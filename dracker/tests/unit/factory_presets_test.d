/**
 * File:         tests/unit/factory_presets_test.d
 * Module:       tests.unit.factory_presets_test
 * Phase:        Instrument library — T46 (bundled presets: definitions, files, and sound check)
 *
 * Purpose:
 *   Verifies app.factory_presets: the list (twelve instruments, four effects, unique names, standard groups), every
 *   parameter name and range, that the checked-in files in resources/presets are byte-identical to what the table
 *   produces (and that the folder holds nothing else), that the files load through InstrumentLibrary with the
 *   right grouping, that the skeleton generator's defaults are the Electric Bass and Electric Piano presets, and
 *   that every preview project renders sound without reaching full scale (effects: both the dry and the wet half).
 *
 * Real-Time & Safety Contract:
 *   Off-RT; renders offline through StudioSession. Reads resources/presets relative to the package folder, which
 *   is the working directory of dub test.
 *
 * Dependencies:
 *   Internal: app.{factory_presets,instrument_library,session,skeleton_gen}, foundation.memory, graph.registry,
 *             io.project_format
 *   External: std.file, std.math, std.path
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T36, T37, T46)
 */
module tests.unit.factory_presets_test;

version (unittest) {
    import std.file : dirEntries, exists, read, SpanMode;
    import std.format : format;
    import std.math : cos, fabs, PI, sin, sqrt;
    import std.path : buildPath;

    import app.factory_presets;
    import app.instrument_library : InstrumentLibrary, LIBRARY_GROUPS, PresetOrigin;
    import app.session : StudioSession;
    import app.skeleton_gen : defaultBassModule, defaultPianoModule;
    import foundation.memory : OwnedBuffer;
    import graph.module_api : ModuleDescriptor;
    import graph.port : PortDirection;
    import graph.registry : ModuleRegistry;
    import io.project_format : LoadedPreset, LoadedProject, loadPreset, SavedModule, SavedPattern, SavedWire,
        validateModuleForSave;
    import sequencer.note : NoteCell;
    import sequencer.timeline : TimelineClip;

    private enum string PRESET_DIR = "resources/presets";

    unittest {
        assert(FACTORY_PRESETS.length == 16);
        size_t instruments = 0;
        foreach (i, ref p; FACTORY_PRESETS) {
            foreach (ref q; FACTORY_PRESETS[0 .. i]) {
                assert(q.name != p.name, p.name);
            }
            bool groupOk = false;
            foreach (g; LIBRARY_GROUPS) {
                groupOk = groupOk || g == p.group;
            }
            assert(groupOk, p.name);
            assert(isInstrument(p) == (p.group != "Effects"), p.name);
            instruments += isInstrument(p) ? 1 : 0;
            const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(p.typeId);
            assert(d !is null, p.name);
            SavedModule m;
            string err;
            assert(factoryModule(p, 5, m, err), err);
            assert(m.id == 5 && m.name == p.name && m.typeId == p.typeId && m.paramValues.length == d.params.length);
            foreach (k, ref dp; d.params) {
                assert(m.paramValues[k] >= dp.minVal && m.paramValues[k] <= dp.maxVal, p.name ~ " " ~ dp.name);
            }
            assert(validateModuleForSave(m, 0, err), err);
            foreach (j, ref s; p.params) {
                foreach (ref t; p.params[0 .. j]) {
                    assert(t.name != s.name, p.name ~ " sets " ~ s.name ~ " twice");
                }
            }
            assert(findFactoryPreset(p.name) is &p);
        }
        assert(instruments == 12 && findFactoryPreset("No such preset") is null);

        FactoryPreset bad = FactoryPreset("Bad", "Bass", "synth.analog_gen", [ParamSetting("No Such Knob", 1.0f)]);
        SavedModule m;
        string err;
        assert(!factoryModule(bad, 1, m, err) && err == "Bad: Analog Generator has no parameter \"No Such Knob\"");
        bad = FactoryPreset("Bad", "Bass", "synth.nope", null);
        assert(!factoryModule(bad, 1, m, err) && err.length > 0);

        SavedModule eb, ep;
        assert(factoryModule(*findFactoryPreset("Electric Bass"), 2, eb, err));
        assert(factoryModule(*findFactoryPreset("Electric Piano"), 3, ep, err));
        assert(defaultBassModule(2).paramValues == eb.paramValues && defaultBassModule(2).name == "Bass");
        assert(defaultPianoModule(3).paramValues == ep.paramValues && defaultPianoModule(3).name == "Piano");
        assert(defaultBassModule(2).typeId == "synth.analog_gen" && defaultPianoModule(3).typeId == "synth.fm_synth");
    }

    unittest {
        assert(exists(PRESET_DIR), "run: dracker --write-factory-presets=resources/presets");
        string err;
        foreach (ref p; FACTORY_PRESETS) {
            immutable string path = buildPath(PRESET_DIR, factoryPresetRelativePath(p));
            assert(exists(path), path ~ " is missing; run: dracker --write-factory-presets=resources/presets");
            ubyte[] expected;
            assert(factoryPresetBytes(p, expected, err), err);
            const(ubyte)[] onDisk = cast(const(ubyte)[]) read(path);
            assert(onDisk == expected, path ~ " differs from app.factory_presets; run: dracker --write-factory-presets=resources/presets");
            LoadedPreset loaded;
            assert(loadPreset(onDisk, loaded, err), err);
            assert(loaded.presetName == p.name && loaded.mod.typeId == p.typeId && loaded.mod.name == p.name);
        }
        size_t files = 0;
        foreach (entry; dirEntries(PRESET_DIR, SpanMode.depth)) {
            if (!entry.isDir && entry.name.length > 5 && entry.name[$ - 5 .. $] == ".msym") {
                files++;
            }
        }
        assert(files == FACTORY_PRESETS.length);

        auto lib = new InstrumentLibrary([PRESET_DIR], "");
        assert(lib.entries().length == 16 && lib.problems().length == 0);
        assert(lib.groups() == ["Bass", "Keys", "Pads & Leads", "Drums", "Effects"]);
        foreach (ref e; lib.entries()) {
            immutable(FactoryPreset)* p = findFactoryPreset(e.name);
            assert(p !is null && p.group == e.group && e.origin == PresetOrigin.bundled && e.playable == isInstrument(*p));
        }
    }

    private float peakOf(const(float)[] l, const(float)[] r, size_t from, size_t to) {
        float p = 0.0f;
        foreach (i; from .. to < l.length ? to : l.length) {
            p = fabs(l[i]) > p ? fabs(l[i]) : p;
            p = fabs(r[i]) > p ? fabs(r[i]) : p;
        }
        return p;
    }

    private double rmsOf(const(float)[] l, const(float)[] r, size_t from, size_t to) {
        immutable size_t hi = to < l.length ? to : l.length;
        if (hi <= from) {
            return 0.0;
        }
        double acc = 0.0;
        foreach (i; from .. hi) {
            acc += cast(double) l[i] * l[i] + cast(double) r[i] * r[i];
        }
        return sqrt(acc / (2.0 * cast(double)(hi - from)));
    }

    private double tonePower(const(float)[] buf, size_t from, size_t to, double hz, double sampleRate) {
        double re = 0.0;
        double im = 0.0;
        immutable double w = 2.0 * PI * hz / sampleRate;
        foreach (i; from .. to) {
            immutable double x = cast(double) buf[i];
            immutable double ang = w * cast(double)(i - from);
            re += x * cos(ang);
            im += x * sin(ang);
        }
        return re * re + im * im;
    }

    private void renderPreview(const ref FactoryPreset p, bool wet, out OwnedBuffer!float l, out OwnedBuffer!float r) {
        LoadedProject proj;
        string err;
        assert(factoryPreviewProject(p, proj, err, wet), err);
        immutable uint bars = factoryPreviewBars(p);
        assert(bars == 4 && proj.patterns[0].lines == bars * 16);
        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        assert(s.openProjectFromMemory(proj, err), p.name ~ ": " ~ err);
        s.engine().reset();
        s.engine().setTempo(proj.bpm, proj.ticksPerLine);
        s.engine().seekLine(0);
        s.engine().setPlaying(true);
        immutable size_t barFrames = 88_200;
        assert(s.engine().renderOfflineToBuffer(bars * barFrames + 44_160, 64, l, r));
    }

    unittest {
        immutable size_t barFrames = 88_200;
        foreach (ref p; FACTORY_PRESETS) {
            OwnedBuffer!float l;
            OwnedBuffer!float r;
            renderPreview(p, true, l, r);
            immutable float whole = peakOf(l[], r[], 0, l.length);
            assert(whole > 0.02f, p.name ~ " is silent");
            assert(whole < 0.98f, p.name ~ " is too loud");
            if (isInstrument(p)) {
                foreach (b; 0 .. 4) {
                    assert(peakOf(l[], r[], b * barFrames, (b + 1) * barFrames) > 0.02f,
                        p.name ~ " has a silent bar");
                }
            } else {
                OwnedBuffer!float dl;
                OwnedBuffer!float dr;
                renderPreview(p, false, dl, dr);
                immutable float dryPeak = peakOf(dl[], dr[], 0, dl.length);
                assert(dryPeak > 0.02f && dryPeak < 0.98f, p.name ~ " dry render out of range");

                immutable double dryRms = rmsOf(dl[], dr[], 0, 4 * barFrames);
                double diffSq = 0.0;
                foreach (i; 0 .. 4 * barFrames) {
                    immutable double dL = cast(double) l[i] - cast(double) dl[i];
                    immutable double dR = cast(double) r[i] - cast(double) dr[i];
                    diffSq += dL * dL + dR * dR;
                }
                immutable double diffRms = sqrt(diffSq / (2.0 * cast(double)(4 * barFrames)));
                assert(diffRms >= 0.25 * dryRms, p.name ~ " wet does not differ enough from dry");

                if (p.name == "Room Reverb" || p.name == "Tempo Delay") {
                    immutable size_t restFrom = 33_075;
                    immutable size_t restTo = 37_485;
                    immutable double dryRest = rmsOf(dl[], dr[], restFrom, restTo);
                    immutable double wetRest = rmsOf(l[], r[], restFrom, restTo);
                    assert(wetRest > 0.004, format("%s rest RMS too low: wet=%.6f dry=%.6f", p.name, wetRest, dryRest));
                    assert(wetRest > dryRest * 2.0, format("%s tail not prominent: wet=%.6f dry=%.6f", p.name, wetRest, dryRest));
                } else if (p.name == "Bus Compressor") {
                    immutable double dryLoud = rmsOf(dl[], dr[], barFrames, barFrames + 4410);
                    immutable double dryQuiet = rmsOf(dl[], dr[], barFrames + 22_050, barFrames + 26_460);
                    immutable double wetLoud = rmsOf(l[], r[], barFrames, barFrames + 4410);
                    immutable double wetQuiet = rmsOf(l[], r[], barFrames + 22_050, barFrames + 26_460);
                    assert(dryLoud > dryQuiet * 2.0, format("Bus Comp dry diff too small: loud=%.6f quiet=%.6f", dryLoud, dryQuiet));
                    assert((wetLoud / wetQuiet) < (dryLoud / dryQuiet) * 0.85,
                        format("Bus Comp did not reduce diff: dry=%.3f wet=%.3f", dryLoud / dryQuiet, wetLoud / wetQuiet));
                } else if (p.name == "Warm Overdrive") {
                    enum double f0 = 65.40639132514966;
                    immutable size_t s0 = 2205;
                    immutable size_t s1 = 10_000;
                    immutable double dryFund = tonePower(dl[], s0, s1, f0, 44_100.0);
                    immutable double wetFund = tonePower(l[], s0, s1, f0, 44_100.0);
                    double dryHarm = 0.0;
                    double wetHarm = 0.0;
                    foreach (h; 15 .. 50) {
                        dryHarm += tonePower(dl[], s0, s1, f0 * h, 44_100.0);
                        wetHarm += tonePower(l[], s0, s1, f0 * h, 44_100.0);
                    }
                    assert(dryFund > 0.0 && wetFund > 0.0);
                    assert(wetHarm > dryHarm * 3.0 && (wetHarm / wetFund) > (dryHarm / dryFund) * 1.2,
                        format("Warm Overdrive harm ratio: dry=%.5f wet=%.5f (abs dry=%.2f wet=%.2f)",
                            dryHarm / dryFund, wetHarm / wetFund, dryHarm, wetHarm));
                }
            }
        }
    }

    private void renderSingleKeysNote(const ref FactoryPreset p, uint noteOffLine, size_t totalFrames,
            out OwnedBuffer!float l, out OwnedBuffer!float r) {
        LoadedProject proj;
        proj.title = "Keys check: " ~ p.name;
        proj.bpm = FACTORY_PREVIEW_BPM;
        proj.ticksPerLine = 6;
        SavedModule master;
        master.id = 1;
        master.typeId = "core.output";
        master.name = "Master Output";
        master.paramValues = [1.0f, 1.0f];
        SavedModule keys;
        string err;
        assert(factoryModule(p, 2, keys, err), err);
        proj.modules = [master, keys];
        const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(keys.typeId);
        ptrdiff_t outPort = -1;
        foreach (idx, ref port; d.ports) {
            if (port.dir == PortDirection.output) {
                outPort = cast(ptrdiff_t) idx;
                break;
            }
        }
        assert(outPort >= 0);
        proj.wires = [SavedWire(2, cast(ushort) outPort, 1, 0, 0.5f)];

        SavedPattern pat;
        pat.patternId = 1;
        pat.tracks = 1;
        pat.lines = 32;
        pat.name = "Hold";
        pat.cells = new NoteCell[32];
        pat.cells[0] = NoteCell.makeNote(60, 0.85f, 2);
        if (noteOffLine > 0 && noteOffLine < pat.lines) {
            pat.cells[noteOffLine] = NoteCell.makeNoteOff(2);
        }
        proj.patterns = [pat];
        proj.clips = [TimelineClip(1, 1, 0, 0, 32, 0, 0, false, false, false)];

        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        assert(s.openProjectFromMemory(proj, err), p.name ~ ": " ~ err);
        s.engine().reset();
        s.engine().setTempo(proj.bpm, proj.ticksPerLine);
        s.engine().seekLine(0);
        s.engine().setPlaying(true);
        assert(s.engine().renderOfflineToBuffer(totalFrames, 64, l, r));
    }

    private float presetParam(const ref FactoryPreset p, string paramName) {
        foreach (ref s; p.params) {
            if (s.name == paramName) {
                return s.value;
            }
        }
        assert(false, p.name ~ " missing " ~ paramName);
    }

    unittest {
        foreach (ref p; FACTORY_PRESETS) {
            if (p.group != "Keys") {
                continue;
            }

            OwnedBuffer!float holdL;
            OwnedBuffer!float holdR;
            renderSingleKeysNote(p, 0, 88_200, holdL, holdR);
            immutable double firstRms = rmsOf(holdL[], holdR[], 0, 4410);
            immutable double lastRms = rmsOf(holdL[], holdR[], 66_150, 88_200);
            assert(firstRms > 0.01, p.name ~ " held first 0.1 s silent");
            if (p.name == "Organ") {
                assert(lastRms > firstRms * 0.85 && lastRms < firstRms * 1.15,
                    format("Organ hold should sustain: first=%.5f last=%.5f", firstRms, lastRms));
            } else {
                assert(lastRms < firstRms * 0.1,
                    format("%s hold did not die away below 1/10: first=%.5f last=%.5f", p.name, firstRms, lastRms));
            }

            immutable uint noteOffLine = 2;
            immutable size_t noteOffFrame = 11_025;
            immutable float releaseMs = presetParam(p, "Release");
            immutable size_t releaseFrames = cast(size_t)(releaseMs * 44.1f);
            immutable size_t totalFrames = noteOffFrame + releaseFrames + 22_050;
            OwnedBuffer!float relL;
            OwnedBuffer!float relR;
            renderSingleKeysNote(p, noteOffLine, totalFrames, relL, relR);

            immutable double preOffRms = rmsOf(relL[], relR[], 4410, noteOffFrame);
            assert(preOffRms > 0.01, p.name ~ " silent before note-off");
            immutable size_t tailFrom = noteOffFrame + (releaseFrames * 8) / 10;
            immutable size_t tailTo = noteOffFrame + releaseFrames;
            immutable double nearEndRms = rmsOf(relL[], relR[], tailFrom, tailTo);
            assert(nearEndRms < preOffRms * 0.1,
                format("%s did not drop below 1/10 within release: pre=%.5f nearEnd=%.5f",
                    p.name, preOffRms, nearEndRms));

            immutable float postReleasePeak = peakOf(relL[], relR[], noteOffFrame + releaseFrames + 128, totalFrames);
            assert(postReleasePeak == 0.0f,
                format("%s non-zero after release: peak=%.8f", p.name, postReleasePeak));
        }
    }
}
