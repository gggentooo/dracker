/**
 * File:         tests/unit/views_param_rack_test.d
 * Module:       tests.unit.views_param_rack_test
 * Phase:        Phase 8.3 — Parameter Rack View Tests
 *
 * Purpose:
 *   Drives ParamRackView headlessly against a real StudioSession: control selection for every ParamScale, slider
 *   drags forming one undo step, double-click / context-menu reset, toggles and dropdowns, external undo refreshing
 *   rows in place, header mute/bypass/solo toggles, MIDI learn arming and completion through processMidiFromRt
 *   with a synthetic CC packet, mapping badges and removal, the WaveShaper curve editor changing rendered audio and
 *   undoing, MultiSynth/MultiCtl curve blob round-trips, the ADSR envelope editor, MetaModule drill-down with a
 *   non-undoable child parameter edit, and clipped drawing.
 *
 * Real-Time & Safety Contract:
 *   Single-threaded; no audio device (the session applies Engine commands itself). Time is injected through a manual
 *   clock so double-click detection is deterministic.
 *
 * Dependencies:
 *   Internal: app.session, gui.{renderer,widgets}, gui.views.{param_rack,studio_context}, io.project_format,
 *             modules.*, platform.interfaces, sequencer.{note,timeline}
 *   External: core.stdc.string, std.algorithm (canFind), std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - class FakeRasterizer; final class ViewRig (session + context + UiContext + HeadlessRenderer + event helpers)
 *   - MidiPacket midiCc(...), float renderPeak(...), LoadedProject makeChildProject()
 *   - version(unittest) suites
 *
 * See_Also:
 *   dev_plan.md (Phase 8.3)
 */
module tests.unit.views_param_rack_test;

version (unittest) {
    import core.stdc.string : memcpy;
    import core.time : Duration;
    import std.algorithm : canFind;
    import std.math : abs, ceil, fabs, isFinite;

    import app.session : MidiNoteEvent, StudioSession;
    import graph.module_api : ParamDescriptor, ParamScale;
    import gui.renderer;
    import gui.widgets;
    import gui.views.param_rack;
    import gui.views.studio_context : StudioContext;
    import io.project_format : LoadedProject, loadProject, SavedModule, SavedPattern, SavedWire;
    import modules.control.metamodule : MetaMacroBinding, MetaModuleAsset;
    import modules.control.multictl : MultiCtlMapAsset;
    import modules.control.multisynth : MultiSynthCurveAsset;
    import platform.interfaces : KeyModifiers, MidiPacket, PlatformEvent, PlatformEventKind;
    import sequencer.note : NoteCell;
    import sequencer.timeline : TimelineClip;

    /**
     * Deterministic glyph rasterizer (advance = 0.5 em, solid boxes).
     */
    class FakeRasterizer : IGlyphRasterizer {
        /**
         * Produces a solid glyph.
         *
         * Params:
         *   font = Font.
         *   pixelSize = Size.
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
         * Reports line metrics.
         *
         * Params:
         *   font = Font.
         *   pixelSize = Size.
         *   ascent = Receives ascent.
         *   lineHeight = Receives line height.
         */
        override void lineMetrics(FontId font, float pixelSize, out float ascent, out float lineHeight) {
            ascent = pixelSize * 0.8f;
            lineHeight = pixelSize * 1.25f;
        }
    }

    /**
     * Headless rig: real session, studio context, a root panel hosting one view, and event helpers.
     */
    final class ViewRig {
        StudioSession session;
        StudioContext ctx;
        Panel root;
        UiContext ui;
        HeadlessRenderer renderer;
        double t = 0.0;
        RectF viewRect;

        /**
         * Creates the session and context (call host() to attach a view).
         */
        this() {
            session = new StudioSession();
            assert(session.initialize(44_100.0f));
            ctx = new StudioContext(session);
            renderer = new HeadlessRenderer(new GlyphCache(new FakeRasterizer()));
        }

        /**
         * Hosts a view inside a root panel at viewRect.
         *
         * Params:
         *   view = View widget.
         *   rect = View bounds.
         *   viewport = Window viewport.
         */
        void host(Widget view, RectF rect = RectF(20, 10, 560, 760), RectF viewport = RectF(0, 0, 600, 800)) {
            root = new Panel(PanelLayout.manual);
            view.bounds = rect;
            viewRect = rect;
            root.add(view);
            ui = new UiContext(root, &now);
            ui.layout(viewport, renderer);
        }

        /**
         * Returns the manual clock.
         *
         * Returns:
         *   Seconds.
         */
        double now() {
            return t;
        }

        /**
         * Re-runs layout (after the view changed structure).
         */
        void relayout() {
            ui.layout(ui.viewport(), renderer);
        }

        /**
         * Sends a platform event.
         *
         * Params:
         *   kind = Kind.
         *   p = Position.
         *   button = Button.
         *   mods = Modifiers.
         *
         * Returns:
         *   Handled flag.
         */
        bool send(PlatformEventKind kind, Point2F p, ubyte button = 0, uint mods = 0) {
            PlatformEvent e;
            e.kind = kind;
            e.x = p.x;
            e.y = p.y;
            e.mouseButton = button;
            e.modifiers = mods;
            return ui.handleEvent(e);
        }

        /**
         * Presses a button (one second after the previous press).
         *
         * Params:
         *   p = Position.
         *   button = Button.
         *   mods = Modifiers.
         *
         * Returns:
         *   Handled flag.
         */
        bool down(Point2F p, ubyte button = 0, uint mods = 0) {
            t += 1.0;
            return send(PlatformEventKind.mouseDown, p, button, mods);
        }

        /**
         * Releases a button.
         *
         * Params:
         *   p = Position.
         *   button = Button.
         *
         * Returns:
         *   Handled flag.
         */
        bool up(Point2F p, ubyte button = 0) {
            return send(PlatformEventKind.mouseUp, p, button);
        }

        /**
         * Moves the pointer.
         *
         * Params:
         *   p = Position.
         *
         * Returns:
         *   Handled flag.
         */
        bool move(Point2F p) {
            return send(PlatformEventKind.mouseMove, p);
        }

        /**
         * Clicks at a point.
         *
         * Params:
         *   p = Position.
         *   button = Button.
         */
        void click(Point2F p, ubyte button = 0) {
            down(p, button);
            up(p, button);
        }

        /**
         * Double-clicks at a point.
         *
         * Params:
         *   p = Position.
         */
        void doubleClick(Point2F p) {
            down(p);
            up(p);
            t += 0.1;
            send(PlatformEventKind.mouseDown, p);
            up(p);
        }

        /**
         * Drags from a to b in steps, with a pause longer than the coalescing window between steps.
         *
         * Params:
         *   a = Start.
         *   b = End.
         *   steps = Intermediate moves.
         */
        void drag(Point2F a, Point2F b, int steps = 6) {
            down(a);
            foreach (k; 1 .. steps + 1) {
                immutable float f = cast(float) k / cast(float) steps;
                move(Point2F(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f));
            }
            up(b);
        }

        /**
         * Scrolls at a point.
         *
         * Params:
         *   p = Position.
         *   dx = Horizontal delta.
         *   dy = Vertical delta.
         *   mods = Modifiers.
         *
         * Returns:
         *   Handled flag.
         */
        bool scroll(Point2F p, float dx, float dy, uint mods = 0) {
            PlatformEvent e;
            e.kind = PlatformEventKind.mouseScroll;
            e.x = p.x;
            e.y = p.y;
            e.deltaX = dx;
            e.deltaY = dy;
            e.modifiers = mods;
            return ui.handleEvent(e);
        }

        /**
         * Sends a pinch gesture.
         *
         * Params:
         *   p = Position.
         *   mag = Magnification.
         *
         * Returns:
         *   Handled flag.
         */
        bool magnify(Point2F p, float mag) {
            PlatformEvent e;
            e.kind = PlatformEventKind.magnify;
            e.x = p.x;
            e.y = p.y;
            e.magnification = mag;
            return ui.handleEvent(e);
        }

        /**
         * Renders one frame at 2x and returns the draw list.
         *
         * Returns:
         *   Draw list.
         */
        const(DrawList)* frame() {
            ui.renderFrame(renderer, 2.0f);
            return renderer.lastDrawList();
        }

        /**
         * Asserts that every draw command except the full-viewport background is clipped inside the view.
         *
         * Params:
         *   dl = Draw list.
         */
        void assertClipped(const(DrawList)* dl) {
            assert(dl.instances.length > 0);
            size_t inside = 0;
            foreach (ref c; dl.commands) {
                if (c.instanceCount == 0) {
                    continue;
                }
                immutable bool full = c.scissor.x == 0 && c.scissor.y == 0 && c.scissor.w == 1200 && c.scissor.h == 1600;
                if (full) {
                    continue;
                }
                inside++;
                assert(c.scissor.x >= cast(uint)(viewRect.x * 2.0f) - 1);
                assert(c.scissor.y >= cast(uint)(viewRect.y * 2.0f) - 1);
                assert(c.scissor.x + c.scissor.w <= cast(uint)(viewRect.right() * 2.0f) + 1);
                assert(c.scissor.y + c.scissor.h <= cast(uint)(viewRect.bottom() * 2.0f) + 1);
            }
            assert(inside > 0);
        }

        /**
         * Returns the topmost open context menu.
         *
         * Returns:
         *   Menu or null.
         */
        ContextMenu openMenu() {
            foreach_reverse (o; ui.overlays()) {
                if (auto m = cast(ContextMenu) o) {
                    return m;
                }
            }
            return null;
        }

        /**
         * Clicks the context-menu entry with a label.
         *
         * Params:
         *   label = Entry label.
         *
         * Returns:
         *   True if found and clicked.
         */
        bool clickMenu(string label) {
            auto m = openMenu();
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
         * Disposes the session.
         */
        void dispose() {
            session.dispose();
        }
    }

    /**
     * Builds a controller-change packet.
     *
     * Params:
     *   ch = Channel.
     *   cc = Controller.
     *   v = Value.
     *
     * Returns:
     *   Packet.
     */
    MidiPacket midiCc(ubyte ch, ubyte cc, ubyte v) {
        MidiPacket p;
        p.data = [cast(ubyte)(0xB0 | ch), cc, v];
        p.len = 3;
        return p;
    }

    /**
     * Renders host buffers and returns the absolute peak.
     *
     * Params:
     *   s = Session.
     *   blocks = 256-frame blocks.
     *
     * Returns:
     *   Peak.
     */
    float renderPeak(StudioSession s, size_t blocks) {
        float[256] l = 0.0f;
        float[256] r = 0.0f;
        float peak = 0.0f;
        const(float[])[2] ins = [null, null];
        foreach (_; 0 .. blocks) {
            float[][2] outs = [l[], r[]];
            s.engine().processHostBuffer(outs, ins, 256);
            foreach (i; 0 .. 256) {
                assert(isFinite(l[i]) && isFinite(r[i]));
                immutable float p = fabs(l[i]) > fabs(r[i]) ? fabs(l[i]) : fabs(r[i]);
                if (p > peak) peak = p;
            }
        }
        return peak;
    }

    /**
     * Builds a small child project (output + analog generator) for MetaModule tests.
     *
     * Returns:
     *   Child project.
     */
    LoadedProject makeChildProject() {
        LoadedProject child;
        child.title = "Child";
        SavedModule cOut;
        cOut.id = 1;
        cOut.typeId = "core.output";
        cOut.name = "Out";
        cOut.paramValues = [0.8f, 1.0f];
        SavedModule cGen;
        cGen.id = 2;
        cGen.typeId = "synth.analog_gen";
        cGen.name = "ChildOsc";
        cGen.paramValues = [2.0f, 1.0f, 0.1f, 3500.0f, 0.2f, 0.005f, 0.15f, 0.6f, 0.1f];
        child.modules = [cOut, cGen];
        child.wires = [SavedWire(2, 2, 1, 0, 1.0f)];
        SavedPattern pat;
        pat.patternId = 1;
        pat.tracks = 1;
        pat.lines = 8;
        pat.name = "P";
        pat.cells = new NoteCell[8];
        pat.cells[0] = NoteCell.makeNote(64, 0.9f, 2);
        child.patterns = [pat];
        child.clips = [TimelineClip(1, 1, 0, 0, 8, 0, 0, false, false, false)];
        return child;
    }

    private float docParam(StudioSession s, uint mod, uint idx) {
        foreach (ref m; s.document().modules) {
            if (m.id == mod) {
                assert(idx < m.paramValues.length);
                return m.paramValues[idx];
            }
        }
        assert(false, "module missing");
    }

    private const(ubyte)[] docBlob(StudioSession s, uint mod) {
        foreach (ref m; s.document().modules) {
            if (m.id == mod) {
                return m.extraBlob;
            }
        }
        assert(false, "module missing");
    }

    private bool near(float a, float b, float eps = 1e-3f) {
        return abs(a - b) <= eps;
    }

    unittest {
        ParamDescriptor lin = ParamDescriptor(0, "a", "Lin", 0.0f, 2.0f, 1.0f, "", ParamScale.linear);
        ParamDescriptor lg = ParamDescriptor(0, "b", "Log", 20.0f, 20_000.0f, 1000.0f, "Hz", ParamScale.logarithmic);
        ParamDescriptor lg0 = ParamDescriptor(0, "c", "Log0", 0.0f, 10.0f, 1.0f, "x", ParamScale.logarithmic);
        ParamDescriptor sw = ParamDescriptor(0, "d", "Switch", 0.0f, 1.0f, 1.0f, "", ParamScale.discrete);
        ParamDescriptor dd = ParamDescriptor(0, "e", "Mode", 0.0f, 5.0f, 2.0f, "", ParamScale.discrete);
        ParamDescriptor big = ParamDescriptor(0, "f", "Steps", 0.0f, 128.0f, 0.0f, "steps", ParamScale.discrete);
        assert(controlKindFor(lin) == ParamControlKind.slider);
        assert(controlKindFor(lg) == ParamControlKind.logSlider);
        assert(controlKindFor(sw) == ParamControlKind.toggle);
        assert(controlKindFor(dd) == ParamControlKind.dropdown);
        assert(controlKindFor(big) == ParamControlKind.steppedSlider);
        assert(valueRangeFor(lg).usesLog() && valueRangeFor(lg).min == 20.0f);
        assert(valueRangeFor(lg0).usesLog() && near(valueRangeFor(lg0).min, 0.01f, 1e-6f));
        assert(!valueRangeFor(lin).usesLog() && valueRangeFor(lin).step == 0.0f);
        assert(valueRangeFor(big).step == 1.0f);
        assert(formatParamValue(lg, 1234.0f) == "1234 Hz");
        assert(formatParamValue(dd, 3.0f) == "3");
        assert(formatParamValue(lin, 0.25f) == "0.250");

        float[5] table = [-1.0f, -0.5f, 0.0f, 0.5f, 1.0f];
        Point2F[] pts = curveTableToPoints(table[], -1.0f, 1.0f, 5);
        assert(pts.length == 5 && near(pts[1].x, 0.25f) && near(pts[1].y, 0.25f) && near(pts[4].y, 1.0f));
        auto ed = new CurveEditor(pts);
        float[9] back;
        resampleCurveToTable(ed, back[], -1.0f, 1.0f);
        assert(near(back[0], -1.0f) && near(back[4], 0.0f) && near(back[8], 1.0f));
    }

    unittest {
        auto rig = new ViewRig();
        scope (exit) rig.dispose();
        auto s = rig.session;
        immutable uint ws = s.doAddModule("fx.waveshaper", "Shaper");
        immutable uint mc = s.doAddModule("ctl.multictl", "Macro");
        assert(ws != 0 && mc != 0);
        auto view = new ParamRackView(rig.ctx);
        rig.host(view);
        assert(view.shownModule() == 0);
        assert(view.paramRowRect(0).isEmpty());

        rig.ctx.selectModule(ws);
        assert(view.shownModule() == ws);
        assert(view.controlKind(0) == ParamControlKind.logSlider);
        assert(view.controlKind(1) == ParamControlKind.slider);
        assert(view.controlKind(2) == ParamControlKind.toggle);
        assert(view.controlKind(3) == ParamControlKind.dropdown);
        assert(cast(RackSlider) view.paramControl(0) !is null);
        assert((cast(RackSlider) view.paramControl(0)).range.usesLog());
        assert(cast(Toggle) view.paramControl(2) !is null);
        assert((cast(Dropdown) view.paramControl(3)).items == ["0", "1", "2"]);
        assert(view.paramValueText(0) == "1.000 x");
        assert(view.hasCurveEditor() && view.editorKind() == RackEditorKind.waveshaper);
        foreach (i; 0 .. 4) {
            immutable RectF row = view.paramRowRect(i);
            assert(!row.isEmpty() && row.y >= rig.viewRect.y + ParamRackView.HEADER_HEIGHT - 0.5f);
            assert(row.contains(view.paramControlRect(i).center()));
        }
        Widget mixCtl = view.paramControl(1);
        assert(mixCtl.id == "rack.param.1.control");

        rig.ctx.selectModule(mc);
        assert(view.shownModule() == mc);
        assert(view.controlKind(2) == ParamControlKind.steppedSlider);
        assert((cast(RackSlider) view.paramControl(2)).range.step == 1.0f);
        assert(view.hasCurveEditor() && view.editorKind() == RackEditorKind.multiCtl);
        rig.assertClipped(rig.frame());
    }

    unittest {
        auto rig = new ViewRig();
        scope (exit) rig.dispose();
        auto s = rig.session;
        immutable uint ws = s.doAddModule("fx.waveshaper", "Shaper");
        auto view = new ParamRackView(rig.ctx);
        rig.host(view);
        rig.ctx.selectModule(ws);
        rig.frame();

        auto mix = cast(RackSlider) view.paramControl(1);
        s.history().setCoalesceWindow(Duration.zero);
        immutable size_t undo0 = s.history().undoCount();
        immutable Point2F thumb = mix.thumbRect().center();
        rig.down(thumb);
        foreach (k; 1 .. 8) {
            rig.t += 0.7;
            rig.move(Point2F(thumb.x - 12.0f * k, thumb.y));
            assert(view.paramControl(1) is mix);
        }
        rig.up(Point2F(thumb.x - 84.0f, thumb.y));
        immutable float dragged = docParam(s, ws, 1);
        assert(dragged < 0.8f && dragged > 0.0f);
        assert(s.history().undoCount() == undo0 + 1);
        immutable ParamDescriptor mixDesc = ParamDescriptor(1, "mix", "Mix", 0.0f, 1.0f, 1.0f, "", ParamScale.linear);
        assert(view.paramControl(1) is mix && view.paramValueText(1) == formatParamValue(mixDesc, dragged));
        assert(s.undo());
        assert(near(docParam(s, ws, 1), 1.0f));
        view.sync();
        assert(near(mix.value(), 1.0f) && view.paramValueText(1) == "1.000");
        assert(view.paramControl(1) is mix);
        assert(s.redo() && near(docParam(s, ws, 1), dragged));
        view.sync();
        assert(near(view.paramControlRect(1).w, mix.bounds.w) && near(mix.value(), dragged));

        s.history().breakCoalesce();
        immutable size_t undo1 = s.history().undoCount();
        rig.doubleClick(mix.thumbRect().center());
        assert(near(docParam(s, ws, 1), 1.0f));
        assert(s.history().undoCount() == undo1 + 1);
        assert(s.undo() && near(docParam(s, ws, 1), dragged));

        assert(s.doSetParam(ws, 0, 4.0f));
        assert(view.paramValueText(0) == "4.000 x");
        assert(near((cast(RackSlider) view.paramControl(0)).value(), 4.0f));
        assert(s.undo());
        assert(view.paramValueText(0) == "1.000 x");

        immutable size_t undo2 = s.history().undoCount();
        auto dc = cast(Toggle) view.paramControl(2);
        assert(dc.checked);
        rig.click(dc.bounds.center());
        assert(near(docParam(s, ws, 2), 0.0f) && !dc.checked);
        rig.click(dc.bounds.center());
        assert(near(docParam(s, ws, 2), 1.0f));
        assert(s.history().undoCount() == undo2 + 2);
        assert(s.undo() && near(docParam(s, ws, 2), 0.0f) && !(cast(Toggle) view.paramControl(2)).checked);
        immutable RectF dcRow = view.paramRowRect(2);
        immutable size_t undo3 = s.history().undoCount();
        rig.doubleClick(Point2F(dcRow.x + 10.0f, dcRow.center().y));
        assert(near(docParam(s, ws, 2), 1.0f) && s.history().undoCount() == undo3 + 1);

        auto os = cast(Dropdown) view.paramControl(3);
        rig.click(os.bounds.center());
        assert(os.isOpen());
        rig.click(os.popup().itemRect(2).center());
        assert(!os.isOpen());
        assert(near(docParam(s, ws, 3), 2.0f) && view.paramValueText(3) == "2");
        assert(s.undo() && view.paramValueText(3) == "0" && (cast(Dropdown) view.paramControl(3)).selectedIndex == 0);

        immutable RectF mixRow = view.paramRowRect(1);
        s.history().breakCoalesce();
        assert(s.doSetParam(ws, 1, 0.3f));
        s.history().breakCoalesce();
        immutable size_t undo4 = s.history().undoCount();
        rig.down(Point2F(mixRow.x + 10.0f, mixRow.center().y), 1);
        assert(rig.openMenu() !is null);
        assert(rig.clickMenu("Reset to Default"));
        assert(near(docParam(s, ws, 1), 1.0f) && s.history().undoCount() == undo4 + 1);

        assert(view.headerToggleRect(0).w > 0.0f);
        rig.click(view.headerToggleRect(0).center());
        assert(s.document().modules[1].muted);
        rig.click(view.headerToggleRect(1).center());
        assert(s.document().modules[1].bypassed);
        assert(s.undo() && !s.document().modules[1].bypassed);
        assert(s.undo() && !s.document().modules[1].muted);
        rig.frame();
        assert(!(cast(Toggle) view.paramControl(2) is null));
        rig.click(view.headerToggleRect(2).center());
        assert(s.isModuleSoloed(ws));
        rig.click(view.headerToggleRect(2).center());
        assert(!s.isModuleSoloed(ws));
        rig.assertClipped(rig.frame());
    }

    unittest {
        auto rig = new ViewRig();
        scope (exit) rig.dispose();
        auto s = rig.session;
        immutable uint ws = s.doAddModule("fx.waveshaper", "Shaper");
        auto view = new ParamRackView(rig.ctx);
        rig.host(view);
        rig.ctx.selectModule(ws);
        rig.frame();

        immutable RectF row = view.paramRowRect(1);
        rig.down(Point2F(row.x + 10.0f, row.center().y), 1);
        rig.up(Point2F(row.x + 10.0f, row.center().y), 1);
        auto menu = rig.openMenu();
        assert(menu !is null && menu.items[0].label == "MIDI Learn");
        assert(!menu.items.canFind!(it => it.label == "Remove MIDI Mapping"));
        assert(rig.clickMenu("MIDI Learn"));
        assert(s.midiLearnActive() && view.isLearning(1) && !view.isLearning(0));
        assert(rig.ui.isAnimating());
        rig.frame();

        MidiNoteEvent[] notes;
        MidiPacket[1] pk = [midiCc(0, 21, 64)];
        s.processMidiFromRt(pk[], notes);
        assert(!s.midiLearnActive() && s.document().midiMappings.length == 1);
        assert(!view.isLearning(1) && !rig.ui.isAnimating());
        assert(view.badgeText(1) == "CC 21" && view.badgeText(0) == "");
        MidiPacket[1] pk2 = [midiCc(0, 21, 127)];
        s.processMidiFromRt(pk2[], notes);
        assert(near(docParam(s, ws, 1), 1.0f));
        rig.frame();

        rig.down(Point2F(row.x + 10.0f, row.center().y), 1);
        rig.up(Point2F(row.x + 10.0f, row.center().y), 1);
        assert(rig.clickMenu("Remove MIDI Mapping"));
        assert(s.document().midiMappings.length == 0 && view.badgeText(1) == "");
        assert(s.undo() && view.badgeText(1) == "CC 21");

        assert(view.startMidiLearn(0) && view.isLearning(0));
        rig.down(Point2F(view.paramRowRect(0).x + 10.0f, view.paramRowRect(0).center().y), 1);
        assert(rig.clickMenu("Cancel MIDI Learn"));
        assert(!s.midiLearnActive() && !view.isLearning(0));
    }

    unittest {
        auto rig = new ViewRig();
        scope (exit) rig.dispose();
        auto s = rig.session;
        immutable uint gen = s.doAddModule("synth.analog_gen", "Gen");
        immutable uint ws = s.doAddModule("fx.waveshaper", "Shaper");
        assert(s.doConnectWire(gen, 2, ws, 0, 1.0f) && s.doConnectWire(ws, 1, 1, 0, 1.0f));
        assert(s.doPatchCell(1, 0, 0, NoteCell.makeNote(45, 1.0f, cast(ushort) gen)));
        auto view = new ParamRackView(rig.ctx);
        rig.host(view, RectF(20, 10, 560, 760));
        rig.ctx.selectModule(ws);
        rig.frame();
        assert(view.hasCurveEditor());
        assert(view.revealParam(0) == false);
        auto ed = view.curveEditor();
        assert(ed.points.length == CURVE_EDITOR_POINTS && ed.mode == CurveMode.smooth);
        assert(near(ed.points[8].y, 0.5f) && ed.points[16].y > 0.95f);

        assert(s.play());
        immutable float before = renderPeak(s, 30);
        assert(before > 0.15f);

        foreach (ref p; ed.points) {
            p.y = 0.5f;
        }
        immutable size_t undo0 = s.history().undoCount();
        immutable Point2F p4 = ed.toScreen(ed.points[4]);
        rig.drag(p4, Point2F(p4.x, p4.y - 4.0f));
        assert(s.history().undoCount() == undo0 + 1);
        const(ubyte)[] blob = docBlob(s, ws);
        assert(blob.length == 257 * float.sizeof);
        float[257] table;
        memcpy(table.ptr, blob.ptr, blob.length);
        assert(near(table[256], 0.0f) && near(table[128], 0.0f) && table[64] > 0.0f);
        assert(view.curveEditor() is ed && near(ed.points[8].y, 0.5f));
        immutable float after = renderPeak(s, 30);
        assert(after < before * 0.5f);
        assert(s.undo());
        assert(docBlob(s, ws).length == 0);
        assert(near(view.curveEditor().points[16].y, ed.points[16].y) && view.curveEditor().points[16].y > 0.95f);
        assert(renderPeak(s, 30) > 0.15f);
        rig.assertClipped(rig.frame());
    }

    unittest {
        auto rig = new ViewRig();
        scope (exit) rig.dispose();
        auto s = rig.session;
        immutable uint ms = s.doAddModule("ctl.multisynth", "MS");
        immutable uint mc = s.doAddModule("ctl.multictl", "MC");
        auto view = new ParamRackView(rig.ctx);
        rig.host(view);
        rig.ctx.selectModule(ms);
        rig.frame();
        assert(view.editorKind() == RackEditorKind.multiSynth);
        auto ed = view.curveEditor();
        assert(near(ed.points[8].y, 0.5f));
        Point2F p = ed.toScreen(ed.points[8]);
        immutable float dy = ed.plotRect().h * 0.25f;
        rig.drag(p, Point2F(p.x, p.y + dy));
        const(ubyte)[] blob = docBlob(s, ms);
        assert(blob.length == MultiSynthCurveAsset.sizeof);
        MultiSynthCurveAsset a;
        memcpy(&a, blob.ptr, blob.length);
        assert(near(a.velCurve[64], 0.5f, 0.02f) && near(a.velCurve[0], 1.0f) && near(a.velCurve[127], 1.0f));
        foreach (v; a.pitchOffset) {
            assert(near(v, 0.0f));
        }

        auto target = cast(Dropdown) null;
        foreach (w; view.curveEditor().parent().children()) {
            if (w.id == "rack.curveTarget") {
                target = cast(Dropdown) w;
            }
        }
        assert(target !is null);
        rig.click(target.bounds.center());
        rig.click(target.popup().itemRect(1).center());
        ed = view.curveEditor();
        foreach (ref q; ed.points) {
            assert(near(q.y, 0.5f));
        }
        p = ed.toScreen(ed.points[8]);
        rig.drag(p, Point2F(p.x, p.y - dy));
        blob = docBlob(s, ms);
        memcpy(&a, blob.ptr, blob.length);
        assert(near(a.pitchOffset[64], 12.0f, 0.5f) && near(a.pitchOffset[0], 0.0f));
        assert(near(a.velCurve[64], 0.5f, 0.02f));
        assert(s.undo());
        memcpy(&a, docBlob(s, ms).ptr, MultiSynthCurveAsset.sizeof);
        assert(near(a.pitchOffset[64], 0.0f) && near(a.velCurve[64], 0.5f, 0.02f));
        assert(near(view.curveEditor().points[8].y, 0.5f));
        view.selectCurveTarget(0);
        assert(near(view.curveEditor().points[8].y, 0.25f, 0.02f));
        assert(s.undo() && docBlob(s, ms).length == 0);
        assert(near(view.curveEditor().points[8].y, 0.5f));

        rig.ctx.selectModule(mc);
        rig.frame();
        assert(view.editorKind() == RackEditorKind.multiCtl);
        ed = view.curveEditor();
        assert(near(ed.points[8].y, 0.5f) && near(ed.points[16].y, 1.0f));
        p = ed.toScreen(ed.points[8]);
        rig.drag(p, Point2F(p.x, p.y - dy));
        blob = docBlob(s, mc);
        assert(blob.length == MultiCtlMapAsset.sizeof);
        MultiCtlMapAsset m;
        memcpy(&m, blob.ptr, blob.length);
        assert(near(m.curve[64], 0.75f, 0.02f) && near(m.curve[128], 1.0f) && near(m.curve[0], 0.0f));
        assert(m.targets[0].enabled && !m.targets[1].enabled);
        assert(s.undo() && docBlob(s, mc).length == 0);
        assert(near(view.curveEditor().points[8].y, 0.5f));
    }

    unittest {
        auto rig = new ViewRig();
        scope (exit) rig.dispose();
        auto s = rig.session;
        immutable uint env = s.doAddModule("ctl.adsr", "Env");
        auto view = new ParamRackView(rig.ctx);
        rig.host(view);
        rig.ctx.selectModule(env);
        rig.frame();
        assert(view.hasEnvelopeEditor() && !view.hasCurveEditor() && view.editorKind() == RackEditorKind.adsr);
        auto ed = view.envelopeEditor();
        assert(ed.points.length == 4 && near(ed.points[2].y, 0.7f));
        immutable size_t undo0 = s.history().undoCount();
        immutable Point2F sp = ed.toScreen(ed.points[2]);
        immutable Point2F ap = ed.toScreen(ed.points[1]);
        rig.drag(sp, Point2F(sp.x, sp.y + ed.plotRect().h * 0.3f));
        assert(near(docParam(s, env, 2), 0.4f, 0.02f));
        assert(s.history().undoCount() == undo0 + 1);
        rig.drag(ap, Point2F(ap.x + ed.plotRect().w * 0.1f, ap.y));
        immutable float atk = docParam(s, env, 0);
        assert(atk > 10.0f + 30.0f);
        assert(s.history().undoCount() == undo0 + 2);
        immutable ParamDescriptor atkDesc = ParamDescriptor(0, "attackMs", "Attack", 0.5f, 5000.0f, 10.0f, "ms",
            ParamScale.logarithmic);
        assert(view.envelopeEditor() is ed && view.paramValueText(0) == formatParamValue(atkDesc, atk));
        assert(s.undo() && near(docParam(s, env, 0), 10.0f, 0.05f));
        assert(s.undo() && near(docParam(s, env, 2), 0.7f));
        assert(near(view.envelopeEditor().points[2].y, 0.7f));
    }

    unittest {
        auto rig = new ViewRig();
        scope (exit) rig.dispose();
        auto s = rig.session;
        immutable uint meta = s.doAddModule("ctl.metamodule", "Meta");
        MetaMacroBinding[MetaModuleAsset.NUM_MACROS] macros;
        string err;
        LoadedProject childProj = makeChildProject();
        assert(s.setMetaModuleChildProject(meta, childProj, 2, macros, err), err);
        auto view = new ParamRackView(rig.ctx);
        rig.host(view);
        rig.ctx.selectModule(meta);
        rig.frame();
        assert(view.shownModule() == meta && !view.inChildGraph());
        assert(view.childModuleIds() == [1u, 2u]);
        assert(view.backButtonRect().isEmpty());
        rig.click(view.childButtonRect(1).center());
        assert(view.inChildGraph() && view.shownModule() == 2);
        assert(view.breadcrumb() == "Meta > ChildOsc");
        assert(!view.backButtonRect().isEmpty());
        assert(view.headerToggleRect(0).isEmpty());
        assert(view.paramValueText(3) == "3500 Hz");
        rig.frame();

        immutable size_t undo0 = s.history().undoCount();
        auto cutoff = cast(RackSlider) view.paramControl(3);
        immutable Point2F th = cutoff.thumbRect().center();
        rig.drag(th, Point2F(th.x + 40.0f, th.y));
        assert(s.history().undoCount() == undo0);
        LoadedProject child;
        const(ubyte)[] msv;
        foreach (ref m; s.document().modules) {
            if (m.id == meta) {
                msv = m.childProjectMsv;
            }
        }
        assert(loadProject(msv, child, err, 1), err);
        assert(child.modules[1].paramValues[3] > 3600.0f);
        assert(child.modules[1].paramValues[0] == 2.0f);
        assert(view.inChildGraph() && view.paramValueText(3) == formatParamValue(
            ParamDescriptor(3, "filterCutoff", "Cutoff", 40.0f, 18_000.0f, 4000.0f, "Hz", ParamScale.logarithmic),
            child.modules[1].paramValues[3]));
        assert(rig.ctx.status == "Child graph updated (not undoable)");

        rig.down(Point2F(view.paramRowRect(0).x + 10.0f, view.paramRowRect(0).center().y), 1);
        auto menu = rig.openMenu();
        assert(menu !is null && !menu.items[0].enabled);
        rig.ui.closeAllOverlays();

        rig.click(view.backButtonRect().center());
        assert(!view.inChildGraph() && view.shownModule() == meta);
        assert(view.childModuleIds().length == 2);
        assert(view.drillInto(1) && view.shownModule() == 1);
        rig.ctx.selectModule(0);
        assert(view.shownModule() == 0 && !view.inChildGraph());
        rig.frame();
    }
}
