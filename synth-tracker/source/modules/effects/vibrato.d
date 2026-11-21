/**
 * File:         source/modules/effects/vibrato.d
 * Module:       modules.effects.vibrato
 * Phase:        Phase 4.6 (Tier 2) — Pitch Vibrato Modulator
 *
 * Purpose:
 *   Audio pitch-modulation effect using a continuously modulated Catmull-Rom delay line.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process().
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.tables, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Vibrato (typeId = "fx.vibrato", ports: audioStereo in/out)
 *   - @Param freqHz, depth, stereoPhase, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.vibrato;
