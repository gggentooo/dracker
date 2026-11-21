/**
 * File:         source/modules/synths/vorbis_player.d
 * Module:       modules.synths.vorbis_player
 * Phase:        Phase 4.9 (Tier 2) — Background-Streamed Ogg Vorbis Player
 *
 * Purpose:
 *   Streams long-form Ogg Vorbis backing tracks by consuming pre-decoded PCM blocks from sequencer/stream_worker.d over a lock-free SpscRing.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; ZERO disk syscalls or codec allocations on the RT thread (all file/Ogg decode occurs on Background I/O Worker).
 *
 * Dependencies:
 *   Internal: foundation.concurrency, dsp.resampler, sequencer.stream_worker, graph.*
 *   External: None on RT path
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct VorbisPlayer (typeId = "synth.vorbis_player", ports: event in, audioStereo out)
 *   - @Param volume, transposeSemitones, loopEnable
 *   - Hooks: handleEvent (play/seek/stop commands to stream_worker), process, swapAsset
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.vorbis_player;
