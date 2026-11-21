/**
 * File:         source/io/importers/sunvox_importer.d
 * Module:       io.importers.sunvox_importer
 * Phase:        Phase 6.5 (Optional) — Best-Effort .sunvox Structural Importer
 *
 * Purpose:
 *   Imports legacy .sunvox project structures on a best-effort basis—mapping patterns, timeline clips, wiring topology, and compatible module parameters onto SynthTracker's clean-slate DSP modules (musical equivalence rather than bit-exact clone output).
 *
 * Real-Time & Safety Contract:
 *   Off-RT @safe chunk parsing via io.binary_stream.
 *
 * Dependencies:
 *   Internal: io.binary_stream, io.project_format, sequencer.note
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ImportReport { uint mappedModules; uint skippedModules; string[] warnings; }
 *   - bool importSunvoxFile(const(ubyte)[] bytes, out LoadedProject proj, out ImportReport report, out string err)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.importers.sunvox_importer;
