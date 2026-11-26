/**
 * File:         source/app/history.d
 * Module:       app.history
 * Phase:        Phase 6.3 — Command-Pattern Undo/Redo Stack
 *
 * Purpose:
 *   Records reversible user actions (pattern edits, module add/remove, wire connect/disconnect, parameter tweaks with drag coalescing, timeline edits, and tempo edits) cleanly bridging StudioSession.
 *
 * Real-Time & Safety Contract:
 *   Executes strictly on UI/main thread; reversible actions dispatch RT mutations lock-free through StudioSession -> SpscRing!EngineCommand.
 *
 * Dependencies:
 *   Internal: app.{music_theory,session}, foundation.types, io.project_format, sequencer.{note,timeline}
 *   External: core.time (Duration, MonoTime)
 *
 * Planned API (Types, Functions & Hooks):
 *   - interface IUndoCommand
 *   - class UndoHistory : pushAndExecute(), pushAndExecuteAt(), beginGroup(), endGroup(), inGroup(), setCoalesceWindow(), undo(), redo(), canUndo(), canRedo(), clear()
 *   - class CompoundCommand (atomic group) / class DelegateCommand (delegate-defined reversible step)
 *   - Reversible command classes: PatchCellCommand, ResizePatternCommand, AddModuleCommand, RemoveModuleCommand, ConnectWireCommand, DisconnectWireCommand, SetParamCommand, MoveModulePositionCommand, AddClipCommand, MoveClipCommand, CloneClipCommand, RemoveClipCommand, SetClipFlagsCommand, SetTempoCommand, SetTimeSignatureCommand, SetKeyCommand, ReplaceDocumentCommand
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module app.history;

import core.time : dur, Duration, MonoTime;

import app.music_theory : MusicalKey;
import app.session : StudioSession;
import io.project_format : LoadedProject, SavedModule, SavedPattern, SavedWire;
import sequencer.note : NoteCell;
import sequencer.timeline : TimelineClip;

/**
 * Reversible command-pattern interface executed and undone against StudioSession.
 */
interface IUndoCommand {
    /**
     * Executes or re-applies the mutation onto session and updates RT state.
     *
     * Params:
     *   session = Active StudioSession owning document and Engine.
     *
     * Returns:
     *   True if the document and Engine were both updated; false leaves both unchanged.
     */
    bool execute(StudioSession session);

    /**
     * Reverts this command cleanly on session and updates RT state.
     *
     * Params:
     *   session = Active StudioSession owning document and Engine.
     *
     * Returns:
     *   True if the document and Engine were both reverted; false leaves both unchanged.
     */
    bool undo(StudioSession session);

    /**
     * Returns concise human-readable action description for UI menus and Edit > Undo labels.
     *
     * Returns:
     *   Command label text.
     */
    string label() const;

    /**
     * Reports whether newer consecutive commands of matching target can coalesce into this command.
     *
     * Params:
     *   next = Newly pushed consecutive command candidate.
     *
     * Returns:
     *   True if next can merge into this entry cleanly.
     */
    bool canMergeWith(IUndoCommand next) const;

    /**
     * Incorporates next's updated target state into this entry while preserving original before-state.
     *
     * Params:
     *   next = Newer consecutive command merged into this entry.
     */
    void mergeFrom(IUndoCommand next);
}

/**
 * Bounded command-pattern undo/redo history stack with drag coalescing support.
 */
class UndoHistory {
    private IUndoCommand[] undoStack_;
    private IUndoCommand[] redoStack_;
    private size_t maxDepth_ = 512;
    private uint coalesceEpoch_ = 1;
    private Duration coalesceWindow_ = dur!"msecs"(500);
    private MonoTime lastPushTime_;
    private bool hasLastPush_ = false;
    private uint groupDepth_ = 0;
    private IUndoCommand[] groupChildren_;
    private string groupLabel_;
    private bool groupFailed_ = false;

    /**
     * Constructs an UndoHistory capped at maxDepth reversible entries.
     *
     * Params:
     *   maxDepth = Maximum retained undo history entries.
     */
    this(size_t maxDepth = 512) {
        maxDepth_ = maxDepth > 0 ? maxDepth : 512;
    }

    /**
     * Executes cmd against session and records it (or coalesces it) only if execution succeeded.
     *
     * Coalescing requires matching command targets, the same epoch, and at most coalesceWindow()
     * elapsed since the previous coalescable push, so separate gestures never merge silently.
     *
     * Params:
     *   cmd = Command to execute immediately.
     *   session = Active StudioSession.
     *
     * Returns:
     *   True if cmd executed; false if it was rejected (nothing is recorded and redo history is kept).
     */
    bool pushAndExecute(IUndoCommand cmd, StudioSession session) {
        return pushAndExecuteAt(cmd, session, MonoTime.currTime);
    }

    /**
     * Same as pushAndExecute() with an explicit timestamp, used for deterministic coalescing tests.
     *
     * Params:
     *   cmd = Command to execute immediately.
     *   session = Active StudioSession.
     *   now = Monotonic timestamp of this push.
     *
     * Returns:
     *   True if cmd executed; false if it was rejected.
     */
    bool pushAndExecuteAt(IUndoCommand cmd, StudioSession session, MonoTime now) {
        if (cmd is null || session is null) {
            return false;
        }
        if (groupDepth_ > 0) {
            if (groupFailed_ || !cmd.execute(session)) {
                groupFailed_ = true;
                return false;
            }
            groupChildren_ ~= cmd;
            return true;
        }
        if (!cmd.execute(session)) {
            return false;
        }
        redoStack_.length = 0;

        immutable bool withinWindow = hasLastPush_ && (now - lastPushTime_) <= coalesceWindow_;
        lastPushTime_ = now;
        hasLastPush_ = true;
        if (withinWindow && undoStack_.length > 0 && undoStack_[$ - 1].canMergeWith(cmd)) {
            undoStack_[$ - 1].mergeFrom(cmd);
            return true;
        }
        undoStack_ ~= cmd;
        if (undoStack_.length > maxDepth_) {
            undoStack_ = undoStack_[undoStack_.length - maxDepth_ .. $];
        }
        return true;
    }

    /**
     * Reverts the most recent executed command and moves it onto the redo stack.
     *
     * Params:
     *   session = Active StudioSession.
     *
     * Returns:
     *   True if a command was undone; false if the stack is empty or the revert was rejected (stack unchanged).
     */
    bool undo(StudioSession session) {
        if (undoStack_.length == 0 || session is null) {
            return false;
        }
        auto cmd = undoStack_[$ - 1];
        if (!cmd.undo(session)) {
            return false;
        }
        undoStack_.length = undoStack_.length - 1;
        redoStack_ ~= cmd;
        breakCoalesce();
        return true;
    }

    /**
     * Re-applies the most recently undone command and moves it back onto the undo stack.
     *
     * Params:
     *   session = Active StudioSession.
     *
     * Returns:
     *   True if a command was redone; false if the stack is empty or re-execution was rejected (stack unchanged).
     */
    bool redo(StudioSession session) {
        if (redoStack_.length == 0 || session is null) {
            return false;
        }
        auto cmd = redoStack_[$ - 1];
        if (!cmd.execute(session)) {
            return false;
        }
        redoStack_.length = redoStack_.length - 1;
        undoStack_ ~= cmd;
        breakCoalesce();
        return true;
    }

    /**
     * Opens (or nests into) an undo group: commands pushed until the matching endGroup() execute immediately and
     * are recorded as a single atomic step. Nested groups flatten into the outermost one.
     *
     * Params:
     *   label = Undo menu label for the group (the outermost label wins).
     */
    void beginGroup(string label) {
        if (groupDepth_ == 0) {
            groupChildren_ = null;
            groupLabel_ = label;
            groupFailed_ = false;
        }
        groupDepth_++;
    }

    /**
     * Closes the current group level. At the outermost level, records the group as one CompoundCommand, or, if
     * any child failed, undoes every executed child in reverse order and records nothing.
     *
     * Params:
     *   session = Active StudioSession.
     *
     * Returns:
     *   True if the group was recorded (or is still open at an outer level); false if it was rolled back or was
     *   empty.
     */
    bool endGroup(StudioSession session) {
        if (groupDepth_ == 0) {
            return false;
        }
        groupDepth_--;
        if (groupDepth_ > 0) {
            return !groupFailed_;
        }
        IUndoCommand[] children = groupChildren_;
        groupChildren_ = null;
        if (groupFailed_) {
            groupFailed_ = false;
            foreach_reverse (c; children) {
                c.undo(session);
            }
            return false;
        }
        if (children.length == 0) {
            return false;
        }
        redoStack_.length = 0;
        undoStack_ ~= new CompoundCommand(groupLabel_, children);
        if (undoStack_.length > maxDepth_) {
            undoStack_ = undoStack_[undoStack_.length - maxDepth_ .. $];
        }
        breakCoalesce();
        return true;
    }

    /**
     * Reports whether an undo group is open.
     *
     * Returns:
     *   True between beginGroup() and the outermost endGroup().
     */
    bool inGroup() const {
        return groupDepth_ > 0;
    }

    /**
     * Sets the maximum gap between consecutive coalescable pushes that may still merge.
     *
     * Params:
     *   window = Non-negative merge window (default 500 ms).
     */
    void setCoalesceWindow(Duration window) {
        coalesceWindow_ = window < Duration.zero ? Duration.zero : window;
    }

    /**
     * Returns the active coalescing merge window.
     *
     * Returns:
     *   Maximum gap between merged pushes.
     */
    Duration coalesceWindow() const {
        return coalesceWindow_;
    }

    /**
     * Breaks consecutive slider/drag coalescing after pointer release or commit.
     */
    void breakCoalesce() {
        coalesceEpoch_++;
        hasLastPush_ = false;
    }

    /**
     * Returns current coalescing epoch token stamped into coalescable commands.
     *
     * Returns:
     *   Active integer epoch token.
     */
    uint currentEpoch() const {
        return coalesceEpoch_;
    }

    /**
     * Reports whether at least one undo entry is available.
     *
     * Returns:
     *   True if can undo.
     */
    bool canUndo() const {
        return undoStack_.length > 0;
    }

    /**
     * Reports whether at least one redo entry is available.
     *
     * Returns:
     *   True if can redo.
     */
    bool canRedo() const {
        return redoStack_.length > 0;
    }

    /**
     * Returns number of entries on the undo stack.
     *
     * Returns:
     *   Undo depth count.
     */
    size_t undoCount() const {
        return undoStack_.length;
    }

    /**
     * Returns number of entries on the redo stack.
     *
     * Returns:
     *   Redo depth count.
     */
    size_t redoCount() const {
        return redoStack_.length;
    }

    /**
     * Returns label of top undo command, or empty string if empty.
     *
     * Returns:
     *   Top undo command label.
     */
    string nextUndoLabel() const {
        return undoStack_.length > 0 ? undoStack_[$ - 1].label() : "";
    }

    /**
     * Returns label of top redo command, or empty string if empty.
     *
     * Returns:
     *   Top redo command label.
     */
    string nextRedoLabel() const {
        return redoStack_.length > 0 ? redoStack_[$ - 1].label() : "";
    }

    /**
     * Clears both undo and redo history stacks completely.
     */
    void clear() {
        undoStack_.length = 0;
        redoStack_.length = 0;
        breakCoalesce();
    }
}

/**
 * Reversible atomic cell edit command on a tracker pattern.
 */
class PatchCellCommand : IUndoCommand {
    private uint patternId_;
    private uint track_;
    private uint line_;
    private NoteCell before_;
    private NoteCell after_;

    /**
     * Constructs a PatchCellCommand recording before and after NoteCells.
     *
     * Params:
     *   patternId = Target pattern identifier.
     *   track = Zero-based track index.
     *   line = Zero-based row index.
     *   before = Prior NoteCell value.
     *   after = New NoteCell value.
     */
    this(uint patternId, uint track, uint line, NoteCell before, NoteCell after) {
        patternId_ = patternId;
        track_ = track;
        line_ = line;
        before_ = before;
        after_ = after;
    }

    override bool execute(StudioSession session) {
        return session.patchCellDirect(patternId_, track_, line_, after_);
    }

    override bool undo(StudioSession session) {
        return session.patchCellDirect(patternId_, track_, line_, before_);
    }

    override string label() const {
        return "Edit Pattern Cell";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible Copy-on-Write pattern dimension resize command preserving displaced cell history.
 */
class ResizePatternCommand : IUndoCommand {
    private uint patternId_;
    private uint oldTracks_;
    private uint oldLines_;
    private NoteCell[] oldCells_;
    private uint newTracks_;
    private uint newLines_;

    /**
     * Constructs a ResizePatternCommand saving prior pattern shape and contents.
     *
     * Params:
     *   prev = Prior SavedPattern snapshot.
     *   newTracks = Requested column count.
     *   newLines = Requested row count.
     */
    this(const ref SavedPattern prev, uint newTracks, uint newLines) {
        patternId_ = prev.patternId;
        oldTracks_ = prev.tracks;
        oldLines_ = prev.lines;
        oldCells_ = prev.cells.dup;
        newTracks_ = newTracks;
        newLines_ = newLines;
    }

    override bool execute(StudioSession session) {
        return session.resizePatternDirect(patternId_, newTracks_, newLines_, null);
    }

    override bool undo(StudioSession session) {
        return session.resizePatternDirect(patternId_, oldTracks_, oldLines_, oldCells_);
    }

    override string label() const {
        return "Resize Pattern";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible module creation command adding a Registered module to document and RT GraphPlan.
 */
class AddModuleCommand : IUndoCommand {
    private SavedModule mod_;

    /**
     * Constructs an AddModuleCommand from a complete SavedModule specification.
     *
     * Params:
     *   mod = SavedModule specification with assigned unique id and typeId.
     */
    this(SavedModule mod) {
        mod_ = mod;
    }

    override bool execute(StudioSession session) {
        return session.addModuleDirect(mod_);
    }

    override bool undo(StudioSession session) {
        return session.removeModuleDirect(mod_.id);
    }

    override string label() const {
        return "Add Module";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible module removal command capturing module state and incident wires prior to deletion.
 */
class RemoveModuleCommand : IUndoCommand {
    private SavedModule modSnapshot_;
    private SavedWire[] removedWires_;

    /**
     * Constructs a RemoveModuleCommand archiving full module state and attached wires.
     *
     * Params:
     *   snap = Deep SavedModule state snapshot captured prior to removal.
     *   incidentWires = Wires referencing snap.id that will be removed alongside the node.
     */
    this(SavedModule snap, SavedWire[] incidentWires) {
        modSnapshot_ = snap;
        removedWires_ = incidentWires.dup;
    }

    override bool execute(StudioSession session) {
        return session.removeModuleDirect(modSnapshot_.id);
    }

    override bool undo(StudioSession session) {
        return session.restoreModuleWithWiresDirect(modSnapshot_, removedWires_);
    }

    override string label() const {
        return "Remove Module";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible patchbay wire connection command.
 */
class ConnectWireCommand : IUndoCommand {
    private SavedWire wire_;

    /**
     * Constructs a ConnectWireCommand for wire.
     *
     * Params:
     *   wire = Wire endpoints and initial gain.
     */
    this(SavedWire wire) {
        wire_ = wire;
    }

    override bool execute(StudioSession session) {
        return session.connectWireDirect(wire_);
    }

    override bool undo(StudioSession session) {
        return session.disconnectWireDirect(wire_);
    }

    override string label() const {
        return "Connect Wire";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible patchbay wire disconnection command.
 */
class DisconnectWireCommand : IUndoCommand {
    private SavedWire wire_;

    /**
     * Constructs a DisconnectWireCommand for wire.
     *
     * Params:
     *   wire = Wire endpoints and archived gain.
     */
    this(SavedWire wire) {
        wire_ = wire;
    }

    override bool execute(StudioSession session) {
        return session.disconnectWireDirect(wire_);
    }

    override bool undo(StudioSession session) {
        return session.connectWireDirect(wire_);
    }

    override string label() const {
        return "Disconnect Wire";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Coalescable continuous module parameter edit command preserving initial value across knob drags.
 */
class SetParamCommand : IUndoCommand {
    private uint modId_;
    private uint paramIdx_;
    private float oldVal_;
    private float newVal_;
    private uint epoch_;

    /**
     * Constructs a SetParamCommand for parameter paramIdx on modId.
     *
     * Params:
     *   modId = Target module identifier.
     *   paramIdx = Zero-based parameter index.
     *   oldVal = Parameter value before drag/edit.
     *   newVal = Target parameter value.
     *   epoch = History coalescing epoch token.
     */
    this(uint modId, uint paramIdx, float oldVal, float newVal, uint epoch) {
        modId_ = modId;
        paramIdx_ = paramIdx;
        oldVal_ = oldVal;
        newVal_ = newVal;
        epoch_ = epoch;
    }

    override bool execute(StudioSession session) {
        return session.setParamDirect(modId_, paramIdx_, newVal_);
    }

    override bool undo(StudioSession session) {
        return session.setParamDirect(modId_, paramIdx_, oldVal_);
    }

    override string label() const {
        return "Change Parameter";
    }

    override bool canMergeWith(IUndoCommand next) const {
        auto other = cast(SetParamCommand) next;
        return other !is null
            && other.epoch_ == epoch_
            && other.modId_ == modId_
            && other.paramIdx_ == paramIdx_;
    }

    override void mergeFrom(IUndoCommand next) {
        auto other = cast(SetParamCommand) next;
        if (other !is null) {
            newVal_ = other.newVal_;
        }
    }
}

/**
 * Coalescable patchbay node coordinate drag command.
 */
class MoveModulePositionCommand : IUndoCommand {
    private uint modId_;
    private float oldX_;
    private float oldY_;
    private float newX_;
    private float newY_;
    private uint epoch_;

    /**
     * Constructs a MoveModulePositionCommand.
     *
     * Params:
     *   modId = Target module identifier.
     *   oldX = Initial X coordinate.
     *   oldY = Initial Y coordinate.
     *   newX = Target X coordinate.
     *   newY = Target Y coordinate.
     *   epoch = Coalescing epoch token.
     */
    this(uint modId, float oldX, float oldY, float newX, float newY, uint epoch) {
        modId_ = modId;
        oldX_ = oldX;
        oldY_ = oldY;
        newX_ = newX;
        newY_ = newY;
        epoch_ = epoch;
    }

    override bool execute(StudioSession session) {
        return session.setModulePositionDirect(modId_, newX_, newY_);
    }

    override bool undo(StudioSession session) {
        return session.setModulePositionDirect(modId_, oldX_, oldY_);
    }

    override string label() const {
        return "Move Module";
    }

    override bool canMergeWith(IUndoCommand next) const {
        auto other = cast(MoveModulePositionCommand) next;
        return other !is null && other.epoch_ == epoch_ && other.modId_ == modId_;
    }

    override void mergeFrom(IUndoCommand next) {
        auto other = cast(MoveModulePositionCommand) next;
        if (other !is null) {
            newX_ = other.newX_;
            newY_ = other.newY_;
        }
    }
}

/**
 * Reversible timeline clip placement addition command.
 */
class AddClipCommand : IUndoCommand {
    private TimelineClip clip_;

    /**
     * Constructs an AddClipCommand.
     *
     * Params:
     *   clip = TimelineClip placement to insert.
     */
    this(TimelineClip clip) {
        clip_ = clip;
    }

    override bool execute(StudioSession session) {
        return session.addClipDirect(clip_);
    }

    override bool undo(StudioSession session) {
        return session.removeClipDirect(clip_.clipId);
    }

    override string label() const {
        return "Add Clip";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible timeline clip position/length edit command.
 */
class MoveClipCommand : IUndoCommand {
    private TimelineClip before_;
    private TimelineClip after_;

    /**
     * Constructs a MoveClipCommand storing prior and updated clip geometry.
     *
     * Params:
     *   before = Clip state before edit.
     *   after = Updated clip geometry.
     */
    this(TimelineClip before, TimelineClip after) {
        before_ = before;
        after_ = after;
    }

    override bool execute(StudioSession session) {
        return session.updateClipDirect(after_);
    }

    override bool undo(StudioSession session) {
        return session.updateClipDirect(before_);
    }

    override string label() const {
        return "Move Clip";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible timeline clip clone insertion command sharing a patternId.
 */
class CloneClipCommand : IUndoCommand {
    private TimelineClip cloned_;

    /**
     * Constructs a CloneClipCommand.
     *
     * Params:
     *   cloned = Cloned TimelineClip placement.
     */
    this(TimelineClip cloned) {
        cloned_ = cloned;
    }

    override bool execute(StudioSession session) {
        return session.addClipDirect(cloned_);
    }

    override bool undo(StudioSession session) {
        return session.removeClipDirect(cloned_.clipId);
    }

    override string label() const {
        return "Clone Clip";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible timeline clip removal command.
 */
class RemoveClipCommand : IUndoCommand {
    private TimelineClip archived_;

    /**
     * Constructs a RemoveClipCommand archiving deleted clip metadata.
     *
     * Params:
     *   archived = Removed clip snapshot.
     */
    this(TimelineClip archived) {
        archived_ = archived;
    }

    override bool execute(StudioSession session) {
        return session.removeClipDirect(archived_.clipId);
    }

    override bool undo(StudioSession session) {
        return session.addClipDirect(archived_);
    }

    override string label() const {
        return "Remove Clip";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible timeline clip mute/solo/supertrack flag update command.
 */
class SetClipFlagsCommand : IUndoCommand {
    private TimelineClip before_;
    private TimelineClip after_;

    /**
     * Constructs a SetClipFlagsCommand.
     *
     * Params:
     *   before = Prior clip flags.
     *   after = Updated clip flags.
     */
    this(TimelineClip before, TimelineClip after) {
        before_ = before;
        after_ = after;
    }

    override bool execute(StudioSession session) {
        return session.updateClipDirect(after_);
    }

    override bool undo(StudioSession session) {
        return session.updateClipDirect(before_);
    }

    override string label() const {
        return "Toggle Clip Flags";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible project BPM and ticks-per-line tempo change command.
 */
class SetTempoCommand : IUndoCommand {
    private double oldBpm_;
    private uint oldTpl_;
    private double newBpm_;
    private uint newTpl_;

    /**
     * Constructs a SetTempoCommand.
     *
     * Params:
     *   oldBpm = Prior BPM.
     *   oldTpl = Prior ticks per line.
     *   newBpm = Updated BPM.
     *   newTpl = Updated ticks per line.
     */
    this(double oldBpm, uint oldTpl, double newBpm, uint newTpl) {
        oldBpm_ = oldBpm;
        oldTpl_ = oldTpl;
        newBpm_ = newBpm;
        newTpl_ = newTpl;
    }

    override bool execute(StudioSession session) {
        return session.setTempoDirect(newBpm_, newTpl_);
    }

    override bool undo(StudioSession session) {
        return session.setTempoDirect(oldBpm_, oldTpl_);
    }

    override string label() const {
        return "Change Tempo";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible project time-signature change.
 */
class SetTimeSignatureCommand : IUndoCommand {
    private ubyte oldNum_;
    private ubyte oldDen_;
    private ubyte newNum_;
    private ubyte newDen_;

    /**
     * Constructs a SetTimeSignatureCommand.
     *
     * Params:
     *   oldNum = Prior numerator.
     *   oldDen = Prior denominator.
     *   newNum = New numerator.
     *   newDen = New denominator.
     */
    this(ubyte oldNum, ubyte oldDen, ubyte newNum, ubyte newDen) {
        oldNum_ = oldNum;
        oldDen_ = oldDen;
        newNum_ = newNum;
        newDen_ = newDen;
    }

    override bool execute(StudioSession session) {
        return session.setTimeSignatureDirect(newNum_, newDen_);
    }

    override bool undo(StudioSession session) {
        return session.setTimeSignatureDirect(oldNum_, oldDen_);
    }

    override string label() const {
        return "Change Time Signature";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible change of the song key.
 */
class SetKeyCommand : IUndoCommand {
    private MusicalKey old_;
    private MusicalKey new_;

    /**
     * Constructs a SetKeyCommand.
     *
     * Params:
     *   oldKey = Prior key.
     *   newKey = New key.
     */
    this(MusicalKey oldKey, MusicalKey newKey) {
        old_ = oldKey;
        new_ = newKey;
    }

    override bool execute(StudioSession session) {
        return session.setKeyDirect(new_);
    }

    override bool undo(StudioSession session) {
        return session.setKeyDirect(old_);
    }

    override string label() const {
        return "Change Key";
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Atomic group of already-executed commands recorded by UndoHistory.endGroup().
 */
class CompoundCommand : IUndoCommand {
    private string label_;
    private IUndoCommand[] children_;

    /**
     * Creates a group.
     *
     * Params:
     *   label = Undo menu label.
     *   children = Commands in execution order.
     */
    this(string label, IUndoCommand[] children) {
        label_ = label;
        children_ = children;
    }

    /**
     * Returns the number of grouped commands.
     *
     * Returns:
     *   Child count.
     */
    size_t childCount() const {
        return children_.length;
    }

    override bool execute(StudioSession session) {
        foreach (i, c; children_) {
            if (!c.execute(session)) {
                foreach_reverse (done; children_[0 .. i]) {
                    done.undo(session);
                }
                return false;
            }
        }
        return true;
    }

    override bool undo(StudioSession session) {
        foreach_reverse (i, c; children_) {
            if (!c.undo(session)) {
                foreach (redone; children_[i + 1 .. $]) {
                    redone.execute(session);
                }
                return false;
            }
        }
        return true;
    }

    override string label() const {
        return label_;
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible command defined by a pair of session-bound delegates (used by Phase 7.5 session operations).
 */
class DelegateCommand : IUndoCommand {
    private string label_;
    private bool delegate() apply_;
    private bool delegate() revert_;

    /**
     * Creates the command.
     *
     * Params:
     *   label = Undo menu label.
     *   apply = Performs the change; returns false (leaving state unchanged) on failure.
     *   revert = Reverts the change; returns false (leaving state unchanged) on failure.
     */
    this(string label, bool delegate() apply, bool delegate() revert) {
        label_ = label;
        apply_ = apply;
        revert_ = revert;
    }

    override bool execute(StudioSession session) {
        return apply_ !is null && apply_();
    }

    override bool undo(StudioSession session) {
        return revert_ !is null && revert_();
    }

    override string label() const {
        return label_;
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }
}

/**
 * Reversible whole-document replacement command (used by the script tab, T113).
 *
 * execute() activates after_ and undo() restores before_, each as one StudioSession
 * replaceDocumentDirect() step; history, file path and transport survive the swap.
 * Memory: unlike existing commands (which keep at most one module or one pattern's cells), this command
 * keeps two complete LoadedProjects, live sample data included. The history holds up to 512 steps, so a
 * long replace-heavy session can retain many whole documents; no memory limit is imposed in T111.
 */
class ReplaceDocumentCommand : IUndoCommand {
    private string label_;
    private LoadedProject before_;
    private LoadedProject after_;
    private string lastError_;

    /**
     * Constructs a ReplaceDocumentCommand holding the document snapshots to swap.
     *
     * Params:
     *   label = Undo menu label.
     *   before = Complete project open before the replacement (restore target for undo()).
     *   after = Complete project the replacement activates (target for execute()).
     */
    this(string label, LoadedProject before, LoadedProject after) {
        label_ = label;
        before_ = before;
        after_ = after;
    }

    /**
     * Activates after_ as the open project; on a late activation failure the session restores before_.
     *
     * Params:
     *   session = Active StudioSession owning document and Engine.
     *
     * Returns:
     *   True if after_ is the open project; false leaves before_ open and records lastError().
     */
    override bool execute(StudioSession session) {
        return session.replaceDocumentDirect(after_, before_, lastError_);
    }

    /**
     * Restores before_ as the open project; on a late activation failure the session restores after_.
     *
     * Params:
     *   session = Active StudioSession owning document and Engine.
     *
     * Returns:
     *   True if before_ is the open project; false leaves after_ open and records lastError().
     */
    override bool undo(StudioSession session) {
        return session.replaceDocumentDirect(before_, after_, lastError_);
    }

    override string label() const {
        return label_;
    }

    override bool canMergeWith(IUndoCommand next) const {
        return false;
    }

    override void mergeFrom(IUndoCommand next) {
        cast(void) next;
    }

    /**
     * Returns the reason the most recent execute() or undo() failed, or an empty string.
     *
     * Returns:
     *   Last failure diagnostic.
     */
    string lastError() const {
        return lastError_;
    }
}
