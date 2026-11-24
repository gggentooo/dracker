/**
 * File:         source/gui/appearance.d
 * Module:       gui.appearance
 * Phase:        Phase 8.5 — Appearance Model: Palettes, Contrast Modes, Validators & Settings Codec
 *
 * Purpose:
 *   Pure-D, headless appearance model. Defines the built-in palettes ("Light · Okabe–Ito" default, "Light · Tol
 *   Bright", "Dark · Okabe–Ito"), user custom palettes, and makeTheme(), which turns a palette plus a High/Low
 *   contrast mode into a StudioTheme while keeping every size metric from StudioTheme.init. Low contrast is
 *   derived deterministically (off-white or lifted surfaces, softened text and borders) and never drops a token
 *   below the Low floor. Provides the WCAG 2.x contrast ratio, the list of every foreground/background pair the
 *   UI draws (usedTextPairs / usedGraphicPairs, including tinted rows, selections and hover overlays), Machado
 *   2009 color-vision-deficiency simulation, CIEDE2000 color difference, the categorical color sets that must
 *   stay distinguishable, and the strict versioned key=value codecs for appearance preferences and .stpalette
 *   files (never throw; reject unknown versions, unknown keys, out-of-range values and oversized input).
 *   Also declares the platform services the apply path needs (IAppearanceBackend) and the preferences store.
 *
 * Real-Time & Safety Contract:
 *   UI thread only; no RT interaction. Codecs are nothrow and bounded by explicit size limits.
 *
 * Dependencies:
 *   Internal: gui.renderer (ColorRGBA, decodeUtf8), gui.theme
 *   External: std.file, std.path (FileAppearanceStore only)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct PaletteSpec / struct AppearanceSettings / struct ContrastPair / struct CategoricalSet / enum CvdType
 *   - builtinPalettes(), findPalette(), makeTheme(), themeFor()
 *   - relativeLuminance(), contrastRatio(), compositeOver(), textFloor(), graphicFloor()
 *   - usedTextPairs(), usedGraphicPairs(), contrastFailures(), categoricalSets(), minCategoricalDeltaE()
 *   - simulateCvd(), deltaE2000()
 *   - encodeAppearance()/decodeAppearance(), encodePalette()/decodePalette()
 *   - duplicateAsCustom(), renameCustomNext(), deleteCustom(), resetCustom(), setCustomToken(), addImportedPalette()
 *   - struct TokenGroup / tokenGroups(); struct ContrastReading / contrastReadout() (palette editor)
 *   - defaultAppearancePath()
 *   - struct FontResolution / interface IAppearanceBackend / interface IAppearanceStore / class FileAppearanceStore
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.5)
 */
module gui.appearance;

import std.math : atan2, cos, exp, fabs, isFinite, pow, sin, sqrt, PI;

import gui.renderer : ColorRGBA, decodeUtf8;
import gui.theme;

/**
 * Default UI font family.
 */
enum string DEFAULT_UI_FONT = "Atkinson Hyperlegible Next";

/**
 * Default monospace (pattern grid) font family.
 */
enum string DEFAULT_MONO_FONT = "Fira Code";

/**
 * Name of the default built-in palette.
 */
enum string DEFAULT_PALETTE = "Light · Okabe–Ito";

/**
 * Settings file format version written by encodeAppearance().
 */
enum uint APPEARANCE_FORMAT_VERSION = 1;

/**
 * Palette file (.stpalette) format version written by encodePalette().
 */
enum uint PALETTE_FORMAT_VERSION = 1;

/**
 * Largest accepted settings or palette text in bytes.
 */
enum size_t MAX_APPEARANCE_BYTES = 256 * 1024;

/**
 * Most custom palettes kept in the settings.
 */
enum size_t MAX_CUSTOM_PALETTES = 32;

/**
 * Longest palette name in bytes.
 */
enum size_t MAX_PALETTE_NAME = 64;

/**
 * Longest font family name in bytes.
 */
enum size_t MAX_FONT_NAME = 128;

/**
 * Named color palette (built-in preset or user custom palette).
 *
 * Only the color tokens and isLight of colors are used; metrics and other flags are ignored by makeTheme().
 */
struct PaletteSpec {
    string name;
    string origin;
    bool builtin = false;
    StudioTheme colors;
}

/**
 * Persistent appearance preferences (never stored in projects).
 */
struct AppearanceSettings {
    string uiFont = DEFAULT_UI_FONT;
    string monoFont = DEFAULT_MONO_FONT;
    ContrastMode contrast = ContrastMode.high;
    string palette = DEFAULT_PALETTE;
    PaletteSpec[] customPalettes;
}

/**
 * One foreground/background combination the UI draws.
 */
struct ContrastPair {
    string fg;
    string bg;
    ColorRGBA fgColor;
    ColorRGBA bgColor;
    bool isText;
}

/**
 * Colors that must stay mutually distinguishable (plus their non-color cue).
 */
struct CategoricalSet {
    string name;
    string cue;
    string[] tokens;
}

/**
 * Simulated color-vision deficiency (Machado, Oliveira & Fernandes 2009, severity 1.0).
 */
enum CvdType : ubyte {
    none = 0,
    protanopia = 1,
    deuteranopia = 2,
    tritanopia = 3
}

/**
 * Result of resolving the requested font families on the platform.
 */
struct FontResolution {
    string requestedUi;
    string requestedMono;
    string uiFamily;
    string monoFamily;
    bool uiFound = false;
    bool monoFound = false;
    string uiSource;
    string monoSource;
    float uiWeight = 0.0f;
    float monoWeight = 0.0f;
}

/**
 * Platform services used when an appearance is applied (CoreText + Metal in the app; faked in tests).
 */
interface IAppearanceBackend {
    /**
     * Lists installed and bundled font families.
     *
     * Params:
     *   monospaceOnly = True to list only fixed-pitch families.
     *
     * Returns:
     *   Sorted family names.
     */
    string[] fontFamilies(bool monospaceOnly);

    /**
     * Switches the UI and monospace families (Regular weight) and flushes the glyph cache.
     *
     * Params:
     *   uiFamily = Requested UI family.
     *   monoFamily = Requested monospace family.
     *
     * Returns:
     *   What was actually resolved.
     */
    FontResolution applyFonts(string uiFamily, string monoFamily);

    /**
     * Applies renderer-level appearance (frame clear color and glyph coverage gamma).
     *
     * Params:
     *   clearColor = Window clear color (theme background).
     *   textGamma = Glyph coverage exponent.
     */
    void applyRendererAppearance(ColorRGBA clearColor, float textGamma);
}

/**
 * Persistent storage of the appearance settings text.
 */
interface IAppearanceStore {
    /**
     * Reads the stored text.
     *
     * Params:
     *   text = Receives the text.
     *
     * Returns:
     *   False when nothing is stored or it cannot be read.
     */
    bool load(out string text);

    /**
     * Replaces the stored text atomically.
     *
     * Params:
     *   text = New text.
     *   err = Receives a diagnostic on failure.
     *
     * Returns:
     *   True on success.
     */
    bool save(string text, out string err);
}

/**
 * IAppearanceStore over one file, written through a temporary file plus rename.
 */
final class FileAppearanceStore : IAppearanceStore {
    private string path_;

    /**
     * Binds the store to path (its directory is created on first save).
     *
     * Params:
     *   path = Settings file path.
     */
    this(string path) {
        path_ = path;
    }

    /**
     * Returns the settings file path.
     *
     * Returns:
     *   Path.
     */
    string path() const {
        return path_;
    }

    override bool load(out string text) {
        import std.file : exists, getSize, isFile, read;

        try {
            if (!exists(path_) || !isFile(path_) || getSize(path_) > MAX_APPEARANCE_BYTES) {
                return false;
            }
            text = cast(string) read(path_);
            return true;
        } catch (Exception) {
            return false;
        }
    }

    override bool save(string text, out string err) {
        import std.file : exists, mkdirRecurse, remove, rename, write;
        import std.path : dirName;

        immutable string tmp = path_ ~ ".tmp";
        try {
            mkdirRecurse(dirName(path_));
            write(tmp, text);
            rename(tmp, path_);
            return true;
        } catch (Exception e) {
            err = e.msg;
            try {
                if (exists(tmp)) {
                    remove(tmp);
                }
            } catch (Exception) {
            }
            return false;
        }
    }
}

/**
 * Returns the default settings path (~/Library/Application Support/Dracker/appearance.cfg on macOS).
 *
 * Returns:
 *   Path, or an empty string when HOME is unset.
 */
string defaultAppearancePath() {
    import std.path : buildPath;
    import std.process : environment;

    immutable string home = environment.get("HOME", "");
    if (home.length == 0) {
        return "";
    }
    return buildPath(home, "Library", "Application Support", "Dracker", "appearance.cfg");
}

private struct HexToken {
    string name;
    uint rgba;
}

private StudioTheme withTokens(StudioTheme base, bool light, const(HexToken)[] tokens) {
    StudioTheme t = base;
    t.isLight = light;
    foreach (ref h; tokens) {
        immutable ptrdiff_t i = colorTokenIndex(h.name);
        assert(i >= 0, "unknown palette token " ~ h.name);
        setColorToken(t, cast(size_t) i, ColorRGBA.fromHex(h.rgba));
    }
    return t;
}

private immutable HexToken[] TOL_LIGHT = [
    HexToken("accent", 0x1F364DFF), HexToken("accentHot", 0x0F1B27FF), HexToken("focusRing", 0x1F364DFF),
    HexToken("danger", 0x7D363EFF), HexToken("warning", 0x4B4519FF), HexToken("success", 0x165821FF),
    HexToken("selection", 0x1F364D14), HexToken("wireAudio", 0x1F364DFF), HexToken("wireSidechain", 0xAA3377FF),
    HexToken("wireEvent", 0x78343CFF), HexToken("wireCv", 0x1E772DFF), HexToken("trackerCursor", 0x1F364DFF),
    HexToken("trackerPlayhead", 0xF9EEEFFF), HexToken("trackerVelocity", 0x0D3213FF),
    HexToken("trackerModule", 0x723139FF), HexToken("trackerEffect", 0x471532FF), HexToken("trackerParam", 0x294867FF),
    HexToken("transportPlayLit", 0x1F364DFF), HexToken("transportRecordLit", 0x7D363EFF),
    HexToken("transportLoopLit", 0x4B4519FF), HexToken("meterLow", 0x165821FF), HexToken("meterMid", 0x4B4519FF),
    HexToken("meterHigh", 0x7D363EFF), HexToken("scopeTraceL", 0x1F364DFF), HexToken("scopeTraceR", 0x78343CFF),
    HexToken("categoryCore", 0x4B4519FF), HexToken("categorySynth", 0x1F364DFF),
    HexToken("categoryEffect", 0xAA3377FF), HexToken("categoryControl", 0x1E772DFF),
    HexToken("clip0", 0xE0EEE2FF), HexToken("clip1", 0x5BA768FF), HexToken("clip2", 0xCA81ABFF),
    HexToken("clip3", 0x66CCEEFF), HexToken("clip4", 0xCCBB44FF), HexToken("clip5", 0xE8E0A9FF),
    HexToken("clip6", 0xBEBEBEFF), HexToken("clip7", 0xC5ECF9FF)
];

private immutable HexToken[] DARK_OKABE_ITO = [
    HexToken("background", 0x0B0C0EFF), HexToken("panel", 0x16181CFF), HexToken("panelRaised", 0x202329FF),
    HexToken("panelSunken", 0x07080AFF), HexToken("border", 0x8C9099FF), HexToken("borderStrong", 0xC8CCD4FF),
    HexToken("text", 0xFFFFFFFF), HexToken("textDim", 0xD0D3D9FF), HexToken("textDisabled", 0xADB1B8FF),
    HexToken("accent", 0x7DB7D8FF), HexToken("accentHot", 0xB5D8ECFF), HexToken("accentText", 0x000000FF),
    HexToken("focusRing", 0x7DB7D8FF), HexToken("danger", 0xEB9B95FF), HexToken("warning", 0xF0E442FF),
    HexToken("success", 0x5CC1A5FF), HexToken("hover", 0xFFFFFF0D), HexToken("pressed", 0x00000055),
    HexToken("selection", 0x7DB7D81A), HexToken("shadow", 0x00000080), HexToken("scrollTrack", 0xFFFFFF0F),
    HexToken("scrollThumb", 0x8C9099FF), HexToken("scrollThumbHot", 0xC8CCD4FF), HexToken("gridLine", 0xFFFFFF1A),
    HexToken("mutedHatch", 0xFFFFFF40), HexToken("wireAudio", 0x7DB7D8FF), HexToken("wireSidechain", 0xCC79A7FF),
    HexToken("wireEvent", 0xDA701CFF), HexToken("wireCv", 0x05A076FF), HexToken("trackerBackground", 0x0B0C0EFF),
    HexToken("trackerRowBeat", 0x111317FF), HexToken("trackerRowBar", 0x16181CFF),
    HexToken("trackerCursor", 0x7DB7D8FF), HexToken("trackerPlayhead", 0x1E1718FF),
    HexToken("trackerNote", 0xFFFFFFFF), HexToken("trackerVelocity", 0x6BC7AEFF),
    HexToken("trackerModule", 0xE9AB1FFF), HexToken("trackerEffect", 0xF3E964FF),
    HexToken("trackerParam", 0xB1DCF5FF), HexToken("trackerEmpty", 0xB5B5B5FF),
    HexToken("transportPlayLit", 0x7DB7D8FF), HexToken("transportRecordLit", 0xEB9B95FF),
    HexToken("transportLoopLit", 0xF0E442FF), HexToken("meterLow", 0x5CC1A5FF), HexToken("meterMid", 0xF0E442FF),
    HexToken("meterHigh", 0xEB9B95FF), HexToken("scopeTraceL", 0x7DB7D8FF), HexToken("scopeTraceR", 0xDA701CFF),
    HexToken("categoryCore", 0xF0E442FF), HexToken("categorySynth", 0x7DB7D8FF),
    HexToken("categoryEffect", 0xCC79A7FF), HexToken("categoryControl", 0x05A076FF),
    HexToken("clip0", 0x005B8EFF), HexToken("clip1", 0x914000FF), HexToken("clip2", 0x004C37FF),
    HexToken("clip3", 0x764661FF), HexToken("clip4", 0x5E2900FF), HexToken("clip5", 0x002940FF),
    HexToken("clip6", 0x212121FF), HexToken("clip7", 0x331700FF), HexToken("clipText", 0xFFFFFFFF)
];

/**
 * Returns the built-in palettes, default first.
 *
 * Returns:
 *   "Light · Okabe–Ito", "Light · Tol Bright", "Dark · Okabe–Ito".
 */
PaletteSpec[] builtinPalettes() {
    PaletteSpec[] list;
    list ~= PaletteSpec(DEFAULT_PALETTE, DEFAULT_PALETTE, true, StudioTheme.init);
    list ~= PaletteSpec("Light · Tol Bright", "Light · Tol Bright", true, withTokens(StudioTheme.init, true, TOL_LIGHT));
    list ~= PaletteSpec("Dark · Okabe–Ito", "Dark · Okabe–Ito", true, withTokens(StudioTheme.init, false, DARK_OKABE_ITO));
    return list;
}

/**
 * Looks up a palette by name among the built-ins and the settings' custom palettes.
 *
 * Params:
 *   s = Settings.
 *   name = Palette name.
 *   outSpec = Receives the palette.
 *
 * Returns:
 *   False when no palette has that name.
 */
bool findPalette(const ref AppearanceSettings s, const(char)[] name, out PaletteSpec outSpec) {
    foreach (p; builtinPalettes()) {
        if (p.name == name) {
            outSpec = p;
            return true;
        }
    }
    foreach (ref p; s.customPalettes) {
        if (p.name == name) {
            outSpec = PaletteSpec(p.name, p.origin, false, p.colors);
            return true;
        }
    }
    return false;
}

/**
 * Builds a theme from a palette and contrast mode; every size metric comes from StudioTheme.init.
 *
 * Params:
 *   spec = Palette.
 *   mode = Contrast mode.
 *
 * Returns:
 *   Theme.
 */
StudioTheme makeTheme(const ref PaletteSpec spec, ContrastMode mode) {
    StudioTheme t = StudioTheme.init;
    static foreach (i, n; THEME_COLOR_TOKENS) {
        __traits(getMember, t, n) = __traits(getMember, spec.colors, n);
    }
    t.isLight = spec.colors.isLight;
    t.contrast = mode;
    t.paletteName = composeDisplayName(spec.name, mode);
    if (mode == ContrastMode.low) {
        soften(t);
    }
    t.textGamma = t.isLight ? (mode == ContrastMode.high ? 0.80f : 0.88f) : (mode == ContrastMode.high ? 0.95f : 1.0f);
    return t;
}

/**
 * Builds the theme selected by settings (falls back to the default palette when the name is unknown).
 *
 * Params:
 *   s = Settings.
 *
 * Returns:
 *   Theme.
 */
StudioTheme themeFor(const ref AppearanceSettings s) {
    PaletteSpec p;
    if (!findPalette(s, s.palette, p)) {
        p = builtinPalettes()[0];
    }
    return makeTheme(p, s.contrast);
}

private string composeDisplayName(string name, ContrastMode mode) {
    immutable string level = mode == ContrastMode.high ? "High Contrast" : "Low Contrast";
    foreach (prefix; ["Light · ", "Dark · "]) {
        if (name.length > prefix.length && name[0 .. prefix.length] == prefix) {
            return prefix ~ level ~ " · " ~ name[prefix.length .. $];
        }
    }
    return name ~ " · " ~ level;
}

private enum string[] SOFT_SURFACES = ["background", "panel", "panelRaised", "panelSunken", "trackerBackground",
        "trackerRowBeat", "trackerRowBar", "trackerPlayhead"];
private enum string[] SOFT_TEXT = ["text", "textDim", "textDisabled", "trackerEmpty"];
private enum string[] SOFT_LINES = ["border", "borderStrong", "scrollThumb", "scrollThumbHot"];

private void soften(ref StudioTheme t) {
    static foreach (n; SOFT_SURFACES) {
        __traits(getMember, t, n) = t.isLight ? ColorRGBA(__traits(getMember, t, n).r * 0.969f,
                __traits(getMember, t, n).g * 0.969f, __traits(getMember, t, n).b * 0.961f, __traits(getMember, t, n).a)
            : __traits(getMember, t, n).lerp(ColorRGBA(1, 1, 1, 1), 0.045f).withAlpha(__traits(getMember, t, n).a);
    }
    t.gridLine = t.gridLine.withAlpha(t.gridLine.a * 0.75f);
    StudioTheme hc = t;
    static foreach (n; SOFT_TEXT) {
        softenToken(t, hc, n, 0.17f);
    }
    static foreach (n; SOFT_LINES) {
        softenToken(t, hc, n, 0.30f);
    }
}

private void softenToken(ref StudioTheme t, const ref StudioTheme hc, string name, float maxT) {
    immutable ptrdiff_t idx = colorTokenIndex(name);
    if (idx < 0) {
        return;
    }
    immutable ColorRGBA original = colorToken(hc, cast(size_t) idx);
    immutable ColorRGBA target = t.background;
    float lo = 0.0f;
    float hi = maxT;
    foreach (step; 0 .. 14) {
        immutable float mid = step == 0 ? maxT : (lo + hi) * 0.5f;
        setColorToken(t, cast(size_t) idx, original.lerp(target, mid).withAlpha(original.a));
        if (tokenMeetsFloor(t, name, 0.15f)) {
            if (step == 0) {
                return;
            }
            lo = mid;
        } else {
            hi = mid;
        }
    }
    setColorToken(t, cast(size_t) idx, original.lerp(target, lo).withAlpha(original.a));
}

private bool tokenMeetsFloor(const ref StudioTheme t, string name, float margin) {
    immutable float tf = textFloor(t.contrast) + margin;
    immutable float gf = graphicFloor(t.contrast) + margin;
    foreach (ref p; usedTextPairs(t)) {
        if (p.fg == name && contrastRatio(p.fgColor, p.bgColor) < tf) {
            return false;
        }
    }
    foreach (ref p; usedGraphicPairs(t)) {
        if (p.fg == name && contrastRatio(p.fgColor, p.bgColor) < gf) {
            return false;
        }
    }
    return true;
}

/**
 * Returns the minimum text contrast ratio for a mode.
 *
 * Params:
 *   mode = Contrast mode.
 *
 * Returns:
 *   7.0 (high) or 4.5 (low).
 */
float textFloor(ContrastMode mode) @safe nothrow pure @nogc {
    return mode == ContrastMode.high ? 7.0f : 4.5f;
}

/**
 * Returns the minimum non-text graphics contrast ratio for a mode.
 *
 * Params:
 *   mode = Contrast mode.
 *
 * Returns:
 *   4.5 (high) or 3.0 (low).
 */
float graphicFloor(ContrastMode mode) @safe nothrow pure @nogc {
    return mode == ContrastMode.high ? 4.5f : 3.0f;
}

/**
 * Composites a (possibly translucent) color over an opaque base.
 *
 * Params:
 *   top = Overlay color.
 *   base = Base color (its alpha is ignored).
 *
 * Returns:
 *   Opaque result.
 */
ColorRGBA compositeOver(ColorRGBA top, ColorRGBA base) @safe nothrow pure @nogc {
    immutable float a = top.a < 0.0f ? 0.0f : (top.a > 1.0f ? 1.0f : top.a);
    return ColorRGBA(base.r + (top.r - base.r) * a, base.g + (top.g - base.g) * a, base.b + (top.b - base.b) * a, 1.0f);
}

private float linearize(float v) @safe nothrow pure @nogc {
    immutable float c = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
    return c <= 0.04045f ? c / 12.92f : cast(float) pow((c + 0.055) / 1.055, 2.4);
}

private float encodeSrgb(float v) @safe nothrow pure @nogc {
    immutable float c = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
    return c <= 0.0031308f ? c * 12.92f : cast(float)(1.055 * pow(c, 1.0 / 2.4) - 0.055);
}

/**
 * Returns the WCAG 2.x relative luminance of an sRGB color (alpha ignored).
 *
 * Params:
 *   c = Color.
 *
 * Returns:
 *   Luminance in [0, 1].
 */
float relativeLuminance(ColorRGBA c) @safe nothrow pure @nogc {
    return 0.2126f * linearize(c.r) + 0.7152f * linearize(c.g) + 0.0722f * linearize(c.b);
}

/**
 * Returns the WCAG contrast ratio of fg drawn on bg (a translucent fg is composited over bg first).
 *
 * Params:
 *   fg = Foreground color.
 *   bg = Opaque background color.
 *
 * Returns:
 *   Ratio in [1, 21].
 */
float contrastRatio(ColorRGBA fg, ColorRGBA bg) @safe nothrow pure @nogc {
    immutable ColorRGBA b = bg.withAlpha(1.0f);
    immutable ColorRGBA f = fg.a < 1.0f ? compositeOver(fg, b) : fg;
    immutable float l1 = relativeLuminance(f);
    immutable float l2 = relativeLuminance(b);
    return l1 > l2 ? (l1 + 0.05f) / (l2 + 0.05f) : (l2 + 0.05f) / (l1 + 0.05f);
}

private ColorRGBA tok(const ref StudioTheme t, string name) {
    return colorToken(t, cast(size_t) colorTokenIndex(name));
}

/**
 * Lists every text/background pair the UI draws, with backgrounds resolved through their actual tints.
 *
 * Params:
 *   t = Theme.
 *
 * Returns:
 *   Pairs (bg names use "+" for overlays composited bottom to top).
 */
ContrastPair[] usedTextPairs(const ref StudioTheme t) {
    ContrastPair[] out_;
    void add(string fg, string bg, ColorRGBA bgc) {
        out_ ~= ContrastPair(fg, bg, tok(t, fg), bgc, true);
    }
    static immutable string[] surfaces = ["background", "panel", "panelRaised", "panelSunken"];
    static immutable string[] surfaceText = ["text", "textDim", "textDisabled", "accent", "accentHot", "danger",
        "warning", "success"];
    foreach (s; surfaces) {
        immutable ColorRGBA sc = tok(t, s);
        foreach (f; surfaceText) {
            add(f, s, sc);
        }
        foreach (f; ["text", "textDim"]) {
            add(f, s ~ "+hover", compositeOver(t.hover, sc));
            add(f, s ~ "+selection", compositeOver(t.selection, sc));
        }
        add("text", s ~ "+pressed", compositeOver(t.pressed, sc));
        add("text", s ~ "+emphasize", t.emphasize(sc, 0.06f));
    }
    static immutable string[] filled = ["accent", "accentHot", "danger", "warning", "success", "transportPlayLit",
        "transportRecordLit", "transportLoopLit"];
    foreach (f; filled) {
        immutable ColorRGBA fc = tok(t, f);
        add("accentText", f, fc);
        add("accentText", f ~ "+emphasize", t.emphasize(fc, 0.08f));
    }
    static immutable string[] trackerText = ["trackerNote", "trackerVelocity", "trackerModule", "trackerEffect",
        "trackerParam", "trackerEmpty", "text", "textDim"];
    foreach (ri; 0 .. 5) {
        static immutable string[5] rowNames = ["trackerBackground", "trackerRowBeat", "trackerRowBar",
            "trackerPlayhead", "trackerBackground+hover"];
        immutable ColorRGBA rc = ri == 4 ? compositeOver(t.hover, t.trackerBackground) : tok(t, rowNames[ri]);
        foreach (sel; 0 .. 2) {
            immutable ColorRGBA bc = sel == 1 ? compositeOver(t.selection, rc) : rc;
            immutable string bn = rowNames[ri] ~ (sel == 1 ? "+selection" : "");
            foreach (f; trackerText) {
                add(f, bn, bc);
            }
        }
    }
    foreach (i; 0 .. 8) {
        static immutable string[8] clips = ["clip0", "clip1", "clip2", "clip3", "clip4", "clip5", "clip6", "clip7"];
        immutable ColorRGBA cc = tok(t, clips[i]);
        add("clipText", clips[i], cc);
        add("clipText", clips[i] ~ "+dimmed", cc.lerp(t.panelSunken, 0.65f).withAlpha(1.0f));
    }
    foreach (c; ["categoryCore", "categorySynth", "categoryEffect", "categoryControl"]) {
        immutable ColorRGBA tint = compositeOver(tok(t, c).withAlpha(t.categoryTint(false)), t.panelRaised);
        add("text", c ~ "+tint+panelRaised", tint);
        add("textDim", c ~ "+tint+panelRaised", tint);
    }
    add("text", "categoryCore+outputTint+panelRaised",
        compositeOver(t.categoryCore.withAlpha(t.categoryTint(true)), t.panelRaised));
    add("textDim", "trackerBackground", t.trackerBackground);
    add("pianoKeyText", "pianoWhiteKey", t.pianoWhiteKey);
    return out_;
}

/**
 * Lists every non-text graphic/background pair (wires, borders, focus rings, meters, port glyphs, outlines).
 *
 * Params:
 *   t = Theme.
 *
 * Returns:
 *   Pairs.
 */
ContrastPair[] usedGraphicPairs(const ref StudioTheme t) {
    ContrastPair[] out_;
    void add(string fg, string bg, ColorRGBA bgc) {
        out_ ~= ContrastPair(fg, bg, tok(t, fg), bgc, false);
    }
    foreach (s; ["background", "panel", "panelRaised", "panelSunken"]) {
        immutable ColorRGBA sc = tok(t, s);
        foreach (f; ["border", "borderStrong", "focusRing", "accent"]) {
            add(f, s, sc);
        }
    }
    foreach (w; ["wireAudio", "wireSidechain", "wireEvent", "wireCv"]) {
        add(w, "panelSunken", t.panelSunken);
        add(w, "panelRaised", t.panelRaised);
    }
    foreach (rname; ["trackerBackground", "trackerRowBeat", "trackerRowBar", "trackerPlayhead"]) {
        immutable ColorRGBA rc = tok(t, rname);
        add("trackerCursor", rname, rc);
        add("accent", rname, rc);
        add("danger", rname, rc);
        add("trackerCursor", rname ~ "+selection", compositeOver(t.selection, rc));
    }
    foreach (m; ["meterLow", "meterMid", "meterHigh", "danger"]) {
        add(m, "panelSunken", t.panelSunken);
    }
    add("scopeTraceL", "trackerBackground", t.trackerBackground);
    add("scopeTraceR", "trackerBackground", t.trackerBackground);
    foreach (c; ["categoryCore", "categorySynth", "categoryEffect", "categoryControl"]) {
        add(c, "panelRaised", t.panelRaised);
    }
    add("scrollThumb", "panel+scrollTrack", compositeOver(t.scrollTrack, t.panel));
    add("borderStrong", "clip", t.clip0);
    add("pianoKeyBorder", "pianoWhiteKey", t.pianoWhiteKey);
    add("pianoBlackKey", "pianoWhiteKey", t.pianoWhiteKey);
    return out_;
}

/**
 * Returns every pair below its floor for the theme's contrast mode.
 *
 * Params:
 *   t = Theme.
 *
 * Returns:
 *   Failing pairs.
 */
ContrastPair[] contrastFailures(const ref StudioTheme t) {
    ContrastPair[] bad;
    immutable float tf = textFloor(t.contrast);
    immutable float gf = graphicFloor(t.contrast);
    foreach (ref p; usedTextPairs(t)) {
        if (contrastRatio(p.fgColor, p.bgColor) < tf) bad ~= p;
    }
    foreach (ref p; usedGraphicPairs(t)) {
        if (contrastRatio(p.fgColor, p.bgColor) < gf) bad ~= p;
    }
    return bad;
}

/**
 * Returns the categorical color sets that must stay distinguishable, with their non-color cues.
 *
 * Returns:
 *   Wire kinds, tracker fields, module categories, clip colors, scope traces.
 */
CategoricalSet[] categoricalSets() {
    return [
        CategoricalSet("wire kinds", "port glyph shape + wire dash pattern",
            ["wireAudio", "wireSidechain", "wireEvent", "wireCv"]),
        CategoricalSet("tracker fields", "fixed column position",
            ["trackerNote", "trackerVelocity", "trackerModule", "trackerEffect", "trackerParam"]),
        CategoricalSet("module categories", "category name under the node title",
            ["categoryCore", "categorySynth", "categoryEffect", "categoryControl"]),
        CategoricalSet("clip colors", "pattern letter label + stripe pattern",
            ["clip0", "clip1", "clip2", "clip3", "clip4", "clip5", "clip6", "clip7"]),
        CategoricalSet("scope traces", "L/R captions", ["scopeTraceL", "scopeTraceR"])
    ];
}

/**
 * Returns the smallest CIEDE2000 difference between any two colors of a set under normal vision and every
 * simulated deficiency.
 *
 * Params:
 *   t = Theme.
 *   set = Categorical set.
 *   worstA = Receives the first token of the closest pair.
 *   worstB = Receives the second token.
 *   worstCvd = Receives the simulation where it occurred.
 *
 * Returns:
 *   Minimum ΔE00.
 */
float minCategoricalDeltaE(const ref StudioTheme t, const ref CategoricalSet set, out string worstA,
        out string worstB, out CvdType worstCvd) {
    float best = float.max;
    foreach (k; [CvdType.none, CvdType.protanopia, CvdType.deuteranopia, CvdType.tritanopia]) {
        foreach (i; 0 .. set.tokens.length) {
            foreach (j; i + 1 .. set.tokens.length) {
                immutable float d = deltaE2000(simulateCvd(tok(t, set.tokens[i]), k), simulateCvd(tok(t, set.tokens[j]), k));
                if (d < best) {
                    best = d;
                    worstA = set.tokens[i];
                    worstB = set.tokens[j];
                    worstCvd = k;
                }
            }
        }
    }
    return best;
}

private immutable float[9][4] MACHADO = [
    [1, 0, 0, 0, 1, 0, 0, 0, 1],
    [0.152286f, 1.052583f, -0.204868f, 0.114503f, 0.786281f, 0.099216f, -0.003882f, -0.048116f, 1.051998f],
    [0.367322f, 0.860646f, -0.227968f, 0.280085f, 0.672501f, 0.047413f, -0.011820f, 0.042940f, 0.968881f],
    [1.255528f, -0.076749f, -0.178779f, -0.078411f, 0.930809f, 0.147602f, 0.004733f, 0.691367f, 0.303900f]
];

/**
 * Simulates how a color appears under a full-severity color-vision deficiency (Machado 2009, linear RGB).
 *
 * Params:
 *   c = sRGB color.
 *   type = Deficiency (none returns c).
 *
 * Returns:
 *   Simulated sRGB color (alpha preserved).
 */
ColorRGBA simulateCvd(ColorRGBA c, CvdType type) @safe nothrow pure @nogc {
    if (type == CvdType.none) {
        return c;
    }
    immutable float[9] m = MACHADO[type];
    immutable float r = linearize(c.r);
    immutable float g = linearize(c.g);
    immutable float b = linearize(c.b);
    return ColorRGBA(encodeSrgb(m[0] * r + m[1] * g + m[2] * b), encodeSrgb(m[3] * r + m[4] * g + m[5] * b),
        encodeSrgb(m[6] * r + m[7] * g + m[8] * b), c.a);
}

private void toLab(ColorRGBA c, out double l, out double a, out double b) @safe nothrow pure @nogc {
    immutable double r = linearize(c.r);
    immutable double g = linearize(c.g);
    immutable double bl = linearize(c.b);
    immutable double x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * bl) / 0.95047;
    immutable double y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * bl;
    immutable double z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * bl) / 1.08883;
    static double f(double v) @safe nothrow pure @nogc {
        return v > 216.0 / 24389.0 ? pow(v, 1.0 / 3.0) : (24389.0 / 27.0 * v + 16.0) / 116.0;
    }
    immutable double fx = f(x);
    immutable double fy = f(y);
    immutable double fz = f(z);
    l = 116.0 * fy - 16.0;
    a = 500.0 * (fx - fy);
    b = 200.0 * (fy - fz);
}

/**
 * Returns the CIEDE2000 color difference of two sRGB colors (D65, kL = kC = kH = 1).
 *
 * Params:
 *   c1 = First color.
 *   c2 = Second color.
 *
 * Returns:
 *   ΔE00.
 */
float deltaE2000(ColorRGBA c1, ColorRGBA c2) @safe nothrow pure @nogc {
    double l1, a1, b1, l2, a2, b2;
    toLab(c1, l1, a1, b1);
    toLab(c2, l2, a2, b2);
    enum double deg = 180.0 / PI;
    immutable double cAb1 = sqrt(a1 * a1 + b1 * b1);
    immutable double cAb2 = sqrt(a2 * a2 + b2 * b2);
    immutable double cBar = (cAb1 + cAb2) / 2.0;
    immutable double c7 = pow(cBar, 7.0);
    immutable double g = 0.5 * (1.0 - sqrt(c7 / (c7 + pow(25.0, 7.0))));
    immutable double a1p = (1.0 + g) * a1;
    immutable double a2p = (1.0 + g) * a2;
    immutable double c1p = sqrt(a1p * a1p + b1 * b1);
    immutable double c2p = sqrt(a2p * a2p + b2 * b2);
    double hue(double bb, double ap) @safe nothrow pure @nogc {
        if (bb == 0.0 && ap == 0.0) return 0.0;
        double h = atan2(bb, ap) * deg;
        return h < 0.0 ? h + 360.0 : h;
    }
    immutable double h1p = hue(b1, a1p);
    immutable double h2p = hue(b2, a2p);
    immutable double dLp = l2 - l1;
    immutable double dCp = c2p - c1p;
    double dhp = 0.0;
    if (c1p * c2p != 0.0) {
        dhp = h2p - h1p;
        if (dhp > 180.0) dhp -= 360.0;
        else if (dhp < -180.0) dhp += 360.0;
    }
    immutable double dHp = 2.0 * sqrt(c1p * c2p) * sin(dhp / 2.0 / deg);
    immutable double lBarP = (l1 + l2) / 2.0;
    immutable double cBarP = (c1p + c2p) / 2.0;
    double hBarP = h1p + h2p;
    if (c1p * c2p != 0.0) {
        if (fabs(h1p - h2p) <= 180.0) hBarP = (h1p + h2p) / 2.0;
        else if (h1p + h2p < 360.0) hBarP = (h1p + h2p + 360.0) / 2.0;
        else hBarP = (h1p + h2p - 360.0) / 2.0;
    }
    immutable double tt = 1.0 - 0.17 * cos((hBarP - 30.0) / deg) + 0.24 * cos((2.0 * hBarP) / deg)
        + 0.32 * cos((3.0 * hBarP + 6.0) / deg) - 0.20 * cos((4.0 * hBarP - 63.0) / deg);
    immutable double dTheta = 30.0 * exp(-((hBarP - 275.0) / 25.0) * ((hBarP - 275.0) / 25.0));
    immutable double cp7 = pow(cBarP, 7.0);
    immutable double rc = 2.0 * sqrt(cp7 / (cp7 + pow(25.0, 7.0)));
    immutable double lm = (lBarP - 50.0) * (lBarP - 50.0);
    immutable double sl = 1.0 + 0.015 * lm / sqrt(20.0 + lm);
    immutable double sc = 1.0 + 0.045 * cBarP;
    immutable double sh = 1.0 + 0.015 * cBarP * tt;
    immutable double rt = -sin(2.0 * dTheta / deg) * rc;
    immutable double x = dLp / sl;
    immutable double y = dCp / sc;
    immutable double z = dHp / sh;
    return cast(float) sqrt(x * x + y * y + z * z + rt * y * z);
}

private bool isCleanText(const(char)[] s, size_t maxLen) @safe nothrow pure @nogc {
    if (s.length == 0 || s.length > maxLen) {
        return false;
    }
    size_t i = 0;
    while (i < s.length) {
        immutable size_t start = i;
        dchar cp;
        decodeUtf8(s, i, cp);
        if (cp == 0xFFFD && !(i - start == 3 && s[start] == 0xEF && s[start + 1] == 0xBF && s[start + 2] == 0xBD)) {
            return false;
        }
        if (cp < 0x20 || cp == 0x7F || (cp >= 0x80 && cp < 0xA0) || cp == 0x2028 || cp == 0x2029) {
            return false;
        }
    }
    return s[0] != ' ' && s[$ - 1] != ' ';
}

private bool parseHex8(const(char)[] s, out uint v) @safe nothrow pure @nogc {
    if (s.length != 8) {
        return false;
    }
    uint acc = 0;
    foreach (ch; s) {
        uint d;
        if (ch >= '0' && ch <= '9') d = ch - '0';
        else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
        else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
        else return false;
        acc = (acc << 4) | d;
    }
    v = acc;
    return true;
}

private string hex8(ColorRGBA c) @safe pure {
    static immutable char[16] digits = "0123456789ABCDEF";
    char[8] buf;
    immutable float[4] ch = [c.r, c.g, c.b, c.a];
    foreach (i, v; ch) {
        immutable float cl = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
        immutable uint b = cast(uint)(cl * 255.0f + 0.5f);
        buf[i * 2] = digits[b >> 4];
        buf[i * 2 + 1] = digits[b & 15];
    }
    return buf.idup;
}

private struct LineReader {
    const(char)[] text;
    size_t pos = 0;
    size_t lineNo = 0;

    bool next(out const(char)[] line) @safe nothrow pure @nogc {
        while (pos < text.length) {
            size_t end = pos;
            while (end < text.length && text[end] != '\n') {
                end++;
            }
            line = text[pos .. end];
            pos = end < text.length ? end + 1 : end;
            lineNo++;
            if (line.length > 0 && line[$ - 1] == '\r') {
                line = line[0 .. $ - 1];
            }
            if (line.length > 0) {
                return true;
            }
        }
        return false;
    }
}

private bool splitKey(const(char)[] line, out const(char)[] key, out const(char)[] value) @safe nothrow pure @nogc {
    foreach (i, ch; line) {
        if (ch == '=') {
            key = line[0 .. i];
            value = line[i + 1 .. $];
            return key.length > 0;
        }
    }
    return false;
}

private bool isBuiltinName(const(char)[] name) {
    foreach (p; builtinPalettes()) {
        if (p.name == name) return true;
    }
    return false;
}

private string paletteBody(const ref PaletteSpec p) {
    string s = "name=" ~ p.name ~ "\n";
    s ~= "origin=" ~ (p.origin.length > 0 ? p.origin : DEFAULT_PALETTE) ~ "\n";
    s ~= "light=" ~ (p.colors.isLight ? "1" : "0") ~ "\n";
    static foreach (n; THEME_COLOR_TOKENS) {
        s ~= n ~ "=" ~ hex8(__traits(getMember, p.colors, n)) ~ "\n";
    }
    return s;
}

/**
 * Serializes appearance settings to the versioned key=value text format.
 *
 * Params:
 *   s = Settings.
 *
 * Returns:
 *   Text.
 */
string encodeAppearance(const ref AppearanceSettings s) {
    import std.conv : to;

    string o = "dracker-appearance " ~ to!string(APPEARANCE_FORMAT_VERSION) ~ "\n";
    o ~= "ui_font=" ~ s.uiFont ~ "\n";
    o ~= "mono_font=" ~ s.monoFont ~ "\n";
    o ~= "contrast=" ~ (s.contrast == ContrastMode.high ? "high" : "low") ~ "\n";
    o ~= "palette=" ~ s.palette ~ "\n";
    foreach (ref p; s.customPalettes) {
        o ~= "[palette]\n" ~ paletteBody(p) ~ "[end]\n";
    }
    return o;
}

private bool parsePaletteBody(ref LineReader rd, bool block, out PaletteSpec p, out string err) {
    bool[THEME_COLOR_TOKENS.length] seen;
    bool haveName = false;
    bool haveOrigin = false;
    bool haveLight = false;
    bool ended = false;
    const(char)[] line;
    while (rd.next(line)) {
        if (block && line == "[end]") {
            ended = true;
            break;
        }
        const(char)[] key;
        const(char)[] value;
        if (!splitKey(line, key, value)) {
            err = "malformed palette line";
            return false;
        }
        if (key == "name") {
            if (haveName || !isCleanText(value, MAX_PALETTE_NAME)) {
                err = "bad palette name";
                return false;
            }
            p.name = value.idup;
            haveName = true;
        } else if (key == "origin") {
            if (haveOrigin || !isBuiltinName(value)) {
                err = "bad palette origin";
                return false;
            }
            p.origin = value.idup;
            haveOrigin = true;
        } else if (key == "light") {
            if (haveLight || (value != "0" && value != "1")) {
                err = "bad light flag";
                return false;
            }
            p.colors.isLight = value == "1";
            haveLight = true;
        } else {
            immutable ptrdiff_t idx = colorTokenIndex(key);
            uint rgba;
            if (idx < 0) {
                err = "unknown palette token";
                return false;
            }
            if (seen[idx] || !parseHex8(value, rgba)) {
                err = "bad color value";
                return false;
            }
            seen[idx] = true;
            setColorToken(p.colors, cast(size_t) idx, ColorRGBA.fromHex(rgba));
        }
    }
    if (!haveName || !haveOrigin || !haveLight || (block && !ended)) {
        err = "incomplete palette";
        return false;
    }
    foreach (b; seen) {
        if (!b) {
            err = "missing palette token";
            return false;
        }
    }
    p.builtin = false;
    return true;
}

private bool parseVersionLine(const(char)[] line, string magic, uint expected) @safe nothrow pure @nogc {
    if (line.length != magic.length + 2 || line[0 .. magic.length] != magic || line[magic.length] != ' ') {
        return false;
    }
    immutable char d = line[$ - 1];
    return d >= '0' && d <= '9' && cast(uint)(d - '0') == expected;
}

/**
 * Parses appearance settings strictly; any defect rejects the whole input and leaves defaults.
 *
 * Params:
 *   text = Settings text.
 *   s = Receives the settings (defaults on failure).
 *   err = Receives a diagnostic on failure.
 *
 * Returns:
 *   True on success.
 */
bool decodeAppearance(const(char)[] text, out AppearanceSettings s, out string err) nothrow {
    try {
        return decodeAppearanceImpl(text, s, err);
    } catch (Exception e) {
        s = AppearanceSettings.init;
        err = "settings parse failure";
        return false;
    }
}

private bool decodeAppearanceImpl(const(char)[] text, out AppearanceSettings s, out string err) {
    s = AppearanceSettings.init;
    if (text.length > MAX_APPEARANCE_BYTES) {
        err = "settings too large";
        return false;
    }
    LineReader rd = LineReader(text);
    const(char)[] line;
    if (!rd.next(line) || !parseVersionLine(line, "dracker-appearance", APPEARANCE_FORMAT_VERSION)) {
        err = "unsupported settings version";
        return false;
    }
    AppearanceSettings r;
    bool haveUi, haveMono, haveContrast, havePalette;
    while (rd.next(line)) {
        if (line == "[palette]") {
            if (r.customPalettes.length >= MAX_CUSTOM_PALETTES) {
                err = "too many custom palettes";
                return false;
            }
            PaletteSpec p;
            if (!parsePaletteBody(rd, true, p, err)) {
                return false;
            }
            if (isBuiltinName(p.name)) {
                err = "custom palette shadows a built-in name";
                return false;
            }
            foreach (ref q; r.customPalettes) {
                if (q.name == p.name) {
                    err = "duplicate custom palette name";
                    return false;
                }
            }
            r.customPalettes ~= p;
            continue;
        }
        const(char)[] key;
        const(char)[] value;
        if (!splitKey(line, key, value)) {
            err = "malformed settings line";
            return false;
        }
        if (key == "ui_font" && !haveUi && isCleanText(value, MAX_FONT_NAME)) {
            r.uiFont = value.idup;
            haveUi = true;
        } else if (key == "mono_font" && !haveMono && isCleanText(value, MAX_FONT_NAME)) {
            r.monoFont = value.idup;
            haveMono = true;
        } else if (key == "contrast" && !haveContrast && (value == "high" || value == "low")) {
            r.contrast = value == "high" ? ContrastMode.high : ContrastMode.low;
            haveContrast = true;
        } else if (key == "palette" && !havePalette && isCleanText(value, MAX_PALETTE_NAME)) {
            r.palette = value.idup;
            havePalette = true;
        } else {
            err = "invalid settings key or value";
            return false;
        }
    }
    if (!haveUi || !haveMono || !haveContrast || !havePalette) {
        err = "incomplete settings";
        return false;
    }
    PaletteSpec found;
    if (!findPalette(r, r.palette, found)) {
        err = "selected palette does not exist";
        return false;
    }
    s = r;
    return true;
}

/**
 * Serializes one palette to the .stpalette format.
 *
 * Params:
 *   p = Palette.
 *
 * Returns:
 *   Text.
 */
string encodePalette(const ref PaletteSpec p) {
    import std.conv : to;

    return "dracker-palette " ~ to!string(PALETTE_FORMAT_VERSION) ~ "\n" ~ paletteBody(p);
}

/**
 * Parses a .stpalette file strictly.
 *
 * Params:
 *   text = File text.
 *   p = Receives the palette (marked custom).
 *   err = Receives a diagnostic on failure.
 *
 * Returns:
 *   True on success.
 */
bool decodePalette(const(char)[] text, out PaletteSpec p, out string err) nothrow {
    try {
        if (text.length > MAX_APPEARANCE_BYTES) {
            err = "palette too large";
            return false;
        }
        LineReader rd = LineReader(text);
        const(char)[] line;
        if (!rd.next(line) || !parseVersionLine(line, "dracker-palette", PALETTE_FORMAT_VERSION)) {
            err = "unsupported palette version";
            return false;
        }
        return parsePaletteBody(rd, false, p, err);
    } catch (Exception e) {
        p = PaletteSpec.init;
        err = "palette parse failure";
        return false;
    }
}

private string nextCustomName(const ref AppearanceSettings s, uint after = 0) {
    import std.conv : to;

    for (uint n = after + 1; ; n++) {
        immutable string candidate = "Custom " ~ to!string(n);
        bool used = false;
        foreach (ref p; s.customPalettes) {
            if (p.name == candidate) used = true;
        }
        if (!used) return candidate;
    }
}

private ptrdiff_t customIndex(const ref AppearanceSettings s, const(char)[] name) {
    foreach (i, ref p; s.customPalettes) {
        if (p.name == name) return i;
    }
    return -1;
}

/**
 * Adds a custom copy of a palette and selects it.
 *
 * Params:
 *   s = Settings to modify.
 *   sourceName = Built-in or custom palette to copy.
 *
 * Returns:
 *   The new palette name, or null when the source is unknown or the custom limit is reached.
 */
string duplicateAsCustom(ref AppearanceSettings s, const(char)[] sourceName) {
    PaletteSpec src;
    if (s.customPalettes.length >= MAX_CUSTOM_PALETTES || !findPalette(s, sourceName, src)) {
        return null;
    }
    PaletteSpec c = src;
    c.name = nextCustomName(s);
    c.origin = src.builtin ? src.name : (src.origin.length > 0 ? src.origin : DEFAULT_PALETTE);
    c.builtin = false;
    s.customPalettes ~= c;
    s.palette = c.name;
    return c.name;
}

/**
 * Renames a custom palette to the next free numbered name ("Custom N", N greater than its current number).
 *
 * Params:
 *   s = Settings to modify.
 *   name = Custom palette name.
 *
 * Returns:
 *   New name, or null when name is not a custom palette.
 */
string renameCustomNext(ref AppearanceSettings s, const(char)[] name) {
    import std.conv : to;

    immutable ptrdiff_t i = customIndex(s, name);
    if (i < 0) {
        return null;
    }
    uint current = 0;
    enum string prefix = "Custom ";
    if (name.length > prefix.length && name[0 .. prefix.length] == prefix) {
        foreach (ch; name[prefix.length .. $]) {
            if (ch < '0' || ch > '9' || current > 100_000) {
                current = 0;
                break;
            }
            current = current * 10 + (ch - '0');
        }
    }
    immutable string nn = nextCustomName(s, current);
    immutable bool selected = s.palette == name;
    s.customPalettes[i].name = nn;
    if (selected) {
        s.palette = nn;
    }
    return nn;
}

/**
 * Deletes a custom palette (selecting the default palette if it was selected).
 *
 * Params:
 *   s = Settings to modify.
 *   name = Custom palette name.
 *
 * Returns:
 *   False when name is not a custom palette.
 */
bool deleteCustom(ref AppearanceSettings s, const(char)[] name) {
    immutable ptrdiff_t i = customIndex(s, name);
    if (i < 0) {
        return false;
    }
    s.customPalettes = s.customPalettes[0 .. i] ~ s.customPalettes[i + 1 .. $];
    if (s.palette == name) {
        s.palette = DEFAULT_PALETTE;
    }
    return true;
}

/**
 * Restores a custom palette's colors from the built-in palette it was copied from.
 *
 * Params:
 *   s = Settings to modify.
 *   name = Custom palette name.
 *
 * Returns:
 *   False when name is not a custom palette.
 */
bool resetCustom(ref AppearanceSettings s, const(char)[] name) {
    immutable ptrdiff_t i = customIndex(s, name);
    if (i < 0) {
        return false;
    }
    foreach (p; builtinPalettes()) {
        if (p.name == s.customPalettes[i].origin) {
            s.customPalettes[i].colors = p.colors;
            return true;
        }
    }
    s.customPalettes[i].colors = builtinPalettes()[0].colors;
    return true;
}

/**
 * Sets one color token of a custom palette.
 *
 * Params:
 *   s = Settings to modify.
 *   name = Custom palette name.
 *   tokenIndex = Index into THEME_COLOR_TOKENS.
 *   c = New color.
 *
 * Returns:
 *   False when name is not a custom palette or the index is out of range.
 */
bool setCustomToken(ref AppearanceSettings s, const(char)[] name, size_t tokenIndex, ColorRGBA c) {
    immutable ptrdiff_t i = customIndex(s, name);
    if (i < 0 || tokenIndex >= THEME_COLOR_TOKENS.length) {
        return false;
    }
    setColorToken(s.customPalettes[i].colors, tokenIndex, c);
    if (THEME_COLOR_TOKENS[tokenIndex] == "background") {
        s.customPalettes[i].colors.isLight = relativeLuminance(c) > 0.18f;
    }
    return true;
}

/**
 * Adds an imported palette as a custom palette (renamed when its name is taken) and selects it.
 *
 * Params:
 *   s = Settings to modify.
 *   p = Decoded palette.
 *
 * Returns:
 *   The stored name, or null when the custom limit is reached.
 */
string addImportedPalette(ref AppearanceSettings s, PaletteSpec p) {
    if (s.customPalettes.length >= MAX_CUSTOM_PALETTES) {
        return null;
    }
    p.builtin = false;
    if (isBuiltinName(p.name) || customIndex(s, p.name) >= 0) {
        p.name = nextCustomName(s);
    }
    s.customPalettes ~= p;
    s.palette = p.name;
    return p.name;
}

/**
 * Named group of color tokens shown together in the custom palette editor.
 */
struct TokenGroup {
    string name;
    string[] tokens;
}

/**
 * Returns the palette editor token groups (every color token appears in exactly one group).
 *
 * Returns:
 *   Groups in display order.
 */
TokenGroup[] tokenGroups() {
    return [
        TokenGroup("Surfaces", ["background", "panel", "panelRaised", "panelSunken", "trackerBackground",
            "trackerRowBeat", "trackerRowBar", "trackerPlayhead"]),
        TokenGroup("Text", ["text", "textDim", "textDisabled", "accentText", "clipText"]),
        TokenGroup("Accent & status", ["accent", "accentHot", "focusRing", "danger", "warning", "success",
            "transportPlayLit", "transportRecordLit", "transportLoopLit", "meterLow", "meterMid", "meterHigh"]),
        TokenGroup("Lines & overlays", ["border", "borderStrong", "gridLine", "hover", "pressed", "selection", "shadow",
            "scrollTrack", "scrollThumb", "scrollThumbHot", "mutedHatch"]),
        TokenGroup("Wires & scope", ["wireAudio", "wireSidechain", "wireEvent", "wireCv", "scopeTraceL", "scopeTraceR"]),
        TokenGroup("Tracker fields", ["trackerCursor", "trackerNote", "trackerVelocity", "trackerModule",
            "trackerEffect", "trackerParam", "trackerEmpty"]),
        TokenGroup("Categories & clips", ["categoryCore", "categorySynth", "categoryEffect", "categoryControl", "clip0",
            "clip1", "clip2", "clip3", "clip4", "clip5", "clip6", "clip7"]),
        TokenGroup("Piano", ["pianoWhiteKey", "pianoBlackKey", "pianoKeyBorder", "pianoKeyText"])
    ];
}

/**
 * One line of the palette editor's live contrast readout.
 */
struct ContrastReading {
    string fg;
    string bg;
    float ratio;
    float required;
    bool isText;

    /**
     * Reports whether the pair meets its floor.
     *
     * Returns:
     *   True when ratio >= required.
     */
    bool passes() const @safe nothrow pure @nogc {
        return ratio >= required;
    }
}

/**
 * Returns every drawn pair involving a token (as foreground or as part of the background), worst first.
 *
 * Params:
 *   t = Theme.
 *   token = Color token name.
 *
 * Returns:
 *   Readings sorted by ratio / required, ascending.
 */
ContrastReading[] contrastReadout(const ref StudioTheme t, string token) {
    import std.algorithm : sort;

    ContrastReading[] out_;
    void scan(ContrastPair[] pairs, float floor) {
        foreach (ref p; pairs) {
            bool involves = p.fg == token;
            if (!involves && p.bg.length >= token.length && p.bg[0 .. token.length] == token) {
                involves = p.bg.length == token.length || p.bg[token.length] == '+' || p.bg[token.length] == '@';
            }
            if (!involves) {
                foreach (k; 0 .. p.bg.length) {
                    if (p.bg[k] == '+' && p.bg.length >= k + 1 + token.length && p.bg[k + 1 .. k + 1 + token.length] == token
                            && (p.bg.length == k + 1 + token.length || p.bg[k + 1 + token.length] == '+')) {
                        involves = true;
                    }
                }
            }
            if (involves) {
                out_ ~= ContrastReading(p.fg, p.bg, contrastRatio(p.fgColor, p.bgColor), floor, p.isText);
            }
        }
    }
    scan(usedTextPairs(t), textFloor(t.contrast));
    scan(usedGraphicPairs(t), graphicFloor(t.contrast));
    sort!((a, b) => a.ratio / a.required < b.ratio / b.required)(out_);
    return out_;
}
