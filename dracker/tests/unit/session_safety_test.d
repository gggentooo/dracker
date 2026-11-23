/**
 * File:         tests/unit/session_safety_test.d
 * Module:       tests.unit.session_safety_test
 * Phase:        Phase 6.3 / 6.2 / 6.5 — Session RT-Boundary, Save-Validity, Undo & Importer Regression Tests
 *
 * Purpose:
 *   Regression suite for the Phase 6 review findings: plan-guarded module retirement, document-sourced
 *   saves, save/load constraint parity, Engine pattern-slot caps, driver-suspended project activation,
 *   failure-aware undo/redo, time-windowed coalescing, and SunVox note-target remapping.
 *
 * Real-Time & Safety Contract:
 *   ThreadedTestDriver renders the session Engine on a real background thread so fence synchronization,
 *   guarded retirement, and suspend-before-teardown are exercised under genuine UI/RT concurrency.
 *
 * Dependencies:
 *   Internal: app.{history,session}, foundation.types, io.{binary_stream,importers.sunvox_importer,project_format},
 *             platform.interfaces, sequencer.{engine,note,timeline}
 *   External: core.atomic, core.thread, core.time
 *
 * Planned API (Types, Functions & Hooks):
 *   - class ThreadedTestDriver : IAudioDriver
 *   - version(unittest) regression suites
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.session_safety_test;

version (unittest) {
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : dur, MonoTime;

    import app.history : IUndoCommand, SetParamCommand, UndoHistory;
    import app.session : StudioSession;
    import foundation.types : FIXED_BLOCK_FRAMES;
    import graph.module_api : ModuleInstance;
    import io.binary_stream : BinaryWriter;
    import io.importers.sunvox_importer : ImportReport, importSunvoxFile;
    import io.project_format : LoadedProject, loadProject, materializeProjectToEngine, MAX_PATTERNS,
        SavedModule, SavedPattern, serializeProject;
    import platform.interfaces : AudioDeviceInfo, AudioDriverStats, AudioNotification, AudioRenderCallback,
        AudioStreamConfig, IAudioDriver;
    import sequencer.engine : Engine, EngineTelemetry;
    import sequencer.note : NoteCell;
    import sequencer.timeline : TimelineClip;

    /**
     * Test audio driver rendering a StudioSession Engine continuously on a dedicated thread.
     */
    class ThreadedTestDriver : IAudioDriver {
        private Engine* engine_;
        private Thread worker_;
        private shared bool running_ = false;
        private shared ulong renderedBlocks_ = 0;
        uint startCount = 0;
        uint stopCount = 0;

        /**
         * Binds the driver to the Engine it will render.
         *
         * Params:
         *   eng = Engine owned by the session under test.
         */
        this(Engine* eng) {
            engine_ = eng;
        }

        /**
         * Returns no devices; the test driver is virtual.
         *
         * Returns:
         *   Empty device list.
         */
        override AudioDeviceInfo[] enumerateDevices() {
            return null;
        }

        /**
         * Accepts any configuration; rendering targets the bound Engine directly.
         *
         * Params:
         *   config = Ignored stream configuration.
         *   callback = Ignored render callback.
         *   userData = Ignored callback context.
         *
         * Returns:
         *   Always true.
         */
        override bool open(const ref AudioStreamConfig config, AudioRenderCallback callback, void* userData) {
            cast(void) config;
            cast(void) callback;
            cast(void) userData;
            return true;
        }

        /**
         * Starts the render thread.
         *
         * Returns:
         *   True once the thread is running.
         */
        override bool start() {
            if (atomicLoad(running_)) {
                return true;
            }
            atomicStore(running_, true);
            worker_ = new Thread(&renderLoop);
            worker_.start();
            startCount++;
            return true;
        }

        /**
         * Stops the render thread and joins it, guaranteeing no render is in flight on return.
         */
        override void stop() {
            if (!atomicLoad(running_)) {
                return;
            }
            atomicStore(running_, false);
            worker_.join();
            worker_ = null;
            stopCount++;
        }

        /**
         * Stops rendering.
         */
        override void close() {
            stop();
        }

        /**
         * Reports whether the render thread is active.
         *
         * Returns:
         *   True while running.
         */
        override bool isRunning() const {
            return atomicLoad(running_);
        }

        /**
         * Returns the fixed virtual sample rate.
         *
         * Returns:
         *   44100.0.
         */
        override double activeSampleRate() const {
            return 44_100.0;
        }

        /**
         * Returns the fixed virtual buffer size.
         *
         * Returns:
         *   FIXED_BLOCK_FRAMES.
         */
        override uint activeBufferFrames() const {
            return FIXED_BLOCK_FRAMES;
        }

        /**
         * Returns default statistics.
         *
         * Returns:
         *   AudioDriverStats.init.
         */
        override AudioDriverStats stats() const {
            return AudioDriverStats.init;
        }

        /**
         * Reports no notifications.
         *
         * Params:
         *   outNotif = Untouched.
         *
         * Returns:
         *   Always false.
         */
        override bool pollNotification(out AudioNotification outNotif) @nogc nothrow {
            return false;
        }

        /**
         * No-op device change handler.
         *
         * Returns:
         *   Always true.
         */
        override bool handleDeviceChange() {
            return true;
        }

        /**
         * Returns the number of 64-frame blocks rendered so far.
         *
         * Returns:
         *   Rendered block count.
         */
        ulong renderedBlocks() const {
            return atomicLoad(renderedBlocks_);
        }

        private void renderLoop() {
            float[FIXED_BLOCK_FRAMES] l = 0.0f;
            float[FIXED_BLOCK_FRAMES] r = 0.0f;
            const(float[])[2] ins = [null, null];
            while (atomicLoad(running_)) {
                float[][2] outs = [l[], r[]];
                engine_.processHostBuffer(outs, ins, FIXED_BLOCK_FRAMES);
                atomicStore(renderedBlocks_, atomicLoad(renderedBlocks_) + 1);
            }
        }
    }

    private void renderOneBlock(StudioSession s) {
        float[FIXED_BLOCK_FRAMES] l = 0.0f;
        float[FIXED_BLOCK_FRAMES] r = 0.0f;
        float[][2] outs = [l[], r[]];
        const(float[])[2] ins = [null, null];
        s.engine().processHostBuffer(outs, ins, FIXED_BLOCK_FRAMES);
    }

    private const(SavedModule)* findModule(const ref LoadedProject p, uint id) {
        foreach (ref m; p.modules) {
            if (m.id == id) return &m;
        }
        return null;
    }

    private final class RejectingCommand : IUndoCommand {
        bool executeResult = false;
        bool undoResult = false;
        uint executeCalls = 0;
        uint undoCalls = 0;

        override bool execute(StudioSession session) {
            executeCalls++;
            return executeResult;
        }

        override bool undo(StudioSession session) {
            undoCalls++;
            return undoResult;
        }

        override string label() const {
            return "Rejecting";
        }

        override bool canMergeWith(IUndoCommand next) const {
            return false;
        }

        override void mergeFrom(IUndoCommand next) {
            cast(void) next;
        }
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();

        immutable uint gen = s.doAddModule("synth.analog_gen", "Gen");
        assert(gen != 0);
        assert(s.doConnectWire(gen, 2, 1, 0, 1.0f));
        assert(s.synchronizeEngine());

        assert(s.doRemoveModule(gen));
        assert(s.pendingRetiredModuleCount() == 1);

        EngineTelemetry tel;
        s.pollRetiredAndTelemetry(tel);
        s.pollRetiredAndTelemetry(tel);
        assert(s.pendingRetiredModuleCount() == 1);

        renderOneBlock(s);
        s.pollRetiredAndTelemetry(tel);
        assert(s.pendingRetiredModuleCount() == 0);

        assert(s.undo());
        assert(s.document().modules.length == 2);
        renderOneBlock(s);
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();

        immutable uint gen = s.doAddModule("synth.analog_gen", "Gen");
        assert(s.doSetParam(gen, 3, 5200.0f));
        ubyte[] bytes;
        string err;
        assert(s.saveProjectToBytes(bytes, err), err);
        LoadedProject back;
        assert(loadProject(bytes, back, err), err);
        const(SavedModule)* m = findModule(back, gen);
        assert(m !is null);
        assert(m.paramValues[3] == 5200.0f);
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        immutable uint gen = s.doAddModule("synth.analog_gen", "Gen");
        assert(s.doConnectWire(gen, 2, 1, 0, 1.0f));

        ThreadedTestDriver drv = new ThreadedTestDriver(s.engine());
        s.attachAudioDriver(drv);
        assert(drv.start());
        scope (exit) {
            drv.stop();
            s.attachAudioDriver(null);
        }

        immutable MonoTime waitStart = MonoTime.currTime;
        while (drv.renderedBlocks() < 8 && MonoTime.currTime - waitStart < dur!"seconds"(5)) {
            Thread.sleep(dur!"msecs"(1));
        }
        assert(drv.renderedBlocks() >= 8);

        EngineTelemetry tel;
        foreach (iter; 0 .. 40) {
            immutable uint fx = s.doAddModule("fx.echo", "Echo");
            assert(fx != 0);
            assert(s.doConnectWire(gen, 2, fx, 0, 0.5f));
            assert(s.doConnectWire(fx, 1, 1, 0, 0.5f));
            assert(s.doSetParam(gen, 3, 1000.0f + iter));
            assert(s.doPatchCell(1, 0, cast(uint)(iter % 64), NoteCell.makeNote(48 + iter % 24, 0.8f, cast(ushort) gen)));
            assert(s.doRemoveModule(fx));
            s.pollRetiredAndTelemetry(tel);
        }
        assert(s.synchronizeEngine());
        assert(s.pendingRetiredModuleCount() == 0);

        ubyte[] bytes;
        string err;
        assert(s.saveProjectToBytes(bytes, err), err);
        LoadedProject back;
        assert(loadProject(bytes, back, err), err);
        assert(findModule(back, gen).paramValues[3] == 1039.0f);

        immutable uint stopsBefore = drv.stopCount;
        immutable uint startsBefore = drv.startCount;
        assert(s.loadProjectFromBytes(bytes, err), err);
        assert(drv.stopCount == stopsBefore + 1);
        assert(drv.startCount == startsBefore + 1);
        assert(drv.isRunning());

        s.newEmptyProject(true);
        assert(drv.stopCount == stopsBefore + 2);
        assert(drv.isRunning());

        immutable ulong blocksAfter = drv.renderedBlocks();
        immutable MonoTime resumeStart = MonoTime.currTime;
        while (drv.renderedBlocks() < blocksAfter + 8 && MonoTime.currTime - resumeStart < dur!"seconds"(5)) {
            Thread.sleep(dur!"msecs"(1));
        }
        assert(drv.renderedBlocks() >= blocksAfter + 8);
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        immutable uint gen = s.doAddModule("synth.analog_gen", "Gen");

        assert(!s.doSetTempo(10.0, 4));
        assert(!s.doSetTempo(120.0, 0));
        assert(!s.doSetTempo(double.nan, 4));
        assert(!s.doSetParam(gen, 0, float.nan));
        assert(!s.doSetParam(gen, 0, float.infinity));
        assert(!s.doResizePattern(1, 65, 16));
        assert(!s.doResizePattern(1, 4, 4097));
        assert(s.document().bpm == 125.0);

        assert(s.doResizePattern(1, 64, 4096));
        immutable NoteCell farCell = NoteCell.makeNote(60, 0.5f, cast(ushort) gen);
        assert(s.doPatchCell(1, 63, 4095, farCell));
        ubyte[] bytes;
        string err;
        assert(s.saveProjectToBytes(bytes, err), err);
        StudioSession s2 = new StudioSession();
        assert(s2.initialize(44_100.0f));
        scope (exit) s2.shutdown();
        assert(s2.loadProjectFromBytes(bytes, err), err);
        assert(s2.document().patterns[0].tracks == 64 && s2.document().patterns[0].lines == 4096);
        assert(s2.document().patterns[0].cells[4095 * 64 + 63] == farCell);

        LoadedProject bad;
        SavedModule outMod;
        outMod.id = 1;
        outMod.typeId = "core.output";
        outMod.paramValues = [1.0f, float.nan];
        bad.modules = [outMod];
        assert(!serializeProject(bad, bytes, err));
        bad.modules[0].paramValues = [1.0f, 1.0f];
        assert(serializeProject(bad, bytes, err), err);
        bad.ticksPerLine = 0;
        assert(!serializeProject(bad, bytes, err));
        bad.ticksPerLine = 6;
        bad.modules ~= outMod;
        bad.modules[1].paramValues = [1.0f, 1.0f];
        assert(!serializeProject(bad, bytes, err));
    }

    unittest {
        LoadedProject p;
        SavedModule outMod;
        outMod.id = 1;
        outMod.typeId = "core.output";
        outMod.paramValues = [1.0f, 1.0f];
        p.modules = [outMod];
        p.patterns = new SavedPattern[MAX_PATTERNS + 1];
        foreach (i, ref sp; p.patterns) {
            sp.patternId = cast(uint)(i + 1);
            sp.tracks = 1;
            sp.lines = 1;
            sp.cells = new NoteCell[1];
        }
        ubyte[] bytes;
        string err;
        assert(!serializeProject(p, bytes, err));

        Engine eng;
        assert(eng.tryInit(44_100.0f));
        ModuleInstance[] owned;
        assert(!materializeProjectToEngine(p, eng, 44_100.0f, owned, err));
        assert(owned.length == 0);
        eng.releaseAllOwnedResources();

        p.patterns.length = MAX_PATTERNS;
        assert(serializeProject(p, bytes, err), err);
        LoadedProject back;
        assert(loadProject(bytes, back, err), err);
        assert(eng.tryInit(44_100.0f));
        assert(materializeProjectToEngine(back, eng, 44_100.0f, owned, err), err);
        eng.releaseAllOwnedResources();
        foreach (ref inst; owned) {
            inst.destroyOffRT();
        }
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        UndoHistory h = s.history();

        immutable uint gen = s.doAddModule("synth.analog_gen", "Gen");
        assert(s.doSetParam(gen, 3, 1000.0f));
        assert(s.undo());
        assert(h.canRedo());
        immutable size_t undoBefore = h.undoCount();

        RejectingCommand rej = new RejectingCommand();
        assert(!h.pushAndExecute(rej, s));
        assert(h.undoCount() == undoBefore);
        assert(h.canRedo());

        rej.executeResult = true;
        assert(h.pushAndExecute(rej, s));
        assert(!h.canRedo());
        immutable size_t afterPush = h.undoCount();
        assert(!h.undo(s));
        assert(h.undoCount() == afterPush);
        assert(!h.canRedo());
        rej.undoResult = true;
        assert(h.undo(s));
        rej.executeResult = false;
        assert(!h.redo(s));
        assert(h.canRedo());

        h.clear();
        immutable MonoTime t0 = MonoTime.currTime;
        assert(h.pushAndExecuteAt(new SetParamCommand(gen, 3, 400.0f, 500.0f, h.currentEpoch()), s, t0));
        assert(h.pushAndExecuteAt(new SetParamCommand(gen, 3, 500.0f, 600.0f, h.currentEpoch()), s, t0 + dur!"msecs"(100)));
        assert(h.undoCount() == 1);
        assert(h.pushAndExecuteAt(new SetParamCommand(gen, 3, 600.0f, 700.0f, h.currentEpoch()), s, t0 + dur!"seconds"(5)));
        assert(h.undoCount() == 2);
        assert(s.undo());
        assert(s.document().modules[1].paramValues[3] == 600.0f);
        assert(s.undo());
        assert(s.document().modules[1].paramValues[3] == 400.0f);
    }

    private void writeSvModule(ref BinaryWriter w, string legacyType, int link) {
        w.writeFourCC("STYP");
        w.writeU32(cast(uint)(legacyType.length + 1));
        foreach (char c; legacyType) w.writeU8(cast(ubyte) c);
        w.writeU8(0);
        if (link >= -1) {
            w.writeFourCC("SLNK");
            w.writeU32(4);
            w.writeI32(link);
        }
        w.writeFourCC("SEND");
        w.writeU32(0);
    }

    unittest {
        BinaryWriter w;
        w.writeFourCC("SVOX");
        w.writeFourCC("VERS");
        w.writeU32(4);
        w.writeU32(0);
        writeSvModule(w, "Output", -1);
        writeSvModule(w, "UnknownLegacyFX", -2);
        writeSvModule(w, "Analog generator", 0);

        w.writeFourCC("PCHN");
        w.writeU32(4);
        w.writeU32(2);
        w.writeFourCC("PLIN");
        w.writeU32(4);
        w.writeU32(4);
        w.writeFourCC("PDTA");
        w.writeU32(8 * 8);
        foreach (cellIdx; 0 .. 8) {
            if (cellIdx == 0) {
                w.writeU8(61);
                w.writeU8(120);
                w.writeU8(2);
            } else if (cellIdx == 1) {
                w.writeU8(64);
                w.writeU8(120);
                w.writeU8(1);
            } else {
                w.writeU8(0);
                w.writeU8(0);
                w.writeU8(0);
            }
            w.writeU8(0);
            w.writeU16(0);
            w.writeU16(0);
        }
        w.writeFourCC("PEND");
        w.writeU32(0);

        LoadedProject p;
        ImportReport report;
        string err;
        assert(importSunvoxFile(w.bytes(), p, report, err), err);
        assert(report.skippedModules == 1);
        assert(report.droppedNoteTargets == 1);
        uint genId = 0;
        foreach (ref m; p.modules) {
            if (m.typeId == "synth.analog_gen") genId = m.id;
        }
        assert(genId == 2);
        assert(p.patterns.length == 1);
        assert(p.patterns[0].cells[0].moduleId == genId);
        assert(p.patterns[0].cells[0].note == 61);
        assert(p.patterns[0].cells[1].isEmpty());
    }
}
