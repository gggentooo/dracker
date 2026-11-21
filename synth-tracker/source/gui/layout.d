/**
 * File:         source/gui/layout.d
 * Module:       gui.layout
 * Phase:        Phase 7.5 — Retained Split-Pane & Docking Layout Engine
 *
 * Purpose:
 *   Computes responsive split-pane bounds, handles splitter dragging, manages input hit-testing, and dispatches keyboard focus cleanly across studio views.
 *
 * Real-Time & Safety Contract:
 *   UI thread only.
 *
 * Dependencies:
 *   Internal: gui.renderer, gui.theme
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - class SplitPaneNode / class DockLayout : arrange(RectF bounds), hitTest(Point2F), routeEvent(...)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.layout;
