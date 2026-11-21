/**
 * File:         source/platform/interfaces.d
 * Module:       platform.interfaces
 * Phase:        Phase 3.1 — OS-Agnostic Driver & Window Interfaces
 *
 * Purpose:
 *   Defines pure-D hardware/OS interfaces (IAudioDriver, IMidiDriver, IPlatformWindow, IFileDialog) isolating macOS platform implementations to enable future Linux/Windows backends.
 *
 * Real-Time & Safety Contract:
 *   Audio/MIDI callback delegates supplied to drivers must be @nogc nothrow; window/dialog calls run on main UI thread.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct AudioDeviceInfo / MidiDeviceInfo / PlatformEvent
 *   - alias AudioRenderCallback = void function(void* userData, const(float)* inL, const(float)* inR, float* outL, float* outR, uint frames) @nogc nothrow
 *   - interface IAudioDriver / interface IMidiDriver / interface IPlatformWindow / interface IFileDialog
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.interfaces;
