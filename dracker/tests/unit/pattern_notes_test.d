/**
 * File:         tests/unit/pattern_notes_test.d
 * Module:       tests.unit.pattern_notes_test
 * Phase:        Pattern editor views — T42 (note model for the piano roll)
 *
 * Purpose:
 *   Verifies app.pattern_notes: note lengths from note-offs, following notes and the pattern end; inherited
 *   modules; track choice for new notes (own track, same-module track, empty track, new track, refusal at 64
 *   tracks); same-pitch overlap refusal; delete restoring a cut note; move and resize with note-off handling;
 *   effect columns travelling with a note; all-or-nothing group moves; and 3,000 random edits on one module that
 *   must leave another module's notes untouched and never create same-pitch overlaps.
 *
 * Real-Time & Safety Contract:
 *   Pure single-threaded checks.
 *
 * Dependencies:
 *   Internal: app.pattern_notes, sequencer.note
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T32, T42)
 */
module tests.unit.pattern_notes_test;

version (unittest) {
    import app.pattern_notes;
    import sequencer.note : NoteCell, NoteCmd;

    private PatternGrid grid(uint tracks, uint lines) {
        return PatternGrid(tracks, lines, new NoteCell[cast(size_t) tracks * lines]);
    }

    private RollNote find(const ref PatternGrid g, ushort moduleId, ubyte pitch, uint line) {
        foreach (ref n; notesOf(g)) {
            if (n.moduleId == moduleId && n.pitch == pitch && n.line == line) {
                return n;
            }
        }
        assert(false, "note not found");
    }

    private uint[3][] shape(const ref PatternGrid g, ushort moduleId) {
        uint[3][] list;
        foreach (ref n; notesOf(g)) {
            if (n.moduleId == moduleId) {
                list ~= [cast(uint) n.pitch, n.line, n.length];
            }
        }
        foreach (i; 0 .. list.length) {
            foreach (j; i + 1 .. list.length) {
                if (list[j][1] < list[i][1] || (list[j][1] == list[i][1] && list[j][0] < list[i][0])) {
                    auto t = list[i];
                    list[i] = list[j];
                    list[j] = t;
                }
            }
        }
        return list;
    }

    unittest {
        PatternGrid g = grid(2, 16);
        g.at(0, 0) = NoteCell.makeNote(60, 0.9f, 2);
        g.at(0, 4) = NoteCell.makeNoteOff(2);
        g.at(0, 8) = NoteCell.makeNote(62, 0.5f, 0);
        g.at(0, 12) = NoteCell.makeNote(64, 1.0f, 0);
        g.at(1, 2) = NoteCell.makeNote(48, 0.8f, 3);
        RollNote[] n = notesOf(g);
        assert(n.length == 4);
        assert(n[0].track == 0 && n[0].line == 0 && n[0].length == 4 && n[0].pitch == 60 && n[0].moduleId == 2);
        assert(n[1].line == 8 && n[1].length == 4 && n[1].pitch == 62 && n[1].moduleId == 2);
        assert(n[1].velocity > 0.49f && n[1].velocity < 0.51f);
        assert(n[2].line == 12 && n[2].length == 4 && n[3].track == 1 && n[3].length == 14 && n[3].moduleId == 3);
        PatternGrid empty = grid(4, 8);
        assert(notesOf(empty).length == 0);
        assert(noteEditMessage(NoteEdit.ok) == "" && noteEditMessage(NoteEdit.noFreeTrack).length > 0);
        assert(noteEditMessage(NoteEdit.samePitchOverlap).length > 0 && noteEditMessage(NoteEdit.outOfRange).length > 0);
        assert(noteEditMessage(NoteEdit.notFound).length > 0);
    }

    unittest {
        PatternGrid g = grid(1, 16);
        RollNote p;
        assert(addNote(g, 1, 60, 4, 4, 0.8f, p) == NoteEdit.ok);
        assert(p.track == 0 && p.line == 4 && p.length == 4 && p.pitch == 60 && p.moduleId == 1);
        assert(g.at(0, 4).note == 61 && g.at(0, 4).moduleId == 1 && g.at(0, 8).note == NoteCmd.noteOff);
        assert(notesOf(g).length == 1 && notesOf(g)[0].length == 4);

        assert(addNote(g, 1, 64, 6, 4, 0.8f, p) == NoteEdit.ok);
        assert(g.tracks == 2 && p.track == 1 && g.at(1, 6).note == 65 && g.at(1, 10).note == NoteCmd.noteOff);
        assert(g.at(0, 4).note == 61 && g.at(0, 8).note == NoteCmd.noteOff);

        assert(addNote(g, 1, 65, 8, 4, 0.8f, p) == NoteEdit.ok);
        assert(p.track == 0 && g.at(0, 8).note == 66 && g.at(0, 12).note == NoteCmd.noteOff);
        assert(find(g, 1, 60, 4).length == 4 && find(g, 1, 65, 8).length == 4);

        PatternGrid before = g.dup();
        assert(addNote(g, 1, 60, 6, 4, 0.8f, p) == NoteEdit.samePitchOverlap);
        assert(addNote(g, 1, 60, 2, 3, 0.8f, p) == NoteEdit.samePitchOverlap);
        assert(addNote(g, 1, 60, 16, 1, 0.8f, p) == NoteEdit.outOfRange);
        assert(addNote(g, 1, 61, 0, 0, 0.8f, p) == NoteEdit.outOfRange);
        assert(addNote(g, 0, 61, 0, 1, 0.8f, p) == NoteEdit.outOfRange);
        assert(g.cells == before.cells && g.tracks == before.tracks);
        assert(addNote(g, 1, 60, 8, 2, 0.8f, p) == NoteEdit.ok && p.track == 2 && g.tracks == 3);

        assert(addNote(g, 2, 40, 0, 2, 0.8f, p) == NoteEdit.ok);
        assert(p.track == g.tracks - 1 && p.moduleId == 2);
        immutable uint m2track = p.track;
        assert(addNote(g, 2, 41, 4, 2, 0.8f, p) == NoteEdit.ok && p.track == m2track);

        assert(addNote(g, 1, 70, 14, 8, 0.8f, p) == NoteEdit.ok && p.length == 2);
        assert(find(g, 1, 70, 14).length == 2);

        PatternGrid full = grid(64, 4);
        foreach (t; 0 .. 64) {
            full.at(t, 0) = NoteCell.makeNote(t, 0.8f, 1);
        }
        assert(addNote(full, 1, 100, 0, 2, 0.8f, p) == NoteEdit.noFreeTrack && full.tracks == 64);
        assert(addNote(full, 1, 100, 1, 2, 0.8f, p) == NoteEdit.noFreeTrack);
        PatternGrid emptyTrack = grid(2, 8);
        emptyTrack.at(0, 0) = NoteCell.makeNote(50, 0.8f, 7);
        assert(addNote(emptyTrack, 1, 60, 0, 4, 0.8f, p) == NoteEdit.ok && p.track == 1 && emptyTrack.tracks == 2);
    }

    unittest {
        PatternGrid g = grid(1, 16);
        g.at(0, 0) = NoteCell.makeNote(60, 0.8f, 1);
        g.at(0, 4) = NoteCell.makeNote(62, 0.8f, 1);
        g.at(0, 8) = NoteCell.makeNoteOff(1);
        assert(find(g, 1, 60, 0).length == 4 && find(g, 1, 62, 4).length == 4);
        assert(deleteNote(g, find(g, 1, 62, 4)) == NoteEdit.ok);
        assert(g.at(0, 4).note == NoteCmd.noteOff && g.at(0, 8).note == 0);
        assert(notesOf(g).length == 1 && find(g, 1, 60, 0).length == 4);
        assert(deleteNote(g, RollNote(0, 4, 4, 62, 0.8f, 1)) == NoteEdit.notFound);
        assert(deleteNote(g, find(g, 1, 60, 0)) == NoteEdit.ok);
        assert(g.at(0, 0).note == 0 && notesOf(g).length == 0);

        PatternGrid h = grid(1, 16);
        h.at(0, 0) = NoteCell.makeNote(60, 0.8f, 2);
        h.at(0, 8) = NoteCell.makeNote(64, 0.8f, 0);
        assert(find(h, 2, 64, 8).moduleId == 2);
        assert(deleteNote(h, find(h, 2, 60, 0)) == NoteEdit.ok);
        assert(h.at(0, 8).moduleId == 2 && find(h, 2, 64, 8).length == 8);

        PatternGrid k = grid(2, 8);
        RollNote a, b;
        assert(addNote(k, 1, 60, 0, 2, 0.8f, a) == NoteEdit.ok && addNote(k, 1, 62, 4, 2, 0.8f, b) == NoteEdit.ok);
        PatternGrid snap = k.dup();
        assert(deleteNotes(k, [a, RollNote(1, 7, 1, 1, 0.8f, 1)]) == NoteEdit.notFound && k.cells == snap.cells);
        assert(deleteNotes(k, [a, b]) == NoteEdit.ok && notesOf(k).length == 0);
        foreach (ref c; k.cells) {
            assert(c.note == 0);
        }
    }

    unittest {
        PatternGrid g = grid(2, 16);
        RollNote a, b, m;
        assert(addNote(g, 1, 60, 0, 4, 0.8f, a) == NoteEdit.ok);
        assert(addNote(g, 1, 64, 8, 4, 0.6f, b) == NoteEdit.ok && b.track == 0);
        g.at(0, 0).effect = 5;
        g.at(0, 0).effectVal = 7;

        assert(moveNote(g, a, 2, 3, m) == NoteEdit.ok);
        assert(m.track == 0 && m.line == 2 && m.pitch == 63 && m.length == 4);
        assert(g.at(0, 0).note == 0 && g.at(0, 0).effect == 0 && g.at(0, 4).note == 0);
        assert(g.at(0, 2).note == 64 && g.at(0, 2).effect == 5 && g.at(0, 2).effectVal == 7);
        assert(g.at(0, 6).note == NoteCmd.noteOff && find(g, 1, 64, 8).length == 4);

        assert(moveNote(g, m, 5, 0, m) == NoteEdit.ok);
        assert(m.line == 7 && m.track == 1 && g.at(1, 7).effect == 5 && find(g, 1, 64, 8).track == 0);
        assert(shape(g, 1) == [[63u, 7u, 4u], [64u, 8u, 4u]]);

        PatternGrid before = g.dup();
        assert(moveNote(g, m, 1, 1, m) == NoteEdit.samePitchOverlap);
        assert(moveNote(g, find(g, 1, 63, 7), -8, 0, m) == NoteEdit.outOfRange);
        assert(moveNote(g, find(g, 1, 63, 7), 0, 100, m) == NoteEdit.outOfRange);
        assert(moveNote(g, RollNote(0, 3, 1, 1, 0.8f, 1), 1, 0, m) == NoteEdit.notFound);
        assert(g.cells == before.cells);

        assert(moveNote(g, find(g, 1, 64, 8), 6, 0, m) == NoteEdit.ok && m.line == 14 && m.length == 2);

        RollNote r;
        PatternGrid s = grid(1, 16);
        assert(addNote(s, 1, 60, 0, 8, 0.8f, a) == NoteEdit.ok && s.at(0, 8).note == NoteCmd.noteOff);
        assert(resizeNote(s, a, 3, r) == NoteEdit.ok && r.length == 3 && r.track == 0);
        assert(s.at(0, 3).note == NoteCmd.noteOff && s.at(0, 8).note == 0);
        assert(resizeNote(s, r, 12, r) == NoteEdit.ok && r.length == 12 && s.at(0, 3).note == 0 && s.at(0, 12).note == NoteCmd.noteOff);
        assert(resizeNote(s, r, 100, r) == NoteEdit.ok && r.length == 16 && s.at(0, 12).note == 0);
        RollNote unusedOut;
        assert(resizeNote(s, r, 0, unusedOut) == NoteEdit.outOfRange);
        assert(resizeNote(s, r, 4, r) == NoteEdit.ok);
        assert(addNote(s, 1, 62, 4, 4, 0.8f, b) == NoteEdit.ok && b.track == 0 && s.tracks == 1);
        assert(resizeNote(s, r, 6, r) == NoteEdit.ok && r.track == 1 && s.tracks == 2);
        assert(shape(s, 1) == [[60u, 0u, 6u], [62u, 4u, 4u]]);

        assert(setNoteVelocity(s, r, 0.25f) == NoteEdit.ok);
        assert(find(s, 1, 60, 0).velocity > 0.24f && find(s, 1, 60, 0).velocity < 0.26f);
        assert(setNoteVelocity(s, RollNote(0, 9, 1, 1, 0.8f, 1), 0.5f) == NoteEdit.notFound);
    }

    unittest {
        PatternGrid g = grid(1, 32);
        RollNote c, e, gg;
        assert(addNote(g, 1, 60, 0, 4, 0.8f, c) == NoteEdit.ok);
        assert(addNote(g, 1, 64, 0, 4, 0.8f, e) == NoteEdit.ok);
        assert(addNote(g, 1, 67, 0, 4, 0.8f, gg) == NoteEdit.ok);
        assert(g.tracks == 3);
        RollNote[] moved;
        assert(moveNotes(g, [c, e, gg], 8, 2, moved) == NoteEdit.ok);
        assert(moved.length == 3 && shape(g, 1) == [[62u, 8u, 4u], [66u, 8u, 4u], [69u, 8u, 4u]]);
        assert(g.tracks == 3);
        PatternGrid before = g.dup();
        RollNote[] placed = moved.dup;
        RollNote[] ignored;
        assert(moveNotes(g, placed, 0, 60, ignored) == NoteEdit.outOfRange && g.cells == before.cells);
        assert(moveNotes(g, placed, -9, 0, ignored) == NoteEdit.outOfRange && g.cells == before.cells);
        assert(moveNotes(g, null, 3, 3, ignored) == NoteEdit.ok && g.cells == before.cells);
        RollNote blocker;
        assert(addNote(g, 1, 64, 0, 4, 0.8f, blocker) == NoteEdit.ok);
        before = g.dup();
        RollNote[] chord = [find(g, 1, 62, 8), find(g, 1, 66, 8), find(g, 1, 69, 8)];
        assert(moveNotes(g, chord, -8, -2, moved) == NoteEdit.samePitchOverlap && g.cells == before.cells);
        assert(moveNotes(g, chord, -8, 0, moved) == NoteEdit.ok);
        assert(shape(g, 1) == [[62u, 0u, 4u], [64u, 0u, 4u], [66u, 0u, 4u], [69u, 0u, 4u]]);
    }

    unittest {
        ulong state = 0x1234_5678_9ABC_DEF0uL;
        uint rnd(uint bound) {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            return cast(uint)((state >> 20) % bound);
        }

        PatternGrid g = grid(3, 48);
        g.at(0, 0) = NoteCell.makeNote(36, 0.8f, 7);
        g.at(0, 6) = NoteCell.makeNote(38, 0.8f, 0);
        g.at(0, 12) = NoteCell.makeNoteOff(0);
        g.at(0, 20) = NoteCell.makeNote(40, 0.8f, 0);
        g.at(1, 4) = NoteCell.makeNote(43, 0.8f, 7);
        g.at(1, 30) = NoteCell.makeNote(45, 0.8f, 7);
        immutable uint[3][] fixed = shape(g, 7).idup;
        assert(fixed.length == 5);
        size_t okAdds = 0, okMoves = 0, okResizes = 0, okDeletes = 0, refused = 0;
        foreach (step; 0 .. 3000) {
            RollNote[] mine;
            foreach (ref n; notesOf(g)) {
                if (n.moduleId == 9) {
                    mine ~= n;
                }
            }
            RollNote res;
            NoteEdit r;
            immutable uint op = mine.length == 0 ? 0 : rnd(mine.length > 40 ? 6 : 4);
            if (op == 0) {
                r = addNote(g, 9, cast(ubyte)(48 + rnd(24)), rnd(52), 1 + rnd(10), 0.1f + rnd(9) / 10.0f, res);
                okAdds += r == NoteEdit.ok;
            } else if (op == 1) {
                r = moveNote(g, mine[rnd(cast(uint) mine.length)], cast(int) rnd(13) - 6, cast(int) rnd(9) - 4, res);
                okMoves += r == NoteEdit.ok;
            } else if (op == 2) {
                r = resizeNote(g, mine[rnd(cast(uint) mine.length)], rnd(14), res);
                okResizes += r == NoteEdit.ok;
            } else {
                r = deleteNote(g, mine[rnd(cast(uint) mine.length)]);
                okDeletes += r == NoteEdit.ok;
            }
            refused += r != NoteEdit.ok;
            assert(g.cells.length == cast(size_t) g.tracks * g.lines && g.tracks <= ROLL_MAX_TRACKS);
            assert(shape(g, 7) == fixed);
            RollNote[] all = notesOf(g);
            foreach (i, ref x; all) {
                assert(x.moduleId == 7 || x.moduleId == 9);
                assert(x.length >= 1 && x.line + x.length <= g.lines);
                foreach (ref y; all[i + 1 .. $]) {
                    if (x.moduleId == y.moduleId && x.pitch == y.pitch) {
                        assert(x.line + x.length <= y.line || y.line + y.length <= x.line);
                    }
                    if (x.track == y.track) {
                        assert(x.line + x.length <= y.line || y.line + y.length <= x.line);
                    }
                }
            }
        }
        assert(okAdds > 100 && okMoves > 100 && okResizes > 100 && okDeletes > 100 && refused > 50);
    }
}
