/**
 * File:         tests/unit/compose_project_test.d
 * Module:       tests.unit.compose_project_test
 * Phase:        Composition helper (dracker-compose) — T76 (Project writer tests)
 *
 * Purpose:
 *   Verifies compose.project_writer. Defaults of a new writer and its document: Master Output as "out" with
 *   id 1 named "Master Output" at the layout origin column, the app's starter pattern and clip. Setters at
 *   their edges (tempo 20.0 and 999.0, ticks 1 to 255, signature numerators 1 to 16 with denominators 2, 4,
 *   8, 16, key tonic below 12, title at 65_536 bytes) and every refusal (kind, subject, reason, suggestion)
 *   leaving the value unchanged. parseKey: note letters with '#' and 'b', bare tonics, major and minor, the
 *   nearest-mode suggestion, a note name round trip for all 24 keys, and every suggestion parsing back.
 *   Handles: the bare-word rule, suggestedHandle for spaces, leading digits, empty text and over-long names,
 *   and every suggestion a valid handle. Modules: adding (displayed name follows the handle, "out" stays
 *   "Master Output"), lookup by case-folded and spaced text, refusals (invalid, duplicate with a numbered
 *   suggestion, unknown with the nearest handle, the protected output, an unloaded writer, a non-finite
 *   position), rename, setModuleName (valid, invalid with invalidName, "out" with protectedModule), move,
 *   remove, ids that never reuse, the automatic four-row layout, and a caller writer changing nothing. The
 *   module limit at MAX_MODULES. Files: a blocked write as writeFailed with the path, an empty path,
 *   documentBytes refusing an out-of-range BPM, .msv bytes loading through the app's own loader, and a
 *   written project round-tripping through loadProjectFile and opening in StudioSession with 3 modules.
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Writes one .msv file into a folder of the temporary directory and removes the folder again.
 *   Loads the project into a StudioSession that never starts audio.
 *
 * Dependencies:
 *   Internal: app.music_theory, app.session, compose.module_writer, compose.project_writer, compose.timing,
 *             io.project_format, sequencer.timeline
 *   External: std.algorithm, std.conv, std.file, std.path, std.process
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T67, T74, T76, T92), source/compose/project_writer.d
 */
module tests.unit.compose_project_test;

version (unittest) {
    import std.algorithm : startsWith;
    import std.conv : to;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    import app.music_theory : allKeys, keyName, KeyMode, MusicalKey;
    import app.session : StudioSession;
    import compose.module_writer : ModuleWriter, ModuleWriterResult;
    import compose.project_writer;
    import compose.timing : TimeSignature;
    import io.project_format : LoadedProject, MAX_MODULES, SavedModule, SavedPattern, loadProject,
        loadProjectFile;
    import sequencer.timeline : TimelineClip;

    /**
     * A writer that must have started from a module type.
     *
     * Params:
     *   typeText = The type as a script gives it.
     *
     * Returns:
     *   The writer.
     */
    private ModuleWriter writerOf(string typeText) {
        ModuleWriterResult r = ModuleWriter.fromType(typeText);
        assert(r.ok, typeText ~ ": " ~ r.problem.text());
        return r.writer;
    }

    /**
     * A text made of one repeated character.
     *
     * Params:
     *   c = The character.
     *   count = How often to repeat it.
     *
     * Returns:
     *   The text.
     */
    private string times(char c, size_t count) {
        char[] buffer = new char[count];
        foreach (i; 0 .. count) {
            buffer[i] = c;
        }
        return buffer.idup;
    }

    unittest {
        ProjectWriter w = new ProjectWriter();
        assert(w.title() == "Untitled" && w.tempo() == 125.0 && w.ticksPerLine() == 6);
        assert(w.timeSignature() == TimeSignature(4, 4));
        assert(w.key() == MusicalKey(0, KeyMode.major));
        assert(w.moduleCount() == 1 && w.hasModule("out"));
        assert(w.handles() == ["out"]);
        assert(w.moduleId("out").ok && w.moduleId("out").id == 1);

        ProjectDocumentResult doc = w.document();
        assert(doc.ok, doc.problem.text());
        assert(doc.project.title == "Untitled" && doc.project.author == "Dracker");
        assert(doc.project.bpm == 125.0 && doc.project.ticksPerLine == 6);
        assert(doc.project.timeSigNumerator == 4 && doc.project.timeSigDenominator == 4);
        assert(doc.project.keyTonic == 0 && doc.project.keyMode == 0);
        assert(doc.project.modules.length == 1);
        SavedModule masterMod = doc.project.modules[0];
        assert(masterMod.id == 1 && masterMod.typeId == "core.output" && masterMod.name == "Master Output");
        assert(masterMod.paramValues == [1.0f, 1.0f]);
        assert(masterMod.posX == 240.0f && masterMod.posY == 60.0f);
        assert(doc.project.wires.length == 0);
        assert(doc.project.patterns.length == 1);
        SavedPattern pat = doc.project.patterns[0];
        assert(pat.patternId == 1 && pat.tracks == 4 && pat.lines == 64 && pat.name == "Pattern 01");
        assert(pat.cells.length == 256);
        assert(doc.project.clips.length == 1);
        assert(doc.project.clips[0] == TimelineClip(1, 1, 0, 0, 64, 0, 0, false, false, false));

        ProjectBytesResult bytes = w.msvBytes();
        assert(bytes.ok && bytes.bytes.length > 0);
    }

    unittest {
        ProjectWriter w = new ProjectWriter();

        immutable ProjectEditResult lowTempo = w.setTempo(19.9);
        assert(!lowTempo.ok && lowTempo.problem.kind == ProjectProblemKind.invalidTempo);
        assert(lowTempo.problem.subject == "tempo" && lowTempo.problem.suggestion == "20");
        assert(lowTempo.problem.text == "the tempo is 20 to 999 beats per minute; the nearest valid value is 20");
        assert(w.tempo() == 125.0);
        immutable ProjectEditResult highTempo = w.setTempo(999.5);
        assert(!highTempo.ok && highTempo.problem.suggestion == "999" && w.tempo() == 125.0);
        immutable ProjectEditResult nanTempo = w.setTempo(double.nan);
        assert(!nanTempo.ok && nanTempo.problem.suggestion == "125" && w.tempo() == 125.0);
        assert(w.setTempo(20.0).ok && w.tempo() == 20.0);
        assert(w.setTempo(999.0).ok && w.tempo() == 999.0);

        immutable ProjectEditResult zeroTicks = w.setTicksPerLine(0);
        assert(!zeroTicks.ok && zeroTicks.problem.kind == ProjectProblemKind.invalidTicksPerLine);
        assert(zeroTicks.problem.subject == "ticks per line" && zeroTicks.problem.suggestion == "1");
        assert(zeroTicks.problem.text == "ticks per line is 1 to 255; the nearest valid value is 1");
        assert(w.ticksPerLine() == 6);
        immutable ProjectEditResult overTicks = w.setTicksPerLine(256);
        assert(!overTicks.ok && overTicks.problem.suggestion == "255" && w.ticksPerLine() == 6);
        assert(w.setTicksPerLine(255).ok && w.ticksPerLine() == 255);

        immutable ProjectEditResult bigNumerator = w.setTimeSignature(TimeSignature(17, 4));
        assert(!bigNumerator.ok && bigNumerator.problem.kind == ProjectProblemKind.invalidTimeSignature);
        assert(bigNumerator.problem.subject == "signature" && bigNumerator.problem.suggestion == "4/4");
        assert(w.timeSignature() == TimeSignature(4, 4));
        assert(!w.setTimeSignature(TimeSignature(0, 4)).ok && w.timeSignature() == TimeSignature(4, 4));
        assert(!w.setTimeSignature(TimeSignature(4, 3)).ok && w.timeSignature() == TimeSignature(4, 4));
        assert(w.setTimeSignature(TimeSignature(16, 16)).ok && w.timeSignature() == TimeSignature(16, 16));

        immutable ProjectEditResult pastTonic = w.setKey(MusicalKey(12, KeyMode.major));
        assert(!pastTonic.ok && pastTonic.problem.kind == ProjectProblemKind.invalidKey);
        assert(pastTonic.problem.subject == "key" && pastTonic.problem.suggestion == "C major");
        assert(pastTonic.problem.text == "a key has a tonic from 0 (C) to 11 (B) and is major or minor; "
            ~ "the nearest valid value is C major");
        assert(w.key() == MusicalKey(0, KeyMode.major));
        assert(w.setKey(MusicalKey(9, KeyMode.minor)).ok && w.key() == MusicalKey(9, KeyMode.minor));

        immutable ProjectEditResult longTitle = w.setTitle(times('a', 65_537));
        assert(!longTitle.ok && longTitle.problem.kind == ProjectProblemKind.invalidTitle);
        assert(longTitle.problem.subject == "title" && longTitle.problem.suggestion == "");
        assert(longTitle.problem.text == "a project title is at most 65536 bytes long");
        assert(w.title() == "Untitled");
        assert(w.setTitle(times('a', 65_536)).ok && w.title().length == 65_536);
    }

    unittest {
        assert(parseKey("A minor").ok && parseKey("A minor").key == MusicalKey(9, KeyMode.minor));
        assert(parseKey("Cb").ok && parseKey("Cb").key == MusicalKey(11, KeyMode.major));
        assert(parseKey("B#").ok && parseKey("B#").key == MusicalKey(0, KeyMode.major));

        immutable ProjectKeyResult am = parseKey("Am");
        assert(!am.ok && am.problem.kind == ProjectProblemKind.invalidKey);
        assert(am.problem.subject == "Am" && am.problem.suggestion == "A minor");
        assert(am.problem.text == "a key is a note name followed by 'major' or 'minor'; "
            ~ "the nearest valid value is A minor");
        assert(parseKey(am.problem.suggestion).ok && parseKey(am.problem.suggestion).key
            == MusicalKey(9, KeyMode.minor));

        immutable ProjectKeyResult hMinor = parseKey("H minor");
        assert(!hMinor.ok && hMinor.problem.kind == ProjectProblemKind.invalidKey);
        assert(hMinor.problem.subject == "H minor" && hMinor.problem.suggestion == "C major");
        assert(parseKey(hMinor.problem.suggestion).ok && parseKey(hMinor.problem.suggestion).key
            == MusicalKey(0, KeyMode.major));
        assert(!parseKey("").ok && parseKey("").problem.suggestion == "C major");
        assert(parseKey("f#").ok && parseKey("f#").key == MusicalKey(6, KeyMode.major));
        assert(parseKey("c Major").ok && parseKey("c Major").key == MusicalKey(0, KeyMode.major));

        foreach (k; allKeys()) {
            immutable string name = keyName(k);
            immutable ProjectKeyResult r = parseKey(name);
            assert(r.ok, name ~ ": " ~ r.problem.text());
            assert(r.key == k, name);
        }
    }

    unittest {
        assert(isValidHandle("bass") && isValidHandle("BASS2") && isValidHandle("my_bass-2")
            && isValidHandle("a1"));
        assert(!isValidHandle("my bass"));
        assert(!isValidHandle("2bass"));
        assert(!isValidHandle(""));
        assert(!isValidHandle("#sharp"));
        assert(!isValidHandle("a=b"));
        assert(!isValidHandle("a:b"));
        assert(!isValidHandle("a\\b"));
        assert(!isValidHandle("a\"b"));
        assert(!isValidHandle(times('x', 33)));

        assert(suggestedHandle("my bass") == "mybass");
        assert(suggestedHandle("2bass") == "bass");
        assert(suggestedHandle("") == "module");
        assert(suggestedHandle(times('x', 33)) == times('x', 32));
        assert(suggestedHandle("#sharp") == "sharp");
        assert(suggestedHandle("a=b") == "ab");
        foreach (text; ["my bass", "2bass", "", "#sharp", "a=b", "a:b", "a\\b", "a\"b", "zzzzzz",
                times('x', 33)]) {
            assert(isValidHandle(suggestedHandle(text)), text);
        }
    }

    unittest {
        ProjectWriter w = new ProjectWriter();
        immutable ProjectIdResult bass = w.addModule("bass", writerOf("synth.analog_gen"));
        assert(bass.ok && bass.id == 2, bass.problem.text());
        immutable ProjectIdResult keys = w.addModule("keys", writerOf("synth.fm_synth"));
        assert(keys.ok && keys.id == 3, keys.problem.text());

        ProjectDocumentResult doc = w.document();
        assert(doc.ok, doc.problem.text());
        assert(doc.project.modules.length == 3);
        assert(doc.project.modules[0].id == 1 && doc.project.modules[0].name == "Master Output");
        assert(doc.project.modules[0].posX == 240.0f && doc.project.modules[0].posY == 60.0f);
        assert(doc.project.modules[1].id == 2 && doc.project.modules[1].typeId == "synth.analog_gen");
        assert(doc.project.modules[1].name == "bass");
        assert(doc.project.modules[1].posX == 60.0f && doc.project.modules[1].posY == 60.0f);
        assert(doc.project.modules[2].id == 3 && doc.project.modules[2].typeId == "synth.fm_synth");
        assert(doc.project.modules[2].name == "keys");
        assert(doc.project.modules[2].posX == 60.0f && doc.project.modules[2].posY == 220.0f);

        assert(w.hasModule("KEYS") && w.hasModule("k e y s"));
        assert(w.moduleId("KEYS").ok && w.moduleId("KEYS").id == 3);
        ProjectModuleResult pm = w.moduleOf("k e y s");
        assert(pm.ok && pm.id == 3 && pm.writer.loaded() && pm.writer.name == "keys");

        immutable ProjectIdResult spaced = w.addModule("my bass", writerOf("fx.amplifier"));
        assert(!spaced.ok && spaced.problem.kind == ProjectProblemKind.invalidHandle);
        assert(spaced.problem.subject == "my bass" && spaced.problem.suggestion == "mybass");
        assert(spaced.problem.text == "a module name starts with a letter and holds only letters, digits, "
            ~ "'_' and '-', at most 32 characters; did you mean 'mybass'?");
        assert(w.moduleCount() == 3);
        assert(!w.addModule("2bass", writerOf("fx.amplifier")).ok
            && w.moduleId("2bass").problem.suggestion == "bass");
        immutable ProjectIdResult emptyHandle = w.addModule("", writerOf("fx.amplifier"));
        assert(!emptyHandle.ok && emptyHandle.problem.kind == ProjectProblemKind.invalidHandle);
        assert(emptyHandle.problem.suggestion == "module");
        immutable ProjectIdResult longHandle = w.addModule(times('x', 33), writerOf("fx.amplifier"));
        assert(!longHandle.ok && longHandle.problem.suggestion == times('x', 32));
        assert(w.moduleCount() == 3);

        immutable ProjectIdResult dup = w.addModule("BASS", writerOf("fx.amplifier"));
        assert(!dup.ok && dup.problem.kind == ProjectProblemKind.duplicateHandle);
        assert(dup.problem.subject == "BASS" && dup.problem.suggestion == "BASS2");
        assert(dup.problem.text == "there is already a module 'BASS'; did you mean 'BASS2'?");
        assert(w.moduleCount() == 3);
        immutable ProjectIdResult dupOut = w.addModule("out", writerOf("fx.amplifier"));
        assert(!dupOut.ok && dupOut.problem.kind == ProjectProblemKind.duplicateHandle);
        assert(dupOut.problem.suggestion == "out2");
        assert(w.addModule("bass2", writerOf("fx.amplifier")).ok);
        assert(w.moduleCount() == 4 && w.moduleId("bass2").id == 4);

        immutable ProjectIdResult near = w.moduleId("bas");
        assert(!near.ok && near.problem.kind == ProjectProblemKind.unknownHandle);
        assert(near.problem.subject == "bas" && near.problem.suggestion == "bass");
        immutable ProjectIdResult far = w.moduleId("zzzzzz");
        assert(!far.ok && far.problem.kind == ProjectProblemKind.unknownHandle && far.problem.suggestion == "");

        immutable ProjectIdResult unloaded = w.addModule("solo", ModuleWriter.init);
        assert(!unloaded.ok && unloaded.problem.kind == ProjectProblemKind.notLoaded);
        assert(unloaded.problem.subject == "solo" && unloaded.problem.suggestion == "");
        immutable ProjectIdResult secondOutput = w.addModule("extra", writerOf(OUTPUT_TYPE_ID));
        assert(!secondOutput.ok && secondOutput.problem.kind == ProjectProblemKind.protectedModule);
        assert(secondOutput.problem.suggestion == "out");
        assert(w.moduleCount() == 4);

        immutable ProjectEditResult removeOut = w.removeModule("out");
        assert(!removeOut.ok && removeOut.problem.kind == ProjectProblemKind.protectedModule);
        assert(removeOut.problem.text == "the Master Output 'out' cannot be removed");
        immutable ProjectEditResult renameOut = w.renameModule("out", "sub");
        assert(!renameOut.ok && renameOut.problem.kind == ProjectProblemKind.protectedModule);
        assert(renameOut.problem.text == "the Master Output 'out' cannot be renamed");
        immutable ProjectEditResult nameOut = w.setModuleName("out", "Main");
        assert(!nameOut.ok && nameOut.problem.kind == ProjectProblemKind.protectedModule);
        assert(w.document().project.modules[0].name == "Master Output");

        immutable ProjectIdResult nanAt = w.addModuleAt("drum", writerOf("synth.drumsynth"), float.nan, 0.0f);
        assert(!nanAt.ok && nanAt.problem.kind == ProjectProblemKind.invalidPosition);
        assert(nanAt.problem.subject == "drum");
        assert(nanAt.problem.text == "the position of 'drum' must be two finite numbers");
        assert(w.moduleCount() == 4);
        immutable ProjectEditResult moveUnknown = w.moveModule("nope", 1.0f, 2.0f);
        assert(!moveUnknown.ok && moveUnknown.problem.kind == ProjectProblemKind.unknownHandle);
        immutable ProjectEditResult moveInf = w.moveModule("keys", float.infinity, 2.0f);
        assert(!moveInf.ok && moveInf.problem.kind == ProjectProblemKind.invalidPosition);
        assert(moveInf.problem.subject == "keys");
        immutable ProjectIdResult badAt = w.addModuleAt("bad name", writerOf("fx.amplifier"), 1.0f, 2.0f);
        assert(!badAt.ok && badAt.problem.kind == ProjectProblemKind.invalidHandle);

        assert(w.renameModule("keys", "sub").ok);
        assert(w.moduleId("sub").id == 3 && !w.moduleId("keys").ok);
        assert(w.document().project.modules[2].name == "sub");
        immutable ProjectEditResult spaceRename = w.renameModule("sub", "sub sonic");
        assert(!spaceRename.ok && spaceRename.problem.kind == ProjectProblemKind.invalidHandle);
        assert(spaceRename.problem.suggestion == "subsonic");
        immutable ProjectEditResult nameSub = w.setModuleName("sub", "Electric Bass");
        assert(nameSub.ok, nameSub.problem.text());
        assert(w.document().project.modules[2].name == "Electric Bass" && w.moduleId("sub").id == 3);
        immutable ProjectEditResult badName = w.setModuleName("sub", "bad/name");
        assert(!badName.ok && badName.problem.kind == ProjectProblemKind.invalidName);
        assert(badName.problem.subject == "bad/name" && badName.problem.suggestion == "bad-name");
        assert(w.document().project.modules[2].name == "Electric Bass");

        assert(w.moveModule("sub", 400.0f, 300.0f).ok);
        ProjectDocumentResult moved = w.document();
        assert(moved.ok, moved.problem.text());
        assert(moved.project.modules[2].posX == 400.0f && moved.project.modules[2].posY == 300.0f);
        assert(moved.project.modules[1].posX == 60.0f && moved.project.modules[1].posY == 60.0f);
        assert(moved.project.modules[0].posX == 240.0f && moved.project.modules[0].posY == 60.0f);

        assert(w.removeModule("bass2").ok);
        assert(w.moduleCount() == 3 && !w.hasModule("bass2"));
        immutable ProjectEditResult removeAgain = w.removeModule("bass2");
        assert(!removeAgain.ok && removeAgain.problem.kind == ProjectProblemKind.unknownHandle);

        ProjectWriter ids = new ProjectWriter();
        assert(ids.addModule("a", writerOf("fx.amplifier")).id == 2);
        assert(ids.addModule("b", writerOf("fx.amplifier")).id == 3);
        assert(ids.removeModule("a").ok);
        assert(ids.addModule("c", writerOf("fx.amplifier")).id == 4);

        ProjectWriter six = new ProjectWriter();
        foreach (n; 1 .. 7) {
            assert(six.addModule("m" ~ to!string(n), writerOf("fx.amplifier")).ok, to!string(n));
        }
        ProjectDocumentResult sixDoc = six.document();
        assert(sixDoc.ok, sixDoc.problem.text());
        assert(sixDoc.project.modules[5].posX == 240.0f && sixDoc.project.modules[5].posY == 60.0f);
        assert(sixDoc.project.modules[6].posX == 240.0f && sixDoc.project.modules[6].posY == 220.0f);
        assert(sixDoc.project.modules[0].posX == 420.0f && sixDoc.project.modules[0].posY == 60.0f);

        ProjectWriter copied = new ProjectWriter();
        ModuleWriter caller = writerOf("synth.analog_gen");
        assert(caller.setParamText("Cutoff", "100").ok);
        assert(copied.addModule("bass", caller).ok);
        assert(caller.setParamText("Cutoff", "5000").ok && caller.setName("Changed").ok);
        ProjectDocumentResult copyDoc = copied.document();
        assert(copyDoc.ok, copyDoc.problem.text());
        assert(copyDoc.project.modules[1].name == "bass" && copyDoc.project.modules[1].paramValues[3] == 100.0f);
        ProjectModuleResult kept = copied.moduleOf("bass");
        assert(kept.ok && kept.writer.name == "bass" && kept.writer.valueOf("Cutoff").value == 100.0f);
    }

    unittest {
        ProjectWriter big = new ProjectWriter();
        foreach (n; 0 .. 1023) {
            assert(big.addModule("m" ~ to!string(n), writerOf("fx.amplifier")).ok, to!string(n));
        }
        assert(big.moduleCount() == MAX_MODULES);
        immutable ProjectIdResult over = big.addModule("over", writerOf("fx.amplifier"));
        assert(!over.ok && over.problem.kind == ProjectProblemKind.tooManyModules);
        assert(over.problem.subject == "over" && over.problem.reason == "a project holds at most 1024 modules");
        assert(big.moduleCount() == MAX_MODULES);
        ProjectDocumentResult doc = big.document();
        assert(doc.ok, doc.problem.text());
        assert(doc.project.modules.length == MAX_MODULES);
    }

    unittest {
        immutable string root = buildPath(tempDir(), "dracker-compose-project-test-"
            ~ to!string(thisProcessID()));
        immutable string path = buildPath(root, "night_drive.msv");
        scope (failure) {
            rmdirRecurse(root);
        }
        if (exists(root)) {
            rmdirRecurse(root);
        }

        ProjectWriter w = new ProjectWriter();
        assert(w.setTitle("Night Drive").ok && w.setTempo(96.0).ok && w.setTicksPerLine(4).ok);
        assert(w.setTimeSignature(TimeSignature(6, 8)).ok);
        assert(w.setKey(parseKey("A minor").key).ok);
        assert(w.addModule("bass", writerOf("synth.analog_gen")).ok);
        assert(w.addModule("keys", writerOf("synth.fm_synth")).ok);

        immutable ProjectEditResult blocked = w.writeFile(path);
        assert(!blocked.ok && blocked.problem.kind == ProjectProblemKind.writeFailed);
        assert(blocked.problem.subject == path);
        assert(blocked.problem.reason.startsWith("could not write the project: "));
        assert(!exists(path));
        immutable ProjectEditResult emptyPath = w.writeFile("");
        assert(!emptyPath.ok && emptyPath.problem.kind == ProjectProblemKind.writeFailed);
        assert(emptyPath.problem.subject == "");

        LoadedProject broken;
        broken.title = "Broken";
        broken.bpm = 5.0;
        ProjectBytesResult brokenBytes = w.documentBytes(broken);
        assert(!brokenBytes.ok && brokenBytes.problem.kind == ProjectProblemKind.invalidProject);
        assert(brokenBytes.problem.subject == "Broken");
        assert(brokenBytes.problem.reason == "the project cannot be saved: Out-of-range BPM or TPL");

        mkdirRecurse(root);
        immutable ProjectEditResult written = w.writeFile(path);
        assert(written.ok, written.problem.reason);

        LoadedProject read;
        string err;
        assert(loadProjectFile(path, read, err), err);
        assert(read.title == "Night Drive" && read.bpm == 96.0 && read.ticksPerLine == 4);
        assert(read.timeSigNumerator == 6 && read.timeSigDenominator == 8);
        assert(read.keyTonic == 9 && read.keyMode == 1);
        assert(read.modules.length == 3 && read.patterns.length == 1 && read.clips.length == 1);
        assert(read.wires.length == 0);
        assert(read.modules[0].id == 1 && read.modules[0].typeId == "core.output");
        assert(read.modules[0].name == "Master Output");
        assert(read.modules[0].posX == 240.0f && read.modules[0].posY == 60.0f);
        assert(read.modules[1].id == 2 && read.modules[1].typeId == "synth.analog_gen");
        assert(read.modules[1].name == "bass");
        assert(read.modules[1].posX == 60.0f && read.modules[1].posY == 60.0f);
        assert(read.modules[2].id == 3 && read.modules[2].typeId == "synth.fm_synth");
        assert(read.modules[2].name == "keys");
        assert(read.modules[2].posX == 60.0f && read.modules[2].posY == 220.0f);
        assert(read.patterns[0].patternId == 1 && read.patterns[0].tracks == 4);
        assert(read.patterns[0].lines == 64 && read.patterns[0].name == "Pattern 01");
        assert(read.patterns[0].cells.length == 256);
        assert(read.clips[0] == TimelineClip(1, 1, 0, 0, 64, 0, 0, false, false, false));

        ProjectBytesResult bytes = w.msvBytes();
        assert(bytes.ok, bytes.problem.reason);
        LoadedProject fromBytes;
        string bytesErr;
        assert(loadProject(bytes.bytes, fromBytes, bytesErr), bytesErr);
        assert(fromBytes == read);

        StudioSession session = new StudioSession();
        assert(session.initialize(44_100.0f));
        scope (exit) {
            session.shutdown();
        }
        string openErr;
        assert(session.openProjectFile(path, openErr), openErr);
        assert(session.document().modules.length == 3);
        assert(session.document().title == "Night Drive");

        rmdirRecurse(root);
    }
}
