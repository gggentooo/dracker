/**
 * File:         tests/unit/compose_notation_test.d
 * Module:       tests.unit.compose_notation_test
 * Phase:        Composition helper (dracker-compose) — T84 (Script language: note notation)
 *
 * Purpose:
 *   Verifies compose.script.notation: pitch parsing and formatting across all MIDI notes and keys,
 *   note/chord/rest sequence parsing in 4/4 and 6/8 with carried lengths and non-carried velocities,
 *   every refusal class (P1-P8, V1-V4, S1-S8, L) with exact byte offset, length and suggestion,
 *   suggestion acceptance checks, and a three-token sweep verifying no crash or out-of-bounds offset.
 *
 * Real-Time & Safety Contract:
 *   Pure single-threaded checks; no session, audio, GUI, or files.
 *
 * Dependencies:
 *   Internal: app.music_theory (allKeys, noteName), compose.script.notation, compose.timing (TimeSignature)
 *   External: std.math (fabs)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T67, T73, T84), source/compose/script/notation.d
 */
module tests.unit.compose_notation_test;

version (unittest) {
    import std.math : fabs;

    import app.music_theory : allKeys, noteName;
    import compose.script.notation;
    import compose.timing : TimeSignature;

    private immutable TimeSignature SIG_4_4 = TimeSignature(4, 4);
    private immutable TimeSignature SIG_6_8 = TimeSignature(6, 8);

    private bool velNear(float a, float b) {
        return fabs(a - b) < 1e-6f;
    }

    private void assertRefused(NotationResult r, size_t offset, size_t length, string suggestion) {
        assert(!r.ok);
        assert(r.events.length == 0);
        assert(r.error.reason.length > 0);
        assert(r.error.offset == offset);
        assert(r.error.length == length);
        assert(r.error.suggestion == suggestion);
    }

    private void assertPitchRefused(PitchResult r, size_t offset, size_t length, string suggestion) {
        assert(!r.ok);
        assert(r.error.reason.length > 0);
        assert(r.error.offset == offset);
        assert(r.error.length == length);
        assert(r.error.suggestion == suggestion);
    }

    unittest {
        assert(velNear(DEFAULT_NOTE_VELOCITY, 0.8f));

        immutable PitchResult c4 = parsePitch("C4");
        immutable PitchResult a4 = parsePitch("A4");
        immutable PitchResult bb3 = parsePitch("Bb3");
        immutable PitchResult es4 = parsePitch("E#4");
        assert(c4.ok && c4.midi == 60);
        assert(a4.ok && a4.midi == 69);
        assert(bb3.ok && bb3.midi == 58);
        assert(es4.ok && es4.midi == 65);

        immutable PitchResult cm1 = parsePitch("C-1");
        immutable PitchResult g9 = parsePitch("G9");
        immutable PitchResult bsm2 = parsePitch("B#-2");
        assert(cm1.ok && cm1.midi == 0);
        assert(g9.ok && g9.midi == 127);
        assert(bsm2.ok && bsm2.midi == 0);

        assert(formatPitch(60) == "C4");
        assert(formatPitch(0) == "C-1");
        assert(formatPitch(127) == "G9");
        assert(formatPitch(128) == "");
    }

    unittest {
        foreach (key; allKeys()) {
            foreach (midi; 0 .. 128) {
                immutable string spelled = noteName(midi, key);
                immutable PitchResult parsed = parsePitch(spelled);
                assert(parsed.ok && parsed.midi == cast(ubyte) midi, spelled);
            }
        }
    }

    unittest {
        immutable NotationResult r1 = parseNotes("C4:1 E4:1/2 G4:1/2@0.6", SIG_4_4);
        assert(r1.ok && r1.totalLines == 8 && r1.events.length == 3);
        assert(r1.events[0].offset == 0 && r1.events[0].length == 4
            && r1.events[0].pitches == [cast(ubyte) 60] && velNear(r1.events[0].velocity, 0.8f)
            && r1.events[0].textOffset == 0 && r1.events[0].textLength == 4);
        assert(r1.events[1].offset == 4 && r1.events[1].length == 2
            && r1.events[1].pitches == [cast(ubyte) 64] && velNear(r1.events[1].velocity, 0.8f)
            && r1.events[1].textOffset == 5 && r1.events[1].textLength == 6);
        assert(r1.events[2].offset == 6 && r1.events[2].length == 2
            && r1.events[2].pitches == [cast(ubyte) 67] && velNear(r1.events[2].velocity, 0.6f)
            && r1.events[2].textOffset == 12 && r1.events[2].textLength == 10);

        immutable NotationResult r2 = parseNotes("C4:1 E4:1/2 G4:1/2@0.6", SIG_6_8);
        assert(r2.ok && r2.totalLines == 4 && r2.events.length == 3);
        assert(r2.events[0].offset == 0 && r2.events[0].length == 2);
        assert(r2.events[1].offset == 2 && r2.events[1].length == 1);
        assert(r2.events[2].offset == 3 && r2.events[2].length == 1);

        immutable NotationResult r3 = parseNotes("C4 D4 E4", SIG_4_4);
        assert(r3.ok && r3.totalLines == 12 && r3.events.length == 3);
        assert(r3.events[0].offset == 0 && r3.events[0].length == 4);
        assert(r3.events[1].offset == 4 && r3.events[1].length == 4);
        assert(r3.events[2].offset == 8 && r3.events[2].length == 4);

        immutable NotationResult r4 = parseNotes("C4 D4 E4", SIG_6_8);
        assert(r4.ok && r4.totalLines == 6 && r4.events.length == 3);
        assert(r4.events[0].offset == 0 && r4.events[0].length == 2);
        assert(r4.events[1].offset == 2 && r4.events[1].length == 2);
        assert(r4.events[2].offset == 4 && r4.events[2].length == 2);

        immutable NotationResult r5 = parseNotes("C4:2 D4 - E4:3l F4", SIG_4_4);
        assert(r5.ok && r5.totalLines == 30 && r5.events.length == 4);
        assert(r5.events[0].offset == 0 && r5.events[0].length == 8);
        assert(r5.events[1].offset == 8 && r5.events[1].length == 8);
        assert(r5.events[2].offset == 24 && r5.events[2].length == 3);
        assert(r5.events[3].offset == 27 && r5.events[3].length == 3);

        immutable NotationResult r6 = parseNotes("[C4 E4 G4]:2", SIG_4_4);
        assert(r6.ok && r6.totalLines == 8 && r6.events.length == 1);
        assert(r6.events[0].offset == 0 && r6.events[0].length == 8
            && r6.events[0].pitches == [cast(ubyte) 60, cast(ubyte) 64, cast(ubyte) 67]
            && velNear(r6.events[0].velocity, 0.8f));

        immutable NotationResult r7 = parseNotes("[C4 E4 G4]:2", SIG_6_8);
        assert(r7.ok && r7.totalLines == 4 && r7.events.length == 1 && r7.events[0].length == 4);

        immutable NotationResult r8 = parseNotes("C4:1b -:1b [A3 C#4]@0.5", SIG_6_8);
        assert(r8.ok && r8.totalLines == 36 && r8.events.length == 2);
        assert(r8.events[0].offset == 0 && r8.events[0].length == 12
            && r8.events[0].pitches == [cast(ubyte) 60]);
        assert(r8.events[1].offset == 24 && r8.events[1].length == 12
            && r8.events[1].pitches == [cast(ubyte) 57, cast(ubyte) 61]
            && velNear(r8.events[1].velocity, 0.5f));

        immutable NotationResult r9 = parseNotes("-", SIG_4_4);
        assert(r9.ok && r9.events.length == 0 && r9.totalLines == 4);

        immutable NotationResult r10 = parseNotes("", SIG_4_4);
        assert(r10.ok && r10.events.length == 0 && r10.totalLines == 0);

        immutable NotationResult r11 = parseNotes("   \t\n ", SIG_4_4);
        assert(r11.ok && r11.events.length == 0 && r11.totalLines == 0);

        immutable NotationResult r12 = parseNotes("C4@1 C4@0.05", SIG_4_4);
        assert(r12.ok && r12.events.length == 2);
        assert(velNear(r12.events[0].velocity, 1.0f));
        assert(velNear(r12.events[1].velocity, 0.05f));
    }

    unittest {
        assertPitchRefused(parsePitch(""), 0, 0, "C4");
        assertRefused(parseNotes("C4 c4", SIG_4_4), 3, 1, "C4");
        assertRefused(parseNotes("H4", SIG_4_4), 0, 1, "");
        assertRefused(parseNotes("C###4", SIG_4_4), 1, 3, "");
        assertRefused(parseNotes("C#b4", SIG_4_4), 1, 2, "");
        assertRefused(parseNotes("C", SIG_4_4), 1, 0, "C4");
        assertRefused(parseNotes("C4 F#", SIG_4_4), 5, 0, "F#4");
        assertRefused(parseNotes("C4x", SIG_4_4), 2, 1, "C4");
        assertRefused(parseNotes("[C4:1 E4]", SIG_4_4), 3, 2, "C4");
        assertRefused(parseNotes("G#9", SIG_4_4), 0, 3, "G9");
        assertRefused(parseNotes("Cb-1", SIG_4_4), 0, 4, "C-1");
        assertRefused(parseNotes("C-4", SIG_4_4), 0, 3, "C4");

        assertRefused(parseNotes("C4:", SIG_4_4), 3, 0, "1");
        assertRefused(parseNotes("C4:1/3", SIG_4_4), 3, 3, "1/4");
        assertRefused(parseNotes("C4:1/4", SIG_6_8), 3, 3, "1/2");
        assertRefused(parseNotes("C4:257b", SIG_4_4), 3, 4, "256b");

        assertRefused(parseNotes("C4@", SIG_4_4), 3, 0, "0.8");
        assertRefused(parseNotes("C4@x", SIG_4_4), 3, 1, "0.8");
        assertRefused(parseNotes("C4@1.5", SIG_4_4), 3, 3, "1");
        assertRefused(parseNotes("C4@0", SIG_4_4), 3, 1, "0.1");

        assertRefused(parseNotes("C4@0.6:1", SIG_4_4), 6, 1, "");
        assertRefused(parseNotes("-@0.5", SIG_4_4), 1, 4, "-");
        assertRefused(parseNotes("[C4 E4", SIG_4_4), 0, 6, "");
        assertRefused(parseNotes("[]", SIG_4_4), 0, 2, "[C4 E4 G4]");
        assertRefused(parseNotes("[C4]x", SIG_4_4), 4, 1, "");
        assertRefused(parseNotes("[C4 C4]", SIG_4_4), 4, 2, "");
        assertRefused(parseNotes("[C#4 Db4]", SIG_4_4), 5, 3, "");
        assertRefused(parseNotes("C4:256b -:1l", SIG_4_4), 8, 4, "");
        assertRefused(parseNotes("C4", TimeSignature(4, 3)), 0, 2, "4/4");
    }

    unittest {
        foreach (bad; ["", "c4", "C", "F#", "C4x", "G#9", "Cb-1", "C-4"]) {
            immutable PitchResult r = parsePitch(bad);
            assert(!r.ok && r.error.suggestion.length > 0);
            assert(parsePitch(r.error.suggestion).ok, bad);
        }

        foreach (bad; ["C4@", "C4@x", "C4@1.5", "C4@0"]) {
            immutable NotationResult r = parseNotes(bad, SIG_4_4);
            assert(!r.ok && r.error.suggestion.length > 0);
            assert(parseNotes("C4@" ~ r.error.suggestion, SIG_4_4).ok, bad);
        }

        foreach (bad; ["[]", "-@0.5"]) {
            immutable NotationResult r = parseNotes(bad, SIG_4_4);
            assert(!r.ok && r.error.suggestion.length > 0);
            assert(parseNotes(r.error.suggestion, SIG_4_4).ok, bad);
        }
    }

    unittest {
        static immutable string[8] TOKENS = ["C4", "-", "[C4 E4]", "[", "]", ":1", "@0.5", "x"];
        static immutable string[2] JOINS = [" ", ""];
        static immutable TimeSignature[2] SIGS = [SIG_4_4, SIG_6_8];

        foreach (sig; SIGS) {
            foreach (sep; JOINS) {
                foreach (a; TOKENS) {
                    foreach (b; TOKENS) {
                        foreach (c; TOKENS) {
                            immutable string text = a ~ sep ~ b ~ sep ~ c;
                            immutable NotationResult r = parseNotes(text, sig);
                            assert(r.ok || r.error.reason.length > 0, text);
                            assert(r.error.offset <= text.length, text);
                        }
                    }
                }
            }
        }
    }
}
