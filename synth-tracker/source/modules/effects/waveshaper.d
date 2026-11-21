/**
 * File:         source/modules/effects/waveshaper.d
 * Module:       modules.effects.waveshaper
 * Phase:        Phase 4.6 (Tier 2) — Editable Transfer-Curve WaveShaper
 *
 * Purpose:
 *   Applies a user-editable transfer lookup curve with DC blocking and optional 2x/4x oversampling.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); curve table swapped atomically via SwapModuleAsset.
 *
 * Dependencies:
 *   Internal: dsp.interp, dsp.resampler, dsp.smoother, foundation.memory, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct WaveShaper (typeId = "fx.waveshaper", ports: audioStereo in/out)
 *   - @Param inputGain, mix, dcBlock, oversampleMode
 *   - Hooks: serializeExtra, deserializeExtra, swapAsset
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.waveshaper;
