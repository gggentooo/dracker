/**
 * File:         tests/unit/compose_end_to_end_test.d
 * Module:       tests.unit.compose_end_to_end_test
 * Phase:        Composition helper (dracker-compose) — T88 (End-to-end check)
 *
 * Purpose:
 *   End-to-end verification of `dracker-compose` across both in-process `runProgram` and the
 *   compiled `build/dracker-compose` binary using the complete script-authored song
 *   `sample-projects/neon_drift.dcs`: validates `catalog`, `check` (no files written, including
 *   `savemodule` + `file=` reuse via the virtual preset cache), `run` (saving custom `.msym` and
 *   `.msv`), `render` (non-silent bars, clean headroom, every synth & effect producing sound),
 *   opening and verifying the resulting song in `StudioSession`, `describe` round-tripping to
 *   byte-identical `.msv` output, and sample-project consistency against the committed
 *   `sample-projects/neon_drift_lead.msym` and `sample-projects/neon_drift.msv` artifacts.
 *
 * Real-Time & Safety Contract:
 *   Off-RT integration tests; temporary files live under tempDir() and clean up via scope(exit).
 *
 * Dependencies:
 *   Internal: app.music_theory (KeyMode), app.session (StudioSession), compose_main (ProgramIo,
 *             runProgram)
 *   External: std.algorithm (canFind), std.array (replace), std.file (exists, mkdirRecurse, read,
 *             readText, rmdirRecurse, tempDir, write), std.json (JSONValue, parseJSON), std.path
 *             (buildPath), std.process (execute, thisProcessID), std.conv (to)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) end-to-end workflow tests for T88
 *
 * See_Also:
 *   docs/todo.md (T88), sample-projects/neon_drift.dcs, ci/macos.yml, source/compose_main.d
 */
module tests.unit.compose_end_to_end_test;

version (unittest) {
    import std.algorithm : canFind;
    import std.array : replace;
    import std.conv : to;
    import std.file : exists, mkdirRecurse, read, readText, rmdirRecurse, tempDir, writeFile = write;
    import std.json : JSONValue, parseJSON;
    import std.path : buildPath;
    import std.process : execute, thisProcessID;

    import app.music_theory : KeyMode;
    import app.session : StudioSession;
    import compose_main : ProgramIo, runProgram;

    private int runInProcess(const(string)[] args, out string stdoutText, out string stderrText) {
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
        stdoutText = ob;
        stderrText = eb;
        return code;
    }

    private string rewriteNeonScript(string msymPath, string msvPath) {
        immutable string src = readText("sample-projects/neon_drift.dcs");
        return src
            .replace("sample-projects/neon_drift_lead.msym", msymPath)
            .replace("sample-projects/neon_drift.msv", msvPath);
    }

    private void verifyStudioSessionDocument(string msvPath) {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();

        string openErr;
        assert(s.openProjectFile(msvPath, openErr), openErr);
        const doc = s.document();
        assert(doc.title == "Neon Drift");
        assert(doc.bpm == 104.0);
        assert(doc.timeSigNumerator == 4 && doc.timeSigDenominator == 4);
        assert(doc.keyTonic == 2 && doc.keyMode == cast(ubyte) KeyMode.minor);
        assert(doc.loopStartLine == 64 && doc.loopEndLine == 192);
        assert(doc.modules.length == 9);
        assert(doc.patterns.length == 19);
        assert(doc.clips.length >= 16);

        bool foundBass = false;
        bool foundKeys = false;
        bool foundLead = false;
        bool foundHarmony = false;
        bool foundKit = false;
        bool foundDelay = false;
        bool foundReverb = false;
        bool foundComp = false;
        size_t leadIdx = 0;
        size_t harmonyIdx = 0;
        size_t delayIdx = 0;
        size_t reverbIdx = 0;
        size_t compIdx = 0;
        size_t kitIdx = 0;

        foreach (i, ref m; doc.modules) {
            if (m.name == "bass") foundBass = true;
            else if (m.name == "keys") foundKeys = true;
            else if (m.name == "Neon Lead") {
                foundLead = true;
                leadIdx = i;
            } else if (m.name == "Neon Harmony") {
                foundHarmony = true;
                harmonyIdx = i;
            } else if (m.name == "kit") {
                foundKit = true;
                kitIdx = i;
            } else if (m.name == "delay" && m.typeId == "fx.delay") {
                foundDelay = true;
                delayIdx = i;
            } else if (m.name == "reverb" && m.typeId == "fx.reverb") {
                foundReverb = true;
                reverbIdx = i;
            } else if (m.name == "bus_comp" && m.typeId == "fx.compressor") {
                foundComp = true;
                compIdx = i;
            }
        }
        assert(foundBass && foundKeys && foundLead && foundHarmony && foundKit
            && foundDelay && foundReverb && foundComp);

        assert(doc.modules[harmonyIdx].typeId == doc.modules[leadIdx].typeId);
        assert(doc.modules[harmonyIdx].paramValues[0] == doc.modules[leadIdx].paramValues[0]);
        assert(doc.modules[harmonyIdx].paramValues[3] != doc.modules[leadIdx].paramValues[3]);

        immutable uint leadId = doc.modules[leadIdx].id;
        immutable uint harmId = doc.modules[harmonyIdx].id;
        immutable uint delayId = doc.modules[delayIdx].id;
        immutable uint reverbId = doc.modules[reverbIdx].id;
        immutable uint compId = doc.modules[compIdx].id;
        immutable uint kitId = doc.modules[kitIdx].id;

        immutable uint outId = doc.modules[0].id;
        bool hasLeadDelay = false;
        bool hasHarmDelay = false;
        bool hasDelayReverb = false;
        bool hasReverbComp = false;
        bool hasKitSidechain = false;
        bool hasCompOut = false;
        foreach (ref w; doc.wires) {
            if (w.srcMod == leadId && w.dstMod == delayId) hasLeadDelay = true;
            if (w.srcMod == harmId && w.dstMod == delayId) hasHarmDelay = true;
            if (w.srcMod == delayId && w.dstMod == reverbId) hasDelayReverb = true;
            if (w.srcMod == reverbId && w.dstMod == compId) hasReverbComp = true;
            if (w.srcMod == kitId && w.dstMod == compId && w.dstPort == 1) hasKitSidechain = true;
            if (w.srcMod == compId && w.dstMod == outId) hasCompOut = true;
        }
        assert(hasLeadDelay && hasHarmDelay && hasDelayReverb && hasReverbComp
            && hasKitSidechain && hasCompOut);
    }

    unittest {
        immutable string dir = buildPath(tempDir(),
            "dracker_t88_inproc_" ~ to!string(thisProcessID()));
        mkdirRecurse(dir);
        scope (exit) {
            if (exists(dir)) {
                rmdirRecurse(dir);
            }
        }

        immutable string scriptPath = buildPath(dir, "song.dcs");
        immutable string msymPath = buildPath(dir, "lead.msym");
        immutable string msvPath = buildPath(dir, "song.msv");
        immutable string wavPath = buildPath(dir, "song.wav");
        immutable string descPath = buildPath(dir, "described.dcs");
        immutable string rtPath = buildPath(dir, "roundtrip.msv");
        writeFile(scriptPath, rewriteNeonScript(msymPath, msvPath));

        string outText;
        string errText;
        assert(runInProcess(["--json", "check", scriptPath], outText, errText) == 0, errText ~ outText);
        JSONValue chkJson = parseJSON(outText);
        assert(chkJson["ok"].boolean && chkJson["commands"].integer == 75);
        assert(!exists(msymPath) && !exists(msvPath));

        assert(runInProcess(["--json", "run", scriptPath], outText, errText) == 0, errText ~ outText);
        JSONValue runJson = parseJSON(outText);
        assert(runJson["ok"].boolean && runJson["written"].array.length == 2);
        assert(exists(msymPath) && exists(msvPath));

        assert(runInProcess(["--json", "render", msvPath, "-o", wavPath], outText, errText) == 0,
            errText ~ outText);
        assert(exists(wavPath));
        JSONValue renJson = parseJSON(outText);
        assert(renJson["ok"].boolean);
        assert(renJson["arrangementBars"].integer == 16);
        assert(renJson["silentBars"].array.length == 0);
        assert(!renJson["limiterReached"].boolean);
        assert(renJson["peak"].floating > 0.1 && renJson["peak"].floating < 0.99);
        assert(renJson["modules"].array.length == 9);
        foreach (modObj; renJson["modules"].array) {
            assert(modObj["producedSound"].boolean, modObj["name"].str);
        }

        verifyStudioSessionDocument(msvPath);

        assert(runInProcess(["--json", "describe", msvPath], outText, errText) == 0, errText ~ outText);
        JSONValue descJson = parseJSON(outText);
        assert(descJson["ok"].boolean && descJson["kind"].str == "project");
        immutable string descScript = descJson["script"].str;
        assert(descScript.canFind("project \"Neon Drift\""));
        writeFile(descPath, descScript);

        assert(runInProcess(["--json", "check", descPath], outText, errText) == 0, errText ~ outText);
        assert(runInProcess(["--json", "run", descPath, "-o", rtPath], outText, errText) == 0,
            errText ~ outText);
        assert(cast(const(ubyte)[]) read(msvPath) == cast(const(ubyte)[]) read(rtPath));
    }

    unittest {
        immutable string binPath = "build/dracker-compose";
        if (!exists(binPath)) {
            return;
        }
        immutable string dir = buildPath(tempDir(),
            "dracker_t88_cli_" ~ to!string(thisProcessID()));
        mkdirRecurse(dir);
        scope (exit) {
            if (exists(dir)) {
                rmdirRecurse(dir);
            }
        }

        immutable string scriptPath = buildPath(dir, "song.dcs");
        immutable string msymPath = buildPath(dir, "lead.msym");
        immutable string msvPath = buildPath(dir, "song.msv");
        immutable string wavPath = buildPath(dir, "song.wav");
        immutable string descPath = buildPath(dir, "described.dcs");
        immutable string rtPath = buildPath(dir, "roundtrip.msv");
        writeFile(scriptPath, rewriteNeonScript(msymPath, msvPath));

        auto catRes = execute([binPath, "--json", "catalog"]);
        assert(catRes.status == 0, catRes.output);
        JSONValue catJson = parseJSON(catRes.output);
        assert(catJson["ok"].boolean && catJson["presets"].array.length == 16);

        auto chkRes = execute([binPath, "--json", "check", scriptPath]);
        assert(chkRes.status == 0, chkRes.output);
        assert(!exists(msymPath) && !exists(msvPath));

        auto runRes = execute([binPath, "--json", "run", scriptPath]);
        assert(runRes.status == 0, runRes.output);
        assert(exists(msymPath) && exists(msvPath));

        auto renRes = execute([binPath, "--json", "render", msvPath, "-o", wavPath]);
        assert(renRes.status == 0, renRes.output);
        JSONValue renJson = parseJSON(renRes.output);
        assert(renJson["ok"].boolean && renJson["silentBars"].array.length == 0
            && !renJson["limiterReached"].boolean);

        auto descRes = execute([binPath, "--json", "describe", msvPath]);
        assert(descRes.status == 0, descRes.output);
        JSONValue descJson = parseJSON(descRes.output);
        assert(descJson["ok"].boolean && descJson["kind"].str == "project");
        writeFile(descPath, descJson["script"].str);

        auto descChk = execute([binPath, "--json", "check", descPath]);
        assert(descChk.status == 0, descChk.output);
        auto descRun = execute([binPath, "--json", "run", descPath, "-o", rtPath]);
        assert(descRun.status == 0, descRun.output);
        assert(cast(const(ubyte)[]) read(msvPath) == cast(const(ubyte)[]) read(rtPath));
    }

    unittest {
        assert(exists("sample-projects/neon_drift.dcs"));
        assert(exists("sample-projects/neon_drift_lead.msym"));
        assert(exists("sample-projects/neon_drift.msv"));
        verifyStudioSessionDocument("sample-projects/neon_drift.msv");

        immutable string dir = buildPath(tempDir(),
            "dracker_t88_sample_" ~ to!string(thisProcessID()));
        mkdirRecurse(dir);
        scope (exit) {
            if (exists(dir)) {
                rmdirRecurse(dir);
            }
        }
        immutable string scriptPath = buildPath(dir, "song.dcs");
        immutable string msymPath = buildPath(dir, "lead.msym");
        immutable string msvPath = buildPath(dir, "song.msv");
        writeFile(scriptPath, rewriteNeonScript(msymPath, msvPath));

        string outText;
        string errText;
        assert(runInProcess(["run", scriptPath], outText, errText) == 0, errText ~ outText);
        assert(cast(const(ubyte)[]) read("sample-projects/neon_drift_lead.msym")
            == cast(const(ubyte)[]) read(msymPath));
        assert(cast(const(ubyte)[]) read("sample-projects/neon_drift.msv")
            == cast(const(ubyte)[]) read(msvPath));
    }
}
