/**
 * File:         source/sequencer/track_effects.d
 * Module:       sequencer.track_effects
 * Phase:        Phase 5.3 — Per-Track Tracker Effect State Machine
 *
 * Purpose:
 *   Interprets active NoteCells and per-tick tracker effect memory (slides, vibrato, arpeggio, retrigger, note cut, note delay, probability, sub-line delay 0x40..0x5F) into sample-accurate ModEvents.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; pre-allocated fixed track state array.
 *
 * Dependencies:
 *   Internal: foundation.types, graph.event, sequencer.note, sequencer.clock
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct TrackEffectState : portamentoTarget, vibratoPhase, arpStep, retrigCounter, cutTick, lastPitch
 *   - void processLineTick(...) @nogc nothrow
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.track_effects;
