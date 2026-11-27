/**
 * File:         source/compose/drum_writer.d
 * Module:       compose.drum_writer
 * Phase:        Composition helper (dracker-compose) — T79 (Drum parts)
 *
 * Purpose:
 *   Builds drum parts and drum patterns (PATTERN_KIND_DRUM) per decision T68. A drum part holds named
 *   lanes, each bound to a module handle and MIDI note (pre-populating standard kit lanes when bound to a
 *   DrumSynth module). Writes drum hits from step strings per lane (with accent and ghost symbols), single
 *   positions with velocities, and repeating pattern fills over a range of bars. Exports SavedPattern values
 *   with SavedDrumLane descriptors and matching TimelineClips compatible with StudioSession's drumpad model.
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Everything is @safe nothrow; no I/O or session state.
 *
 * Dependencies:
 *   Internal: compose.names (namesMatch, nearestName, trim), compose.part_writer (formatPartPatternName,
 *             PartWriter), compose.project_writer (ProjectDocumentResult, ProjectIdResult, ProjectModuleResult,
 *             ProjectProblem, ProjectProblemKind), compose.script.notation (parsePitch, PitchResult),
 *             compose.timing (BeatPosition, formatPosition, linesPerBar, LinesResult, lineToPosition,
 *             positionToLine, TimeSignature), io.project_format (LoadedProject, MAX_LANE_NAME_LEN, MAX_LINES,
 *             MAX_PATTERNS, MAX_TRACKS, PATTERN_KIND_DRUM, SavedDrumLane, SavedPattern,
 *             validateProjectForSave), sequencer.note (NoteCell), sequencer.timeline (TimelineClip)
 *   External: std.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DefaultKitVoice; enum DRUMSYNTH_TYPE_ID; immutable DRUMSYNTH_DEFAULT_KIT
 *   - enum DrumProblemKind; struct DrumProblem; struct DrumEditResult; struct DrumLaneInfo;
 *     struct DrumPartInfo
 *   - final class DrumWriter: addDrumPart(), addLane(), addLanePitch(), hasDrumPart(), drumPartNames(),
 *     lanesOf(), writeHit(), writeSteps(), writeFill(), savedPatterns(), patternCount(), applyToDocument()
 *
 * See_Also:
 *   docs/todo.md (T68, T77, T79), source/compose/part_writer.d, source/modules/synths/drumsynth.d
 */
module compose.drum_writer;

import std.math : isFinite;

import compose.names : namesMatch, nearestName, trim;
import compose.part_writer : formatPartPatternName, MAX_PART_NAME_LENGTH, PartProblem, PartWriter;
import compose.project_writer : ProjectDocumentResult, ProjectIdResult, ProjectModuleResult,
    ProjectProblem, ProjectProblemKind, ProjectWriter;
import compose.script.notation : parsePitch, PitchResult;
import compose.timing : BeatPosition, formatPosition, linesPerBar, LinesResult, lineToPosition,
    positionToLine, TimeSignature;
import io.project_format : LoadedProject, MAX_LANE_NAME_LEN, MAX_LINES, MAX_PATTERNS, MAX_TRACKS,
    PATTERN_KIND_DRUM, SavedDrumLane, SavedPattern;
import sequencer.note : NoteCell;

/** Module type id recognized as a DrumSynth for auto-populating standard kit lanes. */
enum string DRUMSYNTH_TYPE_ID = "synth.drumsynth";

/**
 * Default voice name and MIDI note pair for DrumSynth kits.
 */
struct DefaultKitVoice {
    string name;
    ubyte note;
}

/** Standard kit lanes populated when a drum part binds to a synth.drumsynth module. */
immutable DefaultKitVoice[] DRUMSYNTH_DEFAULT_KIT = [
    DefaultKitVoice("Kick", 36),
    DefaultKitVoice("Snare", 38),
    DefaultKitVoice("Closed Hat", 42),
    DefaultKitVoice("Open Hat", 46),
    DefaultKitVoice("Low Tom", 43),
    DefaultKitVoice("High Tom", 48),
    DefaultKitVoice("Perc", 39)
];

/** Diagnostic categories returned by DrumWriter. */
enum DrumProblemKind : ubyte {
    invalidName = 0,
    duplicatePart = 1,
    unknownPart = 2,
    duplicateLane = 3,
    unknownLane = 4,
    unknownModule = 5,
    unknownSection = 6,
    invalidNote = 7,
    invalidVelocity = 8,
    invalidStep = 9,
    positionOutOfRange = 10,
    invalidBarRange = 11,
    tooManyLanes = 12,
    tooManyPatterns = 13
}

/**
 * Structured error returned by DrumWriter operations.
 */
struct DrumProblem {
    DrumProblemKind kind = DrumProblemKind.invalidName;
    string subject = "";
    string reason = "";
    string suggestion = "";
    size_t offset = 0;
    size_t length = 0;

    /**
     * Formats the problem as one human-readable sentence with optional suggestion.
     *
     * Returns:
     *   Reason followed by "; did you mean '...'?" or "; the nearest valid value is ...".
     */
    string text() const @safe pure nothrow {
        string result = reason;
        if (suggestion.length > 0) {
            result ~= isNameKind(kind) ? "; did you mean '" ~ suggestion ~ "'?"
                : "; the nearest valid value is " ~ suggestion;
        }
        return result;
    }
}

/**
 * Result of a DrumWriter mutation.
 */
struct DrumEditResult {
    bool ok = false;
    DrumProblem problem = DrumProblem.init;
}

/**
 * Public description of one drum lane within a drum part.
 */
struct DrumLaneInfo {
    string name = "";
    string moduleHandle = "";
    uint moduleId = 0;
    ubyte note = 36;
}

private struct DrumPartEntry {
    string name = "";
    DrumLaneInfo[] lanes;
}

private struct DrumPatternEntry {
    uint localId = 0;
    uint fixedPatternId = 0;
    size_t partIndex = 0;
    size_t sectionIndex = 0;
    string name = "";
    uint tracks = 0;
    uint lines = 0;
    NoteCell[] cells;
}

/** Internal export descriptor used by PartWriter when building or arranging unified documents. */
package struct DrumExportEntry {
    SavedPattern pattern;
    size_t partIndex = 0;
    size_t sectionIndex = 0;
    uint patternId = 0;
}

private struct ParsedStep {
    bool hit = false;
    float velocity = 0.8f;
}

private bool isNameKind(DrumProblemKind kind) @safe pure nothrow @nogc {
    return kind == DrumProblemKind.invalidName || kind == DrumProblemKind.duplicatePart
        || kind == DrumProblemKind.unknownPart || kind == DrumProblemKind.duplicateLane
        || kind == DrumProblemKind.unknownLane || kind == DrumProblemKind.unknownModule
        || kind == DrumProblemKind.unknownSection;
}

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
 * Manages drum parts, per-lane module+note bindings, and drum patterns on top of a PartWriter.
 */
final class DrumWriter {
    private PartWriter parts_;
    private DrumPartEntry[] drumParts_;
    private DrumPatternEntry[] patterns_;
    private uint nextLocalId_ = 1;

    /**
     * Attaches the drum writer to an existing PartWriter.
     *
     * Params:
     *   parts = PartWriter owning sections, arrangement, and the attached ProjectWriter.
     */
    this(PartWriter parts) @safe nothrow {
        parts_ = parts;
        if (parts_ !is null && parts_.attachedDrums() is null) {
            parts_.attachDrums(this);
        }
    }

    /**
     * Registers a new drum part, optionally pre-populating default lanes when moduleHandle names
     * a DrumSynth module.
     *
     * Params:
     *   name = Drum part name.
     *   moduleHandle = Optional module handle (adds default DrumSynth kit lanes when type is synth.drumsynth).
     *
     * Returns:
     *   ok, or invalidName, duplicatePart, unknownModule or tooManyLanes.
     */
    DrumEditResult addDrumPart(string name, string moduleHandle = "") @safe nothrow {
        immutable string clean = trim(name);
        if (clean.length == 0 || clean.length > MAX_PART_NAME_LENGTH) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.invalidName, name,
                clean.length == 0 ? "a drum part name cannot be empty"
                    : "a drum part name is at most " ~ wholeText(MAX_PART_NAME_LENGTH) ~ " bytes",
                clean.length == 0 ? "drums" : clean[0 .. MAX_PART_NAME_LENGTH]));
        }
        if (indexOfDrumPart(clean) != drumParts_.length) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.duplicatePart, clean,
                "there is already a drum part '" ~ clean ~ "'", ""));
        }

        DrumLaneInfo[] initialLanes;
        immutable string cleanMod = trim(moduleHandle);
        if (cleanMod.length > 0) {
            ProjectModuleResult modRes = parts_.project().moduleOf(cleanMod);
            if (!modRes.ok) {
                return DrumEditResult(false, DrumProblem(DrumProblemKind.unknownModule, cleanMod,
                    modRes.problem.reason, modRes.problem.suggestion));
            }
            string canonicalMod = cleanMod;
            foreach (h; parts_.project().handles()) {
                if (namesMatch(h, cleanMod)) {
                    canonicalMod = h;
                    break;
                }
            }
            if (modRes.writer.typeId() == DRUMSYNTH_TYPE_ID) {
                foreach (ref voice; DRUMSYNTH_DEFAULT_KIT) {
                    initialLanes ~= DrumLaneInfo(voice.name, canonicalMod, modRes.id, voice.note);
                }
            }
        }

        drumParts_ ~= DrumPartEntry(clean, initialLanes);
        return DrumEditResult(true);
    }

    /**
     * Adds a named lane bound to a project module handle and MIDI note number to a drum part.
     *
     * Params:
     *   partName = Existing drum part name.
     *   laneName = Lane display name (1..MAX_LANE_NAME_LEN bytes).
     *   moduleHandle = Module handle in the attached ProjectWriter.
     *   note = MIDI note number [0, 127].
     *
     * Returns:
     *   ok, or unknownPart, invalidName, duplicateLane, unknownModule, invalidNote or tooManyLanes.
     */
    DrumEditResult addLane(string partName, string laneName, string moduleHandle, ubyte note) @safe nothrow {
        immutable size_t pIdx = indexOfDrumPart(partName);
        if (pIdx == drumParts_.length) {
            return DrumEditResult(false, unknownPartProblem(partName));
        }
        immutable string cleanLane = trim(laneName);
        if (cleanLane.length == 0 || cleanLane.length > MAX_LANE_NAME_LEN) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.invalidName, laneName,
                cleanLane.length == 0 ? "a drum lane name cannot be empty"
                    : "a drum lane name is at most " ~ wholeText(MAX_LANE_NAME_LEN) ~ " bytes",
                cleanLane.length == 0 ? "Kick" : cleanLane[0 .. MAX_LANE_NAME_LEN]));
        }
        if (indexOfLane(pIdx, cleanLane) != drumParts_[pIdx].lanes.length) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.duplicateLane, cleanLane,
                "drum part '" ~ drumParts_[pIdx].name ~ "' already has a lane '" ~ cleanLane ~ "'", ""));
        }
        if (drumParts_[pIdx].lanes.length >= MAX_TRACKS) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.tooManyLanes, cleanLane,
                "a drum part holds at most " ~ wholeText(MAX_TRACKS) ~ " lanes", ""));
        }
        if (note > 127) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.invalidNote, wholeText(note),
                "drum MIDI note must be between 0 and 127", "36"));
        }
        immutable ProjectIdResult modRes = parts_.project().moduleId(moduleHandle);
        if (!modRes.ok) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.unknownModule, moduleHandle,
                modRes.problem.reason, modRes.problem.suggestion));
        }
        string canonicalMod = moduleHandle;
        foreach (h; parts_.project().handles()) {
            if (namesMatch(h, moduleHandle)) {
                canonicalMod = h;
                break;
            }
        }

        immutable uint oldTracks = cast(uint) drumParts_[pIdx].lanes.length;
        drumParts_[pIdx].lanes ~= DrumLaneInfo(cleanLane, canonicalMod, modRes.id, note);
        immutable uint newTracks = oldTracks + 1;

        foreach (ref pat; patterns_) {
            if (pat.partIndex == pIdx) {
                NoteCell[] expanded = new NoteCell[cast(size_t) pat.lines * newTracks];
                foreach (ln; 0 .. pat.lines) {
                    foreach (tr; 0 .. oldTracks) {
                        expanded[cast(size_t) ln * newTracks + tr] = pat.cells[cast(size_t) ln * oldTracks + tr];
                    }
                }
                pat.tracks = newTracks;
                pat.cells = expanded;
            }
        }
        return DrumEditResult(true);
    }

    /**
     * Adds a named lane bound to a project module handle and a pitch spelling (such as "C3" or "F#2").
     *
     * Params:
     *   partName = Existing drum part name.
     *   laneName = Lane display name.
     *   moduleHandle = Module handle in the attached ProjectWriter.
     *   pitchText = Pitch spelling accepted by compose.script.notation.parsePitch().
     *
     * Returns:
     *   ok, or invalidNote / addLane problems.
     */
    DrumEditResult addLanePitch(string partName, string laneName, string moduleHandle, string pitchText)
            @safe nothrow {
        immutable PitchResult pr = parsePitch(trim(pitchText));
        if (!pr.ok) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.invalidNote, pitchText,
                pr.error.reason, pr.error.suggestion.length > 0 ? pr.error.suggestion : "C2"));
        }
        return addLane(partName, laneName, moduleHandle, pr.midi);
    }

    /**
     * Reports whether a drum part exists (matched case/space-insensitively).
     *
     * Params:
     *   name = Drum part name.
     *
     * Returns:
     *   True when found.
     */
    bool hasDrumPart(string name) const @safe nothrow {
        return indexOfDrumPart(name) != drumParts_.length;
    }

    /**
     * Lists declared drum part names in creation order.
     *
     * Returns:
     *   Array of drum part names.
     */
    string[] drumPartNames() const @safe nothrow {
        string[] names;
        foreach (ref dp; drumParts_) {
            names ~= dp.name;
        }
        return names;
    }

    /**
     * Returns the lanes configured on a drum part.
     *
     * Params:
     *   partName = Drum part name.
     *
     * Returns:
     *   Array of DrumLaneInfo (empty if unknown).
     */
    DrumLaneInfo[] lanesOf(string partName) const @safe nothrow {
        immutable size_t pIdx = indexOfDrumPart(partName);
        if (pIdx == drumParts_.length) {
            return null;
        }
        return drumParts_[pIdx].lanes.dup;
    }

    /**
     * Writes a single hit on a drum lane at BeatPosition pos inside a section (or implicit section).
     *
     * Params:
     *   partName = Drum part name.
     *   sectionName = Section name, or "" for implicit section.
     *   laneName = Lane name (matched case/space-insensitively).
     *   pos = BeatPosition counted from start of section.
     *   velocity = Hit velocity in (0, 1].
     *
     * Returns:
     *   ok, or a structured DrumProblem.
     */
    DrumEditResult writeHit(string partName, string sectionName, string laneName, BeatPosition pos,
            float velocity = 0.8f) @safe nothrow {
        if (!isFinite(velocity) || velocity <= 0.0f || velocity > 1.0f) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.invalidVelocity, "velocity",
                "drum hit velocity must be a finite number in (0, 1]", "0.8"));
        }
        size_t pIdx = 0;
        size_t lIdx = 0;
        size_t sIdx = 0;
        uint bars = 0;
        uint lines = 0;
        bool isImp = false;
        DrumProblem prob;
        if (!resolveTarget(partName, sectionName, laneName, pIdx, lIdx, sIdx, bars, lines, isImp, prob)) {
            return DrumEditResult(false, prob);
        }
        immutable TimeSignature sig = parts_.project().timeSignature();
        immutable LinesResult lineRes = positionToLine(pos, sig);
        if (!lineRes.ok) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.positionOutOfRange, formatPosition(pos),
                lineRes.error.reason, lineRes.error.suggestion));
        }
        if (isImp && lineRes.lines >= lines) {
            if (!growImplicitForDrums(lineRes.lines + 1, prob)) {
                return DrumEditResult(false, prob);
            }
            lines = parts_.sectionBarsAt(sIdx) * linesPerBar(sig);
        } else if (lineRes.lines >= lines) {
            immutable string lastPos = lines > 0
                ? formatPosition(lineToPosition(lines - 1, sig).position) : "1";
            return DrumEditResult(false, DrumProblem(DrumProblemKind.positionOutOfRange, formatPosition(pos),
                "position " ~ formatPosition(pos) ~ " is past the end of the section", lastPos));
        }

        immutable size_t patIdx = ensureDrumPattern(pIdx, sIdx, lines, isImp);
        if (patIdx == patterns_.length) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.tooManyPatterns, drumParts_[pIdx].name,
                "a project holds at most " ~ wholeText(MAX_PATTERNS) ~ " patterns", ""));
        }
        immutable DrumLaneInfo lane = drumParts_[pIdx].lanes[lIdx];
        immutable size_t cellIdx = cast(size_t) lineRes.lines * patterns_[patIdx].tracks + lIdx;
        patterns_[patIdx].cells[cellIdx] = NoteCell.makeNote(lane.note, velocity, cast(ushort) lane.moduleId);
        return DrumEditResult(true);
    }

    /**
     * Writes a step pattern string ('x'/'o' normal hit, 'X'/'O'/'!' accent, 'g' ghost, '-'/' .' rest;
     * spaces and '|' barlines ignored) for one lane starting at startPos.
     *
     * Params:
     *   partName = Drum part name.
     *   sectionName = Section name, or "" for implicit section.
     *   laneName = Lane name.
     *   stepString = Step string (e.g. "x---x---x---x---").
     *   startPos = Starting position (default BeatPosition(1, 1, 1)).
     *   velocity = Normal step velocity in (0, 1].
     *   accentVelocity = Accent step velocity in (0, 1].
     *   ghostVelocity = Ghost step velocity in (0, 1].
     *
     * Returns:
     *   ok, or a structured DrumProblem.
     */
    DrumEditResult writeSteps(string partName, string sectionName, string laneName, string stepString,
            BeatPosition startPos = BeatPosition(1, 1, 1), float velocity = 0.8f,
            float accentVelocity = 1.0f, float ghostVelocity = 0.45f) @safe nothrow {
        ParsedStep[] steps;
        DrumProblem stepProb;
        if (!parseStepString(stepString, velocity, accentVelocity, ghostVelocity, steps, stepProb)) {
            return DrumEditResult(false, stepProb);
        }
        size_t pIdx = 0;
        size_t lIdx = 0;
        size_t sIdx = 0;
        uint bars = 0;
        uint lines = 0;
        bool isImp = false;
        if (!resolveTarget(partName, sectionName, laneName, pIdx, lIdx, sIdx, bars, lines, isImp, stepProb)) {
            return DrumEditResult(false, stepProb);
        }
        immutable TimeSignature sig = parts_.project().timeSignature();
        immutable LinesResult lineRes = positionToLine(startPos, sig);
        if (!lineRes.ok) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.positionOutOfRange, formatPosition(startPos),
                lineRes.error.reason, lineRes.error.suggestion));
        }
        immutable ulong endLine = cast(ulong) lineRes.lines + cast(ulong) steps.length;
        if (isImp && endLine > lines) {
            if (!growImplicitForDrums(cast(uint)(endLine > MAX_LINES ? MAX_LINES + 1 : endLine), stepProb)) {
                return DrumEditResult(false, stepProb);
            }
            lines = parts_.sectionBarsAt(sIdx) * linesPerBar(sig);
        } else if (endLine > lines) {
            immutable string sugg = steps.length <= lines
                ? formatPosition(lineToPosition(lines - cast(uint) steps.length, sig).position) : "1";
            return DrumEditResult(false, DrumProblem(DrumProblemKind.positionOutOfRange, formatPosition(startPos),
                "step pattern runs past the end of the section", sugg));
        }

        immutable size_t patIdx = ensureDrumPattern(pIdx, sIdx, lines, isImp);
        if (patIdx == patterns_.length) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.tooManyPatterns, drumParts_[pIdx].name,
                "a project holds at most " ~ wholeText(MAX_PATTERNS) ~ " patterns", ""));
        }
        immutable DrumLaneInfo lane = drumParts_[pIdx].lanes[lIdx];
        foreach (offset, ref st; steps) {
            immutable size_t ln = cast(size_t) lineRes.lines + offset;
            immutable size_t cellIdx = ln * patterns_[patIdx].tracks + lIdx;
            if (st.hit) {
                patterns_[patIdx].cells[cellIdx] = NoteCell.makeNote(lane.note, st.velocity,
                    cast(ushort) lane.moduleId);
            } else {
                patterns_[patIdx].cells[cellIdx] = NoteCell.init;
            }
        }
        return DrumEditResult(true);
    }

    /**
     * Repeats a step pattern across every line from startBar through endBar (1-based inclusive) on a lane.
     *
     * Params:
     *   partName = Drum part name.
     *   sectionName = Section name, or "" for implicit section.
     *   laneName = Lane name.
     *   startBar = First 1-based bar of the fill.
     *   endBar = Last 1-based bar of the fill (>= startBar and <= section bars).
     *   stepString = Non-empty repeating step string.
     *   velocity = Normal hit velocity.
     *   accentVelocity = Accent hit velocity.
     *   ghostVelocity = Ghost hit velocity.
     *
     * Returns:
     *   ok, or a structured DrumProblem.
     */
    DrumEditResult writeFill(string partName, string sectionName, string laneName, uint startBar,
            uint endBar, string stepString, float velocity = 0.8f, float accentVelocity = 1.0f,
            float ghostVelocity = 0.45f) @safe nothrow {
        ParsedStep[] steps;
        DrumProblem stepProb;
        if (!parseStepString(stepString, velocity, accentVelocity, ghostVelocity, steps, stepProb)) {
            return DrumEditResult(false, stepProb);
        }
        if (steps.length == 0) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.invalidStep, stepString,
                "a drum fill pattern needs at least one step", "x---"));
        }
        size_t pIdx = 0;
        size_t lIdx = 0;
        size_t sIdx = 0;
        uint bars = 0;
        uint lines = 0;
        bool isImp = false;
        if (!resolveTarget(partName, sectionName, laneName, pIdx, lIdx, sIdx, bars, lines, isImp, stepProb)) {
            return DrumEditResult(false, stepProb);
        }
        if (startBar == 0 || startBar > endBar) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.invalidBarRange, wholeText(startBar),
                "bar range must start at 1 or higher with endBar >= startBar", "1"));
        }
        immutable uint lpb = linesPerBar(parts_.project().timeSignature());
        immutable ulong fillEndLine = cast(ulong) endBar * cast(ulong) lpb;
        if (isImp && endBar > bars) {
            if (!growImplicitForDrums(cast(uint)(fillEndLine > MAX_LINES ? MAX_LINES + 1 : fillEndLine), stepProb)) {
                return DrumEditResult(false, stepProb);
            }
            lines = parts_.sectionBarsAt(sIdx) * lpb;
        } else if (endBar > bars) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.invalidBarRange, wholeText(endBar),
                "end bar " ~ wholeText(endBar) ~ " exceeds section length of " ~ wholeText(bars) ~ " bars",
                wholeText(bars)));
        }

        immutable size_t patIdx = ensureDrumPattern(pIdx, sIdx, lines, isImp);
        if (patIdx == patterns_.length) {
            return DrumEditResult(false, DrumProblem(DrumProblemKind.tooManyPatterns, drumParts_[pIdx].name,
                "a project holds at most " ~ wholeText(MAX_PATTERNS) ~ " patterns", ""));
        }
        immutable uint firstLine = (startBar - 1) * lpb;
        immutable uint lastLineExclusive = endBar * lpb;
        immutable DrumLaneInfo lane = drumParts_[pIdx].lanes[lIdx];
        foreach (ln; firstLine .. lastLineExclusive) {
            immutable ParsedStep st = steps[(ln - firstLine) % steps.length];
            immutable size_t cellIdx = cast(size_t) ln * patterns_[patIdx].tracks + lIdx;
            if (st.hit) {
                patterns_[patIdx].cells[cellIdx] = NoteCell.makeNote(lane.note, st.velocity,
                    cast(ushort) lane.moduleId);
            } else {
                patterns_[patIdx].cells[cellIdx] = NoteCell.init;
            }
        }
        return DrumEditResult(true);
    }

    /**
     * Returns how many drum patterns have been created so far.
     *
     * Returns:
     *   Drum pattern count.
     */
    size_t patternCount() const @safe nothrow {
        return patterns_.length;
    }

    /**
     * Exports all created drum patterns as SavedPattern entries (PATTERN_KIND_DRUM with SavedDrumLanes).
     *
     * Params:
     *   firstPatternId = First pattern id to assign when a pattern has no fixed id (default 1).
     *
     * Returns:
     *   Array of SavedPattern values in creation order.
     */
    SavedPattern[] savedPatterns(uint firstPatternId = 1) const @safe nothrow {
        bool[uint] emptyUsed;
        auto exports = exportPatterns(firstPatternId, emptyUsed);
        SavedPattern[] result;
        result.reserve(exports.length);
        foreach (ref ex; exports) {
            result ~= ex.pattern;
        }
        return result;
    }

    /**
     * Exports all drum patterns along with their part/section coordinates for PartWriter.
     *
     * Params:
     *   firstAutoId = Minimum id used when allocating ids for newly created drum patterns.
     *   usedIds = Pattern ids already allocated by PartWriter.
     *
     * Returns:
     *   Array of DrumExportEntry records.
     */
    package DrumExportEntry[] exportPatterns(uint firstAutoId, const(bool[uint]) usedIds) const @safe nothrow {
        bool[uint] localUsed;
        foreach (ref entry; patterns_) {
            if (entry.fixedPatternId != 0) {
                localUsed[entry.fixedPatternId] = true;
            }
        }
        uint nextAuto = firstAutoId < 1 ? 1 : firstAutoId;
        DrumExportEntry[] result;
        result.reserve(patterns_.length);
        foreach (ref entry; patterns_) {
            uint pid = entry.fixedPatternId;
            if (pid == 0) {
                while ((pid == 0) || (nextAuto in usedIds) !is null || (nextAuto in localUsed) !is null) {
                    if (pid == 0 && (nextAuto in usedIds) is null && (nextAuto in localUsed) is null) {
                        pid = nextAuto;
                        nextAuto++;
                        break;
                    }
                    nextAuto++;
                }
                localUsed[pid] = true;
            }
            SavedPattern pat;
            pat.patternId = pid;
            pat.tracks = entry.tracks;
            pat.lines = entry.lines;
            pat.name = entry.name;
            pat.kind = PATTERN_KIND_DRUM;
            pat.cells = entry.cells.dup;
            foreach (ref lane; drumParts_[entry.partIndex].lanes) {
                pat.lanes ~= SavedDrumLane(lane.name, lane.moduleId, lane.note);
            }
            result ~= DrumExportEntry(pat, entry.partIndex, entry.sectionIndex, pid);
        }
        return result;
    }

    /**
     * Returns the number of configured drum parts.
     *
     * Returns:
     *   Drum part count.
     */
    package size_t drumPartCount() const @safe nothrow {
        return drumParts_.length;
    }

    /**
     * Reports whether any imported drum pattern reserves the given fixed pattern id.
     *
     * Params:
     *   patId = Pattern id to check.
     *
     * Returns:
     *   True when reserved.
     */
    package bool hasFixedPatternId(uint patId) const @safe nothrow {
        foreach (ref entry; patterns_) {
            if (entry.fixedPatternId == patId) {
                return true;
            }
        }
        return false;
    }

    /**
     * Imports a PATTERN_KIND_DRUM SavedPattern reconstructed from an opened project.
     *
     * Params:
     *   desiredPartName = Preferred drum part name derived from pattern/module name.
     *   sectionIndex = Section index in the attached PartWriter.
     *   pat = Saved drum pattern preserving patternId, lanes, name, and cells verbatim.
     *   assignedPartName = Receives the canonical drum part name assigned or reused.
     *
     * Returns:
     *   True when imported.
     */
    package bool importDrumPattern(string desiredPartName, size_t sectionIndex, const ref SavedPattern pat,
            out string assignedPartName) @safe nothrow {
        DrumLaneInfo[] lanes;
        lanes.reserve(pat.lanes.length);
        foreach (ref sl; pat.lanes) {
            lanes ~= DrumLaneInfo(sl.name, parts_.project().handleForId(sl.moduleId), sl.moduleId, sl.note);
        }

        size_t chosenPart = drumParts_.length;
        foreach (i, ref dp; drumParts_) {
            if (namesMatch(dp.name, desiredPartName) && lanesMatch(dp.lanes, lanes)
                    && indexOfDrumPattern(i, sectionIndex) == patterns_.length) {
                chosenPart = i;
                break;
            }
        }
        if (chosenPart == drumParts_.length) {
            foreach (i, ref dp; drumParts_) {
                if (lanesMatch(dp.lanes, lanes) && indexOfDrumPattern(i, sectionIndex) == patterns_.length) {
                    chosenPart = i;
                    break;
                }
            }
        }
        if (chosenPart == drumParts_.length) {
            string clean = trim(desiredPartName);
            if (clean.length == 0) {
                clean = "drums";
            }
            if (clean.length > MAX_PART_NAME_LENGTH) {
                clean = clean[0 .. MAX_PART_NAME_LENGTH];
            }
            string finalName = clean;
            if (indexOfDrumPart(finalName) != drumParts_.length) {
                finalName = freeDrumPartName(clean);
            }
            chosenPart = drumParts_.length;
            drumParts_ ~= DrumPartEntry(finalName, lanes);
        }

        patterns_ ~= DrumPatternEntry(nextLocalId_++, pat.patternId, chosenPart, sectionIndex,
            pat.name, pat.tracks, pat.lines, pat.cells.dup);
        assignedPartName = drumParts_[chosenPart].name;
        return true;
    }

    /**
     * Builds a full LoadedProject containing the PartWriter's melodic parts plus all drum patterns
     * and arranged drum timeline clips, ready for saving or StudioSession activation.
     *
     * Returns:
     *   ProjectDocumentResult validated by validateProjectForSave().
     */
    ProjectDocumentResult buildDocument() const @safe nothrow {
        return parts_.buildDocument(this);
    }

    private bool resolveTarget(string partName, string sectionName, string laneName,
            out size_t pIdx, out size_t lIdx, out size_t sIdx, out uint bars, out uint lines,
            out bool isImplicit, out DrumProblem problem) @safe nothrow {
        pIdx = indexOfDrumPart(partName);
        if (pIdx == drumParts_.length) {
            problem = unknownPartProblem(partName);
            return false;
        }
        lIdx = indexOfLane(pIdx, laneName);
        if (lIdx == drumParts_[pIdx].lanes.length) {
            problem = unknownLaneProblem(pIdx, laneName);
            return false;
        }
        PartProblem secProb;
        if (!parts_.resolveSectionForWrite(sectionName, sIdx, bars, lines, isImplicit, secProb)) {
            problem = DrumProblem(DrumProblemKind.unknownSection, secProb.subject,
                secProb.reason, secProb.suggestion);
            return false;
        }
        return true;
    }

    private bool growImplicitForDrums(uint minLines, out DrumProblem problem) @safe nothrow {
        if (minLines > MAX_LINES) {
            immutable uint lpb = linesPerBar(parts_.project().timeSignature());
            immutable uint maxBars = lpb > 0 ? MAX_LINES / lpb : 1;
            problem = DrumProblem(DrumProblemKind.positionOutOfRange, wholeText(minLines),
                "drum pattern exceeds the maximum length of " ~ wholeText(MAX_LINES) ~ " lines",
                wholeText(maxBars));
            return false;
        }
        PartProblem pProb;
        if (!parts_.growImplicitSectionToLines(minLines, pProb)) {
            problem = DrumProblem(DrumProblemKind.positionOutOfRange, pProb.subject,
                pProb.reason, pProb.suggestion);
            return false;
        }
        immutable uint targetLines = parts_.arrangementLengthLines() > 0
            ? cast(uint) parts_.arrangementLengthLines() : minLines;
        foreach (ref pat; patterns_) {
            if (pat.lines < targetLines) {
                NoteCell[] resized = new NoteCell[cast(size_t) pat.tracks * targetLines];
                if (pat.cells.length > 0) {
                    resized[0 .. pat.cells.length] = pat.cells[];
                }
                pat.lines = targetLines;
                pat.cells = resized;
            }
        }
        return true;
    }

    private size_t ensureDrumPattern(size_t pIdx, size_t sIdx, uint lines, bool isImp) @safe nothrow {
        immutable size_t existing = indexOfDrumPattern(pIdx, sIdx);
        if (existing != patterns_.length) {
            return existing;
        }
        if (parts_.patternCount() + patterns_.length >= MAX_PATTERNS) {
            return patterns_.length;
        }
        immutable uint tracks = cast(uint) drumParts_[pIdx].lanes.length;
        immutable string secName = "";
        immutable string patName = isImp
            ? drumParts_[pIdx].name
            : formatPartPatternName(drumParts_[pIdx].name, sectionNameForIndex(sIdx), false);
        cast(void) secName;
        patterns_ ~= DrumPatternEntry(nextLocalId_++, 0, pIdx, sIdx, patName, tracks, lines,
            new NoteCell[cast(size_t) tracks * lines]);
        return patterns_.length - 1;
    }

    private string sectionNameForIndex(size_t sIdx) const @safe nothrow {
        return parts_.sectionNameAt(sIdx);
    }

    private static bool lanesMatch(const(DrumLaneInfo)[] a, const(DrumLaneInfo)[] b) @safe nothrow {
        if (a.length != b.length) {
            return false;
        }
        foreach (i; 0 .. a.length) {
            if (a[i].moduleId != b[i].moduleId || a[i].note != b[i].note || !namesMatch(a[i].name, b[i].name)) {
                return false;
            }
        }
        return true;
    }

    private string freeDrumPartName(string stem) const @safe nothrow {
        foreach (n; 2 .. MAX_PATTERNS + 2) {
            immutable string digits = wholeText(n);
            immutable string base = stem.length + digits.length > MAX_PART_NAME_LENGTH
                ? stem[0 .. MAX_PART_NAME_LENGTH - digits.length] : stem;
            if (indexOfDrumPart(base ~ digits) == drumParts_.length) {
                return base ~ digits;
            }
        }
        return stem;
    }

    private static bool parseStepString(string text, float vel, float accentVel, float ghostVel,
            out ParsedStep[] steps, out DrumProblem problem) @safe pure nothrow {
        if (!isFinite(vel) || vel <= 0.0f || vel > 1.0f || !isFinite(accentVel) || accentVel <= 0.0f
                || accentVel > 1.0f || !isFinite(ghostVel) || ghostVel <= 0.0f || ghostVel > 1.0f) {
            problem = DrumProblem(DrumProblemKind.invalidVelocity, "velocity",
                "drum step velocities must be finite numbers in (0, 1]", "0.8");
            return false;
        }
        foreach (i, char c; text) {
            if (c == ' ' || c == '\t' || c == '|') {
                continue;
            }
            if (c == 'x' || c == 'o') {
                steps ~= ParsedStep(true, vel);
            } else if (c == 'X' || c == 'O' || c == '!') {
                steps ~= ParsedStep(true, accentVel);
            } else if (c == 'g') {
                steps ~= ParsedStep(true, ghostVel);
            } else if (c == '-' || c == '.') {
                steps ~= ParsedStep(false, 0.0f);
            } else {
                problem = DrumProblem(DrumProblemKind.invalidStep, [c].idup,
                    "unexpected step character '" ~ [c].idup ~ "' (use x/X/g for hits and - for rests)",
                    "x", i, 1);
                return false;
            }
        }
        if (steps.length == 0) {
            problem = DrumProblem(DrumProblemKind.invalidStep, text,
                "a step pattern must contain at least one hit or rest", "x---");
            return false;
        }
        return true;
    }

    private size_t indexOfDrumPart(string name) const @safe nothrow {
        if (trim(name).length == 0) {
            return drumParts_.length;
        }
        foreach (i, ref dp; drumParts_) {
            if (namesMatch(dp.name, name)) {
                return i;
            }
        }
        return drumParts_.length;
    }

    private size_t indexOfLane(size_t pIdx, string name) const @safe nothrow {
        if (trim(name).length == 0) {
            return drumParts_[pIdx].lanes.length;
        }
        foreach (i, ref l; drumParts_[pIdx].lanes) {
            if (namesMatch(l.name, name)) {
                return i;
            }
        }
        return drumParts_[pIdx].lanes.length;
    }

    private size_t indexOfDrumPattern(size_t pIdx, size_t sIdx) const @safe nothrow {
        foreach (i, ref pat; patterns_) {
            if (pat.partIndex == pIdx && pat.sectionIndex == sIdx) {
                return i;
            }
        }
        return patterns_.length;
    }

    private DrumProblem unknownPartProblem(string name) const @safe nothrow {
        return DrumProblem(DrumProblemKind.unknownPart, name,
            "there is no drum part '" ~ name ~ "'", nearestName(name, drumPartNames()));
    }

    private DrumProblem unknownLaneProblem(size_t pIdx, string name) const @safe nothrow {
        string[] names;
        foreach (ref l; drumParts_[pIdx].lanes) {
            names ~= l.name;
        }
        return DrumProblem(DrumProblemKind.unknownLane, name,
            "drum part '" ~ drumParts_[pIdx].name ~ "' has no lane '" ~ name ~ "'",
            nearestName(name, names));
    }
}
