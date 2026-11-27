/**
 * File:         tests/unit/compose_chord_test.d
 * Module:       tests.unit.compose_chord_test
 * Phase:        Composition helper (dracker-compose) — T78 (Chord writing unit tests)
 *
 * Purpose:
 *   Verifies compose.chord_writer: chord length suffixes (`:2`, `:1/2`), `|` barlines, Roman numerals
 *   following project key, all four T78 styles (`hold`, `pulse` with `every=`, `root`, `root5`), `octave=`
 *   and `voices=3|4` in root position, preset progressions by name, exact note-by-note output in major,
 *   minor, and 3/4 time signatures, bass/keys root agreement across shared progressions (including slash
 *   chords), and structured error refusals.
 *
 * Real-Time & Safety Contract:
 *   Off-RT unit tests; no filesystem I/O.
 *
 * Dependencies:
 *   Internal: app.music_theory (KeyMode, MusicalKey), compose.chord_writer, compose.module_writer
 *             (ModuleWriter), compose.part_writer (PartNote, PartWriter), compose.project_writer
 *             (ProjectWriter), compose.timing (BeatPosition, Length, TimeSignature)
 *   External: std.algorithm (canFind)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) tests covering T78 styles, keys, meters, presets, and error cases
 *
 * See_Also:
 *   docs/todo.md (T69, T78), source/compose/chord_writer.d
 */
module tests.unit.compose_chord_test;

version (unittest) {
    import std.algorithm : canFind;

    import app.music_theory : KeyMode, MusicalKey;
    import compose.chord_writer : ArpDirection, ChordOptions, ChordProblemKind, ChordProgressionResult,
        ChordStyle, ChordVoicing, ChordWriteResult, parseArpDirection, parseChordStyle,
        parseChordVoicing, parseTimedProgression, presetTimedProgression, realizeChords, writeChords,
        writePresetChords;
    import compose.module_writer : ModuleWriter;
    import compose.part_writer : PartNote, PartWriter;
    import compose.project_writer : ProjectWriter;
    import compose.timing : BeatPosition, Length, TimeSignature;

    private PartWriter makeChordBand(MusicalKey key, TimeSignature sig) {
        ProjectWriter proj = new ProjectWriter();
        assert(proj.setKey(key).ok);
        assert(proj.setTimeSignature(sig).ok);
        auto keysMod = ModuleWriter.fromType("synth.fm_synth");
        auto bassMod = ModuleWriter.fromType("synth.analog_gen");
        assert(keysMod.ok && bassMod.ok);
        assert(proj.addModule("keys", keysMod.writer).ok);
        assert(proj.addModule("bass", bassMod.writer).ok);
        PartWriter pw = new PartWriter(proj);
        assert(pw.addPart("keys", "keys").ok);
        assert(pw.addPart("bass", "bass").ok);
        return pw;
    }

    private ubyte[] pitchesAtLine(const(PartNote)[] notes, uint line) {
        ubyte[] ps;
        foreach (ref n; notes) {
            if (n.line == line) {
                ps ~= n.pitch;
            }
        }
        return ps;
    }

    unittest {
        immutable ChordProgressionResult parsed = parseTimedProgression("| Dm7:1/2 G7:1/2 | Cmaj7:2 |",
            TimeSignature(4, 4));
        assert(parsed.ok, parsed.problem.reason);
        assert(parsed.chords.length == 3);
        assert(parsed.chords[0].lines == 8);
        assert(parsed.chords[1].lines == 8);
        assert(parsed.chords[2].lines == 32);
        assert(parsed.totalLines == 48);

        immutable ChordProgressionResult badChord = parseTimedProgression("I - H7", TimeSignature(4, 4));
        assert(!badChord.ok && badChord.problem.kind == ChordProblemKind.invalidChord);
        assert(badChord.problem.offset == 4);

        immutable ChordProgressionResult badLen = parseTimedProgression("C:1/3", TimeSignature(4, 4));
        assert(!badLen.ok && badLen.problem.kind == ChordProblemKind.invalidBarLength);

        immutable ChordProgressionResult emptyProg = parseTimedProgression("  |  ", TimeSignature(4, 4));
        assert(!emptyProg.ok && emptyProg.problem.kind == ChordProblemKind.emptyProgression);

        ChordStyle st;
        import compose.chord_writer : ChordProblem;
        ChordProblem stProb;
        assert(parseChordStyle("ROOT5", st, stProb) && st == ChordStyle.root5);
        assert(!parseChordStyle("puls", st, stProb) && stProb.suggestion == "pulse");
    }

    unittest {
        PartWriter pw = makeChordBand(MusicalKey(0, KeyMode.major), TimeSignature(4, 4));
        assert(pw.addSection("verse", 2).ok);

        ChordOptions holdOpts;
        holdOpts.style = ChordStyle.hold;
        holdOpts.voicing = ChordVoicing.root;
        holdOpts.hasOctave = true;
        holdOpts.octave = 4;
        immutable ChordWriteResult rHold = writeChords(pw, "keys", "verse", "I - IV", holdOpts);
        assert(rHold.ok, rHold.problem.reason);
        assert(rHold.eventCount == 2 && rHold.totalLines == 32);

        PartNote[] kn = pw.notesOfPart("keys", "verse");
        assert(kn.length == 6);
        assert(pitchesAtLine(kn, 0) == [60, 64, 67]);
        assert(pitchesAtLine(kn, 16) == [65, 69, 72]);
        foreach (ref n; kn) {
            assert(n.lengthLines == 16);
        }

        PartWriter pw2 = makeChordBand(MusicalKey(0, KeyMode.major), TimeSignature(4, 4));
        assert(pw2.addSection("v", 2).ok);
        ChordOptions fourOpts;
        fourOpts.style = ChordStyle.hold;
        fourOpts.voices = 4;
        assert(writeChords(pw2, "keys", "v", "I - V7", fourOpts).ok);
        PartNote[] v4 = pw2.notesOfPart("keys", "v");
        assert(pitchesAtLine(v4, 0) == [60, 64, 67, 72]);
        assert(pitchesAtLine(v4, 16) == [67, 71, 74, 77]);

        ChordOptions threeOpts;
        threeOpts.style = ChordStyle.hold;
        threeOpts.voices = 3;
        PartWriter pw3 = makeChordBand(MusicalKey(0, KeyMode.major), TimeSignature(4, 4));
        assert(pw3.addSection("v", 1).ok);
        assert(writeChords(pw3, "keys", "v", "G7", threeOpts).ok);
        assert(pitchesAtLine(pw3.notesOfPart("keys", "v"), 0) == [67, 71, 74]);
    }

    unittest {
        PartWriter minorPw = makeChordBand(MusicalKey(9, KeyMode.minor), TimeSignature(4, 4));
        assert(minorPw.addSection("verse", 4).ok);

        ChordOptions pulseOpts;
        pulseOpts.style = ChordStyle.pulse;
        pulseOpts.every = Length(8);
        pulseOpts.hasOctave = true;
        pulseOpts.octave = 3;
        assert(writeChords(minorPw, "keys", "verse", "i - VI - III - VII", pulseOpts).ok);

        ChordOptions root5Opts;
        root5Opts.style = ChordStyle.root5;
        root5Opts.every = Length(8);
        root5Opts.hasOctave = true;
        root5Opts.octave = 2;
        assert(writeChords(minorPw, "bass", "verse", "i - VI - III - VII", root5Opts).ok);

        PartNote[] kn = minorPw.notesOfPart("keys", "verse");
        assert(kn.length == 24);
        assert(pitchesAtLine(kn, 0) == [57, 60, 64]);
        assert(pitchesAtLine(kn, 8) == [57, 60, 64]);
        assert(pitchesAtLine(kn, 16) == [53, 57, 60]);
        assert(pitchesAtLine(kn, 32) == [48, 52, 55]);
        assert(pitchesAtLine(kn, 48) == [55, 59, 62]);

        PartNote[] bn = minorPw.notesOfPart("bass", "verse");
        assert(bn.length == 8);
        assert(bn[0].line == 0 && bn[0].pitch == 45 && bn[0].lengthLines == 8);
        assert(bn[1].line == 8 && bn[1].pitch == 52 && bn[1].lengthLines == 8);
        assert(bn[2].line == 16 && bn[2].pitch == 41);
        assert(bn[3].line == 24 && bn[3].pitch == 48);
        assert(bn[4].line == 32 && bn[4].pitch == 36);
        assert(bn[5].line == 40 && bn[5].pitch == 43);
        assert(bn[6].line == 48 && bn[6].pitch == 43);
        assert(bn[7].line == 56 && bn[7].pitch == 50);

        foreach (barIdx; 0 .. 4) {
            immutable uint line = cast(uint)(barIdx * 16);
            assert(pitchesAtLine(bn, line)[0] % 12 == pitchesAtLine(kn, line)[0] % 12);
        }
    }

    unittest {
        PartWriter waltz = makeChordBand(MusicalKey(2, KeyMode.major), TimeSignature(3, 4));
        assert(waltz.addSection("a", 2).ok);

        ChordOptions keysPulse;
        keysPulse.style = ChordStyle.pulse;
        assert(writeChords(waltz, "keys", "a", "I:1/2 V:1/2 | IV", keysPulse).ok);

        ChordOptions bassRoot;
        bassRoot.style = ChordStyle.root;
        assert(writeChords(waltz, "bass", "a", "I:1/2 V:1/2 | IV", bassRoot).ok);

        PartNote[] kn = waltz.notesOfPart("keys", "a");
        assert(pitchesAtLine(kn, 0) == [62, 66, 69]);
        assert(pitchesAtLine(kn, 4) == [62, 66, 69]);
        assert(pitchesAtLine(kn, 6) == [69, 73, 76]);
        assert(pitchesAtLine(kn, 10) == [69, 73, 76]);
        assert(pitchesAtLine(kn, 12) == [67, 71, 74]);
        assert(pitchesAtLine(kn, 16) == [67, 71, 74]);
        assert(pitchesAtLine(kn, 20) == [67, 71, 74]);

        PartNote[] bn = waltz.notesOfPart("bass", "a");
        assert(bn.length == 3);
        assert(bn[0].line == 0 && bn[0].lengthLines == 6 && bn[0].pitch == 38);
        assert(bn[1].line == 6 && bn[1].lengthLines == 6 && bn[1].pitch == 45);
        assert(bn[2].line == 12 && bn[2].lengthLines == 12 && bn[2].pitch == 43);
        assert(bn[0].pitch % 12 == 2 && bn[1].pitch % 12 == 9 && bn[2].pitch % 12 == 7);
    }

    unittest {
        PartWriter pw = makeChordBand(MusicalKey(7, KeyMode.major), TimeSignature(4, 4));
        assert(pw.addSection("bridge", 5).ok);

        ChordOptions presetOpts;
        presetOpts.style = ChordStyle.root;
        immutable ChordWriteResult okPreset = writePresetChords(pw, "bass", "bridge",
            "circle of fifths", presetOpts);
        assert(okPreset.ok, okPreset.problem.reason);
        PartNote[] bn = pw.notesOfPart("bass", "bridge");
        assert(bn.length == 5);
        assert(bn[0].pitch == 47 && bn[1].pitch == 40 && bn[2].pitch == 45
            && bn[3].pitch == 38 && bn[4].pitch == 43);

        immutable ChordProgressionResult badPreset = presetTimedProgression("Circl of fifths",
            TimeSignature(4, 4));
        assert(!badPreset.ok && badPreset.problem.kind == ChordProblemKind.unknownPreset);
        assert(badPreset.problem.suggestion == "Circle of fifths");

        ChordOptions badVoices;
        badVoices.voices = 5;
        immutable ChordWriteResult vErr = writeChords(pw, "keys", "bridge", "I", badVoices);
        assert(!vErr.ok && vErr.problem.kind == ChordProblemKind.invalidVoices);

        ChordOptions badOct;
        badOct.hasOctave = true;
        badOct.octave = 10;
        immutable ChordWriteResult oErr = writeChords(pw, "keys", "bridge", "I", badOct);
        assert(!oErr.ok && oErr.problem.kind == ChordProblemKind.pitchOutOfRange);

        ChordOptions slashOpts;
        slashOpts.style = ChordStyle.root;
        PartWriter slashPw = makeChordBand(MusicalKey(0, KeyMode.major), TimeSignature(4, 4));
        assert(writeChords(slashPw, "bass", "", "C/E", slashOpts).ok);
        assert(slashPw.notesOfPart("bass", "")[0].pitch == 40);
    }

    unittest {
        ArpDirection d;
        ChordVoicing v;
        import compose.chord_writer : ChordProblem;
        ChordProblem prob;
        assert(parseArpDirection("UPDOWN", d, prob) && d == ArpDirection.updown);
        assert(!parseArpDirection("updn", d, prob) && prob.kind == ChordProblemKind.invalidDirection);
        assert(parseChordVoicing("CLOSE", v, prob) && v == ChordVoicing.close);
        assert(!parseChordVoicing("clos", v, prob) && prob.suggestion == "close");

        PartWriter arpPw = makeChordBand(MusicalKey(0, KeyMode.major), TimeSignature(4, 4));
        assert(arpPw.addSection("a", 1).ok);
        ChordOptions upOpts;
        upOpts.style = ChordStyle.arp;
        upOpts.arpDir = ArpDirection.up;
        upOpts.every = Length(4);
        assert(writeChords(arpPw, "keys", "a", "C", upOpts).ok);
        PartNote[] upNotes = arpPw.notesOfPart("keys", "a");
        assert(upNotes.length == 4);
        assert(upNotes[0].pitch == 60 && upNotes[1].pitch == 64
            && upNotes[2].pitch == 67 && upNotes[3].pitch == 60);

        PartWriter downPw = makeChordBand(MusicalKey(0, KeyMode.major), TimeSignature(4, 4));
        assert(downPw.addSection("a", 1).ok);
        ChordOptions downOpts;
        downOpts.style = ChordStyle.arp;
        downOpts.arpDir = ArpDirection.down;
        downOpts.every = Length(4);
        assert(writeChords(downPw, "keys", "a", "C", downOpts).ok);
        PartNote[] dnNotes = downPw.notesOfPart("keys", "a");
        assert(dnNotes[0].pitch == 67 && dnNotes[1].pitch == 64
            && dnNotes[2].pitch == 60 && dnNotes[3].pitch == 67);

        PartWriter udPw = makeChordBand(MusicalKey(0, KeyMode.major), TimeSignature(4, 4));
        assert(udPw.addSection("a", 1).ok);
        ChordOptions udOpts;
        udOpts.style = ChordStyle.arp;
        udOpts.arpDir = ArpDirection.updown;
        udOpts.every = Length(4);
        assert(writeChords(udPw, "keys", "a", "C", udOpts).ok);
        PartNote[] udNotes = udPw.notesOfPart("keys", "a");
        assert(udNotes[0].pitch == 60 && udNotes[1].pitch == 64
            && udNotes[2].pitch == 67 && udNotes[3].pitch == 64);

        PartWriter rPw = makeChordBand(MusicalKey(0, KeyMode.major), TimeSignature(4, 4));
        assert(rPw.addSection("r", 1).ok);
        ChordOptions rHold;
        rHold.style = ChordStyle.hold;
        rHold.rhythm = "x-x-x---";
        assert(writeChords(rPw, "keys", "r", "C", rHold).ok);
        PartNote[] rh = rPw.notesOfPart("keys", "r");
        assert(pitchesAtLine(rh, 0) == [60, 64, 67]);
        assert(pitchesAtLine(rh, 2) == [60, 64, 67]);
        assert(pitchesAtLine(rh, 4) == [60, 64, 67]);
        assert(pitchesAtLine(rh, 8) == [60, 64, 67]);
        assert(pitchesAtLine(rh, 1) == [] && pitchesAtLine(rh, 6) == []);
        assert(rh[0].lengthLines == 2);

        ChordOptions rRoot;
        rRoot.style = ChordStyle.root;
        rRoot.rhythm = "X---x---";
        assert(writeChords(rPw, "bass", "r", "C", rRoot).ok);
        PartNote[] rb = rPw.notesOfPart("bass", "r");
        assert(rb.length == 4 && rb[0].line == 0 && rb[0].pitch == 36 && rb[0].velocity > 0.95f
            && rb[1].line == 4 && rb[1].lengthLines == 4);

        PartWriter pPw = makeChordBand(MusicalKey(0, KeyMode.major), TimeSignature(4, 4));
        assert(pPw.addSection("p", 1).ok);
        ChordOptions rPulse;
        rPulse.style = ChordStyle.pulse;
        rPulse.every = Length(1);
        rPulse.rhythm = "x---x---";
        assert(writeChords(pPw, "keys", "p", "C", rPulse).ok);
        foreach (n; pPw.notesOfPart("keys", "p")) {
            assert(n.lengthLines == 1);
        }

        ChordOptions badRhythmLen;
        badRhythmLen.style = ChordStyle.hold;
        badRhythmLen.rhythm = "x-x-x--";
        immutable ChordWriteResult badRL = writeChords(pPw, "keys", "p", "C", badRhythmLen);
        assert(!badRL.ok && badRL.problem.kind == ChordProblemKind.invalidRhythm);

        PartWriter waltzR = makeChordBand(MusicalKey(2, KeyMode.major), TimeSignature(3, 4));
        assert(waltzR.addSection("w", 1).ok);
        ChordOptions waltzBadLen;
        waltzBadLen.style = ChordStyle.hold;
        waltzBadLen.rhythm = "x---x---x---x---";
        immutable ChordWriteResult badWR = writeChords(waltzR, "keys", "w", "D", waltzBadLen);
        assert(!badWR.ok && badWR.problem.kind == ChordProblemKind.invalidRhythm);

        PartWriter closePw = makeChordBand(MusicalKey(0, KeyMode.major), TimeSignature(4, 4));
        assert(closePw.addSection("c", 4).ok);
        PartWriter rootPw = makeChordBand(MusicalKey(0, KeyMode.major), TimeSignature(4, 4));
        assert(rootPw.addSection("c", 4).ok);
        ChordOptions closeOpts;
        closeOpts.style = ChordStyle.hold;
        closeOpts.voicing = ChordVoicing.close;
        ChordOptions rootOpts;
        rootOpts.style = ChordStyle.hold;
        rootOpts.voicing = ChordVoicing.root;
        assert(writeChords(closePw, "keys", "c", "I - IV - V - I", closeOpts).ok);
        assert(writeChords(rootPw, "keys", "c", "I - IV - V - I", rootOpts).ok);

        int maxMoveCloseAll = 0;
        foreach (b; 0 .. 3) {
            ubyte[] prevC = pitchesAtLine(closePw.notesOfPart("keys", "c"), cast(uint)(b * 16));
            ubyte[] nextC = pitchesAtLine(closePw.notesOfPart("keys", "c"), cast(uint)((b + 1) * 16));
            ubyte[] prevR = pitchesAtLine(rootPw.notesOfPart("keys", "c"), cast(uint)(b * 16));
            ubyte[] nextR = pitchesAtLine(rootPw.notesOfPart("keys", "c"), cast(uint)((b + 1) * 16));
            assert(prevC.length == 3 && nextC.length == 3);
            int maxC = 0;
            int maxR = 0;
            foreach (vi; 0 .. 3) {
                int dc = cast(int) nextC[vi] - cast(int) prevC[vi];
                int dr = cast(int) nextR[vi] - cast(int) prevR[vi];
                if (dc < 0) dc = -dc;
                if (dr < 0) dr = -dr;
                if (dc > maxC) maxC = dc;
                if (dr > maxR) maxR = dr;
            }
            assert(maxC <= maxR);
            if (maxC > maxMoveCloseAll) maxMoveCloseAll = maxC;
        }
        assert(maxMoveCloseAll < 5);
    }
}
