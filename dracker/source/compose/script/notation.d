/**
 * File:         source/compose/script/notation.d
 * Module:       compose.script.notation
 * Phase:        Composition helper (dracker-compose) — T84 (Script language: note notation)
 *
 * Purpose:
 *   Pure parser and formatter for the note notation of the composition helper script language (T67):
 *   notes (`<pitch>[:<length>][@<velocity>]`), rests (`-[:<length>]`), and chords
 *   (`[pitch ...][:<length>][@<velocity>]`). Pitches follow app.music_theory spelling (C4 = middle C,
 *   C-1 = MIDI 0, G9 = MIDI 127), lengths are parsed through compose.timing.parseLength for a given
 *   TimeSignature and carried across following items (default one beat), and velocities are in (0, 1]
 *   (default DEFAULT_NOTE_VELOCITY = RollNote.init.velocity, never carried). Every refusal is returned
 *   as NotationError data with byte offset, length, reason and suggestion; nothing is printed or thrown.
 *
 * Real-Time & Safety Contract:
 *   Off-RT / offline only. Every function is @safe pure nothrow; functions returning arrays or strings
 *   allocate on the GC heap. No audio, GUI, session, command-interpreter or file dependency.
 *
 * Dependencies:
 *   Internal: app.music_theory (MusicalKey, noteName), app.pattern_notes (RollNote),
 *             compose.names (isSpaceChar), compose.timing (TimeSignature, LengthResult, linesPerBeat,
 *             parseLength, formatTimeSignature, MAX_POSITION_LINES)
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum DEFAULT_NOTE_VELOCITY
 *   - struct NotationError, struct NoteEvent, struct PitchResult, struct NotationResult
 *   - parsePitch(), formatPitch(), parseNotes()
 *
 * See_Also:
 *   docs/todo.md (T67, T73, T84, T97, T104), source/compose/timing.d, source/app/music_theory.d
 */
module compose.script.notation;

import app.music_theory : MusicalKey, noteName;
import app.pattern_notes : RollNote;
import compose.names : isSpaceChar;
import compose.timing : formatTimeSignature, LengthResult, linesPerBeat, MAX_POSITION_LINES, parseLength,
    TimeSignature;

/** Default velocity when a note or chord omits `@velocity`, matching the piano roll's default. */
enum float DEFAULT_NOTE_VELOCITY = RollNote.init.velocity;

/**
 * A problem found while parsing note notation, returned as data with offsets into the source text.
 */
struct NotationError {
    size_t offset = 0;
    size_t length = 0;
    string reason = "";
    string suggestion = "";
}

/**
 * One parsed note or chord event with its timing in pattern lines, MIDI pitches and velocity.
 */
struct NoteEvent {
    uint offset = 0;
    uint length = 0;
    ubyte[] pitches;
    float velocity = DEFAULT_NOTE_VELOCITY;
    size_t textOffset = 0;
    size_t textLength = 0;
}

/**
 * Outcome of parsing a single pitch spelling.
 */
struct PitchResult {
    ubyte midi = 0;
    bool ok = false;
    NotationError error = NotationError();
}

/**
 * Outcome of parsing a sequence of notes, chords and rests.
 */
struct NotationResult {
    NoteEvent[] events;
    uint totalLines = 0;
    bool ok = false;
    NotationError error = NotationError();
}

private struct VelocityResult {
    float value = DEFAULT_NOTE_VELOCITY;
    bool ok = false;
    NotationError error = NotationError();
}

private immutable int[7] LETTER_SEMITONES = [9, 11, 0, 2, 4, 5, 7];

/**
 * Parses one pitch written in app.music_theory spelling: a capital letter A..G, up to two `#` or two `b`
 * accidentals (never mixed), and a signed integer octave (C4 = 60, C-1 = 0, G9 = 127).
 *
 * Params:
 *   text = Pitch token to parse.
 *
 * Returns:
 *   MIDI note number in 0..127, or a NotationError with offsets relative to text.
 */
PitchResult parsePitch(string text) @safe pure nothrow {
    if (text.length == 0) {
        return PitchResult(0, false, NotationError(0, 0, "a pitch needs a note letter", "C4"));
    }
    immutable char first = text[0];
    if (first >= 'a' && first <= 'g') {
        immutable char upper = cast(char)(first - ('a' - 'A'));
        immutable string candidate = [upper].idup ~ text[1 .. $];
        immutable string suggestion = parsePitch(candidate).ok ? candidate : "";
        return PitchResult(0, false, NotationError(0, 1, "note letters are capitals (A to G)", suggestion));
    }
    if (first < 'A' || first > 'G') {
        return PitchResult(0, false, NotationError(0, 1, "a pitch starts with a note letter (A to G)", ""));
    }

    size_t cursor = 1;
    size_t sharps = 0;
    size_t flats = 0;
    while (cursor < text.length && (text[cursor] == '#' || text[cursor] == 'b')) {
        if (text[cursor] == '#') {
            sharps++;
        } else {
            flats++;
        }
        cursor++;
    }
    if ((sharps > 0 && flats > 0) || sharps > 2 || flats > 2) {
        return PitchResult(0, false,
            NotationError(1, cursor - 1, "a pitch has at most two sharps (#) or two flats (b)", ""));
    }
    immutable int accidental = cast(int) sharps - cast(int) flats;
    immutable size_t octStart = cursor;
    bool negative = false;
    if (cursor < text.length && text[cursor] == '-') {
        negative = true;
        cursor++;
    }
    immutable size_t digitsStart = cursor;
    int octMag = 0;
    while (cursor < text.length && isDigitChar(text[cursor])) {
        if (octMag <= 99) {
            octMag = octMag * 10 + (text[cursor] - '0');
        }
        cursor++;
    }
    if (cursor == digitsStart) {
        return PitchResult(0, false,
            NotationError(cursor, 0, "a pitch needs an octave number (C4 is middle C)",
                text[0 .. octStart] ~ "4"));
    }
    if (cursor < text.length) {
        immutable string prefix = text[0 .. cursor];
        immutable string suggestion = parsePitch(prefix).ok ? prefix : "";
        return PitchResult(0, false,
            NotationError(cursor, text.length - cursor, "unexpected text after the octave", suggestion));
    }

    immutable int octave = negative ? -octMag : octMag;
    immutable int midi = (octave + 1) * 12 + LETTER_SEMITONES[first - 'A'] + accidental;
    if (midi > 127) {
        return PitchResult(0, false, NotationError(0, text.length, "the highest note is G9", "G9"));
    }
    if (midi < 0) {
        string suggestion = "C-1";
        if (octave <= -2) {
            immutable string positive = text[0 .. octStart] ~ text[octStart + 1 .. $];
            if (parsePitch(positive).ok) {
                suggestion = positive;
            }
        }
        return PitchResult(0, false, NotationError(0, text.length, "the lowest note is C-1", suggestion));
    }
    return PitchResult(cast(ubyte) midi, true);
}

/**
 * Formats a MIDI note number in C-major app.music_theory spelling.
 *
 * Params:
 *   midi = MIDI note number (0..127).
 *
 * Returns:
 *   Note name such as "C4", "C-1" or "G9", or "" when midi > 127.
 */
string formatPitch(ubyte midi) @safe pure nothrow {
    if (midi > 127) {
        return "";
    }
    return noteName(midi, MusicalKey());
}

/**
 * Parses a sequence of notes, chords and rests into timed NoteEvents for a time signature.
 *
 * Params:
 *   text = Space-separated sequence of notes, chords and rests.
 *   sig = Time signature governing beat/bar line counts and length parsing.
 *
 * Returns:
 *   Events and total line count on success, or the first NotationError with offsets in text.
 */
NotationResult parseNotes(string text, TimeSignature sig) @safe pure nothrow {
    immutable uint lpb = linesPerBeat(sig);
    if (lpb == 0) {
        return NotationResult(null, 0, false,
            NotationError(0, text.length,
                "the time signature " ~ formatTimeSignature(sig) ~ " is not one this project accepts",
                "4/4"));
    }

    uint carried = lpb;
    ulong lineOffset = 0;
    NoteEvent[] events;
    size_t pos = 0;

    while (pos < text.length) {
        while (pos < text.length && isSpaceChar(text[pos])) {
            pos++;
        }
        if (pos == text.length) {
            break;
        }

        immutable size_t start = pos;
        immutable size_t end = itemEnd(text, start);
        pos = end;

        bool isRest = false;
        ubyte[] pitches;
        size_t suffixStart = start;

        if (text[start] == '[') {
            immutable size_t close = findChar(text, ']', start + 1);
            if (close == text.length || close >= end) {
                return NotationResult(null, 0, false,
                    NotationError(start, end - start, "a chord needs a closing ]", ""));
            }
            size_t inner = start + 1;
            while (inner < close) {
                while (inner < close && isSpaceChar(text[inner])) {
                    inner++;
                }
                if (inner >= close) {
                    break;
                }
                immutable size_t tokStart = inner;
                while (inner < close && !isSpaceChar(text[inner])) {
                    inner++;
                }
                immutable size_t tokEnd = inner;
                immutable PitchResult pr = parsePitch(text[tokStart .. tokEnd]);
                if (!pr.ok) {
                    return NotationResult(null, 0, false,
                        NotationError(tokStart + pr.error.offset, pr.error.length,
                            pr.error.reason, pr.error.suggestion));
                }
                foreach (existing; pitches) {
                    if (existing == pr.midi) {
                        return NotationResult(null, 0, false,
                            NotationError(tokStart, tokEnd - tokStart, "the chord has this note twice", ""));
                    }
                }
                pitches ~= pr.midi;
            }
            if (pitches.length == 0) {
                return NotationResult(null, 0, false,
                    NotationError(start, close + 1 - start, "a chord needs at least one pitch", "[C4 E4 G4]"));
            }
            suffixStart = close + 1;
            if (suffixStart < end && text[suffixStart] != ':' && text[suffixStart] != '@') {
                return NotationResult(null, 0, false,
                    NotationError(suffixStart, 1, "after ] comes :length or @velocity", ""));
            }
        } else {
            size_t sep = start;
            while (sep < end && text[sep] != ':' && text[sep] != '@') {
                sep++;
            }
            immutable string head = text[start .. sep];
            suffixStart = sep;
            if (head == "-") {
                isRest = true;
            } else {
                immutable PitchResult pr = parsePitch(head);
                if (!pr.ok) {
                    return NotationResult(null, 0, false,
                        NotationError(start + pr.error.offset, pr.error.length,
                            pr.error.reason, pr.error.suggestion));
                }
                pitches = [pr.midi];
            }
        }

        uint itemLen = carried;
        float velocity = DEFAULT_NOTE_VELOCITY;
        size_t cur = suffixStart;

        if (cur < end && text[cur] == ':') {
            immutable size_t lenStart = cur + 1;
            immutable size_t lenEnd = findChar(text[0 .. end], '@', lenStart);
            immutable LengthResult lr = parseLength(text[lenStart .. lenEnd], sig);
            if (!lr.ok) {
                return NotationResult(null, 0, false,
                    NotationError(lenStart + lr.error.offset, lr.error.length,
                        lr.error.reason, lr.error.suggestion));
            }
            itemLen = lr.length.lines;
            carried = itemLen;
            cur = lenEnd;
        }

        if (cur < end && text[cur] == '@') {
            if (isRest) {
                return NotationResult(null, 0, false,
                    NotationError(cur, end - cur, "a rest has no velocity", "-"));
            }
            immutable size_t velStart = cur + 1;
            immutable size_t extraColon = findChar(text[0 .. end], ':', velStart);
            if (extraColon != end) {
                return NotationResult(null, 0, false,
                    NotationError(extraColon, 1, "the length is written before the velocity", ""));
            }
            immutable VelocityResult vr = parseVelocity(text[velStart .. end]);
            if (!vr.ok) {
                return NotationResult(null, 0, false,
                    NotationError(velStart + vr.error.offset, vr.error.length,
                        vr.error.reason, vr.error.suggestion));
            }
            velocity = vr.value;
        }

        if (lineOffset + itemLen > MAX_POSITION_LINES) {
            return NotationResult(null, 0, false,
                NotationError(start, end - start, "the notes are longer than the longest pattern", ""));
        }

        if (!isRest) {
            events ~= NoteEvent(cast(uint) lineOffset, itemLen, pitches, velocity, start, end - start);
        }
        lineOffset += itemLen;
    }

    return NotationResult(events, cast(uint) lineOffset, true);
}

/**
 * Parses a velocity decimal strictly in (0, 1], with at most 3 digits before the dot and 6 after.
 *
 * Params:
 *   text = Velocity text following '@'.
 *
 * Returns:
 *   Parsed float value, or a NotationError relative to text.
 */
private VelocityResult parseVelocity(string text) @safe pure nothrow {
    if (text.length == 0) {
        return VelocityResult(DEFAULT_NOTE_VELOCITY, false,
            NotationError(0, 0, "a velocity needs a number from 0 to 1", "0.8"));
    }

    size_t cursor = 0;
    size_t beforeDot = 0;
    ulong scaled = 0;
    ulong divisor = 1;

    while (cursor < text.length && isDigitChar(text[cursor])) {
        beforeDot++;
        if (beforeDot > 3) {
            return VelocityResult(DEFAULT_NOTE_VELOCITY, false,
                NotationError(0, text.length, "a velocity is a number such as 0.8", "0.8"));
        }
        scaled = scaled * 10 + (text[cursor] - '0');
        cursor++;
    }
    if (beforeDot == 0) {
        return VelocityResult(DEFAULT_NOTE_VELOCITY, false,
            NotationError(0, text.length, "a velocity is a number such as 0.8", "0.8"));
    }
    if (cursor < text.length) {
        if (text[cursor] != '.') {
            return VelocityResult(DEFAULT_NOTE_VELOCITY, false,
                NotationError(0, text.length, "a velocity is a number such as 0.8", "0.8"));
        }
        cursor++;
        size_t afterDot = 0;
        while (cursor < text.length && isDigitChar(text[cursor])) {
            afterDot++;
            if (afterDot > 6) {
                return VelocityResult(DEFAULT_NOTE_VELOCITY, false,
                    NotationError(0, text.length, "a velocity is a number such as 0.8", "0.8"));
            }
            scaled = scaled * 10 + (text[cursor] - '0');
            divisor *= 10;
            cursor++;
        }
        if (afterDot == 0 || cursor < text.length) {
            return VelocityResult(DEFAULT_NOTE_VELOCITY, false,
                NotationError(0, text.length, "a velocity is a number such as 0.8", "0.8"));
        }
    }

    if (scaled == 0) {
        return VelocityResult(DEFAULT_NOTE_VELOCITY, false,
            NotationError(0, text.length, "a velocity is above 0", "0.1"));
    }
    if (scaled > divisor) {
        return VelocityResult(DEFAULT_NOTE_VELOCITY, false,
            NotationError(0, text.length, "a velocity is at most 1", "1"));
    }
    return VelocityResult(cast(float)(cast(double) scaled / cast(double) divisor), true);
}

/**
 * Finds the exclusive end offset of the item starting at start.
 *
 * Params:
 *   text = Full notation string.
 *   start = Byte offset of the first non-space character of the item.
 *
 * Returns:
 *   Byte offset of the first space ending the item, or text.length.
 */
private size_t itemEnd(string text, size_t start) @safe pure nothrow @nogc {
    size_t scan = start;
    if (start < text.length && text[start] == '[') {
        immutable size_t close = findChar(text, ']', start + 1);
        if (close == text.length) {
            return text.length;
        }
        scan = close + 1;
    }
    while (scan < text.length && !isSpaceChar(text[scan])) {
        scan++;
    }
    return scan;
}

/**
 * Finds needle in text starting at byte offset from.
 *
 * Params:
 *   text = String to search.
 *   needle = Byte to match.
 *   from = Starting byte offset.
 *
 * Returns:
 *   Byte offset of the match, or text.length when absent.
 */
private size_t findChar(string text, char needle, size_t from) @safe pure nothrow @nogc {
    foreach (i; from .. text.length) {
        if (text[i] == needle) {
            return i;
        }
    }
    return text.length;
}

/**
 * Reports whether c is an ASCII decimal digit.
 *
 * Params:
 *   c = Character to check.
 *
 * Returns:
 *   True for '0'..'9'.
 */
private bool isDigitChar(char c) @safe pure nothrow @nogc {
    return c >= '0' && c <= '9';
}
