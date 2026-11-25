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
 *   generateSkeleton() (T19) turns the generator's settings (SkeletonSpec) into a complete project following T05:
 *   one "Bass" pattern (one track: each block's bass note in octave 2, held to the next block) and one "Piano"
 *   pattern (four tracks: root-position close voicing from octave 4, one chord note per track), each as long as
 *   the whole progression, one clip each on lanes 0 and 1, and a loop over the progression. Without blocks the
 *   project has only the Master Output and one empty 4-bar pattern.
 *
 * Real-Time & Safety Contract:
 *   UI/off-RT only; builds documents, never touches the engine or the session. Functions that look up the
 *   module registry are @system because ModuleRegistry.findByTypeId() is.
 *
 * Dependencies:
 *   Internal: app.{chord_progression,music_theory}, graph.module_api, graph.port, graph.registry, io.project_format,
 *             sequencer.{note,timeline}
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum InstrumentRole (bass, piano); enum InstrumentSource (defaultSound, moduleType, presetFile)
 *   - struct InstrumentChoice (defaults(), ofType(), ofPreset(), label())
 *   - immutable SELECTABLE_SYNTH_TYPES; instrumentChoices()
 *   - defaultBassModule(), defaultPianoModule(), moduleWithDefaults(), resolveInstrument()
 *   - isPlayableInstrument(), audioOutputPort(), eventInputPort(), paramIndex()
 *   - instrumentPreviewProject() (listening test for the default sounds; dracker --sound-check=<file.wav>)
 *   - struct SkeletonSpec; validateSpec(), specLinesPerBeat(), specLinesPerBar(), blockLines(), totalLines(),
 *     generateSkeleton() (T19): settings to a complete LoadedProject
 *
 * See_Also:
 *   docs/todo.md (T06, T13, T19)
 */
module app.skeleton_gen;

import app.chord_progression : BLOCK_HALF_BARS, chordIntervals, ChordBlock, resolveChord, ResolvedChord;
import app.factory_presets : factoryModule, FactoryPreset, findFactoryPreset;
import app.instrument_library : InstrumentLibrary, LibraryEntry, PresetOrigin;
import app.music_theory : MusicalKey;
import graph.module_api : ModuleDescriptor;
import graph.port : isAudioPort, PortDirection, PortKind;
import graph.registry : ModuleRegistry;
import io.project_format : isValidKey, isValidTempo, isValidTimeSignature, LoadedPreset, LoadedProject, MAX_LINES,
    MAX_STRING_LEN, SavedModule, SavedPattern, SavedWire;
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
    presetFile = 2,
    libraryPreset = 3
}

/**
 * Module types offered in the instrument dropdowns besides the default sound (T06): pitched synths that make
 * sound without a loaded sample.
 */
immutable string[] SELECTABLE_SYNTH_TYPES = ["synth.analog_gen", "synth.fm_synth", "synth.spectravoice"];

/**
 * What plays one part: the default sound, a module type with its defaults, a library preset, or a module from
 * a preset file.
 */
struct InstrumentChoice {
    InstrumentSource source = InstrumentSource.defaultSound;
    string typeId;
    string presetName;
    string presetPath;
    PresetOrigin origin = PresetOrigin.bundled;
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
     * Returns the choice of a playable preset loaded from an InstrumentLibrary entry.
     *
     * Params:
     *   entry = Library metadata entry.
     *   p = Loaded preset document.
     *
     * Returns:
     *   Choice carrying a copy of the module.
     */
    static InstrumentChoice ofLibrary(const ref LibraryEntry entry, const ref LoadedPreset p) @safe pure nothrow {
        InstrumentChoice c;
        c.source = InstrumentSource.libraryPreset;
        c.typeId = p.mod.typeId;
        c.presetName = entry.name.length > 0 ? entry.name : (p.presetName.length > 0 ? p.presetName : p.mod.name);
        c.presetPath = entry.path;
        c.origin = entry.origin;
        c.preset = copyModule(p.mod);
        return c;
    }

    /**
     * Returns the text shown for this choice in a dropdown.
     *
     * Returns:
     *   "Default", the module type's display name, library preset name, or "Preset: <name>".
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
            case InstrumentSource.libraryPreset:
                return origin == PresetOrigin.user ? presetName ~ " (user)" : presetName;
        }
    }
}

/**
 * Lists the built-in module choices offered when no InstrumentLibrary is supplied: Default followed by each
 * registered module type in SELECTABLE_SYNTH_TYPES order.
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
 * Lists the choices offered in an instrument dropdown from an InstrumentLibrary: Default, then every playable
 * bundled preset, then every playable user preset. Falls back to instrumentChoices() when library is null.
 *
 * Params:
 *   library = Library to query (may be null).
 *
 * Returns:
 *   Ordered choices ending before the panel's "Load preset file…" entry.
 */
InstrumentChoice[] instrumentChoices(InstrumentLibrary library) {
    if (library is null) {
        return instrumentChoices();
    }
    InstrumentChoice[] list = [InstrumentChoice.defaults()];
    foreach (passOrigin; [PresetOrigin.bundled, PresetOrigin.user]) {
        foreach (ref entry; library.entries()) {
            if (!entry.playable || entry.origin != passOrigin) {
                continue;
            }
            LoadedPreset loaded;
            string err;
            if (!library.load(entry, loaded, err)) {
                continue;
            }
            list ~= InstrumentChoice.ofLibrary(entry, loaded);
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
 * Returns the default bass: the bundled Electric Bass preset, an Analog Generator playing a saw through a low,
 * slightly resonant filter.
 *
 * Params:
 *   id = Module id to assign.
 *
 * Returns:
 *   Module named "Bass".
 */
SavedModule defaultBassModule(uint id) {
    return factoryDefault("Electric Bass", "Bass", id);
}

/**
 * Returns the default piano: the bundled Electric Piano preset, an FM Synth. Algorithm 2 has two carriers:
 * operator 1 with a gentle same-ratio modulator (the body) and operator 3 modulated by operator 5 at ratio 14 (the
 * tine). Operator 4 is silent so operator 2 is a plain sine modulator; the decay is long and the sustain low, like
 * a struck key.
 *
 * Params:
 *   id = Module id to assign.
 *
 * Returns:
 *   Module named "Piano".
 */
SavedModule defaultPianoModule(uint id) {
    return factoryDefault("Electric Piano", "Piano", id);
}

/**
 * Builds a module from a bundled preset under a role name.
 *
 * Params:
 *   presetName = Name in FACTORY_PRESETS.
 *   moduleName = Name the module gets.
 *   id = Module id to assign.
 *
 * Returns:
 *   The module.
 */
private SavedModule factoryDefault(string presetName, string moduleName, uint id) {
    immutable(FactoryPreset)* p = findFactoryPreset(presetName);
    assert(p !is null, "missing bundled preset " ~ presetName);
    SavedModule m;
    string err;
    immutable bool ok = factoryModule(*p, id, m, err);
    assert(ok, err);
    m.name = moduleName;
    return m;
}

/**
 * Resolves the default Bass or Piano module from the bundled preset in library ("Electric Bass" / "Electric Piano"),
 * falling back to the built-in FACTORY_PRESETS constants when the library or bundled file is missing or invalid.
 *
 * Params:
 *   role = Bass or piano.
 *   id = Module id to assign (non-zero).
 *   library = Library to search for the bundled preset (may be null).
 *
 * Returns:
 *   Resolved default module named "Bass" or "Piano".
 */
SavedModule resolveDefaultModule(InstrumentRole role, uint id, InstrumentLibrary library = null) {
    immutable string presetName = role == InstrumentRole.bass ? "Electric Bass" : "Electric Piano";
    immutable string roleName = role == InstrumentRole.bass ? "Bass" : "Piano";
    if (library !is null) {
        foreach (ref entry; library.entries()) {
            if (entry.origin != PresetOrigin.bundled || entry.name != presetName || !entry.playable) {
                continue;
            }
            LoadedPreset loaded;
            string err;
            if (!library.load(entry, loaded, err)) {
                continue;
            }
            const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(loaded.mod.typeId);
            if (d is null || !isPlayableInstrument(loaded.mod.typeId)
                    || loaded.mod.paramValues.length != d.params.length) {
                continue;
            }
            SavedModule m = copyModule(loaded.mod);
            m.id = id;
            m.name = roleName;
            m.posX = 0.0f;
            m.posY = 0.0f;
            m.muted = false;
            m.bypassed = false;
            return m;
        }
    }
    return role == InstrumentRole.bass ? defaultBassModule(id) : defaultPianoModule(id);
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
 * A module-type choice must be one of SELECTABLE_SYNTH_TYPES. A preset or library choice must hold a playable
 * module (isPlayableInstrument) whose parameter count matches its type.
 *
 * Params:
 *   role = Bass or piano.
 *   c = Choice.
 *   id = Module id to assign (non-zero).
 *   posX = Patchbay x position.
 *   posY = Patchbay y position.
 *   m = Receives the module.
 *   err = Receives the reason on failure.
 *   library = Optional library for resolving defaultSound from bundled files.
 *
 * Returns:
 *   True on success.
 */
bool resolveInstrument(InstrumentRole role, const ref InstrumentChoice c, uint id, float posX, float posY,
        out SavedModule m, out string err, InstrumentLibrary library = null) {
    immutable string name = role == InstrumentRole.bass ? "Bass" : "Piano";
    if (id == 0) {
        err = "Module id 0 is reserved";
        return false;
    }
    final switch (c.source) {
        case InstrumentSource.defaultSound:
            m = resolveDefaultModule(role, id, library);
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
        case InstrumentSource.presetFile:
        case InstrumentSource.libraryPreset: {
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

enum float SKELETON_BASS_GAIN = PREVIEW_BASS_GAIN;
enum float SKELETON_PIANO_GAIN = PREVIEW_PIANO_GAIN;
enum float SKELETON_BASS_VELOCITY = 0.9f;
enum float SKELETON_PIANO_VELOCITY = 0.8f;
enum int SKELETON_BASS_OCTAVE_BASE = 36;
enum int SKELETON_PIANO_OCTAVE_BASE = 60;
enum uint SKELETON_EMPTY_BARS = 4;
enum uint SKELETON_EMPTY_TRACKS = 4;
enum uint SKELETON_PIANO_TRACKS = 4;

/**
 * Everything the generator panel collects. Defaults match a new empty project (Untitled, 125 BPM, 6 ticks per
 * line, 4/4, C major) with no chords and the default instruments.
 */
struct SkeletonSpec {
    string title = "Untitled";
    double bpm = 125.0;
    uint ticksPerLine = 6;
    uint timeSigNumerator = 4;
    uint timeSigDenominator = 4;
    MusicalKey key;
    ChordBlock[] blocks;
    InstrumentChoice bass;
    InstrumentChoice piano;
}

/**
 * Returns the lines in one beat for a spec's time signature (16 divided by the denominator).
 *
 * Params:
 *   spec = Settings (time signature must be valid).
 *
 * Returns:
 *   Lines per beat.
 */
uint specLinesPerBeat(const ref SkeletonSpec spec) @safe pure nothrow @nogc {
    return spec.timeSigDenominator == 0 ? 4 : 16 / spec.timeSigDenominator;
}

/**
 * Returns the lines in one bar for a spec's time signature.
 *
 * Params:
 *   spec = Settings (time signature must be valid).
 *
 * Returns:
 *   Lines per bar.
 */
uint specLinesPerBar(const ref SkeletonSpec spec) @safe pure nothrow @nogc {
    return spec.timeSigNumerator * specLinesPerBeat(spec);
}

/**
 * Returns how many lines a block lasts: halfBars × lines per bar ÷ 2.
 *
 * Params:
 *   b = Block.
 *   linesPerBar = Lines in one bar.
 *
 * Returns:
 *   Lines (rounded down; validateSpec() refuses half-bar blocks when a bar has an odd number of lines).
 */
ulong blockLines(const ref ChordBlock b, uint linesPerBar) @safe pure nothrow @nogc {
    return cast(ulong) b.halfBars * linesPerBar / 2;
}

/**
 * Returns the length of a spec's progression in lines.
 *
 * Params:
 *   spec = Settings.
 *
 * Returns:
 *   Sum of blockLines() over all blocks (0 without blocks).
 */
ulong totalLines(const ref SkeletonSpec spec) @safe pure nothrow @nogc {
    ulong total = 0;
    immutable uint bar = specLinesPerBar(spec);
    foreach (ref b; spec.blocks) {
        total += blockLines(b, bar);
    }
    return total;
}

/**
 * Checks a spec before generation and explains the first problem in a sentence for the panel.
 *
 * Params:
 *   spec = Settings.
 *   err = Receives the reason when invalid.
 *   library = Optional library for resolving defaultSound from bundled presets.
 *
 * Returns:
 *   True when generateSkeleton() will succeed (apart from out-of-memory).
 */
bool validateSpec(const ref SkeletonSpec spec, out string err, InstrumentLibrary library = null) {
    if (spec.title.length > MAX_STRING_LEN) {
        err = "The title is too long";
        return false;
    }
    if (!isValidTempo(spec.bpm, spec.ticksPerLine)) {
        err = "Tempo must be 20–999 BPM with 1–255 ticks per line";
        return false;
    }
    if (!isValidTimeSignature(spec.timeSigNumerator, spec.timeSigDenominator)) {
        err = "The time signature must be 1–16 beats over 2, 4, 8 or 16";
        return false;
    }
    if (!isValidKey(spec.key.tonic, spec.key.mode)) {
        err = "Unknown key";
        return false;
    }
    immutable uint bar = specLinesPerBar(spec);
    foreach (i, ref b; spec.blocks) {
        bool allowed = false;
        foreach (h; BLOCK_HALF_BARS) {
            allowed = allowed || h == b.halfBars;
        }
        if (!allowed) {
            err = "A block must last ½, 1, 2 or 4 bars";
            return false;
        }
        if (b.halfBars % 2 == 1 && bar % 2 == 1) {
            err = "Half-bar blocks need a bar with an even number of lines; this time signature has "
                ~ uintText(bar) ~ " lines per bar";
            return false;
        }
    }
    if (totalLines(spec) > MAX_LINES) {
        err = "The progression is " ~ uintText(cast(uint) totalLines(spec)) ~ " lines long; the limit is "
            ~ uintText(cast(uint) MAX_LINES) ~ " lines";
        return false;
    }
    if (spec.blocks.length > 0) {
        SavedModule m;
        if (!resolveInstrument(InstrumentRole.bass, spec.bass, 2, 0.0f, 0.0f, m, err, library)) {
            err = "Bass: " ~ err;
            return false;
        }
        if (!resolveInstrument(InstrumentRole.piano, spec.piano, 3, 0.0f, 0.0f, m, err, library)) {
            err = "Piano: " ~ err;
            return false;
        }
    }
    return true;
}

/**
 * Builds the skeleton project for a spec (T05). Module ids: Master Output 1, Bass 2, Piano 3; pattern ids: Bass 1,
 * Piano 2 (or the empty pattern 1); clip ids 1 and 2. Every note and note-off carries its module id. Each bass
 * note is the block's bass note (the slash bass, else the root) in MIDI 36–47; each piano chord is the root in
 * MIDI 60–71 with the chord's intervals stacked above it, one note per track, triads leaving track 4 silent
 * (a note-off there when the previous chord used it). Notes are held until the next block; the last line of
 * both patterns holds a note-off on every track that does not start a note there. Wire gains are SKELETON_BASS_GAIN and SKELETON_PIANO_GAIN (the
 * levels of the approved sound check).
 *
 * Params:
 *   spec = Settings.
 *   proj = Receives the project.
 *   err = Receives validateSpec()'s reason on failure.
 *   library = Optional library for resolving defaultSound from bundled presets.
 *
 * Returns:
 *   True on success.
 */
bool generateSkeleton(const ref SkeletonSpec spec, out LoadedProject proj, out string err,
        InstrumentLibrary library = null) {
    if (!validateSpec(spec, err, library)) {
        return false;
    }
    proj.title = spec.title.length > 0 ? spec.title : "Untitled";
    proj.author = "Dracker";
    proj.bpm = spec.bpm;
    proj.ticksPerLine = spec.ticksPerLine;
    proj.timeSigNumerator = cast(ubyte) spec.timeSigNumerator;
    proj.timeSigDenominator = cast(ubyte) spec.timeSigDenominator;
    proj.keyTonic = spec.key.tonic;
    proj.keyMode = cast(ubyte) spec.key.mode;

    SavedModule master;
    master.id = 1;
    master.typeId = "core.output";
    master.name = "Master Output";
    master.paramValues = [1.0f, 1.0f];
    master.posX = 520.0f;
    master.posY = 160.0f;
    proj.modules = [master];

    immutable uint bar = specLinesPerBar(spec);
    if (spec.blocks.length == 0) {
        SavedPattern empty;
        empty.patternId = 1;
        empty.tracks = SKELETON_EMPTY_TRACKS;
        empty.lines = SKELETON_EMPTY_BARS * bar;
        empty.name = "Pattern 01";
        empty.cells = new NoteCell[empty.tracks * empty.lines];
        proj.patterns = [empty];
        proj.clips = [TimelineClip(1, 1, 0, 0, empty.lines, 0, 0, false, false, false)];
        return true;
    }

    SavedModule bass;
    SavedModule piano;
    if (!resolveInstrument(InstrumentRole.bass, spec.bass, 2, 200.0f, 80.0f, bass, err, library)
            || !resolveInstrument(InstrumentRole.piano, spec.piano, 3, 200.0f, 240.0f, piano, err, library)) {
        return false;
    }
    proj.modules ~= bass;
    proj.modules ~= piano;
    proj.wires = [
        SavedWire(2, cast(ushort) audioOutputPort(ModuleRegistry.findByTypeId(bass.typeId)), 1, 0, SKELETON_BASS_GAIN),
        SavedWire(3, cast(ushort) audioOutputPort(ModuleRegistry.findByTypeId(piano.typeId)), 1, 0, SKELETON_PIANO_GAIN)
    ];

    immutable uint lines = cast(uint) totalLines(spec);
    SavedPattern bp;
    bp.patternId = 1;
    bp.tracks = 1;
    bp.lines = lines;
    bp.name = "Bass";
    bp.cells = new NoteCell[lines];
    SavedPattern pp;
    pp.patternId = 2;
    pp.tracks = SKELETON_PIANO_TRACKS;
    pp.lines = lines;
    pp.name = "Piano";
    pp.cells = new NoteCell[SKELETON_PIANO_TRACKS * lines];

    uint line = 0;
    bool fourthUsed = false;
    foreach (ref b; spec.blocks) {
        immutable ResolvedChord rc = resolveChord(b.chord, spec.key);
        bp.cells[line] = NoteCell.makeNote(SKELETON_BASS_OCTAVE_BASE + rc.bassPc, SKELETON_BASS_VELOCITY, 2);
        immutable int root = SKELETON_PIANO_OCTAVE_BASE + rc.rootPc;
        immutable(ubyte)[] iv = chordIntervals(b.chord.quality);
        foreach (t; 0 .. SKELETON_PIANO_TRACKS) {
            NoteCell c;
            if (t < iv.length) {
                c = NoteCell.makeNote(root + iv[t], SKELETON_PIANO_VELOCITY, 3);
            } else if (fourthUsed) {
                c = NoteCell.makeNoteOff(3);
            }
            pp.cells[line * SKELETON_PIANO_TRACKS + t] = c;
        }
        fourthUsed = iv.length > 3;
        line += cast(uint) blockLines(b, bar);
    }
    if (bp.cells[lines - 1].note == 0) {
        bp.cells[lines - 1] = NoteCell.makeNoteOff(2);
    }
    foreach (t; 0 .. SKELETON_PIANO_TRACKS) {
        if (pp.cells[(lines - 1) * SKELETON_PIANO_TRACKS + t].note == 0) {
            pp.cells[(lines - 1) * SKELETON_PIANO_TRACKS + t] = NoteCell.makeNoteOff(3);
        }
    }
    proj.patterns = [bp, pp];
    proj.clips = [TimelineClip(1, 1, 0, 0, lines, 0, 0, false, false, false),
        TimelineClip(2, 2, 0, 0, lines, 1, 0, false, false, false)];
    proj.loopStartLine = 0;
    proj.loopEndLine = lines;
    return true;
}

/**
 * Formats an unsigned integer in decimal.
 *
 * Params:
 *   v = Value.
 *
 * Returns:
 *   Text.
 */
private string uintText(uint v) @safe pure nothrow {
    if (v < 10) {
        return [cast(immutable char)('0' + v)];
    }
    return uintText(v / 10) ~ uintText(v % 10);
}
