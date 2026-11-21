/**
 * File:         source/modules/effects/lfo.d
 * Module:       modules.effects.lfo
 * Phase:        Phase 4.2 (Tier 1) — Audio-Rate & CV LFO / Amplitude Modulator
 *
 * Purpose:
 *   Generates audio-rate CV modulation buffers (PortKind.cvControl) or applies direct amplitude/panning modulation to incoming audio, supporting tempo sync.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; emits 64-sample CV buffers cleanly eliminating control zipper noise.
 *
 * Dependencies:
 *   Internal: dsp.tables, dsp.interp, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct LfoMod (typeId = "fx.lfo", ports: audioStereo in/out, cvControl cvOut)
 *   - @Param waveform, freq, syncUnit, amplitude, phaseOffset, stereoSpread
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.lfo;
