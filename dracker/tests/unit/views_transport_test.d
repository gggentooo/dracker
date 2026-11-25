/**
 * File:         tests/unit/views_transport_test.d
 * Module:       tests.unit.views_transport_test
 * Phase:        Phase 8.1 — Transport Bar & Scope View Tests
 *
 * Purpose:
 *   Headless verification of TransportBarView and ScopeView over a real StudioSession: every transport button's
 *   effect on the session (play/stop/pattern audition/record/follow/loop incl. loop undo), BPM/TPL drag gestures as
 *   single undo steps that reflect undo/external edits, octave/step boxes, readout/dirty/DSP/xrun texts, meter
 *   ballistics and clip-hold timing with an injected clock, the device dropdown over a fake IAudioControl, graceful
 *   null-audio behaviour, scope drawing from synthetic ScopeBlocks (trigger, spectrum peak location, goniometer),
 *   source switching through requestScopeTaps, clipping and isAnimating.
 *
 * Real-Time & Safety Contract:
 *   Single-threaded; the Engine is advanced with processHostBuffer() on the test thread (no audio device).
 *
 * Dependencies:
 *   Internal: app.{audio_host,keymap,session}, gui.{renderer,widgets}, gui.views.{scope_view,studio_context,
 *   transport_bar}, platform.interfaces, sequencer.engine
 *   External: std.math (abs, PI, sin)
 *
 * Planned API (Types, Functions & Hooks):
 *   - class TestRasterizer : IGlyphRasterizer; class ManualClock; class FakeAudio : IAudioControl
 *   - class Rig (session + context + UiContext + renderer helpers)
 *   - version(unittest) suites
 *
 * See_Also:
 *   dev_plan.md (Phase 8.1)
 */
module tests.unit.views_transport_test;

version (unittest) {
    import std.math : abs, PI, sin;

    import app.audio_host : AudioLoadTelemetry;
    import app.keymap : StudioAction;
    import app.session : StudioSession;
    import gui.renderer;
    import gui.widgets : Dropdown, NumericDragBox, UiContext, Widget;
    import gui.views.scope_view : ScopeMode, ScopeView;
    import gui.views.studio_context : IAudioControl, StudioContext;
    import gui.views.transport_bar : TransportBarView, TransportButton;
    import platform.interfaces : AudioDeviceInfo, MidiDeviceInfo, MidiPacket, PlatformEvent, PlatformEventKind;
    import sequencer.engine : ScopeBlock;

    /**
     * Deterministic glyph rasterizer (advance = 0.5 em, solid boxes).
     */
    final class TestRasterizer : IGlyphRasterizer {
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
         *   Always true.
         */
        override bool rasterize(FontId font, float pixelSize, dchar cp, out RasterizedGlyph outGlyph) {
            outGlyph.advance = pixelSize * 0.5f;
            if (cp == ' ') {
                return true;
            }
            outGlyph.width = 4;
            outGlyph.height = 6;
            outGlyph.bearingY = 6.0f;
            outGlyph.coverage = new ubyte[24];
            outGlyph.coverage[] = 255;
            return true;
        }

        /**
         * Reports fixed metrics.
         *
         * Params:
         *   font = Font.
         *   pixelSize = Size.
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
    final class ManualClock {
        double t = 10.0;

        /**
         * Returns the time.
         *
         * Returns:
         *   Seconds.
         */
        double now() {
            return t;
        }
    }

    /**
     * Fake audio/MIDI control recording device switches.
     */
    final class FakeAudio : IAudioControl {
        bool isRunning = true;
        uint current = 0;
        uint[] selected;
        bool failSelect = false;
        uint midiTarget = 0;

        /**
         * Reports running.
         *
         * Returns:
         *   isRunning.
         */
        bool running() {
            return isRunning;
        }

        /**
         * Lists three devices (one input-only).
         *
         * Returns:
         *   Devices.
         */
        AudioDeviceInfo[] audioDevices() {
            AudioDeviceInfo a;
            a.id = 11;
            a.name = "Built-in Output";
            a.outputChannels = 2;
            AudioDeviceInfo b;
            b.id = 22;
            b.name = "USB Interface";
            b.outputChannels = 8;
            AudioDeviceInfo mic;
            mic.id = 33;
            mic.name = "Mic Only";
            mic.inputChannels = 1;
            return [a, b, mic];
        }

        /**
         * Records a switch.
         *
         * Params:
         *   deviceId = Device.
         *
         * Returns:
         *   False when failSelect is set.
         */
        bool selectOutputDevice(uint deviceId) {
            selected ~= deviceId;
            if (failSelect) {
                return false;
            }
            current = deviceId;
            return true;
        }

        /**
         * Returns the current device.
         *
         * Returns:
         *   Device id.
         */
        uint currentOutputDevice() {
            return current;
        }

        /**
         * Lists two online sources and one offline.
         *
         * Returns:
         *   Sources.
         */
        MidiDeviceInfo[] midiSources() {
            MidiDeviceInfo k;
            k.id = 1;
            k.name = "kb";
            k.displayName = "Keystation";
            k.isInput = true;
            MidiDeviceInfo p;
            p.id = 2;
            p.name = "Pads";
            p.isInput = true;
            MidiDeviceInfo gone;
            gone.id = 3;
            gone.name = "Gone";
            gone.isInput = true;
            gone.isOffline = true;
            return [k, p, gone];
        }

        /**
         * Records the MIDI target.
         *
         * Params:
         *   moduleId = Module.
         */
        void setMidiTarget(uint moduleId) {
            midiTarget = moduleId;
        }

        /**
         * Reports no load (the context then keeps its injected telemetry).
         *
         * Params:
         *   load = Unused.
         *
         * Returns:
         *   False.
         */
        bool readLoad(out AudioLoadTelemetry load) {
            return false;
        }

        /**
         * Drains nothing.
         *
         * Params:
         *   outPackets = Unused.
         *
         * Returns:
         *   0.
         */
        size_t drainMidi(MidiPacket[] outPackets) {
            return 0;
        }
    }

    /**
     * Session + context + UiContext hosting a root widget.
     */
    final class Rig {
        StudioSession session;
        StudioContext ctx;
        ManualClock clock;
        UiContext ui;
        HeadlessRenderer renderer;
        RectF viewport;

        /**
         * Creates the session and context.
         *
         * Params:
         *   audio = Audio control or null.
         */
        this(IAudioControl audio) {
            session = new StudioSession();
            assert(session.initialize(44_100.0f));
            ctx = new StudioContext(session, audio);
            clock = new ManualClock();
            renderer = new HeadlessRenderer(new GlyphCache(new TestRasterizer()));
        }

        /**
         * Hosts root in a UiContext and lays it out.
         *
         * Params:
         *   root = Root widget.
         *   vp = Viewport.
         */
        void host(Widget root, RectF vp) {
            viewport = vp;
            ui = new UiContext(root, &clock.now);
            ui.layout(vp, renderer);
        }

        /**
         * Renders one frame at 2x.
         *
         * Returns:
         *   Draw list.
         */
        const(DrawList)* frame() {
            renderer.beginFrame(viewport.w, viewport.h, 2.0f);
            ui.draw(renderer);
            renderer.endFrame();
            return renderer.lastDrawList();
        }

        /**
         * Advances the engine by blocks x 256 frames and refreshes context telemetry.
         *
         * Params:
         *   blocks = Host buffers.
         */
        void render(size_t blocks) {
            float[256] l = 0.0f;
            float[256] r = 0.0f;
            const(float[])[2] ins = [null, null];
            foreach (_; 0 .. blocks) {
                float[][2] outs = [l[], r[]];
                session.engine().processHostBuffer(outs, ins, 256);
            }
            ctx.tick();
        }

        /**
         * Sends a mouse event.
         *
         * Params:
         *   kind = Kind.
         *   p = Position.
         *   mods = Modifiers.
         */
        void mouse(PlatformEventKind kind, Point2F p, uint mods = 0) {
            PlatformEvent e;
            e.kind = kind;
            e.x = p.x;
            e.y = p.y;
            e.modifiers = mods;
            ui.handleEvent(e);
        }

        /**
         * Clicks the centre of a rectangle (one second after the previous click).
         *
         * Params:
         *   rect = Target.
         */
        void click(RectF rect) {
            clock.t += 1.0;
            assert(!rect.isEmpty());
            mouse(PlatformEventKind.mouseDown, rect.center());
            mouse(PlatformEventKind.mouseUp, rect.center());
        }

        /**
         * Drags from the centre of a rectangle by dx (in several moves).
         *
         * Params:
         *   rect = Target.
         *   dx = Horizontal distance.
         */
        void drag(RectF rect, float dx) {
            clock.t += 1.0;
            immutable Point2F c = rect.center();
            mouse(PlatformEventKind.mouseDown, c);
            foreach (i; 1 .. 5) {
                mouse(PlatformEventKind.mouseMove, Point2F(c.x + dx * i / 4.0f, c.y));
            }
            mouse(PlatformEventKind.mouseUp, Point2F(c.x + dx, c.y));
        }

        /**
         * Types text then Return into the focused widget.
         *
         * Params:
         *   text = ASCII text.
         */
        void type(string text) {
            foreach (char ch; text) {
                PlatformEvent e;
                e.kind = PlatformEventKind.textInput;
                e.utf32Char = ch;
                ui.handleEvent(e);
            }
            PlatformEvent k;
            k.kind = PlatformEventKind.keyDown;
            k.keyCode = 36;
            ui.handleEvent(k);
        }

        /**
         * Releases the session.
         */
        void dispose() {
            session.dispose();
        }
    }

    private Rig transportRig(IAudioControl audio, out TransportBarView bar) {
        Rig rig = new Rig(audio);
        bar = new TransportBarView(rig.ctx);
        rig.host(bar, RectF(0, 0, 1500, 40));
        rig.frame();
        return rig;
    }

    private bool near(double a, double b, double eps = 1e-4) {
        return abs(a - b) <= eps;
    }

    private T findChild(T)(Widget root, string wid) {
        foreach (c; root.children()) {
            if (c.id == wid) {
                return cast(T) c;
            }
        }
        return null;
    }

    private void pushSine(StudioContext ctx, uint source, double freq, float amp, size_t blocks, double sr = 44_100.0,
            float rightScale = 1.0f) {
        ulong frame = ctx.scopes.newestFrame(source);
        size_t idx = cast(size_t)(frame == 0 ? 0 : frame + 64);
        foreach (b; 0 .. blocks) {
            ScopeBlock blk;
            blk.sourceId = source;
            blk.frame = idx;
            foreach (i; 0 .. 64) {
                immutable float v = amp * cast(float) sin(2.0 * PI * freq * (idx + i) / sr);
                blk.left[i] = v;
                blk.right[i] = v * rightScale;
            }
            ctx.scopes.push(blk);
            idx += 64;
        }
    }

    private bool allInside(const(DrawList)* dl, RectF r, float scale, size_t first) {
        foreach (i; first .. dl.instances.length) {
            const inst = dl.instances[i];
            if (inst.kind == InstanceKind.glyph) {
                continue;
            }
            if (inst.rect[0] < -1.0f || inst.rect[1] < -1.0f) {
                return false;
            }
        }
        foreach (ref cmd; dl.commands) {
            if (cmd.scissor.x + cmd.scissor.w > cast(uint)((r.right()) * scale) + 1
                    || cmd.scissor.y + cmd.scissor.h > cast(uint)((r.bottom()) * scale) + 1) {
                return false;
            }
        }
        return true;
    }

    unittest {
        TransportBarView bar;
        Rig rig = transportRig(null, bar);
        scope (exit) rig.dispose();
        foreach (wid; ["transport.play", "transport.stop", "transport.playPattern", "transport.record",
                "transport.follow", "transport.loop", "transport.bpm", "transport.tpl", "transport.sigNum",
                "transport.sigDen", "transport.device",
                "transport.octave", "transport.step", "transport.readout", "transport.dsp", "transport.meters",
                "transport.clip", "transport.midi", "transport.dirty"]) {
            immutable RectF r = bar.controlRect(wid);
            assert(!r.isEmpty(), wid);
            assert(r.x >= 0.0f && r.right() <= 1500.0f && r.y >= 0.0f && r.bottom() <= 40.0f, wid);
        }
        assert(bar.controlRect("transport.nope").isEmpty());
        assert(near(bar.controlRect("transport.play").h, 28.0f));

        assert(!rig.session.isPlaying());
        rig.click(bar.controlRect("transport.play"));
        rig.render(2);
        assert(rig.session.isPlaying() && rig.ctx.telemetry.engine.playing);
        rig.frame();
        auto playBtn = findChild!TransportButton(bar, "transport.play");
        assert(playBtn !is null && playBtn.lit && playBtn.pausedGlyph);
        assert(bar.isAnimating());
        rig.click(bar.controlRect("transport.play"));
        rig.render(1);
        assert(!rig.session.isPlaying());
        rig.frame();
        assert(!playBtn.lit);

        rig.click(bar.controlRect("transport.play"));
        rig.render(200);
        assert(rig.ctx.telemetry.engine.currentLine > 0);
        rig.click(bar.controlRect("transport.stop"));
        rig.render(1);
        assert(!rig.session.isPlaying());
        assert(rig.ctx.telemetry.engine.currentLine == 0 && rig.ctx.telemetry.engine.currentTick == 0);
        assert(rig.session.history().canUndo() == false);
    }

    unittest {
        TransportBarView bar;
        Rig rig = transportRig(null, bar);
        scope (exit) rig.dispose();
        auto patBtn = findChild!TransportButton(bar, "transport.playPattern");
        rig.click(bar.controlRect("transport.playPattern"));
        assert(rig.session.isAuditioningPattern());
        rig.render(2);
        assert(rig.session.isPlaying());
        rig.frame();
        assert(patBtn.lit);
        rig.click(bar.controlRect("transport.playPattern"));
        assert(!rig.session.isAuditioningPattern());
        rig.render(1);
        assert(!rig.session.isPlaying());
        rig.frame();
        assert(!patBtn.lit);

        rig.ctx.selectPattern(999);
        rig.click(bar.controlRect("transport.playPattern"));
        assert(!rig.session.isAuditioningPattern() && rig.ctx.status == "No pattern to play");

        auto edit = findChild!TransportButton(bar, "transport.edit");
        assert(!rig.ctx.editMode && !edit.lit);
        rig.click(bar.controlRect("transport.edit"));
        assert(rig.ctx.editMode && edit.lit && rig.ctx.status == "Edit on");
        rig.click(bar.controlRect("transport.edit"));
        assert(!rig.ctx.editMode && !edit.lit && rig.ctx.status == "Edit off");

        auto rec = findChild!TransportButton(bar, "transport.record");
        rig.ctx.selectModule(0);
        rig.click(bar.controlRect("transport.record"));
        assert(!rig.ctx.liveRecording() && !rec.lit && rig.ctx.status == "Select an instrument module to record");
        rig.ctx.selectModule(1);
        rig.click(bar.controlRect("transport.record"));
        assert(!rig.ctx.liveRecording() && rig.ctx.status == "Select an instrument module to record");

        auto fol = findChild!TransportButton(bar, "transport.follow");
        assert(rig.ctx.followPlayhead && fol.lit);
        rig.click(bar.controlRect("transport.follow"));
        assert(!rig.ctx.followPlayhead && !fol.lit);
        assert(bar.handleStudioAction(StudioAction.toggleFollow));
        assert(rig.ctx.followPlayhead);
        immutable uint step0 = rig.ctx.editStep;
        assert(bar.handleStudioAction(StudioAction.stepUp) && rig.ctx.editStep == step0 + 1);
        assert(bar.handleStudioAction(StudioAction.stepDown) && rig.ctx.editStep == step0);
        assert(!bar.handleStudioAction(StudioAction.copy));
        assert(rig.session.history().canUndo() == false);
    }

    unittest {
        TransportBarView bar;
        Rig rig = transportRig(null, bar);
        scope (exit) rig.dispose();
        auto loop = findChild!TransportButton(bar, "transport.loop");
        assert(rig.session.doAddClip(1, 64, 32) != 0);
        assert(rig.session.document().loopEndLine == 0);
        rig.click(bar.controlRect("transport.loop"));
        assert(rig.session.document().loopStartLine == 0 && rig.session.document().loopEndLine == 96);
        rig.frame();
        assert(loop.lit);
        rig.click(bar.controlRect("transport.loop"));
        assert(rig.session.document().loopEndLine == 0);
        rig.frame();
        assert(!loop.lit);
        assert(rig.session.undo());
        rig.frame();
        assert(rig.session.document().loopEndLine == 96 && loop.lit);
        assert(rig.session.undo());
        rig.frame();
        assert(rig.session.document().loopEndLine == 0 && !loop.lit);
        assert(rig.session.redo());
        assert(rig.session.document().loopEndLine == 96);
    }

    unittest {
        TransportBarView bar;
        Rig rig = transportRig(null, bar);
        scope (exit) rig.dispose();
        auto loop = findChild!TransportButton(bar, "transport.loop");
        const doc = rig.session.document();
        foreach (cid; 0 .. doc.clips.length) {
            assert(rig.session.doRemoveClip(rig.session.document().clips[0].clipId));
        }
        assert(rig.session.document().clips.length == 0);
        rig.click(bar.controlRect("transport.loop"));
        assert(rig.session.document().loopEndLine == 64);
        rig.frame();
        assert(loop.lit);
    }

    unittest {
        TransportBarView bar;
        Rig rig = transportRig(null, bar);
        scope (exit) rig.dispose();
        auto bpm = findChild!NumericDragBox(bar, "transport.bpm");
        auto tpl = findChild!NumericDragBox(bar, "transport.tpl");
        assert(near(bpm.value(), 125.0) && near(tpl.value(), 6.0));
        assert(!rig.session.history().canUndo());

        rig.drag(bar.controlRect("transport.bpm"), 160.0f);
        immutable double dragged = rig.session.document().bpm;
        assert(dragged > 125.0 + 1.0 && dragged < 135.0);
        assert(near(dragged * 10.0, cast(double) cast(long)(dragged * 10.0 + 0.5), 1e-6));
        assert(rig.session.history().canUndo());
        assert(rig.session.undo());
        assert(!rig.session.history().canUndo());
        assert(near(rig.session.document().bpm, 125.0));
        rig.frame();
        assert(near(bpm.value(), 125.0));
        assert(rig.session.redo());
        rig.frame();
        assert(near(bpm.value(), dragged, 1e-3));
        assert(rig.session.undo());
        rig.frame();

        rig.drag(bar.controlRect("transport.tpl"), 40.0f);
        immutable uint t2 = rig.session.document().ticksPerLine;
        assert(t2 > 6 && t2 <= 20);
        assert(near(rig.session.document().bpm, 125.0));
        assert(rig.session.undo());
        assert(rig.session.document().ticksPerLine == 6 && !rig.session.history().canUndo());
        rig.frame();
        assert(near(tpl.value(), 6.0));

        rig.clock.t += 1.0;
        immutable Point2F c = bar.controlRect("transport.bpm").center();
        rig.mouse(PlatformEventKind.mouseDown, c);
        rig.mouse(PlatformEventKind.mouseUp, c);
        rig.clock.t += 0.1;
        rig.mouse(PlatformEventKind.mouseDown, c);
        rig.mouse(PlatformEventKind.mouseUp, c);
        assert(bpm.isEditing());
        rig.type("140.5");
        assert(!bpm.isEditing());
        assert(near(rig.session.document().bpm, 140.5));
        assert(rig.session.undo() && near(rig.session.document().bpm, 125.0));

        assert(rig.session.doSetTempo(150.0, 8));
        rig.frame();
        assert(near(bpm.value(), 150.0) && near(tpl.value(), 8.0));
        assert(rig.session.undo());
        rig.frame();
        assert(near(bpm.value(), 125.0) && near(tpl.value(), 6.0));

        rig.render(1);
        assert(rig.ctx.telemetry.engine.bpm == 125.0);
        assert(bar.readoutText() == "0000:00  125.0 BPM");
    }

    unittest {
        TransportBarView bar;
        Rig rig = transportRig(null, bar);
        scope (exit) rig.dispose();
        auto oct = findChild!NumericDragBox(bar, "transport.octave");
        auto stp = findChild!NumericDragBox(bar, "transport.step");
        assert(near(oct.value(), 4.0) && near(stp.value(), 1.0));
        rig.drag(bar.controlRect("transport.octave"), 30.0f);
        assert(rig.ctx.editOctave > 4 && rig.ctx.editOctave <= 9);
        rig.drag(bar.controlRect("transport.octave"), -400.0f);
        assert(rig.ctx.editOctave == -1);
        rig.drag(bar.controlRect("transport.step"), 400.0f);
        assert(rig.ctx.editStep == 16);
        rig.ctx.editStep = 3;
        rig.ctx.editOctave = 2;
        rig.frame();
        assert(near(stp.value(), 3.0) && near(oct.value(), 2.0));
        assert(!rig.session.history().canUndo());
    }

    unittest {
        TransportBarView bar;
        Rig rig = transportRig(null, bar);
        scope (exit) rig.dispose();
        assert(!bar.isAnimating());
        assert(bar.meterLevel(false) == 0.0f && !bar.clipLit());

        rig.ctx.telemetry.engine.graph.masterPeakL = 0.5f;
        rig.ctx.telemetry.engine.graph.masterPeakR = 0.25f;
        rig.frame();
        assert(near(bar.meterLevel(false), 0.5f) && near(bar.meterLevel(true), 0.25f));
        assert(bar.isAnimating() && !bar.clipLit());

        rig.ctx.telemetry.engine.graph.masterPeakL = 0.0f;
        rig.ctx.telemetry.engine.graph.masterPeakR = 0.0f;
        rig.clock.t += 0.5;
        rig.frame();
        assert(near(bar.meterLevel(false), 0.5f * 0.316227766f, 1e-4));
        rig.clock.t += 0.5;
        rig.frame();
        assert(near(bar.meterLevel(false), 0.05f, 1e-4) && near(bar.meterLevel(true), 0.025f, 1e-4));
        assert(bar.isAnimating());
        rig.clock.t += 3.0;
        rig.frame();
        assert(bar.meterLevel(false) == 0.0f && bar.meterLevel(true) == 0.0f);
        assert(!bar.isAnimating());

        rig.ctx.telemetry.engine.graph.masterPeakL = 1.2f;
        rig.ctx.telemetry.engine.graph.masterClipped = true;
        rig.frame();
        assert(bar.clipLit());
        rig.ctx.telemetry.engine.graph.masterPeakL = 0.0f;
        rig.ctx.telemetry.engine.graph.masterClipped = false;
        rig.clock.t += 1.0;
        rig.frame();
        assert(bar.clipLit() && bar.isAnimating());
        rig.clock.t += 0.49;
        assert(bar.clipLit());
        rig.clock.t += 0.02;
        assert(!bar.clipLit());
        rig.clock.t += 5.0;
        rig.frame();
        assert(!bar.isAnimating());

        rig.ctx.telemetry.engine.graph.masterClipped = true;
        rig.frame();
        rig.ctx.telemetry.engine.graph.masterClipped = false;
        assert(bar.clipLit());
        rig.click(bar.controlRect("transport.clip"));
        assert(!bar.clipLit());

        rig.ctx.telemetry.engine.playing = true;
        assert(bar.isAnimating());
        rig.ctx.telemetry.engine.playing = false;
        rig.frame();
        assert(!bar.isAnimating());
    }

    unittest {
        TransportBarView bar;
        Rig rig = transportRig(null, bar);
        scope (exit) rig.dispose();
        assert(bar.dspText() == "" && bar.xrunText() == "");
        const(DrawList)* idle = rig.frame();
        immutable size_t idleCount = idle.instances.length;
        assert(idleCount > 0);
        rig.ctx.telemetry.audioRunning = true;
        rig.ctx.telemetry.audio.loadAvg = 0.25f;
        rig.ctx.telemetry.audio.loadPeak = 0.5f;
        rig.ctx.telemetry.audio.xruns = 3;
        assert(bar.isAnimating());
        const(DrawList)* busy = rig.frame();
        assert(busy.instances.length > idleCount);
        assert(bar.dspText() == "DSP 25%" && bar.xrunText() == "XR 3");
        assert(!bar.isAnimating());
        rig.ctx.telemetry.audio.loadAvg = 0.3f;
        assert(bar.isAnimating());
        rig.frame();
        assert(bar.dspText() == "DSP 30%");

        rig.ctx.telemetry.engine.currentLine = 17;
        rig.ctx.telemetry.engine.currentTick = 4;
        rig.ctx.telemetry.engine.bpm = 133.5;
        assert(bar.readoutText() == "0017:04  133.5 BPM");

        assert(!rig.session.isDirty());
        const(DrawList)* clean = rig.frame();
        immutable size_t cleanCount = clean.instances.length;
        assert(rig.session.doSetTempo(126.0, 6));
        assert(rig.session.isDirty());
        const(DrawList)* dirty = rig.frame();
        assert(dirty.instances.length == cleanCount + 1);
    }

    unittest {
        FakeAudio fake = new FakeAudio();
        fake.current = 22;
        TransportBarView bar;
        Rig rig = transportRig(fake, bar);
        scope (exit) rig.dispose();
        auto dev = findChild!Dropdown(bar, "transport.device");
        assert(dev !is null && dev.enabled);
        assert(dev.items == ["System Default", "Built-in Output", "USB Interface"]);
        assert(dev.selectedIndex == 2);
        assert(bar.midiText() == "MIDI: Keystation, Pads");

        rig.click(bar.controlRect("transport.device"));
        assert(dev.isOpen());
        rig.frame();
        auto list = dev.popup();
        rig.click(list.itemRect(1));
        assert(!dev.isOpen());
        assert(fake.selected == [11] && fake.current == 11 && dev.selectedIndex == 1);
        assert(rig.ctx.status == "Audio output: Built-in Output");

        fake.failSelect = true;
        assert(dev.select(0));
        assert(fake.selected == [11, 0]);
        assert(dev.selectedIndex == 1 && fake.current == 11);
        assert(rig.ctx.status == "Could not switch audio output to System Default");

        fake.failSelect = false;
        fake.current = 22;
        bar.refreshDevices();
        assert(dev.selectedIndex == 2);
        rig.ctx.tick();
        assert(rig.ctx.telemetry.audioRunning);
        rig.frame();
        assert(bar.dspText() == "DSP 0%");
        assert(!rig.session.history().canUndo());
    }

    unittest {
        TransportBarView bar;
        Rig rig = transportRig(null, bar);
        scope (exit) rig.dispose();
        auto dev = findChild!Dropdown(bar, "transport.device");
        assert(!dev.enabled && dev.items == ["No audio device"]);
        assert(bar.midiText() == "");
        rig.click(bar.controlRect("transport.device"));
        assert(!dev.isOpen());
        assert(dev.select(0) == false);
        bar.refreshDevices();
        rig.ctx.tick();
        assert(!rig.ctx.telemetry.audioRunning);
        const(DrawList)* dl = rig.frame();
        assert(dl.instances.length > 0);
        assert(bar.dspText() == "");
    }

    unittest {
        Rig rig = new Rig(null);
        scope (exit) rig.dispose();
        auto bar = new TransportBarView(rig.ctx);
        rig.host(bar, RectF(0, 0, 400, 40));
        const(DrawList)* dl = rig.frame();
        assert(dl.instances.length > 0);
        assert(bar.controlRect("transport.play").right() <= 400.0f);
        auto dev = findChild!Dropdown(bar, "transport.device");
        assert(!dev.visible);
        assert(bar.controlRect("transport.meters").isEmpty());
        assert(allInside(dl, RectF(0, 0, 400, 40), 2.0f, 0));
        bool sawBarClip = false;
        foreach (ref cmd; dl.commands) {
            if (cmd.scissor.w == 800 && cmd.scissor.h == 80) {
                sawBarClip = true;
            }
        }
        assert(sawBarClip);
    }

    private Rig scopeRig(out ScopeView view, RectF vp = RectF(0, 0, 520, 300)) {
        Rig rig = new Rig(null);
        view = new ScopeView(rig.ctx);
        rig.host(view, vp);
        return rig;
    }

    unittest {
        ScopeView view;
        Rig rig = scopeRig(view);
        scope (exit) rig.dispose();
        assert(view.mode() == ScopeMode.oscilloscope && view.sourceId() == 0);
        assert(findChild!Dropdown(view, "scope.source").selectedText() == "Selected module");
        assert(!view.controlRect("scope.mode").isEmpty() && !view.controlRect("scope.source").isEmpty());
        assert(!view.plotRect().isEmpty());
        assert(view.controlRect("scope.plot") == view.plotRect());
        rig.frame();
        assert(view.drawnPointCount() == 0);
        assert(!view.isAnimating());

        pushSine(rig.ctx, 0, 441.0, 0.8f, 48, 44_100.0, 0.5f);
        const(DrawList)* dl = rig.frame();
        immutable size_t pts = view.drawnPointCount();
        assert(pts >= 2 * 2 * 500);
        immutable ptrdiff_t trig = view.triggerOffset();
        assert(trig > 0);
        const(float)[] l = view.lastSnapshotLeft();
        assert(l.length == 2048);
        assert(l[trig - 1] <= 0.0f && l[trig] > 0.0f);
        assert(cast(size_t) trig + view.displayFrames <= l.length);
        immutable ulong phase0 = (rig.ctx.scopes.newestFrame(0) + 64 - l.length + trig) % 100;
        pushSine(rig.ctx, 0, 441.0, 0.8f, 1, 44_100.0, 0.5f);
        rig.frame();
        immutable ptrdiff_t trig2 = view.triggerOffset();
        assert(trig2 > 0 && trig2 != trig);
        assert((rig.ctx.scopes.newestFrame(0) + 64 - view.lastSnapshotLeft().length + trig2) % 100 == phase0);

        immutable RectF plot = view.plotRect();
        bool sawPlotClip = false;
        foreach (ref cmd; dl.commands) {
            if (cmd.scissor.x == cast(uint)(plot.x * 2.0f) && cmd.scissor.w == cast(uint)(plot.w * 2.0f)
                    && cmd.instanceCount > 0) {
                sawPlotClip = true;
            }
        }
        assert(sawPlotClip);

        rig.ctx.telemetry.engine.playing = true;
        assert(view.isAnimating());
        rig.ctx.telemetry.engine.playing = false;
        rig.ctx.telemetry.audioRunning = true;
        assert(view.isAnimating());
    }

    unittest {
        ScopeView view;
        Rig rig = scopeRig(view);
        scope (exit) rig.dispose();
        rig.click(view.controlRect("scope.mode"));
        assert(view.mode() == ScopeMode.spectrum);
        rig.frame();
        assert(view.drawnPointCount() == 0);
        pushSine(rig.ctx, 0, 1000.0, 1.0f, 40);
        const(DrawList)* dl = rig.frame();
        assert(dl.instances.length > 0);
        const(float)[] lv = view.spectrumLevels();
        immutable size_t cols = lv.length;
        assert(cols == cast(size_t) view.plotRect().w);
        assert(view.drawnPointCount() == 2 * cols);
        size_t best = 0;
        foreach (c; 0 .. cols) {
            if (lv[c] > lv[best]) {
                best = c;
            }
        }
        immutable float f = view.columnFrequency(best, cols);
        assert(f > 900.0f && f < 1100.0f);
        assert(lv[best] > -3.0f && lv[best] < 1.0f);
        assert(lv[0] < -60.0f);
        assert(near(view.columnFrequency(0, cols), 20.0f, 1e-3));
        assert(near(view.columnFrequency(cols, cols), 22_050.0f, 0.5));

        const(float)[] pk = view.spectrumPeaks();
        immutable float peakBefore = pk[best];
        assert(near(peakBefore, lv[best], 1e-4));
        foreach (b; 0 .. 40) {
            ScopeBlock silent;
            silent.sourceId = 0;
            silent.frame = rig.ctx.scopes.newestFrame(0) + 64;
            rig.ctx.scopes.push(silent);
        }
        rig.clock.t += 1.0;
        rig.frame();
        assert(view.spectrumLevels()[best] < peakBefore - 20.0f);
        assert(near(view.spectrumPeaks()[best], peakBefore - ScopeView.PEAK_DECAY_DB_PER_SEC, 1e-3));

        rig.click(view.controlRect("scope.mode"));
        assert(view.mode() == ScopeMode.goniometer);
        pushSine(rig.ctx, 0, 300.0, 0.5f, 20);
        rig.frame();
        assert(view.drawnPointCount() == view.displayFrames);
        rig.click(view.controlRect("scope.mode"));
        assert(view.mode() == ScopeMode.oscilloscope);
        view.setMode(ScopeMode.goniometer);
        assert(view.mode() == ScopeMode.goniometer);
    }

    unittest {
        ScopeView view;
        Rig rig = scopeRig(view);
        scope (exit) rig.dispose();
        immutable uint gen = rig.session.doAddModule("synth.analog_gen", "Gen");
        immutable uint gen2 = rig.session.doAddModule("synth.analog_gen", "Gen2");
        assert(gen != 0 && gen2 != 0);
        assert(rig.ctx.scopeTaps() == [0u, 0, 0, 0]);
        rig.ctx.selectModule(gen);
        rig.frame();
        assert(view.sourceId() == gen && rig.ctx.scopeTaps()[0] == gen);
        view.selectSource(0);
        assert(view.sourceId() == 0);

        auto src = findChild!Dropdown(view, "scope.source");
        rig.click(view.controlRect("scope.source"));
        assert(src.isOpen());
        rig.frame();
        rig.click(src.popup().itemRect(1));
        assert(src.selectedIndex == 1);
        assert(view.sourceId() == gen);
        assert(rig.ctx.scopeTaps()[0] == gen);

        pushSine(rig.ctx, gen, 441.0, 0.5f, 40);
        rig.frame();
        assert(view.drawnPointCount() > 0);

        rig.ctx.selectModule(gen2);
        rig.frame();
        assert(view.sourceId() == gen2);
        assert(rig.ctx.scopeTaps()[0] == gen2 && rig.ctx.scopeTaps()[1] == gen);
        assert(view.drawnPointCount() == 0);

        rig.ctx.selectModule(0);
        rig.frame();
        assert(view.sourceId() == 0);

        rig.ctx.selectModule(gen);
        view.selectSource(0);
        assert(src.selectedIndex == 0 && view.sourceId() == 0);
        rig.frame();
        assert(view.drawnPointCount() == 0);
        pushSine(rig.ctx, 0, 441.0, 0.5f, 40);
        rig.frame();
        assert(view.drawnPointCount() > 0);
    }

    unittest {
        TransportBarView bar;
        Rig rig = transportRig(null, bar);
        scope (exit) rig.dispose();
        auto num = findChild!NumericDragBox(bar, "transport.sigNum");
        auto den = findChild!Dropdown(bar, "transport.sigDen");
        assert(num !is null && den !is null);
        assert(near(num.value(), 4.0) && den.selectedText() == "4" && den.items == ["2", "4", "8", "16"]);
        assert(bar.controlRect("transport.tpl").right() < bar.controlRect("transport.sigNum").x);
        assert(bar.controlRect("transport.sigNum").right() < bar.controlRect("transport.sigDen").x);
        assert(bar.controlRect("transport.sigDen").right() < bar.controlRect("transport.octave").x);

        rig.drag(bar.controlRect("transport.sigNum"), -12.0f);
        immutable uint n2 = rig.session.timeSignatureNumerator();
        assert(n2 >= 1 && n2 < 4 && rig.session.timeSignatureDenominator() == 4);
        assert(rig.session.undo() && rig.session.timeSignatureNumerator() == 4);
        assert(!rig.session.history().canUndo());
        rig.frame();
        assert(near(num.value(), 4.0));

        rig.drag(bar.controlRect("transport.sigNum"), 400.0f);
        assert(rig.session.timeSignatureNumerator() == 16);
        assert(rig.session.undo() && !rig.session.history().canUndo());
        rig.frame();

        den.select(2);
        assert(rig.session.timeSignatureDenominator() == 8 && rig.session.linesPerBeat() == 2);
        assert(rig.session.timeSignatureNumerator() == 4);
        den.select(0);
        assert(rig.session.timeSignatureDenominator() == 2);
        assert(rig.session.undo() && rig.session.timeSignatureDenominator() == 8);
        rig.frame();
        assert(den.selectedText() == "8");
        assert(rig.session.undo() && rig.session.timeSignatureDenominator() == 4);

        assert(rig.session.doSetTimeSignature(7, 16));
        rig.frame();
        assert(near(num.value(), 7.0) && den.selectedText() == "16");
        assert(rig.session.undo());
        rig.frame();
        assert(near(num.value(), 4.0) && den.selectedText() == "4");

        rig.clock.t += 1.0;
        immutable Point2F c = bar.controlRect("transport.sigNum").center();
        rig.mouse(PlatformEventKind.mouseDown, c);
        rig.mouse(PlatformEventKind.mouseUp, c);
        rig.clock.t += 0.1;
        rig.mouse(PlatformEventKind.mouseDown, c);
        rig.mouse(PlatformEventKind.mouseUp, c);
        assert(num.isEditing());
        rig.type("6");
        assert(!num.isEditing() && rig.session.timeSignatureNumerator() == 6);
        assert(rig.session.undo());
    }
}
