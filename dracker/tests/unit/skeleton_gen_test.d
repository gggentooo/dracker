/**
 * File:         tests/unit/skeleton_gen_test.d
 * Module:       tests.unit.skeleton_gen_test
 * Phase:        Skeleton project generator — T13 (instrument choices and default sounds)
 *
 * Purpose:
 *   Verifies app.skeleton_gen instrument handling: the dropdown choice list and labels, that every choice
 *   resolves for both roles to a valid module of a registered type, the default bass and piano parameter sets
 *   (inside each parameter's range), refusal of unlisted types, non-playable presets, mismatched presets and id 0,
 *   port lookup helpers, and that every choice renders a non-silent note through a real StudioSession.
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
}
