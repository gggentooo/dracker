/**
 * File:         source/sequencer/note.d
 * Module:       sequencer.note
 * Phase:        Phase 5.1 — Tracker NoteCell, NoteCmd & EffectCode Definitions
 *
 * Purpose:
 *   Defines the compact 8-byte POD NoteCell layout (note, velocity, moduleId, paramId, effect, effectVal) and explicit EffectCode enum covering tracker slides, vibrato, arp, retrigger, cut, probability, and sub-line delay.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow pure @safe POD structs; static assert(NoteCell.sizeof == 8) for atomic cell patching.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: std.traits (hasIndirections)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum NoteCmd : ubyte { empty, noteOff, allNotesOff, prevTrack, setPitch, stopSong }
 *   - enum EffectCode : ubyte { slideUp = 0x01, ..., subLineDelayBase = 0x40, subLineDelayMax = 0x5F }
 *   - struct NoteCell : 8-byte atomic-packable tracker cell
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.note;

import std.traits : hasIndirections;

/**
 * Special tracker note-column command codes stored outside the MIDI [1..128] note range.
 */
enum NoteCmd : ubyte {
    empty = 0,
    noteOff = 240,
    allNotesOff = 241,
    prevTrack = 242,
    setPitch = 243,
    stopSong = 244
}

/**
 * Tracker effect column command codes modeled after ProTracker/SunVox idioms.
 */
enum EffectCode : ubyte {
    none = 0x00,
    slideUp = 0x01,
    slideDown = 0x02,
    portamento = 0x03,
    vibrato = 0x04,
    pitchOffsetUp = 0x05,
    pitchOffsetDown = 0x06,
    sampleOffset = 0x07,
    arpeggio = 0x08,
    sampleOffsetFine = 0x09,
    velocitySlide = 0x0A,
    setSpeed = 0x0F,
    fineSlideUp = 0x11,
    fineSlideDown = 0x12,
    bypassModule = 0x13,
    muteModule = 0x14,
    retrigger = 0x19,
    noteCut = 0x1C,
    noteDelay = 0x1D,
    setBpm = 0x1F,
    probabilityBase = 0x20,
    probabilityMax = 0x2F,
    stopSong = 0x30,
    jumpLine = 0x31,
    subLineDelayBase = 0x40,
    subLineDelayMax = 0x5F
}

/**
 * Compact 8-byte tracker pattern cell suited for atomic 64-bit live editing on the RT path.
 *
 * Encoding conventions:
 *   note: 0 = empty, 1..128 = MIDI note + 1 (so 61 == MIDI 60 C4), >= 240 = NoteCmd.
 *   velocity: 0 = default/inherit, 1..255 = normalized velocity in [0.0f, 1.0f].
 *   moduleId: 0 = inherit track module, >= 1 = target graph ModuleId.
 *   paramId: 0 = none, >= 1 = 1-based parameter index (paramId - 1) on target module.
 *   effect / effectVal: EffectCode command and 8-bit parameter operand.
 */
struct NoteCell {
    ubyte note = 0;
    ubyte velocity = 0;
    ushort moduleId = 0;
    ushort paramId = 0;
    ubyte effect = 0;
    ubyte effectVal = 0;

    @nogc nothrow pure @safe:

    /**
     * Packs all fields of this 8-byte NoteCell into a single 64-bit unsigned integer.
     *
     * Returns:
     *   64-bit bit-packed representation suitable for atomic store.
     */
    ulong packU64() const {
        return cast(ulong) note
            | (cast(ulong) velocity << 8)
            | (cast(ulong) moduleId << 16)
            | (cast(ulong) paramId << 32)
            | (cast(ulong) effect << 48)
            | (cast(ulong) effectVal << 56);
    }

    /**
     * Unpacks a 64-bit representation produced by packU64() into a NoteCell.
     *
     * Params:
     *   bits = Packed 64-bit cell word.
     *
     * Returns:
     *   Decoded NoteCell struct.
     */
    static NoteCell unpackU64(ulong bits) {
        NoteCell cell;
        cell.note = cast(ubyte)(bits & 0xFFu);
        cell.velocity = cast(ubyte)((bits >> 8) & 0xFFu);
        cell.moduleId = cast(ushort)((bits >> 16) & 0xFFFFu);
        cell.paramId = cast(ushort)((bits >> 32) & 0xFFFFu);
        cell.effect = cast(ubyte)((bits >> 48) & 0xFFu);
        cell.effectVal = cast(ubyte)((bits >> 56) & 0xFFu);
        return cell;
    }

    /**
     * Encodes a MIDI note number [0..127] into the NoteCell note byte [1..128].
     *
     * Params:
     *   midi = MIDI note number clamped to [0..127].
     *
     * Returns:
     *   Encoded non-zero note field byte.
     */
    static ubyte encodeMidiNote(int midi) {
        int m = midi;
        if (m < 0) m = 0;
        if (m > 127) m = 127;
        return cast(ubyte)(m + 1);
    }

    /**
     * Encodes a normalized velocity [0.0f..1.0f] into the NoteCell velocity byte [1..255].
     *
     * Params:
     *   vel = Normalized note velocity.
     *
     * Returns:
     *   Encoded non-zero velocity byte.
     */
    static ubyte encodeVelocity(float vel) {
        float v = vel;
        if (!(v >= 0.0f)) v = 0.0f;
        if (v > 1.0f) v = 1.0f;
        int scaled = cast(int)(v * 254.0f + 0.5f) + 1;
        if (scaled < 1) scaled = 1;
        if (scaled > 255) scaled = 255;
        return cast(ubyte) scaled;
    }

    /**
     * Constructs a MIDI NoteOn NoteCell with optional effect column.
     *
     * Params:
     *   midi = MIDI note number [0..127].
     *   vel = Normalized velocity in [0.0f..1.0f].
     *   modId = 1-based target ModuleId (or 0 to inherit track module).
     *   fx = EffectCode command byte.
     *   fxVal = 8-bit effect operand.
     *
     * Returns:
     *   Populated NoteCell.
     */
    static NoteCell makeNote(
        int midi,
        float vel = 1.0f,
        ushort modId = 0,
        ubyte fx = 0,
        ubyte fxVal = 0
    ) {
        NoteCell c;
        c.note = encodeMidiNote(midi);
        c.velocity = encodeVelocity(vel);
        c.moduleId = modId;
        c.effect = fx;
        c.effectVal = fxVal;
        return c;
    }

    /**
     * Constructs a NoteOff NoteCell with optional sub-line or tick delay effect.
     *
     * Params:
     *   modId = Target ModuleId (0 for current track module).
     *   fx = Optional EffectCode (such as sub-line delay 0x40..0x5F).
     *   fxVal = 8-bit effect operand.
     *
     * Returns:
     *   Populated NoteOff NoteCell.
     */
    static NoteCell makeNoteOff(ushort modId = 0, ubyte fx = 0, ubyte fxVal = 0) {
        NoteCell c;
        c.note = NoteCmd.noteOff;
        c.moduleId = modId;
        c.effect = fx;
        c.effectVal = fxVal;
        return c;
    }

    /**
     * Constructs a parameter-automation NoteCell targeting 0-based paramIdx on modId.
     *
     * Params:
     *   modId = Target graph ModuleId (>= 1).
     *   paramIdx = Zero-based parameter index encoded as paramIdx + 1.
     *   norm01 = Normalized value [0.0f..1.0f] stored in effectVal [0..255].
     *   fx = Optional effect command (defaults to EffectCode.none or subLineDelay).
     *
     * Returns:
     *   Populated parameter automation NoteCell.
     */
    static NoteCell makeParam(ushort modId, ushort paramIdx, float norm01, ubyte fx = 0) {
        NoteCell c;
        c.moduleId = modId;
        c.paramId = cast(ushort)(paramIdx + 1);
        float n = norm01;
        if (!(n >= 0.0f)) n = 0.0f;
        if (n > 1.0f) n = 1.0f;
        c.effect = fx;
        c.effectVal = cast(ubyte)(n * 255.0f + 0.5f);
        return c;
    }

    /**
     * Constructs an effect-only NoteCell on the current track.
     *
     * Params:
     *   fx = EffectCode command byte.
     *   fxVal = 8-bit operand.
     *   modId = Optional ModuleId override.
     *
     * Returns:
     *   Populated effect NoteCell.
     */
    static NoteCell makeEffect(ubyte fx, ubyte fxVal = 0, ushort modId = 0) {
        NoteCell c;
        c.moduleId = modId;
        c.effect = fx;
        c.effectVal = fxVal;
        return c;
    }

    /**
     * Reports whether note holds a valid MIDI note [1..128].
     *
     * Returns:
     *   True if note encodes MIDI 0..127.
     */
    bool isMidiNote() const {
        return note >= 1 && note <= 128;
    }

    /**
     * Returns the decoded 0-based MIDI note number [0..127].
     *
     * Returns:
     *   Decoded MIDI note number when isMidiNote() is true; 0 otherwise.
     */
    ubyte midiNote() const {
        return isMidiNote() ? cast(ubyte)(note - 1) : 0;
    }

    /**
     * Decodes velocity byte into [0.0f, 1.0f], returning 0.8f when velocity == 0.
     *
     * Returns:
     *   Normalized velocity.
     */
    float normalizedVelocity() const {
        if (velocity == 0) {
            return 0.8f;
        }
        return cast(float)(velocity - 1) / 254.0f;
    }

    /**
     * Reports whether all fields of the cell are zero/inactive.
     *
     * Returns:
     *   True when completely empty.
     */
    bool isEmpty() const {
        return packU64() == 0;
    }

    /**
     * Reports whether effect falls inside the sub-line fractional delay range [0x40..0x5F].
     *
     * Returns:
     *   True if effect is a sub-line delay.
     */
    bool isSubLineDelay() const {
        return effect >= EffectCode.subLineDelayBase && effect <= EffectCode.subLineDelayMax;
    }

    /**
     * Returns the sub-line fractional delay numerator in [0..31] (/ 32 of a line).
     *
     * Returns:
     *   Sub-line step count in [0..31], or 0 if not a sub-line delay.
     */
    uint subLineDelaySteps() const {
        return isSubLineDelay() ? cast(uint)(effect - EffectCode.subLineDelayBase) : 0u;
    }

    /**
     * Reports whether effect is a trigger probability code [0x20..0x2F].
     *
     * Returns:
     *   True when effect encodes probability.
     */
    bool isProbability() const {
        return effect >= EffectCode.probabilityBase && effect <= EffectCode.probabilityMax;
    }
}

static assert(NoteCell.sizeof == 8, "NoteCell must stay exactly 8 bytes for atomic 64-bit patching");
static assert(!hasIndirections!NoteCell, "NoteCell must remain POD with zero indirections");
