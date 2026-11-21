/**
 * File:         source/platform/macos/coretext.d
 * Module:       platform.macos.coretext
 * Phase:        Phase 7.3 — CoreText + CoreGraphics Retina Glyph Atlas
 *
 * Purpose:
 *   Rasterizes crisp macOS monospace tracker glyphs and UI sans-serif fonts via CoreText/CoreGraphics into a dynamically packed R8 texture atlas.
 *
 * Real-Time & Safety Contract:
 *   Main UI thread only; frees CoreFoundation/CoreGraphics refs deterministically.
 *
 * Dependencies:
 *   Internal: platform.macos.corefoundation
 *   External: macOS CoreText.framework, CoreGraphics.framework
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct GlyphMetrics { float advance; float bearingX; float bearingY; float width; float height; float u0, v0, u1, v1; }
 *   - class CoreTextAtlas : rasterizeGlyph(dchar ch, float pxSize, float scaleFactor)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.macos.coretext;
