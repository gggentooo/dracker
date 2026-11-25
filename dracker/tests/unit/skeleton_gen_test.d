/**
 * File:         tests/unit/skeleton_gen_test.d
 * Module:       tests.unit.skeleton_gen_test
 * Phase:        Skeleton project generator — T13 (instrument choices and default sounds)
 *
 * Purpose:
 *   Verifies app.skeleton_gen instrument handling: the dropdown choice list and labels, that every choice
 *   resolves for both roles to a valid module of a registered type, the default bass and piano parameter sets
 *   (inside each parameter's range), refusal of unlisted types, non-playable presets, mismatched presets and id 0,
 *   port lookup helpers, that every choice renders a non-silent note through a real StudioSession, and (T19)
 *   SkeletonSpec validation and generateSkeleton() cell by cell in major and minor keys, 4/4, 3/4 and 3/8, mixed
 *   block lengths and slash basses, plus an offline render with each part muted in turn.
 *
 * Real-Time & Safety Contract:
 *   Off-RT; renders offline through StudioSession.engine().renderOfflineToBuffer().
 *
 * Dependencies:
 *   Internal: app.session, app.skeleton_gen, foundation.memory, graph.module_api, graph.registry, io.project_format,
 *     sequencer.note, sequencer.timeline
 *   External: std.math (fabs)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T06, T13)
 */
module tests.unit.skeleton_gen_test;

version (unittest) {
    import std.math : fabs;

    import app.chord_progression : ChordBlock, parseProgression, ProgressionError;
    import app.music_theory : KeyMode, MusicalKey;
    import app.session : StudioSession;
    import app.skeleton_gen;
    import foundation.memory : OwnedBuffer;
    import graph.module_api : ModuleDescriptor;
    import graph.registry : ModuleRegistry;
    import io.project_format : LoadedPreset, LoadedProject, SavedModule, SavedPattern, SavedWire,
        validateModuleForSave;
    import sequencer.note : NoteCell;
    import sequencer.timeline : TimelineClip;

    private float peakOf(const(float)[] l, const(float)[] r) {
        float p = 0.0f;
        foreach (i; 0 .. l.length) {
            p = fabs(l[i]) > p ? fabs(l[i]) : p;
            p = fabs(r[i]) > p ? fabs(r[i]) : p;
        }
        return p;
    }

    private float renderOneNote(const ref SavedModule inst, int midi) {
        const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(inst.typeId);
        LoadedProject proj;
        proj.title = "Instrument check";
        SavedModule master;
        master.id = 1;
        master.typeId = "core.output";
        master.name = "Master Output";
        master.paramValues = [1.0f, 1.0f];
        proj.modules = [master, cast(SavedModule) inst];
        proj.wires = [SavedWire(inst.id, cast(ushort) audioOutputPort(d), 1, 0, 1.0f)];
        SavedPattern pat;
        pat.patternId = 1;
        pat.tracks = 1;
        pat.lines = 16;
        pat.name = "Check";
        pat.cells = new NoteCell[16];
        pat.cells[0] = NoteCell.makeNote(midi, 0.9f, cast(ushort) inst.id);
        proj.patterns = [pat];
        proj.clips = [TimelineClip(1, 1, 0, 0, 16, 0, 0, false, false, false)];

        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string err;
        assert(s.openProjectFromMemory(proj, err), err);
        s.engine().reset();
        s.engine().setTempo(120.0, 6);
        s.engine().seekLine(0);
        s.engine().setPlaying(true);
        OwnedBuffer!float l;
        OwnedBuffer!float r;
        assert(s.engine().renderOfflineToBuffer(8192, 64, l, r));
        return peakOf(l[], r[]);
    }

    private void assertInRange(const ref SavedModule m) {
        const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(m.typeId);
        assert(d !is null && m.paramValues.length == d.params.length);
        foreach (i, ref p; d.params) {
            assert(m.paramValues[i] >= p.minVal && m.paramValues[i] <= p.maxVal, p.name);
        }
        string err;
        assert(validateModuleForSave(m, 0, err), err);
    }

    unittest {
        InstrumentChoice[] choices = instrumentChoices();
        assert(choices.length == 1 + SELECTABLE_SYNTH_TYPES.length);
        assert(choices[0].source == InstrumentSource.defaultSound && choices[0].label() == "Default");
        assert(choices[1].typeId == "synth.analog_gen" && choices[1].label() == "Analog Generator");
        assert(choices[2].typeId == "synth.fm_synth" && choices[2].label() == "FM Synth");
        assert(choices[3].typeId == "synth.spectravoice" && choices[3].label() == "SpectraVoice");
        foreach (t; SELECTABLE_SYNTH_TYPES) {
            assert(isPlayableInstrument(t), t);
        }
        assert(!isPlayableInstrument("core.output") && !isPlayableInstrument("fx.waveshaper"));
        assert(!isPlayableInstrument("synth.does_not_exist"));

        const(ModuleDescriptor)* ag = ModuleRegistry.findByTypeId("synth.analog_gen");
        assert(audioOutputPort(ag) == 2 && eventInputPort(ag) >= 0);
        assert(audioOutputPort(ModuleRegistry.findByTypeId("synth.fm_synth")) == 1);
        assert(audioOutputPort(null) == -1 && eventInputPort(null) == -1 && paramIndex(null, "Cutoff") == -1);
        assert(paramIndex(ag, "Cutoff") == 3 && paramIndex(ag, "No such parameter") == -1);
    }

    unittest {
        SavedModule bass = defaultBassModule(7);
        assert(bass.id == 7 && bass.typeId == "synth.analog_gen" && bass.name == "Bass");
        const(ModuleDescriptor)* ag = ModuleRegistry.findByTypeId("synth.analog_gen");
        assert(bass.paramValues[paramIndex(ag, "Waveform")] == 2.0f);
        assert(bass.paramValues[paramIndex(ag, "Cutoff")] == 900.0f);
        assertInRange(bass);

        SavedModule piano = defaultPianoModule(8);
        assert(piano.id == 8 && piano.typeId == "synth.fm_synth" && piano.name == "Piano");
        const(ModuleDescriptor)* fm = ModuleRegistry.findByTypeId("synth.fm_synth");
        assert(piano.paramValues[paramIndex(fm, "Algorithm")] == 2.0f);
        assert(piano.paramValues[paramIndex(fm, "Op5 Ratio")] == 14.0f);
        assert(piano.paramValues[paramIndex(fm, "Op4 Level")] == 0.0f);
        assertInRange(piano);

        SavedModule plain;
        assert(moduleWithDefaults("synth.fm_synth", 3, "X", plain));
        assert(plain.paramValues[paramIndex(fm, "Algorithm")] == fm.params[paramIndex(fm, "Algorithm")].defaultVal);
        assert(!moduleWithDefaults("synth.does_not_exist", 3, "X", plain));
    }

    unittest {
        string err;
        foreach (role; [InstrumentRole.bass, InstrumentRole.piano]) {
            foreach (ref c; instrumentChoices()) {
                SavedModule m;
                assert(resolveInstrument(role, c, 5, 120.0f, 40.0f, m, err), err);
                assert(m.id == 5 && m.posX == 120.0f && m.posY == 40.0f);
                assert(m.name == (role == InstrumentRole.bass ? "Bass" : "Piano"));
                assert(c.source != InstrumentSource.moduleType || m.typeId == c.typeId);
                assertInRange(m);
                immutable int midi = role == InstrumentRole.bass ? 40 : 64;
                assert(renderOneNote(m, midi) > 0.01f, m.typeId);
            }
        }
        SavedModule d;
        InstrumentChoice def = InstrumentChoice.defaults();
        assert(resolveInstrument(InstrumentRole.bass, def, 2, 0, 0, d, err) && d.typeId == "synth.analog_gen");
        assert(resolveInstrument(InstrumentRole.piano, def, 3, 0, 0, d, err) && d.typeId == "synth.fm_synth");
        assert(!resolveInstrument(InstrumentRole.bass, def, 0, 0, 0, d, err) && err.length > 0);

        foreach (t; ["synth.sampler", "fx.waveshaper", "core.output", "synth.does_not_exist"]) {
            InstrumentChoice c = InstrumentChoice.ofType(t);
            assert(!resolveInstrument(InstrumentRole.bass, c, 2, 0, 0, d, err) && err.length > 0, t);
        }
    }

    unittest {
        string err;
        LoadedPreset p;
        p.presetName = "Warm Bass";
        p.mod = defaultBassModule(42);
        p.mod.name = "Saved name";
        p.mod.muted = true;
        p.mod.extraBlob = [1, 2, 3];
        InstrumentChoice c = InstrumentChoice.ofPreset(p);
        assert(c.source == InstrumentSource.presetFile && c.label() == "Preset: Warm Bass");
        p.mod.extraBlob[0] = 99;
        SavedModule m;
        assert(resolveInstrument(InstrumentRole.piano, c, 4, 0, 0, m, err), err);
        assert(m.id == 4 && m.name == "Piano" && !m.muted && m.typeId == "synth.analog_gen");
        assert(m.extraBlob == [1, 2, 3] && m.paramValues == defaultBassModule(1).paramValues);

        LoadedPreset unnamed;
        assert(InstrumentChoice.ofPreset(unnamed).label() == "Preset: Preset");
        unnamed.presetName = "";
        unnamed.mod = defaultPianoModule(1);
        assert(InstrumentChoice.ofPreset(unnamed).label() == "Preset: Piano");

        LoadedPreset effect;
        effect.presetName = "Shaper";
        assert(moduleWithDefaults("fx.waveshaper", 1, "Shaper", effect.mod));
        InstrumentChoice ce = InstrumentChoice.ofPreset(effect);
        assert(!resolveInstrument(InstrumentRole.bass, ce, 2, 0, 0, m, err) && err.length > 0);

        LoadedPreset broken;
        broken.mod = defaultBassModule(1);
        broken.mod.paramValues = broken.mod.paramValues[0 .. 3];
        InstrumentChoice cb = InstrumentChoice.ofPreset(broken);
        assert(!resolveInstrument(InstrumentRole.bass, cb, 2, 0, 0, m, err) && err == "Preset does not match its module type");

        LoadedPreset unknown;
        unknown.mod.typeId = "synth.does_not_exist";
        InstrumentChoice cu = InstrumentChoice.ofPreset(unknown);
        assert(!resolveInstrument(InstrumentRole.bass, cu, 2, 0, 0, m, err) && err.length > 0);
    }

    unittest {
        LoadedProject p = instrumentPreviewProject();
        assert(p.modules.length == 3 && p.modules[1].typeId == "synth.analog_gen" && p.modules[2].typeId == "synth.fm_synth");
        assert(p.wires.length == 2 && p.wires[0].gain == PREVIEW_BASS_GAIN && p.wires[1].gain == PREVIEW_PIANO_GAIN);
        const SavedPattern pat = p.patterns[0];
        assert(pat.tracks == 5 && pat.lines == PREVIEW_BARS * PREVIEW_LINES_PER_BAR);
        NoteCell at(uint line, uint track) {
            return pat.cells[line * pat.tracks + track];
        }
        assert(at(0, 0).note == NoteCell.makeNote(36, 0.9f, 2).note && at(0, 1).note == 0);
        assert(at(64, 0).note == NoteCell.makeNoteOff(2).note && at(64, 1).note == NoteCell.makeNote(60, 0.8f, 3).note);
        assert(at(64 + 48, 4).note == NoteCell.makeNote(65, 0.8f, 3).note);
        assert(at(64, 4).note == NoteCell.makeNoteOff(3).note);
        assert(at(128, 0).note == NoteCell.makeNote(36, 0.9f, 2).note);
        foreach (t; 0 .. 5) {
            assert(at(pat.lines - 1, t).note == NoteCell.makeNoteOff().note);
        }

        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string err;
        assert(s.openProjectFromMemory(p, err), err);
        foreach (startLine; [0, 64, 128]) {
            s.engine().reset();
            s.engine().setTempo(p.bpm, p.ticksPerLine);
            s.engine().seekLine(startLine);
            s.engine().setPlaying(true);
            OwnedBuffer!float l;
            OwnedBuffer!float r;
            assert(s.engine().renderOfflineToBuffer(22_050, 64, l, r));
            immutable float peak = peakOf(l[], r[]);
            assert(peak > 0.01f && peak < 1.0f, "segment at line " ~ (startLine == 0 ? "0" : startLine == 64 ? "64" : "128"));
        }
    }

    private SkeletonSpec specOf(string chords, MusicalKey key = MusicalKey.init, uint num = 4, uint den = 4) {
        SkeletonSpec sp;
        sp.key = key;
        sp.timeSigNumerator = num;
        sp.timeSigDenominator = den;
        ProgressionError e;
        assert(parseProgression(chords, sp.blocks, e), e.message);
        return sp;
    }

    private LoadedProject generate(const ref SkeletonSpec sp) {
        LoadedProject p;
        string err;
        assert(generateSkeleton(sp, p, err), err);
        return p;
    }

    private int noteAt(const ref SavedPattern pat, uint line, uint track) {
        immutable NoteCell c = pat.cells[line * pat.tracks + track];
        return c.note;
    }

    private int midi(int m) {
        return NoteCell.makeNote(m, 1.0f, 0).note;
    }

    private immutable int OFF = NoteCell.makeNoteOff().note;

    unittest {
        SkeletonSpec empty;
        LoadedProject p = generate(empty);
        assert(p.title == "Untitled" && p.bpm == 125.0 && p.ticksPerLine == 6);
        assert(p.timeSigNumerator == 4 && p.timeSigDenominator == 4 && p.keyTonic == 0 && p.keyMode == 0);
        assert(p.modules.length == 1 && p.modules[0].typeId == "core.output" && p.wires.length == 0);
        assert(p.patterns.length == 1 && p.patterns[0].tracks == 4 && p.patterns[0].lines == 64);
        assert(p.clips.length == 1 && p.clips[0].lengthLines == 64 && p.loopEndLine == 0);
        foreach (ref c; p.patterns[0].cells) {
            assert(c.note == 0);
        }
        SkeletonSpec waltz;
        waltz.title = "Waltz";
        waltz.timeSigNumerator = 3;
        waltz.key = MusicalKey(9, KeyMode.minor);
        p = generate(waltz);
        assert(p.title == "Waltz" && p.patterns[0].lines == 48 && p.timeSigNumerator == 3);
        assert(p.keyTonic == 9 && p.keyMode == 1);
        waltz.title = "";
        assert(generate(waltz).title == "Untitled");
    }

    unittest {
        SkeletonSpec sp = specOf("ii V7 I");
        sp.title = "Cadence";
        sp.bpm = 96.0;
        LoadedProject p = generate(sp);
        assert(p.title == "Cadence" && p.bpm == 96.0);
        assert(p.modules.length == 3 && p.modules[1].id == 2 && p.modules[1].name == "Bass" && p.modules[2].name == "Piano");
        assert(p.modules[1].typeId == "synth.analog_gen" && p.modules[2].typeId == "synth.fm_synth");
        assert(p.wires.length == 2 && p.wires[0].srcMod == 2 && p.wires[0].dstMod == 1 && p.wires[0].srcPort == 2);
        assert(p.wires[1].srcMod == 3 && p.wires[1].srcPort == 1 && p.wires[0].gain == SKELETON_BASS_GAIN);
        assert(p.wires[1].gain == SKELETON_PIANO_GAIN);
        assert(p.patterns.length == 2);
        const SavedPattern bass = p.patterns[0];
        const SavedPattern piano = p.patterns[1];
        assert(bass.name == "Bass" && bass.tracks == 1 && bass.lines == 48);
        assert(piano.name == "Piano" && piano.tracks == 4 && piano.lines == 48);
        assert(noteAt(bass, 0, 0) == midi(38) && noteAt(bass, 16, 0) == midi(43) && noteAt(bass, 32, 0) == midi(36));
        assert(noteAt(bass, 47, 0) == OFF && noteAt(bass, 1, 0) == 0 && noteAt(bass, 15, 0) == 0);
        assert(noteAt(piano, 0, 0) == midi(62) && noteAt(piano, 0, 1) == midi(65) && noteAt(piano, 0, 2) == midi(69));
        assert(noteAt(piano, 0, 3) == 0);
        assert(noteAt(piano, 16, 0) == midi(67) && noteAt(piano, 16, 1) == midi(71) && noteAt(piano, 16, 2) == midi(74)
            && noteAt(piano, 16, 3) == midi(77));
        assert(noteAt(piano, 32, 0) == midi(60) && noteAt(piano, 32, 1) == midi(64) && noteAt(piano, 32, 2) == midi(67)
            && noteAt(piano, 32, 3) == OFF);
        foreach (t; 0 .. 4) {
            assert(noteAt(piano, 47, t) == OFF);
        }
        foreach (ref c; bass.cells) {
            assert(c.note == 0 || c.moduleId == 2);
        }
        foreach (ref c; piano.cells) {
            assert(c.note == 0 || c.moduleId == 3);
        }
        assert(p.clips.length == 2 && p.clips[0].patternId == 1 && p.clips[0].laneY == 0 && p.clips[1].patternId == 2);
        assert(p.clips[1].laneY == 1 && p.clips[0].startLine == 0 && p.clips[1].lengthLines == 48);
        assert(p.loopStartLine == 0 && p.loopEndLine == 48);
    }

    unittest {
        SkeletonSpec sp = specOf("i iv V", MusicalKey(9, KeyMode.minor), 3, 4);
        LoadedProject p = generate(sp);
        const SavedPattern bass = p.patterns[0];
        const SavedPattern piano = p.patterns[1];
        assert(bass.lines == 36 && piano.lines == 36 && p.timeSigNumerator == 3);
        assert(noteAt(bass, 0, 0) == midi(45) && noteAt(bass, 12, 0) == midi(38) && noteAt(bass, 24, 0) == midi(40));
        assert(noteAt(piano, 0, 0) == midi(69) && noteAt(piano, 0, 1) == midi(72) && noteAt(piano, 0, 2) == midi(76));
        assert(noteAt(piano, 12, 0) == midi(62) && noteAt(piano, 12, 1) == midi(65) && noteAt(piano, 12, 2) == midi(69));
        assert(noteAt(piano, 24, 0) == midi(64) && noteAt(piano, 24, 1) == midi(68) && noteAt(piano, 24, 2) == midi(71));
        assert(noteAt(piano, 12, 3) == 0 && noteAt(piano, 35, 3) == OFF);

        SkeletonSpec mixed = specOf("C Am F G");
        mixed.blocks[0].halfBars = 1;
        mixed.blocks[2].halfBars = 4;
        mixed.blocks[3].halfBars = 8;
        p = generate(mixed);
        assert(p.patterns[0].lines == 8 + 16 + 32 + 64 && totalLines(mixed) == 120);
        assert(noteAt(p.patterns[0], 0, 0) == midi(36) && noteAt(p.patterns[0], 8, 0) == midi(45));
        assert(noteAt(p.patterns[0], 24, 0) == midi(41) && noteAt(p.patterns[0], 56, 0) == midi(43));

        SkeletonSpec slash = specOf("C/E G/B");
        p = generate(slash);
        assert(noteAt(p.patterns[0], 0, 0) == midi(40) && noteAt(p.patterns[0], 16, 0) == midi(47));
        assert(noteAt(p.patterns[1], 0, 0) == midi(60) && noteAt(p.patterns[1], 16, 0) == midi(67));

        SkeletonSpec eighths = specOf("I V", MusicalKey.init, 3, 8);
        eighths.blocks[0].halfBars = 1;
        p = generate(eighths);
        assert(specLinesPerBar(eighths) == 6 && p.patterns[0].lines == 3 + 6);
        assert(noteAt(p.patterns[0], 3, 0) == midi(43));

        SkeletonSpec tiny = specOf("I V", MusicalKey.init, 1, 8);
        tiny.blocks[1].halfBars = 1;
        p = generate(tiny);
        assert(p.patterns[0].lines == 3 && noteAt(p.patterns[0], 2, 0) == midi(43));
    }

    unittest {
        string err;
        LoadedProject p;
        SkeletonSpec sp = specOf("I IV V");
        assert(validateSpec(sp, err));
        sp.bpm = 5.0;
        assert(!validateSpec(sp, err) && err == "Tempo must be 20–999 BPM with 1–255 ticks per line");
        assert(!generateSkeleton(sp, p, err));
        sp.bpm = 120.0;
        sp.ticksPerLine = 0;
        assert(!validateSpec(sp, err));
        sp.ticksPerLine = 6;
        sp.timeSigDenominator = 3;
        assert(!validateSpec(sp, err) && err == "The time signature must be 1–16 beats over 2, 4, 8 or 16");
        sp.timeSigDenominator = 4;
        sp.key = MusicalKey(12, KeyMode.major);
        assert(!validateSpec(sp, err) && err == "Unknown key");
        sp.key = MusicalKey.init;
        sp.blocks[0].halfBars = 3;
        assert(!validateSpec(sp, err) && err == "A block must last ½, 1, 2 or 4 bars");
        sp.blocks[0].halfBars = 2;

        SkeletonSpec odd = specOf("I V", MusicalKey.init, 5, 16);
        assert(validateSpec(odd, err));
        odd.blocks[0].halfBars = 1;
        assert(!validateSpec(odd, err));
        assert(err == "Half-bar blocks need a bar with an even number of lines; this time signature has 5 lines per bar");

        SkeletonSpec longOne = specOf("I");
        foreach (_; 0 .. 64) {
            longOne.blocks ~= ChordBlock(longOne.blocks[0].chord, 8);
        }
        longOne.blocks[0].halfBars = 8;
        assert(totalLines(longOne) == 65 * 64);
        assert(!validateSpec(longOne, err) && err == "The progression is 4160 lines long; the limit is 4096 lines");
        longOne.blocks = longOne.blocks[0 .. 64];
        assert(validateSpec(longOne, err) && generate(longOne).patterns[1].lines == 4096);

        sp.bass = InstrumentChoice.ofType("synth.sampler");
        assert(!validateSpec(sp, err) && err[0 .. 6] == "Bass: ");
        sp.bass = InstrumentChoice.ofType("synth.spectravoice");
        sp.piano = InstrumentChoice.ofType("fx.waveshaper");
        assert(!validateSpec(sp, err) && err[0 .. 7] == "Piano: ");
        sp.piano = InstrumentChoice.ofType("synth.analog_gen");
        p = generate(sp);
        assert(p.modules[1].typeId == "synth.spectravoice" && p.modules[2].typeId == "synth.analog_gen");
        assert(p.wires[0].srcPort == audioOutputPort(ModuleRegistry.findByTypeId("synth.spectravoice")));

        SkeletonSpec none;
        none.bass = InstrumentChoice.ofType("synth.sampler");
        assert(validateSpec(none, err));
        string longTitle;
        longTitle.length = 70_000;
        none.title = longTitle;
        assert(!validateSpec(none, err) && err == "The title is too long");
    }

    unittest {
        SkeletonSpec sp = specOf("I vi ii V7");
        LoadedProject p = generate(sp);
        float renderWith(bool muteBass, bool mutePiano) {
            LoadedProject q = p;
            q.clips = p.clips.dup;
            q.clips[0].mute = muteBass;
            q.clips[1].mute = mutePiano;
            StudioSession s = new StudioSession();
            assert(s.initialize(44_100.0f));
            scope (exit) s.shutdown();
            string err;
            assert(s.openProjectFromMemory(q, err), err);
            assert(s.document().loopEndLine == 64 && s.timeSignatureNumerator() == 4);
            s.engine().reset();
            s.engine().setTempo(q.bpm, q.ticksPerLine);
            s.engine().seekLine(0);
            s.engine().setPlaying(true);
            OwnedBuffer!float l;
            OwnedBuffer!float r;
            assert(s.engine().renderOfflineToBuffer(22_050, 64, l, r));
            return peakOf(l[], r[]);
        }
        immutable float both = renderWith(false, false);
        immutable float bassOnly = renderWith(false, true);
        immutable float pianoOnly = renderWith(true, false);
        immutable float neither = renderWith(true, true);
        assert(bassOnly > 0.01f && pianoOnly > 0.01f && both > 0.01f && both < 1.0f);
        assert(neither < 1e-4f);
    }
}
