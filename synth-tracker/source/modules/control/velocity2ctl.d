/**
 * File:         source/modules/control/velocity2ctl.d
 * Module:       modules.control.velocity2ctl
 * Phase:        Phase 4.8 (Tier 2) — Note Velocity-to-Controller Mapper
 *
 * Purpose:
 *   Translates incoming note velocities into downstream parameter automation or CV modulation.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow.
 *
 * Dependencies:
 *   Internal: graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Velocity2Ctl (typeId = "ctl.velocity2ctl", ports: event in, event out, cvControl out)
 *   - @Param outMin, outMax, noteOffAction
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.velocity2ctl;
