/**
 * File:         source/gui/views/transport_bar.d
 * Module:       gui.views.transport_bar
 * Phase:        Phase 8.1 — Studio Transport Bar & Audio/MIDI Header
 *
 * Purpose:
 *   Top studio toolbar hosting Play/Stop/Play-Pattern/Record controls, BPM/TPL drag boxes, playhead readout, CPU load meter, master stereo peak/clip meters, and audio/MIDI device pickers.
 *
 * Real-Time & Safety Contract:
 *   UI thread; reads lock-free TripleBuffer telemetry snapshots.
 *
 * Dependencies:
 *   Internal: gui.renderer, gui.widgets, app.session
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - class TransportBarView : draw(IRenderer2D), handleInput(...)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.views.transport_bar;
