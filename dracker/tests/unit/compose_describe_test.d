/**
 * File:         tests/unit/compose_describe_test.d
 * Module:       tests.unit.compose_describe_test
 * Phase:        Composition helper (dracker-compose) — T87 & T107 (Describe preset & project tests)
 *
 * Purpose:
 *   Unit tests for compose.script.describe and `dracker-compose describe`:
 *   verifies T87 lossless round-tripping of project properties, modules, non-default parameters,
 *   positions, wires, all bundled `.msym` presets under `resources/presets/`, `keep=` preservation of
 *   Sampler `extraBlob` and MetaModule `childProjectMsv`, and CLI text/JSON output; and verifies
 *   T107 full-song round-tripping for helper-written multi-section melodic + drum compositions, mixed
 *   `notes` + `cells` effects + raw patterns, and bundled `.msv` sample projects rendered offline via
 *   StudioSession sample-for-sample.
 *
 * Real-Time & Safety Contract:
 *   Off-RT unit tests; temporary files cleaned via scope(exit).
 *
 * Dependencies:
 *   Internal: app.music_theory (KeyMode, MusicalKey), app.session (StudioSession), compose.drum_writer
 *             (DrumWriter), compose.module_writer (ModuleWriter), compose.part_writer (PartWriter),
 *             compose.project_writer (ProjectDocumentResult, ProjectWriter), compose.script.commands
 *             (createDefaultInterpreter), compose.script.describe, compose.script.interpreter
 *             (RunResult, ScriptInterpreter), compose.timing (BeatPosition, Length, TimeSignature),
 *             compose_main (ProgramIo, runProgram), foundation.types (FIXED_BLOCK_FRAMES),
 *             io.project_format (LoadedPreset, LoadedProject, loadPreset, loadProjectFile, saveProject,
 *             serializeProject), sequencer.note (NoteCell, NoteCmd)
 *   External: std.algorithm (canFind, endsWith), std.file (dirEntries, exists, mkdirRecurse, read,
 *             rmdirRecurse, SpanMode, tempDir), std.math (fabs), std.path (buildPath)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites for T87 & T107
 *
 * See_Also:
 *   docs/todo.md (T71, T87, T107), source/compose/script/describe.d, source/compose_main.d
 */
module tests.unit.compose_describe_test;

version (unittest) {
    import std.algorithm : canFind, endsWith;
    import std.file : dirEntries, exists, mkdirRecurse, read, rmdirRecurse, SpanMode, tempDir;
    import std.json : JSONValue, parseJSON;
    import std.math : fabs;
    import std.path : buildPath;

    import app.music_theory : KeyMode, MusicalKey;
    import app.session : StudioSession;
    import compose.drum_writer : DrumWriter;
    import compose.module_writer : ModuleWriter;
    import compose.part_writer : PartWriter;
    import compose.project_writer : ProjectDocumentResult, ProjectWriter;
    import compose.script.commands : createDefaultInterpreter;
    import compose.script.describe : describePresetFile, describeProject, describeProjectFile,
        DescribeResult;
    import compose.script.interpreter : RunResult, ScriptInterpreter;
    import compose.timing : BeatPosition, Length, TimeSignature;
    import compose_main : ProgramIo, runProgram;
    import foundation.types : FIXED_BLOCK_FRAMES;
    import io.project_format : LoadedPreset, LoadedProject, loadPreset, loadProjectFile, saveProject,
        serializeProject;
    import sequencer.note : NoteCell, NoteCmd;

    private ubyte[] serializeBuiltProject(const ref LoadedProject doc) {
        ubyte[] bytes;
        string err;
        assert(serializeProject(doc, bytes, err), err);
        return bytes;
    }

    private void renderStereoBlocks(const ref LoadedProject proj, size_t blocks, out float[] outL,
            out float[] outR, out float peak) {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string openErr;
        assert(s.openProjectFromMemory(proj, openErr), openErr);
        s.engine().reset();
        s.engine().setTempo(proj.bpm, proj.ticksPerLine);
        s.engine().seekLine(0);
        s.engine().setPlaying(true);

        immutable size_t total = blocks * FIXED_BLOCK_FRAMES;
        outL = new float[total];
        outR = new float[total];
        const(float[])[2] emptyIn = [null, null];
        peak = 0.0f;
        foreach (b; 0 .. blocks) {
            immutable size_t off = b * FIXED_BLOCK_FRAMES;
            float[][2] outs = [
                outL[off .. off + FIXED_BLOCK_FRAMES],
                outR[off .. off + FIXED_BLOCK_FRAMES]
            ];
            s.engine().processHostBuffer(outs, emptyIn, FIXED_BLOCK_FRAMES);
            foreach (k; 0 .. FIXED_BLOCK_FRAMES) {
                immutable float al = fabs(outL[off + k]);
                immutable float ar = fabs(outR[off + k]);
                if (al > peak) peak = al;
                if (ar > peak) peak = ar;
            }
        }
        s.engine().setPlaying(false);
    }

    unittest {
        ProjectWriter pw = new ProjectWriter();
        assert(pw.setTitle("Synth Lab").ok);
        assert(pw.setTempo(108.5).ok);
        assert(pw.setTicksPerLine(4).ok);
        assert(pw.setTimeSignature(TimeSignature(6, 8)).ok);
        assert(pw.setKey(MusicalKey(9, KeyMode.minor)).ok);

        auto bassRes = ModuleWriter.fromType("synth.analog_gen");
        assert(bassRes.ok);
        assert(bassRes.writer.setParamText("Waveform", "saw").ok);
        assert(bassRes.writer.setParamValue("Release", 0.45f).ok);
        assert(pw.addModule("bass", bassRes.writer).ok);
        assert(pw.setModuleName("bass", "Warm Bass").ok);
        assert(pw.moveModule("bass", 140.0f, 95.0f).ok);

        auto compRes = ModuleWriter.fromType("fx.compressor");
        assert(compRes.ok);
        assert(compRes.writer.setParamValue("Ratio", 6.0f).ok);
        assert(pw.addModule("comp", compRes.writer).ok);

        assert(pw.connect("bass", "comp", 0.75f).ok);
        assert(pw.connect("comp", "out", 0.6f).ok);
        assert(pw.connect("bass", "comp", 0.5f, "", "Sidechain").ok);

        ProjectDocumentResult origDocRes = pw.document();
        assert(origDocRes.ok, origDocRes.problem.reason);
        LoadedProject origDoc = origDocRes.project;
        immutable DescribeResult desc = describeProject(origDoc, "", false);
        assert(desc.ok, desc.error);
        assert(desc.kind == "project");

        ScriptInterpreter interp = createDefaultInterpreter(false);
        RunResult rr = interp.runScript(desc.script);
        assert(rr.ok, rr.problems.length > 0 ? rr.problems[0].text() : desc.script);
        ProjectDocumentResult rtDocRes = interp.buildDocument();
        assert(rtDocRes.ok, rtDocRes.problem.reason);
        LoadedProject rtDoc = rtDocRes.project;

        assert(serializeBuiltProject(origDoc) == serializeBuiltProject(rtDoc));
    }

    unittest {
        size_t presetCount = 0;
        foreach (entry; dirEntries("resources/presets", SpanMode.depth)) {
            if (!entry.isFile || !entry.name.endsWith(".msym")) {
                continue;
            }
            presetCount++;
            immutable DescribeResult dr = describePresetFile(entry.name);
            assert(dr.ok, entry.name ~ ": " ~ dr.error);
            assert(dr.kind == "preset");

            ScriptInterpreter interp = createDefaultInterpreter(false);
            RunResult rr = interp.runScript(dr.script);
            assert(rr.ok, entry.name ~ ": " ~ (rr.problems.length > 0 ? rr.problems[0].text() : ""));
            string[] handles = interp.project().handles();
            assert(handles.length == 2);
            auto mRes = interp.project().moduleOf(handles[1]);
            assert(mRes.ok);

            const(ubyte)[] raw = cast(const(ubyte)[]) read(entry.name);
            LoadedPreset origPreset;
            string pErr;
            assert(loadPreset(raw, origPreset, pErr), pErr);
            auto rtSaved = mRes.writer.savedModule(mRes.id);
            assert(rtSaved.typeId == origPreset.mod.typeId);
            assert(rtSaved.paramValues.length == origPreset.mod.paramValues.length);
            foreach (pi; 0 .. origPreset.mod.paramValues.length) {
                assert(fabs(rtSaved.paramValues[pi] - origPreset.mod.paramValues[pi]) < 1e-4f,
                    entry.name);
            }
        }
        assert(presetCount == 16);
    }

    unittest {
        immutable string dir = buildPath(tempDir(), "dracker_describe_keep_test");
        mkdirRecurse(dir);
        scope (exit) {
            if (exists(dir)) {
                rmdirRecurse(dir);
            }
        }
        immutable string msvPath = buildPath(dir, "opaque.msv");

        ProjectWriter child = new ProjectWriter();
        assert(child.setTitle("Inner").ok);
        auto innerGen = ModuleWriter.fromType("synth.fm_synth");
        assert(innerGen.ok);
        assert(child.addModule("in_gen", innerGen.writer).ok);
        assert(child.connect("in_gen", "out").ok);
        ProjectDocumentResult childDocRes = child.document();
        assert(childDocRes.ok, childDocRes.problem.reason);
        ubyte[] childBytes = serializeBuiltProject(childDocRes.project);

        auto sampRes = ModuleWriter.fromType("synth.sampler");
        assert(sampRes.ok);
        auto metaRes = ModuleWriter.fromType("ctl.metamodule");
        assert(metaRes.ok);

        ProjectWriter ow = new ProjectWriter();
        assert(ow.setTitle("Opaque Test").ok);
        assert(ow.addModule("samp", sampRes.writer).ok);
        assert(ow.setModuleName("samp", "My Sample").ok);
        assert(ow.addModule("meta", metaRes.writer).ok);
        assert(ow.setModuleName("meta", "Inner Meta").ok);
        ProjectDocumentResult owRes = ow.document();
        assert(owRes.ok, owRes.problem.reason);
        LoadedProject doc = owRes.project;
        doc.modules[1].extraBlob = [1, 2, 3, 4, 5, 6, 7, 8];
        doc.modules[2].hasChildProject = true;
        doc.modules[2].childProjectMsv = childBytes.dup;

        string saveErr;
        assert(saveProject(doc, msvPath, saveErr), saveErr);

        immutable DescribeResult dr = describeProjectFile(msvPath);
        assert(dr.ok, dr.error);
        assert(dr.script.canFind("keep="));

        ScriptInterpreter interp = createDefaultInterpreter(false);
        RunResult rr = interp.runScript(dr.script);
        assert(rr.ok, rr.problems.length > 0 ? rr.problems[0].text() : "");
        ProjectDocumentResult rtRes = interp.buildDocument();
        assert(rtRes.ok, rtRes.problem.reason);
        LoadedProject rt = rtRes.project;
        assert(rt.modules.length == 3);
        assert(rt.modules[1].extraBlob == doc.modules[1].extraBlob);
        assert(rt.modules[2].hasChildProject && rt.modules[2].childProjectMsv == childBytes);

        int runCli(string[] args, out string outText, out string errText) {
            string ob = "";
            string eb = "";
            ProgramIo io;
            io.writeOutput = (string s) @safe { ob ~= s; };
            io.writeError = (string s) @safe { eb ~= s; };
            io.readInputFile = (string path, out ubyte[] bytes, out string err) @trusted nothrow {
                try {
                    bytes = cast(ubyte[]) read(path);
                    return true;
                } catch (Exception ex) {
                    bytes = null;
                    err = ex.msg;
                    return false;
                }
            };
            immutable int code = runProgram(args, io);
            outText = ob;
            errText = eb;
            return code;
        }

        string cliOut;
        string cliErr;
        assert(runCli(["describe", msvPath], cliOut, cliErr) == 0 && cliErr.length == 0);
        assert(cliOut.canFind("Opaque Test"));

        assert(runCli(["describe", "--json", "resources/presets/Keys/Electric Piano.msym"],
            cliOut, cliErr) == 0 && cliErr.length == 0);
        JSONValue j = parseJSON(cliOut);
        assert(j["ok"].boolean && j["subcommand"].str == "describe" && j["kind"].str == "preset");
        assert(j["script"].str.canFind("Electric Piano") || j["script"].str.canFind("fm_synth"));
    }

    unittest {
        ProjectWriter pw = new ProjectWriter();
        assert(pw.setTitle("Song Roundtrip").ok);
        assert(pw.setTempo(112.0).ok);
        assert(pw.setTimeSignature(TimeSignature(4, 4)).ok);
        assert(pw.setKey(MusicalKey(9, KeyMode.minor)).ok);

        auto keysRes = ModuleWriter.fromType("synth.fm_synth");
        auto bassRes = ModuleWriter.fromType("synth.analog_gen");
        auto kitRes = ModuleWriter.fromType("synth.drumsynth");
        assert(keysRes.ok && bassRes.ok && kitRes.ok);
        assert(pw.addModule("keys", keysRes.writer).ok);
        assert(pw.addModule("bass", bassRes.writer).ok);
        assert(pw.addModule("kit", kitRes.writer).ok);
        assert(pw.connect("keys", "out", 0.4f).ok);
        assert(pw.connect("bass", "out", 0.5f).ok);
        assert(pw.connect("kit", "out", 0.6f).ok);

        PartWriter parts = new PartWriter(pw);
        DrumWriter drums = new DrumWriter(parts);
        assert(parts.addSection("verse", 2).ok);
        assert(parts.addSection("chorus", 2).ok);
        assert(parts.addPart("keys", "keys").ok);
        assert(parts.addPart("bass", "bass").ok);
        assert(drums.addDrumPart("drums", "kit").ok);

        assert(parts.writeNote("keys", "verse", BeatPosition(1, 1, 1), Length(8), 69, 0.8f).ok);
        assert(parts.writeNote("keys", "verse", BeatPosition(1, 1, 1), Length(8), 72, 0.8f).ok);
        assert(parts.writeNote("keys", "verse", BeatPosition(2, 1, 1), Length(4), 67, 0.6f).ok);
        assert(parts.writeNote("bass", "verse", BeatPosition(1, 1, 1), Length(16), 45, 0.9f).ok);
        assert(parts.writeNote("keys", "chorus", BeatPosition(1, 1, 1), Length(8), 76, 1.0f).ok);
        assert(drums.writeSteps("drums", "verse", "Kick", "x...x...x...X...").ok);
        assert(drums.writeSteps("drums", "chorus", "Snare", "....X.......g...", BeatPosition(1, 1, 1),
            0.8f, 1.0f, 0.45f).ok);

        assert(parts.arrange(["verse", "chorus", "verse"]).ok);
        assert(parts.setLoopLines(32, 96).ok);

        ProjectDocumentResult origDocRes = parts.buildDocument();
        assert(origDocRes.ok, origDocRes.problem.reason);
        LoadedProject origDoc = origDocRes.project;
        immutable DescribeResult dr = describeProject(origDoc);
        assert(dr.ok, dr.error);

        ScriptInterpreter interp = createDefaultInterpreter(false);
        RunResult rr = interp.runScript(dr.script);
        assert(rr.ok, (rr.problems.length > 0 ? rr.problems[0].text() : "") ~ "\n" ~ dr.script);
        ProjectDocumentResult rtDocRes = interp.buildDocument();
        assert(rtDocRes.ok, rtDocRes.problem.reason);
        LoadedProject rtDoc = rtDocRes.project;

        import std.format : format;
        assert(origDoc.modules == rtDoc.modules, "modules differ");
        assert(origDoc.wires == rtDoc.wires, "wires differ");
        assert(origDoc.patterns.length == rtDoc.patterns.length, format("pat len %s vs %s\n%s",
            origDoc.patterns.length, rtDoc.patterns.length, dr.script));
        foreach (pi; 0 .. origDoc.patterns.length) {
            assert(origDoc.patterns[pi] == rtDoc.patterns[pi], format("pat %s differs:\norig=%s\nrt=%s\nscript:\n%s",
                pi, origDoc.patterns[pi], rtDoc.patterns[pi], dr.script));
        }
        assert(origDoc.clips == rtDoc.clips, format("clips differ:\norig=%s\nrt=%s\nscript:\n%s",
            origDoc.clips, rtDoc.clips, dr.script));
        assert(origDoc.loopStartLine == rtDoc.loopStartLine && origDoc.loopEndLine == rtDoc.loopEndLine,
            format("loop differs: %s..%s vs %s..%s", origDoc.loopStartLine, origDoc.loopEndLine,
                rtDoc.loopStartLine, rtDoc.loopEndLine));
        assert(serializeBuiltProject(origDoc) == serializeBuiltProject(rtDoc));
    }

    unittest {
        ProjectWriter pw = new ProjectWriter();
        assert(pw.setTitle("Mixed Cells & Raw").ok);
        auto leadRes = ModuleWriter.fromType("synth.fm_synth");
        assert(leadRes.ok);
        assert(pw.addModule("lead", leadRes.writer).ok);
        assert(pw.connect("lead", "out", 0.5f).ok);

        PartWriter parts = new PartWriter(pw);
        assert(parts.addSection("main", 1).ok);
        assert(parts.addPart("lead", "lead").ok);
        assert(parts.writeNote("lead", "main", BeatPosition(1, 1, 1), Length(4), 60, 0.8f).ok);
        immutable uint patId = parts.patternFor("lead", "main").pattern.patternId;
        assert(parts.writeCell(patId, 0, 5, NoteCell(NoteCmd.noteOff, 0, 1, 0, 0x03, 0x28)).ok);

        auto rawRes = parts.addRawPattern("fill_pat", 2, 16);
        assert(rawRes.ok);
        assert(parts.writeCell(rawRes.pattern.patternId, 1, 4, NoteCell.makeNote(67, 0.9f, 1, 0x01, 0x10)).ok);

        assert(parts.addRawClip(patId, 0, 16, 0).ok);
        assert(parts.addRawClip(rawRes.pattern.patternId, 8, 8, 1).ok);

        ProjectDocumentResult origDocRes = parts.buildDocument();
        assert(origDocRes.ok, origDocRes.problem.reason);
        LoadedProject origDoc = origDocRes.project;
        immutable DescribeResult dr = describeProject(origDoc);
        assert(dr.ok, dr.error);
        assert(dr.script.canFind("fx=0x03") && dr.script.canFind("arrange clip="));

        ScriptInterpreter interp = createDefaultInterpreter(false);
        RunResult rr = interp.runScript(dr.script);
        assert(rr.ok, (rr.problems.length > 0 ? rr.problems[0].text() : "") ~ "\n" ~ dr.script);
        ProjectDocumentResult rtDocRes = interp.buildDocument();
        assert(rtDocRes.ok, rtDocRes.problem.reason);
        LoadedProject rtDoc = rtDocRes.project;

        assert(rtDoc.patterns.length == origDoc.patterns.length);
        foreach (i; 0 .. origDoc.patterns.length) {
            assert(rtDoc.patterns[i].tracks == origDoc.patterns[i].tracks);
            assert(rtDoc.patterns[i].lines == origDoc.patterns[i].lines);
            assert(rtDoc.patterns[i].cells == origDoc.patterns[i].cells);
        }
        assert(rtDoc.clips.length == origDoc.clips.length);
        foreach (i; 0 .. origDoc.clips.length) {
            assert(rtDoc.clips[i].startLine == origDoc.clips[i].startLine);
            assert(rtDoc.clips[i].lengthLines == origDoc.clips[i].lengthLines);
            assert(rtDoc.clips[i].laneY == origDoc.clips[i].laneY);
        }
    }

    unittest {
        foreach (samplePath; [
            "sample-projects/midnight_pulse.msv",
            "sample-projects/lobby_waltz.msv"
        ]) {
            LoadedProject origDoc;
            string loadErr;
            assert(loadProjectFile(samplePath, origDoc, loadErr), loadErr);

            immutable DescribeResult dr = describeProjectFile(samplePath);
            assert(dr.ok, samplePath ~ ": " ~ dr.error);

            ScriptInterpreter interp = createDefaultInterpreter(false);
            RunResult rr = interp.runScript(dr.script);
            assert(rr.ok, samplePath ~ ": "
                ~ (rr.problems.length > 0 ? rr.problems[0].text() : ""));
            ProjectDocumentResult rtDocRes = interp.buildDocument();
            assert(rtDocRes.ok, rtDocRes.problem.reason);
            LoadedProject rtDoc = rtDocRes.project;

            float[] origL;
            float[] origR;
            float origPeak = 0.0f;
            float[] rtL;
            float[] rtR;
            float rtPeak = 0.0f;
            renderStereoBlocks(origDoc, 345, origL, origR, origPeak);
            renderStereoBlocks(rtDoc, 345, rtL, rtR, rtPeak);

            assert(origPeak > 0.001f, samplePath ~ " rendered silent");
            assert(rtPeak > 0.001f, samplePath ~ " round-trip rendered silent");
            assert(origL.length == rtL.length);
            foreach (k; 0 .. origL.length) {
                assert(fabs(origL[k] - rtL[k]) < 1e-5f, samplePath ~ " left mismatch");
                assert(fabs(origR[k] - rtR[k]) < 1e-5f, samplePath ~ " right mismatch");
            }
        }
    }
}
