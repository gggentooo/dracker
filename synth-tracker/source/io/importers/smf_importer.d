/**
 * File:         source/io/importers/smf_importer.d
 * Module:       io.importers.smf_importer
 * Phase:        Phase 6.5 (Optional) — Standard MIDI File (.mid) Importer
 *
 * Purpose:
 *   Parses SMF Type 0 and Type 1 binary streams cleanly into SynthTracker LoadedProjects with mapped melodic/drum synths, tempo automation, patterns, and timeline clips.
 *
 * Real-Time & Safety Contract:
 *   Off-RT @safe binary parsing via io.binary_stream with strict track, event, and pattern caps.
 *
 * Dependencies:
 *   Internal: io.binary_stream, io.project_format, sequencer.note, sequencer.timeline
 *   External: std.algorithm (sort)
 *
 * Planned API (Types, Functions & Hooks):
 *   - bool importMidiFile(const(ubyte)[] bytes, out LoadedProject proj, out string err)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.importers.smf_importer;

import std.algorithm : sort;

import io.binary_stream : BinaryReader;
import io.project_format : LoadedProject, MAX_PATTERNS, SavedModule, SavedPattern, SavedWire;
import sequencer.note : EffectCode, NoteCell, NoteCmd;
import sequencer.timeline : TimelineClip;

private enum size_t MAX_MIDI_TRACKS = 64;
private enum size_t MAX_MIDI_EVENTS = 131_072;
private enum uint LINES_PER_PATTERN = 64;

private struct ParsedMidiEvent {
    ulong tick = 0;
    ubyte kind = 0;
    ubyte channel = 0;
    ubyte note = 60;
    ubyte velocity = 100;
    double bpm = 120.0;
}

/**
 * Parses a Standard MIDI File (SMF Type 0 or 1) binary byte slice into a LoadedProject.
 *
 * Assigns channel 9 to synth.drumsynth and active melodic channels to synth.analog_gen wired
 * to core.output, quantizes timestamps onto 16th-note tracker rows, and encodes off-grid offsets
 * cleanly via sub-line delay commands (0x40..0x5F).
 *
 * Params:
 *   bytes = Complete .mid byte buffer.
 *   proj = Destination LoadedProject populated on success.
 *   err = Human-readable diagnostic error message populated on malformed input.
 *
 * Returns:
 *   True if a valid SMF header and tracks parsed; false on corrupt header or truncation.
 */
bool importMidiFile(const(ubyte)[] bytes, out LoadedProject proj, out string err) @safe nothrow {
    proj = LoadedProject.init;
    err = null;

    BinaryReader r = BinaryReader(bytes);
    char[4] hdrTag;
    uint hdrLen = 0;
    ushort formatType = 0;
    ushort numTracks = 0;
    ushort rawDiv = 0;
    if (!r.readFourCC(hdrTag) || hdrTag != ['M', 'T', 'h', 'd']
            || !r.readU32BE(hdrLen) || hdrLen < 6
            || !r.readU16BE(formatType)
            || !r.readU16BE(numTracks)
            || !r.readU16BE(rawDiv)) {
        err = "Invalid or truncated SMF MThd header";
        return false;
    }
    if (formatType > 2 || numTracks == 0 || numTracks > MAX_MIDI_TRACKS) {
        err = "Unsupported SMF format or track count";
        return false;
    }
    if (hdrLen > 6 && !r.skip(hdrLen - 6)) {
        err = "Truncated SMF extended MThd header";
        return false;
    }

    uint tpqn = 480;
    if ((rawDiv & 0x8000u) == 0) {
        tpqn = rawDiv > 0 ? rawDiv : 480;
    }

    ParsedMidiEvent[] events;
    bool[16] usedChannels = false;
    string songTitle = "MIDI Import";

    foreach (trkIdx; 0 .. numTracks) {
        char[4] trkTag;
        uint trkLen = 0;
        if (!r.readFourCC(trkTag) || trkTag != ['M', 'T', 'r', 'k'] || !r.readU32BE(trkLen)) {
            err = "Invalid or truncated SMF MTrk chunk";
            return false;
        }
        const(ubyte)[] trkSlice;
        if (!r.readBytes(trkLen, trkSlice)) {
            err = "SMF track payload truncated";
            return false;
        }

        BinaryReader tr = BinaryReader(trkSlice);
        ulong absTick = 0;
        ubyte runningStatus = 0;

        while (!tr.atEnd()) {
            uint delta = 0;
            if (!tr.readMidiVlq(delta)) {
                err = "Malformed SMF event delta VLQ";
                return false;
            }
            absTick += delta;

            ubyte statusByte = 0;
            if (!tr.readU8(statusByte)) {
                err = "Truncated SMF event status";
                return false;
            }

            ubyte data1 = 0;
            bool usedRunning = false;
            if ((statusByte & 0x80u) == 0) {
                if (runningStatus == 0) {
                    err = "Invalid SMF running status";
                    return false;
                }
                data1 = statusByte;
                statusByte = runningStatus;
                usedRunning = true;
            }

            if (statusByte == 0xFF) {
                runningStatus = 0;
                ubyte metaType = 0;
                uint metaLen = 0;
                if (!tr.readU8(metaType) || !tr.readMidiVlq(metaLen) || !tr.canRead(metaLen)) {
                    err = "Malformed SMF meta event";
                    return false;
                }
                const(ubyte)[] metaBytes;
                tr.readBytes(metaLen, metaBytes);

                if (metaType == 0x51 && metaLen == 3) {
                    immutable uint mpqn = (cast(uint) metaBytes[0] << 16)
                        | (cast(uint) metaBytes[1] << 8)
                        | cast(uint) metaBytes[2];
                    if (mpqn > 0 && events.length < MAX_MIDI_EVENTS) {
                        double calcBpm = 60_000_000.0 / cast(double) mpqn;
                        if (calcBpm < 20.0) calcBpm = 20.0;
                        if (calcBpm > 999.0) calcBpm = 999.0;
                        ParsedMidiEvent tev;
                        tev.tick = absTick;
                        tev.kind = 3;
                        tev.bpm = calcBpm;
                        events ~= tev;
                    }
                } else if (metaType == 0x03 && trkIdx == 0 && metaLen > 0 && metaLen <= 256) {
                    songTitle = cast(string)(metaBytes.idup);
                } else if (metaType == 0x2F) {
                    break;
                }
                continue;
            }

            if (statusByte == 0xF0 || statusByte == 0xF7) {
                runningStatus = 0;
                uint sysLen = 0;
                if (!tr.readMidiVlq(sysLen) || !tr.skip(sysLen)) {
                    err = "Truncated SMF SysEx event";
                    return false;
                }
                continue;
            }

            runningStatus = statusByte;
            immutable ubyte msgType = cast(ubyte)(statusByte & 0xF0u);
            immutable ubyte ch = cast(ubyte)(statusByte & 0x0Fu);

            if (!usedRunning && !tr.readU8(data1)) {
                err = "Truncated SMF channel data byte 1";
                return false;
            }

            ubyte data2 = 0;
            if (msgType != 0xC0 && msgType != 0xD0) {
                if (!tr.readU8(data2)) {
                    err = "Truncated SMF channel data byte 2";
                    return false;
                }
            }

            if (events.length >= MAX_MIDI_EVENTS) {
                continue;
            }
            if (msgType == 0x90) {
                usedChannels[ch] = true;
                ParsedMidiEvent ev;
                ev.tick = absTick;
                ev.channel = ch;
                ev.note = cast(ubyte)(data1 & 0x7Fu);
                ev.velocity = cast(ubyte)(data2 & 0x7Fu);
                ev.kind = data2 == 0 ? cast(ubyte) 2 : cast(ubyte) 1;
                events ~= ev;
            } else if (msgType == 0x80) {
                usedChannels[ch] = true;
                ParsedMidiEvent ev;
                ev.tick = absTick;
                ev.channel = ch;
                ev.note = cast(ubyte)(data1 & 0x7Fu);
                ev.kind = 2;
                events ~= ev;
            }
        }
    }

    sort!((a, b) => a.tick < b.tick)(events);

    proj.title = songTitle;
    proj.author = "SMF Import";
    proj.bpm = 120.0;
    proj.ticksPerLine = 6;

    SavedModule outMod;
    outMod.id = 1;
    outMod.typeId = "core.output";
    outMod.name = "Master";
    outMod.paramValues = [1.0f, 1.0f];
    proj.modules ~= outMod;

    ushort[16] chModuleId = 0;
    uint nextId = 2;
    foreach (ch; 0 .. 16) {
        if (!usedChannels[ch]) {
            continue;
        }
        chModuleId[ch] = cast(ushort) nextId;
        SavedModule sm;
        sm.id = nextId++;
        sm.posX = 120.0f + cast(float)(ch % 4) * 140.0f;
        sm.posY = 80.0f + cast(float)(ch / 4) * 90.0f;
        if (ch == 9) {
            sm.typeId = "synth.drumsynth";
            sm.name = "SMF Drums";
            proj.wires ~= SavedWire(sm.id, 1, 1, 0, 0.8f);
        } else {
            sm.typeId = "synth.analog_gen";
            sm.name = "SMF Synth";
            proj.wires ~= SavedWire(sm.id, 2, 1, 0, 0.7f);
        }
        proj.modules ~= sm;
    }

    uint activeTracks = 0;
    ubyte[16] chTrackIdx = 0;
    foreach (ch; 0 .. 16) {
        if (usedChannels[ch]) {
            chTrackIdx[ch] = cast(ubyte) activeTracks++;
        }
    }
    if (activeTracks == 0) {
        activeTracks = 1;
    }

    bool firstTempoApplied = false;
    ulong maxLine = 0;
    foreach (ref ev; events) {
        if (ev.kind == 3 && !firstTempoApplied && ev.tick == 0) {
            proj.bpm = ev.bpm;
            firstTempoApplied = true;
        }
        immutable ulong lineIdx = (ev.tick * 4uL) / tpqn;
        if (lineIdx > maxLine) maxLine = lineIdx;
    }

    size_t numPatterns = cast(size_t)((maxLine / LINES_PER_PATTERN) + 1);
    if (numPatterns > MAX_PATTERNS) {
        numPatterns = MAX_PATTERNS;
    }
    if (numPatterns == 0) {
        numPatterns = 1;
    }

    proj.patterns = new SavedPattern[numPatterns];
    proj.clips = new TimelineClip[numPatterns];
    foreach (pi; 0 .. numPatterns) {
        proj.patterns[pi].patternId = cast(uint)(pi + 1);
        proj.patterns[pi].tracks = activeTracks;
        proj.patterns[pi].lines = LINES_PER_PATTERN;
        proj.patterns[pi].cells = new NoteCell[cast(size_t) activeTracks * LINES_PER_PATTERN];
        proj.clips[pi] = TimelineClip(
            cast(uint)(pi + 1),
            cast(uint)(pi + 1),
            0,
            cast(long)(pi * LINES_PER_PATTERN),
            LINES_PER_PATTERN,
            0,
            0,
            false,
            false,
            false
        );
    }

    foreach (ref ev; events) {
        immutable ulong lineGlobal = (ev.tick * 4uL) / tpqn;
        immutable size_t patIdx = cast(size_t)(lineGlobal / LINES_PER_PATTERN);
        if (patIdx >= proj.patterns.length) {
            continue;
        }
        immutable uint localLine = cast(uint)(lineGlobal % LINES_PER_PATTERN);
        immutable ulong remTicks = (ev.tick * 4uL) % tpqn;
        immutable uint subStep = cast(uint)((remTicks * 32uL) / tpqn);
        immutable ubyte subFx = subStep > 0 && subStep <= 31
            ? cast(ubyte)(EffectCode.subLineDelayBase + subStep) : 0;

        if (ev.kind == 3) {
            immutable ubyte bpmVal = cast(ubyte)(ev.bpm > 255.0 ? 255.0 : (ev.bpm < 20.0 ? 20.0 : ev.bpm));
            proj.patterns[patIdx].cells[cast(size_t) localLine * activeTracks] =
                NoteCell.makeEffect(EffectCode.setBpm, bpmVal);
        } else if (ev.kind == 1) {
            immutable uint tr = chTrackIdx[ev.channel];
            immutable ushort modId = chModuleId[ev.channel];
            immutable float velNorm = cast(float) ev.velocity / 127.0f;
            proj.patterns[patIdx].cells[cast(size_t) localLine * activeTracks + tr] =
                NoteCell.makeNote(ev.note, velNorm, modId, subFx, 0);
        } else if (ev.kind == 2) {
            immutable uint tr = chTrackIdx[ev.channel];
            immutable ushort modId = chModuleId[ev.channel];
            immutable size_t idx = cast(size_t) localLine * activeTracks + tr;
            if (proj.patterns[patIdx].cells[idx].isEmpty()) {
                proj.patterns[patIdx].cells[idx] = NoteCell.makeNoteOff(modId, subFx, 0);
            }
        }
    }

    return true;
}
