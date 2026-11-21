/**
 * File:         source/gui/views/sample_editor.d
 * Module:       gui.views.sample_editor
 * Phase:        Phase 8.3 — Sampler Waveform, Loop & Envelope Editor
 *
 * Purpose:
 *   Interactive waveform viewer for Sampler slots featuring zoom, loop start/end markers, slice/envelope editing, and native file import.
 *
 * Real-Time & Safety Contract:
 *   UI thread; dispatches off-RT decoding and SwapModuleAsset via StudioSession.
 *
 * Dependencies:
 *   Internal: gui.renderer, gui.widgets, app.session, modules.synths.sampler
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - class SampleEditorView : draw(IRenderer2D), handleMarkerDrag(...), importSamplePrompt()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.views.sample_editor;
