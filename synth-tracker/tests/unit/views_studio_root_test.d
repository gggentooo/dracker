/**
 * File:         tests/unit/views_studio_root_test.d
 * Module:       tests.unit.views_studio_root_test
 * Phase:        Phase 8.6 — Studio Root Integration Tests
 *
 * Purpose:
 *   Headless integration tests of the assembled studio: every view is constructed over one StudioContext, laid
 *   out and drawn at Retina scale; keyboard shortcuts resolved through the Keymap route document-level actions to
 *   the session/root (undo/redo, record, octave, loop, play) and to the app command handler (save/open/export/
 *   quit), and context-dependent actions to the focused or last-used view (pattern copy/paste, patchbay zoom);
 *   unhandled piano keys play live notes on the selected module; the context keeps selections valid.
 *
 * Real-Time & Safety Contract:
 *   Headless; renders the engine through processHostBuffer to observe live notes.
 *
 * Dependencies:
 *   Internal: app.{keymap,session}, gui.{renderer,widgets}, gui.views.{studio_context,studio_root}, platform.interfaces,
 *             sequencer.note
 *   External: std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.6)
 */
module tests.unit.views_studio_root_test;

version (unittest) {
    import std.math : fabs;

    import app.keymap : StudioAction;
    import app.session : StudioSession;
    import gui.renderer;
    import gui.views.studio_context : IStudioClipboard, StudioContext;
    import gui.views.studio_root : StudioRoot;
    import gui.widgets : UiContext;
    import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;
    import sequencer.note : NoteCell;

    private final class RootRasterizer : IGlyphRasterizer {
        override bool rasterize(FontId font, float px, dchar cp, out RasterizedGlyph g) {
            g.width = 2;
            g.height = 2;
            g.bearingY = 2.0f;
            g.advance = px * 0.55f;
            g.coverage = new ubyte[4];
            return true;
        }

        override void lineMetrics(FontId font, float px, out float ascent, out float lineHeight) {
            ascent = px * 0.8f;
            lineHeight = px * 1.25f;
        }
    }

    private final class MemClipboard : IStudioClipboard {
        string text;

        override string getText() {
            return text;
        }

        override bool setText(string t) {
            text = t;
            return true;
        }
    }

    private struct Rig {
        StudioSession session;
        StudioContext ctx;
        StudioRoot root;
        UiContext ui;
        HeadlessRenderer renderer;
        MemClipboard clip;

        void frame() {
            renderer.beginFrame(1440, 900, 2.0f);
            ctx.tick();
            ui.layout(RectF(0, 0, 1440, 900), renderer);
            ui.draw(renderer);
            renderer.endFrame();
        }

        void mouse(PlatformEventKind kind, Point2F p, ubyte button = 0) {
            PlatformEvent ev;
            ev.kind = kind;
            ev.x = p.x;
            ev.y = p.y;
            ev.mouseButton = button;
            if (kind == PlatformEventKind.mouseDown) {
                root.noteInteraction(p);
            }
            ui.handleEvent(ev);
        }

        void click(Point2F p) {
            mouse(PlatformEventKind.mouseDown, p);
            mouse(PlatformEventKind.mouseUp, p);
            frame();
        }

        void key(uint code, uint mods = 0, bool down = true) {
            PlatformEvent ev;
            ev.kind = down ? PlatformEventKind.keyDown : PlatformEventKind.keyUp;
            ev.keyCode = code;
            ev.modifiers = mods;
            ui.handleEvent(ev);
        }

        void press(uint code, uint mods = 0) {
            key(code, mods, true);
            key(code, mods, false);
            frame();
        }
    }

    private Rig makeRig() {
        Rig r;
        r.session = new StudioSession();
        assert(r.session.initialize(44_100.0f));
        r.clip = new MemClipboard();
        r.ctx = new StudioContext(r.session, null, null, r.clip);
        r.root = new StudioRoot(r.ctx);
        r.ui = new UiContext(r.root);
        r.renderer = new HeadlessRenderer(new GlyphCache(new RootRasterizer()));
        r.frame();
        return r;
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        const dl = r.renderer.lastDrawList();
        assert(dl.instances.length > 200);
        foreach (ref c; dl.commands) {
            assert(c.scissor.x + c.scissor.w <= 2880 && c.scissor.y + c.scissor.h <= 1800);
        }
        foreach (w; [cast(Object) r.root.transport, r.root.patchbay, r.root.rack, r.root.scopeView, r.root.pattern,
                r.root.timeline, r.root.sampleEditor]) {
            assert(w !is null);
        }
        assert(!r.root.patchbay.bounds.isEmpty() && !r.root.pattern.bounds.isEmpty() && !r.root.timeline.bounds.isEmpty());
        assert(r.root.transport.bounds.h == StudioRoot.TRANSPORT_HEIGHT);
        assert(r.root.patchbay.bounds.intersect(r.root.pattern.bounds).isEmpty());
        assert(r.root.patchbay.bounds.intersect(r.root.rack.bounds).isEmpty());
        assert(r.root.pattern.bounds.intersect(r.root.timeline.bounds).isEmpty());
        assert(r.root.transport.bounds.intersect(r.root.patchbay.bounds).isEmpty());
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        immutable uint gen = r.session.doAddModule("synth.analog_gen", "Gen");
        r.frame();
        assert(r.session.doRenameModule(gen, "Lead"));
        r.press(6, KeyModifiers.command);
        assert(r.session.document().modules[1].name == "Gen");
        r.press(6, KeyModifiers.command | KeyModifiers.shift);
        assert(r.session.document().modules[1].name == "Lead");

        r.press(15, KeyModifiers.command);
        assert(r.ctx.recording);
        r.press(15, KeyModifiers.command);
        assert(!r.ctx.recording);
        immutable int oct = r.ctx.editOctave;
        r.press(120);
        assert(r.ctx.editOctave == oct + 1);
        r.press(122);
        r.press(122);
        assert(r.ctx.editOctave == oct - 1);
        r.frame();
        assert(r.session.currentOctave() == r.ctx.editOctave);

        assert(r.session.doAddClip(1, 64, 32) != 0);
        r.press(37, KeyModifiers.command);
        assert(r.session.document().loopEndLine == 96);
        r.press(37, KeyModifiers.command);
        assert(r.session.document().loopEndLine == 0);

        StudioAction[] appActions;
        r.root.appCommandHandler = (StudioAction a) { appActions ~= a; return true; };
        r.press(1, KeyModifiers.command);
        r.press(1, KeyModifiers.command | KeyModifiers.shift);
        r.press(31, KeyModifiers.command);
        r.press(45, KeyModifiers.command);
        r.press(14, KeyModifiers.command);
        r.press(12, KeyModifiers.command);
        assert(appActions == [StudioAction.saveProject, StudioAction.saveProjectAs, StudioAction.openProject,
            StudioAction.newProject, StudioAction.exportWav, StudioAction.quit]);

        r.press(49);
        float[256] l = 0.0f;
        float[256] rr = 0.0f;
        float[][2] outs = [l[], rr[]];
        const(float[])[2] ins = [null, null];
        r.session.engine().processHostBuffer(outs, ins, 256);
        r.frame();
        assert(r.session.isPlaying());
        r.press(53);
        r.session.engine().processHostBuffer(outs, ins, 256);
        r.frame();
        assert(!r.session.isPlaying());
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        immutable uint gen = r.session.doAddModule("synth.analog_gen", "Gen");
        assert(r.session.doConnectWire(gen, 2, 1, 0, 1.0f));
        r.ctx.selectModule(gen);
        r.frame();
        r.click(r.root.pattern.fieldRect(0, 0, 0).center());
        r.press(15, KeyModifiers.command);
        r.press(6);
        r.press(7);
        r.press(15, KeyModifiers.command);
        assert(!r.session.document().patterns[0].cells[0].isEmpty());
        assert(!r.session.document().patterns[0].cells[4].isEmpty());

        r.click(r.root.pattern.fieldRect(0, 0, 0).center());
        r.press(0, KeyModifiers.command);
        r.press(8, KeyModifiers.command);
        assert(r.clip.text.length > 0);
        r.click(r.root.pattern.fieldRect(2, 8, 0).center());
        immutable size_t undoBefore = r.session.history().undoCount();
        r.press(9, KeyModifiers.command);
        assert(r.session.history().undoCount() == undoBefore + 1);
        assert(r.session.document().patterns[0].cells[8 * 4 + 2] == r.session.document().patterns[0].cells[0]);

        r.click(r.root.patchbay.emptyCanvasPoint());
        immutable float z0 = r.root.patchbay.zoom();
        r.press(24, KeyModifiers.command);
        assert(r.root.patchbay.zoom() > z0);
        assert(r.session.document().patterns[0].cells[8 * 4 + 2] == r.session.document().patterns[0].cells[0]);
        r.press(29, KeyModifiers.command);
        assert(fabs(r.root.patchbay.zoom() - 1.0f) < 1e-4f);
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        immutable uint gen = r.session.doAddModule("synth.analog_gen", "Gen");
        assert(r.session.doConnectWire(gen, 2, 1, 0, 1.0f));
        r.frame();
        r.click(r.root.patchbay.emptyCanvasPoint());
        float[512] l = 0.0f;
        float[512] rr = 0.0f;
        float[][2] outs = [l[], rr[]];
        const(float[])[2] ins = [null, null];
        float peak() {
            float p = 0.0f;
            foreach (_; 0 .. 8) {
                r.session.engine().processHostBuffer(outs, ins, 512);
                foreach (v; l) {
                    if (fabs(v) > p) p = fabs(v);
                }
            }
            return p;
        }

        r.key(6);
        assert(peak() < 1e-6f);
        r.key(6, 0, false);
        r.ctx.selectModule(gen);
        r.frame();
        r.key(6);
        assert(peak() > 0.02f);
        r.key(6, 0, false);
        r.frame();

        assert(r.session.doRemoveModule(gen));
        r.frame();
        assert(r.ctx.selectedModule() == 0);
        immutable uint p2 = r.session.doAddPattern(4, 32, "B");
        r.ctx.selectPattern(p2);
        assert(r.session.doRemovePattern(p2));
        r.frame();
        assert(r.ctx.currentPattern() == 1);
    }
}
