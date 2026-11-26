/**
 * File:         source/modules/control/adsr_mod.d
 * Module:       modules.control.adsr_mod
 * Phase:        Phase 4.2 (Tier 1) — Triggerable ADSR Control & Audio Envelope
 *
 * Purpose:
 *   Responds to NoteOn, NoteOff, and AllNotesOff ModEvents and outputs audio-rate CV modulation alongside stereo envelope audio.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero allocations and automatic idle detection when envelope finishes.
 *
 * Dependencies:
 *   Internal: dsp.envelope, graph.buffer, graph.context, graph.event, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct AdsrMod (typeId = "ctl.adsr", ports: event in, cvControl out, audioStereo out)
 *   - @Param attackMs, decayMs, sustain, releaseMs, stateMode
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.adsr_mod;

import std.math : fabs, isFinite;

import dsp.envelope : AdsrEnvelope;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Triggerable ADSR envelope generator outputting both audio-rate CV and stereo envelope level.
 */
struct AdsrMod {
    enum string typeId = "ctl.adsr";
    enum string displayName = "ADSR";
    enum ModuleCategory category = ModuleCategory.control;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("cvOut", "CV Out", PortKind.cvControl, PortDirection.output),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Attack", 0.5f, 5000.0f, 10.0f, "ms", ParamScale.logarithmic)
    float attackMs = 10.0f;

    @Param("Decay", 0.5f, 5000.0f, 150.0f, "ms", ParamScale.logarithmic)
    float decayMs = 150.0f;

    @Param("Sustain", 0.0f, 1.0f, 0.7f, "", ParamScale.linear)
    float sustain = 0.7f;

    @Param("Release", 1.0f, 10_000.0f, 250.0f, "ms", ParamScale.logarithmic)
    float releaseMs = 250.0f;

    @Param("Mode", 0.0f, 2.0f, 0.0f, "", ParamScale.discrete,
        ["Gated", "One-Shot", "Inverted"])
    float stateMode = 0.0f;

    private AdsrEnvelope env_;
    private float sampleRate_ = 44_100.0f;
    private float noteVel_ = 1.0f;

    @nogc nothrow:

    /**
     * Prepares the ADSR envelope generator for sampleRate.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        syncEnvParams();
        reset();
    }

    /**
     * Resets the envelope to idle immediately.
     */
    void reset() {
        env_.reset();
        noteVel_ = 1.0f;
    }

    /**
     * Updates envelope segment timings on parameter changes.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = Unused (times update cleanly immediately).
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) instant;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        syncEnvParams();
    }

    /**
     * Triggers or releases the envelope on incoming note events.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        syncEnvParams();
        immutable int modeIdx = isFinite(stateMode) ? cast(int)(stateMode + 0.5f) : 0;

        if (ev.kind == ModEventKind.noteOn) {
            noteVel_ = isFinite(ev.valueB) ? (ev.valueB < 0.0f ? 0.0f : (ev.valueB > 1.0f ? 1.0f : ev.valueB)) : 1.0f;
            env_.trigger(false);
            if (modeIdx == 1) {
                env_.releaseNote();
            }
        } else if (ev.kind == ModEventKind.noteOff || ev.kind == ModEventKind.allNotesOff) {
            if (modeIdx != 1) {
                env_.releaseNote();
            }
        }
    }

    /**
     * Generates audio-rate envelope values onto cvOut[0] and audioOut stereo channels.
     *
     * Params:
     *   io = Output audio and CV slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while the envelope remains active or output non-silent.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        immutable bool hasCvOut = io.numCvOut > 0 && io.cvOut[0].samples.length >= ctx.frames;
        if (!env_.isActive()) {
            io.audioOut[0][0 .. ctx.frames] = 0.0f;
            io.audioOut[1][0 .. ctx.frames] = 0.0f;
            if (hasCvOut) {
                io.cvOut[0].samples[0 .. ctx.frames] = 0.0f;
            }
            return false;
        }

        immutable int modeIdx = isFinite(stateMode) ? cast(int)(stateMode + 0.5f) : 0;
        immutable bool invert = modeIdx == 2;
        auto outL = io.audioOut[0];
        auto outR = io.audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            float v = env_.next() * noteVel_;
            if (invert) {
                v = 1.0f - v;
            }
            outL[i] = v;
            outR[i] = v;
            if (hasCvOut) {
                io.cvOut[0].samples[i] = v;
            }
            immutable float av = fabs(v);
            if (av > peak) peak = av;
        }

        return peak > 1e-7f || env_.isActive();
    }

    private void syncEnvParams() pure @safe {
        env_.prepare(sampleRate_);
        immutable float a = (isFinite(attackMs) && attackMs > 0.0f) ? attackMs * 0.001f : 0.001f;
        immutable float d = (isFinite(decayMs) && decayMs > 0.0f) ? decayMs * 0.001f : 0.001f;
        immutable float r = (isFinite(releaseMs) && releaseMs > 0.0f) ? releaseMs * 0.001f : 0.001f;
        immutable float s = isFinite(sustain) ? sustain : 0.7f;
        env_.setParams(a, d, s, r);
    }
}
