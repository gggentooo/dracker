/**
 * File:         source/dsp/envelope.d
 * Module:       dsp.envelope
 * Phase:        Phase 1.4 — ADSR & Multi-Breakpoint Curve Envelopes
 *
 * Purpose:
 *   Implements sample-accurate ADSR envelopes and editable multi-breakpoint envelopes with curve shaping for synths, Sampler, and AdsrMod.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero allocations and explicit idle/active state reporting for VoicePool deactivation.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory
 *   External: core.stdc.math (powf)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum EnvStage : ubyte { idle, attack, decay, sustain, release }
 *   - struct AdsrEnvelope : trigger(), releaseNote(), next(), isActive() const, reset()
 *   - struct BreakpointEnvelope : evaluates @nogc breakpoint arrays with loop/sustain points
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.envelope;
