/**
 * File:         tests/golden/golden_suite.d
 * Module:       tests.golden.golden_suite
 * Phase:        Phase 4.5 / 5 — Built-In Module & Sequencer Golden WAV Suite
 *
 * Purpose:
 *   Executes automated golden-WAV regression tests, extreme-parameter NaN sweeps, silence-in/silence-out decay checks, Feedback invariance, and MetaModule nesting tests.
 *
 * Real-Time & Safety Contract:
 *   Test module combining tests.audio_harness and tests.rt_malloc_trap.
 *
 * Dependencies:
 *   Internal: tests.audio_harness, tests.rt_malloc_trap, modules.*, sequencer.engine
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - unittest: every built-in module passes @nogc + rt_malloc_trap + zero-NaN sweep
 *   - unittest: sample-accurate NoteOn offset and sub-line delay (0x40..0x5F)
 *   - unittest: Feedback and MetaModule determinism across 64 vs 512 host block sizes
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.golden.golden_suite;
