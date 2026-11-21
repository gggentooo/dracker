/**
 * File:         source/modules/effects/reverb.d
 * Module:       modules.effects.reverb
 * Phase:        Phase 4.1 (Tier 1) — Algorithmic FDN / Schroeder-Moorer Reverb
 *
 * Purpose:
 *   Dense stereo algorithmic reverberator with pre-delay, dampened feedback delay network, freeze mode, and subnormal/decay-tail guards.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); relies on ScopedNoDenormals + pre-allocated delay lines.
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.filter_biquad, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Reverb (typeId = "fx.reverb", ports: audioStereo in/out)
 *   - @Param dry, wet, roomSize, dampHz, stereoWidth, preDelayMs, freeze
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.reverb;
