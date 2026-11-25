/**
 * File:         tests/unit/persistence_test.d
 * Module:       tests.unit.persistence_test
 * Phase:        Phase 6 — Persistence, Undo/Redo, Keymap, Session & Importer Tests
 *
 * Purpose:
 *   Verifies bounds-checked BinaryReader/BinaryWriter, bit-exact .msv/.msym WAV round-trips (including Sampler PCM, WaveShaper custom curve, unknown chunks, and MetaModule child projects), UndoHistory + StudioSession bridge, opening a project built in memory (StudioSession.openProjectFromMemory), time signature and key storage (MUSC chunk), Keymap, and SMF/XM/SunVox importers.
 *
 * Real-Time & Safety Contract:
 *   Executes RT audio quantum verification inside verifyZeroRtAllocationsNothrow and cleans up all temporary files via scope(exit).
 *
 * Dependencies:
 *   Internal: app.{history,keymap,session}, dsp.{envelope,tables}, foundation.*, io.*, modules.*, platform.interfaces, sequencer.*, tests.*
 *   External: std.file (exists, remove), std.math (fabs, isFinite, sin)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites covering Phase 6.1, 6.2, 6.3, and 6.5
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.persistence_test;

version (unittest) {
    import std.file : exists, remove;
    import std.math : fabs, isFinite, sin;

    import app.history : UndoHistory;
    import app.keymap : Keymap, StudioAction;
    import app.session : StudioSession;
    import dsp.envelope : EnvBreakpoint;
    import dsp.tables : TWO_PI_D;
    import foundation.memory : OwnedBuffer;
    import foundation.types : FIXED_BLOCK_FRAMES, ModuleId;
    import io.audio_io : writeWavMemory;
    import io.binary_stream : BinaryReader, BinaryWriter;
    import io.importers.sunvox_importer : ImportReport;
    import io.project_format : hasNonDefaultMusicSettings, KEY_MODE_MAJOR, KEY_MODE_MINOR, LoadedPreset,
        LoadedProject, loadPreset, loadProject, SavedModule, SavedPattern, SavedWire, serializePreset,
        serializeProject;
    import modules.control.metamodule : MetaMacroBinding, MetaModuleAsset;
    import modules.effects.waveshaper : WaveShaperCurveAsset;
    import modules.synths.sampler : createSamplerAssetFromMemory, SamplerSlotAsset;
    import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;
    import sequencer.engine : EngineCommand, EngineTelemetry;
    import sequencer.note : EffectCode, NoteCell, NoteCmd;
    import sequencer.timeline : TimelineClip;
    import tests.audio_harness : AudioMetrics, compareStereo;
    import tests.rt_malloc_trap : verifyZeroRtAllocationsNothrow;

    unittest {
        BinaryWriter w;
        w.writeU8(0x7F);
        w.writeU16(0xBEEF);
        w.writeU16BE(0xCAFE);
        w.writeI32(-123_456);
        w.writeU32BE(0x1234_5678u);
        w.writeF32(3.5f);
        w.writeF64(-42.25);
        w.writeFourCC("TEST");
        w.writeString("Dracker");

        BinaryWriter subW;
        subW.writeU32(99);
        subW.writeString("Nested");
        w.writeChunk("SUB1", subW.bytes());

        BinaryReader r = BinaryReader(w.bytes());
        ubyte u8v = 0;
        ushort u16l = 0, u16b = 0;
        int i32v = 0;
        uint u32b = 0;
        float f32v = 0.0f;
        double f64l = 0.0;
        char[4] tag;
        string s;
        char[4] cTag;
        BinaryReader cSub;

        assert(r.readU8(u8v) && u8v == 0x7F);
        assert(r.readU16(u16l) && u16l == 0xBEEF);
        assert(r.readU16BE(u16b) && u16b == 0xCAFE);
        assert(r.readI32(i32v) && i32v == -123_456);
        assert(r.readU32BE(u32b) && u32b == 0x1234_5678u);
        assert(r.readF32(f32v) && fabs(f32v - 3.5f) < 1e-6f);
        assert(r.readF64(f64l) && fabs(f64l + 42.25) < 1e-12);
        assert(r.readFourCC(tag) && tag == ['T', 'E', 'S', 'T']);
        assert(r.readString(64, s) && s == "Dracker");
        assert(r.readChunk(cTag, cSub) && cTag == ['S', 'U', 'B', '1']);
        uint nestedU = 0;
        string nestedS;
        assert(cSub.readU32(nestedU) && nestedU == 99);
        assert(cSub.readString(64, nestedS) && nestedS == "Nested");
        assert(cSub.atEnd() && r.atEnd());

        uint dummy = 0;
        assert(!r.readU32(dummy));

        const(ubyte)[4] vlqGood = [0x83, 0x60, 0x7F, 0x00];
        BinaryReader vr = BinaryReader(vlqGood[]);
        uint dv = 0;
        assert(vr.readMidiVlq(dv) && dv == 480);
        assert(vr.readMidiVlq(dv) && dv == 127);

        const(ubyte)[5] vlqBad = [0x80, 0x80, 0x80, 0x80, 0x00];
        BinaryReader brBad = BinaryReader(vlqBad[]);
        assert(!brBad.readMidiVlq(dv));

        BinaryWriter trunc;
        trunc.writeFourCC("HUGE");
        trunc.writeU32(0x7FFF_FFFFu);
        trunc.writeU32(1);
        BinaryReader tr = BinaryReader(trunc.bytes());
        char[4] hTag;
        BinaryReader hSub;
        assert(!tr.readChunk(hTag, hSub));
    }

    private float maxPeakStereo(const(float)[] l, const(float)[] r) @nogc nothrow pure @safe {
        float p = 0.0f;
        foreach (i; 0 .. l.length) {
            assert(isFinite(l[i]) && isFinite(r[i]));
            immutable float al = fabs(l[i]);
            immutable float ar = fabs(r[i]);
            if (al > p) p = al;
            if (ar > p) p = ar;
        }
        return p;
    }

    private ubyte[] makeTestWavBytes() {
        enum size_t FRAMES = 512;
        float[] pcm = new float[FRAMES];
        foreach (i; 0 .. FRAMES) {
            pcm[i] = 0.7f * cast(float) sin(TWO_PI_D * 440.0 * cast(double) i / 44_100.0);
        }
        const(float)[][1] chs = [pcm];
        ubyte[] wavBytes;
        string err;
        assert(writeWavMemory(chs[], 44_100, wavBytes, err));
        return wavBytes;
    }

    private LoadedProject makeNestedChildProject() {
        LoadedProject child;
        child.title = "MetaChild";
        child.author = "UnitTest";
        child.bpm = 132.0;
        child.ticksPerLine = 4;

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

        SavedPattern cPat;
        cPat.patternId = 1;
        cPat.tracks = 1;
        cPat.lines = 8;
        cPat.name = "ChildPat";
        cPat.cells = new NoteCell[8];
        cPat.cells[0] = NoteCell.makeNote(64, 0.9f, 2);
        cPat.cells[4] = NoteCell.makeNote(71, 0.85f, 2);
        child.patterns = [cPat];
        child.clips = [TimelineClip(1, 1, 0, 0, 8, 0, 0, false, false, false)];
        return child;
    }

    unittest {
        immutable string msvPath = "/tmp/dracker_phase6_test.msv";
        immutable string msymPath = "/tmp/dracker_phase6_preset.msym";
        immutable string autoPath = "/tmp/dracker_phase6_auto.msv";
        scope (exit) {
            if (exists(msvPath)) remove(msvPath);
            if (exists(msymPath)) remove(msymPath);
            if (exists(autoPath)) remove(autoPath);
        }

        StudioSession s1 = new StudioSession();
        assert(s1.initialize(44_100.0f));
        scope (exit) s1.shutdown();

        s1.doSetTempo(132.0, 4);
        immutable uint genId = s1.doAddModule("synth.analog_gen", "Lead", 100.0f, 40.0f);
        immutable uint smpId = s1.doAddModule("synth.sampler", "DrumSample", 100.0f, 160.0f);
        immutable uint wsId = s1.doAddModule("fx.waveshaper", "Shaper", 260.0f, 100.0f);
        immutable uint echoId = s1.doAddModule("fx.echo", "Echo", 400.0f, 100.0f);
        immutable uint metaId = s1.doAddModule("ctl.metamodule", "NestedSynth", 260.0f, 220.0f);
        assert(genId != 0 && smpId != 0 && wsId != 0 && echoId != 0 && metaId != 0);

        assert(s1.doConnectWire(genId, 2, wsId, 0, 0.9f));
        assert(s1.doConnectWire(smpId, 2, wsId, 0, 0.85f));
        assert(s1.doConnectWire(wsId, 1, echoId, 0, 1.0f));
        assert(s1.doConnectWire(echoId, 1, 1, 0, 1.0f));
        assert(s1.doConnectWire(metaId, 2, 1, 0, 0.6f));

        assert(s1.doSetParam(genId, 3, 5200.0f));
        assert(s1.doSetParam(wsId, 1, 0.45f));
        assert(s1.doSetParam(echoId, 1, 0.25f));
        assert(s1.doSetParam(metaId, 0, 1.0f));

        string wErr;
        SamplerSlotAsset* smpAsset = createSamplerAssetFromMemory(makeTestWavBytes(), wErr, 60);
        assert(smpAsset !is null);
        smpAsset.loopStart = 32;
        smpAsset.loopEnd = 256;
        smpAsset.volEnv[0] = EnvBreakpoint(0.0f, 0.0f, 0.0f);
        smpAsset.volEnv[1] = EnvBreakpoint(0.005f, 1.0f, 0.0f);
        smpAsset.volEnv[2] = EnvBreakpoint(0.15f, 0.7f, 0.0f);
        smpAsset.volEnvCount = 3;
        smpAsset.volSustainIdx = 1;
        s1.engine().pushCommand(EngineCommand.makeSwapModuleAsset(
            ModuleId(smpId),
            0,
            smpAsset,
            &SamplerSlotAsset.destroyErased
        ));

        float[257] customCurve;
        foreach (i; 0 .. 257) {
            immutable float x = (cast(float) i / 128.0f) - 1.0f;
            customCurve[i] = x - 0.25f * x * x * x;
        }
        WaveShaperCurveAsset* wsCurve = WaveShaperCurveAsset.createOffRT(customCurve[]);
        assert(wsCurve !is null);
        s1.engine().pushCommand(EngineCommand.makeSwapModuleAsset(
            ModuleId(wsId),
            0,
            wsCurve,
            &WaveShaperCurveAsset.destroyErased
        ));

        MetaMacroBinding[MetaModuleAsset.NUM_MACROS] macros;
        macros[0] = MetaMacroBinding(ModuleId(2), 3, 400.0f, 6000.0f, true);
        string metaErr;
        LoadedProject nestedProj = makeNestedChildProject();
        assert(s1.setMetaModuleChildProject(metaId, nestedProj, 2, macros, metaErr));

        assert(s1.doPatchCell(1, 0, 0, NoteCell.makeNote(60, 0.9f, cast(ushort) genId, EffectCode.vibrato, 0x34)));
        assert(s1.doPatchCell(1, 1, 0, NoteCell.makeNote(60, 0.85f, cast(ushort) smpId)));
        assert(s1.doPatchCell(1, 2, 2, NoteCell.makeNote(67, 0.8f, cast(ushort) genId, EffectCode.subLineDelayBase + 8, 0)));
        assert(s1.doPatchCell(1, 3, 0, NoteCell.makeNote(62, 0.7f, cast(ushort) metaId)));
        immutable uint cloneId = s1.doCloneClip(1, 64, 0);
        assert(cloneId != 0);
        assert(s1.doSetClipFlags(1, false, false, true));

        float[FIXED_BLOCK_FRAMES] drainL = 0.0f;
        float[FIXED_BLOCK_FRAMES] drainR = 0.0f;
        float[][2] drainOut = [drainL[], drainR[]];
        const(float[])[2] drainIn = [null, null];
        s1.engine().setPlaying(false);
        s1.engine().processHostBuffer(drainOut, drainIn, FIXED_BLOCK_FRAMES);

        EngineTelemetry tel;
        s1.pollRetiredAndTelemetry(tel);

        s1.engine().reset();
        s1.engine().setTempo(132.0, 4);
        s1.engine().seekLine(0);
        s1.engine().setPlaying(true);

        OwnedBuffer!float preL;
        OwnedBuffer!float preR;
        assert(s1.engine().renderOfflineToBuffer(4096, 64, preL, preR));
        assert(maxPeakStereo(preL[], preR[]) > 0.02f);

        s1.engine().setPlaying(false);
        string ioErr;
        assert(s1.saveAutosave(autoPath, ioErr));
        assert(s1.isDirty());
        assert(s1.saveProjectToFile(msvPath, ioErr));
        assert(!s1.isDirty());
        assert(s1.currentPath() == msvPath);

        ubyte[] msvBytes;
        assert(s1.saveProjectToBytes(msvBytes, ioErr));
        BinaryWriter withFutureChunk;
        withFutureChunk.writeBytes(msvBytes);
        withFutureChunk.writeFourCC("FUTR");
        withFutureChunk.writeU32(8);
        withFutureChunk.writeU32(0xDEAD_BEEFu);
        withFutureChunk.writeU32(0xCAFE_BABEu);

        StudioSession s2 = new StudioSession();
        assert(s2.initialize(44_100.0f));
        scope (exit) s2.shutdown();
        assert(s2.openProjectFile(msvPath, ioErr));
        assert(s2.currentPath() == msvPath);
        assert(!s2.isDirty());

        s2.engine().reset();
        s2.engine().setTempo(132.0, 4);
        s2.engine().seekLine(0);
        s2.engine().setPlaying(true);

        OwnedBuffer!float postL;
        OwnedBuffer!float postR;
        assert(s2.engine().renderOfflineToBuffer(4096, 64, postL, postR));

        immutable AudioMetrics cmpFile = compareStereo(preL[], preR[], postL[], postR[]);
        assert(cmpFile.bitExact());

        StudioSession s3 = new StudioSession();
        assert(s3.initialize(44_100.0f));
        scope (exit) s3.shutdown();
        assert(s3.loadProjectFromBytes(withFutureChunk.bytes(), ioErr));

        s3.engine().reset();
        s3.engine().setTempo(132.0, 4);
        s3.engine().seekLine(0);
        s3.engine().setPlaying(true);
        OwnedBuffer!float postFutL;
        OwnedBuffer!float postFutR;
        assert(s3.engine().renderOfflineToBuffer(4096, 64, postFutL, postFutR));
        immutable AudioMetrics cmpFut = compareStereo(preL[], preR[], postFutL[], postFutR[]);
        assert(cmpFut.bitExact());

        ubyte[] msymBytes;
        assert(s1.saveModulePresetToFile(wsId, "CustomShaper", msymPath, ioErr));
        assert(s1.saveModulePresetToBytes(metaId, "NestedPreset", msymBytes, ioErr));
        uint loadedWsId = 0;
        uint loadedMetaId = 0;
        LoadedPreset parsedPreset;
        assert(loadPreset(msymBytes, parsedPreset, ioErr));
        assert(parsedPreset.presetName == "NestedPreset");
        assert(parsedPreset.mod.hasChildProject);
        assert(s2.loadModulePresetFromBytes(msymBytes, 50.0f, 300.0f, loadedMetaId, ioErr));
        assert(loadedMetaId != 0);
        assert(s2.saveModulePresetToBytes(wsId, "ShaperCopy", msymBytes, ioErr));
        assert(s2.loadModulePresetFromBytes(msymBytes, 80.0f, 300.0f, loadedWsId, ioErr));
        assert(loadedWsId != 0);
    }

    private void renderSessionFromStart(StudioSession s, out OwnedBuffer!float outL, out OwnedBuffer!float outR) {
        float[FIXED_BLOCK_FRAMES] drainL = 0.0f;
        float[FIXED_BLOCK_FRAMES] drainR = 0.0f;
        float[][2] drainOut = [drainL[], drainR[]];
        const(float[])[2] drainIn = [null, null];
        s.engine().setPlaying(false);
        s.engine().processHostBuffer(drainOut, drainIn, FIXED_BLOCK_FRAMES);
        EngineTelemetry tel;
        s.pollRetiredAndTelemetry(tel);

        s.engine().reset();
        s.engine().setTempo(128.0, 4);
        s.engine().seekLine(0);
        s.engine().setPlaying(true);
        assert(s.engine().renderOfflineToBuffer(4096, 64, outL, outR));
        s.engine().setPlaying(false);
    }

    unittest {
        StudioSession src = new StudioSession();
        assert(src.initialize(44_100.0f));
        scope (exit) src.shutdown();

        src.doSetTempo(128.0, 4);
        immutable uint genA = src.doAddModule("synth.analog_gen", "Lead", 0.0f, 0.0f);
        immutable uint wsA = src.doAddModule("fx.waveshaper", "Shaper", 0.0f, 0.0f);
        immutable uint metaA = src.doAddModule("ctl.metamodule", "Nested", 0.0f, 0.0f);
        assert(genA != 0 && wsA != 0 && metaA != 0);
        assert(src.doConnectWire(genA, 2, wsA, 0, 0.9f));
        assert(src.doConnectWire(wsA, 1, 1, 0, 1.0f));
        assert(src.doConnectWire(metaA, 2, 1, 0, 0.6f));
        assert(src.doSetParam(genA, 3, 5200.0f));
        assert(src.doSetParam(wsA, 1, 0.45f));
        assert(src.doSetParam(metaA, 0, 1.0f));

        float[257] curve;
        foreach (i; 0 .. 257) {
            immutable float x = (cast(float) i / 128.0f) - 1.0f;
            curve[i] = x - 0.3f * x * x * x;
        }
        WaveShaperCurveAsset* wsCurve = WaveShaperCurveAsset.createOffRT(curve[]);
        assert(wsCurve !is null);
        src.engine().pushCommand(EngineCommand.makeSwapModuleAsset(
            ModuleId(wsA),
            0,
            wsCurve,
            &WaveShaperCurveAsset.destroyErased
        ));

        MetaMacroBinding[MetaModuleAsset.NUM_MACROS] macros;
        macros[0] = MetaMacroBinding(ModuleId(2), 3, 400.0f, 6000.0f, true);
        string err;
        LoadedProject nestedProj = makeNestedChildProject();
        assert(src.setMetaModuleChildProject(metaA, nestedProj, 2, macros, err));

        immutable NoteCell genNote = NoteCell.makeNote(57, 0.9f, cast(ushort) genA);
        immutable NoteCell metaNote = NoteCell.makeNote(62, 0.8f, cast(ushort) metaA);
        assert(src.doPatchCell(1, 0, 0, genNote));
        assert(src.doPatchCell(1, 1, 0, metaNote));

        OwnedBuffer!float refL;
        OwnedBuffer!float refR;
        renderSessionFromStart(src, refL, refR);
        assert(maxPeakStereo(refL[], refR[]) > 0.02f);

        ubyte[] wsPreset;
        ubyte[] metaPreset;
        assert(src.saveModulePresetToBytes(wsA, "ShaperPreset", wsPreset, err));
        assert(src.saveModulePresetToBytes(metaA, "MetaPreset", metaPreset, err));

        StudioSession dst = new StudioSession();
        assert(dst.initialize(44_100.0f));
        scope (exit) dst.shutdown();

        dst.doSetTempo(128.0, 4);
        immutable uint genB = dst.doAddModule("synth.analog_gen", "Lead", 0.0f, 0.0f);
        uint wsB = 0;
        uint metaB = 0;
        assert(dst.loadModulePresetFromBytes(wsPreset, 0.0f, 0.0f, wsB, err));
        assert(dst.loadModulePresetFromBytes(metaPreset, 0.0f, 0.0f, metaB, err));
        assert(genB == genA && wsB == wsA && metaB == metaA);
        assert(dst.doConnectWire(genB, 2, wsB, 0, 0.9f));
        assert(dst.doConnectWire(wsB, 1, 1, 0, 1.0f));
        assert(dst.doConnectWire(metaB, 2, 1, 0, 0.6f));
        assert(dst.doSetParam(genB, 3, 5200.0f));
        assert(dst.doPatchCell(1, 0, 0, genNote));
        assert(dst.doPatchCell(1, 1, 0, metaNote));

        OwnedBuffer!float gotL;
        OwnedBuffer!float gotR;
        renderSessionFromStart(dst, gotL, gotR);
        immutable AudioMetrics cmp = compareStereo(refL[], refR[], gotL[], gotR[]);
        assert(cmp.bitExact());

        StudioSession plain = new StudioSession();
        assert(plain.initialize(44_100.0f));
        scope (exit) plain.shutdown();
        plain.doSetTempo(128.0, 4);
        immutable uint genC = plain.doAddModule("synth.analog_gen", "Lead", 0.0f, 0.0f);
        immutable uint wsC = plain.doAddModule("fx.waveshaper", "Shaper", 0.0f, 0.0f);
        immutable uint metaC = plain.doAddModule("ctl.metamodule", "Nested", 0.0f, 0.0f);
        assert(plain.doConnectWire(genC, 2, wsC, 0, 0.9f));
        assert(plain.doConnectWire(wsC, 1, 1, 0, 1.0f));
        assert(plain.doConnectWire(metaC, 2, 1, 0, 0.6f));
        assert(plain.doSetParam(genC, 3, 5200.0f));
        assert(plain.doPatchCell(1, 0, 0, genNote));
        assert(plain.doPatchCell(1, 1, 0, metaNote));
        OwnedBuffer!float plainL;
        OwnedBuffer!float plainR;
        renderSessionFromStart(plain, plainL, plainR);
        immutable AudioMetrics cmpPlain = compareStereo(refL[], refR[], plainL[], plainR[]);
        assert(!cmpPlain.bitExact());
    }

    unittest {
        StudioSession sess = new StudioSession();
        assert(sess.initialize(44_100.0f));
        scope (exit) sess.shutdown();

        immutable uint modA = sess.doAddModule("synth.analog_gen", "OscA", 120.0f, 80.0f);
        assert(modA != 0);
        assert(sess.doConnectWire(modA, 2, 1, 0, 0.8f));
        assert(sess.document().modules.length == 2);
        assert(sess.document().wires.length == 1);

        assert(sess.doRemoveModule(modA));
        assert(sess.document().modules.length == 1);
        assert(sess.document().wires.length == 0);

        assert(sess.undo());
        assert(sess.document().modules.length == 2);
        assert(sess.document().wires.length == 1);

        assert(sess.redo());
        assert(sess.document().modules.length == 1);
        assert(sess.undo());

        assert(sess.doSetParam(modA, 3, 1200.0f));
        assert(sess.doSetParam(modA, 3, 2200.0f));
        assert(sess.doSetParam(modA, 3, 8500.0f));
        assert(fabs(sess.document().modules[1].paramValues[3] - 8500.0f) < 1e-2f);

        assert(sess.undo());
        assert(fabs(sess.document().modules[1].paramValues[3] - 4000.0f) < 1e-2f);
        assert(sess.redo());
        assert(fabs(sess.document().modules[1].paramValues[3] - 8500.0f) < 1e-2f);

        sess.history().breakCoalesce();
        assert(sess.doSetParam(modA, 3, 1800.0f));
        assert(sess.undo());
        assert(fabs(sess.document().modules[1].paramValues[3] - 8500.0f) < 1e-2f);

        assert(sess.doMoveModulePosition(modA, 150.0f, 100.0f));
        assert(sess.doMoveModulePosition(modA, 220.0f, 180.0f));
        assert(fabs(sess.document().modules[1].posX - 220.0f) < 1e-5f);
        assert(sess.undo());
        assert(fabs(sess.document().modules[1].posX - 120.0f) < 1e-5f);
        assert(sess.redo());

        assert(sess.doPatchCell(1, 0, 0, NoteCell.makeNote(60, 0.9f, cast(ushort) modA)));
        assert(sess.document().patterns[0].cells[0].midiNote() == 60);
        assert(sess.undo());
        assert(sess.document().patterns[0].cells[0].note == 0);
        assert(sess.redo());
        assert(sess.document().patterns[0].cells[0].midiNote() == 60);

        assert(sess.doResizePattern(1, 8, 32));
        assert(sess.document().patterns[0].tracks == 8);
        assert(sess.document().patterns[0].lines == 32);
        assert(sess.undo());
        assert(sess.document().patterns[0].tracks == 4);
        assert(sess.document().patterns[0].lines == 64);

        immutable uint extraClip = sess.doAddClip(1, 64, 32, 1, true);
        assert(extraClip != 0);
        assert(sess.doMoveClip(extraClip, 96, 48, 2));
        assert(sess.doSetClipFlags(extraClip, true, false, true));
        immutable uint clonedClip = sess.doCloneClip(extraClip, 160, 2);
        assert(clonedClip != 0);
        assert(sess.doRemoveClip(clonedClip));
        assert(sess.undo());
        assert(sess.document().clips.length == 3);

        sess.doSetTempo(144.0, 3);
        assert(fabs(sess.document().bpm - 144.0) < 1e-6);
        assert(sess.undo());
        assert(fabs(sess.document().bpm - 125.0) < 1e-6);

        Keymap km = Keymap.createDefault();
        ubyte noteOut = 0;
        assert(km.resolveNote(6, 4, noteOut) && noteOut == 60);
        assert(km.resolveNote(12, 4, noteOut) && noteOut == 72);
        assert(km.resolveNote(35, 4, noteOut) && noteOut == 88);
        assert(km.resolveAction(49, 0) == StudioAction.playToggle);
        assert(km.resolveAction(6, KeyModifiers.command) == StudioAction.undo);
        assert(km.resolveAction(6, KeyModifiers.command | KeyModifiers.shift) == StudioAction.redo);
        km.bindAction(StudioAction.panic, 99, KeyModifiers.alt);
        assert(km.resolveAction(99, KeyModifiers.alt) == StudioAction.panic);

        PlatformEvent keyEv;
        keyEv.kind = PlatformEventKind.keyDown;
        keyEv.keyCode = 12;
        assert(sess.handleKeyEvent(keyEv, ModuleId(modA)));

        PlatformEvent actEv;
        actEv.kind = PlatformEventKind.keyDown;
        actEv.keyCode = 120;
        assert(sess.handleKeyEvent(actEv, ModuleId(modA)));
        assert(sess.currentOctave() == 5);

        sess.engine().setPlaying(true);
        auto engPtr = sess.engine();
        float[FIXED_BLOCK_FRAMES] qL = 0.0f;
        float[FIXED_BLOCK_FRAMES] qR = 0.0f;
        float[][2] qOut = [qL[], qR[]];
        const(float[])[2] qIn = [null, null];
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            engPtr.processHostBuffer(qOut, qIn, FIXED_BLOCK_FRAMES);
        });
        assert(maxPeakStereo(qL[], qR[]) > 0.001f);

        EngineTelemetry tel;
        sess.pollRetiredAndTelemetry(tel);
        assert(tel.playing);
    }

    unittest {
        BinaryWriter midW;
        midW.writeFourCC("MThd");
        midW.writeU32BE(6);
        midW.writeU16BE(1);
        midW.writeU16BE(2);
        midW.writeU16BE(480);

        BinaryWriter t0;
        t0.writeU8(0x00);
        t0.writeU8(0xFF);
        t0.writeU8(0x51);
        t0.writeU8(0x03);
        t0.writeU8(0x07);
        t0.writeU8(0xA1);
        t0.writeU8(0x20);
        t0.writeU8(0x00);
        t0.writeU8(0x90);
        t0.writeU8(60);
        t0.writeU8(110);
        t0.writeU8(0x83);
        t0.writeU8(0x60);
        t0.writeU8(0x80);
        t0.writeU8(60);
        t0.writeU8(0);
        t0.writeU8(0x00);
        t0.writeU8(0xFF);
        t0.writeU8(0x2F);
        t0.writeU8(0x00);
        midW.writeFourCC("MTrk");
        midW.writeU32BE(cast(uint) t0.length);
        midW.writeBytes(t0.bytes());

        BinaryWriter t1;
        t1.writeU8(0x00);
        t1.writeU8(0x99);
        t1.writeU8(36);
        t1.writeU8(120);
        t1.writeU8(0x81);
        t1.writeU8(0x70);
        t1.writeU8(0x89);
        t1.writeU8(36);
        t1.writeU8(0);
        t1.writeU8(0x00);
        t1.writeU8(0xFF);
        t1.writeU8(0x2F);
        t1.writeU8(0x00);
        midW.writeFourCC("MTrk");
        midW.writeU32BE(cast(uint) t1.length);
        midW.writeBytes(t1.bytes());

        StudioSession sMid = new StudioSession();
        assert(sMid.initialize(44_100.0f));
        scope (exit) sMid.shutdown();
        string err;
        assert(sMid.importMidiBytes(midW.bytes(), err));
        sMid.engine().setPlaying(true);
        OwnedBuffer!float mL;
        OwnedBuffer!float mR;
        assert(sMid.engine().renderOfflineToBuffer(2048, 64, mL, mR));
        assert(maxPeakStereo(mL[], mR[]) > 0.01f);

        BinaryWriter xmW;
        foreach (char c; "Extended Module: ") xmW.writeU8(cast(ubyte) c);
        foreach (_; 0 .. 20) xmW.writeU8('X');
        xmW.writeU8(0x1A);
        foreach (_; 0 .. 20) xmW.writeU8('T');
        xmW.writeU16(0x0104);
        xmW.writeU32(276);
        xmW.writeU16(1);
        xmW.writeU16(0);
        xmW.writeU16(2);
        xmW.writeU16(1);
        xmW.writeU16(1);
        xmW.writeU16(1);
        xmW.writeU16(6);
        xmW.writeU16(125);
        foreach (_; 0 .. 256) xmW.writeU8(0);

        xmW.writeU32(9);
        xmW.writeU8(0);
        xmW.writeU16(4);
        xmW.writeU16(10);
        xmW.writeU8(0x83);
        xmW.writeU8(49);
        xmW.writeU8(1);
        foreach (_; 1 .. 8) xmW.writeU8(0);

        xmW.writeU32(29);
        foreach (_; 0 .. 22) xmW.writeU8('I');
        xmW.writeU8(0);
        xmW.writeU16(1);

        xmW.writeU32(256);
        xmW.writeU32(0);
        xmW.writeU32(256);
        xmW.writeU8(64);
        xmW.writeI8(0);
        xmW.writeU8(0);
        xmW.writeU8(128);
        xmW.writeU8(0);
        xmW.writeI8(0);
        foreach (_; 0 .. 22) xmW.writeU8('S');
        byte prev = 0;
        foreach (k; 0 .. 256) {
            immutable byte target = cast(byte)(60.0 * sin(TWO_PI_D * cast(double) k / 32.0));
            immutable byte delta = cast(byte)(target - prev);
            prev = target;
            xmW.writeU8(cast(ubyte) delta);
        }

        StudioSession sXm = new StudioSession();
        assert(sXm.initialize(44_100.0f));
        scope (exit) sXm.shutdown();
        assert(sXm.importXmBytes(xmW.bytes(), err));
        sXm.engine().setPlaying(true);
        OwnedBuffer!float xL;
        OwnedBuffer!float xR;
        assert(sXm.engine().renderOfflineToBuffer(2048, 64, xL, xR));
        assert(maxPeakStereo(xL[], xR[]) > 0.005f);

        BinaryWriter svW;
        svW.writeFourCC("SVOX");
        svW.writeFourCC("VERS");
        svW.writeU32(4);
        svW.writeU32(0);
        svW.writeFourCC("NAME");
        svW.writeU32(9);
        foreach (char c; "LegacySv\0") svW.writeU8(cast(ubyte) c);
        svW.writeFourCC("BPM ");
        svW.writeU32(4);
        svW.writeU32(130);
        svW.writeFourCC("SPED");
        svW.writeU32(4);
        svW.writeU32(6);

        svW.writeFourCC("STYP");
        svW.writeU32(7);
        foreach (char c; "Output\0") svW.writeU8(cast(ubyte) c);
        svW.writeFourCC("SLNK");
        svW.writeU32(4);
        svW.writeI32(-1);
        svW.writeFourCC("SEND");
        svW.writeU32(0);

        svW.writeFourCC("STYP");
        svW.writeU32(17);
        foreach (char c; "Analog generator\0") svW.writeU8(cast(ubyte) c);
        svW.writeFourCC("SLNK");
        svW.writeU32(4);
        svW.writeI32(0);
        svW.writeFourCC("SEND");
        svW.writeU32(0);

        svW.writeFourCC("STYP");
        svW.writeU32(16);
        foreach (char c; "UnknownLegacyFX\0") svW.writeU8(cast(ubyte) c);
        svW.writeFourCC("SEND");
        svW.writeU32(0);

        svW.writeFourCC("PCHN");
        svW.writeU32(4);
        svW.writeU32(1);
        svW.writeFourCC("PLIN");
        svW.writeU32(4);
        svW.writeU32(8);
        svW.writeFourCC("PDTA");
        svW.writeU32(8);
        svW.writeU8(61);
        svW.writeU8(120);
        svW.writeU8(1);
        svW.writeU8(0);
        svW.writeU16(0);
        svW.writeU16(0);
        svW.writeFourCC("PEND");
        svW.writeU32(0);

        StudioSession sSv = new StudioSession();
        assert(sSv.initialize(44_100.0f));
        scope (exit) sSv.shutdown();
        ImportReport report;
        assert(sSv.importSunvoxBytes(svW.bytes(), report, err));
        assert(report.mappedModules == 2);
        assert(report.skippedModules == 1);
        assert(report.warnings.length >= 1);

        sSv.engine().setPlaying(true);
        OwnedBuffer!float svL;
        OwnedBuffer!float svR;
        assert(sSv.engine().renderOfflineToBuffer(2048, 64, svL, svR));
        assert(maxPeakStereo(svL[], svR[]) > 0.01f);
    }

    private LoadedProject makeMemoryProject() {
        LoadedProject proj;
        proj.title = "Skeleton";
        proj.bpm = 96.0;
        proj.ticksPerLine = 6;
        SavedModule master;
        master.id = 1;
        master.typeId = "core.output";
        master.name = "Master Output";
        master.paramValues = [1.0f, 1.0f];
        SavedModule synth;
        synth.id = 2;
        synth.typeId = "synth.analog_gen";
        synth.name = "Bass";
        proj.modules = [master, synth];
        proj.wires = [SavedWire(2, 2, 1, 0, 1.0f)];
        SavedPattern pat;
        pat.patternId = 1;
        pat.tracks = 1;
        pat.lines = 16;
        pat.name = "Bass";
        pat.cells = new NoteCell[16];
        pat.cells[0] = NoteCell.makeNote(48, 0.9f, 2);
        proj.patterns = [pat];
        proj.clips = [TimelineClip(1, 1, 0, 0, 16, 0, 0, false, false, false)];
        return proj;
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string err;
        immutable uint old = s.doAddModule("synth.fm_synth", "Old", 0.0f, 0.0f);
        assert(old != 0 && s.history().canUndo());

        LoadedProject proj = makeMemoryProject();
        assert(s.openProjectFromMemory(proj, err), err);
        assert(err.length == 0);
        assert(s.document().title == "Skeleton" && s.document().bpm == 96.0);
        assert(s.document().modules.length == 2 && s.document().modules[1].name == "Bass");
        assert(s.document().wires.length == 1 && s.document().clips.length == 1);
        assert(s.document().patterns[0].cells[0].note == NoteCell.makeNote(48, 0.9f, 2).note);
        assert(s.isDirty() && s.currentPath().length == 0);
        assert(!s.history().canUndo() && !s.history().canRedo());
        assert(proj.title == "Skeleton" && proj.modules.length == 2);

        immutable uint added = s.doAddModule("synth.fm_synth", "Next", 0.0f, 0.0f);
        assert(added == 3);
        assert(s.undo());

        OwnedBuffer!float l;
        OwnedBuffer!float r;
        s.engine().reset();
        s.engine().setTempo(96.0, 6);
        s.engine().seekLine(0);
        s.engine().setPlaying(true);
        assert(s.engine().renderOfflineToBuffer(4096, 64, l, r));
        assert(maxPeakStereo(l[], r[]) > 0.01f);

        LoadedProject badTempo = makeMemoryProject();
        badTempo.title = "Bad tempo";
        badTempo.bpm = 5.0;
        assert(!s.openProjectFromMemory(badTempo, err) && err.length > 0);
        assert(s.document().title == "Skeleton" && s.document().modules.length == 2);

        LoadedProject badType = makeMemoryProject();
        badType.title = "Bad type";
        badType.modules[1].typeId = "synth.does_not_exist";
        assert(!s.openProjectFromMemory(badType, err) && err.length > 0);
        assert(s.document().title == "Skeleton" && s.document().modules.length == 2);

        LoadedProject badShape = makeMemoryProject();
        badShape.title = "Bad shape";
        badShape.patterns[0].lines = 0;
        assert(!s.openProjectFromMemory(badShape, err) && err.length > 0);
        assert(s.document().title == "Skeleton");

        LoadedProject dupIds = makeMemoryProject();
        dupIds.title = "Duplicate ids";
        dupIds.modules[1].id = 1;
        assert(!s.openProjectFromMemory(dupIds, err) && err.length > 0);
        assert(s.document().title == "Skeleton" && s.isDirty());
    }

    private bool hasChunk(const(ubyte)[] bytes, string id) {
        foreach (i; 0 .. bytes.length >= 4 ? bytes.length - 3 : 0) {
            if (bytes[i .. i + 4] == cast(const(ubyte)[]) id) {
                return true;
            }
        }
        return false;
    }

    unittest {
        string err;
        LoadedProject plain = makeMemoryProject();
        assert(plain.timeSigNumerator == 4 && plain.timeSigDenominator == 4);
        assert(plain.keyTonic == 0 && plain.keyMode == KEY_MODE_MAJOR && !hasNonDefaultMusicSettings(plain));
        ubyte[] plainBytes;
        assert(serializeProject(plain, plainBytes, err));
        assert(!hasChunk(plainBytes, "MUSC"));
        LoadedProject back;
        assert(loadProject(plainBytes, back, err));
        assert(back.timeSigNumerator == 4 && back.timeSigDenominator == 4 && back.keyTonic == 0
            && back.keyMode == KEY_MODE_MAJOR);

        LoadedProject waltz = makeMemoryProject();
        waltz.timeSigNumerator = 3;
        waltz.keyTonic = 9;
        waltz.keyMode = KEY_MODE_MINOR;
        assert(hasNonDefaultMusicSettings(waltz));
        ubyte[] waltzBytes;
        assert(serializeProject(waltz, waltzBytes, err));
        assert(hasChunk(waltzBytes, "MUSC") && waltzBytes.length == plainBytes.length + 12);
        assert(loadProject(waltzBytes, back, err));
        assert(back.timeSigNumerator == 3 && back.timeSigDenominator == 4 && back.keyTonic == 9
            && back.keyMode == KEY_MODE_MINOR);

        foreach (sig; [[1, 2], [16, 16], [6, 8], [7, 8]]) {
            LoadedProject t = makeMemoryProject();
            t.timeSigNumerator = cast(ubyte) sig[0];
            t.timeSigDenominator = cast(ubyte) sig[1];
            ubyte[] b;
            assert(serializeProject(t, b, err) && loadProject(b, back, err));
            assert(back.timeSigNumerator == sig[0] && back.timeSigDenominator == sig[1]);
        }
        foreach (bad; [[0, 4], [17, 4], [4, 0], [4, 1], [4, 3], [4, 32]]) {
            LoadedProject t = makeMemoryProject();
            t.timeSigNumerator = cast(ubyte) bad[0];
            t.timeSigDenominator = cast(ubyte) bad[1];
            ubyte[] b;
            assert(!serializeProject(t, b, err) && err == "Invalid time signature");
        }
        foreach (bad; [[12, 0], [255, 0], [0, 2]]) {
            LoadedProject t = makeMemoryProject();
            t.keyTonic = cast(ubyte) bad[0];
            t.keyMode = cast(ubyte) bad[1];
            ubyte[] b;
            assert(!serializeProject(t, b, err) && err == "Invalid song key");
        }

        BinaryWriter extended;
        extended.writeBytes(plainBytes);
        extended.writeChunk(['M', 'U', 'S', 'C'], cast(const(ubyte)[]) [cast(ubyte) 6, 8, 2, 1, 0xAA, 0xBB]);
        assert(loadProject(extended.bytes(), back, err));
        assert(back.timeSigNumerator == 6 && back.timeSigDenominator == 8 && back.keyTonic == 2 && back.keyMode == 1);

        BinaryWriter truncated;
        truncated.writeBytes(plainBytes);
        truncated.writeChunk(['M', 'U', 'S', 'C'], cast(const(ubyte)[]) [cast(ubyte) 3, 4, 0]);
        assert(!loadProject(truncated.bytes(), back, err) && err == "Truncated MUSC chunk");

        BinaryWriter badSig;
        badSig.writeBytes(plainBytes);
        badSig.writeChunk(['M', 'U', 'S', 'C'], cast(const(ubyte)[]) [cast(ubyte) 3, 5, 0, 0]);
        assert(!loadProject(badSig.bytes(), back, err) && err == "Invalid time signature in MUSC chunk");

        BinaryWriter badKey;
        badKey.writeBytes(plainBytes);
        badKey.writeChunk(['M', 'U', 'S', 'C'], cast(const(ubyte)[]) [cast(ubyte) 3, 4, 12, 0]);
        assert(!loadProject(badKey.bytes(), back, err) && err == "Invalid song key in MUSC chunk");

        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        assert(s.document().timeSigNumerator == 4 && s.document().keyMode == KEY_MODE_MAJOR);
        assert(s.loadProjectFromBytes(waltzBytes, err), err);
        assert(s.document().timeSigNumerator == 3 && s.document().keyTonic == 9);
        ubyte[] saved;
        assert(s.saveProjectToBytes(saved, err));
        assert(loadProject(saved, back, err));
        assert(back.timeSigNumerator == 3 && back.timeSigDenominator == 4 && back.keyTonic == 9
            && back.keyMode == KEY_MODE_MINOR);
        assert(s.openProjectFromMemory(waltz, err) && s.document().keyMode == KEY_MODE_MINOR);
        s.newEmptyProject(true);
        assert(s.document().timeSigNumerator == 4 && s.document().keyTonic == 0);
    }
}
