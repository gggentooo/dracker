/**
 * File:         source/modules/effects/flanger.d
 * Module:       modules.effects.flanger
 * Phase:        Phase 4.6 (Tier 2) — Modulated Delay Flanger
 *
 * Purpose:
 *   Stereo through-zero/standard flanger driven by an internal LFO and fractional delay line.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process().
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.tables, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Flanger (typeId = "fx.flanger", ports: audioStereo in/out)
 *   - @Param dry, wet, feedback, delayMs, lfoFreqHz, lfoDepth
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.flanger;
