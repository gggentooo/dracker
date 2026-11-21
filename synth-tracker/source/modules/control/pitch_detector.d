/**
 * File:         source/modules/control/pitch_detector.d
 * Module:       modules.control.pitch_detector
 * Phase:        Phase 4.8 (Tier 2) — Real-Time Audio Pitch Tracker
 *
 * Purpose:
 *   Estimates monophonic fundamental frequency via autocorrelation/zero-crossing detection and emits NoteOn/Pitch/NoteOff ModEvents.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); analysis window buffer pre-allocated via OwnedBuffer!float.
 *
 * Dependencies:
 *   Internal: dsp.tables, foundation.memory, foundation.math_rt, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct PitchDetector (typeId = "ctl.pitch_detector", ports: audioStereo in, event out)
 *   - @Param algorithm, threshold, minFreqHz, maxFreqHz, hysteresis
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.pitch_detector;
