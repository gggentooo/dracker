# SynthTracker — Agent Source-of-Truth Guide

> **Project:** Clean-slate modular synthesizer & tracker inspired by SunVox  
> **Language:** Idiomatic D2 (**LDC2 1.40+**, macOS Universal `arm64` + `x86_64`)  
> **Target:** Native macOS desktop `.app` bundle (AppKit + Metal GUI), architected for future Linux/Windows portability  
> **Authoritative References:** [architecture_proposal.md](../architecture_proposal.md) | [dev_plan_proposal.md](../dev_plan_proposal.md) | [docs/changelog.md](./docs/changelog.md)

---

## 1. Non-Negotiable Engineering & Agent Rules

Every contributor and autonomous agent working in `synth-tracker/` **must** follow these four rules without exception:

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
| `source/app/` | `session.d`, `history.d`, `keymap.d` | Main/UI thread orchestration & undo/redo |
| `source/gui/` | `renderer.d`, `theme.d`, `layout.d`, `widgets.d`, `views/` (7 studio views) | Main/UI thread only (excluded in `headless` DUB config) |
| `source/platform/` | `interfaces.d` + `macos/` (`corefoundation.d`, `coreaudio.d`, `coremidi.d`, `objc_runtime.d`, `objc_blocks_shim.m`, `appkit.d`, `coretext.d`, `metal_renderer.d`) | Only OS FFI boundary in the project |
| `shaders/` | `ui2d.metal` (Metal 2D instanced UI, Beziers, R8 glyphs) | Compiled to `build/ui2d.metallib` |
| `packaging/macos/`, `ci/` | `Info.plist`, `entitlements.plist`, `bundle_macos.sh`, `macos.yml` | Release bundling & CI automation |
| `tests/` | `audio_harness.d`, `rt_malloc_trap.d`, `unit/`, `golden/`, `fuzz/` | Offline CI & local verification |
| `docs/` | `changelog.md` | Mandatory change log (Rule 4) |

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

### `[ ]` Phase 5 — Tracker Sequencer, Timeline, Supertracks & `MetaModule` *(Deps: Phases 2, 4 Tier 1)*
- **Subtasks:**
  - `[ ]` `5.1` `sequencer/note.d` (`NoteCell`, `EffectCode`) & `sequencer/pattern.d` (atomic patch + CoW `PatternSnapshot`)
  - `[ ]` `5.2` `sequencer/timeline.d` (`TimelineClip`, clones, Supertracks, CoW `TimelineSnapshot`)
  - `[ ]` `5.3` `sequencer/clock.d` (64-bit rational BPM/TPL clock) & `sequencer/track_effects.d`
  - `[ ]` `5.4` `sequencer/engine.d` (unified instance-scoped `Engine`, live input, offline stem WAV export)
  - `[ ]` `5.5` `modules/control/metamodule.d` (child `Engine`, BPM sync, `MAX_METAMODULE_DEPTH = 16`)
- **Exit Criteria:** Unit & golden tests pass for every sequencer component, clones, Supertracks, dynamic BPM/TPL, sub-line delays (`0x40`–`0x5F`), nested `MetaModule`, live pattern/timeline edits during playback, and `rt_malloc_trap`.

### `[ ]` Phase 6 — Native Persistence, Undo/Redo & Optional Importers *(Deps: Phases 4 Tier 1, 5)*
- **Subtasks:**
  - `[ ]` `6.1` `io/binary_stream.d` (`@safe` bounds-checked LE/BE reader/writer)
  - `[ ]` `6.2` `io/project_format.d` (4CC chunked `.msv` / `.msym` format)
  - `[ ]` `6.3` `app/history.d`, `app/session.d`, `app/keymap.d`
  - `[ ]` `6.4` `tests/fuzz/project_format_fuzz.d` (100,000+ mutated/truncated inputs)
  - `[ ]` `6.5` *(Optional)* `io/importers/{smf,xm,sunvox}_importer.d` (`.sunvox` scoped to best-effort musical/structural mapping)
- **Exit Criteria:** Unit tests for stream bounds, undo/redo, and session bridge pass; complex `.msv`/`.msym` round-trips render bit-identical WAV output; 100k+ fuzz tests pass with zero panics/OOB reads.

### `[ ]` Phase 7 — Native macOS AppKit/Metal Shell & Pure-D UI Toolkit *(Deps: Phases 0, 3; parallelizable with Phases 4–6)*
- **Subtasks:**
  - `[ ]` `7.1` `platform/macos/objc_runtime.d` (`ScopedAutoreleasePool`) & `objc_blocks_shim.m`
  - `[ ]` `7.2` `platform/macos/appkit.d` (`NSApplication`, `NSWindow`, `NSView`, menus, dialogs, raw key-up/down, trackpad, IME basics)
  - `[ ]` `7.3` `platform/macos/coretext.d` (R8 Retina glyph atlas)
  - `[ ]` `7.4` `shaders/ui2d.metal`, `platform/macos/metal_renderer.d`, `gui/renderer.d` (`IRenderer2D`, triple-buffered `CAMetalLayer`)
  - `[ ]` `7.5` `gui/theme.d`, `gui/layout.d`, `gui/widgets.d`
- **Exit Criteria:** Unit tests pass for layout/hit-testing/widgets; AppKit/Metal shell launches cleanly with native menus/dialogs, $< 3\%$ idle CPU, 60–120 fps Retina rendering, accurate raw key events, and zero autorelease leaks over 100k frames.

### `[ ]` Phase 8 — Modular Synth Tracker Studio GUI *(Deps: Phases 5, 6, 7)*
- **Subtasks:**
  - `[ ]` `8.1` `views/transport_bar.d` & `views/scope_view.d`
  - `[ ]` `8.2` `views/patchbay_view.d` (typed ports, pulses, `ModuleRegistry` add menu, inline scopes)
  - `[ ]` `8.3` `views/param_rack.d` (UDA rack + MIDI learn + `MetaModule` drill-down) & `views/sample_editor.d`
  - `[ ]` `8.4` `views/pattern_editor.d` (`NN VV MM CCEE XXYY`, selection, transpose/interpolate, follow-playhead)
  - `[ ]` `8.5` `views/timeline_view.d` (clips, clones, Supertracks, loop, seek)
  - `[ ]` `8.6` Full `app/session.d` + `app/keymap.d` integration & 60+ fps stress pass
- **Exit Criteria:** View/controller unit & integration tests pass; full end-to-end musical workflow succeeds purely via GUI at 60+ fps with zero audio glitches under heavy polyphonic playback.

### `[ ]` Phase 9 — macOS `.app` Packaging, Universal Binary, Profiling & Hardening *(Deps: Phase 8)*
- **Subtasks:**
  - `[ ]` `9.1` `packaging/macos/bundle_macos.sh`, `Info.plist`, `entitlements.plist`, `AppIcon.icns` (Universal `arm64`+`x86_64`, `lipo`, `codesign`)
  - `[ ]` `9.2` Xcode Instruments `Audio System Trace` & `Allocations` RT audit
  - `[ ]` `9.3` Hot-path DSP profiling + targeted `ldc.attributes.restrict` / `core.simd`
  - `[ ]` `9.4` Autosave crash recovery & live audio/MIDI hot-plug resilience
- **Exit Criteria:** Universal `SynthTracker.app` launches on Apple Silicon and Intel with `otool -L` showing system-only frameworks, `codesign --verify --deep --strict` passing, zero Instruments RT violations, and crash-free hot-unplug recovery.

---

## 5. Build, Test & Verification Commands

Run all commands from inside `synth-tracker/` using **LDC2 1.40+** and **DUB**:

```zsh
# Headless unit, rt_malloc_trap, golden WAV, and fuzz tests (CI-safe)
dub test --compiler=ldc2 --config=headless

# Headless CLI demo & release build
dub run --compiler=ldc2 --config=headless -- --cli-demo
dub build --compiler=ldc2 --config=headless --build=release

# Native macOS AppKit/Metal GUI build (requires Xcode Metal toolchain)
dub build --compiler=ldc2 --config=app --build=debug

# Standalone compiler / shim / config checks
ldc2 -o- -w -Isource source/**/*.d
clang -x objective-c -fobjc-arc -mmacosx-version-min=12.0 -fsyntax-only -Wall -Wextra source/platform/macos/objc_blocks_shim.m
plutil -lint packaging/macos/Info.plist packaging/macos/entitlements.plist
bash -n packaging/macos/bundle_macos.sh

# Universal signed macOS .app bundle (Phase 9)
./packaging/macos/bundle_macos.sh
```

*(Headless CI in `ci/macos.yml` enforces compilation, static `@nogc`/`nothrow`, `rt_malloc_trap.d`, golden WAVs, and fuzz smoke tests; live CoreAudio/CoreMIDI, Metal rendering, and Instruments RT traces are verified locally on developer hardware.)*
