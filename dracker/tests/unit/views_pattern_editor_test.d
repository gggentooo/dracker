/**
 * File:         tests/unit/views_pattern_editor_test.d
 * Module:       tests.unit.views_pattern_editor_test
 * Phase:        Phase 8.4 — Tracker Pattern Editor Tests
 *
 * Purpose:
 *   Drives PatternEditorView headlessly over a real StudioSession (HeadlessRenderer + fake glyph rasterizer +
 *   UiContext + synthesized PlatformEvents): cell formatting, cursor navigation/clamping, click and drag
 *   selection, QWERTY entry and audition, hex nibble entry, note-off/delete, clipboard cut/copy/paste through a
 *   fake IStudioClipboard, transpose, interpolate, one-undo-step block operations, live MIDI recording at the
 *   playhead and step recording, follow-playhead scrolling, pattern header operations, and bounded drawing.
 *
 * Real-Time & Safety Contract:
 *   Test-only; renders the Engine through processHostBuffer on the test thread (no audio device).
 *
 * Dependencies:
 *   Internal: app.{keymap,pattern_ops,session}, gui.{renderer,widgets}, gui.views.{pattern_editor,studio_context},
 *             io.project_format, platform.interfaces, sequencer.note
 *   External: std.math, std.algorithm (startsWith, endsWith)
 *
 * Planned API (Types, Functions & Hooks):
 *   - unittest blocks only (helpers: PeRasterizer, PeClipboard, PeRig)
 *
 * See_Also:
 *   dev_plan.md (Phase 8.4)
 */
module tests.unit.views_pattern_editor_test;

version (unittest) {
    import std.algorithm : endsWith, startsWith;
    import std.format : format;
    import std.math : abs, ceil, fabs, isFinite;

    import app.keymap : StudioAction;
    import app.pattern_ops : BLOCK_TEXT_MAGIC, encodeBlockText, PatternBlock;
    import app.session : MidiNoteEvent, StudioSession;
    import gui.renderer;
    import gui.views.pattern_editor;
    import gui.views.studio_context : IStudioClipboard, StudioContext;
    import gui.widgets;
    import io.project_format : SavedPattern;
    import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;
    import sequencer.note : NoteCell, NoteCmd;

    /**
     * Deterministic glyph rasterizer: advance = 0.5 em, line height = 1.25 em.
     */
    class PeRasterizer : IGlyphRasterizer {
        /**
         * Rasterizes a solid box glyph.
         *
         * Params:
         *   font = Font.
         *   pixelSize = Pixel size.
         *   cp = Code point.
         *   outGlyph = Receives the glyph.
         *
         * Returns:
         *   True.
         */
        override bool rasterize(FontId font, float pixelSize, dchar cp, out RasterizedGlyph outGlyph) {
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
         * Reports line metrics.
         *
         * Params:
         *   font = Font.
         *   pixelSize = Pixel size.
         *   ascent = Receives the ascent.
         *   lineHeight = Receives the line height.
         */
        override void lineMetrics(FontId font, float pixelSize, out float ascent, out float lineHeight) {
            ascent = pixelSize * 0.8f;
            lineHeight = pixelSize * 1.25f;
        }
    }

    /**
     * In-memory clipboard.
     */
    class PeClipboard : IStudioClipboard {
        string text;
        size_t writes = 0;

        /**
         * Reads the text.
         *
         * Returns:
         *   Text.
         */
        string getText() {
            return text;
        }

        /**
         * Stores the text.
         *
         * Params:
         *   t = Text.
         *
         * Returns:
         *   True.
         */
        bool setText(string t) {
            text = t;
            writes++;
            return true;
        }
    }

    /**
     * Session + context + editor hosted in a UiContext with a manual clock.
     */
    final class PeRig {
        StudioSession s;
        StudioContext ctx;
        PatternEditorView v;
        UiContext ui;
        HeadlessRenderer r;
        PeClipboard clip;
        double clock = 0.0;
        uint gen = 0;

        /**
         * Builds the rig.
         *
         * Params:
         *   withSynth = Adds an AnalogGen wired to the master output.
         *   w = Viewport width.
         *   h = Viewport height.
         */
        this(bool withSynth = false, float w = 900.0f, float h = 600.0f) {
            s = new StudioSession();
            assert(s.initialize(44_100.0f));
            if (withSynth) {
                gen = s.doAddModule("synth.analog_gen", "Gen");
                assert(gen != 0 && s.doConnectWire(gen, 2, 1, 0, 1.0f));
                assert(s.synchronizeEngine());
            }
            clip = new PeClipboard();
            ctx = new StudioContext(s, null, null, clip);
            v = new PatternEditorView(ctx);
            r = new HeadlessRenderer(new GlyphCache(new PeRasterizer()));
            ui = new UiContext(v, () => clock);
            ui.layout(RectF(0, 0, w, h), r);
            assert(ui.setFocus(v));
            frame();
        }

        /**
         * Runs one studio frame (context tick + draw).
         */
        void frame() {
            ctx.tick();
            ui.renderFrame(r, 1.0f);
        }

        /**
         * Sends a key press.
         *
         * Params:
         *   code = Key code.
         *   mods = Modifiers.
         *
         * Returns:
         *   Handled flag.
         */
        bool key(uint code, uint mods = 0) {
            PlatformEvent e;
            e.kind = PlatformEventKind.keyDown;
            e.keyCode = code;
            e.modifiers = mods;
            return ui.handleEvent(e);
        }

        /**
         * Sends a key release.
         *
         * Params:
         *   code = Key code.
         *
         * Returns:
         *   Handled flag.
         */
        bool keyUp(uint code) {
            PlatformEvent e;
            e.kind = PlatformEventKind.keyUp;
            e.keyCode = code;
            return ui.handleEvent(e);
        }

        /**
         * Sends a mouse event.
         *
         * Params:
         *   kind = Event kind.
         *   p = Position.
         *   mods = Modifiers.
         *   button = Button.
         *
         * Returns:
         *   Handled flag.
         */
        bool mouse(PlatformEventKind kind, Point2F p, uint mods = 0, ubyte button = 0) {
            if (kind == PlatformEventKind.mouseDown) {
                clock += 1.0;
            }
            PlatformEvent e;
            e.kind = kind;
            e.x = p.x;
            e.y = p.y;
            e.modifiers = mods;
            e.mouseButton = button;
            return ui.handleEvent(e);
        }

        /**
         * Clicks at a point.
         *
         * Params:
         *   p = Position.
         *   mods = Modifiers.
         */
        void click(Point2F p, uint mods = 0) {
            mouse(PlatformEventKind.mouseDown, p, mods);
            mouse(PlatformEventKind.mouseUp, p, mods);
        }

        /**
         * Double-clicks at a point (two presses inside the double-click interval).
         *
         * Params:
         *   p = Position.
         */
        void doubleClick(Point2F p) {
            click(p);
            PlatformEvent e;
            e.x = p.x;
            e.y = p.y;
            e.kind = PlatformEventKind.mouseDown;
            ui.handleEvent(e);
            e.kind = PlatformEventKind.mouseUp;
            ui.handleEvent(e);
        }

        /**
         * Sends a scroll event.
         *
         * Params:
         *   p = Position.
         *   dx = Horizontal delta.
         *   dy = Vertical delta.
         *   mods = Modifiers.
         *
         * Returns:
         *   Handled flag.
         */
        bool scroll(Point2F p, float dx, float dy, uint mods = 0) {
            PlatformEvent e;
            e.kind = PlatformEventKind.mouseScroll;
            e.x = p.x;
            e.y = p.y;
            e.deltaX = dx;
            e.deltaY = dy;
            e.modifiers = mods;
            return ui.handleEvent(e);
        }

        /**
         * Returns the current pattern document entry.
         *
         * Returns:
         *   Pattern pointer (valid until the next edit).
         */
        const(SavedPattern)* pattern() {
            foreach (ref p; s.document().patterns) {
                if (p.patternId == ctx.currentPattern()) {
                    return &p;
                }
            }
            return null;
        }

        /**
         * Reads a cell of the current pattern.
         *
         * Params:
         *   t = Track.
         *   l = Line.
         *
         * Returns:
         *   Cell.
         */
        NoteCell cell(uint t, uint l) {
            const sp = pattern();
            return sp.cells[cast(size_t) l * sp.tracks + t];
        }

        /**
         * Writes a cell of the current pattern through the session.
         *
         * Params:
         *   t = Track.
         *   l = Line.
         *   c = Cell.
         */
        void put(uint t, uint l, NoteCell c) {
            assert(s.doPatchCell(ctx.currentPattern(), t, l, c));
        }

        /**
         * Returns the undo depth.
         *
         * Returns:
         *   Undo count.
         */
        size_t undos() {
            return s.history().undoCount();
        }

        /**
         * Renders the engine and returns the output peak.
         *
         * Params:
         *   blocks = 256-frame host buffers to render.
         *
         * Returns:
         *   Peak absolute sample.
         */
        float render(size_t blocks) {
            float[256] l = 0.0f;
            float[256] rr = 0.0f;
            float peak = 0.0f;
            const(float[])[2] ins = [null, null];
            foreach (_; 0 .. blocks) {
                float[][2] outs = [l[], rr[]];
                s.engine().processHostBuffer(outs, ins, 256);
                foreach (i; 0 .. 256) {
                    assert(isFinite(l[i]) && isFinite(rr[i]));
                    immutable float a = fabs(l[i]) > fabs(rr[i]) ? fabs(l[i]) : fabs(rr[i]);
                    peak = a > peak ? a : peak;
                }
            }
            return peak;
        }

        /**
         * Returns the last frame's instance count.
         *
         * Returns:
         *   Instances.
         */
        size_t instances() {
            return r.lastDrawList().instances.length;
        }

        /**
         * Reports whether the last frame contains a shape filled with c whose top edge is at y.
         *
         * Params:
         *   c = Fill color.
         *   y = Expected top edge.
         *
         * Returns:
         *   True if found.
         */
        bool hasShapeAt(ColorRGBA c, float y) {
            foreach (ref inst; r.lastDrawList().instances) {
                if (inst.kind == InstanceKind.shape && inst.colorA == [c.r, c.g, c.b, c.a]
                    && fabs(inst.rect[1] - y) < 0.01f) {
                    return true;
                }
            }
            return false;
        }

        bool hasOutlineAt(ColorRGBA c, float y) {
            foreach (ref inst; r.lastDrawList().instances) {
                if (inst.kind == InstanceKind.shape && inst.colorBorder == [c.r, c.g, c.b, c.a] && inst.borderWidth > 0.0f
                    && fabs(inst.rect[1] - y) < 0.01f) {
                    return true;
                }
            }
            return false;
        }
    }

    unittest {
        assert(formatCellText(NoteCell.init) == "--- .. .. .... ....");
        NoteCell c = NoteCell.makeNote(60, 1.0f, 2, 0x0F, 0x10);
        assert(formatCellText(c) == "C-4 80 02 ..0F 0010");
        c.paramId = 0x0105;
        assert(formatCellText(c) == "C-4 80 02 050F 0110");
        assert(formatCellText(NoteCell.makeNoteOff(3)) == "=== .. 03 .... ....");
        assert(formatCellText(NoteCell.makeParam(5, 2, 1.0f)) == "--- .. 05 03.. 00FF");
        assert(formatCellText(NoteCell.makeEffect(0x1F, 0x80)) == "--- .. .. ..1F 0080");
        NoteCell big;
        big.moduleId = 0x1234;
        assert(formatCellText(big) == "--- .. 34 .... ....");
        NoteCell v0;
        v0.velocity = 1;
        assert(formatCellText(v0) == "--- 00 .. .... ....");
        assert(formatNoteName(NoteCell.encodeMidiNote(0)) == "C--");
        assert(formatNoteName(NoteCell.encodeMidiNote(1)) == "C#-");
        assert(formatNoteName(NoteCell.encodeMidiNote(69)) == "A-4");
        assert(formatNoteName(NoteCell.encodeMidiNote(127)) == "G-9");
        assert(formatNoteName(NoteCell.encodeMidiNote(13)) == "C#0");
        assert(formatNoteName(NoteCmd.empty) == "---");
        assert(formatNoteName(NoteCmd.noteOff) == "===");
        assert(formatNoteName(NoteCmd.allNotesOff) == "AOF");
        assert(formatNoteName(NoteCmd.prevTrack) == "PRV");
        assert(formatNoteName(NoteCmd.setPitch) == "PIT");
        assert(formatNoteName(NoteCmd.stopSong) == "STP");
        assert(formatNoteName(200) == "???");

        CellText ct = formatCell(NoteCell.init);
        assert(ct.noteEmpty && ct.velocityEmpty && ct.moduleEmpty && ct.controllerEmpty && ct.effectEmpty
            && ct.valueEmpty);
        ct = formatCell(NoteCell.makeNote(60, 0.5f, 1, 2, 3));
        assert(!ct.noteEmpty && !ct.velocityEmpty && !ct.moduleEmpty && ct.controllerEmpty && !ct.effectEmpty
            && !ct.valueEmpty);
        assert(ct.velocity == "40");

        assert(velocityToDisplay(0) == 0 && velocityToDisplay(1) == 0 && velocityToDisplay(255) == 0x80);
        assert(velocityToDisplay(NoteCell.encodeVelocity(0.5f)) == 0x40);
        foreach (d; 0 .. 129) {
            assert(velocityToDisplay(velocityFromDisplay(d)) == d);
        }
        assert(velocityFromDisplay(0) == 1 && velocityFromDisplay(0x80) == 255 && velocityFromDisplay(0xFF) == 255);

        assert(fieldGroup(0) == 0 && fieldGroup(1) == 1 && fieldGroup(2) == 1 && fieldGroup(3) == 2
            && fieldGroup(6) == 3 && fieldGroup(7) == 4 && fieldGroup(10) == 5 && fieldGroup(12) == 6);
        assert(hexNibbleForKey(29) == 0 && hexNibbleForKey(18) == 1 && hexNibbleForKey(25) == 9
            && hexNibbleForKey(0) == 10 && hexNibbleForKey(11) == 11 && hexNibbleForKey(8) == 12
            && hexNibbleForKey(2) == 13 && hexNibbleForKey(14) == 14 && hexNibbleForKey(3) == 15
            && hexNibbleForKey(6) == -1 && hexNibbleForKey(12) == -1);
    }

    unittest {
        NoteCell c;
        c = setFieldNibble(c, PatternField.velocityHi, 4);
        assert(velocityToDisplay(c.velocity) == 0x40);
        c = setFieldNibble(c, PatternField.velocityLo, 2);
        assert(c.velocity == velocityFromDisplay(0x42));
        assert(setFieldNibble(NoteCell.init, PatternField.velocityHi, 0xF).velocity == 255);
        c = setFieldNibble(c, PatternField.moduleHi, 1);
        c = setFieldNibble(c, PatternField.moduleLo, 0xA);
        assert(c.moduleId == 0x1A);
        NoteCell hiMod;
        hiMod.moduleId = 0x0300;
        assert(setFieldNibble(hiMod, PatternField.moduleLo, 2).moduleId == 0x0302);
        c = setFieldNibble(c, PatternField.controllerHi, 0);
        c = setFieldNibble(c, PatternField.controllerLo, 3);
        assert(c.paramId == 0x03);
        c = setFieldNibble(c, PatternField.effectHi, 1);
        c = setFieldNibble(c, PatternField.effectLo, 0xF);
        assert(c.effect == 0x1F);
        c = setFieldNibble(c, PatternField.xxHi, 0);
        c = setFieldNibble(c, PatternField.xxLo, 1);
        assert(c.paramId == 0x0103);
        c = setFieldNibble(c, PatternField.yyHi, 0xB);
        c = setFieldNibble(c, PatternField.yyLo, 0xE);
        assert(c.effectVal == 0xBE);
        assert(formatCellText(c) == "--- 42 1A 031F 01BE");
        assert(setFieldNibble(c, PatternField.note, 5) == c);
        assert(setFieldNibble(c, 99, 5) == c);

        NoteCell full = NoteCell.makeNote(60, 1.0f, 7, 0x1F, 0x22);
        full.paramId = 0x0204;
        assert(clearField(full, PatternField.velocityLo).velocity == 0);
        assert(clearField(full, PatternField.moduleHi).moduleId == 0);
        assert(clearField(full, PatternField.controllerLo).paramId == 0x0200);
        assert(clearField(full, PatternField.effectHi).effect == 0);
        assert(clearField(full, PatternField.xxLo).paramId == 0x0004);
        assert(clearField(full, PatternField.yyHi).effectVal == 0);
        assert(clearField(full, PatternField.note).isEmpty());
        immutable NoteCell partial = clearField(full, PatternField.effectLo);
        assert(partial.note == full.note && partial.velocity == full.velocity && partial.moduleId == 7
            && partial.effectVal == 0x22);
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        assert(v.id == "pattern.editor" && v.patternSelect.id == "pattern.select" && v.tracksBox.id == "pattern.tracks"
            && v.linesBox.id == "pattern.lines" && v.addButton.id == "pattern.add"
            && v.duplicateButton.id == "pattern.duplicate" && v.deleteButton.id == "pattern.delete");
        assert(v.cursorTrack() == 0 && v.cursorLine() == 0 && v.cursorField() == 0 && !v.hasSelection());
        foreach (i; 0 .. 12) {
            assert(rig.key(KeyCode.right));
        }
        assert(v.cursorTrack() == 0 && v.cursorField() == 12);
        rig.key(KeyCode.right);
        assert(v.cursorTrack() == 1 && v.cursorField() == 0);
        rig.key(KeyCode.left);
        assert(v.cursorTrack() == 0 && v.cursorField() == 12);
        v.setCursor(0, 0, 0);
        rig.key(KeyCode.left);
        assert(v.cursorTrack() == 0 && v.cursorField() == 0);
        rig.key(KeyCode.up);
        assert(v.cursorLine() == 0);
        foreach (i; 0 .. 3) {
            rig.key(KeyCode.down);
        }
        assert(v.cursorLine() == 3);
        rig.key(KeyCode.pageDown);
        assert(v.cursorLine() == 19);
        rig.key(KeyCode.pageUp);
        assert(v.cursorLine() == 3);
        rig.key(KeyCode.pageUp);
        assert(v.cursorLine() == 0);
        rig.key(KeyCode.end);
        assert(v.cursorLine() == 63);
        assert(v.scrollLine() <= 63 && 63 < v.scrollLine() + v.visibleLineCount());
        assert(v.scrollLine() > 0);
        rig.key(KeyCode.pageDown);
        rig.key(KeyCode.down);
        assert(v.cursorLine() == 63);
        rig.key(KeyCode.home);
        assert(v.cursorLine() == 0 && v.scrollLine() == 0);
        v.setCursor(3, 0, 12);
        rig.key(KeyCode.right);
        assert(v.cursorTrack() == 3 && v.cursorField() == 12);
        v.setCursor(99, 999, 50);
        assert(v.cursorTrack() == 3 && v.cursorLine() == 63 && v.cursorField() == 12);

        v.setCursor(0, 0, 0);
        assert(rig.key(KeyCode.tab));
        assert(v.cursorTrack() == 0 && rig.cell(0, 0).isEmpty());
        assert(rig.s.keymap().bindAction(StudioAction.noteOffEntry, 50, KeyModifiers.none));
        assert(rig.key(KeyCode.tab));
        assert(v.cursorTrack() == 1);
        assert(rig.key(KeyCode.tab, KeyModifiers.shift));
        assert(v.cursorTrack() == 0);
        rig.key(KeyCode.tab, KeyModifiers.shift);
        assert(v.cursorTrack() == 3);
        assert(rig.key(KeyCode.right, KeyModifiers.alt));
        assert(v.cursorTrack() == 0);
        assert(rig.key(KeyCode.left, KeyModifiers.alt));
        assert(v.cursorTrack() == 3);
        assert(!rig.key(KeyCode.space));
        assert(!rig.s.isPlaying());
        assert(!v.isAnimating());
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        immutable RectF f = v.fieldRect(2, 5, 7);
        rig.click(f.center());
        assert(v.cursorTrack() == 2 && v.cursorLine() == 5 && v.cursorField() == 7 && !v.hasSelection());
        foreach (fi; 0 .. PATTERN_FIELD_COUNT) {
            rig.click(v.fieldRect(1, 1, fi).center());
            assert(v.cursorTrack() == 1 && v.cursorLine() == 1 && v.cursorField() == fi);
        }
        immutable RectF c = v.cellRect(0, 9);
        rig.click(Point2F(c.x - 10.0f, c.y + c.h * 0.5f));
        assert(v.cursorLine() == 9 && v.cursorTrack() == 1 && v.cursorField() == 0);
        immutable RectF beyond = v.cellRect(4, 2);
        assert(!rig.mouse(PlatformEventKind.mouseDown, beyond.center()));
        rig.mouse(PlatformEventKind.mouseUp, beyond.center());
        assert(v.cursorLine() == 9);
        assert(rig.ui.focused is v);

        rig.mouse(PlatformEventKind.mouseDown, v.cellRect(1, 2).center());
        rig.mouse(PlatformEventKind.mouseMove, v.cellRect(2, 4).center());
        rig.mouse(PlatformEventKind.mouseMove, v.cellRect(3, 6).center());
        rig.mouse(PlatformEventKind.mouseUp, v.cellRect(3, 6).center());
        assert(v.hasSelection() && v.selection() == [1u, 2u, 3u, 6u]);
        assert(v.cursorTrack() == 3 && v.cursorLine() == 6);
        rig.frame();
        assert(rig.hasShapeAt(rig.ui.theme.selection, v.cellRect(1, 2).y));
        assert(rig.hasOutlineAt(rig.ui.theme.accent, v.cellRect(1, 2).y));

        rig.mouse(PlatformEventKind.mouseDown, v.cellRect(3, 6).center());
        rig.mouse(PlatformEventKind.mouseMove, v.cellRect(0, 1).center());
        rig.mouse(PlatformEventKind.mouseUp, v.cellRect(0, 1).center());
        assert(v.selection() == [0u, 1u, 3u, 6u]);

        rig.click(v.cellRect(2, 2).center());
        assert(!v.hasSelection());
        v.setCursor(1, 1);
        rig.click(v.cellRect(2, 4).center(), KeyModifiers.shift);
        assert(v.hasSelection() && v.selection() == [1u, 1u, 2u, 4u]);

        v.setCursor(0, 0, 0);
        rig.key(KeyCode.down, KeyModifiers.shift);
        rig.key(KeyCode.down, KeyModifiers.shift);
        foreach (i; 0 .. 13) {
            rig.key(KeyCode.right, KeyModifiers.shift);
        }
        assert(v.hasSelection() && v.selection() == [0u, 0u, 1u, 2u]);
        rig.key(KeyCode.down);
        assert(!v.hasSelection() && v.selection() == [1u, 3u, 1u, 3u]);

        rig.mouse(PlatformEventKind.mouseDown, v.cellRect(0, 0).center(), 0, 1);
        assert(rig.ui.overlays().length == 1);
        rig.ui.closeAllOverlays();
    }

    unittest {
        auto rig = new PeRig(true);
        auto v = rig.v;
        auto ctx = rig.ctx;
        ctx.selectModule(rig.gen);
        ctx.editMode = true;
        ctx.editOctave = 5;
        ctx.editStep = 2;
        v.setCursor(0, 0, 0);
        immutable size_t u0 = rig.undos();
        assert(rig.key(6));
        NoteCell c = rig.cell(0, 0);
        assert(c.note == NoteCell.encodeMidiNote(72) && c.velocity == 255 && c.moduleId == rig.gen);
        assert(v.cursorLine() == 2 && rig.undos() == u0 + 1);
        assert(rig.keyUp(6));
        rig.key(1);
        rig.keyUp(1);
        assert(rig.cell(0, 2).note == NoteCell.encodeMidiNote(73) && v.cursorLine() == 4);
        assert(rig.undos() == u0 + 2);
        assert(rig.s.undo());
        assert(rig.cell(0, 2).isEmpty() && !rig.cell(0, 0).isEmpty());
        assert(rig.s.redo());

        rig.put(0, 4, NoteCell.makeEffect(0x1F, 5));
        rig.key(6);
        rig.keyUp(6);
        c = rig.cell(0, 4);
        assert(c.note == NoteCell.encodeMidiNote(72) && c.effect == 0x1F && c.effectVal == 5);

        ctx.selectModule(0);
        v.setCursor(0, 10, 0);
        rig.key(6);
        rig.keyUp(6);
        assert(rig.cell(0, 10).moduleId == rig.gen);
        v.setCursor(1, 0, 0);
        rig.key(6);
        rig.keyUp(6);
        assert(rig.cell(1, 0).moduleId == 0 && rig.cell(1, 0).note == NoteCell.encodeMidiNote(72));
        NoteCell keep;
        keep.moduleId = 9;
        rig.put(2, 0, keep);
        v.setCursor(2, 0, 0);
        rig.key(6);
        rig.keyUp(6);
        assert(rig.cell(2, 0).moduleId == 9);

        ctx.editStep = 0;
        ctx.editOctave = 3;
        v.setCursor(3, 7, 0);
        rig.key(12);
        rig.keyUp(12);
        assert(rig.cell(3, 7).note == NoteCell.encodeMidiNote(60) && v.cursorLine() == 7);

        v.setCursor(3, 8, PatternField.velocityHi);
        immutable size_t u1 = rig.undos();
        assert(rig.key(6));
        rig.keyUp(6);
        assert(rig.cell(3, 8).isEmpty() && rig.undos() == u1);

        rig.render(400);
        ctx.editMode = false;
        ctx.selectModule(rig.gen);
        v.setCursor(3, 20, 0);
        immutable float quiet = rig.render(8);
        assert(quiet < 1.0e-4f);
        immutable size_t u2 = rig.undos();
        assert(rig.key(6));
        assert(rig.cell(3, 20).isEmpty() && rig.undos() == u2 && v.cursorLine() == 20);
        immutable float loud = rig.render(16);
        assert(loud > 1.0e-3f);
        assert(rig.keyUp(6));
        assert(!rig.keyUp(6));
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        rig.ctx.editMode = true;
        rig.ctx.editStep = 0;
        immutable uint[2][12] keys = [
            [1, 21], [2, 19], [3, 18], [4, 0], [5, 29], [6, 20], [7, 18], [8, 3], [9, 29], [10, 18],
            [11, 11], [12, 14]
        ];
        immutable size_t u0 = rig.undos();
        foreach (k; keys) {
            v.setCursor(0, 0, k[0]);
            assert(rig.key(k[1]));
        }
        assert(rig.undos() == u0 + 10);
        assert(formatCellText(rig.cell(0, 0)) == "--- 42 1A 031F 01BE");
        assert(rig.cell(0, 0).velocity == velocityFromDisplay(0x42));
        assert(v.cursorLine() == 0);

        rig.ctx.editStep = 1;
        v.setCursor(1, 0, PatternField.effectHi);
        rig.key(20);
        assert(rig.cell(1, 0).effect == 0x30 && v.cursorLine() == 1 && v.cursorField() == PatternField.effectHi);

        rig.ctx.editMode = false;
        v.setCursor(2, 0, PatternField.velocityHi);
        immutable size_t u1 = rig.undos();
        assert(!rig.key(0));
        rig.key(21);
        assert(rig.cell(2, 0).isEmpty() && rig.undos() == u1);
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        rig.put(0, 0, NoteCell.makeNote(60, 1.0f, 2, 0x1F, 5));
        v.setCursor(0, 0, PatternField.effectLo);
        immutable size_t u0 = rig.undos();
        assert(rig.key(KeyCode.deleteBackward));
        NoteCell c = rig.cell(0, 0);
        assert(c.effect == 0 && c.effectVal == 5 && c.note == NoteCell.encodeMidiNote(60) && c.moduleId == 2);
        assert(v.cursorLine() == 1 && rig.undos() == u0 + 1);
        v.setCursor(0, 0, PatternField.note);
        rig.key(KeyCode.deleteBackward);
        assert(rig.cell(0, 0).isEmpty() && rig.undos() == u0 + 2);
        assert(rig.s.undo());
        assert(rig.cell(0, 0).note == NoteCell.encodeMidiNote(60) && rig.cell(0, 0).effect == 0);

        foreach (t; 0 .. 4) {
            foreach (l; 0 .. 4) {
                rig.put(t, l, NoteCell.makeNote(40 + t + l));
            }
        }
        v.setCursor(1, 1, 0);
        rig.key(KeyCode.down, KeyModifiers.shift);
        rig.key(KeyCode.down, KeyModifiers.shift);
        foreach (i; 0 .. 13) {
            rig.key(KeyCode.right, KeyModifiers.shift);
        }
        assert(v.selection() == [1u, 1u, 2u, 3u]);
        immutable size_t u1 = rig.undos();
        assert(rig.key(KeyCode.forwardDelete));
        assert(rig.undos() == u1 + 1);
        foreach (t; 0 .. 4) {
            foreach (l; 0 .. 4) {
                immutable bool inside = t >= 1 && t <= 2 && l >= 1 && l <= 3;
                assert(rig.cell(t, l).isEmpty() == inside);
            }
        }
        assert(rig.s.undo());
        assert(!rig.cell(1, 1).isEmpty() && !rig.cell(2, 3).isEmpty());
        assert(v.hasSelection());
        assert(rig.key(KeyCode.deleteBackward));
        assert(rig.undos() == u1 + 1 && rig.cell(2, 3).isEmpty() && !rig.cell(3, 3).isEmpty());
        assert(rig.s.undo());
        assert(rig.v.handleStudioAction(StudioAction.deleteBlock));
        assert(rig.undos() == u1 + 1 && rig.cell(1, 2).isEmpty());
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        rig.put(0, 0, NoteCell.makeNote(60));
        rig.put(1, 0, NoteCell.makeNote(62, 0.5f, 3));
        rig.put(0, 1, NoteCell.makeNote(64, 1.0f, 0, 0x1F, 7));
        v.setCursor(0, 0, 0);
        rig.key(KeyCode.down, KeyModifiers.shift);
        foreach (i; 0 .. 13) {
            rig.key(KeyCode.right, KeyModifiers.shift);
        }
        assert(v.selection() == [0u, 0u, 1u, 1u]);
        immutable size_t u0 = rig.undos();
        assert(rig.key(8, KeyModifiers.command));
        assert(rig.undos() == u0 && rig.clip.writes == 1);
        assert(rig.clip.text.startsWith(BLOCK_TEXT_MAGIC ~ " 2 2\n"));

        v.setCursor(2, 10, 0);
        assert(rig.key(9, KeyModifiers.command));
        assert(rig.undos() == u0 + 1);
        assert(rig.cell(2, 10) == rig.cell(0, 0) && rig.cell(3, 10) == rig.cell(1, 0)
            && rig.cell(2, 11) == rig.cell(0, 1) && rig.cell(3, 11).isEmpty());
        assert(v.hasSelection() && v.selection() == [2u, 10u, 3u, 11u]);
        assert(rig.s.undo());
        assert(rig.cell(2, 10).isEmpty() && rig.cell(3, 10).isEmpty());

        v.setCursor(3, 63, 0);
        rig.key(9, KeyModifiers.command);
        assert(rig.cell(3, 63) == rig.cell(0, 0));
        assert(v.selection() == [3u, 63u, 3u, 63u]);
        assert(rig.undos() == u0 + 1);

        PatternBlock b = PatternBlock.create(1, 3);
        b.set(0, 0, NoteCell.makeNote(70));
        b.set(0, 2, NoteCell.makeNoteOff(4));
        rig.clip.text = encodeBlockText(b);
        v.setCursor(1, 20, 0);
        rig.key(9, KeyModifiers.command);
        assert(rig.cell(1, 20).note == NoteCell.encodeMidiNote(70) && rig.cell(1, 21).isEmpty()
            && rig.cell(1, 22).note == NoteCmd.noteOff && rig.cell(1, 22).moduleId == 4);
        assert(rig.undos() == u0 + 2);

        rig.clip.text = "garbage";
        v.setCursor(0, 30, 0);
        assert(rig.key(9, KeyModifiers.command));
        assert(rig.undos() == u0 + 2 && rig.cell(0, 30).isEmpty());
        assert(rig.ctx.status.startsWith("Paste:"));

        v.setCursor(0, 0, 0);
        rig.key(KeyCode.down, KeyModifiers.shift);
        immutable NoteCell a0 = rig.cell(0, 0);
        immutable NoteCell a1 = rig.cell(0, 1);
        immutable size_t u1 = rig.undos();
        assert(rig.key(7, KeyModifiers.command));
        assert(rig.undos() == u1 + 1);
        assert(rig.cell(0, 0).isEmpty() && rig.cell(0, 1).isEmpty() && !rig.cell(1, 0).isEmpty());
        assert(rig.clip.text.startsWith(BLOCK_TEXT_MAGIC ~ " 1 2\n"));
        v.setCursor(2, 40, 0);
        rig.key(9, KeyModifiers.command);
        assert(rig.cell(2, 40) == a0 && rig.cell(2, 41) == a1);
        assert(rig.s.undo() && rig.s.undo());
        assert(rig.cell(0, 0) == a0 && rig.cell(0, 1) == a1);
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        rig.put(0, 0, NoteCell.makeNote(60));
        rig.put(0, 1, NoteCell.makeNote(127));
        rig.put(0, 2, NoteCell.makeNoteOff());
        rig.put(1, 0, NoteCell.makeNote(120));
        assert(rig.key(0, KeyModifiers.command));
        assert(v.selection() == [0u, 0u, 3u, 63u]);
        immutable size_t u0 = rig.undos();
        assert(rig.key(KeyCode.up, KeyModifiers.command));
        assert(rig.undos() == u0 + 1);
        assert(rig.cell(0, 0).midiNote() == 61 && rig.cell(0, 1).midiNote() == 127
            && rig.cell(0, 2).note == NoteCmd.noteOff && rig.cell(1, 0).midiNote() == 121);
        assert(rig.key(KeyCode.up, KeyModifiers.command | KeyModifiers.shift));
        assert(rig.undos() == u0 + 2);
        assert(rig.cell(0, 0).midiNote() == 73 && rig.cell(1, 0).midiNote() == 121);
        rig.key(KeyCode.down, KeyModifiers.command);
        assert(rig.cell(0, 0).midiNote() == 72 && rig.cell(0, 1).midiNote() == 126);
        rig.key(KeyCode.down, KeyModifiers.command | KeyModifiers.shift);
        assert(rig.cell(0, 0).midiNote() == 60 && rig.cell(0, 1).midiNote() == 114 && rig.cell(1, 0).midiNote() == 108);
        assert(rig.undos() == u0 + 4);
        assert(rig.s.undo());
        assert(rig.cell(0, 0).midiNote() == 72);

        v.setCursor(0, 0, 0);
        rig.key(KeyCode.up, KeyModifiers.command);
        assert(rig.cell(0, 0).midiNote() == 73 && rig.cell(1, 0).midiNote() == 120);
        rig.put(2, 5, NoteCell.makeNote(0));
        v.setCursor(2, 5, 0);
        immutable size_t u1 = rig.undos();
        assert(rig.key(KeyCode.down, KeyModifiers.command));
        assert(rig.cell(2, 5).midiNote() == 0 && rig.undos() == u1);
        v.setCursor(3, 9, 0);
        assert(rig.v.handleStudioAction(StudioAction.transposeOctaveUp));
        assert(rig.undos() == u1);
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        rig.put(0, 0, NoteCell.makeNote(60, 0.0f));
        rig.put(0, 4, NoteCell.makeNote(64, 1.0f));
        v.setCursor(0, 0, PatternField.velocityLo);
        immutable size_t u0 = rig.undos();
        assert(!rig.v.handleStudioAction(StudioAction.interpolate));
        assert(rig.undos() == u0);
        foreach (i; 0 .. 4) {
            rig.key(KeyCode.down, KeyModifiers.shift);
        }
        assert(v.selection() == [0u, 0u, 0u, 4u]);
        assert(rig.key(34, KeyModifiers.command));
        assert(rig.undos() == u0 + 1);
        assert(rig.cell(0, 0).velocity == 1 && rig.cell(0, 4).velocity == 255);
        assert(rig.cell(0, 1).velocity == 65 && rig.cell(0, 2).velocity == 128 && rig.cell(0, 3).velocity == 192);
        assert(rig.cell(0, 2).note == 0);

        rig.put(1, 0, NoteCell.makeEffect(1, 0));
        rig.put(1, 4, NoteCell.makeEffect(1, 0x40));
        v.setCursor(1, 0, PatternField.yyLo);
        foreach (i; 0 .. 4) {
            rig.key(KeyCode.down, KeyModifiers.shift);
        }
        rig.key(34, KeyModifiers.command);
        assert(rig.cell(1, 2).effectVal == 0x20 && rig.cell(1, 1).effectVal == 0x10);

        rig.put(2, 0, NoteCell.makeParam(1, 0, 0.0f));
        NoteCell p4 = NoteCell.makeParam(1, 8, 0.0f);
        rig.put(2, 4, p4);
        v.setCursor(2, 0, PatternField.controllerHi);
        foreach (i; 0 .. 4) {
            rig.key(KeyCode.down, KeyModifiers.shift);
        }
        immutable size_t u1 = rig.undos();
        rig.key(34, KeyModifiers.command);
        assert(rig.undos() == u1 + 1 && rig.cell(2, 2).paramId == 5);
        assert(rig.s.undo());
        assert(rig.cell(2, 2).isEmpty());
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        auto ctx = rig.ctx;
        ctx.editMode = true;
        v.setCursor(1, 0, 0);
        assert(rig.s.play());
        rig.render(100);
        rig.frame();
        assert(ctx.telemetry.engine.playing);
        immutable long line = ctx.telemetry.engine.currentLine;
        assert(line > 0 && line < 64);
        assert(v.playheadLocalLine() == line);
        immutable size_t u0 = rig.undos();
        ctx.injectMidiNote(MidiNoteEvent(0, 64, 127, line));
        rig.frame();
        NoteCell c = rig.cell(1, cast(uint) line);
        assert(c.note == NoteCell.encodeMidiNote(64) && c.velocity == 255);
        assert(v.cursorLine() == 0 && rig.undos() == u0 + 1);

        ctx.injectMidiNote(MidiNoteEvent(0, 60, 64, 40));
        ctx.injectMidiNote(MidiNoteEvent(0, 67, 64, 40));
        rig.frame();
        assert(rig.cell(1, 40).note == NoteCell.encodeMidiNote(60) && rig.cell(2, 40).note == NoteCell.encodeMidiNote(67));
        assert(rig.cell(1, 40).velocity == NoteCell.encodeVelocity(64 / 127.0f));

        immutable size_t u1 = rig.undos();
        ctx.injectMidiNote(MidiNoteEvent(0, 50, 100, 5000));
        rig.frame();
        assert(rig.undos() == u1);

        ctx.editMode = false;
        ctx.injectMidiNote(MidiNoteEvent(0, 50, 100, line));
        rig.frame();
        assert(rig.undos() == u1 && ctx.takeMidiNotes().length == 0);

        assert(rig.s.doMoveClip(1, 16, 64, 0));
        assert(v.localLineForSongLine(20) == 4 && v.localLineForSongLine(10) == -1 && v.localLineForSongLine(79) == 63
            && v.localLineForSongLine(80) == -1);
        assert(rig.s.undo());

        rig.s.stop();
        rig.render(4);
        rig.frame();
        assert(!ctx.telemetry.engine.playing && v.playheadLocalLine() == -1);
        ctx.editMode = true;
        ctx.editStep = 1;
        v.setCursor(3, 5, 0);
        ctx.injectMidiNote(MidiNoteEvent(0, 50, 64, 0));
        rig.frame();
        assert(rig.cell(3, 5).note == NoteCell.encodeMidiNote(50));
        assert(rig.cell(3, 5).velocity == NoteCell.encodeVelocity(64 / 127.0f));
        assert(v.cursorLine() == 6);
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        auto ctx = rig.ctx;
        assert(rig.s.doResizePattern(1, 4, 1024));
        assert(rig.s.doMoveClip(1, 0, 1024, 0));
        rig.frame();
        assert(ctx.followPlayhead);
        assert(rig.s.seekLine(500) && rig.s.play());
        rig.render(4);
        rig.frame();
        immutable long pl = v.playheadLocalLine();
        assert(pl >= 500 && pl < 510);
        assert(v.scrollLine() <= pl && pl < v.scrollLine() + v.visibleLineCount());
        assert(v.isAnimating());
        rig.frame();
        assert(rig.hasShapeAt(rig.ui.theme.trackerPlayhead, v.cellRect(0, cast(uint) pl).y));

        assert(rig.key(3, KeyModifiers.command));
        assert(!ctx.followPlayhead);
        immutable uint kept = v.scrollLine();
        assert(rig.s.seekLine(100));
        rig.render(4);
        rig.frame();
        assert(v.scrollLine() == kept);
        assert(!v.isAnimating());
        rig.render(200);
        ctx.tick();
        assert(v.isAnimating());
        rig.frame();
        assert(!v.isAnimating());
        rig.key(3, KeyModifiers.command);
        assert(ctx.followPlayhead && v.isAnimating());
        rig.s.stop();
        rig.render(4);
        rig.frame();
        assert(!v.isAnimating());
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        auto ctx = rig.ctx;
        rig.put(0, 0, NoteCell.makeNote(60));
        immutable size_t n0 = rig.s.document().patterns.length;
        immutable size_t u0 = rig.undos();
        assert(!v.deleteButton.enabled);
        v.deleteButton.click();
        assert(rig.s.document().patterns.length == n0);

        rig.click(v.addButton.bounds.center());
        assert(rig.s.document().patterns.length == n0 + 1 && rig.undos() == u0 + 1);
        immutable uint added = rig.s.document().patterns[$ - 1].patternId;
        assert(ctx.currentPattern() == added);
        assert(rig.pattern().tracks == 4 && rig.pattern().lines == 64 && rig.cell(0, 0).isEmpty());
        rig.frame();
        assert(v.patternSelect.items.length == n0 + 1 && v.patternSelect.selectedIndex == n0);
        assert(v.deleteButton.enabled);

        assert(rig.key(33, KeyModifiers.command));
        assert(ctx.currentPattern() == 1);
        assert(rig.key(30, KeyModifiers.command));
        assert(ctx.currentPattern() == added);
        assert(v.patternSelect.select(0));
        assert(ctx.currentPattern() == 1 && v.cursorLine() == 0);

        v.setCursor(2, 9, 3);
        rig.click(v.duplicateButton.bounds.center());
        immutable uint dup = ctx.currentPattern();
        assert(dup != 1 && dup != added && rig.pattern().name.endsWith(" copy"));
        assert(rig.cell(0, 0).note == NoteCell.encodeMidiNote(60));
        assert(v.cursorTrack() == 0 && v.cursorLine() == 0);
        assert(rig.undos() == u0 + 2);

        rig.frame();
        rig.click(v.deleteButton.bounds.center());
        assert(rig.s.document().patterns.length == n0 + 1 && ctx.currentPattern() != dup);
        assert(rig.undos() == u0 + 3);
        assert(rig.s.undo());
        assert(rig.s.document().patterns.length == n0 + 2);

        ctx.selectPattern(1);
        rig.frame();
        assert(rig.ui.setFocus(v.tracksBox));
        assert(rig.key(KeyCode.up));
        assert(rig.pattern().tracks == 5 && rig.undos() == u0 + 3);
        rig.frame();
        assert(v.tracksBox.value() == 5.0f);

        immutable Point2F lc = v.linesBox.bounds.center();
        rig.mouse(PlatformEventKind.mouseDown, lc);
        rig.mouse(PlatformEventKind.mouseMove, Point2F(lc.x + 30.0f, lc.y));
        assert(rig.pattern().lines == 64 && v.linesBox.hasPending());
        rig.frame();
        rig.mouse(PlatformEventKind.mouseMove, Point2F(lc.x + 60.0f, lc.y));
        rig.mouse(PlatformEventKind.mouseUp, Point2F(lc.x + 60.0f, lc.y));
        assert(rig.pattern().lines == 74 && rig.undos() == u0 + 4);
        rig.frame();
        assert(v.linesBox.value() == 74.0f);
        assert(rig.s.undo());
        assert(rig.pattern().lines == 64);
        rig.frame();
        assert(v.linesBox.value() == 64.0f);
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        auto ctx = rig.ctx;
        ctx.editMode = true;
        ctx.editStep = 1;
        v.setCursor(0, 3, 0);
        rig.put(0, 3, NoteCell.makeEffect(0x1F, 2, 6));
        assert(rig.key(KeyCode.tab));
        assert(rig.cell(0, 3).note == NoteCmd.noteOff && rig.cell(0, 3).moduleId == 6 && rig.cell(0, 3).effect == 0x1F);
        assert(v.cursorLine() == 4);
        ctx.editMode = false;
        assert(rig.key(KeyCode.tab));
        assert(rig.cell(0, 4).isEmpty() && v.cursorLine() == 4 && rig.ui.focused is v);

        ctx.editStep = 63;
        assert(rig.key(KeyCode.up, KeyModifiers.alt));
        assert(ctx.editStep == 64);
        rig.key(KeyCode.up, KeyModifiers.alt);
        assert(ctx.editStep == 64);
        ctx.editStep = 1;
        rig.key(KeyCode.down, KeyModifiers.alt);
        rig.key(KeyCode.down, KeyModifiers.alt);
        assert(ctx.editStep == 0);
        assert(!v.handleStudioAction(StudioAction.playToggle));
        assert(v.handleStudioAction(StudioAction.prevPattern) && ctx.currentPattern() == 1);
        assert(v.handleStudioAction(StudioAction.selectAll) && v.selection() == [0u, 0u, 3u, 63u]);
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        assert(rig.s.doResizePattern(1, 64, 4096));
        rig.frame();
        immutable size_t big = rig.instances();
        immutable size_t rows = v.visibleLineCount() + 1;
        immutable size_t cols = v.visibleTrackCount() + 1;
        immutable size_t bound = rows * cols * CELL_TEXT_COLUMNS + rows * 8 + cols * 4 + 400;
        assert(big > rows * 8 && big < bound);
        foreach (ref inst; rig.r.lastDrawList().instances) {
            immutable RectF ir = RectF(inst.rect[0], inst.rect[1], inst.rect[2], inst.rect[3]);
            assert(inst.kind == InstanceKind.line || !ir.intersect(RectF(0, 0, 900, 600)).isEmpty());
            assert(ir.y < 600.0f && ir.x < 900.0f);
        }
        rig.key(KeyCode.end);
        rig.key(KeyCode.tab, KeyModifiers.shift);
        assert(v.cursorLine() == 4095 && v.cursorTrack() == 63);
        assert(v.scrollTrack() > 0 && v.scrollLine() > 0);
        rig.frame();
        assert(rig.instances() < bound);

        immutable uint small = rig.s.doAddPattern(64, 64);
        rig.ctx.selectPattern(small);
        rig.frame();
        immutable size_t smallCount = rig.instances();
        assert(smallCount < bound);
        assert(abs(cast(long) smallCount - cast(long) big) <= 8);

        v.hexLineNumbers = false;
        rig.frame();
        assert(rig.instances() > smallCount);
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        assert(rig.s.doResizePattern(1, 64, 1024));
        rig.frame();
        immutable RectF grid0 = v.cellRect(0, 0);
        immutable Point2F inside = Point2F(grid0.x + 20.0f, grid0.y + 20.0f);
        immutable float rowH = grid0.h;
        immutable float cellW = grid0.w;
        assert(rig.scroll(inside, 0.0f, -rowH * 10.0f));
        assert(v.scrollLine() == 10);
        rig.scroll(inside, 0.0f, -rowH * 0.5f);
        rig.scroll(inside, 0.0f, -rowH * 0.5f);
        assert(v.scrollLine() == 11);
        rig.scroll(inside, -cellW * 2.0f, 0.0f);
        assert(v.scrollTrack() == 2);
        rig.scroll(inside, 0.0f, cellW, KeyModifiers.shift);
        assert(v.scrollTrack() == 1 && v.scrollLine() == 11);
        rig.scroll(inside, 0.0f, -rowH * 5000.0f);
        assert(v.scrollLine() == 1024 - v.visibleLineCount());
        rig.scroll(inside, 0.0f, rowH * 5000.0f);
        rig.scroll(inside, -cellW * 500.0f, 0.0f);
        assert(v.scrollLine() == 0 && v.scrollTrack() == 64 - v.visibleTrackCount());
        rig.scroll(inside, cellW * 500.0f, -rowH * 20.0f);
        assert(v.scrollTrack() == 0 && v.scrollLine() == 20);
        assert(v.cellRect(0, 20).y == grid0.y);
        rig.click(v.cellRect(3, 22).center());
        assert(v.cursorTrack() == 3 && v.cursorLine() == 22);
        rig.frame();
        assert(rig.hasOutlineAt(rig.ui.theme.trackerCursor, v.cellRect(3, 22).y));
        assert(!rig.scroll(Point2F(5000.0f, 5000.0f), 0.0f, -100.0f));
    }

    unittest {
        auto rig = new PeRig(true);
        auto v = rig.v;
        auto ctx = rig.ctx;
        ctx.editMode = true;
        ctx.editOctave = 5;
        ctx.editStep = 1;
        ctx.selectModule(1);
        v.setCursor(0, 0, 0);
        immutable size_t u0 = rig.undos();
        assert(rig.key(6));
        rig.keyUp(6);
        assert(rig.cell(0, 0).isEmpty() && rig.undos() == u0 && v.cursorLine() == 0);
        assert(ctx.status == MASTER_OUTPUT_BLOCKED_STATUS);

        ctx.injectMidiNote(MidiNoteEvent(0, 64, 100, 0));
        rig.frame();
        assert(rig.cell(0, 0).isEmpty() && rig.cell(1, 0).isEmpty() && rig.undos() == u0 && v.cursorLine() == 0);

        ctx.selectModule(0);
        rig.put(1, 0, NoteCell.makeNote(60, 1.0f, 1));
        immutable size_t u1 = rig.undos();
        v.setCursor(1, 2, 0);
        rig.key(6);
        rig.keyUp(6);
        assert(rig.cell(1, 2).isEmpty() && rig.undos() == u1 && v.cursorLine() == 2);

        ctx.selectModule(rig.gen);
        rig.key(6);
        rig.keyUp(6);
        assert(rig.cell(1, 2).note == NoteCell.encodeMidiNote(72) && rig.cell(1, 2).moduleId == rig.gen);
        assert(rig.undos() == u1 + 1 && v.cursorLine() == 3);
    }

    unittest {
        auto rig = new PeRig(true);
        auto v = rig.v;
        auto ctx = rig.ctx;
        ctx.selectModule(rig.gen);
        ctx.editOctave = 5;
        ctx.editStep = 1;
        assert(!ctx.editMode);

        rig.click(v.fieldRect(2, 5, PatternField.velocityHi).center());
        assert(!ctx.editMode && v.cursorField() == PatternField.velocityHi);

        rig.doubleClick(v.fieldRect(2, 5, PatternField.velocityHi).center());
        assert(ctx.editMode && ctx.status == "Edit on");
        assert(v.cursorTrack() == 2 && v.cursorLine() == 5 && v.cursorField() == PatternField.note);
        assert(!v.hasSelection());

        assert(rig.key(6));
        rig.keyUp(6);
        assert(rig.cell(2, 5).note == NoteCell.encodeMidiNote(72) && rig.cell(2, 5).moduleId == rig.gen);
        assert(v.cursorLine() == 6);

        rig.doubleClick(v.cellRect(1, 9).center());
        assert(ctx.editMode && v.cursorTrack() == 1 && v.cursorLine() == 9);
        ctx.injectMidiNote(MidiNoteEvent(0, 67, 127, 0));
        rig.frame();
        assert(rig.cell(1, 9).note == NoteCell.encodeMidiNote(67) && rig.cell(1, 9).moduleId == rig.gen);
        assert(v.cursorLine() == 10);

        ctx.selectModule(1);
        rig.doubleClick(v.cellRect(3, 12).center());
        assert(ctx.editMode && v.cursorLine() == 12);
        rig.key(6);
        rig.keyUp(6);
        assert(rig.cell(3, 12).isEmpty() && ctx.status == MASTER_OUTPUT_BLOCKED_STATUS);
    }

    unittest {
        auto rig = new PeRig(true);
        auto v = rig.v;
        auto s = rig.s;
        void type(dstring t) {
            foreach (c; t) {
                PlatformEvent e;
                e.kind = PlatformEventKind.textInput;
                e.utf32Char = c;
                rig.ui.handleEvent(e);
            }
        }
        immutable uint p1 = rig.ctx.currentPattern();
        immutable uint p2 = s.doAddPattern(4, 16, "Drums");
        immutable uint p3 = s.doAddPattern(4, 16, "Bass");
        assert(p2 != 0 && p3 != 0);
        rig.frame();
        string nameOf(uint pid) {
            foreach (ref p; s.document().patterns) {
                if (p.patternId == pid) return p.name;
            }
            return null;
        }

        immutable size_t u0 = rig.undos();
        rig.doubleClick(v.patternSelect.bounds.center());
        assert(!v.patternSelect.isOpen() && rig.ui.overlays().length == 1);
        auto f = cast(TextField) rig.ui.overlays()[0];
        assert(f !is null && f.text() == nameOf(p1) && f.allSelected());
        rig.ctx.selectModule(rig.gen);
        rig.ctx.editMode = true;
        v.setCursor(0, 0, 0);
        type("Drums"d);
        assert(rig.key(6));
        rig.keyUp(6);
        assert(rig.cell(0, 0).isEmpty());
        rig.ctx.editMode = false;
        assert(rig.key(KeyCode.returnKey));
        assert(rig.ui.overlays().length == 0 && nameOf(p1) == "Drums1" && rig.undos() == u0 + 1);
        assert(rig.ctx.status == "Renamed pattern to Drums1");
        rig.frame();
        assert(v.patternSelect.selectedText() == format("%02X Drums1", p1));

        assert(v.beginRenamePattern() !is null);
        type("Drums"d);
        rig.key(KeyCode.returnKey);
        assert(nameOf(p1) == "Drums1" && rig.undos() == u0 + 1);

        rig.ctx.selectPattern(p3);
        rig.frame();
        rig.doubleClick(v.patternSelect.bounds.center());
        type("Drums"d);
        rig.key(KeyCode.returnKey);
        assert(nameOf(p3) == "Drums2" && rig.undos() == u0 + 2);

        rig.doubleClick(v.patternSelect.bounds.center());
        type("Nope"d);
        assert(rig.key(KeyCode.escape));
        assert(rig.ui.overlays().length == 0 && nameOf(p3) == "Drums2" && rig.undos() == u0 + 2);

        rig.doubleClick(v.patternSelect.bounds.center());
        rig.key(KeyCode.deleteBackward);
        rig.key(KeyCode.returnKey);
        assert(nameOf(p3) == "Drums2" && rig.undos() == u0 + 2);

        assert(s.doRenamePattern(p3, "  Lead  ") && nameOf(p3) == "Lead");
        assert(!s.doRenamePattern(p3, "   ") && !s.doRenamePattern(9999, "X"));
        assert(s.uniquePatternName("Drums", 0) == "Drums2" && s.uniquePatternName("Drums", p2) == "Drums");
        assert(s.uniquePatternName("Fresh", 0) == "Fresh");
        assert(s.undo() && nameOf(p3) == "Drums2");
        assert(s.undo() && nameOf(p3) == "Bass");
    }

    unittest {
        auto rig = new PeRig();
        auto v = rig.v;
        auto s = rig.s;
        v.setCursor(0, 30, 0);
        immutable ColorRGBA bar = rig.ui.theme.trackerRowBar;
        immutable ColorRGBA beat = rig.ui.theme.trackerRowBeat;
        bool shaded(ColorRGBA c, uint line) {
            return rig.hasShapeAt(c, v.cellRect(0, line).y);
        }

        rig.frame();
        assert(v.beatLines() == 4 && v.barLines() == 16);
        assert(shaded(bar, 16) && shaded(beat, 12) && shaded(beat, 4) && !shaded(beat, 6) && !shaded(bar, 12));

        assert(s.doSetTimeSignature(3, 4));
        rig.frame();
        assert(v.beatLines() == 4 && v.barLines() == 12);
        assert(shaded(bar, 12) && shaded(bar, 24) && shaded(beat, 16) && !shaded(bar, 16) && shaded(beat, 4));

        assert(s.doSetTimeSignature(6, 8));
        rig.frame();
        assert(v.beatLines() == 2 && v.barLines() == 12);
        assert(shaded(beat, 2) && shaded(beat, 6) && shaded(bar, 12) && !shaded(beat, 3) && !shaded(bar, 16));

        assert(s.undo() && s.undo());
        rig.frame();
        assert(v.barLines() == 16 && shaded(bar, 16) && !shaded(bar, 12));
    }
}
