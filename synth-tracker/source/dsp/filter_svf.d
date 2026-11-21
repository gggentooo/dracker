/**
 * File:         source/dsp/filter_svf.d
 * Module:       dsp.filter_svf
 * Phase:        Phase 1.3 — Cytomic TPT Zero-Delay-Feedback SVF
 *
 * Purpose:
 *   Implements Andy Simper's Cytomic trapezoidal TPT state-variable filter delivering audio-rate modulation stability without blowups in AnalogGen and Filter modules.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init on ic1eq/ic2eq state variables.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.math_rt
 *   External: core.stdc.math (tanf)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum SvfMode : ubyte { lpf, hpf, bpf, notch, peak }
 *   - struct CytomicSvf : setParams(cutoffHz, resonance, sampleRate), processSample(float, SvfMode), reset()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.filter_svf;
