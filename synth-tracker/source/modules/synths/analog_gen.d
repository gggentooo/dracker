/**
 * File:         source/modules/synths/analog_gen.d
 * Module:       modules.synths.analog_gen
 * Phase:        Phase 4.3 (Tier 1) — Polyphonic Analog Synthesizer
 *
 * Purpose:
 *   Up to 32-voice virtual-analog synth featuring dual PolyBLEP/drawn-waveform oscillators, unison detune, Cytomic SVF filter, and ADSR amp/filter envelopes.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; uses VoicePool and OwnedBuffer!float for drawn waveform swaps via SwapModuleAsset.
 *
 * Dependencies:
 *   Internal: dsp.voice_pool, dsp.oscillator, dsp.filter_svf, dsp.envelope, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct AnalogGen (typeId = "synth.analog_gen", ports: event in, cvControl in, audioStereo out)
 *   - @Param waveform, unison, detune, filterCutoff, filterReso, envAttack/Decay/Sustain/Release
 *   - Hooks: handleEvent, process, serializeExtra/deserializeExtra (drawn waveform), swapAsset
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.analog_gen;
