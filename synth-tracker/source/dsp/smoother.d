/**
 * File:         source/dsp/smoother.d
 * Module:       dsp.smoother
 * Phase:        Phase 1.4 — Audio-Rate Parameter Smoothers
 *
 * Purpose:
 *   Provides linear and exponential one-pole parameter smoothers supporting smooth live UI/MIDI/CV transitions alongside instant snap during preset/project load.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow pure @safe; explicit non-NaN default init (= 0.0f / 1.0) and zero heap allocations.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: std.math (exp, fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ParamSmoother : prepare(), setSmoothingTime(), setTarget(val, instant), next(), processBlock(), isSettled(), reset()
 *   - struct LinearRamp : reset(), setTarget(), setTargetMs(), next(), isSettled(), current(), target()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.smoother;

import std.math : exp, fabs, isFinite;

/**
 * Exponential one-pole parameter smoother with preset instant-snap support.
 *
 * Smooths scalar parameter edits cleanly at audio rate to eliminate zipper noise while
 * snapping immediately when instant = true (preset load or initialization).
 */
struct ParamSmoother {
    private float current_ = 0.0f;
    private float target_ = 0.0f;
    private double coeff_ = 1.0;
    private float epsilon_ = 1e-6f;

    @nogc nothrow pure @safe:

    /**
     * Initializes smoothing time constant and snaps both current and target to initialValue.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz (>= 1.0f).
     *   timeMs = Exponential 63.2% time constant in milliseconds (<= 0.0f means instant).
     *   initialValue = Starting parameter value.
     */
    void prepare(float sampleRate, float timeMs, float initialValue = 0.0f) {
        setSmoothingTime(sampleRate, timeMs);
        reset(initialValue);
    }

    /**
     * Updates the exponential smoothing time constant without altering current value.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz (>= 1.0f).
     *   timeMs = Smoothing time constant in milliseconds (<= 0.0f selects instant snap).
     */
    void setSmoothingTime(float sampleRate, float timeMs) {
        if (!isFinite(timeMs) || timeMs <= 0.0f || !isFinite(sampleRate) || sampleRate <= 0.0f) {
            coeff_ = 1.0;
            return;
        }
        immutable double tauSamples = cast(double) timeMs * 0.001 * cast(double) sampleRate;
        if (tauSamples <= 0.0) {
            coeff_ = 1.0;
        } else {
            coeff_ = 1.0 - exp(-1.0 / tauSamples);
        }
    }

    /**
     * Sets a new smoothing target, optionally snapping immediately.
     *
     * Params:
     *   val = Target parameter value (non-finite values fall back to 0.0f).
     *   instant = When true, updates current_ immediately without ramping.
     */
    void setTarget(float val, bool instant = false) {
        immutable float clean = isFinite(val) ? val : 0.0f;
        target_ = clean;
        if (instant || coeff_ >= 1.0) {
            current_ = clean;
        }
    }

    /**
     * Resets both current and target values immediately without smoothing.
     *
     * Params:
     *   value = Reset value (non-finite values fall back to 0.0f).
     */
    void reset(float value = 0.0f) {
        immutable float clean = isFinite(value) ? value : 0.0f;
        current_ = clean;
        target_ = clean;
    }

    /**
     * Advances the smoother by one sample and returns the smoothed parameter value.
     *
     * Returns:
     *   Smoothed scalar value.
     */
    float next() {
        immutable float diff = target_ - current_;
        if (fabs(diff) <= epsilon_ || coeff_ >= 1.0) {
            current_ = target_;
            return current_;
        }
        current_ += cast(float)(coeff_ * cast(double) diff);
        return current_;
    }

    /**
     * Generates a contiguous slice of smoothed parameter samples.
     *
     * Params:
     *   dst = Destination buffer filled sample-by-sample.
     */
    void processBlock(float[] dst) {
        foreach (ref s; dst) {
            s = next();
        }
    }

    /**
     * Returns the current smoothed parameter value without advancing state.
     *
     * Returns:
     *   Current value.
     */
    float current() const {
        return current_;
    }

    /**
     * Returns the destination target parameter value.
     *
     * Returns:
     *   Target value.
     */
    float target() const {
        return target_;
    }

    /**
     * Reports whether the smoother has converged exactly onto its target value.
     *
     * Returns:
     *   True if current == target.
     */
    bool isSettled() const {
        return current_ == target_;
    }
}

/**
 * Fixed-duration linear parameter ramp reaching target exactly after durationSamples steps.
 */
struct LinearRamp {
    private double current_ = 0.0;
    private float target_ = 0.0f;
    private double step_ = 0.0;
    private uint remainingSamples_ = 0;

    @nogc nothrow pure @safe:

    /**
     * Resets both current and target values immediately with zero remaining ramp samples.
     *
     * Params:
     *   value = Reset parameter value.
     */
    void reset(float value = 0.0f) {
        immutable float clean = isFinite(value) ? value : 0.0f;
        current_ = clean;
        target_ = clean;
        step_ = 0.0;
        remainingSamples_ = 0;
    }

    /**
     * Starts a linear ramp from the current value to target over durationSamples samples.
     *
     * Params:
     *   targetVal = Destination value (non-finite inputs fall back to 0.0f).
     *   durationSamples = Sample duration (0 snaps immediately).
     */
    void setTarget(float targetVal, uint durationSamples) {
        immutable float clean = isFinite(targetVal) ? targetVal : 0.0f;
        target_ = clean;
        if (durationSamples == 0) {
            current_ = clean;
            step_ = 0.0;
            remainingSamples_ = 0;
            return;
        }
        remainingSamples_ = durationSamples;
        step_ = (cast(double) clean - current_) / cast(double) durationSamples;
    }

    /**
     * Starts a linear ramp specified in milliseconds at the active sample rate.
     *
     * Params:
     *   targetVal = Destination value.
     *   durationMs = Ramp duration in milliseconds (<= 0.0f snaps immediately).
     *   sampleRate = Sample rate in Hertz (> 0.0f).
     */
    void setTargetMs(float targetVal, float durationMs, float sampleRate) {
        if (!isFinite(durationMs) || durationMs <= 0.0f || !isFinite(sampleRate) || sampleRate <= 0.0f) {
            setTarget(targetVal, 0);
            return;
        }
        immutable double samples = cast(double) durationMs * 0.001 * cast(double) sampleRate;
        immutable uint count = samples < 1.0 ? 1 : cast(uint)(samples + 0.5);
        setTarget(targetVal, count);
    }

    /**
     * Advances the linear ramp by one sample.
     *
     * Returns:
     *   Interpolated sample value, landing exactly on target on the final ramp step.
     */
    float next() {
        if (remainingSamples_ == 0) {
            return target_;
        }
        remainingSamples_--;
        if (remainingSamples_ == 0) {
            current_ = target_;
            step_ = 0.0;
            return target_;
        }
        current_ += step_;
        return cast(float) current_;
    }

    /**
     * Reports whether the linear ramp has completed.
     *
     * Returns:
     *   True if remainingSamples == 0.
     */
    bool isSettled() const {
        return remainingSamples_ == 0;
    }

    /**
     * Returns the current ramp output without advancing state.
     *
     * Returns:
     *   Current ramp value.
     */
    float current() const {
        return cast(float) current_;
    }

    /**
     * Returns the destination target value.
     *
     * Returns:
     *   Target value.
     */
    float target() const {
        return target_;
    }
}
