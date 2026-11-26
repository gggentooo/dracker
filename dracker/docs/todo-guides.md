# Dracker Task Guides

> **Generated file. Do not edit it.** `tools/todo.py` writes this file from `docs/todo.json` (`agents.md` Rule 6). Change a guide with `python3 tools/todo.py guide T00 --author "<name>" --text @file`.

A guide says what to write for one task and how: what to read first, the existing code to call (with exact signatures), the new code, the order of the steps, an acceptance table with worked values, and the tests. It was written by reading the code as it was on the date shown; if the code no longer matches the guide, stop and tell the owner instead of guessing. To get one task with everything it rests on, run `python3 tools/todo.py brief T00`.

Only open tasks are listed, in stage order. A task without a guide is named at the end.

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

T77 (Stage 0), T83 (Stage 0), T96 (Stage 0), T115 (Stage 0), T86 (Stage 1), T79 (Stage 1), T82 (Stage 1), T85 (Stage 1), T97 (Stage 1), T98 (Stage 1), T101 (Stage 1), T102 (Stage 1), T112 (Stage 1), T78 (Stage 2), T80 (Stage 2), T81 (Stage 2), T100 (Stage 2), T103 (Stage 2), T104 (Stage 2), T87 (Stage 3), T99 (Stage 3), T106 (Stage 3), T105 (Stage 4), T107 (Stage 5), T113 (Stage 5), T88 (Stage 6), T114 (Stage 6), T89 (Stage 7).

A guide is written when the tasks it needs are built, so that it can name real functions.
