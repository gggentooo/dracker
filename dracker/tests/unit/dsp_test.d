/**
 * File:         tests/unit/dsp_test.d
 * Module:       tests.unit.dsp_test
 * Phase:        Phase 1.1-1.5 — Core DSP Primitives & VoicePool Unit Tests
 *
 * Purpose:
 *   Validates tables, interpolation kernels, streaming resampler, radix-2 FFT (32..65536 in float/double), biquad and Cytomic SVF filters, PolyBLEP/drawn/noise oscillators, smoothers, envelopes, delay line, and VoicePool stealing/deactivation under @nogc and rt_malloc_trap audits.
 *
 * Real-Time & Safety Contract:
 *   Test module executing under dub test --compiler=ldc2 --config=headless.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, foundation.math_rt, dsp.*, tests.audio_harness, tests.rt_malloc_trap
 *   External: core.lifetime (move), std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - unittest: zero-NaN default init across all stateful DSP types
 *   - unittest: dsp.tables, dsp.interp, dsp.resampler chunk invariance & SNR
 *   - unittest: dsp.fft float/double round-trip error < 1e-6 across sizes 32..65536
 *   - unittest: dsp.filter_biquad & dsp.filter_svf frequency response, extreme sweeps, zero-NaN tails
 *   - unittest: dsp.oscillator, dsp.smoother, dsp.envelope, dsp.delay_line, dsp.voice_pool & rt_malloc_trap
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.dsp_test;

version (unittest) {
    import core.lifetime : move;
    import std.math : cos, exp, fabs, isFinite, isNaN, sin, sqrt;

    import dsp.delay_line : DelayLine;
    import dsp.envelope : AdsrEnvelope, BreakpointEnvelope, EnvBreakpoint, EnvStage;
    import dsp.fft : FftDouble, FftFloat, Radix2Fft;
    import dsp.filter_biquad : BiquadFilter, BiquadMode, CascadedBiquad, OnePoleFilter, OnePoleMode;
    import dsp.filter_svf : CytomicSvf, SvfMode, SvfOutputs;
    import dsp.interp : interpCatmullRom, interpHermite, interpHermiteTension, interpLinear,
        interpNearest, sampleBufferClamped, sampleBufferWrapped;
    import dsp.oscillator : DeterministicNoise, DrawnWaveOsc, OscWaveform, PolyBlepOsc;
    import dsp.resampler : FractionalResampler, ResampleCounts, ResampleQuality, StereoResampler;
    import dsp.smoother : LinearRamp, ParamSmoother;
    import dsp.tables : BLACKMAN_WINDOW, HALF_SINE_TABLE, HAMMING_WINDOW, HANN_WINDOW, PI_D,
        SINE_TABLE, TWO_PI_D, WindowKind, fillWindow, lookupCosine, lookupHalfSine, lookupSine;
    import dsp.voice_pool : VoicePool;
    import foundation.math_rt : ScopedNoDenormals;
    import foundation.memory : OwnedBuffer;
    import foundation.types : NoteId;
    import tests.audio_harness : AudioMetrics, compareAudio;
    import tests.rt_malloc_trap : verifyZeroRtAllocationsNothrow;

    private struct MockVoice {
        float level = 0.0f;
        bool active = false;
        bool releasing = false;
        uint noteTag = 0;

        @nogc nothrow:

        void trigger(uint tag, float amp) {
            active = true;
            releasing = false;
            level = amp;
            noteTag = tag;
        }

        void releaseNote() {
            if (active) {
                releasing = true;
            }
        }

        void stepDecay(float factor) {
            if (!active) {
                return;
            }
            if (releasing) {
                level *= factor;
                if (level < 1e-4f) {
                    level = 0.0f;
                    active = false;
                    releasing = false;
                }
            }
        }

        void reset() {
            level = 0.0f;
            active = false;
            releasing = false;
            noteTag = 0;
        }

        bool isActive() const pure @safe {
            return active;
        }

        bool isReleasing() const pure @safe {
            return releasing;
        }

        float currentLevel() const pure @safe {
            return level;
        }
    }

    private struct IncompleteVoice {
        bool active = false;
    }

    private double measureSineGain(
        ref BiquadFilter filter,
        double freqHz,
        double sampleRate,
        size_t settleFrames = 4096,
        size_t measureFrames = 2048
    ) @nogc nothrow {
        filter.reset();
        immutable double omega = TWO_PI_D * freqHz / sampleRate;
        foreach (i; 0 .. settleFrames) {
            cast(void) filter.processSample(cast(float) sin(omega * cast(double) i));
        }
        double peak = 0.0;
        foreach (i; settleFrames .. settleFrames + measureFrames) {
            immutable float y = filter.processSample(cast(float) sin(omega * cast(double) i));
            immutable double ay = fabs(cast(double) y);
            if (ay > peak) {
                peak = ay;
            }
        }
        return peak;
    }

    unittest {
        FractionalResampler resampler;
        StereoResampler stereoResampler;
        OnePoleFilter onePole;
        BiquadFilter biquad;
        CascadedBiquad!2 cascade;
        SvfOutputs svfOut;
        CytomicSvf svf;
        DeterministicNoise noise;
        PolyBlepOsc blepOsc;
        DrawnWaveOsc drawnOsc;
        ParamSmoother smoother;
        LinearRamp ramp;
        AdsrEnvelope adsr;
        EnvBreakpoint bp;
        BreakpointEnvelope bpEnv;
        DelayLine delayLine;
        VoicePool!(MockVoice, 8) pool;

        assert(!isNaN(resampler.evaluateCurrent()));
        float[1] stInitOutL = 0.0f;
        float[1] stInitOutR = 0.0f;
        immutable ResampleCounts stInitCounts = stereoResampler.processBlock(
            null, null, stInitOutL[], stInitOutR[], 1.0
        );
        assert(stInitCounts.consumed == 0 && !isNaN(stInitOutL[0]) && !isNaN(stInitOutR[0]));
        assert(!isNaN(onePole.processSample(0.0f)));
        assert(!isNaN(biquad.processSample(0.0f)));
        assert(!isNaN(cascade.processSample(0.0f)));
        assert(!isNaN(svfOut.low) && !isNaN(svfOut.band) && !isNaN(svfOut.high));
        assert(!isNaN(svf.processSample(0.0f, SvfMode.lpf)));
        assert(!isNaN(noise.white()));
        assert(!isNaN(blepOsc.nextSample(OscWaveform.sine)));
        assert(!isNaN(drawnOsc.nextSample(null)));
        assert(!isNaN(smoother.current()) && !isNaN(smoother.target()));
        assert(!isNaN(ramp.current()) && !isNaN(ramp.target()));
        assert(!isNaN(adsr.value()));
        assert(!isNaN(bp.timeSec) && !isNaN(bp.value) && !isNaN(bp.curve));
        assert(!isNaN(bpEnv.value()));
        assert(delayLine.empty());
        assert(pool.activeCount() == 0);
    }

    unittest {
        assert(SINE_TABLE.length == 4097);
        assert(HALF_SINE_TABLE.length == 2049);
        assert(HANN_WINDOW.length == 1024);
        assert(HAMMING_WINDOW.length == 1024);
        assert(BLACKMAN_WINDOW.length == 1024);

        assert(SINE_TABLE[0] == 0.0f && SINE_TABLE[$ - 1] == 0.0f);
        assert(fabs(SINE_TABLE[1024] - 1.0f) < 1e-6f);
        assert(fabs(SINE_TABLE[3072] + 1.0f) < 1e-6f);

        foreach (i; 0 .. 100) {
            immutable float phase = -1.25f + cast(float) i * 0.037f;
            immutable float actualSin = lookupSine(phase);
            immutable float expectedSin = cast(float) sin(TWO_PI_D * cast(double) phase);
            assert(fabs(actualSin - expectedSin) < 2e-5f);

            immutable float actualCos = lookupCosine(phase);
            immutable float expectedCos = cast(float) cos(TWO_PI_D * cast(double) phase);
            assert(fabs(actualCos - expectedCos) < 2e-5f);
        }
        assert(lookupSine(float.nan) == 0.0f && lookupSine(float.infinity) == 0.0f);
        assert(lookupCosine(float.nan) == 0.0f);

        assert(HALF_SINE_TABLE[0] == 0.0f && HALF_SINE_TABLE[1024] == 1.0f && HALF_SINE_TABLE[2048] == 0.0f);
        assert(lookupHalfSine(-0.5f) == 0.0f && lookupHalfSine(1.5f) == 0.0f && lookupHalfSine(float.nan) == 0.0f);
        assert(fabs(lookupHalfSine(0.5f) - 1.0f) < 1e-6f);
        assert(fabs(lookupHalfSine(0.25f) - cast(float) sin(PI_D * 0.25)) < 2e-5f);

        assert(HANN_WINDOW[0] == 0.0f && HANN_WINDOW[$ - 1] == 0.0f);
        assert(fabs(HAMMING_WINDOW[0] - 0.08f) < 1e-4f);
        assert(BLACKMAN_WINDOW[0] == 0.0f && BLACKMAN_WINDOW[$ - 1] == 0.0f);

        float[64] periodicHann = 0.0f;
        fillWindow(WindowKind.hann, periodicHann[], true);
        foreach (i; 0 .. 32) {
            assert(fabs((periodicHann[i] + periodicHann[i + 32]) - 1.0f) < 1e-5f);
        }

        float[1] singleWin = 0.0f;
        fillWindow(WindowKind.blackman, singleWin[]);
        assert(singleWin[0] == 1.0f);

        float[16] rectWin = 0.0f;
        fillWindow(WindowKind.rectangular, rectWin[]);
        foreach (w; rectWin) {
            assert(w == 1.0f);
        }

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            float[32] scratch = 0.0f;
            fillWindow(WindowKind.hamming, scratch[], false);
            immutable float s = lookupSine(0.123f) + lookupHalfSine(0.37f);
            assert(isFinite(s) && scratch[16] > 0.9f);
        });
    }

    unittest {
        assert(interpNearest(1.0f, 3.0f, 0.25f) == 1.0f);
        assert(interpNearest(1.0f, 3.0f, 0.75f) == 3.0f);
        assert(fabs(interpLinear(2.0f, 6.0f, 0.25f) - 3.0f) < 1e-6f);

        float[8] cubicSeq = 0.0f;
        foreach (i; 0 .. 8) {
            immutable float x = cast(float) i;
            cubicSeq[i] = 0.1f * x * x * x - 0.3f * x * x + 0.5f * x - 1.0f;
        }
        immutable float ym1 = cubicSeq[2];
        immutable float y0 = cubicSeq[3];
        immutable float y1 = cubicSeq[4];
        immutable float y2 = cubicSeq[5];
        immutable float t = 0.37f;
        immutable float exact = 0.1f * (3.0f + t) * (3.0f + t) * (3.0f + t)
            - 0.3f * (3.0f + t) * (3.0f + t) + 0.5f * (3.0f + t) - 1.0f;

        assert(fabs(interpHermite(ym1, y0, y1, y2, t) - exact) < 0.05f);
        assert(fabs(interpCatmullRom(ym1, y0, y1, y2, t) - exact) < 0.05f);
        assert(fabs(interpHermiteTension(ym1, y0, y1, y2, t, 0.0f, 0.0f)
            - interpCatmullRom(ym1, y0, y1, y2, t)) < 1e-5f);

        float[4] quadSeq = 0.0f;
        foreach (i; 0 .. 4) {
            immutable float x = cast(float) i;
            quadSeq[i] = 2.0f * x * x - 3.0f * x + 1.0f;
        }
        immutable float exactQuad = 2.0f * 1.4f * 1.4f - 3.0f * 1.4f + 1.0f;
        assert(fabs(interpCatmullRom(quadSeq[0], quadSeq[1], quadSeq[2], quadSeq[3], 0.4f) - exactQuad) < 1e-5f);

        assert(sampleBufferClamped(null, 0.5) == 0.0f);
        assert(sampleBufferClamped(cubicSeq[], float.nan) == 0.0f);
        assert(sampleBufferClamped(cubicSeq[], -10.0) == cubicSeq[0]);
        assert(sampleBufferClamped(cubicSeq[], 100.0) == cubicSeq[$ - 1]);
        assert(fabs(sampleBufferClamped(cubicSeq[], 3.0) - cubicSeq[3]) < 1e-6f);

        assert(sampleBufferWrapped(null, 0.5) == 0.0f);
        assert(sampleBufferWrapped(cubicSeq[], float.infinity) == 0.0f);
        assert(fabs(sampleBufferWrapped(cubicSeq[], -1.0) - cubicSeq[$ - 1]) < 1e-6f);
        assert(fabs(sampleBufferWrapped(cubicSeq[], 9.0) - cubicSeq[1]) < 1e-6f);
    }

    unittest {
        FractionalResampler unity;
        assert(unity.latencySamples() == 2);
        assert(unity.quality() == ResampleQuality.catmullRom);

        float[64] inUnity = 0.0f;
        float[64] outUnity = 0.0f;
        foreach (i; 0 .. 64) {
            inUnity[i] = cast(float) sin(TWO_PI_D * 440.0 * cast(double) i / 44100.0);
        }
        immutable ResampleCounts unityCounts = unity.processBlock(inUnity[], outUnity[], 1.0);
        assert(unityCounts.consumed == 64 && unityCounts.produced == 62);
        foreach (i; 0 .. unityCounts.produced) {
            assert(outUnity[i] == inUnity[i]);
        }

        enum size_t TOTAL_IN = 512;
        float[TOTAL_IN] srcSine = 0.0f;
        foreach (i; 0 .. TOTAL_IN) {
            srcSine[i] = cast(float) sin(TWO_PI_D * 500.0 * cast(double) i / 44100.0);
        }

        immutable double ratio = 44100.0 / 48000.0;
        FractionalResampler singlePass;
        float[600] outSingle = 0.0f;
        immutable ResampleCounts singleCounts = singlePass.processBlock(srcSine[], outSingle[], ratio);
        assert(singleCounts.consumed == TOTAL_IN && singleCounts.produced > 500);

        FractionalResampler chunkedPass;
        float[600] outChunked = 0.0f;
        size_t inPos = 0;
        size_t outPos = 0;
        while (inPos < TOTAL_IN) {
            immutable size_t inEnd = (inPos + 13 < TOTAL_IN) ? (inPos + 13) : TOTAL_IN;
            immutable ResampleCounts c = chunkedPass.processBlock(
                srcSine[inPos .. inEnd],
                outChunked[outPos .. $],
                ratio
            );
            inPos += c.consumed;
            outPos += c.produced;
            if (c.consumed == 0 && c.produced == 0) {
                break;
            }
        }
        assert(outPos == singleCounts.produced);
        immutable AudioMetrics chunkDiff = compareAudio(
            outChunked[0 .. outPos],
            outSingle[0 .. singleCounts.produced]
        );
        assert(chunkDiff.bitExact());

        float[600] refSine = 0.0f;
        foreach (i; 0 .. singleCounts.produced) {
            refSine[i] = cast(float) sin(TWO_PI_D * 500.0 * (cast(double) i * ratio) / 44100.0);
        }
        immutable AudioMetrics qualityMetrics = compareAudio(
            outSingle[8 .. singleCounts.produced - 4],
            refSine[8 .. singleCounts.produced - 4]
        );
        assert(qualityMetrics.snrDb > 70.0 && qualityMetrics.peakError < 1e-3);

        StereoResampler stereo;
        stereo.setQuality(ResampleQuality.linear);
        float[64] inR = 0.0f;
        foreach (i; 0 .. 64) {
            inR[i] = -inUnity[i];
        }
        float[128] outL = 0.0f;
        float[128] outR = 0.0f;
        immutable ResampleCounts stCounts = stereo.processBlock(inUnity[], inR[], outL[], outR[], 0.5);
        assert(stCounts.consumed == 64 && stCounts.produced == 124);
        foreach (i; 0 .. stCounts.produced) {
            assert(fabs(outL[i] + outR[i]) < 1e-6f);
        }

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            FractionalResampler rtRes;
            rtRes.setQuality(ResampleQuality.catmullRom);
            float[64] rtOut = 0.0f;
            immutable ResampleCounts rc = rtRes.processBlock(inUnity[], rtOut[], 1.0);
            assert(rc.produced == 62);
        });
    }

    unittest {
        assert(FftFloat.isValidSize(32) && FftFloat.isValidSize(65536) && !FftFloat.isValidSize(0) && !FftFloat.isValidSize(48));

        immutable size_t[12] sizes = [32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];
        foreach (n; sizes) {
            OwnedBuffer!float reF;
            OwnedBuffer!float imF;
            OwnedBuffer!float refReF;
            OwnedBuffer!float refImF;
            assert(OwnedBuffer!float.tryAllocate(n, reF));
            assert(OwnedBuffer!float.tryAllocate(n, imF));
            assert(OwnedBuffer!float.tryAllocate(n, refReF));
            assert(OwnedBuffer!float.tryAllocate(n, refImF));

            foreach (i; 0 .. n) {
                immutable double t = cast(double) i / cast(double) n;
                immutable float r = cast(float)(0.6 * cos(TWO_PI_D * 3.0 * t) + 0.35 * sin(TWO_PI_D * 11.0 * t));
                immutable float m = cast(float)(-0.45 * sin(TWO_PI_D * 7.0 * t));
                reF[i] = r;
                imF[i] = m;
                refReF[i] = r;
                refImF[i] = m;
            }

            FftFloat.forward(reF[], imF[]);
            FftFloat.inverse(reF[], imF[]);

            double maxErrF = 0.0;
            foreach (i; 0 .. n) {
                immutable double er = fabs(cast(double) reF[i] - cast(double) refReF[i]);
                immutable double ei = fabs(cast(double) imF[i] - cast(double) refImF[i]);
                if (er > maxErrF) maxErrF = er;
                if (ei > maxErrF) maxErrF = ei;
            }
            assert(maxErrF < 1e-6);

            OwnedBuffer!double reD;
            OwnedBuffer!double imD;
            OwnedBuffer!double refReD;
            OwnedBuffer!double refImD;
            assert(OwnedBuffer!double.tryAllocate(n, reD));
            assert(OwnedBuffer!double.tryAllocate(n, imD));
            assert(OwnedBuffer!double.tryAllocate(n, refReD));
            assert(OwnedBuffer!double.tryAllocate(n, refImD));

            foreach (i; 0 .. n) {
                immutable double t = cast(double) i / cast(double) n;
                immutable double r = 0.6 * cos(TWO_PI_D * 3.0 * t) + 0.35 * sin(TWO_PI_D * 11.0 * t);
                immutable double m = -0.45 * sin(TWO_PI_D * 7.0 * t);
                reD[i] = r;
                imD[i] = m;
                refReD[i] = r;
                refImD[i] = m;
            }

            FftDouble.forward(reD[], imD[]);
            FftDouble.inverse(reD[], imD[]);

            double maxErrD = 0.0;
            foreach (i; 0 .. n) {
                immutable double er = fabs(reD[i] - refReD[i]);
                immutable double ei = fabs(imD[i] - refImD[i]);
                if (er > maxErrD) maxErrD = er;
                if (ei > maxErrD) maxErrD = ei;
            }
            assert(maxErrD < 1e-12);
        }

        enum size_t TONE_N = 1024;
        float[TONE_N] toneInput = 0.0f;
        float[TONE_N] toneRe = 0.0f;
        float[TONE_N] toneIm = 0.0f;
        float[TONE_N] toneMag = 0.0f;
        float[TONE_N] toneDb = 0.0f;
        double timeEnergy = 0.0;
        foreach (i; 0 .. TONE_N) {
            immutable float s = cast(float) cos(TWO_PI_D * 17.0 * cast(double) i / cast(double) TONE_N);
            toneInput[i] = s;
            timeEnergy += cast(double) s * cast(double) s;
        }
        FftFloat.forwardReal(toneInput[], toneRe[], toneIm[]);
        FftFloat.computeMagnitude(toneRe[], toneIm[], toneMag[]);
        FftFloat.computeMagnitudeDb(toneRe[], toneIm[], toneDb[]);

        double freqEnergy = 0.0;
        foreach (i; 0 .. TONE_N) {
            freqEnergy += cast(double) toneMag[i] * cast(double) toneMag[i];
        }
        freqEnergy /= cast(double) TONE_N;
        assert(fabs(freqEnergy - timeEnergy) < 1e-3);
        assert(fabs(toneMag[17] - cast(float)(TONE_N / 2)) < 1e-2f);
        assert(fabs(toneDb[17] + 6.0206f) < 0.05f);
        assert(toneDb[0] == -144.0f);

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            FftFloat.forward(toneRe[], toneIm[]);
            FftFloat.inverse(toneRe[], toneIm[]);
            FftFloat.computeMagnitude(toneRe[], toneIm[], toneMag[]);
        });
    }

    unittest {
        auto denorm = ScopedNoDenormals.enter();

        OnePoleFilter oneLp;
        oneLp.configure(OnePoleMode.lowpass, 1000.0f, 48_000.0f);
        float dcSum = 0.0f;
        foreach (_; 0 .. 2000) {
            dcSum = oneLp.processSample(1.0f);
        }
        assert(fabs(dcSum - 1.0f) < 1e-5f);

        OnePoleFilter oneHp;
        oneHp.configure(OnePoleMode.highpass, 500.0f, 48_000.0f);
        float hpDc = 1.0f;
        foreach (_; 0 .. 4000) {
            hpDc = oneHp.processSample(1.0f);
        }
        assert(fabs(hpDc) < 1e-4f);

        BiquadFilter biquad;
        enum double SR = 48_000.0;
        immutable BiquadMode[8] allModes = [
            BiquadMode.lowpass,
            BiquadMode.highpass,
            BiquadMode.bandpass,
            BiquadMode.notch,
            BiquadMode.allpass,
            BiquadMode.peaking,
            BiquadMode.lowShelf,
            BiquadMode.highShelf
        ];
        immutable double[4] probeFreqs = [120.0, 1000.0, 3500.0, 12000.0];
        foreach (mode; allModes) {
            biquad.configure(mode, 1000.0f, 1.2f, 6.0f, cast(float) SR);
            foreach (f; probeFreqs) {
                immutable double measured = measureSineGain(biquad, f, SR);
                immutable double analytical = biquad.magnitudeAt(f, SR);
                assert(fabs(measured - analytical) < 1e-2);
            }
        }

        biquad.configure(BiquadMode.notch, 2000.0f, 4.0f, 0.0f, cast(float) SR);
        assert(measureSineGain(biquad, 2000.0, SR) < 1e-3);
        assert(biquad.magnitudeAt(2000.0, SR) < 1e-6);

        biquad.configure(BiquadMode.allpass, 1500.0f, 0.707f, 0.0f, cast(float) SR);
        foreach (f; probeFreqs) {
            assert(fabs(biquad.magnitudeAt(f, SR) - 1.0) < 1e-6);
        }

        biquad.configure(BiquadMode.lowpass, 20.0f, 0.7071f, 0.0f, 192_000.0f);
        biquad.reset();
        float y = biquad.processSample(1.0f);
        assert(isFinite(y));
        foreach (_; 0 .. 200_000) {
            y = biquad.processSample(0.0f);
            assert(isFinite(y));
        }
        assert(biquad.isTailSilent());
        assert(isFinite(biquad.processSample(float.nan)));

        CascadedBiquad!2 cascade;
        cascade.configureAll(BiquadMode.lowpass, 1000.0f, 0.7071f, 0.0f, cast(float) SR);
        float[1024] block = 0.0f;
        foreach (i; 0 .. 1024) {
            block[i] = cast(float) sin(TWO_PI_D * 8000.0 * cast(double) i / SR);
        }
        cascade.processBlock(block[]);
        assert(fabs(block[$ - 1]) < 5e-3f);
        foreach (_; 0 .. 20_000) {
            cast(void) cascade.processSample(0.0f);
        }
        assert(cascade.isTailSilent());

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            BiquadFilter rtBq;
            rtBq.configure(BiquadMode.peaking, 1200.0f, 2.0f, -4.5f, 44_100.0f);
            float[64] rtBuf = 0.25f;
            rtBq.processBlock(rtBuf[]);
            assert(isFinite(rtBuf[63]));
        });
    }

    unittest {
        auto denorm = ScopedNoDenormals.enter();

        CytomicSvf svf;
        svf.setParams(1000.0f, 0.5f, 48_000.0f);

        immutable SvfOutputs identity = svf.processAll(0.75f);
        immutable float reconstructed = identity.high + (2.0f - 1.98f * 0.5f) * identity.band + identity.low;
        assert(fabs(reconstructed - 0.75f) < 1e-5f);

        svf.reset();
        svf.setParams(800.0f, 0.0f, 48_000.0f);
        float dcLow = 0.0f;
        float dcHigh = 0.0f;
        foreach (_; 0 .. 4096) {
            immutable SvfOutputs o = svf.processAll(1.0f);
            dcLow = o.low;
            dcHigh = o.high;
        }
        assert(fabs(dcLow - 1.0f) < 1e-5f && fabs(dcHigh) < 1e-5f);

        svf.reset();
        svf.setParamsQ(2000.0f, 4.0f, 48_000.0f);
        foreach (i; 0 .. 4096) {
            cast(void) svf.processSample(cast(float) sin(TWO_PI_D * 2000.0 * cast(double) i / 48_000.0), SvfMode.notch);
        }
        float notchPeak = 0.0f;
        foreach (i; 4096 .. 6144) {
            immutable float y = svf.processSample(
                cast(float) sin(TWO_PI_D * 2000.0 * cast(double) i / 48_000.0),
                SvfMode.notch
            );
            immutable float ay = fabs(y);
            if (ay > notchPeak) notchPeak = ay;
        }
        assert(notchPeak < 2e-3f);

        svf.reset();
        foreach (i; 0 .. 10_000) {
            immutable float mod = 0.5f + 0.5f * cast(float) sin(TWO_PI_D * 37.0 * cast(double) i / 48_000.0);
            immutable float cutoff = 20.0f + mod * 18_000.0f;
            svf.setParams(cutoff, 0.98f, 48_000.0f);
            immutable float x = (i == 0) ? 1.0f : (i < 5000 ? 0.5f * cast(float) sin(0.2 * i) : 0.0f);
            immutable float y = svf.processSample(x, SvfMode.lpf);
            assert(isFinite(y) && fabs(y) < 100.0f);
        }
        foreach (_; 0 .. 100_000) {
            immutable float tail = svf.processSample(0.0f, SvfMode.lpf);
            assert(isFinite(tail));
        }
        assert(svf.isTailSilent());
        assert(isFinite(svf.processSample(float.nan, SvfMode.allpass)));

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            CytomicSvf rtSvf;
            rtSvf.setParams(1500.0f, 0.6f, 44_100.0f);
            float[64] buf = 0.1f;
            rtSvf.processBlock(buf[], SvfMode.bpf);
            assert(isFinite(buf[0]));
        });
    }

    unittest {
        PolyBlepOsc osc;
        osc.setFrequency(440.0f, 44_100.0f);
        double dcSum = 0.0;
        foreach (i; 0 .. 4410) {
            immutable float s = osc.nextSample(OscWaveform.sine);
            immutable float refS = cast(float) sin(TWO_PI_D * 440.0 * cast(double) i / 44_100.0);
            assert(fabs(s - refS) < 5e-4f);
            dcSum += s;
        }
        assert(fabs(dcSum / 4410.0) < 0.01);

        immutable OscWaveform[3] harmonicShapes = [OscWaveform.saw, OscWaveform.pulse, OscWaveform.triangle];
        foreach (shape; harmonicShapes) {
            osc.reset();
            osc.setFrequency(110.0f, 44_100.0f);
            double sum = 0.0;
            float maxAbs = 0.0f;
            foreach (_; 0 .. 44_100) {
                immutable float s = osc.nextSample(shape, 0.5f);
                assert(isFinite(s));
                immutable float as = fabs(s);
                if (as > maxAbs) maxAbs = as;
                sum += s;
            }
            assert(maxAbs <= 1.05f && fabs(sum / 44_100.0) < 0.01);
        }

        osc.reset();
        osc.setFrequency(100.0f, 44_100.0f);
        double pwmMean = 0.0;
        foreach (_; 0 .. 44_100) {
            pwmMean += osc.nextSample(OscWaveform.pulse, 0.25f);
        }
        pwmMean /= 44_100.0;
        assert(fabs(pwmMean - (-0.5)) < 0.02);

        enum size_t ALIAS_N = 2048;
        enum double ALIAS_FREQ = 3719.0;
        float[ALIAS_N] blepSaw = 0.0f;
        float[ALIAS_N] naiveSaw = 0.0f;
        float[ALIAS_N] blepRe = 0.0f;
        float[ALIAS_N] blepIm = 0.0f;
        float[ALIAS_N] naiveRe = 0.0f;
        float[ALIAS_N] naiveIm = 0.0f;
        float[ALIAS_N] blepMag = 0.0f;
        float[ALIAS_N] naiveMag = 0.0f;
        float[ALIAS_N] win = 0.0f;
        fillWindow(WindowKind.hann, win[], true);

        osc.reset();
        osc.setFrequency(cast(float) ALIAS_FREQ, 44_100.0f);
        double naivePhase = 0.0;
        immutable double naiveInc = ALIAS_FREQ / 44_100.0;
        foreach (i; 0 .. ALIAS_N) {
            blepSaw[i] = osc.nextSample(OscWaveform.saw) * win[i];
            naiveSaw[i] = cast(float)(2.0 * naivePhase - 1.0) * win[i];
            naivePhase += naiveInc;
            if (naivePhase >= 1.0) {
                naivePhase -= 1.0;
            }
        }
        FftFloat.forwardReal(blepSaw[], blepRe[], blepIm[]);
        FftFloat.forwardReal(naiveSaw[], naiveRe[], naiveIm[]);
        FftFloat.computeMagnitude(blepRe[], blepIm[], blepMag[]);
        FftFloat.computeMagnitude(naiveRe[], naiveIm[], naiveMag[]);

        double blepAliasEnergy = 0.0;
        double naiveAliasEnergy = 0.0;
        foreach (bin; 8 .. ALIAS_N / 2) {
            bool nearHarmonic = false;
            foreach (h; 1 .. 6) {
                immutable double hBin = cast(double) h * ALIAS_FREQ * cast(double) ALIAS_N / 44_100.0;
                if (fabs(cast(double) bin - hBin) <= 4.0) {
                    nearHarmonic = true;
                    break;
                }
            }
            if (!nearHarmonic) {
                blepAliasEnergy += cast(double) blepMag[bin] * cast(double) blepMag[bin];
                naiveAliasEnergy += cast(double) naiveMag[bin] * cast(double) naiveMag[bin];
            }
        }
        assert(naiveAliasEnergy > 0.0 && blepAliasEnergy < naiveAliasEnergy * 0.15);

        float[64] drawnWave = 0.0f;
        foreach (i; 0 .. 64) {
            drawnWave[i] = cast(float) sin(TWO_PI_D * cast(double) i / 64.0);
        }
        DrawnWaveOsc drawn;
        drawn.setFrequency(1000.0f, 44_100.0f);
        assert(drawn.nextSample(null) == 0.0f);
        immutable float d0 = drawn.nextSample(drawnWave[]);
        immutable float d1 = drawn.nextSample(drawnWave[]);
        assert(fabs(d0) < 1e-4f && d1 > 0.1f);
        drawn.syncPhase(0.25f);
        assert(fabs(drawn.nextSample(drawnWave[]) - 1.0f) < 1e-3f);

        DeterministicNoise n1;
        DeterministicNoise n2;
        n1.seed(42);
        n2.seed(42);
        foreach (_; 0 .. 128) {
            immutable float w1 = n1.white();
            immutable float w2 = n2.white();
            assert(w1 == w2 && w1 >= -1.0f && w1 <= 1.0f);
        }
        n1.reset(42);
        n2.reset(42);
        foreach (_; 0 .. 128) {
            immutable float p1 = n1.pink();
            immutable float p2 = n2.pink();
            assert(p1 == p2 && isFinite(p1) && p1 >= -1.0f && p1 <= 1.0f);
        }

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            PolyBlepOsc rtOsc;
            rtOsc.setFrequency(220.0f, 48_000.0f);
            float acc = 0.0f;
            foreach (_; 0 .. 64) {
                acc += rtOsc.nextSample(OscWaveform.triangle);
            }
            assert(isFinite(acc));
        });
    }

    unittest {
        ParamSmoother smoother;
        smoother.prepare(1000.0f, 10.0f, 0.0f);
        assert(smoother.current() == 0.0f && smoother.isSettled());

        smoother.setTarget(1.0f, true);
        assert(smoother.current() == 1.0f && smoother.isSettled());

        smoother.reset(0.0f);
        smoother.setTarget(1.0f, false);
        assert(!smoother.isSettled());
        float atTau = 0.0f;
        foreach (_; 0 .. 10) {
            atTau = smoother.next();
        }
        assert(fabs(atTau - cast(float)(1.0 - exp(-1.0))) < 1e-4f);

        foreach (_; 0 .. 500) {
            cast(void) smoother.next();
        }
        assert(smoother.isSettled() && smoother.current() == 1.0f);

        smoother.setTarget(float.nan, true);
        assert(smoother.current() == 0.0f);

        LinearRamp ramp;
        ramp.reset(0.0f);
        ramp.setTarget(10.0f, 10);
        foreach (_; 0 .. 5) {
            cast(void) ramp.next();
        }
        assert(fabs(ramp.current() - 5.0f) < 1e-5f && !ramp.isSettled());
        foreach (_; 0 .. 5) {
            cast(void) ramp.next();
        }
        assert(ramp.isSettled() && ramp.current() == 10.0f);

        ramp.setTargetMs(2.0f, 0.0f, 48_000.0f);
        assert(ramp.isSettled() && ramp.current() == 2.0f);

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            ParamSmoother rtSm;
            rtSm.prepare(44_100.0f, 5.0f, 0.0f);
            rtSm.setTarget(1.0f, false);
            float[64] outSm = 0.0f;
            rtSm.processBlock(outSm[]);
            assert(outSm[63] > outSm[0]);
        });
    }

    unittest {
        AdsrEnvelope adsr;
        adsr.prepare(1000.0f);
        adsr.setParams(0.01f, 0.02f, 0.5f, 0.02f);
        adsr.setCurves(1.0f, 1.0f, 1.0f);
        assert(!adsr.isActive() && adsr.stage() == EnvStage.idle);

        adsr.trigger();
        assert(adsr.isActive() && adsr.stage() == EnvStage.attack);
        foreach (_; 0 .. 10) {
            cast(void) adsr.next();
        }
        assert(fabs(adsr.value() - 1.0f) < 1e-5f && adsr.stage() == EnvStage.decay);

        foreach (_; 0 .. 20) {
            cast(void) adsr.next();
        }
        assert(fabs(adsr.value() - 0.5f) < 1e-5f && adsr.stage() == EnvStage.sustain);

        adsr.trigger(true);
        assert(adsr.stage() == EnvStage.sustain && fabs(adsr.value() - 0.5f) < 1e-5f);

        adsr.releaseNote();
        assert(adsr.isReleasing());
        foreach (_; 0 .. 20) {
            cast(void) adsr.next();
        }
        assert(!adsr.isActive() && adsr.stage() == EnvStage.idle && adsr.value() == 0.0f);

        adsr.setParams(0.0f, 0.0f, 0.8f, 0.0f);
        adsr.trigger();
        assert(adsr.stage() == EnvStage.sustain && fabs(adsr.value() - 0.8f) < 1e-6f);
        adsr.releaseNote();
        assert(adsr.stage() == EnvStage.idle && adsr.value() == 0.0f);

        adsr.setParams(0.01f, 0.01f, 0.5f, 0.01f);
        adsr.setCurves(2.0f, 2.0f, 2.0f);
        adsr.trigger();
        foreach (_; 0 .. 5) {
            cast(void) adsr.next();
        }
        assert(fabs(adsr.value() - 0.25f) < 1e-4f);

        adsr.prepare(1024.0f);
        adsr.setParams(0.0f, 0.0625f, 0.0f, 0.0625f);
        adsr.setCurves(1.0f, 3.0f, 3.0f);
        adsr.trigger();
        float prevDecay = adsr.value();
        float decayQuarter = 0.0f;
        foreach (step; 0 .. 64) {
            immutable float v = adsr.next();
            assert(v <= prevDecay + 1e-6f);
            prevDecay = v;
            if (step == 15) {
                decayQuarter = v;
            }
        }
        assert(decayQuarter > 0.0f && decayQuarter < 0.5f);
        assert(adsr.value() == 0.0f && adsr.stage() == EnvStage.sustain);

        adsr.setParams(0.0f, 0.0f, 1.0f, 0.0625f);
        adsr.setCurves(1.0f, 3.0f, 3.0f);
        adsr.trigger();
        assert(adsr.value() == 1.0f);
        adsr.releaseNote();
        float prevRel = adsr.value();
        float relQuarter = 0.0f;
        foreach (step; 0 .. 64) {
            immutable float v = adsr.next();
            assert(v <= prevRel + 1e-6f);
            prevRel = v;
            if (step == 15) {
                relQuarter = v;
            }
        }
        assert(relQuarter > 0.0f && relQuarter < 0.5f);
        assert(!adsr.isActive() && adsr.stage() == EnvStage.idle && adsr.value() == 0.0f);

        immutable EnvBreakpoint[4] points = [
            EnvBreakpoint(0.0f, 0.0f, 1.0f),
            EnvBreakpoint(0.01f, 1.0f, 1.0f),
            EnvBreakpoint(0.02f, 0.5f, 1.0f),
            EnvBreakpoint(0.04f, 0.0f, 1.0f)
        ];
        BreakpointEnvelope bpEnv;
        bpEnv.prepare(1000.0f);
        bpEnv.trigger(points[], 2, -1, -1);
        assert(bpEnv.isActive());
        foreach (_; 0 .. 30) {
            cast(void) bpEnv.next(points[]);
        }
        assert(bpEnv.isActive() && fabs(bpEnv.value() - 0.5f) < 1e-4f);
        bpEnv.releaseNote();
        foreach (_; 0 .. 25) {
            cast(void) bpEnv.next(points[]);
        }
        assert(!bpEnv.isActive() && bpEnv.value() == 0.0f);

        immutable EnvBreakpoint[3] loopPoints = [
            EnvBreakpoint(0.0f, 0.0f, 1.0f),
            EnvBreakpoint(0.01f, 1.0f, 1.0f),
            EnvBreakpoint(0.02f, 0.2f, 1.0f)
        ];
        bpEnv.trigger(loopPoints[], -1, 0, 2);
        foreach (_; 0 .. 45) {
            cast(void) bpEnv.next(loopPoints[]);
            assert(bpEnv.isActive());
        }

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            AdsrEnvelope rtAdsr;
            rtAdsr.prepare(44_100.0f);
            rtAdsr.trigger();
            immutable float v = rtAdsr.next();
            assert(v > 0.0f);
        });
    }

    unittest {
        DelayLine dl;
        assert(dl.tryInit(12));
        assert(dl.capacity() >= 16 && (dl.capacity() & (dl.capacity() - 1)) == 0);
        assert(dl.maxDelay() == 12);

        dl.write(1.0f);
        foreach (_; 0 .. 5) {
            dl.write(0.0f);
        }
        assert(dl.readTap(5) == 1.0f);
        assert(dl.readTap(4) == 0.0f && dl.readTap(6) == 0.0f);
        assert(fabs(dl.readLinear(4.5f) - 0.5f) < 1e-6f);
        assert(fabs(dl.readLinear(0.5f)) < 1e-6f);
        assert(fabs(dl.readCatmullRom(5.0f) - 1.0f) < 1e-6f);
        assert(fabs(dl.readCatmullRom(0.25f)) < 1e-6f);

        dl.write(float.nan);
        assert(dl.readTap(0) == 0.0f);

        dl.clear();
        assert(dl.readTap(0) == 0.0f && dl.readTap(5) == 0.0f);

        DelayLine moved;
        moved = move(dl);
        assert(dl.empty() && moved.capacity() >= 16);

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            foreach (k; 0 .. 128) {
                moved.write(cast(float) k * 0.01f);
                immutable float t = moved.readCatmullRom(3.37f) + moved.readLinear(0.5f);
                assert(isFinite(t));
            }
        });
    }

    unittest {
        static assert(!__traits(compiles, VoicePool!(IncompleteVoice, 4)));

        VoicePool!(MockVoice, 4) pool;
        bool stolen = false;

        auto v1 = pool.allocateVoice(NoteId(1), stolen);
        assert(!stolen && v1 !is null);
        v1.trigger(1, 0.8f);

        auto v2 = pool.allocateVoice(NoteId(2), stolen);
        assert(!stolen);
        v2.trigger(2, 0.6f);

        auto v3 = pool.allocateVoice(NoteId(3), stolen);
        assert(!stolen);
        v3.trigger(3, 0.9f);

        auto v4 = pool.allocateVoice(NoteId(4), stolen);
        assert(!stolen);
        v4.trigger(4, 0.4f);

        assert(pool.activeCount() == 4 && pool.hasActiveVoices());
        assert(pool.findVoice(NoteId(2)) !is null);
        assert(pool.findVoice(NoteId(99)) is null);

        auto v2Retrigger = pool.allocateVoice(NoteId(2), stolen);
        assert(!stolen && v2Retrigger is v2);

        assert(pool.releaseVoice(NoteId(3)));
        auto v5 = pool.allocateVoice(NoteId(5), stolen);
        assert(stolen && v5 is v3);
        v5.trigger(5, 0.9f);

        auto v6 = pool.allocateVoice(NoteId(6), stolen);
        assert(stolen && v6 is v4);
        v6.trigger(6, 0.5f);

        pool.allNotesOff();
        foreach (_; 0 .. 200) {
            pool.forEachActive((ref MockVoice v, NoteId id) @nogc nothrow {
                cast(void) id;
                v.stepDecay(0.8f);
            });
        }
        assert(pool.activeCount() == 0 && !pool.hasActiveVoices());

        pool.setMaxPolyphony(2);
        assert(pool.maxPolyphony() == 2);
        pool.allocateVoice(NoteId(10), stolen).trigger(10, 0.7f);
        pool.allocateVoice(NoteId(11), stolen).trigger(11, 0.7f);
        pool.allocateVoice(NoteId(12), stolen).trigger(12, 0.7f);
        assert(stolen && pool.activeCount() == 2);
        pool.resetAll();
        assert(pool.activeCount() == 0);

        verifyZeroRtAllocationsNothrow(() @nogc nothrow {
            VoicePool!(MockVoice, 16) rtPool;
            bool rtStolen = false;
            foreach (k; 1 .. 10_001) {
                auto slot = rtPool.allocateVoice(NoteId(cast(uint)(k % 24 + 1)), rtStolen);
                slot.trigger(cast(uint) k, 0.5f);
                if ((k % 3) == 0) {
                    rtPool.releaseVoice(NoteId(cast(uint)((k - 1) % 24 + 1)));
                }
                rtPool.forEachActive((ref MockVoice v, NoteId id) @nogc nothrow {
                    cast(void) id;
                    v.stepDecay(0.5f);
                });
            }
            rtPool.allNotesOff();
            foreach (_; 0 .. 64) {
                rtPool.forEachActive((ref MockVoice v, NoteId id) @nogc nothrow {
                    cast(void) id;
                    v.stepDecay(0.5f);
                });
            }
            assert(rtPool.activeCount() == 0);
        });
    }
}
