/**
 * File:         tests/unit/views_studio_root_test.d
 * Module:       tests.unit.views_studio_root_test
 * Phase:        Phase 8.6 — Studio Root Integration Tests (Phase 8.5 appearance switching)
 *
 * Purpose:
 *   Headless integration tests of the assembled studio: every view is constructed over one StudioContext, laid
 *   out and drawn at Retina scale; keyboard shortcuts resolved through the Keymap route document-level actions to
 *   the session/root (undo/redo, record, octave, loop, play) and to the app command handler (save/open/export/
 *   quit), and context-dependent actions to the focused or last-used view (pattern copy/paste, patchbay zoom);
 *   unhandled piano keys play live notes on the selected module; the context keeps selections valid. Phase 8.5:
 *   appearance switches keep every pane rectangle and theme metric identical, bump themeRevision and redraw every
 *   view in the new colors; Cmd+, opens the Appearance panel, Cmd+Option+C toggles contrast; panel edits preview
 *   live, OK persists, Revert restores; preferences reload in a new context; corrupt preferences fall back to the
 *   defaults with a status message; missing fonts report a status message.
 *
 * Real-Time & Safety Contract:
 *   Headless; renders the engine through processHostBuffer to observe live notes.
 *
 * Dependencies:
 *   Internal: app.{keymap,session}, gui.{appearance,renderer,theme,widgets}, gui.views.{appearance_panel,studio_context,
 *             studio_root}, platform.interfaces,
 *             sequencer.note
 *   External: std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.6)
 */
module tests.unit.views_studio_root_test;

version (unittest) {
    import std.math : fabs;

    import app.keymap : StudioAction;
    import gui.appearance;
    import gui.theme : ContrastMode, StudioTheme, THEME_METRIC_FIELDS;
    import gui.views.appearance_panel : AppearancePanel;
    import app.session : StudioSession;
    import gui.renderer;
    import gui.views.studio_context : IStudioClipboard, StudioContext;
    import gui.views.studio_root : StudioRoot;
    import gui.widgets : UiContext;
    import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;
    import sequencer.note : NoteCell;

    private final class RootRasterizer : IGlyphRasterizer {
        override bool rasterize(FontId font, float px, dchar cp, out RasterizedGlyph g) {
            g.width = 2;
            g.height = 2;
            g.bearingY = 2.0f;
            g.advance = px * 0.55f;
            g.coverage = new ubyte[4];
            return true;
        }

        override void lineMetrics(FontId font, float px, out float ascent, out float lineHeight) {
            ascent = px * 0.8f;
            lineHeight = px * 1.25f;
        }
    }

    private final class MemClipboard : IStudioClipboard {
        string text;

        override string getText() {
            return text;
        }

        override bool setText(string t) {
            text = t;
            return true;
        }
    }

    private struct Rig {
        StudioSession session;
        StudioContext ctx;
        StudioRoot root;
        UiContext ui;
        HeadlessRenderer renderer;
        MemClipboard clip;

        void frame() {
            renderer.beginFrame(1440, 900, 2.0f);
            ctx.tick();
            ui.layout(RectF(0, 0, 1440, 900), renderer);
            ui.draw(renderer);
            renderer.endFrame();
        }

        void mouse(PlatformEventKind kind, Point2F p, ubyte button = 0) {
            PlatformEvent ev;
            ev.kind = kind;
            ev.x = p.x;
            ev.y = p.y;
            ev.mouseButton = button;
            if (kind == PlatformEventKind.mouseDown) {
                root.noteInteraction(p);
            }
            ui.handleEvent(ev);
        }

        void click(Point2F p) {
            mouse(PlatformEventKind.mouseDown, p);
            mouse(PlatformEventKind.mouseUp, p);
            frame();
        }

        void key(uint code, uint mods = 0, bool down = true) {
            PlatformEvent ev;
            ev.kind = down ? PlatformEventKind.keyDown : PlatformEventKind.keyUp;
            ev.keyCode = code;
            ev.modifiers = mods;
            ui.handleEvent(ev);
        }

        void press(uint code, uint mods = 0) {
            key(code, mods, true);
            key(code, mods, false);
            frame();
        }
    }

    private Rig makeRig() {
        Rig r;
        r.session = new StudioSession();
        assert(r.session.initialize(44_100.0f));
        r.clip = new MemClipboard();
        r.ctx = new StudioContext(r.session, null, null, r.clip);
        r.root = new StudioRoot(r.ctx);
        r.ui = new UiContext(r.root);
        r.renderer = new HeadlessRenderer(new GlyphCache(new RootRasterizer()));
        r.frame();
        return r;
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        const dl = r.renderer.lastDrawList();
        assert(dl.instances.length > 200);
        foreach (ref c; dl.commands) {
            assert(c.scissor.x + c.scissor.w <= 2880 && c.scissor.y + c.scissor.h <= 1800);
        }
        foreach (w; [cast(Object) r.root.transport, r.root.patchbay, r.root.rack, r.root.scopeView, r.root.pattern,
                r.root.timeline, r.root.sampleEditor]) {
            assert(w !is null);
        }
        assert(!r.root.patchbay.bounds.isEmpty() && !r.root.pattern.bounds.isEmpty() && !r.root.timeline.bounds.isEmpty());
        assert(r.root.transport.bounds.h == StudioRoot.TRANSPORT_HEIGHT);
        assert(r.root.patchbay.bounds.intersect(r.root.pattern.bounds).isEmpty());
        assert(r.root.patchbay.bounds.intersect(r.root.rack.bounds).isEmpty());
        assert(r.root.pattern.bounds.intersect(r.root.timeline.bounds).isEmpty());
        assert(r.root.transport.bounds.intersect(r.root.patchbay.bounds).isEmpty());
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        immutable uint gen = r.session.doAddModule("synth.analog_gen", "Gen");
        r.frame();
        assert(r.session.doRenameModule(gen, "Lead"));
        r.press(6, KeyModifiers.command);
        assert(r.session.document().modules[1].name == "Gen");
        r.press(6, KeyModifiers.command | KeyModifiers.shift);
        assert(r.session.document().modules[1].name == "Lead");

        r.press(15, KeyModifiers.command);
        assert(r.ctx.recording);
        r.press(15, KeyModifiers.command);
        assert(!r.ctx.recording);
        immutable int oct = r.ctx.editOctave;
        r.press(120);
        assert(r.ctx.editOctave == oct + 1);
        r.press(122);
        r.press(122);
        assert(r.ctx.editOctave == oct - 1);
        r.frame();
        assert(r.session.currentOctave() == r.ctx.editOctave);

        assert(r.session.doAddClip(1, 64, 32) != 0);
        r.press(37, KeyModifiers.command);
        assert(r.session.document().loopEndLine == 96);
        r.press(37, KeyModifiers.command);
        assert(r.session.document().loopEndLine == 0);

        StudioAction[] appActions;
        r.root.appCommandHandler = (StudioAction a) { appActions ~= a; return true; };
        r.press(1, KeyModifiers.command);
        r.press(1, KeyModifiers.command | KeyModifiers.shift);
        r.press(31, KeyModifiers.command);
        r.press(45, KeyModifiers.command);
        r.press(14, KeyModifiers.command);
        r.press(12, KeyModifiers.command);
        assert(appActions == [StudioAction.saveProject, StudioAction.saveProjectAs, StudioAction.openProject,
            StudioAction.newProject, StudioAction.exportWav, StudioAction.quit]);

        r.press(49);
        float[256] l = 0.0f;
        float[256] rr = 0.0f;
        float[][2] outs = [l[], rr[]];
        const(float[])[2] ins = [null, null];
        r.session.engine().processHostBuffer(outs, ins, 256);
        r.frame();
        assert(r.session.isPlaying());
        r.press(53);
        r.session.engine().processHostBuffer(outs, ins, 256);
        r.frame();
        assert(!r.session.isPlaying());
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        immutable uint gen = r.session.doAddModule("synth.analog_gen", "Gen");
        assert(r.session.doConnectWire(gen, 2, 1, 0, 1.0f));
        r.ctx.selectModule(gen);
        r.frame();
        r.click(r.root.pattern.fieldRect(0, 0, 0).center());
        r.press(15, KeyModifiers.command);
        r.press(6);
        r.press(7);
        r.press(15, KeyModifiers.command);
        assert(!r.session.document().patterns[0].cells[0].isEmpty());
        assert(!r.session.document().patterns[0].cells[4].isEmpty());

        r.click(r.root.pattern.fieldRect(0, 0, 0).center());
        r.press(0, KeyModifiers.command);
        r.press(8, KeyModifiers.command);
        assert(r.clip.text.length > 0);
        r.click(r.root.pattern.fieldRect(2, 8, 0).center());
        immutable size_t undoBefore = r.session.history().undoCount();
        r.press(9, KeyModifiers.command);
        assert(r.session.history().undoCount() == undoBefore + 1);
        assert(r.session.document().patterns[0].cells[8 * 4 + 2] == r.session.document().patterns[0].cells[0]);

        r.click(r.root.patchbay.emptyCanvasPoint());
        immutable float z0 = r.root.patchbay.zoom();
        r.press(24, KeyModifiers.command);
        assert(r.root.patchbay.zoom() > z0);
        assert(r.session.document().patterns[0].cells[8 * 4 + 2] == r.session.document().patterns[0].cells[0]);
        r.press(29, KeyModifiers.command);
        assert(fabs(r.root.patchbay.zoom() - 1.0f) < 1e-4f);
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        immutable uint gen = r.session.doAddModule("synth.analog_gen", "Gen");
        assert(r.session.doConnectWire(gen, 2, 1, 0, 1.0f));
        r.frame();
        r.click(r.root.patchbay.emptyCanvasPoint());
        float[512] l = 0.0f;
        float[512] rr = 0.0f;
        float[][2] outs = [l[], rr[]];
        const(float[])[2] ins = [null, null];
        float peak() {
            float p = 0.0f;
            foreach (_; 0 .. 8) {
                r.session.engine().processHostBuffer(outs, ins, 512);
                foreach (v; l) {
                    if (fabs(v) > p) p = fabs(v);
                }
            }
            return p;
        }

        r.key(6);
        assert(peak() < 1e-6f);
        r.key(6, 0, false);
        r.ctx.selectModule(gen);
        r.frame();
        r.key(6);
        assert(peak() > 0.02f);
        r.key(6, 0, false);
        r.frame();

        assert(r.session.doRemoveModule(gen));
        r.frame();
        assert(r.ctx.selectedModule() == 0);
        immutable uint p2 = r.session.doAddPattern(4, 32, "B");
        r.ctx.selectPattern(p2);
        assert(r.session.doRemovePattern(p2));
        r.frame();
        assert(r.ctx.currentPattern() == 1);
    }

    private final class MemStore : IAppearanceStore {
        string text;
        bool has = false;
        size_t saves = 0;

        override bool load(out string t) {
            t = text;
            return has;
        }

        override bool save(string t, out string err) {
            text = t;
            has = true;
            saves++;
            return true;
        }
    }

    private final class FakeBackend : IAppearanceBackend {
        string[] calls;
        ColorRGBA clear;
        float gamma = 0.0f;

        override string[] fontFamilies(bool monospaceOnly) {
            return monospaceOnly ? ["Menlo", "Fira Code"] : ["Helvetica", "Atkinson Hyperlegible Next", "Menlo", "Fira Code"];
        }

        override FontResolution applyFonts(string uiFamily, string monoFamily) {
            calls ~= uiFamily ~ "|" ~ monoFamily;
            FontResolution r;
            r.requestedUi = uiFamily;
            r.requestedMono = monoFamily;
            r.uiFound = uiFamily != "Missing Font";
            r.monoFound = true;
            r.uiFamily = r.uiFound ? uiFamily : "System Font";
            r.monoFamily = monoFamily;
            return r;
        }

        override void applyRendererAppearance(ColorRGBA c, float g) {
            clear = c;
            gamma = g;
        }
    }

    private RectF[] paneRects(ref Rig r) {
        return [r.root.bounds, r.root.transport.bounds, r.root.patchbay.bounds, r.root.rack.bounds,
            r.root.scopeView.bounds, r.root.pattern.bounds, r.root.timeline.bounds, r.root.sampleEditor.bounds];
    }

    private bool drewColor(ref Rig r, ColorRGBA c, RectF within) {
        immutable float[4] want = [c.r, c.g, c.b, c.a];
        foreach (ref inst; r.renderer.lastDrawList().instances) {
            immutable RectF ir = RectF(inst.rect[0] / 2.0f, inst.rect[1] / 2.0f, inst.rect[2] / 2.0f, inst.rect[3] / 2.0f);
            if ((inst.colorA == want || inst.colorBorder == want) && !ir.intersect(within).isEmpty()) {
                return true;
            }
        }
        return false;
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        immutable uint gen = r.session.doAddModule("synth.analog_gen", "Gen");
        assert(r.session.doConnectWire(gen, 2, 1, 0, 1.0f));
        assert(r.session.doAddClip(1, 0, 32) != 0);
        r.ctx.selectModule(gen);
        r.frame();
        assert(r.ctx.theme == StudioTheme.init && r.ui.theme == StudioTheme.init);
        const RectF[] before = paneRects(r);
        immutable StudioTheme light = r.ctx.theme;
        foreach (v; [cast(Object) r.root.transport, r.root.patchbay, r.root.pattern, r.root.timeline, r.root.scopeView,
                r.root.sampleEditor, r.root.rack]) {
            assert(v !is null);
        }
        assert(drewColor(r, light.panelSunken, r.root.patchbay.bounds));
        assert(drewColor(r, light.trackerBackground, r.root.pattern.bounds));

        FakeBackend fb = new FakeBackend();
        r.ctx.appearanceBackend = fb;
        size_t notified = 0;
        r.ctx.onThemeChanged(() { notified++; });
        immutable ulong rev0 = r.ctx.themeRevision();
        AppearanceSettings dark;
        dark.palette = "Dark · Okabe–Ito";
        dark.contrast = ContrastMode.low;
        dark.uiFont = "Helvetica";
        dark.monoFont = "Menlo";
        r.ctx.applyAppearance(dark, false);
        assert(r.ctx.themeRevision() == rev0 + 1 && notified == 1);
        assert(fb.calls == ["Helvetica|Menlo"] && fb.clear == r.ctx.theme.background && fb.gamma == r.ctx.theme.textGamma);
        assert(!r.ctx.theme.isLight && r.ctx.theme.contrast == ContrastMode.low);
        assert(r.ui.theme == r.ctx.theme && r.ui.needsRedraw);
        r.frame();
        assert(paneRects(r) == before);
        static foreach (m; THEME_METRIC_FIELDS) {
            assert(__traits(getMember, r.ui.theme, m) == __traits(getMember, light, m));
        }
        immutable StudioTheme dk = r.ctx.theme;
        assert(r.renderer.lastDrawList().instances[0].colorA == [dk.background.r, dk.background.g, dk.background.b,
            dk.background.a]);
        assert(drewColor(r, dk.panelSunken, r.root.patchbay.bounds) && !drewColor(r, light.panelSunken, r.root.patchbay.bounds));
        assert(drewColor(r, dk.trackerBackground, r.root.pattern.bounds));
        assert(!drewColor(r, light.trackerBackground, r.root.pattern.bounds));
        assert(drewColor(r, dk.panelRaised, r.root.transport.bounds) && !drewColor(r, light.panelRaised, r.root.transport.bounds));
        assert(drewColor(r, dk.panel, r.root.rack.bounds) || drewColor(r, dk.panelRaised, r.root.rack.bounds));
        assert(drewColor(r, dk.trackerBackground, r.root.timeline.bounds));
        assert(drewColor(r, dk.clipColor(0), r.root.timeline.bounds) && !drewColor(r, light.clipColor(0), r.root.timeline.bounds));
        assert(drewColor(r, dk.wireAudio, r.root.patchbay.bounds) && !drewColor(r, light.wireAudio, r.root.patchbay.bounds));
        assert(drewColor(r, dk.panel, r.root.scopeView.bounds) && drewColor(r, dk.panel, r.root.sampleEditor.bounds));

        AppearanceSettings missing;
        missing.uiFont = "Missing Font";
        immutable ulong st = r.ctx.statusRevision();
        r.ctx.applyAppearance(missing, false);
        assert(r.ctx.statusRevision() > st && r.ctx.status.length > 0);
        assert(r.ctx.fonts.uiFamily == "System Font" && !r.ctx.fonts.uiFound);
        r.frame();
        assert(paneRects(r) == before && r.ctx.theme == StudioTheme.init);
    }

    unittest {
        import platform.interfaces : KeyModifiers;

        Rig r = makeRig();
        scope (exit) r.session.dispose();
        MemStore store = new MemStore();
        r.ctx.appearanceStore = store;
        r.ctx.appearanceBackend = new FakeBackend();
        const RectF[] before = paneRects(r);

        r.press(8, KeyModifiers.command | KeyModifiers.alt);
        assert(r.ctx.theme.contrast == ContrastMode.low && r.ctx.appearance.contrast == ContrastMode.low);
        assert(store.saves == 1 && r.ctx.status == "Low contrast");
        r.press(8, KeyModifiers.command | KeyModifiers.alt);
        assert(r.ctx.theme.contrast == ContrastMode.high && store.saves == 2);

        assert(r.root.appearancePanel() is null);
        r.press(43, KeyModifiers.command);
        AppearancePanel p = r.root.appearancePanel();
        assert(p !is null && r.ui.overlays().length == 1 && r.ui.overlays()[0] is p);
        assert(p.uiFont.selectedText() == DEFAULT_UI_FONT && p.monoFont.selectedText() == DEFAULT_MONO_FONT);
        assert(p.monoFont.items == ["Fira Code", "Menlo"] && p.uiFont.items[0] == DEFAULT_UI_FONT);
        assert(!p.controlRect("appearance.ok").isEmpty() && p.bounds.w == AppearancePanel.WIDTH);
        assert(r.root.executeAction(StudioAction.openAppearance) && r.root.appearancePanel() is p);

        p.contrast.select(1);
        assert(r.ctx.theme.contrast == ContrastMode.low && store.saves == 2);
        r.frame();
        assert(paneRects(r) == before);
        p.palette.select(2);
        assert(!r.ctx.theme.isLight && r.ui.theme == r.ctx.theme);
        p.monoFont.select(1);
        assert(r.ctx.appearance.monoFont == "Menlo");
        r.frame();
        assert(paneRects(r) == before);
        p.revert();
        assert(r.root.appearancePanel() is null && r.ui.overlays().length == 0);
        assert(r.ctx.theme == StudioTheme.init && r.ctx.appearance.monoFont == DEFAULT_MONO_FONT && store.saves == 2);

        p = r.root.openAppearancePanel();
        assert(!p.channels[0].enabled && !p.deleteBtn.enabled);
        p.duplicate();
        assert(r.ctx.appearance.palette == "Custom 1" && p.channels[0].enabled && p.deleteBtn.enabled);
        assert(p.palette.selectedText() == "Custom 1");
        assert(p.selectToken("accent") && p.selectedToken() == "accent");
        p.channels[0].setValue(200.0f);
        assert(fabs(r.ctx.theme.accent.r - 200.0f / 255.0f) < 1e-4f && r.ui.theme.accent == r.ctx.theme.accent);
        assert(p.readout().length > 0);
        bool flagged = false;
        foreach (ref m; p.readout()) {
            if (!m.passes()) flagged = true;
        }
        assert(flagged);
        p.channels[0].setValue(0.0f);
        assert(p.selectToken("textDim"));
        foreach (ref m; p.readout()) {
            assert(m.passes());
        }
        r.frame();
        assert(!p.controlRect("appearance.readout").isEmpty() && !p.controlRect("appearance.swatch0").isEmpty());
        r.click(p.controlRect("appearance.swatch2").center());
        assert(p.selectedToken() == "textDisabled");
        p.renameCustom();
        assert(r.ctx.appearance.palette == "Custom 2");
        p.ok();
        assert(r.root.appearancePanel() is null && store.saves == 3);

        StudioContext fresh = new StudioContext(r.session);
        fresh.appearanceStore = store;
        assert(fresh.loadAppearance());
        assert(fresh.appearance == r.ctx.appearance && fresh.theme == r.ctx.theme);
        assert(fresh.theme.paletteName == "Custom 2 · High Contrast");

        p = r.root.openAppearancePanel();
        p.deleteCustom();
        assert(r.ctx.appearance.palette == DEFAULT_PALETTE && r.ctx.appearance.customPalettes.length == 0);
        r.click(Point2F(2.0f, 300.0f));
        assert(r.root.appearancePanel() is null && store.saves == 4);

        MemStore bad = new MemStore();
        bad.text = "synthtracker-appearance 9\ngarbage";
        bad.has = true;
        StudioContext c2 = new StudioContext(r.session);
        c2.appearanceStore = bad;
        assert(!c2.loadAppearance());
        assert(c2.theme == StudioTheme.init && c2.status.length > 0 && bad.saves == 0);
        StudioContext c3 = new StudioContext(r.session);
        c3.appearanceStore = new MemStore();
        assert(!c3.loadAppearance() && c3.status.length == 0 && c3.theme == StudioTheme.init);
    }
}
