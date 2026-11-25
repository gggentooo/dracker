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
- Tempo **125 BPM**, **6 ticks per line**.

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
- **Left side:** the most recent message, such as "Saved", "Octave 5", "Record on" or "Font not found: …". It reads "Ready" when there is none.
- **Right side:** **Modified** when there are unsaved changes, otherwise **Saved**.
- The window title also ends with **"•"** when the project is modified.

### 2.3 Which pane receives keyboard commands
Some shortcuts (copy, paste, delete, zoom, transpose and so on) depend on context. They go to:

- the pane containing the control you last clicked or focused; or
- if that pane can't use them, the last of these four you clicked in: **patchbay**, **pattern editor**, **timeline** or **sample editor**.

At startup that is the pattern editor. Clicking in a pane makes it the target.

Other shortcuts work no matter which pane is active: play, stop, record, octave, undo/redo, file commands, loop, panic and appearance.

> **QA note:** after you click a transport button, that button keeps keyboard focus. Space or Return then "presses" it again instead of toggling playback. Click inside the pattern editor or patchbay to restore the normal behavior.

---

## 3. The menu bar

All menu commands can also be triggered from the keyboard.

### Dracker menu

| Item | Shortcut | What it does |
|---|---|---|
| Settings… | ⌘, | Opens the Appearance panel ([§14](#14-appearance-and-accessibility)) |
| Hide Dracker | ⌘H | Hides the app |
| Quit Dracker | ⌘Q | Quits immediately |

> **QA note:** Quit, New and Open do **not** ask you to save unsaved changes. Save first (⌘S).

### File menu

| Item | Shortcut | What it does |
|---|---|---|
| New Project | ⌘N | Replaces the current project with an empty one ([§1.3](#13-what-a-new-project-contains)). Undo history is cleared. |
| Open Project… | ⌘O | Opens an `.msv` project. If the file is invalid, the current project is kept and the error is shown in the status bar. |
| Save Project | ⌘S | Saves to the current file, or asks for a name if the project has never been saved |
| Save Project As… | ⇧⌘S | Saves under a new name |

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
| Record | ⌘R | Toggles record (edit) mode |
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
- **Escape** closes the topmost popup. With no popup open, Escape turns **Record** (edit) mode off if it is on; otherwise it **stops playback**.

> **QA note:** in the pattern editor, Tab enters a note-off, so it does not move focus there.

---

## 5. The transport bar

Controls from left to right. If the window is too narrow, controls on the right are hidden.

| Control | Use |
|---|---|
| **Play** ▶ | Starts or pauses song playback (shows pause bars while playing). Lit during song playback. |
| **Stop** ■ | Stops and returns to line 0 |
| **Pat** (▶ with bar) | Plays only the current pattern, looping. Press again to stop. Lit while auditioning. |
| **Rec** ● | Toggles record (edit) mode. Lit (red) while on. You **must** be in record mode to type notes into patterns. |
| **FOLLOW** | When on (the default), the pattern editor and timeline scroll to follow the playhead |
| **LOOP** | Turns looping on or off (see below). Lit while a loop is set. |
| **BPM** | Tempo, 20–999, adjustable in steps of 0.1. Default 125. |
| **TPL** | Ticks per line, 1–255. Default 6. Fewer ticks means faster lines. |
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
- Dragging BPM or TPL is one undo step.
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
| A node | Mute/Unmute · Solo/Unsolo · Bypass/Enable · Duplicate · Delete. All are disabled for the Master Output. |
| A cable | Delete Wire |
| Empty canvas | Add Synth ▸ · Add Effect ▸ · Add Control ▸ · Add Core ▸ · Fit All · Reset Zoom |

**Duplicate** creates a copy of the module offset down and to the right, with the same parameter values. It does **not** copy cables, mute/bypass state, samples or drawn curves.

### 6.7 Navigating the canvas

| Action | Gesture |
|---|---|
| Pan | Scroll / two-finger swipe, or drag empty canvas |
| Zoom around the pointer | ⌘ + scroll, or pinch |
| Zoom in / out / 100% | ⌘= / ⌘- / ⌘0 (patchbay active) |
| Fit everything in view | Double-click empty canvas, or **Fit All** |

Zoom ranges from 25% to 300%.

> **QA note:** cable gain can't currently be changed in the GUI. The thickness of a cable reflects its gain, which is 1.0 for every cable drawn in the GUI.

---

## 7. The parameter rack

The rack shows the parameters of the module **selected in the patchbay**. With nothing selected it says **"No module selected"**.

### 7.1 Header
- The module name and type.
- Three toggles: **M** (mute), **B** (bypass), **S** (solo).

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

> **QA note:** choice parameters show numbers, not names. For example, Analog Generator *Waveform* 0–5 means sine, triangle, saw, pulse, noise, drawn. [Appendix B](#appendix-b-module-reference) lists every module's numbers and their meanings.

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
- **Pattern dropdown:** chooses the pattern to edit. Items show the pattern's id in hex followed by its name.
- **Trk:** number of tracks, 1–64.
- **Lin:** number of lines, 1–4096. Resizing is undoable.
- **Add:** creates a new empty pattern the same size as the current one, and selects it.
- **Dup:** duplicates the current pattern; the copy is named "*name* copy".
- **Del:** deletes the current pattern **and every timeline clip that uses it**. Undo restores both. The last remaining pattern can't be deleted.
- **Info text:** `Oct N  Step N`, plus **REC** when recording and **FOLLOW** when following.

Up to 256 patterns are allowed.

> **QA note:** there is currently no way to rename a pattern in the GUI.

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
- **Row shading:** every 4th line (beat) is shaded, and every 16th line (bar) is shaded more strongly with a rule above it.
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
| Double-click | Places the cursor on the note field of the clicked row and turns **Record** (edit) mode on |
| Scroll | Vertical scrolls lines; horizontal, or Shift+scroll, scrolls tracks |

### 8.4 Entering notes and values
**Turn on Record mode first** (⌘R, the **Rec** button, or **double-click a row** in the pattern editor). Outside record mode, keys only *play* sounds; nothing is written. Press **Escape** to leave record mode.

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

Both work without record mode.

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

### 8.9 Recording from MIDI
With **Record** on and a MIDI keyboard connected:

- **Stopped (step recording):** notes are written at the cursor line. Chords spread across successive tracks. The cursor then moves by the edit step.
- **Playing (live recording):** notes are written at the line under the playhead, in whichever clip of this pattern is playing. Notes that fall outside every clip of the current pattern are dropped.

Velocity is taken from the MIDI note. Note-offs are not recorded; add `===` by hand where needed.

### 8.10 Following the playhead
- **⌘F**, or the FOLLOW button, toggles follow mode. It is on by default.
- While playing, the editor keeps the playhead line centered.
- When auditioning a pattern (Pat / ⇧Space), the playhead wraps within the pattern.

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
- **Double-click an empty spot** to place a clip of the *current* pattern (the one in the pattern editor). Its length is the pattern's length.
- **Right-click an empty spot** and choose **Add Clip: *pattern name***.

### 9.3 Editing clips

| Action | Gesture |
|---|---|
| Select | Click |
| Open its pattern in the pattern editor | Double-click the clip |
| Move (in time and between lanes) | Drag the body |
| Resize | Drag the right edge (minimum 1 line) |
| **Clone** | **⌥-drag**. The clone plays the *same* pattern, so edits appear in both. |
| Cancel a drag | Escape |
| Delete | Delete / ⌫ |

- A ghost preview shows during a drag; releasing commits one undo step.
- **Snapping:** no modifier snaps to the beat (4 lines); **Shift** to 1 line; **⌘** to the bar (16 lines).

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
| **Source dropdown** | **Master** (the final mix) or **Selected module**, which follows the patchbay selection and falls back to Master when nothing is selected |

The scope shows "No signal" when there is no audio, and updates continuously only while playing or while audio is running.

---

## 12. Playing live

### 12.1 The computer-keyboard piano
When no shortcut uses a key, the letter keys play the **selected module** like a piano, two octaves wide. It works whenever record mode is off, and in the pattern editor's note field while it is on.

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
- **Playing & recording:** Click or drag across keys to play notes on the **selected module**. With **Record** enabled, clicked keys also insert notes into the pattern editor.
- **Live highlighting:** Active keys highlight in the theme's accent color for mouse presses, computer-keyboard piano holds, external MIDI input, and pattern playback targeting the currently selected module.

### 12.3 MIDI keyboards and controllers
- All connected MIDI sources play the **selected module**. The transport shows which sources are connected.
- Map controller knobs to parameters with **MIDI Learn** ([§7.3](#73-midi-learn-controlling-a-parameter-from-hardware)).
- Record MIDI notes into patterns with Record on ([§8.9](#89-recording-from-midi)).

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
- the loop range.

It does **not** store editor state: edit octave, edit step, record/follow, selection or zoom.

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

> **QA note:** MIDI file, XM and SunVox import, module presets (`.msym`) and autosave exist in the engine but have no GUI yet.

### 13.6 Preferences
Appearance settings are saved separately from projects, in `~/Library/Application Support/Dracker/appearance.cfg`. If this file is damaged, the app uses the defaults and shows "Appearance settings ignored (…); using defaults".

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
2. Pick a color group under **Edit colors**: Surfaces; Text; Accent & status; Lines & overlays; Wires & scope; Tracker fields; Categories & clips.
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
   2. Press **⌘R** (Rec lights).
   3. Set **STEP** to 4.
   4. Press **Z**, **C**, **B**, **C**. Notes appear every 4 lines with module `02`.
   5. Press **⌘R** again to leave record mode.
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
| Escape | Leave record (edit) mode if it is on; otherwise stop and return to line 0 (when no popup is open) |
| ⌘R | Record (edit) mode |
| F1 / F2 | Edit octave down / up |
| ⌘. | Panic: stop and silence everything |
| ⌘L | Toggle loop (whole song) |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘N / ⌘O / ⌘S / ⇧⌘S | New / open / save / save as |
| ⌘E | Export WAV |
| ⌘, | Appearance panel |
| ⌥⌘C | Toggle high / low contrast |
| ⌘Q | Quit |

**Active-pane commands**

| Shortcut | Pattern editor | Timeline | Patchbay | Sample editor |
|---|---|---|---|---|
| ⌘= / ⌘- / ⌘0 | — | Zoom | Zoom | Zoom |
| ⌫ | Clear field / selection | Delete clip | Delete selection | — |
| ⌦ | Clear block | — | Delete selection | — |
| ⌘X / ⌘C / ⌘V | Cut / copy / paste | — | — | — |
| ⌘A | Select all | — | — | — |
| ⌘↑ / ⌘↓ | Transpose ±1 | — | — | — |
| ⇧⌘↑ / ⇧⌘↓ | Transpose ±12 | — | — | — |
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
| Patchbay, timeline, sample editor | ⌘ + scroll / pinch | Zoom at pointer |
| Timeline drag | ⌥ | Clone clip |
| Timeline drag | Shift / ⌘ | Snap to line / bar |
| Envelope point | Option-click | Set sustain point |

---

## Appendix B: Module reference

Discrete (choice) parameters are listed with the meaning of each number, because the rack shows only the number. Unless noted otherwise:

- effects have **Input** (audio in) and **Output** (audio out) ports;
- synths have **Events In** (event) and **Audio Out** (audio) ports.

### Core
| Module | Ports | Parameters |
|---|---|---|
| **Master Output** | Input; Output | Volume 0–2 (1) · Limiter 0/1 (on): soft limiter that prevents harsh clipping |

### Synths
| Module | Voices | Parameters (default) |
|---|---|---|
| **Analog Generator** | 32 | Waveform 0–5 (2): 0 sine, 1 triangle, 2 saw, 3 pulse, 4 noise, 5 drawn · Unison 1–4 voices (1) · Detune (0.15) · Cutoff 40–18000 Hz (4000) · Resonance 0–0.95 (0.2) · Attack (0.005 s) · Decay (0.2 s) · Sustain (0.7) · Release (0.25 s). Extra **Cutoff CV** input. |
| **FM Synth** | 16 | Algorithm 0–5 (0): 0 serial 5→4→3→2→1, 1 split branches, 2 two stacks, 3 four into one, 4 mixed, 5 additive · Feedback (0.2) · Op1–5 Ratio 0.5–16 · Op1–5 Level · Attack/Decay/Release (ms) · Sustain |
| **DrumSynth** | 8 | Kit Decay · Tone · Snappy · Pan Spread · Master Vol. The note picks the drum: 36 kick, 38/40 snare, 42/44 closed hat, 46 open hat, 41/43/45 low tom, 47 high tom; other notes by pitch class (C kick, D/E snare, F#/G# hat, A# open hat, otherwise percussion). |
| **Kicker** | 1 | Waveform 0–2 (0 sine, 1 triangle, 2 pulse) · Pitch Start (220 Hz) · Pitch End (48 Hz) · Sweep Time (45 ms) · Decay (220 ms) · Click Drive |
| **Sampler** | 16 | Volume · Panning · Fine Tune · Offset · Loop Mode 0–2 (off, forward, ping-pong) · Quality 0–2 (nearest, linear, cubic). Extra **Audio Thru** input. Load samples in the sample editor. |
| **SpectraVoice** | 16 | Profile 0–3 (harmonic recipes) · Bandwidth · Attack · Release |
| **Input** | — | Brings live audio input into the graph. Input Gain · Channel Route 0–3 (stereo, left, right, mono mix) · Mute |
| **Vorbis Player** | — | Volume · Transpose · Loop. *QA: there is no way to load a file in this build.* |

### Effects
| Module | Parameters (default) |
|---|---|
| **Amplifier** | Volume 0–4 · Pan · DC Offset · Stereo Width · Invert. **Gain CV** input. |
| **Filter Pro** | Mode 0–7 (lowpass, highpass, bandpass, notch, allpass, peaking, low shelf, high shelf) · Slope 1–4 stages · Cutoff (1200 Hz) · Resonance (Q 0.707) · Gain dB · Drive. **Cutoff CV** and **Resonance CV** inputs. |
| **3-Band EQ** | Low/Mid/High Gain ±24 dB · Low Freq (160) · Mid Freq (1000) · Mid Q · High Freq (6000) |
| **Distortion** | Mode 0–3 (soft clip, hard clip, sine fold, asymmetric) · Drive · Bit Depth · SR Div · Mix |
| **WaveShaper** | Input Gain · Mix · DC Block · Oversample 0–2 (1×, 2×, 4×). The shape is drawn in the rack's **Transfer Curve**. |
| **Delay** | Dry · Wet · Delay L (250) · Delay R (375) · Unit 0–2 (ms, Hz, hundredths of a line) · Inverse (swap L/R) |
| **Echo** | Dry · Wet · Feedback · Delay Time (300 ms) · Stereo Mode 0/1 (stereo, ping-pong) · Damping (6000 Hz) |
| **Reverb** | Dry · Wet (0.35) · Room Size · Damping · Stereo Width · Pre-Delay · Freeze |
| **Compressor** | Threshold (−18 dB) · Ratio (4:1) · Attack · Release · Makeup · Mode 0/1 (peak, RMS). **Sidechain** input. |
| **Flanger** | Dry · Wet · Feedback · Delay · LFO Freq · LFO Depth |
| **Vibrato** | Freq · Depth · Stereo Phase · Mix |
| **Modulator** | Mod Type 0–2 (AM, ring, phase) · Mix · PM Max Delay. Inputs: **Carrier In**, **Modulator In** (sidechain), **Modulator CV**. |
| **Pitch Shifter** | Pitch ±24 st · Fine Cents · Grain Size · Feedback · Mix |
| **Vocal Filter** | Vowel 0–4 (morphs A→E→I→O→U) · Formant Shift · Bandwidth · Voice Type 0–3 · Mix. **Vowel CV** input. |
| **FFT FX** | FFT Size 0–3 (256–2048) · Feedback · Bin Shift · Freeze · Mix |
| **Loop** | Repeats · Length (ticks) · Mode 0/1 (forward, ping-pong) · Mix. **Trigger In** event input. |
| **Smooth** | Rise Time · Fall Time · Scale. It also has **CV In** and **CV Out** ports. |
| **DC Blocker** | Cutoff (20 Hz) |

### Control
| Module | Ports | Parameters |
|---|---|---|
| **LFO** | Audio In/Out, **CV Out** | Waveform 0–4 (sine, triangle, saw, square, random) · Frequency (2) · Sync Unit 0/1 (Hz, beats per cycle) · Amplitude · Phase Offset · Stereo Spread |
| **ADSR** | Events In, **CV Out**, Audio Out | Attack · Decay · Sustain · Release · Mode 0–2 (gated, one-shot, inverted) |
| **Glide** | Events In/Out | Response (ms) · Polyphonic · Reset On First |
| **MultiSynth** | Events In/Out | Transpose · Fine Tune · Random Pitch · Velocity Scale · Curve Mode 0–2 (off, velocity curve, velocity + pitch curves) |
| **MultiCtl** | Events In, CV In, Events Out | Value · Gain · Quantization. The curve is drawn in the rack. |
| **Ctl2Note** | Events In, CV In, Events Out | Pitch · First Note · Range Notes · Trigger Mode 0–2 |
| **Pitch2Ctl** | Events In/Out, CV Out | First Note · Semitones · Out Min · Out Max |
| **Velocity2Ctl** | Events In/Out, CV Out | Out Min · Out Max · NoteOff Action 0–2 (keep, go to Min, go to 0) |
| **Sound2Ctl** | Audio In, CV Out, Events Out | Gain · Smooth · Out Min · Out Max · Rate |
| **Pitch Detector** | Audio In, Events Out | Algorithm 0/1 (autocorrelation, zero-crossing) · Threshold · Min/Max Freq · Hysteresis |
| **Feedback** | Input, Output | Volume · Channels 0/1 (stereo, mono) · Fixed Delay (frames). Use this to build intentional feedback loops. |
| **MetaModule** | Audio In, Events In, Audio Out | BPM Sync · Play Patterns 0–2 (off, follow parent, note-triggered) · Input Module · Macro 1–8. Contains a whole sub-project. |

**Project limits**
- 1,024 modules; 8,192 cables; 256 patterns of up to 64 tracks × 4,096 lines; 4,096 clips; 256 MIDI mappings.
- Live keyboard/MIDI: up to 64 notes at once.

---

## Appendix C: Known limitations and QA notes

These are known limitations of the current build. Please report behavior that *differs* from what is described here.

| # | Area | Behavior in this build |
|---|---|---|
| 1 | Files | No unsaved-changes prompt on New, Open or Quit |
| 2 | Pattern editor | Patterns can't be renamed in the GUI |
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
| 15 | Rack | Choice parameters show numbers, not names (see Appendix B) |
| 16 | Rack | Envelope editor: moving the sustain marker has no effect on parameters |
| 17 | Rack | MetaModule inner edits are not undoable |
| 18 | Sampler | AIFF is offered in the import dialog but can't be decoded; drag-and-drop isn't implemented |
| 19 | Sampler | The loop mode dropdown applies to all slots |
| 20 | Sampler | There are no destructive sample edits (trim, normalize and so on) |
| 21 | DrumSynth | Notes 48 and 50 play kick and snare, not high tom; only 47 plays the high tom |
| 22 | Vorbis Player | There is no way to load a file |
| 23 | Export | Stems, MIDI/XM/SunVox import, module presets and autosave are not exposed in the GUI |
| 24 | Panic | In the GUI, Panic stops the transport; it doesn't send a separate all-notes-off |

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
dracker --help
```

- **Running self-tests:** run them with `caffeinate -dims` so the display doesn't sleep. They keep a floating window open, and you shouldn't use the mouse or keyboard while they run.
- **Reading results:** each check prints `PASS` or `FAIL` with details, and the process exits with 0 when every check passed.
- **Your files are safe:** self-tests use temporary folders and never touch your projects, clipboard or appearance preferences.

**Building from source** (inside `dracker/`):

```zsh
dub build --compiler=ldc2 --config=app --build=debug   # studio app → ./build/dracker
dub test  --compiler=ldc2 --config=headless            # headless unit + fuzz tests
dub test  --compiler=ldc2 --config=app                 # macOS platform tests
```
