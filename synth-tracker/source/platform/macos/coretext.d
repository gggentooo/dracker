/**
 * File:         source/platform/macos/coretext.d
 * Module:       platform.macos.coretext
 * Phase:        Phase 7.3 — CoreText Retina Glyph Atlas Rasterizer
 *
 * Purpose:
 *   Implements gui.renderer.IGlyphRasterizer with CoreText + CoreGraphics: rasterizes the system UI sans-serif
 *   and the user fixed-pitch (tracker) font at exact physical pixel sizes into 8-bit grayscale coverage
 *   bitmaps that GlyphCache packs into the dynamically grown R8 Metal atlas. Missing glyphs fall back to
 *   CTFontCreateForString cascade fonts; surrogate pairs are supported.
 *
 * Real-Time & Safety Contract:
 *   Main UI thread only; every CoreFoundation/CoreGraphics object is released deterministically (per-size
 *   CTFont cache released by close()/destructor, per-glyph contexts released immediately).
 *
 * Dependencies:
 *   Internal: gui.renderer, platform.macos.corefoundation
 *   External: macOS CoreText.framework, CoreGraphics.framework
 *
 * Planned API (Types, Functions & Hooks):
 *   - class CoreTextRasterizer : IGlyphRasterizer (rasterize(), lineMetrics(), close())
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 7.3)
 */
module platform.macos.coretext;

version (OSX):

import std.math : ceil, floor, isFinite;

import gui.renderer : FontId, IGlyphRasterizer, RasterizedGlyph;
import platform.macos.corefoundation : CFIndex, CFRange, CFRelease, CFStringRef, CFTypeRef, createCFString;

private alias CTFontRef = const(void)*;
private alias CGContextRef = void*;
private alias CGColorSpaceRef = void*;
private alias CGGlyph = ushort;
private alias UniChar = ushort;

private struct CGPointD {
    double x = 0.0;
    double y = 0.0;
}

private struct CGSizeD {
    double width = 0.0;
    double height = 0.0;
}

private struct CGRectD {
    CGPointD origin;
    CGSizeD size;
}

private enum int kCTFontUIFontUserFixedPitch = 1;
private enum int kCTFontUIFontSystem = 2;
private enum uint kCGImageAlphaNone = 0;
private enum int kCTFontOrientationDefault = 0;

private extern (C) @nogc nothrow {
    CTFontRef CTFontCreateUIFontForLanguage(int uiType, double size, CFStringRef language);
    CTFontRef CTFontCreateForString(CTFontRef currentFont, CFStringRef str, CFRange range);
    bool CTFontGetGlyphsForCharacters(CTFontRef font, const(UniChar)* characters, CGGlyph* glyphs, CFIndex count);
    CGRectD CTFontGetBoundingRectsForGlyphs(CTFontRef font, int orientation, const(CGGlyph)* glyphs,
        CGRectD* boundingRects, CFIndex count);
    double CTFontGetAdvancesForGlyphs(CTFontRef font, int orientation, const(CGGlyph)* glyphs,
        CGSizeD* advances, CFIndex count);
    double CTFontGetAscent(CTFontRef font);
    double CTFontGetDescent(CTFontRef font);
    double CTFontGetLeading(CTFontRef font);
    void CTFontDrawGlyphs(CTFontRef font, const(CGGlyph)* glyphs, const(CGPointD)* positions, size_t count,
        CGContextRef context);

    CGColorSpaceRef CGColorSpaceCreateDeviceGray();
    void CGColorSpaceRelease(CGColorSpaceRef space);
    CGContextRef CGBitmapContextCreate(void* data, size_t width, size_t height, size_t bitsPerComponent,
        size_t bytesPerRow, CGColorSpaceRef space, uint bitmapInfo);
    void CGContextRelease(CGContextRef c);
    void CGContextSetGrayFillColor(CGContextRef c, double gray, double alpha);
    void CGContextSetShouldAntialias(CGContextRef c, bool shouldAntialias);
    void CGContextSetShouldSmoothFonts(CGContextRef c, bool shouldSmoothFonts);
    void CGContextSetAllowsFontSubpixelPositioning(CGContextRef c, bool allows);
    void CGContextSetShouldSubpixelPositionFonts(CGContextRef c, bool should);
}

/**
 * CoreText-backed glyph rasterizer producing R8 coverage bitmaps in physical pixels.
 */
final class CoreTextRasterizer : IGlyphRasterizer {
    private CTFontRef[ulong] fonts_;
    private CGColorSpaceRef gray_ = null;
    private bool closed_ = false;

    /**
     * Creates the rasterizer and its grayscale color space.
     */
    this() {
        gray_ = CGColorSpaceCreateDeviceGray();
    }

    /**
     * Releases cached fonts and the color space (idempotent).
     */
    void close() {
        if (closed_) {
            return;
        }
        closed_ = true;
        foreach (f; fonts_.byValue()) {
            if (f !is null) {
                CFRelease(cast(CFTypeRef) f);
            }
        }
        fonts_ = null;
        if (gray_ !is null) {
            CGColorSpaceRelease(gray_);
            gray_ = null;
        }
    }

    /**
     * Releases native resources.
     */
    ~this() {
        close();
    }

    /**
     * Returns the number of distinct CTFont instances currently cached.
     *
     * Returns:
     *   Cached font count.
     */
    size_t cachedFontCount() const {
        return fonts_.length;
    }

    override bool rasterize(FontId font, float pixelSize, dchar cp, out RasterizedGlyph outGlyph) {
        if (closed_ || gray_ is null || !isFinite(pixelSize) || pixelSize < 1.0f) {
            return false;
        }
        CTFontRef base = fontFor(font, pixelSize);
        if (base is null) {
            return false;
        }
        UniChar[2] units;
        immutable CFIndex unitCount = encodeUtf16(cp, units);
        if (unitCount == 0) {
            return false;
        }
        CGGlyph[2] glyphs;
        CTFontRef drawFont = base;
        CTFontRef fallback = null;
        if (!CTFontGetGlyphsForCharacters(base, units.ptr, glyphs.ptr, unitCount)) {
            fallback = createFallback(base, units[0 .. unitCount]);
            if (fallback is null || !CTFontGetGlyphsForCharacters(fallback, units.ptr, glyphs.ptr, unitCount)) {
                if (fallback !is null) {
                    CFRelease(cast(CFTypeRef) fallback);
                }
                return false;
            }
            drawFont = fallback;
        }
        scope (exit) {
            if (fallback !is null) {
                CFRelease(cast(CFTypeRef) fallback);
            }
        }

        CGSizeD adv;
        CTFontGetAdvancesForGlyphs(drawFont, kCTFontOrientationDefault, glyphs.ptr, &adv, 1);
        CGRectD bbox;
        CTFontGetBoundingRectsForGlyphs(drawFont, kCTFontOrientationDefault, glyphs.ptr, &bbox, 1);
        outGlyph.advance = cast(float) adv.width;

        if (!(bbox.size.width > 0.0) || !(bbox.size.height > 0.0)) {
            outGlyph.width = 0;
            outGlyph.height = 0;
            return true;
        }
        immutable int x0 = cast(int) floor(bbox.origin.x) - 1;
        immutable int y0 = cast(int) floor(bbox.origin.y) - 1;
        immutable int x1 = cast(int) ceil(bbox.origin.x + bbox.size.width) + 1;
        immutable int y1 = cast(int) ceil(bbox.origin.y + bbox.size.height) + 1;
        immutable uint w = cast(uint)(x1 - x0);
        immutable uint h = cast(uint)(y1 - y0);
        if (w == 0 || h == 0 || w > 2048 || h > 2048) {
            return false;
        }

        ubyte[] bitmap = new ubyte[cast(size_t) w * h];
        CGContextRef ctx = CGBitmapContextCreate(bitmap.ptr, w, h, 8, w, gray_, kCGImageAlphaNone);
        if (ctx is null) {
            return false;
        }
        CGContextSetShouldAntialias(ctx, true);
        CGContextSetShouldSmoothFonts(ctx, false);
        CGContextSetAllowsFontSubpixelPositioning(ctx, true);
        CGContextSetShouldSubpixelPositionFonts(ctx, false);
        CGContextSetGrayFillColor(ctx, 1.0, 1.0);
        CGPointD pos = CGPointD(-cast(double) x0, -cast(double) y0);
        CTFontDrawGlyphs(drawFont, glyphs.ptr, &pos, 1, ctx);
        CGContextRelease(ctx);

        outGlyph.width = w;
        outGlyph.height = h;
        outGlyph.bearingX = cast(float) x0;
        outGlyph.bearingY = cast(float) y1;
        outGlyph.coverage = bitmap;
        return true;
    }

    override void lineMetrics(FontId font, float pixelSize, out float ascent, out float lineHeight) {
        CTFontRef f = closed_ ? null : fontFor(font, pixelSize);
        if (f is null) {
            ascent = pixelSize * 0.8f;
            lineHeight = pixelSize * 1.2f;
            return;
        }
        immutable double a = CTFontGetAscent(f);
        immutable double d = CTFontGetDescent(f);
        immutable double l = CTFontGetLeading(f);
        ascent = cast(float) ceil(a);
        lineHeight = cast(float) ceil(a + d + (l > 0.0 ? l : 0.0));
    }

    private CTFontRef fontFor(FontId font, float pixelSize) {
        immutable ulong key = (cast(ulong) font << 32) | cast(ulong)(pixelSize * 4.0f);
        if (auto hit = key in fonts_) {
            return *hit;
        }
        immutable int uiType = font == FontId.mono ? kCTFontUIFontUserFixedPitch : kCTFontUIFontSystem;
        CTFontRef f = CTFontCreateUIFontForLanguage(uiType, pixelSize, null);
        fonts_[key] = f;
        return f;
    }

    private static CTFontRef createFallback(CTFontRef base, const(UniChar)[] units) {
        char[4] utf8;
        immutable size_t n = utf16ToUtf8(units, utf8);
        if (n == 0) {
            return null;
        }
        CFStringRef s = createCFString(utf8[0 .. n]);
        if (s is null) {
            return null;
        }
        scope (exit) CFRelease(cast(CFTypeRef) s);
        return CTFontCreateForString(base, s, CFRange(0, cast(CFIndex) units.length));
    }

    private static CFIndex encodeUtf16(dchar cp, ref UniChar[2] units) @safe nothrow pure @nogc {
        if (cp < 0x10000) {
            if (cp >= 0xD800 && cp <= 0xDFFF) {
                return 0;
            }
            units[0] = cast(UniChar) cp;
            return 1;
        }
        if (cp > 0x10FFFF) {
            return 0;
        }
        immutable uint v = cast(uint) cp - 0x10000;
        units[0] = cast(UniChar)(0xD800 + (v >> 10));
        units[1] = cast(UniChar)(0xDC00 + (v & 0x3FF));
        return 2;
    }

    private static size_t utf16ToUtf8(const(UniChar)[] units, ref char[4] outBuf) @safe nothrow pure @nogc {
        uint cp = units[0];
        if (units.length == 2) {
            cp = 0x10000 + ((cast(uint) units[0] - 0xD800) << 10) + (cast(uint) units[1] - 0xDC00);
        }
        if (cp < 0x80) {
            outBuf[0] = cast(char) cp;
            return 1;
        } else if (cp < 0x800) {
            outBuf[0] = cast(char)(0xC0 | (cp >> 6));
            outBuf[1] = cast(char)(0x80 | (cp & 0x3F));
            return 2;
        } else if (cp < 0x10000) {
            outBuf[0] = cast(char)(0xE0 | (cp >> 12));
            outBuf[1] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
            outBuf[2] = cast(char)(0x80 | (cp & 0x3F));
            return 3;
        }
        outBuf[0] = cast(char)(0xF0 | (cp >> 18));
        outBuf[1] = cast(char)(0x80 | ((cp >> 12) & 0x3F));
        outBuf[2] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
        outBuf[3] = cast(char)(0x80 | (cp & 0x3F));
        return 4;
    }
}

unittest {
    import gui.renderer : AtlasGlyph, GlyphCache;

    CoreTextRasterizer r = new CoreTextRasterizer();
    scope (exit) r.close();

    RasterizedGlyph a;
    assert(r.rasterize(FontId.ui, 26.0f, 'A', a));
    assert(a.width > 4 && a.height > 10 && a.advance > 8.0f);
    assert(a.coverage.length == cast(size_t) a.width * a.height);
    uint inked = 0;
    ubyte peak = 0;
    foreach (c; a.coverage) {
        if (c > 0) inked++;
        if (c > peak) peak = c;
    }
    assert(inked > 20 && peak > 200);
    assert(a.bearingY > 10.0f);

    RasterizedGlyph space;
    assert(r.rasterize(FontId.ui, 26.0f, ' ', space));
    assert(space.width == 0 && space.height == 0 && space.advance > 2.0f);

    RasterizedGlyph mi;
    RasterizedGlyph mw;
    assert(r.rasterize(FontId.mono, 24.0f, 'i', mi));
    assert(r.rasterize(FontId.mono, 24.0f, 'W', mw));
    assert(mi.advance == mw.advance);

    RasterizedGlyph small;
    RasterizedGlyph big;
    assert(r.rasterize(FontId.ui, 12.0f, 'H', small));
    assert(r.rasterize(FontId.ui, 48.0f, 'H', big));
    assert(big.height > small.height * 3);

    RasterizedGlyph kana;
    assert(r.rasterize(FontId.ui, 26.0f, 'あ', kana));
    assert(kana.width > 0);
    RasterizedGlyph emoji;
    assert(r.rasterize(FontId.ui, 26.0f, '\U0001F3B9', emoji));

    float asc = 0.0f;
    float lh = 0.0f;
    r.lineMetrics(FontId.mono, 24.0f, asc, lh);
    assert(asc > 12.0f && lh > asc);
    assert(!r.rasterize(FontId.ui, float.nan, 'A', a));

    GlyphCache cache = new GlyphCache(r);
    AtlasGlyph g1;
    AtlasGlyph g2;
    assert(cache.lookup(FontId.mono, 24.0f, 'Q', g1));
    immutable size_t fontsAfterFirst = r.cachedFontCount();
    assert(cache.lookup(FontId.mono, 24.0f, 'Q', g2));
    assert(g1 == g2 && r.cachedFontCount() == fontsAfterFirst);
    uint minY = 0;
    uint maxY = 0;
    assert(cache.takeDirtyRows(minY, maxY) && maxY > minY);
    assert(!cache.takeDirtyRows(minY, maxY));
}
