/**
 * File:         source/gui/views/piano_view.d
 * Module:       gui.views.piano_view
 * Phase:        Phase 8.7 — Full-Width Resizable On-Screen Piano Keyboard
 *
 * Purpose:
 *   Displays a stark black-and-white high-contrast piano keyboard spanning the studio viewport width between
 *   the upper patchbay/rack/scope panes and the lower pattern/timeline/sample panes. The leftmost key is always
 *   C of the shared edit octave (ctx.editOctave), every visible C key displays its octave number below the
 *   black-key zone, and a pair of octave up/down buttons sits at the far right. Key width scales proportionally
 *   with strip height when resized via its top or bottom splitter. Clicking or dragging keys auditions live notes
 *   on the selected module (and injects MIDI note-ons when Record is enabled), while pressed keys, QWERTY piano
 *   holds, external MIDI input, and active pattern playback notes for the selected module highlight in theme.accent.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Never touches RT state directly; auditions notes through StudioSession.triggerLiveNote() /
 *   releaseLiveNote() using Engine.PIANO_KEY_TAG_BASE tags and reads playback highlights from StudioContext.
 *
 * Dependencies:
 *   Internal: app.session, foundation.types, gui.{layout,renderer,theme,widgets}, gui.views.studio_context,
 *             sequencer.engine
 *   External: std.conv (to)
 *
 * Planned API (Types, Functions & Hooks):
 *   - bool isBlackKey(ubyte) / uint whiteKeyOffsetInOctave(ubyte) / float whiteKeyWidthForHeight(float)
 *   - int startMidiForOctave(int)
 *   - class PianoOctaveButton : Button
 *   - class PianoKeyboardView : Widget — this(StudioContext), baseOctave(), keyBedRect(), octaveUpRect(),
 *     octaveDownRect(), whiteKeyWidth(), keyRect(ubyte), hitTestKey(Point2F), visibleWhiteKeyCount(),
 *     pressedMidi(), isKeyHighlighted(ubyte), releaseHeld(), update(), isAnimating()
 *   - Widget ids: "piano.keyboard", "piano.octaveUp", "piano.octaveDown"
 *
 * See_Also:
 *   architecture.md, dev_plan.md
 */
module gui.views.piano_view;

import std.conv : to;

import app.session : MidiNoteEvent;
import foundation.types : ModuleId;
import gui.layout : clampf;
import gui.renderer : ColorRGBA, FontId, IRenderer2D, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.views.studio_context : StudioContext;
import gui.widgets : Button, MouseButton, MouseEvent, Widget;
import sequencer.engine : Engine;

private immutable bool[12] BLACK_KEY_MAP = [
    false, true, false, true, false, false, true, false, true, false, true, false
];

private immutable uint[12] WHITE_INDEX_IN_OCTAVE = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6];

/**
 * Reports whether a MIDI note number corresponds to a black (sharp/flat) piano key.
 *
 * Params:
 *   midi = MIDI note number 0..127.
 *
 * Returns:
 *   True for C#, D#, F#, G#, A#.
 */
bool isBlackKey(ubyte midi) @safe nothrow pure @nogc {
    return BLACK_KEY_MAP[midi % 12];
}

/**
 * Returns the zero-based white-key slot within an octave (0..6) for a MIDI note (black keys return the left white key).
 *
 * Params:
 *   midi = MIDI note number 0..127.
 *
 * Returns:
 *   White key offset 0..6.
 */
uint whiteKeyOffsetInOctave(ubyte midi) @safe nothrow pure @nogc {
    return WHITE_INDEX_IN_OCTAVE[midi % 12];
}

/**
 * Computes white key width in logical points from the keyboard strip height.
 *
 * Params:
 *   height = Strip height in logical points.
 *
 * Returns:
 *   Proportional white key width clamped to [MIN_WHITE_KEY_W, MAX_WHITE_KEY_W].
 */
float whiteKeyWidthForHeight(float height) @safe nothrow pure @nogc {
    return clampf(height * PianoKeyboardView.WHITE_KEY_ASPECT,
        PianoKeyboardView.MIN_WHITE_KEY_W, PianoKeyboardView.MAX_WHITE_KEY_W);
}

/**
 * Returns the leftmost MIDI note number (always C) for an edit octave clamped to [-1, 9].
 *
 * Params:
 *   octave = Edit octave (-1..9).
 *
 * Returns:
 *   MIDI note number for C of that octave (0..120).
 */
int startMidiForOctave(int octave) @safe nothrow pure @nogc {
    immutable int clamped = octave < PianoKeyboardView.MIN_OCTAVE
        ? PianoKeyboardView.MIN_OCTAVE
        : (octave > PianoKeyboardView.MAX_OCTAVE ? PianoKeyboardView.MAX_OCTAVE : octave);
    return (clamped + 1) * 12;
}

/**
 * High-contrast stacked octave step button at the far right of the piano keyboard.
 */
final class PianoOctaveButton : Button {
    private bool up_ = true;

    /**
     * Creates an octave up or down button.
     *
     * Params:
     *   up = True for octave up, false for octave down.
     *   handler = Click callback.
     */
    this(bool up, void delegate() handler) {
        super(up ? "+" : "-", handler);
        up_ = up;
        focusable = false;
        id = up ? "piano.octaveUp" : "piano.octaveDown";
    }

    /**
     * Draws the button in stark high-contrast piano colors with a vector directional triangle.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        immutable bool on = isEffectivelyEnabled();
        ColorRGBA bg = theme.pianoWhiteKey;
        if (isPressed() && on) {
            bg = theme.accent;
        } else if (isHovered() && on) {
            bg = theme.emphasize(bg, 0.12f);
        }
        r.fillRect(bounds, bg);
        r.strokeRoundedRect(bounds, 0.0f, 1.0f, theme.pianoKeyBorder);
        immutable ColorRGBA ink = !on ? theme.textDisabled : (isPressed() ? theme.accentText : theme.pianoKeyText);
        immutable Point2F c = bounds.center();
        immutable float minDim = bounds.w < bounds.h ? bounds.w : bounds.h;
        immutable float s = clampf(minDim * 0.24f, 3.0f, 8.0f);
        if (up_) {
            Point2F[4] tri = [
                Point2F(c.x - s, c.y + s * 0.6f),
                Point2F(c.x, c.y - s * 0.7f),
                Point2F(c.x + s, c.y + s * 0.6f),
                Point2F(c.x - s, c.y + s * 0.6f)
            ];
            r.drawPolyline(tri[], 2.0f, ink);
            r.drawLine(Point2F(c.x - s * 0.45f, c.y + s * 0.2f), Point2F(c.x + s * 0.45f, c.y + s * 0.2f), 2.0f, ink);
        } else {
            Point2F[4] tri = [
                Point2F(c.x - s, c.y - s * 0.6f),
                Point2F(c.x, c.y + s * 0.7f),
                Point2F(c.x + s, c.y - s * 0.6f),
                Point2F(c.x - s, c.y - s * 0.6f)
            ];
            r.drawPolyline(tri[], 2.0f, ink);
            r.drawLine(Point2F(c.x - s * 0.45f, c.y - s * 0.2f), Point2F(c.x + s * 0.45f, c.y - s * 0.2f), 2.0f, ink);
        }
    }
}

/**
 * Full-width stark black-and-white piano keyboard with far-right octave up/down controls.
 */
final class PianoKeyboardView : Widget {
    enum float DEFAULT_HEIGHT = 60.0f;
    enum float MIN_HEIGHT = 48.0f;
    enum float OCTAVE_BAR_WIDTH = 36.0f;
    enum float WHITE_KEY_ASPECT = 0.58f;
    enum float MIN_WHITE_KEY_W = 18.0f;
    enum float MAX_WHITE_KEY_W = 72.0f;
    enum float BLACK_KEY_WIDTH_RATIO = 0.60f;
    enum float BLACK_KEY_HEIGHT_RATIO = 0.62f;
    enum float DEFAULT_VELOCITY = 0.85f;
    enum ubyte RECORD_VELOCITY = 108;
    enum int MIN_OCTAVE = -1;
    enum int MAX_OCTAVE = 9;

    PianoOctaveButton octaveUpBtn;
    PianoOctaveButton octaveDownBtn;

    private StudioContext ctx_;
    private int pressedMidi_ = -1;
    private uint pressedMod_ = 0;
    private int lastOctave_ = 4;
    private ulong[2] lastDrawnMask_ = 0;
    private int lastDrawnPressed_ = -1;

    /**
     * Builds the piano keyboard and its far-right octave buttons.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        ctx_ = ctx;
        id = "piano.keyboard";
        focusable = false;
        preferredSize = Point2F(0.0f, DEFAULT_HEIGHT);
        octaveUpBtn = add(new PianoOctaveButton(true, () { shiftOctave(1); }));
        octaveDownBtn = add(new PianoOctaveButton(false, () { shiftOctave(-1); }));
        update();
    }

    /**
     * Returns the current base octave clamped to [-1, 9] from the shared context.
     *
     * Returns:
     *   Base octave (leftmost key is C of this octave).
     */
    int baseOctave() const {
        immutable int o = ctx_.editOctave;
        if (o < MIN_OCTAVE) {
            return MIN_OCTAVE;
        }
        return o > MAX_OCTAVE ? MAX_OCTAVE : o;
    }

    /**
     * Returns the rectangle occupied by the piano keys (excluding the far-right octave strip).
     *
     * Returns:
     *   Key bed bounds in logical points.
     */
    RectF keyBedRect() const {
        immutable float barW = OCTAVE_BAR_WIDTH < bounds.w ? OCTAVE_BAR_WIDTH : bounds.w;
        immutable float kw = bounds.w > barW ? bounds.w - barW : 0.0f;
        return RectF(bounds.x, bounds.y, kw, bounds.h);
    }

    /**
     * Returns the bounds of the Octave Up button.
     *
     * Returns:
     *   Button bounds.
     */
    RectF octaveUpRect() const {
        return octaveUpBtn.bounds;
    }

    /**
     * Returns the bounds of the Octave Down button.
     *
     * Returns:
     *   Button bounds.
     */
    RectF octaveDownRect() const {
        return octaveDownBtn.bounds;
    }

    /**
     * Returns the logical width of each white key at the current height.
     *
     * Returns:
     *   White key width in points.
     */
    float whiteKeyWidth() const {
        return whiteKeyWidthForHeight(bounds.h);
    }

    /**
     * Computes the rectangle of a MIDI note inside the key bed (or RectF.init if off-screen or out of range).
     *
     * Params:
     *   midi = MIDI note number 0..127.
     *
     * Returns:
     *   Key rectangle in logical window coordinates.
     */
    RectF keyRect(ubyte midi) const {
        if (midi > 127) {
            return RectF.init;
        }
        immutable RectF bed = keyBedRect();
        if (bed.isEmpty()) {
            return RectF.init;
        }
        immutable int startMidi = startMidiForOctave(baseOctave());
        if (cast(int) midi < startMidi) {
            return RectF.init;
        }
        immutable float ww = whiteKeyWidthForHeight(bed.h);
        if (!(ww > 0.0f)) {
            return RectF.init;
        }
        immutable int rel = cast(int) midi - startMidi;
        immutable int octDelta = rel / 12;
        immutable uint whiteIdx = cast(uint) octDelta * 7u + whiteKeyOffsetInOctave(midi);
        if (isBlackKey(midi)) {
            immutable float bw = ww * BLACK_KEY_WIDTH_RATIO;
            immutable float bh = bed.h * BLACK_KEY_HEIGHT_RATIO;
            immutable float cx = bed.x + cast(float)(whiteIdx + 1u) * ww;
            immutable float x = cx - bw * 0.5f;
            if (x >= bed.right()) {
                return RectF.init;
            }
            return RectF(x, bed.y, bw, bh);
        }
        immutable float x = bed.x + cast(float) whiteIdx * ww;
        if (x >= bed.right()) {
            return RectF.init;
        }
        return RectF(x, bed.y, ww, bed.h);
    }

    /**
     * Hit-tests a logical point against visible keys (black keys take priority over overlapping white keys).
     *
     * Params:
     *   p = Pointer position in logical window coordinates.
     *
     * Returns:
     *   MIDI note number 0..127, or -1 if outside active keys.
     */
    int hitTestKey(Point2F p) const {
        immutable RectF bed = keyBedRect();
        if (!bed.contains(p)) {
            return -1;
        }
        immutable int startMidi = startMidiForOctave(baseOctave());
        foreach (m; startMidi .. 128) {
            immutable ubyte um = cast(ubyte) m;
            if (!isBlackKey(um)) {
                continue;
            }
            immutable RectF kr = keyRect(um);
            if (!kr.isEmpty() && kr.contains(p)) {
                return m;
            }
        }
        foreach (m; startMidi .. 128) {
            immutable ubyte um = cast(ubyte) m;
            if (isBlackKey(um)) {
                continue;
            }
            immutable RectF kr = keyRect(um);
            if (kr.isEmpty()) {
                break;
            }
            if (kr.contains(p)) {
                return m;
            }
        }
        return -1;
    }

    /**
     * Counts visible white keys starting from the leftmost C up to the right edge or MIDI 127.
     *
     * Returns:
     *   Visible white key count.
     */
    uint visibleWhiteKeyCount() const {
        immutable RectF bed = keyBedRect();
        if (bed.isEmpty()) {
            return 0;
        }
        immutable int startMidi = startMidiForOctave(baseOctave());
        uint count = 0;
        foreach (m; startMidi .. 128) {
            immutable ubyte um = cast(ubyte) m;
            if (isBlackKey(um)) {
                continue;
            }
            if (keyRect(um).isEmpty()) {
                break;
            }
            count++;
        }
        return count;
    }

    /**
     * Returns the MIDI note currently pressed by mouse/touch on this widget.
     *
     * Returns:
     *   MIDI note number 0..127, or -1 if none.
     */
    int pressedMidi() const {
        return pressedMidi_;
    }

    /**
     * Reports whether midi should currently paint highlighted (mouse press, QWERTY, MIDI, or pattern playback).
     *
     * Params:
     *   midi = MIDI note number 0..127.
     *
     * Returns:
     *   True if highlighted.
     */
    bool isKeyHighlighted(ubyte midi) const {
        if (cast(int) midi == pressedMidi_) {
            return true;
        }
        return ctx_.isNoteHighlighted(midi);
    }

    /**
     * Releases any mouse-held note on the active module cleanly.
     */
    void releaseHeld() {
        if (pressedMidi_ < 0) {
            return;
        }
        if (pressedMod_ != 0) {
            ctx_.session.releaseLiveNote(ModuleId(pressedMod_), Engine.PIANO_KEY_TAG_BASE | cast(uint) pressedMidi_);
        }
        pressedMidi_ = -1;
        pressedMod_ = 0;
        invalidate();
    }

    /**
     * Synchronizes octave bounds and releases stuck mouse holds when the octave or selected module changes.
     */
    void update() {
        immutable int oct = baseOctave();
        if (oct != lastOctave_) {
            releaseHeld();
            lastOctave_ = oct;
        }
        if (pressedMidi_ >= 0 && ctx_.selectedModule() != pressedMod_) {
            releaseHeld();
        }
        octaveUpBtn.enabled = oct < MAX_OCTAVE;
        octaveDownBtn.enabled = oct > MIN_OCTAVE;
    }

    override void layoutChildren() {
        immutable float barW = OCTAVE_BAR_WIDTH < bounds.w ? OCTAVE_BAR_WIDTH : bounds.w;
        immutable float barX = bounds.right() - barW;
        immutable float halfH = bounds.h * 0.5f;
        octaveUpBtn.arrange(RectF(barX, bounds.y, barW, halfH));
        octaveDownBtn.arrange(RectF(barX, bounds.y + halfH, barW, bounds.h - halfH));
    }

    override bool isAnimating() {
        ulong[2] m;
        currentMask(m);
        if (ctx_.telemetry.engine.playing && ctx_.selectedModule() != 0) {
            return true;
        }
        return m != lastDrawnMask_ || pressedMidi_ != lastDrawnPressed_;
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        update();
        ulong[2] mask;
        currentMask(mask);
        lastDrawnMask_ = mask;
        lastDrawnPressed_ = pressedMidi_;

        r.fillRect(bounds, theme.panelSunken);
        immutable RectF bed = keyBedRect();
        if (bed.isEmpty()) {
            return;
        }
        immutable int startMidi = startMidiForOctave(baseOctave());
        immutable float ww = whiteKeyWidthForHeight(bed.h);
        immutable float fsize = ww >= 34.0f ? theme.fontSizeBody : theme.fontSizeSmall;
        immutable float lh = r.lineHeight(FontId.ui, fsize);
        immutable float lowTop = bed.y + bed.h * BLACK_KEY_HEIGHT_RATIO;
        immutable float labelY = lowTop + (bed.bottom() - lowTop - lh) * 0.5f;

        r.pushClip(bed);
        foreach (m; startMidi .. 128) {
            immutable ubyte um = cast(ubyte) m;
            if (isBlackKey(um)) {
                continue;
            }
            immutable RectF kr = keyRect(um);
            if (kr.isEmpty()) {
                break;
            }
            immutable bool hi = isMaskBitSet(mask, um);
            r.fillRect(kr, hi ? theme.accent : theme.pianoWhiteKey);
            r.strokeRoundedRect(kr, 0.0f, hi ? 2.0f : 1.0f, theme.pianoKeyBorder);
            if (um % 12 == 0) {
                immutable int octNum = m / 12 - 1;
                char[4] buf;
                const(char)[] octTxt = formatOctave(buf[], octNum);
                immutable float tw = r.measureText(octTxt, FontId.ui, fsize);
                r.drawText(Point2F(kr.x + (kr.w - tw) * 0.5f, labelY), octTxt, FontId.ui, fsize,
                    hi ? theme.accentText : theme.pianoKeyText);
            }
        }
        foreach (m; startMidi .. 128) {
            immutable ubyte um = cast(ubyte) m;
            if (!isBlackKey(um)) {
                continue;
            }
            immutable RectF kr = keyRect(um);
            if (kr.isEmpty()) {
                continue;
            }
            immutable bool hi = isMaskBitSet(mask, um);
            r.fillRect(kr, hi ? theme.accent : theme.pianoBlackKey);
            r.strokeRoundedRect(kr, 0.0f, hi ? 2.0f : 1.0f, theme.pianoKeyBorder);
        }
        r.popClip();

        r.fillRect(RectF(bed.right() - 1.0f, bed.y, 1.0f, bed.h), theme.pianoKeyBorder);
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        immutable int m = hitTestKey(e.pos);
        if (m < 0) {
            return false;
        }
        pressKey(cast(ubyte) m);
        return true;
    }

    override bool onMouseMove(const ref MouseEvent e) {
        if (pressedMidi_ < 0) {
            return false;
        }
        immutable int m = hitTestKey(e.pos);
        if (m != pressedMidi_) {
            if (m < 0) {
                releaseHeld();
            } else {
                pressKey(cast(ubyte) m);
            }
        }
        return true;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        if (pressedMidi_ < 0) {
            return false;
        }
        releaseHeld();
        return true;
    }

    override void onCaptureLost() {
        releaseHeld();
    }

    private void pressKey(ubyte midi) {
        if (pressedMidi_ == cast(int) midi && pressedMod_ == ctx_.selectedModule()) {
            return;
        }
        releaseHeld();
        pressedMidi_ = cast(int) midi;
        pressedMod_ = ctx_.selectedModule();
        if (pressedMod_ != 0) {
            ctx_.session.triggerLiveNote(ModuleId(pressedMod_), Engine.PIANO_KEY_TAG_BASE | cast(uint) midi,
                cast(float) midi, DEFAULT_VELOCITY);
        }
        if (ctx_.recording) {
            ctx_.injectMidiNote(MidiNoteEvent(0, midi, RECORD_VELOCITY, ctx_.telemetry.engine.currentLine));
        }
        invalidate();
    }

    private void shiftOctave(int delta) {
        releaseHeld();
        ctx_.setEditOctave(baseOctave() + delta);
        ctx_.setStatus("Octave " ~ to!string(ctx_.editOctave));
        invalidate();
    }

    private void currentMask(out ulong[2] mask) const {
        ctx_.activeNoteMask(mask);
        if (pressedMidi_ >= 0 && pressedMidi_ < 128) {
            immutable uint idx = cast(uint) pressedMidi_;
            mask[idx >> 6] |= (1uL << (idx & 63));
        }
    }

    private static bool isMaskBitSet(const ref ulong[2] mask, ubyte midi) @safe nothrow pure @nogc {
        return midi < 128 && ((mask[midi >> 6] & (1uL << (midi & 63))) != 0);
    }

    private static const(char)[] formatOctave(char[] buf, int oct) @safe nothrow pure @nogc {
        size_t n = 0;
        if (oct < 0) {
            buf[n++] = '-';
            buf[n++] = cast(char)('0' + (-oct));
        } else {
            buf[n++] = cast(char)('0' + oct);
        }
        return buf[0 .. n];
    }
}
