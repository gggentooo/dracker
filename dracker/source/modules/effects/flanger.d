/**
 * File:         source/modules/effects/flanger.d
 * Module:       modules.effects.flanger
 * Phase:        Phase 4.6 (Tier 2) — Modulated Delay Flanger
 *
 * Purpose:
 *   Stereo swept-comb flanger driven by quadrature sine LFO and Catmull-Rom fractional delay lines with bounded bipolar feedback.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); pre-allocated DelayLines and decay-tail silence tracking.
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.smoother, dsp.tables, graph.context, graph.module_api, graph.port
 *   External: std.math (fabs, floor, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Flanger (typeId = "fx.flanger", ports: audioStereo in/out)
 *   - @Param dry, wet, feedback, delayMs, lfoFreqHz, lfoDepth
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.flanger;

import std.math : fabs, floor, isFinite;

import dsp.delay_line : DelayLine;
import dsp.smoother : ParamSmoother;
import dsp.tables : lookupSine;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo LFO-modulated delay flanger with bipolar comb feedback.
 */
struct Flanger {
    enum string typeId = "fx.flanger";
    enum string displayName = "Flanger";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Dry", 0.0f, 1.0f, 0.7f, "", ParamScale.linear)
    float dry = 0.7f;

    @Param("Wet", 0.0f, 1.0f, 0.7f, "", ParamScale.linear)
    float wet = 0.7f;

    @Param("Feedback", -0.95f, 0.95f, 0.4f, "", ParamScale.linear)
    float feedback = 0.4f;

    @Param("Delay", 0.2f, 20.0f, 3.0f, "ms", ParamScale.linear)
    float delayMs = 3.0f;

    @Param("LFO Freq", 0.05f, 10.0f, 0.4f, "Hz", ParamScale.logarithmic)
    float lfoFreqHz = 0.4f;

    @Param("LFO Depth", 0.0f, 1.0f, 0.6f, "", ParamScale.linear)
    float lfoDepth = 0.6f;

    private DelayLine[2] lines_;
    private ParamSmoother drySmoother_;
    private ParamSmoother wetSmoother_;
    private double lfoPhase_ = 0.0;
    private float sampleRate_ = 44_100.0f;
    private float tailEnergy_ = 0.0f;

    @nogc nothrow:

    /**
     * Pre-allocates fractional delay lines up to 50 ms and primes smoothers.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        immutable size_t maxDel = cast(size_t)(sampleRate_ * 0.06f) + 64;
        foreach (ch; 0 .. 2) {
            if (lines_[ch].empty() || lines_[ch].maxDelay() < maxDel) {
                lines_[ch].tryInit(maxDel);
            }
        }
        drySmoother_.prepare(sampleRate_, 5.0f, dry);
        wetSmoother_.prepare(sampleRate_, 5.0f, wet);
        reset();
    }

    /**
     * Clears flanger delay buffers, resets LFO phase, and zeroes tail energy.
     */
    void reset() {
        foreach (ch; 0 .. 2) {
            lines_[ch].clear();
        }
        lfoPhase_ = 0.0;
        tailEnergy_ = 0.0f;
        drySmoother_.reset(dry);
        wetSmoother_.reset(wet);
    }

    /**
     * Updates dry or wet gain smoothers cleanly.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap without ramping.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "dry") {
            drySmoother_.setTarget(dry, instant);
        } else static if (field == "wet") {
            wetSmoother_.setTarget(wet, instant);
        }
    }

    /**
     * Modulates stereo audio through swept Catmull-Rom delay lines.
     *
     * Params:
     *   audioIn = Input stereo slices.
     *   audioOut = Output stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while output or delay comb energy remains above threshold.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        if (lines_[0].empty() || lines_[1].empty() || (ctx.inputSilent && tailEnergy_ <= 1e-7f)) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) drySmoother_.next();
                cast(void) wetSmoother_.next();
            }
            return false;
        }

        immutable double sr = cast(double)(ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_);
        immutable double baseMs = isFinite(delayMs) ? (delayMs < 0.2f ? 0.2 : (delayMs > 20.0f ? 20.0 : cast(double) delayMs)) : 3.0;
        immutable double baseSamples = baseMs * 0.001 * sr;
        immutable double modSpan = baseSamples * 0.85 * (isFinite(lfoDepth)
            ? (lfoDepth < 0.0f ? 0.0 : (lfoDepth > 1.0f ? 1.0 : cast(double) lfoDepth)) : 0.6);
        immutable float fb = isFinite(feedback)
            ? (feedback < -0.95f ? -0.95f : (feedback > 0.95f ? 0.95f : feedback)) : 0.4f;
        immutable double rateHz = isFinite(lfoFreqHz) ? (lfoFreqHz < 0.01f ? 0.01 : cast(double) lfoFreqHz) : 0.4;
        immutable double phaseInc = rateHz / sr;

        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        float slicePeak = 0.0f;
        float delayedPeak = 0.0f;

        foreach (i; 0 .. ctx.frames) {
            immutable float gDry = drySmoother_.next();
            immutable float gWet = wetSmoother_.next();
            immutable float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            immutable double lfoL = 0.5 * (1.0 + cast(double) lookupSine(cast(float) lfoPhase_));
            immutable double lfoR = 0.5 * (1.0 + cast(double) lookupSine(cast(float)(lfoPhase_ + 0.25)));
            float tapL = cast(float)(baseSamples * 0.2 + modSpan * lfoL);
            float tapR = cast(float)(baseSamples * 0.2 + modSpan * lfoR);
            if (tapL < 1.0f) tapL = 1.0f;
            if (tapR < 1.0f) tapR = 1.0f;

            immutable float dL = lines_[0].readCatmullRom(tapL);
            immutable float dR = lines_[1].readCatmullRom(tapR);
            immutable float adL = fabs(dL);
            immutable float adR = fabs(dR);
            if (adL > delayedPeak) delayedPeak = adL;
            if (adR > delayedPeak) delayedPeak = adR;

            lines_[0].write(xL + dL * fb);
            lines_[1].write(xR + dR * fb);

            immutable float yL = xL * gDry + dL * gWet;
            immutable float yR = xR * gDry + dR * gWet;
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > slicePeak) slicePeak = ayL;
            if (ayR > slicePeak) slicePeak = ayR;

            lfoPhase_ += phaseInc;
            if (lfoPhase_ >= 1.0) {
                lfoPhase_ -= floor(lfoPhase_);
            }
        }

        immutable float peakMax = slicePeak > delayedPeak ? slicePeak : delayedPeak;
        if (peakMax > tailEnergy_) {
            tailEnergy_ = peakMax;
        } else {
            tailEnergy_ *= 0.992f;
            if (tailEnergy_ < 1e-8f) {
                tailEnergy_ = 0.0f;
            }
        }

        return slicePeak > 1e-7f || tailEnergy_ > 1e-7f;
    }
}
