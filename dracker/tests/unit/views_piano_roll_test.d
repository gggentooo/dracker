/**
 * File:         tests/unit/views_piano_roll_test.d
 * Module:       tests.unit.views_piano_roll_test
 * Phase:        Pattern editor views — T47 & T53 (piano roll display, navigation, and editing tests)
 *
 * Purpose:
 *   Headless verification of PianoRollView hosted in PatternEditorView: note rectangles, module picker
 *   solid vs outline, time-signature grids in 4/4 and 3/4, auto-scroll, scroll, zoom, playhead, palette
 *   rendering, and full editing (click-add, body drag move, Escape cancel, right-edge drag resize,
 *   Option-drag copy, rubber-band selection, velocity strip drag, note audition, Delete, Cut/Copy/Paste,
 *   transpose ±1/±12, single undo step per gesture, automatic track addition with status message, refused
 *   edits using noteEditMessage(), and preservation of other modules' notes and effect columns).
 *
 * Real-Time & Safety Contract:
 *   Test-only; runs single-threaded with HeadlessRenderer.
 *
 * Dependencies:
 *   Internal: app.{keymap,pattern_notes,session}, gui.{appearance,renderer,theme,widgets},
 *             gui.views.{pattern_editor,piano_roll_view,studio_context}, platform.interfaces, sequencer.note
 *   External: std.algorithm (startsWith), std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites only
 *
 * See_Also:
 *   docs/todo.md (T31, T42, T47, T53)
 */
module tests.unit.views_piano_roll_test;

version (unittest) {
    import std.algorithm : startsWith;
    import std.math : abs, ceil;

    import app.keymap : StudioAction, StudioCommandSink;
    import app.pattern_notes : NoteEdit, noteEditMessage, RollNote;
    import app.session : StudioSession;
    import gui.appearance : builtinPalettes, makeTheme;
    import gui.renderer;
    import gui.theme : ContrastMode, StudioTheme;
    import gui.views.pattern_editor : PatternEditorView, PatternViewKind;
    import gui.views.piano_roll_view : PianoRollView;
    import gui.views.studio_context : IStudioClipboard, StudioContext;
    import gui.widgets : KeyCode, UiContext;
    import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;
    import sequencer.note : NoteCell;

    private final class PrRasterizer : IGlyphRasterizer {
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

    private final class PrClipboard : IStudioClipboard {
        string text;
        override string getText() { return text; }
        override bool setText(string t) { text = t; return true; }
    }

    private final class PrRig {
        StudioSession s;
        StudioContext ctx;
        PrClipboard clip;
        PatternEditorView editor;
        PianoRollView roll;
        UiContext ui;
        HeadlessRenderer r;
        uint modA;
        uint modB;

        this(float w = 900.0f, float h = 600.0f) {
            s = new StudioSession();
            assert(s.initialize(44_100.0f));
            modA = s.doAddModule("synth.analog_gen", "Bass");
            modB = s.doAddModule("synth.fm_synth", "Keys");
            assert(modA != 0 && modB != 0);
            clip = new PrClipboard();
            ctx = new StudioContext(s, null, null, clip);
            editor = new PatternEditorView(ctx);
            roll = editor.pianoRollView();
            assert(roll !is null);
            r = new HeadlessRenderer(new GlyphCache(new PrRasterizer()));
            ui = new UiContext(editor);
            ui.layout(RectF(0, 0, w, h), r);
            frame();
        }

        void dispose() {
            s.dispose();
        }

        const(DrawList)* frame() {
            ui.layout(ui.viewport(), r);
            ctx.tick();
            ui.renderFrame(r, 2.0f);
            return r.lastDrawList();
        }

        void openRoll() {
            assert(editor.setView(PatternViewKind.pianoRoll));
            frame();
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

        void key(uint code, uint mods = 0) {
            PlatformEvent e;
            e.kind = PlatformEventKind.keyDown;
            e.keyCode = code;
            e.modifiers = mods;
            ui.handleEvent(e);
        }

        Point2F cellCenter(uint line, ubyte pitch) {
            immutable float x = roll.lineToX(cast(float) line) + roll.lineWidth() * 0.5f;
            immutable float y = roll.pitchToY(pitch) + roll.rowHeight() * 0.5f;
            return Point2F(x, y);
        }

        void scroll(Point2F p, float dx, float dy, uint mods = 0) {
            PlatformEvent e;
            e.kind = PlatformEventKind.mouseScroll;
            e.x = p.x;
            e.y = p.y;
            e.deltaX = dx;
            e.deltaY = dy;
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

    @("piano roll: note rectangles, module picker solid vs outline, and auto-scroll")
    unittest {
        auto rig = new PrRig();
        scope (exit) rig.dispose();
        immutable uint pid = rig.s.document().patterns[0].patternId;
        assert(rig.s.doPatchCell(pid, 0, 2, NoteCell.makeNote(60, 0.8f, cast(ushort) rig.modA)));
        assert(rig.s.doPatchCell(pid, 0, 6, NoteCell.makeNoteOff(cast(ushort) rig.modA)));
        assert(rig.s.doPatchCell(pid, 1, 2, NoteCell.makeNote(64, 0.8f, cast(ushort) rig.modA)));
        assert(rig.s.doPatchCell(pid, 2, 8, NoteCell.makeNote(72, 0.8f, cast(ushort) rig.modB)));

        rig.openRoll();
        assert(rig.roll.bounds == rig.editor.viewRect());
        assert(rig.roll.modulePicker.items == ["Bass", "Keys"]);
        assert(rig.roll.pickedModule() == rig.modA);

        const(RollNote)[] notes = rig.roll.notes();
        assert(notes.length == 3);
        assert(notes[0].pitch == 60 && notes[0].line == 2 && notes[0].length == 4);
        assert(notes[1].pitch == 64 && notes[1].line == 2 && notes[1].length == 62);
        assert(notes[2].pitch == 72 && notes[2].line == 8 && notes[2].moduleId == rig.modB);

        immutable RectF r0 = rig.roll.noteRect(notes[0]);
        immutable RectF r2 = rig.roll.noteRect(notes[2]);
        assert(abs(r0.w - (4.0f * rig.roll.lineWidth() - 1.0f)) < 1e-3f);
        assert(!r0.intersect(rig.roll.gridRect()).isEmpty());
        assert(!r2.intersect(rig.roll.gridRect()).isEmpty());

        const dlA = rig.frame();
        assert(hasShapeFill(dlA, rig.ctx.theme.rollNote, r0));
        assert(!hasShapeFill(dlA, rig.ctx.theme.rollNote, r2));

        assert(rig.roll.selectPickedModule(rig.modB));
        assert(rig.ctx.selectedModule() == rig.modB);
        const dlB = rig.frame();
        assert(!hasShapeFill(dlB, rig.ctx.theme.rollNote, r0));
        assert(hasShapeFill(dlB, rig.ctx.theme.rollNote, r2));
    }

    @("piano roll: time signature grid in 4/4 and 3/4, scroll, zoom, playhead, and tracker sync")
    unittest {
        auto rig = new PrRig();
        scope (exit) rig.dispose();
        rig.openRoll();
        immutable uint pid = rig.s.document().patterns[0].patternId;

        bool hasGridVertical(const(DrawList)* dl, ColorRGBA col, uint line, float expectedW) {
            immutable float x = rig.roll.lineToX(cast(float) line) * 2.0f;
            immutable float[4] want = [col.r, col.g, col.b, col.a];
            immutable RectF grPx = RectF(rig.roll.gridRect().x * 2.0f, rig.roll.gridRect().y * 2.0f,
                rig.roll.gridRect().w * 2.0f, rig.roll.gridRect().h * 2.0f);
            foreach (ref inst; dl.instances) {
                if (inst.kind != InstanceKind.shape || inst.colorA != want) {
                    continue;
                }
                if (abs(inst.rect[0] - x) < 0.1f && abs(inst.rect[2] - expectedW * 2.0f) < 0.1f
                        && inst.rect[1] <= grPx.y + 0.5f && inst.rect[3] >= grPx.h - 1.0f) {
                    return true;
                }
            }
            return false;
        }

        const dl44 = rig.frame();
        assert(hasGridVertical(dl44, rig.ctx.theme.borderStrong, 16, 2.0f));
        assert(hasGridVertical(dl44, rig.ctx.theme.border, 12, 1.0f));
        assert(!hasGridVertical(dl44, rig.ctx.theme.borderStrong, 12, 2.0f));

        assert(rig.s.doSetTimeSignature(3, 4));
        const dl34 = rig.frame();
        assert(hasGridVertical(dl34, rig.ctx.theme.borderStrong, 12, 2.0f));
        assert(!hasGridVertical(dl34, rig.ctx.theme.borderStrong, 16, 2.0f));

        immutable Point2F anchor = rig.roll.gridRect().center();
        immutable float lineBefore = rig.roll.xToLine(anchor.x);
        rig.scroll(anchor, 0.0f, 30.0f, KeyModifiers.command);
        assert(rig.roll.lineWidth() > PianoRollView.DEFAULT_LINE_W);
        assert(abs(rig.roll.xToLine(anchor.x) - lineBefore) < 0.05f);

        rig.scroll(anchor, -40.0f, -25.0f, 0);
        assert(rig.roll.scrollX() > 0.0f);
        StudioCommandSink sink = rig.editor;
        assert(sink.handleStudioAction(StudioAction.zoomReset));
        assert(abs(rig.roll.lineWidth() - PianoRollView.DEFAULT_LINE_W) < 1e-3f);

        assert(rig.s.doPatchCell(pid, 0, 1, NoteCell.makeNote(67, 0.9f, cast(ushort) rig.modA)));
        rig.frame();
        assert(rig.roll.notes().length == 1 && rig.roll.notes()[0].pitch == 67);
        assert(rig.s.undo());
        rig.frame();
        assert(rig.roll.notes().length == 0);

        assert(rig.s.doAddClip(pid, 0, 64) != 0);
        rig.ctx.telemetry.engine.playing = true;
        rig.ctx.telemetry.engine.currentLine = 40;
        rig.ctx.followPlayhead = true;
        rig.r.beginFrame(900.0f, 600.0f, 2.0f);
        rig.ui.draw(rig.r);
        rig.r.endFrame();
        const dlPlay = rig.r.lastDrawList();
        assert(rig.roll.playheadLocalLine() == 40);
        assert(hasGridVertical(dlPlay, rig.ctx.theme.danger, 40, 2.0f));
        assert(rig.roll.lineToX(40.0f) >= rig.roll.gridRect().x
            && rig.roll.lineToX(40.0f) <= rig.roll.gridRect().right());
    }

    @("piano roll: draws cleanly in every built-in palette and contrast mode")
    unittest {
        auto rig = new PrRig();
        scope (exit) rig.dispose();
        immutable uint pid = rig.s.document().patterns[0].patternId;
        assert(rig.s.doPatchCell(pid, 0, 0, NoteCell.makeNote(60, 0.8f, cast(ushort) rig.modA)));
        assert(rig.s.doPatchCell(pid, 1, 4, NoteCell.makeNote(65, 0.8f, cast(ushort) rig.modB)));
        rig.openRoll();

        foreach (pal; builtinPalettes()) {
            foreach (contrast; [ContrastMode.high, ContrastMode.low]) {
                rig.ctx.theme = makeTheme(pal, contrast);
                rig.ui.setTheme(rig.ctx.theme);
                const dl = rig.frame();
                assert(dl.instances.length > 40);
                assert(hasShapeFill(dl, rig.ctx.theme.rollNote, rig.roll.noteRect(rig.roll.notes()[0])));
                foreach (ref cmd; dl.commands) {
                    if (cmd.instanceCount == 0) continue;
                    assert(cmd.scissor.x + cmd.scissor.w <= 1801 && cmd.scissor.y + cmd.scissor.h <= 1201);
                }
            }
        }
    }

    @("piano roll editing: add, move, resize, copy-drag, marquee, velocity, clipboard, transpose, undo")
    unittest {
        auto rig = new PrRig();
        scope (exit) rig.dispose();
        immutable uint pid = rig.s.document().patterns[0].patternId;
        assert(rig.s.doPatchCell(pid, 0, 2, NoteCell.makeNote(60, 0.8f, cast(ushort) rig.modB, 3, 7)));
        rig.s.history().clear();
        rig.openRoll();
        assert(rig.roll.selectPickedModule(rig.modA));

        rig.click(rig.roll.keyRect(62).center());
        assert(rig.roll.auditionCount() >= 1 && rig.roll.lastAuditionedPitch() == 62);

        immutable size_t aud0 = rig.roll.auditionCount();
        rig.click(rig.cellCenter(0, 64));
        assert(rig.roll.notes().length == 2);
        assert(rig.roll.auditionCount() > aud0 && rig.roll.lastAuditionedPitch() == 64);
        RollNote added = rig.roll.notes()[0].moduleId == rig.modA ? rig.roll.notes()[0] : rig.roll.notes()[1];
        assert(added.pitch == 64 && added.line == 0 && added.length == 4);
        assert(rig.s.undo());
        assert(rig.roll.notes().length == 1);
        assert(rig.s.redo());
        assert(rig.roll.notes().length == 2);

        added = rig.roll.notes()[0].moduleId == rig.modA ? rig.roll.notes()[0] : rig.roll.notes()[1];
        immutable Point2F edgePt = Point2F(rig.roll.noteRect(added).right() - 2.0f, rig.roll.noteRect(added).center().y);
        rig.mouse(PlatformEventKind.mouseDown, edgePt);
        rig.mouse(PlatformEventKind.mouseMove, edgePt + Point2F(rig.roll.lineWidth() * 2.0f, 0.0f));
        rig.mouse(PlatformEventKind.mouseUp, edgePt + Point2F(rig.roll.lineWidth() * 2.0f, 0.0f));
        assert(rig.roll.lastNoteLength() == 6);
        assert(rig.s.undo());
        assert(rig.s.redo());

        immutable size_t uBeforeEsc = rig.s.history().undoCount();
        immutable Point2F bodyPt = rig.cellCenter(0, 64);
        rig.mouse(PlatformEventKind.mouseDown, bodyPt);
        rig.mouse(PlatformEventKind.mouseMove, rig.cellCenter(4, 67));
        rig.key(KeyCode.escape);
        rig.mouse(PlatformEventKind.mouseUp, rig.cellCenter(4, 67));
        assert(rig.s.history().undoCount() == uBeforeEsc);
        assert(rig.roll.selectedNotes()[0].line == 0 && rig.roll.selectedNotes()[0].pitch == 64);

        rig.mouse(PlatformEventKind.mouseDown, bodyPt);
        rig.mouse(PlatformEventKind.mouseMove, rig.cellCenter(4, 67));
        rig.mouse(PlatformEventKind.mouseUp, rig.cellCenter(4, 67));
        assert(rig.s.history().undoCount() == uBeforeEsc + 1);
        assert(rig.roll.selectedNotes()[0].line == 4 && rig.roll.selectedNotes()[0].pitch == 67);
        assert(rig.s.undo());
        RollNote undoneNote = rig.roll.notes()[0].moduleId == rig.modA ? rig.roll.notes()[0] : rig.roll.notes()[1];
        assert(undoneNote.line == 0 && undoneNote.pitch == 64);
        assert(rig.s.redo());

        rig.mouse(PlatformEventKind.mouseDown, rig.cellCenter(4, 67), KeyModifiers.alt);
        rig.mouse(PlatformEventKind.mouseMove, rig.cellCenter(12, 71), KeyModifiers.alt);
        rig.mouse(PlatformEventKind.mouseUp, rig.cellCenter(12, 71), KeyModifiers.alt);
        assert(rig.roll.notes().length == 3);
        assert(rig.s.undo());
        assert(rig.roll.notes().length == 2);
        assert(rig.s.redo());

        rig.roll.clearSelection();
        immutable RectF vr = rig.roll.velocityRect();
        assert(!vr.isEmpty());
        immutable float velTargetY = vr.bottom() - 2.0f - (vr.h - 8.0f) * 0.25f;
        immutable float velX = rig.roll.velocityBarRect(rig.roll.notes()[1]).center().x;
        rig.mouse(PlatformEventKind.mouseDown, Point2F(velX, vr.center().y));
        rig.mouse(PlatformEventKind.mouseMove, Point2F(velX, velTargetY));
        rig.mouse(PlatformEventKind.mouseUp, Point2F(velX, velTargetY));
        assert(rig.roll.notes()[1].velocity < 0.35f);
        assert(rig.s.undo());
        assert(rig.roll.notes()[1].velocity > 0.7f);

        immutable Point2F m0 = Point2F(rig.roll.lineToX(0.0f) + 2.0f, rig.roll.pitchToY(75));
        immutable Point2F m1 = Point2F(rig.roll.lineToX(20.0f), rig.roll.pitchToY(62));
        rig.mouse(PlatformEventKind.mouseDown, m0);
        rig.mouse(PlatformEventKind.mouseMove, m1);
        rig.mouse(PlatformEventKind.mouseUp, m1);
        assert(rig.roll.selectedNotes().length == 2);

        rig.key(8, KeyModifiers.command);
        assert(rig.clip.text.startsWith(PianoRollView.ROLL_CLIP_MAGIC));
        rig.key(9, KeyModifiers.command);
        assert(rig.roll.notes().length == 5);
        assert(rig.s.undo());
        assert(rig.roll.notes().length == 3);

        rig.roll.selectAll();
        rig.key(KeyCode.up, KeyModifiers.command);
        bool found68 = false;
        foreach (ref n; rig.roll.selectedNotes()) {
            if (n.pitch == 68) found68 = true;
        }
        assert(found68);
        assert(rig.s.undo());

        rig.key(7, KeyModifiers.command);
        assert(rig.roll.notes().length == 1);
        assert(rig.s.undo());
        assert(rig.roll.notes().length == 3);

        rig.roll.selectAll();
        rig.key(KeyCode.deleteBackward);
        assert(rig.roll.notes().length == 1);
        assert(rig.roll.notes()[0].moduleId == rig.modB && rig.roll.notes()[0].pitch == 60);
        assert(rig.s.document().patterns[0].cells[2 * rig.s.document().patterns[0].tracks + 0].effect == 3);
        assert(rig.s.document().patterns[0].cells[2 * rig.s.document().patterns[0].tracks + 0].effectVal == 7);
    }

    @("piano roll editing: automatic track add status, refused edits, and effect column preservation")
    unittest {
        auto rig = new PrRig();
        scope (exit) rig.dispose();
        immutable uint pid = rig.s.document().patterns[0].patternId;
        assert(rig.s.doResizePattern(pid, 1, 16));
        assert(rig.s.doPatchCell(pid, 0, 4, NoteCell.makeNote(60, 0.8f, cast(ushort) rig.modA, 0x0A, 0x12)));
        rig.s.history().clear();
        rig.openRoll();
        assert(rig.roll.selectPickedModule(rig.modA));

        rig.click(rig.cellCenter(4, 64));
        assert(rig.s.document().patterns[0].tracks == 2);
        assert(rig.ctx.status == "Added track 2");
        assert(rig.s.undo());
        assert(rig.s.document().patterns[0].tracks == 1);

        rig.click(rig.cellCenter(2, 60));
        assert(rig.s.document().patterns[0].tracks == 1);
        assert(rig.ctx.status == noteEditMessage(NoteEdit.samePitchOverlap));

        immutable Point2F origPt = rig.cellCenter(4, 60);
        rig.mouse(PlatformEventKind.mouseDown, origPt);
        rig.mouse(PlatformEventKind.mouseMove, rig.cellCenter(8, 62));
        rig.mouse(PlatformEventKind.mouseUp, rig.cellCenter(8, 62));
        immutable NoteCell movedCell = rig.s.document().patterns[0].cells[8 * 1 + 0];
        assert(movedCell.midiNote() == 62 && movedCell.effect == 0x0A && movedCell.effectVal == 0x12);
    }
}
