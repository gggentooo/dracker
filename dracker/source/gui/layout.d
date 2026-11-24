/**
 * File:         source/gui/layout.d
 * Module:       gui.layout
 * Phase:        Phase 7.5 — Retained Split-Pane & Docking Layout Engine
 *
 * Purpose:
 *   Pure layout math for the studio shell: rectangle slicing helpers, a flex row/column solver (fixed and
 *   weighted items, gaps, padding, min/max sizes), and a retained SplitPaneNode tree (horizontal/vertical
 *   splits with ratios, per-side minimum sizes, and splitter bars) that arranges named dock leaves, hit-tests
 *   splitters and leaves, and applies min-clamped splitter drags. DockLayout owns a tree plus drag state.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Geometry is in logical points with a top-left origin. Functions never throw; degenerate
 *   inputs (negative sizes, NaN ratios, over-constrained minimums) are clamped to non-negative results.
 *
 * Dependencies:
 *   Internal: gui.renderer (Point2F, RectF)
 *   External: std.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum Axis { horizontal, vertical }; struct Insets
 *   - RectF takeLeft/takeRight/takeTop/takeBottom(ref RectF, float); void splitRect(RectF, Axis, float ratio, float gap, out RectF, out RectF)
 *   - RectF centeredRect(RectF, float w, float h); RectF clampRectInside(RectF, RectF); float clampf(float, float, float)
 *   - struct FlexItem; void layoutFlexInto(RectF, const(FlexItem)[], Axis, float gap, Insets, RectF[]); RectF[] layoutFlex(...)
 *   - final class SplitPaneNode : leaf(id) / split(...), arrange(RectF), splitterAt(Point2F), leafAt(Point2F), findLeaf(id),
 *       leaves(), collectSplits(ref SplitPaneNode[]), clampFirstLength(float), setFirstLength(float)
 *   - final class DockLayout : arrange(RectF), splitterAt, leafAt, leafBounds(id), beginDrag/dragTo/endDrag
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.layout;

import std.math : isFinite;

import gui.renderer : Point2F, RectF;

/**
 * Main layout axis: horizontal lays items left-to-right, vertical lays items top-to-bottom.
 */
enum Axis : ubyte {
    horizontal = 0,
    vertical = 1
}

/**
 * Per-edge padding in logical points.
 */
struct Insets {
    float left = 0.0f;
    float top = 0.0f;
    float right = 0.0f;
    float bottom = 0.0f;

    @safe nothrow pure @nogc:

    /**
     * Builds uniform insets.
     *
     * Params:
     *   v = Inset applied to every edge.
     *
     * Returns:
     *   Uniform insets.
     */
    static Insets all(float v) {
        return Insets(v, v, v, v);
    }

    /**
     * Builds symmetric insets.
     *
     * Params:
     *   horizontal = Left and right inset.
     *   vertical = Top and bottom inset.
     *
     * Returns:
     *   Symmetric insets.
     */
    static Insets symmetric(float horizontal, float vertical) {
        return Insets(horizontal, vertical, horizontal, vertical);
    }

    /**
     * Shrinks a rectangle by these insets (never producing negative sizes).
     *
     * Params:
     *   r = Outer rectangle.
     *
     * Returns:
     *   Inner rectangle.
     */
    RectF apply(RectF r) const {
        immutable float w = r.w - left - right;
        immutable float h = r.h - top - bottom;
        return RectF(r.x + left, r.y + top, w > 0.0f ? w : 0.0f, h > 0.0f ? h : 0.0f);
    }

    /**
     * Returns the summed inset along an axis.
     *
     * Params:
     *   axis = Axis to sum.
     *
     * Returns:
     *   left + right for horizontal, top + bottom for vertical.
     */
    float along(Axis axis) const {
        return axis == Axis.horizontal ? left + right : top + bottom;
    }
}

/**
 * Clamps v into [lo, hi]; NaN maps to lo, and hi < lo yields lo.
 *
 * Params:
 *   v = Value.
 *   lo = Lower bound.
 *   hi = Upper bound.
 *
 * Returns:
 *   Clamped value.
 */
float clampf(float v, float lo, float hi) @safe nothrow pure @nogc {
    if (!(v >= lo)) {
        return lo;
    }
    if (v > hi) {
        return hi > lo ? hi : lo;
    }
    return v;
}

/**
 * Cuts a strip of the given width off the left of r.
 *
 * Params:
 *   r = Rectangle to cut; shrinks to the remainder.
 *   amount = Strip width (clamped to [0, r.w]).
 *
 * Returns:
 *   The removed strip.
 */
RectF takeLeft(ref RectF r, float amount) @safe nothrow pure @nogc {
    immutable float a = clampf(amount, 0.0f, r.w);
    immutable RectF strip = RectF(r.x, r.y, a, r.h);
    r = RectF(r.x + a, r.y, r.w - a, r.h);
    return strip;
}

/**
 * Cuts a strip of the given width off the right of r.
 *
 * Params:
 *   r = Rectangle to cut; shrinks to the remainder.
 *   amount = Strip width (clamped to [0, r.w]).
 *
 * Returns:
 *   The removed strip.
 */
RectF takeRight(ref RectF r, float amount) @safe nothrow pure @nogc {
    immutable float a = clampf(amount, 0.0f, r.w);
    immutable RectF strip = RectF(r.right() - a, r.y, a, r.h);
    r = RectF(r.x, r.y, r.w - a, r.h);
    return strip;
}

/**
 * Cuts a strip of the given height off the top of r.
 *
 * Params:
 *   r = Rectangle to cut; shrinks to the remainder.
 *   amount = Strip height (clamped to [0, r.h]).
 *
 * Returns:
 *   The removed strip.
 */
RectF takeTop(ref RectF r, float amount) @safe nothrow pure @nogc {
    immutable float a = clampf(amount, 0.0f, r.h);
    immutable RectF strip = RectF(r.x, r.y, r.w, a);
    r = RectF(r.x, r.y + a, r.w, r.h - a);
    return strip;
}

/**
 * Cuts a strip of the given height off the bottom of r.
 *
 * Params:
 *   r = Rectangle to cut; shrinks to the remainder.
 *   amount = Strip height (clamped to [0, r.h]).
 *
 * Returns:
 *   The removed strip.
 */
RectF takeBottom(ref RectF r, float amount) @safe nothrow pure @nogc {
    immutable float a = clampf(amount, 0.0f, r.h);
    immutable RectF strip = RectF(r.x, r.bottom() - a, r.w, a);
    r = RectF(r.x, r.y, r.w, r.h - a);
    return strip;
}

/**
 * Splits r along an axis at a ratio of the space remaining after the gap.
 *
 * Params:
 *   r = Rectangle to split.
 *   axis = Horizontal splits side-by-side, vertical splits top/bottom.
 *   ratio = Fraction in [0, 1] given to the first part (NaN treated as 0.5).
 *   gap = Space between the parts.
 *   first = Receives the left/top part.
 *   second = Receives the right/bottom part.
 */
void splitRect(RectF r, Axis axis, float ratio, float gap, out RectF first, out RectF second) @safe nothrow pure @nogc {
    immutable float total = axis == Axis.horizontal ? r.w : r.h;
    immutable float g = clampf(gap, 0.0f, total > 0.0f ? total : 0.0f);
    immutable float avail = total - g > 0.0f ? total - g : 0.0f;
    immutable float t = isFinite(ratio) ? clampf(ratio, 0.0f, 1.0f) : 0.5f;
    immutable float a = avail * t;
    if (axis == Axis.horizontal) {
        first = RectF(r.x, r.y, a, r.h);
        second = RectF(r.x + a + g, r.y, avail - a, r.h);
    } else {
        first = RectF(r.x, r.y, r.w, a);
        second = RectF(r.x, r.y + a + g, r.w, avail - a);
    }
}

/**
 * Centers a w x h rectangle inside outer (sizes clamped to outer).
 *
 * Params:
 *   outer = Container.
 *   w = Desired width.
 *   h = Desired height.
 *
 * Returns:
 *   Centered rectangle.
 */
RectF centeredRect(RectF outer, float w, float h) @safe nothrow pure @nogc {
    immutable float cw = clampf(w, 0.0f, outer.w);
    immutable float ch = clampf(h, 0.0f, outer.h);
    return RectF(outer.x + (outer.w - cw) * 0.5f, outer.y + (outer.h - ch) * 0.5f, cw, ch);
}

/**
 * Moves r (without resizing unless it is larger than container) so that it lies inside container.
 *
 * Params:
 *   r = Rectangle to place.
 *   container = Bounding area, e.g. the window viewport.
 *
 * Returns:
 *   Shifted (and if necessary shrunk) rectangle.
 */
RectF clampRectInside(RectF r, RectF container) @safe nothrow pure @nogc {
    immutable float w = clampf(r.w, 0.0f, container.w);
    immutable float h = clampf(r.h, 0.0f, container.h);
    immutable float x = clampf(r.x, container.x, container.right() - w);
    immutable float y = clampf(r.y, container.y, container.bottom() - h);
    return RectF(x, y, w, h);
}

/**
 * One item of a flex row/column. fixed > 0 requests an exact main-axis size; otherwise weight > 0 shares the
 * remaining space proportionally. Both are clamped into [minSize, maxSize].
 */
struct FlexItem {
    float fixed = 0.0f;
    float weight = 1.0f;
    float minSize = 0.0f;
    float maxSize = float.infinity;

    @safe nothrow pure @nogc:

    /**
     * Builds a fixed-size item.
     *
     * Params:
     *   size = Main-axis size.
     *
     * Returns:
     *   Fixed item.
     */
    static FlexItem fixedSize(float size) {
        return FlexItem(size, 0.0f, 0.0f, float.infinity);
    }

    /**
     * Builds a weighted item.
     *
     * Params:
     *   w = Share weight.
     *   minSize = Minimum main-axis size.
     *   maxSize = Maximum main-axis size.
     *
     * Returns:
     *   Weighted item.
     */
    static FlexItem weighted(float w, float minSize = 0.0f, float maxSize = float.infinity) {
        return FlexItem(0.0f, w, minSize, maxSize);
    }

    /**
     * Reports whether this item uses a fixed size.
     *
     * Returns:
     *   True if fixed > 0.
     */
    bool isFixed() const {
        return fixed > 0.0f;
    }
}

/**
 * Solves a flex layout into a caller-provided output buffer. Fixed items get their size; weighted items share the
 * remainder with iterative min/max freezing. When minimums overflow the container, items keep their minimums and
 * the run extends past the end (callers can clip). Cross-axis size fills the padded container.
 *
 * Params:
 *   bounds = Container rectangle.
 *   items = Item specifications.
 *   axis = Main axis.
 *   gap = Space between consecutive items.
 *   padding = Container padding.
 *   outRects = Receives one rectangle per item (length must be >= items.length).
 */
void layoutFlexInto(RectF bounds, const(FlexItem)[] items, Axis axis, float gap, Insets padding, RectF[] outRects) @safe nothrow pure {
    assert(outRects.length >= items.length, "layoutFlexInto output buffer too small");
    immutable size_t n = items.length;
    if (n == 0) {
        return;
    }
    immutable RectF inner = padding.apply(bounds);
    immutable float mainLen = axis == Axis.horizontal ? inner.w : inner.h;
    immutable float g = gap > 0.0f ? gap : 0.0f;
    float remaining = mainLen - g * cast(float)(n - 1);
    auto sizes = new float[n];
    auto frozen = new bool[n];
    float totalWeight = 0.0f;
    foreach (i, ref const it; items) {
        immutable float lo = it.minSize > 0.0f ? it.minSize : 0.0f;
        immutable float hi = it.maxSize > lo ? it.maxSize : lo;
        if (it.isFixed() || !(it.weight > 0.0f)) {
            sizes[i] = clampf(it.isFixed() ? it.fixed : 0.0f, lo, hi);
            frozen[i] = true;
            remaining -= sizes[i];
        } else {
            sizes[i] = lo;
            totalWeight += it.weight;
        }
    }
    bool changed = true;
    while (changed && totalWeight > 0.0f) {
        changed = false;
        immutable float pool = remaining > 0.0f ? remaining : 0.0f;
        immutable float perWeight = pool / totalWeight;
        foreach (i, ref const it; items) {
            if (frozen[i]) {
                continue;
            }
            immutable float lo = it.minSize > 0.0f ? it.minSize : 0.0f;
            immutable float hi = it.maxSize > lo ? it.maxSize : lo;
            immutable float want = perWeight * it.weight;
            if (want < lo || want > hi) {
                sizes[i] = want < lo ? lo : hi;
                frozen[i] = true;
                remaining -= sizes[i];
                totalWeight -= it.weight;
                changed = true;
            }
        }
        if (!changed) {
            foreach (i, ref const it; items) {
                if (!frozen[i]) {
                    sizes[i] = perWeight * it.weight;
                }
            }
        }
    }
    float cursor = axis == Axis.horizontal ? inner.x : inner.y;
    foreach (i; 0 .. n) {
        if (axis == Axis.horizontal) {
            outRects[i] = RectF(cursor, inner.y, sizes[i], inner.h);
        } else {
            outRects[i] = RectF(inner.x, cursor, inner.w, sizes[i]);
        }
        cursor += sizes[i] + g;
    }
}

/**
 * Allocating convenience wrapper around layoutFlexInto.
 *
 * Params:
 *   bounds = Container rectangle.
 *   items = Item specifications.
 *   axis = Main axis.
 *   gap = Space between consecutive items.
 *   padding = Container padding.
 *
 * Returns:
 *   One rectangle per item.
 */
RectF[] layoutFlex(RectF bounds, const(FlexItem)[] items, Axis axis, float gap = 0.0f, Insets padding = Insets.init) @safe nothrow pure {
    auto rects = new RectF[items.length];
    layoutFlexInto(bounds, items, axis, gap, padding, rects);
    return rects;
}

/**
 * Node of a docking split-pane tree: either a named leaf or a split with two children separated by a splitter bar.
 * Horizontal splits place first on the left and second on the right; vertical splits place first on top.
 */
final class SplitPaneNode {
    string id;
    Axis axis = Axis.horizontal;
    float ratio = 0.5f;
    float minFirst = 0.0f;
    float minSecond = 0.0f;
    float splitterThickness = 4.0f;
    SplitPaneNode first;
    SplitPaneNode second;
    SplitPaneNode parent;
    RectF bounds;
    RectF splitterRect;

    /**
     * Creates a leaf node.
     *
     * Params:
     *   leafId = Identifier used by views to find their pane.
     */
    this(string leafId) @safe nothrow pure {
        id = leafId;
    }

    /**
     * Creates a split node.
     *
     * Params:
     *   splitAxis = Split axis.
     *   a = First (left/top) child.
     *   b = Second (right/bottom) child.
     *   initialRatio = Fraction of the available length given to the first child.
     *   minA = Minimum first-child length.
     *   minB = Minimum second-child length.
     *   thickness = Splitter bar thickness.
     */
    this(Axis splitAxis, SplitPaneNode a, SplitPaneNode b, float initialRatio = 0.5f, float minA = 0.0f,
            float minB = 0.0f, float thickness = 4.0f) @safe nothrow pure {
        assert(a !is null && b !is null, "split children must be non-null");
        axis = splitAxis;
        first = a;
        second = b;
        a.parent = this;
        b.parent = this;
        ratio = isFinite(initialRatio) ? clampf(initialRatio, 0.0f, 1.0f) : 0.5f;
        minFirst = minA > 0.0f ? minA : 0.0f;
        minSecond = minB > 0.0f ? minB : 0.0f;
        splitterThickness = thickness > 0.0f ? thickness : 0.0f;
    }

    /**
     * Builds a leaf node.
     *
     * Params:
     *   leafId = Leaf identifier.
     *
     * Returns:
     *   New leaf.
     */
    static SplitPaneNode leaf(string leafId) @safe nothrow pure {
        return new SplitPaneNode(leafId);
    }

    /**
     * Builds a split node.
     *
     * Params:
     *   splitAxis = Split axis.
     *   a = First child.
     *   b = Second child.
     *   initialRatio = First-child ratio.
     *   minA = Minimum first length.
     *   minB = Minimum second length.
     *   thickness = Splitter thickness.
     *
     * Returns:
     *   New split.
     */
    static SplitPaneNode split(Axis splitAxis, SplitPaneNode a, SplitPaneNode b, float initialRatio = 0.5f,
            float minA = 0.0f, float minB = 0.0f, float thickness = 4.0f) @safe nothrow pure {
        return new SplitPaneNode(splitAxis, a, b, initialRatio, minA, minB, thickness);
    }

    /**
     * Reports whether this node is a leaf.
     *
     * Returns:
     *   True if the node has no children.
     */
    bool isLeaf() const @safe nothrow pure @nogc {
        return first is null;
    }

    /**
     * Returns the main-axis length shared by both children (bounds length minus splitter).
     *
     * Returns:
     *   Available length (>= 0).
     */
    float availableLength() const @safe nothrow pure @nogc {
        immutable float total = axis == Axis.horizontal ? bounds.w : bounds.h;
        immutable float avail = total - splitterThickness;
        return avail > 0.0f ? avail : 0.0f;
    }

    /**
     * Clamps a requested first-child length so both minimums hold; when they cannot both hold, the available
     * length is divided in proportion to the minimums.
     *
     * Params:
     *   length = Requested first-child length.
     *
     * Returns:
     *   Effective first-child length.
     */
    float clampFirstLength(float length) const @safe nothrow pure @nogc {
        immutable float avail = availableLength();
        immutable float mins = minFirst + minSecond;
        if (mins > avail) {
            return mins > 0.0f ? avail * (minFirst / mins) : avail * 0.5f;
        }
        return clampf(isFinite(length) ? length : avail * 0.5f, minFirst, avail - minSecond);
    }

    /**
     * Returns the effective first-child length for the current ratio and bounds.
     *
     * Returns:
     *   First-child length.
     */
    float firstLength() const @safe nothrow pure @nogc {
        return clampFirstLength(availableLength() * ratio);
    }

    /**
     * Sets the ratio from a desired first-child length (clamped by minimums) and re-arranges the subtree.
     *
     * Params:
     *   length = Desired first-child length.
     */
    void setFirstLength(float length) @safe nothrow pure {
        immutable float avail = availableLength();
        immutable float clamped = clampFirstLength(length);
        ratio = avail > 0.0f ? clamped / avail : 0.5f;
        arrange(bounds);
    }

    /**
     * Assigns bounds to this node and recursively to its children and splitter.
     *
     * Params:
     *   r = Node bounds.
     */
    void arrange(RectF r) @safe nothrow pure {
        bounds = r;
        if (isLeaf()) {
            splitterRect = RectF.init;
            return;
        }
        immutable float a = firstLength();
        immutable float avail = availableLength();
        immutable float t = (axis == Axis.horizontal ? r.w : r.h) < splitterThickness
            ? (axis == Axis.horizontal ? r.w : r.h) : splitterThickness;
        if (axis == Axis.horizontal) {
            first.arrange(RectF(r.x, r.y, a, r.h));
            splitterRect = RectF(r.x + a, r.y, t, r.h);
            second.arrange(RectF(r.x + a + t, r.y, avail - a, r.h));
        } else {
            first.arrange(RectF(r.x, r.y, r.w, a));
            splitterRect = RectF(r.x, r.y + a, r.w, t);
            second.arrange(RectF(r.x, r.y + a + t, r.w, avail - a));
        }
    }

    /**
     * Finds the split node whose splitter (grown by slop on the main axis) contains p; outer splitters win.
     *
     * Params:
     *   p = Point to test.
     *   slop = Extra grab margin on each side of the splitter.
     *
     * Returns:
     *   Owning split node, or null.
     */
    SplitPaneNode splitterAt(Point2F p, float slop = 2.0f) @safe nothrow pure @nogc {
        if (isLeaf() || !bounds.contains(p)) {
            return null;
        }
        immutable RectF grab = axis == Axis.horizontal
            ? RectF(splitterRect.x - slop, splitterRect.y, splitterRect.w + 2.0f * slop, splitterRect.h)
            : RectF(splitterRect.x, splitterRect.y - slop, splitterRect.w, splitterRect.h + 2.0f * slop);
        if (grab.contains(p)) {
            return this;
        }
        if (auto hit = first.splitterAt(p, slop)) {
            return hit;
        }
        return second.splitterAt(p, slop);
    }

    /**
     * Finds the leaf whose bounds contain p (splitter bars belong to no leaf).
     *
     * Params:
     *   p = Point to test.
     *
     * Returns:
     *   Leaf node, or null.
     */
    SplitPaneNode leafAt(Point2F p) @safe nothrow pure @nogc {
        if (!bounds.contains(p)) {
            return null;
        }
        if (isLeaf()) {
            return this;
        }
        if (auto hit = first.leafAt(p)) {
            return hit;
        }
        return second.leafAt(p);
    }

    /**
     * Finds a leaf by identifier.
     *
     * Params:
     *   leafId = Identifier.
     *
     * Returns:
     *   Leaf node, or null.
     */
    SplitPaneNode findLeaf(string leafId) @safe nothrow pure @nogc {
        if (isLeaf()) {
            return id == leafId ? this : null;
        }
        if (auto hit = first.findLeaf(leafId)) {
            return hit;
        }
        return second.findLeaf(leafId);
    }

    /**
     * Appends all leaves in left-to-right / top-to-bottom order.
     *
     * Params:
     *   outLeaves = Destination array.
     */
    void collectLeaves(ref SplitPaneNode[] outLeaves) @safe nothrow pure {
        if (isLeaf()) {
            outLeaves ~= this;
            return;
        }
        first.collectLeaves(outLeaves);
        second.collectLeaves(outLeaves);
    }

    /**
     * Returns all leaves in tree order.
     *
     * Returns:
     *   Leaf list.
     */
    SplitPaneNode[] leaves() @safe nothrow pure {
        SplitPaneNode[] result;
        collectLeaves(result);
        return result;
    }

    /**
     * Appends all split (non-leaf) nodes in pre-order (outer splits first).
     *
     * Params:
     *   outSplits = Destination array.
     */
    void collectSplits(ref SplitPaneNode[] outSplits) @safe nothrow pure {
        if (isLeaf()) {
            return;
        }
        outSplits ~= this;
        first.collectSplits(outSplits);
        second.collectSplits(outSplits);
    }
}

/**
 * Owns a split-pane tree, its arranged bounds, and the active splitter drag.
 */
final class DockLayout {
    SplitPaneNode root;
    RectF bounds;
    float hitSlop = 2.0f;
    private SplitPaneNode dragging_;
    private float grabOffset_ = 0.0f;
    private bool anchorFirst_ = false;
    private float anchoredFirstLen_ = 0.0f;
    private bool anchorSecond_ = false;
    private float anchoredSecondLen_ = 0.0f;

    /**
     * Creates a layout around a tree.
     *
     * Params:
     *   tree = Root node.
     */
    this(SplitPaneNode tree) @safe nothrow pure {
        assert(tree !is null, "DockLayout requires a root node");
        root = tree;
    }

    /**
     * Arranges the whole tree.
     *
     * Params:
     *   r = Dock area.
     */
    void arrange(RectF r) @safe nothrow pure {
        bounds = r;
        root.arrange(r);
    }

    /**
     * Finds the splitter under p.
     *
     * Params:
     *   p = Point.
     *
     * Returns:
     *   Split node, or null.
     */
    SplitPaneNode splitterAt(Point2F p) @safe nothrow pure @nogc {
        return root.splitterAt(p, hitSlop);
    }

    /**
     * Finds the leaf under p.
     *
     * Params:
     *   p = Point.
     *
     * Returns:
     *   Leaf, or null.
     */
    SplitPaneNode leafAt(Point2F p) @safe nothrow pure @nogc {
        return root.leafAt(p);
    }

    /**
     * Finds a leaf by identifier.
     *
     * Params:
     *   leafId = Identifier.
     *
     * Returns:
     *   Leaf, or null.
     */
    SplitPaneNode findLeaf(string leafId) @safe nothrow pure @nogc {
        return root.findLeaf(leafId);
    }

    /**
     * Returns the arranged bounds of a leaf.
     *
     * Params:
     *   leafId = Identifier.
     *
     * Returns:
     *   Leaf bounds, or an empty rectangle if not found.
     */
    RectF leafBounds(string leafId) @safe nothrow pure @nogc {
        auto n = root.findLeaf(leafId);
        return n is null ? RectF.init : n.bounds;
    }

    /**
     * Returns all leaves in tree order.
     *
     * Returns:
     *   Leaf list.
     */
    SplitPaneNode[] leaves() @safe nothrow pure {
        return root.leaves();
    }

    /**
     * Starts a splitter drag if p is over a splitter.
     *
     * Params:
     *   p = Press position.
     *
     * Returns:
     *   True if a drag started.
     */
    bool beginDrag(Point2F p) @safe nothrow pure @nogc {
        anchorFirst_ = false;
        anchorSecond_ = false;
        dragging_ = splitterAt(p);
        if (dragging_ is null) {
            return false;
        }
        grabOffset_ = dragging_.axis == Axis.horizontal ? p.x - dragging_.splitterRect.x : p.y - dragging_.splitterRect.y;
        if (!dragging_.first.isLeaf() && dragging_.first.axis == dragging_.axis) {
            anchorFirst_ = true;
            anchoredFirstLen_ = axisLength(dragging_.first.first.bounds, dragging_.axis);
        }
        if (!dragging_.second.isLeaf() && dragging_.second.axis == dragging_.axis) {
            anchorSecond_ = true;
            anchoredSecondLen_ = axisLength(dragging_.second.second.bounds, dragging_.axis);
        }
        return true;
    }

    /**
     * Moves the dragged splitter so that it follows p, keeping the original grab offset.
     *
     * Params:
     *   p = Pointer position.
     *
     * Returns:
     *   True if a drag is active.
     */
    bool dragTo(Point2F p) @safe nothrow pure {
        if (dragging_ is null) {
            return false;
        }
        immutable float origin = dragging_.axis == Axis.horizontal ? dragging_.bounds.x : dragging_.bounds.y;
        immutable float pos = dragging_.axis == Axis.horizontal ? p.x : p.y;
        immutable float wantFirst = pos - grabOffset_ - origin;
        if (!anchorFirst_ && !anchorSecond_) {
            dragging_.setFirstLength(wantFirst);
            return true;
        }
        immutable float avail = dragging_.availableLength();
        float minFirst = dragging_.minFirst;
        if (anchorFirst_) {
            immutable float needed = anchoredFirstLen_ + dragging_.first.splitterThickness + dragging_.first.minSecond;
            if (needed > minFirst) {
                minFirst = needed;
            }
        }
        float minSecond = dragging_.minSecond;
        if (anchorSecond_) {
            immutable float needed = dragging_.second.minFirst + dragging_.second.splitterThickness + anchoredSecondLen_;
            if (needed > minSecond) {
                minSecond = needed;
            }
        }
        immutable float maxFirst = avail - minSecond;
        immutable float targetFirst = maxFirst >= minFirst
            ? clampf(wantFirst, minFirst, maxFirst)
            : dragging_.clampFirstLength(wantFirst);
        dragging_.setFirstLength(targetFirst);
        if (anchorFirst_) {
            dragging_.first.setFirstLength(anchoredFirstLen_);
        }
        if (anchorSecond_) {
            dragging_.second.setFirstLength(dragging_.second.availableLength() - anchoredSecondLen_);
        }
        return true;
    }

    /**
     * Ends the active drag.
     */
    void endDrag() @safe nothrow pure @nogc {
        dragging_ = null;
        anchorFirst_ = false;
        anchorSecond_ = false;
    }

    private static float axisLength(RectF r, Axis a) @safe nothrow pure @nogc {
        return a == Axis.horizontal ? r.w : r.h;
    }

    /**
     * Reports whether a splitter drag is active.
     *
     * Returns:
     *   True while dragging.
     */
    bool isDragging() const @safe nothrow pure @nogc {
        return dragging_ !is null;
    }

    /**
     * Returns the node being dragged.
     *
     * Returns:
     *   Split node, or null.
     */
    SplitPaneNode draggingNode() @safe nothrow pure @nogc {
        return dragging_;
    }
}
