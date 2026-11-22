/**
 * File:         source/modules/control/glide.d
 * Module:       modules.control.glide
 * Phase:        Phase 4.8 (Tier 2) — Polyphonic/Monophonic Pitch Portamento
 *
 * Purpose:
 *   Smooths pitch transitions between consecutive note events and emits sample-accurate setPitch ModEvents downstream in monophonic or polyphonic mode.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; fixed 16-slot note tracker with explicit zero/safe defaults and zero heap allocations.
 *
 * Dependencies:
 *   Internal: foundation.memory, foundation.types, graph.context, graph.event, graph.module_api, graph.port
 *   External: std.math (exp, fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Glide (typeId = "ctl.glide", ports: event in, event out)
 *   - @Param responseRate, polyphonic, resetOnFirstNote
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.glide;

import std.math : exp, fabs, isFinite;

import foundation.memory : FixedArray;
import foundation.types : NoteId;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Portamento pitch-glide processor smoothing NoteOn and SetPitch transitions downstream.
 */
struct Glide {
    enum string typeId = "ctl.glide";
    enum string displayName = "Glide";
    enum ModuleCategory category = ModuleCategory.control;
    enum size_t MAX_GLIDE_NOTES = 16;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Events Out", PortKind.event, PortDirection.output)
    ];

    @Param("Response", 0.1f, 500.0f, 35.0f, "ms", ParamScale.logarithmic)
    float responseRate = 35.0f;

    @Param("Polyphonic", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete)
    float polyphonic = 0.0f;

    @Param("Reset On First", 0.0f, 1.0f, 1.0f, "", ParamScale.discrete)
    float resetOnFirstNote = 1.0f;

    private struct GlideVoiceState {
        NoteId noteId = NoteId.none;
        double currentPitch = 60.0;
        double targetPitch = 60.0;
        bool active = false;
    }

    private GlideVoiceState[MAX_GLIDE_NOTES] slots_;
    private FixedArray!(ModEvent, 64) forwardQueue_;
    private double lastGlobalPitch_ = 60.0;
    private bool hasPriorNote_ = false;
    private float sampleRate_ = 44_100.0f;

    @nogc nothrow:

    /**
     * Configures initial sample rate and resets all tracked portamento slots.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        reset();
    }

    /**
     * Clears tracked voices, forwarded queue, and portamento history cleanly.
     */
    void reset() {
        foreach (ref s; slots_) {
            s = GlideVoiceState.init;
        }
        forwardQueue_.clear();
        lastGlobalPitch_ = 60.0;
        hasPriorNote_ = false;
    }

    /**
     * Intercepts incoming NoteOn/SetPitch/NoteOff events and prepares glided downstream events.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        immutable bool isPoly = polyphonic >= 0.5f;
        immutable bool resetFirst = resetOnFirstNote >= 0.5f;

        switch (ev.kind) {
            case ModEventKind.noteOn: {
                immutable double targetP = isFinite(ev.valueA) ? cast(double) ev.valueA : 60.0;
                immutable bool snapImmediate = !hasPriorNote_ && resetFirst;
                immutable double startP = snapImmediate ? targetP : lastGlobalPitch_;
                hasPriorNote_ = true;
                lastGlobalPitch_ = targetP;

                if (isPoly) {
                    size_t dstIdx = findSlot(ev.noteId);
                    if (dstIdx >= MAX_GLIDE_NOTES) {
                        dstIdx = findFreeSlot();
                    }
                    if (dstIdx < MAX_GLIDE_NOTES) {
                        slots_[dstIdx] = GlideVoiceState(ev.noteId, startP, targetP, true);
                    }
                } else {
                    slots_[0].noteId = ev.noteId;
                    if (!slots_[0].active || snapImmediate) {
                        slots_[0].currentPitch = startP;
                    }
                    slots_[0].targetPitch = targetP;
                    slots_[0].active = true;
                }

                ModEvent outEv = ev;
                outEv.valueA = cast(float) startP;
                forwardQueue_.tryPush(outEv);
                break;
            }

            case ModEventKind.setPitch: {
                immutable double targetP = isFinite(ev.valueA) ? cast(double) ev.valueA : 60.0;
                lastGlobalPitch_ = targetP;
                immutable size_t idx = findSlot(ev.noteId);
                if (idx < MAX_GLIDE_NOTES && slots_[idx].active) {
                    slots_[idx].targetPitch = targetP;
                } else {
                    forwardQueue_.tryPush(ev);
                }
                break;
            }

            case ModEventKind.noteOff: {
                immutable size_t idx = findSlot(ev.noteId);
                if (idx < MAX_GLIDE_NOTES) {
                    slots_[idx].active = false;
                }
                forwardQueue_.tryPush(ev);
                break;
            }

            case ModEventKind.allNotesOff:
                foreach (ref s; slots_) {
                    s.active = false;
                }
                forwardQueue_.tryPush(ev);
                break;

            default:
                forwardQueue_.tryPush(ev);
                break;
        }
    }

    /**
     * Emits forwarded note events and smooth continuous setPitch ModEvents for gliding notes.
     *
     * Params:
     *   ctx = Per-slice execution context holding EventSink.
     *
     * Returns:
     *   True if any forwarded or glided events were emitted in this slice.
     */
    bool process(ref ProcessContext ctx) {
        bool emitted = false;
        foreach (ref ev; forwardQueue_[]) {
            ctx.eventOut.emit(ev);
            emitted = true;
        }
        forwardQueue_.clear();

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable double tauMs = (isFinite(responseRate) && responseRate > 0.05f) ? cast(double) responseRate : 0.05;
        immutable double sliceAlpha = 1.0 - exp(-cast(double) ctx.frames / (tauMs * 0.001 * cast(double)(sr > 1.0f ? sr : 44_100.0f)));

        foreach (ref s; slots_) {
            if (!s.active) {
                continue;
            }
            immutable double diff = s.targetPitch - s.currentPitch;
            if (fabs(diff) <= 1e-4) {
                if (fabs(diff) > 0.0) {
                    s.currentPitch = s.targetPitch;
                    lastGlobalPitch_ = s.currentPitch;
                    ctx.eventOut.emit(ModEvent.makeSetPitch(s.noteId, cast(float) s.currentPitch, 0));
                    emitted = true;
                }
                continue;
            }
            s.currentPitch += diff * sliceAlpha;
            lastGlobalPitch_ = s.currentPitch;
            ctx.eventOut.emit(ModEvent.makeSetPitch(s.noteId, cast(float) s.currentPitch, 0));
            emitted = true;
        }

        return emitted;
    }

    private size_t findSlot(NoteId id) const pure @safe {
        if (!id.isValid()) {
            return MAX_GLIDE_NOTES;
        }
        foreach (i, ref s; slots_) {
            if (s.active && s.noteId == id) {
                return i;
            }
        }
        return MAX_GLIDE_NOTES;
    }

    private size_t findFreeSlot() const pure @safe {
        foreach (i, ref s; slots_) {
            if (!s.active) {
                return i;
            }
        }
        return 0;
    }
}
