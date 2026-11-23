/**
 * File:         source/modules/output.d
 * Module:       modules.output
 * Phase:        Phase 2.5 — Master Output Sink Module
 *
 * Purpose:
 *   Graph terminal sink collecting master stereo audio, applying optional soft-clipping safety limiter, and publishing master peak/clipping telemetry.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero NaN default init and zero heap allocations on render path.
 *
 * Dependencies:
 *   Internal: dsp.smoother, graph.module_api, graph.port, graph.context
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct MasterOutput (typeId = "core.output", ports: audioStereo in -> audioStereo out)
 *   - @Param volume, limiterEnable
 *   - lastPeakL(), lastPeakR(), clipped()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.output;

import std.math : fabs, isFinite;

import dsp.smoother : ParamSmoother;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Terminal master output module with smoothed gain and soft-clip safety limiter.
 */
struct MasterOutput {
    enum string typeId = "core.output";
    enum string displayName = "Master Output";
    enum ModuleCategory category = ModuleCategory.core;
    enum bool isOutputModule = true;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Volume", 0.0f, 2.0f, 1.0f, "", ParamScale.linear)
    float volume = 1.0f;

    @Param("Limiter", 0.0f, 1.0f, 1.0f, "", ParamScale.discrete)
    float limiterEnable = 1.0f;

    private ParamSmoother volSmoother_;
    private float peakL_ = 0.0f;
    private float peakR_ = 0.0f;
    private bool clipped_ = false;

    @nogc nothrow:

    /**
     * Prepares the output volume smoother for the target sample rate.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal processing slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        volSmoother_.prepare(sampleRate, 5.0f, volume);
        reset();
    }

    /**
     * Resets peak telemetry and snaps the volume smoother to the current parameter value.
     */
    void reset() {
        volSmoother_.reset(volume);
        peakL_ = 0.0f;
        peakR_ = 0.0f;
        clipped_ = false;
    }

    /**
     * Updates smoothed master volume when volume is changed via automation or UI.
     *
     * Params:
     *   sampleRate = Active audio sample rate in Hertz.
     *   instant = When true, snaps immediately without ramping.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "volume") {
            volSmoother_.setTarget(volume, instant);
        }
    }

    /**
     * Scales and optionally soft-limits stereo master audio into audioOut.
     *
     * Params:
     *   audioIn = Input stereo channel slices.
     *   audioOut = Output stereo channel slices.
     *   ctx = Per-slice processing context.
     *
     * Returns:
     *   True if non-silent output was produced; false otherwise.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        peakL_ = 0.0f;
        peakR_ = 0.0f;
        clipped_ = false;

        if (ctx.inputSilent && volSmoother_.isSettled()) {
            foreach (ch; 0 .. 2) {
                audioOut[ch][0 .. ctx.frames] = 0.0f;
            }
            return false;
        }

        immutable bool limitOn = limiterEnable >= 0.5f;
        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        foreach (i; 0 .. ctx.frames) {
            immutable float gain = volSmoother_.next();
            immutable float rawL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float rawR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            float yL = rawL * gain;
            float yR = rawR * gain;
            if (fabs(yL) > 1.0f || fabs(yR) > 1.0f) {
                clipped_ = true;
            }
            if (limitOn) {
                yL = softLimitSample(yL);
                yR = softLimitSample(yR);
            }

            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peakL_) peakL_ = ayL;
            if (ayR > peakR_) peakR_ = ayR;
        }

        return peakL_ > 1e-7f || peakR_ > 1e-7f;
    }

    private static float softLimitSample(float x) pure @safe {
        enum float KNEE = 0.95f;
        enum float HEADROOM = 0.05f;
        immutable float ax = fabs(x);
        if (ax <= KNEE) {
            return x;
        }
        immutable float excess = ax - KNEE;
        immutable float limited = KNEE + HEADROOM * (excess / (HEADROOM + excess));
        return x < 0.0f ? -limited : limited;
    }

    /**
     * Returns the left-channel peak amplitude measured during the most recent process() slice.
     *
     * Returns:
     *   Linear peak amplitude >= 0.0f.
     */
    float lastPeakL() const pure @safe {
        return peakL_;
    }

    /**
     * Returns the right-channel peak amplitude measured during the most recent process() slice.
     *
     * Returns:
     *   Linear peak amplitude >= 0.0f.
     */
    float lastPeakR() const pure @safe {
        return peakR_;
    }

    /**
     * Reports whether pre-limiter samples exceeded full scale (+/-1.0f) on the latest slice.
     *
     * Returns:
     *   True if overload occurred prior to limiting.
     */
    bool clipped() const pure @safe {
        return clipped_;
    }
}
