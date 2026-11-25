/**
 * File:         source/gui/views/studio_root.d
 * Module:       gui.views.studio_root
 * Phase:        Phase 8.6 — Studio Window Root: Docked Layout, Command Routing & Status Bar (Phase 8.5 appearance)
 *
 * Purpose:
 *   Assembles every studio view into one docked window layout: transport bar on top; a resizable split grid with
 *   the patchbay and parameter rack + scope above, a full-width resizable piano keyboard in the middle, and the
 *   pattern editor and timeline + sample editor below; and a status bar. Routes keyboard shortcuts resolved through
 *   the session Keymap: document-level actions run here
 *   (transport, record, octave, undo/redo, panic, play-pattern, loop) or go to the app layer (new/open/save/
 *   export/quit); context-dependent actions go to the StudioCommandSink view that holds focus (or was used last);
 *   unhandled piano keys play live notes on the selected module. ⌘R starts/stops a live-record take and ⇧⌘R
 *   toggles edit mode. ⌥⌘S saves the selected module as an .msym preset and ⌥⌘O loads one as a new module
 *   (File menu items). Esc (no modifiers) ends a running take, else leaves edit mode, before the keymap's
 *   Esc = Stop binding is consulted; Play, Stop and Play Pattern during a take end the take. Phase 8.5: openAppearance opens the Appearance
 *   panel overlay, toggleContrast flips High/Low contrast, and every StudioContext appearance switch is pushed
 *   into the UiContext (theme + relayout) through a theme listener.
 *
 * Real-Time & Safety Contract:
 *   UI thread only; never touches RT state except through StudioSession.
 *
 * Dependencies:
 *   Internal: app.keymap, foundation.types, gui.{layout,renderer,theme,widgets}, gui.views.*, platform.interfaces
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - class StudioRoot : Widget (views, appCommandHandler, executeAction(), activeSink(), noteInteraction(),
 *     openAppearancePanel(), appearancePanel(), onAppearanceChanged)
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.6)
 */
module gui.views.studio_root;

import app.keymap : forwardToSink, isDocumentLevel, StudioAction, StudioCommandSink;
import foundation.types : ModuleId;
import gui.layout : Axis, SplitPaneNode;
import gui.renderer : FontId, IRenderer2D, Point2F, RectF;
import gui.theme : ContrastMode, StudioTheme;
import gui.views.appearance_panel : AppearancePanel;
import gui.views.param_rack : ParamRackView;
import gui.views.patchbay_view : PatchbayView;
import gui.views.pattern_editor : PatternEditorView;
import gui.views.piano_view : PianoKeyboardView;
import gui.views.sample_editor : SampleEditorView;
import gui.views.scope_view : ScopeView;
import gui.views.studio_context : StudioContext;
import gui.views.timeline_view : TimelineView;
import gui.views.transport_bar : TransportBarView;
import gui.widgets : KeyCode, KeyEvent, SplitView, Widget;
import platform.interfaces : PlatformEvent, PlatformEventKind;

/**
 * Root widget of the studio window.
 */
final class StudioRoot : Widget {
    enum float TRANSPORT_HEIGHT = 44.0f;
    enum float STATUS_HEIGHT = 22.0f;

    StudioContext ctx;
    TransportBarView transport;
    PatchbayView patchbay;
    ParamRackView rack;
    ScopeView scopeView;
    PianoKeyboardView piano;
    PatternEditorView pattern;
    TimelineView timeline;
    SampleEditorView sampleEditor;
    SplitView grid;

    /**
     * Receives document-level actions that need the platform (new, open, save, save as, export, quit).
     */
    bool delegate(StudioAction) appCommandHandler;

    /**
     * Called after every appearance switch, once the UiContext has adopted the new theme (the app updates the
     * native High Contrast menu checkmark here).
     */
    void delegate() onAppearanceChanged;

    private Widget lastSink_;
    private AppearancePanel appearancePanel_;
    private uint[uint] heldPianoKeys_;

    /**
     * Builds every view over ctx.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        this.ctx = ctx;
        id = "studio.root";
        transport = add(new TransportBarView(ctx));
        patchbay = new PatchbayView(ctx);
        rack = new ParamRackView(ctx);
        scopeView = new ScopeView(ctx);
        piano = new PianoKeyboardView(ctx);
        pattern = new PatternEditorView(ctx);
        timeline = new TimelineView(ctx);
        sampleEditor = new SampleEditorView(ctx);

        SplitPaneNode top = SplitPaneNode.split(Axis.horizontal, SplitPaneNode.leaf("patchbay"),
            SplitPaneNode.split(Axis.vertical, SplitPaneNode.leaf("rack"), SplitPaneNode.leaf("scope"), 0.62f,
                120.0f, 90.0f), 0.62f, 320.0f, 240.0f);
        SplitPaneNode bottom = SplitPaneNode.split(Axis.horizontal, SplitPaneNode.leaf("pattern"),
            SplitPaneNode.split(Axis.vertical, SplitPaneNode.leaf("timeline"), SplitPaneNode.leaf("sample"), 0.55f,
                100.0f, 100.0f), 0.58f, 320.0f, 240.0f);
        SplitPaneNode lower = SplitPaneNode.split(Axis.vertical, SplitPaneNode.leaf("piano"), bottom,
            0.1327f, PianoKeyboardView.MIN_HEIGHT, 180.0f);
        grid = add(new SplitView(SplitPaneNode.split(Axis.vertical, top, lower,
            0.4124f, 180.0f, PianoKeyboardView.MIN_HEIGHT + 4.0f + 180.0f)));
        grid.setPane("patchbay", patchbay);
        grid.setPane("rack", rack);
        grid.setPane("scope", scopeView);
        grid.setPane("piano", piano);
        grid.setPane("pattern", pattern);
        grid.setPane("timeline", timeline);
        grid.setPane("sample", sampleEditor);
        lastSink_ = pattern;
        ctx.onThemeChanged(&syncTheme);
    }

    /**
     * Opens the Appearance panel centered in the window (no-op when it is already open or detached).
     *
     * Returns:
     *   The open panel, or null when the root is not attached to a UiContext.
     */
    AppearancePanel openAppearancePanel() {
        auto c = context;
        if (c is null) {
            return null;
        }
        if (appearancePanel_ !is null) {
            return appearancePanel_;
        }
        AppearancePanel p = new AppearancePanel(ctx);
        immutable RectF vp = c.viewport().isEmpty() ? bounds : c.viewport();
        immutable float w = AppearancePanel.WIDTH < vp.w ? AppearancePanel.WIDTH : vp.w;
        immutable float h = AppearancePanel.HEIGHT < vp.h ? AppearancePanel.HEIGHT : vp.h;
        p.bounds = RectF(vp.x + (vp.w - w) * 0.5f, vp.y + (vp.h - h) * 0.5f, w, h);
        p.onClosed = () { appearancePanel_ = null; invalidate(); };
        p.forwardKey = (const ref KeyEvent e) => onKeyDown(e);
        appearancePanel_ = p;
        c.openOverlay(p);
        return p;
    }

    /**
     * Returns the open Appearance panel.
     *
     * Returns:
     *   Panel, or null when closed.
     */
    AppearancePanel appearancePanel() {
        return appearancePanel_;
    }

    private void syncTheme() {
        if (auto c = context) {
            c.setTheme(ctx.theme);
        }
        if (appearancePanel_ !is null) {
            appearancePanel_.refresh();
        }
        invalidate();
        if (onAppearanceChanged !is null) {
            onAppearanceChanged();
        }
    }

    override void layoutChildren() {
        immutable RectF b = bounds;
        transport.arrange(RectF(b.x, b.y, b.w, TRANSPORT_HEIGHT));
        immutable float gridH = b.h - TRANSPORT_HEIGHT - STATUS_HEIGHT;
        grid.arrange(RectF(b.x, b.y + TRANSPORT_HEIGHT, b.w, gridH > 0.0f ? gridH : 0.0f));
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        r.fillRect(bounds, theme.background);
        immutable RectF bar = RectF(bounds.x, bounds.bottom() - STATUS_HEIGHT, bounds.w, STATUS_HEIGHT);
        r.fillRect(bar, theme.panelSunken);
        r.fillRect(RectF(bar.x, bar.y, bar.w, 1.0f), theme.border);
        string left = ctx.status.length > 0 ? ctx.status : "Ready";
        r.drawText(Point2F(bar.x + 8.0f, bar.y + 4.0f), left, FontId.ui, theme.fontSizeSmall, theme.textDim);
        immutable string right = ctx.session.isDirty() ? "Modified" : "Saved";
        immutable float w = r.measureText(right, FontId.ui, theme.fontSizeSmall);
        r.drawText(Point2F(bar.right() - w - 8.0f, bar.y + 4.0f), right, FontId.ui, theme.fontSizeSmall, theme.textDim);
    }

    override bool isAnimating() {
        return false;
    }

    /**
     * Records which view the pointer went down in (called by the scene before every mouseDown dispatch, since
     * views consume the click before it could bubble here).
     *
     * Params:
     *   p = Pointer position in window coordinates.
     */
    void noteInteraction(Point2F p) {
        noteSinkUnder(p);
    }

    /**
     * Returns the view that receives context-dependent actions: the focused StudioCommandSink, else the last one
     * the user interacted with.
     *
     * Returns:
     *   Sink widget, or null.
     */
    StudioCommandSink activeSink() {
        if (auto c = context) {
            for (Widget w = c.focused; w !is null; w = w.parent) {
                if (auto s = cast(StudioCommandSink) w) {
                    lastSink_ = w;
                    return s;
                }
            }
        }
        return lastSink_ is null ? null : cast(StudioCommandSink) lastSink_;
    }

    /**
     * Executes an action as if its shortcut was pressed.
     *
     * Params:
     *   action = Action.
     *
     * Returns:
     *   True if handled.
     */
    bool executeAction(StudioAction action) {
        if (action == StudioAction.none) {
            return false;
        }
        if (!isDocumentLevel(action)) {
            return forwardToSink(activeSink(), action);
        }
        auto s = ctx.session;
        if (ctx.liveRecording() && (action == StudioAction.playToggle || action == StudioAction.stop
                || action == StudioAction.playPattern)) {
            ctx.stopLiveRecord();
            invalidate();
            return true;
        }
        switch (action) {
            case StudioAction.playToggle:
                s.togglePlay();
                break;
            case StudioAction.stop:
                s.stop();
                s.seekLine(0);
                break;
            case StudioAction.recordToggle:
                ctx.toggleLiveRecord();
                break;
            case StudioAction.editToggle:
                ctx.setEditMode(!ctx.editMode);
                break;
            case StudioAction.octaveUp:
                ctx.setEditOctave(ctx.editOctave + 1);
                ctx.setStatus("Octave " ~ octaveText());
                break;
            case StudioAction.octaveDown:
                ctx.setEditOctave(ctx.editOctave - 1);
                ctx.setStatus("Octave " ~ octaveText());
                break;
            case StudioAction.undo:
                ctx.setStatus(s.undo() ? "Undo" : "Nothing to undo");
                break;
            case StudioAction.redo:
                ctx.setStatus(s.redo() ? "Redo" : "Nothing to redo");
                break;
            case StudioAction.panic:
                piano.releaseHeld();
                heldPianoKeys_ = null;
                ctx.clearVisualNotes();
                s.stop();
                ctx.setStatus("All notes off");
                break;
            case StudioAction.playPattern:
                if (s.isAuditioningPattern()) {
                    s.stop();
                } else {
                    s.playPattern(ctx.currentPattern());
                }
                break;
            case StudioAction.toggleLoop:
                toggleLoop();
                break;
            case StudioAction.openAppearance:
                openAppearancePanel();
                break;
            case StudioAction.toggleContrast:
                ctx.toggleContrast();
                break;
            case StudioAction.saveModulePreset:
                ctx.saveModulePreset(ctx.selectedModule());
                break;
            case StudioAction.loadModulePreset: {
                immutable float[2] at = ctx.nextModulePosition();
                ctx.loadModulePreset(at[0], at[1]);
                break;
            }
            default:
                return appCommandHandler !is null && appCommandHandler(action);
        }
        invalidate();
        return true;
    }

    override bool onKeyDown(const ref KeyEvent e) {
        if (e.keyCode == KeyCode.escape && e.modifiers == 0 && (ctx.liveRecording() || ctx.editMode)) {
            if (!e.isRepeat) {
                if (ctx.liveRecording()) {
                    ctx.stopLiveRecord();
                } else {
                    ctx.setEditMode(false);
                }
                invalidate();
            }
            return true;
        }
        immutable StudioAction act = ctx.session.keymap().resolveAction(e.keyCode, e.modifiers);
        if (act != StudioAction.none) {
            return executeAction(act);
        }
        if (e.modifiers == 0 && !e.isRepeat && livePiano(e, true)) {
            return true;
        }
        return false;
    }

    override bool onKeyUp(const ref KeyEvent e) {
        return livePiano(e, false);
    }

    private bool livePiano(const ref KeyEvent e, bool down) {
        if (!down) {
            auto held = e.keyCode in heldPianoKeys_;
            if (held is null) {
                return false;
            }
            immutable uint mod = *held;
            heldPianoKeys_.remove(e.keyCode);
            ctx.clearQwertyNote(e.keyCode);
            invalidate();
            return ctx.session.releaseLiveNote(ModuleId(mod), e.keyCode);
        }
        ubyte midi;
        if (ctx.selectedModule() == 0 || !ctx.session.keymap().resolveNote(e.keyCode, ctx.editOctave, midi)) {
            return false;
        }
        heldPianoKeys_[e.keyCode] = ctx.selectedModule();
        ctx.setQwertyNote(e.keyCode, ctx.selectedModule(), midi);
        invalidate();
        PlatformEvent ev;
        ev.kind = PlatformEventKind.keyDown;
        ev.keyCode = e.keyCode;
        ev.modifiers = e.modifiers;
        return ctx.session.handleKeyEvent(ev, ModuleId(ctx.selectedModule()));
    }

    private void toggleLoop() {
        const doc = ctx.session.document();
        if (doc.loopEndLine != 0) {
            ctx.session.doSetLoop(0, 0);
            ctx.setStatus("Loop off");
            return;
        }
        long end = 0;
        foreach (ref c; doc.clips) {
            if (c.startLine + c.lengthLines > end) end = c.startLine + c.lengthLines;
        }
        if (end > 0 && ctx.session.doSetLoop(0, end)) {
            ctx.setStatus("Loop song");
        }
    }

    private string octaveText() const {
        import std.conv : to;

        return to!string(ctx.editOctave);
    }

    private void noteSinkUnder(Point2F p) {
        foreach (Widget w; [cast(Widget) patchbay, rack, scopeView, pattern, timeline, sampleEditor]) {
            if (w.visible && w.bounds.contains(p) && cast(StudioCommandSink) w !is null) {
                lastSink_ = w;
            }
        }
    }
}
