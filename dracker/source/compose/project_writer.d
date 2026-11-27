/**
 * File:         source/compose/project_writer.d
 * Module:       compose.project_writer
 * Phase:        Composition helper (dracker-compose) — T76 & T96 (Project writer: modules, wires, saving)
 *
 * Purpose:
 *   Holds one project being built: its title, tempo, ticks per line, time signature and key, its modules
 *   under the handle names a script will use, and the wires between their ports. Master Output exists from
 *   the start as "out". Modules are added from ModuleWriter, renamed, given a displayed name, repositioned
 *   (automatic layout when no position is given) and removed (which also drops their wires). Wires are
 *   checked by handle, port name, direction, port kind compatibility, duplicate check, gain validity and
 *   GraphCompiler cycle check (rejecting feedback loops unless broken by a Feedback module). Before writing
 *   .msv bytes or a file, the project runs through both the app's save checks and a trial activation in
 *   StudioSession. Problems come back as data — kind, subject, reason and the nearest valid handle, port or
 *   value — so a front end decides how to show them.
 *
 * Real-Time & Safety Contract:
 *   Off-RT. Public API is @safe nothrow; saveProjectFile, checkGraphWires and activateProjectInSession are
 *   localized @trusted adapters around GraphCompiler, StudioSession and saveProject.
 *
 * Dependencies:
 *   Internal: app.music_theory (KeyMode, MusicalKey), app.session (StudioSession), compose.module_writer
 *             (ModuleWriter, ModuleEditResult, ModuleWriterResult), compose.names (namesMatch, nearestName,
 *             trim), compose.timing (TimeSignature, formatTimeSignature, defaultTimeSignature),
 *             foundation.types (ModuleId), graph.module_api (ModuleDescriptor), graph.plan
 *             (GraphCompileError, GraphCompiler, GraphPlan, NodeSpec, WireSpec), graph.port
 *             (arePortsCompatible, isAudioPort, PortDescriptor, PortDirection, PortKind), io.project_format
 *             (LoadedProject, SavedModule, SavedPattern, SavedWire, limits, validators, serializer, writer),
 *             sequencer.note (NoteCell), sequencer.timeline (TimelineClip)
 *   External: std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum OUTPUT_HANDLE/OUTPUT_TYPE_ID/OUTPUT_MODULE_ID and the layout and starter constants
 *   - enum ProjectProblemKind; struct ProjectProblem; ProjectEditResult; ProjectIdResult; ProjectModuleResult;
 *     ProjectWire; ProjectDocumentResult; ProjectBytesResult; ProjectKeyResult
 *   - final class ProjectWriter: title(), tempo(), ticksPerLine(), timeSignature(), key(), moduleCount(),
 *     handles(), hasModule(), moduleId(), moduleOf(), addModule(), addModuleAt(), renameModule(),
 *     setModuleName(), moveModule(), removeModule(), wireCount(), wires(), connect(), disconnect(),
 *     setTitle(), setTempo(), setTicksPerLine(), setTimeSignature(), setKey(), document(), trialActivate(),
 *     documentBytes(), writeDocument(), msvBytes(), writeFile()
 *   - isValidHandle(); suggestedHandle(); parseKey()
 *
 * See_Also:
 *   docs/todo.md (T67, T74, T76, T77, T92, T96), source/compose/module_writer.d, source/app/session.d
 */
module compose.project_writer;

import std.math : isFinite;

import app.music_theory : KeyMode, MusicalKey;
import app.session : StudioSession;
import compose.module_writer : ModuleEditResult, ModuleProblem, ModuleWriter, ModuleWriterResult;
import compose.names : namesMatch, nearestName, trim;
import compose.timing : TimeSignature, formatTimeSignature, defaultTimeSignature;
import foundation.types : ModuleId;
import graph.module_api : ModuleDescriptor;
import graph.plan : GraphCompileError, GraphCompiler, GraphPlan, NodeSpec, WireSpec;
import graph.port : arePortsCompatible, isAudioPort, PortDescriptor, PortDirection, PortKind;
import io.project_format : LoadedProject, loadProject, loadProjectFile, MAX_MODULES, MAX_PROJECT_BPM,
    MAX_PROJECT_TPL, MAX_STRING_LEN, MAX_WIRES, MIN_PROJECT_BPM, SavedModule, SavedPattern, SavedWire,
    isValidKey, isValidTempo, saveProject, serializeProject, validateProjectForSave;
import sequencer.note : NoteCell;
import sequencer.timeline : TimelineClip;

/** The handle of the Master Output, which a project has from the start. */
enum string OUTPUT_HANDLE = "out";

/** The module type id of the Master Output. */
enum string OUTPUT_TYPE_ID = "core.output";

/** The module id the Master Output holds, the same id a new app project gives it. */
enum uint OUTPUT_MODULE_ID = 1;

/** The longest handle a module name may be. */
enum size_t MAX_HANDLE_LENGTH = 32;

/** The top-left corner of the automatic module layout, as the app places its first module. */
enum float LAYOUT_ORIGIN_X = 60.0f;

/** The top-left corner's y of the automatic module layout. */
enum float LAYOUT_ORIGIN_Y = 60.0f;

/** The x step between layout columns, the same step StudioSession.freeModulePosition uses. */
enum float LAYOUT_COLUMN_STEP = 180.0f;

/** The y step between layout rows. */
enum float LAYOUT_ROW_STEP = 160.0f;

/** How many automatic modules fit in one layout column. */
enum uint LAYOUT_ROWS = 4;

/** The track count of the starter pattern a new app project writes. */
enum uint STARTER_PATTERN_TRACKS = 4;

/** The line count of the starter pattern a new app project writes. */
enum uint STARTER_PATTERN_LINES = 64;

/** The name of the starter pattern a new app project writes. */
enum string STARTER_PATTERN_NAME = "Pattern 01";

/** The kinds of problem a project writer returns as data. */
enum ProjectProblemKind : ubyte {
    invalidTitle = 0,
    invalidTempo = 1,
    invalidTicksPerLine = 2,
    invalidTimeSignature = 3,
    invalidKey = 4,
    invalidHandle = 5,
    duplicateHandle = 6,
    unknownHandle = 7,
    protectedModule = 8,
    notLoaded = 9,
    tooManyModules = 10,
    invalidPosition = 11,
    invalidProject = 12,
    writeFailed = 13,
    invalidName = 14,
    unknownPort = 15,
    invalidPortDirection = 16,
    incompatiblePorts = 17,
    duplicateWire = 18,
    unknownWire = 19,
    tooManyWires = 20,
    invalidGain = 21,
    feedbackLoop = 22
}

/**
 * A problem found by the project writer, returned as data so a front end decides how to show it.
 */
struct ProjectProblem {
    ProjectProblemKind kind = ProjectProblemKind.invalidProject;
    string subject = "";
    string reason = "";
    string suggestion = "";

    /**
     * Writes the problem as one sentence: the reason, then the suggestion when there is one.
     *
     * Returns:
     *   The reason followed by "; did you mean '...'?" for a handle problem, or by
     *   "; the nearest valid value is ..." for any other problem.
     */
    string text() const @safe pure nothrow {
        string result = reason;
        if (suggestion.length > 0) {
            result ~= isHandleProblem(kind) ? "; did you mean '" ~ suggestion ~ "'?"
                : "; the nearest valid value is " ~ suggestion;
        }
        return result;
    }
}

/**
 * The outcome of a change to a project writer.
 */
struct ProjectEditResult {
    bool ok = false;
    ProjectProblem problem = ProjectProblem.init;
}

/**
 * A module id together with whether the call produced one.
 */
struct ProjectIdResult {
    uint id = 0;
    bool ok = false;
    ProjectProblem problem = ProjectProblem.init;
}

/**
 * A copy of a module writer together with its module id and whether the lookup found the handle.
 */
struct ProjectModuleResult {
    ModuleWriter writer = ModuleWriter.init;
    uint id = 0;
    bool ok = false;
    ProjectProblem problem = ProjectProblem.init;
}

/**
 * A finished project document together with whether it passed the app's save checks.
 */
struct ProjectDocumentResult {
    LoadedProject project;
    bool ok = false;
    ProjectProblem problem = ProjectProblem.init;
}

/**
 * Serialized .msv bytes together with whether they could be written.
 */
struct ProjectBytesResult {
    ubyte[] bytes;
    bool ok = false;
    ProjectProblem problem = ProjectProblem.init;
}

/**
 * A parsed key together with whether the text named one.
 */
struct ProjectKeyResult {
    MusicalKey key = MusicalKey.init;
    bool ok = false;
    ProjectProblem problem = ProjectProblem.init;
}

/**
 * One wire in the project, reported with current module handles, port names, ids, port indices and gain.
 */
struct ProjectWire {
    string srcHandle;
    string srcPort;
    string dstHandle;
    string dstPort;
    uint srcModuleId = 0;
    ushort srcPortIndex = 0;
    uint dstModuleId = 0;
    ushort dstPortIndex = 0;
    float gain = 1.0f;
}

/**
 * Internal stored wire keyed by module ids so renaming a module preserves all its wires.
 */
struct WireEntry {
    uint srcId = 0;
    ushort srcPort = 0;
    uint dstId = 0;
    ushort dstPort = 0;
    float gain = 1.0f;
}

/**
 * Mapping assigned when opening an existing .msv file: the saved module id, its derived handle, and its
 * original displayed name.
 */
struct LoadedModuleHandle {
    uint id = 0;
    string handle = "";
    string name = "";
}

/**
 * Result of opening an existing project document, bytes, or .msv file into a ProjectWriter.
 */
struct ProjectOpenResult {
    ProjectWriter writer = null;
    LoadedModuleHandle[] handles;
    bool ok = false;
    ProjectProblem problem = ProjectProblem.init;
}

/**
 * One module of the project: its handle, its id, a copy of its writer, and where it sits. An entry that was
 * never given a position is laid out automatically when the document is written.
 */
private struct ModuleEntry {
    string handle;
    uint id = 0;
    ModuleWriter writer;
    bool placed = false;
    float posX = 0.0f;
    float posY = 0.0f;

    /**
     * Builds one entry, copying the writer so a change to the caller's writer never changes the project.
     *
     * Params:
     *   handle = The handle the module is known under.
     *   id = The module id assigned to it.
     *   writer = The writer holding the module; copied.
     *   placed = Whether an explicit position was given.
     *   posX = The x the module sits at when placed.
     *   posY = The y the module sits at when placed.
     */
    this(string handle, uint id, ref const ModuleWriter writer, bool placed, float posX, float posY)
            @safe pure nothrow {
        this.handle = handle;
        this.id = id;
        this.writer = ModuleWriter(writer);
        this.placed = placed;
        this.posX = posX;
        this.posY = posY;
    }

    /**
     * Copies an entry, copying the writer's module too.
     *
     * Params:
     *   other = The entry to copy.
     */
    this(ref return scope const ModuleEntry other) @safe pure nothrow {
        handle = other.handle;
        id = other.id;
        writer = ModuleWriter(other.writer);
        placed = other.placed;
        posX = other.posX;
        posY = other.posY;
    }
}

/**
 * Writes a whole number in decimal.
 *
 * Params:
 *   value = The number.
 *
 * Returns:
 *   The number as text, such as "1024".
 */
private string wholeText(ulong value) @safe pure nothrow {
    char[] digits;
    do {
        digits ~= cast(char) ('0' + (value % 10));
        value /= 10;
    } while (value > 0);
    char[] text = new char[digits.length];
    foreach (i; 0 .. digits.length) {
        text[i] = digits[digits.length - 1 - i];
    }
    return text.idup;
}

/**
 * Uppercases an ASCII letter.
 *
 * Params:
 *   c = The character.
 *
 * Returns:
 *   The upper-case letter; other characters unchanged.
 */
private char upperAscii(char c) @safe pure nothrow @nogc {
    return c >= 'a' && c <= 'z' ? cast(char) (c - ('a' - 'A')) : c;
}

/**
 * Reports whether a character is an ASCII letter.
 *
 * Params:
 *   c = The character.
 *
 * Returns:
 *   True for A to Z and a to z.
 */
private bool isAsciiLetter(char c) @safe pure nothrow @nogc {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

/**
 * Reports whether a character may appear in a handle.
 *
 * Params:
 *   c = The character.
 *
 * Returns:
 *   True for ASCII letters, digits, '_' and '-'.
 */
private bool isHandleChar(char c) @safe pure nothrow @nogc {
    return isAsciiLetter(c) || (c >= '0' && c <= '9') || c == '_' || c == '-';
}

/**
 * Reports whether a text is a handle: one bare word the script language takes — ASCII letters, digits, '_'
 * and '-', the first a letter, at most MAX_HANDLE_LENGTH bytes.
 *
 * Params:
 *   text = The text to check.
 *
 * Returns:
 *   True when the text can be a handle.
 */
bool isValidHandle(string text) @safe pure nothrow @nogc {
    if (text.length == 0 || text.length > MAX_HANDLE_LENGTH || !isAsciiLetter(text[0])) {
        return false;
    }
    foreach (c; text) {
        if (!isHandleChar(c)) {
            return false;
        }
    }
    return true;
}

/**
 * The handle nearest to a text: the characters a handle takes are kept (the first must be a letter), cut at
 * MAX_HANDLE_LENGTH bytes.
 *
 * Params:
 *   text = The text as written.
 *
 * Returns:
 *   The nearest handle, or "module" when nothing of the text can be kept.
 */
string suggestedHandle(string text) @safe pure nothrow {
    string kept;
    foreach (c; text) {
        if (isHandleChar(c) && (kept.length > 0 || isAsciiLetter(c)) && kept.length < MAX_HANDLE_LENGTH) {
            kept ~= c;
        }
    }
    return kept.length > 0 ? kept : "module";
}

/**
 * Reports whether a problem kind is about a module handle, displayed name or port name, which is suggested
 * with "did you mean".
 *
 * Params:
 *   kind = The problem kind.
 *
 * Returns:
 *   True for handle, name, and port lookup problems.
 */
private bool isHandleProblem(ProjectProblemKind kind) @safe pure nothrow @nogc {
    return kind == ProjectProblemKind.invalidHandle || kind == ProjectProblemKind.duplicateHandle
        || kind == ProjectProblemKind.unknownHandle || kind == ProjectProblemKind.protectedModule
        || kind == ProjectProblemKind.invalidName || kind == ProjectProblemKind.unknownPort
        || kind == ProjectProblemKind.invalidPortDirection;
}

/**
 * Human-readable label for a port kind.
 *
 * Params:
 *   kind = The port kind.
 *
 * Returns:
 *   Short label describing the port kind.
 */
private string portKindLabel(PortKind kind) @safe pure nothrow @nogc {
    final switch (kind) {
        case PortKind.audioStereo:
            return "stereo audio";
        case PortKind.audioMono:
            return "mono audio";
        case PortKind.sidechainStereo:
            return "sidechain";
        case PortKind.cvControl:
            return "CV";
        case PortKind.event:
            return "event";
    }
}

/**
 * Human-readable label for a GraphCompileError.
 *
 * Params:
 *   err = The compile error.
 *
 * Returns:
 *   Short diagnostic text.
 */
private string graphErrorText(GraphCompileError err) @safe pure nothrow @nogc {
    final switch (err) {
        case GraphCompileError.none:
            return "no error";
        case GraphCompileError.cycleDetected:
            return "graph contains a feedback loop";
        case GraphCompileError.invalidNode:
            return "graph references an invalid module";
        case GraphCompileError.duplicateNodeId:
            return "graph contains a duplicate module id";
        case GraphCompileError.invalidPort:
            return "graph references an invalid port";
        case GraphCompileError.invalidDirection:
            return "wire connects incompatible port directions";
        case GraphCompileError.incompatiblePorts:
            return "wire connects incompatible port kinds";
        case GraphCompileError.outOfMemory:
            return "out of memory compiling graph";
    }
}

/**
 * Checks a handle, filling the problem with invalidHandle and the nearest handle when it is not one.
 *
 * Params:
 *   handle = The handle to check.
 *   problem = Receives the problem when the handle is invalid.
 *
 * Returns:
 *   True when the handle is valid.
 */
private bool checkHandle(string handle, out ProjectProblem problem) @safe pure nothrow {
    if (isValidHandle(handle)) {
        return true;
    }
    problem = ProjectProblem(ProjectProblemKind.invalidHandle, handle,
        "a module name starts with a letter and holds only letters, digits, '_' and '-', at most "
        ~ wholeText(MAX_HANDLE_LENGTH) ~ " characters", suggestedHandle(handle));
    return false;
}

/**
 * The problem for a position that is not two finite numbers.
 *
 * Params:
 *   handle = The handle of the module that was to be placed.
 *
 * Returns:
 *   The problem.
 */
private ProjectProblem positionProblem(string handle) @safe pure nothrow {
    return ProjectProblem(ProjectProblemKind.invalidPosition, handle,
        "the position of '" ~ handle ~ "' must be two finite numbers", "");
}

/**
 * The problem for changing the Master Output, which a project always keeps.
 *
 * Params:
 *   handle = The handle that was given.
 *   action = What was tried ("renamed", "removed").
 *
 * Returns:
 *   The problem.
 */
private ProjectProblem protectedProblem(string handle, string action) @safe pure nothrow {
    return ProjectProblem(ProjectProblemKind.protectedModule, handle,
        "the Master Output '" ~ OUTPUT_HANDLE ~ "' cannot be " ~ action, "");
}

/**
 * One project being built: its properties and its modules under handle names. The Master Output exists from
 * the start as "out" with id 1. Module ids are never reused, because pattern notes will store them (T77).
 * A project is never copied; T77 and T83 share one writer.
 */
final class ProjectWriter {
    private string title_ = LoadedProject.init.title;
    private double bpm_ = LoadedProject.init.bpm;
    private uint ticksPerLine_ = LoadedProject.init.ticksPerLine;
    private TimeSignature signature_;
    private MusicalKey key_;
    private ModuleEntry[] entries_;
    private WireEntry[] wires_;
    private uint nextModuleId_ = OUTPUT_MODULE_ID + 1;
    private bool hasPreservedBase_ = false;
    private LoadedProject preservedBase_;

    /**
     * Starts a project with the app's defaults ("Untitled", 125.0 bpm, 6 ticks per line, 4/4, C major) and
     * the Master Output as "out".
     */
    this() @safe nothrow {
        ModuleWriterResult master = ModuleWriter.fromType(OUTPUT_TYPE_ID);
        entries_ ~= ModuleEntry(OUTPUT_HANDLE, OUTPUT_MODULE_ID, master.writer, false, 0.0f, 0.0f);
    }

    /**
     * Opens an existing LoadedProject into a new ProjectWriter (T82), deriving unique handles from each
     * module's name and preserving patterns, clips, loop range, author, format version, MIDI mappings,
     * drum lanes, module extra data, and MetaModule children verbatim.
     *
     * Params:
     *   proj = Parsed or constructed LoadedProject.
     *
     * Returns:
     *   ProjectOpenResult with populated ProjectWriter and handle table, or invalidProject.
     */
    static ProjectOpenResult fromLoadedProject(const ref LoadedProject proj) @safe nothrow {
        string err;
        if (!validateProjectForSave(proj, err)) {
            return ProjectOpenResult(null, null, false, ProjectProblem(ProjectProblemKind.invalidProject,
                proj.title, "the project cannot be opened: " ~ err, ""));
        }
        ProjectWriter w = new ProjectWriter();
        w.entries_ = null;
        w.wires_ = null;
        w.title_ = proj.title;
        w.bpm_ = proj.bpm;
        w.ticksPerLine_ = proj.ticksPerLine;
        w.signature_ = TimeSignature(proj.timeSigNumerator, proj.timeSigDenominator);
        w.key_ = MusicalKey(proj.keyTonic, cast(KeyMode) proj.keyMode);
        w.hasPreservedBase_ = true;
        w.preservedBase_ = copyPreservedBase(proj);

        uint maxId = OUTPUT_MODULE_ID;
        LoadedModuleHandle[] assigned;
        foreach (ref sm; proj.modules) {
            ModuleWriterResult modRes = ModuleWriter.fromSavedModule(sm);
            if (!modRes.ok) {
                return ProjectOpenResult(null, null, false, ProjectProblem(ProjectProblemKind.invalidProject,
                    sm.name.length > 0 ? sm.name : sm.typeId, modRes.problem.reason, modRes.problem.suggestion));
            }
            string baseHandle;
            if (sm.id == OUTPUT_MODULE_ID || modRes.writer.descriptor().isOutput) {
                baseHandle = w.indexOfHandle(OUTPUT_HANDLE) == w.entries_.length
                    ? OUTPUT_HANDLE : suggestedHandle(sm.name.length > 0 ? sm.name : OUTPUT_HANDLE);
            } else {
                baseHandle = suggestedHandle(sm.name);
            }
            immutable string handle = w.indexOfHandle(baseHandle) == w.entries_.length
                ? baseHandle : w.freeHandle(baseHandle);
            w.entries_ ~= ModuleEntry(handle, sm.id, modRes.writer, true, sm.posX, sm.posY);
            assigned ~= LoadedModuleHandle(sm.id, handle, sm.name);
            if (sm.id > maxId) {
                maxId = sm.id;
            }
        }
        w.nextModuleId_ = maxId + 1;
        foreach (ref wire; proj.wires) {
            w.wires_ ~= WireEntry(wire.srcMod, wire.srcPort, wire.dstMod, wire.dstPort, wire.gain);
        }
        return ProjectOpenResult(w, assigned, true);
    }

    /**
     * Opens serialized .msv bytes into a new ProjectWriter (T82).
     *
     * Params:
     *   bytes = Raw .msv bytes.
     *
     * Returns:
     *   ProjectOpenResult.
     */
    static ProjectOpenResult fromBytes(const(ubyte)[] bytes) @safe nothrow {
        LoadedProject proj;
        string err;
        if (!loadProject(bytes, proj, err)) {
            return ProjectOpenResult(null, null, false, ProjectProblem(ProjectProblemKind.invalidProject,
                "", "could not open the project: " ~ err, ""));
        }
        return fromLoadedProject(proj);
    }

    /**
     * Opens an existing .msv file from disk into a new ProjectWriter (T82).
     *
     * Params:
     *   path = Source .msv file path.
     *
     * Returns:
     *   ProjectOpenResult.
     */
    static ProjectOpenResult fromFile(string path) @safe nothrow {
        LoadedProject proj;
        string err;
        if (!loadProjectFileSafe(path, proj, err)) {
            return ProjectOpenResult(null, null, false, ProjectProblem(ProjectProblemKind.invalidProject,
                path, "could not open '" ~ path ~ "': " ~ err, ""));
        }
        return fromLoadedProject(proj);
    }

    /**
     * Loads a single saved module verbatim (including extraBlob and MetaModule children) from an
     * existing .msv file by numeric module id for `module <handle> keep=<file>:<id>` (T87).
     *
     * Params:
     *   path = Source .msv file path.
     *   modId = Saved module id inside the project.
     *
     * Returns:
     *   ModuleWriterResult wrapping fromSavedModule(sm), or unreadablePreset/unknownModuleType.
     */
    static ModuleWriterResult loadKeptModule(string path, uint modId) @safe nothrow {
        import compose.module_writer : ModuleProblemKind;

        LoadedProject proj;
        string err;
        if (!loadProjectFileSafe(path, proj, err)) {
            return ModuleWriterResult(ModuleWriter.init, false, ModuleProblem(
                ModuleProblemKind.unreadablePreset, path,
                "could not open kept module source '" ~ path ~ "': " ~ err, ""));
        }
        foreach (ref sm; proj.modules) {
            if (sm.id == modId) {
                return ModuleWriter.fromSavedModule(sm);
            }
        }
        return ModuleWriterResult(ModuleWriter.init, false, ModuleProblem(
            ModuleProblemKind.unreadablePreset, path,
            "module id " ~ wholeText(modId) ~ " was not found in '" ~ path ~ "'", ""));
    }

    /**
     * Returns the project title.
     *
     * Returns:
     *   The title.
     */
    string title() const @safe nothrow {
        return title_;
    }

    /**
     * Returns the tempo.
     *
     * Returns:
     *   Beats per minute.
     */
    double tempo() const @safe nothrow {
        return bpm_;
    }

    /**
     * Returns the tick (line) count per line of the clock.
     *
     * Returns:
     *   Ticks per line.
     */
    uint ticksPerLine() const @safe nothrow {
        return ticksPerLine_;
    }

    /**
     * Returns the time signature.
     *
     * Returns:
     *   The signature.
     */
    TimeSignature timeSignature() const @safe nothrow {
        return signature_;
    }

    /**
     * Returns the song key.
     *
     * Returns:
     *   The key.
     */
    MusicalKey key() const @safe nothrow {
        return key_;
    }

    /**
     * Returns how many modules the project holds, Master Output included.
     *
     * Returns:
     *   The module count.
     */
    size_t moduleCount() const @safe nothrow {
        return entries_.length;
    }

    /**
     * Lists the module handles in the order they were added.
     *
     * Returns:
     *   The handles.
     */
    string[] handles() const @safe nothrow {
        string[] names;
        foreach (ref entry; entries_) {
            names ~= entry.handle;
        }
        return names;
    }

    /**
     * Reports whether a handle names a module, matched without regard to case or spaces.
     *
     * Params:
     *   handle = The handle to look for.
     *
     * Returns:
     *   True when the project holds that module.
     */
    bool hasModule(string handle) const @safe nothrow {
        return indexOfHandle(handle) != entries_.length;
    }

    /**
     * Returns the id of a module.
     *
     * Params:
     *   handle = The handle of the module.
     *
     * Returns:
     *   The id, or unknownHandle with the nearest handle.
     */
    ProjectIdResult moduleId(string handle) const @safe nothrow {
        immutable size_t index = indexOfHandle(handle);
        if (index == entries_.length) {
            return ProjectIdResult(0, false, unknownHandleProblem(handle));
        }
        return ProjectIdResult(entries_[index].id, true);
    }

    /**
     * Adds a module under a handle, laid out automatically when the document is written. The writer is copied,
     * and its displayed name becomes the handle.
     *
     * Params:
     *   handle = The handle the module is known under.
     *   writer = The writer holding the module; taken by value.
     *
     * Returns:
     *   The new module id, or invalidHandle, duplicateHandle, notLoaded, protectedModule or tooManyModules.
     */
    ProjectIdResult addModule(string handle, ModuleWriter writer) @safe nothrow {
        return insertModule(handle, writer, false, 0.0f, 0.0f);
    }

    /**
     * Adds a module under a handle at an explicit position.
     *
     * Params:
     *   handle = The handle the module is known under.
     *   writer = The writer holding the module; taken by value.
     *   x = The x of the module.
     *   y = The y of the module.
     *
     * Returns:
     *   The new module id, or invalidPosition first when x or y is not finite, otherwise the refusals of
     *   addModule.
     */
    ProjectIdResult addModuleAt(string handle, ModuleWriter writer, float x, float y) @safe nothrow {
        if (!isFinite(x) || !isFinite(y)) {
            return ProjectIdResult(0, false, positionProblem(handle));
        }
        return insertModule(handle, writer, true, x, y);
    }

    /**
     * Renames a module's handle; its displayed name follows the new handle. The Master Output keeps its
     * handle and name.
     *
     * Params:
     *   handle = The current handle.
     *   newHandle = The handle to use from now on.
     *
     * Returns:
     *   ok, or unknownHandle, protectedModule, invalidHandle or duplicateHandle.
     */
    ProjectEditResult renameModule(string handle, string newHandle) @safe nothrow {
        immutable size_t index = indexOfHandle(handle);
        if (index == entries_.length) {
            return ProjectEditResult(false, unknownHandleProblem(handle));
        }
        if (entries_[index].id == OUTPUT_MODULE_ID) {
            return ProjectEditResult(false, protectedProblem(handle, "renamed"));
        }
        ProjectProblem problem;
        if (!checkHandle(newHandle, problem)) {
            return ProjectEditResult(false, problem);
        }
        immutable size_t taken = indexOfHandle(newHandle);
        if (taken != entries_.length && taken != index) {
            return ProjectEditResult(false, duplicateProblem(newHandle));
        }
        entries_[index].handle = newHandle;
        entries_[index].writer.setName(newHandle);
        return ProjectEditResult(true);
    }

    /**
     * Replaces a module's stored ModuleWriter (keeping its handle, module id, layout placement, and wires),
     * optionally keeping its existing displayed name.
     *
     * Params:
     *   handle = Module handle.
     *   writer = New writer (copied; must match module type if preserving wires).
     *   keepDisplayedName = When true, keeps the module's existing displayed name if non-empty.
     *   problemOut = Optional module problem from name/descriptor validation.
     *
     * Returns:
     *   ok, or unknownHandle / notLoaded.
     */
    ProjectEditResult replaceModuleWriter(string handle, ModuleWriter writer, bool keepDisplayedName = true)
            @safe nothrow {
        immutable size_t index = indexOfHandle(handle);
        if (index == entries_.length) {
            return ProjectEditResult(false, unknownHandleProblem(handle));
        }
        if (!writer.loaded()) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.notLoaded, handle,
                "the module writer for '" ~ handle ~ "' holds no module", ""));
        }
        immutable string prevName = entries_[index].writer.name();
        ModuleWriter stored = ModuleWriter(writer);
        if (keepDisplayedName && prevName.length > 0) {
            cast(void) stored.setName(prevName);
        }
        entries_[index].writer = stored;
        return ProjectEditResult(true);
    }

    /**
     * Sets a parameter on a module by text (decimal number or discrete option name).
     *
     * Params:
     *   handle = Module handle.
     *   paramName = Parameter display name (matched case/space-insensitively).
     *   valueText = Parameter value text.
     *
     * Returns:
     *   ok, or unknownHandle / parameter error.
     */
    ProjectEditResult setModuleParam(string handle, string paramName, string valueText) @safe nothrow {
        immutable size_t index = indexOfHandle(handle);
        if (index == entries_.length) {
            return ProjectEditResult(false, unknownHandleProblem(handle));
        }
        immutable ModuleEditResult res = entries_[index].writer.setParamText(paramName, valueText);
        if (!res.ok) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidName,
                res.problem.subject, res.problem.reason, res.problem.suggestion));
        }
        return ProjectEditResult(true);
    }

    /**
     * Sets a module's displayed name, which may differ from its handle. The Master Output keeps its name.
     *
     * Params:
     *   handle = The handle of the module.
     *   name = The name to show in the app (the same rule ModuleWriter.setName applies).
     *
     * Returns:
     *   ok, or unknownHandle, protectedModule, or invalidName with the nearest valid name.
     */
    ProjectEditResult setModuleName(string handle, string name) @safe nothrow {
        immutable size_t index = indexOfHandle(handle);
        if (index == entries_.length) {
            return ProjectEditResult(false, unknownHandleProblem(handle));
        }
        if (entries_[index].id == OUTPUT_MODULE_ID) {
            return ProjectEditResult(false, protectedProblem(handle, "renamed"));
        }
        immutable ModuleEditResult renamed = entries_[index].writer.setName(name);
        if (!renamed.ok) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidName,
                renamed.problem.subject, renamed.problem.reason, renamed.problem.suggestion));
        }
        return ProjectEditResult(true);
    }

    /**
     * Moves a module to an explicit position, so it stops taking an automatic layout slot.
     *
     * Params:
     *   handle = The handle of the module.
     *   x = The x of the module.
     *   y = The y of the module.
     *
     * Returns:
     *   ok, or unknownHandle, or invalidPosition when x or y is not finite.
     */
    ProjectEditResult moveModule(string handle, float x, float y) @safe nothrow {
        immutable size_t index = indexOfHandle(handle);
        if (index == entries_.length) {
            return ProjectEditResult(false, unknownHandleProblem(handle));
        }
        if (!isFinite(x) || !isFinite(y)) {
            return ProjectEditResult(false, positionProblem(handle));
        }
        entries_[index].placed = true;
        entries_[index].posX = x;
        entries_[index].posY = y;
        return ProjectEditResult(true);
    }

    /**
     * Removes a module and every wire connected to it. The Master Output cannot be removed.
     *
     * Params:
     *   handle = The handle of the module.
     *
     * Returns:
     *   ok, or unknownHandle or protectedModule.
     */
    ProjectEditResult removeModule(string handle) @safe nothrow {
        immutable size_t index = indexOfHandle(handle);
        if (index == entries_.length) {
            return ProjectEditResult(false, unknownHandleProblem(handle));
        }
        if (entries_[index].id == OUTPUT_MODULE_ID) {
            return ProjectEditResult(false, protectedProblem(handle, "removed"));
        }
        immutable uint removedId = entries_[index].id;
        ModuleEntry[] kept;
        foreach (i; 0 .. entries_.length) {
            if (i != index) {
                kept ~= entries_[i];
            }
        }
        entries_ = kept;
        WireEntry[] keptWires;
        foreach (ref w; wires_) {
            if (w.srcId != removedId && w.dstId != removedId) {
                keptWires ~= w;
            }
        }
        wires_ = keptWires;
        return ProjectEditResult(true);
    }

    /**
     * Returns how many wires the project currently holds.
     *
     * Returns:
     *   Wire count.
     */
    size_t wireCount() const @safe nothrow {
        return wires_.length;
    }

    /**
     * Lists all wires in insertion order using current module handles and port display names.
     *
     * Returns:
     *   Array of ProjectWire snapshots.
     */
    ProjectWire[] wires() const @safe nothrow {
        ProjectWire[] list;
        list.reserve(wires_.length);
        foreach (ref w; wires_) {
            immutable size_t si = indexOfId(w.srcId);
            immutable size_t di = indexOfId(w.dstId);
            if (si == entries_.length || di == entries_.length) {
                continue;
            }
            auto sPorts = entries_[si].writer.descriptor().ports;
            auto dPorts = entries_[di].writer.descriptor().ports;
            immutable string sPortName = w.srcPort < sPorts.length ? sPorts[w.srcPort].name : "";
            immutable string dPortName = w.dstPort < dPorts.length ? dPorts[w.dstPort].name : "";
            list ~= ProjectWire(entries_[si].handle, sPortName, entries_[di].handle, dPortName,
                w.srcId, w.srcPort, w.dstId, w.dstPort, w.gain);
        }
        return list;
    }

    /**
     * Connects an output port on srcHandle to an input port on dstHandle with a gain factor.
     *
     * Empty srcPort / dstPort default to the first audio output / first audio input port of the module.
     * Validates handles, port names (with nearest-name suggestions), directions, port kind compatibility,
     * gain, duplicates, wire limit, and GraphCompiler cycle checks (allowing loops broken by a Feedback module).
     *
     * Params:
     *   srcHandle = Source module handle.
     *   dstHandle = Destination module handle.
     *   gain = Linear wire gain (finite, >= 0, default 1.0).
     *   srcPort = Source output port id or name, or "" for first audio output.
     *   dstPort = Destination input port id or name, or "" for first audio input.
     *
     * Returns:
     *   ok, or unknownHandle, unknownPort, invalidPortDirection, incompatiblePorts, invalidGain,
     *   duplicateWire, tooManyWires, feedbackLoop or invalidProject.
     */
    ProjectEditResult connect(string srcHandle, string dstHandle, float gain = 1.0f,
            string srcPort = "", string dstPort = "") @safe nothrow {
        immutable size_t si = indexOfHandle(srcHandle);
        if (si == entries_.length) {
            return ProjectEditResult(false, unknownHandleProblem(srcHandle));
        }
        immutable size_t di = indexOfHandle(dstHandle);
        if (di == entries_.length) {
            return ProjectEditResult(false, unknownHandleProblem(dstHandle));
        }
        if (!isFinite(gain) || gain < 0.0f) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidGain, "gain",
                "wire gain must be a finite number of 0 or more", "1"));
        }

        ushort srcPortIdx = 0;
        ProjectProblem portProb;
        if (!resolvePort(entries_[si], srcPort, PortDirection.output, srcPortIdx, portProb)) {
            return ProjectEditResult(false, portProb);
        }
        ushort dstPortIdx = 0;
        if (!resolvePort(entries_[di], dstPort, PortDirection.input, dstPortIdx, portProb)) {
            return ProjectEditResult(false, portProb);
        }

        immutable auto sDesc = entries_[si].writer.descriptor().ports[srcPortIdx];
        immutable auto dDesc = entries_[di].writer.descriptor().ports[dstPortIdx];
        if (!arePortsCompatible(sDesc.kind, dDesc.kind)) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.incompatiblePorts,
                entries_[si].handle ~ " -> " ~ entries_[di].handle,
                "cannot connect " ~ portKindLabel(sDesc.kind) ~ " port '" ~ sDesc.name ~ "' on '"
                ~ entries_[si].handle ~ "' to " ~ portKindLabel(dDesc.kind) ~ " port '" ~ dDesc.name
                ~ "' on '" ~ entries_[di].handle ~ "'", ""));
        }

        immutable uint sId = entries_[si].id;
        immutable uint dId = entries_[di].id;
        foreach (ref existing; wires_) {
            if (existing.srcId == sId && existing.srcPort == srcPortIdx
                    && existing.dstId == dId && existing.dstPort == dstPortIdx) {
                return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.duplicateWire,
                    entries_[si].handle ~ " -> " ~ entries_[di].handle,
                    "a wire from '" ~ entries_[si].handle ~ "' (" ~ sDesc.name ~ ") to '"
                    ~ entries_[di].handle ~ "' (" ~ dDesc.name ~ ") already exists", ""));
            }
        }
        if (wires_.length >= MAX_WIRES) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.tooManyWires,
                entries_[si].handle ~ " -> " ~ entries_[di].handle,
                "a project holds at most " ~ wholeText(MAX_WIRES) ~ " wires", ""));
        }

        WireEntry candidate = WireEntry(sId, srcPortIdx, dId, dstPortIdx, gain);
        GraphCompileError compileErr = GraphCompileError.none;
        if (!checkGraphWithCandidate(candidate, compileErr)) {
            if (compileErr == GraphCompileError.cycleDetected) {
                return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.feedbackLoop,
                    entries_[si].handle ~ " -> " ~ entries_[di].handle,
                    "connecting '" ~ entries_[si].handle ~ "' to '" ~ entries_[di].handle
                    ~ "' creates a feedback loop; break the loop with a Feedback module", ""));
            }
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidProject,
                entries_[si].handle ~ " -> " ~ entries_[di].handle,
                "the graph rejected the wire: " ~ graphErrorText(compileErr), ""));
        }

        wires_ ~= candidate;
        return ProjectEditResult(true);
    }

    /**
     * Removes an existing wire between srcHandle and dstHandle.
     *
     * Empty srcPort / dstPort resolve to the default first audio output / first audio input.
     *
     * Params:
     *   srcHandle = Source module handle.
     *   dstHandle = Destination module handle.
     *   srcPort = Source output port id or name, or "" for first audio output.
     *   dstPort = Destination input port id or name, or "" for first audio input.
     *
     * Returns:
     *   ok, or unknownHandle, unknownPort, invalidPortDirection or unknownWire.
     */
    ProjectEditResult disconnect(string srcHandle, string dstHandle,
            string srcPort = "", string dstPort = "") @safe nothrow {
        immutable size_t si = indexOfHandle(srcHandle);
        if (si == entries_.length) {
            return ProjectEditResult(false, unknownHandleProblem(srcHandle));
        }
        immutable size_t di = indexOfHandle(dstHandle);
        if (di == entries_.length) {
            return ProjectEditResult(false, unknownHandleProblem(dstHandle));
        }

        ushort srcPortIdx = 0;
        ProjectProblem portProb;
        if (!resolvePort(entries_[si], srcPort, PortDirection.output, srcPortIdx, portProb)) {
            return ProjectEditResult(false, portProb);
        }
        ushort dstPortIdx = 0;
        if (!resolvePort(entries_[di], dstPort, PortDirection.input, dstPortIdx, portProb)) {
            return ProjectEditResult(false, portProb);
        }

        immutable uint sId = entries_[si].id;
        immutable uint dId = entries_[di].id;
        size_t matchIdx = wires_.length;
        foreach (i; 0 .. wires_.length) {
            if (wires_[i].srcId == sId && wires_[i].srcPort == srcPortIdx
                    && wires_[i].dstId == dId && wires_[i].dstPort == dstPortIdx) {
                matchIdx = i;
                break;
            }
        }
        if (matchIdx == wires_.length) {
            immutable auto sDesc = entries_[si].writer.descriptor().ports[srcPortIdx];
            immutable auto dDesc = entries_[di].writer.descriptor().ports[dstPortIdx];
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.unknownWire,
                entries_[si].handle ~ " -> " ~ entries_[di].handle,
                "there is no wire from '" ~ entries_[si].handle ~ "' (" ~ sDesc.name ~ ") to '"
                ~ entries_[di].handle ~ "' (" ~ dDesc.name ~ ")", ""));
        }

        WireEntry[] kept;
        kept.reserve(wires_.length - 1);
        foreach (i; 0 .. wires_.length) {
            if (i != matchIdx) {
                kept ~= wires_[i];
            }
        }
        wires_ = kept;
        return ProjectEditResult(true);
    }

    /**
     * Sets the project title. A refused value changes nothing.
     *
     * Params:
     *   text = The title, at most MAX_STRING_LEN bytes.
     *
     * Returns:
     *   ok, or invalidTitle.
     */
    ProjectEditResult setTitle(string text) @safe nothrow {
        if (text.length > MAX_STRING_LEN) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidTitle, "title",
                "a project title is at most " ~ wholeText(MAX_STRING_LEN) ~ " bytes long", ""));
        }
        title_ = text;
        return ProjectEditResult(true);
    }

    /**
     * Sets the tempo. A refused value changes nothing.
     *
     * Params:
     *   bpm = Beats per minute, finite, MIN_PROJECT_BPM to MAX_PROJECT_BPM.
     *
     * Returns:
     *   ok, or invalidTempo with the nearest allowed number (the default tempo for a non-finite one).
     */
    ProjectEditResult setTempo(double bpm) @safe nothrow {
        if (!isValidTempo(bpm, ticksPerLine_)) {
            immutable string nearest = !isFinite(bpm) ? wholeText(cast(ulong) LoadedProject.init.bpm)
                : (bpm < MIN_PROJECT_BPM ? wholeText(cast(ulong) MIN_PROJECT_BPM)
                : wholeText(cast(ulong) MAX_PROJECT_BPM));
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidTempo, "tempo",
                "the tempo is " ~ wholeText(cast(ulong) MIN_PROJECT_BPM) ~ " to "
                ~ wholeText(cast(ulong) MAX_PROJECT_BPM) ~ " beats per minute", nearest));
        }
        bpm_ = bpm;
        return ProjectEditResult(true);
    }

    /**
     * Sets the ticks (lines) per line of the clock. A refused value changes nothing.
     *
     * Params:
     *   ticks = Ticks per line, 1 to MAX_PROJECT_TPL.
     *
     * Returns:
     *   ok, or invalidTicksPerLine with the nearest allowed number.
     */
    ProjectEditResult setTicksPerLine(uint ticks) @safe nothrow {
        if (!isValidTempo(bpm_, ticks)) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidTicksPerLine,
                "ticks per line", "ticks per line is 1 to " ~ wholeText(MAX_PROJECT_TPL),
                ticks < 1 ? "1" : wholeText(MAX_PROJECT_TPL)));
        }
        ticksPerLine_ = ticks;
        return ProjectEditResult(true);
    }

    /**
     * Sets the time signature. A refused value changes nothing.
     *
     * Params:
     *   sig = The signature: a numerator from 1 to MAX_TIME_SIG_NUMERATOR and a denominator of 2, 4, 8 or 16.
     *
     * Returns:
     *   ok, or invalidTimeSignature with the default signature as the nearest value.
     */
    ProjectEditResult setTimeSignature(TimeSignature sig) @safe nothrow {
        if (!sig.isValid()) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidTimeSignature,
                "signature",
                "a time signature has a numerator from 1 to 16 and a denominator of 2, 4, 8 or 16",
                formatTimeSignature(defaultTimeSignature())));
        }
        signature_ = sig;
        return ProjectEditResult(true);
    }

    /**
     * Sets the song key. A refused value changes nothing.
     *
     * Params:
     *   key = The key: a tonic from 0 (C) to 11 (B) and major or minor.
     *
     * Returns:
     *   ok, or invalidKey with "C major" as the nearest value.
     */
    ProjectEditResult setKey(MusicalKey key) @safe nothrow {
        if (!isValidKey(key.tonic, key.mode)) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidKey, "key",
                "a key has a tonic from 0 (C) to 11 (B) and is major or minor", "C major"));
        }
        key_ = key;
        return ProjectEditResult(true);
    }

    /**
     * Builds the finished document: the properties, every module with its layout position, and the starter
     * pattern and clip a new app project writes.
     *
     * Returns:
     *   The document when the app's own save checks accept it, or invalidProject with their reason.
     */
    ProjectDocumentResult document() const @safe nothrow {
        ProjectDocumentResult result;
        if (hasPreservedBase_) {
            result.project = copyPreservedBase(preservedBase_);
        }
        result.project.title = title_;
        result.project.bpm = bpm_;
        result.project.ticksPerLine = ticksPerLine_;
        result.project.timeSigNumerator = cast(ubyte) signature_.numerator;
        result.project.timeSigDenominator = cast(ubyte) signature_.denominator;
        result.project.keyTonic = key_.tonic;
        result.project.keyMode = cast(ubyte) key_.mode;
        result.project.modules = null;
        result.project.wires = null;
        uint slot = 0;
        foreach (i; 0 .. entries_.length) {
            SavedModule m = entries_[i].writer.savedModule(entries_[i].id);
            if (entries_[i].placed) {
                m.posX = entries_[i].posX;
                m.posY = entries_[i].posY;
            } else if (entries_[i].id == OUTPUT_MODULE_ID) {
                m.posX = LAYOUT_ORIGIN_X + outputColumn() * LAYOUT_COLUMN_STEP;
                m.posY = LAYOUT_ORIGIN_Y;
            } else {
                m.posX = LAYOUT_ORIGIN_X + (slot / LAYOUT_ROWS) * LAYOUT_COLUMN_STEP;
                m.posY = LAYOUT_ORIGIN_Y + (slot % LAYOUT_ROWS) * LAYOUT_ROW_STEP;
                slot++;
            }
            result.project.modules ~= m;
        }
        foreach (ref w; wires_) {
            result.project.wires ~= SavedWire(w.srcId, w.srcPort, w.dstId, w.dstPort, w.gain);
        }
        if (!hasPreservedBase_) {
            SavedPattern starter;
            starter.patternId = 1;
            starter.tracks = STARTER_PATTERN_TRACKS;
            starter.lines = STARTER_PATTERN_LINES;
            starter.name = STARTER_PATTERN_NAME;
            starter.cells = new NoteCell[STARTER_PATTERN_TRACKS * STARTER_PATTERN_LINES];
            result.project.patterns = [starter];
            result.project.clips = [TimelineClip(1, 1, 0, 0, STARTER_PATTERN_LINES, 0, 0, false, false, false)];
        }
        string err;
        if (!validateProjectForSave(result.project, err)) {
            result.problem = ProjectProblem(ProjectProblemKind.invalidProject, title_,
                "the project cannot be saved: " ~ err, "");
            return result;
        }
        result.ok = true;
        return result;
    }

    /**
     * Runs a trial activation of a project in a temporary StudioSession (serialize, parse, compile graph,
     * instantiate modules, and activate) without touching disk.
     *
     * Params:
     *   project = The document to trial-activate.
     *
     * Returns:
     *   ok, or invalidProject with the session's diagnostic reason.
     */
    ProjectEditResult trialActivate(const ref LoadedProject project) const @safe nothrow {
        string err;
        if (!activateProjectInSession(project, err)) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidProject, project.title,
                "the project failed trial activation: " ~ err, ""));
        }
        return ProjectEditResult(true);
    }

    /**
     * Serializes a document through the app's own serializer and verifies it via trial activation.
     *
     * Params:
     *   project = The document to serialize.
     *
     * Returns:
     *   The .msv bytes, or invalidProject with the validator's or session's reason.
     */
    ProjectBytesResult documentBytes(const ref LoadedProject project) const @safe nothrow {
        ProjectBytesResult result;
        string err;
        if (!serializeProject(project, result.bytes, err)) {
            result.problem = ProjectProblem(ProjectProblemKind.invalidProject, project.title,
                "the project cannot be saved: " ~ err, "");
            return result;
        }
        immutable ProjectEditResult act = trialActivate(project);
        if (!act.ok) {
            result.bytes = null;
            result.problem = act.problem;
            return result;
        }
        result.ok = true;
        return result;
    }

    /**
     * Writes a document as an .msv file: first the app's save checks, then trial activation in
     * StudioSession, then the app's own file writer.
     *
     * Params:
     *   project = The document to write.
     *   path = Destination path.
     *
     * Returns:
     *   ok, or invalidProject, or writeFailed with the writer's reason and the path as subject.
     */
    ProjectEditResult writeDocument(const ref LoadedProject project, string path) const @safe nothrow {
        string err;
        if (!validateProjectForSave(project, err)) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidProject, project.title,
                "the project cannot be saved: " ~ err, ""));
        }
        immutable ProjectEditResult act = trialActivate(project);
        if (!act.ok) {
            return act;
        }
        if (!saveProjectFile(project, path, err)) {
            return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.writeFailed, path,
                "could not write the project: " ~ err, ""));
        }
        return ProjectEditResult(true);
    }

    /**
     * Serializes this writer's project into .msv bytes.
     *
     * Returns:
     *   The bytes, or the document's problem when it cannot be saved.
     */
    ProjectBytesResult msvBytes() const @safe nothrow {
        ProjectDocumentResult doc = document();
        if (!doc.ok) {
            ProjectBytesResult result;
            result.problem = doc.problem;
            return result;
        }
        return documentBytes(doc.project);
    }

    /**
     * Writes this writer's project as an .msv file.
     *
     * Params:
     *   path = Destination path.
     *
     * Returns:
     *   ok, or the document's problem, or writeFailed with the path as subject.
     */
    ProjectEditResult writeFile(string path) const @safe nothrow {
        ProjectDocumentResult doc = document();
        if (!doc.ok) {
            return ProjectEditResult(false, doc.problem);
        }
        return writeDocument(doc.project, path);
    }

    /**
     * The index of a handle, matched without regard to case or spaces.
     *
     * Params:
     *   handle = The handle to look for.
     *
     * Returns:
     *   The index, or entries_.length when there is no such module.
     */
    private size_t indexOfHandle(string handle) const @safe nothrow {
        foreach (i; 0 .. entries_.length) {
            if (namesMatch(entries_[i].handle, handle)) {
                return i;
            }
        }
        return entries_.length;
    }

    /**
     * The problem for a handle the project does not hold, with the nearest handle when there is one.
     *
     * Params:
     *   handle = The handle that was given.
     *
     * Returns:
     *   The problem.
     */
    private ProjectProblem unknownHandleProblem(string handle) const @safe nothrow {
        return ProjectProblem(ProjectProblemKind.unknownHandle, handle,
            "there is no module '" ~ handle ~ "'", nearestName(handle, handles()));
    }

    /**
     * The problem for a handle another module already holds, with a free numbered handle.
     *
     * Params:
     *   handle = The handle that was given.
     *
     * Returns:
     *   The problem.
     */
    private ProjectProblem duplicateProblem(string handle) const @safe nothrow {
        return ProjectProblem(ProjectProblemKind.duplicateHandle, handle,
            "there is already a module '" ~ handle ~ "'", freeHandle(handle));
    }

    /**
     * A handle of the given stem with a number that no module holds, such as "bass2".
     *
     * Params:
     *   handle = The stem to number.
     *
     * Returns:
     *   The first free handle, or "" when none fits.
     */
    private string freeHandle(string handle) const @safe nothrow {
        foreach (n; 2 .. MAX_MODULES + 2) {
            immutable string digits = wholeText(n);
            immutable string stem = handle.length + digits.length > MAX_HANDLE_LENGTH
                ? handle[0 .. MAX_HANDLE_LENGTH - digits.length] : handle;
            if (indexOfHandle(stem ~ digits) == entries_.length) {
                return stem ~ digits;
            }
        }
        return "";
    }

    /**
     * Checks a module and appends it, naming the stored copy after its handle.
     *
     * Params:
     *   handle = The handle the module is known under.
     *   writer = The writer holding the module; copied.
     *   placed = Whether an explicit position was given.
     *   x = The x the module sits at when placed.
     *   y = The y the module sits at when placed.
     *
     * Returns:
     *   The new module id, or invalidHandle, duplicateHandle, notLoaded, protectedModule or tooManyModules.
     */
    private ProjectIdResult insertModule(string handle, ref const ModuleWriter writer, bool placed, float x,
            float y) @safe nothrow {
        ProjectProblem problem;
        if (!checkHandle(handle, problem)) {
            return ProjectIdResult(0, false, problem);
        }
        if (indexOfHandle(handle) != entries_.length) {
            return ProjectIdResult(0, false, duplicateProblem(handle));
        }
        if (!writer.loaded()) {
            return ProjectIdResult(0, false, ProjectProblem(ProjectProblemKind.notLoaded, handle,
                "the module writer for '" ~ handle ~ "' holds no module", ""));
        }
        if (writer.descriptor().isOutput) {
            return ProjectIdResult(0, false, ProjectProblem(ProjectProblemKind.protectedModule, handle,
                "a project has one Master Output, the module '" ~ OUTPUT_HANDLE ~ "'", OUTPUT_HANDLE));
        }
        if (entries_.length >= MAX_MODULES) {
            return ProjectIdResult(0, false, ProjectProblem(ProjectProblemKind.tooManyModules, handle,
                "a project holds at most " ~ wholeText(MAX_MODULES) ~ " modules", ""));
        }
        immutable uint id = nextModuleId_;
        nextModuleId_++;
        ModuleWriter stored = ModuleWriter(writer);
        stored.setName(handle);
        entries_ ~= ModuleEntry(handle, id, stored, placed, x, y);
        return ProjectIdResult(id, true);
    }

    /**
     * Returns a copy of a module's writer and its id.
     *
     * Params:
     *   handle = The handle of the module.
     *
     * Returns:
     *   The writer copy and id, or unknownHandle with the nearest handle.
     */
    ProjectModuleResult moduleOf(string handle) const @safe nothrow {
        immutable size_t index = indexOfHandle(handle);
        if (index == entries_.length) {
            return ProjectModuleResult(ModuleWriter.init, 0, false, unknownHandleProblem(handle));
        }
        return ProjectModuleResult(ModuleWriter(entries_[index].writer), entries_[index].id, true);
    }

    /**
     * The layout column the Master Output sits in: one further right than the columns the automatic modules
     * fill, and at least the first column.
     *
     * Returns:
     *   The column number, 1 or more.
     */
    private uint outputColumn() const @safe nothrow {
        uint automatic = 0;
        foreach (i; 0 .. entries_.length) {
            if (!entries_[i].placed && entries_[i].id != OUTPUT_MODULE_ID) {
                automatic++;
            }
        }
        immutable uint columns = (automatic + LAYOUT_ROWS - 1) / LAYOUT_ROWS;
        return columns < 1 ? 1 : columns;
    }

    /**
     * The index of a module by id.
     *
     * Params:
     *   id = Module id.
     *
     * Returns:
     *   Index into entries_, or entries_.length when not found.
     */
    private size_t indexOfId(uint id) const @safe nothrow {
        foreach (i; 0 .. entries_.length) {
            if (entries_[i].id == id) {
                return i;
            }
        }
        return entries_.length;
    }

    /**
     * Reports whether a loaded project base was preserved when opening an existing file.
     *
     * Returns:
     *   True when constructed via fromLoadedProject/fromBytes/fromFile.
     */
    package bool hasPreservedBase() const @safe nothrow {
        return hasPreservedBase_;
    }

    /**
     * Returns an independent copy of the preserved LoadedProject base for PartWriter reconstruction.
     *
     * Returns:
     *   Copied LoadedProject.
     */
    package LoadedProject preservedBaseDocument() const @safe nothrow {
        return copyPreservedBase(preservedBase_);
    }

    /**
     * Reports whether a module with the given numeric id currently exists in the project.
     *
     * Params:
     *   id = Numeric module id.
     *
     * Returns:
     *   True when found.
     */
    package bool hasModuleId(uint id) const @safe nothrow {
        return indexOfId(id) != entries_.length;
    }

    /**
     * Returns the handle string assigned to module id, or empty string if absent.
     *
     * Params:
     *   id = Numeric module id.
     *
     * Returns:
     *   Handle name or "".
     */
    package string handleForId(uint id) const @safe nothrow {
        immutable size_t idx = indexOfId(id);
        return idx < entries_.length ? entries_[idx].handle : "";
    }

    /**
     * Resolves a port name (or empty string for the first audio port) on a module for the expected direction.
     *
     * Params:
     *   entry = Module entry.
     *   portName = Requested port id or display name, or "" for default audio port.
     *   expectedDir = PortDirection.output for wire sources, PortDirection.input for destinations.
     *   portIndex = Receives resolved port index when true is returned.
     *   problem = Receives unknownPort or invalidPortDirection when false is returned.
     *
     * Returns:
     *   True when a matching port in expectedDir was resolved.
     */
    private bool resolvePort(const ref ModuleEntry entry, string portName, PortDirection expectedDir,
            out ushort portIndex, out ProjectProblem problem) const @safe nothrow {
        auto ports = entry.writer.descriptor().ports;
        immutable string clean = trim(portName);
        immutable string dirWord = expectedDir == PortDirection.output ? "output" : "input";

        if (clean.length == 0) {
            string fallback;
            foreach (i, ref p; ports) {
                if (p.dir == expectedDir) {
                    if (isAudioPort(p.kind)) {
                        portIndex = cast(ushort) i;
                        return true;
                    }
                    if (fallback.length == 0) {
                        fallback = p.name;
                    }
                }
            }
            problem = ProjectProblem(ProjectProblemKind.unknownPort, entry.handle,
                "module '" ~ entry.handle ~ "' has no audio " ~ dirWord ~ " port", fallback);
            return false;
        }

        foreach (i, ref p; ports) {
            if (p.dir == expectedDir && (namesMatch(p.id, clean) || namesMatch(p.name, clean))) {
                portIndex = cast(ushort) i;
                return true;
            }
        }

        string[] validNames;
        foreach (ref p; ports) {
            if (p.dir == expectedDir) {
                validNames ~= p.name;
                if (!namesMatch(p.id, p.name)) {
                    validNames ~= p.id;
                }
            }
        }

        foreach (ref p; ports) {
            if (p.dir != expectedDir && (namesMatch(p.id, clean) || namesMatch(p.name, clean))) {
                immutable string oppositeWord = expectedDir == PortDirection.output ? "input" : "output";
                immutable string roleWord = expectedDir == PortDirection.output ? "source" : "destination";
                immutable string suggestion = nearestPortDisplayName(clean, ports, expectedDir, validNames);
                problem = ProjectProblem(ProjectProblemKind.invalidPortDirection, clean,
                    "port '" ~ p.name ~ "' on '" ~ entry.handle ~ "' is an " ~ oppositeWord
                    ~ " port and cannot be used as a wire " ~ roleWord, suggestion);
                return false;
            }
        }

        immutable string suggestion = nearestPortDisplayName(clean, ports, expectedDir, validNames);
        problem = ProjectProblem(ProjectProblemKind.unknownPort, clean,
            "module '" ~ entry.handle ~ "' has no " ~ dirWord ~ " port '" ~ clean ~ "'", suggestion);
        return false;
    }

    /**
     * Finds the display name of the nearest port in expectedDir to query.
     *
     * Params:
     *   query = Requested port name.
     *   ports = Module port descriptors.
     *   expectedDir = Direction to filter by.
     *   candidates = Pre-collected candidate ids and names in expectedDir.
     *
     * Returns:
     *   Display name of the nearest port, or "" when none exists.
     */
    private static string nearestPortDisplayName(string query, immutable(PortDescriptor)[] ports,
            PortDirection expectedDir, const(string)[] candidates) @safe pure nothrow {
        immutable string hit = nearestName(query, candidates);
        if (hit.length > 0) {
            foreach (ref p; ports) {
                if (p.dir == expectedDir && (namesMatch(p.name, hit) || namesMatch(p.id, hit))) {
                    return p.name;
                }
            }
            return hit;
        }
        foreach (ref p; ports) {
            if (p.dir == expectedDir) {
                return p.name;
            }
        }
        return "";
    }

    /**
     * Runs GraphCompiler.compile() on the current modules and wires plus one candidate wire to enforce
     * exact cycle and graph-topology validation. Localized @trusted adapter because GraphCompiler takes
     * raw NodeSpec.state pointers (which compile() checks for non-null and never dereferences) and returns
     * a manually freed GraphPlan*.
     *
     * Params:
     *   candidate = Additional wire to test.
     *   compileErr = Receives GraphCompileError when compilation fails.
     *
     * Returns:
     *   True when GraphCompiler accepts the graph.
     */
    private bool checkGraphWithCandidate(const ref WireEntry candidate, out GraphCompileError compileErr)
            const @trusted nothrow {
        ubyte sentinel = 1;
        void* sentinelPtr = cast(void*) &sentinel;
        NodeSpec[] nodes = new NodeSpec[entries_.length];
        foreach (i; 0 .. entries_.length) {
            nodes[i] = NodeSpec(ModuleId(entries_[i].id), entries_[i].writer.descriptor(), sentinelPtr,
                false, false);
        }
        WireSpec[] specs = new WireSpec[wires_.length + 1];
        foreach (i; 0 .. wires_.length) {
            specs[i] = WireSpec(ModuleId(wires_[i].srcId), wires_[i].srcPort,
                ModuleId(wires_[i].dstId), wires_[i].dstPort, wires_[i].gain);
        }
        specs[wires_.length] = WireSpec(ModuleId(candidate.srcId), candidate.srcPort,
            ModuleId(candidate.dstId), candidate.dstPort, candidate.gain);

        GraphPlan* plan = null;
        bool ok = false;
        try {
            ok = GraphCompiler.compile(nodes, specs, plan, compileErr);
        } catch (Exception) {
            compileErr = GraphCompileError.outOfMemory;
            ok = false;
        }
        if (plan !is null) {
            GraphPlan.destroyOffRT(plan);
        }
        return ok;
    }

    /**
     * Performs a trial activation in a short-lived StudioSession. Localized @trusted adapter because
     * StudioSession manages an unmanaged RT Engine and carries no @safe/nothrow attributes.
     *
     * Params:
     *   project = Project document to activate.
     *   err = Receives diagnostic text on failure.
     *
     * Returns:
     *   True when StudioSession initialized and activated the project cleanly.
     */
    private bool activateProjectInSession(const ref LoadedProject project, out string err) const @trusted nothrow {
        try {
            StudioSession session = new StudioSession();
            if (!session.initialize(44_100.0f)) {
                err = "Failed to initialize StudioSession for trial activation";
                return false;
            }
            scope (exit) {
                session.shutdown();
            }
            return session.openProjectFromMemory(project, err);
        } catch (Exception ex) {
            err = ex.msg.length > 0 ? ex.msg : "Trial activation failed";
            return false;
        }
    }

    /**
     * Writes a validated project with io.project_format saveProject. That function carries no @safe or
     * nothrow marks although it only hands validated bytes to the file system and catches its own file
     * exceptions, so this adapter is @trusted and turns any exception into a reason.
     *
     * Params:
     *   project = The document to write.
     *   path = Destination path.
     *   err = Receives the failure reason.
     *
     * Returns:
     *   True when the file was written.
     */
    private bool saveProjectFile(const ref LoadedProject project, string path, out string err) const @trusted nothrow {
        try {
            return saveProject(project, path, err);
        } catch (Exception ex) {
            err = ex.msg.length > 0 ? ex.msg : "Failed writing .msv project file";
            return false;
        }
    }

    /**
     * Loads a .msv project file using io.project_format.loadProjectFile via a localized @trusted
     * adapter because loadProjectFile carries no @safe/nothrow attributes.
     *
     * Params:
     *   path = Source .msv file path.
     *   proj = Receives parsed LoadedProject.
     *   err = Receives diagnostic text on failure.
     *
     * Returns:
     *   True when loaded cleanly.
     */
    private static bool loadProjectFileSafe(string path, out LoadedProject proj, out string err) @trusted nothrow {
        try {
            return loadProjectFile(path, proj, err);
        } catch (Exception ex) {
            err = ex.msg.length > 0 ? ex.msg : "Failed reading .msv project file";
            return false;
        }
    }

    /**
     * Deep-copies preserved LoadedProject metadata (patterns, cells, drum lanes, clips, loop range,
     * author, formatVersion, and MIDI mappings) so repeated document() calls stay independent.
     *
     * Params:
     *   src = Source LoadedProject.
     *
     * Returns:
     *   Independent copy with cloned slices.
     */
    private static LoadedProject copyPreservedBase(const ref LoadedProject src) @safe pure nothrow {
        LoadedProject dst;
        dst.formatVersion = src.formatVersion;
        dst.title = src.title;
        dst.author = src.author;
        dst.bpm = src.bpm;
        dst.ticksPerLine = src.ticksPerLine;
        dst.loopStartLine = src.loopStartLine;
        dst.loopEndLine = src.loopEndLine;
        dst.timeSigNumerator = src.timeSigNumerator;
        dst.timeSigDenominator = src.timeSigDenominator;
        dst.keyTonic = src.keyTonic;
        dst.keyMode = src.keyMode;
        dst.patterns.reserve(src.patterns.length);
        foreach (ref p; src.patterns) {
            SavedPattern cp;
            cp.patternId = p.patternId;
            cp.tracks = p.tracks;
            cp.lines = p.lines;
            cp.name = p.name;
            cp.kind = p.kind;
            cp.cells = p.cells.dup;
            cp.lanes = p.lanes.dup;
            dst.patterns ~= cp;
        }
        dst.clips = src.clips.dup;
        dst.midiMappings = src.midiMappings.dup;
        return dst;
    }
}

/**
 * Parses a key the way the script language writes it: a note letter A to G, an optional '#' or 'b', and an
 * optional "major" or "minor" (nothing means major). Matched without regard to case or spaces.
 *
 * Params:
 *   text = The key as written, such as "A minor", "F#" or "Cb".
 *
 * Returns:
 *   The key, or invalidKey with the nearest key: "C major" when the first letter is not a note name, or
 *   the tonic with the nearest mode when the mode is not one.
 */
ProjectKeyResult parseKey(string text) @safe pure nothrow {
    static immutable ubyte[7] LETTER_PITCH = [9, 11, 0, 2, 4, 5, 7];
    static immutable string[2] MODES = ["minor", "major"];
    immutable string bare = trim(text);
    immutable char letter = bare.length > 0 ? upperAscii(bare[0]) : ' ';
    if (letter < 'A' || letter > 'G') {
        return ProjectKeyResult(MusicalKey.init, false, ProjectProblem(ProjectProblemKind.invalidKey, text,
            "a key starts with a note name from A to G", "C major"));
    }
    int pitch = LETTER_PITCH[letter - 'A'];
    size_t cursor = 1;
    if (cursor < bare.length && (bare[cursor] == '#' || bare[cursor] == 'b')) {
        pitch += bare[cursor] == '#' ? 1 : -1;
        cursor++;
    }
    immutable string tonicText = [letter].idup ~ bare[1 .. cursor];
    immutable string modeText = trim(bare[cursor .. $]);
    MusicalKey key = MusicalKey(cast(ubyte) ((pitch + 12) % 12), KeyMode.major);
    if (modeText.length == 0 || namesMatch(modeText, "major")) {
        return ProjectKeyResult(key, true);
    }
    if (namesMatch(modeText, "minor")) {
        key.mode = KeyMode.minor;
        return ProjectKeyResult(key, true);
    }
    immutable string nearest = nearestName(modeText, MODES[]);
    return ProjectKeyResult(MusicalKey.init, false, ProjectProblem(ProjectProblemKind.invalidKey, text,
        "a key is a note name followed by 'major' or 'minor'",
        tonicText ~ " " ~ (nearest.length > 0 ? nearest : "major")));
}
