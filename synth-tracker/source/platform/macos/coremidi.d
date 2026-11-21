/**
 * File:         source/platform/macos/coremidi.d
 * Module:       platform.macos.coremidi
 * Phase:        Phase 3.3 — CoreMIDI Multi-Source Input/Output Driver
 *
 * Purpose:
 *   Binds macOS CoreMIDI endpoints and routes incoming packets from CoreMIDI Mach callback threads through per-endpoint SpscRing or bounded MpscRing queues without locks.
 *
 * Real-Time & Safety Contract:
 *   MIDI read callback is extern(C) @nogc nothrow; never allocates or blocks.
 *
 * Dependencies:
 *   Internal: platform.interfaces, platform.macos.corefoundation, foundation.concurrency
 *   External: macOS CoreMIDI.framework
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct MidiPacket { ulong timestamp; ubyte[3] data; ubyte len; }
 *   - class CoreMidiDriver : IMidiDriver
 *   - extern(C) void midiReadProc(...) @nogc nothrow
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.macos.coremidi;
