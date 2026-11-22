/**
 * File:         source/main.d
 * Module:       main
 * Phase:        Phase 3.4 / 8.6 — Application Entry Point (GUI + Headless CLI)
 *
 * Purpose:
 *   Provides the process entry point routing between the native macOS Metal studio GUI (StudioGUI version) and headless CLI modes (--list-devices and --cli-demo live CoreAudio/CoreMIDI synthesizer playback).
 *
 * Real-Time & Safety Contract:
 *   Main thread handles CLI parsing, device setup, CFRunLoop pumping, and hardware hot-plug reconciliation; CoreAudio render callback is extern(C) @nogc nothrow with zero GC allocations or D TLS accesses.
 *
 * Dependencies:
 *   Internal: app.gui_shell (StudioGUI only), foundation.types, foundation.concurrency, dsp.oscillator, dsp.envelope, dsp.filter_svf, dsp.smoother, dsp.voice_pool, graph.port, graph.event, graph.context, graph.module_api, graph.plan, graph.audio_graph, graph.registry, platform.interfaces, platform.macos.corefoundation, platform.macos.coreaudio, platform.macos.coremidi
 *   External: core.atomic, core.lifetime, core.stdc.stdlib, core.sys.posix.signal, core.sys.posix.time, std.conv, std.math, std.stdio, std.string
 *
 * Planned API (Types, Functions & Hooks):
 *   - int main(string[] args)
 *   - int runListDevices()
 *   - int runCliDemo(string[] args)
 *   - --studio-selftest -> app.studio_selftest.runStudioSelfTest() (macOS)
 *   - StudioGUI builds: no arguments / --gui / <file.msv> -> app.studio_app.runStudioApp(), --gallery ->
 *     app.gui_shell.runStudioGui(), --gui-selftest -> runGuiSelfTest()
 *   - struct CliDemoPolySynth (live @nogc ModuleAdapter polyphonic synth)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module main;

import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import core.lifetime : emplace;
import core.stdc.stdlib : calloc, free;
import core.sys.posix.signal : SIGINT, SIGTERM, signal;
import core.sys.posix.time : nanosleep, timespec;
import std.conv : to;
import std.math : fabs, isFinite, pow;
import std.stdio : stderr, stdout, writefln, writeln;
import std.string : startsWith;
import std.traits : hasIndirections;

import dsp.envelope : AdsrEnvelope;
import dsp.filter_svf : CytomicSvf, SvfMode;
import dsp.oscillator : OscWaveform, PolyBlepOsc;
import dsp.smoother : ParamSmoother;
import dsp.voice_pool : VoicePool;
import foundation.concurrency : Atomic, MpscRing, hasGcReference;
import foundation.math_rt : midiNoteToHz;
import foundation.types : FIXED_BLOCK_FRAMES, FrameTime, ModuleId, NoteId;
import graph.audio_graph : AudioGraph, GraphTelemetry;
import graph.context : ProcessContext, TransportState;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleAdapter, ModuleCategory, ModuleInstance, Param, ParamScale;
import graph.plan : GraphCompileError, GraphCompiler, GraphPlan, NodeSpec, WireSpec;
import graph.port : PortDescriptor, PortDirection, PortKind;
import graph.registry : ModuleRegistry;
import platform.interfaces;

version (StudioGUI) {
    import app.gui_shell : runGuiSelfTest, runStudioGui;
    import app.studio_app : runStudioApp;
}

version (OSX) {
    import platform.macos.corefoundation : CFRunLoopGetCurrent, CFRunLoopRunInMode, MachTimebase,
        kCFRunLoopDefaultMode;
    import platform.macos.coreaudio : CoreAudioDriver;
    import platform.macos.coremidi : CoreMidiDriver, CoreMidiRtContext, MidiNoteTracker,
        translateMidiPacketToModEvent;
}

private shared int gCliStopFlag = 0;

private extern(C) void handleCliSignal(int sig) @nogc nothrow {
    cast(void) sig;
    atomicStore!(MemoryOrder.rel)(gCliStopFlag, 1);
}

/**
 * Polyphonic synthesizer voice combining two detuned PolyBLEP oscillators, Cytomic SVF, and ADSR.
 */
struct CliDemoVoice {
    private PolyBlepOsc oscA_;
    private PolyBlepOsc oscB_;
    private CytomicSvf filter_;
    private AdsrEnvelope env_;
    private float baseMidiNote_ = 60.0f;
    private float velocity_ = 1.0f;

    @nogc nothrow:

    /**
     * Resets voice oscillator phases, filter state, and envelope to idle.
     */
    void reset() {
        oscA_.reset();
        oscB_.reset();
        filter_.reset();
        env_.reset();
        baseMidiNote_ = 60.0f;
        velocity_ = 1.0f;
    }

    /**
     * Triggers the voice at midiNote and velocity with global envelope and filter settings.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   midiNote = Fractional MIDI note pitch.
     *   vel = Normalized note velocity [0..1].
     *   bendSemitones = Active channel pitch bend in semitones.
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
        baseMidiNote_ = isFinite(midiNote) ? midiNote : 60.0f;
        velocity_ = isFinite(vel) ? vel : 0.8f;
        if (velocity_ < 0.0f) {
            velocity_ = 0.0f;
        } else if (velocity_ > 1.0f) {
            velocity_ = 1.0f;
        }
        updateFrequency(sampleRate, bendSemitones);
        env_.prepare(sampleRate);
        env_.setParams(attackSec, 0.12f, 0.65f, releaseSec);
        env_.setCurves(1.0f, 1.5f, 1.8f);
        filter_.reset();
        env_.trigger(false);
    }

    /**
     * Transitions the voice envelope into its release phase cleanly.
     */
    void releaseNote() {
        env_.releaseNote();
    }

    /**
     * Updates active pitch for pitch-bend or per-note slides.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   bendSemitones = Pitch bend offset in semitones.
     */
    void updateFrequency(float sampleRate, float bendSemitones) {
        immutable float pitch = baseMidiNote_ + (isFinite(bendSemitones) ? bendSemitones : 0.0f);
        immutable float hzA = midiNoteToHz(pitch - 0.07f);
        immutable float hzB = midiNoteToHz(pitch + 0.07f);
        oscA_.setFrequency(hzA, sampleRate);
        oscB_.setFrequency(hzB, sampleRate);
    }

    /**
     * Updates voice envelope durations on live parameter tweaks.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   attackSec = Attack time in seconds.
     *   releaseSec = Release time in seconds.
     */
    void updateEnvelopeParams(float sampleRate, float attackSec, float releaseSec) {
        env_.prepare(sampleRate);
        env_.setParams(attackSec, 0.12f, 0.65f, releaseSec);
    }

    /**
     * Reports whether the envelope remains active (used by VoicePool deactivation).
     *
     * Returns:
     *   True while envelope is not idle.
     */
    bool isActive() const pure @safe {
        return env_.isActive();
    }

    /**
     * Reports whether the voice has entered its release segment cleanly.
     *
     * Returns:
     *   True if releasing.
     */
    bool isReleasing() const pure @safe {
        return env_.isReleasing();
    }

    /**
     * Returns approximate current envelope amplitude for quietest-voice stealing priority.
     *
     * Returns:
     *   Current normalized envelope value.
     */
    float currentLevel() const pure @safe {
        return env_.value() * velocity_;
    }

    /**
     * Generates stereo audio samples and accumulates them into outL/outR for one slice.
     *
     * Params:
     *   outL = Destination left sample buffer.
     *   outR = Destination right sample buffer.
     *   frames = Frame count to synthesize.
     *   cutoffHz = Filter cutoff frequency in Hertz.
     *   resonance = Normalized filter resonance [0..0.95].
     *   sampleRate = Audio sample rate in Hertz.
     */
    void renderAdd(
        float[] outL,
        float[] outR,
        uint frames,
        float cutoffHz,
        float resonance,
        float sampleRate
    ) {
        foreach (i; 0 .. frames) {
            immutable float envVal = env_.next();
            immutable float sA = oscA_.nextSample(OscWaveform.saw);
            immutable float sB = oscB_.nextSample(OscWaveform.pulse, 0.35f);
            immutable float raw = 0.5f * (sA + sB) * envVal * velocity_;
            immutable float dynCutoff = cutoffHz * (0.4f + 0.85f * envVal);
            filter_.setParams(dynCutoff, resonance, sampleRate);
            immutable float filtered = filter_.processSample(raw, SvfMode.lpf);
            outL[i] += filtered * 0.95f;
            outR[i] += (filtered + 0.08f * (sA - sB) * envVal * velocity_) * 0.95f;
        }
    }
}

/**
 * Live 16-voice polyphonic subtractive synthesizer module compatible with ModuleAdapter and AudioGraph.
 */
struct CliDemoPolySynth {
    enum string typeId = "demo.polysynth";
    enum string displayName = "Live PolySynth";
    enum ModuleCategory category = ModuleCategory.synth;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("events", "MIDI Events", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Volume", 0.0f, 1.0f, 0.35f, "", ParamScale.linear)
    float volume = 0.35f;

    @Param("Cutoff", 80.0f, 12_000.0f, 2400.0f, "Hz", ParamScale.logarithmic)
    float cutoffHz = 2400.0f;

    @Param("Resonance", 0.0f, 0.85f, 0.25f, "", ParamScale.linear)
    float resonance = 0.25f;

    @Param("Attack", 0.002f, 2.0f, 0.008f, "s", ParamScale.logarithmic)
    float attackSec = 0.008f;

    @Param("Release", 0.01f, 3.0f, 0.25f, "s", ParamScale.logarithmic)
    float releaseSec = 0.25f;

    private VoicePool!(CliDemoVoice, 16) voices_;
    private ParamSmoother volSmoother_;
    private ParamSmoother cutoffSmoother_;
    private float sampleRate_ = 44_100.0f;
    private float pitchBendSemitones_ = 0.0f;

    @nogc nothrow:

    /**
     * Initializes voice sample rates and parameter smoothers before live playback.
     *
     * Params:
     *   sampleRate = Active hardware sample rate in Hertz.
     *   maxSliceFrames = Maximum graph slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        volSmoother_.prepare(sampleRate_, 5.0f, volume);
        cutoffSmoother_.prepare(sampleRate_, 5.0f, cutoffHz);
        voices_.resetAll();
        pitchBendSemitones_ = 0.0f;
    }

    /**
     * Silences all active voices and snaps smoothers cleanly on transport reset.
     */
    void reset() {
        voices_.resetAll();
        pitchBendSemitones_ = 0.0f;
        volSmoother_.reset(volume);
        cutoffSmoother_.reset(cutoffHz);
    }

    /**
     * Dispatches @Param changes safely by compile-time field name.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap smoothers immediately without ramping.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "volume") {
            volSmoother_.setTarget(volume, instant);
        } else static if (field == "cutoffHz") {
            cutoffSmoother_.setTarget(cutoffHz, instant);
        } else static if (field == "attackSec" || field == "releaseSec") {
            immutable float sr = sampleRate_;
            immutable float att = attackSec;
            immutable float rel = releaseSec;
            voices_.forEachActive((ref CliDemoVoice v, NoteId id) @nogc nothrow {
                cast(void) id;
                v.updateEnvelopeParams(sr, att, rel);
            });
        }
    }

    /**
     * Handles real-time note, pitch-bend, and panic ModEvents inside the audio graph slice.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        switch (ev.kind) {
            case ModEventKind.noteOn: {
                bool stolen = false;
                CliDemoVoice* v = voices_.allocateVoice(ev.noteId, stolen);
                if (v !is null) {
                    v.trigger(
                        sampleRate_,
                        ev.valueA,
                        ev.valueB,
                        pitchBendSemitones_,
                        attackSec,
                        releaseSec
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
                    immutable float bend = pitchBendSemitones_;
                    voices_.forEachActive((ref CliDemoVoice v, NoteId id) @nogc nothrow {
                        cast(void) id;
                        v.updateFrequency(sr, bend);
                    });
                } else {
                    CliDemoVoice* v = voices_.findVoice(ev.noteId);
                    if (v !is null) {
                        v.baseMidiNote_ = isFinite(ev.valueA) ? ev.valueA : v.baseMidiNote_;
                        v.updateFrequency(sampleRate_, pitchBendSemitones_);
                    }
                }
                break;

            default:
                break;
        }
    }

    /**
     * Renders active polyphonic voices cleanly into audioOut with silent-tail deactivation.
     *
     * Params:
     *   audioIn = Unused input audio slices.
     *   audioOut = Output stereo slices receiving mixed synth output.
     *   ctx = Per-slice processing context.
     *
     * Returns:
     *   True if non-silent output was generated; false when all voices are idle.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        cast(void) audioIn;
        voices_.deactivateFinished();
        if (!voices_.hasActiveVoices()) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) volSmoother_.next();
                cast(void) cutoffSmoother_.next();
            }
            return false;
        }

        auto outL = audioOut[0];
        auto outR = audioOut[1];
        outL[0 .. ctx.frames] = 0.0f;
        outR[0 .. ctx.frames] = 0.0f;

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable uint frames = ctx.frames;
        immutable float curCutoff = cutoffSmoother_.target();
        immutable float res = resonance;

        voices_.forEachActive((ref CliDemoVoice v, NoteId id) @nogc nothrow {
            cast(void) id;
            v.renderAdd(outL, outR, frames, curCutoff, res, sr);
        });

        float peak = 0.0f;
        foreach (i; 0 .. frames) {
            immutable float gain = volSmoother_.next();
            cast(void) cutoffSmoother_.next();
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
}

version (OSX) {
    private struct CliDemoRtState {
        AudioGraph graph;
        CoreMidiRtContext* midiCtx = null;
        MidiNoteTracker noteTracker;
        TransportState transport;
        Atomic!int pauseGraph;
        Atomic!int inRender;
        Atomic!ulong midiEventsProcessed;
        Atomic!ulong autoNotesTriggered;
        float sampleRate = 44_100.0f;
        bool autoChord = false;
        bool enableDuplex = false;
        ulong nextAutoStepFrame = 0;
        uint autoStepIdx = 0;

        @disable this(this);
    }

    static assert(!hasGcReference!CliDemoRtState,
        "CliDemoRtState accessed on CoreAudio RT thread must have zero GC references");

    private void processAutoChordStep(ref CliDemoRtState state, float sampleRate) @nogc nothrow {
        static immutable float[4][4] chordNotes = [
            [48.0f, 55.0f, 60.0f, 67.0f],
            [53.0f, 57.0f, 60.0f, 65.0f],
            [55.0f, 59.0f, 62.0f, 67.0f],
            [48.0f, 55.0f, 64.0f, 72.0f]
        ];
        immutable ulong stepInterval = cast(ulong)(sampleRate * 0.25);
        immutable FrameTime curFrame = state.graph.renderedFrames();
        if (curFrame < state.nextAutoStepFrame) {
            return;
        }

        immutable uint prevGroup = ((state.autoStepIdx + 3) & 3u);
        foreach (k; 0 .. 4) {
            immutable NoteId offId = NoteId(0x4000_0001u + prevGroup * 4u + cast(uint) k);
            state.graph.enqueueEvent(ModuleId(1), ModEvent.makeNoteOff(offId), curFrame);
        }

        immutable uint curGroup = state.autoStepIdx & 3u;
        foreach (k; 0 .. 4) {
            immutable NoteId onId = NoteId(0x4000_0001u + curGroup * 4u + cast(uint) k);
            state.graph.enqueueEvent(
                ModuleId(1),
                ModEvent.makeNoteOn(onId, chordNotes[curGroup][k], 0.45f),
                curFrame + cast(FrameTime)(k * 64u)
            );
        }

        state.autoNotesTriggered.fetchAdd(4);
        state.autoStepIdx++;
        state.nextAutoStepFrame = curFrame + (stepInterval > FIXED_BLOCK_FRAMES ? stepInterval : FIXED_BLOCK_FRAMES);
    }

    private void cliDemoAudioCallback(
        void* userData,
        const(float)* inL,
        const(float)* inR,
        float* outL,
        float* outR,
        uint frames
    ) @nogc nothrow {
        if (outL is null || outR is null || frames == 0) {
            return;
        }
        auto state = cast(CliDemoRtState*) userData;
        if (state is null || state.pauseGraph.load() != 0) {
            outL[0 .. frames] = 0.0f;
            outR[0 .. frames] = 0.0f;
            return;
        }

        state.inRender.store(1);
        scope (exit) state.inRender.store(0);

        if (state.pauseGraph.load() != 0) {
            outL[0 .. frames] = 0.0f;
            outR[0 .. frames] = 0.0f;
            return;
        }

        immutable FrameTime renderAt = state.graph.renderedFrames();
        if (state.midiCtx !is null) {
            MidiPacket pkt;
            while (state.midiCtx.packetRing.tryPop(pkt)) {
                ModEvent ev;
                if (translateMidiPacketToModEvent(pkt, state.noteTracker, ev, 0, 2.0f)) {
                    if (ev.kind == ModEventKind.setParam) {
                        if (ev.paramId == 74 || ev.paramId == 1) {
                            immutable float cutoff = 80.0f * cast(float) pow(150.0, cast(double) ev.valueA);
                            state.graph.setModuleParam(ModuleId(1), 1, cutoff, false);
                        } else if (ev.paramId == 71) {
                            state.graph.setModuleParam(ModuleId(1), 2, ev.valueA * 0.85f, false);
                        } else if (ev.paramId == 7) {
                            state.graph.setModuleParam(ModuleId(1), 0, ev.valueA, false);
                        }
                    } else if (ev.kind != ModEventKind.transport) {
                        state.graph.enqueueEvent(ModuleId(1), ev, renderAt);
                    }
                    state.midiEventsProcessed.fetchAdd(1);
                }
            }
        }

        if (state.autoChord) {
            processAutoChordStep(*state, state.sampleRate);
        }

        float[][2] outs = [outL[0 .. frames], outR[0 .. frames]];
        const(float[])[2] ins = [
            (inL !is null && state.enableDuplex) ? inL[0 .. frames] : null,
            (inR !is null && state.enableDuplex) ? inR[0 .. frames] : null
        ];
        state.graph.render(outs, ins, frames, state.transport);
    }

    private void sleepMilliseconds(uint ms) nothrow {
        timespec req;
        req.tv_sec = ms / 1000;
        req.tv_nsec = cast(long)(ms % 1000) * 1_000_000L;
        nanosleep(&req, null);
    }

    private int runListDevices() {
        scope audio = new CoreAudioDriver();
        auto audioDevs = audio.enumerateDevices();
        writefln("CoreAudio Devices (%s):", audioDevs.length);
        foreach (ref d; audioDevs) {
            writefln(
                "  [%u] \"%s\" (in=%u, out=%u, rate=%.0f Hz, buf=%u..%u)%s%s",
                d.id,
                d.name,
                d.inputChannels,
                d.outputChannels,
                d.nominalSampleRate,
                d.minBufferFrames,
                d.maxBufferFrames,
                d.isDefaultOutput ? " [DEFAULT OUT]" : "",
                d.isDefaultInput ? " [DEFAULT IN]" : ""
            );
        }

        scope midi = new CoreMidiDriver();
        if (midi.open("SynthTracker List")) {
            auto srcs = midi.enumerateSources();
            writefln("CoreMIDI Input Sources (%s):", srcs.length);
            foreach (ref s; srcs) {
                writefln("  [%u] %s%s", s.id, s.displayName, s.isOffline ? " (offline)" : "");
            }
            auto dsts = midi.enumerateDestinations();
            writefln("CoreMIDI Output Destinations (%s):", dsts.length);
            foreach (ref dst; dsts) {
                writefln("  [%u] %s%s", dst.id, dst.displayName, dst.isOffline ? " (offline)" : "");
            }
            midi.close();
        } else {
            writeln("CoreMIDI client unavailable.");
        }
        return 0;
    }

    private int runCliDemo(string[] args) {
        double requestedRate = 44_100.0;
        uint requestedBuffer = 128;
        double maxDurationSec = 0.0;
        bool autoChord = false;
        bool enableDuplex = false;

        foreach (arg; args[1 .. $]) {
            if (arg == "--auto-chord") {
                autoChord = true;
            } else if (arg == "--duplex") {
                enableDuplex = true;
            } else if (arg.startsWith("--sample-rate=")) {
                try {
                    requestedRate = arg["--sample-rate=".length .. $].to!double;
                } catch (Exception) {
                    stderr.writeln("Invalid --sample-rate value");
                    return 1;
                }
            } else if (arg.startsWith("--buffer-frames=")) {
                try {
                    requestedBuffer = arg["--buffer-frames=".length .. $].to!uint;
                } catch (Exception) {
                    stderr.writeln("Invalid --buffer-frames value");
                    return 1;
                }
            } else if (arg.startsWith("--duration=")) {
                try {
                    maxDurationSec = arg["--duration=".length .. $].to!double;
                } catch (Exception) {
                    stderr.writeln("Invalid --duration value");
                    return 1;
                }
            }
        }

        atomicStore!(MemoryOrder.rel)(gCliStopFlag, 0);
        signal(SIGINT, &handleCliSignal);
        signal(SIGTERM, &handleCliSignal);

        auto synthDesc = &ModuleAdapter!CliDemoPolySynth.DESCRIPTOR;
        ModuleInstance synthInst = ModuleInstance(ModuleId(1), synthDesc, synthDesc.vtable.create());
        if (synthInst.state is null) {
            stderr.writeln("Failed to allocate CliDemoPolySynth state.");
            return 1;
        }
        synthDesc.vtable.prepare(synthInst.state, cast(float) requestedRate, FIXED_BLOCK_FRAMES);

        ModuleInstance dcInst;
        ModuleInstance outInst;
        if (!ModuleRegistry.createOffRT("fx.dc_blocker", ModuleId(2), cast(float) requestedRate, dcInst)
                || !ModuleRegistry.createOffRT("core.output", ModuleId(3), cast(float) requestedRate, outInst)) {
            synthInst.destroyOffRT();
            dcInst.destroyOffRT();
            outInst.destroyOffRT();
            stderr.writeln("Failed to instantiate DcBlocker / MasterOutput.");
            return 1;
        }

        scope (exit) {
            synthInst.destroyOffRT();
            dcInst.destroyOffRT();
            outInst.destroyOffRT();
        }

        NodeSpec[3] nodes = [
            NodeSpec.fromInstance(synthInst),
            NodeSpec.fromInstance(dcInst),
            NodeSpec.fromInstance(outInst)
        ];
        WireSpec[2] wires = [
            WireSpec(ModuleId(1), 1, ModuleId(2), 0, 1.0f),
            WireSpec(ModuleId(2), 1, ModuleId(3), 0, 1.0f)
        ];

        GraphPlan* compiledPlan = null;
        GraphCompileError compileErr;
        if (!GraphCompiler.compile(nodes[], wires[], compiledPlan, compileErr)) {
            stderr.writefln("Failed to compile demo AudioGraph: %s", compileErr);
            return 1;
        }

        auto rtState = cast(CliDemoRtState*) calloc(1, CliDemoRtState.sizeof);
        if (rtState is null) {
            GraphPlan.destroyOffRT(compiledPlan);
            return 1;
        }
        emplace(rtState);
        if (!rtState.graph.tryInit(cast(float) requestedRate, 1024)) {
            GraphPlan.destroyOffRT(compiledPlan);
            destroy!false(*rtState);
            free(rtState);
            return 1;
        }
        rtState.graph.swapPlan(compiledPlan);
        rtState.transport.playing = true;
        rtState.sampleRate = cast(float) requestedRate;
        rtState.autoChord = autoChord;
        rtState.enableDuplex = enableDuplex;

        scope (exit) {
            GraphPlan* leftover = rtState.graph.detachPlan();
            if (leftover !is null) {
                GraphPlan.destroyOffRT(leftover);
            }
            destroy!false(*rtState);
            free(rtState);
        }

        scope midi = new CoreMidiDriver();
        size_t connectedMidiCount = 0;
        if (midi.open("SynthTracker CLI Demo")) {
            rtState.midiCtx = midi.rtContext();
            midi.createVirtualDestination("SynthTracker Live MIDI");
            connectedMidiCount = midi.connectAllSources();
        }
        scope (exit) midi.close();

        scope audio = new CoreAudioDriver();
        auto audioDevs = audio.enumerateDevices();
        bool hasOutputDevice = false;
        foreach (ref d; audioDevs) {
            if (d.outputChannels > 0) {
                hasOutputDevice = true;
                break;
            }
        }
        if (!hasOutputDevice) {
            writeln("No CoreAudio output device available; exiting cleanly.");
            return 0;
        }

        AudioStreamConfig cfg;
        cfg.sampleRate = requestedRate;
        cfg.bufferFrames = requestedBuffer;
        cfg.enableInput = enableDuplex;

        if (!audio.open(cfg, &cliDemoAudioCallback, rtState)) {
            stderr.writeln("Failed to initialize CoreAudio driver.");
            return 1;
        }
        scope (exit) audio.close();

        float currentSr = cast(float) audio.activeSampleRate();
        if (fabs(currentSr - cast(float) requestedRate) > 1.0f) {
            GraphPlan* activeP = rtState.graph.detachPlan();
            synthInst.desc.vtable.prepare(synthInst.state, currentSr, FIXED_BLOCK_FRAMES);
            dcInst.desc.vtable.prepare(dcInst.state, currentSr, FIXED_BLOCK_FRAMES);
            outInst.desc.vtable.prepare(outInst.state, currentSr, FIXED_BLOCK_FRAMES);
            rtState.graph.tryInit(currentSr, 1024);
            rtState.graph.swapPlan(activeP);
            rtState.sampleRate = currentSr;
        }

        if (!audio.start()) {
            stderr.writeln("Failed to start CoreAudio output unit.");
            return 1;
        }

        writefln(
            "SynthTracker --cli-demo running @ %.0f Hz (%u frames, MIDI sources: %s, virtual port: \"SynthTracker Live MIDI\"%s). Press Ctrl+C to stop.",
            audio.activeSampleRate(),
            audio.activeBufferFrames(),
            connectedMidiCount,
            autoChord ? ", auto-chord enabled" : ""
        );
        stdout.flush();

        immutable MachTimebase tb = MachTimebase.query();
        immutable ulong startTicks = MachTimebase.nowTicks();
        ulong nextTelemetryNanos = 1_000_000_000UL;

        while (atomicLoad!(MemoryOrder.acq)(gCliStopFlag) == 0) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, 0);
            sleepMilliseconds(10);

            AudioNotification audioNotif;
            if (audio.pollNotification(audioNotif)) {
                rtState.pauseGraph.store(1);
                while (rtState.inRender.load() != 0) {
                    sleepMilliseconds(1);
                }
                if (audio.handleDeviceChange()) {
                    immutable float nextSr = cast(float) audio.activeSampleRate();
                    if (fabs(nextSr - currentSr) > 1.0f) {
                        currentSr = nextSr;
                        GraphPlan* p = rtState.graph.detachPlan();
                        synthInst.desc.vtable.prepare(synthInst.state, currentSr, FIXED_BLOCK_FRAMES);
                        dcInst.desc.vtable.prepare(dcInst.state, currentSr, FIXED_BLOCK_FRAMES);
                        outInst.desc.vtable.prepare(outInst.state, currentSr, FIXED_BLOCK_FRAMES);
                        rtState.graph.tryInit(currentSr, 1024);
                        rtState.graph.swapPlan(p);
                        rtState.sampleRate = currentSr;
                    }
                }
                rtState.pauseGraph.store(0);
            }

            MidiNotification midiNotif;
            if (midi.pollNotification(midiNotif)) {
                midi.refreshConnections();
            }

            immutable ulong elapsedNanos = tb.ticksToNanos(MachTimebase.nowTicks() - startTicks);
            if (elapsedNanos >= nextTelemetryNanos) {
                GraphTelemetry tel;
                rtState.graph.readTelemetry(tel);
                auto drvStats = audio.stats();
                writefln(
                    "  [%.1fs] callbacks=%s frames=%s xruns=%s peakL=%.3f peakR=%.3f midi=%s",
                    cast(double) elapsedNanos / 1.0e9,
                    drvStats.callbackCount,
                    drvStats.framesRendered,
                    drvStats.xrunCount,
                    tel.masterPeakL,
                    tel.masterPeakR,
                    rtState.midiEventsProcessed.load()
                );
                stdout.flush();
                nextTelemetryNanos += 1_000_000_000UL;
            }

            if (maxDurationSec > 0.0 && (cast(double) elapsedNanos / 1.0e9) >= maxDurationSec) {
                break;
            }
        }

        audio.stop();
        auto finalStats = audio.stats();
        writefln(
            "Stopped cleanly: callbacks=%s, frames=%s, xruns=%s, sampleRate=%.0f Hz, midiEvents=%s, autoNotes=%s",
            finalStats.callbackCount,
            finalStats.framesRendered,
            finalStats.xrunCount,
            finalStats.activeSampleRate,
            rtState.midiEventsProcessed.load(),
            rtState.autoNotesTriggered.load()
        );
        return 0;
    }
}

private void printUsage() {
    version (StudioGUI) {
        writeln("SynthTracker (native macOS studio)");
        writeln("Usage:");
        writeln("  synth-tracker [--gui] [project.msv]   launch the studio (default)");
        writeln("  synth-tracker --gallery               Phase 7 toolkit/renderer gallery");
        writeln("  synth-tracker --studio-gui-selftest [--quick]  end-to-end GUI workflow verification");
        writeln("  synth-tracker --gui-selftest [--quick] run the automated Phase 7 GUI verification");
    } else {
        writeln("SynthTracker Headless CLI");
        writeln("Usage:");
    }
    writeln("  synth-tracker --list-devices");
    writeln("  synth-tracker --cli-demo [--duration=<sec>] [--sample-rate=<hz>] [--buffer-frames=<n>] [--auto-chord] [--duplex]");
    writeln("  synth-tracker --studio-selftest [--quick]   live session audio/MIDI backend verification (plays audio)");
}

/**
 * Application entry point dispatching headless CLI modes on macOS and printing usage cleanly.
 *
 * Params:
 *   args = Command-line argument vector supplied by the operating system.
 *
 * Returns:
 *   Exit status code where 0 denotes success.
 */
int main(string[] args) {
    foreach (arg; args[1 .. $]) {
        if (arg == "--help" || arg == "-h") {
            printUsage();
            return 0;
        }
        version (StudioGUI) {
            if (arg == "--gui-selftest") {
                return runGuiSelfTest(args);
            }
            if (arg == "--gui") {
                return runStudioApp(args);
            }
            if (arg == "--studio-gui-selftest") {
                import app.studio_app : runStudioGuiSelfTest;

                return runStudioGuiSelfTest(args);
            }
            if (arg == "--gallery") {
                return runStudioGui(args);
            }
        }
        version (OSX) {
            if (arg == "--list-devices") {
                return runListDevices();
            }
            if (arg == "--cli-demo") {
                return runCliDemo(args);
            }
            if (arg == "--studio-selftest") {
                import app.studio_selftest : runStudioSelfTest;

                return runStudioSelfTest(args);
            }
        }
    }

    version (StudioGUI) {
        if (args.length == 1 || (args.length == 2 && args[1].length > 4 && args[1][$ - 4 .. $] == ".msv")) {
            return runStudioApp(args);
        }
    }
    printUsage();
    return 0;
}
