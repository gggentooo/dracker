/**
 * File:         tests/unit/views_skeleton_panel_test.d
 * Module:       tests.unit.views_skeleton_panel_test
 * Phase:        Skeleton project generator — T20, T21, T22
 *
 * Purpose:
 *   Headless tests of the "New Project from Skeleton" panel hosted by a real StudioRoot:
 *     - T20: opening and centring, modality (outside clicks, keys, shortcuts and piano keys never reach the
 *       studio), editing title, tempo, time signature and key, Escape / Cancel / Create, the disabled-Create
 *       reason, remembered values, Tab focus order, and the scrolling body in a small window.
 *     - T21: chord entry (Return and Add, parse errors), preset insertion after the selection, the block strip
 *       (click, arrow keys, ⌥-arrow moves, Delete), Move / Remove / length / Clear buttons, total length, labels
 *       following key and mode changes, horizontal scrolling of a long strip.
 *     - T22: instrument dropdowns (enabled only with chords), module choice, loading .msym presets through a fake
 *       file dialog (success, cancel, unreadable file, preset that cannot play notes, no dialogs).
 *     - T23: ⇧⌘N / StudioAction.newSkeletonProject opens the panel once; the keymap and document-level checks.
 *     - T24: Create opens the generated project (no question when clean; the unsaved-changes question when
 *       modified, with Cancel keeping project and panel), selects the Piano pattern, sets the status; no
 *       progression gives the empty project; create errors in the footer.
 *     - T25: end to end from ⇧⌘N through typed title and BPM, 3/4, G major, the circle-of-fifths preset and an
 *       FM bass to Create; the document is checked, saved, reopened in a new session, compared and rendered.
 *
 * Real-Time & Safety Contract:
 *   UI-thread code driven single-threaded; temporary preset files are removed with scope(exit).
 *
 * Dependencies:
 *   Internal: app.{chord_progression,keymap,music_theory,session,skeleton_gen}, foundation.memory,
 *             gui.{layout,renderer,widgets}, sequencer.note,
 *             gui.views.{skeleton_panel,studio_context,studio_root}, io.project_format, platform.interfaces
 *   External: std.file, std.path, std.process
 *
 * Planned API (Types, Functions & Hooks):
 *   - class PanelRasterizer : IGlyphRasterizer; class PanelDialog : IFileDialog; struct PanelRig
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T20, T21, T22), source/gui/views/skeleton_panel.d
 */
module tests.unit.views_skeleton_panel_test;

version (unittest) {
    import std.algorithm : startsWith, canFind;
    import std.conv : to;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;

    import app.chord_progression : ChordForm;
    import app.keymap : isDocumentLevel, Keymap, StudioAction;
    import foundation.memory : OwnedBuffer;
    import std.math : fabs;
    import app.music_theory : KeyMode, MusicalKey;
    import app.session : StudioSession;
    import app.skeleton_gen : defaultBassModule, generateSkeleton, InstrumentRole, InstrumentSource,
        moduleWithDefaults, SkeletonSpec;
    import gui.layout : Axis;
    import gui.renderer;
    import gui.views.skeleton_panel : ChordBlockStrip, SkeletonPanel;
    import gui.views.studio_context : StudioContext;
    import gui.views.studio_root : StudioRoot;
    import gui.widgets : UiContext;
    import io.project_format : LoadedPreset, LoadedProject, loadProject, savePreset;
    import sequencer.note : NoteCell;
    import platform.interfaces : FileDialogFilter, IFileDialog, KeyModifiers, PlatformEvent, PlatformEventKind;

    private final class PanelRasterizer : IGlyphRasterizer {
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

    private final class PanelDialog : IFileDialog {
        string openPath;
        string lastTitle;
        string[] lastExtensions;
        uint opens = 0;

        override bool openFile(string title, const(FileDialogFilter)[] filters, out string selectedPath) {
            opens++;
            lastTitle = title;
            lastExtensions = filters.length > 0 ? filters[0].extensions.dup : null;
            selectedPath = openPath;
            return openPath.length > 0;
        }

        override bool saveFile(string title, string defaultName, const(FileDialogFilter)[] filters,
                out string selectedPath) {
            return false;
        }
    }

    private struct PanelRig {
        StudioSession session;
        StudioContext ctx;
        StudioRoot root;
        UiContext ui;
        HeadlessRenderer renderer;
        PanelDialog dialog;
        float w;
        float h;
        StudioAction[] appActions;

        void frame() {
            renderer.beginFrame(w, h, 1.0f);
            ctx.tick();
            ui.layout(RectF(0, 0, w, h), renderer);
            ui.draw(renderer);
            renderer.endFrame();
        }

        void send(PlatformEventKind kind, Point2F p, uint mods = 0) {
            PlatformEvent ev;
            ev.kind = kind;
            ev.x = p.x;
            ev.y = p.y;
            ev.modifiers = mods;
            ui.handleEvent(ev);
        }

        void click(Point2F p, uint mods = 0) {
            send(PlatformEventKind.mouseDown, p, mods);
            send(PlatformEventKind.mouseUp, p, mods);
            frame();
        }

        void key(uint code, uint mods = 0) {
            PlatformEvent ev;
            ev.kind = PlatformEventKind.keyDown;
            ev.keyCode = code;
            ev.modifiers = mods;
            ui.handleEvent(ev);
            ev.kind = PlatformEventKind.keyUp;
            ui.handleEvent(ev);
            frame();
        }

        void type(string text) {
            foreach (dchar c; text) {
                PlatformEvent ev;
                ev.kind = PlatformEventKind.textInput;
                ev.utf32Char = c;
                ui.handleEvent(ev);
            }
            frame();
        }

        void scroll(Point2F p, float dy) {
            PlatformEvent ev;
            ev.kind = PlatformEventKind.mouseScroll;
            ev.x = p.x;
            ev.y = p.y;
            ev.deltaY = dy;
            ui.handleEvent(ev);
            frame();
        }
    }

    private PanelRig makeRig(float w = 1440.0f, float h = 900.0f) {
        PanelRig r;
        r.w = w;
        r.h = h;
        r.session = new StudioSession();
        assert(r.session.initialize(44_100.0f));
        r.dialog = new PanelDialog();
        r.ctx = new StudioContext(r.session, null, r.dialog);
        r.root = new StudioRoot(r.ctx);
        r.ui = new UiContext(r.root);
        r.renderer = new HeadlessRenderer(new GlyphCache(new PanelRasterizer()));
        r.frame();
        return r;
    }

    private void removeQuietly(string f) nothrow {
        try {
            remove(f);
        } catch (Exception) {
        }
    }

    private Point2F centerOf(RectF b) {
        return Point2F(b.x + b.w * 0.5f, b.y + b.h * 0.5f);
    }

    unittest {
        PanelRig r = makeRig();
        scope (exit) r.session.dispose();
        StudioAction[] acts;
        r.root.appCommandHandler = (StudioAction a) { acts ~= a; return true; };
        SkeletonPanel p = r.root.openSkeletonPanel();
        r.frame();
        assert(p !is null && r.root.skeletonPanel() is p && r.root.openSkeletonPanel() is p);
        assert(r.ui.overlays().length == 1 && r.ui.overlays()[0] is p && p.isModalOverlay() && !p.closesOnOutsideClick());
        assert(p.bounds == RectF((1440.0f - 720.0f) * 0.5f, (900.0f - 640.0f) * 0.5f, 720.0f, 640.0f));
        SkeletonSpec s = p.spec();
        assert(s.title == "Untitled" && s.bpm == 125.0 && s.ticksPerLine == 6);
        assert(s.timeSigNumerator == 4 && s.timeSigDenominator == 4 && s.key == MusicalKey.init && s.blocks.length == 0);
        assert(p.reason() == "" && p.createButton.enabled);
        p.onCreate = null;
        assert(p.reason() == "Creating a project is not connected yet" && !p.createButton.enabled);
        assert(!p.bodyView.scrollbarVisible(Axis.vertical));

        r.click(Point2F(5.0f, 5.0f));
        r.click(centerOf(r.root.transport.controlRect("transport.play")));
        assert(r.ui.overlays().length == 1 && r.root.skeletonPanel() is p);
        r.key(49);
        r.key(1, KeyModifiers.command);
        r.key(45, KeyModifiers.command);
        r.key(6);
        float[256] l = 0.0f;
        float[256] rr = 0.0f;
        float[][2] outs = [l[], rr[]];
        const(float[])[2] ins = [null, null];
        r.session.engine().processHostBuffer(outs, ins, 256);
        assert(!r.session.isPlaying() && acts.length == 0 && r.ui.overlays().length == 1);
        assert(r.ui.hovered() is null || p.isAncestorOf(r.ui.hovered()));

        r.click(centerOf(p.titleField.bounds));
        assert(r.ui.focused() is p.titleField);
        r.key(0, KeyModifiers.command);
        r.type("My Song");
        assert(p.spec().title == "My Song");
        r.key(48);
        assert(r.ui.focused() is p.bpmBox);
        r.key(48, KeyModifiers.shift);
        assert(r.ui.focused() is p.titleField);
        r.key(48);
        r.key(48);
        assert(r.ui.focused() is p.tplBox);

        r.send(PlatformEventKind.mouseDown, centerOf(p.bpmBox.bounds));
        r.send(PlatformEventKind.mouseUp, centerOf(p.bpmBox.bounds));
        r.send(PlatformEventKind.mouseDown, centerOf(p.bpmBox.bounds));
        r.send(PlatformEventKind.mouseUp, centerOf(p.bpmBox.bounds));
        assert(p.bpmBox.isEditing() && r.ui.focused() is p.bpmBox);
        r.type("140.5");
        r.key(36);
        assert(!p.bpmBox.isEditing() && p.spec().bpm == 140.5);
        p.tplBox.setValue(4.0f);
        p.sigNumBox.setValue(6.0f);
        p.sigDenBox.select(2);
        p.modeBox.select(1);
        assert(p.tonicBox.items == ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "Bb", "B"]);
        p.tonicBox.select(9);
        s = p.spec();
        assert(s.ticksPerLine == 4 && s.timeSigNumerator == 6 && s.timeSigDenominator == 8);
        assert(s.key == MusicalKey(9, KeyMode.minor));

        r.click(centerOf(p.titleField.bounds));
        r.key(53);
        assert(r.ui.overlays().length == 0 && r.root.skeletonPanel() is null);

        SkeletonPanel q = r.root.openSkeletonPanel();
        r.frame();
        assert(q !is p);
        s = q.spec();
        assert(s.title == "My Song" && s.bpm == 140.5 && s.ticksPerLine == 4 && s.timeSigDenominator == 8);
        assert(s.key == MusicalKey(9, KeyMode.minor) && q.tonicBox.selectedText() == "A" && q.modeBox.selectedText() == "Minor");
        r.click(centerOf(q.cancelButton.bounds));
        assert(r.ui.overlays().length == 0);
        assert(acts.length == 0);
    }

    unittest {
        PanelRig r = makeRig();
        scope (exit) r.session.dispose();
        SkeletonPanel p = r.root.openSkeletonPanel();
        r.frame();
        SkeletonSpec got;
        bool accept = false;
        int calls = 0;
        p.onCreate = (ref const SkeletonSpec sp) {
            calls++;
            got = cast(SkeletonSpec) sp;
            return accept;
        };
        assert(p.reason() == "" && p.createButton.enabled);
        r.frame();
        r.click(centerOf(p.createButton.bounds));
        assert(calls == 1 && r.root.skeletonPanel() is p);

        p.sigNumBox.setValue(5.0f);
        p.sigDenBox.select(3);
        assert(p.addChords("I V"));
        p.setSelectedLength(1);
        assert(p.reason().startsWith("Half-bar blocks need a bar with an even number of lines") && !p.createButton.enabled);
        r.frame();
        r.click(centerOf(p.createButton.bounds));
        assert(calls == 1 && !p.create());
        p.setSelectedLength(2);
        assert(p.reason() == "");

        accept = true;
        r.frame();
        r.click(centerOf(p.createButton.bounds));
        assert(calls == 2 && r.ui.overlays().length == 0 && got.blocks.length == 2 && got.timeSigNumerator == 5);
        LoadedProject proj;
        string err;
        assert(generateSkeleton(got, proj, err), err);
        assert(proj.patterns.length == 2 && proj.patterns[0].lines == 10);
    }

    unittest {
        PanelRig r = makeRig(800.0f, 420.0f);
        scope (exit) r.session.dispose();
        SkeletonPanel p = r.root.openSkeletonPanel();
        r.frame();
        assert(p.bounds.h == 420.0f && p.bounds.w == 720.0f);
        assert(p.bodyView.scrollbarVisible(Axis.vertical) && p.bodyView.scrollOffset().y == 0.0f);
        r.scroll(centerOf(p.bodyView.bounds), -200.0f);
        immutable float scrolled = p.bodyView.scrollOffset().y;
        assert(scrolled > 0.0f);
        r.scroll(centerOf(p.bodyView.bounds), 1000.0f);
        assert(p.bodyView.scrollOffset().y == 0.0f);
        assert(p.addChords("I"));
        r.click(centerOf(p.titleField.bounds));
        foreach (_; 0 .. 40) {
            r.key(48);
            if (r.ui.focused() is p.pianoBox) {
                break;
            }
        }
        assert(r.ui.focused() is p.pianoBox && p.bodyView.scrollOffset().y > 0.0f);
        assert(p.pianoBox.bounds.bottom() <= p.bodyView.viewportRect().bottom() + 0.01f);
        r.key(53);
    }

    unittest {
        PanelRig r = makeRig();
        scope (exit) r.session.dispose();
        SkeletonPanel p = r.root.openSkeletonPanel();
        r.frame();
        ChordBlockStrip st = p.strip;
        assert(p.totalText() == "" && !p.clearButton.enabled && !p.removeButton.enabled && !p.lengthBox.enabled);

        r.click(centerOf(p.chordField.bounds));
        assert(r.ui.focused() is p.chordField);
        r.type("ii V7 I");
        r.key(36);
        assert(st.blocks.length == 3 && p.chordField.text() == "" && p.chordError() == "" && st.selected == 2);
        assert(p.totalText() == "3 bars · 48 lines");
        assert(st.blockText(0) == ["ii · Dm", "1 bar"] && st.blockText(1) == ["V7 · G7", "1 bar"]);

        r.type("C H");
        r.key(36);
        assert(st.blocks.length == 3 && p.chordField.text() == "C H" && p.chordError().startsWith("\"H\":"));
        p.chordField.setText("Bb", false);
        r.click(centerOf(p.addChordsButton.bounds));
        assert(st.blocks.length == 4 && p.chordError() == "" && st.blocks[3].chord.form == ChordForm.name);
        assert(st.blockText(3)[0] == "bVII · Bb");

        assert(p.presetBox.items.length == 8 && p.presetBox.items[0] == "Circle of fifths: iii - vi - ii - V - I");
        st.select(0);
        p.presetBox.select(0);
        r.click(centerOf(p.insertButton.bounds));
        assert(st.blocks.length == 9 && st.selected == 5);
        assert(st.blockText(1)[0] == "iii · Em" && st.blockText(5)[0] == "I · C" && st.blockText(6)[0] == "V7 · G7");

        r.frame();
        r.click(centerOf(st.blockRect(3)));
        assert(st.selected == 3 && r.ui.focused() is st);
        r.key(124);
        assert(st.selected == 4 && st.blockText(4)[0] == "V · G");
        r.key(123, KeyModifiers.alt);
        assert(st.selected == 3 && st.blockText(3)[0] == "V · G" && st.blockText(4)[0] == "ii · Dm");
        r.key(51);
        assert(st.blocks.length == 8 && st.selected == 3 && st.blockText(3)[0] == "ii · Dm");
        r.key(123);
        r.key(123);
        r.key(123);
        r.key(123);
        assert(st.selected == 0 && !p.moveLeftButton.enabled && p.moveRightButton.enabled);
        r.click(centerOf(p.moveRightButton.bounds));
        assert(st.selected == 1 && st.blockText(1)[0] == "ii · Dm" && st.blockText(0)[0] == "iii · Em");
        r.click(centerOf(p.moveLeftButton.bounds));
        assert(st.selected == 0 && st.blockText(0)[0] == "ii · Dm");
        r.click(centerOf(p.removeButton.bounds));
        assert(st.blocks.length == 7 && st.selected == 0 && st.blockText(0)[0] == "iii · Em");

        immutable float w1 = st.contentWidth();
        p.lengthBox.select(3);
        assert(st.blocks[0].halfBars == 8 && st.blockText(0)[1] == "4 bars" && st.contentWidth() > w1);
        p.lengthBox.select(0);
        assert(st.blocks[0].halfBars == 1 && p.totalText() == "6½ bars · 104 lines");
        st.select(6);
        assert(p.lengthBox.selectedIndex == 1 && !p.moveRightButton.enabled);

        p.tonicBox.select(7);
        assert(st.blockText(0)[0] == "iii · Bm" && st.blockText(6)[0] == "bIII · Bb");
        p.modeBox.select(1);
        assert(p.presetBox.items.length == 3 && p.presetBox.items[2] == "Andalusian cadence: i - VII - VI - V");
        assert(p.tonicBox.selectedText() == "G" && p.spec().key == MusicalKey(7, KeyMode.minor));

        foreach (_; 0 .. 30) {
            p.addChords("I");
        }
        r.frame();
        assert(p.stripScroll.scrollbarVisible(Axis.horizontal) && p.stripScroll.scrollOffset().x > 0.0f);
        assert(st.blockRect(st.selected).right() <= p.stripScroll.viewportRect().right() + 0.01f);

        r.click(centerOf(p.clearButton.bounds));
        assert(st.blocks.length == 0 && st.selected == -1 && p.totalText() == "" && !p.clearButton.enabled);
        assert(p.addChords("") && st.blocks.length == 0);
        r.key(53);
    }

    unittest {
        PanelRig r = makeRig();
        scope (exit) r.session.dispose();
        immutable string dir = tempDir();
        immutable string pid = to!string(thisProcessID());
        immutable string good = buildPath(dir, "dracker_skeleton_" ~ pid ~ "_warm.msym");
        immutable string effect = buildPath(dir, "dracker_skeleton_" ~ pid ~ "_fx.msym");
        immutable string junk = buildPath(dir, "dracker_skeleton_" ~ pid ~ "_junk.msym");
        scope (exit) {
            removeQuietly(good);
            removeQuietly(effect);
            removeQuietly(junk);
        }
        string err;
        LoadedPreset warm;
        warm.presetName = "Warm Bass";
        warm.mod = defaultBassModule(9);
        assert(savePreset(warm, good, err), err);
        LoadedPreset fx;
        fx.presetName = "Shaper";
        assert(moduleWithDefaults("fx.waveshaper", 4, "Shaper", fx.mod));
        assert(savePreset(fx, effect, err), err);
        write(junk, "not a preset");

        SkeletonPanel p = r.root.openSkeletonPanel();
        r.frame();
        immutable string[] base = ["Default", "Analog Generator", "FM Synth", "SpectraVoice", "Load preset file…"];
        assert(p.bassBox.items == base && p.pianoBox.items == base);
        assert(!p.bassBox.enabled && !p.pianoBox.enabled);
        assert(p.addChords("I IV V"));
        assert(p.bassBox.enabled && p.pianoBox.enabled);

        p.bassBox.select(2);
        SkeletonSpec s = p.spec();
        assert(s.bass.source == InstrumentSource.moduleType && s.bass.typeId == "synth.fm_synth");
        assert(s.piano.source == InstrumentSource.defaultSound);

        r.dialog.openPath = good;
        p.pianoBox.select(4);
        assert(r.dialog.opens == 1 && r.dialog.lastTitle == "Load Piano Preset" && r.dialog.lastExtensions == ["msym"]);
        assert(p.pianoBox.items.length == 6 && p.pianoBox.items[4] == "Preset: Warm Bass" && p.pianoBox.selectedIndex == 4);
        assert(p.pianoBox.items[5] == "Load preset file…" && p.instrumentError() == "");
        s = p.spec();
        assert(s.piano.source == InstrumentSource.presetFile && s.piano.typeId == "synth.analog_gen");

        r.dialog.openPath = "";
        p.pianoBox.select(5);
        assert(r.dialog.opens == 2 && p.pianoBox.selectedIndex == 4 && p.pianoBox.items.length == 6);

        r.dialog.openPath = junk;
        p.bassBox.select(4);
        assert(p.instrumentError().startsWith("Could not load preset: ") && p.bassBox.selectedIndex == 2);
        assert(p.bassBox.items.length == 5);

        r.dialog.openPath = effect;
        p.bassBox.select(4);
        assert(p.instrumentError() == "\"Shaper\" cannot play notes; choose a synth preset");
        assert(p.bassBox.selectedIndex == 2 && p.spec().bass.typeId == "synth.fm_synth");
        p.bassBox.select(0);
        assert(p.instrumentError() == "" && p.spec().bass.source == InstrumentSource.defaultSound);

        LoadedProject proj;
        SkeletonSpec chosen = p.spec();
        assert(generateSkeleton(chosen, proj, err), err);
        assert(proj.modules[1].typeId == "synth.analog_gen" && proj.modules[2].typeId == "synth.analog_gen");
        assert(proj.modules[2].name == "Piano");

        r.key(53);
        SkeletonPanel q = r.root.openSkeletonPanel();
        r.frame();
        assert(q.pianoBox.items.length == 6 && q.pianoBox.selectedIndex == 4 && q.pianoBox.items[4] == "Preset: Warm Bass");
        r.key(53);

        StudioContext bare = new StudioContext(r.session);
        auto standalone = new SkeletonPanel(bare, SkeletonSpec.init);
        assert(!standalone.loadInstrumentPreset(InstrumentRole.bass));
        assert(standalone.instrumentError() == "File dialogs are not available");
        bool closed = false;
        standalone.onClosed = (SkeletonSpec last) { closed = true; };
        standalone.cancel();
        assert(closed);
    }

    unittest {
        PanelRig r = makeRig();
        scope (exit) r.session.dispose();
        Keymap km = Keymap.createDefault();
        assert(km.resolveAction(45, KeyModifiers.command | KeyModifiers.shift) == StudioAction.newSkeletonProject);
        assert(km.resolveAction(45, KeyModifiers.command) == StudioAction.newProject);
        assert(isDocumentLevel(StudioAction.newSkeletonProject));
        StudioAction[] acts;
        r.root.appCommandHandler = (StudioAction a) { acts ~= a; return true; };

        r.key(45, KeyModifiers.command | KeyModifiers.shift);
        SkeletonPanel p = r.root.skeletonPanel();
        assert(p !is null && r.ui.overlays().length == 1 && acts.length == 0);
        r.key(45, KeyModifiers.command | KeyModifiers.shift);
        assert(r.root.skeletonPanel() is p && r.ui.overlays().length == 1);
        r.key(53);
        assert(r.root.skeletonPanel() is null);
        assert(r.root.executeAction(StudioAction.newSkeletonProject) && r.root.skeletonPanel() !is null);
        assert(r.root.executeAction(StudioAction.newSkeletonProject) && r.ui.overlays().length == 1);
        r.key(53);
        assert(acts.length == 0 && r.ui.overlays().length == 0);
    }

    unittest {
        PanelRig r = makeRig();
        scope (exit) r.session.dispose();
        assert(!r.session.isDirty());
        SkeletonPanel p = r.root.openSkeletonPanel();
        r.frame();
        p.titleField.setText("Cadence", false);
        assert(p.addChords("ii V7 I"));
        r.click(centerOf(p.createButton.bounds));
        assert(r.root.unsavedPrompt() is null && r.root.skeletonPanel() is null && r.ui.overlays().length == 0);
        const doc = r.session.document();
        assert(doc.title == "Cadence" && doc.modules.length == 3 && doc.patterns.length == 2);
        assert(doc.patterns[0].name == "Bass" && doc.patterns[1].name == "Piano" && doc.clips.length == 2);
        assert(r.ctx.currentPattern() == 2 && r.ctx.status == "Created project Cadence");
        assert(r.session.isDirty() && !r.session.history().canUndo() && r.session.currentPath().length == 0);

        p = r.root.openSkeletonPanel();
        r.frame();
        assert(p.spec().title == "Cadence" && p.strip.blocks.length == 3);
        p.clearBlocks();
        assert(p.addChords("I IV"));
        p.titleField.setText("Second", false);
        r.click(centerOf(p.createButton.bounds));
        assert(r.root.unsavedPrompt() !is null && r.ui.overlays().length == 2 && r.root.skeletonPanel() is p);
        assert(r.root.unsavedPrompt().message
            == "The open project has unsaved changes. Creating a new project discards them.");
        r.key(53);
        assert(r.root.unsavedPrompt() is null && r.root.skeletonPanel() is p && r.ui.overlays().length == 1);
        assert(r.session.document().title == "Cadence" && p.spec().title == "Second");
        r.click(centerOf(p.createButton.bounds));
        assert(r.root.unsavedPrompt() !is null);
        r.key(36);
        assert(r.root.skeletonPanel() is null && r.ui.overlays().length == 0);
        assert(r.session.document().title == "Second" && r.session.document().patterns[0].lines == 32);

        p = r.root.openSkeletonPanel();
        r.frame();
        p.clearBlocks();
        p.titleField.setText("Empty", false);
        assert(!p.create());
        r.key(36);
        assert(r.session.document().title == "Empty" && r.session.document().modules.length == 1);
        assert(r.session.document().patterns.length == 1 && r.session.document().patterns[0].name == "Pattern 01");
        assert(r.ctx.currentPattern() == 1 && r.root.skeletonPanel() is null);

        p = r.root.openSkeletonPanel();
        r.frame();
        p.setCreateError("Could not create the project: test");
        assert(p.createError() == "Could not create the project: test");
        r.frame();
        p.onCreate = (ref const SkeletonSpec sp) => false;
        assert(!p.create() && p.createError() == "" && r.root.skeletonPanel() is p);
        r.key(53);
    }

    unittest {
        PanelRig r = makeRig();
        scope (exit) r.session.dispose();
        r.key(45, KeyModifiers.command | KeyModifiers.shift);
        SkeletonPanel p = r.root.skeletonPanel();
        assert(p !is null);
        r.click(centerOf(p.titleField.bounds));
        r.key(0, KeyModifiers.command);
        r.type("Circle Song");
        r.send(PlatformEventKind.mouseDown, centerOf(p.bpmBox.bounds));
        r.send(PlatformEventKind.mouseUp, centerOf(p.bpmBox.bounds));
        r.send(PlatformEventKind.mouseDown, centerOf(p.bpmBox.bounds));
        r.send(PlatformEventKind.mouseUp, centerOf(p.bpmBox.bounds));
        r.type("100");
        r.key(36);
        p.sigNumBox.setValue(3.0f);
        p.tonicBox.select(7);
        p.presetBox.select(0);
        r.click(centerOf(p.insertButton.bounds));
        assert(p.strip.blocks.length == 5 && p.strip.blockText(0)[0] == "iii · Bm");
        p.bassBox.select(2);
        r.frame();
        r.click(centerOf(p.createButton.bounds));
        assert(r.root.skeletonPanel() is null);

        const doc = r.session.document();
        assert(doc.title == "Circle Song" && doc.bpm == 100.0 && doc.timeSigNumerator == 3 && doc.timeSigDenominator == 4);
        assert(r.session.songKey() == MusicalKey(7, KeyMode.major) && r.session.linesPerBar() == 12);
        assert(doc.modules.length == 3 && doc.modules[1].typeId == "synth.fm_synth" && doc.modules[2].typeId == "synth.fm_synth");
        assert(doc.modules[1].name == "Bass" && doc.modules[2].name == "Piano");
        assert(doc.wires.length == 2 && doc.wires[0].dstMod == 1 && doc.wires[1].dstMod == 1);
        assert(doc.patterns[0].lines == 60 && doc.patterns[1].lines == 60 && doc.patterns[1].tracks == 4);
        assert(doc.clips.length == 2 && doc.clips[1].laneY == 1 && doc.loopEndLine == 60);
        immutable ubyte bNote = doc.patterns[0].cells[0].note;
        assert(bNote == NoteCell.makeNote(47, 1.0f, 0).note);
        assert(doc.patterns[1].cells[12 * 4].note == NoteCell.makeNote(64, 1.0f, 0).note);

        r.frame();
        assert(r.root.pattern.barLines() == 12);

        ubyte[] bytes;
        string err;
        assert(r.session.saveProjectToBytes(bytes, err), err);
        StudioSession again = new StudioSession();
        assert(again.initialize(44_100.0f));
        scope (exit) again.shutdown();
        assert(again.loadProjectFromBytes(bytes, err), err);
        const d2 = again.document();
        assert(d2.title == doc.title && d2.bpm == doc.bpm && d2.timeSigNumerator == 3 && d2.keyTonic == 7);
        assert(d2.modules.length == 3 && d2.wires == doc.wires && d2.clips == doc.clips);
        foreach (i; 0 .. 2) {
            assert(d2.patterns[i].name == doc.patterns[i].name && d2.patterns[i].cells == doc.patterns[i].cells);
        }
        assert(d2.loopEndLine == 60);

        again.engine().reset();
        again.engine().setTempo(d2.bpm, d2.ticksPerLine);
        again.engine().seekLine(0);
        again.engine().setPlaying(true);
        OwnedBuffer!float l;
        OwnedBuffer!float rr;
        assert(again.engine().renderOfflineToBuffer(44_100, 64, l, rr));
        float peak = 0.0f;
        foreach (i; 0 .. l.length) {
            peak = fabs(l[i]) > peak ? fabs(l[i]) : peak;
        }
        assert(peak > 0.01f && peak < 1.0f);
    }
}
