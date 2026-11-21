/**
 * File:         source/dsp/delay_line.d
 * Module:       dsp.delay_line
 * Phase:        Phase 1.4 — Fractional Power-of-Two Delay Line
 *
 * Purpose:
 *   Implements an OwnedBuffer-backed power-of-two circular delay line with bitmask indexing and Catmull-Rom/linear fractional taps.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow during read/write/tap; buffer allocated off-RT via OwnedBuffer!float.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, dsp.interp
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DelayLine : tryInit(maxSamples), write(float), readLinear(float delaySamples), readCatmullRom(float delaySamples), clear()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.delay_line;
