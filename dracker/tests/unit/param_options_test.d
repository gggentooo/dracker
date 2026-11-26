/**
 * File:         tests/unit/param_options_test.d
 * Module:       tests.unit.param_options_test
 * Phase:        Composition helper prerequisites — T91 (option names for choice parameters)
 *
 * Purpose:
 *   Verifies that every discrete parameter of every registered module type either names each of its values
 *   (ParamDescriptor.options, one name per value from minVal upwards) or is one of the parameters whose values
 *   are plain whole numbers, so a new choice parameter added without names fails here. The names of one
 *   parameter stay distinct when case and spaces are ignored (the composition helper matches them that way),
 *   contain no '=' or quote characters and do not read as numbers. A table of the expected names guards the
 *   words the owner approved, the parameter rack shows them, and the module writer takes them.
 *
 * Real-Time & Safety Contract:
 *   Pure single-threaded checks against the immutable module registry; no session, audio or GUI.
 *
 * Dependencies:
 *   Internal: compose.module_writer, compose.names, graph.module_api, graph.registry, gui.views.param_rack
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T70, T91), docs/manual.md (Appendix B)
 */
module tests.unit.param_options_test;

version (unittest) {
    import compose.module_writer : ModuleWriter, ModuleWriterResult;
    import compose.names : normalize;
    import graph.module_api : ModuleDescriptor, ParamDescriptor, ParamScale;
    import graph.registry : ModuleRegistry;
    import gui.views.param_rack : discreteOptionLabel, formatParamValue;

    /**
     * One parameter: the module type id and the parameter's display name.
     */
    private struct ParamKey {
        string typeId;
        string name;
    }

    /**
     * The names one choice parameter is expected to have.
     */
    private struct Expected {
        string typeId;
        string name;
        string[] options;
    }

    private immutable ParamKey[14] INTEGER_VALUED = [
        ParamKey("synth.analog_gen", "Unison"),
        ParamKey("fx.loop", "Repeats"),
        ParamKey("fx.loop", "Length"),
        ParamKey("ctl.feedback", "Fixed Delay"),
        ParamKey("fx.distortion", "SR Div"),
        ParamKey("fx.fft", "FFT Size"),
        ParamKey("fx.fft", "Bin Shift"),
        ParamKey("fx.filter_pro", "Slope"),
        ParamKey("ctl.metamodule", "Input Module"),
        ParamKey("ctl.multictl", "Quantization"),
        ParamKey("ctl.pitch2ctl", "First Note"),
        ParamKey("ctl.pitch2ctl", "Semitones"),
        ParamKey("ctl.ctl2note", "First Note"),
        ParamKey("ctl.ctl2note", "Range Notes")
    ];

    /**
     * The registered type id of a module by its display name.
     *
     * Params:
     *   displayName = The display name.
     *
     * Returns:
     *   Its type id.
     */
    private string typeIdOf(string displayName) {
        foreach (ref d; ModuleRegistry.descriptors()) {
            if (d.displayName == displayName) {
                return d.typeId;
            }
        }
        assert(false, displayName);
    }

    /**
     * Finds a parameter of a module type.
     *
     * Params:
     *   typeId = The type id.
     *   name = The parameter's display name.
     *
     * Returns:
     *   The parameter's descriptor.
     */
    private ParamDescriptor paramOf(string typeId, string name) {
        const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(typeId);
        assert(d !is null, typeId);
        foreach (ref p; d.params) {
            if (p.name == name) {
                return p;
            }
        }
        assert(false, typeId ~ " " ~ name);
    }

    /**
     * Reports whether a parameter is one whose values stay plain numbers.
     *
     * Params:
     *   typeId = The type id.
     *   name = The parameter's display name.
     *
     * Returns:
     *   True when it is listed in INTEGER_VALUED.
     */
    private bool isIntegerValued(string typeId, string name) {
        foreach (ref k; INTEGER_VALUED) {
            if (k.typeId == typeId && k.name == name) {
                return true;
            }
        }
        return false;
    }

    /**
     * Reports whether a text reads as a decimal number (digits with an optional sign, point and exponent).
     *
     * Params:
     *   text = The text.
     *
     * Returns:
     *   True when every character is part of a number and at least one is a digit.
     */
    private bool looksNumeric(string text) {
        bool digit = false;
        foreach (c; text) {
            if (c >= '0' && c <= '9') {
                digit = true;
            } else if (c != '+' && c != '-' && c != '.' && c != 'e' && c != 'E') {
                return false;
            }
        }
        return digit;
    }

    unittest {
        foreach (ref k; INTEGER_VALUED) {
            immutable ParamDescriptor p = paramOf(k.typeId, k.name);
            assert(p.scale == ParamScale.discrete && p.options.length == 0, k.typeId ~ " " ~ k.name);
        }
        size_t named = 0;
        size_t plain = 0;
        foreach (ref d; ModuleRegistry.descriptors()) {
            foreach (ref p; d.params) {
                if (p.scale != ParamScale.discrete) {
                    assert(p.options.length == 0, d.typeId ~ " " ~ p.name);
                    continue;
                }
                if (isIntegerValued(d.typeId, p.name)) {
                    plain++;
                    continue;
                }
                immutable size_t values = cast(size_t) (p.maxVal - p.minVal) + 1;
                assert(p.options.length == values, d.typeId ~ " " ~ p.name ~ " has no name for every value");
                foreach (i, option; p.options) {
                    assert(option.length > 0 && normalize(option).length > 0, d.typeId ~ " " ~ p.name);
                    assert(option[0] != ' ' && option[$ - 1] != ' ', option);
                    foreach (c; option) {
                        assert(c != '=' && c != '"' && c != '\'' && c >= 0x20 && c < 0x7F, option);
                    }
                    assert(!looksNumeric(option), option);
                    foreach (j; i + 1 .. p.options.length) {
                        assert(normalize(option) != normalize(p.options[j]), d.typeId ~ " " ~ option);
                    }
                }
                named++;
            }
        }
        assert(named == 36, "named choice parameters");
        assert(plain == 14, "integer-valued parameters");
    }

    unittest {
        immutable Expected[] EXPECTED = [
            Expected("Master Output", "Limiter", ["Off", "On"]),
            Expected("Analog Generator", "Waveform", ["Sine", "Triangle", "Saw", "Square", "Noise", "Drawn"]),
            Expected("FM Synth", "Algorithm",
                ["Serial", "Split Branches", "Two Stacks", "Four Into One", "Carrier + Stacks", "Additive"]),
            Expected("Kicker", "Waveform", ["Sine", "Triangle", "Square"]),
            Expected("Sampler", "Loop Mode", ["One-Shot", "Forward", "Ping-Pong"]),
            Expected("Sampler", "Quality", ["Nearest", "Linear", "Cubic"]),
            Expected("SpectraVoice", "Profile", ["Organ", "Brass", "Choir", "Bell"]),
            Expected("Input", "Channel Route", ["Stereo", "Left", "Right", "Mono Mix"]),
            Expected("Input", "Mute", ["Off", "On"]),
            Expected("Vorbis Player", "Loop", ["Off", "On"]),
            Expected("Amplifier", "Invert", ["Off", "On"]),
            Expected("Filter Pro", "Mode",
                ["Lowpass", "Highpass", "Bandpass", "Notch", "Allpass", "Peaking", "Low Shelf", "High Shelf"]),
            Expected("Distortion", "Mode", ["Soft Clip", "Hard Clip", "Sine Fold", "Asymmetric"]),
            Expected("WaveShaper", "DC Block", ["Off", "On"]),
            Expected("WaveShaper", "Oversample", ["1x", "2x", "4x"]),
            Expected("Delay", "Unit", ["ms", "Hz", "Lines/100"]),
            Expected("Delay", "Inverse", ["Normal", "Swap Wet L/R"]),
            Expected("Echo", "Stereo Mode", ["Stereo", "Ping-Pong"]),
            Expected("Reverb", "Freeze", ["Off", "On"]),
            Expected("Compressor", "Mode", ["Peak", "RMS"]),
            Expected("Modulator", "Mod Type", ["AM", "Ring", "Phase"]),
            Expected("Vocal Filter", "Voice Type", ["Soprano", "Alto", "Tenor", "Bass"]),
            Expected("FFT FX", "Freeze", ["Off", "On"]),
            Expected("Loop", "Mode", ["Forward", "Ping-Pong"]),
            Expected("LFO", "Waveform", ["Sine", "Triangle", "Saw", "Square", "S&H Random"]),
            Expected("LFO", "Sync Unit", ["Hz", "Beats/Cycle"]),
            Expected("ADSR", "Mode", ["Gated", "One-Shot", "Inverted"]),
            Expected("Glide", "Polyphonic", ["Off", "On"]),
            Expected("Glide", "Reset On First", ["Off", "On"]),
            Expected("MultiSynth", "Curve Mode", ["Off", "Velocity", "Velocity + Pitch"]),
            Expected("Ctl2Note", "Trigger Mode", ["Retrigger", "Legato", "Gate"]),
            Expected("Velocity2Ctl", "NoteOff Action", ["Keep", "Go To Min", "Go To 0"]),
            Expected("Pitch Detector", "Algorithm", ["Autocorrelation", "Zero-Crossing"]),
            Expected("Feedback", "Channels", ["Stereo", "Mono"]),
            Expected("MetaModule", "BPM Sync", ["Off", "On"]),
            Expected("MetaModule", "Play Patterns", ["Off", "Follow Parent", "Note Triggered"])
        ];
        assert(EXPECTED.length == 36);
        foreach (ref e; EXPECTED) {
            immutable string typeId = typeIdOf(e.typeId);
            immutable ParamDescriptor p = paramOf(typeId, e.name);
            assert(p.options == e.options, e.typeId ~ " " ~ e.name);
            foreach (i, option; e.options) {
                immutable float value = p.minVal + cast(float) i;
                assert(discreteOptionLabel(p, value) == option, option);
                assert(formatParamValue(p, value) == option, formatParamValue(p, value));
            }
            ModuleWriterResult made = ModuleWriter.fromType(typeId);
            assert(made.ok, typeId);
            foreach (i, option; e.options) {
                assert(made.writer.setParamText(e.name, option).ok, option);
                assert(made.writer.valueOf(e.name).value == p.minVal + cast(float) i, option);
                assert(made.writer.textOf(e.name).text == option, option);
            }
        }
    }
}
