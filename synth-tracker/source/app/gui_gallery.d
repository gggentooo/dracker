/**
 * File:         source/app/gui_gallery.d
 * Module:       app.gui_gallery
 * Phase:        Phase 7 — Toolkit & Renderer Gallery Scene
 *
 * Purpose:
 *   Platform-independent IGuiScene used by the Phase 7 shell and self-test. A gui.widgets UiContext hosts a
 *   SplitView with a scrolling controls pane (toggle, log slider, knobs, numeric drag box, dropdown, context menu,
 *   curve and ADSR envelope editors) and a primitives canvas widget exercising every IRenderer2D feature
 *   (rounded/gradient/bordered panels, scissor clipping, UI and monospace text, anti-aliased Bezier patch cables,
 *   polyline oscilloscope, RGBA texture). An optional continuously animated mode drives display-paced rendering.
 *
 * Real-Time & Safety Contract:
 *   UI thread only.
 *
 * Dependencies:
 *   Internal: app.gui_shell (IGuiScene), gui.{layout,renderer,theme,widgets}, platform.interfaces
 *   External: std.math (sin, PI)
 *
 * Planned API (Types, Functions & Hooks):
 *   - class PrimitivesCanvas : Widget
 *   - class GalleryScene : IGuiScene (setAnimating(), isAnimating(), needsRedraw(), context(), statusText())
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 7)
 */
module app.gui_gallery;

version (StudioGUI):

import std.format : format;
import std.math : PI, sin;

import app.gui_shell : IGuiScene;
import gui.layout : Axis, Insets, SplitPaneNode;
import gui.renderer : ColorRGBA, FontId, IRenderer2D, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.widgets : Button, CurveEditor, Dropdown, EnvelopeEditor, Label, MenuItem, NumericDragBox, Panel, PanelLayout,
    RotaryKnob, ScrollView, Slider, SplitView, Toggle, UiContext, ValueRange, Widget;
import platform.interfaces : PlatformEvent;

private immutable string[3] NODE_TITLES = ["Analog Gen", "Echo", "Output"];
private immutable string[3] NODE_VALUES = ["C-4 7F 02", "fb 0.45", "vol 1.00"];

/**
 * Widget drawing the renderer primitives showcase (patch nodes, cables, scope, texture, Unicode text).
 */
final class PrimitivesCanvas : Widget {
    bool animating = false;
    double timeSeconds = 0.0;
    private uint gradientTexture_ = 0;
    private Point2F[] scopePoints_;

    /**
     * Creates the canvas and its demo RGBA texture.
     *
     * Params:
     *   renderer = Renderer used to allocate the texture.
     */
    this(IRenderer2D renderer) {
        enum uint TW = 64;
        enum uint TH = 64;
        ubyte[] px = new ubyte[TW * TH * 4];
        foreach (y; 0 .. TH) {
            foreach (x; 0 .. TW) {
                immutable size_t o = (y * TW + x) * 4;
                px[o] = cast(ubyte)(x * 4);
                px[o + 1] = cast(ubyte)(y * 4);
                px[o + 2] = cast(ubyte)(255 - x * 2);
                px[o + 3] = 255;
            }
        }
        gradientTexture_ = renderer.createTextureRGBA(TW, TH, px);
        scopePoints_ = new Point2F[256];
    }

    override bool isAnimating() {
        return animating;
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        immutable double t = animating ? timeSeconds : 0.0;
        immutable RectF canvas = bounds.inset(8);
        r.fillRoundedRect(canvas, 8, ColorRGBA.fromHex(0x1D2024FF));
        r.strokeRoundedRect(canvas, 8, 1, ColorRGBA.fromHex(0x3A3F46FF));
        r.pushClip(canvas.inset(1));

        RectF node(float x, float y) {
            return RectF(canvas.x + x, canvas.y + y, 150, 64);
        }
        immutable RectF a = node(30, 30);
        immutable RectF b = node(330, 120 + cast(float)(sin(t * 1.3) * 30.0));
        immutable RectF c = node(330, 10);
        immutable RectF[3] nodes = [a, b, c];
        foreach (i, n; nodes) {
            r.fillRoundedRectGradient(n, 7, ColorRGBA.fromHex(0x3B4350FF), ColorRGBA.fromHex(0x2C323BFF));
            r.strokeRoundedRect(n, 7, 1.5f, ColorRGBA.fromHex(0x5E9CFFFF).withAlpha(i == 0 ? 1.0f : 0.5f));
            r.drawText(Point2F(n.x + 10, n.y + 8), NODE_TITLES[i], FontId.ui, 13, ColorRGBA.fromHex(0xF2F3F5FF));
            r.drawText(Point2F(n.x + 10, n.y + 34), NODE_VALUES[i], FontId.mono, 12, ColorRGBA.fromHex(0x9AA4B2FF));
        }
        immutable Point2F outA = Point2F(a.right(), a.y + 32);
        immutable Point2F inB = Point2F(b.x, b.y + 32);
        immutable Point2F inC = Point2F(c.x, c.y + 32);
        r.drawBezier(outA, Point2F(outA.x + 90, outA.y), Point2F(inB.x - 90, inB.y), inB, 3.0f, theme.wireAudio);
        r.drawBezier(outA, Point2F(outA.x + 90, outA.y), Point2F(inC.x - 90, inC.y), inC, 2.0f, theme.wireCv);

        immutable RectF scopeRect = RectF(canvas.x + 30, canvas.y + 210, 450, 110);
        r.fillRoundedRect(scopeRect, 6, ColorRGBA.fromHex(0x101214FF));
        r.pushClip(scopeRect);
        foreach (i, ref p; scopePoints_) {
            immutable double ph = cast(double) i / (scopePoints_.length - 1);
            p = Point2F(scopeRect.x + cast(float)(ph * scopeRect.w),
                scopeRect.y + scopeRect.h * 0.5f - cast(float)(sin(ph * 6.0 * PI + t * 5.0) * 0.38 * scopeRect.h));
        }
        r.drawPolyline(scopePoints_, 1.6f, ColorRGBA.fromHex(0x5EE2FFFF));
        r.popClip();

        if (gradientTexture_ != 0) {
            r.drawImage(gradientTexture_, RectF(canvas.x + 520, canvas.y + 30, 96, 96), RectF(0, 0, 1, 1),
                ColorRGBA(1, 1, 1, 1));
        }
        r.drawText(Point2F(canvas.x + 520, canvas.y + 140), "\u3042 \u00E9 \u2669 \u2192 \u266F", FontId.ui, 18,
            theme.text);
        r.drawText(Point2F(canvas.x + 30, canvas.y + 340), "Right-click for a context menu \u2022 Cmd+Z/Cmd+S are routed via the menu bar",
            FontId.ui, 12, theme.textDim);
        r.popClip();
    }
}

/**
 * Renderer/toolkit showcase scene.
 */
final class GalleryScene : IGuiScene {
    private UiContext ui_;
    private PrimitivesCanvas canvas_;
    private Toggle animateToggle_;
    private Label status_;
    private float lastW_ = 0.0f;
    private float lastH_ = 0.0f;

    /**
     * Builds the widget tree.
     *
     * Params:
     *   renderer = Renderer used for texture allocation and text measurement.
     */
    this(IRenderer2D renderer) {
        canvas_ = new PrimitivesCanvas(renderer);
        canvas_.contextMenuProvider = (Point2F p) => [
            MenuItem("Add Module\u2026", () { setStatus("context: add module"); }),
            MenuItem("Toggle Animation", () { setAnimating(!canvas_.animating); }),
            MenuItem("", null, true, true),
            MenuItem("Disabled Item", null, false)
        ];

        Panel controls = new Panel(PanelLayout.column);
        controls.gap = 8;
        controls.padding = Insets.all(12);
        controls.add(new Label("Toolkit controls"));
        animateToggle_ = controls.add(new Toggle("Animate canvas", false, (bool on) { setAnimating(on); }));
        Slider cutoff = controls.add(new Slider(ValueRange(20.0f, 20_000.0f, 1000.0f, true), Axis.horizontal));
        cutoff.onChange = (float v) { setStatus(format("cutoff %.0f Hz", v)); };

        Panel knobs = controls.add(new Panel(PanelLayout.row));
        knobs.gap = 10;
        knobs.drawBackground = false;
        foreach (k; 0 .. 3) {
            RotaryKnob knob = knobs.add(new RotaryKnob(ValueRange(0.0f, 1.0f, 0.25f * (k + 1))));
            immutable int idx = k;
            knob.onChange = (float v) { setStatus(format("knob %s = %.3f", idx + 1, v)); };
        }

        NumericDragBox bpm = controls.add(new NumericDragBox(ValueRange(20.0f, 999.0f, 125.0f, false, 0.1f), 1));
        bpm.suffix = " BPM";
        bpm.onChange = (float v) { setStatus(format("tempo %.1f BPM", v)); };
        controls.add(new Dropdown(["Saw", "Square", "Sine", "Noise"], 0,
            (size_t i) { setStatus(format("waveform #%s", i)); }));
        Button menuButton;
        menuButton = controls.add(new Button("Open context menu", () {
            ui_.openContextMenu([
                MenuItem("Copy", () { setStatus("menu: copy"); }),
                MenuItem("Paste", () { setStatus("menu: paste"); })
            ], Point2F(menuButton.bounds.x, menuButton.bounds.bottom()));
        }));
        controls.add(new Label("Transfer curve"));
        CurveEditor curve = controls.add(new CurveEditor([Point2F(0, 0), Point2F(0.4f, 0.6f), Point2F(1, 1)]));
        curve.preferredSize = Point2F(240, 110);
        curve.onChange = () { setStatus(format("curve: %s points", curve.points.length)); };
        controls.add(new Label("ADSR envelope"));
        EnvelopeEditor env = controls.add(new EnvelopeEditor());
        env.setAdsr(0.1f, 0.2f, 0.6f, 0.3f);
        env.preferredSize = Point2F(240, 110);
        status_ = controls.add(new Label("ready"));

        ScrollView scroller = new ScrollView(controls);
        SplitView split = new SplitView(SplitPaneNode.split(Axis.horizontal, SplitPaneNode.leaf("controls"),
            SplitPaneNode.leaf("canvas"), 0.3f, 260.0f, 360.0f));
        split.setPane("controls", scroller);
        split.setPane("canvas", canvas_);
        ui_ = new UiContext(split);
        ui_.layout(RectF(0, 0, 800, 600), renderer);
    }

    /**
     * Enables or disables continuous canvas animation.
     *
     * Params:
     *   on = True to animate every display refresh.
     */
    void setAnimating(bool on) {
        canvas_.animating = on;
        if (animateToggle_ !is null && animateToggle_.checked != on) {
            animateToggle_.checked = on;
        }
        ui_.needsRedraw = true;
    }

    /**
     * Returns the hosted UI context.
     *
     * Returns:
     *   UiContext.
     */
    UiContext context() {
        return ui_;
    }

    /**
     * Returns the "Animate canvas" toggle bounds in logical window coordinates.
     *
     * Returns:
     *   Toggle bounds.
     */
    RectF animateToggleBounds() const {
        return animateToggle_.bounds;
    }

    /**
     * Returns the primitives canvas bounds in logical window coordinates.
     *
     * Returns:
     *   Canvas bounds.
     */
    RectF canvasBounds() const {
        return canvas_.bounds;
    }

    /**
     * Returns the status line text (last widget action).
     *
     * Returns:
     *   Status text.
     */
    string statusText() const {
        return status_.text;
    }

    override bool isAnimating() {
        return ui_.isAnimating();
    }

    override bool needsRedraw() {
        return ui_.needsRedraw;
    }

    override void handleEvent(const ref PlatformEvent ev) {
        ui_.handleEvent(ev);
    }

    override void draw(IRenderer2D r, float width, float height, double timeSeconds) {
        if (width != lastW_ || height != lastH_) {
            lastW_ = width;
            lastH_ = height;
            ui_.layout(RectF(0, 0, width, height), r);
        }
        canvas_.timeSeconds = timeSeconds;
        r.fillRect(RectF(0, 0, width, height), ui_.theme.background);
        ui_.draw(r);
    }

    private void setStatus(string s) {
        status_.text = s;
        ui_.needsRedraw = true;
    }
}
