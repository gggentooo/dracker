/**
 * File:         source/dsp/voice_pool.d
 * Module:       dsp.voice_pool
 * Phase:        Phase 1.5 — Shared Polyphonic Voice Allocator
 *
 * Purpose:
 *   Centralizes polyphonic NoteId tracking, per-note pitch/velocity updates, deterministic voice stealing, and release-tail cleanup for AnalogGen, FmSynth, Sampler, and SpectraVoice.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; fixed compile-time MaxVoices capacity with zero heap allocation.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct VoicePool(VoiceT, size_t MaxVoices)
 *   - VoiceT* allocateVoice(NoteId id, out bool stolen) @nogc nothrow
 *   - VoiceT* findVoice(NoteId id) @nogc nothrow
 *   - void releaseVoice(NoteId id) / void allNotesOff() @nogc nothrow
 *   - void deactivateFinished() @nogc nothrow
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.voice_pool;
