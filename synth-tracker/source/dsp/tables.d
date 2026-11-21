/**
 * File:         source/dsp/tables.d
 * Module:       dsp.tables
 * Phase:        Phase 1.1 — Immutable Lookup & Window Tables
 *
 * Purpose:
 *   Provides read-only compile-time/immutable sine, half-sine, and spectral window tables shared re-entrantly across all DSP modules and MetaModule instances.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow pure @safe; zero mutable globals and explicit finite guards on all lookups.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.math_rt
 *   External: std.math (cos, floor, isFinite, sin)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum WindowKind : ubyte { rectangular, hann, hamming, blackman }
 *   - immutable float[4097] SINE_TABLE
 *   - immutable float[2049] HALF_SINE_TABLE
 *   - immutable float[1024] HANN_WINDOW / HAMMING_WINDOW / BLACKMAN_WINDOW
 *   - float lookupSine(float phase01) @nogc nothrow pure @safe
 *   - float lookupCosine(float phase01) @nogc nothrow pure @safe
 *   - float lookupHalfSine(float pos01) @nogc nothrow pure @safe
 *   - void fillWindow(WindowKind kind, float[] dst, bool periodic = false) @nogc nothrow pure @safe
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.tables;

import std.math : cos, floor, isFinite, sin;

import foundation.math_rt : clampSample;

enum double PI_D = 3.14159265358979323846;
enum double TWO_PI_D = 6.28318530717958647692;
enum float PI_F = cast(float) PI_D;
enum float TWO_PI_F = cast(float) TWO_PI_D;

enum size_t SINE_TABLE_SIZE = 4096;
enum size_t HALF_SINE_TABLE_SIZE = 2048;
enum size_t WINDOW_TABLE_SIZE = 1024;

/**
 * Spectral analysis and overlap-add windowing kernel shapes.
 */
enum WindowKind : ubyte {
    rectangular = 0,
    hann = 1,
    hamming = 2,
    blackman = 3
}

private float[SINE_TABLE_SIZE + 1] generateSineTable() @nogc nothrow pure @safe {
    float[SINE_TABLE_SIZE + 1] table = 0.0f;
    foreach (i; 0 .. SINE_TABLE_SIZE) {
        table[i] = cast(float) sin(TWO_PI_D * cast(double) i / cast(double) SINE_TABLE_SIZE);
    }
    table[SINE_TABLE_SIZE] = 0.0f;
    return table;
}

private float[HALF_SINE_TABLE_SIZE + 1] generateHalfSineTable() @nogc nothrow pure @safe {
    float[HALF_SINE_TABLE_SIZE + 1] table = 0.0f;
    foreach (i; 0 .. HALF_SINE_TABLE_SIZE) {
        table[i] = cast(float) sin(PI_D * cast(double) i / cast(double) HALF_SINE_TABLE_SIZE);
    }
    table[HALF_SINE_TABLE_SIZE / 2] = 1.0f;
    table[HALF_SINE_TABLE_SIZE] = 0.0f;
    return table;
}

private float[WINDOW_TABLE_SIZE] generateWindowTable(WindowKind kind) @nogc nothrow pure @safe {
    float[WINDOW_TABLE_SIZE] table = 0.0f;
    fillWindow(kind, table[], false);
    return table;
}

static immutable float[SINE_TABLE_SIZE + 1] SINE_TABLE = generateSineTable();
static immutable float[HALF_SINE_TABLE_SIZE + 1] HALF_SINE_TABLE = generateHalfSineTable();
static immutable float[WINDOW_TABLE_SIZE] HANN_WINDOW = generateWindowTable(WindowKind.hann);
static immutable float[WINDOW_TABLE_SIZE] HAMMING_WINDOW = generateWindowTable(WindowKind.hamming);
static immutable float[WINDOW_TABLE_SIZE] BLACKMAN_WINDOW = generateWindowTable(WindowKind.blackman);

/**
 * Evaluates a unit-amplitude sine wave at normalized phase [0, 1) via linear table interpolation.
 *
 * Arbitrary finite phases (including negative values) wrap smoothly modulo 1.0; non-finite
 * inputs return 0.0f.
 *
 * Params:
 *   phase01 = Normalized oscillator phase in cycles (1.0 == 2 * pi radians).
 *
 * Returns:
 *   Interpolated sine sample in [-1.0f, 1.0f].
 */
float lookupSine(float phase01) @nogc nothrow pure @safe {
    if (!isFinite(phase01)) {
        return 0.0f;
    }
    double wrapped = cast(double) phase01 - floor(cast(double) phase01);
    if (wrapped < 0.0 || wrapped >= 1.0) {
        wrapped = 0.0;
    }
    immutable double scaled = wrapped * cast(double) SINE_TABLE_SIZE;
    size_t idx = cast(size_t) scaled;
    if (idx >= SINE_TABLE_SIZE) {
        idx = SINE_TABLE_SIZE - 1;
    }
    immutable float frac = cast(float)(scaled - cast(double) idx);
    immutable float s0 = SINE_TABLE[idx];
    immutable float s1 = SINE_TABLE[idx + 1];
    return s0 + frac * (s1 - s0);
}

/**
 * Evaluates a unit-amplitude cosine wave at normalized phase [0, 1) via quarter-cycle shift.
 *
 * Params:
 *   phase01 = Normalized oscillator phase in cycles.
 *
 * Returns:
 *   Interpolated cosine sample in [-1.0f, 1.0f], or 0.0f for non-finite inputs.
 */
float lookupCosine(float phase01) @nogc nothrow pure @safe {
    if (!isFinite(phase01)) {
        return 0.0f;
    }
    return lookupSine(phase01 + 0.25f);
}

/**
 * Evaluates the positive half-sine arch sin(pi * pos01) clamped to [0.0f, 1.0f].
 *
 * Params:
 *   pos01 = Normalized arch position where 0.0 and 1.0 evaluate to 0.0f and 0.5 evaluates to 1.0f.
 *
 * Returns:
 *   Interpolated half-sine value in [0.0f, 1.0f].
 */
float lookupHalfSine(float pos01) @nogc nothrow pure @safe {
    if (!isFinite(pos01)) {
        return 0.0f;
    }
    immutable float clamped = clampSample(pos01, 0.0f, 1.0f);
    immutable double scaled = cast(double) clamped * cast(double) HALF_SINE_TABLE_SIZE;
    size_t idx = cast(size_t) scaled;
    if (idx >= HALF_SINE_TABLE_SIZE) {
        return HALF_SINE_TABLE[HALF_SINE_TABLE_SIZE];
    }
    immutable float frac = cast(float)(scaled - cast(double) idx);
    immutable float h0 = HALF_SINE_TABLE[idx];
    immutable float h1 = HALF_SINE_TABLE[idx + 1];
    return h0 + frac * (h1 - h0);
}

/**
 * Populates dst with a symmetric or periodic (COLA-aligned) spectral window curve.
 *
 * Params:
 *   kind = Window function shape.
 *   dst = Destination float slice populated in place.
 *   periodic = When true, divides by dst.length (STFT COLA); when false, divides by dst.length - 1.
 */
void fillWindow(WindowKind kind, float[] dst, bool periodic = false) @nogc nothrow pure @safe {
    if (dst.length == 0) {
        return;
    }
    if (dst.length == 1) {
        dst[0] = 1.0f;
        return;
    }

    final switch (kind) {
        case WindowKind.rectangular:
            dst[] = 1.0f;
            return;
        case WindowKind.hann:
        case WindowKind.hamming:
        case WindowKind.blackman:
            break;
    }

    immutable double denom = periodic ? cast(double) dst.length : cast(double)(dst.length - 1);
    foreach (i; 0 .. dst.length) {
        immutable double arg = TWO_PI_D * cast(double) i / denom;
        double w = 0.0;
        if (kind == WindowKind.hann) {
            w = 0.5 * (1.0 - cos(arg));
        } else if (kind == WindowKind.hamming) {
            w = 0.54 - 0.46 * cos(arg);
        } else {
            w = 0.42 - 0.5 * cos(arg) + 0.08 * cos(2.0 * arg);
        }
        dst[i] = w < 0.0 ? 0.0f : cast(float) w;
    }
}
