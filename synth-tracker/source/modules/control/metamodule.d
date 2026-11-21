/**
 * File:         source/modules/control/metamodule.d
 * Module:       modules.control.metamodule
 * Phase:        Phase 5.5 — Re-Entrant Nested Child Engine Container
 *
 * Purpose:
 *   Embeds a complete child sequencer.engine.Engine instance synchronized to parent transport/BPM/TPL with macro parameter mapping and recursion-depth guards.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on RT process(); zero global mutable state ensures safe arbitrary nesting; child patch compiled off-RT and swapped via SwapModuleAsset.
 *
 * Dependencies:
 *   Internal: sequencer.engine, dsp.resampler, foundation.memory, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct MetaModule (typeId = "ctl.metamodule", ports: audioStereo in/out, event in)
 *   - @Param bpmSync, playPatterns, inputModule, macro1..macro8
 *   - Hooks: serializeExtra, deserializeExtra, swapAsset (child Engine/GraphPlan)
 *   - enum uint MAX_METAMODULE_DEPTH = 16
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.metamodule;
