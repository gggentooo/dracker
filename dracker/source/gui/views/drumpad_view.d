/**
 * File:         source/gui/views/drumpad_view.d
 * Module:       gui.views.drumpad_view
 * Phase:        Pattern editor views — T48 & T54 (drumpad pads, lanes, and audition)
 *
 * Purpose:
 *   FL-Studio-style step pad grid for drum patterns registered inside PatternEditorView (T30, T33, T34, T41,
 *   T48, T54). Shows one row per drum lane (name, unassigned hatching/tag, audition on label click, and a
 *   per-lane menu button for Module, Note, Rename…, Move Up/Down, and Remove Lane) plus an Add Lane button
 *   below the last row, and one pad per step on the right grouped by beats and bars according to
 *   StudioSession.linesPerBeat() / linesPerBar(). Click toggles a hit in one undo step; dragging paints or
 *   erases hits as one undo group; vertical drag on a hit adjusts velocity and sets the lane's next-hit
 *   velocity; Option-clicking cycles soft/medium/loud. Hits whose cell module or pitch differs from their lane
 *   carry a non-color corner mark. Highlights the playhead column with follow-playhead and scrolls cleanly.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Reads and mutates patterns strictly through StudioSession.
 *
 * Dependencies:
 *   Internal: app.{keymap,session}, foundation.types, gui.{renderer,theme,widgets}, gui.views.studio_context,
 *             io.project_format, platform.interfaces
 *   External: std.conv (to), std.format (format, sformat), std.math (abs, floor, isFinite), std.string (strip)
 *
 * Planned API (Types, Functions & Hooks):
 *   - final class DrumpadView : Widget, StudioCommandSink — this(StudioContext), stepOffsetX(), rulerRect(),
 *     labelsRect(), padsRect(), laneRowRect(), laneLabelRect(), laneMenuButtonRect(), addLaneButtonRect(),
 *     padRect(), hitPad(), laneMenuItems(), laneModuleMenuItems(), laneNoteMenuItems(), addLane(),
 *     beginRenameLane(), scrollX(), scrollY(), setScroll(), laneVelocity(), auditionCount(),
 *     lastAuditionedNote(), playheadLocalLine(), localLineForSongLine(), handleStudioAction(), update()
 *   - Widget id: "pattern.drumpad"
 *
 * See_Also:
 *   docs/todo.md (T33, T34, T41, T43, T48, T54), source/gui/views/pattern_editor.d
 */
module gui.views.drumpad_view;

import std.conv : to;
import std.format : format, sformat;
import std.math : abs, floor, isFinite;
import std.string : strip;

import app.keymap : StudioAction, StudioCommandSink;
import app.session : StudioSession;
import foundation.types : ModuleId;
import gui.renderer : ColorRGBA, FontId, IRenderer2D, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.views.studio_context : StudioContext;
import gui.widgets : hasModifier, MenuItem, MouseButton, MouseEvent, openTextEditor, ScrollEvent, TextField, Widget;
import io.project_format : MAX_TRACKS, PATTERN_KIND_DRUM, SavedDrumLane, SavedPattern;
import platform.interfaces : KeyModifiers;

/**
 * Step-sequencer drum pad editor widget hosted inside PatternEditorView.
 */
final class DrumpadView : Widget, StudioCommandSink {
    enum float RULER_H = 22.0f;
    enum float LANE_LABEL_W = 168.0f;
    enum float LANE_MENU_BTN_W = 20.0f;
    enum float ADD_LANE_H = 26.0f;
    enum float ROW_H = 32.0f;
    enum float PAD_W = 24.0f;
    enum float PAD_H = 24.0f;
    enum float PAD_MARGIN_X = 8.0f;
    enum float PAD_MARGIN_Y = 4.0f;
    enum float STEP_GAP = 3.0f;
    enum float BEAT_GAP = 10.0f;
    enum float BAR_GAP = 18.0f;
    enum float VELOCITY_SOFT = 0.35f;
    enum float VELOCITY_MEDIUM = 0.70f;
    enum float VELOCITY_LOUD = 1.0f;

    private enum uint LANE_AUDITION_TAG_BASE = 0x4452_0000u;

    private struct DrumPresetNote {
        string label;
        ubyte midi;
    }

    private static immutable DrumPresetNote[7] GM_DRUM_NOTES = [
        DrumPresetNote("Kick (36)", 36),
        DrumPresetNote("Snare (38)", 38),
        DrumPresetNote("Closed Hat (42)", 42),
        DrumPresetNote("Open Hat (46)", 46),
        DrumPresetNote("Low Tom (41)", 41),
        DrumPresetNote("High Tom (47)", 47),
        DrumPresetNote("Perc (49)", 49)
    ];

    private enum DragMode : ubyte {
        none = 0,
        hitPending = 1,
        paintOn = 2,
        paintOff = 3,
        velocity = 4,
        audition = 5
    }

    StudioContext ctx;

    private float scrollX_ = 0.0f;
    private float scrollY_ = 0.0f;
    private uint shownPattern_ = 0;
    private float[uint] laneVelocity_;
    private DragMode drag_ = DragMode.none;
    private Point2F pressPos_;
    private uint dragLane_ = 0;
    private uint dragLine_ = 0;
    private float dragOrigVel_ = StudioSession.DEFAULT_DRUM_VELOCITY;
    private uint lastDragLane_ = uint.max;
    private uint lastDragLine_ = uint.max;
    private bool groupOpen_ = false;
    private long lastDrawnPlayLine_ = -1;

    private bool auditionActive_ = false;
    private uint auditionMod_ = 0;
    private uint auditionTag_ = 0;
    private size_t auditionCount_ = 0;
    private ubyte lastAuditionedNote_ = 0;

    /**
     * Creates the drumpad view.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        assert(ctx !is null, "DrumpadView requires a StudioContext");
        this.ctx = ctx;
        id = "pattern.drumpad";
        focusable = true;
        contextMenuProvider = &buildContextMenu;
    }

    /**
     * Computes the content-space x coordinate of step line's left edge, grouped by beat and bar.
     *
     * Params:
     *   line = Step index.
     *   beatLines = Lines per beat.
     *   barLines = Lines per bar.
     *
     * Returns:
     *   Content x offset in logical points.
     */
    float stepOffsetX(uint line, uint beatLines, uint barLines) const {
        immutable uint bars = barLines > 0 ? line / barLines : 0;
        immutable uint beats = beatLines > 0 ? (line / beatLines) - bars : 0;
        immutable uint steps = line - beats - bars;
        return PAD_MARGIN_X + cast(float) line * PAD_W + cast(float) steps * STEP_GAP
            + cast(float) beats * BEAT_GAP + cast(float) bars * BAR_GAP;
    }

    /**
     * Returns the bar-number ruler rectangle above the pads.
     *
     * Returns:
     *   Rectangle in window coordinates.
     */
    RectF rulerRect() const {
        immutable float lw = LANE_LABEL_W < bounds.w ? LANE_LABEL_W : bounds.w;
        immutable float pw = bounds.w > lw ? bounds.w - lw : 0.0f;
        immutable float rh = RULER_H < bounds.h ? RULER_H : (bounds.h > 0.0f ? bounds.h : 0.0f);
        return RectF(bounds.x + lw, bounds.y, pw, rh);
    }

    /**
     * Returns the lane-label column rectangle on the left.
     *
     * Returns:
     *   Rectangle in window coordinates.
     */
    RectF labelsRect() const {
        immutable float lw = LANE_LABEL_W < bounds.w ? LANE_LABEL_W : bounds.w;
        immutable float h = bounds.bottom() - (bounds.y + RULER_H);
        return RectF(bounds.x, bounds.y + RULER_H, lw, h > 0.0f ? h : 0.0f);
    }

    /**
     * Returns the scrollable pad grid rectangle.
     *
     * Returns:
     *   Rectangle in window coordinates.
     */
    RectF padsRect() const {
        immutable float lw = LANE_LABEL_W < bounds.w ? LANE_LABEL_W : bounds.w;
        immutable float pw = bounds.w > lw ? bounds.w - lw : 0.0f;
        immutable float h = bounds.bottom() - (bounds.y + RULER_H);
        return RectF(bounds.x + lw, bounds.y + RULER_H, pw, h > 0.0f ? h : 0.0f);
    }

    /**
     * Returns the full pad-area row rectangle for a lane.
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   Row rectangle.
     */
    RectF laneRowRect(uint lane) const {
        immutable RectF pr = padsRect();
        return RectF(pr.x, pr.y + cast(float) lane * ROW_H - scrollY_, pr.w, ROW_H);
    }

    /**
     * Returns the label cell rectangle for a lane.
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   Label rectangle.
     */
    RectF laneLabelRect(uint lane) const {
        immutable RectF lr = labelsRect();
        return RectF(lr.x, lr.y + cast(float) lane * ROW_H - scrollY_, lr.w, ROW_H);
    }

    /**
     * Returns the per-lane menu button rectangle inside laneLabelRect(lane).
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   Button rectangle.
     */
    RectF laneMenuButtonRect(uint lane) const {
        immutable RectF row = laneLabelRect(lane);
        return RectF(row.right() - LANE_MENU_BTN_W - 4.0f, row.y + (ROW_H - 20.0f) * 0.5f, LANE_MENU_BTN_W, 20.0f);
    }

    /**
     * Returns the Add Lane button rectangle below the last lane inside labelsRect().
     *
     * Returns:
     *   Button rectangle (empty when no drum pattern is active).
     */
    RectF addLaneButtonRect() const {
        const sp = currentDrumPattern();
        if (sp is null) {
            return RectF.init;
        }
        immutable RectF lr = labelsRect();
        immutable float y = lr.y + cast(float) sp.lanes.length * ROW_H - scrollY_ + 2.0f;
        return RectF(lr.x + 6.0f, y, lr.w > 12.0f ? lr.w - 12.0f : lr.w, ADD_LANE_H - 4.0f);
    }

    /**
     * Returns the window rectangle of one step pad.
     *
     * Params:
     *   lane = Lane index.
     *   line = Step line index.
     *
     * Returns:
     *   Pad rectangle.
     */
    RectF padRect(uint lane, uint line) const {
        immutable RectF pr = padsRect();
        immutable uint beat = ctx.session.linesPerBeat();
        immutable uint bar = ctx.session.linesPerBar();
        immutable float x = pr.x + stepOffsetX(line, beat, bar) - scrollX_;
        immutable float y = pr.y + cast(float) lane * ROW_H + PAD_MARGIN_Y - scrollY_;
        return RectF(x, y, PAD_W, PAD_H);
    }

    /**
     * Hit-tests the pad grid at a window point.
     *
     * Params:
     *   p = Window point.
     *   lane = Receives the lane index.
     *   line = Receives the step line index.
     *
     * Returns:
     *   True if p lies inside a valid pad.
     */
    bool hitPad(Point2F p, out uint lane, out uint line) const {
        immutable RectF pr = padsRect();
        if (!pr.contains(p)) {
            return false;
        }
        const sp = currentDrumPattern();
        if (sp is null || sp.lanes.length == 0 || sp.lines == 0) {
            return false;
        }
        immutable int rawLane = cast(int) floor((p.y - pr.y + scrollY_) / ROW_H);
        if (rawLane < 0 || rawLane >= cast(int) sp.lanes.length) {
            return false;
        }
        immutable uint ln = cast(uint) rawLane;
        foreach (s; 0 .. sp.lines) {
            immutable RectF r = padRect(ln, s);
            if (r.x > pr.right()) {
                break;
            }
            if (r.contains(p)) {
                lane = ln;
                line = s;
                return true;
            }
        }
        return false;
    }

    /**
     * Builds the lane context menu (Module, Note, Rename…, Move Up, Move Down, Remove Lane).
     *
     * Params:
     *   lane = Zero-based lane index.
     *
     * Returns:
     *   Menu entries (empty when lane is invalid).
     */
    MenuItem[] laneMenuItems(uint lane) {
        const sp = currentDrumPattern();
        if (sp is null || lane >= sp.lanes.length) {
            return null;
        }
        immutable uint pid = sp.patternId;
        immutable RectF anchor = laneMenuButtonRect(lane);
        immutable Point2F subAt = Point2F(anchor.right(), anchor.y);
        MenuItem[] items;
        items ~= MenuItem("Module ▸", {
            if (auto ui = context()) {
                ui.openContextMenu(laneModuleMenuItems(lane), subAt);
            }
        });
        items ~= MenuItem("Note ▸", {
            if (auto ui = context()) {
                ui.openContextMenu(laneNoteMenuItems(lane), subAt);
            }
        });
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem("Rename…", { beginRenameLane(lane); });
        items ~= MenuItem("Move Up", {
            ctx.session.doMoveDrumLane(pid, lane, lane - 1);
            invalidate();
        }, lane > 0);
        items ~= MenuItem("Move Down", {
            ctx.session.doMoveDrumLane(pid, lane, lane + 1);
            invalidate();
        }, lane + 1 < cast(uint) sp.lanes.length);
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem("Remove Lane", {
            ctx.session.doRemoveDrumLane(pid, lane);
            invalidate();
        }, sp.lanes.length > 1);
        return items;
    }

    /**
     * Builds the module chooser items for one drum lane.
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   Menu items covering Unassigned and every non-output module.
     */
    MenuItem[] laneModuleMenuItems(uint lane) {
        const sp = currentDrumPattern();
        if (sp is null || lane >= sp.lanes.length) {
            return null;
        }
        immutable uint pid = sp.patternId;
        immutable SavedDrumLane cur = sp.lanes[lane];
        MenuItem[] items;
        items ~= MenuItem(cur.moduleId == 0 ? "✓ (Unassigned)" : "(Unassigned)", {
            ctx.session.doRetargetDrumLane(pid, lane, 0, cur.note);
            invalidate();
        });
        foreach (ref m; ctx.session.document().modules) {
            if (m.id == 1 || m.typeId == "core.output") {
                continue;
            }
            immutable uint targetMod = m.id;
            immutable string prefix = cur.moduleId == targetMod ? "✓ " : "";
            immutable string baseName = m.name.length > 0 ? m.name : m.typeId;
            items ~= MenuItem(prefix ~ baseName, makeRetargetAction(pid, lane, targetMod, cur.note));
        }
        return items;
    }

    /**
     * Builds the note chooser items for one drum lane (GM drum voices plus custom MIDI entry).
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   Menu items.
     */
    MenuItem[] laneNoteMenuItems(uint lane) {
        const sp = currentDrumPattern();
        if (sp is null || lane >= sp.lanes.length) {
            return null;
        }
        immutable uint pid = sp.patternId;
        immutable SavedDrumLane cur = sp.lanes[lane];
        MenuItem[] items;
        foreach (gn; GM_DRUM_NOTES) {
            immutable ubyte targetNote = gn.midi;
            immutable string prefix = cur.note == targetNote ? "✓ " : "";
            items ~= MenuItem(prefix ~ gn.label, makeRetargetAction(pid, lane, cur.moduleId, targetNote));
        }
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem("Set MIDI Note…", { beginEditLaneNote(lane); });
        return items;
    }

    private void delegate() makeRetargetAction(uint pid, uint lane, uint modId, ubyte note) {
        return () {
            ctx.session.doRetargetDrumLane(pid, lane, modId, note);
            invalidate();
        };
    }

    /**
     * Opens an inline text editor over laneLabelRect(lane) to rename a drum lane.
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   The open TextField or null when unavailable.
     */
    TextField beginRenameLane(uint lane) {
        const sp = currentDrumPattern();
        auto ui = context();
        if (sp is null || ui is null || lane >= sp.lanes.length) {
            return null;
        }
        immutable uint pid = sp.patternId;
        return openTextEditor(ui, laneLabelRect(lane), sp.lanes[lane].name, (string nextName) {
            ctx.session.doRenameDrumLane(pid, lane, nextName);
            invalidate();
        });
    }

    /**
     * Opens an inline text editor over laneLabelRect(lane) to enter a MIDI note number 0..127.
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   The open TextField or null when unavailable.
     */
    TextField beginEditLaneNote(uint lane) {
        const sp = currentDrumPattern();
        auto ui = context();
        if (sp is null || ui is null || lane >= sp.lanes.length) {
            return null;
        }
        immutable uint pid = sp.patternId;
        immutable uint curMod = sp.lanes[lane].moduleId;
        return openTextEditor(ui, laneLabelRect(lane), format("%d", sp.lanes[lane].note), (string raw) {
            try {
                immutable int parsed = to!int(strip(raw));
                if (parsed < 0 || parsed > 127) {
                    ctx.setStatus("MIDI note must be between 0 and 127");
                    return;
                }
                ctx.session.doRetargetDrumLane(pid, lane, curMod, cast(ubyte) parsed);
                invalidate();
            } catch (Exception) {
                ctx.setStatus("Enter a MIDI note number 0..127");
            }
        });
    }

    /**
     * Appends a new drum lane to the current drum pattern (defaulting to the first DrumSynth or module).
     *
     * Returns:
     *   True if the lane was added.
     */
    bool addLane() {
        const sp = currentDrumPattern();
        if (sp is null) {
            return false;
        }
        if (sp.lanes.length >= MAX_TRACKS) {
            ctx.setStatus("Pattern already has 64 lanes");
            return false;
        }
        uint modId = 0;
        const doc = ctx.session.document();
        foreach (ref m; doc.modules) {
            if (m.typeId == "synth.drumsynth") {
                modId = m.id;
                break;
            }
        }
        if (modId == 0) {
            foreach (ref m; doc.modules) {
                if (m.id != 1 && m.typeId != "core.output") {
                    modId = m.id;
                    break;
                }
            }
        }
        ubyte note = 49;
        string name;
        foreach (gn; GM_DRUM_NOTES) {
            bool used = false;
            foreach (ref ln; sp.lanes) {
                if (ln.note == gn.midi) {
                    used = true;
                    break;
                }
            }
            if (!used) {
                note = gn.midi;
                name = format("Lane %d", sp.lanes.length + 1);
                break;
            }
        }
        if (!ctx.session.doAddDrumLane(sp.patternId, name, modId, note)) {
            return false;
        }
        clampScroll();
        invalidate();
        return true;
    }

    /**
     * Returns how many times a drum lane was auditioned from its label.
     *
     * Returns:
     *   Audition trigger count.
     */
    size_t auditionCount() const {
        return auditionCount_;
    }

    /**
     * Returns the most recently auditioned drum lane MIDI note.
     *
     * Returns:
     *   MIDI note 0..127.
     */
    ubyte lastAuditionedNote() const {
        return lastAuditionedNote_;
    }

    /**
     * Returns horizontal scroll offset in points.
     *
     * Returns:
     *   Horizontal scroll.
     */
    float scrollX() const {
        return scrollX_;
    }

    /**
     * Returns vertical scroll offset in points.
     *
     * Returns:
     *   Vertical scroll.
     */
    float scrollY() const {
        return scrollY_;
    }

    /**
     * Sets scroll offsets, clamped to content bounds.
     *
     * Params:
     *   x = Horizontal scroll in points.
     *   y = Vertical scroll in points.
     */
    void setScroll(float x, float y) {
        if (isFinite(x)) {
            scrollX_ = x;
        }
        if (isFinite(y)) {
            scrollY_ = y;
        }
        clampScroll();
        invalidate();
    }

    /**
     * Returns the default velocity used for new hits on lane (the last velocity set on that lane, or 0.8).
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   Velocity in (0, 1].
     */
    float laneVelocity(uint lane) const {
        if (auto p = lane in laneVelocity_) {
            return *p;
        }
        return StudioSession.DEFAULT_DRUM_VELOCITY;
    }

    /**
     * Maps a song line to the current pattern's local line.
     *
     * Params:
     *   songLine = Song line.
     *
     * Returns:
     *   Local line, or -1 when outside every clip of this pattern.
     */
    long localLineForSongLine(long songLine) const {
        const sp = currentDrumPattern();
        if (sp is null || sp.lines == 0 || songLine < 0) {
            return -1;
        }
        if (ctx.session.isAuditioningPattern()) {
            return songLine % sp.lines;
        }
        foreach (ref clip; ctx.session.document().clips) {
            if (clip.patternId != sp.patternId) {
                continue;
            }
            if (songLine >= clip.startLine && songLine < clip.startLine + clip.lengthLines) {
                immutable long rel = songLine - clip.startLine + clip.patternOffset;
                return rel % sp.lines;
            }
        }
        return -1;
    }

    /**
     * Returns the pattern-local playhead line from the latest telemetry.
     *
     * Returns:
     *   Local line, or -1 when stopped or outside every clip of this pattern.
     */
    long playheadLocalLine() const {
        if (!ctx.telemetry.engine.playing) {
            return -1;
        }
        return localLineForSongLine(ctx.telemetry.engine.currentLine);
    }

    /**
     * Syncs pattern switch state, scroll clamping, and playhead following.
     */
    void update() {
        immutable uint pid = ctx.currentPattern();
        if (pid != shownPattern_) {
            shownPattern_ = pid;
            scrollX_ = 0.0f;
            scrollY_ = 0.0f;
            laneVelocity_ = null;
            endDrag();
        }
        clampScroll();
        immutable long play = playheadLocalLine();
        if (ctx.followPlayhead && play >= 0) {
            followLine(cast(uint) play);
        }
        lastDrawnPlayLine_ = play;
    }

    override bool isAnimating() {
        if (ctx.telemetry.engine.playing && ctx.followPlayhead) {
            return true;
        }
        return playheadLocalLine() != lastDrawnPlayLine_;
    }

    bool handleStudioAction(StudioAction action) {
        switch (action) {
        case StudioAction.toggleFollow:
            ctx.followPlayhead = !ctx.followPlayhead;
            ctx.setStatus(ctx.followPlayhead ? "Follow on" : "Follow off");
            invalidate();
            return true;
        case StudioAction.nextPattern:
            return stepPattern(1);
        case StudioAction.prevPattern:
            return stepPattern(-1);
        default:
            return false;
        }
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        const sp = currentDrumPattern();
        if (sp is null) {
            return false;
        }
        if (labelsRect().contains(e.pos)) {
            if (addLaneButtonRect().contains(e.pos)) {
                addLane();
                return true;
            }
            immutable uint clickedLane = hitLabelLane(e.pos);
            if (clickedLane != uint.max) {
                if (laneMenuButtonRect(clickedLane).contains(e.pos)) {
                    if (auto ui = context()) {
                        immutable RectF br = laneMenuButtonRect(clickedLane);
                        ui.openContextMenu(laneMenuItems(clickedLane), Point2F(br.x, br.bottom()));
                    }
                    return true;
                }
                startAuditionLane(sp, clickedLane);
                drag_ = DragMode.audition;
                return true;
            }
        }
        uint lane, line;
        if (!hitPad(e.pos, lane, line)) {
            return false;
        }
        immutable uint pid = ctx.currentPattern();
        float curVel = 0.0f;
        bool custom = false;
        immutable bool isOn = ctx.session.drumHitAt(pid, lane, line, curVel, custom);
        if (hasModifier(e.modifiers, KeyModifiers.alt)) {
            if (!isOn) {
                return true;
            }
            if (!ctx.session.isDrumLaneAssigned(pid, lane)) {
                ctx.setStatus("Lane has no module assigned");
                return true;
            }
            immutable float nextVel = cycleVelocity(curVel);
            laneVelocity_[lane] = nextVel;
            ctx.session.doSetDrumHit(pid, lane, line, true, nextVel);
            invalidate();
            return true;
        }
        if (!isOn) {
            if (!ctx.session.isDrumLaneAssigned(pid, lane)) {
                ctx.setStatus("Lane has no module assigned");
                return true;
            }
            openGroup("Paint Drum Hits");
            ctx.session.doSetDrumHit(pid, lane, line, true, laneVelocity(lane));
            drag_ = DragMode.paintOn;
            lastDragLane_ = lane;
            lastDragLine_ = line;
            invalidate();
            return true;
        }
        drag_ = DragMode.hitPending;
        pressPos_ = e.pos;
        dragLane_ = lane;
        dragLine_ = line;
        dragOrigVel_ = curVel > 0.0f ? curVel : StudioSession.DEFAULT_DRUM_VELOCITY;
        lastDragLane_ = lane;
        lastDragLine_ = line;
        return true;
    }

    override bool onMouseMove(const ref MouseEvent e) {
        if (drag_ == DragMode.none) {
            return false;
        }
        if (drag_ == DragMode.audition) {
            return true;
        }
        immutable uint pid = ctx.currentPattern();
        if (drag_ == DragMode.hitPending) {
            immutable float dx = e.pos.x - pressPos_.x;
            immutable float dy = e.pos.y - pressPos_.y;
            uint hl, hs;
            immutable bool over = hitPad(e.pos, hl, hs);
            if (abs(dy) >= 4.0f && abs(dy) > abs(dx)) {
                if (!ctx.session.isDrumLaneAssigned(pid, dragLane_)) {
                    ctx.setStatus("Lane has no module assigned");
                    drag_ = DragMode.none;
                    return true;
                }
                drag_ = DragMode.velocity;
                openGroup("Set Drum Velocity");
                applyVelocityDrag(pid, dy);
                return true;
            }
            if ((over && (hl != dragLane_ || hs != dragLine_)) || (abs(dx) >= 6.0f && abs(dx) >= abs(dy))) {
                drag_ = DragMode.paintOff;
                openGroup("Erase Drum Hits");
                ctx.session.doSetDrumHit(pid, dragLane_, dragLine_, false);
                if (over && (hl != dragLane_ || hs != dragLine_)) {
                    ctx.session.doSetDrumHit(pid, hl, hs, false);
                    lastDragLane_ = hl;
                    lastDragLine_ = hs;
                }
                invalidate();
                return true;
            }
            return true;
        }
        if (drag_ == DragMode.velocity) {
            applyVelocityDrag(pid, e.pos.y - pressPos_.y);
            return true;
        }
        uint lane, line;
        if (!hitPad(e.pos, lane, line)) {
            return true;
        }
        if (lane == lastDragLane_ && line == lastDragLine_) {
            return true;
        }
        lastDragLane_ = lane;
        lastDragLine_ = line;
        if (drag_ == DragMode.paintOn) {
            if (ctx.session.isDrumLaneAssigned(pid, lane)) {
                ctx.session.doSetDrumHit(pid, lane, line, true, laneVelocity(lane));
            }
        } else if (drag_ == DragMode.paintOff) {
            ctx.session.doSetDrumHit(pid, lane, line, false);
        }
        invalidate();
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        if (drag_ == DragMode.none) {
            return false;
        }
        if (drag_ == DragMode.hitPending) {
            ctx.session.doSetDrumHit(ctx.currentPattern(), dragLane_, dragLine_, false);
        }
        stopAudition();
        endDrag();
        return true;
    }

    override void onCaptureLost() {
        stopAudition();
        endDrag();
    }

    override bool onScroll(const ref ScrollEvent e) {
        if (!bounds.contains(e.pos)) {
            return false;
        }
        float dy = e.deltaY;
        float dx = e.deltaX;
        if (hasModifier(e.modifiers, KeyModifiers.shift) && dx == 0.0f) {
            dx = dy;
            dy = 0.0f;
        }
        scrollX_ -= dx;
        scrollY_ -= dy;
        clampScroll();
        invalidate();
        return true;
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        update();
        const sp = currentDrumPattern();
        immutable RectF rr = rulerRect();
        immutable RectF lr = labelsRect();
        immutable RectF pr = padsRect();
        immutable uint beat = ctx.session.linesPerBeat();
        immutable uint bar = ctx.session.linesPerBar();
        immutable long play = playheadLocalLine();

        r.pushClip(bounds);
        r.fillRect(bounds, theme.panel);
        r.fillRect(RectF(bounds.x, bounds.y, lr.w, RULER_H), theme.panelSunken);
        r.fillRect(RectF(bounds.x, bounds.y + RULER_H - 1.0f, lr.w, 1.0f), theme.border);

        paintRuler(r, theme, rr, sp, beat, bar, play);
        paintLabels(r, theme, lr, sp);
        paintPads(r, theme, pr, sp, beat, bar, play);

        if (isFocused()) {
            r.strokeRoundedRect(bounds.inset(0.5f), 0.0f, 1.0f, theme.focusRing);
        }
        r.popClip();
    }

    private void paintRuler(IRenderer2D r, const ref StudioTheme theme, RectF rr, const(SavedPattern)* sp,
            uint beat, uint bar, long play) {
        if (rr.isEmpty()) {
            return;
        }
        r.pushClip(rr);
        r.fillRect(rr, theme.panelSunken);
        r.fillRect(RectF(rr.x, rr.bottom() - 1.0f, rr.w, 1.0f), theme.border);
        if (sp !is null && bar > 0) {
            immutable float lh = r.lineHeight(FontId.mono, theme.fontSizeSmall);
            char[16] buf;
            for (uint ln = 0; ln < sp.lines; ln += bar) {
                immutable float x = rr.x + stepOffsetX(ln, beat, bar) - scrollX_;
                if (x > rr.right()) {
                    break;
                }
                if (x + PAD_W * bar >= rr.x) {
                    const(char)[] label = sformat(buf[], "%d", ln / bar + 1);
                    r.drawText(Point2F(x, rr.y + (rr.h - lh) * 0.5f), label, FontId.mono, theme.fontSizeSmall,
                        theme.text);
                }
            }
        }
        if (sp !is null && play >= 0 && play < cast(long) sp.lines) {
            immutable float px = rr.x + stepOffsetX(cast(uint) play, beat, bar) - scrollX_;
            r.fillRect(RectF(px, rr.y, PAD_W, 3.0f), theme.danger);
        }
        r.popClip();
    }

    private void paintLabels(IRenderer2D r, const ref StudioTheme theme, RectF lr, const(SavedPattern)* sp) {
        if (lr.isEmpty()) {
            return;
        }
        r.pushClip(lr);
        r.fillRect(lr, theme.panel);
        if (sp !is null) {
            immutable float lh = r.lineHeight(FontId.ui, theme.fontSizeBody);
            immutable float slh = r.lineHeight(FontId.ui, theme.fontSizeSmall);
            foreach (li, ref lane; sp.lanes) {
                immutable RectF row = laneLabelRect(cast(uint) li);
                if (row.bottom() < lr.y || row.y > lr.bottom()) {
                    continue;
                }
                immutable bool assigned = ctx.session.isDrumLaneAssigned(sp.patternId, cast(uint) li);
                r.fillRect(row, (li % 2 == 0) ? theme.panel : theme.panelSunken);
                if (!assigned) {
                    drawHatch(r, row, theme.mutedHatch, 8.0f);
                }
                r.fillRect(RectF(row.x, row.bottom() - 1.0f, row.w, 1.0f), theme.gridLine);

                immutable RectF mb = laneMenuButtonRect(cast(uint) li);
                r.fillRoundedRect(mb, theme.radiusSm, theme.panelRaised);
                r.strokeRoundedRect(mb, theme.radiusSm, 1.0f, theme.border);
                immutable float dw = r.measureText("...", FontId.ui, theme.fontSizeSmall);
                r.drawText(Point2F(mb.x + (mb.w - dw) * 0.5f, mb.y + (mb.h - slh) * 0.5f),
                    "...", FontId.ui, theme.fontSizeSmall, theme.text);

                immutable float tagW = assigned ? 0.0f : r.measureText("[unassigned]", FontId.ui,
                    theme.fontSizeSmall) + 6.0f;
                immutable float rightReserve = LANE_MENU_BTN_W + 8.0f + tagW;
                r.pushClip(RectF(row.x, row.y, row.w > rightReserve ? row.w - rightReserve : row.w, row.h));
                r.drawText(Point2F(row.x + 8.0f, row.y + (row.h - lh) * 0.5f), lane.name, FontId.ui,
                    theme.fontSizeBody, assigned ? theme.text : theme.textDim);
                r.popClip();
                if (!assigned) {
                    r.drawText(Point2F(mb.x - tagW + 2.0f, row.y + (row.h - slh) * 0.5f),
                        "[unassigned]", FontId.ui, theme.fontSizeSmall, theme.textDim);
                }
            }

            immutable RectF ab = addLaneButtonRect();
            if (!ab.intersect(lr).isEmpty()) {
                immutable bool canAdd = sp.lanes.length < MAX_TRACKS;
                r.fillRoundedRect(ab, theme.radiusSm, theme.panelRaised);
                r.strokeRoundedRect(ab, theme.radiusSm, 1.0f, theme.border);
                immutable float tw = r.measureText("+ Add Lane", FontId.ui, theme.fontSizeSmall);
                r.drawText(Point2F(ab.x + (ab.w - tw) * 0.5f, ab.y + (ab.h - slh) * 0.5f),
                    "+ Add Lane", FontId.ui, theme.fontSizeSmall, canAdd ? theme.text : theme.textDim);
            }
        }
        if (lr.w >= 1.0f) {
            r.fillRect(RectF(lr.right() - 1.0f, lr.y, 1.0f, lr.h), theme.border);
        }
        r.popClip();
    }

    private void paintPads(IRenderer2D r, const ref StudioTheme theme, RectF pr, const(SavedPattern)* sp,
            uint beat, uint bar, long play) {
        if (pr.isEmpty()) {
            return;
        }
        r.pushClip(pr);
        r.fillRect(pr, theme.trackerBackground);
        if (sp is null) {
            r.popClip();
            return;
        }
        immutable uint laneCount = cast(uint) sp.lanes.length;
        foreach (li; 0 .. laneCount) {
            immutable RectF row = laneRowRect(li);
            if (row.bottom() < pr.y || row.y > pr.bottom()) {
                continue;
            }
            r.fillRect(row, (li % 2 == 0) ? theme.trackerBackground : theme.trackerRowBeat);
            if (!ctx.session.isDrumLaneAssigned(sp.patternId, li)) {
                drawHatch(r, row, theme.mutedHatch, 8.0f);
            }
            r.fillRect(RectF(row.x, row.bottom() - 1.0f, row.w, 1.0f), theme.gridLine);
        }
        if (bar > 0) {
            for (uint ln = bar; ln < sp.lines; ln += bar) {
                immutable float x = pr.x + stepOffsetX(ln, beat, bar) - scrollX_ - BAR_GAP * 0.5f;
                if (x >= pr.x && x <= pr.right()) {
                    r.fillRect(RectF(x - 1.0f, pr.y, 2.0f, pr.h), theme.border);
                }
            }
        }
        if (play >= 0 && play < cast(long) sp.lines) {
            immutable float px = pr.x + stepOffsetX(cast(uint) play, beat, bar) - scrollX_;
            immutable float colH = cast(float) laneCount * ROW_H - scrollY_;
            immutable float drawH = colH < pr.h ? (colH > 0.0f ? colH : 0.0f) : pr.h;
            if (drawH > 0.0f) {
                r.fillRect(RectF(px - 2.0f, pr.y, PAD_W + 4.0f, drawH), theme.trackerPlayhead);
                r.fillRect(RectF(px - 2.0f, pr.y, PAD_W + 4.0f, 2.0f), theme.danger);
            }
        }
        foreach (li; 0 .. laneCount) {
            immutable RectF row = laneRowRect(li);
            if (row.bottom() < pr.y || row.y > pr.bottom()) {
                continue;
            }
            foreach (step; 0 .. sp.lines) {
                immutable RectF pad = padRect(li, step);
                if (pad.right() < pr.x) {
                    continue;
                }
                if (pad.x > pr.right()) {
                    break;
                }
                immutable bool oddBeat = beat > 0 && ((step / beat) % 2 == 1);
                float vel = 0.0f;
                bool custom = false;
                immutable bool isOn = ctx.session.drumHitAt(sp.patternId, li, step, vel, custom);
                if (!isOn) {
                    r.fillRoundedRect(pad, theme.radiusSm, oddBeat ? theme.trackerRowBeat : theme.trackerBackground);
                    r.strokeRoundedRect(pad, theme.radiusSm, 1.0f, theme.border);
                } else {
                    r.fillRoundedRect(pad, theme.radiusSm, theme.trackerBackground);
                    immutable float normVel = vel < 0.12f ? 0.12f : (vel > 1.0f ? 1.0f : vel);
                    immutable float innerH = pad.h - 4.0f;
                    immutable float fillH = innerH * normVel;
                    r.fillRect(RectF(pad.x + 2.0f, pad.bottom() - 2.0f - fillH, pad.w - 4.0f, fillH),
                        theme.padHit);
                    r.strokeRoundedRect(pad, theme.radiusSm, 2.0f, theme.borderStrong);
                    if (custom) {
                        immutable RectF mark = RectF(pad.right() - 7.0f, pad.y + 2.0f, 5.0f, 5.0f);
                        r.fillRect(mark, theme.panelRaised);
                        r.strokeRoundedRect(mark, 0.0f, 1.0f, theme.borderStrong);
                    }
                }
            }
        }
        r.popClip();
    }

    private MenuItem[] buildContextMenu(Point2F p) {
        if (!labelsRect().contains(p)) {
            return null;
        }
        immutable uint lane = hitLabelLane(p);
        return lane != uint.max ? laneMenuItems(lane) : null;
    }

    private uint hitLabelLane(Point2F p) const {
        const sp = currentDrumPattern();
        immutable RectF lr = labelsRect();
        if (sp is null || !lr.contains(p)) {
            return uint.max;
        }
        immutable int raw = cast(int) floor((p.y - lr.y + scrollY_) / ROW_H);
        if (raw < 0 || raw >= cast(int) sp.lanes.length) {
            return uint.max;
        }
        return cast(uint) raw;
    }

    private void startAuditionLane(const(SavedPattern)* sp, uint lane) {
        if (sp is null || lane >= sp.lanes.length) {
            return;
        }
        if (!ctx.session.isDrumLaneAssigned(sp.patternId, lane)) {
            ctx.setStatus("Lane has no module assigned");
            return;
        }
        immutable SavedDrumLane dl = sp.lanes[lane];
        stopAudition();
        immutable uint tag = LANE_AUDITION_TAG_BASE | lane;
        ctx.session.triggerLiveNote(ModuleId(dl.moduleId), tag, cast(float) dl.note, laneVelocity(lane));
        auditionActive_ = true;
        auditionMod_ = dl.moduleId;
        auditionTag_ = tag;
        auditionCount_++;
        lastAuditionedNote_ = dl.note;
    }

    private void stopAudition() {
        if (!auditionActive_) {
            return;
        }
        ctx.session.releaseLiveNote(ModuleId(auditionMod_), auditionTag_);
        auditionActive_ = false;
    }

    private static void drawHatch(IRenderer2D r, RectF area, ColorRGBA color, float spacing) {
        if (area.isEmpty() || !(spacing > 1.0f)) {
            return;
        }
        r.pushClip(area);
        for (float d = -area.h; d < area.w; d += spacing) {
            r.drawLine(Point2F(area.x + d, area.bottom()), Point2F(area.x + d + area.h, area.y), 1.0f, color);
        }
        r.popClip();
    }

    private const(SavedPattern)* currentDrumPattern() const {
        immutable uint pid = ctx.currentPattern();
        foreach (ref p; ctx.session.document().patterns) {
            if (p.patternId == pid && p.kind == PATTERN_KIND_DRUM) {
                return &p;
            }
        }
        return null;
    }

    private void applyVelocityDrag(uint pid, float dy) {
        float v = dragOrigVel_ - dy / 80.0f;
        if (v < 0.05f) v = 0.05f;
        if (v > 1.0f) v = 1.0f;
        ctx.session.doSetDrumHit(pid, dragLane_, dragLine_, true, v);
        float stored = v;
        bool custom = false;
        if (ctx.session.drumHitAt(pid, dragLane_, dragLine_, stored, custom)) {
            laneVelocity_[dragLane_] = stored;
        } else {
            laneVelocity_[dragLane_] = v;
        }
        invalidate();
    }

    private static float cycleVelocity(float v) {
        if (v < 0.52f) {
            return VELOCITY_MEDIUM;
        }
        if (v < 0.85f) {
            return VELOCITY_LOUD;
        }
        return VELOCITY_SOFT;
    }

    private void openGroup(string label) {
        if (groupOpen_) {
            return;
        }
        ctx.session.history().breakCoalesce();
        ctx.session.beginEditGroup(label);
        groupOpen_ = true;
    }

    private void endDrag() {
        if (groupOpen_) {
            groupOpen_ = false;
            ctx.session.endEditGroup();
            ctx.session.history().breakCoalesce();
        }
        drag_ = DragMode.none;
        lastDragLane_ = uint.max;
        lastDragLine_ = uint.max;
        invalidate();
    }

    private void followLine(uint line) {
        immutable RectF pr = padsRect();
        if (pr.w <= 0.0f) {
            return;
        }
        immutable float px = stepOffsetX(line, ctx.session.linesPerBeat(), ctx.session.linesPerBar());
        if (px - scrollX_ < 0.0f || px + PAD_W - scrollX_ > pr.w) {
            scrollX_ = px - pr.w * 0.35f;
            clampScroll();
            invalidate();
        }
    }

    private void clampScroll() {
        immutable RectF pr = padsRect();
        const sp = currentDrumPattern();
        if (sp is null) {
            scrollX_ = 0.0f;
            scrollY_ = 0.0f;
            return;
        }
        immutable uint beat = ctx.session.linesPerBeat();
        immutable uint bar = ctx.session.linesPerBar();
        immutable float contentW = sp.lines > 0
            ? stepOffsetX(sp.lines - 1, beat, bar) + PAD_W + PAD_MARGIN_X : 0.0f;
        immutable float maxX = contentW > pr.w ? contentW - pr.w : 0.0f;
        if (!isFinite(scrollX_) || scrollX_ < 0.0f) {
            scrollX_ = 0.0f;
        } else if (scrollX_ > maxX) {
            scrollX_ = maxX;
        }
        immutable float contentH = cast(float) sp.lanes.length * ROW_H + ADD_LANE_H;
        immutable float maxY = contentH > pr.h ? contentH - pr.h : 0.0f;
        if (!isFinite(scrollY_) || scrollY_ < 0.0f) {
            scrollY_ = 0.0f;
        } else if (scrollY_ > maxY) {
            scrollY_ = maxY;
        }
    }

    private bool stepPattern(int dir) {
        const doc = ctx.session.document();
        ptrdiff_t idx = -1;
        immutable uint pid = ctx.currentPattern();
        foreach (i, ref p; doc.patterns) {
            if (p.patternId == pid) {
                idx = cast(ptrdiff_t) i;
                break;
            }
        }
        if (idx < 0) {
            return false;
        }
        immutable ptrdiff_t next = idx + dir;
        if (next >= 0 && next < cast(ptrdiff_t) doc.patterns.length) {
            ctx.selectPattern(doc.patterns[next].patternId);
            invalidate();
        }
        return true;
    }
}
