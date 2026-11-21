/**
 * File:         source/graph/event.d
 * Module:       graph.event
 * Phase:        Phase 2.1 — Sample-Accurate ModEvent & Pre-Allocated EventArena
 *
 * Purpose:
 *   Defines typed real-time events (NoteOn, NoteOff, Pitch, Velocity, Param, Transport) with frameOffset [0..FIXED_BLOCK_FRAMES) and a fixed-capacity @nogc EventArena.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero RT reallocation; all events live in pre-sized OwnedBuffer/FixedArray storage.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum ModEventKind : ubyte { noteOn, noteOff, setPitch, setVelocity, setParam, setParamInstant, allNotesOff, transport }
 *   - struct ModEvent { uint frameOffset; ModEventKind kind; NoteId noteId; uint paramId; float valueA; float valueB; }
 *   - struct EventArena : push(ModEvent), sliceForModule(...), sortByFrameOffset(), clear()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.event;
