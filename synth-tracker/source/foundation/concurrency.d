/**
 * File:         source/foundation/concurrency.d
 * Module:       foundation.concurrency
 * Phase:        Phase 0.3 — Lock-Free Rings, Atomics & Telemetry Buffers
 *
 * Purpose:
 *   Provides wait-free/lock-free SPSC, MPSC, atomic wrappers, and triple-buffered snapshot channels decoupling UI, CoreMIDI, I/O worker, and unregistered RT audio threads.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; uses core.atomic (MemoryOrder.acq / rel) with cache-line padding (64 bytes) to eliminate false sharing and zero mutex locks.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory
 *   External: core.atomic (atomicLoad, atomicStore, cas, MemoryOrder)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct SpscRing(T) : single-producer/single-consumer ring for UI->RT commands, RT->UI retire queue, and per-endpoint MIDI
 *   - struct MpscRing(T) : bounded multi-producer/single-consumer ring for multi-thread CoreMIDI / worker aggregation
 *   - struct Atomic(T) : typed atomic load/store wrapper
 *   - struct TripleBuffer(T) : wait-free latest-snapshot publisher for meters, playhead, and oscilloscope telemetry
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module foundation.concurrency;
