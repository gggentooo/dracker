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
 *   - bool arePortsCompatible(PortKind src, PortKind dst) @nogc nothrow pure @safe
 *   - bool isAudioPort(PortKind kind) @nogc nothrow pure @safe
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.port;

/**
 * Signal domain carried by a module port.
 */
enum PortKind : ubyte {
    audioStereo = 0,
    audioMono = 1,
    sidechainStereo = 2,
    event = 3,
    cvControl = 4
}

/**
 * Signal flow direction of a module port.
 */
enum PortDirection : ubyte {
    input = 0,
    output = 1
}

/**
 * Compile-time immutable descriptor declaring one port exposed by a module.
 */
struct PortDescriptor {
    string id;
    string name;
    PortKind kind = PortKind.audioStereo;
    PortDirection dir = PortDirection.input;
}

/**
 * Reports whether kind carries PCM audio samples (main or sidechain).
 *
 * Params:
 *   kind = Port kind to inspect.
 *
 * Returns:
 *   True for audioStereo, audioMono, or sidechainStereo.
 */
bool isAudioPort(PortKind kind) @nogc nothrow pure @safe {
    return kind == PortKind.audioStereo
        || kind == PortKind.audioMono
        || kind == PortKind.sidechainStereo;
}

/**
 * Checks whether an output port of kind src can wire into an input port of kind dst.
 *
 * Stereo and mono audio outputs may feed audioStereo, audioMono, or sidechainStereo inputs;
 * event and cvControl ports connect strictly within their own signal domain.
 *
 * Params:
 *   src = Source output port kind.
 *   dst = Destination input port kind.
 *
 * Returns:
 *   True if a wire between src and dst is valid.
 */
bool arePortsCompatible(PortKind src, PortKind dst) @nogc nothrow pure @safe {
    if (src == PortKind.audioStereo || src == PortKind.audioMono) {
        return isAudioPort(dst);
    }
    if (src == PortKind.event) {
        return dst == PortKind.event;
    }
    if (src == PortKind.cvControl) {
        return dst == PortKind.cvControl;
    }
    return false;
}
