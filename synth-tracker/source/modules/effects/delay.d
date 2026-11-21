/**
 * File:         source/modules/effects/delay.d
 * Module:       modules.effects.delay
 * Phase:        Phase 4.1 (Tier 1) — Tempo-Synced Stereo Delay
 *
 * Purpose:
 *   Stereo delay supporting millisecond, Hz, and BPM/line-synced delay times with dry/wet mix and stereo offset.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); delay buffer pre-allocated via OwnedBuffer!float.
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Delay (typeId = "fx.delay", ports: audioStereo in/out)
 *   - @Param dry, wet, delayL, delayR, unitMode, inversePan
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.delay;
