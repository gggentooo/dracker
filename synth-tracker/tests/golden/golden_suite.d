/**
 * File:         tests/golden/golden_suite.d
 * Module:       tests.golden.golden_suite
 * Phase:        Phase 4.5 / 5 — Built-In Module & Sequencer Golden WAV Suite
 *
 * Purpose:
 *   Executes automated offline golden-WAV regression tests, multi-module studio patch determinism checks across varying host buffer sizes (64..512), Feedback cycle determinism, and rt_malloc_trap allocation checks across Tier 1 & Tier 2 modules.
 *
 * Real-Time & Safety Contract:
 *   Test module combining tests.audio_harness and tests.rt_malloc_trap with cleanup of temporary golden WAVs.
 *
 * Dependencies:
 *   Internal: foundation.memory, foundation.types, graph.audio_graph, graph.context, graph.event, graph.module_api, graph.plan, graph.registry, tests.audio_harness, tests.rt_malloc_trap
 *   External: std.file (exists, remove), std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) Patch 1: AnalogGen + LfoMod + FilterPro -> Echo -> Reverb -> Compressor -> MasterOutput
 *   - version(unittest) Patch 2: FmSynth -> WaveShaper -> Flanger -> Eq3Band -> MasterOutput
 *   - version(unittest) Patch 3: DrumSynth -> Distortion -> Delay -> MasterOutput
 *   - version(unittest) Patch 4: Kicker + Feedback + DcBlocker cyclic determinism & golden WAV roundtrip
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.golden.golden_suite;

version (unittest) {
    import std.file : exists, remove;
    import std.math : fabs, isFinite;

    import foundation.memory : OwnedBuffer;
    import foundation.types : ModuleId, NoteId;
    import graph.audio_graph : AudioGraph;
    import graph.context : TransportState;
    import graph.event : ModEvent;
    import graph.module_api : ModuleInstance;
    import graph.plan : GraphCompileError, GraphCompiler, GraphPlan, NodeSpec, WireSpec;
    import graph.registry : ModuleRegistry;
    import tests.audio_harness : AudioMetrics, assertBufferSizeInvariance, compareStereo,
        compareWithGoldenWav, renderOfflineStereo, renderOfflineToWav;
    import tests.rt_malloc_trap : verifyZeroRtAllocationsNothrow;

    unittest {
        ModuleInstance lfo;
        ModuleInstance gen;
        ModuleInstance flt;
        ModuleInstance echo;
        ModuleInstance rev;
        ModuleInstance cmp;
        ModuleInstance sink;
        assert(ModuleRegistry.createOffRT("fx.lfo", ModuleId(1), 44_100.0f, lfo));
        assert(ModuleRegistry.createOffRT("synth.analog_gen", ModuleId(2), 44_100.0f, gen));
        assert(ModuleRegistry.createOffRT("fx.filter_pro", ModuleId(3), 44_100.0f, flt));
        assert(ModuleRegistry.createOffRT("fx.echo", ModuleId(4), 44_100.0f, echo));
        assert(ModuleRegistry.createOffRT("fx.reverb", ModuleId(5), 44_100.0f, rev));
        assert(ModuleRegistry.createOffRT("fx.compressor", ModuleId(6), 44_100.0f, cmp));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(7), 44_100.0f, sink));
        scope (exit) {
            lfo.destroyOffRT();
            gen.destroyOffRT();
            flt.destroyOffRT();
            echo.destroyOffRT();
            rev.destroyOffRT();
            cmp.destroyOffRT();
            sink.destroyOffRT();
        }

        gen.desc.vtable.setParam(gen.state, 1, 2.0f, 44_100.0f, true);
        flt.desc.vtable.setParam(flt.state, 2, 1800.0f, 44_100.0f, true);
        lfo.desc.vtable.setParam(lfo.state, 1, 3.0f, 44_100.0f, true);

        NodeSpec[7] nodes = [
            NodeSpec.fromInstance(lfo),
            NodeSpec.fromInstance(gen),
            NodeSpec.fromInstance(flt),
            NodeSpec.fromInstance(echo),
            NodeSpec.fromInstance(rev),
            NodeSpec.fromInstance(cmp),
            NodeSpec.fromInstance(sink)
        ];
        WireSpec[6] wires = [
            WireSpec(ModuleId(1), 2, ModuleId(3), 1, 0.35f),
            WireSpec(ModuleId(2), 2, ModuleId(3), 0, 1.0f),
            WireSpec(ModuleId(3), 3, ModuleId(4), 0, 1.0f),
            WireSpec(ModuleId(4), 1, ModuleId(5), 0, 1.0f),
            WireSpec(ModuleId(5), 1, ModuleId(6), 0, 1.0f),
            WireSpec(ModuleId(6), 2, ModuleId(7), 0, 1.0f)
        ];

        GraphPlan* plan = null;
        GraphCompileError err;
        assert(GraphCompiler.compile(nodes[], wires[], plan, err));

        AudioGraph graph;
        assert(graph.tryInit(44_100.0f));
        graph.swapPlan(plan);
        scope (exit) GraphPlan.destroyOffRT(graph.detachPlan());

        TransportState transport;
        void resetPatch() {
            graph.reset();
            transport = TransportState.init;
            assert(graph.enqueueEvent(ModuleId(2), ModEvent.makeNoteOn(NoteId(1), 48.0f, 0.9f), 0));
            assert(graph.enqueueEvent(ModuleId(2), ModEvent.makeNoteOn(NoteId(2), 55.0f, 0.8f), 137));
            assert(graph.enqueueEvent(ModuleId(2), ModEvent.makeNoteOff(NoteId(1)), 2048));
            assert(graph.enqueueEvent(ModuleId(2), ModEvent.makeNoteOff(NoteId(2)), 2560));
        }

        assertBufferSizeInvariance(
            &resetPatch,
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                float[][2] outs = [l, r];
                const(float[])[2] ins = [null, null];
                graph.render(outs, ins, cast(uint) l.length, transport);
            },
            4096
        );

        resetPatch();
        float[512] rtOutL = 0.0f;
        float[512] rtOutR = 0.0f;
        float[][2] rtOuts = [rtOutL[], rtOutR[]];
        const(float[])[2] rtIns = [null, null];
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            graph.render(rtOuts, rtIns, 512, transport);
        });

        enum string goldenPath = "/tmp/synth_tracker_phase4_golden_patch1.wav";
        scope (exit) {
            if (exists(goldenPath)) {
                remove(goldenPath);
            }
        }
        resetPatch();
        string ioErr;
        assert(renderOfflineToWav(
            goldenPath,
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                float[][2] outs = [l, r];
                const(float[])[2] ins = [null, null];
                graph.render(outs, ins, cast(uint) l.length, transport);
            },
            4096,
            44_100,
            256,
            ioErr
        ));

        resetPatch();
        OwnedBuffer!float checkL;
        OwnedBuffer!float checkR;
        assert(renderOfflineStereo(
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                float[][2] outs = [l, r];
                const(float[])[2] ins = [null, null];
                graph.render(outs, ins, cast(uint) l.length, transport);
            },
            4096,
            128,
            checkL,
            checkR
        ));

        immutable AudioMetrics gm = compareWithGoldenWav(goldenPath, checkL[], checkR[], ioErr);
        assert(gm.bitExact() && gm.peakActual > 0.01);
    }

    unittest {
        ModuleInstance fm;
        ModuleInstance ws;
        ModuleInstance flg;
        ModuleInstance eq;
        ModuleInstance sink;
        assert(ModuleRegistry.createOffRT("synth.fm_synth", ModuleId(1), 44_100.0f, fm));
        assert(ModuleRegistry.createOffRT("fx.waveshaper", ModuleId(2), 44_100.0f, ws));
        assert(ModuleRegistry.createOffRT("fx.flanger", ModuleId(3), 44_100.0f, flg));
        assert(ModuleRegistry.createOffRT("fx.eq3", ModuleId(4), 44_100.0f, eq));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(5), 44_100.0f, sink));
        scope (exit) {
            fm.destroyOffRT();
            ws.destroyOffRT();
            flg.destroyOffRT();
            eq.destroyOffRT();
            sink.destroyOffRT();
        }

        fm.desc.vtable.setParam(fm.state, 0, 2.0f, 44_100.0f, true);
        ws.desc.vtable.setParam(ws.state, 3, 1.0f, 44_100.0f, true);
        eq.desc.vtable.setParam(eq.state, 0, 3.0f, 44_100.0f, true);

        NodeSpec[5] nodes = [
            NodeSpec.fromInstance(fm),
            NodeSpec.fromInstance(ws),
            NodeSpec.fromInstance(flg),
            NodeSpec.fromInstance(eq),
            NodeSpec.fromInstance(sink)
        ];
        WireSpec[4] wires = [
            WireSpec(ModuleId(1), 1, ModuleId(2), 0, 1.0f),
            WireSpec(ModuleId(2), 1, ModuleId(3), 0, 1.0f),
            WireSpec(ModuleId(3), 1, ModuleId(4), 0, 1.0f),
            WireSpec(ModuleId(4), 1, ModuleId(5), 0, 1.0f)
        ];

        GraphPlan* plan = null;
        GraphCompileError err;
        assert(GraphCompiler.compile(nodes[], wires[], plan, err));

        AudioGraph graph;
        assert(graph.tryInit(44_100.0f));
        graph.swapPlan(plan);
        scope (exit) GraphPlan.destroyOffRT(graph.detachPlan());

        TransportState transport;
        void resetFm() {
            graph.reset();
            transport = TransportState.init;
            assert(graph.enqueueEvent(ModuleId(1), ModEvent.makeNoteOn(NoteId(1), 57.0f, 0.9f), 0));
            assert(graph.enqueueEvent(ModuleId(1), ModEvent.makeNoteOn(NoteId(2), 64.0f, 0.85f), 200));
            assert(graph.enqueueEvent(ModuleId(1), ModEvent.makeNoteOff(NoteId(1)), 1800));
        }

        assertBufferSizeInvariance(
            &resetFm,
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                float[][2] outs = [l, r];
                const(float[])[2] ins = [null, null];
                graph.render(outs, ins, cast(uint) l.length, transport);
            },
            3072
        );
    }

    unittest {
        ModuleInstance kick;
        ModuleInstance amp;
        ModuleInstance dc;
        ModuleInstance fb;
        ModuleInstance sink;
        assert(ModuleRegistry.createOffRT("synth.kicker", ModuleId(1), 44_100.0f, kick));
        assert(ModuleRegistry.createOffRT("fx.amplifier", ModuleId(2), 44_100.0f, amp));
        assert(ModuleRegistry.createOffRT("fx.dc_blocker", ModuleId(3), 44_100.0f, dc));
        assert(ModuleRegistry.createOffRT("ctl.feedback", ModuleId(4), 44_100.0f, fb));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(5), 44_100.0f, sink));
        scope (exit) {
            kick.destroyOffRT();
            amp.destroyOffRT();
            dc.destroyOffRT();
            fb.destroyOffRT();
            sink.destroyOffRT();
        }

        fb.desc.vtable.setParam(fb.state, 0, 0.45f, 44_100.0f, true);
        fb.desc.vtable.setParam(fb.state, 2, 128.0f, 44_100.0f, true);

        NodeSpec[5] nodes = [
            NodeSpec.fromInstance(kick),
            NodeSpec.fromInstance(amp),
            NodeSpec.fromInstance(dc),
            NodeSpec.fromInstance(fb),
            NodeSpec.fromInstance(sink)
        ];
        WireSpec[5] wires = [
            WireSpec(ModuleId(1), 1, ModuleId(2), 0, 1.0f),
            WireSpec(ModuleId(4), 1, ModuleId(2), 0, 1.0f),
            WireSpec(ModuleId(2), 2, ModuleId(3), 0, 1.0f),
            WireSpec(ModuleId(3), 1, ModuleId(4), 0, 1.0f),
            WireSpec(ModuleId(3), 1, ModuleId(5), 0, 1.0f)
        ];

        GraphPlan* plan = null;
        GraphCompileError err;
        assert(GraphCompiler.compile(nodes[], wires[], plan, err));

        AudioGraph graph;
        assert(graph.tryInit(44_100.0f));
        graph.swapPlan(plan);
        scope (exit) GraphPlan.destroyOffRT(graph.detachPlan());

        TransportState transport;
        void resetCy() {
            graph.reset();
            transport = TransportState.init;
            assert(graph.enqueueEvent(ModuleId(1), ModEvent.makeNoteOn(NoteId(1), 36.0f, 1.0f), 0));
        }

        assertBufferSizeInvariance(
            &resetCy,
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                float[][2] outs = [l, r];
                const(float[])[2] ins = [null, null];
                graph.render(outs, ins, cast(uint) l.length, transport);
            },
            2048
        );
    }
}
