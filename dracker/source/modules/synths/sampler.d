/**
 * File:         source/modules/synths/sampler.d
 * Module:       modules.synths.sampler
 * Phase:        Phase 4.4 (Tier 1) — Multi-Slot Polyphonic Sampler
 *
 * Purpose:
 *   Plays multi-slot mono/stereo PCM samples via VoicePool with nearest/linear/Catmull-Rom interpolation, one-shot/forward/ping-pong looping, multi-breakpoint volume/pan/pitch envelopes, off-RT codec decoding via io.audio_io, and lock-free SwapModuleAsset switching. samplerExtraWithSample() loads a file's bytes into one slot and builds the module's stored extra data without a session, sanitizing non-finite samples (T75), so StudioSession.doLoadSample and compose.module_writer store byte-identical data.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on RT process(), handleEvent(), and swapAsset(); OwnedBuffer!float sample assets decode off-RT and retire cleanly. samplerExtraWithSample() is off-RT only: it decodes, copies and serializes on the GC heap.
 *
 * Dependencies:
 *   Internal: dsp.envelope, dsp.interp, dsp.voice_pool, foundation.math_rt, foundation.memory, foundation.types, graph.buffer, graph.context, graph.event, graph.module_api, graph.port, io.audio_io
 *   External: core.lifetime, core.stdc.stdlib, core.stdc.string, std.bitmanip, std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct SamplerSlotAsset : createFromPlanar(), createFromAudioFile(), createFromAudioMemory(), destroyErased()
 *   - struct Sampler (typeId = "synth.sampler", ports: event in, audioStereo in/out)
 *   - @Param volume, panning, fineTune, sampleOffset, loopMode, interpQuality
 *   - Hooks: handleEvent, process, swapAsset, serializeExtra, deserializeExtra
 *   - samplerExtraWithSample() : session-free off-RT slot loader shared by StudioSession.doLoadSample and
 *     compose.module_writer
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.sampler;

import core.lifetime : emplace, move;
import core.stdc.stdlib : calloc, free;
import core.stdc.string : memcpy;
import std.bitmanip : littleEndianToNative, nativeToLittleEndian;
import std.math : exp2, fabs, isFinite;

import dsp.envelope : BreakpointEnvelope, EnvBreakpoint;
import dsp.interp : interpLinear, sampleBufferClamped;
import dsp.smoother : ParamSmoother;
import dsp.voice_pool : VoicePool;
import foundation.memory : OwnedBuffer;
import foundation.types : NoteId;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;
import io.audio_io : DecodedAudio, decodeAudioFile, decodeAudioMemory, deinterleaveToPlanar;

/**
 * Unmanaged @nogc sample slot asset owning stereo PCM buffers, loop points, and breakpoint envelopes.
 */
struct SamplerSlotAsset {
    enum size_t MAX_BREAKPOINTS = 8;

    OwnedBuffer!float left;
    OwnedBuffer!float right;
    float sampleRate = 44_100.0f;
    ubyte rootNote = 60;
    ubyte lowNote = 0;
    ubyte highNote = 127;
    size_t loopStart = 0;
    size_t loopEnd = 0;

    EnvBreakpoint[MAX_BREAKPOINTS] volEnv;
    uint volEnvCount = 0;
    int volSustainIdx = -1;

    EnvBreakpoint[MAX_BREAKPOINTS] panEnv;
    uint panEnvCount = 0;
    int panSustainIdx = -1;

    EnvBreakpoint[MAX_BREAKPOINTS] pitchEnv;
    uint pitchEnvCount = 0;
    int pitchSustainIdx = -1;

    @disable this(this);

    @nogc nothrow:

    /**
     * Frees unmanaged left and right sample buffers cleanly.
     */
    ~this() {
        left.reset();
        right.reset();
    }

    /**
     * Allocates a SamplerSlotAsset off-RT by copying planar stereo PCM slices.
     *
     * Params:
     *   srcLeft = Left PCM samples.
     *   srcRight = Right PCM samples (if empty, duplicates srcLeft).
     *   sampleRate = Native recording sample rate in Hertz.
     *   rootNote = Unity-pitch MIDI note number (default 60 = C4).
     *   lowNote = Lowest keymap MIDI note.
     *   highNote = Highest keymap MIDI note.
     *   loopStart = Loop start frame index.
     *   loopEnd = Exclusive loop end frame index.
     *
     * Returns:
     *   Allocated SamplerSlotAsset*, or null on invalid inputs or OOM.
     */
    static SamplerSlotAsset* createFromPlanar(
        const(float)[] srcLeft,
        const(float)[] srcRight = null,
        float sampleRate = 44_100.0f,
        ubyte rootNote = 60,
        ubyte lowNote = 0,
        ubyte highNote = 127,
        size_t loopStart = 0,
        size_t loopEnd = 0
    ) {
        if (srcLeft.length == 0) {
            return null;
        }
        OwnedBuffer!float bufL;
        OwnedBuffer!float bufR;
        if (!OwnedBuffer!float.tryAllocate(srcLeft.length, bufL)
                || !OwnedBuffer!float.tryAllocate(srcLeft.length, bufR)) {
            return null;
        }
        foreach (i; 0 .. srcLeft.length) {
            bufL[i] = isFinite(srcLeft[i]) ? srcLeft[i] : 0.0f;
            immutable float rSample = (i < srcRight.length) ? srcRight[i] : bufL[i];
            bufR[i] = isFinite(rSample) ? rSample : 0.0f;
        }

        auto ptr = cast(SamplerSlotAsset*) calloc(1, SamplerSlotAsset.sizeof);
        if (ptr is null) {
            return null;
        }
        emplace(ptr);
        ptr.left = move(bufL);
        ptr.right = move(bufR);
        ptr.sampleRate = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        ptr.rootNote = rootNote;
        ptr.lowNote = lowNote;
        ptr.highNote = highNote;
        if (loopEnd > loopStart && loopEnd <= srcLeft.length) {
            ptr.loopStart = loopStart;
            ptr.loopEnd = loopEnd;
        } else {
            ptr.loopStart = 0;
            ptr.loopEnd = srcLeft.length;
        }
        return ptr;
    }

    /**
     * Type-erased destructor freeing a SamplerSlotAsset off the real-time thread.
     *
     * Params:
     *   raw = Opaque SamplerSlotAsset* pointer.
     */
    static void destroyErased(void* raw) {
        if (raw !is null) {
            auto typed = cast(SamplerSlotAsset*) raw;
            destroy!false(*typed);
            free(raw);
        }
    }
}

/**
 * Off-RT helper decoding an audio file on disk (WAV/FLAC/MP3/OGG) into a SamplerSlotAsset*.
 *
 * Params:
 *   path = UTF-8 path to audio file.
 *   err = Populated with descriptive error message on failure.
 *   rootNote = Keymap unity root note.
 *
 * Returns:
 *   Allocated SamplerSlotAsset* on success, or null on decode/OOM error.
 */
SamplerSlotAsset* createSamplerAssetFromFile(string path, out string err, ubyte rootNote = 60) {
    DecodedAudio decoded;
    if (!decodeAudioFile(path, decoded, err)) {
        return null;
    }
    OwnedBuffer!float left;
    OwnedBuffer!float right;
    if (!deinterleaveToPlanar(decoded, left, right)) {
        err = "Failed deinterleaving decoded audio";
        return null;
    }
    return allocateAssetFromDecoded(left, right, cast(float) decoded.sampleRate, rootNote, err);
}

/**
 * Off-RT helper decoding an in-memory encoded audio payload into a SamplerSlotAsset*.
 *
 * Params:
 *   bytes = Complete encoded WAV/FLAC/MP3/OGG byte payload.
 *   err = Populated with descriptive error message on failure.
 *   rootNote = Keymap unity root note.
 *
 * Returns:
 *   Allocated SamplerSlotAsset* on success, or null on decode/OOM error.
 */
SamplerSlotAsset* createSamplerAssetFromMemory(const(ubyte)[] bytes, out string err, ubyte rootNote = 60) {
    DecodedAudio decoded;
    if (!decodeAudioMemory(bytes, decoded, err)) {
        return null;
    }
    OwnedBuffer!float left;
    OwnedBuffer!float right;
    if (!deinterleaveToPlanar(decoded, left, right)) {
        err = "Failed deinterleaving decoded audio";
        return null;
    }
    return allocateAssetFromDecoded(left, right, cast(float) decoded.sampleRate, rootNote, err);
}

private SamplerSlotAsset* allocateAssetFromDecoded(
    ref OwnedBuffer!float left,
    ref OwnedBuffer!float right,
    float sr,
    ubyte rootNote,
    out string err
) {
    err = null;
    auto ptr = cast(SamplerSlotAsset*) calloc(1, SamplerSlotAsset.sizeof);
    if (ptr is null) {
        err = "Out of memory allocating SamplerSlotAsset";
        return null;
    }
    emplace(ptr);
    ptr.loopStart = 0;
    ptr.loopEnd = left.length;
    ptr.left = move(left);
    ptr.right = move(right);
    ptr.sampleRate = (!isFinite(sr) || sr < 1.0f) ? 44_100.0f : sr;
    ptr.rootNote = rootNote;
    ptr.lowNote = 0;
    ptr.highNote = 127;
    return ptr;
}

/**
 * Single polyphonic sampler voice tracking fractional playhead, loop bounce, and breakpoint envelopes.
 */
struct SamplerVoice {
    private uint slotIndex_ = 0;
    private double playPos_ = 0.0;
    private double noteSemis_ = 60.0;
    private float velocity_ = 1.0f;
    private float releaseGain_ = 1.0f;
    private bool forward_ = true;
    private bool active_ = false;
    private bool releasing_ = false;

    private BreakpointEnvelope volEnv_;
    private BreakpointEnvelope panEnv_;
    private BreakpointEnvelope pitchEnv_;

    @nogc nothrow:

    /**
     * Resets playhead position, loop direction, and breakpoint envelopes immediately.
     */
    void reset() {
        slotIndex_ = 0;
        playPos_ = 0.0;
        noteSemis_ = 60.0;
        velocity_ = 1.0f;
        releaseGain_ = 1.0f;
        forward_ = true;
        active_ = false;
        releasing_ = false;
        volEnv_.reset();
        panEnv_.reset();
        pitchEnv_.reset();
    }

    /**
     * Triggers playback on a specific SamplerSlotAsset at midiNote and sampleOffset01.
     *
     * Params:
     *   sampleRate = Graph sample rate in Hertz.
     *   slotIndex = Selected slot index in Sampler.
     *   asset = Sample asset descriptor and PCM buffers.
     *   midiNote = Trigger note pitch in fractional MIDI notes.
     *   vel = Trigger velocity [0..1].
     *   sampleOffset01 = Normalized start position offset [0..1].
     */
    void trigger(
        float sampleRate,
        uint slotIndex,
        const(SamplerSlotAsset)* asset,
        float midiNote,
        float vel,
        float sampleOffset01
    ) {
        reset();
        if (asset is null || asset.left.empty()) {
            return;
        }
        slotIndex_ = slotIndex;
        noteSemis_ = isFinite(midiNote) ? cast(double) midiNote : cast(double) asset.rootNote;
        velocity_ = isFinite(vel) ? (vel < 0.0f ? 0.0f : (vel > 1.0f ? 1.0f : vel)) : 0.8f;

        immutable float off = isFinite(sampleOffset01)
            ? (sampleOffset01 < 0.0f ? 0.0f : (sampleOffset01 > 0.99f ? 0.99f : sampleOffset01)) : 0.0f;
        playPos_ = cast(double) off * cast(double)(asset.left.length - 1);
        forward_ = true;
        active_ = true;

        volEnv_.prepare(sampleRate);
        panEnv_.prepare(sampleRate);
        pitchEnv_.prepare(sampleRate);
        if (asset.volEnvCount > 0) {
            volEnv_.trigger(asset.volEnv[0 .. asset.volEnvCount], asset.volSustainIdx);
        }
        if (asset.panEnvCount > 0) {
            panEnv_.trigger(asset.panEnv[0 .. asset.panEnvCount], asset.panSustainIdx);
        }
        if (asset.pitchEnvCount > 0) {
            pitchEnv_.trigger(asset.pitchEnv[0 .. asset.pitchEnvCount], asset.pitchSustainIdx);
        }
    }

    /**
     * Initiates sample/envelope release cleanly.
     */
    void releaseNote() {
        releasing_ = true;
        volEnv_.releaseNote();
        panEnv_.releaseNote();
        pitchEnv_.releaseNote();
    }

    /**
     * Checks whether the voice continues producing audio.
     *
     * Returns:
     *   True while playback remains active.
     */
    bool isActive() const pure @safe {
        return active_;
    }

    /**
     * Reports whether release damping has begun.
     *
     * Returns:
     *   True when releasing.
     */
    bool isReleasing() const pure @safe {
        return releasing_;
    }

    /**
     * Returns current amplitude estimate for VoicePool stealing prioritization.
     *
     * Returns:
     *   Estimated sample amplitude.
     */
    float currentLevel() const pure @safe {
        return releaseGain_ * velocity_;
    }

    /**
     * Renders interpolated stereo sample output with loop bounce and envelopes into outL/outR.
     *
     * Params:
     *   outL = Destination left accumulation buffer.
     *   outR = Destination right accumulation buffer.
     *   frames = Frame count for this slice.
     *   asset = Slot asset referenced by this voice.
     *   sampleRate = Active graph sample rate in Hertz.
     *   fineTune = Pitch offset in semitones [-1..1].
     *   bendSemis = Channel pitch bend in semitones.
     *   panParam = Global sampler pan [-1..1].
     *   loopMode = Loop topology (0=oneShot, 1=forward, 2=pingPong).
     *   interpQuality = Interpolation quality (0=nearest, 1=linear, 2=catmullRom).
     */
    void renderAdd(
        float[] outL,
        float[] outR,
        uint frames,
        const(SamplerSlotAsset)* asset,
        float sampleRate,
        float fineTune,
        float bendSemis,
        float panParam,
        int loopMode,
        int interpQuality
    ) {
        if (!active_ || asset is null || asset.left.empty()) {
            active_ = false;
            return;
        }

        const(float)[] bufL = asset.left[];
        const(float)[] bufR = asset.right.empty() ? asset.left[] : asset.right[];
        immutable double len = cast(double) bufL.length;
        immutable double srRatio = cast(double) asset.sampleRate / cast(double)(sampleRate > 1.0f ? sampleRate : 44_100.0f);
        immutable double lStart = cast(double) asset.loopStart;
        immutable double lEnd = cast(double)(asset.loopEnd > asset.loopStart && asset.loopEnd <= bufL.length
            ? asset.loopEnd : bufL.length);
        immutable double lSpan = lEnd - lStart;
        immutable double releaseStep = 1.0 / (0.015 * cast(double)(sampleRate > 1.0f ? sampleRate : 44_100.0f));

        foreach (i; 0 .. frames) {
            float envVol = 1.0f;
            if (asset.volEnvCount > 0) {
                envVol = volEnv_.next(asset.volEnv[0 .. asset.volEnvCount]);
                if (!volEnv_.isActive()) {
                    active_ = false;
                    break;
                }
            } else if (releasing_) {
                releaseGain_ -= cast(float) releaseStep;
                if (releaseGain_ <= 0.0f) {
                    releaseGain_ = 0.0f;
                    active_ = false;
                    break;
                }
                envVol = releaseGain_;
            }

            float envPan = 0.0f;
            if (asset.panEnvCount > 0) {
                envPan = panEnv_.next(asset.panEnv[0 .. asset.panEnvCount]);
            }
            float envPitch = 0.0f;
            if (asset.pitchEnvCount > 0) {
                envPitch = pitchEnv_.next(asset.pitchEnv[0 .. asset.pitchEnvCount]);
            }

            immutable float sL = evalInterpolated(bufL, playPos_, interpQuality);
            immutable float sR = evalInterpolated(bufR, playPos_, interpQuality);

            float p = panParam + envPan;
            if (p < -1.0f) p = -1.0f;
            if (p > 1.0f) p = 1.0f;
            immutable float gainL = 0.5f * (1.0f - p) + (p <= 0.0f ? 0.5f : 0.5f * (1.0f - p));
            immutable float panL = 1.0f - (p > 0.0f ? p : 0.0f);
            immutable float panR = 1.0f + (p < 0.0f ? p : 0.0f);
            cast(void) gainL;

            immutable float amp = envVol * velocity_;
            outL[i] += sL * panL * amp;
            outR[i] += sR * panR * amp;

            immutable double semis = (noteSemis_ - cast(double) asset.rootNote)
                + cast(double) fineTune + cast(double) bendSemis + cast(double) envPitch * 12.0;
            immutable double step = srRatio * exp2(semis / 12.0);

            if (forward_) {
                playPos_ += step;
            } else {
                playPos_ -= step;
            }

            if (loopMode == 1 && lSpan >= 1.0 && playPos_ >= lEnd) {
                playPos_ = lStart + (playPos_ - lEnd) - cast(long)((playPos_ - lEnd) / lSpan) * lSpan;
            } else if (loopMode == 2 && lSpan >= 1.0) {
                if (forward_ && playPos_ >= lEnd) {
                    playPos_ = lEnd - (playPos_ - lEnd);
                    if (playPos_ < lStart) playPos_ = lStart;
                    forward_ = false;
                } else if (!forward_ && playPos_ <= lStart) {
                    playPos_ = lStart + (lStart - playPos_);
                    if (playPos_ >= lEnd) playPos_ = lEnd - 1.0;
                    forward_ = true;
                }
            } else if (playPos_ >= len || playPos_ < 0.0) {
                active_ = false;
                break;
            }
        }
    }

    private static float evalInterpolated(const(float)[] buf, double pos, int quality) @nogc nothrow pure @safe {
        if (buf.length == 0) {
            return 0.0f;
        }
        if (quality == 0) {
            ptrdiff_t idx = cast(ptrdiff_t)(pos + 0.5);
            if (idx < 0) idx = 0;
            if (idx >= cast(ptrdiff_t) buf.length) idx = cast(ptrdiff_t) buf.length - 1;
            return buf[idx];
        }
        return sampleBufferClamped(buf, pos, quality >= 2);
    }
}

/**
 * 16-slot polyphonic stereo sampler with interpolation selection, loops, envelopes, and off-RT asset swaps.
 */
struct Sampler {
    enum string typeId = "synth.sampler";
    enum string displayName = "Sampler";
    enum ModuleCategory category = ModuleCategory.synth;
    enum size_t MAX_SLOTS = 16;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("events", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("in", "Audio Thru", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Volume", 0.0f, 2.0f, 0.8f, "", ParamScale.linear)
    float volume = 0.8f;

    @Param("Panning", -1.0f, 1.0f, 0.0f, "", ParamScale.linear)
    float panning = 0.0f;

    @Param("Fine Tune", -1.0f, 1.0f, 0.0f, "st", ParamScale.linear)
    float fineTune = 0.0f;

    @Param("Offset", 0.0f, 1.0f, 0.0f, "", ParamScale.linear)
    float sampleOffset = 0.0f;

    @Param("Loop Mode", 0.0f, 2.0f, 0.0f, "", ParamScale.discrete,
        ["One-Shot", "Forward", "Ping-Pong"])
    float loopMode = 0.0f;

    @Param("Quality", 0.0f, 2.0f, 2.0f, "", ParamScale.discrete,
        ["Nearest", "Linear", "Cubic"])
    float interpQuality = 2.0f;

    private SamplerSlotAsset*[MAX_SLOTS] slots_ = null;
    private VoicePool!(SamplerVoice, 16) voices_;
    private ParamSmoother volSmoother_;
    private float sampleRate_ = 44_100.0f;
    private float pitchBendSemis_ = 0.0f;

    /**
     * Serializes all occupied sample slots, keymaps, loops, and envelopes off-RT.
     *
     * Params:
     *   payload = Serialized binary payload containing all active SamplerSlotAssets.
     *
     * Returns:
     *   True on success.
     */
    bool serializeExtra(out ubyte[] payload) const {
        uint activeCount = 0;
        foreach (idx; 0 .. MAX_SLOTS) {
            if (slots_[idx] !is null) {
                activeCount++;
            }
        }
        if (activeCount == 0) {
            payload = null;
            return true;
        }

        ubyte[] buf;
        void appendVal(T)(T v) {
            buf ~= nativeToLittleEndian(v)[];
        }

        appendVal!uint(0x534D_5031u);
        appendVal!uint(activeCount);
        foreach (idx; 0 .. MAX_SLOTS) {
            auto s = slots_[idx];
            if (s is null) {
                continue;
            }
            appendVal!uint(cast(uint) idx);
            appendVal!float(s.sampleRate);
            buf ~= s.rootNote;
            buf ~= s.lowNote;
            buf ~= s.highNote;
            buf ~= 0;
            appendVal!ulong(cast(ulong) s.loopStart);
            appendVal!ulong(cast(ulong) s.loopEnd);
            appendVal!uint(s.volEnvCount);
            appendVal!int(s.volSustainIdx);
            appendVal!uint(s.panEnvCount);
            appendVal!int(s.panSustainIdx);
            appendVal!uint(s.pitchEnvCount);
            appendVal!int(s.pitchSustainIdx);
            foreach (k; 0 .. s.volEnvCount) {
                appendVal!float(s.volEnv[k].timeSec);
                appendVal!float(s.volEnv[k].value);
                appendVal!float(s.volEnv[k].curve);
            }
            foreach (k; 0 .. s.panEnvCount) {
                appendVal!float(s.panEnv[k].timeSec);
                appendVal!float(s.panEnv[k].value);
                appendVal!float(s.panEnv[k].curve);
            }
            foreach (k; 0 .. s.pitchEnvCount) {
                appendVal!float(s.pitchEnv[k].timeSec);
                appendVal!float(s.pitchEnv[k].value);
                appendVal!float(s.pitchEnv[k].curve);
            }
            appendVal!ulong(cast(ulong) s.left.length);
            foreach (i; 0 .. s.left.length) {
                appendVal!float(s.left[i]);
                appendVal!float(i < s.right.length ? s.right[i] : s.left[i]);
            }
        }
        payload = buf;
        return true;
    }

    enum uint ASSET_SLOT_COUNT = MAX_SLOTS;

    /**
     * Returns the asset in a slot (off-RT inspection of non-live states only, e.g. waveform previews).
     *
     * Params:
     *   slot = Slot index.
     *
     * Returns:
     *   Asset or null.
     */
    const(SamplerSlotAsset)* slotAsset(uint slot) const @nogc nothrow {
        return slot < MAX_SLOTS ? slots_[slot] : null;
    }

    /**
     * Returns the destructor for the asset type held in slot (used by live asset replacement).
     *
     * Params:
     *   slot = Asset slot index.
     *
     * Returns:
     *   Type-erased destructor.
     */
    static void function(void*) @nogc nothrow assetDestroyFn(uint slot) @nogc nothrow pure @safe {
        cast(void) slot;
        return &SamplerSlotAsset.destroyErased;
    }

    /**
     * Deserializes saved sample slots cleanly off the real-time thread.
     *
     * Params:
     *   payload = Binary payload previously emitted by serializeExtra().
     *   sampleRate = Active graph sample rate in Hertz.
     *
     * Returns:
     *   True if empty or restored validly; false on corrupt header or truncation.
     */
    bool deserializeExtra(const(ubyte)[] payload, float sampleRate) {
        cast(void) sampleRate;
        if (payload.length == 0) {
            return true;
        }
        size_t pos = 0;
        bool readVal(T)(out T val) {
            if (pos + T.sizeof > payload.length) {
                return false;
            }
            ubyte[T.sizeof] raw = payload[pos .. pos + T.sizeof];
            val = littleEndianToNative!T(raw);
            pos += T.sizeof;
            return true;
        }

        uint magic = 0;
        uint count = 0;
        if (!readVal(magic) || magic != 0x534D_5031u || !readVal(count) || count > MAX_SLOTS) {
            return false;
        }

        foreach (_; 0 .. count) {
            uint slotIdx = 0;
            float sr = 44_100.0f;
            ubyte rootN = 60, lowN = 0, highN = 127, pad = 0;
            ulong lStart = 0, lEnd = 0;
            uint vCnt = 0, paCnt = 0, piCnt = 0;
            int vSus = -1, paSus = -1, piSus = -1;
            if (!readVal(slotIdx) || slotIdx >= MAX_SLOTS || !readVal(sr)
                    || !readVal(rootN) || !readVal(lowN) || !readVal(highN) || !readVal(pad)
                    || !readVal(lStart) || !readVal(lEnd)
                    || !readVal(vCnt) || !readVal(vSus)
                    || !readVal(paCnt) || !readVal(paSus)
                    || !readVal(piCnt) || !readVal(piSus)) {
                return false;
            }
            if (vCnt > SamplerSlotAsset.MAX_BREAKPOINTS
                    || paCnt > SamplerSlotAsset.MAX_BREAKPOINTS
                    || piCnt > SamplerSlotAsset.MAX_BREAKPOINTS) {
                return false;
            }

            EnvBreakpoint[SamplerSlotAsset.MAX_BREAKPOINTS] vEnv, paEnv, piEnv;
            foreach (k; 0 .. vCnt) {
                if (!readVal(vEnv[k].timeSec) || !readVal(vEnv[k].value) || !readVal(vEnv[k].curve)) return false;
            }
            foreach (k; 0 .. paCnt) {
                if (!readVal(paEnv[k].timeSec) || !readVal(paEnv[k].value) || !readVal(paEnv[k].curve)) return false;
            }
            foreach (k; 0 .. piCnt) {
                if (!readVal(piEnv[k].timeSec) || !readVal(piEnv[k].value) || !readVal(piEnv[k].curve)) return false;
            }

            ulong framesCount = 0;
            if (!readVal(framesCount) || framesCount == 0 || framesCount > 100_000_000uL) {
                return false;
            }
            auto tmpL = new float[cast(size_t) framesCount];
            auto tmpR = new float[cast(size_t) framesCount];
            foreach (i; 0 .. cast(size_t) framesCount) {
                if (!readVal(tmpL[i]) || !readVal(tmpR[i])) {
                    return false;
                }
            }

            SamplerSlotAsset* asset = SamplerSlotAsset.createFromPlanar(
                tmpL,
                tmpR,
                sr,
                rootN,
                lowN,
                highN,
                cast(size_t) lStart,
                cast(size_t) lEnd
            );
            if (asset is null) {
                return false;
            }
            asset.volEnvCount = vCnt;
            asset.volSustainIdx = vSus;
            asset.volEnv = vEnv;
            asset.panEnvCount = paCnt;
            asset.panSustainIdx = paSus;
            asset.panEnv = paEnv;
            asset.pitchEnvCount = piCnt;
            asset.pitchSustainIdx = piSus;
            asset.pitchEnv = piEnv;

            void* prev = null;
            swapAsset(slotIdx, asset, prev);
            if (prev !is null) {
                SamplerSlotAsset.destroyErased(prev);
            }
        }
        return true;
    }

    @nogc nothrow:

    /**
     * Destroys all owned sample slot assets off-RT when the Sampler instance is destroyed.
     */
    ~this() {
        foreach (idx; 0 .. MAX_SLOTS) {
            if (slots_[idx] !is null) {
                SamplerSlotAsset.destroyErased(slots_[idx]);
                slots_[idx] = null;
            }
        }
    }

    /**
     * Initializes output volume smoother and clears active sampler voices.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        volSmoother_.prepare(sampleRate_, 5.0f, volume);
        reset();
    }

    /**
     * Stops all active sample voices and resets volume smoother and pitch bend.
     */
    void reset() {
        voices_.resetAll();
        pitchBendSemis_ = 0.0f;
        volSmoother_.reset(volume);
    }

    /**
     * Updates smoothed output volume on parameter edits.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap immediately.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "volume") {
            volSmoother_.setTarget(volume, instant);
        }
    }

    /**
     * Triggers mapped sample slots on NoteOn or releases active voices on NoteOff/AllNotesOff.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        switch (ev.kind) {
            case ModEventKind.noteOn: {
                immutable float midiNote = isFinite(ev.valueA) ? ev.valueA : 60.0f;
                immutable uint slotIdx = selectSlotForNote(midiNote);
                if (slotIdx < MAX_SLOTS && slots_[slotIdx] !is null) {
                    bool stolen = false;
                    SamplerVoice* v = voices_.allocateVoice(ev.noteId, stolen);
                    if (v !is null) {
                        v.trigger(sampleRate_, slotIdx, slots_[slotIdx], midiNote, ev.valueB, sampleOffset);
                    }
                }
                break;
            }

            case ModEventKind.noteOff:
                voices_.releaseVoice(ev.noteId);
                break;

            case ModEventKind.allNotesOff:
                voices_.allNotesOff();
                break;

            case ModEventKind.setPitch:
                if (!ev.noteId.isValid()) {
                    pitchBendSemis_ = isFinite(ev.valueA) ? ev.valueA : 0.0f;
                } else {
                    SamplerVoice* v = voices_.findVoice(ev.noteId);
                    if (v !is null && isFinite(ev.valueA)) {
                        v.noteSemis_ = ev.valueA;
                    }
                }
                break;

            default:
                break;
        }
    }

    /**
     * Renders active sample voices mixed with optional audio passthrough into audioOut.
     *
     * Params:
     *   io = Bundle holding optional input passthrough and stereo output slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while voices or input audio remain audible.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        voices_.deactivateFinished();
        if (ctx.inputSilent && !voices_.hasActiveVoices()) {
            io.audioOut[0][0 .. ctx.frames] = 0.0f;
            io.audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) volSmoother_.next();
            }
            return false;
        }

        auto outL = io.audioOut[0];
        auto outR = io.audioOut[1];
        if (ctx.inputSilent) {
            outL[0 .. ctx.frames] = 0.0f;
            outR[0 .. ctx.frames] = 0.0f;
        } else {
            foreach (i; 0 .. ctx.frames) {
                outL[i] = isFinite(io.audioIn[0][i]) ? io.audioIn[0][i] : 0.0f;
                outR[i] = isFinite(io.audioIn[1][i]) ? io.audioIn[1][i] : 0.0f;
            }
        }

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable uint frames = ctx.frames;
        immutable float ft = isFinite(fineTune) ? fineTune : 0.0f;
        immutable float bend = pitchBendSemis_;
        immutable float pan = isFinite(panning) ? panning : 0.0f;
        immutable int lm = isFinite(loopMode) ? cast(int)(loopMode + 0.5f) : 0;
        immutable int iq = isFinite(interpQuality) ? cast(int)(interpQuality + 0.5f) : 2;

        voices_.forEachActive((ref SamplerVoice v, NoteId id) @nogc nothrow {
            cast(void) id;
            if (v.slotIndex_ < MAX_SLOTS && slots_[v.slotIndex_] !is null) {
                v.renderAdd(outL, outR, frames, slots_[v.slotIndex_], sr, ft, bend, pan, lm, iq);
            } else {
                v.active_ = false;
            }
        });

        float peak = 0.0f;
        foreach (i; 0 .. frames) {
            immutable float gain = volSmoother_.next();
            immutable float yL = outL[i] * gain;
            immutable float yR = outR[i] * gain;
            outL[i] = yL;
            outR[i] = yR;
            immutable float al = fabs(yL);
            immutable float ar = fabs(yR);
            if (al > peak) peak = al;
            if (ar > peak) peak = ar;
        }

        return peak > 1e-7f || voices_.hasActiveVoices();
    }

    /**
     * Atomically replaces the SamplerSlotAsset* at slot [0..MAX_SLOTS) and returns the displaced pointer.
     *
     * Any currently active voice referencing the replaced slot is reset safely so dangling
     * pointers never occur during RetireSink reclamation.
     *
     * Params:
     *   slot = Target slot index in [0..MAX_SLOTS).
     *   newAsset = Replacement SamplerSlotAsset* (or null to clear slot).
     *   oldAsset = Receives the previous SamplerSlotAsset* for off-RT cleanup.
     *
     * Returns:
     *   True if slot < MAX_SLOTS; false otherwise.
     */
    bool swapAsset(uint slot, void* newAsset, out void* oldAsset) {
        oldAsset = null;
        if (slot >= MAX_SLOTS) {
            return false;
        }
        oldAsset = slots_[slot];
        slots_[slot] = cast(SamplerSlotAsset*) newAsset;
        voices_.forEachActive((ref SamplerVoice v, NoteId id) @nogc nothrow {
            cast(void) id;
            if (v.slotIndex_ == slot) {
                v.reset();
            }
        });
        return true;
    }

    private uint selectSlotForNote(float midiNote) const pure @safe {
        immutable int noteInt = cast(int)(midiNote + 0.5f);
        foreach (idx; 0 .. MAX_SLOTS) {
            auto s = slots_[idx];
            if (s !is null && noteInt >= s.lowNote && noteInt <= s.highNote) {
                return cast(uint) idx;
            }
        }
        foreach (idx; 0 .. MAX_SLOTS) {
            if (slots_[idx] !is null) {
                return cast(uint) idx;
            }
        }
        return uint.max;
    }
}

/**
 * Builds the extra data a Sampler module stores after loading an audio file into one slot, without a session:
 * decodes the audio, sets the root note and key range, sanitizes non-finite samples to zero, merges the slot
 * into the module's existing extra data and serializes the result. Used by StudioSession.doLoadSample and by
 * compose.module_writer so both store byte-identical data.
 *
 * Params:
 *   currentExtra = The extra data the module stores now (empty for a fresh module).
 *   slot = Target slot index in [0..Sampler.MAX_SLOTS).
 *   audioBytes = Complete encoded WAV/FLAC/MP3/OGG byte payload.
 *   rootNote = Keymap unity root note (0..127).
 *   lowNote = Lowest mapped note (0..127, never above highNote).
 *   highNote = Highest mapped note (0..127).
 *   blob = Receives the serialized extra data on success; reset when the call starts.
 *   err = Receives the reason on failure; reset when the call starts.
 *
 * Returns:
 *   True when the slot was merged into a copy of the existing data and serialized.
 */
bool samplerExtraWithSample(const(ubyte)[] currentExtra, uint slot, const(ubyte)[] audioBytes,
        ubyte rootNote, ubyte lowNote, ubyte highNote, out ubyte[] blob, out string err) {
    if (slot >= Sampler.MAX_SLOTS || lowNote > highNote || highNote > 127 || rootNote > 127) {
        err = "Target is not a Sampler slot";
        return false;
    }
    SamplerSlotAsset* asset = createSamplerAssetFromMemory(audioBytes, err, rootNote);
    if (asset is null) {
        return false;
    }
    asset.lowNote = lowNote;
    asset.highNote = highNote;
    foreach (i; 0 .. asset.left.length) {
        asset.left[i] = isFinite(asset.left[i]) ? asset.left[i] : 0.0f;
        immutable float rSample = (i < asset.right.length) ? asset.right[i] : asset.left[i];
        asset.right[i] = isFinite(rSample) ? rSample : 0.0f;
    }
    Sampler temp;
    if (currentExtra.length > 0 && !temp.deserializeExtra(currentExtra, 44_100.0f)) {
        SamplerSlotAsset.destroyErased(asset);
        err = "Existing sampler data could not be decoded";
        return false;
    }
    void* old = null;
    temp.swapAsset(slot, asset, old);
    if (old !is null) {
        SamplerSlotAsset.destroyErased(old);
    }
    if (!temp.serializeExtra(blob)) {
        err = "Sampler data could not be serialized";
        return false;
    }
    return true;
}
