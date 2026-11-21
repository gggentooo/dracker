/**
 * File:         source/gui/theme.d
 * Module:       gui.theme
 * Phase:        Phase 7.5 — HiDPI Typography, Spacing & Color Tokens
 *
 * Purpose:
 *   Centralizes Retina-aware UI scaling metrics, color palette tokens (audio vs. CV vs. event wires, tracker column colors), and font sizes.
 *
 * Real-Time & Safety Contract:
 *   UI thread; immutable/configurable theme structs.
 *
 * Dependencies:
 *   Internal: gui.renderer
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct StudioTheme : color tokens, wire colors by PortKind, font sizes, spacing scale
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module gui.theme;
