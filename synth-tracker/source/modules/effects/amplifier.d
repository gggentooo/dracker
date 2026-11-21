/**
 * File:         source/modules/effects/amplifier.d
 * Module:       modules.effects.amplifier
 * Phase:        Phase 2.5 / 4.1 (Tier 1) — Stereo Amplifier & Utility
 *
 * Purpose:
 *   Provides smoothed gain (with optional audio-rate gainMod CV modulation), stereo panning, DC offset, stereo width, and phase inversion with silent-input bypass.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init smoother state.
 *
 * Dependencies:
 *   Internal: dsp.smoother, graph.buffer, graph.context, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Amplifier (typeId = "fx.amplifier", ports: audioStereo in, cvControl gainMod, audioStereo out)
 *   - @Param volume, pan, dcOffset, stereoWidth, invert
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.amplifier;

import std.math : fabs, isFinite;

import dsp.smoother : ParamSmoother;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo gain, pan, width, DC offset, and polarity utility with CV gain modulation.
 */
struct Amplifier {
    enum string typeId = "fx.amplifier";
    enum string displayName = "Amplifier";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("gainMod", "Gain CV", PortKind.cvControl, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Volume", 0.0f, 4.0f, 1.0f, "", ParamScale.linear)
    float volume = 1.0f;

    @Param("Pan", -1.0f, 1.0f, 0.0f, "", ParamScale.linear)
    float pan = 0.0f;

    @Param("DC Offset", -1.0f, 1.0f, 0.0f, "", ParamScale.linear)
    float dcOffset = 0.0f;

    @Param("Stereo Width", 0.0f, 2.0f, 1.0f, "", ParamScale.linear)
    float stereoWidth = 1.0f;

    @Param("Invert", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete)
    float invert = 0.0f;

    private ParamSmoother volSmoother_;
    private ParamSmoother panSmoother_;

    @nogc nothrow:

    /**
     * Initializes gain and pan smoothers at sampleRate.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal processing slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        volSmoother_.prepare(sampleRate, 5.0f, volume);
        panSmoother_.prepare(sampleRate, 5.0f, pan);
    }

    /**
     * Snaps internal smoothers immediately to current parameter values.
     */
    void reset() {
        volSmoother_.reset(volume);
        panSmoother_.reset(pan);
    }

    /**
     * Updates parameter smoothers when volume or pan changes via automation or UI.
     *
     * Params:
     *   sampleRate = Active audio sample rate in Hertz.
     *   instant = When true, snaps immediately without ramping.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "volume") {
            volSmoother_.setTarget(volume, instant);
        } else static if (field == "pan") {
            panSmoother_.setTarget(pan, instant);
        }
    }

    /**
     * Processes stereo audio through mid/side width, smoothed gain * (1 + gainMod CV), pan, invert, and DC offset.
     *
     * Params:
     *   io = Audio and CV input/output views for the current slice.
     *   ctx = Per-slice processing context.
     *
     * Returns:
     *   True if non-silent audio was written to audioOut; false when silent.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        immutable float cleanDc = isFinite(dcOffset) ? dcOffset : 0.0f;
        if (ctx.inputSilent && fabs(cleanDc) <= 1e-7f) {
            foreach (_; 0 .. ctx.frames) {
                cast(void) volSmoother_.next();
                cast(void) panSmoother_.next();
            }
            foreach (ch; 0 .. 2) {
                io.audioOut[ch][0 .. ctx.frames] = 0.0f;
            }
            return false;
        }

        immutable bool cvActive = io.numCvIn > 0
            && io.cvIn[0].connected
            && !io.cvIn[0].silent
            && io.cvIn[0].samples.length >= ctx.frames;
        const(float)[] cvSlice = cvActive ? io.cvIn[0].samples : null;

        immutable float width = isFinite(stereoWidth) ? stereoWidth : 1.0f;
        immutable float invSign = invert >= 0.5f ? -1.0f : 1.0f;
        const inL = io.audioIn[0];
        const inR = io.audioIn[1];
        auto outL = io.audioOut[0];
        auto outR = io.audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            float gain = volSmoother_.next();
            if (cvActive) {
                immutable float cv = isFinite(cvSlice[i]) ? cvSlice[i] : 0.0f;
                gain *= (1.0f + cv);
                if (gain < 0.0f) {
                    gain = 0.0f;
                }
            }

            immutable float p = panSmoother_.next();
            immutable float panGainL = p > 0.0f ? (1.0f - p) : 1.0f;
            immutable float panGainR = p < 0.0f ? (1.0f + p) : 1.0f;

            immutable float rawL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float rawR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            immutable float mid = 0.5f * (rawL + rawR);
            immutable float side = 0.5f * (rawL - rawR) * width;
            immutable float yL = (mid + side) * gain * panGainL * invSign + cleanDc;
            immutable float yR = (mid - side) * gain * panGainR * invSign + cleanDc;

            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;
        }

        return peak > 1e-7f;
    }
}
