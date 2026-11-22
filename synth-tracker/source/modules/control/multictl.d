/**
 * File:         source/modules/control/multictl.d
 * Module:       modules.control.multictl
 * Phase:        Phase 4.2 (Tier 1) — Fan-Out Controller Curve Mapper
 *
 * Purpose:
 *   Maps a master macro controller (or incoming CV modulation signal) through quantization and lookup curves onto multiple target parameter ModEvents.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; emits target ModEvent.setParam events via EventSink with zero heap calls.
 *
 * Dependencies:
 *   Internal: dsp.interp, graph.buffer, graph.context, graph.event, graph.module_api, graph.port
 *   External: core.lifetime, core.stdc.stdlib, core.stdc.string, std.math (fabs, floor, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct MultiCtlTarget / struct MultiCtlMapAsset
 *   - struct MultiCtl (typeId = "ctl.multictl", ports: event in, cvControl in, event out)
 *   - @Param value, gain, quantization
 *   - Hooks: onParamChanged, handleEvent, process, swapAsset, serializeExtra, deserializeExtra
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.multictl;

import core.lifetime : emplace;
import core.stdc.stdlib : calloc, free;
import core.stdc.string : memcpy;
import std.math : fabs, floor, isFinite;

import dsp.interp : interpLinear;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Single fan-out controller destination range descriptor inside MultiCtlMapAsset.
 */
struct MultiCtlTarget {
    uint paramId = 0;
    float outMin = 0.0f;
    float outMax = 1.0f;
    bool enabled = false;
}

/**
 * Unmanaged @nogc mapping asset holding up to 16 destination parameter targets and a 129-point curve.
 */
struct MultiCtlMapAsset {
    MultiCtlTarget[16] targets;
    float[129] curve = 0.0f;

    @nogc nothrow:

    /**
     * Allocates a MultiCtlMapAsset initialized with a linear identity curve and target 0 active.
     *
     * Returns:
     *   Pointer to unmanaged MultiCtlMapAsset, or null on OOM.
     */
    static MultiCtlMapAsset* createOffRT() {
        auto ptr = cast(MultiCtlMapAsset*) calloc(1, MultiCtlMapAsset.sizeof);
        if (ptr !is null) {
            emplace(ptr);
            foreach (i; 0 .. 129) {
                ptr.curve[i] = cast(float) i / 128.0f;
            }
            ptr.targets[0] = MultiCtlTarget(0, 0.0f, 1.0f, true);
        }
        return ptr;
    }

    /**
     * Frees an unmanaged MultiCtlMapAsset off the real-time thread.
     *
     * Params:
     *   raw = Opaque MultiCtlMapAsset* pointer.
     */
    static void destroyErased(void* raw) {
        if (raw !is null) {
            free(raw);
        }
    }
}

/**
 * Fan-out macro controller translating scalar/CV automation through quantization and mapping curves.
 */
struct MultiCtl {
    enum string typeId = "ctl.multictl";
    enum string displayName = "MultiCtl";
    enum ModuleCategory category = ModuleCategory.control;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("cvIn", "CV In", PortKind.cvControl, PortDirection.input),
        PortDescriptor("out", "Events Out", PortKind.event, PortDirection.output)
    ];

    @Param("Value", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float value = 0.5f;

    @Param("Gain", 0.0f, 2.0f, 1.0f, "", ParamScale.linear)
    float gain = 1.0f;

    @Param("Quantization", 0.0f, 128.0f, 0.0f, "steps", ParamScale.discrete)
    float quantization = 0.0f;

    private MultiCtlMapAsset* mapAsset_ = null;
    private float lastEmitted_ = -1.0f;
    private bool dirty_ = false;
    private bool pendingInstant_ = false;

    /**
     * Serializes the attached MultiCtlMapAsset blob off-RT.
     *
     * Params:
     *   payload = Serialized map bytes (empty if using default linear target).
     *
     * Returns:
     *   True on success.
     */
    bool serializeExtra(out ubyte[] payload) const {
        if (mapAsset_ is null) {
            payload = null;
            return true;
        }
        payload = new ubyte[MultiCtlMapAsset.sizeof];
        memcpy(payload.ptr, mapAsset_, MultiCtlMapAsset.sizeof);
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
        return &MultiCtlMapAsset.destroyErased;
    }

    /**
     * Deserializes a saved MultiCtlMapAsset blob off the audio thread.
     *
     * Params:
     *   payload = Previously serialized map bytes.
     *   sampleRate = Active sample rate in Hertz.
     *
     * Returns:
     *   True on success or empty payload; false on corrupt length or OOM.
     */
    bool deserializeExtra(const(ubyte)[] payload, float sampleRate) {
        cast(void) sampleRate;
        if (payload.length == 0) {
            return true;
        }
        if (payload.length != MultiCtlMapAsset.sizeof) {
            return false;
        }
        auto next = MultiCtlMapAsset.createOffRT();
        if (next is null) {
            return false;
        }
        memcpy(next, payload.ptr, MultiCtlMapAsset.sizeof);
        void* prev = null;
        swapAsset(0, next, prev);
        if (prev !is null) {
            MultiCtlMapAsset.destroyErased(prev);
        }
        return true;
    }

    @nogc nothrow:

    /**
     * Releases any attached mapping asset cleanly when destroyed off-RT.
     */
    ~this() {
        if (mapAsset_ !is null) {
            MultiCtlMapAsset.destroyErased(mapAsset_);
            mapAsset_ = null;
        }
    }

    /**
     * Marks initial state clean without spurious emission until edited or modulated.
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
     * Resets dirty emission tracker cleanly.
     */
    void reset() {
        lastEmitted_ = -1.0f;
        dirty_ = false;
        pendingInstant_ = false;
    }

    /**
     * Flags changed parameters so the next process() emits updated target values.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = Preserves instant snap flag onto emitted ModEvents.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "value" || field == "gain" || field == "quantization") {
            dirty_ = true;
            pendingInstant_ = instant;
        }
    }

    /**
     * Accepts incoming setParam/transport controller events and marks outputs dirty.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        cast(void) sampleRate;
        if (ev.kind == ModEventKind.setParam || ev.kind == ModEventKind.setParamInstant) {
            if (isFinite(ev.valueA)) {
                value = clamp01(ev.valueA);
                dirty_ = true;
                pendingInstant_ = (ev.kind == ModEventKind.setParamInstant);
            }
        }
    }

    /**
     * Evaluates macro value + optional CV modulation and emits mapped setParam ModEvents.
     *
     * Params:
     *   io = Audio and CV input/output bundle (reads cvIn[0] when connected).
     *   ctx = Per-slice execution context holding EventSink.
     *
     * Returns:
     *   True if any target ModEvents were emitted during this slice; false otherwise.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        float raw = isFinite(value) ? value : 0.5f;
        if (io.numCvIn > 0 && io.cvIn[0].connected && !io.cvIn[0].silent && io.cvIn[0].samples.length > 0) {
            immutable float cv = isFinite(io.cvIn[0].samples[0]) ? io.cvIn[0].samples[0] : 0.0f;
            raw += cv;
            dirty_ = true;
        }

        if (!dirty_) {
            return false;
        }

        immutable float g = isFinite(gain) ? gain : 1.0f;
        float norm = clamp01(raw * g);

        immutable int qSteps = isFinite(quantization) ? cast(int)(quantization + 0.5f) : 0;
        if (qSteps >= 2) {
            immutable float denom = cast(float)(qSteps - 1);
            norm = cast(float)(floor(cast(double)(norm * denom) + 0.5) / cast(double) denom);
            norm = clamp01(norm);
        }

        dirty_ = false;
        if (fabs(norm - lastEmitted_) <= 1e-6f && !pendingInstant_) {
            return false;
        }
        lastEmitted_ = norm;

        if (mapAsset_ is null) {
            ctx.eventOut.emit(ModEvent.makeSetParam(0, norm, pendingInstant_, 0));
            pendingInstant_ = false;
            return true;
        }

        immutable float fIdx = norm * 128.0f;
        size_t i0 = cast(size_t) fIdx;
        if (i0 > 127) i0 = 127;
        immutable float frac = fIdx - cast(float) i0;
        immutable float shaped = clamp01(interpLinear(mapAsset_.curve[i0], mapAsset_.curve[i0 + 1], frac));

        bool any = false;
        foreach (ref t; mapAsset_.targets) {
            if (!t.enabled) {
                continue;
            }
            immutable float mapped = t.outMin + shaped * (t.outMax - t.outMin);
            ctx.eventOut.emit(ModEvent.makeSetParam(t.paramId, mapped, pendingInstant_, 0));
            any = true;
        }
        pendingInstant_ = false;
        return any;
    }

    /**
     * Atomically swaps the attached MultiCtlMapAsset on slot 0.
     *
     * Params:
     *   slot = Asset slot index (must be 0).
     *   newAsset = Replacement MultiCtlMapAsset* pointer.
     *   oldAsset = Receives previous MultiCtlMapAsset* pointer for off-RT free.
     *
     * Returns:
     *   True if slot == 0.
     */
    bool swapAsset(uint slot, void* newAsset, out void* oldAsset) {
        oldAsset = null;
        if (slot != 0) {
            return false;
        }
        oldAsset = mapAsset_;
        mapAsset_ = cast(MultiCtlMapAsset*) newAsset;
        dirty_ = true;
        return true;
    }

    private static float clamp01(float x) pure @safe {
        if (!isFinite(x) || x < 0.0f) return 0.0f;
        if (x > 1.0f) return 1.0f;
        return x;
    }
}
