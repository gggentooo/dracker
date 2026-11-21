/**
 * File:         source/graph/module_api.d
 * Module:       graph.module_api
 * Phase:        Phase 2.2 — Compile-Time @Param UDA Protocol & ModuleAdapter!T
 *
 * Purpose:
 *   Extracts parameter metadata, port descriptors, NaN-free init assertions, named onParamChanged!field dispatch, and optional serializeExtra/swapAsset hooks from any module struct into a static ModuleVTable.
 *
 * Real-Time & Safety Contract:
 *   Compile-time reflection + @nogc nothrow ModuleVTable wrappers; enforces assertNoNaNInit!T() at build time.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, graph.port, graph.context, graph.event
 *   External: std.traits
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum ParamScale : ubyte { linear, logarithmic, discrete }
 *   - struct Param { string name; float minVal; float maxVal; float defaultVal; string unit; ParamScale scale; }
 *   - struct ParamDescriptor / struct ModuleDescriptor
 *   - struct ModuleVTable { prepare, reset, handleEvent, process, getParam, setParam, serializeExtra, deserializeExtra, swapAsset, destroy }
 *   - template ModuleAdapter(T) + void assertNoNaNInit(T)()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.module_api;
