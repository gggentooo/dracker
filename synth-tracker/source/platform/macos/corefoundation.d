/**
 * File:         source/platform/macos/corefoundation.d
 * Module:       platform.macos.corefoundation
 * Phase:        Phase 3.1 — Minimal CoreFoundation extern(C) Bindings
 *
 * Purpose:
 *   Provides thin @nogc-safe extern(C) bindings for CFString, CFArray, CFRunLoop, and CFRelease needed by CoreAudio, CoreMIDI, and CoreText.
 *
 * Real-Time & Safety Contract:
 *   extern(C) @nogc nothrow bindings only; caller balances CFCreate/CFCopy with CFRelease.
 *
 * Dependencies:
 *   Internal: None
 *   External: macOS CoreFoundation.framework
 *
 * Planned API (Types, Functions & Hooks):
 *   - alias CFTypeRef = const(void)* / CFStringRef / CFRunLoopRef
 *   - extern(C) @nogc nothrow: CFRelease, CFRetain, CFStringCreateWithBytes, CFStringGetCString
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.macos.corefoundation;
