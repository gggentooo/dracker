/**
 * File:         source/modules/synths/input.d
 * Module:       modules.synths.input
 * Phase:        Phase 4.9 (Tier 2) — Live Hardware Audio Input Module
 *
 * Purpose:
 *   Routes live host/CoreAudio capture channels (direct AUHAL duplex or drift-compensated resampled ring buffer staged by AudioGraph) into the modular audio graph.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; reads pre-staged ctx.hostAudioIn slices with smoothed gain and clean silent-input bypass.
 *
 * Dependencies:
 *   Internal: dsp.smoother, graph.context, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct AudioInput (typeId = "synth.input", ports: audioStereo out)
 *   - @Param inputGain, channelRoute, monitorMute
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.input;

import std.math : fabs, isFinite;

import dsp.smoother : ParamSmoother;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Hardware audio input source module exposing staged host capture channels into AudioGraph.
 */
struct AudioInput {
    enum string typeId = "synth.input";
    enum string displayName = "Input";
    enum ModuleCategory category = ModuleCategory.synth;

    static immutable PortDescriptor[1] ports = [
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Input Gain", 0.0f, 4.0f, 1.0f, "x", ParamScale.linear)
    float inputGain = 1.0f;

    @Param("Channel Route", 0.0f, 3.0f, 0.0f, "", ParamScale.discrete)
    float channelRoute = 0.0f;

    @Param("Mute", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete)
    float monitorMute = 0.0f;

    private ParamSmoother gainSmoother_;

    @nogc nothrow:

    /**
     * Initializes input gain smoother for sampleRate.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        gainSmoother_.prepare(sampleRate, 5.0f, inputGain);
        reset();
    }

    /**
     * Snaps input gain smoother to current inputGain parameter.
     */
    void reset() {
        gainSmoother_.reset(inputGain);
    }

    /**
     * Updates gain smoother smoothly or instantly when inputGain changes.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap without ramping.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "inputGain") {
            gainSmoother_.setTarget(inputGain, instant);
        }
    }

    /**
     * Routes staged host capture slices from ProcessContext.hostAudioIn into audioOut.
     *
     * Params:
     *   audioIn = Unused module input slices.
     *   audioOut = Output stereo slices receiving routed host input.
     *   ctx = Per-slice execution context containing hostAudioIn and hostInputSilent.
     *
     * Returns:
     *   True if unmuted non-silent audio was written to audioOut; false otherwise.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        cast(void) audioIn;
        immutable bool muted = monitorMute >= 0.5f;
        if (muted || ctx.hostInputSilent || ctx.hostAudioIn[0].length < ctx.frames
                || ctx.hostAudioIn[1].length < ctx.frames) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) gainSmoother_.next();
            }
            return false;
        }

        immutable int route = isFinite(channelRoute) ? cast(int)(channelRoute + 0.5f) : 0;
        const hL = ctx.hostAudioIn[0];
        const hR = ctx.hostAudioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            immutable float gain = gainSmoother_.next();
            immutable float xL = isFinite(hL[i]) ? hL[i] : 0.0f;
            immutable float xR = isFinite(hR[i]) ? hR[i] : 0.0f;

            float sL = xL;
            float sR = xR;
            if (route == 1) {
                sL = xL;
                sR = xL;
            } else if (route == 2) {
                sL = xR;
                sR = xR;
            } else if (route >= 3) {
                immutable float m = 0.5f * (xL + xR);
                sL = m;
                sR = m;
            }

            immutable float yL = sL * gain;
            immutable float yR = sR * gain;
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
