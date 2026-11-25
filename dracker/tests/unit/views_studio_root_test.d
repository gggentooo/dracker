/**
 * File:         tests/unit/views_studio_root_test.d
 * Module:       tests.unit.views_studio_root_test
 * Phase:        Phase 8.6 — Studio Root Integration Tests (Phase 8.5 appearance switching)
 *
 * Purpose:
 *   Headless integration tests of the assembled studio: every view is constructed over one StudioContext, laid
 *   out and drawn at Retina scale; keyboard shortcuts resolved through the Keymap route document-level actions to
 *   the session/root (undo/redo, record, octave, loop, play) and to the app command handler (save/open/export/
 *   quit; New, Open and Quit ask "Discard unsaved changes?" first when the project is modified, also for
 *   requestClose()), and context-dependent actions to the focused or last-used view (pattern copy/paste, patchbay zoom);
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
    import std.algorithm : startsWith;
    import std.file : exists, getSize, remove, tempDir, write;
    import std.format : format;
    import std.math : fabs;
    import std.path : baseName, buildPath;
    import std.process : thisProcessID;

    import app.keymap : StudioAction;
    import gui.appearance;
    import gui.theme : ContrastMode, StudioTheme, THEME_METRIC_FIELDS;
    import gui.views.appearance_panel : AppearancePanel;
    import app.session : StudioSession;
    import gui.renderer;
    import gui.views.studio_context : IStudioClipboard, StudioContext;
    import gui.views.studio_root : StudioRoot;
    import gui.widgets : ConfirmDialog, MenuItem, UiContext;
    import platform.interfaces : FileDialogFilter, IFileDialog, KeyModifiers, PlatformEvent, PlatformEventKind;
    import sequencer.note : NoteCell, NoteCmd;

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
        foreach (w; [cast(Object) r.root.transport, r.root.patchbay, r.root.rack, r.root.scopeView, r.root.piano,
                r.root.pattern, r.root.timeline, r.root.sampleEditor]) {
            assert(w !is null);
        }
        assert(!r.root.patchbay.bounds.isEmpty() && !r.root.piano.bounds.isEmpty()
            && !r.root.pattern.bounds.isEmpty() && !r.root.timeline.bounds.isEmpty());
        assert(r.root.transport.bounds.h == StudioRoot.TRANSPORT_HEIGHT);
        assert(r.root.piano.bounds.w == r.root.bounds.w);
        assert(r.root.patchbay.bounds.bottom() < r.root.piano.bounds.y);
        assert(r.root.piano.bounds.bottom() < r.root.pattern.bounds.y);
        assert(r.root.piano.bounds.bottom() < r.root.timeline.bounds.y);
        assert(r.root.patchbay.bounds.intersect(r.root.pattern.bounds).isEmpty());
        assert(r.root.patchbay.bounds.intersect(r.root.piano.bounds).isEmpty());
        assert(r.root.piano.bounds.intersect(r.root.pattern.bounds).isEmpty());
        assert(r.root.piano.bounds.intersect(r.root.timeline.bounds).isEmpty());
        assert(r.root.patchbay.bounds.intersect(r.root.rack.bounds).isEmpty());
        assert(r.root.pattern.bounds.intersect(r.root.timeline.bounds).isEmpty());
        assert(r.root.transport.bounds.intersect(r.root.patchbay.bounds).isEmpty());
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        immutable float patchH0 = r.root.patchbay.bounds.h;
        immutable float pianoH0 = r.root.piano.bounds.h;
        immutable float patY0 = r.root.pattern.bounds.y;
        immutable float patH0 = r.root.pattern.bounds.h;
        immutable float topSplitY = r.root.piano.bounds.y - 2.0f;
        r.mouse(PlatformEventKind.mouseDown, Point2F(100.0f, topSplitY));
        r.mouse(PlatformEventKind.mouseMove, Point2F(100.0f, topSplitY - 24.0f));
        r.mouse(PlatformEventKind.mouseUp, Point2F(100.0f, topSplitY - 24.0f));
        r.frame();
        assert(fabs(r.root.patchbay.bounds.h - (patchH0 - 24.0f)) < 1e-3f);
        assert(fabs(r.root.piano.bounds.h - (pianoH0 + 24.0f)) < 1e-3f);
        assert(fabs(r.root.pattern.bounds.y - patY0) < 1e-3f && fabs(r.root.pattern.bounds.h - patH0) < 1e-3f);

        immutable float patchH1 = r.root.patchbay.bounds.h;
        immutable float pianoH1 = r.root.piano.bounds.h;
        immutable float botSplitY = r.root.piano.bounds.bottom() + 2.0f;
        r.mouse(PlatformEventKind.mouseDown, Point2F(100.0f, botSplitY));
        r.mouse(PlatformEventKind.mouseMove, Point2F(100.0f, botSplitY + 20.0f));
        r.mouse(PlatformEventKind.mouseUp, Point2F(100.0f, botSplitY + 20.0f));
        r.frame();
        assert(fabs(r.root.patchbay.bounds.h - patchH1) < 1e-3f);
        assert(fabs(r.root.piano.bounds.h - (pianoH1 + 20.0f)) < 1e-3f);
        assert(fabs(r.root.pattern.bounds.h - (patH0 - 20.0f)) < 1e-3f);
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

        r.press(15, KeyModifiers.command | KeyModifiers.shift);
        assert(r.ctx.editMode && r.ctx.status == "Edit on");
        r.press(15, KeyModifiers.command | KeyModifiers.shift);
        assert(!r.ctx.editMode && r.ctx.status == "Edit off");
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
        assert(r.session.isDirty());
        r.press(1, KeyModifiers.command);
        r.press(1, KeyModifiers.command | KeyModifiers.shift);
        r.press(31, KeyModifiers.command);
        assert(r.root.unsavedPrompt() !is null && appActions.length == 2);
        r.press(36);
        r.press(45, KeyModifiers.command);
        r.press(36);
        r.press(14, KeyModifiers.command);
        r.press(12, KeyModifiers.command);
        r.press(36);
        assert(appActions == [StudioAction.saveProject, StudioAction.saveProjectAs, StudioAction.openProject,
            StudioAction.newProject, StudioAction.exportWav, StudioAction.quit]);
        assert(r.root.unsavedPrompt() is null && r.ui.overlays().length == 0);

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

        r.press(49);
        r.session.engine().processHostBuffer(outs, ins, 256);
        r.frame();
        assert(r.session.isPlaying());
        r.ctx.editMode = true;
        r.press(53);
        r.session.engine().processHostBuffer(outs, ins, 256);
        r.frame();
        assert(!r.ctx.editMode && r.ctx.status == "Edit off" && r.session.isPlaying());
        r.press(53);
        r.session.engine().processHostBuffer(outs, ins, 256);
        r.frame();
        assert(!r.ctx.editMode && !r.session.isPlaying());
        r.ctx.editMode = true;
        r.press(53, KeyModifiers.shift);
        assert(r.ctx.editMode);
        r.ctx.editMode = false;
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        immutable uint gen = r.session.doAddModule("synth.analog_gen", "Gen");
        assert(r.session.doConnectWire(gen, 2, 1, 0, 1.0f));
        r.ctx.selectModule(gen);
        r.frame();
        r.click(r.root.pattern.fieldRect(0, 0, 0).center());
        r.press(15, KeyModifiers.command | KeyModifiers.shift);
        r.press(6);
        r.press(7);
        r.press(15, KeyModifiers.command | KeyModifiers.shift);
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
        assert(!r.root.piano.isKeyHighlighted(60));
        r.key(6, 0, false);
        r.ctx.selectModule(gen);
        r.frame();
        r.key(6);
        assert(r.root.piano.isKeyHighlighted(60));
        assert(peak() > 0.02f);
        r.key(6, 0, false);
        r.frame();
        assert(!r.root.piano.isKeyHighlighted(60));

        r.click(r.root.pattern.fieldRect(1, 0, 0).center());
        r.key(6);
        assert(r.root.piano.isKeyHighlighted(60));
        r.key(6, 0, false);
        r.frame();
        assert(!r.root.piano.isKeyHighlighted(60));

        r.ctx.editMode = true;
        r.click(r.root.piano.keyRect(64).center());
        r.ctx.editMode = false;
        assert(r.session.document().patterns[0].cells[1].note == NoteCell.encodeMidiNote(64));
        assert(r.session.document().patterns[0].cells[1].moduleId == gen);

        assert(r.session.doPatchCell(1, 0, 0, NoteCell.makeNote(62, 0.8f, cast(ushort) gen)));
        r.session.play();
        r.session.engine().processHostBuffer(outs, ins, 64);
        r.frame();
        assert(r.root.piano.isKeyHighlighted(62));
        r.session.stop();
        r.session.engine().processHostBuffer(outs, ins, 64);
        r.frame();
        assert(!r.root.piano.isKeyHighlighted(62));

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
            r.root.scopeView.bounds, r.root.piano.bounds, r.root.pattern.bounds, r.root.timeline.bounds,
            r.root.sampleEditor.bounds];
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
        bad.text = "dracker-appearance 9\ngarbage";
        bad.has = true;
        StudioContext c2 = new StudioContext(r.session);
        c2.appearanceStore = bad;
        assert(!c2.loadAppearance());
        assert(c2.theme == StudioTheme.init && c2.status.length > 0 && bad.saves == 0);
        StudioContext c3 = new StudioContext(r.session);
        c3.appearanceStore = new MemStore();
        assert(!c3.loadAppearance() && c3.status.length == 0 && c3.theme == StudioTheme.init);
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        auto s = r.session;
        immutable uint gen = s.doAddModule("synth.analog_gen", "Gen");
        assert(s.doConnectWire(gen, 2, 1, 0, 1.0f));
        assert(s.doPatchCell(1, 0, 2, NoteCell.makeNote(50, 0.8f, cast(ushort) gen)));
        assert(s.doPatchCell(1, 0, 4, NoteCell.makeNoteOff()));
        assert(s.doSetLoop(0, 20));
        r.frame();

        float[256] l = 0.0f;
        float[256] rr = 0.0f;
        float[][2] outs = [l[], rr[]];
        const(float[])[2] ins = [null, null];
        void renderUntil(double pos) {
            foreach (_; 0 .. 4000) {
                s.engine().processHostBuffer(outs, ins, 256);
                r.ctx.tick();
                if (s.liveSongPosition() >= pos) {
                    return;
                }
            }
            assert(false, "renderUntil timed out");
        }

        r.press(15, KeyModifiers.command);
        assert(!r.ctx.liveRecording() && r.ctx.status == "Select an instrument module to record");

        r.ctx.selectModule(gen);
        assert(s.seekLine(16));
        s.engine().processHostBuffer(outs, ins, 256);
        r.frame();
        r.ctx.editMode = true;
        r.press(15, KeyModifiers.command);
        assert(r.ctx.liveRecording() && !r.ctx.editMode && s.liveTakeStartLine() == 16);
        assert(r.ctx.status == "Count-in 4");
        s.engine().processHostBuffer(outs, ins, 256);
        r.ctx.tick();
        assert(r.ctx.countingIn() && r.ctx.telemetry.engine.currentLine == 0);
        bool preRollNote = false;
        foreach (_; 0 .. 200) {
            s.engine().processHostBuffer(outs, ins, 256);
            r.ctx.tick();
            preRollNote = preRollNote || r.ctx.telemetry.engine.isPatternNoteActive(gen, 50);
            if (s.liveSongPosition() >= 5.2) break;
        }
        assert(preRollNote && r.ctx.status == "Count-in 3");
        r.frame();
        auto rec = r.root.transport.controlRect("transport.record");
        assert(!rec.isEmpty());

        renderUntil(16.05);
        assert(!r.ctx.countingIn() && r.ctx.status == "Recording");
        r.key(6);
        renderUntil(19.1);
        r.key(6, 0, false);
        renderUntil(20.0);
        r.key(1);
        r.key(7);
        renderUntil(22.0);
        assert(r.ctx.telemetry.engine.currentLine == 22);
        r.key(1, 0, false);
        r.key(7, 0, false);
        assert(s.liveTakeNoteCount() == 3);
        immutable size_t undo0 = s.history().undoCount();
        immutable size_t pats0 = s.document().patterns.length;
        immutable size_t clips0 = s.document().clips.length;
        r.press(53);
        assert(!r.ctx.liveRecording() && !s.liveTakeActive());
        assert(s.document().patterns.length == pats0 + 1 && s.document().clips.length == clips0 + 1);
        assert(s.history().undoCount() == undo0 + 1 && s.history().nextUndoLabel() == "Record Take");
        const take = s.document().patterns[$ - 1];
        assert(r.ctx.currentPattern() == take.patternId && take.name == format("Take %02d", take.patternId));
        assert(r.ctx.status == format("Recorded %s (3 notes)", take.name));
        assert(take.tracks == 4 && take.lines == 16);
        NoteCell cellAt(uint t, uint ln) {
            return take.cells[ln * take.tracks + t];
        }
        assert(cellAt(0, 0).note == NoteCell.encodeMidiNote(60) && cellAt(0, 0).moduleId == gen);
        assert(cellAt(0, 3).note == NoteCmd.noteOff);
        assert(cellAt(0, 4).note == NoteCell.encodeMidiNote(61) && cellAt(1, 4).note == NoteCell.encodeMidiNote(62));
        assert(cellAt(0, 6).note == NoteCmd.noteOff && cellAt(1, 6).note == NoteCmd.noteOff);
        const clip = s.document().clips[$ - 1];
        assert(clip.patternId == take.patternId && clip.startLine == 16 && clip.lengthLines == 16 && clip.laneY == 1);
        assert(s.document().loopStartLine == 0 && s.document().loopEndLine == 20);
        s.engine().processHostBuffer(outs, ins, 256);
        r.frame();
        assert(!s.isPlaying() && r.ctx.telemetry.engine.currentLine == 16);

        assert(s.undo());
        assert(s.document().patterns.length == pats0 && s.document().clips.length == clips0);
        assert(s.redo() && s.document().patterns.length == pats0 + 1);

        r.press(15, KeyModifiers.command);
        assert(r.ctx.liveRecording());
        r.press(15, KeyModifiers.command);
        assert(!r.ctx.liveRecording() && r.ctx.status == "Recording stopped: no notes recorded");
        assert(s.document().patterns.length == pats0 + 1);

        r.press(15, KeyModifiers.command);
        assert(r.ctx.liveRecording());
        r.press(15, KeyModifiers.command | KeyModifiers.shift);
        assert(!r.ctx.liveRecording() && r.ctx.editMode && r.ctx.status == "Edit on");
        r.ctx.editMode = false;

        r.press(15, KeyModifiers.command);
        assert(r.ctx.liveRecording());
        r.press(49);
        assert(!r.ctx.liveRecording());
        s.engine().processHostBuffer(outs, ins, 256);
        assert(!s.isPlaying());

        r.press(15, KeyModifiers.command);
        renderUntil(s.liveTakeStartLine() + 0.2);
        assert(s.stop());
        s.engine().processHostBuffer(outs, ins, 256);
        r.ctx.tick();
        assert(!r.ctx.liveRecording());
    }

    private final class PresetDialog : IFileDialog {
        string openPath;
        string savePath;
        string lastTitle;
        string lastDefaultName;
        string[] lastExtensions;

        override bool openFile(string title, const(FileDialogFilter)[] filters, out string selectedPath) {
            lastTitle = title;
            lastExtensions = filters.length > 0 ? filters[0].extensions.dup : null;
            selectedPath = openPath;
            return openPath.length > 0;
        }

        override bool saveFile(string title, string defaultName, const(FileDialogFilter)[] filters,
                out string selectedPath) {
            lastTitle = title;
            lastDefaultName = defaultName;
            lastExtensions = filters.length > 0 ? filters[0].extensions.dup : null;
            selectedPath = savePath;
            return savePath.length > 0;
        }
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        auto s = r.session;
        auto dlg = new PresetDialog();
        r.ctx.dialogs = dlg;
        immutable string path = buildPath(tempDir(), format("dracker_preset_test_%d.msym", thisProcessID()));
        immutable string badPath = path ~ ".bad";
        scope (exit) {
            if (exists(path)) remove(path);
            if (exists(badPath)) remove(badPath);
        }
        immutable uint gen = s.doAddModule("synth.analog_gen", "Lead");
        immutable uint fm = s.doAddModule("synth.fm_synth", "FM");
        assert(s.doConnectWire(gen, 2, 1, 0, 1.0f));
        assert(s.doSetParam(gen, 0, 1.0f) && s.doSetParam(gen, 3, 900.0f));
        s.history().breakCoalesce();
        r.frame();
        float param(uint mod, uint idx) {
            foreach (ref m; s.document().modules) {
                if (m.id == mod) return m.paramValues[idx];
            }
            return float.nan;
        }
        MenuItem find(MenuItem[] items, string label) {
            foreach (it; items) {
                if (it.label == label) return it;
            }
            return MenuItem.init;
        }

        MenuItem[] nodeItems = r.root.patchbay.nodeMenuItems(gen);
        assert(find(nodeItems, "Save Preset…").enabled && find(nodeItems, "Save Preset…").action !is null);
        assert(find(nodeItems, "Apply Preset…").action !is null);
        MenuItem[] outItems = r.root.patchbay.nodeMenuItems(1);
        assert(find(outItems, "Save Preset…").action !is null && !find(outItems, "Save Preset…").enabled);
        assert(!find(outItems, "Apply Preset…").enabled);
        MenuItem[] canvasItems = r.root.patchbay.addModuleMenuItems(Point2F(321.0f, 123.0f), Point2F(0, 0));
        assert(find(canvasItems, "Load Preset…").action !is null);

        r.ctx.selectModule(0);
        dlg.savePath = path;
        r.press(1, KeyModifiers.command | KeyModifiers.alt);
        assert(!exists(path) && r.ctx.status == "Select a module to save as a preset");
        r.ctx.selectModule(1);
        r.press(1, KeyModifiers.command | KeyModifiers.alt);
        assert(!exists(path));
        r.ctx.selectModule(gen);
        dlg.savePath = null;
        r.press(1, KeyModifiers.command | KeyModifiers.alt);
        assert(!exists(path));
        dlg.savePath = path;
        r.press(1, KeyModifiers.command | KeyModifiers.alt);
        assert(exists(path) && getSize(path) > 16 && r.ctx.status == "Saved preset " ~ baseName(path));
        assert(dlg.lastTitle == "Save Module Preset" && dlg.lastDefaultName == "Lead.msym");
        assert(dlg.lastExtensions == ["msym"]);

        immutable size_t mods0 = s.document().modules.length;
        immutable size_t wires0 = s.document().wires.length;
        immutable size_t undo0 = s.history().undoCount();
        r.press(31, KeyModifiers.command | KeyModifiers.alt);
        assert(s.document().modules.length == mods0);
        dlg.openPath = path;
        r.press(31, KeyModifiers.command | KeyModifiers.alt);
        assert(s.document().modules.length == mods0 + 1 && s.document().wires.length == wires0);
        assert(s.history().undoCount() == undo0 + 1 && dlg.lastTitle == "Load Module Preset");
        const loaded = s.document().modules[$ - 1];
        assert(loaded.typeId == "synth.analog_gen" && loaded.name == "Lead" && loaded.id != gen);
        assert(loaded.paramValues[0] == 1.0f && loaded.paramValues[3] == 900.0f);
        assert(r.ctx.selectedModule() == loaded.id && r.ctx.status == "Loaded preset " ~ baseName(path));
        assert(s.undo() && s.document().modules.length == mods0);

        find(canvasItems, "Load Preset…").action();
        assert(s.document().modules.length == mods0 + 1);
        assert(s.document().modules[$ - 1].posX == 321.0f && s.document().modules[$ - 1].posY == 123.0f);
        assert(s.undo());

        assert(s.doSetParam(gen, 0, 3.0f) && s.doSetParam(gen, 3, 5000.0f));
        s.history().breakCoalesce();
        immutable size_t undo1 = s.history().undoCount();
        find(nodeItems, "Apply Preset…").action();
        assert(param(gen, 0) == 1.0f && param(gen, 3) == 900.0f && s.document().wires.length == wires0);
        assert(s.history().undoCount() == undo1 + 1 && s.history().nextUndoLabel() == "Apply Preset");
        assert(r.ctx.status == "Applied preset " ~ baseName(path));
        assert(s.undo() && param(gen, 0) == 3.0f && param(gen, 3) == 5000.0f);
        assert(s.redo() && param(gen, 3) == 900.0f);
        immutable size_t undo2 = s.history().undoCount();
        assert(r.ctx.applyModulePreset(gen) && s.history().undoCount() == undo2);

        assert(!r.ctx.applyModulePreset(fm));
        assert(r.ctx.status.startsWith("Apply preset failed: Preset is for a different module type"));
        assert(!r.ctx.applyModulePreset(1) && r.ctx.status == "Select a module to apply a preset to");

        write(badPath, "not a preset");
        dlg.openPath = badPath;
        assert(r.ctx.loadModulePreset(0.0f, 0.0f) == 0 && r.ctx.status.startsWith("Load preset failed: "));
        assert(!r.ctx.applyModulePreset(gen) && r.ctx.status.startsWith("Apply preset failed: "));
        dlg.openPath = path ~ ".missing";
        assert(r.ctx.loadModulePreset(0.0f, 0.0f) == 0 && r.ctx.status.startsWith("Load preset failed: "));
        assert(s.document().modules.length == mods0);

        immutable float[2] at = r.ctx.nextModulePosition();
        foreach (ref m; s.document().modules) {
            assert(at[0] >= m.posX + 150.0f);
        }
    }

    private Point2F centerOf(RectF b) {
        return Point2F(b.x + b.w * 0.5f, b.y + b.h * 0.5f);
    }

    unittest {
        Rig r = makeRig();
        scope (exit) r.session.dispose();
        StudioAction[] acts;
        r.root.appCommandHandler = (StudioAction a) { acts ~= a; return true; };

        assert(!r.session.isDirty());
        r.press(45, KeyModifiers.command);
        r.press(31, KeyModifiers.command);
        assert(r.root.requestClose());
        assert(acts == [StudioAction.newProject, StudioAction.openProject, StudioAction.quit]);
        assert(r.root.unsavedPrompt() is null && r.ui.overlays().length == 0);
        acts = null;

        assert(r.session.doAddModule("synth.fm_synth", "Lead", 0.0f, 0.0f) != 0);
        assert(r.session.isDirty());
        r.press(45, KeyModifiers.command);
        ConfirmDialog q = r.root.unsavedPrompt();
        assert(q !is null && acts.length == 0 && r.ui.overlays().length == 1 && r.ui.overlays()[0] is q);
        assert(q.title == "Discard unsaved changes?");
        assert(q.message == "The open project has unsaved changes. Starting a new project discards them.");
        r.press(31, KeyModifiers.command);
        r.press(49);
        assert(r.root.requestClose());
        assert(r.root.unsavedPrompt() is q && r.ui.overlays().length == 1 && acts.length == 0);
        assert(!r.session.isPlaying());
        r.press(53);
        assert(r.root.unsavedPrompt() is null && r.ui.overlays().length == 0 && acts.length == 0);
        assert(r.ctx.status == "Kept the open project");

        r.press(31, KeyModifiers.command);
        q = r.root.unsavedPrompt();
        assert(q.message == "The open project has unsaved changes. Opening another project discards them.");
        r.click(centerOf(q.cancelButton.bounds));
        assert(r.root.unsavedPrompt() is null && acts.length == 0);

        r.press(12, KeyModifiers.command);
        q = r.root.unsavedPrompt();
        assert(q.message == "The open project has unsaved changes. Quitting Dracker discards them.");
        r.click(Point2F(5.0f, 5.0f));
        assert(r.root.unsavedPrompt() is null && acts.length == 0);
        r.press(12, KeyModifiers.command);
        r.click(centerOf(r.root.unsavedPrompt().confirmButton.bounds));
        assert(acts == [StudioAction.quit] && r.root.unsavedPrompt() is null);

        assert(r.root.requestClose() && r.root.unsavedPrompt() !is null);
        r.press(36);
        assert(acts == [StudioAction.quit, StudioAction.quit]);

        auto panel = r.root.openAppearancePanel();
        r.frame();
        assert(panel !is null && r.ui.overlays().length == 1);
        r.press(45, KeyModifiers.command);
        assert(r.ui.overlays().length == 2 && r.root.unsavedPrompt() !is null);
        r.press(53);
        assert(r.ui.overlays().length == 1 && r.ui.overlays()[0] is panel && acts.length == 2);
        r.ui.closeAllOverlays();

        int ran = 0;
        assert(!r.root.confirmDiscardThen("Testing discards them.", () { ran++; }));
        assert(!r.root.confirmDiscardThen("Second request.", () { ran += 10; }));
        assert(r.root.unsavedPrompt().message == "The open project has unsaved changes. Testing discards them.");
        r.press(36);
        assert(ran == 1);

        r.root.appCommandHandler = (StudioAction a) {
            acts ~= a;
            if (a == StudioAction.newProject) {
                r.session.newEmptyProject(true);
            }
            return true;
        };
        r.press(45, KeyModifiers.command);
        r.press(36);
        assert(!r.session.isDirty() && r.session.document().modules.length == 1);
        r.press(45, KeyModifiers.command);
        assert(r.root.unsavedPrompt() is null && acts[$ - 2 .. $] == [StudioAction.newProject, StudioAction.newProject]);

        assert(r.session.doAddModule("synth.fm_synth", "Lead", 0.0f, 0.0f) != 0);
        auto detached = new StudioRoot(r.ctx);
        int ranDetached = 0;
        assert(detached.confirmDiscardThen("x", () { ranDetached++; }) && ranDetached == 1);
        detached.appCommandHandler = null;
        assert(!detached.executeAction(StudioAction.quit));
    }
}
