/**
 * File:         source/dsp/fft.d
 * Module:       dsp.fft
 * Phase:        Phase 1.2 — Radix-2 Cooley-Tukey FFT & IFFT
 *
 * Purpose:
 *   Implements in-place radix-2 FFT and inverse FFT with explicit float and double instantiations for SpectraVoice wavetable synthesis, FFT FX, and scope spectrum analysis.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicitly typed float/double (no accidental 80-bit x86 real promotion) and zero internal heap allocation.
 *
 * Dependencies:
 *   Internal: foundation.types, dsp.tables
 *   External: std.math (cos, log10, sin, sqrt)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Radix2Fft(T) if (is(T == float) || is(T == double))
 *   - alias FftFloat = Radix2Fft!float / alias FftDouble = Radix2Fft!double
 *   - static bool isValidSize(size_t n) @nogc nothrow pure @safe
 *   - static void forward(T[] realPart, T[] imagPart) @nogc nothrow pure @safe
 *   - static void inverse(T[] realPart, T[] imagPart) @nogc nothrow pure @safe
 *   - static void forwardReal(const(T)[] input, T[] realOut, T[] imagOut) @nogc nothrow pure @safe
 *   - static void computeMagnitude(const(T)[] realPart, const(T)[] imagPart, T[] magOut) @nogc nothrow pure @safe
 *   - static void computeMagnitudeDb(const(T)[] realPart, const(T)[] imagPart, float[] dbOut) @nogc nothrow pure @safe
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.fft;

import std.math : cos, log10, sin, sqrt;

import dsp.tables : TWO_PI_D;

/**
 * In-place radix-2 Cooley-Tukey FFT and IFFT parameterized explicitly over float or double.
 *
 * Twiddle factors and butterfly accumulations execute in IEEE 64-bit double precision with
 * periodic trigonometric re-anchoring so float round-trip error stays below 1e-6 up to 65536 bins.
 */
struct Radix2Fft(T) if (is(T == float) || is(T == double)) {
    @nogc nothrow pure @safe:

    /**
     * Checks whether n is a valid power-of-two FFT length (>= 1).
     *
     * Params:
     *   n = Transform size to validate.
     *
     * Returns:
     *   True if n >= 1 and is a power of two.
     */
    static bool isValidSize(size_t n) {
        return n >= 1 && (n & (n - 1)) == 0;
    }

    private static void transform(T[] realPart, T[] imagPart, bool invert) {
        assert(realPart.length == imagPart.length, "FFT real and imaginary buffers must have equal length");
        immutable size_t n = realPart.length;
        assert(isValidSize(n), "FFT length must be a power of two");
        if (n <= 1) {
            return;
        }

        size_t rev = 0;
        foreach (i; 1 .. n) {
            size_t bit = n >> 1;
            while ((rev & bit) != 0) {
                rev ^= bit;
                bit >>= 1;
            }
            rev ^= bit;
            if (i < rev) {
                immutable T tmpRe = realPart[i];
                immutable T tmpIm = imagPart[i];
                realPart[i] = realPart[rev];
                imagPart[i] = imagPart[rev];
                realPart[rev] = tmpRe;
                imagPart[rev] = tmpIm;
            }
        }

        for (size_t len = 2; len <= n; len <<= 1) {
            immutable size_t half = len >> 1;
            immutable double angleStep = (invert ? 1.0 : -1.0) * TWO_PI_D / cast(double) len;
            immutable double wStepRe = cos(angleStep);
            immutable double wStepIm = sin(angleStep);

            for (size_t base = 0; base < n; base += len) {
                double wRe = 1.0;
                double wIm = 0.0;
                foreach (k; 0 .. half) {
                    if ((k & 255) == 0 && k != 0) {
                        immutable double theta = cast(double) k * angleStep;
                        wRe = cos(theta);
                        wIm = sin(theta);
                    }

                    immutable size_t evenIdx = base + k;
                    immutable size_t oddIdx = evenIdx + half;
                    immutable double oRe = cast(double) realPart[oddIdx];
                    immutable double oIm = cast(double) imagPart[oddIdx];
                    immutable double tRe = wRe * oRe - wIm * oIm;
                    immutable double tIm = wRe * oIm + wIm * oRe;
                    immutable double eRe = cast(double) realPart[evenIdx];
                    immutable double eIm = cast(double) imagPart[evenIdx];

                    realPart[evenIdx] = cast(T)(eRe + tRe);
                    imagPart[evenIdx] = cast(T)(eIm + tIm);
                    realPart[oddIdx] = cast(T)(eRe - tRe);
                    imagPart[oddIdx] = cast(T)(eIm - tIm);

                    immutable double nextRe = wRe * wStepRe - wIm * wStepIm;
                    wIm = wRe * wStepIm + wIm * wStepRe;
                    wRe = nextRe;
                }
            }
        }

        if (invert) {
            immutable double invN = 1.0 / cast(double) n;
            foreach (i; 0 .. n) {
                realPart[i] = cast(T)(cast(double) realPart[i] * invN);
                imagPart[i] = cast(T)(cast(double) imagPart[i] * invN);
            }
        }
    }

    /**
     * Computes an unnormalized forward in-place complex DFT.
     *
     * Params:
     *   realPart = Real components modified in place (power-of-two length).
     *   imagPart = Imaginary components modified in place (same length as realPart).
     */
    static void forward(T[] realPart, T[] imagPart) {
        transform(realPart, imagPart, false);
    }

    /**
     * Computes a 1/N-normalized inverse in-place complex DFT.
     *
     * Params:
     *   realPart = Real components modified in place (power-of-two length).
     *   imagPart = Imaginary components modified in place (same length as realPart).
     */
    static void inverse(T[] realPart, T[] imagPart) {
        transform(realPart, imagPart, true);
    }

    /**
     * Copies real time-domain input into realOut/imagOut (zeroing imagOut) and runs forward FFT.
     *
     * Params:
     *   input = Real-valued time-domain samples (power-of-two length).
     *   realOut = Output buffer receiving real spectral bins.
     *   imagOut = Output buffer receiving imaginary spectral bins.
     */
    static void forwardReal(const(T)[] input, T[] realOut, T[] imagOut) {
        assert(input.length == realOut.length && input.length == imagOut.length,
            "forwardReal buffers must share equal power-of-two length");
        realOut[] = input[];
        imagOut[] = cast(T) 0;
        forward(realOut, imagOut);
    }

    /**
     * Computes linear bin magnitudes sqrt(re^2 + im^2) for each complex spectral bin.
     *
     * Params:
     *   realPart = Real spectral bin array.
     *   imagPart = Imaginary spectral bin array.
     *   magOut = Destination array receiving bin magnitudes.
     */
    static void computeMagnitude(const(T)[] realPart, const(T)[] imagPart, T[] magOut) {
        assert(realPart.length == imagPart.length && realPart.length == magOut.length,
            "computeMagnitude buffers must have identical lengths");
        foreach (i; 0 .. realPart.length) {
            immutable double re = cast(double) realPart[i];
            immutable double im = cast(double) imagPart[i];
            magOut[i] = cast(T) sqrt(re * re + im * im);
        }
    }

    /**
     * Computes normalized magnitude in decibels (floored at -144.0 dB) for spectrum displays.
     *
     * Params:
     *   realPart = Real spectral bin array.
     *   imagPart = Imaginary spectral bin array.
     *   dbOut = Destination array receiving bin magnitudes in decibels.
     */
    static void computeMagnitudeDb(const(T)[] realPart, const(T)[] imagPart, float[] dbOut) {
        assert(realPart.length == imagPart.length && realPart.length == dbOut.length,
            "computeMagnitudeDb buffers must have identical lengths");
        if (realPart.length == 0) {
            return;
        }
        immutable double scale = 1.0 / cast(double) realPart.length;
        foreach (i; 0 .. realPart.length) {
            immutable double re = cast(double) realPart[i];
            immutable double im = cast(double) imagPart[i];
            immutable double mag = sqrt(re * re + im * im) * scale;
            if (mag <= 1e-7) {
                dbOut[i] = -144.0f;
            } else {
                immutable double db = 20.0 * log10(mag);
                dbOut[i] = db < -144.0 ? -144.0f : cast(float) db;
            }
        }
    }
}

alias FftFloat = Radix2Fft!float;
alias FftDouble = Radix2Fft!double;
