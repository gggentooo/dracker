/**
 * File:         tests/unit/keymap_test.d
 * Module:       tests.unit.keymap_test
 * Phase:        Phase 7.5.6 — Keymap Expansion & Studio Command Routing Tests
 *
 * Purpose:
 *   Verifies every default StudioAction binding, appkit menu key-equivalent parity, absence of binding
 *   conflicts and unmodified piano-key shadowing, document- vs. view-level classification, StudioCommandSink
 *   forwarding, bindAction/addBinding replacement semantics, and unchanged QWERTY piano note mapping.
 *
 * Real-Time & Safety Contract:
 *   Headless UI-thread value-type tests; no platform window or global state.
 *
 * Dependencies:
 *   Internal: app.keymap, platform.interfaces (KeyModifiers)
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites for app.keymap
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.keymap_test;

version (unittest) {
    import app.keymap : forwardToSink, isDocumentLevel, KeyBinding, Keymap, StudioAction, StudioCommandSink;
    import platform.interfaces : KeyModifiers;

    private enum uint CMD = KeyModifiers.command;
    private enum uint SHIFT = KeyModifiers.shift;
    private enum uint ALT = KeyModifiers.alt;

    private struct Expect {
        StudioAction action;
        uint keyCode;
        uint modifiers;
    }

    private immutable Expect[] DEFAULT_TABLE = [
        Expect(StudioAction.playToggle, 49, 0),
        Expect(StudioAction.playToggle, 36, CMD),
        Expect(StudioAction.stop, 53, 0),
        Expect(StudioAction.recordToggle, 15, CMD),
        Expect(StudioAction.octaveDown, 122, 0),
        Expect(StudioAction.octaveUp, 120, 0),
        Expect(StudioAction.undo, 6, CMD),
        Expect(StudioAction.redo, 6, CMD | SHIFT),
        Expect(StudioAction.saveProject, 1, CMD),
        Expect(StudioAction.saveProjectAs, 1, CMD | SHIFT),
        Expect(StudioAction.openProject, 31, CMD),
        Expect(StudioAction.newProject, 45, CMD),
        Expect(StudioAction.panic, 47, CMD),
        Expect(StudioAction.noteOffEntry, 48, 0),
        Expect(StudioAction.deleteCell, 51, 0),
        Expect(StudioAction.cut, 7, CMD),
        Expect(StudioAction.copy, 8, CMD),
        Expect(StudioAction.paste, 9, CMD),
        Expect(StudioAction.selectAll, 0, CMD),
        Expect(StudioAction.deleteBlock, 117, 0),
        Expect(StudioAction.transposeSemitoneUp, 126, CMD),
        Expect(StudioAction.transposeSemitoneDown, 125, CMD),
        Expect(StudioAction.transposeOctaveUp, 126, CMD | SHIFT),
        Expect(StudioAction.transposeOctaveDown, 125, CMD | SHIFT),
        Expect(StudioAction.interpolate, 34, CMD),
        Expect(StudioAction.playPattern, 49, SHIFT),
        Expect(StudioAction.toggleFollow, 3, CMD),
        Expect(StudioAction.nextPattern, 30, CMD),
        Expect(StudioAction.prevPattern, 33, CMD),
        Expect(StudioAction.nextTrack, 124, ALT),
        Expect(StudioAction.prevTrack, 123, ALT),
        Expect(StudioAction.stepUp, 126, ALT),
        Expect(StudioAction.stepDown, 125, ALT),
        Expect(StudioAction.toggleLoop, 37, CMD),
        Expect(StudioAction.zoomIn, 24, CMD),
        Expect(StudioAction.zoomOut, 27, CMD),
        Expect(StudioAction.zoomReset, 29, CMD),
        Expect(StudioAction.exportWav, 14, CMD),
        Expect(StudioAction.quit, 12, CMD),
        Expect(StudioAction.openAppearance, 43, CMD),
        Expect(StudioAction.toggleContrast, 8, CMD | ALT)
    ];

    private immutable Expect[] APPKIT_MENU_TABLE = [
        Expect(StudioAction.newProject, 45, CMD),
        Expect(StudioAction.openProject, 31, CMD),
        Expect(StudioAction.saveProject, 1, CMD),
        Expect(StudioAction.saveProjectAs, 1, CMD | SHIFT),
        Expect(StudioAction.undo, 6, CMD),
        Expect(StudioAction.redo, 6, CMD | SHIFT),
        Expect(StudioAction.cut, 7, CMD),
        Expect(StudioAction.copy, 8, CMD),
        Expect(StudioAction.paste, 9, CMD),
        Expect(StudioAction.selectAll, 0, CMD),
        Expect(StudioAction.playToggle, 36, CMD),
        Expect(StudioAction.recordToggle, 15, CMD),
        Expect(StudioAction.panic, 47, CMD),
        Expect(StudioAction.zoomIn, 24, CMD),
        Expect(StudioAction.zoomOut, 27, CMD),
        Expect(StudioAction.zoomReset, 29, CMD),
        Expect(StudioAction.quit, 12, CMD),
        Expect(StudioAction.openAppearance, 43, CMD),
        Expect(StudioAction.toggleContrast, 8, CMD | ALT)
    ];

    private final class RecordingSink : StudioCommandSink {
        StudioAction last = StudioAction.none;
        size_t calls = 0;
        bool accept = true;

        bool handleStudioAction(StudioAction action) {
            last = action;
            calls++;
            return accept;
        }
    }

    unittest {
        immutable Keymap km = Keymap.createDefault();
        foreach (ref e; DEFAULT_TABLE) {
            assert(km.resolveAction(e.keyCode, e.modifiers) == e.action);
        }
        assert(km.bindingCount() == DEFAULT_TABLE.length);
        assert(km.bindingCount() <= Keymap.MAX_BINDINGS);
        foreach (i; 0 .. km.bindingCount()) {
            immutable KeyBinding kb = km.bindingAt(i);
            bool listed = false;
            foreach (ref e; DEFAULT_TABLE) {
                if (e.action == kb.action && e.keyCode == kb.keyCode && e.modifiers == kb.modifiers) {
                    listed = true;
                }
            }
            assert(listed);
        }
        assert(km.bindingAt(km.bindingCount()) == KeyBinding.init);
        foreach (a; StudioAction.min .. StudioAction.max) {
            if (a == StudioAction.none) {
                continue;
            }
            bool bound = false;
            foreach (i; 0 .. km.bindingCount()) {
                if (km.bindingAt(i).action == a) {
                    bound = true;
                }
            }
            assert(bound);
        }
        assert(km.resolveAction(8, CMD | ALT) == StudioAction.max && StudioAction.max == StudioAction.toggleContrast);
    }

    unittest {
        immutable Keymap km = Keymap.createDefault();
        foreach (ref e; APPKIT_MENU_TABLE) {
            assert(km.resolveAction(e.keyCode, e.modifiers) == e.action);
        }
    }

    unittest {
        immutable Keymap km = Keymap.createDefault();
        StudioAction a = StudioAction.cut;
        StudioAction b = StudioAction.cut;
        assert(!km.hasConflicts(a, b));
        assert(a == StudioAction.none && b == StudioAction.none);
        assert(!km.shadowsPianoKey());

        Keymap clash = Keymap.createDefault();
        assert(clash.bindAction(StudioAction.toggleFollow, 7, CMD));
        assert(clash.hasConflicts(a, b));
        assert((a == StudioAction.cut && b == StudioAction.toggleFollow)
            || (a == StudioAction.toggleFollow && b == StudioAction.cut));

        Keymap shadow = Keymap.createDefault();
        assert(shadow.bindAction(StudioAction.deleteBlock, 6, KeyModifiers.none));
        assert(shadow.shadowsPianoKey());
        Keymap modified = Keymap.createDefault();
        assert(modified.bindAction(StudioAction.deleteBlock, 6, ALT));
        assert(!modified.shadowsPianoKey());
    }

    unittest {
        immutable uint[] pianoKeys = [6, 1, 7, 2, 8, 9, 5, 11, 4, 45, 38, 46, 12, 19, 13, 20, 14, 15, 23, 17,
            22, 16, 26, 32, 34, 25, 31, 29, 35];
        foreach (k; pianoKeys) {
            assert(Keymap.isPianoKey(k));
        }
        assert(!Keymap.isPianoKey(49));
        assert(!Keymap.isPianoKey(117));
        assert(!Keymap.isPianoKey(126));

        immutable Keymap km = Keymap.createDefault();
        ubyte midi = 0;
        assert(km.resolveNote(6, 4, midi) && midi == 60);
        assert(km.resolveNote(1, 4, midi) && midi == 61);
        assert(km.resolveNote(46, 4, midi) && midi == 71);
        assert(km.resolveNote(12, 4, midi) && midi == 72);
        assert(km.resolveNote(35, 4, midi) && midi == 88);
        assert(km.resolveNote(6, -1, midi) && midi == 0);
        assert(!km.resolveNote(35, 9, midi) && midi == 0);
        assert(!km.resolveNote(49, 4, midi));
        assert(km.resolveAction(6, KeyModifiers.none) == StudioAction.none);
        assert(km.resolveAction(999, CMD) == StudioAction.none);
    }

    unittest {
        immutable StudioAction[] documentLevel = [
            StudioAction.playToggle, StudioAction.stop, StudioAction.recordToggle, StudioAction.octaveUp,
            StudioAction.octaveDown, StudioAction.undo, StudioAction.redo, StudioAction.saveProject,
            StudioAction.saveProjectAs, StudioAction.openProject, StudioAction.newProject, StudioAction.panic,
            StudioAction.playPattern, StudioAction.toggleLoop, StudioAction.exportWav, StudioAction.quit,
            StudioAction.openAppearance, StudioAction.toggleContrast
        ];
        immutable StudioAction[] viewLevel = [
            StudioAction.noteOffEntry, StudioAction.deleteCell, StudioAction.cut, StudioAction.copy,
            StudioAction.paste, StudioAction.selectAll, StudioAction.deleteBlock, StudioAction.transposeSemitoneUp,
            StudioAction.transposeSemitoneDown, StudioAction.transposeOctaveUp, StudioAction.transposeOctaveDown,
            StudioAction.interpolate, StudioAction.toggleFollow, StudioAction.nextPattern, StudioAction.prevPattern,
            StudioAction.nextTrack, StudioAction.prevTrack, StudioAction.stepUp, StudioAction.stepDown,
            StudioAction.zoomIn, StudioAction.zoomOut, StudioAction.zoomReset
        ];
        assert(documentLevel.length + viewLevel.length + 1 == StudioAction.max + 1);
        foreach (a; documentLevel) {
            assert(isDocumentLevel(a));
        }
        foreach (a; viewLevel) {
            assert(!isDocumentLevel(a));
        }
        assert(!isDocumentLevel(StudioAction.none));

        auto sink = new RecordingSink();
        foreach (a; viewLevel) {
            assert(forwardToSink(sink, a));
            assert(sink.last == a);
        }
        assert(sink.calls == viewLevel.length);
        foreach (a; documentLevel) {
            assert(!forwardToSink(sink, a));
        }
        assert(!forwardToSink(sink, StudioAction.none));
        assert(sink.calls == viewLevel.length);
        sink.accept = false;
        assert(!forwardToSink(sink, StudioAction.copy));
        assert(sink.calls == viewLevel.length + 1);
        assert(!forwardToSink(null, StudioAction.copy));
    }

    unittest {
        Keymap km = Keymap.createDefault();
        immutable size_t before = km.bindingCount();
        assert(km.bindAction(StudioAction.copy, 8, CMD | KeyModifiers.control));
        assert(km.bindingCount() == before);
        assert(km.resolveAction(8, CMD) == StudioAction.none);
        assert(km.resolveAction(8, CMD | KeyModifiers.control) == StudioAction.copy);

        assert(km.bindAction(StudioAction.playToggle, 49, CMD | ALT));
        assert(km.bindingCount() == before - 1);
        assert(km.resolveAction(49, 0) == StudioAction.none);
        assert(km.resolveAction(36, CMD) == StudioAction.none);
        assert(km.resolveAction(49, CMD | ALT) == StudioAction.playToggle);

        assert(km.addBinding(StudioAction.playToggle, 49, 0));
        assert(km.addBinding(StudioAction.playToggle, 49, 0));
        assert(km.bindingCount() == before);
        assert(!km.addBinding(StudioAction.stop, 49, 0));
        assert(km.resolveAction(49, 0) == StudioAction.playToggle);
        StudioAction a;
        StudioAction b;
        assert(!km.hasConflicts(a, b));
    }

    unittest {
        Keymap km;
        assert(km.bindingCount() == 0);
        foreach (i; 0 .. Keymap.MAX_BINDINGS) {
            assert(km.addBinding(StudioAction.panic, cast(uint)(200 + i), 0));
        }
        assert(!km.addBinding(StudioAction.panic, 999, 0));
        assert(!km.bindAction(StudioAction.stop, 998, 0));
        assert(km.bindAction(StudioAction.panic, 997, 0));
        assert(km.bindingCount() == 1);
        assert(km.resolveAction(997, 0) == StudioAction.panic);
        assert(km.resolveAction(200, 0) == StudioAction.none);
    }
}
