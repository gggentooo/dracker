/**
 * File:         source/modules/effects/waveshaper.d
 * Module:       modules.effects.waveshaper
 * Phase:        Phase 4.6 (Tier 2) — Editable Transfer-Curve WaveShaper
 *
 * Purpose:
 *   Applies an editable bipolar 257-point transfer curve with 1x/2x/4x oversampling and optional post-shaping DC blocking, supporting lock-free SwapModuleAsset updates.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process()/swapAsset(); curve assets allocated off-RT and freed on retire or module destruction.
 *
 * Dependencies:
 *   Internal: dsp.filter_biquad, dsp.interp, dsp.smoother, graph.context, graph.module_api, graph.port
 *   External: core.lifetime, core.stdc.stdlib, core.stdc.string, std.math (fabs, isFinite, tanh)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct WaveShaperCurveAsset
 *   - struct WaveShaper (typeId = "fx.waveshaper", ports: audioStereo in/out)
 *   - @Param inputGain, mix, dcBlock, oversampleMode
 *   - Hooks: swapAsset, serializeExtra, deserializeExtra
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.waveshaper;

import core.lifetime : emplace;
import core.stdc.stdlib : calloc, free;
import core.stdc.string : memcpy;
import std.math : fabs, isFinite, tanh;

import dsp.filter_biquad : OnePoleFilter, OnePoleMode;
import dsp.interp : interpLinear;
import dsp.smoother : ParamSmoother;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Unmanaged @nogc 257-entry bipolar waveshaper transfer curve covering [-1.0, +1.0].
 */
struct WaveShaperCurveAsset {
    float[257] table = 0.0f;

    @nogc nothrow:

    /**
     * Allocates a WaveShaperCurveAsset populated from curve (or smooth tanh default if empty).
     *
     * Params:
     *   curve = Optional custom curve sampled across [-1, +1].
     *
     * Returns:
     *   Unmanaged WaveShaperCurveAsset*, or null on OOM.
     */
    static WaveShaperCurveAsset* createOffRT(const(float)[] curve = null) {
        auto ptr = cast(WaveShaperCurveAsset*) calloc(1, WaveShaperCurveAsset.sizeof);
        if (ptr is null) {
            return null;
        }
        emplace(ptr);
        if (curve.length >= 2) {
            foreach (i; 0 .. 257) {
                immutable double pos = (cast(double) i / 256.0) * cast(double)(curve.length - 1);
                size_t idx = cast(size_t) pos;
                if (idx >= curve.length - 1) idx = curve.length - 2;
                immutable float frac = cast(float)(pos - cast(double) idx);
                immutable float a = isFinite(curve[idx]) ? curve[idx] : 0.0f;
                immutable float b = isFinite(curve[idx + 1]) ? curve[idx + 1] : 0.0f;
                ptr.table[i] = interpLinear(a, b, frac);
            }
        } else {
            foreach (i; 0 .. 257) {
                immutable double x = (cast(double) i / 128.0) - 1.0;
                ptr.table[i] = cast(float) tanh(x * 2.0);
            }
        }
        return ptr;
    }

    /**
     * Type-erased destructor freeing WaveShaperCurveAsset memory off-RT.
     *
     * Params:
     *   raw = Opaque WaveShaperCurveAsset* pointer.
     */
    static void destroyErased(void* raw) {
        if (raw !is null) {
            free(raw);
        }
    }
}

/**
 * Stereo waveshaper with swappable lookup curve, 1x/2x/4x oversampling, and DC blocking.
 */
struct WaveShaper {
    enum string typeId = "fx.waveshaper";
    enum string displayName = "WaveShaper";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Input Gain", 0.0f, 10.0f, 1.0f, "x", ParamScale.logarithmic)
    float inputGain = 1.0f;

    @Param("Mix", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float mix = 1.0f;

    @Param("DC Block", 0.0f, 1.0f, 1.0f, "", ParamScale.discrete)
    float dcBlock = 1.0f;

    @Param("Oversample", 0.0f, 2.0f, 0.0f, "", ParamScale.discrete)
    float oversampleMode = 0.0f;

    private WaveShaperCurveAsset* curveAsset_ = null;
    private OnePoleFilter[2] dcFilters_;
    private OnePoleFilter[2] aaFilters_;
    private ParamSmoother gainSmoother_;
    private ParamSmoother mixSmoother_;
    private float[2] prevIn_ = 0.0f;
    private float sampleRate_ = 44_100.0f;

    /**
     * Serializes the attached transfer curve off-RT.
     *
     * Params:
     *   payload = Byte array holding 257 float entries (empty if using default).
     *
     * Returns:
     *   True on success.
     */
    bool serializeExtra(out ubyte[] payload) const {
        if (curveAsset_ is null) {
            payload = null;
            return true;
        }
        payload = new ubyte[WaveShaperCurveAsset.sizeof];
        memcpy(payload.ptr, curveAsset_, WaveShaperCurveAsset.sizeof);
        return true;
    }

    /**
     * Deserializes a saved transfer curve blob off the real-time thread.
     *
     * Params:
     *   payload = Saved WaveShaperCurveAsset bytes.
     *   sampleRate = Active sample rate in Hertz.
     *
     * Returns:
     *   True if valid or empty; false on corrupt length or OOM.
     */
    bool deserializeExtra(const(ubyte)[] payload, float sampleRate) {
        cast(void) sampleRate;
        if (payload.length == 0) {
            return true;
        }
        if (payload.length != WaveShaperCurveAsset.sizeof) {
            return false;
        }
        auto next = WaveShaperCurveAsset.createOffRT();
        if (next is null) {
            return false;
        }
        memcpy(next, payload.ptr, WaveShaperCurveAsset.sizeof);
        void* prev = null;
        swapAsset(0, next, prev);
        if (prev !is null) {
            WaveShaperCurveAsset.destroyErased(prev);
        }
        return true;
    }

    @nogc nothrow:

    /**
     * Frees any attached WaveShaperCurveAsset pointer on teardown.
     */
    ~this() {
        if (curveAsset_ !is null) {
            WaveShaperCurveAsset.destroyErased(curveAsset_);
            curveAsset_ = null;
        }
    }

    /**
     * Initializes DC-blocker, anti-alias filters, and smoothers for sampleRate.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        foreach (ch; 0 .. 2) {
            dcFilters_[ch].configure(OnePoleMode.highpass, 15.0f, sampleRate_);
            aaFilters_[ch].configure(OnePoleMode.lowpass, sampleRate_ * 0.42f, sampleRate_ * 2.0f);
        }
        gainSmoother_.prepare(sampleRate_, 5.0f, inputGain);
        mixSmoother_.prepare(sampleRate_, 5.0f, mix);
        reset();
    }

    /**
     * Resets filter registers, oversampling history, and smoothers.
     */
    void reset() {
        foreach (ch; 0 .. 2) {
            dcFilters_[ch].reset();
            aaFilters_[ch].reset();
        }
        prevIn_[] = 0.0f;
        gainSmoother_.reset(inputGain);
        mixSmoother_.reset(mix);
    }

    /**
     * Updates inputGain and wet/dry mix smoothers cleanly.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap without ramping.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "inputGain") {
            gainSmoother_.setTarget(inputGain, instant);
        } else static if (field == "mix") {
            mixSmoother_.setTarget(mix, instant);
        }
    }

    /**
     * Processes stereo audio through optional upsampling, lookup curve shaping, and DC blocking.
     *
     * Params:
     *   audioIn = Input stereo slices.
     *   audioOut = Output stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while output or DC filter tail exceeds silence threshold.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        immutable bool dcOn = dcBlock >= 0.5f;
        if (ctx.inputSilent && dcFilters_[0].isTailSilent() && dcFilters_[1].isTailSilent()
                && fabs(prevIn_[0]) <= 1e-7f && fabs(prevIn_[1]) <= 1e-7f) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) gainSmoother_.next();
                cast(void) mixSmoother_.next();
            }
            return false;
        }

        immutable int osIdx = isFinite(oversampleMode) ? cast(int)(oversampleMode + 0.5f) : 0;
        immutable uint osFactor = osIdx >= 2 ? 4 : (osIdx == 1 ? 2 : 1);
        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            immutable float gain = gainSmoother_.next();
            immutable float wetMix = mixSmoother_.next();
            immutable float dryL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float dryR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            float wetL = 0.0f;
            float wetR = 0.0f;
            if (osFactor == 1) {
                wetL = evalCurve(dryL * gain);
                wetR = evalCurve(dryR * gain);
            } else {
                immutable float invOs = 1.0f / cast(float) osFactor;
                float accumL = 0.0f;
                float accumR = 0.0f;
                foreach (sub; 1 .. osFactor + 1) {
                    immutable float frac = cast(float) sub * invOs;
                    immutable float upL = interpLinear(prevIn_[0], dryL, frac) * gain;
                    immutable float upR = interpLinear(prevIn_[1], dryR, frac) * gain;
                    accumL = aaFilters_[0].processSample(evalCurve(upL));
                    accumR = aaFilters_[1].processSample(evalCurve(upR));
                }
                wetL = accumL;
                wetR = accumR;
            }
            prevIn_[0] = dryL;
            prevIn_[1] = dryR;

            if (dcOn) {
                wetL = dcFilters_[0].processSample(wetL);
                wetR = dcFilters_[1].processSample(wetR);
            }

            immutable float yL = dryL + wetMix * (wetL - dryL);
            immutable float yR = dryR + wetMix * (wetR - dryR);
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;
        }

        return peak > 1e-7f || !dcFilters_[0].isTailSilent() || !dcFilters_[1].isTailSilent();
    }

    /**
     * Atomically swaps a WaveShaperCurveAsset pointer on slot 0.
     *
     * Params:
     *   slot = Asset slot index (must be 0).
     *   newAsset = Replacement WaveShaperCurveAsset* pointer.
     *   oldAsset = Receives previous asset pointer for off-RT reclamation.
     *
     * Returns:
     *   True when slot == 0.
     */
    bool swapAsset(uint slot, void* newAsset, out void* oldAsset) {
        oldAsset = null;
        if (slot != 0) {
            return false;
        }
        oldAsset = curveAsset_;
        curveAsset_ = cast(WaveShaperCurveAsset*) newAsset;
        return true;
    }

    private float evalCurve(float x) const pure @safe {
        if (!isFinite(x)) {
            return 0.0f;
        }
        if (curveAsset_ is null) {
            return cast(float) tanh(cast(double) x * 2.0);
        }
        float clamped = x;
        if (clamped < -1.0f) clamped = -1.0f;
        if (clamped > 1.0f) clamped = 1.0f;
        immutable float pos = (clamped + 1.0f) * 128.0f;
        size_t idx = cast(size_t) pos;
        if (idx > 255) idx = 255;
        immutable float frac = pos - cast(float) idx;
        return interpLinear(curveAsset_.table[idx], curveAsset_.table[idx + 1], frac);
    }
}
