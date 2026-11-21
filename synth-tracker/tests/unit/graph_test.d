/**
 * File:         tests/unit/graph_test.d
 * Module:       tests.unit.graph_test
 * Phase:        Phase 2.1-2.5 — Modular AudioGraph, UDA Protocol & Determinism Tests
 *
 * Purpose:
 *   Validates typed ports, EventArena, ProcessIO sub-slicing, @Param UDA reflection, assertNoNaNInit, GraphCompiler topological sorting, Feedback edge splitting, sample-accurate offset 137 rendering, 64 vs 512 buffer invariance, mid-stream SwapGraphPlan/SwapModuleAsset, and rt_malloc_trap zero-allocation audits.
 *
 * Real-Time & Safety Contract:
 *   Test module executing under dub test --compiler=ldc2 --config=headless.
 *
 * Dependencies:
 *   Internal: foundation.*, graph.*, modules.*, tests.audio_harness, tests.rt_malloc_trap
 *   External: core.lifetime (emplace), core.stdc.stdlib (free, malloc), std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - unittest: graph.port, graph.event, graph.buffer, graph.context
 *   - unittest: graph.module_api UDA reflection, assertNoNaNInit, ModuleRegistry
 *   - unittest: graph.plan error codes, cycle rejection, Feedback splitting
 *   - unittest: AudioGraph sample-accurate NoteOn 137, EventSink routing, CV modulation
 *   - unittest: Feedback determinism across 64..512 host blocks, silence skip, SwapGraphPlan/SwapModuleAsset, rt_malloc_trap
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.graph_test;

version (unittest) {
    import core.lifetime : emplace;
    import core.stdc.stdlib : free, malloc;
    import std.math : fabs, isFinite;

    import foundation.concurrency : SpscRing;
    import foundation.memory : OwnedBuffer;
    import foundation.types : FIXED_BLOCK_FRAMES, ModuleId, NoteId;
    import graph.audio_graph : AudioGraph, GraphTelemetry, RetiredResource, RetireSink;
    import graph.buffer : AudioBlock, CvBlock, ProcessIO;
    import graph.context : EventSink, ProcessContext, TransportState;
    import graph.event : EventArena, ModEvent, ModEventKind, sortEventsByFrameOffset;
    import graph.module_api : ModuleAdapter, ModuleCategory, ModuleDescriptor, ModuleInstance,
        Param, ParamScale, assertNoNaNInit;
    import graph.plan : GraphCompileError, GraphCompiler, GraphPlan, NodeSpec, StepKind, WireSpec;
    import graph.port : PortDescriptor, PortDirection, PortKind, arePortsCompatible, isAudioPort;
    import graph.registry : ModuleRegistry;
    import modules.control.feedback : Feedback;
    import modules.effects.amplifier : Amplifier;
    import modules.effects.dc_blocker : DcBlocker;
    import modules.output : MasterOutput;
    import tests.audio_harness : AudioMetrics, assertBufferSizeInvariance, compareStereo,
        renderOfflineStereo;
    import tests.rt_malloc_trap : verifyZeroRtAllocationsNothrow;

    private struct BadNaNModule {
        enum string typeId = "test.bad_nan";
        enum string displayName = "Bad NaN";
        static immutable PortDescriptor[1] ports = [
            PortDescriptor("out", "Out", PortKind.audioStereo, PortDirection.output)
        ];

        float uninitializedField;

        bool process(ref ProcessContext ctx) @nogc nothrow {
            cast(void) ctx;
            return false;
        }
    }

    private struct BadGcModule {
        enum string typeId = "test.bad_gc";
        enum string displayName = "Bad GC";
        static immutable PortDescriptor[1] ports = [
            PortDescriptor("out", "Out", PortKind.audioStereo, PortDirection.output)
        ];

        string forbiddenGcString;

        bool process(ref ProcessContext ctx) @nogc nothrow {
            cast(void) ctx;
            return false;
        }
    }

    private __gshared size_t gAssetDestroyedCount = 0;

    private struct TestAssetBlob {
        float multiplier = 1.0f;

        static TestAssetBlob* createOffRT(float mult) @nogc nothrow {
            auto ptr = cast(TestAssetBlob*) malloc(TestAssetBlob.sizeof);
            if (ptr is null) {
                return null;
            }
            emplace(ptr);
            ptr.multiplier = mult;
            return ptr;
        }

        static void destroyErased(void* raw) @nogc nothrow {
            if (raw !is null) {
                gAssetDestroyedCount++;
                free(raw);
            }
        }
    }

    private struct TestImpulseSynth {
        enum string typeId = "test.impulse_synth";
        enum string displayName = "Test Impulse Synth";
        enum ModuleCategory category = ModuleCategory.synth;

        static immutable PortDescriptor[2] ports = [
            PortDescriptor("evIn", "Events", PortKind.event, PortDirection.input),
            PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
        ];

        @Param("Gain", 0.0f, 4.0f, 1.0f, "", ParamScale.linear)
        float gain = 1.0f;

        @Param("Decay", 0.0f, 0.99f, 0.5f, "", ParamScale.linear)
        float decay = 0.5f;

        private float env_ = 0.0f;
        private float pendingPitch_ = 60.0f;
        private TestAssetBlob* asset_ = null;
        private uint paramNotifyCount_ = 0;
        private bool lastParamInstant_ = false;

        bool serializeExtra(out ubyte[] payload) const {
            payload = [cast(ubyte)(pendingPitch_)];
            return true;
        }

        bool deserializeExtra(const(ubyte)[] payload, float sampleRate) {
            cast(void) sampleRate;
            if (payload.length > 0) {
                pendingPitch_ = cast(float) payload[0];
            }
            return true;
        }

        @nogc nothrow:

        void prepare(float sampleRate, uint maxSliceFrames) {
            cast(void) sampleRate;
            cast(void) maxSliceFrames;
            reset();
        }

        void reset() {
            env_ = 0.0f;
            pendingPitch_ = 60.0f;
            paramNotifyCount_ = 0;
            lastParamInstant_ = false;
        }

        ~this() {
            if (asset_ !is null) {
                TestAssetBlob.destroyErased(asset_);
                asset_ = null;
            }
        }

        void onParamChanged(string field)(float sampleRate, bool instant) {
            cast(void) sampleRate;
            static if (field == "gain" || field == "decay") {
                paramNotifyCount_++;
                lastParamInstant_ = instant;
            }
        }

        void handleEvent(scope const ref ModEvent ev, float sampleRate) {
            cast(void) sampleRate;
            if (ev.kind == ModEventKind.noteOn) {
                env_ = ev.valueB;
                pendingPitch_ = ev.valueA;
            } else if (ev.kind == ModEventKind.noteOff || ev.kind == ModEventKind.allNotesOff) {
                env_ = 0.0f;
            } else if (ev.kind == ModEventKind.setPitch) {
                pendingPitch_ = ev.valueA;
            }
        }

        bool swapAsset(uint slot, void* newAsset, out void* oldAsset) {
            cast(void) slot;
            oldAsset = asset_;
            asset_ = cast(TestAssetBlob*) newAsset;
            return true;
        }

        bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
            cast(void) audioIn;
            if (env_ <= 1e-7f) {
                audioOut[0][0 .. ctx.frames] = 0.0f;
                audioOut[1][0 .. ctx.frames] = 0.0f;
                return false;
            }

            immutable float assetMult = asset_ !is null ? asset_.multiplier : 1.0f;
            immutable float totalGain = gain * assetMult;
            float peak = 0.0f;
            foreach (i; 0 .. ctx.frames) {
                immutable float y = env_ * totalGain;
                audioOut[0][i] = y;
                audioOut[1][i] = y;
                immutable float ay = fabs(y);
                if (ay > peak) peak = ay;
                env_ *= decay;
                if (env_ <= 1e-7f) {
                    env_ = 0.0f;
                }
            }
            return peak > 1e-7f;
        }
    }

    private struct TestEventRouter {
        enum string typeId = "test.event_router";
        enum string displayName = "Test Event Router";
        enum ModuleCategory category = ModuleCategory.control;

        static immutable PortDescriptor[2] ports = [
            PortDescriptor("evIn", "Event In", PortKind.event, PortDirection.input),
            PortDescriptor("evOut", "Event Out", PortKind.event, PortDirection.output)
        ];

        @Param("Emit Offset", 0.0f, 63.0f, 17.0f, "samples", ParamScale.discrete)
        float emitOffset = 17.0f;

        private bool armed_ = true;

        @nogc nothrow:

        void prepare(float sampleRate, uint maxSliceFrames) {
            cast(void) sampleRate;
            cast(void) maxSliceFrames;
            reset();
        }

        void reset() {
            armed_ = true;
        }

        bool process(ref ProcessContext ctx) {
            if (armed_) {
                armed_ = false;
                immutable uint off = cast(uint)(emitOffset + 0.5f);
                ctx.eventOut.emit(ModEvent.makeNoteOn(NoteId(77), 60.0f, 0.75f, off));
            }
            return false;
        }
    }

    private struct TestCvSource {
        enum string typeId = "test.cv_source";
        enum string displayName = "Test CV Source";
        enum ModuleCategory category = ModuleCategory.control;

        static immutable PortDescriptor[1] ports = [
            PortDescriptor("cvOut", "CV Out", PortKind.cvControl, PortDirection.output)
        ];

        @Param("Level", -1.0f, 2.0f, 0.5f, "", ParamScale.linear)
        float level = 0.5f;

        @nogc nothrow:

        bool process(ref ProcessIO io, ref ProcessContext ctx) {
            if (io.numCvOut == 0 || !io.cvOut[0].active) {
                return false;
            }
            io.cvOut[0].samples[0 .. ctx.frames] = level;
            return fabs(level) > 1e-7f;
        }
    }

    private struct TestDcSource {
        enum string typeId = "test.dc_source";
        enum string displayName = "Test DC Source";
        enum ModuleCategory category = ModuleCategory.synth;

        static immutable PortDescriptor[1] ports = [
            PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
        ];

        @Param("Level", 0.0f, 2.0f, 0.4f, "", ParamScale.linear)
        float level = 0.4f;

        @nogc nothrow:

        bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
            cast(void) audioIn;
            if (fabs(level) <= 1e-7f) {
                return false;
            }
            audioOut[0][0 .. ctx.frames] = level;
            audioOut[1][0 .. ctx.frames] = -level;
            return true;
        }
    }

    private struct RetireRingTestCtx {
        SpscRing!RetiredResource* ring = null;
    }

    private bool pushToRetireRing(void* rawCtx, RetiredResource res) @nogc nothrow {
        auto ctx = cast(RetireRingTestCtx*) rawCtx;
        if (ctx is null || ctx.ring is null) {
            return false;
        }
        return ctx.ring.tryPush(res);
    }

    unittest {
        assert(isAudioPort(PortKind.audioStereo));
        assert(isAudioPort(PortKind.audioMono));
        assert(isAudioPort(PortKind.sidechainStereo));
        assert(!isAudioPort(PortKind.event));
        assert(!isAudioPort(PortKind.cvControl));

        assert(arePortsCompatible(PortKind.audioStereo, PortKind.audioStereo));
        assert(arePortsCompatible(PortKind.audioStereo, PortKind.audioMono));
        assert(arePortsCompatible(PortKind.audioStereo, PortKind.sidechainStereo));
        assert(arePortsCompatible(PortKind.audioMono, PortKind.audioStereo));
        assert(!arePortsCompatible(PortKind.sidechainStereo, PortKind.audioStereo));
        assert(arePortsCompatible(PortKind.event, PortKind.event));
        assert(!arePortsCompatible(PortKind.event, PortKind.cvControl));
        assert(arePortsCompatible(PortKind.cvControl, PortKind.cvControl));
        assert(!arePortsCompatible(PortKind.cvControl, PortKind.audioStereo));

        ModEvent[4] unsorted = [
            ModEvent.makeNoteOn(NoteId(1), 60.0f, 1.0f, 12),
            ModEvent.makeNoteOn(NoteId(2), 62.0f, 1.0f, 3),
            ModEvent.makeNoteOff(NoteId(1), 12),
            ModEvent.makeAllNotesOff(0)
        ];
        sortEventsByFrameOffset(unsorted[]);
        assert(unsorted[0].kind == ModEventKind.allNotesOff && unsorted[0].frameOffset == 0);
        assert(unsorted[1].noteId == NoteId(2) && unsorted[1].frameOffset == 3);
        assert(unsorted[2].kind == ModEventKind.noteOn && unsorted[2].frameOffset == 12);
        assert(unsorted[3].kind == ModEventKind.noteOff && unsorted[3].frameOffset == 12);

        EventArena arena;
        assert(EventArena.tryCreate(16, arena));
        assert(arena.tryPush(ModuleId(1), 137, ModEvent.makeNoteOn(NoteId(5), 69.0f, 0.9f)));
        assert(arena.tryPush(ModuleId(1), 50, ModEvent.makeNoteOn(NoteId(4), 64.0f, 0.8f)));
        assert(arena.tryPush(ModuleId(2), 140, ModEvent.makeNoteOff(NoteId(5))));
        arena.sortByFrame();
        assert(arena.slice()[0].targetFrame == 50);

        ModEvent[8] winOut;
        immutable size_t count = arena.collectForModuleInWindow(ModuleId(1), 128, 192, winOut[]);
        assert(count == 1 && winOut[0].frameOffset == 9 && winOut[0].noteId == NoteId(5));
        arena.pruneBefore(140);
        assert(arena.length == 1 && arena.slice()[0].targetMod == ModuleId(2));

        float[8] inBuf = 1.0f;
        float[8] outBuf = 0.0f;
        float[8] cvBuf = 0.5f;
        ProcessIO io;
        io.audioIn = [inBuf[], inBuf[]];
        io.audioOut = [outBuf[], outBuf[]];
        io.numCvIn = 1;
        io.cvIn[0].samples = cvBuf[];
        io.cvIn[0].connected = true;
        io.cvIn[0].silent = false;
        ProcessIO subIo = io.subSlice(2, 6);
        assert(subIo.audioIn[0].length == 4 && subIo.audioOut[0].length == 4 && subIo.cvIn[0].samples.length == 4);

        AudioBlock blk;
        blk.channels = [outBuf[], outBuf[]];
        blk.channels[0][] = 1.0f;
        blk.zeroFill(4);
        assert(blk.silent && blk.channels[0][0] == 0.0f && blk.channels[0][4] == 1.0f);

        CvBlock cvBlk;
        cvBlk.samples = cvBuf[];
        cvBlk.zeroFill(2);
        assert(cvBlk.silent && cvBlk.samples[0] == 0.0f && cvBlk.samples[2] == 0.5f);

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            arena.clear();
            assert(arena.tryPush(ModuleId(1), 10, ModEvent.makeNoteOn(NoteId(1), 60.0f)));
            arena.sortByFrame();
            ModEvent[4] rtWin;
            assert(arena.collectForModuleInWindow(ModuleId(1), 0, 64, rtWin[]) == 1);
            arena.pruneBefore(64);
            assert(arena.empty());
        });
    }

    unittest {
        static assert(!__traits(compiles, ModuleAdapter!BadNaNModule));
        static assert(!__traits(compiles, ModuleAdapter!BadGcModule));

        assertNoNaNInit!MasterOutput();
        assertNoNaNInit!Amplifier();
        assertNoNaNInit!DcBlocker();
        assertNoNaNInit!Feedback();
        assertNoNaNInit!TestImpulseSynth();

        auto impDesc = &ModuleAdapter!TestImpulseSynth.DESCRIPTOR;
        assert(impDesc.params.length == 2);
        assert(impDesc.params[0].fieldName == "gain" && impDesc.params[1].fieldName == "decay");
        assert(!impDesc.isFeedback && !impDesc.isOutput);

        void* raw = impDesc.vtable.create();
        assert(raw !is null);
        scope (exit) impDesc.vtable.destroy(raw);
        impDesc.vtable.prepare(raw, 48_000.0f, FIXED_BLOCK_FRAMES);

        assert(impDesc.vtable.setParam(raw, 0, 99.0f, 48_000.0f, true));
        assert(impDesc.vtable.getParam(raw, 0) == 4.0f);
        assert(impDesc.vtable.setParam(raw, 0, float.nan, 48_000.0f, false));
        assert(impDesc.vtable.getParam(raw, 0) == 1.0f);

        auto typed = cast(TestImpulseSynth*) raw;
        assert(typed.paramNotifyCount_ == 2 && !typed.lastParamInstant_);

        assert(impDesc.vtable.handleEvent !is null);
        ModEvent noteEv = ModEvent.makeNoteOn(NoteId(1), 72.0f, 1.0f);
        impDesc.vtable.handleEvent(raw, noteEv, 48_000.0f);
        ubyte[] extra;
        assert(impDesc.vtable.serializeExtra(raw, extra) && extra.length == 1 && extra[0] == 72);
        typed.pendingPitch_ = 0.0f;
        assert(impDesc.vtable.deserializeExtra(raw, extra, 48_000.0f) && typed.pendingPitch_ == 72.0f);

        auto allDescs = ModuleRegistry.descriptors();
        assert(allDescs.length >= 4);
        assert(ModuleRegistry.findByTypeId("core.output") !is null);
        assert(ModuleRegistry.findByTypeId("fx.amplifier") !is null);
        assert(ModuleRegistry.findByTypeId("fx.dc_blocker") !is null);
        assert(ModuleRegistry.findByTypeId("ctl.feedback") !is null);
        assert(ModuleRegistry.findByTypeId("nonexistent.module") is null);

        ModuleInstance fbInst;
        assert(ModuleRegistry.createOffRT("ctl.feedback", ModuleId(10), 44_100.0f, fbInst));
        assert(fbInst.desc.isFeedback && fbInst.state !is null);
        fbInst.destroyOffRT();
        assert(fbInst.state is null);
    }

    unittest {
        ModuleInstance amp1;
        ModuleInstance amp2;
        ModuleInstance outMod;
        assert(ModuleRegistry.createOffRT("fx.amplifier", ModuleId(1), 44_100.0f, amp1));
        assert(ModuleRegistry.createOffRT("fx.amplifier", ModuleId(2), 44_100.0f, amp2));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(3), 44_100.0f, outMod));
        scope (exit) {
            amp1.destroyOffRT();
            amp2.destroyOffRT();
            outMod.destroyOffRT();
        }

        GraphPlan* badPlan = null;
        GraphCompileError err;

        NodeSpec[2] dupNodes = [
            NodeSpec.fromInstance(amp1),
            NodeSpec(ModuleId(1), amp2.desc, amp2.state)
        ];
        assert(!GraphCompiler.compile(dupNodes[], null, badPlan, err)
            && err == GraphCompileError.duplicateNodeId);

        NodeSpec[2] cycleNodes = [NodeSpec.fromInstance(amp1), NodeSpec.fromInstance(amp2)];
        WireSpec[2] cycleWires = [
            WireSpec(ModuleId(1), 2, ModuleId(2), 0, 1.0f),
            WireSpec(ModuleId(2), 2, ModuleId(1), 0, 1.0f)
        ];
        assert(!GraphCompiler.compile(cycleNodes[], cycleWires[], badPlan, err)
            && err == GraphCompileError.cycleDetected);

        WireSpec[1] wrongDir = [WireSpec(ModuleId(1), 0, ModuleId(2), 0, 1.0f)];
        assert(!GraphCompiler.compile(cycleNodes[], wrongDir[], badPlan, err)
            && err == GraphCompileError.invalidDirection);

        WireSpec[1] badPort = [WireSpec(ModuleId(1), 99, ModuleId(2), 0, 1.0f)];
        assert(!GraphCompiler.compile(cycleNodes[], badPort[], badPlan, err)
            && err == GraphCompileError.invalidPort);

        ModuleInstance impInst;
        auto impDesc = &ModuleAdapter!TestImpulseSynth.DESCRIPTOR;
        impInst.id = ModuleId(4);
        impInst.desc = impDesc;
        impInst.state = impDesc.vtable.create();
        impDesc.vtable.prepare(impInst.state, 44_100.0f, FIXED_BLOCK_FRAMES);
        scope (exit) impInst.destroyOffRT();

        NodeSpec[2] mismatchNodes = [NodeSpec.fromInstance(impInst), NodeSpec.fromInstance(outMod)];
        WireSpec[1] eventToAudio = [WireSpec(ModuleId(4), 1, ModuleId(3), 0, 1.0f)];
        WireSpec[1] evPortToAudioPort = [WireSpec(ModuleId(4), 0, ModuleId(3), 0, 1.0f)];
        cast(void) eventToAudio;
        cast(void) evPortToAudioPort;

        ModuleInstance routerInst;
        auto routerDesc = &ModuleAdapter!TestEventRouter.DESCRIPTOR;
        routerInst.id = ModuleId(5);
        routerInst.desc = routerDesc;
        routerInst.state = routerDesc.vtable.create();
        routerDesc.vtable.prepare(routerInst.state, 44_100.0f, FIXED_BLOCK_FRAMES);
        scope (exit) routerInst.destroyOffRT();

        NodeSpec[2] badCompatNodes = [NodeSpec.fromInstance(routerInst), NodeSpec.fromInstance(outMod)];
        WireSpec[1] badCompatWire = [WireSpec(ModuleId(5), 1, ModuleId(3), 0, 1.0f)];
        assert(!GraphCompiler.compile(badCompatNodes[], badCompatWire[], badPlan, err)
            && err == GraphCompileError.incompatiblePorts);

        ModuleInstance fbInst;
        assert(ModuleRegistry.createOffRT("ctl.feedback", ModuleId(6), 44_100.0f, fbInst));
        scope (exit) fbInst.destroyOffRT();

        NodeSpec[3] fbNodes = [
            NodeSpec.fromInstance(amp1),
            NodeSpec.fromInstance(fbInst),
            NodeSpec.fromInstance(outMod)
        ];
        WireSpec[3] fbWires = [
            WireSpec(ModuleId(6), 1, ModuleId(1), 0, 1.0f),
            WireSpec(ModuleId(1), 2, ModuleId(6), 0, 1.0f),
            WireSpec(ModuleId(1), 2, ModuleId(3), 0, 1.0f)
        ];
        GraphPlan* goodFbPlan = null;
        assert(GraphCompiler.compile(fbNodes[], fbWires[], goodFbPlan, err)
            && err == GraphCompileError.none && goodFbPlan !is null);
        scope (exit) GraphPlan.destroyOffRT(goodFbPlan);
        size_t recvStep = size_t.max;
        size_t ampStep = size_t.max;
        size_t sendStep = size_t.max;
        size_t outStep = size_t.max;
        foreach (si, ref st; goodFbPlan.steps[]) {
            if (st.kind == StepKind.feedbackReceive) recvStep = si;
            else if (st.kind == StepKind.feedbackSend) sendStep = si;
            else if (st.nodeIndex == 0) ampStep = si;
            else if (st.nodeIndex == 2) outStep = si;
        }
        assert(recvStep != size_t.max && ampStep != size_t.max
            && sendStep != size_t.max && outStep != size_t.max);
        assert(recvStep < ampStep && ampStep < sendStep && ampStep < outStep);
    }

    unittest {
        auto impDesc = &ModuleAdapter!TestImpulseSynth.DESCRIPTOR;
        ModuleInstance impInst = ModuleInstance(ModuleId(1), impDesc, impDesc.vtable.create());
        impDesc.vtable.prepare(impInst.state, 44_100.0f, FIXED_BLOCK_FRAMES);

        ModuleInstance outInst;
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(2), 44_100.0f, outInst));
        scope (exit) {
            impInst.destroyOffRT();
            outInst.destroyOffRT();
        }
        outInst.desc.vtable.setParam(outInst.state, 1, 0.0f, 44_100.0f, true);

        NodeSpec[2] nodes = [NodeSpec.fromInstance(impInst), NodeSpec.fromInstance(outInst)];
        WireSpec[1] wires = [WireSpec(ModuleId(1), 1, ModuleId(2), 0, 1.0f)];
        GraphPlan* plan = null;
        GraphCompileError err;
        assert(GraphCompiler.compile(nodes[], wires[], plan, err));

        AudioGraph graph;
        assert(graph.tryInit(44_100.0f));
        graph.swapPlan(plan);
        scope (exit) GraphPlan.destroyOffRT(graph.detachPlan());

        TransportState transport;
        enum size_t TOTAL_FRAMES = 512;

        void resetAndSchedule() {
            graph.reset();
            transport = TransportState.init;
            assert(graph.enqueueEvent(
                ModuleId(1),
                ModEvent.makeNoteOn(NoteId(1), 60.0f, 0.8f),
                137
            ));
        }

        assertBufferSizeInvariance(
            &resetAndSchedule,
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                float[][2] outs = [l, r];
                const(float[])[2] ins = [null, null];
                graph.render(outs, ins, cast(uint) l.length, transport);
            },
            TOTAL_FRAMES
        );

        resetAndSchedule();
        OwnedBuffer!float checkL;
        OwnedBuffer!float checkR;
        assert(renderOfflineStereo(
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                float[][2] outs = [l, r];
                const(float[])[2] ins = [null, null];
                graph.render(outs, ins, cast(uint) l.length, transport);
            },
            TOTAL_FRAMES,
            64,
            checkL,
            checkR
        ));

        foreach (i; 0 .. 137) {
            assert(checkL[i] == 0.0f && checkR[i] == 0.0f);
        }
        assert(fabs(checkL[137] - 0.8f) < 1e-6f && fabs(checkR[137] - 0.8f) < 1e-6f);
        assert(fabs(checkL[138] - 0.4f) < 1e-6f);
        assert(fabs(checkL[139] - 0.2f) < 1e-6f);
    }

    unittest {
        auto routerDesc = &ModuleAdapter!TestEventRouter.DESCRIPTOR;
        ModuleInstance routerInst = ModuleInstance(ModuleId(1), routerDesc, routerDesc.vtable.create());
        routerDesc.vtable.prepare(routerInst.state, 44_100.0f, FIXED_BLOCK_FRAMES);

        auto impDesc = &ModuleAdapter!TestImpulseSynth.DESCRIPTOR;
        ModuleInstance impInst = ModuleInstance(ModuleId(2), impDesc, impDesc.vtable.create());
        impDesc.vtable.prepare(impInst.state, 44_100.0f, FIXED_BLOCK_FRAMES);

        ModuleInstance ampInst;
        assert(ModuleRegistry.createOffRT("fx.amplifier", ModuleId(3), 44_100.0f, ampInst));

        ModuleInstance outInst;
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(4), 44_100.0f, outInst));
        outInst.desc.vtable.setParam(outInst.state, 1, 0.0f, 44_100.0f, true);

        scope (exit) {
            routerInst.destroyOffRT();
            impInst.destroyOffRT();
            ampInst.destroyOffRT();
            outInst.destroyOffRT();
        }

        NodeSpec[4] nodes = [
            NodeSpec.fromInstance(routerInst),
            NodeSpec.fromInstance(impInst),
            NodeSpec.fromInstance(ampInst),
            NodeSpec.fromInstance(outInst)
        ];
        WireSpec[3] wires = [
            WireSpec(ModuleId(1), 1, ModuleId(2), 0, 1.0f),
            WireSpec(ModuleId(2), 1, ModuleId(3), 0, 1.0f),
            WireSpec(ModuleId(3), 2, ModuleId(4), 0, 1.0f)
        ];
        GraphPlan* plan = null;
        GraphCompileError err;
        assert(GraphCompiler.compile(nodes[], wires[], plan, err));

        AudioGraph graph;
        assert(graph.tryInit(44_100.0f));
        graph.swapPlan(plan);
        scope (exit) GraphPlan.destroyOffRT(graph.detachPlan());

        assert(graph.enqueueEvent(
            ModuleId(3),
            ModEvent.makeSetParam(0, 2.0f, true),
            19
        ));

        float[64] outL = 0.0f;
        float[64] outR = 0.0f;
        float[][2] outs = [outL[], outR[]];
        const(float[])[2] ins = [null, null];
        TransportState transport;
        graph.render(outs, ins, 64, transport);

        foreach (i; 0 .. 17) {
            assert(outL[i] == 0.0f);
        }
        assert(fabs(outL[17] - 0.75f) < 1e-6f);
        assert(fabs(outL[18] - 0.375f) < 1e-6f);
        assert(fabs(outL[19] - (0.1875f * 2.0f)) < 1e-5f);

        auto cvDesc = &ModuleAdapter!TestCvSource.DESCRIPTOR;
        ModuleInstance cvInst = ModuleInstance(ModuleId(10), cvDesc, cvDesc.vtable.create());
        cvDesc.vtable.prepare(cvInst.state, 44_100.0f, FIXED_BLOCK_FRAMES);

        auto dcDesc = &ModuleAdapter!TestDcSource.DESCRIPTOR;
        ModuleInstance dcInst = ModuleInstance(ModuleId(11), dcDesc, dcDesc.vtable.create());
        dcDesc.vtable.prepare(dcInst.state, 44_100.0f, FIXED_BLOCK_FRAMES);

        ModuleInstance ampCv;
        assert(ModuleRegistry.createOffRT("fx.amplifier", ModuleId(12), 44_100.0f, ampCv));
        ModuleInstance outCv;
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(13), 44_100.0f, outCv));
        outCv.desc.vtable.setParam(outCv.state, 1, 0.0f, 44_100.0f, true);
        scope (exit) {
            cvInst.destroyOffRT();
            dcInst.destroyOffRT();
            ampCv.destroyOffRT();
            outCv.destroyOffRT();
        }

        NodeSpec[4] cvNodes = [
            NodeSpec.fromInstance(cvInst),
            NodeSpec.fromInstance(dcInst),
            NodeSpec.fromInstance(ampCv),
            NodeSpec.fromInstance(outCv)
        ];
        WireSpec[3] cvWires = [
            WireSpec(ModuleId(11), 0, ModuleId(12), 0, 1.0f),
            WireSpec(ModuleId(10), 0, ModuleId(12), 1, 1.0f),
            WireSpec(ModuleId(12), 2, ModuleId(13), 0, 1.0f)
        ];
        GraphPlan* cvPlan = null;
        assert(GraphCompiler.compile(cvNodes[], cvWires[], cvPlan, err));

        AudioGraph cvGraph;
        assert(cvGraph.tryInit(44_100.0f));
        cvGraph.swapPlan(cvPlan);
        scope (exit) GraphPlan.destroyOffRT(cvGraph.detachPlan());

        cvGraph.render(outs, ins, 64, transport);
        foreach (i; 0 .. 64) {
            assert(fabs(outL[i] - 0.6f) < 1e-6f);
            assert(fabs(outR[i] + 0.6f) < 1e-6f);
        }
    }

    unittest {
        auto impDesc = &ModuleAdapter!TestImpulseSynth.DESCRIPTOR;
        ModuleInstance impInst = ModuleInstance(ModuleId(1), impDesc, impDesc.vtable.create());
        impDesc.vtable.prepare(impInst.state, 44_100.0f, FIXED_BLOCK_FRAMES);
        impDesc.vtable.setParam(impInst.state, 1, 0.0f, 44_100.0f, true);

        ModuleInstance ampInst;
        assert(ModuleRegistry.createOffRT("fx.amplifier", ModuleId(2), 44_100.0f, ampInst));

        ModuleInstance dcInst;
        assert(ModuleRegistry.createOffRT("fx.dc_blocker", ModuleId(3), 44_100.0f, dcInst));

        ModuleInstance fbInst;
        assert(ModuleRegistry.createOffRT("ctl.feedback", ModuleId(4), 44_100.0f, fbInst));
        fbInst.desc.vtable.setParam(fbInst.state, 0, 0.5f, 44_100.0f, true);
        fbInst.desc.vtable.setParam(fbInst.state, 2, 64.0f, 44_100.0f, true);

        ModuleInstance outInst;
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(5), 44_100.0f, outInst));
        outInst.desc.vtable.setParam(outInst.state, 1, 0.0f, 44_100.0f, true);

        scope (exit) {
            impInst.destroyOffRT();
            ampInst.destroyOffRT();
            dcInst.destroyOffRT();
            fbInst.destroyOffRT();
            outInst.destroyOffRT();
        }

        NodeSpec[5] nodes = [
            NodeSpec.fromInstance(impInst),
            NodeSpec.fromInstance(ampInst),
            NodeSpec.fromInstance(dcInst),
            NodeSpec.fromInstance(fbInst),
            NodeSpec.fromInstance(outInst)
        ];
        WireSpec[5] wires = [
            WireSpec(ModuleId(1), 1, ModuleId(2), 0, 1.0f),
            WireSpec(ModuleId(4), 1, ModuleId(2), 0, 1.0f),
            WireSpec(ModuleId(2), 2, ModuleId(3), 0, 1.0f),
            WireSpec(ModuleId(3), 1, ModuleId(4), 0, 1.0f),
            WireSpec(ModuleId(3), 1, ModuleId(5), 0, 1.0f)
        ];

        GraphPlan* fbPlan = null;
        GraphCompileError err;
        assert(GraphCompiler.compile(nodes[], wires[], fbPlan, err));

        AudioGraph graph;
        assert(graph.tryInit(44_100.0f));
        graph.swapPlan(fbPlan);
        scope (exit) GraphPlan.destroyOffRT(graph.detachPlan());

        TransportState transport;
        void resetFeedbackRun() {
            graph.reset();
            transport = TransportState.init;
            assert(graph.enqueueEvent(ModuleId(1), ModEvent.makeNoteOn(NoteId(1), 60.0f, 1.0f), 0));
        }

        assertBufferSizeInvariance(
            &resetFeedbackRun,
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                float[][2] outs = [l, r];
                const(float[])[2] ins = [null, null];
                graph.render(outs, ins, cast(uint) l.length, transport);
            },
            512
        );

        resetFeedbackRun();
        OwnedBuffer!float fbL;
        OwnedBuffer!float fbR;
        assert(renderOfflineStereo(
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                float[][2] outs = [l, r];
                const(float[])[2] ins = [null, null];
                graph.render(outs, ins, cast(uint) l.length, transport);
            },
            512,
            64,
            fbL,
            fbR
        ));

        foreach (s; fbL[]) {
            assert(isFinite(s));
        }
        assert(fabs(fbL[0] - 1.0f) < 1e-4f);
        assert(fbL[64] > 0.45f && fbL[64] < 0.55f);
        assert(fbL[128] > 0.2f && fbL[128] < fbL[64]);
        assert(fbL[192] > 0.08f && fbL[192] < fbL[128]);

        fbInst.desc.vtable.setParam(fbInst.state, 2, 100.0f, 44_100.0f, true);
        resetFeedbackRun();
        OwnedBuffer!float d100L;
        OwnedBuffer!float d100R;
        assert(renderOfflineStereo(
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                float[][2] outs = [l, r];
                const(float[])[2] ins = [null, null];
                graph.render(outs, ins, cast(uint) l.length, transport);
            },
            256,
            64,
            d100L,
            d100R
        ));
        assert(fabs(d100L[64]) < 5e-3f && d100L[100] > 0.4f);
    }

    unittest {
        auto impDesc = &ModuleAdapter!TestImpulseSynth.DESCRIPTOR;
        ModuleInstance impInst = ModuleInstance(ModuleId(1), impDesc, impDesc.vtable.create());
        impDesc.vtable.prepare(impInst.state, 44_100.0f, FIXED_BLOCK_FRAMES);
        impDesc.vtable.setParam(impInst.state, 1, 0.0f, 44_100.0f, true);

        ModuleInstance dcInst;
        assert(ModuleRegistry.createOffRT("fx.dc_blocker", ModuleId(2), 44_100.0f, dcInst));

        ModuleInstance outInst;
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(3), 44_100.0f, outInst));

        scope (exit) {
            impInst.destroyOffRT();
            dcInst.destroyOffRT();
            outInst.destroyOffRT();
        }

        NodeSpec[3] nodes = [
            NodeSpec.fromInstance(impInst),
            NodeSpec.fromInstance(dcInst),
            NodeSpec.fromInstance(outInst)
        ];
        WireSpec[2] wires = [
            WireSpec(ModuleId(1), 1, ModuleId(2), 0, 1.0f),
            WireSpec(ModuleId(2), 1, ModuleId(3), 0, 1.0f)
        ];
        GraphPlan* plan1 = null;
        GraphCompileError err;
        assert(GraphCompiler.compile(nodes[], wires[], plan1, err));

        NodeSpec[3] bypassNodes = [
            NodeSpec.fromInstance(impInst),
            NodeSpec.fromInstance(dcInst, false, true),
            NodeSpec.fromInstance(outInst)
        ];
        GraphPlan* plan2 = null;
        assert(GraphCompiler.compile(bypassNodes[], wires[], plan2, err));

        AudioGraph graph;
        assert(graph.tryInit(44_100.0f));
        graph.swapPlan(plan1);

        SpscRing!RetiredResource retireRing;
        assert(SpscRing!RetiredResource.tryCreate(16, retireRing));
        RetireRingTestCtx retireCtx = RetireRingTestCtx(&retireRing);
        RetireSink retireSink = RetireSink(&pushToRetireRing, &retireCtx);

        assert(graph.enqueueEvent(ModuleId(1), ModEvent.makeNoteOn(NoteId(1), 60.0f, 1.0f), 0));
        float[64] bufL = 0.0f;
        float[64] bufR = 0.0f;
        float[][2] outs = [bufL[], bufR[]];
        const(float[])[2] ins = [null, null];
        TransportState transport;
        graph.render(outs, ins, 64, transport);

        GraphTelemetry tel;
        assert(graph.readTelemetry(tel));
        assert(tel.activeNodeCount == 3 && tel.skippedSilentNodeCount == 0);
        assert(tel.masterPeakL > 0.9f && tel.slicesRendered == 1);

        foreach (_; 0 .. 200) {
            graph.render(outs, ins, 64, transport);
        }
        assert(graph.readTelemetry(tel));
        assert(tel.skippedSilentNodeCount == 3);

        gAssetDestroyedCount = 0;
        TestAssetBlob* asset1 = TestAssetBlob.createOffRT(0.5f);
        TestAssetBlob* asset2 = TestAssetBlob.createOffRT(0.25f);
        assert(asset1 !is null && asset2 !is null);

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            assert(graph.swapModuleAsset(ModuleId(1), 0, asset1, &TestAssetBlob.destroyErased, retireSink));
            assert(graph.swapModuleAsset(ModuleId(1), 0, asset2, &TestAssetBlob.destroyErased, retireSink));
            graph.swapPlan(plan2, retireSink);
            assert(graph.enqueueEvent(ModuleId(1), ModEvent.makeNoteOn(NoteId(2), 64.0f, 0.8f), graph.renderedFrames()));
            graph.render(outs, ins, 64, transport);
        });
        assert(fabs(bufL[0] - 0.2f) < 1e-5f);

        GraphPlan* remainingPlan = graph.detachPlan();
        if (remainingPlan !is null) {
            GraphPlan.destroyOffRT(remainingPlan);
        }

        size_t retiredCount = 0;
        RetiredResource retired;
        while (retireRing.tryPop(retired)) {
            retired.reclaimOffRT();
            retiredCount++;
        }
        assert(retiredCount == 2);
        assert(gAssetDestroyedCount == 1);

        impInst.destroyOffRT();
        assert(gAssetDestroyedCount == 2);
    }
}
