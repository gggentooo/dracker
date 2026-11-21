/**
 * File:         source/modules/synths/fm_synth.d
 * Module:       modules.synths.fm_synth
 * Phase:        Phase 4.3 (Tier 1) — 4/5-Operator FM Synthesizer
 *
 * Purpose:
 *   Polyphonic FM synthesizer inspired by SunVox FMX with selectable modulation routing algorithms, per-operator ratio/feedback/ADSR, and VoicePool voice allocation.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero NaN state; VoicePool-backed.
 *
 * Dependencies:
 *   Internal: dsp.voice_pool, dsp.tables, dsp.envelope, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct FmSynth (typeId = "synth.fm_synth", ports: event in, audioStereo out)
 *   - @Param algorithm, feedback, op1..op5 ratio/level/ADSR
 *   - Hooks: handleEvent, process, onParamChanged
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.fm_synth;
