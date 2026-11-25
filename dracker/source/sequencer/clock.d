/**
 * File:         source/sequencer/clock.d
 * Module:       sequencer.clock
 * Phase:        Phase 5.3 — Drift-Free 64-Bit Rational Sample/Tick/Line Clock
 *
 * Purpose:
 *   Advances song time across arbitrary sample rates, dynamic BPM, and dynamic TPL (ticks per line) without floating-point accumulation drift, producing exact sub-slice tick offsets.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; 64-bit integer/rational accumulator with zero allocations.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: core.stdc.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct TickEvent { uint frameOffset; long line; uint tick; bool isLineStart; }
 *   - struct RationalClock : configure(), setBpm(), setTicksPerLine(), setLoop(), seekToLine(), seekToLineSigned() (negative count-in lines),
 *     advanceSlice(), subLineDelaySamples()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.clock;

import std.math : isFinite;
import std.traits : hasIndirections;

/**
 * Discrete sequencer tick timestamp emitted inside an execution audio slice.
 */
struct TickEvent {
    uint frameOffset = 0;
    long line = 0;
    uint tick = 0;
    bool isLineStart = false;
}

static assert(!hasIndirections!TickEvent);

/**
 * Drift-free 64-bit exact rational tracker clock tracking ticks = BPM * 2 / 5 per second.
 *
 * Keeps denominator = 2500 * sampleRateHz constant across dynamic BPM edits while numerator =
 * round(BPM * 1000), ensuring sub-sample phase continuity and zero long-run drift.
 */
struct RationalClock {
    private ulong sampleRateHz_ = 44_100;
    private ulong num_ = 125_000;
    private ulong den_ = 2500uL * 44_100uL;
    private ulong phaseNum_ = 0;

    private double bpm_ = 125.0;
    private uint tpl_ = 6;
    private long line_ = 0;
    private uint tick_ = 0;
    private bool emitInitialTick_ = true;

    private long loopStart_ = 0;
    private long loopEnd_ = 0;

    @nogc nothrow:

    /**
     * Initializes clock sample rate, tempo, speed, and loop counters cleanly.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   bpm = Tempo in beats per minute (clamped [20.0 .. 999.0]).
     *   ticksPerLine = Tracker speed in ticks per line (clamped [1 .. 255]).
     */
    void configure(float sampleRate, double bpm = 125.0, uint ticksPerLine = 6) {
        immutable uint sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100u : cast(uint)(sampleRate + 0.5f);
        sampleRateHz_ = sr < 1 ? 44_100uL : cast(ulong) sr;
        den_ = 2500uL * sampleRateHz_;
        setBpm(bpm);
        setTicksPerLine(ticksPerLine);
        reset();
    }

    /**
     * Updates BPM dynamically while preserving current sub-tick fractional remainder den_.
     *
     * Params:
     *   bpm = Target beats per minute clamped to [20.0 .. 999.0].
     */
    void setBpm(double bpm) pure @safe {
        double clamped = isFinite(bpm) ? bpm : 125.0;
        if (clamped < 20.0) clamped = 20.0;
        if (clamped > 999.0) clamped = 999.0;
        bpm_ = clamped;
        ulong nextNum = cast(ulong)(clamped * 1000.0 + 0.5);
        if (nextNum < 20_000uL) nextNum = 20_000uL;
        num_ = nextNum;
    }

    /**
     * Updates tracker ticks per line dynamically.
     *
     * Params:
     *   ticksPerLine = Ticks per pattern row clamped to [1 .. 255].
     */
    void setTicksPerLine(uint ticksPerLine) pure @safe {
        uint t = ticksPerLine;
        if (t < 1) t = 1;
        if (t > 255) t = 255;
        tpl_ = t;
        if (tick_ >= tpl_) {
            tick_ = tpl_ - 1;
        }
    }

    /**
     * Configures song loop wrapping interval [loopStart .. loopEnd).
     *
     * Params:
     *   loopStart = Inclusive wrap target line.
     *   loopEnd = Exclusive loop end line (<= loopStart disables looping).
     */
    void setLoop(long loopStart, long loopEnd) pure @safe {
        loopStart_ = loopStart >= 0 ? loopStart : 0;
        loopEnd_ = loopEnd > loopStart_ ? loopEnd : 0;
    }

    /**
     * Resets playhead cleanly to line 0, tick 0 with zero accumulated rational remainder.
     */
    void reset() pure @safe {
        line_ = 0;
        tick_ = 0;
        phaseNum_ = 0;
        emitInitialTick_ = true;
    }

    /**
     * Moves playhead atomically to line, resetting tick counter and phase remainder.
     *
     * Params:
     *   line = Target zero-based song line.
     */
    void seekToLine(long line) pure @safe {
        line_ = line >= 0 ? line : 0;
        tick_ = 0;
        phaseNum_ = 0;
        emitInitialTick_ = true;
    }

    /**
     * Moves the playhead to line, allowing negative lines (count-in lines before the song start), tick 0.
     *
     * Params:
     *   line = Target line; negative lines trigger no clips and advance normally toward line 0.
     */
    void seekToLineSigned(long line) pure @safe {
        line_ = line;
        tick_ = 0;
        phaseNum_ = 0;
        emitInitialTick_ = true;
    }

    /**
     * Computes exact integer sample delay for a sub-line delay effect step in [0..31] (/ 32 line).
     *
     * Params:
     *   step0To31 = Fractional offset in 1/32nds of one pattern line (0..31).
     *
     * Returns:
     *   Rounded delay offset in audio sample frames.
     */
    ulong subLineDelaySamples(uint step0To31) const pure @safe {
        immutable uint s = step0To31 > 31 ? 31 : step0To31;
        if (s == 0 || num_ == 0) {
            return 0;
        }
        return (cast(ulong) s * cast(ulong) tpl_ * den_ + 16uL * num_) / (32uL * num_);
    }

    /**
     * Advances rational tick phase across up to sliceFrames starting at cursorFrame until the next tick boundary.
     *
     * Allows mid-slice BPM or TPL changes inside the same 64-frame quantum without phase loss.
     *
     * Params:
     *   sliceFrames = Total frames inside the current audio quantum (typically 64).
     *   cursorFrame = In/out sample cursor [0 .. sliceFrames] advanced on return.
     *   ev = Populated TickEvent when this call lands on a tick boundary before sliceFrames.
     *
     * Returns:
     *   True if a tick boundary occurred inside [cursorFrame .. sliceFrames); false if cursor reached sliceFrames cleanly.
     */
    bool nextTickInSlice(uint sliceFrames, ref uint cursorFrame, out TickEvent ev) pure @safe {
        ev = TickEvent.init;
        if (cursorFrame >= sliceFrames || den_ == 0 || num_ == 0) {
            return false;
        }

        if (emitInitialTick_) {
            emitInitialTick_ = false;
            ev = TickEvent(cursorFrame, line_, tick_, tick_ == 0);
            advanceTickCounter();
            return true;
        }

        immutable ulong remToNext = den_ - phaseNum_;
        immutable ulong samplesNeeded = (remToNext + num_ - 1uL) / num_;
        immutable ulong remainingSlice = cast(ulong)(sliceFrames - cursorFrame);

        if (samplesNeeded <= remainingSlice) {
            cursorFrame += cast(uint) samplesNeeded;
            phaseNum_ = (phaseNum_ + samplesNeeded * num_) - den_;
            if (cursorFrame < sliceFrames) {
                ev = TickEvent(cursorFrame, line_, tick_, tick_ == 0);
                advanceTickCounter();
                return true;
            }
            emitInitialTick_ = true;
            return false;
        }

        phaseNum_ += remainingSlice * num_;
        cursorFrame = sliceFrames;
        return false;
    }

    /**
     * Advances the clock over frames and writes all occurring TickEvents into outTicks.
     *
     * Params:
     *   frames = Audio sample frame count to advance.
     *   outTicks = Caller-provided destination buffer.
     *
     * Returns:
     *   Number of TickEvents recorded inside [0 .. frames).
     */
    size_t advanceSlice(uint frames, TickEvent[] outTicks) pure @safe {
        uint cursor = 0;
        size_t count = 0;
        while (cursor < frames) {
            TickEvent ev;
            if (!nextTickInSlice(frames, cursor, ev)) {
                break;
            }
            if (count < outTicks.length) {
                outTicks[count++] = ev;
            } else {
                count++;
            }
        }
        return count;
    }

    /**
     * Returns current beats per minute.
     *
     * Returns:
     *   Active BPM value.
     */
    double bpm() const pure @safe {
        return bpm_;
    }

    /**
     * Returns current ticks per line speed.
     *
     * Returns:
     *   Active TPL count.
     */
    uint ticksPerLine() const pure @safe {
        return tpl_;
    }

    /**
     * Returns current zero-based song line index.
     *
     * Returns:
     *   Current line number.
     */
    long currentLine() const pure @safe {
        return line_;
    }

    /**
     * Returns current tick index within currentLine [0 .. ticksPerLine).
     *
     * Returns:
     *   Current tick index.
     */
    uint currentTick() const pure @safe {
        return tick_;
    }

    /**
     * Returns exact integer remainder numerator [0 .. denominator) useful for clock invariants.
     *
     * Returns:
     *   Phase numerator.
     */
    ulong phaseNumerator() const pure @safe {
        return phaseNum_;
    }

    /**
     * Returns fixed sample-rate rational denominator (2500 * sampleRateHz).
     *
     * Returns:
     *   Phase denominator.
     */
    ulong phaseDenominator() const pure @safe {
        return den_;
    }

    private void advanceTickCounter() pure @safe {
        tick_++;
        if (tick_ >= tpl_) {
            tick_ = 0;
            line_++;
            if (loopEnd_ > loopStart_ && line_ >= loopEnd_) {
                line_ = loopStart_;
            }
        }
    }
}
