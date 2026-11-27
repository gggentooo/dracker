/**
 * File:         source/compose/script/commands.d
 * Module:       compose.script.commands
 * Phase:        Composition helper (dracker-compose) — T83 & T101 (Script commands)
 *
 * Purpose:
 *   Registers the composition script commands onto a ScriptInterpreter per decision T67:
 *   project properties (project, tempo, signature, key, save) and module/wire management
 *   (module, set, preset, sample, savemodule, connect, disconnect, remove). Parses typed numeric,
 *   signature, pitch, and key arguments without throwing exceptions, validates options atomically before
 *   mutating ProjectWriter, preserves ModuleWriter/ProjectWriter error reasons and suggestions with exact
 *   source line/column coordinates, and respects checkOnly mode on save and savemodule.
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Everything is @safe nothrow; no console I/O.
 *
 * Dependencies:
 *   Internal: compose.module_writer (ModuleBytesResult, ModuleEditResult, ModuleWriter,
 *             ModuleWriterResult), compose.names (trim), compose.project_writer (parseKey,
 *             ProjectBytesResult, ProjectEditResult, ProjectIdResult, ProjectKeyResult,
 *             ProjectModuleResult, ProjectProblemKind, ProjectWriter), compose.script.interpreter
 *             (ArgKind, CommandArgSpec, CommandOptionSpec, CommandSpec, ParsedCommand,
 *             ScriptInterpreter, ScriptProblem, StepResult), compose.script.lexer (Token),
 *             compose.script.notation (parsePitch, PitchResult), compose.timing (defaultTimeSignature,
 *             formatTimeSignature, parseTimeSignature, TimeSignatureResult)
 *   External: std.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - registerCoreCommands()
 *   - createDefaultInterpreter(); createInterpreterFromDocument(); restrictForApp(); APP_REFUSED_COMMANDS
 *
 * See_Also:
 *   docs/todo.md (T67, T75, T83, T96, T101), source/compose/script/interpreter.d,
 *   source/compose/project_writer.d, source/compose/module_writer.d
 */
module compose.script.commands;

import std.math : isFinite;

import compose.chord_writer : ArpDirection, ChordOptions, ChordProblem, ChordProblemKind, ChordStyle,
    ChordVoicing, ChordWriteResult, parseArpDirection, parseChordStyle, parseChordVoicing, writeChords,
    writePresetChords;
import compose.drum_writer : DrumEditResult, DrumProblemKind;
import compose.module_writer : ModuleBytesResult, ModuleEditResult, ModuleWriter, ModuleWriterResult;
import compose.names : namesMatch, nearestName, trim;
import compose.part_writer : PartEditResult, PartPatternResult, PartProblem, PartProblemKind, PartResult,
    SectionResult;
import compose.project_writer : parseKey, ProjectBytesResult, ProjectDocumentResult, ProjectEditResult, ProjectIdResult,
    ProjectKeyResult, ProjectModuleResult, ProjectOpenResult, ProjectProblem, ProjectProblemKind,
    ProjectWriter;
import compose.script.interpreter : ArgKind, CommandArgSpec, CommandOptionSpec, CommandSpec, ParsedCommand,
    ScriptInterpreter, ScriptProblem, StepResult;
import compose.script.lexer : Token, TokenKind;
import compose.script.notation : NotationError, NotationResult, parseNotes, parsePitch, PitchResult;
import compose.timing : BeatPosition, defaultTimeSignature, formatPosition, formatTimeSignature,
    Length, LengthResult, linesPerBar, lineToPosition, parseLength, parsePosition,
    parseTimeSignature, PositionResult, positionToLine, TimeSignature, TimeSignatureResult;
import io.project_format : LoadedProject;
import sequencer.note : EffectCode, NoteCell, NoteCmd;

/**
 * Outcome of constructing a ScriptInterpreter seeded from an in-memory LoadedProject document.
 */
struct ScriptOpenResult {
    ScriptInterpreter interpreter = null;
    bool ok = false;
    ScriptProblem problem = ScriptProblem.init;
}

/**
 * Parses a decimal floating-point number (optional leading +/-, digits, optional fractional part).
 *
 * Params:
 *   text = Input text.
 *   value = Receives parsed finite double when true is returned.
 *
 * Returns:
 *   True when the text is a valid finite decimal number.
 */
private bool parseDecimal(string text, out double value) @safe pure nothrow @nogc {
    immutable string s = trim(text);
    if (s.length == 0) {
        return false;
    }
    size_t i = 0;
    double sign = 1.0;
    if (s[i] == '-') {
        sign = -1.0;
        i++;
    } else if (s[i] == '+') {
        i++;
    }
    double whole = 0.0;
    size_t digits = 0;
    while (i < s.length && s[i] >= '0' && s[i] <= '9') {
        whole = whole * 10.0 + cast(double)(s[i] - '0');
        digits++;
        i++;
    }
    double frac = 0.0;
    double scale = 0.1;
    if (i < s.length && s[i] == '.') {
        i++;
        while (i < s.length && s[i] >= '0' && s[i] <= '9') {
            frac += cast(double)(s[i] - '0') * scale;
            scale *= 0.1;
            digits++;
            i++;
        }
    }
    if (digits == 0) {
        return false;
    }
    double result = sign * (whole + frac);
    if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
        i++;
        bool negExp = false;
        if (i < s.length && (s[i] == '-' || s[i] == '+')) {
            negExp = s[i] == '-';
            i++;
        }
        int exp = 0;
        size_t expDigits = 0;
        while (i < s.length && s[i] >= '0' && s[i] <= '9') {
            if (exp < 1000) {
                exp = exp * 10 + (s[i] - '0');
            }
            expDigits++;
            i++;
        }
        if (expDigits == 0) {
            return false;
        }
        if (negExp) {
            foreach (_; 0 .. exp) {
                result /= 10.0;
            }
        } else {
            foreach (_; 0 .. exp) {
                result *= 10.0;
            }
        }
    }
    if (i != s.length) {
        return false;
    }
    if (!isFinite(result)) {
        return false;
    }
    value = result;
    return true;
}

/**
 * Parses a non-negative base-10 integer into uint without overflow.
 *
 * Params:
 *   text = Input text.
 *   value = Receives parsed uint when true is returned.
 *
 * Returns:
 *   True when the text is a valid unsigned decimal integer fitting in uint.
 */
private bool parseUint(string text, out uint value) @safe pure nothrow @nogc {
    immutable string s = trim(text);
    if (s.length == 0) {
        return false;
    }
    ulong acc = 0;
    foreach (c; s) {
        if (c < '0' || c > '9') {
            return false;
        }
        acc = acc * 10 + cast(ulong)(c - '0');
        if (acc > uint.max) {
            return false;
        }
    }
    value = cast(uint) acc;
    return true;
}

/**
 * Handles: project <title> and title <title>
 *
 * Params:
 *   interp = Active script interpreter.
 *   cmd = Parsed command tokens.
 *
 * Returns:
 *   StepResult.
 */
private StepResult handleProject(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token titleTok = cmd.args[0];
    immutable ProjectEditResult res = interp.project().setTitle(titleTok.text);
    if (!res.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(res.problem, titleTok));
    }
    return StepResult(true);
}

/**
 * Handles: tempo <bpm> [tpl=<ticks>]
 *
 * Validates both bpm and tpl before mutating the project so an invalid option leaves tempo untouched.
 *
 * Params:
 *   interp = Active script interpreter.
 *   cmd = Parsed command tokens.
 *
 * Returns:
 *   StepResult.
 */
private StepResult handleTempo(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token bpmTok = cmd.args[0];
    double bpm = 0.0;
    if (!parseDecimal(bpmTok.text, bpm)) {
        return StepResult(false, ScriptProblem(bpmTok.line, bpmTok.column, bpmTok.length,
            "tempo must be a number in beats per minute", "125", false));
    }

    Token tplTok;
    immutable bool hasTpl = cmd.optionToken("tpl", tplTok);
    uint tpl = interp.project().ticksPerLine();
    if (hasTpl && !parseUint(tplTok.optionValue, tpl)) {
        return StepResult(false, ScriptProblem(tplTok.line, tplTok.column, tplTok.length,
            "option 'tpl' must be a whole number from 1 to 255", "6", false));
    }

    immutable double prevBpm = interp.project().tempo();
    immutable ProjectEditResult bpmRes = interp.project().setTempo(bpm);
    if (!bpmRes.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(bpmRes.problem, bpmTok));
    }
    if (hasTpl) {
        immutable ProjectEditResult tplRes = interp.project().setTicksPerLine(tpl);
        if (!tplRes.ok) {
            cast(void) interp.project().setTempo(prevBpm);
            return StepResult(false, ScriptInterpreter.fromProjectProblem(tplRes.problem, tplTok));
        }
    }
    return StepResult(true);
}

/**
 * Handles: signature <num/den>
 *
 * Params:
 *   interp = Active script interpreter.
 *   cmd = Parsed command tokens.
 *
 * Returns:
 *   StepResult.
 */
private StepResult handleSignature(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token sigTok = cmd.args[0];
    immutable TimeSignatureResult parsed = parseTimeSignature(sigTok.text);
    if (!parsed.ok) {
        immutable string sugg = parsed.error.suggestion.length > 0
            ? parsed.error.suggestion : formatTimeSignature(defaultTimeSignature());
        return StepResult(false, ScriptProblem(sigTok.line, sigTok.column, sigTok.length,
            parsed.error.reason, sugg, false));
    }
    immutable ProjectEditResult res = interp.project().setTimeSignature(parsed.signature);
    if (!res.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(res.problem, sigTok));
    }
    return StepResult(true);
}

/**
 * Handles: key <tonic> [major|minor] (also accepts a single quoted argument such as "A minor").
 *
 * Params:
 *   interp = Active script interpreter.
 *   cmd = Parsed command tokens.
 *
 * Returns:
 *   StepResult.
 */
private StepResult handleKey(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable string raw = cmd.args.length == 2
        ? (cmd.args[0].text ~ " " ~ cmd.args[1].text)
        : cmd.args[0].text;
    immutable ProjectKeyResult parsed = parseKey(raw);
    if (!parsed.ok) {
        immutable Token errTok = (cmd.args.length == 2 && parseKey(cmd.args[0].text).ok)
            ? cmd.args[1] : cmd.args[0];
        return StepResult(false, ScriptProblem(errTok.line, errTok.column, errTok.length,
            parsed.problem.reason, parsed.problem.suggestion, false));
    }
    immutable ProjectEditResult res = interp.project().setKey(parsed.key);
    if (!res.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(res.problem, cmd.args[0]));
    }
    return StepResult(true);
}

/**
 * Handles: save <path>
 *
 * In check-only mode, validates, serializes, and trial-activates the project without writing to disk.
 *
 * Params:
 *   interp = Active script interpreter.
 *   cmd = Parsed command tokens.
 *
 * Returns:
 *   StepResult.
 */
private StepResult handleSave(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token pathTok = cmd.args[0];
    if (trim(pathTok.text).length == 0) {
        return StepResult(false, ScriptProblem(pathTok.line, pathTok.column, pathTok.length,
            "save path cannot be empty", "", false));
    }
    ProjectDocumentResult doc = interp.buildDocument();
    if (!doc.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(doc.problem, pathTok));
    }
    if (interp.checkOnly()) {
        ProjectBytesResult bytes = interp.project().documentBytes(doc.project);
        if (!bytes.ok) {
            return StepResult(false, ScriptInterpreter.fromProjectProblem(bytes.problem, pathTok));
        }
        interp.recordSavedPath(pathTok.text);
        return StepResult(true);
    }
    immutable ProjectEditResult res = interp.project().writeDocument(doc.project, pathTok.text);
    if (!res.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(res.problem, pathTok));
    }
    interp.recordSavedPath(pathTok.text);
    return StepResult(true);
}

/**
 * Handles: open <path> (T103)
 */
private StepResult handleOpen(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token pathTok = cmd.args[0];
    if (interp.executedCommands() > 0 || interp.startedFromDocument()) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "'open' must be the first command in a script", "", false));
    }
    if (trim(pathTok.text).length == 0) {
        return StepResult(false, ScriptProblem(pathTok.line, pathTok.column, pathTok.length,
            "project file path cannot be empty", "", false));
    }
    ProjectOpenResult projOpen = ProjectWriter.fromFile(pathTok.text);
    ScriptProblem prob;
    if (!interp.installOpenedProject(projOpen, prob, pathTok)) {
        return StepResult(false, prob);
    }
    return StepResult(true);
}

/**
 * Parses a MIDI note number [0..127] from either decimal digits or a pitch spelling (e.g. "C4").
 *
 * Params:
 *   text = Text token value.
 *   midi = Receives MIDI note 0..127 when true is returned.
 *
 * Returns:
 *   True when valid.
 */
private bool parseMidiNoteOption(string text, out int midi) @safe pure nothrow {
    uint num = 0;
    if (parseUint(text, num)) {
        if (num <= 127) {
            midi = cast(int) num;
            return true;
        }
        return false;
    }
    immutable PitchResult pr = parsePitch(trim(text));
    if (pr.ok) {
        midi = cast(int) pr.midi;
        return true;
    }
    return false;
}

/**
 * Chooses the most specific Token for a ProjectWriter wire problem (connect/disconnect).
 */
private Token pickWireProblemToken(const ref ProjectProblem prob, const ref ParsedCommand cmd,
        Token srcTok, Token dstTok, bool hasGain, Token gainTok, bool hasFrom, Token fromTok,
        bool hasTo, Token toTok) @safe pure nothrow {
    if (prob.kind == ProjectProblemKind.invalidGain && hasGain) {
        return gainTok;
    }
    if (prob.kind == ProjectProblemKind.unknownHandle) {
        if (prob.subject == dstTok.text) {
            return dstTok;
        }
        return srcTok;
    }
    if (prob.kind == ProjectProblemKind.unknownPort || prob.kind == ProjectProblemKind.invalidPortDirection) {
        if (hasTo && prob.subject == toTok.optionValue) {
            return toTok;
        }
        if (hasFrom && prob.subject == fromTok.optionValue) {
            return fromTok;
        }
        if (prob.subject == dstTok.text) {
            return dstTok;
        }
        return srcTok;
    }
    return cmd.commandToken;
}

private bool splitKeepSpec(string spec, out string path, out bool hasModId, out uint modId) @safe pure nothrow {
    path = spec;
    hasModId = false;
    modId = 0;
    size_t colon = spec.length;
    foreach_reverse (i, char c; spec) {
        if (c == ':') {
            colon = i;
            break;
        }
        if (c == '/' || c == '\\') {
            break;
        }
    }
    if (colon < spec.length && colon + 1 < spec.length) {
        uint id = 0;
        if (parseUint(spec[colon + 1 .. $], id) && id > 0) {
            path = spec[0 .. colon];
            hasModId = true;
            modId = id;
            return true;
        }
    }
    return trim(path).length > 0;
}

/**
 * Handles: module <handle> [type] [preset=<name>] [file=<path>] [keep=<path[:id]>] [name=<text>] [x=<num>] [y=<num>]
 */
private StepResult handleModule(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token handleTok = cmd.args[0];
    Token presetTok;
    Token fileTok;
    Token keepTok;
    Token nameTok;
    immutable bool hasType = cmd.args.length >= 2;
    immutable bool hasPreset = cmd.optionToken("preset", presetTok);
    immutable bool hasFile = cmd.optionToken("file", fileTok);
    immutable bool hasKeep = cmd.optionToken("keep", keepTok);
    immutable bool hasName = cmd.optionToken("name", nameTok);

    immutable int sourceCount = (hasType ? 1 : 0) + (hasPreset ? 1 : 0) + (hasFile ? 1 : 0) + (hasKeep ? 1 : 0);
    if (sourceCount == 0) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length,
            "module '" ~ handleTok.text ~ "' needs a module type, preset=<name>, file=<path>, or keep=<path>",
            "", false));
    }
    if (sourceCount > 1) {
        immutable Token conflictTok = hasKeep ? keepTok : (hasPreset ? presetTok : fileTok);
        return StepResult(false, ScriptProblem(conflictTok.line, conflictTok.column, conflictTok.length,
            "give only one of module type, preset=<name>, file=<path>, or keep=<path>", "", false));
    }

    Token xTok;
    Token yTok;
    immutable bool hasX = cmd.optionToken("x", xTok);
    immutable bool hasY = cmd.optionToken("y", yTok);
    double xPos = 0.0;
    double yPos = 0.0;
    if (hasX && !parseDecimal(xTok.optionValue, xPos)) {
        return StepResult(false, ScriptProblem(xTok.line, xTok.column, xTok.length,
            "option 'x' must be a finite position number", "60", false));
    }
    if (hasY && !parseDecimal(yTok.optionValue, yPos)) {
        return StepResult(false, ScriptProblem(yTok.line, yTok.column, yTok.length,
            "option 'y' must be a finite position number", "60", false));
    }

    ModuleWriterResult modRes;
    Token sourceTok = handleTok;
    if (hasPreset && interp.library() is null) {
        return StepResult(false, ScriptProblem(presetTok.line, presetTok.column, presetTok.length,
            "preset library could not be initialized", "", false));
    }
    if (hasType) {
        sourceTok = cmd.args[1];
        modRes = ModuleWriter.fromType(sourceTok.text);
    } else if (hasPreset) {
        sourceTok = presetTok;
        modRes = ModuleWriter.fromPreset(interp.library(), presetTok.optionValue);
    } else if (hasFile) {
        sourceTok = fileTok;
        string filePath;
        StepResult pathFailure;
        if (!resolvePathToken(interp, fileTok, fileTok.optionValue, filePath, pathFailure)) {
            return pathFailure;
        }
        const(ubyte)[] virtualBytes;
        if (interp.findVirtualPreset(filePath, virtualBytes)) {
            modRes = ModuleWriter.fromPresetBytes(virtualBytes, filePath);
        } else {
            modRes = ModuleWriter.fromPresetFile(filePath);
        }
    } else {
        sourceTok = keepTok;
        string keepPath;
        bool hasKeepId = false;
        uint keepId = 0;
        if (!splitKeepSpec(keepTok.optionValue, keepPath, hasKeepId, keepId)) {
            return StepResult(false, ScriptProblem(keepTok.line, keepTok.column, keepTok.length,
                "option 'keep' needs a source file path", "", false));
        }
        string keepResolved;
        StepResult pathFailure;
        if (!resolvePathToken(interp, keepTok, keepPath, keepResolved, pathFailure)) {
            return pathFailure;
        }
        modRes = hasKeepId
            ? ProjectWriter.loadKeptModule(keepResolved, keepId)
            : ModuleWriter.fromPresetFile(keepResolved);
    }
    if (!modRes.ok) {
        return StepResult(false, ScriptInterpreter.fromModuleProblem(modRes.problem, sourceTok));
    }

    immutable ProjectIdResult addRes = (hasX || hasY)
        ? interp.project().addModuleAt(handleTok.text, modRes.writer, cast(float) xPos, cast(float) yPos)
        : interp.project().addModule(handleTok.text, modRes.writer);
    if (!addRes.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(addRes.problem, handleTok));
    }
    if (hasName) {
        immutable ProjectEditResult nameRes = interp.project().setModuleName(handleTok.text, nameTok.optionValue);
        if (!nameRes.ok) {
            cast(void) interp.project().removeModule(handleTok.text);
            return StepResult(false, ScriptInterpreter.fromProjectProblem(nameRes.problem, nameTok));
        }
    }
    return StepResult(true);
}

/**
 * Handles: set <handle> <param=value> [...] | set <handle> <param> <value>
 */
private StepResult handleSet(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token handleTok = cmd.args[0];
    if (cmd.options.length == 0 && cmd.args.length < 3) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length,
            "command 'set' needs at least one Param=Value option or <param> <value>", "", false));
    }
    if (cmd.options.length > 0 && cmd.args.length > 1) {
        immutable Token extra = cmd.args[1];
        return StepResult(false, ScriptProblem(extra.line, extra.column, extra.length,
            "write parameter assignments as Param=Value or set <handle> <param> <value>", "", false));
    }
    if (cmd.args.length == 2) {
        return StepResult(false, ScriptProblem(cmd.args[1].line, cmd.args[1].column, cmd.args[1].length,
            "parameter '" ~ cmd.args[1].text ~ "' needs a value", "", false));
    }

    ProjectModuleResult lookup = interp.project().moduleOf(handleTok.text);
    if (!lookup.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(lookup.problem, handleTok));
    }

    ModuleWriter copy = ModuleWriter(lookup.writer);
    if (cmd.options.length > 0) {
        foreach (ref opt; cmd.options) {
            immutable ModuleEditResult edit = copy.setParamText(opt.optionName, opt.optionValue);
            if (!edit.ok) {
                return StepResult(false, ScriptInterpreter.fromModuleProblem(edit.problem, opt));
            }
        }
    } else {
        immutable Token paramTok = cmd.args[1];
        immutable Token valTok = cmd.args[2];
        immutable ModuleEditResult edit = copy.setParamText(paramTok.text, valTok.text);
        if (!edit.ok) {
            return StepResult(false, ScriptInterpreter.fromModuleProblem(edit.problem, valTok));
        }
    }

    immutable ProjectEditResult committed = interp.project().replaceModuleWriter(handleTok.text, copy, true);
    if (!committed.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(committed.problem, handleTok));
    }
    return StepResult(true);
}

/**
 * Handles: preset <handle> [name] [file=<path>]
 */
private StepResult handlePreset(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token handleTok = cmd.args[0];
    Token fileTok;
    immutable bool hasName = cmd.args.length >= 2;
    immutable bool hasFile = cmd.optionToken("file", fileTok);
    if (hasName == hasFile) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'preset' needs either a preset name or file=<path>", "", false));
    }

    ProjectModuleResult existing = interp.project().moduleOf(handleTok.text);
    if (!existing.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(existing.problem, handleTok));
    }

    immutable Token srcTok = hasName ? cmd.args[1] : fileTok;
    ModuleWriterResult loaded;
    if (hasName) {
        loaded = ModuleWriter.fromPreset(interp.library(), srcTok.text);
    } else {
        string filePath;
        StepResult pathFailure;
        if (!resolvePathToken(interp, fileTok, fileTok.optionValue, filePath, pathFailure)) {
            return pathFailure;
        }
        const(ubyte)[] virtualBytes;
        if (interp.findVirtualPreset(filePath, virtualBytes)) {
            loaded = ModuleWriter.fromPresetBytes(virtualBytes, filePath);
        } else {
            loaded = ModuleWriter.fromPresetFile(filePath);
        }
    }
    if (!loaded.ok) {
        return StepResult(false, ScriptInterpreter.fromModuleProblem(loaded.problem, srcTok));
    }
    if (loaded.writer.typeId() != existing.writer.typeId()) {
        return StepResult(false, ScriptProblem(srcTok.line, srcTok.column, srcTok.length,
            "preset type '" ~ loaded.writer.typeId() ~ "' does not match module '" ~ handleTok.text
            ~ "' ('" ~ existing.writer.typeId() ~ "')", "", false));
    }

    immutable ProjectEditResult replaced = interp.project().replaceModuleWriter(handleTok.text, loaded.writer, true);
    if (!replaced.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(replaced.problem, handleTok));
    }
    return StepResult(true);
}

/**
 * Handles: sample <handle> <path> [slot=<0..15>] [root=<note>] [low=<note>] [high=<note>]
 */
private StepResult handleSample(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token handleTok = cmd.args[0];
    immutable Token pathTok = cmd.args[1];

    ProjectModuleResult existing = interp.project().moduleOf(handleTok.text);
    if (!existing.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(existing.problem, handleTok));
    }

    uint slot = 0;
    Token slotTok;
    if (cmd.optionToken("slot", slotTok) && (!parseUint(slotTok.optionValue, slot) || slot > 15)) {
        return StepResult(false, ScriptProblem(slotTok.line, slotTok.column, slotTok.length,
            "option 'slot' must be a whole number from 0 to 15", "0", false));
    }
    int root = 60;
    Token rootTok;
    if (cmd.optionToken("root", rootTok) && !parseMidiNoteOption(rootTok.optionValue, root)) {
        return StepResult(false, ScriptProblem(rootTok.line, rootTok.column, rootTok.length,
            "option 'root' must be a MIDI note (0..127) or pitch name (e.g. C4)", "C4", false));
    }
    int low = 0;
    Token lowTok;
    if (cmd.optionToken("low", lowTok) && !parseMidiNoteOption(lowTok.optionValue, low)) {
        return StepResult(false, ScriptProblem(lowTok.line, lowTok.column, lowTok.length,
            "option 'low' must be a MIDI note (0..127) or pitch name", "0", false));
    }
    int high = 127;
    Token highTok;
    if (cmd.optionToken("high", highTok) && !parseMidiNoteOption(highTok.optionValue, high)) {
        return StepResult(false, ScriptProblem(highTok.line, highTok.column, highTok.length,
            "option 'high' must be a MIDI note (0..127) or pitch name", "127", false));
    }

    string samplePath;
    StepResult pathFailure;
    if (!resolvePathToken(interp, pathTok, pathTok.text, samplePath, pathFailure)) {
        return pathFailure;
    }
    ModuleWriter copy = ModuleWriter(existing.writer);
    immutable ModuleEditResult sampleRes = copy.loadSampleFile(cast(int) slot, samplePath, root, low, high);
    if (!sampleRes.ok) {
        return StepResult(false, ScriptInterpreter.fromModuleProblem(sampleRes.problem, pathTok));
    }

    immutable ProjectEditResult replaced = interp.project().replaceModuleWriter(handleTok.text, copy, true);
    if (!replaced.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(replaced.problem, handleTok));
    }
    return StepResult(true);
}

/**
 * Resolves the file path a command was given against the interpreter's base folder (T109).
 *
 * Params:
 *   interp = The interpreter.
 *   tok = The token the path came from, for the problem's position.
 *   path = The path as written.
 *   resolved = Receives the path to use.
 *   failure = Receives the refusal when relative paths are not allowed.
 *
 * Returns:
 *   True when the path can be used.
 */
private bool resolvePathToken(ScriptInterpreter interp, const ref Token tok, string path, out string resolved,
        out StepResult failure) @safe nothrow {
    failure = StepResult(true);
    if (interp.resolvePath(trim(path), resolved)) {
        return true;
    }
    failure = StepResult(false, ScriptProblem(tok.line, tok.column, tok.length,
        "save the project first, or write an absolute path: a relative path is read from the project's folder",
        "", false));
    return false;
}

/**
 * Handles: savemodule <handle> <path>
 */
private StepResult handleSaveModule(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token handleTok = cmd.args[0];
    immutable Token pathTok = cmd.args[1];
    if (trim(pathTok.text).length == 0) {
        return StepResult(false, ScriptProblem(pathTok.line, pathTok.column, pathTok.length,
            "preset save path cannot be empty", "", false));
    }
    ProjectModuleResult existing = interp.project().moduleOf(handleTok.text);
    if (!existing.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(existing.problem, handleTok));
    }
    string presetPath;
    StepResult pathFailure;
    if (!resolvePathToken(interp, pathTok, pathTok.text, presetPath, pathFailure)) {
        return pathFailure;
    }
    if (interp.checkOnly()) {
        ModuleBytesResult bytes = existing.writer.presetBytes();
        if (!bytes.ok) {
            return StepResult(false, ScriptInterpreter.fromModuleProblem(bytes.problem, pathTok));
        }
        interp.cacheVirtualPreset(presetPath, bytes.bytes);
        interp.recordSavedPath(presetPath);
        return StepResult(true);
    }
    immutable ModuleEditResult wrote = existing.writer.writePresetFile(presetPath);
    if (!wrote.ok) {
        return StepResult(false, ScriptInterpreter.fromModuleProblem(wrote.problem, pathTok));
    }
    interp.recordSavedPath(presetPath);
    return StepResult(true);
}

/**
 * Handles: connect <src> <dst> [gain=<num>] [from=<port>] [to=<port>]
 */
private StepResult handleConnect(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token srcTok = cmd.args[0];
    immutable Token dstTok = cmd.args[1];
    Token gainTok;
    Token fromTok;
    Token toTok;
    immutable bool hasGain = cmd.optionToken("gain", gainTok);
    immutable bool hasFrom = cmd.optionToken("from", fromTok);
    immutable bool hasTo = cmd.optionToken("to", toTok);

    double gain = 1.0;
    if (hasGain && !parseDecimal(gainTok.optionValue, gain)) {
        return StepResult(false, ScriptProblem(gainTok.line, gainTok.column, gainTok.length,
            "wire gain must be a finite number of 0 or more", "1", false));
    }
    immutable string srcPort = hasFrom ? fromTok.optionValue : "";
    immutable string dstPort = hasTo ? toTok.optionValue : "";
    immutable ProjectEditResult res = interp.project().connect(srcTok.text, dstTok.text,
        cast(float) gain, srcPort, dstPort);
    if (!res.ok) {
        immutable Token errTok = pickWireProblemToken(res.problem, cmd, srcTok, dstTok,
            hasGain, gainTok, hasFrom, fromTok, hasTo, toTok);
        return StepResult(false, ScriptInterpreter.fromProjectProblem(res.problem, errTok));
    }
    return StepResult(true);
}

/**
 * Handles: disconnect <src> <dst> [from=<port>] [to=<port>]
 */
private StepResult handleDisconnect(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token srcTok = cmd.args[0];
    immutable Token dstTok = cmd.args[1];
    Token fromTok;
    Token toTok;
    immutable bool hasFrom = cmd.optionToken("from", fromTok);
    immutable bool hasTo = cmd.optionToken("to", toTok);
    immutable string srcPort = hasFrom ? fromTok.optionValue : "";
    immutable string dstPort = hasTo ? toTok.optionValue : "";

    immutable ProjectEditResult res = interp.project().disconnect(srcTok.text, dstTok.text, srcPort, dstPort);
    if (!res.ok) {
        immutable Token dummyGain;
        immutable Token errTok = pickWireProblemToken(res.problem, cmd, srcTok, dstTok,
            false, dummyGain, hasFrom, fromTok, hasTo, toTok);
        return StepResult(false, ScriptInterpreter.fromProjectProblem(res.problem, errTok));
    }
    return StepResult(true);
}

/**
 * Handles: remove <handle>
 */
private StepResult handleRemove(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token handleTok = cmd.args[0];
    immutable ProjectEditResult res = interp.project().removeModule(handleTok.text);
    if (!res.ok) {
        return StepResult(false, ScriptInterpreter.fromProjectProblem(res.problem, handleTok));
    }
    return StepResult(true);
}

private struct NoteSpan {
    size_t joinedStart = 0;
    size_t joinedEnd = 0;
    uint line = 1;
    uint column = 1;
    uint length = 1;
}

private string buildNoteSpans(const(Token)[] tailTokens, out NoteSpan[] spans) @safe pure nothrow {
    string joined;
    foreach (i, ref tok; tailTokens) {
        if (i > 0) {
            joined ~= ' ';
        }
        immutable size_t start = joined.length;
        joined ~= tok.text;
        spans ~= NoteSpan(start, joined.length, tok.line, tok.column, tok.length);
    }
    return joined;
}

private ScriptProblem mapNotationError(const(NoteSpan)[] spans, uint colonLine, uint colonColumn,
        const ref NotationError err) @safe pure nothrow {
    uint line = colonLine;
    uint col = colonColumn;
    uint len = 1;
    bool matched = false;
    foreach (ref sp; spans) {
        if (err.offset >= sp.joinedStart && err.offset < sp.joinedEnd) {
            line = sp.line;
            col = sp.column + cast(uint)(err.offset - sp.joinedStart);
            immutable size_t avail = sp.joinedEnd - err.offset;
            len = err.length > 0 && err.length <= avail
                ? cast(uint) err.length : (avail > 0 ? cast(uint) avail : 1);
            matched = true;
            break;
        }
    }
    if (!matched && spans.length > 0) {
        size_t bestIdx = 0;
        bool hasPrior = false;
        foreach (i, ref sp; spans) {
            if (sp.joinedEnd <= err.offset) {
                bestIdx = i;
                hasPrior = true;
            }
        }
        if (hasPrior) {
            immutable auto sp = spans[bestIdx];
            line = sp.line;
            col = sp.column + sp.length;
            len = 1;
        } else {
            immutable auto sp = spans[0];
            line = sp.line;
            col = sp.column;
            len = sp.length;
        }
    }
    return ScriptProblem(line, col, len, err.reason, err.suggestion, false);
}

/**
 * Handles: section <name> bars=<bars> (T104)
 */
private StepResult handleSection(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token nameTok = cmd.args[0];
    Token barsTok;
    if (!cmd.optionToken("bars", barsTok)) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'section' requires option bars=<count>", "bars=4", false));
    }
    uint bars = 0;
    if (!parseUint(barsTok.optionValue, bars)) {
        return StepResult(false, ScriptProblem(barsTok.line, barsTok.column, barsTok.length,
            "option 'bars' must be a whole number of 1 or more bars", "4", false));
    }
    immutable SectionResult res = interp.parts().addSection(nameTok.text, bars);
    if (!res.ok) {
        immutable Token errTok = (res.problem.kind == PartProblemKind.invalidBars
            || res.problem.kind == PartProblemKind.sectionTooLong) ? barsTok : nameTok;
        return StepResult(false, ScriptInterpreter.fromPartProblem(res.problem, errTok));
    }
    return StepResult(true);
}

/**
 * Handles: part <name> [module=<handle>] [drums=<handle>] (T104 / T105)
 */
private StepResult handlePart(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token nameTok = cmd.args[0];
    Token modTok;
    Token drumsTok;
    immutable bool hasMod = cmd.optionToken("module", modTok);
    immutable bool hasDrums = cmd.optionToken("drums", drumsTok);
    if (!hasMod && !hasDrums) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'part' requires module=<handle> or drums=<handle>", "", false));
    }
    if (hasMod && hasDrums) {
        return StepResult(false, ScriptProblem(drumsTok.line, drumsTok.column, drumsTok.length,
            "give either module=<handle> or drums=<handle>, not both", "", false));
    }
    if (hasDrums) {
        immutable DrumEditResult dRes = interp.drums().addDrumPart(nameTok.text, drumsTok.optionValue);
        if (!dRes.ok) {
            immutable Token errTok = dRes.problem.kind == DrumProblemKind.unknownModule ? drumsTok : nameTok;
            immutable bool isName = dRes.problem.kind == DrumProblemKind.invalidName
                || dRes.problem.kind == DrumProblemKind.duplicatePart
                || dRes.problem.kind == DrumProblemKind.unknownModule;
            return StepResult(false, ScriptProblem(errTok.line, errTok.column, errTok.length,
                dRes.problem.reason, dRes.problem.suggestion, isName));
        }
        return StepResult(true);
    }
    immutable PartResult res = interp.parts().addPart(nameTok.text, modTok.optionValue);
    if (!res.ok) {
        immutable Token errTok = res.problem.kind == PartProblemKind.unknownModule ? modTok : nameTok;
        return StepResult(false, ScriptInterpreter.fromPartProblem(res.problem, errTok));
    }
    return StepResult(true);
}

/**
 * Handles: notes <part> [<section>] [at=<position>]: <notation> (T104)
 */
private StepResult handleNotes(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    if (!cmd.hasColon) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'notes' needs ':' before the notes", "", false));
    }
    immutable Token partTok = cmd.args[0];
    immutable bool hasSection = cmd.args.length >= 2;
    immutable string sectionName = hasSection ? cmd.args[1].text : "";
    immutable Token secTok = hasSection ? cmd.args[1] : partTok;

    immutable TimeSignature sig = interp.project().timeSignature();
    BeatPosition startPos = BeatPosition(1, 1, 1);
    Token atTok;
    immutable bool hasAt = cmd.optionToken("at", atTok);
    if (hasAt) {
        immutable PositionResult posRes = parsePosition(atTok.optionValue, sig);
        if (!posRes.ok) {
            return StepResult(false, ScriptProblem(atTok.line, atTok.column, atTok.length,
                posRes.error.reason, posRes.error.suggestion, false));
        }
        startPos = posRes.position;
    }

    if (cmd.tailTokens.length == 0) {
        return StepResult(false, ScriptProblem(cmd.colonLine, cmd.colonColumn, 1,
            "command 'notes' needs at least one note or rest after ':'", "", false));
    }

    NoteSpan[] spans;
    immutable string joined = buildNoteSpans(cmd.tailTokens, spans);
    NotationResult parsed = parseNotes(joined, sig);
    if (!parsed.ok) {
        return StepResult(false, mapNotationError(spans, cmd.colonLine, cmd.colonColumn, parsed.error));
    }

    immutable PartEditResult writeRes = interp.parts().writeNotes(partTok.text, sectionName, startPos,
        parsed.events);
    if (!writeRes.ok) {
        if (writeRes.problem.kind == PartProblemKind.unknownPart) {
            return StepResult(false, ScriptInterpreter.fromPartProblem(writeRes.problem, partTok));
        }
        if (writeRes.problem.kind == PartProblemKind.unknownSection) {
            return StepResult(false, ScriptInterpreter.fromPartProblem(writeRes.problem, secTok));
        }
        import compose.timing : LinesResult, positionToLine;
        immutable LinesResult baseLine = positionToLine(startPos, sig);
        if (baseLine.ok) {
            foreach (ref ev; parsed.events) {
                immutable auto posAt = lineToPosition(baseLine.lines + ev.offset, sig);
                if (posAt.ok && formatPosition(posAt.position) == writeRes.problem.subject) {
                    NotationError mapped = NotationError(ev.textOffset, ev.textLength,
                        writeRes.problem.reason, writeRes.problem.suggestion);
                    return StepResult(false, mapNotationError(spans, cmd.colonLine, cmd.colonColumn, mapped));
                }
            }
        }
        immutable Token fallbackTok = hasAt ? atTok : cmd.tailTokens[0];
        return StepResult(false, ScriptInterpreter.fromPartProblem(writeRes.problem, fallbackTok));
    }
    return StepResult(true);
}

private bool parseSignedInt(string text, out int value) @safe pure nothrow @nogc {
    immutable string s = trim(text);
    if (s.length == 0) {
        return false;
    }
    size_t i = 0;
    bool neg = false;
    if (s[0] == '-') {
        neg = true;
        i = 1;
    } else if (s[0] == '+') {
        i = 1;
    }
    if (i == s.length) {
        return false;
    }
    long acc = 0;
    foreach (c; s[i .. $]) {
        if (c < '0' || c > '9') {
            return false;
        }
        acc = acc * 10 + (c - '0');
        if (acc > 1_000_000) {
            return false;
        }
    }
    immutable long signed = neg ? -acc : acc;
    if (signed < int.min || signed > int.max) {
        return false;
    }
    value = cast(int) signed;
    return true;
}

private bool parseByteToken(string text, out ubyte value) @safe pure nothrow @nogc {
    immutable string s = trim(text);
    if (s.length == 0) {
        return false;
    }
    if (s.length >= 3 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        uint acc = 0;
        foreach (char c; s[2 .. $]) {
            uint d = 0;
            if (c >= '0' && c <= '9') {
                d = cast(uint)(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                d = cast(uint)(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                d = cast(uint)(c - 'A' + 10);
            } else {
                return false;
            }
            acc = acc * 16 + d;
            if (acc > 255) {
                return false;
            }
        }
        value = cast(ubyte) acc;
        return true;
    }
    uint dec = 0;
    if (!parseUint(s, dec) || dec > 255) {
        return false;
    }
    value = cast(ubyte) dec;
    return true;
}

private bool parseEffectToken(string text, out ubyte fx) @safe pure nothrow {
    if (parseByteToken(text, fx)) {
        return true;
    }
    if (namesMatch(text, "none")) {
        fx = EffectCode.none;
        return true;
    }
    if (namesMatch(text, "slideUp")) {
        fx = EffectCode.slideUp;
        return true;
    }
    if (namesMatch(text, "slideDown")) {
        fx = EffectCode.slideDown;
        return true;
    }
    if (namesMatch(text, "portamento")) {
        fx = EffectCode.portamento;
        return true;
    }
    if (namesMatch(text, "vibrato")) {
        fx = EffectCode.vibrato;
        return true;
    }
    if (namesMatch(text, "pitchOffsetUp")) {
        fx = EffectCode.pitchOffsetUp;
        return true;
    }
    if (namesMatch(text, "pitchOffsetDown")) {
        fx = EffectCode.pitchOffsetDown;
        return true;
    }
    if (namesMatch(text, "sampleOffset")) {
        fx = EffectCode.sampleOffset;
        return true;
    }
    if (namesMatch(text, "arpeggio") || namesMatch(text, "arp")) {
        fx = EffectCode.arpeggio;
        return true;
    }
    if (namesMatch(text, "sampleOffsetFine")) {
        fx = EffectCode.sampleOffsetFine;
        return true;
    }
    if (namesMatch(text, "velocitySlide")) {
        fx = EffectCode.velocitySlide;
        return true;
    }
    if (namesMatch(text, "setSpeed")) {
        fx = EffectCode.setSpeed;
        return true;
    }
    if (namesMatch(text, "fineSlideUp")) {
        fx = EffectCode.fineSlideUp;
        return true;
    }
    if (namesMatch(text, "fineSlideDown")) {
        fx = EffectCode.fineSlideDown;
        return true;
    }
    if (namesMatch(text, "bypassModule")) {
        fx = EffectCode.bypassModule;
        return true;
    }
    if (namesMatch(text, "muteModule")) {
        fx = EffectCode.muteModule;
        return true;
    }
    if (namesMatch(text, "retrigger")) {
        fx = EffectCode.retrigger;
        return true;
    }
    if (namesMatch(text, "noteCut")) {
        fx = EffectCode.noteCut;
        return true;
    }
    if (namesMatch(text, "noteDelay")) {
        fx = EffectCode.noteDelay;
        return true;
    }
    if (namesMatch(text, "setBpm")) {
        fx = EffectCode.setBpm;
        return true;
    }
    if (namesMatch(text, "stopSong")) {
        fx = EffectCode.stopSong;
        return true;
    }
    if (namesMatch(text, "jumpLine")) {
        fx = EffectCode.jumpLine;
        return true;
    }
    return false;
}

private bool parseCellNoteValue(string text, out ubyte noteByte) @safe pure nothrow {
    if (namesMatch(text, "none") || namesMatch(text, "empty")) {
        noteByte = NoteCmd.empty;
        return true;
    }
    if (namesMatch(text, "off") || namesMatch(text, "noteOff")) {
        noteByte = NoteCmd.noteOff;
        return true;
    }
    if (namesMatch(text, "allOff") || namesMatch(text, "allNotesOff")) {
        noteByte = NoteCmd.allNotesOff;
        return true;
    }
    if (namesMatch(text, "prev") || namesMatch(text, "prevTrack")) {
        noteByte = NoteCmd.prevTrack;
        return true;
    }
    if (namesMatch(text, "setPitch")) {
        noteByte = NoteCmd.setPitch;
        return true;
    }
    if (namesMatch(text, "stop") || namesMatch(text, "stopSong")) {
        noteByte = NoteCmd.stopSong;
        return true;
    }
    immutable PitchResult pr = parsePitch(trim(text));
    if (pr.ok) {
        noteByte = cast(ubyte)(pr.midi + 1);
        return true;
    }
    return false;
}

private bool parseFlagOption(string text, out bool val) @safe pure nothrow {
    if (namesMatch(text, "on") || namesMatch(text, "true") || text == "1") {
        val = true;
        return true;
    }
    if (namesMatch(text, "off") || namesMatch(text, "false") || text == "0") {
        val = false;
        return true;
    }
    return false;
}

/**
 * Handles: arrange <section> [<section> ...] | arrange clip=<pattern> start=<line> len=<lines> lane=<y> ... (T104 / T107)
 */
private StepResult handleArrange(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    Token clipTok;
    if (cmd.optionToken("clip", clipTok)) {
        if (cmd.args.length > 0) {
            return StepResult(false, ScriptProblem(cmd.args[0].line, cmd.args[0].column,
                cmd.args[0].length, "cannot mix section names with clip= option in 'arrange'", "", false));
        }
        Token startTok;
        Token lenTok;
        Token laneTok;
        if (!cmd.optionToken("start", startTok)) {
            return StepResult(false, ScriptProblem(clipTok.line, clipTok.column, clipTok.length,
                "arrange clip=... needs start=<line>", "start=0", false));
        }
        if (!cmd.optionToken("len", lenTok)) {
            return StepResult(false, ScriptProblem(clipTok.line, clipTok.column, clipTok.length,
                "arrange clip=... needs len=<lines>", "len=16", false));
        }
        if (!cmd.optionToken("lane", laneTok)) {
            return StepResult(false, ScriptProblem(clipTok.line, clipTok.column, clipTok.length,
                "arrange clip=... needs lane=<index>", "lane=0", false));
        }
        uint startLine = 0;
        uint lenLines = 0;
        uint laneY = 0;
        if (!parseUint(startTok.optionValue, startLine)) {
            return StepResult(false, ScriptProblem(startTok.line, startTok.column, startTok.length,
                "option 'start' must be a non-negative line number", "0", false));
        }
        if (!parseUint(lenTok.optionValue, lenLines) || lenLines == 0) {
            return StepResult(false, ScriptProblem(lenTok.line, lenTok.column, lenTok.length,
                "option 'len' must be a positive line count", "16", false));
        }
        if (!parseUint(laneTok.optionValue, laneY)) {
            return StepResult(false, ScriptProblem(laneTok.line, laneTok.column, laneTok.length,
                "option 'lane' must be a non-negative lane number", "0", false));
        }
        uint offsetLines = 0;
        Token offTok;
        if (cmd.optionToken("offset", offTok) && !parseUint(offTok.optionValue, offsetLines)) {
            return StepResult(false, ScriptProblem(offTok.line, offTok.column, offTok.length,
                "option 'offset' must be a non-negative line offset", "0", false));
        }
        bool muteFlag = false;
        Token muteTok;
        if (cmd.optionToken("mute", muteTok) && !parseFlagOption(muteTok.optionValue, muteFlag)) {
            return StepResult(false, ScriptProblem(muteTok.line, muteTok.column, muteTok.length,
                "option 'mute' must be on or off", "off", false));
        }
        bool soloFlag = false;
        Token soloTok;
        if (cmd.optionToken("solo", soloTok) && !parseFlagOption(soloTok.optionValue, soloFlag)) {
            return StepResult(false, ScriptProblem(soloTok.line, soloTok.column, soloTok.length,
                "option 'solo' must be on or off", "off", false));
        }
        bool superFlag = false;
        Token superTok;
        if (cmd.optionToken("supertrack", superTok) && !parseFlagOption(superTok.optionValue, superFlag)) {
            return StepResult(false, ScriptProblem(superTok.line, superTok.column, superTok.length,
                "option 'supertrack' must be on or off", "off", false));
        }

        uint patId = 0;
        immutable string clipVal = clipTok.optionValue;
        if (clipVal.length > 1 && clipVal[0] == '#') {
            cast(void) parseUint(clipVal[1 .. $], patId);
        }
        if (patId == 0) {
            patId = interp.parts().findPatternIdByName(clipVal);
        }
        if (patId == 0) {
            return StepResult(false, ScriptProblem(clipTok.line, clipTok.column, clipTok.length,
                "there is no pattern '" ~ clipVal ~ "'", "", true));
        }
        immutable PartEditResult addClip = interp.parts().addRawClip(patId, cast(long) startLine,
            lenLines, laneY, offsetLines, muteFlag, soloFlag, superFlag);
        if (!addClip.ok) {
            return StepResult(false, ScriptInterpreter.fromPartProblem(addClip.problem, clipTok));
        }
        return StepResult(true);
    }

    if (cmd.args.length == 0) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'arrange' requires argument 'sections'", "", false));
    }
    string[] names;
    names.reserve(cmd.args.length);
    foreach (ref a; cmd.args) {
        names ~= a.text;
    }
    immutable PartEditResult res = interp.parts().arrange(names);
    if (!res.ok) {
        Token errTok = cmd.args[0];
        foreach (ref a; cmd.args) {
            if (a.text == res.problem.subject) {
                errTok = a;
                break;
            }
        }
        return StepResult(false, ScriptInterpreter.fromPartProblem(res.problem, errTok));
    }
    return StepResult(true);
}

/**
 * Handles: loop <section> [<endSection>] | loop all | loop start=<line> end=<line> (T104)
 */
private StepResult handleLoop(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    Token startTok;
    Token endTok;
    immutable bool hasStart = cmd.optionToken("start", startTok);
    immutable bool hasEnd = cmd.optionToken("end", endTok);
    if (hasStart || hasEnd) {
        if (cmd.args.length > 0) {
            return StepResult(false, ScriptProblem(cmd.args[0].line, cmd.args[0].column,
                cmd.args[0].length, "cannot mix section names with start=/end= options in 'loop'", "", false));
        }
        if (!hasStart || !hasEnd) {
            immutable Token present = hasStart ? startTok : endTok;
            return StepResult(false, ScriptProblem(present.line, present.column, present.length,
                "command 'loop' needs both start=<line> and end=<line>", "", false));
        }
        uint startLine = 0;
        uint endLine = 0;
        if (!parseUint(startTok.optionValue, startLine)) {
            return StepResult(false, ScriptProblem(startTok.line, startTok.column, startTok.length,
                "option 'start' must be a non-negative line number", "0", false));
        }
        if (!parseUint(endTok.optionValue, endLine)) {
            return StepResult(false, ScriptProblem(endTok.line, endTok.column, endTok.length,
                "option 'end' must be a positive line number", "16", false));
        }
        immutable PartEditResult res = interp.parts().setLoopLines(cast(long) startLine, cast(long) endLine);
        if (!res.ok) {
            return StepResult(false, ScriptInterpreter.fromPartProblem(res.problem, endTok));
        }
        return StepResult(true);
    }

    if (cmd.args.length == 0) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length,
            "command 'loop' needs a section name, 'all', or start=<line> end=<line>", "", false));
    }

    immutable Token firstTok = cmd.args[0];
    if (cmd.args.length == 1 && (namesMatch(firstTok.text, "all") || namesMatch(firstTok.text, "clear")
            || namesMatch(firstTok.text, "reset"))) {
        interp.parts().clearLoop();
        return StepResult(true);
    }

    immutable SectionResult firstSec = interp.parts().sectionOf(firstTok.text);
    if (!firstSec.ok) {
        return StepResult(false, ScriptInterpreter.fromPartProblem(firstSec.problem, firstTok));
    }
    const(string)[] arr = interp.parts().arrangement();
    size_t startIdx = arr.length;
    foreach (i, s; arr) {
        if (namesMatch(s, firstSec.section.name)) {
            startIdx = i;
            break;
        }
    }
    if (startIdx == arr.length) {
        return StepResult(false, ScriptProblem(firstTok.line, firstTok.column, firstTok.length,
            "section '" ~ firstSec.section.name ~ "' is not in the arrangement", "", false));
    }

    size_t endIdx = startIdx;
    if (cmd.args.length >= 2) {
        immutable Token secondTok = cmd.args[1];
        immutable SectionResult secondSec = interp.parts().sectionOf(secondTok.text);
        if (!secondSec.ok) {
            return StepResult(false, ScriptInterpreter.fromPartProblem(secondSec.problem, secondTok));
        }
        endIdx = arr.length;
        foreach (i; startIdx .. arr.length) {
            if (namesMatch(arr[i], secondSec.section.name)) {
                endIdx = i;
                break;
            }
        }
        if (endIdx == arr.length) {
            return StepResult(false, ScriptProblem(secondTok.line, secondTok.column, secondTok.length,
                "section '" ~ secondSec.section.name ~ "' does not appear at or after '"
                ~ firstSec.section.name ~ "' in the arrangement", "", false));
        }
    }

    immutable PartEditResult res = interp.parts().setLoopSections(startIdx, endIdx + 1);
    if (!res.ok) {
        return StepResult(false, ScriptInterpreter.fromPartProblem(res.problem, firstTok));
    }
    return StepResult(true);
}

private bool resolvePhraseTargetLength(ScriptInterpreter interp, string partName, string sectionName,
        out uint sectionLines, out bool hasPattern, out PartProblem prob) @safe nothrow {
    if (!interp.parts().hasPart(partName)) {
        immutable auto pr = interp.parts().partOf(partName);
        prob = pr.problem;
        return false;
    }
    immutable string cleanSec = trim(sectionName);
    if (cleanSec.length == 0) {
        if (!interp.parts().hasImplicitSection()) {
            prob = PartProblem(PartProblemKind.unknownSection, sectionName,
                "there is no implicit section yet", "");
            return false;
        }
        sectionLines = cast(uint) interp.parts().arrangementLengthLines();
        immutable auto pat = interp.parts().patternFor(partName, "");
        hasPattern = pat.ok;
        if (pat.ok) {
            sectionLines = pat.pattern.lines;
        }
        return true;
    }
    immutable SectionResult sr = interp.parts().sectionOf(cleanSec);
    if (!sr.ok) {
        prob = sr.problem;
        return false;
    }
    sectionLines = sr.section.lines;
    hasPattern = interp.parts().hasPattern(partName, cleanSec);
    return true;
}

/**
 * Handles: cells <target> [<section>] [tracks=<n>] [lines=<n>] [track=<t>] [line=<l>|at=<pos>]
 *   [note=<pitch|cmd>] [vel=<0..1>] [velbyte=<0..255>] [module=<handle|none>]
 *   [param=<name|id>] [val=<text>] [fx=<hex|name>] [fxval=<hex|int>] (T106)
 */
private StepResult handleCells(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token firstTok = cmd.args[0];
    immutable bool hasSecond = cmd.args.length >= 2;
    immutable string secondName = hasSecond ? cmd.args[1].text : "";

    Token tracksTok;
    Token linesTok;
    immutable bool hasTracks = cmd.optionToken("tracks", tracksTok);
    immutable bool hasLines = cmd.optionToken("lines", linesTok);

    uint targetPatId = 0;
    if (hasTracks || hasLines) {
        if (!hasTracks || !hasLines) {
            immutable Token present = hasTracks ? tracksTok : linesTok;
            return StepResult(false, ScriptProblem(present.line, present.column, present.length,
                "creating a raw pattern needs both tracks=<n> and lines=<n>", "", false));
        }
        if (hasSecond) {
            return StepResult(false, ScriptProblem(cmd.args[1].line, cmd.args[1].column,
                cmd.args[1].length, "raw pattern creation takes one pattern name", "", false));
        }
        uint tr = 0;
        uint ln = 0;
        if (!parseUint(tracksTok.optionValue, tr)) {
            return StepResult(false, ScriptProblem(tracksTok.line, tracksTok.column, tracksTok.length,
                "option 'tracks' must be a whole number from 1 to 64", "1", false));
        }
        if (!parseUint(linesTok.optionValue, ln)) {
            return StepResult(false, ScriptProblem(linesTok.line, linesTok.column, linesTok.length,
                "option 'lines' must be a whole number from 1 to 4096", "16", false));
        }
        immutable PartPatternResult raw = interp.parts().addRawPattern(firstTok.text, tr, ln);
        if (!raw.ok) {
            return StepResult(false, ScriptInterpreter.fromPartProblem(raw.problem, firstTok));
        }
        targetPatId = raw.pattern.patternId;
    }

    Token trackTok;
    Token lineTok;
    Token atTok;
    Token noteTok;
    Token velTok;
    Token velByteTok;
    Token modTok;
    Token paramTok;
    Token valTok;
    Token fxTok;
    Token fxValTok;
    immutable bool hasTrack = cmd.optionToken("track", trackTok);
    immutable bool hasLine = cmd.optionToken("line", lineTok);
    immutable bool hasAt = cmd.optionToken("at", atTok);
    immutable bool hasNote = cmd.optionToken("note", noteTok);
    immutable bool hasVel = cmd.optionToken("vel", velTok);
    immutable bool hasVelByte = cmd.optionToken("velbyte", velByteTok);
    immutable bool hasMod = cmd.optionToken("module", modTok);
    immutable bool hasParam = cmd.optionToken("param", paramTok);
    immutable bool hasVal = cmd.optionToken("val", valTok);
    immutable bool hasFx = cmd.optionToken("fx", fxTok);
    immutable bool hasFxVal = cmd.optionToken("fxval", fxValTok);

    immutable bool anyCellField = hasTrack || hasLine || hasAt || hasNote || hasVel || hasVelByte
        || hasMod || hasParam || hasVal || hasFx || hasFxVal;
    if ((hasTracks || hasLines) && !anyCellField) {
        return StepResult(true);
    }

    if (hasLine && hasAt) {
        return StepResult(false, ScriptProblem(atTok.line, atTok.column, atTok.length,
            "give either line=<n> or at=<pos>, not both", "", false));
    }
    if (!hasLine && !hasAt) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'cells' needs line=<n> or at=<pos>", "line=0", false));
    }

    uint lineIdx = 0;
    if (hasLine) {
        if (!parseUint(lineTok.optionValue, lineIdx)) {
            return StepResult(false, ScriptProblem(lineTok.line, lineTok.column, lineTok.length,
                "option 'line' must be a non-negative line index", "0", false));
        }
    } else {
        immutable PositionResult pr = parsePosition(atTok.optionValue, interp.project().timeSignature());
        if (!pr.ok) {
            return StepResult(false, ScriptProblem(atTok.line, atTok.column, atTok.length,
                pr.error.reason, pr.error.suggestion, false));
        }
        import compose.timing : LinesResult;
        immutable LinesResult lr = positionToLine(pr.position, interp.project().timeSignature());
        if (!lr.ok) {
            return StepResult(false, ScriptProblem(atTok.line, atTok.column, atTok.length,
                lr.error.reason, lr.error.suggestion, false));
        }
        lineIdx = lr.lines;
    }

    uint trackIdx = 0;
    if (hasTrack && !parseUint(trackTok.optionValue, trackIdx)) {
        return StepResult(false, ScriptProblem(trackTok.line, trackTok.column, trackTok.length,
            "option 'track' must be a non-negative track index", "0", false));
    }

    if (targetPatId == 0) {
        if (hasSecond) {
            immutable PartPatternResult pr = interp.parts().patternFor(firstTok.text, secondName);
            if (!pr.ok) {
                immutable Token errTok = (pr.problem.kind == PartProblemKind.unknownSection)
                    ? cmd.args[1] : firstTok;
                return StepResult(false, ScriptInterpreter.fromPartProblem(pr.problem, errTok));
            }
            targetPatId = pr.pattern.patternId;
        } else if (interp.parts().hasPart(firstTok.text)) {
            immutable PartPatternResult pr = interp.parts().patternFor(firstTok.text, "");
            if (!pr.ok) {
                return StepResult(false, ScriptInterpreter.fromPartProblem(pr.problem, firstTok));
            }
            targetPatId = pr.pattern.patternId;
        } else {
            immutable PartPatternResult raw = interp.parts().patternByName(firstTok.text);
            if (!raw.ok) {
                return StepResult(false, ScriptInterpreter.fromPartProblem(raw.problem, firstTok));
            }
            targetPatId = raw.pattern.patternId;
        }
    }

    NoteCell cell = NoteCell.init;
    if (hasNote) {
        if (!parseCellNoteValue(noteTok.optionValue, cell.note)) {
            return StepResult(false, ScriptProblem(noteTok.line, noteTok.column, noteTok.length,
                "invalid tracker note '" ~ noteTok.optionValue ~ "' (use pitch like C4, off, alloff, prev, setpitch, stop, or none)",
                "C4", false));
        }
    }

    if (hasVel && hasVelByte) {
        return StepResult(false, ScriptProblem(velByteTok.line, velByteTok.column, velByteTok.length,
            "give either vel= or velbyte=, not both", "", false));
    }
    if (hasVel) {
        double v = 0.0;
        if (!parseDecimal(velTok.optionValue, v) || v <= 0.0 || v > 1.0) {
            return StepResult(false, ScriptProblem(velTok.line, velTok.column, velTok.length,
                "option 'vel' must be a number in (0, 1]", "0.8", false));
        }
        cell.velocity = NoteCell.encodeVelocity(cast(float) v);
    } else if (hasVelByte) {
        if (!parseByteToken(velByteTok.optionValue, cell.velocity)) {
            return StepResult(false, ScriptProblem(velByteTok.line, velByteTok.column, velByteTok.length,
                "option 'velbyte' must be 0..255", "205", false));
        }
    } else if (cell.isMidiNote()) {
        cell.velocity = NoteCell.encodeVelocity(0.8f);
    }

    uint chosenModId = 0;
    if (hasMod) {
        if (namesMatch(modTok.optionValue, "none") || modTok.optionValue == "0") {
            chosenModId = 0;
        } else {
            immutable ProjectIdResult modRes = interp.project().moduleId(modTok.optionValue);
            if (!modRes.ok) {
                return StepResult(false, ScriptInterpreter.fromProjectProblem(modRes.problem, modTok));
            }
            chosenModId = modRes.id;
        }
    } else if (cell.isMidiNote() || cell.note == NoteCmd.noteOff) {
        immutable PartPatternResult patInfo = interp.parts().patternById(targetPatId);
        if (patInfo.ok && patInfo.pattern.moduleId != 0) {
            chosenModId = patInfo.pattern.moduleId;
        }
    }
    cell.moduleId = cast(ushort) chosenModId;

    if (hasFx && !parseEffectToken(fxTok.optionValue, cell.effect)) {
        return StepResult(false, ScriptProblem(fxTok.line, fxTok.column, fxTok.length,
            "unknown effect code '" ~ fxTok.optionValue ~ "'", "slideUp", false));
    }
    if (hasFxVal && !parseByteToken(fxValTok.optionValue, cell.effectVal)) {
        return StepResult(false, ScriptProblem(fxValTok.line, fxValTok.column, fxValTok.length,
            "option 'fxval' must be a byte 0..255 or hex 0x00..0xFF", "0", false));
    }

    if (hasParam) {
        uint rawParamId = 0;
        if (parseUint(paramTok.optionValue, rawParamId) && !hasVal) {
            if (rawParamId > ushort.max) {
                return StepResult(false, ScriptProblem(paramTok.line, paramTok.column, paramTok.length,
                    "parameter id is out of range", "1", false));
            }
            cell.paramId = cast(ushort) rawParamId;
        } else {
            if (!hasMod || chosenModId == 0) {
                return StepResult(false, ScriptProblem(paramTok.line, paramTok.column, paramTok.length,
                    "named parameter automation requires module=<handle>", "", false));
            }
            if (!hasVal) {
                return StepResult(false, ScriptProblem(paramTok.line, paramTok.column, paramTok.length,
                    "named param=<name> requires val=<value>", "", false));
            }
            auto modLookup = interp.project().moduleOf(modTok.optionValue);
            if (!modLookup.ok) {
                return StepResult(false, ScriptInterpreter.fromProjectProblem(modLookup.problem, modTok));
            }
            auto copy = modLookup.writer;
            immutable auto edit = copy.setParamText(paramTok.optionValue, valTok.optionValue);
            if (!edit.ok) {
                return StepResult(false, ScriptInterpreter.fromModuleProblem(edit.problem, valTok));
            }
            auto desc = copy.descriptor();
            auto saved = copy.savedModule(modLookup.id);
            size_t pIdx = desc.params.length;
            foreach (pi, ref pd; desc.params) {
                if (namesMatch(pd.name, paramTok.optionValue)) {
                    pIdx = pi;
                    break;
                }
            }
            if (pIdx >= desc.params.length) {
                return StepResult(false, ScriptProblem(paramTok.line, paramTok.column, paramTok.length,
                    "unknown parameter '" ~ paramTok.optionValue ~ "'", "", true));
            }
            immutable auto pd = desc.params[pIdx];
            immutable float span = pd.maxVal - pd.minVal;
            float norm = span > 0.0f ? (saved.paramValues[pIdx] - pd.minVal) / span : 0.0f;
            if (norm < 0.0f) norm = 0.0f;
            if (norm > 1.0f) norm = 1.0f;
            cell.paramId = cast(ushort)(pIdx + 1);
            if (!hasFxVal) {
                cell.effectVal = cast(ubyte)(norm * 255.0f + 0.5f);
            }
        }
    } else if (hasVal) {
        return StepResult(false, ScriptProblem(valTok.line, valTok.column, valTok.length,
            "option 'val' requires param=<name>", "", false));
    }

    immutable PartEditResult writeRes = interp.parts().writeCell(targetPatId, trackIdx, lineIdx, cell);
    if (!writeRes.ok) {
        immutable Token errTok = (writeRes.problem.kind == PartProblemKind.tooManyTracks && hasTrack)
            ? trackTok
            : ((writeRes.problem.kind == PartProblemKind.positionOutOfRange)
                ? (hasLine ? lineTok : atTok) : cmd.commandToken);
        return StepResult(false, ScriptInterpreter.fromPartProblem(writeRes.problem, errTok));
    }
    return StepResult(true);
}

/**
 * Handles: copy <part> [<section>] from=<pos> len=<length> to=<pos> [part=<dst>] [section=<dstSec>] (T106)
 */
private StepResult handleCopy(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token srcPartTok = cmd.args[0];
    immutable bool hasSrcSec = cmd.args.length >= 2;
    immutable string srcSec = hasSrcSec ? cmd.args[1].text : "";
    Token fromTok;
    Token lenTok;
    Token toTok;
    if (!cmd.optionToken("from", fromTok)) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'copy' requires from=<position>", "from=1", false));
    }
    if (!cmd.optionToken("len", lenTok)) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'copy' requires len=<length>", "len=1b", false));
    }
    if (!cmd.optionToken("to", toTok)) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'copy' requires to=<position>", "to=2", false));
    }

    immutable TimeSignature sig = interp.project().timeSignature();
    immutable PositionResult fromRes = parsePosition(fromTok.optionValue, sig);
    if (!fromRes.ok) {
        return StepResult(false, ScriptProblem(fromTok.line, fromTok.column, fromTok.length,
            fromRes.error.reason, fromRes.error.suggestion, false));
    }
    immutable LengthResult lenRes = parseLength(lenTok.optionValue, sig);
    if (!lenRes.ok) {
        return StepResult(false, ScriptProblem(lenTok.line, lenTok.column, lenTok.length,
            lenRes.error.reason, lenRes.error.suggestion, false));
    }
    immutable PositionResult toRes = parsePosition(toTok.optionValue, sig);
    if (!toRes.ok) {
        return StepResult(false, ScriptProblem(toTok.line, toTok.column, toTok.length,
            toRes.error.reason, toRes.error.suggestion, false));
    }

    Token dstPartTok;
    Token dstSecTok;
    immutable bool hasDstPart = cmd.optionToken("part", dstPartTok);
    immutable bool hasDstSec = cmd.optionToken("section", dstSecTok);
    immutable string dstPart = hasDstPart ? dstPartTok.optionValue : srcPartTok.text;
    immutable string dstSec = hasDstSec ? dstSecTok.optionValue : srcSec;

    immutable PartEditResult res = interp.parts().copyRange(srcPartTok.text, srcSec, fromRes.position,
        lenRes.length, dstPart, dstSec, toRes.position);
    if (!res.ok) {
        Token errTok = toTok;
        if (res.problem.kind == PartProblemKind.unknownPart) {
            errTok = hasDstPart && namesMatch(res.problem.subject, dstPart) ? dstPartTok : srcPartTok;
        } else if (res.problem.kind == PartProblemKind.unknownSection) {
            errTok = hasDstSec && namesMatch(res.problem.subject, dstSec)
                ? dstSecTok : (hasSrcSec ? cmd.args[1] : srcPartTok);
        }
        return StepResult(false, ScriptInterpreter.fromPartProblem(res.problem, errTok));
    }
    return StepResult(true);
}

/**
 * Handles: repeat <part> [<section>] [from=<pos>] len=<length> times=<n> (T106)
 */
private StepResult handleRepeat(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token partTok = cmd.args[0];
    immutable bool hasSec = cmd.args.length >= 2;
    immutable string secName = hasSec ? cmd.args[1].text : "";
    Token lenTok;
    Token timesTok;
    if (!cmd.optionToken("len", lenTok)) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'repeat' requires len=<length>", "len=1b", false));
    }
    if (!cmd.optionToken("times", timesTok)) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'repeat' requires times=<count>", "times=1", false));
    }
    immutable TimeSignature sig = interp.project().timeSignature();
    BeatPosition startPos = BeatPosition(1, 1, 1);
    Token fromTok;
    if (cmd.optionToken("from", fromTok)) {
        immutable PositionResult pr = parsePosition(fromTok.optionValue, sig);
        if (!pr.ok) {
            return StepResult(false, ScriptProblem(fromTok.line, fromTok.column, fromTok.length,
                pr.error.reason, pr.error.suggestion, false));
        }
        startPos = pr.position;
    }
    immutable LengthResult lenRes = parseLength(lenTok.optionValue, sig);
    if (!lenRes.ok) {
        return StepResult(false, ScriptProblem(lenTok.line, lenTok.column, lenTok.length,
            lenRes.error.reason, lenRes.error.suggestion, false));
    }
    uint times = 0;
    if (!parseUint(timesTok.optionValue, times)) {
        return StepResult(false, ScriptProblem(timesTok.line, timesTok.column, timesTok.length,
            "option 'times' must be a whole number >= 1", "1", false));
    }

    immutable PartEditResult res = interp.parts().repeatRange(partTok.text, secName, startPos,
        lenRes.length, times);
    if (!res.ok) {
        immutable Token errTok = res.problem.kind == PartProblemKind.unknownPart ? partTok
            : (res.problem.kind == PartProblemKind.unknownSection
                ? (hasSec ? cmd.args[1] : partTok) : timesTok);
        return StepResult(false, ScriptInterpreter.fromPartProblem(res.problem, errTok));
    }
    return StepResult(true);
}

/**
 * Handles: transpose <part> [<section>] [from=<pos>] [len=<length>] [by=<semitones>] [steps=<scaleSteps>] (T106)
 */
private StepResult handleTranspose(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token partTok = cmd.args[0];
    immutable bool hasSec = cmd.args.length >= 2;
    immutable string secName = hasSec ? cmd.args[1].text : "";
    Token byTok;
    Token stepsTok;
    immutable bool hasBy = cmd.optionToken("by", byTok);
    immutable bool hasSteps = cmd.optionToken("steps", stepsTok);
    if (hasBy == hasSteps) {
        immutable Token anchor = hasSteps ? stepsTok : cmd.commandToken;
        return StepResult(false, ScriptProblem(anchor.line, anchor.column, anchor.length,
            "command 'transpose' needs either by=<semitones> or steps=<scaleSteps>", "by=12", false));
    }

    int delta = 0;
    immutable Token deltaTok = hasBy ? byTok : stepsTok;
    if (!parseSignedInt(deltaTok.optionValue, delta)) {
        return StepResult(false, ScriptProblem(deltaTok.line, deltaTok.column, deltaTok.length,
            "transposition offset must be a whole number (e.g. 12 or -2)", "0", false));
    }

    immutable TimeSignature sig = interp.project().timeSignature();
    BeatPosition startPos = BeatPosition(1, 1, 1);
    Token fromTok;
    immutable bool hasFrom = cmd.optionToken("from", fromTok);
    if (hasFrom) {
        immutable PositionResult pr = parsePosition(fromTok.optionValue, sig);
        if (!pr.ok) {
            return StepResult(false, ScriptProblem(fromTok.line, fromTok.column, fromTok.length,
                pr.error.reason, pr.error.suggestion, false));
        }
        startPos = pr.position;
    }

    Length rangeLen;
    Token lenTok;
    immutable bool hasLen = cmd.optionToken("len", lenTok);
    if (hasLen) {
        immutable LengthResult lr = parseLength(lenTok.optionValue, sig);
        if (!lr.ok) {
            return StepResult(false, ScriptProblem(lenTok.line, lenTok.column, lenTok.length,
                lr.error.reason, lr.error.suggestion, false));
        }
        rangeLen = lr.length;
    } else {
        uint secLines = 0;
        bool hasPat = false;
        PartProblem prob;
        if (!resolvePhraseTargetLength(interp, partTok.text, secName, secLines, hasPat, prob)) {
            immutable Token errTok = prob.kind == PartProblemKind.unknownPart ? partTok
                : (hasSec ? cmd.args[1] : partTok);
            return StepResult(false, ScriptInterpreter.fromPartProblem(prob, errTok));
        }
        import compose.timing : LinesResult;
        immutable LinesResult startRes = positionToLine(startPos, sig);
        if (!startRes.ok || startRes.lines >= secLines) {
            return StepResult(false, ScriptProblem(hasFrom ? fromTok.line : cmd.commandToken.line,
                hasFrom ? fromTok.column : cmd.commandToken.column,
                hasFrom ? fromTok.length : cmd.commandToken.length,
                "start position is outside section", "1", false));
        }
        rangeLen = Length(secLines - startRes.lines);
    }

    immutable PartEditResult res = hasBy
        ? interp.parts().transposeRange(partTok.text, secName, startPos, rangeLen, delta)
        : interp.parts().transposeRangeScaleSteps(partTok.text, secName, startPos, rangeLen, delta);
    if (!res.ok) {
        Token errTok = deltaTok;
        if (res.problem.kind == PartProblemKind.unknownPart) {
            errTok = partTok;
        } else if (res.problem.kind == PartProblemKind.unknownSection) {
            errTok = hasSec ? cmd.args[1] : partTok;
        } else if (res.problem.kind == PartProblemKind.positionOutOfRange && hasLen) {
            errTok = lenTok;
        }
        return StepResult(false, ScriptInterpreter.fromPartProblem(res.problem, errTok));
    }
    return StepResult(true);
}

/**
 * Handles: clear <part> [<section>] [from=<pos>] [len=<length>] (T106)
 */
private StepResult handleClear(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    immutable Token partTok = cmd.args[0];
    immutable bool hasSec = cmd.args.length >= 2;
    immutable string secName = hasSec ? cmd.args[1].text : "";
    immutable TimeSignature sig = interp.project().timeSignature();
    BeatPosition startPos = BeatPosition(1, 1, 1);
    Token fromTok;
    immutable bool hasFrom = cmd.optionToken("from", fromTok);
    if (hasFrom) {
        immutable PositionResult pr = parsePosition(fromTok.optionValue, sig);
        if (!pr.ok) {
            return StepResult(false, ScriptProblem(fromTok.line, fromTok.column, fromTok.length,
                pr.error.reason, pr.error.suggestion, false));
        }
        startPos = pr.position;
    }
    Length rangeLen;
    Token lenTok;
    immutable bool hasLen = cmd.optionToken("len", lenTok);
    if (hasLen) {
        immutable LengthResult lr = parseLength(lenTok.optionValue, sig);
        if (!lr.ok) {
            return StepResult(false, ScriptProblem(lenTok.line, lenTok.column, lenTok.length,
                lr.error.reason, lr.error.suggestion, false));
        }
        rangeLen = lr.length;
    } else {
        uint secLines = 0;
        bool hasPat = false;
        PartProblem prob;
        if (!resolvePhraseTargetLength(interp, partTok.text, secName, secLines, hasPat, prob)) {
            immutable Token errTok = prob.kind == PartProblemKind.unknownPart ? partTok
                : (hasSec ? cmd.args[1] : partTok);
            return StepResult(false, ScriptInterpreter.fromPartProblem(prob, errTok));
        }
        import compose.timing : LinesResult;
        immutable LinesResult startRes = positionToLine(startPos, sig);
        if (!startRes.ok || startRes.lines >= secLines) {
            return StepResult(false, ScriptProblem(hasFrom ? fromTok.line : cmd.commandToken.line,
                hasFrom ? fromTok.column : cmd.commandToken.column,
                hasFrom ? fromTok.length : cmd.commandToken.length,
                "start position is outside section", "1", false));
        }
        rangeLen = Length(secLines - startRes.lines);
    }

    immutable PartEditResult res = interp.parts().clearRange(partTok.text, secName, startPos, rangeLen);
    if (!res.ok) {
        Token errTok = hasLen ? lenTok : partTok;
        if (res.problem.kind == PartProblemKind.unknownPart) {
            errTok = partTok;
        } else if (res.problem.kind == PartProblemKind.unknownSection) {
            errTok = hasSec ? cmd.args[1] : partTok;
        }
        return StepResult(false, ScriptInterpreter.fromPartProblem(res.problem, errTok));
    }
    return StepResult(true);
}

private ScriptProblem mapOffsetToSpan(const(NoteSpan)[] spans, const(Token)[] toks, uint colonLine,
        uint colonCol, size_t offset, size_t len, string reason, string suggestion, bool isName)
        @safe pure nothrow {
    foreach (i, ref sp; spans) {
        if (offset >= sp.joinedStart && offset < sp.joinedEnd) {
            immutable uint quoteBump = (i < toks.length && toks[i].kind == TokenKind.quoted) ? 1 : 0;
            immutable uint col = sp.column + quoteBump + cast(uint)(offset - sp.joinedStart);
            immutable size_t avail = sp.joinedEnd - offset;
            immutable uint spanLen = len > 0 && len <= avail ? cast(uint) len : (avail > 0 ? cast(uint) avail : 1);
            return ScriptProblem(sp.line, col, spanLen, reason, suggestion, isName);
        }
    }
    if (spans.length > 0) {
        return ScriptProblem(spans[0].line, spans[0].column, spans[0].length, reason, suggestion, isName);
    }
    return ScriptProblem(colonLine, colonCol, 1, reason, suggestion, isName);
}

/**
 * Handles: chords <part> [<section>] [at=<pos>]: <progression> [options...] (T105)
 */
private StepResult handleChords(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    if (!cmd.hasColon && !cmd.hasOption("preset")) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, "command 'chords' needs ':' before the chord progression", "", false));
    }
    immutable Token partTok = cmd.args[0];
    immutable bool hasSection = cmd.args.length >= 2;
    immutable string sectionName = hasSection ? cmd.args[1].text : "";
    immutable Token secTok = hasSection ? cmd.args[1] : partTok;

    static immutable string[10] CHORD_OPT_NAMES = [
        "at", "style", "octave", "voices", "voicing", "every", "dir", "rhythm", "preset", "vel"
    ];

    Token[string] optMap;
    Token[] progTokens;
    foreach (ref tok; cmd.options) {
        foreach (optName; CHORD_OPT_NAMES) {
            if (namesMatch(tok.optionName, optName)) {
                optMap[optName] = tok;
                break;
            }
        }
    }
    foreach (ref tok; cmd.tailTokens) {
        if (tok.kind == TokenKind.option) {
            string matched = "";
            foreach (optName; CHORD_OPT_NAMES) {
                if (namesMatch(tok.optionName, optName)) {
                    matched = optName;
                    break;
                }
            }
            if (matched.length == 0) {
                return StepResult(false, ScriptProblem(tok.line, tok.column, tok.length,
                    "command 'chords' does not accept option '" ~ tok.optionName ~ "'",
                    nearestName(tok.optionName, CHORD_OPT_NAMES[]), true));
            }
            if ((matched in optMap) !is null) {
                return StepResult(false, ScriptProblem(tok.line, tok.column, tok.length,
                    "option '" ~ tok.optionName ~ "' was given more than once", "", false));
            }
            optMap[matched] = tok;
        } else {
            progTokens ~= tok;
        }
    }

    immutable TimeSignature sig = interp.project().timeSignature();
    BeatPosition startPos = BeatPosition(1, 1, 1);
    if (auto atTok = "at" in optMap) {
        immutable PositionResult pr = parsePosition(atTok.optionValue, sig);
        if (!pr.ok) {
            return StepResult(false, ScriptProblem(atTok.line, atTok.column, atTok.length,
                pr.error.reason, pr.error.suggestion, false));
        }
        startPos = pr.position;
    }

    ChordOptions opts;
    if (auto styleTok = "style" in optMap) {
        ChordProblem sProb;
        if (!parseChordStyle(styleTok.optionValue, opts.style, sProb)) {
            return StepResult(false, ScriptProblem(styleTok.line, styleTok.column, styleTok.length,
                sProb.reason, sProb.suggestion, true));
        }
    }
    if (auto octTok = "octave" in optMap) {
        int oct = 4;
        if (!parseSignedInt(octTok.optionValue, oct)) {
            return StepResult(false, ScriptProblem(octTok.line, octTok.column, octTok.length,
                "option 'octave' must be a whole octave number", "4", false));
        }
        opts.hasOctave = true;
        opts.octave = oct;
    }
    if (auto voicesTok = "voices" in optMap) {
        uint vc = 0;
        if (!parseUint(voicesTok.optionValue, vc) || (vc != 3 && vc != 4)) {
            return StepResult(false, ScriptProblem(voicesTok.line, voicesTok.column, voicesTok.length,
                "option 'voices' must be 3 or 4", "3", false));
        }
        opts.voices = cast(ubyte) vc;
    }
    if (auto voicingTok = "voicing" in optMap) {
        ChordProblem vProb;
        if (!parseChordVoicing(voicingTok.optionValue, opts.voicing, vProb)) {
            return StepResult(false, ScriptProblem(voicingTok.line, voicingTok.column, voicingTok.length,
                vProb.reason, vProb.suggestion, true));
        }
    }
    if (auto everyTok = "every" in optMap) {
        immutable LengthResult lr = parseLength(everyTok.optionValue, sig);
        if (!lr.ok) {
            return StepResult(false, ScriptProblem(everyTok.line, everyTok.column, everyTok.length,
                lr.error.reason, lr.error.suggestion, false));
        }
        opts.every = lr.length;
    }
    if (auto dirTok = "dir" in optMap) {
        ChordProblem dProb;
        if (!parseArpDirection(dirTok.optionValue, opts.arpDir, dProb)) {
            return StepResult(false, ScriptProblem(dirTok.line, dirTok.column, dirTok.length,
                dProb.reason, dProb.suggestion, true));
        }
    }
    Token rhythmTok;
    immutable bool hasRhythm = ("rhythm" in optMap) !is null;
    if (hasRhythm) {
        rhythmTok = optMap["rhythm"];
        opts.rhythm = rhythmTok.optionValue;
    }
    if (auto velTok = "vel" in optMap) {
        double v = 0.0;
        if (!parseDecimal(velTok.optionValue, v) || v <= 0.0 || v > 1.0) {
            return StepResult(false, ScriptProblem(velTok.line, velTok.column, velTok.length,
                "option 'vel' must be a number in (0, 1]", "0.8", false));
        }
        opts.velocity = cast(float) v;
    }

    Token presetTok;
    immutable bool hasPreset = ("preset" in optMap) !is null;
    if (hasPreset) {
        presetTok = optMap["preset"];
        if (progTokens.length > 0) {
            return StepResult(false, ScriptProblem(presetTok.line, presetTok.column, presetTok.length,
                "give either chord progression tokens or preset=<name>, not both", "", false));
        }
    } else if (progTokens.length == 0) {
        return StepResult(false, ScriptProblem(cmd.colonLine, cmd.colonColumn, 1,
            "command 'chords' needs a chord progression or preset=<name>", "I - IV - V", false));
    }

    NoteSpan[] spans;
    immutable string joinedProg = buildNoteSpans(progTokens, spans);
    immutable ChordWriteResult res = hasPreset
        ? writePresetChords(interp.parts(), partTok.text, sectionName, presetTok.optionValue, opts, startPos)
        : writeChords(interp.parts(), partTok.text, sectionName, joinedProg, opts, startPos);

    if (!res.ok) {
        if (res.problem.kind == ChordProblemKind.unknownPreset && hasPreset) {
            return StepResult(false, ScriptProblem(presetTok.line, presetTok.column, presetTok.length,
                res.problem.reason, res.problem.suggestion, true));
        }
        if (res.problem.kind == ChordProblemKind.invalidRhythm && hasRhythm) {
            immutable uint qOff = rhythmTok.valueQuoted ? 1 : 0;
            immutable uint valStart = cast(uint)(rhythmTok.column + rhythmTok.optionName.length + 1 + qOff);
            immutable uint errCol = res.problem.length > 0
                ? valStart + cast(uint) res.problem.offset : rhythmTok.column;
            immutable uint errLen = res.problem.length > 0 ? cast(uint) res.problem.length : rhythmTok.length;
            return StepResult(false, ScriptProblem(rhythmTok.line, errCol, errLen,
                res.problem.reason, res.problem.suggestion, false));
        }
        if (res.problem.kind == ChordProblemKind.progressionTooLong && hasPreset) {
            return StepResult(false, ScriptProblem(presetTok.line, presetTok.column, presetTok.length,
                res.problem.reason, "", false));
        }
        if (res.problem.kind == ChordProblemKind.pitchOutOfRange) {
            if (auto octTok = "octave" in optMap) {
                return StepResult(false, ScriptProblem(octTok.line, octTok.column, octTok.length,
                    res.problem.reason, res.problem.suggestion, false));
            }
        }
        if (res.problem.kind == ChordProblemKind.partError) {
            if (namesMatch(res.problem.subject, partTok.text)) {
                return StepResult(false, ScriptProblem(partTok.line, partTok.column, partTok.length,
                    res.problem.reason, res.problem.suggestion, true));
            }
            if (hasSection && namesMatch(res.problem.subject, sectionName)) {
                return StepResult(false, ScriptProblem(secTok.line, secTok.column, secTok.length,
                    res.problem.reason, res.problem.suggestion, true));
            }
            if (!hasSection && trim(res.problem.subject).length == 0) {
                return StepResult(false, ScriptProblem(partTok.line, partTok.column, partTok.length,
                    res.problem.reason, res.problem.suggestion, true));
            }
        }
        if (res.problem.length > 0 && progTokens.length > 0) {
            return StepResult(false, mapOffsetToSpan(spans, progTokens, cmd.colonLine, cmd.colonColumn,
                res.problem.offset, res.problem.length, res.problem.reason, res.problem.suggestion, false));
        }
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, res.problem.reason, res.problem.suggestion,
            res.problem.kind == ChordProblemKind.partError));
    }
    return StepResult(true);
}

/**
 * Handles:
 *   drums <part> module=<handle>
 *   drums <part> lane=<laneName> module=<handle> note=<pitch|midi>
 *   drums <part> [<section>] <lane>: <steps> [at=] [vel=] [accent=] [ghost=] [fill=<a>-<b>] (T105)
 */
private StepResult handleDrums(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    if (!cmd.hasColon) {
        if (cmd.args.length != 1) {
            return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
                cmd.commandToken.length,
                "drum declaration takes <part> with module=<handle> (and optional lane=/note=)", "", false));
        }
        immutable Token partTok = cmd.args[0];
        Token laneTok;
        Token modTok;
        Token noteTok;
        immutable bool hasLane = cmd.optionToken("lane", laneTok);
        immutable bool hasMod = cmd.optionToken("module", modTok);
        immutable bool hasNote = cmd.optionToken("note", noteTok);

        if (hasLane) {
            if (!hasMod || !hasNote) {
                return StepResult(false, ScriptProblem(laneTok.line, laneTok.column, laneTok.length,
                    "adding a drum lane requires lane=<name> module=<handle> note=<pitch>", "", false));
            }
            int midi = 36;
            if (!parseMidiNoteOption(noteTok.optionValue, midi)) {
                return StepResult(false, ScriptProblem(noteTok.line, noteTok.column, noteTok.length,
                    "option 'note' must be a MIDI note 0..127 or pitch spelling (e.g. C3)", "36", false));
            }
            if (!interp.drums().hasDrumPart(partTok.text)) {
                immutable DrumEditResult addPartRes = interp.drums().addDrumPart(partTok.text, "");
                if (!addPartRes.ok) {
                    return StepResult(false, ScriptProblem(partTok.line, partTok.column, partTok.length,
                        addPartRes.problem.reason, addPartRes.problem.suggestion, true));
                }
            }
            immutable DrumEditResult addLaneRes = interp.drums().addLane(partTok.text, laneTok.optionValue,
                modTok.optionValue, cast(ubyte) midi);
            if (!addLaneRes.ok) {
                immutable Token errTok = addLaneRes.problem.kind == DrumProblemKind.unknownModule
                    ? modTok : laneTok;
                return StepResult(false, ScriptProblem(errTok.line, errTok.column, errTok.length,
                    addLaneRes.problem.reason, addLaneRes.problem.suggestion, true));
            }
            return StepResult(true);
        }

        if (!hasMod) {
            return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
                cmd.commandToken.length,
                "drum declaration needs module=<handle> or ':' with step notation", "", false));
        }
        immutable DrumEditResult addRes = interp.drums().addDrumPart(partTok.text, modTok.optionValue);
        if (!addRes.ok) {
            immutable Token errTok = addRes.problem.kind == DrumProblemKind.unknownModule ? modTok : partTok;
            return StepResult(false, ScriptProblem(errTok.line, errTok.column, errTok.length,
                addRes.problem.reason, addRes.problem.suggestion, true));
        }
        return StepResult(true);
    }

    if (cmd.args.length < 2) {
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length,
            "command 'drums' needs <part> [<section>] <lane>: <steps>", "", false));
    }

    immutable Token partTok = cmd.args[0];
    immutable bool hasSection = cmd.args.length >= 3;
    immutable string sectionName = hasSection ? cmd.args[1].text : "";
    immutable Token secTok = hasSection ? cmd.args[1] : partTok;
    immutable Token laneTok = hasSection ? cmd.args[2] : cmd.args[1];

    static immutable string[5] DRUM_OPT_NAMES = ["at", "vel", "accent", "ghost", "fill"];
    Token[string] optMap;
    Token[] stepTokens;
    foreach (ref tok; cmd.options) {
        foreach (optName; DRUM_OPT_NAMES) {
            if (namesMatch(tok.optionName, optName)) {
                optMap[optName] = tok;
                break;
            }
        }
    }
    foreach (ref tok; cmd.tailTokens) {
        if (tok.kind == TokenKind.option) {
            string matched = "";
            foreach (optName; DRUM_OPT_NAMES) {
                if (namesMatch(tok.optionName, optName)) {
                    matched = optName;
                    break;
                }
            }
            if (matched.length == 0) {
                return StepResult(false, ScriptProblem(tok.line, tok.column, tok.length,
                    "command 'drums' does not accept option '" ~ tok.optionName ~ "'",
                    nearestName(tok.optionName, DRUM_OPT_NAMES[]), true));
            }
            if ((matched in optMap) !is null) {
                return StepResult(false, ScriptProblem(tok.line, tok.column, tok.length,
                    "option '" ~ tok.optionName ~ "' was given more than once", "", false));
            }
            optMap[matched] = tok;
        } else {
            stepTokens ~= tok;
        }
    }

    if (stepTokens.length == 0) {
        return StepResult(false, ScriptProblem(cmd.colonLine, cmd.colonColumn, 1,
            "command 'drums' needs a step string after ':' (e.g. x---x---)", "x---", false));
    }

    double vel = 0.8;
    double accentVel = 1.0;
    double ghostVel = 0.45;
    if (auto velTok = "vel" in optMap) {
        if (!parseDecimal(velTok.optionValue, vel) || vel <= 0.0 || vel > 1.0) {
            return StepResult(false, ScriptProblem(velTok.line, velTok.column, velTok.length,
                "option 'vel' must be a number in (0, 1]", "0.8", false));
        }
    }
    if (auto accTok = "accent" in optMap) {
        if (!parseDecimal(accTok.optionValue, accentVel) || accentVel <= 0.0 || accentVel > 1.0) {
            return StepResult(false, ScriptProblem(accTok.line, accTok.column, accTok.length,
                "option 'accent' must be a number in (0, 1]", "1.0", false));
        }
    }
    if (auto ghTok = "ghost" in optMap) {
        if (!parseDecimal(ghTok.optionValue, ghostVel) || ghostVel <= 0.0 || ghostVel > 1.0) {
            return StepResult(false, ScriptProblem(ghTok.line, ghTok.column, ghTok.length,
                "option 'ghost' must be a number in (0, 1]", "0.45", false));
        }
    }

    NoteSpan[] spans;
    immutable string joinedSteps = buildNoteSpans(stepTokens, spans);

    DrumEditResult res;
    if (auto fillTok = "fill" in optMap) {
        immutable string fv = trim(fillTok.optionValue);
        size_t dash = fv.length;
        foreach (i, char c; fv) {
            if (c == '-') {
                dash = i;
                break;
            }
        }
        uint startBar = 0;
        uint endBar = 0;
        if (dash == fv.length) {
            if (!parseUint(fv, startBar)) {
                return StepResult(false, ScriptProblem(fillTok.line, fillTok.column, fillTok.length,
                    "option 'fill' must be a bar number or start-end range (e.g. 2 or 1-4)", "1-2", false));
            }
            endBar = startBar;
        } else {
            if (!parseUint(fv[0 .. dash], startBar) || !parseUint(fv[dash + 1 .. $], endBar)) {
                return StepResult(false, ScriptProblem(fillTok.line, fillTok.column, fillTok.length,
                    "option 'fill' must use whole bar numbers (e.g. 1-4)", "1-2", false));
            }
        }
        res = interp.drums().writeFill(partTok.text, sectionName, laneTok.text, startBar, endBar,
            joinedSteps, cast(float) vel, cast(float) accentVel, cast(float) ghostVel);
    } else {
        BeatPosition startPos = BeatPosition(1, 1, 1);
        if (auto atTok = "at" in optMap) {
            immutable PositionResult pr = parsePosition(atTok.optionValue, interp.project().timeSignature());
            if (!pr.ok) {
                return StepResult(false, ScriptProblem(atTok.line, atTok.column, atTok.length,
                    pr.error.reason, pr.error.suggestion, false));
            }
            startPos = pr.position;
        }
        res = interp.drums().writeSteps(partTok.text, sectionName, laneTok.text, joinedSteps,
            startPos, cast(float) vel, cast(float) accentVel, cast(float) ghostVel);
    }

    if (!res.ok) {
        if (res.problem.kind == DrumProblemKind.unknownPart) {
            return StepResult(false, ScriptProblem(partTok.line, partTok.column, partTok.length,
                res.problem.reason, res.problem.suggestion, true));
        }
        if (res.problem.kind == DrumProblemKind.unknownSection) {
            return StepResult(false, ScriptProblem(secTok.line, secTok.column, secTok.length,
                res.problem.reason, res.problem.suggestion, true));
        }
        if (res.problem.kind == DrumProblemKind.unknownLane) {
            return StepResult(false, ScriptProblem(laneTok.line, laneTok.column, laneTok.length,
                res.problem.reason, res.problem.suggestion, true));
        }
        if (res.problem.kind == DrumProblemKind.invalidStep && res.problem.length > 0) {
            return StepResult(false, mapOffsetToSpan(spans, stepTokens, cmd.colonLine, cmd.colonColumn,
                res.problem.offset, res.problem.length, res.problem.reason, res.problem.suggestion, false));
        }
        if (res.problem.kind == DrumProblemKind.invalidBarRange) {
            if (auto fillTok = "fill" in optMap) {
                return StepResult(false, ScriptProblem(fillTok.line, fillTok.column, fillTok.length,
                    res.problem.reason, res.problem.suggestion, false));
            }
        }
        if (res.problem.kind == DrumProblemKind.positionOutOfRange) {
            if (auto atTok = "at" in optMap) {
                return StepResult(false, ScriptProblem(atTok.line, atTok.column, atTok.length,
                    res.problem.reason, res.problem.suggestion, false));
            }
        }
        return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
            cmd.commandToken.length, res.problem.reason, res.problem.suggestion, false));
    }
    return StepResult(true);
}

/**
 * Registers the composition script commands (project properties, open, module/wire management, and
 * T104 section/part/notes/arrange/loop commands) on an interpreter.
 *
 * Params:
 *   interp = Interpreter to register commands on.
 */
void registerCoreCommands(ScriptInterpreter interp) @safe nothrow {
    interp.registerCommand(
        CommandSpec(
            "project",
            "Set the project title",
            [CommandArgSpec("title", ArgKind.text, true, "Project title (up to 65536 bytes)")],
            []
        ),
        &handleProject
    );
    interp.registerCommand(
        CommandSpec(
            "title",
            "Set the project title (the same as 'project', and allowed in the app's Script tab)",
            [CommandArgSpec("title", ArgKind.text, true, "Project title (up to 65536 bytes)")],
            []
        ),
        &handleProject
    );
    interp.registerCommand(
        CommandSpec(
            "open",
            "Open an existing .msv project file as the starting point of the script",
            [CommandArgSpec("path", ArgKind.path, true, "Existing .msv project file path")],
            []
        ),
        &handleOpen
    );
    interp.registerCommand(
        CommandSpec(
            "tempo",
            "Set tempo in beats per minute and optional ticks per line",
            [CommandArgSpec("bpm", ArgKind.number, true, "Beats per minute (20 to 999)")],
            [CommandOptionSpec("tpl", ArgKind.integer, "Ticks per line (1 to 255)")]
        ),
        &handleTempo
    );
    interp.registerCommand(
        CommandSpec(
            "signature",
            "Set the time signature",
            [CommandArgSpec("signature", ArgKind.timeSignature, true, "Numerator/denominator, e.g. 4/4 or 6/8")],
            []
        ),
        &handleSignature
    );
    interp.registerCommand(
        CommandSpec(
            "key",
            "Set the song key (tonic and optional major/minor mode)",
            [
                CommandArgSpec("tonic", ArgKind.key, true, "Note name A..G with optional # or b, or quoted key"),
                CommandArgSpec("mode", ArgKind.word, false, "Optional 'major' or 'minor'")
            ],
            []
        ),
        &handleKey
    );
    interp.registerCommand(
        CommandSpec(
            "module",
            "Add a module under a handle from a type id, display name, preset, .msym file, or keep reference",
            [
                CommandArgSpec("handle", ArgKind.word, true, "Module handle name"),
                CommandArgSpec("type", ArgKind.text, false, "Module type id or display name")
            ],
            [
                CommandOptionSpec("preset", ArgKind.text, "Preset name or Group/Name"),
                CommandOptionSpec("file", ArgKind.path, "Path to a .msym preset file"),
                CommandOptionSpec("keep", ArgKind.path, "Keep opaque module data from '<file.msv>:<id>' or '<file.msym>'"),
                CommandOptionSpec("name", ArgKind.text, "Optional displayed module name differing from handle"),
                CommandOptionSpec("x", ArgKind.number, "Canvas X position"),
                CommandOptionSpec("y", ArgKind.number, "Canvas Y position")
            ]
        ),
        &handleModule
    );
    interp.registerCommand(
        CommandSpec(
            "set",
            "Set one or more parameters on a module (Param=Value options or <param> <value>)",
            [
                CommandArgSpec("handle", ArgKind.word, true, "Target module handle"),
                CommandArgSpec("param", ArgKind.text, false, "Optional single parameter name"),
                CommandArgSpec("value", ArgKind.text, false, "Optional single parameter value")
            ],
            [],
            true
        ),
        &handleSet
    );
    interp.registerCommand(
        CommandSpec(
            "preset",
            "Apply a bundled/user preset or .msym file onto an existing module",
            [
                CommandArgSpec("handle", ArgKind.word, true, "Target module handle"),
                CommandArgSpec("name", ArgKind.text, false, "Preset name or Group/Name")
            ],
            [CommandOptionSpec("file", ArgKind.path, "Path to a .msym preset file")]
        ),
        &handlePreset
    );
    interp.registerCommand(
        CommandSpec(
            "sample",
            "Load an audio file into a Sampler module slot",
            [
                CommandArgSpec("handle", ArgKind.word, true, "Target Sampler handle"),
                CommandArgSpec("path", ArgKind.path, true, "Audio sample file path")
            ],
            [
                CommandOptionSpec("slot", ArgKind.integer, "Sample slot (0 to 15)"),
                CommandOptionSpec("root", ArgKind.text, "Root MIDI note or pitch name (default C4 / 60)"),
                CommandOptionSpec("low", ArgKind.text, "Lowest MIDI note or pitch name (default 0)"),
                CommandOptionSpec("high", ArgKind.text, "Highest MIDI note or pitch name (default 127)")
            ]
        ),
        &handleSample
    );
    interp.registerCommand(
        CommandSpec(
            "savemodule",
            "Save a module as an .msym preset file",
            [
                CommandArgSpec("handle", ArgKind.word, true, "Module handle to save"),
                CommandArgSpec("path", ArgKind.path, true, "Destination .msym file path")
            ],
            []
        ),
        &handleSaveModule
    );
    interp.registerCommand(
        CommandSpec(
            "connect",
            "Connect an output port on src to an input port on dst",
            [
                CommandArgSpec("src", ArgKind.word, true, "Source module handle"),
                CommandArgSpec("dst", ArgKind.word, true, "Destination module handle")
            ],
            [
                CommandOptionSpec("gain", ArgKind.number, "Linear wire gain >= 0 (default 1)"),
                CommandOptionSpec("from", ArgKind.text, "Source output port id or name"),
                CommandOptionSpec("to", ArgKind.text, "Destination input port id or name")
            ]
        ),
        &handleConnect
    );
    interp.registerCommand(
        CommandSpec(
            "disconnect",
            "Remove a wire between src and dst",
            [
                CommandArgSpec("src", ArgKind.word, true, "Source module handle"),
                CommandArgSpec("dst", ArgKind.word, true, "Destination module handle")
            ],
            [
                CommandOptionSpec("from", ArgKind.text, "Source output port id or name"),
                CommandOptionSpec("to", ArgKind.text, "Destination input port id or name")
            ]
        ),
        &handleDisconnect
    );
    interp.registerCommand(
        CommandSpec(
            "remove",
            "Remove a module and its connected wires",
            [CommandArgSpec("handle", ArgKind.word, true, "Module handle to remove")],
            []
        ),
        &handleRemove
    );
    interp.registerCommand(
        CommandSpec(
            "section",
            "Declare a named song section with a length in bars",
            [CommandArgSpec("name", ArgKind.text, true, "Section name")],
            [CommandOptionSpec("bars", ArgKind.integer, "Section length in bars (>= 1)")]
        ),
        &handleSection
    );
    interp.registerCommand(
        CommandSpec(
            "part",
            "Declare a melodic or drum part bound to a module handle",
            [CommandArgSpec("name", ArgKind.text, true, "Part name")],
            [
                CommandOptionSpec("module", ArgKind.word, "Module handle name for a melodic part"),
                CommandOptionSpec("drums", ArgKind.word, "DrumSynth handle name for a drum part")
            ]
        ),
        &handlePart
    );
    interp.registerCommand(
        CommandSpec(
            "notes",
            "Write notes, chords, and rests into a part's section pattern",
            [
                CommandArgSpec("part", ArgKind.text, true, "Part name"),
                CommandArgSpec("section", ArgKind.text, false, "Section name (omit for implicit section)")
            ],
            [CommandOptionSpec("at", ArgKind.text, "Start position inside section (default 1)")],
            false,
            false,
            true
        ),
        &handleNotes
    );
    interp.registerCommand(
        CommandSpec(
            "chords",
            "Realize and write a chord progression into a part's section pattern",
            [
                CommandArgSpec("part", ArgKind.text, true, "Part name"),
                CommandArgSpec("section", ArgKind.text, false, "Section name (omit for implicit section)")
            ],
            [
                CommandOptionSpec("at", ArgKind.text, "Start position inside section (default 1)"),
                CommandOptionSpec("style", ArgKind.word, "Playing style: hold, pulse, arp, root, root5"),
                CommandOptionSpec("octave", ArgKind.integer, "Base root octave (default 4, or 2 for bass)"),
                CommandOptionSpec("voices", ArgKind.integer, "Voice count: 3 or 4"),
                CommandOptionSpec("voicing", ArgKind.word, "Voicing: root or close"),
                CommandOptionSpec("every", ArgKind.text, "Repeat/arp step interval length"),
                CommandOptionSpec("dir", ArgKind.word, "Arp direction: up, down, updown"),
                CommandOptionSpec("rhythm", ArgKind.text, "Sixteenth rhythm pattern combined with hold/root/pulse"),
                CommandOptionSpec("preset", ArgKind.text, "Bundled progression preset name"),
                CommandOptionSpec("vel", ArgKind.number, "Normalized note velocity in (0, 1]")
            ],
            false,
            false,
            true
        ),
        &handleChords
    );
    interp.registerCommand(
        CommandSpec(
            "drums",
            "Declare drum parts/lanes or write step strings and bar fills on a drum lane",
            [
                CommandArgSpec("part", ArgKind.text, true, "Drum part name"),
                CommandArgSpec("section", ArgKind.text, false, "Section name (when 3 args before ':') or lane"),
                CommandArgSpec("lane", ArgKind.text, false, "Drum lane name (when section is given)")
            ],
            [
                CommandOptionSpec("module", ArgKind.word, "Target module handle (when declaring part or lane)"),
                CommandOptionSpec("lane", ArgKind.text, "Drum lane name (when adding a custom lane)"),
                CommandOptionSpec("note", ArgKind.text, "MIDI note or pitch for a custom drum lane"),
                CommandOptionSpec("at", ArgKind.text, "Start position for step pattern (default 1)"),
                CommandOptionSpec("vel", ArgKind.number, "Normal step velocity in (0, 1]"),
                CommandOptionSpec("accent", ArgKind.number, "Accent ('X') velocity in (0, 1]"),
                CommandOptionSpec("ghost", ArgKind.number, "Ghost ('g') velocity in (0, 1]"),
                CommandOptionSpec("fill", ArgKind.text, "1-based bar or start-end range for repeating fill")
            ],
            false,
            false,
            true
        ),
        &handleDrums
    );
    interp.registerCommand(
        CommandSpec(
            "cells",
            "Write raw tracker pattern cells or declare standalone tracker patterns",
            [
                CommandArgSpec("target", ArgKind.text, true, "Part name or standalone pattern name"),
                CommandArgSpec("section", ArgKind.text, false, "Section name when targeting a part")
            ],
            [
                CommandOptionSpec("tracks", ArgKind.integer, "Track count (creates raw tracker pattern)"),
                CommandOptionSpec("lines", ArgKind.integer, "Line count (creates raw tracker pattern)"),
                CommandOptionSpec("track", ArgKind.integer, "0-based track index (default 0)"),
                CommandOptionSpec("line", ArgKind.integer, "0-based line index"),
                CommandOptionSpec("at", ArgKind.text, "Beat position (alternative to line=)"),
                CommandOptionSpec("note", ArgKind.text, "Pitch (C4) or command (off, alloff, prev, setpitch, stop, none)"),
                CommandOptionSpec("vel", ArgKind.number, "Normalized velocity in (0, 1]"),
                CommandOptionSpec("velbyte", ArgKind.integer, "Raw velocity byte 0..255"),
                CommandOptionSpec("module", ArgKind.word, "Target module handle or 'none'"),
                CommandOptionSpec("param", ArgKind.text, "Parameter name (with val=) or raw numeric paramId"),
                CommandOptionSpec("val", ArgKind.text, "Parameter text value for named automation"),
                CommandOptionSpec("fx", ArgKind.text, "Effect code name or byte (e.g. slideUp or 0x01)"),
                CommandOptionSpec("fxval", ArgKind.text, "Effect operand byte 0..255 or 0x00..0xFF")
            ]
        ),
        &handleCells
    );
    interp.registerCommand(
        CommandSpec(
            "copy",
            "Copy a range of part notes to another position, part, or section",
            [
                CommandArgSpec("part", ArgKind.text, true, "Source part name"),
                CommandArgSpec("section", ArgKind.text, false, "Source section name")
            ],
            [
                CommandOptionSpec("from", ArgKind.text, "Source start position"),
                CommandOptionSpec("len", ArgKind.text, "Range length (beats, bars 'b', or lines 'l')"),
                CommandOptionSpec("to", ArgKind.text, "Destination start position"),
                CommandOptionSpec("part", ArgKind.text, "Optional destination part name"),
                CommandOptionSpec("section", ArgKind.text, "Optional destination section name")
            ]
        ),
        &handleCopy
    );
    interp.registerCommand(
        CommandSpec(
            "repeat",
            "Repeat a range of part notes consecutively",
            [
                CommandArgSpec("part", ArgKind.text, true, "Part name"),
                CommandArgSpec("section", ArgKind.text, false, "Section name")
            ],
            [
                CommandOptionSpec("from", ArgKind.text, "Range start position (default 1)"),
                CommandOptionSpec("len", ArgKind.text, "Range length"),
                CommandOptionSpec("times", ArgKind.integer, "Number of additional copies (>= 1)")
            ]
        ),
        &handleRepeat
    );
    interp.registerCommand(
        CommandSpec(
            "transpose",
            "Transpose a range of part notes by semitones or key scale steps",
            [
                CommandArgSpec("part", ArgKind.text, true, "Part name"),
                CommandArgSpec("section", ArgKind.text, false, "Section name")
            ],
            [
                CommandOptionSpec("from", ArgKind.text, "Range start position (default 1)"),
                CommandOptionSpec("len", ArgKind.text, "Range length (default remainder of section)"),
                CommandOptionSpec("by", ArgKind.integer, "Chromatic semitone delta"),
                CommandOptionSpec("steps", ArgKind.integer, "Diatonic scale-step delta in project key")
            ]
        ),
        &handleTranspose
    );
    interp.registerCommand(
        CommandSpec(
            "clear",
            "Clear notes and cells inside a range of a part's section pattern",
            [
                CommandArgSpec("part", ArgKind.text, true, "Part name"),
                CommandArgSpec("section", ArgKind.text, false, "Section name")
            ],
            [
                CommandOptionSpec("from", ArgKind.text, "Range start position (default 1)"),
                CommandOptionSpec("len", ArgKind.text, "Range length (default remainder of section)")
            ]
        ),
        &handleClear
    );
    interp.registerCommand(
        CommandSpec(
            "arrange",
            "Arrange declared sections in order on the song timeline, or place raw timeline clips",
            [CommandArgSpec("sections", ArgKind.text, false, "Ordered list of section names")],
            [
                CommandOptionSpec("clip", ArgKind.text, "Raw pattern name or #<id> for preserved timeline clips"),
                CommandOptionSpec("start", ArgKind.integer, "Clip start line"),
                CommandOptionSpec("len", ArgKind.integer, "Clip length in lines"),
                CommandOptionSpec("lane", ArgKind.integer, "Timeline lane index"),
                CommandOptionSpec("offset", ArgKind.integer, "Pattern start offset in lines"),
                CommandOptionSpec("mute", ArgKind.word, "Clip mute flag (on/off)"),
                CommandOptionSpec("solo", ArgKind.word, "Clip solo flag (on/off)"),
                CommandOptionSpec("supertrack", ArgKind.word, "Clip supertrack flag (on/off)")
            ],
            false,
            true,
            false
        ),
        &handleArrange
    );
    interp.registerCommand(
        CommandSpec(
            "loop",
            "Set the song loop over arranged sections, 'all', or explicit start/end lines",
            [
                CommandArgSpec("target", ArgKind.text, false, "Section name or 'all'"),
                CommandArgSpec("until", ArgKind.text, false, "Optional end section name")
            ],
            [
                CommandOptionSpec("start", ArgKind.integer, "Loop start line (>= 0)"),
                CommandOptionSpec("end", ArgKind.integer, "Loop end line (> start)")
            ]
        ),
        &handleLoop
    );
    interp.registerCommand(
        CommandSpec(
            "save",
            "Validate, trial-activate, and save the project as an .msv file",
            [CommandArgSpec("path", ArgKind.path, true, "Destination .msv file path")],
            []
        ),
        &handleSave
    );
}

/**
 * Creates a ScriptInterpreter pre-loaded with all core commands.
 *
 * Params:
 *   checkOnly = When true, save validates and trial-activates without writing to disk.
 *   project = Optional existing ProjectWriter to share; creates a fresh one when null.
 *
 * Returns:
 *   Configured ScriptInterpreter.
 */
ScriptInterpreter createDefaultInterpreter(bool checkOnly = false, ProjectWriter project = null)
        @safe nothrow {
    ScriptInterpreter interp = new ScriptInterpreter(project, checkOnly);
    registerCoreCommands(interp);
    return interp;
}

/**
 * Refuses a command the app's Script tab does not run (T109): `project`, `open` and `save`.
 *
 * Params:
 *   interp = The interpreter.
 *   cmd = The command.
 *
 * Returns:
 *   A problem at the command word with the reason.
 */
private StepResult refuseInApp(ScriptInterpreter interp, const ref ParsedCommand cmd) @safe nothrow {
    cast(void) interp;
    string reason;
    if (namesMatch(cmd.name, "project")) {
        reason = "'project' would replace the open project; set the title, tempo, signature and key with "
            ~ "'title', 'tempo', 'signature' and 'key'";
    } else if (namesMatch(cmd.name, "open")) {
        reason = "'open' is not available in the Script tab; open a project with File > Open";
    } else {
        reason = "'save' is not available in the Script tab; save the project with File > Save";
    }
    return StepResult(false, ScriptProblem(cmd.commandToken.line, cmd.commandToken.column,
        cmd.commandToken.length, reason, "", false));
}

/**
 * The commands the app's Script tab refuses (T109), in the order they are refused.
 */
immutable string[3] APP_REFUSED_COMMANDS = ["project", "open", "save"];

/**
 * Prepares an interpreter for the app's Script tab (T109): `project`, `open` and `save` are refused with a
 * reason before their arguments are read, and relative file paths are resolved against the project's folder.
 *
 * Params:
 *   interp = The interpreter (from createInterpreterFromDocument()).
 *   projectFolder = Folder of the open project file, or "" when the project has not been saved (relative
 *     paths are then refused).
 */
void restrictForApp(ScriptInterpreter interp, string projectFolder) @safe nothrow {
    foreach (name; APP_REFUSED_COMMANDS) {
        string summary;
        foreach (ref spec; interp.commandTable()) {
            if (spec.name == name) {
                summary = spec.summary;
            }
        }
        interp.registerCommand(CommandSpec(name, summary ~ " (not available in the app's Script tab)", [], [],
            true, true, true), &refuseInApp);
    }
    interp.setBaseDirectory(projectFolder, projectFolder.length > 0);
}

/**
 * Creates a ScriptInterpreter pre-loaded with all core commands and initialized from an in-memory
 * LoadedProject snapshot (T103 / T113).
 *
 * Params:
 *   doc = LoadedProject snapshot to edit.
 *   checkOnly = When true, save validates without writing files to disk.
 *
 * Returns:
 *   ScriptOpenResult carrying the initialized interpreter or a ScriptProblem.
 */
ScriptOpenResult createInterpreterFromDocument(const ref LoadedProject doc, bool checkOnly = false)
        @safe nothrow {
    ScriptInterpreter interp = createDefaultInterpreter(checkOnly);
    ScriptProblem prob;
    if (!interp.loadFromDocument(doc, prob)) {
        return ScriptOpenResult(null, false, prob);
    }
    return ScriptOpenResult(interp, true);
}
