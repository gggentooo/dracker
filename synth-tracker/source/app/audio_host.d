/**
 * File:         source/app/audio_host.d
 * Module:       app.audio_host
 * Phase:        Phase 7.5.1 / 7.5.2 / 7.5.3 — Live CoreAudio/CoreMIDI Session Host
 *
 * Purpose:
 *   Connects a StudioSession's Engine to the real audio and MIDI hardware. EngineRtContext is the unmanaged
 *   state the CoreAudio callback reaches (Engine pointer, CoreMIDI packet ring, RT -> UI MIDI copy ring, MIDI
 *   target module, MIDI note tracker, DSP-load telemetry). engineRenderCallback drains live MIDI (notes as live
 *   voices on the MIDI target module, CCs through the Engine MIDI map, everything else as ModEvents), renders
 *   the host buffer through Engine.processHostBuffer with duplex input, and publishes render-time load. AudioHost
 *   (UI thread) owns CoreAudioDriver + CoreMidiDriver, opens the stream, keeps the session Engine at the device
 *   sample rate, connects MIDI sources (including hot-plugged ones) and the "SynthTracker Live MIDI" virtual
 *   destination, recovers from device changes, and exposes load telemetry and the UI MIDI stream.
 *
 * Real-Time & Safety Contract:
 *   engineRenderCallback and everything it calls is @nogc nothrow and reaches only unmanaged memory:
 *   EngineRtContext and Engine are calloc-allocated and statically asserted free of GC references. MIDI that
 *   originates on the RT thread calls Engine RT methods directly and never uses the UI -> RT command ring.
 *   Live MIDI events are applied at host-buffer offset 0 because AudioRenderCallback carries no host time
 *   (worst-case added latency: one host buffer). AudioHost fields that the callback reads are written only
 *   while the stream is stopped.
 *
 * Dependencies:
 *   Internal: app.session, foundation.{concurrency,types}, graph.event, platform.interfaces,
 *             platform.macos.{coreaudio,coremidi,corefoundation}, sequencer.engine
 *   External: core.stdc.stdlib (calloc, free), core.lifetime (emplace)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct AudioLoadTelemetry / struct EngineRtContext
 *   - extern(C) void engineRenderCallback(...) @nogc nothrow
 *   - EngineRtContext* createEngineRtContext(Engine*, size_t) / void destroyEngineRtContext(EngineRtContext*)
 *   - class AudioHost : open(), close(), isRunning(), poll(), readLoad(), drainMidi(), setMidiTarget(),
 *     selectOutputDevice(), enumerateDevices(), midiSources()
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 7.5)
 */
module app.audio_host;

import core.lifetime : emplace;
import core.stdc.stdlib : calloc, free;

import foundation.concurrency : Atomic, hasGcReference, SpscRing, TripleBuffer;
import foundation.types : ModuleId;
import graph.event : ModEvent;
import platform.interfaces : MidiPacket;
import sequencer.engine : Engine;

/**
 * DSP load and stream health published by the render callback.
 */
struct AudioLoadTelemetry {
    float loadAvg = 0.0f;
    float loadPeak = 0.0f;
    float sampleRate = 0.0f;
    uint bufferFrames = 0;
    ulong callbacks = 0;
    ulong xruns = 0;
    ulong midiPacketsIn = 0;
    ulong midiDropped = 0;
    ulong scopeDropped = 0;
}

/**
 * Unmanaged state reached from the CoreAudio render callback.
 */
struct EngineRtContext {
    Engine* engine = null;
    MpscRingPtr midiIn = null;
    SpscRing!MidiPacket uiMidi;
    Atomic!uint midiTarget;
    TripleBuffer!AudioLoadTelemetry load;
    float sampleRate = 44_100.0f;
    ulong timebaseNumer = 1;
    ulong timebaseDenom = 1;
    double loadEma = 0.0;
    double loadPeak = 0.0;
    ulong callbacks = 0;
    ulong midiPacketsIn = 0;
    ulong midiDropped = 0;
    ulong xruns = 0;
    ulong scopeDropped = 0;
    ubyte[128][16] heldNotes;

    @disable this(this);
}

/**
 * Type-erased handle to the CoreMIDI MpscRing!MidiPacket consumed on the RT thread (null = no MIDI).
 */
alias MpscRingPtr = void*;

static assert(!hasGcReference!EngineRtContext, "EngineRtContext is reached from the CoreAudio callback");

/**
 * Optional RT-side MIDI source hooks, installed by the platform layer so this module stays testable headless.
 */
struct RtMidiSource {
    bool function(void* ring, out MidiPacket pkt) @nogc nothrow pop = null;
    bool function(const ref MidiPacket pkt, out ModEvent ev) @nogc nothrow translate = null;
    ulong function() @nogc nothrow nowTicks = null;
}

/**
 * Allocates an EngineRtContext bound to engine.
 *
 * Params:
 *   engine = Unmanaged Engine (must outlive the context).
 *   uiMidiCapacity = Power-of-two capacity of the RT -> UI MIDI copy ring.
 *
 * Returns:
 *   Context, or null on OOM.
 */
EngineRtContext* createEngineRtContext(Engine* engine, size_t uiMidiCapacity = 1024) @nogc nothrow {
    auto ctx = cast(EngineRtContext*) calloc(1, EngineRtContext.sizeof);
    if (ctx is null) {
        return null;
    }
    emplace(ctx);
    ctx.engine = engine;
    if (!SpscRing!MidiPacket.tryCreate(uiMidiCapacity, ctx.uiMidi)) {
        destroyEngineRtContext(ctx);
        return null;
    }
    return ctx;
}

/**
 * Frees a context created by createEngineRtContext (the stream must be stopped).
 *
 * Params:
 *   ctx = Context (null-safe).
 */
void destroyEngineRtContext(EngineRtContext* ctx) @nogc nothrow {
    if (ctx is null) {
        return;
    }
    destroy(*ctx);
    free(ctx);
}

/**
 * Processes one MIDI packet on the RT thread: notes become live voices on the MIDI target module, CCs go
 * through the Engine MIDI map (unmapped CCs and other messages are delivered as ModEvents when translate is set).
 *
 * Params:
 *   ctx = RT context.
 *   pkt = Packet.
 *   translate = Optional packet -> ModEvent translator for non-note messages.
 */
void applyMidiPacketRt(EngineRtContext* ctx, const ref MidiPacket pkt,
        bool function(const ref MidiPacket, out ModEvent) @nogc nothrow translate) @nogc nothrow {
    if (ctx is null || ctx.engine is null || pkt.len == 0) {
        return;
    }
    ctx.midiPacketsIn++;
    if (!ctx.uiMidi.tryPush(pkt)) {
        ctx.midiDropped++;
    }
    immutable ubyte status = pkt.status();
    immutable ubyte kind = status & 0xF0;
    immutable ubyte ch = status & 0x0F;
    immutable ModuleId target = ModuleId(ctx.midiTarget.load());
    if (kind == 0x90 && pkt.len >= 3 && pkt.data2() > 0) {
        immutable ubyte note = pkt.data1() & 0x7F;
        ctx.heldNotes[ch][note] = 1;
        ctx.engine.liveNoteOnRt(target, Engine.MIDI_KEY_TAG_BASE | (ch << 8) | note, note, pkt.data2() / 127.0f, 0);
        return;
    }
    if ((kind == 0x80 || kind == 0x90) && pkt.len >= 3) {
        immutable ubyte note = pkt.data1() & 0x7F;
        ctx.heldNotes[ch][note] = 0;
        ctx.engine.liveNoteOffRt(ModuleId.invalid, Engine.MIDI_KEY_TAG_BASE | (ch << 8) | note, 0);
        return;
    }
    if (kind == 0xB0 && pkt.len >= 3) {
        immutable ubyte cc = pkt.data1() & 0x7F;
        if (cc == 120 || cc == 123) {
            foreach (n; 0 .. 128) {
                if (ctx.heldNotes[ch][n]) {
                    ctx.heldNotes[ch][n] = 0;
                    ctx.engine.liveNoteOffRt(ModuleId.invalid, Engine.MIDI_KEY_TAG_BASE | (ch << 8) | n, 0);
                }
            }
            return;
        }
        if (ctx.engine.applyMidiCcRt(ch, cc, pkt.data2() & 0x7F) > 0) {
            return;
        }
    }
    if (translate !is null && target.isValid()) {
        ModEvent ev;
        if (translate(pkt, ev)) {
            ctx.engine.enqueueLiveEventRt(target, ev, 0);
        }
    }
}

/**
 * Renders one host buffer for ctx (shared by the CoreAudio callback and headless tests).
 *
 * Params:
 *   ctx = RT context.
 *   src = RT MIDI hooks (pop/translate/nowTicks may be null).
 *   inL = Optional duplex input left.
 *   inR = Optional duplex input right.
 *   outL = Output left (frames samples).
 *   outR = Output right (frames samples).
 *   frames = Host buffer size.
 */
void renderHostBufferRt(EngineRtContext* ctx, ref const RtMidiSource src, const(float)* inL, const(float)* inR,
        float* outL, float* outR, uint frames) @nogc nothrow {
    if (outL is null || outR is null || frames == 0) {
        return;
    }
    if (ctx is null || ctx.engine is null) {
        outL[0 .. frames] = 0.0f;
        outR[0 .. frames] = 0.0f;
        return;
    }
    immutable ulong t0 = src.nowTicks !is null ? src.nowTicks() : 0;
    if (src.pop !is null && ctx.midiIn !is null) {
        MidiPacket pkt;
        uint budget = 256;
        while (budget > 0 && src.pop(ctx.midiIn, pkt)) {
            applyMidiPacketRt(ctx, pkt, src.translate);
            budget--;
        }
    }
    float[][2] outs = [outL[0 .. frames], outR[0 .. frames]];
    const(float[])[2] ins = [inL is null ? null : inL[0 .. frames], inR is null ? null : inR[0 .. frames]];
    ctx.engine.processHostBuffer(outs, ins, frames);
    ctx.callbacks++;
    if (src.nowTicks !is null && ctx.sampleRate > 0.0f) {
        immutable ulong dt = src.nowTicks() - t0;
        immutable double ns = ctx.timebaseDenom == 0 ? cast(double) dt
            : cast(double) dt * cast(double) ctx.timebaseNumer / cast(double) ctx.timebaseDenom;
        immutable double periodNs = cast(double) frames * 1e9 / ctx.sampleRate;
        immutable double load = periodNs > 0.0 ? ns / periodNs : 0.0;
        ctx.loadEma = ctx.callbacks == 1 ? load : ctx.loadEma * 0.95 + load * 0.05;
        ctx.loadPeak = load > ctx.loadPeak ? load : ctx.loadPeak * 0.999;
    }
    AudioLoadTelemetry* t = &ctx.load.backBuffer();
    t.loadAvg = cast(float) ctx.loadEma;
    t.loadPeak = cast(float) ctx.loadPeak;
    t.sampleRate = ctx.sampleRate;
    t.bufferFrames = frames;
    t.callbacks = ctx.callbacks;
    t.xruns = ctx.xruns;
    t.midiPacketsIn = ctx.midiPacketsIn;
    t.midiDropped = ctx.midiDropped;
    t.scopeDropped = ctx.engine.scopeBlocksDropped();
    ctx.load.publish();
}

version (OSX) {
    import app.session : StudioSession;
    import platform.interfaces : AudioDeviceInfo, AudioStreamConfig, MidiDeviceInfo, MidiNotification;
    import platform.macos.coreaudio : CoreAudioDriver;
    import platform.macos.corefoundation : MachTimebase;
    import platform.macos.coremidi : CoreMidiDriver, CoreMidiRtContext, MidiNoteTracker, translateMidiPacketToModEvent;
    import foundation.concurrency : MpscRing;

    private bool popCoreMidi(void* ring, out MidiPacket pkt) @nogc nothrow {
        return (cast(MpscRing!MidiPacket*) ring).tryPop(pkt);
    }

    private bool translateCoreMidi(const ref MidiPacket pkt, out ModEvent ev) @nogc nothrow {
        MidiNoteTracker unusedTracker;
        return translateMidiPacketToModEvent(pkt, unusedTracker, ev, 0);
    }

    private ulong nowMachTicks() @nogc nothrow {
        return MachTimebase.nowTicks();
    }

    private immutable RtMidiSource CORE_MIDI_SOURCE = RtMidiSource(&popCoreMidi, &translateCoreMidi, &nowMachTicks);

    /**
     * CoreAudio render callback (AudioRenderCallback); userData is an EngineRtContext*.
     *
     * Params:
     *   userData = EngineRtContext*.
     *   inL = Duplex input left (may be null).
     *   inR = Duplex input right (may be null).
     *   outL = Output left.
     *   outR = Output right.
     *   frames = Host buffer size.
     */
    void engineRenderCallback(void* userData, const(float)* inL, const(float)* inR, float* outL,
            float* outR, uint frames) @nogc nothrow {
        renderHostBufferRt(cast(EngineRtContext*) userData, CORE_MIDI_SOURCE, inL, inR, outL, outR, frames);
    }

    /**
     * UI-thread owner of the live audio/MIDI stream driving a StudioSession.
     */
    final class AudioHost {
        private StudioSession session_;
        private CoreAudioDriver audio_;
        private CoreMidiDriver midi_;
        private EngineRtContext* ctx_;
        private AudioStreamConfig config_;
        private bool open_ = false;
        private bool[uint] connectedSources_;

        /**
         * Opens audio (and optionally MIDI) for session, re-initializing the session at the device sample rate,
         * and starts streaming.
         *
         * Params:
         *   session = Initialized session (its Engine allocation is reused across rate changes).
         *   config = Requested stream configuration.
         *   enableMidi = True to open CoreMIDI, connect all sources and create the virtual destination.
         *   err = Receives a diagnostic on failure.
         *
         * Returns:
         *   True if streaming.
         */
        bool open(StudioSession session, AudioStreamConfig config, bool enableMidi, out string err) {
            close();
            if (session is null || session.engine() is null) {
                err = "Session is not initialized";
                return false;
            }
            session_ = session;
            config_ = config;
            ctx_ = createEngineRtContext(session.engine());
            if (ctx_ is null) {
                err = "Out of memory allocating EngineRtContext";
                return false;
            }
            immutable MachTimebase tb = MachTimebase.query();
            ctx_.timebaseNumer = tb.numer;
            ctx_.timebaseDenom = tb.denom;
            if (enableMidi) {
                midi_ = new CoreMidiDriver();
                if (midi_.open("SynthTracker")) {
                    midi_.createVirtualDestination("SynthTracker Live MIDI");
                    connectAllMidiSources();
                    CoreMidiRtContext* mctx = midi_.rtContext();
                    ctx_.midiIn = mctx is null ? null : cast(void*) &mctx.packetRing;
                } else {
                    midi_ = null;
                }
            }
            audio_ = new CoreAudioDriver();
            if (!audio_.open(config_, &engineRenderCallback, ctx_)) {
                err = "CoreAudio stream could not be opened";
                closeDrivers();
                return false;
            }
            if (!followDeviceRate(err)) {
                closeDrivers();
                return false;
            }
            session_.attachAudioDriver(audio_);
            if (!audio_.start()) {
                err = "CoreAudio stream could not be started";
                session_.attachAudioDriver(null);
                closeDrivers();
                return false;
            }
            open_ = true;
            return true;
        }

        /**
         * Stops streaming, detaches from the session, and frees the RT context.
         */
        void close() {
            if (session_ !is null) {
                if (audio_ !is null) {
                    audio_.stop();
                }
                session_.attachAudioDriver(null);
            }
            closeDrivers();
            open_ = false;
        }

        /**
         * Reports whether the stream is running.
         *
         * Returns:
         *   True while CoreAudio renders the session.
         */
        bool isRunning() const {
            return open_ && audio_ !is null && audio_.isRunning();
        }

        /**
         * Returns the session being rendered.
         *
         * Returns:
         *   Session or null.
         */
        StudioSession session() {
            return session_;
        }

        /**
         * Handles device hot-plug/sample-rate notifications and newly attached MIDI sources (call each UI tick).
         *
         * Returns:
         *   False if the stream was lost and could not be recovered.
         */
        bool poll() {
            if (!open_) {
                return false;
            }
            if (midi_ !is null) {
                MidiNotification n;
                bool changed = false;
                while (midi_.pollNotification(n)) {
                    changed = true;
                }
                if (changed) {
                    connectAllMidiSources();
                }
            }
            if (!audio_.handleDeviceChange()) {
                return false;
            }
            if (cast(float) audio_.activeSampleRate() != session_.sampleRate()) {
                audio_.stop();
                string err;
                if (!followDeviceRate(err)) {
                    return false;
                }
                return audio_.start();
            }
            return true;
        }

        /**
         * Switches the output device and restarts the stream (falls back to the previous device on failure).
         *
         * Params:
         *   deviceId = CoreAudio device id (0 = system default).
         *   err = Receives a diagnostic on failure.
         *
         * Returns:
         *   True if streaming on the requested device.
         */
        bool selectOutputDevice(uint deviceId, out string err) {
            if (!open_) {
                err = "Audio host is not open";
                return false;
            }
            AudioStreamConfig next = config_;
            next.outputDeviceId = deviceId;
            audio_.stop();
            audio_.close();
            if (!audio_.open(next, &engineRenderCallback, ctx_)) {
                err = "Requested output device could not be opened";
                audio_.open(config_, &engineRenderCallback, ctx_);
                followDeviceRate(err);
                audio_.start();
                return false;
            }
            config_ = next;
            if (!followDeviceRate(err)) {
                return false;
            }
            return audio_.start();
        }

        /**
         * Lists audio devices.
         *
         * Returns:
         *   Device descriptions.
         */
        AudioDeviceInfo[] enumerateDevices() {
            return audio_ is null ? new CoreAudioDriver().enumerateDevices() : audio_.enumerateDevices();
        }

        /**
         * Lists MIDI sources.
         *
         * Returns:
         *   Source descriptions (empty if MIDI is disabled).
         */
        MidiDeviceInfo[] midiSources() {
            return midi_ is null ? null : midi_.enumerateSources();
        }

        /**
         * Selects the module that receives live MIDI notes and unmapped controller messages.
         *
         * Params:
         *   moduleId = Target module (ModuleId.invalid disables note routing).
         */
        void setMidiTarget(ModuleId moduleId) {
            if (ctx_ !is null) {
                ctx_.midiTarget.store(moduleId.value);
            }
        }

        /**
         * Reads the latest DSP load telemetry (xruns merged from the driver statistics).
         *
         * Params:
         *   outLoad = Receives the snapshot.
         *
         * Returns:
         *   True if a new snapshot arrived since the previous call.
         */
        bool readLoad(out AudioLoadTelemetry outLoad) {
            if (ctx_ is null) {
                return false;
            }
            immutable bool fresh = ctx_.load.read(outLoad);
            if (audio_ !is null) {
                outLoad.xruns = audio_.stats().xrunCount;
            }
            return fresh;
        }

        /**
         * Drains MIDI packets copied by the RT thread (for MIDI learn, recording, and monitoring).
         *
         * Params:
         *   outPackets = Destination buffer.
         *
         * Returns:
         *   Number of packets written.
         */
        size_t drainMidi(MidiPacket[] outPackets) {
            if (ctx_ is null) {
                return 0;
            }
            size_t n = 0;
            while (n < outPackets.length && ctx_.uiMidi.tryPop(outPackets[n])) {
                n++;
            }
            return n;
        }

        /**
         * Sends a packet to the "SynthTracker Live MIDI" virtual source loopback path (self-test).
         *
         * Params:
         *   pkt = Packet to inject into the input ring as if it arrived from hardware.
         *
         * Returns:
         *   True if queued.
         */
        bool injectMidi(MidiPacket pkt) {
            if (midi_ is null || ctx_ is null || ctx_.midiIn is null) {
                return false;
            }
            return (cast(MpscRing!MidiPacket*) ctx_.midiIn).tryPush(pkt);
        }

        private bool followDeviceRate(out string err) {
            immutable float rate = cast(float) audio_.activeSampleRate();
            if (!(rate > 0.0f)) {
                err = "Audio device reported no sample rate";
                return false;
            }
            ctx_.sampleRate = rate;
            if (rate != session_.sampleRate() && !session_.changeSampleRate(rate, err)) {
                return false;
            }
            return true;
        }

        private void connectAllMidiSources() {
            foreach (src; midi_.enumerateSources()) {
                if (src.id !in connectedSources_ && midi_.connectSource(src.id)) {
                    connectedSources_[src.id] = true;
                }
            }
        }

        private void closeDrivers() {
            if (audio_ !is null) {
                audio_.stop();
                audio_.close();
                audio_ = null;
            }
            if (midi_ !is null) {
                midi_.close();
                midi_ = null;
            }
            connectedSources_ = null;
            if (ctx_ !is null) {
                destroyEngineRtContext(ctx_);
                ctx_ = null;
            }
        }
    }
}
