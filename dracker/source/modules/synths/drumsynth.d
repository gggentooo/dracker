/**
 * File:         source/modules/synths/drumsynth.d
 * Module:       modules.synths.drumsynth
 * Phase:        Phase 4.3 (Tier 1) — Multi-Voice Drum Kit Synthesizer
 *
 * Purpose:
 *   Synthesizes mapped kick, snare, closed/open hi-hat, tom, and percussion voices across MIDI notes using PolyBLEP oscillators, Cytomic SVFs, and noise envelopes managed by VoicePool.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; fixed pre-allocated VoicePool!(DrumVoice, 8) with zero heap calls.
 *
 * Dependencies:
 *   Internal: dsp.filter_svf, dsp.oscillator, dsp.voice_pool, graph.context, graph.event, graph.module_api, graph.port
 *   External: std.math (exp, fabs, isFinite, tanh)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DrumSynth (typeId = "synth.drumsynth", ports: event in, audioStereo out)
 *   - @Param kitDecay, tone, snappy, panSpread, masterVol
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.drumsynth;

import std.math : exp, fabs, isFinite, tanh;

import dsp.filter_svf : CytomicSvf, SvfMode;
import dsp.oscillator : DeterministicNoise, OscWaveform, PolyBlepOsc;
import dsp.voice_pool : VoicePool;
import foundation.types : NoteId;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Percussion voice kind mapped from incoming MIDI note numbers.
 */
enum DrumKind : ubyte {
    kick = 0,
    snare = 1,
    closedHat = 2,
    openHat = 3,
    lowTom = 4,
    highTom = 5,
    perc = 6
}

/**
 * Single synthesized drum voice slot supporting kicks, snares, hats, toms, and metallic perc.
 */
struct DrumVoice {
    private PolyBlepOsc bodyOsc_;
    private PolyBlepOsc harmonicOsc_;
    private DeterministicNoise noise_;
    private CytomicSvf svf_;

    private DrumKind kind_ = DrumKind.kick;
    private float velocity_ = 1.0f;
    private float pan_ = 0.0f;
    private double bodyFreqStart_ = 160.0;
    private double bodyFreqEnd_ = 48.0;
    private double pitchDecayRate_ = 30.0;
    private double bodyEnv_ = 0.0;
    private double noiseEnv_ = 0.0;
    private double bodyDecayMul_ = 0.999;
    private double noiseDecayMul_ = 0.998;
    private double elapsed_ = 0.0;
    private bool active_ = false;
    private bool releasing_ = false;

    @nogc nothrow:

    /**
     * Resets oscillator, noise, filter, and envelope accumulators immediately.
     */
    void reset() {
        bodyOsc_.reset();
        harmonicOsc_.reset();
        noise_.reset(0x4452_554Du);
        svf_.reset();
        bodyEnv_ = 0.0;
        noiseEnv_ = 0.0;
        elapsed_ = 0.0;
        active_ = false;
        releasing_ = false;
    }

    /**
     * Triggers the drum voice configured for midiNote and global kit parameters.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   midiNote = Trigger note selecting kick/snare/hat/tom/perc voicing.
     *   velocity = Normalized trigger velocity [0..1].
     *   kitDecay = Global decay time multiplier.
     *   tone = Filter tone shaping [0..1].
     *   snappy = Snare/noise transient balance [0..1].
     *   panSpread = Stereo kit spread [0..1].
     */
    void trigger(
        float sampleRate,
        int midiNote,
        float velocity,
        float kitDecay,
        float tone,
        float snappy,
        float panSpread
    ) {
        reset();
        velocity_ = isFinite(velocity) ? (velocity < 0.0f ? 0.0f : (velocity > 1.0f ? 1.0f : velocity)) : 0.8f;
        immutable double sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0 : cast(double) sampleRate;
        immutable double decScale = (isFinite(kitDecay) && kitDecay >= 0.1f) ? cast(double) kitDecay : 1.0;

        immutable int gm = midiNote >= 0 ? midiNote : 36;
        if (gm == 35 || gm == 36 || (gm % 12) == 0) {
            kind_ = DrumKind.kick;
            bodyFreqStart_ = 190.0;
            bodyFreqEnd_ = 45.0;
            pitchDecayRate_ = 32.0;
            bodyDecayMul_ = exp(-1.0 / (0.16 * decScale * sr));
            noiseDecayMul_ = exp(-1.0 / (0.008 * sr));
            pan_ = 0.0f;
            svf_.setParams(320.0f + 1200.0f * tone, 0.15f, cast(float) sr);
        } else if (gm == 38 || gm == 40 || (gm % 12) == 2 || (gm % 12) == 4) {
            kind_ = DrumKind.snare;
            bodyFreqStart_ = 310.0;
            bodyFreqEnd_ = 175.0;
            pitchDecayRate_ = 45.0;
            bodyDecayMul_ = exp(-1.0 / (0.08 * decScale * sr));
            noiseDecayMul_ = exp(-1.0 / (0.13 * decScale * sr));
            pan_ = -0.1f * panSpread;
            svf_.setParams(1400.0f + 4200.0f * tone, 0.25f, cast(float) sr);
        } else if (gm == 42 || gm == 44 || (gm % 12) == 6 || (gm % 12) == 8) {
            kind_ = DrumKind.closedHat;
            bodyFreqStart_ = 800.0;
            bodyFreqEnd_ = 800.0;
            pitchDecayRate_ = 10.0;
            bodyDecayMul_ = exp(-1.0 / (0.03 * decScale * sr));
            noiseDecayMul_ = exp(-1.0 / (0.035 * decScale * sr));
            pan_ = 0.45f * panSpread;
            svf_.setParams(5500.0f + 5000.0f * tone, 0.35f, cast(float) sr);
        } else if (gm == 46 || (gm % 12) == 10) {
            kind_ = DrumKind.openHat;
            bodyFreqStart_ = 850.0;
            bodyFreqEnd_ = 850.0;
            pitchDecayRate_ = 10.0;
            bodyDecayMul_ = exp(-1.0 / (0.12 * decScale * sr));
            noiseDecayMul_ = exp(-1.0 / (0.28 * decScale * sr));
            pan_ = 0.55f * panSpread;
            svf_.setParams(5200.0f + 5000.0f * tone, 0.35f, cast(float) sr);
        } else if (gm == 41 || gm == 43 || gm == 45) {
            kind_ = DrumKind.lowTom;
            bodyFreqStart_ = 165.0;
            bodyFreqEnd_ = 78.0;
            pitchDecayRate_ = 22.0;
            bodyDecayMul_ = exp(-1.0 / (0.18 * decScale * sr));
            noiseDecayMul_ = exp(-1.0 / (0.02 * sr));
            pan_ = -0.45f * panSpread;
            svf_.setParams(900.0f + 1600.0f * tone, 0.2f, cast(float) sr);
        } else if (gm == 47 || gm == 48 || gm == 50) {
            kind_ = DrumKind.highTom;
            bodyFreqStart_ = 260.0;
            bodyFreqEnd_ = 128.0;
            pitchDecayRate_ = 25.0;
            bodyDecayMul_ = exp(-1.0 / (0.15 * decScale * sr));
            noiseDecayMul_ = exp(-1.0 / (0.02 * sr));
            pan_ = 0.35f * panSpread;
            svf_.setParams(1200.0f + 2200.0f * tone, 0.2f, cast(float) sr);
        } else {
            kind_ = DrumKind.perc;
            immutable double pitchFactor = 1.0 + cast(double)(gm % 12) * 0.12;
            bodyFreqStart_ = 480.0 * pitchFactor;
            bodyFreqEnd_ = 260.0 * pitchFactor;
            pitchDecayRate_ = 40.0;
            bodyDecayMul_ = exp(-1.0 / (0.11 * decScale * sr));
            noiseDecayMul_ = exp(-1.0 / (0.06 * decScale * sr));
            pan_ = ((gm & 1) != 0 ? -0.4f : 0.4f) * panSpread;
            svf_.setParams(2200.0f + 3500.0f * tone, 0.3f, cast(float) sr);
        }

        bodyEnv_ = 1.0;
        noiseEnv_ = kind_ == DrumKind.kick ? 0.35 * snappy : (0.6 + 0.6 * snappy);
        active_ = true;
    }

    /**
     * Marks open hi-hat / percussive release damping when NoteOff arrives.
     */
    void releaseNote() {
        releasing_ = true;
        if (kind_ == DrumKind.openHat) {
            noiseDecayMul_ = 0.996;
        }
    }

    /**
     * Reports whether voice envelopes remain above silence threshold.
     *
     * Returns:
     *   True if active.
     */
    bool isActive() const pure @safe {
        return active_;
    }

    /**
     * Reports whether release damping has been initiated.
     *
     * Returns:
     *   True when releasing.
     */
    bool isReleasing() const pure @safe {
        return releasing_;
    }

    /**
     * Returns approximate amplitude level for VoicePool victim prioritization.
     *
     * Returns:
     *   Current combined body and noise envelope level.
     */
    float currentLevel() const pure @safe {
        return cast(float)(bodyEnv_ + noiseEnv_) * velocity_;
    }

    /**
     * Synthesizes one slice and adds stereo panned samples into outL/outR.
     *
     * Params:
     *   outL = Left output slice.
     *   outR = Right output slice.
     *   frames = Frame count for this slice.
     *   sampleRate = Active sample rate in Hertz.
     *   snappy = Noise transient scaling [0..1].
     */
    void renderAdd(float[] outL, float[] outR, uint frames, float sampleRate, float snappy) {
        if (!active_) {
            return;
        }
        immutable double sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0 : cast(double) sampleRate;
        immutable double dt = 1.0 / sr;
        immutable float gainL = 0.7071f * (1.0f - pan_);
        immutable float gainR = 0.7071f * (1.0f + pan_);
        immutable bool isHat = (kind_ == DrumKind.closedHat || kind_ == DrumKind.openHat);

        foreach (i; 0 .. frames) {
            immutable double instHz = bodyFreqEnd_
                + (bodyFreqStart_ - bodyFreqEnd_) * exp(-elapsed_ * pitchDecayRate_);
            bodyOsc_.setFrequency(cast(float) instHz, cast(float) sr);
            harmonicOsc_.setFrequency(cast(float)(instHz * 1.63), cast(float) sr);

            double bodySig = cast(double) bodyOsc_.nextSample(OscWaveform.sine) * bodyEnv_;
            double noiseSig = cast(double) noise_.white();
            if (isHat) {
                immutable float sq = bodyOsc_.nextSample(OscWaveform.pulse, 0.5f)
                    * harmonicOsc_.nextSample(OscWaveform.pulse, 0.37f);
                noiseSig = svf_.processSample(cast(float)(0.65 * noiseSig + 0.35 * cast(double) sq), SvfMode.hpf);
                bodySig = 0.0;
            } else if (kind_ == DrumKind.snare) {
                noiseSig = svf_.processSample(cast(float) noiseSig, SvfMode.bpf);
            } else {
                noiseSig = svf_.processSample(cast(float) noiseSig, SvfMode.lpf);
            }

            immutable double mixed = (bodySig + noiseSig * noiseEnv_ * (0.4 + 0.6 * snappy))
                * cast(double) velocity_;
            immutable float shaped = cast(float) tanh(mixed);
            outL[i] += shaped * gainL;
            outR[i] += shaped * gainR;

            elapsed_ += dt;
            bodyEnv_ *= bodyDecayMul_;
            noiseEnv_ *= noiseDecayMul_;
        }

        if (bodyEnv_ < 1e-6 && noiseEnv_ < 1e-6) {
            active_ = false;
        }
    }
}

/**
 * 8-voice GM-mapped synthesized drum kit built on VoicePool!(DrumVoice, 8).
 */
struct DrumSynth {
    enum string typeId = "synth.drumsynth";
    enum string displayName = "DrumSynth";
    enum ModuleCategory category = ModuleCategory.synth;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Kit Decay", 0.2f, 2.5f, 1.0f, "x", ParamScale.linear)
    float kitDecay = 1.0f;

    @Param("Tone", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float tone = 0.5f;

    @Param("Snappy", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float snappy = 0.5f;

    @Param("Pan Spread", 0.0f, 1.0f, 0.4f, "", ParamScale.linear)
    float panSpread = 0.4f;

    @Param("Master Vol", 0.0f, 1.0f, 0.8f, "", ParamScale.linear)
    float masterVol = 0.8f;

    private VoicePool!(DrumVoice, 8) voices_;
    private float sampleRate_ = 44_100.0f;

    @nogc nothrow:

    /**
     * Prepares the 8-voice drum VoicePool for sampleRate.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        reset();
    }

    /**
     * Stops and resets all active drum voices cleanly.
     */
    void reset() {
        voices_.resetAll();
    }

    /**
     * Handles incoming note triggers, chokes, and panic releases.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active audio sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        if (ev.kind == ModEventKind.noteOn) {
            bool stolen = false;
            DrumVoice* v = voices_.allocateVoice(ev.noteId, stolen);
            if (v !is null) {
                immutable int midiNote = isFinite(ev.valueA) ? cast(int)(ev.valueA + 0.5f) : 36;
                v.trigger(sampleRate_, midiNote, ev.valueB, kitDecay, tone, snappy, panSpread);
            }
        } else if (ev.kind == ModEventKind.noteOff) {
            voices_.releaseVoice(ev.noteId);
        } else if (ev.kind == ModEventKind.allNotesOff) {
            voices_.allNotesOff();
        }
    }

    /**
     * Synthesizes active drum voices into stereo audioOut with automatic idle skipping.
     *
     * Params:
     *   audioIn = Unused stereo input slices.
     *   audioOut = Destination stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True if any voice produced non-silent output or remains active.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        cast(void) audioIn;
        voices_.deactivateFinished();
        if (!voices_.hasActiveVoices()) {
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
        immutable float sn = snappy;

        voices_.forEachActive((ref DrumVoice v, NoteId id) @nogc nothrow {
            cast(void) id;
            v.renderAdd(outL, outR, frames, sr, sn);
        });

        immutable float mv = isFinite(masterVol) ? masterVol : 0.8f;
        float peak = 0.0f;
        foreach (i; 0 .. frames) {
            immutable float yL = outL[i] * mv;
            immutable float yR = outR[i] * mv;
            outL[i] = yL;
            outR[i] = yR;
            immutable float al = fabs(yL);
            immutable float ar = fabs(yR);
            if (al > peak) peak = al;
            if (ar > peak) peak = ar;
        }

        return peak > 1e-7f || voices_.hasActiveVoices();
    }
}
