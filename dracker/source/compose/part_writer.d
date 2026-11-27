/**
 * File:         source/compose/part_writer.d
 * Module:       compose.part_writer
 * Phase:        Composition helper (dracker-compose) — T77, T97 & T98 (Parts, notes, arrangement)
 *
 * Purpose:
 *   Holds the sections, parts, per-(part, section) patterns, written notes, and song arrangement of a
 *   project being composed (decisions T68 and T90). A section has a name and a length in bars; a part
 *   binds a voice name to one module handle of a ProjectWriter. Each part gets at most one pattern per
 *   section it plays in, created on first use, named "<part> · <section>" (or "<part>" for the implicit
 *   section used by scripts that name no sections), and sized from the section length and the project's time
 *   signature. Notes are written at section-relative positions via compose.timing and placed using
 *   app.pattern_notes (adding tracker tracks for polyphony, writing note-offs on end, refusing same-pitch
 *   overlaps and past-end notes). arrange() builds timeline clips across one lane per part, reuses section
 *   patterns as clone clips, leaves gaps where a part does not play, and sets the song loop. Lookups
 *   ignore ASCII case and spaces and return structured problems with the nearest valid name or value.
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Everything is @safe nothrow; no I/O or session state.
 *
 * Dependencies:
 *   Internal: app.pattern_notes (addNote, NoteEdit, notesOf, PatternGrid, RollNote), compose.names
 *             (namesMatch, nearestName, trim), compose.project_writer (ProjectDocumentResult,
 *             ProjectIdResult, ProjectProblem, ProjectProblemKind, ProjectWriter), compose.script.notation
 *             (DEFAULT_NOTE_VELOCITY, NoteEvent), compose.timing (BeatPosition, formatPosition, Length,
 *             linesPerBar, LinesResult, lineToPosition, positionToLine, PositionResult, TimeSignature),
 *             io.project_format (LoadedProject, MAX_LINES, MAX_PATTERNS, PATTERN_KIND_NORMAL, SavedPattern,
 *             validateProjectForSave), sequencer.note (NoteCell), sequencer.timeline (TimelineClip)
 *   External: std.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum MAX_PART_NAME_LENGTH, PATTERN_NAME_SEPARATOR
 *   - enum PartProblemKind; struct PartProblem; struct PartEditResult; struct SectionInfo; struct SectionResult;
 *     struct PartInfo; struct PartResult; struct PartPatternInfo; struct PartPatternResult; struct PartNote
 *   - final class PartWriter: addSection(), hasSection(), sectionCount(), sectionNames(), sectionOf(),
 *     ensureImplicitSection(), hasImplicitSection(), addPart(), hasPart(), partCount(), partNames(), partOf(),
 *     patternFor(), hasPattern(), patternCount(), patterns(), savedPatterns(), patternGrid(), mutableGrid(),
 *     writeNote(), writeNotes(), notesOfPart(), arrange(), arrangement(), setLoopSections(), setLoopLines(),
 *     clearLoop(), arrangementLengthLines(), loopStartLine(), loopEndLine(), arrangementClips(),
 *     buildDocument(), arrangedSectionIndices(), sectionBarsAt()
 *
 * See_Also:
 *   docs/todo.md (T68, T76, T77, T78, T90, T97, T98), source/compose/project_writer.d,
 *   source/app/pattern_notes.d
 */
module compose.part_writer;

import std.math : isFinite;

import app.music_theory : KeyMode, MusicalKey, scalePitchClasses;
import app.pattern_notes : addNote, cellVelocity, deleteNotes, NoteEdit, notesOf, PatternGrid,
    ROLL_MAX_TRACKS, RollNote, setNoteVelocity;
import compose.drum_writer : DrumExportEntry, DrumWriter;
import compose.names : namesMatch, nearestName, trim;
import compose.project_writer : ProjectDocumentResult, ProjectIdResult, ProjectProblem, ProjectProblemKind,
    ProjectWriter;
import compose.script.notation : DEFAULT_NOTE_VELOCITY, NoteEvent;
import compose.timing : BeatPosition, formatPosition, Length, linesPerBar, LinesResult, lineToPosition,
    positionToLine, PositionResult, TimeSignature;
import io.project_format : LoadedProject, MAX_LINES, MAX_PATTERNS, MAX_TRACKS, PATTERN_KIND_DRUM,
    PATTERN_KIND_NORMAL, SavedDrumLane, SavedPattern, validateProjectForSave;
import sequencer.note : NoteCell, NoteCmd;
import sequencer.timeline : TimelineClip;

/** Maximum length in bytes of a single section or part name so "<part> · <section>" stays well within MAX_STRING_LEN. */
enum size_t MAX_PART_NAME_LENGTH = 64;

/** UTF-8 middle-dot separator used between part and section in pattern names ("<part> · <section>"). */
enum string PATTERN_NAME_SEPARATOR = " \u00B7 ";

/** The kinds of problem a part writer returns as data. */
enum PartProblemKind : ubyte {
    invalidName = 0,
    duplicateSection = 1,
    unknownSection = 2,
    invalidBars = 3,
    sectionTooLong = 4,
    duplicatePart = 5,
    unknownPart = 6,
    unknownModule = 7,
    tooManyPatterns = 8,
    positionOutOfRange = 9,
    noteOverlap = 10,
    tooManyTracks = 11,
    invalidVelocity = 12,
    invalidLength = 13,
    invalidArrangement = 14,
    invalidLoop = 15,
    invalidPitch = 16,
    unknownPattern = 17,
    invalidCell = 18,
    invalidRepeatCount = 19
}

/**
 * A problem found by the part writer, returned as data so a front end decides how to show it.
 */
struct PartProblem {
    PartProblemKind kind = PartProblemKind.invalidName;
    string subject = "";
    string reason = "";
    string suggestion = "";

    /**
     * Writes the problem as one sentence: the reason, then the suggestion when there is one.
     *
     * Returns:
     *   The reason followed by "; did you mean '...'?" for a name problem, or by
     *   "; the nearest valid value is ..." for a numeric problem.
     */
    string text() const @safe pure nothrow {
        string result = reason;
        if (suggestion.length > 0) {
            result ~= isNameProblem(kind) ? "; did you mean '" ~ suggestion ~ "'?"
                : "; the nearest valid value is " ~ suggestion;
        }
        return result;
    }
}

/**
 * Outcome of an edit to a part writer.
 */
struct PartEditResult {
    bool ok = false;
    PartProblem problem = PartProblem.init;
}

/**
 * Description of one declared or implicit section.
 */
struct SectionInfo {
    string name = "";
    uint bars = 0;
    uint lines = 0;
    bool isImplicit = false;
}

/**
 * Result of looking up or creating a section.
 */
struct SectionResult {
    SectionInfo section = SectionInfo.init;
    bool ok = false;
    PartProblem problem = PartProblem.init;
}

/**
 * Description of one part bound to a module in the project.
 */
struct PartInfo {
    string name = "";
    string moduleHandle = "";
    uint moduleId = 0;
}

/**
 * Result of looking up or creating a part.
 */
struct PartResult {
    PartInfo part = PartInfo.init;
    bool ok = false;
    PartProblem problem = PartProblem.init;
}

/**
 * Metadata for one pattern owned by a (part, section) pair.
 */
struct PartPatternInfo {
    uint patternId = 0;
    string name = "";
    string partName = "";
    string sectionName = "";
    uint moduleId = 0;
    uint tracks = 0;
    uint lines = 0;
    bool isImplicitSection = false;
}

/**
 * Result of retrieving or creating the pattern for a (part, section) pair.
 */
struct PartPatternResult {
    PartPatternInfo pattern = PartPatternInfo.init;
    bool ok = false;
    PartProblem problem = PartProblem.init;
}

/**
 * One note read back from a part's section pattern.
 */
struct PartNote {
    BeatPosition position;
    uint line = 0;
    uint lengthLines = 1;
    ubyte pitch = 60;
    float velocity = DEFAULT_NOTE_VELOCITY;
    uint track = 0;
}

/**
 * Result of reading one cell from a pattern grid.
 */
struct CellResult {
    NoteCell cell = NoteCell.init;
    bool ok = false;
    PartProblem problem = PartProblem.init;
}

/**
 * Provenance mapping for one pattern found when opening an existing project.
 */
struct OpenedPatternMapping {
    uint patternId = 0;
    string patternName = "";
    bool isPart = false;
    bool isDrum = false;
    string partName = "";
    string sectionName = "";
}

/**
 * Result of reconstructing parts, sections, drum parts, and arrangement from an opened ProjectWriter.
 */
struct PartOpenResult {
    PartWriter parts = null;
    DrumWriter drums = null;
    OpenedPatternMapping[] patterns;
    bool arrangementReconstructed = false;
    bool ok = false;
    PartProblem problem = PartProblem.init;
}

/**
 * Internal stored section record.
 */
private struct SectionEntry {
    string name = "";
    uint bars = 0;
    bool isImplicit = false;
}

/**
 * Internal stored part record.
 */
private struct PartEntry {
    string name = "";
    string moduleHandle = "";
    uint moduleId = 0;
}

/**
 * Internal stored pattern record bound to one (partIndex, sectionIndex) pair, or a standalone raw pattern.
 */
private struct PatternEntry {
    uint patternId = 0;
    size_t partIndex = 0;
    size_t sectionIndex = 0;
    string name = "";
    PatternGrid grid;
    bool isRaw = false;
    ubyte kind = PATTERN_KIND_NORMAL;
    SavedDrumLane[] lanes;
    bool[ulong] handPlaced;
}

/**
 * Writes a whole number in decimal.
 *
 * Params:
 *   value = The non-negative integer.
 *
 * Returns:
 *   Decimal representation.
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
 * Reports whether a problem kind suggests a name rather than a numeric value.
 *
 * Params:
 *   kind = The problem kind.
 *
 * Returns:
 *   True for name lookup and duplicate/invalid name problems.
 */
private bool isNameProblem(PartProblemKind kind) @safe pure nothrow @nogc {
    return kind == PartProblemKind.invalidName || kind == PartProblemKind.duplicateSection
        || kind == PartProblemKind.unknownSection || kind == PartProblemKind.duplicatePart
        || kind == PartProblemKind.unknownPart || kind == PartProblemKind.unknownModule
        || kind == PartProblemKind.invalidArrangement || kind == PartProblemKind.unknownPattern;
}

/**
 * Builds the pattern name for a part and section according to decision T68.
 *
 * Params:
 *   partName = Canonical part name.
 *   sectionName = Canonical section name.
 *   isImplicit = True when the section is the implicit section.
 *
 * Returns:
 *   "<part>" for the implicit section, or "<part> · <section>" for a named section.
 */
string formatPartPatternName(string partName, string sectionName, bool isImplicit = false) @safe pure nothrow {
    return isImplicit ? partName : (partName ~ PATTERN_NAME_SEPARATOR ~ sectionName);
}

/**
 * Holds sections, parts and per-(part, section) patterns for a ProjectWriter.
 *
 * Patterns are created lazily on first use, sized from the section's bar count and the project's
 * time signature, and owned exclusively by their (part, section) pair.
 */
final class PartWriter {
    private ProjectWriter project_;
    private SectionEntry[] sections_;
    private size_t implicitIndex_ = size_t.max;
    private PartEntry[] parts_;
    private PatternEntry[] patterns_;
    private uint nextPatternId_ = 1;
    private size_t[] arrangedSectionIndices_;
    private bool hasCustomLoop_ = false;
    private long customLoopStart_ = 0;
    private long customLoopEnd_ = 0;
    private bool hasPreservedClips_ = false;
    private TimelineClip[] preservedClips_;
    private long preservedLoopStart_ = 0;
    private long preservedLoopEnd_ = 0;
    private bool[uint] originalPatternIds_;
    private DrumWriter attachedDrums_ = null;

    /**
     * Starts a part writer attached to a ProjectWriter.
     *
     * Params:
     *   project = The project writer whose modules and time signature this writer uses.
     */
    this(ProjectWriter project) @safe nothrow {
        project_ = project;
    }

    /**
     * Returns the attached drum writer, if any.
     *
     * Returns:
     *   Attached DrumWriter or null.
     */
    package DrumWriter attachedDrums() @safe nothrow {
        return attachedDrums_;
    }

    /**
     * Attaches a DrumWriter so buildDocument() exports unified melodic + drum patterns and clips.
     *
     * Params:
     *   drums = DrumWriter instance sharing this PartWriter.
     */
    package void attachDrums(DrumWriter drums) @safe nothrow {
        attachedDrums_ = drums;
    }

    /**
     * Returns the canonical section name for raw section index sIdx.
     *
     * Params:
     *   sIdx = Index into sections_.
     *
     * Returns:
     *   Section name or "".
     */
    package string sectionNameAt(size_t sIdx) const @safe nothrow {
        return sIdx < sections_.length ? sections_[sIdx].name : "";
    }

    /**
     * Returns the attached project writer.
     *
     * Returns:
     *   The ProjectWriter passed at construction.
     */
    inout(ProjectWriter) project() inout @safe nothrow {
        return project_;
    }

    /**
     * Adds a named section with a bar length validated against MAX_LINES in the current time signature.
     *
     * Params:
     *   name = Section name (non-empty after trimming, at most MAX_PART_NAME_LENGTH bytes).
     *   bars = Section length in bars (at least 1, and bars * linesPerBar <= MAX_LINES).
     *
     * Returns:
     *   The section info, or invalidName, duplicateSection, invalidBars or sectionTooLong.
     */
    SectionResult addSection(string name, uint bars) @safe nothrow {
        immutable string clean = trim(name);
        PartProblem nameProb;
        if (!checkName("section", name, clean, nameProb)) {
            return SectionResult(SectionInfo.init, false, nameProb);
        }
        if (indexOfSection(clean) != sections_.length) {
            return SectionResult(SectionInfo.init, false, PartProblem(PartProblemKind.duplicateSection, clean,
                "there is already a section '" ~ clean ~ "'", freeSectionName(clean)));
        }
        PartProblem barProb;
        uint lineCount = 0;
        if (!checkSectionBars(clean, bars, lineCount, barProb)) {
            return SectionResult(SectionInfo.init, false, barProb);
        }
        sections_ ~= SectionEntry(clean, bars, false);
        return SectionResult(SectionInfo(clean, bars, lineCount, false), true);
    }

    /**
     * Ensures the implicit section (used when a script writes music without naming sections) exists,
     * creating it with the given bar length or resizing it if no pattern has been created in it yet.
     *
     * Params:
     *   bars = Length in bars (at least 1, default 1).
     *
     * Returns:
     *   The implicit section info, or invalidBars / sectionTooLong.
     */
    SectionResult ensureImplicitSection(uint bars = 1) @safe nothrow {
        PartProblem barProb;
        uint lineCount = 0;
        if (!checkSectionBars("implicit section", bars, lineCount, barProb)) {
            return SectionResult(SectionInfo.init, false, barProb);
        }
        if (implicitIndex_ == size_t.max) {
            implicitIndex_ = sections_.length;
            sections_ ~= SectionEntry("", bars, true);
        } else if (bars > sections_[implicitIndex_].bars) {
            sections_[implicitIndex_].bars = bars;
        }
        immutable uint effectiveBars = sections_[implicitIndex_].bars;
        immutable uint lpb = linesPerBar(project_.timeSignature());
        return SectionResult(SectionInfo("", effectiveBars, effectiveBars * lpb, true), true);
    }

    /**
     * Grows the implicit section to hold at least minLines lines (rounding up to whole bars),
     * resizing any already-created implicit-section PatternGrid in place without dropping existing cells.
     *
     * Params:
     *   minLines = Required total line count.
     *   problem = Receives sectionTooLong if minLines exceeds MAX_LINES.
     *
     * Returns:
     *   True when the implicit section now holds at least minLines lines.
     */
    package bool growImplicitSectionToLines(uint minLines, out PartProblem problem) @safe nothrow {
        immutable uint lpb = linesPerBar(project_.timeSignature());
        if (lpb == 0) {
            return checkSectionBars("implicit section", 1, minLines, problem);
        }
        immutable uint reqBars = minLines == 0 ? 1 : (minLines + lpb - 1) / lpb;
        immutable SectionResult res = ensureImplicitSection(reqBars);
        if (!res.ok) {
            problem = res.problem;
            return false;
        }
        immutable uint targetLines = res.section.lines;
        foreach (ref entry; patterns_) {
            if (!entry.isRaw && entry.sectionIndex == implicitIndex_ && entry.grid.lines < targetLines) {
                NoteCell[] resized = new NoteCell[cast(size_t) entry.grid.tracks * targetLines];
                if (entry.grid.cells.length > 0) {
                    resized[0 .. entry.grid.cells.length] = entry.grid.cells[];
                }
                entry.grid.lines = targetLines;
                entry.grid.cells = resized;
            }
        }
        return true;
    }

    /**
     * Reports whether an implicit section has been created.
     *
     * Returns:
     *   True when the implicit section exists.
     */
    bool hasImplicitSection() const @safe nothrow {
        return implicitIndex_ != size_t.max;
    }

    /**
     * Returns how many explicit (named) sections have been declared.
     *
     * Returns:
     *   Explicit section count.
     */
    size_t sectionCount() const @safe nothrow {
        size_t count = 0;
        foreach (ref s; sections_) {
            if (!s.isImplicit) {
                count++;
            }
        }
        return count;
    }

    /**
     * Lists explicit section names in declaration order.
     *
     * Returns:
     *   Array of section names.
     */
    string[] sectionNames() const @safe nothrow {
        string[] names;
        foreach (ref s; sections_) {
            if (!s.isImplicit) {
                names ~= s.name;
            }
        }
        return names;
    }

    /**
     * Reports whether a named section exists, matched without regard to case or spaces.
     *
     * Params:
     *   name = Section name to look for.
     *
     * Returns:
     *   True when found.
     */
    bool hasSection(string name) const @safe nothrow {
        return indexOfSection(name) != sections_.length;
    }

    /**
     * Looks up a named section without regard to case or spaces.
     *
     * Params:
     *   name = Section name to look for.
     *
     * Returns:
     *   SectionInfo, or unknownSection with the nearest declared section name.
     */
    SectionResult sectionOf(string name) const @safe nothrow {
        immutable size_t idx = indexOfSection(name);
        if (idx == sections_.length) {
            return SectionResult(SectionInfo.init, false, unknownSectionProblem(name));
        }
        immutable uint lpb = linesPerBar(project_.timeSignature());
        immutable ulong total = cast(ulong) sections_[idx].bars * cast(ulong) lpb;
        immutable uint clampedLines = total > MAX_LINES ? MAX_LINES : cast(uint) total;
        return SectionResult(SectionInfo(sections_[idx].name, sections_[idx].bars, clampedLines, false), true);
    }

    /**
     * Declares a part bound to one module handle of the attached ProjectWriter.
     *
     * Params:
     *   name = Part name (non-empty after trimming, at most MAX_PART_NAME_LENGTH bytes).
     *   moduleHandle = Module handle in the attached ProjectWriter (matched case/space-insensitively).
     *
     * Returns:
     *   PartInfo, or invalidName, duplicatePart or unknownModule with the nearest handle.
     */
    PartResult addPart(string name, string moduleHandle) @safe nothrow {
        immutable string clean = trim(name);
        PartProblem nameProb;
        if (!checkName("part", name, clean, nameProb)) {
            return PartResult(PartInfo.init, false, nameProb);
        }
        if (indexOfPart(clean) != parts_.length) {
            return PartResult(PartInfo.init, false, PartProblem(PartProblemKind.duplicatePart, clean,
                "there is already a part '" ~ clean ~ "'", freePartName(clean)));
        }
        immutable ProjectIdResult modRes = project_.moduleId(moduleHandle);
        if (!modRes.ok) {
            return PartResult(PartInfo.init, false, PartProblem(PartProblemKind.unknownModule, moduleHandle,
                modRes.problem.reason, modRes.problem.suggestion));
        }
        string canonicalHandle = moduleHandle;
        foreach (h; project_.handles()) {
            if (namesMatch(h, moduleHandle)) {
                canonicalHandle = h;
                break;
            }
        }
        parts_ ~= PartEntry(clean, canonicalHandle, modRes.id);
        return PartResult(PartInfo(clean, canonicalHandle, modRes.id), true);
    }

    /**
     * Returns how many parts have been declared.
     *
     * Returns:
     *   Part count.
     */
    size_t partCount() const @safe nothrow {
        return parts_.length;
    }

    /**
     * Lists part names in declaration order.
     *
     * Returns:
     *   Array of part names.
     */
    string[] partNames() const @safe nothrow {
        string[] names;
        foreach (ref p; parts_) {
            names ~= p.name;
        }
        return names;
    }

    /**
     * Reports whether a part exists, matched without regard to case or spaces.
     *
     * Params:
     *   name = Part name to look for.
     *
     * Returns:
     *   True when found.
     */
    bool hasPart(string name) const @safe nothrow {
        return indexOfPart(name) != parts_.length;
    }

    /**
     * Looks up a part without regard to case or spaces.
     *
     * Params:
     *   name = Part name to look for.
     *
     * Returns:
     *   PartInfo, or unknownPart with the nearest declared part name.
     */
    PartResult partOf(string name) const @safe nothrow {
        immutable size_t idx = indexOfPart(name);
        if (idx == parts_.length) {
            return PartResult(PartInfo.init, false, unknownPartProblem(name));
        }
        return PartResult(PartInfo(parts_[idx].name, parts_[idx].moduleHandle, parts_[idx].moduleId), true);
    }

    /**
     * Returns the pattern for a (part, section) pair, creating it on first use.
     *
     * When sectionName is empty and no named sections have been declared (or an implicit section already
     * exists), uses the implicit section (creating it with 1 bar if needed). Two parts never share a pattern.
     *
     * Params:
     *   partName = Part name (matched without regard to case or spaces).
     *   sectionName = Section name, or "" for the implicit section.
     *
     * Returns:
     *   PartPatternInfo, or unknownPart, unknownSection, sectionTooLong or tooManyPatterns.
     */
    PartPatternResult patternFor(string partName, string sectionName = "") @safe nothrow {
        immutable size_t pIdx = indexOfPart(partName);
        if (pIdx == parts_.length) {
            return PartPatternResult(PartPatternInfo.init, false, unknownPartProblem(partName));
        }

        size_t sIdx = sections_.length;
        immutable string cleanSec = trim(sectionName);
        if (cleanSec.length == 0) {
            if (implicitIndex_ != size_t.max) {
                sIdx = implicitIndex_;
            } else if (sectionCount() == 0) {
                immutable SectionResult imp = ensureImplicitSection(1);
                if (!imp.ok) {
                    return PartPatternResult(PartPatternInfo.init, false, imp.problem);
                }
                sIdx = implicitIndex_;
            } else {
                return PartPatternResult(PartPatternInfo.init, false, unknownSectionProblem(sectionName));
            }
        } else {
            sIdx = indexOfSection(cleanSec);
            if (sIdx == sections_.length) {
                return PartPatternResult(PartPatternInfo.init, false, unknownSectionProblem(sectionName));
            }
        }

        immutable size_t existing = indexOfPattern(pIdx, sIdx);
        if (existing != patterns_.length) {
            return PartPatternResult(patternInfoOf(patterns_[existing]), true);
        }

        immutable size_t drumCount = attachedDrums_ !is null ? attachedDrums_.patternCount() : 0;
        if (patterns_.length + drumCount >= MAX_PATTERNS) {
            return PartPatternResult(PartPatternInfo.init, false, PartProblem(PartProblemKind.tooManyPatterns,
                parts_[pIdx].name, "a project holds at most " ~ wholeText(MAX_PATTERNS) ~ " patterns", ""));
        }

        PartProblem barProb;
        uint lineCount = 0;
        immutable string secLabel = sections_[sIdx].isImplicit ? "implicit section" : sections_[sIdx].name;
        if (!checkSectionBars(secLabel, sections_[sIdx].bars, lineCount, barProb)) {
            return PartPatternResult(PartPatternInfo.init, false, barProb);
        }

        immutable uint patId = reservePatternId();
        immutable string patName = formatPartPatternName(parts_[pIdx].name, sections_[sIdx].name,
            sections_[sIdx].isImplicit);
        PatternGrid grid = PatternGrid(1, lineCount, new NoteCell[lineCount]);
        patterns_ ~= PatternEntry(patId, pIdx, sIdx, patName, grid);
        return PartPatternResult(patternInfoOf(patterns_[$ - 1]), true);
    }

    /**
     * Reports whether a pattern has already been created for a (part, section) pair.
     *
     * Params:
     *   partName = Part name.
     *   sectionName = Section name, or "" for the implicit section.
     *
     * Returns:
     *   True when the pattern already exists.
     */
    bool hasPattern(string partName, string sectionName = "") const @safe nothrow {
        immutable size_t pIdx = indexOfPart(partName);
        if (pIdx == parts_.length) {
            return false;
        }
        size_t sIdx = sections_.length;
        immutable string cleanSec = trim(sectionName);
        if (cleanSec.length == 0) {
            sIdx = implicitIndex_;
        } else {
            sIdx = indexOfSection(cleanSec);
        }
        if (sIdx >= sections_.length) {
            return false;
        }
        return indexOfPattern(pIdx, sIdx) != patterns_.length;
    }

    /**
     * Returns how many patterns have been created so far.
     *
     * Returns:
     *   Pattern count.
     */
    size_t patternCount() const @safe nothrow {
        return patterns_.length;
    }

    /**
     * Lists metadata for every created pattern in creation order.
     *
     * Returns:
     *   Array of PartPatternInfo.
     */
    PartPatternInfo[] patterns() const @safe nothrow {
        PartPatternInfo[] list;
        list.reserve(patterns_.length);
        foreach (ref entry; patterns_) {
            list ~= patternInfoOf(entry);
        }
        return list;
    }

    /**
     * Exports every created pattern as a SavedPattern ready for LoadedProject.
     *
     * Returns:
     *   Array of SavedPattern values in creation order.
     */
    SavedPattern[] savedPatterns() const @safe nothrow {
        SavedPattern[] result;
        result.reserve(patterns_.length);
        foreach (ref entry; patterns_) {
            SavedPattern pat;
            pat.patternId = entry.patternId;
            pat.tracks = entry.grid.tracks;
            pat.lines = entry.grid.lines;
            pat.name = entry.name;
            pat.kind = entry.kind;
            pat.cells = entry.grid.cells.dup;
            pat.lanes = entry.lanes.dup;
            result ~= pat;
        }
        return result;
    }

    /**
     * Returns a copy of a created pattern's PatternGrid by pattern id.
     *
     * Params:
     *   patternId = Pattern id from PartPatternInfo.
     *   grid = Receives an independent copy of the PatternGrid when found.
     *
     * Returns:
     *   True when the pattern id exists.
     */
    bool patternGrid(uint patternId, out PatternGrid grid) const @safe nothrow {
        foreach (ref entry; patterns_) {
            if (entry.patternId == patternId) {
                grid = entry.grid.dup();
                return true;
            }
        }
        return false;
    }

    /**
     * Returns a mutable pointer to a pattern's PatternGrid for sibling compose note/chord writers.
     *
     * Params:
     *   patternId = Pattern id from PartPatternInfo.
     *
     * Returns:
     *   Pointer to the live PatternGrid, or null when the id does not exist.
     */
    package PatternGrid* mutableGrid(uint patternId) @safe nothrow {
        foreach (ref entry; patterns_) {
            if (entry.patternId == patternId) {
                return &entry.grid;
            }
        }
        return null;
    }

    /**
     * Writes a single note for a part in a section (or the implicit section when sectionName is empty).
     *
     * Adds tracker tracks cleanly when voices overlap and records a note-off on end via app.pattern_notes.
     * When using the implicit section, grows the implicit section if the note extends past its current bars.
     * Refuses notes that extend past an explicit section with the last position that fits.
     *
     * Params:
     *   partName = Part name (matched case/space-insensitively).
     *   sectionName = Section name, or "" for the implicit section.
     *   pos = BeatPosition counted from the start of the section.
     *   len = Note length.
     *   pitch = MIDI pitch [0, 127].
     *   velocity = Normalized note velocity in (0, 1].
     *
     * Returns:
     *   ok, or a structured PartProblem.
     */
    PartEditResult writeNote(string partName, string sectionName, BeatPosition pos, Length len, ubyte pitch,
            float velocity = DEFAULT_NOTE_VELOCITY) @safe nothrow {
        if (pitch > 127) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidPitch, "pitch",
                "MIDI pitch must be between 0 and 127", "60"));
        }
        if (!isFinite(velocity) || velocity <= 0.0f || velocity > 1.0f) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidVelocity, "velocity",
                "note velocity must be a finite number in (0, 1]", "0.8"));
        }
        if (len.lines == 0) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidLength, "length",
                "note length must be at least 1 line", "1l"));
        }
        immutable TimeSignature sig = project_.timeSignature();
        immutable LinesResult lineRes = positionToLine(pos, sig);
        if (!lineRes.ok) {
            return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange, formatPosition(pos),
                lineRes.error.reason, lineRes.error.suggestion));
        }
        immutable PartPatternResult patRes = patternFor(partName, sectionName);
        if (!patRes.ok) {
            return PartEditResult(false, patRes.problem);
        }
        immutable ulong endLine = cast(ulong) lineRes.lines + cast(ulong) len.lines;
        if (patRes.pattern.isImplicitSection && endLine > patRes.pattern.lines) {
            if (endLine > MAX_LINES) {
                immutable string suggestion = len.lines <= MAX_LINES
                    ? formatPosition(lineToPosition(cast(uint)(MAX_LINES - len.lines), sig).position) : "1";
                return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange, formatPosition(pos),
                    "note ends past the maximum pattern length (" ~ wholeText(MAX_LINES) ~ " lines)",
                    suggestion));
            }
            PartProblem growProb;
            if (!growImplicitSectionToLines(cast(uint) endLine, growProb)) {
                return PartEditResult(false, growProb);
            }
        } else if (endLine > patRes.pattern.lines) {
            immutable string suggestion = len.lines <= patRes.pattern.lines
                ? formatPosition(lineToPosition(patRes.pattern.lines - len.lines, sig).position) : "1";
            return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange, formatPosition(pos),
                "note at " ~ formatPosition(pos) ~ " runs past the end of section '"
                ~ (patRes.pattern.isImplicitSection ? "implicit" : patRes.pattern.sectionName) ~ "'",
                suggestion));
        }

        immutable size_t patEntryIdx = indexOfPatternById(patRes.pattern.patternId);
        if (patEntryIdx == patterns_.length) {
            return PartEditResult(false, unknownPartProblem(partName));
        }
        RollNote placed;
        immutable NoteEdit edit = placePartNote(patterns_[patEntryIdx].grid,
            patterns_[patEntryIdx].handPlaced, cast(ushort) patRes.pattern.moduleId, pitch,
            lineRes.lines, len.lines, velocity, placed);
        if (edit != NoteEdit.ok) {
            return PartEditResult(false, mapNoteEditProblem(edit, formatPosition(pos)));
        }
        return PartEditResult(true);
    }

    /**
     * Atomically writes a sequence of NoteEvents (notes, chords, rests) starting at startPos into a
     * part's section pattern. If any event fails validation or overlaps, the pattern is left unchanged.
     *
     * Params:
     *   partName = Part name.
     *   sectionName = Section name, or "" for the implicit section.
     *   startPos = Starting BeatPosition inside the section.
     *   events = Note events produced by compose.script.notation.parseNotes().
     *
     * Returns:
     *   ok, or a structured PartProblem without mutating the pattern.
     */
    PartEditResult writeNotes(string partName, string sectionName, BeatPosition startPos,
            const(NoteEvent)[] events) @safe nothrow {
        immutable TimeSignature sig = project_.timeSignature();
        immutable LinesResult baseRes = positionToLine(startPos, sig);
        if (!baseRes.ok) {
            return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange, formatPosition(startPos),
                baseRes.error.reason, baseRes.error.suggestion));
        }
        immutable PartPatternResult patRes = patternFor(partName, sectionName);
        if (!patRes.ok) {
            return PartEditResult(false, patRes.problem);
        }
        immutable size_t patEntryIdx = indexOfPatternById(patRes.pattern.patternId);
        if (patEntryIdx == patterns_.length) {
            return PartEditResult(false, unknownPartProblem(partName));
        }
        PatternGrid* liveGrid = &patterns_[patEntryIdx].grid;

        ulong maxRequiredLine = liveGrid.lines;
        foreach (ref ev; events) {
            if (ev.length == 0) {
                return PartEditResult(false, PartProblem(PartProblemKind.invalidLength, "length",
                    "note length must be at least 1 line", "1l"));
            }
            if (ev.pitches.length > 0 && (!isFinite(ev.velocity) || ev.velocity <= 0.0f || ev.velocity > 1.0f)) {
                return PartEditResult(false, PartProblem(PartProblemKind.invalidVelocity, "velocity",
                    "note velocity must be a finite number in (0, 1]", "0.8"));
            }
            foreach (p; ev.pitches) {
                if (p > 127) {
                    return PartEditResult(false, PartProblem(PartProblemKind.invalidPitch, "pitch",
                        "MIDI pitch must be between 0 and 127", "60"));
                }
            }
            immutable ulong evStart = cast(ulong) baseRes.lines + cast(ulong) ev.offset;
            immutable ulong evEnd = evStart + cast(ulong) ev.length;
            if (ev.pitches.length > 0) {
                if (patRes.pattern.isImplicitSection) {
                    if (evEnd > MAX_LINES) {
                        immutable string suggestion = ev.length <= MAX_LINES
                            ? formatPosition(lineToPosition(cast(uint)(MAX_LINES - ev.length), sig).position) : "1";
                        return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange,
                            formatPosition(startPos),
                            "notes run past the maximum pattern length (" ~ wholeText(MAX_LINES) ~ " lines)",
                            suggestion));
                    }
                    if (evEnd > maxRequiredLine) {
                        maxRequiredLine = evEnd;
                    }
                } else if (evEnd > liveGrid.lines) {
                    immutable string suggestion = ev.length <= liveGrid.lines
                        ? formatPosition(lineToPosition(liveGrid.lines - ev.length, sig).position) : "1";
                    return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange,
                        formatPosition(lineToPosition(evStart < MAX_LINES ? cast(uint) evStart : MAX_LINES - 1, sig).position),
                        "note runs past the end of section '" ~ patRes.pattern.sectionName ~ "'",
                        suggestion));
                }
            }
        }

        uint targetLines = liveGrid.lines;
        if (patRes.pattern.isImplicitSection && maxRequiredLine > targetLines) {
            immutable uint lpb = linesPerBar(sig);
            immutable uint reqBars = cast(uint)((maxRequiredLine + lpb - 1) / lpb);
            targetLines = reqBars * lpb;
        }

        PatternGrid work = PatternGrid(liveGrid.tracks, targetLines,
            new NoteCell[cast(size_t) liveGrid.tracks * targetLines]);
        if (liveGrid.cells.length > 0) {
            work.cells[0 .. liveGrid.cells.length] = liveGrid.cells[];
        }

        foreach (ref ev; events) {
            if (ev.pitches.length == 0) {
                continue;
            }
            immutable uint line = baseRes.lines + ev.offset;
            foreach (p; ev.pitches) {
                RollNote placed;
                immutable NoteEdit edit = placePartNote(work, patterns_[patEntryIdx].handPlaced,
                    cast(ushort) patRes.pattern.moduleId, p, line, ev.length, ev.velocity, placed);
                if (edit != NoteEdit.ok) {
                    return PartEditResult(false, mapNoteEditProblem(edit,
                        formatPosition(lineToPosition(line, sig).position)));
                }
            }
        }

        if (patRes.pattern.isImplicitSection && targetLines > liveGrid.lines) {
            PartProblem growProb;
            if (!growImplicitSectionToLines(targetLines, growProb)) {
                return PartEditResult(false, growProb);
            }
        }
        *liveGrid = work;
        return PartEditResult(true);
    }

    /**
     * Adds a standalone tracker-level pattern (T80) not bound to a (part, section) pair.
     *
     * Params:
     *   name = Pattern name (1..MAX_PART_NAME_LENGTH bytes).
     *   tracks = Track count in 1..MAX_TRACKS.
     *   lines = Line count in 1..MAX_LINES.
     *
     * Returns:
     *   PartPatternResult with the created pattern info, or invalidName / invalidLength / tooManyPatterns.
     */
    PartPatternResult addRawPattern(string name, uint tracks, uint lines) @safe nothrow {
        immutable string clean = trim(name);
        PartProblem nameProb;
        if (!checkName("pattern", name, clean, nameProb)) {
            return PartPatternResult(PartPatternInfo.init, false, nameProb);
        }
        if (tracks == 0 || tracks > MAX_TRACKS) {
            return PartPatternResult(PartPatternInfo.init, false, PartProblem(PartProblemKind.tooManyTracks,
                "tracks", "pattern track count must be between 1 and " ~ wholeText(MAX_TRACKS),
                tracks == 0 ? "1" : wholeText(MAX_TRACKS)));
        }
        if (lines == 0 || lines > MAX_LINES) {
            return PartPatternResult(PartPatternInfo.init, false, PartProblem(PartProblemKind.invalidLength,
                "lines", "pattern line count must be between 1 and " ~ wholeText(MAX_LINES),
                lines == 0 ? "16" : wholeText(MAX_LINES)));
        }
        immutable size_t drumCount = attachedDrums_ !is null ? attachedDrums_.patternCount() : 0;
        if (patterns_.length + drumCount >= MAX_PATTERNS) {
            return PartPatternResult(PartPatternInfo.init, false, PartProblem(PartProblemKind.tooManyPatterns,
                clean, "a project holds at most " ~ wholeText(MAX_PATTERNS) ~ " patterns", ""));
        }
        immutable uint patId = reservePatternId();
        PatternGrid grid = PatternGrid(tracks, lines, new NoteCell[cast(size_t) tracks * lines]);
        patterns_ ~= PatternEntry(patId, size_t.max, size_t.max, clean, grid, true, PATTERN_KIND_NORMAL);
        return PartPatternResult(patternInfoOf(patterns_[$ - 1]), true);
    }

    /**
     * Looks up a pattern (part-owned or raw) by numeric patternId.
     *
     * Params:
     *   patternId = Numeric pattern id.
     *
     * Returns:
     *   PartPatternResult, or unknownPattern.
     */
    PartPatternResult patternById(uint patternId) const @safe nothrow {
        immutable size_t idx = indexOfPatternById(patternId);
        if (idx == patterns_.length) {
            return PartPatternResult(PartPatternInfo.init, false, PartProblem(PartProblemKind.unknownPattern,
                wholeText(patternId), "there is no pattern with id " ~ wholeText(patternId), ""));
        }
        return PartPatternResult(patternInfoOf(patterns_[idx]), true);
    }

    /**
     * Looks up a pattern (part-owned or raw) by name without regard to case or spaces.
     *
     * Params:
     *   name = Pattern name.
     *
     * Returns:
     *   PartPatternResult, or unknownPattern with nearest pattern name.
     */
    PartPatternResult patternByName(string name) const @safe nothrow {
        string[] names;
        names.reserve(patterns_.length);
        foreach (ref entry; patterns_) {
            names ~= entry.name;
            if (namesMatch(entry.name, name)) {
                return PartPatternResult(patternInfoOf(entry), true);
            }
        }
        return PartPatternResult(PartPatternInfo.init, false, PartProblem(PartProblemKind.unknownPattern,
            name, "there is no pattern '" ~ name ~ "'", nearestName(name, names)));
    }

    /**
     * Writes an exact tracker NoteCell at (track, line) of a pattern by id (T80), expanding tracks up
     * to MAX_TRACKS if needed and marking non-empty cells as hand-placed so part-level writes never
     * overwrite them.
     *
     * Params:
     *   patternId = Target pattern id.
     *   track = 0-based track index (< MAX_TRACKS).
     *   line = 0-based line index (< pattern lines).
     *   cell = Exact NoteCell to write.
     *
     * Returns:
     *   ok, or unknownPattern / tooManyTracks / positionOutOfRange / invalidCell / unknownModule.
     */
    PartEditResult writeCell(uint patternId, uint track, uint line, NoteCell cell) @safe nothrow {
        immutable size_t idx = indexOfPatternById(patternId);
        if (idx == patterns_.length) {
            return PartEditResult(false, PartProblem(PartProblemKind.unknownPattern, wholeText(patternId),
                "there is no pattern with id " ~ wholeText(patternId), ""));
        }
        if (track >= MAX_TRACKS) {
            return PartEditResult(false, PartProblem(PartProblemKind.tooManyTracks, wholeText(track),
                "track index must be below " ~ wholeText(MAX_TRACKS), wholeText(MAX_TRACKS - 1)));
        }
        if (line >= patterns_[idx].grid.lines) {
            immutable string sugg = patterns_[idx].grid.lines > 0 ? wholeText(patterns_[idx].grid.lines - 1) : "0";
            return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange, wholeText(line),
                "line " ~ wholeText(line) ~ " is outside pattern of length " ~ wholeText(patterns_[idx].grid.lines),
                sugg));
        }
        if (!isValidCellNoteByte(cell.note)) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidCell, wholeText(cell.note),
                "invalid tracker note command byte " ~ wholeText(cell.note), "0"));
        }
        if (cell.moduleId != 0 && !project_.hasModuleId(cell.moduleId)) {
            return PartEditResult(false, PartProblem(PartProblemKind.unknownModule, wholeText(cell.moduleId),
                "there is no module with id " ~ wholeText(cell.moduleId), ""));
        }
        while (patterns_[idx].grid.tracks <= track) {
            if (!patterns_[idx].grid.addTrack()) {
                return PartEditResult(false, PartProblem(PartProblemKind.tooManyTracks, wholeText(track),
                    "cannot add more than " ~ wholeText(ROLL_MAX_TRACKS) ~ " tracks", ""));
            }
        }
        patterns_[idx].grid.at(track, line) = cell;
        ulong key = cellKey(track, line);
        if (cell.isEmpty()) {
            patterns_[idx].handPlaced.remove(key);
        } else {
            patterns_[idx].handPlaced[key] = true;
        }
        return PartEditResult(true);
    }

    /**
     * Writes an exact tracker NoteCell at a BeatPosition inside a pattern by id.
     */
    PartEditResult writeCell(uint patternId, uint track, BeatPosition pos, NoteCell cell) @safe nothrow {
        immutable LinesResult lr = positionToLine(pos, project_.timeSignature());
        if (!lr.ok) {
            return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange, formatPosition(pos),
                lr.error.reason, lr.error.suggestion));
        }
        return writeCell(patternId, track, lr.lines, cell);
    }

    /**
     * Writes an exact tracker NoteCell at (track, line) of a part's section pattern (creating the
     * pattern on first use).
     */
    PartEditResult writeCell(string partName, string sectionName, uint track, uint line, NoteCell cell)
            @safe nothrow {
        immutable PartPatternResult patRes = patternFor(partName, sectionName);
        if (!patRes.ok) {
            return PartEditResult(false, patRes.problem);
        }
        return writeCell(patRes.pattern.patternId, track, line, cell);
    }

    /**
     * Writes an exact tracker NoteCell at (track, pos) of a part's section pattern (growing an implicit
     * section if needed).
     */
    PartEditResult writeCell(string partName, string sectionName, uint track, BeatPosition pos, NoteCell cell)
            @safe nothrow {
        immutable TimeSignature sig = project_.timeSignature();
        immutable LinesResult lr = positionToLine(pos, sig);
        if (!lr.ok) {
            return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange, formatPosition(pos),
                lr.error.reason, lr.error.suggestion));
        }
        immutable PartPatternResult patRes = patternFor(partName, sectionName);
        if (!patRes.ok) {
            return PartEditResult(false, patRes.problem);
        }
        if (patRes.pattern.isImplicitSection && lr.lines >= patRes.pattern.lines) {
            PartProblem growProb;
            if (!growImplicitSectionToLines(lr.lines + 1, growProb)) {
                return PartEditResult(false, growProb);
            }
        }
        return writeCell(patRes.pattern.patternId, track, lr.lines, cell);
    }

    /**
     * Writes a tracker parameter-automation NoteCell resolved by module handle, parameter name, and
     * parameter text value (numeric or discrete option name).
     *
     * Params:
     *   patternId = Target pattern id.
     *   track = 0-based track index.
     *   line = 0-based line index.
     *   moduleHandle = Target module handle.
     *   paramName = Parameter name on that module.
     *   valueText = Parameter value as numeric or option text.
     *   fx = Optional effect code byte (default 0).
     *
     * Returns:
     *   ok, or a structured PartProblem.
     */
    PartEditResult writeParamCell(uint patternId, uint track, uint line, string moduleHandle,
            string paramName, string valueText, ubyte fx = 0) @safe nothrow {
        auto modRes = project_.moduleOf(moduleHandle);
        if (!modRes.ok) {
            return PartEditResult(false, PartProblem(PartProblemKind.unknownModule, moduleHandle,
                modRes.problem.reason, modRes.problem.suggestion));
        }
        auto copy = modRes.writer;
        immutable auto edit = copy.setParamText(paramName, valueText);
        if (!edit.ok) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidCell, paramName,
                edit.problem.reason, edit.problem.suggestion));
        }
        auto desc = copy.descriptor();
        auto saved = copy.savedModule(modRes.id);
        size_t paramIdx = desc.params.length;
        foreach (i, ref p; desc.params) {
            if (namesMatch(p.name, paramName)) {
                paramIdx = i;
                break;
            }
        }
        if (paramIdx >= desc.params.length) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidCell, paramName,
                "unknown parameter '" ~ paramName ~ "'", ""));
        }
        immutable auto pdesc = desc.params[paramIdx];
        immutable float span = pdesc.maxVal - pdesc.minVal;
        immutable float norm = span > 0.0f ? (saved.paramValues[paramIdx] - pdesc.minVal) / span : 0.0f;
        return writeCell(patternId, track, line, NoteCell.makeParam(cast(ushort) modRes.id,
            cast(ushort) paramIdx, norm, fx));
    }

    /**
     * Reads one tracker NoteCell back by pattern id, track, and line.
     */
    CellResult cellAt(uint patternId, uint track, uint line) const @safe nothrow {
        immutable size_t idx = indexOfPatternById(patternId);
        if (idx == patterns_.length) {
            return CellResult(NoteCell.init, false, PartProblem(PartProblemKind.unknownPattern,
                wholeText(patternId), "there is no pattern with id " ~ wholeText(patternId), ""));
        }
        if (line >= patterns_[idx].grid.lines) {
            return CellResult(NoteCell.init, false, PartProblem(PartProblemKind.positionOutOfRange,
                wholeText(line), "line " ~ wholeText(line) ~ " is outside pattern", "0"));
        }
        if (track >= patterns_[idx].grid.tracks) {
            if (track >= MAX_TRACKS) {
                return CellResult(NoteCell.init, false, PartProblem(PartProblemKind.tooManyTracks,
                    wholeText(track), "track index exceeds limit", "0"));
            }
            return CellResult(NoteCell.init, true);
        }
        return CellResult(patterns_[idx].grid.at(track, line), true);
    }

    /**
     * Reads one tracker NoteCell back by part name, section name, track, and line.
     */
    CellResult cellAt(string partName, string sectionName, uint track, uint line) const @safe nothrow {
        immutable size_t pIdx = indexOfPart(partName);
        if (pIdx == parts_.length) {
            return CellResult(NoteCell.init, false, unknownPartProblem(partName));
        }
        immutable string cleanSec = trim(sectionName);
        immutable size_t sIdx = cleanSec.length == 0 ? implicitIndex_ : indexOfSection(cleanSec);
        if (sIdx >= sections_.length) {
            return CellResult(NoteCell.init, false, unknownSectionProblem(sectionName));
        }
        immutable size_t patIdx = indexOfPattern(pIdx, sIdx);
        if (patIdx == patterns_.length) {
            immutable uint lpb = linesPerBar(project_.timeSignature());
            if (line >= sections_[sIdx].bars * lpb || track >= MAX_TRACKS) {
                return CellResult(NoteCell.init, false, PartProblem(PartProblemKind.positionOutOfRange,
                    wholeText(line), "cell coordinate is outside the section pattern", "0"));
            }
            return CellResult(NoteCell.init, true);
        }
        return cellAt(patterns_[patIdx].patternId, track, line);
    }

    /**
     * Reads one tracker NoteCell back by part name, section name, track, and BeatPosition.
     */
    CellResult cellAt(string partName, string sectionName, uint track, BeatPosition pos) const @safe nothrow {
        immutable LinesResult lr = positionToLine(pos, project_.timeSignature());
        if (!lr.ok) {
            return CellResult(NoteCell.init, false, PartProblem(PartProblemKind.positionOutOfRange,
                formatPosition(pos), lr.error.reason, lr.error.suggestion));
        }
        return cellAt(partName, sectionName, track, lr.lines);
    }

    /**
     * Reports whether a cell at (track, line) was hand-placed via writeCell() (T80).
     */
    bool isHandPlaced(uint patternId, uint track, uint line) const @safe nothrow {
        immutable size_t idx = indexOfPatternById(patternId);
        if (idx == patterns_.length) {
            return false;
        }
        return (cellKey(track, line) in patterns_[idx].handPlaced) !is null;
    }

    /**
     * Copies notes inside [srcStart, srcStart + rangeLen) of srcPart in srcSection to dstStart of
     * dstPart in dstSection (T81). Refuses ranges that cross the end of an explicit section or overlap
     * existing destination notes cleanly without mutating the destination pattern.
     */
    PartEditResult copyRange(string srcPart, string srcSection, BeatPosition srcStart, Length rangeLen,
            string dstPart, string dstSection, BeatPosition dstStart) @safe nothrow {
        size_t srcP = 0;
        size_t srcS = 0;
        uint srcStartLine = 0;
        uint srcEndLine = 0;
        PartProblem prob;
        if (!resolvePhraseRange(srcPart, srcSection, srcStart, rangeLen, false, srcP, srcS, srcStartLine,
                srcEndLine, prob)) {
            return PartEditResult(false, prob);
        }

        immutable TimeSignature sig = project_.timeSignature();
        immutable LinesResult dstBase = positionToLine(dstStart, sig);
        if (!dstBase.ok) {
            return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange, formatPosition(dstStart),
                dstBase.error.reason, dstBase.error.suggestion));
        }
        immutable PartPatternResult dstPatRes = patternFor(dstPart, dstSection);
        if (!dstPatRes.ok) {
            return PartEditResult(false, dstPatRes.problem);
        }
        immutable size_t dstPatEntry = indexOfPatternById(dstPatRes.pattern.patternId);
        if (dstPatEntry == patterns_.length) {
            return PartEditResult(false, unknownPartProblem(dstPart));
        }
        immutable ulong dstEndLine = cast(ulong) dstBase.lines + cast(ulong) rangeLen.lines;
        if (dstPatRes.pattern.isImplicitSection) {
            if (dstEndLine > MAX_LINES) {
                return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange, formatPosition(dstStart),
                    "copied range runs past the maximum pattern length (" ~ wholeText(MAX_LINES) ~ " lines)", "1"));
            }
        } else if (dstEndLine > dstPatRes.pattern.lines) {
            immutable string sugg = rangeLen.lines <= dstPatRes.pattern.lines
                ? formatPosition(lineToPosition(dstPatRes.pattern.lines - rangeLen.lines, sig).position) : "1";
            return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange, formatPosition(dstStart),
                "copied range runs past the end of section '" ~ dstPatRes.pattern.sectionName ~ "'", sugg));
        }

        const(RollNote)[] srcNotes;
        immutable size_t srcPatEntry = indexOfPattern(srcP, srcS);
        if (srcPatEntry != patterns_.length) {
            foreach (ref rn; notesOf(patterns_[srcPatEntry].grid)) {
                if (rn.line >= srcStartLine && rn.line < srcEndLine) {
                    srcNotes ~= rn;
                }
            }
        }

        uint targetLines = patterns_[dstPatEntry].grid.lines;
        if (dstPatRes.pattern.isImplicitSection && dstEndLine > targetLines) {
            immutable uint lpb = linesPerBar(sig);
            immutable uint reqBars = cast(uint)((dstEndLine + lpb - 1) / lpb);
            targetLines = reqBars * lpb;
        }
        PatternGrid work = PatternGrid(patterns_[dstPatEntry].grid.tracks, targetLines,
            new NoteCell[cast(size_t) patterns_[dstPatEntry].grid.tracks * targetLines]);
        if (patterns_[dstPatEntry].grid.cells.length > 0) {
            work.cells[0 .. patterns_[dstPatEntry].grid.cells.length] = patterns_[dstPatEntry].grid.cells[];
        }

        foreach (ref rn; srcNotes) {
            immutable uint relLine = rn.line - srcStartLine;
            immutable uint maxClipped = srcEndLine - rn.line;
            immutable uint noteLen = rn.length < maxClipped ? rn.length : maxClipped;
            immutable uint targetLine = dstBase.lines + relLine;
            RollNote placed;
            immutable NoteEdit edit = placePartNote(work, patterns_[dstPatEntry].handPlaced,
                cast(ushort) dstPatRes.pattern.moduleId, rn.pitch, targetLine, noteLen, rn.velocity, placed);
            if (edit != NoteEdit.ok) {
                return PartEditResult(false, mapNoteEditProblem(edit,
                    formatPosition(lineToPosition(targetLine, sig).position)));
            }
        }

        if (dstPatRes.pattern.isImplicitSection && targetLines > patterns_[dstPatEntry].grid.lines) {
            PartProblem growProb;
            if (!growImplicitSectionToLines(targetLines, growProb)) {
                return PartEditResult(false, growProb);
            }
        }
        patterns_[dstPatEntry].grid = work;
        return PartEditResult(true);
    }

    /**
     * Repeats the notes in [startPos, startPos + rangeLen) consecutively `times` additional times
     * immediately following the source range (T81).
     */
    PartEditResult repeatRange(string partName, string sectionName, BeatPosition startPos, Length rangeLen,
            uint times) @safe nothrow {
        if (times == 0) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidRepeatCount, "times",
                "repeat count must be at least 1", "1"));
        }
        size_t pIdx = 0;
        size_t sIdx = 0;
        uint startLine = 0;
        uint endLine = 0;
        PartProblem prob;
        if (!resolvePhraseRange(partName, sectionName, startPos, rangeLen, false, pIdx, sIdx, startLine,
                endLine, prob)) {
            return PartEditResult(false, prob);
        }

        immutable TimeSignature sig = project_.timeSignature();
        immutable ulong span = cast(ulong) rangeLen.lines;
        immutable ulong totalEnd = cast(ulong) startLine + (cast(ulong) times + 1) * span;
        immutable bool isImp = sections_[sIdx].isImplicit;
        immutable uint secLines = sections_[sIdx].bars * linesPerBar(sig);
        if (isImp) {
            if (totalEnd > MAX_LINES) {
                return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange,
                    formatPosition(startPos),
                    "repeated range exceeds maximum pattern length (" ~ wholeText(MAX_LINES) ~ " lines)", "1"));
            }
        } else if (totalEnd > secLines) {
            immutable ulong fit = secLines > startLine + span ? (secLines - startLine - span) / span : 0;
            immutable string sugg = fit > 0 ? wholeText(fit) : "1";
            return PartEditResult(false, PartProblem(PartProblemKind.positionOutOfRange,
                formatPosition(startPos),
                "repeating range " ~ wholeText(times) ~ " times runs past the end of section '"
                ~ sections_[sIdx].name ~ "'", sugg));
        }

        immutable size_t patIdx = indexOfPattern(pIdx, sIdx);
        if (patIdx == patterns_.length) {
            return PartEditResult(true);
        }
        NoteEvent[] captured;
        foreach (ref rn; notesOf(patterns_[patIdx].grid)) {
            if (rn.line >= startLine && rn.line < endLine) {
                immutable uint maxClipped = endLine - rn.line;
                immutable uint noteLen = rn.length < maxClipped ? rn.length : maxClipped;
                captured ~= NoteEvent(rn.line - startLine, noteLen, [rn.pitch], rn.velocity);
            }
        }
        if (captured.length == 0) {
            if (isImp && totalEnd > patterns_[patIdx].grid.lines) {
                PartProblem growProb;
                if (!growImplicitSectionToLines(cast(uint) totalEnd, growProb)) {
                    return PartEditResult(false, growProb);
                }
            }
            return PartEditResult(true);
        }

        uint targetLines = patterns_[patIdx].grid.lines;
        if (isImp && totalEnd > targetLines) {
            immutable uint lpb = linesPerBar(sig);
            immutable uint reqBars = cast(uint)((totalEnd + lpb - 1) / lpb);
            targetLines = reqBars * lpb;
        }
        PatternGrid work = PatternGrid(patterns_[patIdx].grid.tracks, targetLines,
            new NoteCell[cast(size_t) patterns_[patIdx].grid.tracks * targetLines]);
        if (patterns_[patIdx].grid.cells.length > 0) {
            work.cells[0 .. patterns_[patIdx].grid.cells.length] = patterns_[patIdx].grid.cells[];
        }
        foreach (rep; 1 .. times + 1) {
            immutable uint copyBase = startLine + rep * rangeLen.lines;
            foreach (ref ev; captured) {
                RollNote placed;
                immutable uint ln = copyBase + ev.offset;
                immutable NoteEdit edit = placePartNote(work, patterns_[patIdx].handPlaced,
                    cast(ushort) parts_[pIdx].moduleId, ev.pitches[0], ln, ev.length, ev.velocity, placed);
                if (edit != NoteEdit.ok) {
                    return PartEditResult(false, mapNoteEditProblem(edit,
                        formatPosition(lineToPosition(ln, sig).position)));
                }
            }
        }

        if (isImp && targetLines > patterns_[patIdx].grid.lines) {
            PartProblem growProb;
            if (!growImplicitSectionToLines(targetLines, growProb)) {
                return PartEditResult(false, growProb);
            }
        }
        patterns_[patIdx].grid = work;
        return PartEditResult(true);
    }

    /**
     * Transposes all notes starting in [startPos, startPos + rangeLen) by `semitones` (T81).
     * Refuses atomically if the range crosses the section end or any transposed pitch falls outside 0..127.
     */
    PartEditResult transposeRange(string partName, string sectionName, BeatPosition startPos, Length rangeLen,
            int semitones) @safe nothrow {
        size_t pIdx = 0;
        size_t sIdx = 0;
        uint startLine = 0;
        uint endLine = 0;
        PartProblem prob;
        if (!resolvePhraseRange(partName, sectionName, startPos, rangeLen, false, pIdx, sIdx, startLine,
                endLine, prob)) {
            return PartEditResult(false, prob);
        }
        if (semitones == 0) {
            return PartEditResult(true);
        }
        immutable size_t patIdx = indexOfPattern(pIdx, sIdx);
        if (patIdx == patterns_.length) {
            return PartEditResult(true);
        }
        return transposeSelectedNotes(patIdx, pIdx, startLine, endLine, semitones, false);
    }

    /**
     * Transposes all notes starting in [startPos, startPos + rangeLen) by `scaleSteps` diatonic scale
     * steps in the project's key (T81). Preserves chromatic alterations relative to the scale degree.
     */
    PartEditResult transposeRangeScaleSteps(string partName, string sectionName, BeatPosition startPos,
            Length rangeLen, int scaleSteps) @safe nothrow {
        size_t pIdx = 0;
        size_t sIdx = 0;
        uint startLine = 0;
        uint endLine = 0;
        PartProblem prob;
        if (!resolvePhraseRange(partName, sectionName, startPos, rangeLen, false, pIdx, sIdx, startLine,
                endLine, prob)) {
            return PartEditResult(false, prob);
        }
        if (scaleSteps == 0) {
            return PartEditResult(true);
        }
        immutable size_t patIdx = indexOfPattern(pIdx, sIdx);
        if (patIdx == patterns_.length) {
            return PartEditResult(true);
        }
        return transposeSelectedNotes(patIdx, pIdx, startLine, endLine, scaleSteps, true);
    }

    /**
     * Multiplies velocities of all notes starting inside [startPos, startPos + rangeLen) by `factor`,
     * clamping to [1/254, 1.0] (T81).
     */
    PartEditResult scaleVelocities(string partName, string sectionName, BeatPosition startPos, Length rangeLen,
            float factor) @safe nothrow {
        if (!isFinite(factor) || factor <= 0.0f) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidVelocity, "factor",
                "velocity scale factor must be a finite number greater than 0", "1.0"));
        }
        size_t pIdx = 0;
        size_t sIdx = 0;
        uint startLine = 0;
        uint endLine = 0;
        PartProblem prob;
        if (!resolvePhraseRange(partName, sectionName, startPos, rangeLen, false, pIdx, sIdx, startLine,
                endLine, prob)) {
            return PartEditResult(false, prob);
        }
        immutable size_t patIdx = indexOfPattern(pIdx, sIdx);
        if (patIdx == patterns_.length) {
            return PartEditResult(true);
        }
        PatternGrid work = patterns_[patIdx].grid.dup();
        foreach (ref rn; notesOf(work)) {
            if (rn.line >= startLine && rn.line < endLine) {
                float scaled = rn.velocity * factor;
                if (scaled < (1.0f / 254.0f)) {
                    scaled = 1.0f / 254.0f;
                } else if (scaled > 1.0f) {
                    scaled = 1.0f;
                }
                cast(void) setNoteVelocity(work, rn, scaled);
            }
        }
        patterns_[patIdx].grid = work;
        return PartEditResult(true);
    }

    /**
     * Clears all notes starting inside [startPos, startPos + rangeLen) (and any hand-placed cells in
     * those lines) from a part's section pattern (T81).
     */
    PartEditResult clearRange(string partName, string sectionName, BeatPosition startPos, Length rangeLen)
            @safe nothrow {
        size_t pIdx = 0;
        size_t sIdx = 0;
        uint startLine = 0;
        uint endLine = 0;
        PartProblem prob;
        if (!resolvePhraseRange(partName, sectionName, startPos, rangeLen, false, pIdx, sIdx, startLine,
                endLine, prob)) {
            return PartEditResult(false, prob);
        }
        immutable size_t patIdx = indexOfPattern(pIdx, sIdx);
        if (patIdx == patterns_.length) {
            return PartEditResult(true);
        }
        PatternGrid work = patterns_[patIdx].grid.dup();
        RollNote[] doomed;
        foreach (ref rn; notesOf(work)) {
            if (rn.line >= startLine && rn.line < endLine) {
                doomed ~= rn;
            }
        }
        if (doomed.length > 0) {
            immutable NoteEdit del = deleteNotes(work, doomed);
            if (del != NoteEdit.ok) {
                return PartEditResult(false, mapNoteEditProblem(del, formatPosition(startPos)));
            }
        }
        ulong[] clearedKeys;
        foreach (k, _; patterns_[patIdx].handPlaced) {
            immutable uint ln = cast(uint)(k & 0xFFFFFFFFuL);
            immutable uint tr = cast(uint)(k >> 32);
            if (ln >= startLine && ln < endLine) {
                clearedKeys ~= k;
                if (tr < work.tracks && ln < work.lines) {
                    work.at(tr, ln) = NoteCell.init;
                }
            }
        }
        foreach (k; clearedKeys) {
            patterns_[patIdx].handPlaced.remove(k);
        }
        patterns_[patIdx].grid = work;
        return PartEditResult(true);
    }

    /**
     * Reads back every note stored in a part's section pattern.
     *
     * Params:
     *   partName = Part name.
     *   sectionName = Section name, or "" for the implicit section.
     *
     * Returns:
     *   Array of PartNote values ordered by track then line (empty if the pattern does not exist yet).
     */
    PartNote[] notesOfPart(string partName, string sectionName = "") const @safe nothrow {
        immutable size_t pIdx = indexOfPart(partName);
        if (pIdx == parts_.length) {
            return null;
        }
        immutable string cleanSec = trim(sectionName);
        immutable size_t sIdx = cleanSec.length == 0 ? implicitIndex_ : indexOfSection(cleanSec);
        if (sIdx >= sections_.length) {
            return null;
        }
        immutable size_t patIdx = indexOfPattern(pIdx, sIdx);
        if (patIdx == patterns_.length) {
            return null;
        }
        immutable TimeSignature sig = project_.timeSignature();
        RollNote[] raw = notesOf(patterns_[patIdx].grid);
        PartNote[] result;
        result.reserve(raw.length);
        foreach (ref rn; raw) {
            immutable PositionResult posRes = lineToPosition(rn.line, sig);
            result ~= PartNote(posRes.position, rn.line, rn.length, rn.pitch, rn.velocity, rn.track);
        }
        return result;
    }

    /**
     * Sets the song arrangement as an ordered sequence of declared sections (per T68/T98).
     * Calling arrange() again replaces the previous arrangement.
     *
     * Params:
     *   sectionList = Ordered section names.
     *
     * Returns:
     *   ok, or invalidArrangement / unknownSection with the nearest declared section name.
     */
    PartEditResult arrange(const(string)[] sectionList) @safe nothrow {
        if (sectionList.length == 0) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidArrangement, "arrange",
                "an arrangement needs at least one section", sectionNames().length > 0 ? sectionNames()[0] : ""));
        }
        size_t[] nextIndices;
        nextIndices.reserve(sectionList.length);
        foreach (secName; sectionList) {
            immutable size_t sIdx = indexOfSection(secName);
            if (sIdx == sections_.length) {
                return PartEditResult(false, unknownSectionProblem(secName));
            }
            nextIndices ~= sIdx;
        }
        arrangedSectionIndices_ = nextIndices;
        hasPreservedClips_ = false;
        return PartEditResult(true);
    }

    /**
     * Appends an explicit raw TimelineClip (preserving non-canonical clip offsets, lanes, or muted
     * clips when opening or describing existing .msv files — T107).
     *
     * Params:
     *   patternId = Existing pattern id (in this PartWriter or its attached DrumWriter).
     *   startLine = Timeline start line (>= 0).
     *   lengthLines = Clip length in lines (>= 1).
     *   laneY = Timeline track lane (>= 0).
     *   patternOffset = Pattern start offset in lines.
     *   mute = Clip mute flag.
     *   solo = Clip solo flag.
     *   isSupertrack = Clip supertrack flag.
     *
     * Returns:
     *   ok, or unknownPattern / invalidArrangement.
     */
    PartEditResult addRawClip(uint patternId, long startLine, uint lengthLines, uint laneY,
            uint patternOffset = 0, bool mute = false, bool solo = false, bool isSupertrack = false)
            @safe nothrow {
        if (!hasAnyPatternId(patternId)) {
            return PartEditResult(false, PartProblem(PartProblemKind.unknownPattern, wholeText(patternId),
                "there is no pattern with id " ~ wholeText(patternId), ""));
        }
        if (startLine < 0 || lengthLines == 0) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidArrangement, "clip",
                "timeline clip start must be >= 0 and length must be at least 1 line", "0"));
        }
        uint maxId = 0;
        foreach (ref cl; preservedClips_) {
            if (cl.clipId > maxId) {
                maxId = cl.clipId;
            }
        }
        uint cloneId = 0;
        foreach (ref cl; preservedClips_) {
            if (cl.patternId == patternId && cl.cloneSourceId == 0) {
                cloneId = cl.clipId;
                break;
            }
        }
        preservedClips_ ~= TimelineClip(maxId + 1, patternId, cloneId, startLine, lengthLines, laneY,
            patternOffset, mute, solo, isSupertrack);
        hasPreservedClips_ = true;
        originalPatternIds_[patternId] = true;
        return PartEditResult(true);
    }

    /** Reports whether preserved raw timeline clips are active. */
    package bool hasPreservedClips() const @safe nothrow {
        return hasPreservedClips_;
    }

    /** Returns preserved raw timeline clips in order. */
    package const(TimelineClip)[] preservedClips() const @safe nothrow {
        return preservedClips_;
    }

    /** Returns preserved loop start line. */
    package long preservedLoopStart() const @safe nothrow {
        return preservedLoopStart_;
    }

    /** Returns preserved loop end line. */
    package long preservedLoopEnd() const @safe nothrow {
        return preservedLoopEnd_;
    }

    /** Reports whether patternId belongs to a raw tracker pattern in this PartWriter. */
    package bool isRawPatternId(uint patId) const @safe nothrow {
        immutable size_t idx = indexOfPatternById(patId);
        return idx < patterns_.length && patterns_[idx].isRaw;
    }

    /**
     * Lists the arranged section names in order.
     *
     * Returns:
     *   Array of section names.
     */
    string[] arrangement() const @safe nothrow {
        string[] names;
        names.reserve(arrangedSectionIndices_.length);
        foreach (sIdx; arrangedSectionIndices_) {
            names ~= sections_[sIdx].name;
        }
        return names;
    }

    /**
     * Returns the ordered section indices in the active arrangement (or implicit section if unarranged).
     *
     * Returns:
     *   Array of indices into sections_.
     */
    package bool hasArrangement() const @safe nothrow {
        return arrangedSectionIndices_.length > 0;
    }

    /**
     * Returns the ordered section indices in the active arrangement (or implicit section if unarranged).
     *
     * Returns:
     *   Array of indices into sections_.
     */
    package size_t[] activeSectionSequence() const @safe nothrow {
        if (arrangedSectionIndices_.length > 0) {
            return arrangedSectionIndices_.dup;
        }
        if (implicitIndex_ != size_t.max) {
            return [implicitIndex_];
        }
        return null;
    }

    /**
     * Sets a custom loop covering a slice of occurrences in the arrangement [startIdx .. endIdxExclusive].
     *
     * Params:
     *   startIdx = 0-based start occurrence index in the arrangement.
     *   endIdxExclusive = Exclusive end occurrence index (must be > startIdx and <= arrangement.length).
     *
     * Returns:
     *   ok, or invalidLoop.
     */
    PartEditResult setLoopSections(size_t startIdx, size_t endIdxExclusive) @safe nothrow {
        const(size_t)[] seq = activeSectionSequence();
        if (seq.length == 0) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidLoop, "loop",
                "cannot set a section loop before sections are arranged", ""));
        }
        if (startIdx >= endIdxExclusive || endIdxExclusive > seq.length) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidLoop, "loop",
                "loop section range is outside the arrangement of " ~ wholeText(seq.length) ~ " sections",
                "0"));
        }
        immutable uint lpb = linesPerBar(project_.timeSignature());
        long startLine = 0;
        foreach (i; 0 .. startIdx) {
            startLine += cast(long) sections_[seq[i]].bars * lpb;
        }
        long endLine = startLine;
        foreach (i; startIdx .. endIdxExclusive) {
            endLine += cast(long) sections_[seq[i]].bars * lpb;
        }
        customLoopStart_ = startLine;
        customLoopEnd_ = endLine;
        hasCustomLoop_ = true;
        return PartEditResult(true);
    }

    /**
     * Sets an explicit timeline loop range in lines.
     *
     * Params:
     *   startLine = Loop start line (>= 0).
     *   endLine = Loop end line (> startLine).
     *
     * Returns:
     *   ok, or invalidLoop.
     */
    PartEditResult setLoopLines(long startLine, long endLine) @safe nothrow {
        if (startLine < 0 || endLine <= startLine) {
            return PartEditResult(false, PartProblem(PartProblemKind.invalidLoop, "loop",
                "loop start must be >= 0 and loop end must be greater than loop start", "0"));
        }
        customLoopStart_ = startLine;
        customLoopEnd_ = endLine;
        hasCustomLoop_ = true;
        return PartEditResult(true);
    }

    /**
     * Restores the default whole-arrangement loop behavior.
     */
    void clearLoop() @safe nothrow {
        hasCustomLoop_ = false;
        customLoopStart_ = 0;
        customLoopEnd_ = 0;
    }

    /**
     * Returns the total length in lines of the active arrangement (or implicit section).
     *
     * Returns:
     *   Total arrangement length in lines.
     */
    long arrangementLengthLines() const @safe nothrow {
        immutable uint lpb = linesPerBar(project_.timeSignature());
        const(size_t)[] seq = activeSectionSequence();
        long total = 0;
        foreach (sIdx; seq) {
            total += cast(long) sections_[sIdx].bars * lpb;
        }
        return total;
    }

    /**
     * Returns the active loop start line (0 when defaulting to the full arrangement).
     *
     * Returns:
     *   Loop start line.
     */
    long loopStartLine() const @safe nothrow {
        return hasCustomLoop_ ? customLoopStart_ : 0;
    }

    /**
     * Returns the active loop end line (total arrangement length when no custom loop is set).
     *
     * Returns:
     *   Loop end line.
     */
    long loopEndLine() const @safe nothrow {
        return hasCustomLoop_ ? customLoopEnd_ : arrangementLengthLines();
    }

    /**
     * Builds the timeline clips for all parts across the active arrangement: one lane per part,
     * repeated sections reusing the same patternId as clone clips, and gaps where a part has no pattern.
     *
     * Params:
     *   firstClipId = Starting clip id (default 1).
     *
     * Returns:
     *   Ordered TimelineClip array.
     */
    TimelineClip[] arrangementClips(uint firstClipId = 1) const @safe nothrow {
        const(size_t)[] seq = activeSectionSequence();
        if (seq.length == 0) {
            return null;
        }
        immutable uint lpb = linesPerBar(project_.timeSignature());
        TimelineClip[] clips;
        uint[uint] firstClipByPat;
        long cursor = 0;
        uint nextId = firstClipId;
        foreach (sIdx; seq) {
            foreach (pIdx; 0 .. parts_.length) {
                immutable size_t patIdx = indexOfPattern(pIdx, sIdx);
                if (patIdx != patterns_.length) {
                    immutable uint patId = patterns_[patIdx].patternId;
                    immutable uint len = patterns_[patIdx].grid.lines;
                    uint cloneId = 0;
                    if (auto prev = patId in firstClipByPat) {
                        cloneId = *prev;
                    } else {
                        firstClipByPat[patId] = nextId;
                    }
                    clips ~= TimelineClip(nextId++, patId, cloneId, cursor, len, cast(uint) pIdx,
                        0, false, false, false);
                }
            }
            cursor += cast(long) sections_[sIdx].bars * lpb;
        }
        return clips;
    }

    /**
     * Reconstructs parts, sections, drum parts, and arrangement from an opened ProjectWriter (T100).
     *
     * Patterns whose cells all name one valid module become that module's part in a named (or implicit)
     * section; drum patterns become drum parts; unrecognized patterns stay accessible at tracker level.
     * Existing clips reconstruct arrangedSectionIndices_ when they match arrange() output, and otherwise
     * remain preserved verbatim until arrange() is called.
     *
     * Params:
     *   project = ProjectWriter opened via fromLoadedProject/fromBytes/fromFile.
     *
     * Returns:
     *   PartOpenResult containing populated PartWriter, DrumWriter, pattern mappings, and arrangement flag.
     */
    static PartOpenResult openFromProject(ProjectWriter project) @safe nothrow {
        if (project is null) {
            return PartOpenResult(null, null, null, false, false, PartProblem(PartProblemKind.unknownModule,
                "", "a project writer is required", ""));
        }
        PartWriter pw = new PartWriter(project);
        DrumWriter dw = new DrumWriter(pw);
        pw.attachDrums(dw);

        if (!project.hasPreservedBase()) {
            return PartOpenResult(pw, dw, null, false, true);
        }

        LoadedProject base = project.preservedBaseDocument();
        immutable TimeSignature sig = project.timeSignature();
        immutable uint lpb = linesPerBar(sig);

        uint maxPatId = 0;
        bool anySeparator = false;
        bool allSameLines = base.patterns.length > 0;
        immutable uint firstLines = base.patterns.length > 0 ? base.patterns[0].lines : 0;
        foreach (ref sp; base.patterns) {
            if (sp.patternId > maxPatId) {
                maxPatId = sp.patternId;
            }
            pw.originalPatternIds_[sp.patternId] = true;
            if (findSubstring(sp.name, PATTERN_NAME_SEPARATOR) != sp.name.length) {
                anySeparator = true;
            }
            if (sp.lines != firstLines) {
                allSameLines = false;
            }
        }
        pw.nextPatternId_ = maxPatId + 1;

        bool singleImplicitCandidate = !anySeparator && allSameLines && lpb > 0 && firstLines > 0
            && (firstLines % lpb == 0) && base.clips.length == base.patterns.length
            && base.patterns.length > 0;
        if (singleImplicitCandidate) {
            foreach (ref sp; base.patterns) {
                if (trim(sp.name).length == 0 || !project.hasModule(trim(sp.name))) {
                    singleImplicitCandidate = false;
                    break;
                }
            }
            foreach (ref cl; base.clips) {
                if (cl.startLine != 0 || cl.patternOffset != 0 || cl.mute || cl.solo || cl.isSupertrack
                        || cl.lengthLines != firstLines) {
                    singleImplicitCandidate = false;
                    break;
                }
            }
        }

        OpenedPatternMapping[] mappings;
        mappings.reserve(base.patterns.length);

        foreach (ref sp; base.patterns) {
            if (sp.kind == PATTERN_KIND_DRUM) {
                bool lanesValid = lpb > 0 && sp.lines > 0 && (sp.lines % lpb == 0) && sp.lanes.length > 0;
                if (lanesValid) {
                    foreach (ref sl; sp.lanes) {
                        if (!project.hasModuleId(sl.moduleId)) {
                            lanesValid = false;
                            break;
                        }
                    }
                }
                if (lanesValid) {
                    immutable uint bars = sp.lines / lpb;
                    string candPart = "drums";
                    string candSec = trim(sp.name).length > 0 ? trim(sp.name) : "section";
                    immutable size_t sepIdx = findSubstring(sp.name, PATTERN_NAME_SEPARATOR);
                    bool useImp = false;
                    if (sepIdx != sp.name.length) {
                        candPart = trim(sp.name[0 .. sepIdx]);
                        candSec = trim(sp.name[sepIdx + PATTERN_NAME_SEPARATOR.length .. $]);
                        if (candPart.length == 0) {
                            candPart = "drums";
                        }
                        if (candSec.length == 0) {
                            candSec = "section";
                        }
                    } else if (singleImplicitCandidate) {
                        useImp = true;
                        candPart = trim(sp.name);
                    } else {
                        immutable uint firstMod = sp.lanes[0].moduleId;
                        bool sameMod = true;
                        foreach (ref sl; sp.lanes[1 .. $]) {
                            if (sl.moduleId != firstMod) {
                                sameMod = false;
                                break;
                            }
                        }
                        if (sameMod && project.handleForId(firstMod).length > 0) {
                            candPart = project.handleForId(firstMod);
                        }
                    }

                    size_t sIdx = 0;
                    if (useImp) {
                        pw.ensureImplicitSection(bars);
                        sIdx = pw.implicitIndex_;
                    } else {
                        sIdx = pw.ensureOpenedSection(candSec, bars);
                    }
                    string assignedDrumPart;
                    cast(void) dw.importDrumPattern(candPart, sIdx, sp, assignedDrumPart);
                    mappings ~= OpenedPatternMapping(sp.patternId, sp.name, true, true, assignedDrumPart,
                        pw.sections_[sIdx].name);
                    continue;
                }
                PatternGrid rawGrid = PatternGrid(sp.tracks, sp.lines, sp.cells.dup);
                pw.patterns_ ~= PatternEntry(sp.patternId, size_t.max, size_t.max, sp.name, rawGrid,
                    true, sp.kind, sp.lanes.dup);
                mappings ~= OpenedPatternMapping(sp.patternId, sp.name, false, true, "", "");
                continue;
            }

            uint singleModId = 0;
            immutable size_t sepIdx = findSubstring(sp.name, PATTERN_NAME_SEPARATOR);
            immutable bool hasSep = sepIdx != sp.name.length;
            string candPart;
            string candSec;
            bool useImp = false;
            if (hasSep) {
                candPart = trim(sp.name[0 .. sepIdx]);
                candSec = trim(sp.name[sepIdx + PATTERN_NAME_SEPARATOR.length .. $]);
            }

            immutable size_t distinctMods = analyzePatternModules(sp, project, singleModId);
            bool fitsPart = lpb > 0 && sp.lines > 0 && (sp.lines % lpb == 0) && sp.tracks > 0;
            if (fitsPart) {
                if (distinctMods == 1) {
                    immutable string modHandle = project.handleForId(singleModId);
                    if (!hasSep) {
                        if (singleImplicitCandidate) {
                            useImp = true;
                            candPart = trim(sp.name);
                            candSec = "";
                        } else {
                            candPart = modHandle.length > 0 ? modHandle : "part";
                            candSec = trim(sp.name).length > 0 ? trim(sp.name) : "section";
                        }
                    }
                } else if (distinctMods == 0 && hasSep && project.hasModule(candPart)) {
                    immutable auto modIdRes = project.moduleId(candPart);
                    singleModId = modIdRes.ok ? modIdRes.id : 0;
                    if (singleModId == 0) {
                        fitsPart = false;
                    }
                } else {
                    fitsPart = false;
                }
            }

            if (fitsPart) {
                immutable uint bars = sp.lines / lpb;
                immutable size_t sIdx = useImp
                    ? (pw.ensureImplicitSection(bars).ok ? pw.implicitIndex_ : 0)
                    : pw.ensureOpenedSection(candSec, bars);
                immutable size_t pIdx = pw.ensureOpenedPart(candPart, singleModId, sIdx);
                PatternGrid grid = PatternGrid(sp.tracks, sp.lines, sp.cells.dup);
                pw.patterns_ ~= PatternEntry(sp.patternId, pIdx, sIdx, sp.name, grid, false,
                    PATTERN_KIND_NORMAL);
                mappings ~= OpenedPatternMapping(sp.patternId, sp.name, true, false, pw.parts_[pIdx].name,
                    pw.sections_[sIdx].name);
            } else {
                PatternGrid rawGrid = PatternGrid(sp.tracks, sp.lines, sp.cells.dup);
                pw.patterns_ ~= PatternEntry(sp.patternId, size_t.max, size_t.max, sp.name, rawGrid,
                    true, sp.kind, sp.lanes.dup);
                mappings ~= OpenedPatternMapping(sp.patternId, sp.name, false, false, "", "");
            }
        }

        size_t[] reconstructedSeq;
        bool isImplicitSingle = false;
        if (pw.tryReconstructArrangement(dw, base, mappings, lpb, reconstructedSeq, isImplicitSingle)) {
            if (!isImplicitSingle) {
                pw.arrangedSectionIndices_ = reconstructedSeq;
            }
            pw.hasPreservedClips_ = false;
            if (base.loopEndLine > base.loopStartLine
                    && (base.loopStartLine != 0 || base.loopEndLine != pw.arrangementLengthLines())) {
                cast(void) pw.setLoopLines(base.loopStartLine, base.loopEndLine);
            }
            return PartOpenResult(pw, dw, mappings, true, true);
        }

        pw.hasPreservedClips_ = true;
        pw.preservedClips_ = base.clips.dup;
        pw.preservedLoopStart_ = base.loopStartLine;
        pw.preservedLoopEnd_ = base.loopEndLine;
        return PartOpenResult(pw, dw, mappings, false, true);
    }

    /**
     * Combines the attached ProjectWriter's properties/modules/wires with this PartWriter's
     * patterns, arranged clips, and loop range, validating through validateProjectForSave().
     *
     * Returns:
     *   ProjectDocumentResult ready for serialization or saving.
     */
    ProjectDocumentResult buildDocument() const @safe nothrow {
        return buildDocument(attachedDrums_);
    }

    /**
     * Combines the attached ProjectWriter's properties/modules/wires with this PartWriter's patterns
     * and the given DrumWriter's drum patterns into one validated LoadedProject document.
     *
     * Params:
     *   drums = Attached or explicit DrumWriter (may be null).
     *
     * Returns:
     *   ProjectDocumentResult ready for serialization or saving.
     */
    package ProjectDocumentResult buildDocument(const DrumWriter drums) const @safe nothrow {
        ProjectDocumentResult result = project_.document();
        if (!result.ok) {
            return result;
        }
        immutable size_t drumPatCount = drums !is null ? drums.patternCount() : 0;
        immutable bool hasMusic = patterns_.length > 0 || arrangedSectionIndices_.length > 0
            || hasCustomLoop_ || hasPreservedClips_ || drumPatCount > 0;
        if (!hasMusic) {
            return result;
        }

        SavedPattern[] allPats = savedPatterns();
        bool[uint] usedIds;
        uint maxId = 0;
        foreach (ref sp; allPats) {
            usedIds[sp.patternId] = true;
            if (sp.patternId > maxId) {
                maxId = sp.patternId;
            }
        }
        DrumExportEntry[] drumExports;
        if (drums !is null) {
            drumExports = drums.exportPatterns(maxId + 1, usedIds);
            foreach (ref de; drumExports) {
                allPats ~= de.pattern;
            }
        }

        result.project.patterns = allPats;

        immutable uint lpb = linesPerBar(project_.timeSignature());
        if (hasPreservedClips_) {
            TimelineClip[] clips = preservedClips_.dup;
            uint maxClipId = 0;
            uint nextLane = 0;
            bool[long][size_t] secStartLines;
            foreach (ref cl; clips) {
                if (cl.clipId > maxClipId) {
                    maxClipId = cl.clipId;
                }
                if (cl.laneY + 1 > nextLane) {
                    nextLane = cl.laneY + 1;
                }
                size_t secIdx = size_t.max;
                if (findSectionForPatternId(cl.patternId, drumExports, secIdx)) {
                    secStartLines[secIdx][cl.startLine] = true;
                }
            }
            uint nextClipId = maxClipId + 1;
            uint[size_t] melodicLaneByPart;
            uint[size_t] drumLaneByPart;

            foreach (ref entry; patterns_) {
                if (!entry.isRaw && (entry.patternId in originalPatternIds_) is null) {
                    uint lane = 0;
                    if (auto existing = entry.partIndex in melodicLaneByPart) {
                        lane = *existing;
                    } else {
                        lane = nextLane++;
                        melodicLaneByPart[entry.partIndex] = lane;
                    }
                    appendNewClipsForPattern(clips, nextClipId, entry.patternId, entry.grid.lines,
                        lane, entry.sectionIndex, secStartLines);
                }
            }
            foreach (ref de; drumExports) {
                if ((de.patternId in originalPatternIds_) is null) {
                    uint lane = 0;
                    if (auto existing = de.partIndex in drumLaneByPart) {
                        lane = *existing;
                    } else {
                        lane = nextLane++;
                        drumLaneByPart[de.partIndex] = lane;
                    }
                    appendNewClipsForPattern(clips, nextClipId, de.patternId, de.pattern.lines,
                        lane, de.sectionIndex, secStartLines);
                }
            }

            result.project.clips = clips;
            if (hasCustomLoop_) {
                result.project.loopStartLine = customLoopStart_;
                result.project.loopEndLine = customLoopEnd_;
            } else {
                result.project.loopStartLine = preservedLoopStart_;
                result.project.loopEndLine = preservedLoopEnd_;
            }
        } else {
            const(size_t)[] seq = activeSectionSequence();
            TimelineClip[] clips;
            if (seq.length > 0) {
                uint[uint] firstClipByPat;
                long cursor = 0;
                uint nextClipId = 1;
                immutable uint baseDrumLane = cast(uint) parts_.length;
                foreach (sIdx; seq) {
                    foreach (pIdx; 0 .. parts_.length) {
                        immutable size_t patIdx = indexOfPattern(pIdx, sIdx);
                        if (patIdx != patterns_.length) {
                            immutable uint patId = patterns_[patIdx].patternId;
                            immutable uint len = patterns_[patIdx].grid.lines;
                            uint cloneId = 0;
                            if (auto prev = patId in firstClipByPat) {
                                cloneId = *prev;
                            } else {
                                firstClipByPat[patId] = nextClipId;
                            }
                            clips ~= TimelineClip(nextClipId++, patId, cloneId, cursor, len,
                                cast(uint) pIdx, 0, false, false, false);
                        }
                    }
                    if (drums !is null) {
                        foreach (dpIdx; 0 .. drums.drumPartCount()) {
                            foreach (ref de; drumExports) {
                                if (de.partIndex == dpIdx && de.sectionIndex == sIdx) {
                                    uint cloneId = 0;
                                    if (auto prev = de.patternId in firstClipByPat) {
                                        cloneId = *prev;
                                    } else {
                                        firstClipByPat[de.patternId] = nextClipId;
                                    }
                                    clips ~= TimelineClip(nextClipId++, de.patternId, cloneId, cursor,
                                        de.pattern.lines, baseDrumLane + cast(uint) dpIdx,
                                        0, false, false, false);
                                    break;
                                }
                            }
                        }
                    }
                    cursor += cast(long) sections_[sIdx].bars * lpb;
                }
            }
            result.project.clips = clips;
            result.project.loopStartLine = loopStartLine();
            result.project.loopEndLine = loopEndLine();
        }

        string err;
        if (!validateProjectForSave(result.project, err)) {
            result.ok = false;
            result.problem = ProjectProblem(ProjectProblemKind.invalidProject, result.project.title,
                "the project cannot be saved: " ~ err, "");
            return result;
        }
        return result;
    }

    /**
     * Looks up a section's index and bar count by name (or implicit section when clean is empty) for
     * sibling compose writers such as DrumWriter.
     *
     * Params:
     *   sectionName = Section name or "" for implicit.
     *   sIdx = Receives index in sections_.
     *   bars = Receives bar count.
     *   lines = Receives current line count.
     *   isImplicit = Receives whether this is the implicit section.
     *   problem = Receives PartProblem on lookup/creation failure.
     *
     * Returns:
     *   True when resolved.
     */
    package bool resolveSectionForWrite(string sectionName, out size_t sIdx, out uint bars, out uint lines,
            out bool isImplicit, out PartProblem problem) @safe nothrow {
        immutable string cleanSec = trim(sectionName);
        if (cleanSec.length == 0) {
            if (implicitIndex_ != size_t.max) {
                sIdx = implicitIndex_;
            } else if (sectionCount() == 0) {
                immutable SectionResult imp = ensureImplicitSection(1);
                if (!imp.ok) {
                    problem = imp.problem;
                    return false;
                }
                sIdx = implicitIndex_;
            } else {
                problem = unknownSectionProblem(sectionName);
                return false;
            }
        } else {
            sIdx = indexOfSection(cleanSec);
            if (sIdx == sections_.length) {
                problem = unknownSectionProblem(sectionName);
                return false;
            }
        }
        bars = sections_[sIdx].bars;
        isImplicit = sections_[sIdx].isImplicit;
        immutable uint lpb = linesPerBar(project_.timeSignature());
        lines = bars * lpb;
        return true;
    }

    /**
     * Returns the bar count of section sIdx for sibling compose writers.
     *
     * Params:
     *   sIdx = Index returned by resolveSectionForWrite or activeSectionSequence.
     *
     * Returns:
     *   Bars of that section, or 0 if out of bounds.
     */
    package uint sectionBarsAt(size_t sIdx) const @safe nothrow {
        return sIdx < sections_.length ? sections_[sIdx].bars : 0;
    }

    /**
     * Maps NoteEdit failures from app.pattern_notes into PartProblem values.
     *
     * Params:
     *   edit = Failed NoteEdit code.
     *   subject = Formatted BeatPosition of the offending note.
     *
     * Returns:
     *   Corresponding PartProblem.
     */
    private static PartProblem mapNoteEditProblem(NoteEdit edit, string subject) @safe pure nothrow {
        final switch (edit) {
            case NoteEdit.ok:
                return PartProblem.init;
            case NoteEdit.notFound:
                return PartProblem(PartProblemKind.unknownPart, subject, "target note was not found", "");
            case NoteEdit.outOfRange:
                return PartProblem(PartProblemKind.positionOutOfRange, subject,
                    "note at " ~ subject ~ " is out of range", "");
            case NoteEdit.samePitchOverlap:
                return PartProblem(PartProblemKind.noteOverlap, subject,
                    "another note of the same pitch already sounds at " ~ subject, "");
            case NoteEdit.noFreeTrack:
                return PartProblem(PartProblemKind.tooManyTracks, subject,
                    "too many simultaneous notes at " ~ subject ~ " (limit is 64 tracks)", "");
        }
    }

    /**
     * Validates a section or part name.
     *
     * Params:
     *   kindLabel = "section" or "part".
     *   raw = Original input string.
     *   clean = Trimmed input string.
     *   problem = Receives invalidName when rejected.
     *
     * Returns:
     *   True when valid.
     */
    private static bool checkName(string kindLabel, string raw, string clean, out PartProblem problem)
            @safe pure nothrow {
        if (clean.length == 0) {
            problem = PartProblem(PartProblemKind.invalidName, raw,
                "a " ~ kindLabel ~ " name cannot be empty", kindLabel);
            return false;
        }
        if (clean.length > MAX_PART_NAME_LENGTH) {
            problem = PartProblem(PartProblemKind.invalidName, raw,
                "a " ~ kindLabel ~ " name is at most " ~ wholeText(MAX_PART_NAME_LENGTH) ~ " bytes long",
                clean[0 .. MAX_PART_NAME_LENGTH]);
            return false;
        }
        return true;
    }

    /**
     * Checks that a section's bar length produces a valid pattern line count (1..MAX_LINES) in the
     * attached project's current time signature.
     *
     * Params:
     *   label = Section name for error reporting.
     *   bars = Section length in bars.
     *   lineCount = Receives bars * linesPerBar when valid.
     *   problem = Receives invalidBars or sectionTooLong when rejected.
     *
     * Returns:
     *   True when valid.
     */
    private bool checkSectionBars(string label, uint bars, out uint lineCount, out PartProblem problem)
            const @safe nothrow {
        if (bars == 0) {
            problem = PartProblem(PartProblemKind.invalidBars, label,
                "section '" ~ label ~ "' must be at least 1 bar long", "1");
            return false;
        }
        immutable uint lpb = linesPerBar(project_.timeSignature());
        immutable ulong total = cast(ulong) bars * cast(ulong) lpb;
        if (total > MAX_LINES) {
            immutable uint maxBars = MAX_LINES / lpb;
            problem = PartProblem(PartProblemKind.sectionTooLong, label,
                "section '" ~ label ~ "' (" ~ wholeText(bars) ~ " bars, " ~ wholeText(total)
                ~ " lines) exceeds the maximum pattern length of " ~ wholeText(MAX_LINES) ~ " lines",
                wholeText(maxBars));
            return false;
        }
        lineCount = cast(uint) total;
        return true;
    }

    /**
     * Finds an explicit section index by name without regard to case or spaces.
     *
     * Params:
     *   name = Section name.
     *
     * Returns:
     *   Index into sections_, or sections_.length when not found.
     */
    private size_t indexOfSection(string name) const @safe nothrow {
        if (trim(name).length == 0) {
            return sections_.length;
        }
        foreach (i; 0 .. sections_.length) {
            if (!sections_[i].isImplicit && namesMatch(sections_[i].name, name)) {
                return i;
            }
        }
        return sections_.length;
    }

    /**
     * Finds a part index by name without regard to case or spaces.
     *
     * Params:
     *   name = Part name.
     *
     * Returns:
     *   Index into parts_, or parts_.length when not found.
     */
    private size_t indexOfPart(string name) const @safe nothrow {
        if (trim(name).length == 0) {
            return parts_.length;
        }
        foreach (i; 0 .. parts_.length) {
            if (namesMatch(parts_[i].name, name)) {
                return i;
            }
        }
        return parts_.length;
    }

    /**
     * Finds an existing pattern entry for (partIndex, sectionIndex).
     *
     * Params:
     *   partIndex = Index into parts_.
     *   sectionIndex = Index into sections_.
     *
     * Returns:
     *   Index into patterns_, or patterns_.length when not yet created.
     */
    private size_t indexOfPattern(size_t partIndex, size_t sectionIndex) const @safe nothrow {
        foreach (i; 0 .. patterns_.length) {
            if (!patterns_[i].isRaw && patterns_[i].partIndex == partIndex
                    && patterns_[i].sectionIndex == sectionIndex) {
                return i;
            }
        }
        return patterns_.length;
    }

    /**
     * Builds PartPatternInfo from a PatternEntry.
     *
     * Params:
     *   entry = Stored pattern entry.
     *
     * Returns:
     *   Public PartPatternInfo snapshot.
     */
    private PartPatternInfo patternInfoOf(const ref PatternEntry entry) const @safe nothrow {
        if (entry.isRaw) {
            return PartPatternInfo(entry.patternId, entry.name, "", "", 0, entry.grid.tracks,
                entry.grid.lines, false);
        }
        immutable auto part = parts_[entry.partIndex];
        immutable auto sec = sections_[entry.sectionIndex];
        return PartPatternInfo(entry.patternId, entry.name, part.name, sec.name, part.moduleId,
            entry.grid.tracks, entry.grid.lines, sec.isImplicit);
    }

    /**
     * Builds an unknownSection problem with the nearest declared section name.
     *
     * Params:
     *   name = Requested section name.
     *
     * Returns:
     *   PartProblem.
     */
    private PartProblem unknownSectionProblem(string name) const @safe nothrow {
        const(string)[] names = sectionNames();
        immutable string suggestion = trim(name).length == 0
            ? (names.length > 0 ? names[0] : "")
            : nearestName(name, names);
        return PartProblem(PartProblemKind.unknownSection, name,
            "there is no section '" ~ name ~ "'", suggestion);
    }

    /**
     * Builds an unknownPart problem with the nearest declared part name.
     *
     * Params:
     *   name = Requested part name.
     *
     * Returns:
     *   PartProblem.
     */
    private PartProblem unknownPartProblem(string name) const @safe nothrow {
        return PartProblem(PartProblemKind.unknownPart, name,
            "there is no part '" ~ name ~ "'", nearestName(name, partNames()));
    }

    /**
     * Finds a free numbered section name when a duplicate is attempted.
     *
     * Params:
     *   stem = Base section name.
     *
     * Returns:
     *   Free name such as "verse2".
     */
    private string freeSectionName(string stem) const @safe nothrow {
        foreach (n; 2 .. MAX_PATTERNS + 2) {
            immutable string digits = wholeText(n);
            immutable string base = stem.length + digits.length > MAX_PART_NAME_LENGTH
                ? stem[0 .. MAX_PART_NAME_LENGTH - digits.length] : stem;
            if (indexOfSection(base ~ digits) == sections_.length) {
                return base ~ digits;
            }
        }
        return "";
    }

    /**
     * Finds a free numbered part name when a duplicate is attempted.
     *
     * Params:
     *   stem = Base part name.
     *
     * Returns:
     *   Free name such as "bass2".
     */
    private string freePartName(string stem) const @safe nothrow {
        foreach (n; 2 .. MAX_PATTERNS + 2) {
            immutable string digits = wholeText(n);
            immutable string base = stem.length + digits.length > MAX_PART_NAME_LENGTH
                ? stem[0 .. MAX_PART_NAME_LENGTH - digits.length] : stem;
            if (indexOfPart(base ~ digits) == parts_.length) {
                return base ~ digits;
            }
        }
        return "";
    }

    private uint reservePatternId() @safe nothrow {
        while (indexOfPatternById(nextPatternId_) != patterns_.length
                || (attachedDrums_ !is null && attachedDrums_.hasFixedPatternId(nextPatternId_))) {
            nextPatternId_++;
        }
        immutable uint id = nextPatternId_;
        nextPatternId_++;
        return id;
    }

    private bool hasAnyPatternId(uint patId) const @safe nothrow {
        if (indexOfPatternById(patId) != patterns_.length) {
            return true;
        }
        if (attachedDrums_ !is null) {
            if (attachedDrums_.hasFixedPatternId(patId)) {
                return true;
            }
            bool[uint] used;
            uint maxId = 0;
            foreach (ref p; patterns_) {
                used[p.patternId] = true;
                if (p.patternId > maxId) {
                    maxId = p.patternId;
                }
            }
            foreach (ref de; attachedDrums_.exportPatterns(maxId + 1, used)) {
                if (de.patternId == patId) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * Resolves a pattern id by case/space-insensitive pattern name across both melodic/raw
     * patterns and any attached drum patterns.
     *
     * Params:
     *   name = Pattern name to look for.
     *
     * Returns:
     *   Matching patternId, or 0 when not found.
     */
    package uint findPatternIdByName(string name) const @safe nothrow {
        foreach (ref entry; patterns_) {
            if (namesMatch(entry.name, name)) {
                return entry.patternId;
            }
        }
        if (attachedDrums_ !is null) {
            bool[uint] used;
            uint maxId = 0;
            foreach (ref p; patterns_) {
                used[p.patternId] = true;
                if (p.patternId > maxId) {
                    maxId = p.patternId;
                }
            }
            foreach (ref de; attachedDrums_.exportPatterns(maxId + 1, used)) {
                if (namesMatch(de.pattern.name, name)) {
                    return de.patternId;
                }
            }
        }
        return 0;
    }

    private size_t indexOfPatternById(uint patternId) const @safe nothrow {
        foreach (i, ref entry; patterns_) {
            if (entry.patternId == patternId) {
                return i;
            }
        }
        return patterns_.length;
    }

    private static ulong cellKey(uint track, uint line) @safe pure nothrow @nogc {
        return (cast(ulong) track << 32) | cast(ulong) line;
    }

    private static bool isValidCellNoteByte(ubyte note) @safe pure nothrow @nogc {
        return note == 0 || (note >= 1 && note <= 128)
            || (note >= NoteCmd.noteOff && note <= NoteCmd.stopSong);
    }

    private static bool isGridNote(const ref NoteCell c) @safe pure nothrow @nogc {
        return c.note >= 1 && c.note <= 128;
    }

    private static bool isGridStop(const ref NoteCell c) @safe pure nothrow @nogc {
        return c.note >= 240;
    }

    private static ushort gridModuleAt(const ref PatternGrid g, uint track, uint line) @safe pure nothrow @nogc {
        ushort active = 0;
        foreach (ln; 0 .. line + 1) {
            if (g.at(track, ln).moduleId != 0) {
                active = g.at(track, ln).moduleId;
            }
        }
        return active;
    }

    private static bool gridSoundingBefore(const ref PatternGrid g, uint track, uint line) @safe pure nothrow @nogc {
        foreach_reverse (ln; 0 .. line) {
            immutable NoteCell c = g.at(track, ln);
            if (isGridStop(c)) {
                return false;
            }
            if (isGridNote(c)) {
                return gridModuleAt(g, track, ln) != 0;
            }
        }
        return false;
    }

    private static void gridPinFollowing(ref PatternGrid g, uint track, uint line) @safe pure nothrow @nogc {
        foreach (ln; line + 1 .. g.lines) {
            if (g.at(track, ln).moduleId != 0) {
                return;
            }
            if (isGridNote(g.at(track, ln))) {
                immutable ushort m = gridModuleAt(g, track, ln);
                if (m != 0) {
                    g.at(track, ln).moduleId = m;
                }
                return;
            }
        }
    }

    private static bool gridTrackHasNotes(const ref PatternGrid g, uint track) @safe pure nothrow @nogc {
        foreach (ln; 0 .. g.lines) {
            if (isGridNote(g.at(track, ln))) {
                return true;
            }
        }
        return false;
    }

    private static bool gridTrackOnlyModule(const ref PatternGrid g, uint track, ushort moduleId)
            @safe pure nothrow @nogc {
        ushort active = 0;
        bool any = false;
        foreach (ln; 0 .. g.lines) {
            immutable NoteCell c = g.at(track, ln);
            if (c.moduleId != 0) {
                active = c.moduleId;
            }
            if (isGridNote(c)) {
                if (active != moduleId) {
                    return false;
                }
                any = true;
            }
        }
        return any;
    }

    private static bool gridRangeFreeForPart(const ref PatternGrid g, const ref bool[ulong] handPlaced,
            uint track, ushort moduleId, uint line, uint end) @safe pure nothrow {
        if ((cellKey(track, line) in handPlaced) !is null) {
            return false;
        }
        if (end < g.lines && g.at(track, end).note == 0 && (cellKey(track, end) in handPlaced) !is null) {
            return false;
        }
        immutable NoteCell first = g.at(track, line);
        if (isGridNote(first)) {
            return false;
        }
        foreach (ln; line + 1 .. end) {
            if (g.at(track, ln).note != 0) {
                return false;
            }
            if ((cellKey(track, ln) in handPlaced) !is null) {
                immutable NoteCell hc = g.at(track, ln);
                if (hc.moduleId != 0 && hc.moduleId != moduleId) {
                    return false;
                }
            }
        }
        return isGridStop(first) || !gridSoundingBefore(g, track, line);
    }

    private static NoteEdit placePartNote(ref PatternGrid grid, const ref bool[ulong] handPlaced,
            ushort moduleId, ubyte pitch, uint line, uint length, float velocity, out RollNote placed)
            @safe pure nothrow {
        if (handPlaced.length == 0) {
            return addNote(grid, moduleId, pitch, line, length, velocity, placed);
        }
        if (moduleId == 0 || line >= grid.lines || length == 0) {
            return NoteEdit.outOfRange;
        }
        PatternGrid w = grid.dup();
        immutable uint end = cast(ulong) line + length > w.lines ? w.lines : line + length;
        foreach (ref other; notesOf(w)) {
            if (other.moduleId == moduleId && other.pitch == pitch && other.line < end
                    && line < other.line + other.length) {
                return NoteEdit.samePitchOverlap;
            }
        }

        uint track = uint.max;
        foreach (t; 0 .. w.tracks) {
            if (gridTrackOnlyModule(w, t, moduleId) && gridRangeFreeForPart(w, handPlaced, t, moduleId, line, end)) {
                track = t;
                break;
            }
        }
        if (track == uint.max) {
            foreach (t; 0 .. w.tracks) {
                if (!gridTrackHasNotes(w, t) && gridRangeFreeForPart(w, handPlaced, t, moduleId, line, end)) {
                    track = t;
                    break;
                }
            }
        }
        if (track == uint.max) {
            if (!w.addTrack()) {
                return NoteEdit.noFreeTrack;
            }
            track = w.tracks - 1;
        }

        gridPinFollowing(w, track, line);
        immutable NoteCell old = w.at(track, line);
        NoteCell cell = NoteCell.makeNote(pitch, velocity, moduleId);
        cell.effect = old.effect;
        cell.effectVal = old.effectVal;
        cell.paramId = old.paramId;
        w.at(track, line) = cell;
        if (end < w.lines && w.at(track, end).note == 0) {
            NoteCell* e = &w.at(track, end);
            e.note = NoteCmd.noteOff;
            e.moduleId = moduleId;
        }
        grid = w;
        placed = RollNote(track, line, end - line, pitch, cellVelocity(cell), moduleId);
        return NoteEdit.ok;
    }

    private bool resolvePhraseRange(string partName, string sectionName, BeatPosition startPos, Length rangeLen,
            bool allowImplicitGrow, out size_t pIdx, out size_t sIdx, out uint startLine, out uint endLine,
            out PartProblem problem) @safe nothrow {
        pIdx = indexOfPart(partName);
        if (pIdx == parts_.length) {
            problem = unknownPartProblem(partName);
            return false;
        }
        if (rangeLen.lines == 0) {
            problem = PartProblem(PartProblemKind.invalidLength, "length",
                "phrase length must be at least 1 line", "1l");
            return false;
        }
        uint bars = 0;
        uint secLines = 0;
        bool isImp = false;
        if (!resolveSectionForWrite(sectionName, sIdx, bars, secLines, isImp, problem)) {
            return false;
        }
        immutable TimeSignature sig = project_.timeSignature();
        immutable LinesResult lr = positionToLine(startPos, sig);
        if (!lr.ok) {
            problem = PartProblem(PartProblemKind.positionOutOfRange, formatPosition(startPos),
                lr.error.reason, lr.error.suggestion);
            return false;
        }
        startLine = lr.lines;
        immutable ulong reqEnd = cast(ulong) startLine + cast(ulong) rangeLen.lines;
        if (reqEnd > MAX_LINES) {
            problem = PartProblem(PartProblemKind.positionOutOfRange, formatPosition(startPos),
                "range runs past the maximum pattern length (" ~ wholeText(MAX_LINES) ~ " lines)", "1");
            return false;
        }
        if (!allowImplicitGrow && reqEnd > secLines) {
            immutable string sugg = rangeLen.lines <= secLines
                ? formatPosition(lineToPosition(secLines - rangeLen.lines, sig).position) : "1";
            problem = PartProblem(PartProblemKind.positionOutOfRange, formatPosition(startPos),
                "range crosses the end of section '" ~ (isImp ? "implicit" : sections_[sIdx].name) ~ "'",
                sugg);
            return false;
        }
        endLine = cast(uint) reqEnd;
        return true;
    }

    private PartEditResult transposeSelectedNotes(size_t patIdx, size_t pIdx, uint startLine, uint endLine,
            int delta, bool byScaleSteps) @safe nothrow {
        RollNote[] selected;
        foreach (ref rn; notesOf(patterns_[patIdx].grid)) {
            if (rn.line >= startLine && rn.line < endLine) {
                selected ~= rn;
            }
        }
        if (selected.length == 0) {
            return PartEditResult(true);
        }

        immutable MusicalKey songKey = project_.key();
        ubyte[] newPitches = new ubyte[selected.length];
        foreach (i, ref rn; selected) {
            immutable int nextPitch = byScaleSteps
                ? shiftPitchByScaleSteps(rn.pitch, songKey, delta)
                : cast(int) rn.pitch + delta;
            if (nextPitch < 0 || nextPitch > 127) {
                immutable string sugg = nextPitch < 0 ? "0" : "0";
                cast(void) sugg;
                return PartEditResult(false, PartProblem(PartProblemKind.invalidPitch,
                    wholeText(rn.pitch),
                    "transposing puts note outside MIDI pitch range 0..127",
                    nextPitch < 0 ? "0" : "127"));
            }
            newPitches[i] = cast(ubyte) nextPitch;
        }

        PatternGrid work = patterns_[patIdx].grid.dup();
        immutable NoteEdit del = deleteNotes(work, selected);
        if (del != NoteEdit.ok) {
            return PartEditResult(false, mapNoteEditProblem(del, "transpose"));
        }

        immutable TimeSignature sig = project_.timeSignature();
        foreach (i, ref rn; selected) {
            RollNote placed;
            immutable NoteEdit edit = placePartNote(work, patterns_[patIdx].handPlaced,
                cast(ushort) parts_[pIdx].moduleId, newPitches[i], rn.line, rn.length, rn.velocity, placed);
            if (edit != NoteEdit.ok) {
                return PartEditResult(false, mapNoteEditProblem(edit,
                    formatPosition(lineToPosition(rn.line, sig).position)));
            }
        }
        patterns_[patIdx].grid = work;
        return PartEditResult(true);
    }

    private static int shiftPitchByScaleSteps(ubyte pitch, MusicalKey key, int steps) @safe pure nothrow @nogc {
        static immutable int[7] MAJOR_IV = [0, 2, 4, 5, 7, 9, 11];
        static immutable int[7] MINOR_IV = [0, 2, 3, 5, 7, 8, 10];
        const int[7] iv = key.mode == KeyMode.minor ? MINOR_IV : MAJOR_IV;
        immutable int rel = cast(int) pitch - cast(int) key.tonic;
        immutable int oct = rel >= 0 ? (rel / 12) : -((-rel + 11) / 12);
        immutable int rem = rel - oct * 12;
        int deg = 0;
        foreach (d; 0 .. 7) {
            if (iv[d] <= rem) {
                deg = cast(int) d;
            }
        }
        immutable int acc = rem - iv[deg];
        immutable int totalDeg = oct * 7 + deg + steps;
        immutable int newOct = totalDeg >= 0 ? (totalDeg / 7) : -((-totalDeg + 6) / 7);
        immutable int newDeg = totalDeg - newOct * 7;
        return cast(int) key.tonic + newOct * 12 + iv[newDeg] + acc;
    }

    private static size_t findSubstring(string haystack, string needle) @safe pure nothrow @nogc {
        if (needle.length == 0 || haystack.length < needle.length) {
            return haystack.length;
        }
        foreach (i; 0 .. haystack.length - needle.length + 1) {
            if (haystack[i .. i + needle.length] == needle) {
                return i;
            }
        }
        return haystack.length;
    }

    private static size_t analyzePatternModules(const ref SavedPattern pat, const ProjectWriter project,
            out uint singleModId) @safe nothrow {
        uint[] seen;
        foreach (tr; 0 .. pat.tracks) {
            ushort active = 0;
            foreach (ln; 0 .. pat.lines) {
                immutable size_t cellIdx = cast(size_t) ln * pat.tracks + tr;
                if (cellIdx >= pat.cells.length) {
                    continue;
                }
                immutable NoteCell c = pat.cells[cellIdx];
                ushort effMod = c.moduleId;
                if (effMod != 0) {
                    active = effMod;
                } else if (isGridNote(c)) {
                    effMod = active;
                }
                if (effMod != 0) {
                    if (!project.hasModuleId(effMod)) {
                        return 2;
                    }
                    bool found = false;
                    foreach (m; seen) {
                        if (m == effMod) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        seen ~= effMod;
                        if (seen.length > 1) {
                            return seen.length;
                        }
                    }
                }
            }
        }
        if (seen.length == 1) {
            singleModId = seen[0];
        }
        return seen.length;
    }

    private size_t ensureOpenedSection(string desiredName, uint bars) @safe nothrow {
        string clean = trim(desiredName);
        if (clean.length == 0) {
            clean = "section";
        }
        if (clean.length > MAX_PART_NAME_LENGTH) {
            clean = clean[0 .. MAX_PART_NAME_LENGTH];
        }
        immutable size_t existing = indexOfSection(clean);
        if (existing != sections_.length) {
            if (sections_[existing].bars == bars) {
                return existing;
            }
            clean = freeSectionName(clean);
        }
        sections_ ~= SectionEntry(clean, bars, false);
        return sections_.length - 1;
    }

    private size_t ensureOpenedPart(string desiredName, uint moduleId, size_t sectionIdx) @safe nothrow {
        string clean = trim(desiredName);
        if (clean.length == 0) {
            clean = "part";
        }
        if (clean.length > MAX_PART_NAME_LENGTH) {
            clean = clean[0 .. MAX_PART_NAME_LENGTH];
        }
        immutable size_t exact = indexOfPart(clean);
        if (exact != parts_.length && parts_[exact].moduleId == moduleId
                && indexOfPattern(exact, sectionIdx) == patterns_.length) {
            return exact;
        }
        foreach (i, ref p; parts_) {
            if (p.moduleId == moduleId && indexOfPattern(i, sectionIdx) == patterns_.length) {
                return i;
            }
        }
        string finalName = clean;
        if (indexOfPart(finalName) != parts_.length) {
            finalName = freePartName(clean);
        }
        immutable string modHandle = project_.handleForId(moduleId);
        parts_ ~= PartEntry(finalName, modHandle, moduleId);
        return parts_.length - 1;
    }

    private bool tryReconstructArrangement(const DrumWriter drums, const ref LoadedProject base,
            const(OpenedPatternMapping)[] mappings, uint lpb, out size_t[] seq,
            out bool isImplicitSingle) const @safe nothrow {
        if (base.clips.length == 0 || lpb == 0) {
            return false;
        }
        TimelineClip[] sorted = base.clips.dup;
        foreach (i; 1 .. sorted.length) {
            TimelineClip key = sorted[i];
            size_t j = i;
            while (j > 0 && (sorted[j - 1].startLine > key.startLine
                    || (sorted[j - 1].startLine == key.startLine && sorted[j - 1].laneY > key.laneY))) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = key;
        }

        bool[uint] emptyUsed;
        DrumExportEntry[] drumExports = drums !is null ? drums.exportPatterns(1, emptyUsed) : null;

        long cursor = 0;
        size_t i = 0;
        while (i < sorted.length) {
            if (sorted[i].startLine != cursor) {
                return false;
            }
            size_t stepSec = size_t.max;
            while (i < sorted.length && sorted[i].startLine == cursor) {
                immutable TimelineClip cl = sorted[i];
                if (cl.patternOffset != 0 || cl.mute || cl.solo || cl.isSupertrack) {
                    return false;
                }
                size_t patSec = size_t.max;
                uint expectedLane = uint.max;
                uint patLines = 0;
                immutable size_t mIdx = indexOfPatternById(cl.patternId);
                if (mIdx != patterns_.length && !patterns_[mIdx].isRaw) {
                    patSec = patterns_[mIdx].sectionIndex;
                    expectedLane = cast(uint) patterns_[mIdx].partIndex;
                    patLines = patterns_[mIdx].grid.lines;
                } else {
                    foreach (ref de; drumExports) {
                        if (de.patternId == cl.patternId) {
                            patSec = de.sectionIndex;
                            expectedLane = cast(uint) parts_.length + cast(uint) de.partIndex;
                            patLines = de.pattern.lines;
                            break;
                        }
                    }
                }
                if (patSec == size_t.max || cl.lengthLines != patLines || cl.laneY != expectedLane) {
                    return false;
                }
                if (stepSec == size_t.max) {
                    stepSec = patSec;
                } else if (stepSec != patSec) {
                    return false;
                }
                i++;
            }
            seq ~= stepSec;
            cursor += cast(long) sections_[stepSec].bars * lpb;
        }

        isImplicitSingle = seq.length == 1 && seq[0] == implicitIndex_;
        if (isImplicitSingle && sectionCount() > 0) {
            return false;
        }
        return seq.length > 0;
    }

    private bool findSectionForPatternId(uint patId, const(DrumExportEntry)[] drumExports,
            out size_t sectionIndex) const @safe nothrow {
        immutable size_t idx = indexOfPatternById(patId);
        if (idx != patterns_.length && !patterns_[idx].isRaw) {
            sectionIndex = patterns_[idx].sectionIndex;
            return true;
        }
        foreach (ref de; drumExports) {
            if (de.patternId == patId) {
                sectionIndex = de.sectionIndex;
                return true;
            }
        }
        return false;
    }

    private void appendNewClipsForPattern(ref TimelineClip[] clips, ref uint nextClipId, uint patId,
            uint patLines, uint laneY, size_t sectionIdx, const(bool[long][size_t]) secStartLines)
            const @safe nothrow {
        long[] starts;
        if (auto mapPtr = sectionIdx in secStartLines) {
            foreach (st, _; *mapPtr) {
                starts ~= st;
            }
            foreach (i; 1 .. starts.length) {
                long k = starts[i];
                size_t j = i;
                while (j > 0 && starts[j - 1] > k) {
                    starts[j] = starts[j - 1];
                    j--;
                }
                starts[j] = k;
            }
        } else {
            starts = [0];
        }
        uint firstId = 0;
        foreach (idx, st; starts) {
            immutable uint cid = nextClipId++;
            immutable uint cloneId = idx == 0 ? 0 : firstId;
            if (idx == 0) {
                firstId = cid;
            }
            clips ~= TimelineClip(cid, patId, cloneId, st, patLines, laneY, 0, false, false, false);
        }
    }
}
