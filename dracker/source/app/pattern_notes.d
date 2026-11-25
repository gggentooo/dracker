/**
 * File:         source/app/pattern_notes.d
 * Module:       app.pattern_notes
 * Phase:        Pattern editor views — T42 (note model for the piano roll)
 *
 * Purpose:
 *   Reads a pattern's cells as notes and edits them, for the piano roll (decision T32). A note is a note cell;
 *   it ends at the next note or note command on its track, or at the end of the pattern. Each track plays one
 *   note at a time, so the functions here choose tracks:
 *     - A new or moved note goes on its own track when that is free, else on the lowest-numbered track that
 *       holds only notes of the same module and where it overlaps nothing, else on a track without notes, else
 *       on a new track (up to MAX_TRACKS); if none is possible the edit is refused.
 *     - Two notes of the same module and pitch may not overlap.
 *     - Shortening a note writes a note-off at its new end; a note-off is not written where another note or
 *       command already starts, or at the end of the pattern. Removing a note restores the length of a note it
 *       had cut short and removes its own note-off.
 *     - A note's effect columns travel with it. Notes of other modules are never changed: a following note
 *       that inherits its module from an earlier cell on the track gets that module written explicitly before
 *       anything above it changes.
 *     - Empty tracks are never removed.
 *   Every edit works on a copy and is applied only when it fully succeeds.
 *
 * Real-Time & Safety Contract:
 *   UI/off-RT only; pure functions over a PatternGrid value. No session, GUI or I/O.
 *
 * Dependencies:
 *   Internal: sequencer.note
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct RollNote; struct PatternGrid (at(), addTrack()); enum NoteEdit; noteEditMessage()
 *   - notesOf(), addNote(), moveNote(), moveNotes(), resizeNote(), deleteNote(), deleteNotes(), setNoteVelocity()
 *   - cellVelocity()
 *
 * See_Also:
 *   docs/todo.md (T31, T32, T42), source/app/pattern_ops.d
 */
module app.pattern_notes;

import sequencer.note : NoteCell, NoteCmd;

enum uint ROLL_MAX_TRACKS = 64;

/**
 * One note as the piano roll sees it: where its cell is, how long it sounds, and what it plays.
 */
struct RollNote {
    uint track = 0;
    uint line = 0;
    uint length = 1;
    ubyte pitch = 60;
    float velocity = 0.8f;
    ushort moduleId = 0;
}

/**
 * Result of a note edit.
 */
enum NoteEdit : ubyte {
    ok = 0,
    notFound = 1,
    outOfRange = 2,
    samePitchOverlap = 3,
    noFreeTrack = 4
}

/**
 * Working copy of a pattern's cells (row-major: line * tracks + track).
 */
struct PatternGrid {
    uint tracks = 0;
    uint lines = 0;
    NoteCell[] cells;

    /**
     * Returns the cell at a track and line.
     *
     * Params:
     *   track = Track index (< tracks).
     *   line = Line index (< lines).
     *
     * Returns:
     *   Reference to the cell.
     */
    ref inout(NoteCell) at(uint track, uint line) inout @safe pure nothrow @nogc {
        return cells[cast(size_t) line * tracks + track];
    }

    /**
     * Appends an empty track.
     *
     * Returns:
     *   False when the pattern already has ROLL_MAX_TRACKS tracks.
     */
    bool addTrack() @safe pure nothrow {
        if (tracks >= ROLL_MAX_TRACKS) {
            return false;
        }
        NoteCell[] next = new NoteCell[cast(size_t)(tracks + 1) * lines];
        foreach (ln; 0 .. lines) {
            foreach (tr; 0 .. tracks) {
                next[cast(size_t) ln * (tracks + 1) + tr] = cells[cast(size_t) ln * tracks + tr];
            }
        }
        cells = next;
        tracks++;
        return true;
    }

    /**
     * Returns an independent copy.
     *
     * Returns:
     *   Copy with its own cells.
     */
    PatternGrid dup() const @safe pure nothrow {
        return PatternGrid(tracks, lines, cells.dup);
    }
}

/**
 * Returns the sentence shown when an edit is refused.
 *
 * Params:
 *   e = Edit result.
 *
 * Returns:
 *   Text ("" for ok).
 */
string noteEditMessage(NoteEdit e) @safe pure nothrow @nogc {
    final switch (e) {
        case NoteEdit.ok:
            return "";
        case NoteEdit.notFound:
            return "That note is no longer there";
        case NoteEdit.outOfRange:
            return "The note would be outside the pattern";
        case NoteEdit.samePitchOverlap:
            return "It would overlap another note of the same pitch";
        case NoteEdit.noFreeTrack:
            return "No free track: the pattern already has 64 tracks";
    }
}

/**
 * Decodes a cell's velocity byte.
 *
 * Params:
 *   c = Cell.
 *
 * Returns:
 *   Velocity in [0, 1].
 */
float cellVelocity(const ref NoteCell c) @safe pure nothrow @nogc {
    return (c.velocity > 0 ? c.velocity - 1 : 0) / 254.0f;
}

/**
 * Reads every note of a pattern, by track then line. A note's module is the one written in its cell, or the
 * last module written above it on its track.
 *
 * Params:
 *   g = Pattern.
 *
 * Returns:
 *   Notes.
 */
RollNote[] notesOf(const ref PatternGrid g) @safe pure nothrow {
    RollNote[] notes;
    foreach (t; 0 .. g.tracks) {
        ushort active = 0;
        foreach (ln; 0 .. g.lines) {
            immutable NoteCell c = g.at(t, ln);
            if (c.moduleId != 0) {
                active = c.moduleId;
            }
            if (isNote(c)) {
                notes ~= RollNote(t, ln, lengthFrom(g, t, ln), cast(ubyte)(c.note - 1), cellVelocity(c), active);
            }
        }
    }
    return notes;
}

/**
 * Adds a note of a module (T32 track rules).
 *
 * Params:
 *   g = Pattern; changed only on success.
 *   moduleId = Module the note plays (non-zero).
 *   pitch = MIDI pitch [0, 127].
 *   line = Start line.
 *   length = Length in lines (clipped to the end of the pattern; at least 1).
 *   velocity = Velocity in (0, 1].
 *   placed = Receives the note as stored.
 *
 * Returns:
 *   ok, outOfRange, samePitchOverlap or noFreeTrack.
 */
NoteEdit addNote(ref PatternGrid g, ushort moduleId, ubyte pitch, uint line, uint length, float velocity,
        out RollNote placed) @safe pure nothrow {
    PatternGrid w = g.dup();
    immutable NoteEdit r = place(w, NoteCell.makeNote(pitch, velocity, moduleId), moduleId, line, length, uint.max,
        placed);
    if (r == NoteEdit.ok) {
        g = w;
    }
    return r;
}

/**
 * Moves a note in time and pitch, keeping its length (clipped at the end of the pattern), velocity and effect
 * columns.
 *
 * Params:
 *   g = Pattern; changed only on success.
 *   n = Note to move (as returned by notesOf()).
 *   dLine = Lines to move (negative = earlier).
 *   dPitch = Semitones to move.
 *   moved = Receives the note at its new place.
 *
 * Returns:
 *   ok, notFound, outOfRange, samePitchOverlap or noFreeTrack.
 */
NoteEdit moveNote(ref PatternGrid g, RollNote n, int dLine, int dPitch, out RollNote moved) @safe pure nothrow {
    RollNote[] result;
    immutable NoteEdit r = moveNotes(g, [n], dLine, dPitch, result);
    if (r == NoteEdit.ok) {
        moved = result[0];
    }
    return r;
}

/**
 * Moves several notes together by the same amount; either all move or none does.
 *
 * Params:
 *   g = Pattern; changed only on success.
 *   set = Notes to move.
 *   dLine = Lines to move.
 *   dPitch = Semitones to move.
 *   moved = Receives the notes at their new places, in the order of set.
 *
 * Returns:
 *   ok, or the first failure.
 */
NoteEdit moveNotes(ref PatternGrid g, const(RollNote)[] set, int dLine, int dPitch, out RollNote[] moved)
        @safe pure nothrow {
    PatternGrid w = g.dup();
    NoteCell[] carried = new NoteCell[set.length];
    foreach (i, ref n; set) {
        if (!isNoteAt(w, n) || n.moduleId == 0) {
            return NoteEdit.notFound;
        }
        immutable long nl = cast(long) n.line + dLine;
        immutable int np = cast(int) n.pitch + dPitch;
        if (nl < 0 || nl >= w.lines || np < 0 || np > 127) {
            return NoteEdit.outOfRange;
        }
    }
    foreach (i, ref n; set) {
        carried[i] = remove(w, n);
    }
    RollNote[] result = new RollNote[set.length];
    foreach (i, ref n; set) {
        NoteCell c = carried[i];
        c.note = cast(ubyte)(n.pitch + dPitch + 1);
        c.moduleId = n.moduleId;
        immutable NoteEdit r = place(w, c, n.moduleId, cast(uint)(n.line + dLine), n.length, n.track, result[i]);
        if (r != NoteEdit.ok) {
            return r;
        }
    }
    g = w;
    moved = result;
    return NoteEdit.ok;
}

/**
 * Changes a note's length.
 *
 * Params:
 *   g = Pattern; changed only on success.
 *   n = Note to resize.
 *   newLength = New length in lines (at least 1; clipped at the end of the pattern).
 *   resized = Receives the note as stored.
 *
 * Returns:
 *   ok, notFound, outOfRange, samePitchOverlap or noFreeTrack.
 */
NoteEdit resizeNote(ref PatternGrid g, RollNote n, uint newLength, out RollNote resized) @safe pure nothrow {
    if (newLength == 0) {
        return NoteEdit.outOfRange;
    }
    PatternGrid w = g.dup();
    if (!isNoteAt(w, n) || n.moduleId == 0) {
        return NoteEdit.notFound;
    }
    NoteCell c = remove(w, n);
    c.moduleId = n.moduleId;
    immutable NoteEdit r = place(w, c, n.moduleId, n.line, newLength, n.track, resized);
    if (r == NoteEdit.ok) {
        g = w;
    }
    return r;
}

/**
 * Deletes a note. A note it had cut short gets a note-off there, so its length does not change.
 *
 * Params:
 *   g = Pattern; changed only on success.
 *   n = Note to delete.
 *
 * Returns:
 *   ok or notFound.
 */
NoteEdit deleteNote(ref PatternGrid g, RollNote n) @safe pure nothrow {
    return deleteNotes(g, [n]);
}

/**
 * Deletes several notes; either all are deleted or none.
 *
 * Params:
 *   g = Pattern; changed only on success.
 *   set = Notes to delete.
 *
 * Returns:
 *   ok or notFound.
 */
NoteEdit deleteNotes(ref PatternGrid g, const(RollNote)[] set) @safe pure nothrow {
    PatternGrid w = g.dup();
    foreach (ref n; set) {
        if (!isNoteAt(w, n)) {
            return NoteEdit.notFound;
        }
    }
    foreach (ref n; set) {
        remove(w, n);
    }
    g = w;
    return NoteEdit.ok;
}

/**
 * Sets a note's velocity.
 *
 * Params:
 *   g = Pattern; changed only on success.
 *   n = Note.
 *   velocity = New velocity in (0, 1].
 *
 * Returns:
 *   ok or notFound.
 */
NoteEdit setNoteVelocity(ref PatternGrid g, RollNote n, float velocity) @safe pure nothrow {
    if (!isNoteAt(g, n)) {
        return NoteEdit.notFound;
    }
    g.at(n.track, n.line).velocity = NoteCell.encodeVelocity(velocity);
    return NoteEdit.ok;
}

private bool isNote(const ref NoteCell c) @safe pure nothrow @nogc {
    return c.note >= 1 && c.note <= 128;
}

private bool isStop(const ref NoteCell c) @safe pure nothrow @nogc {
    return c.note >= 240;
}

private bool isNoteAt(const ref PatternGrid g, const ref RollNote n) @safe pure nothrow @nogc {
    return n.track < g.tracks && n.line < g.lines && isNote(g.at(n.track, n.line));
}

private uint lengthFrom(const ref PatternGrid g, uint track, uint line) @safe pure nothrow @nogc {
    foreach (ln; line + 1 .. g.lines) {
        immutable NoteCell c = g.at(track, ln);
        if (isNote(c) || isStop(c)) {
            return ln - line;
        }
    }
    return g.lines - line;
}

private ushort moduleAt(const ref PatternGrid g, uint track, uint line) @safe pure nothrow @nogc {
    ushort active = 0;
    foreach (ln; 0 .. line + 1) {
        if (g.at(track, ln).moduleId != 0) {
            active = g.at(track, ln).moduleId;
        }
    }
    return active;
}

private bool soundingBefore(const ref PatternGrid g, uint track, uint line, out ushort moduleId)
        @safe pure nothrow @nogc {
    foreach_reverse (ln; 0 .. line) {
        immutable NoteCell c = g.at(track, ln);
        if (isStop(c)) {
            return false;
        }
        if (isNote(c)) {
            moduleId = moduleAt(g, track, ln);
            return true;
        }
    }
    return false;
}

private void pinFollowing(ref PatternGrid g, uint track, uint line) @safe pure nothrow @nogc {
    foreach (ln; line + 1 .. g.lines) {
        if (g.at(track, ln).moduleId != 0) {
            return;
        }
        if (isNote(g.at(track, ln))) {
            immutable ushort m = moduleAt(g, track, ln);
            if (m != 0) {
                g.at(track, ln).moduleId = m;
            }
            return;
        }
    }
}

private NoteCell remove(ref PatternGrid g, const ref RollNote n) @safe pure nothrow @nogc {
    pinFollowing(g, n.track, n.line);
    immutable NoteCell taken = g.at(n.track, n.line);
    immutable uint end = n.line + lengthFrom(g, n.track, n.line);
    ushort before = 0;
    if (soundingBefore(g, n.track, n.line, before)) {
        g.at(n.track, n.line) = NoteCell.makeNoteOff(before);
    } else {
        g.at(n.track, n.line) = NoteCell.init;
    }
    if (end < g.lines && g.at(n.track, end).note == NoteCmd.noteOff) {
        NoteCell* e = &g.at(n.track, end);
        if (e.effect == 0 && e.effectVal == 0) {
            *e = NoteCell.init;
        } else {
            e.note = 0;
            e.velocity = 0;
            e.moduleId = 0;
        }
    }
    return taken;
}

private bool rangeFree(const ref PatternGrid g, uint track, uint line, uint end) @safe pure nothrow @nogc {
    immutable NoteCell first = g.at(track, line);
    if (isNote(first)) {
        return false;
    }
    foreach (ln; line + 1 .. end) {
        if (g.at(track, ln).note != 0) {
            return false;
        }
    }
    ushort unused = 0;
    return isStop(first) || !soundingBefore(g, track, line, unused);
}

private bool trackHasNotes(const ref PatternGrid g, uint track) @safe pure nothrow @nogc {
    foreach (ln; 0 .. g.lines) {
        if (isNote(g.at(track, ln))) {
            return true;
        }
    }
    return false;
}

private bool trackOnlyModule(const ref PatternGrid g, uint track, ushort moduleId) @safe pure nothrow @nogc {
    ushort active = 0;
    bool any = false;
    foreach (ln; 0 .. g.lines) {
        immutable NoteCell c = g.at(track, ln);
        if (c.moduleId != 0) {
            active = c.moduleId;
        }
        if (isNote(c)) {
            if (active != moduleId) {
                return false;
            }
            any = true;
        }
    }
    return any;
}

private NoteEdit place(ref PatternGrid g, NoteCell cell, ushort moduleId, uint line, uint length, uint preferTrack,
        out RollNote placed) @safe pure nothrow {
    if (moduleId == 0 || line >= g.lines || length == 0 || !isNote(cell)) {
        return NoteEdit.outOfRange;
    }
    immutable uint end = cast(ulong) line + length > g.lines ? g.lines : line + length;
    immutable ubyte pitch = cast(ubyte)(cell.note - 1);
    foreach (ref other; notesOf(g)) {
        if (other.moduleId == moduleId && other.pitch == pitch && other.line < end && line < other.line + other.length) {
            return NoteEdit.samePitchOverlap;
        }
    }
    uint track = uint.max;
    if (preferTrack < g.tracks && rangeFree(g, preferTrack, line, end)) {
        track = preferTrack;
    }
    if (track == uint.max) {
        foreach (t; 0 .. g.tracks) {
            if (trackOnlyModule(g, t, moduleId) && rangeFree(g, t, line, end)) {
                track = t;
                break;
            }
        }
    }
    if (track == uint.max) {
        foreach (t; 0 .. g.tracks) {
            if (!trackHasNotes(g, t) && rangeFree(g, t, line, end)) {
                track = t;
                break;
            }
        }
    }
    if (track == uint.max) {
        if (!g.addTrack()) {
            return NoteEdit.noFreeTrack;
        }
        track = g.tracks - 1;
    }
    pinFollowing(g, track, line);
    immutable NoteCell old = g.at(track, line);
    cell.moduleId = moduleId;
    if (cell.effect == 0 && cell.effectVal == 0 && cell.paramId == 0) {
        cell.effect = old.effect;
        cell.effectVal = old.effectVal;
        cell.paramId = old.paramId;
    }
    g.at(track, line) = cell;
    if (end < g.lines && g.at(track, end).note == 0) {
        NoteCell* e = &g.at(track, end);
        e.note = NoteCmd.noteOff;
        e.moduleId = moduleId;
    }
    placed = RollNote(track, line, end - line, pitch, cellVelocity(cell), moduleId);
    return NoteEdit.ok;
}
