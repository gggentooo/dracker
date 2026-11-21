/**
 * File:         source/modules/control/pitch2ctl.d
 * Module:       modules.control.pitch2ctl
 * Phase:        Phase 4.8 (Tier 2) — Note Pitch-to-Controller Mapper
 *
 * Purpose:
 *   Maps incoming musical note pitches onto downstream parameter automation or CV keytracking.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow.
 *
 * Dependencies:
 *   Internal: graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Pitch2Ctl (typeId = "ctl.pitch2ctl", ports: event in, event out, cvControl out)
 *   - @Param firstNote, numSemitones, outMin, outMax
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.pitch2ctl;
