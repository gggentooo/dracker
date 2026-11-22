/**
 * File:         source/io/importers/sunvox_importer.d
 * Module:       io.importers.sunvox_importer
 * Phase:        Phase 6.5 (Optional) — Best-Effort .sunvox Structural Importer
 *
 * Purpose:
 *   Imports legacy .sunvox project structures on a best-effort basis—mapping patterns, timeline clips, wiring topology, and compatible module parameters onto SynthTracker's clean-slate DSP modules (musical equivalence rather than bit-exact clone output).
 *
 * Real-Time & Safety Contract:
 *   Off-RT @safe chunk parsing via io.binary_stream with strict chunk limits.
 *
 * Dependencies:
 *   Internal: graph.module_api, graph.port, graph.registry, io.binary_stream, io.project_format, sequencer.{note,timeline}
 *   External: std.string (toLower)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ImportReport { uint mappedModules; uint skippedModules; uint droppedNoteTargets; string[] warnings; }
 *   - bool importSunvoxFile(const(ubyte)[] bytes, out LoadedProject proj, out ImportReport report, out string err)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.importers.sunvox_importer;

import graph.module_api : ModuleDescriptor;
import graph.port : PortDescriptor, PortDirection, PortKind, arePortsCompatible;
import graph.registry : ModuleRegistry;
import io.binary_stream : BinaryReader;
import io.project_format : LoadedProject, MAX_CLIPS, MAX_LINES, MAX_MODULES, MAX_PARAMS_PER_MODULE,
    MAX_PATTERNS, MAX_STRING_LEN, MAX_TRACKS, MAX_WIRES, SavedModule, SavedPattern, SavedWire;
import sequencer.note : NoteCell, NoteCmd;
import sequencer.timeline : TimelineClip;

/**
 * Diagnostic summary returned by importSunvoxFile() reporting mapped and skipped legacy modules.
 */
struct ImportReport {
    uint mappedModules = 0;
    uint skippedModules = 0;
    uint droppedNoteTargets = 0;
    string[] warnings;
}

/**
 * Rewrites a cell's raw SunVox module index (0 = none) into the assigned SynthTracker ModuleId.
 *
 * Params:
 *   cell = Pattern cell whose moduleId still holds the raw SunVox module index.
 *   indexToId = Raw module index to assigned ModuleId table (0 marks skipped modules).
 *
 * Returns:
 *   True if the cell targets a mapped module or no module; false if its target was skipped and was cleared.
 */
private bool remapCellModule(ref NoteCell cell, const(uint)[] indexToId) @safe nothrow pure @nogc {
    immutable size_t rawIdx = cell.moduleId;
    if (rawIdx == 0) {
        return true;
    }
    immutable uint mapped = rawIdx < indexToId.length ? indexToId[rawIdx] : 0;
    if (mapped == 0 || mapped > ushort.max) {
        cell = NoteCell.init;
        return false;
    }
    cell.moduleId = cast(ushort) mapped;
    return true;
}

private string asciiLower(string raw) @safe nothrow {
    if (raw.length == 0) {
        return "";
    }
    char[] buf = raw.dup;
    foreach (ref ch; buf) {
        if (ch >= 'A' && ch <= 'Z') {
            ch = cast(char)(ch + ('a' - 'A'));
        }
    }
    return buf.idup;
}

private const(ModuleDescriptor)* findDescriptorSafe(string typeId) @trusted nothrow {
    return ModuleRegistry.findByTypeId(typeId);
}

private string mapLegacySunvoxType(string rawType) @safe nothrow {
    string lower = asciiLower(rawType);
    switch (lower) {
        case "output":
        case "master":
            return "core.output";
        case "analog generator":
        case "generator":
            return "synth.analog_gen";
        case "fm":
        case "fmx":
            return "synth.fm_synth";
        case "drumsynth":
            return "synth.drumsynth";
        case "kicker":
            return "synth.kicker";
        case "sampler":
            return "synth.sampler";
        case "spectravoice":
            return "synth.spectravoice";
        case "input":
            return "synth.input";
        case "vorbis player":
            return "synth.vorbis_player";
        case "amplifier":
            return "fx.amplifier";
        case "dc blocker":
            return "fx.dc_blocker";
        case "filter":
        case "filter pro":
            return "fx.filter_pro";
        case "distortion":
            return "fx.distortion";
        case "delay":
            return "fx.delay";
        case "echo":
            return "fx.echo";
        case "reverb":
            return "fx.reverb";
        case "compressor":
            return "fx.compressor";
        case "eq":
            return "fx.eq3";
        case "waveshaper":
            return "fx.waveshaper";
        case "flanger":
            return "fx.flanger";
        case "vibrato":
            return "fx.vibrato";
        case "modulator":
            return "fx.modulator";
        case "smooth":
            return "fx.smooth";
        case "vocal filter":
            return "fx.vocal_filter";
        case "pitch shifter":
            return "fx.pitch_shifter";
        case "fft":
            return "fx.fft";
        case "loop":
            return "fx.loop";
        case "lfo":
            return "fx.lfo";
        case "multisynth":
            return "ctl.multisynth";
        case "multictl":
            return "ctl.multictl";
        case "adsr":
            return "ctl.adsr";
        case "feedback":
            return "ctl.feedback";
        case "glide":
            return "ctl.glide";
        case "ctl2note":
            return "ctl.ctl2note";
        case "pitch2ctl":
            return "ctl.pitch2ctl";
        case "velocity2ctl":
            return "ctl.velocity2ctl";
        case "sound2ctl":
            return "ctl.sound2ctl";
        case "pitch detector":
            return "ctl.pitch_detector";
        case "metamodule":
            return "ctl.metamodule";
        default:
            return null;
    }
}

private string stripNulls(const(ubyte)[] raw) @safe nothrow {
    size_t len = 0;
    while (len < raw.length && raw[len] != 0) {
        len++;
    }
    if (len == 0) {
        return "";
    }
    return cast(string)(raw[0 .. len].idup);
}

private bool selectCompatiblePorts(
    string srcTypeId,
    string dstTypeId,
    out ushort srcPort,
    out ushort dstPort
) @safe nothrow {
    srcPort = 0;
    dstPort = 0;
    const(ModuleDescriptor)* sd = findDescriptorSafe(srcTypeId);
    const(ModuleDescriptor)* dd = findDescriptorSafe(dstTypeId);
    if (sd is null || dd is null) {
        return false;
    }
    foreach (si, ref sp; sd.ports) {
        if (sp.dir != PortDirection.output) continue;
        foreach (di, ref dp; dd.ports) {
            if (dp.dir != PortDirection.input) continue;
            if (arePortsCompatible(sp.kind, dp.kind)) {
                srcPort = cast(ushort) si;
                dstPort = cast(ushort) di;
                return true;
            }
        }
    }
    return false;
}

/**
 * Performs best-effort structural import of a legacy SVOX chunked .sunvox stream into LoadedProject.
 *
 * Maps compatible legacy synth/effect/control module names to SynthTracker's clean-slate
 * typeIds, translates pattern tracks/lines and links onto typed ports, skips unknown chunks and
 * unsupported legacy module types cleanly, and reports all skipped items in report.
 *
 * Params:
 *   bytes = Binary .sunvox stream payload beginning with "SVOX".
 *   proj = Populated LoadedProject on success.
 *   report = Diagnostic summary listing mapped/skipped modules and warnings.
 *   err = Error string populated if the stream fails SVOX framing or contains invalid bounds.
 *
 * Returns:
 *   True on valid SVOX stream import; false on corrupt header or truncation.
 */
bool importSunvoxFile(
    const(ubyte)[] bytes,
    out LoadedProject proj,
    out ImportReport report,
    out string err
) @safe nothrow {
    proj = LoadedProject.init;
    report = ImportReport.init;
    err = null;

    BinaryReader r = BinaryReader(bytes);
    char[4] magic;
    if (!r.readFourCC(magic) || magic != ['S', 'V', 'O', 'X']) {
        err = "Invalid .sunvox magic header (expected SVOX)";
        return false;
    }

    proj.title = "SunVox Import";
    proj.author = "SunVox Importer";
    proj.bpm = 125.0;
    proj.ticksPerLine = 6;

    struct RawSvMod {
        bool valid = false;
        string name;
        string legacyType;
        string mappedType;
        float posX = 0.0f;
        float posY = 0.0f;
        bool muted = false;
        uint[] links;
        float[] cvals;
    }

    struct RawSvPat {
        uint tracks = 1;
        uint lines = 16;
        long startLine = 0;
        uint laneY = 0;
        uint cloneOf = uint.max;
        NoteCell[] cells;
    }

    RawSvMod[] rawMods;
    RawSvPat[] rawPats;

    bool inMod = false;
    RawSvMod curMod;
    bool inPat = false;
    RawSvPat curPat;

    while (!r.atEnd()) {
        char[4] cid;
        BinaryReader sub;
        if (!r.readChunk(cid, sub)) {
            err = "Malformed or truncated SVOX chunk";
            return false;
        }

        if (cid == ['N', 'A', 'M', 'E']) {
            if (!inMod && !inPat) {
                const(ubyte)[] nameBytes;
                sub.readBytes(sub.remaining(), nameBytes);
                proj.title = stripNulls(nameBytes);
            }
        } else if (cid == ['B', 'P', 'M', ' ']) {
            uint bVal = 125;
            if (sub.readU32(bVal) && bVal >= 20 && bVal <= 999) {
                proj.bpm = cast(double) bVal;
            }
        } else if (cid == ['S', 'P', 'E', 'D']) {
            uint sVal = 6;
            if (sub.readU32(sVal) && sVal >= 1 && sVal <= 255) {
                proj.ticksPerLine = sVal;
            }
        } else if (cid == ['P', 'D', 'T', 'A'] || cid == ['P', 'C', 'H', 'N']
                || cid == ['P', 'L', 'I', 'N'] || cid == ['P', 'X', 'X', 'X']
                || cid == ['P', 'Y', 'Y', 'Y'] || cid == ['P', 'F', 'L', 'G']) {
            inPat = true;
            if (cid == ['P', 'C', 'H', 'N']) {
                uint tc = 1;
                if (sub.readU32(tc) && tc >= 1 && tc <= MAX_TRACKS) curPat.tracks = tc;
            } else if (cid == ['P', 'L', 'I', 'N']) {
                uint lc = 16;
                if (sub.readU32(lc) && lc >= 1 && lc <= MAX_LINES) curPat.lines = lc;
            } else if (cid == ['P', 'X', 'X', 'X']) {
                int sx = 0;
                if (sub.readI32(sx) && sx >= 0) curPat.startLine = sx;
            } else if (cid == ['P', 'Y', 'Y', 'Y']) {
                uint ly = 0;
                if (sub.readU32(ly)) curPat.laneY = ly;
            } else if (cid == ['P', 'D', 'T', 'A']) {
                immutable size_t count = sub.remaining() / 8;
                if (count > 0 && count <= MAX_TRACKS * MAX_LINES) {
                    curPat.cells = new NoteCell[count];
                    foreach (i; 0 .. count) {
                        ubyte nn = 0, vv = 0, mm = 0, ee = 0;
                        ushort cc = 0, xxyy = 0;
                        if (!sub.readU8(nn) || !sub.readU8(vv) || !sub.readU8(mm)
                                || !sub.readU8(ee) || !sub.readU16(cc) || !sub.readU16(xxyy)) {
                            break;
                        }
                        NoteCell nc;
                        if (nn >= 1 && nn <= 128) {
                            nc.note = nn;
                        } else if (nn == 129) {
                            nc.note = NoteCmd.noteOff;
                        }
                        if (vv > 0 && vv <= 129) {
                            nc.velocity = NoteCell.encodeVelocity(cast(float)(vv - 1) / 128.0f);
                        }
                        nc.moduleId = mm;
                        nc.paramId = cc;
                        nc.effect = ee;
                        nc.effectVal = cast(ubyte)(xxyy & 0xFFu);
                        curPat.cells[i] = nc;
                    }
                }
            }
        } else if (cid == ['P', 'E', 'N', 'D']) {
            if (inPat && rawPats.length < MAX_PATTERNS) {
                rawPats ~= curPat;
            }
            curPat = RawSvPat.init;
            inPat = false;
        } else if (cid == ['S', 'F', 'F', 'F'] || cid == ['S', 'N', 'A', 'M']
                || cid == ['S', 'T', 'Y', 'P'] || cid == ['S', 'X', 'X', 'X']
                || cid == ['S', 'Y', 'Y', 'Y'] || cid == ['S', 'L', 'N', 'K']
                || cid == ['C', 'V', 'A', 'L']) {
            inMod = true;
            curMod.valid = true;
            if (cid == ['S', 'F', 'F', 'F']) {
                uint flags = 0;
                if (sub.readU32(flags)) curMod.muted = (flags & 0x01u) != 0;
            } else if (cid == ['S', 'N', 'A', 'M']) {
                const(ubyte)[] sNamBytes;
                sub.readBytes(sub.remaining(), sNamBytes);
                curMod.name = stripNulls(sNamBytes);
            } else if (cid == ['S', 'T', 'Y', 'P']) {
                const(ubyte)[] sTypBytes;
                sub.readBytes(sub.remaining(), sTypBytes);
                curMod.legacyType = stripNulls(sTypBytes);
                curMod.mappedType = mapLegacySunvoxType(curMod.legacyType);
            } else if (cid == ['S', 'X', 'X', 'X']) {
                int x = 0;
                if (sub.readI32(x)) curMod.posX = cast(float) x;
            } else if (cid == ['S', 'Y', 'Y', 'Y']) {
                int y = 0;
                if (sub.readI32(y)) curMod.posY = cast(float) y;
            } else if (cid == ['S', 'L', 'N', 'K']) {
                immutable size_t cnt = sub.remaining() / 4;
                immutable size_t capped = cnt < MAX_WIRES ? cnt : MAX_WIRES;
                foreach (_; 0 .. capped) {
                    int linkIdx = -1;
                    if (sub.readI32(linkIdx) && linkIdx >= 0) {
                        curMod.links ~= cast(uint) linkIdx;
                    }
                }
            } else if (cid == ['C', 'V', 'A', 'L']) {
                uint val = 0;
                if (sub.readU32(val) && curMod.cvals.length < MAX_PARAMS_PER_MODULE) {
                    curMod.cvals ~= cast(float) val / 32_768.0f;
                }
            }
        } else if (cid == ['S', 'E', 'N', 'D']) {
            if (inMod && curMod.valid && rawMods.length < MAX_MODULES) {
                rawMods ~= curMod;
            }
            curMod = RawSvMod.init;
            inMod = false;
        }
    }

    auto indexToId = new uint[rawMods.length];
    auto indexToType = new string[rawMods.length];
    uint nextId = 1;

    foreach (i, ref rm; rawMods) {
        if (rm.mappedType.length == 0) {
            report.skippedModules++;
            report.warnings ~= "Skipped unsupported legacy module type: " ~ rm.legacyType;
            continue;
        }
        immutable uint assignedId = nextId++;
        indexToId[i] = assignedId;
        indexToType[i] = rm.mappedType;

        SavedModule sm;
        sm.id = assignedId;
        sm.typeId = rm.mappedType;
        sm.name = rm.name.length > 0 ? rm.name : rm.legacyType;
        sm.posX = rm.posX;
        sm.posY = rm.posY;
        sm.muted = rm.muted;
        if (rm.cvals.length > 0) {
            const(ModuleDescriptor)* desc = findDescriptorSafe(sm.typeId);
            if (desc !is null) {
                immutable size_t pLen = rm.cvals.length < desc.params.length ? rm.cvals.length : desc.params.length;
                sm.paramValues = new float[desc.params.length];
                foreach (pi, ref pd; desc.params) {
                    sm.paramValues[pi] = pi < pLen
                        ? (pd.minVal + rm.cvals[pi] * (pd.maxVal - pd.minVal))
                        : pd.defaultVal;
                }
            }
        }
        proj.modules ~= sm;
        report.mappedModules++;
    }

    if (proj.modules.length == 0) {
        SavedModule master;
        master.id = 1;
        master.typeId = "core.output";
        master.name = "Master";
        proj.modules ~= master;
    }

    foreach (srcIdx, ref rm; rawMods) {
        if (indexToId[srcIdx] == 0) continue;
        foreach (dstIdx; rm.links) {
            if (dstIdx >= rawMods.length || indexToId[dstIdx] == 0) {
                continue;
            }
            if (proj.wires.length >= MAX_WIRES) break;
            ushort sPort = 0;
            ushort dPort = 0;
            if (selectCompatiblePorts(indexToType[srcIdx], indexToType[dstIdx], sPort, dPort)) {
                proj.wires ~= SavedWire(indexToId[srcIdx], sPort, indexToId[dstIdx], dPort, 1.0f);
            }
        }
    }

    foreach (pi, ref rp; rawPats) {
        if (proj.clips.length >= MAX_CLIPS) break;
        SavedPattern sp;
        sp.patternId = cast(uint)(pi + 1);
        sp.tracks = rp.tracks;
        sp.lines = rp.lines;
        sp.cells = rp.cells;
        if (sp.cells.length < cast(size_t) sp.tracks * sp.lines) {
            sp.cells.length = cast(size_t) sp.tracks * sp.lines;
        }
        foreach (ref cell; sp.cells) {
            if (!remapCellModule(cell, indexToId)) {
                report.droppedNoteTargets++;
            }
        }
        proj.patterns ~= sp;
        proj.clips ~= TimelineClip(
            cast(uint)(pi + 1),
            sp.patternId,
            0,
            rp.startLine,
            rp.lines,
            rp.laneY,
            0,
            false,
            false,
            false
        );
    }

    return true;
}
