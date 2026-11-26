/**
 * File:         tests/unit/session_test.d
 * Module:       tests.unit.session_test
 * Phase:        Phase 6.3 / T111 — Undoable Document Replacement Tests
 *
 * Purpose:
 *   Verifies StudioSession.doReplaceDocument: replace, undo and redo give identical documents and bit-exact
 *   renders; a document that fails activation changes nothing (bytes, undo counts, revision); the default
 *   label applies; file path and modified flag survive the swap; and the transport keeps running where the
 *   new timeline allows it.
 *
 * Real-Time & Safety Contract:
 *   Executes offline host blocks and renderOfflineToBuffer on the main thread; temporary files removed via scope(exit).
 *
 * Dependencies:
 *   Internal: app.session, foundation.memory, io.project_format, sequencer.{engine,note,timeline}, tests.audio_harness
 *   External: std.file (exists, remove, tempDir), std.math (fabs, isFinite), std.path (buildPath)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites covering the T111 acceptance table
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.unit.session_test;

version (unittest) {
    import std.file : exists, remove, tempDir;
    import std.math : fabs, isFinite;
    import std.path : buildPath;

    import app.session : StudioSession;
    import foundation.memory : OwnedBuffer;
    import io.project_format : LoadedProject, SavedModule, SavedPattern, SavedWire;
    import sequencer.engine : EngineTelemetry;
    import sequencer.note : NoteCell;
    import sequencer.timeline : TimelineClip;
    import tests.audio_harness : AudioMetrics, compareStereo;

    private LoadedProject makeMemoryProject(uint clipLines = 16) {
        LoadedProject proj;
        proj.title = "Skeleton";
        proj.bpm = 96.0;
        proj.ticksPerLine = 6;
        SavedModule master;
        master.id = 1;
        master.typeId = "core.output";
        master.name = "Master Output";
        master.paramValues = [1.0f, 1.0f];
        SavedModule synth;
        synth.id = 2;
        synth.typeId = "synth.analog_gen";
        synth.name = "Bass";
        proj.modules = [master, synth];
        proj.wires = [SavedWire(2, 2, 1, 0, 1.0f)];
        SavedPattern pat;
        pat.patternId = 1;
        pat.tracks = 1;
        pat.lines = 16;
        pat.name = "Bass";
        pat.cells = new NoteCell[16];
        pat.cells[0] = NoteCell.makeNote(48, 0.9f, 2);
        proj.patterns = [pat];
        proj.clips = [TimelineClip(1, 1, 0, 0, clipLines, 0, 0, false, false, false)];
        return proj;
    }

    private void renderSession(StudioSession s, out OwnedBuffer!float l, out OwnedBuffer!float r) {
        s.engine().reset();
        s.engine().setTempo(s.document().bpm, s.document().ticksPerLine);
        s.engine().seekLine(0);
        s.engine().setPlaying(true);
        assert(s.engine().renderOfflineToBuffer(4096, 64, l, r));
        s.engine().setPlaying(false);
    }

    private float renderPeak(StudioSession s, size_t blocks) {
        float[256] l = 0.0f;
        float[256] r = 0.0f;
        float peak = 0.0f;
        const(float[])[2] ins = [null, null];
        foreach (_; 0 .. blocks) {
            float[][2] outs = [l[], r[]];
            s.engine().processHostBuffer(outs, ins, 256);
            immutable float p = peakOf(l[]) > peakOf(r[]) ? peakOf(l[]) : peakOf(r[]);
            if (p > peak) peak = p;
        }
        return peak;
    }

    private float maxPeakStereo(const(float)[] l, const(float)[] r) @nogc nothrow pure @safe {
        float p = 0.0f;
        foreach (i; 0 .. l.length) {
            assert(isFinite(l[i]) && isFinite(r[i]));
            immutable float al = fabs(l[i]);
            immutable float ar = fabs(r[i]);
            if (al > p) p = al;
            if (ar > p) p = ar;
        }
        return p;
    }

    private float peakOf(const(float)[] a) {
        float p = 0.0f;
        foreach (v; a) {
            assert(isFinite(v));
            immutable float x = fabs(v);
            if (x > p) p = x;
        }
        return p;
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string err;
        assert(s.doAddModule("synth.analog_gen", "Gen") == 2);
        assert(s.doConnectWire(2, 2, 1, 0, 1.0f));
        assert(s.doPatchCell(1, 0, 0, NoteCell.makeNote(60, 0.9f, 2)));
        assert(s.history().undoCount() == 3);

        ubyte[] bytesBefore;
        assert(s.saveProjectToBytes(bytesBefore, err), err);
        OwnedBuffer!float lBefore;
        OwnedBuffer!float rBefore;
        renderSession(s, lBefore, rBefore);

        LoadedProject p = makeMemoryProject();
        assert(s.doReplaceDocument(p, "Run Script", err), err);
        assert(err is null);
        assert(s.history().undoCount() == 4);
        assert(s.history().redoCount() == 0);
        assert(s.history().nextUndoLabel() == "Run Script");
        assert(s.document().title == "Skeleton");
        assert(s.isDirty());

        ubyte[] bytesAfter;
        assert(s.saveProjectToBytes(bytesAfter, err), err);
        OwnedBuffer!float lAfter;
        OwnedBuffer!float rAfter;
        renderSession(s, lAfter, rAfter);
        assert(maxPeakStereo(lAfter[], rAfter[]) > 0.01f);

        assert(s.undo());
        assert(s.history().undoCount() == 3);
        assert(s.history().redoCount() == 1);
        assert(s.document().title == "Untitled");
        ubyte[] bytesUndo;
        assert(s.saveProjectToBytes(bytesUndo, err), err);
        assert(bytesUndo == bytesBefore);
        OwnedBuffer!float lUndo;
        OwnedBuffer!float rUndo;
        renderSession(s, lUndo, rUndo);
        immutable AudioMetrics cmpUndo = compareStereo(lUndo[], rUndo[], lBefore[], rBefore[]);
        assert(cmpUndo.bitExact());

        assert(s.redo());
        assert(s.history().undoCount() == 4);
        assert(s.history().redoCount() == 0);
        ubyte[] bytesRedo;
        assert(s.saveProjectToBytes(bytesRedo, err), err);
        assert(bytesRedo == bytesAfter);
        OwnedBuffer!float lRedo;
        OwnedBuffer!float rRedo;
        renderSession(s, lRedo, rRedo);
        immutable AudioMetrics cmpRedo = compareStereo(lRedo[], rRedo[], lAfter[], rAfter[]);
        assert(cmpRedo.bitExact());

        foreach (_; 0 .. 4) {
            assert(s.undo());
        }
        assert(s.history().undoCount() == 0);
        assert(s.history().redoCount() == 4);
        assert(s.document().modules.length == 1);
        foreach (_; 0 .. 4) {
            assert(s.redo());
        }
        ubyte[] bytesFinal;
        assert(s.saveProjectToBytes(bytesFinal, err), err);
        assert(bytesFinal == bytesAfter);

        assert(s.doAddModule("synth.fm_synth", "Next") == 3);
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string err;
        assert(s.doAddModule("synth.fm_synth", "Old") != 0);
        immutable ulong rev0 = s.documentRevision();
        ubyte[] bytes0;
        assert(s.saveProjectToBytes(bytes0, err), err);

        LoadedProject badTempo = makeMemoryProject();
        badTempo.title = "Bad tempo";
        badTempo.bpm = 5.0;
        assert(!s.doReplaceDocument(badTempo, "Bad tempo", err));
        assert(err == "Out-of-range BPM or TPL");

        LoadedProject badShape = makeMemoryProject();
        badShape.title = "Bad shape";
        badShape.patterns[0].lines = 0;
        assert(!s.doReplaceDocument(badShape, "Bad shape", err));
        assert(err.length > 0);

        LoadedProject dupIds = makeMemoryProject();
        dupIds.title = "Duplicate ids";
        dupIds.modules[1].id = 1;
        assert(!s.doReplaceDocument(dupIds, "Duplicate ids", err));
        assert(err.length > 0);

        LoadedProject badType = makeMemoryProject();
        badType.title = "Bad type";
        badType.modules[1].typeId = "synth.does_not_exist";
        assert(!s.doReplaceDocument(badType, "Bad type", err));
        assert(err.length > 0);

        LoadedProject loopWire = makeMemoryProject();
        loopWire.title = "Wire loop";
        loopWire.wires = [SavedWire(2, 2, 1, 0, 1.0f), SavedWire(1, 0, 2, 0, 1.0f)];
        assert(!s.doReplaceDocument(loopWire, "Wire loop", err));
        assert(err.length > 0);

        ubyte[] bytesStill;
        assert(s.saveProjectToBytes(bytesStill, err), err);
        assert(bytesStill == bytes0);
        assert(s.history().undoCount() == 1);
        assert(s.history().redoCount() == 0);
        assert(s.documentRevision() == rev0);
        assert(s.document().title == "Untitled" && s.document().modules.length == 2);

        LoadedProject p = makeMemoryProject();
        assert(s.doReplaceDocument(p, "", err), err);
        assert(s.history().nextUndoLabel() == "Replace Document");
        assert(s.history().undoCount() == 2);
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string err;
        immutable string path = buildPath(tempDir(), "dracker_session_replace_test.msv");
        scope (exit) {
            if (exists(path)) {
                remove(path);
            }
        }

        assert(s.saveProjectToFile(path, err), err);
        assert(!s.isDirty());
        assert(s.currentPath() == path);

        LoadedProject p = makeMemoryProject();
        assert(s.doReplaceDocument(p, "Replace", err), err);
        assert(s.isDirty());
        assert(s.currentPath() == path);

        assert(s.undo());
        assert(s.isDirty());
        assert(s.currentPath() == path);
        assert(s.document().title == "Untitled");
    }

    unittest {
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string err;
        EngineTelemetry tel;

        LoadedProject p = makeMemoryProject();
        assert(s.doReplaceDocument(p, "Replace", err), err);
        cast(void) renderPeak(s, 2);
        s.engine().readTelemetry(tel);
        assert(!tel.playing);
        assert(tel.currentLine == 0);

        assert(s.play());
        cast(void) renderPeak(s, 100);
        s.engine().readTelemetry(tel);
        immutable long line = tel.currentLine;
        assert(line > 0 && line < 16);

        assert(s.doReplaceDocument(p, "Replace again", err), err);
        cast(void) renderPeak(s, 1);
        s.engine().readTelemetry(tel);
        assert(tel.playing);
        assert(tel.currentLine == line);

        LoadedProject shortP = makeMemoryProject(2);
        assert(s.doReplaceDocument(shortP, "Short song", err), err);
        cast(void) renderPeak(s, 1);
        s.engine().readTelemetry(tel);
        assert(tel.playing);
        assert(tel.currentLine == 0);

        assert(s.undo());
        cast(void) renderPeak(s, 1);
        s.engine().readTelemetry(tel);
        assert(tel.playing);
        assert(tel.currentLine == 0);
    }
}
