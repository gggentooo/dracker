/**
 * File:         source/modules/effects/compressor.d
 * Module:       modules.effects.compressor
 * Phase:        Phase 4.1 (Tier 1) — Sidechain Peak/RMS Compressor
 *
 * Purpose:
 *   Dynamic range compressor with selectable peak/RMS detector, soft-knee gain reduction, and dedicated sidechainStereo input port.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; double-precision envelope detector with zero heap allocations.
 *
 * Dependencies:
 *   Internal: dsp.smoother, foundation.math_rt, graph.buffer, graph.context, graph.module_api, graph.port
 *   External: std.math (exp, fabs, isFinite, sqrt)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Compressor (typeId = "fx.compressor", ports: audioStereo in, sidechainStereo scIn, audioStereo out)
 *   - @Param thresholdDb, ratio, attackMs, releaseMs, makeupDb, mode
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.compressor;

import std.math : exp, fabs, isFinite, sqrt;

import dsp.smoother : ParamSmoother;
import foundation.math_rt : dbToLinear, linearToDb;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo peak/RMS dynamics compressor with optional external sidechain detector routing.
 */
struct Compressor {
    enum string typeId = "fx.compressor";
    enum string displayName = "Compressor";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("scIn", "Sidechain", PortKind.sidechainStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Threshold", -60.0f, 0.0f, -18.0f, "dB", ParamScale.linear)
    float thresholdDb = -18.0f;

    @Param("Ratio", 1.0f, 20.0f, 4.0f, ":1", ParamScale.logarithmic)
    float ratio = 4.0f;

    @Param("Attack", 0.1f, 200.0f, 10.0f, "ms", ParamScale.logarithmic)
    float attackMs = 10.0f;

    @Param("Release", 5.0f, 1000.0f, 120.0f, "ms", ParamScale.logarithmic)
    float releaseMs = 120.0f;

    @Param("Makeup", -12.0f, 24.0f, 0.0f, "dB", ParamScale.linear)
    float makeupDb = 0.0f;

    @Param("Mode", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete)
    float mode = 0.0f;

    private ParamSmoother makeupSmoother_;
    private double envLevel_ = 0.0;
    private double rmsSq_ = 0.0;
    private double attackCoeff_ = 0.01;
    private double releaseCoeff_ = 0.001;
    private float sampleRate_ = 44_100.0f;

    @nogc nothrow:

    /**
     * Initializes ballistic detector time constants and makeup gain smoother.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        makeupSmoother_.prepare(sampleRate_, 5.0f, makeupDb);
        updateBallistics(sampleRate_);
        reset();
    }

    /**
     * Clears peak/RMS envelope detector state and snaps makeup smoother cleanly.
     */
    void reset() {
        envLevel_ = 0.0;
        rmsSq_ = 0.0;
        makeupSmoother_.reset(makeupDb);
    }

    /**
     * Updates attack/release coefficients or makeup smoother when parameters change.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap without smoothing.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        static if (field == "makeupDb") {
            makeupSmoother_.setTarget(makeupDb, instant);
        } else static if (field == "attackMs" || field == "releaseMs") {
            updateBallistics(sampleRate_);
        }
    }

    /**
     * Compresses stereo audio using internal input or connected sidechainStereo key signal.
     *
     * Params:
     *   io = Audio and optional sidechain input/output slice bundle.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True if output exceeds silence threshold; false when main input is silent.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        if (ctx.inputSilent && envLevel_ <= 1e-8 && rmsSq_ <= 1e-14) {
            io.audioOut[0][0 .. ctx.frames] = 0.0f;
            io.audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) makeupSmoother_.next();
            }
            return false;
        }

        immutable bool useSidechain = io.sidechainConnected && !io.sidechainSilent
            && io.sidechainIn[0].length >= ctx.frames && io.sidechainIn[1].length >= ctx.frames;
        immutable bool rmsMode = mode >= 0.5f;
        immutable double thresh = isFinite(thresholdDb)
            ? (thresholdDb < -60.0f ? -60.0 : (thresholdDb > 0.0f ? 0.0 : cast(double) thresholdDb)) : -18.0;
        immutable double rat = (isFinite(ratio) && ratio > 1.0f) ? cast(double) ratio : 1.0;
        immutable double invSlope = 1.0 - 1.0 / rat;

        const inL = io.audioIn[0];
        const inR = io.audioIn[1];
        const keyL = useSidechain ? io.sidechainIn[0] : io.audioIn[0];
        const keyR = useSidechain ? io.sidechainIn[1] : io.audioIn[1];
        auto outL = io.audioOut[0];
        auto outR = io.audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            immutable float mGain = dbToLinear(makeupSmoother_.next());
            immutable float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            double kL = 0.0;
            double kR = 0.0;
            if (useSidechain || !ctx.inputSilent) {
                kL = isFinite(keyL[i]) ? cast(double) fabs(keyL[i]) : 0.0;
                kR = isFinite(keyR[i]) ? cast(double) fabs(keyR[i]) : 0.0;
            }

            double det = 0.0;
            if (rmsMode) {
                immutable double instSq = 0.5 * (kL * kL + kR * kR);
                rmsSq_ += attackCoeff_ * (instSq - rmsSq_);
                det = rmsSq_ > 0.0 ? sqrt(rmsSq_) : 0.0;
            } else {
                det = kL > kR ? kL : kR;
            }

            if (det > envLevel_) {
                envLevel_ += attackCoeff_ * (det - envLevel_);
            } else {
                envLevel_ += releaseCoeff_ * (det - envLevel_);
            }

            immutable double levelDb = cast(double) linearToDb(cast(float) envLevel_);
            double gainRedDb = 0.0;
            enum double halfKnee = 3.0;
            immutable double over = levelDb - thresh;
            if (over > halfKnee) {
                gainRedDb = over * invSlope;
            } else if (over > -halfKnee) {
                immutable double kneeSpan = over + halfKnee;
                gainRedDb = invSlope * (kneeSpan * kneeSpan) / (4.0 * halfKnee);
            }

            immutable float compGain = dbToLinear(cast(float)(-gainRedDb)) * mGain;
            immutable float yL = xL * compGain;
            immutable float yR = xR * compGain;
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;
        }

        return peak > 1e-7f || !ctx.inputSilent;
    }

    private void updateBallistics(float sr) pure @safe {
        immutable double rate = (!isFinite(sr) || sr < 1.0f) ? 44_100.0 : cast(double) sr;
        immutable double attMs = (!isFinite(attackMs) || attackMs < 0.1f) ? 0.1 : cast(double) attackMs;
        immutable double relMs = (!isFinite(releaseMs) || releaseMs < 1.0f) ? 1.0 : cast(double) releaseMs;
        attackCoeff_ = 1.0 - exp(-1.0 / (attMs * 0.001 * rate));
        releaseCoeff_ = 1.0 - exp(-1.0 / (relMs * 0.001 * rate));
    }
}
