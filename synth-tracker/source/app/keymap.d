/**
 * File:         source/app/keymap.d
 * Module:       app.keymap
 * Phase:        Phase 6.3 / 8.6 — Tracker Keyboard Piano & Shortcut Bindings
 *
 * Purpose:
 *   Maps macOS virtual keycodes and modifiers to polyphonic tracker QWERTY piano notes (two-octave split) and configurable pattern/patchbay/transport StudioActions.
 *
 * Real-Time & Safety Contract:
 *   UI thread key translation helpers; @nogc nothrow pure @safe note and action resolution.
 *
 * Dependencies:
 *   Internal: platform.interfaces (KeyModifiers)
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum StudioAction : ubyte
 *   - struct KeyBinding { StudioAction action; uint keyCode; uint modifiers; }
 *   - struct Keymap : createDefault(), resolveNote(), resolveAction(), bindAction()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module app.keymap;

import platform.interfaces : KeyModifiers;

/**
 * High-level UI/sequencer/document action identifiers dispatched from keyboard shortcuts.
 */
enum StudioAction : ubyte {
    none = 0,
    playToggle = 1,
    stop = 2,
    recordToggle = 3,
    octaveUp = 4,
    octaveDown = 5,
    undo = 6,
    redo = 7,
    saveProject = 8,
    saveProjectAs = 9,
    openProject = 10,
    newProject = 11,
    panic = 12,
    noteOffEntry = 13,
    deleteCell = 14
}

/**
 * Single configurable shortcut binding pairing a StudioAction with keyCode and modifier mask.
 */
struct KeyBinding {
    StudioAction action = StudioAction.none;
    uint keyCode = 0;
    uint modifiers = 0;
}

private struct NoteKeyEntry {
    uint macKeyCode = 0;
    byte semitoneOffset = 0;
}

/**
 * Configurable keyboard shortcut and macOS two-octave QWERTY tracker piano mapper.
 *
 * Lower octave maps Z S X D C V G B H N J M (C..B relative to baseOctave), and upper octave
 * maps Q 2 W 3 E R 5 T 6 Y 7 U I 9 O 0 P (C+12..E+28).
 */
struct Keymap {
    enum size_t MAX_BINDINGS = 64;

    private KeyBinding[MAX_BINDINGS] bindings_;
    private size_t bindingCount_ = 0;

    private static immutable NoteKeyEntry[29] PIANO_KEYS = [
        NoteKeyEntry(6, 0),
        NoteKeyEntry(1, 1),
        NoteKeyEntry(7, 2),
        NoteKeyEntry(2, 3),
        NoteKeyEntry(8, 4),
        NoteKeyEntry(9, 5),
        NoteKeyEntry(5, 6),
        NoteKeyEntry(11, 7),
        NoteKeyEntry(4, 8),
        NoteKeyEntry(45, 9),
        NoteKeyEntry(38, 10),
        NoteKeyEntry(46, 11),
        NoteKeyEntry(12, 12),
        NoteKeyEntry(19, 13),
        NoteKeyEntry(13, 14),
        NoteKeyEntry(20, 15),
        NoteKeyEntry(14, 16),
        NoteKeyEntry(15, 17),
        NoteKeyEntry(23, 18),
        NoteKeyEntry(17, 19),
        NoteKeyEntry(22, 20),
        NoteKeyEntry(16, 21),
        NoteKeyEntry(26, 22),
        NoteKeyEntry(32, 23),
        NoteKeyEntry(34, 24),
        NoteKeyEntry(25, 25),
        NoteKeyEntry(31, 26),
        NoteKeyEntry(29, 27),
        NoteKeyEntry(35, 28)
    ];

    @nogc nothrow pure @safe:

    /**
     * Constructs a Keymap initialized with standard macOS studio shortcuts and tracker controls.
     *
     * Returns:
     *   Populated default Keymap.
     */
    static Keymap createDefault() {
        Keymap km;
        km.bindAction(StudioAction.playToggle, 49, KeyModifiers.none);
        km.bindAction(StudioAction.stop, 53, KeyModifiers.none);
        km.bindAction(StudioAction.recordToggle, 15, KeyModifiers.command);
        km.bindAction(StudioAction.octaveDown, 122, KeyModifiers.none);
        km.bindAction(StudioAction.octaveUp, 120, KeyModifiers.none);
        km.bindAction(StudioAction.undo, 6, KeyModifiers.command);
        km.bindAction(StudioAction.redo, 6, KeyModifiers.command | KeyModifiers.shift);
        km.bindAction(StudioAction.saveProject, 1, KeyModifiers.command);
        km.bindAction(StudioAction.saveProjectAs, 1, KeyModifiers.command | KeyModifiers.shift);
        km.bindAction(StudioAction.openProject, 31, KeyModifiers.command);
        km.bindAction(StudioAction.newProject, 45, KeyModifiers.command);
        km.bindAction(StudioAction.panic, 47, KeyModifiers.command);
        km.bindAction(StudioAction.noteOffEntry, 48, KeyModifiers.none);
        km.bindAction(StudioAction.deleteCell, 51, KeyModifiers.none);
        return km;
    }

    /**
     * Registers or replaces a StudioAction key binding inside the fixed binding table.
     *
     * Params:
     *   action = Target StudioAction identifier.
     *   keyCode = Platform raw virtual key code.
     *   modifiers = Bitmask of KeyModifiers required.
     *
     * Returns:
     *   True if recorded cleanly; false if binding capacity is full.
     */
    bool bindAction(StudioAction action, uint keyCode, uint modifiers) {
        foreach (i; 0 .. bindingCount_) {
            if (bindings_[i].action == action) {
                bindings_[i] = KeyBinding(action, keyCode, modifiers);
                return true;
            }
        }
        if (bindingCount_ >= MAX_BINDINGS) {
            return false;
        }
        bindings_[bindingCount_++] = KeyBinding(action, keyCode, modifiers);
        return true;
    }

    /**
     * Resolves a keyCode and modifier bitmask into a configured StudioAction.
     *
     * Prefers more-specific modifier matches (e.g. Cmd+Shift+Z over Cmd+Z) by checking exact equality.
     *
     * Params:
     *   keyCode = Platform virtual key code.
     *   modifiers = Active KeyModifiers bitmask.
     *
     * Returns:
     *   Matching StudioAction, or StudioAction.none if unbound.
     */
    StudioAction resolveAction(uint keyCode, uint modifiers) const {
        foreach (i; 0 .. bindingCount_) {
            if (bindings_[i].keyCode == keyCode && bindings_[i].modifiers == modifiers) {
                return bindings_[i].action;
            }
        }
        return StudioAction.none;
    }

    /**
     * Maps a macOS virtual keyCode onto the two-octave QWERTY tracker piano relative to baseOctave.
     *
     * Params:
     *   keyCode = macOS virtual key code.
     *   baseOctave = Base tracker octave (e.g., 4 maps Z to MIDI 60 / C4).
     *   midiNote = Output MIDI note clamped to [0..127] when true is returned.
     *
     * Returns:
     *   True if keyCode belongs to the QWERTY piano layout and falls inside MIDI [0..127].
     */
    bool resolveNote(uint keyCode, int baseOctave, out ubyte midiNote) const {
        midiNote = 0;
        int oct = baseOctave;
        if (oct < -1) oct = -1;
        if (oct > 9) oct = 9;
        foreach (ref entry; PIANO_KEYS) {
            if (entry.macKeyCode == keyCode) {
                immutable int raw = (oct + 1) * 12 + cast(int) entry.semitoneOffset;
                if (raw < 0 || raw > 127) {
                    return false;
                }
                midiNote = cast(ubyte) raw;
                return true;
            }
        }
        return false;
    }
}
