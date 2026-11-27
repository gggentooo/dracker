/**
 * File:         source/modules/synths/spectravoice.d
 * Module:       modules.synths.spectravoice
 * Phase:        Phase 4.9 (Tier 2) — Additive Harmonic / FFT Wavetable Synth
 *
 * Purpose:
 *   Synthesizes harmonic spectra via off-RT inverse FFT wavetable synthesis and plays polyphonic voices through VoicePool. prepare() precomputes every Profile x Bandwidth harmonic table into an unmanaged SpectraTableBank off the audio thread so Profile and Bandwidth take effect immediately from the rack, automation, MIDI or loading with a short click-free crossfade on held notes (T115); an attached slot-0 SpectraTableAsset overrides the bank.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process()/handleEvent()/swapAsset(); no harmonic table is ever built on the audio thread; tables live in unmanaged SpectraTableBank and SpectraTableAsset buffers, and serializeExtra prefixes a custom table mark so old stored tables are ignored.
 *
 * Dependencies:
 *   Internal: dsp.envelope, dsp.fft, dsp.interp, dsp.voice_pool, foundation.math_rt, foundation.memory, foundation.types, graph.context, graph.event, graph.module_api, graph.port
 *   External: core.lifetime, core.stdc.stdlib, core.stdc.string, std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct SpectraTableAsset, struct SpectraTableBank
 *   - clampBandwidth, harmonicCount, fillHarmonicTable
 *   - struct SpectraVoice (typeId = "synth.spectravoice", ports: event in, audioStereo out)
 *   - @Param harmonicProfile, bandwidth, attackMs, releaseMs
 *   - Hooks: handleEvent, process, swapAsset, serializeExtra, deserializeExtra
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.spectravoice;

import core.lifetime : emplace, move;
import core.stdc.stdlib : calloc, free;
import core.stdc.string : memcpy;
import std.math : cos, exp, fabs, floor, isFinite, sin;

import dsp.envelope : AdsrEnvelope;
import dsp.fft : FftFloat;
import dsp.interp : sampleBufferWrapped;
import dsp.voice_pool : VoicePool;
import foundation.math_rt : midiNoteToHz;
import foundation.memory : OwnedBuffer;
import foundation.types : NoteId;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Unmanaged @nogc single-cycle harmonic wavetable asset synthesized via inverse radix-2 FFT.
 */
struct SpectraTableAsset {
    OwnedBuffer!float wavetable;
    uint profileId = 0;
    float bandwidthUsed = 0.35f;

    @disable this(this);

    @nogc nothrow:

    /**
     * Releases the unmanaged @nogc wavetable sample buffer.
     */
    ~this() {
        wavetable.reset();
    }

    /**
     * Synthesizes a normalized 2048-point harmonic wavetable using inverse FFT off-RT.
     *
     * Params:
     *   profile = Spectral preset (0=organ, 1=brass, 2=choir, 3=bell).
     *   bandwidth = Spectral brightness/spread in [0.05f, 1.0f].
     *   tableSize = Power-of-two wavetable length (defaults to 2048).
     *
     * Returns:
     *   Allocated SpectraTableAsset*, or null on invalid size or OOM.
     */
    static SpectraTableAsset* buildHarmonicTable(
        uint profile,
        float bandwidth,
        size_t tableSize = 2048
    ) {
        if (!FftFloat.isValidSize(tableSize) || tableSize < 64) {
            return null;
        }
        OwnedBuffer!float tbl;
        OwnedBuffer!float re;
        OwnedBuffer!float im;
        if (!OwnedBuffer!float.tryAllocate(tableSize, tbl)
                || !OwnedBuffer!float.tryAllocate(tableSize, re)
                || !OwnedBuffer!float.tryAllocate(tableSize, im)) {
            return null;
        }

        immutable float bw = clampBandwidth(bandwidth);
        fillHarmonicTable(tbl[], re[], im[], profile, harmonicCount(bw));

        auto ptr = cast(SpectraTableAsset*) calloc(1, SpectraTableAsset.sizeof);
        if (ptr is null) {
            return null;
        }
        emplace(ptr);
        ptr.wavetable = move(tbl);
        ptr.profileId = profile;
        ptr.bandwidthUsed = bw;
        return ptr;
    }

    /**
     * Type-erased destructor freeing SpectraTableAsset memory off the real-time thread.
     *
     * Params:
     *   raw = Opaque SpectraTableAsset* pointer.
     */
    static void destroyErased(void* raw) {
        if (raw !is null) {
            auto typed = cast(SpectraTableAsset*) raw;
            destroy!false(*typed);
            free(raw);
        }
    }
}

/**
 * Clamps a Bandwidth parameter to the table-building range.
 *
 * Params:
 *   bandwidth = Requested spectral brightness/spread.
 *
 * Returns:
 *   bandwidth clamped to [0.05f, 1.0f]; 0.35f when not finite.
 */
float clampBandwidth(float bandwidth) @nogc nothrow pure @safe {
    return isFinite(bandwidth)
        ? (bandwidth < 0.05f ? 0.05f : (bandwidth > 1.0f ? 1.0f : bandwidth)) : 0.35f;
}

/**
 * Maps a Bandwidth value to the number of harmonics a wavetable fill activates.
 *
 * Params:
 *   bandwidth = Requested spectral brightness/spread.
 *
 * Returns:
 *   floor(4 + clampedBandwidth * 44), so 6 at 0.05 and 48 at 1.0.
 */
size_t harmonicCount(float bandwidth) @nogc nothrow pure @safe {
    return cast(size_t)(4.0 + cast(double) clampBandwidth(bandwidth) * 44.0);
}

/**
 * Fills one harmonic wavetable from a profile and harmonic count via inverse FFT, normalizing peak to 0.95.
 *
 * Params:
 *   tbl = Destination 2048-point (or other power-of-two) wavetable slice.
 *   re = Reused inverse-FFT real buffer (zeroed here before use).
 *   im = Reused inverse-FFT imaginary buffer (zeroed here before use).
 *   profile = Spectral preset (0=organ, 1=brass, 2=choir, 3=bell).
 *   harmonics = Number of harmonics to activate.
 */
void fillHarmonicTable(float[] tbl, float[] re, float[] im, uint profile, size_t harmonics) @nogc nothrow {
    re[] = 0.0f;
    im[] = 0.0f;
    immutable size_t tableSize = tbl.length;
    immutable size_t maxBins = tableSize / 2;
    immutable size_t limit = harmonics < maxBins ? harmonics : (maxBins - 1);

    foreach (h; 1 .. limit + 1) {
        double mag = 0.0;
        double ph = 0.0;
        switch (profile) {
            case 0:
                if (h == 1 || h == 2 || h == 3 || h == 4 || h == 6 || h == 8 || h == 12 || h == 16) {
                    mag = 1.0 / (cast(double) h * 0.65 + 0.35);
                }
                break;
            case 1:
                mag = 1.0 / cast(double) h;
                if ((h & 1) == 0) mag *= 0.85;
                break;
            case 2:
                mag = exp(-0.08 * cast(double)(h - 1)) * (0.6 + 0.4 * cos(cast(double) h * 0.9));
                if (mag < 0.0) mag = 0.0;
                break;
            default:
                mag = exp(-0.05 * cast(double)(h - 1)) / (1.0 + 0.1 * cast(double) h);
                ph = cast(double) h * 1.17;
                break;
        }
        immutable double amp = mag * cast(double) tableSize * 0.5;
        re[h] = cast(float)(amp * cos(ph));
        im[h] = cast(float)(amp * sin(ph));
        re[tableSize - h] = re[h];
        im[tableSize - h] = -im[h];
    }

    FftFloat.inverse(re[], im[]);

    float peak = 0.0f;
    foreach (i; 0 .. tableSize) {
        tbl[i] = re[i];
        immutable float a = fabs(tbl[i]);
        if (a > peak) peak = a;
    }
    if (peak > 1e-6f) {
        immutable float inv = 0.95f / peak;
        foreach (i; 0 .. tableSize) {
            tbl[i] *= inv;
        }
    }
}

/**
 * Unmanaged @nogc bank of every precomputed harmonic wavetable: 4 profiles times 43 harmonic counts,
 * built once off the audio thread so parameter changes only pick a table.
 */
struct SpectraTableBank {
    enum size_t TABLE_SIZE = 2048;
    enum size_t PROFILE_COUNT = 4;
    enum size_t MIN_HARMONICS = 6;
    enum size_t MAX_HARMONICS = 48;
    enum size_t COUNTS_PER_PROFILE = MAX_HARMONICS - MIN_HARMONICS + 1;
    enum size_t TABLE_COUNT = PROFILE_COUNT * COUNTS_PER_PROFILE;

    OwnedBuffer!float tables;

    @disable this(this);

    @nogc nothrow:

    /**
     * Releases the unmanaged @nogc table storage on teardown.
     */
    ~this() {
        tables.reset();
    }

    /**
     * Allocates and fills all profile/harmonic-count wavetables off the real-time thread.
     *
     * Returns:
     *   Allocated SpectraTableBank*, or null on out-of-memory.
     */
    static SpectraTableBank* build() {
        auto ptr = cast(SpectraTableBank*) calloc(1, SpectraTableBank.sizeof);
        if (ptr is null) {
            return null;
        }
        emplace(ptr);

        OwnedBuffer!float re;
        OwnedBuffer!float im;
        if (!OwnedBuffer!float.tryAllocate(TABLE_COUNT * TABLE_SIZE, ptr.tables)
                || !OwnedBuffer!float.tryAllocate(TABLE_SIZE, re)
                || !OwnedBuffer!float.tryAllocate(TABLE_SIZE, im)) {
            destroy!false(*ptr);
            free(ptr);
            return null;
        }

        foreach (p; 0 .. PROFILE_COUNT) {
            foreach (count; MIN_HARMONICS .. MAX_HARMONICS + 1) {
                immutable size_t idx = p * COUNTS_PER_PROFILE + (count - MIN_HARMONICS);
                fillHarmonicTable(ptr.tables[idx * TABLE_SIZE .. (idx + 1) * TABLE_SIZE],
                    re[], im[], cast(uint) p, count);
            }
        }
        return ptr;
    }

    /**
     * Returns the precomputed 2048-float wavetable for a profile and bandwidth.
     *
     * Params:
     *   profile = Spectral preset; values above 3 clamp to 3.
     *   bandwidth = Spectral brightness/spread; clamped to [0.05f, 1.0f].
     *
     * Returns:
     *   The selected table slice, or null when the bank is empty.
     */
    const(float)[] table(uint profile, float bandwidth) const {
        if (tables.empty()) {
            return null;
        }
        immutable uint p = profile < PROFILE_COUNT ? profile : (PROFILE_COUNT - 1);
        immutable size_t rawCount = harmonicCount(bandwidth);
        immutable size_t count = rawCount < MIN_HARMONICS ? MIN_HARMONICS
            : (rawCount > MAX_HARMONICS ? MAX_HARMONICS : rawCount);
        immutable size_t idx = p * COUNTS_PER_PROFILE + (count - MIN_HARMONICS);
        return tables[idx * TABLE_SIZE .. (idx + 1) * TABLE_SIZE];
    }

    /**
     * Type-erased destructor freeing SpectraTableBank memory off the real-time thread.
     *
     * Params:
     *   raw = Opaque SpectraTableBank* pointer.
     */
    static void destroyErased(void* raw) {
        if (raw !is null) {
            auto typed = cast(SpectraTableBank*) raw;
            destroy!false(*typed);
            free(raw);
        }
    }
}

/**
 * Polyphonic wavetable voice slot for SpectraVoice reading inverse-FFT harmonic cycles.
 */
struct SpectraVoiceSlot {
    private double phasePos_ = 0.0;
    private double freqHz_ = 440.0;
    private float baseMidiNote_ = 60.0f;
    private float velocity_ = 1.0f;
    private AdsrEnvelope env_;

    @nogc nothrow:

    /**
     * Resets wavetable read phase and amplitude envelope immediately.
     */
    void reset() {
        phasePos_ = 0.0;
        freqHz_ = 440.0;
        baseMidiNote_ = 60.0f;
        velocity_ = 1.0f;
        env_.reset();
    }

    /**
     * Triggers playback on midiNote and velocity with configurable attack/release times.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   midiNote = Fractional MIDI note pitch.
     *   vel = Normalized note velocity [0..1].
     *   bendSemitones = Shared pitch bend offset in semitones.
     *   attackSec = Attack time in seconds.
     *   releaseSec = Release time in seconds.
     */
    void trigger(
        float sampleRate,
        float midiNote,
        float vel,
        float bendSemitones,
        float attackSec,
        float releaseSec
    ) {
        reset();
        baseMidiNote_ = isFinite(midiNote) ? midiNote : 60.0f;
        velocity_ = isFinite(vel) ? (vel < 0.0f ? 0.0f : (vel > 1.0f ? 1.0f : vel)) : 0.8f;
        updateFrequency(bendSemitones);
        env_.prepare(sampleRate);
        env_.setParams(attackSec, 0.15f, 0.75f, releaseSec);
        env_.trigger(false);
    }

    /**
     * Updates target playback frequency from baseMidiNote and pitch bend.
     *
     * Params:
     *   bendSemitones = Shared pitch bend in semitones.
     */
    void updateFrequency(float bendSemitones) pure @safe {
        immutable float pitch = baseMidiNote_ + (isFinite(bendSemitones) ? bendSemitones : 0.0f);
        freqHz_ = cast(double) midiNoteToHz(pitch);
    }

    /**
     * Updates envelope times dynamically while note is held.
     *
     * Params:
     *   sampleRate = Sample rate in Hertz.
     *   attackSec = Attack seconds.
     *   releaseSec = Release seconds.
     */
    void updateEnvelope(float sampleRate, float attackSec, float releaseSec) pure @safe {
        env_.prepare(sampleRate);
        env_.setParams(attackSec, 0.15f, 0.75f, releaseSec);
    }

    /**
     * Starts envelope release stage cleanly.
     */
    void releaseNote() {
        env_.releaseNote();
    }

    /**
     * Checks whether envelope output remains active.
     *
     * Returns:
     *   True if active.
     */
    bool isActive() const pure @safe {
        return env_.isActive();
    }

    /**
     * Checks whether envelope is releasing.
     *
     * Returns:
     *   True if releasing.
     */
    bool isReleasing() const pure @safe {
        return env_.isReleasing();
    }

    /**
     * Returns current voice output weight for deterministic stealing priority.
     *
     * Returns:
     *   Envelope amplitude scaled by velocity.
     */
    float currentLevel() const pure @safe {
        return env_.value() * velocity_;
    }

    /**
     * Renders stereo audio from the active harmonic wavetable and adds into outL/outR.
     *
     * Params:
     *   outL = Destination left accumulation slice.
     *   outR = Destination right accumulation slice.
     *   frames = Frame count for this slice.
     *   table = Precomputed periodic harmonic wavetable slice.
     *   sampleRate = Active sample rate in Hertz.
     */
    void renderAdd(
        float[] outL,
        float[] outR,
        uint frames,
        const(float)[] table,
        float sampleRate
    ) {
        if (table.length < 2) {
            env_.reset();
            return;
        }
        immutable double len = cast(double) table.length;
        immutable double sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0 : cast(double) sampleRate;
        immutable double step = freqHz_ * len / sr;

        foreach (i; 0 .. frames) {
            immutable float a = env_.next();
            immutable float s = sampleBufferWrapped(table, phasePos_, true) * a * velocity_;
            outL[i] += s;
            outR[i] += s;
            phasePos_ += step;
            if (phasePos_ >= len) {
                phasePos_ -= floor(phasePos_ / len) * len;
            }
        }
    }

    /**
     * Renders stereo audio while linearly crossfading from oldTable to newTable over fadeTotal frames.
     *
     * Params:
     *   outL = Destination left accumulation slice.
     *   outR = Destination right accumulation slice.
     *   frames = Frame count for this slice.
     *   oldTable = Previous harmonic wavetable fading out.
     *   newTable = Target harmonic wavetable fading in.
     *   fadePos = Starting frame index inside the crossfade ramp.
     *   fadeTotal = Total crossfade duration in frames (>= 1).
     *   sampleRate = Active sample rate in Hertz.
     */
    void renderAddCrossfade(
        float[] outL,
        float[] outR,
        uint frames,
        const(float)[] oldTable,
        const(float)[] newTable,
        uint fadePos,
        uint fadeTotal,
        float sampleRate
    ) {
        if (newTable.length < 2) {
            env_.reset();
            return;
        }
        if (oldTable.length < 2 || fadeTotal == 0) {
            renderAdd(outL, outR, frames, newTable, sampleRate);
            return;
        }
        immutable double newLen = cast(double) newTable.length;
        immutable double oldLen = cast(double) oldTable.length;
        immutable double ratio = oldLen / newLen;
        immutable double sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0 : cast(double) sampleRate;
        immutable double step = freqHz_ * newLen / sr;
        immutable float invTotal = 1.0f / cast(float) fadeTotal;

        foreach (i; 0 .. frames) {
            immutable uint stepIdx = fadePos + i;
            immutable float t = stepIdx + 1 < fadeTotal ? cast(float)(stepIdx + 1) * invTotal : 1.0f;
            immutable float newS = sampleBufferWrapped(newTable, phasePos_, true);
            immutable double oldPos = oldTable.length == newTable.length ? phasePos_ : phasePos_ * ratio;
            immutable float oldS = sampleBufferWrapped(oldTable, oldPos, true);
            immutable float a = env_.next();
            immutable float s = (oldS * (1.0f - t) + newS * t) * a * velocity_;
            outL[i] += s;
            outR[i] += s;
            phasePos_ += step;
            if (phasePos_ >= newLen) {
                phasePos_ -= floor(phasePos_ / newLen) * newLen;
            }
        }
    }
}

/**
 * 16-voice additive FFT wavetable synthesizer supporting off-RT spectral wavetable swaps.
 */
struct SpectraVoice {
    enum string typeId = "synth.spectravoice";
    enum string displayName = "SpectraVoice";
    enum ModuleCategory category = ModuleCategory.synth;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    static immutable ubyte[4] CUSTOM_TABLE_MAGIC = ['S', 'V', 'T', '1'];
    enum float TABLE_CROSSFADE_MS = 5.0f;

    @Param("Profile", 0.0f, 3.0f, 0.0f, "", ParamScale.discrete,
        ["Organ", "Brass", "Choir", "Bell"])
    float harmonicProfile = 0.0f;

    @Param("Bandwidth", 0.05f, 1.0f, 0.35f, "", ParamScale.linear)
    float bandwidth = 0.35f;

    @Param("Attack", 1.0f, 3000.0f, 15.0f, "ms", ParamScale.logarithmic)
    float attackMs = 15.0f;

    @Param("Release", 5.0f, 5000.0f, 250.0f, "ms", ParamScale.logarithmic)
    float releaseMs = 250.0f;

    private VoicePool!(SpectraVoiceSlot, 16) voices_;
    private SpectraTableAsset* tableAsset_ = null;
    private SpectraTableBank* bank_ = null;
    private const(float)* currentTablePtr_ = null;
    private size_t currentTableLen_ = 0;
    private const(float)* fadeFromPtr_ = null;
    private size_t fadeFromLen_ = 0;
    private uint fadePos_ = 0;
    private uint fadeTotal_ = 0;
    private float sampleRate_ = 44_100.0f;
    private float pitchBendSemitones_ = 0.0f;

    /**
     * Serializes the attached inverse-FFT wavetable slice off-RT, prefixed with the custom table mark.
     *
     * Params:
     *   payload = Byte array holding the mark followed by serialized wavetable floats.
     *
     * Returns:
     *   True on success; payload is empty when no slot-0 table is attached.
     */
    bool serializeExtra(out ubyte[] payload) const {
        if (tableAsset_ is null || tableAsset_.wavetable.empty()) {
            payload = null;
            return true;
        }
        immutable size_t bytes = tableAsset_.wavetable.length * float.sizeof;
        payload = new ubyte[CUSTOM_TABLE_MAGIC.length + bytes];
        memcpy(payload.ptr, CUSTOM_TABLE_MAGIC.ptr, CUSTOM_TABLE_MAGIC.length);
        memcpy(payload.ptr + CUSTOM_TABLE_MAGIC.length, tableAsset_.wavetable.ptr, bytes);
        return true;
    }

    enum uint ASSET_SLOT_COUNT = 1;

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
        return &SpectraTableAsset.destroyErased;
    }

    /**
     * Deserializes a marked harmonic wavetable slice cleanly off the real-time thread.
     *
     * Payloads without the custom mark (old stored tables) are treated as empty and install nothing,
     * so the module keeps sounding from its parameters via the prebuilt table bank.
     *
     * Params:
     *   payload = Mark followed by raw little-endian float wavetable bytes.
     *   sampleRate = Active sample rate in Hertz.
     *
     * Returns:
     *   True if empty, unmarked or validly restored; false on malformed marked length or OOM.
     */
    bool deserializeExtra(const(ubyte)[] payload, float sampleRate) {
        cast(void) sampleRate;
        if (payload.length == 0) {
            return true;
        }
        if (payload.length < CUSTOM_TABLE_MAGIC.length
                || payload[0 .. CUSTOM_TABLE_MAGIC.length] != CUSTOM_TABLE_MAGIC[]) {
            return true;
        }
        const(ubyte)[] tableBytes = payload[CUSTOM_TABLE_MAGIC.length .. $];
        if ((tableBytes.length % float.sizeof) != 0 || tableBytes.length < 64 * float.sizeof) {
            return false;
        }
        immutable size_t count = tableBytes.length / float.sizeof;
        OwnedBuffer!float buf;
        if (!OwnedBuffer!float.tryAllocate(count, buf)) {
            return false;
        }
        memcpy(buf.ptr, tableBytes.ptr, tableBytes.length);

        auto ptr = cast(SpectraTableAsset*) calloc(1, SpectraTableAsset.sizeof);
        if (ptr is null) {
            return false;
        }
        emplace(ptr);
        ptr.wavetable = move(buf);
        void* prev = null;
        swapAsset(0, ptr, prev);
        if (prev !is null) {
            SpectraTableAsset.destroyErased(prev);
        }
        return true;
    }

    @nogc nothrow:

    /**
     * Frees any owned inverse-FFT harmonic wavetable asset and table bank on teardown.
     */
    ~this() {
        if (tableAsset_ !is null) {
            SpectraTableAsset.destroyErased(tableAsset_);
            tableAsset_ = null;
        }
        if (bank_ !is null) {
            SpectraTableBank.destroyErased(bank_);
            bank_ = null;
        }
    }

    /**
     * Builds the full profile/bandwidth harmonic table bank off the audio thread and initializes voices.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        if (bank_ is null) {
            bank_ = SpectraTableBank.build();
        }
        reset();
    }

    /**
     * Selects the wavetable for the current parameters: an attached slot-0 asset overrides the bank.
     *
     * Returns:
     *   Active table slice, or null when no table is available.
     */
    private const(float)[] activeTable() const {
        if (tableAsset_ !is null && !tableAsset_.wavetable.empty()) {
            return tableAsset_.wavetable[];
        }
        if (bank_ !is null) {
            return bank_.table(selectedProfile(), bandwidth);
        }
        return null;
    }

    /**
     * Resets all polyphonic voices and channel pitch bend cleanly.
     */
    void reset() {
        voices_.resetAll();
        pitchBendSemitones_ = 0.0f;
        currentTablePtr_ = null;
        currentTableLen_ = 0;
        fadeFromPtr_ = null;
        fadeFromLen_ = 0;
        fadePos_ = 0;
        fadeTotal_ = 0;
    }

    /**
     * Updates active envelopes when attackMs/releaseMs change cleanly on the RT thread.
     *
     * Params:
     *   sampleRate = Active audio sample rate in Hertz.
     *   instant = Unused.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) instant;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        static if (field == "attackMs" || field == "releaseMs") {
            immutable float sr = sampleRate_;
            immutable float att = attackMs * 0.001f;
            immutable float rel = releaseMs * 0.001f;
            voices_.forEachActive((ref SpectraVoiceSlot v, NoteId id) @nogc nothrow {
                cast(void) id;
                v.updateEnvelope(sr, att, rel);
            });
        }
    }

    /**
     * Handles note triggers, releases, and pitch bends through VoicePool.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        switch (ev.kind) {
            case ModEventKind.noteOn: {
                bool stolen = false;
                SpectraVoiceSlot* v = voices_.allocateVoice(ev.noteId, stolen);
                if (v !is null) {
                    v.trigger(
                        sampleRate_,
                        ev.valueA,
                        ev.valueB,
                        pitchBendSemitones_,
                        attackMs * 0.001f,
                        releaseMs * 0.001f
                    );
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
                    pitchBendSemitones_ = isFinite(ev.valueA) ? ev.valueA : 0.0f;
                    immutable float bend = pitchBendSemitones_;
                    voices_.forEachActive((ref SpectraVoiceSlot v, NoteId id) @nogc nothrow {
                        cast(void) id;
                        v.updateFrequency(bend);
                    });
                } else {
                    SpectraVoiceSlot* v = voices_.findVoice(ev.noteId);
                    if (v !is null) {
                        v.baseMidiNote_ = isFinite(ev.valueA) ? ev.valueA : v.baseMidiNote_;
                        v.updateFrequency(pitchBendSemitones_);
                    }
                }
                break;

            default:
                break;
        }
    }

    /**
     * Renders active polyphonic wavetable voices into stereo audioOut cleanly.
     *
     * Params:
     *   audioIn = Unused stereo input slices.
     *   audioOut = Destination stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while audio output or active voices remain audible.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        cast(void) audioIn;
        voices_.deactivateFinished();
        const(float)[] target = activeTable();
        if (!voices_.hasActiveVoices() || target.length < 2) {
            currentTablePtr_ = target.ptr;
            currentTableLen_ = target.length;
            fadeFromPtr_ = null;
            fadeFromLen_ = 0;
            fadePos_ = 0;
            fadeTotal_ = 0;
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            return false;
        }

        auto outL = audioOut[0];
        auto outR = audioOut[1];
        outL[0 .. ctx.frames] = 0.0f;
        outR[0 .. ctx.frames] = 0.0f;

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable uint frames = ctx.frames;

        if (currentTablePtr_ is null || currentTableLen_ < 2) {
            currentTablePtr_ = target.ptr;
            currentTableLen_ = target.length;
            fadeFromPtr_ = null;
            fadeFromLen_ = 0;
            fadePos_ = 0;
            fadeTotal_ = 0;
        } else if (target.ptr !is currentTablePtr_ || target.length != currentTableLen_) {
            fadeFromPtr_ = currentTablePtr_;
            fadeFromLen_ = currentTableLen_;
            currentTablePtr_ = target.ptr;
            currentTableLen_ = target.length;
            fadePos_ = 0;
            immutable uint fadeFrames = cast(uint)(sr * (TABLE_CROSSFADE_MS * 0.001f) + 0.5f);
            fadeTotal_ = fadeFrames > 0 ? fadeFrames : 1;
        }

        const(float)[] curTbl = currentTablePtr_[0 .. currentTableLen_];
        if (fadeTotal_ > 0 && fadePos_ < fadeTotal_ && fadeFromPtr_ !is null && fadeFromLen_ >= 2) {
            const(float)[] oldTbl = fadeFromPtr_[0 .. fadeFromLen_];
            immutable uint fPos = fadePos_;
            immutable uint fTotal = fadeTotal_;
            voices_.forEachActive((ref SpectraVoiceSlot v, NoteId id) @nogc nothrow {
                cast(void) id;
                v.renderAddCrossfade(outL, outR, frames, oldTbl, curTbl, fPos, fTotal, sr);
            });
            fadePos_ += frames;
            if (fadePos_ >= fadeTotal_) {
                fadeFromPtr_ = null;
                fadeFromLen_ = 0;
                fadePos_ = 0;
                fadeTotal_ = 0;
            }
        } else {
            voices_.forEachActive((ref SpectraVoiceSlot v, NoteId id) @nogc nothrow {
                cast(void) id;
                v.renderAdd(outL, outR, frames, curTbl, sr);
            });
        }

        float peak = 0.0f;
        foreach (i; 0 .. frames) {
            immutable float al = fabs(outL[i]);
            immutable float ar = fabs(outR[i]);
            if (al > peak) peak = al;
            if (ar > peak) peak = ar;
        }
        return peak > 1e-7f || voices_.hasActiveVoices();
    }

    /**
     * Atomically replaces the active SpectraTableAsset* on slot 0 for RetireSink cleanup.
     *
     * Params:
     *   slot = Asset slot index (must be 0).
     *   newAsset = Replacement SpectraTableAsset* built off-RT.
     *   oldAsset = Receives previous SpectraTableAsset* pointer.
     *
     * Returns:
     *   True if slot == 0.
     */
    bool swapAsset(uint slot, void* newAsset, out void* oldAsset) {
        oldAsset = null;
        if (slot != 0) {
            return false;
        }
        if (tableAsset_ !is null && !tableAsset_.wavetable.empty()) {
            const(float)* dying = tableAsset_.wavetable.ptr;
            if (currentTablePtr_ is dying) {
                currentTablePtr_ = null;
                currentTableLen_ = 0;
            }
            if (fadeFromPtr_ is dying) {
                fadeFromPtr_ = null;
                fadeFromLen_ = 0;
                fadePos_ = 0;
                fadeTotal_ = 0;
            }
        }
        oldAsset = tableAsset_;
        tableAsset_ = cast(SpectraTableAsset*) newAsset;
        return true;
    }

    private uint selectedProfile() const pure @safe {
        if (!isFinite(harmonicProfile)) return 0;
        int p = cast(int)(harmonicProfile + 0.5f);
        if (p < 0) p = 0;
        if (p > 3) p = 3;
        return cast(uint) p;
    }
}
