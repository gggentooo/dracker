/**
 * File:         source/modules/effects/vocal_filter.d
 * Module:       modules.effects.vocal_filter
 * Phase:        Phase 4.7 (Tier 2) — Formant Vowel Filter Bank
 *
 * Purpose:
 *   Parallel 3-band bandpass formant filter bank morphing smoothly across A/E/I/O/U vowels with voice-register scaling and CV morph modulation.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; double-precision RBJ bandpass filter registers with silent tail skip.
 *
 * Dependencies:
 *   Internal: dsp.filter_biquad, dsp.smoother, graph.buffer, graph.context, graph.module_api, graph.port
 *   External: std.math (exp2, fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct VocalFilter (typeId = "fx.vocal_filter", ports: audioStereo in, cvControl vowelCv, audioStereo out)
 *   - @Param vowelMorph, formantShift, bandwidth, voiceType, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.vocal_filter;

import std.math : exp2, fabs, isFinite;

import dsp.filter_biquad : BiquadFilter, BiquadMode;
import dsp.smoother : ParamSmoother;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo formant vowel filter interpolating A, E, I, O, and U vocal tract resonances.
 */
struct VocalFilter {
    enum string typeId = "fx.vocal_filter";
    enum string displayName = "Vocal Filter";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("vowelCv", "Vowel CV", PortKind.cvControl, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Vowel", 0.0f, 4.0f, 0.0f, "", ParamScale.linear)
    float vowelMorph = 0.0f;

    @Param("Formant Shift", -12.0f, 12.0f, 0.0f, "st", ParamScale.linear)
    float formantShift = 0.0f;

    @Param("Bandwidth", 0.2f, 3.0f, 1.0f, "x", ParamScale.logarithmic)
    float bandwidth = 1.0f;

    @Param("Voice Type", 0.0f, 3.0f, 0.0f, "", ParamScale.discrete,
        ["Soprano", "Alto", "Tenor", "Bass"])
    float voiceType = 0.0f;

    @Param("Mix", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float mix = 1.0f;

    private static immutable float[3][5] VOWEL_FREQ = [
        [730.0f, 1090.0f, 2440.0f],
        [530.0f, 1840.0f, 2480.0f],
        [270.0f, 2290.0f, 3010.0f],
        [570.0f, 840.0f, 2410.0f],
        [300.0f, 870.0f, 2240.0f]
    ];

    private static immutable float[3][5] VOWEL_AMP = [
        [1.0f, 0.5f, 0.25f],
        [1.0f, 0.45f, 0.28f],
        [1.0f, 0.35f, 0.22f],
        [1.0f, 0.4f, 0.18f],
        [1.0f, 0.3f, 0.14f]
    ];

    private BiquadFilter[3][2] formants_;
    private ParamSmoother morphSmoother_;
    private ParamSmoother mixSmoother_;
    private float sampleRate_ = 44_100.0f;

    @nogc nothrow:

    /**
     * Initializes formant filter stages and morph/mix smoothers cleanly.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        morphSmoother_.prepare(sampleRate_, 8.0f, vowelMorph);
        mixSmoother_.prepare(sampleRate_, 5.0f, mix);
        reset();
        configureFormants(vowelMorph, sampleRate_);
    }

    /**
     * Clears filter delay registers and snaps smoothers immediately.
     */
    void reset() {
        foreach (ch; 0 .. 2) {
            foreach (k; 0 .. 3) {
                formants_[ch][k].reset();
            }
        }
        morphSmoother_.reset(vowelMorph);
        mixSmoother_.reset(mix);
    }

    /**
     * Updates morph/mix smoothers and recomputes formant frequencies when parameters change.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap smoothers immediately.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        static if (field == "vowelMorph") {
            morphSmoother_.setTarget(vowelMorph, instant);
        } else static if (field == "mix") {
            mixSmoother_.setTarget(mix, instant);
        }
        if (instant || field == "formantShift" || field == "bandwidth" || field == "voiceType") {
            configureFormants(morphSmoother_.current(), sampleRate_);
        }
    }

    /**
     * Filters stereo audio through parallel interpolated formant bandpass resonances.
     *
     * Params:
     *   io = Stereo input/output bundle plus optional vowelCv modulation.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while output or formant filter tail exceeds silence threshold.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        if (ctx.inputSilent && isTailSilent()) {
            io.audioOut[0][0 .. ctx.frames] = 0.0f;
            io.audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) morphSmoother_.next();
                cast(void) mixSmoother_.next();
            }
            return false;
        }

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable bool hasCv = io.numCvIn > 0 && io.cvIn[0].connected && !io.cvIn[0].silent
            && io.cvIn[0].samples.length >= ctx.frames;
        const inL = io.audioIn[0];
        const inR = io.audioIn[1];
        auto outL = io.audioOut[0];
        auto outR = io.audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            float m = morphSmoother_.next();
            immutable float wetMix = mixSmoother_.next();
            if (hasCv) {
                immutable float cv = isFinite(io.cvIn[0].samples[i]) ? io.cvIn[0].samples[i] : 0.0f;
                m += cv * 2.0f;
            }
            if (m < 0.0f) m = 0.0f;
            if (m > 4.0f) m = 4.0f;

            float[3] amps = 1.0f;
            configureFormants(m, sr, amps);

            immutable float dryL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float dryR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            float wetL = 0.0f;
            float wetR = 0.0f;
            foreach (k; 0 .. 3) {
                wetL += formants_[0][k].processSample(dryL) * amps[k];
                wetR += formants_[1][k].processSample(dryR) * amps[k];
            }

            immutable float yL = dryL + wetMix * (wetL - dryL);
            immutable float yR = dryR + wetMix * (wetR - dryR);
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;
        }

        return peak > 1e-7f || !isTailSilent();
    }

    private void configureFormants(float morph, float sr) pure @safe {
        float[3] unused = 0.0f;
        configureFormants(morph, sr, unused);
    }

    private void configureFormants(float morph, float sr, out float[3] outAmps) pure @safe {
        float clamped = isFinite(morph) ? (morph < 0.0f ? 0.0f : (morph > 4.0f ? 4.0f : morph)) : 0.0f;
        size_t i0 = cast(size_t) clamped;
        if (i0 > 3) i0 = 3;
        immutable size_t i1 = i0 + 1;
        immutable float frac = clamped - cast(float) i0;

        static immutable float[4] voiceScale = [1.18f, 1.02f, 0.88f, 0.76f];
        int vt = isFinite(voiceType) ? cast(int)(voiceType + 0.5f) : 0;
        if (vt < 0) vt = 0;
        if (vt > 3) vt = 3;

        immutable float shiftMul = cast(float) exp2(
            cast(double)(isFinite(formantShift) ? formantShift : 0.0f) / 12.0
        ) * voiceScale[vt];
        immutable float bw = isFinite(bandwidth)
            ? (bandwidth < 0.2f ? 0.2f : (bandwidth > 3.0f ? 3.0f : bandwidth)) : 1.0f;
        immutable float q = 8.0f / bw;

        foreach (k; 0 .. 3) {
            immutable float freq = (VOWEL_FREQ[i0][k] + frac * (VOWEL_FREQ[i1][k] - VOWEL_FREQ[i0][k])) * shiftMul;
            outAmps[k] = VOWEL_AMP[i0][k] + frac * (VOWEL_AMP[i1][k] - VOWEL_AMP[i0][k]);
            formants_[0][k].configure(BiquadMode.bandpass, freq, q, 0.0f, sr);
            formants_[1][k].configure(BiquadMode.bandpass, freq, q, 0.0f, sr);
        }
    }

    private bool isTailSilent() const pure @safe {
        foreach (ch; 0 .. 2) {
            foreach (k; 0 .. 3) {
                if (!formants_[ch][k].isTailSilent(1e-7)) {
                    return false;
                }
            }
        }
        return true;
    }
}
