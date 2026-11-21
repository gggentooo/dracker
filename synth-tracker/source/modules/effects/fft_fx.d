/**
 * File:         source/modules/effects/fft_fx.d
 * Module:       modules.effects.fft_fx
 * Phase:        Phase 4.7 (Tier 2) — STFT Spectral Processor
 *
 * Purpose:
 *   Short-Time Fourier Transform overlap-add spectral processor supporting spectral freeze, bin shift, tilt, and random phase scatter.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); pre-allocated FFT/overlap-add scratch buffers via OwnedBuffer!float.
 *
 * Dependencies:
 *   Internal: dsp.fft, dsp.tables, dsp.smoother, foundation.memory, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct FftFx (typeId = "fx.fft", ports: audioStereo in/out)
 *   - @Param fftSize, feedback, binShift, freeze, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.fft_fx;
