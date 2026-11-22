/**
 * File:         source/gui/views/scope_view.d
 * Module:       gui.views.scope_view
 * Phase:        Phase 8.1 — Live Oscilloscope & FFT Spectrum Analyzer
 *
 * Purpose:
 *   Renders the master bus or the selected module as a triggered stereo oscilloscope (L/R overlaid, rising
 *   zero-crossing trigger), a log-frequency FFT spectrum (20 Hz .. Nyquist, -90..0 dBFS grid, attack/release
 *   smoothing and decaying peak hold) or a goniometer (mid/side vectorscope). A mode button and a source dropdown
 *   ("Master" / "Selected module") sit in a header strip; choosing the selected module requests a scope tap.
 *   Phase 8.5 (Accessible Appearance): traces use the scopeTraceL/R tokens; the right channel (and spectrum
 *   peak hold) is dashed and an L/R legend is drawn, so channels are not distinguished by color alone.
 *
 * Real-Time & Safety Contract:
 *   UI thread only; zero locking against the RT thread. Samples come from StudioContext.scopes (ScopeHistory,
 *   filled by StudioContext.tick() from the Engine scope ring). Point/column buffers are reused across frames;
 *   ScopeHistory.snapshot()/spectrum() allocate their result arrays per call (toolkit gap noted in the report).
 *
 * Dependencies:
 *   Internal: gui.{renderer,theme,widgets}, gui.views.studio_context
 *   External: core.time (MonoTime), std.math (floor, log10, pow, SQRT1_2)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum ScopeMode : oscilloscope, spectrum, goniometer
 *   - class ScopeView : Widget : this(StudioContext), mode(), setMode(), cycleMode(), sourceId(), selectSource(),
 *     controlRect(id), plotRect(), triggerOffset(), drawnPointCount(), spectrumLevels(), spectrumPeaks(),
 *     columnFrequency(), isAnimating()
 *   - Widget ids: scope.mode (mode button), scope.source (source dropdown)
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.1)
 */
module gui.views.scope_view;

import core.time : MonoTime;
import std.math : floor, log10, pow, SQRT1_2;

import gui.renderer : ColorRGBA, drawDashedPolyline, FontId, IRenderer2D, ITextMeasurer, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.widgets : Button, Dropdown, Widget;
import gui.views.studio_context : StudioContext;

/**
 * Scope display modes.
 */
enum ScopeMode : ubyte {
    oscilloscope = 0,
    spectrum = 1,
    goniometer = 2
}

/**
 * Live oscilloscope / spectrum / goniometer view.
 */
final class ScopeView : Widget {
    enum float HEADER_HEIGHT = 26.0f;
    enum size_t FFT_SIZE = 2048;
    enum float MIN_DB = -90.0f;
    enum float MAX_DB = 0.0f;
    enum float MIN_FREQ = 20.0f;
    enum float PEAK_DECAY_DB_PER_SEC = 18.0f;
    enum float RELEASE_COEFF = 0.35f;

    size_t displayFrames = 1024;
    size_t triggerSearchFrames = 1024;
    double delegate() clock;

    private StudioContext ctx_;
    private Button modeButton_;
    private Dropdown sourceBox_;
    private ScopeMode mode_ = ScopeMode.oscilloscope;
    private bool useSelected_ = false;
    private ulong tappedSelectionRevision_ = 0;
    private RectF plot_;
    private float[] left_;
    private float[] right_;
    private float[] db_;
    private Point2F[] ptsL_;
    private Point2F[] ptsR_;
    private float[] smooth_;
    private float[] peak_;
    private uint smoothSource_ = uint.max;
    private double lastSpectrumTime_ = -1.0;
    private ptrdiff_t trigger_ = -1;
    private size_t drawnPoints_ = 0;
    private MonoTime start_;

    /**
     * Builds the view and enables the master scope tap.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        ctx_ = ctx;
        start_ = MonoTime.currTime;
        modeButton_ = add(new Button(modeLabel(mode_), &cycleMode));
        modeButton_.id = "scope.mode";
        sourceBox_ = add(new Dropdown(["Master", "Selected module"], 0, &selectSource));
        sourceBox_.id = "scope.source";
        ensureTaps();
    }

    /**
     * Returns the display mode.
     *
     * Returns:
     *   Mode.
     */
    ScopeMode mode() const {
        return mode_;
    }

    /**
     * Sets the display mode (resets spectrum smoothing).
     *
     * Params:
     *   m = Mode.
     */
    void setMode(ScopeMode m) {
        if (m == mode_) {
            return;
        }
        mode_ = m;
        modeButton_.text = modeLabel(m);
        resetSpectrum();
        invalidate();
    }

    /**
     * Advances to the next mode (oscilloscope -> spectrum -> goniometer -> oscilloscope).
     */
    void cycleMode() {
        setMode(cast(ScopeMode)((mode_ + 1) % 3));
    }

    /**
     * Returns the source being displayed: 0 for master, or the selected module id in "Selected module" mode (master
     * when nothing is selected).
     *
     * Returns:
     *   Scope source id.
     */
    uint sourceId() const {
        return useSelected_ ? ctx_.selectedModule() : 0;
    }

    /**
     * Chooses the source (0 = Master, 1 = Selected module) and requests the matching scope taps.
     *
     * Params:
     *   index = Source dropdown index.
     */
    void selectSource(size_t index) {
        useSelected_ = index == 1;
        if (sourceBox_.selectedIndex != index) {
            sourceBox_.select(index, false);
        }
        ensureTaps();
        resetSpectrum();
        invalidate();
    }

    /**
     * Returns bounds of the header controls or the plot area.
     *
     * Params:
     *   controlId = "scope.mode", "scope.source" or "scope.plot".
     *
     * Returns:
     *   Bounds, or RectF.init.
     */
    RectF controlRect(string controlId) {
        switch (controlId) {
        case "scope.mode":
            return modeButton_.bounds;
        case "scope.source":
            return sourceBox_.bounds;
        case "scope.plot":
            return plot_;
        default:
            return RectF.init;
        }
    }

    /**
     * Returns the plot area.
     *
     * Returns:
     *   Plot rectangle.
     */
    RectF plotRect() const {
        return plot_;
    }

    /**
     * Returns the trigger position (index into the last snapshot) used by the last oscilloscope frame.
     *
     * Returns:
     *   Index, or -1 if no rising zero crossing was found.
     */
    ptrdiff_t triggerOffset() const {
        return trigger_;
    }

    /**
     * Returns the number of plot points emitted by the last frame (0 when nothing was drawn).
     *
     * Returns:
     *   Point count.
     */
    size_t drawnPointCount() const {
        return drawnPoints_;
    }

    /**
     * Returns the samples of the last oscilloscope/goniometer snapshot (left channel).
     *
     * Returns:
     *   Samples.
     */
    const(float)[] lastSnapshotLeft() const {
        return left_;
    }

    /**
     * Returns the smoothed spectrum level per plot column in dBFS.
     *
     * Returns:
     *   Levels.
     */
    const(float)[] spectrumLevels() const {
        return smooth_;
    }

    /**
     * Returns the peak-hold level per plot column in dBFS.
     *
     * Returns:
     *   Peaks.
     */
    const(float)[] spectrumPeaks() const {
        return peak_;
    }

    /**
     * Returns the lower edge frequency of a plot column on the log axis.
     *
     * Params:
     *   column = Column index.
     *   columns = Column count.
     *
     * Returns:
     *   Frequency in Hz.
     */
    float columnFrequency(size_t column, size_t columns) const {
        return freqAt(columns == 0 ? 0.0f : cast(float) column / cast(float) columns);
    }

    /**
     * Reports whether the scope needs continuous redraws (transport playing or audio running).
     *
     * Returns:
     *   True while animating.
     */
    override bool isAnimating() {
        return ctx_.telemetry.engine.playing || ctx_.telemetry.audioRunning;
    }

    /**
     * Returns the preferred size.
     *
     * Params:
     *   m = Text measurer.
     *   theme = Theme.
     *
     * Returns:
     *   Preferred size (at least 240 x 140).
     */
    override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        return Point2F(preferredSize.x > 0.0f ? preferredSize.x : 240.0f, preferredSize.y > 0.0f ? preferredSize.y : 140.0f);
    }

    /**
     * Places the header controls and the plot area.
     */
    override void layoutChildren() {
        immutable float pad = 4.0f;
        immutable float ch = 20.0f;
        immutable float cy = bounds.y + (HEADER_HEIGHT - ch) * 0.5f;
        modeButton_.arrange(RectF(bounds.x + pad, cy, 78.0f, ch));
        sourceBox_.arrange(RectF(bounds.x + pad + 82.0f, cy, 130.0f, ch));
        immutable float ph = bounds.h - HEADER_HEIGHT - pad;
        plot_ = RectF(bounds.x + pad, bounds.y + HEADER_HEIGHT, bounds.w - 2.0f * pad > 0.0f ? bounds.w - 2.0f * pad : 0.0f,
            ph > 0.0f ? ph : 0.0f);
    }

    /**
     * Draws the background, grid and current mode plot (clipped to the plot area).
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        if (useSelected_ && ctx_.selectionRevision() != tappedSelectionRevision_) {
            ensureTaps();
            resetSpectrum();
        }
        r.fillRect(bounds, theme.panel);
        r.fillRect(RectF(bounds.x, bounds.y + HEADER_HEIGHT - 1.0f, bounds.w, 1.0f), theme.border);
        drawnPoints_ = 0;
        trigger_ = -1;
        if (plot_.isEmpty()) {
            return;
        }
        r.fillRect(plot_, theme.trackerBackground);
        r.pushClip(plot_);
        final switch (mode_) {
        case ScopeMode.oscilloscope:
            drawOscilloscope(r, theme);
            break;
        case ScopeMode.spectrum:
            drawSpectrum(r, theme);
            break;
        case ScopeMode.goniometer:
            drawGoniometer(r, theme);
            break;
        }
        r.popClip();
        r.strokeRoundedRect(plot_, 0.0f, theme.borderWidth, theme.border);
    }

    private static string modeLabel(ScopeMode m) {
        final switch (m) {
        case ScopeMode.oscilloscope:
            return "Scope";
        case ScopeMode.spectrum:
            return "Spectrum";
        case ScopeMode.goniometer:
            return "Vector";
        }
    }

    private void ensureTaps() {
        uint[4] next;
        size_t k = 0;
        immutable uint sel = ctx_.selectedModule();
        if (useSelected_ && sel != 0) {
            next[k++] = sel;
        }
        foreach (t; ctx_.scopeTaps()) {
            if (t != 0 && t != sel && k < next.length) {
                next[k++] = t;
            }
        }
        ctx_.requestScopeTaps(next[0 .. k]);
        tappedSelectionRevision_ = ctx_.selectionRevision();
    }

    private void resetSpectrum() {
        smoothSource_ = uint.max;
        lastSpectrumTime_ = -1.0;
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

    private void drawNoSignal(IRenderer2D r, const ref StudioTheme theme) {
        immutable string msg = "No signal";
        immutable float size = theme.fontSizeSmall;
        immutable float tw = r.measureText(msg, FontId.ui, size);
        immutable float lh = r.lineHeight(FontId.ui, size);
        r.drawText(Point2F(plot_.x + (plot_.w - tw) * 0.5f, plot_.y + (plot_.h - lh) * 0.5f), msg, FontId.ui, size,
            theme.textDim);
    }

    private void drawOscilloscope(IRenderer2D r, const ref StudioTheme theme) {
        immutable float midY = plot_.y + plot_.h * 0.5f;
        foreach (q; 1 .. 4) {
            immutable float gy = plot_.y + plot_.h * 0.25f * q;
            r.fillRect(RectF(plot_.x, gy, plot_.w, 1.0f), q == 2 ? theme.borderStrong : theme.gridLine);
        }
        foreach (q; 1 .. 8) {
            r.fillRect(RectF(plot_.x + plot_.w * 0.125f * q, plot_.y, 1.0f, plot_.h), theme.gridLine);
        }
        immutable size_t window = displayFrames < 16 ? 16 : displayFrames;
        immutable size_t n = ctx_.scopes.snapshot(sourceId(), window + triggerSearchFrames, left_, right_);
        if (n < 2) {
            drawNoSignal(r, theme);
            return;
        }
        size_t startIdx = 0;
        size_t count = n;
        if (n > window) {
            count = window;
            startIdx = n - window;
            foreach_reverse (t; 1 .. n - window + 1) {
                immutable float a = left_[t - 1] + right_[t - 1];
                immutable float b = left_[t] + right_[t];
                if (a <= 0.0f && b > 0.0f) {
                    startIdx = t;
                    trigger_ = cast(ptrdiff_t) t;
                    break;
                }
            }
        }
        immutable float halfH = plot_.h * 0.5f - 1.0f;
        drawnPoints_ = traceChannel(r, left_[startIdx .. startIdx + count], ptsL_, midY, halfH, theme.scopeTraceL,
            false);
        drawnPoints_ += traceChannel(r, right_[startIdx .. startIdx + count], ptsR_, midY, halfH, theme.scopeTraceR,
            true);
        drawTraceLegend(r, theme);
    }

    private size_t traceChannel(IRenderer2D r, const(float)[] samples, ref Point2F[] pts, float midY, float halfH,
            ColorRGBA color, bool dashed) {
        immutable size_t cols = plot_.w >= 2.0f ? cast(size_t) plot_.w : 2;
        immutable size_t count = samples.length;
        size_t k = 0;
        if (count <= cols) {
            if (pts.length < count) {
                pts.length = count;
            }
            foreach (i; 0 .. count) {
                immutable float x = plot_.x + plot_.w * cast(float) i / cast(float)(count - 1);
                pts[k++] = Point2F(x, midY - samples[i] * halfH);
            }
        } else {
            if (pts.length < 2 * cols) {
                pts.length = 2 * cols;
            }
            foreach (c; 0 .. cols) {
                immutable size_t i0 = c * count / cols;
                size_t i1 = (c + 1) * count / cols;
                i1 = i1 > i0 ? i1 : i0 + 1;
                float mn = samples[i0];
                float mx = samples[i0];
                foreach (i; i0 + 1 .. i1) {
                    mn = samples[i] < mn ? samples[i] : mn;
                    mx = samples[i] > mx ? samples[i] : mx;
                }
                immutable float x = plot_.x + plot_.w * cast(float) c / cast(float)(cols - 1);
                immutable bool rising = c == 0 || samples[i0] >= samples[i0 > 0 ? i0 - 1 : 0];
                pts[k++] = Point2F(x, midY - (rising ? mn : mx) * halfH);
                pts[k++] = Point2F(x, midY - (rising ? mx : mn) * halfH);
            }
        }
        if (k >= 2) {
            if (dashed) {
                drawDashedPolyline(r, pts[0 .. k], 1.25f, color, 4.0f, 2.0f);
            } else {
                r.drawPolyline(pts[0 .. k], 1.25f, color);
            }
        }
        return k;
    }

    private void drawTraceLegend(IRenderer2D r, const ref StudioTheme theme) {
        immutable float size = theme.fontSizeSmall;
        immutable float lh = r.lineHeight(FontId.ui, size);
        immutable float x = plot_.right() - 46.0f;
        immutable float y = plot_.y + 4.0f;
        r.drawText(Point2F(x, y), "L", FontId.ui, size, theme.textDim);
        r.drawLine(Point2F(x + 10.0f, y + lh * 0.5f), Point2F(x + 20.0f, y + lh * 0.5f), 1.5f, theme.scopeTraceL);
        r.drawText(Point2F(x + 24.0f, y), "R", FontId.ui, size, theme.textDim);
        immutable Point2F[2] seg = [Point2F(x + 34.0f, y + lh * 0.5f), Point2F(x + 44.0f, y + lh * 0.5f)];
        drawDashedPolyline(r, seg[], 1.5f, theme.scopeTraceR, 4.0f, 2.0f);
    }

    private float nyquist() const {
        immutable float sr = ctx_.session.sampleRate();
        return sr > 0.0f ? sr * 0.5f : 22_050.0f;
    }

    private float freqAt(float t) const {
        immutable float hi = nyquist() > MIN_FREQ * 2.0f ? nyquist() : MIN_FREQ * 2.0f;
        return MIN_FREQ * cast(float) pow(hi / MIN_FREQ, t);
    }

    private float xOfFreq(float f) const {
        immutable float hi = nyquist() > MIN_FREQ * 2.0f ? nyquist() : MIN_FREQ * 2.0f;
        return plot_.x + plot_.w * cast(float)(log10(f / MIN_FREQ) / log10(hi / MIN_FREQ));
    }

    private float yOfDb(float db) const {
        immutable float c = db < MIN_DB ? MIN_DB : (db > MAX_DB ? MAX_DB : db);
        return plot_.y + plot_.h * (MAX_DB - c) / (MAX_DB - MIN_DB);
    }

    private void drawSpectrumGrid(IRenderer2D r, const ref StudioTheme theme) {
        immutable float size = theme.fontSizeSmall * 0.85f;
        for (float db = MAX_DB; db >= MIN_DB; db -= 10.0f) {
            immutable float y = yOfDb(db);
            r.fillRect(RectF(plot_.x, y, plot_.w, 1.0f), db == MAX_DB ? theme.borderStrong : theme.gridLine);
        }
        static immutable float[9] freqs = [50.0f, 100.0f, 200.0f, 500.0f, 1000.0f, 2000.0f, 5000.0f, 10_000.0f, 20_000.0f];
        static immutable string[9] labels = ["50", "100", "200", "500", "1k", "2k", "5k", "10k", "20k"];
        immutable float lh = r.lineHeight(FontId.ui, size);
        foreach (i, f; freqs) {
            if (f >= nyquist()) {
                break;
            }
            immutable float x = xOfFreq(f);
            r.fillRect(RectF(x, plot_.y, 1.0f, plot_.h), theme.gridLine);
            r.drawText(Point2F(x + 2.0f, plot_.bottom() - lh - 1.0f), labels[i], FontId.ui, size, theme.textDim);
        }
        static immutable string[3] dbLabels = ["-30", "-60", "-90"];
        foreach (i, lbl; dbLabels) {
            r.drawText(Point2F(plot_.x + 2.0f, yOfDb(-30.0f * (i + 1)) - lh), lbl, FontId.ui, size, theme.textDim);
        }
    }

    private void drawSpectrum(IRenderer2D r, const ref StudioTheme theme) {
        drawSpectrumGrid(r, theme);
        immutable uint src = sourceId();
        if (!ctx_.scopes.spectrum(src, FFT_SIZE, db_) || db_.length < 2) {
            drawNoSignal(r, theme);
            return;
        }
        immutable size_t cols = plot_.w >= 2.0f ? cast(size_t) plot_.w : 2;
        immutable double t = now();
        if (smooth_.length != cols || smoothSource_ != src) {
            smooth_.length = cols;
            peak_.length = cols;
            smooth_[] = MIN_DB - 30.0f;
            peak_[] = MIN_DB - 30.0f;
            smoothSource_ = src;
            lastSpectrumTime_ = t;
        }
        immutable double dt = lastSpectrumTime_ < 0.0 || t < lastSpectrumTime_ ? 0.0 : t - lastSpectrumTime_;
        lastSpectrumTime_ = t;
        immutable float binHz = (2.0f * nyquist()) / cast(float) FFT_SIZE;
        immutable size_t bins = db_.length;
        foreach (c; 0 .. cols) {
            immutable float f0 = columnFrequency(c, cols);
            immutable float f1 = columnFrequency(c + 1, cols);
            immutable float k0f = f0 / binHz;
            immutable float k1f = f1 / binHz;
            float level;
            size_t k0 = cast(size_t) floor(k0f);
            size_t k1 = cast(size_t) floor(k1f);
            if (k0 >= bins - 1) {
                k0 = bins - 2;
            }
            if (k1 >= bins) {
                k1 = bins - 1;
            }
            if (k1 <= k0) {
                immutable float frac = k0f - cast(float) k0;
                immutable float a = db_[k0];
                immutable float b = db_[k0 + 1];
                level = a + (b - a) * (frac < 0.0f ? 0.0f : (frac > 1.0f ? 1.0f : frac));
            } else {
                level = db_[k0 + 1];
                foreach (k; k0 + 1 .. k1 + 1) {
                    level = db_[k] > level ? db_[k] : level;
                }
            }
            immutable float s = level > smooth_[c] ? level : smooth_[c] + (level - smooth_[c]) * RELEASE_COEFF;
            smooth_[c] = s;
            immutable float decayed = peak_[c] - cast(float)(PEAK_DECAY_DB_PER_SEC * dt);
            peak_[c] = s > decayed ? s : decayed;
        }
        if (ptsL_.length < cols) {
            ptsL_.length = cols;
        }
        if (ptsR_.length < cols) {
            ptsR_.length = cols;
        }
        immutable float colW = plot_.w / cast(float) cols;
        foreach (c; 0 .. cols) {
            immutable float x = plot_.x + (cast(float) c + 0.5f) * colW;
            ptsL_[c] = Point2F(x, yOfDb(smooth_[c]));
            ptsR_[c] = Point2F(x, yOfDb(peak_[c]));
        }
        drawDashedPolyline(r, ptsR_[0 .. cols], 1.0f, theme.textDim, 3.0f, 2.0f);
        r.drawPolyline(ptsL_[0 .. cols], 1.5f, theme.scopeTraceL);
        drawnPoints_ = 2 * cols;
    }

    private void drawGoniometer(IRenderer2D r, const ref StudioTheme theme) {
        immutable Point2F c = plot_.center();
        immutable float rad = (plot_.w < plot_.h ? plot_.w : plot_.h) * 0.5f - 2.0f;
        r.fillRect(RectF(c.x, plot_.y, 1.0f, plot_.h), theme.borderStrong);
        r.fillRect(RectF(plot_.x, c.y, plot_.w, 1.0f), theme.gridLine);
        r.drawLine(Point2F(c.x - rad, c.y - rad), Point2F(c.x + rad, c.y + rad), 1.0f, theme.gridLine);
        r.drawLine(Point2F(c.x - rad, c.y + rad), Point2F(c.x + rad, c.y - rad), 1.0f, theme.gridLine);
        immutable size_t n = ctx_.scopes.snapshot(sourceId(), displayFrames, left_, right_);
        if (n < 2) {
            drawNoSignal(r, theme);
            return;
        }
        if (ptsL_.length < n) {
            ptsL_.length = n;
        }
        immutable float k = cast(float) SQRT1_2 * rad;
        foreach (i; 0 .. n) {
            immutable float side = left_[i] - right_[i];
            immutable float mid = left_[i] + right_[i];
            ptsL_[i] = Point2F(c.x + side * k, c.y - mid * k);
        }
        r.drawPolyline(ptsL_[0 .. n], 1.0f, theme.scopeTraceL);
        drawnPoints_ = n;
    }
}
