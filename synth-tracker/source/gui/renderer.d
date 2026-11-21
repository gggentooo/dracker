/**
 * File:         source/gui/renderer.d
 * Module:       gui.renderer
 * Phase:        Phase 7.4 — Backend-Agnostic IRenderer2D Abstraction
 *
 * Purpose:
 *   Defines the retained-canvas 2D drawing interface (rounded rectangles, borders, gradients, scissor clipping, anti-aliased polylines/cubic Beziers, glyph/textured quads) implemented by MetalRenderer.
 *
 * Real-Time & Safety Contract:
 *   UI thread only.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct RectF / ColorRGBA / Point2F
 *   - interface IRenderer2D : beginFrame(), endFrame(), pushClip(RectF), popClip(), drawRoundedRect(...), drawBezier(...), drawText(...)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.renderer;
