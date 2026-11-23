/**
 * File:         source/modules/synths/analog_gen.d
 * Module:       modules.synths.analog_gen
 * Phase:        Phase 4.3 (Tier 1) — Polyphonic Analog Synthesizer
 *
 * Purpose:
 *   Up to 32-voice virtual-analog synth featuring PolyBLEP and drawn-waveform oscillators, unison detune, Cytomic SVF filtering with CV cutoff modulation, ADSR envelope, and off-RT asset swapping.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; VoicePool-backed with unmanaged DrawnWaveAsset buffers freed off-RT via RetireSink.
 *
 * Dependencies:
 *   Internal: dsp.envelope, dsp.filter_svf, dsp.oscillator, dsp.smoother, dsp.voice_pool, foundation.math_rt, foundation.memory, graph.buffer, graph.context, graph.event, graph.module_api, graph.port
 *   External: core.lifetime, core.stdc.stdlib, core.stdc.string, std.math (exp2, fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DrawnWaveAsset
 *   - struct AnalogGen (typeId = "synth.analog_gen", ports: event in, cvControl cutoffCv, audioStereo out)
 *   - @Param waveform, unison, detune, filterCutoff, filterReso, envAttack, envDecay, envSustain, envRelease
 *   - Hooks: handleEvent, process, swapAsset, serializeExtra, deserializeExtra
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.analog_gen;

import core.lifetime : emplace, move;
import core.stdc.stdlib : calloc, free;
import core.stdc.string : memcpy;
import std.math : exp2, fabs, isFinite;

import dsp.envelope : AdsrEnvelope;
import dsp.filter_svf : CytomicSvf, SvfMode;
import dsp.oscillator : DrawnWaveOsc, OscWaveform, PolyBlepOsc;
import dsp.smoother : ParamSmoother;
import dsp.voice_pool : VoicePool;
import foundation.math_rt : midiNoteToHz;
import foundation.memory : OwnedBuffer;
import foundation.types : NoteId;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Unmanaged @nogc single-cycle waveform table asset for OscWaveform.drawnWave playback.
 */
struct DrawnWaveAsset {
    OwnedBuffer!float table;

    @disable this(this);

    @nogc nothrow:

    /**
     * Releases the underlying @nogc sample table.
     */
    ~this() {
        table.reset();
    }

    /**
     * Copies a cycle of samples off-RT into an unmanaged DrawnWaveAsset pointer.
     *
     * Params:
     *   samples = Single-cycle wavetable samples (>= 2 entries).
     *
     * Returns:
     *   Allocated DrawnWaveAsset*, or null on invalid input or OOM.
     */
    static DrawnWaveAsset* createOffRT(const(float)[] samples) {
        if (samples.length < 2) {
            return null;
        }
        OwnedBuffer!float buf;
        if (!OwnedBuffer!float.tryAllocate(samples.length, buf)) {
            return null;
        }
        foreach (i; 0 .. samples.length) {
            buf[i] = isFinite(samples[i]) ? samples[i] : 0.0f;
        }
        auto ptr = cast(DrawnWaveAsset*) calloc(1, DrawnWaveAsset.sizeof);
        if (ptr is null) {
            return null;
        }
        emplace(ptr);
        ptr.table = move(buf);
        return ptr;
    }

    /**
     * Type-erased destructor invoked by RetireSink or AnalogGen teardown.
     *
     * Params:
     *   raw = Opaque DrawnWaveAsset* pointer.
     */
    static void destroyErased(void* raw) {
        if (raw !is null) {
            auto typed = cast(DrawnWaveAsset*) raw;
            destroy!false(*typed);
            free(raw);
        }
    }
}

/**
 * Single polyphonic virtual-analog voice with up to 4 unison oscillators, Cytomic SVF, and ADSR.
 */
struct AnalogVoice {
    private PolyBlepOsc[4] blepOscs_;
    private DrawnWaveOsc[4] drawnOscs_;
    private CytomicSvf svf_;
    private AdsrEnvelope env_;
    private float baseMidiNote_ = 60.0f;
    private float velocity_ = 1.0f;
    private float detuneAmount_ = 0.15f;
    private uint unisonCount_ = 1;

    @nogc nothrow:

    /**
     * Resets oscillator phases, filter integrators, and ADSR state cleanly.
     */
    void reset() {
        foreach (u; 0 .. 4) {
            blepOscs_[u].reset();
            drawnOscs_[u].reset();
        }
        svf_.reset();
        env_.reset();
        baseMidiNote_ = 60.0f;
        velocity_ = 1.0f;
        detuneAmount_ = 0.15f;
        unisonCount_ = 1;
    }

    /**
     * Initializes the voice for a new NoteOn trigger.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   midiNote = Fractional MIDI note pitch.
     *   vel = Normalized note velocity [0..1].
     *   unison = Unison oscillator count clamped to [1..4].
     *   detune = Unison detune depth [0..1].
     *   attack = Attack duration in seconds.
     *   decay = Decay duration in seconds.
     *   sustain = Sustain level [0..1].
     *   release = Release duration in seconds.
     */
    void trigger(
        float sampleRate,
        float midiNote,
        float vel,
        uint unison,
        float detune,
        float attack,
        float decay,
        float sustain,
        float release
    ) {
        reset();
        baseMidiNote_ = isFinite(midiNote) ? midiNote : 60.0f;
        velocity_ = isFinite(vel) ? (vel < 0.0f ? 0.0f : (vel > 1.0f ? 1.0f : vel)) : 0.8f;
        unisonCount_ = unison < 1 ? 1 : (unison > 4 ? 4 : unison);
        detuneAmount_ = isFinite(detune) ? (detune < 0.0f ? 0.0f : (detune > 1.0f ? 1.0f : detune)) : 0.15f;

        foreach (u; 0 .. 4) {
            immutable float phaseSeed = cast(float) u * 0.23f;
            blepOscs_[u].syncPhase(phaseSeed);
            drawnOscs_[u].syncPhase(phaseSeed);
        }

        updateFrequencies(sampleRate, 0.0f);
        env_.prepare(sampleRate);
        env_.setParams(attack, decay, sustain, release);
        env_.trigger(false);
    }

    /**
     * Updates unison oscillator frequencies cleanly for pitch bend or per-note slides.
     *
     * Params:
     *   sampleRate = Sample rate in Hertz.
     *   bendSemitones = Shared channel pitch bend in semitones.
     */
    void updateFrequencies(float sampleRate, float bendSemitones) {
        immutable float pitch = baseMidiNote_ + (isFinite(bendSemitones) ? bendSemitones : 0.0f);
        if (unisonCount_ <= 1) {
            immutable float hz = midiNoteToHz(pitch);
            blepOscs_[0].setFrequency(hz, sampleRate);
            drawnOscs_[0].setFrequency(hz, sampleRate);
            return;
        }
        immutable float maxSemi = detuneAmount_ * 0.6f;
        immutable float step = (2.0f * maxSemi) / cast(float)(unisonCount_ - 1);
        foreach (u; 0 .. unisonCount_) {
            immutable float offset = -maxSemi + cast(float) u * step;
            immutable float hz = midiNoteToHz(pitch + offset);
            blepOscs_[u].setFrequency(hz, sampleRate);
            drawnOscs_[u].setFrequency(hz, sampleRate);
        }
    }

    /**
     * Triggers envelope release cleanly.
     */
    void releaseNote() {
        env_.releaseNote();
    }

    /**
     * Updates envelope parameters live.
     *
     * Params:
     *   sampleRate = Sample rate in Hertz.
     *   attack = Attack seconds.
     *   decay = Decay seconds.
     *   sustain = Sustain level.
     *   release = Release seconds.
     */
    void updateEnvelope(float sampleRate, float attack, float decay, float sustain, float release) {
        env_.prepare(sampleRate);
        env_.setParams(attack, decay, sustain, release);
    }

    /**
     * Checks whether the voice remains audible.
     *
     * Returns:
     *   True if ADSR is active.
     */
    bool isActive() const pure @safe {
        return env_.isActive();
    }

    /**
     * Checks whether the voice has entered release.
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
     * Synthesizes one slice of unison oscillator + SVF output and adds it to outL/outR.
     *
     * Params:
     *   outL = Left accumulation slice.
     *   outR = Right accumulation slice.
     *   frames = Frame count for this slice.
     *   wf = Selected OscWaveform.
     *   drawnTable = Optional custom wavetable when wf == OscWaveform.drawnWave.
     *   cutoffHz = Nominal SVF cutoff frequency in Hertz.
     *   cutoffCv = Optional per-sample CV cutoff modulation slice (null when unconnected).
     *   reso = Normalized filter resonance [0..0.95].
     *   sampleRate = Active sample rate in Hertz.
     */
    void renderAdd(
        float[] outL,
        float[] outR,
        uint frames,
        OscWaveform wf,
        const(float)[] drawnTable,
        float cutoffHz,
        const(float)[] cutoffCv,
        float reso,
        float sampleRate
    ) {
        immutable uint cnt = unisonCount_ < 1 ? 1 : (unisonCount_ > 4 ? 4 : unisonCount_);
        immutable float normScale = 1.0f / cast(float) cnt;
        immutable bool useDrawn = (wf == OscWaveform.drawnWave && drawnTable.length >= 2);
        immutable bool hasCv = cutoffCv.length >= frames;

        foreach (i; 0 .. frames) {
            immutable float envVal = env_.next();
            float sumL = 0.0f;
            float sumR = 0.0f;

            foreach (u; 0 .. cnt) {
                immutable float s = useDrawn
                    ? drawnOscs_[u].nextSample(drawnTable, true)
                    : blepOscs_[u].nextSample(wf, 0.5f);
                if (cnt == 1) {
                    sumL += s;
                    sumR += s;
                } else {
                    immutable float pan = (cast(float) u / cast(float)(cnt - 1)) * 2.0f - 1.0f;
                    sumL += s * (0.65f - 0.3f * pan);
                    sumR += s * (0.65f + 0.3f * pan);
                }
            }

            float fc = cutoffHz * (0.35f + 0.9f * envVal);
            if (hasCv) {
                immutable float cv = isFinite(cutoffCv[i]) ? cutoffCv[i] : 0.0f;
                fc *= cast(float) exp2(cast(double)(cv < -2.0f ? -2.0f : (cv > 2.0f ? 2.0f : cv)) * 3.0);
            }
            svf_.setParams(fc, reso, sampleRate);
            immutable float monoMid = 0.5f * (sumL + sumR) * normScale;
            immutable float filtered = svf_.processSample(monoMid, SvfMode.lpf);
            immutable float width = (sumL - sumR) * normScale * 0.25f;
            immutable float scale = envVal * velocity_;
            outL[i] += (filtered + width) * scale;
            outR[i] += (filtered - width) * scale;
        }
    }
}

/**
 * 32-voice polyphonic virtual-analog synthesizer supporting drawn wavetable asset swaps.
 */
struct AnalogGen {
    enum string typeId = "synth.analog_gen";
    enum string displayName = "Analog Generator";
    enum ModuleCategory category = ModuleCategory.synth;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("cutoffCv", "Cutoff CV", PortKind.cvControl, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Waveform", 0.0f, 5.0f, 2.0f, "", ParamScale.discrete)
    float waveform = 2.0f;

    @Param("Unison", 1.0f, 4.0f, 1.0f, "v", ParamScale.discrete)
    float unison = 1.0f;

    @Param("Detune", 0.0f, 1.0f, 0.15f, "", ParamScale.linear)
    float detune = 0.15f;

    @Param("Cutoff", 40.0f, 18_000.0f, 4000.0f, "Hz", ParamScale.logarithmic)
    float filterCutoff = 4000.0f;

    @Param("Resonance", 0.0f, 0.95f, 0.2f, "", ParamScale.linear)
    float filterReso = 0.2f;

    @Param("Attack", 0.001f, 5.0f, 0.005f, "s", ParamScale.logarithmic)
    float envAttack = 0.005f;

    @Param("Decay", 0.005f, 5.0f, 0.2f, "s", ParamScale.logarithmic)
    float envDecay = 0.2f;

    @Param("Sustain", 0.0f, 1.0f, 0.7f, "", ParamScale.linear)
    float envSustain = 0.7f;

    @Param("Release", 0.005f, 8.0f, 0.25f, "s", ParamScale.logarithmic)
    float envRelease = 0.25f;

    private VoicePool!(AnalogVoice, 32) voices_;
    private ParamSmoother cutoffSmoother_;
    private DrawnWaveAsset* waveAsset_ = null;
    private float sampleRate_ = 44_100.0f;
    private float pitchBendSemitones_ = 0.0f;

    /**
     * Serializes the attached single-cycle drawn wavetable off-RT.
     *
     * Params:
     *   payload = Serialized float samples byte payload.
     *
     * Returns:
     *   True on success.
     */
    bool serializeExtra(out ubyte[] payload) const {
        if (waveAsset_ is null || waveAsset_.table.empty()) {
            payload = null;
            return true;
        }
        immutable size_t byteLen = waveAsset_.table.length * float.sizeof;
        payload = new ubyte[byteLen];
        memcpy(payload.ptr, waveAsset_.table.ptr, byteLen);
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
        return &DrawnWaveAsset.destroyErased;
    }

    /**
     * Restores a persisted drawn wavetable blob off the real-time thread.
     *
     * Params:
     *   payload = Raw little-endian float wavetable samples.
     *   sampleRate = Active sample rate in Hertz.
     *
     * Returns:
     *   True if valid or empty; false on malformed payload or OOM.
     */
    bool deserializeExtra(const(ubyte)[] payload, float sampleRate) {
        cast(void) sampleRate;
        if (payload.length == 0) {
            return true;
        }
        if ((payload.length % float.sizeof) != 0 || payload.length < 2 * float.sizeof) {
            return false;
        }
        immutable size_t count = payload.length / float.sizeof;
        auto tmp = new float[count];
        memcpy(tmp.ptr, payload.ptr, payload.length);
        DrawnWaveAsset* next = DrawnWaveAsset.createOffRT(tmp);
        if (next is null) {
            return false;
        }
        void* prev = null;
        swapAsset(0, next, prev);
        if (prev !is null) {
            DrawnWaveAsset.destroyErased(prev);
        }
        return true;
    }

    @nogc nothrow:

    /**
     * Releases any attached DrawnWaveAsset when the synthesizer instance is destroyed off-RT.
     */
    ~this() {
        if (waveAsset_ !is null) {
            DrawnWaveAsset.destroyErased(waveAsset_);
            waveAsset_ = null;
        }
    }

    /**
     * Initializes cutoff smoother and resets all 32 voices cleanly.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        cutoffSmoother_.prepare(sampleRate_, 5.0f, filterCutoff);
        reset();
    }

    /**
     * Silences all active voices and snaps cutoff smoother cleanly.
     */
    void reset() {
        voices_.resetAll();
        pitchBendSemitones_ = 0.0f;
        cutoffSmoother_.reset(filterCutoff);
    }

    /**
     * Responds to filter cutoff and ADSR parameter changes safely by field name.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap cutoff smoother immediately.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        static if (field == "filterCutoff") {
            cutoffSmoother_.setTarget(filterCutoff, instant);
        } else static if (field == "envAttack" || field == "envDecay"
                || field == "envSustain" || field == "envRelease") {
            immutable float sr = sampleRate_;
            immutable float a = envAttack;
            immutable float d = envDecay;
            immutable float s = envSustain;
            immutable float r = envRelease;
            voices_.forEachActive((ref AnalogVoice v, NoteId id) @nogc nothrow {
                cast(void) id;
                v.updateEnvelope(sr, a, d, s, r);
            });
        }
    }

    /**
     * Dispatches note trigger, release, pitch bend, and velocity updates to VoicePool.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active audio sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        switch (ev.kind) {
            case ModEventKind.noteOn: {
                bool stolen = false;
                AnalogVoice* v = voices_.allocateVoice(ev.noteId, stolen);
                if (v !is null) {
                    immutable uint uni = isFinite(unison) ? cast(uint)(unison + 0.5f) : 1;
                    v.trigger(
                        sampleRate_,
                        ev.valueA,
                        ev.valueB,
                        uni,
                        detune,
                        envAttack,
                        envDecay,
                        envSustain,
                        envRelease
                    );
                    if (fabs(pitchBendSemitones_) > 1e-6f) {
                        v.updateFrequencies(sampleRate_, pitchBendSemitones_);
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
                    pitchBendSemitones_ = isFinite(ev.valueA) ? ev.valueA : 0.0f;
                    immutable float sr = sampleRate_;
                    immutable float bend = pitchBendSemitones_;
                    voices_.forEachActive((ref AnalogVoice v, NoteId id) @nogc nothrow {
                        cast(void) id;
                        v.updateFrequencies(sr, bend);
                    });
                } else {
                    AnalogVoice* v = voices_.findVoice(ev.noteId);
                    if (v !is null) {
                        v.baseMidiNote_ = isFinite(ev.valueA) ? ev.valueA : v.baseMidiNote_;
                        v.updateFrequencies(sampleRate_, pitchBendSemitones_);
                    }
                }
                break;

            case ModEventKind.setVelocity: {
                AnalogVoice* v = voices_.findVoice(ev.noteId);
                if (v !is null && isFinite(ev.valueB)) {
                    v.velocity_ = ev.valueB < 0.0f ? 0.0f : (ev.valueB > 1.0f ? 1.0f : ev.valueB);
                }
                break;
            }

            default:
                break;
        }
    }

    /**
     * Renders active polyphonic analog voices cleanly into audioOut.
     *
     * Params:
     *   io = Bundle carrying optional cutoffCv modulation and stereo output slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while audio output or active voices remain non-idle.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        voices_.deactivateFinished();
        if (!voices_.hasActiveVoices()) {
            io.audioOut[0][0 .. ctx.frames] = 0.0f;
            io.audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) cutoffSmoother_.next();
            }
            return false;
        }

        auto outL = io.audioOut[0];
        auto outR = io.audioOut[1];
        outL[0 .. ctx.frames] = 0.0f;
        outR[0 .. ctx.frames] = 0.0f;

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable uint frames = ctx.frames;
        immutable int wfInt = isFinite(waveform) ? cast(int)(waveform + 0.5f) : 2;
        immutable OscWaveform wf = (wfInt >= 0 && wfInt <= 5) ? cast(OscWaveform) wfInt : OscWaveform.saw;
        const(float)[] drawnTbl = waveAsset_ !is null ? waveAsset_.table[] : null;
        const(float)[] cvSlice = (io.numCvIn > 0 && io.cvIn[0].connected && !io.cvIn[0].silent)
            ? io.cvIn[0].samples : null;
        immutable float res = isFinite(filterReso)
            ? (filterReso < 0.0f ? 0.0f : (filterReso > 0.95f ? 0.95f : filterReso)) : 0.2f;

        float cutoffNow = cutoffSmoother_.current();
        foreach (_; 0 .. frames) {
            cutoffNow = cutoffSmoother_.next();
        }

        voices_.forEachActive((ref AnalogVoice v, NoteId id) @nogc nothrow {
            cast(void) id;
            v.renderAdd(outL, outR, frames, wf, drawnTbl, cutoffNow, cvSlice, res, sr);
        });

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
     * Atomically swaps a custom DrawnWaveAsset pointer on slot 0.
     *
     * Params:
     *   slot = Asset slot index (must be 0).
     *   newAsset = Replacement DrawnWaveAsset* pointer.
     *   oldAsset = Receives previous asset pointer for off-RT cleanup.
     *
     * Returns:
     *   True when slot == 0.
     */
    bool swapAsset(uint slot, void* newAsset, out void* oldAsset) {
        oldAsset = null;
        if (slot != 0) {
            return false;
        }
        oldAsset = waveAsset_;
        waveAsset_ = cast(DrawnWaveAsset*) newAsset;
        return true;
    }
}
