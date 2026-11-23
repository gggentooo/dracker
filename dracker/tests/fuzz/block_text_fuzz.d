/**
 * File:         tests/fuzz/block_text_fuzz.d
 * Module:       tests.fuzz.block_text_fuzz
 * Phase:        Phase 7.5.7 — Dracker-Block-v1 Clipboard Decoder Fuzz Harness
 *
 * Purpose:
 *   Drives decodeBlockText with 20,000+ seeded mutated, truncated, spliced, line-ending-swapped, and
 *   header-corrupted inputs derived from valid encodings, asserting the decoder never crashes and that every
 *   accepted input yields a valid block whose re-encoding decodes back to an identical block.
 *
 * Real-Time & Safety Contract:
 *   Off-RT verification harness; the decoder under test is @safe nothrow pure, so any throw is a compile error
 *   and any out-of-bounds access aborts the run under bounds-checked builds.
 *
 * Dependencies:
 *   Internal: app.pattern_ops, sequencer.note
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct BlockFuzzStats
 *   - BlockFuzzStats runBlockTextFuzz(ulong seed, size_t iterations = 20_000)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.fuzz.block_text_fuzz;

import app.pattern_ops : decodeBlockText, encodeBlockText, PatternBlock;
import sequencer.note : NoteCell, NoteCmd;

/**
 * Aggregated decoder fuzz counters.
 */
struct BlockFuzzStats {
    size_t totalRuns = 0;
    size_t acceptedCount = 0;
    size_t rejectedCount = 0;
    size_t mutatedAccepted = 0;
    size_t roundTripOk = 0;
}

private struct SplitMix64 {
    ulong state = 0x9E37_79B9_7F4A_7C15uL;

    @nogc nothrow pure @safe:

    ulong nextU64() {
        state += 0x9E37_79B9_7F4A_7C15uL;
        ulong z = state;
        z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9uL;
        z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EBuL;
        return z ^ (z >> 31);
    }

    uint nextU32(uint bound) {
        if (bound <= 1) return 0;
        return cast(uint)(nextU64() % bound);
    }
}

private immutable char[] INTERESTING = "0123456789ABCDEFabcdefG.|\n\r -+xX\0\xFF";

private PatternBlock seedBlock(ref SplitMix64 rng) @safe nothrow {
    immutable uint tracks = 1 + rng.nextU32(6);
    immutable uint lines = 1 + rng.nextU32(8);
    PatternBlock b = PatternBlock.create(tracks, lines);
    foreach (ref c; b.cells) {
        immutable uint kind = rng.nextU32(5);
        if (kind == 0) {
            c = NoteCell.makeNote(cast(int) rng.nextU32(128), 0.7f);
        } else if (kind == 1) {
            c = NoteCell.makeNoteOff();
        } else if (kind == 2) {
            c = NoteCell.unpackU64(rng.nextU64());
        }
    }
    return b;
}

private char[] mutate(ref SplitMix64 rng, const(char)[] src, const(char)[] other) @safe nothrow {
    char[] t = src.dup;
    immutable uint rounds = 1 + rng.nextU32(3);
    foreach (_; 0 .. rounds) {
        immutable uint op = rng.nextU32(9);
        immutable size_t len = t.length;
        immutable size_t at = len == 0 ? 0 : rng.nextU32(cast(uint) len);
        if (op == 0 && len > 0) {
            t[at] = INTERESTING[rng.nextU32(cast(uint) INTERESTING.length)];
        } else if (op == 1 && len > 0) {
            t[at] = cast(char) rng.nextU32(256);
        } else if (op == 2) {
            t = t[0 .. at];
        } else if (op == 3) {
            t = t[0 .. at] ~ INTERESTING[rng.nextU32(cast(uint) INTERESTING.length)] ~ t[at .. $];
        } else if (op == 4 && len > 0) {
            t = t[0 .. at] ~ t[at + 1 .. $];
        } else if (op == 5) {
            immutable size_t cut = other.length == 0 ? 0 : rng.nextU32(cast(uint) other.length);
            t = t[0 .. at] ~ other[cut .. $];
        } else if (op == 6) {
            char[] crlf;
            foreach (ch; t) {
                if (ch == '\n') {
                    crlf ~= "\r\n";
                } else {
                    crlf ~= ch;
                }
            }
            t = crlf;
        } else if (op == 7) {
            immutable string[] headers = ["Dracker-Block-v1 0 1\n", "Dracker-Block-v1 65 1\n",
                "Dracker-Block-v1 1 4097\n", "Dracker-Block-v1 64 4096\n", "Dracker-Block-v1 1 1\n",
                "Dracker-Block-v1 99999 9\n", "Dracker-Block-v2 1 1\n", "Dracker-Block-v1 1 2\r\n"];
            size_t nl = 0;
            while (nl < t.length && t[nl] != '\n') {
                nl++;
            }
            immutable size_t rest = nl < t.length ? nl + 1 : t.length;
            t = headers[rng.nextU32(cast(uint) headers.length)].dup ~ t[rest .. $];
        } else if (op == 8) {
            t ~= INTERESTING[rng.nextU32(cast(uint) INTERESTING.length)];
        }
    }
    return t;
}

/**
 * Runs a deterministic decoder fuzz campaign.
 *
 * Params:
 *   seed = SplitMix64 seed.
 *   iterations = Number of decoded inputs (half pristine/truncated, half multi-op mutations).
 *
 * Returns:
 *   Campaign counters; asserts round-trip identity for every accepted input.
 */
BlockFuzzStats runBlockTextFuzz(ulong seed, size_t iterations = 20_000) @safe nothrow {
    BlockFuzzStats stats;
    SplitMix64 rng;
    rng.state = seed;
    PatternBlock first = seedBlock(rng);
    string previous = encodeBlockText(first);
    foreach (iter; 0 .. iterations) {
        PatternBlock original = seedBlock(rng);
        immutable string valid = encodeBlockText(original);
        const(char)[] input;
        bool mutated = true;
        immutable uint mode = rng.nextU32(4);
        if (mode == 0) {
            input = valid;
            mutated = false;
        } else if (mode == 1) {
            input = valid[0 .. rng.nextU32(cast(uint) valid.length + 1)];
            mutated = input.length + 1 < valid.length;
        } else {
            input = mutate(rng, valid, previous);
        }
        previous = valid;
        PatternBlock decoded;
        string err;
        stats.totalRuns++;
        if (!decodeBlockText(input, decoded, err)) {
            assert(err.length > 0);
            assert(decoded.cells is null && !decoded.isValid());
            stats.rejectedCount++;
            continue;
        }
        stats.acceptedCount++;
        if (mutated && input != valid) {
            stats.mutatedAccepted++;
        }
        assert(decoded.isValid());
        if (!mutated) {
            assert(decoded == original);
        }
        immutable string again = encodeBlockText(decoded);
        PatternBlock redecoded;
        string err2;
        assert(decodeBlockText(again, redecoded, err2));
        assert(redecoded == decoded);
        assert(encodeBlockText(redecoded) == again);
        stats.roundTripOk++;
    }
    return stats;
}

version (unittest) {
    unittest {
        immutable BlockFuzzStats stats = runBlockTextFuzz(0x426C_6F63_6B76_31uL, 20_000);
        assert(stats.totalRuns == 20_000);
        assert(stats.acceptedCount + stats.rejectedCount == stats.totalRuns);
        assert(stats.acceptedCount >= 5_000);
        assert(stats.rejectedCount >= 5_000);
        assert(stats.mutatedAccepted > 0);
        assert(stats.roundTripOk == stats.acceptedCount);
    }
}
