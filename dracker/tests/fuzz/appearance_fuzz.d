/**
 * File:         tests/fuzz/appearance_fuzz.d
 * Module:       tests.fuzz.appearance_fuzz
 * Phase:        Phase 8.5.6 — Appearance Settings & Palette Codec Fuzzing
 *
 * Purpose:
 *   Deterministic mutation fuzzing of decodeAppearance() and decodePalette() over valid seeds (default settings,
 *   settings with custom palettes, every built-in palette as .stpalette): byte flips, insertions of interesting
 *   bytes and keys, line deletion/duplication/reordering, truncation and splicing. Every input must be handled
 *   without throwing; rejected inputs leave defaults and a diagnostic; accepted inputs must re-encode to text
 *   that decodes to the same value and re-encodes identically.
 *
 * Real-Time & Safety Contract:
 *   Headless; deterministic SplitMix64 stream; no file system access.
 *
 * Dependencies:
 *   Internal: gui.appearance, gui.theme
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct AppearanceFuzzStats / AppearanceFuzzStats runAppearanceFuzz(ulong seed, size_t runs)
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.5)
 */
module tests.fuzz.appearance_fuzz;

import gui.appearance;
import gui.theme : ContrastMode;

/**
 * Aggregated fuzz counters.
 */
struct AppearanceFuzzStats {
    size_t totalRuns = 0;
    size_t settingsAccepted = 0;
    size_t settingsRejected = 0;
    size_t paletteAccepted = 0;
    size_t paletteRejected = 0;
    size_t mutatedAccepted = 0;
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

private immutable string[] INSERTS = ["\n", "\r", "=", "[palette]\n", "[end]\n", "\0", "\xFF", "\xE2\x80",
    "dracker-appearance 1\n", "dracker-palette 1\n", "contrast=low\n", "palette=Custom 1\n",
    "ui_font=X\n", "accent=00000000\n", "light=0\n", "name=Custom 7\n", "origin=Dark · Okabe–Ito\n", " ",
    "Light · Okabe–Ito", "0123456789ABCDEF", "\x01", "\t"];

private string[] splitLines(string s) {
    string[] lines;
    size_t start = 0;
    foreach (i, ch; s) {
        if (ch == '\n') {
            lines ~= s[start .. i + 1];
            start = i + 1;
        }
    }
    if (start < s.length) {
        lines ~= s[start .. $];
    }
    return lines;
}

private string mutate(ref SplitMix64 rng, string src, string other) {
    char[] buf = src.dup;
    immutable uint ops = 1 + rng.nextU32(4);
    foreach (_; 0 .. ops) {
        switch (rng.nextU32(8)) {
        case 0:
            if (buf.length > 0) {
                buf[rng.nextU32(cast(uint) buf.length)] ^= cast(char)(1 << rng.nextU32(8));
            }
            break;
        case 1: {
            immutable string ins = INSERTS[rng.nextU32(cast(uint) INSERTS.length)];
            immutable size_t at = rng.nextU32(cast(uint) buf.length + 1);
            buf = buf[0 .. at] ~ ins ~ buf[at .. $];
            break;
        }
        case 2:
            if (buf.length > 0) {
                buf = buf[0 .. rng.nextU32(cast(uint) buf.length)];
            }
            break;
        case 3: {
            string[] lines = splitLines(buf.idup);
            if (lines.length > 1) {
                immutable size_t k = rng.nextU32(cast(uint) lines.length);
                lines = lines[0 .. k] ~ lines[k + 1 .. $];
                buf = null;
                foreach (l; lines) buf ~= l;
            }
            break;
        }
        case 4: {
            string[] lines = splitLines(buf.idup);
            if (lines.length > 0) {
                immutable size_t k = rng.nextU32(cast(uint) lines.length);
                lines = lines[0 .. k + 1] ~ lines[k .. $];
                buf = null;
                foreach (l; lines) buf ~= l;
            }
            break;
        }
        case 5: {
            string[] lines = splitLines(buf.idup);
            if (lines.length > 2) {
                immutable size_t a = 1 + rng.nextU32(cast(uint) lines.length - 1);
                immutable size_t b = 1 + rng.nextU32(cast(uint) lines.length - 1);
                auto t = lines[a];
                lines[a] = lines[b];
                lines[b] = t;
                buf = null;
                foreach (l; lines) buf ~= l;
            }
            break;
        }
        case 6:
            if (other.length > 0) {
                immutable size_t cut = rng.nextU32(cast(uint) buf.length + 1);
                immutable size_t from = rng.nextU32(cast(uint) other.length);
                buf = buf[0 .. cut] ~ other[from .. $];
            }
            break;
        default:
            if (buf.length > 1) {
                immutable size_t a = rng.nextU32(cast(uint) buf.length);
                buf[a] = cast(char)('0' + rng.nextU32(75));
            }
            break;
        }
    }
    return buf.idup;
}

private void checkSettings(string text, ref AppearanceFuzzStats st, bool mutated) {
    AppearanceSettings s;
    string err;
    immutable bool ok = decodeAppearance(text, s, err);
    if (!ok) {
        st.settingsRejected++;
        assert(s == AppearanceSettings.init && err.length > 0);
        return;
    }
    st.settingsAccepted++;
    if (mutated) st.mutatedAccepted++;
    immutable string again = encodeAppearance(s);
    AppearanceSettings s2;
    string err2;
    assert(decodeAppearance(again, s2, err2), err2);
    assert(s2 == s && encodeAppearance(s2) == again);
    cast(void) themeFor(s2);
}

private void checkPalette(string text, ref AppearanceFuzzStats st, bool mutated) {
    PaletteSpec p;
    string err;
    if (!decodePalette(text, p, err)) {
        st.paletteRejected++;
        assert(err.length > 0);
        return;
    }
    st.paletteAccepted++;
    if (mutated) st.mutatedAccepted++;
    immutable string again = encodePalette(p);
    PaletteSpec p2;
    string err2;
    assert(decodePalette(again, p2, err2), err2);
    assert(p2 == p && encodePalette(p2) == again);
    cast(void) makeTheme(p2, ContrastMode.low);
}

/**
 * Runs a fuzz campaign over the settings and palette codecs.
 *
 * Params:
 *   seed = RNG seed.
 *   runs = Mutated inputs per codec.
 *
 * Returns:
 *   Campaign counters; asserts the invariants for every input.
 */
AppearanceFuzzStats runAppearanceFuzz(ulong seed, size_t runs) {
    SplitMix64 rng = SplitMix64(seed);
    AppearanceFuzzStats st;
    AppearanceSettings rich;
    rich.contrast = ContrastMode.low;
    duplicateAsCustom(rich, "Dark · Okabe–Ito");
    duplicateAsCustom(rich, "Light · Tol Bright");
    AppearanceSettings plain;
    string[] settingsSeeds = [encodeAppearance(plain), encodeAppearance(rich)];
    string[] paletteSeeds;
    foreach (p; builtinPalettes()) {
        paletteSeeds ~= encodePalette(p);
    }
    foreach (seedText; settingsSeeds) {
        checkSettings(seedText, st, false);
    }
    foreach (seedText; paletteSeeds) {
        checkPalette(seedText, st, false);
    }
    foreach (i; 0 .. runs) {
        immutable string a = settingsSeeds[rng.nextU32(cast(uint) settingsSeeds.length)];
        immutable string b = paletteSeeds[rng.nextU32(cast(uint) paletteSeeds.length)];
        checkSettings(mutate(rng, a, settingsSeeds[rng.nextU32(cast(uint) settingsSeeds.length)]), st, true);
        checkPalette(mutate(rng, b, a), st, true);
        st.totalRuns += 2;
    }
    return st;
}

version (unittest) {
    unittest {
        immutable AppearanceFuzzStats st = runAppearanceFuzz(0x85_A11CE, 6000);
        assert(st.totalRuns == 12_000);
        assert(st.settingsAccepted >= 2 && st.paletteAccepted >= 3);
        assert(st.settingsRejected > 1000 && st.paletteRejected > 1000);
        assert(st.settingsAccepted + st.settingsRejected == 6002 && st.paletteAccepted + st.paletteRejected == 6003);
    }
}
