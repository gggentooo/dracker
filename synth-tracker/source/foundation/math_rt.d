/**
 * File:         source/foundation/math_rt.d
 * Module:       foundation.math_rt
 * Phase:        Phase 0.4 — Cross-Arch Denormal Suppression & RT Math Utilities
 *
 * Purpose:
 *   Implements RAII CPU FTZ/DAZ subnormal suppression across Apple Silicon (ARM64) and Intel (x86_64), immutable pitch-to-Hz tables, and fast RT math conversions.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; uses LDC2 ldc.llvmasm.__asm (ARM64 fpcr bit 24 FZ / x86_64 MXCSR FTZ+DAZ) with caller state save/restore; zero global --ffast-math.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: ldc.llvmasm (__asm), std.math (exp, fabs, isFinite, isNaN, log10, log2, pow)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ScopedNoDenormals : RAII guard enabling FTZ/DAZ on entry and restoring caller FPCR/MXCSR on exit
 *   - immutable float[8193] PITCH_TO_HZ_TABLE : sub-semitone pitch lookup table
 *   - float midiNoteToHz(float midiNote) @nogc nothrow pure @safe
 *   - float hzToMidiNote(float hz) @nogc nothrow pure @safe
 *   - float dbToLinear(float db) @nogc nothrow pure @safe
 *   - float linearToDb(float amp) @nogc nothrow pure @safe
 *   - float clampSample(float x, float lo, float hi) @nogc nothrow pure @safe
 *   - bool isFiniteSample(float x) @nogc nothrow pure @safe
 *   - float sanitizeSample(float x) @nogc nothrow pure @safe
 *   - float flushSubnormalSoftware(float x) @nogc nothrow pure @safe
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module foundation.math_rt;

import ldc.llvmasm : __asm;
import std.math : exp, fabs, isFinite, isNaN, log10, log2, pow;

enum uint PITCH_TABLE_NOTES = 128;
enum uint PITCH_TABLE_SUBSTEPS = 64;
enum uint PITCH_TABLE_SIZE = PITCH_TABLE_NOTES * PITCH_TABLE_SUBSTEPS + 1;

enum float MIN_DB = -144.0f;
enum float LN10_OVER_20 = 0.1151292546497022842f;
enum float SUBNORMAL_FLUSH_THRESHOLD = float.min_normal;

/**
 * RAII hardware denormal suppression guard for real-time audio and offline render blocks.
 *
 * On AArch64, sets FPCR bit 24 (FZ). On X86_64, sets MXCSR bits 15 (FTZ) and 6 (DAZ).
 * Caller floating-point control register state is saved in enter() and restored on destruction.
 */
struct ScopedNoDenormals {
    private ulong savedState_ = 0;
    private bool active_ = false;

    @disable this(this);

    @nogc nothrow:

    /**
     * Enables hardware flush-to-zero / denormals-are-zero mode on the calling thread.
     *
     * Returns:
     *   Active RAII guard that restores the prior hardware register state when destroyed.
     */
    static ScopedNoDenormals enter() {
        ScopedNoDenormals guard;
        version (AArch64) {
            guard.savedState_ = __asm!ulong("mrs $0, fpcr", "=r,~{memory}");
            immutable ulong nextFpcr = guard.savedState_ | (1UL << 24);
            __asm("msr fpcr, $0", "r,~{memory}", nextFpcr);
            guard.active_ = true;
        } else version (X86_64) {
            uint currentMxcsr = 0;
            __asm("stmxcsr $0", "*m,~{memory}", &currentMxcsr);
            guard.savedState_ = currentMxcsr;
            uint nextMxcsr = currentMxcsr | 0x8040u;
            __asm("ldmxcsr $0", "*m,~{memory}", &nextMxcsr);
            guard.active_ = true;
        }
        return guard;
    }

    /**
     * Restores the saved hardware floating-point control register state if active.
     */
    ~this() {
        if (!active_) {
            return;
        }
        version (AArch64) {
            __asm("msr fpcr, $0", "r,~{memory}", savedState_);
        } else version (X86_64) {
            uint prevMxcsr = cast(uint) savedState_;
            __asm("ldmxcsr $0", "*m,~{memory}", &prevMxcsr);
        }
        active_ = false;
    }

    /**
     * Reports whether this guard instance currently owns an active register override.
     *
     * Returns:
     *   True if enter() succeeded and the destructor has not yet restored state.
     */
    bool isActive() const pure @safe {
        return active_;
    }

    /**
     * Queries the current thread's hardware floating-point control register for FTZ/DAZ bits.
     *
     * Returns:
     *   True when hardware denormal flushing is currently enabled on the calling thread.
     */
    static bool isHardwareNoDenormalsEnabled() {
        version (AArch64) {
            immutable ulong currentFpcr = __asm!ulong("mrs $0, fpcr", "=r,~{memory}");
            return (currentFpcr & (1UL << 24)) != 0;
        } else version (X86_64) {
            uint currentMxcsr = 0;
            __asm("stmxcsr $0", "*m,~{memory}", &currentMxcsr);
            return (currentMxcsr & 0x8040u) == 0x8040u;
        } else {
            return false;
        }
    }
}

private float[PITCH_TABLE_SIZE] generatePitchTable() @nogc nothrow pure @safe {
    float[PITCH_TABLE_SIZE] table = 0.0f;
    foreach (i; 0 .. PITCH_TABLE_SIZE) {
        immutable double midiNote = cast(double) i / cast(double) PITCH_TABLE_SUBSTEPS;
        table[i] = cast(float)(440.0 * pow(2.0, (midiNote - 69.0) / 12.0));
    }
    return table;
}

static immutable float[PITCH_TABLE_SIZE] PITCH_TO_HZ_TABLE = generatePitchTable();

/**
 * Converts a fractional MIDI note number to frequency in Hertz via interpolated table lookup.
 *
 * Values outside [0.0, 128.0] are clamped to table bounds; NaN inputs return 440.0f.
 *
 * Params:
 *   midiNote = Fractional MIDI note number where 69.0f corresponds to A4 (440.0 Hz).
 *
 * Returns:
 *   Frequency in Hertz, safe to invoke from @nogc nothrow pure @safe contexts.
 */
float midiNoteToHz(float midiNote) @nogc nothrow pure @safe {
    if (isNaN(midiNote)) {
        return 440.0f;
    }
    immutable float clamped = clampSample(midiNote, 0.0f, cast(float) PITCH_TABLE_NOTES);
    immutable float scaled = clamped * cast(float) PITCH_TABLE_SUBSTEPS;
    immutable size_t idx = cast(size_t) scaled;
    if (idx >= PITCH_TABLE_SIZE - 1) {
        return PITCH_TO_HZ_TABLE[PITCH_TABLE_SIZE - 1];
    }
    immutable float frac = scaled - cast(float) idx;
    immutable float lo = PITCH_TO_HZ_TABLE[idx];
    immutable float hi = PITCH_TO_HZ_TABLE[idx + 1];
    return lo + frac * (hi - lo);
}

/**
 * Converts a positive frequency in Hertz to a fractional MIDI note number.
 *
 * Params:
 *   hz = Frequency in Hertz; non-finite or non-positive values return 0.0f.
 *
 * Returns:
 *   Fractional MIDI note number where 440.0 Hz maps to 69.0f.
 */
float hzToMidiNote(float hz) @nogc nothrow pure @safe {
    if (!isFinite(hz) || hz <= 0.0f) {
        return 0.0f;
    }
    return 69.0f + 12.0f * cast(float) log2(cast(double) hz / 440.0);
}

/**
 * Converts a decibel gain value to a linear amplitude multiplier.
 *
 * Values at or below MIN_DB (-144.0 dB) or non-finite inputs return 0.0f.
 *
 * Params:
 *   db = Gain in decibels.
 *
 * Returns:
 *   Linear amplitude multiplier >= 0.0f.
 */
float dbToLinear(float db) @nogc nothrow pure @safe {
    if (isNaN(db) || db <= MIN_DB) {
        return 0.0f;
    }
    if (!isFinite(db)) {
        return db > 0.0f ? float.max : 0.0f;
    }
    return cast(float) exp(cast(double) db * cast(double) LN10_OVER_20);
}

/**
 * Converts a linear amplitude value to decibels, floored at MIN_DB (-144.0 dB).
 *
 * Params:
 *   amp = Linear amplitude (sign is ignored via absolute magnitude).
 *
 * Returns:
 *   Gain in decibels >= MIN_DB.
 */
float linearToDb(float amp) @nogc nothrow pure @safe {
    immutable float absAmp = fabs(amp);
    if (!isFinite(absAmp) || absAmp <= 0.0f) {
        return MIN_DB;
    }
    immutable float db = 20.0f * cast(float) log10(cast(double) absAmp);
    return db < MIN_DB ? MIN_DB : db;
}

/**
 * Clamps a scalar sample to [lo, hi], returning lo if the input is NaN.
 *
 * Params:
 *   x = Input sample value.
 *   lo = Minimum allowed value.
 *   hi = Maximum allowed value.
 *
 * Returns:
 *   Clamped finite value within [lo, hi] when lo and hi are finite.
 */
float clampSample(float x, float lo, float hi) @nogc nothrow pure @safe {
    if (isNaN(x) || x < lo) {
        return lo;
    }
    if (x > hi) {
        return hi;
    }
    return x;
}

/**
 * Checks whether a sample is finite (neither NaN nor +/-infinity).
 *
 * Params:
 *   x = Sample value to test.
 *
 * Returns:
 *   True if x is finite.
 */
bool isFiniteSample(float x) @nogc nothrow pure @safe {
    return isFinite(x);
}

/**
 * Replaces non-finite sample values (NaN or infinity) with 0.0f.
 *
 * Params:
 *   x = Sample value to sanitize.
 *
 * Returns:
 *   Original value if finite, otherwise 0.0f.
 */
float sanitizeSample(float x) @nogc nothrow pure @safe {
    return isFinite(x) ? x : 0.0f;
}

/**
 * Flushes IEEE-754 subnormal magnitudes to 0.0f in software without altering hardware FPCR/MXCSR.
 *
 * Params:
 *   x = Input sample value.
 *
 * Returns:
 *   0.0f if x is non-finite or |x| < float.min_normal, otherwise x unchanged.
 */
float flushSubnormalSoftware(float x) @nogc nothrow pure @safe {
    if (!isFinite(x)) {
        return 0.0f;
    }
    return fabs(x) < SUBNORMAL_FLUSH_THRESHOLD ? 0.0f : x;
}
