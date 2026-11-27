/**
 * File:         tests/unit/views_script_test.d
 * Module:       tests.unit.views_script_test
 * Phase:        Pattern editor views — T112 (Script tab view tests), T113 (applying a script)
 *
 * Purpose:
 *   Headless UI tests for gui.views.script_view and PatternEditorView's fourth tab ("Script"):
 *   verifies the Script tab appears and is offered for both normal and drum patterns, retains its text
 *   across tab and pattern switches, reports check-only errors with line/column/suggestion and marks the
 *   offending line while keeping text intact and leaving the project untouched, reports valid command counts,
 *   moves keyboard focus to editor on tab switch, triggers Apply on Cmd+Return, exposes project module
 *   handles, and draws cleanly with HeadlessRenderer. T113: Apply changes the open project as one undo step
 *   (a module, a part and notes; undo and redo restore the exact serialized document) and clears the input;
 *   an error in the last line changes nothing and keeps the input; `project`, `open` and `save` are refused;
 *   applying while the song plays keeps the transport running; relative paths are refused before the project
 *   is saved and read from the project's folder after; a preset written by `savemodule` reaches the disk only
 *   when the whole script succeeds.
 *
 * Real-Time & Safety Contract:
 *   Headless UI test over HeadlessRenderer and in-memory StudioSession.
 *
 * Dependencies:
 *   Internal: app.session (StudioSession), gui.renderer (FontId, GlyphCache, HeadlessRenderer,
 *             IGlyphRasterizer, Point2F, RasterizedGlyph, RectF), gui.views.pattern_editor
 *             (PatternEditorView, PatternViewKind), gui.views.script_view (ScriptApplyResult,
 *             ScriptView), gui.views.studio_context (StudioContext), gui.widgets (KeyCode, TextArea,
 *             UiContext), platform.interfaces (KeyModifiers, PlatformEvent, PlatformEventKind)
 *   External: std.algorithm (canFind), std.file, std.path, std.process (thisProcessID)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) tests covering all T112 requirements
 *
 * See_Also:
 *   docs/todo.md (T83, T108, T110, T112), source/gui/views/script_view.d,
 *   source/gui/views/pattern_editor.d
 */
module tests.unit.views_script_test;

version (unittest) {
    import std.algorithm : canFind;
    import std.conv : to;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    import io.project_format : LoadedProject, serializeProject;

    import app.session : StudioSession;
    import gui.renderer : FontId, GlyphCache, HeadlessRenderer, IGlyphRasterizer, Point2F,
        RasterizedGlyph, RectF;
    import gui.views.pattern_editor : PatternEditorView, PatternViewKind;
    import gui.views.script_view : ScriptApplyResult, ScriptView;
    import gui.views.studio_context : StudioContext;
    import gui.widgets : KeyCode, TextArea, UiContext;
    import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;

    private final class ScriptTestRasterizer : IGlyphRasterizer {
        override bool rasterize(FontId font, float px, dchar cp, out RasterizedGlyph g) {
            cast(void) font;
            cast(void) px;
            cast(void) cp;
            g.width = 2;
            g.height = 2;
            g.bearingY = 2.0f;
            g.advance = px * 0.55f;
            g.coverage = new ubyte[4];
            return true;
        }

        override void lineMetrics(FontId font, float px, out float ascent, out float lineHeight) {
            cast(void) font;
            ascent = px * 0.8f;
            lineHeight = px * 1.25f;
        }
    }

    unittest {
        StudioSession sess = new StudioSession();
        assert(sess.initialize(44_100.0f));
        scope (exit) sess.shutdown();

        StudioContext ctx = new StudioContext(sess);
        PatternEditorView editor = new PatternEditorView(ctx);
        HeadlessRenderer r = new HeadlessRenderer(new GlyphCache(new ScriptTestRasterizer()));
        double clock = 0.0;
        UiContext ui = new UiContext(editor, () => clock);
        ui.layout(RectF(0, 0, 900.0f, 600.0f), r);
        ctx.tick();
        ui.renderFrame(r, 1.0f);

        assert(editor.viewButtons[PatternViewKind.script].id == "pattern.view.script");
        assert(editor.viewButtons[PatternViewKind.script].text == "Script");
        assert(editor.viewOffered(PatternViewKind.script));
        assert(editor.viewAvailable(PatternViewKind.script));
        assert(editor.scriptView() !is null);

        immutable uint drumPat = sess.doAddDrumPattern("Kit");
        assert(drumPat != 0);
        ctx.selectPattern(drumPat);
        ctx.tick();
        ui.renderFrame(r, 1.0f);
        assert(editor.viewOffered(PatternViewKind.script));
        assert(editor.viewButtons[PatternViewKind.script].enabled);

        assert(editor.setView(PatternViewKind.script));
        ctx.tick();
        ui.renderFrame(r, 1.0f);
        ScriptView sv = editor.scriptView();
        assert(sv.visible && sv.bounds == editor.viewRect());
        assert(editor.viewButtons[PatternViewKind.script].lit);
        assert(ui.focused is sv.editor);

        sv.editor.setText("tempo 120\ntemop 120");
        assert(editor.setView(PatternViewKind.tracker));
        ctx.tick();
        ui.renderFrame(r, 1.0f);
        assert(!sv.visible);
        ctx.selectPattern(1);
        ctx.tick();
        ui.renderFrame(r, 1.0f);
        assert(editor.setView(PatternViewKind.script));
        ctx.tick();
        ui.renderFrame(r, 1.0f);
        assert(sv.editor.text() == "tempo 120\ntemop 120");

        immutable ulong revBefore = sess.documentRevision();
        ScriptApplyResult bad = sv.apply();
        assert(!bad.ok);
        assert(!sv.lastOk());
        assert(sv.lastProblems().length == 1);
        assert(sv.lastProblems()[0].line == 2 && sv.lastProblems()[0].column == 1);
        assert(sv.message().canFind("line 2, col 1") && sv.message().canFind("tempo"));
        assert(sv.editor.markedLine() == 1);
        assert(sv.editor.text() == "tempo 120\ntemop 120");
        assert(sess.documentRevision() == revBefore);

        sv.editor.setText("title \"Valid Check\"\ntempo 115\nsignature 6/8");
        PlatformEvent enterEv;
        enterEv.kind = PlatformEventKind.keyDown;
        enterEv.keyCode = KeyCode.returnKey;
        enterEv.modifiers = KeyModifiers.command;
        assert(ui.handleEvent(enterEv));
        assert(sv.lastOk(), sv.message());
        assert(sv.editor.markedLine() == TextArea.NO_MARK);
        assert(sv.message().canFind("Applied 3 commands"), sv.message());
        assert(sess.documentRevision() != revBefore);
        assert(sv.editor.text() == "");
        assert(sess.document().title == "Valid Check" && sess.document().timeSigDenominator == 8);
        assert(sess.undo() && sess.document().title != "Valid Check");

        string[] handles = sv.projectHandles();
        assert(handles.canFind("out"));
        ui.renderFrame(r, 1.0f);
    }

    /**
     * The open document as .msv bytes, to compare documents exactly.
     *
     * Params:
     *   sess = The session.
     *
     * Returns:
     *   The serialized snapshot.
     */
    private ubyte[] documentBytes(StudioSession sess) {
        LoadedProject snap;
        string err;
        assert(sess.snapshotDocumentForSave(snap, err), err);
        ubyte[] bytes;
        assert(serializeProject(snap, bytes, err), err);
        return bytes;
    }

    /**
     * Runs the engine for a number of host buffers, as an audio device would.
     *
     * Params:
     *   sess = The session.
     *   blocks = Buffers of 256 frames to render.
     */
    private void pump(StudioSession sess, size_t blocks) {
        float[256] l = 0.0f;
        float[256] r = 0.0f;
        const(float[])[2] ins = [null, null];
        foreach (_; 0 .. blocks) {
            float[][2] outs = [l[], r[]];
            sess.engine().processHostBuffer(outs, ins, 256);
        }
    }

    /**
     * A script view hosted in a laid-out pattern editor over a fresh session.
     */
    private final class ScriptRig {
        StudioSession sess;
        StudioContext ctx;
        PatternEditorView editor;
        HeadlessRenderer r;
        UiContext ui;
        ScriptView sv;
        double clock = 0.0;

        this() {
            sess = new StudioSession();
            assert(sess.initialize(44_100.0f));
            ctx = new StudioContext(sess);
            editor = new PatternEditorView(ctx);
            r = new HeadlessRenderer(new GlyphCache(new ScriptTestRasterizer()));
            ui = new UiContext(editor, () => clock);
            ui.layout(RectF(0, 0, 900.0f, 600.0f), r);
            ctx.tick();
            assert(editor.setView(PatternViewKind.script));
            ctx.tick();
            ui.renderFrame(r, 1.0f);
            sv = editor.scriptView();
        }

        void frame() {
            ctx.tick();
            ui.renderFrame(r, 1.0f);
        }
    }

    unittest {
        ScriptRig rig = new ScriptRig();
        scope (exit) rig.sess.shutdown();
        StudioSession sess = rig.sess;
        ScriptView sv = rig.sv;

        immutable ubyte[] before = documentBytes(sess).idup;
        immutable size_t modulesBefore = sess.document().modules.length;
        immutable size_t patternsBefore = sess.document().patterns.length;
        immutable size_t undoBefore = sess.history().undoCount();
        sv.editor.setText("module bass preset=\"Electric Bass\"\nconnect bass out gain=0.4\n"
            ~ "section verse bars=2\npart bass module=bass\nnotes bass verse: C3:1 E3:1 G3:2 C3:4\narrange verse");
        ScriptApplyResult applied = sv.apply();
        assert(applied.ok, sv.message());
        assert(applied.commandsRun == 6);
        assert(sv.editor.text() == "" && sv.editor.markedLine() == TextArea.NO_MARK);
        assert(sv.message() == "Applied 6 commands. Cmd+Z takes the script back.", sv.message());
        assert(sess.document().modules.length == modulesBefore + 1);
        assert(sess.document().patterns.length > patternsBefore);
        bool namedBass = false;
        foreach (ref m; sess.document().modules) {
            namedBass = namedBass || m.name == "bass";
        }
        assert(namedBass);
        assert(sess.history().undoCount() == undoBefore + 1);
        assert(sess.history().nextUndoLabel() == "Apply script", sess.history().nextUndoLabel());
        immutable ubyte[] after = documentBytes(sess).idup;
        assert(after != before);
        rig.frame();
        assert(sv.projectHandles().canFind("bass"));

        assert(sess.undo());
        assert(documentBytes(sess) == before);
        rig.frame();
        assert(!sv.projectHandles().canFind("bass"));
        assert(sess.redo());
        assert(documentBytes(sess) == after);
    }

    unittest {
        ScriptRig rig = new ScriptRig();
        scope (exit) rig.sess.shutdown();
        StudioSession sess = rig.sess;
        ScriptView sv = rig.sv;

        immutable ubyte[] before = documentBytes(sess).idup;
        immutable ulong revision = sess.documentRevision();
        immutable size_t undoBefore = sess.history().undoCount();
        immutable string failing = "tempo 140\nmodule pad synth.analog_gen\nset pad Cutof=900";
        sv.editor.setText(failing);
        ScriptApplyResult bad = sv.apply();
        assert(!bad.ok && bad.problems.length == 1);
        assert(bad.problems[0].line == 3, sv.message());
        assert(sv.message().canFind("line 3") && sv.message().canFind("Cutoff"), sv.message());
        assert(sv.editor.text() == failing && sv.editor.markedLine() == 2);
        assert(sess.documentRevision() == revision && sess.history().undoCount() == undoBefore);
        assert(documentBytes(sess) == before);

        foreach (row; [["project \"Other\"", "'project' would replace the open project"],
                ["open \"x.msv\"", "'open' is not available in the Script tab"],
                ["save \"x.msv\"", "'save' is not available in the Script tab"],
                ["save", "'save' is not available in the Script tab"]]) {
            sv.editor.setText("tempo 99\n" ~ row[0]);
            ScriptApplyResult refused = sv.apply();
            assert(!refused.ok && refused.problems.length == 1, row[0]);
            assert(refused.problems[0].line == 2 && refused.problems[0].column == 1, row[0]);
            assert(refused.problems[0].reason.canFind(row[1]), refused.problems[0].reason);
            assert(sv.editor.text() == "tempo 99\n" ~ row[0] && sv.editor.markedLine() == 1);
        }
        assert(documentBytes(sess) == before && sess.history().undoCount() == undoBefore);

        sv.editor.setText("  \n");
        ScriptApplyResult empty = sv.apply();
        assert(empty.ok && empty.commandsRun == 0 && sv.message() == "Nothing to apply.");
        assert(sess.history().undoCount() == undoBefore);
    }

    unittest {
        ScriptRig rig = new ScriptRig();
        scope (exit) rig.sess.shutdown();
        StudioSession sess = rig.sess;
        ScriptView sv = rig.sv;

        assert(sess.play());
        pump(sess, 40);
        assert(sess.isPlaying());
        sv.editor.setText("module pad synth.analog_gen\nconnect pad out gain=0.2");
        ScriptApplyResult applied = sv.apply();
        assert(applied.ok, sv.message());
        pump(sess, 2);
        assert(sess.isPlaying());
        rig.frame();
        pump(sess, 2);
        assert(sess.isPlaying());
    }

    unittest {
        ScriptRig rig = new ScriptRig();
        scope (exit) rig.sess.shutdown();
        StudioSession sess = rig.sess;
        ScriptView sv = rig.sv;

        sv.editor.setText("module lead synth.analog_gen\nsavemodule lead \"lead.msym\"");
        ScriptApplyResult unsaved = sv.apply();
        assert(!unsaved.ok && unsaved.problems.length == 1 && unsaved.problems[0].line == 2);
        assert(unsaved.problems[0].reason.canFind("save the project first"), unsaved.problems[0].reason);

        immutable string root = buildPath(tempDir(), "dracker-script-tab-" ~ to!string(thisProcessID()));
        if (exists(root)) {
            rmdirRecurse(root);
        }
        mkdirRecurse(root);
        scope (exit) rmdirRecurse(root);
        string err;
        assert(sess.saveProjectToFile(buildPath(root, "song.msv"), err), err);

        immutable string preset = buildPath(root, "lead.msym");
        sv.editor.setText("module lead synth.analog_gen\nsavemodule lead \"lead.msym\"\nset lead Cutof=1");
        ScriptApplyResult failing = sv.apply();
        assert(!failing.ok && failing.problems[0].line == 3);
        assert(!exists(preset));

        sv.editor.setText("module lead synth.analog_gen\nset lead Cutoff=900\nsavemodule lead \"lead.msym\"\n"
            ~ "module copy file=\"lead.msym\"");
        ScriptApplyResult applied = sv.apply();
        assert(applied.ok, sv.message());
        assert(exists(preset));
        bool copied = false;
        foreach (ref m; sess.document().modules) {
            copied = copied || m.name == "copy";
        }
        assert(copied);
    }
}

