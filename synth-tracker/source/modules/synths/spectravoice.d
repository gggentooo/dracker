/**
 * File:         source/modules/synths/spectravoice.d
 * Module:       modules.synths.spectravoice
 * Phase:        Phase 4.9 (Tier 2) — Additive Harmonic / FFT Wavetable Synth
 *
 * Purpose:
 *   Synthesizes rich harmonic spectra via off-RT inverse FFT wavetable generation and plays polyphonic voices through VoicePool.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on RT process(); spectral wavetables compiled off-RT and swapped via SwapModuleAsset.
 *
 * Dependencies:
 *   Internal: dsp.voice_pool, dsp.fft, dsp.interp, dsp.envelope, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct SpectraVoice (typeId = "synth.spectravoice", ports: event in, audioStereo out)
 *   - @Param harmonicProfile, bandwidth, attackMs, releaseMs
 *   - Hooks: serializeExtra, swapAsset
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.spectravoice;
