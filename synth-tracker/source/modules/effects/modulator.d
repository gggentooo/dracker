/**
 * File:         source/modules/effects/modulator.d
 * Module:       modules.effects.modulator
 * Phase:        Phase 4.6 (Tier 2) — Ring, Amplitude & Phase Modulator
 *
 * Purpose:
 *   Combines primary carrier and secondary modulator stereo/CV inputs for ring modulation, amplitude modulation, and phase modulation.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow.
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Modulator (typeId = "fx.modulator", ports: audioStereo carrierIn, audioStereo modIn, audioStereo out)
 *   - @Param modType (AM/Ring/PM), mix, maxDelayMs
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.modulator;
