/**
 * File:         source/modules/output.d
 * Module:       modules.output
 * Phase:        Phase 2.5 — Master Output Sink Module
 *
 * Purpose:
 *   Graph terminal sink collecting master stereo audio, applying optional soft-clipping safety limiter, and publishing master peak/clipping telemetry.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero NaN default init.
 *
 * Dependencies:
 *   Internal: graph.module_api, graph.port, graph.context
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct MasterOutput (typeId = "core.output", ports: audioStereo in -> stereo mix)
 *   - @Param volume, limiterEnable
 *   - process(...) returns master peak telemetry
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.output;
