/**
 * File:         source/modules/synths/kicker.d
 * Module:       modules.synths.kicker
 * Phase:        Phase 4.3 (Tier 1) — Pitch-Swept Percussion Synthesizer
 *
 * Purpose:
 *   Punchy percussive drum synthesizer generating sine/triangle/square pitch sweeps with click transient and exponential decay.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init state.
 *
 * Dependencies:
 *   Internal: dsp.oscillator, dsp.envelope, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Kicker (typeId = "synth.kicker", ports: event in, audioStereo out)
 *   - @Param waveform, pitchStartHz, pitchEndHz, sweepTimeMs, decayMs, clickDrive
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.kicker;
