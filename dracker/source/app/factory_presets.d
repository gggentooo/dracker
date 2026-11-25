/**
 * File:         source/app/factory_presets.d
 * Module:       app.factory_presets
 * Phase:        Instrument library — T46 (bundled presets: definitions, files, and sound check)
 *
 * Purpose:
 *   The presets that ship with Dracker (decisions T36, T37): twelve instruments and four effects, defined here as
 *   parameter sets by parameter name so changes can be reviewed as text. writeFactoryPresets() writes them as
 *   .msym files into <dir>/<Group>/<Name>.msym (the checked-in copies live in resources/presets and are packaged
 *   into the app); a unit test fails when those files and this table differ. factoryPreviewProject() builds a
 *   short project for listening to one preset: instruments play a four-bar phrase (basses a bass line, the drum
 *   kit and the kick a beat, the others I–vi–ii–V7 chords), effects are heard on the Electric Piano, four bars
 *   dry and then the same four bars through the effect.
 *   The skeleton generator's default bass and piano are the Electric Bass and Electric Piano presets.
 *
 * Real-Time & Safety Contract:
 *   UI/off-RT only; builds documents and writes files, never touches the engine or the session.
 *
 * Dependencies:
 *   Internal: graph.module_api, graph.port, graph.registry, io.project_format, sequencer.{note,timeline}
 *   External: std.file, std.path
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ParamSetting; struct FactoryPreset; FACTORY_PRESETS; findFactoryPreset()
 *   - factoryModule(), factoryLoadedPreset(), factoryPresetBytes(), factoryPresetRelativePath(),
 *     writeFactoryPresets()
 *   - factoryPreviewProject(), factoryPreviewBars(), isInstrument(), FACTORY_PREVIEW_BPM
 *
 * See_Also:
 *   docs/todo.md (T36, T37, T46), source/app/instrument_library.d, source/app/skeleton_gen.d
 */
module app.factory_presets;

import graph.module_api : ModuleDescriptor;
import graph.port : PortDirection, PortKind;
import graph.registry : ModuleRegistry;
import io.project_format : LoadedPreset, LoadedProject, SavedModule, SavedPattern, SavedWire, serializePreset;
import sequencer.note : NoteCell;
import sequencer.timeline : TimelineClip;

/**
 * One parameter of a preset, by the parameter's display name.
 */
struct ParamSetting {
    string name;
    float value;
}

/**
 * A bundled preset: its name, its group in the instrument list, the module type, and the parameters that differ
 * from (or are pinned to) the module's defaults.
 */
struct FactoryPreset {
    string name;
    string group;
    string typeId;
    immutable(ParamSetting)[] params;
}

enum double FACTORY_PREVIEW_BPM = 120.0;
enum uint FACTORY_PREVIEW_LINES_PER_BAR = 16;

/**
 * The bundled presets, in the order they are listed in T36.
 */
immutable FactoryPreset[] FACTORY_PRESETS = [
    FactoryPreset("Electric Bass", "Bass", "synth.analog_gen", [
        ParamSetting("Waveform", 2.0f), ParamSetting("Unison", 1.0f), ParamSetting("Detune", 0.05f),
        ParamSetting("Cutoff", 900.0f), ParamSetting("Resonance", 0.25f), ParamSetting("Attack", 0.003f),
        ParamSetting("Decay", 0.25f), ParamSetting("Sustain", 0.6f), ParamSetting("Release", 0.12f)]),
    FactoryPreset("Synth Bass", "Bass", "synth.analog_gen", [
        ParamSetting("Waveform", 3.0f), ParamSetting("Unison", 2.0f), ParamSetting("Detune", 0.12f),
        ParamSetting("Cutoff", 1400.0f), ParamSetting("Resonance", 0.45f), ParamSetting("Attack", 0.002f),
        ParamSetting("Decay", 0.18f), ParamSetting("Sustain", 0.35f), ParamSetting("Release", 0.1f)]),
    FactoryPreset("Electric Piano", "Keys", "synth.fm_synth", [
        ParamSetting("Algorithm", 2.0f), ParamSetting("Feedback", 0.05f), ParamSetting("Op1 Ratio", 1.0f),
        ParamSetting("Op2 Ratio", 1.0f), ParamSetting("Op3 Ratio", 1.0f), ParamSetting("Op4 Ratio", 1.0f),
        ParamSetting("Op5 Ratio", 14.0f), ParamSetting("Op1 Level", 1.0f), ParamSetting("Op2 Level", 0.35f),
        ParamSetting("Op3 Level", 0.3f), ParamSetting("Op4 Level", 0.0f), ParamSetting("Op5 Level", 0.18f),
        ParamSetting("Attack", 2.0f), ParamSetting("Decay", 2500.0f), ParamSetting("Sustain", 0.0f),
        ParamSetting("Release", 200.0f)]),
    FactoryPreset("Bright Piano", "Keys", "synth.fm_synth", [
        ParamSetting("Algorithm", 2.0f), ParamSetting("Feedback", 0.1f), ParamSetting("Op1 Ratio", 1.0f),
        ParamSetting("Op2 Ratio", 3.0f), ParamSetting("Op3 Ratio", 1.0f), ParamSetting("Op4 Ratio", 1.0f),
        ParamSetting("Op5 Ratio", 7.0f), ParamSetting("Op1 Level", 1.0f), ParamSetting("Op2 Level", 0.5f),
        ParamSetting("Op3 Level", 0.35f), ParamSetting("Op4 Level", 0.0f), ParamSetting("Op5 Level", 0.3f),
        ParamSetting("Attack", 1.0f), ParamSetting("Decay", 1800.0f), ParamSetting("Sustain", 0.0f),
        ParamSetting("Release", 200.0f)]),
    FactoryPreset("Organ", "Keys", "synth.fm_synth", [
        ParamSetting("Algorithm", 5.0f), ParamSetting("Feedback", 0.0f), ParamSetting("Op1 Ratio", 1.0f),
        ParamSetting("Op2 Ratio", 2.0f), ParamSetting("Op3 Ratio", 3.0f), ParamSetting("Op4 Ratio", 4.0f),
        ParamSetting("Op5 Ratio", 0.5f), ParamSetting("Op1 Level", 1.0f), ParamSetting("Op2 Level", 0.7f),
        ParamSetting("Op3 Level", 0.5f), ParamSetting("Op4 Level", 0.35f), ParamSetting("Op5 Level", 0.5f),
        ParamSetting("Attack", 3.0f), ParamSetting("Decay", 50.0f), ParamSetting("Sustain", 1.0f),
        ParamSetting("Release", 60.0f)]),
    FactoryPreset("Bell", "Keys", "synth.fm_synth", [
        ParamSetting("Algorithm", 3.0f), ParamSetting("Feedback", 0.0f), ParamSetting("Op1 Ratio", 1.0f),
        ParamSetting("Op2 Ratio", 3.5f), ParamSetting("Op3 Ratio", 7.0f), ParamSetting("Op4 Ratio", 1.0f),
        ParamSetting("Op5 Ratio", 1.0f), ParamSetting("Op1 Level", 0.6f), ParamSetting("Op2 Level", 0.6f),
        ParamSetting("Op3 Level", 0.25f), ParamSetting("Op4 Level", 0.0f), ParamSetting("Op5 Level", 0.0f),
        ParamSetting("Attack", 1.0f), ParamSetting("Decay", 2500.0f), ParamSetting("Sustain", 0.0f),
        ParamSetting("Release", 600.0f)]),
    FactoryPreset("Warm Pad", "Pads & Leads", "synth.analog_gen", [
        ParamSetting("Waveform", 2.0f), ParamSetting("Unison", 4.0f), ParamSetting("Detune", 0.35f),
        ParamSetting("Cutoff", 1800.0f), ParamSetting("Resonance", 0.15f), ParamSetting("Attack", 0.6f),
        ParamSetting("Decay", 1.0f), ParamSetting("Sustain", 0.8f), ParamSetting("Release", 1.2f)]),
    FactoryPreset("Strings", "Pads & Leads", "synth.spectravoice", [
        ParamSetting("Profile", 1.0f), ParamSetting("Bandwidth", 0.6f), ParamSetting("Attack", 180.0f),
        ParamSetting("Release", 600.0f)]),
    FactoryPreset("Saw Lead", "Pads & Leads", "synth.analog_gen", [
        ParamSetting("Waveform", 2.0f), ParamSetting("Unison", 2.0f), ParamSetting("Detune", 0.2f),
        ParamSetting("Cutoff", 6000.0f), ParamSetting("Resonance", 0.3f), ParamSetting("Attack", 0.005f),
        ParamSetting("Decay", 0.3f), ParamSetting("Sustain", 0.75f), ParamSetting("Release", 0.2f)]),
    FactoryPreset("Pluck", "Pads & Leads", "synth.fm_synth", [
        ParamSetting("Algorithm", 2.0f), ParamSetting("Feedback", 0.0f), ParamSetting("Op1 Ratio", 1.0f),
        ParamSetting("Op2 Ratio", 2.0f), ParamSetting("Op3 Ratio", 1.0f), ParamSetting("Op4 Ratio", 1.0f),
        ParamSetting("Op5 Ratio", 1.0f), ParamSetting("Op1 Level", 1.0f), ParamSetting("Op2 Level", 0.6f),
        ParamSetting("Op3 Level", 0.0f), ParamSetting("Op4 Level", 0.0f), ParamSetting("Op5 Level", 0.0f),
        ParamSetting("Attack", 1.0f), ParamSetting("Decay", 220.0f), ParamSetting("Sustain", 0.0f),
        ParamSetting("Release", 150.0f)]),
    FactoryPreset("Drum Kit", "Drums", "synth.drumsynth", [
        ParamSetting("Kit Decay", 1.0f), ParamSetting("Tone", 0.5f), ParamSetting("Snappy", 0.5f),
        ParamSetting("Pan Spread", 0.4f), ParamSetting("Master Vol", 0.8f)]),
    FactoryPreset("Kick", "Drums", "synth.kicker", [
        ParamSetting("Waveform", 0.0f), ParamSetting("Pitch Start", 180.0f), ParamSetting("Pitch End", 45.0f),
        ParamSetting("Sweep Time", 40.0f), ParamSetting("Decay", 300.0f), ParamSetting("Click Drive", 0.4f)]),
    FactoryPreset("Room Reverb", "Effects", "fx.reverb", [
        ParamSetting("Dry", 1.0f), ParamSetting("Wet", 0.45f), ParamSetting("Room Size", 0.6f),
        ParamSetting("Damping", 6000.0f), ParamSetting("Stereo Width", 1.0f), ParamSetting("Pre-Delay", 8.0f),
        ParamSetting("Freeze", 0.0f)]),
    FactoryPreset("Tempo Delay", "Effects", "fx.delay", [
        ParamSetting("Dry", 1.0f), ParamSetting("Wet", 0.5f), ParamSetting("Delay L", 300.0f),
        ParamSetting("Delay R", 400.0f), ParamSetting("Unit", 2.0f), ParamSetting("Inverse", 0.0f)]),
    FactoryPreset("Bus Compressor", "Effects", "fx.compressor", [
        ParamSetting("Threshold", -24.0f), ParamSetting("Ratio", 4.0f), ParamSetting("Attack", 20.0f),
        ParamSetting("Release", 150.0f), ParamSetting("Makeup", 6.0f), ParamSetting("Mode", 0.0f)]),
    FactoryPreset("Warm Overdrive", "Effects", "fx.distortion", [
        ParamSetting("Mode", 3.0f), ParamSetting("Drive", 8.0f), ParamSetting("Bit Depth", 24.0f),
        ParamSetting("SR Div", 1.0f), ParamSetting("Mix", 1.0f)])
];

/**
 * Finds a bundled preset by name.
 *
 * Params:
 *   name = Preset name, e.g. "Electric Bass".
 *
 * Returns:
 *   The preset, or null.
 */
immutable(FactoryPreset)* findFactoryPreset(string name) @safe pure nothrow @nogc {
    foreach (i; 0 .. FACTORY_PRESETS.length) {
        if (FACTORY_PRESETS[i].name == name) {
            return &FACTORY_PRESETS[i];
        }
    }
    return null;
}

/**
 * Builds a preset's module: every parameter at the module default, then the preset's settings applied by name.
 *
 * Params:
 *   p = Preset.
 *   id = Module id to assign.
 *   m = Receives the module (named after the preset).
 *   err = Receives the reason on failure.
 *
 * Returns:
 *   False when the module type is not registered or a parameter name does not exist.
 */
bool factoryModule(const ref FactoryPreset p, uint id, out SavedModule m, out string err) {
    const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(p.typeId);
    if (d is null) {
        err = "Module type is not available: " ~ p.typeId;
        return false;
    }
    m.id = id;
    m.typeId = p.typeId;
    m.name = p.name;
    m.paramValues = new float[d.params.length];
    foreach (i, ref dp; d.params) {
        m.paramValues[i] = dp.defaultVal;
    }
    foreach (ref s; p.params) {
        bool found = false;
        foreach (i, ref dp; d.params) {
            if (dp.name == s.name) {
                m.paramValues[i] = s.value;
                found = true;
                break;
            }
        }
        if (!found) {
            err = p.name ~ ": " ~ d.displayName ~ " has no parameter \"" ~ s.name ~ "\"";
            return false;
        }
    }
    return true;
}

/**
 * Returns a preset as it is stored in its file: preset name and module name are the preset's name, module id 1.
 *
 * Params:
 *   p = Preset.
 *   preset = Receives the document.
 *   err = Receives the reason on failure.
 *
 * Returns:
 *   True on success.
 */
bool factoryLoadedPreset(const ref FactoryPreset p, out LoadedPreset preset, out string err) {
    preset.presetName = p.name;
    return factoryModule(p, 1, preset.mod, err);
}

/**
 * Returns the exact bytes of a preset's .msym file.
 *
 * Params:
 *   p = Preset.
 *   bytes = Receives the file content.
 *   err = Receives the reason on failure.
 *
 * Returns:
 *   True on success.
 */
bool factoryPresetBytes(const ref FactoryPreset p, out ubyte[] bytes, out string err) {
    LoadedPreset preset;
    return factoryLoadedPreset(p, preset, err) && serializePreset(preset, bytes, err);
}

/**
 * Returns a preset's file path inside a preset folder: "<Group>/<Name>.msym".
 *
 * Params:
 *   p = Preset.
 *
 * Returns:
 *   Relative path.
 */
string factoryPresetRelativePath(const ref FactoryPreset p) {
    import std.path : buildPath;

    return buildPath(p.group, p.name ~ ".msym");
}

/**
 * Writes every bundled preset below a folder, creating the group folders.
 *
 * Params:
 *   dir = Target folder (for the checked-in copies: resources/presets).
 *   written = Receives the paths written.
 *   err = Receives the reason on failure.
 *
 * Returns:
 *   True when all files were written.
 */
bool writeFactoryPresets(string dir, out string[] written, out string err) {
    import std.file : mkdirRecurse, write;
    import std.path : buildPath, dirName;

    foreach (ref p; FACTORY_PRESETS) {
        ubyte[] bytes;
        if (!factoryPresetBytes(p, bytes, err)) {
            return false;
        }
        immutable string path = buildPath(dir, factoryPresetRelativePath(p));
        try {
            mkdirRecurse(dirName(path));
            write(path, bytes);
        } catch (Exception ex) {
            err = "Could not write " ~ path ~ ": " ~ ex.msg;
            return false;
        }
        written ~= path;
    }
    return true;
}

/**
 * Returns how many bars a preset's preview lasts: 4 bars for both instruments and effect previews.
 *
 * Params:
 *   p = Preset.
 *
 * Returns:
 *   Bars of 16 lines at FACTORY_PREVIEW_BPM.
 */
uint factoryPreviewBars(const ref FactoryPreset p) {
    cast(void) p;
    return 4;
}

/**
 * Builds a project for listening to one preset (see decisions T46 and T62). Module ids: Master Output 1;
 * source instrument 2; when wet is true for an effect, the effect module 3 wired in series. Room Reverb and
 * Tempo Delay use short Electric Piano chords with rests, Bus Compressor uses a dynamic Drum Kit beat with
 * loud and quiet hits, and Warm Overdrive uses the Electric Bass line.
 *
 * Params:
 *   p = Preset.
 *   proj = Receives the project.
 *   err = Receives the reason on failure.
 *   wet = When p is an effect, true wires it in series and false leaves the source dry.
 *
 * Returns:
 *   True on success.
 */
bool factoryPreviewProject(const ref FactoryPreset p, out LoadedProject proj, out string err, bool wet = true) {
    static immutable int[][4] chords = [[60, 64, 67], [57, 60, 64], [62, 65, 69], [55, 59, 62, 65]];
    static immutable int[8] bassLine = [36, 36, 48, 36, 33, 33, 45, 33];
    static immutable int[8] bassLine2 = [38, 38, 50, 38, 31, 31, 43, 35];
    enum uint bar = FACTORY_PREVIEW_LINES_PER_BAR;
    immutable uint bars = factoryPreviewBars(p);
    immutable uint lines = bars * bar;
    enum uint tracks = 4;

    proj.title = "Preview: " ~ p.name;
    proj.bpm = FACTORY_PREVIEW_BPM;
    proj.ticksPerLine = 6;
    SavedModule master;
    master.id = 1;
    master.typeId = "core.output";
    master.name = "Master Output";
    master.paramValues = [1.0f, 1.0f];
    proj.modules = [master];

    SavedPattern pat;
    pat.patternId = 1;
    pat.tracks = tracks;
    pat.lines = lines;
    pat.name = "Preview";
    pat.cells = new NoteCell[tracks * lines];
    void put(uint line, uint track, NoteCell c) {
        pat.cells[line * tracks + track] = c;
    }
    void chordBars(uint firstBar, ushort moduleId) {
        foreach (b; 0 .. 4) {
            immutable uint line = (firstBar + b) * bar;
            foreach (t; 0 .. tracks) {
                put(line, t, t < chords[b].length ? NoteCell.makeNote(chords[b][t], 0.8f, moduleId)
                    : NoteCell.makeNoteOff(moduleId));
            }
        }
        foreach (t; 0 .. tracks) {
            put((firstBar + 4) * bar - 1, t, NoteCell.makeNoteOff(moduleId));
        }
    }
    void staccatoChordBars(ushort moduleId) {
        foreach (b; 0 .. 4) {
            immutable uint line = b * bar;
            foreach (t; 0 .. chords[b].length) {
                put(line, cast(uint) t, NoteCell.makeNote(chords[b][t], 0.85f, moduleId));
                put(line + 2, cast(uint) t, NoteCell.makeNoteOff(moduleId));
            }
        }
    }
    void fillDrumKit(ushort moduleId) {
        foreach (b; 0 .. 4) {
            foreach (step; 0 .. 16) {
                immutable uint line = b * bar + step;
                if (step % 8 == 0 || (b == 3 && step == 10)) {
                    put(line, 0, NoteCell.makeNote(36, 0.95f, moduleId));
                }
                if (step % 8 == 4) {
                    put(line, 1, NoteCell.makeNote(38, 0.9f, moduleId));
                }
                if (step % 2 == 0) {
                    put(line, 2, NoteCell.makeNote(step == 14 ? 46 : 42, step % 4 == 0 ? 0.8f : 0.5f, moduleId));
                }
            }
        }
    }
    void fillCompressorBeat(ushort moduleId) {
        foreach (b; 0 .. 4) {
            put(b * bar + 0, 0, NoteCell.makeNote(36, 1.0f, moduleId));
            put(b * bar + 4, 0, NoteCell.makeNote(42, 0.22f, moduleId));
            put(b * bar + 8, 1, NoteCell.makeNote(38, 1.0f, moduleId));
            put(b * bar + 12, 0, NoteCell.makeNote(42, 0.22f, moduleId));
        }
    }
    void fillBass(ushort moduleId) {
        foreach (b; 0 .. 4) {
            foreach (i; 0 .. 8) {
                immutable int note = (b % 2 == 0 ? bassLine : bassLine2)[i];
                put(b * bar + i * 2, 0, NoteCell.makeNote(note, i % 4 == 0 ? 0.95f : 0.75f, moduleId));
            }
        }
        put(lines - 1, 0, NoteCell.makeNoteOff(moduleId));
    }

    if (!isInstrument(p)) {
        string sourcePresetName = "Electric Piano";
        float dryGain = 0.42f;
        float wetOutGain = 0.9f;
        if (p.typeId == "fx.compressor") {
            sourcePresetName = "Drum Kit";
            dryGain = 0.6f;
            wetOutGain = 0.7f;
        } else if (p.typeId == "fx.distortion") {
            sourcePresetName = "Electric Bass";
            dryGain = wet ? 0.9f : 0.5f;
            wetOutGain = 0.4f;
        }
        immutable(FactoryPreset)* srcPreset = findFactoryPreset(sourcePresetName);
        SavedModule srcMod;
        if (srcPreset is null || !factoryModule(*srcPreset, 2, srcMod, err)) {
            err = err.length > 0 ? err : (sourcePresetName ~ " preset is missing");
            return false;
        }
        proj.modules ~= srcMod;
        const(ModuleDescriptor)* sd = ModuleRegistry.findByTypeId(srcMod.typeId);
        immutable ptrdiff_t srcOut = firstPort(sd, PortDirection.output, true);
        if (srcOut < 0) {
            err = sourcePresetName ~ ": missing audio output port";
            return false;
        }
        if (wet) {
            SavedModule fx;
            if (!factoryModule(p, 3, fx, err)) {
                return false;
            }
            const(ModuleDescriptor)* fd = ModuleRegistry.findByTypeId(fx.typeId);
            immutable ptrdiff_t fxIn = firstPort(fd, PortDirection.input, true);
            immutable ptrdiff_t fxOut = firstPort(fd, PortDirection.output, true);
            if (fxIn < 0 || fxOut < 0) {
                err = p.name ~ ": the effect has no audio input or output";
                return false;
            }
            proj.modules ~= fx;
            proj.wires = [SavedWire(2, cast(ushort) srcOut, 3, cast(ushort) fxIn, dryGain),
                SavedWire(3, cast(ushort) fxOut, 1, 0, wetOutGain)];
        } else {
            proj.wires = [SavedWire(2, cast(ushort) srcOut, 1, 0, dryGain)];
        }
        if (p.typeId == "fx.compressor") {
            fillCompressorBeat(2);
        } else if (p.typeId == "fx.distortion") {
            fillBass(2);
        } else {
            staccatoChordBars(2);
        }
    } else {
        SavedModule inst;
        if (!factoryModule(p, 2, inst, err)) {
            return false;
        }
        proj.modules ~= inst;
        const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(inst.typeId);
        proj.wires = [SavedWire(2, cast(ushort) firstPort(d, PortDirection.output, true), 1, 0,
            p.group == "Drums" ? 0.5f : 0.3f)];
        if (p.typeId == "synth.drumsynth") {
            fillDrumKit(2);
        } else if (p.group == "Drums") {
            foreach (b; 0 .. 4) {
                foreach (beat; 0 .. 4) {
                    put(b * bar + beat * 4, 0, NoteCell.makeNote(36, 0.95f, 2));
                }
            }
        } else if (p.group == "Bass") {
            fillBass(2);
        } else {
            chordBars(0, 2);
        }
    }
    proj.patterns = [pat];
    proj.clips = [TimelineClip(1, 1, 0, 0, lines, 0, 0, false, false, false)];
    return true;
}

/**
 * Reports whether a preset's module takes notes and makes sound (an instrument) rather than processing audio.
 *
 * Params:
 *   p = Preset.
 *
 * Returns:
 *   True for instruments.
 */
bool isInstrument(const ref FactoryPreset p) {
    const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(p.typeId);
    if (d is null) {
        return false;
    }
    bool eventIn = false;
    foreach (ref port; d.ports) {
        eventIn = eventIn || (port.dir == PortDirection.input && port.kind == PortKind.event);
    }
    return eventIn && firstPort(d, PortDirection.output, true) >= 0 && firstPort(d, PortDirection.input, true) < 0;
}

/**
 * Returns the index of a descriptor's first port of a direction that carries audio (or, with audio = false,
 * events).
 *
 * Params:
 *   d = Module descriptor.
 *   dir = Port direction.
 *   audio = True for an audio port, false for an event port.
 *
 * Returns:
 *   Port index, or -1.
 */
private ptrdiff_t firstPort(const(ModuleDescriptor)* d, PortDirection dir, bool audio) {
    if (d is null) {
        return -1;
    }
    foreach (i, ref port; d.ports) {
        if (port.dir == dir && (audio ? port.kind == PortKind.audioStereo || port.kind == PortKind.audioMono
                : port.kind == PortKind.event)) {
            return cast(ptrdiff_t) i;
        }
    }
    return -1;
}
