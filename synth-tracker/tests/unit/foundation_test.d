/**
 * File:         tests/unit/foundation_test.d
 * Module:       tests.unit.foundation_test
 * Phase:        Phase 0.2-0.5 — Foundation, Codec & Harness Unit Tests
 *
 * Purpose:
 *   Validates types, OwnedBuffer!T, FixedArray, Arena, Atomic, SpscRing/MpscRing 10M-message stress tests, TripleBuffer, ScopedNoDenormals, math_rt, audio_io, audio_harness, and rt_malloc_trap.
 *
 * Real-Time & Safety Contract:
 *   Test module executing under dub test --compiler=ldc2 --config=headless.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, foundation.concurrency, foundation.math_rt, io.audio_io, tests.audio_harness, tests.rt_malloc_trap
 *   External: core.exception (AssertError), core.lifetime (move), core.stdc.stdlib, core.sys.posix.stdlib, core.thread, std.file, std.math, std.path, std.process
 *
 * Planned API (Types, Functions & Hooks):
 *   - unittest: foundation.types constants, IDs, and StereoFrame zero-init arithmetic
 *   - unittest: OwnedBuffer!T compile-time guards, overflow, alignment, move, release/adopt, destructors
 *   - unittest: FixedArray and Arena capacity, alignment, rewind, lifetime, and RT zero-alloc checks
 *   - unittest: SpscRing!T and MpscRing!T 10M-message multi-threaded integrity + TripleBuffer torn-read stress
 *   - unittest: ScopedNoDenormals hardware FTZ/DAZ flushing and pitch/dB helpers
 *   - unittest: audio_io, audio_harness invariance, and rt_malloc_trap positive/negative audits
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.foundation_test;

version (unittest) {
    import core.atomic : atomicLoad, atomicStore, MemoryOrder;
    import core.exception : AssertError;
    import core.lifetime : move;
    import core.stdc.stdlib : calloc, free, malloc, realloc;
    import core.sys.posix.stdlib : posix_memalign;
    import core.thread : Thread;
    import std.file : exists, remove, tempDir;
    import std.math : fabs, isInfinity, isNaN, pow, sin;
    import std.path : buildPath;
    import std.process : thisProcessID;

    import foundation.concurrency : Atomic, MpscRing, SpscRing, TripleBuffer, hasGcReference, isPowerOfTwo;
    import foundation.math_rt : PITCH_TO_HZ_TABLE, ScopedNoDenormals, clampSample, dbToLinear,
        flushSubnormalSoftware, hzToMidiNote, isFiniteSample, linearToDb, midiNoteToHz, sanitizeSample;
    import foundation.memory : Arena, FixedArray, OwnedBuffer;
    import foundation.types : CACHE_LINE_SIZE, DEFAULT_SAMPLE_RATE, DEFAULT_SIMD_ALIGNMENT,
        FIXED_BLOCK_FRAMES, FrameTime, MAX_CHANNELS, ModuleId, NoteId, PortId, Sample, StereoFrame;
    import io.audio_io : DecodedAudio, decodeAudioFile, decodeAudioMemory, deinterleaveToPlanar,
        writeWavFile, writeWavInterleaved, writeWavMemory;
    import tests.audio_harness : AudioMetrics, assertAudioMatches, assertBufferSizeInvariance,
        compareAudio, compareWithGoldenWav, renderOfflineStereo, renderOfflineToWav;
    import tests.rt_malloc_trap : RtAllocationAudit, ScopedRtMallocTrap, auditRtAllocations,
        verifyZeroRtAllocations, verifyZeroRtAllocationsNothrow;

    private struct NonNoGcDestructible {
        int val = 0;

        ~this() {
            auto arr = new int[1];
            val = arr[0];
        }
    }

    private __gshared size_t[4] gResourceDestroyCounts = 0;
    private shared size_t gTrapEscapeSink = 0;
    private __gshared void[] gGcEscapeSink = null;

    private struct CountedResource {
        size_t counterSlot = 0;
        int id = 0;
        bool active = false;

        @disable this(this);

        ~this() @nogc nothrow {
            if (active) {
                gResourceDestroyCounts[counterSlot]++;
                active = false;
            }
        }
    }

    private struct NonZeroDefaultPod {
        float cutoff = 20.0f;
        int mode = 7;
    }

    private struct MultiProducerMsg {
        uint producerId = 0;
        ulong sequence = 0;
    }

    private struct TelemetrySnapshot {
        ulong sequence = 0;
        ulong payloadA = 0;
        ulong payloadB = 0;
        ulong checksum = 0;
    }

    private struct StructWithGcSlice {
        int id = 0;
        int[] slice;
    }

    pragma(inline, false)
    private void mulFloatRef(ref float dst, ref const float a, ref const float b) @nogc nothrow {
        dst = a * b;
    }

    private string makeUniqueTempWavPath(string tag) {
        return buildPath(tempDir(), "synthtracker_" ~ tag ~ "_" ~ toDecimalString(thisProcessID) ~ ".wav");
    }

    private string toDecimalString(int v) {
        import std.conv : to;
        return to!string(v);
    }

    private Thread createMpscProducerThread(
        MpscRing!MultiProducerMsg* ringPtr,
        uint producerId,
        ulong messageCount
    ) {
        return new Thread({
            foreach (seq; 0 .. messageCount) {
                MultiProducerMsg msg = MultiProducerMsg(producerId, seq);
                while (!ringPtr.tryPush(msg)) {
                }
            }
        });
    }

    unittest {
        static assert(is(Sample == float));
        static assert(is(FrameTime == ulong));
        assert(FIXED_BLOCK_FRAMES == 64);
        assert(MAX_CHANNELS == 2);
        assert(CACHE_LINE_SIZE == 64);
        assert(DEFAULT_SIMD_ALIGNMENT == 32);
        assert(DEFAULT_SAMPLE_RATE == 44_100);

        assert(!NoteId.init.isValid());
        assert(!NoteId.none.isValid());
        assert(NoteId(1).isValid());

        assert(!ModuleId.init.isValid());
        assert(!ModuleId.invalid.isValid());
        assert(ModuleId(0).isValid());

        assert(!PortId.init.isValid());
        assert(!PortId.invalid.isValid());
        assert(PortId(3).isValid());

        StereoFrame s0;
        assert(!isNaN(s0.left) && !isNaN(s0.right));
        assert(s0.left == 0.0f && s0.right == 0.0f);

        immutable StereoFrame a = StereoFrame(0.25f, -0.5f);
        immutable StereoFrame b = StereoFrame(0.75f, 0.25f);
        immutable StereoFrame sum = a + b;
        immutable StereoFrame diff = b - a;
        immutable StereoFrame scaledR = a * 2.0f;
        immutable StereoFrame scaledL = 2.0f * a;
        assert(sum.left == 1.0f && sum.right == -0.25f);
        assert(diff.left == 0.5f && diff.right == 0.75f);
        assert(scaledR.left == 0.5f && scaledR.right == -1.0f);
        assert(scaledL == scaledR);

        StereoFrame acc = a;
        acc += b;
        assert(acc == sum);
        acc -= b;
        assert(acc == a);
    }

    unittest {
        static assert(!__traits(compiles, OwnedBuffer!(int*)));
        static assert(!__traits(compiles, OwnedBuffer!string));
        static assert(!__traits(compiles, OwnedBuffer!Object));
        static assert(!__traits(compiles, OwnedBuffer!NonNoGcDestructible));

        OwnedBuffer!float emptyBuf;
        assert(OwnedBuffer!float.tryAllocate(0, emptyBuf));
        assert(emptyBuf.empty() && emptyBuf.length == 0 && emptyBuf.ptr is null);

        OwnedBuffer!float badAlign;
        assert(!OwnedBuffer!float.tryAllocate(16, badAlign, 0));
        assert(!OwnedBuffer!float.tryAllocate(16, badAlign, 3));
        assert(!OwnedBuffer!float.tryAllocate(16, badAlign, 48));

        OwnedBuffer!uint overflowBuf;
        assert(!OwnedBuffer!uint.tryAllocate((size_t.max / uint.sizeof) + 1, overflowBuf));

        OwnedBuffer!float floatBuf;
        assert(OwnedBuffer!float.tryAllocate(128, floatBuf, 64));
        assert(floatBuf.length == 128);
        assert((cast(size_t) floatBuf.ptr & 63) == 0);
        foreach (i; 0 .. floatBuf.length) {
            assert(!isNaN(floatBuf[i]) && floatBuf[i] == 0.0f);
            floatBuf[i] = cast(float) i;
        }
        auto sub = floatBuf[10 .. 20];
        assert(sub.length == 10 && sub[0] == 10.0f && sub[$ - 1] == 19.0f);

        OwnedBuffer!(float[4]) vecBuf;
        assert(OwnedBuffer!(float[4]).tryAllocate(8, vecBuf));
        foreach (ref v; vecBuf[]) {
            foreach (c; v) {
                assert(!isNaN(c) && c == 0.0f);
            }
        }

        OwnedBuffer!NonZeroDefaultPod podBuf;
        assert(OwnedBuffer!NonZeroDefaultPod.tryAllocate(4, podBuf));
        foreach (ref item; podBuf[]) {
            assert(item.cutoff == 20.0f && item.mode == 7);
        }

        OwnedBuffer!float moved;
        moved = move(floatBuf);
        assert(floatBuf.empty() && floatBuf.ptr is null);
        assert(moved.length == 128 && moved[127] == 127.0f);

        moved = move(moved);
        assert(moved.length == 128 && moved[5] == 5.0f);

        float[] rawSlice = moved.release();
        assert(moved.empty() && moved.ptr is null);
        assert(rawSlice.length == 128 && rawSlice[42] == 42.0f);
        auto adopted = OwnedBuffer!float.adopt(rawSlice);
        assert(adopted.length == 128 && adopted[42] == 42.0f);
        adopted.reset();
        assert(adopted.empty());

        gResourceDestroyCounts[0] = 0;
        {
            OwnedBuffer!CountedResource resBuf;
            assert(OwnedBuffer!CountedResource.tryAllocate(5, resBuf));
            foreach (i; 0 .. resBuf.length) {
                resBuf[i].counterSlot = 0;
                resBuf[i].id = cast(int) i;
                resBuf[i].active = true;
            }
            resBuf.reset();
            assert(gResourceDestroyCounts[0] == 5);
        }
        assert(gResourceDestroyCounts[0] == 5);
    }

    unittest {
        FixedArray!(float, 8) fa;
        assert(fa.empty() && !fa.full() && fa.remaining == 8);
        foreach (i; 0 .. 8) {
            assert(fa.tryPush(cast(float)(i + 1)));
        }
        assert(fa.full() && fa.remaining == 0);
        assert(!fa.tryPush(99.0f));
        assert(fa.front() == 1.0f && fa.back() == 8.0f);
        assert(fa[1 .. 4] == [2.0f, 3.0f, 4.0f]);

        assert(fa.removeSwapBack(1));
        assert(fa.length == 7 && fa[1] == 8.0f);
        float popped = 0.0f;
        assert(fa.tryPop(popped) && popped == 7.0f);
        fa.clear();
        assert(fa.empty());
        assert(!fa.tryPop(popped));

        verifyZeroRtAllocations({
            FixedArray!(int, 16) rtArr;
            foreach (i; 0 .. 16) {
                assert(rtArr.tryPush(i));
            }
            assert(rtArr.removeSwapBack(3));
            int val = 0;
            while (rtArr.tryPop(val)) {
            }
            rtArr.clear();
        });

        gResourceDestroyCounts[1] = 0;
        {
            FixedArray!(CountedResource, 4) resArr;
            foreach (i; 0 .. 3) {
                CountedResource r;
                r.counterSlot = 1;
                r.id = i;
                r.active = true;
                assert(resArr.tryPush(move(r)));
            }
            assert(gResourceDestroyCounts[1] == 0);
            assert(resArr.removeSwapBack(0));
            assert(gResourceDestroyCounts[1] == 1);
            CountedResource poppedRes;
            assert(resArr.tryPop(poppedRes));
            assert(gResourceDestroyCounts[1] == 1);
            poppedRes.active = false;
        }
        assert(gResourceDestroyCounts[1] == 2);
    }

    unittest {
        static assert(!__traits(compiles, Arena.init.allocSlice!(int*)(4)));
        static assert(!__traits(compiles, Arena.init.allocSlice!CountedResource(2)));

        Arena arena;
        assert(!Arena.tryCreate(128, arena, 3));
        assert(Arena.tryCreate(1024, arena, 64));
        assert(arena.capacity == 1024 && arena.used == 0 && arena.remaining == 1024);
        assert(arena.allocBytes(0) is null && arena.used == 0);

        void* p16 = arena.allocBytes(13, 16);
        assert(p16 !is null && (cast(size_t) p16 & 15) == 0);
        void* p64 = arena.allocBytes(64, 64);
        assert(p64 !is null && (cast(size_t) p64 & 63) == 0);

        immutable size_t mark = arena.mark();
        auto fSlice = arena.allocSlice!float(32, 32);
        assert(fSlice.length == 32 && (cast(size_t) fSlice.ptr & 31) == 0);
        foreach (s; fSlice) {
            assert(!isNaN(s) && s == 0.0f);
        }

        auto framePtr = arena.allocOne!StereoFrame();
        assert(framePtr !is null && framePtr.left == 0.0f && framePtr.right == 0.0f);

        assert(arena.allocBytes(2048) is null);
        arena.rewind(mark);
        assert(arena.used == mark);
        arena.reset();
        assert(arena.used == 0 && arena.remaining == 1024);

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            foreach (cycle; 0 .. 16) {
                auto slice = arena.allocSlice!float(64, 32);
                assert(slice.length == 64);
                slice[0] = cast(float) cycle;
                arena.reset();
            }
        });
    }

    unittest {
        static assert(!hasGcReference!int);
        static assert(!hasGcReference!(void*));
        static assert(!hasGcReference!StereoFrame);
        static assert(hasGcReference!string);
        static assert(hasGcReference!(int[]));
        static assert(hasGcReference!Object);
        static assert(hasGcReference!StructWithGcSlice);
        static assert(!__traits(compiles, SpscRing!string));
        static assert(!__traits(compiles, MpscRing!StructWithGcSlice));
        static assert(!__traits(compiles, TripleBuffer!(int*)));

        assert(isPowerOfTwo(1) && isPowerOfTwo(64) && !isPowerOfTwo(0) && !isPowerOfTwo(3));

        Atomic!uint a = Atomic!uint(10);
        assert(a.load() == 10);
        a.store(25);
        assert(a.exchange(40) == 25);
        uint expected = 30;
        assert(!a.compareExchange(expected, 99) && expected == 40);
        assert(a.compareExchange(expected, 99) && a.load() == 99);
        assert(a.fetchAdd(5) == 99 && a.load() == 104);
        assert(a.fetchSub(4) == 104 && a.load() == 100);
    }

    unittest {
        SpscRing!ulong badRing;
        assert(!SpscRing!ulong.tryCreate(0, badRing));
        assert(!SpscRing!ulong.tryCreate(1, badRing));
        assert(!SpscRing!ulong.tryCreate(3, badRing));

        SpscRing!ulong ring;
        assert(SpscRing!ulong.tryCreate(8, ring));
        assert(ring.capacity == 8 && ring.empty());

        foreach (i; 0 .. 8) {
            assert(ring.tryPush(cast(ulong) i));
        }
        assert(!ring.tryPush(999UL));
        assert(ring.approximateCount == 8);

        ulong popped = 0;
        foreach (i; 0 .. 8) {
            assert(ring.tryPop(popped) && popped == i);
        }
        assert(!ring.tryPop(popped) && ring.empty());

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            ulong v = 0;
            foreach (k; 0 .. 64) {
                assert(ring.tryPush(cast(ulong) k));
                assert(ring.tryPop(v) && v == k);
            }
        });

        SpscRing!ulong stressRing;
        assert(SpscRing!ulong.tryCreate(4096, stressRing));
        enum ulong SPSC_TOTAL = 10_000_000UL;

        auto producer = new Thread({
            foreach (i; 0 .. SPSC_TOTAL) {
                while (!stressRing.tryPush(i)) {
                }
            }
        });
        producer.start();

        ulong expected = 0;
        ulong val = 0;
        while (expected < SPSC_TOTAL) {
            if (stressRing.tryPop(val)) {
                assert(val == expected);
                expected++;
            }
        }
        producer.join();
        assert(expected == SPSC_TOTAL && stressRing.empty());
    }

    unittest {
        MpscRing!MultiProducerMsg badRing;
        assert(!MpscRing!MultiProducerMsg.tryCreate(1, badRing));
        assert(!MpscRing!MultiProducerMsg.tryCreate(6, badRing));

        MpscRing!MultiProducerMsg ring;
        assert(MpscRing!MultiProducerMsg.tryCreate(8, ring));
        foreach (i; 0 .. 8) {
            assert(ring.tryPush(MultiProducerMsg(0, i)));
        }
        assert(!ring.tryPush(MultiProducerMsg(0, 999)));
        MultiProducerMsg item;
        foreach (i; 0 .. 8) {
            assert(ring.tryPop(item) && item.sequence == i);
        }
        assert(!ring.tryPop(item) && ring.empty());

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            MultiProducerMsg msg;
            foreach (k; 0 .. 64) {
                assert(ring.tryPush(MultiProducerMsg(1, k)));
                assert(ring.tryPop(msg) && msg.producerId == 1 && msg.sequence == k);
            }
        });

        MpscRing!MultiProducerMsg stressRing;
        assert(MpscRing!MultiProducerMsg.tryCreate(4096, stressRing));
        enum uint PRODUCER_COUNT = 4;
        enum ulong MSGS_PER_PRODUCER = 2_500_000UL;
        enum ulong TOTAL_MSGS = PRODUCER_COUNT * MSGS_PER_PRODUCER;

        Thread[PRODUCER_COUNT] producers;
        foreach (pid; 0 .. PRODUCER_COUNT) {
            producers[pid] = createMpscProducerThread(&stressRing, pid, MSGS_PER_PRODUCER);
            producers[pid].start();
        }

        ulong[PRODUCER_COUNT] nextExpected = 0;
        ulong totalReceived = 0;
        bool invalidProducer = false;
        bool sequenceMismatch = false;
        MultiProducerMsg popped;
        while (totalReceived < TOTAL_MSGS) {
            if (stressRing.tryPop(popped)) {
                if (popped.producerId >= PRODUCER_COUNT) {
                    invalidProducer = true;
                } else if (popped.sequence != nextExpected[popped.producerId]) {
                    sequenceMismatch = true;
                } else {
                    nextExpected[popped.producerId]++;
                }
                totalReceived++;
            }
        }
        foreach (pid; 0 .. PRODUCER_COUNT) {
            producers[pid].join();
        }
        assert(!invalidProducer, "MpscRing observed out-of-range producerId");
        assert(!sequenceMismatch, "MpscRing observed out-of-order or duplicate sequence");
        foreach (pid; 0 .. PRODUCER_COUNT) {
            assert(nextExpected[pid] == MSGS_PER_PRODUCER);
        }
        assert(totalReceived == TOTAL_MSGS && stressRing.empty());
    }

    unittest {
        TripleBuffer!TelemetrySnapshot tb;
        TelemetrySnapshot snap;
        assert(!tb.read(snap));

        tb.write(TelemetrySnapshot(1, 10, 20, 30));
        tb.write(TelemetrySnapshot(2, 13, 23, 36));
        assert(tb.read(snap));
        assert(snap.sequence == 2 && snap.payloadA == 13 && snap.payloadB == 23 && snap.checksum == 36);
        assert(!tb.read(snap));

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            TelemetrySnapshot outSnap;
            tb.write(TelemetrySnapshot(3, 1, 2, 3));
            assert(tb.read(outSnap) && outSnap.sequence == 3);
        });

        TripleBuffer!TelemetrySnapshot stressTb;
        shared int writerDone = 0;
        enum ulong SNAPSHOT_COUNT = 500_000UL;

        auto writer = new Thread({
            foreach (seq; 1 .. SNAPSHOT_COUNT + 1) {
                immutable ulong a = seq * 3UL + 7UL;
                immutable ulong b = seq ^ 0x9E3779B97F4A7C15UL;
                stressTb.write(TelemetrySnapshot(seq, a, b, a ^ b));
            }
            atomicStore!(MemoryOrder.rel)(writerDone, 1);
        });
        writer.start();

        ulong lastSeq = 0;
        TelemetrySnapshot cur;
        while (atomicLoad!(MemoryOrder.acq)(writerDone) == 0 || stressTb.tryAcquireLatest()) {
            cur = stressTb.frontBuffer();
            if (cur.sequence > 0) {
                assert(cur.sequence >= lastSeq);
                immutable ulong expectedA = cur.sequence * 3UL + 7UL;
                immutable ulong expectedB = cur.sequence ^ 0x9E3779B97F4A7C15UL;
                assert(cur.payloadA == expectedA);
                assert(cur.payloadB == expectedB);
                assert(cur.checksum == (expectedA ^ expectedB));
                lastSeq = cur.sequence;
            }
        }
        writer.join();
        assert(lastSeq == SNAPSHOT_COUNT);
    }

    unittest {
        immutable bool initialState = ScopedNoDenormals.isHardwareNoDenormalsEnabled();
        {
            ScopedNoDenormals inactive;
            assert(!inactive.isActive());
        }
        assert(ScopedNoDenormals.isHardwareNoDenormalsEnabled() == initialState);

        immutable float minNorm = float.min_normal;
        immutable float half = 0.5f;
        float subnormal = 0.0f;
        mulFloatRef(subnormal, minNorm, half);
        assert(subnormal != 0.0f);

        float outsideBefore = 0.0f;
        mulFloatRef(outsideBefore, subnormal, half);
        assert(outsideBefore != 0.0f);

        float insideOuter = 1.0f;
        float insideNested = 1.0f;
        {
            auto outerGuard = ScopedNoDenormals.enter();
            assert(outerGuard.isActive());
            assert(ScopedNoDenormals.isHardwareNoDenormalsEnabled());
            mulFloatRef(insideOuter, subnormal, half);
            {
                auto innerGuard = ScopedNoDenormals.enter();
                assert(innerGuard.isActive());
                assert(ScopedNoDenormals.isHardwareNoDenormalsEnabled());
            }
            assert(ScopedNoDenormals.isHardwareNoDenormalsEnabled());
            mulFloatRef(insideNested, subnormal, half);
        }
        assert(ScopedNoDenormals.isHardwareNoDenormalsEnabled() == initialState);
        assert(insideOuter == 0.0f && insideNested == 0.0f);

        float outsideAfter = 0.0f;
        mulFloatRef(outsideAfter, subnormal, half);
        assert(outsideAfter != 0.0f);

        assert(PITCH_TO_HZ_TABLE.length == 8193);
        assert(fabs(midiNoteToHz(69.0f) - 440.0f) < 1e-4f);
        assert(fabs(midiNoteToHz(57.0f) - 220.0f) < 1e-4f);
        assert(fabs(midiNoteToHz(81.0f) - 880.0f) < 1e-4f);
        assert(fabs(midiNoteToHz(60.0f) - 261.625565f) < 1e-3f);
        immutable float microExpected = cast(float)(440.0 * pow(2.0, 0.5 / 12.0));
        assert(fabs(midiNoteToHz(69.5f) - microExpected) < 0.01f);
        assert(midiNoteToHz(-5.0f) == PITCH_TO_HZ_TABLE[0]);
        assert(midiNoteToHz(200.0f) == PITCH_TO_HZ_TABLE[$ - 1]);
        assert(midiNoteToHz(float.nan) == 440.0f);

        assert(fabs(hzToMidiNote(440.0f) - 69.0f) < 1e-5f);
        assert(hzToMidiNote(0.0f) == 0.0f && hzToMidiNote(-100.0f) == 0.0f && hzToMidiNote(float.nan) == 0.0f);

        assert(fabs(dbToLinear(0.0f) - 1.0f) < 1e-6f);
        assert(fabs(dbToLinear(-20.0f) - 0.1f) < 1e-6f);
        assert(dbToLinear(-144.0f) == 0.0f && dbToLinear(-200.0f) == 0.0f && dbToLinear(float.nan) == 0.0f);
        assert(fabs(linearToDb(1.0f)) < 1e-5f);
        assert(fabs(linearToDb(-0.1f) + 20.0f) < 1e-4f);
        assert(linearToDb(0.0f) == -144.0f && linearToDb(float.nan) == -144.0f);

        assert(clampSample(float.nan, -1.0f, 1.0f) == -1.0f);
        assert(clampSample(2.5f, -1.0f, 1.0f) == 1.0f);
        assert(clampSample(-2.5f, -1.0f, 1.0f) == -1.0f);
        assert(isFiniteSample(0.0f) && !isFiniteSample(float.nan) && !isFiniteSample(float.infinity));
        assert(sanitizeSample(float.nan) == 0.0f && sanitizeSample(-float.infinity) == 0.0f && sanitizeSample(0.5f) == 0.5f);
        assert(flushSubnormalSoftware(subnormal) == 0.0f && flushSubnormalSoftware(0.25f) == 0.25f);

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            auto g = ScopedNoDenormals.enter();
            immutable float hz = midiNoteToHz(64.25f);
            immutable float amp = dbToLinear(-12.0f);
            assert(hz > 0.0f && amp > 0.0f && linearToDb(amp) <= 0.0f);
        });
    }

    unittest {
        enum uint sampleRate = 48_000;
        enum size_t frames = 256;
        auto left = new float[frames];
        auto right = new float[frames];
        foreach (i; 0 .. frames) {
            immutable double t = cast(double) i / cast(double) sampleRate;
            left[i] = cast(float)(0.5 * sin(2.0 * 3.14159265358979323846 * 440.0 * t));
            right[i] = cast(float)(-0.25 * sin(2.0 * 3.14159265358979323846 * 880.0 * t));
        }

        const(float)[][2] planar = [left, right];
        ubyte[] wavBytes;
        string err;
        assert(writeWavMemory(planar[], sampleRate, wavBytes, err), err);
        assert(wavBytes.length > 44);

        DecodedAudio memDecoded;
        assert(decodeAudioMemory(wavBytes, memDecoded, err), err);
        assert(memDecoded.channels == 2 && memDecoded.sampleRate == sampleRate && memDecoded.frames == frames);
        foreach (i; 0 .. frames) {
            assert(memDecoded.sampleAt(i, 0) == left[i]);
            assert(memDecoded.sampleAt(i, 1) == right[i]);
        }

        OwnedBuffer!float planarL;
        OwnedBuffer!float planarR;
        assert(deinterleaveToPlanar(memDecoded, planarL, planarR));
        assertAudioMatches(planarL[], left, 0.0, 120.0);
        assertAudioMatches(planarR[], right, 0.0, 120.0);

        immutable string tmpWav = makeUniqueTempWavPath("audio_io_stereo");
        scope (exit) {
            if (exists(tmpWav)) {
                remove(tmpWav);
            }
        }
        assert(writeWavFile(tmpWav, planar[], sampleRate, err), err);
        DecodedAudio fileDecoded;
        assert(decodeAudioFile(tmpWav, fileDecoded, err), err);
        assert(fileDecoded.frames == frames && fileDecoded.channels == 2);
        foreach (i; 0 .. frames) {
            assert(fileDecoded.sampleAt(i, 0) == left[i]);
            assert(fileDecoded.sampleAt(i, 1) == right[i]);
        }

        immutable string monoWav = makeUniqueTempWavPath("audio_io_mono");
        scope (exit) {
            if (exists(monoWav)) {
                remove(monoWav);
            }
        }
        assert(writeWavInterleaved(monoWav, left, 1, sampleRate, err), err);
        DecodedAudio monoDecoded;
        assert(decodeAudioFile(monoWav, monoDecoded, err), err);
        assert(monoDecoded.channels == 1 && monoDecoded.frames == frames);
        OwnedBuffer!float dupL;
        OwnedBuffer!float dupR;
        assert(deinterleaveToPlanar(monoDecoded, dupL, dupR));
        assertAudioMatches(dupL[], left, 0.0, 120.0);
        assertAudioMatches(dupR[], left, 0.0, 120.0);

        DecodedAudio badAudio;
        assert(!decodeAudioMemory(null, badAudio, err));
        immutable ubyte[8] junk = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03];
        assert(!decodeAudioMemory(junk[], badAudio, err));
        assert(!decodeAudioFile("/nonexistent/path/to/missing.wav", badAudio, err));
        assert(!writeWavFile(tmpWav, planar[], 0, err));
        const(float)[][2] mismatched = [left, right[0 .. 10]];
        assert(!writeWavFile(tmpWav, mismatched[], sampleRate, err));
    }

    unittest {
        float[4] refBuf = [0.25f, -0.5f, 0.75f, -1.0f];
        float[4] sameBuf = [0.25f, -0.5f, 0.75f, -1.0f];
        immutable AudioMetrics exact = compareAudio(sameBuf[], refBuf[]);
        assert(exact.bitExact() && isInfinity(exact.snrDb));

        float[4] noisyBuf = [0.26f, -0.5f, 0.75f, -1.0f];
        immutable AudioMetrics noisy = compareAudio(noisyBuf[], refBuf[]);
        assert(!noisy.bitExact() && fabs(noisy.peakError - 0.01) < 1e-6 && noisy.snrDb > 20.0);

        float[4] nanBuf = [0.25f, float.nan, 0.75f, float.infinity];
        immutable AudioMetrics bad = compareAudio(nanBuf[], refBuf[]);
        assert(bad.hasNaN && bad.hasInf && !bad.bitExact());

        double phase = 0.0;
        assertBufferSizeInvariance(
            () { phase = 0.0; },
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                enum double inc = 2.0 * 3.14159265358979323846 * 330.0 / 44_100.0;
                foreach (i; 0 .. l.length) {
                    immutable float s = cast(float) sin(phase);
                    l[i] = s * 0.6f;
                    r[i] = s * -0.4f;
                    phase += inc;
                }
            },
            1024
        );

        immutable string goldenPath = makeUniqueTempWavPath("golden_harness");
        scope (exit) {
            if (exists(goldenPath)) {
                remove(goldenPath);
            }
        }
        string err;
        phase = 0.0;
        assert(renderOfflineToWav(
            goldenPath,
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                enum double inc = 2.0 * 3.14159265358979323846 * 220.0 / 44_100.0;
                foreach (i; 0 .. l.length) {
                    immutable float s = cast(float) sin(phase);
                    l[i] = s;
                    r[i] = -s;
                    phase += inc;
                }
            },
            512,
            44_100,
            128,
            err
        ), err);

        OwnedBuffer!float renderedL;
        OwnedBuffer!float renderedR;
        phase = 0.0;
        assert(renderOfflineStereo(
            (float[] l, float[] r, size_t startFrame) @nogc nothrow {
                cast(void) startFrame;
                enum double inc = 2.0 * 3.14159265358979323846 * 220.0 / 44_100.0;
                foreach (i; 0 .. l.length) {
                    immutable float s = cast(float) sin(phase);
                    l[i] = s;
                    r[i] = -s;
                    phase += inc;
                }
            },
            512,
            333,
            renderedL,
            renderedR
        ));

        immutable AudioMetrics goldenMetrics = compareWithGoldenWav(goldenPath, renderedL[], renderedR[], err);
        assert(err is null, err);
        assert(goldenMetrics.bitExact());
    }

    unittest {
        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            auto denorm = ScopedNoDenormals.enter();
            float[64] buf = 0.0f;
            foreach (i; 0 .. 64) {
                buf[i] = midiNoteToHz(cast(float)(i + 24)) * 0.001f;
            }
            assert(buf[0] > 0.0f);
        });

        {
            auto outerTrap = ScopedRtMallocTrap.enter(true);
            {
                auto innerTrap = ScopedRtMallocTrap.enter(true);
                immutable float v = dbToLinear(-6.0f);
                assert(v > 0.4f);
                assert(innerTrap.finish().clean());
            }
            assert(outerTrap.finish().clean());
        }

        immutable RtAllocationAudit mallocAudit = auditRtAllocations({
            void* ptr = malloc(128);
            assert(ptr !is null);
            (cast(ubyte*) ptr)[0] = 1;
            atomicStore!(MemoryOrder.seq)(gTrapEscapeSink, cast(size_t) ptr);
            free(ptr);
        });
        assert(!mallocAudit.clean() && mallocAudit.allocCallCount >= 1 && mallocAudit.freeCallCount >= 1);

        immutable RtAllocationAudit callocAudit = auditRtAllocations({
            void* ptr = calloc(8, 16);
            assert(ptr !is null);
            atomicStore!(MemoryOrder.seq)(gTrapEscapeSink, cast(size_t) ptr);
            free(ptr);
        });
        assert(!callocAudit.clean() && callocAudit.heapCallCount >= 2);

        immutable RtAllocationAudit reallocAudit = auditRtAllocations({
            void* p1 = malloc(32);
            assert(p1 !is null);
            (cast(ubyte*) p1)[0] = 2;
            atomicStore!(MemoryOrder.seq)(gTrapEscapeSink, cast(size_t) p1);
            void* p2 = realloc(p1, 256);
            assert(p2 !is null);
            atomicStore!(MemoryOrder.seq)(gTrapEscapeSink, cast(size_t) p2);
            free(p2);
        });
        assert(!reallocAudit.clean() && reallocAudit.heapCallCount >= 3);

        immutable RtAllocationAudit alignAudit = auditRtAllocations({
            void* ptr = null;
            assert(posix_memalign(&ptr, 64, 128) == 0 && ptr !is null);
            (cast(ubyte*) ptr)[0] = 3;
            atomicStore!(MemoryOrder.seq)(gTrapEscapeSink, cast(size_t) ptr);
            free(ptr);
        });
        assert(!alignAudit.clean() && alignAudit.heapCallCount >= 2);

        immutable RtAllocationAudit ownedBufAudit = auditRtAllocations({
            OwnedBuffer!float tmp;
            assert(OwnedBuffer!float.tryAllocate(64, tmp));
            atomicStore!(MemoryOrder.seq)(gTrapEscapeSink, cast(size_t) tmp.ptr);
        });
        assert(!ownedBufAudit.clean() && ownedBufAudit.heapCallCount >= 2);

        immutable RtAllocationAudit gcAudit = auditRtAllocations({
            auto gcSlice = new int[64];
            gcSlice[0] = 7;
            gGcEscapeSink = gcSlice;
            atomicStore!(MemoryOrder.seq)(gTrapEscapeSink, cast(size_t) gcSlice.ptr);
        });
        gGcEscapeSink = null;
        assert(!gcAudit.clean() && gcAudit.gcBytesAllocated > 0);

        bool caughtAssertion = false;
        try {
            verifyZeroRtAllocations({
                void* bad = malloc(64);
                if (bad !is null) {
                    (cast(ubyte*) bad)[0] = 4;
                    atomicStore!(MemoryOrder.seq)(gTrapEscapeSink, cast(size_t) bad);
                }
                free(bad);
            });
        } catch (AssertError) {
            caughtAssertion = true;
        }
        assert(caughtAssertion);

        bool caughtGcAssertion = false;
        try {
            verifyZeroRtAllocations({
                auto badGc = new float[32];
                badGc[0] = 1.0f;
                gGcEscapeSink = badGc;
                atomicStore!(MemoryOrder.seq)(gTrapEscapeSink, cast(size_t) badGc.ptr);
            });
        } catch (AssertError) {
            caughtGcAssertion = true;
        }
        gGcEscapeSink = null;
        assert(caughtGcAssertion);

        auto bgThread = new Thread({
            foreach (_; 0 .. 2000) {
                void* p = malloc(64);
                free(p);
            }
        });
        bgThread.start();
        immutable RtAllocationAudit isolationAudit = auditRtAllocations({
            float acc = 0.0f;
            foreach (i; 0 .. 10_000) {
                acc += dbToLinear(-cast(float)(i % 60));
            }
            assert(acc > 0.0f);
        });
        bgThread.join();
        assert(isolationAudit.clean());
    }
}
