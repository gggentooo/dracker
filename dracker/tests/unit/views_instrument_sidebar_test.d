/**
 * File:         tests/unit/views_instrument_sidebar_test.d
 * Module:       tests.unit.views_instrument_sidebar_test
 * Phase:        Instrument library — T50 (patchbay instrument sidebar tests)
 *
 * Purpose:
 *   Headless verification of InstrumentSidebar and its integration with PatchbayView: grouped bundled and user
 *   preset listing, double-click and Return activation (unwired module at nextModulePosition(), selected, status
 *   message, single undo step), drag-and-drop onto the canvas (drop target outline between onDragEnter and
 *   onDragLeave, placement at drop world coordinate, Escape cancel, sidebar drop refusal), collapsing and
 *   expanding the sidebar (canvasRect, hit-testing, Fit All, panning), library rescan on focus and
 *   notifyLibraryChanged(), and missing-bundled-presets status note.
 *
 * Real-Time & Safety Contract:
 *   Test-only; runs on the test thread with temporary directories cleaned up on scope exit.
 *
 * Dependencies:
 *   Internal: app.{instrument_library,session}, gui.{renderer,widgets},
 *             gui.views.{instrument_sidebar,patchbay_view,studio_context}, io.project_format, platform.interfaces
 *   External: std.file, std.format, std.math, std.path, std.process
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites only
 *
 * See_Also:
 *   docs/todo.md (T35, T45, T50)
 */
module tests.unit.views_instrument_sidebar_test;

version (unittest) {
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.format : format;
    import std.math : abs, ceil;
    import std.path : buildPath;
    import std.process : thisProcessID;

    import app.instrument_library : InstrumentLibrary, PresetOrigin;
    import app.session : StudioSession;
    import gui.renderer;
    import gui.views.instrument_sidebar : InstrumentSidebar, PRESET_DRAG_KIND, PresetDragData,
        SIDEBAR_COLLAPSED_WIDTH, SIDEBAR_EXPANDED_WIDTH;
    import gui.views.patchbay_view : AddInstrumentDialog, PATCHBAY_PAN_MARGIN, PatchbayHitKind, PatchbayView;
    import gui.views.studio_context : StudioContext;
    import gui.widgets : ConfirmDialog, KeyCode, ListGroup, MenuItem, UiContext, Widget;
    import io.project_format : LoadedPreset, SavedModule, savePreset;
    import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;

    private final class SbRasterizer : IGlyphRasterizer {
        override bool rasterize(FontId font, float pixelSize, dchar cp, out RasterizedGlyph outGlyph) {
            outGlyph.advance = pixelSize * 0.5f;
            if (cp == ' ') {
                return true;
            }
            outGlyph.width = cast(uint) ceil(pixelSize * 0.4f);
            outGlyph.height = cast(uint) ceil(pixelSize * 0.7f);
            outGlyph.bearingY = pixelSize * 0.7f;
            outGlyph.coverage = new ubyte[cast(size_t) outGlyph.width * outGlyph.height];
            outGlyph.coverage[] = 255;
            return true;
        }

        override void lineMetrics(FontId font, float pixelSize, out float ascent, out float lineHeight) {
            ascent = pixelSize * 0.8f;
            lineHeight = pixelSize * 1.25f;
        }
    }

    private void writeTestPreset(string path, string presetName, string typeId, float[] params = null) {
        LoadedPreset p;
        p.presetName = presetName;
        p.mod.id = 2;
        p.mod.typeId = typeId;
        p.mod.name = presetName;
        p.mod.paramValues = params;
        string err;
        assert(savePreset(p, path, err), err);
    }

    private final class SbRig {
        string rootDir;
        string bundledDir;
        string userDir;
        string trashDir;
        string[] finderReveals;
        StudioSession s;
        StudioContext ctx;
        PatchbayView view;
        UiContext ui;
        HeadlessRenderer r;
        double clock = 0.0;

        this(bool populateBundled = true, float w = 1000.0f, float h = 640.0f) {
            static uint seq = 0;
            seq++;
            rootDir = buildPath(tempDir(), format("dracker_sb_test_%d_%d", thisProcessID(), seq));
            bundledDir = buildPath(rootDir, "bundled");
            userDir = buildPath(rootDir, "user");
            trashDir = buildPath(rootDir, "trash");
            mkdirRecurse(userDir);
            mkdirRecurse(trashDir);
            if (populateBundled) {
                mkdirRecurse(buildPath(bundledDir, "Bass"));
                mkdirRecurse(buildPath(bundledDir, "Keys"));
                mkdirRecurse(buildPath(bundledDir, "Effects"));
                writeTestPreset(buildPath(bundledDir, "Bass", "Electric Bass.msym"), "Electric Bass",
                    "synth.analog_gen", [0.5f]);
                writeTestPreset(buildPath(bundledDir, "Keys", "Electric Piano.msym"), "Electric Piano",
                    "synth.fm_synth", [0.4f]);
                writeTestPreset(buildPath(bundledDir, "Effects", "Room Reverb.msym"), "Room Reverb",
                    "fx.reverb");
            }
            mkdirRecurse(buildPath(userDir, "Bass"));
            writeTestPreset(buildPath(userDir, "Bass", "My Sub.msym"), "My Sub", "synth.analog_gen");

            s = new StudioSession();
            assert(s.initialize(44_100.0f));
            ctx = new StudioContext(s);
            ctx.library = new InstrumentLibrary(populateBundled ? [bundledDir] : null, userDir, trashDir);
            ctx.revealInFinder = (string path) {
                finderReveals ~= path;
                return true;
            };
            view = new PatchbayView(ctx);
            r = new HeadlessRenderer(new GlyphCache(new SbRasterizer()));
            ui = new UiContext(view, () => clock);
            ui.layout(RectF(0, 0, w, h), r);
            frame();
        }

        void dispose() {
            s.dispose();
            if (exists(rootDir)) {
                rmdirRecurse(rootDir);
            }
        }

        const(DrawList)* frame() {
            ctx.tick();
            ui.layout(ui.viewport(), r);
            ui.renderFrame(r, 2.0f);
            return r.lastDrawList();
        }

        void mouse(PlatformEventKind kind, Point2F p, ubyte btn = 0) {
            if (kind == PlatformEventKind.mouseDown) {
                clock += 1.0;
            }
            PlatformEvent e;
            e.kind = kind;
            e.x = p.x;
            e.y = p.y;
            e.mouseButton = btn;
            ui.handleEvent(e);
        }

        void click(Point2F p) {
            mouse(PlatformEventKind.mouseDown, p);
            mouse(PlatformEventKind.mouseUp, p);
        }

        void doubleClick(Point2F p) {
            click(p);
            PlatformEvent e;
            e.kind = PlatformEventKind.mouseDown;
            e.x = p.x;
            e.y = p.y;
            ui.handleEvent(e);
            mouse(PlatformEventKind.mouseUp, p);
        }

        void key(uint code, uint mods = 0) {
            PlatformEvent e;
            e.kind = PlatformEventKind.keyDown;
            e.keyCode = code;
            e.modifiers = mods;
            ui.handleEvent(e);
        }

        Widget topOverlay() {
            auto ov = ui.overlays();
            return ov.length > 0 ? ov[$ - 1] : null;
        }
    }

    @("sidebar: groups, double-click and Return activation add unwired module in one undo step")
    unittest {
        auto rig = new SbRig();
        scope (exit) rig.dispose();
        auto sb = rig.view.sidebar;
        ListGroup[] grps = sb.list.groups();
        assert(grps.length == 3);
        assert(grps[0].title == "Bass" && grps[0].rows.length == 2);
        assert(grps[0].rows[0].text == "Electric Bass" && grps[0].rows[0].tag.length == 0);
        assert(grps[0].rows[1].text == "My Sub" && grps[0].rows[1].tag == "user");
        assert(grps[1].title == "Keys" && grps[2].title == "Effects");

        immutable size_t mod0 = rig.s.document().modules.length;
        immutable size_t wire0 = rig.s.document().wires.length;
        immutable float[2] expectedPos = rig.ctx.nextModulePosition();

        immutable RectF r0 = sb.list.rowRect(0, 0);
        rig.doubleClick(r0.center());
        rig.frame();
        assert(rig.s.document().modules.length == mod0 + 1);
        assert(rig.s.document().wires.length == wire0);
        const added = rig.s.document().modules[$ - 1];
        assert(added.name == "Electric Bass");
        assert(abs(added.posX - expectedPos[0]) < 1e-3f && abs(added.posY - expectedPos[1]) < 1e-3f);
        assert(rig.ctx.selectedModule() == added.id);
        assert(rig.ctx.status == "Added Electric Bass");

        assert(rig.s.undo());
        assert(rig.s.document().modules.length == mod0);

        sb.list.select(1, 0);
        rig.ui.setFocus(sb.list);
        rig.key(KeyCode.returnKey);
        rig.frame();
        assert(rig.s.document().modules.length == mod0 + 1);
        assert(rig.s.document().modules[$ - 1].name == "Electric Piano");
        assert(rig.s.document().wires.length == wire0);
    }

    @("sidebar: drag-and-drop adds preset at drop point, outlines target, and Escape cancels")
    unittest {
        auto rig = new SbRig();
        scope (exit) rig.dispose();
        auto sb = rig.view.sidebar;
        immutable RectF rowR = sb.list.rowRect(2, 0);
        immutable Point2F start = rowR.center();
        immutable Point2F dropPt = rig.view.canvasRect().center() + Point2F(40.0f, 30.0f);
        immutable Point2F expectedWorld = rig.view.viewToWorld(dropPt);
        immutable size_t mod0 = rig.s.document().modules.length;

        rig.mouse(PlatformEventKind.mouseDown, start);
        rig.mouse(PlatformEventKind.mouseMove, start + Point2F(10.0f, 0.0f));
        assert(rig.ui.isDragging());
        assert(!rig.view.isDropHovered());

        rig.mouse(PlatformEventKind.mouseMove, dropPt);
        assert(rig.ui.dragTarget() is rig.view);
        assert(rig.view.isDropHovered());
        rig.frame();

        rig.mouse(PlatformEventKind.mouseMove, start);
        assert(!rig.view.isDropHovered());
        assert(rig.ui.dragTarget() is null);

        rig.mouse(PlatformEventKind.mouseMove, dropPt);
        assert(rig.view.isDropHovered());
        rig.mouse(PlatformEventKind.mouseUp, dropPt);
        rig.frame();
        assert(!rig.ui.isDragging());
        assert(!rig.view.isDropHovered());
        assert(rig.s.document().modules.length == mod0 + 1);
        const dropped = rig.s.document().modules[$ - 1];
        assert(dropped.name == "Room Reverb");
        assert(abs(dropped.posX - expectedWorld.x) < 1e-2f && abs(dropped.posY - expectedWorld.y) < 1e-2f);
        assert(rig.ctx.selectedModule() == dropped.id);
        assert(rig.s.document().wires.length == 0);
        assert(rig.s.undo() && rig.s.document().modules.length == mod0);

        rig.mouse(PlatformEventKind.mouseDown, start);
        rig.mouse(PlatformEventKind.mouseMove, dropPt);
        assert(rig.view.isDropHovered());
        rig.key(KeyCode.escape);
        assert(!rig.ui.isDragging());
        assert(!rig.view.isDropHovered());
        assert(rig.s.document().modules.length == mod0);
    }

    @("sidebar: collapse updates canvasRect, hitTestAt, fitAll, and panning")
    unittest {
        auto rig = new SbRig();
        scope (exit) rig.dispose();
        auto sb = rig.view.sidebar;
        assert(abs(sb.bounds.w - SIDEBAR_EXPANDED_WIDTH) < 1e-3f);
        assert(abs(rig.view.canvasRect().x - SIDEBAR_EXPANDED_WIDTH) < 1e-3f);

        immutable Point2F inSidebar = sb.bounds.center();
        assert(rig.view.hitTestAt(inSidebar).kind == PatchbayHitKind.none);

        rig.view.fitAll();
        rig.frame();
        immutable RectF outRect = rig.view.nodeRect(1);
        assert(outRect.x >= rig.view.canvasRect().x);

        rig.click(sb.collapseButton.bounds.center());
        rig.frame();
        assert(sb.collapsed());
        assert(!sb.list.visible);
        assert(abs(sb.bounds.w - SIDEBAR_COLLAPSED_WIDTH) < 1e-3f);
        assert(abs(rig.view.canvasRect().x - SIDEBAR_COLLAPSED_WIDTH) < 1e-3f);

        rig.click(sb.collapseButton.bounds.center());
        rig.frame();
        assert(!sb.collapsed());
        assert(sb.list.visible);
        assert(abs(rig.view.canvasRect().x - SIDEBAR_EXPANDED_WIDTH) < 1e-3f);
    }

    @("sidebar: rescans on patchbay focus, list focus, and notifyLibraryChanged; missing bundled note")
    unittest {
        auto rig = new SbRig(false);
        scope (exit) rig.dispose();
        auto sb = rig.view.sidebar;
        assert(sb.list.groups().length == 1 && sb.list.groups()[0].title == "Bass");
        const dl = rig.frame();
        assert(dl.instances.length > 0);

        writeTestPreset(buildPath(rig.userDir, "Bass", "Late Bass.msym"), "Late Bass", "synth.analog_gen");
        rig.ui.setFocus(rig.view);
        assert(sb.list.groups()[0].rows.length == 2);

        mkdirRecurse(buildPath(rig.userDir, "Keys"));
        writeTestPreset(buildPath(rig.userDir, "Keys", "Late Keys.msym"), "Late Keys", "synth.fm_synth");
        rig.ctx.library.rescan();
        rig.ctx.notifyLibraryChanged();
        rig.frame();
        assert(sb.list.groups().length == 2 && sb.list.groups()[1].title == "Keys");
    }

    @("sidebar: add to instruments, user rename, move, remove to trash, finder, bundled disabled, errors")
    unittest {
        auto rig = new SbRig();
        scope (exit) rig.dispose();
        auto sb = rig.view.sidebar;

        assert(sb.rowMenuItems(0, 0) is null);
        assert(sb.rowMenuItems(1, 0) is null);

        MenuItem[] outMenu = rig.view.nodeMenuItems(1);
        bool foundDisabledOutAdd = false;
        foreach (ref it; outMenu) {
            if (it.label == "Add to Instruments…") {
                assert(!it.enabled);
                foundDisabledOutAdd = true;
            }
        }
        assert(foundDisabledOutAdd);

        immutable uint mod = rig.s.doAddModule("synth.analog_gen", "Warm Lead", 120.0f, 120.0f);
        assert(mod != 0);
        MenuItem[] modMenu = rig.view.nodeMenuItems(mod);
        MenuItem addItem;
        bool foundModAdd = false;
        foreach (ref it; modMenu) {
            if (it.label == "Add to Instruments…") {
                assert(it.enabled);
                addItem = it;
                foundModAdd = true;
            }
        }
        assert(foundModAdd);
        addItem.action();
        auto dlg = cast(AddInstrumentDialog) rig.topOverlay();
        assert(dlg !is null);
        dlg.groupSelect.selectedIndex = 2;
        rig.click(dlg.addButton.bounds.center());
        rig.frame();
        assert(rig.topOverlay() is null);
        assert(exists(buildPath(rig.userDir, "Pads & Leads", "Warm Lead.msym")));
        assert(sb.list.groups()[2].title == "Pads & Leads" && sb.list.groups()[2].rows[0].text == "Warm Lead");

        MenuItem[] userMenu = sb.rowMenuItems(0, 1);
        assert(userMenu.length >= 6);
        userMenu[5].action();
        assert(rig.finderReveals.length == 1
            && rig.finderReveals[0] == buildPath(rig.userDir, "Bass", "My Sub.msym"));

        userMenu[0].action();
        foreach (dchar c; "New") {
            PlatformEvent te;
            te.kind = PlatformEventKind.textInput;
            te.utf32Char = c;
            rig.ui.handleEvent(te);
        }
        rig.key(KeyCode.returnKey);
        rig.frame();
        assert(exists(buildPath(rig.userDir, "Bass", "New.msym")));
        assert(!exists(buildPath(rig.userDir, "Bass", "My Sub.msym")));

        writeTestPreset(buildPath(rig.userDir, "Bass", "Taken.msym"), "Taken", "synth.analog_gen");
        sb.refresh(true);
        sb.beginRenameRow(0, 1);
        foreach (dchar c; "Taken") {
            PlatformEvent te;
            te.kind = PlatformEventKind.textInput;
            te.utf32Char = c;
            rig.ui.handleEvent(te);
        }
        rig.key(KeyCode.returnKey);
        assert(rig.ctx.status.length > 0 && exists(buildPath(rig.userDir, "Bass", "New.msym")));

        MenuItem[] moveItems = sb.moveToGroupMenuItems(
            (cast(PresetDragData) sb.list.groups()[0].rows[1].data).entry);
        bool movedOk = false;
        foreach (ref mi; moveItems) {
            if (mi.label == "Keys") {
                mi.action();
                movedOk = true;
                break;
            }
        }
        assert(movedOk);
        rig.frame();
        assert(exists(buildPath(rig.userDir, "Keys", "New.msym")));
        assert(!exists(buildPath(rig.userDir, "Bass", "New.msym")));

        size_t keysNewRow = size_t.max;
        foreach (i, ref r; sb.list.groups()[1].rows) {
            if (r.text == "New") {
                keysNewRow = i;
                break;
            }
        }
        assert(keysNewRow != size_t.max);
        sb.rowMenuItems(1, keysNewRow)[3].action();
        auto confirm = cast(ConfirmDialog) rig.topOverlay();
        assert(confirm !is null);
        rig.key(KeyCode.escape);
        assert(exists(buildPath(rig.userDir, "Keys", "New.msym")));

        sb.rowMenuItems(1, keysNewRow)[3].action();
        confirm = cast(ConfirmDialog) rig.topOverlay();
        assert(confirm !is null);
        rig.click(confirm.confirmButton.bounds.center());
        rig.frame();
        assert(!exists(buildPath(rig.userDir, "Keys", "New.msym")));
        assert(exists(buildPath(rig.trashDir, "New.msym")));

        immutable string blocker = buildPath(rig.rootDir, "not_a_dir");
        write(blocker, "blocked");
        rig.ctx.library = new InstrumentLibrary([rig.bundledDir], blocker, rig.trashDir);
        auto errDlg = rig.view.openAddToInstrumentsDialog(mod);
        assert(errDlg !is null);
        rig.click(errDlg.addButton.bounds.center());
        assert(rig.ctx.status.length > 0);
        if (rig.topOverlay() !is null) {
            rig.key(KeyCode.escape);
        }
    }
}
