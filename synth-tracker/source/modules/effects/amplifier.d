/**
 * File:         source/modules/effects/amplifier.d
 * Module:       modules.effects.amplifier
 * Phase:        Phase 2.5 / 4.1 (Tier 1) — Stereo Amplifier & Utility
 *
 * Purpose:
 *   Provides smoothed gain, stereo panning, DC offset, stereo width, and channel phase inversion with silent-input bypass.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init smoother state.
 *
 * Dependencies:
 *   Internal: dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Amplifier (typeId = "fx.amplifier", ports: audioStereo in/out, cvControl gainMod)
 *   - @Param volume, pan, dcOffset, stereoWidth, invert
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.amplifier;
