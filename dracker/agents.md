# Dracker — Agent Source-of-Truth Guide

> **Project:** Clean-slate modular synthesizer & tracker inspired by SunVox  
> **Language:** Idiomatic D2 (**LDC2 1.40+**, macOS Universal `arm64` + `x86_64`)  
> **Target:** Native macOS desktop `.app` bundle (AppKit + Metal GUI), architected for future Linux/Windows portability  
> **Authoritative References:** [architecture_proposal.md](../architecture_proposal.md) | [dev_plan_proposal.md](../dev_plan_proposal.md) | [docs/changelog.md](./docs/changelog.md)

---

## 1. Non-Negotiable Engineering & Agent Rules

Every contributor and autonomous agent working in `dracker/` **must** follow these four rules without exception:

### Rule 1 — Strict Comment Policy (No Inline Comments)
Comments are permitted **only** in two places:
1. **Document-level header block** (`/** ... */`) at the very top of each source file describing file path, module name, phase/subtask, purpose, real-time/safety contract, internal/external dependencies, and public/planned API.
2. **Function-level DDoc comment block** (`/** ... */`) immediately above each function or method declaration, following standard DDoc conventions (`Params:`, `Returns:`, and safety/contract notes).

**Inline comments inside function bodies, trailing end-of-line comments on statements or struct fields, and mid-function comment blocks are strictly prohibited.** Code should remain self-explanatory via clear naming and small functions.

Valid function-level DDoc example:

```d
/**
 * Converts a MIDI note number (including fractional microtones) to frequency in Hz.
 *
 * Params:
 *   midiNote = Fractional MIDI note value where 69.0f equals A4 (440.0 Hz).
 *
 * Returns:
 *   Frequency in Hertz, safe to invoke from @nogc nothrow pure real-time contexts.
 */
float midiNoteToHz(float midiNote) @nogc nothrow pure {
    immutable float clamped = clampNoteRange(midiNote);
    return lookupPitchHz(clamped);
}
```

### Rule 2 — Strict Phase Exit Criteria Gate
No phase or subtask may be marked `[x]` completed unless **every** exit criterion for that phase is objectively met and verified:
- **Complete unit test coverage** for **all** components implemented in that phase passes without skipped or relaxed assertions.
- Real-time audio components pass both static `@nogc nothrow` compilation and runtime `tests/rt_malloc_trap.d` allocation audits.
- All files compile with zero warnings under `ldc2 -w` (and `clang -Wall -Wextra` for the Objective-C shim).

### Rule 3 — Pure-D Language Policy
The entire program must be written **strictly in D2**. Foreign interfaces are permitted **only** where unavoidable to bind native OS hardware and system frameworks, and must never leak outside `source/platform/macos/` and `shaders/`:
- **Allowed FFI:** `extern(C)` / `extern(Objective-C)` bindings for Apple `CoreAudio`, `AudioToolbox`, `CoreMIDI`, `AppKit`/`Cocoa`, `Metal`, `QuartzCore`, `CoreText`, `CoreGraphics`, and `CoreFoundation`; the ~60-LOC Clang Block bridge [`source/platform/macos/objc_blocks_shim.m`](./source/platform/macos/objc_blocks_shim.m); and Metal shader code in [`shaders/ui2d.metal`](./shaders/ui2d.metal).
- **Prohibited:** Third-party C/C++ libraries (no SDL2, FreeType, Raylib, RtMidi, libFLAC, libvorbis, or raw C/C++ DSP modules). Audio codecs use pure-D `audio-formats` (`boost` subconfiguration).

### Rule 4 — Mandatory Changelog Logging (`docs/changelog.md`)
All major changes to the codebase must be recorded in [docs/changelog.md](./docs/changelog.md) in reverse-chronological order (newest entry at the top). Every entry **must** include:
1. **Datetime stamp in KST** (`YYYY-MM-DD HH:MM:SS KST`, UTC+09:00).
2. **Author's name** (or human-readable agent model name).
3. **List of affected files/directories**.
4. **Brief description of the change(s)**.

### Rule 5 - Require Explicit Owner Confirmation for Critical Changes/Decisions
For any changes or decisions that may have significant impact on the codebase, the human owner of the codebase must be consulted for approval before the change is made. This is to ensure that the change is in line with the project's goals and vision.

---

## 2. Core Architecture & Real-Time Invariants

1. **Hard Real-Time Safety (`@nogc nothrow`):** All code on the audio rendering path (`dsp/`, `graph/`, `modules/`, RT `sequencer/`, and `coreaudio.d` render callback) compiles `@nogc nothrow` with zero GC allocations, zero mutexes, and zero blocking syscalls/file I/O.
2. **Unregistered Audio Thread & Zero-GC-Pointer Boundary:** CoreAudio's RT thread is never registered with the D GC (eliminating stop-the-world GC audio stalls). Because the GC never scans the RT thread's stack or registers, **zero GC-managed pointers may ever cross into RT-owned structs**. All RT buffers use `@nogc` `OwnedBuffer!T` (`static assert(!hasIndirections!T)`, `core.checkedint.mulu` overflow guard, 32-byte alignment) and retire back to the UI thread via `RetireRing`.
3. **Fixed Processing Quantum (`FIXED_BLOCK_FRAMES = 64`):** All `AudioGraph` and `Sequencer` steps execute in fixed 64-frame internal slices (~1.45 ms at 44.1 kHz). Host callbacks of arbitrary size are staged through a pre-allocated buffer adapter, guaranteeing buffer-size-independent feedback delay, consistent control modulation, and bit-exact live-vs-offline determinism.
4. **Zero Global Mutable State:** `Engine`, `AudioGraph`, and `Sequencer` are strictly instance-scoped; lookup tables are `immutable`. Nested `MetaModule` sub-graphs (`MAX_METAMODULE_DEPTH = 16`) and parallel test runners are re-entrant.
5. **Compile-Time UDA Module Protocol:** Every module is one self-contained `.d` file + one line in `graph/registry.d`. `ModuleAdapter!T` reflects `@Param` UDAs and `PortDescriptor`s (`audioStereo`, `audioMono`, `sidechainStereo`, `event`, `cvControl`), passes `ProcessContext`, runs `assertNoNaNInit!T()`, dispatches `onParamChanged!field(sampleRate, instant)` by field name, and supports `serializeExtra` / `deserializeExtra` / `swapAsset` hooks. Discrete events use `ModEvent`; audio-rate modulation uses `PortKind.cvControl` 64-frame buffers.
6. **Shared Polyphony & Denormal Control:** Polyphonic synths (`AnalogGen`, `FmSynth`, `Sampler`, `SpectraVoice`) share `dsp/voice_pool.d` (`VoicePool!(VoiceT, MaxVoices)`). Global `--ffast-math` is omitted; `ScopedNoDenormals` uses `ldc.llvmasm.__asm` (`AArch64` `fpcr` bit 24 / `X86_64` `MXCSR` `FTZ`+`DAZ`) on audio/offline entry.
7. **Objective-C Runtime Discipline:** `extern(Objective-C)` has no ARC or Clang Blocks (`^`). AppKit ticks and every Metal `CAMetalLayer` frame must be wrapped in `ScopedAutoreleasePool`, with `objc_blocks_shim.m` bridging `addCompletedHandler:` and async `NSOpenPanel`/`NSSavePanel` sheets (`metal-cpp` via `extern(C++)` is the Phase 7 fallback if needed).

### UI ↔ RT Lock-Free Mutation Summary

| Domain | Off-RT Preparation | RT Boundary Handoff | Off-RT Reclamation |
| --- | --- | --- | --- |
| **Graph Wiring** | `GraphCompiler.compile()` builds `@nogc` `GraphPlan` | `SwapGraphPlan` on SPSC `CommandRing` | Old `GraphPlan` → `RetireRing` |
| **Modules** | Constructed & `prepare()`'d off-RT | Referenced by new `GraphPlan` | Removed nodes → `RetireRing` |
| **Pattern Cells** | Atomic 8-byte POD `NoteCell` write / `PatchCell` | Lock-free POD read on pattern step | None |
| **Pattern Resize / Clips / Clones / Supertracks** | Build `@nogc` CoW `PatternSnapshot` / `TimelineSnapshot` | `SwapPatternSnapshot` / `SwapTimelineSnapshot` | Old snapshots → `RetireRing` |
| **Heavy Assets** (`Sampler`, curves, wavetables, `MetaModule`) | Decoded/built off-RT (`audio_io.d` / `stream_worker.d`) | `SwapModuleAsset` via `ModuleVTable.swapAsset` | Replaced buffer → `RetireRing` |
| **Scalar Params** | `SetParam(modId, paramId, val, bool instant)` | Instant snap (`instant = true`) or smoother (`false`) | None |
| **Live Audio Host** *(7.5.1)* | `Engine` + `EngineRtContext` allocated unmanaged (`malloc`) | CoreAudio callback `userData` = `EngineRtContext*` (zero GC pointers) | Freed after `IAudioDriver.stop()` returns |
| **Live MIDI** *(7.5.2)* | CoreMIDI thread → `MpscRing!MidiPacket` | Drained in the render callback → `Engine.applyLiveMidi*` (RT-thread direct, never the UI command ring) | Copy → `SpscRing!MidiPacket` UI ring |
| **MIDI Map** *(7.5.2)* | Build immutable POD `MidiMapSnapshot` | `SwapMidiMap` | Old snapshot → `RetireRing` |
| **Scope Taps & Load** *(7.5.3)* | `SetScopeTaps` (≤ 4 module ids + master) | RT pushes `ScopeBlock` to `SpscRing!ScopeBlock`; load stats via `TripleBuffer!AudioLoadTelemetry` | UI drains (drop-on-full counted) |

---

## 3. Repository & Package Map

| Path | Ownership & Role | Safety / Thread Boundary |
| --- | --- | --- |
| `source/foundation/` | `types.d`, `memory.d` (`OwnedBuffer!T`, `FixedArray`, `Arena`), `concurrency.d` (`SpscRing`, `MpscRing`, `TripleBuffer`), `math_rt.d` (`ScopedNoDenormals`) | `@nogc nothrow`, zero GC indirections |
| `source/dsp/` | `tables.d`, `fft.d`, `interp.d`, `resampler.d`, `filter_biquad.d`, `filter_svf.d`, `smoother.d`, `oscillator.d`, `envelope.d`, `delay_line.d`, `voice_pool.d` | `@nogc nothrow`, explicit `= 0.0f` FP init |
| `source/graph/` | `port.d`, `context.d`, `event.d`, `buffer.d`, `module_api.d`, `registry.d`, `plan.d`, `audio_graph.d` | `GraphCompiler` off-RT; `AudioGraph` `@nogc nothrow` RT |
| `source/modules/` | `output.d`, `synths/` (8), `effects/` (19), `control/` (11) | `@nogc nothrow` RT; zero syscalls |
| `source/sequencer/` | `note.d`, `pattern.d`, `timeline.d`, `clock.d`, `track_effects.d`, `stream_worker.d`, `engine.d` | RT step `@nogc nothrow`; `stream_worker.d` off-RT worker |
| `source/io/` | `binary_stream.d`, `project_format.d`, `audio_io.d`, `importers/` (`.mid`, `.xm`, `.sunvox`) | `@safe` off-RT I/O & `audio-formats` (`boost`) |
| `source/app/` | `session.d`, `history.d`, `keymap.d`, `pattern_ops.d`, `telemetry.d`, `music_theory.d` (keys, scales, note spelling), `skeleton_gen.d` (skeleton project generator: instrument choices, sound-check preview), `chord_progression.d` (chord and progression parser), `pattern_notes.d` (piano-roll note model), `instrument_library.d` (bundled and user preset library), `factory_presets.d` (bundled preset definitions; files in `resources/presets/`), `audio_host.d` + `studio_selftest.d` (macOS), `gui_shell.d` + `gui_gallery.d` + `studio_app.d` (`StudioGUI` only) | Main/UI thread orchestration, undo/redo, native GUI main loop & `--gui-selftest` |
| `source/gui/` | `renderer.d`, `theme.d`, `layout.d`, `widgets.d`, `views/` (`studio_context.d`, `studio_root.d` + 7 studio views, `appearance_panel.d`, `skeleton_panel.d` (skeleton project generator panel), `piano_roll_view.d`, `drumpad_view.d`, `instrument_sidebar.d`) | Main/UI thread only; toolkit and all views are built and unit-tested in `headless` |
| `source/platform/` | `interfaces.d` + `macos/` (`corefoundation.d`, `coreaudio.d`, `coremidi.d`, `objc_runtime.d`, `objc_blocks_shim.m`, `appkit.d`, `coretext.d`, `metal_renderer.d`) | Only OS FFI boundary in the project |
| `shaders/` | `ui2d.metal` (Metal 2D instanced UI, Beziers, R8 glyphs) | Compiled to `build/ui2d.metallib` |
| `resources/` | `fonts/`, `presets/` (bundled `.msym` presets matching `app.factory_presets`) | Read-only app resources |
| `packaging/macos/`, `ci/` | `Info.plist`, `entitlements.plist`, `bundle_macos.sh`, `macos.yml` | Release bundling & CI automation |
| `tests/` | `audio_harness.d`, `rt_malloc_trap.d`, `unit/`, `golden/`, `fuzz/` | Offline CI & local verification |
| `docs/` | `manual.md`, `todo.md`, `changelog.md` | User manual, task tracker, mandatory change log (Rule 4) |

---

## 4. Phased Implementation Steps & Exit Criteria

Each phase below tracks status with `[ ]` / `[x]`. Do not mark any item `[x]` until **all** exit criteria (including unit tests for every implemented component) pass.

### `[x]` Phase 0 — Scaffolding, `@nogc` Foundation & Verification Harness *(No dependencies)*
- **Subtasks:**
  - `[x]` `0.1` Verify `dub.json` (`audio-formats` Boost subconfig via `dub describe`) and `ci/macos.yml`.
  - `[x]` `0.2` Implement `foundation/memory.d` (`OwnedBuffer!T`, `FixedArray!(T, N)`, `Arena`).
  - `[x]` `0.3` Implement `foundation/concurrency.d` (`SpscRing!T`, `MpscRing!T`, `Atomic!T`, `TripleBuffer!T`).
  - `[x]` `0.4` Implement `foundation/types.d` & `foundation/math_rt.d` (`ScopedNoDenormals`, pitch/dB helpers).
  - `[x]` `0.5` Implement `io/audio_io.d`, `tests/audio_harness.d`, `tests/rt_malloc_trap.d`, `tests/unit/foundation_test.d`.
- **Exit Criteria:** `dub test --compiler=ldc2 --config=headless` passes with zero warnings; unit tests cover `OwnedBuffer!T`, `FixedArray`, `Arena`, `TripleBuffer`, `audio_io`, `SpscRing`/`MpscRing` 10M-message stress tests, `ScopedNoDenormals` (`arm64` & `x86_64`), and `rt_malloc_trap` failure detection.

### `[x]` Phase 1 — Core DSP Primitives & Shared Polyphony *(Deps: Phase 0)*
- **Subtasks:**
  - `[x]` `1.1` `dsp/tables.d`, `dsp/interp.d`, `dsp/resampler.d`
  - `[x]` `1.2` `dsp/fft.d` (explicit `float`/`double`)
  - `[x]` `1.3` `dsp/filter_biquad.d` (`double` state), `dsp/filter_svf.d`
  - `[x]` `1.4` `dsp/oscillator.d`, `dsp/smoother.d`, `dsp/envelope.d`, `dsp/delay_line.d`
  - `[x]` `1.5` `dsp/voice_pool.d` (`VoicePool!(VoiceT, MaxVoices)`)
- **Exit Criteria:** Every `dsp/` unit compiles `@nogc nothrow`; unit tests pass for all 11 DSP files (`fft` round-trip error $< 10^{-6}$, filter impulse/frequency sweeps with zero `NaN`/Inf, `VoicePool` stealing/deactivation).

### `[x]` Phase 2 — Fixed-Quantum AudioGraph & UDA Module Protocol *(Deps: Phases 0, 1)*
- **Subtasks:**
  - `[x]` `2.1` `graph/port.d`, `graph/context.d`, `graph/event.d`, `graph/buffer.d`
  - `[x]` `2.2` `graph/module_api.d`, `graph/registry.d` (`@Param`, `assertNoNaNInit!T`, named `onParamChanged`, `ModuleAdapter!T`)
  - `[x]` `2.3` `graph/plan.d` (off-RT `GraphCompiler`, topological sort, fixed-delay `Feedback` splitting)
  - `[x]` `2.4` `graph/audio_graph.d` (fixed 64-frame quantum, sub-blocking, silence skip, `SwapGraphPlan`, `SwapModuleAsset`, telemetry)
  - `[x]` `2.5` Smoke-test modules (`output.d`, `amplifier.d`, `dc_blocker.d`, `feedback.d`) + determinism suite
- **Exit Criteria:** `AudioGraph.render()` compiles `@nogc nothrow` and passes `rt_malloc_trap`; unit tests verify sample-accurate `NoteOn` offsets, `64` vs `512` host buffer invariance, deterministic feedback loops, and leak-free mid-stream `SwapGraphPlan`/`SwapModuleAsset`.

### `[x]` Phase 3 — Native macOS Audio & MIDI Layer *(Deps: Phases 0, 2)*
- **Subtasks:**
  - `[x]` `3.1` Freeze `platform/interfaces.d`; implement `platform/macos/corefoundation.d`
  - `[x]` `3.2` Implement `platform/macos/coreaudio.d` (AUHAL output, same-device duplex + dual-AU resampling input, `ScopedNoDenormals`)
  - `[x]` `3.3` Implement `platform/macos/coremidi.d` (multi-source `SpscRing`/`MpscRing` + hot-plug)
  - `[x]` `3.4` Device hot-unplug/sample-rate listeners + `main.d --cli-demo`
- **Exit Criteria:** Hardware/driver unit & integration tests pass; sustained 44.1/48 kHz playback at 64–128 frames with zero xruns; MIDI-to-audio latency $< 10$ ms; callback verified unregistered with GC and allocation-free.

### `[x]` Phase 4 — Built-In Module Library *(Deps: Phases 0, 1, 2, 3)*
- **Subtasks (Tier 1 MVP — 18 modules):**
  - `[x]` `4.1` Core Effects (`amplifier`, `dc_blocker`, `filter_pro`, `distortion`, `delay`, `echo`, `reverb`, `compressor` w/ sidechain)
  - `[x]` `4.2` Core Control (`multisynth`, `multictl`, `adsr_mod`, `lfo`, `feedback`)
  - `[x]` `4.3` Core Percussion/Synths (`kicker`, `drumsynth`, `analog_gen`, `fm_synth`)
  - `[x]` `4.4` `sampler.d` (multi-slot, Catmull-Rom, loops, envelopes, off-RT `SwapModuleAsset`)
  - `[x]` `4.5` Tier 1 automated verification suite + 1-file/1-line extensibility test
- **Subtasks (Tier 2 Expansion — 19 modules, can interleave with Phases 5–8):**
  - `[x]` `4.6` Expansion FX A (`eq`, `waveshaper`, `flanger`, `vibrato`, `modulator`, `smooth_fx`)
  - `[x]` `4.7` Expansion Spectral/Time FX B (`vocal_filter`, `pitch_shifter`, `fft_fx`, `loop_fx`)
  - `[x]` `4.8` Expansion Control (`glide`, `ctl2note`, `pitch2ctl`, `velocity2ctl`, `sound2ctl`, `pitch_detector`)
  - `[x]` `4.9` `spectravoice.d`, `input.d`, `sequencer/stream_worker.d` + `vorbis_player.d` (off-RT decode ring)
- **Exit Criteria:** Unit tests, `@nogc` + `rt_malloc_trap`, silence-decay checks, extreme-sweep zero-`NaN` checks, and golden WAV tests (`tests/golden/golden_suite.d`) pass for every implemented module; `VorbisPlayer` runs with zero RT syscalls.

### `[x]` Phase 5 — Tracker Sequencer, Timeline, Supertracks & `MetaModule` *(Deps: Phases 2, 4 Tier 1)*
- **Subtasks:**
  - `[x]` `5.1` `sequencer/note.d` (`NoteCell`, `EffectCode`) & `sequencer/pattern.d` (atomic patch + CoW `PatternSnapshot`)
  - `[x]` `5.2` `sequencer/timeline.d` (`TimelineClip`, clones, Supertracks, CoW `TimelineSnapshot`)
  - `[x]` `5.3` `sequencer/clock.d` (64-bit rational BPM/TPL clock) & `sequencer/track_effects.d`
  - `[x]` `5.4` `sequencer/engine.d` (unified instance-scoped `Engine`, live input, offline stem WAV export)
  - `[x]` `5.5` `modules/control/metamodule.d` (child `Engine`, BPM sync, `MAX_METAMODULE_DEPTH = 16`)
- **Exit Criteria:** Unit & golden tests pass for every sequencer component, clones, Supertracks, dynamic BPM/TPL, sub-line delays (`0x40`–`0x5F`), nested `MetaModule`, live pattern/timeline edits during playback, and `rt_malloc_trap`.

### `[x]` Phase 6 — Native Persistence, Undo/Redo & Optional Importers *(Deps: Phases 4 Tier 1, 5)*
- **Subtasks:**
  - `[x]` `6.1` `io/binary_stream.d` (`@safe` bounds-checked LE/BE reader/writer)
  - `[x]` `6.2` `io/project_format.d` (4CC chunked `.msv` / `.msym` format)
  - `[x]` `6.3` `app/history.d`, `app/session.d`, `app/keymap.d`
  - `[x]` `6.4` `tests/fuzz/project_format_fuzz.d` (100,000+ mutated/truncated inputs)
  - `[x]` `6.5` *(Optional)* `io/importers/{smf,xm,sunvox}_importer.d` (`.sunvox` scoped to best-effort musical/structural mapping)
- **Exit Criteria:** Unit tests for stream bounds, undo/redo, and session bridge pass; complex `.msv`/`.msym` round-trips render bit-identical WAV output; 100k+ fuzz tests pass with zero panics/OOB reads.

### `[x]` Phase 7 — Native macOS AppKit/Metal Shell & Pure-D UI Toolkit *(Deps: Phases 0, 3; parallelizable with Phases 4–6)*
- **Subtasks:**
  - `[x]` `7.1` `platform/macos/objc_runtime.d` (`ScopedAutoreleasePool`) & `objc_blocks_shim.m`
  - `[x]` `7.2` `platform/macos/appkit.d` (`NSApplication`, `NSWindow`, `NSView`, menus, dialogs, raw key-up/down, trackpad, IME basics)
  - `[x]` `7.3` `platform/macos/coretext.d` (R8 Retina glyph atlas)
  - `[x]` `7.4` `shaders/ui2d.metal`, `platform/macos/metal_renderer.d`, `gui/renderer.d` (`IRenderer2D`, triple-buffered `CAMetalLayer`)
  - `[x]` `7.5` `gui/theme.d`, `gui/layout.d`, `gui/widgets.d`
- **Exit Criteria:** Unit tests pass for layout/hit-testing/widgets; AppKit/Metal shell launches cleanly with native menus/dialogs, $< 3\%$ idle CPU, 60–120 fps Retina rendering, accurate raw key events, and zero autorelease leaks over 100k frames.
- **Sign-off note (2026-11-22):** Marked complete by owner decision. All criteria verified by `--gui-selftest` except the 100k-frame autorelease soak, which the owner waived: the final run (100,000 frames, 120 fps, GC heap +0 KB) held malloc flat for 9 of 10 intervals and then showed one unexplained +127 KB / +1,489-block step. See `docs/changelog.md`.

### `[x]` Phase 7.5 — Studio Backend Integration: Live Audio/MIDI Host, Telemetry, Session Operations & Grouped Undo *(Deps: Phases 3, 5, 6, 7)*
> Inserted 2026-11-22 to close backend gaps found while checking Phase 8 readiness. Full design: [`dev_plan.md` Phase 7.5](../dev_plan.md). Subtask IDs are `7.5.x` and are separate from Phase 7 subtask `7.5` (widget toolkit). **Rule 5:** the `7.5.1`–`7.5.3` UI ↔ RT boundary design was approved by the owner on 2026-11-22.
- **Subtasks:**
  - `[x]` `7.5.1` Unmanaged `Engine` ownership + `app/audio_host.d` (`AudioHost`, `@nogc nothrow` CoreAudio → `Engine` render bridge with an unmanaged `EngineRtContext`, duplex input, device selection, sample-rate follow & hot-unplug recovery)
  - `[x]` `7.5.2` Live MIDI routing (RT drains `CoreMidiRtContext.packetRing` in the render callback; UI copy ring), MIDI target module, MIDI learn (`MidiMapping`, `.msv` `MIDI` chunk, `MidiMapSnapshot` swap)
  - `[x]` `7.5.3` Extended telemetry: scope/analysis `ScopeBlock` ring with module taps, UI-side `app/telemetry.d` (`ScopeHistory`, FFT spectrum), DSP load / xrun / drop counters
  - `[x]` `7.5.4` Session operations: transport (play/stop/seek/play-pattern), loop range, pattern add/duplicate/remove/rename, module mute/bypass/rename/solo, live asset replacement (`buildAssetsFromExtra` hook, sample import + waveform peaks), off-thread WAV/stem export
  - `[x]` `7.5.5` Grouped undo (`beginGroup`/`endGroup`, atomic `CompoundCommand`) + `app/pattern_ops.d` block operations (write/clear/transpose/interpolate, single CoW snapshot swap) and `Dracker-Block-v1` text clipboard codec
  - `[x]` `7.5.6` Keymap expansion (editing/selection/transport/zoom actions matched to `appkit.d` menu equivalents, conflict checks) and a `StudioCommandSink` for view-level actions
  - `[x]` `7.5.7` Verification suite: headless unit/fuzz tests, `rt_malloc_trap` on every new RT path, `--studio-selftest` hardware run
- **Exit Criteria:** Unit tests pass for every new API, including grouped-undo failure rollback, block ops, clipboard-codec fuzzing (10k+ inputs), keymap conflicts, `.msv` `MIDI` chunk round-trip and forward compatibility, and fuzzing of the new chunk. The render bridge, MIDI drain, scope push, and map application compile `@nogc nothrow` and pass `rt_malloc_trap`. No GC pointer is reachable from the audio callback (static asserts + unmanaged ownership). `--studio-selftest` plays a session project through CoreAudio for 30 s at 64 and 128 frames with zero xruns while the UI thread edits concurrently, measures MIDI-in to audio latency under 10 ms, recovers from a device sample-rate change, and exports a WAV bit-identical to an offline render of the same document.

### `[x]` Phase 8 — Modular Synth Tracker Studio GUI *(Deps: Phases 5, 6, 7, 7.5)*
- **Subtasks:**
  - `[x]` `8.1` `views/transport_bar.d` & `views/scope_view.d`
  - `[x]` `8.2` `views/patchbay_view.d` (typed ports, pulses, `ModuleRegistry` add menu, inline scopes)
  - `[x]` `8.3` `views/param_rack.d` (UDA rack + MIDI learn + `MetaModule` drill-down) & `views/sample_editor.d`
  - `[x]` `8.4` `views/pattern_editor.d` (`NN VV MM CCEE XXYY`, selection, transpose/interpolate, follow-playhead)
  - `[x]` `8.5` `views/timeline_view.d` (clips, clones, Supertracks, loop, seek)
  - `[x]` `8.6` Full `app/session.d` + `app/keymap.d` integration & 60+ fps stress pass
- **Exit Criteria:** View/controller unit & integration tests pass; full end-to-end musical workflow succeeds purely via GUI at 60+ fps with zero audio glitches under heavy polyphonic playback.

### `[x]` Phase 8.5 — Accessible Appearance: Atkinson Hyperlegible Next, Light High-Contrast, Colorblind-Safe Palettes & Appearance Menu *(Deps: Phase 8)*
> Inserted 2026-11-22 at the owner's request (visual impairment; dark mode is hard to read). Full design: [`dev_plan.md` Phase 8.5](../dev_plan.md). Subtask IDs are `8.5.x`. **Hard constraint:** no UI geometry or font **size** changes; only font family, colors, and contrast change.
> **Owner decisions:** the UI font is Atkinson Hyperlegible Next and the monospace font is Fira Code, both SIL OFL 1.1 and shipped inside the app in Phase 9.1. The Low-contrast floor is confirmed at 4.5:1 for text.
- **Subtasks:**
  - `[x]` `8.5.1` Appearance model (`gui/theme.d` semantic tokens + new `gui/appearance.d`): built-in palettes (default **Light / High Contrast / Okabe–Ito**, plus Light Low-Contrast and Dark High/Low variants), custom palettes, WCAG contrast and color-vision-deficiency validators
  - `[x]` `8.5.2` Remove dark-mode assumptions and hard-coded colors across `gui/widgets.d`, all views, gallery, and `MetalRenderer.clearColor`; add non-color redundancy cues (port shapes, wire dash patterns, clip labels/stripes, status glyphs)
  - `[x]` `8.5.3` Font family selection in `platform/macos/coretext.d`:
    - defaults: Atkinson Hyperlegible Next for the UI and **Fira Code** for monospace, both requested at Regular 400 (Fira Code's variable default is Light)
    - process-scope registration of bundled fonts (`resources/fonts/` in dev builds, `Contents/Resources/Fonts` in the app), resolved before installed fonts
    - monospace selection restricted to fixed-pitch families, installed-family enumeration, verified fallback
    - glyph-cache/atlas flush and dark-on-light text coverage gamma
  - `[x]` `8.5.4` Runtime theme switching: `StudioContext.themeRevision`, one apply path (context + `UiContext` + renderer clear color + rasterizer fonts + relayout), revision-keyed cache invalidation in every view
  - `[x]` `8.5.5` Appearance menu & panel: native **View ▸ Appearance…** and **View ▸ High Contrast** items, new `StudioAction`s + keymap bindings, in-app Appearance panel (UI font, monospace font, High/Low contrast, palette presets, custom palette editor with live contrast readout, palette import/export), persistent preferences file
  - `[x]` `8.5.6` Verification: unit tests and GUI self-test checks for contrast, CVD separation, size invariance, font loading, live switching, persistence
- **Exit Criteria:**
  - On first launch the studio renders in light high-contrast mode, with Atkinson Hyperlegible Next as the UI font and Fira Code as the monospace (pattern grid) font.
  - Every text/background token pair used by the UI meets WCAG AAA (≥ 7:1) in High contrast and ≥ 4.5:1 in Low contrast, for every built-in palette. Non-text UI graphics (wires, borders, focus rings, meters) meet ≥ 4.5:1 (High) / ≥ 3:1 (Low). These ratios are measured both from tokens and from offscreen-rendered pixels.
  - Categorical color sets (wire kinds, tracker fields, module categories, clip colors) stay distinguishable (CIEDE2000 ΔE ≥ 10 between every pair) under simulated protanopia, deuteranopia, and tritanopia, and each set also has a non-color cue.
  - All theme size metrics and the root/pane layout rectangles are unchanged from Phase 8.
  - Font, contrast, and palette changes from the menu apply live without restart, persist across launches, and survive corrupted preference files (defaults + status message).
  - The preferences parser passes 10k+ fuzzed inputs. All prior unit tests and the `--gui-selftest` / `--studio-selftest` / `--studio-gui-selftest` runs still pass.
- **Completion note (2026-11-22):** All exit criteria are verified by tests (see `docs/changelog.md`). Starting palette values were adjusted by the contrast and CVD gates; the final values and other deviations from the plan text are listed under "Implementation notes" in [`dev_plan.md` Phase 8.5](../dev_plan.md).

### `[ ]` Phase 9 — macOS `.app` Packaging, Universal Binary, Profiling & Hardening *(Deps: Phase 8, 8.5)*
- **Subtasks:**
  - `[ ]` `9.1` `packaging/macos/bundle_macos.sh`, `Info.plist`, `entitlements.plist`, `AppIcon.icns` (Universal `arm64`+`x86_64`, `lipo`, `codesign`), plus the **bundled fonts**: Atkinson Hyperlegible Next and Fira Code with their OFL texts go in `Contents/Resources/Fonts`, with `ATSApplicationFontsPath`, and **bundled presets**: `resources/presets/` go in `Contents/Resources/Presets`; the build fails if any are missing
  - `[ ]` `9.2` Xcode Instruments `Audio System Trace` & `Allocations` RT audit
  - `[ ]` `9.3` Hot-path DSP profiling + targeted `ldc.attributes.restrict` / `core.simd`
  - `[ ]` `9.4` Autosave crash recovery & live audio/MIDI hot-plug resilience
- **Exit Criteria:** Universal `Dracker.app` launches on Apple Silicon and Intel with `otool -L` showing system-only frameworks, `codesign --verify --deep --strict` passing, zero Instruments RT violations, and crash-free hot-unplug recovery. The app renders with its bundled Atkinson Hyperlegible Next and Fira Code (resolved font URLs point inside `Contents/Resources/Fonts`) and loads its bundled presets from `Contents/Resources/Presets`.

---

## 5. Build, Test & Verification Commands

Run all commands from inside `dracker/` using **LDC2 1.40+** and **DUB**:

```zsh
# Headless unit, rt_malloc_trap, golden WAV, and fuzz tests (CI-safe)
dub test --compiler=ldc2 --config=headless

# Headless CLI demo & release build
dub run --compiler=ldc2 --config=headless -- --cli-demo
./build/dracker --studio-selftest [--quick]   # live session audio/MIDI backend check (plays quiet audio)
dub build --compiler=ldc2 --config=headless --build=release

# Native macOS AppKit/Metal GUI build (precompiles build/ui2d.metallib when the Xcode Metal toolchain exists;
# otherwise MetalRenderer compiles the embedded shaders/ui2d.metal source at runtime)
dub build --compiler=ldc2 --config=app --build=debug
./build/dracker                      # launch the studio window
dub test --compiler=ldc2 --config=app      # Objective-C runtime, CoreText, Metal GPU read-back, AppKit unit tests

# Unattended Phase 7 GUI verification on real hardware (keeps its window floating; ~15 min, --quick ~4 min)
caffeinate -dims ./build/dracker --gui-selftest [--quick]
caffeinate -dims ./build/dracker --studio-gui-selftest [--quick]   # Phase 8 end-to-end workflow purely via GUI (plays quiet audio)

# Standalone compiler / shim / config checks
ldc2 -o- -w -Isource source/**/*.d
clang -x objective-c -fobjc-arc -mmacosx-version-min=12.0 -fsyntax-only -Wall -Wextra source/platform/macos/objc_blocks_shim.m
plutil -lint packaging/macos/Info.plist packaging/macos/entitlements.plist
bash -n packaging/macos/bundle_macos.sh

# Universal signed macOS .app bundle (Phase 9)
./packaging/macos/bundle_macos.sh
```

*(Headless CI in `ci/macos.yml` enforces compilation, static `@nogc`/`nothrow`, `rt_malloc_trap.d`, golden WAVs, and fuzz smoke tests; live CoreAudio/CoreMIDI, Metal rendering, and Instruments RT traces are verified locally on developer hardware.)*
