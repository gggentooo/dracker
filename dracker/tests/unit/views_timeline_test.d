/**
 * File:         tests/unit/views_timeline_test.d
 * Module:       tests.unit.views_timeline_test
 * Phase:        Phase 8.5 — Timeline Arranger & Supertracks View Tests
 *
 * Purpose:
 *   Headless verification of TimelineView over a real StudioSession: geometry hooks round-trips at several zooms
 *   and scrolls, hit-testing of clips/edges/ruler/loop strip, clip move (time + lane), right-edge resize and
 *   Alt-clone as single undo steps, double-click add and pattern selection, delete via menu/key/action, clip and
 *   lane-header Mute/Solo/Supertrack toggles, Make Unique, Set Loop To Clip, loop-strip drag and clear, ruler seek
 *   verified against the Engine, zoom/pan clamping and zoom-around-pointer, follow playhead, animation state, and
 *   viewport culling with 300 clips.
 *
 * Real-Time & Safety Contract:
 *   UI-thread code exercised single-threaded; the Engine is advanced with processHostBuffer() on the test thread.
 *
 * Dependencies:
 *   Internal: app.{keymap,session}, gui.{renderer,widgets}, gui.views.{studio_context,timeline_view},
 *             platform.interfaces, sequencer.{note,timeline}
 *   External: std.math (abs)
 *
 * Planned API (Types, Functions & Hooks):
 *   - class FakeRasterizer : IGlyphRasterizer; class TestClock; class Rig (session + view + UiContext + helpers)
 *   - version(unittest) suites
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.views_timeline_test;

version (unittest) {
    import std.math : abs, ceil;

    import app.keymap : StudioAction;
    import app.session : StudioSession;
    import gui.renderer;
    import gui.widgets;
    import gui.views.studio_context : StudioContext;
    import gui.views.timeline_view : TimelineView;
    import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;
    import sequencer.note : NoteCell;
    import sequencer.timeline : TimelineClip;

    /**
     * Deterministic glyph rasterizer (advance 0.5 em, solid boxes).
     */
    class FakeRasterizer : IGlyphRasterizer {
        /**
         * Produces a solid glyph.
         *
         * Params:
         *   font = Font family.
         *   pixelSize = Size in pixels.
         *   cp = Code point.
         *   outGlyph = Receives the glyph.
         *
         * Returns:
         *   True.
         */
        override bool rasterize(FontId font, float pixelSize, dchar cp, out RasterizedGlyph outGlyph) {
            outGlyph.advance = pixelSize * 0.5f;
            if (cp == ' ') {
                return true;
            }
            outGlyph.width = cast(uint) ceil(pixelSize * 0.4f);
            outGlyph.height = cast(uint) ceil(pixelSize * 0.7f);
            outGlyph.bearingY = pixelSize * 0.7f;
            outGlyph.coverage = new ubyte[cast(size_t) outGlyph.width * outGlyph.height];
            outGlyph.coverage[] = 255;
            return true;
        }

        /**
         * Reports fixed line metrics.
         *
         * Params:
         *   font = Font family.
         *   pixelSize = Size in pixels.
         *   ascent = Receives 0.8 * size.
         *   lineHeight = Receives 1.25 * size.
         */
        override void lineMetrics(FontId font, float pixelSize, out float ascent, out float lineHeight) {
            ascent = pixelSize * 0.8f;
            lineHeight = pixelSize * 1.25f;
        }
    }

    /**
     * Manually advanced clock.
     */
    final class TestClock {
        double t = 0.0;

        /**
         * Returns the current time.
         *
         * Returns:
         *   Seconds.
         */
        double now() {
            return t;
        }
    }

    /**
     * Session + context + view + UiContext harness with synthetic event helpers.
     */
    final class Rig {
        StudioSession s;
        StudioContext ctx;
        TimelineView view;
        UiContext ui;
        HeadlessRenderer r;
        TestClock clock;
        float w;
        float h;

        /**
         * Builds the rig.
         *
         * Params:
         *   width = Viewport width.
         *   height = Viewport height.
         */
        this(float width = 900.0f, float height = 400.0f) {
            w = width;
            h = height;
            s = new StudioSession();
            assert(s.initialize(44_100.0f));
            ctx = new StudioContext(s);
            view = new TimelineView(ctx);
            r = new HeadlessRenderer(new GlyphCache(new FakeRasterizer()));
            clock = new TestClock();
            ui = new UiContext(view, &clock.now);
            ui.layout(RectF(0, 0, w, h), r);
        }

        /**
         * Releases the session.
         */
        void dispose() {
            s.dispose();
        }

        /**
         * Builds a pointer event.
         *
         * Params:
         *   k = Kind.
         *   x = X.
         *   y = Y.
         *   button = Button.
         *   mods = Modifiers.
         *
         * Returns:
         *   Event.
         */
        PlatformEvent ev(PlatformEventKind k, float x, float y, ubyte button = 0, uint mods = 0) {
            PlatformEvent e;
            e.kind = k;
            e.x = x;
            e.y = y;
            e.mouseButton = button;
            e.modifiers = mods;
            return e;
        }

        /**
         * Presses (one second after the previous press).
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   button = Button.
         *   mods = Modifiers.
         */
        void down(float x, float y, ubyte button = 0, uint mods = 0) {
            clock.t += 1.0;
            ui.handleEvent(ev(PlatformEventKind.mouseDown, x, y, button, mods));
        }

        /**
         * Releases.
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   button = Button.
         *   mods = Modifiers.
         */
        void up(float x, float y, ubyte button = 0, uint mods = 0) {
            ui.handleEvent(ev(PlatformEventKind.mouseUp, x, y, button, mods));
        }

        /**
         * Moves the pointer.
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   mods = Modifiers.
         */
        void move(float x, float y, uint mods = 0) {
            ui.handleEvent(ev(PlatformEventKind.mouseMove, x, y, 0, mods));
        }

        /**
         * Single click.
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   mods = Modifiers.
         */
        void click(float x, float y, uint mods = 0) {
            down(x, y, 0, mods);
            up(x, y, 0, mods);
        }

        /**
         * Double click.
         *
         * Params:
         *   x = X.
         *   y = Y.
         */
        void dblClick(float x, float y) {
            down(x, y);
            up(x, y);
            clock.t += 0.1;
            ui.handleEvent(ev(PlatformEventKind.mouseDown, x, y));
            up(x, y);
        }

        /**
         * Press, move in two steps, release.
         *
         * Params:
         *   x0 = Start x.
         *   y0 = Start y.
         *   x1 = End x.
         *   y1 = End y.
         *   mods = Modifiers.
         */
        void drag(float x0, float y0, float x1, float y1, uint mods = 0) {
            down(x0, y0, 0, mods);
            move((x0 + x1) * 0.5f, (y0 + y1) * 0.5f, mods);
            move(x1, y1, mods);
            up(x1, y1, 0, mods);
        }

        /**
         * Scrolls.
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   dx = Horizontal delta.
         *   dy = Vertical delta.
         *   mods = Modifiers.
         */
        void scroll(float x, float y, float dx, float dy, uint mods = 0) {
            PlatformEvent e = ev(PlatformEventKind.mouseScroll, x, y, 0, mods);
            e.deltaX = dx;
            e.deltaY = dy;
            ui.handleEvent(e);
        }

        /**
         * Pinch.
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   m = Magnification.
         */
        void pinch(float x, float y, float m) {
            PlatformEvent e = ev(PlatformEventKind.magnify, x, y);
            e.magnification = m;
            ui.handleEvent(e);
        }

        /**
         * Key press.
         *
         * Params:
         *   code = Key code.
         */
        void key(uint code) {
            PlatformEvent e;
            e.kind = PlatformEventKind.keyDown;
            e.keyCode = code;
            ui.handleEvent(e);
        }

        /**
         * Opens the context menu at a point and activates the item with the given label.
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   label = Item label.
         *
         * Returns:
         *   True if the item existed, was enabled and was clicked.
         */
        bool menu(float x, float y, string label) {
            down(x, y, 1);
            up(x, y, 1);
            if (ui.overlays().length == 0) {
                return false;
            }
            auto m = cast(ContextMenu) ui.overlays()[$ - 1];
            assert(m !is null);
            foreach (i, ref it; m.items) {
                if (it.label == label && it.enabled) {
                    immutable Point2F c = m.itemRect(i).center();
                    down(c.x, c.y);
                    up(c.x, c.y);
                    return true;
                }
            }
            ui.closeAllOverlays();
            return false;
        }

        /**
         * Returns the labels of the menu at a point (then closes it).
         *
         * Params:
         *   x = X.
         *   y = Y.
         *
         * Returns:
         *   Labels of enabled items.
         */
        string[] menuLabels(float x, float y) {
            down(x, y, 1);
            up(x, y, 1);
            string[] labels;
            if (ui.overlays().length > 0) {
                auto m = cast(ContextMenu) ui.overlays()[$ - 1];
                foreach (ref it; m.items) {
                    if (!it.separator) {
                        labels ~= it.label;
                    }
                }
            }
            ui.closeAllOverlays();
            return labels;
        }

        /**
         * Renders one frame at 2x.
         */
        void frame() {
            ui.renderFrame(r, 2.0f);
        }

        /**
         * Returns a copy of a clip.
         *
         * Params:
         *   clipId = Clip id.
         *   found = Receives existence.
         *
         * Returns:
         *   Clip (init if missing).
         */
        TimelineClip clip(uint clipId, out bool found) {
            foreach (ref c; s.document().clips) {
                if (c.clipId == clipId) {
                    found = true;
                    return c;
                }
            }
            return TimelineClip.init;
        }

        /**
         * Returns a copy of an existing clip.
         *
         * Params:
         *   clipId = Clip id.
         *
         * Returns:
         *   Clip.
         */
        TimelineClip clip(uint clipId) {
            bool f;
            TimelineClip c = clip(clipId, f);
            assert(f, "clip missing");
            return c;
        }

        /**
         * Reports clip existence.
         *
         * Params:
         *   clipId = Clip id.
         *
         * Returns:
         *   True if present.
         */
        bool has(uint clipId) {
            bool f;
            clip(clipId, f);
            return f;
        }

        /**
         * Renders host buffers so queued Engine commands apply, then refreshes telemetry.
         *
         * Params:
         *   blocks = 64-frame blocks.
         */
        void pump(size_t blocks = 2) {
            float[64] l = 0.0f;
            float[64] rr = 0.0f;
            const(float[])[2] ins = [null, null];
            foreach (_; 0 .. blocks) {
                float[][2] outs = [l[], rr[]];
                s.engine().processHostBuffer(outs, ins, 64);
            }
            ctx.tick();
        }

        /**
         * Returns a body grab point of a clip (left part, vertical centre).
         *
         * Params:
         *   clipId = Clip id.
         *
         * Returns:
         *   Point.
         */
        Point2F bodyOf(uint clipId) {
            immutable RectF cr = view.clipRect(clipId);
            return Point2F(cr.x + 10.0f, cr.y + cr.h * 0.5f);
        }
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        foreach (i; 0 .. 20) {
            assert(g.s.doAddClip(1, 128, 16, cast(uint) i) != 0);
        }
        immutable float[5] zooms = [0.25f, 1.5f, 6.0f, 17.5f, 48.0f];
        immutable double[3] scrolls = [0.0, 13.25, 100.0];
        immutable float[3] lanesScroll = [0.0f, 37.0f, 200.0f];
        foreach (z; zooms) {
            foreach (sl; scrolls) {
                foreach (ly; lanesScroll) {
                    v.setViewport(sl, z, ly);
                    assert(v.pointsPerLine() == z);
                    immutable double expectScroll = sl < v.maxScrollLine() ? sl : v.maxScrollLine();
                    assert(abs(v.scrollLine() - expectScroll) < 1e-9);
                    assert(v.laneScroll() == ly);
                    immutable long first = cast(long) v.scrollLine();
                    foreach (long line; first .. first + 40) {
                        immutable float x = v.lineToX(line);
                        assert(v.xToLine(x) == line);
                        assert(v.xToLine(x + z * 0.5f) == line);
                        assert(abs(v.lineToX(line + 1) - x - z) < 1e-3f);
                    }
                    foreach (fx; [130.0f, 333.3f, 512.0f, 899.0f]) {
                        immutable long l = v.xToLine(fx);
                        assert(v.lineToX(l) <= fx + 1e-3f && fx < v.lineToX(l + 1) + 1e-3f);
                    }
                    foreach (uint lane; 0 .. 20) {
                        immutable float y = v.laneToY(lane);
                        assert(v.yToLane(y + 1.0f) == lane);
                        assert(v.yToLane(y + TimelineView.laneHeight - 1.0f) == lane);
                    }
                    immutable RectF cr = v.clipRect(1);
                    assert(abs(cr.x - v.lineToX(0)) < 1e-3f && abs(cr.w - 64.0f * z) < 1e-2f);
                    assert(abs(cr.y - (v.laneToY(0) + 2.0f)) < 1e-3f && cr.h == TimelineView.laneHeight - 4.0f);
                }
            }
        }
        assert(v.clipRect(9999).isEmpty());
        assert(v.laneCount() == 20);
        assert(v.rulerRect() == RectF(TimelineView.headerWidth, 0, 900 - TimelineView.headerWidth,
            TimelineView.rulerHeight));
        assert(v.loopStripRect().y == TimelineView.rulerHeight);
        assert(v.contentRect().y == TimelineView.rulerHeight + TimelineView.loopHeight);
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable RectF rr = v.rulerRect();
        immutable RectF lr = v.loopStripRect();
        assert(g.ui.hitTest(rr.center()).id == "timeline.ruler");
        assert(g.ui.hitTest(lr.center()).id == "timeline.loop");
        assert(g.ui.hitTest(v.contentRect().center()) is v);
        immutable RectF cr = v.clipRect(1);
        bool edge;
        assert(v.hitClip(Point2F(cr.x + 20.0f, cr.y + 10.0f), edge) == 1 && !edge);
        assert(v.hitClip(Point2F(cr.right() - 2.0f, cr.y + 10.0f), edge) == 1 && edge);
        assert(v.hitClip(Point2F(cr.right() + 2.0f, cr.y + 10.0f), edge) == 0);
        assert(v.hitClip(Point2F(cr.x + 20.0f, cr.bottom() + 3.0f), edge) == 0);
        assert(v.hitClip(Point2F(cr.x + 20.0f, rr.center().y), edge) == 0);
        immutable uint second = g.s.doAddClip(1, 16, 32, 0);
        g.click(v.lineToX(20), cr.y + 10.0f);
        assert(v.selectedClip() == second);
        assert(v.hitClip(Point2F(v.lineToX(20), cr.y + 10.0f), edge) == second);
        g.click(v.lineToX(4), cr.y + 10.0f);
        assert(v.selectedClip() == 1);
        assert(v.hitClip(Point2F(v.lineToX(20), cr.y + 10.0f), edge) == 1);
        g.click(v.lineToX(100), cr.y + 10.0f);
        assert(v.selectedClip() == 0);
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable size_t u0 = g.s.history().undoCount();
        immutable Point2F p = g.bodyOf(1);
        g.down(p.x, p.y, 0, KeyModifiers.shift);
        g.move(p.x + 30.0f, p.y + 22.0f, KeyModifiers.shift);
        g.move(p.x + 60.0f, p.y + TimelineView.laneHeight, KeyModifiers.shift);
        assert(v.isAnimating());
        g.frame();
        assert(g.clip(1).startLine == 0 && g.clip(1).laneY == 0);
        g.up(p.x + 60.0f, p.y + TimelineView.laneHeight, 0, KeyModifiers.shift);
        assert(!v.isAnimating());
        assert(g.clip(1).startLine == 10 && g.clip(1).laneY == 1 && g.clip(1).lengthLines == 64);
        assert(g.s.history().undoCount() == u0 + 1);
        assert(g.s.undo());
        assert(g.clip(1).startLine == 0 && g.clip(1).laneY == 0);
        assert(g.s.redo());
        assert(g.clip(1).startLine == 10 && g.clip(1).laneY == 1);

        immutable Point2F q = g.bodyOf(1);
        g.drag(q.x, q.y, q.x + 50.0f, q.y);
        assert(g.clip(1).startLine == 20 && g.clip(1).laneY == 1);
        immutable Point2F q2 = g.bodyOf(1);
        g.drag(q2.x, q2.y, q2.x - 500.0f, q2.y - 3.0f * TimelineView.laneHeight);
        assert(g.clip(1).startLine == 0 && g.clip(1).laneY == 0);
        immutable size_t u1 = g.s.history().undoCount();
        immutable Point2F q3 = g.bodyOf(1);
        g.drag(q3.x, q3.y, q3.x + 2.0f, q3.y);
        assert(g.s.history().undoCount() == u1);
        g.drag(q3.x, q3.y, q3.x + 6.0f, q3.y);
        assert(g.clip(1).startLine == 0);
        assert(g.s.history().undoCount() == u1);
        g.down(q3.x, q3.y);
        g.move(q3.x + 120.0f, q3.y);
        g.key(KeyCode.escape);
        g.up(q3.x + 120.0f, q3.y);
        assert(g.clip(1).startLine == 0 && g.s.history().undoCount() == u1);
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable size_t u0 = g.s.history().undoCount();
        immutable RectF cr = v.clipRect(1);
        immutable float ex = cr.right() - 2.0f;
        immutable float ey = cr.y + 10.0f;
        g.drag(ex, ey, ex + 36.0f, ey + 30.0f, KeyModifiers.shift);
        assert(g.clip(1).lengthLines == 70 && g.clip(1).startLine == 0 && g.clip(1).laneY == 0);
        assert(g.s.history().undoCount() == u0 + 1);
        immutable float ex2 = v.clipRect(1).right() - 2.0f;
        g.drag(ex2, ey, ex2 - 2000.0f, ey);
        assert(g.clip(1).lengthLines == 1);
        immutable float ex3 = v.clipRect(1).right() - 0.5f;
        g.drag(ex3, ey, ex3 + 6.0f * 13.0f, ey);
        assert(g.clip(1).lengthLines == 16);
        assert(g.s.history().undoCount() == u0 + 3);
        assert(g.s.undo() && g.s.undo() && g.s.undo());
        assert(g.clip(1).lengthLines == 64);
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable size_t u0 = g.s.history().undoCount();
        immutable size_t n0 = g.s.document().clips.length;
        immutable Point2F p = g.bodyOf(1);
        g.down(p.x, p.y, 0, KeyModifiers.alt);
        g.move(p.x + 200.0f, p.y + TimelineView.laneHeight, KeyModifiers.alt);
        g.frame();
        assert(g.s.document().clips.length == n0);
        g.move(p.x + 64.0f * 6.0f, p.y + TimelineView.laneHeight, KeyModifiers.alt);
        g.up(p.x + 64.0f * 6.0f, p.y + TimelineView.laneHeight, 0, KeyModifiers.alt);
        assert(g.s.document().clips.length == n0 + 1);
        immutable uint cid = v.selectedClip();
        assert(cid != 0 && cid != 1);
        immutable TimelineClip c = g.clip(cid);
        assert(c.cloneSourceId == 1 && c.patternId == 1 && c.startLine == 64 && c.laneY == 1 && c.lengthLines == 64);
        assert(g.clip(1).startLine == 0 && g.clip(1).laneY == 0);
        assert(g.s.history().undoCount() == u0 + 1);
        g.frame();
        assert(g.s.undo());
        assert(!g.has(cid) && v.selectedClip() == 0);
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable float y1 = v.laneToY(1) + 20.0f;
        g.dblClick(v.lineToX(102) + 1.0f, y1);
        immutable uint a = v.selectedClip();
        assert(a != 0);
        TimelineClip c = g.clip(a);
        assert(c.patternId == 1 && c.startLine == 100 && c.laneY == 1 && c.lengthLines == 64 && c.cloneSourceId == 0);
        immutable uint p2 = g.s.doAddPattern(4, 32, "Bass");
        assert(p2 != 0);
        g.ctx.selectPattern(p2);
        g.dblClick(v.lineToX(120) + 1.0f, v.laneToY(2) + 20.0f);
        immutable uint b = v.selectedClip();
        c = g.clip(b);
        assert(c.patternId == p2 && c.startLine == 120 && c.laneY == 2 && c.lengthLines == 32);
        assert(v.laneCount() == 3);

        g.ctx.selectPattern(1);
        g.dblClick(g.bodyOf(b).x, g.bodyOf(b).y);
        assert(g.ctx.currentPattern() == p2);
        assert(v.selectedClip() == b);
        assert(g.clip(b).startLine == 120);
        g.dblClick(g.bodyOf(1).x, g.bodyOf(1).y);
        assert(g.ctx.currentPattern() == 1);

        string[] labels = g.menuLabels(v.lineToX(70), v.laneToY(0) + 20.0f);
        assert(labels == ["Add Clip: Pattern 01", "Add Clip: Bass"]);
        assert(g.menu(v.lineToX(110), v.laneToY(3) + 20.0f, "Add Clip: Bass"));
        c = g.clip(v.selectedClip());
        assert(c.patternId == p2 && c.startLine == 108 && c.laneY == 3 && c.lengthLines == 32);
        assert(g.menuLabels(v.rulerRect().center().x, v.rulerRect().center().y).length == 0);
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable uint b = g.s.doAddClip(1, 128, 16, 0);
        g.click(g.bodyOf(1).x, g.bodyOf(1).y);
        assert(g.ui.focused() is v);
        assert(v.selectedClip() == 1);
        g.key(KeyCode.deleteBackward);
        assert(!g.has(1) && v.selectedClip() == 0);
        g.key(KeyCode.forwardDelete);
        assert(g.has(b));
        assert(g.s.undo() && g.has(1));
        assert(g.menu(g.bodyOf(b).x, g.bodyOf(b).y, "Delete"));
        assert(!g.has(b) && g.has(1));
        assert(g.s.undo() && g.has(b));
        v.selectClip(b);
        assert(v.handleStudioAction(StudioAction.deleteBlock));
        assert(!g.has(b));
        assert(!v.handleStudioAction(StudioAction.deleteCell));
        assert(!v.handleStudioAction(StudioAction.transposeSemitoneUp));
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable Point2F p = g.bodyOf(1);
        immutable size_t u0 = g.s.history().undoCount();
        assert(g.menuLabels(p.x, p.y) == ["Mute", "Solo", "Supertrack", "Make Unique", "Set Loop To Clip", "Delete"]);
        assert(g.menu(p.x, p.y, "Mute"));
        assert(g.clip(1).mute && !g.clip(1).solo && !g.clip(1).isSupertrack);
        g.frame();
        assert(g.menuLabels(p.x, p.y)[0] == "Unmute");
        assert(g.menu(p.x, p.y, "Unmute") && !g.clip(1).mute);
        assert(g.menu(p.x, p.y, "Solo") && g.clip(1).solo);
        g.frame();
        assert(g.menu(p.x, p.y, "Unsolo") && !g.clip(1).solo);
        assert(g.menu(p.x, p.y, "Supertrack") && g.clip(1).isSupertrack);
        g.frame();
        assert(g.menu(p.x, p.y, "Clear Supertrack") && !g.clip(1).isSupertrack);
        assert(g.s.history().undoCount() == u0 + 6);
        assert(g.menu(p.x, p.y, "Set Loop To Clip"));
        assert(g.s.document().loopStartLine == 0 && g.s.document().loopEndLine == 64);
        immutable uint b = g.s.doAddClip(1, 96, 20, 0);
        assert(g.menu(g.bodyOf(b).x, g.bodyOf(b).y, "Set Loop To Clip"));
        assert(g.s.document().loopStartLine == 96 && g.s.document().loopEndLine == 116);
        assert(g.s.undo());
        assert(g.s.document().loopEndLine == 64);
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable uint a = g.s.doAddClip(1, 0, 16, 1);
        immutable uint b = g.s.doAddClip(1, 32, 16, 1);
        g.frame();
        immutable size_t u0 = g.s.history().undoCount();
        g.click(v.laneMuteRect(1).center().x, v.laneMuteRect(1).center().y);
        assert(g.clip(a).mute && g.clip(b).mute && !g.clip(1).mute);
        assert(g.s.history().undoCount() == u0 + 1);
        g.frame();
        g.click(v.laneMuteRect(1).center().x, v.laneMuteRect(1).center().y);
        assert(!g.clip(a).mute && !g.clip(b).mute);
        assert(g.s.doSetClipFlags(a, false, true, false));
        g.click(v.laneSoloRect(1).center().x, v.laneSoloRect(1).center().y);
        assert(g.clip(a).solo && g.clip(b).solo && !g.clip(1).solo);
        g.click(v.laneSoloRect(1).center().x, v.laneSoloRect(1).center().y);
        assert(!g.clip(a).solo && !g.clip(b).solo);
        g.click(v.laneSupertrackRect(1).center().x, v.laneSupertrackRect(1).center().y);
        assert(g.clip(a).isSupertrack && g.clip(b).isSupertrack && !g.clip(1).isSupertrack);
        g.frame();
        immutable size_t u1 = g.s.history().undoCount();
        assert(g.s.undo());
        assert(!g.clip(a).isSupertrack && !g.clip(b).isSupertrack);
        assert(g.s.history().undoCount() == u1 - 1);
        g.click(v.laneMuteRect(2).center().x, v.laneMuteRect(2).center().y);
        assert(g.s.history().undoCount() == u1 - 1);
        g.click(v.laneMuteRect(0).center().x, v.laneMuteRect(0).center().y);
        assert(g.clip(1).mute && !g.clip(a).mute);
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable size_t pats = g.s.document().patterns.length;
        immutable uint other = g.s.doAddClip(1, 64, 64, 0);
        assert(g.s.doSetClipFlags(1, true, false, true));
        immutable size_t u0 = g.s.history().undoCount();
        assert(g.menu(g.bodyOf(1).x, g.bodyOf(1).y, "Make Unique"));
        immutable uint nid = v.selectedClip();
        assert(nid != 0 && nid != 1 && !g.has(1));
        immutable TimelineClip c = g.clip(nid);
        assert(g.s.document().patterns.length == pats + 1);
        assert(c.patternId != 1 && c.startLine == 0 && c.lengthLines == 64 && c.laneY == 0);
        assert(c.mute && c.isSupertrack);
        assert(g.ctx.currentPattern() == c.patternId);
        assert(g.clip(other).patternId == 1);
        assert(g.s.history().undoCount() == u0 + 1);
        assert(g.s.undo());
        assert(g.has(1) && !g.has(nid) && g.s.document().patterns.length == pats);
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable RectF lr = v.loopStripRect();
        immutable float y = lr.center().y;
        immutable size_t u0 = g.s.history().undoCount();
        g.down(v.lineToX(9) + 1.0f, y);
        g.move(v.lineToX(14), y);
        g.move(v.lineToX(21) + 1.0f, y);
        assert(v.isAnimating());
        g.frame();
        assert(g.s.document().loopEndLine == 0);
        g.up(v.lineToX(21) + 1.0f, y);
        assert(g.s.document().loopStartLine == 8 && g.s.document().loopEndLine == 24);
        assert(g.s.history().undoCount() == u0 + 1);
        g.drag(v.lineToX(12) + 1.0f, y, v.lineToX(9) + 1.0f, y, KeyModifiers.shift);
        assert(g.s.document().loopStartLine == 9 && g.s.document().loopEndLine == 13);
        g.click(v.lineToX(40), y);
        assert(g.s.document().loopStartLine == 9 && g.s.document().loopEndLine == 13);
        g.frame();
        g.dblClick(v.lineToX(40), y);
        assert(g.s.document().loopStartLine == 0 && g.s.document().loopEndLine == 0);
        immutable size_t u1 = g.s.history().undoCount();
        assert(u1 == u0 + 3);
        g.dblClick(v.lineToX(40), y);
        assert(g.s.history().undoCount() == u1);
        assert(g.s.undo());
        assert(g.s.document().loopStartLine == 9 && g.s.document().loopEndLine == 13);
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable float y = v.rulerRect().center().y;
        immutable size_t u0 = g.s.history().undoCount();
        g.click(v.lineToX(32) + 1.0f, y);
        g.pump();
        assert(g.ctx.telemetry.engine.currentLine == 32);
        g.down(v.lineToX(5) + 1.0f, y);
        g.move(v.lineToX(20) + 1.0f, y);
        g.move(v.lineToX(40) + 1.0f, y);
        g.up(v.lineToX(40) + 1.0f, y);
        g.pump();
        assert(g.ctx.telemetry.engine.currentLine == 40);
        g.click(v.rulerRect().x + 1.0f, y);
        g.pump();
        assert(g.ctx.telemetry.engine.currentLine == 0);
        assert(g.s.history().undoCount() == u0);
        g.frame();
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        v.setViewport(0, 1000.0f, 0);
        assert(v.pointsPerLine() == TimelineView.maxPointsPerLine);
        v.setViewport(0, 0.0001f, 0);
        assert(v.pointsPerLine() == TimelineView.minPointsPerLine);
        v.setViewport(0, 6.0f, 0);
        immutable RectF cr = v.contentRect();
        g.scroll(cr.center().x, cr.center().y, 600.0f, 0.0f);
        assert(v.scrollLine() == 0.0);
        g.scroll(cr.center().x, cr.center().y, -60.0f, 0.0f);
        assert(abs(v.scrollLine() - 10.0) < 1e-6);
        g.scroll(cr.center().x, cr.center().y, -1.0e7f, 0.0f);
        assert(v.scrollLine() == v.maxScrollLine() && v.scrollLine() > 0.0);
        g.scroll(cr.center().x, cr.center().y, 0.0f, -30.0f, KeyModifiers.shift);
        assert(v.scrollLine() == v.maxScrollLine());
        g.scroll(cr.center().x, cr.center().y, 0.0f, 30.0f, KeyModifiers.shift);
        assert(abs(v.scrollLine() - (v.maxScrollLine() - 5.0)) < 1e-6);
        v.setViewport(40.0, 6.0f, 0);
        immutable float px = cr.x + 250.0f;
        immutable double before = v.scrollLine() + (px - cr.x) / v.pointsPerLine();
        g.scroll(px, cr.center().y, 0.0f, 20.0f, KeyModifiers.command);
        assert(v.pointsPerLine() > 6.0f);
        immutable double after = v.scrollLine() + (px - cr.x) / v.pointsPerLine();
        assert(abs(after - before) < 1e-3);
        g.pinch(px, cr.center().y, -0.5f);
        assert(v.pointsPerLine() < 6.0f);
        assert(abs(v.scrollLine() + (px - cr.x) / v.pointsPerLine() - before) < 1e-3);
        foreach (_; 0 .. 50) {
            g.pinch(px, cr.center().y, 1.0f);
        }
        assert(v.pointsPerLine() == TimelineView.maxPointsPerLine);
        foreach (_; 0 .. 50) {
            g.scroll(px, cr.center().y, 0.0f, -200.0f, KeyModifiers.command);
        }
        assert(v.pointsPerLine() == TimelineView.minPointsPerLine);
        assert(v.scrollLine() >= 0.0);
        assert(v.handleStudioAction(StudioAction.zoomReset));
        assert(abs(v.pointsPerLine() - 6.0f) < 1e-4f);
        assert(v.handleStudioAction(StudioAction.zoomIn));
        assert(abs(v.pointsPerLine() - 7.5f) < 1e-4f);
        assert(v.handleStudioAction(StudioAction.zoomOut));
        assert(abs(v.pointsPerLine() - 6.0f) < 1e-4f);

        g.scroll(cr.center().x, cr.center().y, 0.0f, -100.0f);
        assert(v.laneScroll() == 0.0f);
        foreach (i; 0 .. 30) {
            assert(g.s.doAddClip(1, 0, 16, cast(uint) i) != 0);
        }
        g.frame();
        g.scroll(cr.center().x, cr.center().y, 0.0f, -100.0f);
        assert(v.laneScroll() == 100.0f);
        assert(v.yToLane(cr.y + 1.0f) == 2);
        g.scroll(cr.center().x, cr.center().y, 0.0f, -1.0e6f);
        immutable float maxY = 31.0f * TimelineView.laneHeight - cr.h;
        assert(abs(v.laneScroll() - maxY) < 1e-3f);
        g.scroll(cr.center().x, cr.center().y, 0.0f, 1.0e6f);
        assert(v.laneScroll() == 0.0f);
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        immutable RectF cr = v.contentRect();
        assert(!v.isAnimating());
        g.ctx.followPlayhead = true;
        g.ctx.telemetry.engine.playing = true;
        g.ctx.telemetry.engine.currentLine = 3000;
        assert(v.isAnimating());
        g.frame();
        immutable float x = v.lineToX(3000);
        assert(x >= cr.x && x < cr.right());
        immutable double s0 = v.scrollLine();
        g.ctx.telemetry.engine.currentLine = 3010;
        g.frame();
        assert(v.scrollLine() == s0);
        g.ctx.followPlayhead = false;
        g.ctx.telemetry.engine.currentLine = 6000;
        g.frame();
        assert(v.scrollLine() == s0);
        assert(v.handleStudioAction(StudioAction.toggleFollow));
        assert(g.ctx.followPlayhead);
        g.frame();
        immutable float x2 = v.lineToX(6000);
        assert(x2 >= cr.x && x2 < cr.right());
        g.ctx.telemetry.engine.playing = false;
        assert(!v.isAnimating());
        g.ctx.telemetry.engine.currentLine = 0;
        g.ctx.tick();

        assert(g.s.seekLine(0));
        assert(g.s.play());
        g.pump(400);
        assert(g.ctx.telemetry.engine.playing && g.ctx.telemetry.engine.currentLine > 0);
        assert(v.isAnimating());
        assert(g.s.stop());
        g.pump();
        assert(!v.isAnimating());
    }

    unittest {
        auto g = new Rig();
        scope (exit) g.dispose();
        TimelineView v = g.view;
        foreach (i; 0 .. 299) {
            assert(g.s.doAddClip(1, 64 + cast(long) i * 64, 64, cast(uint)(i % 8)) != 0);
        }
        assert(g.s.document().clips.length == 300);
        g.frame();
        size_t expect = 0;
        immutable RectF cr = v.contentRect();
        foreach (ref c; g.s.document().clips) {
            if (!v.clipRect(c.clipId).intersect(cr).isEmpty()) {
                expect++;
            }
        }
        assert(v.lastDrawnClipCount() == expect);
        assert(expect > 0 && expect < 20);
        const(DrawList)* dl = g.r.lastDrawList();
        immutable size_t emptyInstances = dl.instances.length;
        assert(emptyInstances > 0 && emptyInstances < 3000);
        foreach (ref cmd; dl.commands) {
            assert(cmd.scissor.x + cmd.scissor.w <= cast(uint)(g.w * 2.0f));
            assert(cmd.scissor.y + cmd.scissor.h <= cast(uint)(g.h * 2.0f));
        }
        v.setViewport(5000.0, 6.0f, 0.0f);
        g.frame();
        expect = 0;
        foreach (ref c; g.s.document().clips) {
            if (!v.clipRect(c.clipId).intersect(cr).isEmpty()) {
                expect++;
            }
        }
        assert(v.lastDrawnClipCount() == expect && expect > 0 && expect < 20);
        v.setViewport(0.0, 0.25f, 0.0f);
        g.frame();
        assert(v.lastDrawnClipCount() < 300);
        assert(g.r.lastDrawList().instances.length < 6000);

        v.setViewport(0.0, 6.0f, 0.0f);
        g.frame();
        immutable size_t before = g.r.lastDrawList().instances.length;
        foreach (uint ln; 0 .. 16) {
            assert(g.s.doPatchCell(1, ln % 4, ln * 4, NoteCell(60, 100)));
        }
        g.frame();
        immutable size_t withNotes = g.r.lastDrawList().instances.length;
        assert(withNotes > before);
        g.frame();
        assert(g.r.lastDrawList().instances.length == withNotes);
        assert(g.s.doSetClipFlags(1, true, false, false));
        assert(g.s.doSetClipFlags(2, false, true, false));
        assert(g.s.doSetClipFlags(3, false, false, true));
        immutable uint cl = g.s.doCloneClip(1, 0, 9);
        assert(cl != 0);
        v.selectClip(cl);
        g.frame();
        assert(v.selectedClip() == cl);
        assert(g.r.lastDrawList().instances.length > 0);
    }

    unittest {
        auto g = new Rig();
        auto v = g.view;
        void type(dstring t) {
            foreach (c; t) {
                PlatformEvent e;
                e.kind = PlatformEventKind.textInput;
                e.utf32Char = c;
                g.ui.handleEvent(e);
            }
        }
        void key(uint code) {
            PlatformEvent e;
            e.kind = PlatformEventKind.keyDown;
            e.keyCode = code;
            g.ui.handleEvent(e);
        }
        immutable uint p2 = g.s.doAddPattern(4, 16, "Drums");
        g.ctx.selectPattern(p2);
        g.frame();
        immutable uint clipId = g.s.document().clips[0].clipId;
        immutable uint p1 = g.s.document().clips[0].patternId;
        immutable RectF cr = v.clipRect(clipId);
        immutable RectF nr = v.clipNameRect(clipId);
        assert(!nr.isEmpty() && nr.x >= cr.x && nr.right() <= cr.right() && nr.y >= cr.y && nr.bottom() <= cr.bottom());
        assert(v.clipNameRect(9999).isEmpty());

        g.dblClick(nr.center().x, nr.center().y);
        assert(g.ui.overlays().length == 1 && g.ctx.currentPattern() == p2);
        auto f = cast(TextField) g.ui.overlays()[0];
        assert(f !is null && f.text() == g.s.document().patterns[0].name);
        type("Drums"d);
        key(KeyCode.returnKey);
        assert(g.ui.overlays().length == 0 && g.s.document().patterns[0].name == "Drums1");
        assert(g.ctx.status == "Renamed pattern to Drums1" && g.ctx.currentPattern() == p2);

        g.dblClick(cr.right() - 12.0f, cr.bottom() - 4.0f);
        assert(g.ui.overlays().length == 0 && g.ctx.currentPattern() == p1);

        assert(v.beginRenameClipPattern(9999) is null);
        auto f2 = v.beginRenameClipPattern(clipId);
        assert(f2 !is null && f2.text() == "Drums1");
        key(KeyCode.escape);
        assert(g.s.document().patterns[0].name == "Drums1");
    }
}
