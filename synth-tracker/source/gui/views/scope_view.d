/**
 * File:         source/gui/views/scope_view.d
 * Module:       gui.views.scope_view
 * Phase:        Phase 8.1 — Live Oscilloscope & FFT Spectrum Analyzer
 *
 * Purpose:
 *   Renders master and per-module time-domain waveforms and logarithmic FFT spectrum plots from lock-free TripleBuffer telemetry.
 *
 * Real-Time & Safety Contract:
 *   UI thread; zero locking against RT thread.
 *
 * Dependencies:
 *   Internal: gui.renderer, gui.theme, dsp.fft, app.session
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - class ScopeView : draw(IRenderer2D), setMode(ScopeMode)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.views.scope_view;
