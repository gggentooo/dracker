# Dracker Task Guides

> **Generated file. Do not edit it.** `tools/todo.py` writes this file from `docs/todo.json` (`agents.md` Rule 6). Change a guide with `python3 tools/todo.py guide T00 --author "<name>" --text @file`.

A guide says what to write for one task and how: what to read first, the existing code to call (with exact signatures), the new code, the order of the steps, an acceptance table with worked values, and the tests. It was written by reading the code as it was on the date shown; if the code no longer matches the guide, stop and tell the owner instead of guessing. To get one task with everything it rests on, run `python3 tools/todo.py brief T00`.

Only open tasks are listed, in stage order. A task without a guide is named at the end.

---

## T75 · [Compose] Module writer: Sampler samples

Stage 0 · Build · guide written 2026-11-26 by Gemini 4 Neon

**Goal.** `ModuleWriter` can load an audio file (or its bytes) into one of the 16 Sampler slots with a root note and a key range. The extra data is then byte for byte what the app stores after `StudioSession.doLoadSample`. Left out: loop points, envelopes, clearing a slot, reading a sample back as text, commands in `compose_main.d`.

**Read first.**
1. `source/app/session.d`: `doLoadSample` (3097-3145), `doSetModuleExtra` (3066-3080), `saveModulePresetToBytes` (1956-1970). The app's sequence and size limit (line 3070).
2. `source/modules/synths/sampler.d`: `SamplerSlotAsset` (49-71), `createFromPlanar` (101-145), `createSamplerAssetFromMemory` (198-210), `serializeExtra` (537-598), `deserializeExtra` (639-735), `swapAsset` (915-929). The byte layout.
3. `source/io/audio_io.d`: `decodeAudioMemory` (258-268), `deinterleaveToPlanar` (493-531). Mono is copied to both channels.
4. `source/compose/module_writer.d`: `ModuleProblemKind` (78-93), `ModuleEditResult` (151-154), `ModuleWriter` (170-186), `isNameProblem` (798-817), `readPresetFile` (1605-1612). How problems are returned; how an unsafe call is wrapped.
5. `tests/unit/compose_module_test.d`: `writerOf` (115), session test (557-605).

**Existing code to use.**
```d
SamplerSlotAsset* createSamplerAssetFromMemory(const(ubyte)[] bytes, out string err, ubyte rootNote = 60)
```
`sampler.d:198`. Null on failure, `err` set. Not `@safe`, not `nothrow`. Sets range 0..127, loop 0..frames.
```d
bool deserializeExtra(const(ubyte)[] payload, float sampleRate)
bool swapAsset(uint slot, void* newAsset, out void* oldAsset)
bool serializeExtra(out ubyte[] payload) const
static void destroyErased(void* raw)
```
`sampler.d:639`, `915`, `537`, `153`. `deserializeExtra` is false on bad data and ignores `sampleRate`. `swapAsset` is false when `slot >= 16`; the caller frees `oldAsset` with `SamplerSlotAsset.destroyErased`.
```d
enum size_t MAX_SLOTS = 16;
enum size_t MAX_EXTRA_BLOB_BYTES = 64u * 1024u * 1024u;
```
`sampler.d:494` (in `Sampler`); `io/project_format.d:66` (67,108,864).
```d
bool saveModulePresetToBytes(uint modId, string presetName, out ubyte[] bytes, out string err)
bool doLoadSample(uint samplerId, uint slot, const(ubyte)[] audioBytes, ubyte rootNote, ubyte lowNote,
        ubyte highNote, out string err)
```
`session.d:1956`, `3097`. False with `err` set. Tests only.

Nothing needed is private in `session.d`: lines 3110-3139 call only public `sampler.d` code.

**Write.**
In `sampler.d`, after the closing brace of `struct Sampler` (line 946):
```d
bool samplerExtraWithSample(const(ubyte)[] currentExtra, uint slot, const(ubyte)[] audioBytes,
        ubyte rootNote, ubyte lowNote, ubyte highNote, out ubyte[] blob, out string err)
```
It repeats `doLoadSample` without a session:
1. Refuse `slot >= Sampler.MAX_SLOTS || lowNote > highNote || highNote > 127 || rootNote > 127` with `err = "Target is not a Sampler slot"`.
2. `createSamplerAssetFromMemory(audioBytes, err, rootNote)`; on null return false.
3. Set `asset.lowNote` and `asset.highNote`. Set every sample of `asset.left` and `asset.right` that fails `isFinite` to `0.0f` (`createSamplerAssetFromMemory` does not sanitize samples; `createFromPlanar` does at lines 121-123, so doing it here guarantees neither the app nor `ModuleWriter` stores NaN samples).
4. `Sampler temp;`. If `currentExtra.length > 0` and `temp.deserializeExtra(currentExtra, 44_100.0f)` is false: free the asset, `err = "Existing sampler data could not be decoded"`, return false.
5. `temp.swapAsset(slot, asset, old)`; free `old` when not null; if `!temp.serializeExtra(blob)`, set `err = "Sampler data could not be serialized"` and return false; else return true.

In `module_writer.d`, at the end of `ModuleProblemKind`:
```d
    notASampler = 14,
    unreadableSample = 15,
    sampleTooLarge = 16
```
New public members of `ModuleWriter`:
```d
ModuleEditResult loadSampleBytes(int slot, const(ubyte)[] audioBytes, int rootNote = 60, int lowNote = 0,
        int highNote = 127) @safe nothrow
ModuleEditResult loadSampleFile(int slot, string path, int rootNote = 60, int lowNote = 0,
        int highNote = 127) @safe nothrow
```
Defaults are the app's (`gui/views/sample_editor.d:344`). Checks, in order: `desc_ is null` gives `notLoadedProblem()`; `mod_.typeId != "synth.sampler"` gives `notASampler`; slot outside 0..15, then root, low, high outside 0..127 give `outOfRange` with the nearest valid integer as text in `suggestion`; `lowNote > highNote` gives `outOfRange` with `highNote` as text in `suggestion`. A decoder or file failure gives `unreadableSample` with the reason `"could not load the sample: " ~ err`. A blob that fails `sampleDataFits` gives `sampleTooLarge`. Only then `mod_.extraBlob = blob`. `loadSampleFile` reads the file and calls `loadSampleBytes`.

At the end of the file:
```d
bool sampleDataFits(size_t blobBytes) @safe pure nothrow @nogc
private bool buildSamplerExtra(const(ubyte)[] current, uint slot, const(ubyte)[] audio, ubyte root, ubyte low,
        ubyte high, out ubyte[] blob, out string err) @trusted nothrow
private bool readAudioFile(string path, out ubyte[] bytes, out string err) @trusted nothrow
```
`sampleDataFits` returns `blobBytes <= MAX_EXTRA_BLOB_BYTES`. Each adapter wraps one call (`samplerExtraWithSample`, `std.file.read`) in `try`/`catch (Exception ex)`, like `readPresetFile`.

**Steps.** After each step run Gate 2 for the changed file.
1. Add `samplerExtraWithSample` with DDoc.
2. Add the three kinds. Add three `case` lines to the `return false` group of `isNameProblem`.
3. Add imports: `modules.synths.sampler : Sampler, samplerExtraWithSample`; `MAX_EXTRA_BLOB_BYTES` in the `io.project_format` list; `std.file : read`. Add `sampleDataFits` and the two adapters.
4. Add `loadSampleBytes`.
5. Add `loadSampleFile`.
6. Write Tests blocks 1, 2 (two slots loaded 5 then 2; leave the `float.nan` check for Step 7), and 3-7. Run Gate 1 after every two blocks. All tests must pass against the untouched `StudioSession.doLoadSample`.
7. Apply owner decision #1 in `source/app/session.d`: replace lines 3110-3139 of `doLoadSample` with one call to `samplerExtraWithSample` (keeping the signature, `err`, and `doSetModuleExtra` undo step). Then add the `float.nan` WAV check to Test block 2 (before this step, `doLoadSample` did not sanitize NaN samples so the two blobs would differ; after this step both sanitize NaN to `0.0f` and match byte-for-byte). Run Gate 1; every existing sampler, session and sample editor test and the new NaN identity test must pass.
8. Update the file headers (`sampler.d`, `module_writer.d`), run `dub build --compiler=ldc2 --config=compose` (must link cleanly), and run Gates 1, 2, 3.

**Acceptance table.** The WAV is `sineWav(4410, 0.7f)`: mono, 44,100 Hz. Blob size = 8 (magic, count) + 60 per slot (index 4, rate 4, notes 4, loop 16, envelopes 24, frame count 8) + 8 per frame (`serializeExtra`, lines 554-594). Rows 1-6 and the decoder errors were run on 2026-11-26 with a scratch copy.

| Input | Working | Expected |
| --- | --- | --- |
| slot 2, root 69, range 60..80, new writer | 8 + 60 + 8·4410 | `extraBlob.length == 35348` |
| same, bytes 0..11 | magic `0x534D5031` little-endian, count 1, slot 2 | `49,80,77,83, 1,0,0,0, 2,0,0,0` |
| same, bytes 12..19 | 44100.0f = `0x472C4400`; root, low, high, pad | `0,68,44,71, 69,60,80,0` |
| same, bytes 20..35 and 60..67 | loop 0..4410; 4410 = `0x113A` | bytes 20..27 zero; 28,29 = `58,17`; 60,61 = `58,17` |
| then slot 5 with `sineWav(100, 0.5f)` | 8 + 35340 + (60 + 800) | length 36208; bytes 35348..35351 = `5,0,0,0` |
| then slot 2 again with 100 frames | 8 + 860 + 860 | length 1728 |
| slot 16; slot -1 | slots are 0..15 | `outOfRange`; suggestion `15`, then `0` |
| root 128 | notes are 0..127 | `outOfRange`, suggestion `127` |
| low 61, high 60 | low is above high | `outOfRange` |
| writer of `Analog Generator` | type is not `synth.sampler` | `notASampler` |
| bytes `[1, 2, 3]`; empty bytes | decoder: `Cannot decode stream: unrecognized encoding.`; `Encoded audio buffer cannot be empty` | `unreadableSample` |
| a missing path | `std.file.read` throws | `unreadableSample` |
| `ModuleWriter.init` | holds no module | `notLoaded` |
| `sampleDataFits(67108864)`, `(67108865)` | limit 64·1024·1024 | `true`, `false` |

**Tests.** File `tests/unit/compose_module_test.d`. Copy `sineWav` from `studio_backend_test.d:116`. Imitate the session test at line 557. Blocks:
1. Identity: session, `doAddModule("synth.sampler", "Drums")`, `doLoadSample(id, 2, wav, 69, 60, 80, err)`, `saveModulePresetToBytes`, `loadPreset`; writer `loadSampleBytes(2, wav, 69, 60, 80)`; assert `w.savedModule().extraBlob == app.mod.extraBlob`.
2. The same with slots loaded in the order 5 then 2; then (in Step 7, after `doLoadSample` calls `samplerExtraWithSample`) with a WAV holding one `float.nan` sample, verifying both blobs are equal and contain zero non-finite samples.
3. Round trip: `presetBytes()` into `session.loadModulePresetFromBytes`, save again, same extra data.
4. The byte and length rows of the table.
5. Every other row; after each refusal `savedModule().extraBlob` is unchanged.
6. `loadSampleFile` from the temporary folder equals `loadSampleBytes`.
7. Loading into a copy of a writer leaves the original empty.

**Pitfalls.**
- `isNameProblem` is a `final switch`: a kind without a `case` does not compile.
- `err` and `oldAsset` are `out`: reset when the call starts.
- Whole preset bytes differ from the app's (id, name). Compare `extraBlob`.
- Slots are stored in rising slot order.
- Accepted formats: WAV, FLAC, MP3, OGG. The app's dialog also offers AIFF (`sample_editor.d:371`), but the decoder refuses it.
- Never build a 64 MiB blob in a test.
- Cast `int` to `ubyte` only after the range checks.

**Do not.** Do not change `source/app/session.d` except `doLoadSample` in Step 7 (as decided by the owner). Do not change `compose_main.d`, `docs/manual.md`, the blob format or existing `ModuleWriter` behaviour. Do not add loop, envelope or clear functions.

**Done when.**
- Gate 1 prints `N modules passed unittests`; `dub build --compiler=ldc2 --config=compose` succeeds; Gates 2 and 3 are clean.
- The identity test passes for one slot, two slots and the NaN file.
- Every refusal row asserts the `kind` and the unchanged blob.

**Decided by the owner (2026-11-26).**
1. `StudioSession.doLoadSample` is changed in Step 7 to call the new `samplerExtraWithSample`, so the app and the module writer cannot drift and both sanitize non-finite samples. In `source/app/session.d`, replace lines 3110-3139 (decoding audio, setting key range, deserializing current extra data into a temporary Sampler, swapping the slot and serializing) with one call to `samplerExtraWithSample`, keeping the method's signature, what it returns in `err`, and the `doSetModuleExtra` undo call. If an existing test changes its result, undo Step 7 and tell the owner.
2. A loaded sample cannot be printed back as script text (the file path is not stored). That is accepted for this task.

---

## T76 · [Compose] Project writer: properties, modules, saving

Stage 0 · Build · guide written 2026-11-26 by Gemini 4 Neon

**Goal.** A new module `compose.project_writer` holds one project being built: title, tempo, ticks per line, time signature, key, and modules under handle names. It ends as a `LoadedProject`, as `.msv` bytes, or as a file, through the app's own checks. Wires (T96), parts (T77) and script text (T83) are left out.

**Read first.**
1. `source/io/project_format.d`: limits (52-73), `LoadedProject` (149), `isValidTempo` (187), `isValidKey` (216), `validateProjectForSave` (347), `serializeProject` (584), `saveProject` (732): defaults and limits.
2. `source/compose/module_writer.d`: `ModuleProblem` (98-119), copy constructor (182), `savedModule` (566), adapters (1556-1634): the style to copy.
3. `source/compose/names.d`: `nearestName` (82), `namesMatch` (97), `trim` (199). `source/compose/timing.d`: `TimeSignature` (84), `formatTimeSignature` (284).
4. `source/app/music_theory.d`: `MusicalKey` (45), `allKeys` (75), `keyName` (201). No key parser exists; this task writes one.
5. `source/app/session.d`: `resetToEmptyProjectSuspended` (755-802): a new project has Master Output id 1, one pattern, one clip. `freeModulePosition` (3682) steps 180 in x.
6. `source/app/skeleton_gen.d`: `generateSkeleton` (763) builds a document by hand.
7. `tests/unit/compose_module_test.d`: `writerOf` (115), file test (680), failed write (1050).

**Existing code to use.**

```d
bool isValidTempo(double bpm, uint tpl) @safe nothrow pure @nogc
bool isValidKey(uint tonic, uint mode) @safe nothrow pure @nogc
bool validateProjectForSave(scope const ref LoadedProject proj, out string err, uint depth = 0) @safe nothrow
bool serializeProject(const ref LoadedProject proj, out ubyte[] bytes, out string err) @safe nothrow
bool saveProject(const ref LoadedProject proj, string path, out string err)
bool loadProjectFile(string path, out LoadedProject proj, out string err)
```

All return `false` and fill `err` on failure; `err`, `bytes` are `out`. `saveProject` and `loadProjectFile` are neither `@safe` nor `nothrow`: call `saveProject` only through the `@trusted` adapter below, and `loadProjectFile` only in tests. `MIN_PROJECT_BPM` 20.0, `MAX_PROJECT_BPM` 999.0, `MAX_PROJECT_TPL` 255, `MAX_MODULES` 1024, `MAX_STRING_LEN` 65_536. `LoadedProject.init`: "Untitled", "Dracker", 125.0 bpm, 6 ticks, 4/4, C major.

```d
static ModuleWriterResult fromType(string typeText) @safe pure nothrow
bool loaded() const @safe pure nothrow @nogc
const(ModuleDescriptor)* descriptor() const @safe pure nothrow @nogc
SavedModule savedModule(uint id = 0) const @safe pure nothrow
bool namesMatch(string a, string b) @safe pure nothrow @nogc
string nearestName(string text, scope const(string)[] candidates) @safe pure nothrow
string trim(string text) @safe pure nothrow @nogc
string formatTimeSignature(TimeSignature sig) @safe pure nothrow
```

`fromType("core.output")` gives "Master Output" with values `[1, 1]`, as the app does. `descriptor()` is `null` when `loaded()` is false. `ModuleDescriptor.isOutput` (`source/graph/module_api.d:135`) is true only for the Master Output. `nearestName` returns `""` for "none near".

**Write.** `ProjectWriter` is a `final class`: T77 and T83 share one project, and a project is never copied. The code below was compiled and tested. It has no DDoc: add a block above every function, and the file header.

```d
import std.math : isFinite;

import app.music_theory : KeyMode, MusicalKey;
import compose.module_writer : ModuleEditResult, ModuleWriter, ModuleWriterResult;
import compose.names : namesMatch, nearestName, trim;
import compose.timing : TimeSignature, formatTimeSignature, defaultTimeSignature;
import io.project_format : LoadedProject, MAX_MODULES, MAX_PROJECT_BPM, MAX_PROJECT_TPL, MAX_STRING_LEN,
    MIN_PROJECT_BPM, SavedModule, SavedPattern, isValidKey, isValidTempo, saveProject, serializeProject,
    validateProjectForSave;
import sequencer.note : NoteCell;
import sequencer.timeline : TimelineClip;

enum string OUTPUT_HANDLE = "out";
enum string OUTPUT_TYPE_ID = "core.output";
enum uint OUTPUT_MODULE_ID = 1;
enum size_t MAX_HANDLE_LENGTH = 32;
enum float LAYOUT_ORIGIN_X = 60.0f;
enum float LAYOUT_ORIGIN_Y = 60.0f;
enum float LAYOUT_COLUMN_STEP = 180.0f;
enum float LAYOUT_ROW_STEP = 160.0f;
enum uint LAYOUT_ROWS = 4;
enum uint STARTER_PATTERN_TRACKS = 4;
enum uint STARTER_PATTERN_LINES = 64;
enum string STARTER_PATTERN_NAME = "Pattern 01";

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
    invalidName = 14
}

struct ProjectProblem {
    ProjectProblemKind kind = ProjectProblemKind.invalidProject;
    string subject = "";
    string reason = "";
    string suggestion = "";

    string text() const @safe pure nothrow {
        string result = reason;
        if (suggestion.length > 0) {
            result ~= isHandleProblem(kind) ? "; did you mean '" ~ suggestion ~ "'?"
                : "; the nearest valid value is " ~ suggestion;
        }
        return result;
    }
}

struct ProjectEditResult {
    bool ok = false;
    ProjectProblem problem = ProjectProblem.init;
}
```

Five more result structs. Each starts with these fields and ends with `ok` and `problem` as `ProjectEditResult` does:

```d
struct ProjectIdResult        { uint id = 0; }
struct ProjectModuleResult    { ModuleWriter writer = ModuleWriter.init; uint id = 0; }
struct ProjectDocumentResult  { LoadedProject project; }
struct ProjectBytesResult     { ubyte[] bytes; }
struct ProjectKeyResult       { MusicalKey key = MusicalKey.init; }
```

Both constructors of `ModuleEntry` are needed, or `~=` does not compile.

```d
private struct ModuleEntry {
    string handle;
    uint id = 0;
    ModuleWriter writer;
    bool placed = false;
    float posX = 0.0f;
    float posY = 0.0f;

    this(string handle, uint id, ref const ModuleWriter writer, bool placed, float posX, float posY)
            @safe pure nothrow {
        this.handle = handle;
        this.id = id;
        this.writer = ModuleWriter(writer);
        this.placed = placed;
        this.posX = posX;
        this.posY = posY;
    }

    this(ref return scope const ModuleEntry other) @safe pure nothrow {
        handle = other.handle;
        id = other.id;
        writer = ModuleWriter(other.writer);
        placed = other.placed;
        posX = other.posX;
        posY = other.posY;
    }
}

final class ProjectWriter {
    private string title_ = LoadedProject.init.title;
    private double bpm_ = LoadedProject.init.bpm;
    private uint ticksPerLine_ = LoadedProject.init.ticksPerLine;
    private TimeSignature signature_;
    private MusicalKey key_;
    private ModuleEntry[] entries_;
    private uint nextModuleId_ = OUTPUT_MODULE_ID + 1;

    this() @safe nothrow {
        ModuleWriterResult master = ModuleWriter.fromType(OUTPUT_TYPE_ID);
        entries_ ~= ModuleEntry(OUTPUT_HANDLE, OUTPUT_MODULE_ID, master.writer, false, 0.0f, 0.0f);
    }

    string title() const @safe nothrow
    double tempo() const @safe nothrow
    uint ticksPerLine() const @safe nothrow
    TimeSignature timeSignature() const @safe nothrow
    MusicalKey key() const @safe nothrow
    size_t moduleCount() const @safe nothrow
    string[] handles() const @safe nothrow
    bool hasModule(string handle) const @safe nothrow
    ProjectIdResult moduleId(string handle) const @safe nothrow
    ProjectIdResult addModule(string handle, ModuleWriter writer) @safe nothrow
    ProjectIdResult addModuleAt(string handle, ModuleWriter writer, float x, float y) @safe nothrow
    ProjectEditResult renameModule(string handle, string newHandle) @safe nothrow
    ProjectEditResult setModuleName(string handle, string name) @safe nothrow
    ProjectEditResult moveModule(string handle, float x, float y) @safe nothrow
    ProjectEditResult removeModule(string handle) @safe nothrow
    ProjectBytesResult msvBytes() const @safe nothrow
    ProjectEditResult writeFile(string path) const @safe nothrow
}

private string wholeText(ulong value) @safe pure nothrow
private char upperAscii(char c) @safe pure nothrow @nogc
private bool isAsciiLetter(char c) @safe pure nothrow @nogc
private bool isHandleChar(char c) @safe pure nothrow @nogc
```

Setters, inside the class. A refused value changes nothing.

```d
ProjectEditResult setTitle(string text) @safe nothrow {
    if (text.length > MAX_STRING_LEN) {
        return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidTitle, "title",
            "a project title is at most " ~ wholeText(MAX_STRING_LEN) ~ " bytes long", ""));
    }
    title_ = text;
    return ProjectEditResult(true);
}

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

ProjectEditResult setTicksPerLine(uint ticks) @safe nothrow {
    if (!isValidTempo(bpm_, ticks)) {
        return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidTicksPerLine, "ticks per line",
            "ticks per line is 1 to " ~ wholeText(MAX_PROJECT_TPL),
            ticks < 1 ? "1" : wholeText(MAX_PROJECT_TPL)));
    }
    ticksPerLine_ = ticks;
    return ProjectEditResult(true);
}

ProjectEditResult setTimeSignature(TimeSignature sig) @safe nothrow {
    if (!sig.isValid()) {
        return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidTimeSignature, "signature",
            "a time signature has a numerator from 1 to 16 and a denominator of 2, 4, 8 or 16",
            formatTimeSignature(defaultTimeSignature())));
    }
    signature_ = sig;
    return ProjectEditResult(true);
}

ProjectEditResult setKey(MusicalKey key) @safe nothrow {
    if (!isValidKey(key.tonic, key.mode)) {
        return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidKey, "key",
            "a key has a tonic from 0 (C) to 11 (B) and is major or minor", "C major"));
    }
    key_ = key;
    return ProjectEditResult(true);
}
```

Handles. A handle is one bare word for the script language (T67): no space, `#`, `\`, `"`, `=` or `:`. `isHandleChar` is true for ASCII letters, digits, `_` and `-`. `wholeText` writes a number in decimal.

```d
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

string suggestedHandle(string text) @safe pure nothrow {
    string kept;
    foreach (c; text) {
        if (isHandleChar(c) && (kept.length > 0 || isAsciiLetter(c)) && kept.length < MAX_HANDLE_LENGTH) {
            kept ~= c;
        }
    }
    return kept.length > 0 ? kept : "module";
}

private bool isHandleProblem(ProjectProblemKind kind) @safe pure nothrow @nogc {
    return kind == ProjectProblemKind.invalidHandle || kind == ProjectProblemKind.duplicateHandle
        || kind == ProjectProblemKind.unknownHandle || kind == ProjectProblemKind.protectedModule
        || kind == ProjectProblemKind.invalidName;
}

private bool checkHandle(string handle, out ProjectProblem problem) @safe pure nothrow {
    if (isValidHandle(handle)) {
        return true;
    }
    problem = ProjectProblem(ProjectProblemKind.invalidHandle, handle,
        "a module name starts with a letter and holds only letters, digits, '_' and '-', at most "
        ~ wholeText(MAX_HANDLE_LENGTH) ~ " characters", suggestedHandle(handle));
    return false;
}

private ProjectProblem positionProblem(string handle) @safe pure nothrow {
    return ProjectProblem(ProjectProblemKind.invalidPosition, handle,
        "the position of '" ~ handle ~ "' must be two finite numbers", "");
}

private ProjectProblem protectedProblem(string handle, string action) @safe pure nothrow {
    return ProjectProblem(ProjectProblemKind.protectedModule, handle,
        "the Master Output '" ~ OUTPUT_HANDLE ~ "' cannot be " ~ action, "");
}
```

Modules, inside the class. `indexOfHandle` returns `entries_.length` for "not found". Ids are never reused: notes will store them (T77).

```d
private size_t indexOfHandle(string handle) const @safe nothrow {
    foreach (i; 0 .. entries_.length) {
        if (namesMatch(entries_[i].handle, handle)) {
            return i;
        }
    }
    return entries_.length;
}

private ProjectProblem unknownHandleProblem(string handle) const @safe nothrow {
    return ProjectProblem(ProjectProblemKind.unknownHandle, handle,
        "there is no module '" ~ handle ~ "'", nearestName(handle, handles()));
}

private ProjectProblem duplicateProblem(string handle) const @safe nothrow {
    return ProjectProblem(ProjectProblemKind.duplicateHandle, handle,
        "there is already a module '" ~ handle ~ "'", freeHandle(handle));
}

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

private ProjectIdResult insertModule(string handle, ref const ModuleWriter writer, bool placed, float x, float y)
        @safe nothrow {
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

ProjectModuleResult moduleOf(string handle) const @safe nothrow {
    immutable size_t index = indexOfHandle(handle);
    if (index == entries_.length) {
        return ProjectModuleResult(ModuleWriter.init, 0, false, unknownHandleProblem(handle));
    }
    return ProjectModuleResult(ModuleWriter(entries_[index].writer), entries_[index].id, true);
}

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

ProjectEditResult removeModule(string handle) @safe nothrow {
    immutable size_t index = indexOfHandle(handle);
    if (index == entries_.length) {
        return ProjectEditResult(false, unknownHandleProblem(handle));
    }
    if (entries_[index].id == OUTPUT_MODULE_ID) {
        return ProjectEditResult(false, protectedProblem(handle, "removed"));
    }
    ModuleEntry[] kept;
    foreach (i; 0 .. entries_.length) {
        if (i != index) {
            kept ~= entries_[i];
        }
    }
    entries_ = kept;
    return ProjectEditResult(true);
}
```

- `addModule` returns `insertModule(handle, writer, false, 0.0f, 0.0f)`.
- `addModuleAt` and `moveModule` return `positionProblem(handle)` when `!isFinite(x) || !isFinite(y)`. `addModuleAt` checks this first, then inserts with `placed` true. `moveModule` checks the handle first, then stores `placed = true`, `posX`, `posY`.
- `moduleId` is `moduleOf` without the writer.

The document. Layout: four rows per column, the Master Output one column further right. The starter pattern and clip are those of a new app project (`session.d:766-773`); T77 will replace them and call `documentBytes` or `writeDocument`.

```d
ProjectDocumentResult document() const @safe nothrow {
    ProjectDocumentResult result;
    result.project.title = title_;
    result.project.bpm = bpm_;
    result.project.ticksPerLine = ticksPerLine_;
    result.project.timeSigNumerator = cast(ubyte) signature_.numerator;
    result.project.timeSigDenominator = cast(ubyte) signature_.denominator;
    result.project.keyTonic = key_.tonic;
    result.project.keyMode = cast(ubyte) key_.mode;
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
    SavedPattern starter;
    starter.patternId = 1;
    starter.tracks = STARTER_PATTERN_TRACKS;
    starter.lines = STARTER_PATTERN_LINES;
    starter.name = STARTER_PATTERN_NAME;
    starter.cells = new NoteCell[STARTER_PATTERN_TRACKS * STARTER_PATTERN_LINES];
    result.project.patterns = [starter];
    result.project.clips = [TimelineClip(1, 1, 0, 0, STARTER_PATTERN_LINES, 0, 0, false, false, false)];
    string err;
    if (!validateProjectForSave(result.project, err)) {
        result.problem = ProjectProblem(ProjectProblemKind.invalidProject, title_,
            "the project cannot be saved: " ~ err, "");
        return result;
    }
    result.ok = true;
    return result;
}

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

ProjectBytesResult documentBytes(const ref LoadedProject project) @safe nothrow {
    ProjectBytesResult result;
    string err;
    if (!serializeProject(project, result.bytes, err)) {
        result.problem = ProjectProblem(ProjectProblemKind.invalidProject, project.title,
            "the project cannot be saved: " ~ err, "");
        return result;
    }
    result.ok = true;
    return result;
}

ProjectEditResult writeDocument(const ref LoadedProject project, string path) @safe nothrow {
    string err;
    if (!validateProjectForSave(project, err)) {
        return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.invalidProject, project.title,
            "the project cannot be saved: " ~ err, ""));
    }
    if (!saveProjectFile(project, path, err)) {
        return ProjectEditResult(false, ProjectProblem(ProjectProblemKind.writeFailed, path,
            "could not write the project: " ~ err, ""));
    }
    return ProjectEditResult(true);
}

private bool saveProjectFile(const ref LoadedProject project, string path, out string err) @trusted nothrow {
    try {
        return saveProject(project, path, err);
    } catch (Exception ex) {
        err = ex.msg.length > 0 ? ex.msg : "Failed writing .msv project file";
        return false;
    }
}
```

`msvBytes` and `writeFile` call `document()`, return its problem when it failed, else `documentBytes(doc.project)` or `writeDocument(doc.project, path)`. The DDoc of `saveProjectFile` must say why it is `@trusted`: `saveProject` is not marked `@safe` or `nothrow`, although it only hands validated bytes to the file system.

The key parser:

```d
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
```

**Steps.** After each step run Gate 2 of `qwen-inkling.md`; it must print only `exit 0`.
1. Header, imports, constants, problem and result types, handle helpers, `wholeText`.
2. `ModuleEntry`, class fields, constructor, getters, setters.
3. `indexOfHandle` to `insertModule`, `handles`, `hasModule`, `moduleId`, `moduleOf`, `addModule`, `addModuleAt`.
4. `renameModule`, `setModuleName`, `moveModule`, `removeModule`.
5. `parseKey`.
6. `outputColumn`, `document`, `documentBytes`, `writeDocument`, `msvBytes`, `writeFile`, `saveProjectFile`.
7. The tests; then `dub build --compiler=ldc2 --config=compose` and Gates 2, 1 and 3.

**Acceptance table.** Limits: `io/project_format.d:52-73`.

| Input | Working | Expected |
| --- | --- | --- |
| new writer, `document()` | no automatic module: column max(1, 0); 60+1·180 | id 1, `core.output`, "Master Output", `[1, 1]`, at (240, 60); 1 pattern, 1 clip |
| `setTempo(19.9)`, `(999.5)`, `(double.nan)` | limits 20.0, 999.0; default 125.0 | refused: "20", "999", "125"; 20.0, 999.0 accepted |
| `setTicksPerLine(0)`, `(256)` | 1 to 255 | refused: "1", "255"; 255 accepted |
| `setTimeSignature` 17/4, 0/4, 4/3; `setKey(MusicalKey(12, KeyMode.major))` | numerator 1 to 16; denominator 2, 4, 8, 16; tonic below 12 | refused: "4/4"; "C major"; 16/16 accepted |
| `parseKey("A minor")`, `("Cb")`, `("B#")` | A=9; (0−1+12)%12; (11+1+12)%12 | (9, minor), (11, major), (0, major) |
| `parseKey("Am")`, `("H minor")` | "minor" starts with "m"; H is not A to G | refused: "A minor", "C major" |
| title of 65_537 bytes | limit 65_536 | `invalidTitle`; 65_536 accepted |
| add "my bass", "2bass", "", 33 letters | space dropped; digit skipped; nothing left; cut at 32 | `invalidHandle`: "mybass", "bass", "module", first 32 letters |
| add "BASS" after "bass"; add "out" | case ignored; first free number 2 | `duplicateHandle`: "BASS2", "out2" |
| `moduleId("bas")`, `("zzzzzz")` | "bass" starts with "bas"; distance 6 to "out", 6·2>6 | `unknownHandle`: "bass", "" |
| add, add, remove the first, add | ids start at 1+1; none reused | 2, 3, then 4 |
| 6 automatic modules | slot 4: 4/4=1, 4%4=0; columns (6+3)/4=2 | fifth (240, 60), sixth (240, 220), output (420, 60) |
| 1023 modules, then one more | 1023+1 = `MAX_MODULES` 1024 | accepted, then `tooManyModules` |
| remove or rename "out", `setModuleName("out", "Main")`, add a `core.output` writer; add `ModuleWriter.init`; position `float.nan` | one Master Output; not loaded; not finite | `protectedModule`; `notLoaded`; `invalidPosition` |
| `addModule("bass", presetWriter)` then `renameModule("bass", "sub")` then `setModuleName("sub", "Electric Bass")` | displayed name tracks handle until overridden; `out` stays "Master Output" | document module name `"bass"`, then `"sub"`, then `"Electric Bass"` (handle still `"sub"`) |
| `setModuleName("sub", "bad/name")` | `/` is invalid in module names (`ModuleWriter.setName`) | refused: `invalidName`, suggestion `"bad-name"`, displayed name unchanged |
| `writeFile` into a missing folder; `documentBytes` with `bpm = 5.0` | the write fails; 5<20 | `writeFailed`, subject = path; `invalidProject`, "the project cannot be saved: Out-of-range BPM or TPL" |
| 6/8, A minor, 96 bpm, 4 ticks, written and read | tonic 9, minor 1 | 6, 8, 9, 1, 96.0, 4 |

**Tests.** `tests/unit/compose_project_test.d`, module `tests.unit.compose_project_test`, inside `version (unittest) { … }`, header block like `tests/unit/compose_module_test.d`. Copy `writerOf` (115). One `unittest` block each:
1. Defaults of a new writer and its document.
2. Setters: edges, refusals (kind, subject, suggestion), value unchanged after a refusal.
3. `parseKey`: the table rows; `parseKey(keyName(k)).key == k` for all `allKeys()`; every suggestion parses.
4. `isValidHandle`, `suggestedHandle`; every suggestion is valid.
5. Modules: add, displayed name = handle (`out` stays "Master Output"), lookup ("KEYS", "k e y s"), refusals, rename (updates displayed name), `setModuleName` (valid, invalid with `invalidName`, `"out"` with `protectedModule`), move, remove, ids, layout; changing the caller's writer afterwards changes nothing.
6. The module limit.
7. File round trip, imitating line 680 (path in `tempDir()` with `thisProcessID()`, removed in `scope (exit)`): `writeFile`, `loadProjectFile`, compare everything; then `new StudioSession()`, `initialize(44_100.0f)`, `scope (exit) session.shutdown()`, `openProjectFile(path, err)`, 3 modules. Failed writes as at line 1050.

**Pitfalls.**
- Copy a writer with `ModuleWriter(other)`. A plain `=` from a `const` writer does not compile.
- Take the writer by value; `const ref` refuses `addModule("a", writerOf("x"))`.
- Compare `indexOfHandle` with `entries_.length`, never as a boolean.
- Never import from `gui.views.pattern_editor`: the `compose` build excludes `source/gui`.
- No method named `remove` or `rename`. In the test, import `std.file.remove` as `fileRemove`.
- Without `new ProjectWriter()` the variable is `null`.

**Do not.** Change no existing source file. Add no wires, ports, trial activation, parts, script parsing or author setter. Do not print or throw.

**Done when.**
- Gate 2 prints only `exit 0` for both files; Gate 3 prints nothing.
- `dub build --compiler=ldc2 --config=compose` links with exit 0.
- Gate 1 prints `N modules passed unittests`, N one higher than before.
- Every table row is an assertion with the literal value.

**Decided by the owner (2026-11-26).**
1. Handle rule as written above: ASCII letters, digits, `_`, `-`; first a letter; at most 32 bytes.
2. **A module is shown in the app under its handle** (folded into the code and acceptance table above): `insertModule` and `renameModule` call `setName(handle)` on the stored copy; `out` stays named `Master Output`; `setModuleName(handle, name)` sets another displayed name and returns `ProjectProblemKind.invalidName` (or `protectedModule` for `out`) on refusal.
3. A document without patterns gets the app's starter pattern and clip, as written above.
4. `#` is not a comment sign any more: comments in the script language start with `//` (T67 was changed). `parseKey` accepts `#` and `b` as written above.

---

## T84 · [Compose/script] Script language: note notation

Stage 0 · Build · guide written 2026-11-26 by Claude Fable 5.2

**Goal.** A new pure module `compose.script.notation` turns note text such as `C4:1 E4:1/2 [C4 E4 G4]:2@0.6 -` into a list of events (offset in lines, length in lines, MIDI pitches, velocity) for a time signature. Every problem is data with its offset in the text. It writes no patterns and knows no commands, parts or `#` comments (T83).

**Read first.**
1. `source/compose/timing.d`: `TimeSignature` (84), `TimingError` (128), `LengthResult` (147), `linesPerBeat` (190), `parseLength` (481-570), `indexOf` (696). Learn the result shape and the sentinel: not found is `text.length`.
2. `source/app/music_theory.d`: `noteName` (234-241), `accidentalText` (328-341). The spelling: letter, `#`/`##`/`b`/`bb`, octave; MIDI 60 is `C4`, 0 is `C-1`, 127 is `G9`. Nothing in the app parses a note name; you write it.
3. `source/sequencer/note.d`: `NoteCell` (75-88), `encodeVelocity` (152), `normalizedVelocity` (280). Notes are MIDI 0..127; velocity is a float 0..1; without one a cell plays at 0.8.
4. `source/app/pattern_notes.d`: `RollNote` (47-54), `addNote` (186-201, velocity in (0, 1]).
5. `tests/unit/compose_timing_test.d`: 27-55 (layout), 406-426 (sweep).

**Existing code to use.**

```d
struct TimeSignature {
    uint numerator = DEFAULT_TIME_SIG_NUMERATOR;
    uint denominator = DEFAULT_TIME_SIG_DENOMINATOR;
    bool isValid() const @safe pure nothrow @nogc
}
struct Length {
    uint lines = 0;
}
struct TimingError {
    size_t offset = 0;
    size_t length = 0;
    string reason = "";
    string suggestion = "";
}
struct LengthResult {
    Length length = Length();
    bool ok = false;
    TimingError error = TimingError();
}
enum ulong MAX_POSITION_LINES = MAX_LINES;
uint linesPerBeat(TimeSignature sig) @safe pure nothrow @nogc
LengthResult parseLength(string text, TimeSignature sig) @safe pure nothrow
string formatTimeSignature(TimeSignature sig) @safe pure nothrow
string noteName(int midi, MusicalKey key) @safe pure nothrow
bool isSpaceChar(char c) @safe pure nothrow @nogc
```

- `linesPerBeat` (timing.d:190) returns 0 for an invalid signature.
- `parseLength` (timing.d:481): on failure `ok` is false and `error.offset` counts from the start of the length text. Empty text is refused. The result is 1 to 4096 lines.
- `MAX_POSITION_LINES` (timing.d:55) is 4096 (`io/project_format.d:59`).
- `noteName` (music_theory.d:234) with `MusicalKey()` spells in C major. `isSpaceChar` is `compose/names.d:220`.
- `RollNote.init.velocity` (pattern_notes.d:52) is 0.8f. Use it; write no second 0.8.
- `LETTER_PITCH` (music_theory.d:62) and `LETTER_PC` (chord_progression.d:128) are private.

**Write.** Grammar, declarations, rules, and every refusal:

```
sequence = [ item { SPACES item } ]
item     = rest | note | chord
rest     = "-" [ ":" length ]
note     = pitch [ ":" length ] [ "@" velocity ]
chord    = "[" pitch { SPACES pitch } "]" [ ":" length ] [ "@" velocity ]
pitch    = LETTER [ "#" | "##" | "b" | "bb" ] [ "-" ] DIGIT { DIGIT }
velocity = DIGIT { DIGIT } [ "." DIGIT { DIGIT } ]     at most 3 digits before the dot, 6 after
length   = any text compose.timing.parseLength accepts
LETTER   = "A" .. "G" (capitals only)
SPACES   = one or more characters for which isSpaceChar is true
```

```d
module compose.script.notation;

import app.music_theory : MusicalKey, noteName;
import app.pattern_notes : RollNote;
import compose.names : isSpaceChar;
import compose.timing : formatTimeSignature, LengthResult, linesPerBeat, MAX_POSITION_LINES, parseLength,
    TimeSignature;

enum float DEFAULT_NOTE_VELOCITY = RollNote.init.velocity;

struct NotationError {
    size_t offset = 0;
    size_t length = 0;
    string reason = "";
    string suggestion = "";
}

struct NoteEvent {
    uint offset = 0;
    uint length = 0;
    ubyte[] pitches;
    float velocity = DEFAULT_NOTE_VELOCITY;
    size_t textOffset = 0;
    size_t textLength = 0;
}

struct PitchResult {
    ubyte midi = 0;
    bool ok = false;
    NotationError error = NotationError();
}

struct NotationResult {
    NoteEvent[] events;
    uint totalLines = 0;
    bool ok = false;
    NotationError error = NotationError();
}

PitchResult parsePitch(string text) @safe pure nothrow
string formatPitch(ubyte midi) @safe pure nothrow
NotationResult parseNotes(string text, TimeSignature sig) @safe pure nothrow

private struct VelocityResult {
    float value = DEFAULT_NOTE_VELOCITY;
    bool ok = false;
    NotationError error = NotationError();
}
private VelocityResult parseVelocity(string text) @safe pure nothrow
private size_t itemEnd(string text, size_t start) @safe pure nothrow @nogc
private size_t findChar(string text, char needle, size_t from) @safe pure nothrow @nogc
private immutable int[7] LETTER_SEMITONES = [9, 11, 0, 2, 4, 5, 7];
```

```
parsePitch     MIDI = (octave + 1) * 12 + LETTER_SEMITONES[letter - 'A'] + accidental
               accidental is +1 for each "#", -1 for each "b"; accepted when 0 <= MIDI <= 127
               error offsets count from the start of the pitch text
formatPitch    noteName(midi, MusicalKey()); "" when midi > 127
parseVelocity  scaled = all digits read as one ulong; divisor = 10 for each digit after the dot
               accepted when 0 < scaled <= divisor
               value = cast(float)(cast(double) scaled / cast(double) divisor)
findChar       index of needle at or after from; text.length when absent
itemEnd        item starts with "[": the first space after its first "]"; text.length when there is no "]"
               any other item: the first space at or after start; text.length when there is none
parseNotes     1. linesPerBeat(sig) == 0: refuse (S1).
               2. carried = linesPerBeat(sig); offset = 0 (ulong).
               3. Skip spaces; take the next item [start .. itemEnd).
               4. head = "[" up to and including "]" for a chord; otherwise the text before the first ":" or "@".
                  The rest of the item is the suffix: [":" length]["@" velocity].
               5. head == "-" is a rest. Otherwise parsePitch(head), or parsePitch of each pitch inside "[ ]".
               6. A written length: parseLength; carried = its lines. No written length: length = carried.
                  This holds for notes, chords and rests alike.
               7. "@velocity" applies to the whole chord. No "@": DEFAULT_NOTE_VELOCITY. Velocity is never carried.
               8. offset + length > MAX_POSITION_LINES: refuse (S8).
               9. Note or chord: append NoteEvent(offset, length, pitches in written order, velocity, start, item length).
                  Rest: append nothing.
               10. offset += length; go to 3. At the end: ok = true, totalLines = offset.
               Empty or all-space text: ok, no events, totalLines 0.
               First problem: return ok = false, events empty, the error with offsets in the whole text.
```

```
id  case                             (offset, length)        reason                                                  suggestion
P1  empty pitch                      (0, 0)                  "a pitch needs a note letter"                           "C4"
P2  first letter a..g                (0, 1)                  "note letters are capitals (A to G)"                    capital spelling if it parses, else ""
P3  other first character            (0, 1)                  "a pitch starts with a note letter (A to G)"            ""
P4  over two accidentals, or # and b (1, run of # and b)     "a pitch has at most two sharps (#) or two flats (b)"   ""
P5  no octave digit                  (where expected, 0)     "a pitch needs an octave number (C4 is middle C)"       letter + accidentals + "4"
P6  text after the octave            (there, to end)         "unexpected text after the octave"                      text before it if it parses, else ""
P7  MIDI > 127                       (0, whole pitch)        "the highest note is G9"                                "G9"
P8  MIDI < 0                         (0, whole pitch)        "the lowest note is C-1"                                octave <= -2: pitch without "-" if it parses; else "C-1"
V1  empty velocity                   (0, 0)                  "a velocity needs a number from 0 to 1"                 "0.8"
V2  not as in the grammar            (0, whole velocity)     "a velocity is a number such as 0.8"                    "0.8"
V3  above 1                          (0, whole velocity)     "a velocity is at most 1"                               "1"
V4  zero                             (0, whole velocity)     "a velocity is above 0"                                 "0.1"
S1  linesPerBeat(sig) == 0           (0, text.length)        "the time signature " ~ formatTimeSignature(sig) ~ " is not one this project accepts"   "4/4"
S2  "[" without "]"                  (item start, item)      "a chord needs a closing ]"                             ""
S3  chord without pitches            (item start, to "]")    "a chord needs at least one pitch"                      "[C4 E4 G4]"
S4  same MIDI twice in a chord       (second pitch, its length) "the chord has this note twice"                      ""
S5  after "]" not ":", "@" or end    (there, 1)              "after ] comes :length or @velocity"                    ""
S6  ":" after "@"                    (that ":", 1)           "the length is written before the velocity"             ""
S7  rest with "@"                    ("@", to end of item)   "a rest has no velocity"                                "-"
S8  offset + length > 4096           (item start, item)      "the notes are longer than the longest pattern"         ""
L   parseLength refused              (lengthStart + e.offset, e.length)   e.reason                                   e.suggestion
```

**Steps.** After each step run Gate 2 of `qwen-inkling.md` on both files.
1. Create `source/compose/script/notation.d`: header block (shape of `timing.d:1-39`), imports, types, `LETTER_SEMITONES`, and the public functions as stubs returning `.init` values. Create the test file with its header and one `unittest`: `DEFAULT_NOTE_VELOCITY == 0.8f`.
2. `parsePitch`, `formatPitch`, pitch tests.
3. `parseVelocity`, `findChar`, `itemEnd`.
4. `parseNotes` for rests and single notes; sequence tests.
5. Chords; chord tests.
6. Refusal tests and the sweep. Then Gates 3 and 1.

**Acceptance table.** Lines per beat = 16 / denominator (timing.d:194): 4 in 4/4, 2 in 6/8. Bars: 16 and 12 lines. Events are (offset, length, pitches, velocity); errors are (offset, length, suggestion).

| input | working | expected |
| :-- | :-- | :-- |
| `C4` `A4` `Bb3` `E#4` | 5·12+0, 5·12+9, 4·12+11−1, 5·12+4+1 | 60, 69, 58, 65 |
| `C-1` `G9` `B#-2` | 0·12+0, 10·12+7, −1·12+11+1 | 0, 127, 0 |
| `C4:1 E4:1/2 G4:1/2@0.6` in 4/4 | 4, 4/2=2, 2 | (0,4,[60],0.8) (4,2,[64],0.8) (6,2,[67],0.6); total 8; textOffset 0,5,12 |
| same in 6/8 | 2, 2/2=1, 1 | (0,2) (2,1) (3,1); total 4 |
| `C4 D4 E4` | one beat each | 4/4: (0,4) (4,4) (8,4), total 12. 6/8: (0,2) (2,2) (4,2), total 6 |
| `C4:2 D4 - E4:3l F4` in 4/4 | 8, carried 8, rest carried 8, 3, carried 3 | (0,8) (8,8) (24,3) (27,3); total 30 |
| `[C4 E4 G4]:2` | 2·4; 2·2 | 4/4: (0,8,[60,64,67],0.8). 6/8: length 4 |
| `C4:1b -:1b [A3 C#4]@0.5` in 6/8 | bar=12; chord carries 12; 4·12+9, 5·12+1 | (0,12,[60]) (24,12,[57,61],0.5); total 36 |
| `-` in 4/4; empty text | one beat | ok, no events, total 4; total 0 |
| `C4@1` `C4@0.05` | 1/1, 5/100 | velocity 1.0, 0.05 |
| `C4 c4` | P2, second item | (3,1,`C4`) |
| `H4` `C###4` `C#b4` | P3, P4, P4 | (0,1,"") (1,3,"") (1,2,"") |
| `C`; `C4 F#` | P5 | (1,0,`C4`); (5,0,`F#4`) |
| `C4x`; `[C4:1 E4]` | P6; the pitch starts at 1 | (2,1,`C4`); (3,2,`C4`) |
| `G#9` `Cb-1` `C-4` | 120+8=128; 0−1=−1; −3·12=−36 | (0,3,`G9`) (0,4,`C-1`) (0,3,`C4`) |
| `C4:`; `C4:1/3` in 4/4; `C4:1/4` in 6/8 | L; 4/3 lines, nearest 1; 2/4 lines, nearest 1 | (3,0,`1`); (3,3,`1/4`); (3,3,`1/2`) |
| `C4:257b` in 4/4 | 257·16=4112 > 4096; 4096/16=256 | (3,4,`256b`) |
| `C4@` `C4@x` `C4@1.5` `C4@0` | V1, V2, V3, V4 | (3,0,`0.8`) (3,1,`0.8`) (3,3,`1`) (3,1,`0.1`) |
| `C4@0.6:1`; `-@0.5` | S6; S7 | (6,1,""); (1,4,`-`) |
| `[C4 E4` `[]` `[C4]x` | S2, S3, S5 | (0,6,"") (0,2,`[C4 E4 G4]`) (4,1,"") |
| `[C4 C4]` `[C#4 Db4]` | S4; 61 twice | (4,2,"") (5,3,"") |
| `C4:256b -:1l` in 4/4 | 4096+1 > 4096 | S8 (8,4,"") |
| `C4`, `TimeSignature(4, 3)` | linesPerBeat = 0 | S1 (0,2,`4/4`) |

**Tests.** `tests/unit/compose_notation_test.d`, module `tests.unit.compose_notation_test`, all inside `version (unittest)` as `compose_timing_test.d:29`. No registration is needed. Blocks:
1. The two pitch rows; `formatPitch` of 60, 0, 127 gives `C4`, `C-1`, `G9`.
2. Round trip: for every key of `allKeys()` (music_theory.d:75) and midi 0..127, `parsePitch(noteName(midi, key)).midi == midi`.
3. Every sequence row, with literal values.
4. Every refusal row: `!ok`, offset, length, suggestion, non-empty reason, no events.
5. Every non-empty P, V, S suggestion is accepted: `parsePitch(s)`, `parseNotes("C4@" ~ s, sig)`, or `parseNotes(s, sig)`.
6. Sweep as `compose_timing_test.d:406`: tokens `C4`, `-`, `[C4 E4]`, `[`, `]`, `:1`, `@0.5`, `x`; all three-token texts joined with `" "` and with `""`, in both signatures; assert `r.ok || r.error.reason.length > 0` and `r.error.offset <= text.length`.

Compare velocities with `fabs(a - b) < 1e-6f`.

**Pitfalls.**
- `-` is a rest and also the minus of `C-1`. A rest is only `head == "-"`.
- The pattern editor shows middle C as `C-4` (`gui/views/pattern_editor.d:123`). Here `C-4` means octave −4.
- Octave arithmetic is `int`; `uint` wraps at octave −1. Stop adding octave digits once the number passes 99.
- Add offsets as `ulong`; compare with `MAX_POSITION_LINES` before `cast(uint)`.
- `parseLength` offsets are relative: add the start of the length text.
- Compare "not found" with `text.length`.
- Each event needs its own `pitches` array.
- `std.conv.to` and `std.format` do not compile in `nothrow`; `indexOf` and `isDigit` in `timing.d` are private. Write loops.

**Do not.** Do not edit `timing.d`, `music_theory.d`, `names.d`, `pattern_notes.d` or `dub.json`. Do not accept lowercase letters, `♯`/`♭` or MIDI numbers. Do not check notes against a section or module (T97).

**Done when.**
- Every function has DDoc.
- Every table row is an assertion with its literal value.
- Gates 1, 2 and 3 pass, with the printed lines recorded.

**Decided by the owner (2026-11-26).**
1. Comments in the script language start with `//`, not `#` (T67 was changed), so `#` in a note is always a sharp. This module never sees comments; nothing to do here.
2. Only the `app.music_theory` spelling is accepted (`C4`; `C-1` is MIDI 0). The tracker spelling `C-4` is refused with the suggestion `C4`.
3. A rest's written length is carried to the next item like a note's.
4. Velocity is 0 < v ≤ 1, default 0.8, never carried between notes.

---

## T110 · [GUI/widgets] Multi-line text editor widget

Stage 0 · Build · guide written 2026-11-26 by Gemini 4 Neon

**Goal.** `source/gui/widgets.d` gets a `TextArea` widget: monospace multi-line editing with caret, selection, clipboard delegates, vertical scrolling, a line-number gutter and one marked line. A new test file covers it and the gallery shows one. Left out: undo, word wrap, horizontal scrolling (long lines are clipped), a draggable scrollbar, caret blink, and drawing of uncommitted IME text.

**Read first.**
1. `agents.md` Rule 1 (14 to 37) and `qwen-inkling.md`: the gates.
2. `source/gui/widgets.d`: `KeyCode` (67), the event structs (113 to 170), `class Widget` (268 to 820): the hooks to override.
3. Same file, `class TextField` (3080 to 3360): the style to copy. It has **no** selection range, clipboard code, word movement or blink.
4. Same file, `UiContext.handleKeyDown` (1596 to 1632): `false` for Tab lets the context move focus. `GroupedList.scrollTo` (3893), `ScrollBarModel` (4838): the scroll pattern.
5. `source/gui/theme.d` 98 to 224 (tokens, metrics), `scaled()` (409).
6. `source/gui/views/transport_bar.d` 137: a lit state is a stroke of `2.0f * theme.borderWidth`.
7. `tests/unit/gui_test.d`: `FakeRasterizer` (49), `Harness` (314 to 509), the `TextField` test (2336 to 2397), the stroke search (2293 to 2298).
8. `source/app/gui_gallery.d`: the `GalleryScene` constructor (147 to 202).

**Existing code to use.**
```d
class Widget {
    string id;
    RectF bounds;
    Point2F preferredSize;
    bool focusable = false;
    final UiContext context();
    final bool isFocused();
    final void invalidate();
    Point2F measure(ITextMeasurer m, const ref StudioTheme theme);
    void layoutChildren();
    void paint(IRenderer2D r, const ref StudioTheme theme);
    bool onMouseDown(const ref MouseEvent e);
    bool onMouseUp(const ref MouseEvent e);
    bool onMouseMove(const ref MouseEvent e);
    bool onScroll(const ref ScrollEvent e);
    bool onKeyDown(const ref KeyEvent e);
    bool onKeyUp(const ref KeyEvent e);
    bool onTextInput(dchar c);
    void onCaptureLost();
}
```
`context()` is `null` outside a tree. Hooks return `true` for "handled". A handled `onMouseDown` captures the mouse.
```d
float measureTextOr(ITextMeasurer m, const(char)[] text, FontId font, float size);
float lineHeightOr(ITextMeasurer m, FontId font, float size);
bool hasModifier(uint mods, KeyModifiers flag) @safe nothrow pure @nogc;
float clampf(float v, float lo, float hi);
```
With `m` null these fall back to 0.6 em and 1.2 em. `clampf` and `Axis` are already imported.
```d
final class UiContext {
    StudioTheme theme;
    ITextMeasurer measurer();
    bool setFocus(Widget w);
    void setTheme(const ref StudioTheme t);
}
struct ScrollBarModel {
    Axis axis; RectF track; float contentLength; float viewportLength; float offset; float minThumb;
    RectF thumbRect() const;
}
```
`measurer()` can be `null`. `MouseEvent.clickCount` is 2 on a double-click. Test Option and Command with `hasModifier(e.modifiers, KeyModifiers.alt)` and `KeyModifiers.command`.
```d
void pushClip(RectF rect);
void popClip();
void fillRect(RectF rect, ColorRGBA color);
void fillRoundedRect(RectF rect, float radius, ColorRGBA color);
void strokeRoundedRect(RectF rect, float radius, float width, ColorRGBA color);
void drawText(Point2F origin, const(char)[] text, FontId font, float size, ColorRGBA color);
```
`IRenderer2D` is also an `ITextMeasurer`. Shapes outside the clip are not recorded. The font is `FontId.mono` at `theme.fontSizeMono`. Tokens: `textDim` for line numbers, `selection`, `accentHot` for the caret, `danger` for the marked line.

**Write.** Storage is an array of lines, `dchar[][] lines_`, never empty, without newline characters. A column is a code-point index, as in `TextField.caret()`. Reason: movement, gutter and drawing work per line, and a `dchar` index cannot land inside "é" or "가". Nothing in `TextField` can be extracted as a helper; copy only its `onTextInput` filter (3205) and its drawing calls (3315 to 3338). All else is new.

Add `x = 7, c = 8, v = 9` to `KeyCode` (the codes of `source/app/keymap.d` 248 to 250). Add `import std.uni : isAlpha, isNumber;`. Put the new code after `openTextEditor()` (ends at line 3384).
```d
struct TextPos {
    size_t line = 0;
    size_t col = 0;
}

bool textPosBefore(TextPos a, TextPos b) @safe nothrow pure @nogc {
    return a.line < b.line || (a.line == b.line && a.col < b.col);
}

bool isWordChar(dchar c) @safe nothrow pure @nogc {
    return c == '_' || isAlpha(c) || isNumber(c);
}

size_t decimalDigits(size_t n) @safe nothrow pure @nogc {
    size_t d = 1;
    while (n >= 10) {
        n /= 10;
        d++;
    }
    return d;
}

struct TextAreaMetrics {
    float pad = 0.0f;
    float lineH = 0.0f;
    float gutterW = 0.0f;
    float textX = 0.0f;
    float textTop = 0.0f;
    float viewH = 0.0f;
}

class TextArea : Widget {
    enum size_t TAB_SPACES = 4;
    enum size_t GUTTER_MIN_DIGITS = 2;
    enum size_t DEFAULT_ROWS = 8;
    enum size_t NO_MARK = size_t.max;

    void delegate() onChange;
    void delegate() onSubmit;
    string delegate() clipboardRead;
    bool delegate(string) clipboardWrite;
    private dchar[][] lines_;
    private TextPos caret_;
    private TextPos anchor_;
    private size_t wantCol_ = 0;
    private size_t markedLine_ = NO_MARK;
    private float scrollY_ = 0.0f;
    private bool dragging_ = false;

    this(string initial = "");
    string text() const;
    void setText(string t);
    void clear();
    size_t lineCount() const;
    size_t caretLine() const;
    size_t caretColumn() const;
    void setCaret(size_t line, size_t col, bool extend = false);
    bool hasSelection() const;
    string selectedText() const;
    void selectAll();
    void insertText(string s);
    void markLine(size_t line);
    void clearMark();
    size_t markedLine() const;
    float scrollOffset() const;
    bool scrollTo(float y);
    size_t visibleLineCount();
    float gutterWidth();
    RectF lineRect(size_t line);
    TextAreaMetrics metricsFor(ITextMeasurer m, const ref StudioTheme theme) const;
}
```
`setText` resets caret, selection, mark and scroll, and does not call `onChange`. The selection lies between `anchor_` and `caret_`; equal means none. `markLine(n)` with `n >= lineCount()` stores `NO_MARK`; every edit clears the mark. `scrollTo` returns `true` only when the offset changed. Gutter width: `max(decimalDigits(lineCount()), GUTTER_MIN_DIGITS)` times the width of `"0"`, plus `2 * spacingSm`.

Keys: Escape, Shift+Tab and unknown Command keys return `false`, so the parent and application shortcuts still work. Tab inserts `TAB_SPACES` spaces. Option+Left/Right move by word. Page keys move `visibleLineCount()` lines. Shift extends the selection. Cmd+Return calls `onSubmit`.

Give every public member and free function a DDoc block. Overrides and private helpers follow `TextField` (none).

**Steps.** After each step run Gate 2 with `source/gui/widgets.d tests/unit/widgets_textarea_test.d`. Run Gate 1 after steps 4, 7 and 9. Write each step's tests in that step.

1. Storage. Add the `KeyCode` entries, the import, the free functions, both structs, the class with fields and getters, and these bodies. `clear()` is `setText("")`. Leave `ensureCaretVisible()` empty for now.
```d
this(string initial = "") {
    focusable = true;
    setText(initial);
}

string text() const {
    string s;
    foreach (i, ln; lines_) {
        if (i > 0) {
            s ~= '\n';
        }
        s ~= toUTF8(ln);
    }
    return s;
}

void setText(string t) {
    lines_ = splitLines(t);
    caret_ = TextPos(0, 0);
    anchor_ = caret_;
    wantCol_ = 0;
    markedLine_ = NO_MARK;
    scrollY_ = 0.0f;
    invalidate();
}

void setCaret(size_t line, size_t col, bool extend = false) {
    moveCaret(clampPos(TextPos(line, col)), extend);
}

bool hasSelection() const {
    return anchor_ != caret_;
}

private static dchar[][] splitLines(string s) {
    dchar[][] result;
    dchar[] cur;
    bool afterCr = false;
    foreach (dchar c; s) {
        if (c == '\n' && afterCr) {
            afterCr = false;
            continue;
        }
        afterCr = c == '\r';
        if (c == '\n' || c == '\r') {
            result ~= cur;
            cur = null;
        } else if (c == '\t') {
            foreach (k; 0 .. TAB_SPACES) {
                cur ~= ' ';
            }
        } else if (c >= 0x20 && c != 0x7F) {
            cur ~= c;
        }
    }
    result ~= cur;
    return result;
}

private TextPos selStart() const {
    return textPosBefore(anchor_, caret_) ? anchor_ : caret_;
}

private TextPos selEnd() const {
    return textPosBefore(anchor_, caret_) ? caret_ : anchor_;
}

private TextPos clampPos(TextPos p) const {
    if (p.line >= lines_.length) {
        p.line = lines_.length - 1;
    }
    if (p.col > lines_[p.line].length) {
        p.col = lines_[p.line].length;
    }
    return p;
}

private void moveCaret(TextPos p, bool extend) {
    caret_ = p;
    if (!extend) {
        anchor_ = p;
    }
    wantCol_ = p.col;
    ensureCaretVisible();
    invalidate();
}
```
2. Metrics and scrolling. `gutterWidth()` returns `liveMetrics().gutterW`.
```d
TextAreaMetrics metricsFor(ITextMeasurer m, const ref StudioTheme theme) const {
    TextAreaMetrics k;
    immutable size_t digits = decimalDigits(lines_.length);
    k.pad = theme.spacingSm;
    k.lineH = lineHeightOr(m, FontId.mono, theme.fontSizeMono);
    k.gutterW = cast(float)(digits > GUTTER_MIN_DIGITS ? digits : GUTTER_MIN_DIGITS)
        * measureTextOr(m, "0", FontId.mono, theme.fontSizeMono) + 2.0f * k.pad;
    k.textX = bounds.x + k.gutterW + k.pad;
    k.textTop = bounds.y + k.pad;
    k.viewH = bounds.h - 2.0f * k.pad;
    return k;
}

private TextAreaMetrics liveMetrics() {
    auto ctx = context();
    if (ctx is null) {
        immutable StudioTheme def = StudioTheme.init;
        return metricsFor(null, def);
    }
    return metricsFor(ctx.measurer(), ctx.theme);
}

bool scrollTo(float y) {
    immutable TextAreaMetrics k = liveMetrics();
    immutable float content = cast(float) lines_.length * k.lineH;
    immutable float maxY = content > k.viewH && k.viewH > 0.0f ? content - k.viewH : 0.0f;
    immutable float ny = clampf(y, 0.0f, maxY);
    if (ny == scrollY_) {
        return false;
    }
    scrollY_ = ny;
    invalidate();
    return true;
}

size_t visibleLineCount() {
    immutable TextAreaMetrics k = liveMetrics();
    if (!(k.lineH > 0.0f) || !(k.viewH >= k.lineH)) {
        return 1;
    }
    return cast(size_t)(k.viewH / k.lineH);
}

RectF lineRect(size_t line) {
    immutable TextAreaMetrics k = liveMetrics();
    return RectF(bounds.x, k.textTop + cast(float) line * k.lineH - scrollY_, bounds.w, k.lineH);
}

private void ensureCaretVisible() {
    immutable TextAreaMetrics k = liveMetrics();
    if (!(k.viewH > 0.0f)) {
        return;
    }
    immutable float top = cast(float) caret_.line * k.lineH;
    if (top < scrollY_) {
        scrollTo(top);
    } else if (top + k.lineH > scrollY_ + k.viewH) {
        scrollTo(top + k.lineH - k.viewH);
    }
}

override bool onScroll(const ref ScrollEvent e) {
    return scrollTo(scrollY_ - e.deltaY);
}

override void layoutChildren() {
    scrollTo(scrollY_);
}

override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
    if (preferredSize.x > 0.0f && preferredSize.y > 0.0f) {
        return preferredSize;
    }
    immutable TextAreaMetrics k = metricsFor(m, theme);
    return Point2F(k.gutterW + 40.0f * measureTextOr(m, "0", FontId.mono, theme.fontSizeMono) + 2.0f * k.pad,
        cast(float) DEFAULT_ROWS * k.lineH + 2.0f * k.pad);
}
```
3. Caret keys. This is the final `onKeyDown`; in this step leave out its first four cases and the `onCommandKey` call. `onKeyUp` returns `true`.
```d
private void moveVertical(ptrdiff_t delta, bool extend) {
    immutable size_t keep = wantCol_;
    immutable ptrdiff_t target = cast(ptrdiff_t) caret_.line + delta;
    if (target < 0) {
        moveCaret(TextPos(0, 0), extend);
    } else if (target >= cast(ptrdiff_t) lines_.length) {
        moveCaret(TextPos(lines_.length - 1, lines_[$ - 1].length), extend);
    } else {
        moveCaret(clampPos(TextPos(cast(size_t) target, keep)), extend);
        wantCol_ = keep;
    }
}

private TextPos charLeft(TextPos p) const {
    if (p.col > 0) {
        return TextPos(p.line, p.col - 1);
    }
    return p.line > 0 ? TextPos(p.line - 1, lines_[p.line - 1].length) : p;
}

private TextPos charRight(TextPos p) const {
    if (p.col < lines_[p.line].length) {
        return TextPos(p.line, p.col + 1);
    }
    return p.line + 1 < lines_.length ? TextPos(p.line + 1, 0) : p;
}

private TextPos wordLeft(TextPos p) const {
    if (p.col == 0) {
        return charLeft(p);
    }
    const(dchar)[] ln = lines_[p.line];
    size_t c = p.col;
    while (c > 0 && !isWordChar(ln[c - 1])) {
        c--;
    }
    while (c > 0 && isWordChar(ln[c - 1])) {
        c--;
    }
    return TextPos(p.line, c);
}

private TextPos wordRight(TextPos p) const {
    const(dchar)[] ln = lines_[p.line];
    if (p.col == ln.length) {
        return charRight(p);
    }
    size_t c = p.col;
    while (c < ln.length && !isWordChar(ln[c])) {
        c++;
    }
    while (c < ln.length && isWordChar(ln[c])) {
        c++;
    }
    return TextPos(p.line, c);
}

override bool onKeyDown(const ref KeyEvent e) {
    immutable bool shift = e.shift();
    immutable bool alt = hasModifier(e.modifiers, KeyModifiers.alt);
    if (e.keyCode == KeyCode.escape || (e.keyCode == KeyCode.tab && shift)) {
        return false;
    }
    if (hasModifier(e.modifiers, KeyModifiers.command)) {
        return onCommandKey(e.keyCode, shift);
    }
    switch (e.keyCode) {
    case KeyCode.returnKey:
    case KeyCode.keypadEnter:
        insertText("\n");
        break;
    case KeyCode.tab:
        insertText("\t");
        break;
    case KeyCode.deleteBackward:
        deleteBackward();
        break;
    case KeyCode.forwardDelete:
        deleteForward();
        break;
    case KeyCode.left:
        if (!shift && hasSelection()) {
            moveCaret(selStart(), false);
        } else {
            moveCaret(alt ? wordLeft(caret_) : charLeft(caret_), shift);
        }
        break;
    case KeyCode.right:
        if (!shift && hasSelection()) {
            moveCaret(selEnd(), false);
        } else {
            moveCaret(alt ? wordRight(caret_) : charRight(caret_), shift);
        }
        break;
    case KeyCode.up:
        moveVertical(-1, shift);
        break;
    case KeyCode.down:
        moveVertical(1, shift);
        break;
    case KeyCode.pageUp:
        moveVertical(-cast(ptrdiff_t) visibleLineCount(), shift);
        break;
    case KeyCode.pageDown:
        moveVertical(cast(ptrdiff_t) visibleLineCount(), shift);
        break;
    case KeyCode.home:
        moveCaret(TextPos(caret_.line, 0), shift);
        break;
    case KeyCode.end:
        moveCaret(TextPos(caret_.line, lines_[caret_.line].length), shift);
        break;
    default:
        break;
    }
    return true;
}
```
4. Typing and deleting. This covers IME: committed text arrives one code point at a time through `onTextInput`. `deleteForward()` is `deleteBackward()` with `charRight`.
```d
void insertText(string s) {
    deleteSelectionRaw();
    dchar[][] ins = splitLines(s);
    dchar[] tail = lines_[caret_.line][caret_.col .. $].dup;
    dchar[] head = lines_[caret_.line][0 .. caret_.col].dup;
    if (ins.length == 1) {
        lines_[caret_.line] = head ~ ins[0] ~ tail;
        caret_.col = head.length + ins[0].length;
    } else {
        immutable size_t lastLen = ins[$ - 1].length;
        ins[0] = head ~ ins[0];
        ins[$ - 1] = ins[$ - 1] ~ tail;
        lines_ = lines_[0 .. caret_.line] ~ ins ~ lines_[caret_.line + 1 .. $];
        caret_ = TextPos(caret_.line + ins.length - 1, lastLen);
    }
    textChanged();
}

override bool onTextInput(dchar c) {
    if (c < 0x20 || c == 0x7F || (c >= 0xF700 && c <= 0xF8FF)) {
        return true;
    }
    deleteSelectionRaw();
    dchar[] ln = lines_[caret_.line];
    lines_[caret_.line] = ln[0 .. caret_.col] ~ c ~ ln[caret_.col .. $];
    caret_.col++;
    textChanged();
    return true;
}

private bool deleteSelectionRaw() {
    if (!hasSelection()) {
        return false;
    }
    immutable TextPos a = selStart();
    immutable TextPos b = selEnd();
    dchar[] joined = lines_[a.line][0 .. a.col] ~ lines_[b.line][b.col .. $];
    lines_ = lines_[0 .. a.line] ~ joined ~ lines_[b.line + 1 .. $];
    caret_ = a;
    anchor_ = a;
    return true;
}

private void deleteBackward() {
    if (!hasSelection()) {
        immutable TextPos p = charLeft(caret_);
        if (p == caret_) {
            return;
        }
        anchor_ = p;
    }
    deleteSelectionRaw();
    textChanged();
}

private void textChanged() {
    anchor_ = caret_;
    wantCol_ = caret_.col;
    markedLine_ = NO_MARK;
    scrollTo(scrollY_);
    ensureCaretVisible();
    invalidate();
    if (onChange !is null) {
        onChange();
    }
}
```
5. Selection and clipboard.
```d
void selectAll() {
    anchor_ = TextPos(0, 0);
    caret_ = TextPos(lines_.length - 1, lines_[$ - 1].length);
    wantCol_ = caret_.col;
    ensureCaretVisible();
    invalidate();
}

string selectedText() const {
    immutable TextPos a = selStart();
    immutable TextPos b = selEnd();
    if (a.line == b.line) {
        return toUTF8(lines_[a.line][a.col .. b.col]);
    }
    string s = toUTF8(lines_[a.line][a.col .. $]);
    foreach (i; a.line + 1 .. b.line) {
        s ~= '\n';
        s ~= toUTF8(lines_[i]);
    }
    s ~= '\n';
    s ~= toUTF8(lines_[b.line][0 .. b.col]);
    return s;
}

private bool onCommandKey(uint code, bool shift) {
    switch (code) {
    case KeyCode.a:
        selectAll();
        return true;
    case KeyCode.c:
    case KeyCode.x:
        if (hasSelection() && clipboardWrite !is null) {
            clipboardWrite(selectedText());
            if (code == KeyCode.x) {
                deleteSelectionRaw();
                textChanged();
            }
        }
        return true;
    case KeyCode.v:
        if (clipboardRead !is null) {
            immutable string s = clipboardRead();
            if (s.length > 0) {
                insertText(s);
            }
        }
        return true;
    case KeyCode.returnKey:
    case KeyCode.keypadEnter:
        if (onSubmit !is null) {
            onSubmit();
        }
        return true;
    case KeyCode.left:
        moveCaret(TextPos(caret_.line, 0), shift);
        return true;
    case KeyCode.right:
        moveCaret(TextPos(caret_.line, lines_[caret_.line].length), shift);
        return true;
    case KeyCode.up:
    case KeyCode.home:
        moveCaret(TextPos(0, 0), shift);
        return true;
    case KeyCode.down:
    case KeyCode.end:
        moveCaret(TextPos(lines_.length - 1, lines_[$ - 1].length), shift);
        return true;
    default:
        return false;
    }
}
```
6. Mouse.
```d
override bool onMouseMove(const ref MouseEvent e) {
    if (!dragging_) {
        return false;
    }
    moveCaret(posAt(e.pos), true);
    return true;
}

override bool onMouseUp(const ref MouseEvent e) {
    dragging_ = false;
    return true;
}

override void onCaptureLost() {
    dragging_ = false;
}

override bool onMouseDown(const ref MouseEvent e) {
    if (e.button != MouseButton.left) {
        return false;
    }
    immutable TextPos p = posAt(e.pos);
    if (e.clickCount >= 2) {
        selectWordAt(p);
    } else {
        moveCaret(p, e.shift());
        dragging_ = true;
    }
    return true;
}

private TextPos posAt(Point2F p) {
    auto ctx = context();
    ITextMeasurer m = ctx is null ? null : ctx.measurer();
    immutable StudioTheme theme = ctx is null ? StudioTheme.init : ctx.theme;
    immutable TextAreaMetrics k = metricsFor(m, theme);
    immutable float rel = p.y - k.textTop + scrollY_;
    size_t line = rel > 0.0f && k.lineH > 0.0f ? cast(size_t)(rel / k.lineH) : 0;
    if (line >= lines_.length) {
        line = lines_.length - 1;
    }
    const(dchar)[] ln = lines_[line];
    float prev = 0.0f;
    foreach (c; 0 .. ln.length) {
        immutable float next = measureTextOr(m, toUTF8(ln[0 .. c + 1]), FontId.mono, theme.fontSizeMono);
        if (p.x < k.textX + (prev + next) * 0.5f) {
            return TextPos(line, c);
        }
        prev = next;
    }
    return TextPos(line, ln.length);
}

private void selectWordAt(TextPos p) {
    const(dchar)[] ln = lines_[p.line];
    if (ln.length == 0) {
        moveCaret(p, false);
        return;
    }
    immutable size_t i = p.col < ln.length ? p.col : ln.length - 1;
    size_t s = i;
    size_t e = i + 1;
    if (isWordChar(ln[i])) {
        while (s > 0 && isWordChar(ln[s - 1])) {
            s--;
        }
        while (e < ln.length && isWordChar(ln[e])) {
            e++;
        }
    }
    anchor_ = TextPos(p.line, s);
    caret_ = TextPos(p.line, e);
    wantCol_ = e;
    invalidate();
}
```
7. Drawing and the marked line. `clearMark()` stores `NO_MARK` the same way.
```d
void markLine(size_t line) {
    markedLine_ = line < lines_.length ? line : NO_MARK;
    invalidate();
}

override void paint(IRenderer2D r, const ref StudioTheme theme) {
    immutable TextAreaMetrics k = metricsFor(r, theme);
    immutable float size = theme.fontSizeMono;
    r.fillRoundedRect(bounds, theme.radiusSm, theme.panelRaised);
    r.pushClip(bounds.inset(theme.borderWidth));
    r.fillRect(RectF(bounds.x, bounds.y, k.gutterW, bounds.h), theme.panelSunken);
    r.fillRect(RectF(bounds.x + k.gutterW - theme.borderWidth, bounds.y, theme.borderWidth, bounds.h), theme.border);
    immutable size_t first = k.lineH > 0.0f ? cast(size_t)(scrollY_ / k.lineH) : 0;
    immutable TextPos a = selStart();
    immutable TextPos b = selEnd();
    foreach (i; first .. lines_.length) {
        immutable float y = k.textTop + cast(float) i * k.lineH - scrollY_;
        if (y > bounds.bottom()) {
            break;
        }
        if (hasSelection() && i >= a.line && i <= b.line) {
            immutable size_t c0 = i == a.line ? a.col : 0;
            immutable size_t c1 = i == b.line ? b.col : lines_[i].length;
            immutable float x0 = k.textX + r.measureText(toUTF8(lines_[i][0 .. c0]), FontId.mono, size);
            float x1 = k.textX + r.measureText(toUTF8(lines_[i][0 .. c1]), FontId.mono, size);
            if (i < b.line) {
                x1 += r.measureText("0", FontId.mono, size);
            }
            r.fillRect(RectF(x0, y, x1 - x0, k.lineH), theme.selection);
        }
        immutable string num = to!string(i + 1);
        immutable float nw = r.measureText(num, FontId.mono, size);
        r.drawText(Point2F(bounds.x + k.gutterW - k.pad - nw, y), num, FontId.mono, size, theme.textDim);
        r.drawText(Point2F(k.textX, y), toUTF8(lines_[i]), FontId.mono, size, theme.text);
        if (i == markedLine_) {
            r.strokeRoundedRect(RectF(bounds.x, y, bounds.w, k.lineH).inset(theme.borderWidth), 0.0f,
                2.0f * theme.borderWidth, theme.danger);
        }
        if (i == caret_.line && isFocused()) {
            immutable float cx = k.textX + r.measureText(toUTF8(lines_[i][0 .. caret_.col]), FontId.mono, size);
            r.fillRect(RectF(cx, y, 1.5f, k.lineH), theme.accentHot);
        }
    }
    immutable float content = cast(float) lines_.length * k.lineH;
    if (content > k.viewH && k.viewH > 0.0f) {
        ScrollBarModel bar;
        bar.axis = Axis.vertical;
        bar.track = RectF(bounds.right() - theme.scrollbarThickness, bounds.y, theme.scrollbarThickness, bounds.h);
        bar.contentLength = content;
        bar.viewportLength = k.viewH;
        bar.offset = scrollY_;
        bar.minThumb = theme.scrollbarMinThumb;
        r.fillRect(bar.track, theme.scrollTrack);
        r.fillRoundedRect(bar.thumbRect(), theme.radiusSm, theme.scrollThumb);
    }
    r.popClip();
    if (isFocused()) {
        r.strokeRoundedRect(bounds, theme.radiusSm, theme.focusRingWidth, theme.focusRing);
    } else {
        r.strokeRoundedRect(bounds, theme.radiusSm, theme.borderWidth, theme.border);
    }
}
```
8. Gallery. In `source/app/gui_gallery.d` add `TextArea` to the `gui.widgets` import (38), add `private string clipText_;` after `status_` (137), and insert this block before line 193. The file compiles only in the `app` configuration. Check with `dub build --compiler=ldc2 --config=app --build=debug 2>&1 | tail -5`.
```d
controls.add(new Label("Text area"));
TextArea area = controls.add(new TextArea("tempo 120\nplay C-4\n  wait 4"));
area.preferredSize = Point2F(240, 110);
area.markLine(1);
area.clipboardRead = () => clipText_;
area.clipboardWrite = (string s) { clipText_ = s; return true; };
area.onChange = () { setStatus(format("text area: %s lines", area.lineCount())); };
area.onSubmit = () { setStatus("text area: submit"); };
```
9. Update both file headers (`widgets.d` Controls list at 18 to 21, Planned API, External; the gallery's Purpose). Run all gates. Write the changelog.

**Acceptance table.** Every row uses this rig:
```d
auto root = new Panel();
auto h = new Harness(root, RectF(0, 0, 400, 300));
auto ta = root.add(new TextArea(""));
ta.bounds = RectF(10, 10, 300, 83);
h.ctx.setFocus(ta);
```
The fake font is 0.5 em wide and 1.25 em high (`gui_test.d` 69, 93). `fontSizeMono` is 12, `spacingSm` 4, `borderWidth` 1 (`theme.d` 211, 195, 204). So a character is 6 wide and a line 15 high. Caret is (line, column) from 0. A quoted text as input means `setText`.

| Input | Working | Expected |
| --- | --- | --- |
| the rig | gutter 2·6 + 2·4; (83 − 8) / 15 | `gutterWidth()` 20, `visibleLineCount()` 5, `lineRect(0)` (10, 14, 300, 15) |
| type `ab`, Return, type `cd`; then Home, Backspace | split at column 2; join at old length 2 | `"ab\ncd"` (1, 2); then `"abcd"` (0, 2) |
| `"ab\ncd"`, `setCaret(0, 2)`, Delete | line 1 pulled up | `"abcd"` (0, 2) |
| `""`, Backspace | refusal: nothing to delete | unchanged, no `onChange` |
| `"é가x"`, `setCaret(0, 3)`, Left, Backspace, type `가` | "가" goes whole, then returns; bytes 2 + 3 + 1 | `"éx"` (0, 1), then `"é가x"` (0, 2), `text().length` 6 |
| `"one\ntwo\nthree"`, `setCaret(0, 1)`, Shift+Down, Shift+Right, type `X` | selection `"ne\ntw"` | `"oXo\nthree"` (0, 2) |
| `"ab"`, `setCaret(0, 1)`, clipboard `"1\r\n2\t3\n"`, Cmd+V | CRLF is one break; tab is 4 spaces | `"a1\n2    3\nb"` (2, 0) |
| `"hello world"`, Shift+Right twice, Cmd+C, Cmd+X | columns 0 to 2 | clipboard `"he"`; `"llo world"` (0, 0) |
| `"foo bar_baz  qux"`, Option+Right ×3, Option+Left ×2 | `_` is a word character | columns 3, 11, 16, then 13, 4 |
| `"abcdef\nab\nabcd"`, `setCaret(0, 5)`, Down ×3, Up ×3 | lengths 2 and 4; Up on line 0 gives column 0 | (1, 2), (2, 4), (2, 4), then (0, 0) |
| then End, Shift+Home, Tab | `TAB_SPACES` = 4 | `"    \nab\nabcd"` (0, 4) |
| 20 lines `L`, Page Down ×2, `h.scroll(50, 50, 0, -10000)` | 6·15 − 75; 11·15 − 75; 20·15 − 75 | (5, 0) scroll 15; (10, 0) scroll 90; scroll 225 |
| 100 lines | 3·6 + 8 | `gutterWidth()` 26 |
| `"hello world\nsecond"`, `h.click(53, 31)` | text x 10 + 20 + 4; (53 − 34) / 6 = 3.17; (31 − 14) / 15 = 1 | (1, 3) |
| `h.doubleClick(77, 16)` | (77 − 34) / 6 = 7.17 | `selectedText()` `"world"`, (0, 11) |
| `h.drag(40, 16, 46, 31)` | (0, 1) to (1, 2) | `selectedText()` `"ello world\nse"` |
| `markLine(1)`, `h.ctx.renderFrame(h.renderer, 1.0f)` | row (10, 29, 300, 15) inset 1 | shape rect [11, 30, 298, 13], `borderWidth` 2, border color `danger` |
| `markLine(5)` on 2 lines; an edit after `markLine(1)` | refusal; edits clear | `markedLine() == TextArea.NO_MARK` |
| `h.ctx.setTheme(t.scaled(2.0f))` | line 30; 2·12 + 16; (83 − 16) / 30 | `lineRect(0).h` 30, `gutterWidth()` 40, `visibleLineCount()` 2 |
| Escape, Shift+Tab, Cmd+S (code 1) to `ta.onKeyDown` | refusal: not editor keys | `false` each |

Every row was run on a prototype of this code with the real `Harness`.

**Tests.** `tests/unit/widgets_textarea_test.d` does not exist; create it. Copy the header shape of `tests/unit/gui_test.d` (1 to 33) and start as below. `dub` finds the file itself. Imitate the `TextField` test at `gui_test.d` 2336 (`h.type("ab"d)`, `h.key(KeyCode.left, KeyModifiers.shift)`). Then write one block per step:
```d
module tests.unit.widgets_textarea_test;

version (unittest) {
    import gui.layout;
    import gui.renderer;
    import gui.theme;
    import gui.widgets;
    import platform.interfaces : KeyModifiers;
    import tests.unit.gui_test : countKind, Harness, near, nearRect;

    unittest {
        auto root = new Panel();
        auto h = new Harness(root, RectF(0, 0, 400, 300));
        auto ta = root.add(new TextArea(""));
        ta.bounds = RectF(10, 10, 300, 83);
        string clip;
        ta.clipboardRead = () => clip;
        ta.clipboardWrite = (string s) { clip = s; return true; };
        h.ctx.setFocus(ta);
        h.type("ab"d);
        assert(ta.text() == "ab" && ta.caretLine() == 0 && ta.caretColumn() == 2);
    }
}
```
1. free functions, storage round trip, clamping;
2. metrics, scrolling, `scaled`, `measure` without `preferredSize` (268 by 128);
3. caret keys, word jumps, page keys;
4. typing, deleting, the filter (`h.type("\r\t"d)` changes nothing), `onChange` counts;
5. selection, clipboard (also null delegates), unconsumed keys, `onSubmit`;
6. mouse;
7. drawing: marked-line stroke, selection fill, caret only with focus.

**Pitfalls.**
- `gui.widgets` must not import `gui.views.studio_context` (`IStudioClipboard`). So the hooks are delegates.
- `size_t` cannot go below 0. Test `col > 0` before subtracting.
- `moveCaret` sets `wantCol_`; `moveVertical` restores it afterwards. Keep that order.
- `Harness.key` returns `true` for Shift+Tab because the context moves focus. Call `ta.onKeyDown(ke)` with a local `KeyEvent ke`.
- A click outside `ta.bounds` removes focus. Call `h.ctx.setFocus(ta)` before a drawing test.
- No `//` anywhere, also in the test file.

**Do not.**
- Do not change `TextField`, `UiContext`, other widgets, the theme, `source/platform/`, `gui_shell.d` or the views (the script tab is T112).
- Do not write a color literal.
- Do not add undo, wrapping, horizontal scrolling or auto-indent.

**Done when.**
- `TextArea` is in `widgets.d`; `KeyCode` has `x`, `c`, `v`.
- `widgets_textarea_test.d` asserts every table row; the headless suite prints one module more.
- Gate 2 prints only `exit 0`; Gate 3 prints nothing for the three files.
- The `app` build succeeds; the gallery shows line 2 outlined.

**Decided by the owner (2026-11-26).**
1. Two clipboard delegates on `TextArea` (T112 connects them to the app clipboard) and a new test file that imports `Harness` from `gui_test.d`, as written above. The task text was corrected to say so.
2. Only committed IME text is accepted, as `TextField` does.
3. Columns are code points. The script interpreter reports byte columns; T112 converts them. Nothing to do here.
4. Any edit clears the marked line; Tab is 4 spaces; Cmd+Z and Cmd+S pass through to the application; the editor has no undo of its own, no word wrap and no horizontal scrolling.

---

## Open tasks without a guide

T115 (Stage 0), T77 (Stage 1), T83 (Stage 1), T96 (Stage 1), T86 (Stage 2), T79 (Stage 2), T82 (Stage 2), T85 (Stage 2), T97 (Stage 2), T98 (Stage 2), T101 (Stage 2), T102 (Stage 2), T112 (Stage 2), T78 (Stage 3), T80 (Stage 3), T81 (Stage 3), T100 (Stage 3), T103 (Stage 3), T104 (Stage 3), T87 (Stage 4), T99 (Stage 4), T106 (Stage 4), T105 (Stage 5), T107 (Stage 6), T113 (Stage 6), T88 (Stage 7), T114 (Stage 7), T89 (Stage 8).

A guide is written when the tasks it needs are built, so that it can name real functions.
