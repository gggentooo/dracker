/**
 * File:         source/modules/synths/kicker.d
 * Module:       modules.synths.kicker
 * Phase:        Phase 4.3 (Tier 1) — Pitch-Swept Percussion Synthesizer
 *
 * Purpose:
 *   Synthesizes punchy kick drums with exponential pitch sweep, click transient drive, and clean amplitude decay termination.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; explicit zero-init state and automatic idle bypass after decay completes.
 *
 * Dependencies:
 *   Internal: dsp.oscillator, graph.context, graph.event, graph.module_api, graph.port
 *   External: std.math (exp, fabs, isFinite, pow, tanh)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Kicker (typeId = "synth.kicker", ports: event in, audioStereo out)
 *   - @Param waveform, pitchStartHz, pitchEndHz, sweepTimeMs, decayMs, clickDrive
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.kicker;

import std.math : exp, fabs, isFinite, pow, tanh;

import dsp.oscillator : OscWaveform, PolyBlepOsc;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Pitch-swept percussion drum generator with configurable waveform, sweep curve, and click transient.
 */
struct Kicker {
    enum string typeId = "synth.kicker";
    enum string displayName = "Kicker";
    enum ModuleCategory category = ModuleCategory.synth;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Waveform", 0.0f, 2.0f, 0.0f, "", ParamScale.discrete)
    float waveform = 0.0f;

    @Param("Pitch Start", 40.0f, 2000.0f, 220.0f, "Hz", ParamScale.logarithmic)
    float pitchStartHz = 220.0f;

    @Param("Pitch End", 20.0f, 400.0f, 48.0f, "Hz", ParamScale.logarithmic)
    float pitchEndHz = 48.0f;

    @Param("Sweep Time", 1.0f, 500.0f, 45.0f, "ms", ParamScale.logarithmic)
    float sweepTimeMs = 45.0f;

    @Param("Decay", 10.0f, 2000.0f, 220.0f, "ms", ParamScale.logarithmic)
    float decayMs = 220.0f;

    @Param("Click Drive", 0.0f, 1.0f, 0.35f, "", ParamScale.linear)
    float clickDrive = 0.35f;

    private PolyBlepOsc osc_;
    private float sampleRate_ = 44_100.0f;
    private double elapsedSec_ = 0.0;
    private double ampEnv_ = 0.0;
    private double clickEnv_ = 0.0;
    private float velocity_ = 1.0f;
    private float pitchScale_ = 1.0f;
    private bool active_ = false;

    @nogc nothrow:

    /**
     * Initializes oscillator state for sampleRate and resets active kick state.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        reset();
    }

    /**
     * Silences and resets pitch sweep phase and envelope states immediately.
     */
    void reset() {
        osc_.reset();
        elapsedSec_ = 0.0;
        ampEnv_ = 0.0;
        clickEnv_ = 0.0;
        velocity_ = 1.0f;
        pitchScale_ = 1.0f;
        active_ = false;
    }

    /**
     * Triggers the drum sweep on NoteOn or chokes on NoteOff/AllNotesOff.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        if (ev.kind == ModEventKind.noteOn) {
            osc_.reset();
            elapsedSec_ = 0.0;
            ampEnv_ = 1.0;
            clickEnv_ = 1.0;
            velocity_ = isFinite(ev.valueB)
                ? (ev.valueB < 0.0f ? 0.0f : (ev.valueB > 1.0f ? 1.0f : ev.valueB)) : 1.0f;
            immutable float midiNote = isFinite(ev.valueA) ? ev.valueA : 36.0f;
            pitchScale_ = cast(float) exp(cast(double)(midiNote - 36.0f) * 0.05776226504666211);
            if (pitchScale_ < 0.25f) pitchScale_ = 0.25f;
            if (pitchScale_ > 4.0f) pitchScale_ = 4.0f;
            active_ = true;
        } else if (ev.kind == ModEventKind.allNotesOff) {
            active_ = false;
            ampEnv_ = 0.0;
        } else if (ev.kind == ModEventKind.noteOff) {
            ampEnv_ *= 0.25;
        }
    }

    /**
     * Synthesizes stereo pitch-swept percussion output until decay finishes.
     *
     * Params:
     *   audioIn = Unused input slices.
     *   audioOut = Output stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while drum envelope remains active; false when idle.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        cast(void) audioIn;
        if (!active_) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            return false;
        }

        immutable double sr = cast(double)(ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_);
        immutable double dt = 1.0 / (sr > 1.0 ? sr : 44_100.0);
        immutable double startHz = (isFinite(pitchStartHz) && pitchStartHz >= 20.0f ? cast(double) pitchStartHz : 220.0)
            * cast(double) pitchScale_;
        immutable double endHz = (isFinite(pitchEndHz) && pitchEndHz >= 20.0f ? cast(double) pitchEndHz : 48.0)
            * cast(double) pitchScale_;
        immutable double sweepSec = (isFinite(sweepTimeMs) && sweepTimeMs >= 1.0f ? cast(double) sweepTimeMs : 45.0) * 0.001;
        immutable double decSec = (isFinite(decayMs) && decayMs >= 5.0f ? cast(double) decayMs : 220.0) * 0.001;
        immutable double ampDecayMul = exp(-dt / (decSec * 0.35));
        immutable double clickDecayMul = exp(-dt / 0.004);
        immutable double drv = isFinite(clickDrive)
            ? (clickDrive < 0.0f ? 0.0 : (clickDrive > 1.0f ? 1.0 : cast(double) clickDrive)) : 0.35;

        OscWaveform wf = OscWaveform.sine;
        immutable int wfIdx = isFinite(waveform) ? cast(int)(waveform + 0.5f) : 0;
        if (wfIdx == 1) {
            wf = OscWaveform.triangle;
        } else if (wfIdx >= 2) {
            wf = OscWaveform.pulse;
        }

        auto outL = ioSlice(audioOut[0], ctx.frames);
        auto outR = ioSlice(audioOut[1], ctx.frames);
        float peak = 0.0f;

        foreach (i; 0 .. ctx.frames) {
            immutable double sweepRatio = exp(-elapsedSec_ / (sweepSec > 0.0005 ? sweepSec : 0.0005));
            immutable double instHz = endHz + (startHz - endHz) * sweepRatio;
            osc_.setFrequency(cast(float) instHz, cast(float) sr);

            double sample = cast(double) osc_.nextSample(wf, 0.5f);
            sample += drv * 0.45 * clickEnv_;
            if (drv > 0.01) {
                sample = tanh(sample * (1.0 + drv * 2.5)) / (1.0 + drv * 0.5);
            }
            immutable float finalSample = cast(float)(sample * ampEnv_ * cast(double) velocity_);

            outL[i] = finalSample;
            outR[i] = finalSample;
            immutable float af = fabs(finalSample);
            if (af > peak) peak = af;

            elapsedSec_ += dt;
            ampEnv_ *= ampDecayMul;
            clickEnv_ *= clickDecayMul;
        }

        if (ampEnv_ < 1e-6 && elapsedSec_ > 0.005) {
            active_ = false;
            ampEnv_ = 0.0;
        }

        return peak > 1e-7f || active_;
    }

    private static float[] ioSlice(float[] s, uint n) @nogc nothrow pure @safe {
        return s[0 .. n];
    }
}
