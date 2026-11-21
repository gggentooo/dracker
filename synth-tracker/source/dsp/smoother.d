/**
 * File:         source/dsp/smoother.d
 * Module:       dsp.smoother
 * Phase:        Phase 1.4 — Audio-Rate Parameter Smoothers
 *
 * Purpose:
 *   Provides linear and exponential one-pole parameter smoothers supporting smooth live UI/MIDI/CV transitions alongside instant snap during preset/project load.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit non-NaN default init (= 0.0f).
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: core.stdc.math (expf)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ParamSmoother : prepare(sampleRate, timeMs), setTarget(float val, bool instant = false), next() @nogc nothrow, isSettled() const
 *   - struct LinearRamp : fixed-duration linear parameter interpolator
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.smoother;
