/**
 * File:         source/dsp/oscillator.d
 * Module:       dsp.oscillator
 * Phase:        Phase 1.4 — PolyBLEP, Wavetable & Noise Oscillators
 *
 * Purpose:
 *   Implements anti-aliased PolyBLEP oscillators (saw, pulse/square, triangle, sine), arbitrary single-cycle drawn wavetable playback, and deterministic PRNG white/pink noise.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero NaN init and stateless per-voice phase accumulator.
 *
 * Dependencies:
 *   Internal: foundation.types, dsp.tables, dsp.interp
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum OscWaveform : ubyte { sine, triangle, saw, pulse, noise, drawnWave }
 *   - struct PolyBlepOsc : setFrequency(freqHz, sampleRate), nextSample(OscWaveform, float pulseWidth), syncPhase(float phase), reset()
 *   - struct DrawnWaveOsc : interpolates 32..2048-sample waveform slices
 *   - struct DeterministicNoise : white() / pink() @nogc nothrow
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.oscillator;
