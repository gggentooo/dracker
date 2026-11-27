/**
 * File:         tests/unit/compose_script_test.d
 * Module:       tests.unit.compose_script_test
 * Phase:        Composition helper (dracker-compose) — T83 (Script lexer, interpreter & core commands tests)
 *
 * Purpose:
 *   Unit tests for compose.script.lexer, compose.script.interpreter, and compose.script.commands:
 *   verifies every lexical rule (words, double-quoted strings, escapes, double-slash comments outside
 *   quotes, '#' preserved for sharps, backslash line continuations, CRLF handling, name=value and
 *   name="value" options, 1-based line/column tracking, lex errors), interpreter dispatch (command table,
 *   typed args, option validation, nearest-name suggestions, line-by-line execution), and all five T83
 *   commands (project, tempo with optional tpl=, signature, key, save in write and checkOnly modes)
 *   plus round-trip loading in StudioSession.
 *
 * Real-Time & Safety Contract:
 *   Off-RT unit tests; temporary .msv files cleaned via scope(exit).
 *
 * Dependencies:
 *   Internal: app.music_theory (KeyMode, MusicalKey), app.session (StudioSession), compose.script.commands,
 *             compose.script.interpreter, compose.script.lexer, compose.timing (TimeSignature)
 *   External: std.algorithm (canFind), std.file (exists, mkdirRecurse, rmdirRecurse, tempDir),
 *             std.path (buildPath)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites covering all T83 requirements
 *
 * See_Also:
 *   docs/todo.md (T67, T83), source/compose/script/{lexer,interpreter,commands}.d
 */
module tests.unit.compose_script_test;

version (unittest) {
    import std.algorithm : canFind;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.math : fabs;
    import std.path : buildPath;

    import app.music_theory : KeyMode, MusicalKey;
    import app.pattern_notes : PatternGrid;
    import app.session : StudioSession;
    import compose.part_writer : PartNote;
    import compose.script.commands : createDefaultInterpreter, registerCoreCommands;
    import compose.script.interpreter : ArgKind, CommandSpec, RunResult, ScriptInterpreter, ScriptProblem,
        StepResult;
    import compose.script.lexer : CommandLine, LexErrorKind, LexResult, lexLine, lexScript, TokenKind;
    import compose.timing : TimeSignature;
    import foundation.types : FIXED_BLOCK_FRAMES;
    import sequencer.note : NoteCell, NoteCmd;

    unittest {
        immutable string commentPrefix = "/" ~ "/";
        immutable string script =
            commentPrefix ~ " Header comment\r\n"
            ~ "\r\n"
            ~ "project \"Night " ~ commentPrefix ~ " Drive\"  " ~ commentPrefix ~ " inline comment\n"
            ~ "tempo 96 \\\n"
            ~ "  tpl=4\n"
            ~ "key F# minor\n"
            ~ "module bass preset=\"Electric \\\"Sub\\\" Bass\" gain=0.35\n";

        immutable LexResult lex = lexScript(script);
        assert(lex.ok);
        assert(lex.commands.length == 4);

        assert(lex.commands[0].line == 3);
        assert(lex.commands[0].tokens.length == 2);
        assert(lex.commands[0].tokens[0].kind == TokenKind.word);
        assert(lex.commands[0].tokens[0].text == "project");
        assert(lex.commands[0].tokens[0].line == 3 && lex.commands[0].tokens[0].column == 1);
        assert(lex.commands[0].tokens[1].kind == TokenKind.quoted);
        assert(lex.commands[0].tokens[1].text == "Night " ~ commentPrefix ~ " Drive");
        assert(lex.commands[0].tokens[1].line == 3 && lex.commands[0].tokens[1].column == 9);

        assert(lex.commands[1].line == 4);
        assert(lex.commands[1].tokens.length == 3);
        assert(lex.commands[1].tokens[0].text == "tempo" && lex.commands[1].tokens[0].line == 4);
        assert(lex.commands[1].tokens[1].text == "96" && lex.commands[1].tokens[1].line == 4);
        assert(lex.commands[1].tokens[2].kind == TokenKind.option);
        assert(lex.commands[1].tokens[2].optionName == "tpl");
        assert(lex.commands[1].tokens[2].optionValue == "4");
        assert(!lex.commands[1].tokens[2].valueQuoted);
        assert(lex.commands[1].tokens[2].line == 5 && lex.commands[1].tokens[2].column == 3);

        assert(lex.commands[2].line == 6);
        assert(lex.commands[2].tokens.length == 3);
        assert(lex.commands[2].tokens[1].text == "F#");
        assert(lex.commands[2].tokens[2].text == "minor");

        assert(lex.commands[3].line == 7);
        assert(lex.commands[3].tokens.length == 4);
        assert(lex.commands[3].tokens[2].kind == TokenKind.option);
        assert(lex.commands[3].tokens[2].optionName == "preset");
        assert(lex.commands[3].tokens[2].optionValue == "Electric \"Sub\" Bass");
        assert(lex.commands[3].tokens[2].valueQuoted);
        assert(lex.commands[3].tokens[3].optionName == "gain");
        assert(lex.commands[3].tokens[3].optionValue == "0.35");
    }

    unittest {
        immutable LexResult unterm = lexLine("project \"unterminated", 2);
        assert(!unterm.ok && unterm.errors[0].kind == LexErrorKind.unterminatedString);
        assert(unterm.errors[0].line == 2 && unterm.errors[0].column == 9);

        immutable LexResult badEsc = lexLine("project \"bad\\q\"", 4);
        assert(!badEsc.ok && badEsc.errors[0].kind == LexErrorKind.invalidEscape);
        assert(badEsc.errors[0].line == 4 && badEsc.errors[0].column == 13);

        immutable LexResult badOpt = lexLine("tempo 120 =4", 5);
        assert(!badOpt.ok && badOpt.errors[0].kind == LexErrorKind.malformedOption);
        assert(badOpt.errors[0].column == 11);

        immutable LexResult missingVal = lexLine("tempo 120 tpl=", 6);
        assert(!missingVal.ok && missingVal.errors[0].kind == LexErrorKind.missingOptionValue);
        assert(missingVal.errors[0].column == 14);

        immutable LexResult trailing = lexLine("project \"abc\"def", 7);
        assert(!trailing.ok && trailing.errors[0].kind == LexErrorKind.unexpectedAfterQuote);
        assert(trailing.errors[0].column == 14);
    }

    unittest {
        ScriptInterpreter interp = createDefaultInterpreter(true);
        const(CommandSpec)[] table = interp.commandTable();
        assert(table.length == 27);
        foreach (cmdName; ["project", "title", "open", "tempo", "signature", "key", "module", "set", "preset",
                "sample", "savemodule", "connect", "disconnect", "remove", "section", "part", "notes",
                "chords", "drums", "cells", "copy", "repeat", "transpose", "clear", "arrange", "loop",
                "save"]) {
            assert(interp.hasCommand(cmdName));
        }

        immutable string commentPrefix = "/" ~ "/";
        immutable string script =
            commentPrefix ~ " Full T83 check-only script\n"
            ~ "project \"Night Drive\"\n"
            ~ "tempo 96 tpl=4\n"
            ~ "signature 6/8\n"
            ~ "key A minor\n"
            ~ "save \"ignored_in_check_only.msv\"\n";

        RunResult res = interp.runScript(script);
        assert(res.ok, res.problems.length > 0 ? res.problems[0].text() : "");
        assert(res.commandsRun == 5);
        assert(interp.project().title() == "Night Drive");
        assert(interp.project().tempo() == 96.0);
        assert(interp.project().ticksPerLine() == 4);
        assert(interp.project().timeSignature() == TimeSignature(6, 8));
        assert(interp.project().key() == MusicalKey(9, KeyMode.minor));
        assert(interp.savedPaths() == ["ignored_in_check_only.msv"]);
        assert(!exists("ignored_in_check_only.msv"));
    }

    unittest {
        ScriptInterpreter interp = createDefaultInterpreter(true);

        immutable StepResult unkCmd = interp.runLine("temop 120", 3);
        assert(!unkCmd.ok);
        assert(unkCmd.problem.line == 3 && unkCmd.problem.column == 1);
        assert(unkCmd.problem.suggestion == "tempo");
        assert(unkCmd.problem.text().canFind("did you mean 'tempo'?"));

        immutable StepResult unkOpt = interp.runLine("tempo 120 tp=4", 4);
        assert(!unkOpt.ok);
        assert(unkOpt.problem.line == 4 && unkOpt.problem.column == 11);
        assert(unkOpt.problem.suggestion == "tpl");
        assert(unkOpt.problem.text().canFind("did you mean 'tpl'?"));

        immutable StepResult dupOpt = interp.runLine("tempo 120 tpl=4 tpl=6", 5);
        assert(!dupOpt.ok && dupOpt.problem.line == 5 && dupOpt.problem.column == 17);

        immutable StepResult missingArg = interp.runLine("tempo", 6);
        assert(!missingArg.ok && missingArg.problem.line == 6);

        immutable StepResult extraArg = interp.runLine("signature 4/4 extra", 7);
        assert(!extraArg.ok && extraArg.problem.line == 7 && extraArg.problem.column == 15);

        immutable StepResult badBpm = interp.runLine("tempo fast", 8);
        assert(!badBpm.ok && badBpm.problem.line == 8 && badBpm.problem.column == 7);
        assert(badBpm.problem.suggestion == "125");

        immutable StepResult atomicCheck = interp.runLine("tempo 110 tpl=999", 9);
        assert(!atomicCheck.ok && atomicCheck.problem.line == 9 && atomicCheck.problem.column == 11);
        assert(interp.project().tempo() == 125.0);
        assert(interp.project().ticksPerLine() == 6);

        immutable StepResult badSig = interp.runLine("signature 5/7", 10);
        assert(!badSig.ok && badSig.problem.line == 10 && badSig.problem.column == 11);
        assert(badSig.problem.suggestion == "4");

        immutable StepResult badKeyTonic = interp.runLine("key H minor", 11);
        assert(!badKeyTonic.ok && badKeyTonic.problem.line == 11 && badKeyTonic.problem.column == 5);
        assert(badKeyTonic.problem.suggestion == "C major");

        immutable StepResult badKeyMode = interp.runLine("key D minro", 12);
        assert(!badKeyMode.ok && badKeyMode.problem.line == 12 && badKeyMode.problem.column == 7);
        assert(badKeyMode.problem.suggestion == "D minor");

        assert(interp.runLine("key \"F# minor\"", 13).ok);
        assert(interp.project().key() == MusicalKey(6, KeyMode.minor));

        assert(interp.runLine("key Bb", 14).ok);
        assert(interp.project().key() == MusicalKey(10, KeyMode.major));

        immutable StepResult emptySave = interp.runLine("save \"   \"", 15);
        assert(!emptySave.ok && emptySave.problem.line == 15);

        immutable StepResult quotedCmd = interp.runLine("\"project\" foo", 16);
        assert(!quotedCmd.ok && quotedCmd.problem.line == 16 && quotedCmd.problem.column == 1);
    }

    unittest {
        immutable string root = buildPath(tempDir(), "dracker_t83_script_test");
        immutable string path = buildPath(root, "script_out.msv");
        if (exists(root)) {
            rmdirRecurse(root);
        }
        mkdirRecurse(root);
        scope (exit) {
            if (exists(root)) {
                rmdirRecurse(root);
            }
        }

        ScriptInterpreter interp = createDefaultInterpreter(false);
        assert(interp.runLine("project \"Scripted Song\"", 1).ok);
        assert(interp.runLine("tempo 108 tpl=8", 2).ok);
        assert(interp.runLine("signature 3/4", 3).ok);
        assert(interp.runLine("key C# minor", 4).ok);
        immutable StepResult saved = interp.runLine("save \"" ~ path ~ "\"", 5);
        assert(saved.ok, saved.problem.text());
        assert(exists(path));

        StudioSession session = new StudioSession();
        assert(session.initialize(44_100.0f));
        scope (exit) {
            session.shutdown();
        }
        string openErr;
        assert(session.openProjectFile(path, openErr), openErr);
        assert(session.document().title == "Scripted Song");
        assert(session.document().bpm == 108.0);
        assert(session.document().ticksPerLine == 8);
        assert(session.document().timeSigNumerator == 3 && session.document().timeSigDenominator == 4);
        assert(session.document().keyTonic == 1 && session.document().keyMode == 1);
    }

    unittest {
        import compose.module_writer : ModuleWriter;
        import io.audio_io : writeWavFile;
        import io.project_format : loadPresetFile, LoadedPreset;

        immutable string root = buildPath(tempDir(), "dracker_t101_commands_test");
        if (exists(root)) {
            rmdirRecurse(root);
        }
        mkdirRecurse(root);
        scope (exit) {
            if (exists(root)) {
                rmdirRecurse(root);
            }
        }

        immutable string modPath = buildPath(root, "custom_bass.msym");
        immutable string wavPath = buildPath(root, "kick.wav");
        immutable string projPath = buildPath(root, "band.msv");

        float[256] wavL = 0.0f;
        float[256] wavR = 0.0f;
        foreach (i; 0 .. 256) {
            wavL[i] = 0.25f;
            wavR[i] = 0.25f;
        }
        string wavErr;
        const(float)[][2] wavChans = [wavL[], wavR[]];
        assert(writeWavFile(wavPath, wavChans[], 44_100, wavErr), wavErr);

        ScriptInterpreter interp = createDefaultInterpreter(false);
        assert(interp.runLine("project \"T101 Rig\"", 1).ok);
        assert(interp.runLine("module bass synth.analog_gen x=40 y=80", 2).ok);
        assert(interp.runLine("module keys preset=\"Electric Piano\"", 3).ok);
        assert(interp.runLine("module comp fx.compressor", 4).ok);
        assert(interp.runLine("module samp synth.sampler", 5).ok);
        assert(interp.runLine("set bass Waveform=Saw Cutoff=1800", 6).ok);
        assert(interp.runLine("set keys Release 250", 7).ok);
        assert(interp.runLine("sample samp \"" ~ wavPath ~ "\" slot=0 root=C3 low=24 high=96", 8).ok);
        assert(interp.runLine("savemodule bass \"" ~ modPath ~ "\"", 9).ok);
        assert(exists(modPath));
        assert(interp.runLine("module clone file=\"" ~ modPath ~ "\"", 10).ok);
        assert(interp.runLine("preset keys \"Saw Lead\"", 11).ok == false);
        assert(interp.runLine("preset clone \"Synth Bass\"", 12).ok);
        assert(interp.runLine("connect bass comp gain=0.6", 13).ok);
        assert(interp.runLine("connect clone comp gain=0.4 to=Sidechain", 14).ok);
        assert(interp.runLine("connect comp out gain=0.8", 15).ok);
        assert(interp.project().wireCount() == 3);
        assert(interp.runLine("disconnect clone comp to=scIn", 16).ok);
        assert(interp.project().wireCount() == 2);
        assert(interp.runLine("remove clone", 17).ok);
        assert(!interp.project().hasModule("clone"));
        assert(interp.runLine("save \"" ~ projPath ~ "\"", 18).ok);

        LoadedPreset loadedMod;
        string pErr;
        assert(loadPresetFile(modPath, loadedMod, pErr), pErr);
        assert(loadedMod.mod.typeId == "synth.analog_gen");

        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string openErr;
        assert(s.openProjectFile(projPath, openErr), openErr);
        assert(s.document().modules.length == 5);
        assert(s.document().wires.length == 2);

        immutable StepResult badType = interp.runLine("module x analog_ge", 20);
        assert(!badType.ok && badType.problem.line == 20 && badType.problem.column == 10);
        assert(badType.problem.suggestion.length > 0);

        immutable StepResult badParam = interp.runLine("set bass Cutof=500", 21);
        assert(!badParam.ok && badParam.problem.line == 21 && badParam.problem.column == 10);
        assert(badParam.problem.suggestion == "Cutoff");

        immutable StepResult badPort = interp.runLine("connect bass comp to=Sidechan", 22);
        assert(!badPort.ok && badPort.problem.line == 22 && badPort.problem.column == 19);
        assert(badPort.problem.suggestion == "Sidechain");

        immutable StepResult badGain = interp.runLine("connect bass out gain=-1", 23);
        assert(!badGain.ok && badGain.problem.line == 23 && badGain.problem.column == 18);

        ScriptInterpreter chk = createDefaultInterpreter(true);
        assert(chk.runLine("module b synth.analog_gen", 1).ok);
        immutable string uncreated = buildPath(root, "never_written.msym");
        assert(chk.runLine("savemodule b \"" ~ uncreated ~ "\"", 2).ok);
        assert(!exists(uncreated));
    }

    unittest {
        import compose.part_writer : PartNote;
        import compose.script.commands : createInterpreterFromDocument, ScriptOpenResult;
        import io.project_format : LoadedProject;

        immutable string root = buildPath(tempDir(), "dracker_t103_open_script_test");
        if (exists(root)) {
            rmdirRecurse(root);
        }
        mkdirRecurse(root);
        scope (exit) {
            if (exists(root)) {
                rmdirRecurse(root);
            }
        }
        immutable string savedPath = buildPath(root, "opened_edit.msv");

        ScriptInterpreter first = createDefaultInterpreter(false);
        immutable StepResult openOk = first.runLine("open \"sample-projects/midnight_pulse.msv\"", 1);
        assert(openOk.ok, openOk.problem.text());
        assert(first.startedFromDocument());
        assert(first.openedModules().length >= 2);
        string nonOutHandle;
        foreach (ref h; first.openedModules()) {
            if (h.handle != "out") {
                nonOutHandle = h.handle;
                break;
            }
        }
        assert(nonOutHandle.length > 0);
        assert(first.runLine("set out Volume=0.75", 2).ok);
        assert(first.runLine("part extraPart module=" ~ nonOutHandle, 3).ok);
        assert(first.runLine("section overlay bars=1", 4).ok);
        assert(first.runLine("notes extraPart overlay: C4:2 E4:2", 5).ok);
        assert(first.runLine("save \"" ~ savedPath ~ "\"", 6).ok);
        assert(exists(savedPath));

        StudioSession verifySess = new StudioSession();
        assert(verifySess.initialize(44_100.0f));
        scope (exit) verifySess.shutdown();
        string openErr;
        assert(verifySess.openProjectFile(savedPath, openErr), openErr);
        assert(verifySess.document().modules[0].paramValues[0] > 0.74f
            && verifySess.document().modules[0].paramValues[0] < 0.76f);

        ScriptInterpreter badOrder = createDefaultInterpreter(true);
        assert(badOrder.runLine("tempo 120", 1).ok);
        immutable StepResult lateOpen = badOrder.runLine("open \"sample-projects/midnight_pulse.msv\"", 2);
        assert(!lateOpen.ok && lateOpen.problem.line == 2);

        ScriptInterpreter doubleOpen = createDefaultInterpreter(true);
        assert(doubleOpen.runLine("open \"sample-projects/midnight_pulse.msv\"", 1).ok);
        immutable StepResult secondOpen = doubleOpen.runLine("open \"sample-projects/lobby_waltz.msv\"", 2);
        assert(!secondOpen.ok && secondOpen.problem.line == 2);

        ScriptInterpreter missingFile = createDefaultInterpreter(true);
        immutable StepResult badFile = missingFile.runLine("open \"" ~ buildPath(root, "no_such.msv") ~ "\"", 1);
        assert(!badFile.ok && badFile.problem.line == 1);

        ScriptOpenResult memRes = createInterpreterFromDocument(*verifySess.document(), true);
        assert(memRes.ok, memRes.problem.text());
        assert(memRes.interpreter.startedFromDocument());
        assert(memRes.interpreter.runLine("module pad synth.fm_synth", 1).ok);
        assert(memRes.interpreter.runLine("connect pad out gain=0.25", 2).ok);
        assert(memRes.interpreter.runLine("part pad module=pad", 3).ok);
        assert(memRes.interpreter.runLine("section bridge bars=1", 4).ok);
        assert(memRes.interpreter.runLine("notes pad bridge: C4:2 E4:2", 5).ok);
        PartNote[] pn = memRes.interpreter.parts().notesOfPart("pad", "bridge");
        assert(pn.length == 2 && pn[0].pitch == 60 && pn[1].pitch == 64);
        immutable StepResult openInMem = memRes.interpreter.runLine("open \"sample-projects/lobby_waltz.msv\"", 6);
        assert(!openInMem.ok && openInMem.problem.line == 6);
    }

    unittest {
        import compose.render : RenderResult, renderProjectWithReport;
        import io.project_format : LoadedProject, loadProjectFile;

        immutable string root = buildPath(tempDir(), "dracker_t104_music_script_test");
        if (exists(root)) {
            rmdirRecurse(root);
        }
        mkdirRecurse(root);
        scope (exit) {
            if (exists(root)) {
                rmdirRecurse(root);
            }
        }
        immutable string songPath = buildPath(root, "two_sections.msv");
        immutable string wavPath = buildPath(root, "two_sections.wav");

        immutable string script =
            "project \"Two Sections\"\n"
            ~ "tempo 140\n"
            ~ "signature 4/4\n"
            ~ "key C major\n"
            ~ "module bass synth.analog_gen\n"
            ~ "module keys synth.fm_synth\n"
            ~ "connect bass out gain=0.4\n"
            ~ "connect keys out gain=0.4\n"
            ~ "section verse bars=1\n"
            ~ "section chorus bars=1\n"
            ~ "part bass module=bass\n"
            ~ "part keys module=keys\n"
            ~ "notes bass verse: C2:2 G2:2\n"
            ~ "notes keys verse at=1.2: [C4 E4 G4]:1\n"
            ~ "notes bass chorus: F2:2 G2:2\n"
            ~ "notes keys chorus: [F4 A4 C5]:2 [G4 B4 D5]:2\n"
            ~ "arrange verse chorus verse\n"
            ~ "loop verse chorus\n"
            ~ "save \"" ~ songPath ~ "\"\n";

        ScriptInterpreter interp = createDefaultInterpreter(false);
        RunResult res = interp.runScript(script);
        assert(res.ok, res.problems.length > 0 ? res.problems[0].text() : "");
        assert(res.commandsRun == 19);
        assert(exists(songPath));
        assert(interp.parts().arrangement() == ["verse", "chorus", "verse"]);
        assert(interp.parts().loopStartLine() == 0 && interp.parts().loopEndLine() == 32);

        LoadedProject loaded;
        string lErr;
        assert(loadProjectFile(songPath, loaded, lErr), lErr);
        assert(loaded.patterns.length == 4);
        assert(loaded.clips.length == 6);
        assert(loaded.loopStartLine == 0 && loaded.loopEndLine == 32);

        RenderResult rr = renderProjectWithReport(loaded, wavPath);
        assert(rr.ok, rr.error);
        assert(rr.report.arrangementBars == 3);
        assert(rr.report.peak > 0.01f);

        ScriptInterpreter imp = createDefaultInterpreter(true);
        assert(imp.runScript(
            "module lead synth.analog_gen\n"
            ~ "part lead module=lead\n"
            ~ "notes lead: C4 D4 E4 F4 G4:2\n").ok);
        assert(imp.parts().notesOfPart("lead", "").length == 5);
        assert(imp.parts().arrangementLengthLines() == 32);

        ScriptInterpreter errInterp = createDefaultInterpreter(true);
        assert(errInterp.runScript(
            "module keys synth.fm_synth\n"
            ~ "section verse bars=1\n"
            ~ "part keys module=keys\n").ok);

        immutable StepResult badNote = errInterp.runLine("notes keys verse: C4 H4 G4", 4);
        assert(!badNote.ok);
        assert(badNote.problem.line == 4 && badNote.problem.column == 22 && badNote.problem.length == 1);

        ScriptInterpreter contErr = createDefaultInterpreter(true);
        RunResult contRes = contErr.runScript(
            "module keys synth.fm_synth\n"
            ~ "section verse bars=1\n"
            ~ "part keys module=keys\n"
            ~ "notes keys verse: C4 \\\n"
            ~ "  D4 H4\n");
        assert(!contRes.ok && contRes.problems.length == 1);
        assert(contRes.problems[0].line == 5 && contRes.problems[0].column == 6
            && contRes.problems[0].length == 1);

        immutable StepResult badSec = errInterp.runLine("notes keys vers: C4", 5);
        assert(!badSec.ok && badSec.problem.line == 5 && badSec.problem.column == 12);
        assert(badSec.problem.suggestion == "verse");

        immutable StepResult badArr = errInterp.runLine("arrange verse verze", 6);
        assert(!badArr.ok && badArr.problem.line == 6 && badArr.problem.column == 15);
        assert(badArr.problem.suggestion == "verse");

        immutable StepResult badBars = errInterp.runLine("section bridge bars=0", 7);
        assert(!badBars.ok && badBars.problem.line == 7 && badBars.problem.column == 16);

        immutable StepResult badPartMod = errInterp.runLine("part bass module=keyz", 8);
        assert(!badPartMod.ok && badPartMod.problem.line == 8 && badPartMod.problem.column == 11);
        assert(badPartMod.problem.suggestion == "keys");

        immutable StepResult noLoopArg = errInterp.runLine("loop", 9);
        assert(!noLoopArg.ok && noLoopArg.problem.line == 9);
    }

    unittest {
        ScriptInterpreter interp = createDefaultInterpreter(false);
        immutable string script =
            "project \"Edit Ops\"\n"
            ~ "tempo 120\n"
            ~ "signature 4/4\n"
            ~ "key C major\n"
            ~ "module synth synth.fm_synth\n"
            ~ "connect synth out gain=0.4\n"
            ~ "section a bars=2\n"
            ~ "section b bars=2\n"
            ~ "part lead module=synth\n"
            ~ "part dup module=synth\n"
            ~ "notes lead a: C4:1 E4:1 G4:1 B4:1\n"
            ~ "repeat lead a from=1 len=4 times=1\n";
        ScriptInterpreter repInterp = createDefaultInterpreter(false);
        assert(repInterp.runScript(script).ok);
        PartNote[] leadA = repInterp.parts().notesOfPart("lead", "a");
        assert(leadA.length == 8);
        assert(leadA[0].line == 0 && leadA[0].pitch == 60);
        assert(leadA[7].line == 28 && leadA[7].pitch == 71);

        assert(interp.runScript(
            "project \"T106 Ops\"\n"
            ~ "key C major\n"
            ~ "module synth synth.fm_synth\n"
            ~ "connect synth out gain=0.4\n"
            ~ "section a bars=2\n"
            ~ "section b bars=2\n"
            ~ "part lead module=synth\n"
            ~ "part copyPart module=synth\n"
            ~ "notes lead a: C4:1 E4:1\n"
            ~ "repeat lead a from=1 len=2 times=1\n"
            ~ "copy lead a from=1 len=4 to=1 part=copyPart section=b\n"
            ~ "transpose copyPart b from=1 len=2 by=12\n"
            ~ "transpose lead a from=1.3 len=2 steps=1\n"
            ~ "clear copyPart b from=1.3 len=2\n"
            ~ "cells lead a track=0 line=15 note=off fx=03 fxval=0x10\n"
            ~ "cells rawpat tracks=2 lines=8\n"
            ~ "cells rawpat track=1 line=2 note=F#3 velbyte=200 module=synth fx=slideUp fxval=0x12\n"
        ).ok);

        PartNote[] srcNotes = interp.parts().notesOfPart("lead", "a");
        assert(srcNotes.length == 4);
        assert(srcNotes[0].pitch == 60 && srcNotes[1].pitch == 64);
        assert(srcNotes[2].line == 8 && srcNotes[2].pitch == 62);
        assert(srcNotes[3].line == 12 && srcNotes[3].pitch == 65);

        PartNote[] dstNotes = interp.parts().notesOfPart("copyPart", "b");
        assert(dstNotes.length == 2);
        assert(dstNotes[0].line == 0 && dstNotes[0].pitch == 72);
        assert(dstNotes[1].line == 4 && dstNotes[1].pitch == 76);

        auto leadPat = interp.parts().patternFor("lead", "a");
        assert(leadPat.ok);
        PatternGrid leadGrid;
        assert(interp.parts().patternGrid(leadPat.pattern.patternId, leadGrid));
        immutable NoteCell offCell = leadGrid.at(0, 15);
        assert(offCell.note == NoteCmd.noteOff && offCell.effect == 0x03 && offCell.effectVal == 0x10);

        auto rawPat = interp.parts().patternByName("rawpat");
        assert(rawPat.ok && rawPat.pattern.patternId != 0);
        PatternGrid rawGrid;
        assert(interp.parts().patternGrid(rawPat.pattern.patternId, rawGrid));
        assert(rawGrid.tracks == 2 && rawGrid.lines == 8);
        immutable NoteCell rawCell = rawGrid.at(1, 2);
        assert(rawCell.note == 54 + 1 && rawCell.velocity == 200);
        assert(rawCell.effect == 0x01 && rawCell.effectVal == 0x12);

        immutable StepResult badRaw = interp.runLine("cells broken tracks=4", 1);
        assert(!badRaw.ok && badRaw.problem.line == 1);
        immutable StepResult badTrans = interp.runLine("transpose lead a by=1 steps=1", 2);
        assert(!badTrans.ok && badTrans.problem.line == 2);
    }

    unittest {
        ScriptInterpreter interp = createDefaultInterpreter(false);
        RunResult r = interp.runScript(
            "project \"Chords & Drums\"\n"
            ~ "tempo 120\n"
            ~ "signature 4/4\n"
            ~ "key C major\n"
            ~ "module keys synth.fm_synth\n"
            ~ "module bass synth.analog_gen\n"
            ~ "module kit synth.drumsynth\n"
            ~ "module perc synth.drumsynth\n"
            ~ "connect keys out\n"
            ~ "connect bass out\n"
            ~ "connect kit out\n"
            ~ "connect perc out\n"
            ~ "section v bars=2\n"
            ~ "section c bars=2\n"
            ~ "section five bars=5\n"
            ~ "part keys module=keys\n"
            ~ "part bass module=bass\n"
            ~ "part drums drums=kit\n"
            ~ "chords keys v style=arp dir=updown every=1/4 voicing=close: I IV\n"
            ~ "chords keys c style=hold rhythm=X.x. octave=4 voices=4: vi V\n"
            ~ "chords bass v style=root5 octave=2: I IV\n"
            ~ "chords bass five style=root octave=2 preset=\"circle of fifths\"\n"
            ~ "drums drums v kick: x...x...\n"
            ~ "drums drums v snare fill=2: ....X...\n"
            ~ "drums percbeat module=perc\n"
            ~ "drums percbeat lane=clap module=perc note=39\n"
            ~ "drums percbeat v clap: ..g.X...\n"
        );
        assert(r.ok, r.problems.length > 0 ? r.problems[0].text() : "");

        assert(interp.parts().notesOfPart("keys", "v").length >= 8);
        assert(interp.parts().notesOfPart("keys", "c").length == 64);
        assert(interp.parts().notesOfPart("bass", "v").length == 8);
        auto drumPats = interp.drums().savedPatterns();
        assert(drumPats.length == 2);
        size_t hitCount0 = 0;
        foreach (ref c; drumPats[0].cells) {
            if (c.isMidiNote()) hitCount0++;
        }
        size_t hitCount1 = 0;
        foreach (ref c; drumPats[1].cells) {
            if (c.isMidiNote()) hitCount1++;
        }
        assert(hitCount0 >= 4);
        assert(hitCount1 == 2);

        ScriptInterpreter errInterp = createDefaultInterpreter(false);
        assert(errInterp.runScript(
            "module keys synth.fm_synth\n"
            ~ "module kit synth.drumsynth\n"
            ~ "section v bars=1\n"
            ~ "part keys module=keys\n"
            ~ "part drums drums=kit\n"
        ).ok);

        immutable StepResult badChord = errInterp.runLine("chords keys v style=arp: I Z9", 6);
        assert(!badChord.ok && badChord.problem.line == 6 && badChord.problem.column >= 25);

        immutable StepResult badRhythm = errInterp.runLine("chords keys v rhythm=X..: I", 7);
        assert(!badRhythm.ok && badRhythm.problem.line == 7 && badRhythm.problem.column >= 15);

        immutable StepResult badDrumStep = errInterp.runLine("drums drums v kick: x?x.", 8);
        assert(!badDrumStep.ok && badDrumStep.problem.line == 8 && badDrumStep.problem.column == 22);

        immutable string dir = buildPath(tempDir(), "dracker_night_drive_test");
        mkdirRecurse(dir);
        scope (exit) {
            if (exists(dir)) {
                rmdirRecurse(dir);
            }
        }
        immutable string outPath = buildPath(dir, "night_drive.msv");
        ScriptInterpreter nd = createDefaultInterpreter(false);
        RunResult ndRes = nd.runScript(
            "project \"Night Drive\"\n"
            ~ "tempo 96\n"
            ~ "signature 4/4\n"
            ~ "key A minor\n"
            ~ "module bass preset=\"Electric Bass\"\n"
            ~ "module keys preset=\"Electric Piano\"\n"
            ~ "set keys Release=250\n"
            ~ "connect bass out gain=0.3\n"
            ~ "connect keys out gain=0.22\n"
            ~ "section verse bars=4\n"
            ~ "part bass module=bass\n"
            ~ "part keys module=keys\n"
            ~ "chords keys verse: i VI III VII style=hold\n"
            ~ "chords bass verse: i VI III VII style=root octave=2\n"
            ~ "arrange verse verse\n"
            ~ "save \"" ~ outPath ~ "\"\n"
        );
        assert(ndRes.ok, ndRes.problems.length > 0 ? ndRes.problems[0].text() : "");
        assert(exists(outPath));

        StudioSession session = new StudioSession();
        assert(session.initialize(44_100.0f));
        scope (exit) session.shutdown();
        string loadErr;
        assert(session.openProjectFile(outPath, loadErr), loadErr);
        session.engine().reset();
        session.engine().setTempo(session.document().bpm, session.document().ticksPerLine);
        session.engine().seekLine(0);
        session.engine().setPlaying(true);
        float[FIXED_BLOCK_FRAMES] left;
        float[FIXED_BLOCK_FRAMES] right;
        float[][2] outs = [left[], right[]];
        const(float[])[2] emptyIn = [null, null];
        float peak = 0.0f;
        foreach (_; 0 .. 64) {
            session.engine().processHostBuffer(outs, emptyIn, FIXED_BLOCK_FRAMES);
            foreach (k; 0 .. FIXED_BLOCK_FRAMES) {
                immutable float a = fabs(left[k]);
                immutable float b = fabs(right[k]);
                if (a > peak) peak = a;
                if (b > peak) peak = b;
            }
        }
        session.engine().setPlaying(false);
        assert(peak > 0.001f);
    }
}
