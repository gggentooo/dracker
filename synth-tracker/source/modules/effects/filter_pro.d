/**
 * File:         source/modules/effects/filter_pro.d
 * Module:       modules.effects.filter_pro
 * Phase:        Phase 4.1 (Tier 1) — Multi-Stage Cascaded Filter Pro
 *
 * Purpose:
 *   High-precision cascaded RBJ biquad filter with CV cutoff/resonance modulation, drive saturation, and double-precision internal filter state.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero NaN state.
 *
 * Dependencies:
 *   Internal: dsp.filter_biquad, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct FilterPro (typeId = "fx.filter_pro", ports: audioStereo in/out, cvControl cutoffCv, cvControl resoCv)
 *   - @Param mode, slope, cutoffHz, resonance, gainDb, drive
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.filter_pro;
