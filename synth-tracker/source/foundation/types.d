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
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - alias Sample = float
 *   - enum uint FIXED_BLOCK_FRAMES = 64
 *   - enum uint MAX_CHANNELS = 2
 *   - alias FrameTime = ulong
 *   - struct NoteId / ModuleId / PortId (typed POD IDs with explicit defaults)
 *   - struct StereoFrame (left = 0.0f, right = 0.0f)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module foundation.types;
