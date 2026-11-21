/**
 * File:         source/gui/views/timeline_view.d
 * Module:       gui.views.timeline_view
 * Phase:        Phase 8.5 — Horizontal Pattern Arranger & Supertracks View
 *
 * Purpose:
 *   Displays multi-lane pattern clips, clones, loop range, Supertrack lane headers, mute/solo controls, and click-to-seek playhead.
 *
 * Real-Time & Safety Contract:
 *   UI thread; structural clip edits compile into CoW TimelineSnapshots via StudioSession.
 *
 * Dependencies:
 *   Internal: gui.renderer, gui.widgets, app.session, app.history, sequencer.timeline
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - class TimelineView : draw(IRenderer2D), handleClipDrag/Resize/Clone(...)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.views.timeline_view;
