/**
 * File:         source/modules/effects/echo.d
 * Module:       modules.effects.echo
 * Phase:        Phase 4.1 (Tier 1) — Cross-Feedback Filtered Echo
 *
 * Purpose:
 *   Stereo and ping-pong echo processor with bounded feedback damping biquad/1-pole filter and decay-tail silence detection.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); feedback clamped strictly < 1.0 with decay countdown.
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.filter_biquad, dsp.smoother, graph.context, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Echo (typeId = "fx.echo", ports: audioStereo in/out)
 *   - @Param dry, wet, feedback, delayTime, stereoMode, dampingHz
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.echo;

import std.math : fabs, isFinite;

import dsp.delay_line : DelayLine;
import dsp.filter_biquad : OnePoleFilter, OnePoleMode;
import dsp.smoother : ParamSmoother;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo / ping-pong delay echo with feedback loop low-pass damping filter.
 */
struct Echo {
    enum string typeId = "fx.echo";
    enum string displayName = "Echo";
    enum ModuleCategory category = ModuleCategory.effect;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Dry", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float dry = 1.0f;

    @Param("Wet", 0.0f, 1.0f, 0.45f, "", ParamScale.linear)
    float wet = 0.45f;

    @Param("Feedback", 0.0f, 0.98f, 0.5f, "", ParamScale.linear)
    float feedback = 0.5f;

    @Param("Delay Time", 1.0f, 2000.0f, 300.0f, "ms", ParamScale.logarithmic)
    float delayTime = 300.0f;

    @Param("Stereo Mode", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete,
        ["Stereo", "Ping-Pong"])
    float stereoMode = 0.0f;

    @Param("Damping", 200.0f, 20_000.0f, 6000.0f, "Hz", ParamScale.logarithmic)
    float dampingHz = 6000.0f;

    private DelayLine[2] lines_;
    private OnePoleFilter[2] dampFilters_;
    private ParamSmoother drySmoother_;
    private ParamSmoother wetSmoother_;
    private ParamSmoother fbSmoother_;
    private ParamSmoother delaySmoother_;
    private float sampleRate_ = 44_100.0f;
    private float tailEnergy_ = 0.0f;

    @nogc nothrow:

    /**
     * Pre-allocates stereo echo DelayLines and initializes loop damping filters and smoothers.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        immutable size_t maxDel = cast(size_t)(sampleRate_ * 2.5f) + 64;
        foreach (ch; 0 .. 2) {
            if (lines_[ch].empty() || lines_[ch].maxDelay() < maxDel) {
                lines_[ch].tryInit(maxDel);
            }
            dampFilters_[ch].configure(OnePoleMode.lowpass, dampingHz, sampleRate_);
        }
        drySmoother_.prepare(sampleRate_, 5.0f, dry);
        wetSmoother_.prepare(sampleRate_, 5.0f, wet);
        fbSmoother_.prepare(sampleRate_, 5.0f, clampedFeedback());
        delaySmoother_.prepare(sampleRate_, 12.0f, delaySamples(delayTime, sampleRate_));
        reset();
    }

    /**
     * Clears delay history, damping filters, and energy tracker.
     */
    void reset() {
        foreach (ch; 0 .. 2) {
            lines_[ch].clear();
            dampFilters_[ch].reset();
        }
        tailEnergy_ = 0.0f;
        drySmoother_.reset(dry);
        wetSmoother_.reset(wet);
        fbSmoother_.reset(clampedFeedback());
        delaySmoother_.reset(delaySamples(delayTime, sampleRate_));
    }

    /**
     * Updates smoothers or damping filter coefficients on parameter changes.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap immediately without smoothing.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        static if (field == "dry") {
            drySmoother_.setTarget(dry, instant);
        } else static if (field == "wet") {
            wetSmoother_.setTarget(wet, instant);
        } else static if (field == "feedback") {
            fbSmoother_.setTarget(clampedFeedback(), instant);
        } else static if (field == "delayTime") {
            delaySmoother_.setTarget(delaySamples(delayTime, sampleRate_), instant);
        } else static if (field == "dampingHz") {
            dampFilters_[0].configure(OnePoleMode.lowpass, dampingHz, sampleRate_);
            dampFilters_[1].configure(OnePoleMode.lowpass, dampingHz, sampleRate_);
        }
    }

    /**
     * Renders stereo or ping-pong filtered echo slices with automatic silent-tail detection.
     *
     * Params:
     *   audioIn = Input stereo slices.
     *   audioOut = Output stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while output or circulating loop energy remains audible.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        if (lines_[0].empty() || lines_[1].empty()
                || (ctx.inputSilent && tailEnergy_ <= 1e-7f && dampFilters_[0].isTailSilent() && dampFilters_[1].isTailSilent())) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) drySmoother_.next();
                cast(void) wetSmoother_.next();
                cast(void) fbSmoother_.next();
                cast(void) delaySmoother_.next();
            }
            return false;
        }

        immutable bool pingPong = stereoMode >= 0.5f;
        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        float slicePeak = 0.0f;
        float delayedPeak = 0.0f;

        foreach (i; 0 .. ctx.frames) {
            immutable float gDry = drySmoother_.next();
            immutable float gWet = wetSmoother_.next();
            immutable float fb = fbSmoother_.next();
            immutable float tap = delaySmoother_.next();

            immutable float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            immutable float dL = dampFilters_[0].processSample(lines_[0].readLinear(tap));
            immutable float dR = dampFilters_[1].processSample(lines_[1].readLinear(tap));

            immutable float adL = fabs(dL);
            immutable float adR = fabs(dR);
            if (adL > delayedPeak) delayedPeak = adL;
            if (adR > delayedPeak) delayedPeak = adR;

            if (pingPong) {
                lines_[0].write(xL + dR * fb);
                lines_[1].write(xR + dL * fb);
            } else {
                lines_[0].write(xL + dL * fb);
                lines_[1].write(xR + dR * fb);
            }

            immutable float yL = xL * gDry + dL * gWet;
            immutable float yR = xR * gDry + dR * gWet;
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > slicePeak) slicePeak = ayL;
            if (ayR > slicePeak) slicePeak = ayR;
        }

        immutable float instantMag = slicePeak > delayedPeak ? slicePeak : delayedPeak;
        if (instantMag > tailEnergy_) {
            tailEnergy_ = instantMag;
        } else {
            tailEnergy_ *= 0.995f;
            if (tailEnergy_ < 1e-8f) {
                tailEnergy_ = 0.0f;
            }
        }

        return slicePeak > 1e-7f || tailEnergy_ > 1e-7f;
    }

    private float clampedFeedback() const pure @safe {
        if (!isFinite(feedback) || feedback < 0.0f) return 0.0f;
        if (feedback > 0.98f) return 0.98f;
        return feedback;
    }

    private float delaySamples(float ms, float sr) const pure @safe {
        immutable float clampedMs = (!isFinite(ms) || ms < 1.0f) ? 1.0f : (ms > 2000.0f ? 2000.0f : ms);
        float s = clampedMs * 0.001f * sr;
        if (s < 1.0f) s = 1.0f;
        if (!lines_[0].empty() && s > cast(float) lines_[0].maxDelay()) {
            s = cast(float) lines_[0].maxDelay();
        }
        return s;
    }
}
