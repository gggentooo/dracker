# Dracker Tasks

## Document Maintaining Guide

This guide applies to all contributors (human and AI) editing this file.

### Rules

1. **Direct edits.** Edits are made directly on the document. Existing content may be modified, reordered, or removed as needed.
2. **Changelog at bottom.** A 'Changelog' section must always exist at the bottom of the document. All changes made with each update are appended to the bottom of the changelog with a summary and timestamp. The [Author] field must be filled in with the username in the case of human contributors, and the model name in the case that an agent makes the update. This changelog covers this file only; code changes are logged in `docs/changelog.md` (`agents.md` Rule 4).
3. **Concise language.** Write in brief, clear English. Avoid unnecessary verbosity.
4. **Changelog format.** Each changelog entry must begin with a datetime stamp in ISO 8601 format (e.g., `2026-11-25T14:30:00+09:00`), followed by a bulleted list of what was added, modified, or removed.
5. **Task format.** Each task is an H4 heading that begins with an area tag, then the title, the task id, and its type: `#### [Area] Title · T00 · Decision|Build`. Below it: **Files** (all relevant source files), **Task** (brief description), and **Needs** (ids of tasks that must be finished first, or `—`).
   - **Area tags** name the project part, following the package map in `agents.md`: e.g. `[App]`, `[GUI/widgets]`, `[GUI/views]`, `[IO]`, `[Sequencer]`, `[Platform]`, `[Tests]`, `[Docs]`, `[Project]`.
   - **Decision** tasks are made by the owner (`agents.md` Rule 5). Agents may suggest a default marked **(proposed)** but must not decide.
   - **Build** tasks are implementation work. They follow `agents.md` (comment policy, unit tests for every component, zero warnings, `docs/changelog.md` entry).
6. **Ordered by dependency.** Tasks are grouped into stages. *Stage 0* tasks can start now. A task's stage is one higher than the highest stage among its *Needs*, so every task appears below everything it depends on. When a task is added or its *Needs* change, move it to the right stage.
7. **Stable ids.** Ids are never reused or renumbered. New tasks take the next free id.
8. **Done.** A finished task moves to *Done* (above the changelog) with its completion date and where its outcome is recorded (decisions go in `docs/manual.md` or `../architecture.md`). Tasks that listed it under *Needs* move up a stage if possible.
9. **New open questions** found during work become tasks here.

### Format template

```md
#### [Area] Title · T00 · Build

- **Files:** `path/a.d`, `path/b.d`
- **Task:** What needs to be done.
- **Needs:** T00, T00

## Changelog

### YYYY-MM-DDTHH:MM:SS+09:00 — [Author], [Brief title]

- Added: ...
- Modified: ...
- Removed: ...
```

---

## Feature: Skeleton project generator

A File menu item opens a panel where the user sets the project defaults (title, BPM, ticks per line, time signature), the key of the song, and a chord progression (typed, or inserted as blocks from presets). *Create* replaces the open project with a new one. If a progression was given, the project gets a bass and a piano module, each with a pattern that follows the chords: the bass plays each chord's root, the piano plays all notes of the chord.

Decided by the owner on 2026-11-25:

- **Panel, not an OS window.** The generator opens as an in-app overlay panel, like the Appearance panel. Dracker stays a single-window app.
- **The panel is modal.** A click outside it does not close it and nothing behind it reacts; only *Create*, *Cancel*, or Escape close it (T20).
- **Time signature is a project setting.** It is saved in the project file and drives beat and bar highlighting in the pattern editor, the timeline, and the count-in.
- **Chord input accepts both forms.** Roman numerals relative to the key (`ii`, `V7`) and chord names (`Dm7`, `G7`) in the same field.
- **Confirm before replacing.** If the open project has unsaved changes, the generator asks before discarding them.
- **Proposals accepted.** All proposals of T01–T08 were approved as written (see *Done*). The feature is not built yet, so these decisions are recorded in the *Done* entries below; T26 moves them into `docs/manual.md` and `../architecture.md`.

Facts about the current code that the tasks rely on:

- The File menu is native (`source/platform/macos/appkit.d` → `MENU_ITEMS`). A menu click is sent as a key press, so every item needs its own key binding and a `StudioAction` value.
- The project file stores the time signature and key (T12) and the session exposes them (`linesPerBeat()`, `linesPerBar()`, `songKey()`, undoable `doSetTimeSignature()` / `doSetKey()`; T15). The count-in (one bar, at least 2 beats; T29), the pattern editor's row shading and the timeline's grid, ruler and snapping (T17) follow the time signature, which the transport bar's **SIG** control sets (T18).
- A pattern track plays one note at a time, so a chord needs one track per note. A cell names its module (`NoteCell.moduleId`); a track with no module set is silent.
- `doAddModule` does not wire the module; wires are added separately. No presets ship with the app (`resources/` holds only fonts).
- Available building blocks: `StudioSession.openProjectFromMemory()` (T10); `openConfirmDialog()` and modal overlays (`Widget.isModalOverlay()`, T09); `StudioRoot.confirmDiscardThen()` (T27); `app.music_theory` (T11); `app.skeleton_gen` instrument choices, `resolveInstrument()`, `audioOutputPort()` (T13); `app.chord_progression` (`parseProgression()`, `resolveChord()`, `chordLabel()`, `chordIntervals()`, `ChordBlock.halfBars`; T14; presets `PROGRESSION_PRESETS`, `presetsFor()`, `presetBlocks()`, `presetLabel()`; T16).

---

## Stage 0 — Ready now

#### [App] Skeleton generator: settings to project · T19 · Build

- **Files:** `source/app/skeleton_gen.d`, `tests/unit/skeleton_gen_test.d`, `source/app/studio_selftest.d` (`buildSong`, for reference)
- **Task:** `SkeletonSpec` (title, BPM, ticks per line, time signature, key, blocks, bass choice, piano choice) and `validateSpec` (tempo limits as `isValidTempo`, `isValidTimeSignature`, total length ≤ `MAX_LINES`). `generateSkeleton(spec)` returns a `LoadedProject`; it does not touch the session or the GUI.
  - Always: Master Output, title, tempo, time signature, key.
  - No blocks: one empty 4-bar pattern with one clip.
  - With blocks: bass and piano modules from `resolveInstrument()`, each wired from `audioOutputPort()` to the Master Output; patterns, clips, and loop per T05. The first note on each track carries the module id.
  - Tests: cell-by-cell check for a known progression in a major and a minor key, in 4/4 and 3/4; mixed block lengths; slash chord; `StudioSession.openProjectFromMemory()` accepts the result; an offline render has sound from both modules.
- **Needs:** T05, T13, T14, T15


---

## Stage 1

#### [GUI/views] Generator panel: frame and project settings · T20 · Build

- **Files:** `source/gui/views/skeleton_panel.d` (new), `source/gui/views/studio_root.d`, `source/gui/views/appearance_panel.d` (model), `source/app/music_theory.d` (`tonicChoices()`), `tests/unit/views_skeleton_panel_test.d` (new)
- **Task:** `SkeletonPanel`, a **modal** overlay (`isModalOverlay()` returns true) opened and centred by `StudioRoot.openSkeletonPanel()`.
  - Modal (owner decision 2026-11-25): a click outside the panel does nothing and does not close it; hover, clicks, scrolling and keys never reach the views behind it, so shortcuts and piano keys do not fire. Its own dropdown lists and the unsaved-changes question (T24) open above it. Only *Create*, *Cancel*, or Escape close it. Since the panel takes every key, ⌘-menu shortcuts are not forwarded while it is open (unlike the Appearance panel).
  - Fields: title (text), BPM and ticks per line (numeric boxes), time signature (numeric box + dropdown), key (tonic dropdown from `tonicChoices()` and mode dropdown).
  - The panel holds a `SkeletonSpec`; invalid values disable *Create* and show the reason. Opening it again shows the last values of this run of the app. The body scrolls if the window is too small.
  - Tests: an outside click leaves it open and changes nothing behind it; Escape and *Cancel* close it; keys do not reach the root.
- **Needs:** T19


---

## Stage 2

#### [GUI/views] Generator panel: chord progression · T21 · Build

- **Files:** `source/gui/views/skeleton_panel.d`, `source/gui/widgets.d`, `tests/unit/views_skeleton_panel_test.d`
- **Task:** The progression section.
  - Text field: typed chords are parsed (T14) on Return and appended as blocks; a parse error is shown under the field and nothing is added.
  - Preset dropdown (presets of the chosen mode) and *Insert*: the preset's chords are added as blocks after the selected block, or at the end.
  - Block row: each block shows the chord in both forms (e.g. "ii · Dm") and its length (½, 1, 2, or 4 bars). A block can be selected, removed, moved left or right, and given a length; *Clear* removes all. No drag-and-drop (the toolkit has none); move buttons and arrow keys instead. The row scrolls when it overflows.
  - Changing the key keeps Roman-numeral blocks and updates their chord names; blocks typed as chord names keep their names.
  - Total length in bars and lines is shown.
- **Needs:** T16, T20


#### [GUI/views] Generator panel: bass and piano module choice · T22 · Build

- **Files:** `source/gui/views/skeleton_panel.d`, `source/gui/views/studio_context.d`, `tests/unit/views_skeleton_panel_test.d`
- **Task:** A section with one dropdown per instrument (`instrumentChoices()` labels plus *Load preset file…*), enabled only when the progression has at least one block. *Load preset file…* opens the file dialog (`ctx.dialogs`) for a `.msym` file and adds an `InstrumentChoice.ofPreset()` entry showing the preset's name; a file that fails to load, or whose module cannot play notes (`isPlayableInstrument()`), shows the error and keeps the earlier choice. Tests use a fake dialog.
- **Needs:** T13, T20


#### [Platform, App] File menu item and action · T23 · Build

- **Files:** `source/platform/macos/appkit.d` (`MENU_ITEMS`), `source/app/keymap.d` (`StudioAction`, `isDocumentLevel`, `createDefault`), `source/gui/views/studio_root.d` (`executeAction`), `source/app/gui_shell.d` (menu checks), `tests/unit/keymap_test.d` (`APPKIT_MENU_TABLE`), `tests/unit/views_studio_root_test.d`
- **Task:** Add "New Project from Skeleton…" directly below "New Project" with shortcut ⇧⌘N (T07), a new `StudioAction`, and its default key binding. The action opens the generator panel; if it is already open, nothing happens. Tests: the menu table and the keymap agree; the action opens the panel.
- **Needs:** T07, T20


---

## Stage 3

#### [GUI/views, App] Create: confirm, generate, and open the new project · T24 · Build

- **Files:** `source/gui/views/skeleton_panel.d`, `source/gui/views/studio_root.d`, `source/gui/views/studio_context.d`, `tests/unit/views_skeleton_panel_test.d`
- **Task:** *Create* validates the spec, then calls `StudioRoot.confirmDiscardThen("Creating a new project discards them.", …)`, which asks only when the open project has unsaved changes. On confirm: generate the project (T19), open it with `StudioSession.openProjectFromMemory()`, close the panel, select the piano pattern in the pattern editor, and set the status ("Created project …"). Cancel keeps the old project and the panel with its values. A failure leaves the old project open and shows the error in the panel. Tests: no question when clean; cancel keeps the old project and the panel; confirm replaces it; no progression gives a project without bass and piano.
- **Needs:** T08, T09, T10, T21, T22, T27


---

## Stage 4

#### [Tests] End-to-end check of the generator · T25 · Build

- **Files:** `tests/unit/views_studio_root_test.d`, `source/app/studio_app.d` (`--studio-gui-selftest`), `tests/golden/golden_suite.d`
- **Task:** Headless: trigger the menu action, set values, insert the circle-of-fifths preset, create, then check modules, wires, patterns, clips, time signature, and key; save and reopen the project and compare. Offline render of the result is not silent. Add one step to the GUI self-test that opens and closes the panel. Check by hand in the app: 4/4 and 3/4, a major and a minor key, default sounds.
- **Needs:** T23, T24


#### [Docs] Manual, changelog, and agent guide · T26 · Build

- **Files:** `docs/manual.md` (File menu table §3, new section for the generator, shortcut table in Appendix A, QA notes in Appendix C), `docs/changelog.md`, `agents.md` (package map), `../architecture.md`
- **Task:** Describe the generator, the chord syntax, the presets, and the time signature and key settings in the manual. Move the decisions of T01–T08 (now kept in *Done* below) into the manual and `../architecture.md`. Update the package map with the remaining new file (`skeleton_panel.d`; `music_theory.d`, `skeleton_gen.d` and `chord_progression.d` are listed already) and note the MUSC project-file chunk in the architecture document. Each build task above adds its own `docs/changelog.md` entry; this task checks that none is missing.
- **Needs:** T23, T24


---

## Done

#### [App] Count-in length in other time signatures · T29 · Decision

- **Files:** `source/app/session.d` (`countInBeats()`, `MIN_COUNT_IN_BEATS`, `beginLiveTake`), `source/gui/views/studio_context.d` (count-in status), `tests/unit/studio_backend_test.d`, `docs/manual.md` (§8.11 *Count-in*)
- **Done:** 2026-11-25 (owner accepted the proposal and asked for it to be built). The count-in lasts one bar (numerator beats) but at least `MIN_COUNT_IN_BEATS` = 2 beats: 4/4 unchanged (4 beats, 16 lines), 3/4 3 beats, 6/8 6 beats (12 lines), 7/8 7, 2/2 and 1/4 2 beats. `StudioSession.countInBeats()` replaces `COUNT_IN_BEATS`; the first status message ("Count-in N") uses it. Tested by the count-in start line in six time signatures. Recorded in `docs/manual.md` §8.11 and `docs/changelog.md` (2026-11-25 18:30:00 KST).
- **Needs:** —

#### [GUI/views] Time signature control in the transport bar · T18 · Build

- **Files:** `source/gui/views/transport_bar.d`, `tests/unit/views_transport_test.d`, `docs/manual.md` (§5, §13.1)
- **Done:** 2026-11-25. **SIG** after TPL: a numerator drag box (`transport.sigNum`, 1–16, 8 points per step, double-click to type; one "Change Time Signature" undo step per drag) and a denominator dropdown after a "/" caption (`transport.sigDen`: 2, 4, 8, 16; one undo step per choice). Both go through `doSetTimeSignature()` and follow undo/redo and other changes. The Rec button's count-in blink now follows the beat length (it assumed 4 lines). The controls take 122 more points, so in narrow windows the controls at the right end (device picker, meters) are hidden sooner. Tests: ids and order, drags and clamping, dropdown choices, undo, outside changes, typed entry. Recorded in `docs/manual.md` §5 and §13.1 and `docs/changelog.md` (2026-11-25 18:30:00 KST).
- **Needs:** T01, T15

#### [GUI/views] Beat and bar highlighting follows the time signature · T17 · Build

- **Files:** `source/gui/views/pattern_editor.d`, `source/gui/views/timeline_view.d`, `tests/unit/views_pattern_editor_test.d`, `tests/unit/views_timeline_test.d`, `docs/manual.md` (§8, §9.3)
- **Done:** 2026-11-25. Pattern editor: the `beatLines` / `barLines` fields became methods reading `StudioSession.linesPerBeat()` / `linesPerBar()`; row shading, bar rules and bold line numbers follow them. Timeline: the `linesPerBeat` / `linesPerBar` constants became methods reading the session; `gridFor()` (snapping: beat, Shift = line, Cmd = bar) is now an instance method; grid lines and ruler ticks use the session's values; ruler labels (`majorStep()`, now public) step through power-of-two divisions of a beat, beat multiples that divide a bar, then bars and their doublings, so labels land on beats or bars (4/4 unchanged: 1, 2, 4, 8, 16, …). Tests in 4/4, 3/4 and 6/8 (drawn shading and grid lines, snap grids, label steps for six time signatures and seven zooms, undo). Recorded in `docs/manual.md` §8 and §9.3 and `docs/changelog.md` (2026-11-25 18:30:00 KST).
- **Needs:** T15

#### [App] Preset progressions · T16 · Build

- **Files:** `source/app/chord_progression.d`, `tests/unit/chord_progression_test.d`
- **Done:** 2026-11-25. `ProgressionPreset` (name, mode, progression text), `PROGRESSION_PRESETS` (the 11 presets of T04, as Roman-numeral text), `presetsFor(mode)`, `presetBlocks()` (one bar each), `presetLabel()` ("Circle of fifths: iii - vi - ii - V - I"). Names not given in T04 are mine: "Pop" (I–V–vi–IV), "Fifties" (I–vi–IV–V), "Pop (minor start)" (vi–IV–I–V), "Three chords" (I–IV–V), "Jazz ii-V-I", "Minor pop" (i–VI–III–VII), "Minor three chords" (i–iv–v); rename freely. Tests: every preset parses and resolves in every key of its mode; chord names checked for seven presets (Andalusian in A minor: Am G F E, with a major E). Recorded in the `source/app/chord_progression.d` header and `docs/changelog.md` (2026-11-25 18:30:00 KST).
- **Needs:** T04, T14

#### [App] Default bass and piano definitions and the module choice list · T13 · Build

- **Files:** `source/app/skeleton_gen.d`, `tests/unit/skeleton_gen_test.d`, `source/main.d` (`--sound-check`)
- **Done:** 2026-11-25 (owner listened to `build/default-sounds.wav` and approved the default sounds). Instrument choices, `resolveInstrument()`, the default bass (Analog Generator) and piano (FM Synth electric piano), and the `--sound-check` preview, as described in `docs/changelog.md` (2026-11-25 14:29:04 and 16:50:00 KST).
- **Needs:** T06

#### [Platform] Ask before quitting from the Dock; quit at once on logout · T28 · Build

- **Files:** `source/platform/macos/appkit.d`, `source/app/studio_app.d`, `docs/manual.md` (§13.8, Appendix C row 1)
- **Done:** 2026-11-25 (owner decision: logout quits without asking). New `STAppDelegate` (`NSApplicationDelegate`) answers `applicationShouldTerminate:`. If the quit Apple event's `kAEQuitReason` is logout, restart or shutdown (`logo`, `rlgo`, `rrst`, `rest`, `rsdn`, `shut`; `isSessionEndQuitReason()`), it calls `MacWindow.sessionEndHandler` and answers `NSTerminateNow`, so nothing is asked and unsaved changes are lost; the studio's handler cancels a running WAV export, waits for it to stop, and closes the audio host. Any other quit (Dock icon menu, Apple events) is answered `NSTerminateCancel` and delivered as `closeRequested`, so it asks like ⌘Q (T27). Restart and shutdown are treated like logout (my reading of the decision). Tested: the reason list and the delegate's answer without a window (`dub test --config=app`). **Not tested by hand:** a real Dock quit and a real logout. Recorded in `docs/manual.md` §13.8 and `docs/changelog.md` (2026-11-25 16:50:00 KST).
- **Needs:** —

#### [App] Time signature and key in the session · T15 · Build

- **Files:** `source/app/session.d`, `source/app/history.d`, `source/gui/views/studio_context.d`, `tests/unit/studio_backend_test.d`
- **Done:** 2026-11-25. `timeSignatureNumerator()`, `timeSignatureDenominator()`, `linesPerBeat()` (16 ÷ denominator), `linesPerBar()`, `songKey()` (`MusicalKey`). Undoable `doSetTimeSignature()` ("Change Time Signature") and `doSetKey()` ("Change Key"); invalid values are refused, setting the current value adds no undo step. `StudioSession.LINES_PER_BEAT` is removed: the count-in plays `COUNT_IN_BEATS` (4) beats of the project's beat and the count-in status divides by it. Count-in length in bars is open: T29. Tests: defaults, seven time signatures, undo/redo, invalid values, keys, save/load, New Project, count-in start line in 4/4, 6/8 and 2/2. Recorded in `docs/manual.md` §8.11 and `docs/changelog.md` (2026-11-25 16:50:00 KST).
- **Needs:** T12

#### [App] Chord model and parser · T14 · Build

- **Files:** `source/app/chord_progression.d` (new), `tests/unit/chord_progression_test.d` (new), `tests/fuzz/chord_progression_fuzz.d` (new)
- **Done:** 2026-11-25. `ChordQuality` (the 11 qualities of T03), `ChordForm`, `Chord`, `ChordBlock` (`halfBars`, default 2 = one bar; `BLOCK_HALF_BARS` = 1, 2, 4, 8), `ProgressionError` (byte position, length, reason), `ResolvedChord`. `parseChord()`, `parseProgression()` (separators: spaces, commas, `-`, `->`), `chordIntervals()`, `resolveChord()`, `romanLabel()`, `nameLabel()`, `chordLabel()` ("ii · Dm"). Beyond T03, also accepted: `♭`/`♯` for `b`/`#`; `°`, `+`, `ø`, `m7♭5` aliases in chord names; half-diminished Roman numerals (`viiø7`, `viim7b5`) and `°7`/`dim7` (T03 listed only `7`, `maj7`, `dim`, `aug`, `sus2`, `sus4` as Roman suffixes). Case rules: diminished in upper case and major-family suffixes in lower case are refused with a hint. Labels: a named chord's root outside the scale gets a flattened numeral (Bb in C is `bVII`), else a sharpened one; Roman labels use `°` and `ø` (Latin-1; not checked in the app fonts). Tests: every quality in both forms in C major and A minor, all 24 keys × 7 degrees × 3 accidentals × every suffix, errors and positions, labels; 60,000-input fuzz. Recorded in the `source/app/chord_progression.d` header and `docs/changelog.md` (2026-11-25 16:50:00 KST).
- **Needs:** T03, T11

#### [App] Unsaved-changes confirmation for New Project, Open Project, and Quit · T27 · Build

- **Files:** `source/gui/views/studio_root.d`, `source/app/gui_shell.d`, `source/app/studio_app.d`, `tests/unit/views_studio_root_test.d`, `docs/manual.md` (§3, §13.8, Appendix C)
- **Done:** 2026-11-25 (owner request). New Project, Open Project (before the file dialog), Quit Dracker and the window close button ask "Discard unsaved changes?" with a modal `ConfirmDialog` when the project is modified; *Discard changes* goes ahead, *Cancel* keeps the project ("Kept the open project"). Reusable entry point `StudioRoot.confirmDiscardThen(message, proceed)`; one question at a time. The window close button and Dracker ▸ Quit reach it through `StudioRoot.requestClose()`: the studio sets the new `GuiShell.sceneHandlesClose`, so a close request no longer ends the loop by itself (the widget gallery keeps the old behaviour). Two buttons only (no *Save*). Quitting through `terminate:` (Dock, logout) still does not ask: T28. Tested headless only; the native close button and menu path were not clicked by hand. Recorded in `docs/manual.md` §13.8 and `docs/changelog.md` (2026-11-25 14:29:04 KST).
- **Needs:** T09

#### [IO] Time signature and key in the project file · T12 · Build

- **Files:** `source/io/project_format.d`, `source/app/session.d` (`cloneLoadedProject`), `tests/unit/persistence_test.d`, `tests/fuzz/project_format_fuzz.d`
- **Done:** 2026-11-25. `LoadedProject` gains `timeSigNumerator`, `timeSigDenominator`, `keyTonic` (pitch class) and `keyMode` (`KEY_MODE_MAJOR` = 0, `KEY_MODE_MINOR` = 1); defaults 4/4, C major. Optional chunk `MUSC` (4 bytes in that order) is written only when a value differs from the default; `MSV_FORMAT_VERSION` stays 1. Files without it load as 4/4, C major; extra bytes after the fourth are ignored (room for later fields); short or out-of-range chunks are refused. `isValidTimeSignature()` (numerator 1–16, denominator 2/4/8/16), `isValidKey()`, `hasNonDefaultMusicSettings()`; `validateProjectForSave()` refuses invalid values. The session keeps the fields through load, save and `openProjectFromMemory()`. Tests: round trips, chunk only when needed, every invalid case, extended/truncated chunks, session round trip; fuzz seed carries the chunk and a sweep of all 256 values of each byte. Recorded in `source/io/project_format.d` header, `docs/manual.md` §13.1, and `docs/changelog.md` (2026-11-25 14:29:04 KST).
- **Needs:** —

#### [App] Keys, scales, and note spelling · T11 · Build

- **Files:** `source/app/music_theory.d` (new), `tests/unit/music_theory_test.d` (new)
- **Done:** 2026-11-25. `KeyMode` (values match the MUSC chunk), `MusicalKey`, `allKeys()` (24), `keyName()` ("Bb major"), `tonicName()`, `tonicChoices(mode)` (12 names for a tonic dropdown), `usesFlats()` (F, Bb, Eb, Ab, Db major and relative minors), `relativeKey()`, `scalePitchClasses()`, `degreePitchClass()`, `pitchClassOf()`, `pitchClassName()` and `noteName()` ("Bb3"; middle C = C4). Scale tones are spelled diatonically, one letter per degree (E# in F# major and D# minor); other pitch classes follow the key's sharp or flat preference. Names use ASCII `#` and `b` like the pattern editor (T02's proposal wrote ♭; the app fonts were not checked for ♭ and ♯). No dependencies. Tests cover all 24 keys. Recorded in the `source/app/music_theory.d` header and `docs/changelog.md` (2026-11-25 14:29:04 KST).
- **Needs:** T02

#### [App] Replace the open project with one built in memory · T10 · Build

- **Files:** `source/app/session.d`, `tests/unit/persistence_test.d`
- **Done:** 2026-11-25. `StudioSession.openProjectFromMemory(proj, err)`: serializes `proj` and parses it again, so it gets exactly the checks of loading an .msv file, then activates it like a load (trial materialization first, so bad modules or wiring leave the open project untouched; playback stops; undo history cleared). The result has no path and counts as unsaved. Tests: opens and renders sound; dirty, no path, no undo; refuses bad tempo, unknown module type, bad pattern shape, and duplicate module ids, each time keeping the open project. Recorded in `docs/changelog.md` (2026-11-25 14:14:57 KST).
- **Needs:** —

#### [GUI/widgets] Confirmation overlay · T09 · Build

- **Files:** `source/gui/widgets.d`, `tests/unit/gui_test.d`
- **Done:** 2026-11-25. `ConfirmDialog` and `openConfirmDialog(ctx, title, message, confirmLabel, cancelLabel, onConfirm, onCancel)`: centred, sized to the wrapped message (`wrapTextLines()`), opens above other overlays without closing them. Return or Enter confirms, Escape cancels (a focused button handles Return itself), Tab moves between the buttons, all other keys are consumed. Resolves once; the overlay is closed before the handler runs, so a handler may open another dialog. New `Widget.isModalOverlay()` and `UiContext.topModalIndex()`: below a modal overlay, hit-testing, hover, and scrolling find nothing, and a click outside it closes only it and the overlays above it (cancelling the dialog). Recorded in `docs/changelog.md` (2026-11-25 14:14:57 KST).
- **Needs:** —

#### [Project] Where the unsaved-changes confirmation applies · T08 · Decision

- **Files:** `source/app/studio_app.d`, `docs/manual.md` (Appendix C QA note on missing prompt)
- **Done:** 2026-11-25 (owner accepted the proposal). Only the generator asks before discarding unsaved changes. New Project, Open Project, and Quit keep discarding silently for now; adding the confirmation to them is T27. Recorded here until T26.
- **Needs:** —

#### [Project] Menu item title, position, and shortcut · T07 · Decision

- **Files:** `source/platform/macos/appkit.d`, `source/app/keymap.d`
- **Done:** 2026-11-25 (owner accepted the proposal). "New Project from Skeleton…" directly below "New Project" in the File menu, shortcut ⇧⌘N. Recorded here until T26.
- **Needs:** —

#### [Project] Default bass and piano modules, and what the user may choose · T06 · Decision

- **Files:** `source/app/skeleton_gen.d` (new), `source/graph/registry.d`, `source/modules/synths/analog_gen.d`, `source/modules/synths/fm_synth.d`
- **Done:** 2026-11-25 (owner accepted the proposal). Each instrument has a dropdown: *Default*, *Analog Generator*, *FM Synth*, *SpectraVoice* (module defaults), and *Load preset file…* (`.msym`). Samplers and drum modules are not listed. Defaults: bass = Analog Generator with a bass parameter set; piano = FM Synth with an electric-piano parameter set. Both are constants in code, not shipped `.msym` files; the owner approves the sounds by ear (T13). Recorded here until T26.
- **Needs:** —

#### [Project] Generated patterns: rhythm, voicing, and layout · T05 · Decision

- **Files:** `source/app/skeleton_gen.d` (new)
- **Done:** 2026-11-25 (owner accepted the proposal). Recorded here until T26.
  - Length: each block lasts 1 bar by default; the user can set ½, 1, 2, or 4 bars per block.
  - Bass: one track. The root (or slash bass note) in octave 2 (MIDI 36–47) at the start of each block, held until the next block; note-off on the last line.
  - Piano: four tracks. Root position, close voicing, root in octave 4 (MIDI 60–71), one note per track, held like the bass. Triads leave the fourth track empty.
  - Layout: one pattern "Bass" and one pattern "Piano", each as long as the whole progression; one clip each at line 0 on lanes 0 and 1; the loop covers the progression. A progression longer than `MAX_LINES` (4096) is refused in the panel.
  - No progression: no modules are added; the project has one empty pattern of 4 bars.
- **Needs:** —

#### [Project] Preset progressions · T04 · Decision

- **Files:** `source/app/chord_progression.d` (new)
- **Done:** 2026-11-25 (owner accepted the proposal). Major: circle of fifths (iii–vi–ii–V–I), I–V–vi–IV, I–vi–IV–V, vi–IV–I–V, I–IV–V, ii–V–I, canon (I–V–vi–iii–IV–I–IV–V), 12-bar blues (I7×4, IV7×2, I7×2, V7, IV7, I7, V7). Minor: i–VI–III–VII, i–iv–v, Andalusian (i–VII–VI–V). Stored as Roman numerals, so they follow the chosen key. Only presets of the chosen mode are listed. Recorded here until T26.
- **Needs:** —

#### [Project] Chord vocabulary and input syntax · T03 · Decision

- **Files:** `source/app/chord_progression.d` (new)
- **Done:** 2026-11-25 (owner accepted the proposal). Recorded here until T26.
  - Qualities: major, minor, diminished, augmented, sus2, sus4, 7, maj7, m7, m7♭5, dim7.
  - Roman numerals: upper case = major, lower case = minor; `b` or `#` before the numeral (`bVII`); suffixes `7`, `maj7`, `dim` or `°`, `aug` or `+`, `sus2`, `sus4`. Degrees are counted on the scale of the chosen key (in A minor, `III` is C major).
  - Chord names: root `A`–`G` with `#` or `b`, then `m`, `dim`, `aug`, `sus2`, `sus4`, `7`, `maj7`, `m7`, `m7b5`, `dim7`.
  - Slash chords in chord names only (`C/E`): the bass plays the note after the slash. Roman numerals have no slash form.
  - Chords are separated by spaces, commas, `-`, or `->`. Each typed chord becomes one block of one bar.
- **Needs:** —

#### [Project] Song key: choices and storage · T02 · Decision

- **Files:** `source/io/project_format.d`, `source/app/music_theory.d` (new)
- **Done:** 2026-11-25 (owner accepted the proposal). 12 tonics × major or natural minor (24 keys), default C major. Flat keys are spelled with flats (F, B♭, E♭, A♭, D♭, and their relative minors), the rest with sharps. The key is saved in the project with the time signature (T12) but has no effect after generation in this version. Recorded here until T26.
- **Needs:** —

#### [Project] Time signature model · T01 · Decision

- **Files:** `source/sequencer/clock.d`, `source/app/session.d`, `source/gui/views/pattern_editor.d`, `source/gui/views/timeline_view.d`, `source/gui/views/transport_bar.d`
- **Done:** 2026-11-25 (owner accepted the proposal). Numerator 1–16; denominator 2, 4, 8, or 16; default 4/4. A line stays a sixteenth note and the clock is unchanged (BPM counts quarter notes, 4 lines each). Lines per beat = 16 ÷ denominator; lines per bar = numerator × lines per beat (3/4 = 12, 6/8 = 12, 7/8 = 14). One time signature per project, no changes mid-song. The transport bar gets a control to change it after generation (T18). Recorded here until T26.
- **Needs:** —

---

## Changelog

### 2026-11-25T14:04:29+09:00 — Claude Fable 5.2, Document created with skeleton project generator tasks

- Added: Document maintaining guide and format template (adapted from Enparse `dev_meta/todo.md`).
- Added: Feature summary for the skeleton project generator, with the four owner decisions of 2026-11-25 (in-app panel, time signature stored in the project, both chord input forms, confirm before replacing).
- Added: Decision tasks T01–T08 and build tasks T09–T26.

### 2026-11-25T14:14:57+09:00 — Claude Opus 5.5, Stage 0 finished

- Modified: T01–T08 moved to *Done*; the owner accepted every proposal as written. Decisions are kept in their *Done* entries until T26 moves them to the manual and architecture document.
- Modified: T09 (confirmation overlay) and T10 (`openProjectFromMemory`) built and moved to *Done*.
- Modified: Stages recomputed. T11, T12, T13 now Stage 0; T14, T15 Stage 1; T16–T19 Stage 2; T20 Stage 3; T21–T23 Stage 4; T24 Stage 5; T25, T26 Stage 6.
- Modified: T11, T12, T13, T15, T18, T19, T21, T22, T23, T24, T26 now name the decided values and the new APIs instead of pointing at proposals. T18 no longer says it may be skipped (T01 keeps the control).
- Added: T27, unsaved-changes confirmation for New Project, Open Project, and Quit (left out of the generator by T08).
- Added: Two facts to the feature summary (the new APIs; non-modal overlays close on an outside click).

### 2026-11-25T14:29:04+09:00 — Claude Opus 5.5, T11, T12, T27 done; T13 built; generator panel modal

- Added: Owner decision that the generator panel is modal; T20 now describes the modal behaviour and its tests.
- Modified: T11, T12, T27 moved to *Done*. T13 built but left open in Stage 0 until the owner approves the default sounds by ear (new **Status** line).
- Modified: Stages recomputed. T14, T15 now Stage 0; T16–T19 Stage 1; T20 Stage 2; T21–T23 Stage 3; T24 Stage 4; T25, T26 Stage 5.
- Modified: T14, T15, T18, T19, T22, T24, T26 name the new APIs (`MusicalKey`, `isValidTimeSignature`, `resolveInstrument`, `audioOutputPort`, `confirmDiscardThen`, ...). T24 now uses `StudioRoot.confirmDiscardThen()` and needs T27. T18 updates the manual's note on the missing control.
- Modified: Feature summary facts (the project file stores time signature and key; list of available building blocks).
- Added: T28, ask before quitting through `terminate:` (Dock, logout, shutdown), found while building T27.

### 2026-11-25T16:50:00+09:00 — Claude Opus 5.5, T14, T15, T28 done; T13 sound check

- Added: Owner decision that logout quits without asking (T28 *Done*; restart and shutdown treated the same).
- Modified: T14, T15, T28 moved to *Done*. T13 stays open; its **Status** now gives the `--sound-check` command for the listening check.
- Modified: Stages recomputed. T16, T17, T18 now Stage 0; T19 Stage 1 (waits for T13). Later stages unchanged.
- Modified: Feature summary facts (session API for time signature and key; `app.chord_progression`). T26 lists only `skeleton_panel.d` as missing from the package map.
- Added: T29 (Decision), count-in length in time signatures other than 4/4, found in T15.

### 2026-11-25T18:30:00+09:00 — Claude Opus 5.5, T13 approved; T16, T17, T18, T29 done

- Modified: T13 moved to *Done* (owner approved the default sounds). T29 moved to *Done* (owner accepted one bar, at least 2 beats) and built.
- Modified: T16, T17, T18 built and moved to *Done*.
- Modified: Stages recomputed. T19 now Stage 0; T20 Stage 1; T21–T23 Stage 2; T24 Stage 3; T25, T26 Stage 4.
- Modified: Feature summary facts (what follows the time signature now; the preset API).
