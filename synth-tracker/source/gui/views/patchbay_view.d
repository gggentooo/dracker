/**
 * File:         source/gui/views/patchbay_view.d
 * Module:       gui.views.patchbay_view
 * Phase:        Phase 8.2 — Zoomable Modular Patchbay Graph Editor
 *
 * Purpose:
 *   Interactive node-and-wire modular editor over the session document: zoom (pinch, Cmd+scroll, StudioActions)
 *   around the pointer and pan (scroll, empty-canvas drag) with clamping, double-click fit-all, node selection and
 *   dragging (one undo step per drag), typed port-to-port wire creation with a rubber-band cable and compatible
 *   target highlighting, wire selection and deletion, module deletion (the output module is protected),
 *   mute/solo/bypass badges, ModuleRegistry add-module and per-node context menus (mute, solo, bypass, duplicate,
 *   delete), signal pulses animated along wires whose source module reports a nonzero telemetry peak, and inline
 *   mini-scopes for up to four recently selected modules.
 *   Phase 8.5 (Accessible Appearance): colors come only from theme tokens; wire kinds are also encoded by line
 *   style (audio solid, sidechain doubled, event dashed, CV dotted) and port glyph shape (circle, double circle,
 *   square, diamond); muted/bypassed nodes are hatched instead of washed out; selection adds an outer outline.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Every mutation goes through StudioSession (undoable, compiled off-RT by GraphCompiler). The
 *   document is re-read through ctx.session.document() and derived node/wire geometry is cached by document
 *   revision; no pointers into the document survive a frame. Drawing goes exclusively through IRenderer2D, culls
 *   off-screen nodes and wires, and stays inside the view bounds.
 *
 * Dependencies:
 *   Internal: app.keymap, graph.{module_api,port,registry}, gui.{renderer,theme,widgets}, gui.views.studio_context,
 *     platform.interfaces
 *   External: std.math (abs, exp, floor, isFinite, sqrt)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum PatchbayBadge / enum PatchbayHitKind / struct PatchbayHit
 *   - final class PatchbayView : Widget, StudioCommandSink — this(StudioContext), handleStudioAction(), hitTestAt(),
 *     zoomAround(), panBy(), setView(), fitAll(), resetZoom(), deleteSelection(), deleteModule(), addModuleAt(),
 *     selectWire(), clearWireSelection(), addModuleMenuItems(), categoryMenuItems(), nodeMenuItems(),
 *     duplicateModule(), toggleBadge(), pulsesActive(), scopeModules(), isAnimating()
 *   - patchbayBezierPoint() / patchbaySegmentDistance(); PATCHBAY_* layout and zoom constants
 *   - Automation hooks: nodeCenter(), nodeRect(), portPosition(), badgeCenter(), wireMidpoint(), worldToView(),
 *     viewToWorld(), zoom(), pan(), selectedWireIndex(), emptyCanvasPoint(), scopeRect(), isDragging()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.views.patchbay_view;

import std.math : abs, exp, floor, isFinite, sqrt;

import app.keymap : StudioAction, StudioCommandSink;
import graph.module_api : ModuleCategory, ModuleDescriptor;
import graph.port : arePortsCompatible, PortDirection, PortKind;
import graph.registry : ModuleRegistry;
import gui.renderer : ColorRGBA, drawDashedPolyline, FontId, IRenderer2D, Point2F, RectF, sampleBezier;
import gui.theme : StudioTheme, WireDash, WireKind, wireKindOf;
import gui.views.studio_context : StudioContext;
import gui.widgets : fillCircle, hasModifier, KeyCode, KeyEvent, MenuItem, MouseButton, MouseEvent, ScrollEvent,
    UiContext, Widget;
import platform.interfaces : KeyModifiers;

enum float PATCHBAY_MIN_ZOOM = 0.25f;
enum float PATCHBAY_MAX_ZOOM = 3.0f;
enum float PATCHBAY_NODE_WIDTH = 150.0f;
enum float PATCHBAY_HEADER_HEIGHT = 22.0f;
enum float PATCHBAY_TYPE_HEIGHT = 16.0f;
enum float PATCHBAY_PORT_ROW = 16.0f;
enum float PATCHBAY_PORT_RADIUS = 5.0f;
enum float PATCHBAY_BADGE_SIZE = 14.0f;
enum float PATCHBAY_SCOPE_GAP = 4.0f;
enum float PATCHBAY_SCOPE_HEIGHT = 30.0f;
enum float PATCHBAY_PAN_MARGIN = 48.0f;
enum float PATCHBAY_WIRE_TOLERANCE = 6.0f;
enum float PATCHBAY_PULSE_THRESHOLD = 1.0e-4f;
enum size_t PATCHBAY_SCOPE_FRAMES = 256;
enum size_t PATCHBAY_MAX_SCOPES = 4;

/**
 * Header badges toggling per-module flags.
 */
enum PatchbayBadge : ubyte {
    mute = 0,
    solo = 1,
    bypass = 2
}

/**
 * Element kinds reported by PatchbayView.hitTestAt().
 */
enum PatchbayHitKind : ubyte {
    none = 0,
    node = 1,
    badge = 2,
    inputPort = 3,
    outputPort = 4,
    wire = 5
}

/**
 * Result of a patchbay hit test.
 */
struct PatchbayHit {
    PatchbayHitKind kind = PatchbayHitKind.none;
    uint moduleId = 0;
    ushort portIndex = 0;
    PatchbayBadge badge = PatchbayBadge.mute;
    ptrdiff_t wireIndex = -1;
}

private enum DragMode : ubyte {
    none = 0,
    pan = 1,
    node = 2,
    wire = 3
}

private struct NodePort {
    ushort index;
    PortKind kind;
    string name;
}

private struct NodeCache {
    uint id;
    string name;
    string typeName;
    string typeId;
    ModuleCategory category;
    bool isOutput;
    bool muted;
    bool bypassed;
    float x;
    float y;
    float w;
    float h;
    NodePort[] inputs;
    NodePort[] outputs;
}

private struct WireCache {
    uint src;
    ushort srcPort;
    uint dst;
    ushort dstPort;
    float gain;
    PortKind kind;
    size_t srcNode;
    size_t dstNode;
}

private struct WireKey {
    uint src;
    ushort srcPort;
    uint dst;
    ushort dstPort;
}

/**
 * Evaluates a cubic Bezier.
 *
 * Params:
 *   p0 = Start.
 *   c0 = First control point.
 *   c1 = Second control point.
 *   p1 = End.
 *   t = Curve parameter in [0, 1].
 *
 * Returns:
 *   Point on the curve.
 */
Point2F patchbayBezierPoint(Point2F p0, Point2F c0, Point2F c1, Point2F p1, float t) @safe nothrow pure @nogc {
    immutable float u = 1.0f - t;
    immutable float a = u * u * u;
    immutable float b = 3.0f * u * u * t;
    immutable float c = 3.0f * u * t * t;
    immutable float d = t * t * t;
    return Point2F(a * p0.x + b * c0.x + c * c1.x + d * p1.x, a * p0.y + b * c0.y + c * c1.y + d * p1.y);
}

/**
 * Returns the distance from a point to a line segment.
 *
 * Params:
 *   p = Point.
 *   a = Segment start.
 *   b = Segment end.
 *
 * Returns:
 *   Euclidean distance.
 */
float patchbaySegmentDistance(Point2F p, Point2F a, Point2F b) @safe nothrow pure @nogc {
    immutable float vx = b.x - a.x;
    immutable float vy = b.y - a.y;
    immutable float len2 = vx * vx + vy * vy;
    float t = len2 > 0.0f ? ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2 : 0.0f;
    t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
    immutable float dx = p.x - (a.x + vx * t);
    immutable float dy = p.y - (a.y + vy * t);
    return sqrt(dx * dx + dy * dy);
}

/**
 * Zoomable, pannable modular node graph editor for the session document.
 */
final class PatchbayView : Widget, StudioCommandSink {
    private StudioContext ctx_;
    private float zoom_ = 1.0f;
    private Point2F pan_ = Point2F(40.0f, 40.0f);
    private NodeCache[] nodes_;
    private WireCache[] wires_;
    private size_t[uint] nodeIndex_;
    private ulong cachedRevision_ = 0;
    private bool cacheValid_ = false;
    private WireKey selectedWire_;
    private bool hasSelectedWire_ = false;
    private uint[] recentSelection_;
    private ulong seenSelectionRevision_ = 0;
    private uint[PATCHBAY_MAX_SCOPES] requestedTaps_;
    private bool tapsRequested_ = false;
    private DragMode drag_ = DragMode.none;
    private Point2F dragStart_;
    private Point2F dragLast_;
    private uint dragModule_ = 0;
    private Point2F grabOffset_;
    private bool dragMoved_ = false;
    private bool groupOpen_ = false;
    private ushort wirePort_ = 0;
    private Point2F wireCursor_;
    private Point2F[] scopeScratch_;

    /**
     * Creates the patchbay over a studio context.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        assert(ctx !is null, "PatchbayView requires a StudioContext");
        ctx_ = ctx;
        id = "patchbay";
        focusable = true;
        contextMenuProvider = &buildContextMenu;
    }

    /**
     * Returns the current zoom factor.
     *
     * Returns:
     *   Zoom in [PATCHBAY_MIN_ZOOM, PATCHBAY_MAX_ZOOM].
     */
    float zoom() const {
        return zoom_;
    }

    /**
     * Returns the pan offset (view points from the view origin to world origin).
     *
     * Returns:
     *   Pan offset.
     */
    Point2F pan() const {
        return pan_;
    }

    /**
     * Converts patchbay world coordinates to absolute logical window coordinates.
     *
     * Params:
     *   w = World point.
     *
     * Returns:
     *   View point.
     */
    Point2F worldToView(Point2F w) const {
        return Point2F(bounds.x + pan_.x + w.x * zoom_, bounds.y + pan_.y + w.y * zoom_);
    }

    /**
     * Converts absolute logical window coordinates to patchbay world coordinates.
     *
     * Params:
     *   v = View point.
     *
     * Returns:
     *   World point.
     */
    Point2F viewToWorld(Point2F v) const {
        return Point2F((v.x - bounds.x - pan_.x) / zoom_, (v.y - bounds.y - pan_.y) / zoom_);
    }

    /**
     * Sets zoom and pan directly (zoom is clamped, pan is not).
     *
     * Params:
     *   zoomFactor = New zoom.
     *   panOffset = New pan offset.
     */
    void setView(float zoomFactor, Point2F panOffset) {
        zoom_ = clampZoom(zoomFactor);
        if (isFinite(panOffset.x) && isFinite(panOffset.y)) {
            pan_ = panOffset;
        }
        invalidate();
    }

    /**
     * Zooms so the world point under the anchor stays fixed, then clamps the pan.
     *
     * Params:
     *   anchor = View point kept invariant.
     *   newZoom = Requested zoom (clamped to 0.25 .. 3).
     */
    void zoomAround(Point2F anchor, float newZoom) {
        immutable Point2F w = viewToWorld(anchor);
        zoom_ = clampZoom(newZoom);
        pan_ = Point2F(anchor.x - bounds.x - w.x * zoom_, anchor.y - bounds.y - w.y * zoom_);
        clampPan();
        invalidate();
    }

    /**
     * Pans the view by a view-space offset, clamped so the content stays reachable.
     *
     * Params:
     *   dx = Horizontal offset.
     *   dy = Vertical offset.
     */
    void panBy(float dx, float dy) {
        if (!isFinite(dx) || !isFinite(dy)) {
            return;
        }
        pan_ = Point2F(pan_.x + dx, pan_.y + dy);
        clampPan();
        invalidate();
    }

    /**
     * Resets the zoom to 1 around the view centre.
     */
    void resetZoom() {
        zoomAround(bounds.center(), 1.0f);
    }

    /**
     * Fits every node (and its scope area) into the view; resets the view when the document has no modules.
     */
    void fitAll() {
        ensureCache();
        RectF c;
        if (!contentWorldRect(c)) {
            zoom_ = 1.0f;
            pan_ = Point2F(40.0f, 40.0f);
            invalidate();
            return;
        }
        immutable float pad = 32.0f;
        immutable float aw = bounds.w - 2.0f * pad;
        immutable float ah = bounds.h - 2.0f * pad;
        float z = 1.0f;
        if (aw > 0.0f && ah > 0.0f && c.w > 0.0f && c.h > 0.0f) {
            immutable float zx = aw / c.w;
            immutable float zy = ah / c.h;
            z = zx < zy ? zx : zy;
        }
        zoom_ = clampZoom(z);
        immutable Point2F cc = c.center();
        pan_ = Point2F(bounds.w * 0.5f - cc.x * zoom_, bounds.h * 0.5f - cc.y * zoom_);
        invalidate();
    }

    /**
     * Returns the view rectangle of a module node (header and port rows, excluding the mini-scope).
     *
     * Params:
     *   moduleId = Module id.
     *
     * Returns:
     *   Node rectangle, or an empty rectangle if unknown.
     */
    RectF nodeRect(uint moduleId) {
        ensureCache();
        auto p = moduleId in nodeIndex_;
        return p is null ? RectF.init : worldRectToView(nodeWorldRect(nodes_[*p]));
    }

    /**
     * Returns the view-space centre of a module's port-row body (a safe point to click or drag the node).
     *
     * Params:
     *   moduleId = Module id.
     *
     * Returns:
     *   Centre point, or the origin if unknown.
     */
    Point2F nodeCenter(uint moduleId) {
        immutable RectF r = nodeRect(moduleId);
        if (r.isEmpty()) {
            return Point2F.init;
        }
        immutable float top = r.y + (PATCHBAY_HEADER_HEIGHT + PATCHBAY_TYPE_HEIGHT) * zoom_;
        return Point2F(r.x + r.w * 0.5f, (top + r.bottom()) * 0.5f);
    }

    /**
     * Returns the view position of a port.
     *
     * Params:
     *   moduleId = Module id.
     *   portIndex = Index into the module descriptor's ports.
     *
     * Returns:
     *   Port centre, or the origin if unknown.
     */
    Point2F portPosition(uint moduleId, ushort portIndex) {
        ensureCache();
        auto p = moduleId in nodeIndex_;
        if (p is null) {
            return Point2F.init;
        }
        Point2F w;
        if (!portWorldPosition(nodes_[*p], portIndex, w)) {
            return Point2F.init;
        }
        return worldToView(w);
    }

    /**
     * Returns the view centre of a header badge.
     *
     * Params:
     *   moduleId = Module id.
     *   badge = Badge.
     *
     * Returns:
     *   Badge centre, or the origin if the module is unknown or has no badges (output module).
     */
    Point2F badgeCenter(uint moduleId, PatchbayBadge badge) {
        ensureCache();
        auto p = moduleId in nodeIndex_;
        if (p is null || nodes_[*p].isOutput) {
            return Point2F.init;
        }
        return worldRectToView(badgeWorldRect(nodes_[*p], badge)).center();
    }

    /**
     * Returns the view position of the middle of a wire's curve.
     *
     * Params:
     *   wireIndex = Index into the document wire list.
     *
     * Returns:
     *   Curve midpoint, or the origin if out of range.
     */
    Point2F wireMidpoint(size_t wireIndex) {
        ensureCache();
        const doc = ctx_.session.document();
        if (wireIndex >= doc.wires.length) {
            return Point2F.init;
        }
        const dw = doc.wires[wireIndex];
        foreach (ref w; wires_) {
            if (w.src == dw.srcMod && w.srcPort == dw.srcPort && w.dst == dw.dstMod && w.dstPort == dw.dstPort) {
                Point2F p0, c0, c1, p1;
                wireCurve(w, p0, c0, c1, p1);
                return patchbayBezierPoint(p0, c0, c1, p1, 0.5f);
            }
        }
        return Point2F.init;
    }

    /**
     * Returns the view rectangle of a module's inline mini-scope area.
     *
     * Params:
     *   moduleId = Module id.
     *
     * Returns:
     *   Scope rectangle, or empty if unknown.
     */
    RectF scopeRect(uint moduleId) {
        ensureCache();
        auto p = moduleId in nodeIndex_;
        return p is null ? RectF.init : worldRectToView(scopeWorldRect(nodes_[*p]));
    }

    /**
     * Returns the selected wire's index in the document wire list.
     *
     * Returns:
     *   Index, or -1 when no wire is selected.
     */
    ptrdiff_t selectedWireIndex() {
        if (!hasSelectedWire_) {
            return -1;
        }
        foreach (i, ref w; ctx_.session.document().wires) {
            if (w.srcMod == selectedWire_.src && w.srcPort == selectedWire_.srcPort && w.dstMod == selectedWire_.dst
                    && w.dstPort == selectedWire_.dstPort) {
                return cast(ptrdiff_t) i;
            }
        }
        return -1;
    }

    /**
     * Selects a wire by document index.
     *
     * Params:
     *   wireIndex = Index into the document wire list.
     *
     * Returns:
     *   True if the index was valid.
     */
    bool selectWire(size_t wireIndex) {
        const doc = ctx_.session.document();
        if (wireIndex >= doc.wires.length) {
            return false;
        }
        const w = doc.wires[wireIndex];
        selectedWire_ = WireKey(w.srcMod, w.srcPort, w.dstMod, w.dstPort);
        hasSelectedWire_ = true;
        invalidate();
        return true;
    }

    /**
     * Clears the wire selection.
     */
    void clearWireSelection() {
        hasSelectedWire_ = false;
        invalidate();
    }

    /**
     * Returns a view point inside the bounds that is not over any node, port, badge, wire, or mini-scope.
     *
     * Returns:
     *   Empty canvas point (the view centre if the canvas is completely covered).
     */
    Point2F emptyCanvasPoint() {
        ensureCache();
        immutable float step = 12.0f;
        for (float y = bounds.y + step; y < bounds.bottom() - step; y += step) {
            for (float x = bounds.x + step; x < bounds.right() - step; x += step) {
                immutable Point2F p = Point2F(x, y);
                if (isClearCanvas(p)) {
                    return p;
                }
            }
        }
        return bounds.center();
    }

    /**
     * Reports whether a pointer drag (pan, node move, or cable) is in progress.
     *
     * Returns:
     *   True while dragging.
     */
    bool isDragging() const {
        return drag_ != DragMode.none;
    }

    /**
     * Hit-tests the patchbay at a view point (ports first, then badges, nodes topmost-first, then wires).
     *
     * Params:
     *   p = Absolute view point.
     *
     * Returns:
     *   Hit description.
     */
    PatchbayHit hitTestAt(Point2F p) {
        ensureCache();
        PatchbayHit h;
        if (!bounds.contains(p)) {
            return h;
        }
        float bestD = portHitRadius();
        bool havePort = false;
        foreach_reverse (ref n; nodes_) {
            foreach (dirIdx; 0 .. 2) {
                const(NodePort)[] ports = dirIdx == 0 ? n.outputs : n.inputs;
                foreach (ref port; ports) {
                    Point2F w;
                    portWorldPosition(n, port.index, w);
                    immutable float d = (worldToView(w) - p).length();
                    if (d < bestD || (!havePort && d <= bestD)) {
                        bestD = d;
                        havePort = true;
                        h = PatchbayHit(dirIdx == 0 ? PatchbayHitKind.outputPort : PatchbayHitKind.inputPort, n.id,
                            port.index);
                    }
                }
            }
        }
        if (havePort) {
            return h;
        }
        foreach_reverse (ref n; nodes_) {
            immutable RectF r = worldRectToView(nodeWorldRect(n));
            if (!r.contains(p)) {
                continue;
            }
            if (!n.isOutput) {
                foreach (bi; 0 .. 3) {
                    immutable PatchbayBadge b = cast(PatchbayBadge) bi;
                    if (worldRectToView(badgeWorldRect(n, b)).contains(p)) {
                        h.kind = PatchbayHitKind.badge;
                        h.moduleId = n.id;
                        h.badge = b;
                        return h;
                    }
                }
            }
            h.kind = PatchbayHitKind.node;
            h.moduleId = n.id;
            return h;
        }
        immutable ptrdiff_t wi = wireAt(p);
        if (wi >= 0) {
            h.kind = PatchbayHitKind.wire;
            h.wireIndex = wi;
        }
        return h;
    }

    /**
     * Toggles a header badge flag: mute and bypass are undoable document edits, solo is transient.
     *
     * Params:
     *   moduleId = Module id.
     *   badge = Badge.
     *
     * Returns:
     *   True if the session applied the change.
     */
    bool toggleBadge(uint moduleId, PatchbayBadge badge) {
        ensureCache();
        auto p = moduleId in nodeIndex_;
        if (p is null || nodes_[*p].isOutput) {
            return false;
        }
        bool ok;
        final switch (badge) {
        case PatchbayBadge.mute:
            ok = ctx_.session.doSetModuleMuted(moduleId, !nodes_[*p].muted);
            break;
        case PatchbayBadge.solo:
            ok = ctx_.session.setModuleSolo(moduleId, !ctx_.session.isModuleSoloed(moduleId));
            break;
        case PatchbayBadge.bypass:
            ok = ctx_.session.doSetModuleBypassed(moduleId, !nodes_[*p].bypassed);
            break;
        }
        invalidate();
        return ok;
    }

    /**
     * Deletes the selected wire, or else the selected module (never the output module).
     *
     * Returns:
     *   True if something was deleted.
     */
    bool deleteSelection() {
        if (hasSelectedWire_) {
            immutable WireKey k = selectedWire_;
            hasSelectedWire_ = false;
            invalidate();
            return ctx_.session.doDisconnectWire(k.src, k.srcPort, k.dst, k.dstPort);
        }
        immutable uint sel = ctx_.selectedModule();
        if (sel == 0) {
            return false;
        }
        return deleteModule(sel);
    }

    /**
     * Removes a module unless it is the output module.
     *
     * Params:
     *   moduleId = Module id.
     *
     * Returns:
     *   True if removed.
     */
    bool deleteModule(uint moduleId) {
        if (isOutputModule(moduleId)) {
            ctx_.setStatus("The output module cannot be deleted");
            return false;
        }
        if (!ctx_.session.doRemoveModule(moduleId)) {
            return false;
        }
        if (ctx_.selectedModule() == moduleId) {
            ctx_.selectModule(0);
        }
        invalidate();
        return true;
    }

    /**
     * Adds a module of the same type offset from the original and copies its parameter values (one undo step).
     *
     * Params:
     *   moduleId = Module to duplicate.
     *
     * Returns:
     *   New module id, or 0 on failure (the output module is never duplicated).
     */
    uint duplicateModule(uint moduleId) {
        if (isOutputModule(moduleId)) {
            return 0;
        }
        string typeId;
        string name;
        float x = 0.0f;
        float y = 0.0f;
        float[] params;
        bool found = false;
        foreach (ref m; ctx_.session.document().modules) {
            if (m.id == moduleId) {
                typeId = m.typeId;
                name = m.name;
                x = m.posX;
                y = m.posY;
                params = m.paramValues.dup;
                found = true;
                break;
            }
        }
        if (!found) {
            return 0;
        }
        ctx_.session.beginEditGroup("Duplicate Module");
        immutable uint newId = ctx_.session.doAddModule(typeId, name, x + 30.0f, y + 30.0f);
        if (newId != 0) {
            foreach (pi, v; params) {
                ctx_.session.doSetParam(newId, cast(uint) pi, v);
            }
        }
        immutable bool ok = ctx_.session.endEditGroup();
        if (!ok || newId == 0) {
            return 0;
        }
        ctx_.selectModule(newId);
        invalidate();
        return newId;
    }

    /**
     * Adds a module at a world position and selects it.
     *
     * Params:
     *   typeId = Registered type id.
     *   world = World position of the node's top-left corner.
     *
     * Returns:
     *   New module id, or 0 on failure.
     */
    uint addModuleAt(string typeId, Point2F world) {
        immutable uint newId = ctx_.session.doAddModule(typeId, "", world.x, world.y);
        if (newId != 0) {
            ctx_.selectModule(newId);
            hasSelectedWire_ = false;
        }
        invalidate();
        return newId;
    }

    /**
     * Builds the empty-canvas menu: one "Add <Category> ▸" entry per registry category (each opens a menu of
     * that category's modules), then view commands.
     *
     * Params:
     *   world = World position where new modules are placed.
     *   at = View position where follow-up menus open.
     *
     * Returns:
     *   Menu entries.
     */
    MenuItem[] addModuleMenuItems(Point2F world, Point2F at) {
        MenuItem[] items;
        foreach (cat; [ModuleCategory.synth, ModuleCategory.effect, ModuleCategory.control, ModuleCategory.core]) {
            if (categoryMenuItems(cat, world).length == 0) {
                continue;
            }
            items ~= MenuItem("Add " ~ categoryLabel(cat) ~ " ▸", categoryAction(cat, world, at));
        }
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem("Fit All", () { fitAll(); });
        items ~= MenuItem("Reset Zoom", () { resetZoom(); });
        return items;
    }

    /**
     * Builds the list of addable modules of one category (output modules are excluded).
     *
     * Params:
     *   category = Module category.
     *   world = World position where the chosen module is placed.
     *
     * Returns:
     *   Menu entries in registry order.
     */
    MenuItem[] categoryMenuItems(ModuleCategory category, Point2F world) {
        MenuItem[] items;
        foreach (ref d; ModuleRegistry.descriptors()) {
            if (d.category != category || d.isOutput) {
                continue;
            }
            items ~= MenuItem(d.displayName, addAction(d.typeId, world));
        }
        return items;
    }

    /**
     * Builds the context menu for a module node.
     *
     * Params:
     *   moduleId = Module id.
     *
     * Returns:
     *   Menu entries (Mute, Solo, Bypass, Duplicate, Delete).
     */
    MenuItem[] nodeMenuItems(uint moduleId) {
        ensureCache();
        auto p = moduleId in nodeIndex_;
        if (p is null) {
            return null;
        }
        immutable bool output = nodes_[*p].isOutput;
        immutable bool muted = nodes_[*p].muted;
        immutable bool bypassed = nodes_[*p].bypassed;
        immutable bool soloed = ctx_.session.isModuleSoloed(moduleId);
        immutable uint mid = moduleId;
        MenuItem[] items;
        items ~= MenuItem(muted ? "Unmute" : "Mute", () { toggleBadge(mid, PatchbayBadge.mute); }, !output);
        items ~= MenuItem(soloed ? "Unsolo" : "Solo", () { toggleBadge(mid, PatchbayBadge.solo); }, !output);
        items ~= MenuItem(bypassed ? "Enable" : "Bypass", () { toggleBadge(mid, PatchbayBadge.bypass); }, !output);
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem("Duplicate", () { duplicateModule(mid); }, !output);
        items ~= MenuItem("Delete", () { deleteModule(mid); }, !output, false, "⌫");
        return items;
    }

    /**
     * Executes view-level actions: zoomIn / zoomOut / zoomReset around the view centre, deleteCell /
     * deleteBlock delete the selection.
     *
     * Params:
     *   action = Action.
     *
     * Returns:
     *   True if consumed.
     */
    bool handleStudioAction(StudioAction action) {
        switch (action) {
        case StudioAction.zoomIn:
            zoomAround(bounds.center(), zoom_ * 1.25f);
            return true;
        case StudioAction.zoomOut:
            zoomAround(bounds.center(), zoom_ / 1.25f);
            return true;
        case StudioAction.zoomReset:
            resetZoom();
            return true;
        case StudioAction.deleteCell:
        case StudioAction.deleteBlock:
            return deleteSelection();
        default:
            return false;
        }
    }

    /**
     * Reports whether continuous frames are needed: during drags, or while any wire's source module reports a
     * nonzero telemetry peak (signal pulses).
     *
     * Returns:
     *   True while animating.
     */
    override bool isAnimating() {
        return drag_ != DragMode.none || pulsesActive();
    }

    /**
     * Reports whether any wire currently shows a signal pulse.
     *
     * Returns:
     *   True if a wire source has a peak above the pulse threshold.
     */
    bool pulsesActive() {
        ensureCache();
        foreach (ref w; wires_) {
            if (modulePeak(w.src) > PATCHBAY_PULSE_THRESHOLD) {
                return true;
            }
        }
        return false;
    }

    /**
     * Returns the module ids whose mini-scopes are shown (selected first, then most recently selected).
     *
     * Returns:
     *   Up to four ids.
     */
    uint[] scopeModules() {
        syncSelection();
        uint[] ids;
        foreach (idv; recentSelection_) {
            if (ids.length >= PATCHBAY_MAX_SCOPES) {
                break;
            }
            if ((idv in nodeIndex_) !is null) {
                ids ~= idv;
            }
        }
        return ids;
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        immutable PatchbayHit h = hitTestAt(e.pos);
        dragStart_ = e.pos;
        dragLast_ = e.pos;
        dragMoved_ = false;
        final switch (h.kind) {
        case PatchbayHitKind.outputPort:
            ctx_.selectModule(h.moduleId);
            hasSelectedWire_ = false;
            drag_ = DragMode.wire;
            dragModule_ = h.moduleId;
            wirePort_ = h.portIndex;
            wireCursor_ = e.pos;
            break;
        case PatchbayHitKind.badge:
            ctx_.selectModule(h.moduleId);
            toggleBadge(h.moduleId, h.badge);
            drag_ = DragMode.none;
            break;
        case PatchbayHitKind.inputPort:
        case PatchbayHitKind.node:
            ctx_.selectModule(h.moduleId);
            hasSelectedWire_ = false;
            drag_ = DragMode.node;
            dragModule_ = h.moduleId;
            {
                auto p = h.moduleId in nodeIndex_;
                immutable Point2F w = viewToWorld(e.pos);
                grabOffset_ = Point2F(w.x - nodes_[*p].x, w.y - nodes_[*p].y);
            }
            break;
        case PatchbayHitKind.wire:
            selectWire(cast(size_t) h.wireIndex);
            drag_ = DragMode.none;
            break;
        case PatchbayHitKind.none:
            if (e.clickCount >= 2) {
                fitAll();
                drag_ = DragMode.none;
            } else {
                hasSelectedWire_ = false;
                ctx_.selectModule(0);
                drag_ = DragMode.pan;
            }
            break;
        }
        invalidate();
        return true;
    }

    override bool onMouseMove(const ref MouseEvent e) {
        final switch (drag_) {
        case DragMode.none:
            return false;
        case DragMode.pan:
            panBy(e.pos.x - dragLast_.x, e.pos.y - dragLast_.y);
            dragLast_ = e.pos;
            return true;
        case DragMode.node:
            moveDraggedNode(e.pos);
            dragLast_ = e.pos;
            return true;
        case DragMode.wire:
            wireCursor_ = e.pos;
            dragLast_ = e.pos;
            invalidate();
            return true;
        }
    }

    override bool onMouseUp(const ref MouseEvent e) {
        immutable DragMode mode = drag_;
        if (mode == DragMode.node) {
            moveDraggedNode(e.pos);
        } else if (mode == DragMode.wire) {
            finishWireDrag(e.pos);
        }
        endDrag();
        return mode != DragMode.none;
    }

    override void onCaptureLost() {
        endDrag();
    }

    override bool onScroll(const ref ScrollEvent e) {
        if (hasModifier(e.modifiers, KeyModifiers.command)) {
            zoomAround(e.pos, zoom_ * exp(e.deltaY * 0.01f));
        } else {
            panBy(e.deltaX, e.deltaY);
        }
        return true;
    }

    override bool onMagnify(Point2F pos, float magnification) {
        if (!isFinite(magnification)) {
            return false;
        }
        zoomAround(pos, zoom_ * (1.0f + magnification));
        return true;
    }

    override bool onKeyDown(const ref KeyEvent e) {
        if (e.keyCode == KeyCode.deleteBackward || e.keyCode == KeyCode.forwardDelete) {
            if (!hasSelectedWire_ && ctx_.selectedModule() == 0) {
                return false;
            }
            deleteSelection();
            return true;
        }
        if (e.keyCode == KeyCode.escape && drag_ == DragMode.wire) {
            endDrag();
            return true;
        }
        return false;
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        ensureCache();
        syncSelection();
        requestTaps();
        r.pushClip(bounds);
        r.fillRect(bounds, theme.panelSunken);
        drawGrid(r, theme);
        drawWires(r, theme);
        if (drag_ == DragMode.wire) {
            drawRubberBand(r, theme);
        }
        foreach (ref n; nodes_) {
            drawNode(r, theme, n);
        }
        drawScopes(r, theme);
        r.popClip();
    }

    private MenuItem[] buildContextMenu(Point2F p) {
        immutable PatchbayHit h = hitTestAt(p);
        if (h.kind == PatchbayHitKind.node || h.kind == PatchbayHitKind.badge || h.kind == PatchbayHitKind.inputPort
                || h.kind == PatchbayHitKind.outputPort) {
            ctx_.selectModule(h.moduleId);
            hasSelectedWire_ = false;
            return nodeMenuItems(h.moduleId);
        }
        if (h.kind == PatchbayHitKind.wire) {
            selectWire(cast(size_t) h.wireIndex);
            return [MenuItem("Delete Wire", () { deleteSelection(); }, true, false, "⌫")];
        }
        return addModuleMenuItems(viewToWorld(p), p);
    }

    private void delegate() categoryAction(ModuleCategory category, Point2F world, Point2F at) {
        return () { openCategoryMenu(category, world, at); };
    }

    private void delegate() addAction(string typeId, Point2F world) {
        return () { addModuleAt(typeId, world); };
    }

    private void openCategoryMenu(ModuleCategory category, Point2F world, Point2F at) {
        UiContext ui = context();
        if (ui is null) {
            return;
        }
        MenuItem[] items = categoryMenuItems(category, world);
        if (items.length > 0) {
            ui.openContextMenu(items, at);
        }
    }

    private void moveDraggedNode(Point2F pos) {
        if (!dragMoved_ && (pos - dragStart_).length() < 2.0f) {
            return;
        }
        auto p = dragModule_ in nodeIndex_;
        if (p is null) {
            return;
        }
        immutable Point2F w = viewToWorld(pos);
        immutable float nx = w.x - grabOffset_.x;
        immutable float ny = w.y - grabOffset_.y;
        if (nx == nodes_[*p].x && ny == nodes_[*p].y) {
            return;
        }
        if (!groupOpen_) {
            ctx_.session.history().breakCoalesce();
            ctx_.session.beginEditGroup("Move Module");
            groupOpen_ = true;
        }
        dragMoved_ = true;
        ctx_.session.doMoveModulePosition(dragModule_, nx, ny);
        ensureCache();
        invalidate();
    }

    private void finishWireDrag(Point2F pos) {
        immutable PatchbayHit h = hitTestAt(pos);
        if (h.kind != PatchbayHitKind.inputPort) {
            return;
        }
        if (!canConnect(dragModule_, wirePort_, h.moduleId, h.portIndex)) {
            ctx_.setStatus("Incompatible connection");
            return;
        }
        if (!ctx_.session.doConnectWire(dragModule_, wirePort_, h.moduleId, h.portIndex)) {
            ctx_.setStatus("Connection rejected by the graph compiler");
        }
    }

    private void endDrag() {
        if (groupOpen_) {
            groupOpen_ = false;
            ctx_.session.endEditGroup();
            ctx_.session.history().breakCoalesce();
        }
        drag_ = DragMode.none;
        dragMoved_ = false;
        invalidate();
    }

    private bool canConnect(uint srcMod, ushort srcPort, uint dstMod, ushort dstPort) {
        ensureCache();
        if (srcMod == dstMod) {
            return false;
        }
        auto sp = srcMod in nodeIndex_;
        auto dp = dstMod in nodeIndex_;
        if (sp is null || dp is null) {
            return false;
        }
        PortKind sk;
        PortKind dk;
        if (!findPortKind(nodes_[*sp].outputs, srcPort, sk) || !findPortKind(nodes_[*dp].inputs, dstPort, dk)) {
            return false;
        }
        if (!arePortsCompatible(sk, dk)) {
            return false;
        }
        foreach (ref w; wires_) {
            if (w.src == srcMod && w.srcPort == srcPort && w.dst == dstMod && w.dstPort == dstPort) {
                return false;
            }
        }
        return true;
    }

    private static bool findPortKind(const(NodePort)[] ports, ushort index, out PortKind kind) {
        foreach (ref p; ports) {
            if (p.index == index) {
                kind = p.kind;
                return true;
            }
        }
        return false;
    }

    private bool isOutputModule(uint moduleId) {
        if (moduleId == 1) {
            return true;
        }
        ensureCache();
        auto p = moduleId in nodeIndex_;
        return p !is null && nodes_[*p].isOutput;
    }

    private void ensureCache() {
        immutable ulong rev = ctx_.documentRevision();
        if (cacheValid_ && rev == cachedRevision_) {
            return;
        }
        cacheValid_ = true;
        cachedRevision_ = rev;
        const doc = ctx_.session.document();
        nodes_.length = doc.modules.length;
        nodeIndex_ = null;
        foreach (i, ref m; doc.modules) {
            NodeCache n;
            n.id = m.id;
            n.name = m.name;
            n.typeId = m.typeId;
            n.x = isFinite(m.posX) ? m.posX : 0.0f;
            n.y = isFinite(m.posY) ? m.posY : 0.0f;
            n.muted = m.muted;
            n.bypassed = m.bypassed;
            const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(m.typeId);
            if (d !is null) {
                n.typeName = d.displayName;
                n.category = d.category;
                n.isOutput = d.isOutput || m.id == 1;
                foreach (pi, ref pd; d.ports) {
                    immutable NodePort np = NodePort(cast(ushort) pi, pd.kind, pd.name);
                    if (pd.dir == PortDirection.input) {
                        n.inputs ~= np;
                    } else {
                        n.outputs ~= np;
                    }
                }
            } else {
                n.typeName = m.typeId;
                n.category = ModuleCategory.effect;
                n.isOutput = m.id == 1;
            }
            immutable size_t rows = n.inputs.length > n.outputs.length ? n.inputs.length : n.outputs.length;
            n.w = PATCHBAY_NODE_WIDTH;
            n.h = PATCHBAY_HEADER_HEIGHT + PATCHBAY_TYPE_HEIGHT + cast(float)(rows > 0 ? rows : 1) * PATCHBAY_PORT_ROW
                + 6.0f;
            nodes_[i] = n;
            nodeIndex_[m.id] = i;
        }
        wires_.length = 0;
        foreach (ref w; doc.wires) {
            auto s = w.srcMod in nodeIndex_;
            auto t = w.dstMod in nodeIndex_;
            if (s is null || t is null) {
                continue;
            }
            PortKind k = PortKind.audioStereo;
            findPortKind(nodes_[*s].outputs, w.srcPort, k);
            wires_ ~= WireCache(w.srcMod, w.srcPort, w.dstMod, w.dstPort, w.gain, k, *s, *t);
        }
        if (hasSelectedWire_ && selectedWireIndex() < 0) {
            hasSelectedWire_ = false;
        }
    }

    private void syncSelection() {
        ensureCache();
        immutable ulong rev = ctx_.selectionRevision();
        if (rev != seenSelectionRevision_) {
            seenSelectionRevision_ = rev;
            immutable uint sel = ctx_.selectedModule();
            if (sel != 0) {
                uint[] next = [sel];
                foreach (idv; recentSelection_) {
                    if (idv != sel && next.length < 16) {
                        next ~= idv;
                    }
                }
                recentSelection_ = next;
            }
        }
        size_t keep = 0;
        foreach (idv; recentSelection_) {
            if ((idv in nodeIndex_) !is null) {
                recentSelection_[keep++] = idv;
            }
        }
        recentSelection_.length = keep;
    }

    private void requestTaps() {
        uint[PATCHBAY_MAX_SCOPES] taps;
        size_t k = 0;
        foreach (idv; recentSelection_) {
            if (k >= taps.length) {
                break;
            }
            if ((idv in nodeIndex_) !is null) {
                taps[k++] = idv;
            }
        }
        if (k == 0 && !tapsRequested_) {
            return;
        }
        if (tapsRequested_ && taps == requestedTaps_) {
            return;
        }
        requestedTaps_ = taps;
        tapsRequested_ = true;
        ctx_.requestScopeTaps(taps[0 .. k]);
    }

    private float modulePeak(uint moduleId) const {
        const g = &ctx_.telemetry.engine.graph;
        immutable size_t n = g.moduleCount < g.moduleIds.length ? g.moduleCount : g.moduleIds.length;
        foreach (i; 0 .. n) {
            if (g.moduleIds[i] == moduleId) {
                immutable float v = g.modulePeaks[i];
                return isFinite(v) ? abs(v) : 0.0f;
            }
        }
        return 0.0f;
    }

    private static float clampZoom(float z) {
        if (!isFinite(z)) {
            return 1.0f;
        }
        return z < PATCHBAY_MIN_ZOOM ? PATCHBAY_MIN_ZOOM : (z > PATCHBAY_MAX_ZOOM ? PATCHBAY_MAX_ZOOM : z);
    }

    private bool contentWorldRect(out RectF c) {
        if (nodes_.length == 0) {
            return false;
        }
        float x0 = float.max;
        float y0 = float.max;
        float x1 = -float.max;
        float y1 = -float.max;
        foreach (ref n; nodes_) {
            immutable RectF s = scopeWorldRect(n);
            x0 = n.x < x0 ? n.x : x0;
            y0 = n.y < y0 ? n.y : y0;
            x1 = n.x + n.w > x1 ? n.x + n.w : x1;
            y1 = s.bottom() > y1 ? s.bottom() : y1;
        }
        c = RectF(x0, y0, x1 - x0, y1 - y0);
        return true;
    }

    private void clampPan() {
        RectF c;
        if (!contentWorldRect(c)) {
            return;
        }
        immutable RectF v = worldRectToView(c);
        immutable float m = PATCHBAY_PAN_MARGIN;
        float dx = 0.0f;
        float dy = 0.0f;
        if (v.right() < bounds.x + m) {
            dx = bounds.x + m - v.right();
        } else if (v.x > bounds.right() - m) {
            dx = bounds.right() - m - v.x;
        }
        if (v.bottom() < bounds.y + m) {
            dy = bounds.y + m - v.bottom();
        } else if (v.y > bounds.bottom() - m) {
            dy = bounds.bottom() - m - v.y;
        }
        pan_ = Point2F(pan_.x + dx, pan_.y + dy);
    }

    private RectF worldRectToView(RectF w) const {
        immutable Point2F o = worldToView(Point2F(w.x, w.y));
        return RectF(o.x, o.y, w.w * zoom_, w.h * zoom_);
    }

    private static RectF nodeWorldRect(const ref NodeCache n) {
        return RectF(n.x, n.y, n.w, n.h);
    }

    private static RectF scopeWorldRect(const ref NodeCache n) {
        return RectF(n.x, n.y + n.h + PATCHBAY_SCOPE_GAP, n.w, PATCHBAY_SCOPE_HEIGHT);
    }

    private static RectF badgeWorldRect(const ref NodeCache n, PatchbayBadge b) {
        immutable float s = PATCHBAY_BADGE_SIZE;
        immutable float right = n.x + n.w - 4.0f - cast(float)(2 - cast(int) b) * (s + 2.0f);
        return RectF(right - s, n.y + (PATCHBAY_HEADER_HEIGHT - s) * 0.5f, s, s);
    }

    private static bool portWorldPosition(const ref NodeCache n, ushort portIndex, out Point2F w) {
        immutable float top = n.y + PATCHBAY_HEADER_HEIGHT + PATCHBAY_TYPE_HEIGHT + PATCHBAY_PORT_ROW * 0.5f;
        foreach (slot, ref p; n.inputs) {
            if (p.index == portIndex) {
                w = Point2F(n.x, top + cast(float) slot * PATCHBAY_PORT_ROW);
                return true;
            }
        }
        foreach (slot, ref p; n.outputs) {
            if (p.index == portIndex) {
                w = Point2F(n.x + n.w, top + cast(float) slot * PATCHBAY_PORT_ROW);
                return true;
            }
        }
        return false;
    }

    private float portHitRadius() const {
        immutable float r = (PATCHBAY_PORT_RADIUS + 3.0f) * zoom_;
        return r > 8.0f ? r : 8.0f;
    }

    private void wireCurve(const ref WireCache w, out Point2F p0, out Point2F c0, out Point2F c1, out Point2F p1) {
        Point2F a;
        Point2F b;
        portWorldPosition(nodes_[w.srcNode], w.srcPort, a);
        portWorldPosition(nodes_[w.dstNode], w.dstPort, b);
        p0 = worldToView(a);
        p1 = worldToView(b);
        curveControls(p0, p1, c0, c1);
    }

    private void curveControls(Point2F p0, Point2F p1, out Point2F c0, out Point2F c1) const {
        float dx = abs(p1.x - p0.x) * 0.5f;
        immutable float minDx = 40.0f * zoom_;
        dx = dx > minDx ? dx : minDx;
        c0 = Point2F(p0.x + dx, p0.y);
        c1 = Point2F(p1.x - dx, p1.y);
    }

    private static RectF curveBounds(Point2F p0, Point2F c0, Point2F c1, Point2F p1, float pad) {
        immutable float x0 = min4(p0.x, c0.x, c1.x, p1.x);
        immutable float x1 = max4(p0.x, c0.x, c1.x, p1.x);
        immutable float y0 = min4(p0.y, c0.y, c1.y, p1.y);
        immutable float y1 = max4(p0.y, c0.y, c1.y, p1.y);
        return RectF(x0 - pad, y0 - pad, x1 - x0 + 2.0f * pad, y1 - y0 + 2.0f * pad);
    }

    private static float min4(float a, float b, float c, float d) {
        immutable float ab = a < b ? a : b;
        immutable float cd = c < d ? c : d;
        return ab < cd ? ab : cd;
    }

    private static float max4(float a, float b, float c, float d) {
        immutable float ab = a > b ? a : b;
        immutable float cd = c > d ? c : d;
        return ab > cd ? ab : cd;
    }

    private ptrdiff_t wireAt(Point2F p) {
        ptrdiff_t best = -1;
        float bestD = PATCHBAY_WIRE_TOLERANCE;
        foreach (i, ref w; wires_) {
            Point2F p0, c0, c1, p1;
            wireCurve(w, p0, c0, c1, p1);
            if (!curveBounds(p0, c0, c1, p1, PATCHBAY_WIRE_TOLERANCE).contains(p)) {
                continue;
            }
            Point2F prev = p0;
            enum int segments = 32;
            foreach (s; 1 .. segments + 1) {
                immutable Point2F q = patchbayBezierPoint(p0, c0, c1, p1, cast(float) s / segments);
                immutable float d = patchbaySegmentDistance(p, prev, q);
                if (d <= bestD) {
                    bestD = d;
                    best = cast(ptrdiff_t) i;
                }
                prev = q;
            }
        }
        if (best < 0) {
            return -1;
        }
        immutable WireCache wc = wires_[best];
        foreach (i, ref dw; ctx_.session.document().wires) {
            if (dw.srcMod == wc.src && dw.srcPort == wc.srcPort && dw.dstMod == wc.dst && dw.dstPort == wc.dstPort) {
                return cast(ptrdiff_t) i;
            }
        }
        return -1;
    }

    private bool isClearCanvas(Point2F p) {
        if (hitTestAt(p).kind != PatchbayHitKind.none) {
            return false;
        }
        immutable float pad = portHitRadius() + 4.0f;
        foreach (ref n; nodes_) {
            immutable RectF r = worldRectToView(nodeWorldRect(n));
            immutable RectF s = worldRectToView(scopeWorldRect(n));
            if (RectF(r.x - pad, r.y - pad, r.w + 2.0f * pad, s.bottom() - r.y + 2.0f * pad).contains(p)) {
                return false;
            }
        }
        return true;
    }

    private ColorRGBA categoryColor(const ref StudioTheme theme, ModuleCategory c) const {
        return theme.categoryColor(c);
    }

    private static string categoryLabel(ModuleCategory c) {
        final switch (c) {
        case ModuleCategory.core:
            return "Core";
        case ModuleCategory.synth:
            return "Synth";
        case ModuleCategory.effect:
            return "Effect";
        case ModuleCategory.control:
            return "Control";
        }
    }

    private void drawGrid(IRenderer2D r, const ref StudioTheme theme) {
        immutable float step = 40.0f * zoom_;
        if (step < 10.0f) {
            return;
        }
        immutable Point2F w0 = viewToWorld(Point2F(bounds.x, bounds.y));
        float gx = floor(w0.x / 40.0f) * 40.0f;
        for (float x = worldToView(Point2F(gx, 0.0f)).x; x < bounds.right(); x += step) {
            if (x >= bounds.x) {
                r.fillRect(RectF(x, bounds.y, 1.0f, bounds.h), theme.gridLine);
            }
        }
        float gy = floor(w0.y / 40.0f) * 40.0f;
        for (float y = worldToView(Point2F(0.0f, gy)).y; y < bounds.bottom(); y += step) {
            if (y >= bounds.y) {
                r.fillRect(RectF(bounds.x, y, bounds.w, 1.0f), theme.gridLine);
            }
        }
    }

    private void drawWires(IRenderer2D r, const ref StudioTheme theme) {
        immutable ptrdiff_t sel = selectedWireIndex();
        WireKey selKey = selectedWire_;
        immutable float zw = zoom_ < 0.5f ? 0.5f : (zoom_ > 2.0f ? 2.0f : zoom_);
        immutable float phase = cast(float)(ctx_.frame() % 90) / 90.0f;
        foreach (i, ref w; wires_) {
            Point2F p0, c0, c1, p1;
            wireCurve(w, p0, c0, c1, p1);
            immutable float width = theme.wireWidth * zw * gainScale(w.gain);
            if (curveBounds(p0, c0, c1, p1, width + 6.0f).intersect(bounds).isEmpty()) {
                continue;
            }
            immutable ColorRGBA col = theme.portColor(w.kind);
            immutable bool selected = sel >= 0 && w.src == selKey.src && w.srcPort == selKey.srcPort
                && w.dst == selKey.dst && w.dstPort == selKey.dstPort;
            if (selected) {
                r.drawBezier(p0, c0, c1, p1, width + 4.0f, theme.accentHot);
            }
            immutable float peak = modulePeak(w.src);
            if (peak > PATCHBAY_PULSE_THRESHOLD) {
                immutable float glow = peak > 1.0f ? 1.0f : peak;
                r.drawBezier(p0, c0, c1, p1, width + 5.0f, col.withAlpha(0.10f + 0.25f * glow));
            }
            drawStyledWire(r, p0, c0, c1, p1, width, col, StudioTheme.wireDash(wireKindOf(w.kind)));
            if (peak > PATCHBAY_PULSE_THRESHOLD) {
                float t = phase + cast(float)(i % 7) * 0.13f;
                t -= floor(t);
                fillCircle(r, patchbayBezierPoint(p0, c0, c1, p1, t), width + 1.5f, theme.emphasize(col, 0.35f));
            }
        }
    }

    private static float gainScale(float gain) {
        if (!isFinite(gain)) {
            return 1.0f;
        }
        immutable float g = 0.5f + 0.5f * abs(gain);
        return g < 0.5f ? 0.5f : (g > 2.5f ? 2.5f : g);
    }

    private void drawRubberBand(IRenderer2D r, const ref StudioTheme theme) {
        auto sp = dragModule_ in nodeIndex_;
        if (sp is null) {
            return;
        }
        Point2F a;
        if (!portWorldPosition(nodes_[*sp], wirePort_, a)) {
            return;
        }
        PortKind k = PortKind.audioStereo;
        findPortKind(nodes_[*sp].outputs, wirePort_, k);
        immutable Point2F p0 = worldToView(a);
        Point2F c0, c1;
        curveControls(p0, wireCursor_, c0, c1);
        drawStyledWire(r, p0, c0, c1, wireCursor_, theme.wireWidth * 1.5f, theme.portColor(k),
            StudioTheme.wireDash(wireKindOf(k)));
    }

    private void drawNode(IRenderer2D r, const ref StudioTheme theme, const ref NodeCache n) {
        immutable RectF v = worldRectToView(nodeWorldRect(n));
        immutable float portR = PATCHBAY_PORT_RADIUS * zoom_ + 2.0f;
        if (RectF(v.x - portR, v.y, v.w + 2.0f * portR, v.h).intersect(bounds).isEmpty()) {
            return;
        }
        immutable bool selected = ctx_.selectedModule() == n.id;
        immutable float rad = theme.radiusMd * zoom_;
        immutable ColorRGBA cat = categoryColor(theme, n.category);
        r.fillRoundedRect(v.translate(0.0f, 2.0f * zoom_), rad, theme.shadow);
        if (n.isOutput) {
            r.fillRoundedRectGradient(v, rad, theme.emphasize(theme.panelRaised, 0.04f), theme.panelRaised);
        } else {
            r.fillRoundedRect(v, rad, theme.panelRaised);
        }
        immutable RectF header = RectF(v.x, v.y, v.w, PATCHBAY_HEADER_HEIGHT * zoom_);
        r.fillRoundedRect(header, rad, cat.withAlpha(theme.categoryTint(n.isOutput)));
        r.fillRect(RectF(v.x, v.y + rad, 3.0f * zoom_, v.h - 2.0f * rad), cat);
        if (n.muted || n.bypassed) {
            drawHatch(r, RectF(v.x, header.bottom(), v.w, v.h - header.h), theme.mutedHatch,
                (n.muted ? 6.0f : 11.0f) * zoom_);
        }
        if (selected) {
            r.strokeRoundedRect(v, rad, 2.0f, theme.accentHot);
            r.strokeRoundedRect(v.inset(-3.0f), rad + 3.0f, 1.0f, theme.accentHot);
        } else if (n.isOutput) {
            r.strokeRoundedRect(v, rad, 2.0f, theme.categoryCore);
        } else {
            r.strokeRoundedRect(v, rad, theme.borderWidth, theme.border);
        }
        immutable float titleSize = theme.fontSizeBody * zoom_;
        immutable float smallSize = theme.fontSizeSmall * zoom_;
        if (titleSize >= 5.0f) {
            r.pushClip(RectF(v.x + 4.0f * zoom_, v.y, v.w - 8.0f * zoom_, v.h));
            immutable float badgeSpace = n.isOutput ? 0.0f : 3.0f * (PATCHBAY_BADGE_SIZE + 2.0f) * zoom_;
            r.pushClip(RectF(v.x, v.y, v.w - badgeSpace - 6.0f * zoom_, header.h));
            immutable float lh = r.lineHeight(FontId.ui, titleSize);
            r.drawText(Point2F(v.x + 8.0f * zoom_, v.y + (header.h - lh) * 0.5f), n.name, FontId.ui, titleSize,
                n.muted ? theme.textDim : theme.text);
            r.popClip();
            immutable float slh = r.lineHeight(FontId.ui, smallSize);
            r.drawText(Point2F(v.x + 8.0f * zoom_, v.y + header.h + (PATCHBAY_TYPE_HEIGHT * zoom_ - slh) * 0.5f),
                n.typeName, FontId.ui, smallSize, theme.textDim);
            if (zoom_ >= 0.75f) {
                drawPortLabels(r, theme, n, smallSize, slh);
            }
            r.popClip();
        }
        if (!n.isOutput) {
            drawBadges(r, theme, n);
        }
        drawPorts(r, theme, n);
    }

    private static void drawHatch(IRenderer2D r, RectF area, ColorRGBA color, float spacing) {
        if (area.isEmpty() || !(spacing > 1.0f)) {
            return;
        }
        r.pushClip(area);
        for (float d = -area.h; d < area.w; d += spacing) {
            r.drawLine(Point2F(area.x + d, area.bottom()), Point2F(area.x + d + area.h, area.y), 1.0f, color);
        }
        r.popClip();
    }

    private Point2F[] wireScratch_;

    private void drawStyledWire(IRenderer2D r, Point2F p0, Point2F c0, Point2F c1, Point2F p1, float width,
            ColorRGBA col, WireDash dash) {
        final switch (dash) {
        case WireDash.solid:
            r.drawBezier(p0, c0, c1, p1, width, col);
            break;
        case WireDash.dashed:
            sampleBezier(p0, c0, c1, p1, 2.0f, wireScratch_);
            drawDashedPolyline(r, wireScratch_, width, col, 9.0f * zoom_, 5.0f * zoom_);
            break;
        case WireDash.dotted:
            sampleBezier(p0, c0, c1, p1, 2.0f, wireScratch_);
            drawDashedPolyline(r, wireScratch_, width * 1.25f, col, 0.01f, 4.5f * zoom_ + width);
            break;
        case WireDash.doubled:
            sampleBezier(p0, c0, c1, p1, 2.0f, wireScratch_);
            drawOffsetPair(r, wireScratch_, width, col);
            break;
        }
    }

    private static void drawOffsetPair(IRenderer2D r, const(Point2F)[] pts, float width, ColorRGBA col) {
        if (pts.length < 2) {
            return;
        }
        immutable float off = width * 0.9f;
        immutable float lw = width * 0.65f;
        foreach (i; 1 .. pts.length) {
            immutable Point2F d = pts[i] - pts[i - 1];
            immutable float len = d.length();
            if (!(len > 0.0f)) {
                continue;
            }
            immutable Point2F nrm = Point2F(-d.y / len * off, d.x / len * off);
            r.drawLine(pts[i - 1] + nrm, pts[i] + nrm, lw, col);
            r.drawLine(pts[i - 1] - nrm, pts[i] - nrm, lw, col);
        }
    }

    private static void drawPortGlyph(IRenderer2D r, const ref StudioTheme theme, Point2F q, float pr, PortKind kind,
            bool input) {
        immutable ColorRGBA c = theme.portColor(kind);
        final switch (wireKindOf(kind)) {
        case WireKind.audio:
            fillCircle(r, q, pr, c);
            if (input) {
                fillCircle(r, q, pr * 0.45f, theme.panelSunken);
            }
            break;
        case WireKind.sidechain:
            fillCircle(r, q, pr, c);
            fillCircle(r, q, pr * 0.72f, theme.panelSunken);
            fillCircle(r, q, pr * 0.48f, c);
            if (input) {
                fillCircle(r, q, pr * 0.2f, theme.panelSunken);
            }
            break;
        case WireKind.event:
            immutable float h = pr * 0.9f;
            r.fillRoundedRect(RectF(q.x - h, q.y - h, 2.0f * h, 2.0f * h), pr * 0.15f, c);
            if (input) {
                immutable float k = h * 0.45f;
                r.fillRect(RectF(q.x - k, q.y - k, 2.0f * k, 2.0f * k), theme.panelSunken);
            }
            break;
        case WireKind.cv:
            immutable float d = pr * 1.15f;
            immutable int strips = 9;
            foreach (s; 0 .. strips) {
                immutable float y0 = q.y - d + 2.0f * d * s / strips;
                immutable float yc = y0 + d / strips;
                immutable float half = d - abs(yc - q.y);
                r.fillRect(RectF(q.x - half, y0, 2.0f * half, 2.0f * d / strips + 0.25f), c);
            }
            if (input) {
                immutable float k = d * 0.32f;
                r.fillRect(RectF(q.x - k, q.y - k, 2.0f * k, 2.0f * k), theme.panelSunken);
            }
            break;
        }
    }

    private void drawPortLabels(IRenderer2D r, const ref StudioTheme theme, const ref NodeCache n, float size,
            float lh) {
        foreach (ref p; n.inputs) {
            Point2F w;
            portWorldPosition(n, p.index, w);
            immutable Point2F q = worldToView(w);
            r.drawText(Point2F(q.x + 9.0f * zoom_, q.y - lh * 0.5f), p.name, FontId.ui, size, theme.textDim);
        }
        foreach (ref p; n.outputs) {
            Point2F w;
            portWorldPosition(n, p.index, w);
            immutable Point2F q = worldToView(w);
            immutable float tw = r.measureText(p.name, FontId.ui, size);
            r.drawText(Point2F(q.x - 9.0f * zoom_ - tw, q.y - lh * 0.5f), p.name, FontId.ui, size, theme.textDim);
        }
    }

    private void drawBadges(IRenderer2D r, const ref StudioTheme theme, const ref NodeCache n) {
        immutable bool[3] active = [n.muted, ctx_.session.isModuleSoloed(n.id), n.bypassed];
        immutable ColorRGBA[3] on = [theme.danger, theme.warning, theme.accent];
        static immutable string[3] letters = ["M", "S", "B"];
        immutable float size = theme.fontSizeSmall * zoom_;
        foreach (b; 0 .. 3) {
            immutable RectF br = worldRectToView(badgeWorldRect(n, cast(PatchbayBadge) b));
            r.fillRoundedRect(br, theme.radiusSm * zoom_, active[b] ? on[b] : theme.panelSunken);
            r.strokeRoundedRect(br, theme.radiusSm * zoom_, theme.borderWidth, theme.borderStrong);
            if (size >= 5.0f) {
                immutable float lh = r.lineHeight(FontId.ui, size);
                immutable float tw = r.measureText(letters[b], FontId.ui, size);
                r.drawText(Point2F(br.x + (br.w - tw) * 0.5f, br.y + (br.h - lh) * 0.5f), letters[b], FontId.ui, size,
                    active[b] ? theme.accentText : theme.textDim);
            }
        }
    }

    private void drawPorts(IRenderer2D r, const ref StudioTheme theme, const ref NodeCache n) {
        immutable float pr = PATCHBAY_PORT_RADIUS * zoom_;
        immutable bool wiring = drag_ == DragMode.wire;
        foreach (ref p; n.inputs) {
            Point2F w;
            portWorldPosition(n, p.index, w);
            immutable Point2F q = worldToView(w);
            if (wiring && canConnect(dragModule_, wirePort_, n.id, p.index)) {
                immutable bool hot = (wireCursor_ - q).length() <= portHitRadius();
                fillCircle(r, q, pr + (hot ? 5.0f : 3.0f), (hot ? theme.accentHot : theme.success).withAlpha(0.6f));
            }
            drawPortGlyph(r, theme, q, pr, p.kind, true);
        }
        foreach (ref p; n.outputs) {
            Point2F w;
            portWorldPosition(n, p.index, w);
            immutable Point2F q = worldToView(w);
            if (wiring && n.id == dragModule_ && p.index == wirePort_) {
                fillCircle(r, q, pr + 3.0f, theme.accentHot.withAlpha(0.6f));
            }
            drawPortGlyph(r, theme, q, pr, p.kind, false);
        }
    }

    private void drawScopes(IRenderer2D r, const ref StudioTheme theme) {
        size_t shown = 0;
        foreach (idv; recentSelection_) {
            if (shown >= PATCHBAY_MAX_SCOPES) {
                break;
            }
            auto p = idv in nodeIndex_;
            if (p is null) {
                continue;
            }
            shown++;
            immutable RectF sr = worldRectToView(scopeWorldRect(nodes_[*p]));
            if (sr.intersect(bounds).isEmpty()) {
                continue;
            }
            float[] left;
            float[] right;
            immutable size_t n = ctx_.scopes.snapshot(idv, PATCHBAY_SCOPE_FRAMES, left, right);
            r.fillRoundedRect(sr, theme.radiusSm * zoom_, theme.trackerBackground);
            r.strokeRoundedRect(sr, theme.radiusSm * zoom_, theme.borderWidth, theme.border);
            r.fillRect(RectF(sr.x, sr.center().y, sr.w, 1.0f), theme.gridLine);
            if (n < 2) {
                continue;
            }
            enum size_t points = 64;
            scopeScratch_.length = points;
            immutable float half = sr.h * 0.45f;
            foreach (k; 0 .. points) {
                immutable size_t si = k * (n - 1) / (points - 1);
                float s = (left[si] + right[si]) * 0.5f;
                s = isFinite(s) ? (s < -1.0f ? -1.0f : (s > 1.0f ? 1.0f : s)) : 0.0f;
                scopeScratch_[k] = Point2F(sr.x + sr.w * cast(float) k / cast(float)(points - 1), sr.center().y - s * half);
            }
            r.drawPolyline(scopeScratch_, 1.25f, theme.success);
        }
    }
}
