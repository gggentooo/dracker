/**
 * File:         source/modules/effects/dc_blocker.d
 * Module:       modules.effects.dc_blocker
 * Phase:        Phase 2.5 / 4.1 (Tier 1) — 1-Pole DC Blocking High-Pass Filter
 *
 * Purpose:
 *   Removes DC bias with a configurable logarithmic cutoff frequency and decay-tail silence detection for downstream graph skipping.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init on prevIn/prevOut; named onParamChanged!field dispatch.
 *
 * Dependencies:
 *   Internal: graph.module_api, graph.port, graph.context
 *   External: core.stdc.math (expf)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DcBlocker (typeId = "fx.dc_blocker", ports: audioStereo in/out)
 *   - @Param cutoffHz (5..80 Hz, logarithmic)
 *   - Hooks: prepare, reset, onParamChanged!"cutoffHz", process
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.dc_blocker;
