/**
 * File:         source/sequencer/engine.d
 * Module:       sequencer.engine
 * Phase:        Phase 5.4 — Unified Instance-Scoped Engine & Stem Exporter
 *
 * Purpose:
 *   Combines Sequencer, AudioGraph, SPSC command/retire queues, live keyboard/MIDI voice allocation, and offline WAV / per-module stem rendering inside a re-entrant instance-scoped struct.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on renderAudioSlice(); zero global mutable state so MetaModule child Engines nest safely.
 *
 * Dependencies:
 *   Internal: foundation.*, graph.*, sequencer.note, sequencer.pattern, sequencer.timeline, sequencer.clock, sequencer.track_effects
 *   External: None on RT path
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Engine : prepare(sampleRate), processHostBuffer(...), pushCommand(...), drainRetireRing()
 *   - bool renderOfflineToBuffer(...) / stem export hooks
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.engine;
