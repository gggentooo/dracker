/**
 * File:         tests/unit/sequencer_test.d
 * Module:       tests.unit.sequencer_test
 * Phase:        Phase 5 — Sequencer, Timeline, Supertracks, RationalClock, Engine & MetaModule Tests
 *
 * Purpose:
 *   Verifies NoteCell/PatternSnapshot CoW & atomic patching, TimelineSnapshot clones & Supertracks, drift-free 64-bit RationalClock, all tracker EffectCodes (including sub-line delay 0x40..0x5F), unified Engine live edits & stem WAV export, and recursive MetaModule depth limits under rt_malloc_trap.
 *
 * Real-Time & Safety Contract:
 *   RT verification blocks execute inside verifyZeroRtAllocationsNothrow (rt_malloc_trap).
 *
 * Dependencies:
 *   Internal: dsp.tables, foundation.*, graph.*, io.audio_io, modules.*, sequencer.*, tests.*
 *   External: std.file (exists, remove), std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites for Phase 5.1 through 5.5
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.sequencer_test;

version (unittest) {
    import std.file : exists, remove;
    import std.math : fabs, isFinite, sin;

    import dsp.oscillator : OscWaveform;
    import dsp.tables : TWO_PI_D;
    import foundation.memory : OwnedBuffer;
    import foundation.types : FIXED_BLOCK_FRAMES, ModuleId, NoteId;
    import graph.audio_graph : AudioGraph;
    import graph.buffer : ProcessIO;
    import graph.context : ProcessContext, TransportState;
    import graph.event : ModEvent;
    import graph.module_api : ModuleInstance;
    import graph.plan : GraphCompileError, GraphCompiler, GraphPlan, NodeSpec, WireSpec;
    import graph.registry : ModuleRegistry;
    import io.audio_io : DecodedAudio, decodeAudioFile, writeWavMemory;
    import modules.control.metamodule : MAX_METAMODULE_DEPTH, MetaMacroBinding, MetaModule,
        MetaModuleAsset;
    import modules.synths.sampler : createSamplerAssetFromMemory, SamplerSlotAsset;
    import sequencer.clock : RationalClock, TickEvent;
    import sequencer.engine : Engine, EngineCommand, EngineTelemetry, StemExportSpec;
    import sequencer.note : EffectCode, NoteCell, NoteCmd;
    import sequencer.pattern : patchCellAtomic, PatternSnapshot;
    import sequencer.timeline : TimelineClip, TimelineSnapshot;
    import tests.audio_harness : AudioMetrics, assertBufferSizeInvariance, compareStereo;
    import tests.rt_malloc_trap : verifyZeroRtAllocationsNothrow;

    unittest {
        static assert(NoteCell.sizeof == 8);

        NoteCell orig = NoteCell.makeNote(60, 0.75f, 3, EffectCode.subLineDelayBase + 16, 42);
        orig.paramId = 2;
        immutable ulong packed = orig.packU64();
        immutable NoteCell unpacked = NoteCell.unpackU64(packed);
        assert(unpacked.isMidiNote() && unpacked.midiNote() == 60);
        assert(fabs(unpacked.normalizedVelocity() - 0.75f) < 0.01f);
        assert(unpacked.moduleId == 3 && unpacked.paramId == 2);
        assert(unpacked.isSubLineDelay() && unpacked.subLineDelaySteps() == 16);
        assert(unpacked.effectVal == 42);

        PatternSnapshot* p1 = PatternSnapshot.createOffRT(1, 4, 16);
        assert(p1 !is null);
        scope (exit) PatternSnapshot.destroyOffRT(p1);

        patchCellAtomic(p1, 2, 5, orig);
        immutable NoteCell readBack = p1.getCellAtomic(2, 5);
        assert(readBack.packU64() == packed);

        PatternSnapshot* p2 = PatternSnapshot.cloneAndResizeOffRT(p1, 6, 32);
        assert(p2 !is null && p2.tracks == 6 && p2.lines == 32);
        scope (exit) PatternSnapshot.destroyOffRT(p2);
        assert(p2.getCellAtomic(2, 5).packU64() == packed);
        assert(p2.getCellAtomic(5, 31).isEmpty());
    }

    unittest {
        RationalClock clock;
        clock.configure(44_100.0f, 125.0, 6);
        immutable ulong d16 = clock.subLineDelaySamples(16);
        assert(d16 == 2646);

        TickEvent[64] evs;
        ulong ticksObserved = 0;
        foreach (_; 0 .. 10_000) {
            ticksObserved += clock.advanceSlice(441, evs[]);
        }
        assert(ticksObserved == 5000);
        assert(clock.currentLine() == 833 && clock.currentTick() == 2);
        assert(clock.phaseNumerator() == 0);

        RationalClock c2;
        c2.configure(48_000.0f, 120.0, 4);
        c2.setBpm(140.0);
        c2.setTicksPerLine(3);
        c2.setLoop(2, 6);
        ulong tot = 0;
        foreach (_; 0 .. 500) {
            tot += c2.advanceSlice(96, evs[]);
        }
        assert(tot > 0 && c2.currentLine() >= 2 && c2.currentLine() < 6);
    }

    unittest {
        Engine eng;
        assert(eng.tryInit(44_100.0f));
        eng.setTempo(125.0, 6);

        ModuleInstance osc;
        ModuleInstance outMod;
        assert(ModuleRegistry.createOffRT("synth.analog_gen", ModuleId(1), 44_100.0f, osc));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(2), 44_100.0f, outMod));
        scope (exit) {
            eng.releaseAllOwnedResources();
            osc.destroyOffRT();
            outMod.destroyOffRT();
        }
        osc.desc.vtable.setParam(osc.state, 0, cast(float) OscWaveform.triangle, 44_100.0f, true);
        osc.desc.vtable.setParam(osc.state, 3, 16_000.0f, 44_100.0f, true);
        osc.desc.vtable.setParam(osc.state, 5, 0.001f, 44_100.0f, true);

        NodeSpec[2] nodes = [NodeSpec.fromInstance(osc), NodeSpec.fromInstance(outMod)];
        WireSpec[1] wires = [WireSpec(ModuleId(1), 2, ModuleId(2), 0, 1.0f)];
        GraphPlan* plan = null;
        GraphCompileError err;
        assert(GraphCompiler.compile(nodes[], wires[], plan, err));
        eng.attachPlanOffRT(plan);

        PatternSnapshot* pat1 = PatternSnapshot.createOffRT(1, 2, 16);
        assert(pat1 !is null);
        pat1.setCellAtomic(0, 0, NoteCell.makeNote(60, 1.0f, 1, EffectCode.subLineDelayBase + 16, 0));
        assert(eng.attachPatternOffRT(1, pat1));

        TimelineClip[1] clips = [TimelineClip(1, 1, 0, 0, 16, 0, 0, false, false, false)];
        TimelineSnapshot* tl = TimelineSnapshot.createOffRT(clips[], 0, 0);
        assert(tl !is null);
        eng.attachTimelineOffRT(tl);
        eng.setPlaying(true);

        OwnedBuffer!float outL;
        OwnedBuffer!float outR;
        assert(eng.renderOfflineToBuffer(4096, 64, outL, outR));

        size_t firstNonZero = size_t.max;
        foreach (i; 0 .. 4096) {
            assert(isFinite(outL[i]) && isFinite(outR[i]));
            if (firstNonZero == size_t.max && fabs(outL[i]) > 1e-6f) {
                firstNonZero = i;
            }
        }
        assert(firstNonZero == 2646);
    }

    unittest {
        Engine eng;
        assert(eng.tryInit(44_100.0f));
        eng.setTempo(125.0, 6);

        ModuleInstance oscA;
        ModuleInstance oscB;
        ModuleInstance outMod;
        assert(ModuleRegistry.createOffRT("synth.analog_gen", ModuleId(1), 44_100.0f, oscA));
        assert(ModuleRegistry.createOffRT("synth.kicker", ModuleId(2), 44_100.0f, oscB));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(3), 44_100.0f, outMod));
        scope (exit) {
            eng.releaseAllOwnedResources();
            oscA.destroyOffRT();
            oscB.destroyOffRT();
            outMod.destroyOffRT();
        }
        outMod.desc.vtable.setParam(outMod.state, 1, 0.0f, 44_100.0f, true);

        NodeSpec[3] nodes = [
            NodeSpec.fromInstance(oscA),
            NodeSpec.fromInstance(oscB),
            NodeSpec.fromInstance(outMod)
        ];
        WireSpec[2] wires = [
            WireSpec(ModuleId(1), 2, ModuleId(3), 0, 0.6f),
            WireSpec(ModuleId(2), 1, ModuleId(3), 0, 0.5f)
        ];
        GraphPlan* plan = null;
        GraphCompileError gErr;
        assert(GraphCompiler.compile(nodes[], wires[], plan, gErr));
        eng.attachPlanOffRT(plan);

        PatternSnapshot* sharedPat = PatternSnapshot.createOffRT(10, 2, 4);
        assert(sharedPat !is null);
        sharedPat.setCellAtomic(0, 0, NoteCell.makeNote(60, 0.9f, 1, EffectCode.slideUp, 4));
        sharedPat.setCellAtomic(0, 1, NoteCell.makeEffect(EffectCode.vibrato, 0x44));
        sharedPat.setCellAtomic(0, 2, NoteCell.makeEffect(EffectCode.arpeggio, 0x47));
        sharedPat.setCellAtomic(0, 3, NoteCell.makeEffect(EffectCode.velocitySlide, 0x02));
        sharedPat.setCellAtomic(1, 0, NoteCell.makeNote(48, 0.9f, 2, EffectCode.retrigger, 2));
        sharedPat.setCellAtomic(1, 1, NoteCell.makeEffect(EffectCode.noteCut, 2));
        sharedPat.setCellAtomic(1, 2, NoteCell.makeEffect(EffectCode.probabilityBase + 15, 15));
        sharedPat.setCellAtomic(1, 3, NoteCell.makeParam(1, 4, 0.8f));
        assert(eng.attachPatternOffRT(10, sharedPat));

        PatternSnapshot* superPat1 = PatternSnapshot.createOffRT(11, 1, 1);
        superPat1.setCellAtomic(0, 0, NoteCell.makeNote(57, 1.0f, 1));
        assert(eng.attachPatternOffRT(11, superPat1));

        PatternSnapshot* superPat2 = PatternSnapshot.createOffRT(12, 1, 2);
        superPat2.setCellAtomic(0, 0, NoteCell.makeNote(69, 1.0f, 0, EffectCode.portamento, 16));
        superPat2.setCellAtomic(0, 1, NoteCell.makeEffect(EffectCode.jumpLine, 0));
        assert(eng.attachPatternOffRT(12, superPat2));

        TimelineClip[4] clips = [
            TimelineClip(1, 10, 0, 0, 4, 0, 0, false, false, false),
            TimelineClip(2, 10, 1, 4, 4, 0, 0, false, false, false),
            TimelineClip(3, 11, 0, 0, 1, 1, 0, false, false, true),
            TimelineClip(4, 12, 0, 1, 3, 1, 0, false, false, true)
        ];
        TimelineSnapshot* tl = TimelineSnapshot.createOffRT(clips[], 0, 8);
        assert(tl !is null);
        eng.attachTimelineOffRT(tl);
        eng.setPlaying(true);

        float[64] oL = 0.0f;
        float[64] oR = 0.0f;
        float[][2] outs = [oL[], oR[]];
        const(float[])[2] ins = [null, null];

        assert(eng.pushCommand(EngineCommand.makePatchCell(10, 0, 0, NoteCell.makeNote(64, 0.9f, 1, EffectCode.slideUp, 2))));
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            foreach (_; 0 .. 20) {
                eng.processHostBuffer(outs, ins, 64);
            }
        });

        PatternSnapshot* resizedPat = PatternSnapshot.cloneAndResizeOffRT(sharedPat, 2, 8);
        assert(resizedPat !is null);
        assert(eng.pushCommand(EngineCommand.makeSwapPattern(10, resizedPat)));
        eng.processHostBuffer(outs, ins, 64);
        assert(eng.drainRetireRing() >= 1);

        assert(eng.pushCommand(EngineCommand.makeLiveNoteOn(ModuleId(1), 42, 72.0f, 0.8f)));
        eng.processHostBuffer(outs, ins, 64);
        assert(eng.pushCommand(EngineCommand.makeLiveNoteOff(ModuleId(1), 42)));
        eng.processHostBuffer(outs, ins, 64);

        EngineTelemetry tel;
        assert(eng.readTelemetry(tel));
        assert(tel.totalFrames > 0);
    }

    unittest {
        Engine eng;
        assert(eng.tryInit(44_100.0f));
        eng.setTempo(125.0, 2);

        float[256] wavLeft = 0.0f;
        float[256] wavRight = 0.0f;
        foreach (i; 0 .. 256) {
            wavLeft[i] = cast(float) sin(TWO_PI_D * 440.0 * cast(double) i / 44_100.0);
            wavRight[i] = wavLeft[i];
        }
        ubyte[] wavPayload;
        string err;
        const(float)[][2] chs = [wavLeft[], wavRight[]];
        assert(writeWavMemory(chs[], 44_100, wavPayload, err));
        SamplerSlotAsset* slotAsset = createSamplerAssetFromMemory(wavPayload, err, 60);
        assert(slotAsset !is null);

        ModuleInstance samp;
        ModuleInstance gen;
        ModuleInstance outMod;
        assert(ModuleRegistry.createOffRT("synth.sampler", ModuleId(1), 44_100.0f, samp));
        assert(ModuleRegistry.createOffRT("synth.analog_gen", ModuleId(2), 44_100.0f, gen));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(3), 44_100.0f, outMod));
        scope (exit) {
            eng.releaseAllOwnedResources();
            samp.destroyOffRT();
            gen.destroyOffRT();
            outMod.destroyOffRT();
        }
        void* oldSlot = null;
        assert(samp.desc.vtable.swapAsset(samp.state, 0, slotAsset, oldSlot));
        outMod.desc.vtable.setParam(outMod.state, 1, 0.0f, 44_100.0f, true);

        NodeSpec[3] nodes = [
            NodeSpec.fromInstance(samp),
            NodeSpec.fromInstance(gen),
            NodeSpec.fromInstance(outMod)
        ];
        WireSpec[2] wires = [
            WireSpec(ModuleId(1), 2, ModuleId(3), 0, 1.0f),
            WireSpec(ModuleId(2), 2, ModuleId(3), 0, 1.0f)
        ];
        GraphPlan* plan = null;
        GraphCompileError gErr;
        assert(GraphCompiler.compile(nodes[], wires[], plan, gErr));
        eng.attachPlanOffRT(plan);

        PatternSnapshot* pat = PatternSnapshot.createOffRT(1, 2, 8);
        pat.setCellAtomic(0, 0, NoteCell.makeNote(60, 0.9f, 1, EffectCode.sampleOffset, 16));
        pat.setCellAtomic(1, 0, NoteCell.makeNote(64, 0.8f, 2, EffectCode.setSpeed, 4));
        pat.setCellAtomic(1, 1, NoteCell.makeEffect(EffectCode.setBpm, 140));
        pat.setCellAtomic(1, 2, NoteCell.makeEffect(EffectCode.fineSlideUp, 8));
        pat.setCellAtomic(1, 3, NoteCell.makeEffect(EffectCode.muteModule, 1));
        pat.setCellAtomic(1, 4, NoteCell.makeEffect(EffectCode.muteModule, 0));
        pat.setCellAtomic(1, 5, NoteCell.makeEffect(EffectCode.stopSong, 0));
        assert(eng.attachPatternOffRT(1, pat));

        TimelineClip[1] clips = [TimelineClip(1, 1, 0, 0, 8, 0, 0, false, false, false)];
        TimelineSnapshot* tl = TimelineSnapshot.createOffRT(clips[], 0, 0);
        eng.attachTimelineOffRT(tl);
        eng.setPlaying(true);

        enum string mixPath = "/tmp/dracker_phase5_stem_mix.wav";
        enum string stem1Path = "/tmp/dracker_phase5_stem1.wav";
        enum string stem2Path = "/tmp/dracker_phase5_stem2.wav";
        scope (exit) {
            if (exists(mixPath)) remove(mixPath);
            if (exists(stem1Path)) remove(stem1Path);
            if (exists(stem2Path)) remove(stem2Path);
        }

        StemExportSpec[2] specs = [
            StemExportSpec(ModuleId(1), stem1Path),
            StemExportSpec(ModuleId(2), stem2Path)
        ];
        assert(eng.exportStemsWav(specs[], mixPath, 20480, err), err);
        assert(!eng.isPlaying());

        DecodedAudio decMix, decS1, decS2;
        assert(decodeAudioFile(mixPath, decMix, err));
        assert(decodeAudioFile(stem1Path, decS1, err));
        assert(decodeAudioFile(stem2Path, decS2, err));
        assert(decMix.frames == 20480 && decS1.frames == 20480 && decS2.frames == 20480);

        double peakDiff = 0.0;
        double peakMix = 0.0;
        foreach (f; 0 .. 20480) {
            immutable float mL = decMix.sampleAt(f, 0);
            immutable float sumL = decS1.sampleAt(f, 0) + decS2.sampleAt(f, 0);
            immutable double d = fabs(cast(double) mL - cast(double) sumL);
            if (d > peakDiff) peakDiff = d;
            if (fabs(cast(double) mL) > peakMix) peakMix = fabs(cast(double) mL);
        }
        assert(peakMix > 0.05 && peakDiff < 1e-4);
    }

    private MetaModuleAsset* createTestChildSynthAsset(float sampleRate, ushort oscIdValue = 1) {
        MetaModuleAsset* asset = MetaModuleAsset.createOffRT(sampleRate);
        assert(asset !is null);

        ModuleInstance osc;
        ModuleInstance outMod;
        assert(ModuleRegistry.createOffRT("synth.analog_gen", ModuleId(oscIdValue), sampleRate, osc));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(2), sampleRate, outMod));

        NodeSpec[2] nodes = [NodeSpec.fromInstance(osc), NodeSpec.fromInstance(outMod)];
        WireSpec[1] wires = [WireSpec(ModuleId(oscIdValue), 2, ModuleId(2), 0, 1.0f)];
        GraphPlan* plan = null;
        GraphCompileError err;
        assert(GraphCompiler.compile(nodes[], wires[], plan, err));

        asset.adoptModule(osc);
        asset.adoptModule(outMod);
        asset.childEngine.attachPlanOffRT(plan);
        asset.inputModuleId = ModuleId(oscIdValue);
        asset.macros[0] = MetaMacroBinding(ModuleId(oscIdValue), 3, 200.0f, 8000.0f, true);

        PatternSnapshot* pat = PatternSnapshot.createOffRT(1, 1, 4);
        pat.setCellAtomic(0, 0, NoteCell.makeNote(60, 0.9f, oscIdValue));
        pat.setCellAtomic(0, 2, NoteCell.makeNote(67, 0.9f, oscIdValue));
        asset.childEngine.attachPatternOffRT(1, pat);

        TimelineClip[1] clips = [TimelineClip(1, 1, 0, 0, 4, 0, 0, false, false, false)];
        asset.childEngine.attachTimelineOffRT(TimelineSnapshot.createOffRT(clips[], 0, 4));
        return asset;
    }

    unittest {
        ModuleInstance parentMeta;
        ModuleInstance parentOut;
        assert(ModuleRegistry.createOffRT("ctl.metamodule", ModuleId(1), 44_100.0f, parentMeta));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(2), 44_100.0f, parentOut));
        scope (exit) {
            parentMeta.destroyOffRT();
            parentOut.destroyOffRT();
        }

        MetaModuleAsset* outerAsset = MetaModuleAsset.createOffRT(44_100.0f);
        assert(outerAsset !is null);
        ModuleInstance innerMeta;
        ModuleInstance innerOut;
        assert(ModuleRegistry.createOffRT("ctl.metamodule", ModuleId(10), 44_100.0f, innerMeta));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(11), 44_100.0f, innerOut));

        MetaModuleAsset* leafAsset = createTestChildSynthAsset(44_100.0f, 1);
        void* prevInner = null;
        assert(innerMeta.desc.vtable.swapAsset(innerMeta.state, 0, leafAsset, prevInner));

        NodeSpec[2] oNodes = [NodeSpec.fromInstance(innerMeta), NodeSpec.fromInstance(innerOut)];
        WireSpec[1] oWires = [WireSpec(ModuleId(10), 2, ModuleId(11), 0, 1.0f)];
        GraphPlan* oPlan = null;
        GraphCompileError err;
        assert(GraphCompiler.compile(oNodes[], oWires[], oPlan, err));
        outerAsset.adoptModule(innerMeta);
        outerAsset.adoptModule(innerOut);
        outerAsset.childEngine.attachPlanOffRT(oPlan);
        outerAsset.inputModuleId = ModuleId(10);

        void* prevOuter = null;
        assert(parentMeta.desc.vtable.swapAsset(parentMeta.state, 0, outerAsset, prevOuter));

        parentMeta.desc.vtable.setParam(parentMeta.state, 0, 1.0f, 44_100.0f, true);
        parentMeta.desc.vtable.setParam(parentMeta.state, 3, 0.9f, 44_100.0f, true);

        float[FIXED_BLOCK_FRAMES] inL = 0.0f;
        float[FIXED_BLOCK_FRAMES] inR = 0.0f;
        float[FIXED_BLOCK_FRAMES] outL = 0.0f;
        float[FIXED_BLOCK_FRAMES] outR = 0.0f;
        ProcessIO io;
        io.audioIn = [inL[], inR[]];
        io.audioOut = [outL[], outR[]];

        ProcessContext ctx;
        ctx.sampleRate = 44_100.0f;
        ctx.frames = FIXED_BLOCK_FRAMES;
        ctx.inputSilent = true;
        ctx.transport.bpm = 138.0;
        ctx.transport.ticksPerLine = 4;
        ctx.transport.playing = true;
        ctx.metaDepth = 0;

        float peak = 0.0f;
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            foreach (_; 0 .. 4) {
                parentMeta.desc.vtable.process(parentMeta.state, io, ctx);
                foreach (s; outL) {
                    if (fabs(s) > peak) peak = fabs(s);
                }
            }
        });
        assert(peak > 0.05f);
        assert(fabs(outerAsset.childEngine.bpm() - 138.0) < 1e-6);
        assert(outerAsset.childEngine.ticksPerLine() == 4);
        assert(fabs(leafAsset.childEngine.bpm() - 138.0) < 1e-6);
        assert(leafAsset.childEngine.ticksPerLine() == 4);

        ctx.metaDepth = MAX_METAMODULE_DEPTH;
        assert(!parentMeta.desc.vtable.process(parentMeta.state, io, ctx));
        foreach (s; outL) {
            assert(s == 0.0f);
        }

        ubyte[] metaBlob;
        assert(parentMeta.desc.vtable.serializeExtra(parentMeta.state, metaBlob) && metaBlob.length > 0);
        assert(parentMeta.desc.vtable.deserializeExtra(parentMeta.state, metaBlob, 44_100.0f));
    }

    unittest {
        Engine eng;
        assert(eng.tryInit(44_100.0f));
        scope (exit) eng.releaseAllOwnedResources();
        eng.setTempo(125.0, 6);
        enum size_t lineFrames = 5292;
        enum size_t total = 18 * lineFrames;
        float[] mono = new float[total + 64];
        float[64] bl = 0.0f;
        float[64] br = 0.0f;
        float[][2] outs = [bl[], br[]];
        const(float[])[2] ins = [null, null];
        EngineTelemetry tel;

        assert(eng.pushCommand(EngineCommand.makePlayCountIn(0, 16, 4)));
        eng.processHostBuffer(outs, ins, 64);
        assert(eng.readTelemetry(tel) && tel.playing && tel.countingIn && tel.currentLine == -16);
        mono[0 .. 64] = bl[];
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            size_t pos = 64;
            while (pos < total) {
                eng.processHostBuffer(outs, ins, 64);
                mono[pos .. pos + 64] = bl[];
                pos += 64;
            }
        });
        assert(eng.countInClicks() == 4 && !eng.isCountingIn() && eng.isPlaying());
        assert(eng.readTelemetry(tel) && !tel.countingIn && tel.currentLine >= 1);

        size_t[] onsets;
        size_t lastLoud = 0;
        bool any = false;
        foreach (i; 0 .. total) {
            if (fabs(mono[i]) > 1.0e-3f) {
                if (!any || i - lastLoud > 2000) {
                    onsets ~= i;
                }
                lastLoud = i;
                any = true;
            }
        }
        assert(onsets.length == 4);
        foreach (k, o; onsets) {
            immutable size_t expected = k * 4 * lineFrames;
            assert(o >= expected && o <= expected + 2);
        }
        float peak0 = 0.0f;
        float peak1 = 0.0f;
        foreach (i; 0 .. 2000) {
            peak0 = fabs(mono[i]) > peak0 ? fabs(mono[i]) : peak0;
            peak1 = fabs(mono[onsets[1] + i]) > peak1 ? fabs(mono[onsets[1] + i]) : peak1;
        }
        assert(peak0 > peak1 * 1.2f && peak0 < 0.4f);
        assert(lastLoud < 13 * lineFrames);
        foreach (i; 16 * lineFrames .. total) {
            assert(mono[i] == 0.0f);
        }

        assert(eng.pushCommand(EngineCommand.makePlayCountIn(40, 16, 4)));
        eng.processHostBuffer(outs, ins, 64);
        assert(eng.readTelemetry(tel) && tel.currentLine == 24 && tel.countingIn && eng.countInClicks() == 1);
        assert(eng.pushCommand(EngineCommand.makeStop()));
        eng.processHostBuffer(outs, ins, 64);
        assert(!eng.isCountingIn() && !eng.isPlaying());
        foreach (_; 0 .. 40) {
            eng.processHostBuffer(outs, ins, 64);
            foreach (v; bl) {
                assert(v == 0.0f);
            }
        }

        assert(eng.pushCommand(EngineCommand.makePlayCountIn(40, 16, 4)));
        eng.processHostBuffer(outs, ins, 64);
        assert(eng.pushCommand(EngineCommand.makeSeekLine(5)));
        eng.processHostBuffer(outs, ins, 64);
        assert(!eng.isCountingIn() && eng.readTelemetry(tel) && tel.currentLine == 5);
    }
}
