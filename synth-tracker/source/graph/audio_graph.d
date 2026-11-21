/**
 * File:         source/graph/audio_graph.d
 * Module:       graph.audio_graph
 * Phase:        Phase 2.4 — Fixed-Quantum RT AudioGraph Executor
 *
 * Purpose:
 *   Executes compiled GraphPlans in fixed FIXED_BLOCK_FRAMES = 64 internal slices with host-buffer chunking, sample-accurate event sub-blocking, silence skip, SwapGraphPlan, SwapModuleAsset, and TripleBuffer telemetry.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; unregistered-thread safe; zero allocations, zero locks, and zero GC indirections on the render path.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, foundation.concurrency, foundation.math_rt, graph.context, graph.event, graph.buffer, graph.module_api, graph.plan
 *   External: core.lifetime (move), std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum RetiredKind / struct RetiredResource / struct RetireSink
 *   - struct GraphTelemetry
 *   - struct AudioGraph : tryInit(), reset(), swapPlan(), swapModuleAsset(), setModuleParam(), enqueueEvent(), render(), readTelemetry(), detachPlan(), renderedFrames()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.audio_graph;

import core.lifetime : move;
import std.math : fabs, isFinite;

import foundation.concurrency : TripleBuffer;
import foundation.math_rt : ScopedNoDenormals;
import foundation.memory : FixedArray;
import foundation.types : FIXED_BLOCK_FRAMES, FrameTime, ModuleId;
import graph.buffer : CvInView, CvOutView, MAX_CV_PORTS, ProcessIO;
import graph.context : EventSink, ProcessContext, TransportState;
import graph.event : EventArena, ModEvent, ModEventKind, sortEventsByFrameOffset;
import graph.plan : AudioWireBinding, CompiledStep, CvWireBinding, EventWireBinding, GraphPlan,
    NodeBinding, StepKind;

enum size_t MAX_TELEMETRY_MODULES = 64;
enum size_t MAX_SLICE_EVENTS = 128;

/**
 * Resource category tag for deferred off-RT destruction via RetireRing.
 */
enum RetiredKind : ubyte {
    graphPlan = 0,
    moduleState = 1,
    moduleAsset = 2
}

/**
 * Type-erased RT resource handle queued to RetireRing for deterministic off-RT cleanup.
 */
struct RetiredResource {
    RetiredKind kind = RetiredKind.graphPlan;
    void* ptr = null;
    void function(void*) @nogc nothrow destroyFn = null;

    /**
     * Runs the resource destructor on an off-RT thread and clears internal pointers.
     */
    void reclaimOffRT() @nogc nothrow {
        if (ptr !is null && destroyFn !is null) {
            destroyFn(ptr);
        }
        ptr = null;
        destroyFn = null;
    }
}

/**
 * Non-allocating sink callback forwarding displaced RT objects onto an SpscRing!RetiredResource.
 */
struct RetireSink {
    bool function(void* ctx, RetiredResource res) @nogc nothrow pushFn = null;
    void* ctx = null;

    /**
     * Enqueues a retired resource for off-RT reclamation.
     *
     * Params:
     *   res = Retired resource handle to reclaim.
     *
     * Returns:
     *   True if the sink accepted the resource; false if sink is unbound or full.
     */
    bool push(RetiredResource res) @nogc nothrow {
        if (pushFn !is null) {
            return pushFn(ctx, res);
        }
        return false;
    }
}

/**
 * Lock-free telemetry snapshot published per 64-frame quantum over TripleBuffer.
 */
struct GraphTelemetry {
    float[MAX_TELEMETRY_MODULES] modulePeaks = 0.0f;
    uint[MAX_TELEMETRY_MODULES] moduleIds = uint.max;
    uint moduleCount = 0;
    float masterPeakL = 0.0f;
    float masterPeakR = 0.0f;
    bool masterClipped = false;
    float[FIXED_BLOCK_FRAMES] scopeLeft = 0.0f;
    float[FIXED_BLOCK_FRAMES] scopeRight = 0.0f;
    ulong totalFramesRendered = 0;
    ulong slicesRendered = 0;
    uint activeNodeCount = 0;
    uint skippedSilentNodeCount = 0;
}

private struct EventRouterContext {
    EventArena* emitted = null;
    GraphPlan* plan = null;
    const(EventWireBinding)[] wires;
    FrameTime subStartFrame = 0;
    uint subSliceFrames = 0;
}

/**
 * Fixed-quantum (64-frame) real-time modular audio graph executor.
 *
 * Buffers arbitrary host callback block sizes cleanly into deterministic 64-frame slices,
 * executes sample-accurate event sub-blocking, skips silent nodes, and swaps GraphPlans
 * and module assets without locks or allocations.
 */
struct AudioGraph {
    private EventArena scheduledEvents_;
    private EventArena emittedEvents_;
    private FixedArray!(ModEvent, MAX_SLICE_EVENTS) nodeEvents_;
    private float[FIXED_BLOCK_FRAMES][2] stageOut_ = 0.0f;
    private uint stageOutRead_ = FIXED_BLOCK_FRAMES;
    private uint stageOutAvail_ = 0;
    private TripleBuffer!GraphTelemetry telemetry_;
    private GraphPlan* activePlan_ = null;
    private float sampleRate_ = 44100.0f;
    private FrameTime renderedFrames_ = 0;
    private ulong sliceCounter_ = 0;

    @disable this(this);

    @nogc nothrow:

    /**
     * Pre-allocates internal event arenas off-RT for sampleRate.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz (> 0.0f).
     *   maxScheduledEvents = Capacity of scheduled and routed event arenas.
     *
     * Returns:
     *   True on success; false on invalid parameters or OOM.
     */
    bool tryInit(float sampleRate, size_t maxScheduledEvents = 1024) {
        if (!isFinite(sampleRate) || sampleRate < 1.0f || maxScheduledEvents < 16) {
            return false;
        }
        EventArena sched;
        if (!EventArena.tryCreate(maxScheduledEvents, sched)) {
            return false;
        }
        EventArena emit;
        if (!EventArena.tryCreate(maxScheduledEvents, emit)) {
            return false;
        }
        scheduledEvents_ = move(sched);
        emittedEvents_ = move(emit);
        sampleRate_ = sampleRate;
        stageOutRead_ = FIXED_BLOCK_FRAMES;
        stageOutAvail_ = 0;
        renderedFrames_ = 0;
        sliceCounter_ = 0;
        return true;
    }

    /**
     * Resets staged output frames, queued events, render counters, and active module states.
     */
    void reset() {
        scheduledEvents_.clear();
        emittedEvents_.clear();
        stageOut_[0][] = 0.0f;
        stageOut_[1][] = 0.0f;
        stageOutRead_ = FIXED_BLOCK_FRAMES;
        stageOutAvail_ = 0;
        renderedFrames_ = 0;
        sliceCounter_ = 0;
        if (activePlan_ !is null) {
            foreach (i; 0 .. activePlan_.nodeCount()) {
                auto nb = activePlan_.nodeAt(i);
                if (nb.vtable !is null && nb.vtable.reset !is null && nb.state !is null) {
                    nb.vtable.reset(nb.state);
                }
            }
            if (activePlan_.numAudioBuses > 0) {
                auto aSil = activePlan_.audioBusSilent[];
                aSil[] = 1;
            }
            if (activePlan_.numCvBuses > 0) {
                auto cSil = activePlan_.cvBusSilent[];
                cSil[] = 1;
            }
        }
    }

    /**
     * Atomically replaces the active GraphPlan on the RT thread and retires the previous plan.
     *
     * Params:
     *   newPlan = Compiled @nogc GraphPlan prepared off-RT (may be null to clear graph).
     *   retire = Optional RetireSink receiving the displaced GraphPlan* for off-RT cleanup.
     */
    void swapPlan(GraphPlan* newPlan, RetireSink retire = RetireSink.init) {
        GraphPlan* oldPlan = activePlan_;
        activePlan_ = newPlan;
        if (oldPlan !is null) {
            RetiredResource res = RetiredResource(
                RetiredKind.graphPlan,
                oldPlan,
                &GraphPlan.destroyErased
            );
            retire.push(res);
        }
    }

    /**
     * Detaches and returns the active GraphPlan* for manual off-RT destruction during shutdown.
     *
     * Returns:
     *   Previously active GraphPlan*, or null if none.
     */
    GraphPlan* detachPlan() pure @safe {
        GraphPlan* old = activePlan_;
        activePlan_ = null;
        return old;
    }

    /**
     * Swaps a module's heavy @nogc asset pointer via ModuleVTable.swapAsset and retires the old asset.
     *
     * Params:
     *   id = Target ModuleId in the active GraphPlan.
     *   slot = Module-specific asset slot index.
     *   newAsset = Pre-allocated @nogc asset pointer prepared off-RT.
     *   assetDestroyFn = Off-RT destructor function invoked on the replaced asset pointer.
     *   retire = RetireSink receiving the displaced asset pointer.
     *
     * Returns:
     *   True if the module was found and swapAsset succeeded.
     */
    bool swapModuleAsset(
        ModuleId id,
        uint slot,
        void* newAsset,
        void function(void*) @nogc nothrow assetDestroyFn,
        RetireSink retire
    ) {
        if (activePlan_ is null) {
            return false;
        }
        NodeBinding* nb = activePlan_.findNode(id);
        if (nb is null || nb.vtable is null || nb.vtable.swapAsset is null || nb.state is null) {
            return false;
        }
        void* oldAsset = null;
        if (!nb.vtable.swapAsset(nb.state, slot, newAsset, oldAsset)) {
            return false;
        }
        if (oldAsset !is null) {
            RetiredResource res = RetiredResource(RetiredKind.moduleAsset, oldAsset, assetDestroyFn);
            retire.push(res);
        }
        return true;
    }

    /**
     * Applies a scalar parameter change immediately on the active plan's matching module.
     *
     * Params:
     *   id = Target ModuleId.
     *   paramIdx = Zero-based parameter index.
     *   value = New parameter value.
     *   instant = When true, snaps parameter smoothers immediately without ramping.
     *
     * Returns:
     *   True if the module and parameter index were valid and updated.
     */
    bool setModuleParam(ModuleId id, uint paramIdx, float value, bool instant = false) {
        if (activePlan_ is null) {
            return false;
        }
        NodeBinding* nb = activePlan_.findNode(id);
        if (nb is null || nb.vtable is null || nb.vtable.setParam is null || nb.state is null) {
            return false;
        }
        return nb.vtable.setParam(nb.state, paramIdx, value, sampleRate_, instant);
    }

    private bool enqueueEventImpl(ModuleId targetMod, scope const ref ModEvent ev, FrameTime targetFrame) {
        return scheduledEvents_.tryPush(targetMod, targetFrame, ev);
    }

    /**
     * Schedules a sample-accurate ModEvent targeting targetMod at absolute graph frame targetFrame.
     *
     * Params:
     *   targetMod = Destination module identifier.
     *   ev = Event payload.
     *   targetFrame = Absolute sample frame inside the graph timeline.
     *
     * Returns:
     *   True if enqueued; false if the event arena is full.
     */
    bool enqueueEvent(ModuleId targetMod, scope const ref ModEvent ev, FrameTime targetFrame) {
        return enqueueEventImpl(targetMod, ev, targetFrame);
    }

    /**
     * Schedules an rvalue sample-accurate ModEvent targeting targetMod at absolute graph frame targetFrame.
     *
     * Params:
     *   targetMod = Destination module identifier.
     *   ev = Event payload value.
     *   targetFrame = Absolute sample frame inside the graph timeline.
     *
     * Returns:
     *   True if enqueued; false if the event arena is full.
     */
    bool enqueueEvent(ModuleId targetMod, ModEvent ev, FrameTime targetFrame) {
        return enqueueEventImpl(targetMod, ev, targetFrame);
    }

    /**
     * Renders hostFrames stereo output frames by stepping internal fixed 64-frame slices.
     *
     * Params:
     *   outputs = Host stereo output buffers (each >= hostFrames).
     *   inputs = Optional host stereo input buffers (currently reserved for hardware duplex input).
     *   hostFrames = Number of stereo frames requested by the audio host or offline loop.
     *   transport = Mutable transport state (totalFrames advances on rendered internal slices).
     */
    void render(
        float[][2] outputs,
        const(float[])[2] inputs,
        uint hostFrames,
        ref TransportState transport
    ) {
        cast(void) inputs;
        auto denormGuard = ScopedNoDenormals.enter();
        cast(void) denormGuard;

        if (hostFrames == 0) {
            return;
        }
        assert(outputs[0].length >= hostFrames && outputs[1].length >= hostFrames,
            "AudioGraph.render output slices smaller than hostFrames");

        uint hostPos = 0;
        while (hostPos < hostFrames) {
            if (stageOutRead_ < stageOutAvail_) {
                immutable uint avail = stageOutAvail_ - stageOutRead_;
                immutable uint rem = hostFrames - hostPos;
                immutable uint copyCount = avail < rem ? avail : rem;
                outputs[0][hostPos .. hostPos + copyCount] =
                    stageOut_[0][stageOutRead_ .. stageOutRead_ + copyCount];
                outputs[1][hostPos .. hostPos + copyCount] =
                    stageOut_[1][stageOutRead_ .. stageOutRead_ + copyCount];
                stageOutRead_ += copyCount;
                hostPos += copyCount;
                continue;
            }

            renderFixedQuantum(transport);
            stageOutRead_ = 0;
            stageOutAvail_ = FIXED_BLOCK_FRAMES;
        }
    }

    /**
     * Reads the latest lock-free telemetry snapshot if published since the prior read.
     *
     * Params:
     *   outTel = Destination GraphTelemetry struct populated on return.
     *
     * Returns:
     *   True if a newer snapshot was acquired; false otherwise.
     */
    bool readTelemetry(out GraphTelemetry outTel) {
        return telemetry_.read(outTel);
    }

    /**
     * Returns the total number of internal frames processed by fixed 64-frame quanta so far.
     *
     * Returns:
     *   Rendered internal frame count.
     */
    FrameTime renderedFrames() const pure @safe {
        return renderedFrames_;
    }

    private static void routeEmittedEvent(void* rawCtx, scope const ref ModEvent ev) {
        auto rctx = cast(EventRouterContext*) rawCtx;
        if (rctx is null || rctx.emitted is null || rctx.plan is null || rctx.subSliceFrames == 0) {
            return;
        }
        immutable uint relOffset = ev.frameOffset < rctx.subSliceFrames
            ? ev.frameOffset : (rctx.subSliceFrames - 1);
        immutable FrameTime absFrame = rctx.subStartFrame + relOffset;
        foreach (ref wire; rctx.wires) {
            if (wire.dstNodeIndex < rctx.plan.nodeCount()) {
                immutable ModuleId dstId = rctx.plan.nodeAt(wire.dstNodeIndex).id;
                ModEvent routed = ev;
                routed.frameOffset = 0;
                rctx.emitted.tryPush(dstId, absFrame, routed);
            }
        }
    }

    private void renderFixedQuantum(ref TransportState transport) {
        immutable FrameTime quantumStart = renderedFrames_;
        immutable FrameTime quantumEnd = quantumStart + FIXED_BLOCK_FRAMES;

        stageOut_[0][] = 0.0f;
        stageOut_[1][] = 0.0f;
        emittedEvents_.clear();

        GraphTelemetry* tel = &telemetry_.backBuffer();
        *tel = GraphTelemetry.init;

        if (activePlan_ is null || activePlan_.steps.length == 0) {
            scheduledEvents_.pruneBefore(quantumEnd);
            renderedFrames_ = quantumEnd;
            sliceCounter_++;
            transport.totalFrames += FIXED_BLOCK_FRAMES;
            tel.totalFramesRendered = renderedFrames_;
            tel.slicesRendered = sliceCounter_;
            telemetry_.publish();
            return;
        }

        GraphPlan* plan = activePlan_;
        scheduledEvents_.sortByFrame();

        uint[FIXED_BLOCK_FRAMES + 1] splitPoints = 0;
        size_t splitCount = 0;
        splitPoints[splitCount++] = 0;
        foreach (ref se; scheduledEvents_.slice()) {
            if (se.targetFrame > quantumStart && se.targetFrame < quantumEnd) {
                immutable uint rel = cast(uint)(se.targetFrame - quantumStart);
                if (rel != splitPoints[splitCount - 1]) {
                    splitPoints[splitCount++] = rel;
                }
            }
        }
        splitPoints[splitCount++] = FIXED_BLOCK_FRAMES;

        float[MAX_TELEMETRY_MODULES] nodePeakAccum = 0.0f;
        bool[MAX_TELEMETRY_MODULES] nodeAnyActive = false;

        foreach (segIdx; 0 .. splitCount - 1) {
            immutable uint subStart = splitPoints[segIdx];
            immutable uint subEnd = splitPoints[segIdx + 1];
            if (subEnd > subStart) {
                executeSubSlice(
                    plan,
                    quantumStart,
                    subStart,
                    subEnd,
                    transport,
                    nodePeakAccum[],
                    nodeAnyActive[]
                );
            }
        }

        float masterL = 0.0f;
        float masterR = 0.0f;
        bool clipped = false;
        foreach (i; 0 .. FIXED_BLOCK_FRAMES) {
            immutable float l = stageOut_[0][i];
            immutable float r = stageOut_[1][i];
            tel.scopeLeft[i] = l;
            tel.scopeRight[i] = r;
            immutable float al = fabs(l);
            immutable float ar = fabs(r);
            if (al > masterL) masterL = al;
            if (ar > masterR) masterR = ar;
            if (al >= 0.999f || ar >= 0.999f) {
                clipped = true;
            }
        }

        immutable size_t modTelCount = plan.nodeCount() < MAX_TELEMETRY_MODULES
            ? plan.nodeCount() : MAX_TELEMETRY_MODULES;
        tel.moduleCount = cast(uint) modTelCount;
        uint activeCount = 0;
        uint skippedCount = 0;
        foreach (ni; 0 .. modTelCount) {
            tel.moduleIds[ni] = plan.nodeAt(ni).id.value;
            tel.modulePeaks[ni] = nodePeakAccum[ni];
            if (nodeAnyActive[ni]) {
                activeCount++;
            } else {
                skippedCount++;
            }
        }
        tel.activeNodeCount = activeCount;
        tel.skippedSilentNodeCount = skippedCount;
        tel.masterPeakL = masterL;
        tel.masterPeakR = masterR;
        tel.masterClipped = clipped;

        scheduledEvents_.pruneBefore(quantumEnd);
        emittedEvents_.clear();

        renderedFrames_ = quantumEnd;
        sliceCounter_++;
        transport.totalFrames += FIXED_BLOCK_FRAMES;
        tel.totalFramesRendered = renderedFrames_;
        tel.slicesRendered = sliceCounter_;
        telemetry_.publish();
    }

    private void executeSubSlice(
        GraphPlan* plan,
        FrameTime quantumStart,
        uint subStart,
        uint subEnd,
        ref const TransportState transport,
        float[] nodePeakAccum,
        bool[] nodeAnyActive
    ) {
        immutable uint subFrames = subEnd - subStart;
        immutable FrameTime subStartFrame = quantumStart + subStart;
        immutable FrameTime subEndFrame = quantumStart + subEnd;

        foreach (ref step; plan.steps[]) {
            NodeBinding* nb = plan.nodeAt(step.nodeIndex);
            if (nb.vtable is null || nb.state is null) {
                continue;
            }

            ProcessIO io;
            immutable bool mainSilent = gatherAudioInputs(
                plan,
                plan.audioInWires[step.audioInWireStart .. step.audioInWireStart + step.audioInWireCount],
                0,
                subStart,
                subFrames,
                io.audioIn
            );

            if (step.kind == StepKind.feedbackSend) {
                ProcessContext fbCtx;
                fbCtx.sampleRate = sampleRate_;
                fbCtx.frames = subFrames;
                fbCtx.sliceOffset = subStart;
                fbCtx.transport = transport;
                fbCtx.transport.totalFrames = subStartFrame;
                fbCtx.inputSilent = step.muted ? true : mainSilent;
                if (nb.vtable.processFeedbackSend !is null) {
                    nb.vtable.processFeedbackSend(nb.state, io.audioIn, fbCtx);
                }
                continue;
            }

            if (step.hasAudioOut && step.audioOutBus < plan.numAudioBuses) {
                io.audioOut[0] = plan.audioBusChannel(step.audioOutBus, 0)[subStart .. subEnd];
                io.audioOut[1] = plan.audioBusChannel(step.audioOutBus, 1)[subStart .. subEnd];
            }

            bool scSilent = true;
            if (step.hasSidechainIn) {
                scSilent = gatherAudioInputs(
                    plan,
                    plan.sidechainInWires[step.sidechainInWireStart .. step.sidechainInWireStart + step.sidechainInWireCount],
                    2,
                    subStart,
                    subFrames,
                    io.sidechainIn
                );
                io.sidechainConnected = step.sidechainInWireCount > 0;
                io.sidechainSilent = scSilent;
            }

            io.numCvIn = step.numCvIn;
            if (step.numCvIn > 0) {
                gatherCvInputs(
                    plan,
                    plan.cvInWires[step.cvInWireStart .. step.cvInWireStart + step.cvInWireCount],
                    step.numCvIn,
                    subStart,
                    subFrames,
                    io.cvIn
                );
            }

            io.numCvOut = step.numCvOut;
            foreach (k; 0 .. step.numCvOut) {
                if (k >= MAX_CV_PORTS || step.cvOutBusStart == uint.max) {
                    break;
                }
                immutable uint busId = step.cvOutBusStart + k;
                if (busId < plan.numCvBuses) {
                    io.cvOut[k] = CvOutView(plan.cvBusSlice(busId)[subStart .. subEnd], true);
                }
            }

            if (step.kind != StepKind.feedbackReceive) {
                collectNodeEvents(nb.id, subStartFrame, subEndFrame);
            } else {
                nodeEvents_.clear();
            }

            if (step.muted) {
                zeroNodeOutputs(plan, step, io, subFrames);
                continue;
            }

            if (step.bypassed && step.hasAudioOut && step.audioOutBus < plan.numAudioBuses) {
                dispatchSubSliceEvents(nb, nodeEvents_[]);
                if (mainSilent) {
                    io.audioOut[0][] = 0.0f;
                    io.audioOut[1][] = 0.0f;
                    plan.audioBusSilent[step.audioOutBus] = 1;
                } else {
                    io.audioOut[0][] = io.audioIn[0][];
                    io.audioOut[1][] = io.audioIn[1][];
                    plan.audioBusSilent[step.audioOutBus] = 0;
                    if (step.nodeIndex < nodeAnyActive.length) {
                        nodeAnyActive[step.nodeIndex] = true;
                        updatePeak(io.audioOut[0], io.audioOut[1], nodePeakAccum[step.nodeIndex]);
                    }
                }
                continue;
            }

            EventRouterContext routerCtx = EventRouterContext(
                &emittedEvents_,
                plan,
                plan.eventOutWires[step.eventOutWireStart .. step.eventOutWireStart + step.eventOutWireCount],
                subStartFrame,
                subFrames
            );

            ProcessContext ctx;
            ctx.sampleRate = sampleRate_;
            ctx.frames = subFrames;
            ctx.sliceOffset = subStart;
            ctx.transport = transport;
            ctx.transport.totalFrames = subStartFrame;
            ctx.inputSilent = mainSilent;
            if (step.eventOutWireCount > 0) {
                ctx.eventOut = EventSink(&routeEmittedEvent, &routerCtx);
            }

            bool produced = false;
            if (hasMidSliceEvents(nodeEvents_[], subFrames)) {
                produced = executeNodeEventSubBlocks(nb, nodeEvents_[], io, ctx, subFrames);
            } else {
                dispatchSubSliceEvents(nb, nodeEvents_[]);
                if (nb.vtable.process !is null) {
                    produced = nb.vtable.process(nb.state, io, ctx);
                }
            }

            if (step.hasAudioOut && step.audioOutBus < plan.numAudioBuses) {
                if (produced) {
                    plan.audioBusSilent[step.audioOutBus] = 0;
                    if (step.nodeIndex < nodeAnyActive.length) {
                        nodeAnyActive[step.nodeIndex] = true;
                        updatePeak(io.audioOut[0], io.audioOut[1], nodePeakAccum[step.nodeIndex]);
                    }
                } else {
                    io.audioOut[0][] = 0.0f;
                    io.audioOut[1][] = 0.0f;
                    plan.audioBusSilent[step.audioOutBus] = 1;
                }
            }

            foreach (k; 0 .. step.numCvOut) {
                if (k >= MAX_CV_PORTS || step.cvOutBusStart == uint.max) {
                    break;
                }
                immutable uint busId = step.cvOutBusStart + k;
                if (busId < plan.numCvBuses) {
                    bool cvActive = produced && !isSliceSilent(io.cvOut[k].samples);
                    if (cvActive) {
                        plan.cvBusSilent[busId] = 0;
                    } else {
                        io.cvOut[k].samples[] = 0.0f;
                        plan.cvBusSilent[busId] = 1;
                    }
                }
            }
        }

        if (plan.outputAudioBus != uint.max && plan.outputAudioBus < plan.numAudioBuses) {
            if (plan.audioBusSilent[plan.outputAudioBus] == 0) {
                const outL = plan.audioBusChannel(plan.outputAudioBus, 0)[subStart .. subEnd];
                const outR = plan.audioBusChannel(plan.outputAudioBus, 1)[subStart .. subEnd];
                stageOut_[0][subStart .. subEnd] = outL[];
                stageOut_[1][subStart .. subEnd] = outR[];
            }
        }
    }

    private void collectNodeEvents(ModuleId modId, FrameTime windowStart, FrameTime windowEnd) {
        nodeEvents_.clear();
        ModEvent[MAX_SLICE_EVENTS] buf;
        size_t total = scheduledEvents_.collectForModuleInWindow(modId, windowStart, windowEnd, buf[]);
        if (total < MAX_SLICE_EVENTS && !emittedEvents_.empty()) {
            total += emittedEvents_.collectForModuleInWindow(modId, windowStart, windowEnd, buf[total .. $]);
        }
        if (total > 1) {
            sortEventsByFrameOffset(buf[0 .. total]);
        }
        foreach (i; 0 .. total) {
            nodeEvents_.tryPush(buf[i]);
        }
    }

    private static bool hasMidSliceEvents(const(ModEvent)[] events, uint subFrames) pure @safe {
        foreach (ref ev; events) {
            if (ev.frameOffset > 0 && ev.frameOffset < subFrames) {
                return true;
            }
        }
        return false;
    }

    private bool executeNodeEventSubBlocks(
        NodeBinding* nb,
        const(ModEvent)[] events,
        ref ProcessIO fullIo,
        ref ProcessContext fullCtx,
        uint subFrames
    ) {
        bool anyProduced = false;
        uint cursor = 0;
        size_t evIdx = 0;

        while (cursor < subFrames) {
            while (evIdx < events.length && events[evIdx].frameOffset <= cursor) {
                dispatchSingleEvent(nb, events[evIdx]);
                evIdx++;
            }
            uint nextSplit = subFrames;
            if (evIdx < events.length && events[evIdx].frameOffset < subFrames) {
                nextSplit = events[evIdx].frameOffset;
            }
            if (nextSplit <= cursor) {
                nextSplit = cursor + 1;
            }

            ProcessIO localIo = fullIo.subSlice(cursor, nextSplit);
            ProcessContext localCtx = fullCtx;
            localCtx.frames = nextSplit - cursor;
            localCtx.sliceOffset = fullCtx.sliceOffset + cursor;
            localCtx.transport.totalFrames = fullCtx.transport.totalFrames + cursor;
            if (nb.vtable.process !is null && nb.vtable.process(nb.state, localIo, localCtx)) {
                anyProduced = true;
            } else {
                if (localIo.audioOut[0].length > 0) {
                    localIo.audioOut[0][] = 0.0f;
                }
                if (localIo.audioOut[1].length > 0) {
                    localIo.audioOut[1][] = 0.0f;
                }
            }
            cursor = nextSplit;
        }
        return anyProduced;
    }

    private void dispatchSubSliceEvents(NodeBinding* nb, const(ModEvent)[] events) {
        foreach (ref ev; events) {
            dispatchSingleEvent(nb, ev);
        }
    }

    private void dispatchSingleEvent(NodeBinding* nb, scope const ref ModEvent ev) {
        if (nb.vtable is null || nb.state is null) {
            return;
        }
        if (ev.kind == ModEventKind.setParam || ev.kind == ModEventKind.setParamInstant) {
            immutable bool instant = (ev.kind == ModEventKind.setParamInstant);
            if (nb.vtable.setParam !is null
                    && nb.vtable.setParam(nb.state, ev.paramId, ev.valueA, sampleRate_, instant)) {
                return;
            }
        }
        if (nb.vtable.handleEvent !is null) {
            nb.vtable.handleEvent(nb.state, ev, sampleRate_);
        }
    }

    private static bool gatherAudioInputs(
        GraphPlan* plan,
        const(AudioWireBinding)[] wires,
        size_t scratchBaseSlot,
        uint subStart,
        uint subFrames,
        out const(float)[][2] outChannels
    ) {
        auto dstL = plan.scratchChannel(scratchBaseSlot)[0 .. subFrames];
        auto dstR = plan.scratchChannel(scratchBaseSlot + 1)[0 .. subFrames];
        dstL[] = 0.0f;
        dstR[] = 0.0f;
        outChannels[0] = dstL;
        outChannels[1] = dstR;

        if (wires.length == 0) {
            return true;
        }

        bool anyActive = false;
        foreach (ref w; wires) {
            if (w.srcBus >= plan.numAudioBuses || plan.audioBusSilent[w.srcBus] != 0) {
                continue;
            }
            anyActive = true;
            const srcL = plan.audioBusChannel(w.srcBus, 0)[subStart .. subStart + subFrames];
            const srcR = plan.audioBusChannel(w.srcBus, 1)[subStart .. subStart + subFrames];
            immutable float gain = w.gain;
            if (w.srcIsMono) {
                foreach (i; 0 .. subFrames) {
                    immutable float s = srcL[i] * gain;
                    dstL[i] += s;
                    dstR[i] += s;
                }
            } else {
                foreach (i; 0 .. subFrames) {
                    dstL[i] += srcL[i] * gain;
                    dstR[i] += srcR[i] * gain;
                }
            }
        }
        return !anyActive;
    }

    private static void gatherCvInputs(
        GraphPlan* plan,
        const(CvWireBinding)[] wires,
        uint numCvIn,
        uint subStart,
        uint subFrames,
        ref CvInView[MAX_CV_PORTS] cvInViews
    ) {
        bool[MAX_CV_PORTS] hasWire = false;
        bool[MAX_CV_PORTS] activeWire = false;
        foreach (slot; 0 .. numCvIn) {
            if (slot >= MAX_CV_PORTS) {
                break;
            }
            auto buf = plan.scratchChannel(4 + slot)[0 .. subFrames];
            buf[] = 0.0f;
            cvInViews[slot] = CvInView(buf, false, true);
        }

        foreach (ref w; wires) {
            if (w.dstCvSlot >= numCvIn || w.dstCvSlot >= MAX_CV_PORTS) {
                continue;
            }
            hasWire[w.dstCvSlot] = true;
            if (w.srcCvBus >= plan.numCvBuses || plan.cvBusSilent[w.srcCvBus] != 0) {
                continue;
            }
            activeWire[w.dstCvSlot] = true;
            const src = plan.cvBusSlice(w.srcCvBus)[subStart .. subStart + subFrames];
            auto dst = plan.scratchChannel(4 + w.dstCvSlot)[0 .. subFrames];
            immutable float gain = w.gain;
            foreach (i; 0 .. subFrames) {
                dst[i] += src[i] * gain;
            }
        }

        foreach (slot; 0 .. numCvIn) {
            if (slot >= MAX_CV_PORTS) {
                break;
            }
            cvInViews[slot].connected = hasWire[slot];
            cvInViews[slot].silent = !activeWire[slot];
        }
    }

    private static void zeroNodeOutputs(
        GraphPlan* plan,
        scope const ref CompiledStep step,
        ref ProcessIO io,
        uint subFrames
    ) {
        if (step.hasAudioOut && step.audioOutBus < plan.numAudioBuses) {
            io.audioOut[0][0 .. subFrames] = 0.0f;
            io.audioOut[1][0 .. subFrames] = 0.0f;
            plan.audioBusSilent[step.audioOutBus] = 1;
        }
        foreach (k; 0 .. step.numCvOut) {
            if (k >= MAX_CV_PORTS || step.cvOutBusStart == uint.max) {
                break;
            }
            immutable uint busId = step.cvOutBusStart + k;
            if (busId < plan.numCvBuses) {
                io.cvOut[k].samples[0 .. subFrames] = 0.0f;
                plan.cvBusSilent[busId] = 1;
            }
        }
    }

    private static void updatePeak(const(float)[] l, const(float)[] r, ref float peak) pure @safe {
        foreach (i; 0 .. l.length) {
            immutable float al = fabs(l[i]);
            immutable float ar = fabs(r[i]);
            if (al > peak) peak = al;
            if (ar > peak) peak = ar;
        }
    }

    private static bool isSliceSilent(const(float)[] slice) pure @safe {
        foreach (s; slice) {
            if (fabs(s) > 1e-7f) {
                return false;
            }
        }
        return true;
    }
}
