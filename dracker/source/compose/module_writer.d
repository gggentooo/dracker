/**
 * File:         source/compose/module_writer.d
 * Module:       compose.module_writer
 * Phase:        Composition helper (dracker-compose) — T74 (Module writer)
 *
 * Purpose:
 *   Builds one module for the composition helper (decision T70). A ModuleWriter starts from a module type (at
 *   its defaults), from a bundled or user preset of the instrument library, or from the bytes or the file of a
 *   .msym preset; its name and its parameters are then set by name. A parameter is named by its display name,
 *   matched without regard to case or spaces ("Op1Level" finds "Op1 Level"). A value is a number inside the
 *   parameter's range: a value outside it is refused, never clipped. A discrete parameter that names its
 *   values (ParamDescriptor.options) also takes the name, so "Saw" sets Waveform to 2. Values can be read back
 *   as numbers or as the text that sets them again (the shortest decimal that reads back to the same float), so
 *   a preset can be printed as a script. The writer ends as a SavedModule for a project or as a .msym preset,
 *   written through the app's own serializer. What a loaded preset carries and this writer does not edit
 *   (extra data, a MetaModule child project, macro bindings) is kept as it is. A loaded preset must hold
 *   values its type accepts: a value outside a parameter's range, or a discrete value that is not a whole
 *   step, refuses the preset (mismatchedPreset), because the writer never clips. Module names follow the
 *   instrument library's rule (isValidPresetName, valid UTF-8), so any module can be saved to the library; a
 *   name taken from a preset or a file that breaks the rule is replaced by the nearest name that keeps it.
 *   A copy of a writer is independent of the original: the copy constructor copies the module's arrays.
 *   Every problem is returned as data: ModuleProblem says what kind of problem it is, the text it is about, a
 *   one-sentence reason, and the nearest valid name or value when there is one. Nothing is printed or thrown.
 *
 * Real-Time & Safety Contract:
 *   Off-RT / offline only. Every function is @safe nothrow; all are pure except fromPreset(), fromPresetFile(),
 *   fromPresetBytes() and writePresetFile(), which go through the app's preset loader and writer, and
 *   presetBytes(). The app's registry, library and file functions are not marked @safe or nothrow although
 *   they only read immutable tables and bounds-checked files, so each is called through one private @trusted
 *   adapter at the end of this file that says why it is safe. Strings and the rows of the name distance are
 *   allocated on the GC heap. No audio, GUI or session dependency; files are touched only by fromPreset(),
 *   fromPresetFile() and writePresetFile().
 *
 * Dependencies:
 *   Internal: app.instrument_library (InstrumentLibrary, isValidPresetName, LibraryEntry, MAX_PRESET_NAME),
 *             compose.names (name matching and suggestions), graph.module_api (ModuleDescriptor,
 *             ParamDescriptor, ParamScale), graph.registry (ModuleRegistry), io.project_format (LoadedPreset,
 *             SavedModule, loadPreset, loadPresetFile, serializePreset, savePreset)
 *   External: std.conv (to), std.format (format), std.math (floor, isFinite), std.path (baseName,
 *             stripExtension), std.utf (validate)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum PRESET_MODULE_ID; enum ModuleProblemKind
 *   - struct ModuleProblem (text()); struct ModuleWriterResult; struct ModuleValueResult;
 *     struct ModuleTextResult; struct ModuleEditResult; struct ModuleBytesResult
 *   - struct ModuleWriter: loaded(), typeId(), name(), descriptor(), paramCount(), paramValues(), setName(),
 *     setPresetName(), valueOf(), textOf(), setParamText(), setParamValue(), resetToDefaults(), savedModule(),
 *     loadedPreset(), presetBytes(), writePresetFile()
 *   - static ModuleWriter.fromType(), fromDescriptor(), fromPreset(), fromPresetFile(), fromPresetBytes()
 *   - findModuleType(); parameterRangeText(), parameterValueText(); suggestedName()
 *
 * See_Also:
 *   docs/todo.md (T70, T74, T75, T76, T91, T92), source/graph/module_api.d (ParamDescriptor),
 *   source/io/project_format.d (serializePreset, loadPreset)
 */
module compose.module_writer;

import std.conv : to;
import std.format : format;
import std.math : floor, isFinite;
import std.path : baseName, stripExtension;
import std.utf : validate;

import app.instrument_library : InstrumentLibrary, isValidPresetName, LibraryEntry, MAX_PRESET_NAME;
import compose.names : namesMatch, NameMatch, nearestMatch, nearestName, trim;
import graph.module_api : ModuleDescriptor, ParamDescriptor, ParamScale;
import graph.registry : ModuleRegistry;
import io.project_format : LoadedPreset, SavedModule, loadPreset, loadPresetFile, serializePreset, savePreset;

/**
 * The module id a preset is stored with when its module has no id of its own (the bundled presets use it too).
 */
enum uint PRESET_MODULE_ID = 1;

/**
 * The kind of problem a module writer reports.
 */
enum ModuleProblemKind : ubyte {
    unknownModuleType = 0,
    unreadablePreset = 1,
    unknownPreset = 2,
    ambiguousPreset = 3,
    mismatchedPreset = 4,
    unknownParameter = 5,
    ambiguousParameter = 6,
    notANumber = 7,
    outOfRange = 8,
    notAWholeNumber = 9,
    unknownOption = 10,
    invalidName = 11,
    notLoaded = 12,
    writeFailed = 13
}

/**
 * A problem found by the module writer, returned as data so a front end decides how to show it.
 */
struct ModuleProblem {
    ModuleProblemKind kind = ModuleProblemKind.notLoaded;
    string subject = "";
    string reason = "";
    string suggestion = "";

    /**
     * Writes the problem as one sentence: the reason, then the suggestion when there is one.
     *
     * Returns:
     *   The reason followed by "; did you mean '...'?" for a name, or by "; the nearest valid value is ..."
     *   for a value.
     */
    string text() const @safe pure nothrow {
        string result = reason;
        if (suggestion.length > 0) {
            result ~= isNameProblem(kind) ? "; did you mean '" ~ suggestion ~ "'?"
                : "; the nearest valid value is " ~ suggestion;
        }
        return result;
    }
}

/**
 * A module writer together with whether it could be started.
 */
struct ModuleWriterResult {
    ModuleWriter writer = ModuleWriter.init;
    bool ok = false;
    ModuleProblem problem = ModuleProblem.init;
}

/**
 * A parameter value read back from a module writer.
 */
struct ModuleValueResult {
    float value = 0.0f;
    bool ok = false;
    ModuleProblem problem = ModuleProblem.init;
}

/**
 * A parameter value read back as the text that sets it again.
 */
struct ModuleTextResult {
    string text = "";
    bool ok = false;
    ModuleProblem problem = ModuleProblem.init;
}

/**
 * The outcome of a change to a module writer.
 */
struct ModuleEditResult {
    bool ok = false;
    ModuleProblem problem = ModuleProblem.init;
}

/**
 * A serialized .msym preset.
 */
struct ModuleBytesResult {
    ubyte[] bytes;
    bool ok = false;
    ModuleProblem problem = ModuleProblem.init;
}

/**
 * One module being built: its type, its name, its parameter values and the extra data of a loaded preset.
 * A writer that could not be started (ModuleWriter.init, or the writer of a failed result) holds no module and
 * refuses every change with ModuleProblemKind.notLoaded.
 */
struct ModuleWriter {
    private const(ModuleDescriptor)* desc_ = null;
    private SavedModule mod_;
    private string presetName_ = "";

    /**
     * Copies a writer. The parameter values, the extra data and the child project are copied too, so a change
     * to the copy never changes the original.
     *
     * Params:
     *   other = The writer to copy.
     */
    this(ref return scope const ModuleWriter other) @safe pure nothrow {
        desc_ = other.desc_;
        mod_ = copyModule(other.mod_);
        presetName_ = other.presetName_;
    }

    /**
     * Starts a writer from a module type at its defaults, named after the type.
     *
     * Params:
     *   typeText = The type id ("synth.analog_gen") or the display name ("Analog Generator"), matched without
     *     regard to case or spaces.
     *
     * Returns:
     *   The writer, or unknownModuleType with the nearest type id.
     */
    static ModuleWriterResult fromType(string typeText) @safe pure nothrow {
        const(ModuleDescriptor)* found;
        ModuleProblem problem;
        if (!findModuleType(registeredDescriptors(), typeText, found, problem)) {
            return ModuleWriterResult(ModuleWriter.init, false, problem);
        }
        return fromDescriptor(found, found.displayName);
    }

    /**
     * Starts a writer from a module descriptor at the parameter defaults.
     *
     * Params:
     *   d = Descriptor of the module type; the writer keeps the pointer, which must stay alive.
     *   name = Module name, taken as it is.
     *
     * Returns:
     *   The writer, or notLoaded when d is null.
     */
    static ModuleWriterResult fromDescriptor(const(ModuleDescriptor)* d, string name) @safe pure nothrow {
        if (d is null) {
            return ModuleWriterResult(ModuleWriter.init, false, notLoadedProblem());
        }
        ModuleWriter w;
        w.desc_ = d;
        w.mod_.id = PRESET_MODULE_ID;
        w.mod_.typeId = d.typeId;
        w.mod_.name = name;
        w.mod_.paramValues = new float[d.params.length];
        foreach (i, ref p; d.params) {
            w.mod_.paramValues[i] = p.defaultVal;
        }
        return ModuleWriterResult(w, true);
    }

    /**
     * Starts a writer from a preset of the instrument library by name.
     *
     * Params:
     *   library = The preset library (bundled and user presets).
     *   name = Preset name ("Electric Bass"), matched without regard to case or spaces, or "Group/Name"
     *     ("Keys/Electric Piano", the group matched the same way) to tell presets of the same name apart.
     *
     * Returns:
     *   The writer, or unknownPreset, ambiguousPreset or unreadablePreset. The module is named as the app
     *   names it when it loads the preset: the preset's own name, else the entry's name.
     */
    static ModuleWriterResult fromPreset(const InstrumentLibrary library, string name) @safe nothrow {
        if (library is null) {
            return ModuleWriterResult(ModuleWriter.init, false,
                ModuleProblem(ModuleProblemKind.unknownPreset, trim(name), "there is no preset library to search",
                    ""));
        }
        const(LibraryEntry)[] entries = libraryEntries(library);
        immutable size_t slash = lastSlash(name);
        immutable bool qualified = slash != name.length;
        immutable string group = qualified ? trim(name[0 .. slash]) : "";
        immutable string bare = trim(qualified ? name[slash + 1 .. $] : name);
        size_t exactCount = 0;
        size_t lenientCount = 0;
        size_t firstExact = 0;
        size_t firstLenient = 0;
        foreach (i; 0 .. entries.length) {
            if (qualified && !namesMatch(entries[i].group, group)) {
                continue;
            }
            if (entries[i].name == bare) {
                if (exactCount == 0) {
                    firstExact = i;
                }
                exactCount++;
            } else if (namesMatch(entries[i].name, bare)) {
                if (lenientCount == 0) {
                    firstLenient = i;
                }
                lenientCount++;
            }
        }
        immutable size_t hits = exactCount > 0 ? exactCount : lenientCount;
        if (hits == 0) {
            return ModuleWriterResult(ModuleWriter.init, false,
                ModuleProblem(ModuleProblemKind.unknownPreset, trim(name), "unknown preset '" ~ trim(name) ~ "'",
                    nearestPresetName(entries, group, bare, qualified)));
        }
        immutable size_t chosen = exactCount > 0 ? firstExact : firstLenient;
        if (hits > 1) {
            immutable const(LibraryEntry) first = entries[chosen];
            immutable string wayOut = countMatches(entries, first.group, bare) == 1
                ? first.group ~ "/" ~ first.name : "";
            return ModuleWriterResult(ModuleWriter.init, false,
                ModuleProblem(ModuleProblemKind.ambiguousPreset, trim(name),
                    "'" ~ bare ~ "' matches " ~ to!string(hits) ~ " presets", wayOut));
        }
        LoadedPreset preset;
        string err;
        if (!readPresetFile(entries[chosen].path, preset, err)) {
            return ModuleWriterResult(ModuleWriter.init, false,
                ModuleProblem(ModuleProblemKind.unreadablePreset, entries[chosen].path,
                    "could not read the preset '" ~ entries[chosen].path ~ "': " ~ err, ""));
        }
        return adoptPreset(preset, entries[chosen].name);
    }

    /**
     * Starts a writer from a .msym preset file.
     *
     * Params:
     *   path = Path of the file.
     *
     * Returns:
     *   The writer, or unreadablePreset with the loader's reason. The module is named as the app names it when
     *   it loads the preset: the preset's own name, else the file name without its extension.
     */
    static ModuleWriterResult fromPresetFile(string path) @safe nothrow {
        LoadedPreset preset;
        string err;
        if (!readPresetFile(path, preset, err)) {
            return ModuleWriterResult(ModuleWriter.init, false,
                ModuleProblem(ModuleProblemKind.unreadablePreset, path,
                    "could not read the preset '" ~ path ~ "': " ~ err, ""));
        }
        return adoptPreset(preset, stripExtension(baseName(path)));
    }

    /**
     * Starts a writer from the bytes of a .msym preset.
     *
     * Params:
     *   bytes = The preset as the app's loadPreset() reads it.
     *   fallbackName = Module name when the preset carries none.
     *
     * Returns:
     *   The writer, or unreadablePreset, unknownModuleType or mismatchedPreset.
     */
    static ModuleWriterResult fromPresetBytes(const(ubyte)[] bytes, string fallbackName = "")
            @safe nothrow {
        LoadedPreset preset;
        string err;
        if (!loadPreset(bytes, preset, err)) {
            return ModuleWriterResult(ModuleWriter.init, false,
                ModuleProblem(ModuleProblemKind.unreadablePreset, fallbackName,
                    "could not read the preset data: " ~ err, ""));
        }
        return adoptPreset(preset, fallbackName);
    }

    /**
     * Reports whether the writer holds a module.
     *
     * Returns:
     *   True when a start succeeded.
     */
    bool loaded() const @safe pure nothrow @nogc {
        return desc_ !is null;
    }

    /**
     * Returns the type id of the module.
     *
     * Returns:
     *   The type id, or "" when the writer holds no module.
     */
    string typeId() const @safe pure nothrow @nogc {
        return desc_ is null ? "" : desc_.typeId;
    }

    /**
     * Returns the module name (what setName() set, else the name the writer started with).
     *
     * Returns:
     *   The name.
     */
    string name() const @safe pure nothrow @nogc {
        return mod_.name;
    }

    /**
     * Returns the descriptor of the module type: its ports and its parameters with names, ranges and options.
     *
     * Returns:
     *   Pointer to the registered descriptor, or null when the writer holds no module.
     */
    const(ModuleDescriptor)* descriptor() const @safe pure nothrow @nogc {
        return desc_;
    }

    /**
     * Returns how many parameters the module has.
     *
     * Returns:
     *   The parameter count (0 when the writer holds no module).
     */
    size_t paramCount() const @safe pure nothrow @nogc {
        return mod_.paramValues.length;
    }

    /**
     * Returns the current parameter values in descriptor order, in the parameters' own units.
     *
     * Returns:
     *   The values; the slice shares its storage with the writer.
     */
    const(float)[] paramValues() const @safe pure nothrow @nogc {
        return mod_.paramValues;
    }

    /**
     * Sets the module name. Surrounding spaces are dropped. The name must be one the instrument library takes
     * (app.instrument_library.isValidPresetName: 1 to MAX_PRESET_NAME bytes, no '/', '\\', ':' or control
     * characters, not starting with '.') and valid UTF-8, so the module can also become a preset.
     *
     * Params:
     *   text = The name.
     *
     * Returns:
     *   ok, or invalidName with the nearest valid name (suggestedName()) when there is one.
     */
    ModuleEditResult setName(string text) @safe pure nothrow {
        if (desc_ is null) {
            return ModuleEditResult(false, notLoadedProblem());
        }
        immutable string trimmed = trim(text);
        ModuleProblem problem;
        if (!checkName(trimmed, problem)) {
            return ModuleEditResult(false, problem);
        }
        mod_.name = trimmed;
        return ModuleEditResult(true);
    }

    /**
     * Sets the name the preset is stored under when it is written. Until it is set, and again after it is set to
     * "" or to spaces only, the module name is used.
     *
     * Params:
     *   text = The preset name, or "" for the module name.
     *
     * Returns:
     *   ok, or invalidName.
     */
    ModuleEditResult setPresetName(string text) @safe pure nothrow {
        if (desc_ is null) {
            return ModuleEditResult(false, notLoadedProblem());
        }
        immutable string trimmed = trim(text);
        ModuleProblem problem;
        if (trimmed.length > 0 && !checkName(trimmed, problem)) {
            return ModuleEditResult(false, problem);
        }
        presetName_ = trimmed;
        return ModuleEditResult(true);
    }

    /**
     * Reads a parameter value by name.
     *
     * Params:
     *   name = Parameter name, matched without regard to case or spaces.
     *
     * Returns:
     *   The value in the parameter's own units, or the problem.
     */
    ModuleValueResult valueOf(string name) const @safe pure nothrow {
        ptrdiff_t index;
        ModuleProblem problem;
        if (!findParameter(name, index, problem)) {
            return ModuleValueResult(0.0f, false, problem);
        }
        return ModuleValueResult(mod_.paramValues[cast(size_t) index], true);
    }

    /**
     * Reads a parameter value as the text that sets it again: the option name of a named discrete value, a
     * whole number, or the shortest decimal that reads back to the same value.
     *
     * Params:
     *   name = Parameter name, matched without regard to case or spaces.
     *
     * Returns:
     *   The text, or the problem.
     */
    ModuleTextResult textOf(string name) const @safe pure nothrow {
        ptrdiff_t index;
        ModuleProblem problem;
        if (!findParameter(name, index, problem)) {
            return ModuleTextResult("", false, problem);
        }
        immutable size_t i = cast(size_t) index;
        return ModuleTextResult(parameterValueText(desc_.params[i], mod_.paramValues[i]), true);
    }

    /**
     * Sets a parameter from text, as a script gives it: a number, or for a discrete parameter that names its
     * values one of its names. The value is checked against the range; the writer does not change on a refusal.
     *
     * Params:
     *   name = Parameter name, matched without regard to case or spaces.
     *   text = The value as written.
     *
     * Returns:
     *   ok, or a parameter problem (unknownParameter, notANumber, outOfRange, notAWholeNumber,
     *   unknownOption).
     */
    ModuleEditResult setParamText(string name, string text) @safe pure nothrow {
        ptrdiff_t index;
        ModuleProblem problem;
        if (!findParameter(name, index, problem)) {
            return ModuleEditResult(false, problem);
        }
        immutable size_t i = cast(size_t) index;
        float value;
        if (!parseValueText(desc_.params[i], text, value, problem)) {
            return ModuleEditResult(false, problem);
        }
        mod_.paramValues[i] = value;
        return ModuleEditResult(true);
    }

    /**
     * Sets a parameter from a number in the parameter's own units, checked against the range.
     *
     * Params:
     *   name = Parameter name, matched without regard to case or spaces.
     *   value = The value; must be finite, inside the range, and a whole step for a discrete parameter.
     *
     * Returns:
     *   ok, or a parameter problem (unknownParameter, notANumber, outOfRange, notAWholeNumber).
     */
    ModuleEditResult setParamValue(string name, float value) @safe pure nothrow {
        ptrdiff_t index;
        ModuleProblem problem;
        if (!findParameter(name, index, problem)) {
            return ModuleEditResult(false, problem);
        }
        immutable size_t i = cast(size_t) index;
        if (!checkValue(desc_.params[i], value, valueTextForMessage(desc_.params[i], value), problem)) {
            return ModuleEditResult(false, problem);
        }
        mod_.paramValues[i] = value;
        return ModuleEditResult(true);
    }

    /**
     * Sets every parameter back to the type's default. The name and the extra data are kept.
     *
     * Returns:
     *   ok, or notLoaded.
     */
    ModuleEditResult resetToDefaults() @safe pure nothrow {
        if (desc_ is null) {
            return ModuleEditResult(false, notLoadedProblem());
        }
        foreach (i, ref p; desc_.params) {
            mod_.paramValues[i] = p.defaultVal;
        }
        return ModuleEditResult(true);
    }

    /**
     * Returns the module as a project stores it: a copy that shares nothing with the writer.
     *
     * Params:
     *   id = Module id to store; 0 keeps the current one (PRESET_MODULE_ID for a new module, the file's id for
     *     a loaded preset).
     *
     * Returns:
     *   The module, or SavedModule.init when the writer holds no module.
     */
    SavedModule savedModule(uint id = 0) const @safe pure nothrow {
        SavedModule m = copyModule(mod_);
        if (id != 0) {
            m.id = id;
        }
        return m;
    }

    /**
     * Returns the module as a .msym preset: the preset name (the module name unless setPresetName() set one)
     * and the module.
     *
     * Params:
     *   id = Module id to store; 0 keeps the current one.
     *
     * Returns:
     *   The preset document, or an empty one when the writer holds no module.
     */
    LoadedPreset loadedPreset(uint id = 0) const @safe pure nothrow {
        LoadedPreset preset;
        preset.presetName = presetName_.length > 0 ? presetName_ : mod_.name;
        preset.mod = savedModule(id);
        return preset;
    }

    /**
     * Serializes the preset through the app's own serializer, so the app's loader reads it back.
     *
     * Returns:
     *   The .msym bytes, or notLoaded, or writeFailed with the serializer's reason.
     */
    ModuleBytesResult presetBytes() const @safe nothrow {
        ModuleBytesResult result;
        if (desc_ is null) {
            result.problem = notLoadedProblem();
            return result;
        }
        LoadedPreset preset = loadedPreset();
        string err;
        if (!serializePreset(preset, result.bytes, err)) {
            result.problem = ModuleProblem(ModuleProblemKind.writeFailed, mod_.name,
                "could not write the preset: " ~ err, "");
            return result;
        }
        result.ok = true;
        return result;
    }

    /**
     * Writes the preset as a .msym file through the app's own writer.
     *
     * Params:
     *   path = Destination path.
     *
     * Returns:
     *   ok, or notLoaded, or writeFailed with the writer's reason.
     */
    ModuleEditResult writePresetFile(string path) const @safe nothrow {
        if (desc_ is null) {
            return ModuleEditResult(false, notLoadedProblem());
        }
        LoadedPreset preset = loadedPreset();
        string err;
        if (!savePresetFile(preset, path, err)) {
            return ModuleEditResult(false,
                ModuleProblem(ModuleProblemKind.writeFailed, path, "could not write the preset: " ~ err, ""));
        }
        return ModuleEditResult(true);
    }

    /**
     * Takes over a loaded preset: checks its module type, its parameter count and every value against its
     * parameter, and names the module as the app does when it loads the preset (the preset name, else the
     * module's own name, else fallbackName). A name the library would refuse becomes suggestedName() of it, or
     * the type's display name when nothing of it can be kept.
     *
     * Params:
     *   preset = The preset as the app's loader read it.
     *   fallbackName = Module name when the preset carries none.
     *
     * Returns:
     *   The writer, or unknownModuleType, or mismatchedPreset (also for a value the parameter does not take).
     */
    private static ModuleWriterResult adoptPreset(const ref LoadedPreset preset, string fallbackName)
            @safe pure nothrow {
        const(ModuleDescriptor)* d = registeredType(preset.mod.typeId);
        if (d is null) {
            return ModuleWriterResult(ModuleWriter.init, false,
                ModuleProblem(ModuleProblemKind.unknownModuleType, preset.mod.typeId,
                    "the preset holds a module type that is not registered: '" ~ preset.mod.typeId ~ "'",
                    nearestTypeName(registeredDescriptors(), preset.mod.typeId)));
        }
        if (preset.mod.paramValues.length != d.params.length) {
            return ModuleWriterResult(ModuleWriter.init, false,
                ModuleProblem(ModuleProblemKind.mismatchedPreset, preset.mod.typeId,
                    "the preset does not match its module type '" ~ d.displayName ~ "': it has "
                    ~ to!string(preset.mod.paramValues.length) ~ " parameter values, the type has "
                    ~ to!string(d.params.length), ""));
        }
        foreach (i, ref p; d.params) {
            ModuleProblem valueProblem;
            immutable float value = preset.mod.paramValues[i];
            if (!checkValue(p, value, valueTextForMessage(p, value), valueProblem)) {
                return ModuleWriterResult(ModuleWriter.init, false,
                    ModuleProblem(ModuleProblemKind.mismatchedPreset, p.name,
                        "the preset does not match its module type '" ~ d.displayName ~ "': " ~ valueProblem.reason,
                        ""));
            }
        }
        ModuleWriter w;
        w.desc_ = d;
        w.mod_ = copyModule(preset.mod);
        if (w.mod_.id == 0) {
            w.mod_.id = PRESET_MODULE_ID;
        }
        immutable string given = trim(preset.presetName.length > 0 ? preset.presetName
            : (preset.mod.name.length > 0 ? preset.mod.name : fallbackName));
        w.mod_.name = usableName(given, d.displayName);
        immutable string presetName = trim(preset.presetName);
        w.presetName_ = presetName.length == 0 ? "" : usableName(presetName, w.mod_.name);
        return ModuleWriterResult(w, true);
    }

    /**
     * Finds a parameter by name: an exact match first, else the only match without regard to case or spaces.
     *
     * Params:
     *   name = Parameter name.
     *   index = Receives the parameter index.
     *   problem = Receives notLoaded, unknownParameter or ambiguousParameter.
     *
     * Returns:
     *   True when exactly one parameter matches.
     */
    private bool findParameter(string name, out ptrdiff_t index, out ModuleProblem problem)
            const @safe pure nothrow {
        index = -1;
        problem = ModuleProblem.init;
        if (desc_ is null) {
            problem = notLoadedProblem();
            return false;
        }
        immutable string bare = trim(name);
        size_t lenientHits = 0;
        foreach (i, ref p; desc_.params) {
            if (p.name == bare) {
                index = cast(ptrdiff_t) i;
                return true;
            }
            if (namesMatch(p.name, bare)) {
                if (lenientHits == 0) {
                    index = cast(ptrdiff_t) i;
                }
                lenientHits++;
            }
        }
        if (lenientHits > 1) {
            problem = ModuleProblem(ModuleProblemKind.ambiguousParameter, bare,
                "'" ~ bare ~ "' matches " ~ to!string(lenientHits) ~ " parameters of '" ~ desc_.displayName ~ "'",
                desc_.params[cast(size_t) index].name);
            index = -1;
            return false;
        }
        if (index < 0) {
            string[] names;
            foreach (ref p; desc_.params) {
                names ~= p.name;
            }
            problem = ModuleProblem(ModuleProblemKind.unknownParameter, bare,
                "unknown parameter '" ~ bare ~ "'", nearestName(bare, names));
            return false;
        }
        return true;
    }
}

/**
 * Writes what a parameter accepts, for messages and the catalog: "a number from 40 to 18000 Hz", "a whole
 * number from 0 to 5", or "a whole number from 0 to 5, or one of its names".
 *
 * Params:
 *   p = Parameter descriptor.
 *
 * Returns:
 *   The range as text.
 */
string parameterRangeText(ParamDescriptor p) @safe pure nothrow {
    immutable string from = numberText(p.minVal);
    immutable string to = numberText(p.maxVal);
    if (p.scale == ParamScale.discrete) {
        return "a whole number from " ~ from ~ " to " ~ to
            ~ (p.options.length > 0 ? ", or one of its names" : "");
    }
    return "a number from " ~ from ~ " to " ~ to ~ (p.unit.length > 0 ? " " ~ p.unit : "");
}

/**
 * Writes a parameter value as the text that sets it again: the option name of a named discrete value (unless
 * the name reads as a number, which setParamText() would take as a number), a whole number, or the shortest
 * decimal that reads back to the same value.
 *
 * Params:
 *   p = Parameter descriptor.
 *   value = The value in the parameter's own units.
 *
 * Returns:
 *   The value as text.
 */
string parameterValueText(ParamDescriptor p, float value) @safe pure nothrow {
    if (p.scale == ParamScale.discrete && isFinite(value)) {
        immutable float step = value - p.minVal;
        if (step == floor(step)) {
            if (p.options.length > 0 && step >= 0.0f && step < cast(float) p.options.length
                    && !isDecimalNumber(trim(p.options[cast(size_t) step]))) {
                return p.options[cast(size_t) step];
            }
            return integerText(value);
        }
    }
    return numberText(value);
}

/**
 * Reports whether a problem is about a name (its suggestion is read as "did you mean ...").
 *
 * Params:
 *   kind = The kind of problem.
 *
 * Returns:
 *   True for unknown and ambiguous names of types, presets, parameters and options, and for invalid module
 *   names (whose suggestion is the nearest valid name).
 */
private bool isNameProblem(ModuleProblemKind kind) @safe pure nothrow @nogc {
    final switch (kind) {
        case ModuleProblemKind.unknownModuleType:
        case ModuleProblemKind.unknownPreset:
        case ModuleProblemKind.ambiguousPreset:
        case ModuleProblemKind.unknownParameter:
        case ModuleProblemKind.ambiguousParameter:
        case ModuleProblemKind.unknownOption:
        case ModuleProblemKind.invalidName:
            return true;
        case ModuleProblemKind.unreadablePreset:
        case ModuleProblemKind.mismatchedPreset:
        case ModuleProblemKind.notANumber:
        case ModuleProblemKind.outOfRange:
        case ModuleProblemKind.notAWholeNumber:
        case ModuleProblemKind.notLoaded:
        case ModuleProblemKind.writeFailed:
            return false;
    }
}

/**
 * Reads a parameter value from text: a decimal number, or for a discrete parameter that names its values one
 * of its names (matched without regard to case or spaces; a number is still accepted).
 *
 * Params:
 *   p = Parameter descriptor.
 *   text = The value as written.
 *   value = Receives the value in the parameter's own units.
 *   problem = Receives the refusal.
 *
 * Returns:
 *   True when the text is a value the parameter takes.
 */
private bool parseValueText(ParamDescriptor p, string text, out float value, out ModuleProblem problem)
        @safe pure nothrow {
    value = 0.0f;
    problem = ModuleProblem.init;
    immutable string bare = trim(text);
    if (!isDecimalNumber(bare)) {
        if (p.scale == ParamScale.discrete && p.options.length > 0) {
            immutable ptrdiff_t option = matchOption(p.options, bare);
            if (option >= 0) {
                immutable float named = p.minVal + cast(float) option;
                if (!checkValue(p, named, bare, problem)) {
                    return false;
                }
                value = named;
                return true;
            }
            if (bare.length == 0) {
                problem = ModuleProblem(ModuleProblemKind.notANumber, "",
                    "a value is needed for '" ~ p.name ~ "'", "");
                return false;
            }
            string[] names;
            foreach (ref o; p.options) {
                names ~= o;
            }
            problem = ModuleProblem(ModuleProblemKind.unknownOption, bare,
                "unknown value '" ~ bare ~ "' for '" ~ p.name ~ "'", nearestName(bare, names));
            return false;
        }
        problem = bare.length == 0
            ? ModuleProblem(ModuleProblemKind.notANumber, "", "a value is needed for '" ~ p.name ~ "'", "")
            : ModuleProblem(ModuleProblemKind.notANumber, bare,
                "the value of '" ~ p.name ~ "' must be " ~ parameterRangeText(p) ~ "; '" ~ bare
                ~ "' is not a number", "");
        return false;
    }
    float parsed;
    if (!tryParseFloat(bare, parsed) || !isFinite(parsed)) {
        immutable bool negative = bare[0] == '-';
        problem = ModuleProblem(ModuleProblemKind.outOfRange, bare,
            "'" ~ bare ~ "' is outside the range of '" ~ p.name ~ "' (" ~ parameterRangeText(p) ~ ")",
            parameterValueText(p, negative ? p.minVal : p.maxVal));
        return false;
    }
    if (!checkValue(p, parsed, bare, problem)) {
        return false;
    }
    value = parsed;
    return true;
}

/**
 * Checks a value against what a parameter takes.
 *
 * Params:
 *   p = Parameter descriptor.
 *   candidate = The value in the parameter's own units.
 *   text = The value as it was given, for the message.
 *   problem = Receives notANumber, notAWholeNumber or outOfRange with the nearest valid value.
 *
 * Returns:
 *   True when the value is accepted.
 */
private bool checkValue(ParamDescriptor p, float candidate, string text, out ModuleProblem problem)
        @safe pure nothrow {
    problem = ModuleProblem.init;
    if (!isFinite(candidate)) {
        problem = ModuleProblem(ModuleProblemKind.notANumber, text,
            "the value of '" ~ p.name ~ "' must be " ~ parameterRangeText(p) ~ "; '" ~ text
            ~ "' is not a finite number", "");
        return false;
    }
    if (p.scale == ParamScale.discrete) {
        immutable float step = candidate - p.minVal;
        if (step != floor(step)) {
            immutable float nearest = clampToRange(p, floor(step + 0.5f) + p.minVal);
            problem = ModuleProblem(ModuleProblemKind.notAWholeNumber, text,
                "'" ~ text ~ "' is not a whole number; '" ~ p.name ~ "' takes " ~ parameterRangeText(p),
                parameterValueText(p, nearest));
            return false;
        }
    }
    if (candidate < p.minVal || candidate > p.maxVal) {
        problem = ModuleProblem(ModuleProblemKind.outOfRange, text,
            "'" ~ text ~ "' is outside the range of '" ~ p.name ~ "' (" ~ parameterRangeText(p) ~ ")",
            parameterValueText(p, clampToRange(p, candidate)));
        return false;
    }
    return true;
}

/**
 * The text of a value when it is only needed in a message (the shortest decimal, or "nan" and "inf").
 *
 * Params:
 *   p = Parameter descriptor.
 *   value = The value.
 *
 * Returns:
 *   The value as text.
 */
private string valueTextForMessage(ParamDescriptor p, float value) @safe pure nothrow {
    return isFinite(value) ? parameterValueText(p, value) : nonFiniteText(value);
}

/**
 * Checks a module name: one the instrument library takes as a preset name (isValidPresetName) and valid UTF-8.
 *
 * Params:
 *   name = The name, already without surrounding spaces.
 *   problem = Receives invalidName, with suggestedName() of the name as the suggestion.
 *
 * Returns:
 *   True when the name can be used.
 */
private bool checkName(string name, out ModuleProblem problem) @safe pure nothrow {
    problem = ModuleProblem.init;
    if (isUsableName(name)) {
        return true;
    }
    string reason;
    if (name.length == 0) {
        reason = "a module name cannot be empty";
    } else if (!isValidUtf8(name)) {
        reason = "a module name must be valid UTF-8 text";
    } else if (name.length > MAX_PRESET_NAME) {
        reason = "a module name has at most " ~ to!string(MAX_PRESET_NAME) ~ " bytes";
    } else if (name[0] == '.') {
        reason = "a module name cannot start with '.'";
    } else {
        reason = "a module name cannot contain '/', '\\', ':' or control characters";
    }
    problem = ModuleProblem(ModuleProblemKind.invalidName, name, reason, suggestedName(name));
    return false;
}

/**
 * Reports whether a name can be a module name: valid UTF-8 and a name the instrument library takes.
 *
 * Params:
 *   name = The name.
 *
 * Returns:
 *   True when the name is usable.
 */
private bool isUsableName(string name) @safe pure nothrow {
    return isValidUtf8(name) && isValidPresetName(name);
}

/**
 * The nearest name the module writer accepts: '/', '\\' and ':' become '-', control characters and bytes that
 * are not UTF-8 are dropped, leading dots and surrounding spaces are cut, and the name is cut to
 * MAX_PRESET_NAME bytes at a character boundary.
 *
 * Params:
 *   name = The name.
 *
 * Returns:
 *   The nearest usable name (the name itself when it is usable), or "" when nothing of it can be kept.
 */
string suggestedName(string name) @safe pure nothrow {
    char[] buffer;
    size_t i = 0;
    while (i < name.length) {
        immutable size_t length = utf8SequenceLength(name, i);
        if (length == 0) {
            i++;
            continue;
        }
        immutable char c = name[i];
        if (length == 1 && (c < 0x20 || c == 0x7F)) {
            i++;
            continue;
        }
        if (length == 1 && (c == '/' || c == '\\' || c == ':')) {
            buffer ~= '-';
        } else {
            buffer ~= name[i .. i + length];
        }
        i += length;
    }
    string text = trim(buffer.idup);
    size_t start = 0;
    while (start < text.length && text[start] == '.') {
        start++;
    }
    text = trim(text[start .. $]);
    if (text.length > MAX_PRESET_NAME) {
        size_t cut = MAX_PRESET_NAME;
        while (cut > 0 && (text[cut] & 0xC0) == 0x80) {
            cut--;
        }
        text = trim(text[0 .. cut]);
    }
    return isUsableName(text) ? text : "";
}

/**
 * The name to give a module whose name came from a preset or a file: the name when it is usable, else
 * suggestedName() of it, else a fallback.
 *
 * Params:
 *   name = The name as the preset or the file gives it.
 *   fallback = The name to use when nothing of it can be kept; must be usable.
 *
 * Returns:
 *   A usable name.
 */
private string usableName(string name, string fallback) @safe pure nothrow {
    if (isUsableName(name)) {
        return name;
    }
    immutable string suggestion = suggestedName(name);
    return suggestion.length > 0 ? suggestion : fallback;
}

/**
 * Reports whether a text is valid UTF-8.
 *
 * Params:
 *   text = The text.
 *
 * Returns:
 *   True when every byte belongs to a well-formed UTF-8 sequence.
 */
private bool isValidUtf8(string text) @safe pure nothrow {
    try {
        validate(text);
        return true;
    } catch (Exception) {
        return false;
    }
}

/**
 * The length of the well-formed UTF-8 sequence that starts at a position.
 *
 * Params:
 *   text = The text.
 *   start = The position.
 *
 * Returns:
 *   1 to 4, or 0 when the bytes there are not a well-formed sequence.
 */
private size_t utf8SequenceLength(string text, size_t start) @safe pure nothrow {
    immutable ubyte lead = cast(ubyte) text[start];
    immutable size_t length = lead < 0x80 ? 1 : (lead >= 0xC2 && lead < 0xE0 ? 2
        : (lead >= 0xE0 && lead < 0xF0 ? 3 : (lead >= 0xF0 && lead < 0xF5 ? 4 : 0)));
    if (length == 0 || start + length > text.length) {
        return 0;
    }
    return isValidUtf8(text[start .. start + length]) ? length : 0;
}

/**
 * Finds an option by name: an exact match first, else the only match without regard to case or spaces.
 *
 * Params:
 *   options = The option names, in the order of the values.
 *   text = The name as written.
 *
 * Returns:
 *   The index of the option from 0, or -1 when none or more than one matches.
 */
private ptrdiff_t matchOption(scope const(string)[] options, string text) @safe pure nothrow {
    ptrdiff_t found = -1;
    size_t lenientHits = 0;
    foreach (i, ref option; options) {
        if (option == text) {
            return cast(ptrdiff_t) i;
        }
        if (namesMatch(option, text)) {
            if (lenientHits == 0) {
                found = cast(ptrdiff_t) i;
            }
            lenientHits++;
        }
    }
    return lenientHits > 1 ? -1 : found;
}

/**
 * Returns the value nearest to a candidate that lies inside a parameter's range, as a whole step for a
 * discrete parameter.
 *
 * Params:
 *   p = Parameter descriptor.
 *   candidate = The value.
 *
 * Returns:
 *   The nearest valid value.
 */
private float clampToRange(ParamDescriptor p, float candidate) @safe pure nothrow @nogc {
    if (candidate < p.minVal) {
        return p.minVal;
    }
    if (candidate > p.maxVal) {
        return p.maxVal;
    }
    return candidate;
}

/**
 * Deep-copies a module so the copy shares no arrays with the source.
 *
 * Params:
 *   src = The module.
 *
 * Returns:
 *   The copy.
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

/**
 * The problem of a writer that holds no module.
 *
 * Returns:
 *   notLoaded.
 */
private ModuleProblem notLoadedProblem() @safe pure nothrow {
    return ModuleProblem(ModuleProblemKind.notLoaded, "", "the module writer holds no module", "");
}


/**
 * Finds a module type by what a script writes for it: the exact type id first, else the only type whose type id
 * or display name matches without regard to case or spaces. The registry is passed in so the rule can be
 * checked with any list of types.
 *
 * Params:
 *   descs = The module types to search, for example ModuleRegistry.descriptors().
 *   typeText = The type id ("synth.analog_gen") or the display name ("Analog Generator") as written.
 *   found = Receives the type, or null.
 *   problem = Receives unknownModuleType, with the nearest type id or display name, or for a text that
 *     matches more than one type, the type id of the first.
 *
 * Returns:
 *   True when exactly one type was found.
 */
bool findModuleType(scope const(ModuleDescriptor)[] descs, string typeText, out const(ModuleDescriptor)* found,
        out ModuleProblem problem) @safe pure nothrow {
    found = null;
    problem = ModuleProblem.init;
    immutable string bare = trim(typeText);
    foreach (i; 0 .. descs.length) {
        if (descs[i].typeId == bare) {
            found = &descs[i];
            return true;
        }
    }
    foreach (i; 0 .. descs.length) {
        if (namesMatch(descs[i].typeId, bare) || namesMatch(descs[i].displayName, bare)) {
            if (found !is null) {
                problem = ModuleProblem(ModuleProblemKind.unknownModuleType, bare,
                    "'" ~ bare ~ "' matches more than one module type", found.typeId);
                found = null;
                return false;
            }
            found = &descs[i];
        }
    }
    if (found is null) {
        problem = ModuleProblem(ModuleProblemKind.unknownModuleType, bare, "unknown module type '" ~ bare ~ "'",
            nearestTypeName(descs, bare));
        return false;
    }
    return true;
}

/**
 * The type nearest to a text, as its type id or its display name, whichever of the two is nearer (the type id
 * when both are as near). Both are spellings fromType() takes.
 *
 * Params:
 *   descs = The module types.
 *   text = The type id or display name as written.
 *
 * Returns:
 *   The nearest type id or display name, or "" when none is near enough.
 */
private string nearestTypeName(scope const(ModuleDescriptor)[] descs, string text) @safe pure nothrow {
    string[] ids;
    string[] displayNames;
    foreach (i; 0 .. descs.length) {
        ids ~= descs[i].typeId;
        displayNames ~= descs[i].displayName;
    }
    immutable NameMatch byId = nearestMatch(text, ids);
    immutable NameMatch byName = nearestMatch(text, displayNames);
    if (byId.index >= 0 && (byName.index < 0 || byId.distance <= byName.distance)) {
        return ids[cast(size_t) byId.index];
    }
    return byName.index < 0 ? "" : displayNames[cast(size_t) byName.index];
}

/**
 * The preset name nearest to one that was not found.
 *
 * Params:
 *   entries = The presets of the library.
 *   group = The group that was named, or "" when none was.
 *   bare = The preset name as written.
 *   qualified = Whether a group was named.
 *
 * Returns:
 *   For a name written with a group, "Group/Name" of the nearest preset in that group, or else of the nearest
 *   preset anywhere. For a bare name, the nearest bare name when it is unique, else its "Group/Name" when that
 *   is unique. "" when none is near enough or the name cannot be made unique.
 */
private string nearestPresetName(scope const(LibraryEntry)[] entries, string group, string bare, bool qualified)
        @safe pure nothrow {
    immutable ptrdiff_t inGroup = nearestPresetIndex(entries, group, bare);
    if (inGroup >= 0) {
        return presetSuggestion(entries, cast(size_t) inGroup, qualified);
    }
    if (!qualified) {
        return "";
    }
    immutable ptrdiff_t anywhere = nearestPresetIndex(entries, "", bare);
    return anywhere < 0 ? "" : presetSuggestion(entries, cast(size_t) anywhere, true);
}

/**
 * The name to suggest for a preset: its bare name when that is unique and no group was written, else its
 * "Group/Name" when that is unique.
 *
 * Params:
 *   entries = The presets of the library.
 *   index = The preset.
 *   qualified = Whether a group was written.
 *
 * Returns:
 *   The bare or qualified name, or "" when neither is unique.
 */
private string presetSuggestion(scope const(LibraryEntry)[] entries, size_t index, bool qualified)
        @safe pure nothrow {
    immutable const(LibraryEntry) found = entries[index];
    if (!qualified && countMatches(entries, "", found.name) == 1) {
        return found.name;
    }
    return countMatches(entries, found.group, found.name) == 1 ? found.group ~ "/" ~ found.name : "";
}

/**
 * Finds the preset of a group whose name is nearest to a text.
 *
 * Params:
 *   entries = The presets of the library.
 *   group = The group, or "" for every group.
 *   bare = The preset name as written.
 *
 * Returns:
 *   The index of the nearest preset, or -1 when none is near enough.
 */
private ptrdiff_t nearestPresetIndex(scope const(LibraryEntry)[] entries, string group, string bare)
        @safe pure nothrow {
    string[] names;
    size_t[] indices;
    foreach (i, ref e; entries) {
        if (group.length == 0 || namesMatch(e.group, group)) {
            names ~= e.name;
            indices ~= i;
        }
    }
    immutable NameMatch best = nearestMatch(bare, names);
    return best.index < 0 ? -1 : cast(ptrdiff_t) indices[cast(size_t) best.index];
}

/**
 * Counts the presets whose name matches one without regard to case or spaces and that lie in a group.
 *
 * Params:
 *   entries = The presets of the library.
 *   group = The group, or "" for every group.
 *   bare = The preset name.
 *
 * Returns:
 *   How many presets match.
 */
private size_t countMatches(scope const(LibraryEntry)[] entries, string group, string bare)
        @safe pure nothrow {
    size_t count = 0;
    foreach (ref e; entries) {
        if ((group.length == 0 || namesMatch(e.group, group)) && namesMatch(e.name, bare)) {
            count++;
        }
    }
    return count;
}







/**
 * The position of the last slash in a text.
 *
 * Params:
 *   text = The text.
 *
 * Returns:
 *   Its offset, or text.length when there is none (compare with text.length, never with 0).
 */
private size_t lastSlash(string text) @safe pure nothrow @nogc {
    size_t result = text.length;
    foreach (i, c; text) {
        if (c == '/') {
            result = i;
        }
    }
    return result;
}

/**
 * Reports whether a text is a decimal number as this module reads it: an optional sign, digits with an optional
 * fraction, and an optional exponent. Underscores, hexadecimal forms, "nan" and "inf" are not.
 *
 * Params:
 *   text = The text, without surrounding spaces.
 *
 * Returns:
 *   True when the text has the form of a decimal number.
 */
private bool isDecimalNumber(string text) @safe pure nothrow @nogc {
    size_t i = 0;
    if (i < text.length && (text[i] == '+' || text[i] == '-')) {
        i++;
    }
    immutable size_t integerDigits = countDigits(text, i);
    i += integerDigits;
    if (i < text.length && text[i] == '.') {
        i++;
        i += countDigits(text, i);
    }
    if (integerDigits == 0 && (i < 2 || text[i - 1] == '.' || text[i - 1] == '+' || text[i - 1] == '-')) {
        return false;
    }
    if (i < text.length && (text[i] == 'e' || text[i] == 'E')) {
        i++;
        if (i < text.length && (text[i] == '+' || text[i] == '-')) {
            i++;
        }
        immutable size_t exponentDigits = countDigits(text, i);
        if (exponentDigits == 0) {
            return false;
        }
        i += exponentDigits;
    }
    return i == text.length && text.length > 0;
}

/**
 * Counts the digits that start at a position.
 *
 * Params:
 *   text = The text.
 *   start = The position to look from.
 *
 * Returns:
 *   How many digits follow in a row.
 */
private size_t countDigits(scope const(char)[] text, size_t start) @safe pure nothrow @nogc {
    size_t end = start;
    while (end < text.length && text[end] >= '0' && text[end] <= '9') {
        end++;
    }
    return end - start;
}

/**
 * Reads a text that isDecimalNumber() accepts into a float, with the correctly rounded value.
 *
 * Params:
 *   text = The text.
 *   value = Receives the value (0 when the text cannot be read).
 *
 * Returns:
 *   True when the text was read.
 */
private bool tryParseFloat(string text, out float value) @safe pure nothrow {
    try {
        value = to!float(text);
        return true;
    } catch (Exception) {
        value = 0.0f;
        return false;
    }
}

/**
 * Writes a whole number without decimals, anything else as the shortest decimal that reads back to the same
 * value.
 *
 * Params:
 *   value = The value.
 *
 * Returns:
 *   The value as text.
 */
private string numberText(float value) @safe pure nothrow {
    return isFinite(value) && value == floor(value) && absLessThan(value, 1.0e15f)
        ? integerText(value) : shortestFloatText(value);
}

/**
 * Writes a whole number, keeping the sign of a negative zero so that the text reads back to the same bits. A
 * number of 10^15 or more in size, which a long cannot always hold, is written as the shortest decimal.
 *
 * Params:
 *   value = A whole number.
 *
 * Returns:
 *   The number without decimals, or its shortest decimal.
 */
private string integerText(float value) @safe pure nothrow {
    if (value == 0.0f) {
        return 1.0f / value < 0.0f ? "-0" : "0";
    }
    if (!isFinite(value) || !absLessThan(value, 1.0e15f)) {
        return shortestFloatText(value);
    }
    return to!string(cast(long) value);
}

/**
 * Writes the shortest decimal that reads back to the same float: the smallest number of significant digits
 * (up to nine, which always reads back) that round-trips.
 *
 * Params:
 *   value = The value; "nan", "inf" or "-inf" when it is not finite.
 *
 * Returns:
 *   The value as text.
 */
private string shortestFloatText(float value) @safe pure nothrow {
    if (!isFinite(value)) {
        return nonFiniteText(value);
    }
    foreach (precision; 1 .. 10) {
        immutable string text = formatG(precision, value);
        float back;
        if (text.length > 0 && tryParseFloat(text, back) && back == value) {
            return text;
        }
    }
    return formatG(9, value);
}

/**
 * The name of a value that is not a number.
 *
 * Params:
 *   value = The value.
 *
 * Returns:
 *   "nan", "inf" or "-inf".
 */
private string nonFiniteText(float value) @safe pure nothrow @nogc {
    if (value != value) {
        return "nan";
    }
    return value > 0.0f ? "inf" : "-inf";
}

/**
 * Writes a value with a number of significant digits in the style of C's %g. The format string is a literal,
 * so the call cannot fail in practice; should it throw, the result is "" and the caller takes another path.
 *
 * Params:
 *   precision = Significant digits, 1 to 9.
 *   value = The value.
 *
 * Returns:
 *   The formatted number, or "" when the formatter threw.
 */
private string formatG(int precision, float value) @safe pure nothrow {
    try {
        return format("%.*g", precision, value);
    } catch (Exception) {
        return "";
    }
}

/**
 * Reports whether a value is less than a bound in magnitude.
 *
 * Params:
 *   value = The value.
 *   bound = The bound.
 *
 * Returns:
 *   True when -bound < value < bound.
 */
private bool absLessThan(float value, float bound) @safe pure nothrow @nogc {
    return value > -bound && value < bound;
}



/**
 * The registered module descriptors. ModuleRegistry.descriptors() is not marked @safe although it only returns
 * a slice of a static immutable table, so this adapter is @trusted.
 *
 * Returns:
 *   All registered module descriptors in registration order.
 */
private immutable(ModuleDescriptor)[] registeredDescriptors() @trusted pure nothrow {
    return ModuleRegistry.descriptors();
}

/**
 * Finds a registered module type by its exact type id. ModuleRegistry.findByTypeId() is not marked @safe
 * although it only returns a pointer into a static immutable table or null, so this adapter is @trusted.
 *
 * Params:
 *   typeId = The type id.
 *
 * Returns:
 *   Pointer to the descriptor, or null.
 */
private const(ModuleDescriptor)* registeredType(string typeId) @trusted pure nothrow {
    return ModuleRegistry.findByTypeId(typeId);
}

/**
 * The presets of a library. InstrumentLibrary.entries() is not marked @safe or nothrow although it only returns
 * a slice of the library's list, so this adapter is @trusted; should it throw, the result is an empty list.
 *
 * Params:
 *   library = The library (not null).
 *
 * Returns:
 *   The entries of the last scan.
 */
private const(LibraryEntry)[] libraryEntries(const InstrumentLibrary library) @trusted nothrow {
    try {
        return library.entries();
    } catch (Exception) {
        return null;
    }
}

/**
 * Reads a .msym preset file with the app's loader, io.project_format.loadPresetFile(), which is not marked
 * @safe or nothrow although it reads the file into a bounds-checked reader; an exception of the file system
 * becomes the reason. The adapter is therefore @trusted.
 *
 * Params:
 *   path = Path of the file.
 *   preset = Receives the preset.
 *   err = Receives the reason on failure.
 *
 * Returns:
 *   True when the file was read.
 */
private bool readPresetFile(string path, out LoadedPreset preset, out string err) @trusted nothrow {
    try {
        return loadPresetFile(path, preset, err);
    } catch (Exception ex) {
        err = ex.msg.length > 0 ? ex.msg : "Failed reading .msym preset file";
        return false;
    }
}

/**
 * Writes a .msym preset file with the app's writer, io.project_format.savePreset(), which is not marked @safe or
 * nothrow although it only hands validated bytes to the file system; an exception becomes the reason. The
 * adapter is therefore @trusted.
 *
 * Params:
 *   preset = The preset.
 *   path = Destination path.
 *   err = Receives the reason on failure.
 *
 * Returns:
 *   True when the file was written.
 */
private bool savePresetFile(const ref LoadedPreset preset, string path, out string err) @trusted nothrow {
    try {
        return savePreset(preset, path, err);
    } catch (Exception ex) {
        err = ex.msg.length > 0 ? ex.msg : "Failed writing .msym preset file";
        return false;
    }
}
