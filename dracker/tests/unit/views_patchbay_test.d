/**
 * File:         tests/unit/views_patchbay_test.d
 * Module:       tests.unit.views_patchbay_test
 * Phase:        Phase 8.2 — Modular Patchbay Editor Tests
 *
 * Purpose:
 *   Headless verification of PatchbayView against a real StudioSession: hit-testing of nodes, ports, badges and
 *   wires at several zoom/pan settings, click selection, drag-move as a single undo step, port-to-port wiring
 *   (incompatible kinds, self-loops and compiler-rejected cycles refused), wire and module deletion with output
 *   protection, the add-module menus for every category, node menu duplicate, mute/solo/bypass badges, zoom/pan
 *   clamping and zoom-around-pointer invariance, fit-all, telemetry-driven pulse animation, mini-scope tap
 *   requests and drawing, StudioCommandSink actions, and clipped drawing.
 *
 * Real-Time & Safety Contract:
 *   UI-thread code driven single-threaded through UiContext + HeadlessRenderer with a fake glyph rasterizer and
 *   an injected clock (no double-click unless requested).
 *
 * Dependencies:
 *   Internal: app.{keymap,session}, graph.{module_api,registry}, gui.{renderer,theme,widgets},
 *     gui.views.{patchbay_view,studio_context}, platform.interfaces, sequencer.engine
 *   External: std.math (abs, ceil, sin, PI)
 *
 * Planned API (Types, Functions & Hooks):
 *   - class PatchRasterizer : IGlyphRasterizer; class HostWidget : Widget; class Fixture (event helpers)
 *   - version(unittest) suites
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.views_patchbay_test;

version (unittest) {
    import std.algorithm : canFind;
    import std.math : abs, ceil, sin, PI;

    import app.keymap : StudioAction, StudioCommandSink;
    import app.session : StudioSession;
    import graph.module_api : ModuleCategory;
    import graph.registry : ModuleRegistry;
    import gui.renderer;
    import gui.theme : StudioTheme;
    import gui.views.patchbay_view;
    import gui.views.studio_context : StudioContext;
    import gui.widgets : ContextMenu, KeyCode, UiContext, Widget;
    import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;
    import sequencer.engine : ScopeBlock;

    /**
     * Deterministic glyph rasterizer: advance = 0.5 em, solid boxes.
     */
    class PatchRasterizer : IGlyphRasterizer {
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
         *   Always true.
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
         *   ascent = Receives 0.8 em.
         *   lineHeight = Receives 1.25 em.
         */
        override void lineMetrics(FontId font, float pixelSize, out float ascent, out float lineHeight) {
            ascent = pixelSize * 0.8f;
            lineHeight = pixelSize * 1.25f;
        }
    }

    /**
     * Root widget placing its single child into an inset rectangle so clipping can be verified.
     */
    class HostWidget : Widget {
        RectF childRect;

        override void layoutChildren() {
            foreach (c; children()) {
                c.arrange(childRect);
            }
        }
    }

    /**
     * Session + context + patchbay + UiContext harness.
     */
    final class Fixture {
        StudioSession s;
        StudioContext ctx;
        PatchbayView view;
        HostWidget host;
        UiContext ui;
        HeadlessRenderer r;
        RectF vp = RectF(0, 0, 1300, 800);
        double t = 0.0;
        uint gen;
        uint amp;
        uint amp2;

        /**
         * Builds a project: generator, two amplifiers and the output laid out in a row.
         */
        this() {
            s = new StudioSession();
            assert(s.initialize(44_100.0f));
            gen = s.doAddModule("synth.analog_gen", "Gen", 100.0f, 100.0f);
            amp = s.doAddModule("fx.amplifier", "Amp", 350.0f, 100.0f);
            amp2 = s.doAddModule("fx.amplifier", "Amp2", 350.0f, 260.0f);
            assert(gen != 0 && amp != 0 && amp2 != 0);
            assert(s.doMoveModulePosition(1, 600.0f, 100.0f));
            s.history().clear();
            ctx = new StudioContext(s);
            view = new PatchbayView(ctx);
            host = new HostWidget();
            host.childRect = RectF(50, 40, 1200, 700);
            host.add(view);
            r = new HeadlessRenderer(new GlyphCache(new PatchRasterizer()));
            ui = new UiContext(host, &now);
            ui.layout(vp, r);
            view.setView(1.0f, Point2F(40.0f, 40.0f));
        }

        /**
         * Returns the injected clock.
         *
         * Returns:
         *   Seconds.
         */
        double now() {
            return t;
        }

        /**
         * Releases the session.
         */
        void dispose() {
            s.dispose();
        }

        /**
         * Ticks the context and draws one frame at 2x.
         *
         * Returns:
         *   Recorded draw list.
         */
        const(DrawList)* frame() {
            ctx.tick();
            return drawOnly();
        }

        /**
         * Draws one frame at 2x without ticking (keeps injected telemetry).
         *
         * Returns:
         *   Recorded draw list.
         */
        const(DrawList)* drawOnly() {
            r.beginFrame(vp.w, vp.h, 2.0f);
            ui.draw(r);
            r.endFrame();
            return r.lastDrawList();
        }

        /**
         * Sends a mouse event.
         *
         * Params:
         *   kind = Event kind.
         *   p = Position.
         *   button = Button.
         *   mods = Modifiers.
         */
        void mouse(PlatformEventKind kind, Point2F p, ubyte button = 0, uint mods = 0) {
            PlatformEvent ev;
            ev.kind = kind;
            ev.x = p.x;
            ev.y = p.y;
            ev.mouseButton = button;
            ev.modifiers = mods;
            ui.handleEvent(ev);
        }

        /**
         * Clicks a point one second after the previous press.
         *
         * Params:
         *   p = Position.
         *   button = Button.
         */
        void click(Point2F p, ubyte button = 0) {
            t += 1.0;
            mouse(PlatformEventKind.mouseDown, p, button);
            mouse(PlatformEventKind.mouseUp, p, button);
        }

        /**
         * Double-clicks a point.
         *
         * Params:
         *   p = Position.
         */
        void doubleClick(Point2F p) {
            click(p);
            t += 0.1;
            mouse(PlatformEventKind.mouseDown, p);
            mouse(PlatformEventKind.mouseUp, p);
        }

        /**
         * Drags with the left button through intermediate steps.
         *
         * Params:
         *   a = Start.
         *   b = End.
         *   steps = Intermediate moves.
         */
        void drag(Point2F a, Point2F b, int steps = 6) {
            t += 1.0;
            mouse(PlatformEventKind.mouseDown, a);
            foreach (i; 1 .. steps + 1) {
                immutable float f = cast(float) i / steps;
                mouse(PlatformEventKind.mouseMove, Point2F(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f));
            }
            mouse(PlatformEventKind.mouseUp, b);
        }

        /**
         * Sends a key press and release.
         *
         * Params:
         *   code = Virtual key code.
         */
        void key(uint code) {
            PlatformEvent ev;
            ev.kind = PlatformEventKind.keyDown;
            ev.keyCode = code;
            ui.handleEvent(ev);
            ev.kind = PlatformEventKind.keyUp;
            ui.handleEvent(ev);
        }

        /**
         * Sends a scroll event.
         *
         * Params:
         *   p = Pointer.
         *   dx = Horizontal delta.
         *   dy = Vertical delta.
         *   mods = Modifiers.
         */
        void scroll(Point2F p, float dx, float dy, uint mods = 0) {
            PlatformEvent ev;
            ev.kind = PlatformEventKind.mouseScroll;
            ev.x = p.x;
            ev.y = p.y;
            ev.deltaX = dx;
            ev.deltaY = dy;
            ev.modifiers = mods;
            ui.handleEvent(ev);
        }

        /**
         * Sends a pinch event.
         *
         * Params:
         *   p = Pointer.
         *   m = Magnification delta.
         */
        void magnify(Point2F p, float m) {
            PlatformEvent ev;
            ev.kind = PlatformEventKind.magnify;
            ev.x = p.x;
            ev.y = p.y;
            ev.magnification = m;
            ui.handleEvent(ev);
        }

        /**
         * Returns the topmost open context menu.
         *
         * Returns:
         *   Menu or null.
         */
        ContextMenu topMenu() {
            Widget[] o = ui.overlays();
            return o.length == 0 ? null : cast(ContextMenu) o[$ - 1];
        }

        /**
         * Clicks the entry with a label in the topmost menu.
         *
         * Params:
         *   label = Entry label.
         *
         * Returns:
         *   True if found and clicked.
         */
        bool clickMenu(string label) {
            ContextMenu m = topMenu();
            if (m is null) {
                return false;
            }
            foreach (i, ref it; m.items) {
                if (it.label == label) {
                    click(m.itemRect(i).center());
                    return true;
                }
            }
            return false;
        }

        /**
         * Finds a module position in the document.
         *
         * Params:
         *   id = Module id.
         *   x = Receives X.
         *   y = Receives Y.
         *
         * Returns:
         *   True if found.
         */
        bool modulePos(uint id, out float x, out float y) {
            foreach (ref m; s.document().modules) {
                if (m.id == id) {
                    x = m.posX;
                    y = m.posY;
                    return true;
                }
            }
            return false;
        }

        /**
         * Reports whether a module exists.
         *
         * Params:
         *   id = Module id.
         *
         * Returns:
         *   True if present.
         */
        bool hasModule(uint id) {
            float x, y;
            return modulePos(id, x, y);
        }

        /**
         * Reports a module flag.
         *
         * Params:
         *   id = Module id.
         *   bypass = False for muted, true for bypassed.
         *
         * Returns:
         *   Flag value.
         */
        bool flag(uint id, bool bypass) {
            foreach (ref m; s.document().modules) {
                if (m.id == id) {
                    return bypass ? m.bypassed : m.muted;
                }
            }
            assert(false, "module missing");
        }

        /**
         * Reports whether a wire exists.
         *
         * Params:
         *   a = Source module.
         *   ap = Source port.
         *   b = Destination module.
         *   bp = Destination port.
         *
         * Returns:
         *   True if present.
         */
        bool hasWire(uint a, ushort ap, uint b, ushort bp) {
            foreach (ref w; s.document().wires) {
                if (w.srcMod == a && w.srcPort == ap && w.dstMod == b && w.dstPort == bp) {
                    return true;
                }
            }
            return false;
        }
    }

    private bool near(float a, float b, float eps = 1.0e-3f) {
        return abs(a - b) <= eps;
    }

    private bool nearPt(Point2F a, Point2F b, float eps = 1.0e-3f) {
        return near(a.x, b.x, eps) && near(a.y, b.y, eps);
    }

    private bool rectInside(RectF inner, RectF outer) {
        return inner.x >= outer.x - 1.0e-3f && inner.y >= outer.y - 1.0e-3f && inner.right() <= outer.right() + 1.0e-3f
            && inner.bottom() <= outer.bottom() + 1.0e-3f;
    }

    @("patchbay: hit-testing nodes, ports, badges and wires at several zoom/pan settings")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        assert(f.s.doConnectWire(f.gen, 2, f.amp, 0));
        assert(f.s.doConnectWire(f.amp, 2, 1, 0));
        immutable float[4] zooms = [1.0f, 0.5f, 1.5f, 0.25f];
        immutable Point2F[4] pans = [Point2F(40, 40), Point2F(200, -20), Point2F(-100, 0), Point2F(300, 300)];
        foreach (i; 0 .. 4) {
            f.view.setView(zooms[i], pans[i]);
            f.frame();
            assert(near(f.view.zoom(), zooms[i]));
            immutable Point2F w = Point2F(123.0f, -45.0f);
            assert(nearPt(f.view.viewToWorld(f.view.worldToView(w)), w));
            immutable RectF nr = f.view.nodeRect(f.gen);
            assert(near(nr.w, PATCHBAY_NODE_WIDTH * zooms[i]));
            assert(nearPt(Point2F(nr.x, nr.y), f.view.worldToView(Point2F(100.0f, 100.0f))));
            auto h = f.view.hitTestAt(f.view.nodeCenter(f.gen));
            assert(h.kind == PatchbayHitKind.node && h.moduleId == f.gen);
            h = f.view.hitTestAt(f.view.nodeCenter(1));
            assert(h.kind == PatchbayHitKind.node && h.moduleId == 1);
            h = f.view.hitTestAt(f.view.portPosition(f.gen, 2));
            assert(h.kind == PatchbayHitKind.outputPort && h.moduleId == f.gen && h.portIndex == 2);
            h = f.view.hitTestAt(f.view.portPosition(f.amp, 1));
            assert(h.kind == PatchbayHitKind.inputPort && h.moduleId == f.amp && h.portIndex == 1);
            h = f.view.hitTestAt(f.view.portPosition(f.gen, 0));
            assert(h.kind == PatchbayHitKind.inputPort && h.portIndex == 0);
            foreach (b; [PatchbayBadge.mute, PatchbayBadge.solo, PatchbayBadge.bypass]) {
                h = f.view.hitTestAt(f.view.badgeCenter(f.amp, b));
                assert(h.kind == PatchbayHitKind.badge && h.moduleId == f.amp && h.badge == b);
            }
            assert(f.view.badgeCenter(1, PatchbayBadge.mute) == Point2F.init);
            h = f.view.hitTestAt(f.view.wireMidpoint(0));
            assert(h.kind == PatchbayHitKind.wire && h.wireIndex == 0);
            h = f.view.hitTestAt(f.view.wireMidpoint(1));
            assert(h.kind == PatchbayHitKind.wire && h.wireIndex == 1);
            immutable Point2F e = f.view.emptyCanvasPoint();
            assert(f.view.bounds.contains(e));
            assert(f.view.hitTestAt(e).kind == PatchbayHitKind.none);
        }
        assert(f.view.hitTestAt(Point2F(10.0f, 10.0f)).kind == PatchbayHitKind.none);
        assert(f.view.nodeRect(9999).isEmpty());
        assert(f.view.portPosition(f.gen, 77) == Point2F.init);
    }

    @("patchbay: click selects nodes and empty canvas clears selection")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        f.frame();
        f.click(f.view.nodeCenter(f.amp));
        assert(f.ctx.selectedModule() == f.amp);
        assert(f.ui.focused() is f.view);
        f.click(f.view.nodeCenter(f.gen));
        assert(f.ctx.selectedModule() == f.gen);
        f.click(f.view.emptyCanvasPoint());
        assert(f.ctx.selectedModule() == 0);
        assert(!f.view.isAnimating());
    }

    @("patchbay: dragging a node moves it in world units and records exactly one undo step")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        f.view.setView(0.5f, Point2F(60.0f, 60.0f));
        f.frame();
        immutable size_t before = f.s.history().undoCount();
        immutable Point2F a = f.view.nodeCenter(f.gen);
        f.t += 1.0;
        f.mouse(PlatformEventKind.mouseDown, a);
        assert(f.view.isDragging() && f.view.isAnimating());
        foreach (i; 1 .. 11) {
            f.mouse(PlatformEventKind.mouseMove, Point2F(a.x + 4.0f * i, a.y + 2.0f * i));
            f.drawOnly();
        }
        f.mouse(PlatformEventKind.mouseUp, Point2F(a.x + 40.0f, a.y + 20.0f));
        assert(!f.view.isDragging() && !f.view.isAnimating());
        float x, y;
        assert(f.modulePos(f.gen, x, y));
        assert(near(x, 180.0f) && near(y, 140.0f));
        assert(f.s.history().undoCount() == before + 1);
        assert(!f.s.history().inGroup());
        assert(f.s.undo());
        assert(f.modulePos(f.gen, x, y) && near(x, 100.0f) && near(y, 100.0f));
        assert(f.s.redo());
        assert(f.modulePos(f.gen, x, y) && near(x, 180.0f) && near(y, 140.0f));
        f.frame();
        immutable size_t mid = f.s.history().undoCount();
        f.click(f.view.nodeCenter(f.amp));
        assert(f.s.history().undoCount() == mid);
        f.drag(f.view.nodeCenter(f.amp), f.view.nodeCenter(f.amp) + Point2F(10.0f, 0.0f));
        assert(f.s.history().undoCount() == mid + 1);
        assert(f.modulePos(f.amp, x, y) && near(x, 370.0f));
    }

    @("patchbay: capture loss mid-drag closes the undo group")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        f.frame();
        immutable Point2F a = f.view.nodeCenter(f.gen);
        f.t += 1.0;
        f.mouse(PlatformEventKind.mouseDown, a);
        f.mouse(PlatformEventKind.mouseMove, a + Point2F(30.0f, 0.0f));
        assert(f.s.history().inGroup());
        PlatformEvent ev;
        ev.kind = PlatformEventKind.focusChanged;
        ev.focused = false;
        f.ui.handleEvent(ev);
        assert(!f.s.history().inGroup() && !f.view.isDragging());
        assert(f.s.history().undoCount() == 1);
    }

    @("patchbay: port-to-port wiring connects compatible ports and rejects incompatible kinds, self-loops and cycles")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        f.frame();
        immutable size_t idle = f.frame().instances.length;
        f.t += 1.0;
        f.mouse(PlatformEventKind.mouseDown, f.view.portPosition(f.gen, 2));
        f.mouse(PlatformEventKind.mouseMove, f.view.portPosition(f.amp, 0) + Point2F(-30.0f, 10.0f));
        assert(f.view.isDragging() && f.view.isAnimating());
        assert(f.drawOnly().instances.length > idle);
        f.mouse(PlatformEventKind.mouseMove, f.view.portPosition(f.amp, 0));
        f.mouse(PlatformEventKind.mouseUp, f.view.portPosition(f.amp, 0));
        assert(f.hasWire(f.gen, 2, f.amp, 0));
        assert(f.s.document().wires.length == 1);
        assert(f.s.undo());
        assert(f.s.document().wires.length == 0);
        assert(f.s.redo());
        f.frame();

        f.drag(f.view.portPosition(f.gen, 2), f.view.portPosition(f.amp, 1));
        assert(!f.hasWire(f.gen, 2, f.amp, 1));
        assert(f.ctx.status == "Incompatible connection");

        f.drag(f.view.portPosition(f.amp, 2), f.view.portPosition(f.amp, 0));
        assert(!f.hasWire(f.amp, 2, f.amp, 0));

        f.drag(f.view.portPosition(f.gen, 2), f.view.portPosition(f.amp, 0));
        assert(f.s.document().wires.length == 1);

        f.drag(f.view.portPosition(f.amp, 2), f.view.portPosition(f.amp2, 0));
        assert(f.hasWire(f.amp, 2, f.amp2, 0));
        f.frame();
        f.drag(f.view.portPosition(f.amp2, 2), f.view.portPosition(f.amp, 0));
        assert(!f.hasWire(f.amp2, 2, f.amp, 0));
        assert(f.ctx.status == "Connection rejected by the graph compiler");

        f.drag(f.view.portPosition(f.amp2, 2), f.view.emptyCanvasPoint());
        assert(f.s.document().wires.length == 2);
        f.drag(f.view.portPosition(f.amp2, 2), f.view.portPosition(1, 0));
        assert(f.hasWire(f.amp2, 2, 1, 0));
        assert(!f.view.isDragging());
    }

    @("patchbay: clicking a wire selects it and Delete removes it undoably")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        assert(f.s.doConnectWire(f.gen, 2, f.amp, 0));
        assert(f.s.doConnectWire(f.amp, 2, 1, 0));
        f.frame();
        f.click(f.view.wireMidpoint(1));
        assert(f.view.selectedWireIndex() == 1);
        f.frame();
        f.key(KeyCode.deleteBackward);
        assert(f.view.selectedWireIndex() == -1);
        assert(!f.hasWire(f.amp, 2, 1, 0) && f.hasWire(f.gen, 2, f.amp, 0));
        assert(f.s.undo());
        assert(f.hasWire(f.amp, 2, 1, 0));
        f.frame();
        f.click(f.view.wireMidpoint(0));
        assert(f.view.selectedWireIndex() == 0);
        f.key(KeyCode.forwardDelete);
        assert(!f.hasWire(f.gen, 2, f.amp, 0));
        f.frame();
        f.click(f.view.wireMidpoint(0), 1);
        assert(f.view.selectedWireIndex() == 0);
        assert(f.topMenu() !is null && f.topMenu().items[0].label == "Delete Wire");
        assert(f.clickMenu("Delete Wire"));
        assert(f.s.document().wires.length == 0);
    }

    @("patchbay: Delete removes the selected module with its wires but never the output module")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        assert(f.s.doConnectWire(f.gen, 2, f.amp, 0));
        assert(f.s.doConnectWire(f.amp, 2, 1, 0));
        f.frame();
        f.click(f.view.nodeCenter(f.amp));
        f.key(KeyCode.deleteBackward);
        assert(!f.hasModule(f.amp));
        assert(f.s.document().wires.length == 0);
        assert(f.ctx.selectedModule() == 0);
        assert(f.s.undo());
        assert(f.hasModule(f.amp) && f.s.document().wires.length == 2);
        f.frame();
        f.click(f.view.nodeCenter(1));
        assert(f.ctx.selectedModule() == 1);
        immutable ulong rev = f.s.documentRevision();
        f.key(KeyCode.deleteBackward);
        assert(f.hasModule(1));
        assert(f.s.documentRevision() == rev);
        assert(f.ctx.status == "The output module cannot be deleted");
        assert(!f.view.deleteModule(1));
        assert(!f.view.handleStudioAction(StudioAction.deleteBlock));
        assert(f.hasModule(1));
        f.click(f.view.nodeCenter(1), 1);
        ContextMenu m = f.topMenu();
        assert(m !is null);
        foreach (ref it; m.items) {
            if (!it.separator) {
                assert(!it.enabled);
            }
        }
        f.ui.closeAllOverlays();
        f.click(f.view.nodeCenter(f.gen), 1);
        assert(f.ctx.selectedModule() == f.gen);
        assert(f.clickMenu("Delete"));
        assert(!f.hasModule(f.gen));
    }

    @("patchbay: add-module menus create each category's first module at the clicked world point")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        f.frame();
        static immutable ModuleCategory[3] cats = [ModuleCategory.synth, ModuleCategory.effect,
            ModuleCategory.control];
        static immutable string[3] labels = ["Add Synth ▸", "Add Effect ▸", "Add Control ▸"];
        foreach (ci; 0 .. 3) {
            string firstType;
            string firstName;
            foreach (ref d; ModuleRegistry.descriptors()) {
                if (d.category == cats[ci] && !d.isOutput) {
                    firstType = d.typeId;
                    firstName = d.displayName;
                    break;
                }
            }
            assert(firstType.length > 0);
            f.frame();
            immutable Point2F p = f.view.emptyCanvasPoint();
            immutable Point2F w = f.view.viewToWorld(p);
            immutable size_t count = f.s.document().modules.length;
            f.click(p, 1);
            ContextMenu m = f.topMenu();
            assert(m !is null);
            bool hasCore = false;
            foreach (ref it; m.items) {
                hasCore = hasCore || it.label == "Add Core ▸";
            }
            assert(!hasCore);
            assert(f.clickMenu(labels[ci]));
            ContextMenu sub = f.topMenu();
            assert(sub !is null && sub !is m);
            assert(sub.items[0].label == firstName);
            size_t expected = 0;
            foreach (ref d; ModuleRegistry.descriptors()) {
                if (d.category == cats[ci] && !d.isOutput) {
                    expected++;
                }
            }
            assert(sub.items.length == expected);
            assert(f.clickMenu(firstName));
            assert(f.topMenu() is null);
            assert(f.s.document().modules.length == count + 1);
            const nm = f.s.document().modules[$ - 1];
            assert(nm.typeId == firstType);
            assert(near(nm.posX, w.x) && near(nm.posY, w.y));
            assert(f.ctx.selectedModule() == nm.id);
        }
        f.frame();
        f.click(f.view.emptyCanvasPoint(), 1);
        immutable Point2F before = f.view.pan();
        f.view.setView(2.0f, before);
        assert(f.clickMenu("Reset Zoom"));
        assert(near(f.view.zoom(), 1.0f));
    }

    @("patchbay: node menu duplicate copies type and parameters as one undo step")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        assert(f.s.doSetParam(f.amp, 0, 0.25f));
        f.s.history().breakCoalesce();
        f.frame();
        immutable size_t undo0 = f.s.history().undoCount();
        f.click(f.view.nodeCenter(f.amp), 1);
        assert(f.clickMenu("Duplicate"));
        const nm = f.s.document().modules[$ - 1];
        assert(nm.typeId == "fx.amplifier" && nm.id != f.amp);
        assert(near(nm.paramValues[0], 0.25f));
        assert(near(nm.posX, 380.0f) && near(nm.posY, 130.0f));
        assert(f.ctx.selectedModule() == nm.id);
        assert(f.s.history().undoCount() == undo0 + 1);
        immutable uint dup = nm.id;
        assert(f.s.undo());
        assert(!f.hasModule(dup));
        assert(f.view.duplicateModule(1) == 0);
    }

    @("patchbay: mute, solo and bypass badges and node menu entries toggle module flags")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        f.frame();
        f.click(f.view.badgeCenter(f.gen, PatchbayBadge.mute));
        assert(f.flag(f.gen, false));
        assert(f.ctx.selectedModule() == f.gen);
        f.frame();
        f.click(f.view.badgeCenter(f.gen, PatchbayBadge.mute));
        assert(!f.flag(f.gen, false));
        assert(f.s.undo());
        assert(f.flag(f.gen, false));
        assert(f.s.undo());
        assert(!f.flag(f.gen, false));
        f.click(f.view.badgeCenter(f.amp, PatchbayBadge.bypass));
        assert(f.flag(f.amp, true));
        f.frame();
        f.click(f.view.badgeCenter(f.gen, PatchbayBadge.solo));
        assert(f.s.isModuleSoloed(f.gen));
        f.frame();
        f.click(f.view.badgeCenter(f.gen, PatchbayBadge.solo));
        assert(!f.s.isModuleSoloed(f.gen));
        f.click(f.view.nodeCenter(f.amp), 1);
        assert(f.clickMenu("Enable"));
        assert(!f.flag(f.amp, true));
        f.frame();
        f.click(f.view.nodeCenter(f.amp), 1);
        assert(f.clickMenu("Mute"));
        assert(f.flag(f.amp, false));
        f.frame();
        f.click(f.view.nodeCenter(f.amp), 1);
        assert(f.clickMenu("Solo"));
        assert(f.s.isModuleSoloed(f.amp));
        f.frame();
        f.click(f.view.nodeCenter(f.amp), 1);
        assert(f.clickMenu("Unsolo"));
        assert(!f.s.isModuleSoloed(f.amp));
        assert(!f.view.toggleBadge(1, PatchbayBadge.mute));
        assert(!f.flag(1, false));
    }

    @("patchbay: zoom clamps to 0.25..3, zooms around the pointer and pan keeps content reachable")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        f.frame();
        immutable Point2F p = Point2F(400.0f, 300.0f);
        immutable Point2F w0 = f.view.viewToWorld(p);
        f.magnify(p, 0.5f);
        assert(near(f.view.zoom(), 1.5f));
        assert(nearPt(f.view.viewToWorld(p), w0));
        foreach (_; 0 .. 20) {
            f.magnify(p, 1.0f);
        }
        assert(near(f.view.zoom(), PATCHBAY_MAX_ZOOM));
        assert(nearPt(f.view.viewToWorld(p), w0, 1.0e-2f));
        foreach (_; 0 .. 40) {
            f.magnify(p, -0.5f);
        }
        assert(near(f.view.zoom(), PATCHBAY_MIN_ZOOM));
        f.view.setView(1.0f, Point2F(40.0f, 40.0f));
        immutable Point2F q = f.view.nodeCenter(f.amp);
        immutable Point2F wq = f.view.viewToWorld(q);
        f.scroll(q, 0.0f, 20.0f, KeyModifiers.command);
        assert(f.view.zoom() > 1.0f);
        assert(nearPt(f.view.viewToWorld(q), wq, 1.0e-2f));
        f.scroll(q, 0.0f, -40.0f, KeyModifiers.command);
        assert(f.view.zoom() < 1.0f);
        assert(nearPt(f.view.viewToWorld(q), wq, 1.0e-2f));
        f.view.setView(1.0f, Point2F(40.0f, 40.0f));
        f.scroll(Point2F(600.0f, 400.0f), 15.0f, -10.0f);
        assert(nearPt(f.view.pan(), Point2F(55.0f, 30.0f)));
        f.scroll(Point2F(600.0f, 400.0f), 1.0e5f, 1.0e5f);
        RectF nr = f.view.nodeRect(f.gen);
        assert(nr.x <= f.view.bounds.right() - PATCHBAY_PAN_MARGIN + 1.0e-2f);
        assert(nr.y <= f.view.bounds.bottom() - PATCHBAY_PAN_MARGIN + 1.0e-2f);
        f.scroll(Point2F(600.0f, 400.0f), -1.0e6f, -1.0e6f);
        immutable RectF outr = f.view.nodeRect(1);
        immutable RectF sc = f.view.scopeRect(f.amp2);
        assert(outr.right() >= f.view.bounds.x + PATCHBAY_PAN_MARGIN - 1.0e-2f);
        assert(sc.bottom() >= f.view.bounds.y + PATCHBAY_PAN_MARGIN - 1.0e-2f);
        f.view.setView(1.0f, Point2F(40.0f, 40.0f));
        immutable Point2F e = f.view.emptyCanvasPoint();
        f.drag(e, e + Point2F(25.0f, 5.0f));
        assert(nearPt(f.view.pan(), Point2F(65.0f, 45.0f)));
        f.view.setView(3.0f, Point2F(-2000.0f, -900.0f));
        f.frame();
        f.doubleClick(f.view.emptyCanvasPoint());
        ContextMenu m = f.topMenu();
        assert(m !is null, "double-click on empty canvas should open context menu");
        string[] labels;
        foreach (ref it; m.items) labels ~= it.label;
        assert(labels.canFind("Add Synth ▸"), "menu should contain 'Add Synth ▸'");
        assert(labels.canFind("Add Effect ▸"), "menu should contain 'Add Effect ▸'");
        assert(labels.canFind("Add Control ▸"), "menu should contain 'Add Control ▸'");
        assert(!labels.canFind("Add Core ▸"), "empty Core category should be omitted");
        assert(labels.canFind("Fit All"), "menu should contain 'Fit All'");
        assert(labels.canFind("Reset Zoom"), "menu should contain 'Reset Zoom'");
        f.clickMenu("Fit All");
        f.frame();
        foreach (idv; [f.gen, f.amp, f.amp2, 1u]) {
            assert(rectInside(f.view.nodeRect(idv), f.view.bounds));
        }
        assert(f.view.zoom() >= PATCHBAY_MIN_ZOOM && f.view.zoom() <= PATCHBAY_MAX_ZOOM);
    }

    @("patchbay: signal pulses animate only while a wire source reports a nonzero peak")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        assert(f.s.doConnectWire(f.gen, 2, f.amp, 0));
        f.frame();
        assert(!f.view.isAnimating());
        assert(!f.view.pulsesActive());
        immutable size_t idle = f.drawOnly().instances.length;
        f.ctx.telemetry.engine.playing = true;
        f.ctx.telemetry.engine.graph.moduleCount = 2;
        f.ctx.telemetry.engine.graph.moduleIds[0] = 1;
        f.ctx.telemetry.engine.graph.modulePeaks[0] = 0.9f;
        f.ctx.telemetry.engine.graph.moduleIds[1] = f.amp;
        f.ctx.telemetry.engine.graph.modulePeaks[1] = 0.7f;
        assert(!f.view.isAnimating());
        f.ctx.telemetry.engine.graph.moduleIds[2] = f.gen;
        f.ctx.telemetry.engine.graph.modulePeaks[2] = 0.5f;
        assert(!f.view.isAnimating());
        f.ctx.telemetry.engine.graph.moduleCount = 3;
        assert(f.view.isAnimating() && f.ui.isAnimating());
        assert(f.drawOnly().instances.length > idle);
        f.ctx.telemetry.engine.graph.modulePeaks[2] = 0.0f;
        assert(!f.view.isAnimating());
        f.ctx.telemetry.engine.graph.modulePeaks[2] = 0.5f;
        f.frame();
        assert(!f.view.isAnimating());
    }

    @("patchbay: mini-scopes request taps for recently selected modules and draw their waveforms")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        f.frame();
        assert(f.ctx.scopeTaps() == [0u, 0u, 0u, 0u]);
        f.click(f.view.nodeCenter(f.gen));
        f.frame();
        assert(f.ctx.scopeTaps() == [f.gen, 0u, 0u, 0u]);
        f.click(f.view.nodeCenter(f.amp));
        f.frame();
        assert(f.ctx.scopeTaps() == [f.amp, f.gen, 0u, 0u]);
        f.click(f.view.nodeCenter(1));
        f.frame();
        f.click(f.view.nodeCenter(f.amp2));
        f.frame();
        f.click(f.view.nodeCenter(f.gen));
        f.frame();
        assert(f.ctx.scopeTaps() == [f.gen, f.amp2, 1u, f.amp]);
        assert(f.view.scopeModules() == [f.gen, f.amp2, 1u, f.amp]);
        f.click(f.view.emptyCanvasPoint());
        f.frame();
        assert(f.ctx.scopeTaps() == [f.gen, f.amp2, 1u, f.amp]);

        immutable size_t before = f.frame().instances.length;
        foreach (b; 0 .. 4) {
            ScopeBlock blk;
            blk.sourceId = f.amp2;
            blk.frame = cast(ulong) b * 64;
            foreach (k; 0 .. 64) {
                blk.left[k] = cast(float) sin(2.0 * PI * (b * 64 + k) / 64.0);
                blk.right[k] = blk.left[k];
            }
            f.ctx.scopes.push(blk);
        }
        const dl = f.frame();
        assert(dl.instances.length >= before + 63);
        immutable RectF sr = f.view.scopeRect(f.amp2);
        size_t lines = 0;
        foreach (ref inst; dl.instances) {
            if (inst.kind == InstanceKind.line) {
                immutable float cx = (inst.rect[0] + inst.rect[2] * 0.5f) / 2.0f;
                immutable float cy = (inst.rect[1] + inst.rect[3] * 0.5f) / 2.0f;
                if (sr.inset(-4.0f).contains(Point2F(cx, cy))) {
                    lines++;
                }
            }
        }
        assert(lines >= 63);

        f.click(f.view.nodeCenter(f.amp));
        f.key(KeyCode.deleteBackward);
        f.frame();
        assert(f.ctx.scopeTaps() == [f.gen, f.amp2, 1u, 0u]);
    }

    @("patchbay: StudioCommandSink zoom actions zoom around the view centre")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        f.frame();
        StudioCommandSink sink = f.view;
        immutable Point2F c = f.view.canvasRect().center();
        immutable Point2F wc = f.view.viewToWorld(c);
        assert(sink.handleStudioAction(StudioAction.zoomIn));
        assert(near(f.view.zoom(), 1.25f));
        assert(nearPt(f.view.viewToWorld(c), wc, 1.0e-2f));
        assert(sink.handleStudioAction(StudioAction.zoomOut));
        assert(sink.handleStudioAction(StudioAction.zoomOut));
        assert(near(f.view.zoom(), 0.8f));
        assert(nearPt(f.view.viewToWorld(c), wc, 1.0e-2f));
        assert(sink.handleStudioAction(StudioAction.zoomReset));
        assert(near(f.view.zoom(), 1.0f));
        foreach (_; 0 .. 30) {
            sink.handleStudioAction(StudioAction.zoomIn);
        }
        assert(near(f.view.zoom(), PATCHBAY_MAX_ZOOM));
        foreach (_; 0 .. 30) {
            sink.handleStudioAction(StudioAction.zoomOut);
        }
        assert(near(f.view.zoom(), PATCHBAY_MIN_ZOOM));
        assert(!sink.handleStudioAction(StudioAction.playToggle));
        assert(!sink.handleStudioAction(StudioAction.deleteCell));
        assert(f.s.doConnectWire(f.gen, 2, f.amp, 0));
        assert(f.view.selectWire(0));
        assert(sink.handleStudioAction(StudioAction.deleteCell));
        assert(f.s.document().wires.length == 0);
    }

    @("patchbay: drawing produces nodes, wires and text and stays clipped to the view")
    unittest {
        auto f = new Fixture();
        scope (exit) f.dispose();
        assert(f.s.doConnectWire(f.gen, 2, f.amp, 0));
        assert(f.s.doConnectWire(f.amp, 2, 1, 0));
        foreach (i; 0 .. 3) {
            immutable float[3] zs = [1.0f, 2.5f, 0.3f];
            f.view.setView(zs[i], Point2F(-120.0f, -60.0f));
            const dl = f.frame();
            assert(dl.instances.length > 20);
            immutable RectF crPx = RectF(f.view.canvasRect().x * 2.0f, f.view.canvasRect().y * 2.0f,
                f.view.canvasRect().w * 2.0f, f.view.canvasRect().h * 2.0f);
            bool glyphs = false;
            foreach (ref inst; dl.instances) {
                if (inst.kind == InstanceKind.glyph) {
                    immutable RectF ir = RectF(inst.rect[0], inst.rect[1], inst.rect[2], inst.rect[3]);
                    if (!ir.intersect(crPx).isEmpty()) {
                        glyphs = true;
                    }
                }
            }
            assert(glyphs == (zs[i] * 13.0f >= 5.0f));
            immutable RectF vb = f.view.bounds;
            immutable RectF px = RectF(vb.x * 2.0f, vb.y * 2.0f, vb.w * 2.0f, vb.h * 2.0f);
            foreach (ref cmd; dl.commands) {
                if (cmd.instanceCount == 0) {
                    continue;
                }
                immutable RectF sc = RectF(cmd.scissor.x, cmd.scissor.y, cmd.scissor.w, cmd.scissor.h);
                assert(rectInside(sc, px.inset(-1.0f)));
            }
        }
        f.view.setView(1.0f, Point2F(5000.0f, 5000.0f));
        const far = f.frame();
        size_t shapes = 0;
        foreach (ref inst; far.instances) {
            shapes += inst.kind == InstanceKind.line ? 1 : 0;
        }
        assert(shapes == 0);
    }
}
