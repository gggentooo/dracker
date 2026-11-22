/**
 * File:         source/app/session.d
 * Module:       app.session
 * Phase:        Phase 6.3 / 8.6 — Application Session & UI <-> RT Bridge
 *
 * Purpose:
 *   Owns document lifecycle, dirty state, periodic .msv autosave, GraphCompiler invocation, off-RT asset decoding orchestration, UndoHistory dispatch, Keymap handling, and retire-ring reclamation between UI/CLI threads and Engine.
 *
 * Real-Time & Safety Contract:
 *   Executes strictly on the main/UI thread; pushes @nogc snapshots/commands into Engine SpscRing!EngineCommand.
 *   The document (doc_) is the source of truth for parameters; module assets are read for saving only after a
 *   synchronizeEngine() fence round-trip. Removed modules are freed only after the GraphPlan that referenced them
 *   returns through the retire ring. Every Engine teardown (load/new/shutdown) first stops the attached IAudioDriver.
 *   Every mutation is all-or-nothing: if a GraphPlan/snapshot cannot reach the Engine the document is rolled back.
 *
 * Dependencies:
 *   Internal: app.{history,keymap}, foundation.types, graph.{module_api,plan,registry}, io.importers.*, io.project_format, modules.control.metamodule, platform.interfaces, sequencer.{engine,note,pattern,timeline}
 *   External: core.thread (Thread.sleep), core.time (Duration, MonoTime), std.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - class StudioSession : initialize(), shutdown(), attachAudioDriver(), synchronizeEngine(), setEngineSyncTimeout(), pendingRetiredModuleCount(), newEmptyProject(), compileAndSwapGraph(), doAddModule(), doRemoveModule(), doConnectWire(), doDisconnectWire(), doSetParam(), doPatchCell(), doResizePattern(), doAddClip(), doMoveClip(), doCloneClip(), doRemoveClip(), doSetClipFlags(), doSetTempo(), undo(), redo(), saveProject(), openProject(), saveModulePreset(), loadModulePreset(), importMidiBytes(), importXmBytes(), importSunvoxBytes(), handleKeyEvent(), pollRetiredAndTelemetry()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module app.session;

import core.thread : Thread;
import core.time : dur, Duration, MonoTime;
import std.math : isFinite;

import app.history;
import app.keymap : Keymap, StudioAction;
import foundation.types : ModuleId;
import graph.audio_graph : RetiredKind, RetiredResource;
import graph.module_api : ModuleDescriptor, ModuleInstance;
import graph.plan : GraphCompileError, GraphCompiler, GraphPlan, NodeSpec, WireSpec;
import graph.registry : ModuleRegistry;
import io.importers.smf_importer : importMidiFile;
import io.importers.sunvox_importer : ImportReport, importSunvoxFile;
import io.importers.xm_importer : importXmFile;
import io.project_format : LoadedPreset, LoadedProject, loadPreset, loadProject, loadProjectFile,
    isValidPatternShape, isValidTempo, materializeProjectToEngine, savePreset, saveProject, SavedModule, SavedPattern, SavedWire,
    serializePreset, serializeProject;
import modules.control.metamodule : MetaMacroBinding, MetaModuleAsset;
import platform.interfaces : IAudioDriver, PlatformEvent, PlatformEventKind;
import sequencer.engine : Engine, EngineCommand, EngineTelemetry;
import sequencer.note : NoteCell;
import sequencer.pattern : PatternSnapshot;
import sequencer.timeline : TimelineClip, TimelineSnapshot;

/**
 * Removed module awaiting proof that no GraphPlan visible to the RT thread still references it.
 */
private struct PendingModuleRetire {
    ModuleInstance inst;
    GraphPlan* guardPlan = null;
}

/**
 * Coordinates the editable LoadedProject document, UndoHistory, Keymap, and RT Engine.
 *
 * Threading contract: any thread other than the caller that renders engine() must be driven by an
 * IAudioDriver registered through attachAudioDriver(), so the session can stop it before tearing
 * down Engine state and can distinguish RT-owned from UI-owned engine phases.
 */
class StudioSession {
    private Engine engine_;
    private UndoHistory history_;
    private Keymap keymap_;
    private LoadedProject doc_;
    private ModuleInstance[uint] liveModules_;
    private PendingModuleRetire[] retiredModules_;
    private IAudioDriver audioDriver_;
    private GraphPlan* activePlan_ = null;
    private ulong fenceSeq_ = 0;
    private Duration engineSyncTimeout_ = dur!"seconds"(2);

    private float sampleRate_ = 44_100.0f;
    private bool initialized_ = false;
    private bool dirty_ = false;
    private bool recording_ = false;
    private int currentOctave_ = 4;
    private uint currentPatternId_ = 1;
    private uint nextModuleId_ = 2;
    private uint nextClipId_ = 1;
    private string currentPath_;

    /**
     * Initializes the underlying Engine, UndoHistory, Keymap, and default empty project off-RT.
     *
     * Params:
     *   sampleRate = Target audio sample rate in Hertz.
     *
     * Returns:
     *   True if initialized successfully; false on invalid sample rate or OOM.
     */
    bool initialize(float sampleRate = 44_100.0f) {
        shutdown();
        if (!engine_.tryInit(sampleRate)) {
            return false;
        }
        sampleRate_ = sampleRate;
        history_ = new UndoHistory();
        keymap_ = Keymap.createDefault();
        initialized_ = true;
        newEmptyProject(true);
        return true;
    }

    /**
     * Stops the attached audio driver (left stopped), then releases all Engine buffers, live ModuleInstances,
     * and queued retired modules safely off-RT.
     */
    void shutdown() {
        suspendAudio();
        clearLiveAndEngine();
        if (history_ !is null) {
            history_.clear();
        }
        initialized_ = false;
    }

    /**
     * Registers the audio driver whose render thread drives engine().
     *
     * The session stops the driver around every Engine teardown (load, new project, shutdown) and
     * restarts it afterwards if it was running, and uses fence round-trips while it is running.
     *
     * Params:
     *   driver = Opened audio driver rendering engine(), or null to detach.
     */
    void attachAudioDriver(IAudioDriver driver) {
        audioDriver_ = driver;
    }

    /**
     * Sets how long synchronizeEngine() waits for the RT thread to acknowledge a fence.
     *
     * Params:
     *   timeout = Positive wait limit (default 2 seconds).
     */
    void setEngineSyncTimeout(Duration timeout) {
        engineSyncTimeout_ = timeout > Duration.zero ? timeout : dur!"msecs"(1);
    }

    /**
     * Blocks until every command queued so far has been applied by the Engine, then reclaims retired resources.
     *
     * With a running audio driver this pushes a fence and waits for the RT thread to acknowledge it;
     * otherwise the calling thread owns the Engine and applies the pending commands itself.
     *
     * Returns:
     *   True if the Engine reflects every queued command; false on fence timeout.
     */
    bool synchronizeEngine() {
        if (!audioThreadActive()) {
            engine_.applyPendingCommandsOffRT();
            reclaimRetired();
            return true;
        }
        immutable ulong seq = ++fenceSeq_;
        if (!sendCommand(EngineCommand.makeFence(seq))) {
            return false;
        }
        immutable MonoTime deadline = MonoTime.currTime + engineSyncTimeout_;
        while (engine_.appliedFence() < seq) {
            if (MonoTime.currTime > deadline) {
                return false;
            }
            Thread.sleep(dur!"usecs"(250));
        }
        reclaimRetired();
        return true;
    }

    /**
     * Returns the number of removed modules still awaiting safe reclamation.
     *
     * Returns:
     *   Count of retired modules whose guarding GraphPlan has not yet left the RT thread.
     */
    size_t pendingRetiredModuleCount() const {
        return retiredModules_.length;
    }

    /**
     * Returns a pointer to the owned RT Engine for audio driver hookup or offline test rendering.
     *
     * Returns:
     *   Pointer to internal Engine struct.
     */
    Engine* engine() {
        return &engine_;
    }

    /**
     * Returns current document reference for read-only GUI inspection.
     *
     * Returns:
     *   Const reference to active LoadedProject document.
     */
    const(LoadedProject)* document() const {
        return &doc_;
    }

    /**
     * Returns mutable UndoHistory controller.
     *
     * Returns:
     *   Active UndoHistory instance.
     */
    UndoHistory history() {
        return history_;
    }

    /**
     * Returns mutable reference to active keyboard piano and shortcut Keymap.
     *
     * Returns:
     *   Reference to Keymap.
     */
    ref Keymap keymap() {
        return keymap_;
    }

    /**
     * Reports whether unsaved document edits exist since the last save/load.
     *
     * Returns:
     *   True if modified.
     */
    bool isDirty() const {
        return dirty_;
    }

    /**
     * Returns current active filesystem path, if any.
     *
     * Returns:
     *   Document file path or empty string.
     */
    string currentPath() const {
        return currentPath_;
    }

    /**
     * Returns current tracker QWERTY piano octave.
     *
     * Returns:
     *   Octave number [-1..9].
     */
    int currentOctave() const {
        return currentOctave_;
    }

    /**
     * Resets the session to an empty default project containing MasterOutput and 1 empty pattern.
     *
     * Params:
     *   withDefaultOutput = True to instantiate core.output (ModuleId 1) automatically.
     */
    void newEmptyProject(bool withDefaultOutput = true) {
        if (!initialized_) {
            return;
        }
        immutable bool wasRunning = suspendAudio();
        scope (exit) resumeAudio(wasRunning);
        resetToEmptyProjectSuspended(withDefaultOutput);
    }

    private void resetToEmptyProjectSuspended(bool withDefaultOutput) {
        clearLiveAndEngine();
        if (!engine_.tryInit(sampleRate_)) {
            initialized_ = false;
            return;
        }
        doc_ = LoadedProject.init;
        doc_.title = "Untitled";
        doc_.author = "SynthTracker";
        doc_.bpm = 125.0;
        doc_.ticksPerLine = 6;

        SavedPattern initPat;
        initPat.patternId = 1;
        initPat.tracks = 4;
        initPat.lines = 64;
        initPat.name = "Pattern 01";
        initPat.cells = new NoteCell[4 * 64];
        doc_.patterns ~= initPat;
        doc_.clips ~= TimelineClip(1, 1, 0, 0, 64, 0, 0, false, false, false);

        if (withDefaultOutput) {
            SavedModule master;
            master.id = 1;
            master.typeId = "core.output";
            master.name = "Master Output";
            master.paramValues = [1.0f, 1.0f];
            doc_.modules ~= master;
            instantiateSavedModule(master);
            nextModuleId_ = 2;
        } else {
            nextModuleId_ = 1;
        }

        nextClipId_ = 2;
        currentPatternId_ = 1;
        currentPath_ = null;
        dirty_ = false;
        if (history_ !is null) history_.clear();

        compileAndSwapGraph(true);
        pushPatternSnapshotDirect(initPat, true);
        pushTimelineSnapshot(true);
        engine_.setTempo(doc_.bpm, doc_.ticksPerLine);
    }

    /**
     * Allocates and returns the next unique non-zero module identifier.
     *
     * Returns:
     *   Unique ModuleId integer.
     */
    uint allocateNextModuleId() {
        uint id = nextModuleId_++;
        while (findModuleDoc(id) !is null || id == 0) {
            id = nextModuleId_++;
        }
        return id;
    }

    /**
     * Allocates and returns the next unique timeline clip identifier.
     *
     * Returns:
     *   Unique ClipId integer.
     */
    uint allocateNextClipId() {
        uint cid = nextClipId_++;
        while (findClipDoc(cid) !is null || cid == 0) {
            cid = nextClipId_++;
        }
        return cid;
    }

    /**
     * Recompiles the document modular graph off-RT and swaps the GraphPlan cleanly onto Engine.
     *
     * Params:
     *   immediate = True only while no RT thread renders the Engine (load/init); attaches directly.
     *
     * Returns:
     *   True if the plan compiled and reached the Engine; false leaves the previous plan active.
     */
    bool compileAndSwapGraph(bool immediate = false) {
        NodeSpec[] nodes;
        nodes.reserve(doc_.modules.length);
        foreach (ref sm; doc_.modules) {
            auto ptr = sm.id in liveModules_;
            if (ptr !is null && ptr.state !is null) {
                nodes ~= NodeSpec.fromInstance(*ptr, sm.muted, sm.bypassed);
            }
        }
        WireSpec[] wires = new WireSpec[doc_.wires.length];
        foreach (i, ref sw; doc_.wires) {
            wires[i] = WireSpec(ModuleId(sw.srcMod), sw.srcPort, ModuleId(sw.dstMod), sw.dstPort, sw.gain);
        }

        GraphPlan* plan = null;
        GraphCompileError err;
        if (!GraphCompiler.compile(nodes, wires, plan, err)) {
            if (plan !is null) {
                GraphPlan.destroyOffRT(plan);
            }
            return false;
        }
        if (immediate && !audioThreadActive()) {
            engine_.attachPlanOffRT(plan);
        } else if (!sendCommand(EngineCommand.makeSwapGraphPlan(plan))) {
            GraphPlan.destroyOffRT(plan);
            return false;
        }
        activePlan_ = plan;
        return true;
    }

    /**
     * Rebuilds and swaps a CoW TimelineSnapshot into Engine reflecting doc_.clips and loop range.
     *
     * Params:
     *   immediate = True during initial load to attach directly without SPSC queue delay.
     *
     * Returns:
     *   True on success.
     */
    bool pushTimelineSnapshot(bool immediate = false) {
        TimelineSnapshot* snap = TimelineSnapshot.createOffRT(
            doc_.clips,
            doc_.loopStartLine,
            doc_.loopEndLine
        );
        if (snap is null && doc_.clips.length > 0) {
            return false;
        }
        if (immediate && !audioThreadActive()) {
            engine_.attachTimelineOffRT(snap);
        } else if (!sendCommand(EngineCommand.makeSwapTimeline(snap))) {
            if (snap !is null) {
                TimelineSnapshot.destroyOffRT(snap);
            }
            return false;
        }
        return true;
    }

    /**
     * Allocates a CoW PatternSnapshot from sp and attaches/swaps it cleanly into Engine.
     *
     * Params:
     *   sp = Source SavedPattern matrix.
     *   immediate = True during initial load to attach directly.
     *
     * Returns:
     *   True on success.
     */
    bool pushPatternSnapshotDirect(const ref SavedPattern sp, bool immediate = false) {
        PatternSnapshot* snap = PatternSnapshot.createOffRT(sp.patternId, sp.tracks, sp.lines);
        if (snap is null) {
            return false;
        }
        foreach (ln; 0 .. sp.lines) {
            foreach (tr; 0 .. sp.tracks) {
                immutable size_t cIdx = cast(size_t) ln * cast(size_t) sp.tracks + cast(size_t) tr;
                if (cIdx < sp.cells.length) {
                    snap.setCellAtomic(tr, ln, sp.cells[cIdx]);
                }
            }
        }
        if (immediate && !audioThreadActive()) {
            if (!engine_.attachPatternOffRT(sp.patternId, snap)) {
                PatternSnapshot.destroyOffRT(snap);
                return false;
            }
        } else if (!sendCommand(EngineCommand.makeSwapPattern(sp.patternId, snap))) {
            PatternSnapshot.destroyOffRT(snap);
            return false;
        }
        return true;
    }

    /**
     * Undoable command adding a registered module at (posX, posY) and updating GraphPlan.
     *
     * Params:
     *   typeId = Registered ModuleRegistry type string.
     *   name = Display label.
     *   posX = Initial patchbay X coordinate.
     *   posY = Initial patchbay Y coordinate.
     *
     * Returns:
     *   Assigned non-zero ModuleId, or 0 if typeId is unknown.
     */
    uint doAddModule(string typeId, string name = "", float posX = 0.0f, float posY = 0.0f) {
        const(ModuleDescriptor)* desc = ModuleRegistry.findByTypeId(typeId);
        if (desc is null) {
            return 0;
        }
        SavedModule sm;
        sm.id = allocateNextModuleId();
        sm.typeId = typeId;
        sm.name = name.length > 0 ? name : desc.displayName;
        sm.posX = posX;
        sm.posY = posY;
        sm.paramValues = new float[desc.params.length];
        foreach (pi, ref p; desc.params) {
            sm.paramValues[pi] = p.defaultVal;
        }
        if (!history_.pushAndExecute(new AddModuleCommand(sm), this)) {
            return 0;
        }
        return sm.id;
    }

    /**
     * Undoable command removing moduleId and all incident wires, archiving state cleanly for undo.
     *
     * Params:
     *   modId = Target module identifier.
     *
     * Returns:
     *   True if found and removed.
     */
    bool doRemoveModule(uint modId) {
        SavedModule* smPtr = findModuleDoc(modId);
        if (smPtr is null) {
            return false;
        }
        if (!synchronizeEngine()) {
            return false;
        }
        SavedModule snap = snapshotLiveModule(*smPtr);
        SavedWire[] incident;
        foreach (ref w; doc_.wires) {
            if (w.srcMod == modId || w.dstMod == modId) {
                incident ~= w;
            }
        }
        return history_.pushAndExecute(new RemoveModuleCommand(snap, incident), this);
    }

    /**
     * Undoable command connecting srcMod:srcPort -> dstMod:dstPort when GraphCompiler validates wiring.
     *
     * Params:
     *   srcMod = Source ModuleId.
     *   srcPort = Zero-based source port index.
     *   dstMod = Destination ModuleId.
     *   dstPort = Zero-based destination port index.
     *   gain = Wire gain multiplier.
     *
     * Returns:
     *   True if valid connection was committed.
     */
    bool doConnectWire(uint srcMod, ushort srcPort, uint dstMod, ushort dstPort, float gain = 1.0f) {
        if (findModuleDoc(srcMod) is null || findModuleDoc(dstMod) is null) {
            return false;
        }
        SavedWire w = SavedWire(srcMod, srcPort, dstMod, dstPort, gain);
        if (!testGraphWireValid(w)) {
            return false;
        }
        return history_.pushAndExecute(new ConnectWireCommand(w), this);
    }

    /**
     * Undoable command removing an existing wire matching endpoints.
     *
     * Params:
     *   srcMod = Source ModuleId.
     *   srcPort = Zero-based source port index.
     *   dstMod = Destination ModuleId.
     *   dstPort = Zero-based destination port index.
     *
     * Returns:
     *   True if matching wire existed and was disconnected.
     */
    bool doDisconnectWire(uint srcMod, ushort srcPort, uint dstMod, ushort dstPort) {
        foreach (ref w; doc_.wires) {
            if (w.srcMod == srcMod && w.srcPort == srcPort
                    && w.dstMod == dstMod && w.dstPort == dstPort) {
                return history_.pushAndExecute(new DisconnectWireCommand(w), this);
            }
        }
        return false;
    }

    /**
     * Undoable continuous parameter edit supporting UI knob drag coalescing.
     *
     * Params:
     *   modId = Target module identifier.
     *   paramIdx = Zero-based parameter index.
     *   newVal = Target parameter value in parameter domain units.
     *
     * Returns:
     *   True if module and parameter index exist.
     */
    bool doSetParam(uint modId, uint paramIdx, float newVal) {
        SavedModule* sm = findModuleDoc(modId);
        auto instPtr = modId in liveModules_;
        if (sm is null || instPtr is null || paramIdx >= instPtr.desc.params.length || !isFinite(newVal)) {
            return false;
        }
        float oldVal = paramIdx < sm.paramValues.length
            ? sm.paramValues[paramIdx] : instPtr.desc.params[paramIdx].defaultVal;
        return history_.pushAndExecute(
            new SetParamCommand(modId, paramIdx, oldVal, newVal, history_.currentEpoch()),
            this
        );
    }

    /**
     * Undoable patchbay module position move supporting drag coalescing.
     *
     * Params:
     *   modId = Target module identifier.
     *   newX = Target X position.
     *   newY = Target Y position.
     *
     * Returns:
     *   True if modId exists.
     */
    bool doMoveModulePosition(uint modId, float newX, float newY) {
        SavedModule* sm = findModuleDoc(modId);
        if (sm is null) {
            return false;
        }
        return history_.pushAndExecute(
            new MoveModulePositionCommand(modId, sm.posX, sm.posY, newX, newY, history_.currentEpoch()),
            this
        );
    }

    /**
     * Undoable atomic pattern NoteCell edit dispatched lock-free to the RT Engine.
     *
     * Params:
     *   patternId = Pattern identifier.
     *   track = Zero-based track index.
     *   line = Zero-based line index.
     *   cell = Replacement 8-byte NoteCell.
     *
     * Returns:
     *   True if coordinates are valid.
     */
    bool doPatchCell(uint patternId, uint track, uint line, NoteCell cell) {
        SavedPattern* sp = findPatternDoc(patternId);
        if (sp is null || track >= sp.tracks || line >= sp.lines) {
            return false;
        }
        immutable size_t idx = cast(size_t) line * cast(size_t) sp.tracks + cast(size_t) track;
        immutable NoteCell prev = idx < sp.cells.length ? sp.cells[idx] : NoteCell.init;
        return history_.pushAndExecute(new PatchCellCommand(patternId, track, line, prev, cell), this);
    }

    /**
     * Undoable Copy-on-Write pattern dimension resize.
     *
     * Params:
     *   patternId = Target pattern identifier.
     *   newTracks = Target column count (>= 1).
     *   newLines = Target row count (>= 1).
     *
     * Returns:
     *   True if pattern existed and dimensions are valid.
     */
    bool doResizePattern(uint patternId, uint newTracks, uint newLines) {
        SavedPattern* sp = findPatternDoc(patternId);
        if (sp is null || !isValidPatternShape(newTracks, newLines)) {
            return false;
        }
        return history_.pushAndExecute(new ResizePatternCommand(*sp, newTracks, newLines), this);
    }

    /**
     * Undoable timeline clip addition.
     *
     * Params:
     *   patternId = Pattern referenced by the clip.
     *   startLine = Song start line index.
     *   lengthLines = Clip duration in lines.
     *   laneY = Vertical track lane index.
     *   isSupertrack = True to preserve persistent lane playback state.
     *
     * Returns:
     *   Assigned clipId on success, or 0 if patternId does not exist.
     */
    uint doAddClip(
        uint patternId,
        long startLine,
        uint lengthLines,
        uint laneY = 0,
        bool isSupertrack = false
    ) {
        if (findPatternDoc(patternId) is null || lengthLines == 0) {
            return 0;
        }
        TimelineClip clip = TimelineClip(
            allocateNextClipId(),
            patternId,
            0,
            startLine,
            lengthLines,
            laneY,
            0,
            false,
            false,
            isSupertrack
        );
        if (!history_.pushAndExecute(new AddClipCommand(clip), this)) {
            return 0;
        }
        return clip.clipId;
    }

    /**
     * Undoable timeline clip position/length move.
     *
     * Params:
     *   clipId = Target clip identifier.
     *   newStartLine = New song start line.
     *   newLengthLines = New clip length in lines.
     *   newLaneY = New lane index.
     *
     * Returns:
     *   True if clipId existed.
     */
    bool doMoveClip(uint clipId, long newStartLine, uint newLengthLines, uint newLaneY) {
        TimelineClip* c = findClipDoc(clipId);
        if (c is null || newLengthLines == 0) {
            return false;
        }
        TimelineClip next = *c;
        next.startLine = newStartLine;
        next.lengthLines = newLengthLines;
        next.laneY = newLaneY;
        return history_.pushAndExecute(new MoveClipCommand(*c, next), this);
    }

    /**
     * Undoable creation of a pattern clone clip referencing the same PatternSnapshot.
     *
     * Params:
     *   sourceClipId = Clip identifier to clone.
     *   targetStartLine = Song line for the new clone.
     *   targetLaneY = Target lane Y index.
     *
     * Returns:
     *   Newly assigned clone clipId, or 0 if sourceClipId was missing.
     */
    uint doCloneClip(uint sourceClipId, long targetStartLine, uint targetLaneY = 0) {
        TimelineClip* src = findClipDoc(sourceClipId);
        if (src is null) {
            return 0;
        }
        TimelineClip cloned = *src;
        cloned.clipId = allocateNextClipId();
        cloned.cloneSourceId = src.clipId;
        cloned.startLine = targetStartLine;
        cloned.laneY = targetLaneY;
        if (!history_.pushAndExecute(new CloneClipCommand(cloned), this)) {
            return 0;
        }
        return cloned.clipId;
    }

    /**
     * Undoable timeline clip removal.
     *
     * Params:
     *   clipId = Clip identifier to delete.
     *
     * Returns:
     *   True if clip existed and was deleted.
     */
    bool doRemoveClip(uint clipId) {
        TimelineClip* c = findClipDoc(clipId);
        if (c is null) {
            return false;
        }
        return history_.pushAndExecute(new RemoveClipCommand(*c), this);
    }

    /**
     * Undoable clip mute/solo/Supertrack flag update.
     *
     * Params:
     *   clipId = Clip identifier.
     *   mute = Clip mute flag.
     *   solo = Clip solo flag.
     *   isSupertrack = Supertrack lane persistence flag.
     *
     * Returns:
     *   True if clip existed.
     */
    bool doSetClipFlags(uint clipId, bool mute, bool solo, bool isSupertrack) {
        TimelineClip* c = findClipDoc(clipId);
        if (c is null) {
            return false;
        }
        TimelineClip next = *c;
        next.mute = mute;
        next.solo = solo;
        next.isSupertrack = isSupertrack;
        return history_.pushAndExecute(new SetClipFlagsCommand(*c, next), this);
    }

    /**
     * Undoable project BPM and ticks-per-line change.
     *
     * Params:
     *   newBpm = Target tempo [20..999].
     *   newTpl = Target ticks per line [1..255].
     *
     * Returns:
     *   True if the tempo is in range and was applied.
     */
    bool doSetTempo(double newBpm, uint newTpl) {
        if (!isValidTempo(newBpm, newTpl)) {
            return false;
        }
        return history_.pushAndExecute(new SetTempoCommand(doc_.bpm, doc_.ticksPerLine, newBpm, newTpl), this);
    }

    /**
     * Undoes the most recent action on UndoHistory.
     *
     * Returns:
     *   True if an action was undone.
     */
    bool undo() {
        return history_ !is null && history_.undo(this);
    }

    /**
     * Redoes the most recently undone action on UndoHistory.
     *
     * Returns:
     *   True if an action was redone.
     */
    bool redo() {
        return history_ !is null && history_.redo(this);
    }

    /**
     * Snapshots the document plus each module's asset extraBlob into a LoadedProject ready for persistence.
     *
     * Parameter values come from the document (the UI-owned source of truth); asset blobs are read only
     * after synchronizeEngine() proves every queued asset swap has been applied.
     *
     * Params:
     *   outDoc = Receives the complete project snapshot.
     *   err = Populated if the Engine could not be synchronized.
     *
     * Returns:
     *   True on success.
     */
    bool snapshotDocumentForSave(out LoadedProject outDoc, out string err) {
        err = null;
        if (!synchronizeEngine()) {
            err = "Audio engine did not acknowledge pending edits before save";
            return false;
        }
        outDoc = cloneLoadedProject(doc_);
        foreach (i, ref sm; doc_.modules) {
            outDoc.modules[i] = snapshotLiveModule(sm);
        }
        return true;
    }

    /**
     * Serializes the active project state into .msv bytes cleanly off-RT.
     *
     * Params:
     *   bytes = Output serialized .msv byte array.
     *   err = Diagnostic error string on failure.
     *
     * Returns:
     *   True on success.
     */
    bool saveProjectToBytes(out ubyte[] bytes, out string err) {
        LoadedProject snap;
        if (!snapshotDocumentForSave(snap, err)) {
            return false;
        }
        return serializeProject(snap, bytes, err);
    }

    /**
     * Saves the active project to path as an .msv file and clears dirty state.
     *
     * Params:
     *   path = Destination filesystem path.
     *   err = Error message populated on failure.
     *
     * Returns:
     *   True if written cleanly.
     */
    bool saveProjectToFile(string path, out string err) {
        LoadedProject snap;
        if (!snapshotDocumentForSave(snap, err)) {
            return false;
        }
        if (!saveProject(snap, path, err)) {
            return false;
        }
        currentPath_ = path;
        dirty_ = false;
        return true;
    }

    /**
     * Writes an autosave snapshot cleanly to autosavePath without overwriting currentPath_.
     *
     * Params:
     *   autosavePath = Recovery file path.
     *   err = Error message populated on write error.
     *
     * Returns:
     *   True on success.
     */
    bool saveAutosave(string autosavePath, out string err) {
        LoadedProject snap;
        if (!snapshotDocumentForSave(snap, err)) {
            return false;
        }
        return saveProject(snap, autosavePath, err);
    }

    /**
     * Parses .msv project bytes and materializes the complete project into this StudioSession.
     *
     * Params:
     *   bytes = Valid .msv byte stream.
     *   err = Error message populated on parse or GraphCompiler error.
     *
     * Returns:
     *   True on clean load and activation.
     */
    bool loadProjectFromBytes(const(ubyte)[] bytes, out string err) {
        LoadedProject parsed;
        if (!loadProject(bytes, parsed, err)) {
            return false;
        }
        return activateLoadedProject(parsed, null, err);
    }

    /**
     * Opens an .msv file from disk and materializes it into this StudioSession.
     *
     * Params:
     *   path = UTF-8 path to .msv file.
     *   err = Error message populated on I/O, parse, or GraphCompiler error.
     *
     * Returns:
     *   True on success.
     */
    bool openProjectFile(string path, out string err) {
        LoadedProject parsed;
        if (!loadProjectFile(path, parsed, err)) {
            return false;
        }
        return activateLoadedProject(parsed, path, err);
    }

    /**
     * Serializes one live module (including extraBlob and optional MetaModule child project) into .msym preset bytes.
     *
     * Params:
     *   modId = Source ModuleId in liveModules_.
     *   presetName = Human-readable preset title.
     *   bytes = Output serialized .msym byte payload.
     *   err = Error string populated if modId is missing.
     *
     * Returns:
     *   True on success.
     */
    bool saveModulePresetToBytes(uint modId, string presetName, out ubyte[] bytes, out string err) {
        const(SavedModule)* sm = findModuleDocConst(modId);
        if (sm is null) {
            err = "Target module id not found in document";
            return false;
        }
        if (!synchronizeEngine()) {
            err = "Audio engine did not acknowledge pending edits before save";
            return false;
        }
        LoadedPreset preset;
        preset.presetName = presetName.length > 0 ? presetName : sm.name;
        preset.mod = snapshotLiveModule(*sm);
        return serializePreset(preset, bytes, err);
    }

    /**
     * Serializes one live module preset cleanly to an .msym file on disk.
     *
     * Params:
     *   modId = Source ModuleId.
     *   presetName = Preset display title.
     *   path = Destination .msym filesystem path.
     *   err = Error string populated on failure.
     *
     * Returns:
     *   True on success.
     */
    bool saveModulePresetToFile(uint modId, string presetName, string path, out string err) {
        const(SavedModule)* sm = findModuleDocConst(modId);
        if (sm is null) {
            err = "Target module id not found in document";
            return false;
        }
        if (!synchronizeEngine()) {
            err = "Audio engine did not acknowledge pending edits before save";
            return false;
        }
        LoadedPreset preset;
        preset.presetName = presetName.length > 0 ? presetName : sm.name;
        preset.mod = snapshotLiveModule(*sm);
        return savePreset(preset, path, err);
    }

    /**
     * Loads an .msym preset byte stream as a new module in the project cleanly through UndoHistory.
     *
     * Params:
     *   bytes = Valid .msym byte stream.
     *   posX = Placement X coordinate.
     *   posY = Placement Y coordinate.
     *   newModId = Receives assigned new ModuleId.
     *   err = Diagnostic error string populated on failure.
     *
     * Returns:
     *   True if loaded and added cleanly.
     */
    bool loadModulePresetFromBytes(
        const(ubyte)[] bytes,
        float posX,
        float posY,
        out uint newModId,
        out string err
    ) {
        newModId = 0;
        LoadedPreset preset;
        if (!loadPreset(bytes, preset, err)) {
            return false;
        }
        if (ModuleRegistry.findByTypeId(preset.mod.typeId) is null) {
            err = "Unknown preset module typeId";
            return false;
        }
        SavedModule copyMod = preset.mod;
        copyMod.id = allocateNextModuleId();
        copyMod.posX = posX;
        copyMod.posY = posY;
        if (preset.presetName.length > 0) {
            copyMod.name = preset.presetName;
        }
        if (!history_.pushAndExecute(new AddModuleCommand(copyMod), this)) {
            err = "Preset module could not be instantiated or wired";
            return false;
        }
        newModId = copyMod.id;
        return true;
    }

    /**
     * Imports an SMF (.mid) byte payload and activates the resulting project cleanly.
     *
     * Params:
     *   bytes = Binary .mid file contents.
     *   err = Diagnostic error message on failure.
     *
     * Returns:
     *   True on valid import.
     */
    bool importMidiBytes(const(ubyte)[] bytes, out string err) {
        LoadedProject parsed;
        if (!importMidiFile(bytes, parsed, err)) {
            return false;
        }
        return activateLoadedProject(parsed, null, err);
    }

    /**
     * Imports a FastTracker II (.xm) byte payload and activates the resulting project cleanly.
     *
     * Params:
     *   bytes = Binary .xm file contents.
     *   err = Diagnostic error message on failure.
     *
     * Returns:
     *   True on valid import.
     */
    bool importXmBytes(const(ubyte)[] bytes, out string err) {
        LoadedProject parsed;
        if (!importXmFile(bytes, parsed, err)) {
            return false;
        }
        return activateLoadedProject(parsed, null, err);
    }

    /**
     * Performs best-effort structural import of a legacy .sunvox stream into the active session.
     *
     * Params:
     *   bytes = Binary .sunvox payload.
     *   report = Output diagnostic summary reporting mapped/skipped legacy modules.
     *   err = Diagnostic error message on header/structural failure.
     *
     * Returns:
     *   True on valid import.
     */
    bool importSunvoxBytes(const(ubyte)[] bytes, out ImportReport report, out string err) {
        LoadedProject parsed;
        if (!importSunvoxFile(bytes, parsed, report, err)) {
            return false;
        }
        return activateLoadedProject(parsed, null, err);
    }

    /**
     * Translates a UI keyboard down/up event through Keymap into StudioActions or live QWERTY piano notes.
     *
     * Params:
     *   ev = Incoming PlatformEvent from AppKit window or headless harness.
     *   activeMod = Destination synth ModuleId for live piano triggering.
     *
     * Returns:
     *   True if handled by a shortcut or QWERTY piano note.
     */
    bool handleKeyEvent(const ref PlatformEvent ev, ModuleId activeMod) {
        if (ev.kind != PlatformEventKind.keyDown && ev.kind != PlatformEventKind.keyUp) {
            return false;
        }
        if (ev.kind == PlatformEventKind.keyDown && !ev.isRepeat) {
            immutable StudioAction act = keymap_.resolveAction(ev.keyCode, ev.modifiers);
            if (act != StudioAction.none) {
                executeStudioAction(act);
                return true;
            }
        }
        if (!activeMod.isValid()) {
            return false;
        }
        ubyte midi = 0;
        if (keymap_.resolveNote(ev.keyCode, currentOctave_, midi)) {
            if (ev.kind == PlatformEventKind.keyDown && !ev.isRepeat) {
                cast(void) sendCommand(EngineCommand.makeLiveNoteOn(activeMod, ev.keyCode, cast(float) midi, 0.85f));
            } else if (ev.kind == PlatformEventKind.keyUp) {
                cast(void) sendCommand(EngineCommand.makeLiveNoteOff(activeMod, ev.keyCode));
            }
            return true;
        }
        return false;
    }

    /**
     * Drains retired plans/patterns/assets from Engine, safely frees removed modules, and reads EngineTelemetry.
     *
     * Params:
     *   tel = Output telemetry snapshot populated when available.
     *
     * Returns:
     *   Total count of retired resources reclaimed during this poll.
     */
    size_t pollRetiredAndTelemetry(out EngineTelemetry tel) {
        immutable size_t freed = reclaimRetired();
        engine_.readTelemetry(tel);
        return freed;
    }

    /**
     * Attaches a prepared SavedModule subproject directly onto a live MetaModule document entry cleanly.
     *
     * Serializes childProj into SavedModule.childProjectMsv and swaps a freshly materialized
     * MetaModuleAsset onto the live MetaModule instance via SwapModuleAsset.
     *
     * Params:
     *   metaModId = Identifier of an active "ctl.metamodule" in this session.
     *   childProj = Complete child LoadedProject document.
     *   inputModId = Child ModuleId receiving forwarded parent audio/events.
     *   macros = Eight macro routing entries mapping macro1..macro8 onto child params.
     *   err = Diagnostic error string populated if validation or child materialization fails.
     *
     * Returns:
     *   True on success.
     */
    bool setMetaModuleChildProject(
        uint metaModId,
        const ref LoadedProject childProj,
        uint inputModId,
        MetaMacroBinding[MetaModuleAsset.NUM_MACROS] macros,
        out string err
    ) {
        err = null;
        SavedModule* sm = findModuleDoc(metaModId);
        auto instPtr = metaModId in liveModules_;
        if (sm is null || instPtr is null || sm.typeId != "ctl.metamodule") {
            err = "Target module is not an active MetaModule";
            return false;
        }
        ubyte[] childBytes;
        if (!serializeProject(childProj, childBytes, err)) {
            return false;
        }

        MetaModuleAsset* asset = MetaModuleAsset.createOffRT(sampleRate_);
        if (asset is null) {
            err = "Out of memory allocating MetaModuleAsset";
            return false;
        }
        ModuleInstance[] childOwned;
        if (!materializeProjectToEngine(childProj, asset.childEngine, sampleRate_, childOwned, err, 1)) {
            MetaModuleAsset.destroyOffRT(asset);
            return false;
        }
        foreach (ref cm; childOwned) {
            asset.adoptModule(cm);
        }
        asset.inputModuleId = ModuleId(inputModId);
        asset.macros = macros;

        if (!sendCommand(EngineCommand.makeSwapModuleAsset(
            ModuleId(metaModId),
            0,
            asset,
            &MetaModuleAsset.destroyErased
        ))) {
            MetaModuleAsset.destroyOffRT(asset);
            err = "Engine command queue unavailable";
            return false;
        }
        sm.hasChildProject = true;
        sm.metaInputModuleId = inputModId;
        sm.metaMacros = macros;
        sm.childProjectMsv = childBytes;
        dirty_ = true;
        return true;
    }

    package bool patchCellDirect(uint patternId, uint track, uint line, NoteCell cell) {
        SavedPattern* sp = findPatternDoc(patternId);
        if (sp is null || track >= sp.tracks || line >= sp.lines) {
            return false;
        }
        immutable size_t idx = cast(size_t) line * cast(size_t) sp.tracks + cast(size_t) track;
        if (idx >= sp.cells.length) {
            sp.cells.length = cast(size_t) sp.tracks * cast(size_t) sp.lines;
        }
        if (!sendCommand(EngineCommand.makePatchCell(patternId, track, line, cell))) {
            return false;
        }
        sp.cells[idx] = cell;
        dirty_ = true;
        return true;
    }

    package bool resizePatternDirect(uint patternId, uint newTracks, uint newLines, const(NoteCell)[] exactCells) {
        SavedPattern* sp = findPatternDoc(patternId);
        if (sp is null || !isValidPatternShape(newTracks, newLines)) {
            return false;
        }
        NoteCell[] nextCells = new NoteCell[cast(size_t) newTracks * cast(size_t) newLines];
        if (exactCells !is null) {
            immutable size_t copyN = exactCells.length < nextCells.length ? exactCells.length : nextCells.length;
            nextCells[0 .. copyN] = exactCells[0 .. copyN];
        } else {
            immutable uint copyTr = sp.tracks < newTracks ? sp.tracks : newTracks;
            immutable uint copyLn = sp.lines < newLines ? sp.lines : newLines;
            foreach (ln; 0 .. copyLn) {
                foreach (tr; 0 .. copyTr) {
                    immutable size_t srcIdx = cast(size_t) ln * sp.tracks + tr;
                    if (srcIdx < sp.cells.length) {
                        nextCells[cast(size_t) ln * newTracks + tr] = sp.cells[srcIdx];
                    }
                }
            }
        }
        SavedPattern next = *sp;
        next.tracks = newTracks;
        next.lines = newLines;
        next.cells = nextCells;
        if (!pushPatternSnapshotDirect(next, false)) {
            return false;
        }
        *sp = next;
        dirty_ = true;
        return true;
    }

    package bool addModuleDirect(const ref SavedModule sm) {
        if (findModuleDoc(sm.id) !is null) {
            return false;
        }
        SavedModule copyMod = cloneSavedModule(sm);
        if (!instantiateSavedModule(copyMod)) {
            return false;
        }
        doc_.modules ~= copyMod;
        if (!compileAndSwapGraph(false)) {
            doc_.modules.length = doc_.modules.length - 1;
            discardUnpublishedModule(copyMod.id);
            return false;
        }
        dirty_ = true;
        return true;
    }

    package bool removeModuleDirect(uint modId) {
        size_t foundIdx = size_t.max;
        foreach (i, ref sm; doc_.modules) {
            if (sm.id == modId) {
                foundIdx = i;
                break;
            }
        }
        if (foundIdx == size_t.max) {
            return false;
        }
        SavedModule[] prevModules = doc_.modules;
        SavedWire[] prevWires = doc_.wires;
        GraphPlan* guard = activePlan_;

        doc_.modules = doc_.modules[0 .. foundIdx] ~ doc_.modules[foundIdx + 1 .. $];
        SavedWire[] keptWires;
        foreach (ref w; prevWires) {
            if (w.srcMod != modId && w.dstMod != modId) {
                keptWires ~= w;
            }
        }
        doc_.wires = keptWires;
        if (!compileAndSwapGraph(false)) {
            doc_.modules = prevModules;
            doc_.wires = prevWires;
            return false;
        }

        if (auto pInst = modId in liveModules_) {
            retiredModules_ ~= PendingModuleRetire(*pInst, guard);
            liveModules_.remove(modId);
        }
        dirty_ = true;
        return true;
    }

    package bool restoreModuleWithWiresDirect(const ref SavedModule sm, const(SavedWire)[] wires) {
        SavedModule[] prevModules = doc_.modules.dup;
        SavedWire[] prevWires = doc_.wires.dup;
        bool instantiated = false;
        SavedModule copyMod = cloneSavedModule(sm);
        if (findModuleDoc(copyMod.id) is null) {
            if (!instantiateSavedModule(copyMod)) {
                return false;
            }
            instantiated = true;
            doc_.modules ~= copyMod;
        }
        foreach (ref w; wires) {
            if (!hasWireDoc(w)) {
                doc_.wires ~= w;
            }
        }
        if (!compileAndSwapGraph(false)) {
            doc_.modules = prevModules;
            doc_.wires = prevWires;
            if (instantiated) {
                discardUnpublishedModule(copyMod.id);
            }
            return false;
        }
        dirty_ = true;
        return true;
    }

    package bool connectWireDirect(SavedWire w) {
        if (hasWireDoc(w)) {
            return false;
        }
        doc_.wires ~= w;
        if (!compileAndSwapGraph(false)) {
            doc_.wires.length = doc_.wires.length - 1;
            return false;
        }
        dirty_ = true;
        return true;
    }

    package bool disconnectWireDirect(SavedWire w) {
        SavedWire[] next;
        bool removed = false;
        foreach (ref existing; doc_.wires) {
            if (existing.srcMod == w.srcMod && existing.srcPort == w.srcPort
                    && existing.dstMod == w.dstMod && existing.dstPort == w.dstPort) {
                removed = true;
                continue;
            }
            next ~= existing;
        }
        if (!removed) {
            return false;
        }
        SavedWire[] prev = doc_.wires;
        doc_.wires = next;
        if (!compileAndSwapGraph(false)) {
            doc_.wires = prev;
            return false;
        }
        dirty_ = true;
        return true;
    }

    package bool setParamDirect(uint modId, uint paramIdx, float val) {
        SavedModule* sm = findModuleDoc(modId);
        auto instPtr = modId in liveModules_;
        if (sm is null || instPtr is null || paramIdx >= instPtr.desc.params.length || !isFinite(val)) {
            return false;
        }
        if (!sendCommand(EngineCommand.makeSetModuleParam(ModuleId(modId), paramIdx, val, false))) {
            return false;
        }
        if (sm.paramValues.length < instPtr.desc.params.length) {
            immutable size_t oldLen = sm.paramValues.length;
            sm.paramValues.length = instPtr.desc.params.length;
            foreach (pi; oldLen .. sm.paramValues.length) {
                sm.paramValues[pi] = instPtr.desc.params[pi].defaultVal;
            }
        }
        sm.paramValues[paramIdx] = val;
        dirty_ = true;
        return true;
    }

    package bool setModulePositionDirect(uint modId, float x, float y) {
        SavedModule* sm = findModuleDoc(modId);
        if (sm is null || !isFinite(x) || !isFinite(y)) {
            return false;
        }
        sm.posX = x;
        sm.posY = y;
        dirty_ = true;
        return true;
    }

    package bool addClipDirect(TimelineClip clip) {
        if (findClipDoc(clip.clipId) !is null || findPatternDoc(clip.patternId) is null) {
            return false;
        }
        doc_.clips ~= clip;
        if (!pushTimelineSnapshot(false)) {
            doc_.clips.length = doc_.clips.length - 1;
            return false;
        }
        dirty_ = true;
        return true;
    }

    package bool updateClipDirect(TimelineClip clip) {
        foreach (ref c; doc_.clips) {
            if (c.clipId == clip.clipId) {
                immutable TimelineClip prev = c;
                c = clip;
                if (!pushTimelineSnapshot(false)) {
                    c = prev;
                    return false;
                }
                dirty_ = true;
                return true;
            }
        }
        return false;
    }

    package bool removeClipDirect(uint clipId) {
        TimelineClip[] next;
        bool removed = false;
        foreach (ref c; doc_.clips) {
            if (c.clipId == clipId) {
                removed = true;
                continue;
            }
            next ~= c;
        }
        if (!removed) {
            return false;
        }
        TimelineClip[] prev = doc_.clips;
        doc_.clips = next;
        if (!pushTimelineSnapshot(false)) {
            doc_.clips = prev;
            return false;
        }
        dirty_ = true;
        return true;
    }

    package bool setTempoDirect(double bpmVal, uint tplVal) {
        if (!isValidTempo(bpmVal, tplVal)) {
            return false;
        }
        if (!sendCommand(EngineCommand.makeSetBpm(bpmVal))) {
            return false;
        }
        if (!sendCommand(EngineCommand.makeSetTpl(tplVal))) {
            cast(void) sendCommand(EngineCommand.makeSetBpm(doc_.bpm));
            return false;
        }
        doc_.bpm = bpmVal;
        doc_.ticksPerLine = tplVal;
        dirty_ = true;
        return true;
    }

    private void discardUnpublishedModule(uint modId) {
        if (auto pInst = modId in liveModules_) {
            pInst.destroyOffRT();
            liveModules_.remove(modId);
        }
    }

    private void executeStudioAction(StudioAction act) {
        switch (act) {
            case StudioAction.playToggle:
                EngineTelemetry tel;
                immutable bool playingNow = engine_.readTelemetry(tel) && tel.playing;
                cast(void) sendCommand(playingNow ? EngineCommand.makeStop() : EngineCommand.makePlay());
                break;
            case StudioAction.stop:
                cast(void) sendCommand(EngineCommand.makeStop());
                cast(void) sendCommand(EngineCommand.makeSeekLine(0));
                break;
            case StudioAction.recordToggle:
                recording_ = !recording_;
                break;
            case StudioAction.octaveUp:
                if (currentOctave_ < 9) currentOctave_++;
                break;
            case StudioAction.octaveDown:
                if (currentOctave_ > -1) currentOctave_--;
                break;
            case StudioAction.undo:
                undo();
                break;
            case StudioAction.redo:
                redo();
                break;
            case StudioAction.panic:
                cast(void) sendCommand(EngineCommand.makeAllNotesOff());
                break;
            default:
                break;
        }
    }

    private void clearLiveAndEngine() {
        engine_.releaseAllOwnedResources();
        activePlan_ = null;
        foreach (ref inst; liveModules_) {
            inst.destroyOffRT();
        }
        liveModules_.clear();
        foreach (ref rm; retiredModules_) {
            rm.inst.destroyOffRT();
        }
        retiredModules_.length = 0;
    }

    private bool audioThreadActive() {
        return audioDriver_ !is null && audioDriver_.isRunning();
    }

    private bool suspendAudio() {
        if (!audioThreadActive()) {
            return false;
        }
        audioDriver_.stop();
        return true;
    }

    private void resumeAudio(bool wasRunning) {
        if (wasRunning && audioDriver_ !is null) {
            cast(void) audioDriver_.start();
        }
    }

    private bool sendCommand(EngineCommand cmd) {
        if (engine_.pushCommand(cmd)) {
            return true;
        }
        if (!audioThreadActive()) {
            engine_.applyPendingCommandsOffRT();
            reclaimRetired();
            return engine_.pushCommand(cmd);
        }
        immutable MonoTime deadline = MonoTime.currTime + engineSyncTimeout_;
        while (!engine_.pushCommand(cmd)) {
            if (MonoTime.currTime > deadline || !audioThreadActive()) {
                return engine_.pushCommand(cmd);
            }
            Thread.sleep(dur!"usecs"(250));
        }
        return true;
    }

    private size_t reclaimRetired() {
        size_t freed = 0;
        RetiredResource item;
        while (engine_.tryPopRetired(item)) {
            if (item.kind == RetiredKind.graphPlan) {
                foreach (ref rm; retiredModules_) {
                    if (rm.guardPlan is item.ptr) {
                        rm.guardPlan = null;
                    }
                }
            }
            item.reclaimOffRT();
            freed++;
        }
        size_t kept = 0;
        foreach (i; 0 .. retiredModules_.length) {
            if (retiredModules_[i].guardPlan is null) {
                retiredModules_[i].inst.destroyOffRT();
                freed++;
            } else {
                retiredModules_[kept++] = retiredModules_[i];
            }
        }
        retiredModules_.length = kept;
        return freed;
    }

    private bool activateLoadedProject(const ref LoadedProject parsed, string path, out string err) {
        Engine probe;
        if (!probe.tryInit(sampleRate_)) {
            err = "Out of memory creating Engine for loaded project";
            return false;
        }
        ModuleInstance[] probeOwned;
        immutable bool probeOk = materializeProjectToEngine(parsed, probe, sampleRate_, probeOwned, err);
        probe.releaseAllOwnedResources();
        foreach (ref s; probeOwned) {
            s.destroyOffRT();
        }
        if (!probeOk) {
            return false;
        }

        immutable bool wasRunning = suspendAudio();
        scope (exit) resumeAudio(wasRunning);

        clearLiveAndEngine();
        if (!engine_.tryInit(sampleRate_)) {
            err = "Engine re-initialization failed";
            initialized_ = false;
            return false;
        }

        doc_ = cloneLoadedProject(parsed);
        ModuleInstance[] spawned;
        if (!materializeProjectToEngine(doc_, engine_, sampleRate_, spawned, err)) {
            resetToEmptyProjectSuspended(true);
            return false;
        }
        foreach (i, ref sm; doc_.modules) {
            liveModules_[sm.id] = spawned[i];
        }
        if (!compileAndSwapGraph(true)) {
            err = "GraphCompiler rejected loaded project wiring";
            resetToEmptyProjectSuspended(true);
            return false;
        }

        engine_.reset();
        engine_.setTempo(doc_.bpm, doc_.ticksPerLine);
        engine_.seekLine(0);

        uint maxMId = 1;
        foreach (ref sm; doc_.modules) {
            if (sm.id >= maxMId) maxMId = sm.id + 1;
        }
        uint maxCId = 1;
        foreach (ref c; doc_.clips) {
            if (c.clipId >= maxCId) maxCId = c.clipId + 1;
        }
        nextModuleId_ = maxMId;
        nextClipId_ = maxCId;
        currentPatternId_ = doc_.patterns.length > 0 ? doc_.patterns[0].patternId : 1;
        currentPath_ = path;
        dirty_ = false;
        if (history_ !is null) history_.clear();
        return true;
    }

    private bool instantiateSavedModule(const ref SavedModule sm) {
        ModuleInstance inst;
        if (!ModuleRegistry.createOffRT(sm.typeId, ModuleId(sm.id), sampleRate_, inst)) {
            return false;
        }
        foreach (pi, val; sm.paramValues) {
            if (inst.desc.vtable !is null && inst.desc.vtable.setParam !is null) {
                inst.desc.vtable.setParam(inst.state, cast(uint) pi, val, sampleRate_, true);
            }
        }
        if (sm.extraBlob.length > 0 && inst.desc.vtable !is null && inst.desc.vtable.deserializeExtra !is null) {
            inst.desc.vtable.deserializeExtra(inst.state, sm.extraBlob, sampleRate_);
        }
        if (sm.typeId == "ctl.metamodule" && sm.hasChildProject) {
            MetaModuleAsset* asset = MetaModuleAsset.createOffRT(sampleRate_);
            if (asset !is null) {
                if (sm.childProjectMsv.length > 0) {
                    LoadedProject childProj;
                    string cErr;
                    if (loadProject(sm.childProjectMsv, childProj, cErr, 1)) {
                        ModuleInstance[] cOwned;
                        if (materializeProjectToEngine(childProj, asset.childEngine, sampleRate_, cOwned, cErr, 1)) {
                            foreach (ref cm; cOwned) {
                                asset.adoptModule(cm);
                            }
                        }
                    }
                }
                asset.inputModuleId = ModuleId(sm.metaInputModuleId);
                asset.macros = sm.metaMacros;
                void* prev = null;
                inst.desc.vtable.swapAsset(inst.state, 0, asset, prev);
                if (prev !is null) {
                    MetaModuleAsset.destroyErased(prev);
                }
            }
        }
        liveModules_[sm.id] = inst;
        return true;
    }

    private SavedModule snapshotLiveModule(const ref SavedModule base) {
        SavedModule copyMod = cloneSavedModule(base);
        auto instPtr = base.id in liveModules_;
        if (instPtr is null || instPtr.state is null || instPtr.desc is null) {
            return copyMod;
        }
        if (copyMod.paramValues.length < instPtr.desc.params.length) {
            immutable size_t oldLen = copyMod.paramValues.length;
            copyMod.paramValues.length = instPtr.desc.params.length;
            foreach (pi; oldLen .. copyMod.paramValues.length) {
                copyMod.paramValues[pi] = instPtr.desc.params[pi].defaultVal;
            }
        }
        immutable bool extraLivesInDocument = base.typeId == "ctl.metamodule";
        if (!extraLivesInDocument && instPtr.desc.vtable !is null && instPtr.desc.vtable.serializeExtra !is null) {
            ubyte[] blob;
            if (instPtr.desc.vtable.serializeExtra(instPtr.state, blob)) {
                copyMod.extraBlob = blob;
            }
        }
        return copyMod;
    }

    private bool testGraphWireValid(SavedWire candidate) {
        NodeSpec[] nodes;
        nodes.reserve(doc_.modules.length);
        foreach (ref sm; doc_.modules) {
            auto ptr = sm.id in liveModules_;
            if (ptr !is null && ptr.state !is null) {
                nodes ~= NodeSpec.fromInstance(*ptr, sm.muted, sm.bypassed);
            }
        }
        WireSpec[] wires = new WireSpec[doc_.wires.length + 1];
        foreach (i, ref sw; doc_.wires) {
            wires[i] = WireSpec(ModuleId(sw.srcMod), sw.srcPort, ModuleId(sw.dstMod), sw.dstPort, sw.gain);
        }
        wires[$ - 1] = WireSpec(
            ModuleId(candidate.srcMod),
            candidate.srcPort,
            ModuleId(candidate.dstMod),
            candidate.dstPort,
            candidate.gain
        );
        GraphPlan* tmpPlan = null;
        GraphCompileError err;
        immutable bool ok = GraphCompiler.compile(nodes, wires, tmpPlan, err);
        if (tmpPlan !is null) {
            GraphPlan.destroyOffRT(tmpPlan);
        }
        return ok;
    }

    private SavedModule* findModuleDoc(uint modId) {
        foreach (ref sm; doc_.modules) {
            if (sm.id == modId) return &sm;
        }
        return null;
    }

    private const(SavedModule)* findModuleDocConst(uint modId) const {
        foreach (ref sm; doc_.modules) {
            if (sm.id == modId) return &sm;
        }
        return null;
    }

    private SavedPattern* findPatternDoc(uint patId) {
        foreach (ref sp; doc_.patterns) {
            if (sp.patternId == patId) return &sp;
        }
        return null;
    }

    private TimelineClip* findClipDoc(uint clipId) {
        foreach (ref c; doc_.clips) {
            if (c.clipId == clipId) return &c;
        }
        return null;
    }

    private static SavedModule cloneSavedModule(const ref SavedModule sm) @safe nothrow {
        SavedModule copyMod;
        copyMod.id = sm.id;
        copyMod.typeId = sm.typeId;
        copyMod.name = sm.name;
        copyMod.posX = sm.posX;
        copyMod.posY = sm.posY;
        copyMod.muted = sm.muted;
        copyMod.bypassed = sm.bypassed;
        copyMod.paramValues = sm.paramValues.dup;
        copyMod.extraBlob = sm.extraBlob.dup;
        copyMod.hasChildProject = sm.hasChildProject;
        copyMod.metaInputModuleId = sm.metaInputModuleId;
        copyMod.metaMacros = sm.metaMacros;
        copyMod.childProjectMsv = sm.childProjectMsv.dup;
        return copyMod;
    }

    private static SavedPattern cloneSavedPattern(const ref SavedPattern sp) @safe nothrow {
        SavedPattern copyPat;
        copyPat.patternId = sp.patternId;
        copyPat.tracks = sp.tracks;
        copyPat.lines = sp.lines;
        copyPat.name = sp.name;
        copyPat.cells = sp.cells.dup;
        return copyPat;
    }

    private static LoadedProject cloneLoadedProject(const ref LoadedProject src) @safe nothrow {
        LoadedProject dst;
        dst.formatVersion = src.formatVersion;
        dst.title = src.title;
        dst.author = src.author;
        dst.bpm = src.bpm;
        dst.ticksPerLine = src.ticksPerLine;
        dst.loopStartLine = src.loopStartLine;
        dst.loopEndLine = src.loopEndLine;
        dst.modules = new SavedModule[src.modules.length];
        foreach (i, ref sm; src.modules) {
            dst.modules[i] = cloneSavedModule(sm);
        }
        dst.wires = src.wires.dup;
        dst.patterns = new SavedPattern[src.patterns.length];
        foreach (i, ref sp; src.patterns) {
            dst.patterns[i] = cloneSavedPattern(sp);
        }
        dst.clips = src.clips.dup;
        return dst;
    }

    private bool hasWireDoc(SavedWire w) const {
        foreach (ref existing; doc_.wires) {
            if (existing.srcMod == w.srcMod && existing.srcPort == w.srcPort
                    && existing.dstMod == w.dstMod && existing.dstPort == w.dstPort) {
                return true;
            }
        }
        return false;
    }
}
