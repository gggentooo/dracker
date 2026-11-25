/**
 * File:         source/app/skeleton_gen.d
 * Module:       app.skeleton_gen
 * Phase:        Skeleton project generator — T13 (instrument choices and default sounds)
 *
 * Purpose:
 *   Instrument part of the skeleton project generator. An InstrumentChoice says what plays the bass or the
 *   piano part: the built-in default sound, the default parameters of one selectable module type (Analog
 *   Generator, FM Synth, SpectraVoice), or a module loaded from a .msym preset file. resolveInstrument() turns a
 *   choice into the SavedModule that goes into the generated project. The default bass is an Analog Generator
 *   (saw through a low filter, short attack and release); the default piano is an FM Synth set up as an
 *   electric piano (two carrier stacks: a soft body and a bright, fast-decaying tine). Both are constants in code,
 *   set by parameter name so they survive parameter reordering.
 *
 * Real-Time & Safety Contract:
 *   UI/off-RT only; builds documents, never touches the engine or the session. Functions that look up the
 *   module registry are @system because ModuleRegistry.findByTypeId() is.
 *
 * Dependencies:
 *   Internal: graph.module_api, graph.port, graph.registry, io.project_format, sequencer.{note,timeline}
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum InstrumentRole (bass, piano); enum InstrumentSource (defaultSound, moduleType, presetFile)
 *   - struct InstrumentChoice (defaults(), ofType(), ofPreset(), label())
 *   - immutable SELECTABLE_SYNTH_TYPES; instrumentChoices()
 *   - defaultBassModule(), defaultPianoModule(), moduleWithDefaults(), resolveInstrument()
 *   - isPlayableInstrument(), audioOutputPort(), eventInputPort(), paramIndex()
 *   - instrumentPreviewProject() (listening test for the default sounds; dracker --sound-check=<file.wav>)
 *   - (T19, planned) SkeletonSpec, validateSpec(), generateSkeleton()
 *
 * See_Also:
 *   docs/todo.md (T06, T13, T19)
 */
module app.skeleton_gen;

import graph.module_api : ModuleDescriptor;
import graph.port : isAudioPort, PortDirection, PortKind;
import graph.registry : ModuleRegistry;
import io.project_format : LoadedPreset, LoadedProject, SavedModule, SavedPattern, SavedWire;
import sequencer.note : NoteCell;
import sequencer.timeline : TimelineClip;

/**
 * Part of the generated arrangement an instrument plays.
 */
enum InstrumentRole : ubyte {
    bass = 0,
    piano = 1
}

/**
 * Where an instrument's module comes from.
 */
enum InstrumentSource : ubyte {
    defaultSound = 0,
    moduleType = 1,
    presetFile = 2
}

/**
 * Module types offered in the instrument dropdowns besides the default sound (T06): pitched synths that make
 * sound without a loaded sample.
 */
immutable string[] SELECTABLE_SYNTH_TYPES = ["synth.analog_gen", "synth.fm_synth", "synth.spectravoice"];

/**
 * What plays one part: the default sound, a module type with its defaults, or a module from a preset file.
 */
struct InstrumentChoice {
    InstrumentSource source = InstrumentSource.defaultSound;
    string typeId;
    string presetName;
    SavedModule preset;

    /**
     * Returns the default-sound choice.
     *
     * Returns:
     *   Choice.
     */
    static InstrumentChoice defaults() @safe pure nothrow {
        return InstrumentChoice.init;
    }

    /**
     * Returns the choice of one module type with its default parameters.
     *
     * Params:
     *   typeId = Registered module type id.
     *
     * Returns:
     *   Choice.
     */
    static InstrumentChoice ofType(string typeId) @safe pure nothrow {
        InstrumentChoice c;
        c.source = InstrumentSource.moduleType;
        c.typeId = typeId;
        return c;
    }

    /**
     * Returns the choice of the module stored in a loaded .msym preset.
     *
     * Params:
     *   p = Parsed preset.
     *
     * Returns:
     *   Choice (the module is copied, including its extra data).
     */
    static InstrumentChoice ofPreset(const ref LoadedPreset p) @safe pure nothrow {
        InstrumentChoice c;
        c.source = InstrumentSource.presetFile;
        c.typeId = p.mod.typeId;
        c.presetName = p.presetName.length > 0 ? p.presetName : p.mod.name;
        c.preset = copyModule(p.mod);
        return c;
    }

    /**
     * Returns the text shown for this choice in a dropdown.
     *
     * Returns:
     *   "Default", the module type's display name, or "Preset: <name>".
     */
    string label() const {
        final switch (source) {
            case InstrumentSource.defaultSound:
                return "Default";
            case InstrumentSource.moduleType: {
                const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(typeId);
                return d is null ? typeId : d.displayName;
            }
            case InstrumentSource.presetFile:
                return "Preset: " ~ presetName;
        }
    }
}

/**
 * Lists the choices offered in an instrument dropdown: the default sound, then each registered selectable
 * module type in SELECTABLE_SYNTH_TYPES order. (Loading a preset file is a separate dropdown entry handled by
 * the panel, which then adds an ofPreset() choice.)
 *
 * Returns:
 *   Choices.
 */
InstrumentChoice[] instrumentChoices() {
    InstrumentChoice[] list = [InstrumentChoice.defaults()];
    foreach (t; SELECTABLE_SYNTH_TYPES) {
        if (ModuleRegistry.findByTypeId(t) !is null) {
            list ~= InstrumentChoice.ofType(t);
        }
    }
    return list;
}

/**
 * Builds a module of a registered type with every parameter at its default value.
 *
 * Params:
 *   typeId = Registered module type id.
 *   id = Module id to assign (non-zero).
 *   name = Display name.
 *   m = Receives the module.
 *
 * Returns:
 *   False if the type is not registered.
 */
bool moduleWithDefaults(string typeId, uint id, string name, out SavedModule m) {
    const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(typeId);
    if (d is null) {
        return false;
    }
    m.id = id;
    m.typeId = typeId;
    m.name = name;
    m.paramValues = new float[d.params.length];
    foreach (i, ref p; d.params) {
        m.paramValues[i] = p.defaultVal;
    }
    return true;
}

/**
 * Returns the index of a parameter by its display name.
 *
 * Params:
 *   d = Module descriptor.
 *   name = Parameter name, e.g. "Cutoff".
 *
 * Returns:
 *   Index, or -1 when the module has no such parameter.
 */
ptrdiff_t paramIndex(const(ModuleDescriptor)* d, string name) @safe pure nothrow @nogc {
    if (d is null) {
        return -1;
    }
    foreach (i, ref p; d.params) {
        if (p.name == name) {
            return cast(ptrdiff_t) i;
        }
    }
    return -1;
}

/**
 * Returns the default bass: an Analog Generator playing a saw through a low, slightly resonant filter.
 *
 * Params:
 *   id = Module id to assign.
 *
 * Returns:
 *   Module named "Bass".
 */
SavedModule defaultBassModule(uint id) {
    SavedModule m;
    immutable bool ok = moduleWithDefaults("synth.analog_gen", id, "Bass", m);
    assert(ok, "synth.analog_gen must be registered");
    const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId("synth.analog_gen");
    setParam(m, d, "Waveform", 2.0f);
    setParam(m, d, "Unison", 1.0f);
    setParam(m, d, "Detune", 0.05f);
    setParam(m, d, "Cutoff", 900.0f);
    setParam(m, d, "Resonance", 0.25f);
    setParam(m, d, "Attack", 0.003f);
    setParam(m, d, "Decay", 0.25f);
    setParam(m, d, "Sustain", 0.6f);
    setParam(m, d, "Release", 0.12f);
    return m;
}

/**
 * Returns the default piano: an FM Synth electric piano. Algorithm 2 has two carriers: operator 1 with a gentle
 * same-ratio modulator (the body) and operator 3 modulated by operator 5 at ratio 14 (the tine). Operator 4 is
 * silent so operator 2 is a plain sine modulator; the decay is long and the sustain low, like a struck key.
 *
 * Params:
 *   id = Module id to assign.
 *
 * Returns:
 *   Module named "Piano".
 */
SavedModule defaultPianoModule(uint id) {
    SavedModule m;
    immutable bool ok = moduleWithDefaults("synth.fm_synth", id, "Piano", m);
    assert(ok, "synth.fm_synth must be registered");
    const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId("synth.fm_synth");
    setParam(m, d, "Algorithm", 2.0f);
    setParam(m, d, "Feedback", 0.05f);
    setParam(m, d, "Op1 Ratio", 1.0f);
    setParam(m, d, "Op2 Ratio", 1.0f);
    setParam(m, d, "Op3 Ratio", 1.0f);
    setParam(m, d, "Op4 Ratio", 1.0f);
    setParam(m, d, "Op5 Ratio", 14.0f);
    setParam(m, d, "Op1 Level", 1.0f);
    setParam(m, d, "Op2 Level", 0.35f);
    setParam(m, d, "Op3 Level", 0.3f);
    setParam(m, d, "Op4 Level", 0.0f);
    setParam(m, d, "Op5 Level", 0.18f);
    setParam(m, d, "Attack", 2.0f);
    setParam(m, d, "Decay", 1200.0f);
    setParam(m, d, "Sustain", 0.25f);
    setParam(m, d, "Release", 350.0f);
    return m;
}

/**
 * Returns the index of a module type's first event input port (where notes arrive).
 *
 * Params:
 *   d = Module descriptor.
 *
 * Returns:
 *   Port index, or -1 when there is none.
 */
ptrdiff_t eventInputPort(const(ModuleDescriptor)* d) @safe pure nothrow @nogc {
    if (d is null) {
        return -1;
    }
    foreach (i, ref p; d.ports) {
        if (p.dir == PortDirection.input && p.kind == PortKind.event) {
            return cast(ptrdiff_t) i;
        }
    }
    return -1;
}

/**
 * Returns the index of a module type's first audio output port (what is wired to the Master Output).
 *
 * Params:
 *   d = Module descriptor.
 *
 * Returns:
 *   Port index, or -1 when there is none.
 */
ptrdiff_t audioOutputPort(const(ModuleDescriptor)* d) @safe pure nothrow @nogc {
    if (d is null) {
        return -1;
    }
    foreach (i, ref p; d.ports) {
        if (p.dir == PortDirection.output && isAudioPort(p.kind)) {
            return cast(ptrdiff_t) i;
        }
    }
    return -1;
}

/**
 * Reports whether a module type can play a part: it is registered, takes notes on an event input, and has an
 * audio output. Synths and MetaModules qualify; effects, controllers and the Master Output do not.
 *
 * Params:
 *   typeId = Module type id.
 *
 * Returns:
 *   True if playable.
 */
bool isPlayableInstrument(string typeId) pure {
    const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(typeId);
    return d !is null && eventInputPort(d) >= 0 && audioOutputPort(d) >= 0;
}

/**
 * Turns a choice into the module for the generated project.
 *
 * The module gets id, the role's name ("Bass" or "Piano") and position; everything else comes from the choice.
 * A module-type choice must be one of SELECTABLE_SYNTH_TYPES. A preset choice must hold a playable module
 * (isPlayableInstrument) whose parameter count matches its type.
 *
 * Params:
 *   role = Bass or piano.
 *   c = Choice.
 *   id = Module id to assign (non-zero).
 *   posX = Patchbay x position.
 *   posY = Patchbay y position.
 *   m = Receives the module.
 *   err = Receives the reason on failure.
 *
 * Returns:
 *   True on success.
 */
bool resolveInstrument(InstrumentRole role, const ref InstrumentChoice c, uint id, float posX, float posY,
        out SavedModule m, out string err) {
    immutable string name = role == InstrumentRole.bass ? "Bass" : "Piano";
    if (id == 0) {
        err = "Module id 0 is reserved";
        return false;
    }
    final switch (c.source) {
        case InstrumentSource.defaultSound:
            m = role == InstrumentRole.bass ? defaultBassModule(id) : defaultPianoModule(id);
            break;
        case InstrumentSource.moduleType: {
            bool listed = false;
            foreach (t; SELECTABLE_SYNTH_TYPES) {
                listed = listed || t == c.typeId;
            }
            if (!listed || !moduleWithDefaults(c.typeId, id, name, m)) {
                err = "Module type cannot be chosen for an instrument: " ~ c.typeId;
                return false;
            }
            break;
        }
        case InstrumentSource.presetFile: {
            const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(c.preset.typeId);
            if (d is null) {
                err = "Preset module type is not available: " ~ c.preset.typeId;
                return false;
            }
            if (!isPlayableInstrument(c.preset.typeId)) {
                err = "Preset module cannot play notes: " ~ d.displayName;
                return false;
            }
            if (c.preset.paramValues.length != d.params.length) {
                err = "Preset does not match its module type";
                return false;
            }
            m = copyModule(c.preset);
            break;
        }
    }
    m.id = id;
    m.name = name;
    m.posX = posX;
    m.posY = posY;
    m.muted = false;
    m.bypassed = false;
    return true;
}

/**
 * Sets a parameter by name; asserts that the module type has it.
 *
 * Params:
 *   m = Module whose paramValues follow d.
 *   d = Module descriptor.
 *   name = Parameter name.
 *   v = Plain (unnormalized) value.
 */
private void setParam(ref SavedModule m, const(ModuleDescriptor)* d, string name, float v) {
    immutable ptrdiff_t i = paramIndex(d, name);
    assert(i >= 0, "unknown parameter " ~ name);
    m.paramValues[i] = v;
}

/**
 * Deep-copies a module so the copy shares no arrays with the source.
 *
 * Params:
 *   src = Module.
 *
 * Returns:
 *   Copy.
 */
private SavedModule copyModule(const ref SavedModule src) @safe pure nothrow {
    SavedModule m;
    m.id = src.id;
    m.typeId = src.typeId;
    m.name = src.name;
    m.posX = src.posX;
    m.posY = src.posY;
    m.muted = src.muted;
    m.bypassed = src.bypassed;
    m.paramValues = src.paramValues.dup;
    m.extraBlob = src.extraBlob.dup;
    m.hasChildProject = src.hasChildProject;
    m.metaInputModuleId = src.metaInputModuleId;
    m.metaMacros = src.metaMacros;
    m.childProjectMsv = src.childProjectMsv.dup;
    return m;
}

enum uint PREVIEW_LINES_PER_BAR = 16;
enum uint PREVIEW_BARS = 12;
enum float PREVIEW_BASS_GAIN = 0.3f;
enum float PREVIEW_PIANO_GAIN = 0.22f;

/**
 * Builds a short project for listening to the default sounds (T13 owner check): 120 BPM, 4/4, C major,
 * I–vi–ii–V7 (C, Am, Dm, G7), one bar each. Bars 1–4 play the default bass alone (roots in octave 2), bars 5–8
 * the default piano alone (root-position chords from octave 4), bars 9–12 both. One pattern of 5 tracks (bass,
 * then four piano tracks) and one clip; every note is held to the next one and all tracks end with a note-off.
 * Wire gains are PREVIEW_BASS_GAIN and PREVIEW_PIANO_GAIN; T19 decides the generator's own levels.
 *
 * Returns:
 *   The project (Master Output id 1, Bass id 2, Piano id 3, pattern id 1).
 */
LoadedProject instrumentPreviewProject() {
    static immutable int[4] roots = [36, 45, 38, 43];
    static immutable int[][4] chords = [[60, 64, 67], [57, 60, 64], [62, 65, 69], [55, 59, 62, 65]];
    LoadedProject p;
    p.title = "Default instrument preview";
    p.bpm = 120.0;
    p.ticksPerLine = 6;
    SavedModule master;
    master.id = 1;
    master.typeId = "core.output";
    master.name = "Master Output";
    master.paramValues = [1.0f, 1.0f];
    SavedModule bass = defaultBassModule(2);
    bass.posX = 120.0f;
    SavedModule piano = defaultPianoModule(3);
    piano.posX = 120.0f;
    piano.posY = 120.0f;
    p.modules = [master, bass, piano];
    p.wires = [
        SavedWire(2, cast(ushort) audioOutputPort(ModuleRegistry.findByTypeId(bass.typeId)), 1, 0, PREVIEW_BASS_GAIN),
        SavedWire(3, cast(ushort) audioOutputPort(ModuleRegistry.findByTypeId(piano.typeId)), 1, 0, PREVIEW_PIANO_GAIN)
    ];
    enum uint tracks = 5;
    enum uint lines = PREVIEW_BARS * PREVIEW_LINES_PER_BAR;
    SavedPattern pat;
    pat.patternId = 1;
    pat.tracks = tracks;
    pat.lines = lines;
    pat.name = "Preview";
    pat.cells = new NoteCell[tracks * lines];
    void put(uint line, uint track, NoteCell c) {
        pat.cells[line * tracks + track] = c;
    }
    foreach (bar; 0 .. PREVIEW_BARS) {
        immutable uint line = bar * PREVIEW_LINES_PER_BAR;
        immutable size_t ch = bar % 4;
        immutable bool bassOn = bar < 4 || bar >= 8;
        immutable bool pianoOn = bar >= 4;
        if (bassOn) {
            put(line, 0, NoteCell.makeNote(roots[ch], 0.9f, 2));
        } else if (bar == 4) {
            put(line, 0, NoteCell.makeNoteOff(2));
        }
        if (pianoOn) {
            foreach (t; 0 .. 4) {
                put(line, 1 + t, t < chords[ch].length ? NoteCell.makeNote(chords[ch][t], 0.8f, 3)
                    : NoteCell.makeNoteOff(3));
            }
        }
    }
    foreach (t; 0 .. tracks) {
        put(lines - 1, t, NoteCell.makeNoteOff(t == 0 ? 2 : 3));
    }
    p.patterns = [pat];
    p.clips = [TimelineClip(1, 1, 0, 0, lines, 0, 0, false, false, false)];
    return p;
}
