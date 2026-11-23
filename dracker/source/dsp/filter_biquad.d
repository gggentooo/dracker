/**
 * File:         source/dsp/filter_biquad.d
 * Module:       dsp.filter_biquad
 * Phase:        Phase 1.3 — Cascaded RBJ Biquad & 1-Pole Filters
 *
 * Purpose:
 *   Implements 1-pole and 2-pole RBJ biquad filters (LPF, HPF, BPF, Notch, Allpass, Low/High Shelf, Peaking) using double-precision internal delay state for low-cutoff stability.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero initialization of double internal delay state to prevent D NaN poisoning.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.math_rt, dsp.tables
 *   External: std.math (cos, exp, fabs, isFinite, pow, sin, sqrt)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum OnePoleMode : ubyte { lowpass, highpass }
 *   - struct OnePoleFilter : configure(), processSample(), processBlock(), reset(), isTailSilent()
 *   - enum BiquadMode : ubyte { lowpass, highpass, bandpass, notch, allpass, peaking, lowShelf, highShelf }
 *   - struct BiquadFilter : configure(), processSample(), processBlock(), reset(), magnitudeAt(), isTailSilent()
 *   - struct CascadedBiquad(size_t Stages)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.filter_biquad;

import std.math : cos, exp, fabs, isFinite, pow, sin, sqrt;

import dsp.tables : PI_D, TWO_PI_D;

/**
 * Filter polarity for first-order one-pole RC filters.
 */
enum OnePoleMode : ubyte {
    lowpass = 0,
    highpass = 1
}

/**
 * First-order one-pole filter with double-precision internal state.
 */
struct OnePoleFilter {
    private double a0_ = 1.0;
    private double a1_ = 0.0;
    private double b1_ = 0.0;
    private double x1_ = 0.0;
    private double y1_ = 0.0;

    @nogc nothrow pure @safe:

    /**
     * Computes filter coefficients for the given mode, cutoff frequency, and sample rate.
     *
     * Params:
     *   mode = Lowpass or highpass topology.
     *   cutoffHz = Corner frequency in Hertz, clamped safely to [0.5, 0.495 * sampleRate].
     *   sampleRate = Audio sample rate in Hertz (>= 1.0f).
     */
    void configure(OnePoleMode mode, float cutoffHz, float sampleRate) {
        immutable double sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44100.0 : cast(double) sampleRate;
        double fc = isFinite(cutoffHz) ? cast(double) cutoffHz : 1000.0;
        if (fc < 0.5) {
            fc = 0.5;
        } else if (fc > 0.495 * sr) {
            fc = 0.495 * sr;
        }

        immutable double pole = exp(-TWO_PI_D * fc / sr);
        if (mode == OnePoleMode.lowpass) {
            a0_ = 1.0 - pole;
            a1_ = 0.0;
            b1_ = pole;
        } else {
            immutable double g = 0.5 * (1.0 + pole);
            a0_ = g;
            a1_ = -g;
            b1_ = pole;
        }
    }

    /**
     * Clears internal one-pole filter delay state.
     */
    void reset() {
        x1_ = 0.0;
        y1_ = 0.0;
    }

    /**
     * Processes one sample through the 1-pole filter, clamping non-finite input to 0.0.
     *
     * Params:
     *   input = Input audio sample.
     *
     * Returns:
     *   Filtered output sample.
     */
    float processSample(float input) {
        immutable double x0 = isFinite(input) ? cast(double) input : 0.0;
        immutable double y0 = a0_ * x0 + a1_ * x1_ + b1_ * y1_;
        x1_ = x0;
        y1_ = y0;
        return cast(float) y0;
    }

    /**
     * Processes a contiguous slice of samples in place.
     *
     * Params:
     *   samples = Mutable audio sample buffer.
     */
    void processBlock(float[] samples) {
        foreach (ref s; samples) {
            s = processSample(s);
        }
    }

    /**
     * Reports whether stored filter memory has decayed below threshold.
     *
     * Params:
     *   threshold = Absolute state energy threshold.
     *
     * Returns:
     *   True if both |x1| and |y1| are below threshold.
     */
    bool isTailSilent(double threshold = 1e-7) const {
        return fabs(x1_) <= threshold && fabs(y1_) <= threshold;
    }
}

/**
 * Second-order RBJ Audio EQ Cookbook filter modes.
 */
enum BiquadMode : ubyte {
    lowpass = 0,
    highpass = 1,
    bandpass = 2,
    notch = 3,
    allpass = 4,
    peaking = 5,
    lowShelf = 6,
    highShelf = 7
}

/**
 * Second-order Transposed Direct Form II RBJ biquad filter in double precision.
 *
 * Double internal accumulators and coefficients prevent low-frequency pole precision collapse
 * at high sample rates (96-192 kHz) and suppress coefficient/quantization drift.
 */
struct BiquadFilter {
    private double b0_ = 1.0;
    private double b1_ = 0.0;
    private double b2_ = 0.0;
    private double a1_ = 0.0;
    private double a2_ = 0.0;
    private double s1_ = 0.0;
    private double s2_ = 0.0;

    @nogc nothrow pure @safe:

    /**
     * Configures normalized biquad coefficients from RBJ Audio EQ Cookbook formulas.
     *
     * Params:
     *   mode = Filter topology.
     *   freqHz = Center/cutoff frequency in Hertz (clamped to [1.0, 0.495 * sampleRate]).
     *   q = Quality factor / resonance (clamped to [0.05, 50.0]).
     *   gainDb = Shelf/peaking boost or cut in decibels (clamped to [-48.0, 48.0]).
     *   sampleRate = Sample rate in Hertz (>= 1.0f).
     */
    void configure(BiquadMode mode, float freqHz, float q, float gainDb, float sampleRate) {
        immutable double sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44100.0 : cast(double) sampleRate;
        double fc = isFinite(freqHz) ? cast(double) freqHz : 1000.0;
        if (fc < 1.0) {
            fc = 1.0;
        } else if (fc > 0.495 * sr) {
            fc = 0.495 * sr;
        }

        double qClamped = isFinite(q) ? cast(double) q : 0.7071067811865475;
        if (qClamped < 0.05) {
            qClamped = 0.05;
        } else if (qClamped > 50.0) {
            qClamped = 50.0;
        }

        double gDb = isFinite(gainDb) ? cast(double) gainDb : 0.0;
        if (gDb < -48.0) {
            gDb = -48.0;
        } else if (gDb > 48.0) {
            gDb = 48.0;
        }

        immutable double w0 = TWO_PI_D * fc / sr;
        immutable double cosW0 = cos(w0);
        immutable double sinW0 = sin(w0);
        immutable double alpha = sinW0 / (2.0 * qClamped);
        immutable double aAmp = pow(10.0, gDb / 40.0);
        immutable double twoSqrtAAlpha = 2.0 * sqrt(aAmp) * alpha;

        double b0 = 1.0;
        double b1 = 0.0;
        double b2 = 0.0;
        double a0 = 1.0;
        double a1 = 0.0;
        double a2 = 0.0;

        final switch (mode) {
            case BiquadMode.lowpass:
                b0 = 0.5 * (1.0 - cosW0);
                b1 = 1.0 - cosW0;
                b2 = 0.5 * (1.0 - cosW0);
                a0 = 1.0 + alpha;
                a1 = -2.0 * cosW0;
                a2 = 1.0 - alpha;
                break;

            case BiquadMode.highpass:
                b0 = 0.5 * (1.0 + cosW0);
                b1 = -(1.0 + cosW0);
                b2 = 0.5 * (1.0 + cosW0);
                a0 = 1.0 + alpha;
                a1 = -2.0 * cosW0;
                a2 = 1.0 - alpha;
                break;

            case BiquadMode.bandpass:
                b0 = alpha;
                b1 = 0.0;
                b2 = -alpha;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cosW0;
                a2 = 1.0 - alpha;
                break;

            case BiquadMode.notch:
                b0 = 1.0;
                b1 = -2.0 * cosW0;
                b2 = 1.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cosW0;
                a2 = 1.0 - alpha;
                break;

            case BiquadMode.allpass:
                b0 = 1.0 - alpha;
                b1 = -2.0 * cosW0;
                b2 = 1.0 + alpha;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cosW0;
                a2 = 1.0 - alpha;
                break;

            case BiquadMode.peaking:
                b0 = 1.0 + alpha * aAmp;
                b1 = -2.0 * cosW0;
                b2 = 1.0 - alpha * aAmp;
                a0 = 1.0 + alpha / aAmp;
                a1 = -2.0 * cosW0;
                a2 = 1.0 - alpha / aAmp;
                break;

            case BiquadMode.lowShelf:
                b0 = aAmp * ((aAmp + 1.0) - (aAmp - 1.0) * cosW0 + twoSqrtAAlpha);
                b1 = 2.0 * aAmp * ((aAmp - 1.0) - (aAmp + 1.0) * cosW0);
                b2 = aAmp * ((aAmp + 1.0) - (aAmp - 1.0) * cosW0 - twoSqrtAAlpha);
                a0 = (aAmp + 1.0) + (aAmp - 1.0) * cosW0 + twoSqrtAAlpha;
                a1 = -2.0 * ((aAmp - 1.0) + (aAmp + 1.0) * cosW0);
                a2 = (aAmp + 1.0) + (aAmp - 1.0) * cosW0 - twoSqrtAAlpha;
                break;

            case BiquadMode.highShelf:
                b0 = aAmp * ((aAmp + 1.0) + (aAmp - 1.0) * cosW0 + twoSqrtAAlpha);
                b1 = -2.0 * aAmp * ((aAmp - 1.0) + (aAmp + 1.0) * cosW0);
                b2 = aAmp * ((aAmp + 1.0) + (aAmp - 1.0) * cosW0 - twoSqrtAAlpha);
                a0 = (aAmp + 1.0) - (aAmp - 1.0) * cosW0 + twoSqrtAAlpha;
                a1 = 2.0 * ((aAmp - 1.0) - (aAmp + 1.0) * cosW0);
                a2 = (aAmp + 1.0) - (aAmp - 1.0) * cosW0 - twoSqrtAAlpha;
                break;
        }

        immutable double invA0 = 1.0 / a0;
        b0_ = b0 * invA0;
        b1_ = b1 * invA0;
        b2_ = b2 * invA0;
        a1_ = a1 * invA0;
        a2_ = a2 * invA0;
    }

    /**
     * Resets the internal Transposed Direct Form II state registers to zero.
     */
    void reset() {
        s1_ = 0.0;
        s2_ = 0.0;
    }

    /**
     * Processes one sample through the biquad filter, sanitizing non-finite inputs to 0.0.
     *
     * Params:
     *   input = Input audio sample.
     *
     * Returns:
     *   Filtered output sample.
     */
    float processSample(float input) {
        immutable double x = isFinite(input) ? cast(double) input : 0.0;
        immutable double y = b0_ * x + s1_;
        s1_ = b1_ * x - a1_ * y + s2_;
        s2_ = b2_ * x - a2_ * y;
        return cast(float) y;
    }

    /**
     * Processes a contiguous slice of audio samples in place.
     *
     * Params:
     *   samples = Mutable sample buffer.
     */
    void processBlock(float[] samples) {
        foreach (ref s; samples) {
            s = processSample(s);
        }
    }

    /**
     * Evaluates the analytical steady-state magnitude response |H(e^(j*omega))| at freqHz.
     *
     * Params:
     *   freqHz = Probe frequency in Hertz.
     *   sampleRate = Sample rate in Hertz.
     *
     * Returns:
     *   Linear magnitude gain >= 0.0.
     */
    double magnitudeAt(double freqHz, double sampleRate) const {
        if (!isFinite(freqHz) || !isFinite(sampleRate) || sampleRate <= 0.0) {
            return 0.0;
        }
        immutable double w = TWO_PI_D * freqHz / sampleRate;
        immutable double cosW = cos(w);
        immutable double sinW = sin(w);
        immutable double cos2W = cos(2.0 * w);
        immutable double sin2W = sin(2.0 * w);

        immutable double numRe = b0_ + b1_ * cosW + b2_ * cos2W;
        immutable double numIm = -(b1_ * sinW + b2_ * sin2W);
        immutable double denRe = 1.0 + a1_ * cosW + a2_ * cos2W;
        immutable double denIm = -(a1_ * sinW + a2_ * sin2W);
        immutable double denMagSq = denRe * denRe + denIm * denIm;
        if (denMagSq <= 0.0) {
            return 0.0;
        }
        return sqrt((numRe * numRe + numIm * numIm) / denMagSq);
    }

    /**
     * Reports whether stored filter state has decayed below threshold.
     *
     * Params:
     *   threshold = Absolute state amplitude threshold.
     *
     * Returns:
     *   True if both internal delay registers are within threshold.
     */
    bool isTailSilent(double threshold = 1e-7) const {
        return fabs(s1_) <= threshold && fabs(s2_) <= threshold;
    }
}

/**
 * Series cascade of N BiquadFilter stages for steeper slopes (e.g. 24 dB/oct).
 */
struct CascadedBiquad(size_t Stages) {
    static assert(Stages > 0, "CascadedBiquad requires at least one biquad stage");

    BiquadFilter[Stages] stages;

    @nogc nothrow pure @safe:

    /**
     * Configures all stages identically with the specified filter response.
     *
     * Params:
     *   mode = Filter topology.
     *   freqHz = Corner/center frequency in Hertz.
     *   q = Stage Q factor.
     *   gainDb = Stage gain in decibels.
     *   sampleRate = Sample rate in Hertz.
     */
    void configureAll(BiquadMode mode, float freqHz, float q, float gainDb, float sampleRate) {
        foreach (ref st; stages) {
            st.configure(mode, freqHz, q, gainDb, sampleRate);
        }
    }

    /**
     * Configures a specific stage index independently.
     *
     * Params:
     *   stageIdx = Zero-based stage index (< Stages).
     *   mode = Filter topology.
     *   freqHz = Corner/center frequency in Hertz.
     *   q = Stage Q factor.
     *   gainDb = Stage gain in decibels.
     *   sampleRate = Sample rate in Hertz.
     */
    void configureStage(
        size_t stageIdx,
        BiquadMode mode,
        float freqHz,
        float q,
        float gainDb,
        float sampleRate
    ) {
        assert(stageIdx < Stages, "CascadedBiquad stage index out of bounds");
        stages[stageIdx].configure(mode, freqHz, q, gainDb, sampleRate);
    }

    /**
     * Resets all cascaded filter stages to zero internal state.
     */
    void reset() {
        foreach (ref st; stages) {
            st.reset();
        }
    }

    /**
     * Passes one sample sequentially through all biquad stages.
     *
     * Params:
     *   input = Input sample.
     *
     * Returns:
     *   Filtered output sample.
     */
    float processSample(float input) {
        float x = input;
        foreach (ref st; stages) {
            x = st.processSample(x);
        }
        return x;
    }

    /**
     * Processes a contiguous slice of audio samples through all stages in place.
     *
     * Params:
     *   samples = Mutable audio sample buffer.
     */
    void processBlock(float[] samples) {
        foreach (ref st; stages) {
            st.processBlock(samples);
        }
    }

    /**
     * Reports whether every stage's stored state has decayed below threshold.
     *
     * Params:
     *   threshold = Absolute state amplitude threshold.
     *
     * Returns:
     *   True if all stages report silent tails.
     */
    bool isTailSilent(double threshold = 1e-7) const {
        foreach (ref st; stages) {
            if (!st.isTailSilent(threshold)) {
                return false;
            }
        }
        return true;
    }
}
