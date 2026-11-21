/**
 * File:         source/app/history.d
 * Module:       app.history
 * Phase:        Phase 6.3 — Command-Pattern Undo/Redo Stack
 *
 * Purpose:
 *   Records reversible user actions (pattern edits, module add/remove, wire connect/disconnect, parameter tweaks, timeline moves) with coalescing for continuous slider drags.
 *
 * Real-Time & Safety Contract:
 *   Runs on UI thread; undo/redo cleanly dispatches RT updates and reclaims retired objects.
 *
 * Dependencies:
 *   Internal: app.session
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - interface IUndoCommand { void execute(StudioSession s); void undo(StudioSession s); string label() const; }
 *   - class UndoHistory : pushAndExecute(IUndoCommand), undo(), redo(), clear()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module app.history;
