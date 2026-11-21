/**
 * File:         source/dsp/filter_svf.d
 * Module:       dsp.filter_svf
 * Phase:        Phase 1.3 — Cytomic TPT Zero-Delay-Feedback SVF
 *
 * Purpose:
 *   Implements Andy Simper's Cytomic trapezoidal TPT state-variable filter delivering audio-rate modulation stability without blowups in AnalogGen and Filter modules.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init on double ic1eq/ic2eq state variables.
 *
 * Dependencies:
 *   Internal: foundation.types, dsp.tables
 *   External: std.math (fabs, isFinite, tan)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum SvfMode : ubyte { lpf, hpf, bpf, notch, peak, allpass }
 *   - struct SvfOutputs : simultaneous multi-mode outputs per sample
 *   - struct CytomicSvf : setParams(), setParamsQ(), processAll(), processSample(), processBlock(), reset(), isTailSilent()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.filter_svf;

import std.math : fabs, isFinite, tan;

import dsp.tables : PI_D;

/**
 * Filter output selection modes supported by CytomicSvf.
 */
enum SvfMode : ubyte {
    lpf = 0,
    hpf = 1,
    bpf = 2,
    notch = 3,
    peak = 4,
    allpass = 5
}

/**
 * Simultaneous multi-mode outputs produced on each CytomicSvf sample evaluation.
 */
struct SvfOutputs {
    float low = 0.0f;
    float band = 0.0f;
    float high = 0.0f;
    float notch = 0.0f;
    float peak = 0.0f;
    float allpass = 0.0f;
}

/**
 * Cytomic trapezoidal TPT zero-delay-feedback state-variable filter in double precision.
 *
 * Preserves passband gain and pole stability even under sample-by-sample audio-rate cutoff
 * and resonance modulation.
 */
struct CytomicSvf {
    private double g_ = 0.0;
    private double k_ = 1.4142135623730951;
    private double a1_ = 1.0;
    private double a2_ = 0.0;
    private double a3_ = 0.0;
    private double ic1eq_ = 0.0;
    private double ic2eq_ = 0.0;

    @nogc nothrow pure @safe:

    /**
     * Updates filter tuning from cutoff frequency and normalized resonance [0.0, 1.0].
     *
     * Maps resonance in [0.0, 1.0] to damping k in [2.0, 0.02] so self-oscillation stays
     * stably bounded without numerical blowups.
     *
     * Params:
     *   cutoffHz = Cutoff frequency in Hertz, clamped to [5.0, 0.49 * sampleRate].
     *   resonance = Normalized resonance in [0.0f, 1.0f].
     *   sampleRate = Sample rate in Hertz (>= 1.0f).
     */
    void setParams(float cutoffHz, float resonance, float sampleRate) {
        double res = isFinite(resonance) ? cast(double) resonance : 0.0;
        if (res < 0.0) {
            res = 0.0;
        } else if (res > 1.0) {
            res = 1.0;
        }
        immutable double damping = 2.0 - 1.98 * res;
        configureWithDamping(cutoffHz, damping, sampleRate);
    }

    /**
     * Updates filter tuning using an explicit Q factor (>= 0.5f).
     *
     * Params:
     *   cutoffHz = Cutoff frequency in Hertz, clamped to [5.0, 0.49 * sampleRate].
     *   q = Quality factor clamped to [0.5f, 50.0f] where k = 1 / q.
     *   sampleRate = Sample rate in Hertz (>= 1.0f).
     */
    void setParamsQ(float cutoffHz, float q, float sampleRate) {
        double qVal = isFinite(q) ? cast(double) q : 0.7071067811865475;
        if (qVal < 0.5) {
            qVal = 0.5;
        } else if (qVal > 50.0) {
            qVal = 50.0;
        }
        configureWithDamping(cutoffHz, 1.0 / qVal, sampleRate);
    }

    private void configureWithDamping(float cutoffHz, double damping, float sampleRate) {
        immutable double sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44100.0 : cast(double) sampleRate;
        double fc = isFinite(cutoffHz) ? cast(double) cutoffHz : 1000.0;
        if (fc < 5.0) {
            fc = 5.0;
        } else if (fc > 0.49 * sr) {
            fc = 0.49 * sr;
        }

        g_ = tan(PI_D * fc / sr);
        k_ = damping;
        a1_ = 1.0 / (1.0 + g_ * (g_ + k_));
        a2_ = g_ * a1_;
        a3_ = g_ * a2_;
    }

    /**
     * Resets both trapezoidal integrator state variables to zero.
     */
    void reset() {
        ic1eq_ = 0.0;
        ic2eq_ = 0.0;
    }

    /**
     * Advances the TPT filter by one sample and returns all six simultaneous filter outputs.
     *
     * Params:
     *   input = Input sample (non-finite values are sanitized to 0.0).
     *
     * Returns:
     *   SvfOutputs struct containing low, band, high, notch, peak, and allpass taps.
     */
    SvfOutputs processAll(float input) {
        immutable double v0 = isFinite(input) ? cast(double) input : 0.0;
        immutable double v3 = v0 - ic2eq_;
        immutable double v1 = a1_ * ic1eq_ + a2_ * v3;
        immutable double v2 = ic2eq_ + a2_ * ic1eq_ + a3_ * v3;
        ic1eq_ = 2.0 * v1 - ic1eq_;
        ic2eq_ = 2.0 * v2 - ic2eq_;

        immutable double high = v0 - k_ * v1 - v2;
        immutable double notch = v0 - k_ * v1;
        immutable double peak = v2 - high;
        immutable double allpass = v0 - 2.0 * k_ * v1;

        return SvfOutputs(
            cast(float) v2,
            cast(float) v1,
            cast(float) high,
            cast(float) notch,
            cast(float) peak,
            cast(float) allpass
        );
    }

    /**
     * Advances the TPT filter by one sample and returns the requested mode output.
     *
     * Params:
     *   input = Input audio sample.
     *   mode = Desired filter response output.
     *
     * Returns:
     *   Filtered output sample.
     */
    float processSample(float input, SvfMode mode) {
        immutable SvfOutputs outSet = processAll(input);
        final switch (mode) {
            case SvfMode.lpf:     return outSet.low;
            case SvfMode.hpf:     return outSet.high;
            case SvfMode.bpf:     return outSet.band;
            case SvfMode.notch:   return outSet.notch;
            case SvfMode.peak:    return outSet.peak;
            case SvfMode.allpass: return outSet.allpass;
        }
    }

    /**
     * Processes a contiguous slice of audio samples in place for the selected filter mode.
     *
     * Params:
     *   samples = Mutable sample buffer.
     *   mode = Desired filter output mode.
     */
    void processBlock(float[] samples, SvfMode mode) {
        foreach (ref s; samples) {
            s = processSample(s, mode);
        }
    }

    /**
     * Reports whether both integrator states have decayed below threshold.
     *
     * Params:
     *   threshold = Absolute state amplitude threshold.
     *
     * Returns:
     *   True if both |ic1eq| and |ic2eq| are within threshold.
     */
    bool isTailSilent(double threshold = 1e-7) const {
        return fabs(ic1eq_) <= threshold && fabs(ic2eq_) <= threshold;
    }
}
