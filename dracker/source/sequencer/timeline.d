/**
 * File:         source/sequencer/timeline.d
 * Module:       sequencer.timeline
 * Phase:        Phase 5.2 — TimelineClip Placements, Pattern Clones & Supertracks
 *
 * Purpose:
 *   Manages song arrangement clips, shared pattern clones, mute/solo flags, loop regions, and Supertracks persistent per-lane playback state across consecutive clips.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on RT traversal via CoW TimelineSnapshot swapped cleanly at slice boundaries.
 *
 * Dependencies:
 *   Internal: foundation.concurrency, foundation.memory, foundation.types
 *   External: core.lifetime (emplace, move), core.stdc.stdlib (calloc, free), std.traits (hasIndirections)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct TimelineClip : clipId, patternId, cloneSourceId, startLine, lengthLines, laneY, patternOffset, mute, solo, isSupertrack
 *   - struct SupertrackState : persistent per-lane active state metadata
 *   - struct TimelineSnapshot : createOffRT(), destroyOffRT(), destroyErased(), collectActiveClipsAtLine(), songEndLine()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.timeline;

import core.lifetime : emplace, move;
import core.stdc.stdlib : calloc, free;
import std.traits : hasIndirections;

import foundation.concurrency : hasGcReference;
import foundation.memory : OwnedBuffer;
import foundation.types : ModuleId;

/**
 * Single timeline arrangement placement referencing a PatternSnapshot (or clone of one).
 *
 * Clones reference the same patternId so pattern edits reflect across every clone automatically.
 * Clips with isSupertrack = true share persistent laneY track/effect memory seamlessly across cuts.
 */
struct TimelineClip {
    uint clipId = 0;
    uint patternId = 0;
    uint cloneSourceId = 0;
    long startLine = 0;
    uint lengthLines = 64;
    uint laneY = 0;
    uint patternOffset = 0;
    bool mute = false;
    bool solo = false;
    bool isSupertrack = false;
}

static assert(!hasIndirections!TimelineClip);

/**
 * Per-lane Supertrack state metadata tracking active clip ownership and persistent module focus.
 */
struct SupertrackState {
    uint laneY = 0;
    uint activeClipId = 0;
    ModuleId lastModuleId = ModuleId.invalid;
    uint activeTrackCount = 0;
    bool active = false;
}

static assert(!hasIndirections!SupertrackState);

/**
 * Immutable @nogc Copy-on-Write song timeline snapshot swapped atomically into the RT Engine.
 */
struct TimelineSnapshot {
    OwnedBuffer!TimelineClip clips;
    long loopStartLine = 0;
    long loopEndLine = 0;
    uint supertrackCount = 0;
    bool anyClipSolo = false;

    @disable this(this);

    @nogc nothrow:

    /**
     * Frees owned TimelineClip storage on teardown.
     */
    ~this() {
        clips.reset();
        supertrackCount = 0;
        anyClipSolo = false;
    }

    /**
     * Allocates a CoW TimelineSnapshot from srcClips off the real-time audio thread.
     *
     * Params:
     *   srcClips = Array of clip placements sorted/stored cleanly in arrangement order.
     *   loopStart = Inclusive song loop start line.
     *   loopEnd = Exclusive song loop end line (0 or <= loopStart disables looping).
     *
     * Returns:
     *   Allocated TimelineSnapshot*, or null on OOM.
     */
    static TimelineSnapshot* createOffRT(
        const(TimelineClip)[] srcClips,
        long loopStart = 0,
        long loopEnd = 0
    ) {
        OwnedBuffer!TimelineClip buf;
        if (srcClips.length > 0 && !OwnedBuffer!TimelineClip.tryAllocate(srcClips.length, buf)) {
            return null;
        }
        bool foundSolo = false;
        uint maxSuperLane = 0;
        bool hasSuper = false;
        foreach (i, ref c; srcClips) {
            buf[i] = c;
            if (c.solo && !c.mute) {
                foundSolo = true;
            }
            if (c.isSupertrack) {
                hasSuper = true;
                if (c.laneY >= maxSuperLane) {
                    maxSuperLane = c.laneY;
                }
            }
        }

        auto snap = cast(TimelineSnapshot*) calloc(1, TimelineSnapshot.sizeof);
        if (snap is null) {
            return null;
        }
        emplace(snap);
        snap.clips = move(buf);
        snap.loopStartLine = loopStart;
        snap.loopEndLine = loopEnd;
        snap.anyClipSolo = foundSolo;
        snap.supertrackCount = hasSuper ? (maxSuperLane + 1) : 0;
        return snap;
    }

    /**
     * Destroys and frees a TimelineSnapshot* off the real-time thread.
     *
     * Params:
     *   snap = Snapshot pointer to free (null-safe).
     */
    static void destroyOffRT(TimelineSnapshot* snap) {
        if (snap !is null) {
            destroy!false(*snap);
            free(snap);
        }
    }

    /**
     * Type-erased destructor compatible with RetiredResource reclamation off-RT.
     *
     * Params:
     *   raw = Opaque TimelineSnapshot* pointer.
     */
    static void destroyErased(void* raw) {
        destroyOffRT(cast(TimelineSnapshot*) raw);
    }

    /**
     * Reports whether c should play given its mute flag and global solo status.
     *
     * Params:
     *   c = TimelineClip under evaluation.
     *
     * Returns:
     *   True if c is audible on the timeline.
     */
    bool clipAudible(scope const ref TimelineClip c) const pure @safe {
        if (c.mute || c.lengthLines == 0) {
            return false;
        }
        if (anyClipSolo && !c.solo) {
            return false;
        }
        return true;
    }

    /**
     * Collects all audible TimelineClips overlapping song line without heap allocations.
     *
     * Params:
     *   line = Zero-based current song line index.
     *   outClips = Caller-supplied scratch slice receiving matching clips.
     *
     * Returns:
     *   Actual number of clips written into outClips.
     */
    size_t collectActiveClipsAtLine(long line, TimelineClip[] outClips) const {
        if (line < 0 || clips.empty() || outClips.length == 0) {
            return 0;
        }
        size_t count = 0;
        foreach (ref c; clips[]) {
            if (!clipAudible(c)) {
                continue;
            }
            if (line >= c.startLine && line < c.startLine + cast(long) c.lengthLines) {
                outClips[count++] = c;
                if (count >= outClips.length) {
                    break;
                }
            }
        }
        return count;
    }

    /**
     * Computes the exclusive ending song line across all timeline clips and loop end marker.
     *
     * Returns:
     *   Total song length in lines (>= 0).
     */
    long songEndLine() const pure {
        long endLine = loopEndLine > 0 ? loopEndLine : 0;
        foreach (ref c; clips[]) {
            immutable long cEnd = c.startLine + cast(long) c.lengthLines;
            if (cEnd > endLine) {
                endLine = cEnd;
            }
        }
        return endLine;
    }
}

static assert(!hasGcReference!TimelineSnapshot,
    "TimelineSnapshot must contain zero D GC references");
