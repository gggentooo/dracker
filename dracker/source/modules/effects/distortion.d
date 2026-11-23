/**
 * File:         source/modules/effects/distortion.d
 * Module:       modules.effects.distortion
 * Phase:        Phase 4.1 (Tier 1) — Distortion, Foldback & Bitcrusher
 *
 * Purpose:
 *   Combines soft/hard clipping, wavefold saturation, bit-depth quantization, and sample-rate decimation.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init sample-and-hold state with silent-input bypass.
 *
 * Dependencies:
 *   Internal: dsp.smoother, graph.context, graph.module_api, graph.port
 *   External: std.math (fabs, floor, isFinite, sin, tanh)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Distortion (typeId = "fx.distortion", ports: audioStereo in/out)
 *   - @Param mode, drive, bitDepth, sampleRateDiv, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.distortion;

import std.math : fabs, floor, isFinite, sin, tanh;

import dsp.smoother : ParamSmoother;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo nonlinear distortion, wavefolder, bit-depth crusher, and sample-rate reducer.
 */
struct Distortion {
    enum string typeId = "fx.distortion";
    enum string displayName = "Distortion";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Mode", 0.0f, 3.0f, 0.0f, "", ParamScale.discrete)
    float mode = 0.0f;

    @Param("Drive", 1.0f, 50.0f, 2.0f, "x", ParamScale.logarithmic)
    float drive = 2.0f;

    @Param("Bit Depth", 1.0f, 24.0f, 24.0f, "bit", ParamScale.linear)
    float bitDepth = 24.0f;

    @Param("SR Div", 1.0f, 64.0f, 1.0f, "x", ParamScale.discrete)
    float sampleRateDiv = 1.0f;

    @Param("Mix", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float mix = 1.0f;

    private ParamSmoother driveSmoother_;
    private ParamSmoother mixSmoother_;
    private float[2] hold_ = 0.0f;
    private uint holdCounter_ = 0;

    @nogc nothrow:

    /**
     * Configures parameter smoothers and resets sample-and-hold state.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        driveSmoother_.prepare(sampleRate, 5.0f, drive);
        mixSmoother_.prepare(sampleRate, 5.0f, mix);
        reset();
    }

    /**
     * Resets held samples and snaps smoothers cleanly.
     */
    void reset() {
        hold_[] = 0.0f;
        holdCounter_ = 0;
        driveSmoother_.reset(drive);
        mixSmoother_.reset(mix);
    }

    /**
     * Updates drive or wet/dry mix smoothers when parameters change.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap without smoothing.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "drive") {
            driveSmoother_.setTarget(drive, instant);
        } else static if (field == "mix") {
            mixSmoother_.setTarget(mix, instant);
        }
    }

    /**
     * Applies waveshaping, bit quantization, and S&H sample-rate reduction across stereo slices.
     *
     * Params:
     *   audioIn = Input stereo channel slices.
     *   audioOut = Output stereo channel slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True if output peak or held sample exceeds silence threshold.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        immutable bool holdSilent = fabs(hold_[0]) <= 1e-7f && fabs(hold_[1]) <= 1e-7f;
        if (ctx.inputSilent && holdSilent) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) driveSmoother_.next();
                cast(void) mixSmoother_.next();
            }
            return false;
        }

        immutable int m = isFinite(mode) ? cast(int)(mode + 0.5f) : 0;
        immutable uint srDiv = effectiveSrDiv();
        immutable double bits = isFinite(bitDepth)
            ? (bitDepth < 1.0f ? 1.0 : (bitDepth > 24.0f ? 24.0 : cast(double) bitDepth)) : 24.0;
        immutable bool quantize = bits < 23.5;
        immutable double stepScale = quantize ? cast(double)(1uL << cast(uint)(bits - 0.5)) : 1.0;

        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            immutable float drv = driveSmoother_.next();
            immutable float wetMix = mixSmoother_.next();
            immutable float dryL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float dryR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            if (holdCounter_ == 0 || srDiv <= 1) {
                hold_[0] = shapeSample(dryL * drv, m, quantize, stepScale);
                hold_[1] = shapeSample(dryR * drv, m, quantize, stepScale);
            }
            holdCounter_++;
            if (holdCounter_ >= srDiv) {
                holdCounter_ = 0;
            }

            immutable float yL = dryL + wetMix * (hold_[0] - dryL);
            immutable float yR = dryR + wetMix * (hold_[1] - dryR);
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;
        }

        return peak > 1e-7f || fabs(hold_[0]) > 1e-7f || fabs(hold_[1]) > 1e-7f;
    }

    private uint effectiveSrDiv() const pure @safe {
        if (!isFinite(sampleRateDiv)) {
            return 1;
        }
        immutable int r = cast(int)(sampleRateDiv + 0.5f);
        if (r < 1) return 1;
        if (r > 64) return 64;
        return cast(uint) r;
    }

    private static float shapeSample(float x, int modeIdx, bool quantize, double stepScale) pure @safe {
        if (!isFinite(x)) {
            return 0.0f;
        }
        float y = 0.0f;
        switch (modeIdx) {
            case 1:
                y = x > 1.0f ? 1.0f : (x < -1.0f ? -1.0f : x);
                break;
            case 2:
                y = cast(float) sin(cast(double) x);
                break;
            case 3:
                y = x >= 0.0f
                    ? cast(float) tanh(cast(double) x)
                    : cast(float)(0.85 * tanh(cast(double)(x * 0.6f)));
                break;
            default:
                y = cast(float) tanh(cast(double) x);
                break;
        }
        if (quantize && stepScale > 0.0) {
            y = cast(float)(floor(cast(double) y * stepScale + 0.5) / stepScale);
        }
        return isFinite(y) ? y : 0.0f;
    }
}
