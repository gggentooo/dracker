/**
 * File:         source/modules/effects/compressor.d
 * Module:       modules.effects.compressor
 * Phase:        Phase 4.1 (Tier 1) — Sidechain Peak/RMS Compressor
 *
 * Purpose:
 *   Dynamic range compressor with selectable peak/RMS detector, lookahead/knee shaping, and dedicated sidechainStereo input port.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero allocations in envelope detector.
 *
 * Dependencies:
 *   Internal: dsp.smoother, foundation.math_rt, graph.*
 *   External: core.stdc.math (logf, expf)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Compressor (typeId = "fx.compressor", ports: audioStereo in, sidechainStereo scIn, audioStereo out)
 *   - @Param thresholdDb, ratio, attackMs, releaseMs, makeupDb, mode
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.compressor;
