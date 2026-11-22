# SynthTracker Changelog

All major changes to `synth-tracker/` must be recorded in reverse-chronological order (newest entry first).

### Entry Format
- **Timestamp:** `YYYY-MM-DD HH:MM:SS KST` (UTC+09:00)
- **Author:** Human developer name or agent model name
- **Affected Files:** Explicit list of created, modified, or deleted paths
- **Description:** Concise summary of the change(s)

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
  - `synth-tracker/agents.md`
  - `synth-tracker/docs/changelog.md`

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
  - `synth-tracker/agents.md`
  - `dev_plan.md`
  - `synth-tracker/docs/changelog.md`

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
  - `synth-tracker/agents.md`
  - `dev_plan.md`
  - `synth-tracker/docs/changelog.md`

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
    - cut/copy/paste through the `SynthTracker-Block-v1` clipboard, plus transpose and interpolate, each one undo step
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
  - `caffeinate -dims ./build/synth-tracker --studio-gui-selftest` (full, Apple M5 Pro, 120 Hz Retina, live CoreAudio) passed 10/10:
    - added AnalogGen, FM synth and Echo through the patchbay menus; wired three cables by port drags
    - cutoff drag in the rack; 64 notes recorded by QWERTY across 4 tracks
    - Alt-drag clone plus Supertrack through the timeline menu
    - Unison 4 and an 8 s Release set through the rack
    - 10 s playback stress with node drags, scrolling and live 6-note chords: 118.9 fps, 0 xruns, DSP peak 27.4 %, level 0.598
    - Cmd+S, Cmd+N, Cmd+O restored 4 modules, 3 wires and 2 clips; Cmd+E exported a 764,928-frame WAV
  - Regression runs: `--studio-selftest --quick` 5/5 and `--gui-selftest --quick` 13/13.
- **Affected Files:**
  - `synth-tracker/source/gui/views/{studio_context,studio_root}.d` and `synth-tracker/source/app/studio_app.d` (created)
  - `synth-tracker/source/gui/views/{transport_bar,scope_view,patchbay_view,param_rack,sample_editor,pattern_editor,timeline_view}.d`
  - `synth-tracker/tests/unit/views_{transport,patchbay,param_rack,sample_editor,pattern_editor,timeline,studio_root}_test.d` (created)
  - `synth-tracker/source/app/session.d`, `synth-tracker/source/main.d`, `synth-tracker/source/platform/macos/appkit.d`, `synth-tracker/dub.json`
  - `synth-tracker/agents.md`, `synth-tracker/docs/changelog.md`

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
  - `7.5.5` `UndoHistory.beginGroup`/`endGroup` + `CompoundCommand` (atomic rollback on failure, nested groups flatten), `DelegateCommand`, `doReplacePatternCells`. New `app/pattern_ops.d`: blocks, transpose, interpolate, and the `SynthTracker-Block-v1` codec.
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
  - `./build/synth-tracker --studio-selftest` (full) passed 5/5:
    - 30 s @64 frames: 20,674 callbacks, 0 xruns, 2,503 concurrent UI edits, DSP load avg 3.8 % / peak 9.1 %
    - 30 s @128 frames: 0 xruns, 2,478 edits
    - MIDI-in -> rendered audio latency: 0.54 ms
    - a forced 48 kHz mismatch was restored to the 44.1 kHz device rate and playback resumed
    - export bit-identical to an offline render
- **Affected Files:**
  - `synth-tracker/source/app/{audio_host,telemetry,pattern_ops,studio_selftest}.d` (created)
  - `synth-tracker/source/app/{session,history,keymap}.d`
  - `synth-tracker/source/sequencer/engine.d`, `synth-tracker/source/graph/{audio_graph,module_api}.d`, `synth-tracker/source/io/project_format.d`
  - `synth-tracker/source/modules/{effects/waveshaper,control/multisynth,control/multictl,synths/analog_gen,synths/spectravoice,synths/sampler}.d`
  - `synth-tracker/source/main.d`
  - `synth-tracker/tests/unit/{studio_backend_test,pattern_ops_test,keymap_test}.d`, `synth-tracker/tests/fuzz/block_text_fuzz.d` (created), `synth-tracker/tests/fuzz/project_format_fuzz.d`
  - `synth-tracker/agents.md`, `synth-tracker/docs/changelog.md`

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
    - grouped undo with atomic rollback, pattern block operations, and the `SynthTracker-Block-v1` clipboard codec (`app/pattern_ops.d`);
    - keymap expansion and `StudioCommandSink`;
    - verification, including `--studio-selftest`.
  - Phase 8 now depends on Phase 7.5. The `agents.md` UI ↔ RT mutation table gained rows for the audio host, live MIDI, MIDI map, and scope taps, and the package map lists the planned `app/` files. The `dev_plan.md` schedule table and totals were updated.
  - Rule 5: `7.5.1`–`7.5.3` change the UI ↔ RT boundary and are flagged as needing owner approval of the design before implementation.
- **Affected Files:**
  - `synth-tracker/agents.md`
  - `dev_plan.md`
  - `synth-tracker/docs/changelog.md`

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
  - `caffeinate -dims ./build/synth-tracker --gui-selftest` (Apple M5 Pro, 120 Hz Retina, final build): 12/13 PASS — window/Retina 2200x1440 @2x (runtime-compiled shader), 8 menu key equivalents, raw keyDown/text/keyUp/Shift flagsChanged/repeat order, Cmd+Z / Cmd+Shift+Z / Cmd+Q routed once each, flipped mouse coordinates, trackpad scroll, toolkit toggle/context menu/Escape via real events, private-pasteboard clipboard, open/save sheets attached and cancelled, resize to 1800x1200 px, 118-120 fps display-paced, idle CPU 0.06-2.11 % across runs.
  - **Open:** the 100,000-frame soak (100,000 presented frames, 834 s, 120.0 fps; GC heap +0 KB) failed its own tail criterion: malloc stayed flat (+0 to +31 KB) for 9 of 10 checkpoint intervals, then stepped +127 KB / +1,489 blocks in the final interval. A per-frame leak would grow in every interval, so this looks like a one-off allocation burst, but it has not been explained, so Phase 7 stays unchecked pending owner review.
- **Affected Files:**
  - `synth-tracker/source/platform/macos/{objc_runtime,appkit,coretext,metal_renderer}.d`
  - `synth-tracker/shaders/ui2d.metal`
  - `synth-tracker/source/gui/{renderer,theme,layout,widgets}.d`
  - `synth-tracker/source/app/gui_shell.d`, `synth-tracker/source/app/gui_gallery.d` (created)
  - `synth-tracker/tests/unit/gui_test.d` (created)
  - `synth-tracker/source/main.d`, `synth-tracker/dub.json`, `synth-tracker/agents.md`, `synth-tracker/docs/changelog.md`

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
  - `synth-tracker/source/sequencer/engine.d`
  - `synth-tracker/source/io/project_format.d`
  - `synth-tracker/source/io/importers/sunvox_importer.d`
  - `synth-tracker/source/io/importers/xm_importer.d`
  - `synth-tracker/source/app/history.d`
  - `synth-tracker/source/app/session.d`
  - `synth-tracker/tests/fuzz/project_format_fuzz.d`
  - `synth-tracker/tests/unit/persistence_test.d`
  - `synth-tracker/tests/unit/session_safety_test.d` (created)
  - `synth-tracker/agents.md`
  - `synth-tracker/docs/changelog.md`

---

## [2026-11-22 09:52:12 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Reason / Summary:** Completed Phase 6 (Native Persistence, Undo/Redo, Session Bridge & Optional Importers).
  - Implemented `source/io/binary_stream.d` (`BinaryReader` and `BinaryWriter`) with `@safe` overflow-safe bounds checking, LE/BE integer & IEEE-754 float codecs, MIDI VLQ decoding, FourCC helpers, and isolated `readChunk`/`writeChunk` framing.
  - Implemented `source/io/project_format.d` (`MSV1` `.msv` project and `MSYM` `.msym` module/MetaModule preset formats) with unknown-chunk forward-compatibility skipping, recursion depth enforcement (`MAX_METAMODULE_DEPTH`), and `materializeProjectToEngine`.
  - Implemented `source/app/keymap.d` (macOS 29-key two-octave QWERTY tracker piano + `StudioAction` bindings), `source/app/history.d` (`IUndoCommand`, `UndoHistory` with drag coalescing and 14 concrete commands), and `source/app/session.d` (`StudioSession` bridging UI/CLI actions, persistence, importers, `UndoHistory`, and lock-free `Engine` snapshot/command dispatch + `pollRetiredAndTelemetry`).
  - Implemented optional importers in `source/io/importers/{smf,xm,sunvox}_importer.d` supporting Standard MIDI Files (`.mid` Format 0/1 with sub-line delay quantization and channel 9 drum kit mapping), FastTracker II (`.xm` packed patterns and 8/16-bit delta PCM samples mapped to `synth.sampler`), and best-effort `.sunvox` (`SVOX`) structural import with `ImportReport` diagnostics.
  - Added `tests/fuzz/project_format_fuzz.d` executing 100,000 deterministic mutation/truncation/corruption/overflow/NaN/deep-nesting runs across `.msv`, `.msym`, `.mid`, `.xm`, and `.sunvox` parsers, plus `tests/unit/persistence_test.d` verifying stream bounds, bit-exact `.msv`/`.msym` WAV round-trips (`Sampler`, `WaveShaper`, `Echo`, `AnalogGen`, nested `MetaModule`, unknown `FUTR` chunk), `UndoHistory`/`StudioSession`/`Keymap` with `verifyZeroRtAllocationsNothrow`, and all three optional importers.
  - Marked Phase 6 and subtasks `6.1`–`6.5` as completed `[x]` in `synth-tracker/agents.md`.
- **Verification Results:**
  - `dub test --compiler=ldc2 --config=headless --force --skip-registry=all`: 9 modules passed unittests (`120` `__unittest` symbols via `nm`).
  - `DFLAGS="-unittest -O3 -w" dub test --compiler=ldc2 --config=headless --force --skip-registry=all`: 10 modules passed unittests with zero warnings.
  - `dub build --compiler=ldc2 --config=headless --build=release --force --skip-registry=all`, `./build/synth-tracker --list-devices`, and `./build/synth-tracker --cli-demo --duration=0.35 --auto-chord` (122 callbacks, 15,616 frames, 0 xruns) passed cleanly.
  - `x86_64-apple-macos12.0` `-O3 -w -unittest` cross-compile passed (`X86_64_COMPILE_OK`).
  - Strict DDoc-only comment audit (`PHASE6_COMMENT_AUDIT_OK: 10 files`), `plutil -lint packaging/macos/Info.plist`, `clang -Wall -Wextra -fsyntax-only source/platform/macos/objc_blocks_shim.m`, and `bash -n` script check all passed.
- **Affected Files:**
  - `synth-tracker/source/io/binary_stream.d`
  - `synth-tracker/source/io/project_format.d`
  - `synth-tracker/source/io/importers/smf_importer.d`
  - `synth-tracker/source/io/importers/xm_importer.d`
  - `synth-tracker/source/io/importers/sunvox_importer.d`
  - `synth-tracker/source/app/keymap.d`
  - `synth-tracker/source/app/history.d`
  - `synth-tracker/source/app/session.d`
  - `synth-tracker/tests/fuzz/project_format_fuzz.d`
  - `synth-tracker/tests/unit/persistence_test.d`
  - `synth-tracker/agents.md`
  - `synth-tracker/docs/changelog.md`

---

## [2026-11-22 09:33:25 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Summary:** Implemented Phase 5 (Tracker Sequencer, Timeline, Supertracks & `MetaModule`) with 8-byte POD `NoteCell` atomic pattern patching, Copy-on-Write `PatternSnapshot` & `TimelineSnapshot` (pattern clones, mute/solo, loops, persistent-lane Supertracks), drift-free 64-bit `RationalClock`, full `TrackEffectBank` effect suite including exact sample-frame sub-line delays (`0x40`–`0x5F`), unified instance-scoped `Engine` with lock-free commands/retire queue & per-module stem WAV export, and re-entrant nested `MetaModule` (`ctl.metamodule`, `MAX_METAMODULE_DEPTH = 16`, 39 built-in registered modules).
- **Changes & Verification:**
  - Graph Protocol Extensions: extended `ProcessContext` with `metaDepth`, added `ModEventKind.setParamNormalized` + `ModuleVTable.setParamNormalized` (mapping `[0..1]` across linear/logarithmic/discrete `@Param` descriptors in `ModuleAdapter!T`), extended `RetiredKind` with `patternSnapshot`/`timelineSnapshot`/`childEngine`, and added `setNodeMuted`, `setNodeBypassed`, `renderQuantumDirect`, and `copyLastNodeAudioBus` on `AudioGraph`.
  - Pattern, Timeline & Clock (`5.1`, `5.2`, `5.3`): implemented 8-byte POD `NoteCell` + `NoteCmd` + `EffectCode` in `source/sequencer/note.d`, unmanaged atomic-patchable `PatternSnapshot` in `source/sequencer/pattern.d`, CoW `TimelineSnapshot` (`TimelineClip`, pattern clones, `SupertrackState`) in `source/sequencer/timeline.d`, 64-bit exact rational `RationalClock` (zero drift under dynamic BPM/TPL edits + `subLineDelaySamples`) in `source/sequencer/clock.d`, and `TrackEffectBank` (`0x01`–`0x5F`, `NoteCmd`, normalized parameter automation, deterministic probability `0x20`–`0x2F`) in `source/sequencer/track_effects.d`.
  - Unified `Engine` & Re-Entrant `MetaModule` (`5.4`, `5.5`): implemented zero-global-state `Engine` (`SpscRing!EngineCommand`, `SpscRing!RetiredResource`, `TripleBuffer!EngineTelemetry`, live QWERTY/MIDI voice tracking, offline mix & `exportStemsWav` exporter) in `source/sequencer/engine.d`, implemented `MetaModule` + `MetaModuleAsset` (`MAX_METAMODULE_DEPTH = 16`, BPM/TPL sync, 8 macro bindings, audio passthrough, off-RT serialization) in `source/modules/control/metamodule.d`, and registered `ctl.metamodule` in `source/graph/registry.d` (39 built-in modules total).
  - Tests & Verification Gate: added [tests/unit/sequencer_test.d](file:///Users/leehk/dev/sunvox_tools/synth-tracker/tests/unit/sequencer_test.d) covering atomic `PatternSnapshot`, 100k-tick `RationalClock`, exact sample `2646` sub-line delay, clones, Supertracks, all effect opcodes, live playback edits + `drainRetireRing()`, per-module stem WAV sum parity, and 2-level nested `MetaModule` + `MAX_METAMODULE_DEPTH` cutoff; updated `modules_test.d` (39 modules) and appended a Phase 5 multi-pattern nested `MetaModule` golden song test in `tests/golden/golden_suite.d`. Verified debug `dub test` (`7 modules passed unittests`), `DFLAGS="-unittest -O3 -w" dub test` (`8 modules passed unittests`, `114` `__unittest` symbols), `dub build --config=headless --build=release`, `--list-devices`, `--cli-demo --duration=0.35 --auto-chord` (`callbacks=123, frames=15744, xruns=0`), `ldc2 -mtriple=x86_64-apple-macos12.0 -O3 -w -unittest` (`X86_64_COMPILE_OK`), `PHASE5_COMMENT_AUDIT_OK: 15 files`, `plutil -lint`, and `clang -Wall -Wextra`.
- **Affected Files:**
  - `synth-tracker/agents.md` (updated — marked Phase 5 and `5.1`–`5.5` complete)
  - `synth-tracker/docs/changelog.md` (updated — added this entry)
  - `synth-tracker/source/graph/{context,event,module_api,audio_graph,registry}.d` (modified)
  - `synth-tracker/source/sequencer/{note,pattern,timeline,clock,track_effects,engine}.d` (created)
  - `synth-tracker/source/modules/control/metamodule.d` (created)
  - `synth-tracker/tests/unit/sequencer_test.d` (created)
  - `synth-tracker/tests/unit/modules_test.d`, `synth-tracker/tests/golden/golden_suite.d` (modified)

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
  - `synth-tracker/agents.md` (updated — marked Phase 4 and `4.1`–`4.9` complete)
  - `synth-tracker/docs/changelog.md` (updated — added this entry)
  - `synth-tracker/source/graph/context.d`, `synth-tracker/source/graph/audio_graph.d`, `synth-tracker/source/graph/registry.d` (modified)
  - `synth-tracker/source/modules/effects/{filter_pro,distortion,delay,echo,reverb,compressor,lfo,eq,waveshaper,flanger,vibrato,modulator,smooth_fx,vocal_filter,pitch_shifter,fft_fx,loop_fx}.d` (created)
  - `synth-tracker/source/modules/control/{multisynth,multictl,adsr_mod,glide,ctl2note,pitch2ctl,velocity2ctl,sound2ctl,pitch_detector}.d` (created)
  - `synth-tracker/source/modules/synths/{kicker,drumsynth,analog_gen,fm_synth,sampler,spectravoice,input,vorbis_player}.d` (created)
  - `synth-tracker/source/sequencer/stream_worker.d` (created)
  - `synth-tracker/tests/unit/modules_test.d`, `synth-tracker/tests/golden/golden_suite.d` (created)
  - `synth-tracker/tests/unit/foundation_test.d` (modified)

---

## [2026-11-22 08:46:27 KST]
- **Timestamp:** `2026-11-22 08:46:27 KST`
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `synth-tracker/source/platform/interfaces.d`
  - `synth-tracker/source/platform/macos/corefoundation.d`
  - `synth-tracker/source/platform/macos/coreaudio.d`
  - `synth-tracker/source/platform/macos/coremidi.d`
  - `synth-tracker/source/main.d`
  - `synth-tracker/tests/unit/platform_test.d`
  - `synth-tracker/agents.md`
  - `synth-tracker/docs/changelog.md`
- **Description:** Implemented Phase 3 (Native macOS Audio & MIDI Layer): froze `platform.interfaces` (`IAudioDriver`, `IMidiDriver`, `IPlatformWindow`, `IFileDialog`, `MidiPacket`), added `extern(C)` CoreFoundation UTF-8/`ScopedCF`/`MachTimebase` helpers (`corefoundation.d`), implemented `CoreAudioDriver` AUHAL output + same-device direct duplex + dual-device PI `DriftCompensatedInputRing` with `ScopedNoDenormals` and hot-plug/sample-rate property listeners (`coreaudio.d`), implemented `CoreMidiDriver` with architecture-safe `midiPacketNext`, running-status/SysEx MIDI 1.0 parser, multi-source `MpscRing!MidiPacket`, virtual endpoints, and `MidiNoteTracker`/`ModEvent` translation (`coremidi.d`), wired `main.d` (`--list-devices`, `--cli-demo` live polyphonic `CliDemoPolySynth` + `AudioGraph`), and verified with `tests/unit/platform_test.d` under `rt_malloc_trap` and live CoreAudio/CoreMIDI checks.

## [2026-11-22 07:06:26 KST]
- **Timestamp:** `2026-11-22 07:06:26 KST`
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `synth-tracker/source/foundation/concurrency.d`
  - `synth-tracker/source/graph/port.d`
  - `synth-tracker/source/graph/event.d`
  - `synth-tracker/source/graph/context.d`
  - `synth-tracker/source/graph/buffer.d`
  - `synth-tracker/source/graph/module_api.d`
  - `synth-tracker/source/graph/registry.d`
  - `synth-tracker/source/graph/plan.d`
  - `synth-tracker/source/graph/audio_graph.d`
  - `synth-tracker/source/modules/output.d`
  - `synth-tracker/source/modules/effects/amplifier.d`
  - `synth-tracker/source/modules/effects/dc_blocker.d`
  - `synth-tracker/source/modules/control/feedback.d`
  - `synth-tracker/tests/unit/graph_test.d`
  - `synth-tracker/agents.md`
  - `synth-tracker/docs/changelog.md`
- **Description:** Implemented Phase 2 (Fixed-Quantum AudioGraph & UDA Module Protocol): typed port descriptors, sample-accurate `ModEvent`/`EventArena`/`EventSink`, `ProcessContext`/`ProcessIO` audio+CV slice views, UDA `@Param` + `assertNoNaNInit!T` + named `onParamChanged!field` + `@nogc` `ModuleAdapter!T`, `ModuleRegistry`, off-RT `GraphCompiler` with topological sort and `FeedbackReceive`/`FeedbackSend` cycle splitting into `@nogc` `GraphPlan`, real-time `AudioGraph` with 64-frame fixed quanta, sample-accurate event sub-blocking, fan-in audio/sidechain/CV mixing, silence skipping, mid-stream `swapPlan`/`swapModuleAsset` retirement, and `TripleBuffer!GraphTelemetry`, plus Tier 1 modules (`MasterOutput`, `Amplifier`, `DcBlocker`, `Feedback`), `SpscRing`/`MpscRing` pointer-indirection safety fix in `concurrency.d`, and comprehensive `graph_test.d` determinism/allocation-trap unit tests.

## [2026-11-21 21:42:01 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `synth-tracker/source/dsp/tables.d` (implemented)
  - `synth-tracker/source/dsp/interp.d` (implemented)
  - `synth-tracker/source/dsp/resampler.d` (implemented)
  - `synth-tracker/source/dsp/fft.d` (implemented)
  - `synth-tracker/source/dsp/filter_biquad.d` (implemented)
  - `synth-tracker/source/dsp/filter_svf.d` (implemented)
  - `synth-tracker/source/dsp/oscillator.d` (implemented)
  - `synth-tracker/source/dsp/smoother.d` (implemented)
  - `synth-tracker/source/dsp/envelope.d` (implemented)
  - `synth-tracker/source/dsp/delay_line.d` (implemented)
  - `synth-tracker/source/dsp/voice_pool.d` (implemented)
  - `synth-tracker/tests/unit/dsp_test.d` (created)
  - `synth-tracker/agents.md` (updated Phase 1 checklist)
  - `synth-tracker/docs/changelog.md` (updated)
- **Description:** Completed Phase 1 (Core DSP Primitives & Shared Polyphony): implemented all 11 `@nogc nothrow` DSP modules (`tables.d` immutable sine/half-sine/window tables, `interp.d` nearest/linear/Hermite/Catmull-Rom kernels, `resampler.d` causal streaming `FractionalResampler`/`StereoResampler`, `fft.d` explicit `float`/`double` radix-2 FFT/IFFT, `filter_biquad.d` double-state 1-pole/RBJ biquad/cascaded filters, `filter_svf.d` Cytomic TPT SVF, `oscillator.d` PolyBLEP/PolyBLAMP/drawn-wave/deterministic noise, `smoother.d` `ParamSmoother`/`LinearRamp`, `envelope.d` `AdsrEnvelope`/`BreakpointEnvelope`, `delay_line.d` power-of-two `DelayLine`, and `voice_pool.d` `VoicePool!(VoiceT, MaxVoices)`); added comprehensive unit and `rt_malloc_trap` audits in `tests/unit/dsp_test.d`. Verified zero warnings across `dub test --config=headless` (debug & `-O3`), `dub build --config=headless --build=release`, and `x86_64` cross-compilation.

## [2026-11-21 21:29:57 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `synth-tracker/dub.json` (updated)
  - `synth-tracker/dub.selections.json` (created)
  - `synth-tracker/ci/macos.yml` (updated)
  - `synth-tracker/agents.md` (updated Phase 0 checklist)
  - `synth-tracker/source/main.d` (cleaned inline comment)
  - `synth-tracker/source/foundation/types.d` (implemented)
  - `synth-tracker/source/foundation/memory.d` (implemented)
  - `synth-tracker/source/foundation/concurrency.d` (implemented)
  - `synth-tracker/source/foundation/math_rt.d` (implemented)
  - `synth-tracker/source/io/audio_io.d` (implemented)
  - `synth-tracker/tests/rt_malloc_trap.d` (implemented)
  - `synth-tracker/tests/audio_harness.d` (implemented)
  - `synth-tracker/tests/unit/foundation_test.d` (implemented)
  - `synth-tracker/docs/changelog.md` (updated)
- **Description:** Completed Phase 0 (Scaffolding, `@nogc` Foundation & Verification Harness): verified `audio-formats` 3.1.0 `boost` subconfiguration and pinned `dub.selections.json`; configured `dub.json` headless test discovery and updated `ci/macos.yml`; implemented `@nogc nothrow` `foundation/{types,memory,concurrency,math_rt}.d` (`OwnedBuffer!T`, `FixedArray`, `Arena`, `Atomic!T`, `SpscRing!T`, `MpscRing!T`, `TripleBuffer!T`, `ScopedNoDenormals` for `arm64`/`x86_64`, pitch/dB tables); implemented `io/audio_io.d` using `audio-formats` (`boost`) for decoding and a pure-D IEEE-float32 RIFF/WAVE writer bypassing upstream `audio-formats` 3.1.0 WAV-encoder defects; implemented `tests/rt_malloc_trap.d`, `tests/audio_harness.d`, and full unit/10M-message stress tests in `tests/unit/foundation_test.d`. Verified zero warnings across `dub test --config=headless` (debug & `-O3`), `dub build --config=headless --build=release`, and `x86_64` cross-compilation.

## [2026-11-21 20:59:47 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `.gitignore` (created at repository root)
  - `synth-tracker/docs/changelog.md` (updated)
- **Description:** Added root `.gitignore` ignoring everything outside `synth-tracker/` plus standard OS, D/LDC2/DUB, Metal/Xcode, and IDE artifacts; verified zero tracked ignored files remained in the index.

## [2026-11-21 20:45:11 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `synth-tracker/docs/` (created directory)
  - `synth-tracker/agents.md` (created)
  - `synth-tracker/docs/changelog.md` (created)
- **Description:** Created `synth-tracker/docs/`, authored `synth-tracker/agents.md` at the project root as the agent source-of-truth reference (covering design invariants, directory map, phased implementation checklists with strict exit gates, build/test commands, strict document/DDoc-only comment rules, pure-D FFI policy, and changelog requirements), and initialized `synth-tracker/docs/changelog.md` with its first entry.
