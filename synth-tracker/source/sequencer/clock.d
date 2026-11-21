/**
 * File:         source/sequencer/clock.d
 * Module:       sequencer.clock
 * Phase:        Phase 5.3 — Drift-Free 64-Bit Rational Sample/Tick/Line Clock
 *
 * Purpose:
 *   Advances song time across arbitrary sample rates, dynamic BPM, and dynamic TPL (ticks per line) without floating-point accumulation drift, producing exact sub-slice tick offsets.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; 64-bit integer/rational accumulator with zero allocations.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct RationalClock : configure(sampleRate, bpm, ticksPerLine), advanceSlice(uint frames, out TickSpan[] ticks)
 *   - void seekToLine(long line) @nogc nothrow
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.clock;
