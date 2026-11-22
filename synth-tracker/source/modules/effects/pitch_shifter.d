/**
 * File:         source/modules/effects/pitch_shifter.d
 * Module:       modules.effects.pitch_shifter
 * Phase:        Phase 4.7 (Tier 2) — Granular / Overlap-Add Pitch Shifter
 *
 * Purpose:
 *   Dual-head overlap-add delay pitch shifter windowed with half-sine envelopes, fine cents detuning, bounded feedback, and clean silence-tail detection.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); pre-allocated DelayLine buffers sized in prepare().
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.smoother, dsp.tables, graph.context, graph.module_api, graph.port
 *   External: std.math (exp2, fabs, floor, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct PitchShifter (typeId = "fx.pitch_shifter", ports: audioStereo in/out)
 *   - @Param pitchSemitones, fineCents, grainMs, feedback, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.pitch_shifter;

import std.math : exp2, fabs, floor, isFinite;

import dsp.delay_line : DelayLine;
import dsp.smoother : ParamSmoother;
import dsp.tables : lookupHalfSine;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo dual-windowed time-domain pitch shifter with bounded feedback.
 */
struct PitchShifter {
    enum string typeId = "fx.pitch_shifter";
    enum string displayName = "Pitch Shifter";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Pitch", -24.0f, 24.0f, 0.0f, "st", ParamScale.linear)
    float pitchSemitones = 0.0f;

    @Param("Fine Cents", -100.0f, 100.0f, 0.0f, "ct", ParamScale.linear)
    float fineCents = 0.0f;

    @Param("Grain Size", 10.0f, 120.0f, 45.0f, "ms", ParamScale.linear)
    float grainMs = 45.0f;

    @Param("Feedback", 0.0f, 0.85f, 0.0f, "", ParamScale.linear)
    float feedback = 0.0f;

    @Param("Mix", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float mix = 1.0f;

    private DelayLine[2] lines_;
    private ParamSmoother mixSmoother_;
    private double windowPhase_ = 0.0;
    private float sampleRate_ = 44_100.0f;
    private float tailEnergy_ = 0.0f;

    @nogc nothrow:

    /**
     * Pre-allocates stereo granular delay buffers up to 250 ms and primes mix smoother.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        immutable size_t maxDel = cast(size_t)(sampleRate_ * 0.25f) + 64;
        foreach (ch; 0 .. 2) {
            if (lines_[ch].empty() || lines_[ch].maxDelay() < maxDel) {
                lines_[ch].tryInit(maxDel);
            }
        }
        mixSmoother_.prepare(sampleRate_, 5.0f, mix);
        reset();
    }

    /**
     * Clears delay lines, resets overlap window phase, and clears tail energy.
     */
    void reset() {
        foreach (ch; 0 .. 2) {
            lines_[ch].clear();
        }
        windowPhase_ = 0.0;
        tailEnergy_ = 0.0f;
        mixSmoother_.reset(mix);
    }

    /**
     * Updates wet/dry mix smoother cleanly.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap without ramping.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "mix") {
            mixSmoother_.setTarget(mix, instant);
        }
    }

    /**
     * Processes stereo audio through dual quadrature-windowed granular pitch heads.
     *
     * Params:
     *   audioIn = Input stereo slices.
     *   audioOut = Output stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while output or circulating pitch delay energy exceeds threshold.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        if (lines_[0].empty() || lines_[1].empty() || (ctx.inputSilent && tailEnergy_ <= 1e-7f)) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) mixSmoother_.next();
            }
            return false;
        }

        immutable double sr = cast(double)(ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_);
        immutable double totalSemis = (isFinite(pitchSemitones) ? cast(double) pitchSemitones : 0.0)
            + (isFinite(fineCents) ? cast(double) fineCents * 0.01 : 0.0);
        immutable double ratio = exp2(totalSemis / 12.0);
        immutable double gMs = isFinite(grainMs) ? (grainMs < 10.0f ? 10.0 : (grainMs > 120.0f ? 120.0 : cast(double) grainMs)) : 45.0;
        immutable double grainSamp = gMs * 0.001 * sr;
        immutable double phaseInc = (1.0 - ratio) / (grainSamp > 16.0 ? grainSamp : 16.0);
        immutable float fb = isFinite(feedback) ? (feedback < 0.0f ? 0.0f : (feedback > 0.85f ? 0.85f : feedback)) : 0.0f;

        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        float slicePeak = 0.0f;
        float wetPeak = 0.0f;

        foreach (i; 0 .. ctx.frames) {
            immutable float m = mixSmoother_.next();
            immutable float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            immutable double phA = windowPhase_;
            double phB = windowPhase_ + 0.5;
            if (phB >= 1.0) phB -= 1.0;

            immutable float tapA = cast(float)(1.0 + phA * grainSamp);
            immutable float tapB = cast(float)(1.0 + phB * grainSamp);
            immutable float wA = lookupHalfSine(cast(float) phA);
            immutable float wB = lookupHalfSine(cast(float) phB);
            immutable float winSq = wA * wA + wB * wB;
            immutable float norm = winSq > 1e-4f ? 1.0f : 1.0f;
            cast(void) norm;

            immutable float wetL = lines_[0].readLinear(tapA) * wA + lines_[0].readLinear(tapB) * wB;
            immutable float wetR = lines_[1].readLinear(tapA) * wA + lines_[1].readLinear(tapB) * wB;

            lines_[0].write(xL + wetL * fb);
            lines_[1].write(xR + wetR * fb);

            immutable float awL = fabs(wetL);
            immutable float awR = fabs(wetR);
            if (awL > wetPeak) wetPeak = awL;
            if (awR > wetPeak) wetPeak = awR;

            immutable float yL = xL + m * (wetL - xL);
            immutable float yR = xR + m * (wetR - xR);
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > slicePeak) slicePeak = ayL;
            if (ayR > slicePeak) slicePeak = ayR;

            windowPhase_ += phaseInc;
            if (windowPhase_ >= 1.0 || windowPhase_ < 0.0) {
                windowPhase_ -= floor(windowPhase_);
            }
        }

        immutable float instantMag = slicePeak > wetPeak ? slicePeak : wetPeak;
        if (instantMag > tailEnergy_) {
            tailEnergy_ = instantMag;
        } else {
            tailEnergy_ *= 0.992f;
            if (tailEnergy_ < 1e-8f) {
                tailEnergy_ = 0.0f;
            }
        }

        return slicePeak > 1e-7f || tailEnergy_ > 1e-7f;
    }
}
