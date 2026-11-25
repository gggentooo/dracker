/**
 * File:         source/app/keymap.d
 * Module:       app.keymap
 * Phase:        Phase 6.3 / 7.5.6 / 8.6 — Tracker Keyboard Piano, Shortcut Bindings & Studio Command Routing
 *
 * Purpose:
 *   Maps macOS virtual keycodes and modifiers to polyphonic tracker QWERTY piano notes (two-octave split) and configurable pattern/patchbay/transport StudioActions.
 *   Default bindings mirror the platform.macos.appkit menu key equivalents exactly; document-level actions are executed by app.session
 *   while view-level actions (selection, editing, navigation, zoom) are forwarded to the focused StudioCommandSink.
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
 *   - interface StudioCommandSink { bool handleStudioAction(StudioAction action); }
 *   - bool isDocumentLevel(StudioAction), bool forwardToSink(StudioCommandSink, StudioAction)
 *   - struct Keymap : createDefault(), resolveNote(), resolveAction(), bindAction(), addBinding(),
 *     bindingCount(), bindingAt(), hasConflicts(), shadowsPianoKey(), isPianoKey()
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
    deleteCell = 14,
    cut = 15,
    copy = 16,
    paste = 17,
    selectAll = 18,
    deleteBlock = 19,
    transposeSemitoneUp = 20,
    transposeSemitoneDown = 21,
    transposeOctaveUp = 22,
    transposeOctaveDown = 23,
    interpolate = 24,
    playPattern = 25,
    toggleFollow = 26,
    nextPattern = 27,
    prevPattern = 28,
    nextTrack = 29,
    prevTrack = 30,
    stepUp = 31,
    stepDown = 32,
    toggleLoop = 33,
    zoomIn = 34,
    zoomOut = 35,
    zoomReset = 36,
    exportWav = 37,
    quit = 38,
    openAppearance = 39,
    toggleContrast = 40,
    editToggle = 41
}

/**
 * Receiver for context-dependent (view-level) StudioActions, implemented by the focused studio view.
 */
interface StudioCommandSink {
    /**
     * Executes a view-level StudioAction against the view's own selection/cursor state.
     *
     * Params:
     *   action = View-level action resolved from the keymap or a menu item.
     *
     * Returns:
     *   True if the view consumed the action.
     */
    bool handleStudioAction(StudioAction action);
}

/**
 * Classifies a StudioAction as document-level (executed by the session regardless of focus).
 *
 * Document-level: playToggle, stop, recordToggle (live record), editToggle (edit mode), octaveUp/Down, undo, redo, saveProject, saveProjectAs,
 * openProject, newProject, panic, playPattern, toggleLoop, exportWav, quit, openAppearance, toggleContrast.
 * Every other action except
 * none (selection, cell/block editing, transpose, interpolate, navigation, follow, edit step, zoom) is
 * view-level and must be forwarded to the focused StudioCommandSink.
 *
 * Params:
 *   action = Action to classify.
 *
 * Returns:
 *   True for document-level actions; false for view-level actions and none.
 */
bool isDocumentLevel(StudioAction action) @nogc nothrow pure @safe {
    switch (action) {
        case StudioAction.playToggle:
        case StudioAction.stop:
        case StudioAction.recordToggle:
        case StudioAction.editToggle:
        case StudioAction.octaveUp:
        case StudioAction.octaveDown:
        case StudioAction.undo:
        case StudioAction.redo:
        case StudioAction.saveProject:
        case StudioAction.saveProjectAs:
        case StudioAction.openProject:
        case StudioAction.newProject:
        case StudioAction.panic:
        case StudioAction.playPattern:
        case StudioAction.toggleLoop:
        case StudioAction.exportWav:
        case StudioAction.quit:
        case StudioAction.openAppearance:
        case StudioAction.toggleContrast:
            return true;
        default:
            return false;
    }
}

/**
 * Forwards a view-level action to the focused sink.
 *
 * Params:
 *   sink = Focused view sink (may be null when no view has focus).
 *   action = Action to forward.
 *
 * Returns:
 *   False when sink is null, the action is none or document-level, or the sink declined it; otherwise true.
 */
bool forwardToSink(StudioCommandSink sink, StudioAction action) {
    if (sink is null || action == StudioAction.none || isDocumentLevel(action)) {
        return false;
    }
    return sink.handleStudioAction(action);
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
        km.bindAction(StudioAction.editToggle, 15, KeyModifiers.command | KeyModifiers.shift);
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
        km.addBinding(StudioAction.playToggle, 36, KeyModifiers.command);
        km.bindAction(StudioAction.cut, 7, KeyModifiers.command);
        km.bindAction(StudioAction.copy, 8, KeyModifiers.command);
        km.bindAction(StudioAction.paste, 9, KeyModifiers.command);
        km.bindAction(StudioAction.selectAll, 0, KeyModifiers.command);
        km.bindAction(StudioAction.deleteBlock, 117, KeyModifiers.none);
        km.bindAction(StudioAction.transposeSemitoneUp, 126, KeyModifiers.command);
        km.bindAction(StudioAction.transposeSemitoneDown, 125, KeyModifiers.command);
        km.bindAction(StudioAction.transposeOctaveUp, 126, KeyModifiers.command | KeyModifiers.shift);
        km.bindAction(StudioAction.transposeOctaveDown, 125, KeyModifiers.command | KeyModifiers.shift);
        km.bindAction(StudioAction.interpolate, 34, KeyModifiers.command);
        km.bindAction(StudioAction.playPattern, 49, KeyModifiers.shift);
        km.bindAction(StudioAction.toggleFollow, 3, KeyModifiers.command);
        km.bindAction(StudioAction.nextPattern, 30, KeyModifiers.command);
        km.bindAction(StudioAction.prevPattern, 33, KeyModifiers.command);
        km.bindAction(StudioAction.nextTrack, 124, KeyModifiers.alt);
        km.bindAction(StudioAction.prevTrack, 123, KeyModifiers.alt);
        km.bindAction(StudioAction.stepUp, 126, KeyModifiers.alt);
        km.bindAction(StudioAction.stepDown, 125, KeyModifiers.alt);
        km.bindAction(StudioAction.toggleLoop, 37, KeyModifiers.command);
        km.bindAction(StudioAction.zoomIn, 24, KeyModifiers.command);
        km.bindAction(StudioAction.zoomOut, 27, KeyModifiers.command);
        km.bindAction(StudioAction.zoomReset, 29, KeyModifiers.command);
        km.bindAction(StudioAction.exportWav, 14, KeyModifiers.command);
        km.bindAction(StudioAction.quit, 12, KeyModifiers.command);
        km.bindAction(StudioAction.openAppearance, 43, KeyModifiers.command);
        km.bindAction(StudioAction.toggleContrast, 8, KeyModifiers.command | KeyModifiers.alt);
        return km;
    }

    /**
     * Registers or replaces a StudioAction key binding inside the fixed binding table.
     *
     * Any existing bindings for the action (including alternates added via addBinding) are replaced by this
     * single binding.
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
        bool replaced = false;
        size_t w = 0;
        foreach (i; 0 .. bindingCount_) {
            if (bindings_[i].action == action) {
                if (replaced) {
                    continue;
                }
                bindings_[w++] = KeyBinding(action, keyCode, modifiers);
                replaced = true;
                continue;
            }
            bindings_[w++] = bindings_[i];
        }
        bindingCount_ = w;
        if (replaced) {
            return true;
        }
        if (bindingCount_ >= MAX_BINDINGS) {
            return false;
        }
        bindings_[bindingCount_++] = KeyBinding(action, keyCode, modifiers);
        return true;
    }

    /**
     * Appends an alternate key binding for an action, keeping its existing bindings.
     *
     * Params:
     *   action = Target StudioAction identifier.
     *   keyCode = Platform raw virtual key code.
     *   modifiers = Bitmask of KeyModifiers required.
     *
     * Returns:
     *   True if appended (or already present for this action); false if the key combination is already bound
     *   to a different action or the binding table is full.
     */
    bool addBinding(StudioAction action, uint keyCode, uint modifiers) {
        foreach (i; 0 .. bindingCount_) {
            if (bindings_[i].keyCode == keyCode && bindings_[i].modifiers == modifiers) {
                return bindings_[i].action == action;
            }
        }
        if (bindingCount_ >= MAX_BINDINGS) {
            return false;
        }
        bindings_[bindingCount_++] = KeyBinding(action, keyCode, modifiers);
        return true;
    }

    /**
     * Returns the number of populated bindings.
     *
     * Returns:
     *   Binding count in [0, MAX_BINDINGS].
     */
    size_t bindingCount() const {
        return bindingCount_;
    }

    /**
     * Returns the binding stored at index i.
     *
     * Params:
     *   i = Zero-based binding index.
     *
     * Returns:
     *   The binding, or an empty KeyBinding when i >= bindingCount().
     */
    KeyBinding bindingAt(size_t i) const {
        return i < bindingCount_ ? bindings_[i] : KeyBinding.init;
    }

    /**
     * Detects two bindings that share an identical keyCode and modifier mask.
     *
     * Params:
     *   a = Receives the first conflicting action (none when no conflict).
     *   b = Receives the second conflicting action (none when no conflict).
     *
     * Returns:
     *   True if a conflict exists.
     */
    bool hasConflicts(out StudioAction a, out StudioAction b) const {
        foreach (i; 0 .. bindingCount_) {
            foreach (j; i + 1 .. bindingCount_) {
                if (bindings_[i].keyCode == bindings_[j].keyCode && bindings_[i].modifiers == bindings_[j].modifiers) {
                    a = bindings_[i].action;
                    b = bindings_[j].action;
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * Reports whether any unmodified binding would swallow a QWERTY tracker piano key.
     *
     * Returns:
     *   True if a binding with modifiers == none uses a piano keyCode.
     */
    bool shadowsPianoKey() const {
        foreach (i; 0 .. bindingCount_) {
            if (bindings_[i].modifiers == KeyModifiers.none && isPianoKey(bindings_[i].keyCode)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Reports whether a keyCode belongs to the two-octave QWERTY tracker piano layout.
     *
     * Params:
     *   keyCode = macOS virtual key code.
     *
     * Returns:
     *   True for piano keys.
     */
    static bool isPianoKey(uint keyCode) {
        foreach (ref entry; PIANO_KEYS) {
            if (entry.macKeyCode == keyCode) {
                return true;
            }
        }
        return false;
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
