/**
 * File:         source/app/keymap.d
 * Module:       app.keymap
 * Phase:        Phase 6.3 / 8.6 — Tracker Keyboard Piano & Shortcut Bindings
 *
 * Purpose:
 *   Maps macOS raw keycodes and modifiers to polyphonic tracker QWERTY piano notes (with octave state) and configurable pattern/patchbay/transport actions.
 *
 * Real-Time & Safety Contract:
 *   Runs on UI thread.
 *
 * Dependencies:
 *   Internal: platform.interfaces
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum StudioAction { playToggle, stop, recordToggle, octaveUp, octaveDown, undo, redo, ... }
 *   - struct Keymap : resolveNote(uint keyCode, int baseOctave), resolveAction(uint keyCode, uint mods)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module app.keymap;
