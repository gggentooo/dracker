/**
 * File:         source/modules/control/metamodule.d
 * Module:       modules.control.metamodule
 * Phase:        Phase 5.5 — Re-Entrant Nested Child Engine Container
 *
 * Purpose:
 *   Embeds a complete child sequencer.engine.Engine instance synchronized to parent transport/BPM/TPL with macro parameter mapping and recursion-depth guards.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on RT process(); zero global mutable state ensures safe arbitrary nesting; child patch compiled off-RT and swapped via SwapModuleAsset.
 *
 * Dependencies:
 *   Internal: foundation.concurrency, foundation.memory, foundation.types, graph.context, graph.event, graph.module_api, graph.port, sequencer.engine
 *   External: core.lifetime (emplace), core.stdc.stdlib (calloc, free, realloc), core.stdc.string (memcpy), std.bitmanip, std.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum uint MAX_METAMODULE_DEPTH = 16
 *   - struct OwnedChildModule / struct MetaMacroBinding / struct MetaModuleAsset
 *   - struct MetaModule (typeId = "ctl.metamodule", ports: audioStereo in, event events, audioStereo out)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.metamodule;

import core.lifetime : emplace;
import core.stdc.stdlib : calloc, free, realloc;
import core.stdc.string : memcpy;
import std.bitmanip : littleEndianToNative, nativeToLittleEndian;
import std.math : isFinite;
import std.traits : hasIndirections;

import foundation.concurrency : hasGcReference;
import foundation.memory : FixedArray;
import foundation.types : FIXED_BLOCK_FRAMES, ModuleId;
import graph.buffer : ProcessIO;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, ModuleInstance, ModuleVTable, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;
import sequencer.engine : Engine;

enum uint MAX_METAMODULE_DEPTH = 16;

/**
 * Unmanaged child module ownership entry inside MetaModuleAsset containing zero GC references.
 */
struct OwnedChildModule {
    ModuleId id = ModuleId.invalid;
    const(ModuleVTable)* vtable = null;
    void* state = null;
}

static assert(!hasGcReference!OwnedChildModule,
    "OwnedChildModule must remain free of GC indirections");

/**
 * Maps one of the 8 MetaModule macro knobs [0..1] to a child module parameter [minVal..maxVal].
 */
struct MetaMacroBinding {
    ModuleId targetMod = ModuleId.invalid;
    uint paramIdx = 0;
    float minVal = 0.0f;
    float maxVal = 1.0f;
    bool enabled = false;
}

static assert(!hasIndirections!MetaMacroBinding);

/**
 * Unmanaged off-RT-prepared container holding a child Engine, adopted child module states, and 8 macros.
 *
 * Destroyed safely off-RT: tears down Engine (detaching GraphPlan) before freeing adopted child modules.
 */
struct MetaModuleAsset {
    enum size_t NUM_MACROS = 8;

    Engine childEngine;
    ModuleId inputModuleId = ModuleId.invalid;
    MetaMacroBinding[NUM_MACROS] macros;

    private OwnedChildModule* ownedModules_ = null;
    private size_t ownedCount_ = 0;
    private size_t ownedCap_ = 0;

    @disable this(this);

    @nogc nothrow:

    /**
     * Releases childEngine (detaching GraphPlan) first, then destroys every adopted child module state cleanly.
     */
    ~this() {
        childEngine.releaseAllOwnedResources();
        if (ownedModules_ !is null) {
            foreach (i; 0 .. ownedCount_) {
                auto entry = &ownedModules_[i];
                if (entry.state !is null && entry.vtable !is null && entry.vtable.destroy !is null) {
                    entry.vtable.destroy(entry.state);
                }
                entry.state = null;
                entry.vtable = null;
            }
            free(ownedModules_);
            ownedModules_ = null;
            ownedCount_ = 0;
            ownedCap_ = 0;
        }
    }

    /**
     * Allocates and initializes a MetaModuleAsset with an initialized child Engine off-RT.
     *
     * Params:
     *   sampleRate = Initial child engine sample rate in Hertz.
     *
     * Returns:
     *   Pointer to unmanaged MetaModuleAsset, or null on OOM.
     */
    static MetaModuleAsset* createOffRT(float sampleRate) {
        auto ptr = cast(MetaModuleAsset*) calloc(1, MetaModuleAsset.sizeof);
        if (ptr is null) {
            return null;
        }
        emplace(ptr);
        if (!ptr.childEngine.tryInit(sampleRate)) {
            destroyOffRT(ptr);
            return null;
        }
        return ptr;
    }

    /**
     * Transfers ownership of inst.state into this MetaModuleAsset so teardown frees every child module off-RT.
     *
     * Clears inst.state and inst.desc on return so caller scope(exit) destroyOffRT() becomes a no-op.
     *
     * Params:
     *   inst = Initialized ModuleInstance whose state ownership moves into this asset.
     *
     * Returns:
     *   True if adopted validly; false if inst is empty or OOM occurs.
     */
    bool adoptModule(ref ModuleInstance inst) {
        if (!inst.id.isValid() || inst.desc is null || inst.desc.vtable is null || inst.state is null) {
            return false;
        }
        if (ownedCount_ >= ownedCap_) {
            immutable size_t nextCap = ownedCap_ == 0 ? 16 : ownedCap_ * 2;
            auto nextArr = cast(OwnedChildModule*) realloc(
                ownedModules_,
                nextCap * OwnedChildModule.sizeof
            );
            if (nextArr is null) {
                return false;
            }
            ownedModules_ = nextArr;
            ownedCap_ = nextCap;
        }
        ownedModules_[ownedCount_++] = OwnedChildModule(inst.id, inst.desc.vtable, inst.state);
        inst.state = null;
        inst.desc = null;
        inst.id = ModuleId.invalid;
        return true;
    }

    /**
     * Destroys and frees a MetaModuleAsset* off the audio thread.
     *
     * Params:
     *   ptr = Asset pointer to destroy (null-safe).
     */
    static void destroyOffRT(MetaModuleAsset* ptr) {
        if (ptr !is null) {
            destroy!false(*ptr);
            free(ptr);
        }
    }

    /**
     * Type-erased destructor compatible with RetiredResource reclamation off-RT.
     *
     * Params:
     *   raw = Opaque MetaModuleAsset* pointer.
     */
    static void destroyErased(void* raw) {
        destroyOffRT(cast(MetaModuleAsset*) raw);
    }
}

static assert(!hasGcReference!MetaModuleAsset,
    "MetaModuleAsset must contain zero D GC references");

/**
 * Modular container running an independent child Engine synchronized to parent transport with macro controls.
 */
struct MetaModule {
    enum string typeId = "ctl.metamodule";
    enum string displayName = "MetaModule";
    enum ModuleCategory category = ModuleCategory.control;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Audio In", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("events", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("BPM Sync", 0.0f, 1.0f, 1.0f, "", ParamScale.discrete,
        ["Off", "On"])
    float bpmSync = 1.0f;

    @Param("Play Patterns", 0.0f, 2.0f, 1.0f, "", ParamScale.discrete,
        ["Off", "Follow Parent", "Note Triggered"])
    float playPatterns = 1.0f;

    @Param("Input Module", 0.0f, 64.0f, 1.0f, "", ParamScale.discrete)
    float inputModule = 1.0f;

    @Param("Macro 1", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float macro1 = 0.5f;

    @Param("Macro 2", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float macro2 = 0.5f;

    @Param("Macro 3", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float macro3 = 0.5f;

    @Param("Macro 4", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float macro4 = 0.5f;

    @Param("Macro 5", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float macro5 = 0.5f;

    @Param("Macro 6", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float macro6 = 0.5f;

    @Param("Macro 7", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float macro7 = 0.5f;

    @Param("Macro 8", 0.0f, 1.0f, 0.5f, "", ParamScale.linear)
    float macro8 = 0.5f;

    private MetaModuleAsset* childAsset_ = null;
    private FixedArray!(ModEvent, 64) pendingEvents_;
    private float sampleRate_ = 44_100.0f;
    private bool macroDirty_ = true;
    private bool noteTrigPlaying_ = false;

    /**
     * Serializes MetaModule macro routing and child transport configuration off-RT.
     *
     * Params:
     *   payload = Serialized byte stream holding macro bindings and child settings.
     *
     * Returns:
     *   True on success.
     */
    bool serializeExtra(out ubyte[] payload) const {
        if (childAsset_ is null) {
            payload = null;
            return true;
        }
        ubyte[] buf;
        void appendVal(T)(T v) {
            buf ~= nativeToLittleEndian(v)[];
        }

        appendVal!uint(0x4D4D_4F44u);
        appendVal!uint(childAsset_.inputModuleId.value);
        appendVal!double(childAsset_.childEngine.bpm());
        appendVal!uint(childAsset_.childEngine.ticksPerLine());
        foreach (ref m; childAsset_.macros) {
            appendVal!uint(m.targetMod.value);
            appendVal!uint(m.paramIdx);
            appendVal!float(m.minVal);
            appendVal!float(m.maxVal);
            buf ~= m.enabled ? cast(ubyte) 1 : cast(ubyte) 0;
        }
        payload = buf;
        return true;
    }

    /**
     * Restores MetaModule macro bindings and child tempo configuration into an attached or new MetaModuleAsset off-RT.
     *
     * Params:
     *   payload = Previously serialized byte payload from serializeExtra().
     *   sampleRate = Active graph sample rate in Hertz.
     *
     * Returns:
     *   True if empty or validly parsed; false on truncated/corrupt header.
     */
    bool deserializeExtra(const(ubyte)[] payload, float sampleRate) {
        if (payload.length == 0) {
            return true;
        }
        size_t pos = 0;
        bool readVal(T)(out T val) {
            if (pos + T.sizeof > payload.length) {
                return false;
            }
            ubyte[T.sizeof] raw = payload[pos .. pos + T.sizeof];
            val = littleEndianToNative!T(raw);
            pos += T.sizeof;
            return true;
        }

        uint magic = 0;
        uint inModVal = 0;
        double cBpm = 125.0;
        uint cTpl = 6;
        if (!readVal(magic) || magic != 0x4D4D_4F44u || !readVal(inModVal)
                || !readVal(cBpm) || !readVal(cTpl)) {
            return false;
        }

        MetaMacroBinding[MetaModuleAsset.NUM_MACROS] parsedMacros;
        foreach (i; 0 .. MetaModuleAsset.NUM_MACROS) {
            uint tm = 0;
            uint pi = 0;
            float mn = 0.0f;
            float mx = 1.0f;
            ubyte en = 0;
            if (!readVal(tm) || !readVal(pi) || !readVal(mn) || !readVal(mx) || !readVal(en)) {
                return false;
            }
            parsedMacros[i] = MetaMacroBinding(ModuleId(tm), pi, mn, mx, en != 0);
        }

        if (childAsset_ is null) {
            MetaModuleAsset* created = MetaModuleAsset.createOffRT(sampleRate);
            if (created is null) {
                return false;
            }
            void* prev = null;
            swapAsset(0, created, prev);
            if (prev !is null) {
                MetaModuleAsset.destroyErased(prev);
            }
        }
        if (childAsset_ !is null) {
            childAsset_.inputModuleId = ModuleId(inModVal);
            childAsset_.childEngine.setTempo(cBpm, cTpl);
            childAsset_.macros = parsedMacros;
            macroDirty_ = true;
        }
        return true;
    }

    @nogc nothrow:

    /**
     * Frees any owned MetaModuleAsset off-RT when destroyed cleanly.
     */
    ~this() {
        if (childAsset_ !is null) {
            MetaModuleAsset.destroyOffRT(childAsset_);
            childAsset_ = null;
        }
    }

    /**
     * Stores sample rate and marks initial macro state dirty cleanly.
     *
     * Params:
     *   sampleRate = Active graph sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        reset();
    }

    /**
     * Resets queued child events and resets attached childEngine cleanly.
     */
    void reset() {
        pendingEvents_.clear();
        macroDirty_ = true;
        noteTrigPlaying_ = false;
        if (childAsset_ !is null) {
            childAsset_.childEngine.reset();
        }
    }

    /**
     * Marks macro routing dirty so changes apply immediately on the next slice.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = Unused.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        cast(void) instant;
        static if (field.length >= 5 && field[0 .. 5] == "macro") {
            macroDirty_ = true;
        }
    }

    /**
     * Queues incoming parent ModEvents for routing into childEngine during process().
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        pendingEvents_.tryPush(ev);
    }

    /**
     * Renders the embedded child Engine synchronized to parent transport and macro parameters.
     *
     * Enforces MAX_METAMODULE_DEPTH = 16 recursion cutoff, syncs BPM/TPL when enabled, applies all
     * 8 macros, forwards incoming ModEvents, and outputs the child mix cleanly without RT allocations.
     *
     * Params:
     *   io = Parent stereo audio input/output slices.
     *   ctx = Parent per-slice ProcessContext carrying transport and metaDepth.
     *
     * Returns:
     *   True if child engine produced non-silent output.
     */
    bool process(ref ProcessIO io, ref ProcessContext ctx) {
        if (ctx.metaDepth >= MAX_METAMODULE_DEPTH) {
            io.audioOut[0][0 .. ctx.frames] = 0.0f;
            io.audioOut[1][0 .. ctx.frames] = 0.0f;
            pendingEvents_.clear();
            return false;
        }

        if (childAsset_ is null) {
            if (ctx.inputSilent || io.audioIn[0].length < ctx.frames) {
                io.audioOut[0][0 .. ctx.frames] = 0.0f;
                io.audioOut[1][0 .. ctx.frames] = 0.0f;
                pendingEvents_.clear();
                return false;
            }
            io.audioOut[0][0 .. ctx.frames] = io.audioIn[0][0 .. ctx.frames];
            io.audioOut[1][0 .. ctx.frames] = io.audioIn[1][0 .. ctx.frames];
            pendingEvents_.clear();
            return true;
        }

        auto child = &childAsset_.childEngine;
        child.setMetaDepth(ctx.metaDepth + 1);

        immutable int patMode = isFinite(playPatterns) ? cast(int)(playPatterns + 0.5f) : 1;
        immutable ModuleId eventTarget = childAsset_.inputModuleId.isValid()
            ? childAsset_.inputModuleId : resolvedInputModuleId();

        foreach (ref ev; pendingEvents_[]) {
            if (patMode == 2) {
                if (ev.kind == ModEventKind.noteOn) {
                    noteTrigPlaying_ = true;
                    child.seekLine(0);
                } else if (ev.kind == ModEventKind.noteOff || ev.kind == ModEventKind.allNotesOff) {
                    noteTrigPlaying_ = false;
                }
            }
            if (eventTarget.isValid()) {
                child.enqueueEventDirect(eventTarget, ev, child.renderedFrames() + ev.frameOffset);
            }
        }
        pendingEvents_.clear();

        immutable bool doBpmSync = isFinite(bpmSync) && bpmSync >= 0.5f;
        bool shouldPlay = false;
        if (patMode == 1) {
            shouldPlay = ctx.transport.playing;
        } else if (patMode == 2) {
            shouldPlay = noteTrigPlaying_;
        }
        child.syncTransportFromParent(
            ctx.transport.bpm,
            ctx.transport.ticksPerLine,
            doBpmSync,
            shouldPlay
        );

        if (macroDirty_) {
            applyMacros(childAsset_);
            macroDirty_ = false;
        }

        const(float[])[2] emptyIn = [null, null];
        const(float[])[2] passIn = (ctx.inputSilent || io.audioIn[0].length < ctx.frames)
            ? emptyIn
            : io.audioIn;
        child.processDirectSubFrames(io.audioOut, passIn, ctx.frames);

        float peak = 0.0f;
        const outL = io.audioOut[0];
        const outR = io.audioOut[1];
        foreach (i; 0 .. ctx.frames) {
            immutable float al = outL[i] < 0.0f ? -outL[i] : outL[i];
            immutable float ar = outR[i] < 0.0f ? -outR[i] : outR[i];
            if (al > peak) peak = al;
            if (ar > peak) peak = ar;
        }
        return peak > 1e-7f;
    }

    /**
     * Atomically swaps the embedded MetaModuleAsset* on slot 0 and returns oldAsset for off-RT retirement.
     *
     * Params:
     *   slot = Asset slot index (must be 0).
     *   newAsset = Unmanaged MetaModuleAsset* pointer prepared off-RT.
     *   oldAsset = Receives previous MetaModuleAsset* pointer.
     *
     * Returns:
     *   True if slot == 0.
     */
    bool swapAsset(uint slot, void* newAsset, out void* oldAsset) {
        oldAsset = null;
        if (slot != 0) {
            return false;
        }
        oldAsset = childAsset_;
        childAsset_ = cast(MetaModuleAsset*) newAsset;
        macroDirty_ = true;
        return true;
    }

    private ModuleId resolvedInputModuleId() const pure @safe {
        if (!isFinite(inputModule)) {
            return ModuleId.invalid;
        }
        int v = cast(int)(inputModule + 0.5f);
        return v >= 1 ? ModuleId(cast(uint) v) : ModuleId.invalid;
    }

    private void applyMacros(MetaModuleAsset* asset) {
        immutable float[8] vals = [macro1, macro2, macro3, macro4, macro5, macro6, macro7, macro8];
        foreach (idx, ref m; asset.macros) {
            if (!m.enabled || !m.targetMod.isValid()) {
                continue;
            }
            float norm = isFinite(vals[idx]) ? vals[idx] : 0.5f;
            if (norm < 0.0f) norm = 0.0f;
            if (norm > 1.0f) norm = 1.0f;
            immutable float domainVal = m.minVal + norm * (m.maxVal - m.minVal);
            asset.childEngine.setModuleParamDirect(m.targetMod, m.paramIdx, domainVal, true);
        }
    }
}

static assert(!hasGcReference!MetaModule,
    "MetaModule must contain zero D GC indirections");
