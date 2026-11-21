/**
 * File:         source/io/importers/xm_importer.d
 * Module:       io.importers.xm_importer
 * Phase:        Phase 6.5 (Optional) — FastTracker II (.xm) Importer
 *
 * Purpose:
 *   Imports .xm modules, mapping pattern commands, instruments, and sample data into Sampler modules and tracker patterns.
 *
 * Real-Time & Safety Contract:
 *   Off-RT @safe binary parsing via io.binary_stream.
 *
 * Dependencies:
 *   Internal: io.binary_stream, io.project_format, sequencer.note, modules.synths.sampler
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - bool importXmFile(const(ubyte)[] bytes, out LoadedProject proj, out string err)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.importers.xm_importer;
