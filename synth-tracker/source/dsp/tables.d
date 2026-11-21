/**
 * File:         source/dsp/tables.d
 * Module:       dsp.tables
 * Phase:        Phase 1.1 — Immutable Lookup & Window Tables
 *
 * Purpose:
 *   Provides read-only compile-time/immutable sine, half-sine, and spectral window tables shared re-entrantly across all DSP modules and MetaModule instances.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow pure; zero mutable globals.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.math_rt
 *   External: std.math (CTFE table generation)
 *
 * Planned API (Types, Functions & Hooks):
 *   - immutable float[] SINE_TABLE / HALF_SINE_TABLE
 *   - immutable float[] HANN_WINDOW / HAMMING_WINDOW / BLACKMAN_WINDOW
 *   - void fillWindow(WindowKind kind, float[] dst) @nogc nothrow
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.tables;
