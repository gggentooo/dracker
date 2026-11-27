/**
 * File:         source/compose/catalog.d
 * Module:       compose.catalog
 * Phase:        Composition helper (dracker-compose) — T85 (Catalog)
 *
 * Purpose:
 *   Generates the script-authoring catalog for `dracker-compose catalog [topic]` in both plain text
 *   and JSON forms: registered module types grouped by category; per-module ports and parameters with
 *   range, default, unit, scale, and discrete option names; bundled and user instrument presets grouped
 *   by library folder; chord notation syntax and qualities; bundled preset chord progressions; all 24
 *   musical keys with their scale notes; and the script command table generated live from the
 *   ScriptInterpreter so it cannot drift out of date.
 *
 * Real-Time & Safety Contract:
 *   Off-RT only. Formats text and JSON cleanly with no stdout/stderr side effects.
 *
 * Dependencies:
 *   Internal: app.chord_progression (chordIntervals, ChordQuality, PROGRESSION_PRESETS),
 *             app.instrument_library (bundledPresetDirectories, defaultUserInstrumentDirectory,
 *             InstrumentLibrary, LibraryEntry, PresetOrigin), app.music_theory (allKeys, keyName,
 *             KeyMode, MusicalKey, pitchClassName, scalePitchClasses), compose.module_writer
 *             (parameterRangeText, parameterValueText), compose.names (namesMatch, nearestName, trim),
 *             compose.script.commands (createDefaultInterpreter), compose.script.interpreter
 *             (ArgKind, CommandSpec), compose_main (JsonWriter), graph.module_api (ModuleCategory,
 *             ModuleDescriptor, ParamDescriptor, ParamScale), graph.port (PortDescriptor,
 *             PortDirection, PortKind), graph.registry (ModuleRegistry)
 *   External: std.format (format)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct CatalogResult
 *   - runCatalog()
 *
 * See_Also:
 *   docs/todo.md (T66, T83, T85), source/compose_main.d, source/graph/registry.d
 */
module compose.catalog;

import std.format : format;

import app.chord_progression : chordIntervals, ChordQuality, PROGRESSION_PRESETS;
import app.instrument_library : bundledPresetDirectories, defaultUserInstrumentDirectory,
    InstrumentLibrary, LibraryEntry, PresetOrigin;
import app.music_theory : allKeys, keyName, KeyMode, MusicalKey, pitchClassName, scalePitchClasses;
import compose.module_writer : parameterRangeText, parameterValueText;
import compose.names : namesMatch, nearestName, trim;
import compose.script.commands : createDefaultInterpreter;
import compose.script.interpreter : ArgKind, CommandSpec, ScriptInterpreter;
import compose_main : JsonWriter;
import graph.module_api : ModuleCategory, ModuleDescriptor, ParamDescriptor, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;
import graph.registry : ModuleRegistry;

/**
 * Output of querying the composition catalog for a topic or all topics.
 */
struct CatalogResult {
    bool ok = false;
    string text = "";
    string json = "";
    string error = "";
    string suggestion = "";
}

private immutable string[6] STANDARD_TOPICS = [
    "modules", "presets", "chords", "progressions", "keys", "commands"
];

private struct ChordDocEntry {
    ChordQuality quality;
    string name;
    string suffixes;
}

private immutable ChordDocEntry[] CHORD_QUALITIES = [
    ChordDocEntry(ChordQuality.major, "major", "(none)"),
    ChordDocEntry(ChordQuality.minor, "minor", "m"),
    ChordDocEntry(ChordQuality.diminished, "diminished", "dim, °"),
    ChordDocEntry(ChordQuality.augmented, "augmented", "aug, +"),
    ChordDocEntry(ChordQuality.sus2, "suspended 2nd", "sus2"),
    ChordDocEntry(ChordQuality.sus4, "suspended 4th", "sus4"),
    ChordDocEntry(ChordQuality.dominant7, "dominant 7th", "7"),
    ChordDocEntry(ChordQuality.major7, "major 7th", "maj7"),
    ChordDocEntry(ChordQuality.minor7, "minor 7th", "m7"),
    ChordDocEntry(ChordQuality.halfDiminished7, "half-diminished 7th", "m7b5, ø, ø7"),
    ChordDocEntry(ChordQuality.diminished7, "diminished 7th", "dim7, °7")
];

private string categoryLabel(ModuleCategory cat) @safe pure nothrow @nogc {
    final switch (cat) {
        case ModuleCategory.core:
            return "core";
        case ModuleCategory.synth:
            return "synth";
        case ModuleCategory.effect:
            return "effect";
        case ModuleCategory.control:
            return "control";
    }
}

private string portDirectionLabel(PortDirection dir) @safe pure nothrow @nogc {
    return dir == PortDirection.input ? "in" : "out";
}

private string portKindLabel(PortKind kind) @safe pure nothrow @nogc {
    final switch (kind) {
        case PortKind.audioStereo:
            return "audioStereo";
        case PortKind.audioMono:
            return "audioMono";
        case PortKind.sidechainStereo:
            return "sidechainStereo";
        case PortKind.cvControl:
            return "cvControl";
        case PortKind.event:
            return "event";
    }
}

private string paramScaleLabel(ParamScale scale) @safe pure nothrow @nogc {
    final switch (scale) {
        case ParamScale.linear:
            return "linear";
        case ParamScale.logarithmic:
            return "logarithmic";
        case ParamScale.discrete:
            return "discrete";
    }
}

private string argKindLabel(ArgKind kind) @safe pure nothrow @nogc {
    final switch (kind) {
        case ArgKind.text:
            return "text";
        case ArgKind.word:
            return "word";
        case ArgKind.number:
            return "number";
        case ArgKind.integer:
            return "integer";
        case ArgKind.path:
            return "path";
        case ArgKind.key:
            return "key";
        case ArgKind.timeSignature:
            return "signature";
    }
}

private void writeModulesSection(ref string txt, ref JsonWriter json, const(ModuleDescriptor)[] descs)
        @safe nothrow {
    static immutable ModuleCategory[4] CATS = [
        ModuleCategory.core, ModuleCategory.synth, ModuleCategory.effect, ModuleCategory.control
    ];
    txt ~= "Modules:\n";
    json.key("modules");
    json.beginArray();
    foreach (cat; CATS) {
        txt ~= "  [" ~ categoryLabel(cat) ~ "]\n";
        foreach (ref d; descs) {
            if (d.category != cat) {
                continue;
            }
            try {
                txt ~= format("    %-22s  %-22s  (%d ports, %d params)\n",
                    d.typeId, d.displayName, d.ports.length, d.params.length);
            } catch (Exception) {
                txt ~= "    " ~ d.typeId ~ "  " ~ d.displayName ~ "\n";
            }
            json.beginObject();
            json.key("typeId");
            json.valueString(d.typeId);
            json.key("displayName");
            json.valueString(d.displayName);
            json.key("category");
            json.valueString(categoryLabel(d.category));
            json.key("portCount");
            json.valueInt(cast(long) d.ports.length);
            json.key("paramCount");
            json.valueInt(cast(long) d.params.length);
            json.endObject();
        }
    }
    json.endArray();
}

private void writeModuleDetail(ref string txt, ref JsonWriter json, const ref ModuleDescriptor d)
        @safe nothrow {
    txt ~= "Module: " ~ d.displayName ~ " (" ~ d.typeId ~ ", " ~ categoryLabel(d.category) ~ ")\n";
    txt ~= "Ports:\n";
    json.key("module");
    json.beginObject();
    json.key("typeId");
    json.valueString(d.typeId);
    json.key("displayName");
    json.valueString(d.displayName);
    json.key("category");
    json.valueString(categoryLabel(d.category));
    json.key("ports");
    json.beginArray();
    foreach (ref p; d.ports) {
        txt ~= "  " ~ p.id ~ " (" ~ p.name ~ "): " ~ portDirectionLabel(p.dir) ~ " " ~ portKindLabel(p.kind) ~ "\n";
        json.beginObject();
        json.key("id");
        json.valueString(p.id);
        json.key("name");
        json.valueString(p.name);
        json.key("direction");
        json.valueString(portDirectionLabel(p.dir));
        json.key("kind");
        json.valueString(portKindLabel(p.kind));
        json.endObject();
    }
    json.endArray();

    txt ~= "Parameters:\n";
    if (d.params.length == 0) {
        txt ~= "  (none)\n";
    }
    json.key("params");
    json.beginArray();
    foreach (ref p; d.params) {
        txt ~= "  " ~ p.name ~ ": " ~ parameterRangeText(p) ~ ", default "
            ~ parameterValueText(p, p.defaultVal) ~ "\n";
        if (p.options.length > 0) {
            txt ~= "    options:";
            foreach (idx, opt; p.options) {
                txt ~= (idx > 0 ? ", " : " ") ~ opt;
            }
            txt ~= "\n";
        }
        json.beginObject();
        json.key("name");
        json.valueString(p.name);
        json.key("min");
        json.valueDouble(p.minVal);
        json.key("max");
        json.valueDouble(p.maxVal);
        json.key("default");
        json.valueDouble(p.defaultVal);
        json.key("defaultText");
        json.valueString(parameterValueText(p, p.defaultVal));
        json.key("unit");
        json.valueString(p.unit);
        json.key("scale");
        json.valueString(paramScaleLabel(p.scale));
        json.key("options");
        json.beginArray();
        foreach (opt; p.options) {
            json.valueString(opt);
        }
        json.endArray();
        json.endObject();
    }
    json.endArray();
    json.endObject();
}

private void writePresetsSection(ref string txt, ref JsonWriter json, const InstrumentLibrary lib)
        @trusted nothrow {
    txt ~= "Presets:\n";
    json.key("presets");
    json.beginArray();
    const(LibraryEntry)[] entries;
    const(string)[] groups;
    if (lib !is null) {
        try {
            entries = lib.entries();
            groups = lib.groups();
        } catch (Throwable) {
            entries = null;
            groups = null;
        }
    }
    foreach (g; groups) {
        txt ~= "  [" ~ g ~ "]\n";
        foreach (ref e; entries) {
            if (e.group != g) {
                continue;
            }
            immutable string orig = e.origin == PresetOrigin.bundled ? "bundled" : "user";
            txt ~= "    " ~ e.name ~ " (" ~ e.typeId ~ ", " ~ orig ~ ")\n";
            json.beginObject();
            json.key("name");
            json.valueString(e.name);
            json.key("group");
            json.valueString(e.group);
            json.key("typeId");
            json.valueString(e.typeId);
            json.key("origin");
            json.valueString(orig);
            json.endObject();
        }
    }
    json.endArray();
}

private void writeChordsSection(ref string txt, ref JsonWriter json) @safe nothrow {
    txt ~= "Chords:\n";
    txt ~= "  Roman numerals: [b|#] I..VII / i..vii + suffix (e.g. iii, V7, bVII, ø7)\n";
    txt ~= "  Chord names: A..G [#|b] + suffix [/bass] (e.g. Cmaj7, Am, Dm7, C/E)\n";
    json.key("chords");
    json.beginObject();
    json.key("syntax");
    json.beginArray();
    json.valueString("Roman numerals: [b|#] I..VII / i..vii + quality suffix (no slash bass)");
    json.valueString("Chord names: A..G [#|b] + quality suffix + optional /bass");
    json.endArray();
    json.key("qualities");
    json.beginArray();
    foreach (ref q; CHORD_QUALITIES) {
        immutable ubyte[] ivs = chordIntervals(q.quality);
        string ivText;
        foreach (idx, v; ivs) {
            ivText ~= (idx > 0 ? " " : "");
            try {
                ivText ~= format("%d", v);
            } catch (Exception) {
                ivText ~= "0";
            }
        }
        txt ~= "  " ~ q.name ~ " (" ~ q.suffixes ~ "): intervals [" ~ ivText ~ "]\n";
        json.beginObject();
        json.key("name");
        json.valueString(q.name);
        json.key("suffixes");
        json.valueString(q.suffixes);
        json.key("intervals");
        json.beginArray();
        foreach (v; ivs) {
            json.valueInt(v);
        }
        json.endArray();
        json.endObject();
    }
    json.endArray();
    json.endObject();
}

private void writeProgressionsSection(ref string txt, ref JsonWriter json) @safe pure nothrow {
    txt ~= "Preset Progressions:\n";
    json.key("progressions");
    json.beginArray();
    foreach (ref p; PROGRESSION_PRESETS) {
        immutable string modeName = p.mode == KeyMode.major ? "major" : "minor";
        txt ~= "  " ~ p.name ~ " (" ~ modeName ~ "): " ~ p.text ~ "\n";
        json.beginObject();
        json.key("name");
        json.valueString(p.name);
        json.key("mode");
        json.valueString(modeName);
        json.key("chords");
        json.valueString(p.text);
        json.endObject();
    }
    json.endArray();
}

private void writeKeysSection(ref string txt, ref JsonWriter json) @safe pure nothrow {
    txt ~= "Keys:\n";
    json.key("keys");
    json.beginArray();
    immutable MusicalKey[24] keys = allKeys();
    foreach (k; keys) {
        immutable string name = keyName(k);
        immutable ubyte[7] pcs = scalePitchClasses(k);
        string scaleText;
        foreach (i, pc; pcs) {
            scaleText ~= (i > 0 ? " " : "") ~ pitchClassName(pc, k);
        }
        txt ~= "  " ~ name ~ ": " ~ scaleText ~ "\n";
        json.beginObject();
        json.key("name");
        json.valueString(name);
        json.key("tonic");
        json.valueInt(k.tonic);
        json.key("mode");
        json.valueString(k.mode == KeyMode.major ? "major" : "minor");
        json.key("scale");
        json.beginArray();
        foreach (pc; pcs) {
            json.valueString(pitchClassName(pc, k));
        }
        json.endArray();
        json.endObject();
    }
    json.endArray();
}

private void writeCommandsSection(ref string txt, ref JsonWriter json, const(CommandSpec)[] table)
        @safe pure nothrow {
    txt ~= "Commands:\n";
    json.key("commands");
    json.beginArray();
    foreach (ref cmd; table) {
        string sig = cmd.name;
        foreach (ref a; cmd.args) {
            sig ~= a.required ? (" <" ~ a.name ~ ">") : (" [" ~ a.name ~ "]");
        }
        foreach (ref o; cmd.options) {
            sig ~= " [" ~ o.name ~ "=<" ~ argKindLabel(o.kind) ~ ">]";
        }
        if (cmd.allowAnyOptions) {
            sig ~= " [<Param>=<value> ...]";
        }
        txt ~= "  " ~ sig ~ "\n    " ~ cmd.summary ~ "\n";

        json.beginObject();
        json.key("name");
        json.valueString(cmd.name);
        json.key("summary");
        json.valueString(cmd.summary);
        json.key("allowAnyOptions");
        json.valueBool(cmd.allowAnyOptions);
        json.key("args");
        json.beginArray();
        foreach (ref a; cmd.args) {
            json.beginObject();
            json.key("name");
            json.valueString(a.name);
            json.key("kind");
            json.valueString(argKindLabel(a.kind));
            json.key("required");
            json.valueBool(a.required);
            json.key("summary");
            json.valueString(a.summary);
            json.endObject();
        }
        json.endArray();
        json.key("options");
        json.beginArray();
        foreach (ref o; cmd.options) {
            json.beginObject();
            json.key("name");
            json.valueString(o.name);
            json.key("kind");
            json.valueString(argKindLabel(o.kind));
            json.key("summary");
            json.valueString(o.summary);
            json.endObject();
        }
        json.endArray();
        json.endObject();
    }
    json.endArray();
}

private const(ModuleDescriptor)* findModuleDescriptor(const(ModuleDescriptor)[] descs, string topic)
        @safe pure nothrow {
    foreach (i; 0 .. descs.length) {
        if (namesMatch(descs[i].typeId, topic) || namesMatch(descs[i].displayName, topic)) {
            return &descs[i];
        }
    }
    return null;
}

private const(ModuleDescriptor)[] loadRegistryDescriptors() @trusted nothrow {
    return ModuleRegistry.descriptors();
}

private InstrumentLibrary resolveCatalogLibrary(const InstrumentLibrary supplied) @trusted nothrow {
    if (supplied !is null) {
        return cast(InstrumentLibrary) supplied;
    }
    try {
        return new InstrumentLibrary(bundledPresetDirectories(), defaultUserInstrumentDirectory());
    } catch (Throwable) {
        return null;
    }
}

/**
 * Generates the composition catalog for a given topic ("modules", "presets", "chords",
 * "progressions", "keys", "commands", a specific module type/display name, or "" / "all" for the
 * complete catalog) in both plain text and JSON forms.
 *
 * Params:
 *   topic = Requested topic or module name, or "" for all sections.
 *   library = Optional pre-scanned InstrumentLibrary (defaults to bundled + user preset dirs).
 *
 * Returns:
 *   CatalogResult with ok=true, text, and json on success, or error + nearest suggestion on unknown topic.
 */
CatalogResult runCatalog(string topic = "", const InstrumentLibrary library = null) @safe nothrow {
    immutable string clean = trim(topic);
    const(ModuleDescriptor)[] descs = loadRegistryDescriptors();
    ScriptInterpreter interp = createDefaultInterpreter(true);
    const(CommandSpec)[] table = interp.commandTable();
    InstrumentLibrary lib = resolveCatalogLibrary(library);

    string txt;
    JsonWriter json = JsonWriter();
    json.beginObject();
    json.key("ok");
    json.valueBool(true);
    json.key("topic");
    json.valueString(clean.length == 0 ? "all" : clean);

    if (clean.length == 0 || namesMatch(clean, "all")) {
        writeModulesSection(txt, json, descs);
        txt ~= "\n";
        writePresetsSection(txt, json, lib);
        txt ~= "\n";
        writeChordsSection(txt, json);
        txt ~= "\n";
        writeProgressionsSection(txt, json);
        txt ~= "\n";
        writeKeysSection(txt, json);
        txt ~= "\n";
        writeCommandsSection(txt, json, table);
    } else if (namesMatch(clean, "modules")) {
        writeModulesSection(txt, json, descs);
    } else if (namesMatch(clean, "presets")) {
        writePresetsSection(txt, json, lib);
    } else if (namesMatch(clean, "chords")) {
        writeChordsSection(txt, json);
    } else if (namesMatch(clean, "progressions")) {
        writeProgressionsSection(txt, json);
    } else if (namesMatch(clean, "keys")) {
        writeKeysSection(txt, json);
    } else if (namesMatch(clean, "commands")) {
        writeCommandsSection(txt, json, table);
    } else {
        const(ModuleDescriptor)* mod = findModuleDescriptor(descs, clean);
        if (mod is null) {
            string[] allNames;
            foreach (t; STANDARD_TOPICS) {
                allNames ~= t;
            }
            foreach (ref d; descs) {
                allNames ~= d.typeId;
            }
            return CatalogResult(false, "", "",
                "unknown catalog topic '" ~ clean ~ "'", nearestName(clean, allNames));
        }
        writeModuleDetail(txt, json, *mod);
    }

    json.endObject();
    return CatalogResult(true, txt, json.text() ~ "\n", "", "");
}
