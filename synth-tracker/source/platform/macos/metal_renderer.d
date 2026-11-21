/**
 * File:         source/platform/macos/metal_renderer.d
 * Module:       platform.macos.metal_renderer
 * Phase:        Phase 7.4 — extern(Objective-C) Metal 2D Batched Renderer
 *
 * Purpose:
 *   Implements IRenderer2D using CAMetalLayer, precompiled shaders/ui2d.metallib, instanced vertex/fragment draw calls, and triple-buffered dispatch_semaphore pacing via objc_blocks_shim.m.
 *
 * Real-Time & Safety Contract:
 *   Main UI thread only; wraps nextDrawable/commandBuffer frame cycle in ScopedAutoreleasePool.
 *
 * Dependencies:
 *   Internal: gui.renderer, platform.macos.appkit, platform.macos.coretext, platform.macos.objc_runtime
 *   External: macOS Metal.framework, QuartzCore.framework, libSystem (dispatch_semaphore)
 *
 * Planned API (Types, Functions & Hooks):
 *   - class MetalRenderer : IRenderer2D
 *   - Triple-buffered MTLBuffer instance ring + ui2d.metallib pipeline states
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.macos.metal_renderer;
