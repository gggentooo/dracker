/**
 * File:         source/foundation/math_rt.d
 * Module:       foundation.math_rt
 * Phase:        Phase 0.4 — Cross-Arch Denormal Suppression & RT Math Utilities
 *
 * Purpose:
 *   Implements RAII CPU FTZ/DAZ subnormal suppression across Apple Silicon (ARM64) and Intel (x86_64), immutable pitch-to-Hz tables, and fast RT math conversions.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; uses LDC2 ldc.llvmasm.__asm (ARM64 fpcr bit 24 FZ / x86_64 MXCSR FTZ+DAZ) with caller state save/restore; zero global --ffast-math.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: ldc.llvmasm (__asm), core.stdc.math (expf, logf, powf, sinf, cosf)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ScopedNoDenormals : RAII guard enabling FTZ/DAZ on entry and restoring caller FPCR/MXCSR on exit
 *   - immutable float[128 * 64] PITCH_TO_HZ_TABLE : sub-semitone pitch lookup table
 *   - float midiNoteToHz(float midiNote) @nogc nothrow pure
 *   - float dbToLinear(float db) @nogc nothrow pure / float linearToDb(float amp) @nogc nothrow pure
 *   - float clampSample(float x, float lo, float hi) @nogc nothrow pure
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module foundation.math_rt;
