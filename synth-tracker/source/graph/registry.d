/**
 * File:         source/graph/registry.d
 * Module:       graph.registry
 * Phase:        Phase 2.2 — Static ModuleRegistry
 *
 * Purpose:
 *   Provides a single-line registration table binding all built-in synth, effect, and control modules via ModuleAdapter!T for runtime lookup and dynamic GUI add-module menus.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow lookup via immutable ModuleDescriptor[] table; zero global mutable state.
 *
 * Dependencies:
 *   Internal: graph.module_api, modules.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ModuleRegistry : descriptors(), findByTypeId(string typeId), createOffRT(string typeId, float sampleRate)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.registry;
