/**
 * File:         source/modules/control/pitch2ctl.d
 * Module:       modules.control.pitch2ctl
 * Phase:        Phase 4.8 (Tier 2) — Note Pitch-to-Controller Mapper
 *
 * Purpose:
 *   Maps incoming musical note pitches onto continuous parameter automation ModEvents and audio-rate CV keytracking outputs.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; smooths and routes pitch-derived control cleanly without heap allocations.
 *
 * Dependencies:
 *   Internal: foundation.types, graph.buffer, graph.context, graph.event, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Pitch2Ctl (typeId = "ctl.pitch2ctl", ports: event in, event out, cvControl out)
 *   - @Param firstNote, numSemitones, outMin, outMax
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.pitch2ctl;

import std.math : fabs, isFinite;

import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Keytracking controller converter outputting both audio-rate CV and parameter ModEvents.
 */
struct Pitch2Ctl {
    enum string typeId = "ctl.pitch2ctl";
    enum string displayName = "Pitch2Ctl";
    enum ModuleCategory category = ModuleCategory.control;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Events Out", PortKind.event, PortDirection.output),
        PortDescriptor("cvOut", "CV Out", PortKind.cvControl, PortDirection.output)
    ];

    @Param("First Note", 0.0f, 120.0f, 24.0f, "", ParamScale.discrete)
    float firstNote = 24.0f;

    @Param("Semitones", 1.0f, 127.0f, 72.0f, "st", ParamScale.discrete)
    float numSemitones = 72.0f;

    @Param("Out Min", 0.0f, 1.0f, 0.0f, "", ParamScale.linear)
    float outMin = 0.0f;

    @Param("Out Max", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float outMax = 1.0f;

    private float currentValue_ = 0.0f;
    private bool pendingEmit_ = false;

    @nogc nothrow:

    /**
     * Initializes mapped output to outMin cleanly.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) sampleRate;
        cast(void) maxSliceFrames;
        reset();
    }

    /**
     * Resets mapped output value to current outMin and clears pending emits.
     */
    void reset() {
        currentValue_ = isFinite(outMin) ? outMin : 0.0f;
        pendingEmit_ = false;
    }

    /**
     * Converts incoming NoteOn/SetPitch pitches onto [outMin, outMax] cleanly.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        cast(void) sampleRate;
        if (ev.kind == ModEventKind.noteOn || ev.kind == ModEventKind.setPitch) {
            immutable float note = isFinite(ev.valueA) ? ev.valueA : firstNote;
            immutable float base = isFinite(firstNote) ? firstNote : 24.0f;
            immutable float span = (isFinite(numSemitones) && numSemitones >= 1.0f) ? numSemitones : 72.0f;
            float norm = (note - base) / span;
            if (norm < 0.0f) norm = 0.0f;
            if (norm > 1.0f) norm = 1.0f;
            immutable float lo = isFinite(outMin) ? outMin : 0.0f;
            immutable float hi = isFinite(outMax) ? outMax : 1.0f;
            currentValue_ = lo + norm * (hi - lo);
            pendingEmit_ = true;
        }
    }

    /**
     * Writes audio-rate keytracking CV into cvOut[0] and emits pending setParam ModEvents.
     *
     * Params:
     *   io = Bundle holding optional cvControl output view.
     *   ctx = Per-slice execution context holding EventSink.
     *
     * Returns:
     *   True while output value or emitted event is non-idle.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        immutable bool hasCvOut = io.numCvOut > 0 && io.cvOut[0].samples.length >= ctx.frames;
        if (hasCvOut) {
            io.cvOut[0].samples[0 .. ctx.frames] = currentValue_;
        }
        bool emitted = false;
        if (pendingEmit_) {
            ctx.eventOut.emit(ModEvent.makeSetParam(0, currentValue_, false, 0));
            pendingEmit_ = false;
            emitted = true;
        }
        return emitted || (hasCvOut && fabs(currentValue_) > 1e-7f);
    }
}
