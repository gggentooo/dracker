/**
 * File:         source/io/importers/smf_importer.d
 * Module:       io.importers.smf_importer
 * Phase:        Phase 6.5 (Optional) — Standard MIDI File (.mid) Importer
 *
 * Purpose:
 *   Parses SMF Type 0/1 MIDI files into SynthTracker patterns, tempo map changes, and default synth racks.
 *
 * Real-Time & Safety Contract:
 *   Off-RT @safe binary parsing via io.binary_stream.
 *
 * Dependencies:
 *   Internal: io.binary_stream, io.project_format, sequencer.note
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - bool importMidiFile(const(ubyte)[] bytes, out LoadedProject proj, out string err)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.importers.smf_importer;
