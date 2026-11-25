/**
 * File:         source/app/music_theory.d
 * Module:       app.music_theory
 * Phase:        Skeleton project generator — T11 (keys, scales, and note spelling)
 *
 * Purpose:
 *   Pure music-theory helpers for the skeleton project generator: the song key (tonic pitch class + major or
 *   natural minor), the 24 selectable keys with display names, the seven scale degrees of a key as pitch
 *   classes, and note names spelled for a key. Scale tones get their diatonic spelling (one letter per degree,
 *   so F sharp major contains E sharp); other pitch classes use sharps or flats by the key's preference. Flat
 *   keys are F, Bb, Eb, Ab and Db major and their relative minors (D, G, C, F and Bb minor); every other key
 *   prefers sharps. Names use ASCII accidentals ("#" and "b"), like the pattern editor's note column.
 *
 * Real-Time & Safety Contract:
 *   UI/off-RT only. Every function is @safe pure nothrow; functions returning strings allocate them on the GC
 *   heap. No session, GUI, or I/O dependency.
 *
 * Dependencies:
 *   Internal: none
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum KeyMode (major = 0, minor = 1; the same values as io.project_format KEY_MODE_MAJOR / KEY_MODE_MINOR)
 *   - struct MusicalKey (tonic, mode; isValid())
 *   - allKeys(), keyName(), tonicName(), tonicChoices(), usesFlats(), relativeKey()
 *   - scalePitchClasses(), degreePitchClass(), pitchClassOf()
 *   - pitchClassName(), noteName()
 *
 * See_Also:
 *   docs/todo.md (T02, T11), source/gui/views/pattern_editor.d (formatNoteName)
 */
module app.music_theory;

/**
 * Scale family of a key; the numeric values are the ones stored in the .msv MUSC chunk.
 */
enum KeyMode : ubyte {
    major = 0,
    minor = 1
}

/**
 * A song key: tonic pitch class (0 = C ... 11 = B) and mode. The default is C major.
 */
struct MusicalKey {
    ubyte tonic = 0;
    KeyMode mode = KeyMode.major;

    /**
     * Reports whether the tonic is a pitch class and the mode is known.
     *
     * Returns:
     *   True if tonic < 12 and mode is major or minor.
     */
    bool isValid() const @safe pure nothrow @nogc {
        return tonic < 12 && (mode == KeyMode.major || mode == KeyMode.minor);
    }
}

private immutable ubyte[7] MAJOR_INTERVALS = [0, 2, 4, 5, 7, 9, 11];
private immutable ubyte[7] MINOR_INTERVALS = [0, 2, 3, 5, 7, 8, 10];
private immutable ubyte[7] LETTER_PITCH = [0, 2, 4, 5, 7, 9, 11];
private immutable string[7] LETTERS = ["C", "D", "E", "F", "G", "A", "B"];
private immutable string[12] SHARP_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
private immutable string[12] FLAT_NAMES = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"];
private immutable bool[12] MAJOR_FLAT_TONICS = [false, true, false, true, false, true, false, false, true, false,
    true, false];

/**
 * Lists the 24 selectable keys, by tonic from C to B, major before minor.
 *
 * Returns:
 *   All keys.
 */
MusicalKey[24] allKeys() @safe pure nothrow @nogc {
    MusicalKey[24] keys;
    foreach (t; 0 .. 12) {
        keys[2 * t] = MusicalKey(cast(ubyte) t, KeyMode.major);
        keys[2 * t + 1] = MusicalKey(cast(ubyte) t, KeyMode.minor);
    }
    return keys;
}

/**
 * Returns the relative key (same scale tones, other mode): A minor for C major, C major for A minor.
 *
 * Params:
 *   key = Valid key.
 *
 * Returns:
 *   The relative key.
 */
MusicalKey relativeKey(MusicalKey key) @safe pure nothrow @nogc {
    return key.mode == KeyMode.major ? MusicalKey(cast(ubyte)((key.tonic + 9) % 12), KeyMode.minor)
        : MusicalKey(cast(ubyte)((key.tonic + 3) % 12), KeyMode.major);
}

/**
 * Reports whether a key prefers flats: F, Bb, Eb, Ab, Db major and their relative minors.
 *
 * Params:
 *   key = Valid key.
 *
 * Returns:
 *   True for flat keys.
 */
bool usesFlats(MusicalKey key) @safe pure nothrow @nogc {
    immutable ubyte majorTonic = key.mode == KeyMode.major ? key.tonic : relativeKey(key).tonic;
    return MAJOR_FLAT_TONICS[majorTonic % 12];
}

/**
 * Returns the seven scale tones of a key as pitch classes, from the tonic up.
 *
 * Params:
 *   key = Valid key.
 *
 * Returns:
 *   Pitch classes of degrees 1 to 7.
 */
ubyte[7] scalePitchClasses(MusicalKey key) @safe pure nothrow @nogc {
    ubyte[7] pcs;
    const ubyte[7] iv = key.mode == KeyMode.major ? MAJOR_INTERVALS : MINOR_INTERVALS;
    foreach (i; 0 .. 7) {
        pcs[i] = cast(ubyte)((key.tonic + iv[i]) % 12);
    }
    return pcs;
}

/**
 * Returns the pitch class of one scale degree; degrees above 7 wrap (8 is the tonic again).
 *
 * Params:
 *   key = Valid key.
 *   degree = Scale degree, 1 = tonic.
 *
 * Returns:
 *   Pitch class, or the tonic when degree is 0.
 */
ubyte degreePitchClass(MusicalKey key, uint degree) @safe pure nothrow @nogc {
    if (degree == 0) {
        return key.tonic;
    }
    return scalePitchClasses(key)[(degree - 1) % 7];
}

/**
 * Returns the pitch class of a MIDI note number (negative numbers wrap correctly).
 *
 * Params:
 *   midi = MIDI note number (60 = middle C).
 *
 * Returns:
 *   Pitch class 0..11.
 */
ubyte pitchClassOf(int midi) @safe pure nothrow @nogc {
    return cast(ubyte)(((midi % 12) + 12) % 12);
}

/**
 * Returns the tonic's name as spelled in its key ("C", "F#", "Bb").
 *
 * Params:
 *   tonic = Tonic pitch class.
 *   mode = Mode (decides sharps or flats).
 *
 * Returns:
 *   Name.
 */
string tonicName(ubyte tonic, KeyMode mode) @safe pure nothrow {
    immutable MusicalKey key = MusicalKey(tonic, mode);
    return (usesFlats(key) ? FLAT_NAMES : SHARP_NAMES)[tonic % 12];
}

/**
 * Lists the tonic names for one mode in pitch-class order, for a tonic dropdown next to a mode dropdown.
 *
 * Params:
 *   mode = Mode.
 *
 * Returns:
 *   Twelve names; index = pitch class.
 */
string[12] tonicChoices(KeyMode mode) @safe pure nothrow {
    string[12] names;
    foreach (t; 0 .. 12) {
        names[t] = tonicName(cast(ubyte) t, mode);
    }
    return names;
}

/**
 * Returns the display name of a key ("C major", "F# minor", "Bb major").
 *
 * Params:
 *   key = Valid key.
 *
 * Returns:
 *   Name.
 */
string keyName(MusicalKey key) @safe pure nothrow {
    return tonicName(key.tonic, key.mode) ~ (key.mode == KeyMode.major ? " major" : " minor");
}

/**
 * Spells a pitch class for a key. Scale tones get their diatonic spelling (E# in F# major); other pitch
 * classes use the key's accidental preference (Bb in F major, A# in A minor).
 *
 * Params:
 *   pc = Pitch class (taken modulo 12).
 *   key = Valid key.
 *
 * Returns:
 *   Name without octave.
 */
string pitchClassName(ubyte pc, MusicalKey key) @safe pure nothrow {
    int accidental = 0;
    size_t letter = 0;
    spell(cast(ubyte)(pc % 12), key, letter, accidental);
    return LETTERS[letter] ~ accidentalText(accidental);
}

/**
 * Spells a MIDI note with its octave for a key ("C4" for 60 in C major, "Bb3" for 58 in F major). The octave
 * belongs to the letter, so E#4 sounds as F4 and middle C is C4, as in the pattern editor.
 *
 * Params:
 *   midi = MIDI note number in [0, 127].
 *   key = Valid key.
 *
 * Returns:
 *   Name with octave.
 */
string noteName(int midi, MusicalKey key) @safe pure nothrow {
    int accidental = 0;
    size_t letter = 0;
    spell(pitchClassOf(midi), key, letter, accidental);
    immutable int letterMidi = midi - accidental;
    immutable int octave = (letterMidi >= 0 ? letterMidi / 12 : (letterMidi - 11) / 12) - 1;
    return LETTERS[letter] ~ accidentalText(accidental) ~ intText(octave);
}

/**
 * Formats a small integer in decimal.
 *
 * Params:
 *   v = Value.
 *
 * Returns:
 *   Decimal text with a leading "-" when negative.
 */
private string intText(int v) @safe pure nothrow {
    if (v < 0) {
        return "-" ~ intText(-v);
    }
    if (v < 10) {
        return [cast(immutable char)('0' + v)];
    }
    return intText(v / 10) ~ intText(v % 10);
}

/**
 * Finds the letter (0 = C ... 6 = B) and accidental (-2..2 semitones) of a pitch class in a key.
 *
 * Params:
 *   pc = Pitch class 0..11.
 *   key = Valid key.
 *   letter = Receives the letter index.
 *   accidental = Receives the accidental in semitones (+1 = sharp, -1 = flat).
 */
private void spell(ubyte pc, MusicalKey key, out size_t letter, out int accidental) @safe pure nothrow {
    immutable ubyte[7] pcs = scalePitchClasses(key);
    immutable size_t tonicLetter = letterOf(tonicName(key.tonic, key.mode));
    foreach (d; 0 .. 7) {
        if (pcs[d] == pc) {
            letter = (tonicLetter + d) % 7;
            accidental = signedDiff(pc, LETTER_PITCH[letter]);
            return;
        }
    }
    immutable string name = (usesFlats(key) ? FLAT_NAMES : SHARP_NAMES)[pc];
    letter = letterOf(name);
    accidental = name.length == 1 ? 0 : (name[1] == '#' ? 1 : -1);
}

/**
 * Returns the letter index of a note name's first character.
 *
 * Params:
 *   name = Note name starting with A..G.
 *
 * Returns:
 *   0 for C ... 6 for B.
 */
private size_t letterOf(string name) @safe pure nothrow @nogc {
    foreach (i, l; LETTERS) {
        if (l[0] == name[0]) {
            return i;
        }
    }
    return 0;
}

/**
 * Returns pc minus natural as the nearest signed distance in semitones.
 *
 * Params:
 *   pc = Target pitch class.
 *   natural = Pitch class of the plain letter.
 *
 * Returns:
 *   Distance in [-5, 6].
 */
private int signedDiff(ubyte pc, ubyte natural) @safe pure nothrow @nogc {
    int d = (cast(int) pc - cast(int) natural + 12) % 12;
    return d > 6 ? d - 12 : d;
}

/**
 * Returns the ASCII text of an accidental.
 *
 * Params:
 *   accidental = Semitones (+1 sharp, -1 flat, +-2 double).
 *
 * Returns:
 *   "", "#", "##", "b" or "bb".
 */
private string accidentalText(int accidental) @safe pure nothrow @nogc {
    switch (accidental) {
        case 1:
            return "#";
        case 2:
            return "##";
        case -1:
            return "b";
        case -2:
            return "bb";
        default:
            return "";
    }
}
