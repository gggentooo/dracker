/**
 * File:         source/modules/effects/eq.d
 * Module:       modules.effects.eq
 * Phase:        Phase 4.6 (Tier 2) — 3-Band Equalizer
 *
 * Purpose:
 *   Low-shelf, peaking-mid, and high-shelf 3-band EQ built on double-precision RBJ biquads with silent decay detection.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init biquad states and smooth parameter updates.
 *
 * Dependencies:
 *   Internal: dsp.filter_biquad, graph.context, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Eq3Band (typeId = "fx.eq3", ports: audioStereo in/out)
 *   - @Param lowGainDb, midGainDb, highGainDb, lowFreqHz, midFreqHz, midQ, highFreqHz
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.eq;

import std.math : fabs, isFinite;

import dsp.filter_biquad : BiquadFilter, BiquadMode;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo 3-band equalizer combining RBJ low-shelf, peaking mid, and high-shelf filters.
 */
struct Eq3Band {
    enum string typeId = "fx.eq3";
    enum string displayName = "3-Band EQ";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Low Gain", -24.0f, 24.0f, 0.0f, "dB", ParamScale.linear)
    float lowGainDb = 0.0f;

    @Param("Mid Gain", -24.0f, 24.0f, 0.0f, "dB", ParamScale.linear)
    float midGainDb = 0.0f;

    @Param("High Gain", -24.0f, 24.0f, 0.0f, "dB", ParamScale.linear)
    float highGainDb = 0.0f;

    @Param("Low Freq", 30.0f, 800.0f, 160.0f, "Hz", ParamScale.logarithmic)
    float lowFreqHz = 160.0f;

    @Param("Mid Freq", 200.0f, 8000.0f, 1000.0f, "Hz", ParamScale.logarithmic)
    float midFreqHz = 1000.0f;

    @Param("Mid Q", 0.2f, 10.0f, 1.0f, "Q", ParamScale.logarithmic)
    float midQ = 1.0f;

    @Param("High Freq", 1500.0f, 18_000.0f, 6000.0f, "Hz", ParamScale.logarithmic)
    float highFreqHz = 6000.0f;

    private BiquadFilter[3][2] bands_;
    private float sampleRate_ = 44_100.0f;

    @nogc nothrow:

    /**
     * Configures all 3 EQ biquads for sampleRate and resets delay state.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        updateCoeffs(sampleRate_);
        reset();
    }

    /**
     * Clears all 6 biquad delay registers to zero.
     */
    void reset() {
        foreach (ch; 0 .. 2) {
            foreach (b; 0 .. 3) {
                bands_[ch][b].reset();
            }
        }
    }

    /**
     * Recomputes band filter coefficients immediately when any EQ parameter changes.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = Unused.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) instant;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        updateCoeffs(sampleRate_);
    }

    /**
     * Filters stereo audio through low-shelf, peaking-mid, and high-shelf bands.
     *
     * Params:
     *   audioIn = Input stereo slices.
     *   audioOut = Output stereo slices.
     *   ctx = Per-slice processing context.
     *
     * Returns:
     *   True while output or filter tail remains active; false when fully silent.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        if (ctx.inputSilent && isTailSilent()) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            return false;
        }

        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);
            foreach (b; 0 .. 3) {
                xL = bands_[0][b].processSample(xL);
                xR = bands_[1][b].processSample(xR);
            }
            outL[i] = xL;
            outR[i] = xR;
            immutable float axL = fabs(xL);
            immutable float axR = fabs(xR);
            if (axL > peak) peak = axL;
            if (axR > peak) peak = axR;
        }

        return peak > 1e-7f || !isTailSilent();
    }

    private void updateCoeffs(float sr) pure @safe {
        foreach (ch; 0 .. 2) {
            bands_[ch][0].configure(BiquadMode.lowShelf, lowFreqHz, 0.7071f, lowGainDb, sr);
            bands_[ch][1].configure(BiquadMode.peaking, midFreqHz, midQ, midGainDb, sr);
            bands_[ch][2].configure(BiquadMode.highShelf, highFreqHz, 0.7071f, highGainDb, sr);
        }
    }

    private bool isTailSilent() const pure @safe {
        foreach (ch; 0 .. 2) {
            foreach (b; 0 .. 3) {
                if (!bands_[ch][b].isTailSilent(1e-7)) {
                    return false;
                }
            }
        }
        return true;
    }
}
