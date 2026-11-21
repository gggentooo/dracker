/**
 * File:         source/main.d
 * Module:       main
 * Phase:        Phase 3.4 / 8.6 — Application Entry Point (GUI + Headless CLI)
 *
 * Purpose:
 *   Provides the process entry point routing between the native macOS Metal studio GUI (StudioGUI version) and headless CLI modes (--cli-demo live CoreAudio/MIDI playback and --render-wav offline export).
 *
 * Real-Time & Safety Contract:
 *   Main UI thread startup; delegates real-time audio exclusively to Engine and CoreAudioDriver on unregistered RT threads.
 *
 * Dependencies:
 *   Internal: app.session, sequencer.engine, platform.interfaces, (version StudioGUI: gui.*, platform.macos.*), (version HeadlessCore: platform.macos.coreaudio, coremidi)
 *   External: Phobos (core.runtime / CLI arg parsing)
 *
 * Planned API (Types, Functions & Hooks):
 *   - int main(string[] args)
 *   - int runCliDemo(string[] args)
 *   - int runOfflineRender(string projectPath, string wavOutPath)
 *   - int runStudioGui(string[] args)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module main;

int main(string[] args) {
    // Phase 0 scaffold entry point: CLI/GUI dispatch implemented in Phases 3 & 8.
    return 0;
}
