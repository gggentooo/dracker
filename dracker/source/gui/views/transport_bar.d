/**
 * File:         source/gui/views/transport_bar.d
 * Module:       gui.views.transport_bar
 * Phase:        Phase 8.1 — Studio Transport Bar & Audio/MIDI Header
 *
 * Purpose:
 *   Top studio toolbar hosting Play/Stop/Play-Pattern/Record/Follow/Loop controls, BPM/TPL drag boxes (one undo
 *   step per drag gesture, reflecting external/undo changes), edit octave/step boxes, the playhead readout with
 *   engine tempo and dirty indicator, the DSP load meter with xrun counter, master stereo peak meters with decay and
 *   a held clip light, the audio output device picker and a MIDI sources indicator. Exposes stable widget ids and
 *   controlRect() geometry for automated GUI tests.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Reads StudioContext.telemetry (refreshed by StudioContext.tick() from lock-free TripleBuffer
 *   snapshots) and the const session document; every document mutation goes through StudioSession (undoable),
 *   transport commands are non-undoable session calls. No per-frame allocation except when a displayed text changes.
 *
 * Dependencies:
 *   Internal: app.keymap, gui.{renderer,theme,widgets}, gui.views.studio_context
 *   External: core.time (MonoTime), std.format (format), std.math (log10, pow, round)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum TransportGlyph / enum TransportLight (theme light token of a lit button)
 *   - class TransportButton : Button (lit state + drawn glyph; lit buttons also get a 2 pt strong outline)
 *   - class GroupedDragBox : NumericDragBox (onDragBegin/onDragEnd gesture hooks)
 *   - class DeviceDropdown : Dropdown (onBeforeOpen refresh hook)
 *   - class TransportBarView : Widget, StudioCommandSink : this(StudioContext), refresh(), refreshDevices(),
 *     controlRect(id), readoutText(), dspText(), xrunText(), midiText(), meterLevel(), clipLit(), resetClip(),
 *     isAnimating(), handleStudioAction(toggleFollow / stepUp / stepDown)
 *   - Widget ids: transport.play, transport.stop, transport.playPattern, transport.record, transport.follow,
 *     transport.loop, transport.bpm, transport.tpl, transport.octave, transport.step, transport.device;
 *     geometry-only ids: transport.readout, transport.dirty, transport.dsp, transport.meters, transport.clip,
 *     transport.midi
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.1)
 */
module gui.views.transport_bar;

import core.time : MonoTime;
import std.format : format;
import std.math : log10, pow, round;

import app.keymap : StudioAction, StudioCommandSink;
import gui.renderer : ColorRGBA, FontId, IRenderer2D, ITextMeasurer, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.widgets : Button, Dropdown, fillCircle, MouseButton, MouseEvent, NumericDragBox, ValueRange, Widget;
import gui.views.studio_context : StudioContext;

/**
 * Icon drawn by a TransportButton.
 */
enum TransportGlyph : ubyte {
    text = 0,
    play = 1,
    stop = 2,
    playPattern = 3,
    record = 4
}

/**
 * Which theme light token a lit transport button uses.
 */
enum TransportLight : ubyte {
    play = 0,
    record = 1,
    loop = 2
}

/**
 * Toolbar button with a "lit" (active) state and a vector glyph or text caption.
 */
class TransportButton : Button {
    TransportGlyph glyph = TransportGlyph.text;
    bool lit = false;
    bool pausedGlyph = false;
    TransportLight light = TransportLight.play;

    /**
     * Creates a button.
     *
     * Params:
     *   caption = Text (used for TransportGlyph.text).
     *   g = Glyph.
     *   handler = Click handler.
     */
    this(string caption, TransportGlyph g, void delegate() handler) {
        super(caption, handler);
        glyph = g;
    }

    /**
     * Returns the lit fill color for this button from the theme.
     *
     * Params:
     *   theme = Theme.
     *
     * Returns:
     *   transportPlayLit, transportRecordLit or transportLoopLit.
     */
    ColorRGBA litColor(const ref StudioTheme theme) const {
        final switch (light) {
        case TransportLight.play:
            return theme.transportPlayLit;
        case TransportLight.record:
            return theme.transportRecordLit;
        case TransportLight.loop:
            return theme.transportLoopLit;
        }
    }

    /**
     * Draws the button background, lit tint and glyph.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        immutable bool on = isEffectivelyEnabled();
        ColorRGBA top = theme.panelRaised.brighten(0.04f);
        ColorRGBA bottom = theme.panelRaised;
        if (lit) {
            top = litColor(theme);
            bottom = theme.emphasize(top, 0.08f);
        } else if (isPressed()) {
            top = theme.emphasize(theme.panelRaised, 0.06f);
        } else if (isHovered() && on) {
            top = theme.emphasize(top, 0.06f);
            bottom = theme.emphasize(bottom, 0.06f);
        }
        r.fillRoundedRectGradient(bounds, theme.radiusMd, top, bottom);
        r.strokeRoundedRect(bounds, theme.radiusMd, lit ? 2.0f * theme.borderWidth : theme.borderWidth,
            isPressed() || lit ? theme.borderStrong : theme.border);
        immutable ColorRGBA ink = !on ? theme.textDisabled : (lit ? theme.accentText : theme.text);
        immutable Point2F c = bounds.center();
        immutable float s = (bounds.h < bounds.w ? bounds.h : bounds.w) * 0.22f;
        final switch (glyph) {
        case TransportGlyph.text:
            immutable float size = theme.fontSizeSmall;
            immutable float tw = r.measureText(text, FontId.ui, size);
            immutable float lh = r.lineHeight(FontId.ui, size);
            r.drawText(Point2F(bounds.x + (bounds.w - tw) * 0.5f, bounds.y + (bounds.h - lh) * 0.5f), text,
                FontId.ui, size, ink);
            break;
        case TransportGlyph.play:
            if (pausedGlyph) {
                r.fillRect(RectF(c.x - s, c.y - s, s * 0.7f, 2.0f * s), ink);
                r.fillRect(RectF(c.x + s * 0.3f, c.y - s, s * 0.7f, 2.0f * s), ink);
            } else {
                drawTriangle(r, c, s, ink);
            }
            break;
        case TransportGlyph.stop:
            r.fillRect(RectF(c.x - s, c.y - s, 2.0f * s, 2.0f * s), ink);
            break;
        case TransportGlyph.playPattern:
            drawTriangle(r, Point2F(c.x + s * 0.35f, c.y), s, ink);
            r.fillRect(RectF(c.x - s * 1.45f, c.y - s, s * 0.45f, 2.0f * s), ink);
            break;
        case TransportGlyph.record:
            fillCircle(r, c, s, lit ? theme.accentText : theme.danger);
            break;
        }
    }

    private static void drawTriangle(IRenderer2D r, Point2F c, float s, ColorRGBA ink) {
        Point2F[4] tri = [Point2F(c.x - s * 0.8f, c.y - s), Point2F(c.x + s, c.y), Point2F(c.x - s * 0.8f, c.y + s),
            Point2F(c.x - s * 0.8f, c.y - s)];
        r.drawPolyline(tri[], 2.0f, ink);
        r.drawLine(Point2F(c.x - s * 0.4f, c.y - s * 0.5f), Point2F(c.x - s * 0.4f, c.y + s * 0.5f), 2.0f, ink);
        r.drawLine(Point2F(c.x, c.y - s * 0.25f), Point2F(c.x, c.y + s * 0.25f), 2.0f, ink);
    }
}

/**
 * NumericDragBox reporting the start and end of a mouse drag gesture (used to wrap a drag in one undo group).
 */
class GroupedDragBox : NumericDragBox {
    void delegate() onDragBegin;
    void delegate() onDragEnd;
    private bool gesture_ = false;

    /**
     * Creates a drag box.
     *
     * Params:
     *   r = Value range.
     *   decimalPlaces = Displayed decimals.
     */
    this(ValueRange r, int decimalPlaces) {
        super(r, decimalPlaces);
    }

    /**
     * Reports whether a drag gesture is open.
     *
     * Returns:
     *   True between drag start and release.
     */
    bool inGesture() const {
        return gesture_;
    }

    /**
     * Starts a drag and fires onDragBegin.
     *
     * Params:
     *   e = Mouse event.
     *
     * Returns:
     *   Handled flag.
     */
    override bool onMouseDown(const ref MouseEvent e) {
        immutable bool handled = super.onMouseDown(e);
        if (isDragging() && !gesture_) {
            gesture_ = true;
            if (onDragBegin !is null) {
                onDragBegin();
            }
        }
        return handled;
    }

    /**
     * Ends a drag and fires onDragEnd.
     *
     * Params:
     *   e = Mouse event.
     *
     * Returns:
     *   Handled flag.
     */
    override bool onMouseUp(const ref MouseEvent e) {
        immutable bool handled = super.onMouseUp(e);
        finishGesture();
        return handled;
    }

    /**
     * Ends a drag interrupted by capture loss.
     */
    override void onCaptureLost() {
        super.onCaptureLost();
        finishGesture();
    }

    private void finishGesture() {
        if (!gesture_) {
            return;
        }
        gesture_ = false;
        if (onDragEnd !is null) {
            onDragEnd();
        }
    }
}

/**
 * Dropdown invoking a refresh hook just before its popup opens.
 */
class DeviceDropdown : Dropdown {
    void delegate() onBeforeOpen;

    /**
     * Creates the dropdown.
     *
     * Params:
     *   choices = Items.
     */
    this(string[] choices) {
        super(choices);
    }

    /**
     * Refreshes items through onBeforeOpen, then opens the popup.
     *
     * Returns:
     *   True if the popup opened.
     */
    override bool open() {
        if (onBeforeOpen !is null && !isOpen()) {
            onBeforeOpen();
        }
        return super.open();
    }
}

private struct CaptionSlot {
    RectF rect;
    string text;
}

/**
 * Horizontal studio transport toolbar.
 */
final class TransportBarView : Widget, StudioCommandSink {
    enum float BAR_HEIGHT = 40.0f;
    enum double CLIP_HOLD_SECONDS = 1.5;
    enum float METER_FLOOR_DB = -60.0f;
    enum float METER_DECAY_DB_PER_SEC = 20.0f;

    double delegate() clock;

    private StudioContext ctx_;
    private TransportButton playBtn_;
    private TransportButton stopBtn_;
    private TransportButton patternBtn_;
    private TransportButton recordBtn_;
    private TransportButton followBtn_;
    private TransportButton loopBtn_;
    private GroupedDragBox bpmBox_;
    private GroupedDragBox tplBox_;
    private NumericDragBox octaveBox_;
    private NumericDragBox stepBox_;
    private DeviceDropdown deviceBox_;
    private CaptionSlot[4] captions_;
    private RectF readoutRect_;
    private RectF dirtyRect_;
    private RectF dspRect_;
    private RectF meterRect_;
    private RectF clipRect_;
    private RectF midiRect_;
    private uint[] deviceIds_;
    private string midiText_;
    private string readout_;
    private long readoutLine_ = -1;
    private uint readoutTick_ = uint.max;
    private double readoutBpm_ = -1.0;
    private string dspText_;
    private int dspPercent_ = -1;
    private string xrunText_;
    private ulong xrunCount_ = ulong.max;
    private float meterL_ = 0.0f;
    private float meterR_ = 0.0f;
    private double lastMeterTime_ = -1.0;
    private double clipUntil_ = -1.0;
    private float lastLoadAvg_ = -1.0f;
    private MonoTime start_;

    /**
     * Builds the toolbar over a studio context.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        ctx_ = ctx;
        start_ = MonoTime.currTime;
        preferredSize = Point2F(0.0f, BAR_HEIGHT);
        playBtn_ = makeButton("transport.play", "Play", TransportGlyph.play, &onPlay);
        stopBtn_ = makeButton("transport.stop", "Stop", TransportGlyph.stop, &onStop);
        patternBtn_ = makeButton("transport.playPattern", "Pat", TransportGlyph.playPattern, &onPlayPattern);
        recordBtn_ = makeButton("transport.record", "Rec", TransportGlyph.record, &onRecord);
        followBtn_ = makeButton("transport.follow", "FOLLOW", TransportGlyph.text, &onFollow);
        loopBtn_ = makeButton("transport.loop", "LOOP", TransportGlyph.text, &onLoop);
        recordBtn_.light = TransportLight.record;
        loopBtn_.light = TransportLight.loop;

        bpmBox_ = add(new GroupedDragBox(ValueRange(20.0f, 999.0f, 125.0f, false, 0.1f), 1));
        bpmBox_.id = "transport.bpm";
        bpmBox_.onChange = &onBpmChanged;
        bpmBox_.onDragBegin = &beginTempoGesture;
        bpmBox_.onDragEnd = &endTempoGesture;
        tplBox_ = add(new GroupedDragBox(ValueRange(1.0f, 255.0f, 6.0f, false, 1.0f), 0));
        tplBox_.id = "transport.tpl";
        tplBox_.onChange = &onTplChanged;
        tplBox_.onDragBegin = &beginTempoGesture;
        tplBox_.onDragEnd = &endTempoGesture;
        octaveBox_ = add(new NumericDragBox(ValueRange(-1.0f, 9.0f, 4.0f, false, 1.0f), 0));
        octaveBox_.id = "transport.octave";
        octaveBox_.pixelsPerStep = 8.0f;
        octaveBox_.onChange = (float v) { ctx_.setEditOctave(cast(int) round(v)); };
        stepBox_ = add(new NumericDragBox(ValueRange(0.0f, 16.0f, 1.0f, false, 1.0f), 0));
        stepBox_.id = "transport.step";
        stepBox_.pixelsPerStep = 8.0f;
        stepBox_.onChange = (float v) { ctx_.editStep = cast(uint) round(v); };

        deviceBox_ = add(new DeviceDropdown(["No audio device"]));
        deviceBox_.id = "transport.device";
        deviceBox_.onSelect = &onDeviceSelected;
        deviceBox_.onBeforeOpen = &refreshDevices;

        refreshDevices();
        refresh();
    }

    /**
     * Returns the logical-coordinate bounds of a control or display region by id.
     *
     * Params:
     *   controlId = One of the ids listed in the module header.
     *
     * Returns:
     *   Bounds, or RectF.init for an unknown id.
     */
    RectF controlRect(string controlId) {
        foreach (c; children()) {
            if (c.id == controlId) {
                return c.bounds;
            }
        }
        switch (controlId) {
        case "transport.readout":
            return readoutRect_;
        case "transport.dirty":
            return dirtyRect_;
        case "transport.dsp":
            return dspRect_;
        case "transport.meters":
            return meterRect_;
        case "transport.clip":
            return clipRect_;
        case "transport.midi":
            return midiRect_;
        default:
            return RectF.init;
        }
    }

    /**
     * Synchronizes button lit states, tempo boxes (unless being edited), and octave/step boxes with the session,
     * context and telemetry. Called automatically before painting.
     */
    void refresh() {
        const doc = ctx_.session.document();
        immutable bool auditioning = ctx_.session.isAuditioningPattern();
        immutable bool playing = ctx_.telemetry.engine.playing;
        playBtn_.lit = playing && !auditioning;
        playBtn_.pausedGlyph = playing && !auditioning;
        patternBtn_.lit = auditioning;
        recordBtn_.lit = ctx_.recording;
        followBtn_.lit = ctx_.followPlayhead;
        loopBtn_.lit = doc.loopEndLine > 0;
        if (!bpmBox_.isDragging() && !bpmBox_.isEditing()) {
            bpmBox_.setValue(cast(float) doc.bpm, false);
        }
        if (!tplBox_.isDragging() && !tplBox_.isEditing()) {
            tplBox_.setValue(cast(float) doc.ticksPerLine, false);
        }
        if (!octaveBox_.isDragging() && !octaveBox_.isEditing()) {
            octaveBox_.setValue(cast(float) ctx_.editOctave, false);
        }
        if (!stepBox_.isDragging() && !stepBox_.isEditing()) {
            stepBox_.setValue(cast(float) ctx_.editStep, false);
        }
    }

    /**
     * Re-reads audio devices and MIDI sources from ctx.audio (disables the picker when ctx.audio is null).
     */
    void refreshDevices() {
        if (ctx_.audio is null) {
            deviceBox_.items = ["No audio device"];
            deviceBox_.selectedIndex = 0;
            deviceBox_.enabled = false;
            deviceIds_ = [0];
            midiText_ = "";
            invalidate();
            return;
        }
        string[] names = ["System Default"];
        uint[] ids = [0];
        foreach (ref d; ctx_.audio.audioDevices()) {
            if (d.outputChannels > 0 && d.id != 0) {
                names ~= d.name.length > 0 ? d.name : d.uid;
                ids ~= d.id;
            }
        }
        deviceBox_.items = names;
        deviceIds_ = ids;
        deviceBox_.enabled = true;
        deviceBox_.selectedIndex = indexOfDevice(ctx_.audio.currentOutputDevice());
        string midi;
        foreach (ref m; ctx_.audio.midiSources()) {
            if (m.isOffline) {
                continue;
            }
            midi ~= (midi.length > 0 ? ", " : "") ~ (m.displayName.length > 0 ? m.displayName : m.name);
        }
        midiText_ = "MIDI: " ~ (midi.length > 0 ? midi : "none");
        invalidate();
    }

    /**
     * Returns the playhead readout ("LLLL:TT  BPM").
     *
     * Returns:
     *   Readout text.
     */
    string readoutText() {
        updateTexts();
        return readout_;
    }

    /**
     * Returns the DSP load text, empty while audio is not running.
     *
     * Returns:
     *   Text.
     */
    string dspText() {
        updateTexts();
        return ctx_.telemetry.audioRunning ? dspText_ : "";
    }

    /**
     * Returns the xrun counter text, empty while audio is not running.
     *
     * Returns:
     *   Text.
     */
    string xrunText() {
        updateTexts();
        return ctx_.telemetry.audioRunning ? xrunText_ : "";
    }

    /**
     * Returns the MIDI sources indicator text (empty when ctx.audio is null).
     *
     * Returns:
     *   Text.
     */
    string midiText() const {
        return midiText_;
    }

    /**
     * Returns the displayed (decaying) master peak level.
     *
     * Params:
     *   right = True for the right channel.
     *
     * Returns:
     *   Linear amplitude.
     */
    float meterLevel(bool right) const {
        return right ? meterR_ : meterL_;
    }

    /**
     * Reports whether the clip light is lit (held CLIP_HOLD_SECONDS after the last clip).
     *
     * Returns:
     *   True while held.
     */
    bool clipLit() {
        return now() < clipUntil_;
    }

    /**
     * Clears the held clip light.
     */
    void resetClip() {
        clipUntil_ = -1.0;
        invalidate();
    }

    /**
     * Advances meter ballistics from the current telemetry (called by paint()).
     */
    void updateMeters() {
        immutable double t = now();
        double dt = lastMeterTime_ < 0.0 ? 0.0 : t - lastMeterTime_;
        if (dt < 0.0) {
            dt = 0.0;
        }
        lastMeterTime_ = t;
        immutable float fall = cast(float) pow(10.0, -METER_DECAY_DB_PER_SEC * dt / 20.0);
        immutable float floorAmp = cast(float) pow(10.0, METER_FLOOR_DB / 20.0);
        meterL_ = ballistics(meterL_ * fall, ctx_.telemetry.engine.graph.masterPeakL, floorAmp);
        meterR_ = ballistics(meterR_ * fall, ctx_.telemetry.engine.graph.masterPeakR, floorAmp);
        const g = ctx_.telemetry.engine.graph;
        if (g.masterClipped || g.masterPeakL > 1.0f || g.masterPeakR > 1.0f) {
            clipUntil_ = t + CLIP_HOLD_SECONDS;
        }
        lastLoadAvg_ = ctx_.telemetry.audioRunning ? ctx_.telemetry.audio.loadAvg : -1.0f;
    }

    /**
     * Reports whether the toolbar needs continuous redraws (playing, meters decaying, clip held, live load changes).
     *
     * Returns:
     *   True while animating.
     */
    override bool isAnimating() {
        const tel = ctx_.telemetry;
        if (tel.engine.playing || meterL_ > 0.0f || meterR_ > 0.0f) {
            return true;
        }
        if (tel.engine.graph.masterPeakL > 0.0f || tel.engine.graph.masterPeakR > 0.0f || tel.engine.graph.masterClipped) {
            return true;
        }
        if (tel.audioRunning && tel.audio.loadAvg != lastLoadAvg_) {
            return true;
        }
        return clipLit();
    }

    /**
     * Handles view-level actions: toggleFollow, stepUp, stepDown.
     *
     * Params:
     *   action = Action.
     *
     * Returns:
     *   True if consumed.
     */
    bool handleStudioAction(StudioAction action) {
        switch (action) {
        case StudioAction.toggleFollow:
            onFollow();
            return true;
        case StudioAction.stepUp:
            ctx_.editStep = ctx_.editStep < 16 ? ctx_.editStep + 1 : 16;
            refresh();
            return true;
        case StudioAction.stepDown:
            ctx_.editStep = ctx_.editStep > 0 ? ctx_.editStep - 1 : 0;
            refresh();
            return true;
        default:
            return false;
        }
    }

    /**
     * Returns the fixed toolbar height.
     *
     * Params:
     *   m = Text measurer.
     *   theme = Theme.
     *
     * Returns:
     *   Preferred size.
     */
    override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        return Point2F(preferredSize.x, BAR_HEIGHT);
    }

    /**
     * Lays out controls left to right; controls that do not fit are hidden.
     */
    override void layoutChildren() {
        immutable float pad = 6.0f;
        immutable float gap = 4.0f;
        immutable float group = 12.0f;
        immutable float h = bounds.h > 2.0f * pad ? bounds.h - 2.0f * pad : bounds.h;
        immutable float y = bounds.y + (bounds.h - h) * 0.5f;
        immutable float boxH = h < 22.0f ? h : 22.0f;
        immutable float boxY = bounds.y + (bounds.h - boxH) * 0.5f;
        float x = bounds.x + pad;
        RectF take(float w, float yy, float hh, float after) {
            immutable RectF r = RectF(x, yy, w, hh);
            x += w + after;
            return r;
        }
        place(playBtn_, take(h, y, h, gap));
        place(stopBtn_, take(h, y, h, gap));
        place(patternBtn_, take(h, y, h, gap));
        place(recordBtn_, take(h, y, h, group));
        place(followBtn_, take(54.0f, y, h, gap));
        place(loopBtn_, take(44.0f, y, h, group));
        captions_[0] = CaptionSlot(take(28.0f, boxY, boxH, 2.0f), "BPM");
        place(bpmBox_, take(58.0f, boxY, boxH, gap));
        captions_[1] = CaptionSlot(take(26.0f, boxY, boxH, 2.0f), "TPL");
        place(tplBox_, take(38.0f, boxY, boxH, group));
        captions_[2] = CaptionSlot(take(28.0f, boxY, boxH, 2.0f), "OCT");
        place(octaveBox_, take(32.0f, boxY, boxH, gap));
        captions_[3] = CaptionSlot(take(34.0f, boxY, boxH, 2.0f), "STEP");
        place(stepBox_, take(32.0f, boxY, boxH, group));
        readoutRect_ = clipToBar(take(132.0f, y, h, 2.0f));
        dirtyRect_ = clipToBar(take(12.0f, y, h, group));
        dspRect_ = clipToBar(take(96.0f, y, h, group));
        meterRect_ = clipToBar(take(104.0f, y, h, 2.0f));
        clipRect_ = clipToBar(take(14.0f, y, h, group));
        place(deviceBox_, take(170.0f, boxY, boxH, group));
        immutable float rest = bounds.right() - pad - x;
        midiRect_ = rest > 0.0f ? RectF(x, y, rest, h) : RectF.init;
    }

    /**
     * Draws the toolbar background, captions, readout, meters and MIDI indicator.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        refresh();
        updateMeters();
        updateTexts();
        r.fillRoundedRectGradient(bounds, 0.0f, theme.panelRaised, theme.panel);
        r.fillRect(RectF(bounds.x, bounds.bottom() - 1.0f, bounds.w, 1.0f), theme.border);
        r.pushClip(bounds);
        immutable float small = theme.fontSizeSmall;
        foreach (ref cap; captions_) {
            if (!cap.rect.isEmpty() && cap.rect.right() <= bounds.right()) {
                drawCentered(r, cap.rect, cap.text, FontId.ui, small, theme.textDim);
            }
        }
        if (!readoutRect_.isEmpty()) {
            r.fillRoundedRect(readoutRect_, theme.radiusSm, theme.panelSunken);
            r.strokeRoundedRect(readoutRect_, theme.radiusSm, theme.borderWidth, theme.border);
            drawCentered(r, readoutRect_, readout_, FontId.mono, theme.fontSizeMono,
                ctx_.telemetry.engine.playing ? theme.accentHot : theme.text);
        }
        if (!dirtyRect_.isEmpty() && ctx_.session.isDirty()) {
            fillCircle(r, dirtyRect_.center(), 3.5f, theme.warning);
        }
        if (!dspRect_.isEmpty() && ctx_.telemetry.audioRunning) {
            drawDsp(r, theme);
        }
        if (!meterRect_.isEmpty()) {
            drawMeters(r, theme);
        }
        if (!midiRect_.isEmpty() && midiText_.length > 0) {
            immutable float lh = r.lineHeight(FontId.ui, small);
            r.pushClip(midiRect_);
            r.drawText(Point2F(midiRect_.x, midiRect_.y + (midiRect_.h - lh) * 0.5f), midiText_, FontId.ui, small,
                theme.textDim);
            r.popClip();
        }
        r.popClip();
    }

    /**
     * Clears the clip light when it is clicked.
     *
     * Params:
     *   e = Mouse event.
     *
     * Returns:
     *   True if the click hit the clip light or the meters.
     */
    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button == MouseButton.left && (clipRect_.contains(e.pos) || meterRect_.contains(e.pos))) {
            resetClip();
            return true;
        }
        return false;
    }

    private TransportButton makeButton(string wid, string caption, TransportGlyph g, void delegate() handler) {
        auto b = add(new TransportButton(caption, g, handler));
        b.id = wid;
        return b;
    }

    private void place(Widget w, RectF r) {
        w.arrange(r);
        w.visible = r.right() <= bounds.right() + 0.01f;
    }

    private RectF clipToBar(RectF r) {
        return r.right() <= bounds.right() + 0.01f ? r : RectF.init;
    }

    private double now() {
        if (clock !is null) {
            return clock();
        }
        if (auto ui = context()) {
            return ui.now();
        }
        return cast(double)(MonoTime.currTime - start_).total!"usecs" / 1.0e6;
    }

    private static float ballistics(float decayed, float peak, float floorAmp) {
        immutable float p = peak > 0.0f ? peak : 0.0f;
        immutable float v = p > decayed ? p : decayed;
        return v < floorAmp ? 0.0f : v;
    }

    private void updateTexts() {
        const tel = ctx_.telemetry;
        if (tel.engine.currentLine != readoutLine_ || tel.engine.currentTick != readoutTick_ || tel.engine.bpm != readoutBpm_) {
            readoutLine_ = tel.engine.currentLine;
            readoutTick_ = tel.engine.currentTick;
            readoutBpm_ = tel.engine.bpm;
            readout_ = format("%04d:%02d  %.1f BPM", readoutLine_, readoutTick_, readoutBpm_);
        }
        immutable float la = tel.audio.loadAvg < 0.0f ? 0.0f : tel.audio.loadAvg;
        immutable int pct = cast(int) round(la * 100.0f);
        if (pct != dspPercent_) {
            dspPercent_ = pct;
            dspText_ = format("DSP %d%%", pct);
        }
        if (tel.audio.xruns != xrunCount_) {
            xrunCount_ = tel.audio.xruns;
            xrunText_ = format("XR %d", xrunCount_);
        }
    }

    private void drawDsp(IRenderer2D r, const ref StudioTheme theme) {
        const a = ctx_.telemetry.audio;
        immutable float small = theme.fontSizeSmall;
        immutable float half = dspRect_.h * 0.5f;
        immutable RectF bar = RectF(dspRect_.x, dspRect_.y + half + 2.0f, dspRect_.w, half - 4.0f > 2.0f ? half - 4.0f : 2.0f);
        r.fillRoundedRect(bar, 2.0f, theme.panelSunken);
        immutable float avg = clamp01(a.loadAvg);
        immutable float pk = clamp01(a.loadPeak);
        immutable ColorRGBA c = avg > 0.85f ? theme.meterHigh : (avg > 0.6f ? theme.meterMid : theme.meterLow);
        if (avg > 0.0f) {
            r.fillRect(RectF(bar.x, bar.y, bar.w * avg, bar.h), c);
        }
        if (pk > 0.0f) {
            r.fillRect(RectF(bar.x + bar.w * pk - 1.0f, bar.y, 2.0f, bar.h), theme.text);
        }
        immutable float lh = r.lineHeight(FontId.ui, small);
        immutable float ty = dspRect_.y + (half - lh) * 0.5f + 1.0f;
        r.drawText(Point2F(dspRect_.x, ty), dspText_, FontId.ui, small, theme.textDim);
        immutable float xw = r.measureText(xrunText_, FontId.ui, small);
        r.drawText(Point2F(dspRect_.right() - xw, ty), xrunText_, FontId.ui, small, a.xruns > 0 ? theme.danger : theme.textDim);
    }

    private void drawMeters(IRenderer2D r, const ref StudioTheme theme) {
        immutable float barH = (meterRect_.h - 6.0f) * 0.5f;
        immutable RectF top = RectF(meterRect_.x, meterRect_.y + 2.0f, meterRect_.w, barH);
        immutable RectF bottom = RectF(meterRect_.x, top.bottom() + 2.0f, meterRect_.w, barH);
        drawMeterBar(r, theme, top, meterL_);
        drawMeterBar(r, theme, bottom, meterR_);
        if (!clipRect_.isEmpty()) {
            immutable bool lit = clipLit();
            r.fillRoundedRect(clipRect_.inset(1.0f), 2.0f, lit ? theme.danger : theme.panelSunken);
            r.strokeRoundedRect(clipRect_.inset(1.0f), 2.0f, theme.borderWidth, lit ? theme.borderStrong : theme.border);
        }
    }

    private void drawMeterBar(IRenderer2D r, const ref StudioTheme theme, RectF bar, float amp) {
        r.fillRect(bar, theme.panelSunken);
        immutable float f = ampToFraction(amp);
        if (f <= 0.0f) {
            return;
        }
        immutable float greenEnd = ampToFraction(cast(float) pow(10.0, -12.0 / 20.0));
        immutable float yellowEnd = ampToFraction(cast(float) pow(10.0, -3.0 / 20.0));
        fillSegment(r, bar, 0.0f, f < greenEnd ? f : greenEnd, theme.meterLow);
        if (f > greenEnd) {
            fillSegment(r, bar, greenEnd, f < yellowEnd ? f : yellowEnd, theme.meterMid);
        }
        if (f > yellowEnd) {
            fillSegment(r, bar, yellowEnd, f, theme.meterHigh);
        }
        r.fillRect(RectF(bar.x + bar.w * greenEnd, bar.y, 1.0f, bar.h), theme.borderStrong);
        r.fillRect(RectF(bar.x + bar.w * yellowEnd, bar.y, 1.0f, bar.h), theme.borderStrong);
    }

    private static void fillSegment(IRenderer2D r, RectF bar, float f0, float f1, ColorRGBA c) {
        if (f1 > f0) {
            r.fillRect(RectF(bar.x + bar.w * f0, bar.y, bar.w * (f1 - f0), bar.h), c);
        }
    }

    private static float ampToFraction(float amp) {
        if (!(amp > 0.0f)) {
            return 0.0f;
        }
        immutable float db = 20.0f * cast(float) log10(amp);
        return clamp01((db - METER_FLOOR_DB) / -METER_FLOOR_DB);
    }

    private static float clamp01(float v) {
        return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
    }

    private static void drawCentered(IRenderer2D r, RectF rect, const(char)[] text, FontId font, float size, ColorRGBA c) {
        immutable float tw = r.measureText(text, font, size);
        immutable float lh = r.lineHeight(font, size);
        r.drawText(Point2F(rect.x + (rect.w - tw) * 0.5f, rect.y + (rect.h - lh) * 0.5f), text, font, size, c);
    }

    private void onPlay() {
        ctx_.session.togglePlay();
        invalidate();
    }

    private void onStop() {
        ctx_.session.stop();
        ctx_.session.seekLine(0);
        invalidate();
    }

    private void onPlayPattern() {
        if (ctx_.session.isAuditioningPattern()) {
            ctx_.session.stop();
        } else if (!ctx_.session.playPattern(ctx_.currentPattern())) {
            ctx_.setStatus("No pattern to play");
        }
        refresh();
        invalidate();
    }

    private void onRecord() {
        ctx_.recording = !ctx_.recording;
        refresh();
        invalidate();
    }

    private void onFollow() {
        ctx_.followPlayhead = !ctx_.followPlayhead;
        refresh();
        invalidate();
    }

    private void onLoop() {
        const doc = ctx_.session.document();
        if (doc.loopEndLine > 0) {
            ctx_.session.doSetLoop(0, 0);
        } else {
            long end = 0;
            foreach (ref c; doc.clips) {
                immutable long e = c.startLine + c.lengthLines;
                end = e > end ? e : end;
            }
            if (end <= 0) {
                foreach (ref p; doc.patterns) {
                    if (p.patternId == ctx_.currentPattern()) {
                        end = p.lines;
                    }
                }
            }
            if (end <= 0 || !ctx_.session.doSetLoop(0, end)) {
                ctx_.setStatus("Nothing to loop");
            }
        }
        refresh();
        invalidate();
    }

    private void beginTempoGesture() {
        ctx_.session.beginEditGroup("Change Tempo");
    }

    private void endTempoGesture() {
        ctx_.session.endEditGroup();
        refresh();
    }

    private void onBpmChanged(float v) {
        const doc = ctx_.session.document();
        immutable double bpm = round(cast(double) v * 10.0) / 10.0;
        if (bpm != doc.bpm && !ctx_.session.doSetTempo(bpm, doc.ticksPerLine)) {
            bpmBox_.setValue(cast(float) doc.bpm, false);
        }
    }

    private void onTplChanged(float v) {
        const doc = ctx_.session.document();
        immutable uint tpl = cast(uint) round(v);
        if (tpl != doc.ticksPerLine && !ctx_.session.doSetTempo(doc.bpm, tpl)) {
            tplBox_.setValue(cast(float) doc.ticksPerLine, false);
        }
    }

    private size_t indexOfDevice(uint deviceId) const {
        foreach (i, d; deviceIds_) {
            if (d == deviceId) {
                return i;
            }
        }
        return 0;
    }

    private void onDeviceSelected(size_t index) {
        if (ctx_.audio is null || index >= deviceIds_.length) {
            return;
        }
        if (ctx_.audio.selectOutputDevice(deviceIds_[index])) {
            ctx_.setStatus("Audio output: " ~ deviceBox_.items[index]);
        } else {
            ctx_.setStatus("Could not switch audio output to " ~ deviceBox_.items[index]);
            deviceBox_.select(indexOfDevice(ctx_.audio.currentOutputDevice()), false);
        }
    }
}
