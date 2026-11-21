/**
 * File:         source/sequencer/note.d
 * Module:       sequencer.note
 * Phase:        Phase 5.1 — Tracker NoteCell, NoteCmd & EffectCode Definitions
 *
 * Purpose:
 *   Defines the compact 8-byte POD NoteCell layout (note, velocity, moduleId, paramId, effect, effectVal) and explicit EffectCode enum covering tracker slides, vibrato, arp, retrigger, cut, probability, and sub-line delay.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow pure @safe POD structs; static assert(NoteCell.sizeof == 8) for atomic cell patching.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum NoteCmd : ubyte { empty, noteOff, allNotesOff, prevTrack, setPitch, stopSong }
 *   - enum EffectCode : ubyte { slideUp = 0x01, slideDown = 0x02, portamento = 0x03, vibrato = 0x04, ..., subLineDelayBase = 0x40 }
 *   - struct NoteCell { ubyte note; ubyte velocity; ushort moduleId; ushort paramId; ubyte effect; ubyte effectVal; }
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.note;
