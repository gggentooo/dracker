/**
 * File:         source/app/instrument_library.d
 * Module:       app.instrument_library
 * Phase:        Instrument library — T45 (bundled and user presets)
 *
 * Purpose:
 *   The list of module presets shown in the patchbay's instrument sidebar (decisions T35, T37). It scans the
 *   bundled preset folders (shipped with the app) and the user's folder
 *   (~/Library/Application Support/Dracker/Instruments) for .msym files. A preset's group is the folder it is in:
 *   Bass, Keys, Pads & Leads, Drums, Effects, any other folder name, or Other for files directly in the library
 *   folder. An entry's name is its file name without the extension. Unreadable files and presets of unknown
 *   module types are skipped and reported. Entries are sorted by group (the standard groups first, in that
 *   order, then other folder names, then Other) and by name without regard to case, bundled before user.
 *   User presets can be added from a module (an existing name gets a number added), renamed, moved to another
 *   group and removed (moved to the trash folder when one is set, else deleted); bundled presets cannot be
 *   changed. No GUI code.
 *
 * Real-Time & Safety Contract:
 *   UI/off-RT only; file I/O through std.file. Every operation reports failures as a sentence and leaves the
 *   library folder consistent.
 *
 * Dependencies:
 *   Internal: graph.module_api, graph.port, graph.registry, io.project_format
 *   External: std.file, std.path, std.process (HOME), std.uni (toLower)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum PresetOrigin; struct LibraryEntry; struct LibraryProblem; LIBRARY_GROUPS, OTHER_GROUP
 *   - class InstrumentLibrary (this(bundledDirs, userDir, trashDir), rescan(), entries(), groups(), problems(),
 *     load(), addFromModule(), rename(), moveToGroup(), remove(), userDirectory())
 *   - bundledPresetDirectories(), defaultUserInstrumentDirectory(), defaultTrashDirectory(), isValidPresetName()
 *
 * See_Also:
 *   docs/todo.md (T35, T37, T45), source/app/skeleton_gen.d
 */
module app.instrument_library;

import graph.module_api : ModuleDescriptor;
import graph.port : isAudioPort, PortDirection, PortKind;
import graph.registry : ModuleRegistry;
import io.project_format : LoadedPreset, loadPresetFile, SavedModule, savePreset;

/**
 * The standard groups, in the order the sidebar shows them.
 */
immutable string[] LIBRARY_GROUPS = ["Bass", "Keys", "Pads & Leads", "Drums", "Effects"];

/**
 * Group of presets that lie directly in a library folder.
 */
enum string OTHER_GROUP = "Other";

enum string PRESET_EXTENSION = ".msym";
enum size_t MAX_PRESET_NAME = 64;

/**
 * Where a preset comes from.
 */
enum PresetOrigin : ubyte {
    bundled = 0,
    user = 1
}

/**
 * One preset in the library.
 */
struct LibraryEntry {
    string name;
    string group;
    string path;
    PresetOrigin origin = PresetOrigin.bundled;
    string typeId;
    string typeName;
    bool playable = false;
}

/**
 * A file that was skipped during a scan, and why.
 */
struct LibraryProblem {
    string path;
    string reason;
}

/**
 * Reports whether text can be used as a preset or group name: 1 to MAX_PRESET_NAME bytes after trimming, no
 * path separators, colons or control characters, and not starting with a dot.
 *
 * Params:
 *   name = Proposed name.
 *
 * Returns:
 *   True if usable as a file or folder name.
 */
bool isValidPresetName(const(char)[] name) @safe pure nothrow @nogc {
    if (name.length == 0 || name.length > MAX_PRESET_NAME || name[0] == '.' || name[0] == ' ' || name[$ - 1] == ' ') {
        return false;
    }
    foreach (c; name) {
        if (c == '/' || c == '\\' || c == ':' || c < 0x20 || c == 0x7F) {
            return false;
        }
    }
    return true;
}

/**
 * Returns the folders bundled presets are read from: Contents/Resources/Presets in the app bundle, then
 * resources/presets next to a development build. Case-insensitive filesystem aliases to the same directory
 * are deduplicated.
 *
 * Returns:
 *   Existing unique directories, bundle first.
 */
string[] bundledPresetDirectories() {
    import std.file : exists, isDir, thisExePath;
    import std.path : buildNormalizedPath, dirName;

    string[] dirs;
    DirKey[] seen;
    try {
        immutable string exeDir = dirName(thisExePath());
        foreach (candidate; [buildNormalizedPath(exeDir, "..", "Resources", "Presets"),
                buildNormalizedPath(exeDir, "..", "resources", "presets")]) {
            if (exists(candidate) && isDir(candidate)) {
                DirKey key = directoryKey(candidate);
                if (!containsDirectoryKey(seen, key)) {
                    seen ~= key;
                    dirs ~= candidate;
                }
            }
        }
    } catch (Exception) {
    }
    return dirs;
}

private struct DirKey {
    ulong dev = 0;
    ulong ino = 0;
    string fallback;
    bool hasStat = false;
}

private DirKey directoryKey(string path) {
    import std.path : absolutePath, buildNormalizedPath;

    DirKey k;
    version (Posix) {
        import std.file : DirEntry;

        try {
            auto st = DirEntry(path).statBuf;
            k.dev = cast(ulong) st.st_dev;
            k.ino = cast(ulong) st.st_ino;
            k.hasStat = true;
            return k;
        } catch (Exception) {
        }
    }
    try {
        k.fallback = buildNormalizedPath(absolutePath(path));
    } catch (Exception) {
        k.fallback = path;
    }
    return k;
}

private bool sameDirectoryKey(const ref DirKey a, const ref DirKey b) @safe pure nothrow @nogc {
    if (a.hasStat && b.hasStat) {
        return a.dev == b.dev && a.ino == b.ino;
    }
    if (!a.hasStat && !b.hasStat) {
        return a.fallback == b.fallback;
    }
    return false;
}

private bool containsDirectoryKey(const(DirKey)[] list, const ref DirKey key) @safe pure nothrow @nogc {
    foreach (ref item; list) {
        if (sameDirectoryKey(item, key)) {
            return true;
        }
    }
    return false;
}

/**
 * Returns the user's instrument folder.
 *
 * Returns:
 *   ~/Library/Application Support/Dracker/Instruments, or "" when HOME is not set.
 */
string defaultUserInstrumentDirectory() {
    import std.path : buildPath;
    import std.process : environment;

    immutable string home = environment.get("HOME", "");
    return home.length == 0 ? "" : buildPath(home, "Library", "Application Support", "Dracker", "Instruments");
}

/**
 * Returns the user's Trash folder.
 *
 * Returns:
 *   ~/.Trash, or "" when HOME is not set.
 */
string defaultTrashDirectory() {
    import std.path : buildPath;
    import std.process : environment;

    immutable string home = environment.get("HOME", "");
    return home.length == 0 ? "" : buildPath(home, ".Trash");
}

/**
 * Preset library over bundled folders and one user folder.
 */
final class InstrumentLibrary {
    private string[] bundledDirs_;
    private string userDir_;
    private string trashDir_;
    private LibraryEntry[] entries_;
    private LibraryProblem[] problems_;

    /**
     * Creates the library and scans it.
     *
     * Params:
     *   bundledDirs = Folders of bundled presets (read-only; may be empty).
     *   userDir = The user's folder (created on the first add; "" disables user presets).
     *   trashDir = Folder removed presets are moved to ("" deletes them instead).
     */
    this(string[] bundledDirs, string userDir, string trashDir = "") {
        bundledDirs_ = bundledDirs.dup;
        userDir_ = userDir;
        trashDir_ = trashDir;
        rescan();
    }

    /**
     * Returns the user's folder.
     *
     * Returns:
     *   Path ("" when user presets are disabled).
     */
    string userDirectory() const {
        return userDir_;
    }

    /**
     * Returns the entries found by the last scan, sorted for display.
     *
     * Returns:
     *   Entries.
     */
    const(LibraryEntry)[] entries() const {
        return entries_;
    }

    /**
     * Returns the files the last scan skipped.
     *
     * Returns:
     *   Problems.
     */
    const(LibraryProblem)[] problems() const {
        return problems_;
    }

    /**
     * Returns the groups that have entries, in display order.
     *
     * Returns:
     *   Group names.
     */
    string[] groups() const {
        string[] list;
        foreach (ref e; entries_) {
            if (list.length == 0 || list[$ - 1] != e.group) {
                list ~= e.group;
            }
        }
        return list;
    }

    /**
     * Reads the folders again.
     */
    void rescan() {
        import std.file : exists, isDir;

        entries_ = null;
        problems_ = null;
        DirKey[] seenBundled;
        foreach (dir; bundledDirs_) {
            bool isExistingDir = false;
            try {
                isExistingDir = exists(dir) && isDir(dir);
            } catch (Exception) {
            }
            if (!isExistingDir) {
                continue;
            }
            DirKey key = directoryKey(dir);
            if (containsDirectoryKey(seenBundled, key)) {
                continue;
            }
            seenBundled ~= key;
            scanRoot(dir, PresetOrigin.bundled);
        }
        if (userDir_.length > 0) {
            scanRoot(userDir_, PresetOrigin.user);
        }
        sortEntries();
    }

    /**
     * Loads an entry's preset file.
     *
     * Params:
     *   e = Entry.
     *   preset = Receives the preset.
     *   err = Receives the reason on failure.
     *
     * Returns:
     *   True on success.
     */
    bool load(const ref LibraryEntry e, out LoadedPreset preset, out string err) {
        return loadPresetFile(e.path, preset, err);
    }

    /**
     * Saves a module as a user preset and rescans. When the group already has a user preset of that name, a
     * number is added ("Lead 2", "Lead 3", ...).
     *
     * Params:
     *   mod = Module to save (its id, position and name are stored as they are).
     *   name = Preset name.
     *   group = Group (folder) name; OTHER_GROUP stores it directly in the user folder.
     *   added = Receives the new entry.
     *   err = Receives the reason on failure.
     *
     * Returns:
     *   True on success.
     */
    bool addFromModule(const ref SavedModule mod, string name, string group, out LibraryEntry added, out string err) {
        import std.file : exists, mkdirRecurse;
        import std.path : buildPath;

        if (userDir_.length == 0) {
            err = "There is no user instrument folder";
            return false;
        }
        if (!isValidPresetName(name) || !isValidPresetName(group)) {
            err = "Names need 1 to 64 characters and cannot contain / \\ or :";
            return false;
        }
        immutable string dir = group == OTHER_GROUP ? userDir_ : buildPath(userDir_, group);
        string finalName = name;
        try {
            mkdirRecurse(dir);
            for (uint n = 2; exists(buildPath(dir, finalName ~ PRESET_EXTENSION)); n++) {
                finalName = name ~ " " ~ uintText(n);
            }
        } catch (Exception ex) {
            err = "Could not use the instrument folder: " ~ ex.msg;
            return false;
        }
        if (!isValidPresetName(finalName)) {
            err = "The name is too long";
            return false;
        }
        LoadedPreset preset;
        preset.presetName = finalName;
        preset.mod = cast(SavedModule) mod;
        immutable string path = buildPath(dir, finalName ~ PRESET_EXTENSION);
        if (!savePreset(preset, path, err)) {
            return false;
        }
        rescan();
        return findByPath(path, added, err);
    }

    /**
     * Renames a user preset: the file is renamed and the preset name inside it updated.
     *
     * Params:
     *   e = Entry (must be a user preset).
     *   newName = New name; refused when the group already has a preset of that name.
     *   renamed = Receives the entry under its new name.
     *   err = Receives the reason on failure.
     *
     * Returns:
     *   True on success.
     */
    bool rename(LibraryEntry e, string newName, out LibraryEntry renamed, out string err) {
        import std.file : exists, fileRemove = remove;
        import std.path : buildPath, dirName;

        if (!checkUser(e, err)) {
            return false;
        }
        if (!isValidPresetName(newName)) {
            err = "Names need 1 to 64 characters and cannot contain / \\ or :";
            return false;
        }
        immutable string target = buildPath(dirName(e.path), newName ~ PRESET_EXTENSION);
        if (target == e.path) {
            renamed = e;
            return true;
        }
        LoadedPreset preset;
        try {
            if (exists(target)) {
                err = "\"" ~ newName ~ "\" already exists in " ~ e.group;
                return false;
            }
            if (!loadPresetFile(e.path, preset, err)) {
                return false;
            }
            preset.presetName = newName;
            if (!savePreset(preset, target, err)) {
                return false;
            }
            fileRemove(e.path);
        } catch (Exception ex) {
            err = "Could not rename the preset: " ~ ex.msg;
            return false;
        }
        rescan();
        return findByPath(target, renamed, err);
    }

    /**
     * Moves a user preset to another group (folder).
     *
     * Params:
     *   e = Entry (must be a user preset).
     *   group = Target group; refused when it already has a preset of that name.
     *   moved = Receives the entry in its new group.
     *   err = Receives the reason on failure.
     *
     * Returns:
     *   True on success.
     */
    bool moveToGroup(LibraryEntry e, string group, out LibraryEntry moved, out string err) {
        import std.file : exists, fileRename = rename, mkdirRecurse;
        import std.path : buildPath;

        if (!checkUser(e, err)) {
            return false;
        }
        if (!isValidPresetName(group)) {
            err = "Group names need 1 to 64 characters and cannot contain / \\ or :";
            return false;
        }
        if (group == e.group) {
            moved = e;
            return true;
        }
        immutable string dir = group == OTHER_GROUP ? userDir_ : buildPath(userDir_, group);
        immutable string target = buildPath(dir, e.name ~ PRESET_EXTENSION);
        try {
            mkdirRecurse(dir);
            if (exists(target)) {
                err = "\"" ~ e.name ~ "\" already exists in " ~ group;
                return false;
            }
            fileRename(e.path, target);
        } catch (Exception ex) {
            err = "Could not move the preset: " ~ ex.msg;
            return false;
        }
        rescan();
        return findByPath(target, moved, err);
    }

    /**
     * Removes a user preset: its file is moved to the trash folder (under a free name), or deleted when the
     * library has no trash folder.
     *
     * Params:
     *   e = Entry (must be a user preset).
     *   err = Receives the reason on failure.
     *
     * Returns:
     *   True on success.
     */
    bool remove(LibraryEntry e, out string err) {
        import std.file : exists, fileRemove = remove, fileRename = rename, mkdirRecurse;
        import std.path : buildPath;

        if (!checkUser(e, err)) {
            return false;
        }
        try {
            if (trashDir_.length == 0) {
                fileRemove(e.path);
            } else {
                mkdirRecurse(trashDir_);
                string target = buildPath(trashDir_, e.name ~ PRESET_EXTENSION);
                for (uint n = 2; exists(target); n++) {
                    target = buildPath(trashDir_, e.name ~ " " ~ uintText(n) ~ PRESET_EXTENSION);
                }
                fileRename(e.path, target);
            }
        } catch (Exception ex) {
            err = "Could not remove the preset: " ~ ex.msg;
            return false;
        }
        rescan();
        return true;
    }

    private bool checkUser(const ref LibraryEntry e, out string err) {
        import std.file : exists;

        if (e.origin != PresetOrigin.user) {
            err = "Bundled presets cannot be changed";
            return false;
        }
        bool there = false;
        try {
            there = exists(e.path);
        } catch (Exception) {
        }
        if (!there) {
            err = "The preset file is no longer there";
            rescan();
            return false;
        }
        return true;
    }

    private bool findByPath(string path, out LibraryEntry found, out string err) {
        foreach (ref e; entries_) {
            if (e.path == path) {
                found = e;
                return true;
            }
        }
        err = "The preset could not be read back";
        return false;
    }

    private void scanRoot(string root, PresetOrigin origin) {
        import std.file : dirEntries, exists, isDir, SpanMode;
        import std.path : baseName;

        try {
            if (!exists(root) || !isDir(root)) {
                return;
            }
            foreach (item; dirEntries(root, SpanMode.shallow)) {
                immutable string base = baseName(item.name);
                if (base.length == 0 || base[0] == '.') {
                    continue;
                }
                if (item.isDir) {
                    foreach (inner; dirEntries(item.name, SpanMode.shallow)) {
                        if (!inner.isDir) {
                            scanFile(inner.name, base, origin);
                        }
                    }
                } else {
                    scanFile(item.name, OTHER_GROUP, origin);
                }
            }
        } catch (Exception ex) {
            problems_ ~= LibraryProblem(root, "Could not read the folder: " ~ ex.msg);
        }
    }

    private void scanFile(string path, string group, PresetOrigin origin) {
        import std.path : baseName;

        immutable string base = baseName(path);
        if (base.length <= PRESET_EXTENSION.length || base[0] == '.'
                || base[$ - PRESET_EXTENSION.length .. $] != PRESET_EXTENSION) {
            return;
        }
        LoadedPreset preset;
        string err;
        if (!loadPresetFile(path, preset, err)) {
            problems_ ~= LibraryProblem(path, err.length > 0 ? err : "Not a preset file");
            return;
        }
        const(ModuleDescriptor)* d = ModuleRegistry.findByTypeId(preset.mod.typeId);
        if (d is null) {
            problems_ ~= LibraryProblem(path, "Module type is not available: " ~ preset.mod.typeId);
            return;
        }
        LibraryEntry e;
        e.name = base[0 .. $ - PRESET_EXTENSION.length];
        e.group = group;
        e.path = path;
        e.origin = origin;
        e.typeId = preset.mod.typeId;
        e.typeName = d.displayName;
        e.playable = canPlay(d);
        entries_ ~= e;
    }

    private void sortEntries() {
        foreach (i; 1 .. entries_.length) {
            LibraryEntry x = entries_[i];
            size_t j = i;
            while (j > 0 && before(x, entries_[j - 1])) {
                entries_[j] = entries_[j - 1];
                j--;
            }
            entries_[j] = x;
        }
    }

    private static bool before(const ref LibraryEntry a, const ref LibraryEntry b) {
        immutable size_t ga = groupRank(a.group);
        immutable size_t gb = groupRank(b.group);
        if (ga != gb) {
            return ga < gb;
        }
        if (a.group != b.group) {
            return lower(a.group) < lower(b.group);
        }
        immutable string na = lower(a.name);
        immutable string nb = lower(b.name);
        if (na != nb) {
            return na < nb;
        }
        if (a.origin != b.origin) {
            return a.origin == PresetOrigin.bundled;
        }
        return a.path < b.path;
    }

    private static size_t groupRank(string group) {
        foreach (i, g; LIBRARY_GROUPS) {
            if (g == group) {
                return i;
            }
        }
        return group == OTHER_GROUP ? LIBRARY_GROUPS.length + 1 : LIBRARY_GROUPS.length;
    }

    private static string lower(string s) {
        import std.uni : toLower;

        try {
            return toLower(s);
        } catch (Exception) {
            return s;
        }
    }

    private static bool canPlay(const(ModuleDescriptor)* d) {
        bool eventIn = false;
        bool audioOut = false;
        foreach (ref p; d.ports) {
            eventIn = eventIn || (p.dir == PortDirection.input && p.kind == PortKind.event);
            audioOut = audioOut || (p.dir == PortDirection.output && isAudioPort(p.kind));
        }
        return eventIn && audioOut;
    }

    private static string uintText(uint v) {
        if (v < 10) {
            return [cast(immutable char)('0' + v)];
        }
        return uintText(v / 10) ~ uintText(v % 10);
    }
}
