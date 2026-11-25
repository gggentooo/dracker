/**
 * File:         source/gui/views/timeline_view.d
 * Module:       gui.views.timeline_view
 * Phase:        Phase 8.5 — Horizontal Pattern Arranger & Supertracks View
 *
 * Purpose:
 *   Horizontal multi-lane song arranger over document().clips. Lane headers (lane number, Supertrack indicator,
 *   lane-wide Mute/Solo/Supertrack toggles applied to every clip of the lane as one undo group), a ruler with
 *   bar/beat ticks and line numbers (click/drag seeks), a loop strip (drag sets the loop, double-click clears it),
 *   the playhead with optional follow, and rounded clip boxes colored by a stable per-pattern hash, labelled with
 *   the pattern name, with clones marked by a distinct border and a "⧉" prefix (the clone family of the selected
 *   clip is outlined), muted clips dimmed, soloed clips highlighted, and a revision-cached note miniature.
 *   Interactions: body drag moves a clip in time and lane, right-edge drag resizes it, Alt+drag clones it (each
 *   committed as one undo step on release with a ghost preview while dragging), double-click selects the clip's
 *   pattern (on the clip's name label it instead opens a TextField renaming the pattern), double-click on an empty lane adds a clip of the current pattern, right-click menus (clip: Mute,
 *   Solo, Supertrack, Make Unique, Set Loop To Clip, Delete; empty lane: Add Clip of each pattern), Delete key,
 *   horizontal scroll pans, vertical scroll moves lanes, Cmd+scroll / pinch / zoom actions zoom around a point.
 *   Snapping: no modifier snaps to beats (4 lines), Shift snaps to single lines, Cmd snaps to bars (16 lines).
 *   Resizing is right-edge only because no session API changes a clip's patternOffset.
 *   Phase 8.5 (Accessible Appearance): clip fills use the eight categorical theme clip colors; each pattern's
 *   color slot also selects its letter label (A-H) and bottom stripe pattern; dimmed clips are hatched; all clip
 *   text uses clipText. (The "Phase 8.5" above is the Phase 8 subtask ID, not the appearance phase.)
 *
 * Real-Time & Safety Contract:
 *   UI thread only; every edit goes through StudioSession (CoW TimelineSnapshots). The document is re-read every
 *   frame; derived data (pattern index, lane flags, note miniatures, song extent) is cached by documentRevision().
 *   Drawing touches only clips intersecting the viewport and performs no per-frame GC allocation.
 *
 * Dependencies:
 *   Internal: app.keymap, app.session (via gui.views.studio_context), gui.renderer, gui.theme, gui.widgets,
 *             io.project_format, platform.interfaces, sequencer.timeline
 *   External: std.format (sformat), std.math (exp, floor, ceil, round)
 *
 * Planned API (Types, Functions & Hooks):
 *   - final class TimelineView : Widget, StudioCommandSink — this(StudioContext), handleStudioAction(StudioAction)
 *     (deleteCell, deleteBlock, zoomIn, zoomOut, zoomReset, toggleFollow), setViewport(), zoomAround(),
 *     scrollLine(), pointsPerLine(), laneScroll(), maxScrollLine(), laneCount(), lastDrawnClipCount()
 *   - Automation hooks: clipRect(uint), lineToX(long), xToLine(float), laneToY(uint), yToLane(float), rulerRect(),
 *     loopStripRect(), contentRect(), headerRect(), laneMuteRect(uint), laneSoloRect(uint),
 *     laneSupertrackRect(uint), hitClip(Point2F, out bool), selectedClip(), selectClip(uint); child ids "timeline.ruler", "timeline.loop"
 *   - enum TimelineDragMode; final class TimelineStrip : Widget (ruler / loop strip children)
 *   - static patternSlot(uint), static patternColor(StudioTheme, uint) (categorical clip color slot)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.views.timeline_view;

import std.format : sformat;
import std.math : ceil, exp, floor, round;

import app.keymap : StudioAction, StudioCommandSink;
import gui.renderer : ColorRGBA, drawDashedPolyline, FontId, IRenderer2D, ITextMeasurer, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.views.studio_context : StudioContext;
import gui.widgets : KeyCode, KeyEvent, lineHeightOr, measureTextOr, MenuItem, MouseButton, MouseEvent,
    openTextEditor, ScrollEvent, TextField, Widget, hasModifier;
import io.project_format : LoadedProject, SavedPattern;
import platform.interfaces : KeyModifiers;
import sequencer.timeline : TimelineClip;

/**
 * Active pointer gesture of the timeline.
 */
enum TimelineDragMode : ubyte {
    none = 0,
    move = 1,
    resize = 2,
    clone = 3,
    seek = 4,
    loop = 5
}

/**
 * Ruler or loop-strip child widget; painting and input are forwarded to the owning TimelineView.
 */
final class TimelineStrip : Widget {
    private TimelineView owner_;
    private bool isRuler_;

    /**
     * Creates a strip.
     *
     * Params:
     *   owner = Owning timeline view.
     *   isRuler = True for the ruler, false for the loop strip.
     */
    this(TimelineView owner, bool isRuler) {
        owner_ = owner;
        isRuler_ = isRuler;
        id = isRuler ? "timeline.ruler" : "timeline.loop";
    }

    /**
     * Paints the strip through the owner.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        if (isRuler_) {
            owner_.paintRuler(r, theme);
        } else {
            owner_.paintLoopStrip(r, theme);
        }
    }

    /**
     * Forwards a press.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    override bool onMouseDown(const ref MouseEvent e) {
        return isRuler_ ? owner_.rulerDown(e) : owner_.loopDown(e);
    }

    /**
     * Forwards a drag.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    override bool onMouseMove(const ref MouseEvent e) {
        return owner_.stripMove(e);
    }

    /**
     * Forwards a release.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    override bool onMouseUp(const ref MouseEvent e) {
        return owner_.stripUp(e);
    }

    /**
     * Cancels a strip gesture when capture is lost.
     */
    override void onCaptureLost() {
        owner_.cancelDrag();
    }
}

/**
 * Horizontal multi-lane pattern arranger with clones, loop range, Supertrack lanes, mute/solo and seek.
 */
final class TimelineView : Widget, StudioCommandSink {
    enum float headerWidth = 112.0f;
    enum float rulerHeight = 22.0f;
    enum float loopHeight = 12.0f;
    enum float laneHeight = 44.0f;
    enum float minPointsPerLine = 0.25f;
    enum float maxPointsPerLine = 48.0f;
    enum float defaultPointsPerLine = 6.0f;
    enum uint maxLane = 255;
    enum float RENAME_FIELD_WIDTH = 180.0f;
    enum uint linesPerBeat = 4;
    enum uint linesPerBar = 16;
    enum float dragThreshold = 3.0f;
    enum size_t miniatureBudget = 6000;

    StudioContext ctx;

    private TimelineStrip ruler_;
    private TimelineStrip loopStrip_;
    private double scrollLine_ = 0.0;
    private float ppl_ = defaultPointsPerLine;
    private float scrollY_ = 0.0f;
    private uint selected_ = 0;

    private TimelineDragMode drag_ = TimelineDragMode.none;
    private uint dragClip_ = 0;
    private Point2F dragAnchor_;
    private bool dragMoved_ = false;
    private long dragOrigStart_ = 0;
    private uint dragOrigLen_ = 0;
    private uint dragOrigLane_ = 0;
    private long dragStart_ = 0;
    private uint dragLen_ = 0;
    private uint dragLane_ = 0;
    private long loopAnchorLine_ = 0;
    private long loopPreviewStart_ = 0;
    private long loopPreviewEnd_ = 0;
    private long lastSeekLine_ = -1;

    private ulong cacheRevision_ = 0;
    private size_t[uint] patIndex_;
    private MiniPattern[uint] mini_;
    private uint laneCount_ = 1;
    private ubyte[] laneClipCount_;
    private ubyte[] laneMuted_;
    private ubyte[] laneSolo_;
    private ubyte[] laneSuper_;
    private ubyte[] laneAnySuper_;
    private long songEnd_ = 0;
    private bool anySolo_ = false;
    private size_t drawnClips_ = 0;

    /**
     * Note-presence miniature of one pattern in compressed per-line form.
     */
    private static struct MiniPattern {
        uint lines;
        uint tracks;
        uint[] lineStart;
        ushort[] trackAt;
    }

    /**
     * Creates the timeline.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        this.ctx = ctx;
        id = "timeline";
        focusable = true;
        ruler_ = add(new TimelineStrip(this, true));
        loopStrip_ = add(new TimelineStrip(this, false));
        contextMenuProvider = &buildContextMenu;
    }

    /**
     * Positions the ruler and loop-strip children.
     */
    override void layoutChildren() {
        ruler_.arrange(rulerRect());
        loopStrip_.arrange(loopStripRect());
        clampView();
    }

    /**
     * Returns the ruler rectangle (automation hook).
     *
     * Returns:
     *   Window-space rectangle.
     */
    RectF rulerRect() const {
        return RectF(bounds.x + headerWidth, bounds.y, widthOrZero(bounds.w - headerWidth), rulerHeight);
    }

    /**
     * Returns the loop-strip rectangle below the ruler (automation hook).
     *
     * Returns:
     *   Window-space rectangle.
     */
    RectF loopStripRect() const {
        return RectF(bounds.x + headerWidth, bounds.y + rulerHeight, widthOrZero(bounds.w - headerWidth), loopHeight);
    }

    /**
     * Returns the clip lanes area.
     *
     * Returns:
     *   Window-space rectangle.
     */
    RectF contentRect() const {
        immutable float top = rulerHeight + loopHeight;
        return RectF(bounds.x + headerWidth, bounds.y + top, widthOrZero(bounds.w - headerWidth),
            widthOrZero(bounds.h - top));
    }

    /**
     * Returns the lane header column area.
     *
     * Returns:
     *   Window-space rectangle.
     */
    RectF headerRect() const {
        immutable float top = rulerHeight + loopHeight;
        return RectF(bounds.x, bounds.y + top, headerWidth < bounds.w ? headerWidth : widthOrZero(bounds.w),
            widthOrZero(bounds.h - top));
    }

    /**
     * Maps a song line to the x coordinate of its left edge (automation hook).
     *
     * Params:
     *   line = Song line.
     *
     * Returns:
     *   Window x.
     */
    float lineToX(long line) const {
        return cast(float)(bounds.x + headerWidth + (cast(double) line - scrollLine_) * ppl_);
    }

    /**
     * Maps an x coordinate to the song line containing it (automation hook).
     *
     * Params:
     *   x = Window x.
     *
     * Returns:
     *   Song line (may be negative left of line 0).
     */
    long xToLine(float x) const {
        return cast(long) floor(lineAtF(x) + 1.0e-6);
    }

    /**
     * Maps a lane index to the y coordinate of its top edge (automation hook).
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   Window y.
     */
    float laneToY(uint lane) const {
        return bounds.y + rulerHeight + loopHeight + cast(float) lane * laneHeight - scrollY_;
    }

    /**
     * Maps a y coordinate to the lane containing it (automation hook).
     *
     * Params:
     *   y = Window y.
     *
     * Returns:
     *   Lane index clamped to [0, maxLane].
     */
    uint yToLane(float y) const {
        immutable double v = floor((y - (bounds.y + rulerHeight + loopHeight) + scrollY_) / laneHeight + 1.0e-6);
        if (v < 0.0) {
            return 0;
        }
        return v > maxLane ? maxLane : cast(uint) v;
    }

    /**
     * Returns a clip's unclipped rectangle (automation hook).
     *
     * Params:
     *   clipId = Clip id.
     *
     * Returns:
     *   Rectangle, or an empty RectF if the clip does not exist.
     */
    RectF clipRect(uint clipId) const {
        foreach (ref c; ctx.session.document().clips) {
            if (c.clipId == clipId) {
                return rectFor(c.startLine, c.lengthLines, c.laneY);
            }
        }
        return RectF.init;
    }

    /**
     * Returns the rectangle of a clip's pattern-name label as drawn (double-clicking it renames the pattern).
     *
     * Params:
     *   clipId = Clip id.
     *
     * Returns:
     *   Label rectangle clipped to the clip and content area, or an empty RectF when the clip is missing, too
     *   narrow to show a label, or scrolled out of view.
     */
    RectF clipNameRect(uint clipId) {
        const doc = ctx.session.document();
        foreach (ref c; doc.clips) {
            if (c.clipId != clipId) {
                continue;
            }
            immutable RectF cr = rectFor(c.startLine, c.lengthLines, c.laneY);
            immutable RectF content = contentRect();
            const(SavedPattern)* sp = findPattern(c.patternId);
            if (cr.w < 14.0f || sp is null) {
                return RectF.init;
            }
            auto ui = context();
            ITextMeasurer m = ui is null ? null : ui.measurer();
            immutable float size = ctx.theme.fontSizeSmall;
            float tx = (cr.x > content.x ? cr.x : content.x) + 4.0f;
            tx += measureTextOr(m, "W ", FontId.ui, size);
            if (c.cloneSourceId != 0) {
                tx += measureTextOr(m, "⧉ ", FontId.ui, size);
            }
            if (c.isSupertrack) {
                tx += measureTextOr(m, "ST ", FontId.ui, size);
            }
            immutable float tw = measureTextOr(m, sp.name.length > 0 ? sp.name : "W", FontId.ui, size);
            immutable RectF label = RectF(tx - 2.0f, cr.y, tw + 4.0f, lineHeightOr(m, FontId.ui, size) + 4.0f);
            return label.intersect(cr).intersect(content);
        }
        return RectF.init;
    }

    /**
     * Opens a text field over a clip's name label to rename the clip's pattern (every clip of that pattern shows
     * the new name; duplicate names get a number appended by the session).
     *
     * Params:
     *   clipId = Clip whose pattern is renamed.
     *
     * Returns:
     *   The open field, or null when the clip or its pattern is missing or the view is detached.
     */
    TextField beginRenameClipPattern(uint clipId) {
        auto ui = context();
        if (ui is null) {
            return null;
        }
        foreach (ref c; ctx.session.document().clips) {
            if (c.clipId != clipId) {
                continue;
            }
            const(SavedPattern)* sp = findPattern(c.patternId);
            if (sp is null) {
                return null;
            }
            immutable uint pid = c.patternId;
            immutable RectF cr = rectFor(c.startLine, c.lengthLines, c.laneY);
            immutable RectF content = contentRect();
            immutable float x = cr.x > content.x ? cr.x : content.x;
            immutable RectF rect = RectF(x, cr.y, RENAME_FIELD_WIDTH, ctx.theme.controlHeight);
            return openTextEditor(ui, rect, sp.name, (string name) {
                ctx.renamePattern(pid, name);
                invalidate();
            });
        }
        return null;
    }

    /**
     * Returns the lane-header Mute button rectangle (automation hook).
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   Rectangle.
     */
    RectF laneMuteRect(uint lane) const {
        return headerButton(lane, 0);
    }

    /**
     * Returns the lane-header Solo button rectangle (automation hook).
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   Rectangle.
     */
    RectF laneSoloRect(uint lane) const {
        return headerButton(lane, 1);
    }

    /**
     * Returns the lane-header Supertrack button rectangle (automation hook).
     *
     * Params:
     *   lane = Lane index.
     *
     * Returns:
     *   Rectangle.
     */
    RectF laneSupertrackRect(uint lane) const {
        return headerButton(lane, 2);
    }

    /**
     * Hit-tests the clip area (automation hook).
     *
     * Params:
     *   p = Window point.
     *   onRightEdge = Receives true if p is on the right-edge resize handle.
     *
     * Returns:
     *   Clip id under p, or 0.
     */
    uint hitClip(Point2F p, out bool onRightEdge) const {
        const(TimelineClip)* c = clipAt(p, onRightEdge);
        return c is null ? 0 : c.clipId;
    }

    /**
     * Returns the selected clip id, or 0 if none (or it no longer exists).
     *
     * Returns:
     *   Clip id.
     */
    uint selectedClip() const {
        return selected_ != 0 && findClip(selected_) !is null ? selected_ : 0;
    }

    /**
     * Selects a clip (0 clears).
     *
     * Params:
     *   clipId = Clip id.
     */
    void selectClip(uint clipId) {
        selected_ = clipId != 0 && findClip(clipId) !is null ? clipId : 0;
        invalidate();
    }

    /**
     * Returns the first visible line (fractional).
     *
     * Returns:
     *   Horizontal scroll in lines.
     */
    double scrollLine() const {
        return scrollLine_;
    }

    /**
     * Returns the horizontal zoom.
     *
     * Returns:
     *   Points per line.
     */
    float pointsPerLine() const {
        return ppl_;
    }

    /**
     * Returns the vertical lane scroll.
     *
     * Returns:
     *   Points scrolled down.
     */
    float laneScroll() const {
        return scrollY_;
    }

    /**
     * Returns the number of lanes in use (highest laneY + 1, at least 1).
     *
     * Returns:
     *   Lane count.
     */
    uint laneCount() {
        syncCache();
        return laneCount_;
    }

    /**
     * Returns how many clips the last paint drew (viewport culling diagnostic).
     *
     * Returns:
     *   Clip count.
     */
    size_t lastDrawnClipCount() const {
        return drawnClips_;
    }

    /**
     * Returns the largest permitted horizontal scroll.
     *
     * Returns:
     *   Line.
     */
    double maxScrollLine() {
        syncCache();
        return cachedMaxScroll();
    }

    /**
     * Sets scroll and zoom, clamped.
     *
     * Params:
     *   firstLine = First visible line.
     *   pointsPerLine = Zoom.
     *   laneScrollY = Vertical scroll in points.
     */
    void setViewport(double firstLine, float pointsPerLine, float laneScrollY) {
        ppl_ = clampZoom(pointsPerLine);
        scrollLine_ = firstLine;
        scrollY_ = laneScrollY;
        clampView();
        invalidate();
    }

    /**
     * Multiplies the zoom keeping the line under anchorX fixed (when scroll limits allow).
     *
     * Params:
     *   factor = Zoom factor (> 1 zooms in).
     *   anchorX = Window x to keep fixed.
     */
    void zoomAround(float factor, float anchorX) {
        if (!(factor > 0.0f)) {
            return;
        }
        immutable double anchorLine = lineAtF(anchorX);
        immutable double off = anchorX - (bounds.x + headerWidth);
        ppl_ = clampZoom(ppl_ * factor);
        scrollLine_ = anchorLine - off / ppl_;
        clampView();
        invalidate();
    }

    /**
     * Executes view-level actions.
     *
     * Params:
     *   action = Action.
     *
     * Returns:
     *   True if consumed.
     */
    bool handleStudioAction(StudioAction action) {
        immutable float mid = bounds.x + headerWidth + contentRect().w * 0.5f;
        switch (action) {
        case StudioAction.deleteCell:
        case StudioAction.deleteBlock:
            return deleteSelected();
        case StudioAction.zoomIn:
            zoomAround(1.25f, mid);
            return true;
        case StudioAction.zoomOut:
            zoomAround(0.8f, mid);
            return true;
        case StudioAction.zoomReset:
            zoomAround(defaultPointsPerLine / ppl_, mid);
            return true;
        case StudioAction.toggleFollow:
            ctx.followPlayhead = !ctx.followPlayhead;
            invalidate();
            return true;
        default:
            return false;
        }
    }

    /**
     * Reports whether the view animates (playing transport or an active drag).
     *
     * Returns:
     *   True while animating.
     */
    override bool isAnimating() {
        return ctx.telemetry.engine.playing || drag_ != TimelineDragMode.none;
    }

    /**
     * Scrolls the view so the playhead stays visible while playing with follow enabled.
     */
    void updateFollow() {
        if (!ctx.followPlayhead || !ctx.telemetry.engine.playing || drag_ != TimelineDragMode.none) {
            return;
        }
        immutable double line = cast(double) ctx.telemetry.engine.currentLine;
        immutable double vis = visibleLines();
        if (vis <= 0.0) {
            return;
        }
        if (line < scrollLine_ || line >= scrollLine_ + vis * 0.95) {
            immutable double s = line - vis * 0.1;
            scrollLine_ = s > 0.0 ? s : 0.0;
            invalidate();
        }
    }

    /**
     * Paints lanes, grid, loop shading, clips, ghost, playhead and lane headers.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        syncCache();
        updateFollow();
        r.pushClip(bounds);
        r.fillRect(bounds, theme.trackerBackground);
        immutable RectF content = contentRect();
        r.pushClip(content);
        paintLanes(r, theme, content);
        paintGrid(r, theme, content);
        paintLoopShade(r, theme, content);
        paintClips(r, theme, content);
        paintGhost(r, theme);
        paintPlayhead(r, theme, content);
        r.popClip();
        paintHeaders(r, theme);
        r.fillRect(RectF(bounds.x, bounds.y, headerWidth, rulerHeight + loopHeight), theme.panel);
        r.drawText(Point2F(bounds.x + theme.spacingMd, bounds.y + 4.0f), ctx.followPlayhead ? "Follow" : "Arranger",
            FontId.ui, theme.fontSizeSmall, theme.textDim);
        r.popClip();
    }

    /**
     * Paints the ruler (called by the ruler child).
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    void paintRuler(IRenderer2D r, const ref StudioTheme theme) {
        immutable RectF rr = rulerRect();
        r.pushClip(rr);
        r.fillRect(rr, theme.panel);
        r.fillRect(RectF(rr.x, rr.bottom() - 1.0f, rr.w, 1.0f), theme.border);
        immutable long first = firstVisibleLine();
        immutable long last = lastVisibleLine();
        immutable long minor = minorStep();
        for (long l = alignDown(first, minor); l <= last; l += minor) {
            immutable float x = lineToX(l);
            immutable bool bar = l % linesPerBar == 0;
            immutable float h = bar ? 8.0f : 4.0f;
            r.fillRect(RectF(x, rr.bottom() - h, 1.0f, h), bar ? theme.textDim : theme.border);
        }
        immutable long major = majorStep();
        char[24] buf;
        for (long l = alignDown(first, major); l <= last; l += major) {
            immutable float x = lineToX(l);
            r.fillRect(RectF(x, rr.y + 2.0f, 1.0f, rr.h - 2.0f), theme.textDim);
            const(char)[] s = sformat(buf[], "%d", l);
            r.drawText(Point2F(x + 3.0f, rr.y + 2.0f), s, FontId.mono, theme.fontSizeSmall, theme.text);
        }
        immutable float px = lineToX(ctx.telemetry.engine.currentLine);
        r.fillRect(RectF(px - 4.0f, rr.y, 8.0f, 4.0f), theme.danger);
        r.fillRect(RectF(px, rr.y, 1.0f, rr.h), theme.danger);
        r.popClip();
    }

    /**
     * Paints the loop strip (called by the loop child).
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    void paintLoopStrip(IRenderer2D r, const ref StudioTheme theme) {
        immutable RectF lr = loopStripRect();
        r.pushClip(lr);
        r.fillRect(lr, theme.panelSunken);
        long s;
        long e;
        immutable bool preview = drag_ == TimelineDragMode.loop && dragMoved_;
        if (preview) {
            s = loopPreviewStart_;
            e = loopPreviewEnd_;
        } else {
            const doc = ctx.session.document();
            s = doc.loopStartLine;
            e = doc.loopEndLine;
        }
        if (e > s) {
            immutable float x0 = lineToX(s);
            immutable float x1 = lineToX(e);
            immutable RectF bar = RectF(x0, lr.y + 2.0f, x1 - x0, lr.h - 4.0f);
            r.fillRoundedRect(bar, 2.0f, preview ? theme.accentHot.withAlpha(0.7f) : theme.accent);
        }
        r.popClip();
    }

    /**
     * Handles a ruler press (seek).
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    package bool rulerDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        drag_ = TimelineDragMode.seek;
        lastSeekLine_ = -1;
        seekTo(e.pos.x);
        return true;
    }

    /**
     * Handles a loop-strip press (begin loop drag, or clear on double-click).
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    package bool loopDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        if (e.clickCount >= 2) {
            drag_ = TimelineDragMode.none;
            const doc = ctx.session.document();
            if (doc.loopEndLine != 0 || doc.loopStartLine != 0) {
                ctx.session.doSetLoop(0, 0);
            }
            return true;
        }
        drag_ = TimelineDragMode.loop;
        dragAnchor_ = e.pos;
        dragMoved_ = false;
        immutable long l = xToLine(e.pos.x);
        loopAnchorLine_ = l < 0 ? 0 : l;
        return true;
    }

    /**
     * Handles a drag over the ruler/loop strip.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    package bool stripMove(const ref MouseEvent e) {
        if (drag_ == TimelineDragMode.seek) {
            seekTo(e.pos.x);
            return true;
        }
        if (drag_ == TimelineDragMode.loop) {
            updateLoopPreview(e);
            return true;
        }
        return false;
    }

    /**
     * Handles a release over the ruler/loop strip.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    package bool stripUp(const ref MouseEvent e) {
        if (drag_ == TimelineDragMode.seek) {
            seekTo(e.pos.x);
            drag_ = TimelineDragMode.none;
            return true;
        }
        if (drag_ == TimelineDragMode.loop) {
            updateLoopPreview(e);
            drag_ = TimelineDragMode.none;
            if (dragMoved_) {
                const doc = ctx.session.document();
                if (doc.loopStartLine != loopPreviewStart_ || doc.loopEndLine != loopPreviewEnd_) {
                    ctx.session.doSetLoop(loopPreviewStart_, loopPreviewEnd_);
                }
            }
            dragMoved_ = false;
            invalidate();
            return true;
        }
        return false;
    }

    /**
     * Abandons any gesture without committing.
     */
    void cancelDrag() {
        drag_ = TimelineDragMode.none;
        dragMoved_ = false;
        invalidate();
    }

    /**
     * Handles presses in the header and clip area.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        syncCache();
        if (headerRect().contains(e.pos)) {
            return headerClick(e.pos);
        }
        if (!contentRect().contains(e.pos)) {
            return false;
        }
        bool edge;
        const(TimelineClip)* c = clipAt(e.pos, edge);
        if (c is null) {
            selected_ = 0;
            if (e.clickCount >= 2) {
                addClipAt(ctx.currentPattern(), e.pos, e.modifiers);
            }
            invalidate();
            return true;
        }
        selected_ = c.clipId;
        if (e.clickCount >= 2) {
            drag_ = TimelineDragMode.none;
            if (clipNameRect(c.clipId).contains(e.pos)) {
                beginRenameClipPattern(c.clipId);
            } else {
                ctx.selectPattern(c.patternId);
            }
            invalidate();
            return true;
        }
        drag_ = e.alt() ? TimelineDragMode.clone : (edge ? TimelineDragMode.resize : TimelineDragMode.move);
        dragClip_ = c.clipId;
        dragAnchor_ = e.pos;
        dragMoved_ = false;
        dragOrigStart_ = c.startLine;
        dragOrigLen_ = c.lengthLines;
        dragOrigLane_ = c.laneY;
        dragStart_ = c.startLine;
        dragLen_ = c.lengthLines;
        dragLane_ = c.laneY;
        invalidate();
        return true;
    }

    /**
     * Updates clip drag previews.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if a drag is active.
     */
    override bool onMouseMove(const ref MouseEvent e) {
        if (!isClipDrag()) {
            return false;
        }
        updateClipDrag(e);
        return true;
    }

    /**
     * Commits clip drags as one undo step.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if a drag was active.
     */
    override bool onMouseUp(const ref MouseEvent e) {
        if (!isClipDrag()) {
            return false;
        }
        updateClipDrag(e);
        immutable TimelineDragMode mode = drag_;
        drag_ = TimelineDragMode.none;
        if (!dragMoved_) {
            return true;
        }
        dragMoved_ = false;
        final switch (mode) {
        case TimelineDragMode.move:
        case TimelineDragMode.resize:
            if (dragStart_ != dragOrigStart_ || dragLen_ != dragOrigLen_ || dragLane_ != dragOrigLane_) {
                ctx.session.doMoveClip(dragClip_, dragStart_, dragLen_, dragLane_);
            }
            break;
        case TimelineDragMode.clone:
            immutable uint nid = ctx.session.doCloneClip(dragClip_, dragStart_, dragLane_);
            if (nid != 0) {
                selected_ = nid;
            }
            break;
        case TimelineDragMode.none:
        case TimelineDragMode.seek:
        case TimelineDragMode.loop:
            break;
        }
        invalidate();
        return true;
    }

    /**
     * Cancels a clip drag when capture is lost.
     */
    override void onCaptureLost() {
        cancelDrag();
    }

    /**
     * Handles Delete/Backspace (remove selected clip) and Escape (cancel drag).
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True if handled.
     */
    override bool onKeyDown(const ref KeyEvent e) {
        if (e.keyCode == KeyCode.deleteBackward || e.keyCode == KeyCode.forwardDelete) {
            return deleteSelected();
        }
        if (e.keyCode == KeyCode.escape && drag_ != TimelineDragMode.none) {
            cancelDrag();
            return true;
        }
        return false;
    }

    /**
     * Pans horizontally, moves lanes vertically, or zooms around the pointer with Cmd held.
     *
     * Params:
     *   e = Event.
     *
     * Returns:
     *   True.
     */
    override bool onScroll(const ref ScrollEvent e) {
        if (hasModifier(e.modifiers, KeyModifiers.command)) {
            zoomAround(cast(float) exp(e.deltaY * 0.02f), e.pos.x);
            return true;
        }
        float dx = e.deltaX;
        float dy = e.deltaY;
        if (hasModifier(e.modifiers, KeyModifiers.shift) && dx == 0.0f) {
            dx = dy;
            dy = 0.0f;
        }
        scrollLine_ -= dx / ppl_;
        scrollY_ -= dy;
        clampView();
        invalidate();
        return true;
    }

    /**
     * Pinch zoom around the pointer.
     *
     * Params:
     *   pos = Pointer.
     *   magnification = Pinch delta.
     *
     * Returns:
     *   True.
     */
    override bool onMagnify(Point2F pos, float magnification) {
        zoomAround(1.0f + magnification, pos.x);
        return true;
    }

    /**
     * Builds the right-click menu for the clip or empty lane under p (selecting the clip).
     *
     * Params:
     *   p = Window point.
     *
     * Returns:
     *   Menu items (empty outside the clip area).
     */
    MenuItem[] buildContextMenu(Point2F p) {
        syncCache();
        if (!contentRect().contains(p)) {
            return null;
        }
        bool edge;
        const(TimelineClip)* c = clipAt(p, edge);
        MenuItem[] items;
        if (c is null) {
            immutable long line = snapDown(xToLine(p.x), linesPerBeat);
            immutable uint lane = yToLane(p.y);
            foreach (ref pat; ctx.session.document().patterns) {
                immutable uint pid = pat.patternId;
                MenuItem it;
                it.label = "Add Clip: " ~ pat.name;
                it.action = addClipAction(pid, line, lane);
                items ~= it;
            }
            return items;
        }
        immutable TimelineClip cv = *c;
        selected_ = cv.clipId;
        invalidate();
        immutable uint cid = cv.clipId;
        items ~= MenuItem(cv.mute ? "Unmute" : "Mute", () { toggleClipFlag(cid, 0); });
        items ~= MenuItem(cv.solo ? "Unsolo" : "Solo", () { toggleClipFlag(cid, 1); });
        items ~= MenuItem(cv.isSupertrack ? "Clear Supertrack" : "Supertrack", () { toggleClipFlag(cid, 2); });
        items ~= MenuItem.makeSeparator();
        MenuItem unique = MenuItem("Make Unique", () { makeUnique(cid); });
        unique.enabled = cv.patternOffset == 0;
        items ~= unique;
        items ~= MenuItem("Set Loop To Clip", () {
            ctx.session.doSetLoop(cv.startLine, cv.startLine + cast(long) cv.lengthLines);
        });
        items ~= MenuItem.makeSeparator();
        MenuItem del = MenuItem("Delete", () { removeClip(cid); });
        del.shortcut = "⌫";
        items ~= del;
        return items;
    }

    /**
     * Builds a menu action adding a clip (one closure frame per call).
     *
     * Params:
     *   patternId = Pattern id.
     *   line = Start line.
     *   lane = Lane.
     *
     * Returns:
     *   Delegate.
     */
    private void delegate() addClipAction(uint patternId, long line, uint lane) {
        return () { addClipLine(patternId, line, lane); };
    }

    /**
     * Toggles one flag of a clip.
     *
     * Params:
     *   clipId = Clip id.
     *   which = 0 mute, 1 solo, 2 Supertrack.
     *
     * Returns:
     *   True if applied.
     */
    bool toggleClipFlag(uint clipId, int which) {
        const(TimelineClip)* c = findClip(clipId);
        if (c is null) {
            return false;
        }
        bool m = c.mute;
        bool s = c.solo;
        bool st = c.isSupertrack;
        if (which == 0) {
            m = !m;
        } else if (which == 1) {
            s = !s;
        } else {
            st = !st;
        }
        return ctx.session.doSetClipFlags(clipId, m, s, st);
    }

    /**
     * Toggles mute, solo or Supertrack for every clip of a lane as one undo step (set if not all set, else clear).
     *
     * Params:
     *   lane = Lane index.
     *   which = 0 mute, 1 solo, 2 Supertrack.
     *
     * Returns:
     *   True if the group was recorded.
     */
    bool toggleLaneFlag(uint lane, int which) {
        syncCache();
        if (lane >= laneCount_ || laneClipCount_[lane] == 0) {
            return false;
        }
        immutable bool allSet = which == 0 ? laneMuted_[lane] != 0 : (which == 1 ? laneSolo_[lane] != 0
            : laneSuper_[lane] != 0);
        immutable bool target = !allSet;
        uint[] ids;
        foreach (ref c; ctx.session.document().clips) {
            if (c.laneY == lane) {
                ids ~= c.clipId;
            }
        }
        ctx.session.beginEditGroup(which == 0 ? "Mute Lane" : (which == 1 ? "Solo Lane" : "Supertrack Lane"));
        foreach (cid; ids) {
            const(TimelineClip)* c = findClip(cid);
            if (c is null) {
                continue;
            }
            immutable bool m = which == 0 ? target : c.mute;
            immutable bool s = which == 1 ? target : c.solo;
            immutable bool st = which == 2 ? target : c.isSupertrack;
            if (m != c.mute || s != c.solo || st != c.isSupertrack) {
                ctx.session.doSetClipFlags(cid, m, s, st);
            }
        }
        return ctx.session.endEditGroup();
    }

    /**
     * Replaces a clip with a clip of a fresh duplicate of its pattern (one undo step).
     *
     * Params:
     *   clipId = Clip id.
     *
     * Returns:
     *   New clip id, or 0 on failure.
     */
    uint makeUnique(uint clipId) {
        const(TimelineClip)* cp = findClip(clipId);
        if (cp is null || cp.patternOffset != 0) {
            return 0;
        }
        immutable TimelineClip c = *cp;
        ctx.session.beginEditGroup("Make Unique");
        uint nid = 0;
        immutable uint np = ctx.session.doDuplicatePattern(c.patternId);
        if (np != 0) {
            nid = ctx.session.doAddClip(np, c.startLine, c.lengthLines, c.laneY, c.isSupertrack);
            if (nid != 0 && (c.mute || c.solo)) {
                ctx.session.doSetClipFlags(nid, c.mute, c.solo, c.isSupertrack);
            }
            if (nid != 0) {
                ctx.session.doRemoveClip(clipId);
            }
        }
        if (!ctx.session.endEditGroup() || nid == 0 || findClip(nid) is null) {
            return 0;
        }
        selected_ = nid;
        ctx.selectPattern(np);
        invalidate();
        return nid;
    }

    /**
     * Removes the selected clip.
     *
     * Returns:
     *   True if a clip was removed.
     */
    bool deleteSelected() {
        immutable uint sel = selectedClip();
        if (sel == 0) {
            return false;
        }
        return removeClip(sel);
    }

    /**
     * Removes a clip and clears the selection if it was selected.
     *
     * Params:
     *   clipId = Clip id.
     *
     * Returns:
     *   True if removed.
     */
    bool removeClip(uint clipId) {
        immutable bool ok = ctx.session.doRemoveClip(clipId);
        if (ok && selected_ == clipId) {
            selected_ = 0;
        }
        invalidate();
        return ok;
    }

    /**
     * Reports whether a clip drag gesture is active.
     *
     * Returns:
     *   True for move, resize or clone.
     */
    private bool isClipDrag() const {
        return drag_ == TimelineDragMode.move || drag_ == TimelineDragMode.resize || drag_ == TimelineDragMode.clone;
    }

    /**
     * Recomputes the proposed clip placement from the pointer.
     *
     * Params:
     *   e = Event.
     */
    private void updateClipDrag(const ref MouseEvent e) {
        immutable Point2F d = e.pos - dragAnchor_;
        if (!dragMoved_ && (d.x > dragThreshold || d.x < -dragThreshold || d.y > dragThreshold
                || d.y < -dragThreshold)) {
            dragMoved_ = true;
        }
        if (!dragMoved_) {
            return;
        }
        immutable long grid = gridFor(e.modifiers);
        immutable double deltaLines = d.x / ppl_;
        if (drag_ == TimelineDragMode.resize) {
            immutable long end = snapRound(cast(double)(dragOrigStart_ + dragOrigLen_) + deltaLines, grid);
            immutable long len = end - dragOrigStart_;
            dragLen_ = len < 1 ? 1 : (len > uint.max ? uint.max : cast(uint) len);
            dragStart_ = dragOrigStart_;
            dragLane_ = dragOrigLane_;
        } else {
            immutable long s = snapRound(cast(double) dragOrigStart_ + deltaLines, grid);
            dragStart_ = s < 0 ? 0 : s;
            dragLen_ = dragOrigLen_;
            immutable long lane = cast(long) dragOrigLane_ + cast(long) yToLane(e.pos.y)
                - cast(long) yToLane(dragAnchor_.y);
            dragLane_ = lane < 0 ? 0 : (lane > maxLane ? maxLane : cast(uint) lane);
        }
        invalidate();
    }

    /**
     * Updates the loop preview from the pointer.
     *
     * Params:
     *   e = Event.
     */
    private void updateLoopPreview(const ref MouseEvent e) {
        immutable Point2F d = e.pos - dragAnchor_;
        if (!dragMoved_ && (d.x > dragThreshold || d.x < -dragThreshold)) {
            dragMoved_ = true;
        }
        if (!dragMoved_) {
            return;
        }
        immutable long grid = gridFor(e.modifiers);
        long cur = xToLine(e.pos.x);
        cur = cur < 0 ? 0 : cur;
        immutable long lo = cur < loopAnchorLine_ ? cur : loopAnchorLine_;
        immutable long hi = cur < loopAnchorLine_ ? loopAnchorLine_ : cur;
        loopPreviewStart_ = snapDown(lo, grid);
        loopPreviewEnd_ = snapDown(hi + grid, grid);
        if (loopPreviewEnd_ <= loopPreviewStart_) {
            loopPreviewEnd_ = loopPreviewStart_ + grid;
        }
        invalidate();
    }

    /**
     * Seeks the transport to the line under x (only when it changes).
     *
     * Params:
     *   x = Window x.
     */
    private void seekTo(float x) {
        long l = xToLine(x);
        l = l < 0 ? 0 : l;
        if (l != lastSeekLine_) {
            lastSeekLine_ = l;
            ctx.session.seekLine(l);
            ctx.telemetry.engine.currentLine = l;
            invalidate();
        }
    }

    /**
     * Handles a press in the lane header column.
     *
     * Params:
     *   p = Window point.
     *
     * Returns:
     *   True.
     */
    private bool headerClick(Point2F p) {
        immutable uint lane = yToLane(p.y);
        foreach (int which; 0 .. 3) {
            if (headerButton(lane, which).contains(p)) {
                toggleLaneFlag(lane, which);
                invalidate();
                return true;
            }
        }
        return true;
    }

    /**
     * Adds a clip of a pattern at the snapped line/lane under p.
     *
     * Params:
     *   patternId = Pattern id.
     *   p = Window point.
     *   mods = Modifier mask selecting the snap grid.
     *
     * Returns:
     *   New clip id or 0.
     */
    private uint addClipAt(uint patternId, Point2F p, uint mods) {
        long line = snapDown(xToLine(p.x), gridFor(mods));
        return addClipLine(patternId, line < 0 ? 0 : line, yToLane(p.y));
    }

    /**
     * Adds a clip spanning the pattern's lines and selects it.
     *
     * Params:
     *   patternId = Pattern id.
     *   line = Start line.
     *   lane = Lane.
     *
     * Returns:
     *   New clip id or 0.
     */
    private uint addClipLine(uint patternId, long line, uint lane) {
        const(SavedPattern)* sp = findPattern(patternId);
        if (sp is null) {
            return 0;
        }
        immutable uint nid = ctx.session.doAddClip(patternId, line < 0 ? 0 : line, sp.lines, lane);
        if (nid != 0) {
            selected_ = nid;
        }
        invalidate();
        return nid;
    }

    /**
     * Rebuilds revision-keyed caches when the document changed.
     */
    private void syncCache() {
        immutable ulong rev = ctx.documentRevision();
        if (rev == cacheRevision_) {
            return;
        }
        cacheRevision_ = rev;
        const doc = ctx.session.document();
        patIndex_ = null;
        mini_ = null;
        foreach (i, ref p; doc.patterns) {
            patIndex_[p.patternId] = i;
        }
        uint lanes = 1;
        long end = doc.loopEndLine > 0 ? doc.loopEndLine : 0;
        anySolo_ = false;
        foreach (ref c; doc.clips) {
            if (c.laneY + 1 > lanes) {
                lanes = c.laneY + 1 > maxLane + 1 ? maxLane + 1 : c.laneY + 1;
            }
            immutable long ce = c.startLine + cast(long) c.lengthLines;
            if (ce > end) {
                end = ce;
            }
            if (c.solo && !c.mute) {
                anySolo_ = true;
            }
        }
        laneCount_ = lanes;
        songEnd_ = end;
        laneClipCount_ = new ubyte[lanes];
        laneMuted_ = new ubyte[lanes];
        laneSolo_ = new ubyte[lanes];
        laneSuper_ = new ubyte[lanes];
        laneAnySuper_ = new ubyte[lanes];
        laneMuted_[] = 1;
        laneSolo_[] = 1;
        laneSuper_[] = 1;
        foreach (ref c; doc.clips) {
            immutable uint l = c.laneY > maxLane ? maxLane : c.laneY;
            if (laneClipCount_[l] < ubyte.max) {
                laneClipCount_[l]++;
            }
            if (!c.mute) laneMuted_[l] = 0;
            if (!c.solo) laneSolo_[l] = 0;
            if (!c.isSupertrack) laneSuper_[l] = 0;
            if (c.isSupertrack) laneAnySuper_[l] = 1;
        }
        foreach (l; 0 .. lanes) {
            if (laneClipCount_[l] == 0) {
                laneMuted_[l] = 0;
                laneSolo_[l] = 0;
                laneSuper_[l] = 0;
            }
        }
        clampView();
    }

    /**
     * Returns (building lazily) the note miniature of a pattern.
     *
     * Params:
     *   patternId = Pattern id.
     *
     * Returns:
     *   Pointer into the cache, or null if the pattern is missing.
     */
    private const(MiniPattern)* miniFor(uint patternId) {
        if (auto m = patternId in mini_) {
            return m;
        }
        const(SavedPattern)* sp = findPattern(patternId);
        if (sp is null) {
            return null;
        }
        MiniPattern mp;
        mp.lines = sp.lines;
        mp.tracks = sp.tracks;
        mp.lineStart = new uint[sp.lines + 1];
        foreach (ln; 0 .. sp.lines) {
            mp.lineStart[ln] = cast(uint) mp.trackAt.length;
            foreach (tr; 0 .. sp.tracks) {
                immutable size_t idx = cast(size_t) ln * sp.tracks + tr;
                if (idx < sp.cells.length && sp.cells[idx].note >= 1 && sp.cells[idx].note <= 128) {
                    mp.trackAt ~= cast(ushort) tr;
                }
            }
        }
        mp.lineStart[sp.lines] = cast(uint) mp.trackAt.length;
        mini_[patternId] = mp;
        return patternId in mini_;
    }

    /**
     * Finds a pattern via the revision cache.
     *
     * Params:
     *   patternId = Pattern id.
     *
     * Returns:
     *   Transient pointer into the document, or null.
     */
    private const(SavedPattern)* findPattern(uint patternId) {
        syncCache();
        const doc = ctx.session.document();
        if (auto ip = patternId in patIndex_) {
            if (*ip < doc.patterns.length && doc.patterns[*ip].patternId == patternId) {
                return &doc.patterns[*ip];
            }
        }
        return null;
    }

    /**
     * Finds a clip in the document.
     *
     * Params:
     *   clipId = Clip id.
     *
     * Returns:
     *   Transient pointer into the document, or null.
     */
    private const(TimelineClip)* findClip(uint clipId) const {
        foreach (ref c; ctx.session.document().clips) {
            if (c.clipId == clipId) {
                return &c;
            }
        }
        return null;
    }

    /**
     * Hit-tests clips (selected first, then topmost in draw order).
     *
     * Params:
     *   p = Window point.
     *   rightEdge = Receives true if p is on the clip's right-edge resize handle.
     *
     * Returns:
     *   Transient clip pointer or null.
     */
    private const(TimelineClip)* clipAt(Point2F p, out bool rightEdge) const {
        if (!contentRect().contains(p)) {
            return null;
        }
        const(TimelineClip)* sel = selected_ != 0 ? findClip(selected_) : null;
        if (sel !is null && hitRect(rectFor(sel.startLine, sel.lengthLines, sel.laneY), p, rightEdge)) {
            return sel;
        }
        const doc = ctx.session.document();
        foreach_reverse (ref c; doc.clips) {
            if (hitRect(rectFor(c.startLine, c.lengthLines, c.laneY), p, rightEdge)) {
                return &c;
            }
        }
        return null;
    }

    /**
     * Tests a clip rectangle and its right-edge handle.
     *
     * Params:
     *   r = Clip rectangle.
     *   p = Point.
     *   rightEdge = Receives true on the edge handle.
     *
     * Returns:
     *   True if p is inside r.
     */
    private static bool hitRect(RectF r, Point2F p, out bool rightEdge) {
        if (!r.contains(p)) {
            return false;
        }
        immutable float ew = r.w * 0.25f < 6.0f ? r.w * 0.25f : 6.0f;
        rightEdge = p.x >= r.right() - ew;
        return true;
    }

    /**
     * Computes a clip rectangle.
     *
     * Params:
     *   start = Start line.
     *   len = Length in lines.
     *   lane = Lane.
     *
     * Returns:
     *   Window rectangle.
     */
    private RectF rectFor(long start, uint len, uint lane) const {
        immutable float x0 = lineToX(start);
        return RectF(x0, laneToY(lane) + 2.0f, cast(float)(cast(double) len * ppl_), laneHeight - 4.0f);
    }

    /**
     * Computes a lane-header button rectangle.
     *
     * Params:
     *   lane = Lane.
     *   which = 0 Mute, 1 Solo, 2 Supertrack.
     *
     * Returns:
     *   Window rectangle.
     */
    private RectF headerButton(uint lane, int which) const {
        immutable float y = laneToY(lane) + (laneHeight - 16.0f) * 0.5f;
        immutable float x = bounds.x + 34.0f + cast(float) which * 24.0f;
        return RectF(x, y, which == 2 ? 26.0f : 20.0f, 16.0f);
    }

    /**
     * Returns the fractional line at x.
     *
     * Params:
     *   x = Window x.
     *
     * Returns:
     *   Line.
     */
    private double lineAtF(float x) const {
        return scrollLine_ + (x - (bounds.x + headerWidth)) / ppl_;
    }

    /**
     * Returns the number of lines spanning the content width.
     *
     * Returns:
     *   Lines.
     */
    private double visibleLines() const {
        immutable float w = bounds.w - headerWidth;
        return w > 0.0f ? w / ppl_ : 0.0;
    }

    /**
     * Returns the first line intersecting the content area.
     *
     * Returns:
     *   Line.
     */
    private long firstVisibleLine() const {
        return cast(long) floor(scrollLine_);
    }

    /**
     * Returns the last line intersecting the content area.
     *
     * Returns:
     *   Line.
     */
    private long lastVisibleLine() const {
        return cast(long) ceil(scrollLine_ + visibleLines());
    }

    /**
     * Computes the largest horizontal scroll from the cached song extent and the playhead (256 lines of margin,
     * the extent end may scroll to the middle of the view).
     *
     * Returns:
     *   Line.
     */
    private double cachedMaxScroll() const {
        long extent = songEnd_;
        immutable long ph = ctx.telemetry.engine.currentLine;
        if (ph > extent) {
            extent = ph;
        }
        immutable double m = cast(double)(extent + 256) - visibleLines() * 0.5;
        return m > 0.0 ? m : 0.0;
    }

    /**
     * Clamps scroll offsets (refreshing the revision cache first).
     */
    private void clampView() {
        syncCache();
        if (scrollLine_ < 0.0 || scrollLine_ != scrollLine_) {
            scrollLine_ = 0.0;
        }
        if (scrollLine_ > cachedMaxScroll()) {
            scrollLine_ = cachedMaxScroll();
        }
        immutable float contentH = bounds.h - rulerHeight - loopHeight;
        immutable float maxY = cast(float)(laneCount_ + 1) * laneHeight - contentH;
        if (scrollY_ > maxY) {
            scrollY_ = maxY;
        }
        if (scrollY_ < 0.0f || scrollY_ != scrollY_) {
            scrollY_ = 0.0f;
        }
    }

    /**
     * Returns the ruler label spacing in lines for the current zoom.
     *
     * Returns:
     *   Step (power of two).
     */
    private long majorStep() const {
        long step = 1;
        while (cast(double) step * ppl_ < 40.0 && step < (1L << 40)) {
            step *= 2;
        }
        return step;
    }

    /**
     * Returns the ruler minor tick spacing in lines.
     *
     * Returns:
     *   Step.
     */
    private long minorStep() const {
        if (ppl_ >= 5.0f) {
            return 1;
        }
        if (linesPerBeat * ppl_ >= 5.0f) {
            return linesPerBeat;
        }
        long step = linesPerBar;
        while (cast(double) step * ppl_ < 5.0 && step < (1L << 40)) {
            step *= 2;
        }
        return step;
    }

    /**
     * Paints alternating lane backgrounds.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     *   content = Content rectangle.
     */
    private void paintLanes(IRenderer2D r, const ref StudioTheme theme, RectF content) {
        immutable uint l0 = yToLane(content.y);
        immutable uint l1 = yToLane(content.bottom());
        foreach (l; l0 .. l1 + 1) {
            immutable float y = laneToY(l);
            immutable ColorRGBA c = l % 2 == 0 ? theme.trackerBackground : theme.trackerRowBeat;
            r.fillRect(RectF(content.x, y, content.w, laneHeight), l < laneCount_ ? c : theme.panelSunken);
            r.fillRect(RectF(content.x, y + laneHeight - 1.0f, content.w, 1.0f), theme.gridLine);
        }
    }

    /**
     * Paints beat and bar grid lines.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     *   content = Content rectangle.
     */
    private void paintGrid(IRenderer2D r, const ref StudioTheme theme, RectF content) {
        long step = linesPerBeat * ppl_ >= 8.0f ? linesPerBeat : linesPerBar;
        while (cast(double) step * ppl_ < 4.0 && step < (1L << 40)) {
            step *= 2;
        }
        immutable long last = lastVisibleLine();
        for (long l = alignDown(firstVisibleLine(), step); l <= last; l += step) {
            immutable bool bar = l % linesPerBar == 0;
            r.fillRect(RectF(lineToX(l), content.y, 1.0f, content.h), bar ? theme.border : theme.gridLine);
        }
    }

    /**
     * Shades the loop range across the lanes.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     *   content = Content rectangle.
     */
    private void paintLoopShade(IRenderer2D r, const ref StudioTheme theme, RectF content) {
        const doc = ctx.session.document();
        if (doc.loopEndLine > doc.loopStartLine) {
            immutable float x0 = lineToX(doc.loopStartLine);
            immutable float x1 = lineToX(doc.loopEndLine);
            r.fillRect(RectF(x0, content.y, x1 - x0, content.h), theme.selection.withAlpha(0.08f));
        }
    }

    /**
     * Paints every clip intersecting the viewport.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     *   content = Content rectangle.
     */
    private void paintClips(IRenderer2D r, const ref StudioTheme theme, RectF content) {
        const doc = ctx.session.document();
        drawnClips_ = 0;
        size_t budget = miniatureBudget;
        uint familyPattern = 0;
        const(TimelineClip)* sel = selected_ != 0 ? findClip(selected_) : null;
        if (sel !is null) {
            familyPattern = sel.patternId;
        }
        foreach (ref c; doc.clips) {
            if (sel !is null && c.clipId == sel.clipId) {
                continue;
            }
            paintClip(r, theme, content, c, false, familyPattern, budget);
        }
        if (sel !is null) {
            paintClip(r, theme, content, *sel, true, familyPattern, budget);
        }
    }

    /**
     * Paints one clip if visible.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     *   content = Content rectangle.
     *   c = Clip.
     *   isSelected = Selection flag.
     *   familyPattern = Pattern of the selected clip (clone family outline), or 0.
     *   budget = Remaining miniature mark budget.
     */
    private void paintClip(IRenderer2D r, const ref StudioTheme theme, RectF content, const ref TimelineClip c,
            bool isSelected, uint familyPattern, ref size_t budget) {
        immutable RectF cr = rectFor(c.startLine, c.lengthLines, c.laneY);
        immutable RectF vis = cr.intersect(content);
        if (vis.isEmpty()) {
            return;
        }
        drawnClips_++;
        immutable bool dimmed = c.mute || (anySolo_ && !c.solo);
        immutable bool dragging = isClipDrag() && dragMoved_ && c.clipId == dragClip_
            && drag_ != TimelineDragMode.clone;
        immutable size_t slot = patternSlot(c.patternId);
        ColorRGBA fill = theme.clipColor(slot);
        if (dimmed) {
            fill = fill.lerp(theme.panelSunken, 0.65f);
        }
        if (dragging) {
            fill = fill.withAlpha(0.35f);
        }
        immutable float radius = cr.w < 8.0f ? 1.0f : theme.radiusMd;
        r.fillRoundedRect(cr, radius, fill);
        if (dimmed) {
            drawClipHatch(r, cr.intersect(content), theme.mutedHatch);
        }
        if (cr.w >= 14.0f && cr.h >= 10.0f) {
            drawClipStripe(r, vis, cr, slot, theme.clipText);
        }
        r.strokeRoundedRect(cr, radius, theme.borderWidth, theme.borderStrong);
        if (c.solo) {
            r.strokeRoundedRect(cr, radius, 2.0f, theme.success);
        }
        if (c.cloneSourceId != 0) {
            r.strokeRoundedRect(cr.inset(1.5f), radius, 1.0f, theme.warning);
        }
        if (familyPattern != 0 && c.patternId == familyPattern && !isSelected) {
            r.strokeRoundedRect(cr, radius, 1.0f, theme.accentHot.withAlpha(0.7f));
        }
        if (isSelected) {
            r.strokeRoundedRect(cr, radius, 2.0f, theme.text);
            r.strokeRoundedRect(cr.inset(-2.0f), radius + 2.0f, 1.0f, theme.accentHot);
        }
        if (cr.w >= 14.0f) {
            immutable ColorRGBA tc = theme.clipText;
            r.pushClip(vis.inset(1.0f));
            float tx = (cr.x > content.x ? cr.x : content.x) + 4.0f;
            immutable char[1] letter = [cast(char)('A' + slot)];
            r.drawText(Point2F(tx, cr.y + 2.0f), letter[], FontId.ui, theme.fontSizeSmall, tc);
            tx += r.measureText("W ", FontId.ui, theme.fontSizeSmall);
            if (c.cloneSourceId != 0) {
                r.drawText(Point2F(tx, cr.y + 2.0f), "⧉", FontId.ui, theme.fontSizeSmall, tc);
                tx += r.measureText("⧉ ", FontId.ui, theme.fontSizeSmall);
            }
            if (c.isSupertrack) {
                r.drawText(Point2F(tx, cr.y + 2.0f), "ST", FontId.ui, theme.fontSizeSmall, tc);
                tx += r.measureText("ST ", FontId.ui, theme.fontSizeSmall);
            }
            const(SavedPattern)* sp = findPattern(c.patternId);
            if (sp !is null) {
                r.drawText(Point2F(tx, cr.y + 2.0f), sp.name, FontId.ui, theme.fontSizeSmall, tc);
            }
            paintMiniature(r, theme, vis, cr, c, dimmed, budget);
            r.popClip();
        }
    }

    /**
     * Paints the cached note miniature of a clip's visible lines.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     *   vis = Visible part of the clip.
     *   cr = Clip rectangle.
     *   c = Clip.
     *   dimmed = Dimmed flag.
     *   budget = Remaining mark budget.
     */
    private void paintMiniature(IRenderer2D r, const ref StudioTheme theme, RectF vis, RectF cr,
            const ref TimelineClip c, bool dimmed, ref size_t budget) {
        if (ppl_ < 1.0f || budget == 0) {
            return;
        }
        const(MiniPattern)* mp = miniFor(c.patternId);
        if (mp is null || mp.lines == 0 || mp.tracks == 0 || mp.trackAt.length == 0) {
            return;
        }
        immutable float top = cr.y + 17.0f;
        immutable float h = cr.bottom() - 3.0f - top;
        if (h < 4.0f) {
            return;
        }
        immutable float th = h / mp.tracks;
        immutable float mh = th > 1.5f ? th - 0.5f : 1.0f;
        immutable float mw = ppl_ > 2.0f ? ppl_ - 1.0f : 1.0f;
        immutable ColorRGBA mc = theme.clipText.withAlpha(dimmed ? 0.55f : 0.75f);
        long k0 = cast(long) floor(lineAtF(vis.x)) - c.startLine;
        long k1 = cast(long) ceil(lineAtF(vis.right())) - c.startLine;
        k0 = k0 < 0 ? 0 : k0;
        k1 = k1 > c.lengthLines ? c.lengthLines : k1;
        for (long k = k0; k < k1; k++) {
            immutable uint pl = cast(uint)((cast(ulong) k + c.patternOffset) % mp.lines);
            immutable float x = lineToX(c.startLine + k);
            foreach (i; mp.lineStart[pl] .. mp.lineStart[pl + 1]) {
                if (budget == 0) {
                    return;
                }
                budget--;
                r.fillRect(RectF(x, top + mp.trackAt[i] * th, mw, mh), mc);
            }
        }
    }

    /**
     * Paints the drag ghost (proposed placement).
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    private void paintGhost(IRenderer2D r, const ref StudioTheme theme) {
        if (!isClipDrag() || !dragMoved_) {
            return;
        }
        immutable RectF g = rectFor(dragStart_, dragLen_, dragLane_);
        r.fillRoundedRect(g, theme.radiusMd, theme.selection);
        r.strokeRoundedRect(g, theme.radiusMd, 1.5f, drag_ == TimelineDragMode.clone ? theme.warning
            : theme.accentHot);
    }

    /**
     * Paints the playhead line.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     *   content = Content rectangle.
     */
    private void paintPlayhead(IRenderer2D r, const ref StudioTheme theme, RectF content) {
        immutable float x = lineToX(ctx.telemetry.engine.currentLine);
        r.fillRect(RectF(x, content.y, 1.5f, content.h), theme.danger);
    }

    /**
     * Paints lane headers (number, Supertrack indicator, M/S/ST toggles).
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    private void paintHeaders(IRenderer2D r, const ref StudioTheme theme) {
        immutable RectF hr = headerRect();
        r.pushClip(hr);
        r.fillRect(hr, theme.panel);
        r.fillRect(RectF(hr.right() - 1.0f, hr.y, 1.0f, hr.h), theme.border);
        immutable uint l0 = yToLane(hr.y);
        immutable uint l1 = yToLane(hr.bottom());
        char[16] buf;
        foreach (l; l0 .. l1 + 1) {
            if (l >= laneCount_ + 1) {
                break;
            }
            immutable float y = laneToY(l);
            r.fillRect(RectF(hr.x, y + laneHeight - 1.0f, hr.w, 1.0f), theme.gridLine);
            const(char)[] s = sformat(buf[], "%d", l + 1);
            r.drawText(Point2F(hr.x + theme.spacingMd, y + 4.0f), s, FontId.mono, theme.fontSizeSmall, theme.text);
            immutable bool used = l < laneCount_ && laneClipCount_[l] > 0;
            if (used && laneAnySuper_[l]) {
                r.fillRoundedRect(RectF(hr.x + 4.0f, y + laneHeight - 8.0f, 24.0f, 4.0f), 2.0f, theme.accent);
            }
            paintHeaderButton(r, theme, headerButton(l, 0), "M", used && laneMuted_[l] != 0, theme.warning, used);
            paintHeaderButton(r, theme, headerButton(l, 1), "S", used && laneSolo_[l] != 0, theme.success, used);
            paintHeaderButton(r, theme, headerButton(l, 2), "ST", used && laneSuper_[l] != 0, theme.accent,
                used);
        }
        r.popClip();
    }

    /**
     * Paints one header toggle.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     *   b = Button rectangle.
     *   label = Caption.
     *   on = Lit state.
     *   onColor = Lit color.
     *   enabledState = False when the lane has no clips.
     */
    private static void paintHeaderButton(IRenderer2D r, const ref StudioTheme theme, RectF b, string label, bool on,
            ColorRGBA onColor, bool enabledState) {
        r.fillRoundedRect(b, theme.radiusSm, on ? onColor : theme.panelRaised);
        r.strokeRoundedRect(b, theme.radiusSm, on ? 2.0f : 1.0f, on ? theme.borderStrong : theme.border);
        immutable ColorRGBA tc = on ? theme.accentText : (enabledState ? theme.text : theme.textDisabled);
        r.drawText(Point2F(b.x + 4.0f, b.y + 1.0f), label, FontId.ui, theme.fontSizeSmall, tc);
    }

    /**
     * Returns the categorical color slot (0-7) of a pattern; the slot selects the theme clip color, the letter
     * label (A-H) and the stripe pattern, so the three cues always agree.
     *
     * Params:
     *   patternId = Pattern id.
     *
     * Returns:
     *   Slot index.
     */
    static size_t patternSlot(uint patternId) @safe nothrow pure @nogc {
        return patternId == 0 ? 0 : (patternId - 1) % 8;
    }

    /**
     * Returns the display color of a pattern in a theme.
     *
     * Params:
     *   theme = Theme.
     *   patternId = Pattern id.
     *
     * Returns:
     *   Clip fill color.
     */
    static ColorRGBA patternColor(const ref StudioTheme theme, uint patternId) @safe nothrow pure @nogc {
        return theme.clipColor(patternSlot(patternId));
    }

    private static void drawClipHatch(IRenderer2D r, RectF area, ColorRGBA color) {
        if (area.isEmpty()) {
            return;
        }
        r.pushClip(area);
        for (float d = -area.h; d < area.w; d += 7.0f) {
            r.drawLine(Point2F(area.x + d, area.bottom()), Point2F(area.x + d + area.h, area.y), 1.0f, color);
        }
        r.popClip();
    }

    private static void drawClipStripe(IRenderer2D r, RectF vis, RectF cr, size_t slot, ColorRGBA color) {
        static immutable float[2][8] patterns = [[1000.0f, 0.0f], [10.0f, 4.0f], [4.0f, 3.0f], [0.01f, 4.0f],
            [8.0f, 3.0f], [1000.0f, 0.0f], [16.0f, 8.0f], [0.01f, 8.0f]];
        immutable float y = cr.bottom() - 3.0f;
        immutable float x0 = (vis.x > cr.x ? vis.x : cr.x) + 3.0f;
        immutable float x1 = (vis.right() < cr.right() ? vis.right() : cr.right()) - 3.0f;
        if (x1 <= x0) {
            return;
        }
        r.pushClip(vis);
        if (slot == 5) {
            immutable Point2F[2] a = [Point2F(x0, y - 1.5f), Point2F(x1, y - 1.5f)];
            immutable Point2F[2] b = [Point2F(x0, y + 0.5f), Point2F(x1, y + 0.5f)];
            r.drawPolyline(a[], 1.0f, color);
            r.drawPolyline(b[], 1.0f, color);
        } else {
            immutable Point2F[2] seg = [Point2F(x0, y), Point2F(x1, y)];
            drawDashedPolyline(r, seg[], 2.0f, color, patterns[slot][0], patterns[slot][1]);
        }
        r.popClip();
    }

    /**
     * Returns the snap grid for a modifier mask (none = beat, Shift = line, Cmd = bar).
     *
     * Params:
     *   mods = KeyModifiers mask.
     *
     * Returns:
     *   Grid in lines.
     */
    static long gridFor(uint mods) @safe nothrow pure @nogc {
        if (hasModifier(mods, KeyModifiers.shift)) {
            return 1;
        }
        if (hasModifier(mods, KeyModifiers.command)) {
            return linesPerBar;
        }
        return linesPerBeat;
    }

    /**
     * Rounds a fractional line to the nearest grid multiple.
     *
     * Params:
     *   line = Line.
     *   grid = Grid (>= 1).
     *
     * Returns:
     *   Snapped line.
     */
    private static long snapRound(double line, long grid) @safe nothrow pure @nogc {
        return cast(long) round(line / grid) * grid;
    }

    /**
     * Floors a line to a grid multiple.
     *
     * Params:
     *   line = Line.
     *   grid = Grid (>= 1).
     *
     * Returns:
     *   Snapped line.
     */
    private static long snapDown(long line, long grid) @safe nothrow pure @nogc {
        return alignDown(line, grid);
    }

    /**
     * Floors v to a multiple of step (correct for negatives).
     *
     * Params:
     *   v = Value.
     *   step = Step (>= 1).
     *
     * Returns:
     *   Aligned value.
     */
    private static long alignDown(long v, long step) @safe nothrow pure @nogc {
        immutable long q = v / step;
        return (v < 0 && q * step != v ? q - 1 : q) * step;
    }

    /**
     * Clamps a zoom value.
     *
     * Params:
     *   v = Points per line.
     *
     * Returns:
     *   Clamped value.
     */
    private static float clampZoom(float v) @safe nothrow pure @nogc {
        if (!(v >= minPointsPerLine)) {
            return minPointsPerLine;
        }
        return v > maxPointsPerLine ? maxPointsPerLine : v;
    }

    /**
     * Returns v if positive, else 0.
     *
     * Params:
     *   v = Value.
     *
     * Returns:
     *   Non-negative value.
     */
    private static float widthOrZero(float v) @safe nothrow pure @nogc {
        return v > 0.0f ? v : 0.0f;
    }
}
