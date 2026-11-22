/**
 * File:         source/sequencer/track_effects.d
 * Module:       sequencer.track_effects
 * Phase:        Phase 5.3 — Per-Track Tracker Effect State Machine
 *
 * Purpose:
 *   Interprets active NoteCells and per-tick tracker effect memory (slides, vibrato, arpeggio, retrigger, note cut, note delay, probability, sub-line delay 0x40..0x5F) into sample-accurate ModEvents.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; pre-allocated fixed track state array with deterministic xorshift32 PRNG.
 *
 * Dependencies:
 *   Internal: dsp.tables, foundation.concurrency, foundation.types, graph.audio_graph, graph.event, sequencer.clock, sequencer.note
 *   External: std.traits (hasIndirections)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct TrackEffectState : per-channel note/slide/vibrato/arp/retrig/cut/delay state
 *   - struct SequencerActionFlags : BPM/TPL/jump/stop requests returned per tick
 *   - struct TrackEffectBank : processCellTick(), releaseAllActive()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.track_effects;

import std.traits : hasIndirections;

import dsp.tables : lookupSine;
import foundation.concurrency : hasGcReference;
import foundation.types : FrameTime, ModuleId, NoteId;
import graph.audio_graph : AudioGraph;
import graph.event : ModEvent;
import sequencer.clock : RationalClock;
import sequencer.note : EffectCode, NoteCell, NoteCmd;

/**
 * Discriminates whether track memory belongs to an isolated clip or persistent Supertrack lane.
 */
enum TrackKeyKind : ubyte {
    clip = 0,
    supertrack = 1
}

/**
 * Per-track runtime state preserving active voice NoteId, pitch slides, vibrato, arpeggio, and memory.
 */
struct TrackEffectState {
    TrackKeyKind keyKind = TrackKeyKind.clip;
    uint ownerId = 0;
    uint trackIdx = 0;
    bool allocated = false;

    ModuleId activeModule = ModuleId.invalid;
    NoteId activeNoteId = NoteId.none;
    float basePitch = 60.0f;
    float currentPitch = 60.0f;
    float velocity = 0.8f;

    ubyte lastSlideUp = 0;
    ubyte lastSlideDown = 0;
    ubyte lastPortaSpeed = 0;
    ubyte lastVibSpeed = 0;
    ubyte lastVibDepth = 0;
    ubyte lastVelSlide = 0;
    ubyte lastArp = 0;
    ubyte lastRetrig = 0;

    float portamentoTarget = 60.0f;
    bool portamentoActive = false;

    float vibratoPhase = 0.0f;
    bool vibratoActive = false;

    ubyte arpX = 0;
    ubyte arpY = 0;
    uint arpStep = 0;
    bool arpActive = false;

    uint retrigPeriod = 0;
    uint retrigCounter = 0;

    int cutTick = -1;
    int delayTick = -1;
    NoteCell delayedCell;
}

static assert(!hasIndirections!TrackEffectState);

/**
 * Sequencer-level flow/tempo mutations surfaced out of track effect interpretation on tick 0.
 */
struct SequencerActionFlags {
    bool hasBpmChange = false;
    double newBpm = 125.0;
    bool hasTplChange = false;
    uint newTpl = 6;
    bool stopSong = false;
    bool hasJump = false;
    long jumpTargetLine = 0;
}

/**
 * Fixed-capacity bank of 128 track state machines driving all pattern clips and Supertracks @nogc.
 */
struct TrackEffectBank {
    enum size_t MAX_TRACK_CHANNELS = 128;

    private TrackEffectState[MAX_TRACK_CHANNELS] channels_;
    private uint nextNoteSeq_ = 1;
    private uint rngState_ = 0x5452_4B31u;

    @nogc nothrow:

    /**
     * Clears all track slots, note counters, and seeds deterministic probability PRNG.
     */
    void reset() pure @safe {
        foreach (ref ch; channels_) {
            ch = TrackEffectState.init;
        }
        nextNoteSeq_ = 1;
        rngState_ = 0x5452_4B31u;
    }

    /**
     * Releases all currently sounding track notes cleanly with sample-accurate NoteOff at absFrame.
     *
     * Params:
     *   graph = Destination AudioGraph scheduling NoteOff events.
     *   absFrame = Target absolute graph sample frame.
     */
    void releaseAllActive(ref AudioGraph graph, FrameTime absFrame) {
        foreach (ref ch; channels_) {
            if (ch.allocated && ch.activeModule.isValid() && ch.activeNoteId.isValid()) {
                graph.enqueueEvent(ch.activeModule, ModEvent.makeNoteOff(ch.activeNoteId), absFrame);
                ch.activeNoteId = NoteId.none;
            }
        }
    }

    /**
     * Interprets one tracker cell on (keyKind, ownerId, trackIdx) at tick and emits AudioGraph events.
     *
     * Params:
     *   keyKind = TrackKeyKind.clip for standalone clips or supertrack for lane-persistent clips.
     *   ownerId = Clip ID (for clip) or laneY (for supertrack).
     *   trackIdx = Zero-based pattern track column index.
     *   cell = Pattern NoteCell on the current line.
     *   tick = Current tick within the line (0 .. ticksPerLine - 1).
     *   absFrame = Exact absolute audio frame timestamp for this tick.
     *   clock = Active RationalClock providing sub-line sample delay calculations.
     *   graph = Destination AudioGraph receiving Note/Param events and mute/bypass updates.
     *   actions = Accumulated BPM/TPL/stop/jump action requests for the Sequencer.
     */
    void processCellTick(
        TrackKeyKind keyKind,
        uint ownerId,
        uint trackIdx,
        NoteCell cell,
        uint tick,
        FrameTime absFrame,
        ref const RationalClock clock,
        ref AudioGraph graph,
        ref SequencerActionFlags actions
    ) {
        TrackEffectState* st = acquireChannel(keyKind, ownerId, trackIdx);
        if (st is null) {
            return;
        }

        if (tick == 0) {
            processTickZero(st, cell, absFrame, clock, graph, actions);
        } else {
            processContinuationTick(st, cell, tick, absFrame, graph);
        }
    }

    private TrackEffectState* acquireChannel(TrackKeyKind keyKind, uint ownerId, uint trackIdx) pure {
        foreach (ref ch; channels_) {
            if (ch.allocated && ch.keyKind == keyKind && ch.ownerId == ownerId && ch.trackIdx == trackIdx) {
                return &ch;
            }
        }
        foreach (ref ch; channels_) {
            if (!ch.allocated) {
                ch = TrackEffectState.init;
                ch.keyKind = keyKind;
                ch.ownerId = ownerId;
                ch.trackIdx = trackIdx;
                ch.allocated = true;
                return &ch;
            }
        }
        return null;
    }

    private NoteId nextNoteId() pure @safe {
        uint v = nextNoteSeq_++;
        if (v == 0 || v >= 0x4000_0000u) {
            nextNoteSeq_ = 2;
            v = 1;
        }
        return NoteId(v);
    }

    private uint nextRandomByte() pure @safe {
        uint x = rngState_;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        rngState_ = x == 0 ? 0x1234_5678u : x;
        return (rngState_ >> 16) & 0xFFu;
    }

    private bool evaluateProbability(ubyte fx, ubyte fxVal) pure @safe {
        uint prob255 = 255u;
        if (fx == EffectCode.probabilityBase) {
            prob255 = cast(uint) fxVal;
        } else if (fx > EffectCode.probabilityBase && fx <= EffectCode.probabilityMax) {
            immutable uint hi = cast(uint)(fx - EffectCode.probabilityBase);
            prob255 = (hi << 4) | (cast(uint) fxVal & 0x0Fu);
        }
        if (prob255 >= 255u) {
            return true;
        }
        return nextRandomByte() < prob255;
    }

    private void processTickZero(
        TrackEffectState* st,
        NoteCell cell,
        FrameTime absFrame,
        ref const RationalClock clock,
        ref AudioGraph graph,
        ref SequencerActionFlags actions
    ) {
        st.cutTick = -1;
        st.delayTick = -1;
        st.vibratoActive = false;
        st.arpActive = false;
        st.portamentoActive = false;
        st.retrigPeriod = 0;

        if (cell.moduleId > 0) {
            st.activeModule = ModuleId(cell.moduleId);
        }

        if (cell.isProbability() && !evaluateProbability(cell.effect, cell.effectVal)) {
            return;
        }

        switch (cell.effect) {
            case EffectCode.setSpeed:
                if (cell.effectVal >= 1 && cell.effectVal <= 31) {
                    actions.hasTplChange = true;
                    actions.newTpl = cell.effectVal;
                } else if (cell.effectVal >= 32) {
                    actions.hasBpmChange = true;
                    actions.newBpm = cast(double) cell.effectVal;
                }
                break;

            case EffectCode.setBpm:
                if (cell.effectVal > 0) {
                    actions.hasBpmChange = true;
                    actions.newBpm = cast(double) cell.effectVal;
                }
                break;

            case EffectCode.stopSong:
                actions.stopSong = true;
                break;

            case EffectCode.jumpLine:
                actions.hasJump = true;
                actions.jumpTargetLine = cast(long) cell.effectVal;
                break;

            case EffectCode.bypassModule:
                if (st.activeModule.isValid()) {
                    graph.setNodeBypassed(st.activeModule, cell.effectVal != 0);
                }
                break;

            case EffectCode.muteModule:
                if (st.activeModule.isValid()) {
                    graph.setNodeMuted(st.activeModule, cell.effectVal != 0);
                }
                break;

            case EffectCode.noteDelay:
                if ((cell.effectVal & 0x1Fu) > 0) {
                    st.delayTick = cast(int)(cell.effectVal & 0x1Fu);
                    st.delayedCell = cell;
                    return;
                }
                break;

            case EffectCode.noteCut:
                st.cutTick = cast(int)(cell.effectVal & 0x1Fu);
                break;

            default:
                break;
        }

        FrameTime emitFrame = absFrame;
        if (cell.isSubLineDelay()) {
            emitFrame += cast(FrameTime) clock.subLineDelaySamples(cell.subLineDelaySteps());
        }

        if (cell.note == NoteCmd.stopSong) {
            actions.stopSong = true;
        } else if (cell.note == NoteCmd.allNotesOff) {
            if (st.activeModule.isValid()) {
                graph.enqueueEvent(st.activeModule, ModEvent.makeAllNotesOff(), emitFrame);
            }
            st.activeNoteId = NoteId.none;
        }

        executeCellAction(st, cell, emitFrame, graph, actions);
    }

    private void executeCellAction(
        TrackEffectState* st,
        NoteCell cell,
        FrameTime emitFrame,
        ref AudioGraph graph,
        ref SequencerActionFlags actions
    ) {
        cast(void) actions;

        if (st.activeModule.isValid()) {
            if (cell.effect == EffectCode.sampleOffset) {
                immutable float norm = cast(float) cell.effectVal / 256.0f;
                graph.enqueueEvent(st.activeModule, ModEvent.makeSetParam(3, norm, true), emitFrame);
            } else if (cell.effect == EffectCode.sampleOffsetFine) {
                immutable float norm = cast(float) cell.effectVal / 4096.0f;
                graph.enqueueEvent(st.activeModule, ModEvent.makeSetParam(3, norm, true), emitFrame);
            }
        }

        if (cell.paramId > 0 && st.activeModule.isValid()) {
            immutable float pNorm = (cell.effect == EffectCode.none || cell.isSubLineDelay())
                ? (cast(float) cell.effectVal / 255.0f)
                : (cell.velocity > 0 ? cell.normalizedVelocity() : (cast(float) cell.effectVal / 255.0f));
            graph.enqueueEvent(
                st.activeModule,
                ModEvent.makeSetParamNormalized(cast(uint)(cell.paramId - 1), pNorm, true),
                emitFrame
            );
        }

        if (cell.note == NoteCmd.noteOff) {
            if (st.activeModule.isValid() && st.activeNoteId.isValid()) {
                graph.enqueueEvent(st.activeModule, ModEvent.makeNoteOff(st.activeNoteId), emitFrame);
                st.activeNoteId = NoteId.none;
            }
        } else if (cell.isMidiNote()) {
            immutable float targetNote = cast(float) cell.midiNote();
            if (cell.velocity > 0) {
                st.velocity = cell.normalizedVelocity();
            } else if (cell.effect != EffectCode.portamento) {
                st.velocity = 0.8f;
            }

            if (cell.effect == EffectCode.portamento && st.activeNoteId.isValid()) {
                st.portamentoTarget = targetNote;
                st.portamentoActive = true;
                if (cell.effectVal > 0) {
                    st.lastPortaSpeed = cell.effectVal;
                }
            } else if (st.activeModule.isValid()) {
                if (st.activeNoteId.isValid()) {
                    graph.enqueueEvent(st.activeModule, ModEvent.makeNoteOff(st.activeNoteId), emitFrame);
                }
                st.activeNoteId = nextNoteId();
                st.basePitch = targetNote;
                st.currentPitch = targetNote;
                graph.enqueueEvent(
                    st.activeModule,
                    ModEvent.makeNoteOn(st.activeNoteId, targetNote, st.velocity),
                    emitFrame
                );
            }
        } else if (cell.note == NoteCmd.setPitch || cell.note == NoteCmd.prevTrack) {
            if (cell.velocity > 0 && st.activeModule.isValid() && st.activeNoteId.isValid()) {
                st.velocity = cell.normalizedVelocity();
                graph.enqueueEvent(st.activeModule, ModEvent.makeSetVelocity(st.activeNoteId, st.velocity), emitFrame);
            }
        }

        switch (cell.effect) {
            case EffectCode.slideUp:
                if (cell.effectVal > 0) st.lastSlideUp = cell.effectVal;
                break;

            case EffectCode.slideDown:
                if (cell.effectVal > 0) st.lastSlideDown = cell.effectVal;
                break;

            case EffectCode.portamento:
                if (cell.effectVal > 0) st.lastPortaSpeed = cell.effectVal;
                st.portamentoActive = true;
                break;

            case EffectCode.vibrato:
                if (cell.effectVal > 0) {
                    if ((cell.effectVal >> 4) > 0) st.lastVibSpeed = cast(ubyte)(cell.effectVal >> 4);
                    if ((cell.effectVal & 0x0F) > 0) st.lastVibDepth = cast(ubyte)(cell.effectVal & 0x0F);
                }
                st.vibratoActive = true;
                break;

            case EffectCode.pitchOffsetUp:
                if (st.activeModule.isValid() && st.activeNoteId.isValid()) {
                    st.currentPitch += cast(float) cell.effectVal * 0.0625f;
                    graph.enqueueEvent(
                        st.activeModule,
                        ModEvent.makeSetPitch(st.activeNoteId, st.currentPitch),
                        emitFrame
                    );
                }
                break;

            case EffectCode.pitchOffsetDown:
                if (st.activeModule.isValid() && st.activeNoteId.isValid()) {
                    st.currentPitch -= cast(float) cell.effectVal * 0.0625f;
                    graph.enqueueEvent(
                        st.activeModule,
                        ModEvent.makeSetPitch(st.activeNoteId, st.currentPitch),
                        emitFrame
                    );
                }
                break;

            case EffectCode.arpeggio:
                if (cell.effectVal > 0 || st.lastArp > 0) {
                    immutable ubyte arpVal = cell.effectVal > 0 ? cell.effectVal : st.lastArp;
                    st.lastArp = arpVal;
                    st.arpX = cast(ubyte)(arpVal >> 4);
                    st.arpY = cast(ubyte)(arpVal & 0x0F);
                    st.arpStep = 0;
                    st.arpActive = true;
                }
                break;

            case EffectCode.velocitySlide:
                if (cell.effectVal > 0) st.lastVelSlide = cell.effectVal;
                break;

            case EffectCode.fineSlideUp:
                if (st.activeModule.isValid() && st.activeNoteId.isValid()) {
                    immutable ubyte amt = cell.effectVal > 0 ? cell.effectVal : st.lastSlideUp;
                    st.currentPitch += cast(float) amt * 0.03125f;
                    graph.enqueueEvent(
                        st.activeModule,
                        ModEvent.makeSetPitch(st.activeNoteId, st.currentPitch),
                        emitFrame
                    );
                }
                break;

            case EffectCode.fineSlideDown:
                if (st.activeModule.isValid() && st.activeNoteId.isValid()) {
                    immutable ubyte amt = cell.effectVal > 0 ? cell.effectVal : st.lastSlideDown;
                    st.currentPitch -= cast(float) amt * 0.03125f;
                    graph.enqueueEvent(
                        st.activeModule,
                        ModEvent.makeSetPitch(st.activeNoteId, st.currentPitch),
                        emitFrame
                    );
                }
                break;

            case EffectCode.retrigger: {
                immutable ubyte rVal = cell.effectVal > 0 ? cell.effectVal : st.lastRetrig;
                if (rVal > 0) {
                    st.lastRetrig = rVal;
                    st.retrigPeriod = (rVal & 0x0Fu) > 0 ? cast(uint)(rVal & 0x0Fu) : 1u;
                    st.retrigCounter = 0;
                }
                break;
            }

            default:
                break;
        }
    }

    private void processContinuationTick(
        TrackEffectState* st,
        NoteCell cell,
        uint tick,
        FrameTime absFrame,
        ref AudioGraph graph
    ) {
        if (st.delayTick >= 0 && cast(int) tick == st.delayTick) {
            st.delayTick = -1;
            SequencerActionFlags unused;
            NoteCell dc = st.delayedCell;
            dc.effect = EffectCode.none;
            dc.effectVal = 0;
            executeCellAction(st, dc, absFrame, graph, unused);
        }

        if (st.cutTick >= 0 && cast(int) tick == st.cutTick) {
            st.cutTick = -1;
            if (st.activeModule.isValid() && st.activeNoteId.isValid()) {
                graph.enqueueEvent(st.activeModule, ModEvent.makeNoteOff(st.activeNoteId), absFrame);
                st.activeNoteId = NoteId.none;
            }
            return;
        }

        if (!st.activeModule.isValid() || !st.activeNoteId.isValid()) {
            return;
        }

        if (st.retrigPeriod > 0) {
            st.retrigCounter++;
            if (st.retrigCounter >= st.retrigPeriod) {
                st.retrigCounter = 0;
                graph.enqueueEvent(st.activeModule, ModEvent.makeNoteOff(st.activeNoteId), absFrame);
                st.activeNoteId = nextNoteId();
                graph.enqueueEvent(
                    st.activeModule,
                    ModEvent.makeNoteOn(st.activeNoteId, st.currentPitch, st.velocity),
                    absFrame
                );
            }
        }

        bool pitchDirty = false;
        float emittedPitch = st.currentPitch;

        if (cell.effect == EffectCode.slideUp) {
            immutable float delta = cast(float)(cell.effectVal > 0 ? cell.effectVal : st.lastSlideUp) * 0.0625f;
            st.currentPitch += delta;
            emittedPitch = st.currentPitch;
            pitchDirty = true;
        } else if (cell.effect == EffectCode.slideDown) {
            immutable float delta = cast(float)(cell.effectVal > 0 ? cell.effectVal : st.lastSlideDown) * 0.0625f;
            st.currentPitch -= delta;
            emittedPitch = st.currentPitch;
            pitchDirty = true;
        } else if (cell.effect == EffectCode.portamento || st.portamentoActive) {
            immutable float step = cast(float)(st.lastPortaSpeed > 0 ? st.lastPortaSpeed : 1) * 0.125f;
            immutable float diff = st.portamentoTarget - st.currentPitch;
            if (diff > step) {
                st.currentPitch += step;
            } else if (diff < -step) {
                st.currentPitch -= step;
            } else {
                st.currentPitch = st.portamentoTarget;
                st.portamentoActive = false;
            }
            emittedPitch = st.currentPitch;
            pitchDirty = true;
        }

        if (cell.effect == EffectCode.vibrato || st.vibratoActive) {
            immutable float speed = cast(float)(st.lastVibSpeed > 0 ? st.lastVibSpeed : 4) / 32.0f;
            immutable float depth = cast(float)(st.lastVibDepth > 0 ? st.lastVibDepth : 4) * 0.0625f;
            st.vibratoPhase += speed;
            if (st.vibratoPhase >= 1.0f) {
                st.vibratoPhase -= 1.0f;
            }
            emittedPitch = st.currentPitch + lookupSine(st.vibratoPhase) * depth;
            pitchDirty = true;
        }

        if (cell.effect == EffectCode.arpeggio || st.arpActive) {
            st.arpStep = (st.arpStep + 1) % 3;
            immutable float offset = st.arpStep == 1 ? cast(float) st.arpX : (st.arpStep == 2 ? cast(float) st.arpY : 0.0f);
            emittedPitch = st.currentPitch + offset;
            pitchDirty = true;
        }

        if (pitchDirty) {
            graph.enqueueEvent(st.activeModule, ModEvent.makeSetPitch(st.activeNoteId, emittedPitch), absFrame);
        }

        if (cell.effect == EffectCode.velocitySlide) {
            immutable ubyte vs = cell.effectVal > 0 ? cell.effectVal : st.lastVelSlide;
            immutable float up = cast(float)(vs >> 4) / 64.0f;
            immutable float dn = cast(float)(vs & 0x0Fu) / 64.0f;
            st.velocity += (up - dn);
            if (st.velocity < 0.0f) st.velocity = 0.0f;
            if (st.velocity > 1.0f) st.velocity = 1.0f;
            graph.enqueueEvent(st.activeModule, ModEvent.makeSetVelocity(st.activeNoteId, st.velocity), absFrame);
        }
    }
}

static assert(!hasGcReference!TrackEffectBank,
    "TrackEffectBank must remain free of D GC indirections");
