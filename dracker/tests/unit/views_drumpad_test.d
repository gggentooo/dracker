/**
 * File:         tests/unit/views_drumpad_test.d
 * Module:       tests.unit.views_drumpad_test
 * Phase:        Pattern editor views — T48 (drumpad pads tests)
 *
 * Purpose:
 *   Headless verification of DrumpadView hosted in PatternEditorView: click toggling writing and clearing
 *   cells in one undo step, drag-painting and drag-erasing as single undo groups, vertical velocity drag and
 *   Option-click cycling (and new hits inheriting lane velocity), beat/bar grouping in 4/4 and 6/8, tracker
 *   edits reflecting immediately with custom-hit corner marks when note or module diverges, unassigned-lane
 *   handling and undo restoration, playhead highlight and scrolling for long patterns and many lanes, and
 *   drawing across every built-in palette.
 *
 * Real-Time & Safety Contract:
 *   Test-only; runs single-threaded with HeadlessRenderer.
 *
 * Dependencies:
 *   Internal: app.{keymap,session}, gui.{appearance,renderer,theme,widgets},
 *             gui.views.{drumpad_view,pattern_editor,studio_context}, platform.interfaces, sequencer.note
 *   External: std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites only
 *
 * See_Also:
 *   docs/todo.md (T33, T41, T48)
 */
module tests.unit.views_drumpad_test;

version (unittest) {
    import std.format : format;
    import std.math : abs, ceil;

    import app.session : StudioSession;
    import gui.appearance : builtinPalettes, makeTheme;
    import gui.renderer;
    import gui.theme : ContrastMode;
    import gui.views.drumpad_view : DrumpadView;
    import gui.views.pattern_editor : PatternEditorView, PatternViewKind;
    import gui.views.studio_context : StudioContext;
    import gui.widgets : KeyCode, MenuItem, UiContext;
    import io.project_format : PATTERN_KIND_DRUM, PATTERN_KIND_NORMAL;
    import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;
    import sequencer.note : NoteCell;

    private final class DpRasterizer : IGlyphRasterizer {
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

    private final class DpRig {
        StudioSession s;
        StudioContext ctx;
        PatternEditorView editor;
        DrumpadView pads;
        UiContext ui;
        HeadlessRenderer r;
        uint drumPid;

        this(float w = 960.0f, float h = 600.0f) {
            s = new StudioSession();
            assert(s.initialize(44_100.0f));
            drumPid = s.doAddDrumPattern("Kit");
            assert(drumPid != 0);
            ctx = new StudioContext(s);
            ctx.selectPattern(drumPid);
            editor = new PatternEditorView(ctx);
            pads = editor.drumpadView();
            assert(pads !is null);
            r = new HeadlessRenderer(new GlyphCache(new DpRasterizer()));
            ui = new UiContext(editor);
            ui.layout(RectF(0, 0, w, h), r);
            assert(editor.currentView() == PatternViewKind.drumpad);
            frame();
        }

        void dispose() {
            s.dispose();
        }

        const(DrawList)* frame() {
            ctx.tick();
            ui.layout(ui.viewport(), r);
            ui.renderFrame(r, 2.0f);
            return r.lastDrawList();
        }

        void mouse(PlatformEventKind kind, Point2F p, uint mods = 0) {
            PlatformEvent e;
            e.kind = kind;
            e.x = p.x;
            e.y = p.y;
            e.modifiers = mods;
            ui.handleEvent(e);
        }

        void click(Point2F p, uint mods = 0) {
            mouse(PlatformEventKind.mouseDown, p, mods);
            mouse(PlatformEventKind.mouseUp, p, mods);
        }

        void scroll(Point2F p, float dx, float dy) {
            PlatformEvent e;
            e.kind = PlatformEventKind.mouseScroll;
            e.x = p.x;
            e.y = p.y;
            e.deltaX = dx;
            e.deltaY = dy;
            ui.handleEvent(e);
        }

        void key(uint code, uint mods = 0) {
            PlatformEvent e;
            e.kind = PlatformEventKind.keyDown;
            e.keyCode = code;
            e.modifiers = mods;
            ui.handleEvent(e);
        }
    }

    private bool hasShapeFill(const(DrawList)* dl, ColorRGBA col, RectF within) {
        immutable float[4] want = [col.r, col.g, col.b, col.a];
        immutable RectF px = RectF(within.x * 2.0f, within.y * 2.0f, within.w * 2.0f, within.h * 2.0f);
        foreach (ref inst; dl.instances) {
            if (inst.kind != InstanceKind.shape || inst.colorA != want) {
                continue;
            }
            immutable RectF ir = RectF(inst.rect[0], inst.rect[1], inst.rect[2], inst.rect[3]);
            if (!ir.intersect(px).isEmpty()) {
                return true;
            }
        }
        return false;
    }

    @("drumpad: toggle writes cell, paint and erase are one undo step, velocity drag and Alt cycle")
    unittest {
        auto rig = new DpRig();
        scope (exit) rig.dispose();
        immutable uint pid = rig.drumPid;
        const lanes = rig.s.patternLanes(pid);
        assert(lanes.length == 4);

        float vel = 0.0f;
        bool custom = false;
        assert(!rig.s.drumHitAt(pid, 0, 0, vel, custom));

        rig.click(rig.pads.padRect(0, 0).center());
        assert(rig.s.drumHitAt(pid, 0, 0, vel, custom));
        assert(!custom && abs(vel - StudioSession.DEFAULT_DRUM_VELOCITY) < 0.02f);
        const cell = rig.s.document().patterns[1].cells[0];
        assert(cell.note == lanes[0].note + 1 && cell.moduleId == lanes[0].moduleId);

        assert(rig.s.undo());
        assert(!rig.s.drumHitAt(pid, 0, 0, vel, custom));
        assert(rig.s.redo());
        assert(rig.s.drumHitAt(pid, 0, 0, vel, custom));

        rig.click(rig.pads.padRect(0, 0).center());
        assert(!rig.s.drumHitAt(pid, 0, 0, vel, custom));
        assert(rig.s.undo() && rig.s.drumHitAt(pid, 0, 0, vel, custom));
        assert(rig.s.undo() && !rig.s.drumHitAt(pid, 0, 0, vel, custom));

        rig.mouse(PlatformEventKind.mouseDown, rig.pads.padRect(1, 0).center());
        rig.mouse(PlatformEventKind.mouseMove, rig.pads.padRect(1, 2).center());
        rig.mouse(PlatformEventKind.mouseMove, rig.pads.padRect(1, 4).center());
        rig.mouse(PlatformEventKind.mouseUp, rig.pads.padRect(1, 4).center());
        assert(rig.s.drumHitAt(pid, 1, 0, vel, custom));
        assert(rig.s.drumHitAt(pid, 1, 2, vel, custom));
        assert(rig.s.drumHitAt(pid, 1, 4, vel, custom));
        assert(rig.s.undo());
        assert(!rig.s.drumHitAt(pid, 1, 0, vel, custom) && !rig.s.drumHitAt(pid, 1, 4, vel, custom));

        assert(rig.s.doSetDrumHit(pid, 2, 0, true, 0.8f));
        assert(rig.s.doSetDrumHit(pid, 2, 1, true, 0.8f));
        rig.mouse(PlatformEventKind.mouseDown, rig.pads.padRect(2, 0).center());
        rig.mouse(PlatformEventKind.mouseMove, rig.pads.padRect(2, 1).center());
        rig.mouse(PlatformEventKind.mouseUp, rig.pads.padRect(2, 1).center());
        assert(!rig.s.drumHitAt(pid, 2, 0, vel, custom) && !rig.s.drumHitAt(pid, 2, 1, vel, custom));
        assert(rig.s.undo());
        assert(rig.s.drumHitAt(pid, 2, 0, vel, custom) && rig.s.drumHitAt(pid, 2, 1, vel, custom));

        immutable Point2F vStart = rig.pads.padRect(2, 0).center();
        rig.mouse(PlatformEventKind.mouseDown, vStart);
        rig.mouse(PlatformEventKind.mouseMove, vStart + Point2F(0.0f, 36.0f));
        rig.mouse(PlatformEventKind.mouseUp, vStart + Point2F(0.0f, 36.0f));
        assert(rig.s.drumHitAt(pid, 2, 0, vel, custom));
        assert(vel < 0.5f);
        assert(abs(rig.pads.laneVelocity(2) - vel) < 1e-3f);
        rig.click(rig.pads.padRect(2, 3).center());
        float newVel = 0.0f;
        assert(rig.s.drumHitAt(pid, 2, 3, newVel, custom));
        assert(abs(newVel - vel) < 0.02f);

        rig.click(rig.pads.padRect(2, 0).center(), KeyModifiers.alt);
        assert(rig.s.drumHitAt(pid, 2, 0, vel, custom) && abs(vel - DrumpadView.VELOCITY_MEDIUM) < 0.02f);
        rig.click(rig.pads.padRect(2, 0).center(), KeyModifiers.alt);
        assert(rig.s.drumHitAt(pid, 2, 0, vel, custom) && abs(vel - DrumpadView.VELOCITY_LOUD) < 0.02f);
        rig.click(rig.pads.padRect(2, 0).center(), KeyModifiers.alt);
        assert(rig.s.drumHitAt(pid, 2, 0, vel, custom) && abs(vel - DrumpadView.VELOCITY_SOFT) < 0.02f);
    }

    @("drumpad: grouping in 4/4 and 6/8, tracker sync, custom mark, unassigned lane, and scroll")
    unittest {
        auto rig = new DpRig();
        scope (exit) rig.dispose();
        immutable uint pid = rig.drumPid;

        immutable float stepGap = DrumpadView.PAD_W + DrumpadView.STEP_GAP;
        immutable float beatGap = DrumpadView.PAD_W + DrumpadView.BEAT_GAP;
        immutable float barGap = DrumpadView.PAD_W + DrumpadView.BAR_GAP;

        assert(abs((rig.pads.padRect(0, 1).x - rig.pads.padRect(0, 0).x) - stepGap) < 1e-3f);
        assert(abs((rig.pads.padRect(0, 4).x - rig.pads.padRect(0, 3).x) - beatGap) < 1e-3f);

        assert(rig.s.doSetTimeSignature(6, 8));
        assert(abs((rig.pads.padRect(0, 2).x - rig.pads.padRect(0, 1).x) - beatGap) < 1e-3f);
        assert(abs((rig.pads.padRect(0, 12).x - rig.pads.padRect(0, 11).x) - barGap) < 1e-3f);

        assert(rig.s.doResizePattern(pid, 4, 64));
        const lanes = rig.s.patternLanes(pid);
        assert(rig.s.doPatchCell(pid, 0, 5, NoteCell.makeNote(cast(ubyte)(lanes[0].note + 2), 0.9f,
            cast(ushort) lanes[0].moduleId)));
        const dlCustom = rig.frame();
        immutable RectF p5 = rig.pads.padRect(0, 5);
        assert(hasShapeFill(dlCustom, rig.ctx.theme.padHit, p5));
        assert(hasShapeFill(dlCustom, rig.ctx.theme.panelRaised,
            RectF(p5.right() - 7.0f, p5.y + 2.0f, 5.0f, 5.0f)));

        immutable uint drumModId = lanes[0].moduleId;
        assert(rig.s.doRemoveModule(drumModId));
        assert(!rig.s.isDrumLaneAssigned(pid, 0));
        rig.frame();
        rig.click(rig.pads.padRect(0, 1).center());
        float unusedVel = 0.0f;
        bool unusedCustom = false;
        assert(!rig.s.drumHitAt(pid, 0, 1, unusedVel, unusedCustom));
        assert(rig.ctx.status.length > 0);
        assert(rig.s.undo());
        assert(rig.s.isDrumLaneAssigned(pid, 0));

        foreach (i; 0 .. 16) {
            assert(rig.s.doAddDrumLane(pid, format("Extra %d", i), drumModId, 36));
        }
        rig.frame();
        rig.scroll(rig.pads.padsRect().center(), -200.0f, -150.0f);
        assert(rig.pads.scrollX() > 0.0f && rig.pads.scrollY() > 0.0f);

        foreach (pal; builtinPalettes()) {
            foreach (contrast; [ContrastMode.high, ContrastMode.low]) {
                rig.ctx.theme = makeTheme(pal, contrast);
                rig.ui.setTheme(rig.ctx.theme);
                const dl = rig.frame();
                assert(dl.instances.length > 30);
            }
        }
    }

    @("drumpad: new drum pattern button, convert both ways, lane menu, add lane, audition, and undo")
    unittest {
        auto rig = new DpRig();
        scope (exit) rig.dispose();

        assert(rig.editor.addDrumButton.id == "pattern.addDrum");
        assert(rig.editor.patternMenuButton.id == "pattern.menu");

        immutable size_t count0 = rig.s.document().patterns.length;
        rig.click(rig.editor.addDrumButton.bounds.center());
        rig.frame();
        assert(rig.s.document().patterns.length == count0 + 1);
        immutable uint createdPid = rig.ctx.currentPattern();
        assert(rig.s.patternKind(createdPid) == PATTERN_KIND_DRUM);
        assert(rig.editor.currentView() == PatternViewKind.drumpad);
        assert(rig.s.undo());
        assert(rig.s.document().patterns.length == count0);

        rig.ctx.selectPattern(rig.drumPid);
        rig.frame();

        immutable size_t lanes0 = rig.s.patternLanes(rig.drumPid).length;
        rig.click(rig.pads.addLaneButtonRect().center());
        rig.frame();
        assert(rig.s.patternLanes(rig.drumPid).length == lanes0 + 1);
        assert(rig.s.undo());
        assert(rig.s.patternLanes(rig.drumPid).length == lanes0);

        rig.click(Point2F(rig.pads.laneLabelRect(0).x + 20.0f, rig.pads.laneLabelRect(0).center().y));
        assert(rig.ctx.status != "Lane has no module assigned");

        MenuItem[] laneItems = rig.pads.laneMenuItems(0);
        assert(laneItems.length >= 6);
        MenuItem[] modItems = rig.pads.laneModuleMenuItems(0);
        assert(modItems.length >= 2);
        immutable uint origMod = rig.s.patternLanes(rig.drumPid)[0].moduleId;
        modItems[0].action();
        assert(rig.s.patternLanes(rig.drumPid)[0].moduleId == 0);
        rig.click(Point2F(rig.pads.laneLabelRect(0).x + 20.0f, rig.pads.laneLabelRect(0).center().y));
        assert(rig.ctx.status == "Lane has no module assigned");
        assert(rig.s.undo());
        assert(rig.s.patternLanes(rig.drumPid)[0].moduleId == origMod);

        MenuItem[] noteItems = rig.pads.laneNoteMenuItems(0);
        noteItems[1].action();
        assert(rig.s.patternLanes(rig.drumPid)[0].note == 38);
        assert(rig.s.undo());
        assert(rig.s.patternLanes(rig.drumPid)[0].note == 36);

        assert(rig.pads.beginRenameLane(0) !is null);
        foreach (dchar c; "BD") {
            PlatformEvent te;
            te.kind = PlatformEventKind.textInput;
            te.utf32Char = c;
            rig.ui.handleEvent(te);
        }
        rig.key(KeyCode.returnKey);
        assert(rig.s.patternLanes(rig.drumPid)[0].name == "BD");
        assert(rig.s.undo());
        assert(rig.s.patternLanes(rig.drumPid)[0].name == "Kick");

        laneItems = rig.pads.laneMenuItems(0);
        assert(!laneItems[4].enabled && laneItems[5].enabled);
        laneItems[5].action();
        assert(rig.s.patternLanes(rig.drumPid)[0].name == "Snare"
            && rig.s.patternLanes(rig.drumPid)[1].name == "Kick");
        assert(rig.s.undo());
        assert(rig.s.patternLanes(rig.drumPid)[0].name == "Kick");

        laneItems = rig.pads.laneMenuItems(0);
        assert(laneItems[7].enabled);
        laneItems[7].action();
        assert(rig.s.patternLanes(rig.drumPid).length == lanes0 - 1);
        assert(rig.s.undo());
        assert(rig.s.patternLanes(rig.drumPid).length == lanes0);

        MenuItem[] patMenu = rig.editor.patternMenuItems();
        bool foundConvert = false;
        foreach (ref it; patMenu) {
            if (it.label == "Convert to normal pattern") {
                foundConvert = true;
                it.action();
                break;
            }
        }
        assert(foundConvert);
        assert(rig.s.patternKind(rig.drumPid) == PATTERN_KIND_NORMAL);
        assert(rig.editor.currentView() == PatternViewKind.tracker);
        assert(rig.s.undo());
        assert(rig.s.patternKind(rig.drumPid) == PATTERN_KIND_DRUM);

        rig.ctx.selectPattern(rig.s.document().patterns[0].patternId);
        rig.frame();
        assert(rig.s.patternKind(rig.ctx.currentPattern()) == PATTERN_KIND_NORMAL);
        patMenu = rig.editor.patternMenuItems();
        bool foundToDrum = false;
        foreach (ref it; patMenu) {
            if (it.label == "Convert to drum pattern") {
                foundToDrum = true;
                it.action();
                break;
            }
        }
        assert(foundToDrum);
        assert(rig.s.patternKind(rig.ctx.currentPattern()) == PATTERN_KIND_DRUM);
        assert(rig.editor.currentView() == PatternViewKind.drumpad);
        assert(rig.s.undo());
        assert(rig.s.patternKind(rig.ctx.currentPattern()) == PATTERN_KIND_NORMAL);
    }
}
