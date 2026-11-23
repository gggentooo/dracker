/**
 * File:         source/dsp/oscillator.d
 * Module:       dsp.oscillator
 * Phase:        Phase 1.4 — PolyBLEP, Wavetable & Noise Oscillators
 *
 * Purpose:
 *   Implements anti-aliased PolyBLEP oscillators (saw, pulse/square, triangle, sine), arbitrary single-cycle drawn wavetable playback, and deterministic PRNG white/pink noise.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero NaN init and instance-scoped phase accumulator.
 *
 * Dependencies:
 *   Internal: foundation.types, dsp.tables, dsp.interp
 *   External: std.math (fabs, floor, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum OscWaveform : ubyte { sine, triangle, saw, pulse, noise, drawnWave }
 *   - struct DeterministicNoise : seed(), nextUint(), white(), pink(), reset()
 *   - struct PolyBlepOsc : setFrequency(), syncPhase(), reset(), phase(), nextSample()
 *   - struct DrawnWaveOsc : setFrequency(), syncPhase(), reset(), phase(), nextSample()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.oscillator;

import std.math : fabs, floor, isFinite;

import dsp.interp : sampleBufferWrapped;
import dsp.tables : lookupSine;

/**
 * Standard oscillator waveform types supported across built-in synthesizers.
 */
enum OscWaveform : ubyte {
    sine = 0,
    triangle = 1,
    saw = 2,
    pulse = 3,
    noise = 4,
    drawnWave = 5
}

/**
 * Deterministic xorshift32 white noise and 7-stage Kellet pink noise generator.
 *
 * Instance-scoped state ensures parallel tests and MetaModule instances remain re-entrant.
 */
struct DeterministicNoise {
    private uint state_ = 0x1234_5678u;
    private float[7] pink_ = 0.0f;

    @nogc nothrow pure @safe:

    /**
     * Sets the PRNG seed without clearing pink filter history (zero maps to default seed).
     *
     * Params:
     *   seedVal = Non-zero 32-bit PRNG seed.
     */
    void seed(uint seedVal) {
        state_ = seedVal == 0 ? 0x1234_5678u : seedVal;
    }

    /**
     * Resets both PRNG state and pink-noise filter stages cleanly.
     *
     * Params:
     *   seedVal = Initial 32-bit PRNG seed.
     */
    void reset(uint seedVal = 0x1234_5678u) {
        seed(seedVal);
        pink_[] = 0.0f;
    }

    /**
     * Advances and returns the next raw 32-bit unsigned pseudo-random word.
     *
     * Returns:
     *   Non-zero 32-bit unsigned integer.
     */
    uint nextUint() {
        uint x = state_ == 0 ? 0x1234_5678u : state_;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        state_ = x;
        return x;
    }

    /**
     * Generates one uniform white-noise sample in [-1.0f, 1.0f).
     *
     * Returns:
     *   White noise sample.
     */
    float white() {
        immutable int signed24 = cast(int)(nextUint() >> 8) - 8_388_608;
        return cast(float) signed24 * (1.0f / 8_388_608.0f);
    }

    /**
     * Generates one approximately -3 dB/octave pink-noise sample clamped to [-1.0f, 1.0f].
     *
     * Returns:
     *   Pink noise sample.
     */
    float pink() {
        immutable float w = white();
        pink_[0] = 0.99886f * pink_[0] + w * 0.0555179f;
        pink_[1] = 0.99332f * pink_[1] + w * 0.0750759f;
        pink_[2] = 0.96900f * pink_[2] + w * 0.1538520f;
        pink_[3] = 0.86650f * pink_[3] + w * 0.3104856f;
        pink_[4] = 0.55000f * pink_[4] + w * 0.5329522f;
        pink_[5] = -0.7616f * pink_[5] - w * 0.0168980f;
        immutable float total = (
            pink_[0] + pink_[1] + pink_[2] + pink_[3] + pink_[4] + pink_[5] + pink_[6] + w * 0.5362f
        ) * 0.11f;
        pink_[6] = w * 0.115926f;
        if (total > 1.0f) {
            return 1.0f;
        }
        if (total < -1.0f) {
            return -1.0f;
        }
        return total;
    }
}

/**
 * Anti-aliased PolyBLEP / PolyBLAMP oscillator supporting sine, triangle, saw, pulse, and noise.
 */
struct PolyBlepOsc {
    private double phase_ = 0.0;
    private double phaseInc_ = 0.0;
    private DeterministicNoise noise_;

    @nogc nothrow pure @safe:

    /**
     * Evaluates the quadratic PolyBLEP residual at normalized phase t and step dt.
     *
     * Params:
     *   t = Normalized phase in [0.0, 1.0).
     *   dt = Normalized phase increment per sample in (0.0, 0.5).
     *
     * Returns:
     *   Step anti-aliasing correction term.
     */
    static float polyBlep(double t, double dt) {
        if (dt <= 0.0) {
            return 0.0f;
        }
        if (t < dt) {
            immutable double x = t / dt;
            return cast(float)(x + x - x * x - 1.0);
        }
        if (t > 1.0 - dt) {
            immutable double x = (t - 1.0) / dt;
            return cast(float)(x * x + x + x + 1.0);
        }
        return 0.0f;
    }

    /**
     * Evaluates the C2 cubic PolyBLAMP corner-rounding kernel for a unit slope change at phase 0.
     *
     * Params:
     *   t = Normalized phase in [0.0, 1.0).
     *   dt = Normalized phase increment per sample (> 0.0).
     *
     * Returns:
     *   Slope-discontinuity anti-aliasing correction term scaled by dt.
     */
    static float polyBlamp(double t, double dt) {
        if (dt <= 0.0) {
            return 0.0f;
        }
        if (t < dt) {
            immutable double x = 1.0 - t / dt;
            return cast(float)(dt * x * x * x / 6.0);
        }
        if (t > 1.0 - dt) {
            immutable double x = 1.0 - (1.0 - t) / dt;
            return cast(float)(dt * x * x * x / 6.0);
        }
        return 0.0f;
    }

    /**
     * Sets oscillator frequency in Hertz and computes normalized phase increment.
     *
     * Params:
     *   freqHz = Fundamental frequency in Hertz (clamped to [0.0, 0.49 * sampleRate]).
     *   sampleRate = Audio sample rate in Hertz (>= 1.0f).
     */
    void setFrequency(float freqHz, float sampleRate) {
        immutable double sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44100.0 : cast(double) sampleRate;
        double f = isFinite(freqHz) ? cast(double) freqHz : 0.0;
        if (f < 0.0) {
            f = 0.0;
        } else if (f > 0.49 * sr) {
            f = 0.49 * sr;
        }
        phaseInc_ = f / sr;
    }

    /**
     * Sets the oscillator phase directly, wrapping any finite value into [0.0, 1.0).
     *
     * Params:
     *   phase01 = Normalized phase in cycles.
     */
    void syncPhase(float phase01 = 0.0f) {
        if (!isFinite(phase01)) {
            phase_ = 0.0;
            return;
        }
        double wrapped = cast(double) phase01 - floor(cast(double) phase01);
        if (wrapped < 0.0 || wrapped >= 1.0) {
            wrapped = 0.0;
        }
        phase_ = wrapped;
    }

    /**
     * Resets phase accumulator and deterministic noise generator.
     */
    void reset() {
        phase_ = 0.0;
        noise_.reset();
    }

    /**
     * Returns the current normalized oscillator phase in [0.0, 1.0).
     *
     * Returns:
     *   Current normalized phase.
     */
    double phase() const {
        return phase_;
    }

    /**
     * Generates one anti-aliased sample for the requested waveform and advances phase.
     *
     * Params:
     *   waveform = Waveform shape to synthesize.
     *   pulseWidth = Duty cycle in [0.01f, 0.99f] used when waveform == OscWaveform.pulse.
     *
     * Returns:
     *   Synthesized audio sample nominally within [-1.0f, 1.0f].
     */
    float nextSample(OscWaveform waveform, float pulseWidth = 0.5f) {
        immutable double t = phase_;
        immutable double dt = phaseInc_;
        float sample = 0.0f;

        final switch (waveform) {
            case OscWaveform.sine:
            case OscWaveform.drawnWave:
                sample = lookupSine(cast(float) t);
                break;

            case OscWaveform.saw:
                sample = cast(float)(2.0 * t - 1.0) - polyBlep(t, dt);
                break;

            case OscWaveform.pulse: {
                double pw = isFinite(pulseWidth) ? cast(double) pulseWidth : 0.5;
                if (pw < 0.01) {
                    pw = 0.01;
                } else if (pw > 0.99) {
                    pw = 0.99;
                }
                double tShifted = t + (1.0 - pw);
                if (tShifted >= 1.0) {
                    tShifted -= 1.0;
                }
                sample = (t < pw ? 1.0f : -1.0f) + polyBlep(t, dt) - polyBlep(tShifted, dt);
                break;
            }

            case OscWaveform.triangle: {
                double tHalf = t + 0.5;
                if (tHalf >= 1.0) {
                    tHalf -= 1.0;
                }
                immutable double naive = 1.0 - 4.0 * fabs(t - 0.5);
                sample = cast(float) naive + 8.0f * polyBlamp(t, dt) - 8.0f * polyBlamp(tHalf, dt);
                break;
            }

            case OscWaveform.noise:
                sample = noise_.white();
                break;
        }

        double nextPhase = t + dt;
        if (nextPhase >= 1.0) {
            nextPhase -= floor(nextPhase);
        }
        phase_ = nextPhase;
        return sample;
    }
}

/**
 * Single-cycle wavetable oscillator interpolating arbitrary drawn waveform slices.
 */
struct DrawnWaveOsc {
    private double phase_ = 0.0;
    private double phaseInc_ = 0.0;

    @nogc nothrow pure @safe:

    /**
     * Sets oscillator playback frequency in Hertz.
     *
     * Params:
     *   freqHz = Fundamental frequency in Hertz (clamped to [0.0, 0.49 * sampleRate]).
     *   sampleRate = Audio sample rate in Hertz (>= 1.0f).
     */
    void setFrequency(float freqHz, float sampleRate) {
        immutable double sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44100.0 : cast(double) sampleRate;
        double f = isFinite(freqHz) ? cast(double) freqHz : 0.0;
        if (f < 0.0) {
            f = 0.0;
        } else if (f > 0.49 * sr) {
            f = 0.49 * sr;
        }
        phaseInc_ = f / sr;
    }

    /**
     * Sets oscillator phase wrapped into [0.0, 1.0).
     *
     * Params:
     *   phase01 = Normalized phase in cycles.
     */
    void syncPhase(float phase01 = 0.0f) {
        if (!isFinite(phase01)) {
            phase_ = 0.0;
            return;
        }
        double wrapped = cast(double) phase01 - floor(cast(double) phase01);
        if (wrapped < 0.0 || wrapped >= 1.0) {
            wrapped = 0.0;
        }
        phase_ = wrapped;
    }

    /**
     * Resets the wavetable phase accumulator to zero.
     */
    void reset() {
        phase_ = 0.0;
    }

    /**
     * Returns the current normalized phase in [0.0, 1.0).
     *
     * Returns:
     *   Normalized phase accumulator.
     */
    double phase() const {
        return phase_;
    }

    /**
     * Reads one interpolated sample from waveform and advances the phase accumulator.
     *
     * Params:
     *   waveform = Single-cycle sample table (returns 0.0f if empty).
     *   useCatmullRom = Selects 4-point Catmull-Rom when true, or linear when false.
     *
     * Returns:
     *   Interpolated wavetable sample.
     */
    float nextSample(const(float)[] waveform, bool useCatmullRom = true) {
        if (waveform.length == 0) {
            return 0.0f;
        }
        immutable double pos = phase_ * cast(double) waveform.length;
        immutable float outVal = sampleBufferWrapped(waveform, pos, useCatmullRom);
        double nextPhase = phase_ + phaseInc_;
        if (nextPhase >= 1.0) {
            nextPhase -= floor(nextPhase);
        }
        phase_ = nextPhase;
        return outVal;
    }
}
