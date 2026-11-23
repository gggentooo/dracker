/**
 * File:         source/io/audio_io.d
 * Module:       io.audio_io
 * Phase:        Phase 0.5 — Pure-D Audio Codec Wrapper (audio-formats + IEEE Float32 WAV Writer)
 *
 * Purpose:
 *   Wraps Auburn Sounds audio-formats (Boost subconfiguration) for decoding WAV, FLAC, MP3, OGG, MOD, and XM buffers into @nogc OwnedBuffer!float PCM, paired with a pure-D IEEE 32-bit float RIFF/WAVE encoder for lossless test and export WAV writing.
 *
 * Real-Time & Safety Contract:
 *   Off-RT decoding/encoding; writes decoded samples into unscanned OwnedBuffer!float ready for RT handoff.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory
 *   External: audioformats (Auburn Sounds, Boost subconfiguration), core.checkedint (mulu), core.lifetime (move), core.stdc.string (memcpy), std.bitmanip (nativeToLittleEndian), std.file (write)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DecodedAudio { OwnedBuffer!float samples; uint channels; uint sampleRate; ulong frames; }
 *   - bool decodeAudioFile(string path, out DecodedAudio audio, out string err)
 *   - bool decodeAudioMemory(const(ubyte)[] bytes, out DecodedAudio audio, out string err)
 *   - bool writeWavFile(string path, const(float)[][] channels, uint sampleRate, out string err)
 *   - bool writeWavInterleaved(string path, const(float)[] interleaved, uint channels, uint sampleRate, out string err)
 *   - bool writeWavMemory(const(float)[][] channels, uint sampleRate, out ubyte[] wavBytes, out string err)
 *   - bool deinterleaveToPlanar(ref const DecodedAudio audio, out OwnedBuffer!float left, out OwnedBuffer!float right) @nogc nothrow
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.audio_io;

import audioformats : AudioStream, audiostreamUnknownLength;
import core.checkedint : mulu;
import core.lifetime : move;
import core.stdc.string : memcpy;
import std.bitmanip : nativeToLittleEndian;
import std.file : fileWrite = write;

import foundation.memory : OwnedBuffer;

private enum ushort WAV_FORMAT_IEEE_FLOAT = 3;
private enum size_t WAV_HEADER_BYTES = 44;
private enum uint WAV_MAX_CHANNELS = 1024;

/**
 * Decoded interleaved floating-point PCM buffer backed by @nogc OwnedBuffer!float.
 *
 * Move-only container safe for off-RT decoding and subsequent lock-free handoff into
 * unregistered real-time audio threads.
 */
struct DecodedAudio {
    OwnedBuffer!float samples;
    uint channels = 0;
    uint sampleRate = 0;
    ulong frames = 0;

    @disable this(this);

    @nogc nothrow:

    /**
     * Moves ownership of decoded PCM data from rhs into this struct.
     *
     * Params:
     *   rhs = Source DecodedAudio whose sample buffer and metadata are transferred.
     *
     * Returns:
     *   Reference to this DecodedAudio.
     */
    ref DecodedAudio opAssign(DecodedAudio rhs) return {
        samples = move(rhs.samples);
        channels = rhs.channels;
        sampleRate = rhs.sampleRate;
        frames = rhs.frames;
        rhs.channels = 0;
        rhs.sampleRate = 0;
        rhs.frames = 0;
        return this;
    }

    /**
     * Reports whether this container holds zero audio frames.
     *
     * Returns:
     *   True if frames == 0, channels == 0, or samples is empty.
     */
    bool empty() const pure @safe {
        return frames == 0 || channels == 0 || samples.empty();
    }

    /**
     * Reads a single sample by frame index and channel index.
     *
     * Params:
     *   frame = Zero-based frame index (< frames).
     *   channel = Zero-based channel index (< channels).
     *
     * Returns:
     *   Normalized floating-point PCM sample.
     */
    float sampleAt(size_t frame, uint channel) const pure {
        assert(frame < frames && channel < channels, "DecodedAudio.sampleAt index out of bounds");
        return samples[frame * channels + channel];
    }
}

private string formatStreamError(ref const AudioStream stream, string fallback) {
    auto msg = stream.errorMessage();
    return msg.length > 0 ? msg.idup : fallback;
}

private bool decodeFromStream(ref AudioStream stream, out DecodedAudio audio, out string err) {
    audio = DecodedAudio.init;
    err = null;

    if (stream.isError()) {
        err = formatStreamError(stream, "Failed to open audio stream");
        return false;
    }

    immutable int chInt = stream.getNumChannels();
    immutable float srFloat = stream.getSamplerate();
    if (chInt <= 0 || srFloat <= 0.0f) {
        err = "Audio stream reported invalid channel count or sample rate";
        return false;
    }

    immutable uint channels = cast(uint) chInt;
    immutable uint sampleRate = cast(uint)(srFloat + 0.5f);
    immutable long reportedFrames = stream.getLengthInFrames();

    if (reportedFrames == 0) {
        audio.channels = channels;
        audio.sampleRate = sampleRate;
        audio.frames = 0;
        return true;
    }

    if (reportedFrames > 0 && reportedFrames != audiostreamUnknownLength) {
        immutable size_t expectedFrames = cast(size_t) reportedFrames;
        bool overflow = false;
        immutable size_t expectedSamples = mulu(expectedFrames, channels, overflow);
        if (overflow) {
            err = "Decoded audio size overflows addressable memory";
            return false;
        }

        OwnedBuffer!float dst;
        if (!OwnedBuffer!float.tryAllocate(expectedSamples, dst)) {
            err = "Out of memory allocating decoded audio buffer";
            return false;
        }

        size_t framesReadTotal = 0;
        enum size_t chunkFrames = 4096;
        while (framesReadTotal < expectedFrames) {
            immutable size_t remaining = expectedFrames - framesReadTotal;
            immutable int want = cast(int)(remaining < chunkFrames ? remaining : chunkFrames);
            float* writePtr = dst.ptr + framesReadTotal * channels;
            immutable int got = stream.readSamplesFloat(writePtr, want);
            if (stream.isError()) {
                err = formatStreamError(stream, "Audio decoding failed");
                return false;
            }
            if (got <= 0) {
                break;
            }
            framesReadTotal += cast(size_t) got;
        }

        if (framesReadTotal < expectedFrames) {
            OwnedBuffer!float trimmed;
            immutable size_t actualSamples = framesReadTotal * channels;
            if (!OwnedBuffer!float.tryAllocate(actualSamples, trimmed)) {
                err = "Out of memory trimming decoded audio buffer";
                return false;
            }
            if (actualSamples > 0) {
                memcpy(trimmed.ptr, dst.ptr, actualSamples * float.sizeof);
            }
            dst = move(trimmed);
        }

        audio.samples = move(dst);
        audio.channels = channels;
        audio.sampleRate = sampleRate;
        audio.frames = framesReadTotal;
        return true;
    }

    enum size_t streamChunkFrames = 4096;
    auto chunkBuf = new float[streamChunkFrames * channels];
    float[] accum;
    size_t totalFrames = 0;

    while (true) {
        immutable int got = stream.readSamplesFloat(chunkBuf.ptr, cast(int) streamChunkFrames);
        if (stream.isError()) {
            err = formatStreamError(stream, "Streaming audio decoding failed");
            return false;
        }
        if (got <= 0) {
            break;
        }
        immutable size_t gotSamples = cast(size_t) got * channels;
        accum ~= chunkBuf[0 .. gotSamples];
        totalFrames += cast(size_t) got;
    }

    OwnedBuffer!float dst;
    if (!OwnedBuffer!float.tryAllocate(accum.length, dst)) {
        err = "Out of memory allocating streamed audio buffer";
        return false;
    }
    if (accum.length > 0) {
        memcpy(dst.ptr, accum.ptr, accum.length * float.sizeof);
    }

    audio.samples = move(dst);
    audio.channels = channels;
    audio.sampleRate = sampleRate;
    audio.frames = totalFrames;
    return true;
}

/**
 * Decodes an audio file (WAV, FLAC, MP3, OGG, MOD, or XM) into an @nogc OwnedBuffer!float.
 *
 * Params:
 *   path = UTF-8 filesystem path to the audio file.
 *   audio = Destination DecodedAudio populated on success.
 *   err = Human-readable error message populated on failure.
 *
 * Returns:
 *   True if decoding succeeded; false otherwise.
 */
bool decodeAudioFile(string path, out DecodedAudio audio, out string err) {
    audio = DecodedAudio.init;
    err = null;
    if (path.length == 0) {
        err = "Audio file path cannot be empty";
        return false;
    }
    AudioStream stream;
    stream.openFromFile(path);
    return decodeFromStream(stream, audio, err);
}

/**
 * Decodes an in-memory encoded audio file payload into an @nogc OwnedBuffer!float.
 *
 * Params:
 *   bytes = Complete encoded file contents in memory.
 *   audio = Destination DecodedAudio populated on success.
 *   err = Human-readable error message populated on failure.
 *
 * Returns:
 *   True if decoding succeeded; false otherwise.
 */
bool decodeAudioMemory(const(ubyte)[] bytes, out DecodedAudio audio, out string err) {
    audio = DecodedAudio.init;
    err = null;
    if (bytes.length == 0) {
        err = "Encoded audio buffer cannot be empty";
        return false;
    }
    AudioStream stream;
    stream.openFromMemory(bytes);
    return decodeFromStream(stream, audio, err);
}

private bool interleaveChannels(
    const(float)[][] channels,
    out OwnedBuffer!float interleaved,
    out size_t frameCount,
    out string err
) {
    interleaved = OwnedBuffer!float.init;
    frameCount = 0;
    err = null;

    if (channels.length == 0) {
        err = "At least one audio channel is required";
        return false;
    }

    frameCount = channels[0].length;
    foreach (chIdx; 1 .. channels.length) {
        if (channels[chIdx].length != frameCount) {
            err = "All audio channels must have equal frame lengths";
            return false;
        }
    }

    bool overflow = false;
    immutable size_t totalSamples = mulu(frameCount, channels.length, overflow);
    if (overflow) {
        err = "Interleaved audio length overflows addressable memory";
        return false;
    }

    if (!OwnedBuffer!float.tryAllocate(totalSamples, interleaved)) {
        err = "Out of memory allocating interleaved WAV staging buffer";
        return false;
    }

    immutable size_t numCh = channels.length;
    float* dst = interleaved.ptr;
    foreach (f; 0 .. frameCount) {
        immutable size_t base = f * numCh;
        foreach (c; 0 .. numCh) {
            dst[base + c] = channels[c][f];
        }
    }
    return true;
}

private bool encodeFloat32WavBytes(
    const(float)[] interleaved,
    uint channels,
    uint sampleRate,
    out ubyte[] wavBytes,
    out string err
) {
    wavBytes = null;
    err = null;

    if (channels == 0 || channels > WAV_MAX_CHANNELS || sampleRate == 0) {
        err = "WAV channel count and sample rate must be valid positive values";
        return false;
    }
    if (interleaved.length % channels != 0) {
        err = "Interleaved sample length must be a multiple of channel count";
        return false;
    }

    immutable uint blockAlign = channels * cast(uint) float.sizeof;
    bool rateOverflow = false;
    immutable size_t byteRate = mulu(sampleRate, blockAlign, rateOverflow);
    if (rateOverflow || byteRate > uint.max) {
        err = "WAV byte rate overflows 32-bit RIFF header field";
        return false;
    }

    bool dataOverflow = false;
    immutable size_t dataBytes = mulu(interleaved.length, float.sizeof, dataOverflow);
    if (dataOverflow || dataBytes > uint.max - 36) {
        err = "WAV payload size exceeds 32-bit RIFF container limit";
        return false;
    }

    auto buf = new ubyte[WAV_HEADER_BYTES + dataBytes];
    buf[0 .. 4] = cast(const(ubyte)[]) "RIFF";
    buf[4 .. 8] = nativeToLittleEndian(cast(uint)(36 + dataBytes));
    buf[8 .. 12] = cast(const(ubyte)[]) "WAVE";
    buf[12 .. 16] = cast(const(ubyte)[]) "fmt ";
    buf[16 .. 20] = nativeToLittleEndian(cast(uint) 16);
    buf[20 .. 22] = nativeToLittleEndian(WAV_FORMAT_IEEE_FLOAT);
    buf[22 .. 24] = nativeToLittleEndian(cast(ushort) channels);
    buf[24 .. 28] = nativeToLittleEndian(sampleRate);
    buf[28 .. 32] = nativeToLittleEndian(cast(uint) byteRate);
    buf[32 .. 34] = nativeToLittleEndian(cast(ushort) blockAlign);
    buf[34 .. 36] = nativeToLittleEndian(cast(ushort) 32);
    buf[36 .. 40] = cast(const(ubyte)[]) "data";
    buf[40 .. 44] = nativeToLittleEndian(cast(uint) dataBytes);

    if (dataBytes > 0) {
        version (LittleEndian) {
            memcpy(buf.ptr + WAV_HEADER_BYTES, interleaved.ptr, dataBytes);
        } else {
            foreach (i, sample; interleaved) {
                immutable size_t off = WAV_HEADER_BYTES + i * float.sizeof;
                buf[off .. off + float.sizeof] = nativeToLittleEndian(sample);
            }
        }
    }

    wavBytes = buf;
    return true;
}

/**
 * Encodes planar channel slices as an IEEE 32-bit float WAV file on disk.
 *
 * Params:
 *   path = Destination UTF-8 file path.
 *   channels = Non-empty array of equal-length per-channel float slices.
 *   sampleRate = Sample rate in Hertz (> 0).
 *   err = Human-readable error message populated on failure.
 *
 * Returns:
 *   True if the WAV file was written cleanly; false otherwise.
 */
bool writeWavFile(string path, const(float)[][] channels, uint sampleRate, out string err) {
    err = null;
    if (path.length == 0) {
        err = "Destination WAV path cannot be empty";
        return false;
    }
    if (sampleRate == 0) {
        err = "WAV sample rate must be positive";
        return false;
    }

    OwnedBuffer!float interleaved;
    size_t frameCount = 0;
    if (!interleaveChannels(channels, interleaved, frameCount, err)) {
        return false;
    }
    return writeWavInterleaved(path, interleaved[], cast(uint) channels.length, sampleRate, err);
}

/**
 * Encodes an interleaved float sample slice as an IEEE 32-bit float WAV file on disk.
 *
 * Params:
 *   path = Destination UTF-8 file path.
 *   interleaved = Interleaved samples whose length is a multiple of channels.
 *   channels = Channel count (> 0).
 *   sampleRate = Sample rate in Hertz (> 0).
 *   err = Human-readable error message populated on failure.
 *
 * Returns:
 *   True if the WAV file was written cleanly; false otherwise.
 */
bool writeWavInterleaved(
    string path,
    const(float)[] interleaved,
    uint channels,
    uint sampleRate,
    out string err
) {
    err = null;
    if (path.length == 0) {
        err = "Destination WAV path cannot be empty";
        return false;
    }

    ubyte[] wavBytes;
    if (!encodeFloat32WavBytes(interleaved, channels, sampleRate, wavBytes, err)) {
        return false;
    }

    try {
        fileWrite(path, wavBytes);
    } catch (Exception e) {
        err = e.msg.length > 0 ? e.msg : "Failed writing WAV file to disk";
        return false;
    }
    return true;
}

/**
 * Encodes planar channel slices into an in-memory IEEE 32-bit float WAV byte array.
 *
 * Params:
 *   channels = Non-empty array of equal-length per-channel float slices.
 *   sampleRate = Sample rate in Hertz (> 0).
 *   wavBytes = Output byte array containing the complete RIFF/WAVE payload.
 *   err = Human-readable error message populated on failure.
 *
 * Returns:
 *   True if encoding succeeded; false otherwise.
 */
bool writeWavMemory(const(float)[][] channels, uint sampleRate, out ubyte[] wavBytes, out string err) {
    wavBytes = null;
    err = null;
    if (sampleRate == 0) {
        err = "WAV sample rate must be positive";
        return false;
    }

    OwnedBuffer!float interleaved;
    size_t frameCount = 0;
    if (!interleaveChannels(channels, interleaved, frameCount, err)) {
        return false;
    }
    return encodeFloat32WavBytes(interleaved[], cast(uint) channels.length, sampleRate, wavBytes, err);
}

/**
 * Splits interleaved decoded PCM into left and right planar @nogc OwnedBuffer!float buffers.
 *
 * Mono sources duplicate channel 0 into both left and right buffers; multi-channel sources
 * extract channels 0 and 1.
 *
 * Params:
 *   audio = Source decoded interleaved audio.
 *   left = Destination buffer for left channel samples.
 *   right = Destination buffer for right channel samples.
 *
 * Returns:
 *   True if planar buffers were allocated and populated; false if audio is empty or on OOM.
 */
bool deinterleaveToPlanar(
    ref const DecodedAudio audio,
    out OwnedBuffer!float left,
    out OwnedBuffer!float right
) @nogc nothrow {
    left = OwnedBuffer!float.init;
    right = OwnedBuffer!float.init;
    if (audio.empty()) {
        return false;
    }

    immutable size_t frameCount = cast(size_t) audio.frames;
    if (!OwnedBuffer!float.tryAllocate(frameCount, left)) {
        return false;
    }
    if (!OwnedBuffer!float.tryAllocate(frameCount, right)) {
        left.reset();
        return false;
    }

    const(float)* src = audio.samples.ptr;
    float* dstL = left.ptr;
    float* dstR = right.ptr;
    immutable uint ch = audio.channels;
    if (ch == 1) {
        foreach (i; 0 .. frameCount) {
            immutable float s = src[i];
            dstL[i] = s;
            dstR[i] = s;
        }
    } else {
        foreach (i; 0 .. frameCount) {
            immutable size_t base = i * ch;
            dstL[i] = src[base];
            dstR[i] = src[base + 1];
        }
    }
    return true;
}
