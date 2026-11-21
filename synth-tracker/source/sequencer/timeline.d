/**
 * File:         source/sequencer/timeline.d
 * Module:       sequencer.timeline
 * Phase:        Phase 5.2 — TimelineClip Placements, Pattern Clones & Supertracks
 *
 * Purpose:
 *   Manages song arrangement clips, shared pattern clones, mute/solo flags, loop regions, and Supertracks persistent per-lane playback state across consecutive clips.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on RT traversal via CoW TimelineSnapshot swapped cleanly at slice boundaries.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, sequencer.pattern
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct TimelineClip { uint clipId; uint patternId; uint cloneSourceId; long startLine; uint lengthLines; uint laneY; bool mute; bool solo; }
 *   - struct SupertrackState : persistent active track module/effect memory per lane
 *   - struct TimelineSnapshot : OwnedBuffer!TimelineClip clips, loopStartLine, loopEndLine, supertrackCount
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.timeline;
