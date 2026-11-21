/**
 * File:         source/gui/views/pattern_editor.d
 * Module:       gui.views.pattern_editor
 * Phase:        Phase 8.4 — High-Density Tracker Pattern Grid Editor
 *
 * Purpose:
 *   Renders and edits NN VV MM CCEE XXYY tracker columns with QWERTY + MIDI step/live entry, block selection, transpose, interpolate, copy/paste, and follow-playhead scroll.
 *
 * Real-Time & Safety Contract:
 *   UI thread; emits atomic NoteCell patches and UndoHistory commands.
 *
 * Dependencies:
 *   Internal: gui.renderer, gui.widgets, app.session, app.history, app.keymap, sequencer.note
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - class PatternEditorView : draw(IRenderer2D), handleKeyDown/Up(...), transposeSelection(int semitones), interpolateColumn()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.views.pattern_editor;
