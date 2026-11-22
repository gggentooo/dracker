/**
 * File:         source/modules/effects/vibrato.d
 * Module:       modules.effects.vibrato
 * Phase:        Phase 4.6 (Tier 2) — Pitch Vibrato Modulator
 *
 * Purpose:
 *   Continuous Doppler pitch-modulation effect built on Catmull-Rom fractional delay lines with configurable stereo LFO phase offset.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); pre-allocated delay lines and tail countdown silence skip.
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.smoother, dsp.tables, graph.context, graph.module_api, graph.port
 *   External: std.math (fabs, floor, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Vibrato (typeId = "fx.vibrato", ports: audioStereo in/out)
 *   - @Param freqHz, depth, stereoPhase, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.vibrato;

import std.math : fabs, floor, isFinite;

import dsp.delay_line : DelayLine;
import dsp.smoother : ParamSmoother;
import dsp.tables : lookupSine;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo pitch vibrato processor using Catmull-Rom modulated delay taps.
 */
struct Vibrato {
    enum string typeId = "fx.vibrato";
    enum string displayName = "Vibrato";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Freq", 0.1f, 20.0f, 5.0f, "Hz", ParamScale.logarithmic)
    float freqHz = 5.0f;

    @Param("Depth", 0.0f, 1.0f, 0.35f, "", ParamScale.linear)
    float depth = 0.35f;

    @Param("Stereo Phase", 0.0f, 0.5f, 0.25f, "", ParamScale.linear)
    float stereoPhase = 0.25f;

    @Param("Mix", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float mix = 1.0f;

    private DelayLine[2] lines_;
    private ParamSmoother depthSmoother_;
    private ParamSmoother mixSmoother_;
    private double phase_ = 0.0;
    private float sampleRate_ = 44_100.0f;
    private uint tailCountdown_ = 0;

    @nogc nothrow:

    /**
     * Pre-allocates fractional delay buffers and initializes depth and mix smoothers.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        immutable size_t maxDel = cast(size_t)(sampleRate_ * 0.05f) + 64;
        foreach (ch; 0 .. 2) {
            if (lines_[ch].empty() || lines_[ch].maxDelay() < maxDel) {
                lines_[ch].tryInit(maxDel);
            }
        }
        depthSmoother_.prepare(sampleRate_, 5.0f, depth);
        mixSmoother_.prepare(sampleRate_, 5.0f, mix);
        reset();
    }

    /**
     * Clears delay lines, resets LFO phase, and zeroes tail countdown.
     */
    void reset() {
        foreach (ch; 0 .. 2) {
            lines_[ch].clear();
        }
        phase_ = 0.0;
        tailCountdown_ = 0;
        depthSmoother_.reset(depth);
        mixSmoother_.reset(mix);
    }

    /**
     * Updates depth or wet/dry mix smoothers cleanly.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap immediately.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "depth") {
            depthSmoother_.setTarget(depth, instant);
        } else static if (field == "mix") {
            mixSmoother_.setTarget(mix, instant);
        }
    }

    /**
     * Modulates pitch across stereo channels and tracks tail decay cleanly.
     *
     * Params:
     *   audioIn = Input stereo slices.
     *   audioOut = Output stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while output or delay buffer tail remains non-silent.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        if (lines_[0].empty() || lines_[1].empty() || (ctx.inputSilent && tailCountdown_ == 0)) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) depthSmoother_.next();
                cast(void) mixSmoother_.next();
            }
            return false;
        }

        immutable double sr = cast(double)(ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_);
        immutable double hz = isFinite(freqHz) ? (freqHz < 0.05f ? 0.05 : cast(double) freqHz) : 5.0;
        immutable double phaseInc = hz / sr;
        immutable double centerSamp = 0.008 * sr;
        immutable double sweepSamp = 0.006 * sr;
        immutable float sp = isFinite(stereoPhase) ? stereoPhase : 0.25f;

        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        bool sawInput = false;
        float peak = 0.0f;

        foreach (i; 0 .. ctx.frames) {
            immutable float d = depthSmoother_.next();
            immutable float m = mixSmoother_.next();
            immutable float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);
            if (fabs(xL) > 1e-7f || fabs(xR) > 1e-7f) {
                sawInput = true;
            }

            lines_[0].write(xL);
            lines_[1].write(xR);

            float tapL = cast(float)(centerSamp + sweepSamp * d * lookupSine(cast(float) phase_));
            float tapR = cast(float)(centerSamp + sweepSamp * d * lookupSine(cast(float) phase_ + sp));
            if (tapL < 1.0f) tapL = 1.0f;
            if (tapR < 1.0f) tapR = 1.0f;

            immutable float wL = lines_[0].readCatmullRom(tapL);
            immutable float wR = lines_[1].readCatmullRom(tapR);
            immutable float yL = xL + m * (wL - xL);
            immutable float yR = xR + m * (wR - xR);
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;

            phase_ += phaseInc;
            if (phase_ >= 1.0) {
                phase_ -= floor(phase_);
            }
        }

        if (sawInput) {
            tailCountdown_ = cast(uint)(centerSamp + sweepSamp + 16.0);
        } else if (tailCountdown_ > ctx.frames) {
            tailCountdown_ -= ctx.frames;
        } else {
            tailCountdown_ = 0;
        }

        return peak > 1e-7f || tailCountdown_ > 0;
    }
}
