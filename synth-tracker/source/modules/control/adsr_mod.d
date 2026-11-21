/**
 * File:         source/modules/control/adsr_mod.d
 * Module:       modules.control.adsr_mod
 * Phase:        Phase 4.2 (Tier 1) — Triggerable ADSR Control & Audio Envelope
 *
 * Purpose:
 *   Responds to NoteOn/NoteOff events and outputs smooth audio-rate CV modulation and/or controller automation.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow.
 *
 * Dependencies:
 *   Internal: dsp.envelope, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct AdsrMod (typeId = "ctl.adsr", ports: event in, cvControl out, audioStereo out)
 *   - @Param attackMs, decayMs, sustain, releaseMs, stateMode
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.adsr_mod;
