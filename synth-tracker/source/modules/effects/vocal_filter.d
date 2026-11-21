/**
 * File:         source/modules/effects/vocal_filter.d
 * Module:       modules.effects.vocal_filter
 * Phase:        Phase 4.7 (Tier 2) — Formant Vowel Filter Bank
 *
 * Purpose:
 *   Parallel/cascaded bandpass formant filter bank morphing smoothly across A/E/I/O/U vowel spectra.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; double-precision internal biquad states.
 *
 * Dependencies:
 *   Internal: dsp.filter_biquad, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct VocalFilter (typeId = "fx.vocal_filter", ports: audioStereo in/out, cvControl vowelCv)
 *   - @Param vowelMorph, formantShift, bandwidth, voiceType, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.vocal_filter;
