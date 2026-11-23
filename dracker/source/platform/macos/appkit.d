/**
 * File:         source/platform/macos/appkit.d
 * Module:       platform.macos.appkit
 * Phase:        Phase 7.2 — AppKit Window Shell, Menus, Dialogs & Raw Input
 *
 * Purpose:
 *   Native macOS shell built directly on the Objective-C runtime: MacApplication (NSApplication bootstrap and
 *   the File/Edit/Transport/View/Window menu bar), MacWindow : IPlatformWindow (NSWindow + one runtime-subclassed
 *   flipped host NSView backed by a CAMetalLayer, Retina backingScaleFactor tracking, raw keyDown/keyUp plus
 *   modifier flagsChanged, mouse buttons/drag/move, trackpad precise scrolling and pinch magnification, basic
 *   NSTextInputClient IME text commit and marked text, NSPasteboard text), and MacFileDialog : IFileDialog
 *   (NSOpenPanel/NSSavePanel window-modal sheets via objc_blocks_shim.m). Menu commands are delivered as the
 *   same keyDown events (macOS virtual key code + KeyModifiers) the app keymap binds, so menus and shortcuts
 *   share one path; Quit and the window close button deliver closeRequested. Diagnostics helpers (synthetic
 *   NSEvent injection, process footprint and CPU time) support the automated GUI self-test.
 *
 * Real-Time & Safety Contract:
 *   Main UI thread only. Every event pump iteration and sheet wait runs inside a ScopedAutoreleasePool. All
 *   runtime-registered IMPs are extern(C) nothrow and reach their MacWindow through an ivar pointer; MacWindow
 *   pins itself as a GC root while native objects reference it.
 *
 * Dependencies:
 *   Internal: gui.renderer (decodeUtf8), platform.interfaces, platform.macos.objc_runtime
 *   External: macOS Cocoa.framework (AppKit, Foundation), QuartzCore.framework (CAMetalLayer),
 *             CoreGraphics.framework (CGEventCreateScrollWheelEvent2), libproc (proc_pid_rusage)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct MacApplication : initialize(), mainMenu(), menuKeyEquivalent(), setMenuItemChecked(), menuItemChecked()
 *   - class MacWindow : IPlatformWindow (+ waitEvents(), wake(), setContentSize(), usePrivatePasteboard(), isVisibleOnScreen(), setFloating(), markedText(), windowNumber(), liveResizeHandler)
 *   - class MacFileDialog : IFileDialog (+ selfTestAutoDismissSeconds, lastSheetWasAttached)
 *   - uint translateModifierFlags(ulong) / postSyntheticKey() / postSyntheticFlags() / postSyntheticMouse()
 *     / postSyntheticScroll() / processFootprintBytes() / mallocBytesInUse() / processCpuSeconds()
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 7.2)
 */
module platform.macos.appkit;

version (OSX):

import core.memory : GC;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import core.sys.posix.unistd : getpid;
import std.string : fromStringz;

import platform.interfaces : FileDialogFilter, IFileDialog, IPlatformWindow, KeyModifiers, PlatformEvent,
    PlatformEventKind, WindowDesc;
import platform.macos.objc_runtime;

private enum ulong NSWindowStyleMaskTitled = 1;
private enum ulong NSWindowStyleMaskClosable = 2;
private enum ulong NSWindowStyleMaskMiniaturizable = 4;
private enum ulong NSWindowStyleMaskResizable = 8;
private enum ulong NSBackingStoreBuffered = 2;
private enum ulong NSEventMaskAny = ulong.max;
private enum ulong NSEventModifierFlagCapsLock = 1uL << 16;
private enum ulong NSEventModifierFlagShift = 1uL << 17;
private enum ulong NSEventModifierFlagControl = 1uL << 18;
private enum ulong NSEventModifierFlagOption = 1uL << 19;
private enum ulong NSEventModifierFlagCommand = 1uL << 20;
private enum ulong NSEventModifierFlagFunction = 1uL << 23;
private enum ulong NSEventTypeKeyDown = 10;
private enum ulong NSEventTypeKeyUp = 11;
private enum ulong NSEventTypeFlagsChanged = 12;
private enum ulong NSEventTypeApplicationDefined = 15;
private enum long NSModalResponseOK = 1;
private enum long NSModalResponseCancel = 0;

private extern (C) @nogc nothrow {
    void* CGEventCreateScrollWheelEvent2(void* source, uint units, uint wheelCount, int wheel1, int wheel2, int wheel3);
    void CGEventSetLocation(void* event, CGPoint location);
    void CFRelease(const(void)* cf);
    int proc_pid_rusage(int pid, int flavor, void* buffer);
    void malloc_zone_statistics(void* zone, MallocStatistics* stats);
}

private struct MallocStatistics {
    uint blocksInUse;
    size_t sizeInUse;
    size_t maxSizeInUse;
    size_t sizeAllocated;
}

private struct RUsageInfoV2 {
    ubyte[16] uuid;
    ulong userTime;
    ulong systemTime;
    ulong pkgIdleWkups;
    ulong interruptWkups;
    ulong pageins;
    ulong wiredSize;
    ulong residentSize;
    ulong physFootprint;
    ulong[32] reserved;
}

/**
 * Translates NSEventModifierFlags into the portable KeyModifiers mask.
 *
 * Params:
 *   flags = NSEvent modifierFlags.
 *
 * Returns:
 *   KeyModifiers bitmask.
 */
uint translateModifierFlags(ulong flags) @safe nothrow pure @nogc {
    uint m = KeyModifiers.none;
    if (flags & NSEventModifierFlagShift) m |= KeyModifiers.shift;
    if (flags & NSEventModifierFlagControl) m |= KeyModifiers.control;
    if (flags & NSEventModifierFlagOption) m |= KeyModifiers.alt;
    if (flags & NSEventModifierFlagCommand) m |= KeyModifiers.command;
    return m;
}

private ulong modifierBitForKeyCode(uint keyCode) @safe nothrow pure @nogc {
    switch (keyCode) {
        case 56:
        case 60:
            return NSEventModifierFlagShift;
        case 59:
        case 62:
            return NSEventModifierFlagControl;
        case 58:
        case 61:
            return NSEventModifierFlagOption;
        case 54:
        case 55:
            return NSEventModifierFlagCommand;
        case 57:
            return NSEventModifierFlagCapsLock;
        case 63:
            return NSEventModifierFlagFunction;
        default:
            return 0;
    }
}

private ulong toNSModifierFlags(uint mods) @safe nothrow pure @nogc {
    ulong f = 0;
    if (mods & KeyModifiers.shift) f |= NSEventModifierFlagShift;
    if (mods & KeyModifiers.control) f |= NSEventModifierFlagControl;
    if (mods & KeyModifiers.alt) f |= NSEventModifierFlagOption;
    if (mods & KeyModifiers.command) f |= NSEventModifierFlagCommand;
    return f;
}

/**
 * Menu command descriptor: title, key equivalent, and the keyDown it delivers (keyCode uint.max = Quit).
 */
private struct MenuSpec {
    string title;
    string keyEquivalent;
    uint modifiers;
    uint keyCode;
    string nativeAction;
}

private enum uint QUIT_KEYCODE = uint.max;

private immutable MenuSpec[][] MENU_ITEMS = [
    [
        MenuSpec("Settings…", ",", KeyModifiers.command, 43, null),
        MenuSpec("Hide Dracker", "h", KeyModifiers.command, 0, "hide:"),
        MenuSpec("Quit Dracker", "q", KeyModifiers.command, QUIT_KEYCODE, null)
    ],
    [
        MenuSpec("New Project", "n", KeyModifiers.command, 45, null),
        MenuSpec("Open Project…", "o", KeyModifiers.command, 31, null),
        MenuSpec("Save Project", "s", KeyModifiers.command, 1, null),
        MenuSpec("Save Project As…", "S", KeyModifiers.command | KeyModifiers.shift, 1, null)
    ],
    [
        MenuSpec("Undo", "z", KeyModifiers.command, 6, null),
        MenuSpec("Redo", "Z", KeyModifiers.command | KeyModifiers.shift, 6, null),
        MenuSpec("Cut", "x", KeyModifiers.command, 7, null),
        MenuSpec("Copy", "c", KeyModifiers.command, 8, null),
        MenuSpec("Paste", "v", KeyModifiers.command, 9, null),
        MenuSpec("Select All", "a", KeyModifiers.command, 0, null)
    ],
    [
        MenuSpec("Play / Stop", "\r", KeyModifiers.command, 36, null),
        MenuSpec("Record", "r", KeyModifiers.command, 15, null),
        MenuSpec("Panic (All Notes Off)", ".", KeyModifiers.command, 47, null)
    ],
    [
        MenuSpec("Zoom In", "=", KeyModifiers.command, 24, null),
        MenuSpec("Zoom Out", "-", KeyModifiers.command, 27, null),
        MenuSpec("Actual Size", "0", KeyModifiers.command, 29, null),
        MenuSpec("Appearance…", "", KeyModifiers.command, 43, null),
        MenuSpec("High Contrast", "c", KeyModifiers.command | KeyModifiers.alt, 8, null)
    ],
    [
        MenuSpec("Minimize", "m", KeyModifiers.command, 0, "performMiniaturize:"),
        MenuSpec("Zoom", "", 0, 0, "performZoom:")
    ]
];

private immutable string[] MENU_TITLES = ["Dracker", "File", "Edit", "Transport", "View", "Window"];

/**
 * NSApplication bootstrap and main menu bar owner.
 */
struct MacApplication {
    private id app_ = null;
    private id menuTarget_ = null;

    /**
     * Creates the shared NSApplication as a regular foreground app and installs the menu bar.
     *
     * Returns:
     *   True on success.
     */
    bool initialize() {
        auto pool = ScopedAutoreleasePool.enter();
        app_ = send(cast(id) cls("NSApplication"), sel("sharedApplication"));
        if (app_ is null) {
            return false;
        }
        send!bool(app_, sel("setActivationPolicy:"), cast(long) 0);
        if (!registerRuntimeClasses()) {
            return false;
        }
        menuTarget_ = send(send(cast(id) cls("STMenuTarget"), sel("alloc")), sel("init"));
        buildMenuBar();
        send!void(app_, sel("finishLaunching"));
        if (send!bool(app_, sel("respondsToSelector:"), sel("activate"))) {
            send!void(app_, sel("activate"));
        } else {
            send!void(app_, sel("activateIgnoringOtherApps:"), true);
        }
        return true;
    }

    /**
     * Routes menu commands to window (the key window of this single-window app).
     *
     * Params:
     *   window = Target window, or null.
     */
    void setCommandTarget(MacWindow window) {
        setIvarPointer(menuTarget_, "dctx", window is null ? null : cast(void*) window);
    }

    /**
     * Returns the NSApplication main menu.
     *
     * Returns:
     *   NSMenu (+0).
     */
    id mainMenu() {
        return send(app_, sel("mainMenu"));
    }

    /**
     * Looks up the key equivalent and modifier mask of a menu item.
     *
     * Params:
     *   menuTitle = Top-level menu title (e.g. "Edit").
     *   itemTitle = Item title (e.g. "Undo").
     *   keyEquivalent = Receives the key equivalent string.
     *   modifiers = Receives KeyModifiers.
     *
     * Returns:
     *   True if the item exists.
     */
    bool menuKeyEquivalent(string menuTitle, string itemTitle, out string keyEquivalent, out uint modifiers) {
        auto pool = ScopedAutoreleasePool.enter();
        id top = send(mainMenu(), sel("itemWithTitle:"), nsString(menuTitle));
        id sub = send(top, sel("submenu"));
        id item = send(sub, sel("itemWithTitle:"), nsString(itemTitle));
        if (item is null) {
            return false;
        }
        keyEquivalent = fromNSString(send(item, sel("keyEquivalent")));
        modifiers = translateModifierFlags(send!ulong(item, sel("keyEquivalentModifierMask")));
        return true;
    }

    /**
     * Sets or clears the checkmark of a menu item (e.g. View ▸ High Contrast).
     *
     * Params:
     *   menuTitle = Top-level menu title.
     *   itemTitle = Item title.
     *   checked = New state.
     *
     * Returns:
     *   False when the item does not exist.
     */
    bool setMenuItemChecked(string menuTitle, string itemTitle, bool checked) {
        auto pool = ScopedAutoreleasePool.enter();
        id top = send(mainMenu(), sel("itemWithTitle:"), nsString(menuTitle));
        id sub = top is null ? null : send(top, sel("submenu"));
        id item = sub is null ? null : send(sub, sel("itemWithTitle:"), nsString(itemTitle));
        if (item is null) {
            return false;
        }
        send!void(item, sel("setState:"), cast(long)(checked ? 1 : 0));
        return true;
    }

    /**
     * Reads the checkmark state of a menu item.
     *
     * Params:
     *   menuTitle = Top-level menu title.
     *   itemTitle = Item title.
     *
     * Returns:
     *   True when the item exists and is checked.
     */
    bool menuItemChecked(string menuTitle, string itemTitle) {
        auto pool = ScopedAutoreleasePool.enter();
        id top = send(mainMenu(), sel("itemWithTitle:"), nsString(menuTitle));
        id sub = top is null ? null : send(top, sel("submenu"));
        id item = sub is null ? null : send(sub, sel("itemWithTitle:"), nsString(itemTitle));
        return item !is null && send!long(item, sel("state")) == 1;
    }

    private void buildMenuBar() {
        id bar = send(send(cast(id) cls("NSMenu"), sel("alloc")), sel("init"));
        foreach (mi, title; MENU_TITLES) {
            id barItem = send(send(cast(id) cls("NSMenuItem"), sel("alloc")), sel("init"));
            send!void(barItem, sel("setTitle:"), nsString(title));
            id menu = send(send(cast(id) cls("NSMenu"), sel("alloc")), sel("initWithTitle:"), nsString(title));
            foreach (ii, ref spec; MENU_ITEMS[mi]) {
                SEL action = spec.nativeAction !is null ? sel(nativeActionZ(spec.nativeAction)) : sel("stMenuAction:");
                id item = send(send(cast(id) cls("NSMenuItem"), sel("alloc")),
                    sel("initWithTitle:action:keyEquivalent:"), nsString(spec.title), action, nsString(spec.keyEquivalent));
                if (spec.keyEquivalent.length > 0) {
                    send!void(item, sel("setKeyEquivalentModifierMask:"), toNSModifierFlags(spec.modifiers));
                }
                if (spec.nativeAction is null) {
                    send!void(item, sel("setTarget:"), menuTarget_);
                    send!void(item, sel("setTag:"), cast(long)(mi * 100 + ii));
                }
                send!void(menu, sel("addItem:"), item);
                release(item);
            }
            send!void(barItem, sel("setSubmenu:"), menu);
            send!void(bar, sel("addItem:"), barItem);
            if (title == "Window") {
                send!void(app_, sel("setWindowsMenu:"), menu);
            }
            release(menu);
            release(barItem);
        }
        send!void(app_, sel("setMainMenu:"), bar);
        release(bar);
    }

    private static const(char)* nativeActionZ(string action) {
        switch (action) {
            case "hide:":
                return "hide:";
            case "performMiniaturize:":
                return "performMiniaturize:";
            case "performZoom:":
                return "performZoom:";
            default:
                return "noop:";
        }
    }
}

/**
 * AppKit host window delivering PlatformEvents and exposing its CAMetalLayer.
 */
final class MacWindow : IPlatformWindow {
    private id window_ = null;
    private id view_ = null;
    private id layer_ = null;
    private id delegate_ = null;
    private PlatformEvent[] queue_;
    private size_t queueHead_ = 0;
    private bool open_ = false;
    private ulong lastModifierFlags_ = 0;
    private string markedText_;
    private bool pinned_ = false;
    private id privatePasteboard_ = null;

    /**
     * Optional callback invoked synchronously while AppKit live-resizes the window (the main loop is blocked
     * inside AppKit's tracking loop then); the app should lay out and render one frame.
     */
    void delegate() nothrow liveResizeHandler;

    override bool create(const ref WindowDesc desc) {
        if (open_) {
            return true;
        }
        auto pool = ScopedAutoreleasePool.enter();
        if (!registerRuntimeClasses()) {
            return false;
        }
        immutable CGRect frame = CGRect(CGPoint(0, 0), CGSize(desc.width, desc.height));
        ulong style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
        if (desc.resizable) {
            style |= NSWindowStyleMaskResizable;
        }
        window_ = send(send(cast(id) cls("NSWindow"), sel("alloc")),
            sel("initWithContentRect:styleMask:backing:defer:"), frame, style, NSBackingStoreBuffered, false);
        if (window_ is null) {
            return false;
        }
        GC.addRoot(cast(void*) this);
        pinned_ = true;
        send!void(window_, sel("setReleasedWhenClosed:"), false);
        send!void(window_, sel("setTitle:"), nsString(desc.title));
        send!void(window_, sel("setContentMinSize:"), CGSize(desc.minWidth, desc.minHeight));
        send!void(window_, sel("setAcceptsMouseMovedEvents:"), true);

        view_ = send(send(cast(id) cls("STHostView"), sel("alloc")), sel("initWithFrame:"), frame);
        setIvarPointer(view_, "dctx", cast(void*) this);
        layer_ = retain(send(cast(id) cls("CAMetalLayer"), sel("layer")));
        immutable double scale = send!double(window_, sel("backingScaleFactor"));
        send!void(layer_, sel("setContentsScale:"), scale);
        send!void(view_, sel("setLayer:"), layer_);
        send!void(view_, sel("setWantsLayer:"), true);
        send!void(window_, sel("setContentView:"), view_);
        send!bool(window_, sel("makeFirstResponder:"), view_);

        delegate_ = send(send(cast(id) cls("STWindowDelegate"), sel("alloc")), sel("init"));
        setIvarPointer(delegate_, "dctx", cast(void*) this);
        send!void(window_, sel("setDelegate:"), delegate_);
        send!void(window_, sel("center"));
        send!void(window_, sel("makeKeyAndOrderFront:"), cast(id) null);
        open_ = true;
        pushResize();
        return true;
    }

    override void destroy() {
        auto pool = ScopedAutoreleasePool.enter();
        if (window_ !is null) {
            send!void(window_, sel("setDelegate:"), cast(id) null);
            send!void(window_, sel("orderOut:"), cast(id) null);
            send!void(window_, sel("close"));
        }
        if (view_ !is null) {
            setIvarPointer(view_, "dctx", null);
        }
        if (delegate_ !is null) {
            setIvarPointer(delegate_, "dctx", null);
        }
        if (privatePasteboard_ !is null) {
            send!void(privatePasteboard_, sel("releaseGlobally"));
            release(privatePasteboard_);
            privatePasteboard_ = null;
        }
        release(delegate_);
        release(layer_);
        release(view_);
        release(window_);
        delegate_ = null;
        layer_ = null;
        view_ = null;
        window_ = null;
        open_ = false;
        if (pinned_) {
            GC.removeRoot(cast(void*) this);
            pinned_ = false;
        }
    }

    override bool isOpen() const {
        return open_;
    }

    override size_t pollEvents(PlatformEvent[] outEvents) {
        pumpNative(0.0);
        return drainQueue(outEvents);
    }

    /**
     * Blocks until at least one native event arrives or timeoutSeconds elapses, then drains pending events.
     *
     * Params:
     *   timeoutSeconds = Maximum wait (<= 0 polls without blocking).
     *   outEvents = Destination for queued PlatformEvents.
     *
     * Returns:
     *   Number of PlatformEvents written.
     */
    size_t waitEvents(double timeoutSeconds, PlatformEvent[] outEvents) {
        if (queueHead_ >= queue_.length) {
            pumpNative(timeoutSeconds);
        } else {
            pumpNative(0.0);
        }
        return drainQueue(outEvents);
    }

    /**
     * Posts an application-defined event so a pending waitEvents() returns promptly (main thread).
     */
    void wake() {
        auto pool = ScopedAutoreleasePool.enter();
        id ev = send(cast(id) cls("NSEvent"),
            sel("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:"),
            NSEventTypeApplicationDefined, CGPoint(0, 0), cast(ulong) 0, 0.0, cast(long) 0, cast(id) null,
            cast(short) 0, cast(long) 0, cast(long) 0);
        send!void(nsApp(), sel("postEvent:atStart:"), ev, false);
    }

    /**
     * Returns the number of PlatformEvents waiting to be drained.
     *
     * Returns:
     *   Pending count.
     */
    size_t pendingEventCount() const {
        return queue_.length - queueHead_;
    }

    override void setTitle(string title) {
        auto pool = ScopedAutoreleasePool.enter();
        send!void(window_, sel("setTitle:"), nsString(title));
    }

    override void getDrawableSize(out uint width, out uint height, out float scaleFactor) const nothrow {
        id v = cast(id) view_;
        id w = cast(id) window_;
        if (v is null || w is null) {
            return;
        }
        immutable CGRect b = send!CGRect(v, sel("bounds"));
        immutable double s = send!double(w, sel("backingScaleFactor"));
        scaleFactor = cast(float) s;
        width = cast(uint)(b.size.width * s + 0.5);
        height = cast(uint)(b.size.height * s + 0.5);
    }

    override void* nativeLayerHandle() const {
        return cast(void*) layer_;
    }

    override void* nativeWindowHandle() const {
        return cast(void*) window_;
    }

    /**
     * Reports whether any part of the window is currently visible (not minimized, occluded, on a sleeping display,
     * or behind the lock screen). Rendering while invisible only blocks in CAMetalLayer.nextDrawable.
     *
     * Returns:
     *   True if visible.
     */
    bool isVisibleOnScreen() const nothrow {
        if (window_ is null) {
            return false;
        }
        enum ulong NSWindowOcclusionStateVisible = 1uL << 1;
        return (send!ulong(cast(id) window_, sel("occlusionState")) & NSWindowOcclusionStateVisible) != 0;
    }

    /**
     * Keeps the window above normal windows without activating the app (used by the unattended self-test so the
     * window stays visible while another app is frontmost).
     *
     * Params:
     *   floating = True for NSFloatingWindowLevel, false for the normal level.
     */
    void setFloating(bool floating) {
        send!void(window_, sel("setLevel:"), cast(long)(floating ? 3 : 0));
        send!void(window_, sel("orderFrontRegardless"));
    }

    /**
     * Resizes the window's content area (logical points); a resize event follows.
     *
     * Params:
     *   width = New content width.
     *   height = New content height.
     */
    void setContentSize(double width, double height) {
        auto pool = ScopedAutoreleasePool.enter();
        send!void(window_, sel("setContentSize:"), CGSize(width, height));
    }

    /**
     * Returns the NSWindow windowNumber (for synthetic event routing).
     *
     * Returns:
     *   Window number.
     */
    long windowNumber() {
        return send!long(window_, sel("windowNumber"));
    }

    /**
     * Returns the in-progress IME composition (marked) text, empty when none.
     *
     * Returns:
     *   Marked UTF-8 text.
     */
    string markedText() const nothrow {
        return markedText_;
    }

    /**
     * Redirects clipboard calls to a private uniquely named pasteboard so automated tests never touch the user's
     * clipboard (released again by destroy()).
     */
    void usePrivatePasteboard() {
        if (privatePasteboard_ is null) {
            auto pool = ScopedAutoreleasePool.enter();
            privatePasteboard_ = retain(send(cast(id) cls("NSPasteboard"), sel("pasteboardWithUniqueName")));
        }
    }

    override string getClipboardText() {
        auto pool = ScopedAutoreleasePool.enter();
        id pb = activePasteboard();
        return fromNSString(send(pb, sel("stringForType:"), nsString("public.utf8-plain-text")));
    }

    override bool setClipboardText(string text) {
        auto pool = ScopedAutoreleasePool.enter();
        id pb = activePasteboard();
        send!long(pb, sel("clearContents"));
        return send!bool(pb, sel("setString:forType:"), nsString(text), nsString("public.utf8-plain-text"));
    }

    private id activePasteboard() {
        return privatePasteboard_ !is null ? privatePasteboard_
            : send(cast(id) cls("NSPasteboard"), sel("generalPasteboard"));
    }

    private size_t drainQueue(PlatformEvent[] outEvents) {
        size_t n = 0;
        while (n < outEvents.length && queueHead_ < queue_.length) {
            outEvents[n++] = queue_[queueHead_++];
        }
        if (queueHead_ >= queue_.length) {
            queue_.length = 0;
            queue_.assumeSafeAppend();
            queueHead_ = 0;
        }
        return n;
    }

    private void pumpNative(double timeoutSeconds) {
        id app = nsApp();
        bool first = true;
        while (true) {
            auto pool = ScopedAutoreleasePool.enter();
            immutable double wait = first && timeoutSeconds > 0.0 ? timeoutSeconds : 0.0;
            first = false;
            id until = wait > 0.0
                ? send(cast(id) cls("NSDate"), sel("dateWithTimeIntervalSinceNow:"), wait)
                : send(cast(id) cls("NSDate"), sel("distantPast"));
            id ev = send(app, sel("nextEventMatchingMask:untilDate:inMode:dequeue:"), NSEventMaskAny, until,
                nsString("kCFRunLoopDefaultMode"), true);
            if (ev is null) {
                break;
            }
            send!void(app, sel("sendEvent:"), ev);
        }
        auto tailPool = ScopedAutoreleasePool.enter();
        send!void(app, sel("updateWindows"));
    }

    package void push(PlatformEvent ev) nothrow {
        queue_ ~= ev;
    }

    package void pushResize() nothrow {
        PlatformEvent ev;
        ev.kind = PlatformEventKind.resize;
        uint w = 0;
        uint h = 0;
        float s = 1.0f;
        getDrawableSize(w, h, s);
        ev.width = w;
        ev.height = h;
        ev.scaleFactor = s;
        if (layer_ !is null) {
            send!void(layer_, sel("setContentsScale:"), cast(double) s);
        }
        push(ev);
    }

    package void handleKey(id event, PlatformEventKind kind) nothrow {
        PlatformEvent ev;
        ev.kind = kind;
        ev.keyCode = send!ushort(event, sel("keyCode"));
        immutable ulong flags = send!ulong(event, sel("modifierFlags"));
        ev.modifiers = translateModifierFlags(flags);
        ev.isRepeat = send!bool(event, sel("isARepeat"));
        push(ev);
        if (kind == PlatformEventKind.keyDown && (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) == 0) {
            id arr = send(cast(id) cls("NSArray"), sel("arrayWithObject:"), event);
            send!void(view_, sel("interpretKeyEvents:"), arr);
        }
    }

    package void handleFlagsChanged(id event) nothrow {
        immutable uint code = send!ushort(event, sel("keyCode"));
        immutable ulong flags = send!ulong(event, sel("modifierFlags"));
        immutable ulong bit = modifierBitForKeyCode(code);
        lastModifierFlags_ = flags;
        if (bit == 0) {
            return;
        }
        PlatformEvent ev;
        ev.kind = (flags & bit) != 0 ? PlatformEventKind.keyDown : PlatformEventKind.keyUp;
        ev.keyCode = code;
        ev.modifiers = translateModifierFlags(flags);
        push(ev);
    }

    package void handleMouse(id event, PlatformEventKind kind, ubyte button) nothrow {
        PlatformEvent ev;
        ev.kind = kind;
        immutable CGPoint inWindow = send!CGPoint(event, sel("locationInWindow"));
        immutable CGPoint p = send!CGPoint(view_, sel("convertPoint:fromView:"), inWindow, cast(id) null);
        ev.x = cast(float) p.x;
        ev.y = cast(float) p.y;
        ev.mouseButton = button;
        ev.modifiers = translateModifierFlags(send!ulong(event, sel("modifierFlags")));
        push(ev);
    }

    package void handleScroll(id event) nothrow {
        PlatformEvent ev;
        ev.kind = PlatformEventKind.mouseScroll;
        immutable CGPoint inWindow = send!CGPoint(event, sel("locationInWindow"));
        immutable CGPoint p = send!CGPoint(view_, sel("convertPoint:fromView:"), inWindow, cast(id) null);
        ev.x = cast(float) p.x;
        ev.y = cast(float) p.y;
        double dx = send!double(event, sel("scrollingDeltaX"));
        double dy = send!double(event, sel("scrollingDeltaY"));
        if (!send!bool(event, sel("hasPreciseScrollingDeltas"))) {
            dx *= 10.0;
            dy *= 10.0;
        }
        ev.deltaX = cast(float) dx;
        ev.deltaY = cast(float) dy;
        ev.modifiers = translateModifierFlags(send!ulong(event, sel("modifierFlags")));
        push(ev);
    }

    package void handleMagnify(id event) nothrow {
        PlatformEvent ev;
        ev.kind = PlatformEventKind.magnify;
        immutable CGPoint inWindow = send!CGPoint(event, sel("locationInWindow"));
        immutable CGPoint p = send!CGPoint(view_, sel("convertPoint:fromView:"), inWindow, cast(id) null);
        ev.x = cast(float) p.x;
        ev.y = cast(float) p.y;
        ev.magnification = cast(float) send!double(event, sel("magnification"));
        push(ev);
    }

    package void handleInsertText(id text) nothrow {
        id str = text;
        if (send!bool(text, sel("isKindOfClass:"), cast(id) cls("NSAttributedString"))) {
            str = send(text, sel("string"));
        }
        immutable string utf8 = fromNSString(str);
        markedText_ = null;
        size_t i = 0;
        while (i < utf8.length) {
            dchar cp = decodeOne(utf8, i);
            if (cp < 0x20 || cp == 0x7F) {
                continue;
            }
            PlatformEvent ev;
            ev.kind = PlatformEventKind.textInput;
            ev.utf32Char = cp;
            push(ev);
        }
    }

    package void handleSetMarkedText(id text) nothrow {
        id str = text;
        if (send!bool(text, sel("isKindOfClass:"), cast(id) cls("NSAttributedString"))) {
            str = send(text, sel("string"));
        }
        markedText_ = fromNSString(str);
    }

    package void handleUnmark() nothrow {
        markedText_ = null;
    }

    package bool hasMarked() const nothrow {
        return markedText_.length > 0;
    }

    package CGRect caretScreenRect() nothrow {
        if (window_ is null || view_ is null) {
            return CGRect.init;
        }
        immutable CGRect b = send!CGRect(view_, sel("bounds"));
        immutable CGRect inWindow = send!CGRect(view_, sel("convertRect:toView:"),
            CGRect(CGPoint(b.origin.x + 8, b.origin.y + 8), CGSize(1, 18)), cast(id) null);
        return send!CGRect(window_, sel("convertRectToScreen:"), inWindow);
    }

    package void handleClose() nothrow {
        PlatformEvent ev;
        ev.kind = PlatformEventKind.closeRequested;
        push(ev);
    }

    package void handleFocus(bool focused) nothrow {
        PlatformEvent ev;
        ev.kind = PlatformEventKind.focusChanged;
        ev.focused = focused;
        push(ev);
    }

    package void handleMenu(long tag) nothrow {
        immutable size_t mi = cast(size_t)(tag / 100);
        immutable size_t ii = cast(size_t)(tag % 100);
        if (mi >= MENU_ITEMS.length || ii >= MENU_ITEMS[mi].length) {
            return;
        }
        immutable MenuSpec spec = MENU_ITEMS[mi][ii];
        if (spec.keyCode == QUIT_KEYCODE) {
            handleClose();
            return;
        }
        PlatformEvent ev;
        ev.kind = PlatformEventKind.keyDown;
        ev.keyCode = spec.keyCode;
        ev.modifiers = spec.modifiers;
        push(ev);
    }

    package void handleLiveResize() nothrow {
        pushResize();
        if (liveResizeHandler !is null && window_ !is null && send!bool(view_, sel("inLiveResize"))) {
            liveResizeHandler();
        }
    }

    private static dchar decodeOne(string s, ref size_t i) nothrow {
        import gui.renderer : decodeUtf8;

        dchar cp;
        decodeUtf8(s, i, cp);
        return cp;
    }
}

/**
 * AppKit open/save panels presented as window-modal sheets (or app-modal when no window is attached).
 */
final class MacFileDialog : IFileDialog {
    private MacWindow window_;

    /**
     * When > 0 (self-test only), the presented panel is cancelled automatically after this many seconds.
     */
    double selfTestAutoDismissSeconds = 0.0;

    /**
     * True if the most recent panel was observed attached to the parent window as a sheet.
     */
    bool lastSheetWasAttached = false;

    /**
     * Binds dialogs to a parent window.
     *
     * Params:
     *   window = Parent window (sheets), or null for app-modal panels.
     */
    this(MacWindow window) {
        window_ = window;
    }

    override bool openFile(string title, const(FileDialogFilter)[] filters, out string selectedPath) {
        auto pool = ScopedAutoreleasePool.enter();
        id panel = send(cast(id) cls("NSOpenPanel"), sel("openPanel"));
        send!void(panel, sel("setCanChooseFiles:"), true);
        send!void(panel, sel("setCanChooseDirectories:"), false);
        send!void(panel, sel("setAllowsMultipleSelection:"), false);
        configurePanel(panel, title, filters);
        return runPanel(panel, true, selectedPath);
    }

    override bool saveFile(string title, string defaultName, const(FileDialogFilter)[] filters, out string selectedPath) {
        auto pool = ScopedAutoreleasePool.enter();
        id panel = send(cast(id) cls("NSSavePanel"), sel("savePanel"));
        send!void(panel, sel("setCanCreateDirectories:"), true);
        if (defaultName.length > 0) {
            send!void(panel, sel("setNameFieldStringValue:"), nsString(defaultName));
        }
        configurePanel(panel, title, filters);
        return runPanel(panel, false, selectedPath);
    }

    private static void configurePanel(id panel, string title, const(FileDialogFilter)[] filters) {
        send!void(panel, sel("setMessage:"), nsString(title));
        send!void(panel, sel("setTitle:"), nsString(title));
        id types = send(cast(id) cls("NSMutableArray"), sel("array"));
        Class utType = cls("UTType");
        foreach (ref f; filters) {
            foreach (ext; f.extensions) {
                if (utType !is null) {
                    id t = send(cast(id) utType, sel("typeWithFilenameExtension:"), nsString(ext));
                    if (t !is null) {
                        send!void(types, sel("addObject:"), t);
                    }
                } else {
                    send!void(types, sel("addObject:"), nsString(ext));
                }
            }
        }
        if (send!ulong(types, sel("count")) == 0) {
            return;
        }
        if (utType !is null && send!bool(panel, sel("respondsToSelector:"), sel("setAllowedContentTypes:"))) {
            send!void(panel, sel("setAllowedContentTypes:"), types);
        } else {
            send!void(panel, sel("setAllowedFileTypes:"), types);
        }
    }

    private struct PanelResult {
        bool done = false;
        bool accepted = false;
        string path;
    }

    private static extern (C) void onPanelDone(void* ctx, int accepted, const(char)* utf8Path) nothrow {
        auto r = cast(PanelResult*) ctx;
        r.done = true;
        r.accepted = accepted != 0 && utf8Path !is null;
        if (r.accepted) {
            r.path = fromStringz(utf8Path).idup;
        }
    }

    private bool runPanel(id panel, bool isOpen, out string selectedPath) {
        import core.time : MonoTime, dur;

        PanelResult* result = new PanelResult();
        id nsWindow = window_ is null ? null : cast(id) window_.nativeWindowHandle();
        if (nsWindow is null) {
            if (selfTestAutoDismissSeconds > 0.0) {
                return false;
            }
            immutable long resp = send!long(panel, sel("runModal"));
            if (resp == NSModalResponseOK) {
                selectedPath = fromNSString(send(send(panel, sel("URL")), sel("path")));
                return selectedPath.length > 0;
            }
            return false;
        }
        if (isOpen) {
            st_ns_panel_begin_open_sheet(panel, nsWindow, &onPanelDone, result);
        } else {
            st_ns_panel_begin_save_sheet(panel, nsWindow, &onPanelDone, result);
        }
        lastSheetWasAttached = false;
        immutable MonoTime start = MonoTime.currTime;
        bool dismissed = false;
        id app = nsApp();
        while (!result.done) {
            auto pool = ScopedAutoreleasePool.enter();
            id until = send(cast(id) cls("NSDate"), sel("dateWithTimeIntervalSinceNow:"), 0.05);
            id ev = send(app, sel("nextEventMatchingMask:untilDate:inMode:dequeue:"), NSEventMaskAny, until,
                nsString("kCFRunLoopDefaultMode"), true);
            if (ev !is null) {
                send!void(app, sel("sendEvent:"), ev);
            }
            if (send(nsWindow, sel("attachedSheet")) is panel) {
                lastSheetWasAttached = true;
            }
            if (!dismissed && selfTestAutoDismissSeconds > 0.0
                    && (MonoTime.currTime - start) > dur!"msecs"(cast(long)(selfTestAutoDismissSeconds * 1000.0))) {
                send!void(panel, sel("cancel:"), cast(id) null);
                dismissed = true;
            }
        }
        if (result.accepted) {
            selectedPath = result.path;
        }
        return result.accepted;
    }
}

private id nsApp() nothrow {
    return send(cast(id) cls("NSApplication"), sel("sharedApplication"));
}

private MacWindow windowOf(id self) nothrow {
    return cast(MacWindow) getIvarPointer(self, "dctx");
}

private extern (C) bool imp_yes(id self, SEL cmd) nothrow {
    return true;
}

private extern (C) void imp_keyDown(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleKey(event, PlatformEventKind.keyDown);
}

private extern (C) void imp_keyUp(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleKey(event, PlatformEventKind.keyUp);
}

private extern (C) void imp_flagsChanged(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleFlagsChanged(event);
}

private extern (C) void imp_mouseDown(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleMouse(event, PlatformEventKind.mouseDown, 0);
}

private extern (C) void imp_mouseUp(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleMouse(event, PlatformEventKind.mouseUp, 0);
}

private extern (C) void imp_mouseDragged(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleMouse(event, PlatformEventKind.mouseMove, 0);
}

private extern (C) void imp_mouseMoved(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleMouse(event, PlatformEventKind.mouseMove, 0);
}

private extern (C) void imp_rightMouseDown(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleMouse(event, PlatformEventKind.mouseDown, 1);
}

private extern (C) void imp_rightMouseUp(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleMouse(event, PlatformEventKind.mouseUp, 1);
}

private extern (C) void imp_rightMouseDragged(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleMouse(event, PlatformEventKind.mouseMove, 1);
}

private extern (C) void imp_otherMouseDown(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleMouse(event, PlatformEventKind.mouseDown, 2);
}

private extern (C) void imp_otherMouseUp(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleMouse(event, PlatformEventKind.mouseUp, 2);
}

private extern (C) void imp_otherMouseDragged(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleMouse(event, PlatformEventKind.mouseMove, 2);
}

private extern (C) void imp_scrollWheel(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleScroll(event);
}

private extern (C) void imp_magnify(id self, SEL cmd, id event) nothrow {
    if (auto w = windowOf(self)) w.handleMagnify(event);
}

private extern (C) void imp_setFrameSize(id self, SEL cmd, CGSize size) nothrow {
    sendSuper!void(self, cls("NSView"), cmd, size);
    if (auto w = windowOf(self)) w.handleLiveResize();
}

private extern (C) void imp_backingChanged(id self, SEL cmd) nothrow {
    sendSuper!void(self, cls("NSView"), cmd);
    if (auto w = windowOf(self)) w.pushResize();
}

private extern (C) void imp_insertText(id self, SEL cmd, id text, NSRange replacement) nothrow {
    if (auto w = windowOf(self)) w.handleInsertText(text);
}

private extern (C) void imp_setMarkedText(id self, SEL cmd, id text, NSRange selected, NSRange replacement) nothrow {
    if (auto w = windowOf(self)) w.handleSetMarkedText(text);
}

private extern (C) void imp_unmarkText(id self, SEL cmd) nothrow {
    if (auto w = windowOf(self)) w.handleUnmark();
}

private extern (C) bool imp_hasMarkedText(id self, SEL cmd) nothrow {
    auto w = windowOf(self);
    return w !is null && w.hasMarked();
}

private extern (C) NSRange imp_markedRange(id self, SEL cmd) nothrow {
    auto w = windowOf(self);
    if (w is null || !w.hasMarked()) {
        return NSRange(NSNotFound, 0);
    }
    return NSRange(0, w.markedText().length);
}

private extern (C) NSRange imp_selectedRange(id self, SEL cmd) nothrow {
    return NSRange(NSNotFound, 0);
}

private extern (C) id imp_validAttributes(id self, SEL cmd) nothrow {
    return send(cast(id) cls("NSArray"), sel("array"));
}

private extern (C) id imp_attributedSubstring(id self, SEL cmd, NSRange range, NSRange* actual) nothrow {
    return null;
}

private extern (C) ulong imp_characterIndex(id self, SEL cmd, CGPoint p) nothrow {
    return NSNotFound;
}

private extern (C) CGRect imp_firstRect(id self, SEL cmd, NSRange range, NSRange* actual) nothrow {
    auto w = windowOf(self);
    return w is null ? CGRect.init : w.caretScreenRect();
}

private extern (C) void imp_doCommand(id self, SEL cmd, SEL command) nothrow {
}

private extern (C) bool imp_windowShouldClose(id self, SEL cmd, id sender) nothrow {
    if (auto w = windowOf(self)) w.handleClose();
    return false;
}

private extern (C) void imp_windowDidBecomeKey(id self, SEL cmd, id note) nothrow {
    if (auto w = windowOf(self)) w.handleFocus(true);
}

private extern (C) void imp_windowDidResignKey(id self, SEL cmd, id note) nothrow {
    if (auto w = windowOf(self)) w.handleFocus(false);
}

private extern (C) void imp_windowDidChangeOcclusion(id self, SEL cmd, id note) nothrow {
    if (auto w = windowOf(self)) w.pushResize();
}

private extern (C) void imp_menuAction(id self, SEL cmd, id sender) nothrow {
    if (auto w = windowOf(self)) w.handleMenu(send!long(sender, sel("tag")));
}

private bool registerRuntimeClasses() {
    RuntimeClassBuilder view;
    if (!view.begin("STHostView", "NSView")) {
        return false;
    }
    if (!view.reused()) {
        view.addPointerIvar("dctx");
        view.addProtocol("NSTextInputClient");
        view.addMethod("acceptsFirstResponder", cast(IMP) &imp_yes, "c@:");
        view.addMethod("isFlipped", cast(IMP) &imp_yes, "c@:");
        view.addMethod("wantsUpdateLayer", cast(IMP) &imp_yes, "c@:");
        view.addMethod("acceptsFirstMouse:", cast(IMP) &imp_yes, "c@:@");
        view.addMethod("keyDown:", cast(IMP) &imp_keyDown, "v@:@");
        view.addMethod("keyUp:", cast(IMP) &imp_keyUp, "v@:@");
        view.addMethod("flagsChanged:", cast(IMP) &imp_flagsChanged, "v@:@");
        view.addMethod("mouseDown:", cast(IMP) &imp_mouseDown, "v@:@");
        view.addMethod("mouseUp:", cast(IMP) &imp_mouseUp, "v@:@");
        view.addMethod("mouseDragged:", cast(IMP) &imp_mouseDragged, "v@:@");
        view.addMethod("mouseMoved:", cast(IMP) &imp_mouseMoved, "v@:@");
        view.addMethod("rightMouseDown:", cast(IMP) &imp_rightMouseDown, "v@:@");
        view.addMethod("rightMouseUp:", cast(IMP) &imp_rightMouseUp, "v@:@");
        view.addMethod("rightMouseDragged:", cast(IMP) &imp_rightMouseDragged, "v@:@");
        view.addMethod("otherMouseDown:", cast(IMP) &imp_otherMouseDown, "v@:@");
        view.addMethod("otherMouseUp:", cast(IMP) &imp_otherMouseUp, "v@:@");
        view.addMethod("otherMouseDragged:", cast(IMP) &imp_otherMouseDragged, "v@:@");
        view.addMethod("scrollWheel:", cast(IMP) &imp_scrollWheel, "v@:@");
        view.addMethod("magnifyWithEvent:", cast(IMP) &imp_magnify, "v@:@");
        view.addMethod("setFrameSize:", cast(IMP) &imp_setFrameSize, "v@:{CGSize=dd}");
        view.addMethod("viewDidChangeBackingProperties", cast(IMP) &imp_backingChanged, "v@:");
        view.addMethod("insertText:replacementRange:", cast(IMP) &imp_insertText, "v@:@{_NSRange=QQ}");
        view.addMethod("setMarkedText:selectedRange:replacementRange:", cast(IMP) &imp_setMarkedText,
            "v@:@{_NSRange=QQ}{_NSRange=QQ}");
        view.addMethod("unmarkText", cast(IMP) &imp_unmarkText, "v@:");
        view.addMethod("hasMarkedText", cast(IMP) &imp_hasMarkedText, "c@:");
        view.addMethod("markedRange", cast(IMP) &imp_markedRange, "{_NSRange=QQ}@:");
        view.addMethod("selectedRange", cast(IMP) &imp_selectedRange, "{_NSRange=QQ}@:");
        view.addMethod("validAttributesForMarkedText", cast(IMP) &imp_validAttributes, "@@:");
        view.addMethod("attributedSubstringForProposedRange:actualRange:", cast(IMP) &imp_attributedSubstring,
            "@@:{_NSRange=QQ}^{_NSRange=QQ}");
        view.addMethod("characterIndexForPoint:", cast(IMP) &imp_characterIndex, "Q@:{CGPoint=dd}");
        view.addMethod("firstRectForCharacterRange:actualRange:", cast(IMP) &imp_firstRect,
            "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}");
        view.addMethod("doCommandBySelector:", cast(IMP) &imp_doCommand, "v@::");
    }
    if (view.register() is null) {
        return false;
    }

    RuntimeClassBuilder del;
    if (!del.begin("STWindowDelegate", "NSObject")) {
        return false;
    }
    if (!del.reused()) {
        del.addPointerIvar("dctx");
        del.addProtocol("NSWindowDelegate");
        del.addMethod("windowShouldClose:", cast(IMP) &imp_windowShouldClose, "c@:@");
        del.addMethod("windowDidBecomeKey:", cast(IMP) &imp_windowDidBecomeKey, "v@:@");
        del.addMethod("windowDidResignKey:", cast(IMP) &imp_windowDidResignKey, "v@:@");
        del.addMethod("windowDidChangeOcclusionState:", cast(IMP) &imp_windowDidChangeOcclusion, "v@:@");
    }
    if (del.register() is null) {
        return false;
    }

    RuntimeClassBuilder menu;
    if (!menu.begin("STMenuTarget", "NSObject")) {
        return false;
    }
    if (!menu.reused()) {
        menu.addPointerIvar("dctx");
        menu.addMethod("stMenuAction:", cast(IMP) &imp_menuAction, "v@:@");
    }
    return menu.register() !is null;
}

/**
 * Posts a synthetic key event to the application queue (diagnostics / self-test).
 *
 * Params:
 *   window = Target window.
 *   keyDown = True for keyDown, false for keyUp.
 *   keyCode = macOS virtual key code.
 *   characters = Characters the key produces (with modifiers applied).
 *   modifiers = KeyModifiers mask.
 *   isRepeat = Auto-repeat flag.
 */
void postSyntheticKey(MacWindow window, bool keyDown, ushort keyCode, string characters, uint modifiers, bool isRepeat = false) {
    auto pool = ScopedAutoreleasePool.enter();
    id ev = send(cast(id) cls("NSEvent"),
        sel("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"),
        keyDown ? NSEventTypeKeyDown : NSEventTypeKeyUp, CGPoint(0, 0), toNSModifierFlags(modifiers), 0.0,
        window.windowNumber(), cast(id) null, nsString(characters), nsString(characters), isRepeat, keyCode);
    send!void(nsApp(), sel("postEvent:atStart:"), ev, false);
}

/**
 * Posts a synthetic modifier flagsChanged event (diagnostics / self-test).
 *
 * Params:
 *   window = Target window.
 *   keyCode = Modifier virtual key code (e.g. 56 = left Shift).
 *   modifiers = KeyModifiers mask after the change.
 */
void postSyntheticFlags(MacWindow window, ushort keyCode, uint modifiers) {
    auto pool = ScopedAutoreleasePool.enter();
    id ev = send(cast(id) cls("NSEvent"),
        sel("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"),
        NSEventTypeFlagsChanged, CGPoint(0, 0), toNSModifierFlags(modifiers), 0.0, window.windowNumber(),
        cast(id) null, nsString(""), nsString(""), false, keyCode);
    send!void(nsApp(), sel("postEvent:atStart:"), ev, false);
}

/**
 * Posts a synthetic mouse event at a point in top-left view coordinates (diagnostics / self-test).
 *
 * Params:
 *   window = Target window.
 *   eventType = NSEventType (1 down, 2 up, 6 dragged, 3/4 right down/up).
 *   x = X in logical points from the view's left edge.
 *   y = Y in logical points from the view's top edge.
 *   modifiers = KeyModifiers held during the event.
 */
void postSyntheticMouse(MacWindow window, ulong eventType, float x, float y, uint modifiers = 0) {
    auto pool = ScopedAutoreleasePool.enter();
    id view = send(cast(id) window.nativeWindowHandle(), sel("contentView"));
    immutable CGPoint inWindow = send!CGPoint(view, sel("convertPoint:toView:"), CGPoint(x, y), cast(id) null);
    id ev = send(cast(id) cls("NSEvent"),
        sel("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
        eventType, inWindow, toNSModifierFlags(modifiers), 0.0, window.windowNumber(), cast(id) null, cast(long) 0, cast(long) 1,
        cast(float) 1.0f);
    send!void(nsApp(), sel("postEvent:atStart:"), ev, false);
}

/**
 * Posts a synthetic pixel-precise scroll event over the window centre or a given view point (diagnostics / self-test).
 *
 * Params:
 *   window = Target window.
 *   deltaX = Horizontal pixel delta.
 *   deltaY = Vertical pixel delta.
 *   atX = Optional X in top-left view coordinates (NaN = window centre).
 *   atY = Optional Y in top-left view coordinates.
 *
 * Returns:
 *   True if the CoreGraphics event could be created.
 */
bool postSyntheticScroll(MacWindow window, int deltaX, int deltaY, float atX = float.nan, float atY = float.nan) {
    auto pool = ScopedAutoreleasePool.enter();
    void* cg = CGEventCreateScrollWheelEvent2(null, 0, 2, deltaY, deltaX, 0);
    if (cg is null) {
        return false;
    }
    scope (exit) CFRelease(cg);
    id nsWin = cast(id) window.nativeWindowHandle();
    immutable CGRect frame = send!CGRect(nsWin, sel("frame"));
    id screens = send(cast(id) cls("NSScreen"), sel("screens"));
    immutable CGRect primary = send!CGRect(send(screens, sel("objectAtIndex:"), cast(ulong) 0), sel("frame"));
    CGPoint target = CGPoint(frame.origin.x + frame.size.width * 0.5,
        primary.size.height - (frame.origin.y + frame.size.height * 0.5));
    if (atX == atX && atY == atY) {
        id view = send(nsWin, sel("contentView"));
        immutable CGPoint inWindow = send!CGPoint(view, sel("convertPoint:toView:"), CGPoint(atX, atY), cast(id) null);
        immutable CGPoint onScreen = send!CGPoint(nsWin, sel("convertPointToScreen:"), inWindow);
        target = CGPoint(onScreen.x, primary.size.height - onScreen.y);
    }
    CGEventSetLocation(cg, target);
    id ev = send(cast(id) cls("NSEvent"), sel("eventWithCGEvent:"), cg);
    if (ev is null) {
        return false;
    }
    send!void(nsWin, sel("sendEvent:"), ev);
    return true;
}

/**
 * Returns the process physical memory footprint (what Activity Monitor reports as Memory).
 *
 * Returns:
 *   Footprint in bytes, or 0 if unavailable.
 */
ulong processFootprintBytes() nothrow @nogc {
    RUsageInfoV2 info;
    if (proc_pid_rusage(getpid(), 2, &info) != 0) {
        return 0;
    }
    return info.physFootprint;
}

/**
 * Returns bytes and blocks currently allocated across all malloc zones (where Objective-C objects, including any
 * leaked autoreleased objects, live; excludes the D GC heap and GPU/IOSurface memory).
 *
 * Params:
 *   blocks = Receives the live block count.
 *
 * Returns:
 *   Bytes in use.
 */
size_t mallocBytesInUse(out size_t blocks) nothrow @nogc {
    MallocStatistics st;
    malloc_zone_statistics(null, &st);
    blocks = st.blocksInUse;
    return st.sizeInUse;
}

/**
 * Returns total user + system CPU time consumed by this process.
 *
 * Returns:
 *   CPU seconds.
 */
double processCpuSeconds() nothrow @nogc {
    rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) {
        return 0.0;
    }
    return ru.ru_utime.tv_sec + ru.ru_utime.tv_usec * 1e-6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec * 1e-6;
}

unittest {
    assert(translateModifierFlags(NSEventModifierFlagShift | NSEventModifierFlagCommand)
        == (KeyModifiers.shift | KeyModifiers.command));
    assert(translateModifierFlags(NSEventModifierFlagOption | NSEventModifierFlagControl)
        == (KeyModifiers.alt | KeyModifiers.control));
    assert(translateModifierFlags(NSEventModifierFlagCapsLock) == KeyModifiers.none);
    assert(toNSModifierFlags(KeyModifiers.command | KeyModifiers.shift)
        == (NSEventModifierFlagCommand | NSEventModifierFlagShift));
    assert(modifierBitForKeyCode(56) == NSEventModifierFlagShift);
    assert(modifierBitForKeyCode(54) == NSEventModifierFlagCommand);
    assert(modifierBitForKeyCode(0) == 0);
    foreach (mi, items; MENU_ITEMS) {
        assert(mi < MENU_TITLES.length);
        assert(items.length < 100);
    }
    assert(processFootprintBytes() > 1024 * 1024);
    immutable double cpu0 = processCpuSeconds();
    double spin = 0.0;
    foreach (i; 0 .. 2_000_000) {
        spin += i * 0.5;
    }
    assert(spin > 0.0 && processCpuSeconds() >= cpu0);
    assert(registerRuntimeClasses());
    assert(cls("STHostView") !is null && cls("STWindowDelegate") !is null && cls("STMenuTarget") !is null);
}
