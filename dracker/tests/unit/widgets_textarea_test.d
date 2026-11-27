/**
 * File:         tests/unit/widgets_textarea_test.d
 * Module:       tests.unit.widgets_textarea_test
 * Phase:        Script tab — T110 (Multi-line TextArea widget unit tests)
 *
 * Purpose:
 *   Headless verification of gui.widgets.TextArea and its helpers: textPosBefore, isWordChar,
 *   decimalDigits, line splitting/normalization, clamping, theme-driven metrics and scaling,
 *   vertical scrolling, caret/word/page/end movement, typing, Return, Tab, Backspace, Delete,
 *   Unicode code-point editing, IME filter, keyboard and mouse selection (click, double-click,
 *   drag), clipboard delegates (cut/copy/paste and null delegates), unconsumed shortcut pass-through,
 *   marked-line outline, selection fill and focus-dependent caret drawing.
 *
 * Real-Time & Safety Contract:
 *   UI-thread widget code exercised single-threaded through gui_test.Harness and HeadlessRenderer.
 *
 * Dependencies:
 *   Internal: gui.{layout,renderer,theme,widgets}, platform.interfaces, tests.unit.gui_test
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T110), source/gui/widgets.d
 */
module tests.unit.widgets_textarea_test;

version (unittest) {
    import gui.layout;
    import gui.renderer;
    import gui.theme;
    import gui.widgets;
    import platform.interfaces : KeyModifiers;
    import tests.unit.gui_test : countKind, Harness, near, nearRect;

    private struct Rig {
        Panel root;
        Harness h;
        TextArea ta;
        string clip;
        int changes = 0;
        int submits = 0;
    }

    private Rig makeRig(string initial = "") {
        Rig r;
        r.root = new Panel();
        r.h = new Harness(r.root, RectF(0, 0, 400, 300));
        r.ta = r.root.add(new TextArea(initial));
        r.ta.bounds = RectF(10, 10, 300, 83);
        r.h.ctx.setFocus(r.ta);
        return r;
    }

    private string repeatLines(size_t count, string text) {
        string s;
        foreach (i; 0 .. count) {
            if (i > 0) {
                s ~= '\n';
            }
            s ~= text;
        }
        return s;
    }

    unittest {
        assert(textPosBefore(TextPos(0, 1), TextPos(0, 2)));
        assert(textPosBefore(TextPos(0, 9), TextPos(1, 0)));
        assert(!textPosBefore(TextPos(1, 2), TextPos(1, 2)));
        assert(!textPosBefore(TextPos(2, 0), TextPos(1, 5)));

        assert(isWordChar('_') && isWordChar('a') && isWordChar('Z') && isWordChar('5'));
        assert(isWordChar('é') && isWordChar('가'));
        assert(!isWordChar(' ') && !isWordChar('-') && !isWordChar(':'));

        assert(decimalDigits(0) == 1 && decimalDigits(9) == 1);
        assert(decimalDigits(10) == 2 && decimalDigits(99) == 2);
        assert(decimalDigits(100) == 3 && decimalDigits(9999) == 4);

        auto ta = new TextArea("a\r\nb\tc\rd");
        assert(ta.text() == "a\nb    c\nd");
        assert(ta.lineCount() == 3);
        assert(ta.caretLine() == 0 && ta.caretColumn() == 0 && !ta.hasSelection());

        ta.setCaret(99, 99);
        assert(ta.caretLine() == 2 && ta.caretColumn() == 1);

        int changed = 0;
        ta.onChange = () { changed++; };
        ta.setText("hello");
        assert(ta.text() == "hello" && ta.lineCount() == 1 && changed == 0);
        ta.clear();
        assert(ta.text() == "" && ta.lineCount() == 1 && changed == 0);
    }

    unittest {
        Rig r = makeRig("");
        assert(near(r.ta.gutterWidth(), 20.0f));
        assert(r.ta.visibleLineCount() == 5);
        assert(nearRect(r.ta.lineRect(0), RectF(10, 14, 300, 15)));

        immutable Point2F measured = r.ta.measure(r.h.renderer, r.h.ctx.theme);
        assert(near(measured.x, 268.0f) && near(measured.y, 128.0f));

        r.ta.setText(repeatLines(20, "L"));
        r.h.key(KeyCode.pageDown);
        assert(r.ta.caretLine() == 5 && r.ta.caretColumn() == 0 && near(r.ta.scrollOffset(), 15.0f));
        r.h.key(KeyCode.pageDown);
        assert(r.ta.caretLine() == 10 && r.ta.caretColumn() == 0 && near(r.ta.scrollOffset(), 90.0f));
        assert(r.h.scroll(50, 50, 0, -10_000.0f));
        assert(near(r.ta.scrollOffset(), 225.0f));
        assert(!r.ta.scrollTo(225.0f));

        r.ta.setText(repeatLines(100, "L"));
        assert(near(r.ta.gutterWidth(), 26.0f));

        r.ta.setText("one\ntwo");
        StudioTheme t = r.h.ctx.theme;
        StudioTheme scaled = t.scaled(2.0f);
        r.h.ctx.setTheme(scaled);
        assert(near(r.ta.lineRect(0).h, 30.0f));
        assert(near(r.ta.gutterWidth(), 40.0f));
        assert(r.ta.visibleLineCount() == 2);
    }

    unittest {
        Rig r = makeRig("foo bar_baz  qux");
        r.h.key(KeyCode.right, KeyModifiers.alt);
        assert(r.ta.caretColumn() == 3);
        r.h.key(KeyCode.right, KeyModifiers.alt);
        assert(r.ta.caretColumn() == 11);
        r.h.key(KeyCode.right, KeyModifiers.alt);
        assert(r.ta.caretColumn() == 16);
        r.h.key(KeyCode.left, KeyModifiers.alt);
        assert(r.ta.caretColumn() == 13);
        r.h.key(KeyCode.left, KeyModifiers.alt);
        assert(r.ta.caretColumn() == 4);

        r.ta.setText("abcdef\nab\nabcd");
        r.ta.setCaret(0, 5);
        r.h.key(KeyCode.down);
        assert(r.ta.caretLine() == 1 && r.ta.caretColumn() == 2);
        r.h.key(KeyCode.up);
        assert(r.ta.caretLine() == 0 && r.ta.caretColumn() == 5);
        r.h.key(KeyCode.down);
        assert(r.ta.caretLine() == 1 && r.ta.caretColumn() == 2);
        r.h.key(KeyCode.down);
        assert(r.ta.caretLine() == 2 && r.ta.caretColumn() == 4);
        r.h.key(KeyCode.down);
        assert(r.ta.caretLine() == 2 && r.ta.caretColumn() == 4);
        r.h.key(KeyCode.up);
        assert(r.ta.caretLine() == 1 && r.ta.caretColumn() == 2);
        r.h.key(KeyCode.up);
        assert(r.ta.caretLine() == 0 && r.ta.caretColumn() == 4);
        r.h.key(KeyCode.up);
        assert(r.ta.caretLine() == 0 && r.ta.caretColumn() == 0);

        r.h.key(KeyCode.end);
        r.h.key(KeyCode.home, KeyModifiers.shift);
        r.h.key(KeyCode.tab);
        assert(r.ta.text() == "    \nab\nabcd" && r.ta.caretLine() == 0 && r.ta.caretColumn() == 4);

        r.h.key(KeyCode.down, KeyModifiers.command);
        assert(r.ta.caretLine() == 2 && r.ta.caretColumn() == 4);
        r.h.key(KeyCode.up, KeyModifiers.command);
        assert(r.ta.caretLine() == 0 && r.ta.caretColumn() == 0);
        r.h.key(KeyCode.right, KeyModifiers.command);
        assert(r.ta.caretLine() == 0 && r.ta.caretColumn() == 4);
        r.h.key(KeyCode.left, KeyModifiers.command);
        assert(r.ta.caretLine() == 0 && r.ta.caretColumn() == 0);
    }

    unittest {
        Rig r = makeRig("");
        int changes = 0;
        r.ta.onChange = () { changes++; };

        r.h.key(KeyCode.deleteBackward);
        assert(r.ta.text() == "" && changes == 0);

        r.h.type("ab"d);
        r.h.key(KeyCode.returnKey);
        r.h.type("cd"d);
        assert(r.ta.text() == "ab\ncd" && r.ta.caretLine() == 1 && r.ta.caretColumn() == 2);
        assert(changes == 5);

        r.h.key(KeyCode.home);
        r.h.key(KeyCode.deleteBackward);
        assert(r.ta.text() == "abcd" && r.ta.caretLine() == 0 && r.ta.caretColumn() == 2);

        r.ta.setText("ab\ncd");
        r.ta.setCaret(0, 2);
        r.h.key(KeyCode.forwardDelete);
        assert(r.ta.text() == "abcd" && r.ta.caretLine() == 0 && r.ta.caretColumn() == 2);

        r.ta.setText("é가x");
        r.ta.setCaret(0, 3);
        r.h.key(KeyCode.left);
        r.h.key(KeyCode.deleteBackward);
        assert(r.ta.text() == "éx" && r.ta.caretLine() == 0 && r.ta.caretColumn() == 1);
        r.h.type("가"d);
        assert(r.ta.text() == "é가x" && r.ta.caretLine() == 0 && r.ta.caretColumn() == 2);
        assert(r.ta.text().length == 6);

        immutable int beforeFilter = changes;
        r.h.type("\r\t"d);
        assert(r.ta.text() == "é가x" && changes == beforeFilter);
    }

    unittest {
        Rig r = makeRig("one\ntwo\nthree");
        string clip;
        int submits = 0;
        r.ta.clipboardRead = () => clip;
        r.ta.clipboardWrite = (string s) { clip = s; return true; };
        r.ta.onSubmit = () { submits++; };

        r.ta.setCaret(0, 1);
        r.h.key(KeyCode.down, KeyModifiers.shift);
        r.h.key(KeyCode.right, KeyModifiers.shift);
        assert(r.ta.selectedText() == "ne\ntw");
        r.h.type("X"d);
        assert(r.ta.text() == "oXo\nthree" && r.ta.caretLine() == 0 && r.ta.caretColumn() == 2);

        r.ta.setText("ab");
        r.ta.setCaret(0, 1);
        clip = "1\r\n2\t3\n";
        r.h.key(KeyCode.v, KeyModifiers.command);
        assert(r.ta.text() == "a1\n2    3\nb" && r.ta.caretLine() == 2 && r.ta.caretColumn() == 0);

        r.ta.setText("hello world");
        r.h.key(KeyCode.right, KeyModifiers.shift);
        r.h.key(KeyCode.right, KeyModifiers.shift);
        r.h.key(KeyCode.c, KeyModifiers.command);
        assert(clip == "he");
        r.h.key(KeyCode.x, KeyModifiers.command);
        assert(clip == "he" && r.ta.text() == "llo world" && r.ta.caretLine() == 0 && r.ta.caretColumn() == 0);

        r.h.key(KeyCode.a, KeyModifiers.command);
        assert(r.ta.hasSelection() && r.ta.selectedText() == "llo world");

        r.ta.clipboardRead = null;
        r.ta.clipboardWrite = null;
        r.h.key(KeyCode.c, KeyModifiers.command);
        r.h.key(KeyCode.x, KeyModifiers.command);
        r.h.key(KeyCode.v, KeyModifiers.command);
        assert(r.ta.text() == "llo world");

        r.h.key(KeyCode.returnKey, KeyModifiers.command);
        assert(submits == 1);

        KeyEvent esc;
        esc.keyCode = KeyCode.escape;
        assert(!r.ta.onKeyDown(esc));

        KeyEvent shiftTab;
        shiftTab.keyCode = KeyCode.tab;
        shiftTab.modifiers = KeyModifiers.shift;
        assert(!r.ta.onKeyDown(shiftTab));

        KeyEvent cmdS;
        cmdS.keyCode = KeyCode.s;
        cmdS.modifiers = KeyModifiers.command;
        assert(!r.ta.onKeyDown(cmdS));
    }

    unittest {
        Rig r = makeRig("hello world\nsecond");
        r.h.click(53.0f, 31.0f);
        assert(r.ta.caretLine() == 1 && r.ta.caretColumn() == 3 && !r.ta.hasSelection());

        r.h.doubleClick(77.0f, 16.0f);
        assert(r.ta.selectedText() == "world" && r.ta.caretLine() == 0 && r.ta.caretColumn() == 11);

        r.h.drag(40.0f, 16.0f, 46.0f, 31.0f);
        assert(r.ta.selectedText() == "ello world\nse");
    }

    unittest {
        Rig r = makeRig("alpha\nbeta");
        r.ta.markLine(5);
        assert(r.ta.markedLine() == TextArea.NO_MARK);
        r.ta.markLine(1);
        assert(r.ta.markedLine() == 1);

        r.h.ctx.setFocus(r.ta);
        r.h.ctx.renderFrame(r.h.renderer, 1.0f);
        auto dl = r.h.renderer.lastDrawList();
        immutable StudioTheme t = r.h.ctx.theme;
        immutable float[4] dangerColor = [t.danger.r, t.danger.g, t.danger.b, t.danger.a];
        immutable float[4] caretColor = [t.accentHot.r, t.accentHot.g, t.accentHot.b, t.accentHot.a];

        bool foundMark = false;
        bool foundCaret = false;
        foreach (ref inst; dl.instances) {
            if (inst.kind == InstanceKind.shape
                    && near(inst.rect[0], 11.0f) && near(inst.rect[1], 30.0f)
                    && near(inst.rect[2], 298.0f) && near(inst.rect[3], 13.0f)
                    && near(inst.borderWidth, 2.0f) && inst.colorBorder == dangerColor) {
                foundMark = true;
            }
            if (inst.kind == InstanceKind.shape
                    && near(inst.rect[2], 1.5f) && near(inst.rect[3], 15.0f)
                    && inst.colorA == caretColor) {
                foundCaret = true;
            }
        }
        assert(foundMark && foundCaret);
        assert(countKind(dl, InstanceKind.glyph) > 0);

        r.ta.selectAll();
        r.h.ctx.renderFrame(r.h.renderer, 1.0f);
        auto dlSel = r.h.renderer.lastDrawList();
        immutable float[4] selColor = [t.selection.r, t.selection.g, t.selection.b, t.selection.a];
        bool foundSel = false;
        foreach (ref inst; dlSel.instances) {
            if (inst.kind == InstanceKind.shape && inst.colorA == selColor) {
                foundSel = true;
            }
        }
        assert(foundSel);

        r.h.ctx.setFocus(null);
        r.h.ctx.renderFrame(r.h.renderer, 1.0f);
        auto dlUnfocused = r.h.renderer.lastDrawList();
        bool caretUnfocused = false;
        foreach (ref inst; dlUnfocused.instances) {
            if (inst.kind == InstanceKind.shape
                    && near(inst.rect[2], 1.5f) && near(inst.rect[3], 15.0f)
                    && inst.colorA == caretColor) {
                caretUnfocused = true;
            }
        }
        assert(!caretUnfocused);

        r.h.ctx.setFocus(r.ta);
        r.h.type("x"d);
        assert(r.ta.markedLine() == TextArea.NO_MARK);
    }
}
