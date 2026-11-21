/**
 * File:         source/graph/port.d
 * Module:       graph.port
 * Phase:        Phase 2.1 — Typed Audio, Sidechain, Event & CV Port Definitions
 *
 * Purpose:
 *   Defines static port descriptors and kind compatibility rules allowing modules to expose stereo/mono audio, sidechain inputs, event streams, and audio-rate CV modulation ports.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow pure @safe POD metadata.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum PortKind : ubyte { audioStereo, audioMono, sidechainStereo, event, cvControl }
 *   - enum PortDirection : ubyte { input, output }
 *   - struct PortDescriptor { string id; string name; PortKind kind; PortDirection dir; }
 *   - bool arePortsCompatible(PortKind src, PortKind dst) pure @nogc nothrow
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.port;
