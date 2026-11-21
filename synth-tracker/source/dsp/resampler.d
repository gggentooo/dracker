/**
 * File:         source/dsp/resampler.d
 * Module:       dsp.resampler
 * Phase:        Phase 1.1 — Fractional Streaming Resampler
 *
 * Purpose:
 *   Provides stateful fractional sample-rate conversion used by Sampler, MetaModule rate matching, and dual-device drift-compensated CoreAudio input.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; all FP state explicitly zero-initialized (= 0.0f / 0.0).
 *
 * Dependencies:
 *   Internal: foundation.types, dsp.interp
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct FractionalResampler : step(ratio), processBlock(...), reset()
 *   - enum ResampleQuality : ubyte { nearest, linear, catmullRom }
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.resampler;
