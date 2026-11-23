/**
 * File:         source/modules/control/sound2ctl.d
 * Module:       modules.control.sound2ctl
 * Phase:        Phase 4.8 (Tier 2) — Audio Envelope Follower to CV / Controller
 *
 * Purpose:
 *   Tracks incoming stereo audio amplitude envelope cleanly with configurable smoothing and outputs smooth 64-sample CV signals plus rate-limited setParam ModEvents.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; double-precision envelope follower with decay-tail silence detection.
 *
 * Dependencies:
 *   Internal: graph.buffer, graph.context, graph.event, graph.module_api, graph.port
 *   External: std.math (exp, fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Sound2Ctl (typeId = "ctl.sound2ctl", ports: audioStereo in, cvControl out, event out)
 *   - @Param gain, smoothMs, outMin, outMax, sampleRateHz
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.sound2ctl;

import std.math : exp, fabs, isFinite;

import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.event : ModEvent;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Envelope follower translating audio amplitude into audio-rate CV and control-rate events.
 */
struct Sound2Ctl {
    enum string typeId = "ctl.sound2ctl";
    enum string displayName = "Sound2Ctl";
    enum ModuleCategory category = ModuleCategory.control;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Audio In", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("cvOut", "CV Out", PortKind.cvControl, PortDirection.output),
        PortDescriptor("out", "Events Out", PortKind.event, PortDirection.output)
    ];

    @Param("Gain", 0.0f, 8.0f, 1.0f, "x", ParamScale.linear)
    float gain = 1.0f;

    @Param("Smooth", 0.5f, 500.0f, 20.0f, "ms", ParamScale.logarithmic)
    float smoothMs = 20.0f;

    @Param("Out Min", 0.0f, 1.0f, 0.0f, "", ParamScale.linear)
    float outMin = 0.0f;

    @Param("Out Max", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float outMax = 1.0f;

    @Param("Rate", 10.0f, 1000.0f, 100.0f, "Hz", ParamScale.logarithmic)
    float sampleRateHz = 100.0f;

    private double env_ = 0.0;
    private double smoothCoeff_ = 0.01;
    private double emitAccum_ = 0.0;
    private float sampleRate_ = 44_100.0f;

    @nogc nothrow:

    /**
     * Computes smoothing coefficient for sampleRate and resets follower accumulator.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        updateCoeff(sampleRate_);
        reset();
    }

    /**
     * Zeroes internal follower envelope and control-rate divider accumulator.
     */
    void reset() {
        env_ = 0.0;
        emitAccum_ = 0.0;
    }

    /**
     * Updates exponential envelope time constant when smoothMs changes.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = Unused.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) instant;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        static if (field == "smoothMs") {
            updateCoeff(sampleRate_);
        }
    }

    /**
     * Tracks input amplitude into smooth CV output and rate-limited setParam events.
     *
     * Params:
     *   io = Bundle containing audioIn stereo slices and cvOut[0] destination.
     *   ctx = Per-slice execution context holding EventSink.
     *
     * Returns:
     *   True while envelope or mapped CV output remains non-silent.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        immutable bool hasCvOut = io.numCvOut > 0 && io.cvOut[0].samples.length >= ctx.frames;
        immutable float lo = isFinite(outMin) ? outMin : 0.0f;
        immutable float hi = isFinite(outMax) ? outMax : 1.0f;

        if (ctx.inputSilent && env_ <= 1e-7) {
            if (hasCvOut) {
                io.cvOut[0].samples[0 .. ctx.frames] = lo;
            }
            return fabs(lo) > 1e-7f;
        }

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable double g = isFinite(gain) ? cast(double) gain : 1.0;
        immutable double emitRate = (isFinite(sampleRateHz) && sampleRateHz >= 1.0f) ? cast(double) sampleRateHz : 100.0;
        immutable double emitIntervalSamples = cast(double)(sr > 1.0f ? sr : 44_100.0f) / emitRate;

        const inL = io.audioIn[0];
        const inR = io.audioIn[1];
        float peakOut = 0.0f;
        bool emitted = false;

        foreach (i; 0 .. ctx.frames) {
            double rect = 0.0;
            if (!ctx.inputSilent) {
                immutable float l = isFinite(inL[i]) ? fabs(inL[i]) : 0.0f;
                immutable float r = isFinite(inR[i]) ? fabs(inR[i]) : 0.0f;
                rect = (l > r ? cast(double) l : cast(double) r) * g;
                if (rect > 1.0) rect = 1.0;
            }
            env_ += smoothCoeff_ * (rect - env_);
            immutable float mapped = lo + cast(float) env_ * (hi - lo);
            if (hasCvOut) {
                io.cvOut[0].samples[i] = mapped;
            }
            immutable float am = fabs(mapped);
            if (am > peakOut) peakOut = am;

            emitAccum_ += 1.0;
            if (emitAccum_ >= emitIntervalSamples) {
                emitAccum_ -= emitIntervalSamples;
                ctx.eventOut.emit(ModEvent.makeSetParam(0, mapped, false, i));
                emitted = true;
            }
        }

        return emitted || peakOut > 1e-7f || env_ > 1e-7;
    }

    private void updateCoeff(float sr) pure @safe {
        immutable double rate = (!isFinite(sr) || sr < 1.0f) ? 44_100.0 : cast(double) sr;
        immutable double ms = (!isFinite(smoothMs) || smoothMs < 0.1f) ? 0.1 : cast(double) smoothMs;
        smoothCoeff_ = 1.0 - exp(-1.0 / (ms * 0.001 * rate));
    }
}
