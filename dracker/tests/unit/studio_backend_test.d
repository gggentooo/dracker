/**
 * File:         tests/unit/studio_backend_test.d
 * Module:       tests.unit.studio_backend_test
 * Phase:        Phase 7.5.7 — Studio Backend Integration Tests
 *
 * Purpose:
 *   Verifies the Phase 7.5 backend headlessly: the unmanaged Engine + EngineRtContext render bridge driven through
 *   the real callback path (with live MIDI notes, MIDI-map CCs, RT -> UI MIDI copies, and DSP load) under
 *   rt_malloc_trap; MIDI learn and document mirroring; scope taps, ScopeHistory, spectra, and drop counters;
 *   transport, pattern audition, and loop range; pattern add/duplicate/remove/rename; module mute/bypass/rename/
 *   solo; live asset replacement, sample import, and waveform peaks; grouped undo atomicity; sample-rate
 *   re-initialization; the .msv MIDI chunk; and bit-exact off-thread WAV/stem export.
 *
 * Real-Time & Safety Contract:
 *   RT paths run inside verifyZeroRtAllocationsNothrow; temporary files are removed via scope(exit).
 *
 * Dependencies:
 *   Internal: app.{audio_host,history,music_theory,session,telemetry}, foundation.types, io.*, platform.interfaces,
 *             sequencer.{engine,note,timeline}, tests.rt_malloc_trap
 *   External: core.thread, std.file, std.math, std.path
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites covering Phase 7.5.1–7.5.5
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 7.5)
 */
module tests.unit.studio_backend_test;

version (unittest) {
    import core.thread : Thread;
    import core.time : dur;
    import std.file : exists, isFile, mkdirRecurse, remove, rmdirRecurse, tempDir;
    import std.math : fabs, isFinite, sin, PI;
    import std.path : buildPath;

    import app.audio_host : AudioLoadTelemetry, createEngineRtContext, destroyEngineRtContext, EngineRtContext,
        renderHostBufferRt, RtMidiSource;
    import app.history : DelegateCommand;
    import app.music_theory : KeyMode, MusicalKey;
    import app.session : ExportOptions, ExportState, MidiNoteEvent, SamplePeaks, StudioSession;
    import app.telemetry : ScopeHistory;
    import foundation.memory : OwnedBuffer;
    import foundation.types : FIXED_BLOCK_FRAMES, ModuleId;
    import graph.event : ModEvent;
    import io.audio_io : DecodedAudio, decodeAudioFile, deinterleaveToPlanar, writeWavMemory;
    import io.project_format : LoadedProject, loadProject, SavedMidiMapping, serializeProject;
    import platform.interfaces : MidiPacket;
    import sequencer.engine : Engine, EngineTelemetry, ScopeBlock;
    import sequencer.note : NoteCell;
    import tests.rt_malloc_trap : verifyZeroRtAllocationsNothrow;

    private struct TestMidiQueue {
        MidiPacket[64] items;
        size_t head = 0;
        size_t tail = 0;
    }

    private bool popTestQueue(void* ring, out MidiPacket pkt) @nogc nothrow {
        auto q = cast(TestMidiQueue*) ring;
        if (q.head == q.tail) {
            return false;
        }
        pkt = q.items[q.head++ % q.items.length];
        return true;
    }

    private ulong fakeTicks = 0;

    private ulong testNowTicks() @nogc nothrow {
        fakeTicks += 500_000;
        return fakeTicks;
    }

    private MidiPacket midi3(ubyte s, ubyte d1, ubyte d2) {
        MidiPacket p;
        p.data = [s, d1, d2];
        p.len = 3;
        return p;
    }

    private float peakOf(const(float)[] a) {
        float p = 0.0f;
        foreach (v; a) {
            assert(isFinite(v));
            immutable float x = fabs(v);
            if (x > p) p = x;
        }
        return p;
    }

    private float renderPeak(StudioSession s, size_t blocks) {
        float[256] l = 0.0f;
        float[256] r = 0.0f;
        float peak = 0.0f;
        const(float[])[2] ins = [null, null];
        foreach (_; 0 .. blocks) {
            float[][2] outs = [l[], r[]];
            s.engine().processHostBuffer(outs, ins, 256);
            immutable float p = peakOf(l[]) > peakOf(r[]) ? peakOf(l[]) : peakOf(r[]);
            if (p > peak) peak = p;
        }
        return peak;
    }

    private StudioSession makeSynthSession(out uint gen) {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        gen = s.doAddModule("synth.analog_gen", "Gen");
        assert(gen != 0 && s.doConnectWire(gen, 2, 1, 0, 1.0f));
        assert(s.synchronizeEngine());
        return s;
    }

    private ubyte[] sineWav(size_t frames, float amp) {
        float[] pcm = new float[frames];
        foreach (i; 0 .. frames) {
            pcm[i] = amp * cast(float) sin(2.0 * PI * 440.0 * i / 44_100.0);
        }
        const(float)[][1] chs = [pcm];
        ubyte[] bytes;
        string err;
        assert(writeWavMemory(chs[], 44_100, bytes, err));
        return bytes;
    }

    unittest {
        uint gen;
        StudioSession s = makeSynthSession(gen);
        scope (exit) s.dispose();

        uint[1] tapIds = [gen];
        assert(s.setScopeTaps(true, tapIds[]));
        assert(s.synchronizeEngine());
        EngineRtContext* ctx = createEngineRtContext(s.engine());
        assert(ctx !is null);
        scope (exit) destroyEngineRtContext(ctx);
        ctx.sampleRate = 44_100.0f;
        ctx.timebaseNumer = 1;
        ctx.timebaseDenom = 1;
        ctx.midiTarget.store(gen);
        TestMidiQueue* q = new TestMidiQueue();
        ctx.midiIn = cast(void*) q;
        immutable RtMidiSource src = RtMidiSource(&popTestQueue, null, &testNowTicks);

        float[128] outL = 0.0f;
        float[128] outR = 0.0f;
        float[128] inL = 0.0f;
        float[128] inR = 0.0f;
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            renderHostBufferRt(ctx, src, inL.ptr, inR.ptr, outL.ptr, outR.ptr, 128);
        });
        assert(peakOf(outL[]) < 1e-6f);

        q.items[q.tail++] = midi3(0x90, 60, 110);
        float peakOn = 0.0f;
        foreach (_; 0 .. 20) {
            verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                renderHostBufferRt(ctx, src, null, null, outL.ptr, outR.ptr, 128);
            });
            if (peakOf(outL[]) > peakOn) peakOn = peakOf(outL[]);
        }
        assert(peakOn > 0.02f);
        MidiPacket[8] copies;
        AudioLoadTelemetry load;
        assert(ctx.load.read(load));
        assert(load.callbacks == 21 && load.midiPacketsIn == 1 && load.loadAvg > 0.0f && load.bufferFrames == 128);

        size_t got = 0;
        while (got < copies.length && ctx.uiMidi.tryPop(copies[got])) got++;
        assert(got == 1 && copies[0].data1() == 60);
        ScopeHistory trapScopes = new ScopeHistory();
        assert(trapScopes.consume(s.engine()) == 2 * 21 * 2);
        assert(trapScopes.newestFrame(gen) == (21 * 128 - 64));
        assert(s.setScopeTaps(false, null));

        assert(s.doAddMidiMapping(SavedMidiMapping(0, 7, 1, 0, 0.0f, 0.5f)));
        assert(s.synchronizeEngine());
        q.items[q.tail++] = midi3(0xB0, 7, 0);
        foreach (_; 0 .. 60) {
            verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                renderHostBufferRt(ctx, src, null, null, outL.ptr, outR.ptr, 128);
            });
        }
        assert(peakOf(outL[]) < 1e-3f);

        q.items[q.tail++] = midi3(0x80, 60, 0);
        q.items[q.tail++] = midi3(0xB0, 7, 127);
        foreach (_; 0 .. 4) {
            renderHostBufferRt(ctx, src, null, null, outL.ptr, outR.ptr, 128);
        }
        MidiPacket[8] drained;
        size_t nd = 0;
        while (nd < drained.length && ctx.uiMidi.tryPop(drained[nd])) nd++;
        MidiNoteEvent[] notes;
        assert(s.processMidiFromRt(drained[0 .. nd], notes) == 2);
        assert(notes.length == 0);
        assert(fabs(s.document().modules[0].paramValues[0] - 1.0f) < 1e-5f);
        assert(s.isDirty());

        MidiPacket[2] noteAndCc = [midi3(0x93, 64, 90), midi3(0xB2, 21, 64)];
        assert(s.beginMidiLearn(gen, 3) && s.midiLearnActive());
        assert(s.processMidiFromRt(noteAndCc[], notes) == 0);
        assert(notes.length == 1 && notes[0].channel == 3 && notes[0].note == 64 && notes[0].velocity == 90);
        assert(!s.midiLearnActive());
        assert(s.document().midiMappings.length == 2);
        assert(s.document().midiMappings[1] == SavedMidiMapping(2, 21, gen, 3, 0.0f, 1.0f));
        assert(s.undo());
        assert(s.document().midiMappings.length == 1);
        assert(!s.doAddMidiMapping(SavedMidiMapping(16, 1, gen, 0, 0.0f, 1.0f)));
        assert(!s.doAddMidiMapping(SavedMidiMapping(0, 1, gen, 999, 0.0f, 1.0f)));
        assert(s.doRemoveMidiMapping(0) && s.document().midiMappings.length == 0);
        assert(!s.doRemoveMidiMapping(0));
    }

    unittest {
        uint gen;
        StudioSession s = makeSynthSession(gen);
        scope (exit) s.dispose();
        uint[1] taps = [gen];
        assert(s.setScopeTaps(true, taps[]));
        assert(s.doPatchCell(1, 0, 0, NoteCell.makeNote(57, 0.9f, cast(ushort) gen)));
        assert(s.play());
        ScopeHistory hist = new ScopeHistory(4096);
        float[64] l = 0.0f;
        float[64] r = 0.0f;
        const(float[])[2] ins = [null, null];
        float[] lastMaster;
        foreach (_; 0 .. 40) {
            float[][2] outs = [l[], r[]];
            s.engine().processHostBuffer(outs, ins, 64);
            lastMaster = l.dup;
        }
        assert(hist.consume(s.engine()) == 80);
        assert(hist.newestFrame(0) == 39 * 64 && hist.newestFrame(gen) == 39 * 64);
        assert(hist.gaps(0) == 0 && hist.gaps(gen) == 0);
        float[] sl;
        float[] sr;
        assert(hist.snapshot(0, 64, sl, sr) == 64);
        assert(sl == lastMaster);
        assert(hist.snapshot(gen, 10_000, sl, sr) == 2560);
        assert(peakOf(sl) > 0.01f);

        foreach (_; 0 .. 600) {
            float[][2] outs = [l[], r[]];
            s.engine().processHostBuffer(outs, ins, 64);
        }
        assert(s.engine().scopeBlocksDropped() > 0);
        hist.consume(s.engine());
        assert(hist.gaps(0) == 0);
        foreach (_; 0 .. 2) {
            float[][2] outs = [l[], r[]];
            s.engine().processHostBuffer(outs, ins, 64);
        }
        assert(hist.consume(s.engine()) == 4);
        assert(hist.gaps(0) == 1 && hist.gaps(gen) == 1);

        assert(s.setScopeTaps(false, null));
        foreach (_; 0 .. 4) {
            float[][2] outs = [l[], r[]];
            s.engine().processHostBuffer(outs, ins, 64);
        }
        assert(hist.consume(s.engine()) == 0);

        ScopeHistory synth = new ScopeHistory(8192);
        foreach (b; 0 .. 64) {
            ScopeBlock blk;
            blk.sourceId = 5;
            blk.frame = b * 64;
            foreach (i; 0 .. 64) {
                immutable double t = (b * 64 + i) / 44_100.0;
                blk.left[i] = cast(float) sin(2.0 * PI * 1378.125 * t);
                blk.right[i] = blk.left[i];
            }
            synth.push(blk);
        }
        float[] db;
        assert(synth.spectrum(5, 2048, db) && db.length == 1024);
        size_t best = 0;
        foreach (k; 1 .. db.length) {
            if (db[k] > db[best]) best = k;
        }
        assert(best == 64);
        assert(db[best] > -1.5f && db[best] < 0.5f);
        assert(db[300] < -40.0f);
        assert(!synth.spectrum(5, 1000, db));
        assert(!synth.spectrum(99, 2048, db));
    }

    unittest {
        uint gen;
        StudioSession s = makeSynthSession(gen);
        scope (exit) s.dispose();
        assert(s.doPatchCell(1, 0, 0, NoteCell.makeNote(57, 0.9f, cast(ushort) gen)));

        immutable uint p2 = s.doAddPattern(2, 16, "Bridge");
        assert(p2 == 2 && s.document().patterns.length == 2);
        assert(s.document().patterns[1].name == "Bridge" && s.document().patterns[1].cells.length == 32);
        assert(s.doAddPattern(0, 16) == 0 && s.doAddPattern(65, 16) == 0);
        immutable uint p3 = s.doDuplicatePattern(1);
        assert(p3 == 3 && s.document().patterns[2].cells == s.document().patterns[0].cells);
        assert(s.doRenamePattern(p3, "Verse 2") && s.document().patterns[2].name == "Verse 2");
        immutable uint clip = s.doAddClip(p3, 64, 64);
        assert(clip != 0 && s.document().clips.length == 2);
        assert(s.doRemovePattern(p3));
        assert(s.document().patterns.length == 2 && s.document().clips.length == 1);
        assert(s.undo());
        assert(s.document().patterns.length == 3 && s.document().clips.length == 2);
        assert(s.document().patterns[2].name == "Verse 2");
        assert(s.redo() && s.document().patterns.length == 2);
        assert(renderPeak(s, 2) >= 0.0f);

        assert(s.doSetLoop(4, 32));
        assert(s.document().loopStartLine == 4 && s.document().loopEndLine == 32);
        assert(!s.doSetLoop(10, 5) && !s.doSetLoop(-1, 4));
        assert(s.undo() && s.document().loopEndLine == 0);

        assert(s.playPattern(p2) && s.isAuditioningPattern());
        renderPeak(s, 2);
        assert(s.isPlaying());
        assert(s.stop());
        assert(!s.isAuditioningPattern());
        renderPeak(s, 2);
        assert(!s.isPlaying());
        assert(s.seekLine(8) && s.play());
        renderPeak(s, 1);
        assert(s.isPlaying() && s.togglePlay() == false);
        assert(!s.playPattern(999));
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.dispose();
        immutable uint a = s.doAddModule("synth.analog_gen", "A");
        immutable uint b = s.doAddModule("synth.analog_gen", "B");
        immutable uint fx = s.doAddModule("fx.waveshaper", "Shaper");
        assert(s.doConnectWire(a, 2, 1, 0, 1.0f) && s.doConnectWire(b, 2, fx, 0, 1.0f) && s.doConnectWire(fx, 1, 1, 0, 1.0f));
        assert(s.doPatchCell(1, 0, 0, NoteCell.makeNote(57, 0.9f, cast(ushort) a)));
        assert(s.doPatchCell(1, 1, 0, NoteCell.makeNote(64, 0.9f, cast(ushort) b)));
        assert(s.play());
        immutable float both = renderPeak(s, 20);
        assert(both > 0.02f);

        assert(s.doSetModuleMuted(a, true) && s.document().modules[1].muted);
        assert(s.doSetModuleMuted(b, true));
        s.engine().reset();
        s.seekLine(0);
        s.play();
        assert(renderPeak(s, 20) < 1e-4f);
        assert(s.undo() && s.undo());
        assert(!s.document().modules[1].muted && !s.document().modules[2].muted);
        assert(s.doSetModuleBypassed(fx, true) && s.document().modules[3].bypassed);
        assert(s.undo() && !s.document().modules[3].bypassed);
        assert(s.doRenameModule(a, "Lead") && s.document().modules[1].name == "Lead");
        assert(s.undo() && s.document().modules[1].name == "A");
        assert(!s.doSetModuleMuted(999, true));

        assert(s.setModuleSolo(a, true) && s.isModuleSoloed(a));
        assert(!s.isModuleEffectivelyMuted(a) && s.isModuleEffectivelyMuted(b) && !s.isModuleEffectivelyMuted(fx));
        assert(!s.isModuleEffectivelyMuted(1));
        ubyte[] bytes;
        string err;
        assert(s.saveProjectToBytes(bytes, err), err);
        LoadedProject back;
        assert(loadProject(bytes, back, err));
        assert(!back.modules[2].muted);
        assert(s.setModuleSolo(a, false) && !s.isModuleEffectivelyMuted(b));
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.dispose();
        immutable uint gen = s.doAddModule("synth.analog_gen", "Gen");
        immutable uint ws = s.doAddModule("fx.waveshaper", "Shaper");
        assert(s.doConnectWire(gen, 2, ws, 0, 1.0f) && s.doConnectWire(ws, 1, 1, 0, 1.0f));
        assert(s.doPatchCell(1, 0, 0, NoteCell.makeNote(45, 1.0f, cast(ushort) gen)));

        float[257] curve;
        foreach (i; 0 .. 257) {
            immutable float x = (cast(float) i / 128.0f) - 1.0f;
            curve[i] = x > 0.0f ? 0.1f : -0.1f;
        }
        ubyte[] blob = cast(ubyte[]) (cast(ubyte*) curve.ptr)[0 .. curve.sizeof].dup;
        assert(s.play());
        immutable float before = renderPeak(s, 30);
        assert(before > 0.15f);
        assert(s.doSetModuleExtra(ws, blob, "Edit Curve"));
        assert(s.document().modules[2].extraBlob == blob);
        immutable float after = renderPeak(s, 30);
        assert(after < 0.25f && after > 0.01f);
        assert(s.undo());
        assert(s.document().modules[2].extraBlob != blob);
        assert(renderPeak(s, 30) > 0.15f);
        assert(!s.doSetModuleExtra(gen + 100, blob));
        assert(!s.doSetModuleExtra(1, blob));

        immutable uint smp = s.doAddModule("synth.sampler", "Drums");
        assert(s.doConnectWire(smp, 2, 1, 0, 1.0f));
        string err;
        assert(s.doLoadSample(smp, 2, sineWav(4410, 0.7f), 69, 60, 80, err), err);
        SamplePeaks peaks;
        assert(s.samplePeaks(smp, 2, 100, peaks));
        assert(peaks.frames == 4410 && peaks.maxL.length == 100 && peaks.framesPerBucket == 45);
        float hi = -1.0f;
        float lo = 1.0f;
        foreach (k; 0 .. 100) {
            assert(peaks.maxL[k] >= peaks.minL[k] && peaks.maxL[k] <= 0.7001f && peaks.minL[k] >= -0.7001f);
            if (peaks.maxL[k] > hi) hi = peaks.maxL[k];
            if (peaks.minL[k] < lo) lo = peaks.minL[k];
        }
        assert(hi > 0.69f && lo < -0.69f && peaks.sampleRate == 44_100.0f);
        assert(!s.samplePeaks(smp, 3, 100, peaks));
        assert(!s.doLoadSample(smp, 99, sineWav(100, 0.5f), 60, 0, 127, err));
        assert(!s.doLoadSample(smp, 0, [1, 2, 3], 60, 0, 127, err));
        assert(s.doPatchCell(1, 1, 0, NoteCell.makeNote(69, 1.0f, cast(ushort) smp)));
        s.engine().reset();
        s.seekLine(0);
        s.play();
        assert(renderPeak(s, 10) > 0.05f);
        assert(s.undo());
        assert(s.undo());
        assert(!s.samplePeaks(smp, 2, 100, peaks));
    }

    unittest {
        uint gen;
        StudioSession s = makeSynthSession(gen);
        scope (exit) s.dispose();
        immutable size_t undoBefore = s.history().undoCount();
        s.beginEditGroup("Batch");
        assert(s.doSetParam(gen, 3, 1234.0f));
        assert(s.doPatchCell(1, 0, 0, NoteCell.makeNote(60, 0.5f, cast(ushort) gen)));
        s.beginEditGroup("Inner");
        assert(s.doRenameModule(gen, "Grouped"));
        assert(s.endEditGroup());
        assert(s.endEditGroup());
        assert(s.history().undoCount() == undoBefore + 1);
        assert(s.history().nextUndoLabel() == "Batch");
        assert(s.undo());
        assert(s.document().modules[1].name == "Gen" && s.document().patterns[0].cells[0].isEmpty());
        assert(s.document().modules[1].paramValues[3] != 1234.0f);
        assert(s.redo());
        assert(s.document().modules[1].name == "Grouped" && s.document().modules[1].paramValues[3] == 1234.0f);

        immutable size_t mid = s.history().undoCount();
        s.beginEditGroup("Failing");
        assert(s.doRenameModule(gen, "Temp"));
        assert(!s.history().pushAndExecute(new DelegateCommand("Fail", () => false, () => true), s));
        assert(!s.doRenameModule(gen, "NeverApplied"));
        assert(!s.endEditGroup());
        assert(s.document().modules[1].name == "Grouped");
        assert(s.history().undoCount() == mid);
        s.beginEditGroup("Empty");
        assert(!s.endEditGroup());
        assert(s.history().undoCount() == mid);

        NoteCell[] cells = s.document().patterns[0].cells.dup;
        foreach (ref c; cells[0 .. 16]) {
            c = NoteCell.makeNote(48, 0.7f, cast(ushort) gen);
        }
        assert(s.doReplacePatternCells(1, cells, "Paste Block"));
        assert(s.document().patterns[0].cells[15].note == cells[15].note);
        assert(!s.doReplacePatternCells(1, cells[0 .. 3]));
        assert(s.undo() && s.document().patterns[0].cells[15].isEmpty());
    }

    unittest {
        uint gen;
        StudioSession s = makeSynthSession(gen);
        scope (exit) s.dispose();
        assert(s.doSetParam(gen, 3, 2222.0f));
        assert(s.doAddMidiMapping(SavedMidiMapping(1, 74, gen, 3, 0.1f, 0.9f)));
        uint[1] taps = [gen];
        assert(s.setScopeTaps(true, taps[]));
        immutable size_t undoCount = s.history().undoCount();
        string err;
        assert(s.changeSampleRate(48_000.0f, err), err);
        assert(s.sampleRate() == 48_000.0f && s.isDirty());
        assert(s.history().undoCount() == undoCount);
        assert(s.document().modules[1].paramValues[3] == 2222.0f && s.document().midiMappings.length == 1);
        assert(s.undo() && s.document().midiMappings.length == 0);
        float[64] l = 0.0f;
        float[64] r = 0.0f;
        float[][2] outs = [l[], r[]];
        const(float[])[2] ins = [null, null];
        s.engine().processHostBuffer(outs, ins, 64);
        ScopeHistory h = new ScopeHistory();
        assert(h.consume(s.engine()) == 2);
        assert(!s.changeSampleRate(float.nan, err));

        ubyte[] bytes;
        assert(s.redo());
        assert(s.saveProjectToBytes(bytes, err), err);
        LoadedProject back;
        assert(loadProject(bytes, back, err), err);
        assert(back.midiMappings.length == 1 && back.midiMappings[0] == SavedMidiMapping(1, 74, gen, 3, 0.1f, 0.9f));
        back.midiMappings[0].min01 = float.nan;
        assert(!serializeProject(back, bytes, err));
        back.midiMappings.length = 0;
        assert(serializeProject(back, bytes, err));
        foreach (i; 0 .. bytes.length - 4) {
            assert(cast(char[]) bytes[i .. i + 4] != "MIDI");
        }
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.dispose();
        immutable uint gen = s.doAddModule("synth.analog_gen", "Gen");
        immutable uint gen2 = s.doAddModule("synth.analog_gen", "Pad");
        assert(s.doConnectWire(gen, 2, 1, 0, 0.7f) && s.doConnectWire(gen2, 2, 1, 0, 0.5f));
        assert(s.doResizePattern(1, 4, 8));
        assert(s.doPatchCell(1, 0, 0, NoteCell.makeNote(57, 0.9f, cast(ushort) gen)));
        assert(s.doPatchCell(1, 1, 4, NoteCell.makeNote(64, 0.8f, cast(ushort) gen2)));
        assert(s.doMoveClip(1, 0, 8, 0));
        assert(s.doSetLoop(0, 8));
        immutable string dir = buildPath(tempDir(), "dracker_export_test");
        mkdirRecurse(dir);
        scope (exit) rmdirRecurse(dir);
        immutable string wav = buildPath(dir, "song.wav");
        ExportOptions opt;
        opt.tailSeconds = 0.5;
        opt.stemModules = [gen, gen2];
        opt.stemDirectory = dir;
        string err;
        assert(s.beginExport(wav, opt, err), err);
        assert(!s.beginExport(wav, opt, err));
        s.waitForExport();
        auto st = s.exportStatus();
        assert(st.state == ExportState.succeeded, st.error);
        assert(st.songFrames > 0 && st.framesRendered >= st.songFrames);
        assert(exists(buildPath(dir, "stem_" ~ to!string(gen) ~ ".wav")));
        assert(exists(buildPath(dir, "stem_mix.wav")));

        DecodedAudio decoded;
        assert(decodeAudioFile(wav, decoded, err), err);
        assert(decoded.channels == 2 && decoded.frames == st.framesRendered);
        OwnedBuffer!float dl;
        OwnedBuffer!float dr;
        assert(deinterleaveToPlanar(decoded, dl, dr));

        ubyte[] bytes;
        assert(s.saveProjectToBytes(bytes, err), err);
        LoadedProject proj;
        assert(loadProject(bytes, proj, err));
        proj.loopEndLine = 0;
        assert(serializeProject(proj, bytes, err));
        StudioSession ref_ = new StudioSession();
        assert(ref_.initialize(44_100.0f));
        scope (exit) ref_.dispose();
        assert(ref_.loadProjectFromBytes(bytes, err), err);
        ref_.engine().reset();
        ref_.engine().setTempo(proj.bpm, proj.ticksPerLine);
        ref_.engine().seekLine(0);
        ref_.engine().setPlaying(true);
        OwnedBuffer!float rl;
        OwnedBuffer!float rr;
        assert(ref_.engine().renderOfflineToBuffer(cast(size_t) decoded.frames, 512, rl, rr));
        assert(dl[] == rl[] && dr[] == rr[]);
        assert(peakOf(dl[]) > 0.01f);

        opt.stemModules = null;
        opt.maxSeconds = 600.0;
        assert(s.beginExport(wav, opt, err));
        s.cancelExport();
        s.waitForExport();
        immutable auto st2 = s.exportStatus();
        assert(st2.state == ExportState.cancelled || st2.state == ExportState.succeeded);
    }

    unittest {
        uint gen;
        StudioSession s = makeSynthSession(gen);
        scope (exit) s.dispose();
        immutable uint gen2 = s.doAddModule("synth.analog_gen", "Gen2");
        assert(gen2 != 0 && s.doConnectWire(gen2, 2, 1, 0, 1.0f));
        assert(s.doSetParam(gen, 8, 0.05f));
        assert(s.synchronizeEngine());

        assert(!s.triggerLiveNote(ModuleId.invalid, Engine.PIANO_KEY_TAG_BASE | 60, 60.0f));
        assert(s.triggerLiveNote(ModuleId(gen), Engine.PIANO_KEY_TAG_BASE | 60, 60.0f, 0.85f));
        assert(s.triggerLiveNote(ModuleId(gen), 6, 64.0f, 0.85f));
        assert(renderPeak(s, 8) > 0.01f);
        assert(s.releaseLiveNote(ModuleId(gen), 6));
        assert(renderPeak(s, 4) > 0.01f);
        assert(s.releaseLiveNote(ModuleId(gen), Engine.PIANO_KEY_TAG_BASE | 60));
        cast(void) renderPeak(s, 60);
        assert(renderPeak(s, 8) < 1e-4f);

        assert(s.doPatchCell(1, 0, 0, NoteCell.makeNote(60, 0.8f, cast(ushort) gen)));
        assert(s.doPatchCell(1, 1, 0, NoteCell.makeNote(67, 0.8f, cast(ushort) gen2)));
        assert(s.doPatchCell(1, 0, 4, NoteCell.makeNoteOff()));
        assert(s.doPatchCell(1, 1, 4, NoteCell.makeNoteOff()));
        s.engine().setWatchedNoteModule(ModuleId(gen));
        assert(s.engine().watchedNoteModule() == gen);
        s.play();

        float[64] l = 0.0f;
        float[64] r = 0.0f;
        Engine* eng = s.engine();
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            float[][2] outs = [l[], r[]];
            const(float[])[2] ins = [null, null];
            eng.processHostBuffer(outs, ins, 64);
        });
        EngineTelemetry tel;
        assert(s.engine().readTelemetry(tel));
        assert(tel.isPatternNoteActive(gen, 60));
        assert(!tel.isPatternNoteActive(gen, 67) && !tel.isPatternNoteActive(gen2, 67));

        s.engine().setWatchedNoteModule(ModuleId(gen2));
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            float[][2] outs = [l[], r[]];
            const(float[])[2] ins = [null, null];
            eng.processHostBuffer(outs, ins, 64);
        });
        assert(s.engine().readTelemetry(tel));
        assert(tel.isPatternNoteActive(gen2, 67) && !tel.isPatternNoteActive(gen, 60));

        s.stop();
        s.engine().processHostBuffer([l[], r[]], [null, null], 64);
        assert(s.engine().readTelemetry(tel));
        assert(!tel.isPatternNoteActive(gen2, 67));
    }

    import std.conv : to;

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        assert(s.timeSignatureNumerator() == 4 && s.timeSignatureDenominator() == 4);
        assert(s.linesPerBeat() == 4 && s.linesPerBar() == 16);
        assert(s.songKey() == MusicalKey.init && !s.isDirty() && !s.history().canUndo());

        assert(s.doSetTimeSignature(4, 4) && !s.history().canUndo() && !s.isDirty());
        assert(s.doSetKey(MusicalKey.init) && !s.history().canUndo());

        static immutable uint[4][] shapes = [[3, 4, 4, 12], [6, 8, 2, 12], [7, 8, 2, 14], [2, 2, 8, 16],
            [5, 16, 1, 5], [16, 4, 4, 64], [1, 4, 4, 4]];
        foreach (sh; shapes) {
            assert(s.doSetTimeSignature(sh[0], sh[1]));
            assert(s.timeSignatureNumerator() == sh[0] && s.timeSignatureDenominator() == sh[1]);
            assert(s.linesPerBeat() == sh[2] && s.linesPerBar() == sh[3]);
        }
        assert(s.isDirty());
        foreach_reverse (i; 0 .. shapes.length - 1) {
            assert(s.undo());
            assert(s.timeSignatureNumerator() == shapes[i][0] && s.timeSignatureDenominator() == shapes[i][1]);
        }
        assert(s.undo() && s.timeSignatureNumerator() == 4 && s.timeSignatureDenominator() == 4);
        assert(s.redo() && s.timeSignatureNumerator() == 3);

        immutable size_t beforeBad = s.document().timeSigNumerator;
        foreach (bad; [[0, 4], [17, 4], [4, 0], [4, 3], [4, 32], [4, 1]]) {
            assert(!s.doSetTimeSignature(bad[0], bad[1]));
        }
        assert(s.timeSignatureNumerator() == beforeBad && s.timeSignatureDenominator() == 4);

        immutable MusicalKey aMinor = MusicalKey(9, KeyMode.minor);
        assert(s.doSetKey(aMinor) && s.songKey() == aMinor);
        assert(s.document().keyTonic == 9 && s.document().keyMode == 1);
        assert(s.doSetKey(MusicalKey(10, KeyMode.major)) && s.songKey().tonic == 10);
        assert(!s.doSetKey(MusicalKey(12, KeyMode.major)) && !s.doSetKey(MusicalKey(0, cast(KeyMode) 2)));
        assert(s.songKey().tonic == 10);
        assert(s.undo() && s.songKey() == aMinor);
        assert(s.undo() && s.songKey() == MusicalKey.init);
        assert(s.redo() && s.songKey() == aMinor);

        string err;
        ubyte[] bytes;
        assert(s.saveProjectToBytes(bytes, err), err);
        StudioSession t = new StudioSession();
        assert(t.initialize(44_100.0f));
        scope (exit) t.shutdown();
        assert(t.loadProjectFromBytes(bytes, err), err);
        assert(t.timeSignatureNumerator() == 3 && t.timeSignatureDenominator() == 4 && t.linesPerBar() == 12);
        assert(t.songKey() == aMinor);
        t.newEmptyProject(true);
        assert(t.linesPerBeat() == 4 && t.songKey() == MusicalKey.init);

        float[256] l = 0.0f;
        float[256] r = 0.0f;
        float[][2] outs = [l[], r[]];
        const(float[])[2] ins = [null, null];
        foreach (sig; [[4, 4, 16, 4], [6, 8, 12, 6], [2, 2, 16, 2], [3, 4, 12, 3], [1, 4, 8, 2], [7, 8, 14, 7]]) {
            StudioSession c = new StudioSession();
            assert(c.initialize(44_100.0f));
            scope (exit) c.shutdown();
            assert(c.doSetTimeSignature(sig[0], sig[1]));
            assert(c.countInBeats() == sig[3]);
            assert(c.beginLiveTake(40));
            c.engine().processHostBuffer(outs, ins, 256);
            EngineTelemetry tel;
            assert(c.engine().readTelemetry(tel) && tel.countingIn);
            assert(tel.currentLine == 40 - sig[2], to!string(tel.currentLine));
            c.endLiveTake();
        }
    }
}
