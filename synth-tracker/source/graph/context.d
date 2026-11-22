/**
 * File:         source/graph/context.d
 * Module:       graph.context
 * Phase:        Phase 2.1 — Per-Slice Module ProcessContext & EventSink
 *
 * Purpose:
 *   Defines the runtime context passed into every module process() call, carrying sample rate, slice frame count (<= 64), transport BPM/TPL/playhead, silence flags, and outgoing EventSink.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; non-allocating function-pointer EventSink into pre-allocated EventArena.
 *
 * Dependencies:
 *   Internal: foundation.types, graph.event
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct TransportState { double bpm; uint ticksPerLine; ulong totalFrames; bool playing; }
 *   - struct EventSink { void emit(scope const ref ModEvent ev) @nogc nothrow; }
 *   - struct ProcessContext { float sampleRate; uint frames; uint sliceOffset; TransportState transport; EventSink eventOut; bool inputSilent; }
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.context;

import foundation.types : FIXED_BLOCK_FRAMES;
import graph.event : ModEvent;

/**
 * Musical transport state visible to modules during slice processing.
 */
struct TransportState {
    double bpm = 125.0;
    uint ticksPerLine = 6;
    ulong totalFrames = 0;
    bool playing = false;
}

/**
 * Type-erased @nogc callback sink allowing control/event modules to emit downstream ModEvents.
 */
struct EventSink {
    void function(void* ctx, scope const ref ModEvent ev) @nogc nothrow pushFn = null;
    void* ctx = null;

    private void emitImpl(scope const ref ModEvent ev) @nogc nothrow {
        if (pushFn !is null) {
            pushFn(ctx, ev);
        }
    }

    /**
     * Emits ev by const reference through the bound graph event router if connected.
     *
     * Params:
     *   ev = Event whose frameOffset is relative to the invoking sub-slice.
     */
    void emit(scope const ref ModEvent ev) @nogc nothrow {
        emitImpl(ev);
    }

    /**
     * Emits an rvalue ModEvent through the bound graph event router if connected.
     *
     * Params:
     *   ev = Event value whose frameOffset is relative to the invoking sub-slice.
     */
    void emit(ModEvent ev) @nogc nothrow {
        emitImpl(ev);
    }
}

/**
 * Per-slice execution context passed into module process() and feedback hooks.
 */
struct ProcessContext {
    float sampleRate = 44100.0f;
    uint frames = FIXED_BLOCK_FRAMES;
    uint sliceOffset = 0;
    TransportState transport;
    EventSink eventOut;
    bool inputSilent = false;
    const(float)[][2] hostAudioIn;
    bool hostInputSilent = true;
    uint metaDepth = 0;
}
