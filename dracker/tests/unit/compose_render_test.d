/**
 * File:         tests/unit/compose_render_test.d
 * Module:       tests.unit.compose_render_test
 * Phase:        Composition helper (dracker-compose) — T86 (Render and report tests)
 *
 * Purpose:
 *   Unit tests for compose.render: verifies offline WAV export, overall length/peak/RMS levels, per-bar
 *   peak/average measurement and silent-bar detection, per-module producedSound flags, master output
 *   limiter detection on hot signals, and text + valid JSON formatting.
 *
 * Real-Time & Safety Contract:
 *   Off-RT unit tests; temporary WAV files removed via scope(exit).
 *
 * Dependencies:
 *   Internal: compose.module_writer, compose.part_writer, compose.project_writer, compose.render,
 *             compose.timing
 *   External: std.algorithm (canFind), std.file (exists, mkdirRecurse, rmdirRecurse, tempDir),
 *             std.json (JSONValue, parseJSON), std.path (buildPath)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) tests covering all T86 requirements
 *
 * See_Also:
 *   docs/todo.md (T66, T86), source/compose/render.d
 */
module tests.unit.compose_render_test;

version (unittest) {
    import std.algorithm : canFind;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.json : JSONValue, parseJSON;
    import std.path : buildPath;

    import compose.module_writer : ModuleWriter;
    import compose.part_writer : PartWriter;
    import compose.project_writer : ProjectWriter;
    import compose.render : renderProjectWithReport, renderReportJson, renderReportText, RenderResult;
    import compose.timing : BeatPosition, Length;

    unittest {
        immutable string root = buildPath(tempDir(), "dracker_t86_render_test");
        if (exists(root)) {
            rmdirRecurse(root);
        }
        mkdirRecurse(root);
        scope (exit) {
            if (exists(root)) {
                rmdirRecurse(root);
            }
        }

        ProjectWriter proj = new ProjectWriter();
        assert(proj.setTempo(120.0).ok);
        auto lead = ModuleWriter.fromType("synth.analog_gen");
        auto idle = ModuleWriter.fromType("synth.fm_synth");
        assert(lead.ok && idle.ok);
        assert(proj.addModule("lead", lead.writer).ok);
        assert(proj.addModule("idle", idle.writer).ok);
        assert(proj.connect("lead", "out", 0.7f).ok);
        assert(proj.connect("idle", "out", 0.7f).ok);

        PartWriter pw = new PartWriter(proj);
        assert(pw.addSection("a", 1).ok);
        assert(pw.addSection("rest", 1).ok);
        assert(pw.addPart("lead", "lead").ok);
        assert(pw.writeNote("lead", "a", BeatPosition(1, 1, 1), Length(4), 60, 0.9f).ok);
        assert(pw.arrange(["a", "rest"]).ok);

        auto docRes = pw.buildDocument();
        assert(docRes.ok, docRes.problem.reason);

        immutable string wavPath = buildPath(root, "out.wav");
        RenderResult res = renderProjectWithReport(docRes.project, wavPath, 0.2);
        assert(res.ok, res.error);
        assert(exists(wavPath));
        assert(res.report.arrangementBars == 2);
        assert(res.report.bars.length == 2);
        assert(res.report.lengthSeconds > 3.5);
        assert(res.report.peak > 0.01f && res.report.rms > 0.0f);
        assert(!res.report.bars[0].silent && res.report.bars[0].peak > 0.01f);
        assert(res.report.bars[1].silent);
        assert(res.report.silentBars == [2u]);
        assert(res.report.modules.length == 3);
        assert(res.report.modules[0].producedSound);
        assert(res.report.modules[1].producedSound);
        assert(!res.report.modules[2].producedSound);

        immutable string txt = renderReportText(res.report);
        assert(txt.canFind("Silent bars: 2"));
        assert(txt.canFind("lead") && txt.canFind("idle"));
        JSONValue j = parseJSON(renderReportJson(res.report));
        assert(j["ok"].boolean);
        assert(j["arrangementBars"].integer == 2);
        assert(j["silentBars"].array.length == 1 && j["silentBars"][0].integer == 2);
        assert(j["modules"].array.length == 3);

        ProjectWriter hotProj = new ProjectWriter();
        auto hotSynth = ModuleWriter.fromType("synth.analog_gen");
        assert(hotSynth.ok);
        assert(hotProj.addModule("hot", hotSynth.writer).ok);
        assert(hotProj.connect("hot", "out", 4.0f).ok);
        PartWriter hotPw = new PartWriter(hotProj);
        assert(hotPw.addSection("loud", 1).ok);
        assert(hotPw.addPart("hot", "hot").ok);
        assert(hotPw.writeNote("hot", "loud", BeatPosition(1, 1, 1), Length(8), 60, 1.0f).ok);
        assert(hotPw.arrange(["loud"]).ok);
        auto hotDoc = hotPw.buildDocument();
        assert(hotDoc.ok);
        immutable string hotWav = buildPath(root, "hot.wav");
        RenderResult hotRes = renderProjectWithReport(hotDoc.project, hotWav, 0.1);
        assert(hotRes.ok, hotRes.error);
        assert(hotRes.report.limiterReached);
    }
}
