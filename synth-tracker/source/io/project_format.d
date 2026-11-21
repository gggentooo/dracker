/**
 * File:         source/io/project_format.d
 * Module:       io.project_format
 * Phase:        Phase 6.2 — Versioned 4CC Chunked .msv & .msym Serializer
 *
 * Purpose:
 *   Reads and writes versioned IFF-style 4CC chunked .msv (project) and .msym (module/MetaModule preset) files, skipping unknown chunks gracefully for forward compatibility.
 *
 * Real-Time & Safety Contract:
 *   Off-RT @safe parser/serializer; fuzz-hardened against truncated or malformed chunk lengths.
 *
 * Dependencies:
 *   Internal: io.binary_stream, graph.registry, graph.module_api, sequencer.engine, sequencer.pattern, sequencer.timeline
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum uint MSV_FORMAT_VERSION = 1
 *   - bool saveProject(const EngineState, string path, out string err)
 *   - bool loadProject(const(ubyte)[] bytes, out LoadedProject proj, out string err)
 *   - bool savePreset(.msym) / loadPreset(.msym)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.project_format;
