/**
 * File:         tests/unit/pattern_ops_test.d
 * Module:       tests.unit.pattern_ops_test
 * Phase:        Phase 7.5.5 — Pattern Block Operations & Clipboard Codec Tests
 *
 * Purpose:
 *   Verifies PatternBlock extraction and clipped writes at every pattern edge, mix-paste (skipEmpty), region
 *   clearing, transpose range limits and NoteCmd preservation, velocity/effectValue/paramId interpolation
 *   (rounding, sparse vs. fill mode, fewer than two cells), SynthTracker-Block-v1 round-trips over
 *   deterministic random blocks, and strict rejection of malformed clipboard text.
 *
 * Real-Time & Safety Contract:
 *   Headless, off-RT pure helper tests; deterministic SplitMix64 seeding for reproducible random blocks.
 *
 * Dependencies:
 *   Internal: app.pattern_ops, sequencer.note
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites for app.pattern_ops
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.pattern_ops_test;

version (unittest) {
    import app.pattern_ops : BLOCK_TEXT_MAGIC, blockDimsAllowed, clearBlock, clearRegion, decodeBlockText,
        encodeBlockText, extractBlock, interpolateColumn, InterpolateField, MAX_BLOCK_LINES, MAX_BLOCK_TRACKS,
        PatternBlock, transposeBlock, writeBlockInto;
    import sequencer.note : NoteCell, NoteCmd;

    private struct TestRng {
        ulong state = 0x1234_5678_9ABC_DEF0uL;

        ulong next() @safe @nogc nothrow pure {
            state += 0x9E37_79B9_7F4A_7C15uL;
            ulong z = state;
            z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9uL;
            z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EBuL;
            return z ^ (z >> 31);
        }

        uint below(uint bound) @safe @nogc nothrow pure {
            return bound <= 1 ? 0 : cast(uint)(next() % bound);
        }
    }

    private NoteCell tagCell(uint track, uint line) @safe nothrow pure {
        NoteCell c;
        c.note = cast(ubyte)(1 + (track * 7 + line) % 128);
        c.moduleId = cast(ushort)(track + 1);
        c.paramId = cast(ushort)(line + 1);
        return c;
    }

    private NoteCell[] makePattern(uint tracks, uint lines) @safe nothrow pure {
        auto cells = new NoteCell[](tracks * lines);
        foreach (l; 0 .. lines) {
            foreach (t; 0 .. tracks) {
                cells[l * tracks + t] = tagCell(t, l);
            }
        }
        return cells;
    }

    private PatternBlock randomBlock(ref TestRng rng, uint tracks, uint lines) @safe nothrow {
        PatternBlock b = PatternBlock.create(tracks, lines);
        foreach (ref c; b.cells) {
            immutable uint kind = rng.below(4);
            if (kind == 0) {
                continue;
            }
            c = NoteCell.unpackU64(rng.next());
            if (kind == 1) {
                c.note = NoteCmd.noteOff;
            }
        }
        return b;
    }

    private NoteCell noteAt(int midi, ubyte vel = 0) @safe nothrow pure {
        NoteCell c;
        c.note = cast(ubyte)(midi + 1);
        c.velocity = vel;
        return c;
    }

    unittest {
        auto pat = makePattern(8, 16);
        PatternBlock b = extractBlock(pat, 8, 16, 2, 3, 3, 4);
        assert(b.isValid());
        assert(b.tracks == 3 && b.lines == 4);
        foreach (l; 0 .. 4u) {
            foreach (t; 0 .. 3u) {
                assert(b.at(t, l) == tagCell(t + 2, l + 3));
            }
        }
        assert(b.at(3, 0) == NoteCell.init);
        assert(b.at(0, 4) == NoteCell.init);
    }

    unittest {
        auto pat = makePattern(8, 16);
        PatternBlock right = extractBlock(pat, 8, 16, 6, 14, 10, 10);
        assert(right.tracks == 2 && right.lines == 2);
        assert(right.at(1, 1) == tagCell(7, 15));
        PatternBlock corner = extractBlock(pat, 8, 16, 7, 15, 1, 1);
        assert(corner.tracks == 1 && corner.lines == 1 && corner.cells[0] == tagCell(7, 15));
        PatternBlock whole = extractBlock(pat, 8, 16, 0, 0, uint.max, uint.max);
        assert(whole.tracks == 8 && whole.lines == 16 && whole.cells == pat);
        assert(!extractBlock(pat, 8, 16, 8, 0, 1, 1).isValid());
        assert(!extractBlock(pat, 8, 16, 0, 16, 1, 1).isValid());
        assert(!extractBlock(pat, 8, 16, 0, 0, 0, 4).isValid());
        assert(!extractBlock(pat, 8, 16, 0, 0, 4, 0).isValid());
        assert(!extractBlock(pat[0 .. 100], 8, 16, 0, 0, 2, 2).isValid());
        assert(!extractBlock(pat, 0, 16, 0, 0, 2, 2).isValid());
    }

    unittest {
        auto wide = new NoteCell[](100 * 2);
        PatternBlock capped = extractBlock(wide, 100, 2, 0, 0, 100, 2);
        assert(capped.isValid() && capped.tracks == MAX_BLOCK_TRACKS && capped.lines == 2);
    }

    unittest {
        auto pat = new NoteCell[](4 * 4);
        PatternBlock b = PatternBlock.create(3, 3);
        foreach (i, ref c; b.cells) {
            c = noteAt(cast(int)(40 + i));
        }
        assert(writeBlockInto(pat, 4, 4, 0, 0, b) == 9);
        assert(pat[0] == noteAt(40) && pat[2 * 4 + 2] == noteAt(48) && pat[3] == NoteCell.init);

        auto pat2 = new NoteCell[](4 * 4);
        assert(writeBlockInto(pat2, 4, 4, 2, 3, b) == 2);
        assert(pat2[3 * 4 + 2] == noteAt(40));
        assert(pat2[3 * 4 + 3] == noteAt(41));
        foreach (i; 0 .. 14) {
            assert(pat2[i] == NoteCell.init);
        }

        assert(writeBlockInto(pat2, 4, 4, 4, 0, b) == 0);
        assert(writeBlockInto(pat2, 4, 4, 0, 4, b) == 0);
        PatternBlock invalid;
        assert(writeBlockInto(pat2, 4, 4, 0, 0, invalid) == 0);
        assert(writeBlockInto(pat2[0 .. 10], 4, 4, 0, 0, b) == 0);
    }

    unittest {
        auto pat = makePattern(4, 4);
        PatternBlock b = PatternBlock.create(2, 2);
        b.set(0, 0, noteAt(10));
        b.set(1, 1, noteAt(11));
        auto overwrite = pat.dup;
        assert(writeBlockInto(overwrite, 4, 4, 1, 1, b, false) == 4);
        assert(overwrite[1 * 4 + 2] == NoteCell.init);
        assert(overwrite[2 * 4 + 1] == NoteCell.init);
        auto mixed = pat.dup;
        assert(writeBlockInto(mixed, 4, 4, 1, 1, b, true) == 2);
        assert(mixed[1 * 4 + 1] == noteAt(10));
        assert(mixed[2 * 4 + 2] == noteAt(11));
        assert(mixed[1 * 4 + 2] == tagCell(2, 1));
        assert(mixed[2 * 4 + 1] == tagCell(1, 2));
    }

    unittest {
        auto pat = makePattern(4, 4);
        assert(clearRegion(pat, 4, 4, 2, 2, 5, 5) == 4);
        foreach (l; 0 .. 4u) {
            foreach (t; 0 .. 4u) {
                immutable bool inside = t >= 2 && l >= 2;
                assert((pat[l * 4 + t] == NoteCell.init) == inside);
            }
        }
        assert(clearRegion(pat, 4, 4, 4, 0, 1, 1) == 0);
        assert(clearRegion(pat, 4, 4, 0, 0, 0, 3) == 0);
        assert(clearRegion(pat[0 .. 3], 4, 4, 0, 0, 1, 1) == 0);

        PatternBlock b = extractBlock(makePattern(3, 3), 3, 3, 0, 0, 3, 3);
        assert(clearBlock(b) == 9);
        assert(b.isValid());
        foreach (ref c; b.cells) {
            assert(c.isEmpty());
        }
        PatternBlock invalid;
        assert(clearBlock(invalid) == 0);
    }

    unittest {
        PatternBlock b = PatternBlock.create(5, 1);
        b.cells[0] = noteAt(60, 100);
        b.cells[1] = NoteCell.makeNoteOff(3);
        b.cells[2] = NoteCell.init;
        b.cells[3] = noteAt(127);
        b.cells[4] = noteAt(0);
        b.cells[2].note = NoteCmd.stopSong;
        size_t skipped = 99;
        assert(transposeBlock(b, 1, skipped) == 2);
        assert(skipped == 1);
        assert(b.cells[0].midiNote() == 61 && b.cells[0].velocity == 100);
        assert(b.cells[1].note == NoteCmd.noteOff && b.cells[1].moduleId == 3);
        assert(b.cells[2].note == NoteCmd.stopSong);
        assert(b.cells[3].midiNote() == 127);
        assert(b.cells[4].midiNote() == 1);

        assert(transposeBlock(b, -2, skipped) == 2);
        assert(skipped == 1);
        assert(b.cells[0].midiNote() == 59);
        assert(b.cells[3].midiNote() == 125);
        assert(b.cells[4].midiNote() == 1);

        assert(transposeBlock(b, 12, skipped) == 2 && skipped == 1);
        assert(b.cells[0].midiNote() == 71 && b.cells[3].midiNote() == 125 && b.cells[4].midiNote() == 13);
        assert(transposeBlock(b, -12) == 3);
        assert(b.cells[0].midiNote() == 59 && b.cells[3].midiNote() == 113 && b.cells[4].midiNote() == 1);
        assert(transposeBlock(b, int.max, skipped) == 0 && skipped == 3);
        assert(transposeBlock(b, int.min, skipped) == 0 && skipped == 3);
        assert(transposeBlock(b, 0, skipped) == 3 && skipped == 0);

        PatternBlock empty = PatternBlock.create(2, 2);
        assert(transposeBlock(empty, 5) == 0);
        foreach (ref c; empty.cells) {
            assert(c.isEmpty());
        }
        PatternBlock invalid;
        assert(transposeBlock(invalid, 1, skipped) == 0 && skipped == 0);
    }

    unittest {
        PatternBlock b = PatternBlock.create(1, 3);
        b.cells[0] = noteAt(120);
        b.cells[1] = noteAt(126);
        b.cells[2] = noteAt(127);
        size_t skipped;
        assert(transposeBlock(b, 1, skipped) == 2 && skipped == 1);
        assert(b.cells[0].midiNote() == 121 && b.cells[1].midiNote() == 127 && b.cells[2].midiNote() == 127);
        assert(b.cells[1].note == 128);
    }

    unittest {
        PatternBlock b = PatternBlock.create(2, 5);
        b.set(0, 0, noteAt(60, 10));
        b.set(0, 2, noteAt(62, 0));
        b.set(0, 4, noteAt(64, 50));
        b.set(1, 1, noteAt(10, 77));
        assert(interpolateColumn(b, 0, InterpolateField.velocity));
        assert(b.at(0, 0).velocity == 10);
        assert(b.at(0, 2).velocity == 30);
        assert(b.at(0, 2).note == 63);
        assert(b.at(0, 4).velocity == 50);
        assert(b.at(0, 1).isEmpty());
        assert(b.at(0, 3).isEmpty());
        assert(b.at(1, 1).velocity == 77);
        assert(!interpolateColumn(b, 1, InterpolateField.velocity));
        assert(b.at(1, 1).velocity == 77);
        assert(!interpolateColumn(b, 2, InterpolateField.velocity));
    }

    unittest {
        PatternBlock b = PatternBlock.create(1, 5);
        NoteCell a;
        a.effect = 0x0A;
        a.effectVal = 0;
        NoteCell z;
        z.effect = 0x0A;
        z.effectVal = 10;
        b.set(0, 0, a);
        b.set(0, 4, z);
        assert(interpolateColumn(b, 0, InterpolateField.effectValue));
        assert(b.at(0, 1).effectVal == 3);
        assert(b.at(0, 2).effectVal == 5);
        assert(b.at(0, 3).effectVal == 8);
        assert(b.at(0, 1).note == 0 && b.at(0, 1).effect == 0 && b.at(0, 1).velocity == 0);
        assert(b.at(0, 0) == a && b.at(0, 4) == z);
    }

    unittest {
        PatternBlock b = PatternBlock.create(1, 5);
        NoteCell a;
        a.effectVal = 10;
        a.effect = 1;
        NoteCell z;
        z.effectVal = 0;
        z.effect = 1;
        b.set(0, 0, a);
        b.set(0, 4, z);
        assert(interpolateColumn(b, 0, InterpolateField.effectValue));
        assert(b.at(0, 1).effectVal == 7);
        assert(b.at(0, 2).effectVal == 5);
        assert(b.at(0, 3).effectVal == 2);
    }

    unittest {
        PatternBlock b = PatternBlock.create(1, 4);
        NoteCell a = NoteCell.makeParam(5, 0, 0.0f);
        NoteCell z = NoteCell.makeParam(5, 299, 0.0f);
        b.set(0, 0, a);
        b.set(0, 3, z);
        assert(a.paramId == 1 && z.paramId == 300);
        assert(interpolateColumn(b, 0, InterpolateField.paramId));
        assert(b.at(0, 1).paramId == 101);
        assert(b.at(0, 2).paramId == 200);
        assert(b.at(0, 1).moduleId == 0);
    }

    unittest {
        PatternBlock b = PatternBlock.create(1, 3);
        b.set(0, 0, noteAt(1, 1));
        b.set(0, 1, noteAt(2, 255));
        b.set(0, 2, noteAt(3, 2));
        assert(interpolateColumn(b, 0, InterpolateField.velocity));
        assert(b.at(0, 1).velocity == 2);

        PatternBlock adj = PatternBlock.create(1, 2);
        adj.set(0, 0, noteAt(1, 1));
        adj.set(0, 1, noteAt(1, 200));
        assert(interpolateColumn(adj, 0, InterpolateField.velocity));
        assert(adj.at(0, 0).velocity == 1 && adj.at(0, 1).velocity == 200);

        PatternBlock one = PatternBlock.create(1, 4);
        one.set(0, 2, noteAt(5, 9));
        assert(!interpolateColumn(one, 0, InterpolateField.velocity));
        PatternBlock none = PatternBlock.create(1, 4);
        assert(!interpolateColumn(none, 0, InterpolateField.paramId));
        PatternBlock invalid;
        assert(!interpolateColumn(invalid, 0, InterpolateField.velocity));
    }

    unittest {
        PatternBlock b = PatternBlock.create(2, 2);
        b.set(0, 0, NoteCell.unpackU64(0x0123_4567_89AB_CDEFuL));
        b.set(1, 1, NoteCell.makeNoteOff());
        immutable string text = encodeBlockText(b);
        assert(text == BLOCK_TEXT_MAGIC ~ " 2 2\n0123456789ABCDEF|................\n"
            ~ "................|00000000000000F0\n");
        PatternBlock d;
        string err;
        assert(decodeBlockText(text, d, err), err);
        assert(err is null);
        assert(d == b);
        PatternBlock invalid;
        assert(encodeBlockText(invalid) == "");
    }

    unittest {
        TestRng rng;
        foreach (iter; 0 .. 300) {
            immutable uint tracks = 1 + rng.below(iter % 10 == 0 ? MAX_BLOCK_TRACKS : 8);
            immutable uint lines = 1 + rng.below(iter % 10 == 0 ? 128 : 16);
            PatternBlock b = randomBlock(rng, tracks, lines);
            immutable string text = encodeBlockText(b);
            PatternBlock d;
            string err;
            assert(decodeBlockText(text, d, err), err);
            assert(d == b);
            assert(decodeBlockText(text[0 .. $ - 1], d, err), err);
            assert(d == b);
            string crlf;
            foreach (ch; text) {
                if (ch == '\n') {
                    crlf ~= "\r\n";
                } else {
                    crlf ~= ch;
                }
            }
            assert(decodeBlockText(crlf, d, err), err);
            assert(d == b);
        }
    }

    unittest {
        PatternBlock big = PatternBlock.create(MAX_BLOCK_TRACKS, MAX_BLOCK_LINES);
        assert(big.isValid());
        big.cells[$ - 1] = NoteCell.makeNote(64);
        PatternBlock d;
        string err;
        assert(decodeBlockText(encodeBlockText(big), d, err), err);
        assert(d == big);
        assert(!PatternBlock.create(MAX_BLOCK_TRACKS + 1, 1).isValid());
        assert(!PatternBlock.create(1, MAX_BLOCK_LINES + 1).isValid());
        assert(!PatternBlock.create(0, 1).isValid());
        assert(!blockDimsAllowed(0, 5));
        assert(blockDimsAllowed(64, 4096));
        assert(!blockDimsAllowed(65, 1));
    }

    unittest {
        PatternBlock good = PatternBlock.create(2, 2);
        good.set(1, 0, NoteCell.makeNote(60));
        immutable string valid = encodeBlockText(good);
        immutable string row0 = "................|000000000000FF3D";
        immutable string row1 = "................|................";
        assert(valid == BLOCK_TEXT_MAGIC ~ " 2 2\n" ~ row0 ~ "\n" ~ row1 ~ "\n");

        string[] bad = [
            "",
            "SynthTracker-Block-v1",
            "SynthTracker-Block-v2 2 2\n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "synthtracker-block-v1 2 2\n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            " SynthTracker-Block-v1 2 2\n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1  2 2\n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2  2\n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 02 2\n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 +2 2\n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2 \n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 0 2\n",
            "SynthTracker-Block-v1 2 0\n",
            "SynthTracker-Block-v1 65 1\n",
            "SynthTracker-Block-v1 1 4097\n",
            "SynthTracker-Block-v1 99999 99999\n",
            "SynthTracker-Block-v1 4294967296 1\n",
            "SynthTracker-Block-v1 1000000 1\n",
            "SynthTracker-Block-v1 64 4096\n",
            "SynthTracker-Block-v1 2 3\n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 1\n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 3 2\n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 1 2\n" ~ row0 ~ "\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2\n" ~ row0 ~ "\n" ~ row1 ~ "\n\n",
            "SynthTracker-Block-v1 2 2\n" ~ row0 ~ "\n" ~ row1 ~ "\r\n\r\n",
            "SynthTracker-Block-v1 2 2\n" ~ row0 ~ "\n" ~ row1 ~ "\nX",
            "SynthTracker-Block-v1 2 2\n" ~ row0 ~ "\n" ~ row1 ~ "X",
            "SynthTracker-Block-v1 2 2\n" ~ row0 ~ "\n" ~ row1 ~ "\r",
            "SynthTracker-Block-v1 2 2\n" ~ row0 ~ "\r" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2\n" ~ row0 ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2\n" ~ row0 ~ "|\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2\n................,000000000000FF3D\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2\n...............0|000000000000FF3D\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2\n................|000000000000FF3G\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2\n................|00000000000FF3D\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2\n................|0000000000000FF3D\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2\n................|00000000000 FF3D\n" ~ row1 ~ "\n",
            "SynthTracker-Block-v1 2 2\n" ~ row0 ~ "\n" ~ row1[0 .. $ - 1],
            "SynthTracker-Block-v1 2 2\n" ~ row0 ~ "\n",
            "SynthTracker-Block-v1 2 2\n",
        ];
        foreach (i, text; bad) {
            PatternBlock d;
            string err;
            assert(!decodeBlockText(text, d, err), text);
            assert(err.length > 0);
            assert(!d.isValid() && d.cells is null);
        }

        PatternBlock d;
        string err;
        assert(decodeBlockText("SynthTracker-Block-v1 2 2\r\n................|000000000000ff3d\n" ~ row1, d, err), err);
        assert(d == good);
        assert(decodeBlockText("SynthTracker-Block-v1 1 1\n0000000000000000", d, err), err);
        assert(d.tracks == 1 && d.lines == 1 && d.cells[0].isEmpty());
    }
}
