/**
 * File:         source/modules/control/ctl2note.d
 * Module:       modules.control.ctl2note
 * Phase:        Phase 4.8 (Tier 2) — Controller-to-Note Converter
 *
 * Purpose:
 *   Converts scalar parameter automation or audio-rate CV modulation into quantized NoteOn, SetPitch, and NoteOff ModEvents.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; fixed NoteId allocation with zero heap allocations.
 *
 * Dependencies:
 *   Internal: foundation.types, graph.buffer, graph.context, graph.event, graph.module_api, graph.port
 *   External: std.math (fabs, floor, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Ctl2Note (typeId = "ctl.ctl2note", ports: event in, cvControl in, event out)
 *   - @Param pitch, firstNote, rangeNotes, triggerMode
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.ctl2note;

import std.math : fabs, floor, isFinite;

import foundation.types : NoteId;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Controller-to-Note converter emitting quantized MIDI note events from parameter or CV drives.
 */
struct Ctl2Note {
    enum string typeId = "ctl.ctl2note";
    enum string displayName = "Ctl2Note";
    enum ModuleCategory category = ModuleCategory.control;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("cvIn", "CV In", PortKind.cvControl, PortDirection.input),
        PortDescriptor("out", "Events Out", PortKind.event, PortDirection.output)
    ];

    @Param("Pitch", 0.0f, 1.0f, 0.0f, "", ParamScale.linear)
    float pitch = 0.0f;

    @Param("First Note", 0.0f, 108.0f, 36.0f, "", ParamScale.discrete)
    float firstNote = 36.0f;

    @Param("Range Notes", 1.0f, 96.0f, 48.0f, "st", ParamScale.discrete)
    float rangeNotes = 48.0f;

    @Param("Trigger Mode", 0.0f, 2.0f, 0.0f, "", ParamScale.discrete,
        ["Retrigger", "Legato", "Gate"])
    float triggerMode = 0.0f;

    private NoteId currentNoteId_ = NoteId.none;
    private uint nextNoteSeq_ = 1;
    private int lastQuantNote_ = -1;
    private bool dirty_ = false;

    @nogc nothrow:

    /**
     * Resets active note gate and dirty trigger tracker on module prepare.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) sampleRate;
        cast(void) maxSliceFrames;
        reset();
    }

    /**
     * Clears active note tracking cleanly.
     */
    void reset() {
        currentNoteId_ = NoteId.none;
        lastQuantNote_ = -1;
        dirty_ = false;
    }

    /**
     * Flags parameter edits so process() emits note updates cleanly on the active slice.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = Unused.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        cast(void) instant;
        static if (field == "pitch" || field == "firstNote" || field == "rangeNotes" || field == "triggerMode") {
            dirty_ = true;
        }
    }

    /**
     * Accepts scalar setParam events updating controller pitch cleanly.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        cast(void) sampleRate;
        if (ev.kind == ModEventKind.setParam || ev.kind == ModEventKind.setParamInstant) {
            if (isFinite(ev.valueA)) {
                pitch = clamp01(ev.valueA);
                dirty_ = true;
            }
        }
    }

    /**
     * Evaluates controller pitch or CV input and emits quantized NoteOn/Pitch/NoteOff ModEvents.
     *
     * Params:
     *   io = Bundle carrying optional cvIn[0] control input.
     *   ctx = Per-slice execution context holding EventSink.
     *
     * Returns:
     *   True if any note event was emitted during this slice.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        float ctrl = clamp01(pitch);
        if (io.numCvIn > 0 && io.cvIn[0].connected && !io.cvIn[0].silent && io.cvIn[0].samples.length > 0) {
            immutable float cv = isFinite(io.cvIn[0].samples[0]) ? io.cvIn[0].samples[0] : 0.0f;
            ctrl = clamp01(cv);
            dirty_ = true;
        }

        if (!dirty_) {
            return false;
        }
        dirty_ = false;

        immutable int tMode = isFinite(triggerMode) ? cast(int)(triggerMode + 0.5f) : 0;
        if (tMode == 2 && ctrl <= 1e-4f) {
            if (currentNoteId_.isValid()) {
                ctx.eventOut.emit(ModEvent.makeNoteOff(currentNoteId_, 0));
                currentNoteId_ = NoteId.none;
                lastQuantNote_ = -1;
                return true;
            }
            return false;
        }

        immutable int baseN = isFinite(firstNote) ? cast(int)(firstNote + 0.5f) : 36;
        immutable int spanN = isFinite(rangeNotes) && rangeNotes >= 1.0f ? cast(int)(rangeNotes + 0.5f) : 48;
        int quantNote = baseN + cast(int) floor(cast(double) ctrl * cast(double)(spanN - 1) + 0.5);
        if (quantNote < 0) quantNote = 0;
        if (quantNote > 127) quantNote = 127;

        if (quantNote == lastQuantNote_ && currentNoteId_.isValid()) {
            return false;
        }

        bool emitted = false;
        if (tMode == 1 && currentNoteId_.isValid()) {
            ctx.eventOut.emit(ModEvent.makeSetPitch(currentNoteId_, cast(float) quantNote, 0));
            emitted = true;
        } else {
            if (currentNoteId_.isValid()) {
                ctx.eventOut.emit(ModEvent.makeNoteOff(currentNoteId_, 0));
            }
            uint nidVal = nextNoteSeq_++;
            if (nidVal == 0) nidVal = nextNoteSeq_++;
            currentNoteId_ = NoteId(nidVal);
            ctx.eventOut.emit(ModEvent.makeNoteOn(currentNoteId_, cast(float) quantNote, 0.9f, 0));
            emitted = true;
        }

        lastQuantNote_ = quantNote;
        return emitted;
    }

    private static float clamp01(float x) pure @safe {
        if (!isFinite(x) || x < 0.0f) return 0.0f;
        if (x > 1.0f) return 1.0f;
        return x;
    }
}
