/**
 * File:         source/dsp/interp.d
 * Module:       dsp.interp
 * Phase:        Phase 1.1 — Sample & Wavetable Interpolation Kernels
 *
 * Purpose:
 *   Provides zero-order hold, linear, cubic Hermite, and 4-point Catmull-Rom spline interpolation kernels for resamplers, delay lines, and wave readers.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow pure; NaN-free bounded index wrapping.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - float interpLinear(float a, float b, float frac) @nogc nothrow pure
 *   - float interpHermite(float ym1, float y0, float y1, float y2, float frac) @nogc nothrow pure
 *   - float interpCatmullRom(float ym1, float y0, float y1, float y2, float frac) @nogc nothrow pure
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.interp;
