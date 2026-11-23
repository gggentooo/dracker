/**
 * File:         source/app/studio_selftest.d
 * Module:       app.studio_selftest
 * Phase:        Phase 7.5.7 — Hardware Studio Backend Self-Test (--studio-selftest)
 *
 * Purpose:
 *   Unattended verification of the Phase 7.5 live backend on real hardware: plays a session project through
 *   CoreAudio via AudioHost for 30 s at 64 and 128 host frames while the UI thread edits the document
 *   (parameters, cells, module add/wire/remove, tempo, retire polling) and requires zero xruns; measures
 *   MIDI-in -> audio latency by sending a note from a second CoreMIDI client to the "Dracker Live MIDI"
 *   virtual destination and timing the first non-silent master scope block; forces a sample-rate mismatch and
 *   verifies AudioHost.poll() re-initializes the session at the device rate and resumes; and checks that an
 *   off-thread export is bit-identical to an offline render of the same document.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Plays audio on the default output device at low master volume (0.08).
 *
 * Dependencies:
 *   Internal: app.{audio_host,session}, io.{audio_io,project_format}, platform.interfaces,
 *             platform.macos.coremidi, sequencer.note
 *   External: core.thread, core.time, std.file, std.path, std.stdio, std.format
 *
 * Planned API (Types, Functions & Hooks):
 *   - int runStudioSelfTest(string[] args)
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 7.5.7)
 */
module app.studio_selftest;

version (OSX):

import core.thread : Thread;
import core.time : dur, MonoTime;
import std.file : mkdirRecurse, rmdirRecurse, tempDir;
import std.format : format;
import std.math : fabs;
import std.path : buildPath;
import std.stdio : stdout, writefln;

import app.audio_host : AudioHost, AudioLoadTelemetry;
import app.session : ExportOptions, ExportState, StudioSession;
import foundation.memory : OwnedBuffer;
import io.audio_io : DecodedAudio, decodeAudioFile, deinterleaveToPlanar;
import io.project_format : LoadedProject, loadProject, serializeProject;
import platform.interfaces : AudioStreamConfig, MidiPacket;
import platform.macos.coremidi : CoreMidiDriver;
import sequencer.engine : ScopeBlock;
import sequencer.note : NoteCell;

private double secondsSince(MonoTime t0) {
    return (MonoTime.currTime - t0).total!"usecs" * 1e-6;
}

private StudioSession buildSong(out uint lead, out uint pad) {
    StudioSession s = new StudioSession();
    if (!s.initialize(44_100.0f)) {
        return null;
    }
    bool ok = s.doSetParam(1, 0, 0.08f);
    lead = s.doAddModule("synth.analog_gen", "Lead");
    pad = s.doAddModule("synth.fm_synth", "Pad");
    immutable uint echo = s.doAddModule("fx.echo", "Echo");
    ok = ok && lead != 0 && pad != 0 && echo != 0;
    ok = ok && s.doConnectWire(lead, 2, echo, 0, 0.8f);
    ok = ok && s.doConnectWire(echo, 1, 1, 0, 1.0f);
    ok = ok && s.doConnectWire(pad, 1, 1, 0, 0.6f);
    foreach (ln; 0 .. 64) {
        if (ln % 4 == 0) {
            ok = ok && s.doPatchCell(1, 0, ln, NoteCell.makeNote(cast(ubyte)(48 + (ln / 4) % 12), 0.8f,
                cast(ushort) lead));
        }
        if (ln % 16 == 0) {
            ok = ok && s.doPatchCell(1, 1, ln, NoteCell.makeNote(cast(ubyte)(60 + (ln / 16) * 3), 0.6f,
                cast(ushort) pad));
        }
    }
    ok = ok && s.doSetLoop(0, 64);
    if (!ok) {
        s.dispose();
        return null;
    }
    return s;
}

/**
 * Runs the hardware backend self-test and prints one PASS/FAIL line per check.
 *
 * Params:
 *   args = Command-line arguments (--quick shortens playback to 8 s per buffer size).
 *
 * Returns:
 *   0 if every check passed.
 */
int runStudioSelfTest(string[] args) {
    bool quick = false;
    foreach (a; args) {
        if (a == "--quick") quick = true;
    }
    size_t failed = 0;
    size_t total = 0;
    void check(string name, bool pass, string detail) {
        total++;
        if (!pass) failed++;
        writefln("%s  %-28s %s", pass ? "PASS" : "FAIL", name, detail);
        stdout.flush();
    }

    uint lead;
    uint pad;
    StudioSession s = buildSong(lead, pad);
    if (s is null) {
        check("startup", false, "session init or song construction failed");
        return 1;
    }
    scope (exit) s.dispose();
    AudioHost host = new AudioHost();
    scope (exit) host.close();
    immutable double playSeconds = quick ? 8.0 : 30.0;

    foreach (bufferFrames; [64u, 128u]) {
        AudioStreamConfig cfg;
        cfg.bufferFrames = bufferFrames;
        cfg.sampleRate = 44_100.0;
        string err;
        if (!host.open(s, cfg, true, err)) {
            check(format("playback @%s frames", bufferFrames), false, err);
            continue;
        }
        host.setMidiTarget(sequencerModule(lead));
        s.seekLine(0);
        s.play();
        AudioLoadTelemetry l0;
        Thread.sleep(dur!"msecs"(300));
        host.readLoad(l0);
        immutable MonoTime t0 = MonoTime.currTime;
        ulong edits = 0;
        uint tempModule = 0;
        float peakLoad = 0.0f;
        while (secondsSince(t0) < playSeconds) {
            host.poll();
            immutable ulong k = edits;
            s.doSetParam(lead, 3, 800.0f + (k % 50) * 60.0f);
            s.doPatchCell(1, 2, cast(uint)(k % 64), (k % 3 == 0) ? NoteCell.makeNote(cast(ubyte)(72 + k % 5), 0.4f,
                cast(ushort) lead) : NoteCell.init);
            if (k % 20 == 0) {
                if (tempModule == 0) {
                    tempModule = s.doAddModule("fx.distortion", "Temp");
                    s.doConnectWire(lead, 2, tempModule, 0, 0.2f);
                    s.doConnectWire(tempModule, 1, 1, 0, 0.2f);
                } else {
                    s.doRemoveModule(tempModule);
                    tempModule = 0;
                }
            }
            if (k % 50 == 0) {
                s.doSetTempo(110.0 + (k / 50) % 30, 6);
            }
            import sequencer.engine : EngineTelemetry;

            EngineTelemetry tel;
            s.pollRetiredAndTelemetry(tel);
            AudioLoadTelemetry lt;
            host.readLoad(lt);
            if (lt.loadPeak > peakLoad) peakLoad = lt.loadPeak;
            edits++;
            Thread.sleep(dur!"msecs"(10));
        }
        AudioLoadTelemetry l1;
        host.readLoad(l1);
        s.stop();
        immutable ulong xr = l1.xruns - l0.xruns;
        immutable bool synced = s.synchronizeEngine();
        check(format("playback @%s frames", bufferFrames),
            xr == 0 && l1.callbacks > l0.callbacks && synced && s.pendingRetiredModuleCount() == 0,
            format("%.0fs @%.0f Hz, %s callbacks, %s xruns, %s UI edits, DSP load avg %.1f%% peak %.1f%%",
                playSeconds, l1.sampleRate, l1.callbacks - l0.callbacks, xr, edits, l1.loadAvg * 100.0f,
                peakLoad * 100.0f));
        host.close();
    }

    {
        AudioStreamConfig cfg;
        cfg.bufferFrames = 128;
        string err;
        double latencyMs = -1.0;
        bool routed = false;
        string destNames;
        bool destFound = false;
        if (host.open(s, cfg, true, err)) {
            host.setMidiTarget(sequencerModule(pad));
            s.stop();
            s.setScopeTaps(true, null);
            uint quietBlocks = 0;
            immutable MonoTime waitStart = MonoTime.currTime;
            while (quietBlocks < 200 && secondsSince(waitStart) < 10.0) {
                ScopeBlock q;
                while (s.engine().tryPopScopeBlock(q)) {
                    bool silent = true;
                    foreach (v; q.left) {
                        if (fabs(v) > 1e-4f) silent = false;
                    }
                    quietBlocks = silent ? quietBlocks + 1 : 0;
                }
                Thread.sleep(dur!"msecs"(2));
            }
            MidiPacket[64] stale;
            host.drainMidi(stale[]);
            CoreMidiDriver sender = new CoreMidiDriver();
            if (sender.open("Dracker SelfTest Sender")) {
                uint destId = uint.max;
                foreach (d; sender.enumerateDestinations()) {
                    destNames ~= "[" ~ d.name ~ "/" ~ d.displayName ~ "]";
                    if (d.name == "Dracker Live MIDI" || d.displayName == "Dracker Live MIDI") {
                        destId = d.id;
                        destFound = true;
                    }
                }
                if (destId != uint.max) {
                    MidiPacket on;
                    on.data = [0x90, 69, 120];
                    on.len = 3;
                    immutable MonoTime sent = MonoTime.currTime;
                    sender.sendPacket(destId, on);
                    while (secondsSince(sent) < 1.0) {
                        ScopeBlock b;
                        bool loud = false;
                        while (s.engine().tryPopScopeBlock(b)) {
                            foreach (v; b.left) {
                                if (fabs(v) > 1e-4f) loud = true;
                            }
                        }
                        if (loud) {
                            latencyMs = secondsSince(sent) * 1000.0;
                            break;
                        }
                        Thread.sleep(dur!"usecs"(200));
                    }
                    MidiPacket[16] seen;
                    routed = host.drainMidi(seen[]) >= 1;
                    MidiPacket off;
                    off.data = [0x80, 69, 0];
                    off.len = 3;
                    sender.sendPacket(destId, off);
                }
                sender.close();
            }
            s.setScopeTaps(false, null);
            check("MIDI-in latency", latencyMs >= 0.0 && latencyMs < 10.0 && routed,
                latencyMs >= 0.0 ? format("%.2f ms virtual destination -> rendered audio (UI copy %s)", latencyMs,
                    routed ? "received" : "missing")
                    : format("no audio within 1 s (destination found=%s, packet reached RT=%s, destinations=%s)",
                        destFound, routed, destNames));

            immutable float deviceRate = s.sampleRate();
            immutable float other = deviceRate == 48_000.0f ? 44_100.0f : 48_000.0f;
            string rerr;
            immutable bool forced = s.changeSampleRate(other, rerr);
            immutable bool recovered = host.poll();
            Thread.sleep(dur!"msecs"(300));
            AudioLoadTelemetry lt;
            host.readLoad(lt);
            check("sample-rate re-init", forced && recovered && s.sampleRate() == deviceRate && host.isRunning()
                && lt.sampleRate == deviceRate,
                format("forced %.0f Hz -> AudioHost restored %.0f Hz and resumed", other, s.sampleRate()));
            host.close();
        } else {
            check("MIDI-in latency", false, err);
        }
    }

    {
        immutable string dir = buildPath(tempDir(), "dracker_studio_selftest");
        mkdirRecurse(dir);
        scope (exit) rmdirRecurse(dir);
        immutable string wav = buildPath(dir, "song.wav");
        ExportOptions opt;
        opt.tailSeconds = 0.5;
        string err;
        ubyte[] bytes;
        bool ok = s.doSetLoop(0, 0) && s.beginExport(wav, opt, err);
        immutable MonoTime t0 = MonoTime.currTime;
        s.waitForExport();
        immutable double secs = secondsSince(t0);
        auto st = s.exportStatus();
        ok = ok && st.state == ExportState.succeeded && s.saveProjectToBytes(bytes, err);
        bool identical = false;
        DecodedAudio decoded;
        if (ok && decodeAudioFile(wav, decoded, err)) {
            OwnedBuffer!float dl;
            OwnedBuffer!float dr;
            deinterleaveToPlanar(decoded, dl, dr);
            StudioSession fresh = new StudioSession();
            fresh.initialize(s.sampleRate());
            scope (exit) fresh.dispose();
            LoadedProject proj;
            loadProject(bytes, proj, err);
            if (fresh.loadProjectFromBytes(bytes, err)) {
                fresh.engine().reset();
                fresh.engine().setTempo(proj.bpm, proj.ticksPerLine);
                fresh.engine().seekLine(0);
                fresh.engine().setPlaying(true);
                OwnedBuffer!float rl;
                OwnedBuffer!float rr;
                if (fresh.engine().renderOfflineToBuffer(cast(size_t) decoded.frames, 512, rl, rr)) {
                    identical = dl[] == rl[] && dr[] == rr[];
                }
            }
        }
        check("export bit-exact", ok && identical,
            format("%s frames (%.1f s of audio) exported in %.2f s, identical to offline render: %s",
                st.framesRendered, st.framesRendered / s.sampleRate(), secs, identical));
    }

    writefln("Studio backend self-test: %s/%s checks passed", total - failed, total);
    return failed == 0 ? 0 : 1;
}

private auto sequencerModule(uint id) {
    import foundation.types : ModuleId;

    return ModuleId(id);
}
