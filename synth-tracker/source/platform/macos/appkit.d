/**
 * File:         source/platform/macos/appkit.d
 * Module:       platform.macos.appkit
 * Phase:        Phase 7.2 — extern(Objective-C) AppKit Window, Menus & Input
 *
 * Purpose:
 *   Binds the minimal AppKit surface (~15 classes: NSApplication, NSWindow, single host NSView + CAMetalLayer, NSMenu, NSOpenPanel/NSSavePanel, NSPasteboard) and delivers Retina/key/trackpad/IME events.
 *
 * Real-Time & Safety Contract:
 *   Main UI thread only; requires LDC2 1.40+ extern(Objective-C) on macOS arm64/x86_64; wraps ticks in ScopedAutoreleasePool.
 *
 * Dependencies:
 *   Internal: platform.interfaces, platform.macos.objc_runtime
 *   External: macOS Cocoa.framework (AppKit, Foundation, QuartzCore)
 *
 * Planned API (Types, Functions & Hooks):
 *   - extern(Objective-C) extern classes: NSObject, NSApplication, NSWindow, NSView, NSMenu, NSEvent, NSOpenPanel, NSSavePanel, NSPasteboard
 *   - extern(Objective-C) class StudioHostView : NSView (mouse, trackpad pinch/scroll, raw keyDown/keyUp, backingScaleFactor)
 *   - class MacWindow : IPlatformWindow / class MacFileDialog : IFileDialog
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.macos.appkit;
