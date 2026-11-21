/**
 * File:         source/modules/effects/eq.d
 * Module:       modules.effects.eq
 * Phase:        Phase 4.6 (Tier 2) — 3-Band Equalizer
 *
 * Purpose:
 *   Low-shelf, peaking-mid, and high-shelf 3-band EQ built on double-state RBJ biquads.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow.
 *
 * Dependencies:
 *   Internal: dsp.filter_biquad, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Eq3Band (typeId = "fx.eq3", ports: audioStereo in/out)
 *   - @Param lowGainDb, midGainDb, highGainDb, lowFreqHz, midFreqHz, midQ, highFreqHz
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.eq;
