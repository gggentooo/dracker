/**
 * File:         source/app/session.d
 * Module:       app.session
 * Phase:        Phase 6.3 / 8.6 — Application Session & UI <-> RT Bridge
 *
 * Purpose:
 *   Owns document lifecycle, dirty state, periodic .msv autosave, GraphCompiler invocation, off-RT asset decoding orchestration, and retire-ring polling between GUI/CLI and Engine.
 *
 * Real-Time & Safety Contract:
 *   Runs strictly on UI/main thread (may use GC for UI state); ensures all data sent over SPSC CommandRing to RT is @nogc OwnedBuffer-backed with zero GC pointers.
 *
 * Dependencies:
 *   Internal: sequencer.engine, graph.plan, io.project_format, app.history, platform.interfaces
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - class StudioSession : openProject(), saveProject(), compileAndSwapGraph(), patchPatternCell(), pollRetiredAndTelemetry()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module app.session;
