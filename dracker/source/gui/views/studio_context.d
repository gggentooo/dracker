/**
 * File:         source/gui/views/studio_context.d
 * Module:       gui.views.studio_context
 * Phase:        Phase 8 — Shared Studio View Context (Phase 8.5 appearance apply path)
 *
 * Purpose:
 *   The single object every studio view is constructed with. It exposes the StudioSession (all document edits go
 *   through it), the theme, shared selection state (selected module, current pattern, edit mode, follow-playhead,
 *   edit step, edit octave), per-frame telemetry (StudioTelemetry + ScopeHistory), scope-tap allocation, live MIDI
 *   note events for edit-mode entry, a status line, and platform services behind small interfaces (audio/MIDI control,
 *   file dialogs, clipboard, appearance backend and preferences store) so every view stays headless-testable with
 *   fakes. Phase 8.5: applyAppearance() is the one place an appearance switch happens (theme build, renderer
 *   clear color and glyph gamma, font families and glyph-cache flush, themeRevision bump, listener notification
 *   for UiContext relayout, persistence); loadAppearance() restores preferences before the first frame and falls
 *   back to defaults with a status message when they are missing or corrupt.
 *   Edit mode vs. live record mode: editMode (setEditMode()) writes played notes at the pattern editor cursor;
 *   live record (startLiveRecord()/stopLiveRecord()/toggleLiveRecord()) runs a session take with a count-in and
 *   captures every QWERTY, MIDI and on-screen piano note (setQwertyNote()/clearQwertyNote(), MIDI packets,
 *   liveInputNoteOn()/liveInputNoteOff()) into a new pattern. The two modes are mutually exclusive.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. tick() is called once per frame by the studio scene before input dispatch and drawing.
 *
 * Dependencies:
 *   Internal: app.{audio_host,session,telemetry}, foundation.types, gui.{appearance,theme}, platform.interfaces
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - interface IAudioControl / interface IStudioClipboard
 *   - class StudioContext : tick(), selectModule(), selectPattern(), requestScopeTaps(), takeMidiNotes(),
 *     setStatus(), revision counters, setEditOctave(), octaveRevision(), setQwertyNote(), clearQwertyNote(),
 *     clearVisualNotes(), hasHeldExternalNotes(), noteHighlightRevision(), activeNoteMask(), isNoteHighlighted(),
 *     applyAppearance(), loadAppearance(), saveAppearance(), toggleContrast(), themeRevision(), onThemeChanged(),
 *     setEditMode(), liveRecording(), countingIn(), startLiveRecord(), stopLiveRecord(), toggleLiveRecord(),
 *     liveInputNoteOn(), liveInputNoteOff()
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8)
 */
module gui.views.studio_context;

import app.audio_host : AudioLoadTelemetry;
import app.session : MidiNoteEvent, StudioSession;
import app.telemetry : makeStudioTelemetry, ScopeHistory, StudioTelemetry;
import foundation.types : ModuleId;
import std.format : format;
import gui.appearance : AppearanceSettings, decodeAppearance, encodeAppearance, FontResolution, IAppearanceBackend,
    IAppearanceStore, themeFor;
import gui.theme : ContrastMode, StudioTheme;
import platform.interfaces : AudioDeviceInfo, IFileDialog, MidiDeviceInfo, MidiPacket;

/**
 * Live audio/MIDI device control used by the transport bar (implemented over AudioHost by the app; faked in tests).
 */
interface IAudioControl {
    /**
     * Reports whether audio is streaming.
     *
     * Returns:
     *   True while running.
     */
    bool running();

    /**
     * Lists audio devices.
     *
     * Returns:
     *   Devices.
     */
    AudioDeviceInfo[] audioDevices();

    /**
     * Switches the output device.
     *
     * Params:
     *   deviceId = Device id (0 = system default).
     *
     * Returns:
     *   True on success.
     */
    bool selectOutputDevice(uint deviceId);

    /**
     * Returns the active output device id (0 = system default).
     *
     * Returns:
     *   Device id.
     */
    uint currentOutputDevice();

    /**
     * Lists MIDI sources (all connected sources feed the MIDI target module).
     *
     * Returns:
     *   Sources.
     */
    MidiDeviceInfo[] midiSources();

    /**
     * Selects the module receiving live MIDI notes.
     *
     * Params:
     *   moduleId = Module id (0 = none).
     */
    void setMidiTarget(uint moduleId);

    /**
     * Reads the latest DSP load telemetry.
     *
     * Params:
     *   load = Receives the snapshot.
     *
     * Returns:
     *   True if available.
     */
    bool readLoad(out AudioLoadTelemetry load);

    /**
     * Drains MIDI packets copied from the audio thread.
     *
     * Params:
     *   outPackets = Destination buffer.
     *
     * Returns:
     *   Packets written.
     */
    size_t drainMidi(MidiPacket[] outPackets);
}

/**
 * Plain-text clipboard (backed by IPlatformWindow in the app).
 */
interface IStudioClipboard {
    /**
     * Reads clipboard text.
     *
     * Returns:
     *   Text or empty.
     */
    string getText();

    /**
     * Writes clipboard text.
     *
     * Params:
     *   text = Text.
     *
     * Returns:
     *   True on success.
     */
    bool setText(string text);
}

private struct HeldQwerty {
    uint mod = 0;
    ubyte midi = 0;
}

/**
 * Shared state and services for all studio views.
 */
final class StudioContext {
    StudioSession session;
    StudioTheme theme;
    IAudioControl audio;
    IFileDialog dialogs;
    IStudioClipboard clipboard;
    IAppearanceBackend appearanceBackend;
    IAppearanceStore appearanceStore;
    AppearanceSettings appearance;
    FontResolution fonts;
    ScopeHistory scopes;
    StudioTelemetry telemetry;

    enum uint QWERTY_TAKE_TAG = 0x1000_0000u;
    enum uint MIDI_TAKE_TAG = 0x2000_0000u;
    enum uint PIANO_TAKE_TAG = 0x3000_0000u;

    bool editMode = false;
    bool followPlayhead = true;
    uint editStep = 1;
    int editOctave = 4;
    string status;

    private uint selectedModule_ = 0;
    private uint currentPattern_ = 1;
    private ulong selectionRevision_ = 1;
    private ulong statusRevision_ = 1;
    private uint[4] scopeTaps_;
    private bool scopesEnabled_ = false;
    private MidiNoteEvent[] midiNotes_;
    private MidiPacket[256] midiScratch_;
    private ulong frame_ = 0;
    private ulong themeRevision_ = 1;
    private void delegate()[] themeListeners_;
    private HeldQwerty[uint] qwertyHeld_;
    private uint[128][16] midiHeldMod_;
    private ulong noteHighlightRevision_ = 1;
    private ulong octaveRevision_ = 1;
    private long countInBeatShown_ = long.min;

    /**
     * Creates a context over session.
     *
     * Params:
     *   session = Initialized session.
     *   audio = Audio control, or null when no device is open (tests, offline use).
     *   dialogs = File dialogs, or null.
     *   clipboard = Clipboard, or null.
     */
    this(StudioSession session, IAudioControl audio = null, IFileDialog dialogs = null,
            IStudioClipboard clipboard = null) {
        this.session = session;
        this.audio = audio;
        this.dialogs = dialogs;
        this.clipboard = clipboard;
        this.theme = StudioTheme.light();
        this.scopes = new ScopeHistory(8192);
        const doc = session.document();
        if (doc.patterns.length > 0) {
            currentPattern_ = doc.patterns[0].patternId;
        }
    }

    /**
     * Per-frame update: drains scope blocks and MIDI, refreshes telemetry, and repairs stale selections.
     */
    void tick() {
        frame_++;
        session.setCurrentOctave(editOctave);
        if (auto eng = session.engine()) {
            eng.setWatchedNoteModule(ModuleId(selectedModule_));
        }
        scopes.consume(session.engine());
        AudioLoadTelemetry load;
        bool haveLoad = false;
        if (audio !is null && audio.running()) {
            haveLoad = audio.readLoad(load);
            if (!haveLoad) {
                haveLoad = true;
                load = telemetry.audio;
            }
            immutable size_t n = audio.drainMidi(midiScratch_[]);
            if (n > 0) {
                session.processMidiFromRt(midiScratch_[0 .. n], midiNotes_);
                trackMidiPackets(midiScratch_[0 .. n]);
            }
        }
        telemetry = makeStudioTelemetry(session.engine(), haveLoad ? &load : null);
        updateLiveTake();
        const doc = session.document();
        if (selectedModule_ != 0 && !moduleExists(selectedModule_)) {
            selectModule(0);
        }
        bool patternOk = false;
        foreach (ref p; doc.patterns) {
            if (p.patternId == currentPattern_) patternOk = true;
        }
        if (!patternOk) {
            selectPattern(doc.patterns.length > 0 ? doc.patterns[0].patternId : 0);
        }
    }

    /**
     * Returns the number of tick() calls so far (animation phase source).
     *
     * Returns:
     *   Frame counter.
     */
    ulong frame() const {
        return frame_;
    }

    /**
     * Returns the selected module (0 = none).
     *
     * Returns:
     *   Module id.
     */
    uint selectedModule() const {
        return selectedModule_;
    }

    /**
     * Selects a module (parameter rack, MIDI target, patchbay highlight).
     *
     * Params:
     *   moduleId = Module id or 0.
     */
    void selectModule(uint moduleId) {
        if (moduleId == selectedModule_) {
            return;
        }
        selectedModule_ = moduleId;
        selectionRevision_++;
        if (auto eng = session.engine()) {
            eng.setWatchedNoteModule(ModuleId(moduleId));
        }
        if (audio !is null) {
            audio.setMidiTarget(moduleId);
        }
    }

    /**
     * Returns the pattern shown in the pattern editor.
     *
     * Returns:
     *   Pattern id (0 = none).
     */
    uint currentPattern() const {
        return currentPattern_;
    }

    /**
     * Selects the pattern shown in the pattern editor.
     *
     * Params:
     *   patternId = Pattern id.
     */
    void selectPattern(uint patternId) {
        if (patternId == currentPattern_) {
            return;
        }
        currentPattern_ = patternId;
        selectionRevision_++;
    }

    /**
     * Returns a counter bumped whenever the module or pattern selection changes.
     *
     * Returns:
     *   Selection revision.
     */
    ulong selectionRevision() const {
        return selectionRevision_;
    }

    /**
     * Returns the session document revision (shortcut).
     *
     * Returns:
     *   Document revision.
     */
    ulong documentRevision() const {
        return session.documentRevision();
    }

    /**
     * Requests scope taps (master is always published); only re-sent to the Engine when the set changes.
     *
     * Params:
     *   moduleIds = Up to four module ids (0 entries ignored).
     */
    void requestScopeTaps(const(uint)[] moduleIds) {
        uint[4] next;
        size_t k = 0;
        foreach (idv; moduleIds) {
            if (idv != 0 && k < next.length) {
                next[k++] = idv;
            }
        }
        if (scopesEnabled_ && next == scopeTaps_) {
            return;
        }
        scopeTaps_ = next;
        scopesEnabled_ = true;
        session.setScopeTaps(true, scopeTaps_[0 .. k]);
    }

    /**
     * Returns the module ids currently tapped.
     *
     * Returns:
     *   Up to four ids (0 = unused slot).
     */
    uint[4] scopeTaps() const {
        return scopeTaps_;
    }

    /**
     * Removes and returns live MIDI note-ons received since the last call (for step/live recording).
     *
     * Returns:
     *   Note events.
     */
    MidiNoteEvent[] takeMidiNotes() {
        MidiNoteEvent[] n = midiNotes_;
        midiNotes_ = null;
        return n;
    }

    /**
     * Queues a note event as if it came from MIDI (tests and on-screen keyboards).
     *
     * Params:
     *   ev = Event.
     */
    void injectMidiNote(MidiNoteEvent ev) {
        midiNotes_ ~= ev;
    }

    /**
     * Sets the status-line message.
     *
     * Params:
     *   message = Text.
     */
    void setStatus(string message) {
        status = message;
        statusRevision_++;
    }

    /**
     * Returns a counter bumped by setStatus().
     *
     * Returns:
     *   Status revision.
     */
    ulong statusRevision() const {
        return statusRevision_;
    }

    /**
     * Clamps and updates the shared edit octave (-1..9), syncing the session and bumping octaveRevision().
     *
     * Params:
     *   octave = Desired octave index.
     */
    void setEditOctave(int octave) {
        immutable int clamped = octave < -1 ? -1 : (octave > 9 ? 9 : octave);
        if (clamped == editOctave) {
            return;
        }
        editOctave = clamped;
        session.setCurrentOctave(clamped);
        octaveRevision_++;
    }

    /**
     * Returns a counter bumped by setEditOctave().
     *
     * Returns:
     *   Octave revision.
     */
    ulong octaveRevision() const {
        return octaveRevision_;
    }

    /**
     * Records an active QWERTY piano hold for visual highlighting on the on-screen piano.
     *
     * Params:
     *   keyCode = macOS virtual key code.
     *   moduleId = Target module receiving the note.
     *   midi = MIDI note number 0..127.
     */
    void setQwertyNote(uint keyCode, uint moduleId, ubyte midi) {
        if (moduleId == 0 || midi > 127) {
            return;
        }
        qwertyHeld_[keyCode] = HeldQwerty(moduleId, midi);
        noteHighlightRevision_++;
        liveInputNoteOn(QWERTY_TAKE_TAG | (keyCode & 0xFFFFu), midi, 1.0f, moduleId);
    }

    /**
     * Clears a QWERTY piano hold when the key is released.
     *
     * Params:
     *   keyCode = macOS virtual key code.
     */
    void clearQwertyNote(uint keyCode) {
        if ((keyCode in qwertyHeld_) !is null) {
            qwertyHeld_.remove(keyCode);
            noteHighlightRevision_++;
        }
        liveInputNoteOff(QWERTY_TAKE_TAG | (keyCode & 0xFFFFu));
    }

    /**
     * Turns edit mode (played notes are written at the pattern editor cursor) on or off; turning it on ends a
     * running live-record take first.
     *
     * Params:
     *   on = New edit-mode state.
     */
    void setEditMode(bool on) {
        if (on && liveRecording()) {
            stopLiveRecord();
        }
        editMode = on;
        setStatus(on ? "Edit on" : "Edit off");
    }

    /**
     * Reports whether a live-record take (count-in or capture) is running.
     *
     * Returns:
     *   True while recording.
     */
    bool liveRecording() const {
        return session.liveTakeActive();
    }

    /**
     * Reports whether the live-record count-in is still running.
     *
     * Returns:
     *   True during the count-in of an active take.
     */
    bool countingIn() const {
        return liveRecording() && telemetry.engine.countingIn;
    }

    /**
     * Starts a live-record take at the playhead line with the selected module (edit mode is turned off).
     *
     * Returns:
     *   True if the take started; false (with a status message) when no instrument module is selected.
     */
    bool startLiveRecord() {
        if (liveRecording()) {
            return false;
        }
        if (!isInstrumentModule(selectedModule_)) {
            setStatus("Select an instrument module to record");
            return false;
        }
        immutable double pos = session.liveSongPosition();
        immutable long start = pos > 0.0 ? cast(long) pos : 0;
        editMode = false;
        if (!session.beginLiveTake(start)) {
            setStatus("Could not start recording");
            return false;
        }
        countInBeatShown_ = long.min;
        setStatus(format("Count-in %d", StudioSession.COUNT_IN_BEATS));
        return true;
    }

    /**
     * Ends the running take; a non-empty take becomes the current pattern.
     *
     * Returns:
     *   New pattern id, or 0 when nothing was recorded or no take was running.
     */
    uint stopLiveRecord() {
        if (!liveRecording()) {
            return 0;
        }
        immutable size_t notes = session.liveTakeNoteCount();
        immutable uint pid = session.endLiveTake();
        clearVisualNotes();
        if (pid != 0) {
            selectPattern(pid);
            string name;
            foreach (ref p; session.document().patterns) {
                if (p.patternId == pid) name = p.name;
            }
            setStatus(format("Recorded %s (%d notes)", name, notes));
        } else {
            setStatus("Recording stopped: no notes recorded");
        }
        return pid;
    }

    /**
     * Starts or stops a live-record take.
     */
    void toggleLiveRecord() {
        if (liveRecording()) {
            stopLiveRecord();
        } else {
            startLiveRecord();
        }
    }

    /**
     * Feeds a live note-on into the running take (no-op without one).
     *
     * Params:
     *   tag = Unique source tag (QWERTY_TAKE_TAG / MIDI_TAKE_TAG / PIANO_TAKE_TAG plus the key or note).
     *   midi = MIDI note.
     *   velocity = Normalized velocity.
     *   moduleId = Module playing the note.
     */
    void liveInputNoteOn(uint tag, ubyte midi, float velocity, uint moduleId) {
        if (liveRecording()) {
            session.liveTakeNoteOn(tag, midi, velocity, moduleId);
        }
    }

    /**
     * Feeds a live note release into the running take (no-op without one).
     *
     * Params:
     *   tag = Tag passed to liveInputNoteOn().
     */
    void liveInputNoteOff(uint tag) {
        if (liveRecording()) {
            session.liveTakeNoteOff(tag);
        }
    }

    private bool isInstrumentModule(uint modId) const {
        if (modId == 0) {
            return false;
        }
        foreach (ref m; session.document().modules) {
            if (m.id == modId) {
                return m.typeId != "core.output";
            }
        }
        return false;
    }

    private void updateLiveTake() {
        if (!liveRecording()) {
            return;
        }
        if (session.liveTakeShouldEnd()) {
            stopLiveRecord();
            return;
        }
        immutable double remaining = cast(double) session.liveTakeStartLine() - session.liveSongPosition();
        if (!telemetry.engine.playing) {
            return;
        }
        long beat = 0;
        if (telemetry.engine.countingIn && remaining > 0.0) {
            beat = cast(long)((remaining + StudioSession.LINES_PER_BEAT - 1e-9) / StudioSession.LINES_PER_BEAT);
        }
        if (beat == countInBeatShown_) {
            return;
        }
        countInBeatShown_ = beat;
        setStatus(beat > 0 ? format("Count-in %d", beat) : "Recording");
    }

    /**
     * Clears all tracked QWERTY and external MIDI visual note highlights.
     */
    void clearVisualNotes() {
        bool changed = qwertyHeld_.length > 0;
        qwertyHeld_ = null;
        foreach (ref ch; midiHeldMod_) {
            foreach (ref slot; ch) {
                if (slot != 0) {
                    slot = 0;
                    changed = true;
                }
            }
        }
        if (changed) {
            noteHighlightRevision_++;
        }
    }

    /**
     * Reports whether any QWERTY or external MIDI notes are currently held.
     *
     * Returns:
     *   True if at least one external live note is active.
     */
    bool hasHeldExternalNotes() const {
        if (qwertyHeld_.length > 0) {
            return true;
        }
        foreach (ref ch; midiHeldMod_) {
            foreach (slot; ch) {
                if (slot != 0) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * Returns a counter bumped whenever tracked QWERTY or external MIDI note highlights change.
     *
     * Returns:
     *   Note-highlight revision.
     */
    ulong noteHighlightRevision() const {
        return noteHighlightRevision_;
    }

    /**
     * Computes the 128-bit mask of MIDI notes currently sounding for the selected module from QWERTY, external MIDI,
     * and active pattern playback.
     *
     * Params:
     *   mask = Receives the two-word mask (cleared if no module is selected).
     */
    void activeNoteMask(out ulong[2] mask) const {
        mask[0] = 0uL;
        mask[1] = 0uL;
        if (selectedModule_ == 0) {
            return;
        }
        foreach (h; qwertyHeld_.byValue()) {
            if (h.mod == selectedModule_ && h.midi < 128) {
                mask[h.midi >> 6] |= (1uL << (h.midi & 63));
            }
        }
        foreach (ref ch; midiHeldMod_) {
            foreach (n; 0 .. 128) {
                if (ch[n] == selectedModule_) {
                    mask[n >> 6] |= (1uL << (n & 63));
                }
            }
        }
        if (telemetry.engine.playing && telemetry.engine.patternNoteModuleId == selectedModule_) {
            mask[0] |= telemetry.engine.patternNoteMask[0];
            mask[1] |= telemetry.engine.patternNoteMask[1];
        }
    }

    /**
     * Reports whether midi is currently highlighted for the selected module from QWERTY, MIDI, or pattern playback.
     *
     * Params:
     *   midi = MIDI note number 0..127.
     *
     * Returns:
     *   True if active.
     */
    bool isNoteHighlighted(ubyte midi) const {
        if (midi >= 128) {
            return false;
        }
        ulong[2] mask;
        activeNoteMask(mask);
        return (mask[midi >> 6] & (1uL << (midi & 63))) != 0;
    }

    /**
     * Applies an appearance everywhere in one step: builds the theme, updates the renderer clear color and glyph
     * gamma, switches font families (flushing the glyph cache), bumps themeRevision, notifies listeners (the
     * studio root relayouts its UiContext), and optionally persists the settings.
     *
     * Params:
     *   s = Appearance settings.
     *   persist = True to write the settings through appearanceStore.
     */
    void applyAppearance(AppearanceSettings s, bool persist = true) {
        appearance = s;
        theme = themeFor(s);
        if (appearanceBackend !is null) {
            fonts = appearanceBackend.applyFonts(s.uiFont, s.monoFont);
            appearanceBackend.applyRendererAppearance(theme.background, theme.textGamma);
            if (!fonts.uiFound || !fonts.monoFound) {
                string msg = "Font not found:";
                if (!fonts.uiFound) msg ~= " \"" ~ s.uiFont ~ "\" (using " ~ fonts.uiFamily ~ ")";
                if (!fonts.monoFound) msg ~= " \"" ~ s.monoFont ~ "\" (using " ~ fonts.monoFamily ~ ")";
                setStatus(msg);
            }
        }
        themeRevision_++;
        foreach (l; themeListeners_) {
            l();
        }
        if (persist) {
            string err;
            if (appearanceStore !is null && !saveAppearance(err)) {
                setStatus("Could not save appearance: " ~ err);
            }
        }
    }

    /**
     * Loads and applies the stored appearance; missing settings apply the defaults silently, corrupt settings
     * apply the defaults and set a status message.
     *
     * Returns:
     *   True if stored settings were loaded.
     */
    bool loadAppearance() {
        string text;
        if (appearanceStore is null || !appearanceStore.load(text)) {
            applyAppearance(AppearanceSettings.init, false);
            return false;
        }
        AppearanceSettings s;
        string err;
        if (!decodeAppearance(text, s, err)) {
            applyAppearance(AppearanceSettings.init, false);
            setStatus("Appearance settings ignored (" ~ err ~ "); using defaults");
            return false;
        }
        applyAppearance(s, false);
        return true;
    }

    /**
     * Writes the current appearance through appearanceStore.
     *
     * Params:
     *   err = Receives a diagnostic on failure.
     *
     * Returns:
     *   True on success (false when there is no store).
     */
    bool saveAppearance(out string err) {
        if (appearanceStore is null) {
            err = "no preferences store";
            return false;
        }
        return appearanceStore.save(encodeAppearance(appearance), err);
    }

    /**
     * Switches between High and Low contrast, keeping font and palette.
     */
    void toggleContrast() {
        AppearanceSettings s = appearance;
        s.contrast = s.contrast == ContrastMode.high ? ContrastMode.low : ContrastMode.high;
        applyAppearance(s);
        setStatus(s.contrast == ContrastMode.high ? "High contrast" : "Low contrast");
    }

    /**
     * Returns a counter bumped by every applyAppearance() (theme-keyed caches compare against it).
     *
     * Returns:
     *   Theme revision.
     */
    ulong themeRevision() const {
        return themeRevision_;
    }

    /**
     * Registers a callback run after every appearance switch.
     *
     * Params:
     *   listener = Callback.
     */
    void onThemeChanged(void delegate() listener) {
        if (listener !is null) {
            themeListeners_ ~= listener;
        }
    }

    private void trackMidiPackets(const(MidiPacket)[] packets) {
        bool changed = false;
        foreach (ref pkt; packets) {
            if (pkt.len < 3) {
                continue;
            }
            immutable ubyte kind = pkt.status() & 0xF0;
            immutable ubyte ch = pkt.status() & 0x0F;
            if (kind == 0x90 && pkt.data2() > 0) {
                immutable ubyte note = pkt.data1() & 0x7F;
                liveInputNoteOn(MIDI_TAKE_TAG | (cast(uint) ch << 7) | note, note, (pkt.data2() & 0x7F) / 127.0f,
                    selectedModule_);
                if (midiHeldMod_[ch][note] != selectedModule_) {
                    midiHeldMod_[ch][note] = selectedModule_;
                    changed = true;
                }
            } else if (kind == 0x80 || kind == 0x90) {
                immutable ubyte note = pkt.data1() & 0x7F;
                liveInputNoteOff(MIDI_TAKE_TAG | (cast(uint) ch << 7) | note);
                if (midiHeldMod_[ch][note] != 0) {
                    midiHeldMod_[ch][note] = 0;
                    changed = true;
                }
            } else if (kind == 0xB0) {
                immutable ubyte cc = pkt.data1() & 0x7F;
                if (cc == 120 || cc == 123) {
                    foreach (ref slot; midiHeldMod_[ch]) {
                        if (slot != 0) {
                            slot = 0;
                            changed = true;
                        }
                    }
                }
            }
        }
        if (changed) {
            noteHighlightRevision_++;
        }
    }

    private bool moduleExists(uint id) const {
        foreach (ref m; session.document().modules) {
            if (m.id == id) return true;
        }
        return false;
    }
}
