/**
 * File:         source/modules/effects/distortion.d
 * Module:       modules.effects.distortion
 * Phase:        Phase 4.1 (Tier 1) — Distortion, Foldback & Bitcrusher
 *
 * Purpose:
 *   Combines soft/hard clipping, wavefold saturation, bit-depth quantization, and sample-rate decimation.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init sample-and-hold state.
 *
 * Dependencies:
 *   Internal: dsp.smoother, graph.*
 *   External: core.stdc.math (tanhf)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Distortion (typeId = "fx.distortion", ports: audioStereo in/out)
 *   - @Param mode, drive, bitDepth, sampleRateDiv, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.distortion;
