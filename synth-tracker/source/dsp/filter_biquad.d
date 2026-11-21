/**
 * File:         source/dsp/filter_biquad.d
 * Module:       dsp.filter_biquad
 * Phase:        Phase 1.3 — Cascaded RBJ Biquad & 1-Pole Filters
 *
 * Purpose:
 *   Implements 1-pole and 2-pole RBJ biquad filters (LPF, HPF, BPF, Notch, Allpass, Low/High Shelf, Peaking) using double-precision internal delay state for low-cutoff stability.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero initialization of x1/x2/y1/y2 state to prevent D NaN poisoning.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.math_rt
 *   External: core.stdc.math (sin, cos)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum BiquadMode : ubyte { lowpass, highpass, bandpass, notch, allpass, peaking, lowShelf, highShelf }
 *   - struct BiquadFilter : configure(mode, freqHz, q, gainDb, sampleRate), processSample(float), processBlock(float[]), reset()
 *   - struct CascadedBiquad(size_t Stages)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.filter_biquad;
