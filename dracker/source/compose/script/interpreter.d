/**
 * File:         source/compose/script/interpreter.d
 * Module:       compose.script.interpreter
 * Phase:        Composition helper (dracker-compose) — T83 (Script language interpreter core)
 *
 * Purpose:
 *   Executes lexed composition script commands one at a time against a stateful ProjectWriter using a
 *   declarative command table with typed positional argument specs and named option specs (reused by T85's
 *   script catalog). Returns structured ScriptProblem data with 1-based line, column, span length, reason
 *   and nearest valid name or value. Never prints to stdout/stderr, providing a clean seam for both the CLI
 *   and the app's script tab (T112).
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Everything is @safe nothrow; no console I/O.
 *
 * Dependencies:
 *   Internal: compose.names (namesMatch, nearestName), compose.project_writer (ProjectProblem,
 *             ProjectProblemKind, ProjectWriter), compose.script.lexer (CommandLine, LexError, LexResult,
 *             lexLine, lexScript, Token, TokenKind)
 *   External: std.path (buildPath, isAbsolute)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum ArgKind; struct CommandArgSpec; struct CommandOptionSpec; struct CommandSpec
 *   - struct ParsedCommand; struct ScriptProblem; struct StepResult; struct RunResult
 *   - alias CommandHandler
 *   - final class ScriptInterpreter: project(), checkOnly(), setCheckOnly(), savedPaths(),
 *     recordSavedPath(), registerCommand(), commandTable(), hasCommand(), runCommand(), runLine(),
 *     runScript(), fromProjectProblem(), setBaseDirectory(), baseDirectory(), resolvePath()
 *
 * See_Also:
 *   docs/todo.md (T67, T83, T85, T112), source/compose/script/lexer.d, source/compose/script/commands.d
 */
module compose.script.interpreter;

import app.instrument_library : bundledPresetDirectories, defaultUserInstrumentDirectory, InstrumentLibrary;
import compose.drum_writer : DrumWriter;
import compose.module_writer : ModuleProblem, ModuleProblemKind;
import compose.names : namesMatch, nearestName;
import compose.part_writer : OpenedPatternMapping, PartOpenResult, PartProblem, PartProblemKind, PartWriter;
import compose.project_writer : LoadedModuleHandle, ProjectDocumentResult, ProjectOpenResult, ProjectProblem,
    ProjectProblemKind, ProjectWriter;
import compose.script.lexer : CommandLine, LexError, LexResult, lexLine, lexScript, Token, TokenKind;
import io.project_format : LoadedProject;
import std.path : buildPath, isAbsolute;

/** Semantic kind of a positional argument or named option in the command table. */
enum ArgKind : ubyte {
    text = 0,
    word = 1,
    number = 2,
    integer = 3,
    path = 4,
    key = 5,
    timeSignature = 6
}

/**
 * Specification of one positional argument accepted by a script command.
 */
struct CommandArgSpec {
    string name = "";
    ArgKind kind = ArgKind.text;
    bool required = true;
    string summary = "";
}

/**
 * Specification of one named option (name=value) accepted by a script command.
 */
struct CommandOptionSpec {
    string name = "";
    ArgKind kind = ArgKind.text;
    string summary = "";
}

/**
 * Metadata describing one registered script command, used for validation and catalog/help output.
 */
struct CommandSpec {
    string name = "";
    string summary = "";
    CommandArgSpec[] args;
    CommandOptionSpec[] options;
    bool allowAnyOptions = false;
    bool variadicArgs = false;
    bool acceptsColonTail = false;
}

/**
 * One validated command invocation split into canonical name, positional args, and named options.
 */
struct ParsedCommand {
    uint line = 1;
    string name = "";
    Token commandToken;
    Token[] args;
    Token[] options;
    bool hasColon = false;
    uint colonLine = 1;
    uint colonColumn = 1;
    Token[] tailTokens;

    /**
     * Reports whether a named option was supplied (matched without regard to case or spaces).
     *
     * Params:
     *   optName = Option name to check.
     *
     * Returns:
     *   True when present.
     */
    bool hasOption(string optName) const @safe pure nothrow {
        foreach (ref opt; options) {
            if (namesMatch(opt.optionName, optName)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Retrieves a named option's token (matched without regard to case or spaces).
     *
     * Params:
     *   optName = Option name to retrieve.
     *   tok = Receives the matching Token when found.
     *
     * Returns:
     *   True when found.
     */
    bool optionToken(string optName, out Token tok) const @safe pure nothrow {
        foreach (ref opt; options) {
            if (namesMatch(opt.optionName, optName)) {
                tok = opt;
                return true;
            }
        }
        return false;
    }
}

/**
 * Structured diagnostic returned by the script interpreter as data.
 */
struct ScriptProblem {
    uint line = 1;
    uint column = 1;
    uint length = 1;
    string reason = "";
    string suggestion = "";
    bool isNameSuggestion = false;

    /**
     * Formats the problem as one human-readable line with location and suggestion when available.
     *
     * Returns:
     *   "line <L>, col <C>: <reason>" plus suggestion suffix when present.
     */
    string text() const @safe pure nothrow {
        string result = "line " ~ wholeText(line) ~ ", col " ~ wholeText(column) ~ ": " ~ reason;
        if (suggestion.length > 0) {
            result ~= isNameSuggestion ? "; did you mean '" ~ suggestion ~ "'?"
                : "; the nearest valid value is " ~ suggestion;
        }
        return result;
    }
}

/**
 * Result of executing one command or line.
 */
struct StepResult {
    bool ok = false;
    ScriptProblem problem = ScriptProblem.init;
}

/**
 * Result of running an entire multi-line script.
 */
struct RunResult {
    bool ok = true;
    size_t commandsRun = 0;
    ScriptProblem[] problems;
}

/** Handler callback delegate invoked for a validated command. */
alias CommandHandler = StepResult delegate(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow;

/** Plain function-pointer handler callback invoked for a validated command. */
alias CommandHandlerFn = StepResult function(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow;

/**
 * Internal table entry pairing a CommandSpec with its handler.
 */
private struct RegisteredCommand {
    CommandSpec spec;
    CommandHandler handler;
}

/**
 * Formats an unsigned integer in decimal.
 *
 * Params:
 *   value = Non-negative integer.
 *
 * Returns:
 *   Decimal string.
 */
private string wholeText(ulong value) @safe pure nothrow {
    char[] digits;
    do {
        digits ~= cast(char)('0' + (value % 10));
        value /= 10;
    } while (value > 0);
    char[] text = new char[digits.length];
    foreach (i; 0 .. digits.length) {
        text[i] = digits[digits.length - 1 - i];
    }
    return text.idup;
}

/**
 * Reports whether a ProjectProblemKind suggests a name rather than a numeric value.
 *
 * Params:
 *   kind = Project problem kind.
 *
 * Returns:
 *   True for handle, name, and port lookup problems.
 */
private bool isProjectNameSuggestion(ProjectProblemKind kind) @safe pure nothrow @nogc {
    return kind == ProjectProblemKind.invalidHandle || kind == ProjectProblemKind.duplicateHandle
        || kind == ProjectProblemKind.unknownHandle || kind == ProjectProblemKind.protectedModule
        || kind == ProjectProblemKind.invalidName || kind == ProjectProblemKind.unknownPort
        || kind == ProjectProblemKind.invalidPortDirection;
}

private bool isModuleNameSuggestion(ModuleProblemKind kind) @safe pure nothrow @nogc {
    final switch (kind) {
        case ModuleProblemKind.unknownModuleType:
        case ModuleProblemKind.unknownPreset:
        case ModuleProblemKind.ambiguousPreset:
        case ModuleProblemKind.unknownParameter:
        case ModuleProblemKind.ambiguousParameter:
        case ModuleProblemKind.unknownOption:
        case ModuleProblemKind.invalidName:
            return true;
        case ModuleProblemKind.unreadablePreset:
        case ModuleProblemKind.mismatchedPreset:
        case ModuleProblemKind.notANumber:
        case ModuleProblemKind.outOfRange:
        case ModuleProblemKind.notAWholeNumber:
        case ModuleProblemKind.notLoaded:
        case ModuleProblemKind.writeFailed:
        case ModuleProblemKind.notASampler:
        case ModuleProblemKind.unreadableSample:
        case ModuleProblemKind.sampleTooLarge:
            return false;
    }
}

private bool isPartNameSuggestion(PartProblemKind kind) @safe pure nothrow @nogc {
    return kind == PartProblemKind.invalidName || kind == PartProblemKind.duplicateSection
        || kind == PartProblemKind.unknownSection || kind == PartProblemKind.duplicatePart
        || kind == PartProblemKind.unknownPart || kind == PartProblemKind.unknownModule
        || kind == PartProblemKind.invalidArrangement || kind == PartProblemKind.unknownPattern;
}

private size_t findColonChar(string text) @safe pure nothrow @nogc {
    foreach (i, char c; text) {
        if (c == ':') {
            return i;
        }
    }
    return text.length;
}

/**
 * Stateful composition script interpreter executing one command at a time against a ProjectWriter,
 * PartWriter, and DrumWriter.
 *
 * Never prints or reads stdin; callers feed lines, commands, or full scripts and inspect returned
 * StepResult / RunResult values.
 */
final class ScriptInterpreter {
    private ProjectWriter project_;
    private PartWriter parts_;
    private DrumWriter drums_;
    private bool checkOnly_ = false;
    private string[] savedPaths_;
    private ubyte[][string] virtualPresets_;
    private string baseDirectory_;
    private bool relativePathsAllowed_ = true;
    private RegisteredCommand[] commands_;
    private InstrumentLibrary library_;
    private size_t executedCommands_ = 0;
    private bool startedFromDocument_ = false;
    private LoadedModuleHandle[] openedModules_;
    private OpenedPatternMapping[] openedPatterns_;

    /**
     * Constructs an interpreter with an optional ProjectWriter and check-only mode.
     *
     * Params:
     *   project = Existing ProjectWriter to mutate, or null to start a fresh one.
     *   checkOnly = When true, commands like save validate without writing files to disk.
     */
    this(ProjectWriter project = null, bool checkOnly = false) @safe nothrow {
        project_ = project !is null ? project : new ProjectWriter();
        parts_ = new PartWriter(project_);
        drums_ = new DrumWriter(parts_);
        checkOnly_ = checkOnly;
    }

    /**
     * Returns the ProjectWriter owned or mutated by this interpreter.
     *
     * Returns:
     *   The active ProjectWriter.
     */
    ProjectWriter project() @safe nothrow {
        return project_;
    }

    /**
     * Returns the PartWriter tracking sections, melodic parts, raw patterns, and arrangement.
     *
     * Returns:
     *   The active PartWriter.
     */
    PartWriter parts() @safe nothrow {
        return parts_;
    }

    /**
     * Returns the DrumWriter attached to parts().
     *
     * Returns:
     *   The active DrumWriter.
     */
    DrumWriter drums() @safe nothrow {
        return drums_;
    }

    /**
     * Returns how many non-empty commands have completed successfully in this interpreter session.
     *
     * Returns:
     *   Executed command count.
     */
    size_t executedCommands() const @safe nothrow {
        return executedCommands_;
    }

    /**
     * Reports whether the interpreter was started from an opened .msv file or in-memory document.
     *
     * Returns:
     *   True after open or loadFromDocument().
     */
    bool startedFromDocument() const @safe nothrow {
        return startedFromDocument_;
    }

    /**
     * Returns module handles derived when opening an existing file or document.
     *
     * Returns:
     *   Slice of LoadedModuleHandle records.
     */
    const(LoadedModuleHandle)[] openedModules() const @safe nothrow {
        return openedModules_;
    }

    /**
     * Returns pattern-to-part/section mappings derived when opening an existing file or document.
     *
     * Returns:
     *   Slice of OpenedPatternMapping records.
     */
    const(OpenedPatternMapping)[] openedPatterns() const @safe nothrow {
        return openedPatterns_;
    }

    /**
     * Builds the unified LoadedProject document across properties, modules, wires, melodic/raw
     * patterns, drum patterns, timeline clips, and loop range.
     *
     * Returns:
     *   ProjectDocumentResult validated by validateProjectForSave().
     */
    ProjectDocumentResult buildDocument() const @safe nothrow {
        return drums_.buildDocument();
    }

    /**
     * Installs an opened ProjectOpenResult into this interpreter, reconstructing parts, sections,
     * drum parts, and arrangement from any preserved base document (T100 / T103).
     *
     * Params:
     *   projOpen = Result from ProjectWriter.fromFile / fromLoadedProject.
     *   problem = Receives ScriptProblem on failure.
     *   anchor = Token where any diagnostic should point.
     *
     * Returns:
     *   True when installed cleanly.
     */
    bool installOpenedProject(ProjectOpenResult projOpen, out ScriptProblem problem, const ref Token anchor)
            @safe nothrow {
        if (!projOpen.ok) {
            problem = fromProjectProblem(projOpen.problem, anchor);
            return false;
        }
        PartOpenResult pOpen = PartWriter.openFromProject(projOpen.writer);
        if (!pOpen.ok) {
            problem = fromPartProblem(pOpen.problem, anchor);
            return false;
        }
        project_ = projOpen.writer;
        parts_ = pOpen.parts;
        drums_ = pOpen.drums;
        openedModules_ = projOpen.handles;
        openedPatterns_ = pOpen.patterns;
        startedFromDocument_ = true;
        return true;
    }

    /**
     * Initializes the interpreter state from an in-memory LoadedProject document (T103 / T113).
     *
     * Params:
     *   doc = LoadedProject copy or snapshot to edit.
     *   problem = Receives ScriptProblem on failure.
     *
     * Returns:
     *   True when initialized cleanly.
     */
    bool loadFromDocument(const ref LoadedProject doc, out ScriptProblem problem) @safe nothrow {
        ProjectOpenResult projOpen = ProjectWriter.fromLoadedProject(doc);
        immutable Token anchor = Token(TokenKind.word, "open", "", "", false, 1, 1, 4);
        return installOpenedProject(projOpen, problem, anchor);
    }

    /**
     * Reports whether check-only mode is active (validate without writing output files).
     *
     * Returns:
     *   True in check-only mode.
     */
    bool checkOnly() const @safe nothrow {
        return checkOnly_;
    }

    /**
     * Enables or disables check-only mode.
     *
     * Params:
     *   value = True to validate without writing files to disk.
     */
    void setCheckOnly(bool value) @safe nothrow {
        checkOnly_ = value;
    }

    /**
     * Returns all paths passed to successful save commands in order.
     *
     * Returns:
     *   Slice of saved paths.
     */
    const(string)[] savedPaths() const @safe nothrow {
        return savedPaths_;
    }

    /**
     * Records a successfully validated or written output path.
     *
     * Params:
     *   path = Output path recorded by a save command.
     */
    void recordSavedPath(string path) @safe nothrow {
        savedPaths_ ~= path;
    }

    /**
     * Sets the folder that relative file paths in commands are read from and written to (the app's Script tab
     * uses the open project's folder, T109). An empty folder keeps paths as written (relative to the working
     * directory, as on the command line).
     *
     * Params:
     *   directory = Absolute folder, or "" for paths as written.
     *   relativeAllowed = False refuses relative paths (the app's Script tab before the project is saved).
     */
    void setBaseDirectory(string directory, bool relativeAllowed = true) @safe nothrow {
        baseDirectory_ = directory;
        relativePathsAllowed_ = relativeAllowed;
    }

    /**
     * Returns the folder relative file paths are resolved against.
     *
     * Returns:
     *   The folder, or "" when paths are used as written.
     */
    string baseDirectory() const @safe nothrow {
        return baseDirectory_;
    }

    /**
     * Resolves a file path written in a command against baseDirectory().
     *
     * Params:
     *   path = The path as written (already without surrounding spaces).
     *   resolved = Receives the path to use: unchanged when absolute or when no folder is set, else the path
     *     inside the folder.
     *
     * Returns:
     *   False when the path is relative and relative paths are refused (setBaseDirectory).
     */
    bool resolvePath(string path, out string resolved) const @safe nothrow {
        resolved = path;
        if (path.length == 0 || isAbsolute(path)) {
            return true;
        }
        if (!relativePathsAllowed_) {
            return false;
        }
        if (baseDirectory_.length > 0) {
            resolved = buildPath(baseDirectory_, path);
        }
        return true;
    }

    /**
     * Caches serialized .msym preset bytes for in-script checkOnly dry-run reloads.
     *
     * Params:
     *   path = Preset path passed to savemodule.
     *   bytes = Serialized .msym payload.
     */
    void cacheVirtualPreset(string path, const(ubyte)[] bytes) @safe nothrow {
        virtualPresets_[path] = bytes.dup;
    }

    /**
     * Looks up a virtual preset cached during checkOnly dry-run validation.
     *
     * Params:
     *   path = Preset path requested by module file= or preset file=.
     *   bytes = Receives cached bytes when found.
     *
     * Returns:
     *   True when a virtual preset is cached for path.
     */
    bool findVirtualPreset(string path, out const(ubyte)[] bytes) const @safe nothrow {
        const(ubyte[])* found = path in virtualPresets_;
        if (found is null) {
            bytes = null;
            return false;
        }
        bytes = *found;
        return true;
    }

    /**
     * Returns the InstrumentLibrary used by module/preset commands, scanning bundled and user preset
     * directories lazily on first access.
     *
     * Returns:
     *   Active InstrumentLibrary.
     */
    InstrumentLibrary library() @trusted nothrow {
        if (library_ is null) {
            try {
                library_ = new InstrumentLibrary(bundledPresetDirectories(), defaultUserInstrumentDirectory());
            } catch (Throwable) {
                library_ = null;
            }
        }
        return library_;
    }

    /**
     * Overrides the InstrumentLibrary used for preset resolution (useful in tests).
     *
     * Params:
     *   lib = InstrumentLibrary instance.
     */
    void setLibrary(InstrumentLibrary lib) @safe nothrow {
        library_ = lib;
    }

    /**
     * Registers or replaces a command in the interpreter's command table.
     *
     * Params:
     *   spec = Command specification (name, summary, args, options).
     *   handler = Callback executed when the command is invoked.
     */
    void registerCommand(CommandSpec spec, CommandHandler handler) @safe nothrow {
        foreach (ref entry; commands_) {
            if (namesMatch(entry.spec.name, spec.name)) {
                entry.spec = spec;
                entry.handler = handler;
                return;
            }
        }
        commands_ ~= RegisteredCommand(spec, handler);
    }

    /**
     * Registers or replaces a command using a plain function pointer handler.
     *
     * Params:
     *   spec = Command specification (name, summary, args, options).
     *   handler = Function pointer executed when the command is invoked.
     */
    void registerCommand(CommandSpec spec, CommandHandlerFn handler) @safe nothrow {
        registerCommand(spec, (ScriptInterpreter i, const ref ParsedCommand c) @safe nothrow {
            return handler(i, c);
        });
    }

    /**
     * Returns the registered command specifications in registration order.
     *
     * Returns:
     *   Array of const CommandSpec entries.
     */
    const(CommandSpec)[] commandTable() const @safe nothrow {
        const(CommandSpec)[] table;
        table.reserve(commands_.length);
        foreach (ref entry; commands_) {
            table ~= entry.spec;
        }
        return table;
    }

    /**
     * Reports whether a command is registered (matched case/space-insensitively).
     *
     * Params:
     *   name = Command name.
     *
     * Returns:
     *   True when registered.
     */
    bool hasCommand(string name) const @safe nothrow {
        return indexOfCommand(name) != commands_.length;
    }

    /**
     * Executes one lexed CommandLine against the current interpreter state.
     *
     * Params:
     *   cmdLine = Lexed logical command line.
     *
     * Returns:
     *   StepResult indicating success or a structured ScriptProblem.
     */
    StepResult runCommand(const ref CommandLine cmdLine) @safe nothrow {
        if (cmdLine.tokens.length == 0) {
            return StepResult(true);
        }
        immutable Token head = cmdLine.tokens[0];
        if (head.kind != TokenKind.word) {
            return StepResult(false, ScriptProblem(head.line, head.column, head.length,
                "a command line must start with a command word", "", false));
        }

        immutable size_t idx = indexOfCommand(head.text);
        if (idx == commands_.length) {
            immutable string nearest = nearestName(head.text, commandNames());
            return StepResult(false, ScriptProblem(head.line, head.column, head.length,
                "unknown command '" ~ head.text ~ "'", nearest, true));
        }

        auto entry = &commands_[idx];
        Token[] headerTokens;
        Token[] tailTokens;
        bool hasColon = false;
        uint colonLine = head.line;
        uint colonColumn = head.column;

        if (entry.spec.acceptsColonTail) {
            bool inTail = false;
            foreach (tok; cmdLine.tokens[1 .. $]) {
                if (inTail) {
                    tailTokens ~= tok;
                    continue;
                }
                if (tok.kind == TokenKind.word) {
                    immutable size_t cIdx = findColonChar(tok.text);
                    if (cIdx < tok.text.length) {
                        hasColon = true;
                        colonLine = tok.line;
                        colonColumn = tok.column + cast(uint) cIdx;
                        if (cIdx > 0) {
                            headerTokens ~= Token(TokenKind.word, tok.text[0 .. cIdx], "", "", false,
                                tok.line, tok.column, cast(uint) cIdx);
                        }
                        if (cIdx + 1 < tok.text.length) {
                            tailTokens ~= Token(TokenKind.word, tok.text[cIdx + 1 .. $], "", "", false,
                                tok.line, tok.column + cast(uint)(cIdx + 1),
                                cast(uint)(tok.text.length - cIdx - 1));
                        }
                        inTail = true;
                        continue;
                    }
                } else if (tok.kind == TokenKind.option && !tok.valueQuoted) {
                    immutable size_t cIdx = findColonChar(tok.optionValue);
                    if (cIdx < tok.optionValue.length) {
                        immutable string beforeColon = tok.optionValue[0 .. cIdx];
                        immutable uint colonOffsetInTok = cast(uint)(tok.optionName.length + 1 + cIdx);
                        if (beforeColon.length == 0) {
                            return StepResult(false, ScriptProblem(tok.line, tok.column, colonOffsetInTok,
                                "option '" ~ tok.optionName ~ "' is missing a value before ':'", "", false));
                        }
                        hasColon = true;
                        colonLine = tok.line;
                        colonColumn = tok.column + colonOffsetInTok;
                        headerTokens ~= Token(TokenKind.option, tok.optionName ~ "=" ~ beforeColon,
                            tok.optionName, beforeColon, false, tok.line, tok.column, colonOffsetInTok);
                        immutable string afterColon = tok.optionValue[cIdx + 1 .. $];
                        if (afterColon.length > 0) {
                            tailTokens ~= Token(TokenKind.word, afterColon, "", "", false,
                                tok.line, tok.column + colonOffsetInTok + 1, cast(uint) afterColon.length);
                        }
                        inTail = true;
                        continue;
                    }
                }
                headerTokens ~= tok;
            }
        } else {
            headerTokens = cmdLine.tokens[1 .. $].dup;
        }

        Token[] args;
        Token[] opts;
        string[] optNames;
        foreach (ref specOpt; entry.spec.options) {
            optNames ~= specOpt.name;
        }

        foreach (tok; headerTokens) {
            if (tok.kind == TokenKind.option) {
                bool knownOpt = false;
                foreach (ref specOpt; entry.spec.options) {
                    if (namesMatch(specOpt.name, tok.optionName)) {
                        knownOpt = true;
                        break;
                    }
                }
                if (!knownOpt && !entry.spec.allowAnyOptions) {
                    immutable string nearestOpt = nearestName(tok.optionName, optNames);
                    return StepResult(false, ScriptProblem(tok.line, tok.column, tok.length,
                        "command '" ~ entry.spec.name ~ "' does not accept option '" ~ tok.optionName ~ "'",
                        nearestOpt, true));
                }
                foreach (existing; opts) {
                    if (namesMatch(existing.optionName, tok.optionName)) {
                        return StepResult(false, ScriptProblem(tok.line, tok.column, tok.length,
                            "option '" ~ tok.optionName ~ "' was given more than once", "", false));
                    }
                }
                opts ~= tok;
            } else {
                args ~= tok;
            }
        }

        size_t minArgs = 0;
        foreach (ref a; entry.spec.args) {
            if (a.required) {
                minArgs++;
            }
        }
        immutable size_t maxArgs = entry.spec.args.length;

        if (args.length < minArgs) {
            immutable string missingName = entry.spec.args[args.length].name;
            return StepResult(false, ScriptProblem(head.line, head.column, head.length,
                "command '" ~ entry.spec.name ~ "' requires argument '" ~ missingName ~ "'", "", false));
        }
        if (!entry.spec.variadicArgs && args.length > maxArgs) {
            immutable Token extra = args[maxArgs];
            return StepResult(false, ScriptProblem(extra.line, extra.column, extra.length,
                "command '" ~ entry.spec.name ~ "' takes at most " ~ wholeText(maxArgs)
                ~ (maxArgs == 1 ? " argument" : " arguments"), "", false));
        }

        ParsedCommand parsed;
        parsed.line = cmdLine.line;
        parsed.name = entry.spec.name;
        parsed.commandToken = head;
        parsed.args = args;
        parsed.options = opts;
        parsed.hasColon = hasColon;
        parsed.colonLine = colonLine;
        parsed.colonColumn = colonColumn;
        parsed.tailTokens = tailTokens;
        immutable StepResult res = entry.handler(this, parsed);
        if (res.ok) {
            executedCommands_++;
        }
        return res;
    }

    /**
     * Lexes and executes a single line of script text.
     *
     * Params:
     *   lineText = One line of script text.
     *   lineNumber = 1-based physical line number for diagnostics.
     *
     * Returns:
     *   StepResult indicating success or the first lex/execution problem.
     */
    StepResult runLine(string lineText, uint lineNumber = 1) @safe nothrow {
        immutable LexResult lex = lexLine(lineText, lineNumber);
        if (!lex.ok) {
            return StepResult(false, fromLexError(lex.errors[0]));
        }
        if (lex.commands.length == 0) {
            return StepResult(true);
        }
        return runCommand(lex.commands[0]);
    }

    /**
     * Lexes and executes a complete multi-line script.
     *
     * Stops at the first lex phase failure or first command failure so the project state stays consistent.
     *
     * Params:
     *   source = Full script source text.
     *
     * Returns:
     *   RunResult with ok flag, commandsRun count, and any ScriptProblems.
     */
    RunResult runScript(string source) @safe nothrow {
        RunResult result;
        immutable LexResult lex = lexScript(source);
        if (!lex.ok) {
            result.ok = false;
            foreach (ref err; lex.errors) {
                result.problems ~= fromLexError(err);
            }
            return result;
        }
        foreach (ref cmd; lex.commands) {
            immutable StepResult step = runCommand(cmd);
            if (!step.ok) {
                result.ok = false;
                result.problems ~= step.problem;
                return result;
            }
            result.commandsRun++;
        }
        return result;
    }

    /**
     * Converts a ProjectProblem into a ScriptProblem anchored at a source token.
     *
     * Params:
     *   prob = Problem returned by ProjectWriter.
     *   tok = Token responsible for the invalid value.
     *
     * Returns:
     *   ScriptProblem with location from tok and diagnostics from prob.
     */
    static ScriptProblem fromProjectProblem(const ref ProjectProblem prob, const ref Token tok)
            @safe pure nothrow {
        return ScriptProblem(tok.line, tok.column, tok.length, prob.reason, prob.suggestion,
            isProjectNameSuggestion(prob.kind));
    }

    /**
     * Converts a ModuleProblem into a ScriptProblem anchored at a source token.
     *
     * Params:
     *   prob = Problem returned by ModuleWriter.
     *   tok = Token responsible for the invalid value or option.
     *
     * Returns:
     *   ScriptProblem with location from tok and diagnostics from prob.
     */
    static ScriptProblem fromModuleProblem(const ref ModuleProblem prob, const ref Token tok)
            @safe pure nothrow {
        return ScriptProblem(tok.line, tok.column, tok.length, prob.reason, prob.suggestion,
            isModuleNameSuggestion(prob.kind));
    }

    /**
     * Converts a PartProblem into a ScriptProblem anchored at a source token.
     *
     * Params:
     *   prob = Problem returned by PartWriter.
     *   tok = Token responsible for the invalid name or value.
     *
     * Returns:
     *   ScriptProblem with location from tok and diagnostics from prob.
     */
    static ScriptProblem fromPartProblem(const ref PartProblem prob, const ref Token tok)
            @safe pure nothrow {
        return ScriptProblem(tok.line, tok.column, tok.length, prob.reason, prob.suggestion,
            isPartNameSuggestion(prob.kind));
    }

    /**
     * Converts a LexError into a ScriptProblem.
     *
     * Params:
     *   err = Lexer error.
     *
     * Returns:
     *   ScriptProblem with identical coordinates and reason.
     */
    private static ScriptProblem fromLexError(const ref LexError err) @safe pure nothrow {
        return ScriptProblem(err.line, err.column, err.length > 0 ? err.length : 1, err.reason, "", false);
    }

    /**
     * Finds a registered command by name without regard to case or spaces.
     *
     * Params:
     *   name = Command name.
     *
     * Returns:
     *   Index into commands_, or commands_.length when not found.
     */
    private size_t indexOfCommand(string name) const @safe nothrow {
        foreach (i; 0 .. commands_.length) {
            if (namesMatch(commands_[i].spec.name, name)) {
                return i;
            }
        }
        return commands_.length;
    }

    /**
     * Lists all registered command names in registration order.
     *
     * Returns:
     *   Array of command names.
     */
    private string[] commandNames() const @safe nothrow {
        string[] names;
        names.reserve(commands_.length);
        foreach (ref entry; commands_) {
            names ~= entry.spec.name;
        }
        return names;
    }
}
