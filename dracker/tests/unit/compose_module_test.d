/**
 * File:         tests/unit/compose_module_test.d
 * Module:       tests.unit.compose_module_test
 * Phase:        Composition helper (dracker-compose) — T74 (Module writer)
 *
 * Purpose:
 *   Verifies compose.module_writer. Starting a writer from a type (every one of the 39 registered types, by
 *   type id and by display name), from a descriptor, from a bundled or user preset by name, from a preset file
 *   and from preset bytes. Names matched without regard to case or spaces. Values: accepted numbers in every
 *   form the grammar admits, every refusal (not a number, not finite, outside the range, not a whole number,
 *   unknown option, unknown parameter, unknown module type, unknown or ambiguous preset, unreadable preset, a
 *   preset that does not match its type, an invalid name) with the reason and the nearest valid choice, and the
 *   writer staying unchanged after a refusal. Option names for a named discrete parameter, with spaces and a
 *   negative first value. Reading values back as numbers and as text that sets the same value again, including
 *   the shortest decimal that round-trips. Every registered type round-trips through a .msym file, loads in the
 *   app's own loader (loadPreset and StudioSession), and extra data of a preset is kept. A sweep of random
 *   texts that must never throw.
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Reads resources/presets relative to the package folder, which is the working directory of dub
 *   test. Writes user presets into a folder of the temporary directory and removes it again. Loads presets
 *   into a StudioSession that never starts audio.
 *
 * Dependencies:
 *   Internal: app.factory_presets, app.instrument_library, app.session, compose.module_writer, graph.module_api,
 *             graph.registry, io.project_format
 *   External: std.algorithm, std.conv, std.file, std.path
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T70, T74, T91, T92), source/compose/module_writer.d
 */
module tests.unit.compose_module_test;

version (unittest) {
    import std.algorithm : endsWith, startsWith;
    import std.conv : to;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    import app.factory_presets : FACTORY_PRESETS, factoryModule, findFactoryPreset;
    import app.instrument_library : InstrumentLibrary, bundledPresetDirectories;
    import app.session : StudioSession;
    import compose.module_writer;
    import graph.module_api : ModuleDescriptor, ParamDescriptor, ParamScale;
    import graph.registry : ModuleRegistry;
    import io.project_format : LoadedPreset, LoadedProject, SavedModule, loadPreset, loadPresetFile,
        serializePreset, serializeProject, validateModuleForSave;

    private immutable float[9] ANALOG_DEFAULTS =
        [2.0f, 1.0f, 0.15f, 4000.0f, 0.2f, 0.005f, 0.2f, 0.7f, 0.25f];

    /**
     * The descriptor of a module type.
     *
     * Params:
     *   typeId = The type id.
     *
     * Returns:
     *   Pointer to the registered descriptor.
     */
    private const(ModuleDescriptor)* descriptorOf(string typeId) {
        const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(typeId);
        assert(d !is null, typeId);
        return d;
    }

    /**
     * A parameter of a module type.
     *
     * Params:
     *   typeId = The type id.
     *   index = The parameter index.
     *
     * Returns:
     *   A copy of the parameter descriptor.
     */
    private ParamDescriptor paramOf(string typeId, size_t index) {
        return descriptorOf(typeId).params[index];
    }

    /**
     * A test parameter descriptor.
     *
     * Params:
     *   index = Parameter index.
     *   name = Display name.
     *   lo = Lowest value.
     *   hi = Highest value.
     *   def = Default value.
     *   scale = Parameter scale.
     *   options = Names of the values of a discrete parameter.
     *
     * Returns:
     *   The descriptor.
     */
    private ParamDescriptor pd(size_t index, string name, float lo, float hi, float def,
            ParamScale scale = ParamScale.linear, immutable(string)[] options = null) {
        return ParamDescriptor(cast(uint) index, "field" ~ to!string(index), name, lo, hi, def, "", scale,
            options);
    }

    /**
     * A writer that must have started from a module type.
     *
     * Params:
     *   typeText = The type as a script gives it.
     *
     * Returns:
     *   The writer.
     */
    private ModuleWriter writerOf(string typeText) {
        ModuleWriterResult r = ModuleWriter.fromType(typeText);
        assert(r.ok, typeText ~ ": " ~ r.problem.text());
        return r.writer;
    }

    /**
     * A text made of one repeated character.
     *
     * Params:
     *   c = The character.
     *   count = How often to repeat it.
     *
     * Returns:
     *   The text.
     */
    private string times(char c, size_t count) {
        char[] buffer = new char[count];
        buffer[] = c;
        return buffer.idup;
    }

    /**
     * A name written without regard to case or spaces: lower case, no spaces.
     *
     * Params:
     *   name = The name.
     *
     * Returns:
     *   The squashed name.
     */
    private string squashed(string name) {
        string result;
        foreach (c; name) {
            if (c != ' ') {
                result ~= cast(char) (c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c);
            }
        }
        return result;
    }

    /**
     * The next number of a small deterministic generator.
     *
     * Params:
     *   state = The generator state; advanced by the call.
     *
     * Returns:
     *   The next number.
     */
    private uint next(ref uint state) @nogc nothrow {
        state = state * 1103515245u + 12345u;
        return state;
    }

    unittest {
        ModuleWriterResult r = ModuleWriter.fromType("synth.analog_gen");
        assert(r.ok, r.problem.text());
        assert(r.writer.loaded());
        assert(r.writer.typeId == "synth.analog_gen");
        assert(r.writer.name == "Analog Generator");
        assert(r.writer.paramCount == 9);
        assert(r.writer.paramValues == ANALOG_DEFAULTS);
        assert(r.writer.descriptor.typeId == "synth.analog_gen");
        assert(r.writer.savedModule().id == PRESET_MODULE_ID && PRESET_MODULE_ID == 1);
        assert(r.writer.savedModule(7).id == 7);
        assert(r.writer.savedModule().typeId == "synth.analog_gen");
        assert(r.writer.loadedPreset().presetName == "Analog Generator");
        assert(r.writer.loadedPreset().mod.paramValues == ANALOG_DEFAULTS);
        assert(r.problem.kind == ModuleProblemKind.notLoaded && r.problem.reason == "");
    }

    unittest {
        foreach (text; ["Analog Generator", "analoggenerator", "  ANALOG   generator ", "synth.analog_gen",
                " SYNTH.ANALOG_GEN ", "Synth.Analog_Gen"]) {
            ModuleWriterResult r = ModuleWriter.fromType(text);
            assert(r.ok, text);
            assert(r.writer.typeId == "synth.analog_gen", text);
        }
        assert(writerOf("3-Band EQ").typeId == "fx.eq3");
        assert(writerOf("3-BandEQ").typeId == "fx.eq3");
        assert(writerOf("3-bandeQ").typeId == "fx.eq3");
        ModuleWriterResult droppedHyphen = ModuleWriter.fromType("3 Band EQ");
        assert(!droppedHyphen.ok && droppedHyphen.problem.suggestion == "3-Band EQ");
        assert(writerOf(droppedHyphen.problem.suggestion).typeId == "fx.eq3");
        assert(ModuleWriter.fromType("3bandeq").problem.suggestion == "3-Band EQ");
        assert(writerOf("fx.eq3").name == "3-Band EQ");
        ModuleWriterResult misspelled = ModuleWriter.fromType("Analog Genrator");
        assert(!misspelled.ok && misspelled.problem.suggestion == "Analog Generator");
        assert(writerOf(misspelled.problem.suggestion).typeId == "synth.analog_gen");

        ModuleWriterResult typo = ModuleWriter.fromType("synth.analog_genx");
        assert(!typo.ok && !typo.writer.loaded());
        assert(typo.problem.kind == ModuleProblemKind.unknownModuleType);
        assert(typo.problem.subject == "synth.analog_genx");
        assert(typo.problem.suggestion == "synth.analog_gen");
        assert(typo.problem.text == "unknown module type 'synth.analog_genx'; did you mean 'synth.analog_gen'?");
        assert(writerOf(typo.problem.suggestion).typeId == "synth.analog_gen");

        ModuleWriterResult far = ModuleWriter.fromType("zzz");
        assert(!far.ok && far.problem.suggestion == "" && far.problem.reason == "unknown module type 'zzz'");
        ModuleWriterResult empty = ModuleWriter.fromType("");
        assert(!empty.ok && empty.problem.suggestion == "" && empty.problem.reason == "unknown module type ''");
        ModuleWriterResult revrb = ModuleWriter.fromType("Revrb");
        assert(!revrb.ok && revrb.problem.suggestion == "Reverb", revrb.problem.suggestion);
        ModuleWriterResult blank = ModuleWriter.fromType("   ");
        assert(!blank.ok && blank.problem.subject == "");
    }

    unittest {
        immutable(ModuleDescriptor)[] descs = ModuleRegistry.descriptors();
        assert(descs.length == 39);
        foreach (i; 0 .. descs.length) {
            ModuleWriterResult byId = ModuleWriter.fromType(descs[i].typeId);
            ModuleWriterResult byName = ModuleWriter.fromType(descs[i].displayName);
            assert(byId.ok, descs[i].typeId);
            assert(byName.ok, descs[i].displayName ~ ": " ~ byName.problem.text());
            assert(byId.writer.typeId == descs[i].typeId && byName.writer.typeId == descs[i].typeId);
            assert(byId.writer.name == descs[i].displayName);
            assert(byId.writer.descriptor is &descs[i]);
            assert(byId.writer.paramCount == descs[i].params.length);
            foreach (k; 0 .. descs[i].params.length) {
                assert(byId.writer.paramValues[k] == descs[i].params[k].defaultVal,
                    descs[i].typeId ~ " " ~ descs[i].params[k].name);
            }
            SavedModule fresh = byId.writer.savedModule();
            string err;
            assert(validateModuleForSave(fresh, 0, err), err);
        }
        foreach (j; 0 .. descs.length) {
            ModuleWriter w = ModuleWriter.fromType(descs[j].typeId).writer;
            foreach (k; 0 .. descs[j].params.length) {
                immutable ModuleValueResult v = w.valueOf(squashed(descs[j].params[k].name));
                assert(v.ok, descs[j].typeId ~ ": " ~ descs[j].params[k].name ~ ": " ~ v.problem.text());
                assert(v.value == w.paramValues()[k]);
                assert(w.textOf(descs[j].params[k].name).ok);
            }
        }
    }

    unittest {
        ModuleWriter w = writerOf("synth.analog_gen");
        foreach (n; ["Cutoff", "cutoff", "CUT OFF", " cutOff ", "C U T O F F"]) {
            immutable ModuleValueResult v = w.valueOf(n);
            assert(v.ok && v.value == 4000.0f, n);
        }
        ModuleWriter fm = writerOf("synth.fm_synth");
        assert(fm.valueOf("Op1 Level").value == 1.0f);
        assert(fm.valueOf("Op1Level").value == 1.0f);
        assert(fm.valueOf("op 1 level").value == 1.0f);
        assert(fm.valueOf("Op5 Level").value == 0.25f);
        assert(fm.valueOf("OP5LEVEL").value == 0.25f);

        immutable ModuleValueResult cut = w.valueOf("cutof");
        assert(!cut.ok && cut.problem.kind == ModuleProblemKind.unknownParameter);
        assert(cut.problem.subject == "cutof" && cut.problem.suggestion == "Cutoff");
        assert(cut.problem.text == "unknown parameter 'cutof'; did you mean 'Cutoff'?");
        immutable ModuleEditResult wave = w.setParamText("Wave", "Sine");
        assert(!wave.ok && wave.problem.kind == ModuleProblemKind.unknownParameter);
        assert(wave.problem.suggestion == "Waveform");
        assert(w.valueOf("Waveform").value == 2.0f);
        immutable ModuleValueResult far = w.valueOf("zzzzzzzzzz");
        assert(!far.ok && far.problem.suggestion == "");
        immutable ModuleTextResult blank = w.textOf("   ");
        assert(!blank.ok && blank.problem.subject == "" && blank.problem.suggestion == "");

        ModuleDescriptor d;
        d.typeId = "test.ambiguous";
        d.displayName = "Ambiguous";
        d.params = [pd(0, "Pan A", 0.0f, 1.0f, 0.0f), pd(1, "PANA", 0.0f, 1.0f, 1.0f)];
        ModuleWriterResult made = ModuleWriter.fromDescriptor(&d, "Ambiguous");
        assert(made.ok && made.writer.typeId == "test.ambiguous" && made.writer.paramValues == [0.0f, 1.0f]);
        immutable ModuleValueResult both = made.writer.valueOf("pana");
        assert(!both.ok && both.problem.kind == ModuleProblemKind.ambiguousParameter);
        assert(both.problem.suggestion == "Pan A");
        assert(both.problem.text == "'pana' matches 2 parameters of 'Ambiguous'; did you mean 'Pan A'?");
        assert(made.writer.valueOf("PANA").value == 1.0f);
        assert(made.writer.valueOf("Pan A").value == 0.0f);
        immutable ModuleEditResult blocked = made.writer.setParamText("pan a", "0.5");
        assert(!blocked.ok && blocked.problem.kind == ModuleProblemKind.ambiguousParameter);
        assert(made.writer.paramValues == [0.0f, 1.0f]);
        ModuleWriterResult none = ModuleWriter.fromDescriptor(null, "Nothing");
        assert(!none.ok && none.problem.kind == ModuleProblemKind.notLoaded);
    }

    unittest {
        immutable ParamDescriptor wave = paramOf("synth.analog_gen", 0);
        immutable ParamDescriptor unison = paramOf("synth.analog_gen", 1);
        immutable ParamDescriptor detune = paramOf("synth.analog_gen", 2);
        immutable ParamDescriptor cutoff = paramOf("synth.analog_gen", 3);
        immutable ParamDescriptor resonance = paramOf("synth.analog_gen", 4);
        immutable ParamDescriptor attack = paramOf("synth.analog_gen", 5);
        assert(wave.name == "Waveform" && wave.minVal == 0.0f && wave.maxVal == 5.0f && wave.defaultVal == 2.0f);
        assert(wave.scale == ParamScale.discrete);
        assert(wave.options == ["Sine", "Triangle", "Saw", "Square", "Noise", "Drawn"]);
        assert(unison.options.length == 0);

        assert(parameterRangeText(wave) == "a whole number from 0 to 5, or one of its names");
        assert(parameterRangeText(unison) == "a whole number from 1 to 4");
        assert(parameterRangeText(cutoff) == "a number from 40 to 18000 Hz");
        assert(parameterRangeText(resonance) == "a number from 0 to 0.95");
        assert(parameterRangeText(attack) == "a number from 0.001 to 5 s");
        assert(parameterRangeText(paramOf("fx.filter_pro", 4)) == "a number from -24 to 24 dB");
        assert(parameterRangeText(paramOf("fx.filter_pro", 3)) == "a number from 0.05 to 20 Q");

        assert(parameterValueText(wave, 2.0f) == "Saw");
        assert(parameterValueText(wave, 5.0f) == "Drawn");
        assert(parameterValueText(wave, 9.0f) == "9");
        assert(parameterValueText(unison, 3.0f) == "3");
        assert(parameterValueText(cutoff, 4000.0f) == "4000");
        assert(parameterValueText(detune, 0.15f) == "0.15");
        assert(parameterValueText(detune, 0.0f) == "0");
        assert(parameterValueText(detune, -0.0f) == "-0");
        assert(parameterValueText(detune, 1.0f / 3.0f) == "0.33333334");
        assert(parameterValueText(detune, 12.3456789f) == "12.345679");
        assert(parameterValueText(detune, 1.0e-7f) == "1e-07");
        assert(parameterValueText(detune, float.nan) == "nan");
        assert(parameterValueText(detune, float.infinity) == "inf");
        assert(parameterValueText(detune, -float.infinity) == "-inf");
    }

    unittest {
        ModuleWriter w = writerOf("synth.analog_gen");
        assert(w.setParamText("Cutoff", "900").ok);
        assert(w.valueOf("Cutoff").value == 900.0f);
        assert(w.textOf("Cutoff").text == "900");
        assert(w.setParamText("Cutoff", " 900 ").ok);
        assert(w.setParamText("Cutoff", "+900").ok && w.valueOf("Cutoff").value == 900.0f);
        assert(w.setParamText("Cutoff", "4e3").ok && w.valueOf("Cutoff").value == 4000.0f);
        assert(w.setParamText("Cutoff", "1.5e4").ok && w.valueOf("Cutoff").value == 15000.0f);
        assert(w.textOf("Cutoff").text == "15000");
        assert(w.setParamText("Cutoff", "40.").ok && w.valueOf("Cutoff").value == 40.0f);
        assert(w.setParamText("Resonance", ".5").ok && w.valueOf("Resonance").value == 0.5f);
        assert(w.setParamText("Cutoff", "40").ok && w.setParamText("Cutoff", "18000").ok);
        assert(w.setParamText("Cutoff", "900").ok);

        immutable ModuleEditResult high = w.setParamText("Cutoff", "18001");
        assert(!high.ok && high.problem.kind == ModuleProblemKind.outOfRange);
        assert(high.problem.subject == "18001" && high.problem.suggestion == "18000");
        assert(high.problem.text
            == "'18001' is outside the range of 'Cutoff' (a number from 40 to 18000 Hz); the nearest valid value is 18000");
        immutable ModuleEditResult low = w.setParamText("Cutoff", "39.5");
        assert(!low.ok && low.problem.kind == ModuleProblemKind.outOfRange && low.problem.suggestion == "40");
        immutable ModuleEditResult negative = w.setParamText("Cutoff", "-5");
        assert(!negative.ok && negative.problem.kind == ModuleProblemKind.outOfRange
            && negative.problem.suggestion == "40");
        immutable ModuleEditResult word = w.setParamText("Cutoff", "hot");
        assert(!word.ok && word.problem.kind == ModuleProblemKind.notANumber && word.problem.suggestion == "");
        assert(word.problem.text
            == "the value of 'Cutoff' must be a number from 40 to 18000 Hz; 'hot' is not a number");
        immutable ModuleEditResult nothing = w.setParamText("Cutoff", "");
        assert(!nothing.ok && nothing.problem.kind == ModuleProblemKind.notANumber);
        assert(nothing.problem.subject == "" && nothing.problem.suggestion == "");
        assert(nothing.problem.text == "a value is needed for 'Cutoff'");
        assert(w.setParamText("Cutoff", " \t ").problem.text == "a value is needed for 'Cutoff'");
        foreach (bad; ["nan", "inf", "-inf", "NaN", "0x10", "1f", "1,5", "1_000", "1 000", "4000Hz", "+", "-",
                ".", "e5", "1e", "1e5x", "--5", "1.2.3", "5.f", "+.", "1e+", "0x1p3"]) {
            immutable ModuleEditResult r = w.setParamText("Cutoff", bad);
            assert(!r.ok && r.problem.kind == ModuleProblemKind.notANumber, "'" ~ bad ~ "' " ~ r.problem.text());
            assert(r.problem.reason == "the value of 'Cutoff' must be a number from 40 to 18000 Hz; '" ~ bad
                ~ "' is not a number", r.problem.reason);
        }
        assert(w.valueOf("Cutoff").value == 900.0f);
        assert(w.paramValues == [2.0f, 1.0f, 0.15f, 900.0f, 0.5f, 0.005f, 0.2f, 0.7f, 0.25f]);

        immutable ModuleEditResult tiny = w.setParamText("Attack", "0.0009");
        assert(!tiny.ok && tiny.problem.kind == ModuleProblemKind.outOfRange && tiny.problem.suggestion == "0.001");
        assert(w.setParamText("Attack", "0.001").ok);
        assert(w.textOf("Attack").text == "0.001");
        assert(w.setParamText("Attack", "5").ok && w.textOf("Attack").text == "5");
        assert(w.setParamText("Resonance", "0.95").ok && w.textOf("Resonance").text == "0.95");
        immutable ModuleEditResult sharp = w.setParamText("Resonance", "0.96");
        assert(!sharp.ok && sharp.problem.suggestion == "0.95");

        assert(w.setParamValue("Detune", 1.0f / 3.0f).ok);
        assert(w.textOf("Detune").text == "0.33333334");
        assert(w.setParamText("Detune", w.textOf("Detune").text).ok);
        assert(w.valueOf("Detune").value == 1.0f / 3.0f);

        ModuleWriter fp = writerOf("fx.filter_pro");
        assert(fp.setParamText("Gain", "-6.5").ok && fp.textOf("Gain").text == "-6.5");
        assert(fp.setParamText("Gain", "-24").ok && fp.setParamText("Gain", "24").ok);
        immutable ModuleEditResult below = fp.setParamText("Gain", "-24.5");
        assert(!below.ok && below.problem.suggestion == "-24");
        immutable ModuleEditResult above = fp.setParamText("Gain", "24.5");
        assert(!above.ok && above.problem.suggestion == "24");
    }

    unittest {
        ModuleWriter w = writerOf("synth.analog_gen");
        assert(w.textOf("Waveform").text == "Saw");
        immutable string[8] NAMES = ["Sine", "Triangle", "Saw", "Square", "Noise", "Drawn", "saw", "SAW"];
        immutable float[8] VALUES = [0.0f, 1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 2.0f, 2.0f];
        immutable string[8] CANONICAL = ["Sine", "Triangle", "Saw", "Square", "Noise", "Drawn", "Saw", "Saw"];
        foreach (i; 0 .. NAMES.length) {
            immutable ModuleEditResult r = w.setParamText("waveform", NAMES[i]);
            assert(r.ok, NAMES[i] ~ ": " ~ r.problem.text());
            assert(w.valueOf("WAVE FORM").value == VALUES[i]);
            assert(w.textOf("Waveform").text == CANONICAL[i]);
        }
        assert(w.setParamText("Waveform", "3").ok && w.textOf("Waveform").text == "Square");
        assert(w.setParamText("Waveform", "0").ok && w.textOf("Waveform").text == "Sine");
        assert(w.setParamText("Waveform", "2.0").ok && w.textOf("Waveform").text == "Saw");
        assert(w.setParamText("Waveform", "2e0").ok && w.textOf("Waveform").text == "Saw");

        immutable ModuleEditResult near = w.setParamText("Waveform", "Sawh");
        assert(!near.ok && near.problem.kind == ModuleProblemKind.unknownOption);
        assert(near.problem.subject == "Sawh" && near.problem.suggestion == "Saw");
        assert(near.problem.text == "unknown value 'Sawh' for 'Waveform'; did you mean 'Saw'?");
        immutable ModuleEditResult six = w.setParamText("Waveform", "6");
        assert(!six.ok && six.problem.kind == ModuleProblemKind.outOfRange && six.problem.suggestion == "Drawn");
        assert(six.problem.text
            == "'6' is outside the range of 'Waveform' (a whole number from 0 to 5, or one of its names); the nearest valid value is Drawn");
        immutable ModuleEditResult minus = w.setParamText("Waveform", "-1");
        assert(!minus.ok && minus.problem.suggestion == "Sine");
        immutable ModuleEditResult half = w.setParamText("Waveform", "2.5");
        assert(!half.ok && half.problem.kind == ModuleProblemKind.notAWholeNumber);
        assert(half.problem.subject == "2.5" && half.problem.suggestion == "Square");
        assert(half.problem.text
            == "'2.5' is not a whole number; 'Waveform' takes a whole number from 0 to 5, or one of its names; the nearest valid value is Square");
        immutable ModuleEditResult belowStep = w.setParamText("Waveform", "0.4");
        assert(!belowStep.ok && belowStep.problem.suggestion == "Sine");
        immutable ModuleEditResult pastEnd = w.setParamText("Waveform", "5.6");
        assert(!pastEnd.ok && pastEnd.problem.suggestion == "Drawn");
        immutable ModuleEditResult none = w.setParamText("Waveform", "Pulse");
        assert(!none.ok && none.problem.kind == ModuleProblemKind.unknownOption && none.problem.suggestion == "");
        assert(w.setParamText("Waveform", "").problem.text == "a value is needed for 'Waveform'");
        assert(w.valueOf("Waveform").value == 2.0f);

        assert(w.setParamText("Unison", "2").ok && w.textOf("Unison").text == "2");
        immutable ModuleEditResult word = w.setParamText("Unison", "two");
        assert(!word.ok && word.problem.kind == ModuleProblemKind.notANumber);
        assert(word.problem.text
            == "the value of 'Unison' must be a whole number from 1 to 4; 'two' is not a number");
        immutable ModuleEditResult zero = w.setParamText("Unison", "0");
        assert(!zero.ok && zero.problem.suggestion == "1");
        immutable ModuleEditResult five = w.setParamText("Unison", "5");
        assert(!five.ok && five.problem.suggestion == "4");
        immutable ModuleEditResult frac = w.setParamText("Unison", "1.5");
        assert(!frac.ok && frac.problem.kind == ModuleProblemKind.notAWholeNumber && frac.problem.suggestion == "2");
        assert(w.setParamText("Unison", "").problem.text == "a value is needed for 'Unison'");
        assert(w.valueOf("Unison").value == 2.0f);

        ModuleWriter fp = writerOf("fx.filter_pro");
        assert(fp.setParamText("Mode", "3").ok && fp.textOf("Mode").text == "Notch");
        assert(fp.setParamText("Mode", "7").ok && fp.setParamText("Mode", "0").ok);
        immutable ModuleEditResult filter = fp.setParamText("Mode", "zzz");
        assert(!filter.ok && filter.problem.kind == ModuleProblemKind.unknownOption);
        assert(filter.problem.reason == "unknown value 'zzz' for 'Mode'" && filter.problem.suggestion == "");
        immutable ModuleEditResult shelf = fp.setParamText("Mode", "lowshelf");
        assert(shelf.ok && fp.valueOf("Mode").value == 6.0f && fp.textOf("Mode").text == "Low Shelf");
        immutable ModuleEditResult filterNine = fp.setParamText("Mode", "9");
        assert(!filterNine.ok && filterNine.problem.suggestion == "High Shelf");
        assert(fp.setParamText("Slope", "4").ok && fp.textOf("Slope").text == "4");
    }

    unittest {
        ModuleDescriptor d;
        d.typeId = "test.clipper";
        d.displayName = "Clipper";
        d.params = [pd(0, "Shape", -1.0f, 1.0f, 0.0f, ParamScale.discrete, ["Off", "Soft Clip", "Hard Clip"])];
        ModuleWriter w = ModuleWriter.fromDescriptor(&d, "C").writer;
        assert(w.valueOf("Shape").value == 0.0f && w.textOf("Shape").text == "Soft Clip");
        assert(parameterRangeText(d.params[0]) == "a whole number from -1 to 1, or one of its names");
        immutable string[10] TEXTS =
            ["Off", "Soft Clip", "softclip", "soft  clip", "SOFTCLIP", "Hard Clip", "hardclip", "-1", "0", "1"];
        immutable float[10] VALUES = [-1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 1.0f, -1.0f, 0.0f, 1.0f];
        immutable string[10] CANONICAL =
            ["Off", "Soft Clip", "Soft Clip", "Soft Clip", "Soft Clip", "Hard Clip", "Hard Clip", "Off",
            "Soft Clip", "Hard Clip"];
        foreach (i; 0 .. TEXTS.length) {
            immutable ModuleEditResult r = w.setParamText("shape", TEXTS[i]);
            assert(r.ok, TEXTS[i] ~ ": " ~ r.problem.text());
            assert(w.valueOf("Shape").value == VALUES[i] && w.textOf("Shape").text == CANONICAL[i]);
        }
        immutable ModuleEditResult clip = w.setParamText("Shape", "Clip");
        assert(!clip.ok && clip.problem.kind == ModuleProblemKind.unknownOption);
        assert(clip.problem.suggestion == "Soft Clip");
        immutable ModuleEditResult hard = w.setParamText("Shape", "Hard");
        assert(!hard.ok && hard.problem.suggestion == "Hard Clip");
        immutable ModuleEditResult two = w.setParamText("Shape", "2");
        assert(!two.ok && two.problem.kind == ModuleProblemKind.outOfRange);
        assert(two.problem.suggestion == "Hard Clip");
        immutable ModuleEditResult up = w.setParamText("Shape", "0.5");
        assert(!up.ok && up.problem.kind == ModuleProblemKind.notAWholeNumber);
        assert(up.problem.suggestion == "Hard Clip");
        immutable ModuleEditResult down = w.setParamText("Shape", "-0.5");
        assert(!down.ok && down.problem.suggestion == "Soft Clip");
        assert(w.valueOf("Shape").value == 1.0f);
    }

    unittest {
        ModuleWriter w = writerOf("synth.analog_gen");
        assert(w.setParamValue("Cutoff", 2500.0f).ok && w.valueOf("Cutoff").value == 2500.0f);
        assert(w.setParamValue("cutoff", 1000.0f).ok && w.valueOf("Cutoff").value == 1000.0f);
        immutable ModuleEditResult nanSet = w.setParamValue("Cutoff", float.nan);
        assert(!nanSet.ok && nanSet.problem.kind == ModuleProblemKind.notANumber);
        assert(nanSet.problem.text
            == "the value of 'Cutoff' must be a number from 40 to 18000 Hz; 'nan' is not a finite number");
        immutable ModuleEditResult infSet = w.setParamValue("Cutoff", float.infinity);
        assert(!infSet.ok && infSet.problem.text.endsWith("'inf' is not a finite number"));
        immutable ModuleEditResult high = w.setParamValue("Cutoff", 20000.0f);
        assert(!high.ok && high.problem.kind == ModuleProblemKind.outOfRange);
        assert(high.problem.subject == "20000" && high.problem.suggestion == "18000");
        immutable ModuleEditResult step = w.setParamValue("Waveform", 2.5f);
        assert(!step.ok && step.problem.kind == ModuleProblemKind.notAWholeNumber);
        assert(step.problem.subject == "2.5" && step.problem.suggestion == "Square");
        immutable ModuleEditResult gone = w.setParamValue("Nope", 1.0f);
        assert(!gone.ok && gone.problem.kind == ModuleProblemKind.unknownParameter);
        assert(w.setParamValue("Waveform", 3.0f).ok && w.textOf("Waveform").text == "Square");
        assert(w.setParamValue("Unison", 4.0f).ok && w.setParamValue("Detune", 0.0f).ok);
        assert(w.paramValues == [3.0f, 4.0f, 0.0f, 1000.0f, 0.2f, 0.005f, 0.2f, 0.7f, 0.25f]);
        assert(w.resetToDefaults().ok);
        assert(w.paramValues == ANALOG_DEFAULTS);
    }

    unittest {
        ModuleWriter w = writerOf("synth.analog_gen");
        assert(w.setName("Lead").ok && w.name == "Lead");
        assert(w.loadedPreset().presetName == "Lead");
        assert(w.setName("  Lead  ").ok && w.name == "Lead");
        immutable ModuleEditResult empty = w.setName("");
        assert(!empty.ok && empty.problem.kind == ModuleProblemKind.invalidName && w.name == "Lead");
        assert(empty.problem.text == "a module name cannot be empty");
        assert(!w.setName("   ").ok && w.name == "Lead");
        immutable ModuleEditResult control = w.setName("Lead\n2");
        assert(!control.ok && control.problem.text
            == "a module name cannot contain '/', '\\', ':' or control characters; did you mean 'Lead2'?",
            control.problem.text);
        assert(!w.setName("Lead\t2").ok && w.name == "Lead");
        assert(w.setName(times('x', 64)).ok && w.name.length == 64);
        immutable ModuleEditResult tooLong = w.setName(times('x', 65));
        assert(!tooLong.ok && tooLong.problem.kind == ModuleProblemKind.invalidName);
        assert(tooLong.problem.suggestion == times('x', 64) && w.name.length == 64);
        assert(w.setPresetName("My Lead").ok && w.loadedPreset().presetName == "My Lead");
        assert(w.name.length == 64);
        assert(w.setPresetName("").ok && w.loadedPreset().presetName == w.name);
        assert(w.setPresetName("Again").ok && w.loadedPreset().presetName == "Again");
        assert(w.setPresetName(" \t ").ok && w.loadedPreset().presetName == w.name);
        assert(!w.setPresetName(times('x', 65)).ok && w.loadedPreset().presetName == w.name);
    }

    unittest {
        immutable(ModuleDescriptor)[] descs = ModuleRegistry.descriptors();
        StudioSession session = new StudioSession();
        assert(session.initialize(44_100.0f));
        scope (exit) session.shutdown();
        foreach (i; 0 .. descs.length) {
            ModuleWriter w = writerOf(descs[i].typeId);
            float[] expected;
            foreach (k; 0 .. descs[i].params.length) {
                immutable ParamDescriptor p = descs[i].params[k];
                immutable float target = p.defaultVal != p.minVal ? p.minVal : p.maxVal;
                immutable ModuleEditResult set = w.setParamValue(p.name, target);
                assert(set.ok, descs[i].typeId ~ " " ~ p.name ~ ": " ~ set.problem.text());
                expected ~= target;
            }
            immutable string moduleName = "T " ~ descs[i].displayName;
            assert(w.setName(moduleName).ok);
            SavedModule m = w.savedModule(3);
            assert(m.id == 3 && m.typeId == descs[i].typeId && m.name == moduleName);
            assert(m.paramValues == expected && m.extraBlob.length == 0 && !m.hasChildProject);
            string err;
            assert(validateModuleForSave(m, 0, err), err);

            ModuleBytesResult bytes = w.presetBytes();
            assert(bytes.ok, bytes.problem.text());
            LoadedPreset back;
            assert(loadPreset(bytes.bytes, back, err), err);
            assert(back.presetName == moduleName);
            assert(back.mod.id == 1 && back.mod.typeId == descs[i].typeId && back.mod.name == moduleName);
            assert(back.mod.paramValues == expected, descs[i].typeId);
            uint newId;
            assert(session.loadModulePresetFromBytes(bytes.bytes, 0.0f, 0.0f, newId, err),
                descs[i].typeId ~ ": " ~ err);
            assert(newId != 0);

            ModuleWriterResult again = ModuleWriter.fromPresetBytes(bytes.bytes, "Fallback");
            assert(again.ok && again.writer.typeId == descs[i].typeId && again.writer.name == moduleName);
            assert(again.writer.paramValues == expected);
            foreach (k; 0 .. descs[i].params.length) {
                immutable ParamDescriptor p = descs[i].params[k];
                immutable ModuleTextResult text = again.writer.textOf(p.name);
                assert(text.ok, descs[i].typeId ~ " " ~ p.name);
                immutable ModuleEditResult onceMore = again.writer.setParamText(p.name, text.text);
                assert(onceMore.ok, descs[i].typeId ~ " " ~ p.name ~ " '" ~ text.text ~ "': " ~ onceMore.problem.text());
                assert(again.writer.valueOf(p.name).value == expected[k], descs[i].typeId ~ " " ~ p.name);
            }
            assert(again.writer.savedModule(9).id == 9 && again.writer.savedModule().id == 1);
        }
    }

    unittest {
        immutable(ModuleDescriptor)[] descs = ModuleRegistry.descriptors();
        uint state = 20261126u;
        foreach (i; 0 .. descs.length) {
            ModuleWriter w = writerOf(descs[i].typeId);
            foreach (k; 0 .. descs[i].params.length) {
                immutable ParamDescriptor p = descs[i].params[k];
                if (p.scale == ParamScale.discrete || !(p.maxVal > p.minVal)) {
                    continue;
                }
                float v = p.minVal + (p.maxVal - p.minVal) * 0.37f;
                if (v > p.maxVal) {
                    v = p.maxVal;
                }
                immutable ModuleEditResult set = w.setParamValue(p.name, v);
                assert(set.ok && w.valueOf(p.name).value == v, descs[i].typeId ~ " " ~ p.name);
                immutable ModuleTextResult text = w.textOf(p.name);
                immutable ModuleEditResult back = w.setParamText(p.name, text.text);
                assert(back.ok, descs[i].typeId ~ " " ~ p.name ~ " '" ~ text.text ~ "'");
                assert(w.valueOf(p.name).value == v, descs[i].typeId ~ " " ~ p.name ~ " '" ~ text.text ~ "'");
                immutable float random = p.minVal + (p.maxVal - p.minVal) * cast(float) (next(state) % 1001u) / 1001.0f;
                immutable float inside = random > p.maxVal ? p.maxVal : random;
                assert(w.setParamValue(p.name, inside).ok);
                immutable ModuleTextResult randomText = w.textOf(p.name);
                assert(w.setParamText(p.name, randomText.text).ok);
                assert(w.valueOf(p.name).value == inside, descs[i].typeId ~ " " ~ p.name ~ " '" ~ randomText.text ~ "'");
            }
        }
    }

    unittest {
        InstrumentLibrary library = new InstrumentLibrary(bundledPresetDirectories(), "");
        assert(library.entries().length == FACTORY_PRESETS.length);
        ModuleWriterResult bass = ModuleWriter.fromPreset(library, "Electric Bass");
        assert(bass.ok, bass.problem.text());
        assert(bass.writer.typeId == "synth.analog_gen" && bass.writer.name == "Electric Bass");
        SavedModule expected;
        string err;
        assert(factoryModule(*findFactoryPreset("Electric Bass"), 1, expected, err), err);
        assert(bass.writer.paramValues == expected.paramValues);
        assert(bass.writer.textOf("Waveform").text == "Saw");
        foreach (lenient; ["electric bass", "ELECTRICBASS", "Electric  Bass", " Electric Bass "]) {
            ModuleWriterResult r = ModuleWriter.fromPreset(library, lenient);
            assert(r.ok && r.writer.typeId == "synth.analog_gen", lenient);
        }
        ModuleWriterResult piano = ModuleWriter.fromPreset(library, "Keys/Electric Piano");
        assert(piano.ok && piano.writer.typeId == "synth.fm_synth" && piano.writer.name == "Electric Piano");
        ModuleWriterResult lower = ModuleWriter.fromPreset(library, "keys/electricpiano");
        assert(lower.ok && lower.writer.typeId == "synth.fm_synth");
        ModuleWriterResult typo = ModuleWriter.fromPreset(library, "Electric Bas");
        assert(!typo.ok && typo.problem.kind == ModuleProblemKind.unknownPreset);
        assert(typo.problem.subject == "Electric Bas" && typo.problem.suggestion == "Electric Bass");
        assert(typo.problem.text == "unknown preset 'Electric Bas'; did you mean 'Electric Bass'?");
        ModuleWriterResult none = ModuleWriter.fromPreset(library, "No Such Preset");
        assert(!none.ok && none.problem.suggestion == "");
        ModuleWriterResult wrongGroup = ModuleWriter.fromPreset(library, "Drums/Electric Bass");
        assert(!wrongGroup.ok && wrongGroup.problem.suggestion == "Bass/Electric Bass");
        assert(ModuleWriter.fromPreset(library, wrongGroup.problem.suggestion).writer.name == "Electric Bass");
        ModuleWriterResult wrongKey = ModuleWriter.fromPreset(library, "Key/Electric Piano");
        assert(!wrongKey.ok && wrongKey.problem.suggestion == "Keys/Electric Piano");
        ModuleWriterResult noLibrary = ModuleWriter.fromPreset(null, "Electric Bass");
        assert(!noLibrary.ok && noLibrary.problem.kind == ModuleProblemKind.unknownPreset);

        ModuleWriterResult file = ModuleWriter.fromPresetFile("resources/presets/Keys/Electric Piano.msym");
        assert(file.ok, file.problem.text());
        assert(file.writer.typeId == "synth.fm_synth" && file.writer.name == "Electric Piano");
        assert(file.writer.paramValues == piano.writer.paramValues);
        ModuleWriterResult renamed = ModuleWriter.fromPresetFile("resources/presets/Keys/Bell.msym");
        assert(renamed.writer.setName("bell").ok);
        assert(renamed.writer.name == "bell" && renamed.writer.loadedPreset().presetName == "Bell");
        assert(renamed.writer.setPresetName("").ok && renamed.writer.loadedPreset().presetName == "bell");
    }

    unittest {
        immutable string root = buildPath(tempDir(), "dracker-compose-module-test-" ~ to!string(thisProcessID()));
        scope (failure) {
            rmdirRecurse(root);
        }
        if (exists(root)) {
            rmdirRecurse(root);
        }
        mkdirRecurse(buildPath(root, "bundled", "Bass"));
        mkdirRecurse(buildPath(root, "user", "Bass"));
        mkdirRecurse(buildPath(root, "user", "Leads"));
        mkdirRecurse(buildPath(root, "user", "Bbb"));

        ModuleWriter lead = writerOf("synth.analog_gen");
        assert(lead.setName("My Lead").ok);
        assert(lead.setParamText("Waveform", "Square").ok && lead.setParamText("Cutoff", "1200").ok);
        immutable ModuleEditResult written = lead.writePresetFile(buildPath(root, "user", "Leads", "My Lead.msym"));
        assert(written.ok, written.problem.text());
        assert(lead.writePresetFile(buildPath(root, "user", "Bbb", "Lead.msym")).ok);
        assert(lead.setName("Other Lead").ok);
        assert(lead.writePresetFile(buildPath(root, "user", "Leads", "Lead.msym")).ok);
        assert(lead.setName("Shared").ok && lead.writePresetFile(buildPath(root, "bundled", "Bass", "Shared.msym")).ok);
        assert(lead.setName("My Shared").ok && lead.writePresetFile(buildPath(root, "user", "Bass", "Shared.msym")).ok);
        assert(!lead.writePresetFile(buildPath(root, "no-such-folder", "x.msym")).ok);
        assert(!lead.writePresetFile("").ok);

        InstrumentLibrary user = new InstrumentLibrary([], buildPath(root, "user"));
        ModuleWriterResult mine = ModuleWriter.fromPreset(user, "My Lead");
        assert(mine.ok, mine.problem.text());
        assert(mine.writer.typeId == "synth.analog_gen" && mine.writer.name == "My Lead");
        assert(mine.writer.textOf("Waveform").text == "Square" && mine.writer.valueOf("Cutoff").value == 1200.0f);
        ModuleWriterResult both = ModuleWriter.fromPreset(user, "Lead");
        assert(!both.ok && both.problem.kind == ModuleProblemKind.ambiguousPreset);
        assert(both.problem.suggestion == "Bbb/Lead");
        assert(both.problem.text == "'Lead' matches 2 presets; did you mean 'Bbb/Lead'?");
        assert(ModuleWriter.fromPreset(user, both.problem.suggestion).writer.name == "My Lead");
        ModuleWriterResult inLeads = ModuleWriter.fromPreset(user, "Leads/Lead");
        assert(inLeads.ok && inLeads.writer.name == "Other Lead");
        ModuleWriterResult nearLead = ModuleWriter.fromPreset(user, "My Led");
        assert(!nearLead.ok && nearLead.problem.suggestion == "My Lead");
        ModuleWriterResult nearShared = ModuleWriter.fromPreset(user, "Sharde");
        assert(!nearShared.ok && nearShared.problem.suggestion == "Shared");
        assert(ModuleWriter.fromPreset(user, "Bass/Shared").writer.name == "My Shared");

        InstrumentLibrary mixed = new InstrumentLibrary([buildPath(root, "bundled")], buildPath(root, "user"));
        ModuleWriterResult sameGroup = ModuleWriter.fromPreset(mixed, "Shared");
        assert(!sameGroup.ok && sameGroup.problem.kind == ModuleProblemKind.ambiguousPreset);
        assert(sameGroup.problem.suggestion == "");
        ModuleWriterResult byFile = ModuleWriter.fromPresetFile(buildPath(root, "user", "Leads", "Lead.msym"));
        assert(byFile.ok && byFile.writer.name == "Other Lead");
        rmdirRecurse(root);
    }

    unittest {
        ModuleWriterResult missing = ModuleWriter.fromPresetFile("/nonexistent/dracker/Nope.msym");
        assert(!missing.ok && missing.problem.kind == ModuleProblemKind.unreadablePreset);
        assert(missing.problem.suggestion == "" && missing.problem.subject == "/nonexistent/dracker/Nope.msym");
        assert(missing.problem.reason.startsWith("could not read the preset '/nonexistent/dracker/Nope.msym': "));
        ModuleWriterResult notPreset = ModuleWriter.fromPresetFile("dub.json");
        assert(!notPreset.ok && notPreset.problem.kind == ModuleProblemKind.unreadablePreset);
        assert(notPreset.problem.reason == "could not read the preset 'dub.json': Invalid or truncated .msym header");
        ModuleWriterResult noPath = ModuleWriter.fromPresetFile("");
        assert(!noPath.ok && noPath.problem.kind == ModuleProblemKind.unreadablePreset);
        ModuleWriterResult junk = ModuleWriter.fromPresetBytes(cast(const(ubyte)[]) "not a preset", "Junk");
        assert(!junk.ok && junk.problem.kind == ModuleProblemKind.unreadablePreset);
        assert(junk.problem.reason == "could not read the preset data: Invalid or truncated .msym header");

        LoadedPreset ghost;
        ghost.presetName = "Ghost";
        ghost.mod = SavedModule(1, "synth.ghost", "Ghost", 0.0f, 0.0f, false, false, [1.0f], null);
        ubyte[] ghostBytes;
        string err;
        assert(serializePreset(ghost, ghostBytes, err), err);
        ModuleWriterResult haunted = ModuleWriter.fromPresetBytes(ghostBytes, "Fallback");
        assert(!haunted.ok && !haunted.writer.loaded());
        assert(haunted.problem.kind == ModuleProblemKind.unknownModuleType);
        assert(haunted.problem.subject == "synth.ghost");
        assert(haunted.problem.suggestion == "synth.input", haunted.problem.suggestion);
        assert(writerOf(haunted.problem.suggestion).typeId == haunted.problem.suggestion);

        LoadedPreset odd;
        odd.presetName = "Odd";
        odd.mod = SavedModule(1, "synth.analog_gen", "Odd", 0.0f, 0.0f, false, false, [1.0f, 2.0f], null);
        ubyte[] oddBytes;
        assert(serializePreset(odd, oddBytes, err), err);
        ModuleWriterResult mismatch = ModuleWriter.fromPresetBytes(oddBytes, "Fallback");
        assert(!mismatch.ok && mismatch.problem.kind == ModuleProblemKind.mismatchedPreset);
        assert(mismatch.problem.text
            == "the preset does not match its module type 'Analog Generator': it has 2 parameter values, the type has 9");

        immutable ubyte[] EXTRA = [1, 2, 3, 255];
        LoadedPreset extra = writerOf("fx.amplifier").loadedPreset();
        extra.presetName = "Wide";
        extra.mod.id = 4;
        extra.mod.name = "Named Inside";
        extra.mod.posX = 10.0f;
        extra.mod.posY = 20.0f;
        extra.mod.muted = true;
        extra.mod.extraBlob = EXTRA.dup;
        ubyte[] extraBytes;
        assert(serializePreset(extra, extraBytes, err), err);
        ModuleWriterResult kept = ModuleWriter.fromPresetBytes(extraBytes, "Fallback");
        assert(kept.ok, kept.problem.text());
        assert(kept.writer.name == "Wide" && kept.writer.loadedPreset().presetName == "Wide");
        SavedModule keptModule = kept.writer.savedModule();
        assert(keptModule.id == 4 && keptModule.name == "Wide" && keptModule.posX == 10.0f && keptModule.posY == 20.0f);
        assert(keptModule.muted && !keptModule.bypassed && keptModule.extraBlob == EXTRA);
        ModuleBytesResult renamedBytes = kept.writer.presetBytes();
        assert(renamedBytes.ok && renamedBytes.bytes != extraBytes);
        assert(kept.writer.setName("Named Inside").ok);
        assert(kept.writer.name == "Named Inside" && kept.writer.loadedPreset().presetName == "Wide");
        ModuleBytesResult again = kept.writer.presetBytes();
        assert(again.ok && again.bytes == extraBytes);
        keptModule.extraBlob[0] = 9;
        assert(kept.writer.savedModule().extraBlob == EXTRA);
        assert(kept.writer.resetToDefaults().ok && kept.writer.savedModule().extraBlob == EXTRA);

        LoadedPreset bare;
        bare.presetName = "";
        bare.mod = writerOf("fx.amplifier").savedModule();
        bare.mod.name = "Inside";
        ubyte[] bareBytes;
        assert(serializePreset(bare, bareBytes, err), err);
        ModuleWriterResult named = ModuleWriter.fromPresetBytes(bareBytes, "Fallback");
        assert(named.ok && named.writer.name == "Inside", named.writer.name);
        assert(named.writer.loadedPreset().presetName == "Inside");
        bare.mod.name = "";
        assert(serializePreset(bare, bareBytes, err), err);
        ModuleWriterResult unnamed = ModuleWriter.fromPresetBytes(bareBytes, "Fallback");
        assert(unnamed.ok && unnamed.writer.name == "Fallback");

        LoadedProject child;
        child.title = "Child";
        child.modules = [SavedModule(1, "core.output", "Output", 0.0f, 0.0f, false, false, null, null)];
        ubyte[] childBytes;
        assert(serializeProject(child, childBytes, err), err);
        LoadedPreset meta = writerOf("ctl.metamodule").loadedPreset();
        meta.presetName = "Nested";
        meta.mod.hasChildProject = true;
        meta.mod.childProjectMsv = childBytes.dup;
        ubyte[] metaBytes;
        assert(serializePreset(meta, metaBytes, err), err);
        ModuleWriterResult nested = ModuleWriter.fromPresetBytes(metaBytes, "Fallback");
        assert(nested.ok, nested.problem.text());
        SavedModule nestedModule = nested.writer.savedModule();
        assert(nestedModule.hasChildProject && nestedModule.childProjectMsv == childBytes);
        assert(nested.writer.name == "Nested");
        assert(nested.writer.setName("MetaModule").ok);
        ModuleBytesResult nestedBytes = nested.writer.presetBytes();
        assert(nestedBytes.ok && nestedBytes.bytes == metaBytes);
    }

    unittest {
        ModuleWriter empty = ModuleWriter.init;
        assert(!empty.loaded() && empty.typeId == "" && empty.name == "" && empty.paramCount == 0);
        assert(empty.descriptor is null && empty.paramValues.length == 0);
        assert(empty.savedModule().typeId == "" && empty.loadedPreset().presetName == "");
        immutable ModuleEditResult set = empty.setParamText("Cutoff", "900");
        assert(!set.ok && set.problem.kind == ModuleProblemKind.notLoaded);
        assert(set.problem.text == "the module writer holds no module");
        assert(!empty.setParamValue("Cutoff", 900.0f).ok && !empty.setName("Lead").ok);
        assert(!empty.resetToDefaults().ok && !empty.writePresetFile("/tmp/x.msym").ok);
        assert(!empty.valueOf("Cutoff").ok && !empty.textOf("Cutoff").ok);
        ModuleBytesResult bytes = empty.presetBytes();
        assert(!bytes.ok && bytes.bytes.length == 0 && bytes.problem.kind == ModuleProblemKind.notLoaded);
    }

    unittest {
        immutable string ALPHABET = "019.eE+-abcXYZ_ /%\t'Saw Cutof:\xC3\xA9\xFF";
        InstrumentLibrary library = new InstrumentLibrary(bundledPresetDirectories(), "");
        uint state = 777u;
        ModuleWriter w = writerOf("synth.analog_gen");
        size_t accepted = 0;
        foreach (round; 0 .. 3000) {
            immutable size_t length = next(state) % 13u;
            string text;
            foreach (k; 0 .. length) {
                text ~= ALPHABET[next(state) % ALPHABET.length];
            }
            immutable float[] before = w.paramValues.dup;
            immutable string nameBefore = w.name;
            immutable ModuleEditResult value = w.setParamText("Waveform", text);
            if (!value.ok) {
                assert(w.paramValues == before);
                assert(value.problem.kind == ModuleProblemKind.notANumber
                    || value.problem.kind == ModuleProblemKind.outOfRange
                    || value.problem.kind == ModuleProblemKind.notAWholeNumber
                    || value.problem.kind == ModuleProblemKind.unknownOption, value.problem.text());
                if (value.problem.suggestion.length > 0) {
                    ModuleWriter probe = w;
                    assert(probe.setParamText("Waveform", value.problem.suggestion).ok, value.problem.suggestion);
                }
            } else {
                accepted++;
                assert(w.setParamText("Waveform", w.textOf("Waveform").text).ok);
            }
            immutable ModuleEditResult number = w.setParamText("Cutoff", text);
            if (!number.ok) {
                assert(number.problem.kind == ModuleProblemKind.notANumber
                    || number.problem.kind == ModuleProblemKind.outOfRange, number.problem.text());
                if (number.problem.suggestion.length > 0) {
                    ModuleWriter probe = w;
                    assert(probe.setParamText("Cutoff", number.problem.suggestion).ok, number.problem.suggestion);
                }
            }
            immutable ModuleEditResult name = w.setParamText(text, "1");
            if (!name.ok && name.problem.kind == ModuleProblemKind.unknownParameter && name.problem.suggestion.length > 0) {
                assert(w.valueOf(name.problem.suggestion).ok, name.problem.suggestion);
            }
            ModuleWriterResult type = ModuleWriter.fromType(text);
            if (!type.ok) {
                assert(type.problem.kind == ModuleProblemKind.unknownModuleType);
                if (type.problem.suggestion.length > 0) {
                    assert(ModuleWriter.fromType(type.problem.suggestion).ok, type.problem.suggestion);
                }
            }
            ModuleWriterResult preset = ModuleWriter.fromPreset(library, text);
            assert(preset.ok || preset.problem.kind == ModuleProblemKind.unknownPreset
                || preset.problem.kind == ModuleProblemKind.ambiguousPreset, preset.problem.text());
            immutable ModuleEditResult renamed = w.setName(text);
            if (!renamed.ok) {
                assert(renamed.problem.kind == ModuleProblemKind.invalidName && w.name == nameBefore);
                if (renamed.problem.suggestion.length > 0) {
                    ModuleWriter probe = w;
                    assert(probe.setName(renamed.problem.suggestion).ok, renamed.problem.suggestion);
                }
            }
        }
        assert(accepted > 0);
        assert(w.loaded() && w.paramCount == 9);
        assert(w.valueOf("Cutoff").value >= 40.0f && w.valueOf("Cutoff").value <= 18000.0f);
        assert(w.setParamText("Waveform", "Saw").ok && w.setParamText("Cutoff", "900").ok);
    }

    unittest {
        ModuleWriter original = writerOf("synth.analog_gen");
        ModuleWriter copy = original;
        assert(copy.setParamValue("Cutoff", 900.0f).ok && copy.setName("Copy").ok);
        assert(original.valueOf("Cutoff").value == 4000.0f && original.name == "Analog Generator");
        assert(copy.valueOf("Cutoff").value == 900.0f && copy.name == "Copy");
        ModuleWriterResult made = ModuleWriter.fromType("fx.amplifier");
        ModuleWriter taken = made.writer;
        assert(taken.setParamValue("Volume", 2.0f).ok);
        assert(made.writer.valueOf("Volume").value != 2.0f);
        const ModuleWriter frozen = original;
        ModuleWriter thawed = frozen;
        assert(thawed.setParamValue("Cutoff", 100.0f).ok && frozen.valueOf("Cutoff").value == 4000.0f);

        immutable ubyte[] EXTRA = [7, 8, 9];
        LoadedPreset withExtra = writerOf("fx.amplifier").loadedPreset();
        withExtra.presetName = "Extra";
        withExtra.mod.extraBlob = EXTRA.dup;
        ubyte[] bytes;
        string err;
        assert(serializePreset(withExtra, bytes, err), err);
        ModuleWriter first = ModuleWriter.fromPresetBytes(bytes).writer;
        ModuleWriter second = first;
        assert(second.paramValues.ptr !is first.paramValues.ptr);
        assert(second.savedModule().extraBlob == EXTRA && first.savedModule().extraBlob == EXTRA);
    }

    unittest {
        ModuleWriter w = writerOf("fx.amplifier");
        string hangul = "";
        foreach (k; 0 .. 22) {
            hangul ~= "\uAC00";
        }
        assert(hangul.length == 66);
        immutable ModuleEditResult tooLong = w.setName(hangul);
        assert(!tooLong.ok && tooLong.problem.kind == ModuleProblemKind.invalidName);
        assert(tooLong.problem.reason == "a module name has at most 64 bytes");
        assert(tooLong.problem.suggestion == hangul[0 .. 63], tooLong.problem.suggestion);
        assert(w.setName(tooLong.problem.suggestion).ok && w.name.length == 63);

        immutable string[2][] CASES = [
            ["Keys/Lead", "Keys-Lead"], [".hidden", "hidden"], ["a:b", "a-b"], ["a\\b", "a-b"],
            ["a\tb", "ab"], ["ab\xFFcd", "abcd"], ["...", ""], ["\x01\x02", ""], ["/", "-"]
        ];
        immutable string[2][] REASONS = [
            ["Keys/Lead", "a module name cannot contain '/', '\\', ':' or control characters"],
            [".hidden", "a module name cannot start with '.'"],
            ["ab\xFFcd", "a module name must be valid UTF-8 text"]
        ];
        foreach (ref c; CASES) {
            immutable ModuleEditResult r = w.setName(c[0]);
            assert(!r.ok && r.problem.kind == ModuleProblemKind.invalidName, c[0]);
            assert(r.problem.suggestion == c[1], c[0] ~ " -> " ~ r.problem.suggestion);
            assert(suggestedName(c[0]) == c[1]);
            if (c[1].length > 0) {
                ModuleWriter probe = w;
                assert(probe.setName(c[1]).ok, c[1]);
                assert(probe.setPresetName(c[1]).ok, c[1]);
            }
            assert(!w.setPresetName(c[0]).ok, c[0]);
        }
        foreach (ref c; REASONS) {
            assert(w.setName(c[0]).problem.reason == c[1], w.setName(c[0]).problem.reason);
        }
        assert(suggestedName("Fine Name") == "Fine Name" && suggestedName("") == "");

        LoadedPreset slashed = writerOf("fx.amplifier").loadedPreset();
        slashed.presetName = "Keys/Lead";
        ubyte[] bytes;
        string err;
        assert(serializePreset(slashed, bytes, err), err);
        ModuleWriterResult adopted = ModuleWriter.fromPresetBytes(bytes, "Fallback");
        assert(adopted.ok && adopted.writer.name == "Keys-Lead", adopted.writer.name);
        assert(adopted.writer.loadedPreset().presetName == "Keys-Lead");
        slashed.presetName = "\x01\x02";
        assert(serializePreset(slashed, bytes, err), err);
        ModuleWriterResult control = ModuleWriter.fromPresetBytes(bytes, "Fallback");
        assert(control.ok && control.writer.name == "Amplifier", control.writer.name);
    }

    unittest {
        ModuleWriter w = writerOf("synth.analog_gen");
        immutable ModuleEditResult huge = w.setParamValue("Unison", 1.0e30f);
        assert(!huge.ok && huge.problem.kind == ModuleProblemKind.outOfRange);
        assert(huge.problem.reason == "'1e+30' is outside the range of 'Unison' (a whole number from 1 to 4)",
            huge.problem.reason);
        assert(huge.problem.suggestion == "4");
        immutable ModuleEditResult negative = w.setParamValue("Unison", -1.0e30f);
        assert(!negative.ok && negative.problem.subject == "-1e+30" && negative.problem.suggestion == "1");
        assert(parameterValueText(paramOf("synth.analog_gen", 1), 3.0e20f) == "3e+20");

        foreach (row; [["Cutoff", "1e40", "18000"], ["Cutoff", "-1e40", "40"], ["Unison", "1e40", "4"],
                ["Cutoff", "3.5e38", "18000"], ["Cutoff", "1e-50", "40"]]) {
            immutable ModuleEditResult r = w.setParamText(row[0], row[1]);
            assert(!r.ok && r.problem.kind == ModuleProblemKind.outOfRange, row[1] ~ " " ~ r.problem.text());
            assert(r.problem.suggestion == row[2], row[1] ~ " -> " ~ r.problem.suggestion);
            assert(r.problem.reason.startsWith("'" ~ row[1] ~ "' is outside the range of '" ~ row[0] ~ "'"));
        }
        assert(w.paramValues == ANALOG_DEFAULTS);
    }

    unittest {
        ModuleDescriptor d;
        d.typeId = "test.numbers";
        d.displayName = "Numbers";
        immutable ParamDescriptor[1] params = [
            ParamDescriptor(0, "f0", "Size", 0.0f, 3.0f, 0.0f, "", ParamScale.discrete, ["1", "2", "4", "8"])
        ];
        d.params = params[];
        ModuleWriter w = ModuleWriter.fromDescriptor(&d, "N").writer;
        foreach (value; 0 .. 4) {
            assert(w.setParamValue("Size", cast(float) value).ok);
            immutable string text = w.textOf("Size").text;
            assert(text == to!string(value), text);
            ModuleWriter probe = w;
            assert(probe.setParamText("Size", text).ok && probe.valueOf("Size").value == cast(float) value);
        }
    }

    unittest {
        immutable ModuleDescriptor[3] FAKE = [
            ModuleDescriptor("a.one", "Same Name"),
            ModuleDescriptor("b.two", "same name"),
            ModuleDescriptor("c.three", "Third")
        ];
        const(ModuleDescriptor)* found;
        ModuleProblem problem;
        assert(!findModuleType(FAKE[], "Same Name", found, problem) && found is null);
        assert(problem.kind == ModuleProblemKind.unknownModuleType && problem.suggestion == "a.one");
        assert(problem.reason == "'Same Name' matches more than one module type");
        assert(findModuleType(FAKE[], "b.two", found, problem) && found.typeId == "b.two");
        assert(findModuleType(FAKE[], " THIRD ", found, problem) && found.typeId == "c.three");
        assert(!findModuleType(FAKE[], "Thrid", found, problem) && problem.suggestion == "Third");
        assert(!findModuleType(FAKE[], "c.thre", found, problem) && problem.suggestion == "c.three");

        ModuleWriter w = writerOf("fx.amplifier");
        immutable string blocked = buildPath(tempDir(), "dracker-no-such-folder-" ~ to!string(thisProcessID()),
            "x.msym");
        immutable ModuleEditResult failed = w.writePresetFile(blocked);
        assert(!failed.ok && failed.problem.kind == ModuleProblemKind.writeFailed);
        assert(failed.problem.subject == blocked && failed.problem.reason.startsWith("could not write the preset: "));
        assert(!exists(blocked));
    }

    unittest {
        LoadedPreset loud = writerOf("synth.analog_gen").loadedPreset();
        loud.presetName = "Loud";
        loud.mod.paramValues[3] = 99999.0f;
        ubyte[] bytes;
        string err;
        assert(serializePreset(loud, bytes, err), err);
        ModuleWriterResult r = ModuleWriter.fromPresetBytes(bytes);
        assert(!r.ok && r.problem.kind == ModuleProblemKind.mismatchedPreset && r.problem.subject == "Cutoff");
        assert(r.problem.reason == "the preset does not match its module type 'Analog Generator': '99999' is outside "
            ~ "the range of 'Cutoff' (a number from 40 to 18000 Hz)", r.problem.reason);
        loud.mod.paramValues[3] = 4000.0f;
        loud.mod.paramValues[0] = 2.5f;
        assert(serializePreset(loud, bytes, err), err);
        ModuleWriterResult half = ModuleWriter.fromPresetBytes(bytes);
        assert(!half.ok && half.problem.kind == ModuleProblemKind.mismatchedPreset && half.problem.subject == "Waveform");
        assert(half.problem.reason == "the preset does not match its module type 'Analog Generator': '2.5' is not a "
            ~ "whole number; 'Waveform' takes a whole number from 0 to 5, or one of its names", half.problem.reason);
    }
}
