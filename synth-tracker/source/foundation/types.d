/**
 * File:         source/foundation/types.d
 * Module:       foundation.types
 * Phase:        Phase 0.4 — Canonical RT Types & Fixed Quantum Constants
 *
 * Purpose:
 *   Defines core primitive aliases, sample-block quantum constants, and strongly-typed IDs shared across DSP, Graph, Sequencer, and Platform layers.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow pure @safe; value types with zero GC indirections.
 *
 * Dependencies:
 *   Internal: None (root foundation module)
 *   External: std.traits (hasIndirections)
 *
 * Planned API (Types, Functions & Hooks):
 *   - alias Sample = float
 *   - enum uint FIXED_BLOCK_FRAMES = 64
 *   - enum uint MAX_CHANNELS = 2
 *   - enum size_t CACHE_LINE_SIZE = 64
 *   - enum size_t DEFAULT_SIMD_ALIGNMENT = 32
 *   - enum uint DEFAULT_SAMPLE_RATE = 44_100
 *   - alias FrameTime = ulong
 *   - struct NoteId / ModuleId / PortId (typed POD IDs with explicit defaults)
 *   - struct StereoFrame (left = 0.0f, right = 0.0f)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module foundation.types;

import std.traits : hasIndirections;

alias Sample = float;

enum uint FIXED_BLOCK_FRAMES = 64;
enum uint MAX_CHANNELS = 2;
enum size_t CACHE_LINE_SIZE = 64;
enum size_t DEFAULT_SIMD_ALIGNMENT = 32;
enum uint DEFAULT_SAMPLE_RATE = 44_100;

alias FrameTime = ulong;

/**
 * Strongly-typed identifier for an active or scheduled musical note instance.
 *
 * Zero represents an unassigned or invalid note identifier.
 */
struct NoteId {
    uint value = 0;

    enum NoteId none = NoteId(0);

    /**
     * Checks whether this identifier refers to an active note rather than the sentinel zero value.
     *
     * Returns:
     *   True if the note ID is non-zero.
     */
    bool isValid() const @nogc nothrow pure @safe {
        return value != 0;
    }
}

/**
 * Strongly-typed identifier for a module node inside an AudioGraph.
 *
 * uint.max represents an unassigned or invalid module identifier.
 */
struct ModuleId {
    uint value = uint.max;

    enum ModuleId invalid = ModuleId(uint.max);

    /**
     * Checks whether this identifier refers to a valid module slot.
     *
     * Returns:
     *   True if the module ID is not the invalid sentinel.
     */
    bool isValid() const @nogc nothrow pure @safe {
        return value != uint.max;
    }
}

/**
 * Strongly-typed identifier for a typed input or output port on a module.
 *
 * ushort.max represents an unassigned or invalid port identifier.
 */
struct PortId {
    ushort value = ushort.max;

    enum PortId invalid = PortId(ushort.max);

    /**
     * Checks whether this identifier refers to a valid port slot.
     *
     * Returns:
     *   True if the port ID is not the invalid sentinel.
     */
    bool isValid() const @nogc nothrow pure @safe {
        return value != ushort.max;
    }
}

/**
 * Explicit zero-initialized stereo audio sample pair.
 *
 * Both channels default to 0.0f to prevent D's default float.nan initialization from
 * entering real-time signal processing pipelines.
 */
struct StereoFrame {
    Sample left = 0.0f;
    Sample right = 0.0f;

    enum StereoFrame zero = StereoFrame(0.0f, 0.0f);

    /**
     * Applies component-wise addition or subtraction with another stereo frame.
     *
     * Params:
     *   rhs = Right-hand stereo frame operand.
     *
     * Returns:
     *   Resulting stereo frame.
     */
    StereoFrame opBinary(string op)(StereoFrame rhs) const @nogc nothrow pure @safe
    if (op == "+" || op == "-") {
        static if (op == "+") {
            return StereoFrame(left + rhs.left, right + rhs.right);
        } else {
            return StereoFrame(left - rhs.left, right - rhs.right);
        }
    }

    /**
     * Scales both channels by a scalar sample gain.
     *
     * Params:
     *   gain = Linear amplitude multiplier.
     *
     * Returns:
     *   Scaled stereo frame.
     */
    StereoFrame opBinary(string op)(Sample gain) const @nogc nothrow pure @safe
    if (op == "*") {
        return StereoFrame(left * gain, right * gain);
    }

    /**
     * Scales both channels by a left-hand scalar sample gain.
     *
     * Params:
     *   gain = Linear amplitude multiplier.
     *
     * Returns:
     *   Scaled stereo frame.
     */
    StereoFrame opBinaryRight(string op)(Sample gain) const @nogc nothrow pure @safe
    if (op == "*") {
        return StereoFrame(gain * left, gain * right);
    }

    /**
     * Accumulates or subtracts another stereo frame in place.
     *
     * Params:
     *   rhs = Right-hand stereo frame operand.
     *
     * Returns:
     *   Reference to this stereo frame.
     */
    ref StereoFrame opOpAssign(string op)(StereoFrame rhs) return @nogc nothrow pure @safe
    if (op == "+" || op == "-") {
        static if (op == "+") {
            left += rhs.left;
            right += rhs.right;
        } else {
            left -= rhs.left;
            right -= rhs.right;
        }
        return this;
    }
}

static assert(!hasIndirections!NoteId);
static assert(!hasIndirections!ModuleId);
static assert(!hasIndirections!PortId);
static assert(!hasIndirections!StereoFrame);
static assert(StereoFrame.init.left == 0.0f && StereoFrame.init.right == 0.0f);
