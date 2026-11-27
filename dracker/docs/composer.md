# dracker-compose: composer reference

This is the complete reference for `dracker-compose`, the composition helper of Dracker. It is written for an agent that composes a song by writing a script. Read it together with the output of `dracker-compose catalog`. Every example in this file was run with the real program.

## 1. What the program is

`dracker-compose` reads a script (a `.dcs` text file) and writes a Dracker project (`.msv`). It can also write module presets (`.msym`), turn an existing `.msv` or `.msym` back into a script, and play a project offline into a WAV file with a level report.

Build it from the `dracker/` folder:

```sh
dub build --compiler=ldc2 --config=compose
```

The program is `build/dracker-compose`.

### Subcommands

| Subcommand | What it does |
| --- | --- |
| `check <script>` | Runs the script without writing any file. Use it to find errors. |
| `run <script> [-o <file.msv>]` | Runs the script. Its `save` and `savemodule` commands write files. `-o` also writes the finished project to that file. |
| `render <file.msv> -o <file.wav>` | Plays the project offline into a WAV file (44,100 Hz, stereo, 32-bit float) and prints a level report. `-o` is required. |
| `describe <file.msv or file.msym>` | Prints the file as a script. |
| `catalog [topic]` | Lists what a script can use. Topics: `modules`, `presets`, `chords`, `progressions`, `keys`, `commands`, or one module type id or display name, such as `synth.drumsynth` or `"Analog Generator"`. No topic prints everything except the module details. |
| `help [subcommand]` | Shows the help. |

Every subcommand accepts `--json`. It prints the same information as one JSON object. With `--json`, errors also go to standard output as JSON. Without it, errors go to standard error as text.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | The script or a file has errors (also: a file could not be read, an unknown catalog topic). |
| 2 | Wrong usage: unknown subcommand, unknown option, missing argument, `render` without `-o`. |

`run` first runs the whole script in check mode. If anything fails, it writes no file at all. A `run` with no `save` command and no `-o` writes nothing and still succeeds (`Ran N commands.`).

### The workflow

1. Write `song.dcs`.
2. `dracker-compose check song.dcs`. Fix the first error it reports (it stops at the first failing command) and check again until it prints `OK (N commands checked).`
3. `dracker-compose run song.dcs -o song.msv` (or put `save "song.msv"` at the end and run without `-o`).
4. `dracker-compose render song.msv -o song.wav` and read the report (section 8).
5. Fix levels, silent bars or silent parts in the script. Repeat from step 2.

To start from an existing file, run `dracker-compose describe old.msv > old.dcs`, edit `old.dcs`, and run it.

### Output of each subcommand

```text
$ dracker-compose check two_sections.dcs
OK (30 commands checked).
$ dracker-compose run two_sections.dcs
Ran 30 commands.
Wrote two_sections.msv
$ dracker-compose check e_typo.dcs
dracker-compose: line 2, col 10: unknown parameter 'Cutof'; did you mean 'Cutoff'?
```

`check --json` prints `{"ok": true, "subcommand": "check", "commands": 30}`. `run --json` adds `"written": [ ...paths... ]`. `describe --json` prints `{"ok": true, "subcommand": "describe", "kind": "preset" or "project", "script": "..."}`. A failed script with `--json` prints:

```text
{
  "ok": false,
  "error": {
    "code": "script",
    "line": 2,
    "column": 10,
    "length": 10,
    "message": "line 2, col 10: unknown parameter 'Cutof'; did you mean 'Cutoff'?",
    "suggestion": "Cutoff",
    "subcommand": "check"
  },
  "problems": [
    {
      "line": 2,
      "column": 10,
      "length": 10,
      "message": "unknown parameter 'Cutof'",
      "suggestion": "Cutoff"
    }
  ]
}
```

## 2. Script syntax

### Lines and comments

- One command per line: a command word, then its arguments and options, separated by spaces or tabs.
- Blank lines are ignored.
- `//` starts a comment that runs to the end of the line. Inside double quotes, `//` is ordinary text.
- `#` is not a comment. It is the sharp sign in notes and keys (`C#4`, `key F# minor`).
- A line that ends with `\` (only spaces may follow it) continues on the next line. Use it for long note lists.

### Words, quotes and options

- A word is any run of characters without spaces.
- Text with spaces goes in double quotes: `"Electric Piano"`, `"Room Size"`. Inside quotes, `\"`, `\\`, `\n` and `\t` are escapes. Any other `\x` is an error.
- Nothing may touch a closing quote. `"Verse A":` is an error; write `"Verse A" :`.
- `name=value` is a named option. The name starts with a letter and holds letters, digits, `_` and `-`. The value is a word or a quoted text: `preset="Saw Lead"`. An option may appear only once per command.
- Command words, option names, module handles, part names, section names, lane names, parameter names, option values such as `Waveform=saw`, preset names and port names are all matched without regard to upper or lower case and spaces. `TEMPO 120`, `set lead cutoff=900`, `set verb RoomSize=0.6` and `drums d a "closed hat": x` all work.

### Handles

A module gets a handle when you add it: `module bass preset="Electric Bass"` makes the handle `bass`. All later commands name the module by its handle.

- A handle starts with an ASCII letter and holds only letters, digits, `_` and `-`, at most 32 characters.
- Handles must be unique. `out` is the Master Output, which every project has from the start. You cannot add, rename or remove it.
- In the app, a module is shown under its handle, unless you give `name="Display Name"`.
- Part and section names are separate from handles. They are any text up to 64 bytes (quote them if they contain spaces). Prefer one plain word.

### The colon in `notes`, `chords` and `drums`

These three commands take music after a colon. The first word that contains `:` ends the header. Everything after the colon is the music.

```dcs
module k preset="Pluck"
connect k out gain=0.6
section verse bars=1
part keys module=k
notes keys verse: C4 E4 G4 C5
notes keys verse at=1.3: E5:1/2
arrange verse
```

The colon may stick to the last header word (`verse:`, `at=1.3:`) or stand alone (`"Verse A" : C4`). `chords` and `drums` also accept their options after the music; `notes` does not.

### How errors are reported

`check` and `run` stop at the first command that fails and print one line:

```text
dracker-compose: line <L>, col <C>: <reason>[; did you mean '<name>'?|; the nearest valid value is <value>]
```

Line and column are 1-based and point at the word that is wrong. For a misspelled name the program adds the nearest valid name. For a wrong number it adds the nearest valid value. Lexer errors (an unterminated quote) are all reported at once before any command runs. A refused command changes nothing; for example `set` applies all its values or none.

Real error output:

```dcs-bad
module lead synth.analog_gen
set lead Cutoff=20000
```

```text
dracker-compose: line 2, col 10: '20000' is outside the range of 'Cutoff' (a number from 40 to 18000 Hz); the nearest valid value is 18000
```

```dcs-bad
modul lead synth.analog_gen
```

```text
dracker-compose: line 1, col 1: unknown command 'modul'; did you mean 'module'?
```

### Warnings

A script can be valid and still make no sound in places. After a successful `check` or `run`, the program prints one `Warning:` line for each of these, after the summary line; `--json` lists them in a `warnings` array (empty when there are none). The exit code stays 0, so read the output.

| Warning | Cause |
| --- | --- |
| `no section is arranged, so the song is silent; add 'arrange a b'` | Sections have notes, but there is no `arrange`. |
| `section 'b' has notes but is not arranged, so it is never heard` | A section with notes is missing from `arrange`. |
| `part 'p2' plays module 'pad', which was removed, so its notes make no sound` | `remove` of a module a part plays. |
| `drum part 'drums' lane 'Boom' plays module 'boom', which was removed, so its hits make no sound` | The same, for a drum lane. |
| `part 'empty' has no notes` / `drum part 'hats' has no hits` | A part was declared but nothing was written into it. |

```text
OK (12 commands checked).
Warning: no section is arranged, so the song is silent; add 'arrange a "b side"'.
Warning: part 'p2' plays module 'pad', which was removed, so its notes make no sound.
Warning: part 'empty' has no notes.
```

The Script tab in the app shows the same warnings after its "Applied ..." message. After `open`, and in the Script tab, sections and parts that were already in the project are not reported as unarranged or empty (a pattern waiting off the timeline is normal in the app); a part whose module was removed is always reported.

## 3. Musical time

### Lines

The pattern grid is made of lines. **One line is a sixteenth note.** A beat holds `16 / denominator` lines: 4 lines in 4/4 or 3/4, 2 lines in 6/8, 1 line in x/16. A bar holds `numerator × lines per beat` lines (16 in 4/4, 12 in 3/4, 12 in 6/8).

### Tempo

`tempo` is in quarter notes per minute (with the default `tpl=6`). One line lasts `tpl × 2.5 / bpm` seconds. Leave `tpl` at 6. Halving `tpl` doubles the speed.

### Positions

A position is `bar`, `bar.beat` or `bar.beat.sixteenth`, each counted from 1. `1` is the first line. `3.2` is bar 3, beat 2. `2.4.3` is bar 2, beat 4, third sixteenth of that beat. A beat number must be at most the numerator; a sixteenth at most the lines per beat.

**Positions are always counted from the start of the section** (or of the implicit section). They never span the arrangement.

### Lengths

| Written | Meaning (4/4) |
| --- | --- |
| `1`, `2`, `3` | beats (4, 8, 12 lines) |
| `1/2`, `1/4`, `3/2` | fractions of a beat (2, 1, 6 lines) |
| `2b`, `1/2b` | bars (32, 8 lines) |
| `3l` | lines (3 lines) |

A length must be a whole number of lines. `1/8` in 4/4 is refused: `"1/8" is not a whole number of lines in 4/4; the nearest length is 1/4`. The shortest note is one line (`1/4` beat in x/4).

**Chord lengths in a `chords` progression are in bars, not beats** (section 5.3).

### Time signatures

`signature n/d` with `n` from 1 to 16 and `d` 2, 4, 8 or 16. The default is 4/4. Set the signature before any `section` or music command, because patterns are sized when they are made.

### The pattern limit

One pattern holds at most 4096 lines. A section is one pattern per part, so a section is at most 4096 lines: 256 bars of 4/4, 341 bars of 3/4. Longer songs use more sections.

## 4. Commands

Arguments in `<angle brackets>` are required, `[square brackets]` are optional. Every example below is a complete script that passes `check` and `run`.

### 4.1 Project commands

#### `project <title>` and `title <title>`

Sets the project title. Both commands do the same thing. Quote a title with spaces. Default title: `Untitled`. At most 65536 bytes. The app's Script tab refuses `project` but accepts `title`.

```dcs
project "Night Drive"
title "Night Drive (mix 2)"
```

Error: `project Untitled Song` gives `command 'project' takes at most 1 argument` (quote it).

#### `tempo <bpm> [tpl=<ticks>]`

| Part | Values | Default |
| --- | --- | --- |
| `bpm` | decimal number, 20 to 999 | 125 |
| `tpl=` | ticks per line, whole number 1 to 255 | 6 |

```dcs
tempo 96
tempo 140.5 tpl=6
```

Error: `tempo 10` gives `the tempo is 20 to 999 beats per minute; the nearest valid value is 20`.

#### `signature <n/d>`

```dcs
signature 6/8
```

Error: `signature 4/3` gives `the denominator of a time signature is 2, 4, 8 or 16; the nearest valid value is 4`.

#### `key <tonic> [major|minor]`

The tonic is a letter A to G with an optional `#` or `b`. The mode is `major` or `minor`; nothing means major. You may also quote both: `key "F# minor"`. Default: `C major`. The key decides what Roman numerals mean and what `transpose steps=` does. `catalog keys` lists the notes of every key.

```dcs
key D minor
key "F# minor"
key Bb
```

Errors: `key H minor` gives `a key starts with a note name from A to G`; `key A dorian` gives `a key is a note name followed by 'major' or 'minor'; the nearest valid value is A major`.

#### `open <path>`

Loads an existing `.msv` as the starting point. It must be the first command of the script. Everything the helper does not understand is kept unchanged. After `open`:

- Each module's handle is its displayed name with everything except letters, digits, `_` and `-` removed (`Neon Lead` becomes `NeonLead`). Because matching ignores spaces, `NeonLead` is the handle to write.
- Parts and sections come back from pattern names of the form `<part> · <section>`. Patterns that do not fit stay at tracker level.
- Run `describe` on the file first to see the exact handles, parts and sections.

```dcs
open "neon_drift.msv"
tempo 98
set bus_comp Ratio=4
notes lead verse at=4.3: D5:1/2
save "neon_drift_edit.msv"
```

Error: anything before `open` gives `'open' must be the first command in a script`. The app's Script tab refuses `open`.

### 4.2 Module commands

#### `module <handle> [<type>] [preset=<name>] [file=<path>] [keep=<path>] [name=<text>] [x=<n>] [y=<n>]`

Adds a module. Give exactly one source:

| Source | Meaning |
| --- | --- |
| `<type>` | A type id (`synth.analog_gen`) or display name (`"Analog Generator"`) from `catalog modules`. The module starts at its default values. |
| `preset=<name>` | A bundled or user preset from `catalog presets`, such as `preset="Electric Bass"`. Write `preset="Keys/Electric Piano"` (group/name) when two presets share a name. |
| `file=<path>` | A `.msym` preset file, for example one written by `savemodule`. |
| `keep=<path>` | `keep="<file.msv>:<id>"` copies module number `<id>` from a project unchanged; `keep="<file.msym>"` copies a preset unchanged. `describe` writes these for modules it cannot print as parameters. |

| Option | Meaning | Default |
| --- | --- | --- |
| `name=` | Displayed name. Any text up to 64 bytes, without `/`, `\`, `:` or control characters, not starting with `.` | the handle |
| `x=`, `y=` | Position on the patch canvas, decimal numbers | automatic layout |

Automatic layout fills columns of 4 modules from (60, 60), 180 apart across and 160 down; the Master Output goes one column to the right of them.

```dcs
module bass preset="Electric Bass"
module lead synth.analog_gen name="Neon Lead"
module pad "Analog Generator" x=100 y=400
module keys preset="Keys/Electric Piano"
```

Errors:

- `module lead synth.analog` gives `unknown module type 'synth.analog'; did you mean 'synth.analog_gen'?`
- `module lead preset="Saw Leed"` gives `unknown preset 'Saw Leed'; did you mean 'Saw Lead'?`
- `module 1lead synth.analog_gen` gives `a module name starts with a letter and holds only letters, digits, '_' and '-', at most 32 characters; did you mean 'lead'?`
- A second `module lead ...` gives `there is already a module 'lead'; did you mean 'lead2'?`
- No source gives `module 'x' needs a module type, preset=<name>, file=<path>, or keep=<path>`; two sources give `give only one of module type, preset=<name>, file=<path>, or keep=<path>`.

#### `set <handle> <Param>=<value> [<Param>=<value> ...]` or `set <handle> <param> <value>`

Sets parameters. Parameter names are the display names from `catalog <type>`, matched without case or spaces, so `"Room Size"` can be written `RoomSize=0.62`. Use the second form with quotes when you prefer the exact name: `set reverb "Room Size" 0.62`.

- A number must be inside the range shown by the catalog. **Out-of-range values are errors, never clipped.**
- A discrete parameter takes a whole number or one of its option names: `Waveform=Saw`, `Algorithm="Two Stacks"`, `Unit=ms`.
- All values of one `set` are applied together, or none.
- `set out Volume=0.8` and `set out Limiter=Off` change the Master Output.

```dcs
module lead synth.analog_gen
set lead Waveform=Square Unison=2 Detune=0.18 Cutoff=2600 Resonance=0.25
set lead Attack=0.01 Decay=0.25 Sustain=0.6 Release=0.18
module verb fx.reverb
set verb "Room Size" 0.62
set verb Pre-Delay=8
```

Errors:

- `unknown parameter 'Cutof'; did you mean 'Cutoff'?`
- `'20000' is outside the range of 'Cutoff' (a number from 40 to 18000 Hz); the nearest valid value is 18000`
- `'2.5' is not a whole number; 'Unison' takes a whole number from 1 to 4; the nearest valid value is 3`
- `unknown value 'Sawtooth' for 'Waveform'` (use `catalog synth.analog_gen` to see `Sine, Triangle, Saw, Square, Noise, Drawn`)

#### `preset <handle> <name>` or `preset <handle> file=<path>`

Replaces all parameters of an existing module with a preset of the same type. The handle, the displayed name and the wires stay.

```dcs
module pad "Analog Generator" name="Big Pad"
preset pad "Warm Pad"
```

Error: a preset of another type gives `preset type '<type>' does not match module '<handle>' ('<type>')`.

#### `sample <handle> <path> [slot=<n>] [root=<note>] [low=<note>] [high=<note>]`

Loads an audio file into a Sampler (`synth.sampler`) slot.

| Option | Values | Default |
| --- | --- | --- |
| `slot=` | 0 to 15 | 0 |
| `root=` | pitch (`C4`) or MIDI number 0 to 127; the pitch the file plays at | C4 (60) |
| `low=`, `high=` | lowest and highest key of the slot, pitch or MIDI number | 0 and 127 |

```dcs
module samp synth.sampler
sample samp "first_idea.wav" slot=0 root=A4 low=C2 high=C6
connect samp out gain=0.5
```

Errors: `only a Sampler module can load a sample; 'synth.fm_synth' is not a Sampler`; `could not load the sample: nofile.wav: No such file or directory`; a sample larger than 64 MiB of module data is refused.

#### `savemodule <handle> <path>`

Writes the module as a `.msym` preset. In `check` mode nothing is written, but a later `module x file=<same path>` in the same script still works.

```dcs
module lead synth.analog_gen name="Neon Lead"
set lead Waveform=saw Unison=2 Cutoff=2600
savemodule lead "neon_lead.msym"
module harmony file="neon_lead.msym" name="Neon Harmony"
set harmony Cutoff=1600
```

#### `connect <src> <dst> [gain=<g>] [from=<port>] [to=<port>]`

Adds a wire from an output port of `src` to an input port of `dst`.

| Option | Values | Default |
| --- | --- | --- |
| `gain=` | linear factor, 0 or more | 1 |
| `from=` | output port of `src`, by id or name | the first audio output |
| `to=` | input port of `dst`, by id or name | the first audio input |

Ports are listed by `catalog <type>` as `id (Name): direction kind`, for example `scIn (Sidechain): in sidechainStereo`. Write either the id or the name (`to=scIn` or `to=Sidechain`). Wires into the same input add up.

Port kinds: audio output goes to audio or sidechain input; event output goes only to event input; CV output goes only to CV input. Event and CV wires always need `from=` and `to=`.

A part's notes go straight to its module; **no event wire is needed for a synth**. What a synth needs is an audio path to `out`.

```dcs
module kit preset="Drum Kit"
module comp fx.compressor
module wob fx.lfo
module filt fx.filter_pro
connect kit comp gain=0.45
connect kit comp to=Sidechain gain=0.45
connect comp filt
connect wob filt from=cvOut to=cutoffCv
connect filt out gain=0.6
```

Errors:

- `there is no module 'outt'; did you mean 'out'?`
- `module 'out' has no input port 'Sidechain'; did you mean 'Input'?`
- `module 'b' has no audio input port; did you mean 'Events In'?` (an audio wire into a synth)
- `module 'a' has no audio output port; did you mean 'Events Out'?` (MultiSynth to `out`)
- `wire gain must be a finite number of 0 or more; the nearest valid value is 1`
- `a wire from 'a' (Audio Out) to 'out' (Input) already exists`
- `connecting 'b' to 'a' creates a feedback loop; break the loop with a Feedback module`

#### `disconnect <src> <dst> [from=<port>] [to=<port>]`

Removes one wire. Ports default as in `connect`.

```dcs
module a preset="Pluck"
connect a out
disconnect a out
```

Error: `there is no wire from 'a' (Audio Out) to 'out' (Input)`.

#### `remove <handle>`

Removes a module and all its wires. Do not remove a module that a part still plays: the script still runs, but that part's notes then play nothing, and `check` and `run` print a warning such as `Warning: part 'p2' plays module 'pad', which was removed, so its notes make no sound.` (section 2, Warnings).

```dcs
module spare fx.echo
connect spare out
remove spare
```

Error: `remove out` gives `the Master Output 'out' cannot be removed`.

### 4.3 Music commands

Music lives in parts and sections. A **section** is a named stretch of bars (`verse`, 4 bars). A **part** is one voice bound to one module (`bass` plays module `bass`) or a drum part bound to drum lanes. Each part gets one pattern per section it plays in, named `<part> · <section>`, created on first use.

**Implicit section.** If a script declares no section at all, writing music without a section name uses one implicit section. It grows to fit the music (whole bars) and is arranged automatically. Do not mix the two ways: if you use sections, declare them before any music, name a section in every music command, and call `arrange`. A music command without a section name, once sections exist, fails with `a section is needed here, because the song has sections (a, b); write the section after the part name`.

#### `section <name> bars=<n>`

`bars=` is required, a whole number of 1 or more, and `bars × lines per bar` must be at most 4096. (`catalog commands` prints it in brackets like every option; it is still required.)

```dcs
section intro bars=4
section "Verse A" bars=8
```

Errors: `command 'section' requires option bars=<count>; the nearest valid value is bars=4`; `there is already a section 'intro'; did you mean 'intro2'?`; too long: `section 'x' (300 bars, 4800 lines) exceeds the maximum pattern length of 4096 lines; the nearest valid value is 256`.

#### `part <name> module=<handle>` or `part <name> drums=<handle>`

`module=` makes a melodic part. `drums=` makes a drum part; when the module is a DrumSynth (`synth.drumsynth`) the part gets the standard kit lanes (section 5.4).

```dcs
module bass preset="Electric Bass"
module kit preset="Drum Kit"
part bass module=bass
part drums drums=kit
```

Errors: `command 'part' requires module=<handle> or drums=<handle>`; `there is no module 'bas'; did you mean 'bass'?`; `there is already a part 'bass'; did you mean 'bass2'?`.

#### `notes <part> [<section>] [at=<position>]: <notes>`

Writes notes, chords and rests (section 5.1) into the part's pattern for that section, starting at `at=` (default `1`). Notes are added to what is already there. The whole command is refused if any note fails.

```dcs
module lead preset="Saw Lead"
connect lead out gain=0.3
section verse bars=2
part lead module=lead
notes lead verse: A4:1 F4:1 D4:2 Bb4:1 A4:1 G4:2
notes lead verse at=2.3: [C5 E5]:1/2@0.6 -:1/2 D5:1
arrange verse
```

Errors:

- `command 'notes' needs ':' before the notes`
- `note runs past the end of section 'verse'; the nearest valid value is 1.4` (the value is the last start position that fits)
- `another note of the same pitch already sounds at 1` (a same-pitch note overlaps an existing one; `clear` first)
- `a section is needed here, because the song has sections (a, b); write the section after the part name` (the section name is missing while sections exist; reported at the part name)

#### `chords <part> [<section>] [options]: <progression> [options]` or `chords <part> [<section>] preset=<name> [options]`

Turns a chord progression into notes. With `preset=` no colon is needed. Options may stand before or after the colon. All options are described in section 5.3.

| Option | Values | Default |
| --- | --- | --- |
| `style=` | `hold`, `pulse`, `arp`, `root`, `root5` | `hold` |
| `octave=` | octave of the chord root (C4 = middle C) | 4; 2 for `root` and `root5` |
| `voices=` | 3 or 4 | the chord's own size |
| `voicing=` | `root` or `close` | `root` |
| `every=` | length (beats, `b`, `l`) | 1 beat; for `arp` 1/4 beat |
| `dir=` | `up`, `down`, `updown` (arp only) | `up` |
| `rhythm=` | step string, with `hold`, `root` or `pulse` | none |
| `preset=` | progression name from `catalog progressions` | none |
| `vel=` | velocity, above 0 and at most 1 | 0.8 |
| `at=` | start position in the section | 1 |

```dcs
key A minor
module keys preset="Electric Piano"
module bass preset="Electric Bass"
connect keys out gain=0.22
connect bass out gain=0.3
section verse bars=4
part keys module=keys
part bass module=bass
chords keys verse voicing=close: i VI III VII
chords bass verse: i VI III VII style=root octave=2
arrange verse
```

Errors:

- `command 'chords' needs ':' before the chord progression`; with a chord but no colon (`chords m a I`): `command 'chords' takes at most 2 arguments`
- `unknown chord style 'strum' (expected hold, pulse, arp, root, or root5)`
- `"Hm": Not a chord: write a Roman numeral (I–VII, i–vii) or a chord name (C, Dm, G7); the nearest valid value is I`
- `"VIIm": Unknown chord type "m"; the nearest valid value is I` (Roman numerals show minor by lower case: `vii`)
- `rhythm length 3 does not divide a bar of 16 lines; the nearest valid value is 16`
- `option 'rhythm' can only be combined with style hold, root, or pulse; the nearest valid value is hold`
- `option 'voices' must be 3 or 4; the nearest valid value is 3`
- A progression longer than the section: `the progression needs 4 bars, but section 'a' has 2 bars; lengthen the section (section a bars=4) or shorten the progression` (reported at the progression; with `at=` the message says `needs 3 bars from 1.3`)

#### `drums` (three forms)

```text
drums <part> module=<handle>                                   declare a drum part (same as part <part> drums=<handle>)
drums <part> lane=<name> module=<handle> note=<pitch|0-127>    add a lane (creates the part if needed)
drums <part> [<section>] <lane> [options]: <steps> [options]   write steps on a lane
```

| Option (step form) | Values | Default |
| --- | --- | --- |
| `at=` | start position (ignored with `fill=`) | 1 |
| `fill=` | `<bar>` or `<first>-<last>`: repeat the steps over those bars of the section | none |
| `vel=` | velocity of `x`/`o` | 0.8 |
| `accent=` | velocity of `X`/`O`/`!` | 1.0 |
| `ghost=` | velocity of `g` | 0.45 |

Step strings and lanes are described in section 5.4.

```dcs
module kit preset="Drum Kit"
module boom preset="Kick"
connect kit out gain=0.4
connect boom out gain=0.5
section a bars=2
part drums drums=kit
drums drums lane=Boom module=boom note=C2
drums drums a kick fill=1-2: x.......x.......
drums drums a snare fill=1-2: ....X.......X...
drums drums a "Closed Hat" fill=1-2 vel=0.6 ghost=0.3: x.g.x.g.x.g.X.g.
drums drums a Boom at=2.4.3: x.
arrange a
```

Errors:

- `drum part 'd' has no lane 'clap'`
- `unexpected step character 'y' (use x/X/g for hits and - for rests); the nearest valid value is x`
- `end bar 2 exceeds section length of 1 bars; the nearest valid value is 1`
- `step pattern runs past the end of the section; the nearest valid value is 1`
- `there is no drum part 'p'` (a melodic part used with `drums`), `there is no part 'd'` (a drum part used with `notes`)

#### `cells <target> [<section>] [options]`

Writes one raw tracker cell. Use it for things notes cannot say: an exact note-off, an effect code, parameter automation. See section 5.5.

```dcs
module lead preset="Pluck"
connect lead out gain=0.5
section b bars=2
part m module=lead
cells m b line=0 note=C5 vel=0.9
cells m b at=1.3 note=off
cells m b at=2 note=E5 fx=slideUp fxval=0x10
cells m b at=2.2 module=lead param=Release val=100
arrange b
```

Errors: `command 'cells' needs line=<n> or at=<pos>; the nearest valid value is line=0`; `invalid tracker note 'X' (use pitch like C4, off, alloff, prev, setpitch, stop, or none); the nearest valid value is C4`; `named parameter automation requires module=<handle>`.

#### `copy <part> [<section>] from=<pos> len=<length> to=<pos> [part=<part>] [section=<section>]`

Copies the notes that **start** inside `[from, from + len)` to `to=`. A note longer than the range is cut at the range end. The destination defaults to the same part and section. `from=`, `len=` and `to=` are required.

```dcs
key D minor
module lead preset="Saw Lead"
module harm preset="Warm Pad"
connect lead out gain=0.3
connect harm out gain=0.2
section chorus bars=4
part lead module=lead
part harmony module=harm
notes lead chorus: D5:1 F5:1/2 E5:1/2 D5:2 F5:1 D5:1 Bb4:2
copy lead chorus from=1 len=2b to=3
copy lead chorus from=1 len=4b to=1 part=harmony section=chorus
transpose harmony chorus from=1 len=4b steps=-2
arrange chorus
```

Error: `copied range runs past the end of section 'chorus'; the nearest valid value is 3` (the last `to=` that fits).

#### `repeat <part> [<section>] [from=<pos>] len=<length> times=<n>`

Repeats the range `times` more times right after it. `from=` defaults to `1`. `times=` is a whole number of 1 or more.

```dcs
module bass preset="Synth Bass"
connect bass out gain=0.35
section groove bars=4
part bass module=bass
notes bass groove: E2:1/2 E2:1/2 G2:1/2 E2:1/2 A2:1 B2:1
repeat bass groove from=1 len=1b times=3
arrange groove
```

Error: `repeating range 4 times runs past the end of section 'groove'; the nearest valid value is 3` (the value is the largest count that fits).

#### `transpose <part> [<section>] [from=<pos>] [len=<length>] by=<semitones> | steps=<scale steps>`

Moves the notes that start in the range. Give exactly one of `by=` (semitones, may be negative) or `steps=` (steps of the project key's scale; a note outside the scale keeps its offset). `from=` defaults to `1`; `len=` defaults to the rest of the section.

```dcs
key C major
module lead preset="Pluck"
connect lead out gain=0.5
section a bars=2
part m module=lead
notes m a: C4 D4 E4 G4 C4 D4 E4 G4
transpose m a from=2 by=12
transpose m a from=2.3 len=2 steps=-1
arrange a
```

Errors: `command 'transpose' needs either by=<semitones> or steps=<scaleSteps>; the nearest valid value is by=12`; `transposing puts note outside MIDI pitch range 0..127; the nearest valid value is 127`.

#### `clear <part> [<section>] [from=<pos>] [len=<length>]`

Removes the notes that start in the range, and any `cells` written on those lines. `from=` defaults to `1`; `len=` defaults to the rest of the section. Use it before rewriting notes.

```dcs
module lead preset="Pluck"
connect lead out gain=0.5
section a bars=1
part m module=lead
notes m a: C4 D4 E4 G4
clear m a from=1.3
notes m a at=1.3: F4 A4
arrange a
```

### 4.4 Arrangement commands

#### `arrange <section> [<section> ...]`

Puts sections on the song timeline in order. A section may appear more than once; the copies are clones of one pattern (edit once, all change). Each part gets its own timeline lane (melodic parts in declaration order, then drum parts). A part with no music in a section leaves a gap there. Calling `arrange` again replaces the previous arrangement; clips placed with `arrange clip=` for raw patterns stay. **Without `arrange`, a script with named sections renders silence**, and `check` and `run` warn: `Warning: no section is arranged, so the song is silent; add 'arrange verse chorus'.` The default loop covers the whole arrangement.

```dcs
module k preset="Pluck"
connect k out gain=0.5
section verse bars=1
section chorus bars=1
part p module=k
notes p verse: C4:4
notes p chorus: G4:4
arrange verse chorus verse chorus
```

Error: `there is no section 'chorsu'; did you mean 'chorus'?`.

#### `arrange clip=<pattern> start=<line> len=<lines> lane=<n> [offset=<lines>] [mute=on|off] [solo=on|off] [supertrack=on|off]`

Places one clip by hand, in lines from the song start. `<pattern>` is a pattern name (`"m · a"`, with the middle dot `·` and spaces, as patterns are named) or `#<id>`. `describe` writes this form when a project's timeline is not a plain section list. `start=`, `len=` and `lane=` are required.

**The two forms combine.** A clip placed after `arrange <sections>` is added on top of the section arrangement: the sections keep their positions and the clip keeps its lane (pick a lane above the parts' lanes, which are 0, 1, 2, ... in part order, then the drum parts). `arrange <sections>` after clips keeps the clips of raw patterns (`cells`) and replaces the rest. The default loop then runs to the end of the arrangement or of the last clip, whichever is later. Tested: `arrange a b a` followed by `arrange clip=riff start=0 len=16 lane=5` gives the three section clips at lines 0, 16 and 32 and the riff at line 0 on lane 5 (3 bars); the other order gives the same timeline.

```dcs
module lead preset="Pluck"
connect lead out gain=0.6
section a bars=1
section b bars=1
part m module=lead
notes m a: C4:4
notes m b: G4:4
arrange clip="m · a" start=0 len=16 lane=0
arrange clip="m · b" start=16 len=16 lane=0
```

#### `loop <section> [<last section>]`, `loop all`, `loop start=<line> end=<line>`

Sets the song loop, which the app uses when it plays. `loop verse chorus` loops from the first `verse` in the arrangement to the first `chorus` at or after it, inclusive. `loop verse` loops that one section. `loop all` (also `clear` or `reset`) loops the whole arrangement (the default). `start=`/`end=` give lines from the song start. Use `loop` after `arrange`.

**`render` does not follow the loop.** It plays the arrangement once from the start to its end, and its report prints the loop it did not follow (section 7.2).

```dcs
module k preset="Pluck"
connect k out gain=0.5
section intro bars=1
section verse bars=1
section chorus bars=1
part p module=k
notes p intro: C4:4
notes p verse: E4:4
notes p chorus: G4:4
arrange intro verse chorus
loop verse chorus
```

Errors: `section 'x' is not in the arrangement`; `section 'intro' does not appear at or after 'verse' in the arrangement`.

### 4.5 Output commands

#### `save <path>`

Checks the whole project (the app's own save checks and a trial start of the audio engine) and writes the `.msv`. In `check` mode it does all the checks but writes nothing. A script may save more than once. The app's Script tab refuses `save`.

```dcs
module k preset="Pluck"
connect k out gain=0.5
part p module=k
notes p: C4 E4 G4 C5
save "tiny.msv"
```

`savemodule` (section 4.2) writes presets.

### 4.6 The app's Script tab

The same language runs in the app's Script tab, against the open project. It refuses three commands with these reasons:

- `project`: `'project' would replace the open project; set the title, tempo, signature and key with 'title', 'tempo', 'signature' and 'key'`
- `open`: `'open' is not available in the Script tab; open a project with File > Open`
- `save`: `'save' is not available in the Script tab; save the project with File > Save`

There, relative file paths (`file=`, `keep=`, `sample`, `savemodule`) are read from the project's folder. Before the project has been saved, a relative path is refused: `save the project first, or write an absolute path: a relative path is read from the project's folder`. On the command line, relative paths are relative to the working folder.

## 5. Notes, chords, drums and cells

### 5.1 Note notation (`notes`)

A note list is a sequence of items separated by spaces:

| Item | Meaning |
| --- | --- |
| `C4` | a note |
| `C4:2` | a note 2 beats long |
| `C4:1/2@0.6` | half a beat at velocity 0.6 |
| `-` or `-:2` | a rest |
| `[C4 E4 G4]:2` | notes played together (a chord), 2 beats |
| `[C4 E4 G4]:1@0.5` | a chord with length and velocity |

**Pitch.** A capital letter `A` to `G`, then up to two `#` or two `b` (not mixed), then the octave from `-1` to `9`. `C4` is middle C (MIDI 60). `A4` is MIDI 69. `C-1` is the lowest (0), `G9` the highest (127). `C#4` = `Db4`; `B#3` = `C4`; `Cbb4` = `Bb3`. Lower-case letters are an error: `note letters are capitals (A to G); the nearest valid value is C4`.

**Length.** After `:`, in beats (`1`, `1/2`, `2`), bars (`1b`) or lines (`3l`). **A length carries over** to the following items of the same command until another length is written. The first item without a length is 1 beat. Rests carry lengths too: in `C4:2 - E4`, the rest and `E4` are 2 beats each.

**Velocity.** After `@`, a number above 0 and at most 1 (for example `0.6`, `1`). Default 0.8. Velocity does not carry over; write it on each item. A rest has no velocity. Length comes before velocity: `C4:2@0.5`.

**Not allowed in notes:** `|` (bar lines), options after the colon, lower-case letters.

**Overlap and polyphony.** A tracker track plays one note at a time. The helper hides this: overlapping notes of different pitch go to extra tracks automatically (up to 64 tracks per pattern), and every note gets a note-off at its end unless the next note on that track starts there. So you may write a melody and a second voice into the same part with two `notes` commands at the same position. Two notes of the **same pitch** may not overlap: `another note of the same pitch already sounds at 1`.

```dcs
module k preset="Electric Piano"
connect k out gain=0.2
section a bars=1
part p module=k
notes p a: C4:4
notes p a: E4:2 G4:2
notes p a at=1.3: [B4 D5]:1 -:1/2 A4:1/2@0.5
arrange a
```

### 5.2 Positions inside commands

`at=`, `from=` and `to=` are positions (section 3); `len=` and `every=` are lengths. Positions are always inside the named section. To place music in bar 3 of a section, write `at=3`, never a song-wide bar number.

### 5.3 Chord progressions (`chords`)

**Chord tokens.**

- Roman numerals `I` to `VII` relative to the key. Upper case is major, lower case is minor. A `b` or `#` (also `♭` `♯`) in front lowers or raises the degree: `bVII`, `#iv`.
  - Upper-case suffixes: none (major), `7` (dominant 7th), `maj7`, `aug` or `+`, `sus2`, `sus4`.
  - Lower-case suffixes: none (minor), `7` (minor 7th), `dim` or `°`, `dim7` or `°7`, `m7b5` or `ø` or `ø7` (half-diminished), `sus2`, `sus4`.
  - Numerals take their root from the key's scale. In a minor key that is the natural minor scale: in D minor, `i` = Dm, `III` = F, `VI` = Bb, `VII` = C, `v` = Am, `V` = A.
  - Numerals have no slash form.
- Chord names: a root `A` to `G` with optional `#` or `b`, a suffix (none, `m`, `dim`, `°`, `aug`, `+`, `sus2`, `sus4`, `7`, `maj7`, `m7`, `m7b5`, `ø`, `ø7`, `dim7`, `°7`), and an optional slash bass: `Cmaj7`, `Am`, `F#m7`, `C/E`.

`catalog chords` lists every quality with its intervals.

**Lengths are in bars.** Each chord lasts one bar. `Dm7:2` lasts 2 bars, `Dm7:1/2` half a bar, `G:1/4` a quarter bar. The length must be a whole number of lines.

**Separators.** Spaces, commas, `-`, `->` and `|` all separate chords. `|` is only for reading: `i:1/2 iv:1/2 | v:2 | i`.

**Presets.** `preset="Minor pop"` uses a named progression from `catalog progressions` (one bar per chord):

| Name | Chords |
| --- | --- |
| Circle of fifths | iii - vi - ii - V - I |
| Pop | I - V - vi - IV |
| Fifties | I - vi - IV - V |
| Pop (minor start) | vi - IV - I - V |
| Three chords | I - IV - V |
| Jazz ii-V-I | ii - V - I |
| Canon | I - V - vi - iii - IV - I - IV - V |
| 12-bar blues | I7 - I7 - I7 - I7 - IV7 - IV7 - I7 - I7 - V7 - IV7 - I7 - V7 |
| Minor pop | i - VI - III - VII |
| Minor three chords | i - iv - v |
| Andalusian cadence | i - VII - VI - V |

The progression fills the section from `at=`; it may be shorter than the section, but not longer.

**Voicing.**

- The root is placed in octave `octave=` (default 4, so `I` in C is C4 E4 G4). The other notes stack upward (root position).
- **Bass roots do not follow voice leading.** With `style=root` or `root5` every root is its pitch class in octave `octave=` (default 2), so roots that fall late in the octave (A, B) land near its top: in E minor, `VI VII i V` gives C2 D2 E2 **B2**, a jump up instead of a step down to B1. `voicing=close` only affects the upper chord notes. Fix a jump afterwards with `transpose <part> <section> from=<pos> len=<len> by=-12`, or write that bass line with `notes`.
- `voices=3` drops the 7th of a four-note chord. `voices=4` adds the root an octave up to a triad.
- `voicing=close` keeps the first chord in root position and voices every following chord in the inversion and octave that moves least from the previous one. Use it for keys and pads; root position jumps around (`i VI III VII` in A minor gives A4, F4, C4, G4 roots).
- A slash bass (`C/E`) is used by `root` and `root5` only. `hold`, `pulse` and `arp` voice the chord from its root.

**Styles.**

| Style | What it plays |
| --- | --- |
| `hold` | All chord notes for the chord's full length. |
| `pulse` | The chord again every `every=` (default 1 beat); each hit lasts `every`. |
| `arp` | One note at a time, every `every=` (default 1/4 beat, a sixteenth in x/4), through the chord notes by `dir=`: `up` (low to high, again), `down`, or `updown` (C E G B G E C E ...). |
| `root` | The bass note (the root, or the slash bass) for the chord's full length. Default octave 2. |
| `root5` | Root and fifth alternating every `every=` (default 1 beat). Default octave 2. |

**Rhythm.** `rhythm="x.x.X..."` plays hits on a step grid, combined with `hold` (the default), `root` or `pulse`. One character is one line (a sixteenth in x/4):

| Character | Meaning |
| --- | --- |
| `x`, `o` | hit at `vel=` |
| `X`, `O`, `!` | accent: `vel` × 1.25, at most 1 |
| `-`, `.` | rest |
| space, tab, `\|` | ignored |

The step count must divide one bar's lines (in 4/4: 1, 2, 4, 8 or 16 steps). The string repeats through each chord, starting again at each chord. With `hold` and `root` each hit lasts until the next hit or the chord's end. With `pulse` each hit lasts `every=` (default one line) or until the next hit if that is sooner. Quote the rhythm only if it contains spaces.

Real result of `chords rh s style=hold rhythm="x.x.X..." vel=0.6: I V` in C major (from `describe`): `[C4 E4 G4]:1/2@0.6 [C4 E4 G4]:1/2@0.6 [C4 E4 G4]:1@0.75 ...`.

```dcs
key C major
module k preset="Electric Piano"
module b preset="Electric Bass"
connect k out gain=0.2
connect b out gain=0.3
section s bars=3
part hold module=k
part arp module=k
part bass module=b
chords hold s voicing=close voices=4: I vi IV:1/2 V7:1/2
chords arp s style=arp dir=updown every=1/4: Cmaj7 Am7 Fmaj7
chords bass s style=root5: C/E G | F
arrange s
```

### 5.4 Drum parts

A drum part is a set of **lanes**. Each lane is a name, a module and a MIDI note. A drum part bound to a DrumSynth (`part drums drums=kit` with `module kit preset="Drum Kit"`) starts with these lanes:

| Lane | Note |
| --- | --- |
| Kick | 36 (C2) |
| Snare | 38 (D2) |
| Closed Hat | 42 (F#2) |
| Open Hat | 46 (A#2) |
| Low Tom | 43 (G2) |
| High Tom | 48 (C3) |
| Perc | 39 (D#2) |

Add lanes with `drums <part> lane=<name> module=<handle> note=<pitch or number>`. A lane may play any module: a Kicker, a Sampler, a second DrumSynth. A drum part holds at most 64 lanes. Lane names match without case or spaces (`kick`, `"closed hat"`, `ClosedHat`).

**Step strings.** One character is one line (a sixteenth in x/4), so `x...x...x...x...` is four quarter notes in a 4/4 bar.

| Character | Meaning |
| --- | --- |
| `x`, `o` | hit at `vel=` (default 0.8) |
| `X`, `O`, `!` | accent at `accent=` (default 1.0) |
| `g` | ghost at `ghost=` (default 0.45) |
| `-`, `.` | rest: **clears** that line of the lane |
| space, tab, `\|` | ignored |

**Writing.** Without `fill=`, the string is written once from `at=` (default 1) and must fit in the section. With `fill=1-4` the string repeats from the start of bar 1 to the end of bar 4 (`fill=4` is bar 4 only); `at=` is ignored. A later command overwrites the same lines, so write the groove first and a fill bar after it:

```dcs
tempo 104
module kit preset="Drum Kit"
connect kit out gain=0.45
section chorus bars=4
part drums drums=kit
drums drums chorus kick fill=1-4: x..x..x.x..x..x.
drums drums chorus snare fill=1-4: ....X.......X...
drums drums chorus "Open Hat" fill=1-4: ..x...x...x...x.
drums drums chorus snare fill=4: ....X..xx.X.XXXX
arrange chorus
```

Drum hits are one-shots; the voice decides how long it rings (DrumSynth `Kit Decay`, Kicker `Decay`).

### 5.5 Cells (tracker level)

`cells` writes one exact tracker cell into a pattern. Target forms:

- `cells <part> <section> ...`: the part's pattern in that section.
- `cells <part> ...`: the part's pattern in the implicit section.
- `cells <name> tracks=<n> lines=<n>`: create a raw tracker pattern (1 to 64 tracks, 1 to 4096 lines). Later `cells <name> line=...` write into it. A raw pattern plays only when placed with `arrange clip=`, which may follow `arrange <sections>` (section 4.4).

| Option | Values | Default |
| --- | --- | --- |
| `line=` or `at=` | 0-based line, or a position (one of them is required) | none |
| `track=` | 0-based track, up to 63 (tracks are added as needed) | 0 |
| `note=` | a pitch (`C4`), or `off` (`noteOff`), `alloff` (`allNotesOff`), `prev` (`prevTrack`), `setpitch`, `stop` (`stopSong`), `none` (`empty`) | empty |
| `vel=` or `velbyte=` | velocity above 0 and at most 1, or the raw byte 0 to 255 | 0.8 for a pitch |
| `module=` | handle, or `none` | the part's module for a pitch or `off` |
| `fx=` | effect: a byte (`0x01`) or a name: `none`, `slideUp`, `slideDown`, `portamento`, `vibrato`, `pitchOffsetUp`, `pitchOffsetDown`, `sampleOffset`, `arpeggio` (or `arp`), `sampleOffsetFine`, `velocitySlide`, `setSpeed`, `fineSlideUp`, `fineSlideDown`, `bypassModule`, `muteModule`, `retrigger`, `noteCut`, `noteDelay`, `setBpm`, `stopSong`, `jumpLine` | none |
| `fxval=` | effect value, 0 to 255 or `0x00` to `0xFF` | 0 |
| `param=` with `val=` | automation: parameter name and value of `module=` (required). The value is checked against the range like `set`. Or `param=<number>` (a raw parameter id) without `val=` | none |

Cells written this way are "hand placed": later `notes` and `chords` never overwrite them; `clear` removes them in its range. A `cells ... note=off` inside a note cuts it there.

## 6. Modules and sound

### 6.1 Picking instruments

Start from the bundled presets (`catalog presets`). They are tuned and safe:

| Group | Preset | Type | Character |
| --- | --- | --- | --- |
| Bass | Electric Bass | synth.analog_gen | Saw, cutoff 900 Hz, short release. Round bass. |
| Bass | Synth Bass | synth.analog_gen | Square, 2 unison voices, resonance 0.45. Punchy synth bass. |
| Keys | Electric Piano | synth.fm_synth | Decaying electric piano, 2.5 s decay. Chords. |
| Keys | Bright Piano | synth.fm_synth | Brighter, shorter piano. |
| Keys | Bell | synth.fm_synth | Bell tones, long decay. Melodies, sparkle. |
| Keys | Organ | synth.fm_synth | Sustained additive organ. |
| Pads & Leads | Pluck | synth.fm_synth | Short plucked tone (220 ms decay). Arpeggios, riffs. |
| Pads & Leads | Saw Lead | synth.analog_gen | Bright detuned saw. Leads. |
| Pads & Leads | Strings | synth.spectravoice | Slow (180 ms) attack, brass-like ensemble. Pads. |
| Pads & Leads | Warm Pad | synth.analog_gen | 4 unison voices, 0.6 s attack, 1.2 s release. Long chords only. |
| Drums | Drum Kit | synth.drumsynth | All kit lanes on one module. |
| Drums | Kick | synth.kicker | A tuned kick drum on its own. |
| Effects | Bus Compressor | fx.compressor | Threshold -24 dB, makeup +6 dB. |
| Effects | Room Reverb | fx.reverb | Wet 0.45, room 0.6. |
| Effects | Tempo Delay | fx.delay | Delay in lines (Unit=Lines/100: 300 = 3 lines). |
| Effects | Warm Overdrive | fx.distortion | Asymmetric drive 8. |

To see every parameter value of a preset, add it in a small script (`module x preset="Saw Lead"`, then `save "x.msv"`), `run` it and `describe x.msv`: the `set` lines it prints are the preset's values. To build a sound from scratch, use `module x <type>` and `set`, reading the ranges from `catalog <type>`. Useful types:

- `synth.analog_gen`: Waveform (Sine, Triangle, Saw, Square, Noise), Unison 1-4, Detune, Cutoff 40-18000 Hz, Resonance 0-0.95, Attack/Decay/Release in **seconds**, Sustain 0-1.
- `synth.fm_synth`: Algorithm, Feedback, Op1-Op5 Ratio and Level, Attack/Decay/Release in **milliseconds**, Sustain.
- `synth.spectravoice`: Profile (Organ, Brass, Choir, Bell), Bandwidth, Attack/Release in ms.
- `synth.drumsynth`: Kit Decay, Tone, Snappy, Pan Spread, Master Vol.
- `synth.kicker`: Waveform, Pitch Start, Pitch End, Sweep Time, Decay, Click Drive.
- `synth.sampler`: load audio with `sample`.

Check units: `Release=280` on an FM synth is 280 ms; on an Analog Generator the range is 0.005 to 8 seconds, so `Release=280` is an error.

### 6.2 Effects and wiring

Effects are modules with an audio input and output. Chain them with `connect`: `source -> effect -> out`. `Dry` and `Wet` set how much of the plain and the effected signal an effect passes. An effect with `Dry` near 1 and a small `Wet` works as an insert; you can also send one source to two places (dry to a bus, a little to a reverb).

- Delay times are in ms by default (`Unit=ms`). A beat lasts `60000 / bpm` ms. At 104 bpm an eighth is 288.5 ms and a dotted eighth 432.7 ms; neon_drift uses exactly these.
- Compressor sidechain: `connect kit bus_comp to=Sidechain gain=0.45` makes the compressor react to the drums (pumping). The kit also goes into the normal input.
- Event processors (`ctl.multisynth`, `ctl.glide`, ...) sit between a part and synths: bind the part to the processor and wire `from=out to=in` (event ports) to each synth. Example: one part playing two synths:

```dcs
module layer ctl.multisynth
module a preset="Electric Piano"
module b preset="Strings"
module filt fx.filter_pro
module wob fx.lfo
set wob Frequency=0.5
connect layer a from=out to=in
connect layer b from="Events Out" to="Events In"
connect a filt gain=0.2
connect b filt gain=0.15
connect wob filt from=cvOut to=cutoffCv
connect filt out
part p module=layer
notes p: [C4 E4 G4]:4
```

- A loop of wires is refused unless it passes through a Feedback module (`ctl.feedback`).

### 6.3 Gain staging

The Master Output has a soft limiter (on by default). It starts squashing above 0.95 and never lets the output pass 1.0. A good mix peaks around 0.5 to 0.9 with an average of about 0.05 to 0.15.

Module outputs are often louder than 1, so use wire gains below 1. Peaks measured in this document's renders (the module's own output, before wire gain). They depend a lot on the material (pitch range, note overlap, chord size, release) and on parameter changes: a legato Saw Lead melody with `Cutoff=3200` measured 1.34, about twice the value below. Treat the table as a rough guide and read the module peaks of your own render:

| Module and material | Peak |
| --- | --- |
| Electric Piano, 3- and 4-note chords | 2.55 |
| Strings, triads | 1.59 |
| Saw Lead, 4-note chords | 1.63 |
| Saw Lead, single notes | 0.71 |
| Electric Bass, the neon_drift bass line | 1.92 |
| Synth Bass, single notes | 0.77 to 1.20 |
| Pluck, single notes | 0.48 |
| Warm Pad preset with Cutoff=1500, triad | 0.96 |
| Drum Kit, full groove | 0.70 to 1.06 |
| Kick (Kicker) | 0.64 |

The neon_drift mix (section 7.3), which renders at peak 0.69 and average 0.117:

| Wire | Gain |
| --- | --- |
| bass -> bus_comp | 0.35 |
| keys -> reverb | 0.18 |
| keys -> bus_comp | 0.18 |
| lead -> delay | 0.32 |
| harmony -> delay | 0.22 |
| delay -> reverb | 0.50 |
| reverb -> bus_comp | 0.55 |
| kit -> bus_comp | 0.45 |
| kit -> bus_comp (to=Sidechain) | 0.45 |
| bus_comp -> out | 0.60 |

with `delay` Dry=0.85 Wet=0.28, `reverb` Dry=0.85 Wet=0.24 Room Size 0.62, and `bus_comp` Threshold=-16 Ratio=3 Attack=12 Release=120.

Starting points when wiring straight to `out`: chord keys 0.2 to 0.3, bass 0.3 to 0.35, lead 0.3, drums 0.4 to 0.45, one solo instrument 0.6 to 0.8. These are for **each part on its own**; when bass, keys, lead and drums all play together, start about 20 to 25% lower (a test song with bass 0.3, drums 0.42, keys 0.18 into a reverb and lead 0.35 into a delay peaked at 0.955; bass 0.22, drums 0.36, keys 0.15 and lead 0.3 gave peak 0.755, average 0.129). Then render and adjust.

The report says `limiter engaged in <n> bars (...)` as soon as any output sample passes the limiter knee (0.95), and marks those bars `(limiter)`. Keep the peak below 0.9, so that the limiter stays out of the way.

### 6.4 Reusing sounds

`savemodule <handle> <path>` writes a `.msym`. `module <new> file=<path>` loads it as a new module, and `preset <handle> file=<path>` applies it to an existing one of the same type. Both work inside one script, even in `check` mode.

## 7. Worked examples

Each example was run with `check`, `run` and `render`. Run them in an empty folder: they write files named in their `save` command.

### 7.1 A four-bar idea on one instrument

```dcs
// A four-bar melody on one instrument.
project "First Idea"
tempo 100
key A minor

module lead preset="Pluck"
connect lead out gain=0.8

section idea bars=4
part melody module=lead

notes melody idea: A4:1/2 C5:1/2 E5:1 D5:1/2 C5:1/2 A4:1 \
                   G4:1/2 A4:1/2 B4:1 E4:2 \
                   A4:1/2 C5:1/2 E5:1 G5:1/2 F5:1/2 E5:1 \
                   D5:1 C5:1 A4:2

arrange idea
save "first_idea.msv"
```

Each bar adds up to 4 beats. The `\` lines are one command.

```text
$ dracker-compose run first_idea.dcs
Ran 10 commands.
Wrote first_idea.msv
$ dracker-compose render first_idea.msv -o first_idea.wav
Rendered: first_idea.wav (11.60 s, 44100 Hz, 4 bars, the arrangement once from start to end)
Levels:   peak 0.3836  average 0.0536  limiter not engaged
Silent bars: none
Bars:
  bar 1: peak 0.3829  avg 0.0663
  bar 2: peak 0.3829  avg 0.0541
  bar 3: peak 0.3836  avg 0.0663
  bar 4: peak 0.3829  avg 0.0469
Modules:
  Master Output      (core.output): peak 0.3836 (sound)
  lead               (synth.fm_synth): peak 0.4795 (sound)
```

With `gain=0.35` the same song peaked at only 0.17, so the gain was raised to 0.8.

### 7.2 Bass, keys and drums in two sections

```dcs
// Bass, keys and drums over a progression, in two sections.
project "Two Sections"
tempo 92
key E minor

module bass preset="Synth Bass"
module keys preset="Electric Piano"
module kit preset="Drum Kit"
module verb fx.reverb
set verb Dry=0.85 Wet=0.25

connect bass out gain=0.35
connect keys verb gain=0.3
connect verb out gain=0.8
connect kit out gain=0.45

section verse bars=4
section chorus bars=4

part bass module=bass
part keys module=keys
part drums drums=kit

chords keys verse voicing=close: i VI III VII
chords bass verse style=root5: i VI III VII
drums drums verse kick fill=1-4: x.......x.......
drums drums verse snare fill=1-4: ....x.......x...
drums drums verse "Closed Hat" fill=1-4: x.x.x.x.x.x.x.x.

chords keys chorus style=pulse every=1/2 voicing=close voices=4: VI VII i i
chords bass chorus style=root rhythm=x..x..x.x..x..x.: VI VII i i
drums drums chorus kick fill=1-4: x..x..x.x..x....
drums drums chorus snare fill=1-4: ....X.......X..g
drums drums chorus "Open Hat" fill=1-4: ..x...x...x...x.
drums drums chorus snare fill=4: ....X...X.X.XXXX

arrange verse chorus verse chorus
save "two_sections.msv"
```

In E minor, `i VI III VII` is Em C G D. The verse holds the chords and walks the bass between root and fifth; the chorus pulses the keys in eighths, gives the bass a syncopated rhythm and adds a snare fill in bar 4.

```text
Rendered: two_sections.wav (43.74 s, 44100 Hz, 16 bars, the arrangement once from start to end)
Levels:   peak 0.8418  average 0.1273  limiter not engaged
Silent bars: none
Bars:
  bar 1: peak 0.6154  avg 0.0756
  bar 2: peak 0.6836  avg 0.0751
  bar 3: peak 0.5573  avg 0.0799
  bar 4: peak 0.5836  avg 0.0820
  bar 5: peak 0.7516  avg 0.1440
  bar 6: peak 0.8116  avg 0.1542
  bar 7: peak 0.7593  avg 0.1422
  bar 8: peak 0.8399  avg 0.1509
  bar 9: peak 0.7169  avg 0.1080
  bar 10: peak 0.7640  avg 0.0994
  bar 11: peak 0.6577  avg 0.1010
  bar 12: peak 0.6141  avg 0.1072
  bar 13: peak 0.7613  avg 0.1604
  bar 14: peak 0.8168  avg 0.1687
  bar 15: peak 0.7608  avg 0.1598
  bar 16: peak 0.8418  avg 0.1653
Modules:
  Master Output      (core.output): peak 0.8418 (sound)
  bass               (synth.analog_gen): peak 1.1980 (sound)
  keys               (synth.fm_synth): peak 2.5506 (sound)
  kit                (synth.drumsynth): peak 0.9387 (sound)
  verb               (fx.reverb): peak 0.6597 (sound)
```

The chorus bars (5-8, 13-16) are about twice as loud on average as the verse bars, as intended. The peak 0.84 is below the limiter knee (0.95).

#### The render report, field by field

| Field | Meaning |
| --- | --- |
| `Rendered: <wav> (<s> s, <rate> Hz, <n> bars, the arrangement once from start to end)` | The WAV written, its length in seconds, the sample rate, and the song length in bars. The render plays the arrangement once from the start to its end, then a 2-second tail for reverb and release; it does not follow the loop. The bar count is the end of the last timeline clip (or the loop end, if later), rounded up to whole bars. |
| `Loop: lines <a> to <b>, not followed by the render` | Printed only when the project has a custom loop (one that does not cover the whole song). The app plays this loop; the render ignores it. |
| `peak` | The highest sample of the whole file, after the Master Output limiter (0 to 1). |
| `average` | The RMS level of the whole file, tail included. |
| `limiter not engaged` / `limiter engaged in <n> bars (<list>)` | Engaged when some output sample passed the limiter knee (0.95), with the bars where that happened; those bars are marked `(limiter)` in the `Bars:` list. `engaged after the arrangement` means only the tail passed it. |
| `Silent bars` | Bars whose peak is at most 0.00001, or `none`. |
| `Bars:` | Peak and average (RMS) of each bar, measured by tempo from the song start; `(silent)` marks silent bars and `(limiter)` bars where the limiter worked. The tail is not listed. |
| `Modules:` | For each module: its displayed name, type, the peak of its own output (before wire gains), and `sound` or `silent` (peak above 0.00001). |

`render --json` gives the same values as `wav`, `sampleRate`, `lengthSeconds`, `totalFrames`, `arrangementBars`, `peak`, `rms`, `limiterReached` (true when the limiter engaged), `limiterBars` (array), `playback` (always `"once"`), `loop` (`start`, `end` in lines, and `followed`, always false), `silentBars` (array), `bars` (array of `bar`, `peak`, `rms`, `silent`, `limited`) and `modules` (array of `id`, `typeId`, `name`, `peak`, `producedSound`).

**On the limiter.** The limiter is soft: it begins at 0.95 and the output approaches 1.0 slowly, so the peak alone hardly shows how hard it works. A song whose input was about twice full scale rendered `peak 0.9967  average 0.2928  limiter engaged in 4 bars (1, 2, 3, 4)`. When the report says `engaged`, lower the gains.

### 7.3 A full arrangement: neon_drift

This is `sample-projects/neon_drift.dcs`, the owner-approved model song. Here the file paths are changed to plain file names so the script writes into the current folder (the original writes into `sample-projects/`).

```dcs
project "Neon Drift"
tempo 104
signature 4/4
key D minor

module bass preset="Electric Bass"
module keys preset="Electric Piano"
set keys Release=280

module lead synth.analog_gen name="Neon Lead"
set lead Waveform=saw Unison=2 Detune=0.18 Cutoff=2600 Resonance=0.25 Attack=0.01 Decay=0.25 Sustain=0.6 Release=0.18
savemodule lead "neon_drift_lead.msym"

module harmony file="neon_drift_lead.msym" name="Neon Harmony"
set harmony Cutoff=1600 Release=0.3

module kit preset="Drum Kit"
set kit Snappy=0.65
set kit "Pan Spread" 0.45

module delay fx.delay
set delay Dry=0.85 Wet=0.28
set delay "Delay L" 288.5
set delay "Delay R" 432.7

module reverb fx.reverb
set reverb Dry=0.85 Wet=0.24
set reverb "Room Size" 0.62
set reverb Damping=6000

module bus_comp fx.compressor
set bus_comp Threshold=-16 Ratio=3 Attack=12 Release=120

connect bass bus_comp gain=0.35
connect keys reverb gain=0.18
connect keys bus_comp gain=0.18
connect lead delay gain=0.32
connect harmony delay gain=0.22
connect delay reverb gain=0.50
connect reverb bus_comp gain=0.55
connect kit bus_comp gain=0.45
connect kit bus_comp to=Sidechain gain=0.45
connect bus_comp out gain=0.60

section intro bars=4
section verse bars=4
section chorus bars=4
section outro bars=4

part bass module=bass
part keys module=keys
part lead module=lead
part harmony module=harmony
part drums drums=kit

chords keys intro style=hold voicing=close voices=4: i VI III VII
chords bass intro style=root octave=2: i VI III VII
notes harmony intro at=3: D4:2 F4:2 C4:2 E4:2
drums drums intro "Closed Hat" fill=1-4: x.x.x.x.x.x.x.x.
drums drums intro kick fill=3-4: x.......x.......
drums drums intro snare fill=4: ....X...x.x.X.X.

chords keys verse style=hold rhythm=X.x.x.x.X.x.x..x voicing=close: i VI III VII
chords bass verse style=root5 octave=2: i VI III VII
notes lead verse: A4:1 F4:1 D4:2 Bb4:1 A4:1 G4:2 C5:1 G4:1 E4:2 A4:2 G4:2
notes harmony verse: F4:2 D4:2 F4:2 D4:2 G4:2 E4:2 E4:2 C4:2
drums drums verse kick fill=1-4: x..x..x...x.....
drums drums verse snare fill=1-4: ....X.......X...
drums drums verse "Closed Hat" fill=1-4: x.x.x.x.x.x.X.x.

chords keys chorus style=arp dir=updown every=1/4 voicing=close: i VI III VII
chords bass chorus style=root rhythm=X..x..x...x.X... octave=2: i VI III VII
notes lead chorus: D5:1 F5:1/2 E5:1/2 D5:2 F5:1 D5:1 Bb4:2 E5:1 G5:1/2 F5:1/2 E5:2 G5:2 E5:2
copy lead chorus from=1 len=4b to=1 part=harmony section=chorus
transpose harmony chorus from=1 len=4b steps=-2
drums drums chorus kick fill=1-4: x..x..x.x..x..x.
drums drums chorus snare fill=1-4: ....X.......X...
drums drums chorus "Open Hat" fill=1-4: ..x...x...x...x.
drums drums chorus snare fill=4: ....X..xx.X.XXXX

chords keys outro style=hold voicing=close: i VI VII i
chords bass outro style=root octave=2: i VI VII i
notes lead outro: A4:2 D4:2 Bb4:2 F4:2 G4:2 E4:2 D4:4
notes harmony outro at=1: F4:4
drums drums outro kick fill=1-2: x.......x.......
drums drums outro "Closed Hat" fill=1-2: x...x...x...x...

arrange intro verse chorus outro
loop verse chorus
save "neon_drift.msv"
```

How it is built:

- **Sound design.** Presets for bass, keys and drums; a custom saw lead saved with `savemodule` and loaded again as a darker harmony (`Cutoff=1600`). Lead and harmony feed a tempo-synced delay, the delay and keys feed a reverb, and everything meets in a compressor bus that the kit also drives through its sidechain.
- **Form.** Four 4-bar sections over one progression (`i VI III VII` = Dm Bb F C). Each section changes the playing style, not the harmony: held 4-voice chords in the intro, a rhythmic comp in the verse, a sixteenth arpeggio in the chorus, plain held chords in the outro.
- **Bass.** Whole notes in the intro, root-fifth in the verse, a syncopated root rhythm in the chorus.
- **Melody.** The lead enters in the verse (every bar adds up to 4 beats). In the chorus the lead melody is copied to the harmony part and moved two scale steps down, a diatonic third below.
- **Drums.** The intro builds (hats only, kick from bar 3, a snare pickup in bar 4). The verse and chorus have their own grooves; the chorus ends with a snare fill written over bar 4.
- **Ending.** The outro thins out and ends on `i`; the last lead note is 4 beats long.

Render report:

```text
Rendered: neon_drift.wav (38.92 s, 44100 Hz, 16 bars, the arrangement once from start to end)
Loop:     lines 64 to 192, not followed by the render
Levels:   peak 0.6484  average 0.1070  limiter not engaged
Silent bars: none
Bars:
  bar 1: peak 0.4229  avg 0.0691
  bar 2: peak 0.4418  avg 0.0683
  bar 3: peak 0.5240  avg 0.0730
  bar 4: peak 0.5670  avg 0.0774
  bar 5: peak 0.5457  avg 0.1213
  bar 6: peak 0.6484  avg 0.1190
  bar 7: peak 0.6269  avg 0.1276
  bar 8: peak 0.6199  avg 0.1230
  bar 9: peak 0.5314  avg 0.1264
  bar 10: peak 0.5004  avg 0.1264
  bar 11: peak 0.6188  avg 0.1276
  bar 12: peak 0.5125  avg 0.1306
  bar 13: peak 0.4839  avg 0.1192
  bar 14: peak 0.5723  avg 0.1176
  bar 15: peak 0.4420  avg 0.0841
  bar 16: peak 0.3504  avg 0.0798
Modules:
  Master Output      (core.output): peak 0.6484 (sound)
  bass               (synth.analog_gen): peak 1.9214 (sound)
  keys               (synth.fm_synth): peak 2.5619 (sound)
  Neon Lead          (synth.analog_gen): peak 0.9299 (sound)
  Neon Harmony       (synth.analog_gen): peak 0.9548 (sound)
  kit                (synth.drumsynth): peak 1.0644 (sound)
  delay              (fx.delay): peak 0.3151 (sound)
  reverb             (fx.reverb): peak 0.4616 (sound)
  bus_comp           (fx.compressor): peak 1.0806 (sound)
```

The modules `lead` and `harmony` are listed under their displayed names because the script gave `name=`.

The song has `loop verse chorus`, so the app loops lines 64 to 192 when it plays. The render ignores the loop and plays intro, verse, chorus and outro once: the outro bars 15 and 16 fall to an average of 0.0841 and 0.0798 as the arrangement thins out.

## 8. Reading the report and fixing problems

| Symptom in the report | Likely cause | Fix |
| --- | --- | --- |
| Every bar silent; the synth's module line says `sound`; Master Output `silent` | The synth has no audio path to `out`. | `connect <synth> out gain=...` (or through effects to `out`). |
| Every bar silent; every module `silent`; the script has `section` commands | No `arrange`. Sections exist but are not on the timeline (`check` warns about it). | Add `arrange <sections...>`. |
| One part's module `silent` | Its notes are in a section that is not arranged; it was bound to the wrong module; or it is an event processor chain with a missing event wire. | Check `part ... module=`, `arrange`, and `connect ... from=out to=in`. |
| An effect `silent` although its source makes sound | The source is not wired into the effect, or the effect is not wired onward. | Check both wires. |
| Some bars silent where music was meant | Notes written at the wrong `at=`, or the part has no music in that section (a gap). | Positions count from the section start. Use `describe` to see what was written. |
| `limiter engaged in ...` | Too much gain; the limiter is squashing. | Lower wire gains, starting with the loudest module in the Modules list; or lower the bus wire to `out`. |
| Peak below 0.2 | Too little gain. | Raise the wire gains to `out`. |
| The song is shorter than expected | Sections missing from `arrange` (the warning `section '...' has notes but is not arranged` says which). | Check `Rendered: ... <n> bars` against the planned bar count. |
| The tempo feels doubled or halved | `tpl=` was changed. | Use `tempo <bpm>` with the default `tpl=6`. |

To inspect what the script actually wrote, run `describe` on the `.msv`. It prints every part's notes per section with explicit lengths (and turns presets back into parameter lists).

### Real error examples

A note that runs past the section end (one bar = 4 beats; `C4:2 D4:2 E4:1` is 5 beats):

```dcs-bad
module lead preset="Pluck"
section a bars=1
part m module=lead
notes m a: C4:2 D4:2 E4:1
```

```text
dracker-compose: line 4, col 22: note runs past the end of section 'a'; the nearest valid value is 1.4
```

A section name forgotten while sections exist:

```dcs-bad
module lead preset="Pluck"
section a bars=1
part m module=lead
notes m: C4
```

```text
dracker-compose: line 4, col 7: a section is needed here, because the song has sections (a); write the section after the part name
```

A script that checks fine but renders silence because the module is not wired:

```dcs
module lead preset="Pluck"
section a bars=1
part m module=lead
notes m a: C4 E4 G4 C5
arrange a
```

```text
Rendered: e_silent.wav (3.92 s, 44100 Hz, 1 bars, the arrangement once from start to end)
Levels:   peak 0.0000  average 0.0000  limiter not engaged
Silent bars: 1
Bars:
  bar 1: peak 0.0000  avg 0.0000 (silent)
Modules:
  Master Output      (core.output): peak 0.0000 (silent)
  lead               (synth.fm_synth): peak 0.4786 (sound)
```

## 9. Limits

### What the module writer cannot do

- Drawn waveforms and curves: the Analog Generator `Drawn` waveform data and the WaveShaper curve cannot be drawn from a script.
- Envelope editors (drawn envelopes) cannot be edited.
- MetaModules cannot be built from a nested project.
- A preset or kept module that already holds such data is kept intact when loaded and saved (`file=`, `preset=`, `keep=`).

### What `describe` keeps opaque

- Modules with extra data (Sampler samples, drawn data, MetaModule children) are printed as `module <h> keep="<file.msv>:<id>"` (or `keep="<file.msym>"` for a preset). The path is the one given to `describe`, so run the described script from the same folder.
- Patterns that are not exactly what `notes` and `drums` would write are printed as `cells` commands.
- A timeline that is not a plain list of sections is printed as `arrange clip=#<id> ...` commands and a `loop start= end=`. A part that does not play in every arranged section (a gap, for example a lead that starts after the intro) does not count, and neither does declaring the parts in another order than you wrote their notes: those still print as `arrange <sections>`. What counts: clips added with `arrange clip=`, and a section with no music in any part (the file does not store empty sections, so that stretch becomes a gap between clips). The printed script is longer but writes the same file. In this output `section` commands and `arrange clip=` lines appear together: that is safe here because the `section` lines only declare the sections the clips' patterns belong to, and no `arrange <sections>` line follows.
- `describe` prints melodic parts in the order of their timeline lanes (the order the script declared them, for an arranged song) and writes each drum lane as one step string over the whole section, with leading rests turned into `at=`, instead of `fill=` ranges.
- `open` keeps everything it does not understand (module extra data, MetaModule children, MIDI mappings) unchanged.
- Patterns made in the app have no part or section names; `describe` and `open` invent them from pattern and module names (and from displayed names for handles).

### The one-note-per-track rule

Each tracker track plays one note at a time; a new note on a track ends the previous one. `notes` and `chords` hide this: overlapping notes go to new tracks (at most 64 per pattern: `too many simultaneous notes at <pos> (limit is 64 tracks)`), each note gets a note-off at its end, and same-pitch overlaps are refused. Drum lanes are one track each.

**A note that lasts to the very end of its section gets no note-off** (the note-off would fall on the line after the pattern), so it keeps sounding until a later note on the same track replaces it. When the next section of that part starts with a note on the same track, nothing is heard; but in a gap (a following section where the part does not play) and in the 2-second tail after the song, the note holds at full level. Tested: `notes mel a: C4:4` in a 1-bar section followed by an empty 2-bar section rendered bars 2 and 3 at average 0.094, while `C4:1` left them silent. To end a part cleanly before a gap or at the end of the song, make its last note end at least one line early: `C4:15l` instead of `C4:4` in a 16-line bar (tested: bar 2 then only carries the release, average 0.007, and bar 3 is silent). This is task T120.

### Numeric limits

| Item | Limit |
| --- | --- |
| Modules per project | 1024 (the Master Output counts) |
| Wires | 8192 |
| Patterns | 256 in total: one per (part, section) pair played, plus drum patterns, plus raw patterns |
| Tracks per pattern | 64 |
| Lines per pattern (one section) | 4096 (256 bars of 4/4) |
| Timeline clips | 4096 |
| Drum lanes per drum part | 64 |
| Handle | 32 characters: letter first, then letters, digits, `_`, `-` |
| Part, section, drum part name | 64 bytes |
| Title | 65536 bytes |
| Tempo | 20 to 999 bpm; `tpl` 1 to 255 |
| Time signature | numerator 1 to 16; denominator 2, 4, 8 or 16 |
| Pitch | C-1 (0) to G9 (127) |
| Velocity | above 0, at most 1 (at most 3 digits before and 6 after the dot in notes) |
| Sampler | slots 0 to 15; module data at most 64 MiB |
| Shortest note or step | one line (a sixteenth in x/4) |

Other rules found in the code:

- `run` and `check` stop at the first failing command.
- Use either the implicit section or named sections, not both.
- Key modes are only major and minor.
- Notes, chords and drum steps are always inside one section; nothing crosses a section boundary.
- `render` plays the arrangement once and ignores the loop; the app plays the loop (section 4.4).

## 10. Cheat sheet

```text
dracker-compose check s.dcs | run s.dcs [-o s.msv] | render s.msv -o s.wav | describe f.msv|f.msym
dracker-compose catalog [modules|presets|chords|progressions|keys|commands|<type id>]   --json anywhere
exit: 0 ok, 1 script/file error, 2 usage

SYNTAX   one command per line; // comment; \ at end continues; "quoted text"; name=value
         names, options, params, handles: case and spaces ignored
TIME     1 line = 1/16 note; 4/4 bar = 16 lines; tempo in quarter notes (tpl=6)
         position bar[.beat[.sixteenth]] from 1, inside the section
         length 1 (beat) 1/2 (half beat) 2b (bars) 3l (lines); pattern <= 4096 lines

project "T" | title "T" | tempo 120 [tpl=6] | signature 3/4 | key A minor | open "f.msv" (first)
module h <type>|preset="Name"|file=p.msym|keep=f.msv:id [name="Shown"] [x= y=]
set h Param=V Param2=V | set h "Param Name" V          (range errors, Waveform=Saw)
preset h "Name" | preset h file=p.msym | sample h a.wav [slot=0 root=C4 low=0 high=127]
savemodule h p.msym | remove h
connect a b [gain=1] [from=port] [to=port]   (to=Sidechain; events need from=out to=in)
disconnect a b [from=] [to=]

section name bars=4
part p module=h | part d drums=kitHandle
notes p sec [at=pos]: C4:1 D4:1/2@0.6 - [C4 E4 G4]:2      (lengths carry, vel 0.8 default)
chords p sec [style=hold|pulse|arp|root|root5] [octave=4] [voices=3|4] [voicing=root|close]
             [every=1] [dir=up|down|updown] [rhythm=x.x.X...] [vel=0.8] [at=]: i VI III:2 VII:1/2
chords p sec preset="Minor pop" [options]           (chord lengths are BARS)
drums d sec lane [at=] [fill=1-4] [vel=0.8 accent=1 ghost=0.45]: x...X...g..x-...
drums d lane=Name module=h note=C2
cells p sec line=0|at=pos [track=0] note=C4|off [vel=] [module=] [fx= fxval=] [param= val=]
copy p sec from=1 len=2b to=3 [part=q] [section=s]
repeat p sec [from=1] len=1b times=3
transpose p sec [from=1] [len=..] by=12|steps=-2
clear p sec [from=1] [len=..]
arrange intro verse chorus verse          (required when sections exist)
loop verse chorus | loop all | loop start=0 end=64   (the app plays it; render ignores it)
save "song.msv"

DRUM LANES (DrumSynth)  Kick 36, Snare 38, Closed Hat 42, Open Hat 46, Low Tom 43, High Tom 48, Perc 39
STEPS   x o hit, X O ! accent, g ghost, - . rest (clears), space | ignored; 1 char = 1 line
ROMAN   I..VII major, i..vii minor, b/# prefix; I7 Imaj7 I+ Isus4 / i7 i° i°7 iø
GAINS   keys chords 0.2-0.3, bass 0.3-0.35, lead 0.3, drums 0.4-0.45, solo 0.6-0.8
TARGET  peak 0.5-0.9 (>0.95 = limiting), average ~0.05-0.15, Silent bars: none
SILENCE no connect to out | no arrange | part bound to wrong module
```
