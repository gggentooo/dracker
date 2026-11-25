/**
 * File:         tests/unit/views_piano_test.d
 * Module:       tests.unit.views_piano_test
 * Phase:        Phase 8.7 — On-Screen Piano Keyboard Tests
 *
 * Purpose:
 *   Headless unit and integration tests for PianoKeyboardView: full-width layout above the pattern and timeline
 *   editors, leftmost C per octave (-1..9) stopping at MIDI 127, octave digits drawn on every visible C key below
 *   the black-key zone, proportional key width scaling on vertical resize, far-right octave up/down buttons
 *   synced with StudioContext.editOctave, stark black-and-white colors with theme.accent highlights across themes,
 *   black-over-white hit-testing, live note triggering/glissando/release on the selected module, recording
 *   injection, and multi-source key highlighting for QWERTY, external MIDI, and active pattern playback.
 *
 * Real-Time & Safety Contract:
 *   Headless; uses HeadlessRenderer and processes Engine.processHostBuffer() to verify audio output and pattern
 *   playback telemetry.
 *
 * Dependencies:
 *   Internal: app.{audio_host,session}, gui.{appearance,renderer,theme,widgets}, gui.views.{piano_view,studio_context},
 *             platform.interfaces, sequencer.{engine,note}
 *   External: std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites for gui.views.piano_view
 *
 * See_Also:
 *   architecture.md, dev_plan.md
 */
module tests.unit.views_piano_test;

version (unittest) {
    import std.math : fabs;

    import app.audio_host : AudioLoadTelemetry;
    import app.session : MidiNoteEvent, StudioSession;
    import gui.appearance : AppearanceSettings;
    import gui.renderer;
    import gui.theme : ContrastMode, StudioTheme;
    import gui.views.piano_view;
    import gui.views.studio_context : IAudioControl, StudioContext;
    import gui.widgets : UiContext;
    import platform.interfaces : AudioDeviceInfo, MidiDeviceInfo, MidiPacket, PlatformEvent, PlatformEventKind;
    import sequencer.engine : Engine;
    import sequencer.note : NoteCell, NoteCmd;

    private final class PianoRasterizer : IGlyphRasterizer {
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

    private final class FakeMidiAudio : IAudioControl {
        MidiPacket[] queued;

        override bool running() {
            return true;
        }

        override AudioDeviceInfo[] audioDevices() {
            return null;
        }

        override bool selectOutputDevice(uint deviceId) {
            return true;
        }

        override uint currentOutputDevice() {
            return 0;
        }

        override MidiDeviceInfo[] midiSources() {
            return null;
        }

        override void setMidiTarget(uint moduleId) {
        }

        override bool readLoad(out AudioLoadTelemetry load) {
            load = AudioLoadTelemetry.init;
            return true;
        }

        override size_t drainMidi(MidiPacket[] outPackets) {
            size_t n = 0;
            while (n < outPackets.length && n < queued.length) {
                outPackets[n] = queued[n];
                n++;
            }
            queued = n < queued.length ? queued[n .. $] : null;
            return n;
        }

        void pushNote(bool on, ubyte ch, ubyte note, ubyte vel) {
            MidiPacket p;
            p.data = [cast(ubyte)((on ? 0x90 : 0x80) | (ch & 0x0F)), note, vel];
            p.len = 3;
            queued ~= p;
        }

        void pushAllNotesOff(ubyte ch) {
            MidiPacket p;
            p.data = [cast(ubyte)(0xB0 | (ch & 0x0F)), 123, 0];
            p.len = 3;
            queued ~= p;
        }
    }

    private struct PianoRig {
        StudioSession session;
        FakeMidiAudio audio;
        StudioContext ctx;
        PianoKeyboardView piano;
        UiContext ui;
        HeadlessRenderer renderer;
        RectF viewport = RectF(0, 0, 1440, 76);

        void frame() {
            renderer.beginFrame(viewport.w, viewport.h, 2.0f);
            ctx.tick();
            ui.layout(viewport, renderer);
            ui.draw(renderer);
            renderer.endFrame();
        }

        void mouse(PlatformEventKind kind, Point2F p, ubyte button = 0) {
            PlatformEvent ev;
            ev.kind = kind;
            ev.x = p.x;
            ev.y = p.y;
            ev.mouseButton = button;
            ui.handleEvent(ev);
        }

        void click(Point2F p) {
            mouse(PlatformEventKind.mouseDown, p);
            mouse(PlatformEventKind.mouseUp, p);
            frame();
        }
    }

    private PianoRig makePianoRig(float height = 76.0f, float width = 1440.0f) {
        PianoRig r;
        r.session = new StudioSession();
        assert(r.session.initialize(44_100.0f));
        r.audio = new FakeMidiAudio();
        r.ctx = new StudioContext(r.session, r.audio);
        r.piano = new PianoKeyboardView(r.ctx);
        r.ui = new UiContext(r.piano);
        r.renderer = new HeadlessRenderer(new GlyphCache(new PianoRasterizer()));
        r.viewport = RectF(0, 0, width, height);
        r.frame();
        return r;
    }

    private bool hasFillColorInside(ref PianoRig r, ColorRGBA c, RectF region) {
        immutable float[4] want = [c.r, c.g, c.b, c.a];
        foreach (ref inst; r.renderer.lastDrawList().instances) {
            if (inst.kind != InstanceKind.shape || inst.colorA != want) {
                continue;
            }
            immutable RectF ir = RectF(inst.rect[0] / 2.0f, inst.rect[1] / 2.0f, inst.rect[2] / 2.0f,
                inst.rect[3] / 2.0f);
            if (!ir.intersect(region).isEmpty()) {
                return true;
            }
        }
        return false;
    }

    private bool hasGlyphInside(ref PianoRig r, RectF region) {
        foreach (ref inst; r.renderer.lastDrawList().instances) {
            if (inst.kind != InstanceKind.glyph) {
                continue;
            }
            immutable RectF ir = RectF(inst.rect[0] / 2.0f, inst.rect[1] / 2.0f, inst.rect[2] / 2.0f,
                inst.rect[3] / 2.0f);
            if (!ir.intersect(region).isEmpty()) {
                return true;
            }
        }
        return false;
    }

    private float renderPeak(StudioSession session, size_t blocks = 8) {
        float[256] l = 0.0f;
        float[256] rr = 0.0f;
        float[][2] outs = [l[], rr[]];
        const(float[])[2] ins = [null, null];
        float peak = 0.0f;
        foreach (_; 0 .. blocks) {
            session.engine().processHostBuffer(outs, ins, 256);
            foreach (v; l) {
                if (fabs(v) > peak) peak = fabs(v);
            }
            foreach (v; rr) {
                if (fabs(v) > peak) peak = fabs(v);
            }
        }
        return peak;
    }

    unittest {
        PianoRig r = makePianoRig(76.0f, 1440.0f);
        scope (exit) r.session.dispose();
        assert(r.piano.bounds.w == 1440.0f && r.piano.bounds.h == 76.0f);
        immutable RectF bed = r.piano.keyBedRect();
        assert(bed.x == 0.0f && fabs(bed.w - (1440.0f - PianoKeyboardView.OCTAVE_BAR_WIDTH)) < 1e-3f);
        assert(r.piano.octaveUpRect().x >= bed.right() - 1e-3f);
        assert(r.piano.octaveDownRect().x >= bed.right() - 1e-3f);
        assert(r.piano.octaveUpRect().bottom() <= r.piano.octaveDownRect().y + 1e-3f);

        foreach (oct; -1 .. 10) {
            r.ctx.setEditOctave(oct);
            r.frame();
            immutable ubyte cMidi = cast(ubyte)((oct + 1) * 12);
            immutable RectF leftC = r.piano.keyRect(cMidi);
            assert(!leftC.isEmpty() && fabs(leftC.x - bed.x) < 1e-3f);
            if (cMidi > 0) {
                assert(r.piano.keyRect(cast(ubyte)(cMidi - 1)).isEmpty());
            }
            for (int m = cMidi; m <= 127; m += 12) {
                immutable RectF cr = r.piano.keyRect(cast(ubyte) m);
                if (cr.isEmpty()) {
                    break;
                }
                immutable RectF lowerZone = RectF(cr.x, bed.y + bed.h * PianoKeyboardView.BLACK_KEY_HEIGHT_RATIO,
                    cr.w, bed.h * (1.0f - PianoKeyboardView.BLACK_KEY_HEIGHT_RATIO));
                assert(hasGlyphInside(r, lowerZone));
            }
        }

        r.ctx.setEditOctave(0);
        r.viewport = RectF(0, 0, 1440, 48);
        r.frame();
        immutable float w48 = r.piano.whiteKeyWidth();
        immutable uint count48 = r.piano.visibleWhiteKeyCount();
        assert(fabs(w48 - 48.0f * PianoKeyboardView.WHITE_KEY_ASPECT) < 1e-3f);

        r.viewport = RectF(0, 0, 1440, 120);
        r.frame();
        immutable float w120 = r.piano.whiteKeyWidth();
        immutable uint count120 = r.piano.visibleWhiteKeyCount();
        assert(fabs(w120 - 120.0f * PianoKeyboardView.WHITE_KEY_ASPECT) < 1e-3f);
        assert(w120 > w48 && count120 < count48);

        r.viewport = RectF(0, 0, 1440, 300);
        r.frame();
        assert(fabs(r.piano.whiteKeyWidth() - PianoKeyboardView.MAX_WHITE_KEY_W) < 1e-3f);
        r.viewport = RectF(0, 0, 1440, 20);
        r.frame();
        assert(fabs(r.piano.whiteKeyWidth() - PianoKeyboardView.MIN_WHITE_KEY_W) < 1e-3f);
    }

    unittest {
        PianoRig r = makePianoRig(76.0f, 1440.0f);
        scope (exit) r.session.dispose();
        immutable RectF c4 = r.piano.keyRect(60);
        immutable RectF cs4 = r.piano.keyRect(61);
        assert(!c4.isEmpty() && !cs4.isEmpty());
        assert(r.piano.hitTestKey(cs4.center()) == 61);
        assert(r.piano.hitTestKey(Point2F(c4.x + c4.w * 0.35f, c4.y + c4.h * 0.85f)) == 60);
        assert(r.piano.hitTestKey(r.piano.octaveUpRect().center()) == -1);
        r.ctx.setEditOctave(9);
        r.frame();
        assert(r.piano.hitTestKey(Point2F(r.piano.keyBedRect().right() - 10.0f, 38.0f)) == -1);
    }

    unittest {
        PianoRig r = makePianoRig();
        scope (exit) r.session.dispose();
        immutable uint gen = r.session.doAddModule("synth.analog_gen", "Gen");
        assert(r.session.doConnectWire(gen, 2, 1, 0, 1.0f));
        r.frame();

        immutable RectF c4 = r.piano.keyRect(60);
        immutable RectF d4 = r.piano.keyRect(62);
        r.mouse(PlatformEventKind.mouseDown, Point2F(c4.center().x, c4.y + c4.h * 0.85f));
        r.frame();
        assert(r.piano.pressedMidi() == 60 && r.piano.isKeyHighlighted(60));
        assert(renderPeak(r.session) < 1e-6f);
        r.mouse(PlatformEventKind.mouseUp, Point2F(c4.center().x, c4.y + c4.h * 0.85f));
        r.frame();
        assert(r.piano.pressedMidi() == -1 && !r.piano.isKeyHighlighted(60));

        r.ctx.selectModule(gen);
        r.frame();
        r.mouse(PlatformEventKind.mouseDown, Point2F(c4.center().x, c4.y + c4.h * 0.85f));
        r.frame();
        assert(r.piano.isKeyHighlighted(60));
        assert(hasFillColorInside(r, r.ctx.theme.accent, c4));
        assert(renderPeak(r.session) > 0.02f);

        r.mouse(PlatformEventKind.mouseMove, Point2F(d4.center().x, d4.y + d4.h * 0.85f));
        r.frame();
        assert(r.piano.pressedMidi() == 62 && !r.piano.isKeyHighlighted(60) && r.piano.isKeyHighlighted(62));

        r.mouse(PlatformEventKind.mouseUp, Point2F(d4.center().x, d4.y + d4.h * 0.85f));
        r.frame();
        assert(r.piano.pressedMidi() == -1 && !r.piano.isKeyHighlighted(62));

        r.mouse(PlatformEventKind.mouseDown, Point2F(c4.center().x, c4.y + c4.h * 0.85f));
        r.frame();
        assert(r.piano.pressedMidi() == 60);
        r.ui.handleEvent(PlatformEvent(PlatformEventKind.focusChanged));
        r.frame();
        assert(r.piano.pressedMidi() == -1 && !r.piano.isKeyHighlighted(60));
    }

    unittest {
        PianoRig r = makePianoRig();
        scope (exit) r.session.dispose();
        assert(r.ctx.editOctave == 4 && r.piano.baseOctave() == 4);
        r.click(r.piano.octaveUpRect().center());
        assert(r.ctx.editOctave == 5 && r.piano.baseOctave() == 5);
        assert(r.piano.keyRect(60).isEmpty() && fabs(r.piano.keyRect(72).x) < 1e-3f);
        r.click(r.piano.octaveDownRect().center());
        r.click(r.piano.octaveDownRect().center());
        assert(r.ctx.editOctave == 3);

        foreach (_; 0 .. 12) {
            r.click(r.piano.octaveUpRect().center());
        }
        assert(r.ctx.editOctave == 9 && !r.piano.octaveUpBtn.enabled && r.piano.octaveDownBtn.enabled);
        foreach (_; 0 .. 15) {
            r.click(r.piano.octaveDownRect().center());
        }
        assert(r.ctx.editOctave == -1 && r.piano.octaveUpBtn.enabled && !r.piano.octaveDownBtn.enabled);

        r.ctx.setEditOctave(4);
        r.frame();
        r.ctx.editMode = true;
        immutable RectF e4 = r.piano.keyRect(64);
        r.click(Point2F(e4.center().x, e4.y + e4.h * 0.85f));
        MidiNoteEvent[] notes = r.ctx.takeMidiNotes();
        assert(notes.length == 1 && notes[0].note == 64);
    }

    unittest {
        PianoRig r = makePianoRig();
        scope (exit) r.session.dispose();
        immutable uint genA = r.session.doAddModule("synth.analog_gen", "GenA");
        immutable uint genB = r.session.doAddModule("synth.analog_gen", "GenB");
        assert(r.session.doConnectWire(genA, 2, 1, 0, 0.8f));
        assert(r.session.doConnectWire(genB, 2, 1, 0, 0.8f));

        r.ctx.selectModule(genA);
        r.audio.pushNote(true, 0, 65, 100);
        r.frame();
        assert(r.piano.isKeyHighlighted(65));
        assert(hasFillColorInside(r, r.ctx.theme.accent, r.piano.keyRect(65)));

        r.ctx.selectModule(genB);
        r.frame();
        assert(!r.piano.isKeyHighlighted(65));

        r.ctx.selectModule(genA);
        r.frame();
        assert(r.piano.isKeyHighlighted(65));

        r.audio.pushNote(false, 0, 65, 0);
        r.frame();
        assert(!r.piano.isKeyHighlighted(65));

        r.audio.pushNote(true, 0, 67, 100);
        r.frame();
        assert(r.piano.isKeyHighlighted(67));
        r.audio.pushAllNotesOff(0);
        r.frame();
        assert(!r.piano.isKeyHighlighted(67));

        assert(r.session.doPatchCell(1, 0, 0, NoteCell.makeNote(60, 0.8f, cast(ushort) genA)));
        assert(r.session.doPatchCell(1, 1, 0, NoteCell.makeNote(67, 0.8f, cast(ushort) genB)));
        assert(r.session.doPatchCell(1, 0, 4, NoteCell.makeNoteOff()));
        assert(r.session.doPatchCell(1, 1, 4, NoteCell.makeNoteOff()));

        r.ctx.selectModule(genA);
        r.session.play();
        float[64] l = 0.0f;
        float[64] rr = 0.0f;
        float[][2] outs = [l[], rr[]];
        const(float[])[2] ins = [null, null];
        r.session.engine().processHostBuffer(outs, ins, 64);
        r.frame();
        assert(r.piano.isKeyHighlighted(60) && !r.piano.isKeyHighlighted(67));

        r.ctx.selectModule(genB);
        r.session.engine().processHostBuffer(outs, ins, 64);
        r.frame();
        assert(r.piano.isKeyHighlighted(67) && !r.piano.isKeyHighlighted(60));

        r.session.stop();
        r.session.engine().processHostBuffer(outs, ins, 64);
        r.frame();
        assert(!r.piano.isKeyHighlighted(60) && !r.piano.isKeyHighlighted(67));

        AppearanceSettings dark;
        dark.palette = "Dark · Okabe–Ito";
        dark.contrast = ContrastMode.high;
        r.ctx.applyAppearance(dark, false);
        r.ui.setTheme(r.ctx.theme);
        r.frame();
        immutable RectF c4 = r.piano.keyRect(60);
        immutable RectF cs4 = r.piano.keyRect(61);
        assert(hasFillColorInside(r, r.ctx.theme.pianoWhiteKey, c4));
        assert(hasFillColorInside(r, r.ctx.theme.pianoBlackKey, cs4));
        r.mouse(PlatformEventKind.mouseDown, Point2F(c4.center().x, c4.y + c4.h * 0.85f));
        r.frame();
        assert(hasFillColorInside(r, r.ctx.theme.accent, c4));
        r.mouse(PlatformEventKind.mouseUp, Point2F(c4.center().x, c4.y + c4.h * 0.85f));
    }

    unittest {
        PianoRig r = makePianoRig();
        scope (exit) r.session.dispose();
        auto s = r.session;
        immutable uint gen = s.doAddModule("synth.analog_gen", "Gen");
        assert(s.doConnectWire(gen, 2, 1, 0, 1.0f));
        r.ctx.selectModule(gen);
        r.ctx.setEditOctave(4);
        r.frame();
        float[256] l = 0.0f;
        float[256] rr = 0.0f;
        float[][2] outs = [l[], rr[]];
        const(float[])[2] ins = [null, null];
        void renderUntil(double pos) {
            foreach (_; 0 .. 4000) {
                s.engine().processHostBuffer(outs, ins, 256);
                r.ctx.tick();
                if (s.liveSongPosition() >= pos) {
                    return;
                }
            }
            assert(false, "renderUntil timed out");
        }

        assert(r.ctx.startLiveRecord());
        r.audio.pushNote(true, 0, 70, 100);
        renderUntil(-12.0);
        assert(s.liveTakeNoteCount() == 0);
        r.audio.pushNote(false, 0, 70, 0);
        renderUntil(0.0);

        immutable RectF e4 = r.piano.keyRect(64);
        r.mouse(PlatformEventKind.mouseDown, Point2F(e4.center().x, e4.y + e4.h * 0.85f));
        renderUntil(2.0);
        r.mouse(PlatformEventKind.mouseUp, Point2F(e4.center().x, e4.y + e4.h * 0.85f));
        r.audio.pushNote(true, 3, 67, 127);
        r.ctx.tick();
        renderUntil(5.0);
        r.audio.pushNote(false, 3, 67, 0);
        r.ctx.tick();
        assert(s.liveTakeNoteCount() == 2);

        immutable uint pid = r.ctx.stopLiveRecord();
        assert(pid != 0);
        const take = s.document().patterns[$ - 1];
        assert(take.patternId == pid && take.lines == 16 && take.tracks == 4);
        assert(take.cells[0].note == NoteCell.encodeMidiNote(64) && take.cells[0].moduleId == gen);
        assert(take.cells[2 * 4].note == NoteCell.encodeMidiNote(67) && take.cells[2 * 4].moduleId == gen);
        assert(take.cells[2 * 4].normalizedVelocity() > 0.99f);
        assert(take.cells[5 * 4].note == NoteCmd.noteOff);
        foreach (i, c; take.cells) {
            assert(i == 0 || i == 2 * 4 || i == 5 * 4 || c.isEmpty());
        }
        assert(s.document().clips[$ - 1].startLine == 0 && s.document().clips[$ - 1].laneY == 1);
    }
}
