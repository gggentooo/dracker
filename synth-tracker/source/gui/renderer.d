/**
 * File:         source/gui/renderer.d
 * Module:       gui.renderer
 * Phase:        Phase 7.4 — Backend-Agnostic IRenderer2D Abstraction
 *
 * Purpose:
 *   Defines the 2D drawing contract used by every widget (rounded rectangles, borders, vertical gradients,
 *   scissor clipping, anti-aliased polylines/cubic Beziers, glyph and RGBA textured quads) and the
 *   backend-agnostic batching core: BatchRenderer2D records GPU-ready UIInstance structs plus clip/texture
 *   DrawCommand runs into a DrawList, GlyphCache packs rasterized glyphs into a growable R8 atlas through a
 *   ShelfAtlasPacker, and HeadlessRenderer provides a GPU-free backend for tests and offscreen layout.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. All coordinates passed to IRenderer2D are logical points with a top-left origin; the
 *   batcher converts to physical pixels using the frame scale factor. UIInstance layout is mirrored exactly
 *   by shaders/ui2d.metal (96 bytes, float4-aligned).
 *
 * Dependencies:
 *   Internal: None
 *   External: std.math (ceil, floor, sqrt, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Point2F / RectF / ColorRGBA / ScissorRect
 *   - enum FontId / enum InstanceKind / struct UIInstance / struct DrawCommand / struct DrawList
 *   - interface ITextMeasurer / interface IRenderer2D
 *   - struct RasterizedGlyph / interface IGlyphRasterizer / struct AtlasGlyph / struct ShelfAtlasPacker / class GlyphCache
 *   - abstract class BatchRenderer2D : IRenderer2D (submitFrame(), createTexture hooks)
 *   - class HeadlessRenderer : BatchRenderer2D
 *   - size_t decodeUtf8(const(char)[] s, ref size_t index, out dchar cp)
 *
 * See_Also:
 *   architecture.md, dev_plan.md
 */
module gui.renderer;

import std.math : ceil, floor, isFinite, sqrt;

/**
 * Two-dimensional point or vector in logical points.
 */
struct Point2F {
    float x = 0.0f;
    float y = 0.0f;

    @safe nothrow pure @nogc:

    /**
     * Component-wise addition.
     *
     * Params:
     *   o = Offset to add.
     *
     * Returns:
     *   Sum point.
     */
    Point2F opBinary(string op : "+")(Point2F o) const {
        return Point2F(x + o.x, y + o.y);
    }

    /**
     * Component-wise subtraction.
     *
     * Params:
     *   o = Offset to subtract.
     *
     * Returns:
     *   Difference vector.
     */
    Point2F opBinary(string op : "-")(Point2F o) const {
        return Point2F(x - o.x, y - o.y);
    }

    /**
     * Uniform scaling.
     *
     * Params:
     *   s = Scale factor.
     *
     * Returns:
     *   Scaled point.
     */
    Point2F opBinary(string op : "*")(float s) const {
        return Point2F(x * s, y * s);
    }

    /**
     * Euclidean length of this vector.
     *
     * Returns:
     *   Length in logical points.
     */
    float length() const {
        return sqrt(x * x + y * y);
    }
}

/**
 * Axis-aligned rectangle in logical points (top-left origin, y grows downward).
 */
struct RectF {
    float x = 0.0f;
    float y = 0.0f;
    float w = 0.0f;
    float h = 0.0f;

    @safe nothrow pure @nogc:

    /**
     * Returns the right edge coordinate.
     *
     * Returns:
     *   x + w.
     */
    float right() const {
        return x + w;
    }

    /**
     * Returns the bottom edge coordinate.
     *
     * Returns:
     *   y + h.
     */
    float bottom() const {
        return y + h;
    }

    /**
     * Reports whether the rectangle has no positive area.
     *
     * Returns:
     *   True if w <= 0 or h <= 0.
     */
    bool isEmpty() const {
        return !(w > 0.0f) || !(h > 0.0f);
    }

    /**
     * Half-open containment test ([x, x+w) x [y, y+h)).
     *
     * Params:
     *   p = Point to test.
     *
     * Returns:
     *   True if p lies inside.
     */
    bool contains(Point2F p) const {
        return p.x >= x && p.y >= y && p.x < x + w && p.y < y + h;
    }

    /**
     * Intersection with another rectangle.
     *
     * Params:
     *   o = Other rectangle.
     *
     * Returns:
     *   Overlap rectangle, or an empty rectangle at the clamped origin when disjoint.
     */
    RectF intersect(RectF o) const {
        immutable float nx = x > o.x ? x : o.x;
        immutable float ny = y > o.y ? y : o.y;
        immutable float nr = right() < o.right() ? right() : o.right();
        immutable float nb = bottom() < o.bottom() ? bottom() : o.bottom();
        return RectF(nx, ny, nr > nx ? nr - nx : 0.0f, nb > ny ? nb - ny : 0.0f);
    }

    /**
     * Shrinks (positive d) or grows (negative d) the rectangle on every side.
     *
     * Params:
     *   d = Inset distance in logical points.
     *
     * Returns:
     *   Inset rectangle with non-negative size.
     */
    RectF inset(float d) const {
        immutable float nw = w - 2.0f * d;
        immutable float nh = h - 2.0f * d;
        return RectF(x + d, y + d, nw > 0.0f ? nw : 0.0f, nh > 0.0f ? nh : 0.0f);
    }

    /**
     * Translates the rectangle.
     *
     * Params:
     *   dx = Horizontal offset.
     *   dy = Vertical offset.
     *
     * Returns:
     *   Moved rectangle.
     */
    RectF translate(float dx, float dy) const {
        return RectF(x + dx, y + dy, w, h);
    }

    /**
     * Returns the rectangle centre.
     *
     * Returns:
     *   Centre point.
     */
    Point2F center() const {
        return Point2F(x + w * 0.5f, y + h * 0.5f);
    }
}

/**
 * Straight (non-premultiplied) linear RGBA color with components in [0, 1].
 */
struct ColorRGBA {
    float r = 0.0f;
    float g = 0.0f;
    float b = 0.0f;
    float a = 1.0f;

    @safe nothrow pure @nogc:

    /**
     * Builds a color from a packed 0xRRGGBBAA literal.
     *
     * Params:
     *   rgba = Packed color.
     *
     * Returns:
     *   Decoded color.
     */
    static ColorRGBA fromHex(uint rgba) {
        return ColorRGBA(
            ((rgba >> 24) & 0xFF) / 255.0f,
            ((rgba >> 16) & 0xFF) / 255.0f,
            ((rgba >> 8) & 0xFF) / 255.0f,
            (rgba & 0xFF) / 255.0f
        );
    }

    /**
     * Returns a copy with a replaced alpha component.
     *
     * Params:
     *   alpha = New alpha in [0, 1].
     *
     * Returns:
     *   Color with alpha replaced.
     */
    ColorRGBA withAlpha(float alpha) const {
        return ColorRGBA(r, g, b, alpha);
    }

    /**
     * Linear interpolation between this color and other.
     *
     * Params:
     *   other = Target color.
     *   t = Blend amount in [0, 1].
     *
     * Returns:
     *   Interpolated color.
     */
    ColorRGBA lerp(ColorRGBA other, float t) const {
        return ColorRGBA(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t);
    }

    /**
     * Scales the RGB channels toward white (amount > 0) or black (amount < 0).
     *
     * Params:
     *   amount = Signed brightness offset in [-1, 1].
     *
     * Returns:
     *   Adjusted color with unchanged alpha.
     */
    ColorRGBA brighten(float amount) const {
        immutable ColorRGBA target = amount >= 0.0f ? ColorRGBA(1, 1, 1, a) : ColorRGBA(0, 0, 0, a);
        immutable float t = amount >= 0.0f ? amount : -amount;
        return lerp(target, t > 1.0f ? 1.0f : t).withAlpha(a);
    }
}

/**
 * Integer scissor rectangle in physical framebuffer pixels.
 */
struct ScissorRect {
    uint x = 0;
    uint y = 0;
    uint w = 0;
    uint h = 0;
}

/**
 * Font families exposed to widgets.
 */
enum FontId : ubyte {
    ui = 0,
    mono = 1
}

/**
 * Primitive kinds understood by ui2d_fragment.
 */
enum InstanceKind : uint {
    shape = 0,
    glyph = 1,
    image = 2,
    line = 3
}

/**
 * GPU instance record shared bit-for-bit with UIInstance in shaders/ui2d.metal.
 *
 * shape: rect = physical px rect, colorA/colorB = vertical gradient top/bottom, colorBorder + borderWidth stroke,
 *        cornerRadius rounding (all physical px).
 * glyph: rect = destination px, uv = atlas source rect in atlas pixels (x0, y0, x1, y1), colorA tint.
 * image: rect = destination px, uv = normalized texture rect, colorA tint.
 * line:  uv = segment endpoints (x0, y0, x1, y1) in px, cornerRadius = half thickness, colorA color.
 */
struct UIInstance {
    float[4] rect = 0.0f;
    float[4] uv = 0.0f;
    float[4] colorA = 0.0f;
    float[4] colorB = 0.0f;
    float[4] colorBorder = 0.0f;
    float cornerRadius = 0.0f;
    float borderWidth = 0.0f;
    uint kind = InstanceKind.shape;
    uint flags = 0;
}

static assert(UIInstance.sizeof == 96, "UIInstance must match the 96-byte Metal struct layout");

/**
 * Contiguous run of instances sharing one scissor rectangle and one bound texture.
 */
struct DrawCommand {
    ScissorRect scissor;
    uint textureId = 0;
    size_t firstInstance = 0;
    size_t instanceCount = 0;
}

/**
 * One frame of recorded GPU work: instances plus ordered clip/texture command runs.
 */
struct DrawList {
    UIInstance[] instances;
    DrawCommand[] commands;
    uint framebufferWidth = 0;
    uint framebufferHeight = 0;
    float scaleFactor = 1.0f;

    /**
     * Clears recorded work while retaining allocated capacity.
     */
    void clear() @safe nothrow {
        instances.length = 0;
        commands.length = 0;
        () @trusted { instances.assumeSafeAppend(); commands.assumeSafeAppend(); }();
    }
}

/**
 * Text measurement contract used by layout code that must not depend on a GPU backend.
 */
interface ITextMeasurer {
    /**
     * Measures the advance width of a UTF-8 string.
     *
     * Params:
     *   text = UTF-8 text (invalid sequences count as U+FFFD).
     *   font = Font family.
     *   size = Font size in logical points.
     *
     * Returns:
     *   Advance width in logical points.
     */
    float measureText(const(char)[] text, FontId font, float size);

    /**
     * Returns the recommended line height for a font size.
     *
     * Params:
     *   font = Font family.
     *   size = Font size in logical points.
     *
     * Returns:
     *   Line height in logical points.
     */
    float lineHeight(FontId font, float size);
}

/**
 * Immediate-mode 2D drawing contract implemented by Metal (and future) backends.
 */
interface IRenderer2D : ITextMeasurer {
    /**
     * Starts recording a frame.
     *
     * Params:
     *   logicalWidth = Canvas width in logical points.
     *   logicalHeight = Canvas height in logical points.
     *   scaleFactor = Physical pixels per logical point (Retina = 2).
     */
    void beginFrame(float logicalWidth, float logicalHeight, float scaleFactor);

    /**
     * Finishes recording and submits the frame to the backend.
     */
    void endFrame();

    /**
     * Intersects the active clip with rect and pushes it.
     *
     * Params:
     *   rect = Clip rectangle in logical points.
     */
    void pushClip(RectF rect);

    /**
     * Restores the previous clip rectangle.
     */
    void popClip();

    /**
     * Returns the active clip rectangle in logical points.
     *
     * Returns:
     *   Current clip.
     */
    RectF currentClip();

    /**
     * Fills an axis-aligned rectangle.
     *
     * Params:
     *   rect = Target rectangle.
     *   color = Fill color.
     */
    void fillRect(RectF rect, ColorRGBA color);

    /**
     * Fills a rounded rectangle.
     *
     * Params:
     *   rect = Target rectangle.
     *   radius = Corner radius in logical points.
     *   color = Fill color.
     */
    void fillRoundedRect(RectF rect, float radius, ColorRGBA color);

    /**
     * Fills a rounded rectangle with a vertical gradient.
     *
     * Params:
     *   rect = Target rectangle.
     *   radius = Corner radius.
     *   top = Color at the top edge.
     *   bottom = Color at the bottom edge.
     */
    void fillRoundedRectGradient(RectF rect, float radius, ColorRGBA top, ColorRGBA bottom);

    /**
     * Strokes the border of a rounded rectangle (stroke lies inside rect).
     *
     * Params:
     *   rect = Target rectangle.
     *   radius = Corner radius.
     *   width = Stroke width in logical points.
     *   color = Stroke color.
     */
    void strokeRoundedRect(RectF rect, float radius, float width, ColorRGBA color);

    /**
     * Draws an anti-aliased line segment with round caps.
     *
     * Params:
     *   a = Start point.
     *   b = End point.
     *   width = Thickness in logical points.
     *   color = Line color.
     */
    void drawLine(Point2F a, Point2F b, float width, ColorRGBA color);

    /**
     * Draws an anti-aliased open polyline.
     *
     * Params:
     *   points = Vertices (at least two to draw anything).
     *   width = Thickness in logical points.
     *   color = Line color.
     */
    void drawPolyline(const(Point2F)[] points, float width, ColorRGBA color);

    /**
     * Draws an anti-aliased cubic Bezier curve.
     *
     * Params:
     *   p0 = Start point.
     *   c0 = First control point.
     *   c1 = Second control point.
     *   p1 = End point.
     *   width = Thickness in logical points.
     *   color = Curve color.
     */
    void drawBezier(Point2F p0, Point2F c0, Point2F c1, Point2F p1, float width, ColorRGBA color);

    /**
     * Draws single-line UTF-8 text with its top-left corner at origin.
     *
     * Params:
     *   origin = Top-left of the line box in logical points.
     *   text = UTF-8 text.
     *   font = Font family.
     *   size = Font size in logical points.
     *   color = Text color.
     */
    void drawText(Point2F origin, const(char)[] text, FontId font, float size, ColorRGBA color);

    /**
     * Draws an RGBA texture region.
     *
     * Params:
     *   textureId = Handle returned by createTextureRGBA.
     *   rect = Destination rectangle.
     *   uv = Normalized source rectangle (x0, y0 in x/y; x1, y1 in w/h).
     *   tint = Multiplicative tint.
     */
    void drawImage(uint textureId, RectF rect, RectF uv, ColorRGBA tint);

    /**
     * Creates an RGBA8 texture.
     *
     * Params:
     *   width = Texture width in pixels.
     *   height = Texture height in pixels.
     *   pixels = width * height * 4 bytes of straight RGBA.
     *
     * Returns:
     *   Non-zero texture handle, or 0 on failure.
     */
    uint createTextureRGBA(uint width, uint height, const(ubyte)[] pixels);

    /**
     * Replaces the full contents of an RGBA8 texture.
     *
     * Params:
     *   textureId = Existing texture handle.
     *   pixels = width * height * 4 bytes.
     *
     * Returns:
     *   True on success.
     */
    bool updateTextureRGBA(uint textureId, const(ubyte)[] pixels);

    /**
     * Destroys an RGBA8 texture.
     *
     * Params:
     *   textureId = Texture handle to release.
     */
    void destroyTexture(uint textureId);
}

/**
 * Decodes one UTF-8 code point without throwing; malformed input yields U+FFFD and advances one byte.
 *
 * Params:
 *   s = UTF-8 byte string.
 *   index = Read position, advanced past the decoded sequence.
 *   cp = Receives the decoded code point.
 *
 * Returns:
 *   Number of bytes consumed (0 only when index >= s.length).
 */
size_t decodeUtf8(const(char)[] s, ref size_t index, out dchar cp) @safe nothrow pure @nogc {
    cp = 0xFFFD;
    if (index >= s.length) {
        return 0;
    }
    immutable ubyte b0 = s[index];
    size_t need = 0;
    uint value = 0;
    uint minValue = 0;
    if (b0 < 0x80) {
        cp = b0;
        index++;
        return 1;
    } else if ((b0 & 0xE0) == 0xC0) {
        need = 1;
        value = b0 & 0x1F;
        minValue = 0x80;
    } else if ((b0 & 0xF0) == 0xE0) {
        need = 2;
        value = b0 & 0x0F;
        minValue = 0x800;
    } else if ((b0 & 0xF8) == 0xF0) {
        need = 3;
        value = b0 & 0x07;
        minValue = 0x10000;
    } else {
        index++;
        return 1;
    }
    if (index + need >= s.length) {
        index++;
        return 1;
    }
    foreach (k; 1 .. need + 1) {
        immutable ubyte bk = s[index + k];
        if ((bk & 0xC0) != 0x80) {
            index++;
            return 1;
        }
        value = (value << 6) | (bk & 0x3F);
    }
    if (value < minValue || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) {
        index++;
        return 1;
    }
    cp = cast(dchar) value;
    index += need + 1;
    return need + 1;
}

/**
 * CPU-side glyph bitmap and metrics produced by a platform rasterizer, all in physical pixels.
 */
struct RasterizedGlyph {
    uint width = 0;
    uint height = 0;
    float bearingX = 0.0f;
    float bearingY = 0.0f;
    float advance = 0.0f;
    ubyte[] coverage;
}

/**
 * Platform glyph rasterizer (CoreText on macOS) producing 8-bit coverage bitmaps.
 */
interface IGlyphRasterizer {
    /**
     * Rasterizes one code point at a physical pixel size.
     *
     * Params:
     *   font = Font family.
     *   pixelSize = Font size in physical pixels.
     *   cp = Unicode code point.
     *   outGlyph = Receives metrics and width * height coverage bytes (row-major, top row first).
     *
     * Returns:
     *   True if the glyph (possibly empty, e.g. space) was produced.
     */
    bool rasterize(FontId font, float pixelSize, dchar cp, out RasterizedGlyph outGlyph);

    /**
     * Returns ascent and line height for a physical pixel size.
     *
     * Params:
     *   font = Font family.
     *   pixelSize = Font size in physical pixels.
     *   ascent = Receives baseline offset from the line top in pixels.
     *   lineHeight = Receives total line height in pixels.
     */
    void lineMetrics(FontId font, float pixelSize, out float ascent, out float lineHeight);
}

/**
 * Cached glyph placement inside the atlas (pixel units).
 */
struct AtlasGlyph {
    uint atlasX = 0;
    uint atlasY = 0;
    uint width = 0;
    uint height = 0;
    float bearingX = 0.0f;
    float bearingY = 0.0f;
    float advance = 0.0f;
}

/**
 * Row-shelf rectangle packer with 1-pixel gutters; growth in height preserves existing placements.
 */
struct ShelfAtlasPacker {
    uint width = 0;
    uint height = 0;
    private uint shelfY_ = 1;
    private uint shelfHeight_ = 0;
    private uint cursorX_ = 1;

    @safe nothrow pure @nogc:

    /**
     * Resets the packer to an empty atlas.
     *
     * Params:
     *   w = Atlas width in pixels.
     *   h = Atlas height in pixels.
     */
    void reset(uint w, uint h) {
        width = w;
        height = h;
        shelfY_ = 1;
        shelfHeight_ = 0;
        cursorX_ = 1;
    }

    /**
     * Allocates a w x h rectangle.
     *
     * Params:
     *   w = Requested width.
     *   h = Requested height.
     *   outX = Receives the left coordinate.
     *   outY = Receives the top coordinate.
     *
     * Returns:
     *   True if placed; false if the atlas must grow first (packer state is unchanged on failure).
     */
    bool pack(uint w, uint h, out uint outX, out uint outY) {
        if (w + 2 > width) {
            return false;
        }
        uint y = shelfY_;
        uint shelfH = shelfHeight_;
        uint x = cursorX_;
        if (x + w + 1 > width) {
            y += shelfH + 1;
            shelfH = 0;
            x = 1;
        }
        if (y + h + 1 > height) {
            return false;
        }
        shelfY_ = y;
        outX = x;
        outY = y;
        cursorX_ = x + w + 1;
        shelfHeight_ = h > shelfH ? h : shelfH;
        return true;
    }

    /**
     * Increases atlas height; all previously packed rectangles remain valid.
     *
     * Params:
     *   newHeight = New height (must be >= current height).
     */
    void growHeight(uint newHeight) {
        if (newHeight > height) {
            height = newHeight;
        }
    }
}

/**
 * Lazily rasterizing glyph cache backed by a growable CPU R8 atlas with dirty-row tracking.
 */
class GlyphCache {
    enum uint ATLAS_WIDTH = 1024;
    enum uint INITIAL_HEIGHT = 512;
    enum uint MAX_HEIGHT = 8192;

    private IGlyphRasterizer rasterizer_;
    private ShelfAtlasPacker packer_;
    private ubyte[] pixels_;
    private AtlasGlyph[ulong] glyphs_;
    private bool[ulong] missing_;
    private uint dirtyMinY_ = uint.max;
    private uint dirtyMaxY_ = 0;
    private uint generation_ = 1;

    /**
     * Creates an empty cache bound to rasterizer.
     *
     * Params:
     *   rasterizer = Platform glyph rasterizer.
     */
    this(IGlyphRasterizer rasterizer) {
        rasterizer_ = rasterizer;
        packer_.reset(ATLAS_WIDTH, INITIAL_HEIGHT);
        pixels_ = new ubyte[cast(size_t) ATLAS_WIDTH * INITIAL_HEIGHT];
    }

    /**
     * Returns the atlas width in pixels.
     *
     * Returns:
     *   Width.
     */
    uint atlasWidth() const {
        return packer_.width;
    }

    /**
     * Returns the atlas height in pixels.
     *
     * Returns:
     *   Height.
     */
    uint atlasHeight() const {
        return packer_.height;
    }

    /**
     * Returns the full R8 atlas pixel buffer (row-major, atlasWidth stride).
     *
     * Returns:
     *   Atlas pixels.
     */
    const(ubyte)[] pixels() const {
        return pixels_;
    }

    /**
     * Returns a counter bumped whenever the atlas is resized (backends must recreate their texture).
     *
     * Returns:
     *   Atlas generation.
     */
    uint generation() const {
        return generation_;
    }

    /**
     * Reports and clears the dirty row range that must be uploaded.
     *
     * Params:
     *   minY = Receives the first dirty row.
     *   maxY = Receives one past the last dirty row.
     *
     * Returns:
     *   True if any rows changed since the previous call.
     */
    bool takeDirtyRows(out uint minY, out uint maxY) {
        if (dirtyMinY_ == uint.max) {
            return false;
        }
        minY = dirtyMinY_;
        maxY = dirtyMaxY_;
        dirtyMinY_ = uint.max;
        dirtyMaxY_ = 0;
        return true;
    }

    /**
     * Returns the number of cached glyph entries.
     *
     * Returns:
     *   Entry count.
     */
    size_t glyphCount() const {
        return glyphs_.length;
    }

    /**
     * Looks up (rasterizing and packing on first use) a glyph.
     *
     * Params:
     *   font = Font family.
     *   pixelSize = Physical pixel size (rounded to 0.5 px for cache keys).
     *   cp = Code point.
     *   outGlyph = Receives the atlas placement and metrics.
     *
     * Returns:
     *   True if available; false if the rasterizer has no glyph or the atlas is exhausted.
     */
    bool lookup(FontId font, float pixelSize, dchar cp, out AtlasGlyph outGlyph) {
        immutable ulong key = makeKey(font, pixelSize, cp);
        if (auto hit = key in glyphs_) {
            outGlyph = *hit;
            return true;
        }
        if (key in missing_) {
            return false;
        }
        RasterizedGlyph rg;
        if (rasterizer_ is null || !rasterizer_.rasterize(font, quantizeSize(pixelSize), cp, rg)) {
            missing_[key] = true;
            return false;
        }
        AtlasGlyph ag;
        ag.width = rg.width;
        ag.height = rg.height;
        ag.bearingX = rg.bearingX;
        ag.bearingY = rg.bearingY;
        ag.advance = rg.advance;
        if (rg.width > 0 && rg.height > 0) {
            if (rg.coverage.length < cast(size_t) rg.width * rg.height) {
                missing_[key] = true;
                return false;
            }
            uint px = 0;
            uint py = 0;
            while (!packer_.pack(rg.width, rg.height, px, py)) {
                if (!growAtlas()) {
                    return false;
                }
            }
            foreach (row; 0 .. rg.height) {
                immutable size_t dst = cast(size_t)(py + row) * packer_.width + px;
                immutable size_t src = cast(size_t) row * rg.width;
                pixels_[dst .. dst + rg.width] = rg.coverage[src .. src + rg.width];
            }
            ag.atlasX = px;
            ag.atlasY = py;
            markDirty(py, py + rg.height);
        }
        glyphs_[key] = ag;
        outGlyph = ag;
        return true;
    }

    /**
     * Returns line metrics for a physical pixel size.
     *
     * Params:
     *   font = Font family.
     *   pixelSize = Physical pixel size.
     *   ascent = Receives ascent in pixels.
     *   lineHeight = Receives line height in pixels.
     */
    void lineMetrics(FontId font, float pixelSize, out float ascent, out float lineHeight) {
        if (rasterizer_ is null) {
            ascent = pixelSize * 0.8f;
            lineHeight = pixelSize * 1.2f;
            return;
        }
        rasterizer_.lineMetrics(font, quantizeSize(pixelSize), ascent, lineHeight);
    }

    private bool growAtlas() {
        immutable uint oldH = packer_.height;
        if (oldH >= MAX_HEIGHT) {
            return false;
        }
        immutable uint newH = oldH * 2 > MAX_HEIGHT ? MAX_HEIGHT : oldH * 2;
        pixels_.length = cast(size_t) packer_.width * newH;
        packer_.growHeight(newH);
        generation_++;
        markDirty(0, newH);
        return true;
    }

    private void markDirty(uint y0, uint y1) {
        if (y0 < dirtyMinY_) dirtyMinY_ = y0;
        if (y1 > dirtyMaxY_) dirtyMaxY_ = y1;
    }

    private static float quantizeSize(float pixelSize) @safe nothrow pure @nogc {
        immutable float clamped = isFinite(pixelSize) && pixelSize > 1.0f ? (pixelSize < 512.0f ? pixelSize : 512.0f) : 1.0f;
        return floor(clamped * 2.0f + 0.5f) * 0.5f;
    }

    private static ulong makeKey(FontId font, float pixelSize, dchar cp) @safe nothrow pure @nogc {
        immutable ulong sizeKey = cast(ulong)(quantizeSize(pixelSize) * 2.0f);
        return (cast(ulong) font << 56) | (sizeKey << 32) | cast(ulong) cp;
    }
}

/**
 * Backend-agnostic batching renderer: converts IRenderer2D calls into a DrawList and hands it to submitFrame().
 */
abstract class BatchRenderer2D : IRenderer2D {
    protected DrawList list_;
    protected GlyphCache glyphs_;
    private RectF[] clipStack_;
    private size_t clipDepth_ = 0;
    private float scale_ = 1.0f;
    private float logicalW_ = 0.0f;
    private float logicalH_ = 0.0f;
    private bool inFrame_ = false;
    private Point2F[] bezierScratch_;

    /**
     * Binds the batcher to a glyph cache (may be null for text-less backends).
     *
     * Params:
     *   glyphs = Shared glyph cache.
     */
    this(GlyphCache glyphs) {
        glyphs_ = glyphs;
    }

    /**
     * Backend hook receiving the finished frame.
     *
     * Params:
     *   list = Recorded frame.
     */
    protected abstract void submitFrame(ref DrawList list);

    /**
     * Returns the last recorded DrawList (valid until the next beginFrame).
     *
     * Returns:
     *   Pointer to the internal DrawList.
     */
    const(DrawList)* lastDrawList() const {
        return &list_;
    }

    /**
     * Returns the glyph cache used for text.
     *
     * Returns:
     *   Glyph cache, possibly null.
     */
    GlyphCache glyphCache() {
        return glyphs_;
    }

    /**
     * Starts recording; resets clip to the full canvas.
     *
     * Params:
     *   logicalWidth = Canvas width in points.
     *   logicalHeight = Canvas height in points.
     *   scaleFactor = Pixels per point.
     */
    override void beginFrame(float logicalWidth, float logicalHeight, float scaleFactor) {
        scale_ = isFinite(scaleFactor) && scaleFactor > 0.0f ? scaleFactor : 1.0f;
        logicalW_ = logicalWidth > 0.0f ? logicalWidth : 0.0f;
        logicalH_ = logicalHeight > 0.0f ? logicalHeight : 0.0f;
        list_.clear();
        list_.scaleFactor = scale_;
        list_.framebufferWidth = cast(uint) ceil(logicalW_ * scale_);
        list_.framebufferHeight = cast(uint) ceil(logicalH_ * scale_);
        if (clipStack_.length < 16) {
            clipStack_.length = 16;
        }
        clipStack_[0] = RectF(0, 0, logicalW_, logicalH_);
        clipDepth_ = 1;
        inFrame_ = true;
    }

    /**
     * Finishes recording and calls submitFrame().
     */
    override void endFrame() {
        if (!inFrame_) {
            return;
        }
        inFrame_ = false;
        submitFrame(list_);
    }

    /**
     * Pushes the intersection of the active clip and rect.
     *
     * Params:
     *   rect = Clip rectangle in points.
     */
    override void pushClip(RectF rect) {
        immutable RectF next = currentClip().intersect(rect);
        if (clipDepth_ >= clipStack_.length) {
            clipStack_.length = clipStack_.length < 16 ? 16 : clipStack_.length * 2;
        }
        clipStack_[clipDepth_++] = next;
    }

    /**
     * Pops the active clip (the root canvas clip is never popped).
     */
    override void popClip() {
        if (clipDepth_ > 1) {
            clipDepth_--;
        }
    }

    /**
     * Returns the active clip.
     *
     * Returns:
     *   Clip rectangle in points.
     */
    override RectF currentClip() {
        return clipDepth_ > 0 ? clipStack_[clipDepth_ - 1] : RectF(0, 0, logicalW_, logicalH_);
    }

    /**
     * Returns the clip stack depth (1 = root only).
     *
     * Returns:
     *   Depth.
     */
    size_t clipDepth() const {
        return clipDepth_;
    }

    override void fillRect(RectF rect, ColorRGBA color) {
        emitShape(rect, 0.0f, color, color, ColorRGBA(0, 0, 0, 0), 0.0f);
    }

    override void fillRoundedRect(RectF rect, float radius, ColorRGBA color) {
        emitShape(rect, radius, color, color, ColorRGBA(0, 0, 0, 0), 0.0f);
    }

    override void fillRoundedRectGradient(RectF rect, float radius, ColorRGBA top, ColorRGBA bottom) {
        emitShape(rect, radius, top, bottom, ColorRGBA(0, 0, 0, 0), 0.0f);
    }

    override void strokeRoundedRect(RectF rect, float radius, float width, ColorRGBA color) {
        if (!(width > 0.0f)) {
            return;
        }
        emitShape(rect, radius, ColorRGBA(0, 0, 0, 0), ColorRGBA(0, 0, 0, 0), color, width);
    }

    override void drawLine(Point2F a, Point2F b, float width, ColorRGBA color) {
        if (!(width > 0.0f) || !isFinitePoint(a) || !isFinitePoint(b) || color.a <= 0.0f) {
            return;
        }
        immutable float half = width * 0.5f;
        immutable RectF bounds = RectF(
            (a.x < b.x ? a.x : b.x) - half - 1.0f,
            (a.y < b.y ? a.y : b.y) - half - 1.0f,
            (a.x < b.x ? b.x - a.x : a.x - b.x) + width + 2.0f,
            (a.y < b.y ? b.y - a.y : a.y - b.y) + width + 2.0f
        );
        if (bounds.intersect(currentClip()).isEmpty()) {
            return;
        }
        UIInstance inst;
        inst.kind = InstanceKind.line;
        inst.rect = [bounds.x * scale_, bounds.y * scale_, bounds.w * scale_, bounds.h * scale_];
        inst.uv = [a.x * scale_, a.y * scale_, b.x * scale_, b.y * scale_];
        inst.cornerRadius = half * scale_;
        inst.colorA = toArray(color);
        append(inst, 0);
    }

    override void drawPolyline(const(Point2F)[] points, float width, ColorRGBA color) {
        if (points.length < 2) {
            return;
        }
        foreach (i; 1 .. points.length) {
            drawLine(points[i - 1], points[i], width, color);
        }
    }

    override void drawBezier(Point2F p0, Point2F c0, Point2F c1, Point2F p1, float width, ColorRGBA color) {
        immutable size_t segments = bezierSegmentCount(p0, c0, c1, p1, scale_);
        bezierScratch_.length = segments + 1;
        foreach (i; 0 .. segments + 1) {
            bezierScratch_[i] = evalCubic(p0, c0, c1, p1, cast(float) i / cast(float) segments);
        }
        drawPolyline(bezierScratch_, width, color);
    }

    override void drawText(Point2F origin, const(char)[] text, FontId font, float size, ColorRGBA color) {
        if (glyphs_ is null || text.length == 0 || !(size > 0.0f) || color.a <= 0.0f) {
            return;
        }
        immutable float pxSize = size * scale_;
        float ascent = 0.0f;
        float lineH = 0.0f;
        glyphs_.lineMetrics(font, pxSize, ascent, lineH);
        float penX = floor(origin.x * scale_ + 0.5f);
        immutable float baseline = floor(origin.y * scale_ + ascent + 0.5f);
        immutable RectF clipPx = scaleRect(currentClip(), scale_);
        size_t i = 0;
        while (i < text.length) {
            dchar cp;
            decodeUtf8(text, i, cp);
            AtlasGlyph g;
            if (!glyphs_.lookup(font, pxSize, cp, g)) {
                if (!glyphs_.lookup(font, pxSize, '?', g)) {
                    continue;
                }
            }
            if (g.width > 0 && g.height > 0) {
                immutable float gx = penX + g.bearingX;
                immutable float gy = baseline - g.bearingY;
                immutable RectF dst = RectF(gx, gy, g.width, g.height);
                if (!dst.intersect(clipPx).isEmpty()) {
                    UIInstance inst;
                    inst.kind = InstanceKind.glyph;
                    inst.rect = [dst.x, dst.y, dst.w, dst.h];
                    inst.uv = [g.atlasX, g.atlasY, g.atlasX + g.width, g.atlasY + g.height];
                    inst.colorA = toArray(color);
                    append(inst, 0);
                }
            }
            penX += g.advance;
            if (penX > clipPx.right() + pxSize * 4.0f) {
                break;
            }
        }
    }

    override void drawImage(uint textureId, RectF rect, RectF uv, ColorRGBA tint) {
        if (textureId == 0 || rect.isEmpty() || rect.intersect(currentClip()).isEmpty()) {
            return;
        }
        UIInstance inst;
        inst.kind = InstanceKind.image;
        inst.rect = [rect.x * scale_, rect.y * scale_, rect.w * scale_, rect.h * scale_];
        inst.uv = [uv.x, uv.y, uv.w, uv.h];
        inst.colorA = toArray(tint);
        append(inst, textureId);
    }

    override float measureText(const(char)[] text, FontId font, float size) {
        if (glyphs_ is null || !(size > 0.0f)) {
            return 0.0f;
        }
        immutable float pxSize = size * scale_;
        float total = 0.0f;
        size_t i = 0;
        while (i < text.length) {
            dchar cp;
            decodeUtf8(text, i, cp);
            AtlasGlyph g;
            if (glyphs_.lookup(font, pxSize, cp, g) || glyphs_.lookup(font, pxSize, '?', g)) {
                total += g.advance;
            }
        }
        return total / scale_;
    }

    override float lineHeight(FontId font, float size) {
        if (!(size > 0.0f)) {
            return 0.0f;
        }
        if (glyphs_ is null) {
            return size * 1.2f;
        }
        float ascent = 0.0f;
        float lineH = 0.0f;
        glyphs_.lineMetrics(font, size * scale_, ascent, lineH);
        return lineH / scale_;
    }

    private void emitShape(RectF rect, float radius, ColorRGBA top, ColorRGBA bottom, ColorRGBA border, float borderWidth) {
        if (rect.isEmpty() || !isFinite(rect.x) || !isFinite(rect.y) || rect.intersect(currentClip()).isEmpty()) {
            return;
        }
        immutable float maxR = (rect.w < rect.h ? rect.w : rect.h) * 0.5f;
        immutable float r = radius > 0.0f ? (radius < maxR ? radius : maxR) : 0.0f;
        UIInstance inst;
        inst.kind = InstanceKind.shape;
        inst.rect = [rect.x * scale_, rect.y * scale_, rect.w * scale_, rect.h * scale_];
        inst.colorA = toArray(top);
        inst.colorB = toArray(bottom);
        inst.colorBorder = toArray(border);
        inst.cornerRadius = r * scale_;
        inst.borderWidth = borderWidth * scale_;
        append(inst, 0);
    }

    private void append(ref UIInstance inst, uint textureId) {
        immutable ScissorRect sc = toScissor(currentClip());
        if (sc.w == 0 || sc.h == 0) {
            return;
        }
        if (list_.commands.length > 0) {
            DrawCommand* last = &list_.commands[$ - 1];
            if (last.textureId == textureId && last.scissor == sc
                    && last.firstInstance + last.instanceCount == list_.instances.length) {
                list_.instances ~= inst;
                last.instanceCount++;
                return;
            }
        }
        list_.commands ~= DrawCommand(sc, textureId, list_.instances.length, 1);
        list_.instances ~= inst;
    }

    private ScissorRect toScissor(RectF clip) const {
        immutable float x0 = floor(clip.x * scale_);
        immutable float y0 = floor(clip.y * scale_);
        float x1 = ceil(clip.right() * scale_);
        float y1 = ceil(clip.bottom() * scale_);
        if (x1 > list_.framebufferWidth) x1 = list_.framebufferWidth;
        if (y1 > list_.framebufferHeight) y1 = list_.framebufferHeight;
        immutable float cx = x0 > 0.0f ? x0 : 0.0f;
        immutable float cy = y0 > 0.0f ? y0 : 0.0f;
        if (!(x1 > cx) || !(y1 > cy)) {
            return ScissorRect.init;
        }
        return ScissorRect(cast(uint) cx, cast(uint) cy, cast(uint)(x1 - cx), cast(uint)(y1 - cy));
    }

    private static RectF scaleRect(RectF r, float s) @safe nothrow pure @nogc {
        return RectF(r.x * s, r.y * s, r.w * s, r.h * s);
    }

    private static float[4] toArray(ColorRGBA c) @safe nothrow pure @nogc {
        return [c.r, c.g, c.b, c.a];
    }

    private static bool isFinitePoint(Point2F p) @safe nothrow pure @nogc {
        return isFinite(p.x) && isFinite(p.y);
    }
}

/**
 * Chooses a tessellation segment count for a cubic Bezier from its control-polygon length in pixels.
 *
 * Params:
 *   p0 = Start point.
 *   c0 = First control point.
 *   c1 = Second control point.
 *   p1 = End point.
 *   scale = Pixels per point.
 *
 * Returns:
 *   Segment count in [4, 256].
 */
size_t bezierSegmentCount(Point2F p0, Point2F c0, Point2F c1, Point2F p1, float scale) @safe nothrow pure @nogc {
    immutable float polyLen = ((c0 - p0).length() + (c1 - c0).length() + (p1 - c1).length()) * scale;
    if (!isFinite(polyLen)) {
        return 4;
    }
    immutable float n = polyLen / 6.0f;
    return n < 4.0f ? 4 : (n > 256.0f ? 256 : cast(size_t) n);
}

/**
 * Evaluates a cubic Bezier at parameter t.
 *
 * Params:
 *   p0 = Start point.
 *   c0 = First control point.
 *   c1 = Second control point.
 *   p1 = End point.
 *   t = Parameter in [0, 1].
 *
 * Returns:
 *   Curve point.
 */
Point2F evalCubic(Point2F p0, Point2F c0, Point2F c1, Point2F p1, float t) @safe nothrow pure @nogc {
    immutable float u = 1.0f - t;
    immutable float b0 = u * u * u;
    immutable float b1 = 3.0f * u * u * t;
    immutable float b2 = 3.0f * u * t * t;
    immutable float b3 = t * t * t;
    return Point2F(
        b0 * p0.x + b1 * c0.x + b2 * c1.x + b3 * p1.x,
        b0 * p0.y + b1 * c0.y + b2 * c1.y + b3 * p1.y
    );
}

/**
 * GPU-free renderer that records DrawLists (for unit tests, layout probing, and offscreen validation).
 */
class HeadlessRenderer : BatchRenderer2D {
    private uint nextTexture_ = 1;
    private bool[uint] textures_;
    size_t submittedFrames = 0;

    /**
     * Creates a headless renderer.
     *
     * Params:
     *   glyphs = Optional glyph cache for text measurement and glyph instances.
     */
    this(GlyphCache glyphs = null) {
        super(glyphs);
    }

    protected override void submitFrame(ref DrawList list) {
        submittedFrames++;
    }

    override uint createTextureRGBA(uint width, uint height, const(ubyte)[] pixels) {
        if (width == 0 || height == 0 || pixels.length != cast(size_t) width * height * 4) {
            return 0;
        }
        immutable uint id = nextTexture_++;
        textures_[id] = true;
        return id;
    }

    override bool updateTextureRGBA(uint textureId, const(ubyte)[] pixels) {
        return (textureId in textures_) !is null;
    }

    override void destroyTexture(uint textureId) {
        textures_.remove(textureId);
    }
}
