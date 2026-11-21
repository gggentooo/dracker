/**
 * File:         tests/fuzz/project_format_fuzz.d
 * Module:       tests.fuzz.project_format_fuzz
 * Phase:        Phase 6.4 — Persistence & Importer Mutation Fuzzer
 *
 * Purpose:
 *   Feeds 100,000+ mutated, truncated, and adversarial chunk payloads into project_format.d and importers (.mid/.xm/.sunvox) asserting zero crashes, hangs, or out-of-bounds reads.
 *
 * Real-Time & Safety Contract:
 *   Test module executing deterministic seeded PRNG mutations under CI/nightly.
 *
 * Dependencies:
 *   Internal: io.binary_stream, io.project_format, io.importers.*
 *   External: std.random
 *
 * Planned API (Types, Functions & Hooks):
 *   - void runProjectFormatFuzz(ulong seed, size_t iterations = 100_000)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.fuzz.project_format_fuzz;
