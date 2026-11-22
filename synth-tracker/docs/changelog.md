# SynthTracker Changelog

All major changes to `synth-tracker/` must be recorded in reverse-chronological order (newest entry first).

### Entry Format
- **Timestamp:** `YYYY-MM-DD HH:MM:SS KST` (UTC+09:00)
- **Author:** Human developer name or agent model name
- **Affected Files:** Explicit list of created, modified, or deleted paths
- **Description:** Concise summary of the change(s)

---

## [2026-11-22 09:33:25 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Summary:** Implemented Phase 5 (Tracker Sequencer, Timeline, Supertracks & `MetaModule`) with 8-byte POD `NoteCell` atomic pattern patching, Copy-on-Write `PatternSnapshot` & `TimelineSnapshot` (pattern clones, mute/solo, loops, persistent-lane Supertracks), drift-free 64-bit `RationalClock`, full `TrackEffectBank` effect suite including exact sample-frame sub-line delays (`0x40`–`0x5F`), unified instance-scoped `Engine` with lock-free commands/retire queue & per-module stem WAV export, and re-entrant nested `MetaModule` (`ctl.metamodule`, `MAX_METAMODULE_DEPTH = 16`, 39 built-in registered modules).
- **Changes & Verification:**
  - Graph Protocol Extensions: extended `ProcessContext` with `metaDepth`, added `ModEventKind.setParamNormalized` + `ModuleVTable.setParamNormalized` (mapping `[0..1]` across linear/logarithmic/discrete `@Param` descriptors in `ModuleAdapter!T`), extended `RetiredKind` with `patternSnapshot`/`timelineSnapshot`/`childEngine`, and added `setNodeMuted`, `setNodeBypassed`, `renderQuantumDirect`, and `copyLastNodeAudioBus` on `AudioGraph`.
  - Pattern, Timeline & Clock (`5.1`, `5.2`, `5.3`): implemented 8-byte POD `NoteCell` + `NoteCmd` + `EffectCode` in `source/sequencer/note.d`, unmanaged atomic-patchable `PatternSnapshot` in `source/sequencer/pattern.d`, CoW `TimelineSnapshot` (`TimelineClip`, pattern clones, `SupertrackState`) in `source/sequencer/timeline.d`, 64-bit exact rational `RationalClock` (zero drift under dynamic BPM/TPL edits + `subLineDelaySamples`) in `source/sequencer/clock.d`, and `TrackEffectBank` (`0x01`–`0x5F`, `NoteCmd`, normalized parameter automation, deterministic probability `0x20`–`0x2F`) in `source/sequencer/track_effects.d`.
  - Unified `Engine` & Re-Entrant `MetaModule` (`5.4`, `5.5`): implemented zero-global-state `Engine` (`SpscRing!EngineCommand`, `SpscRing!RetiredResource`, `TripleBuffer!EngineTelemetry`, live QWERTY/MIDI voice tracking, offline mix & `exportStemsWav` exporter) in `source/sequencer/engine.d`, implemented `MetaModule` + `MetaModuleAsset` (`MAX_METAMODULE_DEPTH = 16`, BPM/TPL sync, 8 macro bindings, audio passthrough, off-RT serialization) in `source/modules/control/metamodule.d`, and registered `ctl.metamodule` in `source/graph/registry.d` (39 built-in modules total).
  - Tests & Verification Gate: added [tests/unit/sequencer_test.d](file:///Users/leehk/dev/sunvox_tools/synth-tracker/tests/unit/sequencer_test.d) covering atomic `PatternSnapshot`, 100k-tick `RationalClock`, exact sample `2646` sub-line delay, clones, Supertracks, all effect opcodes, live playback edits + `drainRetireRing()`, per-module stem WAV sum parity, and 2-level nested `MetaModule` + `MAX_METAMODULE_DEPTH` cutoff; updated `modules_test.d` (39 modules) and appended a Phase 5 multi-pattern nested `MetaModule` golden song test in `tests/golden/golden_suite.d`. Verified debug `dub test` (`7 modules passed unittests`), `DFLAGS="-unittest -O3 -w" dub test` (`8 modules passed unittests`, `114` `__unittest` symbols), `dub build --config=headless --build=release`, `--list-devices`, `--cli-demo --duration=0.35 --auto-chord` (`callbacks=123, frames=15744, xruns=0`), `ldc2 -mtriple=x86_64-apple-macos12.0 -O3 -w -unittest` (`X86_64_COMPILE_OK`), `PHASE5_COMMENT_AUDIT_OK: 15 files`, `plutil -lint`, and `clang -Wall -Wextra`.
- **Affected Files:**
  - `synth-tracker/agents.md` (updated — marked Phase 5 and `5.1`–`5.5` complete)
  - `synth-tracker/docs/changelog.md` (updated — added this entry)
  - `synth-tracker/source/graph/{context,event,module_api,audio_graph,registry}.d` (modified)
  - `synth-tracker/source/sequencer/{note,pattern,timeline,clock,track_effects,engine}.d` (created)
  - `synth-tracker/source/modules/control/metamodule.d` (created)
  - `synth-tracker/tests/unit/sequencer_test.d` (created)
  - `synth-tracker/tests/unit/modules_test.d`, `synth-tracker/tests/golden/golden_suite.d` (modified)

---

## [2026-11-22 09:17:07 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Summary:** Implemented Phase 4 (Built-In Module Library — Tier 1 & Tier 2) with all 38 built-in `ModuleRegistry` modules, off-RT `StreamWorker` background audio decode/streaming (`VorbisPlayer` + `StreamAudioRing`), host duplex audio-input staging in `AudioGraph`, automated `@nogc` + `rt_malloc_trap` unit and golden WAV verification suites, `-O3` allocator/GC trap escape hardening in `foundation_test.d`, and updated checklist/changelog documentation.
- **Changes & Verification:**
  - Core & Expansion Effects (`4.1`, `4.6`, `4.7`): implemented `FilterPro`, `Distortion`, `Delay`, `Echo`, `Reverb` (8-line Householder FDN), `Compressor` (with `sidechainStereo`), `Eq3Band`, `WaveShaper` (1x/2x/4x oversampling + swappable table), `Flanger`, `Vibrato`, `Modulator` (audio/CV ring/AM/PM), `SmoothFx`, `VocalFilter`, `PitchShifter`, `FftFx` (75%-overlap STFT via `FftFloat`), and `LoopFx`.
  - Core & Expansion Control (`4.2`, `4.8`): implemented `MultiSynth`, `MultiCtl` (with swappable fan-out curve/target maps), `AdsrMod`, `LfoMod`, `Glide`, `Ctl2Note`, `Pitch2Ctl`, `Velocity2Ctl`, `Sound2Ctl`, and `PitchDetector` (first-peak NSDF MPM autocorrelation + zero-crossing pitch-to-note tracking).
  - Core & Expansion Synths, Sampler & Streaming (`4.3`, `4.4`, `4.9`): implemented `Kicker`, `DrumSynth`, `AnalogGen` (32-voice unison + drawn wavetable asset), `FmSynth` (5-op 6-algo), `Sampler` (multi-slot keymap, Catmull-Rom/linear/nearest, forward/ping-pong loops, breakpoint envelopes, off-RT decode, `swapAsset`, serialization), `SpectraVoice` (inverse-FFT harmonic wavetables), `AudioInput` (`synth.input` reading staged duplex host input from `ProcessContext.hostAudioIn`), and `StreamWorker` + `VorbisPlayer` (`StreamAudioRing` wait-free streaming with zero RT syscalls).
  - Graph & Registry: extended `ProcessContext` and `AudioGraph` with lock-free host audio input ring staging and sub-block slicing, and statically registered all 38 built-in modules in `ModuleRegistry` (`source/graph/registry.d`).
  - Verification & Test Suites (`4.5`): added `tests/unit/modules_test.d` (38-module silence/extreme/`rt_malloc_trap` matrix, per-module DSP/asset/serialization/streaming checks, `DummyExtensibilityModule` 1-file/1-line contract) and `tests/golden/golden_suite.d` (multi-module patches, 64..512 buffer-size invariance, cyclic `Feedback` determinism, golden WAV round-trips); fixed `tests/unit/foundation_test.d` allocator/GC escape sinks so `-unittest -O3` does not dead-eliminate trap checks. Verified `dub test` (`6 modules passed unittests`), `DFLAGS="-unittest -O3 -w" dub test` (`7 modules passed unittests`, `102` `__unittest` symbols), `dub build --config=headless --build=release`, `--list-devices`, `--cli-demo --duration=0.35 --auto-chord` (`callbacks=116, frames=14848, xruns=0`), `ldc2 -mtriple=x86_64-apple-macos12.0 -O3 -w -unittest` (`X86_64_COMPILE_OK`), `PHASE4_COMMENT_AUDIT_OK: 46 files`, `plutil -lint`, and `clang -Wall -Wextra`.
- **Affected Files:**
  - `synth-tracker/agents.md` (updated — marked Phase 4 and `4.1`–`4.9` complete)
  - `synth-tracker/docs/changelog.md` (updated — added this entry)
  - `synth-tracker/source/graph/context.d`, `synth-tracker/source/graph/audio_graph.d`, `synth-tracker/source/graph/registry.d` (modified)
  - `synth-tracker/source/modules/effects/{filter_pro,distortion,delay,echo,reverb,compressor,lfo,eq,waveshaper,flanger,vibrato,modulator,smooth_fx,vocal_filter,pitch_shifter,fft_fx,loop_fx}.d` (created)
  - `synth-tracker/source/modules/control/{multisynth,multictl,adsr_mod,glide,ctl2note,pitch2ctl,velocity2ctl,sound2ctl,pitch_detector}.d` (created)
  - `synth-tracker/source/modules/synths/{kicker,drumsynth,analog_gen,fm_synth,sampler,spectravoice,input,vorbis_player}.d` (created)
  - `synth-tracker/source/sequencer/stream_worker.d` (created)
  - `synth-tracker/tests/unit/modules_test.d`, `synth-tracker/tests/golden/golden_suite.d` (created)
  - `synth-tracker/tests/unit/foundation_test.d` (modified)

---

## [2026-11-22 08:46:27 KST]
- **Timestamp:** `2026-11-22 08:46:27 KST`
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `synth-tracker/source/platform/interfaces.d`
  - `synth-tracker/source/platform/macos/corefoundation.d`
  - `synth-tracker/source/platform/macos/coreaudio.d`
  - `synth-tracker/source/platform/macos/coremidi.d`
  - `synth-tracker/source/main.d`
  - `synth-tracker/tests/unit/platform_test.d`
  - `synth-tracker/agents.md`
  - `synth-tracker/docs/changelog.md`
- **Description:** Implemented Phase 3 (Native macOS Audio & MIDI Layer): froze `platform.interfaces` (`IAudioDriver`, `IMidiDriver`, `IPlatformWindow`, `IFileDialog`, `MidiPacket`), added `extern(C)` CoreFoundation UTF-8/`ScopedCF`/`MachTimebase` helpers (`corefoundation.d`), implemented `CoreAudioDriver` AUHAL output + same-device direct duplex + dual-device PI `DriftCompensatedInputRing` with `ScopedNoDenormals` and hot-plug/sample-rate property listeners (`coreaudio.d`), implemented `CoreMidiDriver` with architecture-safe `midiPacketNext`, running-status/SysEx MIDI 1.0 parser, multi-source `MpscRing!MidiPacket`, virtual endpoints, and `MidiNoteTracker`/`ModEvent` translation (`coremidi.d`), wired `main.d` (`--list-devices`, `--cli-demo` live polyphonic `CliDemoPolySynth` + `AudioGraph`), and verified with `tests/unit/platform_test.d` under `rt_malloc_trap` and live CoreAudio/CoreMIDI checks.

## [2026-11-22 07:06:26 KST]
- **Timestamp:** `2026-11-22 07:06:26 KST`
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `synth-tracker/source/foundation/concurrency.d`
  - `synth-tracker/source/graph/port.d`
  - `synth-tracker/source/graph/event.d`
  - `synth-tracker/source/graph/context.d`
  - `synth-tracker/source/graph/buffer.d`
  - `synth-tracker/source/graph/module_api.d`
  - `synth-tracker/source/graph/registry.d`
  - `synth-tracker/source/graph/plan.d`
  - `synth-tracker/source/graph/audio_graph.d`
  - `synth-tracker/source/modules/output.d`
  - `synth-tracker/source/modules/effects/amplifier.d`
  - `synth-tracker/source/modules/effects/dc_blocker.d`
  - `synth-tracker/source/modules/control/feedback.d`
  - `synth-tracker/tests/unit/graph_test.d`
  - `synth-tracker/agents.md`
  - `synth-tracker/docs/changelog.md`
- **Description:** Implemented Phase 2 (Fixed-Quantum AudioGraph & UDA Module Protocol): typed port descriptors, sample-accurate `ModEvent`/`EventArena`/`EventSink`, `ProcessContext`/`ProcessIO` audio+CV slice views, UDA `@Param` + `assertNoNaNInit!T` + named `onParamChanged!field` + `@nogc` `ModuleAdapter!T`, `ModuleRegistry`, off-RT `GraphCompiler` with topological sort and `FeedbackReceive`/`FeedbackSend` cycle splitting into `@nogc` `GraphPlan`, real-time `AudioGraph` with 64-frame fixed quanta, sample-accurate event sub-blocking, fan-in audio/sidechain/CV mixing, silence skipping, mid-stream `swapPlan`/`swapModuleAsset` retirement, and `TripleBuffer!GraphTelemetry`, plus Tier 1 modules (`MasterOutput`, `Amplifier`, `DcBlocker`, `Feedback`), `SpscRing`/`MpscRing` pointer-indirection safety fix in `concurrency.d`, and comprehensive `graph_test.d` determinism/allocation-trap unit tests.

## [2026-11-21 21:42:01 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `synth-tracker/source/dsp/tables.d` (implemented)
  - `synth-tracker/source/dsp/interp.d` (implemented)
  - `synth-tracker/source/dsp/resampler.d` (implemented)
  - `synth-tracker/source/dsp/fft.d` (implemented)
  - `synth-tracker/source/dsp/filter_biquad.d` (implemented)
  - `synth-tracker/source/dsp/filter_svf.d` (implemented)
  - `synth-tracker/source/dsp/oscillator.d` (implemented)
  - `synth-tracker/source/dsp/smoother.d` (implemented)
  - `synth-tracker/source/dsp/envelope.d` (implemented)
  - `synth-tracker/source/dsp/delay_line.d` (implemented)
  - `synth-tracker/source/dsp/voice_pool.d` (implemented)
  - `synth-tracker/tests/unit/dsp_test.d` (created)
  - `synth-tracker/agents.md` (updated Phase 1 checklist)
  - `synth-tracker/docs/changelog.md` (updated)
- **Description:** Completed Phase 1 (Core DSP Primitives & Shared Polyphony): implemented all 11 `@nogc nothrow` DSP modules (`tables.d` immutable sine/half-sine/window tables, `interp.d` nearest/linear/Hermite/Catmull-Rom kernels, `resampler.d` causal streaming `FractionalResampler`/`StereoResampler`, `fft.d` explicit `float`/`double` radix-2 FFT/IFFT, `filter_biquad.d` double-state 1-pole/RBJ biquad/cascaded filters, `filter_svf.d` Cytomic TPT SVF, `oscillator.d` PolyBLEP/PolyBLAMP/drawn-wave/deterministic noise, `smoother.d` `ParamSmoother`/`LinearRamp`, `envelope.d` `AdsrEnvelope`/`BreakpointEnvelope`, `delay_line.d` power-of-two `DelayLine`, and `voice_pool.d` `VoicePool!(VoiceT, MaxVoices)`); added comprehensive unit and `rt_malloc_trap` audits in `tests/unit/dsp_test.d`. Verified zero warnings across `dub test --config=headless` (debug & `-O3`), `dub build --config=headless --build=release`, and `x86_64` cross-compilation.

## [2026-11-21 21:29:57 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `synth-tracker/dub.json` (updated)
  - `synth-tracker/dub.selections.json` (created)
  - `synth-tracker/ci/macos.yml` (updated)
  - `synth-tracker/agents.md` (updated Phase 0 checklist)
  - `synth-tracker/source/main.d` (cleaned inline comment)
  - `synth-tracker/source/foundation/types.d` (implemented)
  - `synth-tracker/source/foundation/memory.d` (implemented)
  - `synth-tracker/source/foundation/concurrency.d` (implemented)
  - `synth-tracker/source/foundation/math_rt.d` (implemented)
  - `synth-tracker/source/io/audio_io.d` (implemented)
  - `synth-tracker/tests/rt_malloc_trap.d` (implemented)
  - `synth-tracker/tests/audio_harness.d` (implemented)
  - `synth-tracker/tests/unit/foundation_test.d` (implemented)
  - `synth-tracker/docs/changelog.md` (updated)
- **Description:** Completed Phase 0 (Scaffolding, `@nogc` Foundation & Verification Harness): verified `audio-formats` 3.1.0 `boost` subconfiguration and pinned `dub.selections.json`; configured `dub.json` headless test discovery and updated `ci/macos.yml`; implemented `@nogc nothrow` `foundation/{types,memory,concurrency,math_rt}.d` (`OwnedBuffer!T`, `FixedArray`, `Arena`, `Atomic!T`, `SpscRing!T`, `MpscRing!T`, `TripleBuffer!T`, `ScopedNoDenormals` for `arm64`/`x86_64`, pitch/dB tables); implemented `io/audio_io.d` using `audio-formats` (`boost`) for decoding and a pure-D IEEE-float32 RIFF/WAVE writer bypassing upstream `audio-formats` 3.1.0 WAV-encoder defects; implemented `tests/rt_malloc_trap.d`, `tests/audio_harness.d`, and full unit/10M-message stress tests in `tests/unit/foundation_test.d`. Verified zero warnings across `dub test --config=headless` (debug & `-O3`), `dub build --config=headless --build=release`, and `x86_64` cross-compilation.

## [2026-11-21 20:59:47 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `.gitignore` (created at repository root)
  - `synth-tracker/docs/changelog.md` (updated)
- **Description:** Added root `.gitignore` ignoring everything outside `synth-tracker/` plus standard OS, D/LDC2/DUB, Metal/Xcode, and IDE artifacts; verified zero tracked ignored files remained in the index.

## [2026-11-21 20:45:11 KST]
- **Author:** Antigravity (Gemini 4 Neon)
- **Affected Files:**
  - `synth-tracker/docs/` (created directory)
  - `synth-tracker/agents.md` (created)
  - `synth-tracker/docs/changelog.md` (created)
- **Description:** Created `synth-tracker/docs/`, authored `synth-tracker/agents.md` at the project root as the agent source-of-truth reference (covering design invariants, directory map, phased implementation checklists with strict exit gates, build/test commands, strict document/DDoc-only comment rules, pure-D FFI policy, and changelog requirements), and initialized `synth-tracker/docs/changelog.md` with its first entry.
