/**
 * File:         source/modules/control/feedback.d
 * Module:       modules.control.feedback
 * Phase:        Phase 2.5 / 4.2 (Tier 1) — Fixed-Delay Graph Feedback Pair
 *
 * Purpose:
 *   Breaks directed audio graph cycles cleanly via explicit FeedbackSend/FeedbackReceive edge splitting with a buffer-size-independent fixed sample delay.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; fixed-length OwnedBuffer!float ring independent of host audio buffer size.
 *
 * Dependencies:
 *   Internal: foundation.memory, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Feedback (typeId = "ctl.feedback", ports: audioStereo in/out)
 *   - @Param volume, channels, fixedDelayFrames (default 64)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.feedback;
