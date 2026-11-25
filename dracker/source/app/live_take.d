/**
 * File:         source/app/live_take.d
 * Module:       app.live_take
 * Phase:        Live record mode — take capture
 *
 * Purpose:
 *   Turns timestamped live note-ons/note-offs (QWERTY, MIDI, on-screen piano) into the cells of a new pattern.
 *   Song positions are fractional lines (line + tick / ticksPerLine) and are snapped to the nearest line relative
 *   to the take start line. Notes that start less than one line after the first note of a chord group land on
 *   that group's line, on separate tracks. Each note goes to the lowest track that is not holding a note (held
 *   notes keep sounding under later notes); when every track is busy, the oldest held note is cut. A release
 *   writes a note-off (===) at its snapped line, at least one line after its note-on. finish() releases held notes
 *   and returns a pattern trimmed to the last bar used.
 *
 * Real-Time & Safety Contract:
 *   UI thread only; GC-backed, never touched by the RT thread.
 *
 * Dependencies:
 *   Internal: io.project_format (MAX_LINES, MAX_TRACKS), sequencer.note
 *   External: std.math (floor, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct LiveTakeResult { tracks, lines, cells, notes }
 *   - final class LiveTakeRecorder : this(startLine, maxTracks, maxLines), startLine(), noteCount(), heldCount(),
 *     isHeld(), snapLine(), noteOn(), noteOff(), finish()
 *
 * See_Also:
 *   docs/changelog.md (live record mode), docs/manual.md §8.10
 */
module app.live_take;

import std.math : floor, isFinite;

import io.project_format : MAX_LINES, MAX_TRACKS;
import sequencer.note : NoteCell;

/**
 * Finished take: pattern dimensions and line-major cells (cells[line * tracks + track]).
 */
struct LiveTakeResult {
    uint tracks = 0;
    uint lines = 0;
    NoteCell[] cells;
    size_t notes = 0;
}

private struct TakeTrack {
    bool holding = false;
    uint holdTag = 0;
    uint onLine = 0;
    uint freeFromLine = 0;
}

/**
 * Accumulates one live-record take.
 */
final class LiveTakeRecorder {
    enum uint BAR_LINES = 16;
    enum uint MIN_TRACKS = 4;
    enum double CHORD_WINDOW_LINES = 1.0;
    enum double COUNT_IN_TOLERANCE_LINES = 0.5;

    private long startLine_ = 0;
    private uint maxTracks_ = MAX_TRACKS;
    private uint maxLines_ = MAX_LINES;
    private NoteCell[][] columns_;
    private TakeTrack[] tracks_;
    private uint[uint] held_;
    private size_t notes_ = 0;
    private uint usedTracks_ = 0;
    private long lastLine_ = -1;
    private bool haveGroup_ = false;
    private double groupAnchor_ = 0.0;
    private uint groupLine_ = 0;

    /**
     * Starts an empty take.
     *
     * Params:
     *   startLine = Song line that becomes pattern line 0.
     *   maxTracks = Track cap (clamped to [1, MAX_TRACKS]).
     *   maxLines = Line cap (clamped to [1, MAX_LINES]).
     */
    this(long startLine, uint maxTracks = MAX_TRACKS, uint maxLines = MAX_LINES) {
        startLine_ = startLine;
        maxTracks_ = maxTracks == 0 ? 1 : (maxTracks > MAX_TRACKS ? MAX_TRACKS : maxTracks);
        maxLines_ = maxLines == 0 ? 1 : (maxLines > MAX_LINES ? MAX_LINES : maxLines);
        columns_ = new NoteCell[][maxTracks_];
        tracks_ = new TakeTrack[maxTracks_];
    }

    /**
     * Returns the song line mapped to pattern line 0.
     *
     * Returns:
     *   Start line.
     */
    long startLine() const {
        return startLine_;
    }

    /**
     * Returns the number of note-ons recorded so far.
     *
     * Returns:
     *   Note count.
     */
    size_t noteCount() const {
        return notes_;
    }

    /**
     * Returns the number of notes currently held.
     *
     * Returns:
     *   Held count.
     */
    size_t heldCount() const {
        return held_.length;
    }

    /**
     * Reports whether the note started with tag is still held.
     *
     * Params:
     *   tag = Source tag passed to noteOn().
     *
     * Returns:
     *   True if held.
     */
    bool isHeld(uint tag) const {
        return (tag in held_) !is null;
    }

    /**
     * Snaps a song position to the nearest pattern line of this take.
     *
     * Params:
     *   songPos = Fractional song line.
     *
     * Returns:
     *   Pattern line (may be negative before the take start).
     */
    long snapLine(double songPos) const {
        if (!isFinite(songPos)) {
            return -1;
        }
        return cast(long) floor(songPos - cast(double) startLine_ + 0.5);
    }

    /**
     * Records a note-on.
     *
     * Params:
     *   tag = Unique id of the key/source, used to match the release.
     *   midi = MIDI note 0..127.
     *   velocity = Normalized velocity.
     *   moduleId = Target module written into the cell.
     *   songPos = Fractional song line of the press.
     *
     * Returns:
     *   True if a cell was written (false during the count-in, past the line cap, or when no track is free).
     */
    bool noteOn(uint tag, ubyte midi, float velocity, ushort moduleId, double songPos) {
        if (!isFinite(songPos) || midi > 127) {
            return false;
        }
        immutable double rel = songPos - cast(double) startLine_;
        if (rel < -COUNT_IN_TOLERANCE_LINES) {
            return false;
        }
        if (isHeld(tag)) {
            noteOff(tag, songPos);
        }
        immutable bool inGroup = haveGroup_ && rel >= groupAnchor_ && rel - groupAnchor_ < CHORD_WINDOW_LINES;
        long line;
        if (inGroup) {
            line = groupLine_;
        } else {
            line = snapLine(songPos);
            if (line < 0) {
                line = 0;
            }
        }
        if (line >= maxLines_) {
            return false;
        }
        immutable uint ln = cast(uint) line;
        immutable int t = pickTrack(ln);
        if (t < 0) {
            return false;
        }
        if (!inGroup) {
            haveGroup_ = true;
            groupAnchor_ = rel;
            groupLine_ = ln;
        }
        immutable uint tr = cast(uint) t;
        if (tracks_[tr].holding) {
            held_.remove(tracks_[tr].holdTag);
        }
        put(tr, ln, NoteCell.makeNote(midi, velocity, moduleId));
        tracks_[tr] = TakeTrack(true, tag, ln, ln);
        held_[tag] = tr;
        notes_++;
        if (tr + 1 > usedTracks_) {
            usedTracks_ = tr + 1;
        }
        if (line > lastLine_) {
            lastLine_ = line;
        }
        return true;
    }

    /**
     * Records the release of a held note as a note-off at its snapped line (at least one line after the note-on).
     *
     * Params:
     *   tag = Source tag passed to noteOn().
     *   songPos = Fractional song line of the release.
     *
     * Returns:
     *   True if the tag was held.
     */
    bool noteOff(uint tag, double songPos) {
        auto p = tag in held_;
        if (p is null) {
            return false;
        }
        immutable uint tr = *p;
        held_.remove(tag);
        TakeTrack st = tracks_[tr];
        long off = snapLine(songPos);
        if (off <= cast(long) st.onLine) {
            off = cast(long) st.onLine + 1;
        }
        uint freeFrom = st.onLine + 1;
        if (off < maxLines_) {
            immutable uint offLn = cast(uint) off;
            immutable NoteCell existing = cellAt(tr, offLn);
            if (!existing.isMidiNote()) {
                put(tr, offLn, NoteCell.makeNoteOff());
            }
            freeFrom = offLn;
            if (off > lastLine_) {
                lastLine_ = off;
            }
        }
        tracks_[tr] = TakeTrack(false, 0, st.onLine, freeFrom);
        return true;
    }

    /**
     * Releases held notes at songPos and returns the take as pattern cells trimmed to the last bar used.
     *
     * Params:
     *   songPos = Fractional song line where recording stopped.
     *
     * Returns:
     *   Result with notes == 0 (and no cells) when nothing was recorded.
     */
    LiveTakeResult finish(double songPos) {
        uint[] tags;
        foreach (tag, tr; held_) {
            tags ~= tag;
        }
        foreach (tag; tags) {
            noteOff(tag, songPos);
        }
        LiveTakeResult res;
        res.notes = notes_;
        if (notes_ == 0 || lastLine_ < 0) {
            return res;
        }
        res.tracks = usedTracks_ > MIN_TRACKS ? usedTracks_ : MIN_TRACKS;
        if (res.tracks > maxTracks_) {
            res.tracks = maxTracks_;
        }
        immutable ulong used = cast(ulong) lastLine_ + 1;
        ulong lines = ((used + BAR_LINES - 1) / BAR_LINES) * BAR_LINES;
        if (lines > maxLines_) {
            lines = maxLines_;
        }
        res.lines = cast(uint) lines;
        res.cells = new NoteCell[cast(size_t) res.tracks * res.lines];
        foreach (t; 0 .. res.tracks) {
            foreach (l, c; columns_[t]) {
                if (l < res.lines) {
                    res.cells[l * res.tracks + t] = c;
                }
            }
        }
        return res;
    }

    private int pickTrack(uint line) const {
        foreach (t; 0 .. maxTracks_) {
            const st = tracks_[t];
            if (!st.holding && st.freeFromLine <= line && !cellAt(t, line).isMidiNote()) {
                return cast(int) t;
            }
        }
        int oldest = -1;
        foreach (t; 0 .. maxTracks_) {
            const st = tracks_[t];
            if (st.holding && st.onLine < line && (oldest < 0 || st.onLine < tracks_[oldest].onLine)) {
                oldest = cast(int) t;
            }
        }
        return oldest;
    }

    private NoteCell cellAt(uint track, uint line) const {
        return line < columns_[track].length ? columns_[track][line] : NoteCell.init;
    }

    private void put(uint track, uint line, NoteCell c) {
        if (columns_[track].length <= line) {
            columns_[track].length = line + 1;
        }
        columns_[track][line] = c;
    }
}
