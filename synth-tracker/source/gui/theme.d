/**
 * File:         source/gui/theme.d
 * Module:       gui.theme
 * Phase:        Phase 7.5 — HiDPI Typography, Spacing & Color Tokens
 *
 * Purpose:
 *   Centralizes the studio color palette (surfaces, text, accent/focus/danger states, typed patch-cable wire
 *   colors for audio / sidechain / event / CV ports, tracker column colors), spacing and corner-radius scales,
 *   control metrics, and font sizes. All metrics are logical points; Retina scaling is applied by the renderer.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. StudioTheme is a plain value type; widgets receive it by const reference at draw time and
 *   never mutate it. No global mutable state: StudioTheme.init already equals the dark studio palette.
 *
 * Dependencies:
 *   Internal: gui.renderer (ColorRGBA), graph.port (PortKind)
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum WireKind : ubyte { audio, sidechain, event, cv }
 *   - struct StudioTheme : color tokens, wire colors, tracker column colors, spacing/radius/control metrics, font sizes
 *       static StudioTheme dark(); ColorRGBA wireColor(WireKind) const; ColorRGBA portColor(PortKind) const;
 *       float spacing(uint step) const; StudioTheme scaled(float factor) const
 *   - WireKind wireKindOf(PortKind kind)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.theme;

import gui.renderer : ColorRGBA;
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
 * Complete set of studio design tokens. The default-initialized value is the dark studio theme.
 */
struct StudioTheme {
    ColorRGBA background = ColorRGBA.fromHex(0x16181DFF);
    ColorRGBA panel = ColorRGBA.fromHex(0x1E2128FF);
    ColorRGBA panelRaised = ColorRGBA.fromHex(0x282C35FF);
    ColorRGBA panelSunken = ColorRGBA.fromHex(0x121418FF);
    ColorRGBA border = ColorRGBA.fromHex(0x363B47FF);
    ColorRGBA borderStrong = ColorRGBA.fromHex(0x4A5161FF);
    ColorRGBA text = ColorRGBA.fromHex(0xE3E6EDFF);
    ColorRGBA textDim = ColorRGBA.fromHex(0x8D94A5FF);
    ColorRGBA textDisabled = ColorRGBA.fromHex(0x5A6070FF);
    ColorRGBA accent = ColorRGBA.fromHex(0x3D9BFFFF);
    ColorRGBA accentHot = ColorRGBA.fromHex(0x6FB6FFFF);
    ColorRGBA accentText = ColorRGBA.fromHex(0x0B1220FF);
    ColorRGBA focusRing = ColorRGBA.fromHex(0x5FAEFFCC);
    ColorRGBA danger = ColorRGBA.fromHex(0xE5484DFF);
    ColorRGBA warning = ColorRGBA.fromHex(0xF5A524FF);
    ColorRGBA success = ColorRGBA.fromHex(0x46C37BFF);
    ColorRGBA hover = ColorRGBA.fromHex(0xFFFFFF14);
    ColorRGBA pressed = ColorRGBA.fromHex(0x00000033);
    ColorRGBA selection = ColorRGBA.fromHex(0x3D9BFF55);
    ColorRGBA shadow = ColorRGBA.fromHex(0x00000080);
    ColorRGBA scrollTrack = ColorRGBA.fromHex(0x0000002A);
    ColorRGBA scrollThumb = ColorRGBA.fromHex(0xFFFFFF40);
    ColorRGBA scrollThumbHot = ColorRGBA.fromHex(0xFFFFFF70);
    ColorRGBA gridLine = ColorRGBA.fromHex(0xFFFFFF14);

    ColorRGBA wireAudio = ColorRGBA.fromHex(0x4CC2FFFF);
    ColorRGBA wireSidechain = ColorRGBA.fromHex(0xB07CFFFF);
    ColorRGBA wireEvent = ColorRGBA.fromHex(0xFFB547FF);
    ColorRGBA wireCv = ColorRGBA.fromHex(0x5BD98AFF);

    ColorRGBA trackerBackground = ColorRGBA.fromHex(0x111317FF);
    ColorRGBA trackerRowBeat = ColorRGBA.fromHex(0x1A1D23FF);
    ColorRGBA trackerRowBar = ColorRGBA.fromHex(0x22262EFF);
    ColorRGBA trackerCursor = ColorRGBA.fromHex(0x3D9BFF66);
    ColorRGBA trackerPlayhead = ColorRGBA.fromHex(0xE5484D55);
    ColorRGBA trackerNote = ColorRGBA.fromHex(0xE3E6EDFF);
    ColorRGBA trackerVelocity = ColorRGBA.fromHex(0x5BD98AFF);
    ColorRGBA trackerModule = ColorRGBA.fromHex(0xFFB547FF);
    ColorRGBA trackerEffect = ColorRGBA.fromHex(0xB07CFFFF);
    ColorRGBA trackerParam = ColorRGBA.fromHex(0x4CC2FFFF);
    ColorRGBA trackerEmpty = ColorRGBA.fromHex(0x3A3F4BFF);

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
     * Returns the default dark studio theme.
     *
     * Returns:
     *   Dark palette with default metrics.
     */
    static StudioTheme dark() @safe nothrow pure @nogc {
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
        static foreach (name; ["spacingXs", "spacingSm", "spacingMd", "spacingLg", "spacingXl", "radiusSm",
                "radiusMd", "radiusLg", "borderWidth", "focusRingWidth", "focusRingGap", "fontSizeSmall",
                "fontSizeBody", "fontSizeTitle", "fontSizeMono", "controlHeight", "menuItemHeight",
                "scrollbarThickness", "scrollbarMinThumb", "splitterThickness", "sliderTrackThickness",
                "sliderThumbSize", "knobSize", "knobArcWidth", "curvePointRadius", "curveLineWidth", "wireWidth"]) {
            __traits(getMember, t, name) *= factor;
        }
        return t;
    }
}
