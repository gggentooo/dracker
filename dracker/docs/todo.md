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

## Feature: Skeleton project generator (finished 2026-11-25)

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
- Available building blocks: `StudioSession.openProjectFromMemory()` (T10); `openConfirmDialog()` and modal overlays (`Widget.isModalOverlay()`, T09); `StudioRoot.confirmDiscardThen()` (T27); `app.music_theory` (T11); `app.skeleton_gen` instrument choices, `resolveInstrument()`, `audioOutputPort()` (T13); `app.chord_progression` (`parseProgression()`, `resolveChord()`, `chordLabel()`, `chordIntervals()`, `ChordBlock.halfBars`; T14; presets `PROGRESSION_PRESETS`, `presetsFor()`, `presetBlocks()`, `presetLabel()`; T16); `SkeletonSpec`, `validateSpec()`, `generateSkeleton()` (T19); `StudioRoot.openSkeletonPanel()` and `SkeletonPanel` with its `onCreate` hook (T20–T22; `onCreate` is connected by `StudioRoot`, T24; the File menu item and ⇧⌘N open the panel, T23).

---

## Feature: Pattern editor views (tracker, piano roll, drumpad)

The pattern editor gets a top bar that switches between three views of the current pattern: the existing **Tracker** view, a DAW-style **Piano roll**, and an FL-Studio-style **Drumpad** for drum patterns. Drum patterns are a new pattern type. All views use the app's high-contrast theme and its rules (contrast ratios, color-blind-safe sets, a non-color cue for every color meaning, no size changes).

Decided by the owner on 2026-11-25:

- **Piano roll is a view of the same pattern.** It shows and edits the same cells as the tracker view. Overlapping notes go on different tracks; a track is added automatically when a note needs one. No change to playback or to how notes are stored.
- **Piano roll shows one module at a time.** A module picker in its bar chooses the module; its notes are drawn in full, other modules' notes dimmed behind them; new notes go to the picked module.
- **Drum pattern = cell grid + lane table.** A drum pattern is a normal cell grid in which each track is one drum lane, plus a lane table (name, module, note per lane) and a "drum" type flag, saved in a new optional file section. The engine plays it unchanged.
- **A lane triggers any module + note.** One drum pattern can mix a Kicker, DrumSynth sounds and Sampler hits.
- **Views per type.** Normal patterns offer Tracker and Piano roll. Drum patterns offer Drumpad and Tracker.
- **Creating.** "New drum pattern" (with lanes for a default kit), and conversion between normal and drum patterns in both directions.

Facts about the current code that the tasks rely on:

- `PatternEditorView` (`source/gui/views/pattern_editor.d`, about 2,100 lines) is one widget holding the header controls (pattern dropdown, tracks and lines boxes, add / duplicate / delete), the tracker grid, selection, clipboard and note entry. It has no notion of views.
- `SavedPattern` is `patternId, tracks, lines, name, cells`; the `PATS` file section is a fixed sequence, so new per-pattern data needs a new optional section (as was done for `MIDI` and `MUSC`).
- A track plays one note at a time; a note lasts until the next note or note-off on its track; each cell names its module. The piano roll must derive note lengths from that.
- The DrumSynth is an 8-voice GM-mapped kit (one drum per MIDI note); the Kicker is a single drum; the Sampler plays loaded samples.
- The theme has tokens for tracker rows and fields but none for piano keys, roll notes or pads. Every new color must pass the contrast and color-vision checks in `tests/unit/appearance_test.d` for every built-in palette.

---

## Feature: Instrument library in the patchbay

The patchbay gets a sidebar on its left that lists presets for modules, grouped (instruments and effects). A set of presets ships with the app; the user's own presets appear in the same list.

Decided by the owner on 2026-11-25:

- **All presets, grouped.** The list shows every preset (instruments and effects) in groups.
- **Adding: double-click and drag, no auto-wiring.** Double-click adds the module at the next free position; dragging onto the canvas adds it where it is dropped. Neither wires it.
- **User presets live in an app-wide folder.** `~/Library/Application Support/Dracker/Instruments`. "Add to Instruments" on a module saves its preset there; `.msym` files placed there also appear.
- **Bundled set.** About 12 instruments and about 4 effects, designed in this project and approved by the owner by ear.
- **The skeleton generator uses the library.** Its Bass and Piano menus list the library's playable instruments; its defaults become the bundled Electric Bass and Electric Piano.

Facts about the current code that the tasks rely on:

- A preset file (`.msym`) holds one module: a synth, an effect, or a MetaModule with an inner patch. It has a preset name but no category field. `StudioContext.saveModulePreset()` / `loadModulePreset()` / `applyModulePreset()` and the patchbay menu items exist.
- `PatchbayView` fills its whole pane with the canvas; there is no sidebar. Modules are added from the canvas context menu (`addModuleAt`).
- The toolkit has no list widget and no drag-and-drop between widgets.
- No presets ship with the app. Fonts are the model for bundled resources: `bundledFontDirectories()` looks in `Contents/Resources/Fonts` and `resources/fonts`; `packaging/macos/bundle_macos.sh` builds the bundle.
- The skeleton generator has its default bass and piano as constants in `source/app/skeleton_gen.d` and a `--sound-check` render for listening.

---

## Stage 0 — Ready now

#### [Tests] End-to-end check of the instrument library · T57 · Build

- **Files:** `tests/unit/views_studio_root_test.d`, `source/app/studio_app.d` (`--studio-gui-selftest`)
- **Task:** Headless: add a bundled instrument by double-click and by drag, wire it, play it; add a module to the library, find it in the list, use it in the skeleton generator; remove it. Check the built app bundle lists the bundled presets. **Open until the owner has checked by hand**, including drag-and-drop with a real pointer.
- **Needs:** T49, T52, T55

---

## Stage 1

#### [Docs] Manual and architecture: instrument library · T59 · Build

- **Files:** `docs/manual.md` (§6, §13.6, §13.9, Appendix C), `../architecture.md`, `agents.md` (package map), `docs/changelog.md`
- **Task:** Describe the sidebar, the bundled presets, the user folder and the generator's instrument menus in the manual; record the decisions T35–T37 in the architecture document; update the package map. Check that every build task has its changelog entry.
- **Needs:** T57

---

## Done

#### [Packaging] Bundled presets in the app bundle · T49 · Build

- **Files:** `packaging/macos/bundle_macos.sh`, `ci/macos.yml`, `agents.md` (Phase 9.1 note)
- **Done:** 2026-11-26. `packaging/macos/bundle_macos.sh` parses all 16 presets from `source/app/factory_presets.d`, verifies their `.msym` files in `resources/presets/`, copies them into `Contents/Resources/Presets`, and fails if any are missing; `ci/macos.yml` enforces `bash -n`, preset presence, and `factory_presets_test`; `agents.md` Phase 9.1 updated. Recorded in `docs/changelog.md` (2026-11-26 08:05:02 KST).
- **Needs:** T46

#### [App, GUI/views] Skeleton generator uses the library · T52 · Build

- **Files:** `source/app/skeleton_gen.d`, `source/gui/views/skeleton_panel.d`, `source/gui/views/studio_root.d`, `tests/unit/skeleton_gen_test.d`, `tests/unit/views_skeleton_panel_test.d`
- **Done:** 2026-11-26. Added `InstrumentSource.libraryPreset`, `InstrumentChoice.ofLibrary()`, `instrumentChoices(InstrumentLibrary)` (listing playable bundled then user presets after `"Default"`), and `resolveDefaultModule()` (resolving defaults via the bundled `.msym` files with built-in fallback when missing). `SkeletonPanel` and `StudioRoot.createSkeletonProject()` rescan and pass `ctx.library`. Tests verify library dropdowns, user preset selection/remembering, fallback on empty library, and byte-identical / sample-identical generated default projects. Recorded in `docs/changelog.md` (2026-11-26 08:05:02 KST).
- **Needs:** T45, T46

#### [Docs] Manual and architecture: pattern editor views · T58 · Build

- **Files:** `docs/manual.md` (§8, Appendix A, Appendix C), `../architecture.md`, `agents.md` (package map), `docs/changelog.md`
- **Done:** 2026-11-26. Updated `docs/manual.md` (§8.1 view bar/`+Drum`/`...` header, new §8.12 Piano roll, new §8.13 Drum patterns and the drumpad, Appendix A shortcuts/mouse modifiers, Appendix C notes), `../architecture.md` (§3 directory tree and new §8 documenting components, owner decisions T30–T34, and the optional `DRUM` chunk), and `agents.md` package map; audited changelog entries for every build task. Recorded in `docs/changelog.md` (2026-11-26 08:05:02 KST).
- **Needs:** T56

#### [Tests] End-to-end check of the pattern editor views · T56 · Build

- **Files:** `tests/unit/views_studio_root_test.d`, `source/app/studio_app.d` (`--studio-gui-selftest`)
- **Done:** 2026-11-26 (owner signed off). Built 2026-11-26 (`docs/changelog.md`, 2026-11-26 07:51:33 KST): headless end-to-end workflow and contrast/palette/time-signature render checks in `tests/unit/views_studio_root_test.d`, plus `"pattern editor views (switch)"` in `runStudioGuiSelfTest()`.
- **Needs:** T51, T53, T54

#### [App] Keys presets: retune and verify · T64 · Build

- **Files:** `source/app/factory_presets.d`, `resources/presets/Keys/`, `tests/unit/factory_presets_test.d`, `tests/unit/skeleton_gen_test.d`
- **Done:** 2026-11-26 (owner confirmed). Retuned `Electric Piano`, `Bright Piano`, and `Bell` per T61 (`Organ` unchanged), regenerated `resources/presets/Keys/*.msym`, added Keys hold/release regression tests, and updated `defaultPianoModule` checks (`docs/changelog.md`, 2026-11-26 07:51:33 KST).
- **Needs:** T61, T63

#### [App] Bundled presets: definitions, files, and sound check · T46 · Build

- **Files:** `source/app/factory_presets.d` (new), `resources/presets/` (new), `source/main.d` (`--write-factory-presets`, `--sound-check`), `source/app/skeleton_gen.d`, `tests/unit/factory_presets_test.d` (new)
- **Done:** 2026-11-26 (owner confirmed after T63–T65 fixes and `--sound-check-presets=build/preset-sounds` / `--sound-check=build/default-sounds.wav` renders). Recorded in `docs/changelog.md` (2026-11-25 19:17:29 KST, 2026-11-26 07:38:02 KST, 2026-11-26 07:51:33 KST).
- **Needs:** T36, T37, T64, T65

#### [GUI/views] Piano roll: editing · T53 · Build

- **Files:** `source/gui/views/piano_roll_view.d`, `source/app/session.d`, `tests/unit/views_piano_roll_test.d`
- **Task:** Editing per T31 through T42: add, move, resize, delete, copy-drag, rubber-band selection, velocity strip, note audition, clipboard and transpose commands, one undo step per gesture, automatic track adding with a status message, refused edits explained. Tests for each gesture, undo, and that other modules' notes and effect columns survive.
- **Status:** Built 2026-11-26 (see `docs/changelog.md`, 2026-11-26 07:38:02 KST).
- **Needs:** T47

#### [GUI/views] Drumpad: lanes, new drum pattern, and conversion · T54 · Build

- **Files:** `source/gui/views/drumpad_view.d`, `source/gui/views/pattern_editor.d`, `tests/unit/views_drumpad_test.d`
- **Task:** Lane menu (module and note chooser, rename, move, remove), add lane, lane audition; "New drum pattern" next to the existing add button; "Convert to drum pattern" / "Convert to normal pattern" in the pattern menu; all through T41. Tests for each command and its undo.
- **Status:** Built 2026-11-26 (see `docs/changelog.md`, 2026-11-26 07:38:02 KST).
- **Needs:** T34, T48

#### [GUI/views] Patchbay: managing user presets · T55 · Build

- **Files:** `source/gui/views/studio_context.d`, `source/gui/views/instrument_sidebar.d`, `source/gui/views/patchbay_view.d`, `tests/unit/views_instrument_sidebar_test.d`
- **Task:** "Add to Instruments" on a module's menu (name and group, per T35); the row menu for user presets (Rename, Move to group, Remove with a confirmation, Show in Finder); bundled rows offer none of these. Errors (folder not writable, name in use) are shown in the status bar. Tests with temporary folders and a fake Finder call.
- **Status:** Built 2026-11-26 (see `docs/changelog.md`, 2026-11-26 07:38:02 KST).
- **Needs:** T50

#### [DSP] FM Synth envelope: decay and release shape · T63 · Build

- **Files:** `source/dsp/envelope.d`, `source/modules/synths/fm_synth.d`, `tests/unit/dsp_test.d`, `tests/golden/golden_suite.d`, `tests/unit/modules_test.d`
- **Task:** Apply the decision of T60. Unit tests for the envelope shape (after a quarter of the release time the level is below half; decay likewise; the envelope still ends exactly at zero and stays real-time safe). Regenerate the golden references that involve the FM Synth and list which changed. Render the sound check again.
- **Status:** Built 2026-11-26 (see `docs/changelog.md`, 2026-11-26 07:38:02 KST). Inspected `tests/golden/golden_suite.d`: no checked-in `.wav` references exist (renders dynamically in `/tmp`); patches involving `synth.fm_synth` are Patch 2 (`synth.fm_synth -> fx.waveshaper -> fx.flanger -> fx.eq3 -> core.output`) and Patch 4 (`Engine` song with `synth.fm_synth` + `ctl.metamodule` + `fx.echo`).
- **Needs:** T60

#### [App] Effect previews that expose the effect · T65 · Build

- **Files:** `source/app/factory_presets.d`, `source/modules/effects/reverb.d`, `resources/presets/Effects/`, `source/main.d`, `tests/unit/factory_presets_test.d`, `docs/manual.md` (Appendix D)
- **Task:** Apply the decision of T62: per-effect preview material, separate dry and wet files, and the stronger preset values. Tests that would have caught the report: for every effect the wet render differs from the dry render by at least a quarter of the dry level; the reverb and the delay are still audible 0.5 s into a rest; the compressor reduces the difference between loud and quiet hits; the overdrive adds energy above the fundamental. Render the sound check for the owner.
- **Status:** Built 2026-11-26 (see `docs/changelog.md`, 2026-11-26 07:38:02 KST).
- **Needs:** T62

#### [GUI/views] Drum patterns in the timeline and the pattern list · T51 · Build

- **Files:** `source/gui/views/timeline_view.d`, `source/gui/views/pattern_editor.d`, `tests/unit/views_timeline_test.d`, `tests/unit/views_pattern_editor_test.d`
- **Done:** 2026-11-25. `PatternEditorView` pattern dropdown prefixes drum patterns with `[D] ` (`formatPatternListEntry()`). `TimelineView` renders a `[D]` prefix on drum pattern clips (`paintClip()` and `clipNameRect()`), prefixes empty-lane menu items (`"Add Clip: [D] ..."`), and draws drum pattern miniatures (`paintMiniature()`) as lane-aligned square hit dots rather than melodic bars. Verified by `views_timeline_test.d` and `views_pattern_editor_test.d`. Recorded in `docs/changelog.md` (2026-11-25 20:15:23 KST).
- **Needs:** T41

#### [GUI/views] Patchbay: instrument sidebar · T50 · Build

- **Files:** `source/gui/views/patchbay_view.d`, `source/gui/views/instrument_sidebar.d` (new), `source/gui/views/studio_context.d`, `tests/unit/views_patchbay_test.d`, `tests/unit/views_instrument_sidebar_test.d` (new)
- **Done:** 2026-11-25. Fixed the pre-existing `tests/unit/views_patchbay_test.d:824` failure (`"Add Core ▸"` omitted when empty). Added `StudioContext.library`, `libraryRevision()`, `notifyLibraryChanged()`, and `addPresetFromLibrary()`. Created `InstrumentSidebar` (`GroupedList` over `InstrumentLibrary`, `"user"` tag, collapse toggle, missing-bundled note, focus/revision rescan, drag payloads) and integrated it into `PatchbayView` (`canvasRect()`, hit-testing/pan/zoom/Fit All scoped to canvas, double-click/Return add at `nextModulePosition()`, drag-and-drop with `onDragQuery`/`onDragEnter`/`onDragLeave`/`onDrop` outline and drop at `viewToWorld(pos)`). Verified by `views_patchbay_test.d` and `views_instrument_sidebar_test.d`. Recorded in `docs/changelog.md` (2026-11-25 20:15:23 KST).
- **Needs:** T35, T39, T40, T45

#### [GUI/views] Drumpad: pads · T48 · Build

- **Files:** `source/gui/views/drumpad_view.d` (new), `source/gui/views/pattern_editor.d`, `tests/unit/views_drumpad_test.d` (new)
- **Done:** 2026-11-25. `DrumpadView` registered with `PatternEditorView.registerView(PatternViewKind.drumpad, …)`: lane names with unassigned-lane hatching and `[unassigned]` tag, beat/bar grouped step pads using `linesPerBeat()` / `linesPerBar()`, click toggle, drag paint/erase as single undo groups, vertical velocity drag and Option-click cycle (soft/medium/loud) updating lane default velocity, playhead column with follow, non-color corner mark for hits differing from their lane, and horizontal/vertical scroll. Verified by `views_drumpad_test.d`. Recorded in `docs/changelog.md` (2026-11-25 20:15:23 KST).
- **Needs:** T33, T41, T43, T44

#### [GUI/views] Piano roll: display and navigation · T47 · Build

- **Files:** `source/gui/views/piano_roll_view.d` (new), `source/gui/views/pattern_editor.d`, `tests/unit/views_piano_roll_test.d` (new)
- **Done:** 2026-11-25. `PianoRollView` registered with `PatternEditorView.registerView(PatternViewKind.pianoRoll, …)`: piano keys (`C-1`..`G9`, C labels, indented black keys), time-signature bar ruler and grid (`linesPerBeat()` / `linesPerBar()`), notes from `notesOf()` (picked module filled `theme.rollNote`, other modules outlined `theme.borderStrong`), module picker in top bar synced with `StudioContext`, auto-scroll to notes on open/pattern change, playhead and follow, scroll/Cmd-scroll/pinch/action zoom, and live redraw on pattern/undo changes. Verified by `views_piano_roll_test.d` across all built-in palettes and contrast modes. Recorded in `docs/changelog.md` (2026-11-25 20:15:23 KST).
- **Needs:** T31, T42, T43, T44

#### [Project] Effect previews and effect preset strength · T62 · Decision

- **Files:** `source/app/factory_presets.d` (`factoryPreviewProject()`, the four effect presets), `source/main.d` (`--sound-check-presets`), `source/modules/effects/reverb.d`
- **Done:** 2026-11-25 (owner accepted the proposal). Write two files per effect (`… (dry).wav` and `… (wet).wav`) so they can be compared directly. Use material that exposes each effect: short chords with rests for Room Reverb and Tempo Delay, the Drum Kit beat for Bus Compressor, and the Electric Bass line for Warm Overdrive. Strengthen presets: Room Reverb Wet 0.45 and Room Size 0.6; Tempo Delay Wet 0.5; Bus Compressor Threshold −24 dB, Ratio 4, Makeup 6 dB; Warm Overdrive Drive 8, Mix 1. Also check during T65 whether Reverb's output level (~10 dB below input at this setting) is intended. Recorded here until T59 moves decisions into the manual and architecture document.
- **Needs:** —

#### [Project] Keys presets: how held and released notes behave · T61 · Decision

- **Files:** `source/app/factory_presets.d` (Electric Piano, Bright Piano, Organ, Bell)
- **Done:** 2026-11-25 (owner accepted the proposal). Electric Piano and Bright Piano: Sustain 0 with longer Decay (2500 ms and 1800 ms) so a held key dies away, Release 200 ms. Bell: Release 600 ms. Organ: unchanged. Changing Electric Piano changes the skeleton generator's default piano (approved in T13), so it needs fresh approval in T64/T46. Recorded here until T59 moves decisions into the manual and architecture document.
- **Needs:** —

#### [Project] FM Synth envelope shape · T60 · Decision

- **Files:** `source/dsp/envelope.d` (`AdsrEnvelope.next()`, `setCurves()`), `source/modules/synths/fm_synth.d` (lines 98 and 103), `tests/golden/golden_suite.d`, `sample-projects/lobby_waltz.msv`
- **Done:** 2026-11-25 (owner accepted the proposal). Make `AdsrEnvelope` decay and release fall fast first and then level off (`1 − (1 − phase)^curve` in place of `phase^curve`), keeping the attack as it is. Every FM Synth sound changes, including the Electric Piano approved in T13, existing projects that use the FM Synth, and the golden WAV references (regenerated and reviewed in T63). Recorded here until T59 moves decisions into the manual and architecture document.
- **Needs:** —

#### [App] Instrument library: bundled and user presets · T45 · Build

- **Files:** `source/app/instrument_library.d` (new), `tests/unit/instrument_library_test.d` (new)
- **Done:** 2026-11-25. `InstrumentLibrary(bundledDirs, userDir, trashDir)`: scans `.msym` files; group = folder name (standard groups Bass, Keys, Pads & Leads, Drums, Effects first, then other folder names, then Other for files directly in a library folder); entry name = file name; `LibraryEntry` has origin (bundled / user), module type and whether it can play notes. Unreadable files and unknown module types are skipped and listed in `problems()`. User presets: `addFromModule()` (an existing name gets " 2", " 3", …), `rename()` (file and inner preset name), `moveToGroup()`, `remove()` (moves the file into the trash folder under a free name, or deletes it when no trash folder is set); bundled presets refuse all three. `bundledPresetDirectories()` (`Contents/Resources/Presets`, then `resources/presets` next to a development build), `defaultUserInstrumentDirectory()`, `defaultTrashDirectory()` (`~/.Trash`), `isValidPresetName()`. The bundled-folder lookup lives here, not in `gui_shell.d`, so headless code and tests can use it. Recorded in `docs/changelog.md` (2026-11-25 19:17:29 KST).
- **Needs:** T35, T37

#### [GUI] Theme colors for the new views · T44 · Build

- **Files:** `source/gui/theme.d`, `source/gui/appearance.d`, `tests/unit/appearance_test.d`
- **Done:** 2026-11-25. Three new tokens: `rollNote`, `rollNoteSelected`, `padHit` (in every built-in palette they equal the accent, hot accent and accent). The rest of what the views need already exists and is reused: piano key colors (`pianoWhiteKey`, `pianoBlackKey`, `pianoKeyBorder`, `pianoKeyText`, from the piano keys pane), tracker row colors for the roll and pad backgrounds, `border` / `borderStrong` for outlines, `trackerPlayhead` / `danger` for the playhead. New graphic contrast pairs: the three tokens and both borders against all four row backgrounds, plus note-on-selection and pad-on-hover; all pass in every palette and both contrast modes. New token group "Piano roll & drumpad" in the Appearance panel. Palette and preference files written before these tokens existed still load: a missing late token takes the palette's accent color (`lateTokenSource()`); other missing tokens are still refused. No size metric changed. Recorded in `docs/manual.md` §14 and `docs/changelog.md` (2026-11-25 19:17:29 KST).
- **Needs:** T31, T33

#### [GUI/views] Pattern editor: view bar and the tracker view as one of several · T43 · Build

- **Files:** `source/gui/views/pattern_editor.d`, `tests/unit/views_pattern_editor_test.d`
- **Done:** 2026-11-25. View bar (28 points) above the shared header with **Tracker**, **Piano roll**, **Drumpad** (`ViewTabButton`: the current view has a 2-point outline and a bar under its name). `PatternViewKind`; `registerView(kind, widget)`, `viewOffered()`, `viewAvailable()`, `currentView()`, `setView()`, `viewRect()`. A button is enabled when the pattern's type offers the view and, for the two new views, a widget is registered; so today only Tracker is enabled. The view is remembered per pattern for the run; a drum pattern first opens in Drumpad once that view exists. While another view is current the tracker ignores mouse, keys, MIDI step entry and its context menu; studio actions go to the view when it implements `StudioCommandSink`; the Trk box is hidden. **Not done as planned:** the tracker grid was not moved into a new `tracker_view.d`; it stays inside `PatternEditorView`, which is both the host and the tracker view. Splitting 2,100 lines of working editor would have risked the tracker for no visible gain; the other views plug in through `registerView()` either way. Recorded in `docs/manual.md` §8.1 and `docs/changelog.md` (2026-11-25 19:17:29 KST).
- **Needs:** T30

#### [App] Note model for the piano roll · T42 · Build

- **Files:** `source/app/pattern_notes.d` (new), `tests/unit/pattern_notes_test.d` (new)
- **Done:** 2026-11-25. `PatternGrid` (working copy of a pattern's cells), `RollNote`, `notesOf()`, `addNote()`, `moveNote()`, `moveNotes()` (all or nothing), `resizeNote()`, `deleteNote()`, `deleteNotes()`, `setNoteVelocity()`, `NoteEdit` results with `noteEditMessage()`. Track choice per T32, with one addition: a moved or resized note stays on its own track when that is free. Any note command (not only note-off) ends a note. A note whose module is inherited from an earlier cell gets it written explicitly before cells above it change, so other modules' notes never change. Effect columns travel with the note. Every edit works on a copy and is applied only on success. Tests include 3,000 random edits that must leave another module's notes untouched. Recorded in the `source/app/pattern_notes.d` header and `docs/changelog.md` (2026-11-25 19:17:29 KST).
- **Needs:** T32

#### [App] Drum patterns in the session · T41 · Build

- **Files:** `source/app/session.d`, `tests/unit/studio_backend_test.d`
- **Done:** 2026-11-25. Getters `patternKind()`, `patternLanes()`, `isDrumLaneAssigned()`, `drumHitAt()`. Undoable: `doAddDrumPattern()` (1 bar; Kick 36, Snare 38, Closed Hat 42, Open Hat 46 on the first DrumSynth, adding and wiring one named "Drums" in the same undo step when there is none; the notes were checked against the DrumSynth's map), `doAddDrumLane()`, `doRemoveDrumLane()` (not the last lane), `doMoveDrumLane()`, `doRenameDrumLane()`, `doRetargetDrumLane()` (hits that used the old module and note follow), `doConvertToDrumPattern()`, `doConvertToNormalPattern()`, `doSetDrumHit()`, `doToggleDrumHit()`. Resizing a drum pattern keeps lanes in step with tracks, and undo restores them (closing the gap left by T38). Duplicate keeps kind and lanes. A lane whose module was deleted is reported unassigned without changing the lane, so undoing the deletion restores it. Lanes converted from a normal pattern are named after the module only, so several lanes can share a name. Recorded in `docs/changelog.md` (2026-11-25 19:17:29 KST).
- **Needs:** T34, T38

#### [GUI/widgets] Grouped list widget · T40 · Build

- **Files:** `source/gui/widgets.d`, `tests/unit/gui_test.d`
- **Done:** 2026-11-25. `GroupedList` with `ListGroup` (title, rows, collapsed) and `ListRow` (text, dimmer detail, outlined tag, caller object). Click selects; a click on a header selects it and collapses or expands; double-click or Return activates (`onActivate`); ↑ / ↓ walk headers and visible rows, ← collapses (from a row it first goes to the header), → expands then enters, Home / End jump; right-click selects the row and asks `rowMenuProvider`; dragging a row past `UiContext.dragThreshold` starts a drag with `dragPayloadProvider`'s payload. Wheel scrolling with a position indicator (the indicator cannot be dragged); selections are scrolled into view; `setGroups()` keeps the selection by group title and row text. Selection = filled bar + 2-point border + left marker; focus ring on the list. Tested: selection, every key, collapsing, hit-testing, scrolling, row menus, row drags, redraw in a dark low-contrast palette. Recorded in `docs/changelog.md` (2026-11-25 18:58:52 KST).
- **Needs:** —

#### [GUI/widgets] Drag-and-drop between widgets · T39 · Build

- **Files:** `source/gui/widgets.d`, `tests/unit/gui_test.d`
- **Done:** 2026-11-25. `DragPayload` (kind, object, label). `UiContext.beginDrag(source, payload)` (called by the source from its `onMouseMove` after `dragThreshold` = 5 points), `cancelDrag()`, `isDragging()`, `dragPayload()`, `dragTarget()`. Widget hooks: `onDragQuery` (the widget under the pointer, then its ancestors; the first that accepts is the target), `onDragEnter`, `onDragMove`, `onDragLeave`, `onDrop`, and `onDragFinished` on the source. The payload label follows the pointer (accent border while over a target). The source loses its mouse capture; Escape, a second button press or losing window focus cancels; all other keys are swallowed during a drag; removing the target or source mid-drag is safe. Ordinary clicks and captures are unchanged. Tested: accept and refuse by kind, ancestor targets, enter / move / leave / drop order and positions, refused drop, every cancel path, removal mid-drag. Recorded in `docs/changelog.md` (2026-11-25 18:58:52 KST).
- **Needs:** —

#### [IO] Pattern type and drum lanes in the project file · T38 · Build

- **Files:** `source/io/project_format.d`, `source/app/session.d`, `tests/unit/persistence_test.d`, `tests/fuzz/project_format_fuzz.d`
- **Done:** 2026-11-25. `SavedPattern.kind` (`PATTERN_KIND_NORMAL` = 0, `PATTERN_KIND_DRUM` = 1) and `SavedPattern.lanes` (`SavedDrumLane`: name up to 256 bytes, module id with 0 = unassigned, note 0–127; lane i belongs to track i; at most one per track). Optional `DRUM` chunk, written only when a drum pattern exists: a count, then one length-prefixed entry per drum pattern (pattern id, kind, lane count, lanes). `MSV_FORMAT_VERSION` stays 1; older builds skip the chunk and load drum patterns as normal ones. Loading: bytes after an entry's lanes are ignored; entries for unknown patterns or of unknown kinds are skipped; a later entry for the same pattern wins; truncated entries, notes above 127, over-long names and more lanes than tracks are refused. `isValidPatternKind()`; `validateProjectForSave()` refuses a normal pattern with lanes, an unknown kind, or bad lanes. Session: pattern copies keep kind and lanes (load, save, duplicate, `openProjectFromMemory`), and reducing the track count trims the lanes so the project stays saveable. Tests: round trips (byte-identical re-save), every refusal, forward compatibility, session round trip, and a sweep of all 256 values of every byte of the chunk. Recorded in the `source/io/project_format.d` header and `docs/changelog.md` (2026-11-25 18:58:52 KST).
- **Needs:** —

#### [Project] Bundled presets: how they are made and packaged · T37 · Decision

- **Files:** `source/app/factory_presets.d` (new), `resources/presets/` (new), `packaging/macos/bundle_macos.sh`, `source/main.d`
- **Done:** 2026-11-25 (owner accepted the proposal). Recorded here until T58 / T59 move it to the manual and architecture document. They are defined in code as parameter sets set by parameter name (like `defaultBassModule()`), so changes can be reviewed as text. `dracker --write-factory-presets <dir>` writes them as `.msym` files into `resources/presets/<Group>/`, which are checked in; a unit test fails when the files and the code differ. The app reads them from `Contents/Resources/Presets` in the bundle, or `resources/presets` in a development build (as for fonts). If no bundled presets are found, the sidebar shows the user's presets and a note, and the skeleton generator falls back to its built-in defaults. The user folder is `~/Library/Application Support/Dracker/Instruments/<Group>/`.
- **Needs:** —

#### [Project] Bundled presets: the list · T36 · Decision

- **Files:** `source/app/factory_presets.d` (new)
- **Done:** 2026-11-25 (owner accepted the proposal). Recorded here until T58 / T59 move it to the manual and architecture document.
  - Bass: **Electric Bass** (Analog Generator; today's default bass), **Synth Bass** (Analog Generator).
  - Keys: **Electric Piano** (FM Synth; today's default piano), **Bright Piano** (FM Synth), **Organ** (FM Synth), **Bell** (FM Synth).
  - Pads & Leads: **Warm Pad** (Analog Generator), **Strings** (SpectraVoice), **Saw Lead** (Analog Generator), **Pluck** (FM Synth).
  - Drums: **Drum Kit** (DrumSynth), **Kick** (Kicker).
  - Effects: **Room Reverb** (Reverb), **Tempo Delay** (Delay), **Bus Compressor** (Compressor), **Warm Overdrive** (Distortion).
  - The owner approves each sound by ear from a rendered sound check (T46) before it ships.
- **Needs:** —

#### [Project] Instrument sidebar: layout, grouping, and list behaviour · T35 · Decision

- **Files:** `source/gui/views/patchbay_view.d`, `source/app/instrument_library.d` (new)
- **Done:** 2026-11-25 (owner accepted the proposal). Recorded here until T58 / T59 move it to the manual and architecture document.
  - A column 200 points wide at the left edge of the patchbay pane with a header "Instruments" and a button that collapses it to a narrow strip; the canvas uses the rest.
  - Groups come from the folder a preset is in: **Bass**, **Keys**, **Pads & Leads**, **Drums**, **Effects**, and **Other** for files directly in the library folder. Bundled and user presets share the groups; user presets carry a "user" tag after the name. Groups can be collapsed.
  - Each row shows the preset name and, dimmer, the module type. Rows are sorted by name.
  - Bundled presets cannot be renamed or removed. User presets get a context menu: Rename, Move to group, Remove (moves the file to the Trash), Show in Finder.
  - "Add to Instruments" asks for a name and a group; an existing name gets a number added.
  - Dragging shows the preset name following the pointer; the canvas is outlined while a drop is possible; Escape cancels.
  - No search field in the first version.
- **Needs:** —

#### [Project] Drum patterns: default kit, tracker view, and conversion · T34 · Decision

- **Files:** `source/app/session.d`, `source/modules/synths/drumsynth.d`
- **Done:** 2026-11-25 (owner accepted the proposal). Recorded here until T58 / T59 move it to the manual and architecture document.
  - New drum pattern: 1 bar long, lanes Kick, Snare, Closed Hat, Open Hat on a DrumSynth (General MIDI notes 36, 38, 42, 46; to be checked against the module's note map when building T41). If the project has no DrumSynth, one is added and wired to the Master Output in the same undo step.
  - Tracker view of a drum pattern: fully editable. A cell whose module or note differs from its lane still plays; the drumpad shows it as a hit with a corner mark.
  - Adding or removing a track in the tracker view adds or removes the lane. At most 64 lanes.
  - Normal → drum: every track becomes a lane named after its module, using the track's module and first note (tracks without notes get an unassigned lane). Drum → normal: the lane table is dropped; cells are untouched. Both are one undo step.
  - Duplicating a drum pattern copies its lanes. Live recording still creates normal patterns.
  - If a lane's module is deleted, the lane stays, is marked unassigned, and its hits are silent.
- **Needs:** —

#### [Project] Drumpad: layout and editing · T33 · Decision

- **Files:** `source/gui/views/drumpad_view.d` (new)
- **Done:** 2026-11-25 (owner accepted the proposal). Recorded here until T58 / T59 move it to the manual and architecture document.
  - Layout: one row per lane; at the left the lane name and a small menu (module, note, rename, move up / down, remove); to the right one pad per line. Pads are grouped by beat with a gap, bars with a wider gap and a bar number, following the time signature. The playhead column is marked.
  - Pads: click toggles a hit; dragging across pads paints or erases. A hit is drawn filled with a border, an empty pad as an outline (shape, not color alone). Velocity is the fill height inside the pad: drag up or down on a hit, or ⌥-click to cycle soft / medium / loud. New hits use the lane's last velocity (at first 0.8).
  - A hit is a note cell with the lane's module and note and no note-off (drums ring out).
  - Clicking a lane name plays the drum. Each gesture is one undo step.
  - Pattern length is set in bars with the shared lines box (steps = lines).
  - Not in the first version: swing, probability, per-step pitch, lane mute / solo.
- **Needs:** —

#### [Project] Piano roll: how notes map to tracks · T32 · Decision

- **Files:** `source/app/pattern_notes.d` (new)
- **Done:** 2026-11-25 (owner accepted the proposal). Recorded here until T58 / T59 move it to the manual and architecture document.
  - A note is a note cell; it ends at the next note or note-off on its track, or at the end of the pattern.
  - A new or moved note goes on the lowest-numbered track where it overlaps nothing and whose other notes belong to the same module; else on an empty track; else a new track is added (up to 64) in the same undo step. If no track can be added, the edit is refused with a status message.
  - Shortening a note writes a note-off at its new end; lengthening removes or moves it; a note-off is not written when the next note starts exactly at the end.
  - Two notes of the same module and pitch may not overlap.
  - Empty tracks are never removed automatically.
- **Needs:** —

#### [Project] Piano roll: layout and editing · T31 · Decision

- **Files:** `source/gui/views/piano_roll_view.d` (new)
- **Done:** 2026-11-25 (owner accepted the proposal). Recorded here until T58 / T59 move it to the manual and architecture document.
  - Layout: piano keys down the left (C-1 to G9, C keys labelled, black keys drawn differently and also marked by position), time left to right in lines with the beat and bar grid of the time signature, playhead line, vertical and horizontal scroll, zoom on both axes (⌘ scroll / pinch), follow-playhead as in the tracker view.
  - Notes: a rectangle from its start line to its end; the picked module's notes solid with a border, other modules' notes as outlines only.
  - Mouse: click empty space adds a note (length of the last edited note, at first one beat) and plays it; drag a note's body moves it in time and pitch; drag its right edge changes its length; rubber-band selects; Delete removes; ⌥-drag copies; Escape cancels a drag. Everything snaps to whole lines.
  - Velocity: a strip under the roll with one bar per selected or all notes; drag to change.
  - Each gesture is one undo step. ⌘X / ⌘C / ⌘V and transpose commands work on the selection.
  - Not shown in the first version: effect columns (kept untouched when a note moves), sub-line delays, notes shorter than a line.
- **Needs:** —

#### [Project] Pattern editor view bar · T30 · Decision

- **Files:** `source/gui/views/pattern_editor.d`
- **Done:** 2026-11-25 (owner accepted the proposal). Recorded here until T58 / T59 move it to the manual and architecture document. A row at the top of the pattern pane, above the existing header: three buttons **Tracker**, **Piano roll**, **Drumpad**, the current one lit with the 2-point outline used for lit transport buttons (not color alone). A view the pattern type does not offer is disabled, not hidden. The view is remembered per pattern for this run of the app and is not saved in the project (like other editor state); a drum pattern first opens in Drumpad, a normal pattern in Tracker. No keyboard shortcuts in the first version. The pattern dropdown, add / duplicate / delete and the lines box stay in a header shared by all views; the tracks box is shown in the Tracker view only.
- **Needs:** —

#### [Tests] End-to-end check of the generator · T25 · Build

- **Files:** `tests/unit/views_skeleton_panel_test.d`, `source/app/studio_app.d` (`--studio-gui-selftest`)
- **Done:** 2026-11-25 (owner tested the GUI and closed the task). Headless end-to-end test (⇧⌘N, typed title and BPM, 3/4, G major, circle-of-fifths preset, FM bass, Create; document checked, saved, reopened, compared, rendered) and the GUI self-test step "skeleton generator panel (menu)". Recorded in `docs/changelog.md` (2026-11-25 18:15:00 KST).
- **Needs:** T23, T24

#### [Docs] Manual, changelog, and agent guide · T26 · Build

- **Files:** `docs/manual.md`, `docs/changelog.md`, `agents.md`, `../architecture.md`
- **Done:** 2026-11-25. Manual: new §13.9 *New Project from Skeleton* (panel, project fields, chord syntax table, error example, preset table, block editing, instruments, what Create makes); File menu row and Appendix A shortcut (⇧⌘N); §1.3 (time signature and key of a new project, pointer to §13.9); §13.1 (the key is chosen in the generator); Appendix C rows 25 (no key control after generation) and 26 (Create is not undoable). `../architecture.md`: new §7 *Skeleton Project Generator* (components and data flow, the owner decisions T01–T08, T27–T29, and the `MUSC` chunk) and the new files in the §3 tree; note that this file is ignored by git (root `.gitignore`), so the change exists only on disk. Package map in `agents.md` already listed every new file. Changelog: every build task T09–T29 has an entry (14:14, 14:29, 16:45, 17:40, 18:08 and 18:15 KST). Recorded in `docs/changelog.md` (2026-11-25 18:15:00 KST).
- **Needs:** T23, T24

#### [GUI/views, App] Create: confirm, generate, and open the new project · T24 · Build

- **Files:** `source/gui/views/studio_root.d`, `source/gui/views/skeleton_panel.d`, `tests/unit/views_skeleton_panel_test.d`
- **Done:** 2026-11-25. `StudioRoot.openSkeletonPanel()` connects `onCreate` to `createSkeletonProject()`: `generateSkeleton()` (a failure goes to the panel footer via the new `SkeletonPanel.setCreateError()`), then `confirmDiscardThen("Creating a new project discards them.", …)`, then `openProjectFromMemory()`, `SkeletonPanel.close()` (new), select the Piano pattern (else the only pattern) and status "Created project <title>". The handler returns false and closes the panel itself, because the question may still be open; Cancel there keeps the old project and the panel. Tests: clean (no question), modified (question; Escape keeps both; Return replaces), no chords (empty project, pattern 1 selected), footer error cleared by the next Create. Recorded in `docs/manual.md` §13.9 and `docs/changelog.md` (2026-11-25 18:15:00 KST).
- **Needs:** T08, T09, T10, T21, T22, T27

#### [Platform, App] File menu item and action · T23 · Build

- **Files:** `source/platform/macos/appkit.d` (`MENU_ITEMS`), `source/app/keymap.d`, `source/gui/views/studio_root.d`, `source/app/gui_shell.d`, `tests/unit/keymap_test.d`, `tests/unit/views_skeleton_panel_test.d`
- **Done:** 2026-11-25. File menu "New Project from Skeleton…" directly below "New Project", key equivalent ⇧⌘N (`"N"`, ⌘⇧, key code 45). `StudioAction.newSkeletonProject = 44` (document-level), default binding ⇧⌘N, `executeAction` → `openSkeletonPanel()` (no-op when open; while the modal panel is open the shortcut is consumed). `--gui-selftest` menu check and the keymap tables include it. Tests: keymap resolves ⇧⌘N, ⌘N unchanged, the menu table agrees, the key and `executeAction` open the panel once. Recorded in `docs/manual.md` §3 and Appendix A and `docs/changelog.md` (2026-11-25 18:15:00 KST).
- **Needs:** T07, T20

#### [GUI/views] Generator panel: bass and piano module choice · T22 · Build

- **Files:** `source/gui/views/skeleton_panel.d`, `tests/unit/views_skeleton_panel_test.d`
- **Done:** 2026-11-25. *Instruments* section: Bass and Piano dropdowns ("Default", "Analog Generator", "FM Synth", "SpectraVoice", "Load preset file…"), enabled only when the progression has a block (with a note under them otherwise). *Load preset file…* opens "Load Bass Preset" / "Load Piano Preset" (`.msym`); a preset that loads and can play notes adds and selects "Preset: <name>" (kept in that dropdown, also after reopening). A cancelled dialog keeps the choice silently; an unreadable file ("Could not load preset: …"), a preset that cannot play notes ("<name>" cannot play notes; choose a synth preset) or missing file dialogs show the reason and keep the earlier choice. Tested with a fake dialog and real temporary `.msym` files. Recorded in `docs/changelog.md` (2026-11-25 18:08:00 KST); the manual section comes with T26.
- **Needs:** T13, T20

#### [GUI/views] Generator panel: chord progression · T21 · Build

- **Files:** `source/gui/views/skeleton_panel.d` (`ChordBlockStrip`), `tests/unit/views_skeleton_panel_test.d`
- **Done:** 2026-11-25. *Chord progression* section: chord field (Return or *Add*: chords appended as one-bar blocks, field cleared, last new block selected; on a parse error the message replaces the syntax hint under the field and the text stays), preset dropdown of the key's mode with *Insert* (after the selected block, else at the end; last inserted block selected), and `ChordBlockStrip` in a horizontal scroll view (box width grows with length; shows "ii · Dm" and "1 bar"; click selects and focuses; ←/→ select, ⌥←/⌥→ move, Delete/Backspace remove; the selection is scrolled into view). Buttons *◀ Move*, *Move ▶*, *Remove*, a length dropdown (½, 1, 2, 4 bars) and *Clear*, disabled when they do nothing; total length ("6½ bars · 104 lines"). Changing the key relabels Roman-numeral blocks; named chords keep their names; changing the mode also switches the preset list and the tonic names. Recorded in `docs/changelog.md` (2026-11-25 18:08:00 KST); the manual section comes with T26.
- **Needs:** T16, T20

#### [GUI/views] Generator panel: frame and project settings · T20 · Build

- **Files:** `source/gui/views/skeleton_panel.d` (new), `source/gui/views/studio_root.d`, `source/gui/widgets.d`, `tests/unit/views_skeleton_panel_test.d` (new), `tests/unit/gui_test.d`
- **Done:** 2026-11-25. `SkeletonPanel` (720 × 640, smaller in a small window, where the body scrolls) opened by `StudioRoot.openSkeletonPanel()`; `skeletonPanel()` returns it. Modal: `isModalOverlay()` and the new `closesOnOutsideClick()` = false, so an outside click does nothing; every key is consumed (no shortcuts, no piano notes; ⌘-menu shortcuts are not forwarded). Escape (also from a text field) and *Cancel* close it; *Create* calls `onCreate(spec)` and closes when it returns true. The footer shows why *Create* is disabled (`validateSpec()`'s reason, or "Creating a project is not connected yet" while `onCreate` is null, i.e. until T24). *Project* section: title, BPM (1 decimal), ticks per line, time signature (number box / dropdown), key (tonic named for the mode, mode). Tab / Shift+Tab move focus through the controls and scroll them into view. The last spec is kept by `StudioRoot` for the next opening in this run. Toolkit changes needed for a form inside an overlay (`widgets.d`): typed text and key releases go to the focused widget inside the top overlay; a click inside a modal overlay moves focus; a click in a lower overlay first closes the popups above it (an open dropdown list closes when clicking elsewhere in the panel); `TextField.persistent` (stays editable after Return, Escape/Tab reach the form, `onEdit` on every change, caret only when focused). Recorded in `docs/changelog.md` (2026-11-25 18:08:00 KST); the manual section comes with T26 once the menu item (T23) makes the panel reachable.
- **Needs:** T19

#### [App] Skeleton generator: settings to project · T19 · Build

- **Files:** `source/app/skeleton_gen.d`, `tests/unit/skeleton_gen_test.d`
- **Done:** 2026-11-25. `SkeletonSpec` (defaults: Untitled, 125 BPM, 6 TPL, 4/4, C major, no blocks, default instruments), `validateSpec()` (one sentence per problem: tempo, time signature, key, block length, half-bar blocks when a bar has an odd number of lines, total over 4096 lines, instruments), `specLinesPerBeat()`, `specLinesPerBar()`, `blockLines()`, `totalLines()`, `generateSkeleton()` per T05. Choices made here (not in T05): every note and note-off carries its module id (T05 only required the first); after a seventh chord, a triad puts a note-off on piano track 4 so the seventh does not hang on; the last-line note-off is written only into empty cells, so a chord starting on the last line is kept; an empty title becomes "Untitled"; wire gains are the approved sound-check levels (`SKELETON_BASS_GAIN` 0.3, `SKELETON_PIANO_GAIN` 0.22). Tests: empty projects in 4/4 and 3/4, cell-by-cell ii–V7–I in C major and i–iv–V in A minor 3/4, mixed lengths, slash basses, 3/8 and 1/8 half bars, every validation message, a 4096-line maximum, and offline renders with each part muted in turn. Recorded in the `source/app/skeleton_gen.d` header and `docs/changelog.md` (2026-11-25 18:08:00 KST).
- **Needs:** T05, T13, T14, T15

#### [App] Count-in length in other time signatures · T29 · Decision

- **Files:** `source/app/session.d` (`countInBeats()`, `MIN_COUNT_IN_BEATS`, `beginLiveTake`), `source/gui/views/studio_context.d` (count-in status), `tests/unit/studio_backend_test.d`, `docs/manual.md` (§8.11 *Count-in*)
- **Done:** 2026-11-25 (owner accepted the proposal and asked for it to be built). The count-in lasts one bar (numerator beats) but at least `MIN_COUNT_IN_BEATS` = 2 beats: 4/4 unchanged (4 beats, 16 lines), 3/4 3 beats, 6/8 6 beats (12 lines), 7/8 7, 2/2 and 1/4 2 beats. `StudioSession.countInBeats()` replaces `COUNT_IN_BEATS`; the first status message ("Count-in N") uses it. Tested by the count-in start line in six time signatures. Recorded in `docs/manual.md` §8.11 and `docs/changelog.md` (2026-11-25 17:40:00 KST).
- **Needs:** —

#### [GUI/views] Time signature control in the transport bar · T18 · Build

- **Files:** `source/gui/views/transport_bar.d`, `tests/unit/views_transport_test.d`, `docs/manual.md` (§5, §13.1)
- **Done:** 2026-11-25. **SIG** after TPL: a numerator drag box (`transport.sigNum`, 1–16, 8 points per step, double-click to type; one "Change Time Signature" undo step per drag) and a denominator dropdown after a "/" caption (`transport.sigDen`: 2, 4, 8, 16; one undo step per choice). Both go through `doSetTimeSignature()` and follow undo/redo and other changes. The Rec button's count-in blink now follows the beat length (it assumed 4 lines). The controls take 122 more points, so in narrow windows the controls at the right end (device picker, meters) are hidden sooner. Tests: ids and order, drags and clamping, dropdown choices, undo, outside changes, typed entry. Recorded in `docs/manual.md` §5 and §13.1 and `docs/changelog.md` (2026-11-25 17:40:00 KST).
- **Needs:** T01, T15

#### [GUI/views] Beat and bar highlighting follows the time signature · T17 · Build

- **Files:** `source/gui/views/pattern_editor.d`, `source/gui/views/timeline_view.d`, `tests/unit/views_pattern_editor_test.d`, `tests/unit/views_timeline_test.d`, `docs/manual.md` (§8, §9.3)
- **Done:** 2026-11-25. Pattern editor: the `beatLines` / `barLines` fields became methods reading `StudioSession.linesPerBeat()` / `linesPerBar()`; row shading, bar rules and bold line numbers follow them. Timeline: the `linesPerBeat` / `linesPerBar` constants became methods reading the session; `gridFor()` (snapping: beat, Shift = line, Cmd = bar) is now an instance method; grid lines and ruler ticks use the session's values; ruler labels (`majorStep()`, now public) step through power-of-two divisions of a beat, beat multiples that divide a bar, then bars and their doublings, so labels land on beats or bars (4/4 unchanged: 1, 2, 4, 8, 16, …). Tests in 4/4, 3/4 and 6/8 (drawn shading and grid lines, snap grids, label steps for six time signatures and seven zooms, undo). Recorded in `docs/manual.md` §8 and §9.3 and `docs/changelog.md` (2026-11-25 17:40:00 KST).
- **Needs:** T15

#### [App] Preset progressions · T16 · Build

- **Files:** `source/app/chord_progression.d`, `tests/unit/chord_progression_test.d`
- **Done:** 2026-11-25. `ProgressionPreset` (name, mode, progression text), `PROGRESSION_PRESETS` (the 11 presets of T04, as Roman-numeral text), `presetsFor(mode)`, `presetBlocks()` (one bar each), `presetLabel()` ("Circle of fifths: iii - vi - ii - V - I"). Names not given in T04 are mine: "Pop" (I–V–vi–IV), "Fifties" (I–vi–IV–V), "Pop (minor start)" (vi–IV–I–V), "Three chords" (I–IV–V), "Jazz ii-V-I", "Minor pop" (i–VI–III–VII), "Minor three chords" (i–iv–v); rename freely. Tests: every preset parses and resolves in every key of its mode; chord names checked for seven presets (Andalusian in A minor: Am G F E, with a major E). Recorded in the `source/app/chord_progression.d` header and `docs/changelog.md` (2026-11-25 17:40:00 KST).
- **Needs:** T04, T14

#### [App] Default bass and piano definitions and the module choice list · T13 · Build

- **Files:** `source/app/skeleton_gen.d`, `tests/unit/skeleton_gen_test.d`, `source/main.d` (`--sound-check`)
- **Done:** 2026-11-25 (owner listened to `build/default-sounds.wav` and approved the default sounds). Instrument choices, `resolveInstrument()`, the default bass (Analog Generator) and piano (FM Synth electric piano), and the `--sound-check` preview, as described in `docs/changelog.md` (2026-11-25 14:29:04 and 16:45:00 KST).
- **Needs:** T06

#### [Platform] Ask before quitting from the Dock; quit at once on logout · T28 · Build

- **Files:** `source/platform/macos/appkit.d`, `source/app/studio_app.d`, `docs/manual.md` (§13.8, Appendix C row 1)
- **Done:** 2026-11-25 (owner decision: logout quits without asking). New `STAppDelegate` (`NSApplicationDelegate`) answers `applicationShouldTerminate:`. If the quit Apple event's `kAEQuitReason` is logout, restart or shutdown (`logo`, `rlgo`, `rrst`, `rest`, `rsdn`, `shut`; `isSessionEndQuitReason()`), it calls `MacWindow.sessionEndHandler` and answers `NSTerminateNow`, so nothing is asked and unsaved changes are lost; the studio's handler cancels a running WAV export, waits for it to stop, and closes the audio host. Any other quit (Dock icon menu, Apple events) is answered `NSTerminateCancel` and delivered as `closeRequested`, so it asks like ⌘Q (T27). Restart and shutdown are treated like logout (my reading of the decision). Tested: the reason list and the delegate's answer without a window (`dub test --config=app`). **Not tested by hand:** a real Dock quit and a real logout. Recorded in `docs/manual.md` §13.8 and `docs/changelog.md` (2026-11-25 16:45:00 KST).
- **Needs:** —

#### [App] Time signature and key in the session · T15 · Build

- **Files:** `source/app/session.d`, `source/app/history.d`, `source/gui/views/studio_context.d`, `tests/unit/studio_backend_test.d`
- **Done:** 2026-11-25. `timeSignatureNumerator()`, `timeSignatureDenominator()`, `linesPerBeat()` (16 ÷ denominator), `linesPerBar()`, `songKey()` (`MusicalKey`). Undoable `doSetTimeSignature()` ("Change Time Signature") and `doSetKey()` ("Change Key"); invalid values are refused, setting the current value adds no undo step. `StudioSession.LINES_PER_BEAT` is removed: the count-in plays `COUNT_IN_BEATS` (4) beats of the project's beat and the count-in status divides by it. Count-in length in bars is open: T29. Tests: defaults, seven time signatures, undo/redo, invalid values, keys, save/load, New Project, count-in start line in 4/4, 6/8 and 2/2. Recorded in `docs/manual.md` §8.11 and `docs/changelog.md` (2026-11-25 16:45:00 KST).
- **Needs:** T12

#### [App] Chord model and parser · T14 · Build

- **Files:** `source/app/chord_progression.d` (new), `tests/unit/chord_progression_test.d` (new), `tests/fuzz/chord_progression_fuzz.d` (new)
- **Done:** 2026-11-25. `ChordQuality` (the 11 qualities of T03), `ChordForm`, `Chord`, `ChordBlock` (`halfBars`, default 2 = one bar; `BLOCK_HALF_BARS` = 1, 2, 4, 8), `ProgressionError` (byte position, length, reason), `ResolvedChord`. `parseChord()`, `parseProgression()` (separators: spaces, commas, `-`, `->`), `chordIntervals()`, `resolveChord()`, `romanLabel()`, `nameLabel()`, `chordLabel()` ("ii · Dm"). Beyond T03, also accepted: `♭`/`♯` for `b`/`#`; `°`, `+`, `ø`, `m7♭5` aliases in chord names; half-diminished Roman numerals (`viiø7`, `viim7b5`) and `°7`/`dim7` (T03 listed only `7`, `maj7`, `dim`, `aug`, `sus2`, `sus4` as Roman suffixes). Case rules: diminished in upper case and major-family suffixes in lower case are refused with a hint. Labels: a named chord's root outside the scale gets a flattened numeral (Bb in C is `bVII`), else a sharpened one; Roman labels use `°` and `ø` (Latin-1; not checked in the app fonts). Tests: every quality in both forms in C major and A minor, all 24 keys × 7 degrees × 3 accidentals × every suffix, errors and positions, labels; 60,000-input fuzz. Recorded in the `source/app/chord_progression.d` header and `docs/changelog.md` (2026-11-25 16:45:00 KST).
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

### 2026-11-25T16:45:00+09:00 — Claude Opus 5.5, T14, T15, T28 done; T13 sound check

- Added: Owner decision that logout quits without asking (T28 *Done*; restart and shutdown treated the same).
- Modified: T14, T15, T28 moved to *Done*. T13 stays open; its **Status** now gives the `--sound-check` command for the listening check.
- Modified: Stages recomputed. T16, T17, T18 now Stage 0; T19 Stage 1 (waits for T13). Later stages unchanged.
- Modified: Feature summary facts (session API for time signature and key; `app.chord_progression`). T26 lists only `skeleton_panel.d` as missing from the package map.
- Added: T29 (Decision), count-in length in time signatures other than 4/4, found in T15.

### 2026-11-25T17:40:00+09:00 — Claude Opus 5.5, T13 approved; T16, T17, T18, T29 done

- Modified: T13 moved to *Done* (owner approved the default sounds). T29 moved to *Done* (owner accepted one bar, at least 2 beats) and built.
- Modified: T16, T17, T18 built and moved to *Done*.
- Modified: Stages recomputed. T19 now Stage 0; T20 Stage 1; T21–T23 Stage 2; T24 Stage 3; T25, T26 Stage 4.
- Modified: Feature summary facts (what follows the time signature now; the preset API).

### 2026-11-25T18:08:00+09:00 — Claude Opus 5.5, T19, T20, T21, T22 done

- Modified: T19, T20, T21, T22 built and moved to *Done*, with the choices made beyond T05 and the toolkit changes listed in their entries.
- Modified: Stages recomputed. T23 and T24 now Stage 0; T25 and T26 Stage 1.
- Modified: T23 calls `openSkeletonPanel()`; T24 connects `SkeletonPanel.onCreate`; T26 no longer lists a missing package-map entry.
- Modified: Feature summary building blocks (generator, panel and `onCreate`).

### 2026-11-25T18:15:00+09:00 — Claude Opus 5.5, T23, T24, T26 done; T25 waits for the owner

- Modified: T23, T24, T26 built and moved to *Done*.
- Modified: T25 built (headless end-to-end test, GUI self-test step) but left open in Stage 0 until the owner runs the GUI self-test and checks the app by hand (new **Status** line). It is the only open task.
- Modified: Feature summary building blocks (menu item and connected Create).

### 2026-11-25T18:46:08+09:00 — Claude Fable 5.2, T25 closed; plans for pattern editor views and the instrument library

- Modified: T25 moved to *Done* (the owner tested the GUI). The skeleton project generator feature is finished.
- Modified: Changelog timestamps corrected in this file and in `docs/changelog.md`. Four earlier entries carried times that were not read from the clock (16:50, 18:30, 20:00, 21:30); they now show the approximate real times taken from file modification times (16:45, 17:40, 18:08, 18:15).
- Added: Feature section "Pattern editor views" with six owner decisions of 2026-11-25, decision tasks T30–T34 and build tasks T38, T41–T44, T47, T48, T51, T53, T54, T56, T58.
- Added: Feature section "Instrument library in the patchbay" with five owner decisions of 2026-11-25, decision tasks T35–T37 and build tasks T39, T40, T45, T46, T49, T50, T52, T55, T57, T59.

### 2026-11-25T18:58:52+09:00 — Claude Fable 5.2, T30–T37 decided; T38, T39, T40 done

- Modified: T30–T37 moved to *Done*; the owner accepted every proposal as written. They stay recorded in their *Done* entries until T58 / T59.
- Modified: T38, T39, T40 built and moved to *Done*.
- Modified: Stages recomputed. T41–T46 now Stage 0; T47–T52 Stage 1; T53–T55 Stage 2; T56, T57 Stage 3; T58, T59 Stage 4.
- Modified: T41 notes what T38 already stores and the one gap it leaves (undo of a track reduction does not restore a trimmed lane). T50 names the drag-and-drop hooks.

### 2026-11-25T19:17:29+09:00 — Claude Fable 5.2, T41–T45 done; T46 built and waiting for the owner

- Modified: T41, T42, T43, T44, T45 built and moved to *Done*. T43 records that the tracker grid was not split into its own file.
- Modified: T46 built but left open in Stage 0 until the owner approves the 16 sounds by ear (new **Status** line with the listening command).
- Modified: Stages recomputed. T47, T48, T50, T51 now Stage 0; T49, T52–T55 Stage 1; T56, T57 Stage 2; T58, T59 Stage 3.
- Modified: T47 and T48 name `registerView()` and the session's drum API.

### 2026-11-25T19:32:06+09:00 — Claude Fable 5.2, investigation of the owner's listening report; T60–T65 added

- Added: Decision tasks T60 (FM Synth envelope shape), T61 (Keys presets: held and released notes) and T62 (effect previews and effect strength), each with the measured cause and a proposal.
- Added: Build tasks T63 (envelope change), T64 (Keys retune with tests) and T65 (effect previews with tests).
- Modified: T46 now needs T64 and T65 and its **Status** records the owner's two findings. It moves to Stage 3; T49 and T52 move to Stage 4, T57 to Stage 5, T59 to Stage 6.
- Modified: Stages recomputed for the other tasks (T53–T55 Stage 1, T56 Stage 2, T58 Stage 3).

### 2026-11-25T20:15:23+09:00 — Gemini 4 Neon, T60–T62 decided; Stage 0 build items T47, T48, T50, T51 done

- Modified: T60, T61, and T62 moved to *Done*; owner approved the proposed options for each decision.
- Modified: T47 (`PianoRollView`), T48 (`DrumpadView`), T50 (`InstrumentSidebar` + `PatchbayView` integration + `tests/unit/views_patchbay_test.d:824` fix), and T51 (drum pattern marks in timeline and pattern dropdown) built and moved to *Done*.
- Modified: Stages recomputed. T53, T54, T55, T63, T65 now Stage 0; T56, T64 Stage 1; T46, T58 Stage 2; T49, T52 Stage 3; T57 Stage 4; T59 Stage 5.

### 2026-11-26T07:38:02+09:00 — Gemini 4 Neon, Stage 0 build items T53, T54, T55, T63, T65 done

- Modified: T53 (piano roll editing), T54 (drumpad lanes, new drum pattern, and pattern conversion), T55 (patchbay/sidebar user preset management), T63 (FM Synth convex-down decay/release curves), and T65 (effect previews and dry/wet preset sound checks) built, tested, rendered, and moved to *Done*.
- Modified: Stages recomputed. T56 and T64 now Stage 0; T46 and T58 Stage 1; T49 and T52 Stage 2; T57 Stage 3; T59 Stage 4.

### 2026-11-26T07:51:33+09:00 — Gemini 4 Neon, T56 and T64 built; awaiting owner verification

- Modified: T64 (Keys presets retuned per T61, `.msym` files regenerated in `resources/presets/Keys/`, hold/release tests added to `tests/unit/factory_presets_test.d`, `skeleton_gen_test.d` updated, sound checks re-rendered) and T56 (headless pattern editor views end-to-end test in `tests/unit/views_studio_root_test.d` and view-switching step in `--studio-gui-selftest`) built and verified; both remain open in Stage 0 until the owner's hand/ear verification.
- Modified: T46 status updated to reflect that T63, T64, and T65 are all built and rendered for the second listening pass.

### 2026-11-26T08:05:02+09:00 — Gemini 4 Neon, T46/T56/T64 signed off; T49, T52, T58 done

- Modified: T46, T56, and T64 moved to *Done* following owner confirmation.
- Modified: T49 (app bundle preset copying & verification in `packaging/macos/bundle_macos.sh`, `ci/macos.yml`, and `agents.md`), T52 (skeleton generator library menus & bundled defaults with built-in fallback), and T58 (`docs/manual.md` §8/Appendices A & C, `../architecture.md` §3 & §8, `agents.md` package map, changelog audit) built and moved to *Done*.
- Modified: Stages recomputed. T57 now Stage 0; T59 Stage 1.
