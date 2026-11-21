/**
 * File:         tests/unit/foundation_test.d
 * Module:       tests.unit.foundation_test
 * Phase:        Phase 0.2-0.4 — Foundation Unit & Multi-Threaded Ring Tests
 *
 * Purpose:
 *   Validates OwnedBuffer!T overflow/alignment/move/non-indirection invariants, SpscRing/MpscRing 10M-message concurrency integrity, and ScopedNoDenormals subnormal flushing.
 *
 * Real-Time & Safety Contract:
 *   Test module running under dub test --config=headless.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, foundation.concurrency, foundation.math_rt
 *   External: core.thread
 *
 * Planned API (Types, Functions & Hooks):
 *   - unittest: OwnedBuffer!T tryAllocate overflow/OOM, move opAssign, release
 *   - unittest: SpscRing!T and MpscRing!T 10M-message stress test
 *   - unittest: ScopedNoDenormals flushes subnormal float values to 0.0f
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.foundation_test;
