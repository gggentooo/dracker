# Dracker User Manual

**Covers:** the native macOS studio as of Phase 8.5 (2026-11-22).
**Audience:** musicians using Dracker, and beta testers verifying it.

Dracker is a modular synthesizer combined with a tracker sequencer:

- You build instruments and effect chains by wiring **modules** together in a **patchbay**.
- You write music as rows of notes and commands in **patterns**.
- You arrange those patterns on a **timeline**.

Everything runs live: edits are heard immediately, and you can play notes from the computer keyboard or a MIDI controller.

> **For beta testers:** sections marked **QA note** describe current limitations or known quirks. They are expected behavior for this build, not new bugs. [Appendix C](#appendix-c-known-limitations-and-qa-notes) collects them all with suggested test procedures.

---

## Contents

1. [Getting started](#1-getting-started)
2. [The studio window](#2-the-studio-window)
3. [The menu bar](#3-the-menu-bar)
4. [General controls: knobs, sliders, number boxes, menus](#4-general-controls)
5. [The transport bar](#5-the-transport-bar)
6. [The patchbay: creating and wiring modules](#6-the-patchbay)
7. [The parameter rack: adjusting modules](#7-the-parameter-rack)
8. [The pattern editor: writing music](#8-the-pattern-editor)
9. [The timeline: arranging the song](#9-the-timeline)
10. [The sample editor](#10-the-sample-editor)
11. [The scope](#11-the-scope)
12. [Playing live: computer keyboard, piano and MIDI](#12-playing-live)
13. [Files: new, open, save, export, import](#13-files)
14. [Appearance and accessibility](#14-appearance-and-accessibility)
15. [Undo and redo](#15-undo-and-redo)
16. [Tutorial: your first song](#16-tutorial-your-first-song)
- [Appendix A: Keyboard shortcut reference](#appendix-a-keyboard-shortcut-reference)
- [Appendix B: Module reference](#appendix-b-module-reference)
- [Appendix C: Known limitations and QA notes](#appendix-c-known-limitations-and-qa-notes)
- [Appendix D: Command-line options and self-tests](#appendix-d-command-line-options-and-self-tests)

---

## 1. Getting started

### 1.1 Requirements
- macOS 12 or later. Apple silicon and Intel are both supported.
- An audio output device. A MIDI controller is optional.
- **Fonts:** the studio is designed for **Atkinson Hyperlegible Next** (interface text) and **Fira Code** (the pattern grid).
  - In this build the fonts are not yet bundled inside the app, so they must be installed, for example in `~/Library/Fonts`.
  - If either font is missing, the app falls back to the system font and says so in the status bar.

### 1.2 Launching
- **From a build tree:** run `./build/dracker` from inside `dracker/`.
- **Opening a project directly:** pass the file as an argument, for example `./build/dracker mysong.msv`.

Startup sequence:

1. The window opens at 1440 × 900 points. The minimum size is 960 × 640.
2. The default audio output device is opened at a 128-frame buffer.
3. All connected MIDI sources are listened to.
4. If audio cannot be opened, the status bar shows **"Audio unavailable: …"** and the studio still works for editing.

### 1.3 What a new project contains
- One module, **Master Output**. Everything you want to hear must eventually be wired into it.
- One pattern, **Pattern 01**: 4 tracks × 64 lines.
- One timeline clip that plays Pattern 01 from line 0.
- Tempo **125 BPM**, **6 ticks per line**, time signature **4/4**, key **C major**.

To start from chords instead, use **File ▸ New Project from Skeleton…** ([§13.9](#139-new-project-from-skeleton)).

### 1.4 Core concepts

| Term | Meaning |
|---|---|
| **Module** | One sound source, effect or controller (e.g. *Analog Generator*, *Reverb*, *LFO*). Each has **ports** and **parameters**. |
| **Port** | An input or output on a module. There are four kinds: audio, sidechain, event (notes) and CV (control signals). |
| **Wire** | A connection from an output port to an input port. |
| **Pattern** | A grid of **tracks** (columns) × **lines** (rows). Each cell can hold a note, velocity, target module, controller and effect. |
| **Line** | One row of a pattern; the basic unit of time. Each line lasts *ticks per line* ticks. |
| **Clip** | A placement of a pattern on the timeline, at a start line, on a lane, with a length. |
| **Lane** | A horizontal row on the timeline. Clips on different lanes play at the same time. |
| **Edit octave / edit step** | The octave used by the computer-keyboard piano, and how many lines the cursor moves after each entry. |

---

## 2. The studio window

```
┌────────────────────────────── Transport bar ─────────────────────────────┐
├──────────────────────────────┬──────────────────────────────────────────┤
│                              │  Parameter rack                          │
│  Patchbay                    ├──────────────────────────────────────────┤
│                              │  Scope                                   │
├──────────────────────────────┴─────────────────────────────────────┬────┤
│  On-screen piano (full width, leftmost C = edit octave)            │▲/▼ │
├──────────────────────────────┬─────────────────────────────────────┴────┤
│                              │  Timeline (arranger)                     │
│  Pattern editor              ├──────────────────────────────────────────┤
│                              │  Sample editor                           │
├──────────────────────────────┴──────────────────────────────────────────┤
│ Status bar: last message (or "Ready")                  Modified / Saved │
└──────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Resizing panes
- Drag the thin dividers between panes to resize them. A divider is highlighted when you hover over or drag it.
- Dragging the top or bottom edge of the on-screen piano resizes the piano vertically (minimum 48 pt) without shifting the opposite half's outer split; key width scales proportionally with strip height.
- Each pane has a minimum size:
  - top and bottom halves: 180 pt tall (piano minimum: 48 pt tall);
  - patchbay and pattern editor: 320 pt wide;
  - the right-hand columns: 240 pt wide.

### 2.2 Status bar
- **Left side:** the most recent message, such as "Saved", "Octave 5", "Edit on", "Count-in 3" or "Font not found: …". It reads "Ready" when there is none.
- **Right side:** **Modified** when there are unsaved changes, otherwise **Saved**.
- The window title also ends with **"•"** when the project is modified.

### 2.3 Which pane receives keyboard commands
Some shortcuts (copy, paste, delete, zoom, transpose and so on) depend on context. They go to:

- the pane containing the control you last clicked or focused; or
- if that pane can't use them, the last of these four you clicked in: **patchbay**, **pattern editor**, **timeline** or **sample editor**.

At startup that is the pattern editor. Clicking in a pane makes it the target.

Other shortcuts work no matter which pane is active: play, stop, record, edit mode, octave, undo/redo, file commands, loop, panic and appearance.

> **QA note:** after you click a transport button, that button keeps keyboard focus. Space or Return then "presses" it again instead of toggling playback. Click inside the pattern editor or patchbay to restore the normal behavior.

---

## 3. The menu bar

All menu commands can also be triggered from the keyboard.

### Dracker menu

| Item | Shortcut | What it does |
|---|---|---|
| Settings… | ⌘, | Opens the Appearance panel ([§14](#14-appearance-and-accessibility)) |
| Hide Dracker | ⌘H | Hides the app |
| Quit Dracker | ⌘Q | Quits. If there are unsaved changes, asks first ([§13.8](#138-unsaved-changes)) |

Closing the window with its close button works like **Quit Dracker**.

### File menu

| Item | Shortcut | What it does |
|---|---|---|
| New Project | ⌘N | Replaces the current project with an empty one ([§1.3](#13-what-a-new-project-contains)). Undo history is cleared. If there are unsaved changes, asks first ([§13.8](#138-unsaved-changes)). |
| New Project from Skeleton… | ⇧⌘N | Opens the skeleton generator: set tempo, time signature, key and chords, and get a new project with a bass and a piano already playing them ([§13.9](#139-new-project-from-skeleton)). Asks first if there are unsaved changes. |
| Open Project… | ⌘O | Opens an `.msv` project. If the file is invalid, the current project is kept and the error is shown in the status bar. If there are unsaved changes, asks first, before the file dialog ([§13.8](#138-unsaved-changes)). |
| Save Project | ⌘S | Saves to the current file, or asks for a name if the project has never been saved |
| Save Project As… | ⇧⌘S | Saves under a new name |
| Save Module Preset… | ⌥⌘S | Saves the selected module as a preset file ([§13.6](#136-module-presets-msym)) |
| Load Module Preset… | ⌥⌘O | Adds a module from a preset file ([§13.6](#136-module-presets-msym)) |

**Export WAV** is ⌘E. It has no menu item ([§13.4](#134-exporting-audio-wav)).

### Edit menu

| Item | Shortcut | What it does |
|---|---|---|
| Undo / Redo | ⌘Z / ⇧⌘Z | Steps back or forward through edits ([§15](#15-undo-and-redo)) |
| Cut / Copy / Paste | ⌘X / ⌘C / ⌘V | Pattern blocks in the pattern editor |
| Select All | ⌘A | Selects the whole pattern in the pattern editor |

### Transport menu

| Item | Shortcut | What it does |
|---|---|---|
| Play / Stop | ⌘Return (also Space) | Toggles song playback |
| Record | ⌘R | Starts or stops live recording ([§8.11](#811-live-recording-record-mode)) |
| Edit Mode | ⇧⌘R | Toggles edit mode (played notes are written at the pattern editor cursor) |
| Panic (All Notes Off) | ⌘. | Stops playback and silences all notes |

### View menu

| Item | Shortcut | What it does |
|---|---|---|
| Zoom In / Zoom Out / Actual Size | ⌘= / ⌘- / ⌘0 | Zooms the active pane: patchbay, timeline or sample editor |
| Appearance… | ⌘, | Opens the Appearance panel |
| High Contrast | ⌥⌘C | Switches between High and Low contrast. The checkmark shows the current mode. |

### Window menu
Minimize (⌘M) and Zoom: the standard macOS commands.

---

## 4. General controls

These behaviors are the same everywhere in the app.

### 4.1 Sliders, knobs and number boxes

| Action | Result |
|---|---|
| **Drag** | Changes the value relative to where you pressed. Number boxes increase when dragged right or up; knobs when dragged up. |
| **Shift + drag** | Fine adjustment (10× slower). You can press or release Shift mid-drag without a jump. |
| **Double-click** | Resets a slider or knob to its default. In a **number box**, starts typing a value instead. |
| **Option-click** | Resets to the default |
| **Click on a slider track** | Jumps to that position, then drags. Shift-click drags without jumping. |
| **Arrow keys** (control focused) | Up/Right increase, Down/Left decrease: 1% of the range per press (0.1% with Shift), or one step for stepped values |
| **Home / End** | Minimum / maximum |

**Typing into a number box**
1. Double-click it, press **Return**, or simply start typing digits while it is focused.
2. The current value is selected, so your first keystroke replaces it.
3. **Return** confirms, **Escape** cancels, **Tab** confirms and moves to the next control.
4. Clicking elsewhere also confirms.
5. Invalid input keeps the old value.

### 4.2 Buttons, toggles and dropdowns
- **Buttons** act when you release the mouse over them; drag off before releasing to cancel. Space or Return also presses a focused button.
- **Toggles** flip on click, Space or Return.
- **Dropdowns**
  - Click to open; click an item to choose it.
  - In the open list: **↑/↓**, Home and End move the highlight; Return or Space picks; Escape or clicking outside closes without changing anything.
  - Lists show up to 10 items and scroll with the mouse wheel.
  - **↑/↓ on a closed dropdown changes the value immediately.**

### 4.3 Context menus
- **Right-click** almost anything to see what you can do with it.
- In a context menu: ↑/↓ moves (skipping disabled items), Return or Space runs the item, Escape closes.
- Shortcut hints are shown on the right of each item.

### 4.4 Keyboard focus
- **Tab / Shift+Tab** move focus between controls, as long as the active pane doesn't use Tab itself.
- **Escape** closes the topmost popup. With no popup open, Escape ends a live recording if one is running, otherwise turns **edit mode** off if it is on, otherwise **stops playback**.

> **QA note:** in the pattern editor, Tab enters a note-off, so it does not move focus there.

---

## 5. The transport bar

Controls from left to right. If the window is too narrow, controls on the right are hidden.

| Control | Use |
|---|---|
| **Play** ▶ | Starts or pauses song playback (shows pause bars while playing). Lit during song playback. |
| **Stop** ■ | Stops and returns to line 0 |
| **Pat** (▶ with bar) | Plays only the current pattern, looping. Press again to stop. Lit while auditioning. |
| **EDIT** | Toggles edit mode. Lit (red) while on. You **must** be in edit mode to type notes into patterns at the cursor. |
| **Rec** ● | Starts or stops live recording ([§8.11](#811-live-recording-record-mode)). Blinks on the beat during the count-in, then stays lit while recording. |
| **FOLLOW** | When on (the default), the pattern editor and timeline scroll to follow the playhead |
| **LOOP** | Turns looping on or off (see below). Lit while a loop is set. |
| **BPM** | Tempo, 20–999, adjustable in steps of 0.1. Default 125. |
| **TPL** | Ticks per line, 1–255. Default 6. Fewer ticks means faster lines. |
| **SIG** | Time signature: beats per bar (1–16; drag or double-click and type) **/** beat note value (dropdown: 2, 4, 8, 16). Default 4/4. A line is always a sixteenth note, so one beat is 16 ÷ the lower number lines (4 in 4/4, 2 in 6/8, 8 in 2/2) and one bar is that times the upper number (16 in 4/4, 12 in 3/4 and 6/8). Beat and bar shading in the pattern editor, the timeline grid, ruler and snapping, and the count-in follow it. BPM still counts quarter notes. |
| **OCT** | Edit octave for the keyboard piano, −1 to 9. Default 4. |
| **STEP** | Edit step, 0–16 lines. 0 means the cursor doesn't move after entry. |
| **Device** | Audio output device: "System Default" or a specific device. The list is refreshed each time you open it. |

**LOOP button**
- If a loop is set, it clears it.
- Otherwise it loops from line 0 to the end of the last clip, or over the current pattern when there are no clips.
- With nothing to loop it shows "Nothing to loop".

**Read-outs**
- **Playhead**: `LLLL:TT  BPM`, i.e. line, tick and current tempo. Highlighted while playing.
- **Modified dot**: a small dot when there are unsaved changes.
- **DSP n%** with a load bar: audio processing load. The bar changes color above 60% and 85%; the tick shows the recent peak.
- **XR n**: the number of audio dropouts (xruns). Turns red once it is above 0.
- **Master meters** (L over R): −60 dBFS to 0 dBFS. Bands change at −12 dB and −3 dB.
- **Clip light**: lights red for 1.5 s when the master output exceeds full scale. **Click the clip light or the meters to reset it.**
- **MIDI**: lists connected MIDI sources, e.g. "MIDI: Keystep", or "MIDI: none". It refreshes when you open the device list.

**Tempo editing**
- Dragging BPM or TPL is one undo step; so is dragging the SIG number, and each choice in the SIG dropdown.
- Tempo can also be changed by pattern effects ([§8.8](#88-effect-commands)), and the boxes follow those changes.

---

## 6. The patchbay

The patchbay shows every module as a box (**node**) and every connection as a cable.

### 6.1 Reading a node
- **Header:** the module name. It is tinted by **category**, with a matching colored stripe on the left. The category name appears under the title:
  - **Core:** the Master Output;
  - **Synth:** sound sources;
  - **Effect:** processors;
  - **Control:** envelopes, LFOs, note and CV utilities.
- **Second line:** the module type.
- **Ports:** inputs on the left edge, outputs on the right edge. Port names appear when zoomed to 75% or more.
- **M / S / B badges** (top right): **M**ute, **S**olo, **B**ypass. They are filled when active. The Master Output has none.
- **Hatching:** a muted or bypassed node is hatched (tighter hatching means muted).
- **Selection:** the selected node has a thick outline plus a second outer outline.
- **Mini-scopes:** recently selected modules (up to 4) show a small waveform strip under the node.

### 6.2 Port and cable kinds
Shape and line style identify the kind even without color.

| Kind | Port shape | Cable style | Carries |
|---|---|---|---|
| Audio | Circle | Solid | Stereo audio |
| Sidechain | Double circle | Double line | A second audio input (e.g. a compressor key) |
| Event | Square | Dashed | Notes and parameter events |
| CV | Diamond | Dotted | Continuous control signals (e.g. LFO → filter cutoff) |

- Input ports are drawn hollow.
- A cable glows, and a dot travels along it, while its source module is producing signal.

### 6.3 Adding a module
1. **Right-click empty canvas.**
2. Choose **Add Synth ▸**, **Add Effect ▸**, **Add Control ▸** or **Add Core ▸**.
3. Pick the module from the second menu.

The new module appears where you right-clicked and becomes selected. Its parameters show in the rack. The Master Output is never offered, because there is only one.

You can also add preconfigured instruments and effects directly from the **instrument sidebar** on the left side of the patchbay ([§6.8](#68-the-instrument-sidebar)).

### 6.4 Connecting modules
- **Press on an output port and drag** to an input port, then release.
- While dragging:
  - every input that can accept the cable is highlighted;
  - the one under the pointer is highlighted more strongly;
  - press **Escape** to cancel.
- Releasing anywhere other than a compatible input does nothing.

**What can connect to what**

| From (output) | To (input) |
|---|---|
| Audio | Audio or sidechain inputs |
| Event | Event inputs only |
| CV | CV inputs only |

- You can't connect a module to itself, and you can't make the same connection twice.
- Rejected connections show **"Incompatible connection"** or **"Connection rejected by the graph compiler"** in the status bar. The second message appears, for example, when a cable would create a loop; use the *Feedback* module for intentional feedback loops.

**What you need for sound**
- A synth's **Audio Out** must reach the Master Output's **Input**, directly or through effects.
- Notes reach a synth from the pattern or the keyboard *by module number*, so a synth does **not** need an event cable to play. Event cables are for chaining note processors, e.g. MultiSynth → synth or Glide → synth.

### 6.5 Selecting, moving, deleting

| Action | Gesture |
|---|---|
| Select a module | Click it. Its parameters appear in the rack, and it becomes the target of the keyboard piano. |
| Move a module | Drag its body. One undo step per drag. |
| Select a cable | Click it |
| Deselect | Click empty canvas |
| Delete the selected cable or module | **Delete** (⌫) or **Forward Delete** (⌦), or the context menu |
| Mute / solo / bypass | Click the **M**, **S** or **B** badge, or use the context menu |

**Deleting**
- The selected cable is deleted first if one is selected.
- The Master Output cannot be deleted ("The output module cannot be deleted").

**Mute, solo and bypass**
- **Mute** silences the module's output.
- **Bypass** passes audio through unprocessed.
- **Solo** silences the other modules. It is a temporary listening aid: it is not saved in undo history.

### 6.6 Context menus

| Right-click on | Menu items |
|---|---|
| A node | Mute/Unmute · Solo/Unsolo · Bypass/Enable · Save Preset… · Apply Preset… · Add to Instruments… · Duplicate · Delete. All are disabled for the Master Output. |
| A cable | Delete Wire |
| Empty canvas | Add Synth ▸ · Add Effect ▸ · Add Control ▸ · Add Core ▸ · Load Preset… · Fit All · Reset Zoom |

**Duplicate** creates a copy of the module offset down and to the right, with the same parameter values. It does **not** copy cables, mute/bypass state, samples or drawn curves.

### 6.7 Navigating the canvas

| Action | Gesture |
|---|---|
| Pan | Scroll / two-finger swipe, or drag empty canvas |
| Zoom around the pointer | ⌘ + scroll, or pinch |
| Zoom in / out / 100% | ⌘= / ⌘- / ⌘0 (patchbay active) |
| Fit everything in view | Double-click empty canvas, or **Fit All** |

Zoom ranges from 25% to 300%.

### 6.8 The instrument sidebar
At the left edge of the patchbay is the collapsible **Instruments** sidebar (200 points wide; click **`<`** / **`>`** in its header to collapse or expand it). Presets are organized in collapsible group headings (**Bass**, **Keys**, **Pads & Leads**, **Drums**, **Effects**, custom group folders, and **Other** for loose `.msym` files) sorted by name. Each row displays the preset name, its module type underneath, and a **user** tag if it belongs to your library.

- **Adding from the sidebar (one undo step, unwired):**
  - **Double-click** a row (or select it and press **Return**) to add the module at the next free canvas position and select it.
  - **Drag** a row onto the canvas (the canvas highlights with a border when ready; press **Escape** to cancel) to add the module at the drop position.
  - Neither gesture adds cables automatically.
- **Navigation:** click a group header to collapse or expand it; use **↑** / **↓**, **←** (collapse or jump to header), **→** (expand or enter rows), **Home** / **End**, or scroll with the mouse wheel. Focusing the sidebar rescans the folders automatically.
- **Bundled presets:** Dracker ships with 16 built-in presets: **Electric Bass**, **Synth Bass** (*Bass*); **Electric Piano**, **Bright Piano**, **Organ**, **Bell** (*Keys*); **Warm Pad**, **Strings**, **Saw Lead**, **Pluck** (*Pads & Leads*); **Drum Kit**, **Kick** (*Drums*); **Room Reverb**, **Tempo Delay**, **Bus Compressor**, **Warm Overdrive** (*Effects*).
- **Managing user presets:**
  - Right-click any module (except Master Output) and choose **Add to Instruments…** to save it into your user folder by name and group (existing names get ` 2`, ` 3`, …).
  - Right-click a **user** row in the sidebar for **Rename…**, **Move to group ▸**, **Remove…** (moves the `.msym` file to `~/.Trash` after confirmation), and **Show in Finder**. Bundled presets are read-only and offer none of these actions. Failures (such as a read-only folder or invalid name) appear in the status bar.

> **QA note:** cable gain can't currently be changed in the GUI. The thickness of a cable reflects its gain, which is 1.0 for every cable drawn in the GUI.

---

## 7. The parameter rack

The rack shows the parameters of the module **selected in the patchbay**. With nothing selected it says **"No module selected"**.

### 7.1 Header
- The module name and type.
- Three toggles: **M** (mute), **S** (solo), **B** (bypass), in the same order as the badges on patchbay modules.

> **QA note:** the order is M B S here, but M S B on the patchbay badges.

### 7.2 Parameter rows
One row per parameter, showing its name, the control, and its current value and unit.

The control depends on the parameter:

| Parameter type | Control |
|---|---|
| Continuous | Slider. Frequencies and times use a logarithmic slider. |
| On/off | Toggle |
| A few whole-number choices (up to 16) | Dropdown of numbers |
| Many whole-number steps | Stepped slider |

Editing:
- Use the controls as in [§4.1](#41-sliders-knobs-and-number-boxes). Each drag or change is one undo step.
- **Double-click the parameter name** to reset it to its default.
- **Right-click a row** for: **MIDI Learn** · **Remove MIDI Mapping** (only if mapped) · **Reset to Default**.

Choice parameters show the name of each value (Analog Generator *Waveform*: Sine, Triangle, Saw, Square, Noise, Drawn); on/off switches show *Off* and *On*. Parameters whose values are plain counts (Unison, Repeats, FFT Size and a few others) show numbers. [Appendix B](#appendix-b-module-reference) lists every module's names; the composition helper takes the same names (`Waveform=Saw`).

### 7.3 MIDI Learn: controlling a parameter from hardware
1. Right-click a parameter row and choose **MIDI Learn**. The row shows **"learning…"** with an outline.
2. Move a knob or fader on your MIDI controller. The **first Control Change (CC) message on any channel** is assigned to the parameter across its full range.
3. The row now shows a **CC n** badge.

- To cancel, choose **Cancel MIDI Learn**. Selecting another module also cancels.
- Remove a mapping with **Remove MIDI Mapping**.
- Mappings are saved in the project.

### 7.4 Special editors under the rows
Some modules get a graphic editor below their parameters.

**Curve editors**

| Module | Section | What the curve shapes |
|---|---|---|
| WaveShaper | **Transfer Curve** | The distortion shape |
| MultiSynth | **Note Curves** | Choose **Velocity Curve** or **Pitch Offset** |
| MultiCtl | **Map Curve** | Maps input to output |

Editing a curve:
- **Drag** a point to move it; Shift gives fine movement.
- **Double-click** empty space to add a point (up to 64).
- **Right-click** a point, or select it and press Delete, to remove it.
- **Arrow keys** nudge the selected point.
- Each edit is applied when you release the mouse, as one undo step.

**Envelope**
- Shown for modules with Attack, Decay, Sustain and Release parameters. Dragging the four points edits A/D/S/R together.

**MetaModule**
- Shows a list of its inner modules. Click one to edit its parameters, and **Back** to return.

> **QA note:** edits inside a MetaModule **cannot be undone**; the rack says so in warning color. MIDI Learn is unavailable for inner modules.

---

## 8. The pattern editor

The pattern editor is where you write music. Time runs downward, one **line** per row. Each **track** is a column of cells.

### 8.1 The header strip
- **View bar** (the row above the header): **Tracker**, **Piano roll** and **Drumpad**. The current view's button has a 2-point outline and a bar under its name. Normal patterns offer **Tracker** and **Piano roll** (starting in Tracker); drum patterns offer **Drumpad** and **Tracker** (starting in Drumpad). Views that the current pattern type does not offer are disabled. The chosen view is remembered per pattern while Dracker runs; it is not saved in the project.
- **Pattern dropdown:** chooses the pattern to edit. Items show the pattern's id in hex followed by `[D] ` for drum patterns and the pattern name. Right-click (or click **`...`**) opens the pattern menu (`New Pattern`, `New Drum Pattern`, `Convert to drum pattern` / `Convert to normal pattern`, `Duplicate Pattern`, `Delete Pattern`).
- **Renaming a pattern:** double-click the pattern dropdown. A text field opens over it with the current name selected. Type the new name and press **Return** (or click elsewhere) to confirm, or **Escape** to cancel. If another pattern already has that name, a number is added to the end (Drums, Drums1, Drums2, …). An empty name is ignored. Renaming is undoable. You can also rename from the timeline ([§9.3](#93-editing-clips)).
- **Trk:** number of tracks, 1–64 (shown in **Tracker** view only). On a drum pattern, adding or removing tracks adds or removes drum lanes up to 64 lanes.
- **Lin:** number of lines, 1–4096 (pattern length in steps for Drumpad). Resizing is undoable.
- **Add:** creates a new empty normal pattern the same size as the current one, and selects it.
- **+Drum:** creates a new 1-bar drum pattern with four default DrumSynth lanes (`Kick`, `Snare`, `Closed Hat`, `Open Hat`; adding and wiring a DrumSynth module named `Drums` if the project has none), and opens it in **Drumpad**.
- **Dup:** duplicates the current pattern (keeping drum pattern type and lanes); the copy is named "*name* copy".
- **Del:** deletes the current pattern **and every timeline clip that uses it**. Undo restores both. The last remaining pattern can't be deleted.
- **`...`:** opens the pattern actions menu (adding normal/drum patterns, converting between normal and drum patterns, duplicating, deleting).
- **Info text:** `Oct N  Step N`, plus **EDIT** in edit mode, **REC** while live recording, and **FOLLOW** when following.

Up to 256 patterns are allowed.

### 8.2 Reading a cell
Each cell of a track reads:

```
NNN VV MM CCEE XXYY
C-4 80 02 ..   ....
```

| Field | Meaning | Values |
|---|---|---|
| **NNN** | Note | e.g. `C-4`, `F#5`; `---` empty; `===` note-off |
| **VV** | Velocity (loudness) | `00`–`80` hex (`80` = full); `..` uses the default (80% loudness) |
| **MM** | Module | The module number to play (shown in hex); `..` keeps the module last used on this track |
| **CC** | Controller | The parameter number to set (1 = first parameter); `..` = none |
| **EE** | Effect | Effect command in hex ([§8.8](#88-effect-commands)); `..` = none |
| **XX** | Controller page | High byte of the controller number, for modules with more than 255 parameters |
| **YY** | Value | The effect's parameter, or the controller value `00`–`FF` |

Other things you'll see:
- Rarely used commands appear in the note column as `AOF` (all notes off), `PIT` / `PRV` (pitch commands) and `STP` (stop song). They come from imported data; they can't be typed.
- **Line numbers** are in hexadecimal.
- **Row shading:** lines on a beat are shaded, and lines that start a bar are shaded more strongly with a rule above them and a bold line number. Beats and bars follow the time signature (**SIG** in the transport bar, [§5](#5-the-transport-bar)): in 4/4 every 4th and every 16th line, in 3/4 every 4th and every 12th, in 6/8 every 2nd and every 12th.
- The **playhead** row is tinted, with a red marker at its left edge.
- The **cursor** row is lightly tinted, and the cursor field has a solid outline.
- **Track headers** show the track number and a colored strip.

> **Module numbers** are the ids shown in the save file, assigned in creation order (the Master Output is 1). The first module you add is usually 2.

### 8.3 Moving the cursor

| Key | Moves |
|---|---|
| ← / → | Between fields of a cell, then into the neighboring track |
| ↑ / ↓ | One line |
| Page Up / Page Down | 16 lines |
| Home / End | First / last line |
| ⌥← / ⌥→ | Previous / next track (same field) |
| ⇧Tab | Previous track |
| ⌘[ / ⌘] | Previous / next pattern (no wrap-around) |
| Click | Places the cursor on the exact field clicked |
| Double-click | Places the cursor on the note field of the clicked row and turns **edit mode** on |
| Scroll | Vertical scrolls lines; horizontal, or Shift+scroll, scrolls tracks |

### 8.4 Entering notes and values
**Turn on edit mode first** (⇧⌘R, the **EDIT** button, or **double-click a row** in the pattern editor). Outside edit mode, keys only *play* sounds; nothing is written. Press **Escape** to leave edit mode. Edit mode and live recording ([§8.11](#811-live-recording-record-mode)) are separate: turning one on turns the other off.

After a double-click, the next note you play on the computer keyboard, a MIDI keyboard or the on-screen piano is written to that row, and the cursor then moves down by the **edit step** as usual. Set the step to 0 to keep entering notes on the same row.

**Notes (cursor in the NNN field)**
- Press a piano key ([§12.1](#121-the-computer-keyboard-piano)). The note is written at the current **edit octave** with full velocity, and the cursor moves down by the **edit step**.
- The module written into **MM** is chosen in this order:
  1. the module selected in the patchbay;
  2. the cell's existing module;
  3. the nearest module above on the same track.
- Notes are always auditioned as you type, so you hear what you enter.
- Notes are never written for the **Master Output** module. If it is selected (or would be inherited from the cells above), nothing is written, the cursor stays put, and the status bar shows "Master Output can't play notes; select an instrument module". Select an instrument module in the patchbay first.

**Other entries**
- **Note-off:** press **Tab** to write `===`, which releases the playing note.
- **Hex fields (VV, MM, CC, EE, XX, YY):** type **0–9** and **A–F**. Each keypress sets one digit and moves by the edit step. Velocity is limited to `80`.

**Octave and step**
- **Octave:** F1 / F2 (−1 to 9), or the transport **OCT** box.
- **Edit step:** ⌥↑ / ⌥↓ (0–64 while the pattern editor is active), or the transport **STEP** box (0–16).

### 8.5 Deleting

| Key | Effect |
|---|---|
| **Delete** (⌫) | With a selection, clears it. Otherwise clears the field under the cursor (the whole cell when on the note field) and moves down. |
| **Forward Delete** (⌦) | Clears the selection, or the cursor cell, without moving |

Both work without edit mode.

### 8.6 Selecting blocks
- **Drag** with the mouse. The view scrolls when you drag past the top or bottom.
- **Shift+click** extends from the cursor.
- **Shift + any cursor key** extends the selection.
- **⌘A** selects the whole pattern.

Selections are always rectangles of whole cells. Changing pattern clears the selection.

### 8.7 Block operations
Each operation is a single undo step.

| Operation | Shortcut | Notes |
|---|---|---|
| Copy | ⌘C | Copies the selection, or the cursor cell. Status "Copied W x H". |
| Cut | ⌘X | Copy, then clear |
| Paste | ⌘V | Pastes at the cursor, clipped to the pattern. Empty cells in the block overwrite too. The pasted area becomes selected. |
| Transpose ±1 | ⌘↑ / ⌘↓ | Moves real notes by a semitone. Notes that would go out of range are left unchanged. |
| Transpose ±12 | ⇧⌘↑ / ⇧⌘↓ | One octave |
| Interpolate | ⌘I | Needs a selection of 2+ lines. Ramps values from the first to the last filled cell of each track (see below). |

**Interpolate details**
- The field ramped depends on the cursor: **CC/XX** → controller number, **EE/YY** → effect value, anywhere else → velocity.
- If only the first and last cells are filled, all cells between them are filled in. Otherwise only the existing in-between cells are adjusted.

**Context menu** (right-click)
- Cut, Copy, Paste, Delete
- Select All
- Transpose +1 / −1 / +12 / −12
- Interpolate

> **QA note:** the context menu labels Interpolate as "Cmd+J", but the shortcut is **⌘I**.

**Clipboard format**
- Blocks are copied as plain text beginning `Dracker-Block-v1 <tracks> <lines>`, so you can paste them between projects or into a text editor.

### 8.8 Effect commands
Type the code (hex) into **EE** and the parameter into **YY**. "Tick" means one subdivision of a line (see TPL).

| EE | Effect | YY |
|---|---|---|
| `01` / `02` | Slide pitch up / down every tick | Speed in 1/16 semitone (00 = reuse last) |
| `03` | Portamento: glide to the new note | Speed in 1/8 semitone per tick (00 = reuse) |
| `04` | Vibrato | X = speed, Y = depth (1/16 semitone) |
| `05` / `06` | Pitch offset up / down (immediate) | In 1/16 semitone |
| `07` | Sample offset (coarse) | Start position = YY/256 |
| `09` | Sample offset (fine) | YY/4096 |
| `08` | Arpeggio | Cycles root, +X, +Y semitones each tick |
| `0A` | Velocity slide | X = up per tick, Y = down per tick (in 1/64) |
| `0F` | Set speed | `01`–`1F` sets ticks per line; `20`+ sets BPM |
| `11` / `12` | Fine slide up / down (once) | In 1/32 semitone |
| `13` | Bypass module | ≠00 bypass, 00 un-bypass |
| `14` | Mute module | ≠00 mute, 00 unmute |
| `19` | Retrigger | Every (Y) ticks |
| `1C` | Note cut | At tick (YY & 1F) |
| `1D` | Note delay | Start at tick (YY & 1F) |
| `1F` | Set BPM | BPM = YY (if > 0) |
| `20` | Probability | Chance = YY/255 |
| `21`–`2F` | Probability (extended) | Combined with YY low digit |
| `30` | Stop song | — |
| `31` | Jump to line | Line = YY |
| `40`–`5F` | Sub-line delay | Delays by (EE − 40)/32 of a line |

**Controller automation.** Put a parameter number in **CC** (1 = first parameter in the rack) and a value in **YY** (`00`–`FF` covers the parameter's whole range). For example, `CC=04, YY=80` sets the 4th parameter to its midpoint.

### 8.9 Entering notes from MIDI in edit mode
With **edit mode** on and a MIDI keyboard connected:

- **Stopped (step recording):** notes are written at the cursor line. Chords spread across successive tracks. The cursor then moves by the edit step.
- **Playing (live recording):** notes are written at the line under the playhead, in whichever clip of this pattern is playing. Notes that fall outside every clip of the current pattern are dropped.

Velocity is taken from the MIDI note. Note-offs are not recorded in edit mode; add `===` by hand where needed. To record a performance with note lengths, use live recording ([§8.11](#811-live-recording-record-mode)).

### 8.10 Following the playhead
- **⌘F**, or the FOLLOW button, toggles follow mode. It is on by default.
- While playing, the editor keeps the playhead line centered.
- When auditioning a pattern (Pat / ⇧Space), the playhead wraps within the pattern.

### 8.11 Live recording (Record mode)
Live recording captures what you play on the computer keyboard, a MIDI keyboard or the on-screen piano into a **new pattern**, in time with the song.

**Starting**
1. Select an **instrument module** in the patchbay. Recording does not start with nothing or the **Master Output** selected ("Select an instrument module to record").
2. Put the playhead where the take should start (click the timeline ruler, or stop there).
3. Press **⌘R** or the **Rec** button. Edit mode turns off.

**Count-in**
- Playback starts **one bar** before the record point, but at least **two beats**, with a metronome click on every beat; the first click is higher. Beats and bars follow the time signature (**SIG**, [§5](#5-the-transport-bar)): in 4/4 the count-in is 4 beats of 4 lines (16 lines), in 3/4 3 beats (12 lines), in 6/8 6 beats of 2 lines (12 lines), in 2/2 2 beats of 8 lines, and in 1/4 2 beats (8 lines).
- Where those lines exist, the song plays under the count-in (pre-roll). Before line 0 there is only the click.
- The status bar counts down ("Count-in 4" … "Count-in 1" in 4/4; it starts from the number of count-in beats), then shows "Recording". The **Rec** button blinks on the beat during the count-in.
- The song loop is ignored while recording, so the playhead keeps moving forward. The loop itself is not changed.

**What is recorded**
- Each note is placed on the **nearest line** to when you pressed it.
- Notes pressed **less than one line apart** count as a chord: they go on the **same line**, one track each.
- Each new note goes on the first track that is not holding a note, so held notes keep sounding under later ones.
- Releasing a key writes a note-off (`===`) at the nearest line, at least one line after the note.
- Notes are written for the module selected at the time, with their velocity (computer keyboard: full; on-screen piano: `6D`; MIDI: as played).
- Notes played during the count-in are not recorded, except within half a line before the record point (they go on the first line).

**Stopping**
- Press **⌘R** or **Rec** again, **Escape**, **Stop**, **Space**/**Play**, or **Pat**. Playback stops and the playhead returns to the record point.
- The take becomes a new pattern named **Take NN**, trimmed to the last 16-line bar used (at least 4 tracks). A clip for it is placed at the record point on the **first timeline lane that is free** for its length, and it becomes the current pattern.
- Adding the take is **one undo step** ("Record Take"). A take with no notes adds nothing ("Recording stopped: no notes recorded").
- Turning edit mode on (⇧⌘R, **EDIT**, or double-clicking a row) also ends the take.

### 8.12 The piano roll
Click **Piano roll** in the view bar on any normal pattern to edit notes in a time-by-pitch grid of the same underlying pattern cells:

- **Layout:** vertical piano keys (`C-1` to `G9`, octaves labelled on every C, black keys shaded and indented), horizontal bar/beat grid following the time signature (**SIG**), module picker in the top bar (defaults to the patchbay selection), playhead line with **FOLLOW**, horizontal/vertical scroll, and zoom (`⌘=` / `⌘-` / `⌘0`, `⌘` + scroll, or pinch). Notes of the picked module are filled with a border; notes of other modules are outlined in the background.
- **Velocity strip:** the strip below the grid shows a bar for each selected note (or all picked-module notes when none are selected). Drag up/down on a bar to adjust velocity.
- **Editing gestures (one undo step each, snapped to lines):**
  - Click empty space to add a note (inheriting the last edited note's length, initially one beat) and audition it. Click a piano key on the left to audition pitches.
  - Drag a note body to move it in time and pitch; **⌥-drag** copies selected notes (preserving effect columns); drag a note's right edge to resize it. Press **Escape** mid-drag to cancel.
  - Drag across empty grid space for a rubber-band selection; **Shift-click** or **Shift-drag** toggles/adds to the selection. **Delete** / **Forward Delete** removes selected notes.
  - Clipboard & transpose: `⌘A` selects all picked-module notes; `⌘X` / `⌘C` / `⌘V` cut, copy, and paste using plain text beginning `DRACKER-ROLL-V1` (keeping effect columns); `⌘↑` / `⌘↓` transpose ±1 semitone; `⇧⌘↑` / `⇧⌘↓` transpose ±12 semitones. Right-click opens the context menu.
- **Track mapping and messages:** overlapping notes are placed automatically on a free same-module track, an empty track, or a new track up to 64 (reporting `"Added track N"` in the status bar). Overlapping two notes of the same module and pitch, selecting **Master Output**, or running out of tracks refuses the edit without losing existing notes and explains why in the status bar. Existing effect columns and other modules' cells remain intact.

### 8.13 Drum patterns and the drumpad
A **drum pattern** keeps the normal pattern cell grid while storing a lane table (name, module, note) per track and a `[D]` flag in the pattern dropdown and timeline.

- **Creating and timeline badges:** click **+Drum** (or **New Drum Pattern** in the pattern menu) to create a 1-bar drum pattern with `Kick` (36), `Snare` (38), `Closed Hat` (42), and `Open Hat` (46) mapped to your DrumSynth (adding and wiring one named `Drums` if needed). Drum patterns appear prefixed with `[D]` in the pattern dropdown and timeline clips, and draw step dots in timeline miniatures.
- **Lanes:** each row shows the lane name and a lane menu button (`▾`). Click a lane name to audition that drum. Use the lane menu to change **Module**, pick a GM **Note** or **Set MIDI Note…**, **Rename…**, **Move Up** / **Move Down**, or **Remove Lane**, or click **+ Lane** below the last lane to append one. If a lane's module is missing, its label shows `[unassigned]` and diagonal hatching.
- **Step pads:** beat and bar spacing follow **SIG**, with bar numbers in the ruler and the playhead column highlighted. Click a pad to toggle a hit; drag across pads to paint or erase as one undo step; drag vertically on a hit to change velocity (or **⌥-click** to cycle soft / medium / loud), which also updates that lane's velocity for new hits. Hits whose cell module or note differs from their lane show a corner mark.
- **Tracker view & converting:** switch between **Drumpad** and **Tracker** in the view bar at any time (adding/removing tracks in Tracker adds/removes lanes, up to 64 lanes). Open the **`...`** menu or right-click the pattern dropdown to run **Convert to normal pattern** or **Convert to drum pattern** (one undo step each).

---

## 9. The timeline

The timeline (arranger) decides **when** each pattern plays. Time runs left to right in lines; each horizontal **lane** can hold clips.

### 9.1 Reading the timeline
- **Ruler** (top): line numbers. Bar ticks are taller. Click or drag on the ruler to **move the playhead**.
- **Loop strip** (under the ruler): shows and sets the loop range.
- **Lane headers** (left): the lane number and three buttons, **M**, **S** and **ST**.
- **Corner label:** "Follow" or "Arranger".

**Clips**
- Each clip is colored by its pattern and labeled with:
  - a **letter A–H** that matches its color;
  - **⧉** if it is a clone;
  - **ST** if it is a Supertrack;
  - the pattern name.
- A **stripe pattern** along the bottom also matches the color.
- At closer zoom, a miniature of the notes is drawn.
- If a clip is longer than its pattern, the pattern repeats.

**Clip states**
- **Muted** clips, and non-soloed clips while something is soloed, are dimmed and hatched.
- **Soloed** clips have a green outline.
- The **selected** clip has a thick outline. Other clips of the same pattern have a thin "family" outline.

### 9.2 Creating clips
- **Double-click an empty spot** to place a clip of the *current* pattern (the one in the pattern editor, which is the pattern of the clip you selected last). Its length is the pattern's length.
- **Right-click an empty spot** and choose **Add Clip: *pattern name***.

### 9.3 Editing clips

| Action | Gesture |
|---|---|
| Select, and open its pattern in the pattern editor | Click. The pattern editor shows the clip's pattern in the view (Tracker, Piano roll or Drumpad) last used for that pattern. A right-click selects the clip in the same way. |
| Rename its pattern | Double-click the clip's **name label**, type the new name, press Return. Every clip of that pattern shows the new name; duplicate names get a number added ([§8.1](#81-the-header-strip)). |
| Move (in time and between lanes) | Drag the body |
| Resize | Drag the right edge (minimum 1 line) |
| **Clone** | **⌥-drag**. The clone plays the *same* pattern, so edits appear in both. |
| Cancel a drag | Escape |
| Delete | Delete / ⌫ |

- A ghost preview shows during a drag; releasing commits one undo step.
- Clicking an empty spot clears the selection. The pattern editor keeps showing the same pattern.
- **Snapping:** no modifier snaps to the beat; **Shift** to 1 line; **⌘** to the bar. Beats and bars follow the time signature (in 4/4: 4 and 16 lines; in 3/4: 4 and 12; in 6/8: 2 and 12). The grid lines (bars stronger than beats) and the ruler follow it too; ruler labels are line numbers placed on beats or bars.

**Clip context menu**
- Mute / Unmute
- Solo / Unsolo
- Supertrack / Clear Supertrack
- **Make Unique:** gives a clone its own copy of the pattern, so you can edit it separately.
- **Set Loop To Clip**
- Delete

### 9.4 Lanes and Supertracks
Each lane-header button applies to **every clip in the lane**:

- **M** mutes the lane.
- **S** solos the lane.
- **ST** makes every clip in the lane a Supertrack.

A button is lit only when all clips in the lane have that state. A small bar under the lane number means at least one clip is a Supertrack.

**Supertrack:** normally each clip starts with fresh playback memory: no held note, slides or effect state. A Supertrack clip shares that memory with the lane instead, so a held note or slide carries over smoothly from one clip to the next.

### 9.5 Looping
- **Drag in the loop strip** to set a loop. The loop is shaded across all lanes.
- **Double-click the loop strip** to clear it.
- **⌘L** clears an existing loop, or loops the whole song (status "Loop song").
- The **LOOP** button also works when there are no clips (it loops the current pattern).
- **Set Loop To Clip** in a clip's context menu loops just that clip.

### 9.6 Zoom and scroll
- **Zoom:** ⌘= / ⌘- / ⌘0 (timeline active), ⌘ + scroll, or pinch.
- **Scroll:** horizontally through time; vertically through lanes.
- **Follow:** while following, the view jumps forward when the playhead nears the right edge.

---

## 10. The sample editor

The sample editor works with the **Sampler** module. Select a Sampler in the patchbay; otherwise the editor says "Select a Sampler module to edit samples".

### 10.1 Toolbar
- **Slot dropdown:** 16 slots per Sampler. Each slot shows its length, e.g. "3: 1.25s", or "empty".
- **Import…:** loads an audio file into the current slot.
- **Loop mode:** Loop Off, Forward or Ping-Pong.
- **Zoom:** −, +, Fit.

> **QA note:** the loop mode applies to the whole Sampler (all slots), not just the current slot.

### 10.2 Importing a sample
1. Select a Sampler and choose a slot.
2. Click **Import…** and pick a WAV, FLAC, MP3 or OGG file.

- Mono files play on both channels.
- The sample is mapped across all keys (0–127) with root note 60. The root note plays the sample at its original pitch.
- The import is one undo step.

> **QA note:** the dialog also offers AIFF (`.aif`/`.aiff`), but AIFF decoding isn't supported in this build, so expect "Import failed". Drag-and-drop import isn't implemented.

### 10.3 Key range
- **Root**, **Low** and **High** (MIDI note numbers 0–127) set which keys play the slot and at what pitch.
- If Low ends up above High, the other value is adjusted to match.

### 10.4 Waveform and loop points
- The waveform shows L above R, with the loop region shaded.
- **Drag the loop start or end flag** to move it.
- **Zoom:** "+" / "−" / "Fit", ⌘= / ⌘- / ⌘0, ⌘ + scroll, or pinch. Plain scroll pans.

### 10.5 Amplitude envelope
The envelope under the waveform shapes the sample's volume over time. It has 3–8 points.

- **Drag** a point; Shift gives fine movement.
- **Double-click** empty space to add a point.
- **Right-click** a point, or press Delete, to remove it.
- **Option-click** an inner point to make it the **sustain point**, where the volume holds while the key is held. It is drawn with a dashed line and can't be removed.

The first and last points are fixed at zero.

There are no destructive operations (trim, normalize, reverse) in this build.

---

## 11. The scope

The scope shows a live picture of the sound.

| Control | Choices |
|---|---|
| **Mode button** (cycles on click) | **Scope**: waveform with L solid and R dashed, triggered for a stable picture · **Spectrum**: frequency analyzer 20 Hz–Nyquist, 0 to −90 dB, with a dashed peak-hold trace · **Vector**: goniometer showing stereo width (mid up, side across) |
| **Source dropdown** | **Selected module** (the default), which follows the patchbay selection and falls back to Master when nothing is selected, or **Master** (the final mix) |

The scope shows "No signal" when there is no audio, and updates continuously only while playing or while audio is running.

---

## 12. Playing live

### 12.1 The computer-keyboard piano
When no shortcut uses a key, the letter keys play the **selected module** like a piano, two octaves wide. It works whenever edit mode is off, and in the pattern editor's note field while it is on. During live recording every played key is recorded ([§8.11](#811-live-recording-record-mode)).

```
 Upper octave (+1):   2 3   5 6 7   9 0
                     Q W E R T Y U I O P      → C D E F G A B C D E
 Lower octave:        S D   G H J
                     Z X C V B N M            → C D E F G A B
```

| Row | Keys → notes |
|---|---|
| Lower | **Z** C · **S** C# · **X** D · **D** D# · **C** E · **V** F · **G** F# · **B** G · **H** G# · **N** A · **J** A# · **M** B |
| Upper | **Q** C · **2** C# · **W** D · **3** D# · **E** E · **R** F · **5** F# · **T** G · **6** G# · **Y** A · **7** A# · **U** B · **I** C · **9** C# · **O** D · **0** D# · **P** E |

- **F1 / F2** shift the octave. At octave 4, **Z** plays middle C (MIDI 60).
- Keys play only when a module is selected, and they don't auto-repeat.
- Hold several keys for chords.

### 12.2 On-screen piano keyboard
A stark black-and-white high-contrast piano strip sits across the full viewport width above the pattern editor and timeline:

- **Layout & resizing:** The leftmost key is always **C** of the current **edit octave** (each visible **C** key shows its octave number below the black keys). Drag the top or bottom border of the strip to resize it; key widths scale proportionally with height.
- **Octave buttons:** Click the stacked **up/down** buttons at the far right to shift the shared edit octave (`-1` to `9`, synchronized with the transport **OCT** box and **F1 / F2**).
- **Playing & recording:** Click or drag across keys to play notes on the **selected module**. In **edit mode**, clicked keys also insert notes into the pattern editor; during live recording they are recorded into the take.
- **Live highlighting:** Active keys highlight in the theme's accent color for mouse presses, computer-keyboard piano holds, external MIDI input, and pattern playback targeting the currently selected module.

### 12.3 MIDI keyboards and controllers
- All connected MIDI sources play the **selected module**. The transport shows which sources are connected.
- Map controller knobs to parameters with **MIDI Learn** ([§7.3](#73-midi-learn-controlling-a-parameter-from-hardware)).
- Enter MIDI notes at the cursor in edit mode ([§8.9](#89-entering-notes-from-midi-in-edit-mode)), or record a performance with live recording ([§8.11](#811-live-recording-record-mode)).

### 12.4 Panic
**⌘.** stops playback and silences everything. Use it if a note gets stuck.

---

## 13. Files

### 13.1 Project files (`.msv`)
A project file stores everything about the song:

- title and tempo;
- every module with its position, name, mute/bypass state, parameters and loaded samples or curves;
- every cable;
- every pattern;
- every timeline clip;
- MIDI mappings;
- the loop range;
- the time signature (set with **SIG** in the transport bar, [§5](#5-the-transport-bar)) and the key of the song. The key is chosen in the skeleton generator ([§13.9](#139-new-project-from-skeleton)) and has no other control yet; it is kept when the project is saved again. New projects are 4/4 in C major.

It does **not** store editor state: edit octave, edit step, edit/follow, selection or zoom.

Projects use format version 1. Files from a future version are refused with "Unsupported .msv format version". Unknown extra data from newer builds is skipped where possible.

### 13.2 Saving
- **⌘S** saves to the current file. **⇧⌘S** saves under a new name; the default name is the current file name, or "Untitled.msv".
- The status bar confirms with "Saved …" or shows "Save failed: *reason*".
- The window title shows the file name, with "•" while there are unsaved changes.

### 13.3 Opening
- **⌘O** shows the "Open Project" dialog, which accepts `.msv` files.
- The file is fully checked before it replaces your current project. If anything is wrong, your current project is untouched and the status bar explains why.
- After opening, undo history is cleared and the playhead is at line 0.

### 13.4 Exporting audio (WAV)
**⌘E** shows the "Export WAV" dialog; the default name is the project name with `.wav`.

- **What is rendered:** the whole song from line 0 to the end of the last non-muted clip, plus a 2-second tail for reverb and echo. The loop is ignored, and there is a 30-minute cap.
- **Format:** stereo 32-bit floating-point WAV at the session sample rate (normally 44,100 Hz).
- **Progress:** the export runs in the background while you keep working. The status bar shows "Exporting …", then "Exported …" or "Export failed: …". Only one export can run at a time.

> **QA note:** stem export (one file per module) exists internally but isn't available from the GUI yet.

### 13.5 Importing
| What | How |
|---|---|
| Audio samples | Sample editor **Import…** ([§10.2](#102-importing-a-sample)) |
| Color palettes (`.stpalette`) | Appearance panel **Import…** ([§14.4](#144-custom-palettes)) |
| Pattern blocks (text) | Paste with ⌘V into the pattern editor |

| Module presets (`.msym`) | **Load Preset…** / **Apply Preset…** ([§13.6](#136-module-presets-msym)) |

> **QA note:** MIDI file, XM and SunVox import and autosave exist in the engine but have no GUI yet.

### 13.6 Module presets (`.msym`)
A preset file stores one module: its type, name, parameter values and extra data (such as a drawn waveform, curves, or a MetaModule's inner project). It does not store cables.

| To | Do this |
|---|---|
| Save a module as a preset | Right-click the module → **Save Preset…**, or select it and use **File ▸ Save Module Preset…** (⌥⌘S). The default file name is the module's name. |
| Save a module to the instrument library | Right-click the module → **Add to Instruments…** ([§6.8](#68-the-instrument-sidebar)) |
| Add a module from a preset | Right-click empty canvas → **Load Preset…** (the module appears where you clicked), or **File ▸ Load Module Preset…** (⌥⌘O; it appears to the right of the existing modules). The new module is selected and has no cables. |
| Apply a preset to an existing module | Right-click the module → **Apply Preset…**. The module's parameters and extra data are replaced; its name, position, cables and mute/bypass state are kept. The preset must be for the same module type, and MetaModules can't be applied to (load the preset as a new module instead). |

Loading and applying are each one undo step. The Master Output can't be saved or applied to. Problems are reported in the status bar ("Load preset failed: …", "Apply preset failed: …").

**Library folders:** bundled presets ship inside `Contents/Resources/Presets` in the `.app` bundle (or `resources/presets` beside a development build). User presets are stored under `~/Library/Application Support/Dracker/Instruments/<Group>/` (presets placed directly inside `Instruments/` appear under **Other**). The sidebar rescans on focus; unreadable files or unknown module types are skipped automatically.

### 13.7 Preferences
Appearance settings are saved separately from projects, in `~/Library/Application Support/Dracker/appearance.cfg`. If this file is damaged, the app uses the defaults and shows "Appearance settings ignored (…); using defaults".

### 13.8 Unsaved changes
**New Project**, **Open Project…**, **Quit Dracker**, the window's close button and **Quit** in the Dock icon's menu replace or close the open project. If it has unsaved changes (the window title shows "•"), Dracker first asks **Discard unsaved changes?**:

- **Discard changes** (or **Return**) goes ahead; the changes are lost.
- **Cancel** (or **Escape**, or a click outside the question) keeps the project; the status bar shows "Kept the open project". Save with ⌘S, then try again.

While the question is shown, other shortcuts, piano keys and clicks elsewhere in the window do nothing. **Tab** moves between the two buttons. Open Project asks before the file dialog appears.

**Logging out, restarting or shutting down** the Mac quits Dracker **without asking**, so that macOS is not held up: unsaved changes are lost, and a WAV export that is still running is cancelled. Save before you log out.


### 13.9 New Project from Skeleton
**File ▸ New Project from Skeleton…** (⇧⌘N) opens a panel that builds a starting project from a few musical choices: the tempo, time signature and key, and a chord progression played by a bass and a piano.

The panel stays open until you press **Create**, **Cancel** or **Escape**; clicks outside it and keyboard shortcuts do nothing while it is open. **Tab** and **⇧Tab** move between its controls. In a small window its contents scroll. When you open it again, it shows the values you used last (until Dracker quits).

**Project**

| Field | Values |
|---|---|
| Title | Any text; empty becomes "Untitled" |
| Tempo | BPM 20–999 and ticks per line 1–255, as in the transport bar |
| Time signature | 1–16 beats over 2, 4, 8 or 16 ([§5](#5-the-transport-bar)) |
| Key | Tonic and **Major** / **Minor** (natural minor). Tonic names follow the key: F, B♭, E♭, A♭ and D♭ major and their relative minors use flats (shown as "b"), the other keys sharps. |

**Chord progression**

Type chords into **Chords** and press **Return** (or **Add**). Each chord becomes a block of one bar at the end of the progression. Separate chords with spaces, commas, `-` or `->`. Two ways of writing a chord can be mixed:

| Form | How to write it | Examples |
|---|---|---|
| Roman numeral (follows the key) | I–VII, counted on the key's own scale. Upper case = major family, lower case = minor family. Optional `b` or `#` before it (or ♭ / ♯). Upper-case endings: none (major), `7`, `maj7`, `aug` or `+`, `sus2`, `sus4`. Lower-case endings: none (minor), `7` (minor 7), `dim` or `°`, `dim7` or `°7`, `m7b5` or `ø`, `sus2`, `sus4`. No slash. | `ii V7 I`, `bVII`, `vii°`, `iiø7`; in A minor `III` is C major |
| Chord name (stays as written) | A–G (capital) with `#` or `b`, then nothing (major), `m`, `dim`, `aug`, `sus2`, `sus4`, `7`, `maj7`, `m7`, `m7b5`, `dim7`. Optional bass note after `/`. | `Dm7, G7, Cmaj7`, `C/E`, `F#m`, `Bbmaj7` |

If a chord can't be read, nothing is added and the reason appears under the field, for example *"Idim": Write diminished and half-diminished chords in lower case (vii°)*.

**Presets:** choose one and press **Insert**. Its chords are inserted after the selected block, or at the end. Presets are written as Roman numerals, so they follow the key; only the presets of the key's mode are listed.

| Major keys | Minor keys |
|---|---|
| Circle of fifths: iii - vi - ii - V - I | Minor pop: i - VI - III - VII |
| Pop: I - V - vi - IV | Minor three chords: i - iv - v |
| Fifties: I - vi - IV - V | Andalusian cadence: i - VII - VI - V |
| Pop (minor start): vi - IV - I - V | |
| Three chords: I - IV - V | |
| Jazz ii-V-I: ii - V - I | |
| Canon: I - V - vi - iii - IV - I - IV - V | |
| 12-bar blues: I7 ×4, IV7 ×2, I7 ×2, V7, IV7, I7, V7 | |

**Blocks:** the strip shows every block with both forms of its chord (for example **ii · Dm**) and its length; a longer block is a wider box. Click a block to select it, then:

| To | Do this |
|---|---|
| Select the previous / next block | ← / → (click the strip first) |
| Move the selected block | ⌥← / ⌥→, or **◀ Move** / **Move ▶** |
| Remove it | Delete / ⌫, or **Remove** |
| Change its length | The length menu: ½, 1, 2 or 4 bars |
| Remove every block | **Clear** |

The total length is shown next to the buttons ("6½ bars · 104 lines"). Changing the key relabels Roman-numeral blocks (ii is Dm in C major, Am in G major); chord names keep their names but get the numeral of the new key. Half-bar blocks need a bar with an even number of lines (not possible in 5/16, for example). The whole progression can be at most 4096 lines.

**Instruments**

**Bass** and **Piano** each offer **Default** (the bundled **Electric Bass** and **Electric Piano** presets, falling back to the built-in constants if the bundled preset files are missing), followed by every playable preset in the instrument library (bundled presets first, then your user presets labelled `(user)`; effects are excluded), and **Load preset file…**, which loads a module preset (`.msym`, [§13.6](#136-module-presets-msym)) that can play notes; it then appears in the list as "Preset: *name*". A file that can't be read, or a preset of a module that can't play notes (an effect, for example), is refused with a message and the earlier choice stays. The instrument menus are only available when there are chords.

**Create**

If anything is not valid, **Create** is disabled and the reason is shown at the bottom of the panel. Otherwise **Create** replaces the open project (asking first if it has unsaved changes; **Cancel** there keeps both the project and the panel). The new project contains:

- the title, tempo, time signature and key you chose, and the **Master Output**;
- with chords: a **Bass** module and a **Piano** module, both wired to the Master Output;
- with chords: a **Bass** pattern (1 track) and a **Piano** pattern (4 tracks), each as long as the whole progression, one clip each at the start of lanes 1 and 2, and the loop set over the progression.
  - The bass plays each chord's root (or the note after the slash), between C2 and B2, held until the next chord.
  - The piano plays every note of the chord in root position, one note per track, from a root between C4 and B4; three-note chords leave track 4 empty.
  - The last line of both patterns stops every note.
- without chords: one empty 4-track pattern of 4 bars and no instruments.

The project is new and unsaved (no file name), its undo history is empty, and the pattern editor shows the **Piano** pattern. The status bar shows "Created project *title*".

---

## 14. Appearance and accessibility

Dracker starts in a **light, high-contrast** theme with a **colorblind-safe** palette:

- **Text:** contrast of at least 7:1 everywhere, including on highlighted rows and selections.
- **Graphics** (cables, borders, meters, port shapes): at least 4.5:1.
- **Color is never the only cue:**
  - cable kinds have line styles and port shapes;
  - clips have letters and stripes;
  - muted items are hatched;
  - selections and cursors have outlines;
  - the scope's right channel is dashed;
  - lit buttons have heavy outlines.

Changing appearance never changes the size of any text or control.

### 14.1 Opening the Appearance panel
Use **⌘,**, **Dracker ▸ Settings…** or **View ▸ Appearance…**.

Every change previews immediately:

| Setting | Choices |
|---|---|
| **UI font** | Any installed font; Atkinson Hyperlegible Next is listed first |
| **Monospace font** (pattern grid) | Fixed-width fonts only; Fira Code first |
| **Contrast** | **High contrast** (7:1 text) or **Low contrast** (4.5:1 text, softer off-white surfaces) |
| **Palette** | **Light · Okabe–Ito** (default), **Light · Tol Bright**, **Dark · Okabe–Ito**, plus your custom palettes |

- Fonts always load at Regular weight. Fira Code's programming ligatures are never used, so `---` and `===` stay as separate characters.
- The current appearance name is shown under the palette, e.g. "Light · High Contrast · Okabe–Ito".

### 14.2 Finishing
- **OK** saves your choices.
- **Revert** restores the appearance the panel opened with.
- Clicking outside the panel, or pressing Escape, closes it and **keeps and saves** what you previewed.
- Menu shortcuts (⌘…) keep working while the panel is open.

### 14.3 Quick contrast switch
**⌥⌘C**, or **View ▸ High Contrast**, flips between High and Low contrast and saves immediately. The menu checkmark shows the current mode.

### 14.4 Custom palettes
Built-in palettes are read-only.

1. Choose a palette and click **Duplicate → Custom**. This creates "Custom N" and selects it.
2. Pick a color group under **Edit colors**: Surfaces; Text; Accent & status; Lines & overlays; Wires & scope; Tracker fields; Categories & clips; Piano; Piano roll & drumpad (colors for views that are not available yet). A palette saved by an older build still loads; the piano roll and drumpad colors it lacks take its accent colors.
3. Pick a color, either from the second dropdown or by clicking its **swatch**.
4. Adjust **R, G, B, A** (0–255) with the number boxes.

The **contrast readout** below the color lists every place that color is used, worst first. Each line shows the contrast ratio and either **OK** or **BELOW** *target* (in red with a dot), so you can see whether your change keeps text readable.

**Other buttons**
- **Rename:** gives the custom palette the next free number. There is no text entry for names yet.
- **Delete:** removes the custom palette.
- **Reset:** restores its colors from the built-in palette it was copied from.
- **Import… / Export…:** load or save `.stpalette` files to share palettes.

You can keep up to 32 custom palettes.

### 14.5 Fonts not found
If a chosen font isn't installed, the app falls back to the system font and the status bar reads "Font not found: …". The panel's footer shows which fonts are actually in use.

---

## 15. Undo and redo

- **⌘Z** undoes and **⇧⌘Z** redoes. Up to 512 steps are kept.
- Rapid repeated edits to the same thing (within half a second) may merge into one step.

**Undoable:**
- module add, delete, move and duplicate; cables; parameters (one step per drag); curves; envelopes;
- mute and bypass;
- pattern contents, size, add, duplicate and delete;
- clips and lanes; loop; tempo;
- samples, key ranges and loop points.

**Not undoable:**
- solo;
- MetaModule inner edits;
- appearance changes (use Revert in the Appearance panel instead).

Opening a project or starting a new one clears the history.

---

## 16. Tutorial: your first song

1. **New project:** press ⌘N.
2. **Add a synth:** right-click empty patchbay space → **Add Synth ▸ Analog Generator**. It appears selected. Note its module number: it is module **2** in a fresh project.
3. **Wire it:** drag from its **Audio Out** port (right edge, circle) to the **Master Output**'s **Input** port (left edge). A solid cable appears.
4. **Try it:** with the synth selected, press **Z X C V** on the keyboard. You should hear notes.
   - If you hear nothing, check that **audio is running** (DSP % shows in the transport) and that the cable reaches the Master Output.
5. **Shape the sound:** in the rack, drag **Cutoff** down and **Resonance** up. Set **Waveform** to 3 (pulse) with ↑/↓ on the dropdown.
6. **Write a pattern:**
   1. Click the first cell of track 1 in the pattern editor.
   2. Press **⇧⌘R** (EDIT lights).
   3. Set **STEP** to 4.
   4. Press **Z**, **C**, **B**, **C**. Notes appear every 4 lines with module `02`.
   5. Press **⇧⌘R** again (or **Escape**) to leave edit mode.
7. **Listen:** press **⇧Space** to loop the pattern, and again to stop.
8. **Add an effect:**
   1. Right-click the canvas → **Add Effect ▸ Echo**.
   2. Right-click the old cable → **Delete Wire**.
   3. Wire synth → Echo **Input**, then Echo **Output** → Master Output.
9. **Arrange:**
   1. In the pattern header click **Dup** to copy the pattern, and change some notes.
   2. In the timeline, double-click to the right of the first clip to place the new pattern.
   3. ⌥-drag the first clip further right to clone it.
10. **Play the song:** press **Space**. Press **⌘L** to loop the whole song.
11. **Save and export:** press **⌘S** to save `mysong.msv`, then **⌘E** to export `mysong.wav`.

---

## Appendix A: Keyboard shortcut reference

**Global (any pane)**

| Shortcut | Action |
|---|---|
| Space · ⌘Return | Play / pause song |
| ⇧Space | Play / stop current pattern (loop) |
| Escape | End live recording if running, else leave edit mode if it is on, else stop and return to line 0 (when no popup is open) |
| ⌘R | Start / stop live recording |
| ⇧⌘R | Edit mode |
| F1 / F2 | Edit octave down / up |
| ⌘. | Panic: stop and silence everything |
| ⌘L | Toggle loop (whole song) |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘N / ⌘O / ⌘S / ⇧⌘S | New / open / save / save as |
| ⇧⌘N | New project from skeleton (generator panel) |
| ⌥⌘S / ⌥⌘O | Save the selected module as a preset / load a preset as a new module |
| ⌘E | Export WAV |
| ⌘, | Appearance panel |
| ⌥⌘C | Toggle high / low contrast |
| ⌘Q | Quit |

**Active-pane commands**

| Shortcut | Pattern editor | Timeline | Patchbay | Sample editor |
|---|---|---|---|---|
| ⌘= / ⌘- / ⌘0 | Zoom (Piano roll) | Zoom | Zoom | Zoom |
| ⌫ | Clear field / selection / notes | Delete clip | Delete selection | — |
| ⌦ | Clear block / notes | — | Delete selection | — |
| ⌘X / ⌘C / ⌘V | Cut / copy / paste (Tracker & Piano roll) | — | — | — |
| ⌘A | Select all (Tracker & Piano roll) | — | — | — |
| ⌘↑ / ⌘↓ | Transpose ±1 (Tracker & Piano roll) | — | — | — |
| ⇧⌘↑ / ⇧⌘↓ | Transpose ±12 (Tracker & Piano roll) | — | — | — |
| ⌘I | Interpolate | — | — | — |
| ⌘F | Toggle follow | Toggle follow | — | — |
| ⌘[ / ⌘] | Previous / next pattern | — | — | — |
| ⌥← / ⌥→ | Previous / next track | — | — | — |
| ⌥↑ / ⌥↓ | Edit step ± | — | — | — |
| Tab | Note-off | — | — | — |

**Mouse modifiers**

| Context | Modifier | Effect |
|---|---|---|
| Any value drag | Shift | Fine adjustment |
| Any slider or number box | Option-click | Reset to default |
| Patchbay, timeline, sample editor, piano roll | ⌘ + scroll / pinch | Zoom at pointer |
| Timeline or piano roll drag | ⌥ | Clone clip / copy selected notes |
| Timeline drag | Shift / ⌘ | Snap to line / bar |
| Drumpad step hit | ⌥-click | Cycle velocity (soft / medium / loud) |
| Envelope point | Option-click | Set sustain point |

---

## Appendix B: Module reference

Choice parameters are listed with the name of each value, in order from the lowest value (the first name is value 0 unless the range says otherwise); the rack shows these names, and the composition helper accepts them in place of the numbers. On/off switches are *Off* (0) and *On* (1). Unless noted otherwise:

- effects have **Input** (audio in) and **Output** (audio out) ports;
- synths have **Events In** (event) and **Audio Out** (audio) ports.

### Core
| Module | Ports | Parameters |
|---|---|---|
| **Master Output** | Input; Output | Volume 0–2 (1) · Limiter Off/On (On): soft limiter that prevents harsh clipping |

### Synths
| Module | Voices | Parameters (default) |
|---|---|---|
| **Analog Generator** | 32 | Waveform (Saw): Sine, Triangle, Saw, Square, Noise, Drawn · Unison 1–4 voices (1) · Detune (0.15) · Cutoff 40–18000 Hz (4000) · Resonance 0–0.95 (0.2) · Attack (0.005 s) · Decay (0.2 s) · Sustain (0.7) · Release (0.25 s). Extra **Cutoff CV** input. |
| **FM Synth** | 16 | Algorithm (Serial): Serial (5→4→3→2→1), Split Branches (5→4, then 4→3→1 and 4→2→1), Two Stacks (4→2→1 and 5→3), Four Into One (2, 3, 4, 5 → 1), Carrier + Stacks (1 alone, 5→4→2 and 4→3), Additive (all five summed) · Feedback (0.2) · Op1–5 Ratio 0.5–16 · Op1–5 Level · Attack/Decay/Release (ms) · Sustain |
| **DrumSynth** | 8 | Kit Decay · Tone · Snappy · Pan Spread · Master Vol. The note picks the drum: 36 kick, 38/40 snare, 42/44 closed hat, 46 open hat, 41/43/45 low tom, 47 high tom; other notes by pitch class (C kick, D/E snare, F#/G# hat, A# open hat, otherwise percussion). |
| **Kicker** | 1 | Waveform: Sine, Triangle, Square · Pitch Start (220 Hz) · Pitch End (48 Hz) · Sweep Time (45 ms) · Decay (220 ms) · Click Drive |
| **Sampler** | 16 | Volume · Panning · Fine Tune · Offset · Loop Mode: One-Shot (plays once and stops), Forward, Ping-Pong (a loop shorter than one sample plays once) · Quality (Cubic): Nearest, Linear, Cubic. Extra **Audio Thru** input. Load samples in the sample editor. |
| **SpectraVoice** | 16 | Profile: Organ, Brass, Choir, Bell (harmonic recipes) · Bandwidth · Attack · Release |
| **Input** | — | Brings live audio input into the graph. Input Gain · Channel Route: Stereo, Left, Right, Mono Mix (Left and Right send that side to both outputs) · Mute Off/On |
| **Vorbis Player** | — | Volume · Transpose · Loop Off/On. *QA: there is no way to load a file in this build.* |

### Effects
| Module | Parameters (default) |
|---|---|
| **Amplifier** | Volume 0–4 · Pan · DC Offset · Stereo Width · Invert Off/On. **Gain CV** input. |
| **Filter Pro** | Mode: Lowpass, Highpass, Bandpass, Notch, Allpass, Peaking, Low Shelf, High Shelf · Slope 1–4 stages · Cutoff (1200 Hz) · Resonance (Q 0.707) · Gain dB · Drive. **Cutoff CV** and **Resonance CV** inputs. |
| **3-Band EQ** | Low/Mid/High Gain ±24 dB · Low Freq (160) · Mid Freq (1000) · Mid Q · High Freq (6000) |
| **Distortion** | Mode: Soft Clip, Hard Clip, Sine Fold, Asymmetric · Drive · Bit Depth · SR Div · Mix |
| **WaveShaper** | Input Gain · Mix · DC Block Off/On (On) · Oversample: 1x, 2x, 4x. The shape is drawn in the rack's **Transfer Curve**. |
| **Delay** | Dry · Wet · Delay L (250) · Delay R (375) · Unit: ms, Hz, Lines/100 (hundredths of a line) · Inverse: Normal, Swap Wet L/R (the delayed signal changes sides; the dry signal does not) |
| **Echo** | Dry · Wet · Feedback · Delay Time (300 ms) · Stereo Mode: Stereo, Ping-Pong (the feedback crosses sides) · Damping (6000 Hz) |
| **Reverb** | Dry · Wet (0.35) · Room Size · Damping · Stereo Width · Pre-Delay · Freeze Off/On |
| **Compressor** | Threshold (−18 dB) · Ratio (4:1) · Attack · Release · Makeup · Mode: Peak, RMS. **Sidechain** input. |
| **Flanger** | Dry · Wet · Feedback · Delay · LFO Freq · LFO Depth |
| **Vibrato** | Freq · Depth · Stereo Phase · Mix |
| **Modulator** | Mod Type (Ring): AM, Ring, Phase · Mix · PM Max Delay. Inputs: **Carrier In**, **Modulator In** (sidechain), **Modulator CV**. |
| **Pitch Shifter** | Pitch ±24 st · Fine Cents · Grain Size · Feedback · Mix |
| **Vocal Filter** | Vowel 0–4 (morphs A→E→I→O→U) · Formant Shift · Bandwidth · Voice Type: Soprano, Alto, Tenor, Bass (formants scaled ×1.18, ×1.02, ×0.88, ×0.76) · Mix. **Vowel CV** input. |
| **FFT FX** | FFT Size 0–3 (256, 512, 1024, 2048) · Feedback · Bin Shift · Freeze Off/On · Mix |
| **Loop** | Repeats · Length (ticks) · Mode: Forward, Ping-Pong (the first pass plays backwards) · Mix. **Trigger In** event input. |
| **Smooth** | Rise Time · Fall Time · Scale. It also has **CV In** and **CV Out** ports. |
| **DC Blocker** | Cutoff (20 Hz) |

### Control
| Module | Ports | Parameters |
|---|---|---|
| **LFO** | Audio In/Out, **CV Out** | Waveform: Sine, Triangle, Saw, Square, S&H Random (a new random value each cycle) · Frequency (2) · Sync Unit: Hz, Beats/Cycle (Frequency is then the number of beats per cycle) · Amplitude · Phase Offset · Stereo Spread |
| **ADSR** | Events In, **CV Out**, Audio Out | Attack · Decay · Sustain · Release · Mode: Gated, One-Shot, Inverted |
| **Glide** | Events In/Out | Response (ms) · Polyphonic Off/On · Reset On First Off/On (On) |
| **MultiSynth** | Events In/Out | Transpose · Fine Tune · Random Pitch · Velocity Scale · Curve Mode: Off, Velocity, Velocity + Pitch (needs a drawn curve) |
| **MultiCtl** | Events In, CV In, Events Out | Value · Gain · Quantization. The curve is drawn in the rack. |
| **Ctl2Note** | Events In, CV In, Events Out | Pitch · First Note · Range Notes · Trigger Mode: Retrigger (a new note whenever the note changes), Legato (the held note changes pitch), Gate (as Retrigger, and a note-off when the control returns to 0) |
| **Pitch2Ctl** | Events In/Out, CV Out | First Note · Semitones · Out Min · Out Max |
| **Velocity2Ctl** | Events In/Out, CV Out | Out Min · Out Max · NoteOff Action: Keep, Go To Min, Go To 0 |
| **Sound2Ctl** | Audio In, CV Out, Events Out | Gain · Smooth · Out Min · Out Max · Rate |
| **Pitch Detector** | Audio In, Events Out | Algorithm: Autocorrelation, Zero-Crossing · Threshold · Min/Max Freq · Hysteresis |
| **Feedback** | Input, Output | Volume · Channels: Stereo, Mono · Fixed Delay (frames). Use this to build intentional feedback loops. |
| **MetaModule** | Audio In, Events In, Audio Out | BPM Sync Off/On (On) · Play Patterns (Follow Parent): Off, Follow Parent, Note Triggered (a note starts the child song from its first line; any note-off stops it) · Input Module · Macro 1–8. Contains a whole sub-project. |

**Project limits**
- 1,024 modules; 8,192 cables; 256 patterns of up to 64 tracks × 4,096 lines; 4,096 clips; 256 MIDI mappings.
- Live keyboard/MIDI: up to 64 notes at once.

---

## Appendix C: Known limitations and QA notes

These are known limitations of the current build. Please report behavior that *differs* from what is described here.

| # | Area | Behavior in this build |
|---|---|---|
| 1 | Files | Logging out, restarting or shutting down quits without asking about unsaved changes (by design, [§13.8](#138-unsaved-changes)) |
| 2 | Pattern editor | Double-clicking the pattern dropdown renames the pattern in place |
| 3 | Pattern editor | The context menu shows "Cmd+J" for Interpolate; the real shortcut is ⌘I |
| 4 | Pattern editor | New patterns are named with a decimal number ("Pattern 10") but the dropdown shows the id in hex ("0A"), so the two disagree from pattern 10 on |
| 5 | Pattern editor | Module numbers above 255 can't be displayed or typed in the MM field |
| 6 | Pattern editor | Hex line numbers can't be switched to decimal in the GUI |
| 7 | Pattern editor | AOF/PIT/PRV/STP note commands can't be typed |
| 8 | Pattern editor | Edit step reaches 64 with ⌥↑ in the pattern editor, but the transport STEP box and its shortcut stop at 16 |
| 9 | Recording | MIDI notes are captured while the pattern editor redraws. Keep it visible while recording. |
| 10 | Transport | ⌘L does nothing when there are no clips; the LOOP button falls back to the current pattern |
| 11 | Transport | After clicking a transport button, Space/Return press that button instead of toggling play |
| 12 | Transport | The MIDI source list refreshes only at startup and when the device dropdown is opened |
| 13 | Patchbay | Cable gain can't be edited; Duplicate doesn't copy cables, samples or curves |
| 14 | Rack | Header toggle order is M B S; the patchbay badges are M S B |
| 16 | Rack | Envelope editor: moving the sustain marker has no effect on parameters |
| 17 | Rack | MetaModule inner edits are not undoable |
| 18 | Sampler | AIFF is offered in the import dialog but can't be decoded; drag-and-drop isn't implemented |
| 19 | Sampler | The loop mode dropdown applies to all slots |
| 20 | Sampler | There are no destructive sample edits (trim, normalize and so on) |
| 21 | DrumSynth | Notes 48 and 50 play kick and snare, not high tom; only 47 plays the high tom |
| 22 | Vorbis Player | There is no way to load a file |
| 23 | Export | Stems, MIDI/XM/SunVox import and autosave are not exposed in the GUI |
| 24 | Panic | In the GUI, Panic stops the transport; it doesn't send a separate all-notes-off |
| 25 | Files | The song key can only be chosen in the skeleton generator; there is no control to change it afterwards ([§13.9](#139-new-project-from-skeleton)) |
| 26 | Files | Creating a project from a skeleton cannot be undone (like New and Open, it clears the undo history) |
| 27 | Pattern editor | The view chosen per pattern (Tracker, Piano roll, Drumpad) resets when reopening Dracker (not saved in `.msv`), and there are no keyboard shortcuts for switching views |
| 28 | Piano roll | Effect columns, sub-line delays (`40`–`5F`), and sub-line note timings are preserved when editing notes, but cannot be viewed or edited directly in the piano roll |
| 29 | Drumpad | Swing, per-step probability, per-step pitch overrides, and lane mute/solo are not implemented in this version |
| 30 | Patchbay | The instrument sidebar has no search/filter box in this version |
| 31 | Patchbay | Adding a preset from the instrument sidebar (double-click or drag) adds an unwired module |
| 32 | Patchbay | Bundled presets are read-only; to save modified parameters, use **Add to Instruments…** to create a user preset |

### Suggested QA passes
1. **Audio path:**
   - Follow the [tutorial](#16-tutorial-your-first-song).
   - Watch **XR** stay at 0 while dragging nodes during playback.
   - Check that the clip light trips on loud signals and resets on click.
2. **Editing round-trip:**
   - Write notes, effects and controller rows, then block-copy, paste, transpose and interpolate.
   - Undo every step and confirm the pattern returns exactly to its start.
3. **Arrangement:**
   - Clone clips (⌥-drag) and confirm edits appear in both, then use **Make Unique**.
   - Test lane M/S/ST, loop strip drag and double-click, and ruler seek.
4. **Files:**
   - Save, choose New, then Open, and confirm modules, cables, patterns, clips, mappings and samples come back.
   - Try opening a non-`.msv` or truncated file: the current project must survive.
   - Export WAV and listen to the result.
5. **MIDI:** learn a CC onto a parameter, then save and reopen to confirm the mapping persists. Step-record and live-record from a MIDI keyboard.
6. **Appearance:**
   - Switch contrast, palette and both fonts.
   - Confirm no panel or control changes size, and that Revert restores everything.
   - Edit a custom palette and check the contrast readout flags low-contrast choices.
   - Corrupt `appearance.cfg` by hand and confirm the app starts with defaults and a status message.
7. **Accessibility:** using a colorblindness simulator, or with color filters enabled in macOS, confirm cable kinds, clips and states can still be told apart by shape, line style, letters and outlines.

---

## Appendix D: Command-line options and self-tests

```
dracker [--gui] [project.msv]            launch the studio (default)
dracker --gallery                        toolkit / renderer gallery
dracker --list-devices                   list audio and MIDI devices
dracker --cli-demo [--duration=<sec>] [--sample-rate=<hz>] [--buffer-frames=<n>] [--auto-chord] [--duplex]
dracker --studio-gui-selftest [--quick]  automated end-to-end GUI workflow (plays quiet audio)
dracker --gui-selftest [--quick]         automated window/toolkit verification
dracker --studio-selftest [--quick]      audio/MIDI backend verification (plays audio)
dracker --sound-check=<file.wav>         render the default bass and piano sounds to a WAV file
dracker --sound-check-presets=<dir>      render WAV previews for bundled presets (12 instruments, 4 effects dry + wet)
dracker --write-factory-presets=<dir>    write the bundled presets as .msym files
dracker --help
```

- **Sound check:** `--sound-check` needs no audio device and writes a 26-second stereo WAV in C major at 120 BPM (I–vi–ii–V7, one chord per bar): bars 1–4 the default bass alone, bars 5–8 the default piano alone, bars 9–12 both. These are the sounds the planned skeleton project generator will use when no other instrument is chosen.
- **Preset sound check:** `--sound-check-presets` renders 20 WAV files into `<dir>` at 120 BPM (four bars plus a 3-second tail each): "*Group* - *Name*.wav" for the twelve instruments (basses a bass line, Drum Kit and Kick a beat, the others the chords C, Am, Dm, G7), and two separate files "*Effects - Name* (dry).wav" and "*Effects - Name* (wet).wav" for each effect (short Electric Piano chords with rests for Room Reverb and Tempo Delay, a dynamic Drum Kit beat for Bus Compressor, and the Electric Bass line for Warm Overdrive).
- **Running self-tests:** run them with `caffeinate -dims` so the display doesn't sleep. They keep a floating window open, and you shouldn't use the mouse or keyboard while they run.
- **Reading results:** each check prints `PASS` or `FAIL` with details, and the process exits with 0 when every check passed.
- **Your files are safe:** self-tests use temporary folders and never touch your projects, clipboard or appearance preferences.

**Building from source** (inside `dracker/`):

```zsh
dub build --compiler=ldc2 --config=app --build=debug   # studio app → ./build/dracker
dub test  --compiler=ldc2 --config=headless            # headless unit + fuzz tests
dub test  --compiler=ldc2 --config=app                 # macOS platform tests
```
