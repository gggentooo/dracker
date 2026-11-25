/**
 * File:         source/gui/views/pattern_editor.d
 * Module:       gui.views.pattern_editor
 * Phase:        Phase 8.4 — High-Density Tracker Pattern Grid Editor
 *
 * Purpose:
 *   Renders and edits the current pattern (StudioContext.currentPattern()) as a high-density tracker grid with a
 *   line-number gutter (hex or decimal, beat/bar rows highlighted by the project's time signature: beatLines() /
 *   barLines() read StudioSession.linesPerBeat() / linesPerBar()), color-coded track headers and per-cell
 *   `NNN VV MM CCEE XXYY` columns, plus a header strip (pattern dropdown, track/line drag boxes, Add/Duplicate/
 *   Delete pattern buttons). Supports keyboard/mouse cursor navigation over 13 sub-fields, rectangular block
 *   selection (mouse drag or Shift+arrows), QWERTY note entry with live audition, hex nibble editing, note-off and
 *   delete entry, live MIDI recording at the playhead or step recording at the cursor, block cut/copy/paste
 *   (Dracker-Block-v1 clipboard text), transpose, interpolate, and follow-playhead scrolling. Double-clicking the
 *   pattern dropdown opens an in-place TextField that renames the current pattern (beginRenamePattern()). Double-clicking a row
 *   puts the cursor on that row's note field and turns edit mode on. Notes are never written for the
 *   Master Output module (core.output): note entry is refused with a status message instead.
 *
 *   Column mapping (faithful to the 8-byte NoteCell):
 *     NNN  = note: "---" empty, "===" note-off, otherwise C-4 style from the stored MIDI+1 value (octave -1 is
 *            shown as '-', other NoteCmd values as AOF/PRV/PIT/STP).
 *     VV   = velocity shown 00..80 hex: display = round((raw - 1) * 128 / 254), raw 0 (engine default) is "..".
 *     MM   = module id low byte (".." when 0).
 *     CC   = paramId low byte (the stored 1-based controller index, ".." when paramId is 0).
 *     EE   = effect code (".." when 0).
 *     XXYY = XX is the paramId high byte (extended controller page, normally 00) and YY is effectVal; the pair is
 *            "...." when paramId, effect and effectVal are all 0.
 *   Phase 8.5 (Accessible Appearance): each row gets exactly one tint (playhead > cursor row > bar > beat) so
 *   tracker text keeps its contrast target; the cursor field and selection carry their state with 2 pt outlines,
 *   bar rows add a 1 pt rule and the playhead row a left edge marker.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Reads the document through ctx.session.document() on every call (never retains pointers or
 *   slices across frames). Every mutation goes through StudioSession: single cells via doPatchCell (one undo step
 *   each) and every block operation via one doReplacePatternCells (one undo step). Drawing touches only visible
 *   rows and tracks and allocates nothing per cell.
 *
 * Dependencies:
 *   Internal: app.keymap, app.pattern_ops, app.session, foundation.types, gui.renderer, gui.theme, gui.widgets,
 *             gui.views.studio_context, io.project_format, platform.interfaces, sequencer.note
 *   External: std.format (format), std.math (ceil, floor)
 *
 *   T43 (pattern editor views): a view bar above the header offers Tracker, Piano roll and Drumpad. The tracker
 *   grid is built into this class; the other views are widgets registered with registerView() that fill
 *   viewRect() while current. A view is enabled when the pattern's type offers it (normal: Tracker + Piano roll;
 *   drum: Drumpad + Tracker) and, for the two others, a widget is registered. The chosen view is remembered per
 *   pattern for this run. While another view is current the tracker ignores mouse, keys, MIDI step entry and its
 *   context menu, and studio actions go to the view when it implements StudioCommandSink. The Trk box is shown
 *   in the Tracker view only.
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum PatternViewKind; class ViewTabButton : Button (lit); PatternEditorView.registerView(), viewOffered(),
 *     viewAvailable(), currentView(), setView(), viewRect(), viewButtons
 *   - enum PatternField / PATTERN_FIELD_COUNT / CELL_TEXT_COLUMNS
 *   - struct CellText; CellText formatCell(NoteCell); string formatCellText(NoteCell); formatNoteName()
 *   - uint velocityToDisplay(ubyte) / ubyte velocityFromDisplay(uint)
 *   - NoteCell setFieldNibble(NoteCell, uint field, uint nibble) / NoteCell clearField(NoteCell, uint field)
 *   - int hexNibbleForKey(uint keyCode)
 *   - class PatternDimensionBox : NumericDragBox (commits once per drag gesture)
 *   - class PatternEditorView : Widget, StudioCommandSink — this(StudioContext), update(), handleStudioAction(),
 *     setCursor(), cellRect(), fieldRect(), cursorTrack(), cursorLine(), cursorField(), hasSelection(),
 *     selection(), scrollLine(), scrollTrack(), visibleLineCount(), playheadLocalLine(), localLineForSongLine()
 *   - Widget ids: "pattern.editor", "pattern.select", "pattern.tracks", "pattern.lines", "pattern.add",
 *     "pattern.duplicate", "pattern.delete"
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.views.pattern_editor;

import std.format : format;
import std.math : ceil, floor;

import app.keymap : isDocumentLevel, StudioAction, StudioCommandSink;
import app.pattern_ops : clearRegion, decodeBlockText, encodeBlockText, extractBlock, InterpolateField,
    interpolateColumn, PatternBlock, transposeBlock, writeBlockInto;
import app.session : MidiNoteEvent;
import foundation.types : ModuleId;
import gui.renderer : ColorRGBA, FontId, IRenderer2D, ITextMeasurer, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.views.drumpad_view : DrumpadView;
import gui.views.piano_roll_view : PianoRollView;
import gui.views.studio_context : StudioContext;
import gui.widgets : Button, Dropdown, KeyCode, KeyEvent, lineHeightOr, measureTextOr, MenuItem, MouseButton,
    MouseEvent, NumericDragBox, openTextEditor, ScrollEvent, TextField, ValueRange, Widget;
import io.project_format : MAX_PATTERNS, PATTERN_KIND_DRUM, SavedPattern;
import platform.interfaces : KeyModifiers, PlatformEvent, PlatformEventKind;
import sequencer.note : NoteCell, NoteCmd;

/**
 * Cursor sub-fields of one tracker cell, in left-to-right order.
 */
enum PatternField : uint {
    note = 0,
    velocityHi = 1,
    velocityLo = 2,
    moduleHi = 3,
    moduleLo = 4,
    controllerHi = 5,
    controllerLo = 6,
    effectHi = 7,
    effectLo = 8,
    xxHi = 9,
    xxLo = 10,
    yyHi = 11,
    yyLo = 12
}

enum uint PATTERN_FIELD_COUNT = 13;

enum uint CELL_TEXT_COLUMNS = 19;

enum string MASTER_OUTPUT_TYPE_ID = "core.output";

enum string MASTER_OUTPUT_BLOCKED_STATUS = "Master Output can't play notes; select an instrument module";

private immutable uint[PATTERN_FIELD_COUNT] FIELD_CHAR = [0, 4, 5, 7, 8, 10, 11, 12, 13, 15, 16, 17, 18];

private immutable uint[CELL_TEXT_COLUMNS] CHAR_FIELD = [0, 0, 0, 0, 1, 2, 2, 3, 4, 4, 5, 6, 7, 8, 8, 9, 10, 11, 12];

private immutable char[16] HEX = "0123456789ABCDEF";

private immutable char[2][12] NOTE_NAMES = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"];

private immutable uint[16] HEX_KEYCODES = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25, 0, 11, 8, 2, 14, 3];

/**
 * Fixed-width text of every column of one cell plus per-column emptiness flags.
 */
struct CellText {
    char[3] note = "---";
    char[2] velocity = "..";
    char[2] moduleId = "..";
    char[2] controller = "..";
    char[2] effect = "..";
    char[4] value = "....";
    bool noteEmpty = true;
    bool velocityEmpty = true;
    bool moduleEmpty = true;
    bool controllerEmpty = true;
    bool effectEmpty = true;
    bool valueEmpty = true;
}

/**
 * Writes v as dst.length upper-case hex digits (most significant first).
 *
 * Params:
 *   dst = Destination characters.
 *   v = Value.
 */
private void putHex(char[] dst, uint v) @safe @nogc nothrow pure {
    foreach_reverse (i; 0 .. dst.length) {
        dst[i] = HEX[v & 0xF];
        v >>= 4;
    }
}

/**
 * Writes v as dst.length zero-padded decimal digits.
 *
 * Params:
 *   dst = Destination characters.
 *   v = Value.
 */
private void putDec(char[] dst, uint v) @safe @nogc nothrow pure {
    foreach_reverse (i; 0 .. dst.length) {
        dst[i] = cast(char)('0' + v % 10);
        v /= 10;
    }
}

/**
 * Formats a stored NoteCell.note value as three tracker characters.
 *
 * Params:
 *   note = Stored note byte (0 empty, 1..128 = MIDI + 1, NoteCmd values otherwise).
 *
 * Returns:
 *   "---", "===", "C-4"-style names (octave -1 shown as '-'), or AOF/PRV/PIT/STP/??? for other commands.
 */
char[3] formatNoteName(ubyte note) @safe @nogc nothrow pure {
    char[3] o = "---";
    if (note == NoteCmd.empty) {
        return o;
    }
    if (note >= 1 && note <= 128) {
        immutable uint midi = note - 1u;
        o[0 .. 2] = NOTE_NAMES[midi % 12];
        immutable int octave = cast(int)(midi / 12) - 1;
        o[2] = octave < 0 ? '-' : cast(char)('0' + octave);
        return o;
    }
    switch (note) {
        case NoteCmd.noteOff:
            o = "===";
            break;
        case NoteCmd.allNotesOff:
            o = "AOF";
            break;
        case NoteCmd.prevTrack:
            o = "PRV";
            break;
        case NoteCmd.setPitch:
            o = "PIT";
            break;
        case NoteCmd.stopSong:
            o = "STP";
            break;
        default:
            o = "???";
            break;
    }
    return o;
}

/**
 * Converts a stored velocity byte to the 00..80 display scale.
 *
 * Params:
 *   raw = NoteCell.velocity (1..255 = 0..1; 0 = engine default, displayed empty).
 *
 * Returns:
 *   Display value 0..128 (0 for raw 0 and 1).
 */
uint velocityToDisplay(ubyte raw) @safe @nogc nothrow pure {
    if (raw == 0) {
        return 0;
    }
    return ((raw - 1u) * 128u + 127u) / 254u;
}

/**
 * Converts a 00..80 display velocity back to the stored byte (exact inverse of velocityToDisplay).
 *
 * Params:
 *   display = Display value (clamped to 0..128).
 *
 * Returns:
 *   Stored velocity byte 1..255.
 */
ubyte velocityFromDisplay(uint display) @safe @nogc nothrow pure {
    immutable uint d = display > 128 ? 128 : display;
    return cast(ubyte)((d * 254u + 64u) / 128u + 1u);
}

/**
 * Formats every column of a cell.
 *
 * Params:
 *   c = Cell.
 *
 * Returns:
 *   Column text and emptiness flags.
 */
CellText formatCell(NoteCell c) @safe @nogc nothrow pure {
    CellText t;
    t.note = formatNoteName(c.note);
    t.noteEmpty = c.note == NoteCmd.empty;
    if (c.velocity != 0) {
        putHex(t.velocity[], velocityToDisplay(c.velocity));
        t.velocityEmpty = false;
    }
    if (c.moduleId != 0) {
        putHex(t.moduleId[], c.moduleId & 0xFF);
        t.moduleEmpty = false;
    }
    if (c.paramId != 0) {
        putHex(t.controller[], c.paramId & 0xFF);
        t.controllerEmpty = false;
    }
    if (c.effect != 0) {
        putHex(t.effect[], c.effect);
        t.effectEmpty = false;
    }
    if (c.paramId != 0 || c.effect != 0 || c.effectVal != 0) {
        putHex(t.value[], ((c.paramId >> 8) << 8) | c.effectVal);
        t.valueEmpty = false;
    }
    return t;
}

/**
 * Formats a cell as the 19-character `NNN VV MM CCEE XXYY` string.
 *
 * Params:
 *   c = Cell.
 *
 * Returns:
 *   Display string.
 */
string formatCellText(NoteCell c) @safe nothrow pure {
    immutable CellText t = formatCell(c);
    char[CELL_TEXT_COLUMNS] s = ' ';
    s[0 .. 3] = t.note[];
    s[4 .. 6] = t.velocity[];
    s[7 .. 9] = t.moduleId[];
    s[10 .. 12] = t.controller[];
    s[12 .. 14] = t.effect[];
    s[15 .. 19] = t.value[];
    return s.idup;
}

/**
 * Maps a sub-field to its byte group (0 note, 1 velocity, 2 module, 3 controller, 4 effect, 5 XX, 6 YY).
 *
 * Params:
 *   field = PatternField index.
 *
 * Returns:
 *   Group index.
 */
uint fieldGroup(uint field) @safe @nogc nothrow pure {
    return field == 0 ? 0 : (field + 1) / 2;
}

/**
 * Replaces one hex nibble of a cell field (velocity in display units, clamped to 80).
 *
 * Params:
 *   c = Source cell.
 *   field = Hex PatternField (1..12); the note field returns c unchanged.
 *   nibble = New nibble 0..15.
 *
 * Returns:
 *   Edited cell.
 */
NoteCell setFieldNibble(NoteCell c, uint field, uint nibble) @safe @nogc nothrow pure {
    if (field == 0 || field >= PATTERN_FIELD_COUNT) {
        return c;
    }
    immutable bool hi = (field % 2) == 1;
    immutable uint n = nibble & 0xF;
    uint apply(uint old) {
        return hi ? ((old & 0x0F) | (n << 4)) : ((old & 0xF0) | n);
    }
    switch (fieldGroup(field)) {
        case 1:
            c.velocity = velocityFromDisplay(apply(c.velocity == 0 ? 0 : velocityToDisplay(c.velocity)));
            break;
        case 2:
            c.moduleId = cast(ushort)((c.moduleId & 0xFF00) | apply(c.moduleId & 0xFF));
            break;
        case 3:
            c.paramId = cast(ushort)((c.paramId & 0xFF00) | apply(c.paramId & 0xFF));
            break;
        case 4:
            c.effect = cast(ubyte) apply(c.effect);
            break;
        case 5:
            c.paramId = cast(ushort)((apply(c.paramId >> 8) << 8) | (c.paramId & 0xFF));
            break;
        case 6:
            c.effectVal = cast(ubyte) apply(c.effectVal);
            break;
        default:
            break;
    }
    return c;
}

/**
 * Clears the column under a sub-field (the note field clears the whole cell).
 *
 * Params:
 *   c = Source cell.
 *   field = PatternField index.
 *
 * Returns:
 *   Edited cell.
 */
NoteCell clearField(NoteCell c, uint field) @safe @nogc nothrow pure {
    switch (fieldGroup(field)) {
        case 1:
            c.velocity = 0;
            break;
        case 2:
            c.moduleId = 0;
            break;
        case 3:
            c.paramId = cast(ushort)(c.paramId & 0xFF00);
            break;
        case 4:
            c.effect = 0;
            break;
        case 5:
            c.paramId = cast(ushort)(c.paramId & 0x00FF);
            break;
        case 6:
            c.effectVal = 0;
            break;
        default:
            c = NoteCell.init;
            break;
    }
    return c;
}

/**
 * Maps a macOS virtual key code of a hex digit key (0-9, A-F) to its nibble.
 *
 * Params:
 *   keyCode = Virtual key code.
 *
 * Returns:
 *   Nibble 0..15, or -1 when the key is not a hex digit.
 */
int hexNibbleForKey(uint keyCode) @safe @nogc nothrow pure {
    foreach (i, k; HEX_KEYCODES) {
        if (k == keyCode) {
            return cast(int) i;
        }
    }
    return -1;
}

/**
 * Integer drag box that reports a value once per gesture: changes during a mouse drag are held until release;
 * keyboard steps and typed values commit immediately.
 */
final class PatternDimensionBox : NumericDragBox {
    void delegate(uint) onCommit;
    private bool pending_ = false;
    private uint pendingValue_ = 0;

    /**
     * Creates the box.
     *
     * Params:
     *   ident = Widget id.
     *   r = Integer value range (step 1).
     */
    this(string ident, ValueRange r) {
        super(r, 0);
        id = ident;
        pixelsPerStep = 6.0f;
        onChange = &changed;
    }

    /**
     * Reports whether a drag result is waiting for release.
     *
     * Returns:
     *   True while a dragged value is pending.
     */
    bool hasPending() const {
        return pending_;
    }

    /**
     * Ends a drag and commits the pending value.
     *
     * Params:
     *   e = Mouse event.
     *
     * Returns:
     *   True.
     */
    override bool onMouseUp(const ref MouseEvent e) {
        immutable bool r = super.onMouseUp(e);
        flush();
        return r;
    }

    /**
     * Commits a pending drag value when capture is lost.
     */
    override void onCaptureLost() {
        super.onCaptureLost();
        flush();
    }

    private void changed(float v) {
        immutable uint n = cast(uint)(v + 0.5f);
        if (isDragging()) {
            pending_ = true;
            pendingValue_ = n;
            return;
        }
        commit(n);
    }

    private void flush() {
        if (pending_) {
            pending_ = false;
            commit(pendingValue_);
        }
    }

    private void commit(uint n) {
        if (onCommit !is null) {
            onCommit(n);
        }
    }
}

/**
 * Tracker pattern grid editor for ctx.currentPattern().
 */
/**
 * The views the pattern editor can show (T30). Tracker is built into PatternEditorView; the other two are
 * widgets registered with PatternEditorView.registerView().
 */
enum PatternViewKind : ubyte {
    tracker = 0,
    pianoRoll = 1,
    drumpad = 2
}

/**
 * Button of the pattern editor's view bar; the current view's button is lit: a 2-point outline and a bar under
 * the caption, so the state does not rely on color.
 */
final class ViewTabButton : Button {
    bool lit = false;

    /**
     * Creates a view button.
     *
     * Params:
     *   caption = Text.
     *   handler = Click handler.
     */
    this(string caption, void delegate() handler) {
        super(caption, handler);
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        super.paint(r, theme);
        if (lit) {
            r.strokeRoundedRect(bounds.inset(1.0f), theme.radiusMd, 2.0f, theme.borderStrong);
            r.fillRect(RectF(bounds.x + 6.0f, bounds.bottom() - 4.0f, bounds.w - 12.0f, 2.0f), theme.text);
        }
    }
}

final class PatternEditorView : Widget, StudioCommandSink {
    enum float VIEW_BAR_H = 28.0f;
    static immutable string[3] VIEW_NAMES = ["Tracker", "Piano roll", "Drumpad"];
    static immutable string[3] VIEW_IDS = ["pattern.view.tracker", "pattern.view.pianoRoll", "pattern.view.drumpad"];

    enum uint MAX_EDIT_STEP = 64;
    enum uint PAGE_LINES = 16;

    StudioContext ctx;
    Dropdown patternSelect;
    PatternDimensionBox tracksBox;
    PatternDimensionBox linesBox;
    Button addButton;
    Button addDrumButton;
    Button duplicateButton;
    Button deleteButton;
    Button patternMenuButton;
    bool hexLineNumbers = true;
    ViewTabButton[3] viewButtons;

    private uint shownPattern_ = 0;
    private uint cursorTrack_ = 0;
    private uint cursorLine_ = 0;
    private uint cursorField_ = 0;
    private uint scrollLine_ = 0;
    private uint scrollTrack_ = 0;
    private float scrollFracY_ = 0.0f;
    private float scrollFracX_ = 0.0f;
    private bool hasSel_ = false;
    private uint selAnchorTrack_ = 0;
    private uint selAnchorLine_ = 0;
    private uint selEndTrack_ = 0;
    private uint selEndLine_ = 0;
    private bool dragging_ = false;
    private uint dragTrack_ = 0;
    private uint dragLine_ = 0;
    private float charW_ = 7.2f;
    private float lineH_ = 15.0f;
    private float rowH_ = 17.0f;
    private float padX_ = 4.0f;
    private float cellW_ = 145.0f;
    private float gutterW_ = 37.0f;
    private float headerH_ = 30.0f;
    private Widget[3] viewWidgets_;
    private PatternViewKind[uint] viewByPattern_;
    private float monoSize_ = 12.0f;
    private float labelTracksX_ = 0.0f;
    private float labelLinesX_ = 0.0f;
    private float infoX_ = 0.0f;
    private ulong itemsRevision_ = 0;
    private ulong itemsSelectionRevision_ = 0;
    private long lastDrawnPlayLine_ = -1;
    private uint[uint] heldNotes_;
    private string localClipboard_;


    /**
     * Returns the number of rows in one beat of the project's time signature (rows on a beat are shaded).
     *
     * Returns:
     *   StudioSession.linesPerBeat() (4 in 4/4).
     */
    uint beatLines() {
        return ctx.session.linesPerBeat();
    }

    /**
     * Returns the number of rows in one bar of the project's time signature (bar rows are shaded more strongly,
     * get a top border and a bold line number).
     *
     * Returns:
     *   StudioSession.linesPerBar() (16 in 4/4).
     */
    uint barLines() {
        return ctx.session.linesPerBar();
    }

    /**
     * Creates the editor, its header controls, and optionally registers the built-in Piano roll and Drumpad views.
     *
     * Params:
     *   ctx = Shared studio context.
     *   registerBuiltInViews = True to register PianoRollView and DrumpadView automatically.
     */
    this(StudioContext ctx, bool registerBuiltInViews = true) {
        this.ctx = ctx;
        id = "pattern.editor";
        focusable = true;
        patternSelect = add(new Dropdown(null, 0, &onPatternChosen));
        patternSelect.id = "pattern.select";
        patternSelect.onDoubleClick = () { beginRenamePattern(); };
        patternSelect.contextMenuProvider = (Point2F _) { return patternMenuItems(); };
        tracksBox = add(new PatternDimensionBox("pattern.tracks", ValueRange(1.0f, 64.0f, 4.0f, false, 1.0f)));
        tracksBox.onCommit = (uint n) { resizeCurrent(n, 0); };
        linesBox = add(new PatternDimensionBox("pattern.lines", ValueRange(1.0f, 4096.0f, 64.0f, false, 1.0f)));
        linesBox.onCommit = (uint n) { resizeCurrent(0, n); };
        addButton = add(new Button("Add", &addPattern));
        addButton.id = "pattern.add";
        addDrumButton = add(new Button("+Drum", &addDrumPattern));
        addDrumButton.id = "pattern.addDrum";
        duplicateButton = add(new Button("Dup", &duplicatePattern));
        duplicateButton.id = "pattern.duplicate";
        deleteButton = add(new Button("Del", &deletePattern));
        deleteButton.id = "pattern.delete";
        patternMenuButton = add(new Button("...", &openPatternMenu));
        patternMenuButton.id = "pattern.menu";
        foreach (i; 0 .. 3) {
            viewButtons[i] = add(new ViewTabButton(VIEW_NAMES[i], viewHandler(cast(PatternViewKind) i)));
            viewButtons[i].id = VIEW_IDS[i];
        }
        contextMenuProvider = &buildContextMenu;
        if (registerBuiltInViews) {
            registerView(PatternViewKind.pianoRoll, new PianoRollView(ctx));
            registerView(PatternViewKind.drumpad, new DrumpadView(ctx));
        }
        updateMetrics(null, ctx.theme);
        syncPatternSelection();
        syncHeaderWidgets();
    }

    /**
     * Returns the registered Piano roll view, or null if none is registered.
     *
     * Returns:
     *   PianoRollView or null.
     */
    PianoRollView pianoRollView() {
        return cast(PianoRollView) viewWidgets_[PatternViewKind.pianoRoll];
    }

    /**
     * Returns the registered Drumpad view, or null if none is registered.
     *
     * Returns:
     *   DrumpadView or null.
     */
    DrumpadView drumpadView() {
        return cast(DrumpadView) viewWidgets_[PatternViewKind.drumpad];
    }

    /**
     * Registers the widget that shows a view other than the tracker (the piano roll or the drumpad). It becomes a
     * child of the editor, fills the area below the shared header while its view is current, and receives studio
     * actions when it implements StudioCommandSink. Until a view is registered its button stays disabled.
     *
     * Params:
     *   kind = pianoRoll or drumpad.
     *   w = View widget (parentless).
     */
    void registerView(PatternViewKind kind, Widget w) {
        if (kind == PatternViewKind.tracker || w is null) {
            return;
        }
        if (viewWidgets_[kind] !is null) {
            remove(viewWidgets_[kind]);
        }
        viewWidgets_[kind] = add(w);
        w.visible = false;
        syncView();
    }

    /**
     * Reports whether the current pattern's type offers a view (T30): normal patterns offer Tracker and Piano
     * roll, drum patterns offer Drumpad and Tracker.
     *
     * Params:
     *   kind = View.
     *
     * Returns:
     *   True if offered.
     */
    bool viewOffered(PatternViewKind kind) {
        immutable bool drum = ctx.session.patternKind(ctx.currentPattern()) == PATTERN_KIND_DRUM;
        final switch (kind) {
            case PatternViewKind.tracker:
                return true;
            case PatternViewKind.pianoRoll:
                return !drum;
            case PatternViewKind.drumpad:
                return drum;
        }
    }

    /**
     * Reports whether a view can be shown now: it is offered for the pattern and, unless it is the tracker, a
     * widget is registered for it.
     *
     * Params:
     *   kind = View.
     *
     * Returns:
     *   True if its button is enabled.
     */
    bool viewAvailable(PatternViewKind kind) {
        return viewOffered(kind) && (kind == PatternViewKind.tracker || viewWidgets_[kind] !is null);
    }

    /**
     * Returns the view shown for the current pattern: the one chosen for it earlier in this run when still
     * available, else Drumpad for a drum pattern (when registered), else Tracker.
     *
     * Returns:
     *   Current view.
     */
    PatternViewKind currentView() {
        immutable uint pid = ctx.currentPattern();
        if (auto chosen = pid in viewByPattern_) {
            if (viewAvailable(*chosen)) {
                return *chosen;
            }
        }
        return viewAvailable(PatternViewKind.drumpad) ? PatternViewKind.drumpad : PatternViewKind.tracker;
    }

    /**
     * Shows a view for the current pattern and remembers it for that pattern until the app quits (it is not
     * saved in the project). Keyboard focus moves to the view.
     *
     * Params:
     *   kind = View.
     *
     * Returns:
     *   False when the view is not available.
     */
    bool setView(PatternViewKind kind) {
        if (!viewAvailable(kind)) {
            return false;
        }
        viewByPattern_[ctx.currentPattern()] = kind;
        syncView();
        if (auto ui = context()) {
            Widget target = kind == PatternViewKind.tracker ? this : viewWidgets_[kind];
            ui.setFocus(target.focusable ? target : this);
            layoutChildren();
        }
        invalidate();
        return true;
    }

    /**
     * Returns the rectangle a non-tracker view fills: everything below the view bar and the shared header.
     *
     * Returns:
     *   Rectangle in window coordinates.
     */
    RectF viewRect() const {
        immutable float top = originY() + headerH_;
        immutable float h = bounds.bottom() - top;
        return RectF(bounds.x, top, bounds.w, h > 0.0f ? h : 0.0f);
    }

    /**
     * Returns the cursor track (automation hook).
     *
     * Returns:
     *   Zero-based track.
     */
    uint cursorTrack() const {
        return cursorTrack_;
    }

    /**
     * Returns the cursor line (automation hook).
     *
     * Returns:
     *   Zero-based line.
     */
    uint cursorLine() const {
        return cursorLine_;
    }

    /**
     * Returns the cursor sub-field (automation hook).
     *
     * Returns:
     *   PatternField index 0..12.
     */
    uint cursorField() const {
        return cursorField_;
    }

    /**
     * Reports whether a block selection exists (automation hook).
     *
     * Returns:
     *   True if selected.
     */
    bool hasSelection() const {
        return hasSel_;
    }

    /**
     * Returns the normalized inclusive selection rectangle (automation hook).
     *
     * Returns:
     *   [t0, l0, t1, l1]; the cursor cell when nothing is selected.
     */
    uint[4] selection() const {
        if (!hasSel_) {
            return [cursorTrack_, cursorLine_, cursorTrack_, cursorLine_];
        }
        immutable uint t0 = selAnchorTrack_ < selEndTrack_ ? selAnchorTrack_ : selEndTrack_;
        immutable uint t1 = selAnchorTrack_ < selEndTrack_ ? selEndTrack_ : selAnchorTrack_;
        immutable uint l0 = selAnchorLine_ < selEndLine_ ? selAnchorLine_ : selEndLine_;
        immutable uint l1 = selAnchorLine_ < selEndLine_ ? selEndLine_ : selAnchorLine_;
        return [t0, l0, t1, l1];
    }

    /**
     * Returns the first visible line.
     *
     * Returns:
     *   Scroll line.
     */
    uint scrollLine() const {
        return scrollLine_;
    }

    /**
     * Returns the first visible track.
     *
     * Returns:
     *   Scroll track.
     */
    uint scrollTrack() const {
        return scrollTrack_;
    }

    /**
     * Returns how many whole lines fit in the grid.
     *
     * Returns:
     *   Visible line count (>= 1).
     */
    uint visibleLineCount() const {
        immutable float h = gridRect().h;
        immutable uint n = h > 0.0f ? cast(uint) floor(h / rowH_) : 0;
        return n > 0 ? n : 1;
    }

    /**
     * Returns how many whole tracks fit in the grid.
     *
     * Returns:
     *   Visible track count (>= 1).
     */
    uint visibleTrackCount() const {
        immutable float w = gridRect().w - gutterW_;
        immutable uint n = w > 0.0f ? cast(uint) floor(w / cellW_) : 0;
        return n > 0 ? n : 1;
    }

    /**
     * Returns a cell's rectangle in logical window coordinates (automation hook; may lie outside the view when
     * the cell is scrolled away).
     *
     * Params:
     *   track = Zero-based track.
     *   line = Zero-based line.
     *
     * Returns:
     *   Cell rectangle.
     */
    RectF cellRect(uint track, uint line) const {
        immutable RectF g = gridRect();
        immutable float x = g.x + gutterW_ + (cast(float) track - cast(float) scrollTrack_) * cellW_;
        immutable float y = g.y + (cast(float) line - cast(float) scrollLine_) * rowH_;
        return RectF(x, y, cellW_, rowH_);
    }

    /**
     * Returns a sub-field's rectangle in logical window coordinates (automation hook).
     *
     * Params:
     *   track = Zero-based track.
     *   line = Zero-based line.
     *   fieldIndex = PatternField index (clamped to 0..12).
     *
     * Returns:
     *   Field rectangle (the note field spans three characters, hex fields one).
     */
    RectF fieldRect(uint track, uint line, uint fieldIndex) const {
        immutable uint f = fieldIndex < PATTERN_FIELD_COUNT ? fieldIndex : PATTERN_FIELD_COUNT - 1;
        immutable RectF c = cellRect(track, line);
        return RectF(c.x + padX_ + FIELD_CHAR[f] * charW_, c.y, (f == 0 ? 3.0f : 1.0f) * charW_, rowH_);
    }

    /**
     * Places the cursor (clamped to the pattern) and clears the selection.
     *
     * Params:
     *   track = Track.
     *   line = Line.
     *   field = PatternField index.
     */
    void setCursor(uint track, uint line, uint field = 0) {
        moveCursorTo(track, line, field, false);
    }

    /**
     * Maps a song line to the current pattern's local line through the clip that plays it (pattern audition maps
     * line modulo pattern length).
     *
     * Params:
     *   songLine = Song line.
     *
     * Returns:
     *   Local line, or -1 when no clip of the current pattern covers songLine.
     */
    long localLineForSongLine(long songLine) const {
        const sp = currentPatternDoc();
        if (sp is null || sp.lines == 0 || songLine < 0) {
            return -1;
        }
        if (ctx.session.isAuditioningPattern()) {
            return songLine % sp.lines;
        }
        foreach (ref clip; ctx.session.document().clips) {
            if (clip.patternId != sp.patternId) {
                continue;
            }
            if (songLine >= clip.startLine && songLine < clip.startLine + clip.lengthLines) {
                immutable long rel = songLine - clip.startLine + clip.patternOffset;
                return rel % sp.lines;
            }
        }
        return -1;
    }

    /**
     * Returns the pattern-local playhead line from the latest telemetry.
     *
     * Returns:
     *   Local line, or -1 when stopped or the playhead is outside every clip of this pattern.
     */
    long playheadLocalLine() const {
        if (!ctx.telemetry.engine.playing) {
            return -1;
        }
        return localLineForSongLine(ctx.telemetry.engine.currentLine);
    }

    /**
     * Per-frame update (also run at the start of paint): follows pattern selection changes, clamps the cursor,
     * syncs header controls, records pending MIDI notes, and scrolls to the playhead when following.
     */
    void update() {
        syncPatternSelection();
        syncView();
        clampState();
        syncHeaderWidgets();
        consumeMidi();
        immutable long play = playheadLocalLine();
        if (ctx.followPlayhead && play >= 0) {
            centerOnLine(cast(uint) play);
        }
        lastDrawnPlayLine_ = play;
    }

    /**
     * Reports whether the view needs continuous frames.
     *
     * Returns:
     *   True while playing with follow enabled or when the playhead line changed since the last frame.
     */
    override bool isAnimating() {
        immutable PatternViewKind view = currentView();
        if (view != PatternViewKind.tracker && viewWidgets_[view] !is null) {
            return viewWidgets_[view].isAnimating();
        }
        if (ctx.telemetry.engine.playing && ctx.followPlayhead) {
            return true;
        }
        return playheadLocalLine() != lastDrawnPlayLine_;
    }

    /**
     * Executes context-dependent studio actions.
     *
     * Params:
     *   action = Action.
     *
     * Returns:
     *   True if handled (noteOffEntry is always consumed but only writes in edit mode).
     */
    bool handleStudioAction(StudioAction action) {
        immutable PatternViewKind view = currentView();
        if (view != PatternViewKind.tracker) {
            auto sink = cast(StudioCommandSink) viewWidgets_[view];
            return sink !is null && sink.handleStudioAction(action);
        }
        switch (action) {
            case StudioAction.noteOffEntry:
                if (ctx.editMode) {
                    writeNoteOff();
                }
                return true;
            case StudioAction.deleteCell:
                return deleteAtCursor();
            case StudioAction.deleteBlock:
                return clearSelectionBlock("Delete Block");
            case StudioAction.cut:
                return copyBlock() && clearSelectionBlock("Cut");
            case StudioAction.copy:
                return copyBlock();
            case StudioAction.paste:
                return pasteBlock();
            case StudioAction.selectAll:
                return selectAll();
            case StudioAction.transposeSemitoneUp:
                return transpose(1);
            case StudioAction.transposeSemitoneDown:
                return transpose(-1);
            case StudioAction.transposeOctaveUp:
                return transpose(12);
            case StudioAction.transposeOctaveDown:
                return transpose(-12);
            case StudioAction.interpolate:
                return interpolate();
            case StudioAction.nextTrack:
                return moveTrack(1);
            case StudioAction.prevTrack:
                return moveTrack(-1);
            case StudioAction.stepUp:
                ctx.editStep = ctx.editStep < MAX_EDIT_STEP ? ctx.editStep + 1 : MAX_EDIT_STEP;
                ctx.setStatus(format("Step %d", ctx.editStep));
                invalidate();
                return true;
            case StudioAction.stepDown:
                ctx.editStep = ctx.editStep > 0 ? ctx.editStep - 1 : 0;
                ctx.setStatus(format("Step %d", ctx.editStep));
                invalidate();
                return true;
            case StudioAction.nextPattern:
                return stepPattern(1);
            case StudioAction.prevPattern:
                return stepPattern(-1);
            case StudioAction.toggleFollow:
                ctx.followPlayhead = !ctx.followPlayhead;
                ctx.setStatus(ctx.followPlayhead ? "Follow on" : "Follow off");
                invalidate();
                return true;
            default:
                return false;
        }
    }

    /**
     * Measures with the current font metrics.
     *
     * Params:
     *   m = Text measurer.
     *   theme = Theme.
     *
     * Returns:
     *   Preferred size.
     */
    override Point2F measure(ITextMeasurer m, const ref StudioTheme theme) {
        updateMetrics(m, theme);
        return preferredSize;
    }

    /**
     * Places the header strip controls.
     */
    override void layoutChildren() {
        auto ui = context();
        if (ui !is null) {
            updateMetrics(ui.measurer(), ui.theme);
        }
        immutable float gap = ctx.theme.spacingSm;
        immutable float ch = ctx.theme.controlHeight;
        float vx = bounds.x + gap;
        static immutable float[3] tabW = [78.0f, 92.0f, 86.0f];
        foreach (i; 0 .. 3) {
            viewButtons[i].arrange(RectF(vx, bounds.y + 3.0f, tabW[i], VIEW_BAR_H - 6.0f));
            vx += tabW[i] + gap;
        }
        foreach (i; 1 .. 3) {
            if (viewWidgets_[i] !is null) {
                viewWidgets_[i].arrange(viewRect());
            }
        }
        immutable float y = originY() + (headerH_ - ch) * 0.5f;
        float x = bounds.x + gap;
        patternSelect.arrange(RectF(x, y, 138.0f, ch));
        x += 138.0f + gap;
        patternMenuButton.arrange(RectF(x, y, 26.0f, ch));
        x += 26.0f + gap * 2.0f;
        labelTracksX_ = x;
        x += 24.0f;
        tracksBox.arrange(RectF(x, y, 42.0f, ch));
        x += 42.0f + gap * 2.0f;
        labelLinesX_ = x;
        x += 24.0f;
        linesBox.arrange(RectF(x, y, 52.0f, ch));
        x += 52.0f + gap * 2.0f;
        addButton.arrange(RectF(x, y, 38.0f, ch));
        x += 38.0f + gap;
        addDrumButton.arrange(RectF(x, y, 52.0f, ch));
        x += 52.0f + gap;
        duplicateButton.arrange(RectF(x, y, 38.0f, ch));
        x += 38.0f + gap;
        deleteButton.arrange(RectF(x, y, 38.0f, ch));
        infoX_ = x + 38.0f + gap * 2.0f;
    }

    /**
     * Draws the header strip, column headers, gutter and visible cells.
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        updateMetrics(r, theme);
        update();
        r.fillRect(bounds, theme.panel);
        r.fillRect(RectF(bounds.x, bounds.y, bounds.w, VIEW_BAR_H), theme.panel);
        r.fillRect(RectF(bounds.x, bounds.y + VIEW_BAR_H - 1.0f, bounds.w, 1.0f), theme.border);
        paintHeader(r, theme);
        if (currentView() != PatternViewKind.tracker) {
            return;
        }
        r.pushClip(viewRect());
        paintGrid(r, theme);
        r.popClip();
        if (isFocused()) {
            immutable RectF g = gridRect();
            r.strokeRoundedRect(RectF(g.x + 0.5f, g.y - rowH_ + 0.5f, g.w - 1.0f, g.h + rowH_ - 1.0f), 0.0f,
                1.0f, theme.focusRing);
        }
    }

    /**
     * Places the cursor on click and starts a block-selection drag (Shift extends from the cursor). A double-click
     * puts the cursor on the note field of the clicked row and turns edit mode on, so the next QWERTY,
     * MIDI or on-screen piano note is written there.
     *
     * Params:
     *   e = Mouse event.
     *
     * Returns:
     *   True if the press hit the grid.
     */
    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left || currentView() != PatternViewKind.tracker) {
            return false;
        }
        uint t, l, f;
        if (!hitCell(e.pos, false, t, l, f)) {
            return false;
        }
        if (auto ui = context()) {
            ui.setFocus(this);
        }
        if (e.clickCount >= 2 && !e.shift()) {
            enterEditModeAt(t, l);
            return true;
        }
        if (e.shift()) {
            moveCursorTo(t, l, f, true);
            return true;
        }
        moveCursorTo(t, l, f, false);
        dragging_ = true;
        dragTrack_ = t;
        dragLine_ = l;
        return true;
    }

    /**
     * Extends the drag selection (auto-scrolling past the grid edges).
     *
     * Params:
     *   e = Mouse event.
     *
     * Returns:
     *   True while dragging.
     */
    override bool onMouseMove(const ref MouseEvent e) {
        if (!dragging_) {
            return false;
        }
        const sp = currentPatternDoc();
        if (sp is null) {
            return true;
        }
        immutable RectF g = gridRect();
        if (e.pos.y >= g.bottom() && scrollLine_ < maxScrollLine(sp.lines)) {
            scrollLine_++;
        } else if (e.pos.y < g.y && scrollLine_ > 0) {
            scrollLine_--;
        }
        uint t, l, f;
        hitCell(e.pos, true, t, l, f);
        if (t != dragTrack_ || l != dragLine_ || hasSel_) {
            hasSel_ = true;
            selAnchorTrack_ = dragTrack_;
            selAnchorLine_ = dragLine_;
            selEndTrack_ = t;
            selEndLine_ = l;
            cursorTrack_ = t;
            cursorLine_ = l;
            cursorField_ = f;
        }
        invalidate();
        return true;
    }

    /**
     * Ends a selection drag.
     *
     * Params:
     *   e = Mouse event.
     *
     * Returns:
     *   True.
     */
    override bool onMouseUp(const ref MouseEvent e) {
        dragging_ = false;
        return true;
    }

    /**
     * Cancels a selection drag.
     */
    override void onCaptureLost() {
        dragging_ = false;
    }

    /**
     * Scrolls lines (vertical delta) and tracks (horizontal delta, or Shift + vertical).
     *
     * Params:
     *   e = Scroll event.
     *
     * Returns:
     *   True if the event was inside the view.
     */
    override bool onScroll(const ref ScrollEvent e) {
        if (!bounds.contains(e.pos) || currentView() != PatternViewKind.tracker) {
            return false;
        }
        const sp = currentPatternDoc();
        if (sp is null) {
            return true;
        }
        float dy = e.deltaY;
        float dx = e.deltaX;
        if ((e.modifiers & KeyModifiers.shift) != 0 && dx == 0.0f) {
            dx = dy;
            dy = 0.0f;
        }
        immutable float lineMax = maxScrollLine(sp.lines);
        float posY = scrollLine_ + scrollFracY_ - dy / rowH_;
        posY = posY < 0.0f ? 0.0f : (posY > lineMax ? lineMax : posY);
        scrollLine_ = cast(uint) floor(posY);
        scrollFracY_ = posY - scrollLine_;
        immutable float trackMax = maxScrollTrack(sp.tracks);
        float posX = scrollTrack_ + scrollFracX_ - dx / cellW_;
        posX = posX < 0.0f ? 0.0f : (posX > trackMax ? trackMax : posX);
        scrollTrack_ = cast(uint) floor(posX);
        scrollFracX_ = posX - scrollTrack_;
        invalidate();
        return true;
    }

    /**
     * Handles navigation, keymap context actions, hex nibble entry, and QWERTY note entry/audition.
     *
     * Params:
     *   e = Key event.
     *
     * Returns:
     *   True if handled (document-level actions bubble to the studio root).
     */
    override bool onKeyDown(const ref KeyEvent e) {
        if (currentView() != PatternViewKind.tracker) {
            return false;
        }
        immutable StudioAction act = ctx.session.keymap().resolveAction(e.keyCode, e.modifiers);
        if (act != StudioAction.none) {
            if (isDocumentLevel(act)) {
                return false;
            }
            return handleStudioAction(act);
        }
        if (navigate(e)) {
            return true;
        }
        if (e.modifiers != 0) {
            return false;
        }
        if (cursorField_ != PatternField.note && ctx.editMode) {
            immutable int nib = hexNibbleForKey(e.keyCode);
            if (nib >= 0) {
                if (!e.isRepeat) {
                    editNibble(cast(uint) nib);
                }
                return true;
            }
        }
        return pianoKey(e, true);
    }

    /**
     * Releases auditioned piano notes.
     *
     * Params:
     *   e = Key event.
     *
     * Returns:
     *   True if the key was an auditioned note.
     */
    override bool onKeyUp(const ref KeyEvent e) {
        return pianoKey(e, false);
    }

    private const(SavedPattern)* currentPatternDoc() const {
        immutable uint pid = ctx.currentPattern();
        foreach (ref p; ctx.session.document().patterns) {
            if (p.patternId == pid) {
                return &p;
            }
        }
        return null;
    }

    private ptrdiff_t currentPatternIndex() const {
        immutable uint pid = ctx.currentPattern();
        foreach (i, ref p; ctx.session.document().patterns) {
            if (p.patternId == pid) {
                return cast(ptrdiff_t) i;
            }
        }
        return -1;
    }

    private static NoteCell cellOf(const(SavedPattern)* sp, uint track, uint line) {
        immutable size_t idx = cast(size_t) line * sp.tracks + track;
        return idx < sp.cells.length ? sp.cells[idx] : NoteCell.init;
    }

    private static NoteCell[] cellsCopy(const(SavedPattern)* sp) {
        immutable size_t n = cast(size_t) sp.tracks * sp.lines;
        NoteCell[] c = new NoteCell[n];
        immutable size_t have = sp.cells.length < n ? sp.cells.length : n;
        c[0 .. have] = sp.cells[0 .. have];
        return c;
    }

    private static bool sameCells(const(SavedPattern)* sp, const(NoteCell)[] cells) {
        return sp.cells.length >= cells.length && sp.cells[0 .. cells.length] == cells;
    }

    private float originY() const {
        return bounds.y + VIEW_BAR_H;
    }

    private void delegate() viewHandler(PatternViewKind kind) {
        return () { setView(kind); };
    }

    private void syncView() {
        immutable PatternViewKind view = currentView();
        foreach (i; 0 .. 3) {
            immutable PatternViewKind k = cast(PatternViewKind) i;
            viewButtons[i].enabled = viewAvailable(k);
            viewButtons[i].lit = k == view;
            if (viewWidgets_[i] !is null) {
                viewWidgets_[i].visible = k == view;
            }
        }
        tracksBox.visible = view == PatternViewKind.tracker;
    }

    private RectF gridRect() const {
        immutable float top = originY() + headerH_ + rowH_;
        immutable float h = bounds.bottom() - top;
        return RectF(bounds.x, top, bounds.w, h > 0.0f ? h : 0.0f);
    }

    private uint maxScrollLine(uint lines) const {
        immutable uint vis = visibleLineCount();
        return lines > vis ? lines - vis : 0;
    }

    private uint maxScrollTrack(uint tracks) const {
        immutable uint vis = visibleTrackCount();
        return tracks > vis ? tracks - vis : 0;
    }

    private void updateMetrics(ITextMeasurer m, const ref StudioTheme theme) {
        monoSize_ = theme.fontSizeMono;
        immutable float cw = measureTextOr(m, "0", FontId.mono, monoSize_);
        charW_ = cw > 0.0f ? cw : monoSize_ * 0.6f;
        lineH_ = lineHeightOr(m, FontId.mono, monoSize_);
        rowH_ = cast(float) ceil(lineH_) + 2.0f;
        padX_ = theme.spacingSm;
        cellW_ = CELL_TEXT_COLUMNS * charW_ + 2.0f * padX_ + 1.0f;
        gutterW_ = 4.0f * charW_ + 2.0f * padX_;
        headerH_ = theme.controlHeight + 2.0f * theme.spacingSm;
    }

    private void syncPatternSelection() {
        immutable uint pid = ctx.currentPattern();
        if (pid == shownPattern_) {
            return;
        }
        shownPattern_ = pid;
        cursorTrack_ = 0;
        cursorLine_ = 0;
        cursorField_ = 0;
        scrollLine_ = 0;
        scrollTrack_ = 0;
        scrollFracX_ = 0.0f;
        scrollFracY_ = 0.0f;
        hasSel_ = false;
        dragging_ = false;
        invalidate();
    }

    private void clampState() {
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        immutable uint tmax = sp.tracks - 1;
        immutable uint lmax = sp.lines - 1;
        cursorTrack_ = cursorTrack_ > tmax ? tmax : cursorTrack_;
        cursorLine_ = cursorLine_ > lmax ? lmax : cursorLine_;
        selAnchorTrack_ = selAnchorTrack_ > tmax ? tmax : selAnchorTrack_;
        selEndTrack_ = selEndTrack_ > tmax ? tmax : selEndTrack_;
        selAnchorLine_ = selAnchorLine_ > lmax ? lmax : selAnchorLine_;
        selEndLine_ = selEndLine_ > lmax ? lmax : selEndLine_;
        immutable uint sl = maxScrollLine(sp.lines);
        immutable uint st = maxScrollTrack(sp.tracks);
        scrollLine_ = scrollLine_ > sl ? sl : scrollLine_;
        scrollTrack_ = scrollTrack_ > st ? st : scrollTrack_;
    }

    private static string formatPatternListEntry(const ref SavedPattern p) {
        return p.kind == PATTERN_KIND_DRUM ? format("%02X [D] %s", p.patternId, p.name)
            : format("%02X %s", p.patternId, p.name);
    }

    private void syncHeaderWidgets() {
        const doc = ctx.session.document();
        immutable ulong rev = ctx.documentRevision();
        immutable ulong selRev = ctx.selectionRevision();
        if (rev != itemsRevision_ || selRev != itemsSelectionRevision_) {
            itemsRevision_ = rev;
            itemsSelectionRevision_ = selRev;
            string[] names = new string[doc.patterns.length];
            foreach (i, ref p; doc.patterns) {
                names[i] = formatPatternListEntry(p);
            }
            patternSelect.items = names;
            immutable ptrdiff_t idx = currentPatternIndex();
            patternSelect.selectedIndex = idx >= 0 ? cast(size_t) idx : 0;
            immutable bool room = doc.patterns.length < MAX_PATTERNS;
            addButton.enabled = room;
            addDrumButton.enabled = room;
            duplicateButton.enabled = room && idx >= 0;
            deleteButton.enabled = doc.patterns.length > 1 && idx >= 0;
            patternMenuButton.enabled = idx >= 0;
            invalidate();
        }
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        if (!tracksBox.isDragging() && !tracksBox.isEditing() && !tracksBox.hasPending()) {
            tracksBox.setValue(sp.tracks, false);
        }
        if (!linesBox.isDragging() && !linesBox.isEditing() && !linesBox.hasPending()) {
            linesBox.setValue(sp.lines, false);
        }
    }

    private void ensureCursorVisible() {
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        immutable uint vr = visibleLineCount();
        if (cursorLine_ < scrollLine_) {
            scrollLine_ = cursorLine_;
        } else if (cursorLine_ >= scrollLine_ + vr) {
            scrollLine_ = cursorLine_ - vr + 1;
        }
        immutable uint vt = visibleTrackCount();
        if (cursorTrack_ < scrollTrack_) {
            scrollTrack_ = cursorTrack_;
        } else if (cursorTrack_ >= scrollTrack_ + vt) {
            scrollTrack_ = cursorTrack_ - vt + 1;
        }
        scrollFracX_ = 0.0f;
        scrollFracY_ = 0.0f;
        clampState();
    }

    private void centerOnLine(uint line) {
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        immutable uint half = visibleLineCount() / 2;
        uint target = line > half ? line - half : 0;
        immutable uint maxL = maxScrollLine(sp.lines);
        target = target > maxL ? maxL : target;
        if (target != scrollLine_) {
            scrollLine_ = target;
            scrollFracY_ = 0.0f;
            invalidate();
        }
    }

    private void moveCursorTo(uint track, uint line, uint field, bool extend) {
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        immutable uint t = track < sp.tracks ? track : sp.tracks - 1;
        immutable uint l = line < sp.lines ? line : sp.lines - 1;
        immutable uint f = field < PATTERN_FIELD_COUNT ? field : PATTERN_FIELD_COUNT - 1;
        if (extend) {
            if (!hasSel_) {
                hasSel_ = true;
                selAnchorTrack_ = cursorTrack_;
                selAnchorLine_ = cursorLine_;
            }
            selEndTrack_ = t;
            selEndLine_ = l;
        } else {
            hasSel_ = false;
        }
        cursorTrack_ = t;
        cursorLine_ = l;
        cursorField_ = f;
        ensureCursorVisible();
        invalidate();
    }

    private bool navigate(const ref KeyEvent e) {
        if (e.modifiers != 0 && e.modifiers != KeyModifiers.shift) {
            return false;
        }
        const sp = currentPatternDoc();
        if (sp is null) {
            return false;
        }
        if (e.keyCode == KeyCode.tab) {
            return moveTrack(e.shift() ? -1 : 1);
        }
        uint t = cursorTrack_;
        uint l = cursorLine_;
        uint f = cursorField_;
        immutable uint lastLine = sp.lines - 1;
        switch (e.keyCode) {
            case KeyCode.left:
                if (f > 0) {
                    f--;
                } else if (t > 0) {
                    t--;
                    f = PATTERN_FIELD_COUNT - 1;
                }
                break;
            case KeyCode.right:
                if (f + 1 < PATTERN_FIELD_COUNT) {
                    f++;
                } else if (t + 1 < sp.tracks) {
                    t++;
                    f = 0;
                }
                break;
            case KeyCode.up:
                l = l > 0 ? l - 1 : 0;
                break;
            case KeyCode.down:
                l = l < lastLine ? l + 1 : lastLine;
                break;
            case KeyCode.pageUp:
                l = l >= PAGE_LINES ? l - PAGE_LINES : 0;
                break;
            case KeyCode.pageDown:
                l = l + PAGE_LINES < lastLine ? l + PAGE_LINES : lastLine;
                break;
            case KeyCode.home:
                l = 0;
                break;
            case KeyCode.end:
                l = lastLine;
                break;
            default:
                return false;
        }
        moveCursorTo(t, l, f, e.shift());
        return true;
    }

    private bool moveTrack(int dir) {
        const sp = currentPatternDoc();
        if (sp is null) {
            return false;
        }
        immutable uint n = sp.tracks;
        immutable uint t = dir > 0 ? (cursorTrack_ + 1) % n : (cursorTrack_ + n - 1) % n;
        moveCursorTo(t, cursorLine_, cursorField_, false);
        return true;
    }

    private bool stepPattern(int dir) {
        const doc = ctx.session.document();
        immutable ptrdiff_t idx = currentPatternIndex();
        if (idx < 0) {
            return false;
        }
        immutable ptrdiff_t next = idx + dir;
        if (next < 0 || next >= cast(ptrdiff_t) doc.patterns.length) {
            return true;
        }
        ctx.selectPattern(doc.patterns[next].patternId);
        syncPatternSelection();
        invalidate();
        return true;
    }

    private void advance() {
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        immutable uint lastLine = sp.lines - 1;
        immutable ulong next = cast(ulong) cursorLine_ + ctx.editStep;
        cursorLine_ = next < lastLine ? cast(uint) next : lastLine;
        ensureCursorVisible();
        invalidate();
    }

    private void enterEditModeAt(uint track, uint line) {
        dragging_ = false;
        moveCursorTo(track, line, PatternField.note, false);
        if (!ctx.editMode) {
            ctx.setEditMode(true);
        }
        invalidate();
    }

    private bool isMasterOutput(uint modId) const {
        if (modId == 0) {
            return false;
        }
        foreach (ref m; ctx.session.document().modules) {
            if (m.id == modId) {
                return m.typeId == MASTER_OUTPUT_TYPE_ID;
            }
        }
        return false;
    }

    private bool noteEntryBlocked(const(SavedPattern)* sp, uint track, uint line) {
        if (sp is null || !isMasterOutput(entryModule(sp, track, line))) {
            return false;
        }
        ctx.setStatus(MASTER_OUTPUT_BLOCKED_STATUS);
        return true;
    }

    private ushort entryModule(const(SavedPattern)* sp, uint track, uint line) const {
        if (ctx.selectedModule() != 0) {
            return cast(ushort) ctx.selectedModule();
        }
        immutable NoteCell here = cellOf(sp, track, line);
        if (here.moduleId != 0) {
            return here.moduleId;
        }
        uint l = line;
        while (l > 0) {
            l--;
            immutable NoteCell c = cellOf(sp, track, l);
            if (c.isMidiNote() && c.moduleId != 0) {
                return c.moduleId;
            }
        }
        return 0;
    }

    private bool writeNote(uint track, uint line, int midi, float velocity) {
        const sp = currentPatternDoc();
        if (sp is null || track >= sp.tracks || line >= sp.lines) {
            return false;
        }
        NoteCell c = cellOf(sp, track, line);
        immutable ushort mod = entryModule(sp, track, line);
        if (isMasterOutput(mod)) {
            ctx.setStatus(MASTER_OUTPUT_BLOCKED_STATUS);
            return false;
        }
        immutable uint pid = sp.patternId;
        c.note = NoteCell.encodeMidiNote(midi);
        c.velocity = NoteCell.encodeVelocity(velocity);
        c.moduleId = mod;
        return ctx.session.doPatchCell(pid, track, line, c);
    }

    private void writeNoteOff() {
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        NoteCell c = cellOf(sp, cursorTrack_, cursorLine_);
        immutable uint pid = sp.patternId;
        c.note = NoteCmd.noteOff;
        c.velocity = 0;
        ctx.session.doPatchCell(pid, cursorTrack_, cursorLine_, c);
        advance();
    }

    private void editNibble(uint nibble) {
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        immutable NoteCell before = cellOf(sp, cursorTrack_, cursorLine_);
        immutable NoteCell after = setFieldNibble(before, cursorField_, nibble);
        immutable uint pid = sp.patternId;
        if (after != before) {
            ctx.session.doPatchCell(pid, cursorTrack_, cursorLine_, after);
        }
        advance();
    }

    private bool pianoKey(const ref KeyEvent e, bool down) {
        if (!down) {
            auto held = e.keyCode in heldNotes_;
            if (held is null) {
                return false;
            }
            immutable uint mod = *held;
            heldNotes_.remove(e.keyCode);
            ctx.clearQwertyNote(e.keyCode);
            ctx.session.releaseLiveNote(ModuleId(mod), e.keyCode);
            invalidate();
            return true;
        }
        ubyte midi = 0;
        if (!ctx.session.keymap().resolveNote(e.keyCode, ctx.editOctave, midi)) {
            return false;
        }
        if (e.isRepeat) {
            return true;
        }
        const sp = currentPatternDoc();
        immutable uint mod = sp !is null ? entryModule(sp, cursorTrack_, cursorLine_) : ctx.selectedModule();
        if (ctx.editMode && cursorField_ == PatternField.note && sp !is null
                && !noteEntryBlocked(sp, cursorTrack_, cursorLine_)) {
            writeNote(cursorTrack_, cursorLine_, midi, 1.0f);
            advance();
        }
        if (mod != 0) {
            heldNotes_[e.keyCode] = mod;
            ctx.setQwertyNote(e.keyCode, mod, midi);
            audition(PlatformEventKind.keyDown, e, mod);
            invalidate();
        }
        return true;
    }

    private void audition(PlatformEventKind kind, const ref KeyEvent e, uint mod) {
        PlatformEvent ev;
        ev.kind = kind;
        ev.keyCode = e.keyCode;
        ev.modifiers = e.modifiers;
        ev.isRepeat = e.isRepeat;
        ctx.session.handleKeyEvent(ev, ModuleId(mod));
    }

    private void consumeMidi() {
        MidiNoteEvent[] notes = ctx.takeMidiNotes();
        if (notes.length == 0 || !ctx.editMode || currentView() != PatternViewKind.tracker) {
            return;
        }
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        immutable uint tracks = sp.tracks;
        if (ctx.telemetry.engine.playing) {
            long lastLine = -1;
            uint chord = 0;
            foreach (ref ev; notes) {
                immutable long local = localLineForSongLine(ev.line);
                if (local < 0) {
                    continue;
                }
                chord = local == lastLine ? chord + 1 : 0;
                lastLine = local;
                writeNote((cursorTrack_ + chord) % tracks, cast(uint) local, ev.note, ev.velocity / 127.0f);
            }
            return;
        }
        if (noteEntryBlocked(sp, cursorTrack_, cursorLine_)) {
            return;
        }
        foreach (i, ref ev; notes) {
            writeNote(cast(uint)((cursorTrack_ + i) % tracks), cursorLine_, ev.note, ev.velocity / 127.0f);
        }
        advance();
    }

    private bool region(const(SavedPattern)* sp, out uint t0, out uint l0, out uint w, out uint h) const {
        if (sp is null) {
            return false;
        }
        immutable uint[4] s = selection();
        t0 = s[0];
        l0 = s[1];
        w = s[2] - s[0] + 1;
        h = s[3] - s[1] + 1;
        return t0 < sp.tracks && l0 < sp.lines;
    }

    private bool deleteAtCursor() {
        if (hasSel_) {
            return clearSelectionBlock("Delete Block");
        }
        const sp = currentPatternDoc();
        if (sp is null) {
            return false;
        }
        immutable NoteCell before = cellOf(sp, cursorTrack_, cursorLine_);
        immutable NoteCell after = clearField(before, cursorField_);
        immutable uint pid = sp.patternId;
        if (after != before) {
            ctx.session.doPatchCell(pid, cursorTrack_, cursorLine_, after);
        }
        advance();
        return true;
    }

    private bool clearSelectionBlock(string label) {
        const sp = currentPatternDoc();
        uint t0, l0, w, h;
        if (!region(sp, t0, l0, w, h)) {
            return false;
        }
        NoteCell[] cells = cellsCopy(sp);
        clearRegion(cells, sp.tracks, sp.lines, t0, l0, w, h);
        if (sameCells(sp, cells)) {
            return true;
        }
        immutable uint pid = sp.patternId;
        ctx.session.doReplacePatternCells(pid, cells, label);
        invalidate();
        return true;
    }

    private bool copyBlock() {
        const sp = currentPatternDoc();
        uint t0, l0, w, h;
        if (!region(sp, t0, l0, w, h)) {
            return false;
        }
        PatternBlock b = extractBlock(cellsCopy(sp), sp.tracks, sp.lines, t0, l0, w, h);
        if (!b.isValid()) {
            return false;
        }
        immutable string text = encodeBlockText(b);
        localClipboard_ = text;
        if (ctx.clipboard !is null) {
            ctx.clipboard.setText(text);
        }
        ctx.setStatus(format("Copied %d x %d", b.tracks, b.lines));
        return true;
    }

    private bool pasteBlock() {
        const sp = currentPatternDoc();
        if (sp is null) {
            return false;
        }
        string text = ctx.clipboard !is null ? ctx.clipboard.getText() : null;
        if (text.length == 0) {
            text = localClipboard_;
        }
        PatternBlock b;
        string err;
        if (!decodeBlockText(text, b, err)) {
            ctx.setStatus("Paste: " ~ (err.length > 0 ? err : "clipboard is empty"));
            return true;
        }
        NoteCell[] cells = cellsCopy(sp);
        writeBlockInto(cells, sp.tracks, sp.lines, cursorTrack_, cursorLine_, b);
        immutable uint pid = sp.patternId;
        immutable uint w = b.tracks < sp.tracks - cursorTrack_ ? b.tracks : sp.tracks - cursorTrack_;
        immutable uint h = b.lines < sp.lines - cursorLine_ ? b.lines : sp.lines - cursorLine_;
        if (!sameCells(sp, cells)) {
            ctx.session.doReplacePatternCells(pid, cells, "Paste");
        }
        hasSel_ = true;
        selAnchorTrack_ = cursorTrack_;
        selAnchorLine_ = cursorLine_;
        selEndTrack_ = cursorTrack_ + w - 1;
        selEndLine_ = cursorLine_ + h - 1;
        invalidate();
        return true;
    }

    private bool selectAll() {
        const sp = currentPatternDoc();
        if (sp is null) {
            return false;
        }
        hasSel_ = true;
        selAnchorTrack_ = 0;
        selAnchorLine_ = 0;
        selEndTrack_ = sp.tracks - 1;
        selEndLine_ = sp.lines - 1;
        invalidate();
        return true;
    }

    private bool transpose(int semitones) {
        const sp = currentPatternDoc();
        uint t0, l0, w, h;
        if (!region(sp, t0, l0, w, h)) {
            return false;
        }
        NoteCell[] cells = cellsCopy(sp);
        PatternBlock b = extractBlock(cells, sp.tracks, sp.lines, t0, l0, w, h);
        if (!b.isValid() || transposeBlock(b, semitones) == 0) {
            return true;
        }
        writeBlockInto(cells, sp.tracks, sp.lines, t0, l0, b);
        immutable uint pid = sp.patternId;
        ctx.session.doReplacePatternCells(pid, cells, "Transpose");
        invalidate();
        return true;
    }

    private InterpolateField interpolationField() const {
        switch (fieldGroup(cursorField_)) {
            case 3:
            case 5:
                return InterpolateField.paramId;
            case 4:
            case 6:
                return InterpolateField.effectValue;
            default:
                return InterpolateField.velocity;
        }
    }

    private bool interpolate() {
        const sp = currentPatternDoc();
        uint t0, l0, w, h;
        if (!region(sp, t0, l0, w, h) || h < 2) {
            return false;
        }
        NoteCell[] cells = cellsCopy(sp);
        PatternBlock b = extractBlock(cells, sp.tracks, sp.lines, t0, l0, w, h);
        if (!b.isValid()) {
            return false;
        }
        immutable InterpolateField f = interpolationField();
        bool any = false;
        foreach (c; 0 .. b.tracks) {
            any = interpolateColumn(b, c, f) || any;
        }
        if (!any) {
            return true;
        }
        writeBlockInto(cells, sp.tracks, sp.lines, t0, l0, b);
        if (sameCells(sp, cells)) {
            return true;
        }
        immutable uint pid = sp.patternId;
        ctx.session.doReplacePatternCells(pid, cells, "Interpolate");
        invalidate();
        return true;
    }

    /**
     * Opens a text field over the pattern dropdown to rename the current pattern (Return or a click elsewhere
     * commits, Escape cancels; duplicate names get a number appended by the session).
     *
     * Returns:
     *   The open field, or null when there is no current pattern or the view is detached.
     */
    TextField beginRenamePattern() {
        const sp = currentPatternDoc();
        auto ui = context();
        if (sp is null || ui is null) {
            return null;
        }
        immutable uint pid = sp.patternId;
        return openTextEditor(ui, patternSelect.bounds, sp.name, (string name) {
            ctx.renamePattern(pid, name);
            invalidate();
        });
    }

    private void onPatternChosen(size_t index) {
        const doc = ctx.session.document();
        if (index < doc.patterns.length) {
            ctx.selectPattern(doc.patterns[index].patternId);
            syncPatternSelection();
        }
    }

    private void resizeCurrent(uint tracks, uint lines) {
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        immutable uint t = tracks != 0 ? tracks : sp.tracks;
        immutable uint l = lines != 0 ? lines : sp.lines;
        immutable uint pid = sp.patternId;
        if (t == sp.tracks && l == sp.lines) {
            return;
        }
        ctx.session.doResizePattern(pid, t, l);
        clampState();
        invalidate();
    }

    /**
     * Builds the pattern menu entries (rename, new drum pattern, convert pattern type, duplicate, delete).
     *
     * Returns:
     *   Menu entries for the current pattern.
     */
    MenuItem[] patternMenuItems() {
        const doc = ctx.session.document();
        const sp = currentPatternDoc();
        immutable bool hasPat = sp !is null;
        immutable bool drum = hasPat && sp.kind == PATTERN_KIND_DRUM;
        immutable bool room = doc.patterns.length < MAX_PATTERNS;
        MenuItem[] items;
        items ~= MenuItem("Rename Pattern…", () { beginRenamePattern(); }, hasPat);
        items ~= MenuItem("New Drum Pattern", () { addDrumPattern(); }, room);
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem(drum ? "Convert to normal pattern" : "Convert to drum pattern",
            () { convertCurrentPattern(); }, hasPat);
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem("Duplicate Pattern", () { duplicatePattern(); }, room && hasPat);
        items ~= MenuItem("Delete Pattern", () { deletePattern(); }, doc.patterns.length > 1 && hasPat);
        return items;
    }

    /**
     * Adds a new drum pattern with the default kit and selects it (which opens in Drumpad view).
     */
    void addDrumPattern() {
        immutable uint id = ctx.session.doAddDrumPattern();
        if (id == 0) {
            ctx.setStatus("Could not add drum pattern");
            return;
        }
        ctx.selectPattern(id);
        syncPatternSelection();
        syncView();
        if (auto ui = context()) {
            layoutChildren();
        }
        ctx.setStatus("Added drum pattern");
        invalidate();
    }

    /**
     * Converts the current pattern between normal and drum pattern in one undo step, switching to Drumpad or
     * Tracker view accordingly.
     *
     * Returns:
     *   True if converted.
     */
    bool convertCurrentPattern() {
        const sp = currentPatternDoc();
        if (sp is null) {
            return false;
        }
        immutable uint pid = sp.patternId;
        if (sp.kind == PATTERN_KIND_DRUM) {
            if (!ctx.session.doConvertToNormalPattern(pid)) {
                return false;
            }
            viewByPattern_[pid] = PatternViewKind.tracker;
            syncView();
            ctx.setStatus("Converted to normal pattern");
        } else {
            if (!ctx.session.doConvertToDrumPattern(pid)) {
                return false;
            }
            viewByPattern_[pid] = PatternViewKind.drumpad;
            syncView();
            ctx.setStatus("Converted to drum pattern");
        }
        invalidate();
        return true;
    }

    private void openPatternMenu() {
        if (auto ui = context()) {
            ui.openContextMenu(patternMenuItems(),
                Point2F(patternMenuButton.bounds.x, patternMenuButton.bounds.bottom()));
        }
    }

    private void addPattern() {
        const sp = currentPatternDoc();
        immutable uint t = sp !is null ? sp.tracks : 4;
        immutable uint l = sp !is null ? sp.lines : 64;
        immutable uint id = ctx.session.doAddPattern(t, l);
        if (id != 0) {
            ctx.selectPattern(id);
            syncPatternSelection();
        }
    }

    private void duplicatePattern() {
        const sp = currentPatternDoc();
        if (sp is null) {
            return;
        }
        immutable uint id = ctx.session.doDuplicatePattern(sp.patternId);
        if (id != 0) {
            ctx.selectPattern(id);
            syncPatternSelection();
        }
    }

    private void deletePattern() {
        const doc = ctx.session.document();
        immutable ptrdiff_t idx = currentPatternIndex();
        if (idx < 0) {
            return;
        }
        if (doc.patterns.length <= 1) {
            ctx.setStatus("Cannot delete the last pattern");
            return;
        }
        immutable uint pid = doc.patterns[idx].patternId;
        if (!ctx.session.doRemovePattern(pid)) {
            return;
        }
        const after = ctx.session.document();
        immutable size_t next = cast(size_t) idx < after.patterns.length ? cast(size_t) idx : after.patterns.length - 1;
        ctx.selectPattern(after.patterns[next].patternId);
        syncPatternSelection();
    }

    private MenuItem[] buildContextMenu(Point2F p) {
        if (currentView() != PatternViewKind.tracker) {
            return null;
        }
        uint t, l, f;
        if (hitCell(p, false, t, l, f)) {
            immutable uint[4] s = selection();
            immutable bool inside = hasSel_ && t >= s[0] && t <= s[2] && l >= s[1] && l <= s[3];
            if (!inside) {
                moveCursorTo(t, l, f, false);
            }
        }
        MenuItem[] items;
        items ~= MenuItem("Cut", () { handleStudioAction(StudioAction.cut); }, true, false, "Cmd+X");
        items ~= MenuItem("Copy", () { handleStudioAction(StudioAction.copy); }, true, false, "Cmd+C");
        items ~= MenuItem("Paste", () { handleStudioAction(StudioAction.paste); }, true, false, "Cmd+V");
        items ~= MenuItem("Delete", () { handleStudioAction(StudioAction.deleteBlock); }, true, false, "Del");
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem("Select All", () { handleStudioAction(StudioAction.selectAll); }, true, false, "Cmd+A");
        items ~= MenuItem("Transpose +1", () { handleStudioAction(StudioAction.transposeSemitoneUp); });
        items ~= MenuItem("Transpose -1", () { handleStudioAction(StudioAction.transposeSemitoneDown); });
        items ~= MenuItem("Transpose +12", () { handleStudioAction(StudioAction.transposeOctaveUp); });
        items ~= MenuItem("Transpose -12", () { handleStudioAction(StudioAction.transposeOctaveDown); });
        items ~= MenuItem("Interpolate", () { handleStudioAction(StudioAction.interpolate); }, hasSel_, false,
            "Cmd+J");
        if (const sp = currentPatternDoc()) {
            items ~= MenuItem.makeSeparator();
            items ~= MenuItem(sp.kind == PATTERN_KIND_DRUM ? "Convert to normal pattern" : "Convert to drum pattern",
                () { convertCurrentPattern(); });
        }
        return items;
    }

    private bool hitCell(Point2F p, bool clampToGrid, out uint track, out uint line, out uint field) const {
        const sp = currentPatternDoc();
        if (sp is null) {
            return false;
        }
        immutable RectF g = gridRect();
        if (!clampToGrid && !g.contains(p)) {
            return false;
        }
        immutable float ly = p.y - g.y;
        long row = cast(long) floor(ly / rowH_) + scrollLine_;
        row = row < 0 ? 0 : (row >= sp.lines ? sp.lines - 1 : row);
        line = cast(uint) row;
        immutable float lx = p.x - (g.x + gutterW_);
        if (lx < 0.0f) {
            track = cursorTrack_;
            field = 0;
            return true;
        }
        immutable long col = cast(long) floor(lx / cellW_);
        long t = col + scrollTrack_;
        if (t >= sp.tracks) {
            if (!clampToGrid) {
                return false;
            }
            track = sp.tracks - 1;
            field = PATTERN_FIELD_COUNT - 1;
            return true;
        }
        track = cast(uint) t;
        immutable float inCell = lx - col * cellW_ - padX_;
        long ch = cast(long) floor(inCell / charW_);
        ch = ch < 0 ? 0 : (ch >= CELL_TEXT_COLUMNS ? CELL_TEXT_COLUMNS - 1 : ch);
        field = CHAR_FIELD[cast(size_t) ch];
        return true;
    }

    private static ColorRGBA trackColor(const ref StudioTheme t, uint track) {
        switch (track % 8) {
            case 0:
                return t.wireAudio;
            case 1:
                return t.wireEvent;
            case 2:
                return t.wireCv;
            case 3:
                return t.wireSidechain;
            case 4:
                return t.accent;
            case 5:
                return t.success;
            case 6:
                return t.warning;
            default:
                return t.danger;
        }
    }

    private void paintHeader(IRenderer2D r, const ref StudioTheme theme) {
        immutable RectF h = RectF(bounds.x, originY(), bounds.w, headerH_);
        r.fillRect(h, theme.panelRaised);
        r.fillRect(RectF(h.x, h.bottom() - 1.0f, h.w, 1.0f), theme.border);
        immutable float size = theme.fontSizeSmall;
        immutable float ty = h.y + (headerH_ - r.lineHeight(FontId.ui, size)) * 0.5f;
        if (tracksBox.visible) {
            r.drawText(Point2F(labelTracksX_, ty), "Trk", FontId.ui, size, theme.textDim);
        }
        r.drawText(Point2F(labelLinesX_, ty), "Lin", FontId.ui, size, theme.textDim);
        if (infoX_ < h.right()) {
            char[48] buf;
            size_t n = 0;
            void put(const(char)[] s) {
                foreach (ch; s) {
                    if (n < buf.length) {
                        buf[n++] = ch;
                    }
                }
            }
            put("Oct ");
            immutable int oct = ctx.editOctave;
            if (oct < 0) {
                put("-");
            }
            char[1] od;
            putDec(od[], cast(uint)(oct < 0 ? -oct : oct));
            put(od[]);
            put("  Step ");
            char[2] sd;
            putDec(sd[], ctx.editStep);
            put(sd[0] == '0' ? sd[1 .. 2] : sd[]);
            if (ctx.editMode) {
                put("  EDIT");
            }
            if (ctx.liveRecording()) {
                put("  REC");
            }
            if (ctx.followPlayhead) {
                put("  FOLLOW");
            }
            r.pushClip(h);
            r.drawText(Point2F(infoX_, ty), buf[0 .. n], FontId.ui, size,
                ctx.editMode || ctx.liveRecording() ? theme.danger : theme.textDim);
            r.popClip();
        }
    }

    private void paintGrid(IRenderer2D r, const ref StudioTheme theme) {
        immutable RectF g = gridRect();
        immutable RectF colHeader = RectF(bounds.x, g.y - rowH_, bounds.w, rowH_);
        r.fillRect(colHeader, theme.panelSunken);
        r.fillRect(g, theme.trackerBackground);
        const sp = currentPatternDoc();
        if (sp is null) {
            r.drawText(Point2F(g.x + padX_, g.y + padX_), "No pattern", FontId.ui, theme.fontSizeBody, theme.textDim);
            return;
        }
        immutable uint tracks = sp.tracks;
        immutable uint lines = sp.lines;
        immutable uint firstLine = scrollLine_;
        immutable uint rowsShown = visibleLineCount() + 1;
        immutable uint lastLine = firstLine + rowsShown < lines ? firstLine + rowsShown : lines;
        immutable uint firstTrack = scrollTrack_;
        immutable float cellsW = g.w - gutterW_;
        immutable uint tracksShown = cellsW > 0.0f ? cast(uint) ceil(cellsW / cellW_) : 0;
        immutable uint lastTrack = firstTrack + tracksShown < tracks ? firstTrack + tracksShown : tracks;
        immutable float textDy = (rowH_ - lineH_) * 0.5f;
        immutable long play = playheadLocalLine();
        immutable float cellsX = g.x + gutterW_;
        immutable float cellsRight = cellsX + (lastTrack - firstTrack) * cellW_;
        immutable float rowRight = cellsRight < g.right() ? cellsRight : g.right();

        foreach (t; firstTrack .. lastTrack) {
            immutable RectF c = cellRect(t, 0);
            immutable float x = c.x;
            r.fillRect(RectF(x, colHeader.y, cellW_ - 1.0f, 3.0f), trackColor(theme, t));
            char[2] num;
            putDec(num[], (t + 1) % 100);
            r.drawText(Point2F(x + padX_, colHeader.y + textDy + 1.0f), num[], FontId.mono, monoSize_,
                t == cursorTrack_ ? theme.text : theme.textDim);
        }

        immutable uint rowsPerBar = barLines();
        immutable uint rowsPerBeat = beatLines();
        foreach (l; firstLine .. lastLine) {
            immutable float y = g.y + (l - firstLine) * rowH_;
            immutable RectF row = RectF(g.x, y, rowRight - g.x, rowH_);
            if (l == play) {
                r.fillRect(row, theme.trackerPlayhead);
                r.fillRect(RectF(row.x, row.y, 3.0f, row.h), theme.danger);
            } else if (l == cursorLine_) {
                r.fillRect(row, theme.trackerBackground);
                r.fillRect(row, theme.hover);
            } else if (rowsPerBar > 0 && l % rowsPerBar == 0) {
                r.fillRect(row, theme.trackerRowBar);
                r.fillRect(RectF(row.x, row.y, row.w, 1.0f), theme.border);
            } else if (rowsPerBeat > 0 && l % rowsPerBeat == 0) {
                r.fillRect(row, theme.trackerRowBeat);
            }
            char[4] num;
            const(char)[] txt;
            if (hexLineNumbers) {
                putHex(num[0 .. 3], l);
                txt = num[0 .. 3];
            } else {
                putDec(num[], l);
                txt = num[];
            }
            immutable bool strong = (rowsPerBar > 0 && l % rowsPerBar == 0) || l == cursorLine_;
            r.drawText(Point2F(g.x + padX_, y + textDy), txt, FontId.mono, monoSize_,
                strong ? theme.text : theme.textDim);
        }

        if (hasSel_) {
            immutable uint[4] s = selection();
            immutable uint st0 = s[0] > firstTrack ? s[0] : firstTrack;
            immutable uint st1 = s[2] + 1 < lastTrack ? s[2] + 1 : lastTrack;
            immutable uint sl0 = s[1] > firstLine ? s[1] : firstLine;
            immutable uint sl1 = s[3] + 1 < lastLine ? s[3] + 1 : lastLine;
            if (st1 > st0 && sl1 > sl0) {
                immutable RectF a = cellRect(st0, sl0);
                immutable RectF selRect = RectF(a.x, a.y, (st1 - st0) * cellW_, (sl1 - sl0) * rowH_);
                r.fillRect(selRect, theme.selection);
                r.strokeRoundedRect(selRect, 0.0f, 2.0f, theme.accent);
            }
        }

        if (cursorTrack_ >= firstTrack && cursorTrack_ < lastTrack && cursorLine_ >= firstLine
            && cursorLine_ < lastLine) {
            r.strokeRoundedRect(fieldRect(cursorTrack_, cursorLine_, cursorField_), 0.0f, 2.0f, theme.trackerCursor);
        }

        foreach (l; firstLine .. lastLine) {
            immutable float y = g.y + (l - firstLine) * rowH_ + textDy;
            immutable size_t rowBase = cast(size_t) l * tracks;
            foreach (t; firstTrack .. lastTrack) {
                immutable size_t idx = rowBase + t;
                immutable NoteCell cell = idx < sp.cells.length ? sp.cells[idx] : NoteCell.init;
                immutable CellText ct = formatCell(cell);
                immutable float x = cellsX + (t - firstTrack) * cellW_ + padX_;
                r.drawText(Point2F(x, y), ct.note[], FontId.mono, monoSize_,
                    ct.noteEmpty ? theme.trackerEmpty : theme.trackerNote);
                r.drawText(Point2F(x + 4.0f * charW_, y), ct.velocity[], FontId.mono, monoSize_,
                    ct.velocityEmpty ? theme.trackerEmpty : theme.trackerVelocity);
                r.drawText(Point2F(x + 7.0f * charW_, y), ct.moduleId[], FontId.mono, monoSize_,
                    ct.moduleEmpty ? theme.trackerEmpty : theme.trackerModule);
                r.drawText(Point2F(x + 10.0f * charW_, y), ct.controller[], FontId.mono, monoSize_,
                    ct.controllerEmpty ? theme.trackerEmpty : theme.trackerParam);
                r.drawText(Point2F(x + 12.0f * charW_, y), ct.effect[], FontId.mono, monoSize_,
                    ct.effectEmpty ? theme.trackerEmpty : theme.trackerEffect);
                r.drawText(Point2F(x + 15.0f * charW_, y), ct.value[], FontId.mono, monoSize_,
                    ct.valueEmpty ? theme.trackerEmpty : theme.trackerParam);
            }
        }

        immutable float gridBottom = g.y + (lastLine - firstLine) * rowH_;
        immutable float lineBottom = gridBottom < g.bottom() ? gridBottom : g.bottom();
        r.drawLine(Point2F(cellsX - 0.5f, colHeader.y), Point2F(cellsX - 0.5f, lineBottom), 1.0f, theme.border);
        foreach (t; firstTrack .. lastTrack) {
            immutable float x = cellsX + (t - firstTrack + 1) * cellW_ - 0.5f;
            r.drawLine(Point2F(x, colHeader.y), Point2F(x, lineBottom), 1.0f, theme.gridLine);
        }
    }
}
