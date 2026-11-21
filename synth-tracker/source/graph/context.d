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
 *   - struct ProcessContext { float sampleRate; uint frames; TransportState transport; EventSink eventOut; bool inputSilent; }
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.context;
