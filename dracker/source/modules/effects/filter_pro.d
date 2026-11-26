/**
 * File:         source/modules/effects/filter_pro.d
 * Module:       modules.effects.filter_pro
 * Phase:        Phase 4.1 (Tier 1) — Multi-Stage Cascaded Filter Pro
 *
 * Purpose:
 *   High-precision cascaded RBJ biquad filter with CV cutoff/resonance modulation, drive saturation, and double-precision internal filter state.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero NaN state and decay-tail silence detection.
 *
 * Dependencies:
 *   Internal: dsp.filter_biquad, dsp.smoother, graph.buffer, graph.context, graph.module_api, graph.port
 *   External: std.math (exp2, fabs, isFinite, tanh)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct FilterPro (typeId = "fx.filter_pro", ports: audioStereo in/out, cvControl cutoffCv, cvControl resoCv)
 *   - @Param mode, slope, cutoffHz, resonance, gainDb, drive
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.filter_pro;

import std.math : exp2, fabs, isFinite, tanh;

import dsp.filter_biquad : BiquadMode, CascadedBiquad;
import dsp.smoother : ParamSmoother;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Multi-topology cascaded RBJ biquad filter (12–48 dB/oct) with CV cutoff/Q modulation and drive.
 */
struct FilterPro {
    enum string typeId = "fx.filter_pro";
    enum string displayName = "Filter Pro";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[4] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("cutoffCv", "Cutoff CV", PortKind.cvControl, PortDirection.input),
        PortDescriptor("resoCv", "Resonance CV", PortKind.cvControl, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Mode", 0.0f, 7.0f, 0.0f, "", ParamScale.discrete,
        ["Lowpass", "Highpass", "Bandpass", "Notch", "Allpass", "Peaking", "Low Shelf", "High Shelf"])
    float mode = 0.0f;

    @Param("Slope", 1.0f, 4.0f, 2.0f, "st", ParamScale.discrete)
    float slope = 2.0f;

    @Param("Cutoff", 20.0f, 20_000.0f, 1200.0f, "Hz", ParamScale.logarithmic)
    float cutoffHz = 1200.0f;

    @Param("Resonance", 0.05f, 20.0f, 0.7071f, "Q", ParamScale.logarithmic)
    float resonance = 0.7071f;

    @Param("Gain", -24.0f, 24.0f, 0.0f, "dB", ParamScale.linear)
    float gainDb = 0.0f;

    @Param("Drive", 0.0f, 1.0f, 0.0f, "", ParamScale.linear)
    float drive = 0.0f;

    private CascadedBiquad!4[2] stages_;
    private ParamSmoother cutoffSmoother_;
    private ParamSmoother resoSmoother_;
    private ParamSmoother gainSmoother_;
    private float sampleRate_ = 44_100.0f;

    @nogc nothrow:

    /**
     * Prepares cascaded filter stages and parameter smoothers for sampleRate.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        cutoffSmoother_.prepare(sampleRate_, 5.0f, cutoffHz);
        resoSmoother_.prepare(sampleRate_, 5.0f, resonance);
        gainSmoother_.prepare(sampleRate_, 5.0f, gainDb);
        reset();
        reconfigureStages(cutoffHz, resonance, gainDb, sampleRate_);
    }

    /**
     * Clears filter memory and snaps smoothers to current parameters.
     */
    void reset() {
        foreach (ch; 0 .. 2) {
            stages_[ch].reset();
        }
        cutoffSmoother_.reset(cutoffHz);
        resoSmoother_.reset(resonance);
        gainSmoother_.reset(gainDb);
    }

    /**
     * Responds to named parameter updates with instant snapping support.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap without ramping.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        static if (field == "cutoffHz") {
            cutoffSmoother_.setTarget(cutoffHz, instant);
        } else static if (field == "resonance") {
            resoSmoother_.setTarget(resonance, instant);
        } else static if (field == "gainDb") {
            gainSmoother_.setTarget(gainDb, instant);
        }
        if (instant) {
            reconfigureStages(cutoffSmoother_.current(), resoSmoother_.current(),
                gainSmoother_.current(), sampleRate_);
        }
    }

    /**
     * Filters stereo audio across active cascade stages with optional CV modulation and saturation.
     *
     * Params:
     *   io = Audio input/output slices and cutoff/resonance CV views.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while output peak or filter tail exceeds silence threshold.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        immutable size_t activeStages = activeStageCount();
        if (ctx.inputSilent && isTailSilent(activeStages)) {
            io.audioOut[0][0 .. ctx.frames] = 0.0f;
            io.audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) cutoffSmoother_.next();
                cast(void) resoSmoother_.next();
                cast(void) gainSmoother_.next();
            }
            return false;
        }

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable bool hasCutCv = io.numCvIn > 0 && io.cvIn[0].connected && !io.cvIn[0].silent
            && io.cvIn[0].samples.length >= ctx.frames;
        immutable bool hasResCv = io.numCvIn > 1 && io.cvIn[1].connected && !io.cvIn[1].silent
            && io.cvIn[1].samples.length >= ctx.frames;
        immutable float drv = isFinite(drive) ? (drive < 0.0f ? 0.0f : (drive > 1.0f ? 1.0f : drive)) : 0.0f;
        immutable float driveGain = 1.0f + 5.0f * drv;

        const inL = io.audioIn[0];
        const inR = io.audioIn[1];
        auto outL = io.audioOut[0];
        auto outR = io.audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            float fc = cutoffSmoother_.next();
            float q = resoSmoother_.next();
            immutable float g = gainSmoother_.next();

            if (hasCutCv) {
                immutable float cv = isFinite(io.cvIn[0].samples[i]) ? io.cvIn[0].samples[i] : 0.0f;
                fc *= cast(float) exp2(cast(double) clampVal(cv, -2.0f, 2.0f) * 4.0);
            }
            if (hasResCv) {
                immutable float cv = isFinite(io.cvIn[1].samples[i]) ? io.cvIn[1].samples[i] : 0.0f;
                q *= 1.0f + clampVal(cv, -0.9f, 4.0f);
            }

            if (hasCutCv || hasResCv || !cutoffSmoother_.isSettled()
                    || !resoSmoother_.isSettled() || !gainSmoother_.isSettled() || i == 0) {
                reconfigureStages(fc, q, g, sr);
            }

            float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);
            if (drv > 1e-4f) {
                xL = cast(float) tanh(cast(double)(xL * driveGain)) / (1.0f + 0.5f * drv);
                xR = cast(float) tanh(cast(double)(xR * driveGain)) / (1.0f + 0.5f * drv);
            }

            float yL = xL;
            float yR = xR;
            foreach (st; 0 .. activeStages) {
                yL = stages_[0].stages[st].processSample(yL);
                yR = stages_[1].stages[st].processSample(yR);
            }
            if (!isFinite(yL)) yL = 0.0f;
            if (!isFinite(yR)) yR = 0.0f;

            outL[i] = yL;
            outR[i] = yR;
            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;
        }

        return peak > 1e-7f || !isTailSilent(activeStages);
    }

    private size_t activeStageCount() const pure @safe {
        if (!isFinite(slope)) {
            return 2;
        }
        immutable int rounded = cast(int)(slope + 0.5f);
        if (rounded < 1) return 1;
        if (rounded > 4) return 4;
        return cast(size_t) rounded;
    }

    private BiquadMode selectedMode() const pure @safe {
        if (!isFinite(mode)) {
            return BiquadMode.lowpass;
        }
        int idx = cast(int)(mode + 0.5f);
        if (idx < 0) idx = 0;
        if (idx > 7) idx = 7;
        return cast(BiquadMode) idx;
    }

    private void reconfigureStages(float fc, float q, float gDb, float sr) pure @safe {
        immutable BiquadMode m = selectedMode();
        immutable size_t cnt = activeStageCount();
        immutable float perStageGain = gDb / cast(float) cnt;
        stages_[0].configureAll(m, fc, q, perStageGain, sr);
        stages_[1].configureAll(m, fc, q, perStageGain, sr);
    }

    private bool isTailSilent(size_t activeStages) const pure @safe {
        foreach (ch; 0 .. 2) {
            foreach (st; 0 .. activeStages) {
                if (!stages_[ch].stages[st].isTailSilent(1e-7)) {
                    return false;
                }
            }
        }
        return true;
    }

    private static float clampVal(float x, float lo, float hi) pure @safe {
        if (!isFinite(x) || x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }
}
