/**
 * File:         tests/fuzz/compose_script_fuzz.d
 * Module:       tests.fuzz.compose_script_fuzz
 * Phase:        Composition helper (dracker-compose) — T83 (Script lexer & interpreter fuzz test)
 *
 * Purpose:
 *   Seeded fuzzing (SplitMix64) of compose.script.lexer.lexScript() and compose.script.commands
 *   createDefaultInterpreter(checkOnly=true).runScript() across 20,000 random fragment combinations and
 *   byte-level mutations of valid scripts. Verifies that no input crashes or throws, every token and
 *   diagnostic carries valid 1-based coordinates and non-empty error reasons, and valid scripts succeed
 *   cleanly without writing to disk.
 *
 * Real-Time & Safety Contract:
 *   Off-RT deterministic verification harness (SplitMix64); checkOnly mode performs zero disk writes.
 *
 * Dependencies:
 *   Internal: compose.script.commands (createDefaultInterpreter), compose.script.interpreter (RunResult,
 *             ScriptInterpreter), compose.script.lexer (LexResult, lexScript)
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ScriptFuzzStats; ScriptFuzzStats runComposeScriptFuzz(ulong seed, size_t iterations)
 *
 * See_Also:
 *   docs/todo.md (T67, T83), tests/fuzz/chord_progression_fuzz.d
 */
module tests.fuzz.compose_script_fuzz;

import compose.script.commands : createDefaultInterpreter;
import compose.script.interpreter : RunResult, ScriptInterpreter;
import compose.script.lexer : LexResult, lexScript;

/**
 * Counters collected during one fuzz run.
 */
struct ScriptFuzzStats {
    size_t runs = 0;
    size_t lexOk = 0;
    size_t lexErr = 0;
    size_t runOk = 0;
    size_t runErr = 0;
}

private struct SplitMix64 {
    ulong state;

    /**
     * Returns the next 64-bit pseudo-random value.
     *
     * Returns:
     *   Pseudo-random ulong.
     */
    ulong next() @safe pure nothrow @nogc {
        ulong z = (state += 0x9E37_79B9_7F4A_7C15uL);
        z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9uL;
        z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EBuL;
        return z ^ (z >> 31);
    }

    /**
     * Returns a pseudo-random index in [0, bound).
     *
     * Params:
     *   bound = Exclusive upper bound (> 0).
     *
     * Returns:
     *   Index below bound.
     */
    size_t below(size_t bound) @safe pure nothrow @nogc {
        return cast(size_t)(next() % bound);
    }
}

private immutable string COMMENT = "/" ~ "/";

private immutable string[] FRAGMENTS = [
    "project", "open", "tempo", "signature", "key", "save", "module", "set", "preset", "sample",
    "savemodule", "connect", "disconnect", "remove", "section", "part", "notes", "chords", "drums",
    "cells", "copy", "repeat", "transpose", "clear", "arrange", "loop", "temop", "unknown",
    "bass", "keys", "out", "comp", "verse", "chorus", "all", "synth.analog_gen", "fx.compressor",
    "Cutoff=900", "gain=0.5", "bars=4", "bars=0", "module=bass", "drums=kit", "at=1.2", "start=0",
    "end=16", "len=16", "lane=0", "clip=verse", "to=Sidechain", "preset=\"Electric Piano\"",
    "slot=0", "root=C4", "x=60", "y=60", "style=arp", "dir=updown", "every=1/2", "octave=3",
    "voices=4", "voicing=close", "rhythm=X.x.", "tracks=4", "lines=64", "track=0", "line=0",
    "note=off", "vel=0.8", "velbyte=200", "param=1", "fx=03", "fxval=20", "by=12", "steps=2",
    "keep=\"a.msv:1\"", "name=\"My Bass\"", "kick", "snare", "hat", "note=36",
    ":", "C4", "Am7", "Fmaj7", "x..x..x.", "[C4 E4 G4]:2@0.8", "C4:1/2", "-:1", "H4", "C4:1/3",
    "\"Night Drive\"", "\"\"", "\"unterminated", "\"esc\\\"quote\"", "\"bad\\q\"",
    "120", "96.5", "0", "-5", "9999", "NaN", "tpl=6", "tpl=0", "tpl=999", "tpl=", "=bad", "opt=\"val\"",
    "4/4", "6/8", "3/4", "7/9", "A", "C#", "Bb", "H", "major", "minor", "minro",
    " ", "\t", "\n", "\r\n", "\\\n", "\\", "/", COMMENT, "=", "\"", "\x00", "\xC2", "\xFF"
];

private immutable string[] SEEDS = [
    "project \"Night Drive\"\ntempo 96 tpl=4\nsignature 6/8\nkey A minor\n",
    "project \"Demo\" " ~ COMMENT ~ " title\ntempo 125 \\\n  tpl=6\nkey F# major\n",
    "signature 3/4\nkey D minor\ntempo 140\n",
    "module bass synth.analog_gen\nset bass Cutoff=1200\nconnect bass out gain=0.4\nsave \"x.msv\"\n",
    "module lead synth.fm_synth\nconnect lead out gain=0.5\nsection a bars=1\nsection b bars=1\npart lead module=lead\nnotes lead a: C4:1 E4 G4 B4\nnotes lead b at=1.2: [D4 F4 A4]:2\narrange a b a\nloop a b\n",
    "module keys synth.fm_synth\nmodule drum synth.drum_synth\nconnect keys out\nconnect drum out\nsection v bars=2\npart keys module=keys\npart beat drums=drum\nchords keys v style=arp dir=up rhythm=X.x.: Am7 Fmaj7\ndrums beat v kick: x...x...\ncells keys v track=0 line=4 fx=03 fxval=10\ncopy keys v beat b\ntranspose keys v by=2\n",
    "project \"Escape \\\"Test\\\"\"\nkey C\n"
];

/**
 * Checks lexer and interpreter invariants on one arbitrary input string.
 *
 * Params:
 *   text = Arbitrary script text.
 *   stats = Fuzz statistics updated in place.
 */
private void checkInput(string text, ref ScriptFuzzStats stats) @safe {
    stats.runs++;
    immutable LexResult lex = lexScript(text);
    if (lex.ok) {
        stats.lexOk++;
    } else {
        stats.lexErr++;
        foreach (ref e; lex.errors) {
            assert(e.line >= 1 && e.column >= 1 && e.length >= 1);
            assert(e.reason.length > 0);
        }
    }
    foreach (ref cmd; lex.commands) {
        assert(cmd.line >= 1 && cmd.tokens.length > 0);
        foreach (ref tok; cmd.tokens) {
            assert(tok.line >= 1 && tok.column >= 1 && tok.length >= 1);
        }
    }

    ScriptInterpreter interp = createDefaultInterpreter(true);
    RunResult res = interp.runScript(text);
    if (res.ok) {
        stats.runOk++;
        assert(res.problems.length == 0);
    } else {
        stats.runErr++;
        assert(res.problems.length > 0);
        foreach (ref p; res.problems) {
            assert(p.line >= 1 && p.column >= 1 && p.length >= 1);
            assert(p.reason.length > 0);
            assert(p.text().length > 0);
        }
    }
}

/**
 * Runs the deterministic fuzz harness over fragment combinations and mutated valid scripts.
 *
 * Params:
 *   seed = SplitMix64 seed.
 *   iterations = Total number of inputs to test.
 *
 * Returns:
 *   Aggregated ScriptFuzzStats.
 */
ScriptFuzzStats runComposeScriptFuzz(ulong seed, size_t iterations) @safe {
    SplitMix64 rng = SplitMix64(seed);
    ScriptFuzzStats stats;
    foreach (it; 0 .. iterations) {
        string text;
        if (it % 4 == 0) {
            text = SEEDS[rng.below(SEEDS.length)];
        } else if (it % 2 == 0) {
            immutable size_t n = rng.below(14);
            foreach (_; 0 .. n) {
                text ~= FRAGMENTS[rng.below(FRAGMENTS.length)];
                if (rng.below(3) == 0) {
                    text ~= " ";
                }
            }
        } else {
            char[] buf = SEEDS[rng.below(SEEDS.length)].dup;
            immutable size_t edits = 1 + rng.below(4);
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
        checkInput(text, stats);
    }
    return stats;
}

version (unittest) {
    unittest {
        immutable ScriptFuzzStats s = runComposeScriptFuzz(0x5363_7269_7074uL, 20_000);
        assert(s.runs == 20_000);
        assert(s.lexOk > 1_000 && s.lexErr > 1_000);
        assert(s.runOk > 1_000 && s.runErr > 1_000);
    }
}
