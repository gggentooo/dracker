/**
 * File:         source/modules/control/velocity2ctl.d
 * Module:       modules.control.velocity2ctl
 * Phase:        Phase 4.8 (Tier 2) — Note Velocity-to-Controller Mapper
 *
 * Purpose:
 *   Maps incoming note velocity levels onto continuous parameter automation ModEvents and audio-rate CV modulation outputs with selectable NoteOff release behavior.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; zero heap allocations.
 *
 * Dependencies:
 *   Internal: graph.buffer, graph.context, graph.event, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Velocity2Ctl (typeId = "ctl.velocity2ctl", ports: event in, event out, cvControl out)
 *   - @Param outMin, outMax, noteOffAction
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.velocity2ctl;

import std.math : fabs, isFinite;

import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Velocity-to-controller converter outputting scaled parameter events and audio-rate CV.
 */
struct Velocity2Ctl {
    enum string typeId = "ctl.velocity2ctl";
    enum string displayName = "Velocity2Ctl";
    enum ModuleCategory category = ModuleCategory.control;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Events Out", PortKind.event, PortDirection.output),
        PortDescriptor("cvOut", "CV Out", PortKind.cvControl, PortDirection.output)
    ];

    @Param("Out Min", 0.0f, 1.0f, 0.0f, "", ParamScale.linear)
    float outMin = 0.0f;

    @Param("Out Max", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float outMax = 1.0f;

    @Param("NoteOff Action", 0.0f, 2.0f, 0.0f, "", ParamScale.discrete,
        ["Keep", "Go To Min", "Go To 0"])
    float noteOffAction = 0.0f;

    private float currentValue_ = 0.0f;
    private bool pendingEmit_ = false;

    @nogc nothrow:

    /**
     * Initializes output state cleanly before playback.
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
     * Resets mapped output to outMin cleanly.
     */
    void reset() {
        currentValue_ = isFinite(outMin) ? outMin : 0.0f;
        pendingEmit_ = false;
    }

    /**
     * Translates NoteOn, SetVelocity, and NoteOff velocity dynamics cleanly.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        cast(void) sampleRate;
        immutable float lo = isFinite(outMin) ? outMin : 0.0f;
        immutable float hi = isFinite(outMax) ? outMax : 1.0f;

        if (ev.kind == ModEventKind.noteOn || ev.kind == ModEventKind.setVelocity) {
            float vel = isFinite(ev.valueB) ? ev.valueB : 1.0f;
            if (vel < 0.0f) vel = 0.0f;
            if (vel > 1.0f) vel = 1.0f;
            currentValue_ = lo + vel * (hi - lo);
            pendingEmit_ = true;
        } else if (ev.kind == ModEventKind.noteOff || ev.kind == ModEventKind.allNotesOff) {
            immutable int act = isFinite(noteOffAction) ? cast(int)(noteOffAction + 0.5f) : 0;
            if (act == 1) {
                currentValue_ = lo;
                pendingEmit_ = true;
            } else if (act >= 2) {
                currentValue_ = 0.0f;
                pendingEmit_ = true;
            }
        }
    }

    /**
     * Outputs continuous CV values and emits pending setParam ModEvents downstream.
     *
     * Params:
     *   io = Bundle holding optional cvControl output slice.
     *   ctx = Per-slice execution context holding EventSink.
     *
     * Returns:
     *   True while output CV or event emission is active.
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
