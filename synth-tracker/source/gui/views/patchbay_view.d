/**
 * File:         source/gui/views/patchbay_view.d
 * Module:       gui.views.patchbay_view
 * Phase:        Phase 8.2 — Zoomable Modular Patchbay Graph Editor
 *
 * Purpose:
 *   Interactive node-and-wire modular editor supporting pan/zoom, module dragging, typed wire creation (audio, sidechain, event, CV), signal pulses, mute/solo/bypass, inline scopes, and ModuleRegistry menu.
 *
 * Real-Time & Safety Contract:
 *   UI thread; mutations commit through UndoHistory and StudioSession off-RT GraphCompiler.
 *
 * Dependencies:
 *   Internal: gui.renderer, gui.widgets, app.session, app.history, graph.registry
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - class PatchbayView : draw(IRenderer2D), handleMouse/Wheel/Pinch(...), openAddModuleMenu()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.views.patchbay_view;
