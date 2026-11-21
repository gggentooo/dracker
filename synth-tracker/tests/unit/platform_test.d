/**
 * File:         tests/unit/platform_test.d
 * Module:       tests.unit.platform_test
 * Phase:        Phase 3 — Native macOS Audio & MIDI Verification Suite
 *
 * Purpose:
 *   Verifies platform interfaces, CoreFoundation UTF-8/MachTimebase helpers, DriftCompensatedInputRing resampling/clock-drift stability, unregistered-thread CoreAudio callback RT safety under rt_malloc_trap, CoreMIDI packet-list alignment parsing, multi-thread MpscRing aggregation, and live hardware audio/MIDI loopback smoke checks.
 *
 * Real-Time & Safety Contract:
 *   RT callback tests execute inside verifyZeroRtAllocationsNothrow (rt_malloc_trap) guaranteeing zero C heap calls and zero D GC entry.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.concurrency, foundation.math_rt, foundation.memory, graph.event, graph.module_api, graph.plan, graph.audio_graph, graph.registry, modules.effects.amplifier, platform.interfaces, platform.macos.corefoundation, platform.macos.coreaudio, platform.macos.coremidi, tests.rt_malloc_trap
 *   External: core.lifetime, core.stdc.stdlib, core.stdc.string, core.thread, core.time, std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites for interfaces, CoreFoundation, DriftCompensatedInputRing, CoreAudio RT callback, CoreMIDI parser/MPSC, and live macOS hardware tests
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.platform_test;

version (unittest) {
    import core.lifetime : emplace;
    import core.stdc.stdlib : calloc, free;
    import core.stdc.string : memcpy;
    import core.thread : Thread;
    import core.time : dur, MonoTime;
    import std.math : fabs, isFinite, sin;

    import foundation.concurrency : Atomic, MpscRing;
    import foundation.math_rt : ScopedNoDenormals;
    import foundation.memory : OwnedBuffer;
    import foundation.types : FIXED_BLOCK_FRAMES, ModuleId, NoteId, StereoFrame;
    import graph.audio_graph : AudioGraph;
    import graph.context : TransportState;
    import graph.event : ModEvent, ModEventKind;
    import graph.module_api : ModuleInstance;
    import graph.plan : GraphCompileError, GraphCompiler, GraphPlan, NodeSpec, WireSpec;
    import graph.registry : ModuleRegistry;
    import platform.interfaces;
    import tests.rt_malloc_trap : verifyZeroRtAllocationsNothrow;

    version (OSX) {
        import platform.macos.coreaudio;
        import platform.macos.corefoundation;
        import platform.macos.coremidi;
    }

    unittest {
        immutable MidiPacket onPkt = MidiPacket.makeNoteOn(2, 60, 100, 1234, 7);
        assert(onPkt.isNoteOn() && !onPkt.isNoteOff());
        assert(onPkt.channel() == 2 && onPkt.data1() == 60 && onPkt.data2() == 100);
        assert(onPkt.timestamp == 1234 && onPkt.sourceId == 7);

        immutable MidiPacket zeroVelOn = MidiPacket.makeNoteOn(2, 60, 0);
        assert(zeroVelOn.isNoteOff() && !zeroVelOn.isNoteOn());

        immutable MidiPacket offPkt = MidiPacket.makeNoteOff(2, 60, 64);
        assert(offPkt.isNoteOff());

        immutable MidiPacket ccPkt = MidiPacket.makeControlChange(0, 74, 127);
        assert(ccPkt.isControlChange() && ccPkt.data1() == 74 && ccPkt.data2() == 127);

        immutable MidiPacket centerBend = MidiPacket.makePitchBend(0, 0);
        assert(centerBend.isPitchBend());
        assert(fabs(centerBend.pitchBendNormalized()) < 1e-6f);

        immutable MidiPacket maxBend = MidiPacket.makePitchBend(0, 8191);
        assert(maxBend.pitchBendNormalized() > 0.999f);

        immutable MidiPacket minBend = MidiPacket.makePitchBend(0, -8192);
        assert(fabs(minBend.pitchBendNormalized() + 1.0f) < 1e-6f);

        immutable MidiPacket clk = MidiPacket.makeClock();
        assert(clk.isClock() && clk.len == 1);

        MidiPacket outPkt;
        outPkt = clk;
        assert(outPkt.isClock());
    }

    unittest {
        DriftCompensatedInputRing ring;
        assert(ring.tryInit(44_100.0, 48_000.0, 512, 8192));

        enum double PI_2 = 6.2831853071795864769;
        double phase = 0.0;
        immutable double dPhase = PI_2 * 440.0 / 44_100.0;

        float[256] inL = 0.0f;
        float[256] inR = 0.0f;
        float[128] outL = 0.0f;
        float[128] outR = 0.0f;

        foreach (i; 0 .. 256) {
            inL[i] = cast(float) sin(phase);
            inR[i] = -inL[i];
            phase += dPhase;
        }
        assert(ring.pushStereo(inL.ptr, inR.ptr, 256) == 256);

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            ring.pullResampled(outL.ptr, outR.ptr, 128);
        });

        double accumIn = 0.0;
        double ratio = 44_100.0 / 48_000.0;
        foreach (block; 0 .. 220) {
            accumIn += 128.0 * ratio;
            immutable uint genFrames = cast(uint) accumIn;
            accumIn -= cast(double) genFrames;

            foreach (i; 0 .. genFrames) {
                inL[i] = cast(float) sin(phase);
                inR[i] = -inL[i];
                phase += dPhase;
            }

            verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                ring.pushStereo(inL.ptr, inR.ptr, genFrames);
                ring.pullResampled(outL.ptr, outR.ptr, 128);
            });

            foreach (i; 0 .. 128) {
                assert(isFinite(outL[i]) && isFinite(outR[i]));
                assert(fabs(outL[i] + outR[i]) < 1e-4f);
            }
        }

        assert(ring.isPrimed());
        assert(ring.overrunCount() == 0);
        assert(ring.underrunCount() == 0);

        ring.reset();
        inL[] = 0.0f;
        inR[] = 0.0f;
        ring.pushStereo(inL.ptr, inR.ptr, 256);
        ring.pushStereo(inL.ptr, inR.ptr, 144);
        ratio = (44_100.0 / 48_000.0) * 1.0005;
        accumIn = 0.0;
        foreach (_; 0 .. 300) {
            accumIn += 128.0 * ratio;
            immutable uint genFrames = cast(uint) accumIn;
            accumIn -= cast(double) genFrames;
            foreach (i; 0 .. genFrames) {
                inL[i] = cast(float) sin(phase);
                inR[i] = inL[i];
                phase += dPhase;
            }
            ring.pushStereo(inL.ptr, inR.ptr, genFrames);
            ring.pullResampled(outL.ptr, outR.ptr, 128);
        }
        assert(ring.isPrimed() && ring.underrunCount() == 0 && ring.overrunCount() == 0);
        assert(ring.currentRatio() > 0.90 && ring.currentRatio() < 0.94);

        assert(ring.tryInit(48_000.0, 44_100.0, 512, 8192));
        inL[] = 0.25f;
        inR[] = -0.25f;
        ring.pushStereo(inL.ptr, inR.ptr, 256);
        ring.pushStereo(inL.ptr, inR.ptr, 144);
        ratio = (48_000.0 / 44_100.0) * 0.9995;
        accumIn = 0.0;
        foreach (_; 0 .. 300) {
            accumIn += 128.0 * ratio;
            immutable uint genFrames = cast(uint) accumIn;
            accumIn -= cast(double) genFrames;
            foreach (i; 0 .. genFrames) {
                inL[i] = 0.25f;
                inR[i] = -0.25f;
            }
            ring.pushStereo(inL.ptr, inR.ptr, genFrames);
            ring.pullResampled(outL.ptr, outR.ptr, 128);
        }
        assert(ring.isPrimed() && ring.underrunCount() == 0 && ring.overrunCount() == 0);
        assert(ring.currentRatio() > 1.06 && ring.currentRatio() < 1.11);
    }

    version (OSX) {
        private struct TestCaGraphBridge {
            AudioGraph graph;
            TransportState transport;
            float duplexGain = 1.0f;
            float lastPeakL = 0.0f;

            @disable this(this);
        }

        private void testCaRenderCallback(
            void* userData,
            const(float)* inL,
            const(float)* inR,
            float* outL,
            float* outR,
            uint frames
        ) @nogc nothrow {
            auto bridge = cast(TestCaGraphBridge*) userData;
            if (bridge is null || outL is null || outR is null || frames == 0) {
                return;
            }
            float[][2] outs = [outL[0 .. frames], outR[0 .. frames]];
            const(float[])[2] ins = [null, null];
            bridge.graph.render(outs, ins, frames, bridge.transport);

            if (inL !is null && inR !is null) {
                foreach (i; 0 .. frames) {
                    outL[i] += inL[i] * bridge.duplexGain;
                    outR[i] += inR[i] * bridge.duplexGain;
                }
            }
            foreach (i; 0 .. frames) {
                immutable float a = outL[i] < 0.0f ? -outL[i] : outL[i];
                if (a > bridge.lastPeakL) {
                    bridge.lastPeakL = a;
                }
            }
        }

        private class MidiProducerThread : Thread {
            CoreMidiRtContext* ctx = null;
            uint sourceId = 0;
            uint count = 0;

            this(CoreMidiRtContext* c, uint srcId, uint n) {
                ctx = c;
                sourceId = srcId;
                count = n;
                super(&run);
            }

            private void run() {
                ubyte[MIDIPacketList.sizeof] rawBuf = 0;
                auto plist = cast(MIDIPacketList*) rawBuf.ptr;
                plist.numPackets = 1;
                foreach (i; 0 .. count) {
                    plist.packet[0].timeStamp = i + 1;
                    plist.packet[0].length = 3;
                    plist.packet[0].data[0] = cast(ubyte)(0x90u | (sourceId & 0x0Fu));
                    plist.packet[0].data[1] = cast(ubyte)(36u + (i & 0x3Fu));
                    plist.packet[0].data[2] = 100;
                    midiReadProc(plist, ctx, cast(void*) cast(size_t) sourceId);
                }
            }
        }

        unittest {
            {
                ScopedCF!CFStringRef cfAscii = ScopedCF!CFStringRef(createCFString("CoreAudio Device 48kHz"));
                assert(!cfAscii.isNull());
                assert(cfStringToDString(cfAscii.get()) == "CoreAudio Device 48kHz");

                char[16] shortBuf = 0;
                immutable size_t w = cfStringToBuffer(cfAscii.get(), shortBuf[]);
                assert(w == 0 || shortBuf[w] == '\0');

                char[64] okBuf = 0;
                immutable size_t fullW = cfStringToBuffer(cfAscii.get(), okBuf[]);
                assert(fullW == "CoreAudio Device 48kHz".length);
            }

            {
                ScopedCF!CFStringRef cfUtf8 = ScopedCF!CFStringRef(createCFString("신디사이저 MIDI 🎹"));
                assert(!cfUtf8.isNull());
                assert(cfStringToDString(cfUtf8.get()) == "신디사이저 MIDI 🎹");

                ScopedCF!CFStringRef cfEmpty = ScopedCF!CFStringRef(createCFString(""));
                assert(!cfEmpty.isNull());
                assert(cfStringToDString(cfEmpty.get()) == "");
            }

            MachTimebase tb = MachTimebase.query();
            assert(tb.numer > 0 && tb.denom > 0);
            immutable ulong t0 = MachTimebase.nowTicks();
            immutable ulong t1 = MachTimebase.nowTicks();
            assert(t1 >= t0);
            immutable ulong ns = tb.ticksToNanos(1_000_000);
            assert(ns > 0);
            immutable ulong back = tb.nanosToTicks(ns);
            assert(back >= 999_990 && back <= 1_000_010);
            assert(tb.ticksToNanos(ulong.max / 4) > 0);
        }

        unittest {
            ModuleInstance ampInst;
            ModuleInstance outInst;
            assert(ModuleRegistry.createOffRT("fx.amplifier", ModuleId(1), 44_100.0f, ampInst));
            assert(ModuleRegistry.createOffRT("core.output", ModuleId(2), 44_100.0f, outInst));
            ampInst.desc.vtable.setParam(ampInst.state, 2, 0.25f, 44_100.0f, true);
            scope (exit) {
                ampInst.destroyOffRT();
                outInst.destroyOffRT();
            }

            NodeSpec[2] nodes = [NodeSpec.fromInstance(ampInst), NodeSpec.fromInstance(outInst)];
            WireSpec[1] wires = [WireSpec(ModuleId(1), 2, ModuleId(2), 0, 1.0f)];
            GraphPlan* plan = null;
            GraphCompileError err;
            assert(GraphCompiler.compile(nodes[], wires[], plan, err));

            auto bridge = cast(TestCaGraphBridge*) calloc(1, TestCaGraphBridge.sizeof);
            assert(bridge !is null);
            emplace(bridge);
            assert(bridge.graph.tryInit(44_100.0f, 128));
            bridge.graph.swapPlan(plan);
            bridge.duplexGain = 0.5f;

            auto rtCtx = cast(CoreAudioRtContext*) calloc(1, CoreAudioRtContext.sizeof);
            assert(rtCtx !is null);
            emplace(rtCtx);
            scope (exit) {
                GraphPlan* leftover = bridge.graph.detachPlan();
                if (leftover !is null) {
                    GraphPlan.destroyOffRT(leftover);
                }
                destroy!false(*bridge);
                free(bridge);
                rtCtx.releaseBuffers();
                destroy!false(*rtCtx);
                free(rtCtx);
            }

            assert(OwnedBuffer!float.tryAllocate(512, rtCtx.outScratchL));
            assert(OwnedBuffer!float.tryAllocate(512, rtCtx.outScratchR));
            assert(OwnedBuffer!float.tryAllocate(512, rtCtx.inScratchL));
            assert(OwnedBuffer!float.tryAllocate(512, rtCtx.inScratchR));
            assert(rtCtx.inputRing.tryInit(44_100.0, 44_100.0, 128, 1024));
            assert(MpscRing!AudioNotification.tryCreate(16, rtCtx.notifRing));

            rtCtx.userCallback = &testCaRenderCallback;
            rtCtx.userData = bridge;
            rtCtx.maxFramesPerSlice = 512;
            rtCtx.activeSampleRate = 44_100.0;
            rtCtx.activeBufferFrames = 128;
            rtCtx.timebase = MachTimebase.query();
            rtCtx.expectedCallbackNanos = (128.0 / 44_100.0) * 1.0e9;
            rtCtx.duplexMode.store(2);
            rtCtx.active.store(1);

            float[128] feedInL = 0.4f;
            float[128] feedInR = -0.4f;
            rtCtx.inputRing.pushStereo(feedInL.ptr, feedInR.ptr, 128);

            float[128] hostOutL = 0.0f;
            float[128] hostOutR = 0.0f;
            AudioBufferList2 nonInterleaved;
            nonInterleaved.mNumberBuffers = 2;
            nonInterleaved.mBuffers[0] = AudioBuffer(1, 128 * float.sizeof, hostOutL.ptr);
            nonInterleaved.mBuffers[1] = AudioBuffer(1, 128 * float.sizeof, hostOutR.ptr);

            immutable bool denormsBefore = ScopedNoDenormals.isHardwareNoDenormalsEnabled();
            AudioUnitRenderActionFlags flags = 0;

            verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                immutable OSStatus st = CoreAudioDriver.invokeRenderCallbackForTest(
                    rtCtx,
                    128,
                    cast(AudioBufferList*) &nonInterleaved,
                    &flags
                );
                assert(st == noErr);
            });

            assert(ScopedNoDenormals.isHardwareNoDenormalsEnabled() == denormsBefore);
            assert(rtCtx.lastDenormalsEnabled.load() == 1);
            assert(rtCtx.callbackCount.load() == 1);
            assert(rtCtx.framesRendered.load() == 128);
            assert(fabs(hostOutL[64] - 0.45f) < 1e-3f);
            assert(fabs(hostOutR[64] - 0.05f) < 1e-3f);

            float[256] interleavedBuf = 0.0f;
            AudioBufferList interleavedAbl;
            interleavedAbl.mNumberBuffers = 1;
            interleavedAbl.mBuffers[0] = AudioBuffer(2, 256 * float.sizeof, interleavedBuf.ptr);
            rtCtx.inputRing.pushStereo(feedInL.ptr, feedInR.ptr, 128);
            verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                immutable OSStatus st = CoreAudioDriver.invokeRenderCallbackForTest(
                    rtCtx,
                    128,
                    &interleavedAbl,
                    &flags
                );
                assert(st == noErr);
            });
            assert(fabs(interleavedBuf[2 * 64] - 0.45f) < 1e-3f);
            assert(fabs(interleavedBuf[2 * 64 + 1] - 0.05f) < 1e-3f);

            AudioObjectPropertyAddress defOutAddr = AudioObjectPropertyAddress(
                kAudioHardwarePropertyDefaultOutputDevice,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            );
            verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                auPropertyListener(kAudioObjectSystemObject, 1, &defOutAddr, rtCtx);
            });
            AudioNotification polledNotif;
            assert(rtCtx.notifRing.tryPop(polledNotif)
                && polledNotif.kind == AudioNotificationKind.defaultOutputChanged);

            rtCtx.active.store(0);
            flags = 0;
            verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                CoreAudioDriver.invokeRenderCallbackForTest(
                    rtCtx,
                    128,
                    cast(AudioBufferList*) &nonInterleaved,
                    &flags
                );
            });
            assert((flags & kAudioUnitRenderAction_OutputIsSilence) != 0);
            assert(hostOutL[0] == 0.0f && hostOutR[127] == 0.0f);
        }

        unittest {
            auto ctx = cast(CoreMidiRtContext*) calloc(1, CoreMidiRtContext.sizeof);
            assert(ctx !is null);
            emplace(ctx);
            scope (exit) {
                ctx.releaseRings();
                destroy!false(*ctx);
                free(ctx);
            }
            assert(MpscRing!MidiPacket.tryCreate(1024, ctx.packetRing));
            assert(MpscRing!MidiNotification.tryCreate(32, ctx.notifRing));
            ctx.active.store(1);

            ubyte[600] plistStorage = 0;
            auto plist = cast(MIDIPacketList*) plistStorage.ptr;
            plist.numPackets = 3;

            const(MIDIPacket)* p0 = &plist.packet[0];
            ubyte[11] pkt0Bytes = [
                0x90, 60, 100,
                64, 90,
                0xF8,
                60, 0,
                0xB1, 74, 64
            ];
            MIDITimeStamp ts = 1000;
            ushort len = cast(ushort) pkt0Bytes.length;
            memcpy(cast(void*) &(p0.timeStamp), &ts, MIDITimeStamp.sizeof);
            memcpy(cast(void*) &(p0.length), &len, ushort.sizeof);
            memcpy(cast(void*) p0.data.ptr, pkt0Bytes.ptr, pkt0Bytes.length);

            auto p1 = cast(MIDIPacket*) midiPacketNext(p0);
            ubyte[8] pkt1Bytes = [
                0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7,
                0xE0, 0x00
            ];
            ts = 2000;
            len = cast(ushort)(pkt1Bytes.length + 1);
            memcpy(&(p1.timeStamp), &ts, MIDITimeStamp.sizeof);
            memcpy(&(p1.length), &len, ushort.sizeof);
            memcpy(p1.data.ptr, pkt1Bytes.ptr, pkt1Bytes.length);
            p1.data[pkt1Bytes.length] = 0x60;

            auto p2 = cast(MIDIPacket*) midiPacketNext(p1);
            ts = 3000;
            len = 1;
            p2.timeStamp = ts;
            p2.length = len;
            p2.data[0] = 0xFA;

            verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                midiReadProc(plist, ctx, cast(void*) cast(size_t) 42);
            });

            assert(ctx.packetsReceived.load() == 7);
            assert(ctx.packetsDropped.load() == 0);

            MidiPacket[7] got;
            foreach (idx; 0 .. 7) {
                assert(ctx.packetRing.tryPop(got[idx]));
                assert(got[idx].sourceId == 42);
            }

            assert(got[0].isNoteOn() && got[0].data1() == 60 && got[0].data2() == 100);
            assert(got[1].isNoteOn() && got[1].data1() == 64 && got[1].data2() == 90);
            assert(got[2].isClock());
            assert(got[3].isNoteOff() && got[3].data1() == 60);
            assert(got[4].isControlChange() && got[4].channel() == 1 && got[4].data1() == 74);
            assert(got[5].isPitchBend() && got[5].pitchBendNormalized() > 0.45f);
            assert(got[6].messageKind() == MidiMessageKind.start);

            MidiNoteTracker tracker;
            ModEvent ev0, ev1, ev3, ev4, ev5;
            assert(translateMidiPacketToModEvent(got[0], tracker, ev0, 17));
            assert(ev0.kind == ModEventKind.noteOn && ev0.frameOffset == 17 && ev0.noteId.isValid());
            assert(translateMidiPacketToModEvent(got[1], tracker, ev1, 20));
            assert(ev1.kind == ModEventKind.noteOn && ev1.noteId != ev0.noteId);
            assert(translateMidiPacketToModEvent(got[3], tracker, ev3, 30));
            assert(ev3.kind == ModEventKind.noteOff && ev3.noteId == ev0.noteId);
            assert(translateMidiPacketToModEvent(got[4], tracker, ev4, 31));
            assert(ev4.kind == ModEventKind.setParam && ev4.paramId == 74);
            assert(translateMidiPacketToModEvent(got[5], tracker, ev5, 32));
            assert(ev5.kind == ModEventKind.setPitch && ev5.valueA > 0.9f);

            MIDINotification notifMsg = MIDINotification(kMIDIMsgSetupChanged, 8);
            verifyZeroRtAllocationsNothrow(() @nogc nothrow {
                midiNotifyProc(&notifMsg, ctx);
            });
            MidiNotification mn;
            assert(ctx.notifRing.tryPop(mn) && mn.kind == MidiNotificationKind.setupChanged);

            MidiProducerThread[4] producers;
            foreach (pIdx; 0 .. 4) {
                producers[pIdx] = new MidiProducerThread(ctx, cast(uint)(pIdx + 10), 100);
                producers[pIdx].start();
            }
            size_t totalDrained = 0;
            ulong seenSum = 0;
            while (totalDrained < 400) {
                MidiPacket mp;
                if (ctx.packetRing.tryPop(mp)) {
                    totalDrained++;
                    seenSum += mp.data1();
                } else {
                    Thread.yield();
                }
            }
            foreach (pIdx; 0 .. 4) {
                producers[pIdx].join();
            }
            assert(totalDrained == 400 && seenSum > 0);
        }

        unittest {
            scope audio = new CoreAudioDriver();
            auto devices = audio.enumerateDevices();
            bool hasOutput = false;
            foreach (ref d; devices) {
                if (d.outputChannels > 0) {
                    hasOutput = true;
                    break;
                }
            }

            if (hasOutput) {
                ModuleInstance outInst;
                assert(ModuleRegistry.createOffRT("core.output", ModuleId(1), 44_100.0f, outInst));
                outInst.desc.vtable.setParam(outInst.state, 0, 0.0f, 44_100.0f, true);
                scope (exit) outInst.destroyOffRT();

                NodeSpec[1] nodes = [NodeSpec.fromInstance(outInst)];
                GraphPlan* plan = null;
                GraphCompileError gErr;
                assert(GraphCompiler.compile(nodes[], null, plan, gErr));

                auto bridge = cast(TestCaGraphBridge*) calloc(1, TestCaGraphBridge.sizeof);
                assert(bridge !is null);
                emplace(bridge);
                assert(bridge.graph.tryInit(44_100.0f, 128));
                bridge.graph.swapPlan(plan);
                scope (exit) {
                    GraphPlan* leftover = bridge.graph.detachPlan();
                    if (leftover !is null) {
                        GraphPlan.destroyOffRT(leftover);
                    }
                    destroy!false(*bridge);
                    free(bridge);
                }

                AudioStreamConfig cfg;
                cfg.sampleRate = 44_100.0;
                cfg.bufferFrames = 128;
                cfg.enableInput = false;

                if (audio.open(cfg, &testCaRenderCallback, bridge)) {
                    scope (exit) audio.close();
                    immutable float liveSr = cast(float) audio.activeSampleRate();
                    outInst.desc.vtable.prepare(outInst.state, liveSr, FIXED_BLOCK_FRAMES);

                    if (audio.start()) {
                        Thread.sleep(dur!"msecs"(150));
                        audio.stop();

                        auto st = audio.stats();
                        assert(st.callbackCount > 0);
                        assert(st.framesRendered > 0);
                        assert(st.xrunCount == 0);
                        assert(st.denormalsSuppressedInCallback);
                        assert(st.lastRtThreadId != 0);

                        bool registeredWithDRuntime = false;
                        foreach (t; Thread.getAll()) {
                            if (cast(size_t) t.id == st.lastRtThreadId) {
                                registeredWithDRuntime = true;
                                break;
                            }
                        }
                        assert(!registeredWithDRuntime);
                    }
                }
            }

            scope midi = new CoreMidiDriver();
            if (midi.open("SynthTracker Unit Test MIDI")) {
                scope (exit) midi.close();
                midi.enumerateSources();
                midi.enumerateDestinations();
                if (midi.createVirtualDestination("SynthTracker Test In")
                        && midi.createVirtualSource("SynthTracker Test Out")) {
                    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, 0);
                    midi.connectAllSources();
                    immutable uint destId = midi.virtualDestinationId();
                    if (destId != 0) {
                        immutable MonoTime tSend = MonoTime.currTime;
                        immutable MidiPacket testNote = MidiPacket.makeNoteOn(0, 69, 96);
                        if (midi.sendPacket(destId, testNote)) {
                            MidiPacket gotPkt;
                            bool received = false;
                            foreach (_; 0 .. 20) {
                                if (midi.pollPacket(gotPkt)) {
                                    received = true;
                                    break;
                                }
                                Thread.sleep(dur!"msecs"(2));
                            }
                            if (received) {
                                immutable long us = (MonoTime.currTime - tSend).total!"usecs";
                                assert(gotPkt.isNoteOn() && gotPkt.data1() == 69 && us < 20_000);
                            }
                        }
                    }
                }
            }
        }
    }
}
