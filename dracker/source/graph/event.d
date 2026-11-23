/**
 * File:         source/graph/event.d
 * Module:       graph.event
 * Phase:        Phase 2.1 — Sample-Accurate ModEvent & Pre-Allocated EventArena
 *
 * Purpose:
 *   Defines typed real-time events (NoteOn, NoteOff, Pitch, Velocity, Param, Transport) with frameOffset [0..FIXED_BLOCK_FRAMES) and a fixed-capacity @nogc EventArena.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero RT reallocation; all events live in pre-sized OwnedBuffer storage with zero GC indirections.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory
 *   External: core.lifetime (move), std.traits (hasIndirections)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum ModEventKind : ubyte { noteOn, noteOff, setPitch, setVelocity, setParam, setParamInstant, allNotesOff, transport }
 *   - struct ModEvent { uint frameOffset; ModEventKind kind; NoteId noteId; uint paramId; float valueA; float valueB; }
 *   - struct ScheduledEvent { ModuleId targetMod; FrameTime targetFrame; ModEvent ev; uint sequence; }
 *   - struct EventArena : tryCreate(), tryPush(), sortByFrame(), collectForModuleInWindow(), pruneBefore(), clear()
 *   - void sortEventsByFrameOffset(ModEvent[] events) @nogc nothrow pure @safe
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.event;

import core.lifetime : move;
import std.traits : hasIndirections;

import foundation.memory : OwnedBuffer;
import foundation.types : FrameTime, ModuleId, NoteId;

/**
 * Real-time discrete musical, parameter, or transport event type.
 */
enum ModEventKind : ubyte {
    noteOn = 0,
    noteOff = 1,
    setPitch = 2,
    setVelocity = 3,
    setParam = 4,
    setParamInstant = 5,
    allNotesOff = 6,
    transport = 7,
    setParamNormalized = 8
}

/**
 * Sample-accurate discrete event passed to modules during slice execution.
 *
 * frameOffset specifies the sample index [0 .. sliceFrames) inside the current execution slice.
 */
struct ModEvent {
    uint frameOffset = 0;
    ModEventKind kind = ModEventKind.noteOn;
    NoteId noteId = NoteId.none;
    uint paramId = 0;
    float valueA = 0.0f;
    float valueB = 0.0f;

    @nogc nothrow pure @safe:

    /**
     * Constructs a NoteOn event with fractional MIDI pitch and normalized velocity.
     *
     * Params:
     *   noteId = Unique note voice identifier.
     *   midiNote = Fractional MIDI note number (69.0f == A4).
     *   velocity = Normalized note velocity in [0.0f, 1.0f].
     *   frameOffset = Sample offset within the slice.
     *
     * Returns:
     *   Initialized ModEvent.
     */
    static ModEvent makeNoteOn(NoteId noteId, float midiNote, float velocity = 1.0f, uint frameOffset = 0) {
        return ModEvent(frameOffset, ModEventKind.noteOn, noteId, 0, midiNote, velocity);
    }

    /**
     * Constructs a NoteOff event targeting a previously triggered NoteId.
     *
     * Params:
     *   noteId = Identifier of the note to release.
     *   frameOffset = Sample offset within the slice.
     *
     * Returns:
     *   Initialized ModEvent.
     */
    static ModEvent makeNoteOff(NoteId noteId, uint frameOffset = 0) {
        return ModEvent(frameOffset, ModEventKind.noteOff, noteId, 0, 0.0f, 0.0f);
    }

    /**
     * Constructs a continuous per-note pitch update event.
     *
     * Params:
     *   noteId = Active note identifier.
     *   midiNote = Target fractional MIDI note number.
     *   frameOffset = Sample offset within the slice.
     *
     * Returns:
     *   Initialized ModEvent.
     */
    static ModEvent makeSetPitch(NoteId noteId, float midiNote, uint frameOffset = 0) {
        return ModEvent(frameOffset, ModEventKind.setPitch, noteId, 0, midiNote, 0.0f);
    }

    /**
     * Constructs a per-note velocity modulation event.
     *
     * Params:
     *   noteId = Active note identifier.
     *   velocity = Target normalized velocity in [0.0f, 1.0f].
     *   frameOffset = Sample offset within the slice.
     *
     * Returns:
     *   Initialized ModEvent.
     */
    static ModEvent makeSetVelocity(NoteId noteId, float velocity, uint frameOffset = 0) {
        return ModEvent(frameOffset, ModEventKind.setVelocity, noteId, 0, 0.0f, velocity);
    }

    /**
     * Constructs a parameter automation event targeting paramIdx.
     *
     * Params:
     *   paramIdx = Zero-based parameter index on the destination module.
     *   value = Target parameter value in parameter domain units.
     *   instant = When true, emits setParamInstant bypassing smoothers.
     *   frameOffset = Sample offset within the slice.
     *
     * Returns:
     *   Initialized ModEvent.
     */
    static ModEvent makeSetParam(uint paramIdx, float value, bool instant = false, uint frameOffset = 0) {
        return ModEvent(
            frameOffset,
            instant ? ModEventKind.setParamInstant : ModEventKind.setParam,
            NoteId.none,
            paramIdx,
            value,
            0.0f
        );
    }

    /**
     * Constructs an all-notes-off panic/release event.
     *
     * Params:
     *   frameOffset = Sample offset within the slice.
     *
     * Returns:
     *   Initialized ModEvent.
     */
    static ModEvent makeAllNotesOff(uint frameOffset = 0) {
        return ModEvent(frameOffset, ModEventKind.allNotesOff, NoteId.none, 0, 0.0f, 0.0f);
    }

    /**
     * Constructs a normalized [0.0f, 1.0f] parameter automation event mapped using module ParamScale.
     *
     * Params:
     *   paramIdx = Zero-based parameter index on the destination module.
     *   norm01 = Normalized parameter value clamped to [0.0f, 1.0f].
     *   instant = When true, snaps parameter smoothers immediately.
     *   frameOffset = Sample offset within the slice.
     *
     * Returns:
     *   Initialized ModEvent.
     */
    static ModEvent makeSetParamNormalized(
        uint paramIdx,
        float norm01,
        bool instant = false,
        uint frameOffset = 0
    ) {
        return ModEvent(
            frameOffset,
            ModEventKind.setParamNormalized,
            NoteId.none,
            paramIdx,
            norm01,
            instant ? 1.0f : 0.0f
        );
    }
}

/**
 * Timestamped module-targeted event stored inside an EventArena.
 */
struct ScheduledEvent {
    ModuleId targetMod = ModuleId.invalid;
    FrameTime targetFrame = 0;
    ModEvent ev;
    uint sequence = 0;
}

static assert(!hasIndirections!ModEvent);
static assert(!hasIndirections!ScheduledEvent);

/**
 * Performs a stable in-place insertion sort of ModEvents by ascending frameOffset.
 *
 * Params:
 *   events = Event slice sorted in place without allocations.
 */
void sortEventsByFrameOffset(ModEvent[] events) @nogc nothrow pure @safe {
    foreach (i; 1 .. events.length) {
        immutable ModEvent key = events[i];
        size_t j = i;
        while (j > 0 && events[j - 1].frameOffset > key.frameOffset) {
            events[j] = events[j - 1];
            j--;
        }
        events[j] = key;
    }
}

/**
 * Pre-allocated @nogc event storage buffer for scheduling and sub-blocking RT events.
 *
 * Zero heap allocations occur during push, sort, window collection, or pruning.
 */
struct EventArena {
    private OwnedBuffer!ScheduledEvent storage_;
    private size_t count_ = 0;
    private uint nextSequence_ = 0;

    @disable this(this);

    @nogc nothrow:

    /**
     * Transfers EventArena backing storage from an rvalue source.
     *
     * Params:
     *   rhs = Source EventArena moved into this instance.
     *
     * Returns:
     *   Reference to this EventArena.
     */
    ref EventArena opAssign(EventArena rhs) return {
        storage_ = move(rhs.storage_);
        count_ = rhs.count_;
        nextSequence_ = rhs.nextSequence_;
        rhs.count_ = 0;
        rhs.nextSequence_ = 0;
        return this;
    }

    /**
     * Allocates backing capacity for capacityEvents ScheduledEvents off-RT.
     *
     * Params:
     *   capacityEvents = Maximum queued event capacity.
     *   result = Destination EventArena initialized on success.
     *
     * Returns:
     *   True on success; false on OOM.
     */
    static bool tryCreate(size_t capacityEvents, out EventArena result) {
        result = EventArena.init;
        OwnedBuffer!ScheduledEvent buf;
        if (!OwnedBuffer!ScheduledEvent.tryAllocate(capacityEvents, buf)) {
            return false;
        }
        result.storage_ = move(buf);
        result.count_ = 0;
        result.nextSequence_ = 0;
        return true;
    }

    /**
     * Clears all stored events in O(1) without releasing backing memory.
     */
    void clear() pure @safe {
        count_ = 0;
        nextSequence_ = 0;
    }

    private bool tryPushImpl(ModuleId targetMod, FrameTime targetFrame, scope const ref ModEvent ev) pure {
        if (count_ >= storage_.length) {
            return false;
        }
        storage_[count_] = ScheduledEvent(targetMod, targetFrame, ev, nextSequence_);
        count_++;
        nextSequence_++;
        return true;
    }

    /**
     * Appends a scheduled event targeting targetMod at absolute graph frame targetFrame.
     *
     * Params:
     *   targetMod = Destination module identifier.
     *   targetFrame = Absolute sample frame at which the event takes effect.
     *   ev = Event payload to schedule.
     *
     * Returns:
     *   True if appended; false if capacity is exhausted.
     */
    bool tryPush(ModuleId targetMod, FrameTime targetFrame, scope const ref ModEvent ev) pure {
        return tryPushImpl(targetMod, targetFrame, ev);
    }

    /**
     * Appends an rvalue scheduled event targeting targetMod at absolute graph frame targetFrame.
     *
     * Params:
     *   targetMod = Destination module identifier.
     *   targetFrame = Absolute sample frame at which the event takes effect.
     *   ev = Event payload value to schedule.
     *
     * Returns:
     *   True if appended; false if capacity is exhausted.
     */
    bool tryPush(ModuleId targetMod, FrameTime targetFrame, ModEvent ev) pure {
        return tryPushImpl(targetMod, targetFrame, ev);
    }

    /**
     * Sorts scheduled events stably in place by ascending (targetFrame, sequence).
     */
    void sortByFrame() pure {
        auto items = storage_[0 .. count_];
        foreach (i; 1 .. items.length) {
            immutable ScheduledEvent key = items[i];
            size_t j = i;
            while (j > 0 && comesAfter(items[j - 1], key)) {
                items[j] = items[j - 1];
                j--;
            }
            items[j] = key;
        }
    }

    private static bool comesAfter(scope const ref ScheduledEvent a, scope const ref ScheduledEvent b) pure @safe {
        if (a.targetFrame != b.targetFrame) {
            return a.targetFrame > b.targetFrame;
        }
        return a.sequence > b.sequence;
    }

    /**
     * Extracts events targeting modId inside [windowStart, windowEnd) into outBuf.
     *
     * Populates each copied event's frameOffset relative to windowStart and sorts outBuf
     * stably by ascending frameOffset.
     *
     * Params:
     *   modId = Destination module identifier to match.
     *   windowStart = Inclusive start frame of the current processing slice.
     *   windowEnd = Exclusive end frame of the current processing slice.
     *   outBuf = Caller-provided staging slice receiving matched events.
     *
     * Returns:
     *   Number of events written to outBuf[0 .. returnValue].
     */
    size_t collectForModuleInWindow(
        ModuleId modId,
        FrameTime windowStart,
        FrameTime windowEnd,
        ModEvent[] outBuf
    ) const pure {
        size_t written = 0;
        const items = storage_[0 .. count_];
        foreach (ref item; items) {
            if (item.targetMod == modId && item.targetFrame >= windowStart && item.targetFrame < windowEnd) {
                if (written >= outBuf.length) {
                    break;
                }
                ModEvent copy = item.ev;
                copy.frameOffset = cast(uint)(item.targetFrame - windowStart);
                outBuf[written] = copy;
                written++;
            }
        }
        if (written > 1) {
            sortEventsByFrameOffset(outBuf[0 .. written]);
        }
        return written;
    }

    /**
     * Compacts the arena in place, removing all events with targetFrame < cutoffFrame.
     *
     * Params:
     *   cutoffFrame = Exclusive frame threshold below which dispatched events are discarded.
     */
    void pruneBefore(FrameTime cutoffFrame) pure {
        size_t keep = 0;
        auto items = storage_[0 .. count_];
        foreach (i; 0 .. count_) {
            if (items[i].targetFrame >= cutoffFrame) {
                if (keep != i) {
                    items[keep] = items[i];
                }
                keep++;
            }
        }
        count_ = keep;
        if (count_ == 0) {
            nextSequence_ = 0;
        }
    }

    /**
     * Returns the number of events currently stored.
     *
     * Returns:
     *   Active event count.
     */
    size_t length() const pure @safe {
        return count_;
    }

    /**
     * Returns the maximum event capacity of this arena.
     *
     * Returns:
     *   Allocated slot count.
     */
    size_t capacity() const pure @safe {
        return storage_.length;
    }

    /**
     * Reports whether zero events are currently stored.
     *
     * Returns:
     *   True if length() == 0.
     */
    bool empty() const pure @safe {
        return count_ == 0;
    }

    /**
     * Returns a read-only view of all active scheduled events.
     *
     * Returns:
     *   Const slice spanning [0 .. length()].
     */
    const(ScheduledEvent)[] slice() const pure {
        return storage_[0 .. count_];
    }
}
