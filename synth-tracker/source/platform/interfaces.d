/**
 * File:         source/platform/interfaces.d
 * Module:       platform.interfaces
 * Phase:        Phase 3.1 — OS-Agnostic Driver & Window Interfaces
 *
 * Purpose:
 *   Defines pure-D hardware/OS interfaces (IAudioDriver, IMidiDriver, IPlatformWindow, IFileDialog) isolating macOS platform implementations to enable future Linux/Windows backends.
 *
 * Real-Time & Safety Contract:
 *   Audio/MIDI callback delegates supplied to drivers must be @nogc nothrow; window/dialog calls run on main UI thread.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: std.traits (hasIndirections)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct AudioDeviceInfo / AudioStreamConfig / AudioDriverStats / AudioNotification
 *   - alias AudioRenderCallback = void function(void* userData, const(float)* inL, const(float)* inR, float* outL, float* outR, uint frames) @nogc nothrow
 *   - struct MidiPacket / MidiDeviceInfo / MidiNotification
 *   - struct PlatformEvent / WindowDesc / FileDialogFilter
 *   - interface IAudioDriver / interface IMidiDriver / interface IPlatformWindow / interface IFileDialog
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.interfaces;

import std.traits : hasIndirections;

/**
 * Hardware audio endpoint metadata returned by platform device enumeration.
 */
struct AudioDeviceInfo {
    uint id = 0;
    string uid;
    string name;
    uint inputChannels = 0;
    uint outputChannels = 0;
    double nominalSampleRate = 44_100.0;
    double[] supportedSampleRates;
    uint minBufferFrames = 32;
    uint maxBufferFrames = 4096;
    bool isDefaultOutput = false;
    bool isDefaultInput = false;
}

/**
 * Configuration requested when opening an IAudioDriver stream.
 */
struct AudioStreamConfig {
    uint outputDeviceId = 0;
    uint inputDeviceId = 0;
    bool enableInput = false;
    double sampleRate = 44_100.0;
    uint bufferFrames = 128;
    uint outputChannels = 2;
    uint inputChannels = 2;
}

/**
 * Real-time audio driver diagnostic counters and negotiated stream parameters.
 */
struct AudioDriverStats {
    ulong callbackCount = 0;
    ulong framesRendered = 0;
    ulong xrunCount = 0;
    ulong inputOverrunCount = 0;
    ulong inputUnderrunCount = 0;
    double activeSampleRate = 44_100.0;
    uint activeBufferFrames = 0;
    double resampleRatio = 1.0;
    size_t lastRtThreadId = 0;
    bool running = false;
    bool duplexDirect = false;
    bool duplexResampled = false;
    bool denormalsSuppressedInCallback = false;
}

static assert(!hasIndirections!AudioDriverStats,
    "AudioDriverStats must remain GC-indirection-free POD");

/**
 * Asynchronous hardware property or device lifecycle notification kinds.
 */
enum AudioNotificationKind : ubyte {
    none = 0,
    sampleRateChanged = 1,
    deviceListChanged = 2,
    defaultOutputChanged = 3,
    defaultInputChanged = 4,
    deviceDisconnected = 5,
    bufferSizeChanged = 6
}

/**
 * Audio device/property notification emitted by CoreAudio listeners via lock-free MPSC queue.
 */
struct AudioNotification {
    AudioNotificationKind kind = AudioNotificationKind.none;
    uint deviceId = 0;
    double newSampleRate = 0.0;
    uint newBufferFrames = 0;
}

static assert(!hasIndirections!AudioNotification,
    "AudioNotification must remain GC-indirection-free POD");

/**
 * Real-time @nogc stereo audio render callback invoked from unregistered RT audio threads.
 */
alias AudioRenderCallback = void function(
    void* userData,
    const(float)* inL,
    const(float)* inR,
    float* outL,
    float* outR,
    uint frames
) @nogc nothrow;

/**
 * Platform-agnostic hardware audio driver contract.
 */
interface IAudioDriver {
    /**
     * Enumerates available hardware audio devices on the host system.
     *
     * Returns:
     *   Array of AudioDeviceInfo descriptors.
     */
    AudioDeviceInfo[] enumerateDevices();

    /**
     * Configures output (and optional direct or resampled duplex input) hardware streams.
     *
     * Params:
     *   config = Requested device IDs, sample rate, buffer frame size, and duplex flags.
     *   callback = Unregistered-thread @nogc nothrow render callback.
     *   userData = Opaque @nogc context pointer forwarded verbatim to callback.
     *
     * Returns:
     *   True if the audio graph hardware pipeline initialized cleanly.
     */
    bool open(const ref AudioStreamConfig config, AudioRenderCallback callback, void* userData);

    /**
     * Starts hardware audio I/O callbacks.
     *
     * Returns:
     *   True if started successfully.
     */
    bool start();

    /**
     * Stops hardware audio I/O callbacks cleanly without destroying stream configuration.
     */
    void stop();

    /**
     * Stops audio I/O, unregisters hardware property listeners, and releases RT resources.
     */
    void close();

    /**
     * Reports whether the hardware audio stream is currently started.
     *
     * Returns:
     *   True when active.
     */
    bool isRunning() const;

    /**
     * Returns the hardware-negotiated output sample rate in Hertz.
     *
     * Returns:
     *   Active sample rate.
     */
    double activeSampleRate() const;

    /**
     * Returns the hardware-negotiated nominal buffer size in frames.
     *
     * Returns:
     *   Active buffer frame count.
     */
    uint activeBufferFrames() const;

    /**
     * Captures a snapshot of driver counters and duplex/resampler status.
     *
     * Returns:
     *   Current AudioDriverStats snapshot.
     */
    AudioDriverStats stats() const;

    /**
     * Dequeues one pending hardware notification posted by OS property listeners.
     *
     * Params:
     *   outNotif = Receives the oldest queued AudioNotification on success.
     *
     * Returns:
     *   True if a notification was available; false when empty.
     */
    bool pollNotification(out AudioNotification outNotif) @nogc nothrow;

    /**
     * Reconciles active stream configuration after default device change, unplug, or rate change.
     *
     * Returns:
     *   True if the stream remains operational or recovered cleanly on fallback hardware.
     */
    bool handleDeviceChange();
}

/**
 * Normalized MIDI 1.0 message categories supported by IMidiDriver and sequencer routing.
 */
enum MidiMessageKind : ubyte {
    unknown = 0,
    noteOn = 1,
    noteOff = 2,
    polyAftertouch = 3,
    controlChange = 4,
    programChange = 5,
    channelAftertouch = 6,
    pitchBend = 7,
    clock = 8,
    start = 9,
    cont = 10,
    stop = 11
}

/**
 * Fixed-size @nogc MIDI 1.0 packet transferred lock-free from CoreMIDI Mach threads to RT audio.
 */
struct MidiPacket {
    ulong timestamp = 0;
    ubyte[3] data = 0;
    ubyte len = 0;
    uint sourceId = 0;

    @nogc nothrow pure @safe:

    /**
     * Returns the MIDI status byte, or 0 if empty.
     *
     * Returns:
     *   First packet byte.
     */
    ubyte status() const {
        return len > 0 ? data[0] : 0;
    }

    /**
     * Returns the zero-based MIDI channel index [0..15] for channel messages.
     *
     * Returns:
     *   Lower 4 bits of status byte.
     */
    ubyte channel() const {
        return cast(ubyte)(status() & 0x0Fu);
    }

    /**
     * Returns the first MIDI data byte (note number, CC index, or bend LSB).
     *
     * Returns:
     *   Second packet byte, or 0 if absent.
     */
    ubyte data1() const {
        return len > 1 ? data[1] : 0;
    }

    /**
     * Returns the second MIDI data byte (velocity, CC value, or bend MSB).
     *
     * Returns:
     *   Third packet byte, or 0 if absent.
     */
    ubyte data2() const {
        return len > 2 ? data[2] : 0;
    }

    /**
     * Classifies the MIDI message type, mapping zero-velocity Note On to Note Off.
     *
     * Returns:
     *   Parsed MidiMessageKind value.
     */
    MidiMessageKind messageKind() const {
        if (len == 0) {
            return MidiMessageKind.unknown;
        }
        immutable ubyte st = data[0];
        if (st >= 0xF8u) {
            switch (st) {
                case 0xF8u:
                    return MidiMessageKind.clock;
                case 0xFAu:
                    return MidiMessageKind.start;
                case 0xFBu:
                    return MidiMessageKind.cont;
                case 0xFCu:
                    return MidiMessageKind.stop;
                default:
                    return MidiMessageKind.unknown;
            }
        }
        switch (st & 0xF0u) {
            case 0x80u:
                return MidiMessageKind.noteOff;
            case 0x90u:
                return data2() == 0 ? MidiMessageKind.noteOff : MidiMessageKind.noteOn;
            case 0xA0u:
                return MidiMessageKind.polyAftertouch;
            case 0xB0u:
                return MidiMessageKind.controlChange;
            case 0xC0u:
                return MidiMessageKind.programChange;
            case 0xD0u:
                return MidiMessageKind.channelAftertouch;
            case 0xE0u:
                return MidiMessageKind.pitchBend;
            default:
                return MidiMessageKind.unknown;
        }
    }

    /**
     * Reports whether this packet represents an active Note On (velocity > 0).
     *
     * Returns:
     *   True if messageKind() == MidiMessageKind.noteOn.
     */
    bool isNoteOn() const {
        return messageKind() == MidiMessageKind.noteOn;
    }

    /**
     * Reports whether this packet represents a Note Off (or zero-velocity Note On).
     *
     * Returns:
     *   True if messageKind() == MidiMessageKind.noteOff.
     */
    bool isNoteOff() const {
        return messageKind() == MidiMessageKind.noteOff;
    }

    /**
     * Reports whether this packet is a Control Change message.
     *
     * Returns:
     *   True if messageKind() == MidiMessageKind.controlChange.
     */
    bool isControlChange() const {
        return messageKind() == MidiMessageKind.controlChange;
    }

    /**
     * Reports whether this packet is a 14-bit Pitch Bend message.
     *
     * Returns:
     *   True if messageKind() == MidiMessageKind.pitchBend.
     */
    bool isPitchBend() const {
        return messageKind() == MidiMessageKind.pitchBend;
    }

    /**
     * Reports whether this packet is a MIDI timing clock pulse (0xF8).
     *
     * Returns:
     *   True if messageKind() == MidiMessageKind.clock.
     */
    bool isClock() const {
        return messageKind() == MidiMessageKind.clock;
    }

    /**
     * Decodes a 14-bit Pitch Bend payload into normalized range [-1.0f, 1.0f].
     *
     * Returns:
     *   Normalized pitch bend where 8192 maps to 0.0f.
     */
    float pitchBendNormalized() const {
        if (!isPitchBend() || len < 3) {
            return 0.0f;
        }
        immutable int raw14 = ((cast(int)(data[2] & 0x7Fu)) << 7) | cast(int)(data[1] & 0x7Fu);
        float norm = cast(float)(raw14 - 8192) * (1.0f / 8192.0f);
        if (norm < -1.0f) {
            norm = -1.0f;
        } else if (norm > 1.0f) {
            norm = 1.0f;
        }
        return norm;
    }

    /**
     * Constructs a 3-byte Note On MidiPacket.
     *
     * Params:
     *   channel = MIDI channel [0..15].
     *   note = MIDI note number [0..127].
     *   velocity = Note velocity [1..127].
     *   timestamp = Host timestamp in Mach ticks or nanoseconds.
     *   sourceId = Source endpoint identifier.
     *
     * Returns:
     *   Populated MidiPacket.
     */
    static MidiPacket makeNoteOn(
        ubyte channel,
        ubyte note,
        ubyte velocity,
        ulong timestamp = 0,
        uint sourceId = 0
    ) {
        MidiPacket pkt;
        pkt.timestamp = timestamp;
        pkt.data = [
            cast(ubyte)(0x90u | (channel & 0x0Fu)),
            cast(ubyte)(note & 0x7Fu),
            cast(ubyte)(velocity & 0x7Fu)
        ];
        pkt.len = 3;
        pkt.sourceId = sourceId;
        return pkt;
    }

    /**
     * Constructs a 3-byte Note Off MidiPacket.
     *
     * Params:
     *   channel = MIDI channel [0..15].
     *   note = MIDI note number [0..127].
     *   velocity = Release velocity [0..127].
     *   timestamp = Host timestamp.
     *   sourceId = Source endpoint identifier.
     *
     * Returns:
     *   Populated MidiPacket.
     */
    static MidiPacket makeNoteOff(
        ubyte channel,
        ubyte note,
        ubyte velocity = 0,
        ulong timestamp = 0,
        uint sourceId = 0
    ) {
        MidiPacket pkt;
        pkt.timestamp = timestamp;
        pkt.data = [
            cast(ubyte)(0x80u | (channel & 0x0Fu)),
            cast(ubyte)(note & 0x7Fu),
            cast(ubyte)(velocity & 0x7Fu)
        ];
        pkt.len = 3;
        pkt.sourceId = sourceId;
        return pkt;
    }

    /**
     * Constructs a 3-byte Control Change MidiPacket.
     *
     * Params:
     *   channel = MIDI channel [0..15].
     *   cc = Controller index [0..127].
     *   value = Controller value [0..127].
     *   timestamp = Host timestamp.
     *   sourceId = Source endpoint identifier.
     *
     * Returns:
     *   Populated MidiPacket.
     */
    static MidiPacket makeControlChange(
        ubyte channel,
        ubyte cc,
        ubyte value,
        ulong timestamp = 0,
        uint sourceId = 0
    ) {
        MidiPacket pkt;
        pkt.timestamp = timestamp;
        pkt.data = [
            cast(ubyte)(0xB0u | (channel & 0x0Fu)),
            cast(ubyte)(cc & 0x7Fu),
            cast(ubyte)(value & 0x7Fu)
        ];
        pkt.len = 3;
        pkt.sourceId = sourceId;
        return pkt;
    }

    /**
     * Constructs a 3-byte 14-bit Pitch Bend MidiPacket centered at 0 offset (8192 raw).
     *
     * Params:
     *   channel = MIDI channel [0..15].
     *   offsetFromCenter = Signed 14-bit bend offset clamped to [-8192, 8191].
     *   timestamp = Host timestamp.
     *   sourceId = Source endpoint identifier.
     *
     * Returns:
     *   Populated MidiPacket.
     */
    static MidiPacket makePitchBend(
        ubyte channel,
        short offsetFromCenter,
        ulong timestamp = 0,
        uint sourceId = 0
    ) {
        int raw = 8192 + cast(int) offsetFromCenter;
        if (raw < 0) {
            raw = 0;
        } else if (raw > 16_383) {
            raw = 16_383;
        }
        MidiPacket pkt;
        pkt.timestamp = timestamp;
        pkt.data = [
            cast(ubyte)(0xE0u | (channel & 0x0Fu)),
            cast(ubyte)(raw & 0x7Fu),
            cast(ubyte)((raw >> 7) & 0x7Fu)
        ];
        pkt.len = 3;
        pkt.sourceId = sourceId;
        return pkt;
    }

    /**
     * Constructs a 1-byte MIDI timing clock packet (0xF8).
     *
     * Params:
     *   timestamp = Host timestamp.
     *   sourceId = Source endpoint identifier.
     *
     * Returns:
     *   Populated MidiPacket.
     */
    static MidiPacket makeClock(ulong timestamp = 0, uint sourceId = 0) {
        MidiPacket pkt;
        pkt.timestamp = timestamp;
        pkt.data = [0xF8u, 0, 0];
        pkt.len = 1;
        pkt.sourceId = sourceId;
        return pkt;
    }
}

static assert(!hasIndirections!MidiPacket,
    "MidiPacket must remain GC-indirection-free POD for lock-free rings");

/**
 * Hardware or virtual MIDI endpoint metadata returned by IMidiDriver enumeration.
 */
struct MidiDeviceInfo {
    uint id = 0;
    string name;
    string displayName;
    bool isInput = false;
    bool isOutput = false;
    bool isOffline = false;
}

/**
 * Asynchronous MIDI subsystem hot-plug notification kinds.
 */
enum MidiNotificationKind : ubyte {
    none = 0,
    setupChanged = 1,
    sourceAdded = 2,
    sourceRemoved = 3,
    destinationAdded = 4,
    destinationRemoved = 5,
    propertyChanged = 6
}

/**
 * Hot-plug event emitted by CoreMIDI notifications into a lock-free MPSC queue.
 */
struct MidiNotification {
    MidiNotificationKind kind = MidiNotificationKind.none;
    uint endpointId = 0;
}

static assert(!hasIndirections!MidiNotification,
    "MidiNotification must remain GC-indirection-free POD");

/**
 * Platform-agnostic hardware & virtual MIDI driver contract.
 */
interface IMidiDriver {
    /**
     * Initializes the MIDI client, input/output ports, and hot-plug listener.
     *
     * Params:
     *   clientName = Human-readable client identifier registered with the OS MIDI server.
     *
     * Returns:
     *   True if initialized successfully.
     */
    bool open(string clientName = "SynthTracker");

    /**
     * Disconnects endpoints, disposes virtual ports/client, and frees native RT ring state.
     */
    void close();

    /**
     * Reports whether the MIDI client is currently open.
     *
     * Returns:
     *   True when opened.
     */
    bool isOpen() const;

    /**
     * Enumerates currently registered MIDI input source endpoints.
     *
     * Returns:
     *   Array of input MidiDeviceInfo descriptors.
     */
    MidiDeviceInfo[] enumerateSources();

    /**
     * Enumerates currently registered MIDI output destination endpoints.
     *
     * Returns:
     *   Array of output MidiDeviceInfo descriptors.
     */
    MidiDeviceInfo[] enumerateDestinations();

    /**
     * Connects a MIDI source endpoint by unique/endpoint ID to the driver's input ring.
     *
     * Params:
     *   sourceId = Source endpoint identifier.
     *
     * Returns:
     *   True if connected (or already connected).
     */
    bool connectSource(uint sourceId);

    /**
     * Disconnects a previously connected MIDI source endpoint.
     *
     * Params:
     *   sourceId = Source endpoint identifier.
     *
     * Returns:
     *   True if disconnected cleanly.
     */
    bool disconnectSource(uint sourceId);

    /**
     * Connects every currently available physical and virtual MIDI source endpoint.
     *
     * Returns:
     *   Total count of connected sources.
     */
    size_t connectAllSources();

    /**
     * Refreshes active input/output endpoint tables after a hot-plug setup notification.
     *
     * Returns:
     *   Number of currently connected MIDI sources after reconciliation.
     */
    size_t refreshConnections();

    /**
     * Creates an OS virtual MIDI destination receiving incoming packets from other apps.
     *
     * Params:
     *   name = Visible endpoint name.
     *
     * Returns:
     *   True on success.
     */
    bool createVirtualDestination(string name);

    /**
     * Creates an OS virtual MIDI source broadcasting packets emitted via sendToVirtualSource().
     *
     * Params:
     *   name = Visible endpoint name.
     *
     * Returns:
     *   True on success.
     */
    bool createVirtualSource(string name);

    /**
     * Sends a MIDI packet to a known hardware or virtual destination endpoint lock-free.
     *
     * Params:
     *   destinationId = Destination endpoint identifier.
     *   packet = Valid 1..3-byte MIDI packet payload.
     *
     * Returns:
     *   True if dispatched cleanly to the OS MIDI API.
     */
    bool sendPacket(uint destinationId, const ref MidiPacket packet) @nogc nothrow;

    /**
     * Broadcasts a MIDI packet out through the driver's virtual MIDI source endpoint.
     *
     * Params:
     *   packet = Valid 1..3-byte MIDI packet payload.
     *
     * Returns:
     *   True if broadcast cleanly.
     */
    bool sendToVirtualSource(const ref MidiPacket packet) @nogc nothrow;

    /**
     * Dequeues the oldest received MidiPacket for consumption on the RT audio thread.
     *
     * Params:
     *   outPacket = Receives the dequeued packet.
     *
     * Returns:
     *   True if a packet was ready; false when queue is empty.
     */
    bool pollPacket(out MidiPacket outPacket) @nogc nothrow;

    /**
     * Dequeues the oldest pending MIDI topology notification on the control/UI thread.
     *
     * Params:
     *   outNotif = Receives the dequeued MidiNotification.
     *
     * Returns:
     *   True if a notification was available; false when empty.
     */
    bool pollNotification(out MidiNotification outNotif) @nogc nothrow;
}

/**
 * Platform window input and lifecycle event kinds used by IPlatformWindow (Phase 7).
 */
enum PlatformEventKind : ubyte {
    none = 0,
    keyDown = 1,
    keyUp = 2,
    textInput = 3,
    mouseDown = 4,
    mouseUp = 5,
    mouseMove = 6,
    mouseScroll = 7,
    magnify = 8,
    resize = 9,
    closeRequested = 10,
    focusChanged = 11
}

/**
 * Keyboard modifier bitmask flags attached to PlatformEvent inputs.
 */
enum KeyModifiers : uint {
    none = 0,
    shift = 1u << 0,
    control = 1u << 1,
    alt = 1u << 2,
    command = 1u << 3
}

/**
 * OS-agnostic UI window event delivered on the main UI thread.
 */
struct PlatformEvent {
    PlatformEventKind kind = PlatformEventKind.none;
    float x = 0.0f;
    float y = 0.0f;
    float deltaX = 0.0f;
    float deltaY = 0.0f;
    float magnification = 0.0f;
    float scaleFactor = 1.0f;
    uint width = 0;
    uint height = 0;
    uint keyCode = 0;
    uint modifiers = 0;
    ubyte mouseButton = 0;
    dchar utf32Char = 0;
    bool isRepeat = false;
    bool focused = false;
}

static assert(!hasIndirections!PlatformEvent,
    "PlatformEvent must remain GC-indirection-free POD");

/**
 * Native window creation parameters passed to IPlatformWindow.create().
 */
struct WindowDesc {
    string title = "SynthTracker";
    uint width = 1280;
    uint height = 800;
    uint minWidth = 640;
    uint minHeight = 480;
    bool resizable = true;
}

/**
 * Platform-agnostic host window contract implemented by macOS AppKit in Phase 7.
 */
interface IPlatformWindow {
    /**
     * Creates and presents the native host window.
     *
     * Params:
     *   desc = Initial title, dimensions, and sizing constraints.
     *
     * Returns:
     *   True if window creation succeeded.
     */
    bool create(const ref WindowDesc desc);

    /**
     * Tears down and releases the native window and view resources.
     */
    void destroy();

    /**
     * Reports whether the window remains open and active.
     *
     * Returns:
     *   True until destroyed or user closes window.
     */
    bool isOpen() const;

    /**
     * Pumps pending OS UI events into outEvents up to outEvents.length capacity.
     *
     * Params:
     *   outEvents = Pre-allocated destination slice populated with events.
     *
     * Returns:
     *   Number of events written into outEvents.
     */
    size_t pollEvents(PlatformEvent[] outEvents);

    /**
     * Updates the native window title string.
     *
     * Params:
     *   title = New window title text.
     */
    void setTitle(string title);

    /**
     * Queries the current backing drawable dimensions in physical pixels and Retina scale.
     *
     * Params:
     *   width = Receives backing drawable width in pixels.
     *   height = Receives backing drawable height in pixels.
     *   scaleFactor = Receives HiDPI scale multiplier.
     */
    void getDrawableSize(out uint width, out uint height, out float scaleFactor) const;

    /**
     * Returns the native backing render layer handle (CAMetalLayer on macOS).
     *
     * Returns:
     *   Opaque native layer pointer.
     */
    void* nativeLayerHandle() const;

    /**
     * Returns the underlying native window handle (NSWindow pointer on macOS).
     *
     * Returns:
     *   Opaque native window pointer.
     */
    void* nativeWindowHandle() const;

    /**
     * Reads UTF-8 plain text from the OS clipboard, or empty string if unavailable.
     *
     * Returns:
     *   Clipboard text.
     */
    string getClipboardText();

    /**
     * Writes UTF-8 plain text to the OS clipboard.
     *
     * Params:
     *   text = UTF-8 string to place on the clipboard.
     *
     * Returns:
     *   True if the clipboard write succeeded.
     */
    bool setClipboardText(string text);
}

/**
 * Extension filter entry passed to native open/save file panels.
 */
struct FileDialogFilter {
    string label;
    string[] extensions;
}

/**
 * Platform-agnostic file open/save dialog contract implemented cleanly for macOS in Phase 7.
 */
interface IFileDialog {
    /**
     * Prompts the user to select an existing file path matching filters.
     *
     * Params:
     *   title = Dialog title.
     *   filters = Allowed file extension filters.
     *   selectedPath = Receives the chosen file path when accepted.
     *
     * Returns:
     *   True if the user confirmed a selection; false if canceled.
     */
    bool openFile(string title, const(FileDialogFilter)[] filters, out string selectedPath);

    /**
     * Prompts the user for a destination path to save a file.
     *
     * Params:
     *   title = Dialog title.
     *   defaultName = Suggested default filename.
     *   filters = Allowed file extension filters.
     *   selectedPath = Receives the chosen destination path when accepted.
     *
     * Returns:
     *   True if the user confirmed a destination; false if canceled.
     */
    bool saveFile(
        string title,
        string defaultName,
        const(FileDialogFilter)[] filters,
        out string selectedPath
    );
}
