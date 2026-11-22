/**
 * File:         source/gui/views/studio_context.d
 * Module:       gui.views.studio_context
 * Phase:        Phase 8 — Shared Studio View Context
 *
 * Purpose:
 *   The single object every studio view is constructed with. It exposes the StudioSession (all document edits go
 *   through it), the theme, shared selection state (selected module, current pattern, recording, follow-playhead,
 *   edit step, edit octave), per-frame telemetry (StudioTelemetry + ScopeHistory), scope-tap allocation, live MIDI
 *   note events for recording, a status line, and platform services behind small interfaces (audio/MIDI control,
 *   file dialogs, clipboard) so every view stays headless-testable with fakes.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. tick() is called once per frame by the studio scene before input dispatch and drawing.
 *
 * Dependencies:
 *   Internal: app.{audio_host,session,telemetry}, foundation.types, gui.theme, platform.interfaces
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - interface IAudioControl / interface IStudioClipboard
 *   - class StudioContext : tick(), selectModule(), selectPattern(), requestScopeTaps(), takeMidiNotes(),
 *     setStatus(), revision counters
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 8)
 */
module gui.views.studio_context;

import app.audio_host : AudioLoadTelemetry;
import app.session : MidiNoteEvent, StudioSession;
import app.telemetry : makeStudioTelemetry, ScopeHistory, StudioTelemetry;
import gui.theme : StudioTheme;
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

/**
 * Shared state and services for all studio views.
 */
final class StudioContext {
    StudioSession session;
    StudioTheme theme;
    IAudioControl audio;
    IFileDialog dialogs;
    IStudioClipboard clipboard;
    ScopeHistory scopes;
    StudioTelemetry telemetry;

    bool recording = false;
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
        this.theme = StudioTheme.dark();
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
            }
        }
        telemetry = makeStudioTelemetry(session.engine(), haveLoad ? &load : null);
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

    private bool moduleExists(uint id) const {
        foreach (ref m; session.document().modules) {
            if (m.id == id) return true;
        }
        return false;
    }
}
