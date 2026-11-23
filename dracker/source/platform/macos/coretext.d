/**
 * File:         source/platform/macos/coretext.d
 * Module:       platform.macos.coretext
 * Phase:        Phase 7.3 — CoreText Retina Glyph Atlas Rasterizer (Phase 8.5 font family selection)
 *
 * Purpose:
 *   Implements gui.renderer.IGlyphRasterizer with CoreText + CoreGraphics: rasterizes the UI font and the
 *   fixed-pitch (tracker) font at exact physical pixel sizes into 8-bit grayscale coverage bitmaps that
 *   GlyphCache packs into the dynamically grown R8 Metal atlas. Missing glyphs fall back to CTFontCreateForString
 *   cascade fonts; surrogate pairs are supported. Phase 8.5: setFonts() selects families by name at Regular
 *   weight (variable fonts are pinned to wght 400 through kCTFontVariationAttribute, because e.g. Fira Code's
 *   default instance is Light), resolving bundled fonts registered at process scope by registerBundledFonts()
 *   before installed copies, and falling back to the system UI / fixed-pitch font when a family is missing or a
 *   monospace request is not fixed-pitch. listFontFamilies() enumerates installed families (optionally only
 *   fixed-pitch ones). Glyphs are rasterized per code point without shaping, so programming ligatures (Fira
 *   Code "->", "===") never apply and tracker strings keep uniform advances.
 *
 * Real-Time & Safety Contract:
 *   Main UI thread only; every CoreFoundation/CoreGraphics object is released deterministically (per-size
 *   CTFont cache and font descriptors released by setFonts()/close()/destructor, per-glyph contexts released
 *   immediately). Font registration is process-scoped: nothing is installed system-wide.
 *
 * Dependencies:
 *   Internal: gui.renderer, platform.macos.corefoundation
 *   External: macOS CoreText.framework, CoreGraphics.framework
 *
 * Planned API (Types, Functions & Hooks):
 *   - class CoreTextRasterizer : IGlyphRasterizer (rasterize(), lineMetrics(), close(), setFonts(), resolution(),
 *     registerBundledFonts(), listFontFamilies(), isFixedPitchFamily())
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 7.3)
 */
module platform.macos.coretext;

version (OSX):

import std.math : ceil, fabs, floor, isFinite;

import gui.appearance : FontResolution;
import gui.renderer : FontId, IGlyphRasterizer, RasterizedGlyph;
import platform.macos.corefoundation : CFArrayGetCount, CFArrayGetValueAtIndex, CFArrayRef, CFIndex, CFRange,
    CFRelease, CFRetain, CFStringRef, CFTypeRef, cfStringToDString, createCFString;

private alias CTFontRef = const(void)*;
private alias CGContextRef = void*;
private alias CGColorSpaceRef = void*;
private alias CGGlyph = ushort;
private alias UniChar = ushort;
private alias CTFontDescriptorRef = const(void)*;
private alias CFDictionaryRef = const(void)*;
private alias CFNumberRef = const(void)*;
private alias CFURLRef = const(void)*;
private alias CFErrorRef = void*;

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
private enum uint kCTFontTraitMonoSpace = 1u << 10;
private enum uint kCTFontManagerScopeProcess = 1;
private enum int kCFNumberSInt32Type = 3;
private enum int kCFNumberDoubleType = 13;
private enum int WGHT_AXIS_TAG = 0x77676874;
private enum CFIndex kCTFontManagerErrorAlreadyRegistered = 105;

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

    CTFontDescriptorRef CTFontDescriptorCreateWithAttributes(CFDictionaryRef attributes);
    CTFontDescriptorRef CTFontDescriptorCreateCopyWithAttributes(CTFontDescriptorRef original, CFDictionaryRef attributes);
    CTFontRef CTFontCreateWithFontDescriptor(CTFontDescriptorRef descriptor, double size, const(void)* matrix);
    CFStringRef CTFontCopyFamilyName(CTFontRef font);
    CFTypeRef CTFontCopyAttribute(CTFontRef font, CFStringRef attribute);
    CFDictionaryRef CTFontCopyVariation(CTFontRef font);
    CFDictionaryRef CTFontCopyTraits(CTFontRef font);
    uint CTFontGetSymbolicTraits(CTFontRef font);
    bool CTFontManagerRegisterFontsForURL(CFURLRef fontURL, uint scope_, CFErrorRef* error);
    CFArrayRef CTFontManagerCopyAvailableFontFamilyNames();
    CFArrayRef CTFontManagerCreateFontDescriptorsFromURL(CFURLRef fileURL);
    CFTypeRef CTFontDescriptorCopyAttribute(CTFontDescriptorRef descriptor, CFStringRef attribute);

    CFDictionaryRef CFDictionaryCreate(const(void)* allocator, const(void)** keys, const(void)** values,
        CFIndex numValues, const(void)* keyCallBacks, const(void)* valueCallBacks);
    const(void)* CFDictionaryGetValue(CFDictionaryRef dict, const(void)* key);
    CFNumberRef CFNumberCreate(const(void)* allocator, int theType, const(void)* valuePtr);
    bool CFNumberGetValue(CFNumberRef number, int theType, void* valuePtr);
    CFURLRef CFURLCreateFromFileSystemRepresentation(const(void)* allocator, const(char)* buffer, CFIndex bufLen,
        bool isDirectory);
    bool CFURLGetFileSystemRepresentation(CFURLRef url, bool resolveAgainstBase, char* buffer, CFIndex maxBufLen);
    CFIndex CFErrorGetCode(CFErrorRef err);

    extern __gshared const CFStringRef kCTFontFamilyNameAttribute;
    extern __gshared const CFStringRef kCTFontVariationAttribute;
    extern __gshared const CFStringRef kCTFontURLAttribute;
    extern __gshared const CFStringRef kCTFontTraitsAttribute;
    extern __gshared const CFStringRef kCTFontWeightTrait;
    extern __gshared const void* kCFTypeDictionaryKeyCallBacks;
    extern __gshared const void* kCFTypeDictionaryValueCallBacks;
}

private CFDictionaryRef makeDict(const(void)*[] keys, const(void)*[] values) {
    return CFDictionaryCreate(null, keys.ptr, values.ptr, cast(CFIndex) keys.length, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
}

private string urlPath(CFURLRef url) {
    if (url is null) {
        return null;
    }
    char[4096] buf;
    if (!CFURLGetFileSystemRepresentation(url, true, buf.ptr, cast(CFIndex) buf.length)) {
        return null;
    }
    size_t n = 0;
    while (n < buf.length && buf[n] != 0) {
        n++;
    }
    return buf[0 .. n].idup;
}

private string familyOf(CTFontRef f) {
    if (f is null) {
        return null;
    }
    CFStringRef s = CTFontCopyFamilyName(f);
    if (s is null) {
        return null;
    }
    scope (exit) CFRelease(cast(CFTypeRef) s);
    return cfStringToDString(s);
}

private string fontFilePath(CTFontRef f) {
    CFTypeRef u = CTFontCopyAttribute(f, kCTFontURLAttribute);
    if (u is null) {
        return null;
    }
    scope (exit) CFRelease(u);
    return urlPath(cast(CFURLRef) u);
}

private float fontWeight(CTFontRef f) {
    CFDictionaryRef v = CTFontCopyVariation(f);
    if (v !is null) {
        scope (exit) CFRelease(cast(CFTypeRef) v);
        int tag = WGHT_AXIS_TAG;
        CFNumberRef key = CFNumberCreate(null, kCFNumberSInt32Type, &tag);
        scope (exit) CFRelease(cast(CFTypeRef) key);
        CFNumberRef val = cast(CFNumberRef) CFDictionaryGetValue(v, key);
        double w = 0.0;
        if (val !is null && CFNumberGetValue(val, kCFNumberDoubleType, &w)) {
            return cast(float) w;
        }
    }
    CFDictionaryRef traits = CTFontCopyTraits(f);
    if (traits is null) {
        return 0.0f;
    }
    scope (exit) CFRelease(cast(CFTypeRef) traits);
    CFNumberRef wt = cast(CFNumberRef) CFDictionaryGetValue(traits, kCTFontWeightTrait);
    double t = 0.0;
    if (wt is null || !CFNumberGetValue(wt, kCFNumberDoubleType, &t)) {
        return 0.0f;
    }
    if (fabs(t) < 0.05) return 400.0f;
    if (t < 0.0) return cast(float)(400.0 + t * 300.0);
    return cast(float)(400.0 + t * 500.0);
}

/**
 * CoreText-backed glyph rasterizer producing R8 coverage bitmaps in physical pixels.
 */
final class CoreTextRasterizer : IGlyphRasterizer {
    private CTFontRef[ulong] fonts_;
    private CGColorSpaceRef gray_ = null;
    private bool closed_ = false;
    private CTFontDescriptorRef[2] descriptors_;
    private FontResolution resolution_;
    private CTFontDescriptorRef[string] bundled_;
    private string[string] bundledPaths_;
    private bool[string] monoCache_;

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
        releaseFonts();
        foreach (ref d; descriptors_) {
            if (d !is null) {
                CFRelease(cast(CFTypeRef) d);
                d = null;
            }
        }
        foreach (d; bundled_.byValue()) {
            CFRelease(cast(CFTypeRef) d);
        }
        bundled_ = null;
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

    /**
     * Registers every .ttf/.otf/.ttc file in a directory with CoreText at process scope (nothing is installed
     * system-wide) and remembers their families so setFonts() resolves them before installed copies.
     *
     * Params:
     *   dir = Font directory (Contents/Resources/Fonts in the app bundle, resources/fonts in development).
     *
     * Returns:
     *   Number of font files registered (already-registered files count as registered).
     */
    size_t registerBundledFonts(string dir) {
        import std.algorithm : endsWith;
        import std.file : dirEntries, exists, isDir, SpanMode;
        import std.uni : toLower;

        size_t count = 0;
        try {
            if (closed_ || dir.length == 0 || !exists(dir) || !isDir(dir)) {
                return 0;
            }
            foreach (e; dirEntries(dir, SpanMode.shallow)) {
                immutable string lower = toLower(e.name);
                if (!e.isFile || !(lower.endsWith(".ttf") || lower.endsWith(".otf") || lower.endsWith(".ttc"))) {
                    continue;
                }
                CFURLRef url = CFURLCreateFromFileSystemRepresentation(null, e.name.ptr, cast(CFIndex) e.name.length,
                    false);
                if (url is null) {
                    continue;
                }
                scope (exit) CFRelease(cast(CFTypeRef) url);
                CFErrorRef error = null;
                bool ok = CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, &error);
                if (!ok && error !is null) {
                    ok = CFErrorGetCode(error) == kCTFontManagerErrorAlreadyRegistered;
                    CFRelease(cast(CFTypeRef) error);
                }
                if (!ok) {
                    continue;
                }
                count++;
                CFArrayRef descs = CTFontManagerCreateFontDescriptorsFromURL(url);
                if (descs is null) {
                    continue;
                }
                scope (exit) CFRelease(cast(CFTypeRef) descs);
                foreach (i; 0 .. CFArrayGetCount(descs)) {
                    CTFontDescriptorRef d = cast(CTFontDescriptorRef) CFArrayGetValueAtIndex(descs, i);
                    CFTypeRef fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute);
                    if (fam is null) {
                        continue;
                    }
                    immutable string family = cfStringToDString(cast(CFStringRef) fam);
                    CFRelease(fam);
                    if (family.length == 0 || (family in bundled_) !is null) {
                        continue;
                    }
                    CFRetain(cast(CFTypeRef) d);
                    bundled_[family] = d;
                    bundledPaths_[family] = e.name;
                }
            }
        } catch (Exception) {
        }
        return count;
    }

    /**
     * Returns the families registered by registerBundledFonts().
     *
     * Returns:
     *   Family names.
     */
    string[] bundledFamilies() const {
        return bundled_.keys;
    }

    /**
     * Selects the UI and monospace families at Regular (400) weight, flushing the per-size font cache.
     *
     * Families are resolved from bundled registrations first, then installed fonts; a family that cannot be
     * found (or a monospace family that is not fixed-pitch) falls back to the system UI / fixed-pitch font.
     *
     * Params:
     *   uiFamily = UI font family name.
     *   monoFamily = Monospace font family name.
     *
     * Returns:
     *   Resolution report (also available through resolution()).
     */
    FontResolution setFonts(string uiFamily, string monoFamily) {
        FontResolution res;
        res.requestedUi = uiFamily;
        res.requestedMono = monoFamily;
        if (closed_) {
            return res;
        }
        releaseFonts();
        foreach (ref d; descriptors_) {
            if (d !is null) {
                CFRelease(cast(CFTypeRef) d);
                d = null;
            }
        }
        resolveSlot(FontId.ui, uiFamily, res.uiFamily, res.uiFound, res.uiSource, res.uiWeight);
        resolveSlot(FontId.mono, monoFamily, res.monoFamily, res.monoFound, res.monoSource, res.monoWeight);
        resolution_ = res;
        return res;
    }

    /**
     * Returns the last setFonts() report (default system fonts before the first call).
     *
     * Returns:
     *   Resolution.
     */
    FontResolution resolution() const {
        return resolution_;
    }

    /**
     * Lists available font families (installed plus process-registered).
     *
     * Params:
     *   monospaceOnly = True to keep only fixed-pitch families.
     *
     * Returns:
     *   Sorted, de-duplicated family names (hidden "." families excluded).
     */
    string[] listFontFamilies(bool monospaceOnly) {
        import std.algorithm : sort, uniq;
        import std.array : array;

        string[] names;
        CFArrayRef arr = CTFontManagerCopyAvailableFontFamilyNames();
        if (arr !is null) {
            scope (exit) CFRelease(cast(CFTypeRef) arr);
            foreach (i; 0 .. CFArrayGetCount(arr)) {
                immutable string n = cfStringToDString(cast(CFStringRef) CFArrayGetValueAtIndex(arr, i));
                if (n.length > 0 && n[0] != '.') {
                    names ~= n;
                }
            }
        }
        names ~= bundled_.keys;
        sort(names);
        names = names.uniq.array;
        if (!monospaceOnly) {
            return names;
        }
        string[] mono;
        foreach (n; names) {
            if (isFixedPitchFamily(n)) {
                mono ~= n;
            }
        }
        return mono;
    }

    /**
     * Reports whether a family is fixed-pitch (monospace trait, or identical advances for "i", "W", "m", ".").
     *
     * Params:
     *   family = Family name.
     *
     * Returns:
     *   True for monospace families; false for proportional or unknown families.
     */
    bool isFixedPitchFamily(string family) {
        if (auto hit = family in monoCache_) {
            return *hit;
        }
        bool mono = false;
        CTFontDescriptorRef d = makeDescriptor(family);
        if (d !is null) {
            scope (exit) CFRelease(cast(CFTypeRef) d);
            CTFontRef f = CTFontCreateWithFontDescriptor(d, 16.0, null);
            if (f !is null) {
                scope (exit) CFRelease(cast(CFTypeRef) f);
                if (familyOf(f) == family) {
                    mono = (CTFontGetSymbolicTraits(f) & kCTFontTraitMonoSpace) != 0 || equalAdvances(f);
                }
            }
        }
        monoCache_[family] = mono;
        return mono;
    }

    private static bool equalAdvances(CTFontRef f) {
        immutable UniChar[4] chars = ['i', 'W', 'm', '.'];
        CGGlyph[4] glyphs;
        if (!CTFontGetGlyphsForCharacters(f, chars.ptr, glyphs.ptr, 4)) {
            return false;
        }
        CGSizeD[4] adv;
        CTFontGetAdvancesForGlyphs(f, kCTFontOrientationDefault, glyphs.ptr, adv.ptr, 4);
        foreach (i; 1 .. 4) {
            if (fabs(adv[i].width - adv[0].width) > 0.01) return false;
        }
        return adv[0].width > 0.0;
    }

    private CTFontDescriptorRef makeDescriptor(string family) {
        CFStringRef name = createCFString(family);
        if (name is null) {
            return null;
        }
        scope (exit) CFRelease(cast(CFTypeRef) name);
        int tag = WGHT_AXIS_TAG;
        double regular = 400.0;
        CFNumberRef tagNum = CFNumberCreate(null, kCFNumberSInt32Type, &tag);
        CFNumberRef wghtNum = CFNumberCreate(null, kCFNumberDoubleType, &regular);
        scope (exit) {
            CFRelease(cast(CFTypeRef) tagNum);
            CFRelease(cast(CFTypeRef) wghtNum);
        }
        const(void)*[1] vk = [tagNum];
        const(void)*[1] vv = [wghtNum];
        CFDictionaryRef variation = makeDict(vk[], vv[]);
        scope (exit) CFRelease(cast(CFTypeRef) variation);
        double zero = 0.0;
        CFNumberRef zeroNum = CFNumberCreate(null, kCFNumberDoubleType, &zero);
        scope (exit) CFRelease(cast(CFTypeRef) zeroNum);
        const(void)*[1] tk = [kCTFontWeightTrait];
        const(void)*[1] tv = [zeroNum];
        CFDictionaryRef traits = makeDict(tk[], tv[]);
        scope (exit) CFRelease(cast(CFTypeRef) traits);
        if (auto b = family in bundled_) {
            const(void)*[2] k2 = [kCTFontVariationAttribute, kCTFontTraitsAttribute];
            const(void)*[2] v2 = [variation, traits];
            CFDictionaryRef attrs = makeDict(k2[], v2[]);
            scope (exit) CFRelease(cast(CFTypeRef) attrs);
            return CTFontDescriptorCreateCopyWithAttributes(*b, attrs);
        }
        const(void)*[3] k3 = [kCTFontFamilyNameAttribute, kCTFontVariationAttribute, kCTFontTraitsAttribute];
        const(void)*[3] v3 = [name, variation, traits];
        CFDictionaryRef attrs = makeDict(k3[], v3[]);
        scope (exit) CFRelease(cast(CFTypeRef) attrs);
        return CTFontDescriptorCreateWithAttributes(attrs);
    }

    private void resolveSlot(FontId slot, string family, out string resolved, out bool found, out string source,
            out float weight) {
        CTFontDescriptorRef d = family.length > 0 ? makeDescriptor(family) : null;
        if (d !is null) {
            CTFontRef probe = CTFontCreateWithFontDescriptor(d, 16.0, null);
            bool ok = probe !is null && familyOf(probe) == family;
            if (ok && slot == FontId.mono) {
                ok = isFixedPitchFamily(family);
            }
            if (ok) {
                descriptors_[slot] = d;
                resolved = family;
                found = true;
                weight = fontWeight(probe);
                immutable string path = fontFilePath(probe);
                source = (family in bundled_) !is null ? "bundled: " ~ path : "installed: " ~ path;
                CFRelease(cast(CFTypeRef) probe);
                return;
            }
            if (probe !is null) {
                CFRelease(cast(CFTypeRef) probe);
            }
            CFRelease(cast(CFTypeRef) d);
        }
        found = false;
        CTFontRef sys = CTFontCreateUIFontForLanguage(slot == FontId.mono ? kCTFontUIFontUserFixedPitch
            : kCTFontUIFontSystem, 16.0, null);
        if (sys !is null) {
            resolved = familyOf(sys);
            weight = fontWeight(sys);
            CFRelease(cast(CFTypeRef) sys);
        }
        source = "system fallback";
    }

    private void releaseFonts() {
        foreach (f; fonts_.byValue()) {
            if (f !is null) {
                CFRelease(cast(CFTypeRef) f);
            }
        }
        fonts_ = null;
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
        CTFontRef f = null;
        immutable size_t slot = font == FontId.mono ? 1 : 0;
        if (descriptors_[slot] !is null) {
            f = CTFontCreateWithFontDescriptor(descriptors_[slot], pixelSize, null);
        }
        if (f is null) {
            immutable int uiType = font == FontId.mono ? kCTFontUIFontUserFixedPitch : kCTFontUIFontSystem;
            f = CTFontCreateUIFontForLanguage(uiType, pixelSize, null);
        }
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

unittest {
    import std.algorithm : canFind, startsWith;
    import std.file : copy, exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : baseName, buildPath;
    import std.stdio : writeln;

    import gui.appearance : DEFAULT_MONO_FONT, DEFAULT_UI_FONT;
    import gui.renderer : GlyphCache, HeadlessRenderer;

    CoreTextRasterizer r = new CoreTextRasterizer();
    scope (exit) r.close();

    FontResolution bad = r.setFonts("No Such Family 8.5", "Helvetica");
    assert(!bad.uiFound && !bad.monoFound && bad.uiSource == "system fallback" && bad.uiFamily.length > 0);
    RasterizedGlyph g;
    assert(r.rasterize(FontId.ui, 24.0f, 'A', g) && g.width > 0);
    RasterizedGlyph mi;
    RasterizedGlyph mw;
    assert(r.rasterize(FontId.mono, 24.0f, 'i', mi) && r.rasterize(FontId.mono, 24.0f, 'W', mw));
    assert(mi.advance == mw.advance);

    string[] mono = r.listFontFamilies(true);
    string[] all = r.listFontFamilies(false);
    assert(mono.length > 0 && all.length > mono.length);
    assert(!mono.canFind("Helvetica") && mono.canFind("Menlo"));
    foreach (m; mono) {
        assert(all.canFind(m));
    }

    if (!all.canFind(DEFAULT_UI_FONT) || !all.canFind(DEFAULT_MONO_FONT)) {
        writeln("SKIP coretext default-font checks: ", DEFAULT_UI_FONT, " / ", DEFAULT_MONO_FONT, " not available");
        return;
    }
    assert(mono.canFind(DEFAULT_MONO_FONT) && !mono.canFind(DEFAULT_UI_FONT));
    FontResolution res = r.setFonts(DEFAULT_UI_FONT, DEFAULT_MONO_FONT);
    assert(res.uiFound && res.monoFound, res.uiSource ~ " / " ~ res.monoSource);
    assert(res.uiFamily == DEFAULT_UI_FONT && res.monoFamily == DEFAULT_MONO_FONT);
    assert(fabs(res.uiWeight - 400.0f) < 1.0f && fabs(res.monoWeight - 400.0f) < 1.0f);
    assert(res.uiSource.startsWith("installed: ") && res.monoSource.startsWith("installed: "));
    assert(r.resolution().monoFamily == DEFAULT_MONO_FONT);

    float fileDefaultWeight = 0.0f;
    {
        immutable string path = res.monoSource["installed: ".length .. $];
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, cast(CFIndex) path.length, false);
        CFArrayRef descs = CTFontManagerCreateFontDescriptorsFromURL(url);
        assert(descs !is null && CFArrayGetCount(descs) > 0);
        CTFontRef f = CTFontCreateWithFontDescriptor(cast(CTFontDescriptorRef) CFArrayGetValueAtIndex(descs, 0), 16.0,
            null);
        fileDefaultWeight = fontWeight(f);
        CFRelease(cast(CFTypeRef) f);
        CFRelease(cast(CFTypeRef) descs);
        CFRelease(cast(CFTypeRef) url);
    }
    assert(fileDefaultWeight < 390.0f, "the variable font's default instance is lighter than Regular");

    GlyphCache cache = new GlyphCache(r);
    HeadlessRenderer hr = new HeadlessRenderer(cache);
    hr.beginFrame(100, 100, 2.0f);
    immutable float one = hr.measureText("-", FontId.mono, 12.0f);
    assert(one > 0.0f);
    foreach (s; ["---", "===", "->", "<=", "!=", "www", "C-4", ".."]) {
        assert(fabs(hr.measureText(s, FontId.mono, 12.0f) - one * s.length) < 1e-3f, s);
    }
    hr.endFrame();
    immutable size_t before = cache.glyphCount();
    immutable uint gen = cache.generation();
    cache.reset();
    assert(cache.glyphCount() == 0 && before > 0 && cache.generation() == gen + 1);

    immutable string dir = buildPath(tempDir(), "dracker_bundled_fonts_test");
    if (exists(dir)) {
        rmdirRecurse(dir);
    }
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    immutable string installed = res.monoSource["installed: ".length .. $];
    immutable string copyPath = buildPath(dir, baseName(installed));
    copy(installed, copyPath);
    CoreTextRasterizer rb = new CoreTextRasterizer();
    scope (exit) rb.close();
    assert(rb.registerBundledFonts(dir) == 1);
    assert(rb.bundledFamilies().canFind(DEFAULT_MONO_FONT));
    FontResolution br = rb.setFonts(DEFAULT_UI_FONT, DEFAULT_MONO_FONT);
    assert(br.monoFound && br.monoSource.startsWith("bundled: ") && br.monoSource.canFind(dir), br.monoSource);
    assert(fabs(br.monoWeight - 400.0f) < 1.0f && br.uiSource.startsWith("installed: "));
    assert(rb.registerBundledFonts(buildPath(dir, "missing")) == 0);
}
