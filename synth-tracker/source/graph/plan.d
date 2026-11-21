/**
 * File:         source/graph/plan.d
 * Module:       graph.plan
 * Phase:        Phase 2.3 — Off-RT GraphCompiler, Topological Sort & Feedback Splitting
 *
 * Purpose:
 *   Compiles patchbay wiring off the audio thread into a flat topologically ordered @nogc GraphPlan, validating port kinds and converting FeedbackSend->FeedbackReceive edges into fixed-delay buffers.
 *
 * Real-Time & Safety Contract:
 *   Compiled off-RT into @nogc OwnedBuffer storage (!hasIndirections!T) so old plans can be safely retired from the RT thread.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, graph.port, graph.module_api
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct WireSpec { ModuleId srcMod; ushort srcPort; ModuleId dstMod; ushort dstPort; }
 *   - struct GraphPlan : flat executionOrder, pre-bound input/output buffer indices, feedback delay slots
 *   - struct GraphCompiler : static bool compile(..., out GraphPlan plan)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.plan;
