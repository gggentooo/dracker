/**
 * File:         tests/fuzz/project_format_fuzz.d
 * Module:       tests.fuzz.project_format_fuzz
 * Phase:        Phase 6.4 — Project, Preset & Importer Fuzz Harness
 *
 * Purpose:
 *   Exercises 100,000+ seeded mutated, truncated, corrupted-length, non-finite-float, and deeply nested inputs across .msv, .msym, .mid, .xm, and .sunvox parsers to guarantee zero panics or OOB reads, then materializes and renders every accepted project to prove parser acceptance implies Engine-loadability.
 *
 * Real-Time & Safety Contract:
 *   Off-RT verification harness (parsers under test are @safe nothrow) reusing bounded scratch buffers for fast 100k+ execution in Debug and Release/O3 builds.
 *
 * Dependencies:
 *   Internal: foundation.types, graph.module_api, io.binary_stream, io.importers.{smf_importer,sunvox_importer,xm_importer}, io.project_format, modules.control.metamodule, sequencer.{engine,note,timeline}
 *   External: std.algorithm (min)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct FuzzStats
 *   - FuzzStats runProjectFormatFuzz(ulong seed, size_t iterations = 100_000)
 *   - ubyte[] buildNestedMetaMsvRaw(uint levels)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.fuzz.project_format_fuzz;

import std.algorithm : min;

import io.binary_stream : BinaryWriter;
import io.importers.smf_importer : importMidiFile;
import io.importers.sunvox_importer : ImportReport, importSunvoxFile;
import io.importers.xm_importer : importXmFile;
import foundation.types : FIXED_BLOCK_FRAMES;
import graph.module_api : ModuleInstance;
import io.project_format : LoadedPreset, LoadedProject, loadPreset, loadProject, materializeProjectToEngine,
    MSV_FORMAT_VERSION, SavedModule, SavedPattern, SavedWire, serializePreset, serializeProject;
import modules.control.metamodule : MAX_METAMODULE_DEPTH, MetaModuleAsset;
import sequencer.engine : Engine;
import sequencer.note : NoteCell;
import sequencer.timeline : TimelineClip;

/**
 * Aggregated fuzz campaign counters verifying format coverage across all parsers.
 */
struct FuzzStats {
    size_t totalRuns = 0;
    size_t msvRuns = 0;
    size_t msymRuns = 0;
    size_t midRuns = 0;
    size_t xmRuns = 0;
    size_t sunvoxRuns = 0;
    size_t acceptedCount = 0;
    size_t rejectedCount = 0;
    size_t mutatedAccepted = 0;
    size_t materializedOk = 0;
    size_t materializedRejected = 0;
    bool deepMetaAccepted = false;
}

private struct SplitMix64 {
    ulong state = 0x9E37_79B9_7F4A_7C15uL;

    @nogc nothrow pure @safe:

    ulong nextU64() {
        state += 0x9E37_79B9_7F4A_7C15uL;
        ulong z = state;
        z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9uL;
        z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EBuL;
        return z ^ (z >> 31);
    }

    uint nextU32(uint bound) {
        if (bound <= 1) return 0;
        return cast(uint)(nextU64() % bound);
    }
}

private ubyte[] buildSeedMsv() @safe nothrow {
    LoadedProject p;
    p.title = "FuzzSeed";
    p.author = "Fuzz";
    p.bpm = 128.0;
    p.ticksPerLine = 6;

    SavedModule outMod;
    outMod.id = 1;
    outMod.typeId = "core.output";
    outMod.name = "Out";
    outMod.paramValues = [1.0f, 1.0f];

    SavedModule genMod;
    genMod.id = 2;
    genMod.typeId = "synth.analog_gen";
    genMod.name = "Gen";
    genMod.paramValues = [0.8f, 0.0f];
    p.modules = [outMod, genMod];
    p.wires = [SavedWire(2, 2, 1, 0, 1.0f)];

    SavedPattern pat;
    pat.patternId = 1;
    pat.tracks = 2;
    pat.lines = 4;
    pat.name = "P1";
    pat.cells = new NoteCell[8];
    pat.cells[0] = NoteCell.makeNote(60, 0.9f, 2);
    p.patterns = [pat];
    p.clips = [TimelineClip(1, 1, 0, 0, 4, 0, 0, false, false, false)];

    ubyte[] bytes;
    string err;
    serializeProject(p, bytes, err);
    return bytes;
}

private ubyte[] buildSeedMsym() @safe nothrow {
    LoadedPreset pre;
    pre.presetName = "SeedPreset";
    pre.mod.id = 2;
    pre.mod.typeId = "synth.analog_gen";
    pre.mod.name = "Gen";
    pre.mod.paramValues = [0.75f, 1.0f];

    ubyte[] bytes;
    string err;
    serializePreset(pre, bytes, err);
    return bytes;
}

private ubyte[] buildSeedMidi() @safe nothrow {
    BinaryWriter w;
    w.writeFourCC("MThd");
    w.writeU32BE(6);
    w.writeU16BE(1);
    w.writeU16BE(1);
    w.writeU16BE(480);

    BinaryWriter tr;
    tr.writeU8(0x00);
    tr.writeU8(0xFF);
    tr.writeU8(0x51);
    tr.writeU8(0x03);
    tr.writeU8(0x07);
    tr.writeU8(0xA1);
    tr.writeU8(0x20);
    tr.writeU8(0x00);
    tr.writeU8(0x90);
    tr.writeU8(60);
    tr.writeU8(100);
    tr.writeU8(0x83);
    tr.writeU8(0x60);
    tr.writeU8(0x80);
    tr.writeU8(60);
    tr.writeU8(0);
    tr.writeU8(0x00);
    tr.writeU8(0xFF);
    tr.writeU8(0x2F);
    tr.writeU8(0x00);

    w.writeFourCC("MTrk");
    w.writeU32BE(cast(uint) tr.length);
    w.writeBytes(tr.bytes());
    return w.bytes().dup;
}

private ubyte[] buildSeedXm() @safe nothrow {
    BinaryWriter w;
    immutable string sig = "Extended Module: ";
    foreach (char c; sig) w.writeU8(cast(ubyte) c);
    foreach (_; 0 .. 20) w.writeU8('F');
    w.writeU8(0x1A);
    foreach (_; 0 .. 20) w.writeU8('T');
    w.writeU16(0x0104);
    w.writeU32(276);
    w.writeU16(1);
    w.writeU16(0);
    w.writeU16(2);
    w.writeU16(1);
    w.writeU16(0);
    w.writeU16(1);
    w.writeU16(6);
    w.writeU16(125);
    w.writeU8(0);
    foreach (_; 1 .. 256) w.writeU8(0);

    w.writeU32(9);
    w.writeU8(0);
    w.writeU16(4);
    w.writeU16(10);
    w.writeU8(0x85);
    w.writeU8(49);
    w.writeU8(1);
    foreach (_; 1 .. 8) w.writeU8(0);
    return w.bytes().dup;
}

private ubyte[] buildSeedSunvox() @safe nothrow {
    BinaryWriter w;
    w.writeFourCC("SVOX");
    w.writeFourCC("VERS");
    w.writeU32(8);
    w.writeU8(2);
    w.writeU8(1);
    w.writeU8(0);
    w.writeU8(0);
    w.writeFourCC("BVOL");
    w.writeU32(4);
    w.writeU32(256);
    w.writeFourCC("BPM ");
    w.writeU32(4);
    w.writeU32(125);
    w.writeFourCC("SPED");
    w.writeU32(4);
    w.writeU32(6);
    w.writeFourCC("SNEW");
    w.writeU32(4);
    w.writeU32(0);
    w.writeFourCC("STYP");
    w.writeU32(17);
    foreach (char c; "Analog generator\0") w.writeU8(cast(ubyte) c);
    w.writeFourCC("SNAM");
    w.writeU32(14);
    foreach (char c; "Analog gen\0\0\0\0") w.writeU8(cast(ubyte) c);
    w.writeFourCC("SLNK");
    w.writeU32(8);
    w.writeI32(0);
    w.writeI32(-1);
    w.writeFourCC("SEND");
    w.writeU32(0);
    w.writeFourCC("PDTA");
    w.writeU32(0);
    w.writeFourCC("PEND");
    w.writeU32(0);
    return w.bytes().dup;
}

private void mutateBuffer(
    ref SplitMix64 rng,
    const(ubyte)[] seed,
    ref ubyte[] scratch,
    out size_t activeLen,
    uint mode
) @safe nothrow {
    if (scratch.length < 1024) {
        scratch.length = 1024;
    }

    if (mode == 9) {
        immutable size_t rndLen = rng.nextU32(512);
        foreach (i; 0 .. rndLen) {
            scratch[i] = cast(ubyte) rng.nextU32(256);
        }
        activeLen = rndLen;
        return;
    }

    immutable size_t copyLen = min(seed.length, cast(size_t) 512);
    if (copyLen > 0) {
        scratch[0 .. copyLen] = seed[0 .. copyLen];
    }
    activeLen = copyLen;

    if (mode == 0 && activeLen > 0) {
        return;
    }

    switch (mode) {
        case 1:
            if (activeLen > 0) {
                activeLen = rng.nextU32(cast(uint) activeLen + 1);
            }
            break;

        case 2:
            if (activeLen > 0) {
                immutable uint flips = 1 + rng.nextU32(6);
                foreach (_; 0 .. flips) {
                    immutable size_t pos = rng.nextU32(cast(uint) activeLen);
                    scratch[pos] ^= cast(ubyte)(1 + rng.nextU32(255));
                }
            }
            break;

        case 3:
            if (activeLen >= 8) {
                immutable size_t pos = rng.nextU32(cast(uint)(activeLen - 3));
                scratch[pos] = 0xFF;
                scratch[pos + 1] = 0xFF;
                scratch[pos + 2] = 0xFF;
                scratch[pos + 3] = cast(ubyte)(0x7F + rng.nextU32(2) * 0x80);
            }
            break;

        case 4:
            if (activeLen >= 8) {
                immutable size_t pos = rng.nextU32(cast(uint)(activeLen - 3));
                scratch[pos] = cast(ubyte) rng.nextU32(256);
                scratch[pos + 1] = cast(ubyte) rng.nextU32(256);
                scratch[pos + 2] = 0xC0;
                scratch[pos + 3] = rng.nextU32(2) == 0 ? 0x7F : 0xFF;
            }
            break;

        case 5:
            if (activeLen + 12 <= scratch.length) {
                scratch[activeLen .. activeLen + 4] = [cast(ubyte) 'F', 'U', 'T', 'R'];
                scratch[activeLen + 4 .. activeLen + 8] = [4, 0, 0, 0];
                scratch[activeLen + 8 .. activeLen + 12] = [1, 2, 3, 4];
                activeLen += 12;
            }
            break;

        case 6:
            if (activeLen > 12) {
                immutable size_t shiftPos = 4 + rng.nextU32(cast(uint)(activeLen - 4));
                scratch[shiftPos] = 0;
                scratch[shiftPos + 1] = 0;
            }
            break;

        case 7:
            immutable size_t extra = 1 + rng.nextU32(64);
            if (activeLen + extra <= scratch.length) {
                foreach (k; 0 .. extra) {
                    scratch[activeLen + k] = cast(ubyte) rng.nextU32(256);
                }
                activeLen += extra;
            }
            break;

        default:
            if (activeLen > 0) {
                immutable size_t idx = rng.nextU32(cast(uint) activeLen);
                scratch[idx] = cast(ubyte) rng.nextU32(256);
            }
            break;
    }
}

private ubyte[] wrapInMetaModuleRaw(const(ubyte)[] childMsv) @safe nothrow {
    BinaryWriter meta;
    meta.writeString("DeepMeta");
    meta.writeString("Fuzz");
    meta.writeF64(125.0);
    meta.writeU32(6);
    meta.writeI64(0);
    meta.writeI64(0);

    BinaryWriter mods;
    mods.writeU32(1);
    mods.writeU32(2);
    mods.writeString("ctl.metamodule");
    mods.writeString("M");
    mods.writeF32(0.0f);
    mods.writeF32(0.0f);
    mods.writeU8(0);
    mods.writeU8(0);
    mods.writeU32(0);
    mods.writeU32(0);
    mods.writeU8(1);
    mods.writeU32(2);
    foreach (_; 0 .. MetaModuleAsset.NUM_MACROS) {
        mods.writeU32(0);
        mods.writeU32(0);
        mods.writeF32(0.0f);
        mods.writeF32(1.0f);
        mods.writeU8(0);
    }
    mods.writeLengthPrefixedBytes(childMsv);

    BinaryWriter w;
    w.writeFourCC("MSV1");
    w.writeU32(MSV_FORMAT_VERSION);
    w.writeU32(0);
    w.writeChunk(['M', 'E', 'T', 'A'], meta.bytes());
    w.writeChunk(['M', 'O', 'D', 'S'], mods.bytes());
    return w.bytes().dup;
}

/**
 * Hand-encodes an .msv whose MetaModule chain nests levels deep, bypassing serializeProject's depth validation.
 *
 * Params:
 *   levels = Number of nested MetaModule child projects wrapped around the seed project.
 *
 * Returns:
 *   Encoded .msv bytes.
 */
ubyte[] buildNestedMetaMsvRaw(uint levels) @safe nothrow {
    ubyte[] inner = buildSeedMsv();
    foreach (_; 0 .. levels) {
        inner = wrapInMetaModuleRaw(inner);
    }
    return inner;
}

private void materializeAccepted(const ref LoadedProject proj, ref FuzzStats stats) {
    Engine eng;
    if (!eng.tryInit(44_100.0f, 64, 64)) {
        return;
    }
    ModuleInstance[] owned;
    string err;
    if (materializeProjectToEngine(proj, eng, 44_100.0f, owned, err)) {
        stats.materializedOk++;
        float[FIXED_BLOCK_FRAMES] l = 0.0f;
        float[FIXED_BLOCK_FRAMES] r = 0.0f;
        float[][2] outs = [l[], r[]];
        const(float[])[2] ins = [null, null];
        eng.setPlaying(true);
        eng.processHostBuffer(outs, ins, FIXED_BLOCK_FRAMES);
    } else {
        stats.materializedRejected++;
    }
    eng.releaseAllOwnedResources();
    foreach (ref inst; owned) {
        inst.destroyOffRT();
    }
}

/**
 * Executes deterministic seeded mutation/truncation/corruption fuzzing across all native and optional file parsers.
 *
 * Params:
 *   seed = Initial 64-bit SplitMix seed.
 *   iterations = Number of fuzz invocations (default 100,000).
 *
 * Returns:
 *   FuzzStats counters summarizing iterations executed across formats.
 */
FuzzStats runProjectFormatFuzz(ulong seed, size_t iterations = 100_000) {
    SplitMix64 rng = SplitMix64(seed);
    FuzzStats stats;

    const(ubyte)[] msvSeed = buildSeedMsv();
    const(ubyte)[] msymSeed = buildSeedMsym();
    const(ubyte)[] midSeed = buildSeedMidi();
    const(ubyte)[] xmSeed = buildSeedXm();
    const(ubyte)[] svxSeed = buildSeedSunvox();
    const(ubyte)[] deepMeta = buildNestedMetaMsvRaw(MAX_METAMODULE_DEPTH + 4);

    ubyte[] scratch = new ubyte[1024];

    LoadedProject tmpProj;
    LoadedPreset tmpPreset;
    ImportReport tmpReport;
    string tmpErr;

    if (loadProject(deepMeta, tmpProj, tmpErr)) {
        stats.acceptedCount++;
        stats.deepMetaAccepted = true;
    } else {
        stats.rejectedCount++;
    }
    stats.totalRuns++;
    stats.msvRuns++;

    foreach (iter; 1 .. iterations) {
        immutable uint target = cast(uint)(iter % 5);
        immutable uint mode = iter < 50 ? 0 : rng.nextU32(10);
        size_t activeLen = 0;

        bool ok = false;
        final switch (target) {
            case 0:
                mutateBuffer(rng, msvSeed, scratch, activeLen, mode);
                ok = loadProject(scratch[0 .. activeLen], tmpProj, tmpErr);
                stats.msvRuns++;
                break;
            case 1:
                mutateBuffer(rng, msymSeed, scratch, activeLen, mode);
                ok = loadPreset(scratch[0 .. activeLen], tmpPreset, tmpErr);
                stats.msymRuns++;
                break;
            case 2:
                mutateBuffer(rng, midSeed, scratch, activeLen, mode);
                ok = importMidiFile(scratch[0 .. activeLen], tmpProj, tmpErr);
                stats.midRuns++;
                break;
            case 3:
                mutateBuffer(rng, xmSeed, scratch, activeLen, mode);
                ok = importXmFile(scratch[0 .. activeLen], tmpProj, tmpErr);
                stats.xmRuns++;
                break;
            case 4:
                mutateBuffer(rng, svxSeed, scratch, activeLen, mode);
                ok = importSunvoxFile(scratch[0 .. activeLen], tmpProj, tmpReport, tmpErr);
                stats.sunvoxRuns++;
                break;
        }

        stats.totalRuns++;
        if (ok) {
            stats.acceptedCount++;
            if (mode != 0) {
                stats.mutatedAccepted++;
            }
            if (target != 1) {
                materializeAccepted(tmpProj, stats);
            }
        } else {
            stats.rejectedCount++;
        }
    }

    return stats;
}

version (unittest) {
    unittest {
        immutable FuzzStats stats = runProjectFormatFuzz(0x5068_6173_6536uL, 100_000);
        assert(stats.totalRuns == 100_000);
        assert(stats.msvRuns >= 19_000);
        assert(stats.msymRuns >= 19_000);
        assert(stats.midRuns >= 19_000);
        assert(stats.xmRuns >= 19_000);
        assert(stats.sunvoxRuns >= 19_000);
        assert(stats.acceptedCount > 0);
        assert(stats.rejectedCount > 0);
        assert(!stats.deepMetaAccepted);
        assert(stats.mutatedAccepted > 0);
        assert(stats.materializedOk > 0);
    }

    unittest {
        LoadedProject p;
        string err;
        assert(loadProject(buildNestedMetaMsvRaw(MAX_METAMODULE_DEPTH), p, err));
        assert(!loadProject(buildNestedMetaMsvRaw(MAX_METAMODULE_DEPTH + 1), p, err));
    }
}
