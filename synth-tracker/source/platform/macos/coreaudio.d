/**
 * File:         source/platform/macos/coreaudio.d
 * Module:       platform.macos.coreaudio
 * Phase:        Phase 3.2 — CoreAudio / AudioToolbox AUHAL Driver
 *
 * Purpose:
 *   Binds macOS AudioUnit (HALOutput / AUHAL) for low-latency stereo playback, same-device duplex input, and dual-device drift-compensated resampling ring input, plus hot-plug property listeners.
 *
 * Real-Time & Safety Contract:
 *   Render callback is extern(C) @nogc nothrow, runs on an unregistered macOS RT thread, and activates ScopedNoDenormals on entry.
 *
 * Dependencies:
 *   Internal: platform.interfaces, platform.macos.corefoundation, foundation.math_rt, dsp.resampler
 *   External: macOS CoreAudio.framework, AudioToolbox.framework
 *
 * Planned API (Types, Functions & Hooks):
 *   - class CoreAudioDriver : IAudioDriver
 *   - extern(C) OSStatus auRenderCallback(...) @nogc nothrow
 *   - Audio device enumeration, sample-rate negotiation, and hot-unplug listeners
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.macos.coreaudio;
