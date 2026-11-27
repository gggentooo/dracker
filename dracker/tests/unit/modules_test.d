/**
 * File:         tests/unit/modules_test.d
 * Module:       tests.unit.modules_test
 * Phase:        Phase 4.5 — Comprehensive Tier 1 & Tier 2 Module Verification Suite
 *
 * Purpose:
 *   Tests all 38 built-in modules via ModuleRegistry for silence-in/silence-out, @nogc rt_malloc_trap safety, extreme NaN/Inf parameter sweeps, DSP functional behavior, asset swaps/serialization, background StreamWorker/VorbisPlayer zero-RT streaming, and the 1-file/1-line extensibility contract.
 *
 * Real-Time & Safety Contract:
 *   RT verification blocks execute inside verifyZeroRtAllocationsNothrow (rt_malloc_trap).
 *
 * Dependencies:
 *   Internal: dsp.*, foundation.*, graph.*, io.audio_io, modules.*, sequencer.stream_worker, tests.audio_harness, tests.rt_malloc_trap
 *   External: core.thread, core.time, std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) universal 38-module RT safety + extreme parameter sweep matrix
 *   - version(unittest) per-module Tier 1 & Tier 2 functional DSP & SwapAsset suites
 *   - version(unittest) DummyExtensibilityModule 1-file/1-line contract test
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.modules_test;

version (unittest) {
    import core.thread : Thread;
    import core.time : dur;
    import std.math : fabs, isFinite, sin, sqrt;

    import dsp.envelope : EnvBreakpoint;
    import dsp.tables : TWO_PI_D;
    import foundation.types : FIXED_BLOCK_FRAMES, ModuleId, NoteId;
    import graph.audio_graph : AudioGraph;
    import graph.buffer : ProcessIO;
    import graph.context : EventSink, ProcessContext, TransportState;
    import graph.event : ModEvent, ModEventKind;
    import graph.module_api : ModuleAdapter, ModuleCategory, ModuleDescriptor, ModuleInstance, Param,
        ParamScale;
    import graph.plan : GraphCompileError, GraphCompiler, GraphPlan, NodeSpec, WireSpec;
    import graph.port : PortDescriptor, PortDirection, PortKind;
    import graph.registry : ModuleRegistry;
    import io.audio_io : writeWavMemory;
    import modules.control.multisynth : MultiSynthCurveAsset;
    import modules.control.multictl : MultiCtlMapAsset;
    import modules.control.pitch_detector : PitchDetector;
    import modules.effects.waveshaper : WaveShaperCurveAsset;
    import modules.synths.analog_gen : DrawnWaveAsset;
    import modules.synths.sampler : Sampler, SamplerSlotAsset, createSamplerAssetFromMemory;
    import modules.synths.spectravoice : SpectraTableAsset, SpectraTableBank, harmonicCount;
    import sequencer.stream_worker : AsyncSampleResult, StreamAudioRing, StreamWorker;
    import tests.rt_malloc_trap : verifyZeroRtAllocationsNothrow;

    private struct EventCaptureBox {
        ModEvent[64] events;
        size_t count = 0;
    }

    /**
     * Forwards a ModEvent value by const ref to a module's handleEvent vtable entry.
     *
     * Params:
     *   desc = Target ModuleDescriptor pointer.
     *   state = Module instance opaque state pointer.
     *   ev = Event payload passed by value.
     *   sr = Active sample rate in Hertz.
     */
    private void sendEvent(const(ModuleDescriptor)* desc, void* state, ModEvent ev, float sr) @nogc nothrow {
        desc.vtable.handleEvent(state, ev, sr);
    }

    private void captureEventFn(void* rawCtx, scope const ref ModEvent ev) @nogc nothrow {
        auto box = cast(EventCaptureBox*) rawCtx;
        if (box !is null && box.count < box.events.length) {
            box.events[box.count++] = ev;
        }
    }

    unittest {
        auto descs = ModuleRegistry.descriptors();
        assert(descs.length == 39);

        foreach (i; 0 .. descs.length) {
            assert(descs[i].typeId.length > 0 && descs[i].ports.length > 0);
            foreach (j; i + 1 .. descs.length) {
                assert(descs[i].typeId != descs[j].typeId);
            }
        }

        assert(ModuleRegistry.findByTypeId("synth.analog_gen") !is null);
        assert(ModuleRegistry.findByTypeId("synth.fm_synth") !is null);
        assert(ModuleRegistry.findByTypeId("synth.sampler") !is null);
        assert(ModuleRegistry.findByTypeId("fx.reverb") !is null);
        assert(ModuleRegistry.findByTypeId("fx.compressor") !is null);
        assert(ModuleRegistry.findByTypeId("fx.fft") !is null);
        assert(ModuleRegistry.findByTypeId("ctl.pitch_detector") !is null);
        assert(ModuleRegistry.findByTypeId("synth.vorbis_player") !is null);
        assert(ModuleRegistry.findByTypeId("ctl.metamodule") !is null);

        float[FIXED_BLOCK_FRAMES] zeroInL = 0.0f;
        float[FIXED_BLOCK_FRAMES] zeroInR = 0.0f;
        float[FIXED_BLOCK_FRAMES] impInL = 0.0f;
        float[FIXED_BLOCK_FRAMES] impInR = 0.0f;
        impInL[0] = 0.75f;
        impInR[0] = -0.5f;
        float[FIXED_BLOCK_FRAMES] outL = 0.0f;
        float[FIXED_BLOCK_FRAMES] outR = 0.0f;
        float[FIXED_BLOCK_FRAMES] scL = 0.0f;
        float[FIXED_BLOCK_FRAMES] scR = 0.0f;
        float[FIXED_BLOCK_FRAMES * 4] cvInBuf = 0.0f;
        float[FIXED_BLOCK_FRAMES * 4] cvOutBuf = 0.0f;

        foreach (idx, ref desc; descs) {
            ModuleInstance inst;
            assert(ModuleRegistry.createOffRT(desc.typeId, ModuleId(cast(uint)(idx + 1)), 44_100.0f, inst));
            scope (exit) inst.destroyOffRT();

            foreach (pIdx, ref p; desc.params) {
                immutable float val = desc.vtable.getParam(inst.state, cast(uint) pIdx);
                assert(isFinite(val));
            }

            ProcessIO io;
            io.audioIn[0] = zeroInL[];
            io.audioIn[1] = zeroInR[];
            io.audioOut[0] = outL[];
            io.audioOut[1] = outR[];
            io.sidechainIn[0] = scL[];
            io.sidechainIn[1] = scR[];
            foreach (k; 0 .. 4) {
                io.cvIn[k].samples = cvInBuf[k * FIXED_BLOCK_FRAMES .. (k + 1) * FIXED_BLOCK_FRAMES];
                io.cvIn[k].connected = false;
                io.cvIn[k].silent = true;
                io.cvOut[k].samples = cvOutBuf[k * FIXED_BLOCK_FRAMES .. (k + 1) * FIXED_BLOCK_FRAMES];
                io.cvOut[k].active = true;
            }
            io.numCvIn = 4;
            io.numCvOut = 4;

            EventCaptureBox cap;
            ProcessContext ctx;
            ctx.sampleRate = 44_100.0f;
            ctx.frames = FIXED_BLOCK_FRAMES;
            ctx.transport.bpm = 125.0;
            ctx.transport.ticksPerLine = 6;
            ctx.transport.playing = true;
            ctx.inputSilent = true;
            ctx.eventOut = EventSink(&captureEventFn, &cap);

            outL[] = 0.0f;
            outR[] = 0.0f;
            cvOutBuf[] = 0.0f;
            verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                desc.vtable.process(inst.state, io, ctx);
            });
            foreach (s; outL) {
                assert(isFinite(s) && fabs(s) < 1e-6f);
            }
            foreach (s; outR) {
                assert(isFinite(s) && fabs(s) < 1e-6f);
            }

            immutable float[6] extremeVals = [0.0f, -1e9f, 1e9f, float.nan, float.infinity, -float.infinity];
            foreach (pIdx, ref p; desc.params) {
                verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                    assert(desc.vtable.setParam(inst.state, cast(uint) pIdx, p.minVal, 44_100.0f, true));
                    assert(desc.vtable.setParam(inst.state, cast(uint) pIdx, p.maxVal, 44_100.0f, false));
                    foreach (evVal; extremeVals) {
                        assert(desc.vtable.setParam(inst.state, cast(uint) pIdx, evVal, 44_100.0f, false));
                    }
                    assert(desc.vtable.setParam(inst.state, cast(uint) pIdx, p.defaultVal, 44_100.0f, true));
                });
            }

            outL[] = 0.0f;
            outR[] = 0.0f;
            io.audioIn[0] = impInL[];
            io.audioIn[1] = impInR[];
            ctx.inputSilent = false;
            verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                sendEvent(inst.desc, inst.state, ModEvent.makeNoteOn(NoteId(1), 60.0f, 1.0f), 44_100.0f);
                desc.vtable.process(inst.state, io, ctx);
                if (desc.vtable.processFeedbackSend !is null) {
                    const(float[])[2] fbIn = [outL[], outR[]];
                    desc.vtable.processFeedbackSend(inst.state, fbIn, ctx);
                }
                sendEvent(inst.desc, inst.state, ModEvent.makeNoteOff(NoteId(1)), 44_100.0f);
            });

            foreach (s; outL) {
                assert(isFinite(s));
            }
            foreach (s; outR) {
                assert(isFinite(s));
            }
        }
    }

    unittest {
        ModuleInstance flt;
        ModuleInstance dst;
        ModuleInstance dly;
        ModuleInstance ech;
        ModuleInstance rev;
        ModuleInstance cmp;
        assert(ModuleRegistry.createOffRT("fx.filter_pro", ModuleId(1), 44_100.0f, flt));
        assert(ModuleRegistry.createOffRT("fx.distortion", ModuleId(2), 44_100.0f, dst));
        assert(ModuleRegistry.createOffRT("fx.delay", ModuleId(3), 44_100.0f, dly));
        assert(ModuleRegistry.createOffRT("fx.echo", ModuleId(4), 44_100.0f, ech));
        assert(ModuleRegistry.createOffRT("fx.reverb", ModuleId(5), 44_100.0f, rev));
        assert(ModuleRegistry.createOffRT("fx.compressor", ModuleId(6), 44_100.0f, cmp));
        scope (exit) {
            flt.destroyOffRT();
            dst.destroyOffRT();
            dly.destroyOffRT();
            ech.destroyOffRT();
            rev.destroyOffRT();
            cmp.destroyOffRT();
        }

        float[FIXED_BLOCK_FRAMES] inL = 0.0f;
        float[FIXED_BLOCK_FRAMES] inR = 0.0f;
        float[FIXED_BLOCK_FRAMES] outL = 0.0f;
        float[FIXED_BLOCK_FRAMES] outR = 0.0f;
        foreach (i; 0 .. FIXED_BLOCK_FRAMES) {
            inL[i] = cast(float) sin(TWO_PI_D * 8000.0 * cast(double) i / 44_100.0);
            inR[i] = inL[i];
        }

        flt.desc.vtable.setParam(flt.state, 0, 0.0f, 44_100.0f, true);
        flt.desc.vtable.setParam(flt.state, 2, 200.0f, 44_100.0f, true);
        ProcessIO io;
        io.audioIn = [inL[], inR[]];
        io.audioOut = [outL[], outR[]];
        ProcessContext ctx;
        ctx.sampleRate = 44_100.0f;
        ctx.frames = FIXED_BLOCK_FRAMES;
        foreach (_; 0 .. 10) {
            assert(flt.desc.vtable.process(flt.state, io, ctx));
        }
        assert(fabs(outL[FIXED_BLOCK_FRAMES - 1]) < 0.05f);

        dst.desc.vtable.setParam(dst.state, 1, 10.0f, 44_100.0f, true);
        dst.desc.vtable.setParam(dst.state, 3, 4.0f, 44_100.0f, true);
        assert(dst.desc.vtable.process(dst.state, io, ctx));
        assert(fabs(outL[0] - outL[1]) < 1e-6f);

        dly.desc.vtable.setParam(dly.state, 0, 0.0f, 44_100.0f, true);
        dly.desc.vtable.setParam(dly.state, 1, 1.0f, 44_100.0f, true);
        dly.desc.vtable.setParam(dly.state, 2, 2.0f, 44_100.0f, true);
        dly.desc.vtable.setParam(dly.state, 3, 2.0f, 44_100.0f, true);
        inL[] = 0.0f;
        inR[] = 0.0f;
        inL[0] = 1.0f;
        inR[0] = 1.0f;
        dly.desc.vtable.process(dly.state, io, ctx);
        assert(fabs(outL[0]) < 1e-5f);
        float maxTail = 0.0f;
        foreach (_; 0 .. 5) {
            inL[0] = 0.0f;
            inR[0] = 0.0f;
            dly.desc.vtable.process(dly.state, io, ctx);
            foreach (s; outL) {
                if (fabs(s) > maxTail) maxTail = fabs(s);
            }
        }
        assert(maxTail > 0.3f);

        inL[] = 0.0f;
        inR[] = 0.0f;
        inL[0] = 1.0f;
        inR[0] = -1.0f;
        ech.desc.vtable.setParam(ech.state, 3, 2.0f, 44_100.0f, true);
        ech.desc.vtable.setParam(ech.state, 4, 1.0f, 44_100.0f, true);
        ech.desc.vtable.process(ech.state, io, ctx);
        inL[0] = 0.0f;
        inR[0] = 0.0f;
        ech.desc.vtable.process(ech.state, io, ctx);
        foreach (_; 0 .. 4) {
            ech.desc.vtable.process(ech.state, io, ctx);
        }

        inL[0] = 1.0f;
        inR[0] = 0.5f;
        rev.desc.vtable.setParam(rev.state, 6, 1.0f, 44_100.0f, true);
        rev.desc.vtable.process(rev.state, io, ctx);
        inL[0] = 0.0f;
        inR[0] = 0.0f;
        bool revActive = false;
        foreach (_; 0 .. 40) {
            revActive = rev.desc.vtable.process(rev.state, io, ctx);
        }
        assert(revActive);
        rev.desc.vtable.reset(rev.state);
        ctx.inputSilent = true;
        rev.desc.vtable.setParam(rev.state, 6, 0.0f, 44_100.0f, true);
        assert(!rev.desc.vtable.process(rev.state, io, ctx));

        float[FIXED_BLOCK_FRAMES] scHot = 0.9f;
        float[FIXED_BLOCK_FRAMES] carrier = 0.5f;
        io.audioIn = [carrier[], carrier[]];
        io.sidechainIn = [scHot[], scHot[]];
        io.sidechainConnected = true;
        io.sidechainSilent = false;
        ctx.inputSilent = false;
        cmp.desc.vtable.setParam(cmp.state, 0, -24.0f, 44_100.0f, true);
        cmp.desc.vtable.setParam(cmp.state, 1, 10.0f, 44_100.0f, true);
        foreach (_; 0 .. 20) {
            cmp.desc.vtable.process(cmp.state, io, ctx);
        }
        assert(outL[FIXED_BLOCK_FRAMES - 1] < 0.25f);
    }

    unittest {
        ModuleInstance msInst;
        ModuleInstance mcInst;
        ModuleInstance adsrInst;
        ModuleInstance lfoInst;
        assert(ModuleRegistry.createOffRT("ctl.multisynth", ModuleId(1), 44_100.0f, msInst));
        assert(ModuleRegistry.createOffRT("ctl.multictl", ModuleId(2), 44_100.0f, mcInst));
        assert(ModuleRegistry.createOffRT("ctl.adsr", ModuleId(3), 44_100.0f, adsrInst));
        assert(ModuleRegistry.createOffRT("fx.lfo", ModuleId(4), 44_100.0f, lfoInst));
        scope (exit) {
            msInst.destroyOffRT();
            mcInst.destroyOffRT();
            adsrInst.destroyOffRT();
            lfoInst.destroyOffRT();
        }

        MultiSynthCurveAsset* msCurve = MultiSynthCurveAsset.createOffRT();
        assert(msCurve !is null);
        msCurve.velCurve[127] = 0.5f;
        msCurve.pitchOffset[60] = 7.0f;
        void* oldAsset = null;
        assert(msInst.desc.vtable.swapAsset(msInst.state, 0, msCurve, oldAsset) && oldAsset is null);
        msInst.desc.vtable.setParam(msInst.state, 0, 12.0f, 44_100.0f, true);
        msInst.desc.vtable.setParam(msInst.state, 4, 2.0f, 44_100.0f, true);

        EventCaptureBox cap;
        ProcessIO io;
        ProcessContext ctx;
        ctx.sampleRate = 44_100.0f;
        ctx.frames = FIXED_BLOCK_FRAMES;
        ctx.eventOut = EventSink(&captureEventFn, &cap);

        sendEvent(msInst.desc, msInst.state, ModEvent.makeNoteOn(NoteId(1), 60.0f, 1.0f), 44_100.0f);
        assert(msInst.desc.vtable.process(msInst.state, io, ctx) && cap.count == 1);
        assert(fabs(cap.events[0].valueA - 79.0f) < 1e-4f && fabs(cap.events[0].valueB - 0.5f) < 1e-4f);

        ubyte[] msBlob;
        assert(msInst.desc.vtable.serializeExtra(msInst.state, msBlob) && msBlob.length > 0);
        assert(msInst.desc.vtable.deserializeExtra(msInst.state, msBlob, 44_100.0f));

        MultiCtlMapAsset* mcMap = MultiCtlMapAsset.createOffRT();
        assert(mcMap !is null);
        mcMap.targets[1] = typeof(mcMap.targets[1])(3, 100.0f, 500.0f, true);
        assert(mcInst.desc.vtable.swapAsset(mcInst.state, 0, mcMap, oldAsset));
        cap.count = 0;
        mcInst.desc.vtable.setParam(mcInst.state, 0, 0.5f, 44_100.0f, true);
        assert(mcInst.desc.vtable.process(mcInst.state, io, ctx) && cap.count == 2);
        assert(cap.events[1].paramId == 3 && fabs(cap.events[1].valueA - 300.0f) < 1e-2f);

        float[FIXED_BLOCK_FRAMES] cvOut = 0.0f;
        float[FIXED_BLOCK_FRAMES] aL = 0.0f;
        float[FIXED_BLOCK_FRAMES] aR = 0.0f;
        io.audioOut = [aL[], aR[]];
        io.numCvOut = 1;
        io.cvOut[0].samples = cvOut[];
        io.cvOut[0].active = true;
        sendEvent(adsrInst.desc, adsrInst.state, ModEvent.makeNoteOn(NoteId(2), 60.0f, 1.0f), 44_100.0f);
        assert(adsrInst.desc.vtable.process(adsrInst.state, io, ctx) && cvOut[FIXED_BLOCK_FRAMES - 1] > 0.05f);

        lfoInst.desc.vtable.setParam(lfoInst.state, 1, 20.0f, 44_100.0f, true);
        assert(lfoInst.desc.vtable.process(lfoInst.state, io, ctx));
        assert(fabs(cvOut[10]) > 1e-4f);
    }

    /**
     * Plays one note on an ADSR module and collects its CV output.
     *
     * Params:
     *   desc = Descriptor of the module.
     *   state = State of the module.
     *   velocity = Note-on velocity; a value below 0 sends no note-on.
     *   blocks = Number of 64-frame blocks to process.
     *   noteOffBlock = Block before which the note-off is sent; -1 sends none.
     *   lastProduced = Receives what the last process call returned.
     *
     * Returns:
     *   blocks * 64 CV samples; index 0 is the first sample after the note-on.
     */
    private float[] renderAdsr(const(ModuleDescriptor)* desc, void* state, float velocity, uint blocks,
            int noteOffBlock, out bool lastProduced) {
        float[FIXED_BLOCK_FRAMES] cv = 0.0f;
        float[FIXED_BLOCK_FRAMES] left = 0.0f;
        float[FIXED_BLOCK_FRAMES] right = 0.0f;
        ProcessIO io;
        ProcessContext ctx;
        ctx.sampleRate = 44_100.0f;
        ctx.frames = FIXED_BLOCK_FRAMES;
        io.audioOut = [left[], right[]];
        io.numCvOut = 1;
        io.cvOut[0].samples = cv[];
        io.cvOut[0].active = true;
        float[] samples;
        if (velocity >= 0.0f) {
            sendEvent(desc, state, ModEvent.makeNoteOn(NoteId(1), 60.0f, velocity), 44_100.0f);
        }
        foreach (block; 0 .. blocks) {
            if (cast(int) block == noteOffBlock) {
                sendEvent(desc, state, ModEvent.makeNoteOff(NoteId(1)), 44_100.0f);
            }
            lastProduced = desc.vtable.process(state, io, ctx);
            foreach (i; 0 .. FIXED_BLOCK_FRAMES) {
                assert(left[i] == cv[i] && right[i] == cv[i]);
            }
            samples ~= cv[];
        }
        return samples;
    }

    /**
     * Applies the acceptance-table ADSR timings (Attack 10 ms, Decay 20 ms, Sustain 0.5, Release 40 ms).
     *
     * Params:
     *   inst = Instance of the ADSR module.
     *   mode = Mode parameter value: 0 Gated, 1 One-Shot, 2 Inverted.
     */
    private void setAdsrShape(ref ModuleInstance inst, float mode) {
        assert(inst.desc.vtable.setParam(inst.state, 0, 10.0f, 44_100.0f, true));
        assert(inst.desc.vtable.setParam(inst.state, 1, 20.0f, 44_100.0f, true));
        assert(inst.desc.vtable.setParam(inst.state, 2, 0.5f, 44_100.0f, true));
        assert(inst.desc.vtable.setParam(inst.state, 3, 40.0f, 44_100.0f, true));
        assert(inst.desc.vtable.setParam(inst.state, 4, mode, 44_100.0f, true));
    }

    unittest {
        bool produced = false;

        ModuleInstance gatedHold;
        assert(ModuleRegistry.createOffRT("ctl.adsr", ModuleId(1), 44_100.0f, gatedHold));
        scope (exit) gatedHold.destroyOffRT();
        setAdsrShape(gatedHold, 0.0f);

        float[] held = renderAdsr(gatedHold.desc, gatedHold.state, 1.0f, 51, -1, produced);
        assert(fabs(held[219] - 0.4989f) < 1e-3f);
        assert(fabs(held[882] - 0.75f) < 1e-3f);
        assert(fabs(held[3200] - 0.5f) < 1e-3f);
        assert(produced);

        ModuleInstance gatedOff;
        assert(ModuleRegistry.createOffRT("ctl.adsr", ModuleId(2), 44_100.0f, gatedOff));
        scope (exit) gatedOff.destroyOffRT();
        setAdsrShape(gatedOff, 0.0f);

        float[] released = renderAdsr(gatedOff.desc, gatedOff.state, 1.0f, 69, 40, produced);
        assert(fabs(released[2000] - 0.5f) < 1e-3f);
        assert(fabs(released[3441] - 0.25f) < 1e-3f);
        assert(fabs(released[4400]) < 1e-3f);
        assert(!produced);

        ModuleInstance gatedIdle;
        assert(ModuleRegistry.createOffRT("ctl.adsr", ModuleId(3), 44_100.0f, gatedIdle));
        scope (exit) gatedIdle.destroyOffRT();
        setAdsrShape(gatedIdle, 0.0f);

        float[] silent = renderAdsr(gatedIdle.desc, gatedIdle.state, -1.0f, 1, -1, produced);
        foreach (s; silent) {
            assert(fabs(s) < 1e-6f);
        }
        assert(!produced);
    }

    unittest {
        bool produced = false;

        ModuleInstance oneShot;
        assert(ModuleRegistry.createOffRT("ctl.adsr", ModuleId(1), 44_100.0f, oneShot));
        scope (exit) oneShot.destroyOffRT();
        setAdsrShape(oneShot, 1.0f);

        float[] fired = renderAdsr(oneShot.desc, oneShot.state, 1.0f, 51, -1, produced);
        assert(fabs(fired[219] - 0.4989f) < 1e-3f);
        assert(fabs(fired[882] - 0.75f) < 1e-3f);
        assert(fabs(fired[1500] - 0.4501f) < 1e-3f);
        assert(fabs(fired[2206] - 0.25f) < 1e-3f);
        assert(fabs(fired[3200]) < 1e-3f);
        assert(!produced);
        float loudest = 0.0f;
        foreach (s; fired) {
            if (fabs(s) > loudest) loudest = fabs(s);
        }
        assert(loudest >= 0.99f);

        ModuleInstance oneShotIgnored;
        assert(ModuleRegistry.createOffRT("ctl.adsr", ModuleId(2), 44_100.0f, oneShotIgnored));
        scope (exit) oneShotIgnored.destroyOffRT();
        setAdsrShape(oneShotIgnored, 1.0f);

        float[] unheld = renderAdsr(oneShotIgnored.desc, oneShotIgnored.state, 1.0f, 51, 2, produced);
        assert(fabs(unheld[882] - 0.75f) < 1e-3f);

        ModuleInstance oneShotQuiet;
        assert(ModuleRegistry.createOffRT("ctl.adsr", ModuleId(3), 44_100.0f, oneShotQuiet));
        scope (exit) oneShotQuiet.destroyOffRT();
        setAdsrShape(oneShotQuiet, 1.0f);

        float[] half = renderAdsr(oneShotQuiet.desc, oneShotQuiet.state, 0.5f, 14, -1, produced);
        assert(fabs(half[882] - 0.375f) < 1e-3f);
    }

    unittest {
        bool produced = false;

        ModuleInstance invertedIdle;
        assert(ModuleRegistry.createOffRT("ctl.adsr", ModuleId(1), 44_100.0f, invertedIdle));
        scope (exit) invertedIdle.destroyOffRT();
        setAdsrShape(invertedIdle, 2.0f);

        float[] resting = renderAdsr(invertedIdle.desc, invertedIdle.state, -1.0f, 1, -1, produced);
        foreach (s; resting) {
            assert(fabs(s - 1.0f) < 1e-6f);
        }
        assert(produced);

        ModuleInstance invertedHeld;
        assert(ModuleRegistry.createOffRT("ctl.adsr", ModuleId(2), 44_100.0f, invertedHeld));
        scope (exit) invertedHeld.destroyOffRT();
        setAdsrShape(invertedHeld, 2.0f);

        float[] rising = renderAdsr(invertedHeld.desc, invertedHeld.state, 1.0f, 51, -1, produced);
        assert(fabs(rising[219] - 0.5011f) < 1e-3f);
        assert(fabs(rising[882] - 0.25f) < 1e-3f);

        ModuleInstance invertedOff;
        assert(ModuleRegistry.createOffRT("ctl.adsr", ModuleId(3), 44_100.0f, invertedOff));
        scope (exit) invertedOff.destroyOffRT();
        setAdsrShape(invertedOff, 2.0f);

        float[] falling = renderAdsr(invertedOff.desc, invertedOff.state, 1.0f, 69, 40, produced);
        assert(fabs(falling[2000] - 0.5f) < 1e-3f);
        assert(fabs(falling[3441] - 0.75f) < 1e-3f);
        assert(fabs(falling[4400] - 1.0f) < 1e-3f);
        assert(produced);
    }

    unittest {
        ModuleInstance kick;
        ModuleInstance drum;
        ModuleInstance analog;
        ModuleInstance fm;
        ModuleInstance samp;
        ModuleInstance spec;
        assert(ModuleRegistry.createOffRT("synth.kicker", ModuleId(1), 44_100.0f, kick));
        assert(ModuleRegistry.createOffRT("synth.drumsynth", ModuleId(2), 44_100.0f, drum));
        assert(ModuleRegistry.createOffRT("synth.analog_gen", ModuleId(3), 44_100.0f, analog));
        assert(ModuleRegistry.createOffRT("synth.fm_synth", ModuleId(4), 44_100.0f, fm));
        assert(ModuleRegistry.createOffRT("synth.sampler", ModuleId(5), 44_100.0f, samp));
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(6), 44_100.0f, spec));
        scope (exit) {
            kick.destroyOffRT();
            drum.destroyOffRT();
            analog.destroyOffRT();
            fm.destroyOffRT();
            samp.destroyOffRT();
            spec.destroyOffRT();
        }

        float[FIXED_BLOCK_FRAMES] outL = 0.0f;
        float[FIXED_BLOCK_FRAMES] outR = 0.0f;
        ProcessIO io;
        io.audioOut = [outL[], outR[]];
        ProcessContext ctx;
        ctx.sampleRate = 44_100.0f;
        ctx.frames = FIXED_BLOCK_FRAMES;
        ctx.inputSilent = true;

        foreach (inst; [kick, drum, analog, fm, spec]) {
            sendEvent(inst.desc, inst.state, ModEvent.makeNoteOn(NoteId(1), 60.0f, 0.9f), 44_100.0f);
            assert(inst.desc.vtable.process(inst.state, io, ctx));
            float peak = 0.0f;
            foreach (s; outL) {
                assert(isFinite(s));
                if (fabs(s) > peak) peak = fabs(s);
            }
            assert(peak > 0.01f);
        }

        float[128] drawnCycle = 0.0f;
        foreach (i; 0 .. 128) {
            drawnCycle[i] = cast(float) sin(TWO_PI_D * cast(double) i / 128.0);
        }
        DrawnWaveAsset* wave1 = DrawnWaveAsset.createOffRT(drawnCycle[]);
        assert(wave1 !is null);
        void* oldWave = null;
        assert(analog.desc.vtable.swapAsset(analog.state, 0, wave1, oldWave) && oldWave is null);
        analog.desc.vtable.setParam(analog.state, 0, 5.0f, 44_100.0f, true);
        analog.desc.vtable.setParam(analog.state, 1, 3.0f, 44_100.0f, true);
        assert(analog.desc.vtable.process(analog.state, io, ctx));
        ubyte[] analogBlob;
        assert(analog.desc.vtable.serializeExtra(analog.state, analogBlob) && analogBlob.length == 128 * float.sizeof);

        SpectraTableAsset* specTbl = SpectraTableAsset.buildHarmonicTable(2, 0.7f, 1024);
        assert(specTbl !is null);
        void* oldSpec = null;
        assert(spec.desc.vtable.swapAsset(spec.state, 0, specTbl, oldSpec) && oldSpec is null);
        SpectraTableAsset.destroyErased(oldSpec);
        assert(spec.desc.vtable.process(spec.state, io, ctx));

        float[256] wavLeft = 0.0f;
        float[256] wavRight = 0.0f;
        foreach (i; 0 .. 256) {
            wavLeft[i] = cast(float) sin(TWO_PI_D * 440.0 * cast(double) i / 44_100.0);
            wavRight[i] = wavLeft[i] * 0.5f;
        }
        ubyte[] wavPayload;
        string err;
        const(float)[][2] chs = [wavLeft[], wavRight[]];
        assert(writeWavMemory(chs[], 44_100, wavPayload, err));
        SamplerSlotAsset* decodedSlot = createSamplerAssetFromMemory(wavPayload, err, 60);
        assert(decodedSlot !is null);
        decodedSlot.loopStart = 32;
        decodedSlot.loopEnd = 160;
        decodedSlot.volEnv[0] = EnvBreakpoint(0.0f, 0.0f, 1.0f);
        decodedSlot.volEnv[1] = EnvBreakpoint(0.002f, 1.0f, 1.0f);
        decodedSlot.volEnv[2] = EnvBreakpoint(0.05f, 0.0f, 1.0f);
        decodedSlot.volEnvCount = 3;
        decodedSlot.volSustainIdx = 1;

        void* oldSlot = null;
        assert(samp.desc.vtable.swapAsset(samp.state, 0, decodedSlot, oldSlot) && oldSlot is null);
        samp.desc.vtable.setParam(samp.state, 4, 2.0f, 44_100.0f, true);
        sendEvent(samp.desc, samp.state, ModEvent.makeNoteOn(NoteId(5), 60.0f, 1.0f), 44_100.0f);
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            foreach (_; 0 .. 12) {
                assert(samp.desc.vtable.process(samp.state, io, ctx));
            }
        });
        ubyte[] sampBlob;
        assert(samp.desc.vtable.serializeExtra(samp.state, sampBlob) && sampBlob.length > 0);
        assert(samp.desc.vtable.deserializeExtra(samp.state, sampBlob, 44_100.0f));
    }

    /**
     * Plays note 60 on a SpectraVoice module and collects the left-channel output.
     *
     * Params:
     *   desc = Descriptor of the module.
     *   state = State of the module.
     *   blocks = Number of 64-frame blocks to process.
     *   noteOn = True sends a note-on before the first block.
     *
     * Returns:
     *   blocks * 64 left-channel samples; index 0 is the first processed sample.
     */
    private float[] playSpectra(const(ModuleDescriptor)* desc, void* state, uint blocks, bool noteOn) {
        float[FIXED_BLOCK_FRAMES] left = 0.0f;
        float[FIXED_BLOCK_FRAMES] right = 0.0f;
        ProcessIO io;
        io.audioOut = [left[], right[]];
        ProcessContext ctx;
        ctx.sampleRate = 44_100.0f;
        ctx.frames = FIXED_BLOCK_FRAMES;
        ctx.inputSilent = true;
        float[] samples;
        if (noteOn) {
            sendEvent(desc, state, ModEvent.makeNoteOn(NoteId(1), 60.0f, 0.9f), 44_100.0f);
        }
        foreach (_; 0 .. blocks) {
            assert(desc.vtable.process(state, io, ctx));
            samples ~= left[];
        }
        return samples;
    }

    unittest {
        assert(harmonicCount(0.05f) == 6);
        assert(harmonicCount(0.35f) == 19);
        assert(harmonicCount(0.6f) == 30);
        assert(harmonicCount(1.0f) == 48);
        assert(harmonicCount(float.nan) == 19);
        assert(harmonicCount(-3.0f) == 6);
        assert(harmonicCount(9.0f) == 48);

        assert(SpectraTableBank.TABLE_COUNT == 172);
        SpectraTableBank* bank = SpectraTableBank.build();
        assert(bank !is null);
        scope (exit) SpectraTableBank.destroyErased(bank);
        assert(bank.tables.length == 352_256);
    }

    unittest {
        SpectraTableBank* bank = SpectraTableBank.build();
        assert(bank !is null);
        scope (exit) SpectraTableBank.destroyErased(bank);

        foreach (p; 0 .. 4) {
            foreach (n; 0 .. 96) {
                immutable float bw = 0.05f + cast(float) n * 0.01f;
                SpectraTableAsset* asset = SpectraTableAsset.buildHarmonicTable(p, bw);
                assert(asset !is null);
                assert(bank.table(p, bw) == asset.wavetable[]);
                SpectraTableAsset.destroyErased(asset);
            }
        }

        assert(bank.table(0, 0.35f) == bank.table(0, 1.0f));
        assert(bank.table(0, 0.05f) != bank.table(0, 0.35f));
        assert(bank.table(1, 0.35f) != bank.table(1, 1.0f));
        assert(bank.table(7, 0.35f) == bank.table(3, 0.35f));
    }

    unittest {
        ModuleInstance organ;
        ModuleInstance brass;
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(1), 44_100.0f, organ));
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(2), 44_100.0f, brass));
        scope (exit) {
            organ.destroyOffRT();
            brass.destroyOffRT();
        }
        assert(brass.desc.vtable.setParam(brass.state, 0, 1.0f, 44_100.0f, true));

        float[] organSound = playSpectra(organ.desc, organ.state, 40, true);
        float[] brassSound = playSpectra(brass.desc, brass.state, 40, true);
        assert(organSound.length == 40 * FIXED_BLOCK_FRAMES && brassSound.length == organSound.length);

        float sumDiff = 0.0f;
        float organPeak = 0.0f;
        float brassPeak = 0.0f;
        foreach (i; 0 .. organSound.length) {
            immutable float d = fabs(organSound[i] - brassSound[i]);
            sumDiff += d;
            if (fabs(organSound[i]) > organPeak) organPeak = fabs(organSound[i]);
            if (fabs(brassSound[i]) > brassPeak) brassPeak = fabs(brassSound[i]);
        }
        assert(sumDiff > 1.0f);
        assert(brassPeak > 0.5f && organPeak > 0.5f);

        ModuleInstance swapped;
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(3), 44_100.0f, swapped));
        scope (exit) swapped.destroyOffRT();
        SpectraTableAsset* brassTable = SpectraTableAsset.buildHarmonicTable(1, 0.35f);
        assert(brassTable !is null);
        void* oldAsset = null;
        assert(swapped.desc.vtable.swapAsset(swapped.state, 0, brassTable, oldAsset) && oldAsset is null);
        float[] swappedSound = playSpectra(swapped.desc, swapped.state, 40, true);
        assert(brassSound == swappedSound);
    }

    unittest {
        ModuleInstance changed;
        ModuleInstance untouched;
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(1), 44_100.0f, changed));
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(2), 44_100.0f, untouched));
        scope (exit) {
            changed.destroyOffRT();
            untouched.destroyOffRT();
        }

        float[] first = playSpectra(changed.desc, changed.state, 20, true);
        float[] twin = playSpectra(untouched.desc, untouched.state, 20, true);
        assert(first == twin);
        assert(changed.desc.vtable.setParam(changed.state, 0, 3.0f, 44_100.0f, true));
        float[] after = playSpectra(changed.desc, changed.state, 20, false);
        float[] afterTwin = playSpectra(untouched.desc, untouched.state, 20, false);
        assert(after != afterTwin);

        ModuleInstance brassLow;
        ModuleInstance brassHigh;
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(3), 44_100.0f, brassLow));
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(4), 44_100.0f, brassHigh));
        scope (exit) {
            brassLow.destroyOffRT();
            brassHigh.destroyOffRT();
        }
        assert(brassLow.desc.vtable.setParam(brassLow.state, 0, 1.0f, 44_100.0f, true));
        assert(brassHigh.desc.vtable.setParam(brassHigh.state, 0, 1.0f, 44_100.0f, true));
        assert(brassHigh.desc.vtable.setParam(brassHigh.state, 1, 1.0f, 44_100.0f, true));

        float[] lowSound = playSpectra(brassLow.desc, brassLow.state, 40, true);
        float[] highSound = playSpectra(brassHigh.desc, brassHigh.state, 40, true);
        assert(lowSound != highSound);
    }

    unittest {
        ModuleInstance spec;
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(1), 44_100.0f, spec));
        scope (exit) spec.destroyOffRT();

        float[FIXED_BLOCK_FRAMES] outL = 0.0f;
        float[FIXED_BLOCK_FRAMES] outR = 0.0f;
        ProcessIO io;
        io.audioOut = [outL[], outR[]];
        ProcessContext ctx;
        ctx.sampleRate = 44_100.0f;
        ctx.frames = FIXED_BLOCK_FRAMES;
        ctx.inputSilent = true;

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            sendEvent(spec.desc, spec.state, ModEvent.makeNoteOn(NoteId(1), 60.0f, 0.9f), 44_100.0f);
            assert(spec.desc.vtable.setParam(spec.state, 0, 1.0f, 44_100.0f, true));
            assert(spec.desc.vtable.setParam(spec.state, 1, 0.9f, 44_100.0f, false));
            assert(spec.desc.vtable.process(spec.state, io, ctx));
        });

        float peak = 0.0f;
        foreach (s; outL) {
            assert(isFinite(s));
            if (fabs(s) > peak) peak = fabs(s);
        }
        assert(peak > 0.01f);
    }

    unittest {
        ModuleInstance fresh;
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(1), 44_100.0f, fresh));
        scope (exit) fresh.destroyOffRT();

        ubyte[] emptyBlob;
        assert(fresh.desc.vtable.serializeExtra(fresh.state, emptyBlob) && emptyBlob.length == 0);

        ubyte[8192] legacy = 0;
        assert(fresh.desc.vtable.deserializeExtra(fresh.state, legacy[], 44_100.0f));
        ubyte[] afterLegacy;
        assert(fresh.desc.vtable.serializeExtra(fresh.state, afterLegacy) && afterLegacy.length == 0);

        ModuleInstance marked;
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(2), 44_100.0f, marked));
        scope (exit) marked.destroyOffRT();

        SpectraTableAsset* tbl = SpectraTableAsset.buildHarmonicTable(1, 0.6f, 2048);
        assert(tbl !is null);
        void* oldAsset = null;
        assert(marked.desc.vtable.swapAsset(marked.state, 0, tbl, oldAsset) && oldAsset is null);
        ubyte[] markedBlob;
        assert(marked.desc.vtable.serializeExtra(marked.state, markedBlob));
        assert(markedBlob.length == 4 + 2048 * float.sizeof);
        immutable ubyte[4] expectedMark = ['S', 'V', 'T', '1'];
        assert(markedBlob[0 .. 4] == expectedMark[]);

        ubyte[] shortMarked = cast(ubyte[])("SVT1") ~ new ubyte[10];
        assert(!marked.desc.vtable.deserializeExtra(marked.state, shortMarked, 44_100.0f));
    }

    unittest {
        ModuleInstance fading;
        ModuleInstance pureBell;
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(1), 44_100.0f, fading));
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(2), 44_100.0f, pureBell));
        scope (exit) {
            fading.destroyOffRT();
            pureBell.destroyOffRT();
        }
        assert(pureBell.desc.vtable.setParam(pureBell.state, 0, 3.0f, 44_100.0f, true));

        float[] before = playSpectra(fading.desc, fading.state, 20, true);
        float[] bellBefore = playSpectra(pureBell.desc, pureBell.state, 20, true);
        assert(before != bellBefore);

        float[FIXED_BLOCK_FRAMES] rtL = 0.0f;
        float[FIXED_BLOCK_FRAMES] rtR = 0.0f;
        ProcessIO rtIo;
        rtIo.audioOut = [rtL[], rtR[]];
        ProcessContext rtCtx;
        rtCtx.sampleRate = 44_100.0f;
        rtCtx.frames = FIXED_BLOCK_FRAMES;
        rtCtx.inputSilent = true;

        float[] transition;
        transition ~= before[$ - FIXED_BLOCK_FRAMES .. $];
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            assert(fading.desc.vtable.setParam(fading.state, 0, 3.0f, 44_100.0f, true));
            assert(fading.desc.vtable.process(fading.state, rtIo, rtCtx));
        });
        transition ~= rtL[];
        float[] afterRest = playSpectra(fading.desc, fading.state, 9, false);
        transition ~= afterRest;

        float maxStep = 0.0f;
        foreach (i; 1 .. transition.length) {
            assert(isFinite(transition[i]));
            immutable float step = fabs(transition[i] - transition[i - 1]);
            if (step > maxStep) maxStep = step;
        }
        assert(maxStep < 0.25f);

        float[] bellAfter = playSpectra(pureBell.desc, pureBell.state, 10, false);
        float[] tailFading = transition[6 * FIXED_BLOCK_FRAMES .. $];
        float[] tailBell = bellAfter[5 * FIXED_BLOCK_FRAMES .. $];
        assert(tailFading.length == tailBell.length);
        foreach (i; 0 .. tailFading.length) {
            assert(fabs(tailFading[i] - tailBell[i]) < 1e-5f);
        }

        ModuleInstance bwFade;
        assert(ModuleRegistry.createOffRT("synth.spectravoice", ModuleId(3), 44_100.0f, bwFade));
        scope (exit) bwFade.destroyOffRT();
        assert(bwFade.desc.vtable.setParam(bwFade.state, 0, 1.0f, 44_100.0f, true));
        assert(bwFade.desc.vtable.setParam(bwFade.state, 1, 0.05f, 44_100.0f, true));
        float[] bwBefore = playSpectra(bwFade.desc, bwFade.state, 20, true);
        float[] bwTrans;
        bwTrans ~= bwBefore[$ - FIXED_BLOCK_FRAMES .. $];
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            assert(bwFade.desc.vtable.setParam(bwFade.state, 1, 1.0f, 44_100.0f, true));
            assert(bwFade.desc.vtable.process(bwFade.state, rtIo, rtCtx));
        });
        bwTrans ~= rtL[];
        bwTrans ~= playSpectra(bwFade.desc, bwFade.state, 5, false);
        float maxBwStep = 0.0f;
        foreach (i; 1 .. bwTrans.length) {
            immutable float step = fabs(bwTrans[i] - bwTrans[i - 1]);
            if (step > maxBwStep) maxBwStep = step;
        }
        assert(maxBwStep < 0.25f);
    }

    unittest {
        ModuleInstance pdInst;
        assert(ModuleRegistry.createOffRT("ctl.pitch_detector", ModuleId(1), 44_100.0f, pdInst));
        scope (exit) pdInst.destroyOffRT();

        EventCaptureBox cap;
        float[FIXED_BLOCK_FRAMES] sineL = 0.0f;
        float[FIXED_BLOCK_FRAMES] sineR = 0.0f;
        float[FIXED_BLOCK_FRAMES] outL = 0.0f;
        float[FIXED_BLOCK_FRAMES] outR = 0.0f;
        ProcessIO io;
        io.audioOut = [outL[], outR[]];
        ProcessContext ctx;
        ctx.sampleRate = 44_100.0f;
        ctx.frames = FIXED_BLOCK_FRAMES;
        ctx.eventOut = EventSink(&captureEventFn, &cap);

        size_t totalSample = 0;
        foreach (_; 0 .. 32) {
            foreach (i; 0 .. FIXED_BLOCK_FRAMES) {
                immutable float s = 0.6f * cast(float) sin(TWO_PI_D * 440.0 * cast(double) totalSample / 44_100.0);
                sineL[i] = s;
                sineR[i] = s;
                totalSample++;
            }
            io.audioIn = [sineL[], sineR[]];
            pdInst.desc.vtable.process(pdInst.state, io, ctx);
        }

        auto typedPd = cast(const(PitchDetector)*) pdInst.state;
        assert(fabs(typedPd.lastDetectedHz() - 440.0f) < 6.0f);
        assert(cap.count > 0 && cap.events[0].kind == ModEventKind.noteOn);
        assert(fabs(cap.events[0].valueA - 69.0f) < 0.35f);
    }

    unittest {
        ModuleInstance eqInst;
        ModuleInstance wsInst;
        ModuleInstance flgInst;
        ModuleInstance vibInst;
        ModuleInstance modInst;
        ModuleInstance smInst;
        ModuleInstance vocInst;
        ModuleInstance psInst;
        ModuleInstance fftInst;
        ModuleInstance lpInst;
        ModuleInstance glInst;
        ModuleInstance c2nInst;
        ModuleInstance p2cInst;
        ModuleInstance v2cInst;
        ModuleInstance s2cInst;
        assert(ModuleRegistry.createOffRT("fx.eq3", ModuleId(1), 44_100.0f, eqInst));
        assert(ModuleRegistry.createOffRT("fx.waveshaper", ModuleId(2), 44_100.0f, wsInst));
        assert(ModuleRegistry.createOffRT("fx.flanger", ModuleId(3), 44_100.0f, flgInst));
        assert(ModuleRegistry.createOffRT("fx.vibrato", ModuleId(4), 44_100.0f, vibInst));
        assert(ModuleRegistry.createOffRT("fx.modulator", ModuleId(5), 44_100.0f, modInst));
        assert(ModuleRegistry.createOffRT("fx.smooth", ModuleId(6), 44_100.0f, smInst));
        assert(ModuleRegistry.createOffRT("fx.vocal_filter", ModuleId(7), 44_100.0f, vocInst));
        assert(ModuleRegistry.createOffRT("fx.pitch_shifter", ModuleId(8), 44_100.0f, psInst));
        assert(ModuleRegistry.createOffRT("fx.fft", ModuleId(9), 44_100.0f, fftInst));
        assert(ModuleRegistry.createOffRT("fx.loop", ModuleId(10), 44_100.0f, lpInst));
        assert(ModuleRegistry.createOffRT("ctl.glide", ModuleId(11), 44_100.0f, glInst));
        assert(ModuleRegistry.createOffRT("ctl.ctl2note", ModuleId(12), 44_100.0f, c2nInst));
        assert(ModuleRegistry.createOffRT("ctl.pitch2ctl", ModuleId(13), 44_100.0f, p2cInst));
        assert(ModuleRegistry.createOffRT("ctl.velocity2ctl", ModuleId(14), 44_100.0f, v2cInst));
        assert(ModuleRegistry.createOffRT("ctl.sound2ctl", ModuleId(15), 44_100.0f, s2cInst));
        scope (exit) {
            eqInst.destroyOffRT();
            wsInst.destroyOffRT();
            flgInst.destroyOffRT();
            vibInst.destroyOffRT();
            modInst.destroyOffRT();
            smInst.destroyOffRT();
            vocInst.destroyOffRT();
            psInst.destroyOffRT();
            fftInst.destroyOffRT();
            lpInst.destroyOffRT();
            glInst.destroyOffRT();
            c2nInst.destroyOffRT();
            p2cInst.destroyOffRT();
            v2cInst.destroyOffRT();
            s2cInst.destroyOffRT();
        }

        float[FIXED_BLOCK_FRAMES] carL = 0.5f;
        float[FIXED_BLOCK_FRAMES] carR = 0.5f;
        float[FIXED_BLOCK_FRAMES] modSig = -1.0f;
        float[FIXED_BLOCK_FRAMES] outL = 0.0f;
        float[FIXED_BLOCK_FRAMES] outR = 0.0f;
        float[FIXED_BLOCK_FRAMES] cvOut = 0.0f;

        WaveShaperCurveAsset* wsCurve = WaveShaperCurveAsset.createOffRT();
        assert(wsCurve !is null);
        void* oldWs = null;
        assert(wsInst.desc.vtable.swapAsset(wsInst.state, 0, wsCurve, oldWs));
        wsInst.desc.vtable.setParam(wsInst.state, 3, 2.0f, 44_100.0f, true);

        ProcessIO io;
        io.audioIn = [carL[], carR[]];
        io.sidechainIn = [modSig[], modSig[]];
        io.sidechainConnected = true;
        io.sidechainSilent = false;
        io.audioOut = [outL[], outR[]];
        io.numCvOut = 1;
        io.cvOut[0].samples = cvOut[];
        io.cvOut[0].active = true;

        EventCaptureBox cap;
        ProcessContext ctx;
        ctx.sampleRate = 44_100.0f;
        ctx.frames = FIXED_BLOCK_FRAMES;
        ctx.eventOut = EventSink(&captureEventFn, &cap);

        modInst.desc.vtable.setParam(modInst.state, 0, 1.0f, 44_100.0f, true);
        assert(modInst.desc.vtable.process(modInst.state, io, ctx));
        assert(fabs(outL[10] + 0.5f) < 1e-4f);

        fftInst.desc.vtable.setParam(fftInst.state, 0, 0.0f, 44_100.0f, true);
        fftInst.desc.vtable.setParam(fftInst.state, 2, 4.0f, 44_100.0f, true);
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            foreach (_; 0 .. 16) {
                fftInst.desc.vtable.process(fftInst.state, io, ctx);
            }
        });

        lpInst.desc.vtable.setParam(lpInst.state, 0, 2.0f, 44_100.0f, true);
        sendEvent(lpInst.desc, lpInst.state, ModEvent.makeNoteOn(NoteId(1), 60.0f, 1.0f), 44_100.0f);
        assert(lpInst.desc.vtable.process(lpInst.state, io, ctx));

        sendEvent(glInst.desc, glInst.state, ModEvent.makeNoteOn(NoteId(1), 48.0f, 1.0f), 44_100.0f);
        glInst.desc.vtable.process(glInst.state, io, ctx);
        sendEvent(glInst.desc, glInst.state, ModEvent.makeNoteOn(NoteId(2), 72.0f, 1.0f), 44_100.0f);
        cap.count = 0;
        assert(glInst.desc.vtable.process(glInst.state, io, ctx) && cap.count >= 1);

        c2nInst.desc.vtable.setParam(c2nInst.state, 0, 0.5f, 44_100.0f, true);
        cap.count = 0;
        assert(c2nInst.desc.vtable.process(c2nInst.state, io, ctx) && cap.count == 1
            && cap.events[0].kind == ModEventKind.noteOn);

        sendEvent(p2cInst.desc, p2cInst.state, ModEvent.makeNoteOn(NoteId(1), 60.0f, 1.0f), 44_100.0f);
        assert(p2cInst.desc.vtable.process(p2cInst.state, io, ctx) && cvOut[0] > 0.4f);

        sendEvent(v2cInst.desc, v2cInst.state, ModEvent.makeNoteOn(NoteId(1), 60.0f, 0.75f), 44_100.0f);
        assert(v2cInst.desc.vtable.process(v2cInst.state, io, ctx) && fabs(cvOut[0] - 0.75f) < 1e-4f);

        foreach (_; 0 .. 16) {
            s2cInst.desc.vtable.process(s2cInst.state, io, ctx);
        }
        assert(cvOut[FIXED_BLOCK_FRAMES - 1] > 0.2f);
    }

    unittest {
        float[4096] srcL = 0.0f;
        float[4096] srcR = 0.0f;
        foreach (i; 0 .. 4096) {
            srcL[i] = 0.6f * cast(float) sin(TWO_PI_D * 330.0 * cast(double) i / 44_100.0);
            srcR[i] = -srcL[i];
        }
        ubyte[] wavStreamBytes;
        string err;
        const(float)[][2] wavChans = [srcL[], srcR[]];
        assert(writeWavMemory(wavChans[], 44_100, wavStreamBytes, err));

        StreamAudioRing* ring = StreamAudioRing.createOffRT(4096);
        assert(ring !is null);
        scope (exit) StreamAudioRing.destroyOffRT(ring);

        scope worker = new StreamWorker();
        scope (exit) worker.shutdown();
        assert(worker.openStreamMemory(wavStreamBytes, ring, err));

        immutable uint asyncJob = worker.enqueueSampleDecodeMemory(wavStreamBytes);
        AsyncSampleResult asyncRes;
        bool asyncDone = false;
        foreach (_; 0 .. 100) {
            if (worker.pollSampleDecodeResult(asyncRes)) {
                asyncDone = true;
                break;
            }
            Thread.sleep(dur!"msecs"(5));
        }
        assert(asyncDone && asyncRes.jobId == asyncJob && asyncRes.success && asyncRes.audio.frames == 4096);

        foreach (_; 0 .. 60) {
            if (ring.bufferedFrames() >= 1024) {
                break;
            }
            Thread.sleep(dur!"msecs"(5));
        }
        assert(ring.bufferedFrames() > 0);

        ModuleInstance vpInst;
        ModuleInstance outInst;
        assert(ModuleRegistry.createOffRT("synth.vorbis_player", ModuleId(1), 44_100.0f, vpInst));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(2), 44_100.0f, outInst));
        scope (exit) {
            vpInst.destroyOffRT();
            outInst.destroyOffRT();
        }

        void* oldRing = null;
        assert(vpInst.desc.vtable.swapAsset(vpInst.state, 0, ring, oldRing));
        vpInst.desc.vtable.setParam(vpInst.state, 1, 12.0f, 44_100.0f, true);
        vpInst.desc.vtable.setParam(vpInst.state, 2, 1.0f, 44_100.0f, true);

        NodeSpec[2] nodes = [NodeSpec.fromInstance(vpInst), NodeSpec.fromInstance(outInst)];
        WireSpec[1] wires = [WireSpec(ModuleId(1), 1, ModuleId(2), 0, 1.0f)];
        GraphPlan* plan = null;
        GraphCompileError gErr;
        assert(GraphCompiler.compile(nodes[], wires[], plan, gErr));

        AudioGraph graph;
        assert(graph.tryInit(44_100.0f));
        graph.swapPlan(plan);
        scope (exit) GraphPlan.destroyOffRT(graph.detachPlan());

        assert(graph.enqueueEvent(ModuleId(1), ModEvent.makeNoteOn(NoteId(1), 60.0f, 1.0f), 0));
        TransportState transport;
        float[256] renderL = 0.0f;
        float[256] renderR = 0.0f;
        float[][2] outs = [renderL[], renderR[]];
        const(float[])[2] ins = [null, null];

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            graph.render(outs, ins, 256, transport);
        });

        float streamPeak = 0.0f;
        foreach (i; 0 .. 256) {
            assert(isFinite(renderL[i]) && isFinite(renderR[i]));
            if (fabs(renderL[i]) > streamPeak) streamPeak = fabs(renderL[i]);
        }
        assert(streamPeak > 0.1f);
        worker.stopStream();
    }

    unittest {
        ModuleInstance inMod;
        ModuleInstance outMod;
        assert(ModuleRegistry.createOffRT("synth.input", ModuleId(1), 44_100.0f, inMod));
        assert(ModuleRegistry.createOffRT("core.output", ModuleId(2), 44_100.0f, outMod));
        scope (exit) {
            inMod.destroyOffRT();
            outMod.destroyOffRT();
        }
        inMod.desc.vtable.setParam(inMod.state, 0, 2.0f, 44_100.0f, true);
        inMod.desc.vtable.setParam(inMod.state, 1, 1.0f, 44_100.0f, true);
        outMod.desc.vtable.setParam(outMod.state, 1, 0.0f, 44_100.0f, true);

        NodeSpec[2] nodes = [NodeSpec.fromInstance(inMod), NodeSpec.fromInstance(outMod)];
        WireSpec[1] wires = [WireSpec(ModuleId(1), 0, ModuleId(2), 0, 1.0f)];
        GraphPlan* plan = null;
        GraphCompileError gErr;
        assert(GraphCompiler.compile(nodes[], wires[], plan, gErr));

        AudioGraph graph;
        assert(graph.tryInit(44_100.0f));
        graph.swapPlan(plan);
        scope (exit) GraphPlan.destroyOffRT(graph.detachPlan());

        float[128] hostInL = 0.25f;
        float[128] hostInR = -0.1f;
        float[128] hostOutL = 0.0f;
        float[128] hostOutR = 0.0f;
        float[][2] outs = [hostOutL[], hostOutR[]];
        const(float[])[2] ins = [hostInL[], hostInR[]];
        TransportState transport;

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            graph.render(outs, ins, 128, transport);
        });
        assert(fabs(hostOutL[64] - 0.5f) < 1e-3f && fabs(hostOutR[64] - 0.5f) < 1e-3f);
    }

    private struct DummyExtensibilityModule {
        enum string typeId = "test.dummy_gain";
        enum string displayName = "Dummy Gain";
        enum ModuleCategory category = ModuleCategory.effect;

        static immutable PortDescriptor[2] ports = [
            PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
            PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
        ];

        @Param("Gain", 0.0f, 2.0f, 0.5f, "x", ParamScale.linear)
        float gain = 0.5f;

        private float lastGain_ = 0.5f;

        @nogc nothrow:

        void prepare(float sampleRate, uint maxSliceFrames) {
            cast(void) sampleRate;
            cast(void) maxSliceFrames;
            lastGain_ = gain;
        }

        void reset() {
            lastGain_ = gain;
        }

        void onParamChanged(string field)(float sampleRate, bool instant) {
            cast(void) sampleRate;
            cast(void) instant;
            static if (field == "gain") {
                lastGain_ = gain;
            }
        }

        bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
            if (ctx.inputSilent) {
                audioOut[0][0 .. ctx.frames] = 0.0f;
                audioOut[1][0 .. ctx.frames] = 0.0f;
                return false;
            }
            foreach (i; 0 .. ctx.frames) {
                audioOut[0][i] = audioIn[0][i] * lastGain_;
                audioOut[1][i] = audioIn[1][i] * lastGain_;
            }
            return true;
        }
    }

    unittest {
        auto desc = &ModuleAdapter!DummyExtensibilityModule.DESCRIPTOR;
        assert(desc.typeId == "test.dummy_gain" && desc.params.length == 1);
        void* st = desc.vtable.create();
        assert(st !is null);
        scope (exit) desc.vtable.destroy(st);
        desc.vtable.prepare(st, 44_100.0f, FIXED_BLOCK_FRAMES);
        assert(desc.vtable.setParam(st, 0, 1.5f, 44_100.0f, true));

        float[FIXED_BLOCK_FRAMES] inL = 0.4f;
        float[FIXED_BLOCK_FRAMES] inR = -0.2f;
        float[FIXED_BLOCK_FRAMES] outL = 0.0f;
        float[FIXED_BLOCK_FRAMES] outR = 0.0f;
        ProcessIO io;
        io.audioIn = [inL[], inR[]];
        io.audioOut = [outL[], outR[]];
        ProcessContext ctx;
        ctx.sampleRate = 44_100.0f;
        ctx.frames = FIXED_BLOCK_FRAMES;
        assert(desc.vtable.process(st, io, ctx));
        assert(fabs(outL[0] - 0.6f) < 1e-5f && fabs(outR[0] + 0.3f) < 1e-5f);
    }

    unittest {
        ModuleInstance fm;
        assert(ModuleRegistry.createOffRT("synth.fm_synth", ModuleId(40), 44_100.0f, fm));
        scope (exit) fm.destroyOffRT();

        fm.desc.vtable.setParam(fm.state, 12, 1.0f, 44_100.0f, true);
        fm.desc.vtable.setParam(fm.state, 13, 10.0f, 44_100.0f, true);
        fm.desc.vtable.setParam(fm.state, 14, 1.0f, 44_100.0f, true);
        fm.desc.vtable.setParam(fm.state, 15, 200.0f, 44_100.0f, true);

        sendEvent(fm.desc, fm.state, ModEvent.makeNoteOn(NoteId(1), 60.0f, 1.0f), 44_100.0f);

        float[FIXED_BLOCK_FRAMES] outL = 0.0f;
        float[FIXED_BLOCK_FRAMES] outR = 0.0f;
        ProcessIO io;
        io.audioOut = [outL[], outR[]];
        ProcessContext ctx;
        ctx.sampleRate = 44_100.0f;
        ctx.frames = FIXED_BLOCK_FRAMES;
        ctx.inputSilent = true;

        double susSq = 0.0;
        size_t susN = 0;
        foreach (b; 0 .. 40) {
            assert(fm.desc.vtable.process(fm.state, io, ctx));
            if (b >= 30) {
                foreach (s; outL) {
                    susSq += cast(double) s * s;
                    susN++;
                }
            }
        }
        immutable double susRms = sqrt(susSq / cast(double) susN);
        assert(susRms > 0.05);

        sendEvent(fm.desc, fm.state, ModEvent.makeNoteOff(NoteId(1)), 44_100.0f);
        size_t released = 0;
        double qSq = 0.0;
        size_t qN = 0;
        immutable size_t qStart = cast(size_t)(0.050 * 44_100.0);
        immutable size_t qEnd = cast(size_t)(0.065 * 44_100.0);
        while (released < cast(size_t)(0.22 * 44_100.0)) {
            fm.desc.vtable.process(fm.state, io, ctx);
            foreach (i; 0 .. FIXED_BLOCK_FRAMES) {
                immutable size_t pos = released + i;
                if (pos >= qStart && pos < qEnd) {
                    qSq += cast(double) outL[i] * outL[i];
                    qN++;
                }
            }
            released += FIXED_BLOCK_FRAMES;
        }
        immutable double quarterRms = sqrt(qSq / cast(double) qN);
        assert(quarterRms < susRms * 0.5, "FM Synth release should drop below half before a quarter of release time");
        assert(!fm.desc.vtable.process(fm.state, io, ctx));
        foreach (i; 0 .. FIXED_BLOCK_FRAMES) {
            assert(outL[i] == 0.0f && outR[i] == 0.0f);
        }
    }
}
