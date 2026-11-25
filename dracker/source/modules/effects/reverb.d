/**
 * File:         source/modules/effects/reverb.d
 * Module:       modules.effects.reverb
 * Phase:        Phase 4.1 (Tier 1) — Algorithmic FDN / Schroeder-Moorer Reverb
 *
 * Purpose:
 *   Dense 8-channel Householder feedback delay network reverberator with pre-delay, dampened tails, freeze mode, stereo width control, and decay-tail silence detection.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); relies on ScopedNoDenormals and pre-allocated DelayLines.
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.filter_biquad, dsp.smoother, graph.context, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Reverb (typeId = "fx.reverb", ports: audioStereo in/out)
 *   - @Param dry, wet, roomSize, dampHz, stereoWidth, preDelayMs, freeze
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.reverb;

import std.math : fabs, isFinite;

import dsp.delay_line : DelayLine;
import dsp.filter_biquad : OnePoleFilter, OnePoleMode;
import dsp.smoother : ParamSmoother;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * 8-tap Householder FDN algorithmic stereo reverberator with pre-delay and freeze mode.
 */
struct Reverb {
    enum string typeId = "fx.reverb";
    enum string displayName = "Reverb";
    enum ModuleCategory category = ModuleCategory.effect;
    enum size_t NUM_LINES = 8;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Dry", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float dry = 1.0f;

    @Param("Wet", 0.0f, 1.0f, 0.35f, "", ParamScale.linear)
    float wet = 0.35f;

    @Param("Room Size", 0.0f, 1.0f, 0.65f, "", ParamScale.linear)
    float roomSize = 0.65f;

    @Param("Damping", 400.0f, 20_000.0f, 5500.0f, "Hz", ParamScale.logarithmic)
    float dampHz = 5500.0f;

    @Param("Stereo Width", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float stereoWidth = 1.0f;

    @Param("Pre-Delay", 0.0f, 200.0f, 12.0f, "ms", ParamScale.linear)
    float preDelayMs = 12.0f;

    @Param("Freeze", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete)
    float freeze = 0.0f;

    private static immutable size_t[NUM_LINES] BASE_DELAYS_44K = [
        1087, 1283, 1511, 1777, 2081, 2411, 2791, 3191
    ];

    private DelayLine[NUM_LINES] fdnLines_;
    private OnePoleFilter[NUM_LINES] dampFilters_;
    private DelayLine[2] preDelayLines_;
    private size_t[NUM_LINES] lineLengths_ = 1024;
    private ParamSmoother drySmoother_;
    private ParamSmoother wetSmoother_;
    private float sampleRate_ = 44_100.0f;
    private float fdnEnergy_ = 0.0f;

    @nogc nothrow:

    /**
     * Pre-allocates all 8 FDN delay lines, pre-delay lines, damping filters, and smoothers.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        immutable double rateScale = cast(double) sampleRate_ / 44_100.0;

        foreach (k; 0 .. NUM_LINES) {
            size_t len = cast(size_t)(cast(double) BASE_DELAYS_44K[k] * rateScale + 0.5);
            if (len < 64) len = 64;
            lineLengths_[k] = len;
            if (fdnLines_[k].empty() || fdnLines_[k].maxDelay() < len + 8) {
                fdnLines_[k].tryInit(len + 8);
            }
            dampFilters_[k].configure(OnePoleMode.lowpass, dampHz, sampleRate_);
        }

        immutable size_t maxPre = cast(size_t)(sampleRate_ * 0.25f) + 32;
        foreach (ch; 0 .. 2) {
            if (preDelayLines_[ch].empty() || preDelayLines_[ch].maxDelay() < maxPre) {
                preDelayLines_[ch].tryInit(maxPre);
            }
        }

        drySmoother_.prepare(sampleRate_, 5.0f, dry);
        wetSmoother_.prepare(sampleRate_, 5.0f, wet);
        reset();
    }

    /**
     * Clears FDN and pre-delay buffers, damping filters, and energy estimator.
     */
    void reset() {
        foreach (k; 0 .. NUM_LINES) {
            fdnLines_[k].clear();
            dampFilters_[k].reset();
        }
        foreach (ch; 0 .. 2) {
            preDelayLines_[ch].clear();
        }
        fdnEnergy_ = 0.0f;
        drySmoother_.reset(dry);
        wetSmoother_.reset(wet);
    }

    /**
     * Updates smoothers or damping filter cutoff on parameter updates.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap immediately.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        static if (field == "dry") {
            drySmoother_.setTarget(dry, instant);
        } else static if (field == "wet") {
            wetSmoother_.setTarget(wet, instant);
        } else static if (field == "dampHz") {
            foreach (k; 0 .. NUM_LINES) {
                dampFilters_[k].configure(OnePoleMode.lowpass, dampHz, sampleRate_);
            }
        }
    }

    /**
     * Processes stereo audio through pre-delay and an 8-tap dampened Householder FDN.
     *
     * Params:
     *   audioIn = Input stereo slices.
     *   audioOut = Output stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while output or tank energy remains above silence threshold.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        if (fdnLines_[0].empty() || preDelayLines_[0].empty()
                || (ctx.inputSilent && fdnEnergy_ <= 1e-7f && freeze < 0.5f)) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) drySmoother_.next();
                cast(void) wetSmoother_.next();
            }
            return false;
        }

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable bool frozen = freeze >= 0.5f;
        immutable float room = isFinite(roomSize) ? (roomSize < 0.0f ? 0.0f : (roomSize > 1.0f ? 1.0f : roomSize)) : 0.65f;
        immutable float width = isFinite(stereoWidth)
            ? (stereoWidth < 0.0f ? 0.0f : (stereoWidth > 1.0f ? 1.0f : stereoWidth)) : 1.0f;
        immutable float fbGain = frozen ? 0.998f : (0.48f + 0.49f * room);
        immutable float preMs = isFinite(preDelayMs)
            ? (preDelayMs < 0.0f ? 0.0f : (preDelayMs > 200.0f ? 200.0f : preDelayMs)) : 0.0f;
        size_t preDelaySamp = cast(size_t)(preMs * 0.001f * sr);
        if (preDelaySamp >= preDelayLines_[0].maxDelay()) {
            preDelaySamp = preDelayLines_[0].maxDelay() - 1;
        }

        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        float slicePeak = 0.0f;
        float tankPeak = 0.0f;
        float[NUM_LINES] taps = 0.0f;

        foreach (i; 0 .. ctx.frames) {
            immutable float gDry = drySmoother_.next();
            immutable float gWet = wetSmoother_.next();
            immutable float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            preDelayLines_[0].write(xL);
            preDelayLines_[1].write(xR);
            immutable float injL = frozen ? 0.0f : preDelayLines_[0].readTap(preDelaySamp);
            immutable float injR = frozen ? 0.0f : preDelayLines_[1].readTap(preDelaySamp);

            float sumTaps = 0.0f;
            foreach (k; 0 .. NUM_LINES) {
                immutable float rawTap = fdnLines_[k].readTap(lineLengths_[k] - 1);
                immutable float filtered = frozen ? rawTap : dampFilters_[k].processSample(rawTap);
                taps[k] = filtered;
                sumTaps += filtered;
                immutable float af = fabs(filtered);
                if (af > tankPeak) tankPeak = af;
            }

            immutable float householder = 0.25f * sumTaps;
            foreach (k; 0 .. NUM_LINES) {
                immutable float inj = ((k & 1) == 0 ? injL : injR) * 0.35f;
                immutable float mixed = (taps[k] - householder) * fbGain + inj;
                fdnLines_[k].write(mixed);
            }

            immutable float tankL = (taps[0] + taps[2] + taps[4] + taps[6]) * 0.65f;
            immutable float tankR = (taps[1] + taps[3] + taps[5] + taps[7]) * 0.65f;
            immutable float mid = 0.5f * (tankL + tankR);
            immutable float side = 0.5f * (tankL - tankR) * width;

            immutable float yL = xL * gDry + (mid + side) * gWet;
            immutable float yR = xR * gDry + (mid - side) * gWet;
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > slicePeak) slicePeak = ayL;
            if (ayR > slicePeak) slicePeak = ayR;
        }

        if (tankPeak > fdnEnergy_) {
            fdnEnergy_ = tankPeak;
        } else {
            fdnEnergy_ *= 0.992f;
            if (fdnEnergy_ < 1e-8f) {
                fdnEnergy_ = 0.0f;
            }
        }

        return slicePeak > 1e-7f || fdnEnergy_ > 1e-7f || frozen;
    }
}
