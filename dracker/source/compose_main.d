/**
 * File:         source/compose_main.d
 * Module:       compose_main
 * Phase:        Composition helper (dracker-compose) — T72 (Second executable)
 *
 * Purpose:
 *   The command line of dracker-compose (decision T66): it parses the subcommand and its options, prints the
 *   help as text or as JSON, reads the file a subcommand is given, and sets the exit code (0 success, 1 the
 *   script or a file has errors, 2 wrong usage). The subcommands themselves are filled in by later tasks: run
 *   and check by T83 and T84, catalog by T85, render by T86, describe by T87. Until then each of them reads its
 *   file when it has one, answers that it is not available in this build yet, and exits with 1.
 *   --json may be written anywhere on the command line and prints the same information as JSON: for the help
 *   a document with the program name, the script extension, the exit codes and the subcommands; for a problem
 *   an object with ok=false and the problem. In text form a problem goes to the error stream and the help to
 *   the output stream; in JSON form everything goes to the output stream.
 *   The parsing and the help are pure functions, and runProgram() reads and writes only through the delegates
 *   of ProgramIo, so the whole program can be tested without a terminal or files. The entry point exists only
 *   in the compose configuration (version ComposeProgram), so this module is also part of the app and headless
 *   builds, where it has no main.
 *
 * Real-Time & Safety Contract:
 *   Off-RT. The parsing, the help and the JSON writer are @safe pure nothrow. runProgram() is @safe and does
 *   its input and output only through the delegates of ProgramIo; the real ones read a file with std.file and
 *   write to the standard streams. No audio, GUI or session code.
 *
 * Dependencies:
 *   Internal: compose.names (nearestName: the same suggestion rule as the rest of the helper, without regard
 *             to case or spaces)
 *   External: std.file (read), std.stdio (stderr, stdout)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum PROGRAM_NAME, SCRIPT_EXTENSION; enum ExitCode; enum ErrorCode; enum Subcommand
 *   - struct SubcommandInfo; SUBCOMMANDS; subcommandInfo()
 *   - struct CommandLine; struct UsageError; struct ParsedCommandLine; parseCommandLine()
 *   - struct ProgramIo; realProgramIo()
 *   - usageText(), subcommandHelpText(); helpJson(); problemText()
 *   - struct JsonWriter (beginObject(), key(), valueString(), valueInt(), valueBool(), beginArray(),
 *     endArray(), endObject(), text()); jsonString()
 *   - runProgram(args, io); version (ComposeProgram) int main(string[] args)
 *
 * See_Also:
 *   docs/todo.md (T66, T72), source/compose/
 */
module compose_main;

import std.file : read;
import std.stdio : stderr, stdout;

import compose.names : nearestName;

/**
 * The name the program is called by.
 */
enum string PROGRAM_NAME = "dracker-compose";

/**
 * The file name extension of a script.
 */
enum string SCRIPT_EXTENSION = ".dcs";

/**
 * The exit codes of the program (decision T66).
 */
enum ExitCode : int {
    success = 0,
    fileError = 1,
    wrongUsage = 2
}

/**
 * The code of a problem in the JSON output.
 */
enum ErrorCode : string {
    usage = "usage",
    file = "file",
    notAvailable = "not_available"
}

/**
 * The subcommands of the program (decision T66), in the order SUBCOMMANDS lists them.
 */
enum Subcommand : ubyte {
    run = 0,
    check = 1,
    catalog = 2,
    describe = 3,
    render = 4,
    help = 5
}

/**
 * What the command line needs to know about one subcommand.
 */
struct SubcommandInfo {
    Subcommand kind;
    string name;
    string usage;
    string summary;
    string operandName;
    string operandDescription;
    size_t minOperands;
    size_t maxOperands;
    bool outputAllowed;
    bool outputRequired;
    string builtBy;
}

/**
 * The subcommands, in the order the help lists them and the order of Subcommand.
 */
immutable SubcommandInfo[] SUBCOMMANDS = [
    SubcommandInfo(Subcommand.run, "run", "run <script> [-o <file>]",
        "runs a script; its own save commands write files, and -o names the file the run writes.",
        "script", "The script file (.dcs): plain text with one command per line.", 1, 1, true, false, "T83"),
    SubcommandInfo(Subcommand.check, "check", "check <script>",
        "runs a script without writing anything, to look for errors.",
        "script", "The script file (.dcs).", 1, 1, false, false, "T83"),
    SubcommandInfo(Subcommand.catalog, "catalog", "catalog [topic]",
        "lists what a script can use: module types, parameters, presets, chords and commands.",
        "topic", "One part of the catalog, such as modules; the whole catalog when left out.", 0, 1, false,
        false, "T85"),
    SubcommandInfo(Subcommand.describe, "describe", "describe <file.msv|file.msym>",
        "prints a project (.msv) or a module preset (.msym) as a script.",
        "file", "A project (.msv) or a preset (.msym) file.", 1, 1, false, false, "T87"),
    SubcommandInfo(Subcommand.render, "render", "render <file.msv> -o <file.wav>",
        "plays a project offline into a WAV file and reports the levels.",
        "file", "A project (.msv) file.", 1, 1, true, true, "T86"),
    SubcommandInfo(Subcommand.help, "help", "help [subcommand]",
        "shows the help of the program, or of one subcommand.",
        "subcommand", "The subcommand to explain.", 0, 1, false, false, "")
];

/**
 * A command line that parsed.
 */
struct CommandLine {
    Subcommand subcommand = Subcommand.help;
    string[] operands;
    string outputPath;
    bool json = false;
    Subcommand topic = Subcommand.help;
}

/**
 * A command line that did not parse.
 */
struct UsageError {
    string message = "";
    string suggestion = "";
}

/**
 * The result of parsing a command line. On a failure command holds what was read before the problem, so a
 * --json that came first is still honored.
 */
struct ParsedCommandLine {
    bool ok = false;
    CommandLine command = CommandLine.init;
    UsageError error = UsageError.init;
}

/**
 * Where the program reads and writes: the output stream, the error stream and the files. Tests pass delegates
 * that write into strings; realProgramIo() returns the real ones. A null readInputFile reads the disk.
 */
struct ProgramIo {
    void delegate(string text) @safe writeOutput;
    void delegate(string text) @safe writeError;
    bool delegate(string path, out ubyte[] bytes, out string err) @safe nothrow readInputFile;
}

/**
 * Returns the entry on one subcommand.
 *
 * Params:
 *   subcommand = The subcommand.
 *
 * Returns:
 *   Its entry, or the entry of help when the value is not a subcommand.
 */
SubcommandInfo subcommandInfo(Subcommand subcommand) @safe pure nothrow {
    foreach (ref info; SUBCOMMANDS) {
        if (info.kind == subcommand) {
            return info;
        }
    }
    return SUBCOMMANDS[$ - 1];
}

/**
 * Parses the command line after the program name. The subcommand word and its operands are the arguments that
 * do not start with a dash; -o and --json may be written anywhere. help takes the name of one subcommand.
 *
 * Params:
 *   args = The arguments after the program name.
 *
 * Returns:
 *   The command, or a UsageError with a message and the nearest valid choice when there is one.
 */
ParsedCommandLine parseCommandLine(const(string)[] args) @safe pure nothrow {
    CommandLine command;
    string word = "";
    size_t outputs = 0;
    size_t i = 0;
    while (i < args.length) {
        immutable string arg = args[i];
        if (arg == "--json") {
            command.json = true;
        } else if (arg == "-o") {
            if (i + 1 >= args.length || args[i + 1].length == 0) {
                return refuse(command, "-o needs a file name after it", "");
            }
            i++;
            outputs++;
            command.outputPath = args[i];
        } else if (arg.length > 1 && arg[0] == '-') {
            return refuse(command, "unknown option '" ~ arg ~ "'", nearestName(arg, ["-o", "--json"]));
        } else if (word.length == 0) {
            word = arg;
        } else {
            command.operands ~= arg;
        }
        i++;
    }
    if (word.length == 0) {
        return refuse(command, "a subcommand is needed", args.length == 0 ? "help" : "");
    }
    immutable ptrdiff_t found = indexOfName(word);
    if (found < 0) {
        return refuse(command, "unknown subcommand '" ~ word ~ "'", nearestName(word, subcommandNames()));
    }
    immutable SubcommandInfo info = SUBCOMMANDS[cast(size_t) found];
    command.subcommand = info.kind;
    if (outputs > 1) {
        return refuse(command, "-o is given twice", "");
    }
    if (outputs == 1 && !info.outputAllowed) {
        return refuse(command, info.name ~ " does not take -o", "");
    }
    if (command.operands.length < info.minOperands) {
        return refuse(command, info.name ~ " needs a " ~ info.operandName, "");
    }
    if (command.operands.length > info.maxOperands) {
        return refuse(command, info.name ~ " takes one " ~ info.operandName ~ ", "
            ~ decimal(command.operands.length) ~ " were given", "");
    }
    foreach (ref operand; command.operands) {
        if (operand.length == 0) {
            return refuse(command, info.name ~ " needs a " ~ info.operandName, "");
        }
    }
    if (info.outputRequired && command.outputPath.length == 0) {
        return refuse(command, info.name ~ " needs -o <file.wav>", "");
    }
    if (info.kind == Subcommand.help && command.operands.length == 1) {
        immutable ptrdiff_t topic = indexOfName(command.operands[0]);
        if (topic < 0) {
            return refuse(command, "help does not know the subcommand '" ~ command.operands[0] ~ "'",
                nearestName(command.operands[0], subcommandNames()));
        }
        command.topic = cast(Subcommand) topic;
    }
    ParsedCommandLine parsed;
    parsed.ok = true;
    parsed.command = command;
    return parsed;
}

/**
 * The help of the whole program as text.
 *
 * Returns:
 *   The usage, the subcommands, the options and the exit codes.
 */
string usageText() @safe pure nothrow {
    string text = PROGRAM_NAME ~ " writes Dracker projects (.msv) and module presets (.msym) from a script.\n"
        ~ "\n"
        ~ "Usage:\n"
        ~ "  " ~ PROGRAM_NAME ~ " <subcommand> [arguments] [--json]\n"
        ~ "\n"
        ~ "Subcommands:\n";
    size_t width = 0;
    foreach (ref info; SUBCOMMANDS) {
        width = info.usage.length > width ? info.usage.length : width;
    }
    foreach (ref info; SUBCOMMANDS) {
        text ~= "  " ~ info.usage ~ spaces(width - info.usage.length + 2) ~ capitalize(info.summary) ~ "\n";
    }
    text ~= "\n"
        ~ "Options:\n"
        ~ "  -o <file>   The output file (run and render; see the subcommands).\n"
        ~ "  --json      Print the same information as JSON instead of text.\n"
        ~ "\n"
        ~ "Exit codes:\n"
        ~ "  0  success\n"
        ~ "  1  the script or a file has errors\n"
        ~ "  2  wrong usage\n"
        ~ "\n"
        ~ "A script is plain text with one command per line and ends in " ~ SCRIPT_EXTENSION ~ ".\n";
    return text;
}

/**
 * The help of one subcommand as text.
 *
 * Params:
 *   subcommand = The subcommand.
 *
 * Returns:
 *   Its usage, arguments, options, exit codes and whether it is available in this build.
 */
string subcommandHelpText(Subcommand subcommand) @safe pure nothrow {
    immutable SubcommandInfo info = subcommandInfo(subcommand);
    string text = "Usage:\n"
        ~ "  " ~ PROGRAM_NAME ~ " " ~ info.usage ~ "\n"
        ~ "\n"
        ~ capitalize(info.summary) ~ "\n";
    if (info.maxOperands > 0) {
        text ~= "\n"
            ~ "Arguments:\n"
            ~ "  " ~ info.operandName ~ "   " ~ info.operandDescription ~ "\n";
    }
    text ~= "\n"
        ~ "Options:\n"
        ~ "  --json      Print the result as JSON.\n";
    if (info.outputAllowed) {
        text ~= "  -o <file>   " ~ (info.kind == Subcommand.render
            ? "The WAV file to write (needed)."
            : "The file the run writes.") ~ "\n";
    }
    text ~= "\n"
        ~ "Exit codes:\n"
        ~ "  0  success\n"
        ~ "  1  the script or a file has errors\n"
        ~ "  2  wrong usage\n";
    if (info.builtBy.length > 0) {
        text ~= "\n"
            ~ "Not available in this build yet (task " ~ info.builtBy ~ ").\n";
    }
    return text;
}

/**
 * The help as JSON: the program name, the script extension, the exit codes and the subcommands.
 *
 * Params:
 *   topic = The one subcommand to describe, or help for all of them.
 *
 * Returns:
 *   A JSON document with ok=true.
 */
string helpJson(Subcommand topic = Subcommand.help) @safe pure nothrow {
    JsonWriter json = JsonWriter();
    json.beginObject();
    json.key("ok");
    json.valueBool(true);
    json.key("program");
    json.valueString(PROGRAM_NAME);
    json.key("scriptExtension");
    json.valueString(SCRIPT_EXTENSION);
    json.key("exitCodes");
    json.beginArray();
    json.beginObject();
    json.key("code");
    json.valueInt(ExitCode.success);
    json.key("meaning");
    json.valueString("success");
    json.endObject();
    json.beginObject();
    json.key("code");
    json.valueInt(ExitCode.fileError);
    json.key("meaning");
    json.valueString("the script or a file has errors");
    json.endObject();
    json.beginObject();
    json.key("code");
    json.valueInt(ExitCode.wrongUsage);
    json.key("meaning");
    json.valueString("wrong usage");
    json.endObject();
    json.endArray();
    json.key("subcommands");
    json.beginArray();
    foreach (ref info; SUBCOMMANDS) {
        if (topic != Subcommand.help && info.kind != topic) {
            continue;
        }
        json.beginObject();
        json.key("name");
        json.valueString(info.name);
        json.key("usage");
        json.valueString(info.usage);
        json.key("summary");
        json.valueString(info.summary);
        json.key("argument");
        if (info.maxOperands == 0) {
            json.valueString("");
        } else {
            json.valueString(info.operandName);
        }
        json.key("argumentOptional");
        json.valueBool(info.minOperands == 0);
        json.key("output");
        json.valueString(!info.outputAllowed ? "" : (info.outputRequired ? "required" : "optional"));
        json.key("available");
        json.valueBool(info.builtBy.length == 0);
        if (info.builtBy.length > 0) {
            json.key("builtBy");
            json.valueString(info.builtBy);
        }
        json.endObject();
    }
    json.endArray();
    json.endObject();
    return json.text() ~ "\n";
}

/**
 * Writes a problem as one sentence: the message, then the suggestion when there is one.
 *
 * Params:
 *   message = What is wrong, without a final period.
 *   suggestion = The nearest valid choice, or "".
 *
 * Returns:
 *   The sentence.
 */
string problemText(string message, string suggestion) @safe pure nothrow {
    return suggestion.length > 0 ? message ~ "; did you mean '" ~ suggestion ~ "'?" : message ~ ".";
}

/**
 * Runs the program on a command line: parses it, then shows the help, reads the file of the subcommand, and
 * answers. Nothing is written except through io.
 *
 * Params:
 *   args = The arguments after the program name.
 *   io = Where to write and how to read a file; writeOutput and writeError must be set.
 *
 * Returns:
 *   The exit code: 0, 1 or 2.
 */
int runProgram(const(string)[] args, ProgramIo io) @safe {
    ParsedCommandLine parsed = parseCommandLine(args);
    if (io.writeOutput is null || io.writeError is null) {
        return ExitCode.wrongUsage;
    }
    if (!parsed.ok) {
        immutable bool known = parsed.command.subcommand != Subcommand.help;
        reportProblem(io, parsed.command.json, ErrorCode.usage, parsed.error.message, parsed.error.suggestion,
            parsed.command.subcommand, known ? helpHint(parsed.command.subcommand) : PROGRAM_NAME ~ " help");
        return ExitCode.wrongUsage;
    }
    CommandLine command = parsed.command;
    immutable SubcommandInfo info = subcommandInfo(command.subcommand);
    if (command.subcommand == Subcommand.help) {
        if (command.json) {
            io.writeOutput(helpJson(command.topic));
        } else if (command.topic == Subcommand.help) {
            io.writeOutput(usageText());
        } else {
            io.writeOutput(subcommandHelpText(command.topic));
        }
        return ExitCode.success;
    }
    if (info.minOperands > 0) {
        ubyte[] bytes;
        string err;
        immutable bool readOk = io.readInputFile is null
            ? readFileFromDisk(command.operands[0], bytes, err)
            : io.readInputFile(command.operands[0], bytes, err);
        if (!readOk) {
            reportProblem(io, command.json, ErrorCode.file,
                "could not read '" ~ command.operands[0] ~ "': " ~ err, "", command.subcommand, "");
            return ExitCode.fileError;
        }
    }
    reportProblem(io, command.json, ErrorCode.notAvailable,
        "'" ~ info.name ~ "' is not available in this build yet (task " ~ info.builtBy ~ ")", "",
        command.subcommand, helpHint(command.subcommand));
    return ExitCode.fileError;
}

/**
 * The real input and output: the standard output stream, the standard error stream and the files on disk. The
 * stream closures are @trusted because the standard streams are shared globals whose write() is not marked
 * @safe, although writing a text is memory-safe.
 *
 * Returns:
 *   A ProgramIo for the entry point.
 */
ProgramIo realProgramIo() @safe {
    ProgramIo io;
    io.writeOutput = (string text) @trusted {
        stdout.write(text);
    };
    io.writeError = (string text) @trusted {
        stderr.write(text);
    };
    io.readInputFile = (string path, out ubyte[] bytes, out string err) @safe nothrow {
        return readFileFromDisk(path, bytes, err);
    };
    return io;
}

/**
 * Writes JSON with one value per line and two spaces of indentation per level. A value is written between
 * beginObject() and endObject(), or beginArray() and endArray(); inside an object each value follows a key().
 */
struct JsonWriter {
    private string text_;
    private bool[] filled_;
    private bool afterKey_ = false;

    /**
     * Starts an object.
     */
    void beginObject() @safe pure nothrow {
        beforeValue();
        text_ ~= "{";
        filled_ ~= false;
        afterKey_ = false;
    }

    /**
     * Ends an object.
     */
    void endObject() @safe pure nothrow {
        closeContainer();
        text_ ~= "}";
        afterValue();
    }

    /**
     * Starts an array.
     */
    void beginArray() @safe pure nothrow {
        beforeValue();
        text_ ~= "[";
        filled_ ~= false;
        afterKey_ = false;
    }

    /**
     * Ends an array.
     */
    void endArray() @safe pure nothrow {
        closeContainer();
        text_ ~= "]";
        afterValue();
    }

    /**
     * Writes the name of a member; the value written next is its value.
     *
     * Params:
     *   name = The member name.
     */
    void key(string name) @safe pure nothrow {
        beforeValue();
        text_ ~= jsonString(name) ~ ": ";
        afterKey_ = true;
    }

    /**
     * Writes a text.
     *
     * Params:
     *   value = The text.
     */
    void valueString(string value) @safe pure nothrow {
        beforeValue();
        text_ ~= jsonString(value);
        afterValue();
    }

    /**
     * Writes a whole number.
     *
     * Params:
     *   value = The number.
     */
    void valueInt(long value) @safe pure nothrow {
        beforeValue();
        text_ ~= value < 0 ? "-" ~ decimal(0UL - cast(ulong) value) : decimal(cast(ulong) value);
        afterValue();
    }

    /**
     * Writes true or false.
     *
     * Params:
     *   value = The value.
     */
    void valueBool(bool value) @safe pure nothrow {
        beforeValue();
        text_ ~= value ? "true" : "false";
        afterValue();
    }

    /**
     * Returns the JSON written so far.
     *
     * Returns:
     *   The JSON text, without a final newline.
     */
    string text() const @safe pure nothrow @nogc {
        return text_;
    }

    /**
     * Closes the innermost container: removes it, and breaks the line when it holds values.
     */
    private void closeContainer() @safe pure nothrow {
        immutable bool filled = filled_.length > 0 && filled_[$ - 1];
        if (filled_.length > 0) {
            filled_ = filled_[0 .. $ - 1];
        }
        if (filled) {
            newline();
        }
    }

    /**
     * Starts a line break with the indentation of the current depth.
     */
    private void newline() @safe pure nothrow {
        text_ ~= "\n";
        foreach (_; 0 .. filled_.length) {
            text_ ~= "  ";
        }
    }

    /**
     * Starts the line of a value inside a container, with a comma after the value before it. A value that
     * follows its key stays on the key's line, and an empty container stays on one line ("{}").
     */
    private void beforeValue() @safe pure nothrow {
        if (afterKey_) {
            afterKey_ = false;
            return;
        }
        if (filled_.length > 0) {
            if (filled_[$ - 1]) {
                text_ ~= ",";
            }
            newline();
        }
    }

    /**
     * Notes that the innermost container holds a value.
     */
    private void afterValue() @safe pure nothrow {
        if (filled_.length > 0) {
            filled_[$ - 1] = true;
        }
        afterKey_ = false;
    }
}

/**
 * A JSON text with its quotes, backslashes and control characters escaped.
 *
 * Params:
 *   text = The text.
 *
 * Returns:
 *   The text in double quotes.
 */
string jsonString(string text) @safe pure nothrow {
    string result = "\"";
    foreach (c; text) {
        switch (c) {
            case '"':
                result ~= "\\\"";
                break;
            case '\\':
                result ~= "\\\\";
                break;
            case '\n':
                result ~= "\\n";
                break;
            case '\r':
                result ~= "\\r";
                break;
            case '\t':
                result ~= "\\t";
                break;
            default:
                if (c < 0x20) {
                    result ~= "\\u00" ~ hexDigit(cast(ubyte) (c >> 4)) ~ hexDigit(cast(ubyte) (c & 0x0F));
                } else {
                    result ~= c;
                }
        }
    }
    return result ~ "\"";
}

/**
 * Ends a command line that did not parse, keeping what was read before the problem.
 *
 * Params:
 *   command = What was read before the problem.
 *   message = What is wrong.
 *   suggestion = The nearest valid choice, or "".
 *
 * Returns:
 *   The failed result.
 */
private ParsedCommandLine refuse(CommandLine command, string message, string suggestion) @safe pure nothrow {
    ParsedCommandLine parsed;
    parsed.command = command;
    parsed.error = UsageError(message, suggestion);
    return parsed;
}

/**
 * Writes a problem to the output or error stream, as text or as JSON.
 *
 * Params:
 *   io = Where to write.
 *   json = Whether to write JSON.
 *   code = The code of the problem.
 *   message = What is wrong, without a final period.
 *   suggestion = The nearest valid choice, or "".
 *   subcommand = The subcommand that was asked for, or help.
 *   hint = The command that explains more, such as "dracker-compose help run", or "".
 */
private void reportProblem(ProgramIo io, bool json, ErrorCode code, string message, string suggestion,
        Subcommand subcommand, string hint) @safe {
    immutable string sentence = problemText(message, suggestion);
    if (json) {
        JsonWriter writer = JsonWriter();
        writer.beginObject();
        writer.key("ok");
        writer.valueBool(false);
        writer.key("error");
        writer.beginObject();
        writer.key("code");
        writer.valueString(cast(string) code);
        writer.key("message");
        writer.valueString(sentence);
        if (suggestion.length > 0) {
            writer.key("suggestion");
            writer.valueString(suggestion);
        }
        if (subcommand != Subcommand.help) {
            writer.key("subcommand");
            writer.valueString(subcommandInfo(subcommand).name);
        }
        if (hint.length > 0) {
            writer.key("hint");
            writer.valueString(hint);
        }
        writer.endObject();
        writer.endObject();
        io.writeOutput(writer.text() ~ "\n");
        return;
    }
    io.writeError(PROGRAM_NAME ~ ": " ~ sentence ~ "\n");
    if (hint.length > 0) {
        io.writeError("Try '" ~ hint ~ "'.\n");
    }
}

/**
 * The command that explains a subcommand.
 *
 * Params:
 *   subcommand = The subcommand.
 *
 * Returns:
 *   "dracker-compose help <subcommand>".
 */
private string helpHint(Subcommand subcommand) @safe pure nothrow {
    return PROGRAM_NAME ~ " help " ~ subcommandInfo(subcommand).name;
}

/**
 * Reads a file from disk.
 *
 * Params:
 *   path = The file.
 *   bytes = Receives the bytes of the file.
 *   err = Receives the reason when the file cannot be read, instead of an exception.
 *
 * Returns:
 *   True when the file was read.
 */
private bool readFileFromDisk(string path, out ubyte[] bytes, out string err) @trusted nothrow {
    bytes = null;
    err = "";
    try {
        bytes = cast(ubyte[]) read(path);
        return true;
    } catch (Exception ex) {
        err = ex.msg.length > 0 ? ex.msg : "the file could not be read";
        return false;
    }
}

/**
 * The names of the subcommands.
 *
 * Returns:
 *   The names in the order of the help.
 */
private string[] subcommandNames() @safe pure nothrow {
    string[] names;
    foreach (ref info; SUBCOMMANDS) {
        names ~= info.name;
    }
    return names;
}

/**
 * Finds a subcommand by its exact name.
 *
 * Params:
 *   name = The name.
 *
 * Returns:
 *   Its index in SUBCOMMANDS, or -1 when there is none.
 */
private ptrdiff_t indexOfName(string name) @safe pure nothrow {
    foreach (i, ref info; SUBCOMMANDS) {
        if (info.name == name) {
            return cast(ptrdiff_t) i;
        }
    }
    return -1;
}




/**
 * A whole number as decimal text.
 *
 * Params:
 *   value = The number.
 *
 * Returns:
 *   Its decimal spelling.
 */
private string decimal(ulong value) @safe pure nothrow {
    char[20] buffer;
    size_t cursor = buffer.length;
    ulong remaining = value;
    do {
        cursor--;
        buffer[cursor] = cast(char) ('0' + remaining % 10);
        remaining /= 10;
    } while (remaining > 0);
    return buffer[cursor .. $].idup;
}

/**
 * A run of spaces.
 *
 * Params:
 *   count = How many.
 *
 * Returns:
 *   count spaces.
 */
private string spaces(size_t count) @safe pure nothrow {
    char[] buffer = new char[count];
    buffer[] = ' ';
    return buffer.idup;
}

/**
 * A text with its first letter in upper case.
 *
 * Params:
 *   text = The text.
 *
 * Returns:
 *   The text with a capital first letter.
 */
private string capitalize(string text) @safe pure nothrow {
    return text.length > 0 && text[0] >= 'a' && text[0] <= 'z'
        ? cast(char) (text[0] - ('a' - 'A')) ~ text[1 .. $] : text;
}

/**
 * A hex digit in lower case.
 *
 * Params:
 *   value = 0 to 15.
 *
 * Returns:
 *   The digit.
 */
private char hexDigit(ubyte value) @safe pure nothrow @nogc {
    return value < 10 ? cast(char) ('0' + value) : cast(char) ('a' + value - 10);
}

version (ComposeProgram) {

/**
 * The entry point of dracker-compose: runs the command line with the real files and the terminal.
 *
 * Params:
 *   args = The command line; args[0] is the program.
 *
 * Returns:
 *   The exit code: 0, 1 or 2.
 */
int main(string[] args) {
    return runProgram(args[1 .. $], realProgramIo());
}

}
