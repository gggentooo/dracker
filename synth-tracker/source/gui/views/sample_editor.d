/**
 * File:         source/gui/views/sample_editor.d
 * Module:       gui.views.sample_editor
 * Phase:        Phase 8.3 — Sampler Waveform, Loop & Envelope Editor
 *
 * Purpose:
 *   Editor for the selected synth.sampler module: a slot selector (0 .. Sampler.MAX_SLOTS-1, occupied slots show
 *   their length), an Import... button (native file dialog through ctx.dialogs, or importSampleBytes() for tests and
 *   drag-and-drop), zoom buttons, the module's loop mode (off / forward / ping-pong) and root / low / high note
 *   fields; a stereo-stacked min/max waveform from session.samplePeaks() with zoom (pinch, Cmd+scroll, buttons,
 *   zoomIn/zoomOut/zoomReset actions) and horizontal scrolling; draggable loop start / end markers; and an
 *   amplitude EnvelopeEditor over the slot's volume breakpoints. Slot edits rebuild the sampler extra blob through a
 *   temporary sampler created from the module vtable (create / deserializeExtra / swapAsset / serializeExtra /
 *   destroy) and apply it with session.doSetModuleExtra() once per gesture (one undo step).
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Slot metadata is decoded once per document revision; waveform peaks are fetched only when the
 *   revision, slot, or power-of-two zoom bucket count changes, and drawing touches only visible columns. Nothing is
 *   re-read while a marker, field, or envelope gesture is active. Every mutation goes through StudioSession.
 *
 * Dependencies:
 *   Internal: app.keymap, app.session, dsp.envelope, graph.registry, gui.{layout,renderer,theme,widgets},
 *             gui.views.{param_rack (GestureHooks),studio_context}, modules.synths.sampler, platform.interfaces
 *   External: std.file (read), std.format (format), std.math (ceil, floor, round)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct SampleSlotInfo; final class SampleEnvelopeEditor; final class SampleNumberBox
 *   - final class SampleEditorView : Widget, StudioCommandSink — this(StudioContext), sync(), samplerId(),
 *     currentSlot(), selectSlot(), slotInfo(), importSampleBytes(), importPrompt(), setLoopMode(), loopMode(),
 *     zoomIn(), zoomOut(), zoomFit(), zoomBy(), framesPerPixel(), viewStartFrame(), waveformRect(), frameToX(),
 *     xToFrame(), loopStartMarkerRect(), loopEndMarkerRect(), envelopeEditor(), envelopeEditorRect(), noteBox(),
 *     handleStudioAction(zoomIn/zoomOut/zoomReset)
 *   - ids: "sample.import", "sample.slot", "sample.zoomIn", "sample.zoomOut", "sample.zoomFit", "sample.loopMode",
 *     "sample.root", "sample.low", "sample.high", "sample.envelope"
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.3)
 */
module gui.views.sample_editor;

import std.file : read;
import std.format : format;
import std.math : ceil, floor, round;

import app.keymap : StudioAction, StudioCommandSink;
import app.session : SamplePeaks;
import dsp.envelope : EnvBreakpoint;
import graph.registry : ModuleRegistry;
import gui.layout : clampf;
import gui.renderer : ColorRGBA, FontId, IRenderer2D, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.widgets : Button, Dropdown, EnvelopeEditor, KeyEvent, MouseButton, MouseEvent, NumericDragBox, ScrollEvent,
    ValueRange, Widget;
import gui.views.param_rack : GestureHooks;
import gui.views.studio_context : StudioContext;
import modules.synths.sampler : Sampler, SamplerSlotAsset;
import platform.interfaces : FileDialogFilter, KeyModifiers;

/**
 * Decoded metadata of one sampler slot (sample data stays in the session).
 */
struct SampleSlotInfo {
    bool occupied = false;
    size_t frames = 0;
    float sampleRate = 44_100.0f;
    ubyte rootNote = 60;
    ubyte lowNote = 0;
    ubyte highNote = 127;
    size_t loopStart = 0;
    size_t loopEnd = 0;
    EnvBreakpoint[SamplerSlotAsset.MAX_BREAKPOINTS] volEnv;
    uint volEnvCount = 0;
    int volSustainIdx = -1;
}

/**
 * Amplitude envelope editor reporting gesture begin/end.
 */
final class SampleEnvelopeEditor : EnvelopeEditor {
    mixin GestureHooks;

    /**
     * Creates the editor (3 .. MAX_BREAKPOINTS points).
     */
    this() {
        super();
        minPoints = 3;
        maxPoints = SamplerSlotAsset.MAX_BREAKPOINTS;
    }
}

/**
 * Integer note field reporting press/release so a drag commits once.
 */
final class SampleNumberBox : NumericDragBox {
    void delegate() onGestureEnd;
    private bool active_ = false;

    /**
     * Creates a MIDI note field.
     */
    this() {
        super(ValueRange(0.0f, 127.0f, 60.0f, false, 1.0f), 0);
    }

    /**
     * Reports whether a drag is active.
     *
     * Returns:
     *   True between press and release.
     */
    bool gestureActive() const {
        return active_;
    }

    override bool onMouseDown(const ref MouseEvent e) {
        immutable bool h = super.onMouseDown(e);
        if (h && e.button == MouseButton.left && !isEditing()) {
            active_ = true;
        }
        return h;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        immutable bool h = super.onMouseUp(e);
        finish();
        return h;
    }

    override void onCaptureLost() {
        super.onCaptureLost();
        finish();
    }

    private void finish() {
        if (!active_) {
            return;
        }
        active_ = false;
        if (onGestureEnd !is null) {
            onGestureEnd();
        }
    }
}

/**
 * Sampler slot waveform, loop, key-range and envelope editor.
 */
final class SampleEditorView : Widget, StudioCommandSink {
    enum float TOOLBAR_HEIGHT = 28.0f;
    enum float FIELDS_HEIGHT = 28.0f;
    enum float ENVELOPE_HEIGHT = 110.0f;
    enum float MARKER_GRAB = 5.0f;
    enum double MIN_FRAMES_PER_PIXEL = 1.0 / 32.0;
    enum uint MAX_PEAK_BUCKETS = 1u << 22;

    private StudioContext ctx_;
    private Dropdown slotDropdown_;
    private Button importButton_;
    private Button zoomInButton_;
    private Button zoomOutButton_;
    private Button zoomFitButton_;
    private Dropdown loopModeDropdown_;
    private SampleNumberBox rootBox_;
    private SampleNumberBox lowBox_;
    private SampleNumberBox highBox_;
    private SampleEnvelopeEditor env_;
    private SampleSlotInfo[Sampler.MAX_SLOTS] info_;
    private bool bound_ = false;
    private uint boundModule_ = 0;
    private ulong boundRev_ = 0;
    private uint slot_ = 0;
    private int loopModeIdx_ = -1;
    private RectF wave_;
    private double viewStart_ = 0.0;
    private double fpp_ = 1.0;
    private bool fitPending_ = true;
    private size_t fittedFrames_ = 0;
    private SamplePeaks peaks_;
    private bool havePeaks_ = false;
    private ulong peaksRev_ = 0;
    private uint peaksSlot_ = uint.max;
    private uint peaksBuckets_ = 0;
    private uint peaksModule_ = 0;
    private int dragMarker_ = 0;
    private size_t dragStart_ = 0;
    private size_t dragEnd_ = 0;
    private float envSpan_ = 1.0f;
    private bool fieldDirty_ = false;

    /**
     * Creates the editor.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        ctx_ = ctx;
        id = "sample";
        string[] slots;
        foreach (i; 0 .. Sampler.MAX_SLOTS) {
            slots ~= format("%d: empty", i + 1);
        }
        slotDropdown_ = add(new Dropdown(slots, 0, (size_t i) { selectSlot(cast(uint) i); }));
        slotDropdown_.id = "sample.slot";
        importButton_ = add(new Button("Import...", () { importPrompt(); }));
        importButton_.id = "sample.import";
        zoomOutButton_ = add(new Button("-", () { zoomOut(); }));
        zoomOutButton_.id = "sample.zoomOut";
        zoomInButton_ = add(new Button("+", () { zoomIn(); }));
        zoomInButton_.id = "sample.zoomIn";
        zoomFitButton_ = add(new Button("Fit", () { zoomFit(); }));
        zoomFitButton_.id = "sample.zoomFit";
        loopModeDropdown_ = add(new Dropdown(["Loop Off", "Forward", "Ping-Pong"], 0, (size_t i) {
            setLoopMode(cast(uint) i);
        }));
        loopModeDropdown_.id = "sample.loopMode";
        rootBox_ = add(makeNoteBox("sample.root"));
        lowBox_ = add(makeNoteBox("sample.low"));
        highBox_ = add(makeNoteBox("sample.high"));
        env_ = add(new SampleEnvelopeEditor());
        env_.id = "sample.envelope";
        env_.onGestureEnd = (bool changed) {
            if (changed) {
                commitEnvelope();
            }
        };
        focusable = true;
    }

    /**
     * Brings the editor in line with the selection and document.
     */
    void sync() {
        if (gestureActive()) {
            return;
        }
        immutable uint sel = samplerId();
        immutable ulong rev = ctx_.documentRevision();
        if (bound_ && sel == boundModule_ && rev == boundRev_) {
            return;
        }
        immutable bool moduleChanged = !bound_ || sel != boundModule_;
        bound_ = true;
        boundModule_ = sel;
        boundRev_ = rev;
        loadInfo();
        if (moduleChanged) {
            slot_ = 0;
            foreach (i, ref inf; info_) {
                if (inf.occupied) {
                    slot_ = cast(uint) i;
                    break;
                }
            }
            fitPending_ = true;
        }
        if (info_[slot_].frames != fittedFrames_) {
            fitPending_ = true;
        }
        refreshControls();
        layoutChildren();
        invalidate();
    }

    /**
     * Returns the edited sampler (the selected module when it is a synth.sampler).
     *
     * Returns:
     *   Module id, or 0.
     */
    uint samplerId() const {
        immutable uint sel = ctx_.selectedModule();
        foreach (ref m; ctx_.session.document().modules) {
            if (m.id == sel) {
                return m.typeId == "synth.sampler" ? sel : 0;
            }
        }
        return 0;
    }

    /**
     * Returns the edited slot.
     *
     * Returns:
     *   Slot index.
     */
    uint currentSlot() {
        sync();
        return slot_;
    }

    /**
     * Switches the edited slot.
     *
     * Params:
     *   slot = Slot index (clamped).
     */
    void selectSlot(uint slot) {
        sync();
        immutable uint s = slot < Sampler.MAX_SLOTS ? slot : cast(uint)(Sampler.MAX_SLOTS - 1);
        if (s == slot_) {
            return;
        }
        slot_ = s;
        slotDropdown_.select(s, false);
        fitPending_ = true;
        refreshControls();
        layoutChildren();
        invalidate();
    }

    /**
     * Returns decoded metadata of a slot.
     *
     * Params:
     *   slot = Slot index.
     *
     * Returns:
     *   Slot info (default when out of range).
     */
    SampleSlotInfo slotInfo(uint slot) {
        sync();
        return slot < Sampler.MAX_SLOTS ? info_[slot] : SampleSlotInfo.init;
    }

    /**
     * Decodes audio bytes into a slot (root 60, full key range) as one undo step.
     *
     * Params:
     *   slot = Slot index.
     *   bytes = Encoded WAV/FLAC/MP3/OGG/AIFF bytes.
     *   err = Receives a diagnostic on failure.
     *
     * Returns:
     *   True if loaded.
     */
    bool importSampleBytes(uint slot, const(ubyte)[] bytes, out string err) {
        immutable uint id = samplerId();
        if (id == 0) {
            err = "Select a Sampler module first";
            return false;
        }
        if (!ctx_.session.doLoadSample(id, slot, bytes, 60, 0, 127, err)) {
            return false;
        }
        if (slot < Sampler.MAX_SLOTS && slot != slot_) {
            slot_ = slot;
            slotDropdown_.select(slot, false);
        }
        fitPending_ = true;
        sync();
        return true;
    }

    /**
     * Runs the Import... flow through ctx.dialogs and reports the outcome on the status line.
     *
     * Returns:
     *   True if a sample was loaded.
     */
    bool importPrompt() {
        if (ctx_.dialogs is null) {
            ctx_.setStatus("File dialogs are not available");
            return false;
        }
        if (samplerId() == 0) {
            ctx_.setStatus("Select a Sampler module first");
            return false;
        }
        immutable FileDialogFilter[1] filters = [FileDialogFilter("Audio", ["wav", "flac", "mp3", "ogg", "aif", "aiff"])];
        string path;
        if (!ctx_.dialogs.openFile("Import Sample", filters[], path)) {
            return false;
        }
        const(ubyte)[] bytes;
        try {
            bytes = cast(const(ubyte)[]) read(path);
        } catch (Exception ex) {
            ctx_.setStatus("Import failed: " ~ ex.msg);
            return false;
        }
        string err;
        if (!importSampleBytes(slot_, bytes, err)) {
            ctx_.setStatus("Import failed: " ~ err);
            return false;
        }
        ctx_.setStatus(format("Imported sample into slot %d", slot_ + 1));
        return true;
    }

    /**
     * Sets the sampler's loop mode parameter (one undo step).
     *
     * Params:
     *   mode = 0 = off, 1 = forward, 2 = ping-pong.
     *
     * Returns:
     *   True if applied.
     */
    bool setLoopMode(uint mode) {
        immutable uint id = samplerId();
        if (id == 0 || loopModeIdx_ < 0) {
            return false;
        }
        ctx_.session.history().breakCoalesce();
        immutable bool ok = ctx_.session.doSetParam(id, cast(uint) loopModeIdx_, cast(float)(mode > 2 ? 2 : mode));
        ctx_.session.history().breakCoalesce();
        return ok;
    }

    /**
     * Returns the sampler's loop mode.
     *
     * Returns:
     *   0 .. 2.
     */
    uint loopMode() {
        sync();
        return cast(uint) loopModeDropdown_.selectedIndex;
    }

    /**
     * Zooms in by 2x around the waveform centre.
     */
    void zoomIn() {
        zoomBy(2.0, wave_.x + wave_.w * 0.5f);
    }

    /**
     * Zooms out by 2x around the waveform centre.
     */
    void zoomOut() {
        zoomBy(0.5, wave_.x + wave_.w * 0.5f);
    }

    /**
     * Shows the whole sample.
     */
    void zoomFit() {
        sync();
        fitPending_ = true;
        applyFit();
        invalidate();
    }

    /**
     * Zooms keeping the frame under anchorX fixed.
     *
     * Params:
     *   factor = > 1 zooms in.
     *   anchorX = Absolute x of the zoom anchor.
     */
    void zoomBy(double factor, float anchorX) {
        sync();
        immutable size_t frames = info_[slot_].frames;
        if (frames == 0 || !(factor > 0.0) || !(wave_.w > 0.0f)) {
            return;
        }
        immutable double ax = clampf(anchorX, wave_.x, wave_.right()) - wave_.x;
        immutable double anchorFrame = viewStart_ + ax * fpp_;
        double next = fpp_ / factor;
        immutable double maxFpp = cast(double) frames / wave_.w;
        next = next < MIN_FRAMES_PER_PIXEL ? MIN_FRAMES_PER_PIXEL : (next > maxFpp ? maxFpp : next);
        fpp_ = next;
        viewStart_ = anchorFrame - ax * fpp_;
        clampView();
        invalidate();
    }

    /**
     * Returns the zoom level.
     *
     * Returns:
     *   Frames per logical pixel.
     */
    double framesPerPixel() {
        sync();
        return fpp_;
    }

    /**
     * Returns the first visible frame.
     *
     * Returns:
     *   Frame position (fractional).
     */
    double viewStartFrame() {
        sync();
        return viewStart_;
    }

    /**
     * Returns the waveform area.
     *
     * Returns:
     *   Absolute rectangle (empty when no sampler is selected).
     */
    RectF waveformRect() {
        sync();
        return samplerId() == 0 ? RectF.init : wave_;
    }

    /**
     * Maps a frame to an absolute x coordinate.
     *
     * Params:
     *   frame = Frame index.
     *
     * Returns:
     *   X (may lie outside the waveform when scrolled away).
     */
    float frameToX(size_t frame) {
        sync();
        return frameX(frame);
    }

    /**
     * Maps an absolute x coordinate to the nearest frame.
     *
     * Params:
     *   x = X.
     *
     * Returns:
     *   Frame clamped to [0, frames].
     */
    size_t xToFrame(float x) {
        sync();
        return xFrame(x);
    }

    /**
     * Returns the loop start marker grab rectangle.
     *
     * Returns:
     *   Absolute rectangle (empty without a sample).
     */
    RectF loopStartMarkerRect() {
        sync();
        return markerRect(dragMarker_ == 1 ? dragStart_ : info_[slot_].loopStart);
    }

    /**
     * Returns the loop end marker grab rectangle.
     *
     * Returns:
     *   Absolute rectangle (empty without a sample).
     */
    RectF loopEndMarkerRect() {
        sync();
        return markerRect(dragMarker_ == 2 ? dragEnd_ : info_[slot_].loopEnd);
    }

    /**
     * Returns the amplitude envelope editor.
     *
     * Returns:
     *   Editor.
     */
    SampleEnvelopeEditor envelopeEditor() {
        sync();
        return env_;
    }

    /**
     * Returns the envelope editor bounds.
     *
     * Returns:
     *   Absolute rectangle (empty when hidden).
     */
    RectF envelopeEditorRect() {
        sync();
        return env_.visible ? env_.bounds : RectF.init;
    }

    /**
     * Returns a note field.
     *
     * Params:
     *   k = 0 = root, 1 = low, 2 = high.
     *
     * Returns:
     *   Field.
     */
    SampleNumberBox noteBox(uint k) {
        sync();
        return k == 0 ? rootBox_ : (k == 1 ? lowBox_ : highBox_);
    }

    override bool handleStudioAction(StudioAction action) {
        switch (action) {
        case StudioAction.zoomIn:
            zoomIn();
            return true;
        case StudioAction.zoomOut:
            zoomOut();
            return true;
        case StudioAction.zoomReset:
            zoomFit();
            return true;
        default:
            return false;
        }
    }

    override Widget hitTest(Point2F p) {
        sync();
        return super.hitTest(p);
    }

    override void layoutChildren() {
        immutable bool on = samplerId() != 0;
        foreach (c; children) {
            c.visible = on;
        }
        float x = bounds.x + 4.0f;
        immutable float ty = bounds.y + 3.0f;
        immutable float h = TOOLBAR_HEIGHT - 6.0f;
        slotDropdown_.arrange(RectF(x, ty, 120.0f, h));
        x += 124.0f;
        importButton_.arrange(RectF(x, ty, 76.0f, h));
        x += 80.0f;
        loopModeDropdown_.arrange(RectF(x, ty, 100.0f, h));
        x += 104.0f;
        zoomOutButton_.arrange(RectF(x, ty, 26.0f, h));
        x += 28.0f;
        zoomInButton_.arrange(RectF(x, ty, 26.0f, h));
        x += 28.0f;
        zoomFitButton_.arrange(RectF(x, ty, 40.0f, h));
        immutable float fy = bounds.y + TOOLBAR_HEIGHT + 3.0f;
        rootBox_.arrange(RectF(bounds.x + 44.0f, fy, 48.0f, h));
        lowBox_.arrange(RectF(bounds.x + 136.0f, fy, 48.0f, h));
        highBox_.arrange(RectF(bounds.x + 228.0f, fy, 48.0f, h));
        immutable float top = bounds.y + TOOLBAR_HEIGHT + FIELDS_HEIGHT;
        immutable float envH = ENVELOPE_HEIGHT < bounds.h * 0.4f ? ENVELOPE_HEIGHT : bounds.h * 0.4f;
        env_.arrange(RectF(bounds.x + 4.0f, bounds.bottom() - envH - 4.0f, bounds.w - 8.0f, envH));
        immutable float wh = env_.bounds.y - 4.0f - top;
        wave_ = RectF(bounds.x + 4.0f, top, bounds.w - 8.0f > 0.0f ? bounds.w - 8.0f : 0.0f, wh > 0.0f ? wh : 0.0f);
        if (fitPending_) {
            applyFit();
        } else {
            clampView();
        }
    }

    override void draw(IRenderer2D r, const ref StudioTheme theme) {
        if (!visible) {
            return;
        }
        sync();
        r.pushClip(bounds);
        paint(r, theme);
        drawChildren(r, theme);
        r.popClip();
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        r.fillRect(bounds, theme.panel);
        if (samplerId() == 0) {
            r.drawText(Point2F(bounds.x + 8.0f, bounds.y + 8.0f), "Select a Sampler module to edit samples",
                FontId.ui, theme.fontSizeBody, theme.textDim);
            return;
        }
        r.fillRect(RectF(bounds.x, bounds.y, bounds.w, TOOLBAR_HEIGHT), theme.panelRaised);
        immutable float sl = r.lineHeight(FontId.ui, theme.fontSizeSmall);
        immutable float fy = bounds.y + TOOLBAR_HEIGHT + (FIELDS_HEIGHT - sl) * 0.5f;
        r.drawText(Point2F(bounds.x + 8.0f, fy), "Root", FontId.ui, theme.fontSizeSmall, theme.textDim);
        r.drawText(Point2F(bounds.x + 100.0f, fy), "Low", FontId.ui, theme.fontSizeSmall, theme.textDim);
        r.drawText(Point2F(bounds.x + 192.0f, fy), "High", FontId.ui, theme.fontSizeSmall, theme.textDim);
        paintWaveform(r, theme);
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left || samplerId() == 0 || info_[slot_].frames == 0) {
            return false;
        }
        immutable RectF rs = markerRect(info_[slot_].loopStart);
        immutable RectF re = markerRect(info_[slot_].loopEnd);
        immutable bool inS = rs.contains(e.pos);
        immutable bool inE = re.contains(e.pos);
        if (!inS && !inE) {
            return false;
        }
        immutable float ds = inS ? abs(e.pos.x - (rs.x + MARKER_GRAB)) : float.max;
        immutable float de = inE ? abs(e.pos.x - (re.x + MARKER_GRAB)) : float.max;
        dragMarker_ = de < ds ? 2 : 1;
        dragStart_ = info_[slot_].loopStart;
        dragEnd_ = info_[slot_].loopEnd;
        invalidate();
        return true;
    }

    override bool onMouseMove(const ref MouseEvent e) {
        if (dragMarker_ == 0) {
            return false;
        }
        immutable size_t frames = info_[slot_].frames;
        immutable size_t f = xFrame(e.pos.x);
        if (dragMarker_ == 1) {
            dragStart_ = f < dragEnd_ ? f : (dragEnd_ > 0 ? dragEnd_ - 1 : 0);
        } else {
            dragEnd_ = f > dragStart_ ? (f < frames ? f : frames) : dragStart_ + 1;
        }
        invalidate();
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        if (dragMarker_ == 0) {
            return false;
        }
        dragMarker_ = 0;
        immutable size_t ns = dragStart_;
        immutable size_t ne = dragEnd_;
        if (ns != info_[slot_].loopStart || ne != info_[slot_].loopEnd) {
            editSlot(slot_, (SamplerSlotAsset* a) {
                a.loopStart = ns;
                a.loopEnd = ne;
            }, "Edit Loop");
        }
        invalidate();
        return true;
    }

    override void onCaptureLost() {
        dragMarker_ = 0;
        invalidate();
    }

    override bool onScroll(const ref ScrollEvent e) {
        if (samplerId() == 0 || !wave_.contains(e.pos) || info_[slot_].frames == 0) {
            return false;
        }
        if ((e.modifiers & cast(uint) KeyModifiers.command) != 0) {
            immutable double f = 1.0 + clampf(e.deltaY, -50.0f, 50.0f) * 0.02;
            zoomBy(f > 0.1 ? f : 0.1, e.pos.x);
            return true;
        }
        immutable float d = e.deltaX != 0.0f ? e.deltaX : e.deltaY;
        viewStart_ -= cast(double) d * fpp_;
        clampView();
        invalidate();
        return true;
    }

    override bool onMagnify(Point2F pos, float magnification) {
        if (samplerId() == 0 || info_[slot_].frames == 0) {
            return false;
        }
        immutable double f = 1.0 + magnification;
        zoomBy(f > 0.1 ? f : 0.1, pos.x);
        return true;
    }

    private bool gestureActive() const {
        return dragMarker_ != 0 || env_.gestureActive() || rootBox_.gestureActive() || lowBox_.gestureActive()
            || highBox_.gestureActive();
    }

    private SampleNumberBox makeNoteBox(string boxId) {
        auto b = new SampleNumberBox();
        b.id = boxId;
        b.onChange = (float v) {
            fieldDirty_ = true;
            if (!b.gestureActive()) {
                commitFields();
            }
        };
        b.onGestureEnd = () {
            if (fieldDirty_) {
                commitFields();
            }
        };
        return b;
    }

    private void loadInfo() {
        info_[] = SampleSlotInfo.init;
        loopModeIdx_ = -1;
        immutable uint id = boundModule_;
        if (id == 0) {
            return;
        }
        auto desc = ModuleRegistry.findByTypeId("synth.sampler");
        foreach (i, ref p; desc.params) {
            if (p.name == "Loop Mode") {
                loopModeIdx_ = cast(int) i;
            }
        }
        const(ubyte)[] blob = moduleBlob(id);
        if (blob.length == 0) {
            return;
        }
        auto vt = desc.vtable;
        void* temp = vt.create();
        if (temp is null) {
            return;
        }
        scope (exit) vt.destroy(temp);
        if (!vt.deserializeExtra(temp, blob, ctx_.session.sampleRate())) {
            return;
        }
        auto sampler = cast(const(Sampler)*) temp;
        foreach (i; 0 .. Sampler.MAX_SLOTS) {
            const(SamplerSlotAsset)* a = sampler.slotAsset(cast(uint) i);
            if (a is null || a.left.length == 0) {
                continue;
            }
            SampleSlotInfo inf;
            inf.occupied = true;
            inf.frames = a.left.length;
            inf.sampleRate = a.sampleRate;
            inf.rootNote = a.rootNote;
            inf.lowNote = a.lowNote;
            inf.highNote = a.highNote;
            inf.loopStart = a.loopStart;
            inf.loopEnd = a.loopEnd > a.loopStart && a.loopEnd <= inf.frames ? a.loopEnd : inf.frames;
            inf.volEnv = a.volEnv;
            inf.volEnvCount = a.volEnvCount;
            inf.volSustainIdx = a.volSustainIdx;
            info_[i] = inf;
        }
    }

    private const(ubyte)[] moduleBlob(uint id) const {
        foreach (ref m; ctx_.session.document().modules) {
            if (m.id == id) {
                return m.extraBlob;
            }
        }
        return null;
    }

    private float moduleParam(uint id, int idx, float fallback) const {
        foreach (ref m; ctx_.session.document().modules) {
            if (m.id == id) {
                return idx >= 0 && idx < m.paramValues.length ? m.paramValues[idx] : fallback;
            }
        }
        return fallback;
    }

    private void refreshControls() {
        foreach (i, ref inf; info_) {
            slotDropdown_.items[i] = inf.occupied
                ? format("%d: %.2fs", i + 1, cast(double) inf.frames / (inf.sampleRate > 0.0f ? inf.sampleRate : 44_100.0f))
                : format("%d: empty", i + 1);
        }
        slotDropdown_.select(slot_, false);
        immutable float lm = moduleParam(boundModule_, loopModeIdx_, 0.0f);
        immutable long li = cast(long) round(lm);
        loopModeDropdown_.select(li < 0 ? 0 : (li > 2 ? 2 : cast(size_t) li), false);
        const inf = &info_[slot_];
        rootBox_.setValue(inf.rootNote, false);
        lowBox_.setValue(inf.lowNote, false);
        highBox_.setValue(inf.highNote, false);
        immutable bool has = inf.occupied;
        rootBox_.enabled = has;
        lowBox_.enabled = has;
        highBox_.enabled = has;
        env_.enabled = has;
        loadEnvelope();
    }

    private void loadEnvelope() {
        const inf = &info_[slot_];
        if (inf.volEnvCount >= 3) {
            immutable float last = inf.volEnv[inf.volEnvCount - 1].timeSec;
            envSpan_ = last > 0.0f ? last : 1.0f;
            Point2F[] pts = new Point2F[inf.volEnvCount];
            foreach (k; 0 .. inf.volEnvCount) {
                pts[k] = Point2F(clampf(inf.volEnv[k].timeSec / envSpan_, 0.0f, 1.0f), clampf(inf.volEnv[k].value, 0.0f, 1.0f));
            }
            pts[$ - 1].x = 1.0f;
            env_.points = pts;
            immutable int si = inf.volSustainIdx;
            env_.sustainIndex = si >= 1 && si + 1 < cast(int) inf.volEnvCount ? cast(size_t) si : 1;
        } else {
            envSpan_ = 1.0f;
            env_.points = [Point2F(0.0f, 0.0f), Point2F(0.01f, 1.0f), Point2F(0.3f, 1.0f), Point2F(1.0f, 0.0f)];
            env_.sustainIndex = 2;
        }
        env_.selected = -1;
        env_.invalidate();
    }

    private void commitFields() {
        fieldDirty_ = false;
        if (!info_[slot_].occupied) {
            return;
        }
        immutable ubyte root = cast(ubyte) round(rootBox_.value());
        ubyte lo = cast(ubyte) round(lowBox_.value());
        ubyte hi = cast(ubyte) round(highBox_.value());
        if (lo > hi) {
            if (lo != info_[slot_].lowNote) {
                hi = lo;
            } else {
                lo = hi;
            }
        }
        if (root == info_[slot_].rootNote && lo == info_[slot_].lowNote && hi == info_[slot_].highNote) {
            refreshControls();
            return;
        }
        editSlot(slot_, (SamplerSlotAsset* a) {
            a.rootNote = root;
            a.lowNote = lo;
            a.highNote = hi;
        }, "Edit Key Range");
    }

    private void commitEnvelope() {
        if (!info_[slot_].occupied) {
            loadEnvelope();
            return;
        }
        immutable size_t n = env_.points.length;
        EnvBreakpoint[SamplerSlotAsset.MAX_BREAKPOINTS] next;
        foreach (k; 0 .. n) {
            immutable float curve = k < info_[slot_].volEnvCount ? info_[slot_].volEnv[k].curve : 1.0f;
            next[k] = EnvBreakpoint(env_.points[k].x * envSpan_, env_.points[k].y, curve);
        }
        immutable int sus = cast(int) env_.sustainIndex;
        editSlot(slot_, (SamplerSlotAsset* a) {
            a.volEnv = next;
            a.volEnvCount = cast(uint) n;
            a.volSustainIdx = sus;
        }, "Edit Envelope");
    }

    private bool editSlot(uint slot, scope void delegate(SamplerSlotAsset*) mutate, string label) {
        immutable uint id = samplerId();
        if (id == 0 || slot >= Sampler.MAX_SLOTS) {
            return false;
        }
        auto vt = ModuleRegistry.findByTypeId("synth.sampler").vtable;
        void* temp = vt.create();
        if (temp is null) {
            ctx_.setStatus("Out of memory");
            return false;
        }
        scope (exit) vt.destroy(temp);
        const(ubyte)[] blob = moduleBlob(id);
        if (blob.length > 0 && !vt.deserializeExtra(temp, blob, ctx_.session.sampleRate())) {
            ctx_.setStatus("Sampler data could not be decoded");
            return false;
        }
        const(SamplerSlotAsset)* cur = (cast(const(Sampler)*) temp).slotAsset(slot);
        if (cur is null || cur.left.length == 0) {
            return false;
        }
        SamplerSlotAsset* next = SamplerSlotAsset.createFromPlanar(cur.left[], cur.right[], cur.sampleRate,
            cur.rootNote, cur.lowNote, cur.highNote, cur.loopStart, cur.loopEnd);
        if (next is null) {
            ctx_.setStatus("Out of memory");
            return false;
        }
        next.volEnv = cur.volEnv;
        next.volEnvCount = cur.volEnvCount;
        next.volSustainIdx = cur.volSustainIdx;
        next.panEnv = cur.panEnv;
        next.panEnvCount = cur.panEnvCount;
        next.panSustainIdx = cur.panSustainIdx;
        next.pitchEnv = cur.pitchEnv;
        next.pitchEnvCount = cur.pitchEnvCount;
        next.pitchSustainIdx = cur.pitchSustainIdx;
        mutate(next);
        immutable size_t frames = next.left.length;
        if (!(next.loopEnd > next.loopStart && next.loopEnd <= frames)) {
            next.loopStart = 0;
            next.loopEnd = frames;
        }
        void* old = null;
        vt.swapAsset(temp, slot, next, old);
        if (old !is null) {
            SamplerSlotAsset.destroyErased(old);
        }
        ubyte[] outBlob;
        if (!vt.serializeExtra(temp, outBlob) || !ctx_.session.doSetModuleExtra(id, outBlob, label)) {
            ctx_.setStatus("Sample edit could not be applied");
            sync();
            return false;
        }
        sync();
        return true;
    }

    private void applyFit() {
        immutable size_t frames = info_[slot_].frames;
        fittedFrames_ = frames;
        fitPending_ = false;
        viewStart_ = 0.0;
        fpp_ = frames > 0 && wave_.w > 0.0f ? cast(double) frames / wave_.w : 1.0;
    }

    private void clampView() {
        immutable size_t frames = info_[slot_].frames;
        immutable double maxStart = cast(double) frames - wave_.w * fpp_;
        if (viewStart_ > maxStart) {
            viewStart_ = maxStart;
        }
        if (viewStart_ < 0.0) {
            viewStart_ = 0.0;
        }
    }

    private float frameX(size_t frame) const {
        return cast(float)(wave_.x + (cast(double) frame - viewStart_) / fpp_);
    }

    private size_t xFrame(float x) const {
        immutable double f = round(viewStart_ + (cast(double) x - wave_.x) * fpp_);
        immutable double frames = cast(double) info_[slot_].frames;
        return cast(size_t)(f < 0.0 ? 0.0 : (f > frames ? frames : f));
    }

    private RectF markerRect(size_t frame) {
        if (samplerId() == 0 || info_[slot_].frames == 0) {
            return RectF.init;
        }
        immutable float x = frameX(frame);
        return RectF(x - MARKER_GRAB, wave_.y, 2.0f * MARKER_GRAB, wave_.h);
    }

    private void fetchPeaks() {
        immutable size_t frames = info_[slot_].frames;
        if (frames == 0) {
            havePeaks_ = false;
            return;
        }
        immutable double want = ceil(cast(double) frames / fpp_);
        uint buckets = 1;
        while (buckets < want && buckets < MAX_PEAK_BUCKETS) {
            buckets <<= 1;
        }
        if (havePeaks_ && peaksRev_ == boundRev_ && peaksSlot_ == slot_ && peaksBuckets_ == buckets
                && peaksModule_ == boundModule_) {
            return;
        }
        peaksRev_ = boundRev_;
        peaksSlot_ = slot_;
        peaksBuckets_ = buckets;
        peaksModule_ = boundModule_;
        havePeaks_ = ctx_.session.samplePeaks(boundModule_, slot_, buckets, peaks_) && peaks_.minL.length > 0;
    }

    private void paintWaveform(IRenderer2D r, const ref StudioTheme theme) {
        r.fillRoundedRect(wave_, theme.radiusSm, theme.panelSunken);
        immutable size_t frames = info_[slot_].frames;
        if (frames == 0 || wave_.w < 1.0f || wave_.h < 2.0f) {
            immutable float lh = r.lineHeight(FontId.ui, theme.fontSizeBody);
            r.drawText(Point2F(wave_.x + 8.0f, wave_.y + (wave_.h - lh) * 0.5f), "Empty slot - use Import...",
                FontId.ui, theme.fontSizeBody, theme.textDim);
            return;
        }
        r.pushClip(wave_);
        immutable size_t ls = dragMarker_ == 1 ? dragStart_ : info_[slot_].loopStart;
        immutable size_t le = dragMarker_ == 2 ? dragEnd_ : info_[slot_].loopEnd;
        immutable float lx0 = frameX(ls);
        immutable float lx1 = frameX(le);
        r.fillRect(RectF(lx0, wave_.y, lx1 - lx0, wave_.h), theme.selection.withAlpha(0.12f));
        immutable float halfH = wave_.h * 0.25f;
        immutable float cyL = wave_.y + halfH;
        immutable float cyR = wave_.y + 3.0f * halfH;
        r.fillRect(RectF(wave_.x, cyL, wave_.w, 1.0f), theme.gridLine);
        r.fillRect(RectF(wave_.x, cyR, wave_.w, 1.0f), theme.gridLine);
        r.fillRect(RectF(wave_.x, wave_.y + wave_.h * 0.5f, wave_.w, 1.0f), theme.border);
        fetchPeaks();
        if (havePeaks_) {
            immutable size_t n = peaks_.minL.length;
            immutable double scale = cast(double) n / cast(double) frames;
            immutable int cols = cast(int) wave_.w;
            foreach (c; 0 .. cols) {
                immutable double f0 = viewStart_ + c * fpp_;
                if (f0 >= frames) {
                    break;
                }
                size_t b0 = cast(size_t) floor(f0 * scale);
                size_t b1 = cast(size_t) ceil((f0 + fpp_) * scale);
                b0 = b0 < n ? b0 : n - 1;
                b1 = b1 > b0 + 1 ? (b1 < n ? b1 : n) : b0 + 1;
                float mnL = peaks_.minL[b0];
                float mxL = peaks_.maxL[b0];
                float mnR = peaks_.minR[b0];
                float mxR = peaks_.maxR[b0];
                foreach (b; b0 + 1 .. b1) {
                    mnL = peaks_.minL[b] < mnL ? peaks_.minL[b] : mnL;
                    mxL = peaks_.maxL[b] > mxL ? peaks_.maxL[b] : mxL;
                    mnR = peaks_.minR[b] < mnR ? peaks_.minR[b] : mnR;
                    mxR = peaks_.maxR[b] > mxR ? peaks_.maxR[b] : mxR;
                }
                immutable float x = wave_.x + c;
                drawColumn(r, x, cyL, halfH, mnL, mxL, theme.wireAudio);
                drawColumn(r, x, cyR, halfH, mnR, mxR, theme.wireAudio);
            }
        }
        immutable ColorRGBA mc = theme.warning;
        r.fillRect(RectF(lx0 - 0.5f, wave_.y, 1.5f, wave_.h), mc);
        r.fillRect(RectF(lx0 - 0.5f, wave_.y, 8.0f, 8.0f), mc);
        r.fillRect(RectF(lx1 - 1.0f, wave_.y, 1.5f, wave_.h), mc);
        r.fillRect(RectF(lx1 - 7.5f, wave_.y, 8.0f, 8.0f), mc);
        r.popClip();
    }

    private static void drawColumn(IRenderer2D r, float x, float cy, float halfH, float mn, float mx, ColorRGBA c) {
        immutable float top = cy - clampf(mx, -1.0f, 1.0f) * halfH;
        immutable float bot = cy - clampf(mn, -1.0f, 1.0f) * halfH;
        immutable float h = bot - top > 1.0f ? bot - top : 1.0f;
        r.fillRect(RectF(x, top, 1.0f, h), c);
    }

    private static float abs(float v) {
        return v < 0.0f ? -v : v;
    }
}
