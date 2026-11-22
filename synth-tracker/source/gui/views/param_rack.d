/**
 * File:         source/gui/views/param_rack.d
 * Module:       gui.views.param_rack
 * Phase:        Phase 8.3 — UDA Auto-Generated Parameter Rack & Custom Editors
 *
 * Purpose:
 *   Parameter rack for the selected module: a header (name, type, mute/bypass/solo quick toggles) and one row per
 *   @Param whose control is generated from the ParamDescriptor (linear -> Slider, logarithmic -> Slider with a
 *   logarithmic ValueRange, discrete span <= 1 -> Toggle, discrete span <= 16 -> Dropdown of integer values, larger
 *   discrete spans -> stepped Slider) with value text + unit. Drags form one undo step (beginEditGroup/endEditGroup
 *   + breakCoalesce on release), double-click (slider or row label) and the context menu reset to the default as
 *   one step. Right-click offers MIDI Learn (row shows "learning..." until the session disarms), Remove MIDI
 *   Mapping and Reset to Default; mapped rows show a "CC n" badge. Custom editors: WaveShaper 257-point transfer
 *   curve, MultiSynth velocity/pitch curves and MultiCtl map curve (smooth CurveEditor resampled into the module's
 *   extra blob and applied with doSetModuleExtra on edit end), and an EnvelopeEditor for modules exposing
 *   Attack/Decay/Sustain/Release params (written with doSetParam inside one edit group). MetaModules list their
 *   child graph; drilling into a child module shows its params with breadcrumbs and a Back button, and child edits
 *   rebuild the child project through setMetaModuleChildProject (not undoable; the UI says so).
 *   Phase 8.5 (Accessible Appearance): MIDI-learn rows and mapping badges use outlines instead of tints so text
 *   always sits on a contrast-checked surface.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. All document reads go through ctx.session.document() and are re-read on every sync; rows are
 *   rebuilt only when the selected module, its type, the drill-down target, or (for MetaModules) the document
 *   revision changes, and refreshed in place on other revision changes; nothing is rebuilt while a gesture is
 *   active. Every mutation goes through StudioSession.
 *
 * Dependencies:
 *   Internal: app.session, graph.{module_api,registry}, gui.{layout,renderer,theme,widgets},
 *             gui.views.studio_context, io.project_format, modules.control.{metamodule,multictl,multisynth},
 *             modules.effects.waveshaper
 *   External: core.stdc.string (memcpy), std.format (format), std.math (abs, round)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum ParamControlKind; ParamControlKind controlKindFor(ParamDescriptor); ValueRange valueRangeFor(ParamDescriptor);
 *     string formatParamValue(ParamDescriptor, float); Point2F[] curveTableToPoints(...); void resampleCurveToTable(...)
 *   - enum RackEditorKind; mixin template GestureHooks; final class RackCurveEditor / RackEnvelopeEditor / RackSlider / ParamRow
 *   - final class ParamRackView : Widget — this(StudioContext), sync(), shownModule(), inChildGraph(), drillInto(),
 *     drillBack(), paramRowRect(idx), paramControlRect(idx), paramControl(idx), controlKind(idx), paramValueText(idx),
 *     badgeText(idx), isLearning(idx), revealParam(idx), hasCurveEditor(), curveEditorRect(), curveEditor(),
 *     selectCurveTarget(), hasEnvelopeEditor(), envelopeEditorRect(), envelopeEditor(), childModuleIds(),
 *     childButtonRect(i), backButtonRect(), headerToggleRect(k), startMidiLearn(idx), removeMapping(idx),
 *     resetParam(idx), contextMenuFor(idx)
 *   - ids: "rack.param.<idx>" (row), "rack.param.<idx>.control", "rack.mute", "rack.bypass", "rack.solo",
 *     "rack.back", "rack.child.<i>", "rack.curve", "rack.curveTarget", "rack.envelope"
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.3)
 */
module gui.views.param_rack;

import core.stdc.string : memcpy;
import std.format : format;
import std.math : abs, round;

import graph.module_api : ParamDescriptor, ParamScale;
import graph.registry : ModuleRegistry;
import gui.layout : clampf;
import gui.renderer : ColorRGBA, FontId, IRenderer2D, ITextMeasurer, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.widgets : Button, ContextMenu, CurveEditor, CurveMode, Dropdown, EnvelopeEditor, Label, MenuItem,
    MouseButton, MouseEvent, KeyEvent, Panel, PanelLayout, ScrollView, Slider, Toggle, ValueRange, Widget;
import gui.views.studio_context : StudioContext;
import io.project_format : LoadedProject, loadProject;
import modules.control.metamodule : MetaMacroBinding, MetaModuleAsset;
import modules.control.multictl : MultiCtlMapAsset;
import modules.control.multisynth : MultiSynthCurveAsset;
import modules.effects.waveshaper : WaveShaperCurveAsset;

/**
 * Control generated for one parameter row.
 */
enum ParamControlKind : ubyte {
    slider = 0,
    logSlider = 1,
    toggle = 2,
    dropdown = 3,
    steppedSlider = 4
}

/**
 * Custom editor shown below the parameter rows.
 */
enum RackEditorKind : ubyte {
    none = 0,
    waveshaper = 1,
    multiSynth = 2,
    multiCtl = 3,
    adsr = 4
}

enum float MAX_DROPDOWN_SPAN = 16.0f;
enum size_t CURVE_EDITOR_POINTS = 17;

/**
 * Chooses the control for a parameter from its scale and range.
 *
 * Params:
 *   p = Parameter descriptor.
 *
 * Returns:
 *   Control kind.
 */
ParamControlKind controlKindFor(const ParamDescriptor p) @safe nothrow pure @nogc {
    final switch (p.scale) {
    case ParamScale.linear:
        return ParamControlKind.slider;
    case ParamScale.logarithmic:
        return ParamControlKind.logSlider;
    case ParamScale.discrete:
        immutable float span = p.maxVal - p.minVal;
        if (span <= 1.0f) {
            return ParamControlKind.toggle;
        }
        return span <= MAX_DROPDOWN_SPAN ? ParamControlKind.dropdown : ParamControlKind.steppedSlider;
    }
}

/**
 * Builds the ValueRange of a parameter control. Logarithmic params whose minimum is not positive use a floor of
 * max / 1000 so the exponential mapping stays defined; discrete params step by 1.
 *
 * Params:
 *   p = Parameter descriptor.
 *
 * Returns:
 *   Value range.
 */
ValueRange valueRangeFor(const ParamDescriptor p) @safe nothrow pure @nogc {
    ValueRange r = ValueRange(p.minVal, p.maxVal, p.defaultVal, false, 0.0f);
    if (p.scale == ParamScale.logarithmic) {
        r.logarithmic = true;
        if (!(r.min > 0.0f)) {
            r.min = p.maxVal > 0.0f ? p.maxVal * 1.0e-3f : 1.0e-3f;
        }
    } else if (p.scale == ParamScale.discrete) {
        r.step = 1.0f;
    }
    return r;
}

/**
 * Formats a parameter value with its unit.
 *
 * Params:
 *   p = Parameter descriptor.
 *   v = Value.
 *
 * Returns:
 *   Display text.
 */
string formatParamValue(const ParamDescriptor p, float v) {
    string num;
    if (p.scale == ParamScale.discrete) {
        num = format("%d", cast(int) round(v));
    } else if (abs(v) >= 1000.0f) {
        num = format("%.0f", v);
    } else if (abs(v) >= 100.0f) {
        num = format("%.1f", v);
    } else {
        num = format("%.3f", v);
    }
    return p.unit.length > 0 ? num ~ " " ~ p.unit : num;
}

/**
 * Samples a lookup table into evenly spaced normalized curve points.
 *
 * Params:
 *   table = Table values.
 *   lo = Value mapped to y = 0.
 *   hi = Value mapped to y = 1.
 *   count = Number of points (>= 2).
 *
 * Returns:
 *   Points sorted by x covering [0, 1].
 */
Point2F[] curveTableToPoints(const(float)[] table, float lo, float hi, size_t count = CURVE_EDITOR_POINTS) {
    if (table.length < 2 || count < 2) {
        return [Point2F(0.0f, 0.0f), Point2F(1.0f, 1.0f)];
    }
    Point2F[] pts = new Point2F[count];
    immutable size_t last = table.length - 1;
    foreach (k; 0 .. count) {
        immutable size_t idx = cast(size_t) round(cast(double) k * last / (count - 1));
        immutable float x = cast(float) idx / cast(float) last;
        immutable float y = hi != lo ? clampf((table[idx] - lo) / (hi - lo), 0.0f, 1.0f) : 0.0f;
        pts[k] = Point2F(x, y);
    }
    return pts;
}

/**
 * Resamples an editor curve into a lookup table (entry i sits at x = i / (length - 1)).
 *
 * Params:
 *   editor = Curve editor.
 *   table = Destination table (length >= 2).
 *   lo = Value at y = 0.
 *   hi = Value at y = 1.
 */
void resampleCurveToTable(const CurveEditor editor, float[] table, float lo, float hi) {
    if (table.length < 2) {
        return;
    }
    immutable float last = cast(float)(table.length - 1);
    foreach (i, ref t; table) {
        t = lo + editor.evaluate(cast(float) i / last) * (hi - lo);
    }
}

private T loadAssetOrDefault(T)(const(ubyte)[] blob) {
    T a;
    if (blob.length == T.sizeof) {
        memcpy(&a, blob.ptr, T.sizeof);
        return a;
    }
    T* d = T.createOffRT();
    if (d !is null) {
        memcpy(&a, d, T.sizeof);
        T.destroyErased(d);
    }
    return a;
}

private ubyte[] assetBytes(T)(const ref T a) {
    return (cast(const(ubyte)*)&a)[0 .. T.sizeof].dup;
}

/**
 * Mixin for CurveEditor subclasses: reports onGestureBegin on a handled press and onGestureEnd(changed) on release,
 * capture loss, or a keyboard edit, so edits can be committed as one undo step when the gesture ends.
 */
mixin template GestureHooks() {
    void delegate() onGestureBegin;
    void delegate(bool changed) onGestureEnd;
    private bool gestureActive_ = false;
    private bool gestureDirty_ = false;

    /**
     * Reports whether a pointer gesture is in progress.
     *
     * Returns:
     *   True between press and release.
     */
    bool gestureActive() const {
        return gestureActive_;
    }

    protected override void changed() {
        gestureDirty_ = true;
        super.changed();
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (!gestureActive_) {
            gestureDirty_ = false;
        }
        immutable bool h = super.onMouseDown(e);
        if (h && !gestureActive_) {
            gestureActive_ = true;
            if (onGestureBegin !is null) {
                onGestureBegin();
            }
        }
        return h;
    }

    override bool onMouseUp(const ref MouseEvent e) {
        immutable bool h = super.onMouseUp(e);
        finishGesture();
        return h;
    }

    override void onCaptureLost() {
        super.onCaptureLost();
        finishGesture();
    }

    override bool onKeyDown(const ref KeyEvent e) {
        if (gestureActive_) {
            return super.onKeyDown(e);
        }
        gestureDirty_ = false;
        immutable bool h = super.onKeyDown(e);
        if (gestureDirty_ && onGestureEnd !is null) {
            if (onGestureBegin !is null) {
                onGestureBegin();
            }
            onGestureEnd(true);
        }
        gestureDirty_ = false;
        return h;
    }

    private void finishGesture() {
        if (!gestureActive_) {
            return;
        }
        gestureActive_ = false;
        immutable bool dirty = gestureDirty_;
        gestureDirty_ = false;
        if (onGestureEnd !is null) {
            onGestureEnd(dirty);
        }
    }
}

/**
 * CurveEditor reporting gesture begin/end (edits are committed on release).
 */
final class RackCurveEditor : CurveEditor {
    mixin GestureHooks;

    /**
     * Creates the editor in smooth mode.
     */
    this() {
        super(null);
        mode = CurveMode.smooth;
    }
}

/**
 * EnvelopeEditor reporting gesture begin/end (edits are committed on release).
 */
final class RackEnvelopeEditor : EnvelopeEditor {
    mixin GestureHooks;

    /**
     * Creates the editor with a fixed four-point ADSR shape.
     */
    this() {
        super();
        minPoints = 4;
        maxPoints = 4;
    }
}

/**
 * Slider reporting press/release so the rack can wrap a drag in one undo group.
 */
final class RackSlider : Slider {
    void delegate() onGestureBegin;
    void delegate() onGestureEnd;
    private bool active_ = false;

    /**
     * Creates the slider.
     *
     * Params:
     *   r = Value range.
     */
    this(ValueRange r) {
        super(r);
    }

    /**
     * Reports whether a press/drag is active.
     *
     * Returns:
     *   True between press and release.
     */
    bool gestureActive() const {
        return active_;
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        if (!active_) {
            active_ = true;
            if (onGestureBegin !is null) {
                onGestureBegin();
            }
        }
        return super.onMouseDown(e);
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
 * One parameter row: name, generated control, value text, optional CC badge and MIDI-learn state.
 */
final class ParamRow : Widget {
    uint paramIdx;
    ParamDescriptor desc;
    ParamControlKind kind;
    Widget control;
    string valueText;
    string badgeText;
    bool learning = false;
    bool odd = false;
    private ParamRackView owner_;

    /**
     * Creates a row and its control.
     *
     * Params:
     *   owner = Owning rack.
     *   idx = Parameter index.
     *   d = Parameter descriptor.
     */
    this(ParamRackView owner, uint idx, ParamDescriptor d) {
        owner_ = owner;
        paramIdx = idx;
        desc = d;
        kind = controlKindFor(d);
        id = format("rack.param.%d", idx);
        control = makeControl();
        control.id = id ~ ".control";
        add(control);
    }

    /**
     * Shows a value on the control without notifying and updates the value text.
     *
     * Params:
     *   v = Parameter value.
     */
    void showValue(float v) {
        final switch (kind) {
        case ParamControlKind.slider:
        case ParamControlKind.logSlider:
        case ParamControlKind.steppedSlider:
            (cast(RackSlider) control).setValue(v, false);
            break;
        case ParamControlKind.toggle:
            (cast(Toggle) control).setChecked(v > (desc.minVal + desc.maxVal) * 0.5f, false);
            break;
        case ParamControlKind.dropdown:
            immutable long i = cast(long) round(v - desc.minVal);
            (cast(Dropdown) control).select(i < 0 ? 0 : cast(size_t) i, false);
            break;
        }
        valueText = formatParamValue(desc, v);
        invalidate();
    }

    /**
     * Reports whether the control is mid-gesture.
     *
     * Returns:
     *   True while a slider drag is active.
     */
    bool gestureActive() {
        auto s = cast(RackSlider) control;
        return s !is null && s.gestureActive();
    }

    override void layoutChildren() {
        immutable float nameW = bounds.w * 0.34f;
        immutable float valueW = 86.0f;
        immutable float badgeW = 46.0f;
        float cw = bounds.w - nameW - valueW - badgeW - 8.0f;
        cw = cw > 24.0f ? cw : 24.0f;
        if (kind == ParamControlKind.toggle) {
            cw = cw < 40.0f ? cw : 40.0f;
        }
        control.arrange(RectF(bounds.x + nameW, bounds.y + 2.0f, cw, bounds.h - 4.0f));
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button == MouseButton.left && e.clickCount >= 2 && !control.bounds.contains(e.pos)) {
            owner_.resetParam(paramIdx);
            return true;
        }
        return false;
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        if (learning) {
            r.fillRect(bounds, theme.hover);
            r.strokeRoundedRect(bounds.inset(1.0f), 0.0f, 2.0f, theme.warning);
        } else if (odd) {
            r.fillRect(bounds, theme.hover);
        }
        immutable float size = theme.fontSizeBody;
        immutable float lh = r.lineHeight(FontId.ui, size);
        immutable float ty = bounds.y + (bounds.h - lh) * 0.5f;
        r.pushClip(RectF(bounds.x, bounds.y, bounds.w * 0.34f - 2.0f, bounds.h));
        r.drawText(Point2F(bounds.x + 6.0f, ty), desc.name, FontId.ui, size, theme.text);
        r.popClip();
        immutable string vt = learning ? "learning..." : valueText;
        immutable float tw = r.measureText(vt, FontId.mono, theme.fontSizeMono);
        r.drawText(Point2F(bounds.right() - 6.0f - tw, bounds.y + (bounds.h - r.lineHeight(FontId.mono, theme.fontSizeMono)) * 0.5f),
            vt, FontId.mono, theme.fontSizeMono, learning ? theme.text : theme.textDim);
        if (badgeText.length > 0) {
            immutable float bs = theme.fontSizeSmall;
            immutable float bw = r.measureText(badgeText, FontId.ui, bs) + 8.0f;
            immutable RectF br = RectF(bounds.right() - 86.0f - 4.0f - bw, bounds.y + 5.0f, bw, bounds.h - 10.0f);
            r.fillRoundedRect(br, theme.radiusSm, theme.panelSunken);
            r.strokeRoundedRect(br, theme.radiusSm, theme.borderWidth, theme.accent);
            r.drawText(Point2F(br.x + 4.0f, br.y + (br.h - r.lineHeight(FontId.ui, bs)) * 0.5f), badgeText, FontId.ui, bs,
                theme.text);
        }
    }

    private Widget makeControl() {
        immutable uint idx = paramIdx;
        final switch (kind) {
        case ParamControlKind.slider:
        case ParamControlKind.logSlider:
        case ParamControlKind.steppedSlider:
            auto s = new RackSlider(valueRangeFor(desc));
            s.onChange = (float v) { owner_.controlChanged(idx, v); };
            s.onGestureBegin = () { owner_.beginGesture("Change Parameter"); };
            s.onGestureEnd = () { owner_.endGesture(); };
            return s;
        case ParamControlKind.toggle:
            return new Toggle("", false, (bool on) { owner_.controlChanged(idx, on ? desc.maxVal : desc.minVal); });
        case ParamControlKind.dropdown:
            string[] items;
            immutable int lo = cast(int) round(desc.minVal);
            immutable int hi = cast(int) round(desc.maxVal);
            foreach (v; lo .. hi + 1) {
                items ~= desc.unit.length > 0 ? format("%d %s", v, desc.unit) : format("%d", v);
            }
            return new Dropdown(items, 0, (size_t i) { owner_.controlChanged(idx, desc.minVal + cast(float) i); });
        }
    }
}

/**
 * Auto-generated parameter rack with MIDI learn, custom curve/envelope editors and MetaModule drill-down.
 */
final class ParamRackView : Widget {
    enum float HEADER_HEIGHT = 30.0f;
    enum float CRUMB_HEIGHT = 24.0f;
    enum float ROW_HEIGHT = 26.0f;
    enum float SECTION_HEIGHT = 22.0f;
    enum float EDITOR_HEIGHT = 150.0f;
    enum float ITEM_HEIGHT = 24.0f;

    private StudioContext ctx_;
    private ScrollView scroll_;
    private Panel content_;
    private Toggle muteToggle_;
    private Toggle bypassToggle_;
    private Toggle soloToggle_;
    private Button backButton_;
    private ParamRow[] rows_;
    private RackCurveEditor curve_;
    private Dropdown curveTarget_;
    private RackEnvelopeEditor env_;
    private Button[] childButtons_;
    private uint[] childIds_;
    private RackEditorKind editorKind_ = RackEditorKind.none;
    private uint[4] adsrIdx_;
    private uint curveTargetIndex_ = 0;
    private ubyte[] lastCommittedBlob_;
    private bool haveLastCommitted_ = false;

    private bool bound_ = false;
    private uint boundModule_ = 0;
    private string boundType_;
    private ulong boundRev_ = 0;
    private uint boundMeta_ = 0;
    private uint boundChild_ = 0;
    private uint drillMeta_ = 0;
    private uint drillChild_ = 0;
    private LoadedProject child_;
    private bool childValid_ = false;
    private bool childDirty_ = false;
    private int learningParam_ = -1;
    private int gestureDepth_ = 0;
    private float contentHeight_ = 0.0f;
    private string title_;
    private string typeText_;
    private string crumbText_;
    private string crumbLine_;

    /**
     * Creates the rack.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        ctx_ = ctx;
        id = "rack";
        muteToggle_ = add(new Toggle("M", false, (bool on) { toggleHeader(0, on); }));
        muteToggle_.id = "rack.mute";
        bypassToggle_ = add(new Toggle("B", false, (bool on) { toggleHeader(1, on); }));
        bypassToggle_.id = "rack.bypass";
        soloToggle_ = add(new Toggle("S", false, (bool on) { toggleHeader(2, on); }));
        soloToggle_.id = "rack.solo";
        backButton_ = add(new Button("Back", () { drillBack(); }));
        backButton_.id = "rack.back";
        backButton_.visible = false;
        content_ = new Panel(PanelLayout.column);
        content_.drawBackground = false;
        scroll_ = add(new ScrollView(content_));
        scroll_.scrollHorizontal = false;
        scroll_.id = "rack.scroll";
    }

    /**
     * Brings the rack in line with the selection and document (rebuilds or refreshes as needed).
     */
    void sync() {
        if (gestureDepth_ > 0 || anyGestureActive()) {
            return;
        }
        immutable uint sel = ctx_.selectedModule();
        if (drillMeta_ != 0 && drillMeta_ != sel) {
            drillMeta_ = 0;
            drillChild_ = 0;
        }
        const doc = ctx_.session.document();
        immutable ptrdiff_t mi = findModule(sel);
        immutable string type = mi >= 0 ? doc.modules[mi].typeId : null;
        immutable ulong rev = ctx_.documentRevision();
        if (learningParam_ >= 0 && !ctx_.session.midiLearnActive()) {
            learningParam_ = -1;
            foreach (row; rows_) {
                row.learning = false;
            }
            invalidate();
        }
        immutable bool structural = !bound_ || sel != boundModule_ || type != boundType_ || drillMeta_ != boundMeta_
            || drillChild_ != boundChild_;
        immutable bool metaLike = type == "ctl.metamodule" || inChildGraph();
        if (structural || (rev != boundRev_ && metaLike)) {
            rebuild(sel, type);
        } else if (rev != boundRev_) {
            refresh();
        }
        soloToggle_.setChecked(sel != 0 && ctx_.session.isModuleSoloed(sel), false);
    }

    /**
     * Returns the module whose parameters are shown (a child module id while drilled into a MetaModule).
     *
     * Returns:
     *   Module id, or 0 when nothing is shown.
     */
    uint shownModule() {
        sync();
        return currentModule();
    }

    /**
     * Reports whether the rack shows a MetaModule child module.
     *
     * Returns:
     *   True while drilled down.
     */
    bool inChildGraph() const {
        return drillMeta_ != 0 && drillChild_ != 0;
    }

    /**
     * Drills into a child module of the selected MetaModule.
     *
     * Params:
     *   childModuleId = Child module id inside the MetaModule's child project.
     *
     * Returns:
     *   True if the child exists.
     */
    bool drillInto(uint childModuleId) {
        sync();
        immutable uint sel = ctx_.selectedModule();
        if (!childValid_ || drillMeta_ != sel) {
            return false;
        }
        foreach (ref m; child_.modules) {
            if (m.id == childModuleId) {
                drillChild_ = childModuleId;
                sync();
                return true;
            }
        }
        return false;
    }

    /**
     * Returns from a child module to the MetaModule.
     */
    void drillBack() {
        drillChild_ = 0;
        invalidate();
    }

    /**
     * Returns the child module ids listed under "Child graph" (MetaModule only).
     *
     * Returns:
     *   Ids in document order.
     */
    const(uint)[] childModuleIds() {
        sync();
        return childIds_;
    }

    /**
     * Returns the absolute bounds of a child-graph list entry.
     *
     * Params:
     *   i = Entry index.
     *
     * Returns:
     *   Bounds, or an empty rect.
     */
    RectF childButtonRect(size_t i) {
        sync();
        return i < childButtons_.length ? childButtons_[i].bounds : RectF.init;
    }

    /**
     * Returns the Back button bounds (empty unless drilled down).
     *
     * Returns:
     *   Bounds.
     */
    RectF backButtonRect() {
        sync();
        return backButton_.visible ? backButton_.bounds : RectF.init;
    }

    /**
     * Returns the bounds of a header toggle.
     *
     * Params:
     *   k = 0 = mute, 1 = bypass, 2 = solo.
     *
     * Returns:
     *   Bounds.
     */
    RectF headerToggleRect(uint k) {
        sync();
        Toggle t = k == 0 ? muteToggle_ : (k == 1 ? bypassToggle_ : soloToggle_);
        return t.visible ? t.bounds : RectF.init;
    }

    /**
     * Returns the breadcrumb text ("Meta > Child") while drilled down.
     *
     * Returns:
     *   Breadcrumb text or empty.
     */
    string breadcrumb() {
        sync();
        return inChildGraph() ? crumbText_ : "";
    }

    /**
     * Returns the absolute bounds of a parameter row.
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   Bounds, or an empty rect when not shown.
     */
    RectF paramRowRect(uint paramIdx) {
        sync();
        auto row = rowFor(paramIdx);
        return row is null ? RectF.init : row.bounds;
    }

    /**
     * Returns the absolute bounds of a parameter's draggable control.
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   Bounds, or an empty rect when not shown.
     */
    RectF paramControlRect(uint paramIdx) {
        sync();
        auto row = rowFor(paramIdx);
        return row is null ? RectF.init : row.control.bounds;
    }

    /**
     * Returns the control widget of a parameter.
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   Control, or null.
     */
    Widget paramControl(uint paramIdx) {
        sync();
        auto row = rowFor(paramIdx);
        return row is null ? null : row.control;
    }

    /**
     * Returns the generated control kind of a parameter row.
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   Kind (slider when not shown).
     */
    ParamControlKind controlKind(uint paramIdx) {
        sync();
        auto row = rowFor(paramIdx);
        return row is null ? ParamControlKind.slider : row.kind;
    }

    /**
     * Returns the value text of a row.
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   Text.
     */
    string paramValueText(uint paramIdx) {
        sync();
        auto row = rowFor(paramIdx);
        return row is null ? "" : row.valueText;
    }

    /**
     * Returns the MIDI mapping badge text of a row ("CC n" or empty).
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   Badge text.
     */
    string badgeText(uint paramIdx) {
        sync();
        auto row = rowFor(paramIdx);
        return row is null ? "" : row.badgeText;
    }

    /**
     * Reports whether a row is waiting for a MIDI controller.
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   True while learning.
     */
    bool isLearning(uint paramIdx) {
        sync();
        auto row = rowFor(paramIdx);
        return row !is null && row.learning;
    }

    /**
     * Scrolls a row into view.
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   True if the scroll offset changed.
     */
    bool revealParam(uint paramIdx) {
        sync();
        auto row = rowFor(paramIdx);
        return row !is null && scroll_.ensureVisible(row.bounds);
    }

    /**
     * Reports whether a curve editor (WaveShaper / MultiSynth / MultiCtl) is shown.
     *
     * Returns:
     *   True if shown.
     */
    bool hasCurveEditor() {
        sync();
        return curve_ !is null;
    }

    /**
     * Returns the curve editor bounds.
     *
     * Returns:
     *   Bounds, or an empty rect.
     */
    RectF curveEditorRect() {
        sync();
        return curve_ is null ? RectF.init : curve_.bounds;
    }

    /**
     * Returns the curve editor.
     *
     * Returns:
     *   Editor, or null.
     */
    RackCurveEditor curveEditor() {
        sync();
        return curve_;
    }

    /**
     * Returns the custom editor kind.
     *
     * Returns:
     *   Kind.
     */
    RackEditorKind editorKind() {
        sync();
        return editorKind_;
    }

    /**
     * Selects which MultiSynth table the curve editor edits.
     *
     * Params:
     *   target = 0 = velocity curve, 1 = pitch offset.
     */
    void selectCurveTarget(uint target) {
        sync();
        curveTargetIndex_ = target > 1 ? 1 : target;
        if (curveTarget_ !is null) {
            curveTarget_.select(curveTargetIndex_, false);
        }
        haveLastCommitted_ = false;
        loadCurvePoints();
    }

    /**
     * Reports whether the ADSR envelope editor is shown.
     *
     * Returns:
     *   True if shown.
     */
    bool hasEnvelopeEditor() {
        sync();
        return env_ !is null;
    }

    /**
     * Returns the envelope editor bounds.
     *
     * Returns:
     *   Bounds, or an empty rect.
     */
    RectF envelopeEditorRect() {
        sync();
        return env_ is null ? RectF.init : env_.bounds;
    }

    /**
     * Returns the envelope editor.
     *
     * Returns:
     *   Editor, or null.
     */
    RackEnvelopeEditor envelopeEditor() {
        sync();
        return env_;
    }

    /**
     * Arms MIDI learn for a parameter of the shown (top-level) module.
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   True if armed.
     */
    bool startMidiLearn(uint paramIdx) {
        if (inChildGraph() || !ctx_.session.beginMidiLearn(currentModule(), paramIdx)) {
            return false;
        }
        learningParam_ = cast(int) paramIdx;
        foreach (row; rows_) {
            row.learning = row.paramIdx == paramIdx;
        }
        invalidate();
        return true;
    }

    /**
     * Removes the first MIDI mapping bound to a parameter of the shown module.
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   True if removed.
     */
    bool removeMapping(uint paramIdx) {
        immutable ptrdiff_t mapIdx = mappingIndexFor(paramIdx);
        return mapIdx >= 0 && ctx_.session.doRemoveMidiMapping(cast(size_t) mapIdx);
    }

    /**
     * Resets a parameter to its default as one undo step.
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   True if applied.
     */
    bool resetParam(uint paramIdx) {
        auto row = rowFor(paramIdx);
        if (row is null) {
            return false;
        }
        immutable float v = row.desc.defaultVal;
        row.showValue(v);
        if (inChildGraph()) {
            setChildParam(paramIdx, v);
            return commitChild();
        }
        ctx_.session.history().breakCoalesce();
        immutable bool ok = ctx_.session.doSetParam(currentModule(), paramIdx, v);
        ctx_.session.history().breakCoalesce();
        return ok;
    }

    /**
     * Builds the context menu of a parameter row.
     *
     * Params:
     *   paramIdx = Parameter index.
     *
     * Returns:
     *   Menu items.
     */
    MenuItem[] contextMenuFor(uint paramIdx) {
        MenuItem[] items;
        immutable bool child = inChildGraph();
        if (learningParam_ == cast(int) paramIdx) {
            items ~= MenuItem("Cancel MIDI Learn", () { ctx_.session.cancelMidiLearn(); });
        } else {
            items ~= MenuItem("MIDI Learn", () { startMidiLearn(paramIdx); }, !child);
        }
        if (!child && mappingIndexFor(paramIdx) >= 0) {
            items ~= MenuItem("Remove MIDI Mapping", () { removeMapping(paramIdx); });
        }
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem("Reset to Default", () { resetParam(paramIdx); });
        return items;
    }

    override Widget hitTest(Point2F p) {
        sync();
        return super.hitTest(p);
    }

    override bool isAnimating() {
        return learningParam_ >= 0;
    }

    override void layoutChildren() {
        immutable float tw = 44.0f;
        immutable float th = 20.0f;
        immutable float ty = bounds.y + (HEADER_HEIGHT - th) * 0.5f;
        soloToggle_.arrange(RectF(bounds.right() - 6.0f - tw, ty, tw, th));
        bypassToggle_.arrange(RectF(bounds.right() - 6.0f - 2.0f * tw, ty, tw, th));
        muteToggle_.arrange(RectF(bounds.right() - 6.0f - 3.0f * tw, ty, tw, th));
        float y = bounds.y + HEADER_HEIGHT;
        backButton_.visible = inChildGraph();
        if (backButton_.visible) {
            backButton_.arrange(RectF(bounds.x + 4.0f, y + 2.0f, 56.0f, CRUMB_HEIGHT - 4.0f));
            y += CRUMB_HEIGHT;
        }
        scroll_.contentSize = Point2F(0.0f, contentHeight_);
        immutable float h = bounds.bottom() - y;
        scroll_.arrange(RectF(bounds.x, y, bounds.w, h > 0.0f ? h : 0.0f));
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
        immutable RectF hr = RectF(bounds.x, bounds.y, bounds.w, HEADER_HEIGHT);
        r.fillRect(hr, theme.panelRaised);
        immutable float lh = r.lineHeight(FontId.ui, theme.fontSizeTitle);
        r.pushClip(RectF(hr.x, hr.y, hr.w - 140.0f > 0.0f ? hr.w - 140.0f : 0.0f, hr.h));
        if (title_.length > 0) {
            r.drawText(Point2F(hr.x + 8.0f, hr.y + (hr.h - lh) * 0.5f), title_, FontId.ui, theme.fontSizeTitle, theme.text);
            immutable float nw = r.measureText(title_, FontId.ui, theme.fontSizeTitle);
            r.drawText(Point2F(hr.x + 16.0f + nw, hr.y + (hr.h - r.lineHeight(FontId.ui, theme.fontSizeSmall)) * 0.5f),
                typeText_, FontId.ui, theme.fontSizeSmall, theme.textDim);
        } else {
            r.drawText(Point2F(hr.x + 8.0f, hr.y + (hr.h - lh) * 0.5f), "No module selected", FontId.ui,
                theme.fontSizeTitle, theme.textDim);
        }
        r.popClip();
        if (inChildGraph()) {
            immutable RectF cr = RectF(bounds.x, hr.bottom(), bounds.w, CRUMB_HEIGHT);
            r.fillRect(cr, theme.panelSunken);
            immutable float sl = r.lineHeight(FontId.ui, theme.fontSizeSmall);
            r.drawText(Point2F(cr.x + 66.0f, cr.y + (cr.h - sl) * 0.5f), crumbLine_, FontId.ui, theme.fontSizeSmall, theme.warning);
        }
    }

    /**
     * Applies a control edit: doSetParam on the shown module (inside the active gesture group, if any), or a local
     * child-project change committed immediately when no gesture is active.
     *
     * Params:
     *   paramIdx = Parameter index.
     *   v = New value.
     */
    package void controlChanged(uint paramIdx, float v) {
        auto row = rowFor(paramIdx);
        if (row !is null) {
            row.valueText = formatParamValue(row.desc, v);
        }
        if (inChildGraph()) {
            setChildParam(paramIdx, v);
            if (gestureDepth_ == 0) {
                commitChild();
            }
            return;
        }
        if (gestureDepth_ == 0) {
            ctx_.session.history().breakCoalesce();
        }
        ctx_.session.doSetParam(currentModule(), paramIdx, v);
        if (gestureDepth_ == 0 && row !is null && row.kind != ParamControlKind.slider
                && row.kind != ParamControlKind.logSlider && row.kind != ParamControlKind.steppedSlider) {
            ctx_.session.history().breakCoalesce();
        }
    }

    /**
     * Opens a drag gesture; the outermost one opens an undo group (top-level modules only).
     *
     * Params:
     *   label = Undo label.
     */
    package void beginGesture(string label) {
        if (gestureDepth_++ == 0 && !inChildGraph()) {
            ctx_.session.beginEditGroup(label);
        }
    }

    /**
     * Closes a drag gesture: ends the undo group and breaks coalescing, or commits pending child-project edits.
     */
    package void endGesture() {
        if (gestureDepth_ == 0) {
            return;
        }
        if (--gestureDepth_ > 0) {
            return;
        }
        if (inChildGraph()) {
            if (childDirty_) {
                commitChild();
            }
            return;
        }
        ctx_.session.endEditGroup();
        ctx_.session.history().breakCoalesce();
    }

    private uint currentModule() {
        if (inChildGraph()) {
            return drillChild_;
        }
        immutable uint sel = ctx_.selectedModule();
        return findModule(sel) >= 0 ? sel : 0;
    }

    private bool anyGestureActive() {
        foreach (row; rows_) {
            if (row.gestureActive()) {
                return true;
            }
        }
        return (curve_ !is null && curve_.gestureActive()) || (env_ !is null && env_.gestureActive());
    }

    private ptrdiff_t findModule(uint id) const {
        if (id == 0) {
            return -1;
        }
        foreach (i, ref m; ctx_.session.document().modules) {
            if (m.id == id) {
                return cast(ptrdiff_t) i;
            }
        }
        return -1;
    }

    private ptrdiff_t findChildModule(uint id) const {
        if (!childValid_) {
            return -1;
        }
        foreach (i, ref m; child_.modules) {
            if (m.id == id) {
                return cast(ptrdiff_t) i;
            }
        }
        return -1;
    }

    private ParamRow rowFor(uint paramIdx) {
        foreach (row; rows_) {
            if (row.paramIdx == paramIdx) {
                return row;
            }
        }
        return null;
    }

    private ptrdiff_t mappingIndexFor(uint paramIdx) const {
        if (inChildGraph()) {
            return -1;
        }
        immutable uint mod = ctx_.selectedModule();
        foreach (i, ref mm; ctx_.session.document().midiMappings) {
            if (mm.moduleId == mod && mm.paramIdx == paramIdx) {
                return cast(ptrdiff_t) i;
            }
        }
        return -1;
    }

    private float paramValue(uint paramIdx, float fallback) {
        if (inChildGraph()) {
            immutable ptrdiff_t ci = findChildModule(drillChild_);
            if (ci >= 0 && paramIdx < child_.modules[ci].paramValues.length) {
                return child_.modules[ci].paramValues[paramIdx];
            }
            return fallback;
        }
        immutable ptrdiff_t mi = findModule(ctx_.selectedModule());
        if (mi >= 0 && paramIdx < ctx_.session.document().modules[mi].paramValues.length) {
            return ctx_.session.document().modules[mi].paramValues[paramIdx];
        }
        return fallback;
    }

    private void loadChild(uint metaId) {
        childValid_ = false;
        child_ = LoadedProject.init;
        immutable ptrdiff_t mi = findModule(metaId);
        if (mi < 0) {
            return;
        }
        const(ubyte)[] msv = ctx_.session.document().modules[mi].childProjectMsv;
        if (msv.length == 0) {
            return;
        }
        string err;
        LoadedProject p;
        if (loadProject(msv, p, err, 1)) {
            child_ = p;
            childValid_ = true;
        }
    }

    private void setChildParam(uint paramIdx, float v) {
        immutable ptrdiff_t ci = findChildModule(drillChild_);
        if (ci < 0) {
            return;
        }
        auto desc = ModuleRegistry.findByTypeId(child_.modules[ci].typeId);
        float[] pv = child_.modules[ci].paramValues;
        if (desc !is null && pv.length < desc.params.length) {
            immutable size_t old = pv.length;
            pv.length = desc.params.length;
            foreach (k; old .. pv.length) {
                pv[k] = desc.params[k].defaultVal;
            }
        }
        if (paramIdx < pv.length) {
            pv[paramIdx] = v;
        }
        child_.modules[ci].paramValues = pv;
        childDirty_ = true;
    }

    private bool commitChild() {
        childDirty_ = false;
        immutable ptrdiff_t mi = findModule(drillMeta_);
        if (mi < 0 || !childValid_) {
            return false;
        }
        const sm = &ctx_.session.document().modules[mi];
        MetaMacroBinding[MetaModuleAsset.NUM_MACROS] macros = sm.metaMacros;
        immutable uint input = sm.metaInputModuleId;
        string err;
        if (!ctx_.session.setMetaModuleChildProject(drillMeta_, child_, input, macros, err)) {
            ctx_.setStatus("Child graph edit failed: " ~ err);
            return false;
        }
        ctx_.setStatus("Child graph updated (not undoable)");
        return true;
    }

    private void toggleHeader(uint which, bool on) {
        immutable uint mod = currentModule();
        if (mod == 0 || inChildGraph()) {
            return;
        }
        if (which == 0) {
            ctx_.session.doSetModuleMuted(mod, on);
        } else if (which == 1) {
            ctx_.session.doSetModuleBypassed(mod, on);
        } else {
            ctx_.session.setModuleSolo(mod, on);
        }
    }

    private void rebuild(uint sel, string type) {
        content_.clearChildren();
        rows_ = null;
        curve_ = null;
        curveTarget_ = null;
        env_ = null;
        childButtons_ = null;
        childIds_ = null;
        editorKind_ = RackEditorKind.none;
        haveLastCommitted_ = false;
        contentHeight_ = 0.0f;
        title_ = null;
        typeText_ = null;
        crumbText_ = null;
        if (sel != boundModule_ || type != boundType_) {
            if (learningParam_ >= 0) {
                ctx_.session.cancelMidiLearn();
                learningParam_ = -1;
            }
            drillChild_ = 0;
            drillMeta_ = type == "ctl.metamodule" ? sel : 0;
            curveTargetIndex_ = 0;
        }
        bound_ = true;
        boundModule_ = sel;
        boundType_ = type;
        boundRev_ = ctx_.documentRevision();
        const doc = ctx_.session.document();
        immutable ptrdiff_t mi = findModule(sel);
        if (drillMeta_ != 0) {
            loadChild(drillMeta_);
            if (drillChild_ != 0 && findChildModule(drillChild_) < 0) {
                drillChild_ = 0;
            }
        }
        boundMeta_ = drillMeta_;
        boundChild_ = drillChild_;
        immutable bool child = inChildGraph();
        muteToggle_.visible = mi >= 0 && !child;
        bypassToggle_.visible = mi >= 0 && !child;
        soloToggle_.visible = mi >= 0 && !child;
        if (mi < 0) {
            relayout();
            return;
        }
        string shownType = type;
        if (child) {
            immutable ptrdiff_t ci = findChildModule(drillChild_);
            shownType = child_.modules[ci].typeId;
            title_ = child_.modules[ci].name.length > 0 ? child_.modules[ci].name : shownType;
            crumbText_ = (doc.modules[mi].name.length > 0 ? doc.modules[mi].name : type) ~ " > " ~ title_;
            crumbLine_ = crumbText_ ~ "  (child edits are not undoable)";
        } else {
            title_ = doc.modules[mi].name.length > 0 ? doc.modules[mi].name : type;
        }
        typeText_ = shownType;
        auto desc = ModuleRegistry.findByTypeId(shownType);
        if (desc !is null) {
            foreach (i, ref p; desc.params) {
                ParamDescriptor d = p;
                auto row = new ParamRow(this, cast(uint) i, d);
                row.odd = (i & 1) == 1;
                row.flex.fixed = ROW_HEIGHT;
                row.contextMenuProvider = makeMenuProvider(cast(uint) i);
                content_.add(row);
                rows_ ~= row;
                contentHeight_ += ROW_HEIGHT;
            }
        }
        if (!child) {
            buildEditor(type, desc is null ? null : desc.params);
            if (type == "ctl.metamodule") {
                buildChildList();
            }
        }
        refresh();
        relayout();
    }

    private MenuItem[] delegate(Point2F) makeMenuProvider(uint idx) {
        return (Point2F p) => contextMenuFor(idx);
    }

    private void addSection(string text) {
        auto l = new Label(text);
        l.dim = true;
        l.flex.fixed = SECTION_HEIGHT;
        content_.add(l);
        contentHeight_ += SECTION_HEIGHT;
    }

    private void buildEditor(string type, const(ParamDescriptor)[] params) {
        if (type == "fx.waveshaper") {
            editorKind_ = RackEditorKind.waveshaper;
            addSection("Transfer Curve");
        } else if (type == "ctl.multisynth") {
            editorKind_ = RackEditorKind.multiSynth;
            addSection("Note Curves");
            curveTarget_ = new Dropdown(["Velocity Curve", "Pitch Offset"], curveTargetIndex_, (size_t i) {
                selectCurveTarget(cast(uint) i);
            });
            curveTarget_.id = "rack.curveTarget";
            curveTarget_.flex.fixed = ITEM_HEIGHT;
            content_.add(curveTarget_);
            contentHeight_ += ITEM_HEIGHT;
        } else if (type == "ctl.multictl") {
            editorKind_ = RackEditorKind.multiCtl;
            addSection("Map Curve");
        } else {
            immutable string[4] names = ["Attack", "Decay", "Sustain", "Release"];
            uint found = 0;
            foreach (k, nm; names) {
                foreach (i, ref p; params) {
                    if (p.name == nm) {
                        adsrIdx_[k] = cast(uint) i;
                        found++;
                        break;
                    }
                }
            }
            if (found == 4) {
                editorKind_ = RackEditorKind.adsr;
                addSection("Envelope");
                env_ = new RackEnvelopeEditor();
                env_.id = "rack.envelope";
                env_.flex.fixed = EDITOR_HEIGHT;
                env_.onGestureEnd = (bool changed) {
                    if (changed) {
                        commitEnvelope();
                    }
                };
                content_.add(env_);
                contentHeight_ += EDITOR_HEIGHT;
            }
            return;
        }
        curve_ = new RackCurveEditor();
        curve_.id = "rack.curve";
        curve_.flex.fixed = EDITOR_HEIGHT;
        curve_.maxPoints = 64;
        curve_.onGestureEnd = (bool changed) {
            if (changed) {
                commitCurve();
            }
        };
        content_.add(curve_);
        contentHeight_ += EDITOR_HEIGHT;
    }

    private void buildChildList() {
        addSection(childValid_ ? "Child graph (edits are not undoable)" : "Child graph (empty)");
        if (!childValid_) {
            return;
        }
        foreach (i, ref m; child_.modules) {
            immutable uint cid = m.id;
            auto b = new Button(format("%s  [%s]", m.name.length > 0 ? m.name : m.typeId, m.typeId), makeDrillHandler(cid));
            b.id = format("rack.child.%d", i);
            b.flex.fixed = ITEM_HEIGHT;
            content_.add(b);
            childButtons_ ~= b;
            childIds_ ~= cid;
            contentHeight_ += ITEM_HEIGHT;
        }
    }

    private void delegate() makeDrillHandler(uint cid) {
        return () {
            drillChild_ = cid;
            invalidate();
        };
    }

    private void refresh() {
        boundRev_ = ctx_.documentRevision();
        immutable ptrdiff_t mi = findModule(ctx_.selectedModule());
        if (mi >= 0) {
            const sm = &ctx_.session.document().modules[mi];
            muteToggle_.setChecked(sm.muted, false);
            bypassToggle_.setChecked(sm.bypassed, false);
        }
        foreach (row; rows_) {
            row.showValue(paramValue(row.paramIdx, row.desc.defaultVal));
            immutable ptrdiff_t mapIdx = mappingIndexFor(row.paramIdx);
            row.badgeText = mapIdx >= 0 ? format("CC %d", ctx_.session.document().midiMappings[mapIdx].cc) : null;
            row.learning = learningParam_ == cast(int) row.paramIdx;
        }
        if (curve_ !is null) {
            loadCurvePoints();
        }
        if (env_ !is null) {
            loadEnvelope();
        }
        invalidate();
    }

    private void relayout() {
        layoutChildren();
        invalidate();
    }

    private const(ubyte)[] currentBlob() {
        immutable ptrdiff_t mi = findModule(ctx_.selectedModule());
        return mi >= 0 ? ctx_.session.document().modules[mi].extraBlob : null;
    }

    private void curveDomain(out float lo, out float hi) {
        final switch (editorKind_) {
        case RackEditorKind.waveshaper:
            lo = -1.0f;
            hi = 1.0f;
            break;
        case RackEditorKind.multiSynth:
            lo = curveTargetIndex_ == 0 ? 0.0f : -24.0f;
            hi = curveTargetIndex_ == 0 ? 2.0f : 24.0f;
            break;
        case RackEditorKind.multiCtl:
        case RackEditorKind.none:
        case RackEditorKind.adsr:
            lo = 0.0f;
            hi = 1.0f;
            break;
        }
    }

    private void loadCurvePoints() {
        if (curve_ is null) {
            return;
        }
        const(ubyte)[] blob = currentBlob();
        if (haveLastCommitted_ && blob == lastCommittedBlob_) {
            return;
        }
        float lo;
        float hi;
        curveDomain(lo, hi);
        Point2F[] pts;
        final switch (editorKind_) {
        case RackEditorKind.waveshaper:
            auto a = loadAssetOrDefault!WaveShaperCurveAsset(blob);
            pts = curveTableToPoints(a.table[], lo, hi);
            break;
        case RackEditorKind.multiSynth:
            auto a = loadAssetOrDefault!MultiSynthCurveAsset(blob);
            pts = curveTableToPoints(curveTargetIndex_ == 0 ? a.velCurve[] : a.pitchOffset[], lo, hi);
            break;
        case RackEditorKind.multiCtl:
            auto a = loadAssetOrDefault!MultiCtlMapAsset(blob);
            pts = curveTableToPoints(a.curve[], lo, hi);
            break;
        case RackEditorKind.none:
        case RackEditorKind.adsr:
            return;
        }
        curve_.points = pts;
        curve_.selected = -1;
        curve_.invalidate();
    }

    private ubyte[] buildCurveBlob() {
        const(ubyte)[] blob = currentBlob();
        float lo;
        float hi;
        curveDomain(lo, hi);
        final switch (editorKind_) {
        case RackEditorKind.waveshaper:
            auto a = loadAssetOrDefault!WaveShaperCurveAsset(blob);
            resampleCurveToTable(curve_, a.table[], lo, hi);
            return assetBytes(a);
        case RackEditorKind.multiSynth:
            auto a = loadAssetOrDefault!MultiSynthCurveAsset(blob);
            resampleCurveToTable(curve_, curveTargetIndex_ == 0 ? a.velCurve[] : a.pitchOffset[], lo, hi);
            return assetBytes(a);
        case RackEditorKind.multiCtl:
            auto a = loadAssetOrDefault!MultiCtlMapAsset(blob);
            resampleCurveToTable(curve_, a.curve[], lo, hi);
            return assetBytes(a);
        case RackEditorKind.none:
        case RackEditorKind.adsr:
            return null;
        }
    }

    private void commitCurve() {
        immutable uint mod = currentModule();
        ubyte[] blob = buildCurveBlob();
        if (mod == 0 || blob.length == 0) {
            return;
        }
        if (ctx_.session.doSetModuleExtra(mod, blob, "Edit Curve")) {
            lastCommittedBlob_ = blob;
            haveLastCommitted_ = true;
        } else {
            ctx_.setStatus("Curve edit could not be applied");
            haveLastCommitted_ = false;
            loadCurvePoints();
        }
    }

    private void loadEnvelope() {
        if (env_ is null) {
            return;
        }
        immutable float a = paramValue(adsrIdx_[0], rows_[adsrIdx_[0]].desc.defaultVal);
        immutable float d = paramValue(adsrIdx_[1], rows_[adsrIdx_[1]].desc.defaultVal);
        immutable float s = paramValue(adsrIdx_[2], rows_[adsrIdx_[2]].desc.defaultVal);
        immutable float rel = paramValue(adsrIdx_[3], rows_[adsrIdx_[3]].desc.defaultVal);
        immutable ParamDescriptor sd = rows_[adsrIdx_[2]].desc;
        immutable float sn = sd.maxVal > sd.minVal ? (s - sd.minVal) / (sd.maxVal - sd.minVal) : 0.0f;
        env_.setAdsr(a, d, sn, rel);
    }

    private void commitEnvelope() {
        immutable uint mod = currentModule();
        if (mod == 0 || env_.points.length != 4) {
            return;
        }
        float[4] cur;
        foreach (k; 0 .. 4) {
            cur[k] = paramValue(adsrIdx_[k], rows_[adsrIdx_[k]].desc.defaultVal);
        }
        immutable float total = cur[0] + cur[1] + cur[3] > 0.0f ? cur[0] + cur[1] + cur[3] : 1.0f;
        immutable Point2F p1 = env_.points[1];
        immutable Point2F p2 = env_.points[2];
        immutable ParamDescriptor sd = rows_[adsrIdx_[2]].desc;
        float[4] next = [p1.x * total, (p2.x - p1.x) * total, sd.minVal + p2.y * (sd.maxVal - sd.minVal),
            (1.0f - p2.x) * total];
        ctx_.session.beginEditGroup("Edit Envelope");
        foreach (k; 0 .. 4) {
            immutable ParamDescriptor pd = rows_[adsrIdx_[k]].desc;
            next[k] = clampf(next[k], pd.minVal, pd.maxVal);
            if (next[k] != cur[k]) {
                ctx_.session.doSetParam(mod, adsrIdx_[k], next[k]);
            }
        }
        ctx_.session.endEditGroup();
        ctx_.session.history().breakCoalesce();
    }
}
