/**
 * File:         source/modules/effects/dc_blocker.d
 * Module:       modules.effects.dc_blocker
 * Phase:        Phase 2.5 / 4.1 (Tier 1) — 1-Pole DC Blocking High-Pass Filter
 *
 * Purpose:
 *   Removes DC bias with a configurable logarithmic cutoff frequency and decay-tail silence detection for downstream graph skipping.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init on double prevIn/prevOut; named onParamChanged!field dispatch.
 *
 * Dependencies:
 *   Internal: dsp.tables, graph.module_api, graph.port, graph.context
 *   External: std.math (exp, fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DcBlocker (typeId = "fx.dc_blocker", ports: audioStereo in/out)
 *   - @Param cutoffHz (5..80 Hz, logarithmic)
 *   - Hooks: prepare, reset, onParamChanged!"cutoffHz", process
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.dc_blocker;

import std.math : exp, fabs, isFinite;

import dsp.tables : TWO_PI_D;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo 1-pole DC blocking high-pass filter with decay-tail silence tracking.
 */
struct DcBlocker {
    enum string typeId = "fx.dc_blocker";
    enum string displayName = "DC Blocker";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Cutoff", 5.0f, 80.0f, 20.0f, "Hz", ParamScale.logarithmic)
    float cutoffHz = 20.0f;

    private double[2] prevIn = 0.0;
    private double[2] prevOut = 0.0;
    private double coeff = 0.997154;

    @nogc nothrow:

    /**
     * Computes filter pole coefficient for sampleRate and clears delay registers.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal processing slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        updateCoeff(sampleRate);
        reset();
    }

    /**
     * Clears stored input and output delay registers to zero.
     */
    void reset() {
        prevIn[] = 0.0;
        prevOut[] = 0.0;
    }

    /**
     * Recomputes the high-pass filter pole when cutoffHz changes.
     *
     * Params:
     *   sampleRate = Active audio sample rate in Hertz.
     *   instant = Instant flag (pole coefficient updates immediately without zipper).
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) instant;
        static if (field == "cutoffHz") {
            updateCoeff(sampleRate);
        }
    }

    /**
     * Filters DC bias from stereo audio and reports whether output or filter tail remains active.
     *
     * Params:
     *   audioIn = Input stereo channel slices.
     *   audioOut = Output stereo channel slices.
     *   ctx = Per-slice processing context.
     *
     * Returns:
     *   True while output peak or stored filter decay tail exceeds silence threshold.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        if (ctx.inputSilent && isTailSilent()) {
            foreach (ch; 0 .. 2) {
                audioOut[ch][0 .. ctx.frames] = 0.0f;
            }
            return false;
        }

        immutable double r = coeff;
        float peak = 0.0f;
        foreach (ch; 0 .. 2) {
            double x1 = prevIn[ch];
            double y1 = prevOut[ch];
            const inp = audioIn[ch];
            auto outp = audioOut[ch];
            foreach (i; 0 .. ctx.frames) {
                immutable double x = ctx.inputSilent ? 0.0 : (isFinite(inp[i]) ? cast(double) inp[i] : 0.0);
                immutable double y = x - x1 + r * y1;
                x1 = x;
                y1 = y;
                immutable float outVal = cast(float) y;
                outp[i] = outVal;
                immutable float ay = fabs(outVal);
                if (ay > peak) peak = ay;
            }
            prevIn[ch] = x1;
            prevOut[ch] = y1;
        }
        return peak > 1e-7f || !isTailSilent();
    }

    private bool isTailSilent() const pure @safe {
        enum double EPS = 1e-7;
        foreach (ch; 0 .. 2) {
            if (fabs(prevIn[ch]) > EPS || fabs(prevOut[ch]) > EPS) {
                return false;
            }
        }
        return true;
    }

    private void updateCoeff(float sampleRate) pure @safe {
        immutable double sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44100.0 : cast(double) sampleRate;
        double fc = isFinite(cutoffHz) ? cast(double) cutoffHz : 20.0;
        if (fc < 1.0) {
            fc = 1.0;
        } else if (fc > 0.45 * sr) {
            fc = 0.45 * sr;
        }
        coeff = exp(-TWO_PI_D * fc / sr);
    }
}
