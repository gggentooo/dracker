/**
 * File:         source/gui/views/skeleton_panel.d
 * Module:       gui.views.skeleton_panel
 * Phase:        Skeleton project generator — T20 (panel frame and project settings), T21 (chord progression),
 *               T22 (bass and piano module choice)
 *
 * Purpose:
 *   The "New Project from Skeleton" panel: a modal overlay (isModalOverlay(), and closesOnOutsideClick() is
 *   false, so a click outside it does nothing) that collects a SkeletonSpec. Its scrollable body has three
 *   sections:
 *     - Project (T20): title, BPM and ticks per line, time signature (numerator box + denominator dropdown), key
 *       (tonic dropdown named for the mode + mode dropdown).
 *     - Chord progression (T21): a chord text field (Return or Add parses with parseProgression() and appends the
 *       chords as one-bar blocks; a parse error is shown under the field and nothing is added), a preset dropdown
 *       of the key's mode with Insert (after the selected block, else at the end), and the block strip
 *       (ChordBlockStrip: "ii · Dm" and the length of each block; click to select; ←/→ select, ⌥←/⌥→ move,
 *       Delete removes) with Move ◀ / Move ▶ / Remove / length dropdown / Clear buttons and the total length.
 *       Labels follow the key: Roman-numeral blocks change their chord names, named chords keep theirs.
 *     - Instruments (T22): Bass and Piano dropdowns (instrumentChoices() plus "Load preset file…"), enabled only
 *       when there is at least one block. Loading a .msym preset that can play notes adds and selects a "Preset:
 *       <name>" entry; a failed or unsuitable file shows the reason and keeps the earlier choice.
 *   The footer shows why Create is disabled (validateSpec()'s reason, or that no onCreate handler is connected)
 *   (or the message of setCreateError() after a failed Create) and the Cancel and Create buttons. Escape or Cancel
 *   closes the panel; Create calls onCreate(spec) and closes when it returns true (StudioRoot's handler returns
 *   false and closes the panel itself once the project is open, since it may first ask about unsaved changes). Every key press is consumed (shortcuts and piano keys never reach the studio); Tab and
 *   Shift+Tab move focus through the panel's controls. onClosed receives the last spec so the next opening can
 *   show the same values.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. The panel never touches the session document; the only side effects are file dialogs and
 *   preset file reads for T22, and status messages.
 *
 * Dependencies:
 *   Internal: app.{chord_progression,music_theory,skeleton_gen}, gui.{renderer,theme,widgets},
 *             gui.views.studio_context, io.project_format, platform.interfaces
 *   External: none
 *
 * Planned API (Types, Functions & Hooks):
 *   - class ChordBlockStrip : Widget (blocks, key, selected, select(), moveSelected(), removeSelected(),
 *     blockRect(), contentWidth(), blockText(), onChanged)
 *   - class SkeletonPanel : Widget (this(StudioContext, SkeletonSpec), spec(), reason(), controls by field,
 *     addChords(), insertPreset(), moveSelected(), removeSelected(), setSelectedLength(), clearBlocks(),
 *     chooseInstrument(), loadInstrumentPreset(), chordError(), instrumentError(), totalText(), cancel(), create(),
 *     close(), setCreateError(), createError(), onCreate, onClosed)
 *
 * See_Also:
 *   docs/todo.md (T20, T21, T22), source/app/skeleton_gen.d, source/gui/views/appearance_panel.d
 */
module gui.views.skeleton_panel;

import app.chord_progression : BLOCK_HALF_BARS, chordLabel, ChordBlock, parseProgression, presetBlocks,
    presetLabel, presetsFor, ProgressionError, ProgressionPreset;
import app.music_theory : KeyMode, MusicalKey, tonicChoices;
import app.skeleton_gen : InstrumentChoice, InstrumentRole, InstrumentSource, instrumentChoices,
    isPlayableInstrument, SkeletonSpec, specLinesPerBar, totalLines, validateSpec;
import gui.renderer : FontId, IRenderer2D, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.widgets : Button, Dropdown, KeyCode, KeyEvent, MouseButton, MouseEvent, NumericDragBox, ScrollEvent,
    ScrollView, TextField, ValueRange, Widget;
import gui.views.studio_context : StudioContext;
import io.project_format : LoadedPreset, loadPresetFile;
import platform.interfaces : FileDialogFilter, KeyModifiers;

/**
 * Text of a block length in half bars ("½ bar", "1 bar", "2 bars", "4 bars").
 *
 * Params:
 *   halfBars = 1, 2, 4 or 8.
 *
 * Returns:
 *   Text.
 */
string lengthText(uint halfBars) @safe pure nothrow {
    switch (halfBars) {
        case 1:
            return "½ bar";
        case 2:
            return "1 bar";
        case 4:
            return "2 bars";
        case 8:
            return "4 bars";
        default:
            return "?";
    }
}

/**
 * Horizontal strip of chord blocks (T21). Each block is a box as wide as its length, showing the chord in both
 * forms and its length. Click selects; with focus, ←/→ select the previous/next block, ⌥←/⌥→ move the selected
 * block, Delete or Backspace removes it.
 */
final class ChordBlockStrip : Widget {
    enum float BLOCK_H = 46.0f;
    enum float GAP = 6.0f;
    enum float PAD = 4.0f;

    ChordBlock[] blocks;
    MusicalKey key;
    ptrdiff_t selected = -1;

    /**
     * Called after the selection or the blocks changed.
     */
    void delegate() onChanged;

    /**
     * Creates an empty strip.
     */
    this() {
        id = "skeleton.blocks";
        focusable = true;
    }

    /**
     * Returns the width of a block box.
     *
     * Params:
     *   halfBars = Block length.
     *
     * Returns:
     *   Points.
     */
    static float blockWidth(uint halfBars) @safe pure nothrow @nogc {
        return 60.0f + 30.0f * halfBars;
    }

    /**
     * Returns the width needed to show every block.
     *
     * Returns:
     *   Points (0 without blocks).
     */
    float contentWidth() const {
        if (blocks.length == 0) {
            return 0.0f;
        }
        float w = PAD;
        foreach (ref b; blocks) {
            w += blockWidth(b.halfBars) + GAP;
        }
        return w - GAP + PAD;
    }

    /**
     * Returns the box of block i in window coordinates.
     *
     * Params:
     *   i = Block index.
     *
     * Returns:
     *   Rectangle (empty for a bad index).
     */
    RectF blockRect(size_t i) const {
        if (i >= blocks.length) {
            return RectF.init;
        }
        float x = bounds.x + PAD;
        foreach (k; 0 .. i) {
            x += blockWidth(blocks[k].halfBars) + GAP;
        }
        return RectF(x, bounds.y + PAD, blockWidth(blocks[i].halfBars), BLOCK_H);
    }

    /**
     * Returns the two lines shown on block i: its label and its length.
     *
     * Params:
     *   i = Block index.
     *
     * Returns:
     *   [label, length] (empty strings for a bad index).
     */
    string[2] blockText(size_t i) const {
        if (i >= blocks.length) {
            return ["", ""];
        }
        return [chordLabel(blocks[i].chord, key), lengthText(blocks[i].halfBars)];
    }

    /**
     * Selects block i (or nothing with -1); out-of-range indices are clamped to the last block.
     *
     * Params:
     *   i = Index or -1.
     */
    void select(ptrdiff_t i) {
        if (blocks.length == 0 || i < 0) {
            selected = -1;
        } else {
            selected = i < cast(ptrdiff_t) blocks.length ? i : cast(ptrdiff_t) blocks.length - 1;
        }
        changed();
    }

    /**
     * Moves the selected block one place left (dir < 0) or right (dir > 0); the selection follows it.
     *
     * Params:
     *   dir = Direction.
     *
     * Returns:
     *   True if it moved.
     */
    bool moveSelected(int dir) {
        if (selected < 0) {
            return false;
        }
        immutable ptrdiff_t to = selected + (dir < 0 ? -1 : 1);
        if (to < 0 || to >= cast(ptrdiff_t) blocks.length) {
            return false;
        }
        ChordBlock t = blocks[to];
        blocks[to] = blocks[selected];
        blocks[selected] = t;
        selected = to;
        changed();
        return true;
    }

    /**
     * Removes the selected block; the block after it (else before it) becomes selected.
     *
     * Returns:
     *   True if a block was removed.
     */
    bool removeSelected() {
        if (selected < 0) {
            return false;
        }
        blocks = blocks[0 .. selected] ~ blocks[selected + 1 .. $];
        if (selected >= cast(ptrdiff_t) blocks.length) {
            selected = cast(ptrdiff_t) blocks.length - 1;
        }
        changed();
        return true;
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return false;
        }
        foreach (i; 0 .. blocks.length) {
            if (blockRect(i).contains(e.pos)) {
                select(cast(ptrdiff_t) i);
                return true;
            }
        }
        return true;
    }

    override bool onKeyDown(const ref KeyEvent e) {
        immutable bool alt = (e.modifiers & KeyModifiers.alt) != 0;
        switch (e.keyCode) {
            case KeyCode.left:
                if (alt) {
                    moveSelected(-1);
                } else if (blocks.length > 0) {
                    select(selected <= 0 ? 0 : selected - 1);
                }
                return true;
            case KeyCode.right:
                if (alt) {
                    moveSelected(1);
                } else if (blocks.length > 0) {
                    select(selected < 0 ? 0 : selected + 1);
                }
                return true;
            case KeyCode.deleteBackward:
            case KeyCode.forwardDelete:
                removeSelected();
                return true;
            default:
                return false;
        }
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        r.fillRoundedRect(bounds, theme.radiusSm, theme.panelSunken);
        r.strokeRoundedRect(bounds, theme.radiusSm, theme.borderWidth, isFocused() ? theme.focusRing : theme.border);
        immutable float bodySize = theme.fontSizeBody;
        immutable float small = theme.fontSizeSmall;
        if (blocks.length == 0) {
            immutable float lh = r.lineHeight(FontId.ui, small);
            r.drawText(Point2F(bounds.x + 10.0f, bounds.y + (bounds.h - lh) * 0.5f),
                "No chords yet: type them above or insert a preset", FontId.ui, small, theme.textDim);
            return;
        }
        foreach (i; 0 .. blocks.length) {
            immutable RectF b = blockRect(i);
            immutable bool sel = cast(ptrdiff_t) i == selected;
            r.fillRoundedRect(b, theme.radiusSm, sel ? theme.selection : theme.panelRaised);
            r.strokeRoundedRect(b, theme.radiusSm, sel ? 2.0f : theme.borderWidth, sel ? theme.accent : theme.border);
            immutable string[2] t = blockText(i);
            r.pushClip(b.inset(3.0f));
            r.drawText(Point2F(b.x + 7.0f, b.y + 5.0f), t[0], FontId.ui, bodySize, theme.text);
            r.drawText(Point2F(b.x + 7.0f, b.y + 5.0f + r.lineHeight(FontId.ui, bodySize) + 2.0f), t[1], FontId.ui, small,
                theme.textDim);
            r.popClip();
        }
    }

    private void changed() {
        invalidate();
        if (onChanged !is null) {
            onChanged();
        }
    }
}

/**
 * Scrollable form inside the panel; it delegates layout and label painting to the panel.
 */
private final class SkeletonForm : Widget {
    private SkeletonPanel panel_;

    /**
     * Creates the form of a panel.
     *
     * Params:
     *   p = Owning panel.
     */
    this(SkeletonPanel p) {
        panel_ = p;
    }

    override void layoutChildren() {
        panel_.arrangeForm(bounds);
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        panel_.paintForm(r, theme);
    }
}

private struct FormText {
    string text;
    float x;
    float y;
    bool heading;
}

/**
 * The skeleton project generator panel (see the module header).
 */
final class SkeletonPanel : Widget {
    enum float WIDTH = 720.0f;
    enum float HEIGHT = 640.0f;
    enum float HEADER_H = 44.0f;
    enum float FOOTER_H = 52.0f;
    enum float FORM_HEIGHT = 540.0f;
    enum float PAD = 16.0f;
    enum float LABEL_W = 130.0f;
    enum float ROW_H = 24.0f;
    enum string LOAD_PRESET_TEXT = "Load preset file…";

    TextField titleField;
    NumericDragBox bpmBox;
    NumericDragBox tplBox;
    NumericDragBox sigNumBox;
    Dropdown sigDenBox;
    Dropdown tonicBox;
    Dropdown modeBox;
    TextField chordField;
    Button addChordsButton;
    Dropdown presetBox;
    Button insertButton;
    ChordBlockStrip strip;
    ScrollView stripScroll;
    Button moveLeftButton;
    Button moveRightButton;
    Button removeButton;
    Dropdown lengthBox;
    Button clearButton;
    Dropdown bassBox;
    Dropdown pianoBox;
    ScrollView bodyView;
    Button cancelButton;
    Button createButton;

    /**
     * Called by Create with the current spec; returning true closes the panel. While null, Create is disabled.
     */
    bool delegate(const ref SkeletonSpec) onCreate;

    /**
     * Called once after the panel closed (Cancel, Escape, Create or dismissal) with the spec it showed last.
     */
    void delegate(SkeletonSpec) onClosed;

    private StudioContext ctx_;
    private SkeletonForm form_;
    private InstrumentChoice[][2] choices_;
    private size_t[2] chosen_;
    private string chordError_;
    private string instrumentError_;
    private string reason_;
    private string createError_;
    private bool closed_ = false;
    private FormText[] texts_;
    private RectF chordErrorRect_;
    private RectF totalRect_;
    private RectF instrumentNoteRect_;

    /**
     * Builds the panel showing initial.
     *
     * Params:
     *   ctx = Studio context (file dialogs for presets, status messages).
     *   initial = Values to show (the last spec of this run, or SkeletonSpec.init).
     */
    this(StudioContext ctx, SkeletonSpec initial) {
        ctx_ = ctx;
        id = "skeleton.panel";
        form_ = new SkeletonForm(this);
        bodyView = add(new ScrollView(form_));
        bodyView.id = "skeleton.body";
        bodyView.scrollHorizontal = false;
        bodyView.drawBackground = false;
        bodyView.contentSize = Point2F(0.0f, FORM_HEIGHT);

        titleField = formAdd(new TextField(initial.title), "skeleton.title");
        titleField.persistent = true;
        titleField.setText(initial.title, false);
        titleField.onEdit = (string t) { refreshState(); };
        bpmBox = formAdd(new NumericDragBox(ValueRange(20.0f, 999.0f, 125.0f, false, 0.1f), 1), "skeleton.bpm");
        bpmBox.setValue(cast(float) initial.bpm, false);
        bpmBox.onChange = (float v) { refreshState(); };
        tplBox = formAdd(new NumericDragBox(ValueRange(1.0f, 255.0f, 6.0f, false, 1.0f), 0), "skeleton.tpl");
        tplBox.pixelsPerStep = 8.0f;
        tplBox.setValue(cast(float) initial.ticksPerLine, false);
        tplBox.onChange = (float v) { refreshState(); };
        sigNumBox = formAdd(new NumericDragBox(ValueRange(1.0f, 16.0f, 4.0f, false, 1.0f), 0), "skeleton.sigNum");
        sigNumBox.pixelsPerStep = 8.0f;
        sigNumBox.setValue(cast(float) initial.timeSigNumerator, false);
        sigNumBox.onChange = (float v) { refreshState(); };
        sigDenBox = formAdd(new Dropdown(["2", "4", "8", "16"], denominatorIndex(initial.timeSigDenominator)),
            "skeleton.sigDen");
        sigDenBox.onSelect = (size_t i) { refreshState(); };
        modeBox = formAdd(new Dropdown(["Major", "Minor"], initial.key.mode == KeyMode.minor ? 1 : 0), "skeleton.mode");
        modeBox.onSelect = (size_t i) { onModeChanged(); };
        tonicBox = formAdd(new Dropdown(tonicItems(initial.key.mode), initial.key.tonic % 12), "skeleton.tonic");
        tonicBox.onSelect = (size_t i) { onKeyChanged(); };

        chordField = formAdd(new TextField(""), "skeleton.chords");
        chordField.persistent = true;
        chordField.setText("", false);
        chordField.onCommit = (string t) { addChords(t); };
        addChordsButton = formAdd(new Button("Add", () { addChords(chordField.text()); }), "skeleton.addChords");
        presetBox = formAdd(new Dropdown(presetLabels(initial.key.mode), 0), "skeleton.preset");
        insertButton = formAdd(new Button("Insert", &insertPreset), "skeleton.insertPreset");
        strip = new ChordBlockStrip();
        strip.blocks = initial.blocks.dup;
        strip.key = initial.key;
        strip.onChanged = &onStripChanged;
        stripScroll = formAdd(new ScrollView(strip), "skeleton.stripScroll");
        stripScroll.scrollVertical = false;
        stripScroll.drawBackground = false;
        moveLeftButton = formAdd(new Button("◀ Move", () { moveSelected(-1); }), "skeleton.moveLeft");
        moveRightButton = formAdd(new Button("Move ▶", () { moveSelected(1); }), "skeleton.moveRight");
        removeButton = formAdd(new Button("Remove", &removeSelected), "skeleton.remove");
        lengthBox = formAdd(new Dropdown(["½ bar", "1 bar", "2 bars", "4 bars"], 1), "skeleton.length");
        lengthBox.onSelect = (size_t i) { setSelectedLength(BLOCK_HALF_BARS[i]); };
        clearButton = formAdd(new Button("Clear", &clearBlocks), "skeleton.clear");

        choices_[0] = instrumentChoices();
        choices_[1] = instrumentChoices();
        chosen_[0] = adoptChoice(0, initial.bass);
        chosen_[1] = adoptChoice(1, initial.piano);
        bassBox = formAdd(new Dropdown(instrumentItems(0), chosen_[0]), "skeleton.bass");
        bassBox.onSelect = (size_t i) { chooseInstrument(InstrumentRole.bass, i); };
        pianoBox = formAdd(new Dropdown(instrumentItems(1), chosen_[1]), "skeleton.piano");
        pianoBox.onSelect = (size_t i) { chooseInstrument(InstrumentRole.piano, i); };

        cancelButton = add(new Button("Cancel", &cancel));
        cancelButton.id = "skeleton.cancel";
        createButton = add(new Button("Create", () { create(); }));
        createButton.id = "skeleton.create";
        onStripChanged();
    }

    /**
     * Returns the settings the panel shows now.
     *
     * Returns:
     *   Spec (blocks and instrument choices are copies).
     */
    SkeletonSpec spec() {
        SkeletonSpec s;
        s.title = titleField.text();
        s.bpm = cast(double) cast(long)(bpmBox.value() * 10.0f + 0.5f) / 10.0;
        s.ticksPerLine = cast(uint)(tplBox.value() + 0.5f);
        s.timeSigNumerator = cast(uint)(sigNumBox.value() + 0.5f);
        s.timeSigDenominator = [2u, 4u, 8u, 16u][sigDenBox.selectedIndex < 4 ? sigDenBox.selectedIndex : 1];
        s.key = currentKey();
        s.blocks = strip.blocks.dup;
        s.bass = choices_[0][chosen_[0]];
        s.piano = choices_[1][chosen_[1]];
        return s;
    }

    /**
     * Returns why Create is disabled.
     *
     * Returns:
     *   Reason, or "" when Create is enabled.
     */
    string reason() {
        refreshState();
        return reason_;
    }

    /**
     * Shows why creating the project failed (in the footer, until the next Create); Create stays enabled.
     *
     * Params:
     *   message = Sentence, or "" to clear.
     */
    void setCreateError(string message) {
        createError_ = message;
        invalidate();
    }

    /**
     * Returns the message set by setCreateError().
     *
     * Returns:
     *   Text ("" when none).
     */
    string createError() const {
        return createError_;
    }

    /**
     * Closes the panel (onClosed receives the current spec).
     */
    void close() {
        closePanel();
    }

    /**
     * Returns the error of the last chord entry ("" when it parsed).
     *
     * Returns:
     *   Text.
     */
    string chordError() const {
        return chordError_;
    }

    /**
     * Returns the error of the last instrument preset load ("" when none).
     *
     * Returns:
     *   Text.
     */
    string instrumentError() const {
        return instrumentError_;
    }

    /**
     * Returns the total-length text shown under the strip ("3 bars · 48 lines").
     *
     * Returns:
     *   Text ("" without blocks).
     */
    string totalText() {
        if (strip.blocks.length == 0) {
            return "";
        }
        uint halves = 0;
        foreach (ref b; strip.blocks) {
            halves += b.halfBars;
        }
        SkeletonSpec s = spec();
        immutable string bars = uintText(halves / 2) ~ (halves % 2 == 1 ? "½" : "");
        return bars ~ (halves == 2 ? " bar" : " bars") ~ " · " ~ uintText(cast(uint) totalLines(s)) ~ " lines";
    }

    /**
     * Parses chord text and appends its chords as one-bar blocks; on success the chord field is cleared and the
     * last new block selected, on failure the error is shown and nothing is added.
     *
     * Params:
     *   text = Progression text.
     *
     * Returns:
     *   True if the text parsed (empty text adds nothing and returns true).
     */
    bool addChords(string text) {
        ChordBlock[] added;
        ProgressionError e;
        if (!parseProgression(text, added, e)) {
            chordError_ = e.message;
            invalidate();
            return false;
        }
        chordError_ = null;
        chordField.setText("", false);
        if (added.length > 0) {
            strip.blocks ~= added;
            strip.select(cast(ptrdiff_t) strip.blocks.length - 1);
        }
        refreshState();
        return true;
    }

    /**
     * Inserts the chosen preset's blocks after the selected block, or at the end; the last inserted block becomes
     * selected.
     */
    void insertPreset() {
        const(ProgressionPreset)[] list = presetsFor(currentKey().mode);
        if (presetBox.selectedIndex >= list.length) {
            return;
        }
        ChordBlock[] added = presetBlocks(list[presetBox.selectedIndex]);
        immutable size_t at = strip.selected >= 0 ? cast(size_t) strip.selected + 1 : strip.blocks.length;
        strip.blocks = strip.blocks[0 .. at] ~ added ~ strip.blocks[at .. $];
        strip.select(cast(ptrdiff_t)(at + added.length) - 1);
    }

    /**
     * Moves the selected block left or right.
     *
     * Params:
     *   dir = -1 left, +1 right.
     */
    void moveSelected(int dir) {
        strip.moveSelected(dir);
    }

    /**
     * Removes the selected block.
     */
    void removeSelected() {
        strip.removeSelected();
    }

    /**
     * Sets the length of the selected block.
     *
     * Params:
     *   halfBars = 1, 2, 4 or 8.
     */
    void setSelectedLength(ubyte halfBars) {
        if (strip.selected < 0) {
            return;
        }
        strip.blocks[strip.selected].halfBars = halfBars;
        onStripChanged();
    }

    /**
     * Removes every block.
     */
    void clearBlocks() {
        strip.blocks = null;
        strip.select(-1);
    }

    /**
     * Chooses entry i of an instrument dropdown; the last entry ("Load preset file…") loads a preset instead.
     *
     * Params:
     *   role = Bass or piano.
     *   i = Dropdown index.
     */
    void chooseInstrument(InstrumentRole role, size_t i) {
        immutable size_t r = role == InstrumentRole.bass ? 0 : 1;
        if (i >= choices_[r].length) {
            loadInstrumentPreset(role);
            return;
        }
        chosen_[r] = i;
        instrumentError_ = null;
        refreshState();
    }

    /**
     * Asks for a .msym file and makes its module the role's instrument. The file must load and hold a module that
     * can play notes; otherwise the reason is shown and the earlier choice stays.
     *
     * Params:
     *   role = Bass or piano.
     *
     * Returns:
     *   True if a preset was added and chosen.
     */
    bool loadInstrumentPreset(InstrumentRole role) {
        immutable size_t r = role == InstrumentRole.bass ? 0 : 1;
        scope (exit) {
            dropdownOf(r).items = instrumentItems(r);
            dropdownOf(r).select(chosen_[r], false);
            refreshState();
        }
        if (ctx_.dialogs is null) {
            instrumentError_ = "File dialogs are not available";
            return false;
        }
        string path;
        static immutable FileDialogFilter[] filters = [FileDialogFilter("Dracker Module Preset", ["msym"])];
        if (!ctx_.dialogs.openFile(role == InstrumentRole.bass ? "Load Bass Preset" : "Load Piano Preset", filters,
                path)) {
            return false;
        }
        LoadedPreset preset;
        string err;
        if (!loadPresetFile(path, preset, err)) {
            instrumentError_ = "Could not load preset: " ~ err;
            return false;
        }
        if (!isPlayableInstrument(preset.mod.typeId)) {
            instrumentError_ = "\"" ~ preset.presetName ~ "\" cannot play notes; choose a synth preset";
            return false;
        }
        choices_[r] ~= InstrumentChoice.ofPreset(preset);
        chosen_[r] = choices_[r].length - 1;
        instrumentError_ = null;
        return true;
    }

    /**
     * Closes the panel without creating anything.
     */
    void cancel() {
        closePanel();
    }

    /**
     * Creates the project through onCreate when the spec is valid; closes the panel when onCreate returns true.
     *
     * Returns:
     *   True if onCreate accepted the spec.
     */
    bool create() {
        createError_ = null;
        if (reason().length > 0) {
            return false;
        }
        SkeletonSpec s = spec();
        if (!onCreate(s)) {
            refreshState();
            return false;
        }
        closePanel();
        return true;
    }

    override bool isModalOverlay() const {
        return true;
    }

    override bool closesOnOutsideClick() const {
        return false;
    }

    override void onDismissed() {
        if (closed_) {
            return;
        }
        closed_ = true;
        if (onClosed !is null) {
            onClosed(spec());
        }
    }

    override bool onKeyDown(const ref KeyEvent e) {
        if (e.keyCode == KeyCode.escape) {
            cancel();
            return true;
        }
        if (e.keyCode == KeyCode.tab) {
            cycleFocus(e.shift() ? -1 : 1);
            return true;
        }
        return true;
    }

    override bool onKeyUp(const ref KeyEvent e) {
        return true;
    }

    override bool onTextInput(dchar c) {
        return true;
    }

    override bool onMouseDown(const ref MouseEvent e) {
        return true;
    }

    override bool onScroll(const ref ScrollEvent e) {
        return true;
    }

    override void layoutChildren() {
        bodyView.arrange(RectF(bounds.x + 2.0f, bounds.y + HEADER_H, bounds.w - 4.0f,
            bounds.h - HEADER_H - FOOTER_H > 0.0f ? bounds.h - HEADER_H - FOOTER_H : 0.0f));
        immutable float by = bounds.bottom() - PAD - ROW_H;
        createButton.arrange(RectF(bounds.right() - PAD - 100.0f, by, 100.0f, ROW_H));
        cancelButton.arrange(RectF(bounds.right() - PAD - 208.0f, by, 100.0f, ROW_H));
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        refreshState();
        r.fillRoundedRect(bounds.translate(0.0f, 4.0f), theme.radiusLg, theme.shadow);
        r.fillRoundedRect(bounds, theme.radiusLg, theme.panel);
        r.strokeRoundedRect(bounds, theme.radiusLg, 2.0f, theme.borderStrong);
        r.drawText(Point2F(bounds.x + PAD, bounds.y + 14.0f), "New Project from Skeleton", FontId.ui,
            theme.fontSizeTitle, theme.text);
        r.fillRect(RectF(bounds.x, bounds.y + HEADER_H - 1.0f, bounds.w, 1.0f), theme.border);
        immutable float fy = bounds.bottom() - FOOTER_H;
        r.fillRect(RectF(bounds.x, fy, bounds.w, 1.0f), theme.border);
        immutable string footer = reason_.length > 0 ? reason_ : createError_;
        if (footer.length > 0) {
            immutable float small = theme.fontSizeSmall;
            immutable RectF rr = RectF(bounds.x + PAD, fy + 1.0f, cancelButton.bounds.x - bounds.x - 2.0f * PAD,
                FOOTER_H - 2.0f);
            r.pushClip(rr);
            r.drawText(Point2F(rr.x, rr.y + (rr.h - r.lineHeight(FontId.ui, small)) * 0.5f), footer, FontId.ui, small,
                theme.danger);
            r.popClip();
        }
    }

    /**
     * Lays out the form's controls inside the scrolled form rectangle (called by the form; does nothing while the
     * constructor is still creating the controls).
     *
     * Params:
     *   b = Form bounds.
     */
    package void arrangeForm(RectF b) {
        if (pianoBox is null) {
            return;
        }
        texts_ = null;
        immutable float x0 = b.x + PAD;
        immutable float cx = x0 + LABEL_W;
        immutable float fullW = b.w - 2.0f * PAD;
        float y = b.y + 8.0f;
        heading("Project", x0, y);
        y += 26.0f;
        label("Title", x0, y);
        titleField.arrange(RectF(cx, y, 320.0f, ROW_H));
        y += 34.0f;
        label("Tempo", x0, y);
        bpmBox.arrange(RectF(cx, y, 70.0f, ROW_H));
        label("BPM", cx + 76.0f, y);
        tplBox.arrange(RectF(cx + 120.0f, y, 50.0f, ROW_H));
        label("ticks per line", cx + 176.0f, y);
        y += 34.0f;
        label("Time signature", x0, y);
        sigNumBox.arrange(RectF(cx, y, 44.0f, ROW_H));
        label("/", cx + 50.0f, y);
        sigDenBox.arrange(RectF(cx + 62.0f, y, 56.0f, ROW_H));
        y += 34.0f;
        label("Key", x0, y);
        tonicBox.arrange(RectF(cx, y, 70.0f, ROW_H));
        modeBox.arrange(RectF(cx + 76.0f, y, 100.0f, ROW_H));
        y += 44.0f;
        heading("Chord progression", x0, y);
        y += 26.0f;
        label("Chords", x0, y);
        chordField.arrange(RectF(cx, y, 380.0f, ROW_H));
        addChordsButton.arrange(RectF(cx + 388.0f, y, 70.0f, ROW_H));
        y += 28.0f;
        chordErrorRect_ = RectF(cx, y, fullW - LABEL_W, 18.0f);
        y += 22.0f;
        label("Preset", x0, y);
        presetBox.arrange(RectF(cx, y, 380.0f, ROW_H));
        insertButton.arrange(RectF(cx + 388.0f, y, 70.0f, ROW_H));
        y += 34.0f;
        stripScroll.arrange(RectF(x0, y, fullW, ChordBlockStrip.BLOCK_H + 2.0f * ChordBlockStrip.PAD + 10.0f));
        y += ChordBlockStrip.BLOCK_H + 2.0f * ChordBlockStrip.PAD + 18.0f;
        float bx = x0;
        Widget[5] row = [moveLeftButton, moveRightButton, removeButton, lengthBox, clearButton];
        static immutable float[5] widths = [90.0f, 90.0f, 80.0f, 90.0f, 70.0f];
        foreach (i, w; row) {
            w.arrange(RectF(bx, y, widths[i], ROW_H));
            bx += widths[i] + 6.0f;
        }
        totalRect_ = RectF(bx + 10.0f, y, b.right() - PAD - bx - 10.0f, ROW_H);
        y += 44.0f;
        heading("Instruments", x0, y);
        y += 26.0f;
        label("Bass", x0, y);
        bassBox.arrange(RectF(cx, y, 260.0f, ROW_H));
        y += 34.0f;
        label("Piano", x0, y);
        pianoBox.arrange(RectF(cx, y, 260.0f, ROW_H));
        y += 30.0f;
        instrumentNoteRect_ = RectF(cx, y, fullW - LABEL_W, 18.0f);
    }

    /**
     * Paints the form's headings, labels, chord error, total and instrument note (called by the form).
     *
     * Params:
     *   r = Renderer.
     *   theme = Theme.
     */
    package void paintForm(IRenderer2D r, const ref StudioTheme theme) {
        immutable float bodySize = theme.fontSizeBody;
        immutable float small = theme.fontSizeSmall;
        immutable float lh = r.lineHeight(FontId.ui, bodySize);
        foreach (ref t; texts_) {
            if (t.heading) {
                r.drawText(Point2F(t.x, t.y), t.text, FontId.ui, theme.fontSizeTitle, theme.text);
            } else {
                r.drawText(Point2F(t.x, t.y + (ROW_H - lh) * 0.5f), t.text, FontId.ui, bodySize, theme.textDim);
            }
        }
        void line(RectF rr, string text, bool error) {
            if (text.length == 0) {
                return;
            }
            r.pushClip(rr);
            r.drawText(Point2F(rr.x, rr.y), text, FontId.ui, small, error ? theme.danger : theme.textDim);
            r.popClip();
        }
        line(chordErrorRect_, chordError_.length > 0 ? chordError_
            : "Roman numerals (ii V7 I) or chord names (Dm7 G7 C/E), separated by spaces, commas or ->", chordError_.length > 0);
        immutable string total = totalText();
        if (total.length > 0) {
            r.drawText(Point2F(totalRect_.x, totalRect_.y + (ROW_H - lh) * 0.5f), total, FontId.ui, bodySize, theme.text);
        }
        line(instrumentNoteRect_, instrumentError_.length > 0 ? instrumentError_
            : (strip.blocks.length == 0 ? "Add chords to get a bass and a piano; without chords the project has one empty pattern" : ""),
            instrumentError_.length > 0);
    }

    private T formAdd(T)(T w, string wid) {
        w.id = wid;
        return form_.add(w);
    }

    private void heading(string t, float x, float y) {
        texts_ ~= FormText(t, x, y, true);
    }

    private void label(string t, float x, float y) {
        texts_ ~= FormText(t, x, y, false);
    }

    private MusicalKey currentKey() {
        return MusicalKey(cast(ubyte)(tonicBox.selectedIndex % 12),
            modeBox.selectedIndex == 1 ? KeyMode.minor : KeyMode.major);
    }

    private void onModeChanged() {
        immutable MusicalKey k = currentKey();
        tonicBox.items = tonicItems(k.mode);
        presetBox.items = presetLabels(k.mode);
        presetBox.select(0, false);
        onKeyChanged();
    }

    private void onKeyChanged() {
        strip.key = currentKey();
        strip.invalidate();
        refreshState();
    }

    private void onStripChanged() {
        stripScroll.contentSize = Point2F(strip.contentWidth(), 0.0f);
        stripScroll.layoutChildren();
        if (strip.selected >= 0) {
            stripScroll.ensureVisible(strip.blockRect(cast(size_t) strip.selected));
            immutable ubyte h = strip.blocks[strip.selected].halfBars;
            foreach (i, v; BLOCK_HALF_BARS) {
                if (v == h) {
                    lengthBox.select(i, false);
                }
            }
        }
        immutable bool sel = strip.selected >= 0;
        moveLeftButton.enabled = sel && strip.selected > 0;
        moveRightButton.enabled = sel && strip.selected + 1 < cast(ptrdiff_t) strip.blocks.length;
        removeButton.enabled = sel;
        lengthBox.enabled = sel;
        clearButton.enabled = strip.blocks.length > 0;
        refreshState();
    }

    private void refreshState() {
        immutable bool any = strip.blocks.length > 0;
        bassBox.enabled = any;
        pianoBox.enabled = any;
        SkeletonSpec s = spec();
        string why;
        if (!validateSpec(s, why)) {
            reason_ = why;
        } else if (onCreate is null) {
            reason_ = "Creating a project is not connected yet";
        } else {
            reason_ = null;
        }
        createButton.enabled = reason_.length == 0;
        invalidate();
    }

    private size_t adoptChoice(size_t r, const ref InstrumentChoice c) {
        final switch (c.source) {
            case InstrumentSource.defaultSound:
                return 0;
            case InstrumentSource.moduleType:
                foreach (i, ref x; choices_[r]) {
                    if (x.source == InstrumentSource.moduleType && x.typeId == c.typeId) {
                        return i;
                    }
                }
                return 0;
            case InstrumentSource.presetFile:
                choices_[r] ~= cast(InstrumentChoice) c;
                return choices_[r].length - 1;
        }
    }

    private string[] instrumentItems(size_t r) {
        string[] items;
        foreach (ref c; choices_[r]) {
            items ~= c.label();
        }
        return items ~ LOAD_PRESET_TEXT;
    }

    private Dropdown dropdownOf(size_t r) {
        return r == 0 ? bassBox : pianoBox;
    }

    private void closePanel() {
        if (auto c = context()) {
            c.closeOverlay(this);
        } else {
            onDismissed();
        }
    }

    private void cycleFocus(int dir) {
        Widget[] order;
        void collect(Widget w) {
            if (!w.visible || !w.enabled) {
                return;
            }
            if (w.focusable && w !is this) {
                order ~= w;
            }
            foreach (c; w.children()) {
                collect(c);
            }
        }
        collect(this);
        auto c = context();
        if (order.length == 0 || c is null) {
            return;
        }
        ptrdiff_t at = -1;
        foreach (i, w; order) {
            if (w is c.focused) {
                at = cast(ptrdiff_t) i;
            }
        }
        immutable ptrdiff_t n = cast(ptrdiff_t) order.length;
        immutable ptrdiff_t next = at < 0 ? (dir > 0 ? 0 : n - 1) : ((at + dir) % n + n) % n;
        c.setFocus(order[next]);
        bodyView.ensureVisible(order[next].bounds);
    }

    private static string[] tonicItems(KeyMode mode) {
        string[12] names = tonicChoices(mode);
        return names[].dup;
    }

    private static string[] presetLabels(KeyMode mode) {
        string[] items;
        foreach (ref p; presetsFor(mode)) {
            items ~= presetLabel(p);
        }
        return items;
    }

    private static size_t denominatorIndex(uint den) {
        switch (den) {
            case 2:
                return 0;
            case 8:
                return 2;
            case 16:
                return 3;
            default:
                return 1;
        }
    }

    private static string uintText(uint v) {
        if (v < 10) {
            return [cast(immutable char)('0' + v)];
        }
        return uintText(v / 10) ~ uintText(v % 10);
    }
}
