/**
 * File:         source/modules/effects/delay.d
 * Module:       modules.effects.delay
 * Phase:        Phase 4.1 (Tier 1) — Tempo-Synced Stereo Delay
 *
 * Purpose:
 *   Stereo delay supporting millisecond, Hz, and BPM/line-synced delay times with dry/wet mix and channel swap.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); pre-allocated DelayLine buffers sized safely in prepare().
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.smoother, graph.context, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Delay (typeId = "fx.delay", ports: audioStereo in/out)
 *   - @Param dry, wet, delayL, delayR, unitMode, inversePan
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.delay;

import std.math : fabs, isFinite;

import dsp.delay_line : DelayLine;
import dsp.smoother : ParamSmoother;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Clean stereo delay supporting milliseconds, Hertz frequency period, and tempo-line sync.
 */
struct Delay {
    enum string typeId = "fx.delay";
    enum string displayName = "Delay";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Dry", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float dry = 1.0f;

    @Param("Wet", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float wet = 0.5f;

    @Param("Delay L", 0.1f, 2000.0f, 250.0f, "", ParamScale.linear)
    float delayL = 250.0f;

    @Param("Delay R", 0.1f, 2000.0f, 375.0f, "", ParamScale.linear)
    float delayR = 375.0f;

    @Param("Unit", 0.0f, 2.0f, 0.0f, "", ParamScale.discrete)
    float unitMode = 0.0f;

    @Param("Inverse", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete)
    float inversePan = 0.0f;

    private DelayLine[2] lines_;
    private ParamSmoother drySmoother_;
    private ParamSmoother wetSmoother_;
    private ParamSmoother tapLSmoother_;
    private ParamSmoother tapRSmoother_;
    private float sampleRate_ = 44_100.0f;
    private uint tailCountdown_ = 0;

    @nogc nothrow:

    /**
     * Pre-allocates stereo DelayLine ring buffers up to 4 seconds and primes smoothers.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        immutable size_t needed = cast(size_t)(sampleRate_ * 4.0f) + 64;
        foreach (ch; 0 .. 2) {
            if (lines_[ch].empty() || lines_[ch].maxDelay() < needed) {
                lines_[ch].tryInit(needed);
            }
        }
        drySmoother_.prepare(sampleRate_, 5.0f, dry);
        wetSmoother_.prepare(sampleRate_, 5.0f, wet);
        tapLSmoother_.prepare(sampleRate_, 12.0f, 0.25f * sampleRate_);
        tapRSmoother_.prepare(sampleRate_, 12.0f, 0.375f * sampleRate_);
        reset();
    }

    /**
     * Clears delay lines and resets tail countdown and parameter smoothers.
     */
    void reset() {
        foreach (ch; 0 .. 2) {
            lines_[ch].clear();
        }
        tailCountdown_ = 0;
        drySmoother_.reset(dry);
        wetSmoother_.reset(wet);
        tapLSmoother_.reset(computeDelaySamples(delayL, sampleRate_, 125.0));
        tapRSmoother_.reset(computeDelaySamples(delayR, sampleRate_, 125.0));
    }

    /**
     * Responds to parameter updates on dry, wet, delayL, or delayR.
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
        } else static if (field == "delayL") {
            tapLSmoother_.setTarget(computeDelaySamples(delayL, sampleRate_, 125.0), instant);
        } else static if (field == "delayR") {
            tapRSmoother_.setTarget(computeDelaySamples(delayR, sampleRate_, 125.0), instant);
        }
    }

    /**
     * Renders stereo delayed audio with silent-tail bypass once delay buffers flush cleanly.
     *
     * Params:
     *   audioIn = Input stereo slices.
     *   audioOut = Output stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while delayed signal or input exceeds silence threshold.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        if (lines_[0].empty() || lines_[1].empty() || (ctx.inputSilent && tailCountdown_ == 0)) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) drySmoother_.next();
                cast(void) wetSmoother_.next();
                cast(void) tapLSmoother_.next();
                cast(void) tapRSmoother_.next();
            }
            return false;
        }

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable double bpm = ctx.transport.bpm > 1.0 ? ctx.transport.bpm : 125.0;
        tapLSmoother_.setTarget(computeDelaySamples(delayL, sr, bpm), false);
        tapRSmoother_.setTarget(computeDelaySamples(delayR, sr, bpm), false);

        immutable bool swapOut = inversePan >= 0.5f;
        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        bool sawEnergy = false;
        float peak = 0.0f;
        float maxTap = 0.0f;

        foreach (i; 0 .. ctx.frames) {
            immutable float gDry = drySmoother_.next();
            immutable float gWet = wetSmoother_.next();
            immutable float tL = tapLSmoother_.next();
            immutable float tR = tapRSmoother_.next();
            if (tL > maxTap) maxTap = tL;
            if (tR > maxTap) maxTap = tR;

            immutable float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);
            if (fabs(xL) > 1e-7f || fabs(xR) > 1e-7f) {
                sawEnergy = true;
            }

            lines_[0].write(xL);
            lines_[1].write(xR);

            immutable float dL = lines_[0].readLinear(tL);
            immutable float dR = lines_[1].readLinear(tR);
            immutable float wL = swapOut ? dR : dL;
            immutable float wR = swapOut ? dL : dR;

            immutable float yL = xL * gDry + wL * gWet;
            immutable float yR = xR * gDry + wR * gWet;
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;
        }

        if (sawEnergy) {
            tailCountdown_ = cast(uint)(maxTap + 16.0f);
        } else if (tailCountdown_ > ctx.frames) {
            tailCountdown_ -= ctx.frames;
        } else {
            tailCountdown_ = 0;
        }

        return peak > 1e-7f || tailCountdown_ > 0;
    }

    private float computeDelaySamples(float rawVal, float sr, double bpm) const pure @safe {
        immutable float v = isFinite(rawVal) ? rawVal : 250.0f;
        immutable int u = isFinite(unitMode) ? cast(int)(unitMode + 0.5f) : 0;
        double samples = 0.0;
        if (u == 1) {
            immutable double hz = v < 0.25f ? 0.25 : cast(double) v;
            samples = cast(double) sr / hz;
        } else if (u == 2) {
            immutable double linesPerSec = bpm * 4.0 / 60.0;
            immutable double sec = (v * 0.01) / (linesPerSec > 0.01 ? linesPerSec : 1.0);
            samples = sec * cast(double) sr;
        } else {
            samples = cast(double) v * 0.001 * cast(double) sr;
        }
        immutable double maxCap = lines_[0].empty() ? cast(double) sr * 2.0 : cast(double) lines_[0].maxDelay();
        if (samples < 1.0) samples = 1.0;
        if (samples > maxCap) samples = maxCap;
        return cast(float) samples;
    }
}
