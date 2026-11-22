/**
 * File:         tests/unit/views_sample_editor_test.d
 * Module:       tests.unit.views_sample_editor_test
 * Phase:        Phase 8.3 — Sample Editor View Tests
 *
 * Purpose:
 *   Drives SampleEditorView headlessly against a real StudioSession: placeholder state, sample import from WAV
 *   bytes (writeWavMemory) and through a fake IFileDialog (including failures), waveform drawing and clipping,
 *   frame <-> x mapping, loop start/end marker drags producing the expected loop frames in the reloaded blob, loop
 *   mode changes, root/low/high note fields (drag and keyboard), amplitude envelope edits, zoom (buttons, Cmd+scroll,
 *   pinch, StudioActions) and scrolling, slot switching, and undo/redo of every edit.
 *
 * Real-Time & Safety Contract:
 *   Single-threaded; no audio device. Temporary WAV files are removed via scope(exit).
 *
 * Dependencies:
 *   Internal: app.{keymap,session}, graph.registry, gui.{renderer,widgets}, gui.views.{sample_editor,studio_context},
 *             io.audio_io, modules.synths.sampler, platform.interfaces, tests.unit.views_param_rack_test (ViewRig)
 *   External: std.file, std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - class FakeDialog : IFileDialog; ubyte[] stereoWav(...); SampleSlotInfo decodeSlot(...)
 *   - version(unittest) suites
 *
 * See_Also:
 *   dev_plan.md (Phase 8.3)
 */
module tests.unit.views_sample_editor_test;

version (unittest) {
    import std.file : exists, remove, write;
    import std.math : abs, sin, PI;

    import app.keymap : StudioAction;
    import app.session : StudioSession;
    import graph.registry : ModuleRegistry;
    import gui.renderer;
    import gui.widgets;
    import gui.views.sample_editor;
    import io.audio_io : writeWavMemory;
    import modules.synths.sampler : Sampler, SamplerSlotAsset;
    import platform.interfaces : FileDialogFilter, IFileDialog, KeyModifiers, PlatformEvent, PlatformEventKind;
    import tests.unit.views_param_rack_test : ViewRig;

    /**
     * Scripted file dialog.
     */
    class FakeDialog : IFileDialog {
        string path;
        bool accept = true;
        string lastTitle;
        size_t lastFilterCount = 0;
        string[] lastExtensions;

        /**
         * Returns the scripted path.
         *
         * Params:
         *   title = Title.
         *   filters = Filters.
         *   selectedPath = Receives the path.
         *
         * Returns:
         *   accept.
         */
        override bool openFile(string title, const(FileDialogFilter)[] filters, out string selectedPath) {
            lastTitle = title;
            lastFilterCount = filters.length;
            lastExtensions = filters.length > 0 ? filters[0].extensions.dup : null;
            selectedPath = path;
            return accept;
        }

        /**
         * Unused.
         *
         * Params:
         *   title = Title.
         *   defaultName = Name.
         *   filters = Filters.
         *   selectedPath = Receives nothing.
         *
         * Returns:
         *   False.
         */
        override bool saveFile(string title, string defaultName, const(FileDialogFilter)[] filters, out string selectedPath) {
            return false;
        }
    }

    /**
     * Builds a stereo WAV: left = sine at amp, right = sine at amp / 2.
     *
     * Params:
     *   frames = Frames.
     *   amp = Amplitude.
     *
     * Returns:
     *   WAV bytes.
     */
    ubyte[] stereoWav(size_t frames, float amp) {
        float[] l = new float[frames];
        float[] r = new float[frames];
        foreach (i; 0 .. frames) {
            l[i] = amp * cast(float) sin(2.0 * PI * 220.0 * i / 44_100.0);
            r[i] = l[i] * 0.5f;
        }
        const(float)[][2] chs = [l, r];
        ubyte[] bytes;
        string err;
        assert(writeWavMemory(chs[], 44_100, bytes, err), err);
        return bytes;
    }

    /**
     * Decodes one slot of a sampler's document blob independently of the view.
     *
     * Params:
     *   s = Session.
     *   id = Sampler id.
     *   slot = Slot.
     *
     * Returns:
     *   Slot info.
     */
    SampleSlotInfo decodeSlot(StudioSession s, uint id, uint slot) {
        const(ubyte)[] blob;
        foreach (ref m; s.document().modules) {
            if (m.id == id) {
                blob = m.extraBlob;
            }
        }
        SampleSlotInfo inf;
        if (blob.length == 0) {
            return inf;
        }
        auto vt = ModuleRegistry.findByTypeId("synth.sampler").vtable;
        void* temp = vt.create();
        scope (exit) vt.destroy(temp);
        assert(vt.deserializeExtra(temp, blob, 44_100.0f));
        const(SamplerSlotAsset)* a = (cast(const(Sampler)*) temp).slotAsset(slot);
        if (a is null) {
            return inf;
        }
        inf.occupied = true;
        inf.frames = a.left.length;
        inf.rootNote = a.rootNote;
        inf.lowNote = a.lowNote;
        inf.highNote = a.highNote;
        inf.loopStart = a.loopStart;
        inf.loopEnd = a.loopEnd;
        inf.volEnv = a.volEnv;
        inf.volEnvCount = a.volEnvCount;
        inf.volSustainIdx = a.volSustainIdx;
        return inf;
    }

    private bool near(double a, double b, double eps = 1e-3) {
        return abs(a - b) <= eps;
    }

    private Widget byId(Widget root, string wid) {
        if (root.id == wid) {
            return root;
        }
        foreach (c; root.children()) {
            if (auto w = byId(c, wid)) {
                return w;
            }
        }
        return null;
    }

    private float docParam(StudioSession s, uint mod, uint idx) {
        foreach (ref m; s.document().modules) {
            if (m.id == mod) {
                return idx < m.paramValues.length ? m.paramValues[idx] : 0.0f;
            }
        }
        assert(false);
    }

    unittest {
        auto rig = new ViewRig();
        scope (exit) rig.dispose();
        auto s = rig.session;
        immutable uint gen = s.doAddModule("synth.analog_gen", "Gen");
        immutable uint smp = s.doAddModule("synth.sampler", "Smp");
        auto view = new SampleEditorView(rig.ctx);
        rig.host(view, RectF(20, 10, 560, 500));
        assert(view.samplerId() == 0 && view.waveformRect().isEmpty());
        rig.ctx.selectModule(gen);
        assert(view.waveformRect().isEmpty() && view.loopStartMarkerRect().isEmpty());
        string err;
        assert(!view.importSampleBytes(0, stereoWav(100, 0.5f), err) && err.length > 0);
        rig.assertClipped(rig.frame());
        assert(!byId(view, "sample.import").visible);

        rig.ctx.selectModule(smp);
        rig.frame();
        assert(view.samplerId() == smp && byId(view, "sample.import").visible);
        immutable RectF wf = view.waveformRect();
        assert(!wf.isEmpty() && wf.y >= rig.viewRect.y + SampleEditorView.TOOLBAR_HEIGHT);
        assert(view.loopStartMarkerRect().isEmpty());
        immutable size_t emptyInstances = rig.frame().instances.length;

        immutable size_t undo0 = s.history().undoCount();
        assert(!view.importSampleBytes(0, [cast(ubyte) 1, 2, 3, 4], err) && err.length > 0);
        assert(s.history().undoCount() == undo0);
        assert(view.importSampleBytes(0, stereoWav(4410, 0.8f), err), err);
        assert(s.history().undoCount() == undo0 + 1);
        SampleSlotInfo inf = view.slotInfo(0);
        assert(inf.occupied && inf.frames == 4410 && inf.loopStart == 0 && inf.loopEnd == 4410 && inf.rootNote == 60);
        auto slotDd = cast(Dropdown) byId(view, "sample.slot");
        assert(slotDd.items[0] == "1: 0.10s" && slotDd.items[1] == "2: empty");

        const(DrawList)* full = rig.frame();
        assert(full.instances.length > emptyInstances + cast(size_t) wf.w);
        rig.assertClipped(full);

        assert(near(view.frameToX(0), wf.x) && near(view.frameToX(4410), wf.right(), 0.01));
        assert(view.xToFrame(view.frameToX(1234)) == 1234);
        assert(view.xToFrame(wf.x - 50.0f) == 0 && view.xToFrame(wf.right() + 50.0f) == 4410);
        assert(near(view.loopStartMarkerRect().center().x, wf.x) && near(view.loopEndMarkerRect().center().x, wf.right(), 0.01));

        immutable size_t undo1 = s.history().undoCount();
        immutable Point2F ls = Point2F(view.frameToX(0) + 2.0f, wf.center().y);
        rig.drag(ls, Point2F(view.frameToX(1000), wf.center().y));
        assert(s.history().undoCount() == undo1 + 1);
        assert(decodeSlot(s, smp, 0).loopStart == 1000 && decodeSlot(s, smp, 0).loopEnd == 4410);
        assert(view.slotInfo(0).loopStart == 1000 && near(view.loopStartMarkerRect().center().x, view.frameToX(1000)));
        immutable Point2F le = Point2F(view.frameToX(4410) - 2.0f, wf.center().y);
        rig.drag(le, Point2F(view.frameToX(3000), wf.center().y));
        assert(decodeSlot(s, smp, 0).loopEnd == 3000 && decodeSlot(s, smp, 0).loopStart == 1000);
        assert(s.history().undoCount() == undo1 + 2);
        rig.drag(Point2F(view.frameToX(1000), wf.center().y), Point2F(view.frameToX(3500), wf.center().y));
        assert(decodeSlot(s, smp, 0).loopStart == 2999 && decodeSlot(s, smp, 0).loopEnd == 3000);
        assert(s.undo() && decodeSlot(s, smp, 0).loopStart == 1000);
        assert(s.undo() && decodeSlot(s, smp, 0).loopEnd == 4410);
        assert(view.slotInfo(0).loopEnd == 4410);
        assert(s.undo() && decodeSlot(s, smp, 0).loopStart == 0);
        assert(decodeSlot(s, smp, 0).frames == 4410);
        immutable size_t undoLoop = s.history().undoCount();
        rig.click(Point2F(wf.center().x, wf.center().y));
        assert(s.history().undoCount() == undoLoop);

        auto lm = cast(Dropdown) byId(view, "sample.loopMode");
        rig.click(lm.bounds.center());
        rig.click(lm.popup().itemRect(2).center());
        assert(docParam(s, smp, 4) == 2.0f && view.loopMode() == 2);
        rig.click(lm.bounds.center());
        rig.click(lm.popup().itemRect(1).center());
        assert(docParam(s, smp, 4) == 1.0f);
        assert(s.undo() && view.loopMode() == 2);
        assert(s.undo() && view.loopMode() == 0);

        auto env = view.envelopeEditor();
        assert(env.points.length == 4 && env.sustainIndex == 2 && env.enabled);
        immutable size_t undo2 = s.history().undoCount();
        immutable Point2F sp = env.toScreen(env.points[2]);
        rig.drag(sp, Point2F(sp.x, sp.y + env.plotRect().h * 0.5f));
        assert(s.history().undoCount() == undo2 + 1);
        SampleSlotInfo e1 = decodeSlot(s, smp, 0);
        assert(e1.volEnvCount == 4 && e1.volSustainIdx == 2);
        assert(near(e1.volEnv[2].value, 0.5, 0.01) && near(e1.volEnv[3].timeSec, 1.0) && near(e1.volEnv[1].value, 1.0));
        assert(near(view.envelopeEditor().points[2].y, 0.5, 0.01));
        rig.doubleClick(env.toScreen(Point2F(0.6f, 0.3f)));
        rig.frame();
        SampleSlotInfo e2 = decodeSlot(s, smp, 0);
        assert(e2.volEnvCount == 5 && near(e2.volEnv[3].timeSec, 0.6, 0.01) && near(e2.volEnv[3].value, 0.3, 0.01));
        assert(s.undo() && decodeSlot(s, smp, 0).volEnvCount == 4);
        assert(s.undo() && decodeSlot(s, smp, 0).volEnvCount == 0);
        assert(s.redo() && view.envelopeEditor().points.length == 4 && near(view.envelopeEditor().points[2].y, 0.5, 0.01));

        auto root = view.noteBox(0);
        immutable size_t undo3 = s.history().undoCount();
        immutable Point2F rc = root.bounds.center();
        rig.drag(rc, Point2F(rc.x + 40.0f, rc.y), 8);
        assert(decodeSlot(s, smp, 0).rootNote == 70);
        assert(s.history().undoCount() == undo3 + 1);
        auto low = view.noteBox(1);
        rig.click(low.bounds.center());
        assert(rig.ui.focused is low);
        PlatformEvent k;
        k.kind = PlatformEventKind.keyDown;
        k.keyCode = KeyCode.up;
        rig.ui.handleEvent(k);
        assert(decodeSlot(s, smp, 0).lowNote == 1 && s.history().undoCount() == undo3 + 2);
        auto high = view.noteBox(2);
        high.setValue(0.0f);
        SampleSlotInfo kr = decodeSlot(s, smp, 0);
        assert(kr.highNote == 0 && kr.lowNote == 0);
        assert(s.undo() && decodeSlot(s, smp, 0).highNote == 127 && decodeSlot(s, smp, 0).lowNote == 1);
        assert(s.undo() && decodeSlot(s, smp, 0).lowNote == 0);
        assert(s.undo() && decodeSlot(s, smp, 0).rootNote == 60 && view.noteBox(0).value() == 60.0f);
        rig.assertClipped(rig.frame());
    }

    unittest {
        auto rig = new ViewRig();
        scope (exit) rig.dispose();
        auto s = rig.session;
        immutable uint smp = s.doAddModule("synth.sampler", "Smp");
        auto dlg = new FakeDialog();
        rig.ctx.dialogs = dlg;
        immutable string wavPath = "/tmp/st_params_sample_editor_test.wav";
        scope (exit) {
            if (exists(wavPath)) remove(wavPath);
        }
        write(wavPath, stereoWav(8820, 0.6f));
        auto view = new SampleEditorView(rig.ctx);
        rig.host(view, RectF(20, 10, 560, 500));
        rig.ctx.selectModule(smp);
        rig.frame();

        auto slotDd = cast(Dropdown) byId(view, "sample.slot");
        rig.click(slotDd.bounds.center());
        rig.click(slotDd.popup().itemRect(2).center());
        assert(view.currentSlot() == 2);
        dlg.path = wavPath;
        rig.click(byId(view, "sample.import").bounds.center());
        assert(dlg.lastTitle == "Import Sample" && dlg.lastFilterCount == 1 && dlg.lastExtensions.length == 6);
        assert(rig.ctx.status == "Imported sample into slot 3");
        assert(view.slotInfo(2).frames == 8820 && !view.slotInfo(0).occupied && view.currentSlot() == 2);

        dlg.path = "/tmp/st_params_missing_file.wav";
        assert(!view.importPrompt());
        assert(rig.ctx.status.length > 14 && rig.ctx.status[0 .. 14] == "Import failed:");
        dlg.accept = false;
        immutable ulong sr = rig.ctx.statusRevision();
        assert(!view.importPrompt() && rig.ctx.statusRevision() == sr);
        rig.ctx.dialogs = null;
        assert(!view.importPrompt() && rig.ctx.status == "File dialogs are not available");

        string err;
        assert(view.importSampleBytes(0, stereoWav(2000, 0.9f), err), err);
        assert(view.currentSlot() == 0 && view.slotInfo(0).frames == 2000 && view.slotInfo(2).frames == 8820);
        immutable RectF wf = view.waveformRect();
        assert(near(view.frameToX(2000), wf.right(), 0.01));
        view.selectSlot(2);
        assert(near(view.frameToX(8820), wf.right(), 0.01) && near(view.framesPerPixel(), 8820.0 / wf.w));
        rig.frame();

        immutable double fit = view.framesPerPixel();
        rig.click(byId(view, "sample.zoomIn").bounds.center());
        assert(near(view.framesPerPixel(), fit / 2.0));
        assert(near(view.viewStartFrame(), 8820.0 / 4.0, 1.0));
        rig.click(byId(view, "sample.zoomOut").bounds.center());
        assert(near(view.framesPerPixel(), fit));
        rig.click(byId(view, "sample.zoomOut").bounds.center());
        assert(near(view.framesPerPixel(), fit) && near(view.viewStartFrame(), 0.0));

        assert(rig.scroll(Point2F(wf.x + 10.0f, wf.center().y), 0.0f, 25.0f, KeyModifiers.command));
        immutable double zoomed = view.framesPerPixel();
        assert(zoomed < fit * 0.7);
        assert(near(view.xToFrame(wf.x + 10.0f), cast(double)(cast(size_t)(10.0 * fit + 0.5)), 2.0));
        immutable double start0 = view.viewStartFrame();
        assert(rig.scroll(wf.center(), -30.0f, 0.0f));
        assert(near(view.viewStartFrame(), start0 + 30.0 * zoomed, 0.01));
        assert(rig.magnify(wf.center(), 1.0f));
        assert(near(view.framesPerPixel(), zoomed / 2.0));
        assert(view.handleStudioAction(StudioAction.zoomIn) && near(view.framesPerPixel(), zoomed / 4.0));
        assert(view.handleStudioAction(StudioAction.zoomOut) && near(view.framesPerPixel(), zoomed / 2.0));
        foreach (_; 0 .. 20) {
            view.zoomIn();
        }
        assert(near(view.framesPerPixel(), SampleEditorView.MIN_FRAMES_PER_PIXEL));
        rig.frame();
        rig.assertClipped(rig.frame());
        assert(view.handleStudioAction(StudioAction.zoomReset) && near(view.framesPerPixel(), fit));
        assert(!view.handleStudioAction(StudioAction.copy));

        view.zoomBy(4.0, wf.x);
        immutable size_t target = view.xToFrame(wf.x + 200.0f);
        rig.drag(Point2F(view.frameToX(0) + 1.0f, wf.center().y), Point2F(wf.x + 200.0f, wf.center().y));
        assert(decodeSlot(s, smp, 2).loopStart == target && decodeSlot(s, smp, 0).loopStart == 0);
        assert(view.currentSlot() == 2);
        immutable size_t undoN = s.history().undoCount();
        view.selectSlot(0);
        assert(near(view.framesPerPixel(), 2000.0 / wf.w) && view.slotInfo(0).loopEnd == 2000);
        assert(s.undo() && decodeSlot(s, smp, 2).loopStart == 0);
        assert(s.undo() && !decodeSlot(s, smp, 0).occupied && s.history().undoCount() == undoN - 2);
        assert(!view.slotInfo(0).occupied && view.loopStartMarkerRect().isEmpty());
        assert(view.envelopeEditorRect().w > 0.0f && !view.envelopeEditor().enabled);
        rig.frame();
        rig.ctx.selectModule(0);
        assert(view.waveformRect().isEmpty());
        rig.frame();
    }
}
