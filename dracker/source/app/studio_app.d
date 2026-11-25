/**
 * File:         source/app/studio_app.d
 * Module:       app.studio_app
 * Phase:        Phase 8.6 — Native Studio Application (Scene, Audio Lifecycle, Dialog Commands)
 *
 * Purpose:
 *   Turns the Phase 7 shell into the Dracker studio: StudioScene hosts StudioRoot in a UiContext, drives
 *   StudioContext.tick(), polls AudioHost device changes and MIDI even while the window idles, keeps the window
 *   title in sync with the document, and implements the platform-bound document actions (New, Open, Save,
 *   Save As, Export WAV, Quit) through IFileDialog. Adapters expose AudioHost as IAudioControl and the window
 *   pasteboard as IStudioClipboard. runStudioApp() launches the whole studio with live CoreAudio/CoreMIDI;
 *   runStudioGuiSelfTest() performs the full musical workflow purely through synthetic window input.
 *   Phase 8.5: ShellAppearanceBackend exposes CoreText font selection, the glyph cache flush, and the Metal
 *   clear color / glyph gamma as IAppearanceBackend; the scene loads the persisted appearance
 *   (~/Library/Application Support/Dracker/appearance.cfg) before the first frame and keeps the native
 *   View ▸ High Contrast checkmark in sync; the GUI self-test also drives the Appearance menu and panel.
 *   The studio sets GuiShell.sceneHandlesClose, so the window close button and Dracker ▸ Quit go through
 *   StudioRoot.requestClose(), which asks before discarding unsaved changes (New and Open ask the same way).
 *   A Dock-menu quit arrives the same way (closeRequested). Logout, restart and shutdown quit without asking:
 *   MacWindow.sessionEndHandler cancels a running export (and waits for it to stop) and closes the audio host, then macOS ends the process
 *   and unsaved changes are lost (owner decision, T28).
 *
 * Real-Time & Safety Contract:
 *   UI thread only; audio is reached exclusively through AudioHost and StudioSession.
 *
 * Dependencies:
 *   Internal: app.{audio_host,gui_shell,keymap,session}, gui.{renderer,widgets}, gui.views.{studio_context,studio_root},
 *             platform.interfaces, platform.macos.appkit
 *   External: core.time, std.file, std.path, std.stdio
 *
 * Planned API (Types, Functions & Hooks):
 *   - class HostAudioControl : IAudioControl / class WindowClipboard : IStudioClipboard
 *   - class ShellAppearanceBackend : IAppearanceBackend
 *   - class StudioScene : IGuiScene (root(), context(), ui(), performAppCommand())
 *   - class ScriptedFileDialog : IFileDialog
 *   - int runStudioApp(string[] args) / int runStudioGuiSelfTest(string[] args)
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8.6)
 */
module app.studio_app;

version (StudioGUI):

import core.time : dur, MonoTime;
import std.path : baseName, setExtension;
import std.stdio : stderr;

import app.audio_host : AudioHost, AudioLoadTelemetry;
import app.gui_shell : GuiShell, IGuiScene;
import app.keymap : StudioAction;
import app.session : ExportOptions, ExportState, StudioSession;
import gui.appearance : defaultAppearancePath, FileAppearanceStore, FontResolution, IAppearanceBackend,
    IAppearanceStore;
import gui.renderer : ColorRGBA, IRenderer2D, RectF;
import gui.theme : ContrastMode;
import gui.views.studio_context : IAudioControl, IStudioClipboard, StudioContext;
import gui.views.studio_root : StudioRoot;
import gui.widgets : UiContext;
import platform.interfaces : AudioDeviceInfo, AudioStreamConfig, FileDialogFilter, IFileDialog, IPlatformWindow,
    MidiDeviceInfo, MidiPacket, PlatformEvent, PlatformEventKind, WindowDesc;
import platform.macos.appkit : MacFileDialog, MacWindow;

/**
 * IAudioControl over AudioHost.
 */
final class HostAudioControl : IAudioControl {
    private AudioHost host_;
    private uint currentDevice_ = 0;

    /**
     * Wraps host.
     *
     * Params:
     *   host = Audio host (may be closed).
     */
    this(AudioHost host) {
        host_ = host;
    }

    override bool running() {
        return host_ !is null && host_.isRunning();
    }

    override AudioDeviceInfo[] audioDevices() {
        return host_ is null ? null : host_.enumerateDevices();
    }

    override bool selectOutputDevice(uint deviceId) {
        string err;
        if (host_ is null || !host_.selectOutputDevice(deviceId, err)) {
            return false;
        }
        currentDevice_ = deviceId;
        return true;
    }

    override uint currentOutputDevice() {
        return currentDevice_;
    }

    override MidiDeviceInfo[] midiSources() {
        return host_ is null ? null : host_.midiSources();
    }

    override void setMidiTarget(uint moduleId) {
        import foundation.types : ModuleId;

        if (host_ !is null) {
            host_.setMidiTarget(ModuleId(moduleId));
        }
    }

    override bool readLoad(out AudioLoadTelemetry load) {
        return host_ !is null && host_.readLoad(load);
    }

    override size_t drainMidi(MidiPacket[] outPackets) {
        return host_ is null ? 0 : host_.drainMidi(outPackets);
    }
}

/**
 * IStudioClipboard over the platform window pasteboard.
 */
final class WindowClipboard : IStudioClipboard {
    private IPlatformWindow window_;

    /**
     * Wraps window.
     *
     * Params:
     *   window = Platform window.
     */
    this(IPlatformWindow window) {
        window_ = window;
    }

    override string getText() {
        return window_.getClipboardText();
    }

    override bool setText(string text) {
        return window_.setClipboardText(text);
    }
}

/**
 * IAppearanceBackend over the GUI shell's CoreText rasterizer, glyph cache, and Metal renderer.
 */
final class ShellAppearanceBackend : IAppearanceBackend {
    private GuiShell shell_;
    private string[][2] families_;
    private bool[2] listed_;

    /**
     * Wraps shell.
     *
     * Params:
     *   shell = Created GUI shell.
     */
    this(GuiShell shell) {
        shell_ = shell;
    }

    override string[] fontFamilies(bool monospaceOnly) {
        immutable size_t k = monospaceOnly ? 1 : 0;
        if (!listed_[k]) {
            families_[k] = shell_.rasterizer.listFontFamilies(monospaceOnly);
            listed_[k] = true;
        }
        return families_[k];
    }

    override FontResolution applyFonts(string uiFamily, string monoFamily) {
        FontResolution res = shell_.rasterizer.setFonts(uiFamily, monoFamily);
        shell_.glyphs.reset();
        return res;
    }

    override void applyRendererAppearance(ColorRGBA clearColor, float textGamma) {
        shell_.renderer.clearColor = clearColor;
        shell_.renderer.textGamma = textGamma;
    }
}

/**
 * Studio scene: StudioRoot inside a UiContext plus app-level commands.
 */
final class StudioScene : IGuiScene {
    private StudioContext ctx_;
    private StudioRoot root_;
    private UiContext ui_;
    private MacWindow window_;
    private GuiShell shell_;
    private AudioHost host_;
    private float lastW_ = 0.0f;
    private float lastH_ = 0.0f;
    private ulong drawnDocRevision_ = 0;
    private ulong drawnStatusRevision_ = 0;
    private ulong drawnSelection_ = 0;
    private ulong drawnNoteRevision_ = 0;
    private ulong drawnOctaveRevision_ = 0;
    private string lastTitle_;
    private MonoTime lastPoll_;
    private bool exportWatch_ = false;

    /**
     * Set by the Quit command; the app loop exits when true.
     */
    bool quitRequested = false;

    /**
     * Builds the studio scene.
     *
     * Params:
     *   session = Initialized session.
     *   host = Audio host (may be null when audio is unavailable).
     *   window = Host window (title, clipboard).
     *   dialogs = File dialogs (null disables dialog commands).
     *   shell = GUI shell providing fonts, glyph cache, renderer and menus (null: headless appearance).
     *   store = Appearance preferences store (null: preferences are not persisted).
     */
    this(StudioSession session, AudioHost host, MacWindow window, IFileDialog dialogs, GuiShell shell = null,
            IAppearanceStore store = null) {
        host_ = host;
        window_ = window;
        shell_ = shell;
        ctx_ = new StudioContext(session, host is null ? null : new HostAudioControl(host), dialogs,
            window is null ? null : new WindowClipboard(window));
        root_ = new StudioRoot(ctx_);
        root_.appCommandHandler = &performAppCommand;
        root_.onAppearanceChanged = &syncMenus;
        ui_ = new UiContext(root_);
        ctx_.appearanceStore = store;
        if (shell !is null) {
            ctx_.appearanceBackend = new ShellAppearanceBackend(shell);
        }
        ctx_.loadAppearance();
        lastPoll_ = MonoTime.currTime;
    }

    private void syncMenus() {
        if (shell_ !is null) {
            shell_.app.setMenuItemChecked("View", "High Contrast", ctx_.theme.contrast == ContrastMode.high);
        }
    }

    /**
     * Returns the studio root widget.
     *
     * Returns:
     *   Root.
     */
    StudioRoot root() {
        return root_;
    }

    /**
     * Returns the shared context.
     *
     * Returns:
     *   Context.
     */
    StudioContext context() {
        return ctx_;
    }

    /**
     * Returns the widget context.
     *
     * Returns:
     *   UiContext.
     */
    UiContext ui() {
        return ui_;
    }

    override void handleEvent(const ref PlatformEvent ev) {
        if (ev.kind == PlatformEventKind.closeRequested) {
            root_.requestClose();
            return;
        }
        if (ev.kind == PlatformEventKind.mouseDown) {
            import gui.renderer : Point2F;

            root_.noteInteraction(Point2F(ev.x, ev.y));
        }
        ui_.handleEvent(ev);
    }

    override void draw(IRenderer2D r, float width, float height, double timeSeconds) {
        ctx_.tick();
        if (width != lastW_ || height != lastH_ || drawnDocRevision_ != ctx_.documentRevision()
                || drawnSelection_ != ctx_.selectionRevision()) {
            lastW_ = width;
            lastH_ = height;
            ui_.layout(RectF(0, 0, width, height), r);
        }
        drawnDocRevision_ = ctx_.documentRevision();
        drawnStatusRevision_ = ctx_.statusRevision();
        drawnSelection_ = ctx_.selectionRevision();
        drawnNoteRevision_ = ctx_.noteHighlightRevision();
        drawnOctaveRevision_ = ctx_.octaveRevision();
        ui_.draw(r);
        updateTitle();
    }

    override bool needsRedraw() {
        pollBackground();
        return ui_.needsRedraw || drawnDocRevision_ != ctx_.documentRevision()
            || drawnStatusRevision_ != ctx_.statusRevision() || drawnSelection_ != ctx_.selectionRevision()
            || drawnNoteRevision_ != ctx_.noteHighlightRevision() || drawnOctaveRevision_ != ctx_.octaveRevision()
            || (host_ !is null && host_.hasPendingMidi());
    }

    override bool isAnimating() {
        return ui_.isAnimating() || ctx_.session.isPlaying() || exportWatch_
            || ((ctx_.editMode || ctx_.liveRecording()) && ctx_.audio !is null && ctx_.audio.running());
    }

    /**
     * Executes a platform-bound document action (also used by the GUI self-test).
     *
     * Params:
     *   action = newProject, openProject, saveProject, saveProjectAs, exportWav, or quit.
     *
     * Returns:
     *   True if handled.
     */
    bool performAppCommand(StudioAction action) {
        auto s = ctx_.session;
        string err;
        switch (action) {
            case StudioAction.newProject:
                s.newEmptyProject(true);
                ctx_.setStatus("New project");
                return true;
            case StudioAction.openProject: {
                string path;
                if (ctx_.dialogs is null || !ctx_.dialogs.openFile("Open Project", projectFilters(), path)) {
                    return true;
                }
                ctx_.setStatus(s.openProjectFile(path, err) ? "Opened " ~ baseName(path) : "Open failed: " ~ err);
                return true;
            }
            case StudioAction.saveProject:
                if (s.currentPath().length > 0) {
                    ctx_.setStatus(s.saveProjectToFile(s.currentPath(), err) ? "Saved" : "Save failed: " ~ err);
                    return true;
                }
                goto case StudioAction.saveProjectAs;
            case StudioAction.saveProjectAs: {
                string path;
                if (ctx_.dialogs is null || !ctx_.dialogs.saveFile("Save Project", defaultName("msv"), projectFilters(),
                        path)) {
                    return true;
                }
                ctx_.setStatus(s.saveProjectToFile(path, err) ? "Saved " ~ baseName(path) : "Save failed: " ~ err);
                return true;
            }
            case StudioAction.exportWav: {
                string path;
                if (ctx_.dialogs is null || !ctx_.dialogs.saveFile("Export WAV", defaultName("wav"),
                        [FileDialogFilter("WAV Audio", ["wav"])], path)) {
                    return true;
                }
                ExportOptions opt;
                if (s.beginExport(path, opt, err)) {
                    exportWatch_ = true;
                    ctx_.setStatus("Exporting " ~ baseName(path) ~ "…");
                } else {
                    ctx_.setStatus("Export failed: " ~ err);
                }
                return true;
            }
            case StudioAction.quit:
                quitRequested = true;
                return true;
            default:
                return false;
        }
    }

    private void pollBackground() {
        if (MonoTime.currTime - lastPoll_ < dur!"msecs"(15)) {
            return;
        }
        lastPoll_ = MonoTime.currTime;
        if (host_ !is null && host_.isRunning()) {
            host_.poll();
        }
        if (exportWatch_) {
            auto st = ctx_.session.exportStatus();
            if (st.state != ExportState.running) {
                exportWatch_ = false;
                ctx_.setStatus(st.state == ExportState.succeeded ? "Exported " ~ baseName(st.path)
                    : "Export failed: " ~ st.error);
            }
        }
    }

    private void updateTitle() {
        if (window_ is null) {
            return;
        }
        immutable string path = ctx_.session.currentPath();
        immutable string t = "Dracker — " ~ (path.length > 0 ? baseName(path) : "Untitled")
            ~ (ctx_.session.isDirty() ? " •" : "");
        if (t != lastTitle_) {
            lastTitle_ = t;
            window_.setTitle(t);
        }
    }

    private string defaultName(string ext) {
        immutable string path = ctx_.session.currentPath();
        return path.length > 0 ? setExtension(baseName(path), ext) : "Untitled." ~ ext;
    }

    private static FileDialogFilter[] projectFilters() {
        return [FileDialogFilter("Dracker Project", ["msv"])];
    }
}

/**
 * Opens the default audio device for session (best effort).
 *
 * Params:
 *   session = Initialized session.
 *   host = Receives the running host, or null if audio could not be opened.
 *   err = Receives a diagnostic.
 *
 * Returns:
 *   True if audio is running.
 */
bool openDefaultAudio(StudioSession session, out AudioHost host, out string err) {
    AudioHost h = new AudioHost();
    AudioStreamConfig cfg;
    cfg.bufferFrames = 128;
    if (!h.open(session, cfg, true, err)) {
        host = null;
        return false;
    }
    host = h;
    return true;
}

/**
 * Launches the Dracker studio window with live audio/MIDI and runs until the user quits.
 *
 * Params:
 *   args = Command-line arguments (an optional .msv path opens that project).
 *
 * Returns:
 *   Process exit code.
 */
int runStudioApp(string[] args) {
    GuiShell shell = new GuiShell();
    WindowDesc desc;
    desc.title = "Dracker";
    desc.width = 1440;
    desc.height = 900;
    desc.minWidth = 960;
    desc.minHeight = 640;
    string err;
    if (!shell.create(desc, err)) {
        stderr.writeln("GUI startup failed: ", err);
        return 1;
    }
    scope (exit) shell.shutdown();
    StudioSession session = new StudioSession();
    if (!session.initialize(44_100.0f)) {
        stderr.writeln("Session initialization failed");
        return 1;
    }
    scope (exit) session.dispose();
    foreach (a; args[1 .. $]) {
        if (a.length > 4 && a[$ - 4 .. $] == ".msv" && !session.openProjectFile(a, err)) {
            stderr.writeln("Could not open ", a, ": ", err);
        }
    }
    AudioHost host;
    string audioErr;
    immutable bool audioOk = openDefaultAudio(session, host, audioErr);
    scope (exit) {
        if (host !is null) host.close();
    }
    immutable string prefsPath = defaultAppearancePath();
    StudioScene scene = new StudioScene(session, host, shell.window, new MacFileDialog(shell.window), shell,
        prefsPath.length > 0 ? new FileAppearanceStore(prefsPath) : null);
    if (!audioOk) {
        scene.context().setStatus("Audio unavailable: " ~ audioErr);
    }
    shell.scene = scene;
    shell.sceneHandlesClose = true;
    shell.window.sessionEndHandler = () nothrow {
        try {
            session.cancelExport();
            session.waitForExport();
            if (host !is null) {
                host.close();
            }
        } catch (Exception) {
        }
    };
    while (shell.window.isOpen() && !shell.quitRequested && !scene.quitRequested) {
        shell.tick();
    }
    session.waitForExport();
    return 0;
}

/**
 * IFileDialog that answers with preset paths (unattended GUI self-test).
 */
final class ScriptedFileDialog : IFileDialog {
    string openPath;
    string savePath;
    string exportPath;
    uint openCalls = 0;
    uint saveCalls = 0;

    override bool openFile(string title, const(FileDialogFilter)[] filters, out string selectedPath) {
        openCalls++;
        selectedPath = openPath;
        return openPath.length > 0;
    }

    override bool saveFile(string title, string defaultName, const(FileDialogFilter)[] filters, out string selectedPath) {
        saveCalls++;
        selectedPath = filters.length > 0 && filters[0].extensions.length > 0 && filters[0].extensions[0] == "wav"
            ? exportPath : savePath;
        return selectedPath.length > 0;
    }
}

/**
 * Unattended end-to-end studio workflow driven purely through synthetic window input (mouse, keyboard, menu
 * shortcuts) against the real AppKit window, Metal renderer, and live CoreAudio stream.
 *
 * Params:
 *   args = Command-line arguments (--quick shortens the playback stress phase to 4 s).
 *
 * Returns:
 *   0 if every step passed.
 */
int runStudioGuiSelfTest(string[] args) {
    import core.time : Duration;
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir;
    import std.format : format;
    import std.path : buildPath;
    import std.stdio : stdout, writefln;

    import app.keymap : StudioAction;
    import graph.registry : ModuleRegistry;
    import gui.renderer : Point2F;
    import gui.widgets : ContextMenu, Dropdown, Widget;
    import platform.interfaces : KeyModifiers;
    import platform.macos.appkit : postSyntheticKey, postSyntheticMouse, postSyntheticScroll;

    bool quick = false;
    foreach (a; args) {
        if (a == "--quick") quick = true;
    }
    size_t failed = 0;
    size_t total = 0;
    void check(string name, bool pass, string detail) {
        total++;
        if (!pass) failed++;
        writefln("%s  %-30s %s", pass ? "PASS" : "FAIL", name, detail);
        stdout.flush();
    }

    GuiShell shell = new GuiShell();
    WindowDesc desc;
    desc.title = "Dracker Studio Self-Test";
    desc.width = 1440;
    desc.height = 900;
    string err;
    if (!shell.create(desc, err)) {
        check("startup", false, err);
        return 1;
    }
    scope (exit) shell.shutdown();
    shell.window.setFloating(true);
    StudioSession session = new StudioSession();
    session.initialize(44_100.0f);
    scope (exit) session.dispose();
    session.doSetParam(1, 0, 0.12f);
    AudioHost host;
    string audioErr;
    immutable bool audioOk = openDefaultAudio(session, host, audioErr);
    scope (exit) {
        if (host !is null) host.close();
    }
    immutable string dir = buildPath(tempDir(), "dracker_studio_gui_selftest");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    ScriptedFileDialog dialogs = new ScriptedFileDialog();
    dialogs.savePath = buildPath(dir, "workflow.msv");
    dialogs.openPath = dialogs.savePath;
    dialogs.exportPath = buildPath(dir, "workflow.wav");
    immutable string prefsPath = buildPath(dir, "prefs", "appearance.cfg");
    FileAppearanceStore prefs = new FileAppearanceStore(prefsPath);
    StudioScene scene = new StudioScene(session, host, shell.window, dialogs, shell, prefs);
    shell.scene = scene;
    StudioRoot root = scene.root();
    auto ctx = scene.context();
    auto doc() {
        return session.document();
    }

    void pumpFor(double seconds) {
        immutable MonoTime until = MonoTime.currTime + dur!"usecs"(cast(long)(seconds * 1e6));
        while (MonoTime.currTime < until) {
            shell.tick(0.01);
        }
    }

    bool pumpUntil(bool delegate() cond, double timeoutSeconds = 2.0) {
        immutable MonoTime until = MonoTime.currTime + dur!"usecs"(cast(long)(timeoutSeconds * 1e6));
        while (MonoTime.currTime < until) {
            shell.tick(0.01);
            if (cond()) return true;
        }
        return cond();
    }

    void click(Point2F p, uint mods = 0) {
        postSyntheticMouse(shell.window, 1, p.x, p.y, mods);
        postSyntheticMouse(shell.window, 2, p.x, p.y, mods);
        pumpFor(0.06);
    }

    void rightClick(Point2F p) {
        postSyntheticMouse(shell.window, 3, p.x, p.y);
        postSyntheticMouse(shell.window, 4, p.x, p.y);
        pumpFor(0.08);
    }

    void drag(Point2F a, Point2F b, uint mods = 0, int steps = 12) {
        postSyntheticMouse(shell.window, 1, a.x, a.y, mods);
        pumpFor(0.02);
        foreach (i; 1 .. steps + 1) {
            immutable float t = cast(float) i / steps;
            postSyntheticMouse(shell.window, 6, a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, mods);
            pumpFor(0.012);
        }
        postSyntheticMouse(shell.window, 2, b.x, b.y, mods);
        pumpFor(0.08);
    }

    void key(ushort code, string chars, uint mods = 0) {
        postSyntheticKey(shell.window, true, code, chars, mods);
        pumpFor(0.06);
        postSyntheticKey(shell.window, false, code, chars, mods);
        pumpFor(0.06);
    }

    ContextMenu openMenu() {
        foreach (w; scene.ui().overlays()) {
            if (auto m = cast(ContextMenu) w) return m;
        }
        return null;
    }

    bool chooseMenuItem(string prefix) {
        ContextMenu m = openMenu();
        if (m is null) return false;
        foreach (i, ref it; m.items) {
            if (it.label.length >= prefix.length && it.label[0 .. prefix.length] == prefix) {
                click(m.itemRect(i).center());
                return true;
            }
        }
        return false;
    }

    uint addModuleViaMenu(string category, string typeId) {
        immutable size_t before = doc().modules.length;
        rightClick(root.patchbay.emptyCanvasPoint());
        if (!chooseMenuItem(category)) return 0;
        pumpFor(0.08);
        if (!chooseMenuItem(ModuleRegistry.findByTypeId(typeId).displayName)) return 0;
        pumpUntil(() => doc().modules.length == before + 1);
        return doc().modules.length == before + 1 ? doc().modules[$ - 1].id : 0;
    }

    pumpFor(0.8);
    check("studio window", shell.framesRendered > 0 && audioOk,
        audioOk ? format("%s frames, audio @%.0f Hz", shell.framesRendered, session.sampleRate())
            : "audio unavailable: " ~ audioErr);
    {
        import gui.appearance : DEFAULT_MONO_FONT, DEFAULT_UI_FONT;
        import gui.theme : StudioTheme;

        const f = ctx.fonts;
        immutable bool lightHc = ctx.theme == StudioTheme.init && scene.ui().theme == StudioTheme.init
            && shell.renderer.clearColor == StudioTheme.init.background && shell.renderer.textGamma == StudioTheme.init.textGamma;
        immutable bool fontsOk = f.uiFound && f.monoFound && f.uiFamily == DEFAULT_UI_FONT && f.monoFamily == DEFAULT_MONO_FONT
            && f.uiWeight == 400.0f && f.monoWeight == 400.0f;
        check("first launch appearance", lightHc && fontsOk && shell.app.menuItemChecked("View", "High Contrast"),
            format("%s; UI %s (%.0f, %s); mono %s (%.0f, %s)", ctx.theme.paletteName, f.uiFamily, f.uiWeight, f.uiSource,
                f.monoFamily, f.monoWeight, f.monoSource));
    }

    immutable uint gen = addModuleViaMenu("Add Synth", "synth.analog_gen");
    immutable uint fm = addModuleViaMenu("Add Synth", "synth.fm_synth");
    immutable uint echo = addModuleViaMenu("Add Effect", "fx.echo");
    check("add modules (patchbay menu)", gen != 0 && fm != 0 && echo != 0,
        format("analog_gen=%s fm_synth=%s echo=%s", gen, fm, echo));

    if (gen != 0 && fm != 0 && echo != 0) {
        pumpFor(0.2);
        drag(root.patchbay.portPosition(gen, 2), root.patchbay.portPosition(echo, 0));
        drag(root.patchbay.portPosition(echo, 1), root.patchbay.portPosition(1, 0));
        drag(root.patchbay.portPosition(fm, 1), root.patchbay.portPosition(1, 0));
        check("wire modules (port drags)", doc().wires.length == 3, format("%s wires", doc().wires.length));
    }

    float cutoffBefore = 0.0f;
    float cutoffAfter = 0.0f;
    if (gen != 0) {
        click(root.patchbay.nodeCenter(gen));
        pumpUntil(() => ctx.selectedModule() == gen);
        pumpFor(0.2);
        foreach (ref m; doc().modules) {
            if (m.id == gen && m.paramValues.length > 3) cutoffBefore = m.paramValues[3];
        }
        immutable RectF pr = root.rack.paramControlRect(3);
        drag(Point2F(pr.x + pr.w * 0.5f, pr.center().y), Point2F(pr.x + pr.w * 0.2f, pr.center().y));
        foreach (ref m; doc().modules) {
            if (m.id == gen && m.paramValues.length > 3) cutoffAfter = m.paramValues[3];
        }
        check("parameter drag (rack)", ctx.selectedModule() == gen && cutoffAfter != cutoffBefore && !pr.isEmpty(),
            format("cutoff %.1f -> %.1f", cutoffBefore, cutoffAfter));
    }

    {
        click(root.transport.controlRect("transport.edit").center());
        immutable ushort[8] pianoKeys = [6, 1, 7, 2, 8, 9, 5, 11];
        immutable string[8] pianoChars = ["z", "s", "x", "d", "c", "v", "g", "b"];
        string cursorTrace;
        size_t keyDowns = 0;
        size_t keyRepeats = 0;
        shell.setEventObserver((const ref PlatformEvent ev) {
            if (ev.kind == PlatformEventKind.keyDown) {
                keyDowns++;
                if (ev.isRepeat) keyRepeats++;
            }
        });
        foreach (track; 0 .. 4) {
            click(root.patchbay.nodeCenter(track % 2 == 0 ? gen : fm));
            pumpFor(0.05);
            immutable RectF cell = root.pattern.fieldRect(track, 0, 0);
            click(cell.center());
            Widget fw = scene.ui().focused;
            cursorTrace ~= format(" t%s->cursor%s focus=%s rec=%s", track, root.pattern.cursorTrack(),
                fw is null ? "none" : fw.id, ctx.editMode);
            foreach (n; 0 .. 16) {
                key(pianoKeys[(n + track * 2) % 8], pianoChars[(n + track * 2) % 8]);
            }
        }
        click(root.transport.controlRect("transport.edit").center());
        size_t notes = 0;
        size_t[4] perTrack;
        foreach (ref p; doc().patterns) {
            if (p.patternId == ctx.currentPattern()) {
                foreach (ci, ref c; p.cells) {
                    if (!c.isEmpty()) {
                        notes++;
                        if (ci % p.tracks < 4) perTrack[ci % p.tracks]++;
                    }
                }
            }
        }
        shell.setEventObserver(null);
        cursorTrace ~= format(" perTrack=%s keyDowns=%s repeats=%s", perTrack, keyDowns, keyRepeats);
        foreach (ref p; doc().patterns) {
            if (p.patternId == ctx.currentPattern()) {
                cursorTrace ~= " t0lines:";
                foreach (ln; 0 .. 20) {
                    immutable c = p.cells[ln * p.tracks];
                    cursorTrace ~= c.isEmpty() ? "." : "x";
                }
                cursorTrace ~= format(" cursorLineEnd=%s step=%s", root.pattern.cursorLine(), ctx.editStep);
            }
        }
        check("record notes (QWERTY)", notes >= 64 && !ctx.editMode, format("%s notes written;%s", notes, cursorTrace));
    }

    {
        pumpFor(0.2);
        click(Point2F(root.timeline.contentRect().x + 20.0f, root.timeline.laneToY(3) + 4.0f));
        key(27, "-", KeyModifiers.command);
        key(27, "-", KeyModifiers.command);
        pumpFor(0.1);
        immutable size_t clipsBefore = doc().clips.length;
        immutable uint firstClip = doc().clips.length > 0 ? doc().clips[0].clipId : 0;
        immutable RectF cr = root.timeline.clipRect(firstClip);
        immutable Point2F from = cr.center();
        immutable Point2F to = Point2F(from.x + root.timeline.lineToX(64) - root.timeline.lineToX(0), from.y);
        drag(from, to, KeyModifiers.alt);
        bool cloned = doc().clips.length == clipsBefore + 1 && doc().clips[$ - 1].cloneSourceId != 0;
        bool supertrack = false;
        string menuTrace;
        bool menuHit = false;
        if (cloned) {
            immutable uint cloneId = doc().clips[$ - 1].clipId;
            rightClick(root.timeline.clipRect(cloneId).center());
            if (ContextMenu m = openMenu()) {
                foreach (ref it; m.items) menuTrace ~= "[" ~ it.label ~ (it.enabled ? "" : " (off)") ~ "]";
            }
            menuHit = chooseMenuItem("Supertrack");
            pumpFor(0.1);
            foreach (ref c; doc().clips) {
                if (c.clipId == cloneId) supertrack = c.isSupertrack;
            }
        }
        check("arrange clone + Supertrack", cloned && supertrack,
            format("%s clips, clone=%s, supertrack=%s, menu item hit=%s %s", doc().clips.length, cloned, supertrack,
                menuHit, menuTrace));
    }

    {
        click(root.patchbay.nodeCenter(gen));
        pumpUntil(() => ctx.selectedModule() == gen);
        pumpFor(0.2);
        click(root.rack.paramControlRect(1).center());
        pumpFor(0.1);
        key(119, "", 0);
        key(36, "\r", 0);
        foreach (attempt; 0 .. 40) {
            immutable RectF row = root.rack.paramControlRect(8);
            if (!row.isEmpty() && row.y >= root.rack.bounds.y + 30.0f && row.bottom() <= root.rack.bounds.bottom() - 4.0f) {
                break;
            }
            immutable Point2F over = root.rack.bounds.center();
            postSyntheticScroll(shell.window, 0, -24, over.x, over.y);
            pumpFor(0.05);
        }
        immutable RectF rel = root.rack.paramControlRect(8);
        drag(Point2F(rel.x + rel.w * 0.3f, rel.center().y), Point2F(rel.right() + 40.0f, rel.center().y));
        float unison = 0.0f;
        float release = 0.0f;
        foreach (ref m; doc().modules) {
            if (m.id == gen && m.paramValues.length > 8) {
                unison = m.paramValues[1];
                release = m.paramValues[8];
            }
        }
        check("heavy voice setup (rack)", unison == 4.0f && release > 4.0f,
            format("unison %.0f voices, release %.2f s", unison, release));
    }

    {
        AudioLoadTelemetry l0;
        if (ctx.audio !is null) ctx.audio.readLoad(l0);
        click(root.transport.controlRect("transport.play").center());
        pumpFor(0.3);
        immutable bool playingNow = session.isPlaying();
        immutable long line0 = ctx.telemetry.engine.currentLine;
        immutable double stressSeconds = quick ? 4.0 : 10.0;
        immutable ulong f0 = shell.framesRendered;
        immutable MonoTime t0 = MonoTime.currTime;
        immutable Point2F nodeA = root.patchbay.nodeCenter(echo);
        ulong step = 0;
        float maxLevel = 0.0f;
        bool dragging = false;
        immutable ushort[6] chord = [6, 8, 11, 12, 14, 17];
        click(root.patchbay.nodeCenter(gen));
        while (MonoTime.currTime - t0 < dur!"usecs"(cast(long)(stressSeconds * 1e6))) {
            immutable float phase = (step % 120) / 120.0f;
            if (!dragging) {
                postSyntheticMouse(shell.window, 1, nodeA.x, nodeA.y);
                dragging = true;
            }
            postSyntheticMouse(shell.window, 6, nodeA.x + 80.0f * phase, nodeA.y + 30.0f * phase);
            if (step % 120 == 119) {
                postSyntheticMouse(shell.window, 2, nodeA.x + 80.0f, nodeA.y + 30.0f);
                dragging = false;
            }
            if (step % 45 == 0) {
                foreach (k; chord) postSyntheticKey(shell.window, true, k, "", 0);
            }
            if (step % 45 == 30) {
                foreach (k; chord) postSyntheticKey(shell.window, false, k, "", 0);
            }
            if (step % 30 == 0) {
                postSyntheticScroll(shell.window, 0, (step / 30) % 2 == 0 ? -40 : 40);
            }
            shell.tick(0.0);
            immutable float tl = ctx.telemetry.engine.graph.masterPeakL;
            if (tl > maxLevel) maxLevel = tl;
            float[] sl;
            float[] sr;
            if (ctx.scopes.snapshot(0, 512, sl, sr) > 0) {
                foreach (v; sl) {
                    immutable float av = v < 0.0f ? -v : v;
                    if (av > maxLevel) maxLevel = av;
                }
            }
            step++;
        }
        if (dragging) {
            postSyntheticMouse(shell.window, 2, nodeA.x, nodeA.y);
        }
        immutable double secs = (MonoTime.currTime - t0).total!"usecs" * 1e-6;
        immutable double fps = (shell.framesRendered - f0) / secs;
        AudioLoadTelemetry l1;
        if (ctx.audio !is null) ctx.audio.readLoad(l1);
        immutable ulong xr = l1.xruns - l0.xruns;
        immutable float peak = maxLevel;
        immutable long lineAdvance = ctx.telemetry.engine.currentLine - line0;
        click(root.transport.controlRect("transport.stop").center());
        check("playback stress (60+ fps)", fps >= 60.0 && xr == 0 && l1.callbacks > l0.callbacks && peak > 1e-3f,
            format("%.1f fps over %.0fs with node drags/scroll/live chords, %s xruns, DSP peak %.1f%%, max level %.3f, "
                ~ "playing=%s lines+%s", fps, secs, xr, l1.loadPeak * 100.0f, peak, playingNow, lineAdvance));
    }

    {
        import std.math : fabs;

        click(root.patchbay.nodeCenter(gen));
        pumpUntil(() => ctx.selectedModule() == gen);
        immutable bool spanOk = root.piano.bounds.w == root.bounds.w
            && root.piano.bounds.y > root.patchbay.bounds.y
            && root.piano.bounds.bottom() <= root.pattern.bounds.y;
        immutable int oct0 = ctx.editOctave;
        click(root.piano.octaveUpRect().center());
        immutable int octUp = ctx.editOctave;
        click(root.piano.octaveDownRect().center());
        immutable int octBack = ctx.editOctave;
        immutable ubyte testMidi = cast(ubyte)((octBack + 1) * 12);
        immutable Point2F keyPt = root.piano.keyRect(testMidi).center();
        postSyntheticMouse(shell.window, 1, keyPt.x, keyPt.y);
        pumpFor(0.15);
        immutable bool keyHeld = root.piano.pressedMidi() == cast(int) testMidi
            && root.piano.isKeyHighlighted(testMidi);
        immutable float heldPeak = ctx.telemetry.engine.graph.masterPeakL > ctx.telemetry.engine.graph.masterPeakR
            ? ctx.telemetry.engine.graph.masterPeakL : ctx.telemetry.engine.graph.masterPeakR;
        postSyntheticMouse(shell.window, 2, keyPt.x, keyPt.y);
        pumpFor(0.08);
        immutable bool keyReleased = root.piano.pressedMidi() == -1 && !root.piano.isKeyHighlighted(testMidi);
        immutable float h0 = root.piano.bounds.h;
        immutable float topY = root.piano.bounds.y - 2.0f;
        drag(Point2F(200.0f, topY), Point2F(200.0f, topY - 24.0f));
        immutable float hAfterTop = root.piano.bounds.h;
        immutable float botY = root.piano.bounds.bottom() + 2.0f;
        drag(Point2F(200.0f, botY), Point2F(200.0f, botY + 20.0f));
        immutable float hAfterBot = root.piano.bounds.h;
        check("on-screen piano", spanOk && octUp == oct0 + 1 && octBack == oct0 && keyHeld && keyReleased
            && heldPeak > 1e-3f && hAfterTop > h0 + 15.0f && hAfterBot > hAfterTop + 12.0f
            && fabs(root.piano.bounds.w - root.bounds.w) < 0.5f,
            format("oct %s->%s->%s, peak %.3f, h %.0f->%.0f->%.0f", oct0, octUp, octBack, heldPeak, h0, hAfterTop,
                hAfterBot));
    }

    {
        immutable size_t mods = doc().modules.length;
        immutable size_t clips = doc().clips.length;
        immutable size_t wires = doc().wires.length;
        key(1, "s", KeyModifiers.command);
        immutable bool saved = pumpUntil(() => exists(dialogs.savePath) && !session.isDirty());
        key(45, "n", KeyModifiers.command);
        immutable bool cleared = pumpUntil(() => doc().modules.length == 1);
        key(31, "o", KeyModifiers.command);
        immutable bool reopened = pumpUntil(() => doc().modules.length == mods);
        check("save / new / reopen (menus)", saved && cleared && reopened && doc().clips.length == clips
            && doc().wires.length == wires && session.currentPath() == dialogs.savePath,
            format("%s modules, %s wires, %s clips restored", doc().modules.length, doc().wires.length,
                doc().clips.length));
    }

    {
        key(14, "e", KeyModifiers.command);
        immutable bool exported = pumpUntil(() => exists(dialogs.exportPath)
            && session.exportStatus().state == ExportState.succeeded, 30.0);
        check("export WAV (menu)", exported && getSize(dialogs.exportPath) > 44,
            exported ? format("%s bytes, %s frames", getSize(dialogs.exportPath), session.exportStatus().framesRendered)
                : "export did not finish: " ~ session.exportStatus().error);
    }

    {
        import std.algorithm : canFind;
        import std.file : readText;
        import gui.appearance : DEFAULT_MONO_FONT, DEFAULT_UI_FONT;
        import gui.theme : ContrastMode, StudioTheme;
        import gui.views.appearance_panel : AppearancePanel;

        RectF[] rects() {
            return [root.bounds, root.transport.bounds, root.patchbay.bounds, root.rack.bounds, root.scopeView.bounds,
                root.piano.bounds, root.pattern.bounds, root.timeline.bounds, root.sampleEditor.bounds];
        }
        bool pickItem(Dropdown d, size_t i) {
            click(d.bounds.center());
            pumpFor(0.05);
            if (d.popup() is null) return false;
            immutable RectF ir = d.popup().itemRect(i);
            if (ir.isEmpty()) return false;
            click(ir.center());
            pumpFor(0.05);
            return d.selectedIndex == i;
        }
        const RectF[] before = rects();
        key(43, ",", KeyModifiers.command);
        AppearancePanel p = root.appearancePanel();
        string trace;
        bool lowOk = false, darkOk = false, fontOk = false, layoutOk = false, reverted = false;
        if (p !is null) {
            lowOk = pickItem(p.contrast, 1) && ctx.theme.contrast == ContrastMode.low
                && !shell.app.menuItemChecked("View", "High Contrast");
            darkOk = pickItem(p.palette, 2) && !ctx.theme.isLight && shell.renderer.clearColor == ctx.theme.background
                && scene.ui().theme == ctx.theme;
            fontOk = pickItem(p.uiFont, 1) && ctx.appearance.uiFont != DEFAULT_UI_FONT && ctx.fonts.uiFound
                && shell.rasterizer.resolution().uiFamily == ctx.appearance.uiFont;
            trace = format("low=%s dark=%s font=%s(%s)", lowOk, darkOk, fontOk, ctx.appearance.uiFont);
            pumpFor(0.2);
            layoutOk = rects() == before;
            click(p.revertBtn.bounds.center());
            pumpFor(0.1);
            reverted = root.appearancePanel() is null && ctx.theme == StudioTheme.init
                && ctx.fonts.uiFamily == DEFAULT_UI_FONT && ctx.fonts.monoFamily == DEFAULT_MONO_FONT
                && shell.app.menuItemChecked("View", "High Contrast") && rects() == before;
        }
        check("appearance panel (menu)", p !is null && lowOk && darkOk && fontOk && layoutOk && reverted,
            format("%s layout=%s reverted=%s", trace, layoutOk, reverted));

        key(8, "c", KeyModifiers.command | KeyModifiers.alt);
        immutable bool toggledLow = ctx.theme.contrast == ContrastMode.low && !shell.app.menuItemChecked("View", "High Contrast");
        string saved;
        try {
            saved = readText(prefsPath);
        } catch (Exception) {
        }
        StudioContext reload = new StudioContext(session);
        reload.appearanceStore = new FileAppearanceStore(prefsPath);
        immutable bool reloaded = reload.loadAppearance() && reload.theme == ctx.theme;
        key(8, "c", KeyModifiers.command | KeyModifiers.alt);
        immutable bool toggledHigh = ctx.theme == StudioTheme.init && shell.app.menuItemChecked("View", "High Contrast");
        string savedHigh;
        try {
            savedHigh = readText(prefsPath);
        } catch (Exception) {
        }
        check("contrast toggle + persistence", toggledLow && toggledHigh && saved.canFind("contrast=low")
            && savedHigh.canFind("contrast=high") && reloaded && rects() == before,
            format("low=%s high=%s saved=%s reloaded=%s", toggledLow, toggledHigh, saved.canFind("contrast=low"), reloaded));
    }

    writefln("Studio GUI self-test: %s/%s checks passed", total - failed, total);
    return failed == 0 ? 0 : 1;
}
