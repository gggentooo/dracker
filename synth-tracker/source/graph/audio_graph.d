/**
 * File:         source/graph/audio_graph.d
 * Module:       graph.audio_graph
 * Phase:        Phase 2.4 — Fixed-Quantum RT AudioGraph Executor
 *
 * Purpose:
 *   Executes compiled GraphPlans in fixed FIXED_BLOCK_FRAMES = 64 internal slices with host-buffer chunking, sample-accurate event sub-blocking, silence skip, SwapGraphPlan, SwapModuleAsset, and TripleBuffer telemetry.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; unregistered-thread safe; zero allocations or locks on render path.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, foundation.concurrency, graph.context, graph.event, graph.buffer, graph.module_api, graph.plan
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct GraphTelemetry : per-module peak meters, oscilloscope ring snapshot, DSP CPU cycles
 *   - struct AudioGraph : render(float[][2] outputs, const(float[])[2] inputs, uint hostFrames, TransportState)
 *   - void swapPlan(GraphPlan* newPlan, RetireSink) @nogc nothrow
 *   - void swapModuleAsset(ModuleId id, uint slot, void* newAsset, RetireSink) @nogc nothrow
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.audio_graph;
