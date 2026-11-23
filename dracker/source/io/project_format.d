/**
 * File:         source/io/project_format.d
 * Module:       io.project_format
 * Phase:        Phase 6.2 — Versioned 4CC Chunked .msv & .msym Serializer
 *
 * Purpose:
 *   Reads and writes versioned IFF-style 4CC chunked .msv (project) and .msym (module/MetaModule preset) files, skipping unknown chunks gracefully for forward compatibility.
 *
 * Real-Time & Safety Contract:
 *   Off-RT @safe parser/serializer; fuzz-hardened against truncated, overflowing, or deeply nested chunk payloads.
 *
 * Dependencies:
 *   Internal: foundation.types, graph.module_api, graph.plan, graph.registry, io.binary_stream, modules.control.metamodule, sequencer.{engine,note,pattern,timeline}
 *   External: std.file, std.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum uint MSV_FORMAT_VERSION = 1
 *   - struct SavedModule / SavedWire / SavedPattern / SavedMidiMapping / LoadedProject / LoadedPreset
 *   - serializeProject(), saveProject(), loadProject(), loadProjectFile()
 *   - serializePreset(), savePreset(), loadPreset(), loadPresetFile()
 *   - isValidTempo(), isValidPatternShape(), isValidMidiMapping(), validateModuleForSave(), validateProjectForSave()
 *   - materializeProjectToEngine()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.project_format;

import std.file : fileRead = read, fileWrite = write;
import std.math : isFinite;

import foundation.types : ModuleId;
import graph.module_api : ModuleDescriptor, ModuleInstance;
import graph.plan : GraphCompileError, GraphCompiler, GraphPlan, NodeSpec, WireSpec;
import graph.registry : ModuleRegistry;
import io.binary_stream : BinaryReader, BinaryWriter;
import modules.control.metamodule : MAX_METAMODULE_DEPTH, MetaMacroBinding, MetaModuleAsset;
import sequencer.engine : Engine;
import sequencer.note : NoteCell;
import sequencer.pattern : PatternSnapshot;
import sequencer.timeline : TimelineClip, TimelineSnapshot;

enum uint MSV_FORMAT_VERSION = 1;
enum size_t MAX_STRING_LEN = 65_536;
enum size_t MAX_MODULES = 1024;
enum size_t MAX_PARAMS_PER_MODULE = 256;
enum size_t MAX_WIRES = 8192;
enum size_t MAX_PATTERNS = Engine.MAX_PATTERNS;
enum size_t MAX_TRACKS = 64;
enum size_t MAX_LINES = 4096;
enum size_t MAX_CELLS_PER_PATTERN = MAX_TRACKS * MAX_LINES;
enum double MIN_PROJECT_BPM = 20.0;
enum double MAX_PROJECT_BPM = 999.0;
enum uint MAX_PROJECT_TPL = 255;
enum size_t MAX_CLIPS = 4096;
enum size_t MAX_MIDI_MAPPINGS = 256;
enum size_t MAX_EXTRA_BLOB_BYTES = 64u * 1024u * 1024u;

/**
 * Serializable representation of one modular node, its @Param floats, optional extraBlob, and optional child MetaModule project.
 */
struct SavedModule {
    uint id = 0;
    string typeId;
    string name;
    float posX = 0.0f;
    float posY = 0.0f;
    bool muted = false;
    bool bypassed = false;
    float[] paramValues;
    ubyte[] extraBlob;

    bool hasChildProject = false;
    uint metaInputModuleId = 0;
    MetaMacroBinding[MetaModuleAsset.NUM_MACROS] metaMacros;
    ubyte[] childProjectMsv;
}

/**
 * Serializable representation of a directional graph wire connection.
 */
struct SavedWire {
    uint srcMod = 0;
    ushort srcPort = 0;
    uint dstMod = 0;
    ushort dstPort = 0;
    float gain = 1.0f;
}

/**
 * Serializable representation of a tracker pattern matrix and display title.
 */
struct SavedPattern {
    uint patternId = 0;
    uint tracks = 4;
    uint lines = 64;
    string name;
    NoteCell[] cells;
}

/**
 * Serializable MIDI-learn binding (stored in the optional .msv MIDI chunk).
 */
struct SavedMidiMapping {
    ubyte channel = 0;
    ubyte cc = 0;
    uint moduleId = 0;
    uint paramIdx = 0;
    float min01 = 0.0f;
    float max01 = 1.0f;
}

/**
 * Complete off-RT Dracker project document (.msv) ready for session loading or disk export.
 */
struct LoadedProject {
    uint formatVersion = MSV_FORMAT_VERSION;
    string title = "Untitled";
    string author = "Dracker";
    double bpm = 125.0;
    uint ticksPerLine = 6;
    long loopStartLine = 0;
    long loopEndLine = 0;
    SavedModule[] modules;
    SavedWire[] wires;
    SavedPattern[] patterns;
    TimelineClip[] clips;
    SavedMidiMapping[] midiMappings;
}

/**
 * Complete off-RT single-module or MetaModule preset document (.msym).
 */
struct LoadedPreset {
    uint formatVersion = MSV_FORMAT_VERSION;
    string presetName = "Preset";
    SavedModule mod;
}

/**
 * Reports whether a tempo pair is inside the range accepted by the .msv loader and the Engine clock.
 *
 * Params:
 *   bpm = Beats per minute.
 *   tpl = Ticks per line.
 *
 * Returns:
 *   True if bpm is finite in [MIN_PROJECT_BPM, MAX_PROJECT_BPM] and tpl is in [1, MAX_PROJECT_TPL].
 */
bool isValidTempo(double bpm, uint tpl) @safe nothrow pure @nogc {
    return isFinite(bpm) && bpm >= MIN_PROJECT_BPM && bpm <= MAX_PROJECT_BPM && tpl >= 1 && tpl <= MAX_PROJECT_TPL;
}

/**
 * Reports whether pattern dimensions are accepted by the .msv loader.
 *
 * Params:
 *   tracks = Column count.
 *   lines = Row count.
 *
 * Returns:
 *   True if 1 <= tracks <= MAX_TRACKS, 1 <= lines <= MAX_LINES, and the cell count fits MAX_CELLS_PER_PATTERN.
 */
bool isValidPatternShape(uint tracks, uint lines) @safe nothrow pure @nogc {
    return tracks >= 1 && tracks <= MAX_TRACKS && lines >= 1 && lines <= MAX_LINES
        && cast(ulong) tracks * cast(ulong) lines <= MAX_CELLS_PER_PATTERN;
}

/**
 * Validates one module against every constraint readSingleModule enforces so a saved module always reloads.
 *
 * Params:
 *   m = Module to validate.
 *   depth = MetaModule nesting depth of the container holding m.
 *   err = Receives the first violated constraint.
 *
 * Returns:
 *   True if m round-trips through writeSingleModule/readSingleModule.
 */
bool validateModuleForSave(scope const ref SavedModule m, uint depth, out string err) @safe nothrow {
    err = null;
    if (m.id == 0) {
        err = "Module identifier 0 is reserved";
        return false;
    }
    if (m.typeId.length == 0 || m.typeId.length > MAX_STRING_LEN || m.name.length > MAX_STRING_LEN) {
        err = "Module typeId or name length out of range";
        return false;
    }
    if (m.paramValues.length > MAX_PARAMS_PER_MODULE) {
        err = "Module parameter count exceeds MAX_PARAMS_PER_MODULE";
        return false;
    }
    foreach (pv; m.paramValues) {
        if (!isFinite(pv)) {
            err = "Module parameter value is not finite";
            return false;
        }
    }
    if (m.extraBlob.length > MAX_EXTRA_BLOB_BYTES) {
        err = "Module extraBlob exceeds MAX_EXTRA_BLOB_BYTES";
        return false;
    }
    if (m.hasChildProject) {
        if (depth >= MAX_METAMODULE_DEPTH) {
            err = "MetaModule child project exceeds maximum nesting depth";
            return false;
        }
        if (m.childProjectMsv.length > MAX_EXTRA_BLOB_BYTES) {
            err = "MetaModule child project exceeds MAX_EXTRA_BLOB_BYTES";
            return false;
        }
        foreach (ref mac; m.metaMacros) {
            if (!isFinite(mac.minVal) || !isFinite(mac.maxVal)) {
                err = "Non-finite MetaModule macro range";
                return false;
            }
        }
        if (m.childProjectMsv.length > 0) {
            LoadedProject child;
            if (!loadProject(m.childProjectMsv, child, err, depth + 1)) {
                return false;
            }
        }
    }
    return true;
}

/**
 * Validates a project against every constraint loadProject enforces so a saved project always reloads.
 *
 * Params:
 *   proj = Project to validate.
 *   err = Receives the first violated constraint.
 *   depth = MetaModule nesting depth of proj.
 *
 * Returns:
 *   True if proj round-trips through serializeProject/loadProject.
 */
bool validateProjectForSave(scope const ref LoadedProject proj, out string err, uint depth = 0) @safe nothrow {
    err = null;
    if (proj.modules.length > MAX_MODULES || proj.wires.length > MAX_WIRES
            || proj.patterns.length > MAX_PATTERNS || proj.clips.length > MAX_CLIPS) {
        err = "Project exceeds serialization safety caps";
        return false;
    }
    if (proj.title.length > MAX_STRING_LEN || proj.author.length > MAX_STRING_LEN) {
        err = "Project title or author too long";
        return false;
    }
    if (!isValidTempo(proj.bpm, proj.ticksPerLine)) {
        err = "Out-of-range BPM or TPL";
        return false;
    }
    foreach (i, ref m; proj.modules) {
        if (!validateModuleForSave(m, depth, err)) {
            return false;
        }
        foreach (ref other; proj.modules[0 .. i]) {
            if (other.id == m.id) {
                err = "Duplicate module identifier";
                return false;
            }
        }
    }
    foreach (ref w; proj.wires) {
        if (!isFinite(w.gain)) {
            err = "Non-finite wire gain";
            return false;
        }
    }
    if (proj.midiMappings.length > MAX_MIDI_MAPPINGS) {
        err = "Too many MIDI mappings";
        return false;
    }
    foreach (ref mm; proj.midiMappings) {
        if (!isValidMidiMapping(mm)) {
            err = "Invalid MIDI mapping";
            return false;
        }
    }
    foreach (i, ref pat; proj.patterns) {
        if (!isValidPatternShape(pat.tracks, pat.lines) || pat.name.length > MAX_STRING_LEN) {
            err = "Invalid pattern dimensions or name";
            return false;
        }
        foreach (ref other; proj.patterns[0 .. i]) {
            if (other.patternId == pat.patternId) {
                err = "Duplicate pattern identifier";
                return false;
            }
        }
    }
    return true;
}

private bool hasDuplicateIds(scope const(SavedModule)[] mods, scope const(SavedPattern)[] pats) @safe nothrow {
    foreach (i, ref m; mods) {
        foreach (ref other; mods[0 .. i]) {
            if (other.id == m.id) return true;
        }
    }
    foreach (i, ref p; pats) {
        foreach (ref other; pats[0 .. i]) {
            if (other.patternId == p.patternId) return true;
        }
    }
    return false;
}

private void writeSingleModule(ref BinaryWriter w, scope const ref SavedModule m) @safe nothrow {
    w.writeU32(m.id);
    w.writeString(m.typeId);
    w.writeString(m.name);
    w.writeF32(isFinite(m.posX) ? m.posX : 0.0f);
    w.writeF32(isFinite(m.posY) ? m.posY : 0.0f);
    w.writeU8(m.muted ? 1 : 0);
    w.writeU8(m.bypassed ? 1 : 0);

    immutable size_t pCnt = m.paramValues.length > MAX_PARAMS_PER_MODULE
        ? MAX_PARAMS_PER_MODULE : m.paramValues.length;
    w.writeU32(cast(uint) pCnt);
    foreach (p; m.paramValues[0 .. pCnt]) {
        w.writeF32(p);
    }

    w.writeLengthPrefixedBytes(m.extraBlob);
    w.writeU8(m.hasChildProject ? 1 : 0);
    if (m.hasChildProject) {
        w.writeU32(m.metaInputModuleId);
        foreach (ref mac; m.metaMacros) {
            w.writeU32(mac.targetMod.value);
            w.writeU32(mac.paramIdx);
            w.writeF32(isFinite(mac.minVal) ? mac.minVal : 0.0f);
            w.writeF32(isFinite(mac.maxVal) ? mac.maxVal : 1.0f);
            w.writeU8(mac.enabled ? 1 : 0);
        }
        w.writeLengthPrefixedBytes(m.childProjectMsv);
    }
}

private bool readSingleModule(
    ref BinaryReader r,
    out SavedModule m,
    out string err,
    uint depth
) @safe nothrow {
    m = SavedModule.init;
    err = null;

    if (!r.readU32(m.id) || m.id == 0) {
        err = "Invalid module identifier in serialized stream";
        return false;
    }
    if (!r.readString(MAX_STRING_LEN, m.typeId) || m.typeId.length == 0
            || !r.readString(MAX_STRING_LEN, m.name)) {
        err = "Malformed module header strings";
        return false;
    }
    if (!r.readF32(m.posX) || !r.readF32(m.posY)) {
        err = "Truncated module coordinates";
        return false;
    }
    if (!isFinite(m.posX)) m.posX = 0.0f;
    if (!isFinite(m.posY)) m.posY = 0.0f;

    ubyte mutedByte = 0;
    ubyte bypassedByte = 0;
    if (!r.readU8(mutedByte) || !r.readU8(bypassedByte)) {
        err = "Truncated module state flags";
        return false;
    }
    m.muted = mutedByte != 0;
    m.bypassed = bypassedByte != 0;

    uint pCnt = 0;
    if (!r.readU32(pCnt) || pCnt > MAX_PARAMS_PER_MODULE) {
        err = "Invalid module parameter count";
        return false;
    }
    if (!r.canRead(cast(size_t) pCnt * 4)) {
        err = "Truncated module parameter array";
        return false;
    }
    if (pCnt > 0) {
        m.paramValues = new float[pCnt];
        foreach (i; 0 .. pCnt) {
            float pv = 0.0f;
            if (!r.readF32(pv) || !isFinite(pv)) {
                err = "Non-finite or truncated parameter float";
                return false;
            }
            m.paramValues[i] = pv;
        }
    }

    const(ubyte)[] extraSlice;
    if (!r.readLengthPrefixedBytes(MAX_EXTRA_BLOB_BYTES, extraSlice)) {
        err = "Malformed or overflowing module extraBlob";
        return false;
    }
    if (extraSlice.length > 0) {
        m.extraBlob = extraSlice.dup;
    }

    ubyte hasChildByte = 0;
    if (!r.readU8(hasChildByte)) {
        err = "Truncated module child-project marker";
        return false;
    }
    m.hasChildProject = hasChildByte != 0;
    if (m.hasChildProject) {
        if (depth >= MAX_METAMODULE_DEPTH) {
            err = "MetaModule child project exceeds maximum nesting depth";
            return false;
        }
        if (!r.readU32(m.metaInputModuleId)) {
            err = "Truncated MetaModule input module id";
            return false;
        }
        foreach (i; 0 .. MetaModuleAsset.NUM_MACROS) {
            uint tm = 0;
            uint pi = 0;
            float mn = 0.0f;
            float mx = 1.0f;
            ubyte en = 0;
            if (!r.readU32(tm) || !r.readU32(pi) || !r.readF32(mn) || !r.readF32(mx) || !r.readU8(en)) {
                err = "Truncated MetaModule macro entry";
                return false;
            }
            if (!isFinite(mn) || !isFinite(mx)) {
                err = "Non-finite MetaModule macro range";
                return false;
            }
            m.metaMacros[i] = MetaMacroBinding(ModuleId(tm), pi, mn, mx, en != 0);
        }
        const(ubyte)[] childSlice;
        if (!r.readLengthPrefixedBytes(MAX_EXTRA_BLOB_BYTES, childSlice)) {
            err = "Malformed MetaModule nested child MSV payload";
            return false;
        }
        if (childSlice.length > 0) {
            LoadedProject unusedChild;
            if (!loadProject(childSlice, unusedChild, err, depth + 1)) {
                return false;
            }
            m.childProjectMsv = childSlice.dup;
        }
    }

    return true;
}

/**
 * Serializes a LoadedProject document into a tagged 4CC chunked .msv byte stream.
 *
 * Params:
 *   proj = Document structure containing metadata, modules, wires, patterns, and timeline clips.
 *   bytes = Output byte slice receiving serialized .msv container.
 *   err = Diagnostic error text populated on validation failure.
 *
 * Returns:
 *   True on success; false if structural caps are exceeded.
 */
bool serializeProject(const ref LoadedProject proj, out ubyte[] bytes, out string err) @safe nothrow {
    bytes = null;
    err = null;

    if (!validateProjectForSave(proj, err)) {
        return false;
    }

    BinaryWriter w;
    w.writeFourCC(['M', 'S', 'V', '1']);
    w.writeU32(proj.formatVersion > 0 ? proj.formatVersion : MSV_FORMAT_VERSION);
    w.writeU32(0);

    w.writeChunk(['M', 'E', 'T', 'A'], (ref BinaryWriter cw) @safe nothrow {
        cw.writeString(proj.title);
        cw.writeString(proj.author);
        cw.writeF64(proj.bpm);
        cw.writeU32(proj.ticksPerLine);
        cw.writeI64(proj.loopStartLine);
        cw.writeI64(proj.loopEndLine);
    });

    w.writeChunk(['M', 'O', 'D', 'S'], (ref BinaryWriter cw) @safe nothrow {
        cw.writeU32(cast(uint) proj.modules.length);
        foreach (ref m; proj.modules) {
            writeSingleModule(cw, m);
        }
    });

    w.writeChunk(['W', 'I', 'R', 'E'], (ref BinaryWriter cw) @safe nothrow {
        cw.writeU32(cast(uint) proj.wires.length);
        foreach (ref wr; proj.wires) {
            cw.writeU32(wr.srcMod);
            cw.writeU16(wr.srcPort);
            cw.writeU32(wr.dstMod);
            cw.writeU16(wr.dstPort);
            cw.writeF32(isFinite(wr.gain) ? wr.gain : 1.0f);
        }
    });

    w.writeChunk(['P', 'A', 'T', 'S'], (ref BinaryWriter cw) @safe nothrow {
        cw.writeU32(cast(uint) proj.patterns.length);
        foreach (ref pat; proj.patterns) {
            cw.writeU32(pat.patternId);
            cw.writeU32(pat.tracks);
            cw.writeU32(pat.lines);
            cw.writeString(pat.name);
            immutable size_t totalCells = cast(size_t) pat.tracks * cast(size_t) pat.lines;
            foreach (idx; 0 .. totalCells) {
                immutable ulong packed = idx < pat.cells.length ? pat.cells[idx].packU64() : 0uL;
                cw.writeU64(packed);
            }
        }
    });

    w.writeChunk(['T', 'I', 'M', 'E'], (ref BinaryWriter cw) @safe nothrow {
        cw.writeU32(cast(uint) proj.clips.length);
        foreach (ref c; proj.clips) {
            cw.writeU32(c.clipId);
            cw.writeU32(c.patternId);
            cw.writeU32(c.cloneSourceId);
            cw.writeI64(c.startLine);
            cw.writeU32(c.lengthLines);
            cw.writeU32(c.laneY);
            cw.writeU32(c.patternOffset);
            cw.writeU8(c.mute ? 1 : 0);
            cw.writeU8(c.solo ? 1 : 0);
            cw.writeU8(c.isSupertrack ? 1 : 0);
        }
    });

    if (proj.midiMappings.length > 0) {
        w.writeChunk(['M', 'I', 'D', 'I'], (ref BinaryWriter cw) @safe nothrow {
            cw.writeU32(cast(uint) proj.midiMappings.length);
            foreach (ref mm; proj.midiMappings) {
                cw.writeU8(mm.channel);
                cw.writeU8(mm.cc);
                cw.writeU32(mm.moduleId);
                cw.writeU32(mm.paramIdx);
                cw.writeF32(mm.min01);
                cw.writeF32(mm.max01);
            }
        });
    }

    bytes = w.bytes().dup;
    return true;
}

/**
 * Reports whether a MIDI mapping is storable and loadable.
 *
 * Params:
 *   mm = Mapping to check.
 *
 * Returns:
 *   True if channel < 16, cc < 128, moduleId != 0, and the range is finite within [0, 1].
 */
bool isValidMidiMapping(scope const ref SavedMidiMapping mm) @safe nothrow pure @nogc {
    return mm.channel < 16 && mm.cc < 128 && mm.moduleId != 0 && isFinite(mm.min01) && isFinite(mm.max01)
        && mm.min01 >= 0.0f && mm.min01 <= 1.0f && mm.max01 >= 0.0f && mm.max01 <= 1.0f;
}

/**
 * Serializes proj and writes the resulting .msv file to path cleanly off-RT.
 *
 * Params:
 *   proj = Project document to persist.
 *   path = Destination filesystem path.
 *   err = Error message populated on failure.
 *
 * Returns:
 *   True on write success; false otherwise.
 */
bool saveProject(const ref LoadedProject proj, string path, out string err) {
    err = null;
    if (path.length == 0) {
        err = "Project path cannot be empty";
        return false;
    }
    ubyte[] bytes;
    if (!serializeProject(proj, bytes, err)) {
        return false;
    }
    try {
        fileWrite(path, bytes);
    } catch (Exception ex) {
        err = ex.msg.length > 0 ? ex.msg : "Failed writing .msv project file";
        return false;
    }
    return true;
}

/**
 * Parses a versioned chunked .msv binary stream safely with full bounds validation.
 *
 * Unknown 4CC chunks are skipped cleanly for forward format compatibility.
 *
 * Params:
 *   bytes = Input .msv byte stream.
 *   proj = Output LoadedProject structure on success.
 *   err = Diagnostic error string populated on malformed input.
 *   depth = Internal nesting depth counter guarding recursive MetaModule projects.
 *
 * Returns:
 *   True if valid .msv document parsed; false on corrupt header, truncation, or overflow.
 */
bool loadProject(
    const(ubyte)[] bytes,
    out LoadedProject proj,
    out string err,
    uint depth = 0
) @safe nothrow {
    proj = LoadedProject.init;
    err = null;

    if (depth > MAX_METAMODULE_DEPTH) {
        err = "Nested .msv recursion limit exceeded";
        return false;
    }

    BinaryReader r = BinaryReader(bytes);
    char[4] magic;
    uint versionNum = 0;
    uint flags = 0;
    if (!r.readFourCC(magic) || magic != ['M', 'S', 'V', '1']
            || !r.readU32(versionNum) || !r.readU32(flags)) {
        err = "Invalid or truncated .msv header";
        return false;
    }
    if (versionNum == 0 || versionNum > MSV_FORMAT_VERSION) {
        err = "Unsupported .msv format version";
        return false;
    }
    proj.formatVersion = versionNum;
    bool hasMeta = false;
    bool hasMods = false;

    while (!r.atEnd()) {
        char[4] chunkId;
        BinaryReader sub;
        if (!r.readChunk(chunkId, sub)) {
            err = "Malformed or truncated .msv chunk framing";
            return false;
        }

        if (chunkId == ['M', 'E', 'T', 'A']) {
            double bpmVal = 125.0;
            uint tplVal = 6;
            long ls = 0;
            long le = 0;
            if (!sub.readString(MAX_STRING_LEN, proj.title)
                    || !sub.readString(MAX_STRING_LEN, proj.author)
                    || !sub.readF64(bpmVal)
                    || !sub.readU32(tplVal)
                    || !sub.readI64(ls)
                    || !sub.readI64(le)) {
                err = "Truncated META chunk";
                return false;
            }
            if (!isValidTempo(bpmVal, tplVal)) {
                err = "Out-of-range BPM or TPL in META chunk";
                return false;
            }
            proj.bpm = bpmVal;
            proj.ticksPerLine = tplVal;
            proj.loopStartLine = ls;
            proj.loopEndLine = le;
            hasMeta = true;
        } else if (chunkId == ['M', 'O', 'D', 'S']) {
            uint modCount = 0;
            if (!sub.readU32(modCount) || modCount > MAX_MODULES) {
                err = "Invalid module count in MODS chunk";
                return false;
            }
            if (sub.remaining() < cast(size_t) modCount * 22) {
                err = "Insufficient remaining bytes for declared MODS entries";
                return false;
            }
            if (modCount > 0) {
                proj.modules = new SavedModule[modCount];
                foreach (i; 0 .. modCount) {
                    if (!readSingleModule(sub, proj.modules[i], err, depth)) {
                        return false;
                    }
                }
            }
            hasMods = true;
        } else if (chunkId == ['W', 'I', 'R', 'E']) {
            uint wireCount = 0;
            if (!sub.readU32(wireCount) || wireCount > MAX_WIRES) {
                err = "Invalid wire count in WIRE chunk";
                return false;
            }
            if (sub.remaining() < cast(size_t) wireCount * 16) {
                err = "Insufficient remaining bytes for WIRE entries";
                return false;
            }
            if (wireCount > 0) {
                proj.wires = new SavedWire[wireCount];
                foreach (i; 0 .. wireCount) {
                    SavedWire w;
                    if (!sub.readU32(w.srcMod) || !sub.readU16(w.srcPort)
                            || !sub.readU32(w.dstMod) || !sub.readU16(w.dstPort)
                            || !sub.readF32(w.gain)) {
                        err = "Truncated WIRE record";
                        return false;
                    }
                    if (!isFinite(w.gain)) {
                        err = "Non-finite wire gain";
                        return false;
                    }
                    proj.wires[i] = w;
                }
            }
        } else if (chunkId == ['P', 'A', 'T', 'S']) {
            uint patCount = 0;
            if (!sub.readU32(patCount) || patCount > MAX_PATTERNS) {
                err = "Invalid pattern count in PATS chunk";
                return false;
            }
            if (sub.remaining() < cast(size_t) patCount * 16) {
                err = "Insufficient remaining bytes for PATS entries";
                return false;
            }
            if (patCount > 0) {
                proj.patterns = new SavedPattern[patCount];
                foreach (i; 0 .. patCount) {
                    SavedPattern pat;
                    if (!sub.readU32(pat.patternId)
                            || !sub.readU32(pat.tracks)
                            || !sub.readU32(pat.lines)
                            || !sub.readString(MAX_STRING_LEN, pat.name)) {
                        err = "Truncated pattern header";
                        return false;
                    }
                    if (pat.tracks == 0 || pat.tracks > MAX_TRACKS
                            || pat.lines == 0 || pat.lines > MAX_LINES) {
                        err = "Invalid pattern dimensions";
                        return false;
                    }
                    immutable ulong cellCount64 = cast(ulong) pat.tracks * cast(ulong) pat.lines;
                    if (cellCount64 > MAX_CELLS_PER_PATTERN
                            || sub.remaining() < cast(size_t) cellCount64 * 8) {
                        err = "Pattern cell payload truncated or oversized";
                        return false;
                    }
                    immutable size_t cellCount = cast(size_t) cellCount64;
                    pat.cells = new NoteCell[cellCount];
                    foreach (cIdx; 0 .. cellCount) {
                        ulong packed = 0;
                        if (!sub.readU64(packed)) {
                            err = "Truncated pattern cell data";
                            return false;
                        }
                        pat.cells[cIdx] = NoteCell.unpackU64(packed);
                    }
                    proj.patterns[i] = pat;
                }
            }
        } else if (chunkId == ['M', 'I', 'D', 'I']) {
            uint mapCount = 0;
            if (!sub.readU32(mapCount) || mapCount > MAX_MIDI_MAPPINGS) {
                err = "Invalid mapping count in MIDI chunk";
                return false;
            }
            if (sub.remaining() < cast(size_t) mapCount * 18) {
                err = "Insufficient remaining bytes for MIDI entries";
                return false;
            }
            proj.midiMappings = new SavedMidiMapping[mapCount];
            foreach (i; 0 .. mapCount) {
                SavedMidiMapping mm;
                if (!sub.readU8(mm.channel) || !sub.readU8(mm.cc) || !sub.readU32(mm.moduleId)
                        || !sub.readU32(mm.paramIdx) || !sub.readF32(mm.min01) || !sub.readF32(mm.max01)) {
                    err = "Truncated MIDI mapping entry";
                    return false;
                }
                if (!isValidMidiMapping(mm)) {
                    err = "Invalid MIDI mapping entry";
                    return false;
                }
                proj.midiMappings[i] = mm;
            }
        } else if (chunkId == ['T', 'I', 'M', 'E']) {
            uint clipCount = 0;
            if (!sub.readU32(clipCount) || clipCount > MAX_CLIPS) {
                err = "Invalid clip count in TIME chunk";
                return false;
            }
            if (sub.remaining() < cast(size_t) clipCount * 35) {
                err = "Insufficient remaining bytes for TIME entries";
                return false;
            }
            if (clipCount > 0) {
                proj.clips = new TimelineClip[clipCount];
                foreach (i; 0 .. clipCount) {
                    TimelineClip c;
                    ubyte mB = 0;
                    ubyte sB = 0;
                    ubyte stB = 0;
                    if (!sub.readU32(c.clipId)
                            || !sub.readU32(c.patternId)
                            || !sub.readU32(c.cloneSourceId)
                            || !sub.readI64(c.startLine)
                            || !sub.readU32(c.lengthLines)
                            || !sub.readU32(c.laneY)
                            || !sub.readU32(c.patternOffset)
                            || !sub.readU8(mB)
                            || !sub.readU8(sB)
                            || !sub.readU8(stB)) {
                        err = "Truncated TIME clip entry";
                        return false;
                    }
                    c.mute = mB != 0;
                    c.solo = sB != 0;
                    c.isSupertrack = stB != 0;
                    proj.clips[i] = c;
                }
            }
        }
    }

    if (!hasMeta || !hasMods) {
        err = "Missing mandatory META or MODS chunk";
        return false;
    }
    if (hasDuplicateIds(proj.modules, proj.patterns)) {
        err = "Duplicate module or pattern identifier";
        return false;
    }
    return true;
}

/**
 * Reads an .msv project file from disk and parses it via loadProject().
 *
 * Params:
 *   path = UTF-8 path to .msv file.
 *   proj = Parsed LoadedProject on success.
 *   err = Error message populated on I/O or format error.
 *
 * Returns:
 *   True on success.
 */
bool loadProjectFile(string path, out LoadedProject proj, out string err) {
    err = null;
    if (path.length == 0) {
        err = "Project file path cannot be empty";
        return false;
    }
    const(ubyte)[] raw;
    try {
        raw = cast(const(ubyte)[]) fileRead(path);
    } catch (Exception ex) {
        err = ex.msg.length > 0 ? ex.msg : "Failed reading .msv project file";
        return false;
    }
    return loadProject(raw, proj, err);
}

/**
 * Serializes a LoadedPreset into a tagged 4CC .msym module preset byte stream.
 *
 * Params:
 *   preset = Preset payload carrying module parameters, extraBlob, and optional child project.
 *   bytes = Output serialized .msym bytes.
 *   err = Error message on validation failure.
 *
 * Returns:
 *   True on success.
 */
bool serializePreset(const ref LoadedPreset preset, out ubyte[] bytes, out string err) @safe nothrow {
    bytes = null;
    err = null;
    if (preset.presetName.length > MAX_STRING_LEN) {
        err = "Preset name too long";
        return false;
    }
    if (!validateModuleForSave(preset.mod, 0, err)) {
        return false;
    }

    BinaryWriter w;
    w.writeFourCC(['M', 'S', 'Y', 'M']);
    w.writeU32(preset.formatVersion > 0 ? preset.formatVersion : MSV_FORMAT_VERSION);
    w.writeU32(0);

    w.writeChunk(['P', 'S', 'E', 'T'], (ref BinaryWriter cw) @safe nothrow {
        cw.writeString(preset.presetName);
        writeSingleModule(cw, preset.mod);
    });

    bytes = w.bytes().dup;
    return true;
}

/**
 * Writes preset serialized as .msym cleanly to path off-RT.
 *
 * Params:
 *   preset = LoadedPreset to serialize.
 *   path = Destination filesystem path.
 *   err = Error message on failure.
 *
 * Returns:
 *   True on write success.
 */
bool savePreset(const ref LoadedPreset preset, string path, out string err) {
    err = null;
    if (path.length == 0) {
        err = "Preset path cannot be empty";
        return false;
    }
    ubyte[] bytes;
    if (!serializePreset(preset, bytes, err)) {
        return false;
    }
    try {
        fileWrite(path, bytes);
    } catch (Exception ex) {
        err = ex.msg.length > 0 ? ex.msg : "Failed writing .msym preset file";
        return false;
    }
    return true;
}

/**
 * Parses a versioned .msym preset byte stream safely, skipping unknown forward chunks.
 *
 * Params:
 *   bytes = Encoded .msym payload bytes.
 *   preset = Destination LoadedPreset populated on success.
 *   err = Error message populated on corrupt header/chunk.
 *
 * Returns:
 *   True on valid preset load; false otherwise.
 */
bool loadPreset(const(ubyte)[] bytes, out LoadedPreset preset, out string err) @safe nothrow {
    preset = LoadedPreset.init;
    err = null;

    BinaryReader r = BinaryReader(bytes);
    char[4] magic;
    uint ver = 0;
    uint flags = 0;
    if (!r.readFourCC(magic) || magic != ['M', 'S', 'Y', 'M']
            || !r.readU32(ver) || !r.readU32(flags)) {
        err = "Invalid or truncated .msym header";
        return false;
    }
    if (ver == 0 || ver > MSV_FORMAT_VERSION) {
        err = "Unsupported .msym version";
        return false;
    }
    preset.formatVersion = ver;
    bool hasPset = false;

    while (!r.atEnd()) {
        char[4] cid;
        BinaryReader sub;
        if (!r.readChunk(cid, sub)) {
            err = "Truncated .msym chunk framing";
            return false;
        }
        if (cid == ['P', 'S', 'E', 'T']) {
            if (!sub.readString(MAX_STRING_LEN, preset.presetName)
                    || !readSingleModule(sub, preset.mod, err, 0)) {
                return false;
            }
            hasPset = true;
        }
    }

    if (!hasPset) {
        err = "Missing mandatory PSET chunk";
        return false;
    }
    return true;
}

/**
 * Reads an .msym preset file from disk and parses it safely via loadPreset().
 *
 * Params:
 *   path = Path to .msym file.
 *   preset = Destination LoadedPreset.
 *   err = Error message on failure.
 *
 * Returns:
 *   True on success.
 */
bool loadPresetFile(string path, out LoadedPreset preset, out string err) {
    err = null;
    if (path.length == 0) {
        err = "Preset path cannot be empty";
        return false;
    }
    const(ubyte)[] raw;
    try {
        raw = cast(const(ubyte)[]) fileRead(path);
    } catch (Exception ex) {
        err = ex.msg.length > 0 ? ex.msg : "Failed reading .msym preset file";
        return false;
    }
    return loadPreset(raw, preset, err);
}

/**
 * Materializes a parsed LoadedProject cleanly off-RT into an initialized Engine and owned ModuleInstances.
 *
 * Params:
 *   proj = Parsed LoadedProject structure.
 *   eng = Initialized target Engine receiving plan, patterns, timeline, and tempo.
 *   sampleRate = Audio sample rate in Hertz.
 *   ownedModules = Receives instantiated ModuleInstances owned by the caller/session.
 *   err = Diagnostic error string populated if module creation or GraphCompiler fails.
 *   depth = Recursion level for nested MetaModules.
 *
 * Returns:
 *   True on success; cleans up partially instantiated modules on failure.
 */
bool materializeProjectToEngine(
    const ref LoadedProject proj,
    ref Engine eng,
    float sampleRate,
    out ModuleInstance[] ownedModules,
    out string err,
    uint depth = 0
) {
    ownedModules = null;
    err = null;
    if (depth > MAX_METAMODULE_DEPTH) {
        err = "MetaModule materialization recursion depth exceeded";
        return false;
    }

    void cleanupAll() {
        eng.releaseAllOwnedResources();
        foreach (ref inst; ownedModules) {
            inst.destroyOffRT();
        }
        ownedModules = null;
    }

    ownedModules.length = proj.modules.length;
    auto nodeSpecs = new NodeSpec[proj.modules.length];

    foreach (i, ref sm; proj.modules) {
        ModuleInstance inst;
        if (!ModuleRegistry.createOffRT(sm.typeId, ModuleId(sm.id), sampleRate, inst)) {
            err = "Unknown or failed module typeId during materialize: " ~ sm.typeId;
            cleanupAll();
            return false;
        }
        ownedModules[i] = inst;

        foreach (pIdx, val; sm.paramValues) {
            if (inst.desc.vtable !is null && inst.desc.vtable.setParam !is null) {
                inst.desc.vtable.setParam(inst.state, cast(uint) pIdx, val, sampleRate, true);
            }
        }
        if (sm.extraBlob.length > 0 && inst.desc.vtable !is null && inst.desc.vtable.deserializeExtra !is null) {
            if (!inst.desc.vtable.deserializeExtra(inst.state, sm.extraBlob, sampleRate)) {
                err = "Failed deserializing module extraBlob for id";
                cleanupAll();
                return false;
            }
        }
        if (sm.typeId == "ctl.metamodule" && sm.hasChildProject) {
            MetaModuleAsset* asset = MetaModuleAsset.createOffRT(sampleRate);
            if (asset is null) {
                err = "Out of memory allocating MetaModuleAsset";
                cleanupAll();
                return false;
            }
            if (sm.childProjectMsv.length > 0) {
                LoadedProject childProj;
                if (!loadProject(sm.childProjectMsv, childProj, err, depth + 1)) {
                    MetaModuleAsset.destroyOffRT(asset);
                    cleanupAll();
                    return false;
                }
                ModuleInstance[] childOwned;
                if (!materializeProjectToEngine(childProj, asset.childEngine, sampleRate, childOwned, err, depth + 1)) {
                    MetaModuleAsset.destroyOffRT(asset);
                    cleanupAll();
                    return false;
                }
                foreach (ref cm; childOwned) {
                    asset.adoptModule(cm);
                }
            }
            asset.inputModuleId = ModuleId(sm.metaInputModuleId);
            asset.macros = sm.metaMacros;

            void* prevAsset = null;
            if (!inst.desc.vtable.swapAsset(inst.state, 0, asset, prevAsset)) {
                MetaModuleAsset.destroyOffRT(asset);
                err = "Failed attaching materialized MetaModuleAsset";
                cleanupAll();
                return false;
            }
            if (prevAsset !is null) {
                MetaModuleAsset.destroyErased(prevAsset);
            }
        }

        nodeSpecs[i] = NodeSpec.fromInstance(ownedModules[i], sm.muted, sm.bypassed);
    }

    auto wireSpecs = new WireSpec[proj.wires.length];
    foreach (i, ref sw; proj.wires) {
        wireSpecs[i] = WireSpec(
            ModuleId(sw.srcMod),
            sw.srcPort,
            ModuleId(sw.dstMod),
            sw.dstPort,
            sw.gain
        );
    }

    GraphPlan* plan = null;
    GraphCompileError gErr;
    if (!GraphCompiler.compile(nodeSpecs, wireSpecs, plan, gErr)) {
        err = "GraphCompiler rejected materialized project wiring";
        cleanupAll();
        return false;
    }

    eng.attachPlanOffRT(plan);
    foreach (ref sp; proj.patterns) {
        PatternSnapshot* snap = PatternSnapshot.createOffRT(sp.patternId, sp.tracks, sp.lines);
        if (snap is null) {
            err = "Out of memory allocating pattern snapshot during materialize";
            cleanupAll();
            return false;
        }
        foreach (ln; 0 .. sp.lines) {
            foreach (tr; 0 .. sp.tracks) {
                immutable size_t cIdx = cast(size_t) ln * cast(size_t) sp.tracks + cast(size_t) tr;
                if (cIdx < sp.cells.length) {
                    snap.setCellAtomic(tr, ln, sp.cells[cIdx]);
                }
            }
        }
        if (!eng.attachPatternOffRT(sp.patternId, snap)) {
            PatternSnapshot.destroyOffRT(snap);
            err = "Engine pattern slots exhausted during materialize";
            cleanupAll();
            return false;
        }
    }

    TimelineSnapshot* tl = TimelineSnapshot.createOffRT(proj.clips, proj.loopStartLine, proj.loopEndLine);
    if (tl is null && proj.clips.length > 0) {
        err = "Out of memory allocating TimelineSnapshot";
        cleanupAll();
        return false;
    }
    eng.attachTimelineOffRT(tl);
    eng.setTempo(proj.bpm, proj.ticksPerLine);
    eng.seekLine(0);
    return true;
}
