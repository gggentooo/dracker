/**
 * File:         source/gui/views/piano_roll_view.d
 * Module:       gui.views.piano_roll_view
 * Phase:        Pattern editor views — T47 & T53 (piano roll display, navigation, and editing)
 *
 * Purpose:
 *   Interactive DAW-style piano roll view registered inside PatternEditorView (T30, T31, T32, T42, T47, T53).
 *   Displays piano keys on the left (C-1..G9, C keys labelled, black keys shaded and indented for non-color
 *   distinction), a bar ruler and vertical time-signature grid (line / beat / bar from
 *   StudioSession.linesPerBeat() / linesPerBar()), notes derived from app.pattern_notes.notesOf() (picked
 *   module filled, selected notes highlighted with a 2-point border, other modules outlined only), a velocity
 *   strip beneath the roll, and playhead with follow-playhead.
 *   Supports click-to-add notes (inheriting last edited note length, initially one beat), body drag to move in
 *   time and pitch, Option-drag to copy (preserving effect columns), right-edge drag to resize, rubber-band
 *   selection, velocity strip dragging, piano-key and edit note audition, Escape to cancel a drag or clear
 *   selection, Delete/Backspace, clipboard Cut/Copy/Paste (DRACKER-ROLL-V1 text format preserving effect
 *   columns), and semitone/octave transpose. Every gesture commits as one undo step through
 *   StudioSession.doReplacePatternGrid(), automatically adding tracks when needed with a status message and
 *   reporting refused edits with noteEditMessage().
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Reads StudioContext.session.document() and converts the current pattern on revision change;
 *   never retains pointers into the document across frames.
 *
 * Dependencies:
 *   Internal: app.{keymap,pattern_notes}, foundation.types, gui.{renderer,theme,widgets},
 *             gui.views.{piano_view,studio_context}, io.project_format, platform.interfaces, sequencer.note
 *   External: std.algorithm (sort), std.conv (to), std.format (format, sformat),
 *             std.math (abs, ceil, exp, floor, isFinite), std.string (split, splitLines, strip)
 *
 * Planned API (Types, Functions & Hooks):
 *   - final class PianoRollView : Widget, StudioCommandSink — this(StudioContext), modulePicker, pickedModule(),
 *     selectPickedModule(), barRect(), rulerRect(), keysRect(), gridRect(), velocityRect(), velocityBarRect(),
 *     lineToX(), xToLine(), pitchToY(), yToPitch(), keyRect(), noteRect(), notes(), selectedNotes(),
 *     hasSelection(), clearSelection(), selectAll(), lastNoteLength(), lastVelocity(), auditionCount(),
 *     lastAuditionedPitch(), lineWidth(), rowHeight(), scrollX(), scrollY(), setScroll(), setZoom(),
 *     zoomAround(), playheadLocalLine(), localLineForSongLine(), handleStudioAction(), update()
 *   - Widget ids: "pattern.pianoRoll", "pianoRoll.module"
 *
 * See_Also:
 *   docs/todo.md (T31, T32, T42, T43, T47, T53), source/gui/views/pattern_editor.d
 */
module gui.views.piano_roll_view;

import std.algorithm : sort;
import std.conv : to;
import std.format : format, sformat;
import std.math : abs, ceil, exp, floor, isFinite;
import std.string : split, splitLines, strip;

import app.keymap : StudioAction, StudioCommandSink;
import app.pattern_notes : addNote, deleteNotes, moveNotes, NoteEdit, noteEditMessage, notesOf, PatternGrid,
    resizeNote, RollNote, setNoteVelocity;
import foundation.types : ModuleId;
import gui.renderer : ColorRGBA, FontId, IRenderer2D, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.views.piano_view : isBlackKey;
import gui.views.studio_context : StudioContext;
import gui.widgets : Dropdown, hasModifier, KeyCode, KeyEvent, MenuItem, MouseButton, MouseEvent, ScrollEvent, Widget;
import io.project_format : SavedPattern;
import platform.interfaces : KeyModifiers;
import sequencer.note : NoteCell;

private struct NoteKey {
    uint track = 0;
    uint line = 0;
}

private struct ClipNote {
    uint relLine = 0;
    uint length = 1;
    ubyte pitch = 60;
    ubyte velByte = 0;
    ushort paramId = 0;
    ubyte effect = 0;
    ubyte effectVal = 0;
}

/**
 * Interactive piano roll widget hosted inside PatternEditorView.
 */
final class PianoRollView : Widget, StudioCommandSink {
    enum float BAR_H = 28.0f;
    enum float RULER_H = 18.0f;
    enum float KEYS_W = 54.0f;
    enum float VELOCITY_H = 56.0f;
    enum float EDGE_GRAB_W = 6.0f;
    enum float DEFAULT_LINE_W = 24.0f;
    enum float MIN_LINE_W = 6.0f;
    enum float MAX_LINE_W = 96.0f;
    enum float DEFAULT_ROW_H = 14.0f;
    enum float MIN_ROW_H = 6.0f;
    enum float MAX_ROW_H = 32.0f;
    enum uint MIDI_COUNT = 128;
    enum string ROLL_CLIP_MAGIC = "DRACKER-ROLL-V1";
    private enum uint AUDITION_TAG_BASE = 0x524F_0000u;

    private enum DragMode : ubyte {
        none = 0,
        keyAudition = 1,
        emptyPending = 2,
        marquee = 3,
        move = 4,
        copyMove = 5,
        resize = 6,
        velocity = 7
    }

    StudioContext ctx;
    Dropdown modulePicker;

    private uint pickedModule_ = 0;
    private uint[] pickerModuleIds_;
    private float scrollX_ = 0.0f;
    private float scrollY_ = 0.0f;
    private float lineW_ = DEFAULT_LINE_W;
    private float rowH_ = DEFAULT_ROW_H;
    private uint shownPattern_ = 0;
    private bool needsAutoScroll_ = true;
    private ulong cacheDocRev_ = 0;
    private ulong cacheSelRev_ = 0;
    private uint cachePatId_ = 0;
    private RollNote[] notes_;
    private long lastDrawnPlayLine_ = -1;

    private NoteKey[] selected_;
    private uint lastNoteLen_ = 0;
    private float lastVel_ = 0.8f;
    private uint lastClickLine_ = 0;
    private bool hasClickLine_ = false;
    private string localClipboard_;

    private DragMode drag_ = DragMode.none;
    private Point2F pressPos_;
    private Point2F dragPos_;
    private bool dragMoved_ = false;
    private bool dragAdditive_ = false;
    private int pressLine_ = 0;
    private int pressPitch_ = 60;
    private RollNote[] dragNotes_;
    private RollNote resizeTarget_;
    private int dragDLine_ = 0;
    private int dragDPitch_ = 0;
    private uint resizeNewLen_ = 1;
    private float[NoteKey] velPreview_;

    private bool auditionActive_ = false;
    private uint auditionMod_ = 0;
    private ubyte auditionPitch_ = 0;
    private size_t auditionCount_ = 0;
    private ubyte lastAuditionedPitch_ = 0;

    /**
     * Creates the piano roll view and its module picker.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        assert(ctx !is null, "PianoRollView requires a StudioContext");
        this.ctx = ctx;
        id = "pattern.pianoRoll";
        focusable = true;
        modulePicker = add(new Dropdown(null, 0, &onModulePicked));
        modulePicker.id = "pianoRoll.module";
        contextMenuProvider = &buildContextMenu;
        update();
    }

    /**
     * Returns the currently picked module id (0 when the project has no instrument/effect modules).
     *
     * Returns:
     *   Module id.
     */
    uint pickedModule() const {
        return pickedModule_;
    }

    /**
     * Selects a module in the picker (if present) and syncs StudioContext.selectModule().
     *
     * Params:
     *   moduleId = Module id.
     *
     * Returns:
     *   True if moduleId is in the picker.
     */
    bool selectPickedModule(uint moduleId) {
        syncPicker();
        foreach (i, mid; pickerModuleIds_) {
            if (mid == moduleId) {
                pickedModule_ = moduleId;
                modulePicker.selectedIndex = i;
                selected_ = null;
                ctx.selectModule(moduleId);
                invalidate();
                return true;
            }
        }
        return false;
    }

    /**
     * Returns the module-picker bar rectangle at the top of the view.
     *
     * Returns:
     *   Rectangle in window coordinates.
     */
    RectF barRect() const {
        return RectF(bounds.x, bounds.y, bounds.w, BAR_H < bounds.h ? BAR_H : (bounds.h > 0.0f ? bounds.h : 0.0f));
    }

    /**
     * Returns the bar-number ruler rectangle above the note grid.
     *
     * Returns:
     *   Rectangle in window coordinates.
     */
    RectF rulerRect() const {
        immutable float kw = KEYS_W < bounds.w ? KEYS_W : bounds.w;
        immutable float gw = bounds.w > kw ? bounds.w - kw : 0.0f;
        immutable float availH = bounds.h > BAR_H ? bounds.h - BAR_H : 0.0f;
        immutable float rh = RULER_H < availH ? RULER_H : availH;
        return RectF(bounds.x + kw, bounds.y + BAR_H, gw, rh);
    }

    /**
     * Returns the velocity strip rectangle beneath the note grid.
     *
     * Returns:
     *   Rectangle in window coordinates (height 0 when the view is too short).
     */
    RectF velocityRect() const {
        immutable float vh = velocityHeight();
        immutable float kw = KEYS_W < bounds.w ? KEYS_W : bounds.w;
        immutable float gw = bounds.w > kw ? bounds.w - kw : 0.0f;
        return RectF(bounds.x + kw, bounds.bottom() - vh, gw, vh);
    }

    /**
     * Returns the piano keys column rectangle.
     *
     * Returns:
     *   Rectangle in window coordinates.
     */
    RectF keysRect() const {
        immutable float top = bounds.y + BAR_H + RULER_H;
        immutable float h = bounds.bottom() - velocityHeight() - top;
        immutable float kw = KEYS_W < bounds.w ? KEYS_W : bounds.w;
        return RectF(bounds.x, top, kw, h > 0.0f ? h : 0.0f);
    }

    /**
     * Returns the note grid rectangle.
     *
     * Returns:
     *   Rectangle in window coordinates.
     */
    RectF gridRect() const {
        immutable float kw = KEYS_W < bounds.w ? KEYS_W : bounds.w;
        immutable float top = bounds.y + BAR_H + RULER_H;
        immutable float h = bounds.bottom() - velocityHeight() - top;
        return RectF(bounds.x + kw, top, bounds.w > kw ? bounds.w - kw : 0.0f, h > 0.0f ? h : 0.0f);
    }

    /**
     * Returns the velocity bar rectangle for a note inside velocityRect().
     *
     * Params:
     *   n = RollNote.
     *
     * Returns:
     *   Bar rectangle in window coordinates.
     */
    RectF velocityBarRect(const ref RollNote n) const {
        immutable RectF vr = velocityRect();
        immutable float x = lineToX(cast(float) n.line);
        immutable float bw = lineW_ * 0.45f < 8.0f ? (lineW_ * 0.45f > 4.0f ? lineW_ * 0.45f : 4.0f) : 8.0f;
        float v = n.velocity;
        if (auto pv = NoteKey(n.track, n.line) in velPreview_) {
            v = *pv;
        }
        v = v < 0.05f ? 0.05f : (v > 1.0f ? 1.0f : v);
        immutable float usable = vr.h > 8.0f ? vr.h - 8.0f : vr.h;
        immutable float bh = usable * v;
        return RectF(x + 2.0f, vr.bottom() - 2.0f - bh, bw, bh);
    }

    /**
     * Maps a pattern line index to a window x coordinate.
     *
     * Params:
     *   line = Line position (0-based).
     *
     * Returns:
     *   Window x.
     */
    float lineToX(float line) const {
        return gridRect().x + line * lineW_ - scrollX_;
    }

    /**
     * Maps a window x coordinate to a fractional pattern line index.
     *
     * Params:
     *   x = Window x.
     *
     * Returns:
     *   Fractional line.
     */
    float xToLine(float x) const {
        return (x - gridRect().x + scrollX_) / lineW_;
    }

    /**
     * Maps a MIDI pitch (0..127, 127 at top) to the top y coordinate of its row.
     *
     * Params:
     *   pitch = MIDI pitch 0..127.
     *
     * Returns:
     *   Window y.
     */
    float pitchToY(ubyte pitch) const {
        return gridRect().y + cast(float)(127 - cast(int) pitch) * rowH_ - scrollY_;
    }

    /**
     * Maps a window y coordinate to a MIDI pitch (clamped to 0..127).
     *
     * Params:
     *   y = Window y.
     *
     * Returns:
     *   MIDI pitch 0..127.
     */
    int yToPitch(float y) const {
        immutable int p = 127 - cast(int) floor((y - gridRect().y + scrollY_) / rowH_);
        return p < 0 ? 0 : (p > 127 ? 127 : p);
    }

    /**
     * Returns the window rectangle of one key in the piano keys column.
     *
     * Params:
     *   midi = MIDI pitch 0..127.
     *
     * Returns:
     *   Key rectangle.
     */
    RectF keyRect(ubyte midi) const {
        immutable RectF kr = keysRect();
        return RectF(kr.x, pitchToY(midi), kr.w, rowH_);
    }

    /**
     * Returns the window rectangle of a roll note.
     *
     * Params:
     *   n = RollNote.
     *
     * Returns:
     *   Note rectangle.
     */
    RectF noteRect(const ref RollNote n) const {
        immutable float x = lineToX(cast(float) n.line) + 0.5f;
        immutable float rawW = cast(float) n.length * lineW_;
        immutable float w = rawW > 2.0f ? rawW - 1.0f : (rawW > 1.0f ? rawW : 1.0f);
        immutable float y = pitchToY(n.pitch) + 1.0f;
        immutable float h = rowH_ > 3.0f ? rowH_ - 2.0f : rowH_;
        return RectF(x, y, w, h);
    }

    /**
     * Returns the cached notes of the current pattern.
     *
     * Returns:
     *   Notes slice.
     */
    const(RollNote)[] notes() {
        syncNotesAndPicker();
        return notes_;
    }

    /**
     * Returns the currently selected notes of the picked module.
     *
     * Returns:
     *   Selected RollNote array.
     */
    RollNote[] selectedNotes() {
        syncNotesAndPicker();
        RollNote[] outList;
        foreach (ref n; notes_) {
            if (n.moduleId == pickedModule_ && isSelectedKey(NoteKey(n.track, n.line))) {
                outList ~= n;
            }
        }
        return outList;
    }

    /**
     * Reports whether at least one note of the picked module is selected.
     *
     * Returns:
     *   True if selection is non-empty.
     */
    bool hasSelection() {
        return selectedNotes().length > 0;
    }

    /**
     * Clears the current note selection.
     */
    void clearSelection() {
        selected_ = null;
        invalidate();
    }

    /**
     * Selects every note of the picked module in the current pattern.
     */
    void selectAll() {
        syncNotesAndPicker();
        selected_ = null;
        foreach (ref n; notes_) {
            if (n.moduleId == pickedModule_) {
                selected_ ~= NoteKey(n.track, n.line);
            }
        }
        invalidate();
    }

    /**
     * Returns the default length in lines used for newly added notes (last edited length, or one beat initially).
     *
     * Returns:
     *   Length in lines (>= 1).
     */
    uint lastNoteLength() const {
        if (lastNoteLen_ > 0) {
            return lastNoteLen_;
        }
        immutable uint beat = ctx.session.linesPerBeat();
        return beat > 0 ? beat : 4;
    }

    /**
     * Returns the velocity used for newly added notes.
     *
     * Returns:
     *   Velocity in (0, 1].
     */
    float lastVelocity() const {
        return lastVel_;
    }

    /**
     * Returns how many note auditions have been triggered from this view.
     *
     * Returns:
     *   Audition trigger count.
     */
    size_t auditionCount() const {
        return auditionCount_;
    }

    /**
     * Returns the most recently auditioned MIDI pitch.
     *
     * Returns:
     *   MIDI pitch 0..127.
     */
    ubyte lastAuditionedPitch() const {
        return lastAuditionedPitch_;
    }

    /**
     * Returns the horizontal zoom in points per line.
     *
     * Returns:
     *   Line width.
     */
    float lineWidth() const {
        return lineW_;
    }

    /**
     * Returns the vertical zoom in points per semitone row.
     *
     * Returns:
     *   Row height.
     */
    float rowHeight() const {
        return rowH_;
    }

    /**
     * Returns the horizontal scroll offset in points.
     *
     * Returns:
     *   Horizontal scroll.
     */
    float scrollX() const {
        return scrollX_;
    }

    /**
     * Returns the vertical scroll offset in points.
     *
     * Returns:
     *   Vertical scroll.
     */
    float scrollY() const {
        return scrollY_;
    }

    /**
     * Sets scroll offsets, clamped to the grid content.
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
        needsAutoScroll_ = false;
        invalidate();
    }

    /**
     * Sets horizontal and vertical zoom directly (clamped).
     *
     * Params:
     *   newLineW = Points per line.
     *   newRowH = Points per semitone row.
     */
    void setZoom(float newLineW, float newRowH) {
        lineW_ = clampLineW(newLineW);
        rowH_ = clampRowH(newRowH);
        clampScroll();
        invalidate();
    }

    /**
     * Zooms horizontally and/or vertically keeping the line and pitch under anchor fixed.
     *
     * Params:
     *   anchor = Anchor point in window coordinates.
     *   newLineW = New line width.
     *   newRowH = New row height.
     */
    void zoomAround(Point2F anchor, float newLineW, float newRowH) {
        immutable RectF gr = gridRect();
        immutable float lineAt = gr.w > 0.0f ? (anchor.x - gr.x + scrollX_) / lineW_ : 0.0f;
        immutable float pitchAt = gr.h > 0.0f ? (anchor.y - gr.y + scrollY_) / rowH_ : 0.0f;
        lineW_ = clampLineW(newLineW);
        rowH_ = clampRowH(newRowH);
        scrollX_ = lineAt * lineW_ - (anchor.x - gr.x);
        scrollY_ = pitchAt * rowH_ - (anchor.y - gr.y);
        clampScroll();
        needsAutoScroll_ = false;
        invalidate();
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
        const sp = currentPatternDoc();
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
     * Syncs notes, picker, auto-scroll, and follow-playhead state.
     */
    void update() {
        syncNotesAndPicker();
        if (needsAutoScroll_ && gridRect().h > 0.0f && gridRect().w > 0.0f) {
            scrollToNotes();
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
        case StudioAction.zoomIn:
            zoomAround(gridRect().center(), lineW_ * 1.25f, rowH_);
            return true;
        case StudioAction.zoomOut:
            zoomAround(gridRect().center(), lineW_ / 1.25f, rowH_);
            return true;
        case StudioAction.zoomReset:
            zoomAround(gridRect().center(), DEFAULT_LINE_W, DEFAULT_ROW_H);
            return true;
        case StudioAction.toggleFollow:
            ctx.followPlayhead = !ctx.followPlayhead;
            ctx.setStatus(ctx.followPlayhead ? "Follow on" : "Follow off");
            invalidate();
            return true;
        case StudioAction.nextPattern:
            return stepPattern(1);
        case StudioAction.prevPattern:
            return stepPattern(-1);
        case StudioAction.selectAll:
            selectAll();
            return true;
        case StudioAction.deleteCell:
        case StudioAction.deleteBlock:
            return deleteSelectedNotes();
        case StudioAction.copy:
            return copySelectedNotes();
        case StudioAction.cut:
            return cutSelectedNotes();
        case StudioAction.paste:
            return pasteNotes();
        case StudioAction.transposeSemitoneUp:
            return transposeNotes(1);
        case StudioAction.transposeSemitoneDown:
            return transposeNotes(-1);
        case StudioAction.transposeOctaveUp:
            return transposeNotes(12);
        case StudioAction.transposeOctaveDown:
            return transposeNotes(-12);
        default:
            return false;
        }
    }

    override void layoutChildren() {
        immutable RectF br = barRect();
        immutable float ch = ctx.theme.controlHeight < br.h - 4.0f ? ctx.theme.controlHeight
            : (br.h > 4.0f ? br.h - 4.0f : br.h);
        immutable float py = br.y + (br.h - ch) * 0.5f;
        modulePicker.arrange(RectF(br.x + 60.0f, py, 190.0f, ch));
        if (needsAutoScroll_ && gridRect().h > 0.0f && gridRect().w > 0.0f) {
            scrollToNotes();
        }
        clampScroll();
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        syncNotesAndPicker();
        if (auto ui = context()) {
            ui.setFocus(this);
        }
        immutable RectF kr = keysRect();
        if (kr.contains(e.pos)) {
            immutable ubyte p = cast(ubyte) yToPitch(e.pos.y);
            drag_ = DragMode.keyAudition;
            pressPitch_ = p;
            auditionNote(p, lastVel_);
            invalidate();
            return true;
        }
        immutable RectF vr = velocityRect();
        if (!vr.isEmpty() && vr.contains(e.pos)) {
            drag_ = DragMode.velocity;
            pressPos_ = e.pos;
            dragPos_ = e.pos;
            velPreview_ = null;
            applyVelocityAt(e.pos);
            invalidate();
            return true;
        }
        immutable RectF rr = rulerRect();
        if (rr.contains(e.pos)) {
            const sp = currentPatternDoc();
            if (sp !is null && sp.lines > 0) {
                int ln = cast(int) floor(xToLine(e.pos.x));
                if (ln < 0) ln = 0;
                if (ln >= cast(int) sp.lines) ln = cast(int) sp.lines - 1;
                lastClickLine_ = cast(uint) ln;
                hasClickLine_ = true;
            }
            return true;
        }
        immutable RectF gr = gridRect();
        if (!gr.contains(e.pos)) {
            return false;
        }
        const sp = currentPatternDoc();
        if (sp is null || sp.lines == 0) {
            return true;
        }
        pressPos_ = e.pos;
        dragPos_ = e.pos;
        dragMoved_ = false;
        dragDLine_ = 0;
        dragDPitch_ = 0;
        int clickedLine = cast(int) floor(xToLine(e.pos.x));
        if (clickedLine >= 0 && clickedLine < cast(int) sp.lines) {
            lastClickLine_ = cast(uint) clickedLine;
            hasClickLine_ = true;
        }
        pressLine_ = clickedLine;
        pressPitch_ = yToPitch(e.pos.y);

        size_t hitIdx = 0;
        bool onEdge = false;
        if (hitNote(e.pos, hitIdx, onEdge)) {
            immutable RollNote hit = notes_[hitIdx];
            immutable NoteKey key = NoteKey(hit.track, hit.line);
            if (onEdge && !hasModifier(e.modifiers, KeyModifiers.alt) && !hasModifier(e.modifiers, KeyModifiers.shift)) {
                selected_ = [key];
                drag_ = DragMode.resize;
                resizeTarget_ = hit;
                resizeNewLen_ = hit.length;
                auditionNote(hit.pitch, hit.velocity);
                invalidate();
                return true;
            }
            if (hasModifier(e.modifiers, KeyModifiers.shift)) {
                toggleSelectKey(key);
            } else if (!isSelectedKey(key)) {
                selected_ = [key];
            }
            dragNotes_ = selectedNotes();
            drag_ = hasModifier(e.modifiers, KeyModifiers.alt) ? DragMode.copyMove : DragMode.move;
            auditionNote(hit.pitch, hit.velocity);
            invalidate();
            return true;
        }

        dragAdditive_ = hasModifier(e.modifiers, KeyModifiers.shift);
        drag_ = DragMode.emptyPending;
        invalidate();
        return true;
    }

    override bool onMouseMove(const ref MouseEvent e) {
        if (drag_ == DragMode.none) {
            return false;
        }
        dragPos_ = e.pos;
        if (drag_ == DragMode.keyAudition) {
            immutable ubyte p = cast(ubyte) yToPitch(e.pos.y);
            if (!auditionActive_ || auditionPitch_ != p) {
                auditionNote(p, lastVel_);
            }
            invalidate();
            return true;
        }
        if (drag_ == DragMode.velocity) {
            applyVelocityAt(e.pos);
            invalidate();
            return true;
        }
        if (drag_ == DragMode.emptyPending) {
            if (abs(e.pos.x - pressPos_.x) >= 4.0f || abs(e.pos.y - pressPos_.y) >= 4.0f) {
                drag_ = DragMode.marquee;
                dragMoved_ = true;
            }
            invalidate();
            return true;
        }
        if (drag_ == DragMode.marquee) {
            invalidate();
            return true;
        }
        if (drag_ == DragMode.move || drag_ == DragMode.copyMove) {
            immutable int curLine = cast(int) floor(xToLine(e.pos.x));
            immutable int curPitch = yToPitch(e.pos.y);
            immutable int nextDL = curLine - pressLine_;
            immutable int nextDP = curPitch - pressPitch_;
            if (nextDL != 0 || nextDP != 0) {
                dragMoved_ = true;
            }
            if (nextDP != dragDPitch_ && dragNotes_.length > 0) {
                int np = cast(int) dragNotes_[0].pitch + nextDP;
                if (np >= 0 && np <= 127) {
                    auditionNote(cast(ubyte) np, dragNotes_[0].velocity);
                }
            }
            dragDLine_ = nextDL;
            dragDPitch_ = nextDP;
            invalidate();
            return true;
        }
        if (drag_ == DragMode.resize) {
            const sp = currentPatternDoc();
            if (sp !is null) {
                immutable int curLine = cast(int) floor(xToLine(e.pos.x));
                immutable int delta = curLine - pressLine_;
                if (delta != 0) {
                    dragMoved_ = true;
                }
                int newLen = cast(int) resizeTarget_.length + delta;
                if (newLen < 1) {
                    newLen = 1;
                }
                immutable int maxLen = cast(int) sp.lines - cast(int) resizeTarget_.line;
                if (maxLen > 0 && newLen > maxLen) {
                    newLen = maxLen;
                }
                resizeNewLen_ = cast(uint) newLen;
            }
            invalidate();
            return true;
        }
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        if (drag_ == DragMode.none) {
            return false;
        }
        dragPos_ = e.pos;
        immutable DragMode mode = drag_;
        drag_ = DragMode.none;
        stopAudition();

        final switch (mode) {
        case DragMode.none:
        case DragMode.keyAudition:
            break;
        case DragMode.emptyPending:
            addNoteAt(pressLine_, pressPitch_);
            break;
        case DragMode.marquee:
            selectInMarquee(marqueeRect(), dragAdditive_);
            break;
        case DragMode.move:
            if (dragMoved_ && (dragDLine_ != 0 || dragDPitch_ != 0)) {
                commitMove(dragNotes_, dragDLine_, dragDPitch_);
            }
            break;
        case DragMode.copyMove:
            if (dragMoved_ && (dragDLine_ != 0 || dragDPitch_ != 0)) {
                commitCopy(dragNotes_, dragDLine_, dragDPitch_);
            }
            break;
        case DragMode.resize:
            if (resizeNewLen_ != resizeTarget_.length) {
                commitResize(resizeTarget_, resizeNewLen_);
            }
            break;
        case DragMode.velocity:
            commitVelocityPreview();
            break;
        }
        dragNotes_ = null;
        velPreview_ = null;
        dragMoved_ = false;
        invalidate();
        return true;
    }

    override void onCaptureLost() {
        cancelDrag();
    }

    override bool onKeyDown(const ref KeyEvent e) {
        if (e.keyCode == KeyCode.escape) {
            if (drag_ != DragMode.none) {
                cancelDrag();
                return true;
            }
            if (selected_.length > 0) {
                clearSelection();
                return true;
            }
            return false;
        }
        if (e.keyCode == KeyCode.deleteBackward || e.keyCode == KeyCode.forwardDelete) {
            return deleteSelectedNotes();
        }
        if (hasModifier(e.modifiers, KeyModifiers.command)) {
            if (e.keyCode == KeyCode.a) {
                selectAll();
                return true;
            }
            if (e.keyCode == 8) {
                return copySelectedNotes();
            }
            if (e.keyCode == 7) {
                return cutSelectedNotes();
            }
            if (e.keyCode == 9) {
                return pasteNotes();
            }
            if (e.keyCode == KeyCode.up) {
                return transposeNotes(hasModifier(e.modifiers, KeyModifiers.shift) ? 12 : 1);
            }
            if (e.keyCode == KeyCode.down) {
                return transposeNotes(hasModifier(e.modifiers, KeyModifiers.shift) ? -12 : -1);
            }
        }
        return false;
    }

    override bool onScroll(const ref ScrollEvent e) {
        if (!bounds.contains(e.pos)) {
            return false;
        }
        if (hasModifier(e.modifiers, KeyModifiers.command)) {
            immutable float factor = exp(e.deltaY * 0.01f);
            if (hasModifier(e.modifiers, KeyModifiers.shift)) {
                zoomAround(e.pos, lineW_, rowH_ * factor);
            } else {
                zoomAround(e.pos, lineW_ * factor, rowH_);
            }
            return true;
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
        needsAutoScroll_ = false;
        invalidate();
        return true;
    }

    override bool onMagnify(Point2F pos, float magnification) {
        if (!isFinite(magnification) || !bounds.contains(pos)) {
            return false;
        }
        immutable float factor = 1.0f + magnification;
        zoomAround(pos, lineW_ * factor, rowH_ * factor);
        return true;
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        update();
        const sp = currentPatternDoc();
        immutable RectF br = barRect();
        immutable RectF rr = rulerRect();
        immutable RectF kr = keysRect();
        immutable RectF gr = gridRect();
        immutable RectF vr = velocityRect();
        immutable uint beat = ctx.session.linesPerBeat();
        immutable uint bar = ctx.session.linesPerBar();
        immutable long play = playheadLocalLine();

        r.pushClip(bounds);
        r.fillRect(br, theme.panel);
        r.fillRect(RectF(br.x, br.bottom() - 1.0f, br.w, 1.0f), theme.border);
        immutable float blh = r.lineHeight(FontId.ui, theme.fontSizeSmall);
        r.drawText(Point2F(br.x + 8.0f, br.y + (br.h - blh) * 0.5f), "Module", FontId.ui, theme.fontSizeSmall,
            theme.textDim);
        if (sp !is null) {
            char[64] infoBuf;
            const(char)[] info = sformat(infoBuf[], "%d/%d · %d lines",
                ctx.session.timeSignatureNumerator(), ctx.session.timeSignatureDenominator(), sp.lines);
            r.drawText(Point2F(modulePicker.bounds.right() + 12.0f, br.y + (br.h - blh) * 0.5f),
                info, FontId.ui, theme.fontSizeSmall, theme.textDim);
        }

        immutable float kw = KEYS_W < bounds.w ? KEYS_W : bounds.w;
        r.fillRect(RectF(bounds.x, bounds.y + BAR_H, kw, RULER_H), theme.panelSunken);
        r.fillRect(RectF(bounds.x, bounds.y + BAR_H + RULER_H - 1.0f, kw, 1.0f), theme.border);

        paintRuler(r, theme, rr, sp, beat, bar, play);
        paintKeys(r, theme, kr);
        paintGrid(r, theme, gr, sp, beat, bar, play);
        if (!vr.isEmpty()) {
            r.fillRect(RectF(bounds.x, vr.y, kw, vr.h), theme.panelSunken);
            r.fillRect(RectF(bounds.x, vr.y, kw, 1.0f), theme.border);
            r.fillRect(RectF(bounds.x + kw - 1.0f, vr.y, 1.0f, vr.h), theme.border);
            r.drawText(Point2F(bounds.x + 6.0f, vr.y + (vr.h - blh) * 0.5f), "Vel", FontId.ui, theme.fontSizeSmall,
                theme.textDim);
            paintVelocityStrip(r, theme, vr, sp, beat, bar);
        }

        if (isFocused()) {
            r.strokeRoundedRect(bounds.inset(0.5f), 0.0f, 1.0f, theme.focusRing);
        }
        r.popClip();
    }

    private float velocityHeight() const {
        return bounds.h > BAR_H + RULER_H + 100.0f ? VELOCITY_H : 0.0f;
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
            int l0 = cast(int) floor(xToLine(rr.x));
            int l1 = cast(int) ceil(xToLine(rr.right()));
            if (l0 < 0) l0 = 0;
            if (l1 > cast(int) sp.lines) l1 = cast(int) sp.lines;
            char[16] buf;
            foreach (l; l0 .. l1 + 1) {
                immutable float x = lineToX(cast(float) l);
                if (l % bar == 0) {
                    r.fillRect(RectF(x, rr.y, 1.0f, rr.h), theme.borderStrong);
                    if (l < cast(int) sp.lines) {
                        const(char)[] label = sformat(buf[], "%d", l / bar + 1);
                        r.drawText(Point2F(x + 3.0f, rr.y + (rr.h - lh) * 0.5f), label, FontId.mono,
                            theme.fontSizeSmall, theme.text);
                    }
                } else if (beat > 0 && l % beat == 0) {
                    r.fillRect(RectF(x, rr.bottom() - 5.0f, 1.0f, 5.0f), theme.border);
                }
            }
        }
        if (play >= 0) {
            immutable float px = lineToX(cast(float) play);
            r.fillRect(RectF(px - 3.0f, rr.y, 6.0f, 5.0f), theme.danger);
            r.fillRect(RectF(px, rr.y, 2.0f, rr.h), theme.danger);
        }
        r.popClip();
    }

    private void paintKeys(IRenderer2D r, const ref StudioTheme theme, RectF kr) {
        if (kr.isEmpty()) {
            return;
        }
        r.pushClip(kr);
        r.fillRect(kr, theme.pianoWhiteKey);
        int topPitch = yToPitch(kr.y) + 1;
        int botPitch = yToPitch(kr.bottom()) - 1;
        if (topPitch > 127) topPitch = 127;
        if (botPitch < 0) botPitch = 0;
        immutable float slh = r.lineHeight(FontId.mono, theme.fontSizeSmall);
        char[8] buf;
        for (int p = botPitch; p <= topPitch; p++) {
            immutable ubyte midi = cast(ubyte) p;
            immutable RectF row = keyRect(midi);
            immutable bool black = isBlackKey(midi);
            immutable bool held = auditionActive_ && auditionPitch_ == midi;
            r.fillRect(row, held ? theme.rollNoteSelected : theme.pianoWhiteKey);
            if (black) {
                immutable RectF blackBox = RectF(row.x, row.y + 0.5f, row.w * 0.65f,
                    row.h > 1.0f ? row.h - 1.0f : row.h);
                r.fillRect(blackBox, held ? theme.accent : theme.pianoBlackKey);
                r.fillRect(RectF(row.x, row.bottom() - 1.0f, row.w, 1.0f), theme.gridLine);
            } else {
                r.fillRect(RectF(row.x, row.bottom() - 1.0f, row.w, 1.0f),
                    (midi % 12 == 0) ? theme.pianoKeyBorder : theme.border);
            }
            if (midi % 12 == 0 && rowH_ >= 8.0f) {
                immutable int oct = cast(int)(midi / 12) - 1;
                const(char)[] label = oct < 0 ? "C-" : sformat(buf[], "C%d", oct);
                immutable float tw = r.measureText(label, FontId.mono, theme.fontSizeSmall);
                r.drawText(Point2F(row.right() - tw - 4.0f, row.y + (row.h - slh) * 0.5f),
                    label, FontId.mono, theme.fontSizeSmall, theme.pianoKeyText);
            }
        }
        r.fillRect(RectF(kr.right() - 1.0f, kr.y, 1.0f, kr.h), theme.pianoKeyBorder);
        r.popClip();
    }

    private void paintGrid(IRenderer2D r, const ref StudioTheme theme, RectF gr, const(SavedPattern)* sp,
            uint beat, uint bar, long play) {
        if (gr.isEmpty()) {
            return;
        }
        r.pushClip(gr);
        r.fillRect(gr, theme.trackerBackground);
        int topPitch = yToPitch(gr.y) + 1;
        int botPitch = yToPitch(gr.bottom()) - 1;
        if (topPitch > 127) topPitch = 127;
        if (botPitch < 0) botPitch = 0;
        for (int p = botPitch; p <= topPitch; p++) {
            immutable ubyte midi = cast(ubyte) p;
            immutable RectF row = RectF(gr.x, pitchToY(midi), gr.w, rowH_);
            if (isBlackKey(midi)) {
                r.fillRect(row, theme.trackerRowBeat);
            }
            r.fillRect(RectF(gr.x, row.bottom() - 1.0f, gr.w, 1.0f),
                (midi % 12 == 0) ? theme.border : theme.gridLine);
        }
        if (sp !is null) {
            immutable float endX = lineToX(cast(float) sp.lines);
            if (endX < gr.right()) {
                immutable float ox = endX > gr.x ? endX : gr.x;
                r.fillRect(RectF(ox, gr.y, gr.right() - ox, gr.h), theme.panelSunken);
            }
            int l0 = cast(int) floor(xToLine(gr.x));
            int l1 = cast(int) ceil(xToLine(gr.right()));
            if (l0 < 0) l0 = 0;
            if (l1 > cast(int) sp.lines) l1 = cast(int) sp.lines;
            if (play >= 0 && play < cast(long) sp.lines) {
                immutable float px = lineToX(cast(float) play);
                r.fillRect(RectF(px, gr.y, lineW_, gr.h), theme.trackerPlayhead);
            }
            foreach (l; l0 .. l1 + 1) {
                immutable float x = lineToX(cast(float) l);
                if (bar > 0 && l % bar == 0) {
                    r.fillRect(RectF(x, gr.y, 2.0f, gr.h), theme.borderStrong);
                } else if (beat > 0 && l % beat == 0) {
                    r.fillRect(RectF(x, gr.y, 1.0f, gr.h), theme.border);
                } else {
                    r.fillRect(RectF(x, gr.y, 1.0f, gr.h), theme.gridLine);
                }
            }
            foreach (ref n; notes_) {
                if (n.moduleId == pickedModule_) {
                    continue;
                }
                immutable RectF nr = noteRect(n);
                if (!nr.intersect(gr).isEmpty()) {
                    r.strokeRoundedRect(nr, 2.0f, 1.5f, theme.borderStrong);
                }
            }
            foreach (ref n; notes_) {
                if (n.moduleId != pickedModule_) {
                    continue;
                }
                immutable bool sel = isSelectedKey(NoteKey(n.track, n.line));
                immutable RectF nr = noteRect(n);
                if (!nr.intersect(gr).isEmpty()) {
                    r.fillRoundedRect(nr, 2.0f, sel ? theme.rollNoteSelected : theme.rollNote);
                    r.strokeRoundedRect(nr, 2.0f, sel ? 2.0f : 1.0f, theme.borderStrong);
                }
            }
            if ((drag_ == DragMode.move || drag_ == DragMode.copyMove) && dragMoved_) {
                foreach (ref n; dragNotes_) {
                    immutable int nl = cast(int) n.line + dragDLine_;
                    immutable int np = cast(int) n.pitch + dragDPitch_;
                    if (nl >= 0 && nl < cast(int) sp.lines && np >= 0 && np <= 127) {
                        RollNote ghost = n;
                        ghost.line = cast(uint) nl;
                        ghost.pitch = cast(ubyte) np;
                        immutable RectF gnr = noteRect(ghost);
                        r.strokeRoundedRect(gnr, 2.0f, 2.0f, theme.accent);
                    }
                }
            } else if (drag_ == DragMode.resize) {
                RollNote ghost = resizeTarget_;
                ghost.length = resizeNewLen_;
                r.strokeRoundedRect(noteRect(ghost), 2.0f, 2.0f, theme.accent);
            } else if (drag_ == DragMode.marquee) {
                immutable RectF mr = marqueeRect();
                r.fillRect(mr, theme.selection);
                r.strokeRoundedRect(mr, 0.0f, 1.5f, theme.accent);
            }
            if (play >= 0 && play < cast(long) sp.lines) {
                immutable float px = lineToX(cast(float) play);
                r.fillRect(RectF(px, gr.y, 2.0f, gr.h), theme.danger);
            }
        }
        r.popClip();
    }

    private void paintVelocityStrip(IRenderer2D r, const ref StudioTheme theme, RectF vr, const(SavedPattern)* sp,
            uint beat, uint bar) {
        r.pushClip(vr);
        r.fillRect(vr, theme.panelSunken);
        r.fillRect(RectF(vr.x, vr.y, vr.w, 1.0f), theme.border);
        immutable float midY = vr.y + vr.h * 0.5f;
        r.fillRect(RectF(vr.x, midY, vr.w, 1.0f), theme.gridLine);
        if (sp !is null) {
            int l0 = cast(int) floor(xToLine(vr.x));
            int l1 = cast(int) ceil(xToLine(vr.right()));
            if (l0 < 0) l0 = 0;
            if (l1 > cast(int) sp.lines) l1 = cast(int) sp.lines;
            foreach (l; l0 .. l1 + 1) {
                immutable float x = lineToX(cast(float) l);
                if (bar > 0 && l % bar == 0) {
                    r.fillRect(RectF(x, vr.y, 1.0f, vr.h), theme.border);
                } else if (beat > 0 && l % beat == 0) {
                    r.fillRect(RectF(x, vr.y, 1.0f, vr.h), theme.gridLine);
                }
            }
            immutable bool filterSel = hasSelection();
            foreach (ref n; notes_) {
                if (n.moduleId != pickedModule_) {
                    continue;
                }
                immutable bool sel = isSelectedKey(NoteKey(n.track, n.line));
                if (filterSel && !sel) {
                    continue;
                }
                immutable RectF barR = velocityBarRect(n);
                if (!barR.intersect(vr).isEmpty()) {
                    r.fillRect(barR, sel ? theme.rollNoteSelected : theme.rollNote);
                    r.strokeRoundedRect(barR, 0.0f, 1.0f, theme.borderStrong);
                }
            }
        }
        r.popClip();
    }

    private RectF marqueeRect() const {
        immutable float x0 = pressPos_.x < dragPos_.x ? pressPos_.x : dragPos_.x;
        immutable float x1 = pressPos_.x < dragPos_.x ? dragPos_.x : pressPos_.x;
        immutable float y0 = pressPos_.y < dragPos_.y ? pressPos_.y : dragPos_.y;
        immutable float y1 = pressPos_.y < dragPos_.y ? dragPos_.y : pressPos_.y;
        return RectF(x0, y0, x1 - x0, y1 - y0);
    }

    private bool hitNote(Point2F p, out size_t idx, out bool onRightEdge) const {
        foreach_reverse (i, ref n; notes_) {
            if (n.moduleId != pickedModule_) {
                continue;
            }
            immutable RectF nr = noteRect(n);
            if (nr.contains(p)) {
                idx = i;
                immutable float edgeW = nr.w * 0.35f < EDGE_GRAB_W ? nr.w * 0.35f : EDGE_GRAB_W;
                onRightEdge = p.x >= nr.right() - edgeW;
                return true;
            }
        }
        return false;
    }

    private void addNoteAt(int line, int pitch) {
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        if (pickedModule_ == 0) {
            ctx.setStatus("Add an instrument module first");
            return;
        }
        if (line < 0 || line >= cast(int) sp.lines || pitch < 0 || pitch > 127) {
            ctx.setStatus(noteEditMessage(NoteEdit.outOfRange));
            return;
        }
        PatternGrid g = PatternGrid(sp.tracks, sp.lines, cellsCopy(sp));
        RollNote placed;
        immutable NoteEdit res = addNote(g, cast(ushort) pickedModule_, cast(ubyte) pitch, cast(uint) line,
            lastNoteLength(), lastVel_, placed);
        if (res != NoteEdit.ok) {
            ctx.setStatus(noteEditMessage(res));
            return;
        }
        if (commitGrid(sp, g, "Add Note")) {
            selected_ = [NoteKey(placed.track, placed.line)];
            auditionNote(placed.pitch, placed.velocity);
            stopAudition();
        }
    }

    private void commitMove(const(RollNote)[] moving, int dLine, int dPitch) {
        const sp = currentPatternDoc();
        if (sp is null || moving.length == 0) {
            return;
        }
        PatternGrid g = PatternGrid(sp.tracks, sp.lines, cellsCopy(sp));
        RollNote[] moved;
        immutable NoteEdit res = moveNotes(g, moving, dLine, dPitch, moved);
        if (res != NoteEdit.ok) {
            ctx.setStatus(noteEditMessage(res));
            return;
        }
        if (commitGrid(sp, g, "Move Notes")) {
            selected_ = null;
            foreach (ref m; moved) {
                selected_ ~= NoteKey(m.track, m.line);
            }
        }
    }

    private void commitCopy(const(RollNote)[] copying, int dLine, int dPitch) {
        const sp = currentPatternDoc();
        if (sp is null || copying.length == 0) {
            return;
        }
        PatternGrid g = PatternGrid(sp.tracks, sp.lines, cellsCopy(sp));
        NoteCell[] origCells = new NoteCell[copying.length];
        foreach (i, ref n; copying) {
            immutable int nl = cast(int) n.line + dLine;
            immutable int np = cast(int) n.pitch + dPitch;
            if (nl < 0 || nl >= cast(int) sp.lines || np < 0 || np > 127) {
                ctx.setStatus(noteEditMessage(NoteEdit.outOfRange));
                return;
            }
            origCells[i] = g.at(n.track, n.line);
        }
        RollNote[] placed;
        foreach (i, ref n; copying) {
            RollNote pn;
            immutable NoteEdit res = addNote(g, n.moduleId, cast(ubyte)(n.pitch + dPitch),
                cast(uint)(n.line + dLine), n.length, n.velocity, pn);
            if (res != NoteEdit.ok) {
                ctx.setStatus(noteEditMessage(res));
                return;
            }
            if (origCells[i].effect != 0 || origCells[i].effectVal != 0 || origCells[i].paramId != 0) {
                NoteCell* dst = &g.at(pn.track, pn.line);
                dst.effect = origCells[i].effect;
                dst.effectVal = origCells[i].effectVal;
                dst.paramId = origCells[i].paramId;
            }
            placed ~= pn;
        }
        if (commitGrid(sp, g, "Copy Notes")) {
            selected_ = null;
            foreach (ref pn; placed) {
                selected_ ~= NoteKey(pn.track, pn.line);
            }
        }
    }

    private void commitResize(RollNote target, uint newLength) {
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        PatternGrid g = PatternGrid(sp.tracks, sp.lines, cellsCopy(sp));
        RollNote resized;
        immutable NoteEdit res = resizeNote(g, target, newLength, resized);
        if (res != NoteEdit.ok) {
            ctx.setStatus(noteEditMessage(res));
            return;
        }
        if (commitGrid(sp, g, "Resize Note")) {
            lastNoteLen_ = resized.length;
            selected_ = [NoteKey(resized.track, resized.line)];
        }
    }

    private void applyVelocityAt(Point2F p) {
        immutable RectF vr = velocityRect();
        if (vr.isEmpty()) {
            return;
        }
        float v = (vr.bottom() - 2.0f - p.y) / (vr.h > 8.0f ? vr.h - 8.0f : vr.h);
        if (v < 0.05f) v = 0.05f;
        if (v > 1.0f) v = 1.0f;
        immutable bool filterSel = hasSelection();
        immutable float hitTol = lineW_ * 0.6f > 8.0f ? lineW_ * 0.6f : 8.0f;
        bool matched = false;
        foreach (ref n; notes_) {
            if (n.moduleId != pickedModule_) {
                continue;
            }
            immutable NoteKey key = NoteKey(n.track, n.line);
            if (filterSel && !isSelectedKey(key)) {
                continue;
            }
            immutable float barCx = lineToX(cast(float) n.line) + 4.0f;
            if (abs(p.x - barCx) <= hitTol) {
                velPreview_[key] = v;
                lastVel_ = v;
                matched = true;
            }
        }
        if (!matched && velPreview_.length == 0) {
            float bestDist = float.infinity;
            NoteKey bestKey;
            bool haveBest = false;
            foreach (ref n; notes_) {
                if (n.moduleId != pickedModule_) {
                    continue;
                }
                immutable NoteKey key = NoteKey(n.track, n.line);
                if (filterSel && !isSelectedKey(key)) {
                    continue;
                }
                immutable float dist = abs(p.x - (lineToX(cast(float) n.line) + 4.0f));
                if (dist < bestDist) {
                    bestDist = dist;
                    bestKey = key;
                    haveBest = true;
                }
            }
            if (haveBest && bestDist <= hitTol * 2.0f) {
                velPreview_[bestKey] = v;
                lastVel_ = v;
            }
        }
    }

    private void commitVelocityPreview() {
        if (velPreview_.length == 0) {
            return;
        }
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        PatternGrid g = PatternGrid(sp.tracks, sp.lines, cellsCopy(sp));
        bool any = false;
        foreach (ref n; notes_) {
            if (n.moduleId != pickedModule_) {
                continue;
            }
            if (auto pv = NoteKey(n.track, n.line) in velPreview_) {
                if (setNoteVelocity(g, n, *pv) == NoteEdit.ok) {
                    any = true;
                }
            }
        }
        if (any) {
            commitGrid(sp, g, "Edit Velocity");
        }
    }

    private void selectInMarquee(RectF mr, bool additive) {
        if (!additive) {
            selected_ = null;
        }
        foreach (ref n; notes_) {
            if (n.moduleId != pickedModule_) {
                continue;
            }
            if (!noteRect(n).intersect(mr).isEmpty()) {
                immutable NoteKey key = NoteKey(n.track, n.line);
                if (!isSelectedKey(key)) {
                    selected_ ~= key;
                }
            }
        }
    }

    private bool deleteSelectedNotes() {
        syncNotesAndPicker();
        RollNote[] sel = selectedNotes();
        if (sel.length == 0) {
            return false;
        }
        const sp = currentPatternDoc();
        if (sp is null) {
            return false;
        }
        PatternGrid g = PatternGrid(sp.tracks, sp.lines, cellsCopy(sp));
        immutable NoteEdit res = deleteNotes(g, sel);
        if (res != NoteEdit.ok) {
            ctx.setStatus(noteEditMessage(res));
            return true;
        }
        if (commitGrid(sp, g, "Delete Notes")) {
            selected_ = null;
        }
        return true;
    }

    private bool copySelectedNotes() {
        syncNotesAndPicker();
        RollNote[] sel = selectedNotes();
        const sp = currentPatternDoc();
        if (sp is null || sel.length == 0) {
            return false;
        }
        uint minLine = sel[0].line;
        foreach (ref n; sel) {
            if (n.line < minLine) minLine = n.line;
        }
        string text = ROLL_CLIP_MAGIC ~ "\n";
        foreach (ref n; sel) {
            immutable size_t idx = cast(size_t) n.line * sp.tracks + n.track;
            immutable NoteCell c = idx < sp.cells.length ? sp.cells[idx] : NoteCell.init;
            text ~= format("%d %d %d %d %d %d %d\n", n.line - minLine, n.length, n.pitch,
                c.velocity, c.paramId, c.effect, c.effectVal);
        }
        writeClipboard(text);
        return true;
    }

    private bool cutSelectedNotes() {
        if (!copySelectedNotes()) {
            return false;
        }
        return deleteSelectedNotes();
    }

    private bool pasteNotes() {
        syncNotesAndPicker();
        const sp = currentPatternDoc();
        if (sp is null || pickedModule_ == 0) {
            return false;
        }
        ClipNote[] clip;
        if (!decodeRollClipboard(readClipboard(), clip)) {
            ctx.setStatus("Paste: clipboard does not contain piano roll notes");
            return true;
        }
        immutable uint baseLine = pasteTargetLine(sp);
        PatternGrid g = PatternGrid(sp.tracks, sp.lines, cellsCopy(sp));
        RollNote[] placed;
        foreach (ref cn; clip) {
            immutable uint targetLine = baseLine + cn.relLine;
            if (targetLine >= sp.lines) {
                ctx.setStatus(noteEditMessage(NoteEdit.outOfRange));
                return true;
            }
            immutable float vel = cn.velByte > 0 ? cast(float)(cn.velByte - 1) / 254.0f : lastVel_;
            RollNote pn;
            immutable NoteEdit res = addNote(g, cast(ushort) pickedModule_, cn.pitch, targetLine, cn.length, vel, pn);
            if (res != NoteEdit.ok) {
                ctx.setStatus(noteEditMessage(res));
                return true;
            }
            NoteCell* dst = &g.at(pn.track, pn.line);
            if (cn.velByte != 0) {
                dst.velocity = cn.velByte;
            }
            dst.paramId = cn.paramId;
            dst.effect = cn.effect;
            dst.effectVal = cn.effectVal;
            placed ~= pn;
        }
        if (commitGrid(sp, g, "Paste Notes")) {
            selected_ = null;
            foreach (ref pn; placed) {
                selected_ ~= NoteKey(pn.track, pn.line);
            }
        }
        return true;
    }

    private bool transposeNotes(int semitones) {
        syncNotesAndPicker();
        const sp = currentPatternDoc();
        if (sp is null || pickedModule_ == 0) {
            return false;
        }
        RollNote[] targets = selectedNotes();
        immutable bool usedSelection = targets.length > 0;
        if (!usedSelection) {
            foreach (ref n; notes_) {
                if (n.moduleId == pickedModule_) {
                    targets ~= n;
                }
            }
        }
        if (targets.length == 0) {
            return false;
        }
        PatternGrid g = PatternGrid(sp.tracks, sp.lines, cellsCopy(sp));
        RollNote[] moved;
        immutable NoteEdit res = moveNotes(g, targets, 0, semitones, moved);
        if (res != NoteEdit.ok) {
            ctx.setStatus(noteEditMessage(res));
            return true;
        }
        if (commitGrid(sp, g, "Transpose Notes") && usedSelection) {
            selected_ = null;
            foreach (ref m; moved) {
                selected_ ~= NoteKey(m.track, m.line);
            }
        }
        return true;
    }

    private uint pasteTargetLine(const(SavedPattern)* sp) {
        immutable long play = playheadLocalLine();
        if (play >= 0 && play < cast(long) sp.lines) {
            return cast(uint) play;
        }
        RollNote[] sel = selectedNotes();
        if (sel.length > 0) {
            uint maxEnd = 0;
            foreach (ref n; sel) {
                if (n.line + n.length > maxEnd) {
                    maxEnd = n.line + n.length;
                }
            }
            return maxEnd < sp.lines ? maxEnd : 0;
        }
        if (hasClickLine_ && lastClickLine_ < sp.lines) {
            return lastClickLine_;
        }
        return 0;
    }

    private bool commitGrid(const(SavedPattern)* sp, const ref PatternGrid g, string label) {
        immutable uint prevTracks = sp.tracks;
        immutable uint pid = sp.patternId;
        if (!ctx.session.doReplacePatternGrid(pid, g.tracks, g.cells, label)) {
            return false;
        }
        if (g.tracks > prevTracks) {
            ctx.setStatus(format("Added track %d", g.tracks));
        }
        syncNotesAndPicker();
        invalidate();
        return true;
    }

    private static NoteCell[] cellsCopy(const(SavedPattern)* sp) {
        immutable size_t n = cast(size_t) sp.tracks * sp.lines;
        NoteCell[] c = new NoteCell[n];
        immutable size_t have = sp.cells.length < n ? sp.cells.length : n;
        c[0 .. have] = sp.cells[0 .. have];
        return c;
    }

    private void auditionNote(ubyte pitch, float vel) {
        if (pickedModule_ == 0) {
            return;
        }
        if (auditionActive_ && (auditionMod_ != pickedModule_ || auditionPitch_ != pitch)) {
            stopAudition();
        }
        immutable uint tag = AUDITION_TAG_BASE | pitch;
        ctx.session.triggerLiveNote(ModuleId(pickedModule_), tag, cast(float) pitch, vel);
        auditionActive_ = true;
        auditionMod_ = pickedModule_;
        auditionPitch_ = pitch;
        lastAuditionedPitch_ = pitch;
        auditionCount_++;
    }

    private void stopAudition() {
        if (!auditionActive_) {
            return;
        }
        immutable uint tag = AUDITION_TAG_BASE | auditionPitch_;
        ctx.session.releaseLiveNote(ModuleId(auditionMod_), tag);
        auditionActive_ = false;
    }

    private void cancelDrag() {
        stopAudition();
        drag_ = DragMode.none;
        dragNotes_ = null;
        velPreview_ = null;
        dragMoved_ = false;
        dragDLine_ = 0;
        dragDPitch_ = 0;
        invalidate();
    }

    private MenuItem[] buildContextMenu(Point2F p) {
        if (!gridRect().contains(p)) {
            return null;
        }
        MenuItem[] items;
        immutable bool hasSel = hasSelection();
        items ~= MenuItem("Cut", () { handleStudioAction(StudioAction.cut); }, hasSel, false, "Cmd+X");
        items ~= MenuItem("Copy", () { handleStudioAction(StudioAction.copy); }, hasSel, false, "Cmd+C");
        items ~= MenuItem("Paste", () { handleStudioAction(StudioAction.paste); }, true, false, "Cmd+V");
        items ~= MenuItem("Delete", () { handleStudioAction(StudioAction.deleteBlock); }, hasSel, false, "Del");
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem("Select All", () { handleStudioAction(StudioAction.selectAll); }, true, false, "Cmd+A");
        items ~= MenuItem("Transpose +1", () { handleStudioAction(StudioAction.transposeSemitoneUp); });
        items ~= MenuItem("Transpose -1", () { handleStudioAction(StudioAction.transposeSemitoneDown); });
        items ~= MenuItem("Transpose +12", () { handleStudioAction(StudioAction.transposeOctaveUp); });
        items ~= MenuItem("Transpose -12", () { handleStudioAction(StudioAction.transposeOctaveDown); });
        return items;
    }

    private void writeClipboard(string text) {
        localClipboard_ = text;
        if (ctx.clipboard !is null) {
            ctx.clipboard.setText(text);
        }
    }

    private string readClipboard() {
        if (ctx.clipboard !is null) {
            string t = ctx.clipboard.getText();
            if (t.length > 0) {
                return t;
            }
        }
        return localClipboard_;
    }

    private static bool decodeRollClipboard(string text, out ClipNote[] outNotes) {
        auto lines = splitLines(text);
        if (lines.length < 2 || strip(lines[0]) != ROLL_CLIP_MAGIC) {
            return false;
        }
        ClipNote[] parsed;
        foreach (ln; lines[1 .. $]) {
            immutable string trimmed = strip(ln);
            if (trimmed.length == 0) {
                continue;
            }
            auto parts = split(trimmed);
            if (parts.length < 7) {
                return false;
            }
            try {
                ClipNote cn;
                cn.relLine = to!uint(parts[0]);
                cn.length = to!uint(parts[1]);
                immutable uint p = to!uint(parts[2]);
                if (cn.length == 0 || p > 127) {
                    return false;
                }
                cn.pitch = cast(ubyte) p;
                cn.velByte = cast(ubyte) to!uint(parts[3]);
                cn.paramId = cast(ushort) to!uint(parts[4]);
                cn.effect = cast(ubyte) to!uint(parts[5]);
                cn.effectVal = cast(ubyte) to!uint(parts[6]);
                parsed ~= cn;
            } catch (Exception) {
                return false;
            }
        }
        if (parsed.length == 0) {
            return false;
        }
        sort!((a, b) => a.relLine < b.relLine || (a.relLine == b.relLine && a.pitch < b.pitch))(parsed);
        outNotes = parsed;
        return true;
    }

    private bool isSelectedKey(NoteKey k) const {
        foreach (ref s; selected_) {
            if (s == k) {
                return true;
            }
        }
        return false;
    }

    private void toggleSelectKey(NoteKey k) {
        foreach (i, ref s; selected_) {
            if (s == k) {
                selected_ = selected_[0 .. i] ~ selected_[i + 1 .. $];
                return;
            }
        }
        selected_ ~= k;
    }

    private const(SavedPattern)* currentPatternDoc() const {
        immutable uint pid = ctx.currentPattern();
        foreach (ref p; ctx.session.document().patterns) {
            if (p.patternId == pid) {
                return &p;
            }
        }
        return null;
    }

    private void syncNotesAndPicker() {
        immutable uint pid = ctx.currentPattern();
        immutable ulong dRev = ctx.documentRevision();
        immutable ulong sRev = ctx.selectionRevision();
        if (pid != shownPattern_) {
            shownPattern_ = pid;
            needsAutoScroll_ = true;
            selected_ = null;
            hasClickLine_ = false;
            cancelDrag();
        }
        if (dRev != cacheDocRev_ || pid != cachePatId_) {
            cacheDocRev_ = dRev;
            cachePatId_ = pid;
            const sp = currentPatternDoc();
            if (sp !is null) {
                PatternGrid g = PatternGrid(sp.tracks, sp.lines, cast(NoteCell[]) sp.cells);
                notes_ = notesOf(g);
            } else {
                notes_ = null;
            }
            pruneSelection();
        }
        if (sRev != cacheSelRev_ || dRev == cacheDocRev_) {
            cacheSelRev_ = sRev;
            syncPicker();
        }
    }

    private void pruneSelection() {
        if (selected_.length == 0) {
            return;
        }
        NoteKey[] kept;
        foreach (ref k; selected_) {
            foreach (ref n; notes_) {
                if (n.track == k.track && n.line == k.line) {
                    kept ~= k;
                    break;
                }
            }
        }
        selected_ = kept;
    }

    private void syncPicker() {
        const doc = ctx.session.document();
        uint[] ids;
        string[] labels;
        foreach (ref m; doc.modules) {
            if (m.id == 1 || m.typeId == "core.output") {
                continue;
            }
            ids ~= m.id;
            labels ~= m.name.length > 0 ? m.name : m.typeId;
        }
        pickerModuleIds_ = ids;
        modulePicker.items = labels;
        modulePicker.enabled = ids.length > 0;
        if (ids.length == 0) {
            pickedModule_ = 0;
            modulePicker.selectedIndex = 0;
            return;
        }
        bool pickedValid = false;
        foreach (mid; ids) {
            if (mid == pickedModule_) {
                pickedValid = true;
                break;
            }
        }
        immutable uint sel = ctx.selectedModule();
        if (!pickedValid) {
            pickedModule_ = chooseDefaultModule(ids, sel);
        } else if (sel != 0 && sel != pickedModule_) {
            foreach (mid; ids) {
                if (mid == sel) {
                    pickedModule_ = sel;
                    selected_ = null;
                    break;
                }
            }
        }
        foreach (i, mid; ids) {
            if (mid == pickedModule_) {
                modulePicker.selectedIndex = i;
                break;
            }
        }
    }

    private uint chooseDefaultModule(const(uint)[] ids, uint sel) const {
        if (sel != 0) {
            bool validSel = false;
            foreach (mid; ids) {
                if (mid == sel) validSel = true;
            }
            if (validSel) {
                foreach (ref n; notes_) {
                    if (n.moduleId == sel) {
                        return sel;
                    }
                }
            }
        }
        foreach (ref n; notes_) {
            foreach (mid; ids) {
                if (mid == n.moduleId) {
                    return n.moduleId;
                }
            }
        }
        if (sel != 0) {
            foreach (mid; ids) {
                if (mid == sel) {
                    return sel;
                }
            }
        }
        return ids[0];
    }

    private void onModulePicked(size_t index) {
        if (index < pickerModuleIds_.length) {
            pickedModule_ = pickerModuleIds_[index];
            selected_ = null;
            ctx.selectModule(pickedModule_);
            invalidate();
        }
    }

    private void scrollToNotes() {
        needsAutoScroll_ = false;
        immutable RectF gr = gridRect();
        if (gr.h <= 0.0f || gr.w <= 0.0f) {
            return;
        }
        ubyte minP = 127;
        ubyte maxP = 0;
        uint minL = uint.max;
        bool found = false;
        foreach (ref n; notes_) {
            if (pickedModule_ != 0 && n.moduleId != pickedModule_) {
                continue;
            }
            found = true;
            if (n.pitch < minP) minP = n.pitch;
            if (n.pitch > maxP) maxP = n.pitch;
            if (n.line < minL) minL = n.line;
        }
        if (!found) {
            foreach (ref n; notes_) {
                found = true;
                if (n.pitch < minP) minP = n.pitch;
                if (n.pitch > maxP) maxP = n.pitch;
                if (n.line < minL) minL = n.line;
            }
        }
        immutable float midPitch = found ? (cast(float) minP + cast(float) maxP) * 0.5f : 60.0f;
        immutable float midRowY = (127.0f - midPitch + 0.5f) * rowH_;
        scrollY_ = midRowY - gr.h * 0.5f;
        if (found) {
            immutable float nx = cast(float) minL * lineW_;
            if (nx + lineW_ > gr.w) {
                scrollX_ = nx - gr.w * 0.2f;
            } else {
                scrollX_ = 0.0f;
            }
        } else {
            scrollX_ = 0.0f;
        }
        clampScroll();
    }

    private void followLine(uint line) {
        immutable RectF gr = gridRect();
        if (gr.w <= 0.0f) {
            return;
        }
        immutable float x = lineToX(cast(float) line);
        if (x < gr.x || x + lineW_ > gr.right()) {
            scrollX_ = cast(float) line * lineW_ - gr.w * 0.35f;
            clampScroll();
            invalidate();
        }
    }

    private void clampScroll() {
        immutable RectF gr = gridRect();
        immutable float totalH = MIDI_COUNT * rowH_;
        immutable float maxY = totalH > gr.h ? totalH - gr.h : 0.0f;
        if (!isFinite(scrollY_) || scrollY_ < 0.0f) {
            scrollY_ = 0.0f;
        } else if (scrollY_ > maxY) {
            scrollY_ = maxY;
        }
        const sp = currentPatternDoc();
        immutable float totalW = sp !is null ? cast(float) sp.lines * lineW_ : 0.0f;
        immutable float maxX = totalW > gr.w ? totalW - gr.w : 0.0f;
        if (!isFinite(scrollX_) || scrollX_ < 0.0f) {
            scrollX_ = 0.0f;
        } else if (scrollX_ > maxX) {
            scrollX_ = maxX;
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

    private static float clampLineW(float w) {
        if (!isFinite(w)) return DEFAULT_LINE_W;
        return w < MIN_LINE_W ? MIN_LINE_W : (w > MAX_LINE_W ? MAX_LINE_W : w);
    }

    private static float clampRowH(float h) {
        if (!isFinite(h)) return DEFAULT_ROW_H;
        return h < MIN_ROW_H ? MIN_ROW_H : (h > MAX_ROW_H ? MAX_ROW_H : h);
    }
}
