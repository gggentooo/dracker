/**
 * File:         source/compose/script/describe.d
 * Module:       compose.script.describe
 * Phase:        Composition helper (dracker-compose) — T87 & T107 (Describe preset & project as script)
 *
 * Purpose:
 *   Converts existing `.msym` module presets and `.msv` project files (or in-memory LoadedPreset /
 *   LoadedProject documents) into runnable composition scripts per decision T71. Emits project
 *   properties, derived module handles, non-default parameters via `set`, `keep=<file>:<id>` for
 *   modules carrying extra binary payloads or MetaModule child projects, and `connect` wires with
 *   only the non-default ports/gains needed to reproduce the exact document. (T107 extends
 *   describeProject() to also emit sections, parts, `notes`, `drums`, `cells`, `arrange`, and `loop`.)
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Public functions are @safe nothrow; disk adapters wrap loadProject / loadPresetFile.
 *
 * Dependencies:
 *   Internal: app.music_theory (keyName, KeyMode, MusicalKey), compose.module_writer
 *             (parameterValueText), compose.project_writer (LAYOUT_COLUMN_STEP, LAYOUT_ORIGIN_X,
 *             LAYOUT_ORIGIN_Y, LAYOUT_ROWS, LoadedModuleHandle, OUTPUT_HANDLE, OUTPUT_MODULE_ID,
 *             ProjectOpenResult, ProjectWriter, suggestedHandle), compose.timing
 *             (formatTimeSignature, TimeSignature), graph.module_api (ModuleDescriptor,
 *             ParamDescriptor), graph.port (isAudioPort, PortDescriptor, PortDirection),
 *             graph.registry (ModuleRegistry), io.project_format (LoadedPreset, LoadedProject,
 *             loadPreset, loadPresetFile, loadProject, loadProjectFile, SavedModule, SavedWire)
 *   External: std.conv (to), std.file (read), std.format (format), std.math (floor, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DescribeResult
 *   - describePreset(), describePresetBytes(), describePresetFile()
 *   - describeProject(), describeProjectBytes(), describeProjectFile()
 *   - describeBytes()
 *
 * See_Also:
 *   docs/todo.md (T71, T87, T107), source/compose/project_writer.d, source/compose_main.d
 */
module compose.script.describe;

import std.conv : to;
import std.format : format;
import std.math : floor, isFinite;

import app.music_theory : keyName, KeyMode, MusicalKey;
import app.pattern_notes : notesOf, PatternGrid, RollNote;
import compose.drum_writer : DRUMSYNTH_DEFAULT_KIT, DRUMSYNTH_TYPE_ID, DrumLaneInfo;
import compose.module_writer : ModuleWriter, parameterValueText;
import compose.names : namesMatch;
import compose.part_writer : OpenedPatternMapping, PartEditResult, PartOpenResult, PartWriter,
    SectionResult;
import compose.project_writer : LAYOUT_COLUMN_STEP, LAYOUT_ORIGIN_X, LAYOUT_ORIGIN_Y, LAYOUT_ROW_STEP,
    LAYOUT_ROWS, LoadedModuleHandle, OUTPUT_HANDLE, OUTPUT_MODULE_ID, ProjectOpenResult, ProjectWriter,
    suggestedHandle;
import compose.script.notation : formatPitch, NotationResult, parseNotes;
import compose.timing : BeatPosition, formatLength, formatPosition, formatTimeSignature, Length,
    linesPerBar, linesToLength, lineToPosition, PositionResult, TimeSignature;
import graph.module_api : ModuleDescriptor, ParamDescriptor;
import graph.port : isAudioPort, PortDescriptor, PortDirection;
import graph.registry : ModuleRegistry;
import io.project_format : LoadedPreset, LoadedProject, loadPreset, loadPresetFile, loadProject,
    loadProjectFile, PATTERN_KIND_NORMAL, SavedModule, SavedPattern, SavedWire;
import sequencer.note : NoteCell, NoteCmd;
import sequencer.timeline : TimelineClip;

/**
 * Result of describing a `.msv` project or `.msym` preset as a runnable composition script.
 */
struct DescribeResult {
    string script = "";
    string kind = "";
    bool ok = false;
    string error = "";
}

/**
 * Formats a double-quoted script string escaping backslash, quotes, newline, and tab.
 *
 * Params:
 *   s = Raw string value.
 *
 * Returns:
 *   Double-quoted token suitable for the T67 script lexer.
 */
string quoteScriptString(string s) @safe pure nothrow {
    char[] buf;
    buf.reserve(s.length + 2);
    buf ~= '"';
    foreach (char c; s) {
        if (c == '"') {
            buf ~= '\\';
            buf ~= '"';
        } else if (c == '\\') {
            buf ~= '\\';
            buf ~= '\\';
        } else if (c == '\n') {
            buf ~= '\\';
            buf ~= 'n';
        } else if (c == '\t') {
            buf ~= '\\';
            buf ~= 't';
        } else {
            buf ~= c;
        }
    }
    buf ~= '"';
    return buf.idup;
}

/**
 * Formats a token either as a bare word when safe or as a double-quoted string.
 *
 * Params:
 *   s = Raw token value.
 *
 * Returns:
 *   Safe script token.
 */
string formatScriptValue(string s) @safe pure nothrow {
    if (s.length == 0) {
        return "\"\"";
    }
    bool bare = true;
    foreach (i, char c; s) {
        if (c <= ' ' || c > '~' || c == '"' || c == '\\' || c == '=' || c == ':') {
            bare = false;
            break;
        }
        if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
            bare = false;
            break;
        }
    }
    return bare ? s : quoteScriptString(s);
}

private bool isOptionIdentifier(string name) @safe pure nothrow @nogc {
    if (name.length == 0) {
        return false;
    }
    immutable char first = name[0];
    if (!((first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z'))) {
        return false;
    }
    foreach (char c; name) {
        immutable bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
            || (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!ok) {
            return false;
        }
    }
    return true;
}

private string formatFloatExact(float v) @safe pure nothrow {
    if (!isFinite(v)) {
        return "0";
    }
    if (v == 0.0f) {
        return "0";
    }
    if (v == floor(v) && v > -1.0e7f && v < 1.0e7f) {
        return decimalSigned(cast(long) v);
    }
    foreach (prec; 1 .. 10) {
        immutable string s = formatSafeFloat(prec, v);
        float back = 0.0f;
        if (s.length > 0 && parseSafeFloat(s, back) && back == v) {
            return s;
        }
    }
    return formatSafeFloat(9, v);
}

private string formatDoubleExact(double v) @safe pure nothrow {
    if (!isFinite(v)) {
        return "125";
    }
    if (v == floor(v) && v > -1.0e12 && v < 1.0e12) {
        return decimalSigned(cast(long) v);
    }
    foreach (prec; 1 .. 18) {
        immutable string s = formatSafeDouble(prec, v);
        double back = 0.0;
        if (s.length > 0 && parseSafeDouble(s, back) && back == v) {
            return s;
        }
    }
    return formatSafeDouble(17, v);
}

private string formatSafeFloat(int prec, float v) @safe pure nothrow {
    try {
        return format("%.*g", prec, v);
    } catch (Exception) {
        return "";
    }
}

private string formatSafeDouble(int prec, double v) @safe pure nothrow {
    try {
        return format("%.*g", prec, v);
    } catch (Exception) {
        return "";
    }
}

private bool parseSafeFloat(string text, out float v) @safe pure nothrow {
    try {
        v = to!float(text);
        return true;
    } catch (Exception) {
        v = 0.0f;
        return false;
    }
}

private bool parseSafeDouble(string text, out double v) @safe pure nothrow {
    try {
        v = to!double(text);
        return true;
    } catch (Exception) {
        v = 0.0;
        return false;
    }
}

private string decimalSigned(long v) @safe pure nothrow {
    if (v < 0) {
        return "-" ~ decimal(0UL - cast(ulong) v);
    }
    return decimal(cast(ulong) v);
}

private string decimal(ulong v) @safe pure nothrow {
    char[24] buf;
    size_t idx = buf.length;
    do {
        idx--;
        buf[idx] = cast(char)('0' + (v % 10));
        v /= 10;
    } while (v > 0);
    return buf[idx .. $].idup;
}

private const(ModuleDescriptor)* findDescriptorSafe(string typeId) @trusted pure nothrow {
    return ModuleRegistry.findByTypeId(typeId);
}

private int defaultAudioPortIndex(const(ModuleDescriptor)* d, PortDirection dir) @safe pure nothrow @nogc {
    if (d is null) {
        return -1;
    }
    foreach (i, ref p; d.params) {
        cast(void) p;
    }
    foreach (i, ref p; d.ports) {
        if (p.dir == dir && isAudioPort(p.kind)) {
            return cast(int) i;
        }
    }
    return -1;
}

private string formatSetParamLine(string handle, const ref ParamDescriptor p, float val) @safe pure nothrow {
    immutable string valText = parameterValueText(p, val);
    if (isOptionIdentifier(p.name)) {
        return "set " ~ handle ~ " " ~ p.name ~ "=" ~ formatScriptValue(valText);
    }
    return "set " ~ handle ~ " " ~ quoteScriptString(p.name) ~ " " ~ formatScriptValue(valText);
}

/**
 * Describes a loaded `.msym` preset as `module` and `set` script commands (T87).
 *
 * Params:
 *   preset = Parsed LoadedPreset.
 *   sourcePath = Optional source path used for `keep=` when the module holds extra binary data.
 *
 * Returns:
 *   DescribeResult with kind `"preset"`.
 */
DescribeResult describePreset(const ref LoadedPreset preset, string sourcePath = "") @safe nothrow {
    const(ModuleDescriptor)* d = findDescriptorSafe(preset.mod.typeId);
    if (d is null) {
        return DescribeResult("", "preset", false,
            "unknown module type '" ~ preset.mod.typeId ~ "'");
    }
    if (preset.mod.paramValues.length != d.params.length) {
        return DescribeResult("", "preset", false,
            "preset parameter count does not match module type '" ~ preset.mod.typeId ~ "'");
    }

    immutable string rawName = preset.mod.name.length > 0 ? preset.mod.name
        : (preset.presetName.length > 0 ? preset.presetName : d.displayName);
    immutable string handle = suggestedHandle(rawName);
    immutable bool hasOpaque = preset.mod.extraBlob.length > 0 || preset.mod.hasChildProject;

    string script;
    string line = "module " ~ handle ~ " ";
    if (hasOpaque && sourcePath.length > 0) {
        line ~= "keep=" ~ formatScriptValue(sourcePath);
    } else {
        line ~= formatScriptValue(preset.mod.typeId);
    }
    if (preset.mod.name.length > 0 && preset.mod.name != handle) {
        line ~= " name=" ~ formatScriptValue(preset.mod.name);
    }
    script ~= line ~ "\n";

    foreach (i, ref p; d.params) {
        immutable float val = preset.mod.paramValues[i];
        if (val != p.defaultVal) {
            script ~= formatSetParamLine(handle, p, val) ~ "\n";
        }
    }
    return DescribeResult(script, "preset", true, "");
}

/**
 * Describes `.msym` preset bytes as script commands (T87).
 *
 * Params:
 *   bytes = Raw `.msym` payload.
 *   sourcePath = Optional source file path for `keep=`.
 *
 * Returns:
 *   DescribeResult.
 */
DescribeResult describePresetBytes(const(ubyte)[] bytes, string sourcePath = "") @safe nothrow {
    LoadedPreset preset;
    string err;
    if (!loadPreset(bytes, preset, err)) {
        return DescribeResult("", "preset", false, "could not parse preset: " ~ err);
    }
    return describePreset(preset, sourcePath);
}

/**
 * Loads a `.msym` file from disk and describes it as script commands (T87).
 *
 * Params:
 *   path = Path to the `.msym` preset file.
 *
 * Returns:
 *   DescribeResult.
 */
DescribeResult describePresetFile(string path) @safe nothrow {
    LoadedPreset preset;
    string err;
    if (!readPresetFileSafe(path, preset, err)) {
        return DescribeResult("", "preset", false, "could not read '" ~ path ~ "': " ~ err);
    }
    return describePreset(preset, path);
}

/**
 * Describes a LoadedProject as a runnable composition script (T87 properties, modules, wires;
 * extended by T107 to include sections, parts, patterns, arrangement, and loop).
 *
 * Params:
 *   proj = Parsed or constructed LoadedProject.
 *   sourcePath = Optional `.msv` path used for `keep=<path>:<id>` on opaque modules.
 *   includeMusic = Whether to emit music sections/parts/patterns/arrangement (T107).
 *
 * Returns:
 *   DescribeResult with kind `"project"`.
 */
DescribeResult describeProject(const ref LoadedProject proj, string sourcePath = "",
        bool includeMusic = true) @safe nothrow {
    ProjectOpenResult opened = ProjectWriter.fromLoadedProject(proj);
    if (!opened.ok) {
        return DescribeResult("", "project", false, opened.problem.reason);
    }

    string[uint] handleById;
    foreach (ref h; opened.handles) {
        handleById[h.id] = h.handle;
    }

    string script;
    script ~= "project " ~ quoteScriptString(proj.title) ~ "\n";
    string tempoLine = "tempo " ~ formatDoubleExact(proj.bpm);
    if (proj.ticksPerLine != 6) {
        tempoLine ~= " tpl=" ~ decimal(proj.ticksPerLine);
    }
    script ~= tempoLine ~ "\n";

    immutable TimeSignature sig = TimeSignature(proj.timeSigNumerator, proj.timeSigDenominator);
    script ~= "signature " ~ formatTimeSignature(sig) ~ "\n";
    immutable MusicalKey songKey = MusicalKey(proj.keyTonic, cast(KeyMode) proj.keyMode);
    script ~= "key " ~ keyName(songKey) ~ "\n";

    uint slot = 0;
    foreach (ref sm; proj.modules) {
        const(ModuleDescriptor)* d = findDescriptorSafe(sm.typeId);
        if (d is null) {
            return DescribeResult("", "project", false, "unknown module type '" ~ sm.typeId ~ "'");
        }
        const(string)* hPtr = sm.id in handleById;
        immutable string handle = hPtr !is null ? *hPtr : suggestedHandle(sm.name);
        immutable bool isOut = sm.id == OUTPUT_MODULE_ID || d.isOutput;

        if (!isOut) {
            immutable float autoX = LAYOUT_ORIGIN_X + (slot / LAYOUT_ROWS) * LAYOUT_COLUMN_STEP;
            immutable float autoY = LAYOUT_ORIGIN_Y + (slot % LAYOUT_ROWS) * LAYOUT_ROW_STEP;
            slot++;
            immutable bool autoPos = sm.posX == autoX && sm.posY == autoY;

            immutable bool hasOpaque = sm.extraBlob.length > 0 || sm.hasChildProject;
            string modLine = "module " ~ handle ~ " ";
            if (hasOpaque && sourcePath.length > 0) {
                modLine ~= "keep=" ~ formatScriptValue(sourcePath ~ ":" ~ decimal(sm.id));
            } else {
                modLine ~= formatScriptValue(sm.typeId);
            }
            if (sm.name != handle) {
                modLine ~= " name=" ~ formatScriptValue(sm.name);
            }
            if (!autoPos) {
                modLine ~= " x=" ~ formatFloatExact(sm.posX) ~ " y=" ~ formatFloatExact(sm.posY);
            }
            script ~= modLine ~ "\n";

            if (!(hasOpaque && sourcePath.length > 0)) {
                foreach (i, ref p; d.params) {
                    if (i < sm.paramValues.length && sm.paramValues[i] != p.defaultVal) {
                        script ~= formatSetParamLine(handle, p, sm.paramValues[i]) ~ "\n";
                    }
                }
            }
        } else {
            foreach (i, ref p; d.params) {
                if (i < sm.paramValues.length && sm.paramValues[i] != p.defaultVal) {
                    script ~= formatSetParamLine(handle, p, sm.paramValues[i]) ~ "\n";
                }
            }
        }
    }

    const(ModuleDescriptor)*[uint] descById;
    foreach (ref sm; proj.modules) {
        descById[sm.id] = findDescriptorSafe(sm.typeId);
    }

    foreach (ref w; proj.wires) {
        const(string)* srcPtr = w.srcMod in handleById;
        const(string)* dstPtr = w.dstMod in handleById;
        if (srcPtr is null || dstPtr is null) {
            continue;
        }
        const(ModuleDescriptor)* srcD = w.srcMod in descById ? descById[w.srcMod] : null;
        const(ModuleDescriptor)* dstD = w.dstMod in descById ? descById[w.dstMod] : null;
        string wireLine = "connect " ~ *srcPtr ~ " " ~ *dstPtr;
        if (w.gain != 1.0f) {
            wireLine ~= " gain=" ~ formatFloatExact(w.gain);
        }
        immutable int defSrc = defaultAudioPortIndex(srcD, PortDirection.output);
        if (w.srcPort != defSrc && srcD !is null && w.srcPort < srcD.ports.length) {
            wireLine ~= " from=" ~ formatScriptValue(srcD.ports[w.srcPort].name);
        }
        immutable int defDst = defaultAudioPortIndex(dstD, PortDirection.input);
        if (w.dstPort != defDst && dstD !is null && w.dstPort < dstD.ports.length) {
            wireLine ~= " to=" ~ formatScriptValue(dstD.ports[w.dstPort].name);
        }
        script ~= wireLine ~ "\n";
    }

    if (includeMusic && !isDefaultStarterMusic(proj)) {
        string musicErr;
        if (!describeMusic(proj, opened.writer, handleById, songKey, sig, script, musicErr)) {
            return DescribeResult("", "project", false, musicErr);
        }
    }
    return DescribeResult(script, "project", true, "");
}

/**
 * Describes `.msv` project bytes as a runnable composition script.
 *
 * Params:
 *   bytes = Raw `.msv` payload.
 *   sourcePath = Optional source file path for `keep=`.
 *   includeMusic = Whether to describe music patterns and arrangement (T107).
 *
 * Returns:
 *   DescribeResult.
 */
DescribeResult describeProjectBytes(const(ubyte)[] bytes, string sourcePath = "",
        bool includeMusic = true) @safe nothrow {
    LoadedProject proj;
    string err;
    if (!loadProject(bytes, proj, err)) {
        return DescribeResult("", "project", false, "could not parse project: " ~ err);
    }
    return describeProject(proj, sourcePath, includeMusic);
}

/**
 * Reads a `.msv` file from disk and describes it as a composition script.
 *
 * Params:
 *   path = Path to `.msv` file.
 *   includeMusic = Whether to describe music patterns and arrangement (T107).
 *
 * Returns:
 *   DescribeResult.
 */
DescribeResult describeProjectFile(string path, bool includeMusic = true) @safe nothrow {
    LoadedProject proj;
    string err;
    if (!readProjectFileSafe(path, proj, err)) {
        return DescribeResult("", "project", false, "could not read '" ~ path ~ "': " ~ err);
    }
    return describeProject(proj, path, includeMusic);
}

/**
 * Auto-detects whether raw bytes represent a `.msv` project or `.msym` preset and describes it.
 *
 * Params:
 *   bytes = File contents read from disk or memory.
 *   sourcePath = Source path used for file-type hinting and `keep=` references.
 *
 * Returns:
 *   DescribeResult.
 */
DescribeResult describeBytes(const(ubyte)[] bytes, string sourcePath = "") @safe nothrow {
    if (looksLikePreset(bytes, sourcePath)) {
        immutable DescribeResult pr = describePresetBytes(bytes, sourcePath);
        if (pr.ok) {
            return pr;
        }
        immutable DescribeResult pj = describeProjectBytes(bytes, sourcePath, true);
        return pj.ok ? pj : pr;
    }
    immutable DescribeResult pj = describeProjectBytes(bytes, sourcePath, true);
    if (pj.ok) {
        return pj;
    }
    immutable DescribeResult pr = describePresetBytes(bytes, sourcePath);
    return pr.ok ? pr : pj;
}

private bool looksLikePreset(const(ubyte)[] bytes, string sourcePath) @safe pure nothrow @nogc {
    if (bytes.length >= 4 && bytes[0] == 'M' && bytes[1] == 'S' && bytes[2] == 'Y' && bytes[3] == 'M') {
        return true;
    }
    if (sourcePath.length >= 5) {
        immutable string tail = sourcePath[$ - 5 .. $];
        if (tail == ".msym" || tail == ".MSYM") {
            return true;
        }
    }
    return false;
}

private bool readPresetFileSafe(string path, out LoadedPreset preset, out string err) @trusted nothrow {
    try {
        return loadPresetFile(path, preset, err);
    } catch (Exception ex) {
        err = ex.msg.length > 0 ? ex.msg : "Failed reading .msym file";
        return false;
    }
}

private bool readProjectFileSafe(string path, out LoadedProject proj, out string err) @trusted nothrow {
    try {
        return loadProjectFile(path, proj, err);
    } catch (Exception ex) {
        err = ex.msg.length > 0 ? ex.msg : "Failed reading .msv file";
        return false;
    }
}

private bool allCellsEmpty(const(NoteCell)[] cells) @safe pure nothrow @nogc {
    foreach (ref c; cells) {
        if (!c.isEmpty()) {
            return false;
        }
    }
    return true;
}

private bool isDefaultStarterMusic(const ref LoadedProject proj) @safe pure nothrow @nogc {
    if (proj.loopStartLine != 0 || proj.loopEndLine != 0) {
        return false;
    }
    if (proj.patterns.length == 0 && proj.clips.length == 0) {
        return true;
    }
    if (proj.patterns.length == 1) {
        immutable size_t patLen = proj.patterns[0].cells.length;
        cast(void) patLen;
        if (proj.patterns[0].name == "Pattern 01" && proj.patterns[0].tracks == 4
                && proj.patterns[0].lines == 64 && proj.patterns[0].kind == PATTERN_KIND_NORMAL
                && allCellsEmpty(proj.patterns[0].cells)) {
            if (proj.clips.length == 0) {
                return true;
            }
            if (proj.clips.length == 1) {
                immutable TimelineClip c = proj.clips[0];
                return c.patternId == proj.patterns[0].patternId && c.startLine == 0 && c.lengthLines == 64
                    && c.laneY == 0 && c.patternOffset == 0 && !c.mute && !c.solo
                    && !c.isSupertrack;
            }
        }
    }
    return false;
}

private string formatHexByte(ubyte b) @safe pure nothrow {
    static immutable string HEX = "0123456789ABCDEF";
    char[4] buf = ['0', 'x', HEX[b >> 4], HEX[b & 0x0F]];
    return buf[].idup;
}

private string formatVelByte(ubyte velByte) @safe pure nothrow {
    if (velByte == 204) {
        return "0.8";
    }
    if (velByte == 255) {
        return "1";
    }
    if (velByte == 115) {
        return "0.45";
    }
    immutable double v = cast(double)(velByte - 1) / 254.0;
    foreach (prec; [2, 3, 4, 5, 6, 8, 10]) {
        immutable string cand = formatSafeDouble(prec, v);
        double parsed = 0.0;
        if (cand.length > 0 && parseSafeDouble(cand, parsed)) {
            if (NoteCell.encodeVelocity(cast(float) parsed) == velByte) {
                return cand;
            }
        }
    }
    return formatDoubleExact(v);
}

private struct GroupedNoteEvent {
    uint line = 0;
    uint length = 1;
    ubyte velByte = 204;
    ubyte[] pitches;
}

private struct NotesLineCandidate {
    string lineText = "";
    BeatPosition startPos;
    string tailText = "";
}

private bool tryBuildNotesLines(const ref SavedPattern origPat, uint partModId, MusicalKey songKey,
        TimeSignature sig, string partName, string secName, out string[] outLines) @safe nothrow {
    outLines = null;
    cast(void) songKey;
    immutable uint lpbar = linesPerBar(sig);
    if (lpbar == 0 || origPat.lines == 0 || (secName.length > 0 && (origPat.lines % lpbar) != 0)) {
        return false;
    }
    if (origPat.cells.length != cast(size_t) origPat.tracks * origPat.lines) {
        return false;
    }
    foreach (ref c; origPat.cells) {
        if (c.effect != 0 || c.effectVal != 0 || c.paramId != 0) {
            return false;
        }
        if (c.note >= NoteCmd.allNotesOff) {
            return false;
        }
        if ((c.isMidiNote() || c.note == NoteCmd.noteOff) && c.moduleId != 0 && c.moduleId != partModId) {
            return false;
        }
    }

    PatternGrid origGrid = PatternGrid(origPat.tracks, origPat.lines, origPat.cells.dup);
    RollNote[] raw = notesOf(origGrid);
    if (raw.length == 0) {
        return false;
    }

    struct RawWithByte {
        RollNote rn;
        ubyte velByte;
    }
    RawWithByte[] sorted = new RawWithByte[raw.length];
    foreach (i, ref rn; raw) {
        if (rn.line + rn.length > origPat.lines) {
            return false;
        }
        immutable ubyte vb = origGrid.at(rn.track, rn.line).velocity;
        if (vb <= 1) {
            return false;
        }
        sorted[i] = RawWithByte(rn, vb);
    }
    foreach (i; 1 .. sorted.length) {
        RawWithByte key = sorted[i];
        size_t j = i;
        while (j > 0) {
            immutable auto prev = sorted[j - 1];
            immutable bool greater = prev.rn.line > key.rn.line
                || (prev.rn.line == key.rn.line && (prev.rn.track > key.rn.track
                    || (prev.rn.track == key.rn.track && prev.rn.pitch > key.rn.pitch)));
            if (!greater) {
                break;
            }
            sorted[j] = sorted[j - 1];
            j--;
        }
        sorted[j] = key;
    }

    GroupedNoteEvent[] events;
    foreach (ref item; sorted) {
        if (events.length > 0 && events[$ - 1].line == item.rn.line
                && events[$ - 1].length == item.rn.length
                && events[$ - 1].velByte == item.velByte) {
            events[$ - 1].pitches ~= item.rn.pitch;
        } else {
            events ~= GroupedNoteEvent(item.rn.line, item.rn.length, item.velByte, [item.rn.pitch]);
        }
    }

    GroupedNoteEvent[][] streams;
    uint[] streamEnd;
    foreach (ref ev; events) {
        size_t target = streams.length;
        foreach (si; 0 .. streams.length) {
            if (ev.line >= streamEnd[si]) {
                target = si;
                break;
            }
        }
        if (target == streams.length) {
            streams ~= [ev];
            streamEnd ~= ev.line + ev.length;
        } else {
            streams[target] ~= ev;
            streamEnd[target] = ev.line + ev.length;
        }
    }

    NotesLineCandidate[] cands;
    foreach (ref st; streams) {
        immutable uint startLine = st[0].line;
        immutable PositionResult startPosRes = lineToPosition(startLine, sig);
        if (!startPosRes.ok) {
            return false;
        }
        string lineCmd = "notes " ~ formatScriptValue(partName);
        if (secName.length > 0) {
            lineCmd ~= " " ~ formatScriptValue(secName);
        }
        if (startLine > 0) {
            lineCmd ~= " at=" ~ formatPosition(startPosRes.position);
        }
        lineCmd ~= (lineCmd.length > 0 && lineCmd[$ - 1] == '"') ? " :" : ":";

        string tail;
        uint cursor = startLine;
        foreach (ei, ref ev; st) {
            if (ev.line > cursor) {
                immutable Length restLen = linesToLength(ev.line - cursor);
                if (tail.length > 0) {
                    tail ~= " ";
                }
                tail ~= "-:" ~ formatLength(restLen, sig);
            }
            string tok;
            if (ev.pitches.length == 1) {
                tok = formatPitch(ev.pitches[0]);
            } else {
                tok = "[";
                foreach (pi, mp; ev.pitches) {
                    if (pi > 0) {
                        tok ~= " ";
                    }
                    tok ~= formatPitch(mp);
                }
                tok ~= "]";
            }
            immutable Length nLen = linesToLength(ev.length);
            tok ~= ":" ~ formatLength(nLen, sig);
            if (ev.velByte != 204) {
                tok ~= "@" ~ formatVelByte(ev.velByte);
            }
            if (tail.length > 0) {
                tail ~= " ";
            }
            tail ~= tok;
            cursor = ev.line + ev.length;
        }
        lineCmd ~= " " ~ tail;
        cands ~= NotesLineCandidate(lineCmd, startPosRes.position, tail);
    }

    ProjectWriter scratchProj = new ProjectWriter();
    if (!scratchProj.setTimeSignature(sig).ok || !scratchProj.setKey(songKey).ok) {
        return false;
    }
    auto modRes = ModuleWriter.fromType("synth.fm_synth");
    if (!modRes.ok) {
        return false;
    }
    auto addModRes = scratchProj.addModule("m", modRes.writer);
    if (!addModRes.ok) {
        return false;
    }
    immutable uint scratchModId = addModRes.id;
    PartWriter pw = new PartWriter(scratchProj);
    if (secName.length > 0) {
        immutable uint bars = origPat.lines / lpbar;
        if (!pw.addSection(secName, bars).ok) {
            return false;
        }
    }
    if (!pw.addPart(partName, "m").ok) {
        return false;
    }
    foreach (ref c; cands) {
        immutable NotationResult nr = parseNotes(c.tailText, sig);
        if (!nr.ok) {
            return false;
        }
        immutable PartEditResult wr = pw.writeNotes(partName, secName, c.startPos, nr.events);
        if (!wr.ok) {
            return false;
        }
    }
    auto simPat = pw.patternFor(partName, secName);
    if (!simPat.ok) {
        return false;
    }
    PatternGrid simGrid;
    if (!pw.patternGrid(simPat.pattern.patternId, simGrid)) {
        return false;
    }
    if (simGrid.tracks != origGrid.tracks || simGrid.lines != origGrid.lines
            || simGrid.cells.length != origGrid.cells.length) {
        return false;
    }
    foreach (i; 0 .. origGrid.cells.length) {
        immutable NoteCell oc = origGrid.cells[i];
        immutable NoteCell sc = simGrid.cells[i];
        immutable bool modMatch = (oc.moduleId == 0 && sc.moduleId == 0)
            || (oc.moduleId == partModId && sc.moduleId == scratchModId);
        if (oc.note != sc.note || oc.velocity != sc.velocity || !modMatch
                || oc.paramId != sc.paramId || oc.effect != sc.effect
                || oc.effectVal != sc.effectVal) {
            return false;
        }
    }

    outLines.reserve(cands.length);
    foreach (ref c; cands) {
        outLines ~= c.lineText;
    }
    return true;
}

private void appendCellCommands(const ref SavedPattern pat, string target, string secName,
        uint defaultModId, const(string)[uint] handleById, ref string script) @safe nothrow {
    bool wroteAny = false;
    bool touchedLastTrack = false;
    immutable string prefix = secName.length > 0
        ? ("cells " ~ formatScriptValue(target) ~ " " ~ formatScriptValue(secName))
        : ("cells " ~ formatScriptValue(target));

    foreach (ln; 0 .. pat.lines) {
        foreach (tr; 0 .. pat.tracks) {
            immutable size_t idx = cast(size_t) ln * pat.tracks + tr;
            if (idx >= pat.cells.length) {
                continue;
            }
            immutable NoteCell c = pat.cells[idx];
            if (c.isEmpty()) {
                continue;
            }
            wroteAny = true;
            if (tr + 1 == pat.tracks) {
                touchedLastTrack = true;
            }
            string cmd = prefix;
            if (tr != 0) {
                cmd ~= " track=" ~ decimal(tr);
            }
            cmd ~= " line=" ~ decimal(ln);
            if (c.isMidiNote()) {
                cmd ~= " note=" ~ formatPitch(c.midiNote());
                if (c.velocity != 204) {
                    cmd ~= " velbyte=" ~ decimal(c.velocity);
                }
            } else if (c.note == NoteCmd.noteOff) {
                cmd ~= " note=off";
                if (c.velocity != 0) {
                    cmd ~= " velbyte=" ~ decimal(c.velocity);
                }
            } else if (c.note == NoteCmd.allNotesOff) {
                cmd ~= " note=alloff";
            } else if (c.note == NoteCmd.prevTrack) {
                cmd ~= " note=prev";
            } else if (c.note == NoteCmd.setPitch) {
                cmd ~= " note=setpitch";
            } else if (c.note == NoteCmd.stopSong) {
                cmd ~= " note=stop";
            } else if (c.velocity != 0) {
                cmd ~= " velbyte=" ~ decimal(c.velocity);
            }
            if (c.moduleId != 0) {
                const(string)* mh = c.moduleId in handleById;
                if (mh !is null) {
                    if (c.moduleId != defaultModId || (!c.isMidiNote() && c.note != NoteCmd.noteOff)) {
                        cmd ~= " module=" ~ *mh;
                    }
                }
            } else if ((c.isMidiNote() || c.note == NoteCmd.noteOff) && defaultModId != 0) {
                cmd ~= " module=none";
            }
            if (c.paramId != 0) {
                cmd ~= " param=" ~ decimal(c.paramId);
            }
            if (c.effect != 0) {
                cmd ~= " fx=" ~ formatHexByte(c.effect);
            }
            if (c.effectVal != 0) {
                cmd ~= " fxval=" ~ formatHexByte(c.effectVal);
            }
            script ~= cmd ~ "\n";
        }
    }

    if (secName.length > 0 || defaultModId != 0) {
        if (!wroteAny) {
            script ~= prefix ~ " track=" ~ decimal(pat.tracks > 1 ? pat.tracks - 1 : 0)
                ~ " line=0 note=none\n";
        } else if (pat.tracks > 1 && !touchedLastTrack) {
            script ~= prefix ~ " track=" ~ decimal(pat.tracks - 1) ~ " line=0 note=none\n";
        }
    }
}

private bool isPureDrumPattern(const ref SavedPattern pat, const(DrumLaneInfo)[] lanes) @safe pure nothrow @nogc {
    if (pat.tracks != lanes.length || pat.cells.length != cast(size_t) pat.tracks * pat.lines) {
        return false;
    }
    foreach (ln; 0 .. pat.lines) {
        foreach (tr; 0 .. pat.tracks) {
            immutable NoteCell c = pat.cells[cast(size_t) ln * pat.tracks + tr];
            if (c.isEmpty()) {
                continue;
            }
            if (!c.isMidiNote() || c.note != lanes[tr].note + 1 || c.moduleId != lanes[tr].moduleId
                    || c.velocity < 2 || c.paramId != 0 || c.effect != 0 || c.effectVal != 0) {
                return false;
            }
        }
    }
    return true;
}

private void appendDrumPatternCommands(const ref SavedPattern pat, const(DrumLaneInfo)[] lanes,
        string partName, string secName, TimeSignature sig, ref string script) @safe nothrow {
    bool anyEmitted = false;
    immutable string basePrefix = secName.length > 0
        ? ("drums " ~ formatScriptValue(partName) ~ " " ~ formatScriptValue(secName))
        : ("drums " ~ formatScriptValue(partName));

    foreach (tr, ref lane; lanes) {
        ubyte[] distinctVels;
        uint firstHit = pat.lines;
        uint lastHit = 0;
        foreach (ln; 0 .. pat.lines) {
            immutable NoteCell c = pat.cells[cast(size_t) ln * pat.tracks + tr];
            if (c.isEmpty()) {
                continue;
            }
            if (firstHit == pat.lines) {
                firstHit = ln;
            }
            lastHit = ln;
            bool seen = false;
            foreach (dv; distinctVels) {
                if (dv == c.velocity) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                distinctVels ~= c.velocity;
            }
        }
        if (distinctVels.length == 0) {
            continue;
        }
        anyEmitted = true;

        ubyte normalByte = 204;
        ubyte accentByte = 255;
        ubyte ghostByte = 115;
        bool hasNormal = false;
        bool hasAccent = false;
        bool hasGhost = false;
        foreach (dv; distinctVels) {
            if (dv == 204) hasNormal = true;
            else if (dv == 255) hasAccent = true;
            else if (dv == 115) hasGhost = true;
        }
        ubyte[] leftovers;
        foreach (dv; distinctVels) {
            if (dv == 204 || dv == 255 || dv == 115) {
                continue;
            }
            if (!hasNormal) {
                normalByte = dv;
                hasNormal = true;
            } else if (!hasAccent) {
                accentByte = dv;
                hasAccent = true;
            } else if (!hasGhost) {
                ghostByte = dv;
                hasGhost = true;
            } else {
                leftovers ~= dv;
            }
        }

        char[] steps;
        steps.reserve(lastHit - firstHit + 1);
        foreach (ln; firstHit .. lastHit + 1) {
            immutable NoteCell c = pat.cells[cast(size_t) ln * pat.tracks + tr];
            if (c.isEmpty()) {
                steps ~= '.';
            } else if (c.velocity == normalByte) {
                steps ~= 'x';
            } else if (c.velocity == accentByte) {
                steps ~= 'X';
            } else if (c.velocity == ghostByte) {
                steps ~= 'g';
            } else {
                steps ~= '.';
            }
        }

        string cmd = basePrefix ~ " " ~ formatScriptValue(lane.name);
        if (firstHit > 0) {
            immutable PositionResult pr = lineToPosition(firstHit, sig);
            cmd ~= " at=" ~ formatPosition(pr.position);
        }
        if (hasNormal && normalByte != 204) {
            cmd ~= " vel=" ~ formatVelByte(normalByte);
        }
        if (hasAccent && accentByte != 255) {
            cmd ~= " accent=" ~ formatVelByte(accentByte);
        }
        if (hasGhost && ghostByte != 115) {
            cmd ~= " ghost=" ~ formatVelByte(ghostByte);
        }
        cmd ~= ((cmd.length > 0 && cmd[$ - 1] == '"') ? " : " : ": ") ~ steps.idup;
        script ~= cmd ~ "\n";

        if (leftovers.length > 0) {
            foreach (ln; 0 .. pat.lines) {
                immutable NoteCell c = pat.cells[cast(size_t) ln * pat.tracks + tr];
                if (c.isEmpty()) {
                    continue;
                }
                if (c.velocity != normalByte && c.velocity != accentByte && c.velocity != ghostByte) {
                    immutable PositionResult pr = lineToPosition(ln, sig);
                    script ~= basePrefix ~ " " ~ formatScriptValue(lane.name)
                        ~ " at=" ~ formatPosition(pr.position)
                        ~ " vel=" ~ formatVelByte(c.velocity) ~ ": x\n";
                }
            }
        }
    }

    if (!anyEmitted && lanes.length > 0) {
        immutable string firstTok = formatScriptValue(lanes[0].name);
        script ~= basePrefix ~ " " ~ firstTok
            ~ ((firstTok.length > 0 && firstTok[$ - 1] == '"') ? " : .\n" : ": .\n");
    }
}

private bool isDefaultDrumKit(const(DrumLaneInfo)[] lanes, const ref LoadedProject proj,
        const(string)[uint] handleById, out string kitHandle) @safe nothrow {
    kitHandle = "";
    if (lanes.length != DRUMSYNTH_DEFAULT_KIT.length) {
        return false;
    }
    immutable uint modId = lanes[0].moduleId;
    const(string)* hPtr = modId in handleById;
    if (hPtr is null) {
        return false;
    }
    bool isDrumSynthMod = false;
    foreach (ref sm; proj.modules) {
        if (sm.id == modId) {
            isDrumSynthMod = sm.typeId == DRUMSYNTH_TYPE_ID;
            break;
        }
    }
    if (!isDrumSynthMod) {
        return false;
    }
    foreach (i, ref l; lanes) {
        if (l.moduleId != modId || !namesMatch(l.name, DRUMSYNTH_DEFAULT_KIT[i].name)
                || l.note != DRUMSYNTH_DEFAULT_KIT[i].note) {
            return false;
        }
    }
    kitHandle = *hPtr;
    return true;
}

private string pickUniqueRawName(string preferred, uint patId, string[] existingParts,
        ref string[] usedRawNames) @safe nothrow {
    string candidate = suggestedHandle(preferred.length > 0 ? preferred : ("pat_" ~ decimal(patId)));
    bool collides(string name) {
        foreach (p; existingParts) {
            if (namesMatch(p, name)) {
                return true;
            }
        }
        foreach (r; usedRawNames) {
            if (namesMatch(r, name)) {
                return true;
            }
        }
        return false;
    }
    if (!collides(candidate)) {
        usedRawNames ~= candidate;
        return candidate;
    }
    uint suffix = 2;
    while (true) {
        immutable string next = candidate ~ "_" ~ decimal(suffix);
        if (!collides(next)) {
            usedRawNames ~= next;
            return next;
        }
        suffix++;
    }
}

private bool describeMusic(const ref LoadedProject proj, ProjectWriter openedWriter,
        const(string)[uint] handleById, MusicalKey songKey, TimeSignature sig,
        ref string script, out string err) @safe nothrow {
    PartOpenResult music = PartWriter.openFromProject(openedWriter);
    if (!music.ok) {
        err = music.problem.reason;
        return false;
    }

    size_t[uint] origIdxById;
    foreach (pi, ref pat; proj.patterns) {
        origIdxById[pat.patternId] = pi;
    }

    bool[uint] treatAsRaw;
    bool forceRawClips = false;
    foreach (ref m; music.patterns) {
        const(size_t)* idxPtr = m.patternId in origIdxById;
        if (idxPtr is null) {
            continue;
        }
        const(SavedPattern)* op = &proj.patterns[*idxPtr];
        if (m.isPart && m.isDrum) {
            DrumLaneInfo[] lanes = music.drums.lanesOf(m.partName);
            if (!isPureDrumPattern(*op, lanes)) {
                treatAsRaw[m.patternId] = true;
                forceRawClips = true;
            }
        }
    }

    string[] secNames = music.parts.sectionNames();
    foreach (sn; secNames) {
        immutable SectionResult sr = music.parts.sectionOf(sn);
        if (sr.ok) {
            script ~= "section " ~ formatScriptValue(sn) ~ " bars=" ~ decimal(sr.section.bars) ~ "\n";
        }
    }

    string[] melodicParts = music.parts.partNames();
    uint[string] partModIdByName;
    foreach (pn; melodicParts) {
        auto pr = music.parts.partOf(pn);
        if (pr.ok) {
            const(string)* mh = pr.part.moduleId in handleById;
            if (mh !is null) {
                script ~= "part " ~ formatScriptValue(pn) ~ " module=" ~ *mh ~ "\n";
                partModIdByName[pn] = pr.part.moduleId;
            }
        }
    }

    string[] drumParts = music.drums.drumPartNames();
    foreach (dn; drumParts) {
        bool hasPureDrumPat = false;
        foreach (ref m; music.patterns) {
            if (m.isPart && m.isDrum && namesMatch(m.partName, dn) && (m.patternId in treatAsRaw) is null) {
                hasPureDrumPat = true;
                break;
            }
        }
        if (!hasPureDrumPat) {
            continue;
        }
        DrumLaneInfo[] lanes = music.drums.lanesOf(dn);
        string kitHandle;
        if (isDefaultDrumKit(lanes, proj, handleById, kitHandle)) {
            script ~= "part " ~ formatScriptValue(dn) ~ " drums=" ~ kitHandle ~ "\n";
        } else if (lanes.length > 0) {
            foreach (ref l; lanes) {
                const(string)* lh = l.moduleId in handleById;
                immutable string modHandle = lh !is null ? *lh : OUTPUT_HANDLE;
                script ~= "drums " ~ formatScriptValue(dn)
                    ~ " lane=" ~ formatScriptValue(l.name)
                    ~ " module=" ~ modHandle
                    ~ " note=" ~ decimal(l.note) ~ "\n";
            }
        }
    }

    string[] usedRawNames;
    string[uint] clipRefByOrigPatId;
    uint assignedMelodicOrRawId = 0;

    foreach (ref m; music.patterns) {
        const(size_t)* idxPtr = m.patternId in origIdxById;
        if (idxPtr is null) {
            continue;
        }
        const(SavedPattern)* op = &proj.patterns[*idxPtr];
        immutable bool asRaw = !m.isPart || ((m.patternId in treatAsRaw) !is null);
        if (m.isPart && m.isDrum && !asRaw) {
            continue;
        }
        assignedMelodicOrRawId++;
        if (asRaw) {
            immutable string rName = pickUniqueRawName(op.name, m.patternId, melodicParts, usedRawNames);
            script ~= "cells " ~ formatScriptValue(rName)
                ~ " tracks=" ~ decimal(op.tracks)
                ~ " lines=" ~ decimal(op.lines) ~ "\n";
            appendCellCommands(*op, rName, "", 0, handleById, script);
            clipRefByOrigPatId[m.patternId] = formatScriptValue(rName);
        } else {
            const(uint)* pmPtr = m.partName in partModIdByName;
            immutable uint partModId = pmPtr !is null ? *pmPtr : 0;
            string[] noteLines;
            if (tryBuildNotesLines(*op, partModId, songKey, sig, m.partName, m.sectionName, noteLines)) {
                foreach (nl; noteLines) {
                    script ~= nl ~ "\n";
                }
            } else {
                appendCellCommands(*op, m.partName, m.sectionName, partModId, handleById, script);
            }
            clipRefByOrigPatId[m.patternId] = "#" ~ decimal(assignedMelodicOrRawId);
        }
    }

    uint assignedDrumId = assignedMelodicOrRawId;
    foreach (ref m; music.patterns) {
        if (!(m.isPart && m.isDrum) || (m.patternId in treatAsRaw) !is null) {
            continue;
        }
        const(size_t)* idxPtr = m.patternId in origIdxById;
        if (idxPtr is null) {
            continue;
        }
        assignedDrumId++;
        DrumLaneInfo[] lanes = music.drums.lanesOf(m.partName);
        appendDrumPatternCommands(proj.patterns[*idxPtr], lanes, m.partName, m.sectionName, sig, script);
        clipRefByOrigPatId[m.patternId] = "#" ~ decimal(assignedDrumId);
    }

    if (music.arrangementReconstructed && !forceRawClips) {
        string[] arr = music.parts.arrangement();
        immutable bool skipImplicitArr = arr.length == 0 || (music.parts.hasImplicitSection()
            && secNames.length == 0 && arr.length == 1);
        if (!skipImplicitArr) {
            string arrLine = "arrange";
            foreach (sn; arr) {
                arrLine ~= " " ~ formatScriptValue(sn);
            }
            script ~= arrLine ~ "\n";
        }
    } else if (proj.clips.length > 0) {
        foreach (ref cl; proj.clips) {
            const(string)* refPtr = cl.patternId in clipRefByOrigPatId;
            immutable string patRef = refPtr !is null ? *refPtr : ("#" ~ decimal(cl.patternId));
            string cLine = "arrange clip=" ~ patRef
                ~ " start=" ~ decimalSigned(cl.startLine)
                ~ " len=" ~ decimal(cl.lengthLines)
                ~ " lane=" ~ decimal(cl.laneY);
            if (cl.patternOffset != 0) {
                cLine ~= " offset=" ~ decimal(cl.patternOffset);
            }
            if (cl.mute) {
                cLine ~= " mute=on";
            }
            if (cl.solo) {
                cLine ~= " solo=on";
            }
            if (cl.isSupertrack) {
                cLine ~= " supertrack=on";
            }
            script ~= cLine ~ "\n";
        }
    }

    if (proj.loopEndLine > proj.loopStartLine) {
        immutable bool defaultLoop = music.arrangementReconstructed && !forceRawClips
            && proj.loopStartLine == 0 && proj.loopEndLine == music.parts.arrangementLengthLines();
        if (!defaultLoop) {
            script ~= "loop start=" ~ decimalSigned(proj.loopStartLine)
                ~ " end=" ~ decimalSigned(proj.loopEndLine) ~ "\n";
        }
    }

    return true;
}
