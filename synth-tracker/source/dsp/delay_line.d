/**
 * File:         source/dsp/delay_line.d
 * Module:       dsp.delay_line
 * Phase:        Phase 1.4 — Fractional Power-of-Two Delay Line
 *
 * Purpose:
 *   Implements an OwnedBuffer-backed power-of-two circular delay line with bitmask indexing and Catmull-Rom/linear fractional taps.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow during read/write/tap; buffer allocated off-RT via OwnedBuffer!float with zero heap allocations on audio thread.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, dsp.interp
 *   External: core.lifetime (move), core.stdc.string (memset), std.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DelayLine : tryInit(), write(), readTap(), readLinear(), readCatmullRom(), clear(), capacity(), maxDelay(), empty()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.delay_line;

import core.lifetime : move;
import core.stdc.string : memset;
import std.math : isFinite;

import dsp.interp : interpCatmullRom, interpLinear;
import foundation.memory : OwnedBuffer;

/**
 * Power-of-two circular delay line backed by move-only @nogc OwnedBuffer!float.
 *
 * Allocates power-of-two capacity >= maxDelaySamples + 4 so 4-point Catmull-Rom taps never
 * wrap into unwritten future slots.
 */
struct DelayLine {
    private OwnedBuffer!float buffer_;
    private size_t mask_ = 0;
    private size_t maxDelay_ = 0;
    private size_t writePos_ = 0;

    @disable this(this);

    @nogc nothrow:

    /**
     * Transfers delay-line buffer ownership from an rvalue source.
     *
     * Params:
     *   rhs = Source DelayLine moved into this instance.
     *
     * Returns:
     *   Reference to this DelayLine.
     */
    ref DelayLine opAssign(DelayLine rhs) return {
        buffer_ = move(rhs.buffer_);
        mask_ = rhs.mask_;
        maxDelay_ = rhs.maxDelay_;
        writePos_ = rhs.writePos_;
        rhs.mask_ = 0;
        rhs.maxDelay_ = 0;
        rhs.writePos_ = 0;
        return this;
    }

    /**
     * Allocates a power-of-two ring buffer supporting delays up to maxDelaySamples.
     *
     * Params:
     *   maxDelaySamples = Maximum fractional or integer delay length in samples.
     *
     * Returns:
     *   True on success; false on size overflow or OOM.
     */
    bool tryInit(size_t maxDelaySamples) {
        if (maxDelaySamples > size_t.max - 4) {
            return false;
        }
        immutable size_t required = maxDelaySamples + 4;
        size_t pow2 = 8;
        while (pow2 < required) {
            if (pow2 > size_t.max / 2) {
                return false;
            }
            pow2 <<= 1;
        }

        OwnedBuffer!float allocated;
        if (!OwnedBuffer!float.tryAllocate(pow2, allocated)) {
            return false;
        }

        buffer_ = move(allocated);
        mask_ = pow2 - 1;
        maxDelay_ = maxDelaySamples;
        writePos_ = 0;
        return true;
    }

    /**
     * Zeros all buffered samples and resets the circular write cursor without reallocating.
     */
    void clear() {
        if (buffer_.ptr !is null && buffer_.length > 0) {
            memset(buffer_.ptr, 0, buffer_.length * float.sizeof);
        }
        writePos_ = 0;
    }

    /**
     * Writes one sample into the delay line and advances the write cursor.
     *
     * Params:
     *   sample = Input audio sample (non-finite inputs are stored as 0.0f).
     */
    void write(float sample) {
        if (buffer_.empty()) {
            return;
        }
        buffer_[writePos_ & mask_] = isFinite(sample) ? sample : 0.0f;
        writePos_++;
    }

    /**
     * Reads an integer tap delaySamples behind the most recently written sample.
     *
     * delaySamples == 0 reads the sample written by the most recent write() call.
     *
     * Params:
     *   delaySamples = Integer delay in samples, clamped to maxDelay().
     *
     * Returns:
     *   Delayed sample, or 0.0f when uninitialized.
     */
    float readTap(size_t delaySamples) const pure {
        if (buffer_.empty()) {
            return 0.0f;
        }
        immutable size_t d = delaySamples > maxDelay_ ? maxDelay_ : delaySamples;
        immutable size_t idx = (writePos_ - 1 - d) & mask_;
        return buffer_[idx];
    }

    /**
     * Reads a linearly interpolated fractional tap at delaySamples.
     *
     * Params:
     *   delaySamples = Fractional delay in samples, clamped to [0.0f, maxDelay()].
     *
     * Returns:
     *   Linearly interpolated sample.
     */
    float readLinear(float delaySamples) const pure {
        if (buffer_.empty() || !isFinite(delaySamples)) {
            return 0.0f;
        }
        float d = delaySamples;
        if (d < 0.0f) {
            d = 0.0f;
        } else if (d > cast(float) maxDelay_) {
            d = cast(float) maxDelay_;
        }
        immutable size_t d0 = cast(size_t) d;
        immutable float frac = d - cast(float) d0;
        immutable float s0 = buffer_[(writePos_ - 1 - d0) & mask_];
        immutable float s1 = buffer_[(writePos_ - 1 - (d0 + 1)) & mask_];
        return interpLinear(s0, s1, frac);
    }

    /**
     * Reads a 4-point Catmull-Rom interpolated fractional tap at delaySamples.
     *
     * Falls back cleanly to linear interpolation when delaySamples < 1.0f so future
     * ring slots are never referenced.
     *
     * Params:
     *   delaySamples = Fractional delay in samples, clamped to [0.0f, maxDelay()].
     *
     * Returns:
     *   Cubic-interpolated delayed sample.
     */
    float readCatmullRom(float delaySamples) const pure {
        if (buffer_.empty() || !isFinite(delaySamples)) {
            return 0.0f;
        }
        float d = delaySamples;
        if (d < 0.0f) {
            d = 0.0f;
        } else if (d > cast(float) maxDelay_) {
            d = cast(float) maxDelay_;
        }
        if (d < 1.0f) {
            return readLinear(d);
        }

        immutable size_t d0 = cast(size_t) d;
        immutable float frac = d - cast(float) d0;
        immutable float ym1 = buffer_[(writePos_ - 1 - (d0 - 1)) & mask_];
        immutable float y0 = buffer_[(writePos_ - 1 - d0) & mask_];
        immutable float y1 = buffer_[(writePos_ - 1 - (d0 + 1)) & mask_];
        immutable float y2 = buffer_[(writePos_ - 1 - (d0 + 2)) & mask_];
        return interpCatmullRom(ym1, y0, y1, y2, frac);
    }

    /**
     * Returns the allocated power-of-two ring capacity in samples.
     *
     * Returns:
     *   Total circular buffer length.
     */
    size_t capacity() const pure @safe {
        return buffer_.length;
    }

    /**
     * Returns the configured maximum delay length in samples.
     *
     * Returns:
     *   Maximum addressable delay.
     */
    size_t maxDelay() const pure @safe {
        return maxDelay_;
    }

    /**
     * Reports whether the delay line has not yet been initialized.
     *
     * Returns:
     *   True if capacity == 0.
     */
    bool empty() const pure @safe {
        return buffer_.empty();
    }
}
