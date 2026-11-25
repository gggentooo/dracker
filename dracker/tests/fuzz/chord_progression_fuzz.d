/**
 * File:         tests/fuzz/chord_progression_fuzz.d
 * Module:       tests.fuzz.chord_progression_fuzz
 * Phase:        Skeleton project generator — T14 (chord model and parser)
 *
 * Purpose:
 *   Seeded fuzzing of app.chord_progression.parseProgression() with 60,000 inputs: random sequences of chord
 *   fragments, separators, Unicode symbols, cut multi-byte sequences and raw bytes, plus byte mutations of valid
 *   progressions. Checks that the parser never crashes, that an error always points inside the text with a reason,
 *   and that every accepted chord resolves to 3 or 4 pitch classes below 12 and has a label in several keys.
 *
 * Real-Time & Safety Contract:
 *   Off-RT verification harness; deterministic (SplitMix64).
 *
 * Dependencies:
 *   Internal: app.chord_progression, app.music_theory
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ChordFuzzStats; ChordFuzzStats runChordProgressionFuzz(ulong seed, size_t iterations)
 *
 * See_Also:
 *   docs/todo.md (T14), tests/fuzz/block_text_fuzz.d
 */
module tests.fuzz.chord_progression_fuzz;

import app.chord_progression : chordLabel, ChordBlock, parseProgression, ProgressionError, resolveChord;
import app.music_theory : KeyMode, MusicalKey;

/**
 * Counters of one fuzz run.
 */
struct ChordFuzzStats {
    size_t runs = 0;
    size_t accepted = 0;
    size_t rejected = 0;
    size_t chordsChecked = 0;
}

private struct SplitMix64 {
    ulong state;

    /**
     * Returns the next 64-bit value.
     *
     * Returns:
     *   Pseudo-random value.
     */
    ulong next() @safe pure nothrow @nogc {
        ulong z = (state += 0x9E37_79B9_7F4A_7C15uL);
        z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9uL;
        z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EBuL;
        return z ^ (z >> 31);
    }

    /**
     * Returns a value below bound.
     *
     * Params:
     *   bound = Exclusive upper bound (> 0).
     *
     * Returns:
     *   Value in [0, bound).
     */
    size_t below(size_t bound) @safe pure nothrow @nogc {
        return cast(size_t)(next() % bound);
    }
}

private immutable string[] FRAGMENTS = ["I", "V", "i", "v", "II", "iv", "vii", "b", "#", "♭", "♯", "°", "ø", "+",
    "A", "B", "C", "D", "E", "F", "G", "H", "a", "m", "maj7", "7", "9", "dim", "dim7", "aug", "sus2", "sus4", "m7b5",
    "/", " ", ",", "-", "->", ">", "\t", "\n", "x", "", "\xC2", "\xE2\x99", "\xFF"];

private immutable string[] SEEDS = ["iii -> vi -> ii -> V -> I", "Dm7, G7, Cmaj7", "C/E Am F G7", "bVII IV I",
    "vii° Bø7 #iv°", "I V vi IV"];

private void check(string text, ref ChordFuzzStats stats) @safe {
    static immutable MusicalKey[3] keys = [MusicalKey(0, KeyMode.major), MusicalKey(9, KeyMode.minor),
        MusicalKey(6, KeyMode.major)];
    ChordBlock[] blocks;
    ProgressionError err;
    stats.runs++;
    if (parseProgression(text, blocks, err)) {
        stats.accepted++;
        foreach (ref b; blocks) {
            foreach (k; keys) {
                auto r = resolveChord(b.chord, k);
                assert(r.pitchClasses.length == 3 || r.pitchClasses.length == 4);
                assert(r.rootPc < 12 && r.bassPc < 12);
                foreach (pc; r.pitchClasses) {
                    assert(pc < 12);
                }
                assert(chordLabel(b.chord, k).length > 0);
            }
            stats.chordsChecked++;
        }
    } else {
        stats.rejected++;
        assert(blocks.length == 0);
        assert(err.message.length > 0 && err.length > 0 && err.position + err.length <= text.length);
    }
}

/**
 * Runs the fuzz loop: even iterations build text from random fragments, odd ones mutate a valid seed.
 *
 * Params:
 *   seed = SplitMix64 seed.
 *   iterations = Number of inputs.
 *
 * Returns:
 *   Counters.
 */
ChordFuzzStats runChordProgressionFuzz(ulong seed, size_t iterations) @safe {
    SplitMix64 rng = SplitMix64(seed);
    ChordFuzzStats stats;
    foreach (it; 0 .. iterations) {
        string text;
        if (it % 2 == 0) {
            immutable size_t n = rng.below(12);
            foreach (_; 0 .. n) {
                text ~= FRAGMENTS[rng.below(FRAGMENTS.length)];
            }
        } else {
            char[] buf = SEEDS[rng.below(SEEDS.length)].dup;
            immutable size_t edits = 1 + rng.below(3);
            foreach (_; 0 .. edits) {
                if (buf.length == 0) {
                    break;
                }
                immutable size_t at = rng.below(buf.length);
                final switch (rng.below(3)) {
                    case 0:
                        buf[at] = cast(char) rng.below(256);
                        break;
                    case 1:
                        buf = buf[0 .. at] ~ buf[at + 1 .. $];
                        break;
                    case 2:
                        buf = buf[0 .. at] ~ FRAGMENTS[rng.below(FRAGMENTS.length)].dup ~ buf[at .. $];
                        break;
                }
            }
            text = buf.idup;
        }
        check(text, stats);
    }
    return stats;
}

version (unittest) {
    unittest {
        immutable ChordFuzzStats s = runChordProgressionFuzz(0x4368_6F72_6473uL, 60_000);
        assert(s.runs == 60_000);
        assert(s.accepted > 1_000 && s.rejected > 1_000 && s.chordsChecked > 5_000);
    }
}
