/**
 * File:         source/io/audio_io.d
 * Module:       io.audio_io
 * Phase:        Phase 0.5 — Pure-D Audio Codec Wrapper (audio-formats)
 *
 * Purpose:
 *   Wraps Auburn Sounds audio-formats (Boost subconfiguration) to decode WAV, FLAC, MP3, and OGG files into @nogc OwnedBuffer!float PCM and encode WAV exports.
 *
 * Real-Time & Safety Contract:
 *   Off-RT decoding/encoding; writes decoded samples into unscanned OwnedBuffer!float ready for RT handoff.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory
 *   External: audioformats (Auburn Sounds, Boost subconfiguration)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DecodedAudio { OwnedBuffer!float interleavedOrPlanar; uint channels; uint sampleRate; ulong frames; }
 *   - bool decodeAudioFile(string path, out DecodedAudio audio, out string err)
 *   - bool decodeAudioMemory(const(ubyte)[] bytes, out DecodedAudio audio, out string err)
 *   - bool writeWavFile(string path, const(float)[][] channels, uint sampleRate, out string err)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.audio_io;
