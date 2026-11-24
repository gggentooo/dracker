/**
 * File:         tests/unit/gui_test.d
 * Module:       tests.unit.gui_test
 * Phase:        Phase 7.4 / 7.5 — Renderer Core, Theme, Layout Engine & Widget Toolkit Tests
 *
 * Purpose:
 *   Headless verification of the pure-D UI stack: UTF-8 decoding, shelf atlas packing, glyph cache lookup /
 *   dirty rows / growth, clip stack nesting and scissor merging, Bezier tessellation bounds, theme tokens,
 *   rectangle/flex/split-pane layout math and splitter drags, UiContext hit-testing, bubbling, capture, hover,
 *   focus traversal, double-click detection, overlays, and every widget's interaction and drawing.
 *
 * Real-Time & Safety Contract:
 *   UI-thread code exercised single-threaded through HeadlessRenderer; time is injected with a manual clock
 *   so double-click detection is deterministic.
 *
 * Dependencies:
 *   Internal: gui.{renderer,theme,layout,widgets}, graph.port, platform.interfaces
 *   External: std.math (abs, ceil, sqrt, isNaN)
 *
 * Planned API (Types, Functions & Hooks):
 *   - class FakeRasterizer : IGlyphRasterizer (fixed advance = 0.5 em, solid coverage)
 *   - class Probe : Widget (event recorder); class TestClock; class Harness (event helpers)
 *   - version(unittest) suites
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.gui_test;

version (unittest) {
    import std.math : abs, ceil, isNaN, sqrt;

    import graph.port : PortKind;
    import gui.layout;
    import gui.renderer;
    import gui.theme;
    import gui.appearance : builtinPalettes, makeTheme;
    import gui.widgets;
    import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;

    /**
     * Deterministic glyph rasterizer: advance = 0.5 * pixelSize, solid box glyphs, U+FFFF reported missing.
     */
    class FakeRasterizer : IGlyphRasterizer {
        size_t rasterizeCalls = 0;

        /**
         * Produces a solid glyph.
         *
         * Params:
         *   font = Font family.
         *   pixelSize = Size in pixels.
         *   cp = Code point.
         *   outGlyph = Receives the glyph.
         *
         * Returns:
         *   False only for U+FFFF.
         */
        override bool rasterize(FontId font, float pixelSize, dchar cp, out RasterizedGlyph outGlyph) {
            rasterizeCalls++;
            if (cp == 0xFFFF) {
                return false;
            }
            outGlyph.advance = pixelSize * 0.5f;
            if (cp == ' ') {
                return true;
            }
            outGlyph.width = cast(uint) ceil(pixelSize * 0.4f);
            outGlyph.height = cast(uint) ceil(pixelSize * 0.7f);
            outGlyph.bearingX = 0.0f;
            outGlyph.bearingY = pixelSize * 0.7f;
            outGlyph.coverage = new ubyte[cast(size_t) outGlyph.width * outGlyph.height];
            outGlyph.coverage[] = 255;
            return true;
        }

        /**
         * Reports fixed line metrics.
         *
         * Params:
         *   font = Font family.
         *   pixelSize = Size in pixels.
         *   ascent = Receives 0.8 * size.
         *   lineHeight = Receives 1.25 * size.
         */
        override void lineMetrics(FontId font, float pixelSize, out float ascent, out float lineHeight) {
            ascent = pixelSize * 0.8f;
            lineHeight = pixelSize * 1.25f;
        }
    }

    /**
     * Manually advanced clock.
     */
    final class TestClock {
        double t = 0.0;

        /**
         * Returns the current time.
         *
         * Returns:
         *   Seconds.
         */
        double now() {
            return t;
        }
    }

    /**
     * Event-recording widget with configurable handling.
     */
    class Probe : Widget {
        bool handleDown = true;
        bool handleUp = true;
        bool handleMove = true;
        bool handleKeys = false;
        bool handleScroll = false;
        bool animating = false;
        int downs = 0;
        int ups = 0;
        int moves = 0;
        int enters = 0;
        int leaves = 0;
        int gained = 0;
        int lost = 0;
        int captureLost = 0;
        int keyDowns = 0;
        int keyUps = 0;
        int texts = 0;
        int scrolls = 0;
        int magnifies = 0;
        int paints = 0;
        MouseEvent lastMouse;
        KeyEvent lastKey;
        dchar lastChar = 0;

        /**
         * Creates a probe.
         *
         * Params:
         *   b = Bounds.
         *   focus = Focusable flag.
         */
        this(RectF b, bool focus = false) {
            bounds = b;
            focusable = focus;
        }

        override bool onMouseDown(const ref MouseEvent e) {
            downs++;
            lastMouse = e;
            return handleDown;
        }

        override bool onMouseUp(const ref MouseEvent e) {
            ups++;
            lastMouse = e;
            return handleUp;
        }

        override bool onMouseMove(const ref MouseEvent e) {
            moves++;
            lastMouse = e;
            return handleMove;
        }

        override void onMouseEnter() {
            enters++;
        }

        override void onMouseLeave() {
            leaves++;
        }

        override void onFocusGained() {
            gained++;
        }

        override void onFocusLost() {
            lost++;
        }

        override void onCaptureLost() {
            captureLost++;
        }

        override bool onKeyDown(const ref KeyEvent e) {
            keyDowns++;
            lastKey = e;
            return handleKeys;
        }

        override bool onKeyUp(const ref KeyEvent e) {
            keyUps++;
            return handleKeys;
        }

        override bool onTextInput(dchar c) {
            texts++;
            lastChar = c;
            return handleKeys;
        }

        override bool onScroll(const ref ScrollEvent e) {
            scrolls++;
            return handleScroll;
        }

        override bool onMagnify(Point2F pos, float magnification) {
            magnifies++;
            return true;
        }

        override bool isAnimating() {
            return animating;
        }

        override void paint(IRenderer2D r, const ref StudioTheme theme) {
            paints++;
            r.fillRect(bounds, theme.panel);
        }
    }

    /**
     * Builds a headless renderer backed by the fake rasterizer.
     *
     * Returns:
     *   Renderer.
     */
    HeadlessRenderer makeRenderer() {
        return new HeadlessRenderer(new GlyphCache(new FakeRasterizer()));
    }

    /**
     * Approximate float equality.
     *
     * Params:
     *   a = Value.
     *   b = Expected.
     *   eps = Tolerance.
     *
     * Returns:
     *   True if |a - b| <= eps.
     */
    bool near(float a, float b, float eps = 1e-3f) {
        return abs(a - b) <= eps;
    }

    /**
     * Approximate rectangle equality.
     *
     * Params:
     *   a = Rectangle.
     *   b = Expected.
     *
     * Returns:
     *   True if all components match within 1e-3.
     */
    bool nearRect(RectF a, RectF b) {
        return near(a.x, b.x) && near(a.y, b.y) && near(a.w, b.w) && near(a.h, b.h);
    }

    /**
     * Counts instances of a kind in a draw list.
     *
     * Params:
     *   dl = Draw list.
     *   kind = Instance kind.
     *
     * Returns:
     *   Count.
     */
    size_t countKind(const(DrawList)* dl, InstanceKind kind) {
        size_t n = 0;
        foreach (ref inst; dl.instances) {
            if (inst.kind == kind) {
                n++;
            }
        }
        return n;
    }

    /**
     * Builds a platform event.
     *
     * Params:
     *   kind = Event kind.
     *   x = X.
     *   y = Y.
     *   button = Mouse button.
     *   mods = Modifiers.
     *
     * Returns:
     *   Event.
     */
    PlatformEvent pev(PlatformEventKind kind, float x = 0.0f, float y = 0.0f, ubyte button = 0, uint mods = 0) {
        PlatformEvent e;
        e.kind = kind;
        e.x = x;
        e.y = y;
        e.mouseButton = button;
        e.modifiers = mods;
        return e;
    }

    /**
     * Test harness wiring a widget tree to a UiContext, manual clock and headless renderer.
     */
    final class Harness {
        TestClock clock;
        UiContext ctx;
        HeadlessRenderer renderer;

        /**
         * Creates and lays out the harness.
         *
         * Params:
         *   root = Root widget.
         *   vp = Viewport.
         */
        this(Widget root, RectF vp = RectF(0, 0, 400, 300)) {
            clock = new TestClock();
            renderer = makeRenderer();
            ctx = new UiContext(root, &clock.now);
            ctx.layout(vp, renderer);
        }

        /**
         * Presses a button one second after the previous press (never a double-click).
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   button = Button.
         *   mods = Modifiers.
         *
         * Returns:
         *   Handled flag.
         */
        bool down(float x, float y, ubyte button = 0, uint mods = 0) {
            clock.t += 1.0;
            return ctx.handleEvent(pev(PlatformEventKind.mouseDown, x, y, button, mods));
        }

        /**
         * Presses a button 0.1 s after the previous press (double-click candidate).
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   button = Button.
         *   mods = Modifiers.
         *
         * Returns:
         *   Handled flag.
         */
        bool downQuick(float x, float y, ubyte button = 0, uint mods = 0) {
            clock.t += 0.1;
            return ctx.handleEvent(pev(PlatformEventKind.mouseDown, x, y, button, mods));
        }

        /**
         * Releases a button.
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   button = Button.
         *   mods = Modifiers.
         *
         * Returns:
         *   Handled flag.
         */
        bool up(float x, float y, ubyte button = 0, uint mods = 0) {
            return ctx.handleEvent(pev(PlatformEventKind.mouseUp, x, y, button, mods));
        }

        /**
         * Moves the pointer.
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   mods = Modifiers.
         *
         * Returns:
         *   Handled flag.
         */
        bool move(float x, float y, uint mods = 0) {
            return ctx.handleEvent(pev(PlatformEventKind.mouseMove, x, y, 0, mods));
        }

        /**
         * Clicks (press + release) at a point.
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   button = Button.
         *   mods = Modifiers.
         *
         * Returns:
         *   Press handled flag.
         */
        bool click(float x, float y, ubyte button = 0, uint mods = 0) {
            immutable bool h = down(x, y, button, mods);
            up(x, y, button, mods);
            return h;
        }

        /**
         * Double-clicks at a point.
         *
         * Params:
         *   x = X.
         *   y = Y.
         */
        void doubleClick(float x, float y) {
            down(x, y);
            up(x, y);
            downQuick(x, y);
            up(x, y);
        }

        /**
         * Drags from one point to another with a single intermediate move.
         *
         * Params:
         *   x0 = Start X.
         *   y0 = Start Y.
         *   x1 = End X.
         *   y1 = End Y.
         *   mods = Modifiers held throughout.
         */
        void drag(float x0, float y0, float x1, float y1, uint mods = 0) {
            down(x0, y0, 0, mods);
            move(x1, y1, mods);
            up(x1, y1, 0, mods);
        }

        /**
         * Sends a key press.
         *
         * Params:
         *   code = Virtual key code.
         *   mods = Modifiers.
         *
         * Returns:
         *   Handled flag.
         */
        bool key(uint code, uint mods = 0) {
            PlatformEvent e = pev(PlatformEventKind.keyDown, 0, 0, 0, mods);
            e.keyCode = code;
            return ctx.handleEvent(e);
        }

        /**
         * Sends a key release.
         *
         * Params:
         *   code = Virtual key code.
         *
         * Returns:
         *   Handled flag.
         */
        bool keyUp(uint code) {
            PlatformEvent e = pev(PlatformEventKind.keyUp);
            e.keyCode = code;
            return ctx.handleEvent(e);
        }

        /**
         * Sends committed text.
         *
         * Params:
         *   s = Characters to send one by one.
         */
        void type(dstring s) {
            foreach (c; s) {
                PlatformEvent e = pev(PlatformEventKind.textInput);
                e.utf32Char = c;
                ctx.handleEvent(e);
            }
        }

        /**
         * Sends a scroll event.
         *
         * Params:
         *   x = X.
         *   y = Y.
         *   dx = Horizontal delta.
         *   dy = Vertical delta.
         *
         * Returns:
         *   Handled flag.
         */
        bool scroll(float x, float y, float dx, float dy) {
            PlatformEvent e = pev(PlatformEventKind.mouseScroll, x, y);
            e.deltaX = dx;
            e.deltaY = dy;
            return ctx.handleEvent(e);
        }
    }

    unittest {
        size_t i = 0;
        dchar cp;
        immutable string s = "aé€😀";
        assert(decodeUtf8(s, i, cp) == 1 && cp == 'a' && i == 1);
        assert(decodeUtf8(s, i, cp) == 2 && cp == 'é' && i == 3);
        assert(decodeUtf8(s, i, cp) == 3 && cp == '€' && i == 6);
        assert(decodeUtf8(s, i, cp) == 4 && cp == '😀' && i == 10);
        assert(decodeUtf8(s, i, cp) == 0 && cp == 0xFFFD && i == 10);

        immutable string lone = "\x80z";
        i = 0;
        assert(decodeUtf8(lone, i, cp) == 1 && cp == 0xFFFD && i == 1);
        assert(decodeUtf8(lone, i, cp) == 1 && cp == 'z');

        immutable string truncated = "\xE2\x82";
        i = 0;
        assert(decodeUtf8(truncated, i, cp) == 1 && cp == 0xFFFD && i == 1);
        assert(decodeUtf8(truncated, i, cp) == 1 && cp == 0xFFFD && i == 2);

        immutable string tailTwoByte = "a\xC3";
        i = 1;
        assert(decodeUtf8(tailTwoByte, i, cp) == 1 && cp == 0xFFFD && i == 2);

        immutable string overlong = "\xC0\xAF";
        i = 0;
        assert(decodeUtf8(overlong, i, cp) == 1 && cp == 0xFFFD && i == 1);

        immutable string surrogate = "\xED\xA0\x80";
        i = 0;
        assert(decodeUtf8(surrogate, i, cp) == 1 && cp == 0xFFFD);

        immutable string tooBig = "\xF4\x90\x80\x80";
        i = 0;
        assert(decodeUtf8(tooBig, i, cp) == 1 && cp == 0xFFFD);

        immutable string badCont = "\xE2\x41\x41";
        i = 0;
        assert(decodeUtf8(badCont, i, cp) == 1 && cp == 0xFFFD && i == 1);
        assert(decodeUtf8(badCont, i, cp) == 1 && cp == 'A');

        immutable string invalidLead = "\xFF";
        i = 0;
        assert(decodeUtf8(invalidLead, i, cp) == 1 && cp == 0xFFFD && i == 1);

        immutable string maxCp = "\xF4\x8F\xBF\xBF";
        i = 0;
        assert(decodeUtf8(maxCp, i, cp) == 4 && cp == 0x10FFFF);
    }

    unittest {
        ShelfAtlasPacker p;
        p.reset(16, 16);
        uint x, y;
        assert(p.pack(4, 4, x, y) && x == 1 && y == 1);
        assert(p.pack(4, 4, x, y) && x == 6 && y == 1);
        assert(p.pack(4, 4, x, y) && x == 11 && y == 1);
        assert(p.pack(4, 4, x, y) && x == 1 && y == 6);
        assert(p.pack(4, 8, x, y) && x == 6 && y == 6);
        assert(!p.pack(15, 1, x, y));
        assert(!p.pack(10, 4, x, y));
        p.growHeight(8);
        assert(p.height == 16);
        p.growHeight(32);
        assert(p.height == 32 && p.width == 16);
        assert(p.pack(10, 4, x, y) && x == 1 && y == 15);
        assert(p.pack(14, 2, x, y) && x == 1 && y == 20);
        p.reset(32, 32);
        assert(p.pack(30, 30, x, y) && x == 1 && y == 1);
        assert(!p.pack(1, 1, x, y));

        p.reset(16, 12);
        assert(p.pack(6, 4, x, y) && x == 1 && y == 1);
        assert(!p.pack(12, 8, x, y));
        assert(p.pack(6, 4, x, y) && x == 8 && y == 1);
    }

    unittest {
        auto fake = new FakeRasterizer();
        auto cache = new GlyphCache(fake);
        assert(cache.atlasWidth() == GlyphCache.ATLAS_WIDTH && cache.atlasHeight() == GlyphCache.INITIAL_HEIGHT);
        assert(cache.generation() == 1);
        uint minY, maxY;
        assert(!cache.takeDirtyRows(minY, maxY));

        AtlasGlyph g;
        assert(cache.lookup(FontId.ui, 20.0f, 'A', g));
        assert(g.width == 8 && g.height == 14 && near(g.advance, 10.0f));
        assert(g.atlasX == 1 && g.atlasY == 1);
        assert(cache.glyphCount() == 1 && fake.rasterizeCalls == 1);
        assert(cache.pixels()[cast(size_t) g.atlasY * cache.atlasWidth() + g.atlasX] == 255);
        assert(cache.pixels()[0] == 0);
        assert(cache.takeDirtyRows(minY, maxY) && minY == 1 && maxY == 15);
        assert(!cache.takeDirtyRows(minY, maxY));

        AtlasGlyph again;
        assert(cache.lookup(FontId.ui, 20.2f, 'A', again));
        assert(again == g && fake.rasterizeCalls == 1 && cache.glyphCount() == 1);
        assert(cache.lookup(FontId.mono, 20.0f, 'A', again));
        assert(cache.glyphCount() == 2 && fake.rasterizeCalls == 2);
        assert(again.atlasX == g.atlasX + g.width + 1);

        AtlasGlyph sp;
        assert(cache.lookup(FontId.ui, 20.0f, ' ', sp));
        assert(sp.width == 0 && near(sp.advance, 10.0f));
        assert(cache.takeDirtyRows(minY, maxY) && minY == 1 && maxY == 15);
        assert(!cache.takeDirtyRows(minY, maxY));

        AtlasGlyph miss;
        immutable size_t callsBefore = fake.rasterizeCalls;
        assert(!cache.lookup(FontId.ui, 20.0f, cast(dchar) 0xFFFF, miss));
        assert(!cache.lookup(FontId.ui, 20.0f, cast(dchar) 0xFFFF, miss));
        assert(fake.rasterizeCalls == callsBefore + 1);

        float ascent, lh;
        cache.lineMetrics(FontId.ui, 20.0f, ascent, lh);
        assert(near(ascent, 16.0f) && near(lh, 25.0f));

        auto nullCache = new GlyphCache(null);
        assert(!nullCache.lookup(FontId.ui, 12.0f, 'x', miss));
        nullCache.lineMetrics(FontId.ui, 10.0f, ascent, lh);
        assert(near(ascent, 8.0f) && near(lh, 12.0f));
    }

    unittest {
        auto fake = new FakeRasterizer();
        auto cache = new GlyphCache(fake);
        AtlasGlyph first;
        assert(cache.lookup(FontId.ui, 200.0f, 'A', first));
        uint minY, maxY;
        cache.takeDirtyRows(minY, maxY);
        foreach (k; 1 .. 60) {
            AtlasGlyph g;
            assert(cache.lookup(FontId.ui, 200.0f, cast(dchar)('A' + k), g));
            assert(g.atlasY + g.height <= cache.atlasHeight());
        }
        assert(cache.atlasHeight() > GlyphCache.INITIAL_HEIGHT);
        assert(cache.generation() > 1);
        assert(cache.pixels().length == cast(size_t) cache.atlasWidth() * cache.atlasHeight());
        assert(cache.takeDirtyRows(minY, maxY) && minY == 0 && maxY == cache.atlasHeight());
        AtlasGlyph check;
        assert(cache.lookup(FontId.ui, 200.0f, 'A', check) && check == first);
        assert(cache.pixels()[cast(size_t)(first.atlasY + first.height - 1) * cache.atlasWidth() + first.atlasX + first.width - 1] == 255);
        assert(cache.glyphCount() == 60);
    }

    unittest {
        auto r = makeRenderer();
        r.beginFrame(200.0f, 100.0f, 2.0f);
        assert(r.clipDepth() == 1);
        assert(nearRect(r.currentClip(), RectF(0, 0, 200, 100)));
        auto dl = r.lastDrawList();
        assert(dl.framebufferWidth == 400 && dl.framebufferHeight == 200 && near(dl.scaleFactor, 2.0f));

        r.fillRect(RectF(0, 0, 10, 10), ColorRGBA(1, 0, 0, 1));
        r.fillRect(RectF(20, 0, 10, 10), ColorRGBA(1, 0, 0, 1));
        assert(dl.commands.length == 1 && dl.commands[0].instanceCount == 2);
        assert(dl.commands[0].scissor == ScissorRect(0, 0, 400, 200));

        r.pushClip(RectF(10, 10, 100, 50));
        r.pushClip(RectF(50, 0, 100, 100));
        assert(r.clipDepth() == 3);
        assert(nearRect(r.currentClip(), RectF(50, 10, 60, 50)));
        r.fillRect(RectF(60, 20, 10, 10), ColorRGBA(0, 1, 0, 1));
        assert(dl.commands.length == 2);
        assert(dl.commands[1].scissor == ScissorRect(100, 20, 120, 100));
        assert(dl.instances[2].rect == [120.0f, 40.0f, 20.0f, 20.0f]);

        r.fillRect(RectF(0, 80, 10, 10), ColorRGBA(0, 1, 0, 1));
        assert(dl.instances.length == 3);

        r.popClip();
        assert(nearRect(r.currentClip(), RectF(10, 10, 100, 50)));
        r.fillRect(RectF(15, 15, 5, 5), ColorRGBA(0, 0, 1, 1));
        assert(dl.commands.length == 3 && dl.commands[2].scissor == ScissorRect(20, 20, 200, 100));
        r.popClip();
        r.popClip();
        r.popClip();
        assert(r.clipDepth() == 1);
        r.fillRect(RectF(100, 50, 5, 5), ColorRGBA(0, 0, 1, 1));
        assert(dl.commands.length == 4 && dl.commands[3].scissor == ScissorRect(0, 0, 400, 200));
        r.fillRect(RectF(110, 50, 5, 5), ColorRGBA(0, 0, 1, 1));
        assert(dl.commands.length == 4 && dl.commands[3].instanceCount == 2);

        r.pushClip(RectF(300, 300, 10, 10));
        assert(r.currentClip().isEmpty());
        immutable size_t before = dl.instances.length;
        r.fillRect(RectF(0, 0, 400, 400), ColorRGBA(1, 1, 1, 1));
        r.drawLine(Point2F(0, 0), Point2F(50, 50), 2.0f, ColorRGBA(1, 1, 1, 1));
        assert(dl.instances.length == before);
        r.popClip();

        r.strokeRoundedRect(RectF(10, 10, 20, 20), 4.0f, 0.0f, ColorRGBA(1, 1, 1, 1));
        assert(dl.instances.length == before);
        r.strokeRoundedRect(RectF(10, 10, 20, 20), 40.0f, 1.0f, ColorRGBA(1, 1, 1, 1));
        assert(dl.instances.length == before + 1);
        assert(near(dl.instances[$ - 1].cornerRadius, 20.0f) && near(dl.instances[$ - 1].borderWidth, 2.0f));

        immutable size_t frames = r.submittedFrames;
        r.endFrame();
        assert(r.submittedFrames == frames + 1);
        r.endFrame();
        assert(r.submittedFrames == frames + 1);

        r.beginFrame(50.0f, 50.0f, 1.0f);
        assert(r.lastDrawList().instances.length == 0 && r.lastDrawList().commands.length == 0);
        foreach (k; 0 .. 70) {
            r.pushClip(RectF(k, 0, 50 - k * 0.5f, 50));
        }
        assert(r.clipDepth() == 71);
        foreach (k; 0 .. 69) {
            r.popClip();
        }
        assert(r.clipDepth() == 2);
        assert(r.currentClip() == RectF(0, 0, 50, 50));
        r.popClip();
        r.popClip();
        assert(r.clipDepth() == 1);
        r.endFrame();
    }

    unittest {
        auto r = makeRenderer();
        r.beginFrame(100.0f, 100.0f, 1.0f);
        immutable uint tex = r.createTextureRGBA(2, 2, new ubyte[16]);
        assert(tex != 0);
        assert(r.createTextureRGBA(2, 2, new ubyte[15]) == 0);
        r.drawImage(tex, RectF(0, 0, 10, 10), RectF(0, 0, 1, 1), ColorRGBA(1, 1, 1, 1));
        r.fillRect(RectF(0, 0, 5, 5), ColorRGBA(1, 1, 1, 1));
        auto dl = r.lastDrawList();
        assert(dl.commands.length == 2 && dl.commands[0].textureId == tex && dl.commands[1].textureId == 0);
        assert(r.updateTextureRGBA(tex, new ubyte[16]));
        r.destroyTexture(tex);
        assert(!r.updateTextureRGBA(tex, new ubyte[16]));
        r.drawImage(0, RectF(0, 0, 10, 10), RectF(0, 0, 1, 1), ColorRGBA(1, 1, 1, 1));
        assert(dl.instances.length == 2);

        assert(near(r.measureText("abc", FontId.ui, 10.0f), 15.0f));
        assert(near(r.lineHeight(FontId.ui, 10.0f), 12.5f));
        r.drawText(Point2F(10, 10), "a b", FontId.ui, 10.0f, ColorRGBA(1, 1, 1, 1));
        assert(countKind(dl, InstanceKind.glyph) == 2);
        r.drawText(Point2F(10, 10), "\xFF", FontId.ui, 10.0f, ColorRGBA(1, 1, 1, 1));
        assert(countKind(dl, InstanceKind.glyph) == 3);
        r.endFrame();

        r.beginFrame(100.0f, 100.0f, 2.0f);
        assert(near(r.measureText("abc", FontId.ui, 10.0f), 15.0f));
        assert(near(r.lineHeight(FontId.ui, 10.0f), 12.5f));
        r.endFrame();

        auto bare = new HeadlessRenderer();
        bare.beginFrame(10.0f, 10.0f, 1.0f);
        assert(bare.measureText("abc", FontId.ui, 10.0f) == 0.0f);
        assert(near(bare.lineHeight(FontId.ui, 10.0f), 12.0f));
        bare.drawText(Point2F(0, 0), "abc", FontId.ui, 10.0f, ColorRGBA(1, 1, 1, 1));
        assert(bare.lastDrawList().instances.length == 0);
        bare.endFrame();
    }

    unittest {
        immutable Point2F o = Point2F(5, 5);
        assert(bezierSegmentCount(o, o, o, o, 1.0f) == 4);
        assert(bezierSegmentCount(Point2F(0, 0), Point2F(200, 0), Point2F(400, 0), Point2F(600, 0), 1.0f) == 100);
        assert(bezierSegmentCount(Point2F(0, 0), Point2F(100, 0), Point2F(200, 0), Point2F(300, 0), 2.0f) == 100);
        assert(bezierSegmentCount(Point2F(0, 0), Point2F(1e5f, 0), Point2F(2e5f, 0), Point2F(3e5f, 0), 1.0f) == 256);
        assert(bezierSegmentCount(Point2F(float.nan, 0), o, o, o, 1.0f) == 4);
        assert(bezierSegmentCount(Point2F(float.infinity, 0), o, o, o, 1.0f) == 4);
        immutable Point2F e0 = evalCubic(Point2F(0, 0), Point2F(0, 10), Point2F(10, 10), Point2F(10, 0), 0.0f);
        immutable Point2F e1 = evalCubic(Point2F(0, 0), Point2F(0, 10), Point2F(10, 10), Point2F(10, 0), 1.0f);
        immutable Point2F em = evalCubic(Point2F(0, 0), Point2F(0, 10), Point2F(10, 10), Point2F(10, 0), 0.5f);
        assert(e0 == Point2F(0, 0) && e1 == Point2F(10, 0) && near(em.x, 5.0f) && near(em.y, 7.5f));

        auto r = makeRenderer();
        r.beginFrame(800.0f, 100.0f, 1.0f);
        r.drawBezier(Point2F(0, 50), Point2F(200, 50), Point2F(400, 50), Point2F(600, 50), 2.0f, ColorRGBA(1, 1, 1, 1));
        assert(countKind(r.lastDrawList(), InstanceKind.line) == 100);
        r.drawPolyline([Point2F(0, 0)], 2.0f, ColorRGBA(1, 1, 1, 1));
        r.drawLine(Point2F(0, 0), Point2F(10, 10), 2.0f, ColorRGBA(1, 1, 1, 0));
        r.drawLine(Point2F(float.nan, 0), Point2F(10, 10), 2.0f, ColorRGBA(1, 1, 1, 1));
        assert(countKind(r.lastDrawList(), InstanceKind.line) == 100);
        r.endFrame();
    }

    unittest {
        immutable StudioTheme t = StudioTheme.light();
        assert(t == StudioTheme.init && t.isLight && t.contrast == ContrastMode.high);
        assert(t.wireColor(WireKind.audio) == t.wireAudio);
        assert(t.wireColor(WireKind.sidechain) == t.wireSidechain);
        assert(t.wireColor(WireKind.event) == t.wireEvent);
        assert(t.wireColor(WireKind.cv) == t.wireCv);
        assert(t.portColor(PortKind.audioStereo) == t.wireAudio);
        assert(t.portColor(PortKind.audioMono) == t.wireAudio);
        assert(t.portColor(PortKind.sidechainStereo) == t.wireSidechain);
        assert(t.portColor(PortKind.event) == t.wireEvent);
        assert(t.portColor(PortKind.cvControl) == t.wireCv);
        assert(wireKindOf(PortKind.cvControl) == WireKind.cv);
        assert(t.wireAudio != t.wireCv && t.wireEvent != t.wireSidechain && t.accent != t.danger);
        assert(t.background != t.panel && t.text != t.textDim);
        assert(t.spacing(0) == 0.0f && t.spacing(1) == t.spacingXs && t.spacing(3) == t.spacingMd);
        assert(t.spacing(5) == t.spacingXl && t.spacing(99) == t.spacingXl);
        assert(t.spacingXs < t.spacingSm && t.spacingSm < t.spacingMd && t.spacingMd < t.spacingLg && t.spacingLg < t.spacingXl);
        immutable StudioTheme big = t.scaled(2.0f);
        assert(near(big.fontSizeBody, t.fontSizeBody * 2.0f) && near(big.spacingMd, t.spacingMd * 2.0f));
        assert(near(big.scrollbarThickness, t.scrollbarThickness * 2.0f) && near(big.radiusLg, t.radiusLg * 2.0f));
        assert(big.accent == t.accent && big.wireCv == t.wireCv);
        assert(t.scaled(-1.0f) == t && t.scaled(float.nan) == t && t.scaled(float.infinity) == t);
        assert(t.text.a == 1.0f && t.background.r > t.text.r);
    }

    unittest {
        assert(clampf(5, 0, 10) == 5 && clampf(-1, 0, 10) == 0 && clampf(11, 0, 10) == 10);
        assert(clampf(float.nan, 2, 10) == 2 && clampf(5, 3, 1) == 3);

        immutable Insets ins = Insets(1, 2, 3, 4);
        assert(nearRect(ins.apply(RectF(0, 0, 10, 10)), RectF(1, 2, 6, 4)));
        assert(nearRect(Insets.all(20).apply(RectF(0, 0, 10, 10)), RectF(20, 20, 0, 0)));
        assert(Insets.symmetric(3, 5) == Insets(3, 5, 3, 5));
        assert(ins.along(Axis.horizontal) == 4 && ins.along(Axis.vertical) == 6);

        RectF r = RectF(0, 0, 100, 50);
        assert(nearRect(takeLeft(r, 20), RectF(0, 0, 20, 50)) && nearRect(r, RectF(20, 0, 80, 50)));
        assert(nearRect(takeRight(r, 30), RectF(70, 0, 30, 50)) && nearRect(r, RectF(20, 0, 50, 50)));
        assert(nearRect(takeTop(r, 10), RectF(20, 0, 50, 10)) && nearRect(r, RectF(20, 10, 50, 40)));
        assert(nearRect(takeBottom(r, 15), RectF(20, 35, 50, 15)) && nearRect(r, RectF(20, 10, 50, 25)));
        assert(nearRect(takeLeft(r, 500), RectF(20, 10, 50, 25)) && r.w == 0);
        RectF r2 = RectF(0, 0, 10, 10);
        assert(nearRect(takeTop(r2, -5), RectF(0, 0, 10, 0)) && nearRect(r2, RectF(0, 0, 10, 10)));

        RectF a, b;
        splitRect(RectF(0, 0, 110, 20), Axis.horizontal, 0.25f, 10.0f, a, b);
        assert(nearRect(a, RectF(0, 0, 25, 20)) && nearRect(b, RectF(35, 0, 75, 20)));
        splitRect(RectF(0, 0, 20, 100), Axis.vertical, float.nan, 0.0f, a, b);
        assert(nearRect(a, RectF(0, 0, 20, 50)) && nearRect(b, RectF(0, 50, 20, 50)));
        splitRect(RectF(0, 0, 100, 10), Axis.horizontal, 2.0f, 200.0f, a, b);
        assert(a.w == 0 && b.w == 0);

        assert(nearRect(centeredRect(RectF(0, 0, 100, 50), 20, 10), RectF(40, 20, 20, 10)));
        assert(nearRect(centeredRect(RectF(0, 0, 100, 50), 200, 10), RectF(0, 20, 100, 10)));
        assert(nearRect(clampRectInside(RectF(90, 90, 20, 20), RectF(0, 0, 100, 100)), RectF(80, 80, 20, 20)));
        assert(nearRect(clampRectInside(RectF(-5, 10, 20, 20), RectF(0, 0, 100, 100)), RectF(0, 10, 20, 20)));
        assert(nearRect(clampRectInside(RectF(10, 10, 300, 20), RectF(0, 0, 100, 100)), RectF(0, 10, 100, 20)));
    }

    unittest {
        FlexItem[] items = [FlexItem.fixedSize(50), FlexItem.weighted(1), FlexItem.weighted(2)];
        auto rects = layoutFlex(RectF(0, 0, 300, 50), items, Axis.horizontal, 10.0f, Insets.all(5));
        assert(rects.length == 3);
        assert(nearRect(rects[0], RectF(5, 5, 50, 40)));
        assert(nearRect(rects[1], RectF(65, 5, 220.0f / 3.0f, 40)));
        assert(nearRect(rects[2], RectF(65 + 220.0f / 3.0f + 10, 5, 440.0f / 3.0f, 40)));
        assert(near(rects[2].right(), 295.0f));

        auto minClamp = layoutFlex(RectF(0, 0, 200, 10), [FlexItem.weighted(1, 150), FlexItem.weighted(1)], Axis.horizontal);
        assert(near(minClamp[0].w, 150) && near(minClamp[1].w, 50) && near(minClamp[1].x, 150));

        auto maxClamp = layoutFlex(RectF(0, 0, 200, 10), [FlexItem.weighted(1, 0, 40), FlexItem.weighted(1)], Axis.horizontal);
        assert(near(maxClamp[0].w, 40) && near(maxClamp[1].w, 160));

        auto cascade = layoutFlex(RectF(0, 0, 100, 10),
            [FlexItem.weighted(1, 0, 10), FlexItem.weighted(1, 0, 10), FlexItem.weighted(1)], Axis.horizontal);
        assert(near(cascade[0].w, 10) && near(cascade[1].w, 10) && near(cascade[2].w, 80));

        auto overflow = layoutFlex(RectF(0, 0, 150, 10), [FlexItem.fixedSize(100), FlexItem.weighted(1, 80)], Axis.horizontal);
        assert(near(overflow[0].w, 100) && near(overflow[1].w, 80) && near(overflow[1].x, 100));

        auto fixedMin = layoutFlex(RectF(0, 0, 100, 10), [FlexItem.fixedSize(5), FlexItem(0.0f, 0.0f, 30.0f)], Axis.horizontal);
        FlexItem clampedFixed = FlexItem.fixedSize(5);
        clampedFixed.minSize = 12;
        auto fm = layoutFlex(RectF(0, 0, 100, 10), [clampedFixed], Axis.horizontal);
        assert(near(fixedMin[0].w, 5) && near(fixedMin[1].w, 30) && near(fm[0].w, 12));

        auto col = layoutFlex(RectF(10, 20, 40, 100), [FlexItem.fixedSize(20), FlexItem.weighted(1)], Axis.vertical, 4.0f);
        assert(nearRect(col[0], RectF(10, 20, 40, 20)) && nearRect(col[1], RectF(10, 44, 40, 76)));

        assert(layoutFlex(RectF(0, 0, 10, 10), [], Axis.horizontal).length == 0);

        RectF[3] buf;
        layoutFlexInto(RectF(0, 0, 90, 10), [FlexItem.weighted(1), FlexItem.weighted(1), FlexItem.weighted(1)],
            Axis.horizontal, 0.0f, Insets.init, buf[]);
        assert(near(buf[0].w, 30) && near(buf[1].x, 30) && near(buf[2].x, 60));

        auto squeezed = layoutFlex(RectF(0, 0, 10, 10), [FlexItem.weighted(1), FlexItem.weighted(1)], Axis.horizontal, 20.0f);
        assert(squeezed[0].w == 0 && squeezed[1].w == 0);
    }

    unittest {
        auto browser = SplitPaneNode.leaf("browser");
        auto editor = SplitPaneNode.leaf("editor");
        auto mixer = SplitPaneNode.leaf("mixer");
        auto right = SplitPaneNode.split(Axis.vertical, editor, mixer, 0.5f, 50, 50, 4);
        auto root = SplitPaneNode.split(Axis.horizontal, browser, right, 0.25f, 100, 100, 4);
        assert(!root.isLeaf() && browser.isLeaf() && editor.parent is right && right.parent is root);
        root.arrange(RectF(0, 0, 404, 304));
        assert(nearRect(browser.bounds, RectF(0, 0, 100, 304)));
        assert(nearRect(root.splitterRect, RectF(100, 0, 4, 304)));
        assert(nearRect(right.bounds, RectF(104, 0, 300, 304)));
        assert(nearRect(editor.bounds, RectF(104, 0, 300, 150)));
        assert(nearRect(right.splitterRect, RectF(104, 150, 300, 4)));
        assert(nearRect(mixer.bounds, RectF(104, 154, 300, 150)));
        assert(near(root.availableLength(), 400.0f) && near(root.firstLength(), 100.0f));

        assert(root.leafAt(Point2F(50, 50)) is browser);
        assert(root.leafAt(Point2F(200, 100)) is editor);
        assert(root.leafAt(Point2F(200, 200)) is mixer);
        assert(root.leafAt(Point2F(101, 50)) is null);
        assert(root.leafAt(Point2F(500, 50)) is null);
        assert(root.findLeaf("mixer") is mixer && root.findLeaf("nope") is null);
        auto leaves = root.leaves();
        assert(leaves.length == 3 && leaves[0] is browser && leaves[1] is editor && leaves[2] is mixer);
        SplitPaneNode[] splits;
        root.collectSplits(splits);
        assert(splits.length == 2 && splits[0] is root && splits[1] is right);

        assert(root.splitterAt(Point2F(101, 50)) is root);
        assert(root.splitterAt(Point2F(99, 50), 2.0f) is root);
        assert(root.splitterAt(Point2F(97, 50), 2.0f) is null);
        assert(root.splitterAt(Point2F(200, 152)) is right);
        assert(root.splitterAt(Point2F(200, 100)) is null);
        assert(browser.splitterAt(Point2F(50, 50)) is null);

        root.ratio = 0.05f;
        root.arrange(RectF(0, 0, 404, 304));
        assert(near(browser.bounds.w, 100.0f));
        root.ratio = 0.99f;
        root.arrange(RectF(0, 0, 404, 304));
        assert(near(browser.bounds.w, 300.0f) && near(right.bounds.w, 100.0f));
        root.ratio = float.nan;
        root.arrange(RectF(0, 0, 404, 304));
        assert(near(browser.bounds.w, 200.0f));

        auto tight = SplitPaneNode.split(Axis.horizontal, SplitPaneNode.leaf("a"), SplitPaneNode.leaf("b"), 0.9f, 300, 100, 4);
        tight.arrange(RectF(0, 0, 204, 50));
        assert(near(tight.first.bounds.w, 150.0f) && near(tight.second.bounds.w, 50.0f));
        tight.arrange(RectF(0, 0, 2, 50));
        assert(tight.first.bounds.w == 0 && tight.second.bounds.w == 0 && near(tight.splitterRect.w, 2.0f));

        auto vsplit = SplitPaneNode.split(Axis.vertical, SplitPaneNode.leaf("t"), SplitPaneNode.leaf("b"), 0.5f, 10, 10, 2);
        vsplit.arrange(RectF(0, 0, 50, 102));
        vsplit.setFirstLength(70);
        assert(near(vsplit.ratio, 0.7f) && near(vsplit.first.bounds.h, 70.0f) && near(vsplit.second.bounds.y, 72.0f));
        vsplit.setFirstLength(-50);
        assert(near(vsplit.first.bounds.h, 10.0f));
        vsplit.setFirstLength(1000);
        assert(near(vsplit.first.bounds.h, 90.0f) && near(vsplit.second.bounds.h, 10.0f));
    }

    unittest {
        auto right = SplitPaneNode.split(Axis.vertical, SplitPaneNode.leaf("editor"), SplitPaneNode.leaf("mixer"), 0.5f, 50, 50, 4);
        auto dock = new DockLayout(SplitPaneNode.split(Axis.horizontal, SplitPaneNode.leaf("browser"), right, 0.25f, 100, 100, 4));
        dock.arrange(RectF(0, 0, 404, 304));
        assert(nearRect(dock.leafBounds("browser"), RectF(0, 0, 100, 304)));
        assert(dock.leafBounds("missing") == RectF.init);
        assert(dock.leafAt(Point2F(10, 10)).id == "browser");
        assert(dock.findLeaf("editor") !is null && dock.leaves().length == 3);
        assert(!dock.isDragging() && !dock.dragTo(Point2F(0, 0)));
        assert(!dock.beginDrag(Point2F(50, 50)));

        assert(dock.splitterAt(Point2F(102, 50)) is dock.root);
        assert(dock.beginDrag(Point2F(102, 50)) && dock.isDragging() && dock.draggingNode() is dock.root);
        assert(dock.dragTo(Point2F(202, 50)));
        assert(nearRect(dock.leafBounds("browser"), RectF(0, 0, 200, 304)));
        assert(nearRect(dock.leafBounds("editor"), RectF(204, 0, 200, 150)));
        assert(near(dock.root.ratio, 0.5f));
        dock.dragTo(Point2F(10, 50));
        assert(near(dock.leafBounds("browser").w, 100.0f));
        dock.dragTo(Point2F(400, 50));
        assert(near(dock.leafBounds("browser").w, 300.0f) && near(dock.leafBounds("mixer").w, 100.0f));
        dock.endDrag();
        assert(!dock.isDragging());

        assert(dock.beginDrag(Point2F(350, 151)));
        assert(dock.draggingNode() is right);
        dock.dragTo(Point2F(350, 251));
        assert(near(dock.leafBounds("editor").h, 250.0f) && near(dock.leafBounds("mixer").y, 254.0f));
        dock.dragTo(Point2F(350, 1));
        assert(near(dock.leafBounds("editor").h, 50.0f));
        dock.endDrag();

        dock.arrange(RectF(0, 0, 804, 304));
        assert(near(dock.leafBounds("browser").w, 600.0f));
    }

    unittest {
        auto bottom = SplitPaneNode.leaf("bottom");
        auto middle = SplitPaneNode.leaf("middle");
        auto lower = SplitPaneNode.split(Axis.vertical, middle, bottom, 0.1685f, 48, 180, 4);
        auto top = SplitPaneNode.leaf("top");
        auto dock = new DockLayout(SplitPaneNode.split(Axis.vertical, top, lower, 0.4518f, 180, 232, 4));
        dock.arrange(RectF(0, 0, 400, 834));
        immutable RectF top0 = top.bounds;
        immutable RectF mid0 = middle.bounds;
        immutable RectF bot0 = bottom.bounds;
        assert(near(top0.h + 4.0f + mid0.h + 4.0f + bot0.h, 834.0f));

        immutable float topSplitY = dock.root.splitterRect.y + 2.0f;
        assert(dock.beginDrag(Point2F(100, topSplitY)) && dock.draggingNode() is dock.root);
        dock.dragTo(Point2F(100, topSplitY + 20.0f));
        assert(near(top.bounds.h, top0.h + 20.0f));
        assert(near(middle.bounds.h, mid0.h - 20.0f));
        assert(near(bottom.bounds.y, bot0.y) && near(bottom.bounds.h, bot0.h));

        dock.dragTo(Point2F(100, topSplitY + 500.0f));
        assert(near(middle.bounds.h, 48.0f));
        assert(near(bottom.bounds.y, bot0.y) && near(bottom.bounds.h, bot0.h));

        dock.dragTo(Point2F(100, topSplitY - 500.0f));
        assert(near(top.bounds.h, 180.0f));
        assert(near(bottom.bounds.y, bot0.y) && near(bottom.bounds.h, bot0.h));
        dock.endDrag();

        dock.arrange(RectF(0, 0, 400, 834));
        immutable RectF top1 = top.bounds;
        immutable RectF mid1 = middle.bounds;
        immutable RectF bot1 = bottom.bounds;
        immutable float botSplitY = lower.splitterRect.y + 2.0f;
        assert(dock.beginDrag(Point2F(100, botSplitY)) && dock.draggingNode() is lower);
        dock.dragTo(Point2F(100, botSplitY + 30.0f));
        assert(near(top.bounds.h, top1.h));
        assert(near(middle.bounds.h, mid1.h + 30.0f));
        assert(near(bottom.bounds.h, bot1.h - 30.0f));
        dock.endDrag();

        auto leftA = SplitPaneNode.leaf("a");
        auto midB = SplitPaneNode.leaf("b");
        auto rightC = SplitPaneNode.leaf("c");
        auto leftPair = SplitPaneNode.split(Axis.horizontal, leftA, midB, 0.5f, 50, 50, 4);
        auto hdock = new DockLayout(SplitPaneNode.split(Axis.horizontal, leftPair, rightC, 0.6f, 104, 80, 4));
        hdock.arrange(RectF(0, 0, 504, 100));
        immutable RectF a0 = leftA.bounds;
        immutable RectF b0 = midB.bounds;
        immutable RectF c0 = rightC.bounds;
        immutable float splitX = hdock.root.splitterRect.x + 2.0f;
        assert(hdock.beginDrag(Point2F(splitX, 50)) && hdock.draggingNode() is hdock.root);
        hdock.dragTo(Point2F(splitX + 25.0f, 50));
        assert(near(leftA.bounds.w, a0.w));
        assert(near(midB.bounds.w, b0.w + 25.0f));
        assert(near(rightC.bounds.w, c0.w - 25.0f));
        hdock.endDrag();
    }

    unittest {
        auto root = new Panel();
        auto a = root.add(new Probe(RectF(0, 0, 100, 100)));
        auto b = root.add(new Probe(RectF(50, 50, 100, 100)));
        auto label = root.add(new Label("hi"));
        label.bounds = RectF(200, 0, 50, 20);
        auto h = new Harness(root);
        assert(root.children().length == 3 && a.parent() is root);
        assert(h.ctx.hitTest(Point2F(75, 75)) is b);
        assert(h.ctx.hitTest(Point2F(25, 25)) is a);
        assert(h.ctx.hitTest(Point2F(210, 5)) is root);
        assert(h.ctx.hitTest(Point2F(399, 299)) is root);
        assert(h.ctx.hitTest(Point2F(500, 500)) is null);
        b.visible = false;
        assert(h.ctx.hitTest(Point2F(75, 75)) is a);
        b.visible = true;

        auto overlay = new Probe(RectF(60, 60, 30, 30));
        h.ctx.openOverlay(overlay);
        assert(h.ctx.isOverlayOpen(overlay) && h.ctx.overlays().length == 1);
        assert(h.ctx.hitTest(Point2F(70, 70)) is overlay);
        assert(h.ctx.hitTest(Point2F(120, 120)) is b);
        assert(overlay.context() is h.ctx);
        assert(h.ctx.closeOverlay(overlay) && !h.ctx.closeOverlay(overlay));
        assert(overlay.context() is null);

        assert(root.remove(b) && !root.remove(b) && b.parent() is null);
        assert(h.ctx.hitTest(Point2F(120, 120)) is root);
        root.clearChildren();
        assert(root.children().length == 0);
    }

    unittest {
        auto root = new Panel();
        auto outer = root.add(new Probe(RectF(0, 0, 200, 200)));
        auto inner = outer.add(new Probe(RectF(10, 10, 50, 50)));
        inner.handleDown = false;
        auto h = new Harness(root);
        assert(h.down(20, 20));
        assert(inner.downs == 1 && outer.downs == 1);
        assert(h.ctx.captured() is outer);
        h.up(20, 20);
        assert(outer.ups == 1 && inner.ups == 0 && h.ctx.captured() is null);

        inner.enabled = false;
        h.down(20, 20);
        assert(inner.downs == 1 && outer.downs == 2);
        h.up(20, 20);
        inner.enabled = true;

        outer.enabled = false;
        assert(!h.down(20, 20));
        assert(inner.downs == 1);
        h.up(20, 20);
        outer.enabled = true;

        PlatformEvent mag = pev(PlatformEventKind.magnify, 20, 20);
        mag.magnification = 0.1f;
        assert(h.ctx.handleEvent(mag) && inner.magnifies == 1);
        inner.handleScroll = false;
        outer.handleScroll = true;
        assert(h.scroll(20, 20, 0, 5) && inner.scrolls == 1 && outer.scrolls == 1);
        assert(!h.ctx.handleEvent(pev(PlatformEventKind.closeRequested)));
        assert(!h.ctx.handleEvent(pev(PlatformEventKind.resize)) && h.ctx.needsRedraw);
    }

    unittest {
        auto root = new Panel();
        auto p = root.add(new Probe(RectF(0, 0, 50, 50)));
        auto other = root.add(new Probe(RectF(100, 0, 50, 50)));
        auto h = new Harness(root);
        h.down(10, 10);
        assert(h.ctx.captured() is p);
        h.move(120, 10);
        assert(p.moves == 1 && other.moves == 0);
        h.move(300, 250);
        assert(p.moves == 2 && near(p.lastMouse.pos.x, 300));
        h.up(300, 250);
        assert(p.ups == 1 && h.ctx.captured() is null);
        h.move(120, 10);
        assert(other.moves == 1 && p.moves == 2);

        h.down(10, 10);
        assert(h.ctx.captured() is p);
        PlatformEvent blur = pev(PlatformEventKind.focusChanged);
        blur.focused = false;
        assert(h.ctx.handleEvent(blur));
        assert(p.captureLost == 1 && h.ctx.captured() is null && !h.ctx.windowFocused());
        blur.focused = true;
        h.ctx.handleEvent(blur);
        assert(h.ctx.windowFocused());

        h.down(10, 10);
        root.remove(p);
        assert(p.captureLost == 2 && h.ctx.captured() is null);

        h.ctx.capture(other);
        assert(h.ctx.captured() is other);
        h.ctx.releaseCapture();
        assert(h.ctx.captured() is null);
    }

    unittest {
        auto root = new Panel();
        auto a = root.add(new Probe(RectF(0, 0, 50, 50)));
        auto b = root.add(new Probe(RectF(100, 0, 50, 50)));
        a.handleMove = false;
        b.handleMove = false;
        auto h = new Harness(root);
        assert(h.move(10, 10));
        assert(h.ctx.hovered() is a && a.enters == 1 && a.isHovered());
        h.ctx.needsRedraw = false;
        assert(!h.move(12, 12));
        assert(!h.ctx.needsRedraw);
        assert(h.move(110, 10));
        assert(a.leaves == 1 && b.enters == 1 && h.ctx.hovered() is b && h.ctx.needsRedraw);
        h.move(390, 290);
        assert(b.leaves == 1 && h.ctx.hovered() is root);
        h.move(110, 10);
        root.remove(b);
        assert(h.ctx.hovered() is null);
        assert(near(h.ctx.mousePosition().x, 110));
    }

    unittest {
        auto root = new Panel(PanelLayout.manual);
        auto b1 = root.add(new Probe(RectF(0, 0, 40, 20), true));
        auto group = root.add(new Panel());
        group.bounds = RectF(0, 50, 300, 100);
        auto b2 = group.add(new Probe(RectF(0, 50, 40, 20), true));
        auto hidden = group.add(new Probe(RectF(50, 50, 40, 20), true));
        hidden.visible = false;
        auto disabled = group.add(new Probe(RectF(100, 50, 40, 20), true));
        disabled.enabled = false;
        auto b3 = root.add(new Probe(RectF(0, 200, 40, 20), true));
        auto plain = root.add(new Probe(RectF(200, 200, 40, 20), false));
        auto h = new Harness(root);
        auto order = h.ctx.focusOrder();
        assert(order.length == 3 && order[0] is b1 && order[1] is b2 && order[2] is b3);
        assert(h.ctx.focused() is null);
        assert(h.key(KeyCode.tab));
        assert(h.ctx.focused() is b1 && b1.gained == 1 && b1.isFocused());
        h.key(KeyCode.tab);
        assert(h.ctx.focused() is b2 && b1.lost == 1);
        h.key(KeyCode.tab);
        assert(h.ctx.focused() is b3);
        h.key(KeyCode.tab);
        assert(h.ctx.focused() is b1);
        h.key(KeyCode.tab, KeyModifiers.shift);
        assert(h.ctx.focused() is b3);
        h.key(KeyCode.tab, KeyModifiers.shift);
        assert(h.ctx.focused() is b2);
        assert(!h.key(KeyCode.tab, KeyModifiers.command));
        assert(h.ctx.focused() is b2);
        assert(b2.keyDowns == 2 && b1.keyDowns == 2 && b3.keyDowns == 2);

        assert(!h.ctx.setFocus(hidden) && !h.ctx.setFocus(disabled) && !h.ctx.setFocus(plain));
        assert(h.ctx.focused() is b2);
        b2.handleKeys = true;
        assert(h.key(KeyCode.tab));
        assert(h.ctx.focused() is b2);
        b2.handleKeys = false;

        h.click(10, 205);
        assert(h.ctx.focused() is b3);
        h.click(210, 205);
        assert(h.ctx.focused() is null);
        h.ctx.setFocus(null);
        assert(h.ctx.focusPrevious() && h.ctx.focused() is b3);

        h.ctx.setFocus(b1);
        assert(!h.key(KeyCode.a));
        assert(b1.keyDowns == 3 && b1.lastKey.keyCode == KeyCode.a);
        h.keyUp(KeyCode.a);
        assert(b1.keyUps == 1);
        h.type("x"d);
        assert(b1.texts == 1 && b1.lastChar == 'x');
        root.remove(b1);
        assert(h.ctx.focused() is null && b1.lost == 3);

        auto lonely = new Harness(new Panel());
        assert(!lonely.ctx.focusNext());
        assert(lonely.key(KeyCode.tab));
    }

    unittest {
        auto root = new Panel();
        auto p = root.add(new Probe(RectF(0, 0, 100, 100)));
        auto h = new Harness(root);
        h.down(10, 10);
        h.up(10, 10);
        assert(p.lastMouse.clickCount == 1);
        h.downQuick(11, 11);
        assert(p.lastMouse.clickCount == 2);
        h.up(11, 11);
        h.downQuick(11, 12);
        assert(p.lastMouse.clickCount == 3);
        h.up(11, 12);
        h.downQuick(30, 30);
        assert(p.lastMouse.clickCount == 1);
        h.up(30, 30);
        h.clock.t += 0.5;
        h.ctx.handleEvent(pev(PlatformEventKind.mouseDown, 30, 30));
        assert(p.lastMouse.clickCount == 1);
        h.up(30, 30);
        h.downQuick(30, 30, 1);
        assert(p.lastMouse.clickCount == 1 && p.lastMouse.button == MouseButton.right);
        h.up(30, 30, 1);
        h.downQuick(30, 30, 2);
        assert(p.lastMouse.button == MouseButton.other);
        h.up(30, 30, 2);

        auto realClock = new UiContext(new Panel());
        immutable double t0 = realClock.now();
        assert(t0 >= 0.0 && realClock.now() >= t0);
    }

    unittest {
        auto root = new Panel();
        auto p = root.add(new Probe(RectF(0, 0, 100, 100)));
        auto h = new Harness(root);
        assert(h.ctx.needsRedraw);
        h.ctx.draw(h.renderer);
        assert(!h.ctx.needsRedraw);
        assert(!h.ctx.isAnimating());
        p.animating = true;
        assert(h.ctx.isAnimating());
        p.visible = false;
        assert(!h.ctx.isAnimating());
        p.visible = true;
        p.animating = false;
        auto ov = new Probe(RectF(0, 0, 10, 10));
        ov.animating = true;
        h.ctx.openOverlay(ov);
        assert(h.ctx.isAnimating() && h.ctx.needsRedraw);
        h.ctx.closeAllOverlays();
        assert(!h.ctx.isAnimating() && h.ctx.overlays().length == 0);
        h.ctx.draw(h.renderer);
        p.invalidate();
        assert(h.ctx.needsRedraw);
        h.ctx.draw(h.renderer);
        h.down(10, 10);
        assert(h.ctx.needsRedraw);
    }

    unittest {
        auto root = new Panel();
        int clicks = 0;
        auto btn = root.add(new Button("Play", () { clicks++; }));
        btn.bounds = RectF(10, 10, 80, 24);
        auto h = new Harness(root);
        h.click(20, 20);
        assert(clicks == 1 && h.ctx.focused() is btn);
        h.down(20, 20);
        assert(btn.isPressed());
        h.move(200, 200);
        h.up(200, 200);
        assert(clicks == 1 && !btn.isPressed());
        assert(h.key(KeyCode.returnKey) && clicks == 2);
        assert(h.key(KeyCode.space) && clicks == 3);
        assert(!h.key(KeyCode.a));
        btn.enabled = false;
        h.click(20, 20);
        assert(clicks == 3);
        btn.click();
        assert(clicks == 3);
        btn.enabled = true;
        h.click(20, 20, 1);
        assert(clicks == 3);
        h.down(20, 20);
        PlatformEvent blur = pev(PlatformEventKind.focusChanged);
        h.ctx.handleEvent(blur);
        assert(!btn.isPressed());
        auto m = btn.measure(h.renderer, h.ctx.theme);
        assert(near(m.x, 4 * 6.5f + 24.0f) && near(m.y, h.ctx.theme.controlHeight));
    }

    unittest {
        auto root = new Panel();
        bool last = false;
        int calls = 0;
        auto tog = root.add(new Toggle("Loop", false, (bool v) { last = v; calls++; }));
        tog.bounds = RectF(0, 0, 100, 20);
        auto h = new Harness(root);
        h.click(5, 10);
        assert(tog.checked && last && calls == 1);
        h.click(5, 10);
        assert(!tog.checked && !last && calls == 2);
        h.down(5, 10);
        h.up(300, 200);
        assert(!tog.checked && calls == 2);
        h.ctx.setFocus(tog);
        assert(h.key(KeyCode.space) && tog.checked && calls == 3);
        assert(h.key(KeyCode.returnKey) && !tog.checked && calls == 4);
        assert(tog.setChecked(true, false) && calls == 4 && tog.checked);
        assert(!tog.setChecked(true));
        assert(nearRect(tog.trackRect(), RectF(0, 2, 28.8f, 16)));
    }

    unittest {
        ValueRange lin = ValueRange(-1.0f, 1.0f, 0.0f);
        assert(near(lin.toNormalized(0.0f), 0.5f) && near(lin.fromNormalized(0.75f), 0.5f));
        assert(lin.clamp(5) == 1 && lin.clamp(-5) == -1 && lin.clamp(float.nan) == 0);
        assert(lin.clamp(float.infinity) == 1 && lin.clamp(-float.infinity) == -1);
        assert(lin.fromNormalized(2.0f) == 1.0f && lin.fromNormalized(-1.0f) == -1.0f);
        assert(!lin.usesLog());

        ValueRange lg = ValueRange(20.0f, 20000.0f, 1000.0f, true);
        assert(lg.usesLog());
        assert(near(lg.fromNormalized(0.5f), 632.4555f, 0.01f));
        assert(near(lg.toNormalized(632.4555f), 0.5f));
        assert(near(lg.fromNormalized(0.0f), 20.0f) && near(lg.fromNormalized(1.0f), 20000.0f, 0.05f));
        assert(near(lg.toNormalized(2000.0f), 2.0f / 3.0f));
        assert(!ValueRange(0.0f, 10.0f, 1.0f, true).usesLog());
        assert(near(ValueRange(0.0f, 10.0f, 1.0f, true).fromNormalized(0.5f), 5.0f));

        ValueRange stepped = ValueRange(0.0f, 10.0f, 0.0f, false, 2.5f);
        assert(stepped.quantize(3.6f) == 2.5f && stepped.quantize(3.9f) == 5.0f && stepped.quantize(11) == 10.0f);
        assert(stepped.fromNormalized(0.3f) == 2.5f);
        assert(ValueRange(1.0f, 1.0f, 1.0f).toNormalized(1.0f) == 0.0f);
        ValueRange reversed = ValueRange(10.0f, 0.0f, 5.0f);
        assert(reversed.clamp(-3) == 0 && reversed.clamp(13) == 10);
    }

    unittest {
        auto root = new Panel();
        float lastValue = float.nan;
        int changes = 0;
        auto s = root.add(new Slider(ValueRange(0.0f, 1.0f, 0.2f)));
        s.onChange = (float v) { lastValue = v; changes++; };
        s.bounds = RectF(0, 0, 112, 20);
        auto h = new Harness(root);
        assert(nearRect(s.trackRect(), RectF(6, 8, 100, 4)));
        assert(near(s.value(), 0.2f) && near(s.thumbCenter().x, 26.0f));
        assert(nearRect(s.thumbRect(), RectF(20, 4, 12, 12)));
        assert(near(s.positionToNormalized(Point2F(-50, 0)), 0.0f) && near(s.positionToNormalized(Point2F(500, 0)), 1.0f));

        h.down(56, 10);
        assert(near(s.value(), 0.5f) && changes == 1 && near(lastValue, 0.5f) && s.isDragging());
        h.move(81, 10);
        assert(near(s.value(), 0.75f));
        h.move(81, 10, KeyModifiers.shift);
        assert(near(s.value(), 0.75f));
        h.move(181, 10, KeyModifiers.shift);
        assert(near(s.value(), 0.85f));
        h.move(191, 10);
        assert(near(s.value(), 0.85f));
        h.move(166, 10);
        assert(near(s.value(), 0.6f));
        h.up(166, 10);
        assert(!s.isDragging());

        h.down(56, 10);
        h.up(56, 10);
        assert(near(s.value(), 0.5f));
        h.downQuick(56, 10);
        h.up(56, 10);
        assert(near(s.value(), 0.2f) && near(lastValue, 0.2f));

        h.down(86, 10, 0, KeyModifiers.shift);
        assert(near(s.value(), 0.2f));
        h.move(186, 10, KeyModifiers.shift);
        assert(near(s.value(), 0.3f));
        h.up(186, 10);

        h.click(56, 10);
        assert(near(s.value(), 0.5f));
        h.click(56, 10, 0, KeyModifiers.alt);
        assert(near(s.value(), 0.2f));

        h.down(26, 10);
        assert(near(s.value(), 0.2f));
        h.move(36, 10);
        assert(near(s.value(), 0.3f));
        h.up(36, 10);

        assert(h.ctx.focused() is s);
        immutable int before = changes;
        assert(h.key(KeyCode.right) && near(s.value(), 0.31f));
        assert(h.key(KeyCode.down) && near(s.value(), 0.30f));
        assert(h.key(KeyCode.up, KeyModifiers.shift) && near(s.value(), 0.301f));
        assert(h.key(KeyCode.end) && near(s.value(), 1.0f));
        assert(h.key(KeyCode.home) && near(s.value(), 0.0f));
        assert(!h.key(KeyCode.a));
        assert(changes == before + 5);
        assert(!s.setValue(0.0f) && s.setValue(0.4f, false) && changes == before + 5);
        h.click(56, 10, 1);
        assert(near(s.value(), 0.4f));

        auto v = root.add(new Slider(ValueRange(0.0f, 1.0f, 0.2f), Axis.vertical));
        v.bounds = RectF(200, 0, 20, 112);
        h.ctx.layout(RectF(0, 0, 400, 300));
        assert(nearRect(v.trackRect(), RectF(208, 6, 4, 100)));
        h.down(210, 31);
        assert(near(v.value(), 0.75f));
        h.move(210, 81);
        assert(near(v.value(), 0.25f));
        h.up(210, 81);

        auto logS = root.add(new Slider(ValueRange(20.0f, 20000.0f, 1000.0f, true)));
        logS.bounds = RectF(0, 100, 112, 20);
        h.ctx.layout(RectF(0, 0, 400, 300));
        h.click(56, 110);
        assert(near(logS.value(), 632.4555f, 0.01f));
        h.click(106, 110);
        assert(near(logS.value(), 20000.0f, 0.05f));
        h.doubleClick(6, 110);
        assert(near(logS.value(), 1000.0f, 0.01f));

        auto stepped = root.add(new Slider(ValueRange(0.0f, 10.0f, 0.0f, false, 1.0f)));
        stepped.bounds = RectF(0, 150, 112, 20);
        h.ctx.layout(RectF(0, 0, 400, 300));
        h.click(40, 160);
        assert(stepped.value() == 3.0f);
        h.ctx.setFocus(stepped);
        h.key(KeyCode.right, KeyModifiers.shift);
        assert(stepped.value() == 4.0f);
        h.key(KeyCode.left);
        assert(stepped.value() == 3.0f);
    }

    unittest {
        auto root = new Panel();
        auto k = root.add(new RotaryKnob(ValueRange(0.0f, 1.0f, 0.5f)));
        k.bounds = RectF(0, 0, 40, 40);
        int changes = 0;
        k.onChange = (float v) { changes++; };
        auto h = new Harness(root);
        assert(near(RotaryKnob.angleFor(0.0f), cast(float)(PI_F * 0.75f)) && near(RotaryKnob.angleFor(1.0f), cast(float)(PI_F * 2.25f)));
        assert(near(RotaryKnob.angleFor(5.0f), RotaryKnob.angleFor(1.0f)));
        assert(near(k.radius(), 17.0f));
        h.down(20, 20);
        assert(near(k.value(), 0.5f) && changes == 0);
        h.move(20, -80);
        assert(near(k.value(), 1.0f));
        h.move(20, 20);
        assert(near(k.value(), 0.5f));
        h.move(220, 20);
        assert(near(k.value(), 0.5f));
        h.move(20, 20, KeyModifiers.shift);
        h.move(20, -80, KeyModifiers.shift);
        assert(near(k.value(), 0.55f));
        h.move(20, 520, KeyModifiers.shift);
        assert(near(k.value(), 0.25f));
        h.move(20, 2000, KeyModifiers.shift);
        assert(near(k.value(), 0.0f, 1e-6f));
        h.up(20, 500);
        h.doubleClick(20, 20);
        assert(near(k.value(), 0.5f));

        auto lk = root.add(new RotaryKnob(ValueRange(20.0f, 20000.0f, 20.0f, true)));
        lk.bounds = RectF(100, 0, 40, 40);
        h.ctx.layout(RectF(0, 0, 400, 300));
        h.drag(120, 20, 120, -80);
        assert(near(lk.value(), 632.4555f, 0.01f));
        h.ctx.setFocus(lk);
        h.key(KeyCode.end);
        assert(near(lk.value(), 20000.0f, 0.05f));
    }

    unittest {
        auto root = new Panel();
        auto nb = root.add(new NumericDragBox(ValueRange(0.0f, 100.0f, 10.0f, false, 1.0f), 1));
        nb.suffix = " Hz";
        nb.bounds = RectF(0, 0, 60, 20);
        float last = float.nan;
        nb.onChange = (float v) { last = v; };
        auto other = root.add(new Probe(RectF(200, 0, 40, 20), true));
        auto h = new Harness(root);
        assert(nb.displayText() == "10.0 Hz" && nb.formatValue(3.14159f) == "3.1 Hz");
        h.down(30, 10);
        h.move(70, 10);
        assert(nb.value() == 20.0f && last == 20.0f);
        h.move(70, -10);
        assert(nb.value() == 25.0f);
        h.move(72, -10);
        assert(nb.value() == 26.0f);
        h.move(72, -10, KeyModifiers.shift);
        h.move(112, -10, KeyModifiers.shift);
        assert(nb.value() == 27.0f);
        h.up(112, -10);
        assert(nb.displayText() == "27.0 Hz");

        assert(h.ctx.focused() is nb);
        h.key(KeyCode.up);
        assert(nb.value() == 28.0f);
        h.key(KeyCode.down, KeyModifiers.shift);
        assert(nb.value() == 27.0f);

        assert(h.key(KeyCode.returnKey) && nb.isEditing() && nb.editText() == "27.0");
        assert(nb.displayText() == "27.0");
        h.type("42"d);
        assert(nb.editText() == "42");
        h.key(KeyCode.returnKey);
        assert(!nb.isEditing() && nb.value() == 42.0f && last == 42.0f);

        h.key(KeyCode.returnKey);
        h.type("5"d);
        h.key(KeyCode.escape);
        assert(!nb.isEditing() && nb.value() == 42.0f);

        h.type("7"d);
        assert(nb.isEditing() && nb.editText() == "7");
        h.type("x"d);
        assert(nb.editText() == "7");
        h.type("5"d);
        h.key(KeyCode.deleteBackward);
        assert(nb.editText() == "7");
        h.key(KeyCode.left);
        assert(nb.isEditing());
        h.key(KeyCode.keypadEnter);
        assert(nb.value() == 7.0f);

        h.key(KeyCode.returnKey);
        h.key(KeyCode.deleteBackward);
        assert(nb.editText() == "");
        h.type("4-2"d);
        assert(!nb.commitEdit() && nb.value() == 7.0f && !nb.isEditing());
        assert(!nb.commitEdit());

        h.key(KeyCode.returnKey);
        h.type("500"d);
        h.key(KeyCode.returnKey);
        assert(nb.value() == 100.0f);

        h.doubleClick(30, 10);
        assert(nb.isEditing() && h.ctx.focused() is nb);
        h.click(30, 10);
        assert(nb.isEditing());
        h.type("12.6"d);
        assert(h.key(KeyCode.tab));
        assert(!nb.isEditing() && nb.value() == 13.0f && h.ctx.focused() is other);

        h.ctx.setFocus(nb);
        h.type("3"d);
        h.ctx.setFocus(other);
        assert(!nb.isEditing() && nb.value() == 3.0f);

        h.ctx.setFocus(nb);
        h.type("1e1"d);
        h.key(KeyCode.returnKey);
        assert(nb.value() == 10.0f);
        assert(!nb.onTextInput('q'));

        nb.formatter = (float v) => v < 50.0f ? "low" : "high";
        assert(nb.displayText() == "low");
        auto m = nb.measure(h.renderer, h.ctx.theme);
        assert(near(m.x, 4 * 6.0f + 16.0f) && near(m.y, h.ctx.theme.controlHeight));

        auto cont = root.add(new NumericDragBox(ValueRange(0.0f, 1.0f, 0.0f), 3));
        cont.bounds = RectF(0, 100, 60, 20);
        h.ctx.layout(RectF(0, 0, 400, 300));
        h.drag(30, 110, 230, 110);
        assert(near(cont.value(), 0.5f));
    }

    unittest {
        auto root = new Panel();
        size_t picked = size_t.max;
        int selects = 0;
        auto dd = root.add(new Dropdown(["Sine", "Saw", "Square", "Noise"], 0, (size_t i) { picked = i; selects++; }));
        dd.bounds = RectF(10, 10, 100, 22);
        auto behind = root.add(new Probe(RectF(10, 200, 50, 50)));
        auto h = new Harness(root, RectF(0, 0, 400, 300));
        assert(dd.selectedText() == "Sine" && !dd.isOpen());

        h.click(50, 20);
        assert(dd.isOpen() && h.ctx.overlays().length == 1 && h.ctx.focused() is dd);
        auto list = dd.popup();
        assert(nearRect(list.bounds, RectF(10, 34, 100, 96)));
        assert(list.visibleCount == 4 && list.highlighted == 0);
        assert(nearRect(list.itemRect(2), RectF(10, 82, 100, 22)));
        assert(list.itemAt(Point2F(50, 90)) == 2 && list.itemAt(Point2F(50, 36)) == -1);
        h.move(50, 70);
        assert(list.highlighted == 1);
        h.click(50, 90);
        assert(!dd.isOpen() && dd.selectedIndex == 2 && picked == 2 && selects == 1);
        assert(dd.selectedText() == "Square" && h.ctx.overlays().length == 0);

        h.click(50, 20);
        assert(dd.isOpen() && dd.popup().highlighted == 2);
        assert(h.key(KeyCode.escape));
        assert(!dd.isOpen() && dd.selectedIndex == 2 && selects == 1);

        h.key(KeyCode.space);
        assert(dd.isOpen());
        h.key(KeyCode.down);
        h.key(KeyCode.down);
        h.key(KeyCode.down);
        assert(dd.popup().highlighted == 3);
        h.key(KeyCode.up);
        h.key(KeyCode.home);
        assert(dd.popup().highlighted == 0);
        h.key(KeyCode.end);
        h.key(KeyCode.returnKey);
        assert(!dd.isOpen() && dd.selectedIndex == 3 && picked == 3 && selects == 2);

        h.click(50, 20);
        assert(dd.isOpen());
        assert(!h.scroll(300, 250, 0, 10));
        assert(!h.key(KeyCode.a));
        assert(h.down(20, 210));
        assert(!dd.isOpen() && behind.downs == 0);
        h.up(20, 210);
        h.click(20, 210);
        assert(behind.downs == 1);

        h.click(50, 20);
        assert(dd.isOpen());
        h.click(50, 20);
        assert(!dd.isOpen());

        h.ctx.setFocus(dd);
        h.key(KeyCode.up);
        assert(dd.selectedIndex == 2 && picked == 2);
        h.key(KeyCode.down);
        h.key(KeyCode.down);
        assert(dd.selectedIndex == 3);
        assert(!dd.select(3) && !dd.select(99));
        assert(dd.select(0, false) && picked == 3);

        dd.items = ["Sine", "A very long waveform name"];
        dd.selectedIndex = 0;
        assert(dd.open());
        assert(!dd.open());
        assert(near(dd.popup().bounds.w, 25 * 6.5f + 16.0f));
        dd.close();
        assert(!dd.isOpen() && h.ctx.overlays().length == 0);

        dd.items = ["A", "B", "C", "D", "E", "F"];
        dd.maxVisibleItems = 3;
        dd.bounds = RectF(10, 270, 100, 22);
        h.ctx.layout(RectF(0, 0, 400, 300));
        dd.open();
        list = dd.popup();
        assert(nearRect(list.bounds, RectF(10, 194, 100, 74)));
        assert(list.visibleCount == 3 && list.firstVisible == 0);
        h.key(KeyCode.end);
        assert(list.highlighted == 5 && list.firstVisible == 3);
        assert(list.itemRect(0) == RectF.init);
        h.key(KeyCode.home);
        assert(list.firstVisible == 0);
        assert(h.scroll(50, 220, 0, -50));
        assert(list.firstVisible == 2);
        h.scroll(50, 220, 0, 500);
        assert(list.firstVisible == 0);
        h.ctx.closeAllOverlays();
        assert(!dd.isOpen());

        auto empty = root.add(new Dropdown([]));
        assert(!empty.open() && empty.selectedText() == "");
        auto detached = new Dropdown(["x"]);
        assert(!detached.open());
    }

    unittest {
        auto root = new Panel();
        auto target = root.add(new Panel());
        target.bounds = RectF(0, 0, 400, 300);
        string[] log;
        bool closed = false;
        target.contextMenuProvider = (Point2F p) {
            return [
                MenuItem("Copy", () { log ~= "copy"; }, true, false, "Cmd+C"),
                MenuItem.makeSeparator(),
                MenuItem("Paste", () { log ~= "paste"; }, false),
                MenuItem("Delete", () { log ~= "delete"; })
            ];
        };
        auto h = new Harness(root, RectF(0, 0, 400, 300));
        assert(h.down(50, 50, 1));
        assert(h.ctx.overlays().length == 1);
        auto menu = cast(ContextMenu) h.ctx.overlays()[0];
        assert(menu !is null);
        menu.onClosed = () { closed = true; };
        h.up(50, 50, 1);
        assert(h.ctx.overlays().length == 1 && log.length == 0);
        assert(nearRect(menu.bounds, RectF(50, 50, 140, 81)));
        assert(near(menu.contentHeight(), 81.0f));
        assert(nearRect(menu.itemRect(2), RectF(50, 83, 140, 22)));
        assert(menu.itemAt(Point2F(100, 60)) == 0 && menu.itemAt(Point2F(100, 80)) == 1);
        assert(!menu.isSelectable(1) && !menu.isSelectable(2) && menu.isSelectable(3) && !menu.isSelectable(9));

        h.move(100, 90);
        assert(menu.highlighted == -1);
        h.move(100, 60);
        assert(menu.highlighted == 0);
        h.click(100, 90);
        assert(h.ctx.overlays().length == 1 && log.length == 0);
        h.click(100, 78);
        assert(h.ctx.overlays().length == 1);
        h.click(100, 60);
        assert(h.ctx.overlays().length == 0 && log == ["copy"] && closed);

        h.click(50, 50, 1);
        menu = cast(ContextMenu) h.ctx.overlays()[0];
        h.key(KeyCode.down);
        assert(menu.highlighted == 0);
        h.key(KeyCode.down);
        assert(menu.highlighted == 3);
        h.key(KeyCode.down);
        assert(menu.highlighted == 0);
        h.key(KeyCode.up);
        assert(menu.highlighted == 3);
        h.key(KeyCode.returnKey);
        assert(log == ["copy", "delete"] && h.ctx.overlays().length == 0);

        h.click(50, 50, 1);
        assert(h.key(KeyCode.escape));
        assert(h.ctx.overlays().length == 0 && log.length == 2);

        h.click(390, 290, 1);
        menu = cast(ContextMenu) h.ctx.overlays()[0];
        assert(nearRect(menu.bounds, RectF(260, 219, 140, 81)));
        assert(h.click(10, 10));
        assert(h.ctx.overlays().length == 0);

        auto direct = h.ctx.openContextMenu([MenuItem("Only", null, false)], Point2F(5, 5));
        assert(h.ctx.isOverlayOpen(direct));
        assert(!direct.activate(0));
        direct.highlighted = -1;
        h.key(KeyCode.down);
        assert(direct.highlighted == -1);
        h.key(KeyCode.returnKey);
        assert(h.ctx.isOverlayOpen(direct));
        direct.close();
        assert(!h.ctx.isOverlayOpen(direct));

        target.contextMenuProvider = (Point2F p) { MenuItem[] none; return none; };
        assert(!h.click(10, 10, 1));
        assert(h.ctx.overlays().length == 0);
        target.contextMenuProvider = null;
        assert(!h.click(10, 10, 1));
    }

    unittest {
        ScrollBarModel bar;
        bar.axis = Axis.vertical;
        bar.track = RectF(90, 0, 10, 90);
        bar.contentLength = 400;
        bar.viewportLength = 90;
        assert(near(bar.maxOffset(), 310) && bar.isScrollable());
        assert(near(bar.thumbLength(), 20.25f) && nearRect(bar.thumbRect(), RectF(90, 0, 10, 20.25f)));
        bar.offset = 310;
        assert(near(bar.thumbRect().bottom(), 90.0f));
        assert(near(bar.offsetForThumbDrag(0, 69.75f / 2.0f), 155.0f));
        assert(near(bar.offsetForThumbDrag(0, 1000), 310.0f) && near(bar.offsetForThumbDrag(100, -1000), 0.0f));
        bar.offset = 155;
        assert(near(bar.pageToward(Point2F(95, 80)), 245.0f) && near(bar.pageToward(Point2F(95, 2)), 65.0f));
        bar.contentLength = 10000;
        assert(near(bar.thumbLength(), 18.0f));
        bar.contentLength = 50;
        assert(!bar.isScrollable() && near(bar.thumbLength(), 90.0f) && bar.maxOffset() == 0);
        assert(near(bar.offsetForThumbDrag(20, 5), 0.0f));
        ScrollBarModel hb;
        hb.axis = Axis.horizontal;
        hb.track = RectF(0, 90, 90, 10);
        hb.contentLength = 300;
        hb.viewportLength = 90;
        hb.offset = 210;
        assert(nearRect(hb.thumbRect(), RectF(63, 90, 27, 10)));
    }

    unittest {
        auto root = new Panel();
        auto content = new Panel();
        auto top = content.add(new Probe(RectF(0, 0, 50, 50)));
        auto low = content.add(new Probe(RectF(0, 200, 50, 50)));
        auto sv = root.add(new ScrollView(content));
        sv.bounds = RectF(0, 0, 100, 100);
        sv.contentSize = Point2F(300, 400);
        auto h = new Harness(root, RectF(0, 0, 400, 300));
        assert(sv.scrollbarVisible(Axis.vertical) && sv.scrollbarVisible(Axis.horizontal));
        assert(nearRect(sv.viewportRect(), RectF(0, 0, 90, 90)));
        assert(nearRect(content.bounds, RectF(0, 0, 300, 400)));
        assert(h.ctx.hitTest(Point2F(10, 10)) is top);
        assert(h.ctx.hitTest(Point2F(95, 10)) is sv);
        assert(h.ctx.hitTest(Point2F(10, 95)) is sv);
        assert(h.ctx.hitTest(Point2F(60, 60)) is content);

        assert(h.scroll(50, 50, 0, -50));
        assert(near(sv.scrollOffset().y, 50.0f) && near(content.bounds.y, -50.0f) && near(top.bounds.y, -50.0f));
        assert(near(low.bounds.y, 150.0f));
        h.scroll(50, 50, 0, -1000);
        assert(near(sv.scrollOffset().y, 310.0f) && near(low.bounds.y, -110.0f));
        h.scroll(50, 50, -1000, 0);
        assert(near(sv.scrollOffset().x, 210.0f) && near(low.bounds.x, -210.0f));
        assert(!h.scroll(50, 50, -5, -5));
        h.scroll(50, 50, 1000, 1000);
        assert(sv.scrollOffset() == Point2F(0, 0) && near(low.bounds.y, 200.0f));
        assert(!h.scroll(50, 50, 0, 10));

        assert(sv.scrollTo(0, 150));
        assert(h.ctx.hitTest(Point2F(25, 60)) is low);
        assert(!sv.scrollTo(0, 150));
        sv.scrollTo(0, 0);

        h.down(95, 10);
        assert(sv.isDraggingThumb() && h.ctx.captured() is sv);
        h.move(95, 10 + 69.75f / 2.0f);
        assert(near(sv.scrollOffset().y, 155.0f, 0.01f));
        h.move(95, 1000);
        assert(near(sv.scrollOffset().y, 310.0f));
        h.move(95, 10 + 69.75f / 2.0f);
        h.up(95, 10 + 69.75f / 2.0f);
        assert(!sv.isDraggingThumb());
        assert(near(sv.verticalBar().offset, 155.0f, 0.01f));
        h.click(95, 80);
        assert(near(sv.scrollOffset().y, 245.0f, 0.01f));
        h.click(95, 2);
        assert(near(sv.scrollOffset().y, 155.0f, 0.01f));

        h.down(5, 95);
        h.move(5 + 34.5f, 95);
        assert(near(sv.scrollOffset().x, 34.5f * 210.0f / 63.0f, 0.01f));
        h.up(5 + 34.5f, 95);
        assert(near(sv.horizontalBar().offset, sv.scrollOffset().x));
        h.click(85, 95);
        assert(near(sv.scrollOffset().x, 34.5f * 210.0f / 63.0f + 90.0f, 0.01f));

        sv.scrollTo(0, 0);
        assert(sv.ensureVisible(low.bounds));
        assert(near(sv.scrollOffset().y, 160.0f) && near(low.bounds.bottom(), 90.0f));
        assert(sv.ensureVisible(RectF(-20, -30, 10, 10)));
        assert(near(sv.scrollOffset().y, 130.0f) && near(sv.scrollOffset().x, 0.0f));

        h.ctx.draw(h.renderer);
        sv.scrollTo(0, 0);
        h.renderer.beginFrame(400, 300, 2.0f);
        top.paints = 0;
        low.paints = 0;
        h.ctx.draw(h.renderer);
        h.renderer.endFrame();
        assert(top.paints == 1 && low.paints == 0);
        auto dl = h.renderer.lastDrawList();
        bool sawViewportScissor = false;
        foreach (ref cmd; dl.commands) {
            if (cmd.scissor == ScissorRect(0, 0, 180, 180)) {
                sawViewportScissor = true;
            }
        }
        assert(sawViewportScissor);
        assert(h.renderer.clipDepth() == 1);

        sv.contentSize = Point2F(50, 50);
        h.ctx.layout(RectF(0, 0, 400, 300));
        assert(!sv.scrollbarVisible(Axis.vertical) && !sv.scrollbarVisible(Axis.horizontal));
        assert(nearRect(sv.viewportRect(), RectF(0, 0, 100, 100)) && nearRect(content.bounds, RectF(0, 0, 100, 100)));
        assert(!h.scroll(50, 50, 0, -30));

        sv.contentSize = Point2F(95, 200);
        sv.layoutChildren();
        assert(sv.scrollbarVisible(Axis.vertical) && sv.scrollbarVisible(Axis.horizontal));
        sv.scrollHorizontal = false;
        sv.contentSize = Point2F(500, 200);
        sv.layoutChildren();
        assert(sv.scrollbarVisible(Axis.vertical) && !sv.scrollbarVisible(Axis.horizontal));
        assert(near(content.bounds.w, 90.0f));

        auto replacement = new Probe(RectF(0, 0, 10, 10));
        sv.setContent(replacement);
        assert(content.parent() is null && replacement.parent() is sv && sv.content is replacement);
    }

    unittest {
        auto right = SplitPaneNode.split(Axis.vertical, SplitPaneNode.leaf("editor"), SplitPaneNode.leaf("mixer"), 0.5f, 50, 50, 4);
        auto tree = SplitPaneNode.split(Axis.horizontal, SplitPaneNode.leaf("browser"), right, 0.25f, 100, 100, 4);
        auto sv = new SplitView(tree);
        auto browser = new Probe(RectF(0, 0, 1, 1));
        auto editor = new Probe(RectF(0, 0, 1, 1));
        auto mixer = new Probe(RectF(0, 0, 1, 1));
        assert(sv.setPane("browser", browser) && sv.setPane("editor", editor) && sv.setPane("mixer", mixer));
        assert(!sv.setPane("nope", new Probe(RectF(0, 0, 1, 1))));
        assert(sv.pane("editor") is editor && sv.pane("nope") is null);
        auto h = new Harness(sv, RectF(0, 0, 404, 304));
        assert(nearRect(browser.bounds, RectF(0, 0, 100, 304)));
        assert(nearRect(editor.bounds, RectF(104, 0, 300, 150)));
        assert(nearRect(mixer.bounds, RectF(104, 154, 300, 150)));
        assert(h.ctx.hitTest(Point2F(102, 50)) is sv);
        assert(h.ctx.hitTest(Point2F(50, 50)) is browser);

        h.down(102, 50);
        assert(h.ctx.captured() is sv && sv.dock.isDragging());
        h.move(202, 50);
        assert(nearRect(browser.bounds, RectF(0, 0, 200, 304)) && nearRect(editor.bounds, RectF(204, 0, 200, 150)));
        h.move(5, 50);
        assert(near(browser.bounds.w, 100.0f));
        h.up(5, 50);
        assert(!sv.dock.isDragging() && browser.downs == 0);

        h.drag(250, 152, 250, 252);
        assert(near(editor.bounds.h, 250.0f) && near(mixer.bounds.y, 254.0f));

        auto replacement = new Probe(RectF(0, 0, 1, 1));
        sv.setPane("mixer", replacement);
        assert(mixer.parent() is null && nearRect(replacement.bounds, RectF(104, 254, 300, 50)));

        h.move(102, 50);
        h.renderer.beginFrame(404, 304, 1.0f);
        h.ctx.draw(h.renderer);
        h.renderer.endFrame();
        auto dl = h.renderer.lastDrawList();
        immutable StudioTheme theme = h.ctx.theme;
        bool sawHot = false;
        bool sawPlain = false;
        foreach (ref inst; dl.instances) {
            if (inst.rect == [100.0f, 0.0f, 4.0f, 304.0f] && inst.colorA == [theme.accent.r, theme.accent.g, theme.accent.b, theme.accent.a]) {
                sawHot = true;
            }
            if (inst.rect == [104.0f, 250.0f, 300.0f, 4.0f] && inst.colorA == [theme.border.r, theme.border.g, theme.border.b, theme.border.a]) {
                sawPlain = true;
            }
        }
        assert(sawHot && sawPlain);

        h.down(102, 50);
        PlatformEvent blur = pev(PlatformEventKind.focusChanged);
        h.ctx.handleEvent(blur);
        assert(!sv.dock.isDragging() && h.ctx.captured() is null);
        h.move(50, 50);
        assert(h.ctx.hovered() is browser);
    }

    unittest {
        auto root = new Panel();
        auto ce = root.add(new CurveEditor());
        ce.bounds = RectF(0, 0, 112, 112);
        int changes = 0;
        ce.onChange = () { changes++; };
        auto h = new Harness(root);
        assert(nearRect(ce.plotRect(), RectF(6, 6, 100, 100)));
        assert(ce.points == [Point2F(0, 0), Point2F(1, 1)]);
        assert(ce.toScreen(Point2F(0.5f, 0.5f)) == Point2F(56, 56));
        assert(ce.toNormalized(Point2F(56, 56)) == Point2F(0.5f, 0.5f));
        assert(ce.pointAt(Point2F(8, 104)) == 0 && ce.pointAt(Point2F(105, 7)) == 1 && ce.pointAt(Point2F(56, 56)) == -1);

        h.click(56, 56);
        assert(ce.points.length == 2 && ce.selected == -1 && changes == 0);
        h.downQuick(56, 56);
        assert(ce.points.length == 3 && ce.points[1] == Point2F(0.5f, 0.5f) && ce.selected == 1 && changes == 1);
        h.move(76, 36);
        assert(near(ce.points[1].x, 0.7f) && near(ce.points[1].y, 0.7f));
        h.up(76, 36);

        h.drag(76, 36, 300, 36);
        assert(ce.points[1].x == 1.0f && ce.points[2].x == 1.0f);
        h.drag(106, 36, 66, -100);
        assert(near(ce.points[1].x, 0.6f) && ce.points[1].y == 1.0f);

        h.drag(6, 106, 56, 56);
        assert(ce.points[0] == Point2F(0.0f, 0.5f));
        h.drag(106, 6, 0, 6);
        assert(ce.points[2].x == 1.0f);

        h.drag(66, 6, 66, 56, KeyModifiers.shift);
        assert(near(ce.points[1].y, 0.95f));

        ce.lockEndpointsX = false;
        h.drag(6, 56, 90, 56);
        assert(near(ce.points[0].x, 0.6f));
        assert(ce.points[0].x <= ce.points[1].x);
        h.drag(66, 56, 0, 56);
        assert(near(ce.points[0].x, 0.0f));
        ce.lockEndpointsX = true;

        assert(ce.insertPoint(Point2F(0.25f, 0.2f)) == 1);
        assert(ce.points.length == 4 && ce.points[1] == Point2F(0.25f, 0.2f));
        foreach (i; 1 .. ce.points.length) {
            assert(ce.points[i - 1].x <= ce.points[i].x);
        }
        assert(ce.insertPoint(Point2F(-1.0f, 2.0f)) == 1);
        assert(ce.points[1] == Point2F(0.0f, 1.0f));
        assert(ce.removePoint(1));
        assert(ce.insertPoint(Point2F(5.0f, 0.0f)) == 3);
        assert(ce.points[3] == Point2F(1.0f, 0.0f) && ce.points[4].x == 1.0f);
        assert(ce.removePoint(3));

        immutable size_t n = ce.points.length;
        immutable int c0 = changes;
        assert(h.down(31, 86, 1));
        assert(ce.points.length == n - 1 && changes == c0 + 1);
        h.up(31, 86, 1);
        assert(!h.down(6, 56, 1));
        h.up(6, 56, 1);
        assert(ce.points.length == n - 1);

        h.click(66, 11);
        assert(ce.selected == 1);
        h.key(KeyCode.left);
        assert(near(ce.points[1].x, 0.59f));
        h.key(KeyCode.right, KeyModifiers.shift);
        assert(near(ce.points[1].x, 0.591f));
        h.key(KeyCode.down);
        assert(near(ce.points[1].y, 0.94f));
        h.key(KeyCode.up);
        assert(near(ce.points[1].y, 0.95f));
        assert(h.key(KeyCode.deleteBackward));
        assert(ce.points.length == 2 && ce.selected == -1);
        assert(!h.key(KeyCode.deleteBackward));
        assert(!ce.removePoint(0) && !ce.removePoint(1) && !ce.removePoint(7));
        ce.minPoints = 1;
        ce.lockEndpointsX = false;
        assert(ce.canRemovePoint(0));
        ce.minPoints = 2;
        ce.lockEndpointsX = true;

        ce.maxPoints = 3;
        assert(ce.insertPoint(Point2F(0.5f, 0.5f)) == 1);
        assert(ce.insertPoint(Point2F(0.7f, 0.5f)) == -1);
        ce.selected = 1;
        assert(ce.insertPoint(Point2F(0.1f, 0.5f)) == -1);
        ce.maxPoints = 64;
        assert(ce.insertPoint(Point2F(0.1f, 0.1f)) == 1 && ce.selected == 2);
        assert(ce.removePoint(1) && ce.selected == 1);
        assert(!ce.movePoint(9, Point2F(0, 0)));
        assert(!ce.movePoint(1, ce.points[1]));

        ce.points = [Point2F(0, 0), Point2F(1, 1)];
        assert(near(ce.evaluate(0.25f), 0.25f) && near(ce.evaluate(-1.0f), 0.0f) && near(ce.evaluate(2.0f), 1.0f));
        ce.mode = CurveMode.smooth;
        assert(near(ce.evaluate(0.25f), 0.15625f) && near(ce.evaluate(0.5f), 0.5f));
        ce.points = [Point2F(0, 0.2f), Point2F(0.5f, 0.2f), Point2F(0.5f, 0.8f), Point2F(1, 0.8f)];
        assert(near(ce.evaluate(0.25f), 0.2f) && near(ce.evaluate(0.75f), 0.8f));

        ce.points = [Point2F(0, 0), Point2F(1, 1)];
        h.down(56, 56);
        h.move(60, 60);
        assert(!ce.isDraggingPoint());
        h.up(60, 60);
        h.move(7, 105);
        assert(ce.hoveredPoint == 0);
        h.move(56, 56);
        assert(ce.hoveredPoint == -1);
        h.down(6, 106);
        assert(ce.isDraggingPoint());
        root.remove(ce);
        assert(!ce.isDraggingPoint() && h.ctx.captured() is null);
    }

    unittest {
        auto root = new Panel();
        auto env = root.add(new EnvelopeEditor());
        env.bounds = RectF(0, 0, 112, 112);
        int changes = 0;
        env.onChange = () { changes++; };
        auto h = new Harness(root);
        assert(env.points.length == 4 && env.sustainIndex == 2 && near(env.sustainLevel(), 0.6f));
        assert(near(env.points[1].x, 0.1f / 0.6f) && env.points[1].y == 1.0f && near(env.points[2].x, 0.5f));
        assert(env.points[0] == Point2F(0, 0) && env.points[3] == Point2F(1, 0));

        h.drag(6, 106, 56, 6);
        assert(env.points[0] == Point2F(0, 0));
        h.drag(106, 106, 50, 50);
        assert(env.points[3] == Point2F(1, 0));

        h.drag(56, 46, 56, 26);
        assert(near(env.sustainLevel(), 0.8f));

        assert(env.insertPoint(Point2F(0.05f, 0.5f)) == 1);
        assert(env.sustainIndex == 3 && near(env.sustainLevel(), 0.8f));
        assert(env.insertPoint(Point2F(0.9f, 0.3f)) == 4);
        assert(env.sustainIndex == 3);
        assert(!env.removePoint(3) && !env.canRemovePoint(3));
        assert(env.removePoint(1) && env.sustainIndex == 2 && near(env.sustainLevel(), 0.8f));
        assert(env.removePoint(3) && env.sustainIndex == 2);

        immutable int c0 = changes;
        immutable Point2F p1 = env.toScreen(env.points[1]);
        h.click(p1.x, p1.y, 0, KeyModifiers.alt);
        assert(env.sustainIndex == 1 && changes == c0 + 1 && near(env.sustainLevel(), 1.0f));
        assert(!env.setSustainIndex(0) && !env.setSustainIndex(3) && !env.setSustainIndex(1));
        assert(env.setSustainIndex(2) && env.sustainIndex == 2);
        h.click(56, 90, 0, KeyModifiers.alt);
        assert(env.sustainIndex == 2);

        env.setAdsr(0.2f, 0.2f, 0.5f, 0.6f);
        assert(env.points.length == 4 && near(env.points[1].x, 0.2f) && near(env.points[2].x, 0.4f));
        assert(near(env.sustainLevel(), 0.5f) && env.sustainIndex == 2);
        env.setAdsr(0.0f, 0.0f, 2.0f, 0.0f);
        assert(env.points[1].x == 0.0f && env.points[2].x == 0.0f && env.sustainLevel() == 1.0f);
        assert(env.minPoints == 3);
    }

    unittest {
        auto row = new Panel(PanelLayout.row);
        row.gap = 4.0f;
        row.padding = Insets.all(2);
        auto fixedW = row.add(new Probe(RectF(0, 0, 1, 1)));
        fixedW.flex = FlexItem.fixedSize(30);
        auto label = row.add(new Label("abcd"));
        label.flex = FlexItem(0.0f, 0.0f);
        auto grow = row.add(new Probe(RectF(0, 0, 1, 1)));
        grow.flex = FlexItem.weighted(1);
        auto hidden = row.add(new Probe(RectF(0, 0, 1, 1)));
        hidden.visible = false;
        auto h = new Harness(row, RectF(0, 0, 200, 30));
        assert(near(label.measuredSize.x, 4 * 6.5f + 4.0f) && near(label.measuredSize.y, 13.0f * 1.25f));
        assert(nearRect(fixedW.bounds, RectF(2, 2, 30, 26)));
        assert(nearRect(label.bounds, RectF(36, 2, 30, 26)));
        assert(nearRect(grow.bounds, RectF(70, 2, 128, 26)));
        assert(near(row.measuredSize.x, 30 + 30 + 0 + 8 + 4) && near(row.measuredSize.y, 13.0f * 1.25f + 4));

        auto col = new Panel(PanelLayout.column);
        auto a = col.add(new Probe(RectF(0, 0, 1, 1)));
        a.flex = FlexItem.fixedSize(10);
        auto b = col.add(new Probe(RectF(0, 0, 1, 1)));
        auto hc = new Harness(col, RectF(5, 5, 50, 100));
        assert(nearRect(a.bounds, RectF(5, 5, 50, 10)) && nearRect(b.bounds, RectF(5, 15, 50, 90)));
        assert(hc.ctx.viewport() == RectF(5, 5, 50, 100) && hc.ctx.root() is col);

        auto stack = new Panel(PanelLayout.stack);
        stack.padding = Insets.all(3);
        auto s1 = stack.add(new Probe(RectF(0, 0, 1, 1)));
        auto s2 = stack.add(new Probe(RectF(0, 0, 1, 1)));
        s1.preferredSize = Point2F(20, 40);
        s2.preferredSize = Point2F(30, 10);
        new Harness(stack, RectF(0, 0, 60, 60));
        assert(nearRect(s1.bounds, RectF(3, 3, 54, 54)) && nearRect(s2.bounds, RectF(3, 3, 54, 54)));
        assert(near(stack.measuredSize.x, 36) && near(stack.measuredSize.y, 46));

        auto manual = new Panel();
        auto inner = manual.add(new Panel());
        inner.bounds = RectF(10, 10, 50, 50);
        auto leaf = inner.add(new Probe(RectF(15, 15, 5, 5)));
        new Harness(manual, RectF(100, 200, 300, 300));
        assert(nearRect(inner.bounds, RectF(110, 210, 50, 50)) && nearRect(leaf.bounds, RectF(115, 215, 5, 5)));
        manual.arrange(RectF(0, 0, 300, 300));
        assert(nearRect(leaf.bounds, RectF(15, 15, 5, 5)));

        auto fixedPref = new Panel(PanelLayout.row);
        fixedPref.preferredSize = Point2F(77, 33);
        new Harness(fixedPref);
        assert(fixedPref.measuredSize == Point2F(77, 33));
    }

    unittest {
        auto root = new Panel();
        auto a = new Panel();
        auto child = a.add(new Probe(RectF(0, 0, 5, 5), true));
        root.add(a);
        auto b = root.add(new Panel());
        b.add(child);
        assert(child.parent() is b && a.children().length == 0 && b.children().length == 1);
        auto h = new Harness(root);
        assert(child.isEffectivelyVisible() && child.isEffectivelyEnabled());
        b.visible = false;
        assert(!child.isEffectivelyVisible() && !h.ctx.setFocus(child));
        b.visible = true;
        b.enabled = false;
        assert(!child.isEffectivelyEnabled());
        b.enabled = true;
        assert(root.isAncestorOf(child) && !a.isAncestorOf(child) && child.isAncestorOf(child));
        assert(child.context() is h.ctx && new Probe(RectF.init).context() is null);
        h.ctx.setFocus(child);
        h.ctx.openOverlay(new Probe(RectF(0, 0, 10, 10), true));
        auto ov = h.ctx.overlays()[0];
        h.ctx.setFocus(ov);
        assert(h.ctx.focused() is ov);
        h.ctx.closeOverlay(ov);
        assert(h.ctx.focused() is null);

        auto p = new Probe(RectF(0, 0, 10, 10));
        h.ctx.openOverlay(p);
        p.handleKeys = true;
        assert(h.key(KeyCode.escape));
        assert(h.ctx.isOverlayOpen(p) && p.keyDowns == 1);
        p.handleKeys = false;
        h.keyUp(KeyCode.a);
        assert(p.keyUps == 1);
        h.type("z"d);
        assert(p.texts == 1 && p.lastChar == 'z');
        assert(h.key(KeyCode.escape));
        assert(!h.ctx.isOverlayOpen(p));

        auto o1 = new Probe(RectF(0, 0, 10, 10));
        auto o2 = new Probe(RectF(0, 0, 10, 10));
        h.ctx.openOverlay(o1);
        h.ctx.openOverlay(o2);
        h.ctx.openOverlay(o1);
        assert(h.ctx.overlays().length == 2 && h.ctx.overlays()[1] is o1);
        h.ctx.layout(RectF(0, 0, 5, 5));
        assert(nearRect(o1.bounds, RectF(0, 0, 5, 5)));
        assert(h.click(3, 3));
        assert(o1.downs == 1 && h.ctx.overlays().length == 2);
        h.ctx.closeAllOverlays();

        PlatformEvent[] batch = [pev(PlatformEventKind.mouseMove, 1, 1), pev(PlatformEventKind.none)];
        h.ctx.handleEvents(batch);
        assert(!h.ctx.handleEvent(pev(PlatformEventKind.none)));
        assert(hasModifier(KeyModifiers.shift | KeyModifiers.alt, KeyModifiers.alt) && !hasModifier(0, KeyModifiers.shift));
    }

    unittest {
        auto split = new SplitView(SplitPaneNode.split(Axis.horizontal, SplitPaneNode.leaf("left"), SplitPaneNode.leaf("right"), 0.5f, 50, 50, 4));
        auto left = new Panel(PanelLayout.column);
        left.padding = Insets.all(4);
        left.gap = 4;
        auto title = left.add(new Label("Synth", TextAlign.center));
        title.flex = FlexItem.fixedSize(20);
        auto btn = left.add(new Button("Play"));
        btn.flex = FlexItem.fixedSize(24);
        auto tog = left.add(new Toggle("Loop", true));
        tog.flex = FlexItem.fixedSize(20);
        auto sl = left.add(new Slider(ValueRange(0, 1, 0.5f)));
        sl.flex = FlexItem.fixedSize(20);
        auto vs = left.add(new Slider(ValueRange(0, 1, 0.5f), Axis.vertical));
        vs.flex = FlexItem.fixedSize(60);
        auto kn = left.add(new RotaryKnob(ValueRange(0, 1, 0.3f)));
        kn.flex = FlexItem.fixedSize(40);
        auto nb = left.add(new NumericDragBox(ValueRange(0, 200, 120, false, 1), 0));
        nb.flex = FlexItem.fixedSize(22);
        auto dd = left.add(new Dropdown(["Sine", "Saw"]));
        dd.flex = FlexItem.fixedSize(22);
        auto dim = left.add(new Label("dim", TextAlign.right));
        dim.dim = true;
        dim.flex = FlexItem.fixedSize(16);
        auto rightCol = new Panel(PanelLayout.column);
        auto ce = rightCol.add(new CurveEditor([Point2F(0, 0), Point2F(0.5f, 0.8f), Point2F(1, 0.2f)]));
        ce.mode = CurveMode.smooth;
        ce.flex = FlexItem.fixedSize(100);
        auto env = rightCol.add(new EnvelopeEditor());
        env.flex = FlexItem.fixedSize(100);
        auto content = new Panel(PanelLayout.column);
        content.preferredSize = Point2F(150, 600);
        auto scrolled = new ScrollView(content);
        scrolled.flex = FlexItem.weighted(1);
        rightCol.add(scrolled);
        split.setPane("left", left);
        split.setPane("right", rightCol);

        auto h = new Harness(split, RectF(0, 0, 404, 500));
        h.ctx.setFocus(btn);
        h.renderer.beginFrame(404, 500, 2.0f);
        StudioTheme darkTheme = makeTheme(builtinPalettes()[2], ContrastMode.high);
        h.ctx.draw(h.renderer, darkTheme);
        h.renderer.endFrame();
        assert(!h.ctx.needsRedraw);
        auto dl = h.renderer.lastDrawList();
        assert(countKind(dl, InstanceKind.shape) > 20);
        assert(countKind(dl, InstanceKind.glyph) > 10);
        assert(countKind(dl, InstanceKind.line) > 20);
        immutable StudioTheme t = h.ctx.theme;
        bool focusRing = false;
        foreach (ref inst; dl.instances) {
            if (near(inst.borderWidth, t.focusRingWidth * 2.0f) && inst.colorBorder == [t.focusRing.r, t.focusRing.g, t.focusRing.b, t.focusRing.a]) {
                focusRing = true;
            }
        }
        assert(focusRing);
        immutable RectF vp = scrolled.viewportRect();
        assert(scrolled.scrollbarVisible(Axis.vertical));
        immutable ScissorRect expect = ScissorRect(cast(uint)(vp.x * 2), cast(uint)(vp.y * 2), cast(uint)(vp.w * 2), cast(uint)(vp.h * 2));
        bool clipped = false;
        foreach (ref cmd; dl.commands) {
            if (cmd.scissor == expect) {
                clipped = true;
            }
        }
        assert(clipped && dl.commands.length >= 3);
        h.ctx.renderFrame(h.renderer, 1.0f);
        immutable size_t baseInstances = h.renderer.lastDrawList().instances.length;

        dd.open();
        tog.enabled = false;
        btn.enabled = false;
        h.ctx.renderFrame(h.renderer, 1.0f);
        dl = h.renderer.lastDrawList();
        assert(dl.instances.length > baseInstances);
        assert(dl.framebufferWidth == 404 && dl.framebufferHeight == 500);
        immutable RectF pb = dd.popup().bounds;
        immutable UIInstance lastShape = dl.instances[$ - 1];
        assert(lastShape.kind == InstanceKind.glyph);
        assert(lastShape.rect[1] >= pb.y && lastShape.rect[1] < pb.bottom());
        assert(h.renderer.submittedFrames == 3);
        assert(dl.instances[0].colorA == [t.background.r, t.background.g, t.background.b, t.background.a]);

        auto bare = new Harness(new Label("x"));
        bare.ctx.renderFrame(bare.renderer, 2.0f);
        assert(countKind(bare.renderer.lastDrawList(), InstanceKind.glyph) == 1);
        auto noMeasure = new UiContext(new Label("abc"));
        noMeasure.layout(RectF(0, 0, 100, 20));
        assert(noMeasure.measurer() is null && noMeasure.root().measuredSize == Point2F(0, 0));
        assert(near(measureTextOr(null, "abc", FontId.ui, 10.0f), 18.0f) && near(lineHeightOr(null, FontId.ui, 10.0f), 12.0f));
    }

    private enum float PI_F = 3.14159265358979f;
}
