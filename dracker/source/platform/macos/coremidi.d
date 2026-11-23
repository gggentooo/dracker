/**
 * File:         source/platform/macos/coremidi.d
 * Module:       platform.macos.coremidi
 * Phase:        Phase 3.3 — CoreMIDI Multi-Source Input/Output Driver
 *
 * Purpose:
 *   Binds macOS CoreMIDI endpoints, parses MIDI 1.0 packet lists cleanly into fixed @nogc MidiPackets on CoreMIDI Mach threads via MpscRing, translates messages into sample-accurate ModEvents, and tracks hot-plug setup changes.
 *
 * Real-Time & Safety Contract:
 *   midiReadProc and midiNotifyProc are extern(C) @nogc nothrow with zero GC references, zero D TLS accesses, and zero blocking locks or allocations.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.concurrency, graph.event, platform.interfaces, platform.macos.corefoundation
 *   External: core.lifetime, core.stdc.stdlib, core.stdc.string, macOS CoreMIDI.framework
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct MIDIPacket / MIDIPacketList / MIDINotification + CoreMIDI extern(C) bindings
 *   - const(MIDIPacket)* midiPacketNext(...) @nogc nothrow pure
 *   - size_t parseMidiBytes(...) @nogc nothrow / void parseMidiPacketList(...) @nogc nothrow
 *   - struct MidiNoteTracker / bool translateMidiPacketToModEvent(...) @nogc nothrow pure @safe
 *   - struct CoreMidiRtContext / extern(C) midiReadProc / midiNotifyProc @nogc nothrow
 *   - class CoreMidiDriver : IMidiDriver
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.macos.coremidi;

import core.lifetime : emplace;
import core.stdc.string : memcpy;
import std.traits : hasIndirections;

import foundation.concurrency : Atomic, MpscRing, hasGcReference;
import foundation.types : NoteId;
import graph.event : ModEvent, ModEventKind;
import platform.interfaces;

/**
 * Polyphonic MIDI channel+note to NoteId tracker mapping incoming Note On and Note Off pairs.
 */
struct MidiNoteTracker {
    private uint[128][16] activeNotes_ = 0;
    private uint nextNoteId_ = 1;

    @nogc nothrow pure @safe:

    /**
     * Resets all tracked channel/note slots and restarts monotonic NoteId generation cleanly.
     */
    void reset() {
        foreach (ch; 0 .. 16) {
            activeNotes_[ch][] = 0;
        }
        nextNoteId_ = 1;
    }

    /**
     * Allocates a non-zero NoteId for an incoming MIDI Note On event on (channel, note).
     *
     * Params:
     *   channel = Zero-based MIDI channel [0..15].
     *   note = MIDI note number [0..127].
     *
     * Returns:
     *   Assigned non-zero NoteId stored until the matching Note Off.
     */
    NoteId noteOn(ubyte channel, ubyte note) {
        uint id = nextNoteId_++;
        if (nextNoteId_ == 0) {
            nextNoteId_ = 1;
        }
        if (id == 0) {
            id = 1;
        }
        activeNotes_[channel & 0x0Fu][note & 0x7Fu] = id;
        return NoteId(id);
    }

    /**
     * Looks up and clears the active NoteId associated with (channel, note).
     *
     * Params:
     *   channel = Zero-based MIDI channel [0..15].
     *   note = MIDI note number [0..127].
     *
     * Returns:
     *   Matching NoteId if previously triggered, or NoteId.none when inactive.
     */
    NoteId noteOff(ubyte channel, ubyte note) {
        immutable uint c = channel & 0x0Fu;
        immutable uint n = note & 0x7Fu;
        immutable uint existing = activeNotes_[c][n];
        activeNotes_[c][n] = 0;
        return existing != 0 ? NoteId(existing) : NoteId.none;
    }

    /**
     * Peeks at the active NoteId currently assigned to (channel, note) without releasing it.
     *
     * Params:
     *   channel = Zero-based MIDI channel [0..15].
     *   note = MIDI note number [0..127].
     *
     * Returns:
     *   Active NoteId, or NoteId.none if silent.
     */
    NoteId activeNote(ubyte channel, ubyte note) const {
        immutable uint id = activeNotes_[channel & 0x0Fu][note & 0x7Fu];
        return id != 0 ? NoteId(id) : NoteId.none;
    }
}

static assert(!hasGcReference!MidiNoteTracker,
    "MidiNoteTracker must remain GC-indirection-free POD");

/**
 * Translates one normalized MidiPacket into a graph ModEvent at frameOffset.
 *
 * Note On allocates a NoteId in tracker, Note Off (and velocity-0 Note On) resolves the prior
 * NoteId, Control Change 120/123 emits allNotesOff, other CCs emit setParam, Pitch Bend emits
 * continuous setPitch in semitones, and timing clock/transport bytes emit transport events.
 *
 * Params:
 *   pkt = Incoming MIDI packet.
 *   tracker = Polyphonic MIDI note-to-NoteId state map.
 *   outEvent = Populated ModEvent on return when translation applies.
 *   frameOffset = Sample offset inside the current audio slice.
 *   pitchBendRangeSemitones = Half-range pitch bend scale in semitones.
 *
 * Returns:
 *   True if outEvent contains an actionable graph event; false if the packet produced no event.
 */
bool translateMidiPacketToModEvent(
    const ref MidiPacket pkt,
    ref MidiNoteTracker tracker,
    out ModEvent outEvent,
    uint frameOffset = 0,
    float pitchBendRangeSemitones = 2.0f
) @nogc nothrow pure @safe {
    final switch (pkt.messageKind()) {
        case MidiMessageKind.noteOn:
            immutable NoteId nid = tracker.noteOn(pkt.channel(), pkt.data1());
            immutable float vel = cast(float)(pkt.data2() & 0x7Fu) * (1.0f / 127.0f);
            outEvent = ModEvent.makeNoteOn(nid, cast(float)(pkt.data1() & 0x7Fu), vel, frameOffset);
            return true;

        case MidiMessageKind.noteOff:
            immutable NoteId nid = tracker.noteOff(pkt.channel(), pkt.data1());
            if (!nid.isValid()) {
                return false;
            }
            outEvent = ModEvent.makeNoteOff(nid, frameOffset);
            return true;

        case MidiMessageKind.controlChange:
            immutable ubyte cc = cast(ubyte)(pkt.data1() & 0x7Fu);
            if (cc == 120 || cc == 123) {
                tracker.reset();
                outEvent = ModEvent.makeAllNotesOff(frameOffset);
                return true;
            }
            immutable float val = cast(float)(pkt.data2() & 0x7Fu) * (1.0f / 127.0f);
            outEvent = ModEvent.makeSetParam(cc, val, false, frameOffset);
            return true;

        case MidiMessageKind.pitchBend:
            outEvent = ModEvent.makeSetPitch(
                NoteId.none,
                pkt.pitchBendNormalized() * pitchBendRangeSemitones,
                frameOffset
            );
            return true;

        case MidiMessageKind.clock:
        case MidiMessageKind.start:
        case MidiMessageKind.cont:
        case MidiMessageKind.stop:
            outEvent = ModEvent(frameOffset, ModEventKind.transport, NoteId.none, pkt.status(), 0.0f, 0.0f);
            return true;

        case MidiMessageKind.polyAftertouch:
            immutable NoteId nid = tracker.activeNote(pkt.channel(), pkt.data1());
            if (!nid.isValid()) {
                return false;
            }
            immutable float pressure = cast(float)(pkt.data2() & 0x7Fu) * (1.0f / 127.0f);
            outEvent = ModEvent.makeSetVelocity(nid, pressure, frameOffset);
            return true;

        case MidiMessageKind.programChange:
        case MidiMessageKind.channelAftertouch:
        case MidiMessageKind.unknown:
            return false;
    }
}

version (OSX):

import core.stdc.stdlib : calloc, free;
import platform.macos.corefoundation : CFStringRef, ScopedCF, cfStringToDString, createCFString;

alias MIDIClientRef = uint;
alias MIDIPortRef = uint;
alias MIDIEndpointRef = uint;
alias MIDIObjectRef = uint;
alias MIDITimeStamp = ulong;
alias MIDIUniqueID = int;
alias ItemCount = size_t;
alias MIDIOSStatus = int;

/**
 * CoreMIDI packet entry matching Apple MIDIServices.h #pragma pack(4) layout.
 */
align(4) struct MIDIPacket {
    align(4) MIDITimeStamp timeStamp = 0;
    align(1) ushort length = 0;
    align(1) ubyte[256] data = 0;
}

/**
 * Variable-length CoreMIDI packet list header matching Apple MIDIServices.h layout.
 */
align(4) struct MIDIPacketList {
    align(4) uint numPackets = 0;
    align(4) MIDIPacket[1] packet;
}

/**
 * CoreMIDI topology/property notification header matching MIDINotification.
 */
struct MIDINotification {
    int messageID = 0;
    uint messageSize = 0;
}

enum int kMIDIMsgSetupChanged = 1;
enum int kMIDIMsgObjectAdded = 2;
enum int kMIDIMsgObjectRemoved = 3;
enum int kMIDIMsgPropertyChanged = 4;

enum MIDIOSStatus midiNoErr = 0;
enum size_t MAX_MIDI_DEST_MAP = 64;

alias MIDINotifyProc = extern(C) void function(const(MIDINotification)* message, void* refCon) @nogc nothrow;
alias MIDIReadProc = extern(C) void function(
    const(MIDIPacketList)* pktlist,
    void* readProcRefCon,
    void* srcConnRefCon
) @nogc nothrow;

static assert(MIDIPacket.sizeof == 268 && MIDIPacket.alignof == 4);
static assert(MIDIPacket.timeStamp.offsetof == 0 && MIDIPacket.length.offsetof == 8 && MIDIPacket.data.offsetof == 10);
static assert(MIDIPacketList.sizeof == 272 && MIDIPacketList.alignof == 4 && MIDIPacketList.packet.offsetof == 4);
static assert(MIDINotification.sizeof == 8 && MIDINotification.messageSize.offsetof == 4);

extern(C) @nogc nothrow {
    extern __gshared const CFStringRef kMIDIPropertyName;
    extern __gshared const CFStringRef kMIDIPropertyDisplayName;
    extern __gshared const CFStringRef kMIDIPropertyUniqueID;
    extern __gshared const CFStringRef kMIDIPropertyOffline;

    MIDIOSStatus MIDIClientCreate(
        CFStringRef name,
        MIDINotifyProc notifyProc,
        void* notifyRefCon,
        MIDIClientRef* outClient
    );
    MIDIOSStatus MIDIClientDispose(MIDIClientRef client);

    MIDIOSStatus MIDIInputPortCreate(
        MIDIClientRef client,
        CFStringRef portName,
        MIDIReadProc readProc,
        void* refCon,
        MIDIPortRef* outPort
    );
    MIDIOSStatus MIDIOutputPortCreate(
        MIDIClientRef client,
        CFStringRef portName,
        MIDIPortRef* outPort
    );
    MIDIOSStatus MIDIPortDispose(MIDIPortRef port);

    MIDIOSStatus MIDIPortConnectSource(
        MIDIPortRef port,
        MIDIEndpointRef source,
        void* connRefCon
    );
    MIDIOSStatus MIDIPortDisconnectSource(MIDIPortRef port, MIDIEndpointRef source);

    MIDIOSStatus MIDISourceCreate(MIDIClientRef client, CFStringRef name, MIDIEndpointRef* outSrc);
    MIDIOSStatus MIDIDestinationCreate(
        MIDIClientRef client,
        CFStringRef name,
        MIDIReadProc readProc,
        void* refCon,
        MIDIEndpointRef* outDest
    );
    MIDIOSStatus MIDIEndpointDispose(MIDIEndpointRef endpt);

    ItemCount MIDIGetNumberOfSources();
    MIDIEndpointRef MIDIGetSource(ItemCount sourceIndex0);
    ItemCount MIDIGetNumberOfDestinations();
    MIDIEndpointRef MIDIGetDestination(ItemCount destIndex0);

    MIDIOSStatus MIDIObjectGetStringProperty(
        MIDIObjectRef obj,
        CFStringRef propertyID,
        CFStringRef* str
    );
    MIDIOSStatus MIDIObjectGetIntegerProperty(
        MIDIObjectRef obj,
        CFStringRef propertyID,
        int* outValue
    );

    MIDIOSStatus MIDISend(MIDIPortRef port, MIDIEndpointRef dest, const(MIDIPacketList)* pktlist);
    MIDIOSStatus MIDIReceived(MIDIEndpointRef src, const(MIDIPacketList)* pktlist);
}

/**
 * Architecture-accurate replacement for C's MIDIPacketNext macro (4-byte aligned on ARM/ARM64, packed on x86_64).
 *
 * Uses memcpy when reading packet length so unaligned packed packets on x86_64 never fault.
 *
 * Params:
 *   pkt = Pointer to current MIDIPacket inside a MIDIPacketList.
 *
 * Returns:
 *   Pointer to the subsequent MIDIPacket entry.
 */
const(MIDIPacket)* midiPacketNext(const(MIDIPacket)* pkt) @nogc nothrow pure {
    if (pkt is null) {
        return null;
    }
    ushort pktLen = 0;
    memcpy(&pktLen, &(pkt.length), ushort.sizeof);
    immutable size_t rawNext = cast(size_t)(cast(const(ubyte)*) pkt + MIDIPacket.data.offsetof + pktLen);
    version (AArch64) {
        return cast(const(MIDIPacket)*)((rawNext + 3) & ~cast(size_t) 3);
    } else version (ARM) {
        return cast(const(MIDIPacket)*)((rawNext + 3) & ~cast(size_t) 3);
    } else {
        return cast(const(MIDIPacket)*) rawNext;
    }
}

private uint expectedMidiChannelOrCommonLength(ubyte statusByte) @nogc nothrow pure @safe {
    if (statusByte >= 0xF8u) {
        return 1;
    }
    if (statusByte >= 0xF0u) {
        switch (statusByte) {
            case 0xF1u:
            case 0xF3u:
                return 2;
            case 0xF2u:
                return 3;
            case 0xF6u:
                return 1;
            default:
                return 0;
        }
    }
    immutable ubyte upper = cast(ubyte)(statusByte & 0xF0u);
    if (upper == 0xC0u || upper == 0xD0u) {
        return 2;
    }
    if (upper >= 0x80u && upper <= 0xE0u) {
        return 3;
    }
    return 0;
}

private void pushParsedPacket(
    const ref MidiPacket pkt,
    ref MpscRing!MidiPacket ring,
    ref Atomic!ulong receivedCount,
    ref Atomic!ulong droppedCount
) @nogc nothrow {
    if (ring.tryPush(pkt)) {
        receivedCount.fetchAdd(1);
    } else {
        droppedCount.fetchAdd(1);
    }
}

/**
 * Parses a raw MIDI 1.0 byte stream (including running status, interleaved real-time bytes, and SysEx)
 * into fixed-length @nogc MidiPackets pushed into ring.
 *
 * Params:
 *   bytes = Raw MIDI 1.0 byte slice from one CoreMIDI packet.
 *   timestamp = Packet timestamp copied onto emitted MidiPackets.
 *   sourceId = Source endpoint identifier copied onto emitted MidiPackets.
 *   ring = Destination bounded MpscRing!MidiPacket.
 *   receivedCount = Atomic counter incremented per accepted packet.
 *   droppedCount = Atomic counter incremented per dropped packet when ring is full.
 *   inSysEx = Persistent SysEx state across fragmented packet boundaries.
 *   runningStatus = Persistent MIDI running status byte within a packet list.
 *
 * Returns:
 *   Number of discrete MidiPackets parsed from bytes.
 */
size_t parseMidiBytes(
    const(ubyte)[] bytes,
    ulong timestamp,
    uint sourceId,
    ref MpscRing!MidiPacket ring,
    ref Atomic!ulong receivedCount,
    ref Atomic!ulong droppedCount,
    ref bool inSysEx,
    ref ubyte runningStatus
) @nogc nothrow {
    size_t parsedCount = 0;
    size_t idx = 0;

    while (idx < bytes.length) {
        immutable ubyte b = bytes[idx];

        if (b >= 0xF8u) {
            if (b == 0xF8u || b == 0xFAu || b == 0xFBu || b == 0xFCu || b == 0xFFu) {
                MidiPacket rtPkt;
                rtPkt.timestamp = timestamp;
                rtPkt.data = [b, 0, 0];
                rtPkt.len = 1;
                rtPkt.sourceId = sourceId;
                pushParsedPacket(rtPkt, ring, receivedCount, droppedCount);
                parsedCount++;
            }
            idx++;
            continue;
        }

        if (inSysEx) {
            if (b == 0xF7u) {
                inSysEx = false;
                idx++;
            } else if (b >= 0x80u) {
                inSysEx = false;
            } else {
                idx++;
            }
            continue;
        }

        if (b == 0xF0u) {
            runningStatus = 0;
            inSysEx = true;
            idx++;
            continue;
        }

        if (b == 0xF7u) {
            runningStatus = 0;
            inSysEx = false;
            idx++;
            continue;
        }

        if (b >= 0x80u) {
            immutable uint msgLen = expectedMidiChannelOrCommonLength(b);
            if (b < 0xF0u) {
                runningStatus = b;
            } else {
                runningStatus = 0;
            }
            if (msgLen == 0) {
                idx++;
                continue;
            }
            if (msgLen == 1) {
                MidiPacket pkt;
                pkt.timestamp = timestamp;
                pkt.data = [b, 0, 0];
                pkt.len = 1;
                pkt.sourceId = sourceId;
                pushParsedPacket(pkt, ring, receivedCount, droppedCount);
                parsedCount++;
                idx++;
                continue;
            }

            ubyte[2] dataBytes = 0;
            ubyte collected = 0;
            size_t scan = idx + 1;
            immutable ubyte needData = cast(ubyte)(msgLen - 1);
            bool abortedByStatus = false;

            while (scan < bytes.length && collected < needData) {
                immutable ubyte nb = bytes[scan];
                if (nb >= 0xF8u) {
                    if (nb == 0xF8u || nb == 0xFAu || nb == 0xFBu || nb == 0xFCu || nb == 0xFFu) {
                        MidiPacket rtPkt;
                        rtPkt.timestamp = timestamp;
                        rtPkt.data = [nb, 0, 0];
                        rtPkt.len = 1;
                        rtPkt.sourceId = sourceId;
                        pushParsedPacket(rtPkt, ring, receivedCount, droppedCount);
                        parsedCount++;
                    }
                    scan++;
                    continue;
                }
                if (nb >= 0x80u) {
                    abortedByStatus = true;
                    break;
                }
                dataBytes[collected++] = nb;
                scan++;
            }

            if (!abortedByStatus && collected == needData) {
                MidiPacket pkt;
                pkt.timestamp = timestamp;
                pkt.data[0] = b;
                pkt.data[1] = dataBytes[0];
                pkt.data[2] = needData > 1 ? dataBytes[1] : 0;
                pkt.len = cast(ubyte) msgLen;
                pkt.sourceId = sourceId;
                pushParsedPacket(pkt, ring, receivedCount, droppedCount);
                parsedCount++;
                idx = scan;
            } else {
                idx = abortedByStatus ? scan : bytes.length;
            }
        } else {
            if (runningStatus < 0x80u || runningStatus >= 0xF0u) {
                idx++;
                continue;
            }
            immutable uint msgLen = expectedMidiChannelOrCommonLength(runningStatus);
            if (msgLen < 2) {
                idx++;
                continue;
            }

            ubyte[2] dataBytes = 0;
            dataBytes[0] = b;
            ubyte collected = 1;
            size_t scan = idx + 1;
            immutable ubyte needData = cast(ubyte)(msgLen - 1);
            bool abortedByStatus = false;

            while (scan < bytes.length && collected < needData) {
                immutable ubyte nb = bytes[scan];
                if (nb >= 0xF8u) {
                    if (nb == 0xF8u || nb == 0xFAu || nb == 0xFBu || nb == 0xFCu || nb == 0xFFu) {
                        MidiPacket rtPkt;
                        rtPkt.timestamp = timestamp;
                        rtPkt.data = [nb, 0, 0];
                        rtPkt.len = 1;
                        rtPkt.sourceId = sourceId;
                        pushParsedPacket(rtPkt, ring, receivedCount, droppedCount);
                        parsedCount++;
                    }
                    scan++;
                    continue;
                }
                if (nb >= 0x80u) {
                    abortedByStatus = true;
                    break;
                }
                dataBytes[collected++] = nb;
                scan++;
            }

            if (!abortedByStatus && collected == needData) {
                MidiPacket pkt;
                pkt.timestamp = timestamp;
                pkt.data[0] = runningStatus;
                pkt.data[1] = dataBytes[0];
                pkt.data[2] = needData > 1 ? dataBytes[1] : 0;
                pkt.len = cast(ubyte) msgLen;
                pkt.sourceId = sourceId;
                pushParsedPacket(pkt, ring, receivedCount, droppedCount);
                parsedCount++;
                idx = scan;
            } else {
                idx = abortedByStatus ? scan : bytes.length;
            }
        }
    }

    return parsedCount;
}

/**
 * Decodes every variable-length MIDIPacket in pktlist using architecture-safe alignment strides.
 *
 * Params:
 *   pktlist = Incoming CoreMIDI MIDIPacketList pointer.
 *   sourceId = Source endpoint identifier associated with the list.
 *   ring = Destination lock-free MpscRing!MidiPacket.
 *   receivedCount = Counter updated per queued packet.
 *   droppedCount = Counter updated per overflow-dropped packet.
 *
 * Returns:
 *   Number of normalized MidiPackets pushed into ring.
 */
size_t parseMidiPacketList(
    const(MIDIPacketList)* pktlist,
    uint sourceId,
    MpscRing!MidiPacket* ring,
    Atomic!ulong* receivedCount,
    Atomic!ulong* droppedCount
) @nogc nothrow {
    if (pktlist is null || ring is null || receivedCount is null || droppedCount is null) {
        return 0;
    }
    immutable uint count = pktlist.numPackets;
    const(MIDIPacket)* pkt = &pktlist.packet[0];
    bool inSysEx = false;
    ubyte runningStatus = 0;
    size_t totalParsed = 0;

    foreach (_; 0 .. count) {
        MIDITimeStamp ts = 0;
        ushort len = 0;
        memcpy(&ts, &(pkt.timeStamp), MIDITimeStamp.sizeof);
        memcpy(&len, &(pkt.length), ushort.sizeof);
        immutable size_t safeLen = len <= 256 ? len : 256;
        if (safeLen > 0) {
            totalParsed += parseMidiBytes(
                pkt.data.ptr[0 .. safeLen],
                ts,
                sourceId,
                *ring,
                *receivedCount,
                *droppedCount,
                inSysEx,
                runningStatus
            );
        }
        pkt = midiPacketNext(pkt);
    }
    return totalParsed;
}

/**
 * Destination ID-to-MIDIEndpointRef cache slot readable without allocations during @nogc MIDISend.
 */
struct MidiDestinationSlot {
    uint id = 0;
    MIDIEndpointRef endpoint = 0;
}

/**
 * Unmanaged @nogc CoreMIDI callback state block holding lock-free MPSC queues and endpoints.
 *
 * Zero GC references ensure CoreMIDI Mach callback threads never interact with the D GC runtime.
 */
struct CoreMidiRtContext {
    MpscRing!MidiPacket packetRing;
    MpscRing!MidiNotification notifRing;

    Atomic!int active;
    Atomic!ulong packetsReceived;
    Atomic!ulong packetsDropped;
    Atomic!ulong notificationsReceived;

    MIDIClientRef client = 0;
    MIDIPortRef inputPort = 0;
    MIDIPortRef outputPort = 0;
    MIDIEndpointRef virtualDest = 0;
    MIDIEndpointRef virtualSrc = 0;

    MidiDestinationSlot[MAX_MIDI_DEST_MAP] destinations;
    Atomic!size_t destinationCount;

    @disable this(this);

    @nogc nothrow:

    /**
     * Releases backing lock-free rings cleanly off the real-time path.
     */
    void releaseRings() {
        active.store(0);
        packetRing.reset();
        notifRing.reset();
        destinationCount.store(0);
    }

    /**
     * Looks up a cached MIDIEndpointRef by destination identifier without GC allocation.
     *
     * Params:
     *   destId = Logical MIDI destination unique/endpoint identifier.
     *
     * Returns:
     *   Matching MIDIEndpointRef, or 0 if not cached.
     */
    MIDIEndpointRef findDestinationEndpoint(uint destId) const {
        immutable size_t count = destinationCount.load();
        immutable size_t bounded = count <= MAX_MIDI_DEST_MAP ? count : MAX_MIDI_DEST_MAP;
        foreach (i; 0 .. bounded) {
            if (destinations[i].id == destId) {
                return destinations[i].endpoint;
            }
        }
        return 0;
    }
}

static assert(!hasGcReference!CoreMidiRtContext,
    "CoreMidiRtContext passed to CoreMIDI Mach threads must contain zero GC references");

/**
 * CoreMIDI Mach-thread read callback decoding incoming packets lock-free into CoreMidiRtContext.
 */
extern(C) void midiReadProc(
    const(MIDIPacketList)* pktlist,
    void* readProcRefCon,
    void* srcConnRefCon
) @nogc nothrow {
    auto ctx = cast(CoreMidiRtContext*) readProcRefCon;
    if (ctx is null || pktlist is null || ctx.active.load() == 0) {
        return;
    }
    immutable uint sourceId = cast(uint) cast(size_t) srcConnRefCon;
    parseMidiPacketList(
        pktlist,
        sourceId,
        &ctx.packetRing,
        &ctx.packetsReceived,
        &ctx.packetsDropped
    );
}

/**
 * CoreMIDI subsystem notification callback forwarding hot-plug setup events into MpscRing.
 */
extern(C) void midiNotifyProc(const(MIDINotification)* message, void* refCon) @nogc nothrow {
    auto ctx = cast(CoreMidiRtContext*) refCon;
    if (ctx is null || message is null || ctx.active.load() == 0) {
        return;
    }
    MidiNotification notif;
    switch (message.messageID) {
        case kMIDIMsgSetupChanged:
            notif.kind = MidiNotificationKind.setupChanged;
            break;
        case kMIDIMsgObjectAdded:
            notif.kind = MidiNotificationKind.sourceAdded;
            break;
        case kMIDIMsgObjectRemoved:
            notif.kind = MidiNotificationKind.sourceRemoved;
            break;
        case kMIDIMsgPropertyChanged:
            notif.kind = MidiNotificationKind.propertyChanged;
            break;
        default:
            return;
    }
    ctx.notificationsReceived.fetchAdd(1);
    ctx.notifRing.tryPush(notif);
}

/**
 * macOS CoreMIDI implementation of IMidiDriver supporting hardware/virtual multi-source routing.
 */
class CoreMidiDriver : IMidiDriver {
    private struct ConnectedSource {
        uint id = 0;
        MIDIEndpointRef endpoint = 0;
    }

    private CoreMidiRtContext* rtCtx_ = null;
    private ConnectedSource[] connectedSources_;
    private bool open_ = false;

    /**
     * Releases CoreMIDI client/ports/endpoints and frees unmanaged RT rings on teardown.
     */
    ~this() {
        close();
    }

    /**
     * Creates CoreMIDI client, input port, output port, and unmanaged MPSC rings.
     *
     * Params:
     *   clientName = Display name registered with CoreMIDI.
     *
     * Returns:
     *   True if CoreMIDI initialized cleanly.
     */
    override bool open(string clientName = "Dracker") {
        close();

        auto ctx = cast(CoreMidiRtContext*) calloc(1, CoreMidiRtContext.sizeof);
        if (ctx is null) {
            return false;
        }
        emplace(ctx);

        if (!MpscRing!MidiPacket.tryCreate(2048, ctx.packetRing)
                || !MpscRing!MidiNotification.tryCreate(64, ctx.notifRing)) {
            ctx.releaseRings();
            destroy!false(*ctx);
            free(ctx);
            return false;
        }

        ctx.active.store(1);
        rtCtx_ = ctx;

        ScopedCF!CFStringRef cfClient = ScopedCF!CFStringRef(createCFString(clientName));
        if (cfClient.isNull()
                || MIDIClientCreate(cfClient.get(), &midiNotifyProc, ctx, &ctx.client) != midiNoErr) {
            close();
            return false;
        }

        ScopedCF!CFStringRef cfInName = ScopedCF!CFStringRef(createCFString("Dracker Input"));
        ScopedCF!CFStringRef cfOutName = ScopedCF!CFStringRef(createCFString("Dracker Output"));
        if (MIDIInputPortCreate(ctx.client, cfInName.get(), &midiReadProc, ctx, &ctx.inputPort) != midiNoErr
                || MIDIOutputPortCreate(ctx.client, cfOutName.get(), &ctx.outputPort) != midiNoErr) {
            close();
            return false;
        }

        open_ = true;
        refreshDestinationMap();
        return true;
    }

    /**
     * Disconnects sources, disposes CoreMIDI endpoints/ports/client, and frees RT rings cleanly.
     */
    override void close() {
        if (rtCtx_ !is null) {
            rtCtx_.active.store(0);

            foreach (ref conn; connectedSources_) {
                if (rtCtx_.inputPort != 0 && conn.endpoint != 0) {
                    MIDIPortDisconnectSource(rtCtx_.inputPort, conn.endpoint);
                }
            }
            connectedSources_.length = 0;

            if (rtCtx_.virtualDest != 0) {
                MIDIEndpointDispose(rtCtx_.virtualDest);
                rtCtx_.virtualDest = 0;
            }
            if (rtCtx_.virtualSrc != 0) {
                MIDIEndpointDispose(rtCtx_.virtualSrc);
                rtCtx_.virtualSrc = 0;
            }
            if (rtCtx_.inputPort != 0) {
                MIDIPortDispose(rtCtx_.inputPort);
                rtCtx_.inputPort = 0;
            }
            if (rtCtx_.outputPort != 0) {
                MIDIPortDispose(rtCtx_.outputPort);
                rtCtx_.outputPort = 0;
            }
            if (rtCtx_.client != 0) {
                MIDIClientDispose(rtCtx_.client);
                rtCtx_.client = 0;
            }

            rtCtx_.releaseRings();
            destroy!false(*rtCtx_);
            free(rtCtx_);
            rtCtx_ = null;
        } else {
            connectedSources_.length = 0;
        }
        open_ = false;
    }

    /**
     * Reports whether the CoreMIDI client and ports are currently active.
     *
     * Returns:
     *   True when opened.
     */
    override bool isOpen() const {
        return open_ && rtCtx_ !is null;
    }

    /**
     * Enumerates available CoreMIDI source endpoints.
     *
     * Returns:
     *   Array of input MidiDeviceInfo descriptors.
     */
    override MidiDeviceInfo[] enumerateSources() {
        immutable ItemCount n = MIDIGetNumberOfSources();
        MidiDeviceInfo[] result;
        result.reserve(n);
        foreach (i; 0 .. n) {
            immutable MIDIEndpointRef ep = MIDIGetSource(i);
            if (ep == 0) {
                continue;
            }
            result ~= readEndpointInfo(ep, true, false);
        }
        return result;
    }

    /**
     * Enumerates available CoreMIDI destination endpoints and updates RT destination map.
     *
     * Returns:
     *   Array of output MidiDeviceInfo descriptors.
     */
    override MidiDeviceInfo[] enumerateDestinations() {
        refreshDestinationMap();
        immutable ItemCount n = MIDIGetNumberOfDestinations();
        MidiDeviceInfo[] result;
        result.reserve(n);
        foreach (i; 0 .. n) {
            immutable MIDIEndpointRef ep = MIDIGetDestination(i);
            if (ep == 0) {
                continue;
            }
            result ~= readEndpointInfo(ep, false, true);
        }
        return result;
    }

    /**
     * Connects a MIDI source by unique ID (or endpoint ref) to the input port.
     *
     * Params:
     *   sourceId = Source endpoint identifier returned by enumerateSources().
     *
     * Returns:
     *   True if connected (or already connected).
     */
    override bool connectSource(uint sourceId) {
        if (!isOpen() || sourceId == 0) {
            return false;
        }
        foreach (ref c; connectedSources_) {
            if (c.id == sourceId) {
                return true;
            }
        }

        immutable MIDIEndpointRef ep = findSourceById(sourceId);
        if (ep == 0) {
            return false;
        }
        immutable MIDIOSStatus st = MIDIPortConnectSource(
            rtCtx_.inputPort,
            ep,
            cast(void*) cast(size_t) sourceId
        );
        if (st != midiNoErr) {
            return false;
        }
        connectedSources_ ~= ConnectedSource(sourceId, ep);
        return true;
    }

    /**
     * Disconnects a previously connected MIDI source endpoint cleanly.
     *
     * Params:
     *   sourceId = Source endpoint identifier.
     *
     * Returns:
     *   True if found and disconnected.
     */
    override bool disconnectSource(uint sourceId) {
        if (!isOpen()) {
            return false;
        }
        foreach (idx, ref c; connectedSources_) {
            if (c.id == sourceId) {
                MIDIPortDisconnectSource(rtCtx_.inputPort, c.endpoint);
                if (idx + 1 < connectedSources_.length) {
                    connectedSources_[idx] = connectedSources_[$ - 1];
                }
                connectedSources_.length = connectedSources_.length - 1;
                return true;
            }
        }
        return false;
    }

    /**
     * Connects every currently available non-offline CoreMIDI source endpoint.
     *
     * Returns:
     *   Count of connected sources.
     */
    override size_t connectAllSources() {
        if (!isOpen()) {
            return 0;
        }
        auto sources = enumerateSources();
        foreach (ref src; sources) {
            if (!src.isOffline) {
                connectSource(src.id);
            }
        }
        return connectedSources_.length;
    }

    /**
     * Reconciles active MIDI connections and destination map after CoreMIDI hot-plug notifications.
     *
     * Returns:
     *   Active connected source count after cleanup and auto-connect.
     */
    override size_t refreshConnections() {
        if (!isOpen()) {
            return 0;
        }
        MidiNotification discarded;
        while (pollNotification(discarded)) {
        }

        auto sources = enumerateSources();
        size_t i = 0;
        while (i < connectedSources_.length) {
            bool stillPresent = false;
            foreach (ref src; sources) {
                if (src.id == connectedSources_[i].id) {
                    stillPresent = true;
                    break;
                }
            }
            if (!stillPresent) {
                MIDIPortDisconnectSource(rtCtx_.inputPort, connectedSources_[i].endpoint);
                if (i + 1 < connectedSources_.length) {
                    connectedSources_[i] = connectedSources_[$ - 1];
                }
                connectedSources_.length = connectedSources_.length - 1;
            } else {
                i++;
            }
        }

        refreshDestinationMap();
        return connectAllSources();
    }

    /**
     * Creates a CoreMIDI virtual destination receiving external application MIDI into packetRing.
     *
     * Params:
     *   name = Visible endpoint name.
     *
     * Returns:
     *   True on success.
     */
    override bool createVirtualDestination(string name) {
        if (!isOpen() || name.length == 0) {
            return false;
        }
        if (rtCtx_.virtualDest != 0) {
            MIDIEndpointDispose(rtCtx_.virtualDest);
            rtCtx_.virtualDest = 0;
        }
        ScopedCF!CFStringRef cfName = ScopedCF!CFStringRef(createCFString(name));
        MIDIEndpointRef ep = 0;
        if (MIDIDestinationCreate(rtCtx_.client, cfName.get(), &midiReadProc, rtCtx_, &ep) != midiNoErr
                || ep == 0) {
            return false;
        }
        rtCtx_.virtualDest = ep;
        refreshDestinationMap();
        return true;
    }

    /**
     * Creates a CoreMIDI virtual source broadcasting packets emitted by sendToVirtualSource().
     *
     * Params:
     *   name = Visible endpoint name.
     *
     * Returns:
     *   True on success.
     */
    override bool createVirtualSource(string name) {
        if (!isOpen() || name.length == 0) {
            return false;
        }
        if (rtCtx_.virtualSrc != 0) {
            MIDIEndpointDispose(rtCtx_.virtualSrc);
            rtCtx_.virtualSrc = 0;
        }
        ScopedCF!CFStringRef cfName = ScopedCF!CFStringRef(createCFString(name));
        MIDIEndpointRef ep = 0;
        if (MIDISourceCreate(rtCtx_.client, cfName.get(), &ep) != midiNoErr || ep == 0) {
            return false;
        }
        rtCtx_.virtualSrc = ep;
        return true;
    }

    /**
     * Transmits one 1..3-byte MIDI packet to destinationId without GC heap allocations.
     *
     * Params:
     *   destinationId = Target CoreMIDI destination unique ID.
     *   packet = Normalized MIDI packet payload.
     *
     * Returns:
     *   True if dispatched to CoreMIDI successfully.
     */
    override bool sendPacket(uint destinationId, const ref MidiPacket packet) @nogc nothrow {
        if (rtCtx_ is null || !open_ || rtCtx_.outputPort == 0 || packet.len == 0 || packet.len > 3) {
            return false;
        }
        MIDIEndpointRef ep = rtCtx_.findDestinationEndpoint(destinationId);
        if (ep == 0) {
            ep = findDestinationByIdNoGc(destinationId);
        }
        if (ep == 0) {
            return false;
        }
        MIDIPacketList list;
        populateSinglePacketList(list, packet);
        return MIDISend(rtCtx_.outputPort, ep, &list) == midiNoErr;
    }

    /**
     * Broadcasts one 1..3-byte MIDI packet via the driver's virtual source endpoint cleanly.
     *
     * Params:
     *   packet = Normalized MIDI packet payload.
     *
     * Returns:
     *   True if MIDIReceived succeeded.
     */
    override bool sendToVirtualSource(const ref MidiPacket packet) @nogc nothrow {
        if (rtCtx_ is null || !open_ || rtCtx_.virtualSrc == 0 || packet.len == 0 || packet.len > 3) {
            return false;
        }
        MIDIPacketList list;
        populateSinglePacketList(list, packet);
        return MIDIReceived(rtCtx_.virtualSrc, &list) == midiNoErr;
    }

    /**
     * Pops one normalized MidiPacket from the lock-free MPSC queue on the RT consumer thread.
     *
     * Params:
     *   outPacket = Receives the oldest queued packet on success.
     *
     * Returns:
     *   True if a packet was available; false when empty.
     */
    override bool pollPacket(out MidiPacket outPacket) @nogc nothrow {
        if (rtCtx_ is null) {
            return false;
        }
        return rtCtx_.packetRing.tryPop(outPacket);
    }

    /**
     * Pops one CoreMIDI hot-plug notification emitted by midiNotifyProc.
     *
     * Params:
     *   outNotif = Receives the oldest queued notification on success.
     *
     * Returns:
     *   True if a notification was available; false when empty.
     */
    override bool pollNotification(out MidiNotification outNotif) @nogc nothrow {
        if (rtCtx_ is null) {
            return false;
        }
        return rtCtx_.notifRing.tryPop(outNotif);
    }

    /**
     * Returns total normalized MIDI packets accepted into the MPSC ring.
     *
     * Returns:
     *   Received packet counter.
     */
    ulong packetsReceived() const @nogc nothrow {
        return rtCtx_ !is null ? rtCtx_.packetsReceived.load() : 0;
    }

    /**
     * Returns total packets dropped due to MPSC ring saturation.
     *
     * Returns:
     *   Dropped packet counter.
     */
    ulong packetsDropped() const @nogc nothrow {
        return rtCtx_ !is null ? rtCtx_.packetsDropped.load() : 0;
    }

    /**
     * Returns total CoreMIDI setup/topology notifications observed.
     *
     * Returns:
     *   Notification counter.
     */
    ulong notificationsReceived() const @nogc nothrow {
        return rtCtx_ !is null ? rtCtx_.notificationsReceived.load() : 0;
    }

    /**
     * Returns the unmanaged RT context pointer for direct callback/RT-trap verification.
     *
     * Returns:
     *   Active CoreMidiRtContext*, or null when closed.
     */
    CoreMidiRtContext* rtContext() @nogc nothrow {
        return rtCtx_;
    }

    /**
     * Returns the unique endpoint ID assigned to the created virtual destination, or 0.
     *
     * Returns:
     *   Virtual destination ID if created; 0 otherwise.
     */
    uint virtualDestinationId() const @nogc nothrow {
        if (rtCtx_ is null || rtCtx_.virtualDest == 0) {
            return 0;
        }
        return endpointUniqueIdNoGc(rtCtx_.virtualDest);
    }

    /**
     * Returns the unique endpoint ID assigned to the created virtual source, or 0.
     *
     * Returns:
     *   Virtual source ID if created; 0 otherwise.
     */
    uint virtualSourceId() const @nogc nothrow {
        if (rtCtx_ is null || rtCtx_.virtualSrc == 0) {
            return 0;
        }
        return endpointUniqueIdNoGc(rtCtx_.virtualSrc);
    }

    private void refreshDestinationMap() @nogc nothrow {
        if (rtCtx_ is null) {
            return;
        }
        immutable ItemCount n = MIDIGetNumberOfDestinations();
        size_t count = 0;
        foreach (i; 0 .. n) {
            if (count >= MAX_MIDI_DEST_MAP) {
                break;
            }
            immutable MIDIEndpointRef ep = MIDIGetDestination(i);
            if (ep != 0) {
                rtCtx_.destinations[count++] = MidiDestinationSlot(endpointUniqueIdNoGc(ep), ep);
            }
        }
        rtCtx_.destinationCount.store(count);
    }

    private static void populateSinglePacketList(ref MIDIPacketList list, const ref MidiPacket packet) @nogc nothrow {
        list.numPackets = 1;
        MIDIPacket* pkt = &list.packet[0];
        pkt.timeStamp = packet.timestamp;
        pkt.length = packet.len;
        foreach (i; 0 .. 3) {
            pkt.data[i] = i < packet.len ? packet.data[i] : 0;
        }
    }

    private static uint endpointUniqueIdNoGc(MIDIEndpointRef ep) @nogc nothrow {
        int uid = 0;
        if (MIDIObjectGetIntegerProperty(ep, kMIDIPropertyUniqueID, &uid) == midiNoErr && uid != 0) {
            return cast(uint) uid;
        }
        return ep;
    }

    private static MIDIEndpointRef findSourceById(uint targetId) @nogc nothrow {
        immutable ItemCount n = MIDIGetNumberOfSources();
        foreach (i; 0 .. n) {
            immutable MIDIEndpointRef ep = MIDIGetSource(i);
            if (ep != 0 && endpointUniqueIdNoGc(ep) == targetId) {
                return ep;
            }
        }
        return 0;
    }

    private static MIDIEndpointRef findDestinationByIdNoGc(uint targetId) @nogc nothrow {
        immutable ItemCount n = MIDIGetNumberOfDestinations();
        foreach (i; 0 .. n) {
            immutable MIDIEndpointRef ep = MIDIGetDestination(i);
            if (ep != 0 && endpointUniqueIdNoGc(ep) == targetId) {
                return ep;
            }
        }
        return 0;
    }

    private static MidiDeviceInfo readEndpointInfo(MIDIEndpointRef ep, bool isInput, bool isOutput) {
        MidiDeviceInfo info;
        info.id = endpointUniqueIdNoGc(ep);
        info.name = readEndpointString(ep, kMIDIPropertyName);
        info.displayName = readEndpointString(ep, kMIDIPropertyDisplayName);
        if (info.displayName.length == 0) {
            info.displayName = info.name;
        }
        info.isInput = isInput;
        info.isOutput = isOutput;
        int offlineVal = 0;
        if (MIDIObjectGetIntegerProperty(ep, kMIDIPropertyOffline, &offlineVal) == midiNoErr) {
            info.isOffline = (offlineVal != 0);
        }
        return info;
    }

    private static string readEndpointString(MIDIEndpointRef ep, CFStringRef prop) {
        CFStringRef raw = null;
        if (MIDIObjectGetStringProperty(ep, prop, &raw) != midiNoErr || raw is null) {
            return "";
        }
        ScopedCF!CFStringRef scoped = ScopedCF!CFStringRef(raw);
        return cfStringToDString(scoped.get());
    }
}
