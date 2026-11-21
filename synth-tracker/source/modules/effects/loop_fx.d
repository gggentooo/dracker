/**
 * File:         source/modules/effects/loop_fx.d
 * Module:       modules.effects.loop_fx
 * Phase:        Phase 4.7 (Tier 2) — Tempo-Synced Stutter & Beat Repeater
 *
 * Purpose:
 *   Captures incoming audio slices and repeats tempo-synced sub-divisions with envelope crossfades to prevent clicks.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); pre-allocated loop buffer via OwnedBuffer!float.
 *
 * Dependencies:
 *   Internal: dsp.smoother, foundation.memory, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct LoopFx (typeId = "fx.loop", ports: audioStereo in/out, event in)
 *   - @Param repeats, lengthTicks, mode, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.loop_fx;
