/**
 * File:         source/app/gui_shell.d
 * Module:       app.gui_shell
 * Phase:        Phase 7 — Native macOS Studio Shell Runner & Automated GUI Self-Test
 *
 * Purpose:
 *   Owns the native GUI main loop: boots MacApplication, MacWindow, CoreTextRasterizer + GlyphCache and
 *   MetalRenderer, then alternates between blocking event waits when idle (near-zero CPU) and display-paced
 *   rendering while a scene animates or input arrives. Hosts any IGuiScene (the Phase 7 widget gallery today,
 *   the Phase 8 studio views later). Also implements --gui-selftest, an unattended verification run of the
 *   Phase 7 exit criteria on the real window: menu key equivalents, raw keyDown/keyUp/modifier/repeat and IME
 *   text, menu shortcut routing (Cmd+Z/Cmd+Shift+Z/Cmd+Q), flipped mouse coordinates, trackpad scroll,
 *   clipboard round-trip, native open/save sheets, Retina drawable sizing and live resize, vsync frame rate,
 *   idle CPU, and zero autorelease/malloc and GC heap growth across 100,000 presented Metal frames. Phase 8.5:
 *   create() registers bundled fonts at process scope (bundledFontDirectories()) and selects the default
 *   Atkinson Hyperlegible Next / Fira Code families before the first frame.
 *
 * Real-Time & Safety Contract:
 *   Main UI thread only; never touches the audio thread. All Objective-C work is delegated to
 *   platform.macos.* which wraps it in autorelease pools.
 *
 * Dependencies:
 *   Internal: gui.{appearance,renderer}, platform.interfaces, platform.macos.{appkit,coretext,metal_renderer}
 *   External: core.time, std.stdio, std.format
 *
 * Planned API (Types, Functions & Hooks):
 *   - interface IGuiScene : handleEvent(), draw(), needsRedraw(), isAnimating()
 *   - class GuiShell : create(), runLoop(), renderFrame(), shutdown()
 *   - string[] bundledFontDirectories()
 *   - int runStudioGui(string[] args) / int runGuiSelfTest(string[] args)
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 7)
 */
module app.gui_shell;

version (StudioGUI):

import core.time : dur, Duration, MonoTime;
import std.format : format;
import std.stdio : stderr, stdout, writefln, writeln;

import gui.renderer : GlyphCache, IRenderer2D, Point2F, RectF;
import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind, WindowDesc;
import platform.macos.appkit : MacApplication, MacFileDialog, MacWindow, postSyntheticFlags, postSyntheticKey,
    postSyntheticMouse, postSyntheticScroll, processCpuSeconds, processFootprintBytes, mallocBytesInUse;
import gui.appearance : DEFAULT_MONO_FONT, DEFAULT_UI_FONT, FontResolution;
import platform.macos.coretext : CoreTextRasterizer;
import platform.macos.metal_renderer : MetalRenderer;

/**
 * Content hosted by GuiShell (widget gallery now, studio views in Phase 8).
 */
interface IGuiScene {
    /**
     * Delivers one platform event.
     *
     * Params:
     *   ev = Event in logical top-left coordinates.
     */
    void handleEvent(const ref PlatformEvent ev);

    /**
     * Lays out and draws the scene for one frame.
     *
     * Params:
     *   r = Active renderer (frame already begun).
     *   width = Canvas width in logical points.
     *   height = Canvas height in logical points.
     *   timeSeconds = Seconds since the shell started.
     */
    void draw(IRenderer2D r, float width, float height, double timeSeconds);

    /**
     * Reports whether the scene changed since the last draw.
     *
     * Returns:
     *   True if a redraw is required.
     */
    bool needsRedraw();

    /**
     * Reports whether the scene animates continuously (display-paced rendering).
     *
     * Returns:
     *   True while animating.
     */
    bool isAnimating();
}

/**
 * Returns the directories searched for bundled fonts: Contents/Resources/Fonts inside an app bundle, and
 * resources/fonts next to the build directory in development builds.
 *
 * Returns:
 *   Existing directories, bundle first.
 */
string[] bundledFontDirectories() {
    import std.file : exists, isDir, thisExePath;
    import std.path : buildNormalizedPath, dirName;

    string[] dirs;
    try {
        immutable string exeDir = dirName(thisExePath());
        foreach (candidate; [buildNormalizedPath(exeDir, "..", "Resources", "Fonts"),
                buildNormalizedPath(exeDir, "..", "resources", "fonts")]) {
            if (exists(candidate) && isDir(candidate)) {
                dirs ~= candidate;
            }
        }
    } catch (Exception) {
    }
    return dirs;
}

/**
 * Native window + renderer + scene main loop.
 */
final class GuiShell {
    MacApplication app;
    MacWindow window;
    CoreTextRasterizer rasterizer;
    GlyphCache glyphs;
    MetalRenderer renderer;
    IGuiScene scene;
    bool quitRequested = false;
    bool forceRedraw = true;
    ulong framesRendered = 0;
    ulong occludedTicks = 0;
    /**
     * Number of bundled font files registered at process scope during create().
     */
    size_t bundledFontFiles = 0;

    /**
     * Fonts resolved for the default appearance during create().
     */
    FontResolution fontResolution;

    private MonoTime start_;
    private PlatformEvent[256] events_;
    private void delegate(const ref PlatformEvent) eventObserver_;

    /**
     * Creates the application, window, and Metal renderer.
     *
     * Params:
     *   desc = Window parameters.
     *   err = Receives a diagnostic on failure.
     *
     * Returns:
     *   True on success.
     */
    bool create(const ref WindowDesc desc, out string err) {
        if (!app.initialize()) {
            err = "NSApplication initialization failed";
            return false;
        }
        window = new MacWindow();
        if (!window.create(desc)) {
            err = "NSWindow creation failed";
            return false;
        }
        app.setCommandTarget(window);
        rasterizer = new CoreTextRasterizer();
        foreach (dir; bundledFontDirectories()) {
            bundledFontFiles += rasterizer.registerBundledFonts(dir);
        }
        fontResolution = rasterizer.setFonts(DEFAULT_UI_FONT, DEFAULT_MONO_FONT);
        glyphs = new GlyphCache(rasterizer);
        renderer = MetalRenderer.create(glyphs, err);
        if (renderer is null) {
            return false;
        }
        renderer.attachLayer(window.nativeLayerHandle());
        window.liveResizeHandler = &onLiveResize;
        start_ = MonoTime.currTime;
        return true;
    }

    /**
     * Installs an observer that sees every event before the scene (self-test instrumentation).
     *
     * Params:
     *   observer = Callback, or null.
     */
    void setEventObserver(void delegate(const ref PlatformEvent) observer) {
        eventObserver_ = observer;
    }

    /**
     * Returns seconds elapsed since create().
     *
     * Returns:
     *   Elapsed seconds.
     */
    double elapsedSeconds() const {
        return (MonoTime.currTime - start_).total!"usecs" * 1e-6;
    }

    /**
     * Processes pending events, blocking up to maxWaitSeconds when nothing needs rendering (or the window is not
     * visible), then renders if needed. Occluded windows never render; an occlusion change triggers a redraw.
     *
     * Params:
     *   maxWaitSeconds = Upper bound for the idle wait.
     *
     * Returns:
     *   True if a frame was rendered.
     */
    bool tick(double maxWaitSeconds = 0.5) {
        immutable bool visible = window.isVisibleOnScreen();
        immutable bool busy = visible
            && (forceRedraw || (scene !is null && (scene.needsRedraw() || scene.isAnimating())));
        immutable size_t n = busy ? window.pollEvents(events_[]) : window.waitEvents(maxWaitSeconds, events_[]);
        dispatch(events_[0 .. n]);
        while (window.pendingEventCount() > 0) {
            immutable size_t more = window.pollEvents(events_[]);
            dispatch(events_[0 .. more]);
        }
        if (!window.isVisibleOnScreen()) {
            occludedTicks++;
            return false;
        }
        if (forceRedraw || (scene !is null && (scene.needsRedraw() || scene.isAnimating()))) {
            renderFrame();
            return true;
        }
        return false;
    }

    /**
     * Runs until the user closes the window or quits.
     */
    void runLoop() {
        while (window.isOpen() && !quitRequested) {
            tick();
        }
    }

    /**
     * Renders one frame of the scene at the current drawable size.
     */
    void renderFrame() {
        uint w = 0;
        uint h = 0;
        float s = 1.0f;
        window.getDrawableSize(w, h, s);
        if (w == 0 || h == 0) {
            return;
        }
        immutable float lw = w / s;
        immutable float lh = h / s;
        renderer.beginFrame(lw, lh, s);
        if (scene !is null) {
            scene.draw(renderer, lw, lh, elapsedSeconds());
        }
        renderer.endFrame();
        forceRedraw = false;
        framesRendered++;
    }

    /**
     * Releases renderer, rasterizer, and window.
     */
    void shutdown() {
        if (renderer !is null) {
            renderer.close();
            renderer = null;
        }
        if (rasterizer !is null) {
            rasterizer.close();
            rasterizer = null;
        }
        if (window !is null) {
            app.setCommandTarget(null);
            window.destroy();
        }
    }

    private void dispatch(const(PlatformEvent)[] evs) {
        foreach (ref ev; evs) {
            if (eventObserver_ !is null) {
                eventObserver_(ev);
            }
            if (ev.kind == PlatformEventKind.closeRequested) {
                quitRequested = true;
            }
            if (ev.kind == PlatformEventKind.resize || ev.kind == PlatformEventKind.focusChanged) {
                forceRedraw = true;
            }
            if (scene !is null) {
                scene.handleEvent(ev);
            }
        }
    }

    private void onLiveResize() nothrow {
        try {
            renderFrame();
        } catch (Exception) {
        }
    }
}

/**
 * Launches the interactive studio shell (Phase 7: widget gallery) and runs until quit.
 *
 * Params:
 *   args = Command-line arguments.
 *
 * Returns:
 *   Process exit code.
 */
int runStudioGui(string[] args) {
    import app.gui_gallery : GalleryScene;

    GuiShell shell = new GuiShell();
    WindowDesc desc;
    desc.title = "SynthTracker";
    string err;
    if (!shell.create(desc, err)) {
        stderr.writeln("GUI startup failed: ", err);
        return 1;
    }
    scope (exit) shell.shutdown();
    shell.scene = new GalleryScene(shell.renderer);
    shell.runLoop();
    return 0;
}

private struct CheckResult {
    string name;
    bool pass;
    string detail;
}

private final class EventLog {
    PlatformEvent[] events;

    void record(const ref PlatformEvent ev) {
        events ~= ev;
    }

    void clear() {
        events.length = 0;
    }

    size_t count(PlatformEventKind kind) const {
        size_t n = 0;
        foreach (ref e; events) {
            if (e.kind == kind) n++;
        }
        return n;
    }
}

/**
 * Runs the unattended Phase 7 GUI verification and prints one PASS/FAIL line per check.
 *
 * Params:
 *   args = Command-line arguments (--quick shortens the 100,000-frame soak to 20,000 frames).
 *
 * Returns:
 *   0 if every check passed, 1 otherwise.
 */
int runGuiSelfTest(string[] args) {
    import app.gui_gallery : GalleryScene;

    bool quick = false;
    foreach (a; args) {
        if (a == "--quick") quick = true;
    }
    CheckResult[] results;
    void check(string name, bool pass, string detail) {
        results ~= CheckResult(name, pass, detail);
        writefln("%s  %-26s %s", pass ? "PASS" : "FAIL", name, detail);
        stdout.flush();
    }

    GuiShell shell = new GuiShell();
    WindowDesc desc;
    desc.title = "SynthTracker GUI Self-Test";
    desc.width = 1100;
    desc.height = 720;
    string err;
    if (!shell.create(desc, err)) {
        check("startup", false, err);
        return 1;
    }
    scope (exit) shell.shutdown();
    GalleryScene gallery = new GalleryScene(shell.renderer);
    shell.scene = gallery;
    shell.window.setFloating(true);
    EventLog log = new EventLog();
    shell.setEventObserver(&log.record);

    void pumpFor(double seconds) {
        immutable MonoTime until = MonoTime.currTime + dur!"usecs"(cast(long)(seconds * 1e6));
        while (MonoTime.currTime < until) {
            shell.tick(0.02);
        }
    }

    bool pumpUntil(bool delegate() cond, double timeoutSeconds) {
        immutable MonoTime until = MonoTime.currTime + dur!"usecs"(cast(long)(timeoutSeconds * 1e6));
        while (MonoTime.currTime < until) {
            shell.tick(0.02);
            if (cond()) return true;
        }
        return cond();
    }

    pumpFor(0.6);

    uint dw = 0;
    uint dh = 0;
    float ds = 0.0f;
    shell.window.getDrawableSize(dw, dh, ds);
    check("window+retina", shell.window.isOpen() && dw > 0 && dh > 0 && ds >= 1.0f
        && shell.window.nativeLayerHandle() !is null && shell.framesRendered > 0,
        format("drawable %sx%s px @%sx, shader=%s", dw, dh, ds, shell.renderer.shaderOrigin()));

    {
        struct MenuExpect {
            string menu;
            string item;
            string key;
            uint mods;
        }
        immutable MenuExpect[] expect = [
            MenuExpect("SynthTracker", "Quit SynthTracker", "q", KeyModifiers.command),
            MenuExpect("File", "Open Project…", "o", KeyModifiers.command),
            MenuExpect("File", "Save Project", "s", KeyModifiers.command),
            MenuExpect("Edit", "Undo", "z", KeyModifiers.command),
            MenuExpect("Edit", "Redo", "Z", KeyModifiers.command | KeyModifiers.shift),
            MenuExpect("Transport", "Play / Stop", "\r", KeyModifiers.command),
            MenuExpect("View", "Zoom In", "=", KeyModifiers.command),
            MenuExpect("Window", "Minimize", "m", KeyModifiers.command)
        ];
        bool ok = true;
        string bad;
        foreach (ref e; expect) {
            string key;
            uint mods;
            if (!shell.app.menuKeyEquivalent(e.menu, e.item, key, mods) || key != e.key || mods != e.mods) {
                ok = false;
                bad ~= e.menu ~ "/" ~ e.item ~ " ";
            }
        }
        check("menu bar", ok, ok ? format("%s key equivalents verified", expect.length) : "mismatch: " ~ bad);
    }

    {
        log.clear();
        postSyntheticKey(shell.window, true, 12, "q", 0);
        postSyntheticKey(shell.window, false, 12, "q", 0);
        postSyntheticFlags(shell.window, 56, KeyModifiers.shift);
        postSyntheticFlags(shell.window, 56, 0);
        postSyntheticKey(shell.window, true, 12, "q", 0, true);
        postSyntheticKey(shell.window, false, 12, "q", 0);
        immutable bool got = pumpUntil(() => log.count(PlatformEventKind.keyUp) >= 3, 2.0);
        PlatformEventKind[] kinds;
        foreach (ref e; log.events) {
            if (e.kind == PlatformEventKind.keyDown || e.kind == PlatformEventKind.keyUp
                    || e.kind == PlatformEventKind.textInput) {
                kinds ~= e.kind;
            }
        }
        bool ok = got && kinds.length >= 8;
        PlatformEvent[] keys;
        foreach (ref e; log.events) {
            if (e.kind == PlatformEventKind.keyDown || e.kind == PlatformEventKind.keyUp
                    || e.kind == PlatformEventKind.textInput) {
                keys ~= e;
            }
        }
        if (ok) {
            ok = keys[0].kind == PlatformEventKind.keyDown && keys[0].keyCode == 12 && !keys[0].isRepeat
                && keys[1].kind == PlatformEventKind.textInput && keys[1].utf32Char == 'q'
                && keys[2].kind == PlatformEventKind.keyUp && keys[2].keyCode == 12
                && keys[3].kind == PlatformEventKind.keyDown && keys[3].keyCode == 56
                && (keys[3].modifiers & KeyModifiers.shift) != 0
                && keys[4].kind == PlatformEventKind.keyUp && keys[4].keyCode == 56
                && keys[5].kind == PlatformEventKind.keyDown && keys[5].keyCode == 12 && keys[5].isRepeat
                && keys[6].kind == PlatformEventKind.textInput
                && keys[7].kind == PlatformEventKind.keyUp && keys[7].keyCode == 12;
        }
        check("raw keys + IME text", ok, format("%s key/text events in order down/text/up/shift/repeat", keys.length));
    }

    {
        log.clear();
        postSyntheticKey(shell.window, true, 6, "z", KeyModifiers.command);
        postSyntheticKey(shell.window, true, 6, "Z", KeyModifiers.command | KeyModifiers.shift);
        pumpUntil(() => log.count(PlatformEventKind.keyDown) >= 2, 2.0);
        size_t undo = 0;
        size_t redo = 0;
        foreach (ref e; log.events) {
            if (e.kind == PlatformEventKind.keyDown && e.keyCode == 6 && e.modifiers == KeyModifiers.command) undo++;
            if (e.kind == PlatformEventKind.keyDown && e.keyCode == 6
                    && e.modifiers == (KeyModifiers.command | KeyModifiers.shift)) redo++;
        }
        log.clear();
        shell.quitRequested = false;
        postSyntheticKey(shell.window, true, 12, "q", KeyModifiers.command);
        immutable bool quitSeen = pumpUntil(() => log.count(PlatformEventKind.closeRequested) >= 1, 2.0);
        immutable bool quitFlag = shell.quitRequested;
        shell.quitRequested = false;
        check("menu shortcuts", undo == 1 && redo == 1 && quitSeen && quitFlag,
            format("Cmd+Z x%s, Cmd+Shift+Z x%s, Cmd+Q close=%s", undo, redo, quitSeen));
    }

    {
        log.clear();
        postSyntheticMouse(shell.window, 1, 120.0f, 64.0f);
        postSyntheticMouse(shell.window, 2, 120.0f, 64.0f);
        postSyntheticMouse(shell.window, 3, 300.0f, 200.0f);
        postSyntheticMouse(shell.window, 4, 300.0f, 200.0f);
        pumpUntil(() => log.count(PlatformEventKind.mouseUp) >= 2, 2.0);
        PlatformEvent[] downs;
        foreach (ref e; log.events) {
            if (e.kind == PlatformEventKind.mouseDown) downs ~= e;
        }
        immutable bool ok = downs.length == 2
            && downs[0].mouseButton == 0 && approx(downs[0].x, 120.0f) && approx(downs[0].y, 64.0f)
            && downs[1].mouseButton == 1 && approx(downs[1].x, 300.0f) && approx(downs[1].y, 200.0f)
            && log.count(PlatformEventKind.mouseUp) == 2;
        check("mouse (flipped coords)", ok, downs.length == 2
            ? format("left@(%.1f,%.1f) right@(%.1f,%.1f)", downs[0].x, downs[0].y, downs[1].x, downs[1].y)
            : format("%s mouseDown events", downs.length));
    }

    {
        log.clear();
        immutable bool posted = postSyntheticScroll(shell.window, 0, -30);
        pumpUntil(() => log.count(PlatformEventKind.mouseScroll) >= 1, 2.0);
        float dy = 0.0f;
        foreach (ref e; log.events) {
            if (e.kind == PlatformEventKind.mouseScroll) dy += e.deltaY;
        }
        check("trackpad scroll", posted && log.count(PlatformEventKind.mouseScroll) >= 1 && dy < -1.0f,
            format("deltaY=%.1f", dy));
    }

    {
        pumpFor(0.2);
        immutable RectF tb = gallery.animateToggleBounds();
        immutable Point2F tc = tb.center();
        postSyntheticMouse(shell.window, 1, tc.x, tc.y);
        postSyntheticMouse(shell.window, 2, tc.x, tc.y);
        immutable bool turnedOn = pumpUntil(() => gallery.isAnimating(), 2.0);
        postSyntheticMouse(shell.window, 1, tc.x, tc.y);
        postSyntheticMouse(shell.window, 2, tc.x, tc.y);
        immutable bool turnedOff = pumpUntil(() => !gallery.isAnimating(), 2.0);
        immutable RectF cb = gallery.canvasBounds();
        postSyntheticMouse(shell.window, 3, cb.x + cb.w * 0.6f, cb.y + cb.h * 0.7f);
        postSyntheticMouse(shell.window, 4, cb.x + cb.w * 0.6f, cb.y + cb.h * 0.7f);
        immutable bool menuOpened = pumpUntil(() => gallery.context().overlays().length == 1, 2.0);
        postSyntheticKey(shell.window, true, 53, "\x1b", 0);
        postSyntheticKey(shell.window, false, 53, "\x1b", 0);
        immutable bool menuClosed = pumpUntil(() => gallery.context().overlays().length == 0, 2.0);
        check("toolkit via real events", turnedOn && turnedOff && menuOpened && menuClosed,
            format("toggle on=%s off=%s, context menu open=%s, Escape closed=%s", turnedOn, turnedOff, menuOpened,
                menuClosed));
    }

    {
        shell.window.usePrivatePasteboard();
        immutable string probe = "SynthTracker self-test \u2713 clipboard";
        immutable bool wrote = shell.window.setClipboardText(probe);
        immutable string back = shell.window.getClipboardText();
        immutable bool cleared = shell.window.setClipboardText("");
        check("clipboard", wrote && back == probe && cleared && shell.window.getClipboardText() == "",
            "UTF-8 round-trip on a private pasteboard (user clipboard untouched)");
    }

    {
        MacFileDialog dlg = new MacFileDialog(shell.window);
        dlg.selfTestAutoDismissSeconds = 0.4;
        import platform.interfaces : FileDialogFilter;

        FileDialogFilter[] filters = [FileDialogFilter("SynthTracker Project", ["msv"])];
        string path;
        immutable MonoTime t0 = MonoTime.currTime;
        immutable bool openAccepted = dlg.openFile("Open Project", filters, path);
        immutable bool openSheet = dlg.lastSheetWasAttached;
        immutable bool saveAccepted = dlg.saveFile("Save Project", "Untitled.msv", filters, path);
        immutable bool saveSheet = dlg.lastSheetWasAttached;
        immutable double secs = (MonoTime.currTime - t0).total!"msecs" / 1000.0;
        check("open/save sheets", !openAccepted && !saveAccepted && openSheet && saveSheet && secs < 6.0,
            format("both sheets attached and cancelled in %.2fs", secs));
    }

    {
        log.clear();
        shell.window.setContentSize(900, 600);
        pumpFor(0.3);
        uint w2 = 0;
        uint h2 = 0;
        float s2 = 0.0f;
        shell.window.getDrawableSize(w2, h2, s2);
        immutable ulong framesBefore = shell.framesRendered;
        pumpFor(0.2);
        immutable bool resizedSeen = log.count(PlatformEventKind.resize) >= 1;
        immutable bool listOk = shell.renderer.lastDrawList().framebufferWidth == w2;
        check("resize", resizedSeen && w2 == cast(uint)(900 * s2) && h2 == cast(uint)(600 * s2) && listOk
            && shell.framesRendered >= framesBefore,
            format("drawable now %sx%s px", w2, h2));
    }

    {
        gallery.setAnimating(true);
        pumpFor(0.5);
        immutable ulong f0 = shell.framesRendered;
        immutable MonoTime t0 = MonoTime.currTime;
        pumpFor(2.0);
        immutable double secs = (MonoTime.currTime - t0).total!"usecs" * 1e-6;
        immutable double fps = (shell.framesRendered - f0) / secs;
        check("vsync animation", fps >= 55.0 && fps <= 125.0,
            format("%.1f fps display-paced (dropped %s)", fps, shell.renderer.framesDropped));
    }

    {
        gallery.setAnimating(false);
        pumpFor(0.5);
        immutable ulong f0 = shell.framesRendered;
        immutable double cpu0 = processCpuSeconds();
        immutable MonoTime t0 = MonoTime.currTime;
        while (MonoTime.currTime - t0 < dur!"seconds"(5)) {
            shell.tick(1.0);
        }
        immutable double wall = (MonoTime.currTime - t0).total!"usecs" * 1e-6;
        immutable double pct = (processCpuSeconds() - cpu0) / wall * 100.0;
        check("idle CPU", pct < 3.0, format("%.2f%% over %.1fs (%s frames while idle)", pct, wall,
            shell.framesRendered - f0));
    }

    {
        immutable ulong total = quick ? 20_000 : 100_000;
        immutable ulong warm = total / 5;
        import core.memory : GC;

        enum size_t CHECKPOINTS = 10;
        shell.window.setContentSize(640, 400);
        gallery.setAnimating(true);
        log.clear();
        shell.setEventObserver(null);
        size_t[CHECKPOINTS + 1] mallocAt;
        size_t[CHECKPOINTS + 1] blocksAt;
        size_t gcWarm = 0;
        ulong footprintWarm = 0;
        immutable ulong framesAtStart = shell.framesRendered;
        immutable double drawableWait0 = shell.renderer.secondsWaitingForDrawable;
        immutable MonoTime t0 = MonoTime.currTime;
        size_t nextCheckpoint = 0;
        immutable MonoTime deadline = MonoTime.currTime + dur!"seconds"(cast(long)(total / 30 + 120));
        ulong occludedWaits = 0;
        ulong done = 0;
        while (done < total && MonoTime.currTime < deadline) {
            if (!shell.tick(0.25)) {
                occludedWaits++;
                continue;
            }
            done++;
            if (done >= warm && nextCheckpoint <= CHECKPOINTS
                    && done >= warm + (total - warm) * nextCheckpoint / CHECKPOINTS) {
                GC.collect();
                GC.minimize();
                if (nextCheckpoint == 0) {
                    gcWarm = GC.stats().usedSize;
                    footprintWarm = processFootprintBytes();
                }
                mallocAt[nextCheckpoint] = mallocBytesInUse(blocksAt[nextCheckpoint]);
                nextCheckpoint++;
            }
        }
        if (done < total) {
            check("100k-frame memory soak", false, format("only %s/%s frames presented before the deadline; window "
                ~ "was not visible for %s waits (display asleep, locked, or occluded?)", done, total, occludedWaits));
        } else {
        immutable double secs = (MonoTime.currTime - t0).total!"usecs" * 1e-6;
        GC.collect();
        GC.minimize();
        immutable long gcGrowth = cast(long) GC.stats().usedSize - cast(long) gcWarm;
        immutable long footprintGrowth = cast(long) processFootprintBytes() - cast(long) footprintWarm;
        immutable ulong frames = shell.framesRendered - framesAtStart;
        gallery.setAnimating(false);
        shell.setEventObserver(&log.record);
        immutable long mallocTotal = cast(long) mallocAt[CHECKPOINTS] - cast(long) mallocAt[0];
        immutable long mallocTail = cast(long) mallocAt[CHECKPOINTS] - cast(long) mallocAt[CHECKPOINTS * 6 / 10];
        immutable long blocksTail = cast(long) blocksAt[CHECKPOINTS] - cast(long) blocksAt[CHECKPOINTS * 6 / 10];
        string trace;
        foreach (k; 0 .. CHECKPOINTS + 1) {
            trace ~= format("%s%+.0f", k == 0 ? "" : " ", (cast(long) mallocAt[k] - cast(long) mallocAt[0]) / 1024.0);
        }
        check("100k-frame memory soak",
            frames >= total && mallocTail < 256 * 1024 && blocksTail < 256 && mallocTotal < 2 * 1024 * 1024
                && gcGrowth < 256 * 1024 && footprintGrowth < 64 * 1024 * 1024,
            format("%s presented frames in %.0fs (%.1f fps); malloc after warm-up %+.1f KB, last 40%%: %+.1f KB / %+d "
                ~ "blocks; GC heap %+d KB; footprint %+.1f MB; malloc KB trace [%s]",
                frames, secs, frames / secs, mallocTotal / 1024.0, mallocTail / 1024.0, blocksTail, gcGrowth / 1024,
                footprintGrowth / 1048576.0, trace));
        }
    }

    size_t failed = 0;
    foreach (ref r; results) {
        if (!r.pass) failed++;
    }
    writefln("GUI self-test: %s/%s checks passed", results.length - failed, results.length);
    return failed == 0 ? 0 : 1;
}

private bool approx(float a, float b) {
    immutable float d = a - b;
    return d < 1.0f && d > -1.0f;
}
