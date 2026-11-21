/**
 * File:         source/modules/effects/smooth_fx.d
 * Module:       modules.effects.smooth_fx
 * Phase:        Phase 4.6 (Tier 2) — Audio-Rate Slew Limiter
 *
 * Purpose:
 *   Asymmetric rise/fall slew-rate limiter smoothing audio or CV signals without allocations.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow.
 *
 * Dependencies:
 *   Internal: graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct SmoothFx (typeId = "fx.smooth", ports: audioStereo in/out, cvControl in/out)
 *   - @Param riseRate, fallRate, scale
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.smooth_fx;
