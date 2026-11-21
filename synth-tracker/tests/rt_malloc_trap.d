/**
 * File:         tests/rt_malloc_trap.d
 * Module:       tests.rt_malloc_trap
 * Phase:        Phase 0.5 — Thread-Local RT Allocation Trap
 *
 * Purpose:
 *   Installs a thread-local allocation guard around Engine.renderOffline(), AudioGraph.render(), and module process() tests to catch any accidental malloc/calloc/realloc/free or GC entry at runtime.
 *
 * Real-Time & Safety Contract:
 *   Diagnostic verification utility for CI headless tests.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: core.stdc.stdlib, core.memory (GC.stats / hook)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ScopedRtMallocTrap : fails assertion if any heap allocation or GC collection occurs on the guarded thread
 *   - void verifyZeroRtAllocations(scope void delegate() rtStep)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.rt_malloc_trap;
