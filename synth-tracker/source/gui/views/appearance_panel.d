/**
 * File:         source/gui/views/appearance_panel.d
 * Module:       gui.views.appearance_panel
 * Phase:        Phase 8.5.5 — In-App Appearance Panel
 *
 * Purpose:
 *   Modal toolkit overlay (opened from SynthTracker ▸ Settings…, View ▸ Appearance… or Cmd+,) that edits the
 *   appearance with live preview: UI font (Atkinson Hyperlegible Next first), monospace font (fixed-pitch
 *   families only, Fira Code first), High/Low contrast, palette preset, and a custom palette editor (token
 *   groups as swatches, R/G/B/A NumericDragBoxes for the selected token, and a live contrast readout of every
 *   pair the token takes part in, flagging pairs below target with text as well as color). Buttons duplicate a
 *   preset into a custom palette, rename it to the next numbered name, delete it, reset it to its preset, and
 *   import/export .stpalette files through IFileDialog. OK persists the settings; Revert restores the
 *   appearance the panel opened with; dismissing the overlay keeps (and persists) the previewed state.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Every change goes through StudioContext.applyAppearance().
 *
 * Dependencies:
 *   Internal: gui.{appearance,renderer,theme,widgets}, gui.views.studio_context, platform.interfaces
 *   External: std.file, std.format
 *
 * Planned API (Types, Functions & Hooks):
 *   - class AppearancePanel : Widget (this(StudioContext), refresh(), ok(), revert(), selectToken(), duplicate(),
 *     renameCustom(), deleteCustom(), resetCustom(), importPalette(), exportPalette(), readout(), controlRect(id),
 *     onClosed, forwardKey)
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.5)
 */
module gui.views.appearance_panel;

import std.format : format;

import gui.appearance;
import gui.renderer : ColorRGBA, FontId, IRenderer2D, Point2F, RectF;
import gui.theme : colorToken, colorTokenIndex, ContrastMode, StudioTheme, THEME_COLOR_TOKENS;
import gui.views.studio_context : StudioContext;
import gui.widgets : Button, Dropdown, fillCircle, KeyEvent, MouseButton, MouseEvent, NumericDragBox, ValueRange, Widget;
import platform.interfaces : FileDialogFilter, KeyModifiers;

/**
 * Appearance settings overlay.
 */
final class AppearancePanel : Widget {
    enum float WIDTH = 640.0f;
    enum float HEIGHT = 600.0f;
    enum float LABEL_W = 150.0f;
    enum size_t READOUT_LINES = 7;

    Dropdown uiFont;
    Dropdown monoFont;
    Dropdown contrast;
    Dropdown palette;
    Dropdown group;
    Dropdown token;
    Button duplicateBtn;
    Button renameBtn;
    Button deleteBtn;
    Button resetBtn;
    Button importBtn;
    Button exportBtn;
    Button revertBtn;
    Button okBtn;
    NumericDragBox[4] channels;

    /**
     * Called after the panel closed (OK, Revert or dismissal).
     */
    void delegate() onClosed;

    /**
     * Receives Cmd-modified key presses so menu shortcuts keep working while the panel is open.
     */
    bool delegate(const ref KeyEvent) forwardKey;

    private StudioContext ctx_;
    private AppearanceSettings snapshot_;
    private string[] uiFamilies_;
    private string[] monoFamilies_;
    private string[] paletteNames_;
    private TokenGroup[] groups_;
    private size_t groupIndex_ = 0;
    private size_t tokenIndex_ = 0;
    private bool resolved_ = false;
    private bool syncing_ = false;
    private RectF[] swatchRects_;
    private RectF readoutRect_;
    private RectF hintRect_;

    /**
     * Builds the panel over ctx and remembers the current appearance for Revert.
     *
     * Params:
     *   ctx = Studio context.
     */
    this(StudioContext ctx) {
        ctx_ = ctx;
        id = "appearance.panel";
        snapshot_ = ctx.appearance;
        groups_ = tokenGroups();
        uiFamilies_ = orderedFamilies(false, DEFAULT_UI_FONT);
        monoFamilies_ = orderedFamilies(true, DEFAULT_MONO_FONT);
        uiFont = addDropdown("appearance.uiFont", uiFamilies_, &onUiFont);
        monoFont = addDropdown("appearance.monoFont", monoFamilies_, &onMonoFont);
        contrast = addDropdown("appearance.contrast", ["High contrast (7:1 text)", "Low contrast (4.5:1 text)"],
            &onContrast);
        palette = addDropdown("appearance.palette", [DEFAULT_PALETTE], &onPalette);
        string[] gnames;
        foreach (ref g; groups_) {
            gnames ~= g.name;
        }
        group = addDropdown("appearance.group", gnames, &onGroup);
        token = addDropdown("appearance.token", groups_[0].tokens.dup, &onToken);
        duplicateBtn = addButton("appearance.duplicate", "Duplicate → Custom", &duplicate);
        renameBtn = addButton("appearance.rename", "Rename", &renameCustom);
        deleteBtn = addButton("appearance.delete", "Delete", &deleteCustom);
        resetBtn = addButton("appearance.reset", "Reset", &resetCustom);
        importBtn = addButton("appearance.import", "Import…", &importPalette);
        exportBtn = addButton("appearance.export", "Export…", &exportPalette);
        revertBtn = addButton("appearance.revert", "Revert", &revert);
        okBtn = addButton("appearance.ok", "OK", &ok);
        static immutable string[4] chNames = ["appearance.red", "appearance.green", "appearance.blue", "appearance.alpha"];
        foreach (i; 0 .. 4) {
            NumericDragBox b = new NumericDragBox(ValueRange(0.0f, 255.0f, 0.0f, false, 1.0f), 0);
            b.id = chNames[i];
            b.onChange = channelHandler(i);
            channels[i] = add(b);
        }
        refresh();
    }

    /**
     * Re-reads the context's appearance into every control (without applying anything).
     */
    void refresh() {
        syncing_ = true;
        scope (exit) syncing_ = false;
        const s = ctx_.appearance;
        paletteNames_ = null;
        foreach (p; builtinPalettes()) {
            paletteNames_ ~= p.name;
        }
        foreach (ref p; s.customPalettes) {
            paletteNames_ ~= p.name;
        }
        palette.items = paletteNames_.dup;
        palette.select(indexOf(paletteNames_, s.palette), false);
        uiFont.select(indexOf(uiFamilies_, s.uiFont), false);
        monoFont.select(indexOf(monoFamilies_, s.monoFont), false);
        contrast.select(s.contrast == ContrastMode.high ? 0 : 1, false);
        group.select(groupIndex_, false);
        token.items = groups_[groupIndex_].tokens.dup;
        token.select(tokenIndex_, false);
        immutable bool custom = isCustom();
        renameBtn.enabled = custom;
        deleteBtn.enabled = custom;
        resetBtn.enabled = custom;
        duplicateBtn.enabled = s.customPalettes.length < MAX_CUSTOM_PALETTES;
        importBtn.enabled = ctx_.dialogs !is null && s.customPalettes.length < MAX_CUSTOM_PALETTES;
        exportBtn.enabled = ctx_.dialogs !is null;
        immutable ColorRGBA c = selectedColor();
        immutable float[4] v = [c.r, c.g, c.b, c.a];
        foreach (i; 0 .. 4) {
            channels[i].enabled = custom;
            channels[i].setValue(cast(float) cast(int)(v[i] * 255.0f + 0.5f), false);
        }
        invalidate();
    }

    /**
     * Returns the name of the token being edited.
     *
     * Returns:
     *   Token name.
     */
    string selectedToken() const {
        return groups_[groupIndex_].tokens[tokenIndex_];
    }

    /**
     * Selects a token for editing by name.
     *
     * Params:
     *   name = Token name.
     *
     * Returns:
     *   False when the token is unknown.
     */
    bool selectToken(string name) {
        foreach (gi, ref g; groups_) {
            foreach (ti, t; g.tokens) {
                if (t == name) {
                    groupIndex_ = gi;
                    tokenIndex_ = ti;
                    refresh();
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * Returns the live contrast readout for the selected token, worst pair first.
     *
     * Returns:
     *   Readings.
     */
    ContrastReading[] readout() const {
        return contrastReadout(ctx_.theme, selectedToken());
    }

    /**
     * Returns a control's rectangle by widget id (also "appearance.swatchN" and "appearance.readout").
     *
     * Params:
     *   wid = Widget id.
     *
     * Returns:
     *   Rectangle (empty when unknown).
     */
    RectF controlRect(string wid) {
        import std.conv : to;

        if (wid == "appearance.readout") {
            return readoutRect_;
        }
        enum string sw = "appearance.swatch";
        if (wid.length > sw.length && wid[0 .. sw.length] == sw) {
            try {
                immutable size_t i = to!size_t(wid[sw.length .. $]);
                return i < swatchRects_.length ? swatchRects_[i] : RectF.init;
            } catch (Exception) {
                return RectF.init;
            }
        }
        foreach (c; children) {
            if (c.id == wid) {
                return c.bounds;
            }
        }
        return RectF.init;
    }

    /**
     * Persists the previewed appearance and closes.
     */
    void ok() {
        resolved_ = true;
        string err;
        if (ctx_.appearanceStore !is null && !ctx_.saveAppearance(err)) {
            ctx_.setStatus("Could not save appearance: " ~ err);
        } else {
            ctx_.setStatus("Appearance saved");
        }
        close();
    }

    /**
     * Restores the appearance the panel opened with and closes.
     */
    void revert() {
        resolved_ = true;
        ctx_.applyAppearance(snapshot_, false);
        ctx_.setStatus("Appearance reverted");
        close();
    }

    /**
     * Copies the selected palette into a new custom palette and selects it.
     */
    void duplicate() {
        AppearanceSettings s = ctx_.appearance;
        immutable string n = duplicateAsCustom(s, s.palette);
        if (n is null) {
            ctx_.setStatus("Custom palette limit reached");
            return;
        }
        apply(s);
        ctx_.setStatus("Created " ~ n);
    }

    /**
     * Renames the selected custom palette to the next free numbered name.
     */
    void renameCustom() {
        AppearanceSettings s = ctx_.appearance;
        immutable string n = renameCustomNext(s, s.palette);
        if (n !is null) {
            apply(s);
        }
    }

    /**
     * Deletes the selected custom palette.
     */
    void deleteCustom() {
        AppearanceSettings s = ctx_.appearance;
        if (gui.appearance.deleteCustom(s, s.palette)) {
            apply(s);
        }
    }

    /**
     * Resets the selected custom palette to the preset it was copied from.
     */
    void resetCustom() {
        AppearanceSettings s = ctx_.appearance;
        if (gui.appearance.resetCustom(s, s.palette)) {
            apply(s);
        }
    }

    /**
     * Imports a .stpalette file as a custom palette.
     */
    void importPalette() {
        import std.file : getSize, read;

        string path;
        if (ctx_.dialogs is null || !ctx_.dialogs.openFile("Import Palette", paletteFilters(), path)) {
            return;
        }
        string text;
        try {
            if (getSize(path) > MAX_APPEARANCE_BYTES) {
                ctx_.setStatus("Import failed: palette file too large");
                return;
            }
            text = cast(string) read(path);
        } catch (Exception e) {
            ctx_.setStatus("Import failed: " ~ e.msg);
            return;
        }
        PaletteSpec p;
        string err;
        if (!decodePalette(text, p, err)) {
            ctx_.setStatus("Import failed: " ~ err);
            return;
        }
        AppearanceSettings s = ctx_.appearance;
        immutable string n = addImportedPalette(s, p);
        if (n is null) {
            ctx_.setStatus("Custom palette limit reached");
            return;
        }
        apply(s);
        ctx_.setStatus("Imported " ~ n);
    }

    /**
     * Exports the selected palette to a .stpalette file.
     */
    void exportPalette() {
        import std.file : write;

        PaletteSpec p;
        if (ctx_.dialogs is null || !findPalette(ctx_.appearance, ctx_.appearance.palette, p)) {
            return;
        }
        string path;
        if (!ctx_.dialogs.saveFile("Export Palette", p.name ~ ".stpalette", paletteFilters(), path)) {
            return;
        }
        try {
            write(path, encodePalette(p));
            ctx_.setStatus("Exported " ~ p.name);
        } catch (Exception e) {
            ctx_.setStatus("Export failed: " ~ e.msg);
        }
    }

    override void onDismissed() {
        if (!resolved_) {
            resolved_ = true;
            string err;
            if (ctx_.appearanceStore !is null && !ctx_.saveAppearance(err)) {
                ctx_.setStatus("Could not save appearance: " ~ err);
            }
        }
        if (onClosed !is null) {
            onClosed();
        }
    }

    override bool onKeyDown(const ref KeyEvent e) {
        if ((e.modifiers & KeyModifiers.command) != 0 && forwardKey !is null) {
            return forwardKey(e);
        }
        return false;
    }

    override bool onMouseDown(const ref MouseEvent e) {
        if (e.button != MouseButton.left) {
            return true;
        }
        foreach (i, r; swatchRects_) {
            if (r.contains(e.pos)) {
                tokenIndex_ = i;
                refresh();
                return true;
            }
        }
        return true;
    }

    override void layoutChildren() {
        immutable float pad = 16.0f;
        immutable float ch = 22.0f;
        immutable float row = ch + 10.0f;
        immutable float x0 = bounds.x + pad;
        immutable float cx = x0 + LABEL_W;
        immutable float cw = bounds.w - 2.0f * pad - LABEL_W;
        float y = bounds.y + 48.0f;
        uiFont.arrange(RectF(cx, y, cw, ch));
        y += row;
        monoFont.arrange(RectF(cx, y, cw, ch));
        y += row;
        contrast.arrange(RectF(cx, y, cw, ch));
        y += row;
        palette.arrange(RectF(cx, y, cw, ch));
        y += row;
        Button[6] pb = [duplicateBtn, renameBtn, deleteBtn, resetBtn, importBtn, exportBtn];
        immutable float[6] widths = [150.0f, 70.0f, 64.0f, 58.0f, 74.0f, 74.0f];
        float bx = cx;
        foreach (i, b; pb) {
            b.arrange(RectF(bx, y, widths[i], ch));
            bx += widths[i] + 6.0f;
        }
        y += row + 14.0f;
        group.arrange(RectF(cx, y, 200.0f, ch));
        token.arrange(RectF(cx + 210.0f, y, cw - 210.0f, ch));
        y += row;
        swatchRects_.length = groups_[groupIndex_].tokens.length;
        foreach (i; 0 .. swatchRects_.length) {
            swatchRects_[i] = RectF(cx + (i % 12) * 28.0f, y + (i / 12) * 28.0f, 24.0f, 24.0f);
        }
        y += 28.0f * ((swatchRects_.length + 11) / 12) + 6.0f;
        foreach (i; 0 .. 4) {
            channels[i].arrange(RectF(cx + 22.0f + i * 100.0f, y, 70.0f, ch));
        }
        y += row;
        hintRect_ = RectF(cx, y, cw, ch);
        y += ch + 4.0f;
        readoutRect_ = RectF(x0, y, bounds.w - 2.0f * pad, READOUT_LINES * 18.0f + 8.0f);
        revertBtn.arrange(RectF(bounds.right() - pad - 170.0f, bounds.bottom() - pad - ch, 80.0f, ch));
        okBtn.arrange(RectF(bounds.right() - pad - 80.0f, bounds.bottom() - pad - ch, 80.0f, ch));
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        r.fillRoundedRect(bounds.translate(0.0f, 4.0f), theme.radiusLg, theme.shadow);
        r.fillRoundedRect(bounds, theme.radiusLg, theme.panel);
        r.strokeRoundedRect(bounds, theme.radiusLg, 2.0f, theme.borderStrong);
        immutable float pad = 16.0f;
        immutable float x0 = bounds.x + pad;
        r.drawText(Point2F(x0, bounds.y + 14.0f), "Appearance", FontId.ui, theme.fontSizeTitle, theme.text);
        immutable float small = theme.fontSizeSmall;
        immutable float body = theme.fontSizeBody;
        void label(Widget w, string text) {
            immutable float lh = r.lineHeight(FontId.ui, body);
            r.drawText(Point2F(x0, w.bounds.y + (w.bounds.h - lh) * 0.5f), text, FontId.ui, body, theme.text);
        }
        label(uiFont, "UI font");
        label(monoFont, "Monospace font");
        label(contrast, "Contrast");
        label(palette, "Palette");
        label(group, "Edit colors");
        r.drawText(Point2F(x0, duplicateBtn.bounds.y + 4.0f), theme.paletteName, FontId.ui, small, theme.textDim);
        static immutable string[4] chLabels = ["R", "G", "B", "A"];
        foreach (i; 0 .. 4) {
            immutable RectF b = channels[i].bounds;
            r.drawText(Point2F(b.x - 16.0f, b.y + 4.0f), chLabels[i], FontId.ui, body, theme.text);
        }
        label(channels[0], "Value");
        const(string)[] toks = groups_[groupIndex_].tokens;
        foreach (i, sr; swatchRects_) {
            immutable ptrdiff_t ti = colorTokenIndex(toks[i]);
            immutable ColorRGBA c = ti >= 0 ? colorToken(theme, cast(size_t) ti) : ColorRGBA(0, 0, 0, 0);
            r.fillRect(sr, theme.background);
            r.fillRect(sr.inset(2.0f), c);
            immutable bool sel = i == tokenIndex_;
            r.strokeRoundedRect(sr, 0.0f, sel ? 2.0f : 1.0f, sel ? theme.focusRing : theme.border);
        }
        immutable string hint = isCustom() ? "Editing " ~ selectedToken() ~ " in " ~ ctx_.appearance.palette
            : "Built-in palettes are read-only: Duplicate → Custom to edit " ~ selectedToken();
        r.drawText(Point2F(hintRect_.x, hintRect_.y + 3.0f), hint, FontId.ui, small, theme.textDim);
        r.fillRoundedRect(readoutRect_, theme.radiusSm, theme.panelSunken);
        r.strokeRoundedRect(readoutRect_, theme.radiusSm, theme.borderWidth, theme.border);
        ContrastReading[] rd = readout();
        immutable float lh = r.lineHeight(FontId.ui, small);
        if (rd.length == 0) {
            r.drawText(Point2F(readoutRect_.x + 8.0f, readoutRect_.y + 6.0f), "This color is not drawn behind or as text",
                FontId.ui, small, theme.textDim);
        }
        foreach (i, ref m; rd) {
            if (i >= READOUT_LINES) {
                break;
            }
            immutable float ly = readoutRect_.y + 4.0f + i * 18.0f + (18.0f - lh) * 0.5f;
            immutable string verdict = m.passes() ? "OK" : format("BELOW %.1f:1", m.required);
            immutable string line = format("%s on %s", m.fg, m.bg);
            r.drawText(Point2F(readoutRect_.x + 8.0f, ly), line, FontId.ui, small, theme.text);
            immutable string val = format("%.2f:1  %s %s", m.ratio, m.isText ? "text" : "graphic", verdict);
            immutable float vw = r.measureText(val, FontId.mono, small);
            r.drawText(Point2F(readoutRect_.right() - 8.0f - vw, ly), val, FontId.mono, small,
                m.passes() ? theme.text : theme.danger);
            if (!m.passes()) {
                fillCircle(r, Point2F(readoutRect_.right() - 14.0f - vw, ly + lh * 0.5f), 3.0f, theme.danger);
            }
        }
        if (ctx_.fonts.uiFamily.length > 0) {
            immutable string fontLine = format("UI: %s%s · Mono: %s%s", ctx_.fonts.uiFamily,
                ctx_.fonts.uiFound ? "" : " (fallback)", ctx_.fonts.monoFamily, ctx_.fonts.monoFound ? "" : " (fallback)");
            r.drawText(Point2F(x0, okBtn.bounds.y + 4.0f), fontLine, FontId.ui, small, theme.textDim);
        }
    }

    private void close() {
        if (auto c = context()) {
            c.closeOverlay(this);
        }
    }

    private bool isCustom() const {
        foreach (ref p; ctx_.appearance.customPalettes) {
            if (p.name == ctx_.appearance.palette) return true;
        }
        return false;
    }

    private ColorRGBA selectedColor() const {
        immutable ptrdiff_t ti = colorTokenIndex(selectedToken());
        return ti >= 0 ? colorToken(ctx_.theme, cast(size_t) ti) : ColorRGBA(0, 0, 0, 0);
    }

    private void apply(AppearanceSettings s) {
        ctx_.applyAppearance(s, false);
        refresh();
    }

    private void onUiFont(size_t i) {
        if (syncing_ || i >= uiFamilies_.length) return;
        AppearanceSettings s = ctx_.appearance;
        s.uiFont = uiFamilies_[i];
        apply(s);
    }

    private void onMonoFont(size_t i) {
        if (syncing_ || i >= monoFamilies_.length) return;
        AppearanceSettings s = ctx_.appearance;
        s.monoFont = monoFamilies_[i];
        apply(s);
    }

    private void onContrast(size_t i) {
        if (syncing_) return;
        AppearanceSettings s = ctx_.appearance;
        s.contrast = i == 0 ? ContrastMode.high : ContrastMode.low;
        apply(s);
    }

    private void onPalette(size_t i) {
        if (syncing_ || i >= paletteNames_.length) return;
        AppearanceSettings s = ctx_.appearance;
        s.palette = paletteNames_[i];
        apply(s);
    }

    private void onGroup(size_t i) {
        if (syncing_ || i >= groups_.length) return;
        groupIndex_ = i;
        tokenIndex_ = 0;
        refresh();
        if (auto c = context()) {
            arrange(bounds);
            c.needsRedraw = true;
        }
    }

    private void onToken(size_t i) {
        if (syncing_ || i >= groups_[groupIndex_].tokens.length) return;
        tokenIndex_ = i;
        refresh();
    }

    private void onChannel(size_t ch, float v) {
        if (syncing_ || !isCustom()) return;
        ColorRGBA c = selectedColor();
        immutable float f = v / 255.0f;
        final switch (ch) {
        case 0:
            c.r = f;
            break;
        case 1:
            c.g = f;
            break;
        case 2:
            c.b = f;
            break;
        case 3:
            c.a = f;
            break;
        }
        AppearanceSettings s = ctx_.appearance;
        s.customPalettes = s.customPalettes.dup;
        immutable ptrdiff_t ti = colorTokenIndex(selectedToken());
        if (ti >= 0 && setCustomToken(s, s.palette, cast(size_t) ti, c)) {
            apply(s);
        }
    }

    private void delegate(float) channelHandler(size_t ch) {
        return (float v) { onChannel(ch, v); };
    }

    private Dropdown addDropdown(string wid, string[] items, void delegate(size_t) handler) {
        Dropdown d = new Dropdown(items, 0, handler);
        d.id = wid;
        return add(d);
    }

    private Button addButton(string wid, string caption, void delegate() handler) {
        Button b = new Button(caption, handler);
        b.id = wid;
        return add(b);
    }

    private string[] orderedFamilies(bool mono, string preferred) {
        string[] list = ctx_.appearanceBackend is null ? null : ctx_.appearanceBackend.fontFamilies(mono);
        string[] ordered = [preferred];
        foreach (f; list) {
            if (f != preferred) ordered ~= f;
        }
        immutable string current = mono ? ctx_.appearance.monoFont : ctx_.appearance.uiFont;
        bool found = false;
        foreach (f; ordered) {
            if (f == current) found = true;
        }
        if (!found) {
            ordered ~= current;
        }
        return ordered;
    }

    private static size_t indexOf(const(string)[] list, string v) {
        foreach (i, s; list) {
            if (s == v) return i;
        }
        return 0;
    }

    private static FileDialogFilter[] paletteFilters() {
        return [FileDialogFilter("SynthTracker Palette", ["stpalette"])];
    }
}
