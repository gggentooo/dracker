/**
 * File:         source/modules/control/multictl.d
 * Module:       modules.control.multictl
 * Phase:        Phase 4.2 (Tier 1) — Fan-Out Controller Curve Mapper
 *
 * Purpose:
 *   Maps a master macro value across multiple target module parameters with per-target min/max/curve mappings.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; emits target ModEvent.setParam commands.
 *
 * Dependencies:
 *   Internal: dsp.interp, foundation.memory, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct MultiCtl (typeId = "ctl.multictl", ports: event in, event out, cvControl in)
 *   - @Param value, gain, quantization
 *   - Hooks: serializeExtra, deserializeExtra, swapAsset (mapping table + curve)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.multictl;
