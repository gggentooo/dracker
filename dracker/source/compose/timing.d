/**
 * File:         source/compose/timing.d
 * Module:       compose.timing
 * Phase:        Composition helper (dracker-compose) — T73 (positions and lengths: bars, beats, lines)
 *
 * Purpose:
 *   The musical-time model used by every part of the composition helper: a position inside one pattern written
 *   as `bar`, `bar.beat` or `bar.beat.sixteenth` (all counted from 1), and a length written as beats (`1`, `1/2`, `2`),
 *   bars (`2b`) or lines (`3l`). A line is one sixteenth note, so the time signature of the project decides
 *   how many lines a beat and a bar hold (lines per beat = 16 / denominator, lines per bar = numerator *
 *   lines per beat), exactly as StudioSession reports them. Parsing and formatting are pure functions that
 *   return problems as data (an offset, a length, a one-sentence reason and the nearest valid value) instead
 *   of printing anything, so a later front end decides how a problem is shown.
 *
 * Real-Time & Safety Contract:
 *   Off-RT / offline only. Every function is @safe pure nothrow; functions returning strings allocate them on
 *   the GC heap. No audio, GUI, session or file dependency; the only import is the time-signature and pattern
 *   size rules of io.project_format, which are the same rules the app enforces when it loads a project.
 *
 * Dependencies:
 *   Internal: io.project_format (isValidTimeSignature, MAX_LINES, MAX_TIME_SIG_NUMERATOR,
 *             DEFAULT_TIME_SIG_NUMERATOR, DEFAULT_TIME_SIG_DENOMINATOR)
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum LINES_PER_WHOLE_NOTE, enum MAX_POSITION_LINES
 *   - struct TimeSignature (numerator, denominator; isValid()); defaultTimeSignature();
 *     parseTimeSignature(); formatTimeSignature()
 *   - enum LengthUnit (beats, bars, lines); struct Length (lines); linesToLength()
 *   - struct BeatPosition (bar, beat, sixteenth); struct Fraction (numerator, denominator)
 *   - struct TimingError; struct PositionResult; struct LengthResult; struct LinesResult;
 *     struct TimeSignatureResult
 *   - linesPerBeat(), linesPerBar()
 *   - parsePosition(), formatPosition(), positionToLine(), lineToPosition()
 *   - parseLength(), formatLength(), beatsOf()
 *
 * See_Also:
 *   docs/todo.md (T66, T67, T68, T73, T90), docs/manual.md (time signature), source/app/session.d (linesPerBeat)
 */
module compose.timing;

import io.project_format : DEFAULT_TIME_SIG_DENOMINATOR, DEFAULT_TIME_SIG_NUMERATOR, isValidTimeSignature, MAX_LINES,
    MAX_TIME_SIG_NUMERATOR;

/**
 * Lines in one whole note. A line is a sixteenth note, as in the tracker and the sequencer clock, so a beat of
 * a signature with denominator d holds 16 / d lines (the same rule as StudioSession.LINES_PER_WHOLE_NOTE).
 */
enum uint LINES_PER_WHOLE_NOTE = 16;

/**
 * The number of lines a position must stay below and a length may reach: the longest pattern the project
 * format accepts. Positions are counted inside one pattern (a part's section), not across the arrangement.
 */
enum ulong MAX_POSITION_LINES = MAX_LINES;

/**
 * Largest number accepted in a position part or a length value before the result is refused as too large.
 */
private enum ulong NUMBER_CAP = 1_000_000_000;

/**
 * Outcome of reading a run of decimal digits.
 */
private enum NumberStatus : ubyte {
    ok = 0,
    notANumber = 1,
    tooLarge = 2
}

/**
 * Unit of a written length: beats by default, bars with a `b` suffix, lines with an `l` suffix.
 */
enum LengthUnit : ubyte {
    beats = 0,
    bars = 1,
    lines = 2
}

/**
 * A project's time signature. The numerator is 1 to MAX_TIME_SIG_NUMERATOR and the denominator is 2, 4, 8
 * or 16, the same values the .msv loader accepts.
 */
struct TimeSignature {
    uint numerator = DEFAULT_TIME_SIG_NUMERATOR;
    uint denominator = DEFAULT_TIME_SIG_DENOMINATOR;

    /**
     * Reports whether the pair is one the project format accepts.
     *
     * Returns:
     *   True if the numerator and denominator are both in range.
     */
    bool isValid() const @safe pure nothrow @nogc {
        return isValidTimeSignature(numerator, denominator);
    }
}

/**
 * A place inside one pattern: a bar, a beat inside that bar and a sixteenth (line) inside that beat, each
 * counted from 1. (1, 1, 1) is the first line of the pattern.
 */
struct BeatPosition {
    uint bar = 1;
    uint beat = 1;
    uint sixteenth = 1;
}

/**
 * A length held as a whole number of lines, the unit a pattern actually stores.
 */
struct Length {
    uint lines = 0;
}

/**
 * A reduced positive fraction, used to show a length as beats.
 */
struct Fraction {
    uint numerator = 0;
    uint denominator = 1;
}

/**
 * A problem found while parsing musical time: where in the text, how long the offending part is, what is
 * wrong, and the nearest value that would work (empty when there is none).
 */
struct TimingError {
    size_t offset = 0;
    size_t length = 0;
    string reason = "";
    string suggestion = "";
}

/**
 * The result of parsing a position: the position when ok is true, the problem otherwise.
 */
struct PositionResult {
    BeatPosition position = BeatPosition();
    bool ok = false;
    TimingError error = TimingError();
}

/**
 * The result of parsing a length: the length when ok is true, the problem otherwise.
 */
struct LengthResult {
    Length length = Length();
    bool ok = false;
    TimingError error = TimingError();
}

/**
 * The result of converting between a position and a line index.
 */
struct LinesResult {
    uint lines = 0;
    bool ok = false;
    TimingError error = TimingError();
}

/**
 * The result of parsing a time signature.
 */
struct TimeSignatureResult {
    TimeSignature signature = TimeSignature();
    bool ok = false;
    TimingError error = TimingError();
}

/**
 * The time signature a new project starts with.
 *
 * Returns:
 *   4/4.
 */
TimeSignature defaultTimeSignature() @safe pure nothrow @nogc {
    return TimeSignature();
}

/**
 * Lines in one beat for a time signature.
 *
 * Params:
 *   sig = The project's time signature.
 *
 * Returns:
 *   16 / denominator (4/4 gives 4, 3/4 gives 4, 6/8 gives 2, 5/16 gives 1), or 0 for an invalid signature.
 */
uint linesPerBeat(TimeSignature sig) @safe pure nothrow @nogc {
    if (!sig.isValid()) {
        return 0;
    }
    return LINES_PER_WHOLE_NOTE / sig.denominator;
}

/**
 * Lines in one bar for a time signature.
 *
 * Params:
 *   sig = The project's time signature.
 *
 * Returns:
 *   numerator * linesPerBeat, or 0 for an invalid signature.
 */
uint linesPerBar(TimeSignature sig) @safe pure nothrow @nogc {
    return sig.numerator * linesPerBeat(sig);
}

/**
 * Parses a time signature written as `numerator/denominator`, as the `signature` command takes it.
 *
 * Params:
 *   text = Text such as "4/4", "3/4" or "5/16"; no surrounding spaces.
 *
 * Returns:
 *   The signature, or the problem with the offset of the offending part.
 */
TimeSignatureResult parseTimeSignature(string text) @safe pure nothrow {
    if (text.length == 0) {
        return TimeSignatureResult(TimeSignature(), false,
            TimingError(0, 0, "a time signature needs a numerator and a denominator", "4/4"));
    }
    immutable size_t slash = indexOf(text, '/');
    if (slash == text.length) {
        return TimeSignatureResult(TimeSignature(), false,
            TimingError(0, text.length, "a time signature is written as numerator/denominator", "4/4"));
    }
    if (slash == 0) {
        return TimeSignatureResult(TimeSignature(), false,
            TimingError(0, 0, "a time signature needs a numerator before '/'", "4/4"));
    }
    if (slash == text.length - 1) {
        return TimeSignatureResult(TimeSignature(), false,
            TimingError(text.length, 0, "a time signature needs a denominator after '/'", "4/4"));
    }
    immutable string rest = text[slash + 1 .. $];
    immutable size_t secondSlash = indexOf(rest, '/');
    if (secondSlash != rest.length) {
        return TimeSignatureResult(TimeSignature(), false,
            TimingError(slash + 1 + secondSlash, 1, "a time signature has one numerator and one denominator", "4/4"));
    }
    ulong numerator = 0;
    ulong denominator = 0;
    immutable NumberStatus numeratorStatus = parseDigits(text[0 .. slash], numerator);
    if (numeratorStatus != NumberStatus.ok) {
        return TimeSignatureResult(TimeSignature(), false,
            TimingError(0, slash, numeratorStatus == NumberStatus.tooLarge
                ? "the numerator of a time signature is at most " ~ decimal(MAX_TIME_SIG_NUMERATOR)
                : "the numerator of a time signature must be a whole number",
                numeratorStatus == NumberStatus.tooLarge ? decimal(MAX_TIME_SIG_NUMERATOR) : "4"));
    }
    if (parseDigits(rest, denominator) != NumberStatus.ok) {
        return TimeSignatureResult(TimeSignature(), false,
            TimingError(slash + 1, rest.length, "the denominator of a time signature is 2, 4, 8 or 16", "4"));
    }
    immutable TimeSignature sig = TimeSignature(cast(uint) numerator, cast(uint) denominator);
    if (!sig.isValid()) {
        if (numerator > MAX_TIME_SIG_NUMERATOR) {
            return TimeSignatureResult(sig, false,
                TimingError(0, slash, "the numerator of a time signature is at most " ~ decimal(MAX_TIME_SIG_NUMERATOR),
                decimal(MAX_TIME_SIG_NUMERATOR)));
        }
        if (numerator == 0) {
            return TimeSignatureResult(sig, false,
                TimingError(0, slash, "the numerator of a time signature is at least 1", "1"));
        }
        return TimeSignatureResult(sig, false,
            TimingError(slash + 1, text.length - slash - 1,
                "the denominator of a time signature is 2, 4, 8 or 16", "4"));
    }
    return TimeSignatureResult(sig, true);
}

/**
 * Writes a time signature the way the script language takes it.
 *
 * Params:
 *   sig = The project's time signature.
 *
 * Returns:
 *   Text such as "4/4" or "7/8".
 */
string formatTimeSignature(TimeSignature sig) @safe pure nothrow {
    return decimal(sig.numerator) ~ "/" ~ decimal(sig.denominator);
}

/**
 * Parses a position written as `bar`, `bar.beat` or `bar.beat.sixteenth`, counted from 1.
 *
 * Params:
 *   text = Text such as "3", "3.2" or "3.2.3".
 *   sig = The project's time signature, which bounds the beat and sixteenth numbers.
 *
 * Returns:
 *   The position, or the problem with the offset of the offending part. A beat past the bar's number of beats
 *   and a sixteenth past the beat's number of lines are refused with the largest value that fits.
 */
PositionResult parsePosition(string text, TimeSignature sig) @safe pure nothrow {
    immutable uint lpb = linesPerBeat(sig);
    immutable uint lpbar = linesPerBar(sig);
    if (lpb == 0) {
        return PositionResult(BeatPosition(), false,
            TimingError(0, text.length, "the time signature " ~ formatTimeSignature(sig) ~ " is not one this project accepts",
                "4/4"));
    }
    if (text.length == 0) {
        return PositionResult(BeatPosition(), false,
            TimingError(0, 0, "a position needs a bar number", "1"));
    }
    ulong[3] values = [0, 0, 0];
    size_t[3] offsets = [0, 0, 0];
    size_t[3] lengths = [0, 0, 0];
    size_t count = 0;
    size_t partStart = 0;
    size_t cursor = 0;
    while (cursor <= text.length) {
        if (cursor == text.length || text[cursor] == '.') {
            if (count == 3) {
                return PositionResult(BeatPosition(), false,
                    TimingError(partStart, cursor - partStart,
                        "a position has a bar, a beat and a sixteenth at most", "3.2.3"));
            }
            offsets[count] = partStart;
            lengths[count] = cursor - partStart;
            if (cursor == partStart) {
                return PositionResult(BeatPosition(), false,
                    TimingError(partStart, 0, "a position part is empty", "1"));
            }
            immutable NumberStatus status = parseDigits(text[partStart .. cursor], values[count]);
            if (status == NumberStatus.tooLarge) {
                return PositionResult(BeatPosition(), false,
                    TimingError(partStart, cursor - partStart, "the position number is too large",
                        formatPosition(lineToPosition(cast(uint) MAX_POSITION_LINES - 1, sig).position)));
            }
            if (status != NumberStatus.ok) {
                return PositionResult(BeatPosition(), false,
                    TimingError(partStart, cursor - partStart, "a position part must be a whole number", "1"));
            }
            count++;
            partStart = cursor + 1;
        }
        cursor++;
    }
    if (values[0] < 1) {
        return PositionResult(BeatPosition(), false,
            TimingError(offsets[0], lengths[0], "the bar number is at least 1", "1"));
    }
    immutable uint beat = count >= 2 ? cast(uint) values[1] : 1;
    immutable uint sixteenth = count >= 3 ? cast(uint) values[2] : 1;
    if (count >= 2) {
        if (beat < 1) {
            return PositionResult(BeatPosition(), false,
                TimingError(offsets[1], lengths[1], "the beat number is at least 1", "1"));
        }
        if (beat > sig.numerator) {
            return PositionResult(BeatPosition(), false,
                TimingError(offsets[1], lengths[1],
                    "a bar of " ~ formatTimeSignature(sig) ~ " has " ~ decimal(sig.numerator) ~ " beats",
                    decimal(sig.numerator)));
        }
    }
    if (count >= 3) {
        if (sixteenth < 1) {
            return PositionResult(BeatPosition(), false,
                TimingError(offsets[2], lengths[2], "the sixteenth number is at least 1", "1"));
        }
        if (sixteenth > lpb) {
            return PositionResult(BeatPosition(), false,
                TimingError(offsets[2], lengths[2],
                    "a beat of " ~ formatTimeSignature(sig) ~ " has " ~ decimal(lpb) ~ " sixteenths", decimal(lpb)));
        }
    }
    immutable ulong line = (values[0] - 1) * lpbar + (beat - 1) * lpb + (sixteenth - 1);
    if (line >= MAX_POSITION_LINES) {
        return PositionResult(BeatPosition(), false,
            TimingError(offsets[0], lengths[0], "the position is past the longest pattern (" ~ decimal(cast(uint) MAX_POSITION_LINES) ~ " lines)",
                formatPosition(lineToPosition(cast(uint) MAX_POSITION_LINES - 1, sig).position)));
    }
    return PositionResult(BeatPosition(cast(uint) values[0], beat, sixteenth), true);
}

/**
 * Writes a position the shortest way the script language accepts it.
 *
 * Params:
 *   p = The position, counted from 1.
 *
 * Returns:
 *   "3" when the beat and sixteenth are both 1, "3.2" when only the beat is set, otherwise "3.2.3". A beat of
 *   1 with a later sixteenth keeps its ".1" so the sixteenth cannot be read as a beat.
 */
string formatPosition(BeatPosition p) @safe pure nothrow {
    if (p.beat == 1 && p.sixteenth == 1) {
        return decimal(p.bar);
    }
    if (p.sixteenth == 1) {
        return decimal(p.bar) ~ "." ~ decimal(p.beat);
    }
    return decimal(p.bar) ~ "." ~ decimal(p.beat) ~ "." ~ decimal(p.sixteenth);
}

/**
 * Converts a position to the 0-based line index a pattern cell would use.
 *
 * Params:
 *   p = The position, counted from 1.
 *   sig = The project's time signature.
 *
 * Returns:
 *   The line index, or the problem when the signature, the position, or the resulting line is out of range.
 */
LinesResult positionToLine(BeatPosition p, TimeSignature sig) @safe pure nothrow {
    immutable uint lpb = linesPerBeat(sig);
    immutable uint lpbar = linesPerBar(sig);
    if (lpb == 0) {
        return LinesResult(0, false,
            TimingError(0, 0, "the time signature " ~ formatTimeSignature(sig) ~ " is not one this project accepts",
                "4/4"));
    }
    if (p.bar < 1) {
        return LinesResult(0, false, TimingError(0, 0, "the bar number is at least 1", "1"));
    }
    if (p.beat < 1 || p.beat > sig.numerator) {
        return LinesResult(0, false,
            TimingError(0, 0, "a bar of " ~ formatTimeSignature(sig) ~ " has " ~ decimal(sig.numerator) ~ " beats",
                decimal(sig.numerator)));
    }
    if (p.sixteenth < 1 || p.sixteenth > lpb) {
        return LinesResult(0, false,
            TimingError(0, 0, "a beat of " ~ formatTimeSignature(sig) ~ " has " ~ decimal(lpb) ~ " sixteenths",
                decimal(lpb)));
    }
    immutable ulong line = (cast(ulong) p.bar - 1) * lpbar + (cast(ulong) p.beat - 1) * lpb + (p.sixteenth - 1);
    if (line >= MAX_POSITION_LINES) {
        return LinesResult(0, false,
            TimingError(0, 0, "the position is past the longest pattern (" ~ decimal(cast(uint) MAX_POSITION_LINES) ~ " lines)",
                formatPosition(lineToPosition(cast(uint) MAX_POSITION_LINES - 1, sig).position)));
    }
    return LinesResult(cast(uint) line, true);
}

/**
 * Converts a 0-based line index to a position.
 *
 * Params:
 *   line = The line index in a pattern.
 *   sig = The project's time signature.
 *
 * Returns:
 *   The position, or the problem when the signature or the line is out of range.
 */
PositionResult lineToPosition(uint line, TimeSignature sig) @safe pure nothrow {
    immutable uint lpb = linesPerBeat(sig);
    immutable uint lpbar = linesPerBar(sig);
    if (lpb == 0) {
        return PositionResult(BeatPosition(), false,
            TimingError(0, 0, "the time signature " ~ formatTimeSignature(sig) ~ " is not one this project accepts",
                "4/4"));
    }
    if (line >= MAX_POSITION_LINES) {
        return PositionResult(BeatPosition(), false,
            TimingError(0, 0, "the line is past the longest pattern (" ~ decimal(cast(uint) MAX_POSITION_LINES) ~ " lines)",
                decimal(cast(uint) MAX_POSITION_LINES - 1)));
    }
    return PositionResult(BeatPosition(line / lpbar + 1, (line % lpbar) / lpb + 1, line % lpb + 1), true);
}

/**
 * Parses a length written as beats (`1`, `1/2`, `2`), bars (`2b`, `1/2b`) or lines (`3l`).
 *
 * Params:
 *   text = The length text.
 *   sig = The project's time signature, which decides how many lines a beat and a bar hold.
 *
 * Returns:
 *   The length as whole lines, or the problem. A length that is not a whole number of lines is refused with
 *   the nearest length that is; a fraction written in lines is refused with its beats spelling. A length past
 *   the longest pattern is refused with the longest length, written in bars.
 */
LengthResult parseLength(string text, TimeSignature sig) @safe pure nothrow {
    immutable uint lpb = linesPerBeat(sig);
    immutable uint lpbar = linesPerBar(sig);
    if (lpb == 0) {
        return LengthResult(Length(), false,
            TimingError(0, text.length, "the time signature " ~ formatTimeSignature(sig) ~ " is not one this project accepts",
                "4/4"));
    }
    if (text.length == 0) {
        return LengthResult(Length(), false, TimingError(0, 0, "a length needs a number", "1"));
    }
    ulong value = 0;
    size_t cursor = 0;
    while (cursor < text.length && isDigit(text[cursor])) {
        value = value * 10 + (text[cursor] - '0');
        if (value > NUMBER_CAP) {
            return LengthResult(Length(), false,
                TimingError(0, cursor + 1, "the length number is too large", longestLength(sig)));
        }
        cursor++;
    }
    if (cursor == 0) {
        return LengthResult(Length(), false,
            TimingError(0, text.length > 0 ? 1 : 0, "a length must start with a number", "1"));
    }
    ulong denominator = 1;
    if (cursor < text.length && text[cursor] == '/') {
        denominator = 0;
        cursor++;
        if (cursor == text.length || !isDigit(text[cursor])) {
            return LengthResult(Length(), false,
                TimingError(cursor, text.length - cursor, "a fraction needs a number after '/'", "1/2"));
        }
        size_t digitsStart = cursor;
        while (cursor < text.length && isDigit(text[cursor])) {
            denominator = denominator * 10 + (text[cursor] - '0');
            if (denominator > NUMBER_CAP) {
                return LengthResult(Length(), false,
                    TimingError(digitsStart, cursor + 1 - digitsStart, "the denominator of a length is too large", "2"));
            }
            cursor++;
        }
        if (denominator < 1) {
            return LengthResult(Length(), false,
                TimingError(digitsStart, cursor - digitsStart, "the denominator of a length is at least 1", "2"));
        }
    }
    LengthUnit unit = LengthUnit.beats;
    if (cursor < text.length) {
        if (text[cursor] == 'b') {
            unit = LengthUnit.bars;
        } else if (text[cursor] == 'l') {
            unit = LengthUnit.lines;
        } else {
            return LengthResult(Length(), false,
                TimingError(cursor, 1, "unknown length unit \"" ~ text[cursor .. cursor + 1] ~ "\"; use b for bars or l for lines",
                    "b"));
        }
        cursor++;
        if (cursor < text.length) {
            return LengthResult(Length(), false,
                TimingError(cursor, text.length - cursor, "unexpected text after the length", ""));
        }
    }
    immutable ulong linesPerUnit = unit == LengthUnit.bars ? lpbar : (unit == LengthUnit.lines ? 1 : lpb);
    immutable ulong wholeUnits = value;
    immutable ulong scaled = wholeUnits * linesPerUnit;
    if (scaled % denominator != 0) {
        if (unit == LengthUnit.lines) {
            return LengthResult(Length(), false,
                TimingError(0, text.length, "a length in lines must be a whole number of lines; write fractions in beats",
                decimal(cast(uint) value) ~ "/" ~ decimal(cast(uint) denominator)));
        }
        immutable ulong nearest = nearestWhole(scaled, denominator);
        return LengthResult(Length(), false,
            TimingError(0, text.length, "\"" ~ text ~ "\" is not a whole number of lines in "
                ~ formatTimeSignature(sig) ~ "; the nearest length is " ~ formatLength(linesToLength(cast(uint) nearest), sig),
                formatLength(linesToLength(cast(uint) nearest), sig)));
    }
    immutable ulong lines = scaled / denominator;
    if (lines < 1) {
        return LengthResult(Length(), false, TimingError(0, text.length, "a length is at least one line", "1"));
    }
    if (lines > MAX_POSITION_LINES) {
        return LengthResult(Length(), false,
            TimingError(0, text.length, "the length is longer than the longest pattern (" ~ decimal(cast(uint) MAX_POSITION_LINES) ~ " lines)",
                longestLength(sig)));
    }
    return LengthResult(Length(cast(uint) lines), true);
}

/**
 * A length given as a number of lines.
 *
 * Params:
 *   lines = Whole lines; 0 is a valid empty length for callers that need one.
 *
 * Returns:
 *   The length.
 */
Length linesToLength(uint lines) @safe pure nothrow @nogc {
    return Length(lines);
}

/**
 * A length expressed as beats, reduced to the smallest terms.
 *
 * Params:
 *   len = The length in whole lines.
 *   sig = The project's time signature.
 *
 * Returns:
 *   Lines / lines-per-beat as a reduced fraction; for an invalid signature the line count is returned as a
 *   whole number of beats.
 */
Fraction beatsOf(Length len, TimeSignature sig) @safe pure nothrow @nogc {
    immutable uint lpb = linesPerBeat(sig);
    if (lpb == 0) {
        return Fraction(len.lines, 1);
    }
    immutable uint common = greatestCommonDivisor(len.lines, lpb);
    return Fraction(len.lines / common, lpb / common);
}

/**
 * Writes a length the way the script language takes it: whole bars as `2b`, otherwise beats as a whole
 * number or a reduced fraction.
 *
 * Params:
 *   len = The length in whole lines.
 *   sig = The project's time signature.
 *
 * Returns:
 *   Text such as "2b", "2" or "1/2".
 */
string formatLength(Length len, TimeSignature sig) @safe pure nothrow {
    immutable uint lpbar = linesPerBar(sig);
    if (len.lines > 0 && lpbar > 0 && len.lines % lpbar == 0) {
        return decimal(len.lines / lpbar) ~ "b";
    }
    immutable Fraction beats = beatsOf(len, sig);
    if (beats.denominator == 1) {
        return decimal(beats.numerator);
    }
    return decimal(beats.numerator) ~ "/" ~ decimal(beats.denominator);
}

/**
 * Reports whether a character is an ASCII digit.
 *
 * Params:
 *   c = The character.
 *
 * Returns:
 *   True for '0' to '9'.
 */
private bool isDigit(char c) @safe pure nothrow @nogc {
    return c >= '0' && c <= '9';
}

/**
 * Reads a string that must hold a whole decimal number within NUMBER_CAP.
 *
 * Params:
 *   text = The candidate text; must be non-empty and all digits.
 *   value = Set to the parsed number when the text is accepted, left unchanged otherwise.
 *
 * Returns:
 *   NumberStatus.ok when every character is a digit and the value is within NUMBER_CAP,
 *   NumberStatus.tooLarge when the digits are valid but the value is above NUMBER_CAP,
 *   NumberStatus.notANumber when the text is empty or holds a character that is not a digit.
 */
private NumberStatus parseDigits(string text, ref ulong value) @safe pure nothrow @nogc {
    if (text.length == 0) {
        return NumberStatus.notANumber;
    }
    foreach (c; text) {
        if (!isDigit(c)) {
            return NumberStatus.notANumber;
        }
    }
    ulong parsed = 0;
    foreach (c; text) {
        parsed = parsed * 10 + (c - '0');
        if (parsed > NUMBER_CAP) {
            return NumberStatus.tooLarge;
        }
    }
    value = parsed;
    return NumberStatus.ok;
}

/**
 * The longest length a pattern can hold, written the way the script language takes it.
 *
 * Params:
 *   sig = The project's time signature.
 *
 * Returns:
 *   formatLength of MAX_POSITION_LINES lines, for example "256b" in 4/4.
 */
private string longestLength(TimeSignature sig) @safe pure nothrow {
    return formatLength(linesToLength(cast(uint) MAX_POSITION_LINES), sig);
}

/**
 * Finds a character in a string.
 *
 * Params:
 *   text = The text to search.
 *   needle = The character to look for.
 *
 * Returns:
 *   Its byte offset, or text.length when it is absent (never 0 for "absent"; compare with text.length).
 */
private size_t indexOf(string text, char needle) @safe pure nothrow @nogc {
    foreach (i, c; text) {
        if (c == needle) {
            return i;
        }
    }
    return text.length;
}

/**
 * Rounds a scaled value divided by a denominator to the nearest whole number, at least 1.
 *
 * Params:
 *   scaled = The value before division.
 *   denominator = The divisor, at least 1.
 *
 * Returns:
 *   The nearest whole quotient, clamped to at least 1 and to MAX_POSITION_LINES.
 */
private ulong nearestWhole(ulong scaled, ulong denominator) @safe pure nothrow @nogc {
    immutable ulong floor = scaled / denominator;
    immutable ulong remainder = scaled % denominator;
    ulong nearest = remainder * 2 >= denominator ? floor + 1 : floor;
    if (nearest < 1) {
        nearest = 1;
    }
    if (nearest > MAX_POSITION_LINES) {
        nearest = MAX_POSITION_LINES;
    }
    return nearest;
}

/**
 * The largest common divisor of two numbers, 1 when either is 0.
 *
 * Params:
 *   a = One number.
 *   b = The other number.
 *
 * Returns:
 *   The greatest common divisor.
 */
private uint greatestCommonDivisor(uint a, uint b) @safe pure nothrow @nogc {
    uint x = a;
    uint y = b;
    while (y != 0) {
        immutable uint rest = x % y;
        x = y;
        y = rest;
    }
    return x == 0 ? 1 : x;
}

/**
 * Writes an unsigned number as decimal text.
 *
 * Params:
 *   value = The number.
 *
 * Returns:
 *   Its decimal spelling, without leading zeros.
 */
private string decimal(uint value) @safe pure nothrow {
    char[12] buffer;
    size_t cursor = buffer.length;
    uint remaining = value;
    do {
        cursor--;
        buffer[cursor] = cast(char) ('0' + (remaining % 10));
        remaining /= 10;
    } while (remaining > 0);
    return buffer[cursor .. $].dup;
}
