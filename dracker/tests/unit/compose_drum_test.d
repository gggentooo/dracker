/**
 * File:         tests/unit/compose_drum_test.d
 * Module:       tests.unit.compose_drum_test
 * Phase:        Composition helper (dracker-compose) — T79 (Drum parts tests)
 *
 * Purpose:
 *   Unit tests for compose.drum_writer: default DrumSynth kit lanes, custom multi-module drum lanes,
 *   step strings with normal/accent/ghost/rest symbols and bar dividers, position hits, repeating bar-range
 *   fills, structured errors with nearest suggestions, and full StudioSession drumpad model compatibility
 *   (patternKind, patternLanes, drumHitAt) plus audible rendered output.
 *
 * Real-Time & Safety Contract:
 *   Off-RT unit tests; no filesystem I/O.
 *
 * Dependencies:
 *   Internal: app.session (StudioSession), compose.drum_writer, compose.module_writer, compose.part_writer,
 *             compose.project_writer, compose.timing, foundation.memory (OwnedBuffer), io.project_format
 *             (PATTERN_KIND_DRUM)
 *   External: std.algorithm (canFind), std.math (fabs)
 *
 * Planned API (Types, Functions & Hooks):
 *   - version(unittest) tests covering all T79 requirements
 *
 * See_Also:
 *   docs/todo.md (T68, T79), source/compose/drum_writer.d
 */
module tests.unit.compose_drum_test;

version (unittest) {
    import std.algorithm : canFind;
    import std.math : fabs;

    import app.session : StudioSession;
    import compose.drum_writer : DrumEditResult, DrumLaneInfo, DrumProblemKind, DrumWriter,
        DRUMSYNTH_DEFAULT_KIT;
    import compose.module_writer : ModuleWriter;
    import compose.part_writer : PartWriter;
    import compose.project_writer : ProjectWriter;
    import compose.timing : BeatPosition;
    import foundation.memory : OwnedBuffer;
    import io.project_format : PATTERN_KIND_DRUM;

    unittest {
        ProjectWriter proj = new ProjectWriter();
        assert(proj.setTempo(120.0).ok);
        auto drumsMod = ModuleWriter.fromType("synth.drumsynth");
        assert(drumsMod.ok);
        auto percSynth = ModuleWriter.fromType("synth.analog_gen");
        assert(percSynth.ok);
        assert(proj.addModule("drums", drumsMod.writer).ok);
        assert(proj.addModule("perc", percSynth.writer).ok);
        assert(proj.connect("drums", "out", 0.8f).ok);
        assert(proj.connect("perc", "out", 0.5f).ok);

        PartWriter pw = new PartWriter(proj);
        assert(pw.addSection("verse", 2).ok);
        assert(pw.arrange(["verse"]).ok);

        DrumWriter dw = new DrumWriter(pw);
        assert(dw.addDrumPart("kit", "drums").ok);
        assert(dw.hasDrumPart("KIT"));
        assert(dw.lanesOf("kit").length == DRUMSYNTH_DEFAULT_KIT.length);

        assert(dw.addLanePitch("kit", "Ping", "perc", "C5").ok);
        assert(dw.lanesOf("kit").length == DRUMSYNTH_DEFAULT_KIT.length + 1);

        assert(dw.writeSteps("kit", "verse", "Kick", "X---x--- | x---x---").ok);
        assert(dw.writeSteps("kit", "verse", "Closed Hat", "x-g-x-g-").ok);
        assert(dw.writeHit("kit", "verse", "Ping", BeatPosition(1, 2, 1), 0.7f).ok);
        assert(dw.writeFill("kit", "verse", "Snare", 2, 2, "--X-").ok);

        auto docRes = dw.buildDocument();
        assert(docRes.ok, docRes.problem.reason);
        assert(docRes.project.patterns.length == 1);
        assert(docRes.project.patterns[0].name == "kit \u00B7 verse");

        StudioSession s = new StudioSession();
        assert(s.initialize(44_100.0f));
        scope (exit) s.shutdown();
        string err;
        assert(s.openProjectFromMemory(docRes.project, err), err);

        immutable uint pid = docRes.project.patterns[0].patternId;
        assert(s.patternKind(pid) == PATTERN_KIND_DRUM);
        auto lanes = s.patternLanes(pid);
        assert(lanes.length == DRUMSYNTH_DEFAULT_KIT.length + 1);
        assert(lanes[0].name == "Kick" && lanes[0].note == 36);
        assert(lanes[1].name == "Snare" && lanes[1].note == 38);
        assert(lanes[$ - 1].name == "Ping" && lanes[$ - 1].note == 72);

        float vel = 0.0f;
        bool custom = false;
        assert(s.drumHitAt(pid, 0, 0, vel, custom) && vel > 0.95f && !custom);
        assert(!s.drumHitAt(pid, 0, 1, vel, custom));
        assert(s.drumHitAt(pid, 0, 4, vel, custom) && vel > 0.75f && vel < 0.85f);
        assert(s.drumHitAt(pid, 0, 8, vel, custom));
        assert(s.drumHitAt(pid, 0, 12, vel, custom));

        assert(s.drumHitAt(pid, 2, 0, vel, custom) && vel > 0.75f);
        assert(s.drumHitAt(pid, 2, 2, vel, custom) && vel < 0.55f);

        assert(!s.drumHitAt(pid, 1, 2, vel, custom));
        assert(s.drumHitAt(pid, 1, 18, vel, custom) && vel > 0.95f);
        assert(s.drumHitAt(pid, 1, 22, vel, custom));
        assert(s.drumHitAt(pid, 1, 26, vel, custom));
        assert(s.drumHitAt(pid, 1, 30, vel, custom));

        assert(s.drumHitAt(pid, cast(uint)(lanes.length - 1), 4, vel, custom));

        s.engine().reset();
        s.engine().setTempo(docRes.project.bpm, docRes.project.ticksPerLine);
        s.engine().seekLine(0);
        s.engine().setPlaying(true);
        OwnedBuffer!float outL;
        OwnedBuffer!float outR;
        assert(s.engine().renderOfflineToBuffer(4096, 64, outL, outR));
        float peak = 0.0f;
        foreach (i; 0 .. outL.length) {
            immutable float a = fabs(outL[i]) > fabs(outR[i]) ? fabs(outL[i]) : fabs(outR[i]);
            if (a > peak) peak = a;
        }
        assert(peak > 0.01f);
    }

    unittest {
        ProjectWriter proj = new ProjectWriter();
        auto drumsMod = ModuleWriter.fromType("synth.drumsynth");
        assert(drumsMod.ok);
        assert(proj.addModule("drums", drumsMod.writer).ok);
        PartWriter pw = new PartWriter(proj);
        assert(pw.addSection("a", 2).ok);
        DrumWriter dw = new DrumWriter(pw);
        assert(dw.addDrumPart("kit", "drums").ok);

        immutable DrumEditResult badLane = dw.writeSteps("kit", "a", "Kikc", "x---");
        assert(!badLane.ok && badLane.problem.kind == DrumProblemKind.unknownLane);
        assert(badLane.problem.suggestion == "Kick");
        assert(badLane.problem.text().canFind("did you mean 'Kick'?"));

        immutable DrumEditResult badStep = dw.writeSteps("kit", "a", "Kick", "x-z-");
        assert(!badStep.ok && badStep.problem.kind == DrumProblemKind.invalidStep);

        immutable DrumEditResult badFill = dw.writeFill("kit", "a", "Snare", 1, 5, "x-");
        assert(!badFill.ok && badFill.problem.kind == DrumProblemKind.invalidBarRange);
        assert(badFill.problem.suggestion == "2");
    }
}
