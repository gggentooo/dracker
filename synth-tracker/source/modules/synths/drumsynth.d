/**
 * File:         source/modules/synths/drumsynth.d
 * Module:       modules.synths.drumsynth
 * Phase:        Phase 4.3 (Tier 1) — Multi-Voice Drum Kit Synthesizer
 *
 * Purpose:
 *   Synthesizes mapped kick, snare, closed/open hi-hat, tom, and percussion voices across note ranges using pitch/amp envelopes and noise/bandpass networks.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; pre-allocated voice array; zero heap calls.
 *
 * Dependencies:
 *   Internal: dsp.tables, dsp.oscillator, dsp.filter_svf, dsp.envelope, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DrumSynth (typeId = "synth.drumsynth", ports: event in, audioStereo out)
 *   - @Param kitDecay, tone, snappy, panSpread, masterVol
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.drumsynth;
