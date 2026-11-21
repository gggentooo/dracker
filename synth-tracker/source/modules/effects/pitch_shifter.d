/**
 * File:         source/modules/effects/pitch_shifter.d
 * Module:       modules.effects.pitch_shifter
 * Phase:        Phase 4.7 (Tier 2) — Granular / Overlap-Add Pitch Shifter
 *
 * Purpose:
 *   Time-domain dual-windowed overlap-add pitch shifter with adjustable grain size and feedback.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); grain ring buffer pre-allocated via OwnedBuffer!float.
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.tables, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct PitchShifter (typeId = "fx.pitch_shifter", ports: audioStereo in/out)
 *   - @Param pitchSemitones, fineCents, grainMs, feedback, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.pitch_shifter;
