/**
 * File:         source/modules/control/ctl2note.d
 * Module:       modules.control.ctl2note
 * Phase:        Phase 4.8 (Tier 2) — Controller-to-Note Converter
 *
 * Purpose:
 *   Converts continuous parameter or CV automation values into quantized NoteOn/NoteOff/Pitch ModEvents.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow.
 *
 * Dependencies:
 *   Internal: graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Ctl2Note (typeId = "ctl.ctl2note", ports: event in, cvControl in, event out)
 *   - @Param pitch, firstNote, rangeNotes, triggerMode
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.ctl2note;
