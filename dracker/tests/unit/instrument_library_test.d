/**
 * File:         tests/unit/instrument_library_test.d
 * Module:       tests.unit.instrument_library_test
 * Phase:        Instrument library — T45 (bundled and user presets)
 *
 * Purpose:
 *   Verifies app.instrument_library with temporary folders: grouping by folder, display order, playable versus
 *   effect presets, skipped files (unreadable, unknown module type, other extensions, hidden files), missing
 *   folders, adding from a module with unique names, rename, move to group, remove to a trash folder and by
 *   deletion, bundled presets being read-only, and the name rules.
 *
 * Real-Time & Safety Contract:
 *   Off-RT file I/O in a per-process temporary folder that is removed with scope(exit).
 *
 * Dependencies:
 *   Internal: app.instrument_library, app.skeleton_gen, io.project_format
 *   External: std.conv, std.file, std.path, std.process
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) suites
 *
 * See_Also:
 *   docs/todo.md (T35, T37, T45)
 */
module tests.unit.instrument_library_test;

version (unittest) {
    import std.conv : to;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;

    import app.instrument_library;
    import app.skeleton_gen : defaultBassModule, defaultPianoModule, moduleWithDefaults;
    import io.project_format : LoadedPreset, SavedModule, savePreset;

    private void removeTree(string dir) nothrow {
        try {
            if (exists(dir)) {
                rmdirRecurse(dir);
            }
        } catch (Exception) {
        }
    }

    private void writePreset(string dir, string name, SavedModule mod) {
        mkdirRecurse(dir);
        LoadedPreset p;
        p.presetName = name;
        p.mod = mod;
        string err;
        assert(savePreset(p, buildPath(dir, name ~ ".msym"), err), err);
    }

    private string[] names(const(LibraryEntry)[] list) {
        string[] n;
        foreach (ref e; list) {
            n ~= e.group ~ "/" ~ e.name ~ (e.origin == PresetOrigin.user ? "*" : "");
        }
        return n;
    }

    unittest {
        assert(isValidPresetName("Warm Pad") && isValidPresetName("Pads & Leads") && isValidPresetName("A"));
        assert(!isValidPresetName("") && !isValidPresetName(".hidden") && !isValidPresetName("a/b") && !isValidPresetName("a:b"));
        assert(!isValidPresetName(" lead") && !isValidPresetName("lead ") && !isValidPresetName("a\\b"));
        assert(!isValidPresetName("tab\there"));
        char[] longName = new char[65];
        longName[] = 'x';
        assert(!isValidPresetName(longName) && isValidPresetName(longName[0 .. 64]));
        assert(LIBRARY_GROUPS == ["Bass", "Keys", "Pads & Leads", "Drums", "Effects"] && OTHER_GROUP == "Other");
        assert(defaultUserInstrumentDirectory().length == 0
            || defaultUserInstrumentDirectory()[$ - "Dracker/Instruments".length .. $] == "Dracker/Instruments");
        foreach (d; bundledPresetDirectories()) {
            assert(exists(d));
        }
    }

    unittest {
        immutable string root = buildPath(tempDir(), "dracker_library_" ~ to!string(thisProcessID()));
        removeTree(root);
        scope (exit) removeTree(root);
        immutable string bundled = buildPath(root, "bundled");
        immutable string user = buildPath(root, "user");
        immutable string trash = buildPath(root, "trash");

        auto emptyLib = new InstrumentLibrary([buildPath(root, "missing")], buildPath(root, "also missing"));
        assert(emptyLib.entries().length == 0 && emptyLib.problems().length == 0 && emptyLib.groups().length == 0);

        SavedModule reverb;
        assert(moduleWithDefaults("fx.reverb", 1, "Reverb", reverb));
        SavedModule kit;
        assert(moduleWithDefaults("synth.drumsynth", 1, "Kit", kit));
        writePreset(buildPath(bundled, "Bass"), "Electric Bass", defaultBassModule(1));
        writePreset(buildPath(bundled, "Keys"), "Electric Piano", defaultPianoModule(1));
        writePreset(buildPath(bundled, "Keys"), "bell", defaultPianoModule(1));
        writePreset(buildPath(bundled, "Drums"), "Drum Kit", kit);
        writePreset(buildPath(bundled, "Effects"), "Room Reverb", reverb);
        writePreset(bundled, "Loose", defaultBassModule(1));
        writePreset(buildPath(bundled, "Zebra"), "Stripe", defaultBassModule(1));
        writePreset(buildPath(bundled, "Alpha"), "First", defaultBassModule(1));
        write(buildPath(bundled, "Keys", "broken.msym"), "not a preset");
        write(buildPath(bundled, "Keys", "readme.txt"), "ignored");
        write(buildPath(bundled, "Keys", ".hidden.msym"), "ignored");
        SavedModule alien = defaultBassModule(1);
        alien.typeId = "synth.from_the_future";
        writePreset(buildPath(bundled, "Bass"), "Alien", alien);
        writePreset(buildPath(user, "Keys"), "Electric Piano", defaultPianoModule(1));
        writePreset(buildPath(user, "Bass"), "acid", defaultBassModule(1));

        auto lib = new InstrumentLibrary([bundled], user, trash);
        assert(names(lib.entries()) == ["Bass/acid*", "Bass/Electric Bass", "Keys/bell", "Keys/Electric Piano",
            "Keys/Electric Piano*", "Drums/Drum Kit", "Effects/Room Reverb", "Alpha/First", "Zebra/Stripe", "Other/Loose"]);
        assert(lib.groups() == ["Bass", "Keys", "Drums", "Effects", "Alpha", "Zebra", "Other"]);
        assert(lib.problems().length == 2);
        bool sawBroken = false, sawAlien = false;
        foreach (ref p; lib.problems()) {
            sawBroken = sawBroken || p.path == buildPath(bundled, "Keys", "broken.msym");
            sawAlien = sawAlien || (p.path == buildPath(bundled, "Bass", "Alien.msym")
                && p.reason == "Module type is not available: synth.from_the_future");
        }
        assert(sawBroken && sawAlien);
        foreach (ref e; lib.entries()) {
            assert(e.playable == (e.group != "Effects"), e.name);
            assert(e.typeName.length > 0 && exists(e.path));
        }
        assert(lib.entries()[1].typeId == "synth.analog_gen" && lib.entries()[1].typeName == "Analog Generator");
        assert(lib.entries()[6].typeId == "fx.reverb" && !lib.entries()[6].playable);
        LoadedPreset loaded;
        string err;
        assert(lib.load(lib.entries()[1], loaded, err) && loaded.presetName == "Electric Bass");
        assert(loaded.mod.paramValues == defaultBassModule(1).paramValues);

        LibraryEntry added;
        SavedModule lead = defaultBassModule(9);
        lead.name = "My Lead";
        assert(lib.addFromModule(lead, "Lead", "Pads & Leads", added, err), err);
        assert(added.name == "Lead" && added.group == "Pads & Leads" && added.origin == PresetOrigin.user && added.playable);
        assert(added.path == buildPath(user, "Pads & Leads", "Lead.msym") && exists(added.path));
        LibraryEntry second;
        assert(lib.addFromModule(lead, "Lead", "Pads & Leads", second, err) && second.name == "Lead 2");
        LibraryEntry third;
        assert(lib.addFromModule(lead, "Lead", "Pads & Leads", third, err) && third.name == "Lead 3");
        LibraryEntry loose;
        assert(lib.addFromModule(reverb, "Hall", OTHER_GROUP, loose, err) && loose.group == "Other" && !loose.playable);
        assert(loose.path == buildPath(user, "Hall.msym"));
        assert(lib.groups() == ["Bass", "Keys", "Pads & Leads", "Drums", "Effects", "Alpha", "Zebra", "Other"]);
        assert(lib.load(second, loaded, err) && loaded.presetName == "Lead 2" && loaded.mod.name == "My Lead");
        LibraryEntry ignored;
        assert(!lib.addFromModule(lead, "a/b", "Bass", ignored, err) && err.length > 0);
        assert(!lib.addFromModule(lead, "ok", "", ignored, err) && !lib.addFromModule(lead, "", "Bass", ignored, err));
        immutable size_t countBefore = lib.entries().length;

        LibraryEntry renamed;
        assert(lib.rename(second, "Soft Lead", renamed, err), err);
        assert(renamed.name == "Soft Lead" && !exists(second.path) && exists(renamed.path));
        assert(lib.load(renamed, loaded, err) && loaded.presetName == "Soft Lead");
        assert(lib.entries().length == countBefore);
        assert(!lib.rename(renamed, "Lead", ignored, err) && err == "\"Lead\" already exists in Pads & Leads");
        assert(!lib.rename(renamed, "bad:name", ignored, err));
        assert(lib.rename(renamed, "Soft Lead", ignored, err) && ignored.path == renamed.path);
        assert(!lib.rename(second, "Gone", ignored, err) && err == "The preset file is no longer there");
        assert(!lib.rename(lib.entries()[1], "Mine", ignored, err) && err == "Bundled presets cannot be changed");

        LibraryEntry moved;
        assert(lib.moveToGroup(renamed, "Keys", moved, err), err);
        assert(moved.group == "Keys" && moved.path == buildPath(user, "Keys", "Soft Lead.msym") && !exists(renamed.path));
        assert(lib.moveToGroup(moved, "Keys", ignored, err) && ignored.path == moved.path);
        assert(lib.moveToGroup(moved, OTHER_GROUP, moved, err) && moved.path == buildPath(user, "Soft Lead.msym"));
        assert(lib.moveToGroup(moved, "My Sounds", moved, err) && moved.group == "My Sounds");
        LibraryEntry clash;
        assert(lib.addFromModule(lead, "Soft Lead", "Keys", clash, err));
        assert(!lib.moveToGroup(clash, "My Sounds", ignored, err) && err == "\"Soft Lead\" already exists in My Sounds");
        assert(!lib.moveToGroup(lib.entries()[1], "Keys", ignored, err) && err == "Bundled presets cannot be changed");
        assert(!lib.moveToGroup(clash, "a/b", ignored, err));

        assert(lib.remove(clash, err), err);
        assert(!exists(clash.path) && exists(buildPath(trash, "Soft Lead.msym")));
        assert(lib.remove(moved, err) && exists(buildPath(trash, "Soft Lead 2.msym")));
        assert(!lib.remove(moved, err) && err == "The preset file is no longer there");
        assert(!lib.remove(lib.entries()[1], err) && err == "Bundled presets cannot be changed" && exists(lib.entries()[1].path));

        auto noTrash = new InstrumentLibrary([bundled], user, "");
        LibraryEntry victim;
        foreach (ref e; noTrash.entries()) {
            if (e.name == "Lead 3") {
                victim = cast(LibraryEntry) e;
            }
        }
        assert(victim.path.length > 0 && noTrash.remove(victim, err) && !exists(victim.path));
        lib.rescan();
        foreach (ref e; lib.entries()) {
            assert(e.name != "Lead 3" && e.name != "Soft Lead");
        }

        auto readOnly = new InstrumentLibrary([bundled], "");
        assert(readOnly.userDirectory() == "" && !readOnly.addFromModule(lead, "x", "Bass", ignored, err));
        assert(err == "There is no user instrument folder");
        foreach (ref e; readOnly.entries()) {
            assert(e.origin == PresetOrigin.bundled);
        }
    }

    unittest {
        immutable string root = buildPath(tempDir(), "dracker_lib_dedup_" ~ to!string(thisProcessID()));
        removeTree(root);
        scope (exit) removeTree(root);
        immutable string bundled = buildPath(root, "bundled");
        writePreset(buildPath(bundled, "Bass"), "Electric Bass", defaultBassModule(1));
        writePreset(buildPath(bundled, "Keys"), "Electric Piano", defaultPianoModule(1));

        auto dupSame = new InstrumentLibrary([bundled, bundled], "");
        assert(names(dupSame.entries()) == ["Bass/Electric Bass", "Keys/Electric Piano"]);

        immutable string upperVariant = buildPath(root, "BUNDLED");
        if (exists(upperVariant)) {
            auto dupCase = new InstrumentLibrary([bundled, upperVariant], "");
            assert(names(dupCase.entries()) == ["Bass/Electric Bass", "Keys/Electric Piano"]);
        }

        string[] bundledDirs = bundledPresetDirectories();
        assert(bundledDirs.length <= 1);
        auto realLib = new InstrumentLibrary(bundledDirs, "");
        bool[string] seen;
        foreach (ref e; realLib.entries()) {
            immutable string key = e.group ~ "\0" ~ e.name;
            assert((key in seen) is null);
            seen[key] = true;
        }
    }
}
