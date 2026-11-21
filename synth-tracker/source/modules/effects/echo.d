/**
 * File:         source/modules/effects/echo.d
 * Module:       modules.effects.echo
 * Phase:        Phase 4.1 (Tier 1) — Cross-Feedback Filtered Echo
 *
 * Purpose:
 *   Stereo/ping-pong echo processor placing a biquad damping filter inside the delay feedback loop.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); explicit feedback clamp (< 1.0) and decay-tail silence detection.
 *
 * Dependencies:
 *   Internal: dsp.delay_line, dsp.filter_biquad, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Echo (typeId = "fx.echo", ports: audioStereo in/out)
 *   - @Param dry, wet, feedback, delayTime, stereoMode, dampingHz
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.echo;
