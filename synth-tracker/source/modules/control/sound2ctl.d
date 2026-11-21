/**
 * File:         source/modules/control/sound2ctl.d
 * Module:       modules.control.sound2ctl
 * Phase:        Phase 4.8 (Tier 2) — Audio Envelope Follower to CV / Controller
 *
 * Purpose:
 *   Tracks incoming audio amplitude with configurable attack/release smoothing and drives downstream CV or parameter targets.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow.
 *
 * Dependencies:
 *   Internal: dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Sound2Ctl (typeId = "ctl.sound2ctl", ports: audioStereo in, cvControl out, event out)
 *   - @Param gain, smoothMs, outMin, outMax, sampleRateHz
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.sound2ctl;
