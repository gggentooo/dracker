# SynthTracker Changelog

All major changes to `synth-tracker/` must be recorded in reverse-chronological order (newest entry first).

### Entry Format
- **Timestamp:** `YYYY-MM-DD HH:MM:SS KST` (UTC+09:00)
- **Author:** Human developer name or agent model name
- **Affected Files:** Explicit list of created, modified, or deleted paths
- **Description:** Concise summary of the change(s)

---

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
