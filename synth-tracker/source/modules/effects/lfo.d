/**
 * File:         source/modules/effects/lfo.d
 * Module:       modules.effects.lfo
 * Phase:        Phase 4.2 (Tier 1) — Audio-Rate & CV LFO / Amplitude Modulator
 *
 * Purpose:
 *   Generates smooth 64-sample audio-rate CV modulation buffers (PortKind.cvControl) eliminating 172 Hz zipper artifacts and optionally modulates stereo audio amplitude/panning.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; deterministic sample-and-hold PRNG and explicit zero-init phase accumulator.
 *
 * Dependencies:
 *   Internal: dsp.oscillator, dsp.tables, dsp.smoother, graph.buffer, graph.context, graph.module_api, graph.port
 *   External: std.math (fabs, floor, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct LfoMod (typeId = "fx.lfo", ports: audioStereo in/out, cvControl cvOut)
 *   - @Param waveform, freq, syncUnit, amplitude, phaseOffset, stereoSpread
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.lfo;

import std.math : fabs, floor, isFinite;

import dsp.oscillator : DeterministicNoise;
import dsp.smoother : ParamSmoother;
import dsp.tables : lookupSine;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Dual-role audio-rate CV low-frequency oscillator and stereo tremolo/amplitude modulator.
 */
struct LfoMod {
    enum string typeId = "fx.lfo";
    enum string displayName = "LFO";
    enum ModuleCategory category = ModuleCategory.control;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Audio In", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output),
        PortDescriptor("cvOut", "CV Out", PortKind.cvControl, PortDirection.output)
    ];

    @Param("Waveform", 0.0f, 4.0f, 0.0f, "", ParamScale.discrete)
    float waveform = 0.0f;

    @Param("Frequency", 0.01f, 100.0f, 2.0f, "Hz", ParamScale.logarithmic)
    float freq = 2.0f;

    @Param("Sync Unit", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete)
    float syncUnit = 0.0f;

    @Param("Amplitude", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float amplitude = 1.0f;

    @Param("Phase Offset", 0.0f, 1.0f, 0.0f, "", ParamScale.linear)
    float phaseOffset = 0.0f;

    @Param("Stereo Spread", 0.0f, 0.5f, 0.0f, "", ParamScale.linear)
    float stereoSpread = 0.0f;

    private double phase_ = 0.0;
    private float sampleRate_ = 44_100.0f;
    private ParamSmoother ampSmoother_;
    private DeterministicNoise rng_;
    private float heldRand_ = 0.0f;
    private double prevPhase_ = 0.0;

    @nogc nothrow:

    /**
     * Initializes amplitude smoother and resets oscillator phase cleanly.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        ampSmoother_.prepare(sampleRate_, 5.0f, amplitude);
        reset();
    }

    /**
     * Resets oscillator phase, sample-and-hold PRNG, and amplitude smoother.
     */
    void reset() {
        phase_ = 0.0;
        prevPhase_ = 0.0;
        rng_.reset(0x4C46_4F31u);
        heldRand_ = 0.0f;
        ampSmoother_.reset(amplitude);
    }

    /**
     * Updates amplitude smoother on parameter updates.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap without ramping.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        static if (field == "amplitude") {
            ampSmoother_.setTarget(amplitude, instant);
        }
    }

    /**
     * Generates audio-rate CV waveforms and modulates stereo input audio cleanly.
     *
     * Params:
     *   io = Stereo audio input/output plus cvControl output slot.
     *   ctx = Per-slice processing context.
     *
     * Returns:
     *   True while amplitude > silence threshold or audio output is active.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable bool beatSync = syncUnit >= 0.5f;
        immutable float f = isFinite(freq) ? (freq < 0.01f ? 0.01f : (freq > 100.0f ? 100.0f : freq)) : 2.0f;
        immutable double bpm = ctx.transport.bpm > 1.0 ? ctx.transport.bpm : 125.0;
        immutable double hz = beatSync ? (bpm / 60.0) / cast(double) f : cast(double) f;
        immutable double phaseInc = hz / cast(double)(sr > 1.0f ? sr : 44_100.0f);

        immutable int wf = isFinite(waveform) ? cast(int)(waveform + 0.5f) : 0;
        immutable float pOff = isFinite(phaseOffset) ? phaseOffset : 0.0f;
        immutable float spread = isFinite(stereoSpread)
            ? (stereoSpread < 0.0f ? 0.0f : (stereoSpread > 0.5f ? 0.5f : stereoSpread)) : 0.0f;

        immutable bool hasCvOut = io.numCvOut > 0 && io.cvOut[0].samples.length >= ctx.frames;
        const inL = io.audioIn[0];
        const inR = io.audioIn[1];
        auto outL = io.audioOut[0];
        auto outR = io.audioOut[1];
        immutable bool hasAudioIn = !ctx.inputSilent && inL.length >= ctx.frames && inR.length >= ctx.frames;
        immutable bool hasAudioOut = outL.length >= ctx.frames && outR.length >= ctx.frames;

        float maxActivity = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            immutable float amp = ampSmoother_.next();
            if (phase_ < prevPhase_) {
                heldRand_ = rng_.white();
            }
            prevPhase_ = phase_;

            immutable float phL = wrap01(cast(float) phase_ + pOff);
            immutable float phR = wrap01(phL + spread);
            immutable float lfoL = evaluateWave(wf, phL, heldRand_) * amp;
            immutable float lfoR = evaluateWave(wf, phR, heldRand_) * amp;

            if (hasCvOut) {
                io.cvOut[0].samples[i] = lfoL;
                immutable float acv = fabs(lfoL);
                if (acv > maxActivity) maxActivity = acv;
            }

            if (hasAudioOut) {
                if (!hasAudioIn) {
                    outL[i] = 0.0f;
                    outR[i] = 0.0f;
                } else {
                    immutable float modL = 1.0f - 0.5f * amp * (1.0f - lfoL);
                    immutable float modR = 1.0f - 0.5f * amp * (1.0f - lfoR);
                    immutable float xL = isFinite(inL[i]) ? inL[i] : 0.0f;
                    immutable float xR = isFinite(inR[i]) ? inR[i] : 0.0f;
                    immutable float yL = xL * modL;
                    immutable float yR = xR * modR;
                    outL[i] = yL;
                    outR[i] = yR;
                    immutable float ayL = fabs(yL);
                    immutable float ayR = fabs(yR);
                    if (ayL > maxActivity) maxActivity = ayL;
                    if (ayR > maxActivity) maxActivity = ayR;
                }
            }

            phase_ += phaseInc;
            if (phase_ >= 1.0) {
                phase_ -= floor(phase_);
            }
        }

        return maxActivity > 1e-7f || hasAudioIn || (hasCvOut && ampSmoother_.current() > 1e-7f);
    }

    private static float wrap01(float p) pure @safe {
        if (!isFinite(p)) return 0.0f;
        double w = cast(double) p - floor(cast(double) p);
        if (w < 0.0 || w >= 1.0) w = 0.0;
        return cast(float) w;
    }

    private static float evaluateWave(int wf, float p, float randVal) pure @safe {
        switch (wf) {
            case 1:
                return 1.0f - 4.0f * fabs(p - 0.5f);
            case 2:
                return 2.0f * p - 1.0f;
            case 3:
                return p < 0.5f ? 1.0f : -1.0f;
            case 4:
                return randVal;
            default:
                return lookupSine(p);
        }
    }
}
