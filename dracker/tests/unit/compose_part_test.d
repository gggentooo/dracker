/**
 * File:         tests/unit/compose_part_test.d
 * Module:       tests.unit.compose_part_test
 * Phase:        Composition helper (dracker-compose) — T77 (Sections, parts, and their patterns)
 *
 * Purpose:
 *   Unit tests for compose.part_writer: section declarations, pattern naming ("<part> · <section>" and
 *   implicit "<part>"), pattern sizing across 4/4, 3/4 and 6/8 time signatures, lazy creation on first use,
 *   part isolation (two parts never share a pattern even when bound to the same module), MAX_LINES overflow
 *   refusals with nearest valid bar count, case/space-insensitive lookups, and unknown/duplicate name refusals
 *   with nearest-name suggestions.
 *
 * Real-Time & Safety Contract:
 *   Off-RT unit tests; no filesystem I/O.
 *
 * Dependencies:
 *   Internal: app.pattern_notes (PatternGrid), compose.module_writer (ModuleWriter), compose.part_writer,
 *             compose.project_writer (ProjectWriter), compose.timing (TimeSignature), io.project_format
 *             (MAX_LINES, SavedPattern)
 *   External: std.algorithm (canFind)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) tests covering all T77 requirements
 *
 * See_Also:
 *   docs/todo.md (T68, T77), source/compose/part_writer.d
 */
module tests.unit.compose_part_test;

version (unittest) {
    import std.algorithm : canFind;

    import app.pattern_notes : PatternGrid;
    import compose.module_writer : ModuleWriter;
    import compose.part_writer : formatPartPatternName, MAX_PART_NAME_LENGTH, PartEditResult, PartInfo,
        PartPatternInfo, PartPatternResult, PartProblem, PartProblemKind, PartResult, PartWriter,
        PATTERN_NAME_SEPARATOR, SectionInfo, SectionResult;
    import compose.project_writer : ProjectWriter;
    import compose.timing : TimeSignature;
    import io.project_format : MAX_LINES, PATTERN_KIND_NORMAL, SavedPattern;

    private ProjectWriter makeProjectWithSynths() {
        ProjectWriter proj = new ProjectWriter();
        auto bassMod = ModuleWriter.fromType("synth.analog_gen");
        assert(bassMod.ok);
        auto keysMod = ModuleWriter.fromType("synth.fm_synth");
        assert(keysMod.ok);
        assert(proj.addModule("bass", bassMod.writer).ok);
        assert(proj.addModule("keys", keysMod.writer).ok);
        return proj;
    }

    unittest {
        ProjectWriter proj = makeProjectWithSynths();
        PartWriter pw = new PartWriter(proj);

        immutable SectionResult verse = pw.addSection("verse", 4);
        assert(verse.ok);
        assert(verse.section.name == "verse");
        assert(verse.section.bars == 4);
        assert(verse.section.lines == 64);
        assert(!verse.section.isImplicit);

        immutable SectionResult chorus = pw.addSection("chorus", 8);
        assert(chorus.ok);
        assert(chorus.section.lines == 128);
        assert(pw.sectionCount() == 2);
        assert(pw.sectionNames() == ["verse", "chorus"]);

        immutable PartResult bass = pw.addPart("bass", "bass");
        assert(bass.ok);
        assert(bass.part.name == "bass");
        assert(bass.part.moduleHandle == "bass");
        assert(bass.part.moduleId == 2);

        immutable PartResult keys = pw.addPart("keys", "KEYS");
        assert(keys.ok);
        assert(keys.part.moduleHandle == "keys");
        assert(keys.part.moduleId == 3);
        assert(pw.partCount() == 2);
        assert(pw.patternCount() == 0);

        assert(!pw.hasPattern("bass", "verse"));
        immutable PartPatternResult bv1 = pw.patternFor("bass", "verse");
        assert(bv1.ok);
        assert(bv1.pattern.patternId == 1);
        assert(bv1.pattern.name == "bass \u00B7 verse");
        assert(bv1.pattern.name == formatPartPatternName("bass", "verse"));
        assert(bv1.pattern.tracks == 1);
        assert(bv1.pattern.lines == 64);
        assert(bv1.pattern.moduleId == 2);
        assert(!bv1.pattern.isImplicitSection);
        assert(pw.hasPattern("BASS", " VERSE "));
        assert(pw.patternCount() == 1);

        immutable PartPatternResult bv2 = pw.patternFor("  BASS ", "Verse");
        assert(bv2.ok);
        assert(bv2.pattern.patternId == bv1.pattern.patternId);
        assert(pw.patternCount() == 1);

        immutable PartPatternResult kv = pw.patternFor("keys", "verse");
        assert(kv.ok);
        assert(kv.pattern.patternId == 2);
        assert(kv.pattern.name == "keys \u00B7 verse");
        assert(kv.pattern.patternId != bv1.pattern.patternId);

        immutable PartPatternResult bc = pw.patternFor("bass", "chorus");
        assert(bc.ok);
        assert(bc.pattern.patternId == 3);
        assert(bc.pattern.name == "bass \u00B7 chorus");
        assert(bc.pattern.lines == 128);

        PatternGrid grid;
        assert(pw.patternGrid(1, grid));
        assert(grid.tracks == 1 && grid.lines == 64 && grid.cells.length == 64);
        assert(!pw.patternGrid(999, grid));

        SavedPattern[] exported = pw.savedPatterns();
        assert(exported.length == 3);
        assert(exported[0].patternId == 1 && exported[0].name == "bass \u00B7 verse"
            && exported[0].lines == 64 && exported[0].tracks == 1 && exported[0].kind == PATTERN_KIND_NORMAL);
        assert(exported[1].patternId == 2 && exported[1].name == "keys \u00B7 verse" && exported[1].lines == 64);
        assert(exported[2].patternId == 3 && exported[2].name == "bass \u00B7 chorus" && exported[2].lines == 128);
    }

    unittest {
        ProjectWriter p44 = makeProjectWithSynths();
        assert(p44.setTimeSignature(TimeSignature(4, 4)).ok);
        PartWriter w44 = new PartWriter(p44);
        assert(w44.addPart("lead", "keys").ok);
        immutable SectionResult s44 = w44.addSection("A", 3);
        assert(s44.ok && s44.section.lines == 48);
        immutable PartPatternResult pat44 = w44.patternFor("lead", "A");
        assert(pat44.ok && pat44.pattern.lines == 48);

        ProjectWriter p34 = makeProjectWithSynths();
        assert(p34.setTimeSignature(TimeSignature(3, 4)).ok);
        PartWriter w34 = new PartWriter(p34);
        assert(w34.addPart("lead", "keys").ok);
        immutable SectionResult s34 = w34.addSection("waltz", 4);
        assert(s34.ok && s34.section.lines == 48);
        immutable PartPatternResult pat34 = w34.patternFor("lead", "waltz");
        assert(pat34.ok && pat34.pattern.lines == 48);

        ProjectWriter p68 = makeProjectWithSynths();
        assert(p68.setTimeSignature(TimeSignature(6, 8)).ok);
        PartWriter w68 = new PartWriter(p68);
        assert(w68.addPart("lead", "keys").ok);
        immutable SectionResult s68 = w68.addSection("jig", 5);
        assert(s68.ok && s68.section.lines == 60);
        immutable PartPatternResult pat68 = w68.patternFor("lead", "jig");
        assert(pat68.ok && pat68.pattern.lines == 60);
    }

    unittest {
        ProjectWriter proj = makeProjectWithSynths();
        PartWriter pw = new PartWriter(proj);
        assert(pw.addSection("verse", 2).ok);
        assert(pw.addPart("bassLow", "bass").ok);
        assert(pw.addPart("bassHigh", "bass").ok);

        immutable PartPatternResult p1 = pw.patternFor("bassLow", "verse");
        immutable PartPatternResult p2 = pw.patternFor("bassHigh", "verse");
        assert(p1.ok && p2.ok);
        assert(p1.pattern.patternId != p2.pattern.patternId);
        assert(p1.pattern.name == "bassLow \u00B7 verse");
        assert(p2.pattern.name == "bassHigh \u00B7 verse");
        assert(p1.pattern.moduleId == p2.pattern.moduleId);
    }

    unittest {
        ProjectWriter proj = makeProjectWithSynths();
        PartWriter pw = new PartWriter(proj);
        assert(pw.addPart("bass", "bass").ok);
        assert(pw.addPart("keys", "keys").ok);
        assert(!pw.hasImplicitSection());

        immutable PartPatternResult bImp = pw.patternFor("bass");
        assert(bImp.ok);
        assert(pw.hasImplicitSection());
        assert(pw.sectionCount() == 0);
        assert(bImp.pattern.name == "bass");
        assert(bImp.pattern.lines == 16);
        assert(bImp.pattern.isImplicitSection);

        immutable SectionResult grown = pw.ensureImplicitSection(4);
        assert(grown.ok && grown.section.isImplicit && grown.section.bars == 4 && grown.section.lines == 64);

        immutable PartPatternResult kImp = pw.patternFor("keys");
        assert(kImp.ok);
        assert(kImp.pattern.name == "keys");
        assert(kImp.pattern.lines == 64);
        assert(kImp.pattern.patternId != bImp.pattern.patternId);
    }

    unittest {
        ProjectWriter proj = makeProjectWithSynths();
        PartWriter pw = new PartWriter(proj);

        immutable SectionResult zeroBars = pw.addSection("intro", 0);
        assert(!zeroBars.ok && zeroBars.problem.kind == PartProblemKind.invalidBars);
        assert(zeroBars.problem.suggestion == "1");

        immutable uint maxBars44 = MAX_LINES / 16;
        immutable SectionResult exact = pw.addSection("maxed", maxBars44);
        assert(exact.ok && exact.section.lines == MAX_LINES);

        immutable SectionResult tooLong = pw.addSection("huge", maxBars44 + 1);
        assert(!tooLong.ok && tooLong.problem.kind == PartProblemKind.sectionTooLong);
        assert(tooLong.problem.suggestion == "256");
        assert(tooLong.problem.text().canFind("the nearest valid value is 256"));

        immutable SectionResult overflow = pw.addSection("overflow", uint.max);
        assert(!overflow.ok && overflow.problem.kind == PartProblemKind.sectionTooLong);
        assert(overflow.problem.suggestion == "256");

        immutable SectionResult emptySec = pw.addSection("   ", 4);
        assert(!emptySec.ok && emptySec.problem.kind == PartProblemKind.invalidName);

        char[MAX_PART_NAME_LENGTH + 5] overLen = 'a';
        immutable SectionResult longSec = pw.addSection(overLen[].idup, 4);
        assert(!longSec.ok && longSec.problem.kind == PartProblemKind.invalidName);
        assert(longSec.problem.suggestion.length == MAX_PART_NAME_LENGTH);

        assert(pw.addSection("verse", 4).ok);
        immutable SectionResult dupSec = pw.addSection("VERSE", 8);
        assert(!dupSec.ok && dupSec.problem.kind == PartProblemKind.duplicateSection);
        assert(dupSec.problem.suggestion == "VERSE2");

        immutable SectionResult missingSec = pw.sectionOf("vers");
        assert(!missingSec.ok && missingSec.problem.kind == PartProblemKind.unknownSection);
        assert(missingSec.problem.suggestion == "verse");
        assert(missingSec.problem.text().canFind("did you mean 'verse'?"));

        assert(pw.addPart("bass", "bass").ok);
        immutable PartResult dupPart = pw.addPart(" Bass ", "keys");
        assert(!dupPart.ok && dupPart.problem.kind == PartProblemKind.duplicatePart);
        assert(dupPart.problem.suggestion == "Bass2");

        immutable PartResult badMod = pw.addPart("lead", "bazz");
        assert(!badMod.ok && badMod.problem.kind == PartProblemKind.unknownModule);
        assert(badMod.problem.suggestion == "bass");

        immutable PartResult missingPart = pw.partOf("bas");
        assert(!missingPart.ok && missingPart.problem.kind == PartProblemKind.unknownPart);
        assert(missingPart.problem.suggestion == "bass");

        immutable PartPatternResult missingPatSec = pw.patternFor("bass", "vers");
        assert(!missingPatSec.ok && missingPatSec.problem.kind == PartProblemKind.unknownSection);
        assert(missingPatSec.problem.suggestion == "verse");

        immutable PartPatternResult omittedWhenExplicit = pw.patternFor("bass", "");
        assert(!omittedWhenExplicit.ok && omittedWhenExplicit.problem.kind == PartProblemKind.unknownSection);
        assert(omittedWhenExplicit.problem.suggestion == "maxed");

        immutable PartPatternResult missingPatPart = pw.patternFor("bazz", "verse");
        assert(!missingPatPart.ok && missingPatPart.problem.kind == PartProblemKind.unknownPart);
        assert(missingPatPart.problem.suggestion == "bass");
    }

    unittest {
        import app.session : StudioSession;
        import compose.script.notation : parseNotes;
        import compose.timing : BeatPosition, Length;
        import foundation.memory : OwnedBuffer;
        import io.project_format : LoadedProject;
        import std.math : fabs;

        ProjectWriter proj = makeProjectWithSynths();
        assert(proj.connect("bass", "out", 0.5f).ok);
        assert(proj.connect("keys", "out", 0.5f).ok);
        PartWriter pw = new PartWriter(proj);
        assert(pw.addSection("a", 2).ok);
        assert(pw.addPart("bass", "bass").ok);
        assert(pw.addPart("keys", "keys").ok);

        assert(pw.writeNote("bass", "a", BeatPosition(1, 1, 1), Length(4), 36, 0.9f).ok);
        assert(pw.writeNote("bass", "a", BeatPosition(2, 3, 1), Length(8), 43, 0.8f).ok);

        auto chordNotes = parseNotes("[C4 E4 G4]:2 - [F4 A4 C5]:2", TimeSignature(4, 4));
        assert(chordNotes.ok);
        assert(pw.writeNotes("keys", "a", BeatPosition(1, 1, 1), chordNotes.events).ok);

        auto kNotes = pw.notesOfPart("keys", "a");
        assert(kNotes.length == 6);
        assert(kNotes[0].line == 0 && kNotes[0].lengthLines == 8 && kNotes[0].pitch == 60);
        assert(kNotes[1].line == 16 && kNotes[1].lengthLines == 8 && kNotes[1].pitch == 65);
        assert(kNotes[2].track == 1 && kNotes[4].track == 2);

        immutable PartEditResult overlap = pw.writeNote("bass", "a", BeatPosition(1, 1, 3), Length(2), 36);
        assert(!overlap.ok && overlap.problem.kind == PartProblemKind.noteOverlap);

        immutable PartEditResult pastEnd = pw.writeNote("bass", "a", BeatPosition(2, 4, 2), Length(4), 48);
        assert(!pastEnd.ok && pastEnd.problem.kind == PartProblemKind.positionOutOfRange);
        assert(pastEnd.problem.suggestion == "2.4");

        assert(pw.arrange(["a"]).ok);
        auto docRes = pw.buildDocument();
        assert(docRes.ok, docRes.problem.reason);

        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string err;
        assert(s.openProjectFromMemory(docRes.project, err), err);
        s.engine().reset();
        s.engine().setTempo(docRes.project.bpm, docRes.project.ticksPerLine);
        s.engine().seekLine(0);
        s.engine().setPlaying(true);
        OwnedBuffer!float outL;
        OwnedBuffer!float outR;
        assert(s.engine().renderOfflineToBuffer(4096, 64, outL, outR));
        float peak = 0.0f;
        foreach (i; 0 .. outL.length) {
            immutable float a = fabs(outL[i]) > fabs(outR[i]) ? fabs(outL[i]) : fabs(outR[i]);
            if (a > peak) peak = a;
        }
        assert(peak > 0.01f);

        ProjectWriter p34 = makeProjectWithSynths();
        assert(p34.setTimeSignature(TimeSignature(3, 4)).ok);
        PartWriter w34 = new PartWriter(p34);
        assert(w34.addSection("w", 2).ok);
        assert(w34.addPart("keys", "keys").ok);
        assert(w34.writeNote("keys", "w", BeatPosition(2, 2, 1), Length(4), 64).ok);
        assert(w34.notesOfPart("keys", "w")[0].line == 16);

        ProjectWriter p68 = makeProjectWithSynths();
        assert(p68.setTimeSignature(TimeSignature(6, 8)).ok);
        PartWriter w68 = new PartWriter(p68);
        assert(w68.addSection("j", 2).ok);
        assert(w68.addPart("keys", "keys").ok);
        assert(w68.writeNote("keys", "j", BeatPosition(2, 4, 1), Length(2), 67).ok);
        assert(w68.notesOfPart("keys", "j")[0].line == 18);
    }

    unittest {
        import app.session : StudioSession;
        import compose.timing : BeatPosition, Length;
        import foundation.memory : OwnedBuffer;
        import std.math : fabs;

        ProjectWriter proj = makeProjectWithSynths();
        assert(proj.setTempo(150.0).ok);
        assert(proj.connect("bass", "out", 0.5f).ok);
        assert(proj.connect("keys", "out", 0.5f).ok);
        PartWriter pw = new PartWriter(proj);
        assert(pw.addSection("verse", 1).ok);
        assert(pw.addSection("chorus", 1).ok);
        assert(pw.addPart("bass", "bass").ok);
        assert(pw.addPart("keys", "keys").ok);

        assert(pw.writeNote("bass", "verse", BeatPosition(1, 1, 1), Length(8), 36, 0.9f).ok);
        assert(pw.writeNote("keys", "chorus", BeatPosition(1, 1, 1), Length(8), 72, 0.9f).ok);

        assert(pw.arrange(["chorus"]).ok);
        assert(pw.arrangement() == ["chorus"]);
        assert(pw.arrange(["verse", "chorus", "verse"]).ok);
        assert(pw.arrangement() == ["verse", "chorus", "verse"]);
        assert(pw.arrangementLengthLines() == 48);
        assert(pw.loopStartLine() == 0 && pw.loopEndLine() == 48);

        auto clips = pw.arrangementClips();
        assert(clips.length == 3);
        assert(clips[0].laneY == 0 && clips[0].startLine == 0 && clips[0].lengthLines == 16);
        assert(clips[1].laneY == 1 && clips[1].startLine == 16 && clips[1].lengthLines == 16);
        assert(clips[2].laneY == 0 && clips[2].startLine == 32 && clips[2].lengthLines == 16);
        assert(clips[0].patternId == clips[2].patternId);
        assert(clips[0].cloneSourceId == 0 && clips[2].cloneSourceId == clips[0].clipId);

        assert(pw.setLoopSections(1, 3).ok);
        assert(pw.loopStartLine() == 16 && pw.loopEndLine() == 48);
        pw.clearLoop();
        assert(pw.loopStartLine() == 0 && pw.loopEndLine() == 48);

        auto badArr = pw.arrange(["vers"]);
        assert(!badArr.ok && badArr.problem.kind == PartProblemKind.unknownSection);
        assert(badArr.problem.suggestion == "verse");

        auto docRes = pw.buildDocument();
        assert(docRes.ok, docRes.problem.reason);

        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string err;
        assert(s.openProjectFromMemory(docRes.project, err), err);
        assert(s.document().clips.length == 3);
        assert(s.document().loopEndLine == 48);

        s.engine().reset();
        s.engine().setTempo(docRes.project.bpm, docRes.project.ticksPerLine);
        s.engine().seekLine(0);
        s.engine().setPlaying(true);
        OwnedBuffer!float outL;
        OwnedBuffer!float outR;
        immutable size_t secFrames = 26_460;
        assert(s.engine().renderOfflineToBuffer(secFrames * 3, 64, outL, outR));

        float s1 = 0.0f;
        float s2 = 0.0f;
        foreach (i; 0 .. 4096) {
            immutable float a1 = fabs(outL[i]);
            immutable float a2 = fabs(outL[secFrames + i]);
            if (a1 > s1) s1 = a1;
            if (a2 > s2) s2 = a2;
        }
        assert(s1 > 0.01f && s2 > 0.01f);

        ProjectWriter impProj = makeProjectWithSynths();
        assert(impProj.connect("bass", "out", 0.5f).ok);
        PartWriter impPw = new PartWriter(impProj);
        assert(impPw.addPart("bass", "bass").ok);
        assert(impPw.writeNote("bass", "", BeatPosition(2, 1, 1), Length(4), 40).ok);
        assert(impPw.arrangementLengthLines() == 32);
        auto impClips = impPw.arrangementClips();
        assert(impClips.length == 1 && impClips[0].startLine == 0 && impClips[0].lengthLines == 32);
    }

    unittest {
        import compose.part_writer : CellResult;
        import compose.timing : BeatPosition, Length;
        import sequencer.note : EffectCode, NoteCell, NoteCmd;

        ProjectWriter proj = makeProjectWithSynths();
        PartWriter pw = new PartWriter(proj);
        assert(pw.addSection("verse", 1).ok);
        assert(pw.addPart("bass", "bass").ok);
        auto bassPat = pw.patternFor("bass", "verse");
        assert(bassPat.ok);
        immutable ushort bassId = cast(ushort) bassPat.pattern.moduleId;

        immutable NoteCell noteSlide = NoteCell.makeNote(45, 0.75f, bassId, EffectCode.slideUp, 0x08);
        assert(pw.writeCell(bassPat.pattern.patternId, 0, 0, noteSlide).ok);
        assert(pw.writeCell("bass", "verse", 0, BeatPosition(1, 2, 1),
            NoteCell.makeNoteOff(bassId)).ok);
        assert(pw.writeCell(bassPat.pattern.patternId, 0, 6,
            NoteCell(NoteCmd.allNotesOff, 0, bassId, 0, EffectCode.noteCut, 2)).ok);
        assert(pw.writeParamCell(bassPat.pattern.patternId, 1, 2, "bass", "Waveform", "Saw").ok);

        assert(pw.isHandPlaced(bassPat.pattern.patternId, 0, 0));
        assert(pw.isHandPlaced(bassPat.pattern.patternId, 1, 2));
        immutable CellResult read0 = pw.cellAt(bassPat.pattern.patternId, 0, 0);
        assert(read0.ok && read0.cell == noteSlide);
        immutable CellResult readOff = pw.cellAt("bass", "verse", 0, BeatPosition(1, 2, 1));
        assert(readOff.ok && readOff.cell.note == NoteCmd.noteOff);
        immutable CellResult readCut = pw.cellAt(bassPat.pattern.patternId, 0, 6);
        assert(readCut.ok && readCut.cell.note == NoteCmd.allNotesOff && readCut.cell.effect == EffectCode.noteCut);
        immutable CellResult readParam = pw.cellAt(bassPat.pattern.patternId, 1, 2);
        assert(readParam.ok && readParam.cell.moduleId == bassId && readParam.cell.paramId >= 1);

        assert(pw.writeNote("bass", "verse", BeatPosition(1, 1, 1), Length(4), 36, 0.9f).ok);
        assert(pw.cellAt(bassPat.pattern.patternId, 0, 0).cell == noteSlide);
        assert(pw.cellAt("bass", "verse", 0, BeatPosition(1, 2, 1)).cell.note == NoteCmd.noteOff);
        assert(pw.notesOfPart("bass", "verse").length == 2);

        auto rawPat = pw.addRawPattern("Bridge Fx", 2, 16);
        assert(rawPat.ok);
        assert(pw.writeCell(rawPat.pattern.patternId, 1, 4, NoteCell.makeEffect(EffectCode.setBpm, 140)).ok);
        assert(pw.patternByName("bridgefx").ok);
        assert(pw.cellAt(rawPat.pattern.patternId, 1, 4).cell.effect == EffectCode.setBpm);

        assert(!pw.writeCell(9999, 0, 0, noteSlide).ok);
        assert(!pw.writeCell(rawPat.pattern.patternId, 0, 99, noteSlide).ok);
        assert(!pw.writeCell(rawPat.pattern.patternId, 0, 0, NoteCell(200, 0, 0, 0, 0, 0)).ok);
        assert(!pw.writeCell(rawPat.pattern.patternId, 0, 0, NoteCell.makeNote(60, 0.5f, 999)).ok);
    }

    unittest {
        import app.music_theory : KeyMode, MusicalKey;
        import compose.part_writer : PartNote;
        import compose.timing : BeatPosition, Length;
        import std.math : fabs;

        ProjectWriter proj = makeProjectWithSynths();
        assert(proj.setKey(MusicalKey(0, KeyMode.major)).ok);
        PartWriter pw = new PartWriter(proj);
        assert(pw.addSection("verse", 2).ok);
        assert(pw.addSection("chorus", 2).ok);
        assert(pw.addPart("bass", "bass").ok);
        assert(pw.addPart("keys", "keys").ok);

        assert(pw.writeNote("keys", "verse", BeatPosition(1, 1, 1), Length(4), 60, 0.8f).ok);
        assert(pw.writeNote("keys", "verse", BeatPosition(1, 2, 1), Length(4), 62, 0.5f).ok);

        assert(pw.repeatRange("keys", "verse", BeatPosition(1, 1, 1), Length(8), 1).ok);
        PartNote[] repeated = pw.notesOfPart("keys", "verse");
        assert(repeated.length == 4);
        assert(repeated[2].line == 8 && repeated[2].pitch == 60);
        assert(repeated[3].line == 12 && repeated[3].pitch == 62);

        assert(pw.copyRange("keys", "verse", BeatPosition(1, 1, 1), Length(8),
            "keys", "chorus", BeatPosition(2, 1, 1)).ok);
        PartNote[] chorusNotes = pw.notesOfPart("keys", "chorus");
        assert(chorusNotes.length == 2);
        assert(chorusNotes[0].line == 16 && chorusNotes[0].pitch == 60);
        assert(chorusNotes[1].line == 20 && chorusNotes[1].pitch == 62);

        assert(pw.transposeRange("keys", "verse", BeatPosition(1, 1, 1), Length(8), 12).ok);
        repeated = pw.notesOfPart("keys", "verse");
        assert(repeated[0].pitch == 72 && repeated[1].pitch == 74);
        assert(repeated[2].pitch == 60 && repeated[3].pitch == 62);

        assert(pw.transposeRangeScaleSteps("keys", "chorus", BeatPosition(2, 1, 1), Length(8), 2).ok);
        chorusNotes = pw.notesOfPart("keys", "chorus");
        assert(chorusNotes[0].pitch == 64 && chorusNotes[1].pitch == 65);

        assert(pw.scaleVelocities("keys", "chorus", BeatPosition(2, 1, 1), Length(8), 0.5f).ok);
        chorusNotes = pw.notesOfPart("keys", "chorus");
        assert(fabs(chorusNotes[0].velocity - 0.4f) < 0.02f);

        assert(pw.clearRange("keys", "verse", BeatPosition(1, 1, 1), Length(8)).ok);
        PartNote[] afterClear = pw.notesOfPart("keys", "verse");
        assert(afterClear.length == 2 && afterClear[0].line == 8);

        immutable PartEditResult crossRepeat = pw.repeatRange("keys", "verse", BeatPosition(1, 1, 1),
            Length(16), 2);
        assert(!crossRepeat.ok && crossRepeat.problem.kind == PartProblemKind.positionOutOfRange);
        immutable PartEditResult crossCopy = pw.copyRange("keys", "verse", BeatPosition(2, 1, 1),
            Length(24), "bass", "chorus", BeatPosition(1, 1, 1));
        assert(!crossCopy.ok && crossCopy.problem.kind == PartProblemKind.positionOutOfRange);
        immutable PartEditResult crossTrans = pw.transposeRange("keys", "verse", BeatPosition(2, 1, 1),
            Length(20), 1);
        assert(!crossTrans.ok && crossTrans.problem.kind == PartProblemKind.positionOutOfRange);
        immutable PartEditResult crossClear = pw.clearRange("keys", "verse", BeatPosition(2, 1, 1),
            Length(20));
        assert(!crossClear.ok && crossClear.problem.kind == PartProblemKind.positionOutOfRange);
        immutable PartEditResult badTimes = pw.repeatRange("keys", "verse", BeatPosition(1, 1, 1),
            Length(4), 0);
        assert(!badTimes.ok && badTimes.problem.kind == PartProblemKind.invalidRepeatCount);
        immutable PartEditResult badVel = pw.scaleVelocities("keys", "verse", BeatPosition(1, 1, 1),
            Length(4), -1.0f);
        assert(!badVel.ok && badVel.problem.kind == PartProblemKind.invalidVelocity);
    }
}
