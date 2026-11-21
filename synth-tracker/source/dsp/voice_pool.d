/**
 * File:         source/dsp/voice_pool.d
 * Module:       dsp.voice_pool
 * Phase:        Phase 1.5 — Shared Polyphonic Voice Allocator
 *
 * Purpose:
 *   Centralizes polyphonic NoteId tracking, per-note pitch/velocity updates, deterministic voice stealing, and release-tail cleanup for AnalogGen, FmSynth, Sampler, and SpectraVoice.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; fixed compile-time MaxVoices capacity with zero heap allocation and zero GC indirections.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct VoicePool(VoiceT, size_t MaxVoices)
 *   - void setMaxPolyphony(size_t limit) / size_t maxPolyphony() const
 *   - VoiceT* allocateVoice(NoteId id, out bool stolen) @nogc nothrow
 *   - VoiceT* findVoice(NoteId id) @nogc nothrow
 *   - bool releaseVoice(NoteId id) @nogc nothrow
 *   - void allNotesOff() @nogc nothrow
 *   - void resetAll() @nogc nothrow
 *   - void deactivateFinished() @nogc nothrow
 *   - size_t activeCount() const / bool hasActiveVoices() const
 *   - void forEachActive(scope void delegate(ref VoiceT voice, NoteId id) @nogc nothrow visitor)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.voice_pool;

import foundation.types : NoteId;

/**
 * Fixed-capacity @nogc polyphonic voice allocator and deterministic voice stealer.
 *
 * VoiceT must provide @nogc nothrow methods isActive() const, releaseNote(), and reset().
 * Optionally providing isReleasing() const and currentLevel() const refines steal priority
 * (releasing voices before held voices, lowest amplitude first, oldest age tie-breaker).
 */
struct VoicePool(VoiceT, size_t MaxVoices) {
    static assert(MaxVoices > 0, "VoicePool MaxVoices must be greater than zero");
    static assert(
        __traits(compiles, (const ref VoiceT v) @nogc nothrow { bool a = v.isActive(); }),
        "VoicePool!" ~ VoiceT.stringof ~ " requires @nogc nothrow bool isActive() const"
    );
    static assert(
        __traits(compiles, (ref VoiceT v) @nogc nothrow { v.releaseNote(); }),
        "VoicePool!" ~ VoiceT.stringof ~ " requires @nogc nothrow void releaseNote()"
    );
    static assert(
        __traits(compiles, (ref VoiceT v) @nogc nothrow { v.reset(); }),
        "VoicePool!" ~ VoiceT.stringof ~ " requires @nogc nothrow void reset()"
    );

    private enum bool hasIsReleasing = __traits(
        compiles, (const ref VoiceT v) @nogc nothrow { bool r = v.isReleasing(); }
    );
    private enum bool hasCurrentLevel = __traits(
        compiles, (const ref VoiceT v) @nogc nothrow { float lvl = v.currentLevel(); }
    );

    private struct VoiceSlot {
        VoiceT voice;
        NoteId noteId = NoteId.none;
        ulong ageOrder = 0;
        bool occupied = false;
        bool released = false;
    }

    private VoiceSlot[MaxVoices] slots_;
    private size_t maxPolyphony_ = MaxVoices;
    private ulong nextOrder_ = 1;

    enum size_t capacity = MaxVoices;

    @nogc nothrow:

    /**
     * Caps active polyphony dynamically within [1, MaxVoices] without reallocation.
     *
     * Params:
     *   limit = Desired maximum simultaneous voice count.
     */
    void setMaxPolyphony(size_t limit) pure @safe {
        if (limit < 1) {
            maxPolyphony_ = 1;
        } else if (limit > MaxVoices) {
            maxPolyphony_ = MaxVoices;
        } else {
            maxPolyphony_ = limit;
        }
    }

    /**
     * Returns the current polyphony ceiling in [1, MaxVoices].
     *
     * Returns:
     *   Maximum concurrent voices allowed by allocateVoice().
     */
    size_t maxPolyphony() const pure @safe {
        return maxPolyphony_;
    }

    /**
     * Reclaims finished slots whose voice.isActive() has returned false.
     */
    void deactivateFinished() {
        foreach (ref slot; slots_) {
            if (slot.occupied && !slot.voice.isActive()) {
                slot.occupied = false;
                slot.released = false;
                slot.noteId = NoteId.none;
                slot.ageOrder = 0;
            }
        }
    }

    /**
     * Allocates or steals a voice slot for id and invokes voice.reset() on fresh/stolen slots.
     *
     * If id is valid and already active, reuses that voice slot in place (stolen = false).
     * Otherwise prefers free slots before stealing releasing, quietest, or oldest voices.
     *
     * Params:
     *   id = Note identifier associated with the voice.
     *   stolen = Output flag set to true if an active voice had to be stolen.
     *
     * Returns:
     *   Pointer to the allocated VoiceT slot within inline storage.
     */
    VoiceT* allocateVoice(NoteId id, out bool stolen) {
        deactivateFinished();
        stolen = false;

        if (id.isValid()) {
            foreach (i; 0 .. maxPolyphony_) {
                if (slots_[i].occupied && slots_[i].noteId == id) {
                    slots_[i].released = false;
                    slots_[i].ageOrder = nextOrder_++;
                    return &slots_[i].voice;
                }
            }
        }

        foreach (i; 0 .. maxPolyphony_) {
            if (!slots_[i].occupied) {
                slots_[i].voice.reset();
                slots_[i].occupied = true;
                slots_[i].released = false;
                slots_[i].noteId = id;
                slots_[i].ageOrder = nextOrder_++;
                return &slots_[i].voice;
            }
        }

        size_t victimIdx = 0;
        bool victimReleasing = isSlotReleasing(slots_[0]);
        float victimLevel = slotLevel(slots_[0]);
        ulong victimOrder = slots_[0].ageOrder;

        foreach (i; 1 .. maxPolyphony_) {
            immutable bool candReleasing = isSlotReleasing(slots_[i]);
            immutable float candLevel = slotLevel(slots_[i]);
            immutable ulong candOrder = slots_[i].ageOrder;

            if (isBetterStealCandidate(
                    candReleasing, candLevel, candOrder,
                    victimReleasing, victimLevel, victimOrder)) {
                victimIdx = i;
                victimReleasing = candReleasing;
                victimLevel = candLevel;
                victimOrder = candOrder;
            }
        }

        stolen = true;
        slots_[victimIdx].voice.reset();
        slots_[victimIdx].occupied = true;
        slots_[victimIdx].released = false;
        slots_[victimIdx].noteId = id;
        slots_[victimIdx].ageOrder = nextOrder_++;
        return &slots_[victimIdx].voice;
    }

    private static bool isSlotReleasing(const ref VoiceSlot slot) {
        static if (hasIsReleasing) {
            return slot.released || slot.voice.isReleasing();
        } else {
            return slot.released;
        }
    }

    private static float slotLevel(const ref VoiceSlot slot) {
        static if (hasCurrentLevel) {
            immutable float lvl = slot.voice.currentLevel();
            return lvl < 0.0f ? -lvl : lvl;
        } else {
            return 0.0f;
        }
    }

    private static bool isBetterStealCandidate(
        bool candReleasing,
        float candLevel,
        ulong candOrder,
        bool curReleasing,
        float curLevel,
        ulong curOrder
    ) pure @safe {
        if (candReleasing != curReleasing) {
            return candReleasing;
        }
        static if (hasCurrentLevel) {
            enum float LEVEL_TIE_EPS = 1e-4f;
            if (candLevel + LEVEL_TIE_EPS < curLevel) {
                return true;
            }
            if (curLevel + LEVEL_TIE_EPS < candLevel) {
                return false;
            }
        }
        return candOrder < curOrder;
    }

    /**
     * Looks up an active voice slot matching a valid NoteId.
     *
     * Params:
     *   id = Note identifier to locate.
     *
     * Returns:
     *   Pointer to the active VoiceT, or null if invalid or inactive.
     */
    VoiceT* findVoice(NoteId id) {
        if (!id.isValid()) {
            return null;
        }
        foreach (ref slot; slots_) {
            if (slot.occupied && slot.noteId == id && slot.voice.isActive()) {
                return &slot.voice;
            }
        }
        return null;
    }

    /**
     * Triggers releaseNote() on any active voice matching id.
     *
     * Params:
     *   id = Note identifier to release.
     *
     * Returns:
     *   True if a matching active voice was found and released.
     */
    bool releaseVoice(NoteId id) {
        if (!id.isValid()) {
            return false;
        }
        bool matched = false;
        foreach (ref slot; slots_) {
            if (slot.occupied && slot.noteId == id && slot.voice.isActive()) {
                slot.voice.releaseNote();
                slot.released = true;
                matched = true;
            }
        }
        return matched;
    }

    /**
     * Sends releaseNote() to all currently occupied voices.
     */
    void allNotesOff() {
        foreach (ref slot; slots_) {
            if (slot.occupied && slot.voice.isActive()) {
                slot.voice.releaseNote();
                slot.released = true;
            }
        }
    }

    /**
     * Hard-resets every voice slot immediately to idle state.
     */
    void resetAll() {
        foreach (ref slot; slots_) {
            slot.voice.reset();
            slot.occupied = false;
            slot.released = false;
            slot.noteId = NoteId.none;
            slot.ageOrder = 0;
        }
        nextOrder_ = 1;
    }

    /**
     * Counts currently occupied slots whose voice reports isActive() == true.
     *
     * Returns:
     *   Active voice count.
     */
    size_t activeCount() const {
        size_t count = 0;
        foreach (ref slot; slots_) {
            if (slot.occupied && slot.voice.isActive()) {
                count++;
            }
        }
        return count;
    }

    /**
     * Reports whether at least one voice is currently active.
     *
     * Returns:
     *   True if activeCount() > 0.
     */
    bool hasActiveVoices() const {
        foreach (ref slot; slots_) {
            if (slot.occupied && slot.voice.isActive()) {
                return true;
            }
        }
        return false;
    }

    /**
     * Invokes visitor for each active voice slot and automatically retires finished voices first.
     *
     * Params:
     *   visitor = Callback receiving mutable voice reference and its NoteId.
     */
    void forEachActive(scope void delegate(ref VoiceT voice, NoteId id) @nogc nothrow visitor) {
        if (visitor is null) {
            return;
        }
        foreach (ref slot; slots_) {
            if (!slot.occupied) {
                continue;
            }
            if (!slot.voice.isActive()) {
                slot.occupied = false;
                slot.released = false;
                slot.noteId = NoteId.none;
                slot.ageOrder = 0;
                continue;
            }
            visitor(slot.voice, slot.noteId);
            if (!slot.voice.isActive()) {
                slot.occupied = false;
                slot.released = false;
                slot.noteId = NoteId.none;
                slot.ageOrder = 0;
            }
        }
    }
}
