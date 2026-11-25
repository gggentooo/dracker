/**
 * File:         source/app/chord_progression.d
 * Module:       app.chord_progression
 * Phase:        Skeleton project generator — T14 (chord model and parser)
 *
 * Purpose:
 *   Chords and chord progressions for the skeleton project generator, with the input syntax decided in T03.
 *   A progression is text of chords separated by spaces, commas, "-" or "->"; each chord becomes one block of one
 *   bar. A chord is written either as a Roman numeral relative to the key or as a chord name:
 *     - Roman numerals: optional "b" or "#" (also "♭" / "♯"), then I..VII. Upper case is a major-family chord,
 *       lower case a minor-family chord, counted on the key's own scale (in A minor, III is C major). Upper-case
 *       suffixes: none (major), "7" (dominant 7), "maj7", "aug" or "+", "sus2", "sus4". Lower-case suffixes: none
 *       (minor), "7" (minor 7), "dim" or "°", "dim7" or "°7", "m7b5" or "ø" / "ø7" (half-diminished),
 *       "sus2", "sus4". Roman numerals have no slash form.
 *     - Chord names: root A..G (capital) with optional "#" or "b" (also "♯" / "♭"), then "", "m", "dim" (or
 *       "°"), "aug" (or "+"), "sus2", "sus4", "7", "maj7", "m7", "m7b5" (or "m7♭5", "ø", "ø7"), "dim7" (or "°7"),
 *       then an optional slash bass note ("C/E"): the bass plays the note after the slash.
 *   resolveChord() gives a chord's root, bass and pitch classes in a key; chordLabel() shows it in both forms
 *   ("ii · Dm"). Roman-numeral chords follow the key (their names change with it); chord names keep the
 *   spelling the user typed.
 *   Preset progressions (T04/T16) are stored as Roman-numeral text, so they follow the chosen key; only the presets of
 *   the key's mode are offered.
 *
 * Real-Time & Safety Contract:
 *   UI/off-RT only. Pure @safe functions; strings and arrays are GC-allocated.
 *
 * Dependencies:
 *   Internal: app.music_theory
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum ChordQuality / enum ChordForm; struct Chord; struct ChordBlock (halfBars); struct ProgressionError;
 *     struct ResolvedChord
 *   - parseChord(), parseProgression(), chordIntervals(), resolveChord(), romanLabel(), nameLabel(), chordLabel()
 *   - struct ProgressionPreset; PROGRESSION_PRESETS; presetsFor(), presetBlocks(), presetLabel() (T16)
 *
 * See_Also:
 *   docs/todo.md (T03, T05, T14, T16), source/app/music_theory.d
 */
module app.chord_progression;

import app.music_theory : degreePitchClass, KeyMode, MusicalKey, pitchClassName, scalePitchClasses;

/**
 * Chord quality (the stack of intervals above the root).
 */
enum ChordQuality : ubyte {
    major = 0,
    minor = 1,
    diminished = 2,
    augmented = 3,
    sus2 = 4,
    sus4 = 5,
    dominant7 = 6,
    major7 = 7,
    minor7 = 8,
    halfDiminished7 = 9,
    diminished7 = 10
}

/**
 * How a chord was written: as a Roman numeral relative to the key, or as a chord name.
 */
enum ChordForm : ubyte {
    roman = 0,
    name = 1
}

/**
 * One chord as typed. Roman chords store a scale degree and a chromatic shift; named chords store their root
 * and optional bass pitch classes together with the spelling the user typed.
 */
struct Chord {
    ChordForm form = ChordForm.roman;
    ChordQuality quality = ChordQuality.major;
    ubyte degree = 1;
    byte shift = 0;
    ubyte rootPc = 0;
    string rootText;
    bool hasBass = false;
    ubyte bassPc = 0;
    string bassText;
    string text;
}

/**
 * One block of a progression: a chord and how long it lasts, in half bars (1 = ½ bar, 2 = 1 bar, 4 = 2 bars,
 * 8 = 4 bars; T05).
 */
struct ChordBlock {
    Chord chord;
    ubyte halfBars = 2;
}

/**
 * Where and why parsing a progression failed.
 */
struct ProgressionError {
    size_t position = 0;
    size_t length = 0;
    string message;
}

/**
 * A chord placed in a key: root, bass (the root unless a slash bass was given) and every pitch class of the
 * chord from the root up in stacking order (3 for triads and sus chords, 4 for sevenths).
 */
struct ResolvedChord {
    ubyte rootPc = 0;
    ubyte bassPc = 0;
    ubyte[] pitchClasses;
}

/**
 * Block lengths a block may have, in half bars.
 */
immutable ubyte[4] BLOCK_HALF_BARS = [1, 2, 4, 8];

private immutable ubyte[][11] INTERVALS = [
    [0, 4, 7], [0, 3, 7], [0, 3, 6], [0, 4, 8], [0, 2, 7], [0, 5, 7],
    [0, 4, 7, 10], [0, 4, 7, 11], [0, 3, 7, 10], [0, 3, 6, 10], [0, 3, 6, 9]
];
private immutable string[11] NAME_SUFFIX = ["", "m", "dim", "aug", "sus2", "sus4", "7", "maj7", "m7", "m7b5",
    "dim7"];
private immutable string[11] ROMAN_SUFFIX = ["", "", "°", "+", "sus2", "sus4", "7", "maj7", "7", "ø7", "°7"];
private immutable bool[11] ROMAN_UPPER = [true, false, false, true, true, true, true, true, false, false, false];
private immutable string[7] NUMERALS = ["I", "II", "III", "IV", "V", "VI", "VII"];
private immutable ubyte[7] LETTER_PC = [9, 11, 0, 2, 4, 5, 7];

private struct SuffixEntry {
    string text;
    ChordQuality quality;
}

private immutable SuffixEntry[] NAME_SUFFIXES = [
    SuffixEntry("", ChordQuality.major), SuffixEntry("m", ChordQuality.minor),
    SuffixEntry("dim", ChordQuality.diminished), SuffixEntry("°", ChordQuality.diminished),
    SuffixEntry("aug", ChordQuality.augmented), SuffixEntry("+", ChordQuality.augmented),
    SuffixEntry("sus2", ChordQuality.sus2), SuffixEntry("sus4", ChordQuality.sus4),
    SuffixEntry("7", ChordQuality.dominant7), SuffixEntry("maj7", ChordQuality.major7),
    SuffixEntry("m7", ChordQuality.minor7), SuffixEntry("m7b5", ChordQuality.halfDiminished7),
    SuffixEntry("m7♭5", ChordQuality.halfDiminished7), SuffixEntry("ø", ChordQuality.halfDiminished7),
    SuffixEntry("ø7", ChordQuality.halfDiminished7), SuffixEntry("dim7", ChordQuality.diminished7),
    SuffixEntry("°7", ChordQuality.diminished7)
];

private immutable SuffixEntry[] UPPER_ROMAN_SUFFIXES = [
    SuffixEntry("", ChordQuality.major), SuffixEntry("7", ChordQuality.dominant7),
    SuffixEntry("maj7", ChordQuality.major7), SuffixEntry("aug", ChordQuality.augmented),
    SuffixEntry("+", ChordQuality.augmented), SuffixEntry("sus2", ChordQuality.sus2),
    SuffixEntry("sus4", ChordQuality.sus4)
];

private immutable SuffixEntry[] LOWER_ROMAN_SUFFIXES = [
    SuffixEntry("", ChordQuality.minor), SuffixEntry("7", ChordQuality.minor7),
    SuffixEntry("dim", ChordQuality.diminished), SuffixEntry("°", ChordQuality.diminished),
    SuffixEntry("dim7", ChordQuality.diminished7), SuffixEntry("°7", ChordQuality.diminished7),
    SuffixEntry("m7b5", ChordQuality.halfDiminished7), SuffixEntry("m7♭5", ChordQuality.halfDiminished7),
    SuffixEntry("ø", ChordQuality.halfDiminished7), SuffixEntry("ø7", ChordQuality.halfDiminished7),
    SuffixEntry("sus2", ChordQuality.sus2), SuffixEntry("sus4", ChordQuality.sus4)
];

/**
 * Returns the semitone offsets of a quality above its root, ascending from 0.
 *
 * Params:
 *   q = Quality.
 *
 * Returns:
 *   Three or four offsets.
 */
immutable(ubyte)[] chordIntervals(ChordQuality q) @safe pure nothrow @nogc {
    return INTERVALS[q];
}

/**
 * Parses one chord token (no separators inside).
 *
 * Params:
 *   token = Chord text, e.g. "ii7", "bVII", "Dm7", "C/E".
 *   c = Receives the chord.
 *   reason = Receives a sentence explaining a failure.
 *
 * Returns:
 *   True on success.
 */
bool parseChord(string token, out Chord c, out string reason) @safe pure nothrow {
    if (token.length == 0) {
        reason = "Empty chord";
        return false;
    }
    immutable char first = token[0];
    if (first >= 'A' && first <= 'G') {
        return parseChordName(token, c, reason);
    }
    if (first >= 'a' && first <= 'g' && first != 'b') {
        reason = "Chord names start with a capital letter A–G";
        return false;
    }
    return parseRoman(token, c, reason);
}

/**
 * Parses a whole progression: chords separated by spaces, commas, "-" or "->". Every chord becomes a block of
 * one bar. Empty text gives no blocks.
 *
 * Params:
 *   text = Progression text, e.g. "iii -> vi -> ii -> V -> I" or "Dm7, G7, Cmaj7".
 *   blocks = Receives the blocks (empty on failure).
 *   err = Receives the byte position, byte length and reason of the first bad chord.
 *
 * Returns:
 *   True when every chord parsed.
 */
bool parseProgression(string text, out ChordBlock[] blocks, out ProgressionError err) @safe pure nothrow {
    size_t i = 0;
    ChordBlock[] result;
    while (i < text.length) {
        immutable char ch = text[i];
        if (isSeparator(ch)) {
            i++;
            continue;
        }
        if (ch == '>') {
            if (i == 0 || text[i - 1] != '-') {
                err = ProgressionError(i, 1, "Unexpected \">\"; separate chords with spaces, commas, - or ->");
                return false;
            }
            i++;
            continue;
        }
        immutable size_t start = i;
        while (i < text.length && !isSeparator(text[i]) && text[i] != '>') {
            i++;
        }
        Chord c;
        string reason;
        if (!parseChord(text[start .. i], c, reason)) {
            err = ProgressionError(start, i - start, "\"" ~ text[start .. i] ~ "\": " ~ reason);
            return false;
        }
        result ~= ChordBlock(c, 2);
    }
    blocks = result;
    return true;
}

/**
 * Places a chord in a key.
 *
 * Params:
 *   c = Chord.
 *   key = Song key (Roman numerals count on its scale; chord names ignore it).
 *
 * Returns:
 *   Root, bass and pitch classes.
 */
ResolvedChord resolveChord(const ref Chord c, MusicalKey key) @safe pure nothrow {
    ResolvedChord r;
    r.rootPc = c.form == ChordForm.roman ? cast(ubyte)((degreePitchClass(key, c.degree) + c.shift + 12) % 12)
        : c.rootPc;
    r.bassPc = c.hasBass ? c.bassPc : r.rootPc;
    foreach (iv; chordIntervals(c.quality)) {
        r.pitchClasses ~= cast(ubyte)((r.rootPc + iv) % 12);
    }
    return r;
}

/**
 * Returns the Roman-numeral form of a chord in a key ("ii", "V7", "bVII", "vii°"). A named chord gets the
 * numeral of the scale degree its root falls on; a root outside the scale is written as a flattened degree
 * (Bb in C major is "bVII") or, when only that fits, a sharpened one. A slash bass is not shown.
 *
 * Params:
 *   c = Chord.
 *   key = Song key.
 *
 * Returns:
 *   Text.
 */
string romanLabel(const ref Chord c, MusicalKey key) @safe pure nothrow {
    ubyte degree = c.degree;
    int shift = c.shift;
    if (c.form == ChordForm.name) {
        findDegree(c.rootPc, key, degree, shift);
    }
    string numeral = NUMERALS[(degree - 1) % 7];
    if (!ROMAN_UPPER[c.quality]) {
        numeral = lowerAscii(numeral);
    }
    return accidentalText(shift) ~ numeral ~ ROMAN_SUFFIX[c.quality];
}

/**
 * Returns the chord-name form ("Dm", "G7", "Bb", "C/E"). Roman chords are spelled for the key (bVII in C major is
 * "Bb"); named chords keep the root and bass spelling the user typed, with the quality written canonically.
 *
 * Params:
 *   c = Chord.
 *   key = Song key.
 *
 * Returns:
 *   Text.
 */
string nameLabel(const ref Chord c, MusicalKey key) @safe pure nothrow {
    if (c.form == ChordForm.name) {
        return c.rootText ~ NAME_SUFFIX[c.quality] ~ (c.hasBass ? "/" ~ c.bassText : "");
    }
    immutable ubyte[7] pcs = scalePitchClasses(key);
    immutable string base = pitchClassName(pcs[(c.degree - 1) % 7], key);
    return base[0 .. 1] ~ accidentalText(accidentalOf(base) + c.shift) ~ NAME_SUFFIX[c.quality];
}

/**
 * Returns the label shown on a chord block: both forms, Roman numeral first ("ii · Dm").
 *
 * Params:
 *   c = Chord.
 *   key = Song key.
 *
 * Returns:
 *   Text.
 */
string chordLabel(const ref Chord c, MusicalKey key) @safe pure nothrow {
    return romanLabel(c, key) ~ " · " ~ nameLabel(c, key);
}

private bool parseChordName(string token, out Chord c, out string reason) @safe pure nothrow {
    size_t slash = token.length;
    foreach (i, ch; token) {
        if (ch == '/') {
            slash = i;
            break;
        }
    }
    string rootText;
    ubyte rootPc;
    size_t used;
    if (!readNote(token[0 .. slash], rootText, rootPc, used)) {
        reason = "Chord names start with a capital letter A–G";
        return false;
    }
    immutable string suffix = token[used .. slash];
    bool found = false;
    foreach (ref e; NAME_SUFFIXES) {
        if (e.text == suffix) {
            c.quality = e.quality;
            found = true;
            break;
        }
    }
    if (!found) {
        reason = "Unknown chord type \"" ~ suffix ~ "\" (use m, dim, aug, sus2, sus4, 7, maj7, m7, m7b5 or dim7)";
        return false;
    }
    c.form = ChordForm.name;
    c.rootPc = rootPc;
    c.rootText = rootText;
    c.text = token;
    if (slash < token.length) {
        immutable string bassPart = token[slash + 1 .. $];
        string bassText;
        ubyte bassPc;
        size_t bassUsed;
        if (!readNote(bassPart, bassText, bassPc, bassUsed) || bassUsed != bassPart.length) {
            reason = "After \"/\" write a bass note such as E or Bb";
            return false;
        }
        c.hasBass = true;
        c.bassPc = bassPc;
        c.bassText = bassText;
    }
    return true;
}

private bool parseRoman(string token, out Chord c, out string reason) @safe pure nothrow {
    size_t i = 0;
    int shift = 0;
    if (startsWith(token, "b") || startsWith(token, "#")) {
        shift = token[0] == 'b' ? -1 : 1;
        i = 1;
    } else if (startsWith(token, "♭") || startsWith(token, "♯")) {
        shift = startsWith(token, "♭") ? -1 : 1;
        i = "♭".length;
    }
    immutable size_t numStart = i;
    while (i < token.length && (token[i] == 'I' || token[i] == 'V' || token[i] == 'i' || token[i] == 'v')) {
        i++;
    }
    immutable string numeral = token[numStart .. i];
    if (numeral.length == 0) {
        reason = "Not a chord: write a Roman numeral (I–VII, i–vii) or a chord name (C, Dm, G7)";
        return false;
    }
    immutable bool upper = numeral[0] == 'I' || numeral[0] == 'V';
    foreach (ch; numeral) {
        if ((ch == 'I' || ch == 'V') != upper) {
            reason = "Mixed upper and lower case in a Roman numeral";
            return false;
        }
    }
    immutable string up = upperAscii(numeral);
    ubyte degree = 0;
    foreach (d, n; NUMERALS) {
        if (n == up) {
            degree = cast(ubyte)(d + 1);
        }
    }
    if (degree == 0) {
        reason = "Roman numerals go from I to VII";
        return false;
    }
    immutable string suffix = token[i .. $];
    foreach (ch; suffix) {
        if (ch == '/') {
            reason = "Roman numerals have no slash form; type a chord name such as C/E";
            return false;
        }
    }
    const(SuffixEntry)[] table = upper ? UPPER_ROMAN_SUFFIXES : LOWER_ROMAN_SUFFIXES;
    foreach (ref e; table) {
        if (e.text == suffix) {
            c.form = ChordForm.roman;
            c.quality = e.quality;
            c.degree = degree;
            c.shift = cast(byte) shift;
            c.text = token;
            return true;
        }
    }
    foreach (ref e; upper ? LOWER_ROMAN_SUFFIXES : UPPER_ROMAN_SUFFIXES) {
        if (e.text == suffix && suffix.length > 0) {
            reason = upper ? "Write diminished and half-diminished chords in lower case (vii°)"
                : "Write major, dominant 7, maj7 and augmented chords in upper case (V7)";
            return false;
        }
    }
    reason = "Unknown chord type \"" ~ suffix ~ "\"";
    return false;
}

private bool readNote(string s, out string text, out ubyte pc, out size_t used) @safe pure nothrow {
    if (s.length == 0 || s[0] < 'A' || s[0] > 'G') {
        return false;
    }
    int value = LETTER_PC[s[0] - 'A'];
    used = 1;
    string acc;
    if (s.length > 1 && (s[1] == '#' || s[1] == 'b')) {
        value += s[1] == '#' ? 1 : -1;
        acc = s[1] == '#' ? "#" : "b";
        used = 2;
    } else if (startsWith(s[1 .. $], "♯") || startsWith(s[1 .. $], "♭")) {
        immutable bool sharp = startsWith(s[1 .. $], "♯");
        value += sharp ? 1 : -1;
        acc = sharp ? "#" : "b";
        used = 1 + "♯".length;
    }
    text = s[0 .. 1] ~ acc;
    pc = cast(ubyte)((value + 12) % 12);
    return true;
}

private void findDegree(ubyte pc, MusicalKey key, out ubyte degree, out int shift) @safe pure nothrow @nogc {
    static immutable int[3] preference = [0, -1, 1];
    immutable ubyte[7] pcs = scalePitchClasses(key);
    foreach (want; preference) {
        foreach (d; 0 .. 7) {
            if ((pcs[d] + want + 12) % 12 == pc) {
                degree = cast(ubyte)(d + 1);
                shift = want;
                return;
            }
        }
    }
    degree = 1;
    shift = 0;
}

private bool isSeparator(char ch) @safe pure nothrow @nogc {
    return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ',' || ch == '-';
}

private bool startsWith(string s, string prefix) @safe pure nothrow @nogc {
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

private int accidentalOf(string noteName) @safe pure nothrow @nogc {
    int a = 0;
    foreach (ch; noteName[1 .. $]) {
        a += ch == '#' ? 1 : (ch == 'b' ? -1 : 0);
    }
    return a;
}

private string accidentalText(int a) @safe pure nothrow {
    string t;
    foreach (_; 0 .. (a < 0 ? -a : a)) {
        t ~= a < 0 ? "b" : "#";
    }
    return t;
}

private string upperAscii(string s) @safe pure nothrow {
    char[] r = s.dup;
    foreach (ref ch; r) {
        if (ch >= 'a' && ch <= 'z') {
            ch = cast(char)(ch - 32);
        }
    }
    return r.idup;
}

private string lowerAscii(string s) @safe pure nothrow {
    char[] r = s.dup;
    foreach (ref ch; r) {
        if (ch >= 'A' && ch <= 'Z') {
            ch = cast(char)(ch + 32);
        }
    }
    return r.idup;
}

/**
 * A widely used progression offered in the generator's preset dropdown. The text is ordinary progression syntax
 * (Roman numerals), so it parses with parseProgression() and follows the chosen key.
 */
struct ProgressionPreset {
    string name;
    KeyMode mode;
    string text;
}

/**
 * The preset progressions decided in T04: eight for major keys, three for minor keys.
 */
immutable ProgressionPreset[] PROGRESSION_PRESETS = [
    ProgressionPreset("Circle of fifths", KeyMode.major, "iii - vi - ii - V - I"),
    ProgressionPreset("Pop", KeyMode.major, "I - V - vi - IV"),
    ProgressionPreset("Fifties", KeyMode.major, "I - vi - IV - V"),
    ProgressionPreset("Pop (minor start)", KeyMode.major, "vi - IV - I - V"),
    ProgressionPreset("Three chords", KeyMode.major, "I - IV - V"),
    ProgressionPreset("Jazz ii-V-I", KeyMode.major, "ii - V - I"),
    ProgressionPreset("Canon", KeyMode.major, "I - V - vi - iii - IV - I - IV - V"),
    ProgressionPreset("12-bar blues", KeyMode.major, "I7 - I7 - I7 - I7 - IV7 - IV7 - I7 - I7 - V7 - IV7 - I7 - V7"),
    ProgressionPreset("Minor pop", KeyMode.minor, "i - VI - III - VII"),
    ProgressionPreset("Minor three chords", KeyMode.minor, "i - iv - v"),
    ProgressionPreset("Andalusian cadence", KeyMode.minor, "i - VII - VI - V")
];

/**
 * Lists the presets offered for a mode, in table order.
 *
 * Params:
 *   mode = Mode of the chosen key.
 *
 * Returns:
 *   Presets of that mode.
 */
const(ProgressionPreset)[] presetsFor(KeyMode mode) @safe pure nothrow {
    const(ProgressionPreset)[] list;
    foreach (ref p; PROGRESSION_PRESETS) {
        if (p.mode == mode) {
            list ~= p;
        }
    }
    return list;
}

/**
 * Returns a preset's chords as blocks of one bar each.
 *
 * Params:
 *   p = Preset.
 *
 * Returns:
 *   Blocks (never empty for a table entry; the table is checked by unit tests).
 */
ChordBlock[] presetBlocks(const ref ProgressionPreset p) @safe pure nothrow {
    ChordBlock[] blocks;
    ProgressionError err;
    if (!parseProgression(p.text, blocks, err)) {
        return null;
    }
    return blocks;
}

/**
 * Returns the dropdown text of a preset: its name and its chords, e.g. "Circle of fifths: iii - vi - ii - V - I".
 *
 * Params:
 *   p = Preset.
 *
 * Returns:
 *   Label.
 */
string presetLabel(const ref ProgressionPreset p) @safe pure nothrow {
    return p.name ~ ": " ~ p.text;
}
