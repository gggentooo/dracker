/**
 * File:         source/modules/synths/sampler.d
 * Module:       modules.synths.sampler
 * Phase:        Phase 4.4 (Tier 1) — Multi-Slot Polyphonic Sampler
 *
 * Purpose:
 *   Plays multi-slot audio samples with Catmull-Rom interpolation, forward/ping-pong loops, and multi-breakpoint vol/pan/pitch envelopes; audio files decode off-RT via io/audio_io.d.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on RT process(); sample buffers live in unscanned OwnedBuffer!float swapped via SwapModuleAsset and retired to UI thread.
 *
 * Dependencies:
 *   Internal: dsp.voice_pool, dsp.resampler, dsp.envelope, foundation.memory, graph.*, (off-RT: io.audio_io)
 *   External: None on RT path
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Sampler (typeId = "synth.sampler", ports: event in, audioStereo in/out)
 *   - @Param volume, panning, fineTune, sampleOffset, loopMode, interpQuality
 *   - Hooks: handleEvent, process, serializeExtra/deserializeExtra (embedded PCM/envelopes), swapAsset
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.sampler;
