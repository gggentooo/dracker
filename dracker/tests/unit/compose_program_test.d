/**
 * File:         tests/unit/compose_program_test.d
 * Module:       tests.unit.compose_program_test
 * Phase:        Composition helper (dracker-compose) — T72 (Second executable)
 *
 * Purpose:
 *   Verifies compose_main, the command line of dracker-compose (decision T66), without a terminal: every
 *   subcommand in its accepted forms with -o and --json anywhere on the line; every wrong usage with its
 *   message and the nearest valid choice; the help of the program and of one subcommand as text and as JSON
 *   that parses and carries the same facts (program name, script extension, exit codes, the six subcommands);
 *   the exit codes through runProgram() with delegates in place of the streams and files (0 help, 2 wrong
 *   usage, 1 a file that cannot be read or a subcommand that is not available yet), with --json honored when
 *   it comes before the mistake and nothing written to the error stream in JSON form; the JSON writer's
 *   escaping and layout; reading a file from disk; and random argument lists that never throw.
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Streams and files are replaced by delegates, except one case that reads a temporary file from disk
 *   and removes it again. Nothing is printed.
 *
 * Dependencies:
 *   Internal: compose_main
 *   External: std.algorithm, std.array, std.file, std.json, std.path
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T66, T72), source/compose_main.d
 */
module tests.unit.compose_program_test;

version (unittest) {
    import std.algorithm : startsWith;
    import std.array : join;
    import std.file : exists, remove, tempDir, write;
    import std.json : parseJSON, JSONValue;
    import std.path : buildPath;

    import compose_main;

    private immutable string[6] NAMES = ["run", "check", "catalog", "describe", "render", "help"];

    /**
     * One wrong command line: what was written, what the program answers, the nearest valid choice, and a
     * command line that uses that choice and must be accepted.
     */
    private struct UsageCase {
        string[] args;
        string message;
        string suggestion;
        string[] working;
    }

    /**
     * The offset of a text inside another.
     *
     * Params:
     *   text = The text to search.
     *   part = The text to look for.
     *
     * Returns:
     *   Its offset, or text.length when it is not there.
     */
    private size_t indexOf(string text, string part) {
        foreach (i; 0 .. text.length) {
            if (text.length - i >= part.length && text[i .. i + part.length] == part) {
                return i;
            }
        }
        return text.length;
    }

    /**
     * Runs the program with the streams and the input file replaced.
     *
     * Params:
     *   args = The arguments after the program name.
     *   output = Receives what the program wrote to its output stream.
     *   errors = Receives what the program wrote to its error stream.
     *   fileReadable = Whether the input file exists.
     *
     * Returns:
     *   The exit code.
     */
    private int run(string[] args, out string output, out string errors, bool fileReadable = true) {
        string outText = "";
        string errText = "";
        ProgramIo io;
        io.writeOutput = (string text) @safe {
            outText ~= text;
        };
        io.writeError = (string text) @safe {
            errText ~= text;
        };
        io.readInputFile = (string path, out ubyte[] bytes, out string err) @safe nothrow {
            bytes = null;
            if (!fileReadable) {
                err = "No such file or directory";
                return false;
            }
            bytes = cast(ubyte[]) ("script " ~ path).dup;
            return true;
        };
        immutable int code = runProgram(args, io);
        output = outText;
        errors = errText;
        return code;
    }

    /**
     * A text with its first letter in upper case, as the help prints a summary.
     *
     * Params:
     *   text = The text.
     *
     * Returns:
     *   The text with a capital first letter.
     */
    private string capital(string text) {
        return text.length > 0 && text[0] >= 'a' && text[0] <= 'z'
            ? cast(char) (text[0] - ('a' - 'A')) ~ text[1 .. $] : text;
    }

    /**
     * The next number of a small deterministic generator.
     *
     * Params:
     *   state = The generator state; advanced by the call.
     *
     * Returns:
     *   The next number.
     */
    private uint next(ref uint state) @nogc nothrow {
        state = state * 1103515245u + 12345u;
        return state;
    }

    unittest {
        assert(SUBCOMMANDS.length == 6);
        foreach (i, ref info; SUBCOMMANDS) {
            assert(info.name == NAMES[i], info.name);
            assert(cast(ubyte) info.kind == i, info.name);
            assert(subcommandInfo(info.kind).name == info.name);
            assert(info.usage.startsWith(info.name), info.usage);
            assert((info.builtBy.length > 0) == (info.kind != Subcommand.help), info.name);
        }
        assert(subcommandInfo(Subcommand.help).outputAllowed == false);
        assert(subcommandInfo(Subcommand.run).outputAllowed && !subcommandInfo(Subcommand.run).outputRequired);
        assert(subcommandInfo(Subcommand.render).outputAllowed && subcommandInfo(Subcommand.render).outputRequired);
        assert(subcommandInfo(Subcommand.run).builtBy == "T83" && subcommandInfo(Subcommand.check).builtBy == "T83");
        assert(subcommandInfo(Subcommand.catalog).builtBy == "T85");
        assert(subcommandInfo(Subcommand.render).builtBy == "T86");
        assert(subcommandInfo(Subcommand.describe).builtBy == "T87");
        assert(PROGRAM_NAME == "dracker-compose" && SCRIPT_EXTENSION == ".dcs");
        assert(ExitCode.success == 0 && ExitCode.fileError == 1 && ExitCode.wrongUsage == 2);
    }

    unittest {
        ParsedCommandLine none = parseCommandLine([]);
        assert(!none.ok && none.error.message == "a subcommand is needed" && none.error.suggestion == "help");
        assert(!none.command.json);
        ParsedCommandLine onlyJson = parseCommandLine(["--json"]);
        assert(!onlyJson.ok && onlyJson.error.message == "a subcommand is needed");
        assert(onlyJson.error.suggestion == "" && onlyJson.command.json);

        ParsedCommandLine help = parseCommandLine(["help"]);
        assert(help.ok && help.command.subcommand == Subcommand.help && help.command.topic == Subcommand.help);
        assert(help.command.operands.length == 0 && !help.command.json && help.command.outputPath == "");
        ParsedCommandLine helpRun = parseCommandLine(["help", "run"]);
        assert(helpRun.ok && helpRun.command.topic == Subcommand.run && helpRun.command.operands == ["run"]);
        ParsedCommandLine helpRender = parseCommandLine(["--json", "help", "render"]);
        assert(helpRender.ok && helpRender.command.json && helpRender.command.topic == Subcommand.render);

        ParsedCommandLine runIt = parseCommandLine(["run", "a.dcs"]);
        assert(runIt.ok && runIt.command.subcommand == Subcommand.run && runIt.command.operands == ["a.dcs"]);
        assert(runIt.command.outputPath == "" && runIt.command.topic == Subcommand.help);
        ParsedCommandLine after = parseCommandLine(["run", "a.dcs", "-o", "out.msv", "--json"]);
        assert(after.ok && after.command.outputPath == "out.msv" && after.command.json);
        assert(after.command.operands == ["a.dcs"]);
        ParsedCommandLine before = parseCommandLine(["--json", "-o", "out.msv", "run", "a.dcs"]);
        assert(before.ok && before.command.outputPath == "out.msv" && before.command.json);
        assert(before.command.operands == ["a.dcs"]);
        ParsedCommandLine between = parseCommandLine(["run", "-o", "out.msv", "a.dcs"]);
        assert(between.ok && between.command.operands == ["a.dcs"] && between.command.outputPath == "out.msv");
        assert(parseCommandLine(["check", "b.dcs"]).ok);
        assert(parseCommandLine(["catalog"]).ok && parseCommandLine(["catalog"]).command.operands.length == 0);
        ParsedCommandLine topic = parseCommandLine(["catalog", "modules"]);
        assert(topic.ok && topic.command.operands == ["modules"]);
        assert(parseCommandLine(["describe", "x.msv"]).ok && parseCommandLine(["describe", "x.msym"]).ok);
        ParsedCommandLine rendered = parseCommandLine(["render", "x.msv", "-o", "x.wav"]);
        assert(rendered.ok && rendered.command.outputPath == "x.wav"
            && rendered.command.subcommand == Subcommand.render);
    }

    unittest {
        immutable UsageCase[] CASES = [
            UsageCase(["run"], "run needs a script", "", []),
            UsageCase(["run", ""], "run needs a script", "", []),
            UsageCase(["run", "a.dcs", "b.dcs"], "run takes one script, 2 were given", "", []),
            UsageCase(["check", "a", "b", "c"], "check takes one script, 3 were given", "", []),
            UsageCase(["run", "-o"], "-o needs a file name after it", "", []),
            UsageCase(["run", "-o", ""], "-o needs a file name after it", "", []),
            UsageCase(["run", "-o", "x"], "run needs a script", "", []),
            UsageCase(["run", "a.dcs", "-o", "x", "-o", "y"], "-o is given twice", "", []),
            UsageCase(["check", "a.dcs", "-o", "x"], "check does not take -o", "", []),
            UsageCase(["describe"], "describe needs a file", "", []),
            UsageCase(["catalog", "a", "b"], "catalog takes one topic, 2 were given", "", []),
            UsageCase(["catalog", ""], "catalog needs a topic", "", []),
            UsageCase(["render", "x.msv"], "render needs -o <file.wav>", "", []),
            UsageCase(["render", "x.msv", "--json"], "render needs -o <file.wav>", "", []),
            UsageCase(["help", "run", "check"], "help takes one subcommand, 2 were given", "", []),
            UsageCase(["catlog"], "unknown subcommand 'catlog'", "catalog", ["catalog"]),
            UsageCase(["rn", "a.dcs"], "unknown subcommand 'rn'", "run", ["run", "a.dcs"]),
            UsageCase(["frobnicate"], "unknown subcommand 'frobnicate'", "", []),
            UsageCase(["HELP"], "unknown subcommand 'HELP'", "", []),
            UsageCase(["help", "rn"], "help does not know the subcommand 'rn'", "run", ["help", "run"]),
            UsageCase(["help", "nope"], "help does not know the subcommand 'nope'", "", []),
            UsageCase(["run", "--jsn"], "unknown option '--jsn'", "--json", ["run", "a.dcs", "--json"]),
            UsageCase(["-json", "run"], "unknown option '-json'", "--json", ["--json", "help"]),
            UsageCase(["run", "--output", "x"], "unknown option '--output'", "", []),
            UsageCase(["--json", "run", "-x"], "unknown option '-x'", "-o", ["run", "a.dcs", "-o", "out.msv"]),
        ];
        size_t suggested = 0;
        foreach (ref row; CASES) {
            immutable string[] args = row.args;
            ParsedCommandLine parsed = parseCommandLine(args);
            assert(!parsed.ok, args.length > 0 ? args[0] : "(none)");
            assert(parsed.error.message == row.message, parsed.error.message);
            assert(parsed.error.suggestion == row.suggestion,
                "'" ~ parsed.error.suggestion ~ "' for " ~ parsed.error.message);
            if (row.working.length > 0) {
                assert(parseCommandLine(row.working).ok, row.working.join(" "));
                assert(row.working.join(" ").indexOf(row.suggestion) != row.working.join(" ").length);
                suggested++;
            }
        }
        assert(suggested == 6);
        ParsedCommandLine jsonKept = parseCommandLine(["--json", "run"]);
        assert(!jsonKept.ok && jsonKept.command.json && jsonKept.command.subcommand == Subcommand.run);
        ParsedCommandLine jsonKept2 = parseCommandLine(["--json", "render", "x.msv"]);
        assert(!jsonKept2.ok && jsonKept2.command.json);
    }

    unittest {
        string usage = usageText();
        foreach (line; ["Usage:", "dracker-compose <subcommand> [arguments] [--json]", "Subcommands:",
                "run <script> [-o <file>]", "check <script>", "catalog [topic]",
                "describe <file.msv|file.msym>", "render <file.msv> -o <file.wav>", "help [subcommand]",
                "Options:", "-o <file>", "--json", "Exit codes:", "0  success", "1  the script or a file has errors",
                "2  wrong usage", ".dcs"]) {
            assert(usage.indexOf(line) != usage.length, line);
        }
        assert(usage.indexOf("not available") == usage.length);
        size_t column = size_t.max;
        foreach (ref info; SUBCOMMANDS) {
            immutable size_t startOfLine = usage.indexOf("\n  " ~ info.usage ~ "  ");
            assert(startOfLine != usage.length, info.usage);
            immutable size_t summaryAt = 2 + info.usage.length
                + usage[startOfLine + 3 + info.usage.length .. $].indexOf("  " ~ capital(info.summary)) + 2;
            column = column == size_t.max ? summaryAt : column;
            assert(summaryAt == column, info.name);
        }
        assert(column == 35);
        assert("render <file.msv> -o <file.wav>".length == 31 && "describe <file.msv|file.msym>".length == 29);

        string runHelp = subcommandHelpText(Subcommand.run);
        assert(runHelp.startsWith("Usage:\n  dracker-compose run <script> [-o <file>]\n\nRuns a script"));
        foreach (part; ["Arguments:", "script   The script file (.dcs)", "--json", "-o <file>",
                "The file the run writes.", "0  success", "2  wrong usage",
                "Not available in this build yet (task T83)."]) {
            assert(runHelp.indexOf(part) != runHelp.length, part);
        }
        string renderHelp = subcommandHelpText(Subcommand.render);
        assert(renderHelp.indexOf("-o <file>   The WAV file to write (needed).") != renderHelp.length);
        assert(renderHelp.indexOf("(task T86)") != renderHelp.length);
        string catalogHelp = subcommandHelpText(Subcommand.catalog);
        assert(catalogHelp.indexOf("topic   One part of the catalog") != catalogHelp.length);
        assert(catalogHelp.indexOf("-o <file>") == catalogHelp.length);
        string helpHelp = subcommandHelpText(Subcommand.help);
        assert(helpHelp.indexOf("Not available") == helpHelp.length);
        assert(helpHelp.indexOf("dracker-compose help [subcommand]") != helpHelp.length);
        foreach (info; SUBCOMMANDS) {
            assert(subcommandHelpText(info.kind).indexOf(info.usage) != subcommandHelpText(info.kind).length);
        }
    }

    unittest {
        string all = helpJson();
        JSONValue doc = parseJSON(all);
        assert(doc["ok"].boolean && doc["program"].str == "dracker-compose" && doc["scriptExtension"].str == ".dcs");
        assert(doc["exitCodes"].array.length == 3);
        assert(doc["exitCodes"][0]["code"].integer == 0 && doc["exitCodes"][0]["meaning"].str == "success");
        assert(doc["exitCodes"][1]["code"].integer == 1);
        assert(doc["exitCodes"][1]["meaning"].str == "the script or a file has errors");
        assert(doc["exitCodes"][2]["code"].integer == 2 && doc["exitCodes"][2]["meaning"].str == "wrong usage");
        assert(doc["subcommands"].array.length == 6);
        foreach (i, ref info; SUBCOMMANDS) {
            JSONValue entry = doc["subcommands"][cast(uint) i];
            assert(entry["name"].str == info.name && entry["usage"].str == info.usage);
            assert(entry["summary"].str == info.summary);
            assert(entry["available"].boolean == (info.kind == Subcommand.help), info.name);
            if (info.kind != Subcommand.help) {
                assert(entry["builtBy"].str == info.builtBy, info.name);
            }
        }
        assert(doc["subcommands"][0]["argument"].str == "script");
        assert(doc["subcommands"][0]["argumentOptional"].boolean == false);
        assert(doc["subcommands"][0]["output"].str == "optional");
        assert(doc["subcommands"][1]["output"].str == "");
        assert(doc["subcommands"][2]["argument"].str == "topic");
        assert(doc["subcommands"][2]["argumentOptional"].boolean == true);
        assert(doc["subcommands"][4]["output"].str == "required");
        assert(doc["subcommands"][5]["argument"].str == "subcommand");
        assert(all[all.length - 1] == '\n');

        JSONValue one = parseJSON(helpJson(Subcommand.render));
        assert(one["ok"].boolean && one["subcommands"].array.length == 1);
        assert(one["subcommands"][0]["name"].str == "render" && one["subcommands"][0]["available"].boolean == false);
        assert(parseJSON(helpJson(Subcommand.help))["subcommands"].array.length == 6);

        foreach (text; ["plain", "a\"b\\c", "line\nbreak\ttab", "\u0001\u001F\u007F", "caf\u00E9 \u266B",
                "", "--json"]) {
            immutable string quoted = jsonString(text);
            JSONValue value = parseJSON(quoted);
            assert(value.str == text, quoted);
        }
        assert(jsonString("a\"b\\c\n\t\u0001") == "\"a\\\"b\\\\c\\n\\t\\u0001\"");

        JsonWriter writer = JsonWriter();
        writer.beginObject();
        writer.key("a");
        writer.valueInt(-5);
        writer.key("b");
        writer.valueBool(true);
        writer.key("c");
        writer.beginArray();
        writer.valueString("x");
        writer.valueString("y");
        writer.endArray();
        writer.key("d");
        writer.beginObject();
        writer.endObject();
        writer.key("e");
        writer.beginArray();
        writer.endArray();
        writer.endObject();
        assert(writer.text() == "{\n  \"a\": -5,\n  \"b\": true,\n  \"c\": [\n    \"x\",\n    \"y\"\n  ],\n  \"d\": {},"
            ~ "\n  \"e\": []\n}", writer.text());
        assert(parseJSON(writer.text())["c"].array.length == 2);
        JsonWriter top = JsonWriter();
        top.beginArray();
        top.valueInt(0);
        top.valueInt(long.max);
        top.valueInt(long.min);
        top.endArray();
        assert(top.text() == "[\n  0,\n  9223372036854775807,\n  -9223372036854775808\n]", top.text());
        assert(JsonWriter().text() == "");
        assert(problemText("a problem", "") == "a problem.");
        assert(problemText("a problem", "x") == "a problem; did you mean 'x'?");
    }

    unittest {
        string output;
        string errors;

        assert(run(["help"], output, errors) == 0 && output == usageText() && errors == "");
        assert(run(["help", "run"], output, errors) == 0 && output == subcommandHelpText(Subcommand.run)
            && errors == "");
        assert(run(["help", "catalog", "--json"], output, errors) == 0 && errors == "");
        JSONValue catalogDoc = parseJSON(output);
        assert(catalogDoc["ok"].boolean && catalogDoc["subcommands"].array.length == 1);
        assert(catalogDoc["subcommands"][0]["name"].str == "catalog");
        assert(run(["--json", "help"], output, errors) == 0 && errors == "");
        assert(parseJSON(output)["subcommands"].array.length == 6);

        assert(run([], output, errors) == 2 && output == "");
        assert(errors == "dracker-compose: a subcommand is needed; did you mean 'help'?\n"
            ~ "Try 'dracker-compose help'.\n", errors);
        assert(run(["catlog", "x"], output, errors) == 2 && output == "");
        assert(errors == "dracker-compose: unknown subcommand 'catlog'; did you mean 'catalog'?\n"
            ~ "Try 'dracker-compose help'.\n", errors);
        assert(run(["run"], output, errors) == 2);
        assert(errors == "dracker-compose: run needs a script.\nTry 'dracker-compose help run'.\n", errors);
        assert(run(["help", "rn"], output, errors) == 2);
        assert(errors == "dracker-compose: help does not know the subcommand 'rn'; did you mean 'run'?\n"
            ~ "Try 'dracker-compose help'.\n", errors);
        assert(run(["render", "x.msv"], output, errors) == 2);
        assert(errors == "dracker-compose: render needs -o <file.wav>.\nTry 'dracker-compose help render'.\n",
            errors);

        assert(run(["--json", "catlog"], output, errors) == 2 && errors == "");
        JSONValue usageDoc = parseJSON(output);
        assert(!usageDoc["ok"].boolean && usageDoc["error"]["code"].str == "usage");
        assert(usageDoc["error"]["message"].str == "unknown subcommand 'catlog'; did you mean 'catalog'?");
        assert(usageDoc["error"]["suggestion"].str == "catalog");
        assert(usageDoc["error"]["hint"].str == "dracker-compose help");
        assert(usageDoc["error"].object.length == 4);
        assert(run(["--json", "run"], output, errors) == 2 && errors == "");
        JSONValue runDoc = parseJSON(output);
        assert(runDoc["error"]["code"].str == "usage" && runDoc["error"]["message"].str == "run needs a script.");
        assert(runDoc["error"]["subcommand"].str == "run" && runDoc["error"]["hint"].str == "dracker-compose help run");
        assert(("suggestion" in runDoc["error"]) is null);

        assert(run(["run", "a.dcs"], output, errors, false) == 1 && output == "");
        assert(errors == "dracker-compose: could not read 'a.dcs': No such file or directory.\n", errors);
        assert(run(["describe", "x.msv"], output, errors, false) == 1);
        assert(errors == "dracker-compose: could not read 'x.msv': No such file or directory.\n", errors);
        assert(run(["--json", "run", "a.dcs"], output, errors, false) == 1 && errors == "");
        JSONValue fileDoc = parseJSON(output);
        assert(!fileDoc["ok"].boolean && fileDoc["error"]["code"].str == "file");
        assert(fileDoc["error"]["message"].str == "could not read 'a.dcs': No such file or directory.");
        assert(fileDoc["error"]["subcommand"].str == "run" && fileDoc["error"].object.length == 3);

        assert(run(["run", "a.dcs"], output, errors) == 1 && output == "");
        assert(errors == "dracker-compose: 'run' is not available in this build yet (task T83).\n"
            ~ "Try 'dracker-compose help run'.\n", errors);
        assert(run(["check", "a.dcs"], output, errors) == 1);
        assert(errors.indexOf("'check' is not available in this build yet (task T83).") != errors.length, errors);
        assert(run(["catalog"], output, errors) == 1);
        assert(errors == "dracker-compose: 'catalog' is not available in this build yet (task T85).\n"
            ~ "Try 'dracker-compose help catalog'.\n", errors);
        assert(run(["catalog", "modules"], output, errors) == 1);
        assert(run(["describe", "a.msym"], output, errors) == 1);
        assert(errors.indexOf("(task T87)") != errors.length);
        assert(run(["render", "a.msv", "-o", "a.wav"], output, errors) == 1);
        assert(errors.indexOf("'render' is not available in this build yet (task T86).") != errors.length);
        assert(run(["--json", "catalog", "modules"], output, errors) == 1 && errors == "");
        JSONValue pending = parseJSON(output);
        assert(!pending["ok"].boolean && pending["error"]["code"].str == "not_available");
        assert(pending["error"]["message"].str == "'catalog' is not available in this build yet (task T85).");
        assert(pending["error"]["subcommand"].str == "catalog");
        assert(pending["error"]["hint"].str == "dracker-compose help catalog");
        assert(run(["--json", "run", "a.dcs", "-o", "out.msv"], output, errors) == 1 && errors == "");
        assert(parseJSON(output)["error"]["subcommand"].str == "run");
    }

    unittest {
        immutable string path = buildPath(tempDir(), "dracker-compose-program-test.dcs");
        scope (exit) {
            if (exists(path)) {
                remove(path);
            }
        }
        write(path, "project \"Test\"\n");
        string outText = "";
        string errText = "";
        ProgramIo io;
        io.writeOutput = (string text) @safe {
            outText ~= text;
        };
        io.writeError = (string text) @safe {
            errText ~= text;
        };
        assert(runProgram(["check", path], io) == 1);
        assert(errText.indexOf("could not read") == errText.length, errText);
        assert(errText.indexOf("'check' is not available in this build yet (task T83).") != errText.length);
        errText = "";
        immutable string missing = buildPath(tempDir(), "dracker-compose-no-such-file.dcs");
        assert(runProgram(["check", missing], io) == 1);
        assert(errText.indexOf("could not read '" ~ missing ~ "': ") != errText.length, errText);
        errText = "";
        assert(runProgram(["--json", "check", missing], io) == 1 && errText == "");
        assert(parseJSON(outText)["error"]["code"].str == "file");
        remove(path);
        assert(runProgram(["help"], io) == 0);
        assert(runProgram(["help"], ProgramIo()) == 2);
    }

    unittest {
        immutable string[14] WORDS = ["run", "check", "catalog", "describe", "render", "help", "-o", "--json",
            "a.dcs", "out.msv", "rn", "--jsn", "", "frobnicate"];
        uint state = 726u;
        string output;
        string errors;
        size_t[] codes = [0, 0, 0];
        foreach (round; 0 .. 3000) {
            immutable size_t length = next(state) % 7u;
            string[] args;
            foreach (k; 0 .. length) {
                args ~= WORDS[next(state) % WORDS.length];
            }
            immutable int code = run(args, output, errors, next(state) % 2u == 0);
            assert(code == 0 || code == 1 || code == 2);
            codes[cast(size_t) code]++;
            ParsedCommandLine parsed = parseCommandLine(args);
            if (parsed.ok && parsed.command.json) {
                assert(errors == "", args.join(" "));
                parseJSON(output);
            }
        }
        assert(codes[0] > 0 && codes[1] > 0 && codes[2] > 0);
    }
}
