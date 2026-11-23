/**
 * File:         source/modules/control/multisynth.d
 * Module:       modules.control.multisynth
 * Phase:        Phase 4.2 (Tier 1) — Note, Velocity & Pitch Router
 *
 * Purpose:
 *   Transforms and fans out incoming note, pitch, and velocity ModEvents to downstream modules using transposition, velocity scaling, pitch randomization, and optional off-RT swapped transfer curves.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process()/handleEvent()/swapAsset(); curve assets live in unmanaged memory swapped cleanly via SwapModuleAsset.
 *
 * Dependencies:
 *   Internal: dsp.oscillator, foundation.memory, graph.context, graph.event, graph.module_api, graph.port
 *   External: core.lifetime, core.stdc.stdlib, core.stdc.string, std.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct MultiSynthCurveAsset
 *   - struct MultiSynth (typeId = "ctl.multisynth", ports: event in, event out)
 *   - @Param transpose, finetune, randomPitch, velocityScale, curveMode
 *   - Hooks: handleEvent, process, swapAsset, serializeExtra, deserializeExtra
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.multisynth;

import core.lifetime : emplace;
import core.stdc.stdlib : calloc, free;
import core.stdc.string : memcpy;
import std.math : isFinite;

import dsp.oscillator : DeterministicNoise;
import foundation.memory : FixedArray;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Unmanaged @nogc transfer curve asset specifying 128-entry velocity scaling and pitch offsets.
 */
struct MultiSynthCurveAsset {
    float[128] velCurve = 1.0f;
    float[128] pitchOffset = 0.0f;

    @nogc nothrow:

    /**
     * Allocates a default unity MultiSynthCurveAsset off the real-time thread.
     *
     * Returns:
     *   Pointer to unmanaged MultiSynthCurveAsset, or null on OOM.
     */
    static MultiSynthCurveAsset* createOffRT() {
        auto ptr = cast(MultiSynthCurveAsset*) calloc(1, MultiSynthCurveAsset.sizeof);
        if (ptr !is null) {
            emplace(ptr);
        }
        return ptr;
    }

    /**
     * Type-erased destructor invoked via RetireSink or module cleanup off-RT.
     *
     * Params:
     *   raw = Opaque MultiSynthCurveAsset* pointer.
     */
    static void destroyErased(void* raw) {
        if (raw !is null) {
            free(raw);
        }
    }
}

/**
 * Event router transforming incoming note pitch/velocity events and emitting to all downstream wires.
 */
struct MultiSynth {
    enum string typeId = "ctl.multisynth";
    enum string displayName = "MultiSynth";
    enum ModuleCategory category = ModuleCategory.control;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Events Out", PortKind.event, PortDirection.output)
    ];

    @Param("Transpose", -48.0f, 48.0f, 0.0f, "st", ParamScale.linear)
    float transpose = 0.0f;

    @Param("Fine Tune", -1.0f, 1.0f, 0.0f, "st", ParamScale.linear)
    float finetune = 0.0f;

    @Param("Random Pitch", 0.0f, 12.0f, 0.0f, "st", ParamScale.linear)
    float randomPitch = 0.0f;

    @Param("Velocity Scale", 0.0f, 2.0f, 1.0f, "", ParamScale.linear)
    float velocityScale = 1.0f;

    @Param("Curve Mode", 0.0f, 2.0f, 0.0f, "", ParamScale.discrete)
    float curveMode = 0.0f;

    private FixedArray!(ModEvent, 64) pendingOut_;
    private DeterministicNoise rng_;
    private MultiSynthCurveAsset* curveAsset_ = null;

    /**
     * Serializes the attached MultiSynthCurveAsset blob off-RT for preset/project persistence.
     *
     * Params:
     *   payload = Output byte slice receiving serialized curve tables (empty when default).
     *
     * Returns:
     *   True on success.
     */
    bool serializeExtra(out ubyte[] payload) const {
        if (curveAsset_ is null) {
            payload = null;
            return true;
        }
        payload = new ubyte[MultiSynthCurveAsset.sizeof];
        memcpy(payload.ptr, curveAsset_, MultiSynthCurveAsset.sizeof);
        return true;
    }

    enum uint ASSET_SLOT_COUNT = 1;

    /**
     * Returns the destructor for the asset type held in slot (used by live asset replacement).
     *
     * Params:
     *   slot = Asset slot index.
     *
     * Returns:
     *   Type-erased destructor.
     */
    static void function(void*) @nogc nothrow assetDestroyFn(uint slot) @nogc nothrow pure @safe {
        cast(void) slot;
        return &MultiSynthCurveAsset.destroyErased;
    }

    /**
     * Restores a persisted MultiSynthCurveAsset blob off the real-time thread.
     *
     * Params:
     *   payload = Previously serialized MultiSynthCurveAsset bytes.
     *   sampleRate = Active sample rate in Hertz.
     *
     * Returns:
     *   True if valid or empty; false on malformed payload or OOM.
     */
    bool deserializeExtra(const(ubyte)[] payload, float sampleRate) {
        cast(void) sampleRate;
        if (payload.length == 0) {
            return true;
        }
        if (payload.length != MultiSynthCurveAsset.sizeof) {
            return false;
        }
        auto next = MultiSynthCurveAsset.createOffRT();
        if (next is null) {
            return false;
        }
        memcpy(next, payload.ptr, MultiSynthCurveAsset.sizeof);
        void* prev = null;
        swapAsset(0, next, prev);
        if (prev !is null) {
            MultiSynthCurveAsset.destroyErased(prev);
        }
        return true;
    }

    @nogc nothrow:

    /**
     * Destroys any currently attached curve asset pointer cleanly on module teardown.
     */
    ~this() {
        if (curveAsset_ !is null) {
            MultiSynthCurveAsset.destroyErased(curveAsset_);
            curveAsset_ = null;
        }
    }

    /**
     * Initializes deterministic PRNG and clears queued output events.
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
     * Clears pending event FIFO and re-seeds deterministic random pitch generator.
     */
    void reset() {
        pendingOut_.clear();
        rng_.reset(0x534D_594Eu);
    }

    /**
     * Transforms an incoming ModEvent and stages it for emission inside process().
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        cast(void) sampleRate;
        ModEvent transformed = ev;
        immutable float shift = (isFinite(transpose) ? transpose : 0.0f)
            + (isFinite(finetune) ? finetune : 0.0f);
        immutable float vScale = isFinite(velocityScale) ? velocityScale : 1.0f;
        immutable int cMode = isFinite(curveMode) ? cast(int)(curveMode + 0.5f) : 0;

        if (ev.kind == ModEventKind.noteOn) {
            float note = isFinite(ev.valueA) ? ev.valueA : 60.0f;
            float vel = (isFinite(ev.valueB) ? ev.valueB : 1.0f) * vScale;
            if (curveAsset_ !is null && cMode >= 1) {
                int vIdx = cast(int)(vel * 127.0f + 0.5f);
                if (vIdx < 0) vIdx = 0;
                if (vIdx > 127) vIdx = 127;
                int nIdx = cast(int)(note + 0.5f);
                if (nIdx < 0) nIdx = 0;
                if (nIdx > 127) nIdx = 127;
                vel *= curveAsset_.velCurve[vIdx];
                if (cMode >= 2) {
                    note += curveAsset_.pitchOffset[nIdx];
                }
            }
            if (isFinite(randomPitch) && randomPitch > 0.0f) {
                note += rng_.white() * randomPitch;
            }
            note += shift;
            if (note < 0.0f) note = 0.0f;
            if (note > 127.0f) note = 127.0f;
            if (vel < 0.0f) vel = 0.0f;
            if (vel > 1.0f) vel = 1.0f;
            transformed.valueA = note;
            transformed.valueB = vel;
        } else if (ev.kind == ModEventKind.setPitch) {
            transformed.valueA = (isFinite(ev.valueA) ? ev.valueA : 60.0f) + shift;
        } else if (ev.kind == ModEventKind.setVelocity) {
            float vel = (isFinite(ev.valueB) ? ev.valueB : 1.0f) * vScale;
            if (vel < 0.0f) vel = 0.0f;
            if (vel > 1.0f) vel = 1.0f;
            transformed.valueB = vel;
        }

        pendingOut_.tryPush(transformed);
    }

    /**
     * Flushes staged transformed events to downstream connected event inputs.
     *
     * Params:
     *   ctx = Per-slice processing context holding eventOut sink.
     *
     * Returns:
     *   True if one or more events were emitted during this slice; false otherwise.
     */
    bool process(ref ProcessContext ctx) {
        if (pendingOut_.empty()) {
            return false;
        }
        foreach (ref ev; pendingOut_[]) {
            ctx.eventOut.emit(ev);
        }
        pendingOut_.clear();
        return true;
    }

    /**
     * Atomically replaces the active MultiSynthCurveAsset pointer on slot 0 for RT retire cleanup.
     *
     * Params:
     *   slot = Asset slot index (must be 0).
     *   newAsset = Newly allocated MultiSynthCurveAsset* (may be null to revert to identity).
     *   oldAsset = Receives previous MultiSynthCurveAsset* for off-RT reclamation.
     *
     * Returns:
     *   True if slot == 0; false otherwise.
     */
    bool swapAsset(uint slot, void* newAsset, out void* oldAsset) {
        oldAsset = null;
        if (slot != 0) {
            return false;
        }
        oldAsset = curveAsset_;
        curveAsset_ = cast(MultiSynthCurveAsset*) newAsset;
        return true;
    }
}
