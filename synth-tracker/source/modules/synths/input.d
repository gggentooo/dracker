/**
 * File:         source/modules/synths/input.d
 * Module:       modules.synths.input
 * Phase:        Phase 4.9 (Tier 2) — Live Hardware Audio Input Module
 *
 * Purpose:
 *   Routes live CoreAudio capture channels (direct AUHAL duplex or drift-compensated resampled ring buffer) into the modular audio graph.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; reads pre-captured frame slice from ProcessContext / platform audio input ring.
 *
 * Dependencies:
 *   Internal: dsp.resampler, dsp.smoother, graph.*
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct AudioInput (typeId = "synth.input", ports: audioStereo out)
 *   - @Param inputGain, channelRoute, monitorMute
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.input;
