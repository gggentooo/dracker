# Dracker Changelog

All major changes to `dracker/` must be recorded in reverse-chronological order (newest entry first).

### Entry Format
- **Timestamp:** `YYYY-MM-DD HH:MM:SS KST` (UTC+09:00)
- **Author:** Human developer name or agent model name
- **Affected Files:** Explicit list of created, modified, or deleted paths
- **Description:** Concise summary of the change(s)

---

## [2026-11-25 13:38:05 KST]
- **Author:** Claude Fable 5.2
- **Affected Files:** `source/gui/widgets.d`, `source/app/session.d`, `source/app/keymap.d`, `source/platform/macos/appkit.d`, `source/gui/views/studio_context.d`, `source/gui/views/studio_root.d`, `source/gui/views/pattern_editor.d`, `source/gui/views/timeline_view.d`, `source/gui/views/scope_view.d`, `source/gui/views/patchbay_view.d`, `tests/unit/gui_test.d`, `tests/unit/keymap_test.d`, `tests/unit/views_pattern_editor_test.d`, `tests/unit/views_timeline_test.d`, `tests/unit/views_transport_test.d`, `tests/unit/views_studio_root_test.d`, `docs/manual.md`, `docs/changelog.md`
- **Reason / Summary:** Pattern renaming from the GUI, a new Scope default, and a GUI workflow for module presets. Design decisions confirmed by the owner (Rule 5) before implementation: on a timeline clip only the name label renames (the rest of the clip still opens its pattern); renaming uses a new in-app text field rather than a native prompt; presets are reachable from the patchbay menus and the File menu; loading adds a new module, and a separate "Apply Preset…" overwrites an existing module of the same type.
  - **Text entry (`gui/widgets.d`):**
    - New `TextField` widget: single line, caret editing (Left/Right/Home/End, Backspace, Forward Delete, ⌘A), starts with all text selected, Return commits, Escape cancels, `maxLength` 128 code points. It consumes every key press while shown, so shortcuts and piano keys do not fire while typing.
    - New `openTextEditor(ui, rect, initial, onCommit)` opens it in the overlay layer; a click elsewhere dismisses it and commits.
    - New `Dropdown.onDoubleClick`. `UiContext.handleMouseDown` calls it when the second click of a double-click lands on a dropdown whose own list the first click opened. Before, that second click only closed the list.
  - **Pattern rename (`app/session.d`, `gui/views/studio_context.d`, `gui/views/pattern_editor.d`, `gui/views/timeline_view.d`):**
    - `StudioSession.doRenamePattern()` now trims the name, refuses an empty one, and makes it unique with the new `uniquePatternName()`: if another pattern has the name, the smallest number 1, 2, … is appended (Drums, Drums1, Drums2). Renaming to the current name is a no-op with no undo step.
    - `StudioContext.renamePattern()` wraps it and sets the status ("Renamed pattern to …").
    - Pattern editor: double-clicking the pattern dropdown opens the field over it (`beginRenamePattern()`).
    - Timeline: double-clicking a clip's name label opens the field at the clip (`clipNameRect()`, `beginRenameClipPattern()`). Double-clicking elsewhere on the clip still selects its pattern.
  - **Scope default (`gui/views/scope_view.d`):** The source dropdown now starts on "Selected module" instead of "Master". With no module selected it still shows the master bus.
  - **Module presets (`.msym`):** There was no GUI for these; the manual's QA notes listed them as engine-only.
    - Session: new `loadModulePresetFromFile()`, and `doApplyModulePresetBytes()` / `doApplyModulePresetFile()`. Apply replaces the parameters and extra data of an existing module of the same type as one "Apply Preset" undo group, keeping id, name, position, wires and mute/bypass. It refuses a different module type, and refuses MetaModules (their child project cannot be swapped in place).
    - Context: `saveModulePreset()`, `loadModulePreset()`, `applyModulePreset()` (file dialogs through `ctx.dialogs`, status messages, Master Output refused) and `nextModulePosition()`.
    - Patchbay: node menu gains **Save Preset…** and **Apply Preset…** (disabled for the Master Output); the canvas menu gains **Load Preset…**, which adds the module where the user right-clicked.
    - File menu: **Save Module Preset…** (⌥⌘S, selected module) and **Load Module Preset…** (⌥⌘O). New document-level `StudioAction.saveModulePreset = 42` and `loadModulePreset = 43`. Native menu items dispatch through the keymap, so they need key bindings; the owner was told the File items would have no default shortcuts, and these two were added because of that mechanism.
  - **Docs:** `docs/manual.md`: File menu, patchbay context menus, §8.1 and §9.3 (renaming), §11 (scope default), new §13.6 *Module presets* (Preferences is now §13.7), the shortcut table, and the QA notes that said presets had no GUI.
- **Verification Results:**
  - `tests/unit/gui_test.d`: `TextField` editing, key consumption, Unicode input, commit/cancel/click-away, `maxLength`; `Dropdown.onDoubleClick` fires only on a real double-click.
  - `tests/unit/views_pattern_editor_test.d`: double-click on the dropdown opens the field with the current name; typed piano keys write no notes in edit mode; duplicates become "Drums1" / "Drums2"; Escape and an empty name change nothing; trimming, `uniquePatternName()` and undo.
  - `tests/unit/views_timeline_test.d`: the name label lies inside the clip; double-clicking it renames without changing the current pattern; double-clicking elsewhere on the clip selects its pattern.
  - `tests/unit/views_transport_test.d`: the scope starts on "Selected module" and follows the selection.
  - `tests/unit/views_studio_root_test.d`: menu items present and disabled for the Master Output; ⌥⌘S saves (refused with no module or the Master Output selected, cancel writes nothing); ⌥⌘O and the canvas item load a new unwired module with the saved values at the right position, as one undo step; Apply restores parameters as one undo step, keeps wires, adds no step when nothing differs, and refuses another module type and the Master Output; unreadable and missing files report an error. `tests/unit/keymap_test.d` covers the new bindings and menu table.
  - `DFLAGS="-w" dub build --compiler=ldc2 --config=headless --force` and `--config=app --build=debug --force` both exit 0 with zero warnings. `dub test --compiler=ldc2 --config=app`: `4 modules passed unittests`.
  - `dub test --compiler=ldc2 --config=headless`: 25/26 modules pass. The one failure is the existing, unrelated `tests/unit/views_patchbay_test.d:824` (`menu should contain 'Add Core ▸'`); because it aborts that module, later patchbay tests do not run, so the new patchbay menu items are checked in the studio root test instead.
  - Not run: the GUI self-tests and the real macOS file dialogs. Typing into the text field through real AppKit key events has not been checked on hardware.

---

## [2026-11-25 13:20:03 KST]
- **Author:** Claude Opus 5.5
- **Affected Files:** `source/graph/module_api.d`, `source/modules/synths/analog_gen.d`, `source/gui/views/param_rack.d`, `source/gui/widgets.d`, `tests/unit/views_param_rack_test.d`, `docs/manual.md`, `docs/changelog.md`
- **Reason / Summary:** Three parameter rack fixes.
  - **Named waveform options (`graph/module_api.d`, `modules/synths/analog_gen.d`, `gui/views/param_rack.d`):**
    - `Param` and `ParamDescriptor` gained an optional `options` list (`string[]` in the attribute, `immutable(string)[]` in the descriptor) that names a discrete parameter's values `minVal, minVal + 1, …` in order. It is display-only and does not change the stored value, `.msv` files or the RT path.
    - The Analog Generator's **Waveform** parameter now lists **Sine, Triangle, Saw, Square, Noise, Drawn**, matching `OscWaveform` 0–5. "Square" is correct because AnalogGen always calls the pulse oscillator with a 0.5 duty cycle.
    - New `discreteOptionLabel()`. The rack dropdown items and `formatParamValue()` (row value text) show the label when one exists, otherwise the number and unit as before.
  - **Slider outline (`gui/widgets.d`):** `Slider.paint` now strokes the whole track with `theme.border` (`theme.textDisabled` when disabled) at `theme.borderWidth`. Before, the track fill (`panelSunken` #EBEBEB) on the rack row (`panel` #F4F4F4, or the odd-row hover tint) had about 1.1:1 contrast, so the slider's ends were hard to see. The Phase 8.5 gates already require `border` against `background`, `panel`, `panelRaised` and `panelSunken` to reach ≥ 4.5:1 (High) / ≥ 3:1 (Low) in every built-in palette; the default light theme gives about 6.4:1 on `panel`. This applies to every `Slider` (the rack's `RackSlider` inherits it). Sizes are unchanged.
  - **Header toggle order (`gui/views/param_rack.d`):** The rack header toggles now read **M, S, B** (mute, solo, bypass), the same order as the patchbay node badges. Creation order changed too, so Tab focus follows the visual order. `headerToggleRect(k)` indices are unchanged (0 = mute, 1 = bypass, 2 = solo).
  - **Docs:** `docs/manual.md` §7 lists the toggles as M, S, B.
- **Verification Results:**
  - New test in `tests/unit/views_param_rack_test.d`: the Analog Generator Waveform dropdown lists the six labels; its default value text is "Saw"; choosing item 3 shows "Square" and stores 3.0 in the document. `discreteOptionLabel()` and `formatParamValue()` are checked with and without options, out-of-range values, NaN and non-discrete parameters. Rack sliders (params 3–5) have a `border`-colored outline covering their track; this check fails when the outline is removed and passes with it.
  - The header toggle test now checks mute → solo → bypass order from left to right, with each caption inside its toggle.
  - `DFLAGS="-w" dub build --compiler=ldc2 --config=headless --force` and `--config=app --build=debug --force` both exit 0 with zero warnings. `dub test --compiler=ldc2 --config=app`: `4 modules passed unittests`.
  - `dub test --compiler=ldc2 --config=headless`: 25/26 modules pass, including the appearance contrast and CVD gates. The one failure is the existing, unrelated `tests/unit/views_patchbay_test.d:824` (`menu should contain 'Add Core ▸'`).

---

## [2026-11-25 12:59:31 KST]
- **Author:** Claude Opus 5.5
- **Affected Files:**
  - Created: `source/sequencer/count_in.d`, `source/app/live_take.d`, `tests/unit/live_take_test.d`
  - Modified: `source/sequencer/clock.d`, `source/sequencer/engine.d`, `source/app/session.d`, `source/app/keymap.d`, `source/app/studio_app.d`, `source/platform/macos/appkit.d`, `source/gui/views/studio_context.d`, `source/gui/views/studio_root.d`, `source/gui/views/transport_bar.d`, `source/gui/views/pattern_editor.d`, `source/gui/views/piano_view.d`, `tests/unit/keymap_test.d`, `tests/unit/sequencer_test.d`, `tests/unit/views_pattern_editor_test.d`, `tests/unit/views_piano_test.d`, `tests/unit/views_studio_root_test.d`, `tests/unit/views_transport_test.d`, `docs/manual.md`, `docs/changelog.md`
- **Reason / Summary:** Split the old "record (edit) mode" into two modes. **Edit mode** keeps the previous behavior: played notes are written at the pattern editor cursor. **Record mode** is new: it records a live take into a new pattern. Design decisions confirmed by the owner (Rule 5) before implementation: the count-in uses both song pre-roll and an Engine metronome click; note-offs are recorded and held notes get their own tracks; takes start at the record point on the first free lane, grow while recording, are trimmed to the last bar used, are discarded when empty, and are one undo step; ⌘R = Record, ⇧⌘R = Edit mode, with separate EDIT and Rec transport buttons.
  - **Engine count-in (RT; `sequencer/count_in.d`, `sequencer/engine.d`, `sequencer/clock.d`):**
    - New `EngineCmdKind.playCountIn` / `EngineCommand.makePlayCountIn(startLine, countInLines, beatLines)`.
    - It seeks the clock to `startLine - countInLines` with the new `RationalClock.seekToLineSigned()`, which allows negative lines. Negative lines trigger no clips (`collectActiveClipsAtLine` already ignores them), so the song pre-rolls where those lines exist and is silent before line 0.
    - It arms a `CountInClick`: a POD `@nogc nothrow pure @safe` one-voice decaying sine (1760 Hz accent on the first beat, 1320 Hz on the others, 18 ms decay). It is triggered sample-accurately from line-start tick events on every beat line before the start line, and added to the master output after the graph renders, so it never reaches modules, stems or WAV exports.
    - Stop, seek and `setPlaying(false)` silence and disarm it.
    - New `Engine.isCountingIn()`, `countInClicks()` and `EngineTelemetry.countingIn`. `static assert(!hasIndirections!CountInClick)` holds, and `Engine` stays free of GC references.
  - **Take capture (`app/live_take.d`, UI thread):** `LiveTakeRecorder` maps fractional song positions (line + tick / TPL) to the nearest line relative to the take start.
    - Notes less than one line after the first note of a chord group share its line on separate tracks. The window is measured from the group's first note, so a fast arpeggio does not merge into one long chord.
    - A new note goes to the lowest track that is not holding a note. When none is free, the oldest held note is cut.
    - A release writes `===` at its snapped line, at least one line after the note.
    - Notes more than half a line before the start (count-in) are dropped. The line cap is `MAX_LINES`.
    - `finish()` releases held notes and returns cells trimmed to whole 16-line bars, with at least 4 tracks.
  - **Session (`app/session.d`):**
    - `beginLiveTake()` suspends the Engine loop (the document loop is unchanged) and sends `playCountIn(start, 16, 4)`.
    - `liveTakeNoteOn()` / `liveTakeNoteOff()` timestamp notes from fresh Engine telemetry. They refuse module 0 and the Master Output.
    - `liveTakeShouldEnd()` returns true when playback stopped by other means or the take reached `MAX_LINES`.
    - `endLiveTake()` stops playback, restores the loop, seeks back to the take start, and adds a "Take NN" pattern plus a clip on the first lane free over the take, inside one `"Record Take"` undo group.
    - Also new: `liveTakeActive()`, `liveTakeStartLine()`, `liveTakeNoteCount()`, `liveSongPosition()`.
    - The headless `executeStudioAction` maps `recordToggle` to takes and the new `editToggle` to edit mode (`recording_` was renamed `editMode_`).
  - **Keymap and menus (`app/keymap.d`, `platform/macos/appkit.d`):** New document-level `StudioAction.editToggle = 41`, bound to ⇧⌘R, with a **Transport ▸ Edit Mode** menu item. ⌘R (`recordToggle`) now starts and stops a live take.
  - **Studio context (`gui/views/studio_context.d`):**
    - `recording` was renamed `editMode` (all views, the app and tests).
    - New `setEditMode()` (it ends a running take), `liveRecording()`, `countingIn()`, `startLiveRecord()` (requires an instrument module, otherwise "Select an instrument module to record"), `stopLiveRecord()` (selects the new pattern; status "Recorded Take NN (N notes)" or "Recording stopped: no notes recorded"), `toggleLiveRecord()`, `liveInputNoteOn()` / `liveInputNoteOff()`.
    - QWERTY holds (`setQwertyNote()` / `clearQwertyNote()`, used by both the pattern editor and the root) and MIDI note-on/off packets feed the take with distinct source tags.
    - `tick()` ends takes that should end and shows "Count-in N", then "Recording".
  - **Views:**
    - `studio_root.d`: ⌘R toggles live recording; ⇧⌘R toggles edit mode; Esc ends a take, otherwise leaves edit mode, otherwise stops; Play, Stop and Play Pattern during a take end it.
    - `transport_bar.d`: new **EDIT** button (`transport.edit`, lit in edit mode). **Rec** now toggles live recording and blinks on the beat during the count-in. Play, Stop and Pat end a take. The bar shifts right by one 44 pt button.
    - `pattern_editor.d`: the info text shows **EDIT** and/or **REC**, and double-click uses `setEditMode(true)` (status "Edit on").
    - `piano_view.d`: clicked keys feed the take.
    - `studio_app.d`: the GUI self-test's QWERTY step uses `transport.edit`.
  - **Docs:** `docs/manual.md`: menu, Escape, transport, edit-mode wording, renamed §8.9, new §8.11 *Live recording (Record mode)*, §12, the tutorial and the shortcut table.
- **Verification Results:**
  - **Engine (`tests/unit/sequencer_test.d`):** a count-in from line 0 starts at line −16 with `countingIn`. Exactly 4 clicks start within 2 frames of each beat (0, 4, 8, 12 lines × 5292 frames), the accent is louder, and output is bit-exact silence from line 0 on with no modules. The render loop runs inside `verifyZeroRtAllocationsNothrow` (`rt_malloc_trap`). Stop and seek disarm and silence the click.
  - **Take recorder (`tests/unit/live_take_test.d`):** snapping, count-in drop and tolerance, chord grouping, held-note track allocation, note-off placement, re-press, track stealing, the line cap, bar trimming and minimum tracks.
  - **End to end (`tests/unit/views_studio_root_test.d`):** ⌘R without an instrument is refused; edit mode turns off on ⌘R; the countdown status; song pre-roll plays a pattern note during the count-in; the loop at line 20 is ignored during the take and kept in the document; QWERTY note and chord capture with note-offs; Esc ends the take as one "Record Take" undo step with a clip on lane 1 and the playhead back at the take start; undo/redo; empty takes; ⇧⌘R ending a take; Space ending a take; an external stop ending a take.
  - **Piano and MIDI (`tests/unit/views_piano_test.d`):** MIDI note-on/off packets and on-screen piano clicks are recorded with velocities; MIDI notes during the count-in are dropped.
  - **Updated tests:** keymap (new binding, menu table, document-level list, `StudioAction.max`), transport EDIT/Rec buttons, root shortcuts, pattern editor status text.
  - `DFLAGS="-w" dub build --compiler=ldc2 --config=headless --force` and `--config=app --build=debug --force` both exit 0 with zero warnings. `dub test --compiler=ldc2 --config=app`: `4 modules passed unittests`.
  - `dub test --compiler=ldc2 --config=headless`: 25/26 modules pass. The one failure is the existing, unrelated `tests/unit/views_patchbay_test.d:824` (`menu should contain 'Add Core ▸'`).
  - Not run: `--studio-selftest` and `--studio-gui-selftest`, which need the audio device and a window. Live CoreAudio timing of the count-in click, and how responsive recording feels on real hardware, have not been checked.

---

## [2026-11-25 12:31:42 KST]
- **Author:** Claude Opus 5.5
- **Affected Files:** `source/gui/views/pattern_editor.d`, `source/gui/views/studio_root.d`, `tests/unit/views_pattern_editor_test.d`, `tests/unit/views_studio_root_test.d`, `docs/manual.md`, `docs/changelog.md`
- **Reason / Summary:** Three changes to pattern note entry and record (edit) mode.
  - **Master Output cannot receive notes (`gui/views/pattern_editor.d`):** Before, when the Master Output module (`core.output`) was selected in the patchbay, QWERTY, MIDI and on-screen piano input in record mode wrote notes with `MM = 01`. Note entry now checks the module that would be written, whether it comes from the patchbay selection, the cell's own module, or the nearest module above on the track. If it is the Master Output, nothing is written, the cursor does not move, no undo step is added, and the status bar shows `MASTER_OUTPUT_BLOCKED_STATUS` ("Master Output can't play notes; select an instrument module"). `writeNote()` also refuses it as a final check. Notes are still auditioned. Typing `01` into the MM hex field by hand is unchanged.
  - **Double-click a row to enter edit mode (`PatternEditorView.onMouseDown`):** A double-click (`clickCount >= 2`, no Shift) on the grid cancels any selection drag, puts the cursor on the **note** field of the clicked track and row, and turns `ctx.recording` on (status "Record on"; the transport **Rec** button lights up on the next frame). The next QWERTY, MIDI (step recording) or on-screen piano note is written to that row, and the cursor then advances by the edit step as before. A single click still only moves the cursor.
  - **Escape leaves edit mode (`StudioRoot.onKeyDown`):** Escape with no modifiers now turns record mode off (status "Record off") when it is on, before the keymap's `Esc = Stop` binding is checked, so playback keeps running. When record mode is already off, Escape stops playback as before. Widgets that already use Escape (open popups and menus, number-box editing, patchbay wire drags, timeline drags) still get it first, because they handle it before the key reaches the root.
  - **Docs:** `docs/manual.md` §2 (Escape), §8.3 (double-click), §8.4 (entering edit mode, leaving with Escape, Master Output rule) and the shortcut table.
- **Verification Results:**
  - New tests in `tests/unit/views_pattern_editor_test.d` cover the Master Output block for QWERTY input, MIDI step input and a module inherited from an earlier cell, and recovery once an instrument is selected. They also cover double-click entering edit mode on the note field with QWERTY and MIDI writes to the clicked row, a single click not enabling it, and double-click combined with a selected Master Output. A new `PeRig.doubleClick()` helper sends a real double-click; the rig's `mouse()` advances the clock on every press, so it never produces one.
  - `tests/unit/views_studio_root_test.d`: Escape with record on turns record off and keeps playback running; a second Escape stops playback; Shift+Escape does not leave record mode.
  - `DFLAGS="-w" dub build --compiler=ldc2 --config=headless --force` and `--config=app --build=debug --force` both exit 0 with zero warnings. `dub test --compiler=ldc2 --config=app`: `4 modules passed unittests`.
  - `dub test --compiler=ldc2 --config=headless`: 24/25 modules pass, including all new tests. The one failure is the existing, unrelated `tests/unit/views_patchbay_test.d:824` (`menu should contain 'Add Core ▸'`).
  - Not run: `--studio-gui-selftest`, which opens a window and plays audio. Its QWERTY record check uses instrument modules and single clicks, so these changes should not affect it.

---

## [2026-11-25 12:22:55 KST]
- **Author:** Claude Opus 5.5
- **Affected Files:** `source/gui/widgets.d`, `source/gui/views/param_rack.d`, `tests/unit/views_param_rack_test.d`, `docs/changelog.md`
- **Reason / Summary:** Fixed the module rack header **M / B / S** toggles, where the switch tracks covered the "M" and "B" labels.
  - **Cause:** `ParamRackView.layoutChildren()` gave each toggle a fixed 44 px slot with no gap. The switch track (16 px × 1.8 = 28.8 px) and the 8 px `spacingMd` caption gap leave about 7 px for the caption, but "M" and "B" in Atkinson Hyperlegible Next at `fontSizeBody` (13 px) are wider than that. The caption ran into the next slot, and the next toggle's track was painted over it. "S" is the rightmost toggle, so nothing covered it.
  - **Fix:** Added `Toggle.contentWidth(measurer, theme, height)`, which returns track + gap + measured caption width. The rack header now sizes each toggle from that width (minimum 44 px, so no toggle gets smaller), places them right to left with a 6 px gap (`HEADER_TOGGLE_GAP`), and clips the module title at the left edge of the toggle group instead of a fixed `w - 140`. `Toggle.measure()` is unchanged, so no other layout moves.
  - **Tests:** The test `FakeRasterizer` glyph advance can now be configured. Its default 0.5 em is narrow enough that "M" fit in the old 44 px slot, so the old test could not catch this bug. A new wide-glyph (0.85 em) rack test checks that each caption fits inside its toggle bounds and that the toggles do not overlap. It fails on the old layout and passes with the fix.
- **Verification Results:**
  - `DFLAGS="-w" dub build --compiler=ldc2 --config=headless --force` and `--config=app --build=debug --force` both exit 0 with zero warnings.
  - `dub test --compiler=ldc2 --config=app`: `4 modules passed unittests`.
  - `dub test --compiler=ldc2 --config=headless`: 24/25 modules pass, including the new test. The one failure is the existing, unrelated `tests/unit/views_patchbay_test.d:824` (`menu should contain 'Add Core ▸'`), which fails the same way on a clean tree.

---

## [2026-11-24 13:06:35 KST]
- **Author:** Gemini (Antigravity)
- **Reason / Summary:** Added a full-width, resizable, stark black-and-white high-contrast on-screen piano keyboard above the pattern editor and timeline panes, along with user manual documentation.
  - **Layout & resizing (`gui/layout.d`, `gui/views/studio_root.d`, `gui/views/piano_view.d`):** Docked `PianoKeyboardView` (`"piano.keyboard"`, `DEFAULT_HEIGHT = 60.0f`, `MIN_HEIGHT = 48.0f`) full-width between the upper (`patchbay` / `rack`+`scope`) and lower (`pattern` / `timeline`+`sample`) areas. Updated `DockLayout.beginDrag()`, `dragTo()`, and `endDrag()` with sibling-anchored same-axis split dragging so dragging the piano's top or bottom edge resizes only the adjacent panes 1:1 without shifting the opposite outer edge.
  - **Piano rendering, octave controls & proportional keys (`gui/views/piano_view.d`, `gui/theme.d`, `gui/appearance.d`):**
    - Leftmost key is always `C` of the shared `StudioContext.editOctave` (`-1..9`, default `4`), stopping at MIDI `127`. White key widths scale proportionally with strip height (`WHITE_KEY_ASPECT = 0.58f`, clamped to `[18.0f, 72.0f]`).
    - Every visible `C` key renders its octave number centered in the lower white-key zone below the black keys (`BLACK_KEY_HEIGHT_RATIO = 0.62f`).
    - Stacked `PianoOctaveButton` (`"piano.octaveUp"` / `"piano.octaveDown"`) sits on the far-right `36.0f` strip and updates `ctx.setEditOctave(...)`, staying synchronized with the transport `OCT` drag box, pattern editor, and `F1`/`F2` shortcuts.
    - Added stark black-and-white `StudioTheme` tokens (`pianoWhiteKey = #FFFFFF`, `pianoBlackKey = #000000`, `pianoKeyBorder = #000000`, `pianoKeyText = #000000`) and registered them in `gui/appearance.d` (`usedTextPairs()`, `usedGraphicPairs()`, `"Piano"` group). Pressed/active keys highlight in `theme.accent` (with `theme.accentText` on active `C` labels).
  - **Live playback, recording & multi-source highlighting (`sequencer/track_effects.d`, `sequencer/engine.d`, `app/session.d`, `app/audio_host.d`, `gui/views/{studio_context,pattern_editor,studio_root}.d`, `app/studio_app.d`):**
    - Mouse click/drag auditions notes with glissando on the selected module via `StudioSession.triggerLiveNote()` / `releaseLiveNote()` (`Engine.PIANO_KEY_TAG_BASE`) and injects `MidiNoteEvent` entries when `ctx.recording` is enabled. Releases cleanly on mouse-up, capture loss, octave change, module change, and Panic (`⌘.`).
    - Added `TrackEffectState.lastEmittedPitch`, `@nogc nothrow pure @safe` `TrackEffectBank.collectActiveNotes()`, atomic `Engine.setWatchedNoteModule()`, and `EngineTelemetry.patternNoteModuleId` / `patternNoteMask` / `isPatternNoteActive()` so active pattern playback notes targeting the currently selected module highlight on the piano alongside QWERTY holds and external MIDI input (`AudioHost.hasPendingMidi()`, `StudioContext.activeNoteMask()`).
  - **Documentation & tests:** Documented the on-screen piano in `docs/manual.md` (§2 layout diagram & §2.1 resizing, plus new §12.2 On-screen piano keyboard), added `tests/unit/views_piano_test.d`, updated `tests/unit/{gui_test,appearance_test,studio_backend_test,views_studio_root_test}.d`, and added the `"on-screen piano"` check to `runStudioGuiSelfTest()`.
- **Verification Results:**
  - Zero-warning builds: `DFLAGS="-w" dub build --compiler=ldc2 --config=headless --force` and `DFLAGS="-w" dub build --compiler=ldc2 --config=app --build=debug --force` both exited 0 with zero warnings.
  - `dub test --compiler=ldc2 --config=app`: `4 modules passed unittests`.
  - `caffeinate -dims ./build/dracker --studio-gui-selftest --quick`: `14/14 checks passed` (including `record notes (QWERTY)`, `playback stress (60+ fps)` at `120.0 fps` / `0 xruns`, and `on-screen piano`).
  - `dub test --compiler=ldc2 --config=headless`: 24/25 modules passed (all new and modified test modules passed; 1 pre-existing failure in untouched `tests/unit/views_patchbay_test.d:824` — `menu should contain 'Add Core ▸'` from commit `430cdc7`).
  - Rule 1 comment audit across all 18 created/modified `.d` files: `0` issues.
- **Affected Files:**
  - Created:
    - `dracker/source/gui/views/piano_view.d`
    - `dracker/tests/unit/views_piano_test.d`
  - Modified:
    - `dracker/source/sequencer/track_effects.d`
    - `dracker/source/sequencer/engine.d`
    - `dracker/source/app/session.d`
    - `dracker/source/app/audio_host.d`
    - `dracker/source/app/studio_app.d`
    - `dracker/source/gui/theme.d`
    - `dracker/source/gui/appearance.d`
    - `dracker/source/gui/layout.d`
    - `dracker/source/gui/views/studio_context.d`
    - `dracker/source/gui/views/transport_bar.d`
    - `dracker/source/gui/views/studio_root.d`
    - `dracker/source/gui/views/pattern_editor.d`
    - `dracker/tests/unit/gui_test.d`
    - `dracker/tests/unit/appearance_test.d`
    - `dracker/tests/unit/studio_backend_test.d`
    - `dracker/tests/unit/views_studio_root_test.d`
    - `dracker/docs/manual.md`
    - `dracker/docs/changelog.md`

---

## [2026-11-22 16:56:04 KST]
- **Author:** Claude Opus 5.5 (Claude Code)
- **Reason / Summary:** Added the user and beta-tester manual, `docs/manual.md`. Documentation only; no code changed.
  - Covers the studio window, every menu, shared control behavior, the transport, patchbay (adding, wiring and deleting modules), parameter rack (MIDI Learn, curve and envelope editors), pattern editor (cell fields, entry, selection, block operations, effect commands, recording), timeline (clips, clones, Supertracks, loop), sample editor, scope, live keyboard and MIDI, files (`.msv`, WAV export, sample and palette import), appearance and accessibility, undo, a tutorial, a shortcut reference, and a module reference.
  - Written from a code survey.
  - Appendix C lists 24 current limitations and quirks found during the survey, with suggested QA passes. Examples: no unsaved-changes prompt; "Cmd+J" menu label vs the real ⌘I; AIFF offered but not decodable; no pattern rename; DrumSynth notes 48/50 never reach the high-tom branch.
- **Affected Files:**
  - `dracker/docs/manual.md` (new)
  - `dracker/docs/changelog.md`

---

## [2026-11-22 16:27:11 KST]
- **Author:** Claude Opus 5.5 (Claude Code)
- **Reason / Summary:** Implemented **Phase 8.5: Accessible Appearance**. No UI geometry or font size changed; only font families, colors and contrast did.
  - **8.5.1 Appearance model.** `gui/theme.d` gained semantic tokens: transport lights, meters, scope traces, module categories, 8 clip colors, `clipText`, `mutedHatch`. It also gained `isLight`, `contrast`, `paletteName`, `textGamma`, `emphasize()`, `wireDash()`, `categoryColor()`, `clipColor()` and token-enumeration tables. `StudioTheme.init` is now "Light · High Contrast · Okabe–Ito"; `StudioTheme.dark()` was removed.
    - New `gui/appearance.d` provides:
      - the built-in palettes: Light · Okabe–Ito, Light · Tol Bright, Dark · Okabe–Ito, each with High or Low contrast
      - custom palettes, and `makeTheme()`, which keeps all metrics
      - the deterministic Low-contrast derivation
      - WCAG contrast, the drawn-pair inventory, Machado CVD simulation and CIEDE2000
      - categorical sets, palette-editor token groups and the contrast readout
      - strict versioned codecs for `appearance.cfg` and `.stpalette`
      - an atomic `FileAppearanceStore`
  - **8.5.2 Hard-coded colors and non-color cues.**
    - Hard-coded colors removed from: transport lit colors and meters, the timeline HSV hash, the gallery, and the Metal clear color.
    - `brighten()` hover/pressed effects replaced with `emphasize()`.
    - Wires carry dash styles: audio solid, sidechain doubled, event dashed, CV dotted.
    - Port glyph shapes: circle, double circle, square, diamond.
    - Clips show a letter A–H and a stripe pattern that match their color slot; muted nodes and clips are hatched.
    - Scope R trace is dashed, with an L/R legend.
    - The pattern grid uses a single tint per row, plus cursor and selection outlines.
    - Lit buttons and toggles get strong outlines.
  - **8.5.3 Fonts.**
    - `CoreTextRasterizer.setFonts()` resolves families with wght pinned to 400 and reports the source file.
    - `registerBundledFonts()` registers fonts at process scope; bundled copies win over installed ones.
    - `listFontFamilies(monospaceOnly)` and `isFixedPitchFamily()` added; missing families fall back to the system font with a status message.
    - `GlyphCache.reset()` added.
    - A glyph coverage gamma uniform was added to `ui2d.metal`.
    - `GuiShell` registers `resources/fonts/` (new, with a README) and selects Atkinson Hyperlegible Next and Fira Code before the first frame.
  - **8.5.4 Runtime switching.** `StudioContext.applyAppearance()` is the single apply path: theme, renderer clear color and gamma, fonts with cache flush, `themeRevision`, listeners, and persistence. It also adds `loadAppearance()` (defaults plus a status message on corrupt input), `saveAppearance()` and `toggleContrast()`. New `UiContext.setTheme()` relayouts, and `StudioRoot` syncs the UiContext through a theme listener.
  - **8.5.5 Menus and panel.**
    - New `StudioAction.openAppearance` (Cmd+,) and `StudioAction.toggleContrast` (Cmd+Option+C).
    - Menu items: Dracker ▸ Settings…, View ▸ Appearance…, and View ▸ High Contrast with a live checkmark (`MacApplication.setMenuItemChecked()`).
    - New `gui/views/appearance_panel.d`:
      - font, contrast and palette dropdowns
      - a custom palette editor (token groups, swatches, R/G/B/A boxes, live contrast readout with OK/BELOW text)
      - Duplicate, Rename, Delete, Reset, Import…, Export…, Revert and OK buttons
    - Preferences live in `~/Library/Application Support/Dracker/appearance.cfg`.
  - **Bug fix (pre-existing).** `MetalRenderer.syncAtlas()` deadlocked whenever the atlas texture had to be recreated, because the current frame already held a semaphore slot. It now drains only the other in-flight frames. The first studio self-test run hung on this after the font switch.
  - **8.5.6 Verification.**
    - `dub test --config=headless`: 24 modules passed, zero warnings. New tests:
      - `tests/unit/appearance_test.d`: contrast gate for all 6 appearances, ΔE ≥ 10 under 3 CVD simulations, metric invariance, math reference values, codec strictness, custom editing, store.
      - `tests/fuzz/appearance_fuzz.d`: 12,000 mutated inputs.
      - Studio-root integration: identical pane rectangles across switches, every view redrawn in new colors, Cmd+, / Cmd+Option+C, panel preview, OK, Revert and dismiss, reload, corrupt-preference fallback, missing-font status.
    - `dub test --config=app`: 4 modules passed. New tests:
      - Both default fonts resolve at wght 400 (Fira Code's file default is 331).
      - No ligatures: uniform mono advances for `---`, `===`, `->`.
      - Fallback, monospace-only listing, and bundled-before-installed.
      - Offscreen Metal render in the default theme: white background, text pixels ≥ 7:1, gamma effect.
      - Atlas recreation after `reset()`.
    - Self-tests:
      - `caffeinate -dims ./build/dracker --studio-gui-selftest` passed 13/13, full and `--quick`. New checks: "first launch appearance", "appearance panel (menu)" (Low contrast → Dark palette → another UI font → Revert, layout unchanged), and "contrast toggle + persistence".
      - Regressions: `--gui-selftest --quick` 13/13 and `--studio-selftest --quick` 5/5.
- **Affected Files:**
  - Created: `dracker/source/gui/appearance.d`, `dracker/source/gui/views/appearance_panel.d`, `dracker/tests/unit/appearance_test.d`, `dracker/tests/fuzz/appearance_fuzz.d`, `dracker/resources/fonts/README.md`
  - Modified:
    - `dracker/shaders/ui2d.metal`
    - `dracker/source/app/{gui_gallery,gui_shell,keymap,studio_app}.d`
    - `dracker/source/gui/{renderer,theme,widgets}.d`
    - `dracker/source/gui/views/{param_rack,patchbay_view,pattern_editor,scope_view,studio_context,studio_root,timeline_view,transport_bar}.d`
    - `dracker/source/platform/macos/{appkit,coretext,metal_renderer}.d`
    - `dracker/tests/unit/{gui_test,keymap_test,views_pattern_editor_test,views_studio_root_test}.d`
    - `dracker/agents.md`, `dev_plan.md`, `dracker/docs/changelog.md`

---

## [2026-11-22 14:30:15 KST]
- **Author:** Claude Opus 5.5 (Claude Code)
- **Reason / Summary:** Owner revision: the monospace font is **Fira Code** (installed) instead of Fira Mono (not installed). Documentation only; no code changed.
  - Every Phase 8.5 and Phase 9 reference in `dev_plan.md` and `agents.md` now names Fira Code.
  - Fira Code's variable default instance is Light (300), so the plan requires requesting and verifying Regular (400) for low-vision legibility; the same applies to Atkinson Hyperlegible Next.
  - Programming ligatures don't apply because the rasterizer draws glyphs per code point; a test pins this.
  - Both fonts are installed per-user, so Phase 8.5 can use them directly.
  - Recorded a Phase 9.1 prerequisite: the OFL license texts for both fonts are not on disk and must be obtained from the official upstreams before packaging.
- **Affected Files:**
  - `dev_plan.md`
  - `dracker/agents.md`
  - `dracker/docs/changelog.md`

---

## [2026-11-22 14:28:09 KST]
- **Author:** Claude Opus 5.5 (Claude Code)
- **Reason / Summary:** Recorded owner decisions for Phase 8.5 and Phase 9. Documentation only; no code changed.
  - Monospace font: **Fira Mono**.
  - Phase 9.1 bundles Atkinson Hyperlegible Next and Fira Mono plus their OFL 1.1 license texts in `Contents/Resources/Fonts`, with `ATSApplicationFontsPath`. The build fails if any file is missing, and the Phase 9 exit criteria now require the resolved font URLs to point inside the bundle.
  - Low contrast floor confirmed at 4.5:1 for text.
  - Phase 8.5.3 now registers bundled fonts at process scope (`resources/fonts/` in dev builds, `Contents/Resources/Fonts` in the app) before checking installed fonts and the system fallback. The UI and tests prefer Fira Mono for monospace text.
  - Readiness finding: Fira Mono is **not** installed on the development machine (only Fira Code is), so its files must be installed or approved for fetching from the official upstream before 8.5.3.
- **Affected Files:**
  - `dracker/agents.md`
  - `dev_plan.md`
  - `dracker/docs/changelog.md`

---

## [2026-11-22 14:23:26 KST]
- **Author:** Claude Opus 5.5 (Claude Code)
- **Reason / Summary:** Planned Phase 8.5 (Accessible Appearance) at the owner's request before Phase 9. This entry covers documentation only; no code changed.
  - **Defaults:** light high-contrast mode, Atkinson Hyperlegible Next as the UI font, and a colorblind-safe palette derived from Okabe–Ito. Font sizes and UI geometry stay unchanged.
  - **Appearance menu:** UI and monospace font, High/Low contrast, palette presets, a custom palette editor, and persistent preferences.
  - **Subtasks `8.5.1`–`8.5.6`:**
    - the appearance model and palettes
    - removal of dark-mode assumptions, hard-coded colors, and color-only cues
    - CoreText font-family selection
    - runtime theme switching
    - the Appearance menu/panel and persistence
    - verification
  - **Gates:** WCAG AAA 7:1 text / 4.5:1 graphics in High contrast; 4.5:1 / 3:1 in Low contrast; CIEDE2000 ΔE ≥ 10 under simulated protanopia, deuteranopia, and tritanopia; theme metrics and layout bit-identical to Phase 8.
  - **Findings recorded in the plan:**
    - Atkinson Hyperlegible Next is installed per-user as a variable font.
    - Views already use theme tokens almost everywhere. The remaining hard-coded or dark-assuming colors are in the widget `brighten()` hover logic, transport lit colors, the timeline's HSV pattern colors, the gallery, and the Metal clear color.
    - Several Okabe–Ito mid tones are only about 3:1 on white, so darkened variants are specified.
  - Phase 9 now depends on Phase 8.5.
- **Affected Files:**
  - `dracker/agents.md`
  - `dev_plan.md`
  - `dracker/docs/changelog.md`

---

## [2026-11-22 14:12:26 KST]
- **Author:** Claude Opus 5.5 (Claude Code), with five Claude subagents implementing the views in parallel (8.1 transport/scope, 8.2 patchbay, 8.3 parameter rack/sample editor, 8.4 pattern editor, 8.5 timeline)
- **Reason / Summary:** Implemented Phase 8 (Modular Synth Tracker Studio GUI).
  - **Shared contract** `gui/views/studio_context.d`. `StudioContext` holds:
    - the session, theme and selection state (selected module, current pattern, record, follow, step, octave)
    - per-frame telemetry and `ScopeHistory`, scope-tap requests and the live MIDI note queue
    - the status line, plus `IAudioControl` and `IStudioClipboard` interfaces so every view is headless-testable
  - **Session.** `StudioSession.documentRevision()` lets views cache by revision, and `setCurrentOctave()` keeps the live-piano octave synced with the editor octave.
  - **8.1** `TransportBarView`:
    - transport, record, follow and loop buttons
    - BPM/TPL drag boxes (one undo step per drag), octave and step boxes, the position readout and a dirty dot
    - DSP load, xruns, master meters with clip hold, and the device/MIDI pickers
  - **8.1** `ScopeView`: oscilloscope with trigger, log-frequency spectrum with peak hold, goniometer, and master or selected-module source.
  - **8.2** `PatchbayView`:
    - zoom/pan node graph with typed, colored ports and Bezier wires, signal pulses, mute/solo/bypass badges
    - registry add-module menus, node and wire context menus, port-drag wiring with compatibility checks, wire/module delete
    - inline mini-scopes
  - **8.3** `ParamRackView`:
    - controls generated from @Param (slider, log slider, toggle, dropdown) with one undo step per gesture
    - MIDI learn and unmapping, curve editors for WaveShaper/MultiSynth/MultiCtl, an ADSR envelope editor
    - MetaModule drill-down (child edits are not undoable)
  - **8.3** `SampleEditorView`: slots, waveform, zoom, loop markers, loop mode, note range, an amplitude envelope, and import through the file dialog.
  - **8.4** `PatternEditorView`:
    - the `NN VV MM CCEE XXYY` grid, drawing only what is visible
    - cursor fields, block selection, QWERTY entry and audition, hex nibble editing
    - live and step MIDI recording
    - cut/copy/paste through the `Dracker-Block-v1` clipboard, plus transpose and interpolate, each one undo step
    - follow playhead, and pattern add/duplicate/delete/resize/switch
  - **8.5** `TimelineView`:
    - lanes, ruler and playhead, clip move/resize/Alt-clone with one undo step each
    - clip menus (mute, solo, Supertrack, make unique, loop to clip, delete) and lane header toggles
    - loop strip, ruler seek, zoom/pan, follow, and drawing that skips off-screen clips
  - **8.6** Integration:
    - `gui/views/studio_root.d` docks every view in a resizable split layout with a status bar. Keymap shortcuts go to the session or root (document level), to the app handler (new, open, save, export, quit), or to the focused or last-used view. Piano keys with no handler play live notes.
    - `app/studio_app.d` covers the scene, the `AudioHost`/clipboard adapters, dialog-driven commands, window-title sync and background polling of MIDI and devices.
    - The app now launches the studio by default (`--gallery` keeps the Phase 7 gallery).
    - `--studio-gui-selftest` runs the whole workflow purely through synthetic window input.
  - **Build.** `dub.json` headless now builds and tests `gui/views/`. `appkit.d`: synthetic mouse events take modifiers, and synthetic scroll can target a point.
  - **Known gaps:**
    - The timeline can't trim from the left edge or point a clip at another pattern (no session API); Make Unique re-creates the clip.
    - The patchbay has no rename (no text field widget), and Duplicate doesn't copy a module's extra data.
    - Logarithmic params with min <= 0 floor at max/1000.
    - MetaModule drill-down goes one level deep and its edits aren't undoable.
    - `ScopeHistory.snapshot` allocates a little per visible scope each frame.
    - The device list refreshes when its popup opens, not on hot-plug events.
    - Tab defaults to note-off (Shift+Tab and Alt+arrows move between tracks).
    - The end-to-end test uses scripted file dialogs; the native sheets were verified in Phase 7.
- **Verification Results:**
  - `dub test --config=headless`: 22 modules passed, including 74 new view/integration unittest blocks across 8 view test files.
  - `DFLAGS="-unittest -O3 -w"`: headless 23 modules and app 5 modules passed, zero warnings.
  - x86_64 cross-compiles (`HeadlessCore` and `StudioGUI`) pass, and the comment audit is clean.
  - `caffeinate -dims ./build/dracker --studio-gui-selftest` (full, Apple M5 Pro, 120 Hz Retina, live CoreAudio) passed 10/10:
    - added AnalogGen, FM synth and Echo through the patchbay menus; wired three cables by port drags
    - cutoff drag in the rack; 64 notes recorded by QWERTY across 4 tracks
    - Alt-drag clone plus Supertrack through the timeline menu
    - Unison 4 and an 8 s Release set through the rack
    - 10 s playback stress with node drags, scrolling and live 6-note chords: 118.9 fps, 0 xruns, DSP peak 27.4 %, level 0.598
    - Cmd+S, Cmd+N, Cmd+O restored 4 modules, 3 wires and 2 clips; Cmd+E exported a 764,928-frame WAV
  - Regression runs: `--studio-selftest --quick` 5/5 and `--gui-selftest --quick` 13/13.
- **Affected Files:**
  - `dracker/source/gui/views/{studio_context,studio_root}.d` and `dracker/source/app/studio_app.d` (created)
  - `dracker/source/gui/views/{transport_bar,scope_view,patchbay_view,param_rack,sample_editor,pattern_editor,timeline_view}.d`
  - `dracker/tests/unit/views_{transport,patchbay,param_rack,sample_editor,pattern_editor,timeline,studio_root}_test.d` (created)
  - `dracker/source/app/session.d`, `dracker/source/main.d`, `dracker/source/platform/macos/appkit.d`, `dracker/dub.json`
  - `dracker/agents.md`, `dracker/docs/changelog.md`

---

## [2026-11-22 13:17:47 KST]
- **Author:** Claude Opus 5.5 (Claude Code), with a Claude subagent implementing `app/pattern_ops.d`, the block clipboard codec/fuzzer, and the keymap expansion
- **Reason / Summary:** Implemented Phase 7.5 (Studio Backend Integration) per the owner-approved design in `dev_plan.md`.
  - `7.5.1` The session `Engine` is now calloc-allocated (`dispose()` / finalizer free it). New `app/audio_host.d`:
    - `EngineRtContext` is unmanaged and statically asserted GC-free.
    - The `@nogc nothrow` `renderHostBufferRt`/`engineRenderCallback` bridge does the MIDI drain, renders through `processHostBuffer` with duplex input, and measures DSP load.
    - `AudioHost` owns CoreAudio + CoreMIDI. It handles device selection, follows the device sample rate via the new `StudioSession.changeSampleRate()` (document, ids, path, dirty flag and undo history are preserved), and recovers hot-plugged MIDI sources and device changes.
  - `7.5.2` RT-thread MIDI:
    - Notes become live voices on the MIDI target module (`Engine.liveNoteOnRt` / `liveNoteOffRt`).
    - CCs go through `MidiMapSnapshot` (`EngineCmdKind.swapMidiMap` + retire). Other messages become ModEvents (`enqueueLiveEventRt`).
    - A copy goes to a UI ring. `StudioSession` adds MIDI learn, undoable mappings, document mirroring of mapped values, and note reports for recording.
    - New optional `.msv` `MIDI` chunk, validated on save and load, and covered by the fuzzer.
  - `7.5.3` `EngineCmdKind.setScopeTaps` (master + 4 modules) publishes `ScopeBlock`s to an `SpscRing` (512 blocks, drops counted). New `app/telemetry.d` provides `ScopeHistory` (snapshots, gap detection, Hann/FFT dBFS spectra) and `StudioTelemetry`.
  - `7.5.4` `StudioSession` operations:
    - transport (play, stop, toggle, seek, transient `playPattern` audition) and undoable `doSetLoop`
    - pattern add, duplicate, remove (clips restored on undo) and rename
    - module mute, bypass, rename and transient solo
    - live asset replacement via the new generic `ModuleVTable.buildAssetsFromExtra` (6 modules declare `ASSET_SLOT_COUNT`/`assetDestroyFn`), plus `doLoadSample` and `samplePeaks`
    - an off-thread `ExportJob` (separate Engine, 32-bit float WAV + stems, progress and cancel)
  - `7.5.5` `UndoHistory.beginGroup`/`endGroup` + `CompoundCommand` (atomic rollback on failure, nested groups flatten), `DelegateCommand`, `doReplacePatternCells`. New `app/pattern_ops.d`: blocks, transpose, interpolate, and the `Dracker-Block-v1` codec.
  - `7.5.6` `keymap.d`: 24 new `StudioAction`s whose default bindings match the menu key equivalents, `addBinding`, `hasConflicts`, `shadowsPianoKey`, `StudioCommandSink`, `isDocumentLevel`, `forwardToSink`. The session handles `playPattern`.
  - `7.5.7` New `tests/unit/studio_backend_test.d`, `tests/unit/pattern_ops_test.d`, `tests/unit/keymap_test.d`, and `tests/fuzz/block_text_fuzz.d` (20,000 inputs). The MIDI chunk was added to the `project_format_fuzz.d` seed. New `--studio-selftest` (`app/studio_selftest.d`).
  - **Deviations from the design:**
    - Live MIDI is applied at host-buffer offset 0, because `AudioRenderCallback` carries no host timestamp. This adds at most one buffer of latency.
    - Solo mutes only `synth`-category modules, so effect chains of soloed sources keep running.
    - `Keymap.bindAction` now also clears the action's extra bindings.
- **Verification Results:**
  - `dub test --config=headless`: 15 modules passed.
  - `DFLAGS="-unittest -O3 -w"`: headless 16 modules and app 5 modules passed, with zero warnings.
  - The render bridge (MIDI notes, MIDI-map CC, UI copy, scope push, load telemetry) runs inside `verifyZeroRtAllocationsNothrow`.
  - The x86_64 cross-compiles (`HeadlessCore` and `StudioGUI`) pass, the comment audit is clean, and the headless `--cli-demo` had 0 xruns.
  - `./build/dracker --studio-selftest` (full) passed 5/5:
    - 30 s @64 frames: 20,674 callbacks, 0 xruns, 2,503 concurrent UI edits, DSP load avg 3.8 % / peak 9.1 %
    - 30 s @128 frames: 0 xruns, 2,478 edits
    - MIDI-in -> rendered audio latency: 0.54 ms
    - a forced 48 kHz mismatch was restored to the 44.1 kHz device rate and playback resumed
    - export bit-identical to an offline render
- **Affected Files:**
  - `dracker/source/app/{audio_host,telemetry,pattern_ops,studio_selftest}.d` (created)
  - `dracker/source/app/{session,history,keymap}.d`
  - `dracker/source/sequencer/engine.d`, `dracker/source/graph/{audio_graph,module_api}.d`, `dracker/source/io/project_format.d`
  - `dracker/source/modules/{effects/waveshaper,control/multisynth,control/multictl,synths/analog_gen,synths/spectravoice,synths/sampler}.d`
  - `dracker/source/main.d`
  - `dracker/tests/unit/{studio_backend_test,pattern_ops_test,keymap_test}.d`, `dracker/tests/fuzz/block_text_fuzz.d` (created), `dracker/tests/fuzz/project_format_fuzz.d`
  - `dracker/agents.md`, `dracker/docs/changelog.md`

---

## [2026-11-22 12:56:07 KST]
- **Author:** Claude Opus 5.5 (Claude Code)
- **Reason / Summary:** Owner decisions after the Phase 8 readiness check: mark Phase 7 complete with the 100k-frame autorelease soak waived, and insert a new Phase 7.5 for the backend pieces Phase 8 needs. Documentation and design only; no code changed.
  - Phase 7 and subtasks `7.1`–`7.5` marked `[x]` in `agents.md`, with a sign-off note recording the waived soak result (malloc flat for 9/10 intervals, one unexplained +127 KB / +1,489-block step in the final interval; GC heap +0 KB). This supersedes the "Phase 7 remains `[ ]`" status in the previous entry.
  - Added Phase 7.5 (Studio Backend Integration, subtasks `7.5.1`–`7.5.7`) to `agents.md` (checklist + exit criteria) and its full design to `dev_plan.md`:
    - unmanaged `Engine` ownership with a `@nogc nothrow` CoreAudio render bridge (`app/audio_host.d`, `EngineRtContext`), sample-rate follow and hot-unplug recovery;
    - live MIDI drained on the RT thread, MIDI target module, MIDI learn (`.msv` `MIDI` chunk, `MidiMapSnapshot` swap);
    - scope/spectrum taps (`ScopeBlock` ring, `app/telemetry.d`) and DSP load telemetry;
    - session transport, loop, pattern, module, live-asset (`buildAssetsFromExtra`), sample import, and off-thread export operations;
    - grouped undo with atomic rollback, pattern block operations, and the `Dracker-Block-v1` clipboard codec (`app/pattern_ops.d`);
    - keymap expansion and `StudioCommandSink`;
    - verification, including `--studio-selftest`.
  - Phase 8 now depends on Phase 7.5. The `agents.md` UI ↔ RT mutation table gained rows for the audio host, live MIDI, MIDI map, and scope taps, and the package map lists the planned `app/` files. The `dev_plan.md` schedule table and totals were updated.
  - Rule 5: `7.5.1`–`7.5.3` change the UI ↔ RT boundary and are flagged as needing owner approval of the design before implementation.
- **Affected Files:**
  - `dracker/agents.md`
  - `dev_plan.md`
  - `dracker/docs/changelog.md`

---

## [2026-11-22 12:10:30 KST]
- **Author:** Claude Opus 5.5 (Claude Code), with a Claude subagent implementing `7.5`
- **Reason / Summary:** Implemented Phase 7 (Native macOS AppKit/Metal Shell & Pure-D UI Toolkit). Phase 7 remains `[ ]` in `agents.md`: one exit-criterion check (memory soak tail) is unresolved, see Verification.
  - `7.1` `objc_runtime.d`: typed `objc_msgSend`/`objc_msgSendSuper` trampolines (x86_64 `_stret` for >16-byte struct returns), `RuntimeClassBuilder` (runtime subclassing with ivars/protocols, idempotent), ivar context pointers, NSString conversion, retain/release/autorelease, `ScopedAutoreleasePool`; extern(C) bindings for the existing `objc_blocks_shim.m`.
  - `7.2` `appkit.d`: `MacApplication` (regular foreground app, File/Edit/Transport/View/Window menu bar; menu commands are delivered as the same keyDown keyCode+KeyModifiers the keymap binds, Quit -> `closeRequested`), `MacWindow : IPlatformWindow` (runtime `STHostView` flipped NSView hosting a CAMetalLayer; raw keyDown/keyUp/repeat + modifier flagsChanged; mouse buttons/drag/move; precise trackpad scroll and pinch; `NSTextInputClient` IME commit + marked text; Retina backing-scale tracking; live-resize render hook; occlusion tracking; blocking `waitEvents()` for idle; pasteboard text), `MacFileDialog : IFileDialog` (NSOpenPanel/NSSavePanel window-modal sheets via the Block shim, UTType filters), and self-test diagnostics (synthetic NSEvent/CGEvent injection, malloc/footprint/CPU probes).
  - `7.3` `coretext.d`: `CoreTextRasterizer : IGlyphRasterizer` (system UI + user fixed-pitch fonts at exact physical pixel sizes, R8 coverage bitmaps, CTFontCreateForString fallback, surrogate pairs).
  - `7.4` `gui/renderer.d` (backend-agnostic `IRenderer2D`, 96-byte `UIInstance`, `DrawList` with scissor/texture command runs, `BatchRenderer2D`, `GlyphCache` + `ShelfAtlasPacker` growable R8 atlas, `HeadlessRenderer`), `shaders/ui2d.metal` (instanced SDF rounded rect/border/gradient, pixel-space R8 glyphs, RGBA images, anti-aliased round-capped segments, premultiplied alpha), `metal_renderer.d` (`MetalRenderer`: metallib if present else runtime compilation of the embedded shader source, triple-buffered instance buffers paced by a dispatch semaphore signalled from command-buffer completion, dirty-row atlas uploads, RGBA textures, offscreen render + read-back).
  - `7.5` `gui/theme.d`, `gui/layout.d`, `gui/widgets.d`: `StudioTheme`; flex layout, `SplitPaneNode`/`DockLayout`; retained `Widget` tree + `UiContext` (hit-testing, capture, hover, focus/Tab traversal, overlays, double-click, context menus, dirty/animating flags) with Panel, Label, Button, Toggle, Slider (log/fine/reset), RotaryKnob, NumericDragBox, Dropdown, ContextMenu, ScrollView + scrollbars, SplitView, CurveEditor, EnvelopeEditor.
  - Shell: `app/gui_shell.d` (`GuiShell` main loop: blocking waits when idle, display-paced rendering while animating, no rendering while occluded; `--gui-selftest`), `app/gui_gallery.d` (toolkit + renderer gallery scene); `main.d` launches the shell by default in `app` builds.
  - Build: `dub.json` `app` config only precompiles `ui2d.metallib` when `xcrun metal` exists (this machine has Command Line Tools only) and string-imports `shaders/`; `headless` now builds and tests the pure-D toolkit (only `gui/views/` stays excluded).
  - Review follow-ups: atlas `pack()` no longer mutates on failure; the clip stack is unbounded and pops symmetrically.
- **Verification Results:**
  - `dub test --config=headless`: 11 modules passed (incl. 35-block `tests/unit/gui_test.d`); `DFLAGS="-unittest -O3 -w"`: 12 passed, zero warnings.
  - `DFLAGS="-unittest -O3 -w" dub test --config=app`: 5 modules passed (Objective-C runtime subclass/ivar/super/struct-return, CoreText glyphs/fallbacks, Metal GPU pixel read-back of shapes/borders/clip/lines/text/textures, AppKit helpers).
  - `x86_64-apple-macos12.0 -O3 -w -unittest` cross-compile of all sources with `StudioGUI`; `clang -Wall -Wextra` shim check; no `//` comments in new files; headless `--cli-demo` regression (0 xruns).
  - `caffeinate -dims ./build/dracker --gui-selftest` (Apple M5 Pro, 120 Hz Retina, final build): 12/13 PASS — window/Retina 2200x1440 @2x (runtime-compiled shader), 8 menu key equivalents, raw keyDown/text/keyUp/Shift flagsChanged/repeat order, Cmd+Z / Cmd+Shift+Z / Cmd+Q routed once each, flipped mouse coordinates, trackpad scroll, toolkit toggle/context menu/Escape via real events, private-pasteboard clipboard, open/save sheets attached and cancelled, resize to 1800x1200 px, 118-120 fps display-paced, idle CPU 0.06-2.11 % across runs.
  - **Open:** the 100,000-frame soak (100,000 presented frames, 834 s, 120.0 fps; GC heap +0 KB) failed its own tail criterion: malloc stayed flat (+0 to +31 KB) for 9 of 10 checkpoint intervals, then stepped +127 KB / +1,489 blocks in the final interval. A per-frame leak would grow in every interval, so this looks like a one-off allocation burst, but it has not been explained, so Phase 7 stays unchecked pending owner review.
- **Affected Files:**
  - `dracker/source/platform/macos/{objc_runtime,appkit,coretext,metal_renderer}.d`
  - `dracker/shaders/ui2d.metal`
  - `dracker/source/gui/{renderer,theme,layout,widgets}.d`
  - `dracker/source/app/gui_shell.d`, `dracker/source/app/gui_gallery.d` (created)
  - `dracker/tests/unit/gui_test.d` (created)
  - `dracker/source/main.d`, `dracker/dub.json`, `dracker/agents.md`, `dracker/docs/changelog.md`

---

## [2026-11-22 10:15:35 KST]
- **Author:** Claude Opus 5.5 (Claude Code)
- **Reason / Summary:** Phase 6 review remediation. An independent review of the uncommitted Phase 6 work found nine defects (RT use-after-free, stale saves, unreloadable saves, pattern-slot overflow/leak, live-engine teardown, ignored push/compile failures, SunVox note mis-targeting, unbounded undo coalescing, vacuous tests). Phase 6 was reverted to `[ ]` until all were fixed and verified, with owner approval for the UI/RT boundary changes (Rule 5).
  - **RT module retirement:** removed modules are now tagged with the `GraphPlan` that still references them and freed only after that exact plan returns through the retire ring (`Engine.tryPopRetired()`), replacing the unsafe "free when stopped or when anything retired" heuristic.
  - **Save source of truth:** parameter values are saved from the document; module asset blobs are read only after `StudioSession.synchronizeEngine()` (new `EngineCmdKind.fence` + `Engine.appliedFence()` acquire/release round-trip while audio runs, `Engine.applyPendingCommandsOffRT()` when it does not). MetaModule state is saved from the document (its live `serializeExtra` reads RT-mutated child tempo).
  - **Save/load parity:** `serializeProject`/`serializePreset` now run `validateProjectForSave`/`validateModuleForSave` (tempo range, finite params/macros, string/blob caps, nesting depth incl. child re-parse, duplicate module/pattern ids); loader rejects duplicate ids; `MAX_CELLS_PER_PATTERN = MAX_TRACKS * MAX_LINES`; `doSetTempo`/`doSetParam`/`doResizePattern` reject out-of-range input.
  - **Pattern slots:** `MAX_PATTERNS` now equals `Engine.MAX_PATTERNS` (256); `materializeProjectToEngine` frees and fails on a rejected pattern attach; XM cap statically asserted against it.
  - **Engine teardown:** `StudioSession.attachAudioDriver(IAudioDriver)`; load/new-project/shutdown stop the driver before tearing down the Engine and restart it afterwards; `immediate` attach paths fall back to queued commands while audio runs; loaded projects recompile their plan through the session so plan guards are known.
  - **All-or-nothing mutations:** `IUndoCommand.execute/undo` return `bool`; every `*Direct` mutator rolls the document back if its plan/snapshot/command cannot reach the Engine (`sendCommand` drains or waits instead of dropping); `UndoHistory` records only successful commands and leaves stacks unchanged on failed undo/redo.
  - **Undo coalescing:** merges additionally require consecutive pushes within a 500 ms window (`setCoalesceWindow`, deterministic `pushAndExecuteAt`).
  - **SunVox importer:** pattern cells keep raw module indices and are remapped through `indexToId`; notes aimed at skipped modules are cleared and counted in `ImportReport.droppedNoteTargets`.
  - **Tests:** new `tests/unit/session_safety_test.d` (plan-guarded retirement, save-without-render, a threaded `IAudioDriver` rendering concurrently through 40 add/wire/param/patch/remove cycles + fenced save + suspended load/new-project, save validation incl. 64x4096 pattern round-trip, 256/257 pattern caps, failure-aware undo/redo, time-window coalescing, SunVox remap); `persistence_test.d` gains a bit-exact `.msym` (WaveShaper curve + nested MetaModule) render-parity test with a non-vacuity control; the fuzz harness hand-encodes over-deep MetaModule files (asserts 16 levels accepted, 17 rejected), and materializes + renders every accepted mutated project.
- **Verification Results:**
  - `dub test --compiler=ldc2 --config=headless --force`: 10 modules passed; 15 consecutive reruns of the test binary all passed (threaded driver suite stable).
  - `DFLAGS="-unittest -O3 -w" dub test --compiler=ldc2 --config=headless --force`: 11 modules passed, zero warnings.
  - Mutation checks: reverting guarded retirement and inverting the `.msym` control assertion each make the suite fail.
  - `dub build --config=headless --build=release` + `--cli-demo --duration=0.35 --auto-chord` (120 callbacks, 15,360 frames, 0 xruns); `x86_64-apple-macos12.0 -O3 -w -unittest` cross-compile OK; DDoc-only comment audit, `clang -Wall -Wextra` shim check, `plutil -lint`, and `bash -n` all passed.
- **Affected Files:**
  - `dracker/source/sequencer/engine.d`
  - `dracker/source/io/project_format.d`
  - `dracker/source/io/importers/sunvox_importer.d`
  - `dracker/source/io/importers/xm_importer.d`
  - `dracker/source/app/history.d`
  - `dracker/source/app/session.d`
  - `dracker/tests/fuzz/project_format_fuzz.d`
  - `dracker/tests/unit/persistence_test.d`
  - `dracker/tests/unit/session_safety_test.d` (created)
  - `dracker/agents.md`
  - `dracker/docs/changelog.md`

---

## [2026-11-22 09:52:12 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Reason / Summary:** Completed Phase 6 (Native Persistence, Undo/Redo, Session Bridge & Optional Importers).
  - Implemented `source/io/binary_stream.d` (`BinaryReader` and `BinaryWriter`) with `@safe` overflow-safe bounds checking, LE/BE integer & IEEE-754 float codecs, MIDI VLQ decoding, FourCC helpers, and isolated `readChunk`/`writeChunk` framing.
  - Implemented `source/io/project_format.d` (`MSV1` `.msv` project and `MSYM` `.msym` module/MetaModule preset formats) with unknown-chunk forward-compatibility skipping, recursion depth enforcement (`MAX_METAMODULE_DEPTH`), and `materializeProjectToEngine`.
  - Implemented `source/app/keymap.d` (macOS 29-key two-octave QWERTY tracker piano + `StudioAction` bindings), `source/app/history.d` (`IUndoCommand`, `UndoHistory` with drag coalescing and 14 concrete commands), and `source/app/session.d` (`StudioSession` bridging UI/CLI actions, persistence, importers, `UndoHistory`, and lock-free `Engine` snapshot/command dispatch + `pollRetiredAndTelemetry`).
  - Implemented optional importers in `source/io/importers/{smf,xm,sunvox}_importer.d` supporting Standard MIDI Files (`.mid` Format 0/1 with sub-line delay quantization and channel 9 drum kit mapping), FastTracker II (`.xm` packed patterns and 8/16-bit delta PCM samples mapped to `synth.sampler`), and best-effort `.sunvox` (`SVOX`) structural import with `ImportReport` diagnostics.
  - Added `tests/fuzz/project_format_fuzz.d` executing 100,000 deterministic mutation/truncation/corruption/overflow/NaN/deep-nesting runs across `.msv`, `.msym`, `.mid`, `.xm`, and `.sunvox` parsers, plus `tests/unit/persistence_test.d` verifying stream bounds, bit-exact `.msv`/`.msym` WAV round-trips (`Sampler`, `WaveShaper`, `Echo`, `AnalogGen`, nested `MetaModule`, unknown `FUTR` chunk), `UndoHistory`/`StudioSession`/`Keymap` with `verifyZeroRtAllocationsNothrow`, and all three optional importers.
  - Marked Phase 6 and subtasks `6.1`–`6.5` as completed `[x]` in `dracker/agents.md`.
- **Verification Results:**
  - `dub test --compiler=ldc2 --config=headless --force --skip-registry=all`: 9 modules passed unittests (`120` `__unittest` symbols via `nm`).
  - `DFLAGS="-unittest -O3 -w" dub test --compiler=ldc2 --config=headless --force --skip-registry=all`: 10 modules passed unittests with zero warnings.
  - `dub build --compiler=ldc2 --config=headless --build=release --force --skip-registry=all`, `./build/dracker --list-devices`, and `./build/dracker --cli-demo --duration=0.35 --auto-chord` (122 callbacks, 15,616 frames, 0 xruns) passed cleanly.
  - `x86_64-apple-macos12.0` `-O3 -w -unittest` cross-compile passed (`X86_64_COMPILE_OK`).
  - Strict DDoc-only comment audit (`PHASE6_COMMENT_AUDIT_OK: 10 files`), `plutil -lint packaging/macos/Info.plist`, `clang -Wall -Wextra -fsyntax-only source/platform/macos/objc_blocks_shim.m`, and `bash -n` script check all passed.
- **Affected Files:**
  - `dracker/source/io/binary_stream.d`
  - `dracker/source/io/project_format.d`
  - `dracker/source/io/importers/smf_importer.d`
  - `dracker/source/io/importers/xm_importer.d`
  - `dracker/source/io/importers/sunvox_importer.d`
  - `dracker/source/app/keymap.d`
  - `dracker/source/app/history.d`
  - `dracker/source/app/session.d`
  - `dracker/tests/fuzz/project_format_fuzz.d`
  - `dracker/tests/unit/persistence_test.d`
  - `dracker/agents.md`
  - `dracker/docs/changelog.md`

---

## [2026-11-22 09:33:25 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Summary:** Implemented Phase 5 (Tracker Sequencer, Timeline, Supertracks & `MetaModule`) with 8-byte POD `NoteCell` atomic pattern patching, Copy-on-Write `PatternSnapshot` & `TimelineSnapshot` (pattern clones, mute/solo, loops, persistent-lane Supertracks), drift-free 64-bit `RationalClock`, full `TrackEffectBank` effect suite including exact sample-frame sub-line delays (`0x40`–`0x5F`), unified instance-scoped `Engine` with lock-free commands/retire queue & per-module stem WAV export, and re-entrant nested `MetaModule` (`ctl.metamodule`, `MAX_METAMODULE_DEPTH = 16`, 39 built-in registered modules).
- **Changes & Verification:**
  - Graph Protocol Extensions: extended `ProcessContext` with `metaDepth`, added `ModEventKind.setParamNormalized` + `ModuleVTable.setParamNormalized` (mapping `[0..1]` across linear/logarithmic/discrete `@Param` descriptors in `ModuleAdapter!T`), extended `RetiredKind` with `patternSnapshot`/`timelineSnapshot`/`childEngine`, and added `setNodeMuted`, `setNodeBypassed`, `renderQuantumDirect`, and `copyLastNodeAudioBus` on `AudioGraph`.
  - Pattern, Timeline & Clock (`5.1`, `5.2`, `5.3`): implemented 8-byte POD `NoteCell` + `NoteCmd` + `EffectCode` in `source/sequencer/note.d`, unmanaged atomic-patchable `PatternSnapshot` in `source/sequencer/pattern.d`, CoW `TimelineSnapshot` (`TimelineClip`, pattern clones, `SupertrackState`) in `source/sequencer/timeline.d`, 64-bit exact rational `RationalClock` (zero drift under dynamic BPM/TPL edits + `subLineDelaySamples`) in `source/sequencer/clock.d`, and `TrackEffectBank` (`0x01`–`0x5F`, `NoteCmd`, normalized parameter automation, deterministic probability `0x20`–`0x2F`) in `source/sequencer/track_effects.d`.
  - Unified `Engine` & Re-Entrant `MetaModule` (`5.4`, `5.5`): implemented zero-global-state `Engine` (`SpscRing!EngineCommand`, `SpscRing!RetiredResource`, `TripleBuffer!EngineTelemetry`, live QWERTY/MIDI voice tracking, offline mix & `exportStemsWav` exporter) in `source/sequencer/engine.d`, implemented `MetaModule` + `MetaModuleAsset` (`MAX_METAMODULE_DEPTH = 16`, BPM/TPL sync, 8 macro bindings, audio passthrough, off-RT serialization) in `source/modules/control/metamodule.d`, and registered `ctl.metamodule` in `source/graph/registry.d` (39 built-in modules total).
  - Tests & Verification Gate: added [tests/unit/sequencer_test.d](file:///Users/leehk/dev/sunvox_tools/dracker/tests/unit/sequencer_test.d) covering atomic `PatternSnapshot`, 100k-tick `RationalClock`, exact sample `2646` sub-line delay, clones, Supertracks, all effect opcodes, live playback edits + `drainRetireRing()`, per-module stem WAV sum parity, and 2-level nested `MetaModule` + `MAX_METAMODULE_DEPTH` cutoff; updated `modules_test.d` (39 modules) and appended a Phase 5 multi-pattern nested `MetaModule` golden song test in `tests/golden/golden_suite.d`. Verified debug `dub test` (`7 modules passed unittests`), `DFLAGS="-unittest -O3 -w" dub test` (`8 modules passed unittests`, `114` `__unittest` symbols), `dub build --config=headless --build=release`, `--list-devices`, `--cli-demo --duration=0.35 --auto-chord` (`callbacks=123, frames=15744, xruns=0`), `ldc2 -mtriple=x86_64-apple-macos12.0 -O3 -w -unittest` (`X86_64_COMPILE_OK`), `PHASE5_COMMENT_AUDIT_OK: 15 files`, `plutil -lint`, and `clang -Wall -Wextra`.
- **Affected Files:**
  - `dracker/agents.md` (updated — marked Phase 5 and `5.1`–`5.5` complete)
  - `dracker/docs/changelog.md` (updated — added this entry)
  - `dracker/source/graph/{context,event,module_api,audio_graph,registry}.d` (modified)
  - `dracker/source/sequencer/{note,pattern,timeline,clock,track_effects,engine}.d` (created)
  - `dracker/source/modules/control/metamodule.d` (created)
  - `dracker/tests/unit/sequencer_test.d` (created)
  - `dracker/tests/unit/modules_test.d`, `dracker/tests/golden/golden_suite.d` (modified)

---

## [2026-11-22 09:17:07 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Summary:** Implemented Phase 4 (Built-In Module Library — Tier 1 & Tier 2) with all 38 built-in `ModuleRegistry` modules, off-RT `StreamWorker` background audio decode/streaming (`VorbisPlayer` + `StreamAudioRing`), host duplex audio-input staging in `AudioGraph`, automated `@nogc` + `rt_malloc_trap` unit and golden WAV verification suites, `-O3` allocator/GC trap escape hardening in `foundation_test.d`, and updated checklist/changelog documentation.
- **Changes & Verification:**
  - Core & Expansion Effects (`4.1`, `4.6`, `4.7`): implemented `FilterPro`, `Distortion`, `Delay`, `Echo`, `Reverb` (8-line Householder FDN), `Compressor` (with `sidechainStereo`), `Eq3Band`, `WaveShaper` (1x/2x/4x oversampling + swappable table), `Flanger`, `Vibrato`, `Modulator` (audio/CV ring/AM/PM), `SmoothFx`, `VocalFilter`, `PitchShifter`, `FftFx` (75%-overlap STFT via `FftFloat`), and `LoopFx`.
  - Core & Expansion Control (`4.2`, `4.8`): implemented `MultiSynth`, `MultiCtl` (with swappable fan-out curve/target maps), `AdsrMod`, `LfoMod`, `Glide`, `Ctl2Note`, `Pitch2Ctl`, `Velocity2Ctl`, `Sound2Ctl`, and `PitchDetector` (first-peak NSDF MPM autocorrelation + zero-crossing pitch-to-note tracking).
  - Core & Expansion Synths, Sampler & Streaming (`4.3`, `4.4`, `4.9`): implemented `Kicker`, `DrumSynth`, `AnalogGen` (32-voice unison + drawn wavetable asset), `FmSynth` (5-op 6-algo), `Sampler` (multi-slot keymap, Catmull-Rom/linear/nearest, forward/ping-pong loops, breakpoint envelopes, off-RT decode, `swapAsset`, serialization), `SpectraVoice` (inverse-FFT harmonic wavetables), `AudioInput` (`synth.input` reading staged duplex host input from `ProcessContext.hostAudioIn`), and `StreamWorker` + `VorbisPlayer` (`StreamAudioRing` wait-free streaming with zero RT syscalls).
  - Graph & Registry: extended `ProcessContext` and `AudioGraph` with lock-free host audio input ring staging and sub-block slicing, and statically registered all 38 built-in modules in `ModuleRegistry` (`source/graph/registry.d`).
  - Verification & Test Suites (`4.5`): added `tests/unit/modules_test.d` (38-module silence/extreme/`rt_malloc_trap` matrix, per-module DSP/asset/serialization/streaming checks, `DummyExtensibilityModule` 1-file/1-line contract) and `tests/golden/golden_suite.d` (multi-module patches, 64..512 buffer-size invariance, cyclic `Feedback` determinism, golden WAV round-trips); fixed `tests/unit/foundation_test.d` allocator/GC escape sinks so `-unittest -O3` does not dead-eliminate trap checks. Verified `dub test` (`6 modules passed unittests`), `DFLAGS="-unittest -O3 -w" dub test` (`7 modules passed unittests`, `102` `__unittest` symbols), `dub build --config=headless --build=release`, `--list-devices`, `--cli-demo --duration=0.35 --auto-chord` (`callbacks=116, frames=14848, xruns=0`), `ldc2 -mtriple=x86_64-apple-macos12.0 -O3 -w -unittest` (`X86_64_COMPILE_OK`), `PHASE4_COMMENT_AUDIT_OK: 46 files`, `plutil -lint`, and `clang -Wall -Wextra`.
- **Affected Files:**
  - `dracker/agents.md` (updated — marked Phase 4 and `4.1`–`4.9` complete)
  - `dracker/docs/changelog.md` (updated — added this entry)
  - `dracker/source/graph/context.d`, `dracker/source/graph/audio_graph.d`, `dracker/source/graph/registry.d` (modified)
  - `dracker/source/modules/effects/{filter_pro,distortion,delay,echo,reverb,compressor,lfo,eq,waveshaper,flanger,vibrato,modulator,smooth_fx,vocal_filter,pitch_shifter,fft_fx,loop_fx}.d` (created)
  - `dracker/source/modules/control/{multisynth,multictl,adsr_mod,glide,ctl2note,pitch2ctl,velocity2ctl,sound2ctl,pitch_detector}.d` (created)
  - `dracker/source/modules/synths/{kicker,drumsynth,analog_gen,fm_synth,sampler,spectravoice,input,vorbis_player}.d` (created)
  - `dracker/source/sequencer/stream_worker.d` (created)
  - `dracker/tests/unit/modules_test.d`, `dracker/tests/golden/golden_suite.d` (created)
  - `dracker/tests/unit/foundation_test.d` (modified)

---

## [2026-11-22 08:46:27 KST]
- **Timestamp:** `2026-11-22 08:46:27 KST`
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `dracker/source/platform/interfaces.d`
  - `dracker/source/platform/macos/corefoundation.d`
  - `dracker/source/platform/macos/coreaudio.d`
  - `dracker/source/platform/macos/coremidi.d`
  - `dracker/source/main.d`
  - `dracker/tests/unit/platform_test.d`
  - `dracker/agents.md`
  - `dracker/docs/changelog.md`
- **Description:** Implemented Phase 3 (Native macOS Audio & MIDI Layer): froze `platform.interfaces` (`IAudioDriver`, `IMidiDriver`, `IPlatformWindow`, `IFileDialog`, `MidiPacket`), added `extern(C)` CoreFoundation UTF-8/`ScopedCF`/`MachTimebase` helpers (`corefoundation.d`), implemented `CoreAudioDriver` AUHAL output + same-device direct duplex + dual-device PI `DriftCompensatedInputRing` with `ScopedNoDenormals` and hot-plug/sample-rate property listeners (`coreaudio.d`), implemented `CoreMidiDriver` with architecture-safe `midiPacketNext`, running-status/SysEx MIDI 1.0 parser, multi-source `MpscRing!MidiPacket`, virtual endpoints, and `MidiNoteTracker`/`ModEvent` translation (`coremidi.d`), wired `main.d` (`--list-devices`, `--cli-demo` live polyphonic `CliDemoPolySynth` + `AudioGraph`), and verified with `tests/unit/platform_test.d` under `rt_malloc_trap` and live CoreAudio/CoreMIDI checks.

## [2026-11-22 07:06:26 KST]
- **Timestamp:** `2026-11-22 07:06:26 KST`
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `dracker/source/foundation/concurrency.d`
  - `dracker/source/graph/port.d`
  - `dracker/source/graph/event.d`
  - `dracker/source/graph/context.d`
  - `dracker/source/graph/buffer.d`
  - `dracker/source/graph/module_api.d`
  - `dracker/source/graph/registry.d`
  - `dracker/source/graph/plan.d`
  - `dracker/source/graph/audio_graph.d`
  - `dracker/source/modules/output.d`
  - `dracker/source/modules/effects/amplifier.d`
  - `dracker/source/modules/effects/dc_blocker.d`
  - `dracker/source/modules/control/feedback.d`
  - `dracker/tests/unit/graph_test.d`
  - `dracker/agents.md`
  - `dracker/docs/changelog.md`
- **Description:** Implemented Phase 2 (Fixed-Quantum AudioGraph & UDA Module Protocol): typed port descriptors, sample-accurate `ModEvent`/`EventArena`/`EventSink`, `ProcessContext`/`ProcessIO` audio+CV slice views, UDA `@Param` + `assertNoNaNInit!T` + named `onParamChanged!field` + `@nogc` `ModuleAdapter!T`, `ModuleRegistry`, off-RT `GraphCompiler` with topological sort and `FeedbackReceive`/`FeedbackSend` cycle splitting into `@nogc` `GraphPlan`, real-time `AudioGraph` with 64-frame fixed quanta, sample-accurate event sub-blocking, fan-in audio/sidechain/CV mixing, silence skipping, mid-stream `swapPlan`/`swapModuleAsset` retirement, and `TripleBuffer!GraphTelemetry`, plus Tier 1 modules (`MasterOutput`, `Amplifier`, `DcBlocker`, `Feedback`), `SpscRing`/`MpscRing` pointer-indirection safety fix in `concurrency.d`, and comprehensive `graph_test.d` determinism/allocation-trap unit tests.

## [2026-11-21 21:42:01 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `dracker/source/dsp/tables.d` (implemented)
  - `dracker/source/dsp/interp.d` (implemented)
  - `dracker/source/dsp/resampler.d` (implemented)
  - `dracker/source/dsp/fft.d` (implemented)
  - `dracker/source/dsp/filter_biquad.d` (implemented)
  - `dracker/source/dsp/filter_svf.d` (implemented)
  - `dracker/source/dsp/oscillator.d` (implemented)
  - `dracker/source/dsp/smoother.d` (implemented)
  - `dracker/source/dsp/envelope.d` (implemented)
  - `dracker/source/dsp/delay_line.d` (implemented)
  - `dracker/source/dsp/voice_pool.d` (implemented)
  - `dracker/tests/unit/dsp_test.d` (created)
  - `dracker/agents.md` (updated Phase 1 checklist)
  - `dracker/docs/changelog.md` (updated)
- **Description:** Completed Phase 1 (Core DSP Primitives & Shared Polyphony): implemented all 11 `@nogc nothrow` DSP modules (`tables.d` immutable sine/half-sine/window tables, `interp.d` nearest/linear/Hermite/Catmull-Rom kernels, `resampler.d` causal streaming `FractionalResampler`/`StereoResampler`, `fft.d` explicit `float`/`double` radix-2 FFT/IFFT, `filter_biquad.d` double-state 1-pole/RBJ biquad/cascaded filters, `filter_svf.d` Cytomic TPT SVF, `oscillator.d` PolyBLEP/PolyBLAMP/drawn-wave/deterministic noise, `smoother.d` `ParamSmoother`/`LinearRamp`, `envelope.d` `AdsrEnvelope`/`BreakpointEnvelope`, `delay_line.d` power-of-two `DelayLine`, and `voice_pool.d` `VoicePool!(VoiceT, MaxVoices)`); added comprehensive unit and `rt_malloc_trap` audits in `tests/unit/dsp_test.d`. Verified zero warnings across `dub test --config=headless` (debug & `-O3`), `dub build --config=headless --build=release`, and `x86_64` cross-compilation.

## [2026-11-21 21:29:57 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `dracker/dub.json` (updated)
  - `dracker/dub.selections.json` (created)
  - `dracker/ci/macos.yml` (updated)
  - `dracker/agents.md` (updated Phase 0 checklist)
  - `dracker/source/main.d` (cleaned inline comment)
  - `dracker/source/foundation/types.d` (implemented)
  - `dracker/source/foundation/memory.d` (implemented)
  - `dracker/source/foundation/concurrency.d` (implemented)
  - `dracker/source/foundation/math_rt.d` (implemented)
  - `dracker/source/io/audio_io.d` (implemented)
  - `dracker/tests/rt_malloc_trap.d` (implemented)
  - `dracker/tests/audio_harness.d` (implemented)
  - `dracker/tests/unit/foundation_test.d` (implemented)
  - `dracker/docs/changelog.md` (updated)
- **Description:** Completed Phase 0 (Scaffolding, `@nogc` Foundation & Verification Harness): verified `audio-formats` 3.1.0 `boost` subconfiguration and pinned `dub.selections.json`; configured `dub.json` headless test discovery and updated `ci/macos.yml`; implemented `@nogc nothrow` `foundation/{types,memory,concurrency,math_rt}.d` (`OwnedBuffer!T`, `FixedArray`, `Arena`, `Atomic!T`, `SpscRing!T`, `MpscRing!T`, `TripleBuffer!T`, `ScopedNoDenormals` for `arm64`/`x86_64`, pitch/dB tables); implemented `io/audio_io.d` using `audio-formats` (`boost`) for decoding and a pure-D IEEE-float32 RIFF/WAVE writer bypassing upstream `audio-formats` 3.1.0 WAV-encoder defects; implemented `tests/rt_malloc_trap.d`, `tests/audio_harness.d`, and full unit/10M-message stress tests in `tests/unit/foundation_test.d`. Verified zero warnings across `dub test --config=headless` (debug & `-O3`), `dub build --config=headless --build=release`, and `x86_64` cross-compilation.

## [2026-11-21 20:59:47 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `.gitignore` (created at repository root)
  - `dracker/docs/changelog.md` (updated)
- **Description:** Added root `.gitignore` ignoring everything outside `dracker/` plus standard OS, D/LDC2/DUB, Metal/Xcode, and IDE artifacts; verified zero tracked ignored files remained in the index.

## [2026-11-21 20:45:11 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `dracker/docs/` (created directory)
  - `dracker/agents.md` (created)
  - `dracker/docs/changelog.md` (created)
- **Description:** Created `dracker/docs/`, authored `dracker/agents.md` at the project root as the agent source-of-truth reference (covering design invariants, directory map, phased implementation checklists with strict exit gates, build/test commands, strict document/DDoc-only comment rules, pure-D FFI policy, and changelog requirements), and initialized `dracker/docs/changelog.md` with its first entry.
