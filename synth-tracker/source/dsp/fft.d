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
 *   External: core.stdc.math (cos, sin)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Radix2Fft(T) if (is(T == float) || is(T == double))
 *   - void forward(T[] realPart, T[] imagPart) @nogc nothrow
 *   - void inverse(T[] realPart, T[] imagPart) @nogc nothrow
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.fft;
