/**
 * File:         tests/unit/chord_progression_test.d
 * Module:       tests.unit.chord_progression_test
 * Phase:        Skeleton project generator — T14 (chord model and parser)
 *
 * Purpose:
 *   Verifies app.chord_progression: every chord quality in Roman-numeral and chord-name form in a major and a
 *   minor key, accidentals and Unicode aliases, slash basses, separators, error reasons and positions,
 *   resolveChord() in all 24 keys, the preset progressions (T16), and the two-form block labels (Roman chords follow the key, named chords keep
 *   their spelling).
 *
 * Real-Time & Safety Contract:
 *   Pure single-threaded checks.
 *
 * Dependencies:
 *   Internal: app.chord_progression, app.music_theory
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T03, T14)
 */
module tests.unit.chord_progression_test;

version (unittest) {
    import app.chord_progression;
    import app.music_theory : allKeys, degreePitchClass, KeyMode, MusicalKey;

    private immutable MusicalKey C_MAJOR = MusicalKey(0, KeyMode.major);
    private immutable MusicalKey A_MINOR = MusicalKey(9, KeyMode.minor);

    private Chord chord(string token) {
        Chord c;
        string reason;
        assert(parseChord(token, c, reason), token ~ ": " ~ reason);
        return c;
    }

    private ubyte[] pcs(string token, MusicalKey key) {
        Chord c = chord(token);
        return resolveChord(c, key).pitchClasses;
    }

    private string failure(string token) {
        Chord c;
        string reason;
        assert(!parseChord(token, c, reason), token);
        assert(reason.length > 0);
        return reason;
    }

    unittest {
        assert(pcs("I", C_MAJOR) == [0, 4, 7]);
        assert(pcs("ii", C_MAJOR) == [2, 5, 9]);
        assert(pcs("iii", C_MAJOR) == [4, 7, 11]);
        assert(pcs("IV", C_MAJOR) == [5, 9, 0]);
        assert(pcs("V7", C_MAJOR) == [7, 11, 2, 5]);
        assert(pcs("vi", C_MAJOR) == [9, 0, 4]);
        assert(pcs("vii°", C_MAJOR) == [11, 2, 5] && pcs("viidim", C_MAJOR) == [11, 2, 5]);
        assert(pcs("viiø7", C_MAJOR) == [11, 2, 5, 9] && pcs("viim7b5", C_MAJOR) == [11, 2, 5, 9]);
        assert(pcs("viiø", C_MAJOR) == [11, 2, 5, 9] && pcs("viim7♭5", C_MAJOR) == [11, 2, 5, 9]);
        assert(pcs("vii°7", C_MAJOR) == [11, 2, 5, 8] && pcs("viidim7", C_MAJOR) == [11, 2, 5, 8]);
        assert(pcs("Imaj7", C_MAJOR) == [0, 4, 7, 11]);
        assert(pcs("ii7", C_MAJOR) == [2, 5, 9, 0]);
        assert(pcs("Iaug", C_MAJOR) == [0, 4, 8] && pcs("I+", C_MAJOR) == [0, 4, 8]);
        assert(pcs("Isus2", C_MAJOR) == [0, 2, 7] && pcs("Vsus4", C_MAJOR) == [7, 0, 2]);
        assert(pcs("iisus4", C_MAJOR) == [2, 7, 9]);
        assert(pcs("bVII", C_MAJOR) == [10, 2, 5] && pcs("♭VII", C_MAJOR) == [10, 2, 5]);
        assert(pcs("bIII", C_MAJOR) == [3, 7, 10] && pcs("bVI", C_MAJOR) == [8, 0, 3]);
        assert(pcs("#iv°", C_MAJOR) == [6, 9, 0] && pcs("♯iv°", C_MAJOR) == [6, 9, 0]);

        assert(pcs("i", A_MINOR) == [9, 0, 4]);
        assert(pcs("ii°", A_MINOR) == [11, 2, 5]);
        assert(pcs("III", A_MINOR) == [0, 4, 7]);
        assert(pcs("iv7", A_MINOR) == [2, 5, 9, 0]);
        assert(pcs("v", A_MINOR) == [4, 7, 11] && pcs("V7", A_MINOR) == [4, 8, 11, 2]);
        assert(pcs("VI", A_MINOR) == [5, 9, 0] && pcs("VII", A_MINOR) == [7, 11, 2]);
    }

    unittest {
        assert(pcs("C", A_MINOR) == [0, 4, 7] && pcs("Dm", C_MAJOR) == [2, 5, 9]);
        assert(pcs("Bdim", C_MAJOR) == [11, 2, 5] && pcs("B°", C_MAJOR) == [11, 2, 5]);
        assert(pcs("Caug", C_MAJOR) == [0, 4, 8] && pcs("C+", C_MAJOR) == [0, 4, 8]);
        assert(pcs("Csus2", C_MAJOR) == [0, 2, 7] && pcs("Csus4", C_MAJOR) == [0, 5, 7]);
        assert(pcs("G7", C_MAJOR) == [7, 11, 2, 5] && pcs("Cmaj7", C_MAJOR) == [0, 4, 7, 11]);
        assert(pcs("Am7", C_MAJOR) == [9, 0, 4, 7]);
        foreach (t; ["Bm7b5", "Bm7♭5", "Bø", "Bø7"]) {
            assert(pcs(t, C_MAJOR) == [11, 2, 5, 9], t);
        }
        assert(pcs("Bdim7", C_MAJOR) == [11, 2, 5, 8] && pcs("B°7", C_MAJOR) == [11, 2, 5, 8]);
        assert(pcs("Bb", C_MAJOR) == [10, 2, 5] && pcs("F#m", C_MAJOR) == [6, 9, 1]);
        assert(pcs("Ebmaj7", C_MAJOR) == [3, 7, 10, 2] && pcs("C♯m", C_MAJOR) == [1, 4, 8]);
        assert(pcs("Cb", C_MAJOR) == [11, 3, 6] && pcs("E#", C_MAJOR) == [5, 9, 0]);

        Chord slash = chord("C/E");
        ResolvedChord r = resolveChord(slash, A_MINOR);
        assert(slash.hasBass && r.rootPc == 0 && r.bassPc == 4 && r.pitchClasses == [0, 4, 7]);
        Chord db = chord("Db/Ab");
        assert(resolveChord(db, C_MAJOR).bassPc == 8 && db.bassText == "Ab" && db.rootText == "Db");
        assert(resolveChord(db, C_MAJOR).rootPc == 1);
        Chord g = chord("G7");
        assert(!g.hasBass && resolveChord(g, C_MAJOR).bassPc == 7);
        assert(chord("C/B♭").bassText == "Bb" && chord("C/B♭").bassPc == 10);

        foreach (q; 0 .. 11) {
            immutable size_t n = chordIntervals(cast(ChordQuality) q).length;
            assert(chordIntervals(cast(ChordQuality) q)[0] == 0 && (n == 3 || n == 4));
        }
    }

    unittest {
        assert(failure("am") == "Chord names start with a capital letter A–G");
        assert(failure("Hm").length > 0 && failure("x").length > 0 && failure("b").length > 0);
        assert(failure("IIII") == "Roman numerals go from I to VII");
        assert(failure("VIII") == "Roman numerals go from I to VII");
        assert(failure("Iv") == "Mixed upper and lower case in a Roman numeral");
        assert(failure("Idim") == "Write diminished and half-diminished chords in lower case (vii°)");
        assert(failure("Iø7") == "Write diminished and half-diminished chords in lower case (vii°)");
        assert(failure("iimaj7") == "Write major, dominant 7, maj7 and augmented chords in upper case (V7)");
        assert(failure("iiaug") == "Write major, dominant 7, maj7 and augmented chords in upper case (V7)");
        assert(failure("V/V") == "Roman numerals have no slash form; type a chord name such as C/E");
        assert(failure("ii/C") == "Roman numerals have no slash form; type a chord name such as C/E");
        assert(failure("C/") == "After \"/\" write a bass note such as E or Bb");
        assert(failure("C/H") == "After \"/\" write a bass note such as E or Bb");
        assert(failure("C/Em") == "After \"/\" write a bass note such as E or Bb");
        assert(failure("Cxyz") == "Unknown chord type \"xyz\" (use m, dim, aug, sus2, sus4, 7, maj7, m7, m7b5 or dim7)");
        assert(failure("V9") == "Unknown chord type \"9\"");
        assert(failure("") == "Empty chord");
    }

    unittest {
        ChordBlock[] b;
        ProgressionError e;
        assert(parseProgression("iii -> vi -> ii -> V -> I", b, e));
        assert(b.length == 5 && b[0].chord.degree == 3 && b[3].chord.degree == 5 && b[4].chord.degree == 1);
        foreach (ref blk; b) {
            assert(blk.halfBars == 2 && blk.chord.form == ChordForm.roman);
        }
        assert(parseProgression("Dm7, G7, Cmaj7", b, e) && b.length == 3 && b[1].chord.text == "G7");
        assert(parseProgression("C-G-Am-F", b, e) && b.length == 4 && b[2].chord.quality == ChordQuality.minor);
        assert(parseProgression("C,,G\tAm\nF\r\n", b, e) && b.length == 4);
        assert(parseProgression("ii->V->I", b, e) && b.length == 3);
        assert(parseProgression("", b, e) && b.length == 0);
        assert(parseProgression("  ,  - ", b, e) && b.length == 0);
        assert(parseProgression("vii° Bø7 C/E", b, e) && b.length == 3 && b[2].chord.hasBass);

        assert(!parseProgression("C G Hm7 F", b, e) && b.length == 0);
        assert(e.position == 4 && e.length == 3 && e.message[0 .. 6] == "\"Hm7\":");
        assert(!parseProgression("C > G", b, e) && e.position == 2 && e.length == 1);
        assert(!parseProgression("> C", b, e) && e.position == 0);
        assert(!parseProgression("I ii Idim", b, e) && e.position == 5 && e.length == 4);
        assert(BLOCK_HALF_BARS == [1, 2, 4, 8]);
    }

    unittest {
        string label(string t, MusicalKey k) {
            Chord c = chord(t);
            return chordLabel(c, k);
        }

        assert(label("ii", C_MAJOR) == "ii · Dm");
        assert(label("V7", C_MAJOR) == "V7 · G7");
        assert(label("I", C_MAJOR) == "I · C");
        assert(label("vii°", C_MAJOR) == "vii° · Bdim");
        assert(label("viidim", C_MAJOR) == "vii° · Bdim");
        assert(label("viiø7", C_MAJOR) == "viiø7 · Bm7b5");
        assert(label("vii°7", C_MAJOR) == "vii°7 · Bdim7");
        assert(label("ii7", C_MAJOR) == "ii7 · Dm7");
        assert(label("Imaj7", C_MAJOR) == "Imaj7 · Cmaj7");
        assert(label("I+", C_MAJOR) == "I+ · Caug");
        assert(label("Vsus4", C_MAJOR) == "Vsus4 · Gsus4");
        assert(label("bVII", C_MAJOR) == "bVII · Bb");
        assert(label("#iv°", C_MAJOR) == "#iv° · F#dim");
        assert(label("ii", MusicalKey(7, KeyMode.major)) == "ii · Am");
        assert(label("vii°", MusicalKey(6, KeyMode.major)) == "vii° · E#dim");
        assert(label("IV", MusicalKey(5, KeyMode.major)) == "IV · Bb");
        assert(label("III", A_MINOR) == "III · C");
        assert(label("ii°", A_MINOR) == "ii° · Bdim");

        assert(label("Dm", C_MAJOR) == "ii · Dm");
        assert(label("G7", C_MAJOR) == "V7 · G7");
        assert(label("Bb", C_MAJOR) == "bVII · Bb");
        assert(label("A#", C_MAJOR) == "bVII · A#");
        assert(label("C/E", C_MAJOR) == "I · C/E");
        assert(label("Dm", MusicalKey(2, KeyMode.minor)) == "i · Dm");
        assert(label("Bø", C_MAJOR) == "viiø7 · Bm7b5");
        assert(label("C+", C_MAJOR) == "I+ · Caug");
        assert(label("C♯m", MusicalKey(4, KeyMode.major)) == "vi · C#m");
    }

    unittest {
        static immutable string[] qualitiesUpper = ["", "7", "maj7", "aug", "+", "sus2", "sus4"];
        static immutable string[] qualitiesLower = ["", "7", "dim", "°", "dim7", "°7", "m7b5", "ø", "ø7", "sus2",
            "sus4"];
        static immutable string[7] numerals = ["I", "II", "III", "IV", "V", "VI", "VII"];
        static immutable string[7] lowerNumerals = ["i", "ii", "iii", "iv", "v", "vi", "vii"];
        foreach (k; allKeys()) {
            foreach (d; 0 .. 7) {
                foreach (acc; ["", "b", "#"]) {
                    immutable int shift = acc == "b" ? -1 : (acc == "#" ? 1 : 0);
                    foreach (q; qualitiesUpper) {
                        Chord c = chord(acc ~ numerals[d] ~ q);
                        ResolvedChord r = resolveChord(c, k);
                        assert(r.rootPc == (degreePitchClass(k, cast(uint)(d + 1)) + shift + 12) % 12);
                        assert(r.bassPc == r.rootPc && r.pitchClasses[0] == r.rootPc);
                        assert(r.pitchClasses.length == chordIntervals(c.quality).length);
                        assert(chordLabel(c, k).length > 0);
                    }
                    foreach (q; qualitiesLower) {
                        Chord c = chord(acc ~ lowerNumerals[d] ~ q);
                        ResolvedChord r = resolveChord(c, k);
                        assert(r.rootPc == (degreePitchClass(k, cast(uint)(d + 1)) + shift + 12) % 12);
                        assert(r.pitchClasses.length == chordIntervals(c.quality).length);
                        foreach (i, pc; r.pitchClasses) {
                            assert(pc == (r.rootPc + chordIntervals(c.quality)[i]) % 12);
                        }
                    }
                }
            }
            Chord named = chord("F#m7");
            assert(resolveChord(named, k).pitchClasses == [6, 9, 1, 4]);
            assert(nameLabel(named, k) == "F#m7");
        }
    }

    unittest {
        assert(PROGRESSION_PRESETS.length == 11);
        assert(presetsFor(KeyMode.major).length == 8 && presetsFor(KeyMode.minor).length == 3);
        foreach (ref p; PROGRESSION_PRESETS) {
            ChordBlock[] b = presetBlocks(p);
            assert(b.length >= 3, p.name);
            ChordBlock[] direct;
            ProgressionError e;
            assert(parseProgression(p.text, direct, e), p.name ~ ": " ~ e.message);
            assert(direct.length == b.length);
            foreach (ref blk; b) {
                assert(blk.chord.form == ChordForm.roman && blk.halfBars == 2);
            }
            foreach (k; allKeys()) {
                if (k.mode != p.mode) {
                    continue;
                }
                foreach (ref blk; b) {
                    ResolvedChord r = resolveChord(blk.chord, k);
                    assert(r.pitchClasses.length >= 3 && chordLabel(blk.chord, k).length > 0);
                }
            }
            assert(presetLabel(p) == p.name ~ ": " ~ p.text);
        }
        foreach (ref p; presetsFor(KeyMode.minor)) {
            assert(p.mode == KeyMode.minor);
        }

        string[] names(const ref ProgressionPreset p, MusicalKey k) {
            string[] out_;
            foreach (ref blk; presetBlocks(p)) {
                out_ ~= nameLabel(blk.chord, k);
            }
            return out_;
        }
        assert(PROGRESSION_PRESETS[0].name == "Circle of fifths");
        assert(names(PROGRESSION_PRESETS[0], C_MAJOR) == ["Em", "Am", "Dm", "G", "C"]);
        assert(names(PROGRESSION_PRESETS[1], MusicalKey(7, KeyMode.major)) == ["G", "D", "Em", "C"]);
        assert(names(PROGRESSION_PRESETS[6], C_MAJOR) == ["C", "G", "Am", "Em", "F", "C", "F", "G"]);
        assert(names(PROGRESSION_PRESETS[7], MusicalKey(5, KeyMode.major))
            == ["F7", "F7", "F7", "F7", "Bb7", "Bb7", "F7", "F7", "C7", "Bb7", "F7", "C7"]);
        assert(names(PROGRESSION_PRESETS[8], A_MINOR) == ["Am", "F", "C", "G"]);
        assert(names(PROGRESSION_PRESETS[9], A_MINOR) == ["Am", "Dm", "Em"]);
        assert(names(PROGRESSION_PRESETS[10], A_MINOR) == ["Am", "G", "F", "E"]);
        assert(names(PROGRESSION_PRESETS[10], MusicalKey(2, KeyMode.minor)) == ["Dm", "C", "Bb", "A"]);
        ChordBlock[] andalusian = presetBlocks(PROGRESSION_PRESETS[10]);
        assert(resolveChord(andalusian[3].chord, A_MINOR).pitchClasses == [4, 8, 11]);
    }
}
