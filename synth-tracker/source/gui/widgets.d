/**
 * File:         source/gui/widgets.d
 * Module:       gui.widgets
 * Phase:        Phase 7.5 — Pure-D Studio Widget Library
 *
 * Purpose:
 *   Retained widget toolkit for the studio: a Widget tree (bounds, children, visibility, enablement, focus,
 *   measure/arrange hooks, IRenderer2D drawing, bubbling event handlers, hit-testing) driven by UiContext,
 *   which converts PlatformEvents into widget dispatch with topmost-first hit-testing, mouse capture during
 *   drags, hover tracking, double-click detection, keyboard focus with Tab/Shift+Tab traversal, an overlay
 *   layer for popups that closes on outside click/Escape, right-click context-menu providers, and a
 *   needsRedraw/isAnimating pair so the host can sleep when idle. Controls: Panel, Label, Button, Toggle,
 *   Slider, RotaryKnob, NumericDragBox, Dropdown, ContextMenu, ScrollView (with ScrollBarModel), SplitView,
 *   CurveEditor and EnvelopeEditor.
 *
 * Real-Time & Safety Contract:
 *   UI thread only; GC allocation is permitted but kept off per-frame hot paths where practical. Widgets
 *   use absolute window coordinates in logical points (top-left origin) and draw exclusively through
 *   IRenderer2D. Text is measured through ITextMeasurer. No global mutable state.
 *
 * Dependencies:
 *   Internal: gui.renderer, gui.theme, gui.layout, platform.interfaces (PlatformEvent, PlatformEventKind, KeyModifiers)
 *   External: std.math, std.format (format), std.conv (to), core.time (MonoTime)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum KeyCode / enum MouseButton / struct MouseEvent / struct ScrollEvent / struct KeyEvent
 *   - class Widget : add/remove, measure(ITextMeasurer, theme), arrange(RectF), layoutChildren(), draw(IRenderer2D, theme),
 *       paint(), hitTest(Point2F), onMouseDown/Up/Move, onScroll, onMagnify, onKeyDown/Up, onTextInput, onMouseEnter/Leave,
 *       onFocusGained/Lost, onCaptureLost, onDismissed, isAnimating(), contextMenuProvider
 *   - final class UiContext : handleEvent(PlatformEvent), layout(RectF, ITextMeasurer), draw(IRenderer2D[, theme]),
 *       renderFrame(IRenderer2D, scale), needsRedraw, isAnimating(), setFocus/focusNext/focusPrevious, capture/releaseCapture,
 *       openOverlay/closeOverlay/closeAllOverlays, hitTest(Point2F)
 *   - struct ValueRange; abstract class ValueWidget; class Panel / Label / Button / Toggle / Slider / RotaryKnob /
 *       NumericDragBox / Dropdown / DropdownList / ContextMenu (struct MenuItem) / ScrollView (struct ScrollBarModel) /
 *       SplitView / CurveEditor / EnvelopeEditor
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.widgets;

import core.time : MonoTime;
import std.conv : to;
import std.format : format;
import std.math : abs, cos, exp, isFinite, log, PI, round, sin;

import gui.layout : Axis, clampf, clampRectInside, DockLayout, FlexItem, Insets, layoutFlexInto, SplitPaneNode;
import gui.renderer : ColorRGBA, FontId, IRenderer2D, ITextMeasurer, Point2F, RectF;
import gui.theme : StudioTheme;
import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;

/**
 * macOS virtual key codes used by the toolkit.
 */
enum KeyCode : uint {
    a = 0,
    s = 1,
    returnKey = 36,
    tab = 48,
    space = 49,
    deleteBackward = 51,
    escape = 53,
    keypadEnter = 76,
    home = 115,
    pageUp = 116,
    forwardDelete = 117,
    end = 119,
    pageDown = 121,
    left = 123,
    right = 124,
    down = 125,
    up = 126
}

/**
 * Mouse buttons as reported by PlatformEvent.mouseButton.
 */
enum MouseButton : ubyte {
    left = 0,
    right = 1,
    other = 2
}

/**
 * Reports whether a modifier mask contains a flag.
 *
 * Params:
 *   mods = KeyModifiers bitmask.
 *   flag = Flag to test.
 *
 * Returns:
 *   True if set.
 */
bool hasModifier(uint mods, KeyModifiers flag) @safe nothrow pure @nogc {
    return (mods & cast(uint) flag) != 0;
}

/**
 * Mouse button/move event in absolute logical coordinates.
 */
struct MouseEvent {
    Point2F pos;
    MouseButton button = MouseButton.left;
    uint modifiers = 0;
    uint clickCount = 1;

    @safe nothrow pure @nogc:

    /**
     * Reports whether Shift is held.
     *
     * Returns:
     *   True if Shift is held.
     */
    bool shift() const {
        return hasModifier(modifiers, KeyModifiers.shift);
    }

    /**
     * Reports whether Option/Alt is held.
     *
     * Returns:
     *   True if Alt is held.
     */
    bool alt() const {
        return hasModifier(modifiers, KeyModifiers.alt);
    }
}

/**
 * Trackpad/wheel scroll event; positive deltaY moves content down (scrolls toward the top).
 */
struct ScrollEvent {
    Point2F pos;
    float deltaX = 0.0f;
    float deltaY = 0.0f;
    uint modifiers = 0;
}

/**
 * Raw key event carrying a macOS virtual key code.
 */
struct KeyEvent {
    uint keyCode = 0;
    uint modifiers = 0;
    bool isRepeat = false;

    @safe nothrow pure @nogc:

    /**
     * Reports whether Shift is held.
     *
     * Returns:
     *   True if Shift is held.
     */
    bool shift() const {
        return hasModifier(modifiers, KeyModifiers.shift);
    }
}

/**
 * One context-menu entry; separators ignore every other field.
 */
struct MenuItem {
    string label;
    void delegate() action;
    bool enabled = true;
    bool separator = false;
    string shortcut;

    /**
     * Builds a separator entry.
     *
     * Returns:
     *   Separator item.
     */
    static MenuItem makeSeparator() @safe nothrow pure @nogc {
        MenuItem m;
        m.separator = true;
        m.enabled = false;
        return m;
    }
}

/**
 * Measures text through a measurer, falling back to a 0.6 em per code point estimate when none is available.
 *
 * Params:
 *   m = Text measurer (may be null).
 *   text = UTF-8 text.
 *   font = Font family.
 *   size = Font size in points.
 *
 * Returns:
 *   Advance width in points.
 */
float measureTextOr(ITextMeasurer m, const(char)[] text, FontId font, float size) {
    if (m !is null) {
        return m.measureText(text, font, size);
    }
    size_t cps = 0;
    foreach (dchar c; text) {
        cast(void) c;
        cps++;
    }
    return cast(float) cps * size * 0.6f;
}

/**
 * Returns a line height through a measurer, falling back to 1.2 em.
 *
 * Params:
 *   m = Text measurer (may be null).
 *   font = Font family.
 *   size = Font size in points.
 *
 * Returns:
 *   Line height in points.
 */
float lineHeightOr(ITextMeasurer m, FontId font, float size) {
    return m !is null ? m.lineHeight(font, size) : size * 1.2f;
}

/**
 * Draws the theme focus ring around a rectangle.
 *
 * Params:
 *   r = Renderer.
 *   theme = Theme.
 *   rect = Focused control bounds.
 *   radius = Control corner radius.
 */
void drawFocusRing(IRenderer2D r, const ref StudioTheme theme, RectF rect, float radius) {
    immutable float g = theme.focusRingGap;
    immutable RectF ring = RectF(rect.x - g, rect.y - g, rect.w + 2.0f * g, rect.h + 2.0f * g);
    r.strokeRoundedRect(ring, radius + g, theme.focusRingWidth, theme.focusRing);
}

/**
 * Draws a filled circle via a fully rounded rectangle.
 *
 * Params:
 *   r = Renderer.
 *   c = Centre.
 *   radius = Radius.
 *   color = Fill color.
 */
void fillCircle(IRenderer2D r, Point2F c, float radius, ColorRGBA color) {
    r.fillRoundedRect(RectF(c.x - radius, c.y - radius, radius * 2.0f, radius * 2.0f), radius, color);
}

/**
 * Base retained widget. Bounds are absolute logical window coordinates. Event handlers return true when
 * handled; unhandled events bubble to the parent.
 */
class Widget {
    string id;
    RectF bounds;
    Point2F preferredSize;
    Point2F measuredSize;
    FlexItem flex;
    bool visible = true;
    bool enabled = true;
    bool focusable = false;
    bool mouseTransparent = false;
    MenuItem[] delegate(Point2F) contextMenuProvider;
    private Widget parent_;
    private Widget[] children_;
    private UiContext context_;

    /**
     * Returns the parent widget.
     *
     * Returns:
     *   Parent, or null for roots and overlays.
     */
    final Widget parent() {
        return parent_;
    }

    /**
     * Returns the child list in paint order (last child is topmost).
     *
     * Returns:
     *   Children slice.
     */
    final Widget[] children() {
        return children_;
    }

    /**
     * Appends a child widget (reparenting it if needed).
     *
     * Params:
     *   child = Child to add.
     *
     * Returns:
     *   The child, for fluent construction.
     */
    final T add(T : Widget)(T child) {
        Widget w = child;
        assert(w !is null && w !is this, "invalid child");
        if (w.parent_ !is null) {
            w.parent_.remove(w);
        }
        w.parent_ = this;
        children_ ~= w;
        invalidate();
        return child;
    }

    /**
     * Removes a direct child; the UiContext drops focus/hover/capture references into the removed subtree.
     *
     * Params:
     *   child = Child to remove.
     *
     * Returns:
     *   True if the child was found.
     */
    final bool remove(Widget child) {
        foreach (i, c; children_) {
            if (c is child) {
                if (auto ctx = context()) {
                    ctx.widgetDetached(child);
                }
                children_ = children_[0 .. i] ~ children_[i + 1 .. $];
                child.parent_ = null;
                invalidate();
                return true;
            }
        }
        return false;
    }

    /**
     * Removes all children.
     */
    final void clearChildren() {
        while (children_.length > 0) {
            remove(children_[$ - 1]);
        }
    }

    /**
     * Returns the UiContext owning this widget's tree (root or overlay layer).
     *
     * Returns:
     *   Context, or null when detached.
     */
    final UiContext context() {
        Widget w = this;
        while (w.parent_ !is null) {
            w = w.parent_;
        }
        return w.context_;
    }

    /**
     * Reports whether this widget is w or one of w's ancestors.
     *
     * Params:
     *   w = Candidate descendant.
     *
     * Returns:
     *   True if w lies in this subtree.
     */
    final bool isAncestorOf(Widget w) {
        for (Widget p = w; p !is null; p = p.parent_) {
            if (p is this) {
                return true;
            }
        }
        return false;
    }

    /**
     * Reports whether this widget and all ancestors are visible.
     *
     * Returns:
     *   Effective visibility.
     */
    final bool isEffectivelyVisible() {
        for (Widget p = this; p !is null; p = p.parent_) {
            if (!p.visible) {
                return false;
            }
        }
        return true;
    }

    /**
     * Reports whether this widget and all ancestors are enabled.
     *
     * Returns:
     *   Effective enablement.
     */
    final bool isEffectivelyEnabled() {
        for (Widget p = this; p !is null; p = p.parent_) {
            if (!p.enabled) {
                return false;
            }
        }
        return true;
    }

    /**
     * Reports whether this widget holds keyboard focus.
     *
     * Returns:
     *   True if focused.
     */
    final bool isFocused() {
        auto ctx = context();
        return ctx !is null && ctx.focused is this;
    }

    /**
     * Reports whether the pointer hovers this widget directly.
     *
     * Returns:
     *   True if hovered.
     */
    final bool isHovered() {
        auto ctx = context();
        return ctx !is null && ctx.hovered is this;
    }

    /**
     * Requests a redraw from the owning context.
     */
    final void invalidate() {
        if (auto ctx = context()) {
            ctx.needsRedraw = true;
        }
    }

    /**
     * Measures the subtree bottom-up, storing each widget's measuredSize.
     *
     * Params:
     *   m = Text measurer.
     *   theme = Theme metrics.
     */
    final void measureTree(ITextMeasurer m, const ref StudioTheme theme) {
        foreach (c; children_) {
            c.measureTree(m, theme);
        }
        measuredSize = measure(m, theme);
    }

    /**
     * Measure hook: returns this widget's desired size (children are already measured).
     *
     * Params:
     *   m = Text measurer.
     *   theme = Theme metrics.
     *
     * Returns:
     *   Desired size (default: preferredSize).
     */
    Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        return preferredSize;
    }

    /**
     * Assigns bounds and lays out children. When the origin moves, the whole child subtree is translated first, so
     * manually placed children keep their offset relative to this widget.
     *
     * Params:
     *   r = New absolute bounds.
     */
    void arrange(RectF r) {
        immutable float dx = r.x - bounds.x;
        immutable float dy = r.y - bounds.y;
        if (dx != 0.0f || dy != 0.0f) {
            foreach (c; children_) {
                c.translateSubtree(dx, dy);
            }
        }
        bounds = r;
        layoutChildren();
    }

    /**
     * Moves this widget and its whole subtree without re-running layout.
     *
     * Params:
     *   dx = Horizontal offset.
     *   dy = Vertical offset.
     */
    final void translateSubtree(float dx, float dy) {
        bounds = bounds.translate(dx, dy);
        foreach (c; children_) {
            c.translateSubtree(dx, dy);
        }
    }

    /**
     * Arrange hook positioning children inside bounds (default: leaves children at their translated positions).
     */
    void layoutChildren() {
    }

    /**
     * Draws the widget and its children if visible.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    void draw(IRenderer2D r, const ref StudioTheme theme) {
        if (!visible) {
            return;
        }
        paint(r, theme);
        drawChildren(r, theme);
    }

    /**
     * Paint hook for the widget's own visuals (drawn before children).
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    void paint(IRenderer2D r, const ref StudioTheme theme) {
    }

    /**
     * Draws visible children that intersect the active clip.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    void drawChildren(IRenderer2D r, const ref StudioTheme theme) {
        immutable RectF clip = r.currentClip();
        foreach (c; children_) {
            if (c.visible && !c.bounds.intersect(clip).isEmpty()) {
                c.draw(r, theme);
            }
        }
    }

    /**
     * Returns the topmost visible widget in this subtree containing p (later children first).
     *
     * Params:
     *   p = Absolute point.
     *
     * Returns:
     *   Hit widget, or null.
     */
    Widget hitTest(Point2F p) {
        if (!visible || !bounds.contains(p)) {
            return null;
        }
        foreach_reverse (c; children_) {
            if (auto h = c.hitTest(p)) {
                return h;
            }
        }
        return mouseTransparent ? null : this;
    }

    /**
     * Reports whether this widget needs continuous frames (subtree is aggregated by UiContext).
     *
     * Returns:
     *   True while animating.
     */
    bool isAnimating() {
        return false;
    }

    /**
     * Mouse-press handler; handling it captures the mouse until release.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    bool onMouseDown(const ref MouseEvent e) {
        return false;
    }

    /**
     * Mouse-release handler (delivered to the capturing widget if any).
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    bool onMouseUp(const ref MouseEvent e) {
        return false;
    }

    /**
     * Mouse-move handler (drags are delivered to the capturing widget).
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    bool onMouseMove(const ref MouseEvent e) {
        return false;
    }

    /**
     * Scroll handler.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    bool onScroll(const ref ScrollEvent e) {
        return false;
    }

    /**
     * Pinch-zoom handler.
     *
     * Params:
     *   pos = Pointer position.
     *   magnification = Incremental magnification.
     *
     * Returns:
     *   True if handled.
     */
    bool onMagnify(Point2F pos, float magnification) {
        return false;
    }

    /**
     * Key-press handler.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    bool onKeyDown(const ref KeyEvent e) {
        return false;
    }

    /**
     * Key-release handler.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    bool onKeyUp(const ref KeyEvent e) {
        return false;
    }

    /**
     * Committed text input handler.
     *
     * Params:
     *   c = UTF-32 character.
     *
     * Returns:
     *   True if handled.
     */
    bool onTextInput(dchar c) {
        return false;
    }

    /**
     * Called when the pointer starts hovering this widget.
     */
    void onMouseEnter() {
    }

    /**
     * Called when the pointer stops hovering this widget.
     */
    void onMouseLeave() {
    }

    /**
     * Called after this widget gains keyboard focus.
     */
    void onFocusGained() {
    }

    /**
     * Called after this widget loses keyboard focus.
     */
    void onFocusLost() {
    }

    /**
     * Called when an active mouse capture is cancelled without a release (window deactivation, removal).
     */
    void onCaptureLost() {
    }

    /**
     * Called after this widget was removed from the overlay layer.
     */
    void onDismissed() {
    }
}

/**
 * Root event router and frame driver for one window.
 */
final class UiContext {
    StudioTheme theme;
    double doubleClickInterval = 0.4;
    float doubleClickDistance = 4.0f;
    private Widget root_;
    private Widget[] overlays_;
    private Widget focused_;
    private Widget hovered_;
    private Widget captured_;
    private bool needsRedraw_ = true;
    private RectF viewport_;
    private ITextMeasurer measurer_;
    private double delegate() clock_;
    private MonoTime start_;
    private double lastClickTime_ = -1.0e9;
    private Point2F lastClickPos_;
    private MouseButton lastClickButton_ = MouseButton.left;
    private uint clickCount_ = 0;
    private Point2F mousePos_;
    private bool windowFocused_ = true;

    /**
     * Creates a context driving a widget tree.
     *
     * Params:
     *   root = Root widget (receives the full viewport on layout).
     *   clock = Optional monotonic seconds source (defaults to MonoTime); injectable for tests.
     */
    this(Widget root, double delegate() clock = null) {
        assert(root !is null, "UiContext requires a root widget");
        root_ = root;
        root_.context_ = this;
        clock_ = clock;
        start_ = MonoTime.currTime;
    }

    /**
     * Returns the root widget.
     *
     * Returns:
     *   Root.
     */
    Widget root() {
        return root_;
    }

    /**
     * Reports whether the UI changed since the last draw.
     *
     * Returns:
     *   Dirty flag.
     */
    bool needsRedraw() const {
        return needsRedraw_;
    }

    /**
     * Sets or clears the dirty flag.
     *
     * Params:
     *   v = New flag value.
     */
    void needsRedraw(bool v) {
        needsRedraw_ = v;
    }

    /**
     * Reports whether any widget (tree or overlay) requests continuous frames.
     *
     * Returns:
     *   True if the host should keep rendering at display rate.
     */
    bool isAnimating() {
        if (anyAnimating(root_)) {
            return true;
        }
        foreach (o; overlays_) {
            if (anyAnimating(o)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Returns the last layout viewport.
     *
     * Returns:
     *   Viewport rectangle.
     */
    RectF viewport() const {
        return viewport_;
    }

    /**
     * Returns the text measurer from the last layout/draw.
     *
     * Returns:
     *   Measurer, possibly null.
     */
    ITextMeasurer measurer() {
        return measurer_;
    }

    /**
     * Returns the current time from the context clock.
     *
     * Returns:
     *   Seconds.
     */
    double now() {
        if (clock_ !is null) {
            return clock_();
        }
        return cast(double)(MonoTime.currTime - start_).total!"usecs" / 1.0e6;
    }

    /**
     * Returns the focused widget.
     *
     * Returns:
     *   Focused widget, or null.
     */
    Widget focused() {
        return focused_;
    }

    /**
     * Returns the hovered widget.
     *
     * Returns:
     *   Hovered widget, or null.
     */
    Widget hovered() {
        return hovered_;
    }

    /**
     * Returns the widget capturing the mouse.
     *
     * Returns:
     *   Capturing widget, or null.
     */
    Widget captured() {
        return captured_;
    }

    /**
     * Returns the last known pointer position.
     *
     * Returns:
     *   Pointer position.
     */
    Point2F mousePosition() const {
        return mousePos_;
    }

    /**
     * Reports whether the host window is key/focused.
     *
     * Returns:
     *   Window focus state.
     */
    bool windowFocused() const {
        return windowFocused_;
    }

    /**
     * Returns the open overlays, bottom to top.
     *
     * Returns:
     *   Overlay list.
     */
    Widget[] overlays() {
        return overlays_;
    }

    /**
     * Measures (when a measurer is given or remembered) and arranges the root into viewport; re-clamps overlays.
     *
     * Params:
     *   viewport = Window content rectangle in logical points.
     *   m = Optional text measurer (normally the IRenderer2D).
     */
    void layout(RectF viewport, ITextMeasurer m = null) {
        viewport_ = viewport;
        if (m !is null) {
            measurer_ = m;
        }
        if (measurer_ !is null) {
            root_.measureTree(measurer_, theme);
        }
        root_.arrange(viewport);
        foreach (o; overlays_) {
            o.arrange(clampRectInside(o.bounds, viewport));
        }
        needsRedraw_ = true;
    }

    /**
     * Draws the tree then overlays, and clears needsRedraw. Does not begin or end the frame.
     *
     * Params:
     *   r = Renderer (also remembered as the text measurer).
     */
    void draw(IRenderer2D r) {
        measurer_ = r;
        root_.draw(r, theme);
        foreach (o; overlays_) {
            o.draw(r, theme);
        }
        needsRedraw_ = false;
    }

    /**
     * Replaces the theme and draws.
     *
     * Params:
     *   r = Renderer.
     *   t = Theme to adopt.
     */
    void draw(IRenderer2D r, const ref StudioTheme t) {
        theme = t;
        draw(r);
    }

    /**
     * Records a complete frame: beginFrame over the viewport, background clear, draw, endFrame.
     *
     * Params:
     *   r = Renderer.
     *   scaleFactor = Backing scale factor.
     */
    void renderFrame(IRenderer2D r, float scaleFactor) {
        r.beginFrame(viewport_.right(), viewport_.bottom(), scaleFactor);
        r.fillRect(viewport_, theme.background);
        draw(r);
        r.endFrame();
    }

    /**
     * Dispatches a batch of platform events.
     *
     * Params:
     *   events = Events in arrival order.
     *
     * Returns:
     *   True if any event was handled.
     */
    bool handleEvents(const(PlatformEvent)[] events) {
        bool any = false;
        foreach (ref ev; events) {
            any = handleEvent(ev) || any;
        }
        return any;
    }

    /**
     * Converts one PlatformEvent into widget dispatch.
     *
     * Params:
     *   ev = Platform event (mouse coordinates in logical points, top-left origin).
     *
     * Returns:
     *   True if a widget (or the context itself, e.g. overlay dismissal / focus traversal) consumed it.
     */
    bool handleEvent(PlatformEvent ev) {
        switch (ev.kind) {
        case PlatformEventKind.mouseDown:
            return handleMouseDown(ev);
        case PlatformEventKind.mouseUp:
            return handleMouseUp(ev);
        case PlatformEventKind.mouseMove:
            return handleMouseMove(ev);
        case PlatformEventKind.mouseScroll:
            return handleScroll(ev);
        case PlatformEventKind.magnify:
            return handleMagnify(ev);
        case PlatformEventKind.keyDown:
            return handleKeyDown(ev);
        case PlatformEventKind.keyUp:
            return handleKeyUp(ev);
        case PlatformEventKind.textInput:
            return handleTextInput(ev);
        case PlatformEventKind.focusChanged:
            windowFocused_ = ev.focused;
            if (!ev.focused) {
                cancelCapture();
            }
            needsRedraw_ = true;
            return true;
        case PlatformEventKind.resize:
            needsRedraw_ = true;
            return false;
        default:
            return false;
        }
    }

    /**
     * Returns the topmost widget under p, searching overlays (top first) before the root tree.
     *
     * Params:
     *   p = Absolute point.
     *
     * Returns:
     *   Hit widget, or null.
     */
    Widget hitTest(Point2F p) {
        foreach_reverse (o; overlays_) {
            if (auto h = o.hitTest(p)) {
                return h;
            }
        }
        return root_.hitTest(p);
    }

    /**
     * Moves keyboard focus.
     *
     * Params:
     *   w = Focusable, visible, enabled widget, or null to clear focus.
     *
     * Returns:
     *   True if focus now equals w.
     */
    bool setFocus(Widget w) {
        if (w !is null && !canFocus(w)) {
            return false;
        }
        if (w is focused_) {
            return true;
        }
        Widget old = focused_;
        focused_ = w;
        if (old !is null) {
            old.onFocusLost();
        }
        if (w !is null) {
            w.onFocusGained();
        }
        needsRedraw_ = true;
        return true;
    }

    /**
     * Returns focusable widgets of the root tree in depth-first paint order.
     *
     * Returns:
     *   Tab order.
     */
    Widget[] focusOrder() {
        Widget[] order;
        collectFocusable(root_, order);
        return order;
    }

    /**
     * Moves focus to the next focusable widget (wrapping).
     *
     * Returns:
     *   True if focus moved.
     */
    bool focusNext() {
        return stepFocus(1);
    }

    /**
     * Moves focus to the previous focusable widget (wrapping).
     *
     * Returns:
     *   True if focus moved.
     */
    bool focusPrevious() {
        return stepFocus(-1);
    }

    /**
     * Routes all mouse moves and the next release to w.
     *
     * Params:
     *   w = Capturing widget.
     */
    void capture(Widget w) {
        captured_ = w;
    }

    /**
     * Releases mouse capture without notifying the widget.
     */
    void releaseCapture() {
        captured_ = null;
    }

    /**
     * Opens (or raises) a popup in the overlay layer. Callers set the overlay bounds first.
     *
     * Params:
     *   w = Parentless overlay widget.
     */
    void openOverlay(Widget w) {
        assert(w !is null && w.parent_ is null, "overlays must be parentless");
        removeFromOverlayList(w);
        overlays_ ~= w;
        w.context_ = this;
        w.arrange(w.bounds);
        needsRedraw_ = true;
    }

    /**
     * Closes an overlay and calls its onDismissed hook.
     *
     * Params:
     *   w = Overlay to close.
     *
     * Returns:
     *   True if it was open.
     */
    bool closeOverlay(Widget w) {
        if (!removeFromOverlayList(w)) {
            return false;
        }
        widgetDetached(w);
        w.context_ = null;
        needsRedraw_ = true;
        w.onDismissed();
        return true;
    }

    /**
     * Closes every overlay, topmost first.
     */
    void closeAllOverlays() {
        while (overlays_.length > 0) {
            closeOverlay(overlays_[$ - 1]);
        }
    }

    /**
     * Reports whether w is currently open as an overlay.
     *
     * Params:
     *   w = Overlay widget.
     *
     * Returns:
     *   True if open.
     */
    bool isOverlayOpen(const Widget w) const {
        foreach (o; overlays_) {
            if (o is w) {
                return true;
            }
        }
        return false;
    }

    /**
     * Opens a context menu at a point.
     *
     * Params:
     *   items = Menu entries.
     *   at = Requested top-left position.
     *
     * Returns:
     *   The opened menu.
     */
    ContextMenu openContextMenu(MenuItem[] items, Point2F at) {
        auto menu = new ContextMenu(items);
        menu.openAt(this, at);
        return menu;
    }

    /**
     * Drops focus/hover/capture references into a subtree being detached.
     *
     * Params:
     *   w = Subtree root.
     */
    void widgetDetached(Widget w) {
        if (focused_ !is null && w.isAncestorOf(focused_)) {
            Widget old = focused_;
            focused_ = null;
            old.onFocusLost();
        }
        if (hovered_ !is null && w.isAncestorOf(hovered_)) {
            hovered_ = null;
        }
        if (captured_ !is null && w.isAncestorOf(captured_)) {
            Widget old = captured_;
            captured_ = null;
            old.onCaptureLost();
        }
        needsRedraw_ = true;
    }

    private bool handleMouseDown(const ref PlatformEvent ev) {
        immutable Point2F p = Point2F(ev.x, ev.y);
        mousePos_ = p;
        immutable MouseButton button = toButton(ev.mouseButton);
        immutable uint clicks = registerClick(p, button);
        Widget hit = hitTest(p);
        immutable bool inOverlay = hit !is null && overlayOf(hit) !is null;
        if (overlays_.length > 0 && !inOverlay) {
            closeAllOverlays();
            updateHover(p);
            return true;
        }
        if (!inOverlay) {
            focusForClick(hit);
        }
        MouseEvent me = MouseEvent(p, button, ev.modifiers, clicks);
        Widget handler = bubble(hit, (Widget w) => w.onMouseDown(me));
        if (handler !is null) {
            if (overlays_.length == 0 || overlayOf(handler) !is null) {
                captured_ = handler;
            }
            needsRedraw_ = true;
            return true;
        }
        if (button == MouseButton.right && !inOverlay) {
            for (Widget w = hit; w !is null; w = w.parent_) {
                if (w.contextMenuProvider !is null && w.isEffectivelyEnabled()) {
                    MenuItem[] items = w.contextMenuProvider(p);
                    if (items.length > 0) {
                        openContextMenu(items, p);
                        return true;
                    }
                    break;
                }
            }
        }
        return false;
    }

    private bool handleMouseUp(const ref PlatformEvent ev) {
        immutable Point2F p = Point2F(ev.x, ev.y);
        mousePos_ = p;
        MouseEvent me = MouseEvent(p, toButton(ev.mouseButton), ev.modifiers, clickCount_);
        if (captured_ !is null) {
            Widget c = captured_;
            captured_ = null;
            c.onMouseUp(me);
            updateHover(p);
            needsRedraw_ = true;
            return true;
        }
        immutable bool handled = bubble(hitTest(p), (Widget w) => w.onMouseUp(me)) !is null;
        if (handled) {
            needsRedraw_ = true;
        }
        return handled;
    }

    private bool handleMouseMove(const ref PlatformEvent ev) {
        immutable Point2F p = Point2F(ev.x, ev.y);
        mousePos_ = p;
        MouseEvent me = MouseEvent(p, toButton(ev.mouseButton), ev.modifiers, 0);
        if (captured_ !is null) {
            captured_.onMouseMove(me);
            needsRedraw_ = true;
            return true;
        }
        immutable bool hoverChanged = updateHover(p);
        immutable bool handled = bubble(hovered_, (Widget w) => w.onMouseMove(me)) !is null;
        if (handled) {
            needsRedraw_ = true;
        }
        return handled || hoverChanged;
    }

    private bool handleScroll(const ref PlatformEvent ev) {
        immutable Point2F p = Point2F(ev.x, ev.y);
        Widget hit = hitTest(p);
        if (overlays_.length > 0 && (hit is null || overlayOf(hit) is null)) {
            return false;
        }
        ScrollEvent se = ScrollEvent(p, ev.deltaX, ev.deltaY, ev.modifiers);
        immutable bool handled = bubble(hit, (Widget w) => w.onScroll(se)) !is null;
        if (handled) {
            needsRedraw_ = true;
            updateHover(mousePos_);
        }
        return handled;
    }

    private bool handleMagnify(const ref PlatformEvent ev) {
        immutable Point2F p = Point2F(ev.x, ev.y);
        immutable float mag = ev.magnification;
        immutable bool handled = bubble(hitTest(p), (Widget w) => w.onMagnify(p, mag)) !is null;
        if (handled) {
            needsRedraw_ = true;
        }
        return handled;
    }

    private bool handleKeyDown(const ref PlatformEvent ev) {
        KeyEvent ke = KeyEvent(ev.keyCode, ev.modifiers, ev.isRepeat);
        if (overlays_.length > 0) {
            Widget top = overlays_[$ - 1];
            Widget target = focused_ !is null && top.isAncestorOf(focused_) ? focused_ : top;
            if (bubble(target, (Widget w) => w.onKeyDown(ke)) !is null) {
                needsRedraw_ = true;
                return true;
            }
            if (ev.keyCode == KeyCode.escape) {
                closeOverlay(top);
                return true;
            }
            return false;
        }
        Widget target = focused_ !is null ? focused_ : root_;
        if (bubble(target, (Widget w) => w.onKeyDown(ke)) !is null) {
            needsRedraw_ = true;
            return true;
        }
        immutable uint blocking = KeyModifiers.command | KeyModifiers.control | KeyModifiers.alt;
        if (ev.keyCode == KeyCode.tab && (ev.modifiers & blocking) == 0) {
            if (ke.shift()) {
                focusPrevious();
            } else {
                focusNext();
            }
            return true;
        }
        return false;
    }

    private bool handleKeyUp(const ref PlatformEvent ev) {
        KeyEvent ke = KeyEvent(ev.keyCode, ev.modifiers, ev.isRepeat);
        Widget target = overlays_.length > 0 ? overlays_[$ - 1] : (focused_ !is null ? focused_ : root_);
        return bubble(target, (Widget w) => w.onKeyUp(ke)) !is null;
    }

    private bool handleTextInput(const ref PlatformEvent ev) {
        immutable dchar c = ev.utf32Char;
        Widget target = overlays_.length > 0 ? overlays_[$ - 1] : (focused_ !is null ? focused_ : root_);
        immutable bool handled = bubble(target, (Widget w) => w.onTextInput(c)) !is null;
        if (handled) {
            needsRedraw_ = true;
        }
        return handled;
    }

    private Widget bubble(Widget start, scope bool delegate(Widget) fn) {
        for (Widget w = start; w !is null; w = w.parent_) {
            if (w.isEffectivelyEnabled() && fn(w)) {
                return w;
            }
        }
        return null;
    }

    private uint registerClick(Point2F p, MouseButton button) {
        immutable double t = now();
        immutable bool sameSpot = (p - lastClickPos_).length() <= doubleClickDistance;
        if (button == lastClickButton_ && sameSpot && t - lastClickTime_ <= doubleClickInterval) {
            clickCount_++;
        } else {
            clickCount_ = 1;
        }
        lastClickTime_ = t;
        lastClickPos_ = p;
        lastClickButton_ = button;
        return clickCount_;
    }

    private bool updateHover(Point2F p) {
        Widget h = hitTest(p);
        if (h is hovered_) {
            return false;
        }
        Widget old = hovered_;
        hovered_ = h;
        if (old !is null) {
            old.onMouseLeave();
        }
        if (h !is null) {
            h.onMouseEnter();
        }
        needsRedraw_ = true;
        return true;
    }

    private void focusForClick(Widget hit) {
        for (Widget w = hit; w !is null; w = w.parent_) {
            if (canFocus(w)) {
                setFocus(w);
                return;
            }
        }
        setFocus(null);
    }

    private void cancelCapture() {
        if (captured_ !is null) {
            Widget c = captured_;
            captured_ = null;
            c.onCaptureLost();
        }
    }

    private Widget overlayOf(Widget w) {
        Widget top = w;
        while (top.parent_ !is null) {
            top = top.parent_;
        }
        foreach (o; overlays_) {
            if (o is top) {
                return o;
            }
        }
        return null;
    }

    private bool removeFromOverlayList(Widget w) {
        foreach (i, o; overlays_) {
            if (o is w) {
                overlays_ = overlays_[0 .. i] ~ overlays_[i + 1 .. $];
                return true;
            }
        }
        return false;
    }

    private bool stepFocus(int dir) {
        Widget[] order = focusOrder();
        if (order.length == 0) {
            return false;
        }
        ptrdiff_t idx = -1;
        foreach (i, w; order) {
            if (w is focused_) {
                idx = cast(ptrdiff_t) i;
                break;
            }
        }
        immutable ptrdiff_t n = cast(ptrdiff_t) order.length;
        ptrdiff_t next;
        if (idx < 0) {
            next = dir > 0 ? 0 : n - 1;
        } else {
            next = ((idx + dir) % n + n) % n;
        }
        return setFocus(order[next]);
    }

    private static bool canFocus(Widget w) {
        return w.focusable && w.isEffectivelyVisible() && w.isEffectivelyEnabled();
    }

    private static void collectFocusable(Widget w, ref Widget[] order) {
        if (!w.visible || !w.enabled) {
            return;
        }
        if (w.focusable) {
            order ~= w;
        }
        foreach (c; w.children_) {
            collectFocusable(c, order);
        }
    }

    private static bool anyAnimating(Widget w) {
        if (!w.visible) {
            return false;
        }
        if (w.isAnimating()) {
            return true;
        }
        foreach (c; w.children_) {
            if (anyAnimating(c)) {
                return true;
            }
        }
        return false;
    }

    private static MouseButton toButton(ubyte b) @safe nothrow pure @nogc {
        return b == 0 ? MouseButton.left : (b == 1 ? MouseButton.right : MouseButton.other);
    }
}

/**
 * Child layout strategies for Panel.
 */
enum PanelLayout : ubyte {
    manual = 0,
    stack = 1,
    row = 2,
    column = 3
}

/**
 * Container with optional background and stack/row/column layout. In row/column mode each visible child uses its
 * flex item; a child with neither fixed size nor weight uses its measured main-axis size.
 */
class Panel : Widget {
    PanelLayout layoutMode = PanelLayout.manual;
    float gap = 0.0f;
    Insets padding;
    bool drawBackground = true;
    bool raised = false;
    bool drawBorder = false;
    float cornerRadius = 0.0f;
    bool useCustomColor = false;
    ColorRGBA customColor;
    private FlexItem[] itemScratch_;
    private RectF[] rectScratch_;

    /**
     * Creates a panel.
     *
     * Params:
     *   mode = Child layout strategy.
     */
    this(PanelLayout mode = PanelLayout.manual) {
        layoutMode = mode;
    }

    override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        if (preferredSize.x > 0.0f && preferredSize.y > 0.0f) {
            return preferredSize;
        }
        float mainSum = 0.0f;
        float crossMax = 0.0f;
        size_t count = 0;
        immutable bool horizontal = layoutMode == PanelLayout.row;
        foreach (c; children) {
            if (!c.visible) {
                continue;
            }
            immutable float cm = horizontal ? childMain(c, Axis.horizontal) : childMain(c, Axis.vertical);
            immutable float cc = horizontal ? c.measuredSize.y : c.measuredSize.x;
            if (layoutMode == PanelLayout.row || layoutMode == PanelLayout.column) {
                mainSum += cm;
                count++;
            } else {
                mainSum = mainSum > cm ? mainSum : cm;
            }
            crossMax = crossMax > cc ? crossMax : cc;
        }
        if (count > 1) {
            mainSum += gap * cast(float)(count - 1);
        }
        immutable Point2F content = horizontal ? Point2F(mainSum, crossMax) : Point2F(crossMax, mainSum);
        immutable Point2F result = Point2F(content.x + padding.along(Axis.horizontal), content.y + padding.along(Axis.vertical));
        return Point2F(preferredSize.x > 0.0f ? preferredSize.x : result.x, preferredSize.y > 0.0f ? preferredSize.y : result.y);
    }

    override void layoutChildren() {
        final switch (layoutMode) {
        case PanelLayout.manual:
            foreach (c; children) {
                c.arrange(c.bounds);
            }
            break;
        case PanelLayout.stack:
            immutable RectF inner = padding.apply(bounds);
            foreach (c; children) {
                c.arrange(inner);
            }
            break;
        case PanelLayout.row:
            layoutLine(Axis.horizontal);
            break;
        case PanelLayout.column:
            layoutLine(Axis.vertical);
            break;
        }
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        if (drawBackground) {
            immutable ColorRGBA c = useCustomColor ? customColor : (raised ? theme.panelRaised : theme.panel);
            r.fillRoundedRect(bounds, cornerRadius, c);
        }
        if (drawBorder) {
            r.strokeRoundedRect(bounds, cornerRadius, theme.borderWidth, theme.border);
        }
    }

    private float childMain(Widget c, Axis axis) {
        if (c.flex.isFixed()) {
            return c.flex.fixed;
        }
        immutable float measured = axis == Axis.horizontal ? c.measuredSize.x : c.measuredSize.y;
        return measured > c.flex.minSize ? measured : c.flex.minSize;
    }

    private void layoutLine(Axis axis) {
        itemScratch_.length = 0;
        Widget[] shown;
        foreach (c; children) {
            if (!c.visible) {
                continue;
            }
            FlexItem it = c.flex;
            if (!it.isFixed() && !(it.weight > 0.0f)) {
                it.fixed = childMain(c, axis);
            }
            itemScratch_ ~= it;
            shown ~= c;
        }
        rectScratch_.length = itemScratch_.length;
        layoutFlexInto(bounds, itemScratch_, axis, gap, padding, rectScratch_);
        foreach (i, c; shown) {
            c.arrange(rectScratch_[i]);
        }
    }
}

/**
 * Horizontal text alignment.
 */
enum TextAlign : ubyte {
    left = 0,
    center = 1,
    right = 2
}

/**
 * Single-line static text; transparent to the mouse.
 */
class Label : Widget {
    string text;
    FontId font = FontId.ui;
    float fontSize = 0.0f;
    TextAlign alignment = TextAlign.left;
    bool dim = false;
    bool useCustomColor = false;
    ColorRGBA customColor;
    float paddingX = 2.0f;

    /**
     * Creates a label.
     *
     * Params:
     *   t = Text.
     *   a = Alignment.
     */
    this(string t = "", TextAlign a = TextAlign.left) {
        text = t;
        alignment = a;
        mouseTransparent = true;
    }

    /**
     * Resolves the font size against the theme.
     *
     * Params:
     *   theme = Theme.
     *
     * Returns:
     *   Font size in points.
     */
    float resolvedSize(const ref StudioTheme theme) const {
        return fontSize > 0.0f ? fontSize : (font == FontId.mono ? theme.fontSizeMono : theme.fontSizeBody);
    }

    override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        immutable float size = resolvedSize(theme);
        immutable float w = measureTextOr(m, text, font, size) + 2.0f * paddingX;
        immutable float h = lineHeightOr(m, font, size);
        return Point2F(preferredSize.x > 0.0f ? preferredSize.x : w, preferredSize.y > 0.0f ? preferredSize.y : h);
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        if (text.length == 0) {
            return;
        }
        immutable float size = resolvedSize(theme);
        immutable float tw = r.measureText(text, font, size);
        immutable float lh = r.lineHeight(font, size);
        float x = bounds.x + paddingX;
        if (alignment == TextAlign.center) {
            x = bounds.x + (bounds.w - tw) * 0.5f;
        } else if (alignment == TextAlign.right) {
            x = bounds.right() - paddingX - tw;
        }
        immutable ColorRGBA c = !isEffectivelyEnabled() ? theme.textDisabled
            : (useCustomColor ? customColor : (dim ? theme.textDim : theme.text));
        r.drawText(Point2F(x, bounds.y + (bounds.h - lh) * 0.5f), text, font, size, c);
    }
}

/**
 * Push button firing onClick on release inside, or on Return/Space while focused.
 */
class Button : Widget {
    string text;
    void delegate() onClick;
    private bool pressed_ = false;

    /**
     * Creates a button.
     *
     * Params:
     *   t = Caption.
     *   handler = Click handler.
     */
    this(string t = "", void delegate() handler = null) {
        text = t;
        onClick = handler;
        focusable = true;
    }

    /**
     * Reports whether the button is held down.
     *
     * Returns:
     *   Pressed state.
     */
    bool isPressed() const {
        return pressed_;
    }

    /**
     * Programmatically clicks the button.
     */
    void click() {
        if (onClick !is null && isEffectivelyEnabled()) {
            onClick();
        }
        invalidate();
    }

    override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        immutable float w = measureTextOr(m, text, FontId.ui, theme.fontSizeBody) + 2.0f * theme.spacingLg;
        return Point2F(preferredSize.x > 0.0f ? preferredSize.x : w, preferredSize.y > 0.0f ? preferredSize.y : theme.controlHeight);
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        pressed_ = true;
        invalidate();
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        immutable bool fire = pressed_ && bounds.contains(e.pos);
        pressed_ = false;
        if (fire) {
            click();
        }
        invalidate();
        return true;
    }

    override void onCaptureLost() {
        pressed_ = false;
    }

    override bool onKeyDown(const ref KeyEvent e) {
        if (e.keyCode == KeyCode.returnKey || e.keyCode == KeyCode.space || e.keyCode == KeyCode.keypadEnter) {
            click();
            return true;
        }
        return false;
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        immutable bool on = isEffectivelyEnabled();
        ColorRGBA top = theme.panelRaised.brighten(0.04f);
        ColorRGBA bottom = theme.panelRaised;
        if (pressed_) {
            top = theme.accent;
            bottom = theme.accent.brighten(-0.15f);
        } else if (isHovered() && on) {
            top = top.brighten(0.06f);
            bottom = bottom.brighten(0.06f);
        }
        r.fillRoundedRectGradient(bounds, theme.radiusMd, top, bottom);
        r.strokeRoundedRect(bounds, theme.radiusMd, theme.borderWidth, theme.border);
        immutable float size = theme.fontSizeBody;
        immutable float tw = r.measureText(text, FontId.ui, size);
        immutable float lh = r.lineHeight(FontId.ui, size);
        immutable ColorRGBA tc = !on ? theme.textDisabled : (pressed_ ? theme.accentText : theme.text);
        r.drawText(Point2F(bounds.x + (bounds.w - tw) * 0.5f, bounds.y + (bounds.h - lh) * 0.5f), text, FontId.ui, size, tc);
        if (isFocused()) {
            drawFocusRing(r, theme, bounds, theme.radiusMd);
        }
    }
}

/**
 * Switch-style on/off toggle with optional caption.
 */
class Toggle : Widget {
    string text;
    bool checked = false;
    void delegate(bool) onToggle;
    private bool pressed_ = false;

    /**
     * Creates a toggle.
     *
     * Params:
     *   t = Caption.
     *   initial = Initial state.
     *   handler = Change handler.
     */
    this(string t = "", bool initial = false, void delegate(bool) handler = null) {
        text = t;
        checked = initial;
        onToggle = handler;
        focusable = true;
    }

    /**
     * Sets the state.
     *
     * Params:
     *   v = New state.
     *   notify = Whether to call onToggle when the state changes.
     *
     * Returns:
     *   True if the state changed.
     */
    bool setChecked(bool v, bool notify = true) {
        if (v == checked) {
            return false;
        }
        checked = v;
        invalidate();
        if (notify && onToggle !is null) {
            onToggle(v);
        }
        return true;
    }

    /**
     * Flips the state and notifies.
     */
    void toggle() {
        setChecked(!checked);
    }

    /**
     * Returns the switch track rectangle.
     *
     * Returns:
     *   Track rect at the left edge, vertically centred.
     */
    RectF trackRect() const {
        immutable float h = bounds.h < 16.0f ? bounds.h : 16.0f;
        immutable float w = h * 1.8f < bounds.w ? h * 1.8f : bounds.w;
        return RectF(bounds.x, bounds.y + (bounds.h - h) * 0.5f, w, h);
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        pressed_ = true;
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        if (pressed_ && bounds.contains(e.pos)) {
            toggle();
        }
        pressed_ = false;
        return true;
    }

    override void onCaptureLost() {
        pressed_ = false;
    }

    override bool onKeyDown(const ref KeyEvent e) {
        if (e.keyCode == KeyCode.space || e.keyCode == KeyCode.returnKey) {
            toggle();
            return true;
        }
        return false;
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        immutable RectF tr = trackRect();
        immutable bool on = isEffectivelyEnabled();
        immutable float rad = tr.h * 0.5f;
        r.fillRoundedRect(tr, rad, checked ? (on ? theme.accent : theme.textDisabled) : theme.panelSunken);
        r.strokeRoundedRect(tr, rad, theme.borderWidth, theme.border);
        immutable float knobR = rad - 2.0f > 1.0f ? rad - 2.0f : 1.0f;
        immutable float cx = checked ? tr.right() - rad : tr.x + rad;
        fillCircle(r, Point2F(cx, tr.y + rad), knobR, on ? theme.text : theme.textDim);
        if (text.length > 0) {
            immutable float size = theme.fontSizeBody;
            immutable float lh = r.lineHeight(FontId.ui, size);
            r.drawText(Point2F(tr.right() + theme.spacingMd, bounds.y + (bounds.h - lh) * 0.5f), text, FontId.ui, size,
                on ? theme.text : theme.textDisabled);
        }
        if (isFocused()) {
            drawFocusRing(r, theme, tr, rad);
        }
    }
}

/**
 * Value domain shared by sliders, knobs and numeric boxes, with optional logarithmic mapping and stepping.
 */
struct ValueRange {
    float min = 0.0f;
    float max = 1.0f;
    float defaultValue = 0.0f;
    bool logarithmic = false;
    float step = 0.0f;

    @safe nothrow pure @nogc:

    /**
     * Reports whether logarithmic mapping is active (requires 0 < min < max).
     *
     * Returns:
     *   True if values map exponentially to the normalized domain.
     */
    bool usesLog() const {
        return logarithmic && min > 0.0f && max > min;
    }

    /**
     * Clamps a value into [min, max]; NaN maps to the clamped default.
     *
     * Params:
     *   v = Value.
     *
     * Returns:
     *   Clamped value.
     */
    float clamp(float v) const {
        immutable float lo = min < max ? min : max;
        immutable float hi = min < max ? max : min;
        if (!isFinite(v)) {
            if (v == float.infinity) {
                return hi;
            }
            if (v == -float.infinity) {
                return lo;
            }
            return clampf(defaultValue, lo, hi);
        }
        return clampf(v, lo, hi);
    }

    /**
     * Snaps a value to the step grid (if any) and clamps it.
     *
     * Params:
     *   v = Value.
     *
     * Returns:
     *   Quantized value.
     */
    float quantize(float v) const {
        immutable float c = clamp(v);
        if (!(step > 0.0f)) {
            return c;
        }
        return clamp(min + round((c - min) / step) * step);
    }

    /**
     * Maps a value to [0, 1].
     *
     * Params:
     *   v = Value.
     *
     * Returns:
     *   Normalized position.
     */
    float toNormalized(float v) const {
        immutable float c = clamp(v);
        if (max == min) {
            return 0.0f;
        }
        if (usesLog()) {
            return clampf(cast(float)(log(c / min) / log(max / min)), 0.0f, 1.0f);
        }
        return clampf((c - min) / (max - min), 0.0f, 1.0f);
    }

    /**
     * Maps a normalized position to a quantized value.
     *
     * Params:
     *   n = Position (clamped to [0, 1]).
     *
     * Returns:
     *   Value.
     */
    float fromNormalized(float n) const {
        immutable float t = clampf(n, 0.0f, 1.0f);
        if (usesLog()) {
            return quantize(cast(float)(min * exp(t * log(max / min))));
        }
        return quantize(min + t * (max - min));
    }
}

/**
 * Base for continuous controls: value storage, onChange, relative drags with Shift fine mode (re-anchored when Shift
 * toggles mid-drag), Alt-click / double-click reset to default, and arrow/Home/End keyboard stepping.
 */
abstract class ValueWidget : Widget {
    ValueRange range;
    void delegate(float) onChange;
    float fineFactor = 0.1f;
    float keyboardStep = 0.01f;
    private float value_ = 0.0f;
    private bool dragging_ = false;
    private Point2F anchorPos_;
    private float anchorNorm_ = 0.0f;
    private bool anchorFine_ = false;

    /**
     * Creates the control at its default value.
     *
     * Params:
     *   r = Value range.
     */
    this(ValueRange r) {
        range = r;
        value_ = r.quantize(r.defaultValue);
        focusable = true;
    }

    /**
     * Returns the current value.
     *
     * Returns:
     *   Value.
     */
    float value() const {
        return value_;
    }

    /**
     * Returns the current normalized position.
     *
     * Returns:
     *   Position in [0, 1].
     */
    float normalizedValue() const {
        return range.toNormalized(value_);
    }

    /**
     * Sets the value (quantized and clamped).
     *
     * Params:
     *   v = New value.
     *   notify = Whether to call onChange when it changes.
     *
     * Returns:
     *   True if the value changed.
     */
    bool setValue(float v, bool notify = true) {
        immutable float nv = range.quantize(v);
        if (nv == value_) {
            return false;
        }
        value_ = nv;
        invalidate();
        if (notify && onChange !is null) {
            onChange(nv);
        }
        return true;
    }

    /**
     * Sets the value from a normalized position.
     *
     * Params:
     *   n = Position.
     *   notify = Whether to notify.
     *
     * Returns:
     *   True if the value changed.
     */
    bool setNormalized(float n, bool notify = true) {
        return setValue(range.fromNormalized(n), notify);
    }

    /**
     * Restores the default value.
     *
     * Returns:
     *   True if the value changed.
     */
    bool resetToDefault() {
        return setValue(range.defaultValue);
    }

    /**
     * Reports whether a value drag is active.
     *
     * Returns:
     *   Drag state.
     */
    bool isDragging() const {
        return dragging_;
    }

    /**
     * Returns the signed drag distance in points between two pointer positions (positive increases the value).
     *
     * Params:
     *   from = Anchor position.
     *   to = Current position.
     *
     * Returns:
     *   Distance in points.
     */
    protected abstract float dragDelta(Point2F from, Point2F to);

    /**
     * Returns the drag distance in points that sweeps the full normalized range at coarse speed.
     *
     * Returns:
     *   Span in points (> 0).
     */
    protected abstract float dragSpan();

    /**
     * Press hook called before a drag begins (sliders jump to the click position here).
     *
     * Params:
     *   e = Mouse event.
     */
    protected void pressAt(const ref MouseEvent e) {
    }

    /**
     * Double-click hook (default: reset to default).
     *
     * Params:
     *   e = Mouse event.
     */
    protected void doubleClicked(const ref MouseEvent e) {
        resetToDefault();
    }

    /**
     * Applies a keyboard increment: one step for stepped ranges, otherwise units * keyboardStep normalized.
     *
     * Params:
     *   units = Signed increment (fractional with Shift).
     */
    void stepBy(float units) {
        if (range.step > 0.0f) {
            setValue(value_ + (units > 0.0f ? range.step : -range.step));
        } else {
            setNormalized(normalizedValue() + units * keyboardStep);
        }
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        if (e.clickCount >= 2) {
            dragging_ = false;
            doubleClicked(e);
            return true;
        }
        if (e.alt()) {
            resetToDefault();
            return true;
        }
        pressAt(e);
        dragging_ = true;
        anchorPos_ = e.pos;
        anchorNorm_ = normalizedValue();
        anchorFine_ = e.shift();
        invalidate();
        return true;
    }

    override bool onMouseMove(const ref MouseEvent e) {
        if (!dragging_) {
            return false;
        }
        immutable bool fine = e.shift();
        if (fine != anchorFine_) {
            anchorPos_ = e.pos;
            anchorNorm_ = normalizedValue();
            anchorFine_ = fine;
            return true;
        }
        immutable float span = dragSpan() > 1.0f ? dragSpan() : 1.0f;
        immutable float delta = dragDelta(anchorPos_, e.pos) / span * (fine ? fineFactor : 1.0f);
        setNormalized(anchorNorm_ + delta);
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        dragging_ = false;
        invalidate();
        return true;
    }

    override void onCaptureLost() {
        dragging_ = false;
    }

    override bool onKeyDown(const ref KeyEvent e) {
        immutable float unit = e.shift() ? fineFactor : 1.0f;
        switch (e.keyCode) {
        case KeyCode.up:
        case KeyCode.right:
            stepBy(unit);
            return true;
        case KeyCode.down:
        case KeyCode.left:
            stepBy(-unit);
            return true;
        case KeyCode.home:
            setNormalized(0.0f);
            return true;
        case KeyCode.end:
            setNormalized(1.0f);
            return true;
        default:
            return false;
        }
    }
}

/**
 * Linear fader. Clicking the track jumps to the pointer (unless Shift is held), then drags relatively.
 */
class Slider : ValueWidget {
    Axis orientation = Axis.horizontal;
    float thumbSize = 12.0f;
    float trackThickness = 4.0f;

    /**
     * Creates a slider.
     *
     * Params:
     *   r = Value range.
     *   o = Orientation (vertical sliders increase upward).
     */
    this(ValueRange r, Axis o = Axis.horizontal) {
        super(r);
        orientation = o;
    }

    /**
     * Returns the travel track (thumb centre range).
     *
     * Returns:
     *   Track rectangle.
     */
    RectF trackRect() const {
        immutable float half = thumbSize * 0.5f;
        immutable Point2F c = bounds.center();
        if (orientation == Axis.horizontal) {
            immutable float len = bounds.w - thumbSize > 0.0f ? bounds.w - thumbSize : 0.0f;
            return RectF(bounds.x + half, c.y - trackThickness * 0.5f, len, trackThickness);
        }
        immutable float len = bounds.h - thumbSize > 0.0f ? bounds.h - thumbSize : 0.0f;
        return RectF(c.x - trackThickness * 0.5f, bounds.y + half, trackThickness, len);
    }

    /**
     * Returns the thumb centre for the current value.
     *
     * Returns:
     *   Thumb centre.
     */
    Point2F thumbCenter() const {
        immutable RectF t = trackRect();
        immutable float n = normalizedValue();
        immutable Point2F c = bounds.center();
        return orientation == Axis.horizontal ? Point2F(t.x + n * t.w, c.y) : Point2F(c.x, t.bottom() - n * t.h);
    }

    /**
     * Returns the thumb rectangle.
     *
     * Returns:
     *   Thumb rect.
     */
    RectF thumbRect() const {
        immutable Point2F c = thumbCenter();
        return RectF(c.x - thumbSize * 0.5f, c.y - thumbSize * 0.5f, thumbSize, thumbSize);
    }

    /**
     * Maps a pointer position to a normalized value along the track.
     *
     * Params:
     *   p = Pointer.
     *
     * Returns:
     *   Normalized position in [0, 1].
     */
    float positionToNormalized(Point2F p) const {
        immutable RectF t = trackRect();
        if (orientation == Axis.horizontal) {
            return t.w > 0.0f ? clampf((p.x - t.x) / t.w, 0.0f, 1.0f) : 0.0f;
        }
        return t.h > 0.0f ? clampf((t.bottom() - p.y) / t.h, 0.0f, 1.0f) : 0.0f;
    }

    protected override float dragDelta(Point2F from, Point2F to) {
        return orientation == Axis.horizontal ? to.x - from.x : from.y - to.y;
    }

    protected override float dragSpan() {
        immutable RectF t = trackRect();
        return orientation == Axis.horizontal ? t.w : t.h;
    }

    protected override void pressAt(const ref MouseEvent e) {
        if (!e.shift() && !thumbRect().contains(e.pos)) {
            setNormalized(positionToNormalized(e.pos));
        }
    }

    override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        if (preferredSize.x > 0.0f && preferredSize.y > 0.0f) {
            return preferredSize;
        }
        return orientation == Axis.horizontal ? Point2F(120.0f, theme.controlHeight) : Point2F(theme.controlHeight, 120.0f);
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        immutable RectF t = trackRect();
        immutable bool on = isEffectivelyEnabled();
        immutable float rad = trackThickness * 0.5f;
        r.fillRoundedRect(t.inset(-rad), rad, theme.panelSunken);
        immutable Point2F tc = thumbCenter();
        immutable RectF filled = orientation == Axis.horizontal
            ? RectF(t.x - rad, t.y, tc.x - t.x + rad, t.h)
            : RectF(t.x, tc.y, t.w, t.bottom() - tc.y + rad);
        r.fillRoundedRect(filled, rad, on ? theme.accent : theme.textDisabled);
        immutable bool hot = isDragging() || isHovered();
        fillCircle(r, tc, thumbSize * 0.5f, on ? (hot ? theme.accentHot : theme.text) : theme.textDim);
        if (isFocused()) {
            drawFocusRing(r, theme, thumbRect(), thumbSize * 0.5f);
        }
    }
}

/**
 * Rotary knob controlled by vertical drags (up increases), sweeping 270 degrees.
 */
class RotaryKnob : ValueWidget {
    float dragRange = 200.0f;
    float arcWidth = 3.0f;
    private Point2F[] arcScratch_;

    /**
     * Creates a knob.
     *
     * Params:
     *   r = Value range.
     */
    this(ValueRange r) {
        super(r);
    }

    /**
     * Returns the pointer angle in radians (screen coordinates, y down) for a normalized value.
     *
     * Params:
     *   n = Normalized value.
     *
     * Returns:
     *   Angle: 0.75 pi at minimum through 2.25 pi at maximum (clockwise via the top).
     */
    static float angleFor(float n) @safe nothrow pure @nogc {
        return cast(float)(PI * 0.75 + PI * 1.5 * clampf(n, 0.0f, 1.0f));
    }

    /**
     * Returns the knob radius.
     *
     * Returns:
     *   Radius in points.
     */
    float radius() const {
        immutable float s = bounds.w < bounds.h ? bounds.w : bounds.h;
        immutable float rr = s * 0.5f - arcWidth;
        return rr > 1.0f ? rr : 1.0f;
    }

    protected override float dragDelta(Point2F from, Point2F to) {
        return from.y - to.y;
    }

    protected override float dragSpan() {
        return dragRange;
    }

    override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        return preferredSize.x > 0.0f ? preferredSize : Point2F(theme.knobSize, theme.knobSize);
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        immutable Point2F c = bounds.center();
        immutable float rad = radius();
        immutable bool on = isEffectivelyEnabled();
        immutable float n = normalizedValue();
        drawArc(r, c, rad, 0.0f, 1.0f, theme.border);
        if (n > 0.0f) {
            drawArc(r, c, rad, 0.0f, n, on ? theme.accent : theme.textDisabled);
        }
        immutable float bodyR = rad * 0.72f;
        fillCircle(r, c, bodyR, isHovered() || isDragging() ? theme.panelRaised.brighten(0.06f) : theme.panelRaised);
        immutable float a = angleFor(n);
        immutable Point2F tip = Point2F(c.x + cos(a) * bodyR, c.y + sin(a) * bodyR);
        r.drawLine(Point2F(c.x + cos(a) * bodyR * 0.35f, c.y + sin(a) * bodyR * 0.35f), tip, 2.0f, on ? theme.text : theme.textDim);
        if (isFocused()) {
            drawFocusRing(r, theme, RectF(c.x - rad, c.y - rad, rad * 2.0f, rad * 2.0f), rad);
        }
    }

    private void drawArc(IRenderer2D r, Point2F c, float rad, float n0, float n1, ColorRGBA color) {
        immutable size_t segs = 2 + cast(size_t)(40.0f * (n1 - n0));
        arcScratch_.length = segs + 1;
        foreach (i; 0 .. segs + 1) {
            immutable float a = angleFor(n0 + (n1 - n0) * cast(float) i / cast(float) segs);
            arcScratch_[i] = Point2F(c.x + cos(a) * rad, c.y + sin(a) * rad);
        }
        r.drawPolyline(arcScratch_, arcWidth, color);
    }
}

/**
 * Numeric field changed by dragging (right/up increases, pixelsPerStep points per step), arrows, or typed text:
 * Return or double-click starts editing, typing a digit starts editing with that digit, Return commits,
 * Escape cancels, focus loss commits.
 */
class NumericDragBox : ValueWidget {
    float pixelsPerStep = 4.0f;
    int decimals = 2;
    string suffix;
    string delegate(float) formatter;
    private bool editing_ = false;
    private bool replaceOnType_ = false;
    private char[] editBuffer_;

    /**
     * Creates a numeric box.
     *
     * Params:
     *   r = Value range (step > 0 makes drags step-quantized).
     *   decimalPlaces = Digits after the decimal point in the default format.
     */
    this(ValueRange r, int decimalPlaces = 2) {
        super(r);
        decimals = decimalPlaces;
    }

    /**
     * Formats a value for display.
     *
     * Params:
     *   v = Value.
     *
     * Returns:
     *   Display text.
     */
    string formatValue(float v) {
        if (formatter !is null) {
            return formatter(v);
        }
        return format("%.*f", decimals, v) ~ suffix;
    }

    /**
     * Returns the current display text (edit buffer while editing).
     *
     * Returns:
     *   Text.
     */
    string displayText() {
        return editing_ ? editBuffer_.idup : formatValue(value());
    }

    /**
     * Reports whether text editing is active.
     *
     * Returns:
     *   Edit state.
     */
    bool isEditing() const {
        return editing_;
    }

    /**
     * Returns the edit buffer.
     *
     * Returns:
     *   Edit text.
     */
    const(char)[] editText() const {
        return editBuffer_;
    }

    /**
     * Starts editing with the current value; the first typed character replaces it.
     */
    void beginEdit() {
        editing_ = true;
        replaceOnType_ = true;
        editBuffer_ = format("%.*f", decimals, value()).dup;
        if (auto ctx = context()) {
            ctx.setFocus(this);
        }
        invalidate();
    }

    /**
     * Parses and applies the edit buffer, leaving edit mode; invalid text restores the previous value.
     *
     * Returns:
     *   True if the text parsed.
     */
    bool commitEdit() {
        if (!editing_) {
            return false;
        }
        editing_ = false;
        invalidate();
        float parsed = 0.0f;
        try {
            parsed = to!float(editBuffer_);
        } catch (Exception) {
            return false;
        }
        if (!isFinite(parsed)) {
            return false;
        }
        setValue(parsed);
        return true;
    }

    /**
     * Leaves edit mode without applying.
     */
    void cancelEdit() {
        editing_ = false;
        invalidate();
    }

    protected override float dragDelta(Point2F from, Point2F to) {
        return (to.x - from.x) + (from.y - to.y);
    }

    protected override float dragSpan() {
        if (range.step > 0.0f) {
            immutable float steps = abs(range.max - range.min) / range.step;
            return pixelsPerStep * (steps > 1.0f ? steps : 1.0f);
        }
        return pixelsPerStep * 100.0f;
    }

    protected override void doubleClicked(const ref MouseEvent e) {
        beginEdit();
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (editing_) {
            return e.button == MouseButton.left;
        }
        return super.onMouseDown(e);
    }

    override bool onTextInput(dchar c) {
        immutable bool numeric = (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E';
        if (!numeric) {
            return editing_;
        }
        if (!editing_) {
            beginEdit();
        }
        if (replaceOnType_) {
            editBuffer_.length = 0;
            replaceOnType_ = false;
        }
        editBuffer_ ~= cast(char) c;
        invalidate();
        return true;
    }

    override bool onKeyDown(const ref KeyEvent e) {
        if (!editing_) {
            if (e.keyCode == KeyCode.returnKey || e.keyCode == KeyCode.keypadEnter) {
                beginEdit();
                return true;
            }
            return super.onKeyDown(e);
        }
        switch (e.keyCode) {
        case KeyCode.returnKey:
        case KeyCode.keypadEnter:
            commitEdit();
            return true;
        case KeyCode.escape:
            cancelEdit();
            return true;
        case KeyCode.deleteBackward:
            if (replaceOnType_) {
                editBuffer_.length = 0;
                replaceOnType_ = false;
            } else if (editBuffer_.length > 0) {
                editBuffer_.length = editBuffer_.length - 1;
            }
            invalidate();
            return true;
        case KeyCode.tab:
            commitEdit();
            return false;
        default:
            return true;
        }
    }

    override void onFocusLost() {
        if (editing_) {
            commitEdit();
        }
    }

    override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        if (preferredSize.x > 0.0f && preferredSize.y > 0.0f) {
            return preferredSize;
        }
        immutable float w = measureTextOr(m, formatValue(range.max), FontId.mono, theme.fontSizeMono) + 2.0f * theme.spacingMd;
        return Point2F(w, theme.controlHeight);
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        immutable bool on = isEffectivelyEnabled();
        r.fillRoundedRect(bounds, theme.radiusSm, editing_ ? theme.panelSunken.brighten(0.04f) : theme.panelSunken);
        r.strokeRoundedRect(bounds, theme.radiusSm, theme.borderWidth, isDragging() ? theme.accent : theme.border);
        immutable string txt = displayText();
        immutable float size = theme.fontSizeMono;
        immutable float tw = r.measureText(txt, FontId.mono, size);
        immutable float lh = r.lineHeight(FontId.mono, size);
        immutable float tx = bounds.x + (bounds.w - tw) * 0.5f;
        immutable float ty = bounds.y + (bounds.h - lh) * 0.5f;
        if (editing_ && replaceOnType_ && tw > 0.0f) {
            r.fillRect(RectF(tx, ty, tw, lh), theme.selection);
        }
        r.drawText(Point2F(tx, ty), txt, FontId.mono, size, !on ? theme.textDisabled : (isDragging() ? theme.accentHot : theme.text));
        if (editing_) {
            r.fillRect(RectF(tx + tw + 1.0f, ty, 1.0f, lh), theme.accentHot);
        }
        if (isFocused()) {
            drawFocusRing(r, theme, bounds, theme.radiusSm);
        }
    }
}

/**
 * Popup choice list shown in the overlay layer by Dropdown.
 */
class DropdownList : Widget {
    Dropdown owner;
    size_t highlighted = 0;
    size_t firstVisible = 0;
    size_t visibleCount = 0;
    float itemHeight = 22.0f;
    float paddingY = 4.0f;
    private float scrollAccum_ = 0.0f;
    private bool pressed_ = false;

    /**
     * Creates a list bound to a dropdown.
     *
     * Params:
     *   o = Owning dropdown.
     */
    this(Dropdown o) {
        owner = o;
        highlighted = o.selectedIndex < o.items.length ? o.selectedIndex : 0;
    }

    /**
     * Returns the rectangle of an item, or an empty rect when scrolled out.
     *
     * Params:
     *   i = Item index.
     *
     * Returns:
     *   Item rectangle.
     */
    RectF itemRect(size_t i) const {
        if (i < firstVisible || i >= firstVisible + visibleCount) {
            return RectF.init;
        }
        return RectF(bounds.x, bounds.y + paddingY + cast(float)(i - firstVisible) * itemHeight, bounds.w, itemHeight);
    }

    /**
     * Returns the item under a point.
     *
     * Params:
     *   p = Point.
     *
     * Returns:
     *   Item index, or -1.
     */
    ptrdiff_t itemAt(Point2F p) const {
        foreach (i; firstVisible .. firstVisible + visibleCount) {
            if (itemRect(i).contains(p)) {
                return cast(ptrdiff_t) i;
            }
        }
        return -1;
    }

    /**
     * Moves the highlight, scrolling it into view.
     *
     * Params:
     *   i = New highlighted index (clamped).
     */
    void setHighlight(size_t i) {
        if (owner.items.length == 0) {
            return;
        }
        highlighted = i < owner.items.length ? i : owner.items.length - 1;
        if (highlighted < firstVisible) {
            firstVisible = highlighted;
        } else if (highlighted >= firstVisible + visibleCount) {
            firstVisible = highlighted + 1 - visibleCount;
        }
        invalidate();
    }

    override bool onMouseMove(const ref MouseEvent e) {
        immutable ptrdiff_t i = itemAt(e.pos);
        if (i >= 0 && cast(size_t) i != highlighted) {
            highlighted = cast(size_t) i;
            invalidate();
        }
        return true;
    }

    override bool onMouseDown(const ref MouseEvent e) {
        pressed_ = true;
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        immutable ptrdiff_t i = itemAt(e.pos);
        if (pressed_ && i >= 0) {
            choose(cast(size_t) i);
        }
        pressed_ = false;
        return true;
    }

    override bool onScroll(const ref ScrollEvent e) {
        immutable size_t n = owner.items.length;
        if (n <= visibleCount) {
            return true;
        }
        scrollAccum_ -= e.deltaY;
        while (scrollAccum_ >= itemHeight && firstVisible + visibleCount < n) {
            firstVisible++;
            scrollAccum_ -= itemHeight;
        }
        while (scrollAccum_ <= -itemHeight && firstVisible > 0) {
            firstVisible--;
            scrollAccum_ += itemHeight;
        }
        invalidate();
        return true;
    }

    override bool onKeyDown(const ref KeyEvent e) {
        immutable size_t n = owner.items.length;
        switch (e.keyCode) {
        case KeyCode.up:
            setHighlight(highlighted > 0 ? highlighted - 1 : 0);
            return true;
        case KeyCode.down:
            setHighlight(highlighted + 1 < n ? highlighted + 1 : highlighted);
            return true;
        case KeyCode.home:
            setHighlight(0);
            return true;
        case KeyCode.end:
            setHighlight(n > 0 ? n - 1 : 0);
            return true;
        case KeyCode.returnKey:
        case KeyCode.keypadEnter:
        case KeyCode.space:
            if (n > 0) {
                choose(highlighted);
            }
            return true;
        default:
            return false;
        }
    }

    override void onDismissed() {
        owner.popupDismissed(this);
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        r.fillRoundedRect(bounds.translate(0.0f, 2.0f), theme.radiusMd, theme.shadow);
        r.fillRoundedRect(bounds, theme.radiusMd, theme.panelRaised);
        r.strokeRoundedRect(bounds, theme.radiusMd, theme.borderWidth, theme.borderStrong);
        immutable float size = theme.fontSizeBody;
        immutable float lh = r.lineHeight(FontId.ui, size);
        foreach (i; firstVisible .. firstVisible + visibleCount) {
            immutable RectF ir = itemRect(i);
            if (i == highlighted) {
                r.fillRoundedRect(ir.inset(2.0f), theme.radiusSm, theme.accent);
            }
            immutable ColorRGBA tc = i == highlighted ? theme.accentText : (i == owner.selectedIndex ? theme.accentHot : theme.text);
            r.drawText(Point2F(ir.x + theme.spacingMd, ir.y + (ir.h - lh) * 0.5f), owner.items[i], FontId.ui, size, tc);
        }
    }

    private void choose(size_t i) {
        Dropdown o = owner;
        if (auto ctx = context()) {
            ctx.closeOverlay(this);
        }
        o.select(i);
    }
}

/**
 * Pop-up choice control. Click / Return / Space opens the list overlay; Up/Down while closed changes the selection.
 */
class Dropdown : Widget {
    string[] items;
    size_t selectedIndex = 0;
    void delegate(size_t) onSelect;
    size_t maxVisibleItems = 10;
    private DropdownList popup_;

    /**
     * Creates a dropdown.
     *
     * Params:
     *   choices = Item labels.
     *   initial = Initially selected index.
     *   handler = Selection handler.
     */
    this(string[] choices, size_t initial = 0, void delegate(size_t) handler = null) {
        items = choices;
        selectedIndex = initial < choices.length ? initial : 0;
        onSelect = handler;
        focusable = true;
    }

    /**
     * Returns the selected label.
     *
     * Returns:
     *   Label, or "" when empty.
     */
    string selectedText() const {
        return selectedIndex < items.length ? items[selectedIndex] : "";
    }

    /**
     * Reports whether the popup is open.
     *
     * Returns:
     *   True if open.
     */
    bool isOpen() const {
        return popup_ !is null;
    }

    /**
     * Returns the open popup.
     *
     * Returns:
     *   Popup, or null.
     */
    DropdownList popup() {
        return popup_;
    }

    /**
     * Selects an item.
     *
     * Params:
     *   i = Item index.
     *   notify = Whether to call onSelect when it changes.
     *
     * Returns:
     *   True if the selection changed.
     */
    bool select(size_t i, bool notify = true) {
        if (i >= items.length || i == selectedIndex) {
            return false;
        }
        selectedIndex = i;
        invalidate();
        if (notify && onSelect !is null) {
            onSelect(i);
        }
        return true;
    }

    /**
     * Opens the popup below (or above, when there is more room) the control, clamped to the viewport.
     *
     * Returns:
     *   True if opened.
     */
    bool open() {
        auto ctx = context();
        if (ctx is null || popup_ !is null || items.length == 0) {
            return false;
        }
        auto list = new DropdownList(this);
        list.itemHeight = ctx.theme.menuItemHeight;
        list.visibleCount = items.length < maxVisibleItems ? items.length : maxVisibleItems;
        float w = bounds.w;
        foreach (it; items) {
            immutable float iw = measureTextOr(ctx.measurer(), it, FontId.ui, ctx.theme.fontSizeBody) + 2.0f * ctx.theme.spacingMd;
            w = iw > w ? iw : w;
        }
        immutable float h = cast(float) list.visibleCount * list.itemHeight + 2.0f * list.paddingY;
        immutable RectF vp = ctx.viewport();
        float y = bounds.bottom() + 2.0f;
        if (y + h > vp.bottom() && bounds.y - vp.y > vp.bottom() - bounds.bottom()) {
            y = bounds.y - 2.0f - h;
        }
        list.bounds = vp.isEmpty() ? RectF(bounds.x, y, w, h) : clampRectInside(RectF(bounds.x, y, w, h), vp);
        list.setHighlight(list.highlighted);
        popup_ = list;
        ctx.openOverlay(list);
        invalidate();
        return true;
    }

    /**
     * Closes the popup without changing the selection.
     */
    void close() {
        if (popup_ is null) {
            return;
        }
        if (auto ctx = popup_.context()) {
            ctx.closeOverlay(popup_);
        }
        popup_ = null;
    }

    /**
     * Called by the popup when it leaves the overlay layer.
     *
     * Params:
     *   list = Dismissed popup.
     */
    void popupDismissed(DropdownList list) {
        if (popup_ is list) {
            popup_ = null;
        }
        invalidate();
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        if (isOpen()) {
            close();
        } else {
            open();
        }
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        return true;
    }

    override bool onKeyDown(const ref KeyEvent e) {
        switch (e.keyCode) {
        case KeyCode.returnKey:
        case KeyCode.keypadEnter:
        case KeyCode.space:
            open();
            return true;
        case KeyCode.up:
            if (selectedIndex > 0) {
                select(selectedIndex - 1);
            }
            return true;
        case KeyCode.down:
            if (selectedIndex + 1 < items.length) {
                select(selectedIndex + 1);
            }
            return true;
        default:
            return false;
        }
    }

    override void onDismissed() {
        close();
    }

    override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        if (preferredSize.x > 0.0f && preferredSize.y > 0.0f) {
            return preferredSize;
        }
        float w = 0.0f;
        foreach (it; items) {
            immutable float iw = measureTextOr(m, it, FontId.ui, theme.fontSizeBody);
            w = iw > w ? iw : w;
        }
        return Point2F(w + 2.0f * theme.spacingMd + 16.0f, theme.controlHeight);
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        immutable bool on = isEffectivelyEnabled();
        r.fillRoundedRectGradient(bounds, theme.radiusMd, theme.panelRaised.brighten(isHovered() ? 0.08f : 0.04f), theme.panelRaised);
        r.strokeRoundedRect(bounds, theme.radiusMd, theme.borderWidth, isOpen() ? theme.accent : theme.border);
        immutable float size = theme.fontSizeBody;
        immutable float lh = r.lineHeight(FontId.ui, size);
        r.drawText(Point2F(bounds.x + theme.spacingMd, bounds.y + (bounds.h - lh) * 0.5f), selectedText(), FontId.ui, size,
            on ? theme.text : theme.textDisabled);
        immutable float ax = bounds.right() - 12.0f;
        immutable float ay = bounds.center().y;
        r.drawLine(Point2F(ax - 4.0f, ay - 2.0f), Point2F(ax, ay + 2.0f), 1.5f, theme.textDim);
        r.drawLine(Point2F(ax, ay + 2.0f), Point2F(ax + 4.0f, ay - 2.0f), 1.5f, theme.textDim);
        if (isFocused()) {
            drawFocusRing(r, theme, bounds, theme.radiusMd);
        }
    }
}

/**
 * Overlay command menu. Enabled items run their action after the menu closes; disabled items and separators
 * ignore clicks. Up/Down skip non-selectable entries; Return activates; Escape (via UiContext) closes.
 */
class ContextMenu : Widget {
    MenuItem[] items;
    ptrdiff_t highlighted = -1;
    float itemHeight = 22.0f;
    float separatorHeight = 7.0f;
    float paddingY = 4.0f;
    float minWidth = 140.0f;
    void delegate() onClosed;
    private bool pressed_ = false;

    /**
     * Creates a menu.
     *
     * Params:
     *   entries = Menu entries.
     */
    this(MenuItem[] entries) {
        items = entries;
    }

    /**
     * Sizes the menu, clamps it into the viewport and opens it at a point.
     *
     * Params:
     *   ctx = Context.
     *   at = Requested top-left.
     */
    void openAt(UiContext ctx, Point2F at) {
        itemHeight = ctx.theme.menuItemHeight;
        float w = minWidth;
        immutable float size = ctx.theme.fontSizeBody;
        foreach (ref it; items) {
            if (it.separator) {
                continue;
            }
            float iw = measureTextOr(ctx.measurer(), it.label, FontId.ui, size) + 2.0f * ctx.theme.spacingLg;
            if (it.shortcut.length > 0) {
                iw += measureTextOr(ctx.measurer(), it.shortcut, FontId.ui, ctx.theme.fontSizeSmall) + ctx.theme.spacingXl;
            }
            w = iw > w ? iw : w;
        }
        immutable RectF wanted = RectF(at.x, at.y, w, contentHeight());
        immutable RectF vp = ctx.viewport();
        bounds = vp.isEmpty() ? wanted : clampRectInside(wanted, vp);
        highlighted = -1;
        ctx.openOverlay(this);
    }

    /**
     * Closes the menu.
     */
    void close() {
        if (auto ctx = context()) {
            ctx.closeOverlay(this);
        }
    }

    /**
     * Returns the total height of all entries plus padding.
     *
     * Returns:
     *   Height in points.
     */
    float contentHeight() const {
        float h = 2.0f * paddingY;
        foreach (ref it; items) {
            h += it.separator ? separatorHeight : itemHeight;
        }
        return h;
    }

    /**
     * Returns the rectangle of an entry.
     *
     * Params:
     *   i = Entry index.
     *
     * Returns:
     *   Entry rectangle.
     */
    RectF itemRect(size_t i) const {
        float y = bounds.y + paddingY;
        foreach (k; 0 .. i) {
            y += items[k].separator ? separatorHeight : itemHeight;
        }
        return RectF(bounds.x, y, bounds.w, items[i].separator ? separatorHeight : itemHeight);
    }

    /**
     * Returns the entry under a point.
     *
     * Params:
     *   p = Point.
     *
     * Returns:
     *   Entry index, or -1.
     */
    ptrdiff_t itemAt(Point2F p) const {
        foreach (i; 0 .. items.length) {
            if (itemRect(i).contains(p)) {
                return cast(ptrdiff_t) i;
            }
        }
        return -1;
    }

    /**
     * Reports whether an entry can be highlighted/activated.
     *
     * Params:
     *   i = Entry index.
     *
     * Returns:
     *   True for enabled non-separator entries.
     */
    bool isSelectable(size_t i) const {
        return i < items.length && items[i].enabled && !items[i].separator;
    }

    /**
     * Activates an entry: closes the menu, then runs its action.
     *
     * Params:
     *   i = Entry index.
     *
     * Returns:
     *   True if the entry was selectable.
     */
    bool activate(size_t i) {
        if (!isSelectable(i)) {
            return false;
        }
        auto action = items[i].action;
        close();
        if (action !is null) {
            action();
        }
        return true;
    }

    override bool onMouseMove(const ref MouseEvent e) {
        immutable ptrdiff_t i = itemAt(e.pos);
        immutable ptrdiff_t next = i >= 0 && isSelectable(cast(size_t) i) ? i : -1;
        if (next != highlighted) {
            highlighted = next;
            invalidate();
        }
        return true;
    }

    override bool onMouseDown(const ref MouseEvent e) {
        pressed_ = true;
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        immutable ptrdiff_t i = itemAt(e.pos);
        immutable bool wasPressed = pressed_;
        pressed_ = false;
        if (wasPressed && i >= 0) {
            activate(cast(size_t) i);
        }
        return true;
    }

    override bool onKeyDown(const ref KeyEvent e) {
        switch (e.keyCode) {
        case KeyCode.down:
            moveHighlight(1);
            return true;
        case KeyCode.up:
            moveHighlight(-1);
            return true;
        case KeyCode.returnKey:
        case KeyCode.keypadEnter:
        case KeyCode.space:
            if (highlighted >= 0) {
                activate(cast(size_t) highlighted);
            }
            return true;
        default:
            return false;
        }
    }

    override void onDismissed() {
        if (onClosed !is null) {
            onClosed();
        }
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        r.fillRoundedRect(bounds.translate(0.0f, 2.0f), theme.radiusMd, theme.shadow);
        r.fillRoundedRect(bounds, theme.radiusMd, theme.panelRaised);
        r.strokeRoundedRect(bounds, theme.radiusMd, theme.borderWidth, theme.borderStrong);
        immutable float size = theme.fontSizeBody;
        immutable float lh = r.lineHeight(FontId.ui, size);
        foreach (i, ref it; items) {
            immutable RectF ir = itemRect(i);
            if (it.separator) {
                r.fillRect(RectF(ir.x + theme.spacingSm, ir.center().y, ir.w - 2.0f * theme.spacingSm, 1.0f), theme.border);
                continue;
            }
            immutable bool hi = cast(ptrdiff_t) i == highlighted;
            if (hi) {
                r.fillRoundedRect(ir.inset(2.0f), theme.radiusSm, theme.accent);
            }
            immutable ColorRGBA tc = !it.enabled ? theme.textDisabled : (hi ? theme.accentText : theme.text);
            r.drawText(Point2F(ir.x + theme.spacingLg, ir.y + (ir.h - lh) * 0.5f), it.label, FontId.ui, size, tc);
            if (it.shortcut.length > 0) {
                immutable float sw = r.measureText(it.shortcut, FontId.ui, theme.fontSizeSmall);
                r.drawText(Point2F(ir.right() - theme.spacingLg - sw, ir.y + (ir.h - lh) * 0.5f), it.shortcut, FontId.ui,
                    theme.fontSizeSmall, hi ? theme.accentText : theme.textDim);
            }
        }
    }

    private void moveHighlight(int dir) {
        immutable ptrdiff_t n = cast(ptrdiff_t) items.length;
        if (n == 0) {
            return;
        }
        ptrdiff_t i = highlighted;
        foreach (k; 0 .. n) {
            i = i < 0 ? (dir > 0 ? 0 : n - 1) : ((i + dir) % n + n) % n;
            if (isSelectable(cast(size_t) i)) {
                highlighted = i;
                invalidate();
                return;
            }
        }
    }
}

/**
 * Geometry of one scrollbar: proportional thumb, offset/thumb conversions and track paging.
 */
struct ScrollBarModel {
    Axis axis = Axis.vertical;
    RectF track;
    float contentLength = 0.0f;
    float viewportLength = 0.0f;
    float offset = 0.0f;
    float minThumb = 18.0f;

    @safe nothrow pure @nogc:

    /**
     * Returns the largest valid offset.
     *
     * Returns:
     *   max(0, content - viewport).
     */
    float maxOffset() const {
        immutable float m = contentLength - viewportLength;
        return m > 0.0f ? m : 0.0f;
    }

    /**
     * Reports whether content overflows the viewport.
     *
     * Returns:
     *   True if scrolling is possible.
     */
    bool isScrollable() const {
        return maxOffset() > 0.0f;
    }

    /**
     * Returns the track length along the axis.
     *
     * Returns:
     *   Length.
     */
    float trackLength() const {
        return axis == Axis.vertical ? track.h : track.w;
    }

    /**
     * Returns the thumb length (proportional, at least minThumb, at most the track).
     *
     * Returns:
     *   Thumb length.
     */
    float thumbLength() const {
        immutable float tl = trackLength();
        if (!isScrollable() || !(contentLength > 0.0f)) {
            return tl;
        }
        immutable float len = tl * viewportLength / contentLength;
        return clampf(len, minThumb < tl ? minThumb : tl, tl);
    }

    /**
     * Returns the thumb rectangle.
     *
     * Returns:
     *   Thumb rect.
     */
    RectF thumbRect() const {
        immutable float len = thumbLength();
        immutable float travel = trackLength() - len;
        immutable float m = maxOffset();
        immutable float pos = m > 0.0f ? travel * clampf(offset, 0.0f, m) / m : 0.0f;
        return axis == Axis.vertical ? RectF(track.x, track.y + pos, track.w, len) : RectF(track.x + pos, track.y, len, track.h);
    }

    /**
     * Converts a thumb drag distance into a content offset.
     *
     * Params:
     *   startOffset = Offset when the drag began.
     *   delta = Pointer travel along the axis.
     *
     * Returns:
     *   Clamped offset.
     */
    float offsetForThumbDrag(float startOffset, float delta) const {
        immutable float travel = trackLength() - thumbLength();
        if (!(travel > 0.0f)) {
            return clampf(startOffset, 0.0f, maxOffset());
        }
        return clampf(startOffset + delta * maxOffset() / travel, 0.0f, maxOffset());
    }

    /**
     * Returns the offset after a page jump toward a track click.
     *
     * Params:
     *   p = Click position on the track.
     *
     * Returns:
     *   Clamped offset.
     */
    float pageToward(Point2F p) const {
        immutable RectF t = thumbRect();
        immutable bool before = axis == Axis.vertical ? p.y < t.y : p.x < t.x;
        return clampf(offset + (before ? -viewportLength : viewportLength), 0.0f, maxOffset());
    }
}

/**
 * Clipping scroll container for one content widget with trackpad scrolling and draggable/pageable scrollbars.
 * Content size comes from contentSize when set (> 0 per axis), otherwise from the content's measured size.
 */
class ScrollView : Widget {
    Widget content;
    Point2F contentSize;
    bool scrollHorizontal = true;
    bool scrollVertical = true;
    float scrollbarThickness = 10.0f;
    bool drawBackground = true;
    private float offsetX_ = 0.0f;
    private float offsetY_ = 0.0f;
    private RectF viewport_;
    private ScrollBarModel vbar_;
    private ScrollBarModel hbar_;
    private bool showV_ = false;
    private bool showH_ = false;
    private int dragAxis_ = -1;
    private float dragStartOffset_ = 0.0f;
    private Point2F dragStartPos_;

    /**
     * Creates a scroll view.
     *
     * Params:
     *   c = Content widget (may be null and set later via setContent).
     */
    this(Widget c = null) {
        vbar_.axis = Axis.vertical;
        hbar_.axis = Axis.horizontal;
        if (c !is null) {
            setContent(c);
        }
    }

    /**
     * Replaces the content widget.
     *
     * Params:
     *   c = New content.
     */
    void setContent(Widget c) {
        if (content !is null) {
            remove(content);
        }
        content = c;
        if (c !is null) {
            add(c);
        }
        offsetX_ = 0.0f;
        offsetY_ = 0.0f;
        layoutChildren();
    }

    /**
     * Returns the scroll offset.
     *
     * Returns:
     *   Offset (x, y) in content points.
     */
    Point2F scrollOffset() const {
        return Point2F(offsetX_, offsetY_);
    }

    /**
     * Returns the visible content area (bounds minus scrollbars).
     *
     * Returns:
     *   Viewport rectangle.
     */
    RectF viewportRect() const {
        return viewport_;
    }

    /**
     * Returns the vertical scrollbar model.
     *
     * Returns:
     *   Model copy.
     */
    ScrollBarModel verticalBar() const {
        return vbar_;
    }

    /**
     * Returns the horizontal scrollbar model.
     *
     * Returns:
     *   Model copy.
     */
    ScrollBarModel horizontalBar() const {
        return hbar_;
    }

    /**
     * Reports scrollbar visibility.
     *
     * Params:
     *   axis = Scrollbar axis.
     *
     * Returns:
     *   True if that scrollbar is shown.
     */
    bool scrollbarVisible(Axis axis) const {
        return axis == Axis.vertical ? showV_ : showH_;
    }

    /**
     * Returns the effective content size.
     *
     * Returns:
     *   Content size in points.
     */
    Point2F effectiveContentSize() const {
        immutable Point2F m = content is null ? Point2F(0, 0) : content.measuredSize;
        return Point2F(contentSize.x > 0.0f ? contentSize.x : m.x, contentSize.y > 0.0f ? contentSize.y : m.y);
    }

    /**
     * Scrolls to an offset (clamped) and re-arranges the content.
     *
     * Params:
     *   x = Horizontal offset.
     *   y = Vertical offset.
     *
     * Returns:
     *   True if the offset changed.
     */
    bool scrollTo(float x, float y) {
        immutable float ox = offsetX_;
        immutable float oy = offsetY_;
        offsetX_ = x;
        offsetY_ = y;
        layoutChildren();
        immutable bool changed = ox != offsetX_ || oy != offsetY_;
        if (changed) {
            invalidate();
        }
        return changed;
    }

    /**
     * Scrolls the minimum distance that makes a content-space rectangle (absolute, current layout) visible.
     *
     * Params:
     *   r = Rectangle in absolute coordinates.
     *
     * Returns:
     *   True if the offset changed.
     */
    bool ensureVisible(RectF r) {
        float x = offsetX_;
        float y = offsetY_;
        if (r.x < viewport_.x) {
            x -= viewport_.x - r.x;
        } else if (r.right() > viewport_.right()) {
            x += r.right() - viewport_.right();
        }
        if (r.y < viewport_.y) {
            y -= viewport_.y - r.y;
        } else if (r.bottom() > viewport_.bottom()) {
            y += r.bottom() - viewport_.bottom();
        }
        return scrollTo(x, y);
    }

    override void layoutChildren() {
        immutable Point2F cs = effectiveContentSize();
        immutable float t = scrollbarThickness;
        bool needV = scrollVertical && cs.y > bounds.h;
        immutable bool needH = scrollHorizontal && cs.x > bounds.w - (needV ? t : 0.0f);
        if (needH && !needV && scrollVertical) {
            needV = cs.y > bounds.h - t;
        }
        showV_ = needV;
        showH_ = needH;
        immutable float vw = bounds.w - (needV ? t : 0.0f);
        immutable float vh = bounds.h - (needH ? t : 0.0f);
        viewport_ = RectF(bounds.x, bounds.y, vw > 0.0f ? vw : 0.0f, vh > 0.0f ? vh : 0.0f);
        vbar_.track = RectF(viewport_.right(), bounds.y, needV ? t : 0.0f, viewport_.h);
        vbar_.contentLength = scrollVertical ? cs.y : 0.0f;
        vbar_.viewportLength = viewport_.h;
        hbar_.track = RectF(bounds.x, viewport_.bottom(), viewport_.w, needH ? t : 0.0f);
        hbar_.contentLength = scrollHorizontal ? cs.x : 0.0f;
        hbar_.viewportLength = viewport_.w;
        offsetX_ = clampf(offsetX_, 0.0f, hbar_.maxOffset());
        offsetY_ = clampf(offsetY_, 0.0f, vbar_.maxOffset());
        vbar_.offset = offsetY_;
        hbar_.offset = offsetX_;
        if (content !is null) {
            immutable float cw = scrollHorizontal && cs.x > viewport_.w ? cs.x : viewport_.w;
            immutable float ch = scrollVertical && cs.y > viewport_.h ? cs.y : viewport_.h;
            content.arrange(RectF(viewport_.x - offsetX_, viewport_.y - offsetY_, cw, ch));
        }
    }

    override Widget hitTest(Point2F p) {
        if (!visible || !bounds.contains(p)) {
            return null;
        }
        if (viewport_.contains(p) && content !is null) {
            if (auto h = content.hitTest(p)) {
                return h;
            }
        }
        return this;
    }

    override bool onScroll(const ref ScrollEvent e) {
        return scrollTo(offsetX_ - e.deltaX, offsetY_ - e.deltaY);
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        if (showV_ && vbar_.track.contains(e.pos)) {
            return pressBar(Axis.vertical, e.pos);
        }
        if (showH_ && hbar_.track.contains(e.pos)) {
            return pressBar(Axis.horizontal, e.pos);
        }
        return false;
    }

    override bool onMouseMove(const ref MouseEvent e) {
        if (dragAxis_ < 0) {
            return false;
        }
        if (dragAxis_ == cast(int) Axis.vertical) {
            scrollTo(offsetX_, vbar_.offsetForThumbDrag(dragStartOffset_, e.pos.y - dragStartPos_.y));
        } else {
            scrollTo(hbar_.offsetForThumbDrag(dragStartOffset_, e.pos.x - dragStartPos_.x), offsetY_);
        }
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        immutable bool was = dragAxis_ >= 0;
        dragAxis_ = -1;
        return was;
    }

    override void onCaptureLost() {
        dragAxis_ = -1;
    }

    /**
     * Reports whether a scrollbar thumb drag is active.
     *
     * Returns:
     *   True while dragging.
     */
    bool isDraggingThumb() const {
        return dragAxis_ >= 0;
    }

    override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        return preferredSize;
    }

    override void draw(IRenderer2D r, const ref StudioTheme theme) {
        if (!visible) {
            return;
        }
        if (drawBackground) {
            r.fillRect(bounds, theme.panelSunken);
        }
        r.pushClip(viewport_);
        drawChildren(r, theme);
        r.popClip();
        if (showV_) {
            drawBar(r, theme, vbar_, dragAxis_ == cast(int) Axis.vertical);
        }
        if (showH_) {
            drawBar(r, theme, hbar_, dragAxis_ == cast(int) Axis.horizontal);
        }
    }

    private bool pressBar(Axis axis, Point2F p) {
        ScrollBarModel* bar = axis == Axis.vertical ? &vbar_ : &hbar_;
        if (bar.thumbRect().contains(p)) {
            dragAxis_ = cast(int) axis;
            dragStartOffset_ = bar.offset;
            dragStartPos_ = p;
            invalidate();
            return true;
        }
        immutable float target = bar.pageToward(p);
        if (axis == Axis.vertical) {
            scrollTo(offsetX_, target);
        } else {
            scrollTo(target, offsetY_);
        }
        return true;
    }

    private static void drawBar(IRenderer2D r, const ref StudioTheme theme, const ref ScrollBarModel bar, bool hot) {
        r.fillRect(bar.track, theme.scrollTrack);
        immutable RectF th = bar.thumbRect().inset(2.0f);
        immutable float rad = (th.w < th.h ? th.w : th.h) * 0.5f;
        r.fillRoundedRect(th, rad, hot ? theme.scrollThumbHot : theme.scrollThumb);
    }
}

/**
 * Docking split view: arranges pane widgets into the leaves of a split-pane tree and lets the user drag splitters.
 */
class SplitView : Widget {
    DockLayout dock;
    private Widget[string] panes_;
    private SplitPaneNode hoverSplit_;
    private SplitPaneNode[] splitScratch_;

    /**
     * Creates a split view.
     *
     * Params:
     *   tree = Split-pane tree.
     */
    this(SplitPaneNode tree) {
        dock = new DockLayout(tree);
    }

    /**
     * Assigns a widget to a leaf (replacing any previous pane for that leaf).
     *
     * Params:
     *   leafId = Leaf identifier.
     *   w = Pane widget.
     *
     * Returns:
     *   True if the leaf exists.
     */
    bool setPane(string leafId, Widget w) {
        if (dock.findLeaf(leafId) is null) {
            return false;
        }
        if (auto old = leafId in panes_) {
            remove(*old);
        }
        panes_[leafId] = w;
        add(w);
        layoutChildren();
        return true;
    }

    /**
     * Returns the pane assigned to a leaf.
     *
     * Params:
     *   leafId = Leaf identifier.
     *
     * Returns:
     *   Pane, or null.
     */
    Widget pane(string leafId) {
        if (auto p = leafId in panes_) {
            return *p;
        }
        return null;
    }

    override void layoutChildren() {
        dock.arrange(bounds);
        foreach (leafId, w; panes_) {
            w.arrange(dock.leafBounds(leafId));
        }
    }

    override Widget hitTest(Point2F p) {
        if (!visible || !bounds.contains(p)) {
            return null;
        }
        if (dock.isDragging() || dock.splitterAt(p) !is null) {
            return this;
        }
        return super.hitTest(p);
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left || !dock.beginDrag(e.pos)) {
            return false;
        }
        invalidate();
        return true;
    }

    override bool onMouseMove(const ref MouseEvent e) {
        if (dock.isDragging()) {
            dock.dragTo(e.pos);
            foreach (leafId, w; panes_) {
                w.arrange(dock.leafBounds(leafId));
            }
            invalidate();
            return true;
        }
        auto s = dock.splitterAt(e.pos);
        if (s !is hoverSplit_) {
            hoverSplit_ = s;
            invalidate();
        }
        return s !is null;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        immutable bool was = dock.isDragging();
        dock.endDrag();
        return was;
    }

    override void onMouseLeave() {
        hoverSplit_ = null;
    }

    override void onCaptureLost() {
        dock.endDrag();
    }

    override void draw(IRenderer2D r, const ref StudioTheme theme) {
        if (!visible) {
            return;
        }
        drawChildren(r, theme);
        splitScratch_.length = 0;
        dock.root.collectSplits(splitScratch_);
        foreach (s; splitScratch_) {
            immutable bool hot = s is dock.draggingNode() || s is hoverSplit_;
            r.fillRect(s.splitterRect, hot ? theme.accent : theme.border);
        }
    }
}

/**
 * Curve rendering style for CurveEditor.
 */
enum CurveMode : ubyte {
    linear = 0,
    smooth = 1
}

/**
 * Breakpoint curve editor over the normalized [0, 1]^2 domain (y up). Drag points (Shift = fine), double-click empty
 * space to insert, right-click or Delete to remove, arrows nudge the selected point. Endpoint x positions stay fixed
 * when lockEndpointsX is set and x ordering is always preserved. Smooth mode draws cubic Beziers with horizontal
 * tangents (y follows a smoothstep between breakpoints).
 */
class CurveEditor : Widget {
    Point2F[] points;
    CurveMode mode = CurveMode.linear;
    bool lockEndpointsX = true;
    bool lockFirstY = false;
    bool lockLastY = false;
    size_t minPoints = 2;
    size_t maxPoints = 64;
    float hitRadius = 6.0f;
    float padding = 6.0f;
    float fineFactor = 0.1f;
    float nudgeStep = 0.01f;
    void delegate() onChange;
    ptrdiff_t selected = -1;
    ptrdiff_t hoveredPoint = -1;
    private ptrdiff_t dragIndex_ = -1;
    private Point2F dragAnchorScreen_;
    private Point2F dragAnchorPoint_;
    private bool dragFine_ = false;
    private Point2F[] screenScratch_;

    /**
     * Creates an editor.
     *
     * Params:
     *   initial = Initial breakpoints sorted by x (default: (0,0)-(1,1) ramp).
     */
    this(Point2F[] initial = null) {
        points = initial.length >= 2 ? initial.dup : [Point2F(0.0f, 0.0f), Point2F(1.0f, 1.0f)];
        focusable = true;
    }

    /**
     * Returns the plotting rectangle.
     *
     * Returns:
     *   Bounds inset by padding.
     */
    RectF plotRect() const {
        return bounds.inset(padding);
    }

    /**
     * Maps a normalized point to screen coordinates.
     *
     * Params:
     *   n = Normalized point.
     *
     * Returns:
     *   Screen point.
     */
    Point2F toScreen(Point2F n) const {
        immutable RectF pr = plotRect();
        return Point2F(pr.x + n.x * pr.w, pr.bottom() - n.y * pr.h);
    }

    /**
     * Maps a screen point to the normalized domain (unclamped).
     *
     * Params:
     *   s = Screen point.
     *
     * Returns:
     *   Normalized point.
     */
    Point2F toNormalized(Point2F s) const {
        immutable RectF pr = plotRect();
        return Point2F(pr.w > 0.0f ? (s.x - pr.x) / pr.w : 0.0f, pr.h > 0.0f ? (pr.bottom() - s.y) / pr.h : 0.0f);
    }

    /**
     * Returns the nearest point within hitRadius of a screen position.
     *
     * Params:
     *   s = Screen point.
     *
     * Returns:
     *   Point index, or -1.
     */
    ptrdiff_t pointAt(Point2F s) const {
        ptrdiff_t best = -1;
        float bestD = hitRadius;
        foreach (i, ref const p; points) {
            immutable float d = (toScreen(p) - s).length();
            if (d <= bestD) {
                bestD = d;
                best = cast(ptrdiff_t) i;
            }
        }
        return best;
    }

    /**
     * Applies all constraints to a candidate position for point i.
     *
     * Params:
     *   i = Point index.
     *   n = Candidate normalized position.
     *
     * Returns:
     *   Constrained position.
     */
    Point2F constrain(size_t i, Point2F n) const {
        immutable size_t last = points.length - 1;
        float y = clampf(isFinite(n.y) ? n.y : points[i].y, 0.0f, 1.0f);
        if ((i == 0 && lockFirstY) || (i == last && lockLastY)) {
            y = points[i].y;
        }
        float x;
        if (lockEndpointsX && (i == 0 || i == last)) {
            x = points[i].x;
        } else {
            immutable float lo = i > 0 ? points[i - 1].x : 0.0f;
            immutable float hi = i < last ? points[i + 1].x : 1.0f;
            x = clampf(isFinite(n.x) ? n.x : points[i].x, lo, hi);
        }
        return Point2F(x, y);
    }

    /**
     * Moves point i to a constrained position.
     *
     * Params:
     *   i = Point index.
     *   n = Requested normalized position.
     *
     * Returns:
     *   True if the point moved.
     */
    bool movePoint(size_t i, Point2F n) {
        if (i >= points.length) {
            return false;
        }
        immutable Point2F c = constrain(i, n);
        if (c == points[i]) {
            return false;
        }
        points[i] = c;
        changed();
        return true;
    }

    /**
     * Inserts a breakpoint keeping x order (strictly between locked endpoints).
     *
     * Params:
     *   n = Normalized position.
     *
     * Returns:
     *   New point index, or -1 when at maxPoints.
     */
    ptrdiff_t insertPoint(Point2F n) {
        if (points.length >= maxPoints) {
            return -1;
        }
        float x = clampf(isFinite(n.x) ? n.x : 0.5f, 0.0f, 1.0f);
        immutable float y = clampf(isFinite(n.y) ? n.y : 0.5f, 0.0f, 1.0f);
        if (lockEndpointsX) {
            x = clampf(x, points[0].x, points[$ - 1].x);
        }
        size_t idx = points.length;
        foreach (i, ref const p; points) {
            if (p.x > x) {
                idx = i;
                break;
            }
        }
        if (lockEndpointsX) {
            if (idx == 0) {
                idx = 1;
            }
            if (idx >= points.length) {
                idx = points.length - 1;
            }
        }
        points = points[0 .. idx] ~ Point2F(x, y) ~ points[idx .. $];
        if (selected >= cast(ptrdiff_t) idx) {
            selected++;
        }
        pointInserted(idx);
        changed();
        return cast(ptrdiff_t) idx;
    }

    /**
     * Reports whether point i may be removed.
     *
     * Params:
     *   i = Point index.
     *
     * Returns:
     *   False for out-of-range indices, locked endpoints, or when at minPoints.
     */
    bool canRemovePoint(size_t i) const {
        if (i >= points.length || points.length <= minPoints) {
            return false;
        }
        if (lockEndpointsX && (i == 0 || i == points.length - 1)) {
            return false;
        }
        return true;
    }

    /**
     * Removes point i if allowed.
     *
     * Params:
     *   i = Point index.
     *
     * Returns:
     *   True if removed.
     */
    bool removePoint(size_t i) {
        if (!canRemovePoint(i)) {
            return false;
        }
        points = points[0 .. i] ~ points[i + 1 .. $];
        if (selected == cast(ptrdiff_t) i) {
            selected = -1;
        } else if (selected > cast(ptrdiff_t) i) {
            selected--;
        }
        hoveredPoint = -1;
        dragIndex_ = -1;
        pointRemoved(i);
        changed();
        return true;
    }

    /**
     * Evaluates the curve at x (clamped to the first/last breakpoint outside the covered range).
     *
     * Params:
     *   x = Normalized x.
     *
     * Returns:
     *   Normalized y.
     */
    float evaluate(float x) const {
        if (x <= points[0].x) {
            return points[0].y;
        }
        if (x >= points[$ - 1].x) {
            return points[$ - 1].y;
        }
        foreach (i; 1 .. points.length) {
            if (x <= points[i].x) {
                immutable Point2F a = points[i - 1];
                immutable Point2F b = points[i];
                immutable float dx = b.x - a.x;
                if (!(dx > 0.0f)) {
                    return b.y;
                }
                immutable float t = (x - a.x) / dx;
                immutable float s = mode == CurveMode.smooth ? t * t * (3.0f - 2.0f * t) : t;
                return a.y + (b.y - a.y) * s;
            }
        }
        return points[$ - 1].y;
    }

    /**
     * Reports whether a point drag is active.
     *
     * Returns:
     *   True while dragging.
     */
    bool isDraggingPoint() const {
        return dragIndex_ >= 0;
    }

    /**
     * Hook called after a point is inserted at index i.
     *
     * Params:
     *   i = Inserted index.
     */
    protected void pointInserted(size_t i) {
    }

    /**
     * Hook called after the point at index i was removed.
     *
     * Params:
     *   i = Removed index.
     */
    protected void pointRemoved(size_t i) {
    }

    /**
     * Hook drawing decorations beneath the curve.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    protected void paintDecorations(IRenderer2D r, const ref StudioTheme theme) {
    }

    /**
     * Returns the fill color of point i.
     *
     * Params:
     *   i = Point index.
     *   theme = Theme.
     *
     * Returns:
     *   Point color.
     */
    protected ColorRGBA pointColor(size_t i, const ref StudioTheme theme) {
        if (cast(ptrdiff_t) i == selected) {
            return theme.accentHot;
        }
        if (cast(ptrdiff_t) i == hoveredPoint) {
            return theme.text;
        }
        return theme.accent;
    }

    /**
     * Marks the curve changed and notifies onChange.
     */
    protected void changed() {
        invalidate();
        if (onChange !is null) {
            onChange();
        }
    }

    override bool onMouseDown(const ref MouseEvent e) {
        immutable ptrdiff_t hit = pointAt(e.pos);
        if (e.button == MouseButton.right) {
            return hit >= 0 && removePoint(cast(size_t) hit);
        }
        if (e.button != MouseButton.left) {
            return false;
        }
        ptrdiff_t target = hit;
        if (target < 0 && e.clickCount >= 2) {
            target = insertPoint(toNormalized(e.pos));
        }
        selected = target;
        if (target >= 0) {
            dragIndex_ = target;
            dragAnchorScreen_ = e.pos;
            dragAnchorPoint_ = points[target];
            dragFine_ = e.shift();
        }
        invalidate();
        return true;
    }

    override bool onMouseMove(const ref MouseEvent e) {
        if (dragIndex_ < 0) {
            immutable ptrdiff_t h = pointAt(e.pos);
            if (h != hoveredPoint) {
                hoveredPoint = h;
                invalidate();
            }
            return false;
        }
        immutable bool fine = e.shift();
        if (fine != dragFine_) {
            dragFine_ = fine;
            dragAnchorScreen_ = e.pos;
            dragAnchorPoint_ = points[dragIndex_];
            return true;
        }
        immutable RectF pr = plotRect();
        immutable float k = fine ? fineFactor : 1.0f;
        immutable float dx = pr.w > 0.0f ? (e.pos.x - dragAnchorScreen_.x) / pr.w * k : 0.0f;
        immutable float dy = pr.h > 0.0f ? (dragAnchorScreen_.y - e.pos.y) / pr.h * k : 0.0f;
        movePoint(cast(size_t) dragIndex_, Point2F(dragAnchorPoint_.x + dx, dragAnchorPoint_.y + dy));
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        dragIndex_ = -1;
        return true;
    }

    override void onCaptureLost() {
        dragIndex_ = -1;
    }

    override void onMouseLeave() {
        hoveredPoint = -1;
    }

    override bool onKeyDown(const ref KeyEvent e) {
        if (selected < 0 || selected >= cast(ptrdiff_t) points.length) {
            return false;
        }
        immutable size_t i = cast(size_t) selected;
        immutable float s = e.shift() ? nudgeStep * fineFactor : nudgeStep;
        switch (e.keyCode) {
        case KeyCode.deleteBackward:
        case KeyCode.forwardDelete:
            removePoint(i);
            return true;
        case KeyCode.left:
            movePoint(i, Point2F(points[i].x - s, points[i].y));
            return true;
        case KeyCode.right:
            movePoint(i, Point2F(points[i].x + s, points[i].y));
            return true;
        case KeyCode.up:
            movePoint(i, Point2F(points[i].x, points[i].y + s));
            return true;
        case KeyCode.down:
            movePoint(i, Point2F(points[i].x, points[i].y - s));
            return true;
        default:
            return false;
        }
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        r.fillRoundedRect(bounds, theme.radiusSm, theme.panelSunken);
        r.strokeRoundedRect(bounds, theme.radiusSm, theme.borderWidth, theme.border);
        immutable RectF pr = plotRect();
        foreach (k; 1 .. 4) {
            immutable float f = cast(float) k * 0.25f;
            r.fillRect(RectF(pr.x + pr.w * f, pr.y, 1.0f, pr.h), theme.gridLine);
            r.fillRect(RectF(pr.x, pr.y + pr.h * f, pr.w, 1.0f), theme.gridLine);
        }
        paintDecorations(r, theme);
        immutable ColorRGBA lc = isEffectivelyEnabled() ? theme.accent : theme.textDisabled;
        screenScratch_.length = points.length;
        foreach (i, ref const p; points) {
            screenScratch_[i] = toScreen(p);
        }
        if (mode == CurveMode.linear) {
            r.drawPolyline(screenScratch_, theme.curveLineWidth, lc);
        } else {
            foreach (i; 1 .. screenScratch_.length) {
                immutable Point2F a = screenScratch_[i - 1];
                immutable Point2F b = screenScratch_[i];
                immutable float third = (b.x - a.x) / 3.0f;
                r.drawBezier(a, Point2F(a.x + third, a.y), Point2F(b.x - third, b.y), b, theme.curveLineWidth, lc);
            }
        }
        foreach (i; 0 .. screenScratch_.length) {
            fillCircle(r, screenScratch_[i], theme.curvePointRadius, pointColor(i, theme));
        }
        if (isFocused()) {
            drawFocusRing(r, theme, bounds, theme.radiusSm);
        }
    }
}

/**
 * ADSR-style envelope editor built on CurveEditor: the first and last points sit at y = 0 with fixed x, and one
 * breakpoint is the sustain point (Alt-click a point to move it). The sustain point cannot be removed and its index
 * tracks insertions/removals.
 */
class EnvelopeEditor : CurveEditor {
    size_t sustainIndex = 2;

    /**
     * Creates an editor with a default ADSR shape.
     */
    this() {
        super(null);
        lockEndpointsX = true;
        lockFirstY = true;
        lockLastY = true;
        minPoints = 3;
        setAdsr(0.1f, 0.2f, 0.6f, 0.3f);
    }

    /**
     * Rebuilds the four-point ADSR shape; times are relative and normalized so the release ends at x = 1.
     *
     * Params:
     *   attack = Attack time (relative).
     *   decay = Decay time (relative).
     *   sustain = Sustain level in [0, 1].
     *   release = Release time (relative).
     */
    void setAdsr(float attack, float decay, float sustain, float release) {
        immutable float a = attack > 0.0f ? attack : 0.0f;
        immutable float d = decay > 0.0f ? decay : 0.0f;
        immutable float rel = release > 0.0f ? release : 0.0f;
        immutable float total = a + d + rel > 0.0f ? a + d + rel : 1.0f;
        immutable float s = clampf(sustain, 0.0f, 1.0f);
        points = [Point2F(0.0f, 0.0f), Point2F(a / total, 1.0f), Point2F((a + d) / total, s), Point2F(1.0f, 0.0f)];
        sustainIndex = 2;
        selected = -1;
        changed();
    }

    /**
     * Returns the sustain level.
     *
     * Returns:
     *   y of the sustain point.
     */
    float sustainLevel() const {
        return points[sustainIndex].y;
    }

    /**
     * Moves the sustain marker to an interior point.
     *
     * Params:
     *   i = Point index (must not be the first or last point).
     *
     * Returns:
     *   True if the sustain index changed.
     */
    bool setSustainIndex(size_t i) {
        if (i == 0 || i + 1 >= points.length || i == sustainIndex) {
            return false;
        }
        sustainIndex = i;
        changed();
        return true;
    }

    override bool canRemovePoint(size_t i) const {
        return i != sustainIndex && super.canRemovePoint(i);
    }

    protected override void pointInserted(size_t i) {
        if (i <= sustainIndex) {
            sustainIndex++;
        }
    }

    protected override void pointRemoved(size_t i) {
        if (i < sustainIndex) {
            sustainIndex--;
        }
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button == MouseButton.left && e.alt()) {
            immutable ptrdiff_t hit = pointAt(e.pos);
            if (hit >= 0) {
                setSustainIndex(cast(size_t) hit);
                selected = hit;
                return true;
            }
        }
        return super.onMouseDown(e);
    }

    protected override void paintDecorations(IRenderer2D r, const ref StudioTheme theme) {
        immutable RectF pr = plotRect();
        immutable float x = toScreen(points[sustainIndex]).x;
        float y = pr.y;
        while (y < pr.bottom()) {
            immutable float seg = y + 4.0f < pr.bottom() ? 4.0f : pr.bottom() - y;
            r.fillRect(RectF(x, y, 1.0f, seg), theme.warning);
            y += 8.0f;
        }
    }

    protected override ColorRGBA pointColor(size_t i, const ref StudioTheme theme) {
        if (i == sustainIndex && cast(ptrdiff_t) i != selected) {
            return theme.warning;
        }
        return super.pointColor(i, theme);
    }
}
