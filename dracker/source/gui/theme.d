/**
 * File:         source/gui/theme.d
 * Module:       gui.theme
 * Phase:        Phase 8.5 — Accessible Semantic Color Tokens (Phase 7.5 metrics unchanged)
 *
 * Purpose:
 *   Centralizes the studio design tokens: semantic colors (surfaces, text, accent/focus/status states, typed
 *   patch-cable wire colors for audio / sidechain / event / CV ports, tracker field colors, transport lights,
 *   meters, scope traces, module categories, eight categorical clip colors), the appearance flags (light/dark,
 *   contrast mode, palette name, glyph coverage gamma), and the spacing, corner-radius, control and font-size
 *   metrics. All metrics are logical points; Retina scaling is applied by the renderer. The default-initialized
 *   value is the "Light · High Contrast · Okabe–Ito" appearance; palettes and contrast variants are built by
 *   gui.appearance, which only ever replaces color tokens and appearance flags, never metrics.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. StudioTheme is a plain value type; widgets receive it by const reference at draw time and
 *   never mutate it. No global mutable state.
 *
 * Dependencies:
 *   Internal: gui.renderer (ColorRGBA), graph.port (PortKind), graph.module_api (ModuleCategory)
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum WireKind : ubyte { audio, sidechain, event, cv } / enum WireDash / enum ContrastMode
 *   - struct StudioTheme : color tokens, appearance flags, spacing/radius/control metrics, font sizes
 *       static StudioTheme light(); ColorRGBA wireColor(WireKind) const; ColorRGBA portColor(PortKind) const;
 *       WireDash wireDash(WireKind) const; ColorRGBA categoryColor(ModuleCategory) const; ColorRGBA clipColor(size_t)
 *       const; ColorRGBA emphasize(ColorRGBA, float) const; float spacing(uint) const; StudioTheme scaled(float) const
 *   - WireKind wireKindOf(PortKind kind)
 *   - THEME_COLOR_TOKENS / THEME_METRIC_FIELDS name tables; colorToken(), setColorToken(), colorTokenIndex()
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 7.5, Phase 8.5)
 */
module gui.theme;

import gui.renderer : ColorRGBA;
import graph.module_api : ModuleCategory;
import graph.port : PortKind;

/**
 * Visual wire categories used for patch cables and port badges.
 */
enum WireKind : ubyte {
    audio = 0,
    sidechain = 1,
    event = 2,
    cv = 3
}

/**
 * Non-color line style that redundantly encodes a wire kind (color is never the only cue).
 */
enum WireDash : ubyte {
    solid = 0,
    doubled = 1,
    dashed = 2,
    dotted = 3
}

/**
 * Contrast level of an appearance.
 *
 * High targets WCAG AAA (text ≥ 7:1, graphics ≥ 4.5:1); low targets AA (text ≥ 4.5:1, graphics ≥ 3:1).
 */
enum ContrastMode : ubyte {
    high = 0,
    low = 1
}

/**
 * Maps a graph port kind onto its wire color category.
 *
 * Params:
 *   kind = Graph port kind.
 *
 * Returns:
 *   Wire category (mono and stereo audio share the audio color).
 */
WireKind wireKindOf(PortKind kind) @safe nothrow pure @nogc {
    final switch (kind) {
    case PortKind.audioStereo:
    case PortKind.audioMono:
        return WireKind.audio;
    case PortKind.sidechainStereo:
        return WireKind.sidechain;
    case PortKind.event:
        return WireKind.event;
    case PortKind.cvControl:
        return WireKind.cv;
    }
}

/**
 * Complete set of studio design tokens. The default-initialized value is "Light · High Contrast · Okabe–Ito".
 */
struct StudioTheme {
    ColorRGBA background = ColorRGBA.fromHex(0xFFFFFFFF);
    ColorRGBA panel = ColorRGBA.fromHex(0xF4F4F4FF);
    ColorRGBA panelRaised = ColorRGBA.fromHex(0xFFFFFFFF);
    ColorRGBA panelSunken = ColorRGBA.fromHex(0xEBEBEBFF);
    ColorRGBA border = ColorRGBA.fromHex(0x5C5C5CFF);
    ColorRGBA borderStrong = ColorRGBA.fromHex(0x000000FF);
    ColorRGBA text = ColorRGBA.fromHex(0x000000FF);
    ColorRGBA textDim = ColorRGBA.fromHex(0x333333FF);
    ColorRGBA textDisabled = ColorRGBA.fromHex(0x4D4D4DFF);
    ColorRGBA accent = ColorRGBA.fromHex(0x004A73FF);
    ColorRGBA accentHot = ColorRGBA.fromHex(0x00324FFF);
    ColorRGBA accentText = ColorRGBA.fromHex(0xFFFFFFFF);
    ColorRGBA focusRing = ColorRGBA.fromHex(0x004A73FF);
    ColorRGBA danger = ColorRGBA.fromHex(0x941E15FF);
    ColorRGBA warning = ColorRGBA.fromHex(0x654600FF);
    ColorRGBA success = ColorRGBA.fromHex(0x005840FF);
    ColorRGBA hover = ColorRGBA.fromHex(0x0000000D);
    ColorRGBA pressed = ColorRGBA.fromHex(0x00000022);
    ColorRGBA selection = ColorRGBA.fromHex(0x004A7314);
    ColorRGBA shadow = ColorRGBA.fromHex(0x00000033);
    ColorRGBA scrollTrack = ColorRGBA.fromHex(0x0000000F);
    ColorRGBA scrollThumb = ColorRGBA.fromHex(0x5C5C5CFF);
    ColorRGBA scrollThumbHot = ColorRGBA.fromHex(0x333333FF);
    ColorRGBA gridLine = ColorRGBA.fromHex(0x0000001A);
    ColorRGBA mutedHatch = ColorRGBA.fromHex(0x00000040);

    ColorRGBA wireAudio = ColorRGBA.fromHex(0x004A73FF);
    ColorRGBA wireSidechain = ColorRGBA.fromHex(0x8F5575FF);
    ColorRGBA wireEvent = ColorRGBA.fromHex(0xAA4B00FF);
    ColorRGBA wireCv = ColorRGBA.fromHex(0x007656FF);

    ColorRGBA trackerBackground = ColorRGBA.fromHex(0xFFFFFFFF);
    ColorRGBA trackerRowBeat = ColorRGBA.fromHex(0xF7F7F7FF);
    ColorRGBA trackerRowBar = ColorRGBA.fromHex(0xF0F0F0FF);
    ColorRGBA trackerCursor = ColorRGBA.fromHex(0x004A73FF);
    ColorRGBA trackerPlayhead = ColorRGBA.fromHex(0xF9EEEDFF);
    ColorRGBA trackerNote = ColorRGBA.fromHex(0x000000FF);
    ColorRGBA trackerVelocity = ColorRGBA.fromHex(0x003426FF);
    ColorRGBA trackerModule = ColorRGBA.fromHex(0x753400FF);
    ColorRGBA trackerEffect = ColorRGBA.fromHex(0x5D374CFF);
    ColorRGBA trackerParam = ColorRGBA.fromHex(0x004A74FF);
    ColorRGBA trackerEmpty = ColorRGBA.fromHex(0x464646FF);

    ColorRGBA transportPlayLit = ColorRGBA.fromHex(0x004A73FF);
    ColorRGBA transportRecordLit = ColorRGBA.fromHex(0x941E15FF);
    ColorRGBA transportLoopLit = ColorRGBA.fromHex(0x654600FF);
    ColorRGBA meterLow = ColorRGBA.fromHex(0x005840FF);
    ColorRGBA meterMid = ColorRGBA.fromHex(0x654600FF);
    ColorRGBA meterHigh = ColorRGBA.fromHex(0x941E15FF);
    ColorRGBA scopeTraceL = ColorRGBA.fromHex(0x004A73FF);
    ColorRGBA scopeTraceR = ColorRGBA.fromHex(0xAA4B00FF);

    ColorRGBA categoryCore = ColorRGBA.fromHex(0x654600FF);
    ColorRGBA categorySynth = ColorRGBA.fromHex(0x004A73FF);
    ColorRGBA categoryEffect = ColorRGBA.fromHex(0x8F5575FF);
    ColorRGBA categoryControl = ColorRGBA.fromHex(0x007656FF);

    ColorRGBA clip0 = ColorRGBA.fromHex(0xE8A50FFF);
    ColorRGBA clip1 = ColorRGBA.fromHex(0x78C3EDFF);
    ColorRGBA clip2 = ColorRGBA.fromHex(0x24AC87FF);
    ColorRGBA clip3 = ColorRGBA.fromHex(0xF2E860FF);
    ColorRGBA clip4 = ColorRGBA.fromHex(0xCE7EABFF);
    ColorRGBA clip5 = ColorRGBA.fromHex(0xC6E6F8FF);
    ColorRGBA clip6 = ColorRGBA.fromHex(0xF0C5A3FF);
    ColorRGBA clip7 = ColorRGBA.fromHex(0xC7C7C7FF);
    ColorRGBA clipText = ColorRGBA.fromHex(0x000000FF);

    ColorRGBA pianoWhiteKey = ColorRGBA.fromHex(0xFFFFFFFF);
    ColorRGBA pianoBlackKey = ColorRGBA.fromHex(0x000000FF);
    ColorRGBA pianoKeyBorder = ColorRGBA.fromHex(0x000000FF);
    ColorRGBA pianoKeyText = ColorRGBA.fromHex(0x000000FF);

    ColorRGBA rollNote = ColorRGBA.fromHex(0x004A73FF);
    ColorRGBA rollNoteSelected = ColorRGBA.fromHex(0x00324FFF);
    ColorRGBA padHit = ColorRGBA.fromHex(0x004A73FF);

    /**
     * True for light (dark-on-light) appearances; selects the emphasize() direction.
     */
    bool isLight = true;

    /**
     * Contrast level the color tokens were built for.
     */
    ContrastMode contrast = ContrastMode.high;

    /**
     * Display name of the appearance ("Light · High Contrast · Okabe–Ito").
     */
    string paletteName = "Light · High Contrast · Okabe–Ito";

    /**
     * Glyph coverage exponent applied by the GPU text path (< 1 thickens dark-on-light text; 1 = unchanged).
     */
    float textGamma = 0.80f;

    float spacingXs = 2.0f;
    float spacingSm = 4.0f;
    float spacingMd = 8.0f;
    float spacingLg = 12.0f;
    float spacingXl = 16.0f;

    float radiusSm = 3.0f;
    float radiusMd = 5.0f;
    float radiusLg = 8.0f;

    float borderWidth = 1.0f;
    float focusRingWidth = 2.0f;
    float focusRingGap = 2.0f;

    float fontSizeSmall = 11.0f;
    float fontSizeBody = 13.0f;
    float fontSizeTitle = 15.0f;
    float fontSizeMono = 12.0f;

    float controlHeight = 22.0f;
    float menuItemHeight = 22.0f;
    float scrollbarThickness = 10.0f;
    float scrollbarMinThumb = 18.0f;
    float splitterThickness = 4.0f;
    float sliderTrackThickness = 4.0f;
    float sliderThumbSize = 12.0f;
    float knobSize = 36.0f;
    float knobArcWidth = 3.0f;
    float curvePointRadius = 4.0f;
    float curveLineWidth = 1.5f;
    float wireWidth = 2.0f;

    /**
     * Returns the default light high-contrast theme.
     *
     * Returns:
     *   "Light · High Contrast · Okabe–Ito" with default metrics.
     */
    static StudioTheme light() @safe nothrow pure @nogc {
        return StudioTheme.init;
    }

    /**
     * Returns the cable color for a wire category.
     *
     * Params:
     *   kind = Wire category.
     *
     * Returns:
     *   Wire color.
     */
    ColorRGBA wireColor(WireKind kind) const @safe nothrow pure @nogc {
        final switch (kind) {
        case WireKind.audio:
            return wireAudio;
        case WireKind.sidechain:
            return wireSidechain;
        case WireKind.event:
            return wireEvent;
        case WireKind.cv:
            return wireCv;
        }
    }

    /**
     * Returns the cable color for a graph port kind.
     *
     * Params:
     *   kind = Graph port kind.
     *
     * Returns:
     *   Wire color.
     */
    ColorRGBA portColor(PortKind kind) const @safe nothrow pure @nogc {
        return wireColor(wireKindOf(kind));
    }

    /**
     * Returns the line style that redundantly encodes a wire kind.
     *
     * Params:
     *   kind = Wire category.
     *
     * Returns:
     *   Audio solid, sidechain doubled, event dashed, CV dotted.
     */
    static WireDash wireDash(WireKind kind) @safe nothrow pure @nogc {
        final switch (kind) {
        case WireKind.audio:
            return WireDash.solid;
        case WireKind.sidechain:
            return WireDash.doubled;
        case WireKind.event:
            return WireDash.dashed;
        case WireKind.cv:
            return WireDash.dotted;
        }
    }

    /**
     * Returns the accent color of a module category (patchbay node stripe and header tint).
     *
     * Params:
     *   c = Module category.
     *
     * Returns:
     *   Category color.
     */
    ColorRGBA categoryColor(ModuleCategory c) const @safe nothrow pure @nogc {
        final switch (c) {
        case ModuleCategory.core:
            return categoryCore;
        case ModuleCategory.synth:
            return categorySynth;
        case ModuleCategory.effect:
            return categoryEffect;
        case ModuleCategory.control:
            return categoryControl;
        }
    }

    /**
     * Returns the opacity of a module category tint behind a patchbay node header.
     *
     * Params:
     *   output = True for the output node (stronger tint).
     *
     * Returns:
     *   Alpha in [0, 1] (lower on dark themes, where category colors are bright).
     */
    float categoryTint(bool output) const @safe nothrow pure @nogc {
        return isLight ? (output ? 0.55f : 0.30f) : (output ? 0.22f : 0.12f);
    }

    /**
     * Returns one of the eight categorical clip/pattern fill colors (index wraps).
     *
     * Params:
     *   index = Slot index.
     *
     * Returns:
     *   Fill color (labels use clipText).
     */
    ColorRGBA clipColor(size_t index) const @safe nothrow pure @nogc {
        switch (index % 8) {
        case 0:
            return clip0;
        case 1:
            return clip1;
        case 2:
            return clip2;
        case 3:
            return clip3;
        case 4:
            return clip4;
        case 5:
            return clip5;
        case 6:
            return clip6;
        default:
            return clip7;
        }
    }

    /**
     * Pushes a color away from the surface: darker on light themes, lighter on dark ones (hover/pressed states).
     *
     * Params:
     *   c = Base color.
     *   amount = Blend amount in [0, 1] toward black (light) or white (dark).
     *
     * Returns:
     *   Adjusted color with unchanged alpha.
     */
    ColorRGBA emphasize(ColorRGBA c, float amount) const @safe nothrow pure @nogc {
        immutable float t = amount < 0.0f ? 0.0f : (amount > 1.0f ? 1.0f : amount);
        immutable ColorRGBA target = isLight ? ColorRGBA(0, 0, 0, c.a) : ColorRGBA(1, 1, 1, c.a);
        return c.lerp(target, t).withAlpha(c.a);
    }

    /**
     * Returns a spacing value from the scale (0 = none, 1 = xs ... 5 = xl, larger steps saturate at xl).
     *
     * Params:
     *   step = Scale step.
     *
     * Returns:
     *   Spacing in logical points.
     */
    float spacing(uint step) const @safe nothrow pure @nogc {
        switch (step) {
        case 0:
            return 0.0f;
        case 1:
            return spacingXs;
        case 2:
            return spacingSm;
        case 3:
            return spacingMd;
        case 4:
            return spacingLg;
        default:
            return spacingXl;
        }
    }

    /**
     * Returns a copy whose every length metric (spacing, radii, strokes, fonts, control sizes) is multiplied by factor.
     *
     * Params:
     *   factor = Positive UI zoom factor (non-positive or non-finite values return an unchanged copy).
     *
     * Returns:
     *   Scaled theme with identical colors.
     */
    StudioTheme scaled(float factor) const @safe nothrow pure @nogc {
        StudioTheme t = this;
        if (!(factor > 0.0f) || factor == float.infinity) {
            return t;
        }
        static foreach (name; THEME_METRIC_FIELDS) {
            __traits(getMember, t, name) *= factor;
        }
        return t;
    }
}

/**
 * Names of every length metric of StudioTheme (all unchanged by palette and contrast switches).
 */
static immutable string[] THEME_METRIC_FIELDS = ["spacingXs", "spacingSm", "spacingMd", "spacingLg", "spacingXl", "radiusSm",
        "radiusMd", "radiusLg", "borderWidth", "focusRingWidth", "focusRingGap", "fontSizeSmall", "fontSizeBody",
        "fontSizeTitle", "fontSizeMono", "controlHeight", "menuItemHeight", "scrollbarThickness", "scrollbarMinThumb",
        "splitterThickness", "sliderTrackThickness", "sliderThumbSize", "knobSize", "knobArcWidth",
        "curvePointRadius", "curveLineWidth", "wireWidth"];

private string[] collectColorTokens() @safe pure nothrow {
    string[] names;
    static foreach (m; __traits(allMembers, StudioTheme)) {
        static if (is(typeof(__traits(getMember, StudioTheme.init, m)) == ColorRGBA)) {
            names ~= m;
        }
    }
    return names;
}

/**
 * Names of every color token of StudioTheme, in declaration order (settings codec and palette editor order).
 */
enum string[] THEME_COLOR_TOKENS = collectColorTokens();

/**
 * Returns the index of a color token name.
 *
 * Params:
 *   name = Token name.
 *
 * Returns:
 *   Index into THEME_COLOR_TOKENS, or -1 when unknown.
 */
ptrdiff_t colorTokenIndex(const(char)[] name) @safe nothrow pure @nogc {
    static foreach (i, n; THEME_COLOR_TOKENS) {
        if (name == n) {
            return i;
        }
    }
    return -1;
}

/**
 * Reads a color token by index.
 *
 * Params:
 *   t = Theme.
 *   index = Index into THEME_COLOR_TOKENS.
 *
 * Returns:
 *   Token color (transparent black when out of range).
 */
ColorRGBA colorToken(const ref StudioTheme t, size_t index) @safe nothrow pure @nogc {
    switch (index) {
        static foreach (i, n; THEME_COLOR_TOKENS) {
    case i:
            return __traits(getMember, t, n);
        }
    default:
        return ColorRGBA(0, 0, 0, 0);
    }
}

/**
 * Writes a color token by index.
 *
 * Params:
 *   t = Theme to modify.
 *   index = Index into THEME_COLOR_TOKENS.
 *   c = New color.
 *
 * Returns:
 *   False when index is out of range.
 */
bool setColorToken(ref StudioTheme t, size_t index, ColorRGBA c) @safe nothrow pure @nogc {
    switch (index) {
        static foreach (i, n; THEME_COLOR_TOKENS) {
    case i:
            __traits(getMember, t, n) = c;
            return true;
        }
    default:
        return false;
    }
}
