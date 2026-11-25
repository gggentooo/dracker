/**
 * File:         source/gui/views/instrument_sidebar.d
 * Module:       gui.views.instrument_sidebar
 * Phase:        Instrument library — T50 & T55 (patchbay instrument sidebar and user preset management)
 *
 * Purpose:
 *   Collapsible left sidebar of PatchbayView displaying bundled and user module presets grouped by folder
 *   (Bass, Keys, Pads & Leads, Drums, Effects, custom groups, Other) using GroupedList. Double-clicking or
 *   pressing Return on a preset row adds it as an unwired module at the next free canvas position; dragging a
 *   row onto the patchbay canvas adds it at the drop point. Rescans the library on focus and after library
 *   changes while preserving group collapse states.
 *   User presets offer a context menu (Rename…, Move to group ▸, Remove… with confirmation, and Show in
 *   Finder); bundled presets offer none of these. Any library error is reported to the status bar.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Reads StudioContext.library and renders via IRenderer2D.
 *
 * Dependencies:
 *   Internal: app.instrument_library, gui.{renderer,theme,widgets}, gui.views.studio_context
 *   External: std.string (strip)
 *
 * Planned API (Types, Functions & Hooks):
 *   - SIDEBAR_EXPANDED_WIDTH, SIDEBAR_COLLAPSED_WIDTH, SIDEBAR_HEADER_HEIGHT, PRESET_DRAG_KIND
 *   - final class PresetDragData : Object
 *   - final class InstrumentSidebar : Widget — this(StudioContext), collapsed(), setCollapsed(bool),
 *     preferredWidth(), refresh(bool rescan = false), rowMenuItems(), moveToGroupMenuItems(),
 *     beginRenameRow(), onActivateEntry, onToggleCollapsed
 *   - Widget ids: "patchbay.sidebar", "patchbay.sidebar.list", "patchbay.sidebar.collapse"
 *
 * See_Also:
 *   docs/todo.md (T35, T45, T50, T55), source/gui/views/patchbay_view.d
 */
module gui.views.instrument_sidebar;

import std.string : strip;

import app.instrument_library : LIBRARY_GROUPS, LibraryEntry, OTHER_GROUP, PresetOrigin;
import gui.renderer : FontId, IRenderer2D, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.views.studio_context : StudioContext;
import gui.widgets : Button, DragPayload, GroupedList, ListGroup, ListRow, MenuItem, openConfirmDialog,
    openTextEditor, TextField, Widget;

enum float SIDEBAR_EXPANDED_WIDTH = 200.0f;
enum float SIDEBAR_COLLAPSED_WIDTH = 26.0f;
enum float SIDEBAR_HEADER_HEIGHT = 28.0f;
enum string PRESET_DRAG_KIND = "dracker.preset";

/**
 * Payload object carried by UiContext drag-and-drop when dragging a preset row onto the patchbay canvas.
 */
final class PresetDragData : Object {
    LibraryEntry entry;

    /**
     * Wraps a library entry for drag-and-drop.
     *
     * Params:
     *   entry = Preset entry being dragged.
     */
    this(LibraryEntry entry) {
        this.entry = entry;
    }
}

private final class SidebarList : GroupedList {
    void delegate() onFocused;

    override void onFocusGained() {
        super.onFocusGained();
        if (onFocused !is null) {
            onFocused();
        }
    }
}

/**
 * Collapsible preset browser sidebar at the left edge of the patchbay pane.
 */
final class InstrumentSidebar : Widget {
    SidebarList list;
    Button collapseButton;
    void delegate(LibraryEntry) onActivateEntry;
    void delegate() onToggleCollapsed;

    private StudioContext ctx_;
    private bool collapsed_ = false;
    private bool[string] groupCollapsed_;
    private ulong seenLibraryRevision_ = 0;
    private bool hasBundled_ = false;
    private bool hasAny_ = false;

    /**
     * Creates the sidebar over a studio context.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        assert(ctx !is null, "InstrumentSidebar requires a StudioContext");
        ctx_ = ctx;
        id = "patchbay.sidebar";
        collapseButton = add(new Button("<", &toggleCollapsed));
        collapseButton.id = "patchbay.sidebar.collapse";
        list = add(new SidebarList());
        list.id = "patchbay.sidebar.list";
        list.onFocused = () { refresh(true); };
        list.onActivate = &activateRow;
        list.dragPayloadProvider = &dragRowPayload;
        list.rowMenuProvider = &rowMenuItems;
        refresh(false);
    }

    /**
     * Reports whether the sidebar is collapsed to a narrow strip.
     *
     * Returns:
     *   True when collapsed.
     */
    bool collapsed() const {
        return collapsed_;
    }

    /**
     * Sets the collapsed state and notifies the owning patchbay to relayout.
     *
     * Params:
     *   c = True to collapse, false to expand.
     */
    void setCollapsed(bool c) {
        if (collapsed_ == c) {
            return;
        }
        collapsed_ = c;
        list.visible = !c;
        collapseButton.text = c ? ">" : "<";
        layoutChildren();
        if (onToggleCollapsed !is null) {
            onToggleCollapsed();
        }
        invalidate();
    }

    /**
     * Returns the current desired width in logical points.
     *
     * Returns:
     *   SIDEBAR_COLLAPSED_WIDTH when collapsed, else SIDEBAR_EXPANDED_WIDTH.
     */
    float preferredWidth() const {
        return collapsed_ ? SIDEBAR_COLLAPSED_WIDTH : SIDEBAR_EXPANDED_WIDTH;
    }

    /**
     * Rebuilds the grouped preset list from ctx.library, optionally rescanning the folders first while
     * preserving group collapse state and selection.
     *
     * Params:
     *   rescan = True to call ctx.library.rescan() before reading entries.
     */
    void refresh(bool rescan = false) {
        foreach (ref grp; list.groups()) {
            groupCollapsed_[grp.title] = grp.collapsed;
        }
        if (ctx_.library !is null && rescan) {
            ctx_.library.rescan();
        }
        seenLibraryRevision_ = ctx_.libraryRevision();
        hasBundled_ = false;
        hasAny_ = false;
        ListGroup[] next;
        if (ctx_.library !is null) {
            foreach (ref e; ctx_.library.entries()) {
                hasAny_ = true;
                if (e.origin == PresetOrigin.bundled) {
                    hasBundled_ = true;
                }
                if (next.length == 0 || next[$ - 1].title != e.group) {
                    ListGroup g;
                    g.title = e.group;
                    g.collapsed = groupCollapsed_.get(e.group, false);
                    next ~= g;
                }
                ListRow row;
                row.text = e.name;
                row.detail = e.typeName;
                row.tag = e.origin == PresetOrigin.user ? "user" : null;
                row.data = new PresetDragData(e);
                next[$ - 1].rows ~= row;
            }
        }
        list.setGroups(next);
        layoutChildren();
        invalidate();
    }

    /**
     * Builds the context menu for a row; bundled presets return null, user presets offer Rename…, Move to group,
     * Remove…, and Show in Finder.
     *
     * Params:
     *   group = Group index.
     *   row = Row index inside group.
     *
     * Returns:
     *   Menu entries for user presets, or null for bundled presets or invalid indices.
     */
    MenuItem[] rowMenuItems(size_t group, size_t row) {
        if (ctx_.library is null) {
            return null;
        }
        auto groups = list.groups();
        if (group >= groups.length || row >= groups[group].rows.length) {
            return null;
        }
        auto data = cast(PresetDragData) groups[group].rows[row].data;
        if (data is null || data.entry.origin != PresetOrigin.user) {
            return null;
        }
        immutable LibraryEntry entry = data.entry;
        immutable RectF rr = list.rowRect(group, row);
        immutable Point2F subAt = Point2F(rr.right(), rr.y);
        MenuItem[] items;
        items ~= MenuItem("Rename…", { beginRenameRow(group, row); });
        items ~= MenuItem("Move to group ▸", {
            if (auto ui = context()) {
                ui.openContextMenu(moveToGroupMenuItems(entry), subAt);
            }
        });
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem("Remove…", { confirmRemoveEntry(entry); });
        items ~= MenuItem.makeSeparator();
        items ~= MenuItem("Show in Finder", {
            if (!ctx_.revealFileInFinder(entry.path)) {
                ctx_.setStatus("Could not show \"" ~ entry.name ~ "\" in Finder");
            }
        });
        return items;
    }

    /**
     * Builds the Move to group submenu items for a user preset entry.
     *
     * Params:
     *   entry = User preset entry.
     *
     * Returns:
     *   Menu items for all standard, active, and Other groups.
     */
    MenuItem[] moveToGroupMenuItems(LibraryEntry entry) {
        if (ctx_.library is null || entry.origin != PresetOrigin.user) {
            return null;
        }
        string[] groups;
        void appendUnique(string g) {
            foreach (existing; groups) {
                if (existing == g) return;
            }
            groups ~= g;
        }
        foreach (g; LIBRARY_GROUPS) {
            appendUnique(g);
        }
        foreach (g; ctx_.library.groups()) {
            appendUnique(g);
        }
        appendUnique(OTHER_GROUP);

        MenuItem[] items;
        foreach (g; groups) {
            immutable string target = g;
            immutable bool same = target == entry.group;
            items ~= MenuItem(same ? "✓ " ~ target : target, makeMoveGroupAction(entry, target), !same);
        }
        return items;
    }

    private void delegate() makeMoveGroupAction(LibraryEntry entry, string target) {
        return () {
            LibraryEntry moved;
            string err;
            if (!ctx_.library.moveToGroup(entry, target, moved, err)) {
                ctx_.setStatus(err);
                return;
            }
            ctx_.notifyLibraryChanged();
            refresh(false);
            ctx_.setStatus("Moved \"" ~ moved.name ~ "\" to " ~ moved.group);
        };
    }

    /**
     * Opens an inline text editor over a user preset row to rename it.
     *
     * Params:
     *   group = Group index.
     *   row = Row index inside group.
     *
     * Returns:
     *   The open TextField or null when invalid or bundled.
     */
    TextField beginRenameRow(size_t group, size_t row) {
        auto ui = context();
        if (ui is null || ctx_.library is null) {
            return null;
        }
        auto groups = list.groups();
        if (group >= groups.length || row >= groups[group].rows.length) {
            return null;
        }
        auto data = cast(PresetDragData) groups[group].rows[row].data;
        if (data is null || data.entry.origin != PresetOrigin.user) {
            return null;
        }
        immutable LibraryEntry entry = data.entry;
        return openTextEditor(ui, list.rowRect(group, row), entry.name, (string rawName) {
            immutable string nextName = strip(rawName);
            LibraryEntry renamed;
            string err;
            if (!ctx_.library.rename(entry, nextName, renamed, err)) {
                ctx_.setStatus(err);
                return;
            }
            ctx_.notifyLibraryChanged();
            refresh(false);
            ctx_.setStatus("Renamed to \"" ~ renamed.name ~ "\"");
        });
    }

    override void layoutChildren() {
        immutable RectF b = bounds;
        if (b.isEmpty()) {
            return;
        }
        if (collapsed_) {
            list.visible = false;
            immutable float bw = b.w - 6.0f > 14.0f ? (b.w - 6.0f < 20.0f ? b.w - 6.0f : 20.0f) : b.w;
            collapseButton.arrange(RectF(b.x + (b.w - bw) * 0.5f, b.y + 4.0f, bw, 20.0f));
            return;
        }
        list.visible = true;
        immutable float bw = 22.0f;
        collapseButton.arrange(RectF(b.right() - bw - 4.0f, b.y + (SIDEBAR_HEADER_HEIGHT - 20.0f) * 0.5f,
            bw, 20.0f));
        immutable float noteH = hasBundled_ ? 0.0f : 20.0f;
        immutable float listTop = b.y + SIDEBAR_HEADER_HEIGHT;
        immutable float listH = b.bottom() - listTop - noteH;
        immutable float listW = b.w > 1.0f ? b.w - 1.0f : 0.0f;
        list.arrange(RectF(b.x, listTop, listW, listH > 0.0f ? listH : 0.0f));
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        if (ctx_.libraryRevision() != seenLibraryRevision_) {
            refresh(false);
        }
        if (bounds.isEmpty()) {
            return;
        }
        r.pushClip(bounds);
        r.fillRect(bounds, theme.panel);
        immutable float hdrH = SIDEBAR_HEADER_HEIGHT < bounds.h ? SIDEBAR_HEADER_HEIGHT : bounds.h;
        r.fillRect(RectF(bounds.x, bounds.y, bounds.w, hdrH), theme.panelRaised);
        if (hdrH >= 1.0f) {
            r.fillRect(RectF(bounds.x, bounds.y + hdrH - 1.0f, bounds.w, 1.0f), theme.border);
        }
        if (!collapsed_) {
            immutable float lh = r.lineHeight(FontId.ui, theme.fontSizeBody);
            r.drawText(Point2F(bounds.x + 8.0f, bounds.y + (hdrH - lh) * 0.5f),
                "Instruments", FontId.ui, theme.fontSizeBody, theme.text);
            if (!hasBundled_ && bounds.h >= hdrH + 20.0f) {
                immutable float ny = bounds.bottom() - 20.0f;
                r.fillRect(RectF(bounds.x, ny, bounds.w, 1.0f), theme.border);
                immutable string note = hasAny_ ? "No bundled presets" : "No presets found";
                immutable float slh = r.lineHeight(FontId.ui, theme.fontSizeSmall);
                r.drawText(Point2F(bounds.x + 8.0f, ny + (20.0f - slh) * 0.5f),
                    note, FontId.ui, theme.fontSizeSmall, theme.textDim);
            }
        }
        if (bounds.w >= 1.0f) {
            r.fillRect(RectF(bounds.right() - 1.0f, bounds.y, 1.0f, bounds.h), theme.border);
        }
        r.popClip();
    }

    override void drawChildren(IRenderer2D r, const ref StudioTheme theme) {
        if (bounds.isEmpty()) {
            return;
        }
        r.pushClip(bounds);
        super.drawChildren(r, theme);
        r.popClip();
    }

    private void confirmRemoveEntry(LibraryEntry entry) {
        auto ui = context();
        if (ui is null || ctx_.library is null) {
            return;
        }
        openConfirmDialog(ui, "Remove \"" ~ entry.name ~ "\"?",
            "The preset file will be moved to the Trash.", "Remove", "Cancel", () {
                string err;
                if (!ctx_.library.remove(entry, err)) {
                    ctx_.setStatus(err);
                    return;
                }
                ctx_.notifyLibraryChanged();
                refresh(false);
                ctx_.setStatus("Removed \"" ~ entry.name ~ "\"");
            }, null);
    }

    private void toggleCollapsed() {
        setCollapsed(!collapsed_);
    }

    private void activateRow(size_t group, size_t row) {
        auto groups = list.groups();
        if (group >= groups.length || row >= groups[group].rows.length) {
            return;
        }
        auto data = cast(PresetDragData) groups[group].rows[row].data;
        if (data !is null && onActivateEntry !is null) {
            onActivateEntry(data.entry);
        }
    }

    private DragPayload dragRowPayload(size_t group, size_t row) {
        auto groups = list.groups();
        if (group >= groups.length || row >= groups[group].rows.length) {
            return DragPayload.init;
        }
        auto data = cast(PresetDragData) groups[group].rows[row].data;
        if (data is null) {
            return DragPayload.init;
        }
        return DragPayload(PRESET_DRAG_KIND, data, data.entry.name);
    }
}
