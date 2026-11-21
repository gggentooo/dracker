/**
 * File:         source/sequencer/stream_worker.d
 * Module:       sequencer.stream_worker
 * Phase:        Phase 4.9 — Background Disk & Codec Streaming Worker
 *
 * Purpose:
 *   Runs a dedicated non-RT background thread decoding streaming Ogg Vorbis tracks (VorbisPlayer) and async Sampler loads via audio-formats, feeding decoded PCM over lock-free SpscRing buffers.
 *
 * Real-Time & Safety Contract:
 *   Worker thread may allocate/perform file I/O; consumer RT ring interface is strictly @nogc nothrow wait-free.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, foundation.concurrency, io.audio_io
 *   External: core.thread
 *
 * Planned API (Types, Functions & Hooks):
 *   - class StreamWorker : openVorbisStream(...), requestSeek(...), requestStop(), enqueueSampleDecode(...)
 *   - struct StreamAudioRing : @nogc SpscRing!float block consumer for VorbisPlayer.process()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.stream_worker;
