/**
 * File:         source/modules/control/glide.d
 * Module:       modules.control.glide
 * Phase:        Phase 4.8 (Tier 2) — Polyphonic/Monophonic Pitch Portamento
 *
 * Purpose:
 *   Smooths pitch transitions between consecutive note events and emits sample-accurate setPitch ModEvents downstream.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow.
 *
 * Dependencies:
 *   Internal: dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Glide (typeId = "ctl.glide", ports: event in, event out)
 *   - @Param responseRate, polyphonic, resetOnFirstNote
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.glide;
