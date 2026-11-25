/**
 * File:         tests/unit/music_theory_test.d
 * Module:       tests.unit.music_theory_test
 * Phase:        Skeleton project generator — T11 (keys, scales, and note spelling)
 *
 * Purpose:
 *   Verifies app.music_theory for all 24 keys: key list and names, sharp/flat preference, scale pitch classes,
 *   degree lookup, diatonic spelling (seven distinct letters per scale, every spelled name naming its pitch
 *   class), spelling of non-scale tones, octave numbering, and that KeyMode values match the .msv MUSC
 *   chunk constants.
 *
 * Real-Time & Safety Contract:
 *   Pure single-threaded checks; no session, audio, or files.
 *
 * Dependencies:
 *   Internal: app.music_theory, io.project_format (KEY_MODE_MAJOR, KEY_MODE_MINOR)
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T02, T11)
 */
module tests.unit.music_theory_test;

version (unittest) {
    import app.music_theory;
    import io.project_format : KEY_MODE_MAJOR, KEY_MODE_MINOR;

    private immutable ubyte[7] NATURALS = [0, 2, 4, 5, 7, 9, 11];

    private int pitchOfName(string name) {
        immutable size_t letter = indexOfLetter(name[0]);
        int pc = NATURALS[letter];
        foreach (c; name[1 .. $]) {
            if (c == '#') {
                pc++;
            } else if (c == 'b') {
                pc--;
            }
        }
        return ((pc % 12) + 12) % 12;
    }

    private size_t indexOfLetter(char c) {
        foreach (i, l; "CDEFGAB") {
            if (l == c) {
                return i;
            }
        }
        assert(false, "not a note letter");
    }

    private string[7] spelledScale(MusicalKey k) {
        string[7] names;
        immutable ubyte[7] pcs = scalePitchClasses(k);
        foreach (i; 0 .. 7) {
            names[i] = pitchClassName(pcs[i], k);
        }
        return names;
    }

    unittest {
        assert(cast(ubyte) KeyMode.major == KEY_MODE_MAJOR && cast(ubyte) KeyMode.minor == KEY_MODE_MINOR);
        assert(MusicalKey.init.tonic == 0 && MusicalKey.init.mode == KeyMode.major && MusicalKey.init.isValid());
        assert(!MusicalKey(12, KeyMode.major).isValid() && !MusicalKey(0, cast(KeyMode) 2).isValid());

        immutable MusicalKey[24] keys = allKeys();
        foreach (i, k; keys) {
            assert(k.isValid() && k.tonic == i / 2 && k.mode == (i % 2 == 0 ? KeyMode.major : KeyMode.minor));
            foreach (j; 0 .. i) {
                assert(keys[j] != k);
            }
        }
    }

    unittest {
        foreach (k; allKeys()) {
            immutable ubyte[7] pcs = scalePitchClasses(k);
            assert(pcs[0] == k.tonic);
            foreach (i; 0 .. 7) {
                assert(degreePitchClass(k, cast(uint)(i + 1)) == pcs[i]);
                assert(degreePitchClass(k, cast(uint)(i + 8)) == pcs[i]);
                foreach (j; 0 .. i) {
                    assert(pcs[j] != pcs[i]);
                }
            }
            assert(degreePitchClass(k, 0) == k.tonic);

            immutable string[7] names = spelledScale(k);
            bool[7] lettersSeen;
            foreach (i, n; names) {
                assert(n.length >= 1 && n.length <= 2, n);
                assert(pitchOfName(n) == pcs[i], n);
                immutable size_t l = indexOfLetter(n[0]);
                assert(!lettersSeen[l], keyName(k));
                lettersSeen[l] = true;
                if (usesFlats(k)) {
                    assert(n.length == 1 || n[1] == 'b', keyName(k) ~ " " ~ n);
                } else {
                    assert(n.length == 1 || n[1] == '#', keyName(k) ~ " " ~ n);
                }
            }
            assert(names[0] == tonicName(k.tonic, k.mode));

            immutable MusicalKey rel = relativeKey(k);
            assert(rel.mode != k.mode && relativeKey(rel) == k && usesFlats(rel) == usesFlats(k));
            immutable ubyte[7] relPcs = scalePitchClasses(rel);
            foreach (pc; pcs) {
                bool found = false;
                foreach (q; relPcs) {
                    found = found || q == pc;
                }
                assert(found);
            }
            foreach (pc; 0 .. 12) {
                immutable string n = pitchClassName(cast(ubyte) pc, k);
                assert(pitchOfName(n) == pc, keyName(k) ~ " " ~ n);
            }
        }
    }

    unittest {
        assert(spelledScale(MusicalKey(0, KeyMode.major)) == ["C", "D", "E", "F", "G", "A", "B"]);
        assert(spelledScale(MusicalKey(9, KeyMode.minor)) == ["A", "B", "C", "D", "E", "F", "G"]);
        assert(spelledScale(MusicalKey(5, KeyMode.major)) == ["F", "G", "A", "Bb", "C", "D", "E"]);
        assert(spelledScale(MusicalKey(6, KeyMode.major)) == ["F#", "G#", "A#", "B", "C#", "D#", "E#"]);
        assert(spelledScale(MusicalKey(1, KeyMode.major)) == ["Db", "Eb", "F", "Gb", "Ab", "Bb", "C"]);
        assert(spelledScale(MusicalKey(10, KeyMode.minor)) == ["Bb", "C", "Db", "Eb", "F", "Gb", "Ab"]);
        assert(spelledScale(MusicalKey(3, KeyMode.minor)) == ["D#", "E#", "F#", "G#", "A#", "B", "C#"]);
        assert(spelledScale(MusicalKey(0, KeyMode.minor)) == ["C", "D", "Eb", "F", "G", "Ab", "Bb"]);

        foreach (t; [5, 10, 3, 8, 1]) {
            assert(usesFlats(MusicalKey(cast(ubyte) t, KeyMode.major)));
        }
        foreach (t; [2, 7, 0, 5, 10]) {
            assert(usesFlats(MusicalKey(cast(ubyte) t, KeyMode.minor)));
        }
        size_t flatKeys = 0;
        foreach (k; allKeys()) {
            flatKeys += usesFlats(k) ? 1 : 0;
        }
        assert(flatKeys == 10);

        assert(keyName(MusicalKey.init) == "C major");
        assert(keyName(MusicalKey(9, KeyMode.minor)) == "A minor");
        assert(keyName(MusicalKey(10, KeyMode.major)) == "Bb major");
        assert(keyName(MusicalKey(6, KeyMode.minor)) == "F# minor");
        assert(keyName(MusicalKey(1, KeyMode.minor)) == "C# minor");
        assert(keyName(MusicalKey(1, KeyMode.major)) == "Db major");
        assert(tonicChoices(KeyMode.major) == ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]);
        assert(tonicChoices(KeyMode.minor) == ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "Bb", "B"]);
    }

    unittest {
        immutable MusicalKey c = MusicalKey.init;
        immutable MusicalKey f = MusicalKey(5, KeyMode.major);
        immutable MusicalKey a = MusicalKey(9, KeyMode.minor);
        immutable MusicalKey fs = MusicalKey(6, KeyMode.major);
        assert(noteName(60, c) == "C4" && noteName(69, c) == "A4" && noteName(0, c) == "C-1");
        assert(noteName(127, c) == "G9" && noteName(61, c) == "C#4");
        assert(noteName(70, f) == "Bb4" && noteName(58, f) == "Bb3" && noteName(61, f) == "Db4");
        assert(noteName(58, a) == "A#3" && pitchClassName(10, a) == "A#");
        assert(noteName(65, fs) == "E#4" && noteName(66, fs) == "F#4");
        assert(pitchClassOf(60) == 0 && pitchClassOf(71) == 11 && pitchClassOf(-1) == 11 && pitchClassOf(-12) == 0);
    }
}
