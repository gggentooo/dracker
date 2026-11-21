/**
 * File:         tests/audio_harness.d
 * Module:       tests.audio_harness
 * Phase:        Phase 0.5 — Offline Golden WAV Renderer & Audio Metric Harness
 *
 * Purpose:
 *   Renders graphs and Engine projects deterministically offline, compares PCM buffers against golden WAV references, and asserts SNR and peak error tolerances.
 *
 * Real-Time & Safety Contract:
 *   Test harness (runs off-RT; drives @nogc render calls across varying simulated host block sizes).
 *
 * Dependencies:
 *   Internal: foundation.types, sequencer.engine, io.audio_io
 *   External: core.stdc.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct AudioMetrics { double peakError; double rmsError; double snrDb; bool hasNaN; }
 *   - AudioMetrics compareAudio(const(float)[] actual, const(float)[] expected)
 *   - void assertBufferSizeInvariance(string projectPath)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.audio_harness;
