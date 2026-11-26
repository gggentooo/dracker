/**
 * File:         source/modules/synths/fm_synth.d
 * Module:       modules.synths.fm_synth
 * Phase:        Phase 4.3 (Tier 1) — 4/5-Operator FM Synthesizer
 *
 * Purpose:
 *   Polyphonic 5-operator phase-modulation FM synthesizer with 6 routing algorithms, operator self-feedback, per-operator frequency ratios/levels, ADSR shaping, and VoicePool voice allocation.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init operator phase and feedback registers.
 *
 * Dependencies:
 *   Internal: dsp.envelope, dsp.tables, dsp.voice_pool, foundation.math_rt, foundation.types, graph.context, graph.event, graph.module_api, graph.port
 *   External: std.math (fabs, floor, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct FmSynth (typeId = "synth.fm_synth", ports: event in, audioStereo out)
 *   - @Param algorithm, feedback, op1Ratio..op5Ratio, op1Level..op5Level, attackMs, decayMs, sustain, releaseMs
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.fm_synth;

import std.math : fabs, floor, isFinite;

import dsp.envelope : AdsrEnvelope;
import dsp.tables : lookupSine;
import dsp.voice_pool : VoicePool;
import foundation.math_rt : midiNoteToHz;
import foundation.types : NoteId;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Polyphonic 5-operator FM voice supporting 6 modulation algorithms and operator-5 self-feedback.
 */
struct FmVoice {
    private double[5] phase_ = 0.0;
    private double[5] phaseInc_ = 0.0;
    private float op5Prev_ = 0.0f;
    private float op5Prev2_ = 0.0f;
    private AdsrEnvelope ampEnv_;
    private AdsrEnvelope modEnv_;
    private float baseMidiNote_ = 60.0f;
    private float velocity_ = 1.0f;

    @nogc nothrow:

    /**
     * Clears operator phase accumulators, feedback history, and envelopes.
     */
    void reset() {
        phase_[] = 0.0;
        phaseInc_[] = 0.0;
        op5Prev_ = 0.0f;
        op5Prev2_ = 0.0f;
        ampEnv_.reset();
        modEnv_.reset();
        baseMidiNote_ = 60.0f;
        velocity_ = 1.0f;
    }

    /**
     * Triggers one polyphonic FM note.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   midiNote = Fractional MIDI note pitch.
     *   vel = Normalized note velocity [0..1].
     *   ratios = Frequency multiplier ratios for operators 1..5.
     *   bendSemitones = Shared pitch bend offset in semitones.
     *   attackSec = Amplitude attack time in seconds.
     *   decaySec = Amplitude decay time in seconds.
     *   sustain = Sustain level [0..1].
     *   releaseSec = Release time in seconds.
     */
    void trigger(
        float sampleRate,
        float midiNote,
        float vel,
        const(float)[5] ratios,
        float bendSemitones,
        float attackSec,
        float decaySec,
        float sustain,
        float releaseSec
    ) {
        reset();
        baseMidiNote_ = isFinite(midiNote) ? midiNote : 60.0f;
        velocity_ = isFinite(vel) ? (vel < 0.0f ? 0.0f : (vel > 1.0f ? 1.0f : vel)) : 0.8f;
        updatePitch(sampleRate, ratios, bendSemitones);

        ampEnv_.prepare(sampleRate);
        ampEnv_.setParams(attackSec, decaySec, sustain, releaseSec);
        ampEnv_.setCurves(1.0f, 3.0f, 3.0f);
        ampEnv_.trigger(false);

        modEnv_.prepare(sampleRate);
        modEnv_.setParams(attackSec * 0.8f, decaySec * 0.7f, sustain * 0.75f, releaseSec);
        modEnv_.setCurves(1.0f, 2.5f, 2.5f);
        modEnv_.trigger(false);
    }

    /**
     * Updates operator phase increments on pitch bend, ratio change, or per-note slide.
     *
     * Params:
     *   sampleRate = Sample rate in Hertz.
     *   ratios = Frequency ratios for operators 1..5.
     *   bendSemitones = Pitch bend offset in semitones.
     */
    void updatePitch(float sampleRate, const(float)[5] ratios, float bendSemitones) {
        immutable double sr = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0 : cast(double) sampleRate;
        immutable float pitch = baseMidiNote_ + (isFinite(bendSemitones) ? bendSemitones : 0.0f);
        immutable double baseHz = cast(double) midiNoteToHz(pitch);
        foreach (k; 0 .. 5) {
            immutable double r = (isFinite(ratios[k]) && ratios[k] > 0.01f) ? cast(double) ratios[k] : 1.0;
            double f = baseHz * r;
            if (f > 0.48 * sr) f = 0.48 * sr;
            phaseInc_[k] = f / sr;
        }
    }

    /**
     * Releases both carrier and modulator envelopes cleanly.
     */
    void releaseNote() {
        ampEnv_.releaseNote();
        modEnv_.releaseNote();
    }

    /**
     * Checks whether the amplitude envelope remains active.
     *
     * Returns:
     *   True while active.
     */
    bool isActive() const pure @safe {
        return ampEnv_.isActive();
    }

    /**
     * Checks whether release stage has started.
     *
     * Returns:
     *   True when releasing.
     */
    bool isReleasing() const pure @safe {
        return ampEnv_.isReleasing();
    }

    /**
     * Returns approximate output amplitude for VoicePool stealing priority.
     *
     * Returns:
     *   Amplitude envelope level scaled by velocity.
     */
    float currentLevel() const pure @safe {
        return ampEnv_.value() * velocity_;
    }

    /**
     * Evaluates the 5-operator modulation network and accumulates stereo audio into outL/outR.
     *
     * Params:
     *   outL = Destination left sample buffer.
     *   outR = Destination right sample buffer.
     *   frames = Frame count for this slice.
     *   algo = Algorithm selector [0..5].
     *   fb = Operator-5 self-feedback [0..1].
     *   levels = Output/modulation indices for operators 1..5.
     */
    void renderAdd(
        float[] outL,
        float[] outR,
        uint frames,
        int algo,
        float fb,
        const(float)[5] levels
    ) {
        immutable float fbDepth = fb * 0.45f;
        foreach (i; 0 .. frames) {
            immutable float aEnv = ampEnv_.next();
            immutable float mEnv = modEnv_.next();

            immutable float fbPhase = 0.5f * (op5Prev_ + op5Prev2_) * fbDepth;
            immutable float op5 = lookupSine(cast(float) phase_[4] + fbPhase) * levels[4] * mEnv;
            op5Prev2_ = op5Prev_;
            op5Prev_ = op5;

            float carL = 0.0f;
            float carR = 0.0f;

            switch (algo) {
                case 1: {
                    immutable float op4 = lookupSine(cast(float) phase_[3] + op5 * 1.4f) * levels[3] * mEnv;
                    immutable float op3 = lookupSine(cast(float) phase_[2] + op4 * 1.4f) * levels[2] * mEnv;
                    immutable float op2 = lookupSine(cast(float) phase_[1] + op4 * 1.1f) * levels[1] * mEnv;
                    immutable float c1 = lookupSine(cast(float) phase_[0] + op3 * 1.5f) * levels[0];
                    immutable float c2 = lookupSine(cast(float) phase_[0] + op2 * 1.5f) * levels[0] * 0.5f;
                    carL = (c1 + c2 * 0.6f);
                    carR = (c1 - c2 * 0.6f);
                    break;
                }
                case 2: {
                    immutable float op4 = lookupSine(cast(float) phase_[3]) * levels[3] * mEnv;
                    immutable float op2 = lookupSine(cast(float) phase_[1] + op4 * 1.4f) * levels[1] * mEnv;
                    immutable float c1 = lookupSine(cast(float) phase_[0] + op2 * 1.5f) * levels[0];
                    immutable float c3 = lookupSine(cast(float) phase_[2] + op5 * 1.5f) * levels[2];
                    carL = 0.6f * c1 + 0.4f * c3;
                    carR = 0.4f * c1 + 0.6f * c3;
                    break;
                }
                case 3: {
                    immutable float modSum = (lookupSine(cast(float) phase_[1]) * levels[1]
                        + lookupSine(cast(float) phase_[2]) * levels[2]
                        + lookupSine(cast(float) phase_[3]) * levels[3]
                        + op5) * mEnv;
                    immutable float c1 = lookupSine(cast(float) phase_[0] + modSum * 0.9f) * levels[0];
                    carL = c1;
                    carR = c1;
                    break;
                }
                case 4: {
                    immutable float op4 = lookupSine(cast(float) phase_[3] + op5 * 1.3f) * levels[3];
                    immutable float op2 = lookupSine(cast(float) phase_[1] + op4 * 1.3f) * levels[1];
                    immutable float c1 = lookupSine(cast(float) phase_[0]) * levels[0];
                    immutable float c3 = lookupSine(cast(float) phase_[2] + op4 * 0.9f) * levels[2];
                    immutable float m = (c1 + 0.5f * op2 * mEnv + 0.5f * c3);
                    carL = m * 0.7f;
                    carR = m * 0.7f;
                    break;
                }
                case 5: {
                    immutable float s1 = lookupSine(cast(float) phase_[0]) * levels[0];
                    immutable float s2 = lookupSine(cast(float) phase_[1]) * levels[1];
                    immutable float s3 = lookupSine(cast(float) phase_[2]) * levels[2];
                    immutable float s4 = lookupSine(cast(float) phase_[3]) * levels[3];
                    carL = (s1 + 0.8f * s2 + 0.6f * s3 + 0.4f * s4 + 0.5f * op5) * 0.35f;
                    carR = (s1 + 0.6f * s2 + 0.8f * s3 + 0.5f * s4 + 0.4f * op5) * 0.35f;
                    break;
                }
                default: {
                    immutable float op4 = lookupSine(cast(float) phase_[3] + op5 * 1.35f) * levels[3] * mEnv;
                    immutable float op3 = lookupSine(cast(float) phase_[2] + op4 * 1.35f) * levels[2] * mEnv;
                    immutable float op2 = lookupSine(cast(float) phase_[1] + op3 * 1.35f) * levels[1] * mEnv;
                    immutable float c1 = lookupSine(cast(float) phase_[0] + op2 * 1.45f) * levels[0];
                    carL = c1;
                    carR = c1;
                    break;
                }
            }

            immutable float outScale = aEnv * velocity_;
            outL[i] += carL * outScale;
            outR[i] += carR * outScale;

            foreach (k; 0 .. 5) {
                phase_[k] += phaseInc_[k];
                if (phase_[k] >= 1.0) {
                    phase_[k] -= floor(phase_[k]);
                }
            }
        }
    }
}

/**
 * 16-voice polyphonic 5-operator FM synthesizer built on VoicePool!(FmVoice, 16).
 */
struct FmSynth {
    enum string typeId = "synth.fm_synth";
    enum string displayName = "FM Synth";
    enum ModuleCategory category = ModuleCategory.synth;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Algorithm", 0.0f, 5.0f, 0.0f, "", ParamScale.discrete,
        ["Serial", "Split Branches", "Two Stacks", "Four Into One", "Carrier + Stacks", "Additive"])
    float algorithm = 0.0f;

    @Param("Feedback", 0.0f, 1.0f, 0.2f, "", ParamScale.linear)
    float feedback = 0.2f;

    @Param("Op1 Ratio", 0.5f, 16.0f, 1.0f, "x", ParamScale.logarithmic)
    float op1Ratio = 1.0f;

    @Param("Op2 Ratio", 0.5f, 16.0f, 2.0f, "x", ParamScale.logarithmic)
    float op2Ratio = 2.0f;

    @Param("Op3 Ratio", 0.5f, 16.0f, 3.0f, "x", ParamScale.logarithmic)
    float op3Ratio = 3.0f;

    @Param("Op4 Ratio", 0.5f, 16.0f, 4.0f, "x", ParamScale.logarithmic)
    float op4Ratio = 4.0f;

    @Param("Op5 Ratio", 0.5f, 16.0f, 1.0f, "x", ParamScale.logarithmic)
    float op5Ratio = 1.0f;

    @Param("Op1 Level", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float op1Level = 1.0f;

    @Param("Op2 Level", 0.0f, 1.0f, 0.55f, "", ParamScale.linear)
    float op2Level = 0.55f;

    @Param("Op3 Level", 0.0f, 1.0f, 0.35f, "", ParamScale.linear)
    float op3Level = 0.35f;

    @Param("Op4 Level", 0.0f, 1.0f, 0.2f, "", ParamScale.linear)
    float op4Level = 0.2f;

    @Param("Op5 Level", 0.0f, 1.0f, 0.25f, "", ParamScale.linear)
    float op5Level = 0.25f;

    @Param("Attack", 1.0f, 2000.0f, 5.0f, "ms", ParamScale.logarithmic)
    float attackMs = 5.0f;

    @Param("Decay", 5.0f, 4000.0f, 250.0f, "ms", ParamScale.logarithmic)
    float decayMs = 250.0f;

    @Param("Sustain", 0.0f, 1.0f, 0.6f, "", ParamScale.linear)
    float sustain = 0.6f;

    @Param("Release", 5.0f, 5000.0f, 220.0f, "ms", ParamScale.logarithmic)
    float releaseMs = 220.0f;

    private VoicePool!(FmVoice, 16) voices_;
    private float sampleRate_ = 44_100.0f;
    private float pitchBendSemitones_ = 0.0f;

    @nogc nothrow:

    /**
     * Configures initial sample rate and resets all FM voices.
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
     * Silences all FM voices and clears channel pitch bend immediately.
     */
    void reset() {
        voices_.resetAll();
        pitchBendSemitones_ = 0.0f;
    }

    /**
     * Updates active operator frequencies when operator ratios change.
     *
     * Params:
     *   sampleRate = Active audio sample rate in Hertz.
     *   instant = Unused for frequency updates.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) instant;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        static if (field == "op1Ratio" || field == "op2Ratio" || field == "op3Ratio"
                || field == "op4Ratio" || field == "op5Ratio") {
            immutable float sr = sampleRate_;
            immutable float[5] r = currentRatios();
            immutable float bend = pitchBendSemitones_;
            voices_.forEachActive((ref FmVoice v, NoteId id) @nogc nothrow {
                cast(void) id;
                v.updatePitch(sr, r, bend);
            });
        }
    }

    /**
     * Handles NoteOn, NoteOff, SetPitch, SetVelocity, and AllNotesOff ModEvents.
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
                FmVoice* v = voices_.allocateVoice(ev.noteId, stolen);
                if (v !is null) {
                    v.trigger(
                        sampleRate_,
                        ev.valueA,
                        ev.valueB,
                        currentRatios(),
                        pitchBendSemitones_,
                        attackMs * 0.001f,
                        decayMs * 0.001f,
                        sustain,
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
                    immutable float sr = sampleRate_;
                    immutable float[5] r = currentRatios();
                    immutable float bend = pitchBendSemitones_;
                    voices_.forEachActive((ref FmVoice v, NoteId id) @nogc nothrow {
                        cast(void) id;
                        v.updatePitch(sr, r, bend);
                    });
                } else {
                    FmVoice* v = voices_.findVoice(ev.noteId);
                    if (v !is null) {
                        v.baseMidiNote_ = isFinite(ev.valueA) ? ev.valueA : v.baseMidiNote_;
                        v.updatePitch(sampleRate_, currentRatios(), pitchBendSemitones_);
                    }
                }
                break;

            default:
                break;
        }
    }

    /**
     * Synthesizes active polyphonic FM voices into stereo audioOut with silent-tail deactivation.
     *
     * Params:
     *   audioIn = Unused stereo input slices.
     *   audioOut = Destination stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while audio or active FM voices remain audible.
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

        immutable uint frames = ctx.frames;
        immutable int algo = isFinite(algorithm) ? cast(int)(algorithm + 0.5f) : 0;
        immutable float fb = isFinite(feedback) ? (feedback < 0.0f ? 0.0f : (feedback > 1.0f ? 1.0f : feedback)) : 0.2f;
        immutable float[5] lvls = [
            clampLevel(op1Level),
            clampLevel(op2Level),
            clampLevel(op3Level),
            clampLevel(op4Level),
            clampLevel(op5Level)
        ];

        voices_.forEachActive((ref FmVoice v, NoteId id) @nogc nothrow {
            cast(void) id;
            v.renderAdd(outL, outR, frames, algo, fb, lvls);
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

    private float[5] currentRatios() const pure @safe {
        return [op1Ratio, op2Ratio, op3Ratio, op4Ratio, op5Ratio];
    }

    private static float clampLevel(float x) pure @safe {
        if (!isFinite(x) || x < 0.0f) return 0.0f;
        if (x > 1.0f) return 1.0f;
        return x;
    }
}
