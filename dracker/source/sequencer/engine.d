/**
 * File:         source/sequencer/engine.d
 * Module:       sequencer.engine
 * Phase:        Phase 5.4 — Unified Instance-Scoped Engine & Stem Exporter
 *
 * Purpose:
 *   Combines Sequencer, AudioGraph, SPSC command/retire queues, live keyboard/MIDI voice allocation, and offline WAV / per-module stem rendering inside a re-entrant instance-scoped struct.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on RT playback and command dispatch; zero global mutable state so MetaModule child Engines nest safely. Off-RT WAV/stem helpers reside prior to the @nogc attribute block.
 *
 * Dependencies:
 *   Internal: foundation.*, graph.*, io.audio_io, sequencer.{clock,count_in,note,pattern,timeline,track_effects}
 *   External: core.lifetime (move), std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum EngineCmdKind / struct EngineCommand / struct EngineTelemetry / struct StemExportSpec / struct MidiMapEntry
 *     / struct MidiMapSnapshot / struct ScopeBlock
 *   - struct Engine : tryInit(), reset(), pushCommand(), drainRetireRing(), tryPopRetired(), applyPendingCommandsOffRT(), appliedFence(), liveNoteOnRt(), liveNoteOffRt(),
 *     enqueueLiveEventRt(), applyMidiCcRt(), setWatchedNoteModule(), watchedNoteModule(), tryPopScopeBlock(), scopeBlocksDropped(), processHostBuffer(), processDirectSubFrames(), renderOfflineToBuffer(), exportOfflineWav(), exportStemsWav()
 *   - EngineCommand.makePlayCountIn() / EngineCmdKind.playCountIn: live-record count-in (pre-roll from a possibly
 *     negative line plus a CountInClick metronome added to the master output); isCountingIn(), countInClicks(),
 *     EngineTelemetry.countingIn
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.engine;

import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import core.lifetime : emplace, move;
import core.stdc.stdlib : calloc, free;
import std.math : fabs, isFinite;

import foundation.concurrency : hasGcReference, SpscRing, TripleBuffer;
import foundation.memory : OwnedBuffer;
import foundation.types : FIXED_BLOCK_FRAMES, FrameTime, ModuleId, NoteId;
import graph.audio_graph : AudioGraph, GraphTelemetry, RetiredKind, RetiredResource, RetireSink;
import graph.context : TransportState;
import graph.event : ModEvent;
import graph.plan : GraphPlan;
import io.audio_io : writeWavFile;
import sequencer.clock : RationalClock, TickEvent;
import sequencer.count_in : CountInClick;
import sequencer.note : NoteCell;
import sequencer.pattern : patchCellAtomic, PatternSnapshot;
import sequencer.timeline : TimelineClip, TimelineSnapshot;
import sequencer.track_effects : SequencerActionFlags, TrackEffectBank, TrackKeyKind;

/**
 * UI-to-RT asynchronous command variants queued via lock-free SpscRing!EngineCommand.
 */
enum EngineCmdKind : ubyte {
    play = 0,
    stop = 1,
    seekLine = 2,
    setBpm = 3,
    setTicksPerLine = 4,
    setLoop = 5,
    swapGraphPlan = 6,
    swapModuleAsset = 7,
    setModuleParam = 8,
    setModuleParamNorm = 9,
    setModuleMute = 10,
    setModuleBypass = 11,
    swapPattern = 12,
    patchCell = 13,
    swapTimeline = 14,
    liveNoteOn = 15,
    liveNoteOff = 16,
    allNotesOff = 17,
    sendModEvent = 18,
    fence = 19,
    swapMidiMap = 20,
    setScopeTaps = 21,
    playCountIn = 22
}

/**
 * One MIDI-learn binding: a controller (channel, CC number) driving a module parameter over [min01, max01].
 */
struct MidiMapEntry {
    ubyte channel = 0;
    ubyte cc = 0;
    ModuleId moduleId = ModuleId.invalid;
    uint paramIdx = 0;
    float min01 = 0.0f;
    float max01 = 1.0f;
}

/**
 * Immutable-after-build unmanaged MIDI map swapped into the Engine with EngineCmdKind.swapMidiMap.
 */
struct MidiMapSnapshot {
    enum size_t MAX_ENTRIES = 256;

    OwnedBuffer!MidiMapEntry entries;
    size_t count = 0;

    @disable this(this);

    /**
     * Builds a snapshot off-RT.
     *
     * Params:
     *   src = Bindings (at most MAX_ENTRIES are kept).
     *
     * Returns:
     *   Unmanaged snapshot, or null on OOM.
     */
    static MidiMapSnapshot* createOffRT(const(MidiMapEntry)[] src) @nogc nothrow {
        auto snap = cast(MidiMapSnapshot*) calloc(1, MidiMapSnapshot.sizeof);
        if (snap is null) {
            return null;
        }
        emplace(snap);
        immutable size_t n = src.length < MAX_ENTRIES ? src.length : MAX_ENTRIES;
        if (n > 0) {
            if (!OwnedBuffer!MidiMapEntry.tryAllocate(n, snap.entries)) {
                destroyOffRT(snap);
                return null;
            }
            snap.entries.opSlice()[0 .. n] = src[0 .. n];
        }
        snap.count = n;
        return snap;
    }

    /**
     * Frees a snapshot off-RT.
     *
     * Params:
     *   snap = Snapshot (null-safe).
     */
    static void destroyOffRT(MidiMapSnapshot* snap) @nogc nothrow {
        if (snap is null) {
            return;
        }
        destroy(*snap);
        free(snap);
    }

    /**
     * Type-erased destructor for RetireRing.
     *
     * Params:
     *   p = MidiMapSnapshot pointer.
     */
    static void destroyErased(void* p) @nogc nothrow {
        destroyOffRT(cast(MidiMapSnapshot*) p);
    }

    /**
     * Returns the bindings.
     *
     * Returns:
     *   Entry slice.
     */
    const(MidiMapEntry)[] view() const @nogc nothrow {
        return count == 0 ? null : entries.opSlice()[0 .. count];
    }
}

/**
 * One 64-frame stereo block of a tapped signal (master = source id 0) published RT -> UI for scopes/spectra.
 */
struct ScopeBlock {
    uint sourceId = 0;
    ulong frame = 0;
    float[FIXED_BLOCK_FRAMES] left = 0.0f;
    float[FIXED_BLOCK_FRAMES] right = 0.0f;
}

/**
 * Plain-old-data message dispatched lock-free from UI/MIDI threads to the RT Engine.
 */
struct EngineCommand {
    EngineCmdKind kind = EngineCmdKind.play;
    ModuleId targetMod = ModuleId.invalid;
    uint paramIdx = 0;
    uint slot = 0;
    uint track = 0;
    uint line = 0;
    uint tag = 0;
    long lineVal = 0;
    long lineVal2 = 0;
    float floatVal = 0.0f;
    float floatVal2 = 0.0f;
    double doubleVal = 125.0;
    bool boolVal = false;
    NoteCell cell;
    ModEvent modEvent;
    GraphPlan* graphPlan = null;
    MidiMapSnapshot* midiMap = null;
    PatternSnapshot* patternSnap = null;
    TimelineSnapshot* timelineSnap = null;
    void* assetPtr = null;
    void function(void*) @nogc nothrow assetDestroyFn = null;

    @nogc nothrow pure @safe:

    /**
     * Builds a command starting song playback cleanly.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makePlay() {
        EngineCommand c;
        c.kind = EngineCmdKind.play;
        return c;
    }

    /**
     * Builds a command stopping playback and releasing active sequencer voices.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeStop() {
        EngineCommand c;
        c.kind = EngineCmdKind.stop;
        return c;
    }

    /**
     * Builds a command seeking playhead cleanly to targetLine.
     *
     * Params:
     *   targetLine = Destination zero-based song line.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSeekLine(long targetLine) {
        EngineCommand c;
        c.kind = EngineCmdKind.seekLine;
        c.lineVal = targetLine;
        return c;
    }

    /**
     * Builds a command that starts playback countInLines before startLine with a metronome click on every beat
     * of the count-in (the song pre-rolls where those lines exist; lines before 0 are silent apart from clicks).
     *
     * Params:
     *   startLine = Line where the count-in ends (recording starts).
     *   countInLines = Count-in length in lines.
     *   beatLines = Lines per click.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makePlayCountIn(long startLine, uint countInLines, uint beatLines) {
        EngineCommand c;
        c.kind = EngineCmdKind.playCountIn;
        c.lineVal = startLine;
        c.lineVal2 = countInLines;
        c.paramIdx = beatLines;
        return c;
    }

    /**
     * Builds a command updating tempo in beats per minute.
     *
     * Params:
     *   bpm = Target BPM clamped [20..999].
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSetBpm(double bpm) {
        EngineCommand c;
        c.kind = EngineCmdKind.setBpm;
        c.doubleVal = bpm;
        return c;
    }

    /**
     * Builds a command updating tracker ticks per line.
     *
     * Params:
     *   tpl = Ticks per row clamped [1..255].
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSetTpl(uint tpl) {
        EngineCommand c;
        c.kind = EngineCmdKind.setTicksPerLine;
        c.paramIdx = tpl;
        return c;
    }

    /**
     * Builds a command configuring timeline loop bounds [loopStart .. loopEnd).
     *
     * Params:
     *   loopStart = Inclusive wrap target line.
     *   loopEnd = Exclusive loop end line (<= loopStart disables loop).
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSetLoop(long loopStart, long loopEnd) {
        EngineCommand c;
        c.kind = EngineCmdKind.setLoop;
        c.lineVal = loopStart;
        c.lineVal2 = loopEnd;
        return c;
    }

    /**
     * Builds an atomic GraphPlan replacement command (displacing prior plan onto RetireRing).
     *
     * Params:
     *   plan = Off-RT compiled GraphPlan*.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSwapGraphPlan(GraphPlan* plan) {
        EngineCommand c;
        c.kind = EngineCmdKind.swapGraphPlan;
        c.graphPlan = plan;
        return c;
    }

    /**
     * Builds a lock-free SwapModuleAsset command targeting modId slot.
     *
     * Params:
     *   modId = Destination module identifier.
     *   slot = Module asset slot index.
     *   assetPtr = Pre-allocated unmanaged asset pointer.
     *   destroyFn = Off-RT destructor invoked on displaced old asset.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSwapModuleAsset(
        ModuleId modId,
        uint slot,
        void* assetPtr,
        void function(void*) @nogc nothrow destroyFn
    ) {
        EngineCommand c;
        c.kind = EngineCmdKind.swapModuleAsset;
        c.targetMod = modId;
        c.slot = slot;
        c.assetPtr = assetPtr;
        c.assetDestroyFn = destroyFn;
        return c;
    }

    /**
     * Builds a module parameter update command in domain units.
     *
     * Params:
     *   modId = Destination ModuleId.
     *   paramIdx = Zero-based parameter index.
     *   val = Target domain value.
     *   instant = True to snap smoothers immediately.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSetModuleParam(ModuleId modId, uint paramIdx, float val, bool instant = false) {
        EngineCommand c;
        c.kind = EngineCmdKind.setModuleParam;
        c.targetMod = modId;
        c.paramIdx = paramIdx;
        c.floatVal = val;
        c.boolVal = instant;
        return c;
    }

    /**
     * Builds a normalized [0.0f, 1.0f] module parameter update command.
     *
     * Params:
     *   modId = Destination ModuleId.
     *   paramIdx = Zero-based parameter index.
     *   norm01 = Normalized parameter position in [0.0f, 1.0f].
     *   instant = True to snap smoothers immediately.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSetModuleParamNorm(ModuleId modId, uint paramIdx, float norm01, bool instant = false) {
        EngineCommand c;
        c.kind = EngineCmdKind.setModuleParamNorm;
        c.targetMod = modId;
        c.paramIdx = paramIdx;
        c.floatVal = norm01;
        c.boolVal = instant;
        return c;
    }

    /**
     * Builds a node mute toggle command.
     *
     * Params:
     *   modId = Target ModuleId.
     *   muted = True to mute node output.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSetModuleMute(ModuleId modId, bool muted) {
        EngineCommand c;
        c.kind = EngineCmdKind.setModuleMute;
        c.targetMod = modId;
        c.boolVal = muted;
        return c;
    }

    /**
     * Builds a node bypass toggle command.
     *
     * Params:
     *   modId = Target ModuleId.
     *   bypassed = True to bypass node processing.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSetModuleBypass(ModuleId modId, bool bypassed) {
        EngineCommand c;
        c.kind = EngineCmdKind.setModuleBypass;
        c.targetMod = modId;
        c.boolVal = bypassed;
        return c;
    }

    /**
     * Builds a Copy-on-Write pattern snapshot replacement command.
     *
     * Params:
     *   patternId = Logical pattern identifier.
     *   snap = Off-RT allocated PatternSnapshot* replacing any previous snapshot for patternId.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSwapPattern(uint patternId, PatternSnapshot* snap) {
        EngineCommand c;
        c.kind = EngineCmdKind.swapPattern;
        c.slot = patternId;
        c.patternSnap = snap;
        return c;
    }

    /**
     * Builds an atomic live pattern cell edit command.
     *
     * Params:
     *   patternId = Target pattern identifier.
     *   track = Zero-based track index.
     *   line = Zero-based row index.
     *   cell = Replacement 8-byte NoteCell.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makePatchCell(uint patternId, uint track, uint line, NoteCell cell) {
        EngineCommand c;
        c.kind = EngineCmdKind.patchCell;
        c.slot = patternId;
        c.track = track;
        c.line = line;
        c.cell = cell;
        return c;
    }

    /**
     * Builds a Copy-on-Write TimelineSnapshot replacement command.
     *
     * Params:
     *   snap = Off-RT allocated TimelineSnapshot*.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSwapTimeline(TimelineSnapshot* snap) {
        EngineCommand c;
        c.kind = EngineCmdKind.swapTimeline;
        c.timelineSnap = snap;
        return c;
    }

    /**
     * Builds a live QWERTY/MIDI key-down voice trigger command.
     *
     * Params:
     *   modId = Target synth ModuleId.
     *   keyTag = Caller key/MIDI identifier matched on makeLiveNoteOff().
     *   midiNote = Fractional MIDI note pitch.
     *   velocity = Normalized note velocity [0..1].
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeLiveNoteOn(ModuleId modId, uint keyTag, float midiNote, float velocity = 0.85f) {
        EngineCommand c;
        c.kind = EngineCmdKind.liveNoteOn;
        c.targetMod = modId;
        c.tag = keyTag;
        c.floatVal = midiNote;
        c.floatVal2 = velocity;
        return c;
    }

    /**
     * Builds a live QWERTY/MIDI key-up voice release command matching keyTag.
     *
     * Params:
     *   modId = Target synth ModuleId.
     *   keyTag = Key/MIDI identifier originally passed to makeLiveNoteOn().
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeLiveNoteOff(ModuleId modId, uint keyTag) {
        EngineCommand c;
        c.kind = EngineCmdKind.liveNoteOff;
        c.targetMod = modId;
        c.tag = keyTag;
        return c;
    }

    /**
     * Builds an all-notes-off panic release command across live and sequencer voices.
     *
     * Params:
     *   modId = Optional module target (invalid broadcasts to live voices and active tracks).
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeAllNotesOff(ModuleId modId = ModuleId.invalid) {
        EngineCommand c;
        c.kind = EngineCmdKind.allNotesOff;
        c.targetMod = modId;
        return c;
    }

    /**
     * Builds a direct ModEvent delivery command targeting modId.
     *
     * Params:
     *   modId = Destination module identifier.
     *   ev = Event payload.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSendModEvent(ModuleId modId, ModEvent ev) {
        EngineCommand c;
        c.kind = EngineCmdKind.sendModEvent;
        c.targetMod = modId;
        c.modEvent = ev;
        return c;
    }

    /**
     * Builds a MIDI map swap command (the displaced map is retired).
     *
     * Params:
     *   snap = New map (ownership transfers to the Engine); null clears the map.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSwapMidiMap(MidiMapSnapshot* snap) {
        EngineCommand c;
        c.kind = EngineCmdKind.swapMidiMap;
        c.midiMap = snap;
        return c;
    }

    /**
     * Enables scope publishing for master plus up to four tapped modules (invalid ids leave a slot unused).
     *
     * Params:
     *   enabled = False stops all scope publishing.
     *   taps = Module ids to tap.
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeSetScopeTaps(bool enabled, ModuleId[4] taps) {
        EngineCommand c;
        c.kind = EngineCmdKind.setScopeTaps;
        c.boolVal = enabled;
        c.tag = taps[0].value;
        c.slot = taps[1].value;
        c.track = taps[2].value;
        c.line = taps[3].value;
        return c;
    }

    /**
     * Builds an ordering fence acknowledged by the RT thread once every earlier queued command has been applied.
     *
     * Params:
     *   sequence = Monotonic non-zero fence token published through Engine.appliedFence().
     *
     * Returns:
     *   Populated EngineCommand.
     */
    static EngineCommand makeFence(ulong sequence) {
        EngineCommand c;
        c.kind = EngineCmdKind.fence;
        c.lineVal = cast(long) sequence;
        return c;
    }
}

static assert(!hasGcReference!EngineCommand,
    "EngineCommand must contain zero D GC references");

/**
 * Lock-free Engine telemetry snapshot published per 64-frame quantum over TripleBuffer.
 */
struct EngineTelemetry {
    GraphTelemetry graph;
    long currentLine = 0;
    uint currentTick = 0;
    double bpm = 125.0;
    uint ticksPerLine = 6;
    bool playing = false;
    bool countingIn = false;
    ulong totalFrames = 0;
    uint patternNoteModuleId = 0;
    ulong[2] patternNoteMask = 0;

    /**
     * Reports whether a pattern voice targeting moduleId is currently sounding midi.
     *
     * Params:
     *   moduleId = Module identifier to test.
     *   midi = MIDI note number 0..127.
     *
     * Returns:
     *   True if active during playback.
     */
    bool isPatternNoteActive(uint moduleId, ubyte midi) const @nogc nothrow pure @safe {
        return playing && moduleId != 0 && patternNoteModuleId == moduleId && midi < 128
            && ((patternNoteMask[midi >> 6] & (1uL << (midi & 63))) != 0);
    }
}

/**
 * Specification pairing a graph ModuleId with a destination WAV output path for stem export.
 */
struct StemExportSpec {
    ModuleId moduleId = ModuleId.invalid;
    string wavPath;
}

private struct PatternSlotEntry {
    bool occupied = false;
    uint patternId = 0;
    PatternSnapshot* snap = null;
}

private struct LiveVoiceSlot {
    bool active = false;
    ModuleId modId = ModuleId.invalid;
    uint keyTag = 0;
    NoteId noteId = NoteId.none;
}

/**
 * Re-entrant instance-scoped modular synth tracker engine integrating Sequencer and AudioGraph.
 *
 * Owns zero global mutable state so nested MetaModules instantiate independent child Engines.
 */
struct Engine {
    enum size_t MAX_PATTERNS = 256;
    enum size_t MAX_LINE_CLIPS = 32;
    enum size_t MAX_LIVE_VOICES = 64;
    enum size_t SCOPE_RING_BLOCKS = 512;
    enum uint MIDI_KEY_TAG_BASE = 0x0100_0000u;
    enum uint PIANO_KEY_TAG_BASE = 0x0200_0000u;

    private AudioGraph graph_;
    private RationalClock clock_;
    private CountInClick countIn_;
    private TrackEffectBank trackFx_;
    private SpscRing!EngineCommand cmdRing_;
    private SpscRing!RetiredResource retireRing_;
    private TripleBuffer!EngineTelemetry telemetry_;

    private PatternSlotEntry[MAX_PATTERNS] patterns_;
    private TimelineSnapshot* timeline_ = null;
    private LiveVoiceSlot[MAX_LIVE_VOICES] liveVoices_;
    private uint nextLiveNoteSeq_ = 1;

    private OwnedBuffer!float hostInRingL_;
    private OwnedBuffer!float hostInRingR_;
    private size_t hostInRead_ = 0;
    private size_t hostInWrite_ = 0;
    private size_t hostInCount_ = 0;
    private float[FIXED_BLOCK_FRAMES][2] stageIn_ = 0.0f;
    private float[FIXED_BLOCK_FRAMES][2] stageOut_ = 0.0f;
    private uint stageOutRead_ = FIXED_BLOCK_FRAMES;
    private uint stageOutAvail_ = 0;

    private TransportState transport_;
    private bool playing_ = false;
    private long pendingJumpLine_ = -1;
    private float sampleRate_ = 44_100.0f;
    private bool initialized_ = false;
    private shared ulong appliedFence_ = 0;
    private MidiMapSnapshot* midiMap_ = null;
    private SpscRing!ScopeBlock scopeRing_;
    private ModuleId[4] scopeTaps_;
    private bool scopeEnabled_ = false;
    private shared ulong scopeDropped_ = 0;
    private ScopeBlock scopeScratch_;
    private shared uint watchNoteModule_ = 0;

    @disable this(this);

    /**
     * Renders totalFrames offline in hostBlockFrames increments into newly allocated stereo buffers.
     *
     * Params:
     *   totalFrames = Total stereo frames to render.
     *   hostBlockFrames = Host block quantum size used to test buffer-size invariance (>= 1).
     *   outL = Destination left OwnedBuffer!float.
     *   outR = Destination right OwnedBuffer!float.
     *
     * Returns:
     *   True on success; false if uninitialized, totalFrames == 0, or OOM.
     */
    bool renderOfflineToBuffer(
        size_t totalFrames,
        size_t hostBlockFrames,
        out OwnedBuffer!float outL,
        out OwnedBuffer!float outR
    ) {
        outL = OwnedBuffer!float.init;
        outR = OwnedBuffer!float.init;
        if (!initialized_ || totalFrames == 0 || hostBlockFrames == 0) {
            return false;
        }
        if (!OwnedBuffer!float.tryAllocate(totalFrames, outL)
                || !OwnedBuffer!float.tryAllocate(totalFrames, outR)) {
            outL.reset();
            outR.reset();
            return false;
        }

        const(float[])[2] emptyIn = [null, null];
        size_t pos = 0;
        while (pos < totalFrames) {
            immutable size_t rem = totalFrames - pos;
            immutable uint chunk = cast(uint)(rem < hostBlockFrames ? rem : hostBlockFrames);
            float[][2] outs = [outL[pos .. pos + chunk], outR[pos .. pos + chunk]];
            processHostBuffer(outs, emptyIn, chunk);
            pos += chunk;
        }
        return true;
    }

    /**
     * Renders totalFrames offline and writes an IEEE Float32 stereo WAV file to wavPath.
     *
     * Params:
     *   wavPath = Output WAV filesystem path.
     *   totalFrames = Total stereo frames to render.
     *   hostBlockFrames = Chunk size passed to processHostBuffer().
     *   err = Error message populated on failure.
     *
     * Returns:
     *   True if render and WAV encoding succeeded.
     */
    bool exportOfflineWav(string wavPath, size_t totalFrames, size_t hostBlockFrames, out string err) {
        err = null;
        if (wavPath.length == 0) {
            err = "Output WAV path cannot be empty";
            return false;
        }
        OwnedBuffer!float bufL;
        OwnedBuffer!float bufR;
        if (!renderOfflineToBuffer(totalFrames, hostBlockFrames, bufL, bufR)) {
            err = "Offline engine render failed";
            return false;
        }
        const(float)[][2] chans = [bufL[], bufR[]];
        immutable uint sr = cast(uint)(sampleRate_ + 0.5f);
        return writeWavFile(wavPath, chans[], sr > 0 ? sr : 44_100u, err);
    }

    /**
     * Renders totalFrames in a single deterministic pass and exports full mix plus per-module stems as WAV files.
     *
     * Params:
     *   stems = Module IDs and destination WAV paths for isolated bus capture.
     *   mixWavPath = Optional full mix WAV output path (skipped when null/empty).
     *   totalFrames = Total stereo frames to render.
     *   err = Error message populated if any render or WAV write fails.
     *
     * Returns:
     *   True if every requested stem (and mix if non-empty) exported cleanly.
     */
    bool exportStemsWav(
        const(StemExportSpec)[] stems,
        string mixWavPath,
        size_t totalFrames,
        out string err
    ) {
        err = null;
        if (!initialized_ || totalFrames == 0) {
            err = "Engine must be initialized with totalFrames > 0 for stem export";
            return false;
        }

        float[] mixL = new float[totalFrames];
        float[] mixR = new float[totalFrames];
        float[][] stemL = new float[][](stems.length, totalFrames);
        float[][] stemR = new float[][](stems.length, totalFrames);

        float[FIXED_BLOCK_FRAMES] qOutL = 0.0f;
        float[FIXED_BLOCK_FRAMES] qOutR = 0.0f;
        float[FIXED_BLOCK_FRAMES] sBufL = 0.0f;
        float[FIXED_BLOCK_FRAMES] sBufR = 0.0f;
        const(float[])[2] emptyIn = [null, null];

        size_t pos = 0;
        while (pos < totalFrames) {
            float[][2] qOut = [qOutL[], qOutR[]];
            renderSingleQuantum(qOut, emptyIn, FIXED_BLOCK_FRAMES);

            immutable size_t rem = totalFrames - pos;
            immutable size_t cp = rem < FIXED_BLOCK_FRAMES ? rem : FIXED_BLOCK_FRAMES;
            mixL[pos .. pos + cp] = qOutL[0 .. cp];
            mixR[pos .. pos + cp] = qOutR[0 .. cp];

            foreach (si, ref spec; stems) {
                if (graph_.copyLastNodeAudioBus(spec.moduleId, sBufL[], sBufR[])) {
                    stemL[si][pos .. pos + cp] = sBufL[0 .. cp];
                    stemR[si][pos .. pos + cp] = sBufR[0 .. cp];
                } else {
                    stemL[si][pos .. pos + cp] = 0.0f;
                    stemR[si][pos .. pos + cp] = 0.0f;
                }
            }
            pos += cp;
        }

        immutable uint sr = cast(uint)(sampleRate_ + 0.5f) > 0 ? cast(uint)(sampleRate_ + 0.5f) : 44_100u;
        if (mixWavPath.length > 0) {
            const(float)[][2] mixCh = [mixL, mixR];
            if (!writeWavFile(mixWavPath, mixCh[], sr, err)) {
                return false;
            }
        }
        foreach (si, ref spec; stems) {
            if (spec.wavPath.length == 0) {
                continue;
            }
            const(float)[][2] stCh = [stemL[si], stemR[si]];
            if (!writeWavFile(spec.wavPath, stCh[], sr, err)) {
                return false;
            }
        }
        return true;
    }

    @nogc nothrow:

    /**
     * Releases owned GraphPlan, TimelineSnapshot, all PatternSnapshots, and retired resources off-RT.
     */
    ~this() {
        releaseAllOwnedResources();
    }

    /**
     * Frees all unmanaged RT buffers, plans, patterns, and timelines owned by this Engine off-RT.
     */
    void releaseAllOwnedResources() {
        GraphPlan* gp = graph_.detachPlan();
        if (gp !is null) {
            GraphPlan.destroyOffRT(gp);
        }
        if (timeline_ !is null) {
            TimelineSnapshot.destroyOffRT(timeline_);
            timeline_ = null;
        }
        foreach (ref p; patterns_) {
            if (p.occupied && p.snap !is null) {
                PatternSnapshot.destroyOffRT(p.snap);
            }
            p = PatternSlotEntry.init;
        }
        if (midiMap_ !is null) {
            MidiMapSnapshot.destroyOffRT(midiMap_);
            midiMap_ = null;
        }
        drainRetireRing();
        scopeRing_.reset();
        scopeEnabled_ = false;
        scopeTaps_ = ModuleId.init;
        hostInRingL_.reset();
        hostInRingR_.reset();
        cmdRing_.reset();
        retireRing_.reset();
        initialized_ = false;
    }

    /**
     * Initializes AudioGraph, RationalClock, SPSC command/retire rings, and staging buffers off-RT.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz (> 0.0f).
     *   cmdCap = Power-of-two capacity for lock-free UI->RT commands.
     *   retireCap = Power-of-two capacity for RT->UI retire cleanup queue.
     *
     * Returns:
     *   True on success; false on invalid arguments or OOM.
     */
    bool tryInit(float sampleRate, size_t cmdCap = 1024, size_t retireCap = 1024) {
        releaseAllOwnedResources();
        if (!isFinite(sampleRate) || sampleRate < 1.0f) {
            return false;
        }
        if (!graph_.tryInit(sampleRate, 2048)) {
            return false;
        }
        if (!SpscRing!EngineCommand.tryCreate(cmdCap, cmdRing_)) {
            return false;
        }
        if (!SpscRing!RetiredResource.tryCreate(retireCap, retireRing_)) {
            return false;
        }
        if (!SpscRing!ScopeBlock.tryCreate(SCOPE_RING_BLOCKS, scopeRing_)) {
            return false;
        }
        if (!OwnedBuffer!float.tryAllocate(8192, hostInRingL_)
                || !OwnedBuffer!float.tryAllocate(8192, hostInRingR_)) {
            return false;
        }
        sampleRate_ = sampleRate;
        initialized_ = true;
        reset();
        return true;
    }

    /**
     * Resets graph state, sequencer clock, active tracks, live voices, and host staging buffers cleanly.
     */
    void reset() {
        graph_.reset();
        clock_.configure(sampleRate_, 125.0, 6);
        countIn_.prepare(sampleRate_);
        trackFx_.reset();
        foreach (ref lv; liveVoices_) {
            lv = LiveVoiceSlot.init;
        }
        nextLiveNoteSeq_ = 1;
        if (!hostInRingL_.empty()) hostInRingL_.opSlice()[] = 0.0f;
        if (!hostInRingR_.empty()) hostInRingR_.opSlice()[] = 0.0f;
        hostInRead_ = 0;
        hostInWrite_ = 0;
        hostInCount_ = 0;
        stageIn_[0][] = 0.0f;
        stageIn_[1][] = 0.0f;
        stageOut_[0][] = 0.0f;
        stageOut_[1][] = 0.0f;
        stageOutRead_ = FIXED_BLOCK_FRAMES;
        stageOutAvail_ = 0;
        transport_ = TransportState.init;
        transport_.bpm = 125.0;
        transport_.ticksPerLine = 6;
        transport_.playing = false;
        playing_ = false;
        pendingJumpLine_ = -1;
        publishTelemetry();
    }

    /**
     * Pushes an EngineCommand lock-free from UI/MIDI threads to the audio engine.
     *
     * Params:
     *   cmd = POD EngineCommand payload.
     *
     * Returns:
     *   True if pushed; false if the command ring is full or uninitialized.
     */
    bool pushCommand(EngineCommand cmd) {
        if (!initialized_) {
            return false;
        }
        return cmdRing_.tryPush(cmd);
    }

    /**
     * Reclaims displaced plans, patterns, timelines, and module assets on a non-RT thread.
     *
     * Returns:
     *   Number of retired items destroyed cleanly off-RT.
     */
    size_t drainRetireRing() {
        size_t freedCount = 0;
        RetiredResource item;
        while (retireRing_.tryPop(item)) {
            item.reclaimOffRT();
            freedCount++;
        }
        return freedCount;
    }

    /**
     * Reads the latest lock-free EngineTelemetry snapshot for GUI meters and playhead display.
     *
     * Params:
     *   outTel = Destination telemetry struct.
     *
     * Returns:
     *   True when a newer snapshot was consumed.
     */
    bool readTelemetry(out EngineTelemetry outTel) {
        return telemetry_.read(outTel);
    }

    /**
     * Sets the MetaModule nesting depth forwarded into child AudioGraph ProcessContexts.
     *
     * Params:
     *   depth = Zero-based recursion nesting depth.
     */
    void setMetaDepth(uint depth) pure @safe {
        graph_.setMetaDepth(depth);
    }

    /**
     * Synchronizes child clock/transport BPM, TPL, and optional play state from a parent Engine.
     *
     * Params:
     *   parentBpm = Parent active BPM.
     *   parentTpl = Parent active ticks per line.
     *   syncTempo = True to lock BPM and TPL to parent transport.
     *   startStopFollow = Optional play state synchronized when desired.
     */
    void syncTransportFromParent(double parentBpm, uint parentTpl, bool syncTempo, bool startStopFollow) {
        if (syncTempo) {
            clock_.setBpm(parentBpm);
            clock_.setTicksPerLine(parentTpl);
            transport_.bpm = clock_.bpm();
            transport_.ticksPerLine = clock_.ticksPerLine();
        }
        if (startStopFollow && !playing_) {
            playing_ = true;
            transport_.playing = true;
        } else if (!startStopFollow && playing_) {
            playing_ = false;
            transport_.playing = false;
            trackFx_.releaseAllActive(graph_, graph_.renderedFrames());
        }
    }

    /**
     * Pops one retired resource without reclaiming it so the caller can inspect its identity first.
     *
     * Params:
     *   item = Receives the retired resource; the caller must invoke item.reclaimOffRT() off-RT.
     *
     * Returns:
     *   True if an item was popped; false if the retire ring is empty.
     */
    bool tryPopRetired(out RetiredResource item) {
        if (!initialized_) {
            return false;
        }
        return retireRing_.tryPop(item);
    }

    /**
     * Applies every queued EngineCommand on the calling thread.
     *
     * Precondition: no RT audio thread is rendering this Engine (device stopped or never started),
     * so the caller is the sole owner of all RT state for the duration of the call.
     */
    void applyPendingCommandsOffRT() {
        if (initialized_) {
            drainCommands();
        }
    }

    /**
     * RT-thread live note-on from an RT-side source (MIDI drained inside the render callback); never touches the
     * UI command ring. Call before processHostBuffer() of the same callback.
     *
     * Params:
     *   target = Module receiving the note.
     *   keyTag = Caller tag identifying the key (MIDI uses MIDI_KEY_TAG_BASE | channel << 8 | note).
     *   midiNote = MIDI note number.
     *   velocity = Velocity in [0, 1].
     *   hostOffset = Frame offset inside the current host buffer.
     */
    void liveNoteOnRt(ModuleId target, uint keyTag, float midiNote, float velocity, uint hostOffset) {
        if (initialized_) {
            triggerLiveNote(target, keyTag, midiNote, velocity, hostOffsetToFrame(hostOffset));
        }
    }

    /**
     * RT-thread live note-off matching liveNoteOnRt().
     *
     * Params:
     *   target = Module that received the note (invalid = any).
     *   keyTag = Tag used at note-on.
     *   hostOffset = Frame offset inside the current host buffer.
     */
    void liveNoteOffRt(ModuleId target, uint keyTag, uint hostOffset) {
        if (initialized_) {
            releaseLiveNote(target, keyTag, hostOffsetToFrame(hostOffset));
        }
    }

    /**
     * RT-thread delivery of an arbitrary ModEvent (pitch bend, aftertouch, unmapped CC).
     *
     * Params:
     *   target = Destination module.
     *   ev = Event payload.
     *   hostOffset = Frame offset inside the current host buffer.
     *
     * Returns:
     *   True if scheduled.
     */
    bool enqueueLiveEventRt(ModuleId target, ModEvent ev, uint hostOffset) {
        if (!initialized_ || !target.isValid()) {
            return false;
        }
        return graph_.enqueueEvent(target, ev, hostOffsetToFrame(hostOffset));
    }

    /**
     * RT-thread MIDI CC application through the active MIDI map.
     *
     * Params:
     *   channel = MIDI channel 0..15.
     *   cc = Controller number 0..127.
     *   value = Controller value 0..127.
     *
     * Returns:
     *   Number of parameters driven (0 = unmapped).
     */
    uint applyMidiCcRt(ubyte channel, ubyte cc, ubyte value) {
        if (!initialized_ || midiMap_ is null) {
            return 0;
        }
        uint hits = 0;
        immutable float v = (value > 127 ? 127 : value) / 127.0f;
        foreach (ref e; midiMap_.view()) {
            if (e.channel == channel && e.cc == cc) {
                graph_.setModuleParamNormalized(e.moduleId, e.paramIdx, e.min01 + (e.max01 - e.min01) * v, false);
                hits++;
            }
        }
        return hits;
    }

    /**
     * UI-thread consumer of published scope blocks (single consumer).
     *
     * Params:
     *   block = Receives the oldest unread block.
     *
     * Returns:
     *   True if a block was popped.
     */
    bool tryPopScopeBlock(out ScopeBlock block) {
        return initialized_ && scopeRing_.tryPop(block);
    }

    /**
     * Returns how many scope blocks the RT thread dropped because the ring was full.
     *
     * Returns:
     *   Drop count.
     */
    ulong scopeBlocksDropped() const {
        return atomicLoad!(MemoryOrder.acq)(scopeDropped_);
    }

    /**
     * Returns the newest fence token acknowledged by the thread that drains commands.
     *
     * Returns:
     *   Last applied fence sequence (acquire ordering), or 0 if none.
     */
    ulong appliedFence() const {
        return atomicLoad!(MemoryOrder.acq)(appliedFence_);
    }

    /**
     * Selects the module whose active pattern notes are reported in EngineTelemetry.patternNoteMask.
     *
     * Params:
     *   modId = Target module identifier (invalid disables pattern-note tracking).
     */
    void setWatchedNoteModule(ModuleId modId) {
        atomicStore!(MemoryOrder.rel)(watchNoteModule_, modId.value);
    }

    /**
     * Returns the module currently watched for pattern-note telemetry.
     *
     * Returns:
     *   Watched module id, or 0 when disabled.
     */
    uint watchedNoteModule() const {
        return atomicLoad!(MemoryOrder.acq)(watchNoteModule_);
    }

    /**
     * Returns whether sequencer playback is currently active.
     *
     * Returns:
     *   True if playing.
     */
    bool isPlaying() const pure @safe {
        return playing_;
    }

    /**
     * Reports whether a live-record count-in is still clicking toward its start line.
     *
     * Returns:
     *   True between playCountIn and the record start line.
     */
    bool isCountingIn() const pure @safe {
        return countIn_.armed();
    }

    /**
     * Returns the number of count-in clicks triggered since the last playCountIn command.
     *
     * Returns:
     *   Click count.
     */
    uint countInClicks() const pure @safe {
        return countIn_.clicksTriggered();
    }

    /**
     * Returns current active tempo in BPM.
     *
     * Returns:
     *   Current BPM.
     */
    double bpm() const pure @safe {
        return clock_.bpm();
    }

    /**
     * Returns current active ticks per line.
     *
     * Returns:
     *   Current TPL count.
     */
    uint ticksPerLine() const pure @safe {
        return clock_.ticksPerLine();
    }

    /**
     * Returns current sequencer line index.
     *
     * Returns:
     *   Current song line.
     */
    long currentLine() const pure @safe {
        return clock_.currentLine();
    }

    /**
     * Attaches a compiled GraphPlan directly off-RT before streaming starts.
     *
     * Params:
     *   plan = Compiled GraphPlan* (transferred ownership to Engine).
     */
    void attachPlanOffRT(GraphPlan* plan) {
        GraphPlan* oldPlan = graph_.detachPlan();
        if (oldPlan !is null) {
            GraphPlan.destroyOffRT(oldPlan);
        }
        graph_.swapPlan(plan);
    }

    /**
     * Attaches or replaces a PatternSnapshot off-RT cleanly.
     *
     * Params:
     *   patternId = Logical pattern identifier.
     *   snap = Off-RT allocated PatternSnapshot*.
     *
     * Returns:
     *   True if registered in patterns_.
     */
    bool attachPatternOffRT(uint patternId, PatternSnapshot* snap) {
        PatternSnapshot* displaced = swapPatternInternal(patternId, snap);
        if (displaced !is null && displaced !is snap) {
            PatternSnapshot.destroyOffRT(displaced);
        }
        return findPattern(patternId) is snap;
    }

    /**
     * Attaches or replaces the active TimelineSnapshot off-RT cleanly.
     *
     * Params:
     *   snap = Off-RT allocated TimelineSnapshot*.
     */
    void attachTimelineOffRT(TimelineSnapshot* snap) {
        if (timeline_ !is null && timeline_ !is snap) {
            TimelineSnapshot.destroyOffRT(timeline_);
        }
        timeline_ = snap;
        if (timeline_ !is null) {
            clock_.setLoop(timeline_.loopStartLine, timeline_.loopEndLine);
        } else {
            clock_.setLoop(0, 0);
        }
    }

    /**
     * Directly sets sequencer playback active state off-RT or at setup time.
     *
     * Params:
     *   play = True to enable playback.
     */
    void setPlaying(bool play) {
        playing_ = play;
        transport_.playing = play;
        if (!play) {
            trackFx_.releaseAllActive(graph_, graph_.renderedFrames());
            countIn_.disarm(true);
        }
    }

    /**
     * Directly seeks playhead to line off-RT or at setup time.
     *
     * Params:
     *   line = Zero-based target song line.
     */
    void seekLine(long line) {
        trackFx_.releaseAllActive(graph_, graph_.renderedFrames());
        countIn_.disarm(true);
        clock_.seekToLine(line);
        pendingJumpLine_ = -1;
    }

    /**
     * Configures tempo and speed directly off-RT before rendering.
     *
     * Params:
     *   targetBpm = Initial beats per minute.
     *   targetTpl = Initial ticks per line.
     */
    void setTempo(double targetBpm, uint targetTpl) {
        clock_.setBpm(targetBpm);
        clock_.setTicksPerLine(targetTpl);
        transport_.bpm = clock_.bpm();
        transport_.ticksPerLine = clock_.ticksPerLine();
    }

    /**
     * Sets a module scalar parameter directly on the attached GraphPlan.
     *
     * Params:
     *   id = Target ModuleId.
     *   paramIdx = Zero-based parameter index.
     *   value = Domain value.
     *   instant = True to snap smoothers immediately.
     *
     * Returns:
     *   True if updated.
     */
    bool setModuleParamDirect(ModuleId id, uint paramIdx, float value, bool instant = false) {
        return graph_.setModuleParam(id, paramIdx, value, instant);
    }

    /**
     * Enqueues a sample-accurate ModEvent directly into the underlying AudioGraph.
     *
     * Params:
     *   targetMod = Target ModuleId.
     *   ev = ModEvent payload.
     *   absFrame = Target absolute graph frame.
     *
     * Returns:
     *   True if enqueued.
     */
    bool enqueueEventDirect(ModuleId targetMod, ModEvent ev, FrameTime absFrame) {
        return graph_.enqueueEvent(targetMod, ev, absFrame);
    }

    /**
     * Returns total internal sample frames rendered by the underlying AudioGraph.
     *
     * Returns:
     *   Total rendered frame count.
     */
    FrameTime renderedFrames() const pure @safe {
        return graph_.renderedFrames();
    }

    /**
     * Processes arbitrary hostFrames audio callbacks in fixed 64-frame internal Engine slices cleanly @nogc.
     *
     * Params:
     *   outputs = Host stereo output buffers (>= hostFrames).
     *   inputs = Optional host stereo input buffers for duplex AudioInput modules.
     *   hostFrames = Number of frames requested by CoreAudio or offline loop.
     */
    void processHostBuffer(float[][2] outputs, const(float[])[2] inputs, uint hostFrames) {
        if (!initialized_ || hostFrames == 0) {
            return;
        }
        assert(outputs[0].length >= hostFrames && outputs[1].length >= hostFrames,
            "Engine.processHostBuffer output slices smaller than hostFrames");

        pushHostInputs(inputs, hostFrames);

        uint hostPos = 0;
        while (hostPos < hostFrames) {
            if (stageOutRead_ < stageOutAvail_) {
                immutable uint avail = stageOutAvail_ - stageOutRead_;
                immutable uint rem = hostFrames - hostPos;
                immutable uint copyCount = avail < rem ? avail : rem;
                outputs[0][hostPos .. hostPos + copyCount] =
                    stageOut_[0][stageOutRead_ .. stageOutRead_ + copyCount];
                outputs[1][hostPos .. hostPos + copyCount] =
                    stageOut_[1][stageOutRead_ .. stageOutRead_ + copyCount];
                stageOutRead_ += copyCount;
                hostPos += copyCount;
                continue;
            }

            popHostInputQuantum();
            float[][2] qOut = [stageOut_[0][], stageOut_[1][]];
            const(float[])[2] qIn = [stageIn_[0][], stageIn_[1][]];
            renderSingleQuantum(qOut, qIn, FIXED_BLOCK_FRAMES);
            stageOutRead_ = 0;
            stageOutAvail_ = FIXED_BLOCK_FRAMES;
        }
    }

    /**
     * Renders 1..FIXED_BLOCK_FRAMES directly without host staging latency (used inside MetaModule sub-slices).
     *
     * Params:
     *   outputs = Destination stereo slices (>= subFrames).
     *   inputs = Host/parent stereo input slices.
     *   subFrames = Direct sub-slice frame count in [1 .. FIXED_BLOCK_FRAMES].
     */
    void processDirectSubFrames(float[][2] outputs, const(float[])[2] inputs, uint subFrames) {
        if (!initialized_ || subFrames == 0) {
            return;
        }
        immutable uint sf = subFrames > FIXED_BLOCK_FRAMES ? FIXED_BLOCK_FRAMES : subFrames;
        renderSingleQuantum(outputs, inputs, sf);
    }

    private void renderSingleQuantum(float[][2] outSlice, const(float[])[2] inSlice, uint qFrames) {
        drainCommands();
        stepSequencerOverFrames(qFrames);
        transport_.playing = playing_;
        transport_.bpm = clock_.bpm();
        transport_.ticksPerLine = clock_.ticksPerLine();
        graph_.renderQuantumDirect(outSlice, inSlice, transport_, qFrames);
        countIn_.renderAdd(outSlice[0], outSlice[1], qFrames);
        publishTelemetry();
        if (scopeEnabled_ && qFrames == FIXED_BLOCK_FRAMES) {
            publishScopeBlocks(outSlice);
        }
    }

    private void publishScopeBlocks(float[][2] master) {
        immutable ulong frame = graph_.renderedFrames() - FIXED_BLOCK_FRAMES;
        scopeScratch_.sourceId = 0;
        scopeScratch_.frame = frame;
        scopeScratch_.left[] = master[0][0 .. FIXED_BLOCK_FRAMES];
        scopeScratch_.right[] = master[1][0 .. FIXED_BLOCK_FRAMES];
        pushScopeScratch();
        foreach (tap; scopeTaps_) {
            if (!tap.isValid()) {
                continue;
            }
            if (graph_.copyLastNodeAudioBus(tap, scopeScratch_.left[], scopeScratch_.right[])) {
                scopeScratch_.sourceId = tap.value;
                scopeScratch_.frame = frame;
                pushScopeScratch();
            }
        }
    }

    private void pushScopeScratch() {
        if (!scopeRing_.tryPush(scopeScratch_)) {
            atomicStore!(MemoryOrder.rel)(scopeDropped_, atomicLoad!(MemoryOrder.raw)(scopeDropped_) + 1);
        }
    }

    private FrameTime hostOffsetToFrame(uint hostOffset) const {
        immutable FrameTime rendered = graph_.renderedFrames();
        immutable uint pending = stageOutAvail_ > stageOutRead_ ? stageOutAvail_ - stageOutRead_ : 0;
        immutable FrameTime base = rendered >= pending ? rendered - pending : 0;
        immutable FrameTime target = base + hostOffset;
        return target < rendered ? rendered : target;
    }

    private RetireSink retireSink() pure {
        return RetireSink(&pushToRetireRing, &retireRing_);
    }

    private static bool pushToRetireRing(void* rawCtx, RetiredResource res) @nogc nothrow {
        auto ring = cast(SpscRing!RetiredResource*) rawCtx;
        if (ring !is null) {
            return ring.tryPush(res);
        }
        return false;
    }

    private void drainCommands() {
        EngineCommand cmd;
        RetireSink rs = retireSink();
        FrameTime nowFrame = graph_.renderedFrames();

        while (cmdRing_.tryPop(cmd)) {
            switch (cmd.kind) {
                case EngineCmdKind.play:
                    playing_ = true;
                    transport_.playing = true;
                    break;

                case EngineCmdKind.stop:
                    playing_ = false;
                    transport_.playing = false;
                    pendingJumpLine_ = -1;
                    trackFx_.releaseAllActive(graph_, nowFrame);
                    countIn_.disarm(true);
                    break;

                case EngineCmdKind.seekLine:
                    trackFx_.releaseAllActive(graph_, nowFrame);
                    countIn_.disarm(true);
                    clock_.seekToLine(cmd.lineVal);
                    pendingJumpLine_ = -1;
                    break;

                case EngineCmdKind.playCountIn: {
                    trackFx_.releaseAllActive(graph_, nowFrame);
                    immutable long countLines = cmd.lineVal2 > 0 ? cmd.lineVal2 : 0;
                    immutable long firstLine = cmd.lineVal - countLines;
                    clock_.seekToLineSigned(firstLine);
                    pendingJumpLine_ = -1;
                    countIn_.arm(firstLine, cmd.lineVal, cmd.paramIdx);
                    playing_ = true;
                    transport_.playing = true;
                    break;
                }

                case EngineCmdKind.setBpm:
                    clock_.setBpm(cmd.doubleVal);
                    transport_.bpm = clock_.bpm();
                    break;

                case EngineCmdKind.setTicksPerLine:
                    clock_.setTicksPerLine(cmd.paramIdx);
                    transport_.ticksPerLine = clock_.ticksPerLine();
                    break;

                case EngineCmdKind.setLoop:
                    clock_.setLoop(cmd.lineVal, cmd.lineVal2);
                    break;

                case EngineCmdKind.swapGraphPlan:
                    graph_.swapPlan(cmd.graphPlan, rs);
                    break;

                case EngineCmdKind.swapModuleAsset:
                    graph_.swapModuleAsset(cmd.targetMod, cmd.slot, cmd.assetPtr, cmd.assetDestroyFn, rs);
                    break;

                case EngineCmdKind.setModuleParam:
                    graph_.setModuleParam(cmd.targetMod, cmd.paramIdx, cmd.floatVal, cmd.boolVal);
                    break;

                case EngineCmdKind.setModuleParamNorm:
                    graph_.setModuleParamNormalized(cmd.targetMod, cmd.paramIdx, cmd.floatVal, cmd.boolVal);
                    break;

                case EngineCmdKind.setModuleMute:
                    graph_.setNodeMuted(cmd.targetMod, cmd.boolVal);
                    break;

                case EngineCmdKind.setModuleBypass:
                    graph_.setNodeBypassed(cmd.targetMod, cmd.boolVal);
                    break;

                case EngineCmdKind.swapPattern: {
                    PatternSnapshot* oldPat = swapPatternInternal(cmd.slot, cmd.patternSnap);
                    if (oldPat !is null) {
                        rs.push(RetiredResource(RetiredKind.patternSnapshot, oldPat, &PatternSnapshot.destroyErased));
                    }
                    break;
                }

                case EngineCmdKind.patchCell: {
                    PatternSnapshot* targetPat = findPattern(cmd.slot);
                    if (targetPat !is null) {
                        patchCellAtomic(targetPat, cmd.track, cmd.line, cmd.cell);
                    }
                    break;
                }

                case EngineCmdKind.swapTimeline: {
                    TimelineSnapshot* oldTl = timeline_;
                    timeline_ = cmd.timelineSnap;
                    if (timeline_ !is null) {
                        clock_.setLoop(timeline_.loopStartLine, timeline_.loopEndLine);
                    } else {
                        clock_.setLoop(0, 0);
                    }
                    if (oldTl !is null) {
                        rs.push(RetiredResource(RetiredKind.timelineSnapshot, oldTl, &TimelineSnapshot.destroyErased));
                    }
                    break;
                }

                case EngineCmdKind.liveNoteOn:
                    triggerLiveNote(cmd.targetMod, cmd.tag, cmd.floatVal, cmd.floatVal2, nowFrame);
                    break;

                case EngineCmdKind.liveNoteOff:
                    releaseLiveNote(cmd.targetMod, cmd.tag, nowFrame);
                    break;

                case EngineCmdKind.allNotesOff:
                    releaseAllLiveAndTrackNotes(cmd.targetMod, nowFrame);
                    break;

                case EngineCmdKind.sendModEvent:
                    if (cmd.targetMod.isValid()) {
                        graph_.enqueueEvent(cmd.targetMod, cmd.modEvent, nowFrame);
                    }
                    break;

                case EngineCmdKind.swapMidiMap: {
                    MidiMapSnapshot* old = midiMap_;
                    midiMap_ = cmd.midiMap;
                    if (old !is null) {
                        rs.push(RetiredResource(RetiredKind.midiMap, old, &MidiMapSnapshot.destroyErased));
                    }
                    break;
                }

                case EngineCmdKind.setScopeTaps:
                    scopeEnabled_ = cmd.boolVal;
                    scopeTaps_ = [ModuleId(cmd.tag), ModuleId(cmd.slot), ModuleId(cmd.track), ModuleId(cmd.line)];
                    break;

                case EngineCmdKind.fence:
                    atomicStore!(MemoryOrder.rel)(appliedFence_, cast(ulong) cmd.lineVal);
                    break;

                default:
                    break;
            }
        }
    }

    private void stepSequencerOverFrames(uint frames) {
        if (!playing_) {
            return;
        }
        immutable FrameTime baseFrame = graph_.renderedFrames();
        uint cursor = 0;

        while (cursor < frames) {
            TickEvent tev;
            if (!clock_.nextTickInSlice(frames, cursor, tev)) {
                break;
            }
            if (tev.isLineStart && pendingJumpLine_ >= 0) {
                immutable long jumpTarget = pendingJumpLine_;
                pendingJumpLine_ = -1;
                clock_.seekToLine(jumpTarget);
                continue;
            }

            if (tev.isLineStart) {
                countIn_.onLineStart(tev.line, tev.frameOffset);
            }
            immutable FrameTime absTickFrame = baseFrame + tev.frameOffset;
            SequencerActionFlags actions;
            TimelineClip[MAX_LINE_CLIPS] activeClips;
            immutable size_t clipCount = timeline_ !is null
                ? timeline_.collectActiveClipsAtLine(tev.line, activeClips[]) : 0;

            foreach (ci; 0 .. clipCount) {
                auto ref clip = activeClips[ci];
                PatternSnapshot* pat = findPattern(clip.patternId);
                if (pat is null || pat.tracks == 0 || pat.lines == 0) {
                    continue;
                }
                immutable long relLine = (tev.line - clip.startLine) + cast(long) clip.patternOffset;
                immutable uint patLine = cast(uint)(relLine >= 0 ? (cast(ulong) relLine % pat.lines) : 0uL);
                immutable TrackKeyKind tkKind = clip.isSupertrack ? TrackKeyKind.supertrack : TrackKeyKind.clip;
                immutable uint ownerId = clip.isSupertrack ? clip.laneY : clip.clipId;

                foreach (tr; 0 .. pat.tracks) {
                    immutable NoteCell cell = pat.getCellAtomic(tr, patLine);
                    trackFx_.processCellTick(
                        tkKind,
                        ownerId,
                        tr,
                        cell,
                        tev.tick,
                        absTickFrame,
                        clock_,
                        graph_,
                        actions
                    );
                }
            }

            if (actions.hasTplChange) {
                clock_.setTicksPerLine(actions.newTpl);
                transport_.ticksPerLine = clock_.ticksPerLine();
            }
            if (actions.hasBpmChange) {
                clock_.setBpm(actions.newBpm);
                transport_.bpm = clock_.bpm();
            }
            if (actions.hasJump) {
                pendingJumpLine_ = actions.jumpTargetLine;
            }
            if (actions.stopSong) {
                playing_ = false;
                pendingJumpLine_ = -1;
                trackFx_.releaseAllActive(graph_, absTickFrame);
                break;
            }
        }
    }

    private PatternSnapshot* findPattern(uint patternId) pure @safe {
        foreach (ref p; patterns_) {
            if (p.occupied && p.patternId == patternId) {
                return p.snap;
            }
        }
        return null;
    }

    private PatternSnapshot* swapPatternInternal(uint patternId, PatternSnapshot* nextSnap) pure @safe {
        foreach (ref p; patterns_) {
            if (p.occupied && p.patternId == patternId) {
                PatternSnapshot* old = p.snap;
                if (nextSnap is null) {
                    p = PatternSlotEntry.init;
                } else {
                    p.snap = nextSnap;
                }
                return old;
            }
        }
        if (nextSnap !is null) {
            foreach (ref p; patterns_) {
                if (!p.occupied) {
                    p.occupied = true;
                    p.patternId = patternId;
                    p.snap = nextSnap;
                    return null;
                }
            }
        }
        return nextSnap;
    }

    private NoteId nextLiveNoteId() pure @safe {
        uint seq = nextLiveNoteSeq_++;
        if (seq == 0 || seq >= 0x3FFF_0000u) {
            nextLiveNoteSeq_ = 2;
            seq = 1;
        }
        return NoteId(0x4000_0000u + seq);
    }

    private void triggerLiveNote(ModuleId modId, uint keyTag, float midiNote, float vel, FrameTime nowFrame) {
        if (!modId.isValid()) {
            return;
        }
        size_t chosen = size_t.max;
        foreach (idx, ref lv; liveVoices_) {
            if (lv.active && lv.modId == modId && lv.keyTag == keyTag) {
                graph_.enqueueEvent(lv.modId, ModEvent.makeNoteOff(lv.noteId), nowFrame);
                chosen = idx;
                break;
            }
        }
        if (chosen == size_t.max) {
            foreach (idx, ref lv; liveVoices_) {
                if (!lv.active) {
                    chosen = idx;
                    break;
                }
            }
        }
        if (chosen == size_t.max) {
            chosen = 0;
            if (liveVoices_[0].active && liveVoices_[0].modId.isValid()) {
                graph_.enqueueEvent(liveVoices_[0].modId, ModEvent.makeNoteOff(liveVoices_[0].noteId), nowFrame);
            }
        }

        immutable NoteId nid = nextLiveNoteId();
        liveVoices_[chosen] = LiveVoiceSlot(true, modId, keyTag, nid);
        graph_.enqueueEvent(modId, ModEvent.makeNoteOn(nid, midiNote, vel), nowFrame);
    }

    private void releaseLiveNote(ModuleId modId, uint keyTag, FrameTime nowFrame) {
        foreach (ref lv; liveVoices_) {
            if (lv.active && lv.keyTag == keyTag && (!modId.isValid() || lv.modId == modId)) {
                if (lv.modId.isValid() && lv.noteId.isValid()) {
                    graph_.enqueueEvent(lv.modId, ModEvent.makeNoteOff(lv.noteId), nowFrame);
                }
                lv = LiveVoiceSlot.init;
            }
        }
    }

    private void releaseAllLiveAndTrackNotes(ModuleId modId, FrameTime nowFrame) {
        if (modId.isValid()) {
            graph_.enqueueEvent(modId, ModEvent.makeAllNotesOff(), nowFrame);
        }
        foreach (ref lv; liveVoices_) {
            if (lv.active && (!modId.isValid() || lv.modId == modId)) {
                if (lv.modId.isValid() && lv.noteId.isValid()) {
                    graph_.enqueueEvent(lv.modId, ModEvent.makeAllNotesOff(), nowFrame);
                }
                lv = LiveVoiceSlot.init;
            }
        }
        trackFx_.releaseAllActive(graph_, nowFrame);
    }

    private void pushHostInputs(const(float[])[2] inputs, uint hostFrames) {
        if (hostInRingL_.empty() || hostInRingR_.empty()) {
            return;
        }
        immutable size_t cap = hostInRingL_.length;
        immutable size_t mask = cap - 1;
        const(float)[] inL = inputs[0];
        const(float)[] inR = inputs[1];
        foreach (i; 0 .. hostFrames) {
            immutable float l = (i < inL.length && isFinite(inL[i])) ? inL[i] : 0.0f;
            immutable float r = (i < inR.length && isFinite(inR[i])) ? inR[i] : 0.0f;
            if (hostInCount_ >= cap) {
                hostInRead_ = (hostInRead_ + 1) & mask;
                hostInCount_--;
            }
            hostInRingL_[hostInWrite_] = l;
            hostInRingR_[hostInWrite_] = r;
            hostInWrite_ = (hostInWrite_ + 1) & mask;
            hostInCount_++;
        }
    }

    private void popHostInputQuantum() {
        stageIn_[0][] = 0.0f;
        stageIn_[1][] = 0.0f;
        if (hostInRingL_.empty() || hostInRingR_.empty() || hostInCount_ == 0) {
            return;
        }
        immutable size_t mask = hostInRingL_.length - 1;
        immutable size_t pullCount = hostInCount_ < FIXED_BLOCK_FRAMES ? hostInCount_ : FIXED_BLOCK_FRAMES;
        foreach (i; 0 .. pullCount) {
            stageIn_[0][i] = hostInRingL_[hostInRead_];
            stageIn_[1][i] = hostInRingR_[hostInRead_];
            hostInRead_ = (hostInRead_ + 1) & mask;
        }
        hostInCount_ -= pullCount;
    }

    private void publishTelemetry() {
        EngineTelemetry* tel = &telemetry_.backBuffer();
        graph_.readTelemetry(tel.graph);
        tel.currentLine = clock_.currentLine();
        tel.currentTick = clock_.currentTick();
        tel.countingIn = countIn_.armed();
        tel.bpm = clock_.bpm();
        tel.ticksPerLine = clock_.ticksPerLine();
        tel.playing = playing_;
        tel.totalFrames = cast(ulong) graph_.renderedFrames();
        immutable uint watchMod = atomicLoad!(MemoryOrder.acq)(watchNoteModule_);
        tel.patternNoteModuleId = watchMod;
        tel.patternNoteMask[0] = 0uL;
        tel.patternNoteMask[1] = 0uL;
        if (playing_ && watchMod != 0) {
            trackFx_.collectActiveNotes(ModuleId(watchMod), tel.patternNoteMask);
        }
        telemetry_.publish();
    }
}

static assert(!hasGcReference!Engine,
    "Engine must remain free of D GC indirections");
