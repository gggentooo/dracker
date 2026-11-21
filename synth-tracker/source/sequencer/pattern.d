/**
 * File:         source/sequencer/pattern.d
 * Module:       sequencer.pattern
 * Phase:        Phase 5.1 — @nogc PatternData, CoW PatternSnapshot & Atomic Cell Patch
 *
 * Purpose:
 *   Stores tracker pattern tracks x lines inside unscanned OwnedBuffer!NoteCell blocks. Hot cell edits patch atomically; structural resizes swap CoW PatternSnapshots through the retire ring.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on RT reads; zero GC indirections so unregistered CoreAudio thread safely reads active pattern snapshots.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, foundation.concurrency, sequencer.note
 *   External: core.atomic
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct PatternSnapshot : tracks, lines, OwnedBuffer!NoteCell cells
 *   - void patchCellAtomic(PatternSnapshot* snap, uint track, uint line, NoteCell cell) @nogc nothrow
 *   - PatternSnapshot* cloneAndResizeOffRT(const PatternSnapshot* src, uint newTracks, uint newLines)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.pattern;
