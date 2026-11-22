/**
 * File:         source/sequencer/pattern.d
 * Module:       sequencer.pattern
 * Phase:        Phase 5.1 — @nogc PatternData, CoW PatternSnapshot & Atomic Cell Patch
 *
 * Purpose:
 *   Stores tracker pattern tracks x lines inside unscanned OwnedBuffer!ulong blocks. Hot cell edits patch atomically; structural resizes swap CoW PatternSnapshots through the retire ring.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on RT reads; zero GC indirections so unregistered CoreAudio thread safely reads active pattern snapshots.
 *
 * Dependencies:
 *   Internal: foundation.concurrency, foundation.memory, sequencer.note
 *   External: core.atomic, core.checkedint (mulu), core.lifetime (emplace, move), core.stdc.stdlib (calloc, free)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct PatternSnapshot : patternId, tracks, lines, OwnedBuffer!ulong rawCells
 *   - void patchCellAtomic(PatternSnapshot* snap, uint track, uint line, NoteCell cell) @nogc nothrow
 *   - PatternSnapshot* PatternSnapshot.createOffRT(...) / cloneAndResizeOffRT(...)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.pattern;

import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import core.checkedint : mulu;
import core.lifetime : emplace, move;
import core.stdc.stdlib : calloc, free;

import foundation.concurrency : hasGcReference;
import foundation.memory : OwnedBuffer;
import sequencer.note : NoteCell;

/**
 * Unmanaged @nogc Copy-on-Write tracker pattern snapshot shared safely with unregistered RT threads.
 *
 * Each cell occupies one 64-bit atomic word in row-major order `line * tracks + track`,
 * allowing lock-free single-cell hot patching and clone-safe multi-clip sharing.
 */
struct PatternSnapshot {
    uint patternId = 0;
    uint tracks = 0;
    uint lines = 0;
    OwnedBuffer!ulong rawCells;

    @disable this(this);

    @nogc nothrow:

    /**
     * Releases owned raw cell memory cleanly on teardown.
     */
    ~this() {
        rawCells.reset();
        tracks = 0;
        lines = 0;
    }

    /**
     * Allocates an initialized empty PatternSnapshot off the real-time thread.
     *
     * Params:
     *   id = Logical pattern identifier.
     *   numTracks = Column count (>= 1).
     *   numLines = Row count (>= 1).
     *
     * Returns:
     *   Allocated PatternSnapshot* on success, or null on invalid dimensions or OOM.
     */
    static PatternSnapshot* createOffRT(uint id, uint numTracks, uint numLines) {
        if (numTracks == 0 || numLines == 0) {
            return null;
        }
        bool overflow = false;
        immutable size_t cellCount = mulu(cast(size_t) numTracks, cast(size_t) numLines, overflow);
        if (overflow) {
            return null;
        }

        OwnedBuffer!ulong cells;
        if (!OwnedBuffer!ulong.tryAllocate(cellCount, cells)) {
            return null;
        }

        auto snap = cast(PatternSnapshot*) calloc(1, PatternSnapshot.sizeof);
        if (snap is null) {
            return null;
        }
        emplace(snap);
        snap.patternId = id;
        snap.tracks = numTracks;
        snap.lines = numLines;
        snap.rawCells = move(cells);
        return snap;
    }

    /**
     * Clones an existing PatternSnapshot into new dimensions off-RT (Copy-on-Write resize).
     *
     * Overlapping cells within min(tracks) x min(lines) are preserved via atomic loads.
     *
     * Params:
     *   src = Source snapshot to clone (may be null to create blank resized snapshot).
     *   newTracks = Target column count (>= 1).
     *   newLines = Target line count (>= 1).
     *
     * Returns:
     *   Newly allocated PatternSnapshot* on success, or null on OOM/invalid size.
     */
    static PatternSnapshot* cloneAndResizeOffRT(
        const(PatternSnapshot)* src,
        uint newTracks,
        uint newLines
    ) {
        immutable uint id = src !is null ? src.patternId : 0;
        PatternSnapshot* dst = createOffRT(id, newTracks, newLines);
        if (dst is null || src is null) {
            return dst;
        }

        immutable uint copyTracks = src.tracks < newTracks ? src.tracks : newTracks;
        immutable uint copyLines = src.lines < newLines ? src.lines : newLines;
        foreach (ln; 0 .. copyLines) {
            foreach (tr; 0 .. copyTracks) {
                immutable NoteCell c = src.getCellAtomic(tr, ln);
                dst.rawCells[cast(size_t) ln * cast(size_t) newTracks + cast(size_t) tr] = c.packU64();
            }
        }
        return dst;
    }

    /**
     * Destroys and frees a PatternSnapshot* off the audio thread.
     *
     * Params:
     *   snap = Snapshot pointer to free (null-safe).
     */
    static void destroyOffRT(PatternSnapshot* snap) {
        if (snap !is null) {
            destroy!false(*snap);
            free(snap);
        }
    }

    /**
     * Type-erased destructor compatible with RetiredResource reclamation off-RT.
     *
     * Params:
     *   raw = Opaque PatternSnapshot* pointer.
     */
    static void destroyErased(void* raw) {
        destroyOffRT(cast(PatternSnapshot*) raw);
    }

    /**
     * Atomically reads one tracker NoteCell using acquire semantics without GC/locks.
     *
     * Params:
     *   track = Zero-based track column.
     *   line = Zero-based pattern line.
     *
     * Returns:
     *   Decoded NoteCell, or empty NoteCell if coordinates are out of range.
     */
    NoteCell getCellAtomic(uint track, uint line) const @trusted {
        if (track >= tracks || line >= lines || rawCells.empty()) {
            return NoteCell.init;
        }
        immutable size_t idx = cast(size_t) line * cast(size_t) tracks + cast(size_t) track;
        immutable ulong bits = atomicLoad!(MemoryOrder.acq)(
            *cast(const(shared(ulong))*) &rawCells.ptr[idx]
        );
        return NoteCell.unpackU64(bits);
    }

    /**
     * Atomically overwrites one tracker NoteCell using release semantics (UI/RT lock-free edit).
     *
     * Params:
     *   track = Zero-based track column.
     *   line = Zero-based pattern line.
     *   cell = Replacement 8-byte NoteCell.
     */
    void setCellAtomic(uint track, uint line, NoteCell cell) @trusted {
        if (track >= tracks || line >= lines || rawCells.empty()) {
            return;
        }
        immutable size_t idx = cast(size_t) line * cast(size_t) tracks + cast(size_t) track;
        atomicStore!(MemoryOrder.rel)(
            *cast(shared(ulong)*) &rawCells.ptr[idx],
            cell.packU64()
        );
    }
}

static assert(!hasGcReference!PatternSnapshot,
    "PatternSnapshot must contain zero D GC references");

/**
 * Lock-free 64-bit atomic cell patch helper safe for live editing on active snapshots.
 *
 * Params:
 *   snap = Target PatternSnapshot pointer (null-safe).
 *   track = Zero-based track index.
 *   line = Zero-based line index.
 *   cell = Replacement 8-byte NoteCell value.
 */
void patchCellAtomic(PatternSnapshot* snap, uint track, uint line, NoteCell cell) @nogc nothrow {
    if (snap !is null) {
        snap.setCellAtomic(track, line, cell);
    }
}
