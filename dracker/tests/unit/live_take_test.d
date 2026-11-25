/**
 * File:         tests/unit/live_take_test.d
 * Module:       tests.unit.live_take_test
 * Phase:        Live record mode — take capture tests
 *
 * Purpose:
 *   Verifies LiveTakeRecorder: nearest-line snapping relative to the take start, count-in notes dropped (with a
 *   half-line tolerance), chord grouping within one line onto separate tracks, held-note-aware track allocation,
 *   note-offs at the snapped release line (at least one line after the note), re-pressing a held tag, oldest-note
 *   stealing when every track is busy, the line cap, and finish() trimming to whole bars with at least 4 tracks.
 *
 * Real-Time & Safety Contract:
 *   UI-thread logic only; no RT paths.
 *
 * Dependencies:
 *   Internal: app.live_take, sequencer.note
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites for LiveTakeRecorder
 *
 * See_Also:
 *   source/app/live_take.d
 */
module tests.unit.live_take_test;

version (unittest) {
    import app.live_take : LiveTakeRecorder, LiveTakeResult;
    import sequencer.note : NoteCell, NoteCmd;

    private NoteCell at(const ref LiveTakeResult r, uint track, uint line) {
        return r.cells[cast(size_t) line * r.tracks + track];
    }

    unittest {
        auto take = new LiveTakeRecorder(32);
        assert(take.snapLine(32.0) == 0 && take.snapLine(32.49) == 0 && take.snapLine(32.5) == 1);
        assert(take.snapLine(31.6) == 0 && take.snapLine(30.0) == -2);
        assert(!take.noteOn(1, 60, 1.0f, 2, 20.0));
        assert(!take.noteOn(1, 60, 1.0f, 2, 31.4));
        assert(take.noteCount() == 0);
        LiveTakeResult empty = take.finish(40.0);
        assert(empty.notes == 0 && empty.cells.length == 0 && empty.lines == 0);
    }

    unittest {
        auto take = new LiveTakeRecorder(0);
        assert(take.noteOn(1, 60, 1.0f, 2, -0.3));
        assert(take.noteOn(2, 64, 0.5f, 2, 0.4));
        assert(take.noteOn(3, 67, 0.5f, 2, 0.6));
        assert(take.noteOn(4, 72, 0.5f, 2, 1.1));
        assert(take.heldCount() == 4);
        assert(take.noteOff(1, 3.2));
        assert(take.noteOff(2, 3.6));
        assert(take.noteOff(3, 3.0));
        assert(!take.noteOff(3, 3.0));
        assert(take.noteOff(4, 1.3));
        LiveTakeResult r = take.finish(4.0);
        assert(r.notes == 4 && r.tracks == 4 && r.lines == 16 && r.cells.length == 64);
        assert(at(r, 0, 0).note == NoteCell.encodeMidiNote(60) && at(r, 0, 0).moduleId == 2);
        assert(at(r, 1, 0).note == NoteCell.encodeMidiNote(64));
        assert(at(r, 2, 0).note == NoteCell.encodeMidiNote(67));
        assert(at(r, 3, 1).note == NoteCell.encodeMidiNote(72));
        assert(at(r, 0, 3).note == NoteCmd.noteOff && at(r, 1, 4).note == NoteCmd.noteOff);
        assert(at(r, 2, 3).note == NoteCmd.noteOff);
        assert(at(r, 3, 2).note == NoteCmd.noteOff);
        assert(at(r, 3, 1).normalizedVelocity() > 0.45f && at(r, 3, 1).normalizedVelocity() < 0.55f);
    }

    unittest {
        auto take = new LiveTakeRecorder(10);
        assert(take.noteOn(1, 48, 1.0f, 3, 10.0));
        assert(take.noteOn(2, 52, 1.0f, 3, 12.0));
        assert(take.noteOff(2, 13.0));
        assert(take.noteOn(3, 55, 1.0f, 3, 13.0));
        assert(take.noteOn(4, 57, 1.0f, 3, 15.0));
        assert(take.noteOn(5, 59, 1.0f, 3, 15.2));
        assert(take.noteOn(6, 60, 1.0f, 3, 15.9));
        assert(take.noteOn(7, 62, 1.0f, 3, 16.1));
        assert(take.noteOn(3, 67, 1.0f, 3, 17.2));
        LiveTakeResult r = take.finish(30.0);
        assert(r.notes == 8 && r.tracks == 6 && r.lines == 32);
        assert(at(r, 0, 0).note == NoteCell.encodeMidiNote(48) && at(r, 0, 20).note == NoteCmd.noteOff);
        assert(at(r, 1, 2).note == NoteCell.encodeMidiNote(52));
        assert(at(r, 1, 3).note == NoteCell.encodeMidiNote(55));
        assert(at(r, 2, 5).note == NoteCell.encodeMidiNote(57));
        assert(at(r, 3, 5).note == NoteCell.encodeMidiNote(59));
        assert(at(r, 4, 5).note == NoteCell.encodeMidiNote(60));
        assert(at(r, 5, 6).note == NoteCell.encodeMidiNote(62));
        assert(at(r, 1, 7).note == NoteCell.encodeMidiNote(67));
        assert(at(r, 0, 20).moduleId == 0);
        foreach (t; 1 .. 6) {
            assert(at(r, t, 20).note == NoteCmd.noteOff);
        }
    }

    unittest {
        auto take = new LiveTakeRecorder(0, 2, 40);
        assert(take.noteOn(1, 60, 1.0f, 2, 0.0));
        assert(take.noteOn(2, 62, 1.0f, 2, 2.0));
        assert(take.noteOn(3, 64, 1.0f, 2, 4.0));
        assert(!take.isHeld(1) && take.isHeld(2) && take.isHeld(3));
        assert(take.noteOn(4, 65, 1.0f, 2, 4.2));
        assert(!take.isHeld(2) && take.isHeld(4));
        assert(!take.noteOn(5, 67, 1.0f, 2, 39.6));
        assert(take.noteOn(6, 69, 1.0f, 2, 39.0));
        LiveTakeResult r = take.finish(45.0);
        assert(r.tracks == 2 && r.lines == 40);
        assert(at(r, 0, 0).note == NoteCell.encodeMidiNote(60));
        assert(at(r, 0, 4).note == NoteCell.encodeMidiNote(64));
        assert(at(r, 1, 2).note == NoteCell.encodeMidiNote(62));
        assert(at(r, 1, 4).note == NoteCell.encodeMidiNote(65));
        assert(at(r, 0, 39).note == NoteCell.encodeMidiNote(69));
    }
}
