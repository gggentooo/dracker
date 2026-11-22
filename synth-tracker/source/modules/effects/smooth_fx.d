/**
 * File:         source/modules/effects/smooth_fx.d
 * Module:       modules.effects.smooth_fx
 * Phase:        Phase 4.6 (Tier 2) — Audio-Rate Slew Limiter
 *
 * Purpose:
 *   Asymmetric rise/fall exponential slew limiter smoothing both stereo audio channels and audio-rate CV modulation without zipper artifacts.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init slew registers with decay-tail silence detection.
 *
 * Dependencies:
 *   Internal: graph.buffer, graph.context, graph.module_api, graph.port
 *   External: std.math (exp, fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct SmoothFx (typeId = "fx.smooth", ports: audioStereo in/out, cvControl cvIn/cvOut)
 *   - @Param riseRate, fallRate, scale
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.smooth_fx;

import std.math : exp, fabs, isFinite;

import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo audio and CV asymmetric rise/fall slew-rate limiter.
 */
struct SmoothFx {
    enum string typeId = "fx.smooth";
    enum string displayName = "Smooth";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[4] ports = [
        PortDescriptor("in", "Audio In", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("cvIn", "CV In", PortKind.cvControl, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output),
        PortDescriptor("cvOut", "CV Out", PortKind.cvControl, PortDirection.output)
    ];

    @Param("Rise Time", 0.1f, 500.0f, 10.0f, "ms", ParamScale.logarithmic)
    float riseRate = 10.0f;

    @Param("Fall Time", 0.1f, 500.0f, 40.0f, "ms", ParamScale.logarithmic)
    float fallRate = 40.0f;

    @Param("Scale", 0.0f, 2.0f, 1.0f, "", ParamScale.linear)
    float scale = 1.0f;

    private double[2] stateAudio_ = 0.0;
    private double stateCv_ = 0.0;
    private double riseCoeff_ = 0.01;
    private double fallCoeff_ = 0.005;
    private float sampleRate_ = 44_100.0f;

    @nogc nothrow:

    /**
     * Computes rise and fall coefficients for sampleRate and resets slew accumulators.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        updateCoeffs(sampleRate_);
        reset();
    }

    /**
     * Resets stereo and CV slew state variables to zero immediately.
     */
    void reset() {
        stateAudio_[] = 0.0;
        stateCv_ = 0.0;
    }

    /**
     * Recomputes rise/fall smoothing coefficients when slew rates change.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = Unused.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) instant;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        static if (field == "riseRate" || field == "fallRate") {
            updateCoeffs(sampleRate_);
        }
    }

    /**
     * Applies asymmetric rise/fall smoothing across stereo audio and optional CV channels.
     *
     * Params:
     *   io = Bundle containing audioIn, cvIn, audioOut, and cvOut views.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while audio or CV slew state remains above silence threshold.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        immutable bool hasCvIn = io.numCvIn > 0 && io.cvIn[0].connected && !io.cvIn[0].silent
            && io.cvIn[0].samples.length >= ctx.frames;
        immutable bool hasCvOut = io.numCvOut > 0 && io.cvOut[0].samples.length >= ctx.frames;

        if (ctx.inputSilent && !hasCvIn && isTailSilent()) {
            io.audioOut[0][0 .. ctx.frames] = 0.0f;
            io.audioOut[1][0 .. ctx.frames] = 0.0f;
            if (hasCvOut) {
                io.cvOut[0].samples[0 .. ctx.frames] = 0.0f;
            }
            return false;
        }

        immutable double gScale = isFinite(scale) ? cast(double) scale : 1.0;
        const inL = io.audioIn[0];
        const inR = io.audioIn[1];
        auto outL = io.audioOut[0];
        auto outR = io.audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            immutable double targetL = ctx.inputSilent ? 0.0
                : (isFinite(inL[i]) ? cast(double) inL[i] * gScale : 0.0);
            immutable double targetR = ctx.inputSilent ? 0.0
                : (isFinite(inR[i]) ? cast(double) inR[i] * gScale : 0.0);

            stateAudio_[0] = stepSlew(stateAudio_[0], targetL);
            stateAudio_[1] = stepSlew(stateAudio_[1], targetR);

            immutable float yL = cast(float) stateAudio_[0];
            immutable float yR = cast(float) stateAudio_[1];
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;

            if (hasCvOut) {
                immutable double cvTarget = hasCvIn && isFinite(io.cvIn[0].samples[i])
                    ? cast(double) io.cvIn[0].samples[i] * gScale : 0.0;
                stateCv_ = stepSlew(stateCv_, cvTarget);
                immutable float cvOutVal = cast(float) stateCv_;
                io.cvOut[0].samples[i] = cvOutVal;
                immutable float acv = fabs(cvOutVal);
                if (acv > peak) peak = acv;
            }
        }

        return peak > 1e-7f || !isTailSilent();
    }

    private double stepSlew(double current, double target) const pure @safe {
        immutable double c = fabs(target) > fabs(current) ? riseCoeff_ : fallCoeff_;
        return current + c * (target - current);
    }

    private void updateCoeffs(float sr) pure @safe {
        immutable double rate = (!isFinite(sr) || sr < 1.0f) ? 44_100.0 : cast(double) sr;
        immutable double rMs = (!isFinite(riseRate) || riseRate < 0.05f) ? 0.05 : cast(double) riseRate;
        immutable double fMs = (!isFinite(fallRate) || fallRate < 0.05f) ? 0.05 : cast(double) fallRate;
        riseCoeff_ = 1.0 - exp(-1.0 / (rMs * 0.001 * rate));
        fallCoeff_ = 1.0 - exp(-1.0 / (fMs * 0.001 * rate));
    }

    private bool isTailSilent() const pure @safe {
        return fabs(stateAudio_[0]) <= 1e-7 && fabs(stateAudio_[1]) <= 1e-7 && fabs(stateCv_) <= 1e-7;
    }
}
