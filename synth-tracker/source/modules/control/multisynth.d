/**
 * File:         source/modules/control/multisynth.d
 * Module:       modules.control.multisynth
 * Phase:        Phase 4.2 (Tier 1) — Note, Velocity & Pitch Router
 *
 * Purpose:
 *   Transforms and fans out incoming note/pitch/velocity ModEvents to multiple downstream modules using editable velocity/pitch curves and transposition.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; emits transformed ModEvents into ProcessContext.eventOut.
 *
 * Dependencies:
 *   Internal: dsp.interp, foundation.memory, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct MultiSynth (typeId = "ctl.multisynth", ports: event in, event out)
 *   - @Param transpose, finetune, randomPitch, velocityScale, curveMode
 *   - Hooks: serializeExtra, deserializeExtra, swapAsset (transfer curves)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.multisynth;
