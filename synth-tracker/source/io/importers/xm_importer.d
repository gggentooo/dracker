/**
 * File:         source/io/importers/xm_importer.d
 * Module:       io.importers.xm_importer
 * Phase:        Phase 6.5 (Optional) — FastTracker II (.xm) Importer
 *
 * Purpose:
 *   Imports FastTracker II .xm modules safely, decoding packed pattern commands, instruments, and delta-PCM samples into SynthTracker Sampler/AnalogGen modules and patterns.
 *
 * Real-Time & Safety Contract:
 *   Off-RT @safe binary parsing via io.binary_stream with strict sample, pattern, and instrument bounds caps.
 *
 * Dependencies:
 *   Internal: io.binary_stream, io.project_format, sequencer.note, sequencer.timeline
 *   External: std.bitmanip (nativeToLittleEndian)
 *
 * Planned API (Types, Functions & Hooks):
 *   - bool importXmFile(const(ubyte)[] bytes, out LoadedProject proj, out string err)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.importers.xm_importer;

import std.bitmanip : nativeToLittleEndian;

import io.binary_stream : BinaryReader;
import io.project_format : LoadedProject, MAX_PATTERNS, SavedModule, SavedPattern, SavedWire;
import sequencer.note : EffectCode, NoteCell, NoteCmd;
import sequencer.timeline : TimelineClip;

private enum size_t MAX_XM_CHANNELS = 32;
private enum size_t MAX_XM_PATTERNS = 256;
static assert(MAX_XM_PATTERNS <= MAX_PATTERNS, "XM pattern cap must fit the .msv/Engine pattern cap");
private enum size_t MAX_XM_INSTRUMENTS = 128;
private enum size_t MAX_XM_SAMPLES = 32;
private enum uint MAX_XM_SAMPLE_BYTES = 16u * 1024u * 1024u;

private ubyte[] buildSingleSlotSamplerBlob(const(float)[] pcm, uint loopStart, uint loopEnd, ubyte rootNote) @safe nothrow {
    ubyte[] buf;
    void appendVal(T)(T v) @safe nothrow {
        buf ~= nativeToLittleEndian(v)[];
    }

    appendVal!uint(0x534D_5031u);
    appendVal!uint(1u);
    appendVal!uint(0u);
    appendVal!float(22_050.0f);
    buf ~= rootNote;
    buf ~= cast(ubyte) 0;
    buf ~= cast(ubyte) 127;
    buf ~= cast(ubyte) 0;
    appendVal!ulong(cast(ulong) loopStart);
    appendVal!ulong(cast(ulong) loopEnd);
    appendVal!uint(0u);
    appendVal!int(-1);
    appendVal!uint(0u);
    appendVal!int(-1);
    appendVal!uint(0u);
    appendVal!int(-1);
    appendVal!ulong(cast(ulong) pcm.length);
    foreach (s; pcm) {
        appendVal!float(s);
        appendVal!float(s);
    }
    return buf;
}

private string trimAscii(const(ubyte)[] raw) @safe nothrow {
    size_t len = raw.length;
    while (len > 0 && (raw[len - 1] == 0 || raw[len - 1] == ' ')) {
        len--;
    }
    if (len == 0) {
        return "";
    }
    return cast(string)(raw[0 .. len].idup);
}

private void mapXmEffect(ubyte xmFx, ubyte xmParam, out ubyte fx, out ubyte fxVal) @safe pure nothrow {
    fx = EffectCode.none;
    fxVal = xmParam;
    switch (xmFx) {
        case 0x00:
            if (xmParam != 0) fx = EffectCode.arpeggio;
            break;
        case 0x01:
            fx = EffectCode.slideUp;
            break;
        case 0x02:
            fx = EffectCode.slideDown;
            break;
        case 0x03:
            fx = EffectCode.portamento;
            break;
        case 0x04:
            fx = EffectCode.vibrato;
            break;
        case 0x09:
            fx = EffectCode.sampleOffset;
            break;
        case 0x0A:
            fx = EffectCode.velocitySlide;
            break;
        case 0x0B:
            fx = EffectCode.jumpLine;
            break;
        case 0x0F:
            fx = xmParam >= 32 ? EffectCode.setBpm : EffectCode.setSpeed;
            break;
        case 0x0E: {
            immutable ubyte sub = cast(ubyte)(xmParam >> 4);
            immutable ubyte sv = cast(ubyte)(xmParam & 0x0Fu);
            fxVal = sv;
            if (sub == 0x09) {
                fx = EffectCode.retrigger;
            } else if (sub == 0x0C) {
                fx = EffectCode.noteCut;
            } else if (sub == 0x0D) {
                fx = EffectCode.noteDelay;
            }
            break;
        }
        default:
            fxVal = 0;
            break;
    }
}

/**
 * Parses a FastTracker II Extended Module (.xm) byte buffer into a LoadedProject.
 *
 * Translates XM patterns, order table clips, effects, and delta-encoded PCM instrument samples
 * into SynthTracker patterns, timeline clips, and Sampler/AnalogGen nodes safely off-RT.
 *
 * Params:
 *   bytes = Complete .xm file byte payload.
 *   proj = Populated LoadedProject structure on success.
 *   err = Diagnostic error string populated if corrupt or unsupported.
 *
 * Returns:
 *   True on valid XM module load; false on malformed headers or truncation.
 */
bool importXmFile(const(ubyte)[] bytes, out LoadedProject proj, out string err) @safe nothrow {
    proj = LoadedProject.init;
    err = null;

    BinaryReader r = BinaryReader(bytes);
    const(ubyte)[] magic;
    const(ubyte)[] modName;
    ubyte id1A = 0;
    const(ubyte)[] trackerName;
    ushort xmVersion = 0;
    uint headerSize = 0;

    if (!r.readBytes(17, magic)
            || magic != cast(const(ubyte)[]) "Extended Module: "
            || !r.readBytes(20, modName)
            || !r.readU8(id1A)
            || !r.readBytes(20, trackerName)
            || !r.readU16(xmVersion)
            || !r.readU32(headerSize)) {
        err = "Invalid or truncated XM header";
        return false;
    }
    if (headerSize < 20 || headerSize > 4096) {
        err = "Invalid XM extended header size";
        return false;
    }
    immutable size_t bodyOffset = 60 + cast(size_t) headerSize;
    if (bodyOffset > bytes.length) {
        err = "XM header extends past EOF";
        return false;
    }

    ushort songLen = 0;
    ushort restartPos = 0;
    ushort numChannels = 0;
    ushort numPatterns = 0;
    ushort numInstruments = 0;
    ushort xmFlags = 0;
    ushort defaultTpl = 6;
    ushort defaultBpm = 125;

    if (!r.readU16(songLen)
            || !r.readU16(restartPos)
            || !r.readU16(numChannels)
            || !r.readU16(numPatterns)
            || !r.readU16(numInstruments)
            || !r.readU16(xmFlags)
            || !r.readU16(defaultTpl)
            || !r.readU16(defaultBpm)) {
        err = "Truncated XM song metrics header";
        return false;
    }
    if (numChannels == 0 || numChannels > MAX_XM_CHANNELS
            || numPatterns > MAX_XM_PATTERNS
            || numInstruments > MAX_XM_INSTRUMENTS
            || !r.canRead(cast(size_t) numPatterns * 9)) {
        err = "XM channel, pattern, or instrument count out of range";
        return false;
    }

    ubyte[256] orders = 0;
    immutable size_t hdrOrderBytes = headerSize - 20;
    immutable size_t orderToRead = hdrOrderBytes < 256 ? hdrOrderBytes : 256;
    const(ubyte)[] orderSlice;
    if (!r.readBytes(orderToRead, orderSlice)) {
        err = "Truncated XM pattern order table";
        return false;
    }
    foreach (i, b; orderSlice) {
        orders[i] = b;
    }
    if (!r.seek(bodyOffset)) {
        err = "Failed seeking to XM patterns section";
        return false;
    }

    immutable string titleStr = trimAscii(modName);
    proj.title = titleStr.length > 0 ? titleStr : "XM Import";
    proj.author = "XM Import";
    proj.bpm = defaultBpm >= 20 && defaultBpm <= 999 ? cast(double) defaultBpm : 125.0;
    proj.ticksPerLine = defaultTpl >= 1 && defaultTpl <= 255 ? cast(uint) defaultTpl : 6u;

    SavedPattern[] parsedPatterns = new SavedPattern[numPatterns];
    foreach (pi; 0 .. numPatterns) {
        uint patHdrLen = 0;
        ubyte packType = 0;
        ushort rows = 0;
        ushort packedSize = 0;
        if (!r.readU32(patHdrLen) || patHdrLen < 9
                || !r.readU8(packType)
                || !r.readU16(rows)
                || !r.readU16(packedSize)) {
            err = "Truncated XM pattern header";
            return false;
        }
        if (patHdrLen > 9 && !r.skip(patHdrLen - 9)) {
            err = "Truncated XM extended pattern header";
            return false;
        }
        if (rows == 0 || rows > 1024) {
            err = "Invalid XM pattern row count";
            return false;
        }

        const(ubyte)[] patData;
        if (packedSize > 0 && !r.readBytes(packedSize, patData)) {
            err = "Truncated XM packed pattern payload";
            return false;
        }

        parsedPatterns[pi].patternId = cast(uint)(pi + 1);
        parsedPatterns[pi].tracks = numChannels;
        parsedPatterns[pi].lines = rows;
        parsedPatterns[pi].cells = new NoteCell[cast(size_t) rows * cast(size_t) numChannels];

        BinaryReader pr = BinaryReader(patData);
        rowLoop: foreach (row; 0 .. rows) {
            foreach (ch; 0 .. numChannels) {
                if (pr.atEnd()) {
                    break rowLoop;
                }
                ubyte b = 0;
                pr.readU8(b);

                ubyte xmNote = 0;
                ubyte xmInst = 0;
                ubyte xmVol = 0;
                ubyte xmFx = 0;
                ubyte xmParam = 0;

                if ((b & 0x80u) != 0) {
                    if ((b & 0x01u) != 0 && !pr.readU8(xmNote)) break rowLoop;
                    if ((b & 0x02u) != 0 && !pr.readU8(xmInst)) break rowLoop;
                    if ((b & 0x04u) != 0 && !pr.readU8(xmVol)) break rowLoop;
                    if ((b & 0x08u) != 0 && !pr.readU8(xmFx)) break rowLoop;
                    if ((b & 0x10u) != 0 && !pr.readU8(xmParam)) break rowLoop;
                } else {
                    xmNote = b;
                    if (!pr.readU8(xmInst) || !pr.readU8(xmVol)
                            || !pr.readU8(xmFx) || !pr.readU8(xmParam)) {
                        break rowLoop;
                    }
                }

                NoteCell cell;
                if (xmInst > 0 && xmInst <= numInstruments) {
                    cell.moduleId = cast(ushort)(xmInst + 1);
                }
                if (xmNote >= 1 && xmNote <= 96) {
                    cell.note = NoteCell.encodeMidiNote(cast(int) xmNote + 11);
                } else if (xmNote == 97) {
                    cell.note = NoteCmd.noteOff;
                }
                if (xmVol >= 0x10 && xmVol <= 0x50) {
                    cell.velocity = NoteCell.encodeVelocity(cast(float)(xmVol - 0x10) / 64.0f);
                }
                ubyte fx = 0;
                ubyte fxVal = 0;
                mapXmEffect(xmFx, xmParam, fx, fxVal);
                cell.effect = fx;
                cell.effectVal = fxVal;
                parsedPatterns[pi].cells[cast(size_t) row * numChannels + ch] = cell;
            }
        }
    }

    SavedModule masterMod;
    masterMod.id = 1;
    masterMod.typeId = "core.output";
    masterMod.name = "Master";
    masterMod.paramValues = [1.0f, 1.0f];
    proj.modules ~= masterMod;

    struct XmSampleMeta {
        uint byteLen = 0;
        uint loopStart = 0;
        uint loopLen = 0;
        bool is16Bit = false;
        bool hasLoop = false;
        byte relNote = 0;
    }

    foreach (instIdx; 0 .. numInstruments) {
        uint instSize = 0;
        const(ubyte)[] instNameRaw;
        ubyte instType = 0;
        ushort numSamples = 0;
        if (!r.readU32(instSize) || instSize < 29 || instSize > 65_536
                || !r.readBytes(22, instNameRaw)
                || !r.readU8(instType)
                || !r.readU16(numSamples)) {
            err = "Truncated XM instrument header";
            return false;
        }
        if (numSamples > MAX_XM_SAMPLES || !r.canRead(cast(size_t) numSamples * 40)) {
            err = "XM instrument sample count exceeds limit";
            return false;
        }
        immutable size_t instSkip = cast(size_t) instSize - 29;
        if (!r.skip(instSkip)) {
            err = "Truncated XM instrument extended block";
            return false;
        }

        auto metas = new XmSampleMeta[numSamples];
        foreach (si; 0 .. numSamples) {
            uint sLen = 0;
            uint lStart = 0;
            uint lLen = 0;
            ubyte vol = 64;
            byte fine = 0;
            ubyte flags = 0;
            ubyte pan = 128;
            byte relN = 0;
            ubyte res = 0;
            const(ubyte)[] sNameRaw;
            if (!r.readU32(sLen)
                    || !r.readU32(lStart)
                    || !r.readU32(lLen)
                    || !r.readU8(vol)
                    || !r.readI8(fine)
                    || !r.readU8(flags)
                    || !r.readU8(pan)
                    || !r.readI8(relN)
                    || !r.readU8(res)
                    || !r.readBytes(22, sNameRaw)) {
                err = "Truncated XM sample header";
                return false;
            }
            if (sLen > MAX_XM_SAMPLE_BYTES) {
                err = "XM sample payload exceeds safety limit";
                return false;
            }
            metas[si] = XmSampleMeta(
                sLen,
                lStart,
                lLen,
                (flags & 0x10u) != 0,
                (flags & 0x03u) != 0,
                relN
            );
        }

        float[] firstSamplePcm;
        uint firstLoopStart = 0;
        uint firstLoopEnd = 0;
        ubyte firstRoot = 60;

        foreach (si; 0 .. numSamples) {
            const(ubyte)[] rawPcm;
            if (metas[si].byteLen > 0 && !r.readBytes(metas[si].byteLen, rawPcm)) {
                err = "Truncated XM sample PCM payload";
                return false;
            }
            if (si == 0 && metas[si].byteLen > 0) {
                if (metas[si].is16Bit) {
                    immutable size_t frames = metas[si].byteLen / 2;
                    firstSamplePcm = new float[frames];
                    int acc16 = 0;
                    BinaryReader sr = BinaryReader(rawPcm);
                    foreach (fi; 0 .. frames) {
                        short d = 0;
                        if (!sr.readI16(d)) break;
                        acc16 += d;
                        firstSamplePcm[fi] = cast(float) cast(short) acc16 / 32_768.0f;
                    }
                    firstLoopStart = metas[si].loopStart / 2;
                    firstLoopEnd = metas[si].hasLoop ? ((metas[si].loopStart + metas[si].loopLen) / 2) : 0;
                } else {
                    immutable size_t frames = metas[si].byteLen;
                    firstSamplePcm = new float[frames];
                    int acc8 = 0;
                    foreach (fi; 0 .. frames) {
                        acc8 += cast(byte) rawPcm[fi];
                        firstSamplePcm[fi] = cast(float) cast(byte) acc8 / 128.0f;
                    }
                    firstLoopStart = metas[si].loopStart;
                    firstLoopEnd = metas[si].hasLoop ? (metas[si].loopStart + metas[si].loopLen) : 0;
                }
                int rn = 60 - cast(int) metas[si].relNote;
                if (rn < 0) rn = 0;
                if (rn > 127) rn = 127;
                firstRoot = cast(ubyte) rn;
                if (firstLoopEnd > firstSamplePcm.length) {
                    firstLoopEnd = cast(uint) firstSamplePcm.length;
                }
            }
        }

        SavedModule sm;
        sm.id = cast(uint)(instIdx + 2);
        sm.name = trimAscii(instNameRaw);
        sm.posX = 120.0f + cast(float)(instIdx % 4) * 140.0f;
        sm.posY = 80.0f + cast(float)(instIdx / 4) * 90.0f;
        if (firstSamplePcm.length > 0) {
            sm.typeId = "synth.sampler";
            sm.paramValues = [
                0.8f,
                0.0f,
                0.0f,
                0.0f,
                firstLoopEnd > firstLoopStart ? 1.0f : 0.0f,
                2.0f
            ];
            sm.extraBlob = buildSingleSlotSamplerBlob(firstSamplePcm, firstLoopStart, firstLoopEnd, firstRoot);
        } else {
            sm.typeId = "synth.analog_gen";
        }
        proj.modules ~= sm;
        proj.wires ~= SavedWire(sm.id, 2, 1, 0, 0.7f);
    }

    proj.patterns = parsedPatterns;
    immutable size_t clampedOrderLen = songLen < 256 ? songLen : 256;
    long lineCursor = 0;
    uint clipSeq = 1;
    foreach (oi; 0 .. clampedOrderLen) {
        immutable uint patIdx = orders[oi];
        if (patIdx < parsedPatterns.length) {
            immutable uint patLen = parsedPatterns[patIdx].lines;
            proj.clips ~= TimelineClip(
                clipSeq++,
                parsedPatterns[patIdx].patternId,
                0,
                lineCursor,
                patLen,
                0,
                0,
                false,
                false,
                false
            );
            lineCursor += patLen;
        }
    }

    return true;
}
