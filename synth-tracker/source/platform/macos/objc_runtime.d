/**
 * File:         source/platform/macos/objc_runtime.d
 * Module:       platform.macos.objc_runtime
 * Phase:        Phase 7.1 — Objective-C Runtime & Autorelease Pool Discipline
 *
 * Purpose:
 *   Provides ScopedAutoreleasePool (objc_autoreleasePoolPush/Pop), manual retain/release helpers, and extern(C) declarations matching objc_blocks_shim.m.
 *
 * Real-Time & Safety Contract:
 *   UI thread only; mandatory around AppKit event loops and every Metal CAMetalLayer frame to prevent drawable leaks.
 *
 * Dependencies:
 *   Internal: None
 *   External: libobjc (objc_autoreleasePoolPush, objc_autoreleasePoolPop), objc_blocks_shim.m
 *
 * Planned API (Types, Functions & Hooks):
 *   - extern(C) @nogc nothrow void* objc_autoreleasePoolPush() / void objc_autoreleasePoolPop(void*)
 *   - struct ScopedAutoreleasePool (RAII push/pop)
 *   - extern(C) bindings: st_mtl_cmdbuf_add_completed_handler, st_ns_panel_begin_open_sheet, st_ns_panel_begin_save_sheet
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.macos.objc_runtime;
