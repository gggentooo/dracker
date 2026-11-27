/**
 * File:         tests/unit/compose_song_checks_test.d
 * Module:       tests.unit.compose_song_checks_test
 * Phase:        Composition helper (dracker-compose) — T116, T117, T118, T119
 *
 * Purpose:
 *   Tests for the fixes found while writing docs/composer.md:
 *   - T116: `arrange clip=` and `arrange <sections>` combine in both orders: section clips keep their positions,
 *     raw clips keep their lanes, and a drum clip survives later pattern ids;
 *   - T117: warnings for scripts that run but make no sound (no arrangement, a section that is never arranged,
 *     a removed module, parts and drum parts without notes), printed by `check` and `run` with exit code 0;
 *   - T118: render plays the arrangement once (a loop that ends early is not followed), and the limiter
 *     counts as engaged above its knee, with the bars it worked in;
 *   - T119: the progression-too-long and missing-section messages, and `describe` printing a plain
 *     `arrange <sections>` when the parts were declared in another order than their patterns were written.
 *
 * Real-Time & Safety Contract:
 *   Off-RT unit tests; temporary files removed via scope(exit).
 *
 * Dependencies:
 *   Internal: compose.chord_writer, compose.render, compose.script.commands, compose.script.describe,
 *             compose.script.interpreter, compose_main, io.project_format, modules.output, sequencer.timeline
 *   External: std.algorithm (canFind), std.file (exists, mkdirRecurse, rmdirRecurse, tempDir, write),
 *             std.json (parseJSON), std.path (buildPath)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites for T116 to T119
 *
 * See_Also:
 *   docs/todo.md (T116, T117, T118, T119), docs/composer.md
 */
module tests.unit.compose_song_checks_test;

version (unittest) {
    import std.algorithm : canFind;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.json : parseJSON;
    import std.path : buildPath;

    import compose.render : renderProjectWithReport, renderReportJson, renderReportText, RenderResult;
    import compose.script.commands : createDefaultInterpreter;
    import compose.script.describe : describeProject, DescribeResult;
    import compose.script.interpreter : RunResult, ScriptInterpreter;
    import compose_main : ProgramIo, runProgram;
    import io.project_format : LoadedProject;
    import modules.output : LIMITER_KNEE;
    import sequencer.timeline : TimelineClip;

    enum string TWO_SECTIONS =
        "module lead synth.analog_gen\n"
        ~ "connect lead out gain=0.3\n"
        ~ "section a bars=1\n"
        ~ "section b bars=1\n"
        ~ "part mel module=lead\n"
        ~ "notes mel a: C4 E4 G4 C5\n"
        ~ "notes mel b: D4 F4 A4 D5\n"
        ~ "cells riff tracks=1 lines=16\n";

    /**
     * Runs a script in check mode and builds its document.
     *
     * Params:
     *   script = Script text; every line must succeed.
     *   run = Receives the run result.
     *
     * Returns:
     *   The built project.
     */
    private LoadedProject buildScript(string script, out RunResult run) {
        ScriptInterpreter interp = createDefaultInterpreter(true);
        run = interp.runScript(script);
        assert(run.ok, run.problems.length > 0 ? run.problems[0].text() : "run failed");
        auto doc = interp.buildDocument();
        assert(doc.ok, doc.problem.reason);
        return doc.project;
    }

    /**
     * Runs a script that must fail and returns its first problem's text, line and column.
     *
     * Params:
     *   script = Script text.
     *   column = Receives the problem's column.
     *   suggestion = Receives the problem's suggestion.
     *
     * Returns:
     *   The problem reason.
     */
    private string failureOf(string script, out uint column, out string suggestion) {
        ScriptInterpreter interp = createDefaultInterpreter(true);
        RunResult run = interp.runScript(script);
        assert(!run.ok && run.problems.length > 0);
        column = run.problems[0].column;
        suggestion = run.problems[0].suggestion;
        return run.problems[0].reason;
    }

    /**
     * Finds the clips of the pattern with the given name.
     *
     * Params:
     *   proj = Built project.
     *   name = Pattern name.
     *
     * Returns:
     *   The clips playing that pattern, in timeline order.
     */
    private TimelineClip[] clipsOf(const ref LoadedProject proj, string name) {
        uint patId = 0;
        foreach (ref sp; proj.patterns) {
            if (sp.name == name) {
                patId = sp.patternId;
            }
        }
        assert(patId != 0, "no pattern " ~ name);
        TimelineClip[] found;
        foreach (ref cl; proj.clips) {
            if (cl.patternId == patId) {
                found ~= cl;
            }
        }
        return found;
    }

    unittest {
        RunResult run;
        LoadedProject first = buildScript(TWO_SECTIONS ~ "arrange a b a\narrange clip=riff start=0 len=16 lane=5\n",
            run);
        auto aClips = clipsOf(first, "mel · a");
        auto bClips = clipsOf(first, "mel · b");
        auto riffClips = clipsOf(first, "riff");
        assert(aClips.length == 2 && aClips[0].startLine == 0 && aClips[1].startLine == 32);
        assert(aClips[1].cloneSourceId == aClips[0].clipId);
        assert(bClips.length == 1 && bClips[0].startLine == 16 && bClips[0].laneY == 0);
        assert(riffClips.length == 1 && riffClips[0].startLine == 0 && riffClips[0].laneY == 5);
        assert(first.clips.length == 4);
        assert(first.loopStartLine == 0 && first.loopEndLine == 48);

        LoadedProject second = buildScript(TWO_SECTIONS
            ~ "arrange clip=riff start=48 len=16 lane=5\narrange a b a\n", run);
        assert(clipsOf(second, "mel · a").length == 2 && clipsOf(second, "mel · b").length == 1);
        riffClips = clipsOf(second, "riff");
        assert(riffClips.length == 1 && riffClips[0].startLine == 48 && riffClips[0].laneY == 5);
        assert(second.clips.length == 4 && second.loopEndLine == 64);

        LoadedProject twice = buildScript(TWO_SECTIONS
            ~ "arrange clip=riff start=48 len=16 lane=5\narrange a b a\narrange b a\n", run);
        assert(clipsOf(twice, "riff").length == 1 && clipsOf(twice, "mel · b")[0].startLine == 0);
        assert(twice.loopEndLine == 64);

        LoadedProject sectionClip = buildScript(TWO_SECTIONS
            ~ "arrange a b\narrange clip=\"mel · a\" start=32 len=16 lane=0\n", run);
        aClips = clipsOf(sectionClip, "mel · a");
        assert(aClips.length == 2 && aClips[0].startLine == 0 && aClips[1].startLine == 32);
        assert(sectionClip.loopEndLine == 48);
    }

    unittest {
        enum string DRUMS =
            "module kit preset=\"Drum Kit\"\n"
            ~ "module lead synth.analog_gen\n"
            ~ "connect kit out gain=0.4\n"
            ~ "connect lead out gain=0.3\n"
            ~ "section a bars=1\n"
            ~ "section b bars=1\n"
            ~ "part drums drums=kit\n"
            ~ "drums drums a kick: x...x...x...x...\n"
            ~ "arrange a b\n"
            ~ "arrange clip=\"drums · a\" start=32 len=16 lane=3\n"
            ~ "part mel module=lead\n"
            ~ "notes mel a: C4\n"
            ~ "notes mel b: D4\n";
        RunResult run;
        LoadedProject proj = buildScript(DRUMS, run);
        auto drumClips = clipsOf(proj, "drums · a");
        assert(drumClips.length == 2);
        assert(drumClips[0].startLine == 0 && drumClips[1].startLine == 32 && drumClips[1].laneY == 3);
        assert(drumClips[1].cloneSourceId == drumClips[0].clipId);
        assert(clipsOf(proj, "mel · b").length == 1);
    }

    unittest {
        enum string SILENT =
            "module lead synth.analog_gen\n"
            ~ "module pad synth.analog_gen\n"
            ~ "connect lead out gain=0.3\n"
            ~ "connect pad out gain=0.3\n"
            ~ "section a bars=1\n"
            ~ "section \"b side\" bars=1\n"
            ~ "part mel module=lead\n"
            ~ "part p2 module=pad\n"
            ~ "part empty module=lead\n"
            ~ "notes mel a: C4 E4 G4 C5\n"
            ~ "notes p2 \"b side\" : C4\n"
            ~ "remove pad\n";
        RunResult run;
        cast(void) buildScript(SILENT, run);
        assert(run.warnings == [
            "no section is arranged, so the song is silent; add 'arrange a \"b side\"'",
            "part 'p2' plays module 'pad', which was removed, so its notes make no sound",
            "part 'empty' has no notes"
        ], run.warnings.length > 0 ? run.warnings[0] : "no warnings");

        cast(void) buildScript(SILENT ~ "arrange a\n", run);
        assert(run.warnings.length == 3);
        assert(run.warnings[0] == "section 'b side' has notes but is not arranged, so it is never heard");

        cast(void) buildScript(TWO_SECTIONS ~ "arrange a b\n", run);
        assert(run.warnings.length == 0, run.warnings.length > 0 ? run.warnings[0] : "");

        cast(void) buildScript("module lead synth.analog_gen\nconnect lead out gain=0.3\npart mel module=lead\n"
            ~ "notes mel: C4 E4\n", run);
        assert(run.warnings.length == 0);

        enum string KIT =
            "module kit preset=\"Drum Kit\"\n"
            ~ "module boom preset=\"Kick\"\n"
            ~ "connect kit out gain=0.4\n"
            ~ "connect boom out gain=0.5\n"
            ~ "section a bars=1\n"
            ~ "part drums drums=kit\n"
            ~ "part hats drums=kit\n"
            ~ "drums drums lane=Boom module=boom note=C2\n"
            ~ "drums drums a Boom: x...x...\n"
            ~ "arrange a\n"
            ~ "remove boom\n";
        cast(void) buildScript(KIT, run);
        assert(run.warnings == [
            "drum part 'drums' lane 'Boom' plays module 'boom', which was removed, so its hits make no sound",
            "drum part 'hats' has no hits"
        ], run.warnings.length > 0 ? run.warnings[0] : "no warnings");
    }

    unittest {
        immutable string root = buildPath(tempDir(), "dracker_t117_warnings_test");
        if (exists(root)) {
            rmdirRecurse(root);
        }
        mkdirRecurse(root);
        scope (exit) {
            if (exists(root)) {
                rmdirRecurse(root);
            }
        }
        immutable string silent = buildPath(root, "silent.dcs");
        write(silent, TWO_SECTIONS);
        immutable string clean = buildPath(root, "clean.dcs");
        write(clean, TWO_SECTIONS ~ "arrange a b\n");

        string outText = "";
        string errText = "";
        ProgramIo io;
        io.writeOutput = (string text) @safe {
            outText ~= text;
        };
        io.writeError = (string text) @safe {
            errText ~= text;
        };

        assert(runProgram(["check", silent], io) == 0 && errText == "");
        assert(outText == "OK (8 commands checked).\n"
            ~ "Warning: no section is arranged, so the song is silent; add 'arrange a b'.\n", outText);
        outText = "";
        assert(runProgram(["--json", "run", silent], io) == 0 && errText == "");
        auto j = parseJSON(outText);
        assert(j["ok"].boolean && j["warnings"].array.length == 1);
        assert(j["warnings"][0].str == "no section is arranged, so the song is silent; add 'arrange a b'");
        outText = "";
        assert(runProgram(["--json", "check", clean], io) == 0);
        assert(parseJSON(outText)["warnings"].array.length == 0);
        outText = "";
        assert(runProgram(["run", clean], io) == 0 && !outText.canFind("Warning"));

        immutable string unplacedMsv = buildPath(root, "unplaced.msv");
        outText = "";
        assert(runProgram(["run", silent, "-o", unplacedMsv], io) == 0 && exists(unplacedMsv));
        immutable string reopen = buildPath(root, "reopen.dcs");
        write(reopen, "open \"" ~ unplacedMsv ~ "\"\ntempo 100\n");
        outText = "";
        assert(runProgram(["check", reopen], io) == 0);
        assert(outText == "OK (2 commands checked).\n", outText);
        write(reopen, "open \"" ~ unplacedMsv ~ "\"\nremove lead\n");
        outText = "";
        assert(runProgram(["check", reopen], io) == 0);
        assert(outText.canFind("Warning: part 'mel' plays module 'lead', which was removed"), outText);
    }

    unittest {
        immutable string root = buildPath(tempDir(), "dracker_t118_render_test");
        if (exists(root)) {
            rmdirRecurse(root);
        }
        mkdirRecurse(root);
        scope (exit) {
            if (exists(root)) {
                rmdirRecurse(root);
            }
        }

        RunResult run;
        LoadedProject looped = buildScript(
            "module lead synth.analog_gen\n"
            ~ "connect lead out gain=0.3\n"
            ~ "section quiet bars=1\n"
            ~ "section tune bars=1\n"
            ~ "part mel module=lead\n"
            ~ "notes mel tune: C4 E4 G4 C5\n"
            ~ "arrange quiet tune\n"
            ~ "loop quiet\n", run);
        assert(looped.loopStartLine == 0 && looped.loopEndLine == 16);
        RenderResult res = renderProjectWithReport(looped, buildPath(root, "looped.wav"), 0.1);
        assert(res.ok, res.error);
        assert(res.report.arrangementBars == 2);
        assert(!res.report.bars[1].silent && res.report.bars[1].peak > 0.05f);
        assert(res.report.loopIgnored);
        immutable string txt = renderReportText(res.report);
        assert(txt.canFind("the arrangement once from start to end"));
        assert(txt.canFind("Loop:     lines 0 to 16, not followed by the render"));
        assert(txt.canFind("limiter not engaged"));
        auto j = parseJSON(renderReportJson(res.report));
        assert(j["playback"].str == "once" && !j["loop"]["followed"].boolean);
        assert(j["loop"]["end"].integer == 16 && !j["limiterReached"].boolean);

        LoadedProject whole = buildScript(
            "module lead synth.analog_gen\nconnect lead out gain=0.3\nsection a bars=1\npart mel module=lead\n"
            ~ "notes mel a: C4\narrange a\n", run);
        res = renderProjectWithReport(whole, buildPath(root, "whole.wav"), 0.1);
        assert(res.ok && !res.report.loopIgnored && !renderReportText(res.report).canFind("Loop:"));

        LoadedProject hot = buildScript(
            "module lead preset=\"Saw Lead\"\n"
            ~ "module bass preset=\"Synth Bass\"\n"
            ~ "connect lead out gain=1\n"
            ~ "connect bass out gain=1\n"
            ~ "section a bars=2\n"
            ~ "part l module=lead\n"
            ~ "part b module=bass\n"
            ~ "chords l a voices=4: Am F\n"
            ~ "notes b a: A1:1 F1:1\n"
            ~ "arrange a\n", run);
        res = renderProjectWithReport(hot, buildPath(root, "hot.wav"), 0.0);
        assert(res.ok, res.error);
        assert(res.report.peak > LIMITER_KNEE && res.report.peak < 0.999f);
        assert(res.report.limiterReached);
        assert(res.report.limiterBars == [1u, 2u]);
        assert(res.report.bars[0].limited && res.report.bars[1].limited);
        assert(renderReportText(res.report).canFind("limiter engaged in 2 bars (1, 2)"));
        assert(renderReportText(res.report).canFind("  bar 1: peak"));
        j = parseJSON(renderReportJson(res.report));
        assert(j["limiterReached"].boolean && j["limiterBars"].array.length == 2);
        assert(j["bars"][0]["limited"].boolean && j["bars"][1]["limited"].boolean);
    }

    unittest {
        uint column;
        string suggestion;
        immutable string base =
            "module lead synth.analog_gen\n"
            ~ "section a bars=2\n"
            ~ "section b bars=1\n"
            ~ "part keys module=lead\n";

        string reason = failureOf(base ~ "chords keys a: Am F C G\n", column, suggestion);
        assert(reason == "the progression needs 4 bars, but section 'a' has 2 bars; lengthen the section "
            ~ "(section a bars=4) or shorten the progression", reason);
        assert(column == 16 && suggestion == "");

        reason = failureOf(base ~ "chords keys a at=1.3: Am F\n", column, suggestion);
        assert(reason.canFind("needs 3 bars from 1.3, but section 'a' has 2 bars"), reason);

        reason = failureOf(base ~ "notes keys: C4\n", column, suggestion);
        assert(reason == "a section is needed here, because the song has sections (a, b); write the section "
            ~ "after the part name", reason);
        assert(column == 7 && suggestion == "");

        reason = failureOf(base ~ "chords keys: Am\n", column, suggestion);
        assert(reason.canFind("a section is needed here") && column == 8 && suggestion == "");

        reason = failureOf(base ~ "notes keys c: C4\n", column, suggestion);
        assert(reason == "there is no section 'c'", reason);
    }

    unittest {
        enum string ORDER =
            "module lead synth.analog_gen\n"
            ~ "module pad synth.analog_gen\n"
            ~ "connect lead out gain=0.3\n"
            ~ "connect pad out gain=0.3\n"
            ~ "section a bars=1\n"
            ~ "section b bars=1\n"
            ~ "part zz module=pad\n"
            ~ "part aa module=lead\n"
            ~ "notes aa a: C4 E4 G4 C5\n"
            ~ "notes zz a: C3\n"
            ~ "notes zz b: D3\n"
            ~ "notes aa b: D4\n"
            ~ "arrange a b a\n";
        RunResult run;
        LoadedProject proj = buildScript(ORDER, run);
        DescribeResult desc = describeProject(proj);
        assert(desc.ok, desc.error);
        assert(desc.script.canFind("\narrange a b a\n"), desc.script);
        assert(!desc.script.canFind("arrange clip="));
        assert(desc.script.canFind("part zz module=pad\npart aa module=lead\n"));

        LoadedProject again = buildScript(desc.script, run);
        assert(again.clips == proj.clips);
    }
}
