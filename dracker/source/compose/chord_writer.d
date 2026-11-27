/**
 * File:         source/compose/chord_writer.d
 * Module:       compose.chord_writer
 * Phase:        Composition helper (dracker-compose) — T78 (Chords for parts: timing, styles, root voicing)
 *
 * Purpose:
 *   Parses chord progressions with bar/fraction timing (`Dm7:2`, `Dm7:1/2`, optional `|` barlines, and
 *   named preset progressions) via app.chord_progression, resolves Roman numerals against the project's
 *   key, realizes root-position notes (`hold`, `pulse` with `every=`, `root`, and `root5`, with `octave=`
 *   and `voices=3|4` per decision T69), and writes them atomically into a PartWriter's section pattern.
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Everything is @safe nothrow; no I/O or session state.
 *
 * Dependencies:
 *   Internal: app.chord_progression (Chord, chordIntervals, ChordQuality, parseChord,
 *             PROGRESSION_PRESETS, resolveChord, ResolvedChord), app.music_theory (MusicalKey),
 *             compose.names (namesMatch, nearestName, trim), compose.part_writer (PartEditResult,
 *             PartProblem, PartWriter), compose.script.notation (DEFAULT_NOTE_VELOCITY, NoteEvent),
 *             compose.timing (BeatPosition, formatPosition, formatTimeSignature, Length, linesPerBar,
 *             linesPerBeat, MAX_POSITION_LINES, TimeSignature)
 *   External: std.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum ChordStyle; enum ChordVoicing; enum ChordProblemKind
 *   - struct ChordProblem; struct TimedChord; struct ChordProgressionResult; struct ChordOptions;
 *     struct ChordEventsResult; struct ChordWriteResult
 *   - parseTimedProgression(), presetTimedProgression(), realizeChords(), writeChords(),
 *     writePresetChords()
 *
 * See_Also:
 *   docs/todo.md (T69, T78, T99), source/app/chord_progression.d, source/compose/part_writer.d
 */
module compose.chord_writer;

import std.math : isFinite;

import app.chord_progression : Chord, chordIntervals, ChordQuality, parseChord, PROGRESSION_PRESETS,
    resolveChord, ResolvedChord;
import app.music_theory : MusicalKey;
import compose.names : namesMatch, nearestName, trim;
import compose.part_writer : PartEditResult, PartProblem, PartWriter;
import compose.script.notation : DEFAULT_NOTE_VELOCITY, NoteEvent;
import compose.timing : BeatPosition, formatPosition, formatTimeSignature, Length, linesPerBar, linesPerBeat,
    LinesResult, MAX_POSITION_LINES, positionToLine, TimeSignature;

/** Chord realization styles supported in T78 and T99 (per decision T69). */
enum ChordStyle : ubyte {
    hold = 0,
    pulse = 1,
    root = 2,
    root5 = 3,
    arp = 4
}

/** Chord voicing strategies supported in T78 and T99 (per decision T69). */
enum ChordVoicing : ubyte {
    root = 0,
    close = 1
}

/** Arpeggio playback direction for ChordStyle.arp (per decision T69 / T99). */
enum ArpDirection : ubyte {
    up = 0,
    down = 1,
    updown = 2
}

/** Diagnostic categories returned by compose.chord_writer. */
enum ChordProblemKind : ubyte {
    emptyProgression = 0,
    invalidChord = 1,
    invalidBarLength = 2,
    unknownPreset = 3,
    invalidStyle = 4,
    invalidVoices = 5,
    invalidEvery = 6,
    pitchOutOfRange = 7,
    invalidVelocity = 8,
    partError = 9,
    invalidVoicing = 10,
    invalidDirection = 11,
    invalidRhythm = 12,
    progressionTooLong = 13
}

/**
 * Structured problem returned by chord parsing, realization, or writing.
 */
struct ChordProblem {
    ChordProblemKind kind = ChordProblemKind.invalidChord;
    string subject = "";
    string reason = "";
    string suggestion = "";
    size_t offset = 0;
    size_t length = 0;

    /**
     * Formats the problem as one human-readable sentence with optional suggestion.
     *
     * Returns:
     *   The reason followed by a name or value suggestion when present.
     */
    string text() const @safe pure nothrow {
        string result = reason;
        if (suggestion.length > 0) {
            immutable bool isName = kind == ChordProblemKind.unknownPreset
                || kind == ChordProblemKind.invalidStyle || kind == ChordProblemKind.partError
                || kind == ChordProblemKind.invalidVoicing || kind == ChordProblemKind.invalidDirection;
            result ~= isName ? "; did you mean '" ~ suggestion ~ "'?"
                : "; the nearest valid value is " ~ suggestion;
        }
        return result;
    }
}

/**
 * One parsed chord together with its duration expressed as a fraction of bars and whole tracker lines.
 */
struct TimedChord {
    Chord chord;
    uint barsNum = 1;
    uint barsDen = 1;
    uint lines = 16;
    size_t textOffset = 0;
    size_t textLength = 0;
}

/**
 * Result of parsing a timed chord progression or named progression preset.
 */
struct ChordProgressionResult {
    TimedChord[] chords;
    uint totalLines = 0;
    bool ok = false;
    ChordProblem problem = ChordProblem.init;
}

/**
 * Realization options for turning chords into timed NoteEvents per decision T69.
 */
struct ChordOptions {
    ChordStyle style = ChordStyle.hold;
    ChordVoicing voicing = ChordVoicing.root;
    bool hasOctave = false;
    int octave = 4;
    ubyte voices = 0;
    Length every = Length(0);
    float velocity = DEFAULT_NOTE_VELOCITY;
    ArpDirection arpDir = ArpDirection.up;
    string rhythm = "";
}

/**
 * Result of realizing timed chords into timed NoteEvents.
 */
struct ChordEventsResult {
    NoteEvent[] events;
    uint totalLines = 0;
    bool ok = false;
    ChordProblem problem = ChordProblem.init;
}

/**
 * Result of writing realized chords directly into a PartWriter.
 */
struct ChordWriteResult {
    size_t eventCount = 0;
    uint totalLines = 0;
    bool ok = false;
    ChordProblem problem = ChordProblem.init;
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

private string signedText(int value) @safe pure nothrow {
    return value < 0 ? ("-" ~ wholeText(cast(ulong)(-cast(long) value))) : wholeText(cast(ulong) value);
}

private bool isProgSeparator(char ch) @safe pure nothrow @nogc {
    return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ',' || ch == '-' || ch == '|';
}

private bool parseBarFraction(string text, uint lpbar, out uint barsNum, out uint barsDen, out uint lines,
        out ChordProblem problem) @safe pure nothrow {
    if (text.length == 0) {
        problem = ChordProblem(ChordProblemKind.invalidBarLength, text,
            "chord duration after ':' cannot be empty", "1");
        return false;
    }
    size_t slash = text.length;
    foreach (i, char c; text) {
        if (c == '/') {
            slash = i;
            break;
        }
    }
    ulong num = 0;
    ulong den = 1;
    immutable string numPart = text[0 .. slash];
    if (numPart.length == 0) {
        problem = ChordProblem(ChordProblemKind.invalidBarLength, text,
            "chord duration must start with a whole number of bars", "1");
        return false;
    }
    foreach (char c; numPart) {
        if (c < '0' || c > '9') {
            problem = ChordProblem(ChordProblemKind.invalidBarLength, text,
                "chord duration '" ~ text ~ "' must be a positive number or fraction of bars (e.g. 2 or 1/2)",
                "1");
            return false;
        }
        num = num * 10 + cast(ulong)(c - '0');
        if (num > MAX_POSITION_LINES) {
            problem = ChordProblem(ChordProblemKind.invalidBarLength, text,
                "chord duration '" ~ text ~ "' is too large", "1");
            return false;
        }
    }
    if (slash < text.length) {
        immutable string denPart = text[slash + 1 .. $];
        if (denPart.length == 0) {
            problem = ChordProblem(ChordProblemKind.invalidBarLength, text,
                "chord duration fraction needs a denominator after '/'", "1/2");
            return false;
        }
        den = 0;
        foreach (char c; denPart) {
            if (c < '0' || c > '9') {
                problem = ChordProblem(ChordProblemKind.invalidBarLength, text,
                    "chord duration '" ~ text ~ "' must use whole numbers", "1/2");
                return false;
            }
            den = den * 10 + cast(ulong)(c - '0');
            if (den > MAX_POSITION_LINES) {
                problem = ChordProblem(ChordProblemKind.invalidBarLength, text,
                    "chord duration denominator is too large", "2");
                return false;
            }
        }
        if (den == 0) {
            problem = ChordProblem(ChordProblemKind.invalidBarLength, text,
                "chord duration denominator must be at least 1", "2");
            return false;
        }
    }
    if (num == 0) {
        problem = ChordProblem(ChordProblemKind.invalidBarLength, text,
            "chord duration must be greater than 0 bars", "1");
        return false;
    }
    immutable ulong scaled = num * cast(ulong) lpbar;
    if (scaled % den != 0) {
        problem = ChordProblem(ChordProblemKind.invalidBarLength, text,
            "'" ~ text ~ "' bars is not a whole number of lines in this time signature", "1/2");
        return false;
    }
    immutable ulong calcLines = scaled / den;
    if (calcLines == 0 || calcLines > MAX_POSITION_LINES) {
        problem = ChordProblem(ChordProblemKind.invalidBarLength, text,
            "chord duration exceeds the maximum pattern length", "1");
        return false;
    }
    barsNum = cast(uint) num;
    barsDen = cast(uint) den;
    lines = cast(uint) calcLines;
    return true;
}

/**
 * Parses a timed chord progression such as `"Dm7:1/2 G7:1/2 | Cmaj7:2"`.
 *
 * Supports Roman numerals and chord names (including slash bass), `:bars` / `:num/den` durations
 * (default 1 bar), `|`, spaces, commas, `-`, and `->` separators.
 *
 * Params:
 *   text = Progression text.
 *   sig = Project time signature determining lines per bar.
 *
 * Returns:
 *   ChordProgressionResult with timed chords and total lines, or a structured ChordProblem.
 */
ChordProgressionResult parseTimedProgression(string text, TimeSignature sig) @safe pure nothrow {
    immutable uint lpbar = linesPerBar(sig);
    if (lpbar == 0) {
        return ChordProgressionResult(null, 0, false, ChordProblem(ChordProblemKind.invalidBarLength,
            formatTimeSignature(sig),
            "the time signature " ~ formatTimeSignature(sig) ~ " is not accepted", "4/4"));
    }

    TimedChord[] result;
    ulong total = 0;
    size_t i = 0;
    while (i < text.length) {
        immutable char ch = text[i];
        if (isProgSeparator(ch)) {
            i++;
            continue;
        }
        if (ch == '>') {
            if (i == 0 || text[i - 1] != '-') {
                return ChordProgressionResult(null, 0, false, ChordProblem(ChordProblemKind.invalidChord, ">",
                    "unexpected '>'; separate chords with spaces, commas, '|', '-' or '->'", "|", i, 1));
            }
            i++;
            continue;
        }

        immutable size_t start = i;
        while (i < text.length && !isProgSeparator(text[i]) && text[i] != '>') {
            i++;
        }
        immutable string token = text[start .. i];

        size_t colon = token.length;
        foreach (k, char tc; token) {
            if (tc == ':') {
                colon = k;
                break;
            }
        }
        immutable string chordPart = token[0 .. colon];
        Chord parsed;
        string chordReason;
        if (!parseChord(chordPart, parsed, chordReason)) {
            return ChordProgressionResult(null, 0, false, ChordProblem(ChordProblemKind.invalidChord, chordPart,
                "\"" ~ chordPart ~ "\": " ~ chordReason, "I", start, chordPart.length));
        }

        uint barsNum = 1;
        uint barsDen = 1;
        uint chordLines = lpbar;
        if (colon < token.length) {
            ChordProblem lenProb;
            immutable string lenText = token[colon + 1 .. $];
            if (!parseBarFraction(lenText, lpbar, barsNum, barsDen, chordLines, lenProb)) {
                lenProb.offset = start + colon + 1;
                lenProb.length = lenText.length;
                return ChordProgressionResult(null, 0, false, lenProb);
            }
        }

        if (total + chordLines > MAX_POSITION_LINES) {
            return ChordProgressionResult(null, 0, false, ChordProblem(ChordProblemKind.invalidBarLength, token,
                "progression runs past the maximum pattern length", "", start, token.length));
        }
        total += chordLines;
        result ~= TimedChord(parsed, barsNum, barsDen, chordLines, start, token.length);
    }

    if (result.length == 0) {
        return ChordProgressionResult(null, 0, false, ChordProblem(ChordProblemKind.emptyProgression, text,
            "chord progression cannot be empty", "I - IV - V - I"));
    }
    return ChordProgressionResult(result, cast(uint) total, true);
}

/**
 * Looks up a bundled preset progression by name (ignoring case and spaces) and parses its chords.
 *
 * Params:
 *   presetName = Name such as `"Circle of fifths"` or `"Minor pop"`.
 *   sig = Project time signature.
 *
 * Returns:
 *   ChordProgressionResult, or unknownPreset with the nearest preset name.
 */
ChordProgressionResult presetTimedProgression(string presetName, TimeSignature sig) @safe pure nothrow {
    string[] names;
    names.reserve(PROGRESSION_PRESETS.length);
    foreach (ref p; PROGRESSION_PRESETS) {
        names ~= p.name;
        if (namesMatch(p.name, presetName)) {
            return parseTimedProgression(p.text, sig);
        }
    }
    return ChordProgressionResult(null, 0, false, ChordProblem(ChordProblemKind.unknownPreset, presetName,
        "unknown chord preset '" ~ trim(presetName) ~ "'", nearestName(presetName, names)));
}

/**
 * Parses a style name string into ChordStyle (case/space-insensitive).
 *
 * Params:
 *   text = Style text (`hold`, `pulse`, `root`, `root5`).
 *   style = Receives parsed ChordStyle when true is returned.
 *   problem = Receives invalidStyle on failure.
 *
 * Returns:
 *   True when recognized.
 */
bool parseChordStyle(string text, out ChordStyle style, out ChordProblem problem) @safe pure nothrow {
    if (namesMatch(text, "hold")) {
        style = ChordStyle.hold;
        return true;
    }
    if (namesMatch(text, "pulse")) {
        style = ChordStyle.pulse;
        return true;
    }
    if (namesMatch(text, "root")) {
        style = ChordStyle.root;
        return true;
    }
    if (namesMatch(text, "root5")) {
        style = ChordStyle.root5;
        return true;
    }
    if (namesMatch(text, "arp")) {
        style = ChordStyle.arp;
        return true;
    }
    static immutable string[5] STYLES = ["hold", "pulse", "arp", "root", "root5"];
    problem = ChordProblem(ChordProblemKind.invalidStyle, text,
        "unknown chord style '" ~ trim(text) ~ "' (expected hold, pulse, arp, root, or root5)",
        nearestName(text, STYLES[]));
    return false;
}

/**
 * Parses a voicing option value (`root` or `close`) without regard to case or spaces.
 *
 * Params:
 *   text = Voicing text.
 *   voicing = Receives parsed ChordVoicing.
 *   problem = Receives invalidVoicing on failure.
 *
 * Returns:
 *   True when recognized.
 */
bool parseChordVoicing(string text, out ChordVoicing voicing, out ChordProblem problem) @safe pure nothrow {
    if (namesMatch(text, "root")) {
        voicing = ChordVoicing.root;
        return true;
    }
    if (namesMatch(text, "close")) {
        voicing = ChordVoicing.close;
        return true;
    }
    static immutable string[2] VOICINGS = ["root", "close"];
    problem = ChordProblem(ChordProblemKind.invalidVoicing, text,
        "unknown chord voicing '" ~ trim(text) ~ "' (expected root or close)",
        nearestName(text, VOICINGS[]));
    return false;
}

/**
 * Parses an arpeggio direction (`up`, `down`, or `updown`) without regard to case or spaces.
 *
 * Params:
 *   text = Direction text.
 *   dir = Receives parsed ArpDirection.
 *   problem = Receives invalidDirection on failure.
 *
 * Returns:
 *   True when recognized.
 */
bool parseArpDirection(string text, out ArpDirection dir, out ChordProblem problem) @safe pure nothrow {
    if (namesMatch(text, "up")) {
        dir = ArpDirection.up;
        return true;
    }
    if (namesMatch(text, "down")) {
        dir = ArpDirection.down;
        return true;
    }
    if (namesMatch(text, "updown")) {
        dir = ArpDirection.updown;
        return true;
    }
    static immutable string[3] DIRS = ["up", "down", "updown"];
    problem = ChordProblem(ChordProblemKind.invalidDirection, text,
        "unknown arp direction '" ~ trim(text) ~ "' (expected up, down, or updown)",
        nearestName(text, DIRS[]));
    return false;
}

private struct RhythmStep {
    bool hit = false;
    float velocity = 0.8f;
}

private bool parseRhythmSteps(string rhythm, uint lpbar, float baseVel, out RhythmStep[] steps,
        out ChordProblem problem) @safe pure nothrow {
    bool anyHit = false;
    foreach (i, char c; rhythm) {
        if (c == ' ' || c == '\t' || c == '|') {
            continue;
        }
        if (c == 'x' || c == 'o') {
            steps ~= RhythmStep(true, baseVel);
            anyHit = true;
        } else if (c == 'X' || c == 'O' || c == '!') {
            float accVel = baseVel * 1.25f;
            if (accVel > 1.0f) {
                accVel = 1.0f;
            }
            steps ~= RhythmStep(true, accVel);
            anyHit = true;
        } else if (c == '-' || c == '.') {
            steps ~= RhythmStep(false, 0.0f);
        } else {
            problem = ChordProblem(ChordProblemKind.invalidRhythm, [c].idup,
                "unexpected rhythm character '" ~ [c].idup ~ "' (use x/X for hits and - for rests)",
                "x", i, 1);
            return false;
        }
    }
    if (steps.length == 0 || !anyHit) {
        problem = ChordProblem(ChordProblemKind.invalidRhythm, rhythm,
            "rhythm string must contain at least one hit (x)", "x---x---");
        return false;
    }
    if (lpbar % steps.length != 0) {
        problem = ChordProblem(ChordProblemKind.invalidRhythm, rhythm,
            "rhythm length " ~ wholeText(steps.length) ~ " does not divide a bar of "
            ~ wholeText(lpbar) ~ " lines", wholeText(lpbar));
        return false;
    }
    return true;
}

private ubyte[] buildCloseVoicing(const(ubyte)[] rootPitches, const(ubyte)[] prevPitches, bool doubleTopOctave)
        @safe pure nothrow {
    if (prevPitches.length == 0 || rootPitches.length == 0) {
        return rootPitches.dup;
    }
    immutable size_t baseLen = doubleTopOctave && rootPitches.length == 4 ? 3 : rootPitches.length;
    ubyte[] pcs;
    pcs.reserve(baseLen);
    foreach (p; rootPitches[0 .. baseLen]) {
        pcs ~= cast(ubyte)(p % 12);
    }

    ubyte[] best = rootPitches.dup;
    int bestMax = 0;
    int bestSum = 0;
    int bestCentroid = 0;
    scoreVoicingMove(best, prevPitches, bestMax, bestSum, bestCentroid);

    int prevSum = 0;
    foreach (p; prevPitches) {
        prevSum += cast(int) p;
    }
    immutable int approxBaseOct = ((prevSum / cast(int) prevPitches.length) / 12) - 1;

    foreach (inv; 0 .. baseLen) {
        int[] shape = new int[baseLen];
        int cur = cast(int) pcs[inv];
        shape[0] = cur;
        foreach (j; 1 .. baseLen) {
            int nextPc = cast(int) pcs[(inv + j) % baseLen];
            while (nextPc <= cur) {
                nextPc += 12;
            }
            shape[j] = nextPc;
            cur = nextPc;
        }

        foreach (octShift; approxBaseOct - 2 .. approxBaseOct + 4) {
            immutable int offset = (octShift + 1) * 12;
            ubyte[] cand;
            cand.reserve(rootPitches.length);
            bool inRange = true;
            foreach (s; shape) {
                immutable int m = offset + s;
                if (m < 0 || m > 127) {
                    inRange = false;
                    break;
                }
                cand ~= cast(ubyte) m;
            }
            if (!inRange) {
                continue;
            }
            if (doubleTopOctave && rootPitches.length == 4) {
                immutable int top = cast(int) cand[0] + 12;
                if (top < 0 || top > 127) {
                    continue;
                }
                cand ~= cast(ubyte) top;
            }
            int cMax = 0;
            int cSum = 0;
            int cCent = 0;
            scoreVoicingMove(cand, prevPitches, cMax, cSum, cCent);
            if (cMax < bestMax || (cMax == bestMax && cSum < bestSum)
                    || (cMax == bestMax && cSum == bestSum && cCent < bestCentroid)) {
                best = cand;
                bestMax = cMax;
                bestSum = cSum;
                bestCentroid = cCent;
            }
        }
    }
    return best;
}

private void scoreVoicingMove(const(ubyte)[] cand, const(ubyte)[] prev, out int maxMove, out int sumMove,
        out int centroidDiff) @safe pure nothrow @nogc {
    maxMove = 0;
    sumMove = 0;
    int candSum = 0;
    int prevSum = 0;
    foreach (p; cand) {
        candSum += cast(int) p;
    }
    foreach (p; prev) {
        prevSum += cast(int) p;
    }
    if (cand.length == prev.length) {
        foreach (i; 0 .. cand.length) {
            int d = cast(int) cand[i] - cast(int) prev[i];
            if (d < 0) {
                d = -d;
            }
            sumMove += d;
            if (d > maxMove) {
                maxMove = d;
            }
        }
    } else {
        foreach (c; cand) {
            int nearest = 128;
            foreach (p; prev) {
                int d = cast(int) c - cast(int) p;
                if (d < 0) {
                    d = -d;
                }
                if (d < nearest) {
                    nearest = d;
                }
            }
            sumMove += nearest;
            if (nearest > maxMove) {
                maxMove = nearest;
            }
        }
    }
    int cDiff = candSum * cast(int) prev.length - prevSum * cast(int) cand.length;
    centroidDiff = cDiff < 0 ? -cDiff : cDiff;
}

private void emitRhythmEvents(ref NoteEvent[] events, uint cursor, uint chordLines,
        const(ubyte)[] pitches, const(RhythmStep)[] steps, bool isPulseStyle, uint pulseLen,
        size_t textOffset, size_t textLength) @safe pure nothrow {
    foreach (uint off; 0 .. chordLines) {
        immutable RhythmStep st = steps[off % steps.length];
        if (!st.hit) {
            continue;
        }
        uint distToNext = chordLines - off;
        foreach (uint look; 1 .. chordLines - off) {
            if (steps[(off + look) % steps.length].hit) {
                distToNext = look;
                break;
            }
        }
        immutable uint noteLen = isPulseStyle && pulseLen < distToNext ? pulseLen : distToNext;
        events ~= NoteEvent(cursor + off, noteLen, pitches.dup, st.velocity, textOffset, textLength);
    }
}

/**
 * Realizes a timed chord sequence (root or close voicing) into timed NoteEvents ready for PartWriter.
 *
 * Params:
 *   chords = Parsed timed chords.
 *   key = Project MusicalKey used to resolve Roman-numeral chords.
 *   sig = Project TimeSignature used for step timing and bar rhythm divisibility.
 *   opts = Style, voicing, octave, voices, step interval, arp direction, rhythm string, and velocity.
 *
 * Returns:
 *   ChordEventsResult with timed NoteEvents, or a structured ChordProblem.
 */
ChordEventsResult realizeChords(const(TimedChord)[] chords, MusicalKey key, TimeSignature sig,
        ChordOptions opts = ChordOptions.init) @safe pure nothrow {
    if (chords.length == 0) {
        return ChordEventsResult(null, 0, false, ChordProblem(ChordProblemKind.emptyProgression, "",
            "chord progression cannot be empty", "I"));
    }
    immutable uint lpb = linesPerBeat(sig);
    immutable uint lpbar = linesPerBar(sig);
    if (lpb == 0 || lpbar == 0) {
        return ChordEventsResult(null, 0, false, ChordProblem(ChordProblemKind.invalidBarLength,
            formatTimeSignature(sig), "time signature is not valid", "4/4"));
    }
    if (!isFinite(opts.velocity) || opts.velocity <= 0.0f || opts.velocity > 1.0f) {
        return ChordEventsResult(null, 0, false, ChordProblem(ChordProblemKind.invalidVelocity, "velocity",
            "chord velocity must be finite and in (0, 1]", "0.8"));
    }
    if (opts.voices != 0 && opts.voices != 3 && opts.voices != 4) {
        return ChordEventsResult(null, 0, false, ChordProblem(ChordProblemKind.invalidVoices,
            wholeText(opts.voices), "option 'voices' must be 3 or 4", "3"));
    }
    if (opts.every.lines > MAX_POSITION_LINES) {
        return ChordEventsResult(null, 0, false, ChordProblem(ChordProblemKind.invalidEvery, "every",
            "option 'every' is too long", "1"));
    }

    RhythmStep[] rhythmSteps;
    immutable bool hasRhythm = opts.rhythm.length > 0;
    if (hasRhythm) {
        if (opts.style != ChordStyle.hold && opts.style != ChordStyle.root
                && opts.style != ChordStyle.pulse) {
            return ChordEventsResult(null, 0, false, ChordProblem(ChordProblemKind.invalidRhythm, "rhythm",
                "option 'rhythm' can only be combined with style hold, root, or pulse", "hold"));
        }
        ChordProblem rProb;
        if (!parseRhythmSteps(opts.rhythm, lpbar, opts.velocity, rhythmSteps, rProb)) {
            return ChordEventsResult(null, 0, false, rProb);
        }
    }

    immutable bool isBassStyle = opts.style == ChordStyle.root || opts.style == ChordStyle.root5;
    immutable int effOctave = opts.hasOctave ? opts.octave : (isBassStyle ? 2 : 4);
    immutable uint stepLines = opts.every.lines > 0
        ? opts.every.lines
        : (opts.style == ChordStyle.arp ? (lpb >= 4 ? lpb / 4 : 1) : lpb);

    NoteEvent[] events;
    ubyte[] prevChordPitches;
    uint cursor = 0;
    foreach (ref tc; chords) {
        immutable ResolvedChord rc = resolveChord(tc.chord, key);
        immutable(ubyte)[] ivs = chordIntervals(tc.chord.quality);

        if (isBassStyle) {
            immutable int bassMidi = (effOctave + 1) * 12 + cast(int) rc.bassPc;
            if (bassMidi < 0 || bassMidi > 127) {
                immutable int clamped = bassMidi < 0 ? 0 : 8;
                return ChordEventsResult(null, 0, false, ChordProblem(ChordProblemKind.pitchOutOfRange,
                    signedText(effOctave), "bass octave places chord root outside MIDI range 0..127",
                    signedText(clamped), tc.textOffset, tc.textLength));
            }
            int fifthMidi = bassMidi + (ivs.length >= 3 ? cast(int) ivs[2] : 7);
            if (tc.chord.hasBass && ivs.length >= 3) {
                immutable int fifthPc = (cast(int) rc.rootPc + cast(int) ivs[2]) % 12;
                immutable int delta = (fifthPc - cast(int) rc.bassPc + 12) % 12;
                fifthMidi = bassMidi + (delta == 0 ? 7 : delta);
            }
            if (opts.style == ChordStyle.root5 && (fifthMidi < 0 || fifthMidi > 127)) {
                immutable int clamped = fifthMidi < 0 ? 0 : 7;
                return ChordEventsResult(null, 0, false, ChordProblem(ChordProblemKind.pitchOutOfRange,
                    signedText(effOctave), "root5 fifth falls outside MIDI range 0..127",
                    signedText(clamped), tc.textOffset, tc.textLength));
            }

            if (hasRhythm) {
                emitRhythmEvents(events, cursor, tc.lines, [cast(ubyte) bassMidi], rhythmSteps,
                    false, 1, tc.textOffset, tc.textLength);
            } else if (opts.style == ChordStyle.root) {
                events ~= NoteEvent(cursor, tc.lines, [cast(ubyte) bassMidi], opts.velocity,
                    tc.textOffset, tc.textLength);
            } else {
                uint off = 0;
                uint step = 0;
                while (off < tc.lines) {
                    immutable uint rem = tc.lines - off;
                    immutable uint noteLen = rem < stepLines ? rem : stepLines;
                    immutable ubyte notePitch = cast(ubyte)((step & 1) == 0 ? bassMidi : fifthMidi);
                    events ~= NoteEvent(cursor + off, noteLen, [notePitch], opts.velocity,
                        tc.textOffset, tc.textLength);
                    off += stepLines;
                    step++;
                }
            }
        } else {
            immutable int rootMidi = (effOctave + 1) * 12 + cast(int) rc.rootPc;
            ubyte[] rootPitches;
            foreach (iv; ivs) {
                immutable int p = rootMidi + cast(int) iv;
                if (p < 0 || p > 127) {
                    immutable int clamped = p < 0 ? 0 : 7;
                    return ChordEventsResult(null, 0, false, ChordProblem(ChordProblemKind.pitchOutOfRange,
                        signedText(effOctave), "octave places chord notes outside MIDI range 0..127",
                        signedText(clamped), tc.textOffset, tc.textLength));
                }
                rootPitches ~= cast(ubyte) p;
            }
            bool doubledOctave = false;
            if (opts.voices == 3 && rootPitches.length > 3) {
                rootPitches = rootPitches[0 .. 3];
            } else if (opts.voices == 4 && rootPitches.length == 3) {
                immutable int topOct = rootMidi + 12;
                if (topOct < 0 || topOct > 127) {
                    return ChordEventsResult(null, 0, false, ChordProblem(ChordProblemKind.pitchOutOfRange,
                        signedText(effOctave), "4-voice octave doubling exceeds MIDI range 0..127", "6",
                        tc.textOffset, tc.textLength));
                }
                rootPitches ~= cast(ubyte) topOct;
                doubledOctave = true;
            }

            ubyte[] pitches = opts.voicing == ChordVoicing.close
                ? buildCloseVoicing(rootPitches, prevChordPitches, doubledOctave)
                : rootPitches;
            prevChordPitches = pitches;

            if (hasRhythm) {
                immutable uint pulseLen = opts.every.lines > 0 ? opts.every.lines : 1;
                emitRhythmEvents(events, cursor, tc.lines, pitches, rhythmSteps,
                    opts.style == ChordStyle.pulse, pulseLen, tc.textOffset, tc.textLength);
            } else if (opts.style == ChordStyle.hold) {
                events ~= NoteEvent(cursor, tc.lines, pitches, opts.velocity, tc.textOffset, tc.textLength);
            } else if (opts.style == ChordStyle.pulse) {
                uint off = 0;
                while (off < tc.lines) {
                    immutable uint rem = tc.lines - off;
                    immutable uint noteLen = rem < stepLines ? rem : stepLines;
                    events ~= NoteEvent(cursor + off, noteLen, pitches.dup, opts.velocity,
                        tc.textOffset, tc.textLength);
                    off += stepLines;
                }
            } else {
                immutable size_t k = pitches.length;
                uint off = 0;
                size_t step = 0;
                while (off < tc.lines) {
                    immutable uint rem = tc.lines - off;
                    immutable uint noteLen = rem < stepLines ? rem : stepLines;
                    size_t pitchIdx = 0;
                    final switch (opts.arpDir) {
                        case ArpDirection.up:
                            pitchIdx = step % k;
                            break;
                        case ArpDirection.down:
                            pitchIdx = k - 1 - (step % k);
                            break;
                        case ArpDirection.updown:
                            if (k == 1) {
                                pitchIdx = 0;
                            } else {
                                immutable size_t cycle = 2 * (k - 1);
                                immutable size_t pos = step % cycle;
                                pitchIdx = pos < k ? pos : (cycle - pos);
                            }
                            break;
                    }
                    events ~= NoteEvent(cursor + off, noteLen, [pitches[pitchIdx]], opts.velocity,
                        tc.textOffset, tc.textLength);
                    off += stepLines;
                    step++;
                }
            }
        }
        cursor += tc.lines;
    }
    return ChordEventsResult(events, cursor, true);
}

/**
 * Parses a chord progression, realizes it in root position against the project's key and time
 * signature, and writes the resulting notes into a part's section pattern atomically.
 *
 * Params:
 *   parts = Target PartWriter.
 *   partName = Destination part name.
 *   sectionName = Destination section name, or "" for the implicit section.
 *   progression = Progression text (chords with optional `:bars` and `|` separators).
 *   opts = Chord playing style and voicing options.
 *   startPos = Starting position inside the section (default `1`).
 *
 * Returns:
 *   ChordWriteResult indicating written event count or a structured ChordProblem.
 */
ChordWriteResult writeChords(PartWriter parts, string partName, string sectionName, string progression,
        ChordOptions opts = ChordOptions.init, BeatPosition startPos = BeatPosition(1, 1, 1)) @safe nothrow {
    if (parts is null) {
        return ChordWriteResult(0, 0, false, ChordProblem(ChordProblemKind.partError, partName,
            "a part writer is required", ""));
    }
    immutable TimeSignature sig = parts.project().timeSignature();
    immutable ChordProgressionResult parsed = parseTimedProgression(progression, sig);
    if (!parsed.ok) {
        return ChordWriteResult(0, 0, false, parsed.problem);
    }
    return writeTimedChords(parts, partName, sectionName, parsed.chords, opts, startPos);
}

/**
 * Realizes a bundled preset progression by name and writes it into a part's section pattern atomically.
 *
 * Params:
 *   parts = Target PartWriter.
 *   partName = Destination part name.
 *   sectionName = Destination section name, or "" for the implicit section.
 *   presetName = Bundled preset progression name (matched case/space-insensitively).
 *   opts = Chord playing style and voicing options.
 *   startPos = Starting position inside the section (default `1`).
 *
 * Returns:
 *   ChordWriteResult indicating written event count or a structured ChordProblem.
 */
ChordWriteResult writePresetChords(PartWriter parts, string partName, string sectionName, string presetName,
        ChordOptions opts = ChordOptions.init, BeatPosition startPos = BeatPosition(1, 1, 1)) @safe nothrow {
    if (parts is null) {
        return ChordWriteResult(0, 0, false, ChordProblem(ChordProblemKind.partError, partName,
            "a part writer is required", ""));
    }
    immutable TimeSignature sig = parts.project().timeSignature();
    immutable ChordProgressionResult parsed = presetTimedProgression(presetName, sig);
    if (!parsed.ok) {
        return ChordWriteResult(0, 0, false, parsed.problem);
    }
    return writeTimedChords(parts, partName, sectionName, parsed.chords, opts, startPos);
}

/**
 * Checks that a realized progression ends inside its named section (T119). The implicit section grows, so it
 * always fits.
 *
 * Params:
 *   parts = Target PartWriter.
 *   sectionName = Destination section name, or "" for the implicit section.
 *   chords = Parsed chords, for the span of the progression text.
 *   totalLines = Length of the realized progression in lines.
 *   startPos = Starting position inside the section.
 *   problem = Receives progressionTooLong with the section length and the bars the progression needs.
 *
 * Returns:
 *   True when the progression fits or the section is not a named one.
 */
private bool progressionFitsSection(PartWriter parts, string sectionName, const(TimedChord)[] chords,
        uint totalLines, BeatPosition startPos, out ChordProblem problem) @safe nothrow {
    if (trim(sectionName).length == 0) {
        return true;
    }
    immutable sec = parts.sectionOf(sectionName);
    if (!sec.ok) {
        return true;
    }
    immutable TimeSignature sig = parts.project().timeSignature();
    immutable LinesResult start = positionToLine(startPos, sig);
    immutable uint startLine = start.ok ? start.lines : 0;
    immutable ulong endLine = cast(ulong) startLine + totalLines;
    if (endLine <= sec.section.lines) {
        return true;
    }
    immutable uint lpb = linesPerBar(sig);
    immutable ulong neededBars = lpb > 0 ? (endLine + lpb - 1) / lpb : 0;
    size_t textEnd = 0;
    foreach (ref c; chords) {
        if (c.textOffset + c.textLength > textEnd) {
            textEnd = c.textOffset + c.textLength;
        }
    }
    immutable string fromText = startLine > 0 ? " from " ~ formatPosition(startPos) : "";
    problem = ChordProblem(ChordProblemKind.progressionTooLong, sec.section.name,
        "the progression needs " ~ barsText(neededBars) ~ fromText ~ ", but section '" ~ sec.section.name
            ~ "' has " ~ barsText(sec.section.bars) ~ "; lengthen the section (section " ~ sec.section.name
            ~ " bars=" ~ wholeBars(neededBars) ~ ") or shorten the progression",
        "", 0, textEnd);
    return false;
}

/**
 * Writes a bar count with its unit.
 *
 * Params:
 *   bars = Number of bars.
 *
 * Returns:
 *   "1 bar" or "<n> bars".
 */
private string barsText(ulong bars) @safe pure nothrow {
    return wholeBars(bars) ~ (bars == 1 ? " bar" : " bars");
}

/**
 * Writes a whole number in decimal.
 *
 * Params:
 *   v = The number.
 *
 * Returns:
 *   Its decimal digits.
 */
private string wholeBars(ulong v) @safe pure nothrow {
    if (v == 0) {
        return "0";
    }
    char[20] buf;
    size_t n = buf.length;
    while (v > 0) {
        buf[--n] = cast(char)('0' + v % 10);
        v /= 10;
    }
    return buf[n .. $].idup;
}

private ChordWriteResult writeTimedChords(PartWriter parts, string partName, string sectionName,
        const(TimedChord)[] chords, const ref ChordOptions opts, BeatPosition startPos) @safe nothrow {
    ChordEventsResult realized = realizeChords(chords, parts.project().key(),
        parts.project().timeSignature(), opts);
    if (!realized.ok) {
        return ChordWriteResult(0, 0, false, realized.problem);
    }
    ChordProblem lengthProblem;
    if (!progressionFitsSection(parts, sectionName, chords, realized.totalLines, startPos, lengthProblem)) {
        return ChordWriteResult(0, 0, false, lengthProblem);
    }
    immutable PartEditResult written = parts.writeNotes(partName, sectionName, startPos, realized.events);
    if (!written.ok) {
        return ChordWriteResult(0, 0, false, ChordProblem(ChordProblemKind.partError,
            written.problem.subject, written.problem.reason, written.problem.suggestion));
    }
    return ChordWriteResult(realized.events.length, realized.totalLines, true);
}
