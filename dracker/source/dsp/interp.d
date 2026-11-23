/**
 * File:         source/dsp/interp.d
 * Module:       dsp.interp
 * Phase:        Phase 1.1 — Sample & Wavetable Interpolation Kernels
 *
 * Purpose:
 *   Provides zero-order hold, linear, cubic Hermite, and 4-point Catmull-Rom spline interpolation kernels for resamplers, delay lines, and wave readers.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow pure @safe; NaN-free bounded index clamping and modulo wrapping.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: std.math (floor, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - float interpNearest(float a, float b, float frac) @nogc nothrow pure @safe
 *   - float interpLinear(float a, float b, float frac) @nogc nothrow pure @safe
 *   - float interpHermite(float ym1, float y0, float y1, float y2, float frac) @nogc nothrow pure @safe
 *   - float interpCatmullRom(float ym1, float y0, float y1, float y2, float frac) @nogc nothrow pure @safe
 *   - float interpHermiteTension(float ym1, float y0, float y1, float y2, float frac, float tension, float bias) @nogc nothrow pure @safe
 *   - float sampleBufferClamped(const(float)[] buf, double pos, bool useCatmullRom = true) @nogc nothrow pure @safe
 *   - float sampleBufferWrapped(const(float)[] buf, double pos, bool useCatmullRom = true) @nogc nothrow pure @safe
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.interp;

import std.math : floor, isFinite;

/**
 * Evaluates nearest-neighbor (zero-order hold) interpolation between two samples.
 *
 * Params:
 *   a = Sample at fractional offset 0.0f.
 *   b = Sample at fractional offset 1.0f.
 *   frac = Fractional offset in [0.0f, 1.0f].
 *
 * Returns:
 *   a when frac < 0.5f, otherwise b.
 */
float interpNearest(float a, float b, float frac) @nogc nothrow pure @safe {
    return frac < 0.5f ? a : b;
}

/**
 * Evaluates linear interpolation between two adjacent samples.
 *
 * Params:
 *   a = Sample at fractional offset 0.0f.
 *   b = Sample at fractional offset 1.0f.
 *   frac = Fractional offset in [0.0f, 1.0f].
 *
 * Returns:
 *   Linearly interpolated sample value.
 */
float interpLinear(float a, float b, float frac) @nogc nothrow pure @safe {
    return a + frac * (b - a);
}

/**
 * Evaluates 4-point 3rd-order Hermite spline interpolation across [y0, y1].
 *
 * Params:
 *   ym1 = Sample at index -1.
 *   y0 = Sample at index 0.
 *   y1 = Sample at index +1.
 *   y2 = Sample at index +2.
 *   frac = Fractional offset between y0 and y1 in [0.0f, 1.0f].
 *
 * Returns:
 *   Interpolated sample passing exactly through y0 at frac = 0 and y1 at frac = 1.
 */
float interpHermite(float ym1, float y0, float y1, float y2, float frac) @nogc nothrow pure @safe {
    immutable float c0 = y0;
    immutable float c1 = 0.5f * (y1 - ym1);
    immutable float c2 = ym1 - 2.5f * y0 + 2.0f * y1 - 0.5f * y2;
    immutable float c3 = 0.5f * (y2 - ym1) + 1.5f * (y0 - y1);
    return ((c3 * frac + c2) * frac + c1) * frac + c0;
}

/**
 * Evaluates 4-point Catmull-Rom cubic spline interpolation across [y0, y1].
 *
 * Params:
 *   ym1 = Sample at index -1.
 *   y0 = Sample at index 0.
 *   y1 = Sample at index +1.
 *   y2 = Sample at index +2.
 *   frac = Fractional offset between y0 and y1 in [0.0f, 1.0f].
 *
 * Returns:
 *   Interpolated sample value.
 */
float interpCatmullRom(float ym1, float y0, float y1, float y2, float frac) @nogc nothrow pure @safe {
    immutable float f2 = frac * frac;
    immutable float f3 = f2 * frac;
    return 0.5f * (
        (2.0f * y0)
        + (-ym1 + y1) * frac
        + (2.0f * ym1 - 5.0f * y0 + 4.0f * y1 - y2) * f2
        + (-ym1 + 3.0f * y0 - 3.0f * y1 + y2) * f3
    );
}

/**
 * Evaluates 4-point Kochanek-Bartels Hermite interpolation with tunable tension and bias.
 *
 * Params:
 *   ym1 = Sample at index -1.
 *   y0 = Sample at index 0.
 *   y1 = Sample at index +1.
 *   y2 = Sample at index +2.
 *   frac = Fractional offset between y0 and y1 in [0.0f, 1.0f].
 *   tension = Tangent tightness in [-1.0f, 1.0f] where 0.0f matches Catmull-Rom.
 *   bias = Tangent directional skew in [-1.0f, 1.0f] where 0.0f is symmetric.
 *
 * Returns:
 *   Interpolated sample value.
 */
float interpHermiteTension(
    float ym1,
    float y0,
    float y1,
    float y2,
    float frac,
    float tension,
    float bias
) @nogc nothrow pure @safe {
    immutable float mu2 = frac * frac;
    immutable float mu3 = mu2 * frac;
    immutable float halfScale = 0.5f * (1.0f - tension);
    immutable float m0 = (y0 - ym1) * (1.0f + bias) * halfScale + (y1 - y0) * (1.0f - bias) * halfScale;
    immutable float m1 = (y1 - y0) * (1.0f + bias) * halfScale + (y2 - y1) * (1.0f - bias) * halfScale;
    immutable float a0 = 2.0f * mu3 - 3.0f * mu2 + 1.0f;
    immutable float a1 = mu3 - 2.0f * mu2 + frac;
    immutable float a2 = mu3 - mu2;
    immutable float a3 = -2.0f * mu3 + 3.0f * mu2;
    return a0 * y0 + a1 * m0 + a2 * m1 + a3 * y1;
}

/**
 * Reads an interpolated sample from a non-looping slice with endpoint clamping.
 *
 * Params:
 *   buf = Source sample buffer.
 *   pos = Fractional sample position; clamped to [0, buf.length - 1].
 *   useCatmullRom = Selects 4-point Catmull-Rom when true, or linear interpolation when false.
 *
 * Returns:
 *   Interpolated sample, or 0.0f when buf is empty or pos is non-finite.
 */
float sampleBufferClamped(const(float)[] buf, double pos, bool useCatmullRom = true) @nogc nothrow pure @safe {
    if (buf.length == 0 || !isFinite(pos)) {
        return 0.0f;
    }
    if (buf.length == 1 || pos <= 0.0) {
        return buf[0];
    }
    immutable size_t last = buf.length - 1;
    if (pos >= cast(double) last) {
        return buf[last];
    }

    immutable size_t i0 = cast(size_t) pos;
    immutable float frac = cast(float)(pos - cast(double) i0);
    if (!useCatmullRom) {
        return interpLinear(buf[i0], buf[i0 + 1], frac);
    }

    immutable float ym1 = i0 > 0 ? buf[i0 - 1] : buf[0];
    immutable float y0 = buf[i0];
    immutable float y1 = buf[i0 + 1];
    immutable float y2 = (i0 + 2 <= last) ? buf[i0 + 2] : buf[last];
    return interpCatmullRom(ym1, y0, y1, y2, frac);
}

/**
 * Reads an interpolated sample from a periodic/looping buffer with wrap-around indexing.
 *
 * Params:
 *   buf = Source periodic waveform or loop slice.
 *   pos = Arbitrary finite sample position (including negative or >= buf.length).
 *   useCatmullRom = Selects 4-point Catmull-Rom when true, or linear interpolation when false.
 *
 * Returns:
 *   Interpolated wrapped sample, or 0.0f when buf is empty or pos is non-finite.
 */
float sampleBufferWrapped(const(float)[] buf, double pos, bool useCatmullRom = true) @nogc nothrow pure @safe {
    if (buf.length == 0 || !isFinite(pos)) {
        return 0.0f;
    }
    if (buf.length == 1) {
        return buf[0];
    }

    immutable double len = cast(double) buf.length;
    double wrapped = pos - floor(pos / len) * len;
    if (wrapped < 0.0 || wrapped >= len) {
        wrapped = 0.0;
    }

    size_t i0 = cast(size_t) wrapped;
    if (i0 >= buf.length) {
        i0 = 0;
    }
    immutable float frac = cast(float)(wrapped - cast(double) i0);
    immutable size_t i1 = (i0 + 1) % buf.length;
    if (!useCatmullRom) {
        return interpLinear(buf[i0], buf[i1], frac);
    }

    immutable size_t im1 = (i0 + buf.length - 1) % buf.length;
    immutable size_t i2 = (i0 + 2) % buf.length;
    return interpCatmullRom(buf[im1], buf[i0], buf[i1], buf[i2], frac);
}
