/**
 * File:         source/modules/effects/modulator.d
 * Module:       modules.effects.modulator
 * Phase:        Phase 4.6 (Tier 2) — Ring, Amplitude & Phase Modulator
 *
 * Purpose:
 *   Combines carrier audio with secondary modulator sidechain audio or CV modulation for amplitude modulation (AM), ring modulation (RM), and audio-rate phase modulation (PM).
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; fractional PM DelayLine pre-allocated in prepare().
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.smoother, graph.buffer, graph.context, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Modulator (typeId = "fx.modulator", ports: audioStereo carrierIn, sidechainStereo modIn, cvControl modCv, audioStereo out)
 *   - @Param modType, mix, maxDelayMs
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.modulator;

import std.math : fabs, isFinite;

import dsp.delay_line : DelayLine;
import dsp.smoother : ParamSmoother;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Dual-input AM, Ring, and fractional-delay Phase Modulator supporting audio and CV modulators.
 */
struct Modulator {
    enum string typeId = "fx.modulator";
    enum string displayName = "Modulator";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[4] ports = [
        PortDescriptor("carrierIn", "Carrier In", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("modIn", "Modulator In", PortKind.sidechainStereo, PortDirection.input),
        PortDescriptor("modCv", "Modulator CV", PortKind.cvControl, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Mod Type", 0.0f, 2.0f, 1.0f, "", ParamScale.discrete)
    float modType = 1.0f;

    @Param("Mix", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float mix = 1.0f;

    @Param("PM Max Delay", 0.2f, 30.0f, 5.0f, "ms", ParamScale.linear)
    float maxDelayMs = 5.0f;

    private DelayLine[2] pmLines_;
    private ParamSmoother mixSmoother_;
    private float sampleRate_ = 44_100.0f;
    private uint tailCountdown_ = 0;

    @nogc nothrow:

    /**
     * Pre-allocates PM fractional delay lines up to 35 ms and prepares mix smoother.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        immutable size_t maxDel = cast(size_t)(sampleRate_ * 0.04f) + 64;
        foreach (ch; 0 .. 2) {
            if (pmLines_[ch].empty() || pmLines_[ch].maxDelay() < maxDel) {
                pmLines_[ch].tryInit(maxDel);
            }
        }
        mixSmoother_.prepare(sampleRate_, 5.0f, mix);
        reset();
    }

    /**
     * Clears PM delay memory and resets tail countdown and mix smoother.
     */
    void reset() {
        foreach (ch; 0 .. 2) {
            pmLines_[ch].clear();
        }
        tailCountdown_ = 0;
        mixSmoother_.reset(mix);
    }

    /**
     * Updates wet/dry mix smoother cleanly on parameter edit.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap immediately.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "mix") {
            mixSmoother_.setTarget(mix, instant);
        }
    }

    /**
     * Applies AM, Ring, or Phase Modulation combining carrierIn with modIn or modCv.
     *
     * Params:
     *   io = Bundle holding carrier audioIn, sidechainIn modulator, modCv, and audioOut.
     *   ctx = Per-slice processing context.
     *
     * Returns:
     *   True while output or PM delay tail exceeds silence threshold.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        immutable bool usePm = (isFinite(modType) ? cast(int)(modType + 0.5f) : 1) == 2;
        if (ctx.inputSilent && (!usePm || tailCountdown_ == 0)) {
            io.audioOut[0][0 .. ctx.frames] = 0.0f;
            io.audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) mixSmoother_.next();
            }
            return false;
        }

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable int kind = isFinite(modType) ? cast(int)(modType + 0.5f) : 1;
        immutable bool hasSc = io.sidechainConnected && !io.sidechainSilent
            && io.sidechainIn[0].length >= ctx.frames && io.sidechainIn[1].length >= ctx.frames;
        immutable bool hasCv = io.numCvIn > 0 && io.cvIn[0].connected && !io.cvIn[0].silent
            && io.cvIn[0].samples.length >= ctx.frames;

        immutable float pmSpan = (isFinite(maxDelayMs) ? (maxDelayMs < 0.2f ? 0.2f : (maxDelayMs > 30.0f ? 30.0f : maxDelayMs)) : 5.0f)
            * 0.001f * sr;

        const carL = io.audioIn[0];
        const carR = io.audioIn[1];
        auto outL = io.audioOut[0];
        auto outR = io.audioOut[1];

        bool sawCarrier = false;
        float peak = 0.0f;

        foreach (i; 0 .. ctx.frames) {
            immutable float m = mixSmoother_.next();
            immutable float cL = ctx.inputSilent ? 0.0f : (isFinite(carL[i]) ? carL[i] : 0.0f);
            immutable float cR = ctx.inputSilent ? 0.0f : (isFinite(carR[i]) ? carR[i] : 0.0f);
            if (fabs(cL) > 1e-7f || fabs(cR) > 1e-7f) {
                sawCarrier = true;
            }

            float modL = 0.0f;
            float modR = 0.0f;
            if (hasSc) {
                modL = isFinite(io.sidechainIn[0][i]) ? io.sidechainIn[0][i] : 0.0f;
                modR = isFinite(io.sidechainIn[1][i]) ? io.sidechainIn[1][i] : 0.0f;
            } else if (hasCv) {
                immutable float cv = isFinite(io.cvIn[0].samples[i]) ? io.cvIn[0].samples[i] : 0.0f;
                modL = cv;
                modR = cv;
            }

            float wetL = cL;
            float wetR = cR;
            if (kind == 0) {
                wetL = cL * (0.5f + 0.5f * modL);
                wetR = cR * (0.5f + 0.5f * modR);
            } else if (kind == 1) {
                wetL = cL * modL;
                wetR = cR * modR;
            } else if (!pmLines_[0].empty() && !pmLines_[1].empty()) {
                pmLines_[0].write(cL);
                pmLines_[1].write(cR);
                float tapL = 1.0f + 0.5f * (modL + 1.0f) * pmSpan;
                float tapR = 1.0f + 0.5f * (modR + 1.0f) * pmSpan;
                if (tapL < 1.0f) tapL = 1.0f;
                if (tapR < 1.0f) tapR = 1.0f;
                wetL = pmLines_[0].readCatmullRom(tapL);
                wetR = pmLines_[1].readCatmullRom(tapR);
            }

            immutable float yL = cL + m * (wetL - cL);
            immutable float yR = cR + m * (wetR - cR);
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;
        }

        if (usePm) {
            if (sawCarrier) {
                tailCountdown_ = cast(uint)(pmSpan + 16.0f);
            } else if (tailCountdown_ > ctx.frames) {
                tailCountdown_ -= ctx.frames;
            } else {
                tailCountdown_ = 0;
            }
        }

        return peak > 1e-7f || (usePm && tailCountdown_ > 0);
    }
}
