/**
 * File:         source/graph/buffer.d
 * Module:       graph.buffer
 * Phase:        Phase 2.1 — AudioBlock, ChannelSlice & Silence Tracking
 *
 * Purpose:
 *   Manages pre-allocated scratch audio and CV channel buffers inside compiled GraphPlans, tracking per-buffer silent flags so idle modules are skipped cleanly.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; OwnedBuffer-backed non-GC storage aligned for SIMD.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ChannelSlice { float[] samples; bool silent; }
 *   - struct AudioBlock { float[][2] channels; bool silent; void zeroFill(uint frames); }
 *   - struct CvBlock { float[] samples; bool silent; }
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.buffer;
