/**
 * File:         source/graph/plan.d
 * Module:       graph.plan
 * Phase:        Phase 2.3 — Off-RT GraphCompiler, Topological Sort & Feedback Splitting
 *
 * Purpose:
 *   Compiles patchbay wiring off the audio thread into a flat topologically ordered @nogc GraphPlan, validating port kinds and converting FeedbackSend->FeedbackReceive edges into fixed-delay buffers.
 *
 * Real-Time & Safety Contract:
 *   Compiled off-RT into @nogc OwnedBuffer and posix_memalign storage with zero GC indirections so superseded plans retire safely from the RT thread.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, foundation.concurrency, graph.buffer, graph.port, graph.module_api
 *   External: core.lifetime (emplace, move), core.stdc.stdlib (free, malloc), core.sys.posix.stdlib (posix_memalign), std.traits (hasIndirections)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct NodeSpec / struct WireSpec
 *   - enum GraphCompileError / enum StepKind
 *   - struct CompiledStep / struct AudioWireBinding / struct CvWireBinding / struct EventWireBinding / struct NodeBinding
 *   - struct GraphPlan : destroyOffRT(), destroyErased(), audioBusChannel(), cvBusSlice(), findNode(), nodeCount()
 *   - struct GraphCompiler : static bool compile(const(NodeSpec)[] nodes, const(WireSpec)[] wires, out GraphPlan* plan, out GraphCompileError err)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.plan;

import core.lifetime : emplace, move;
import core.stdc.stdlib : free, malloc;
version (Posix) import core.sys.posix.stdlib : posix_memalign;
import std.traits : hasIndirections;

import foundation.concurrency : hasGcReference;
import foundation.memory : OwnedBuffer;
import foundation.types : DEFAULT_SIMD_ALIGNMENT, FIXED_BLOCK_FRAMES, ModuleId;
import graph.buffer : MAX_CV_PORTS;
import graph.module_api : ModuleDescriptor, ModuleInstance, ModuleVTable;
import graph.port : PortDescriptor, PortDirection, PortKind, arePortsCompatible, isAudioPort;

/**
 * Off-RT node specification supplied to GraphCompiler.compile().
 */
struct NodeSpec {
    ModuleId id = ModuleId.invalid;
    const(ModuleDescriptor)* desc = null;
    void* state = null;
    bool muted = false;
    bool bypassed = false;

    /**
     * Constructs a NodeSpec directly from an instantiated ModuleInstance.
     *
     * Params:
     *   inst = Owning ModuleInstance descriptor and state handle.
     *   muted = Initial mute flag.
     *   bypassed = Initial bypass flag.
     *
     * Returns:
     *   Populated NodeSpec.
     */
    static NodeSpec fromInstance(
        ref ModuleInstance inst,
        bool muted = false,
        bool bypassed = false
    ) @nogc nothrow pure @safe {
        return NodeSpec(inst.id, inst.desc, inst.state, muted, bypassed);
    }
}

/**
 * Directed connection between an output port on srcMod and an input port on dstMod.
 */
struct WireSpec {
    ModuleId srcMod = ModuleId.invalid;
    ushort srcPort = 0;
    ModuleId dstMod = ModuleId.invalid;
    ushort dstPort = 0;
    float gain = 1.0f;
}

/**
 * Diagnostic error codes returned when GraphCompiler.compile() rejects an invalid graph.
 */
enum GraphCompileError : ubyte {
    none = 0,
    invalidNode = 1,
    duplicateNodeId = 2,
    invalidPort = 3,
    invalidDirection = 4,
    incompatiblePorts = 5,
    cycleDetected = 6,
    outOfMemory = 7
}

/**
 * Execution step variant in a compiled flat GraphPlan.
 */
enum StepKind : ubyte {
    normal = 0,
    feedbackReceive = 1,
    feedbackSend = 2
}

/**
 * Single compiled topological execution step inside a GraphPlan.
 */
struct CompiledStep {
    uint nodeIndex = 0;
    StepKind kind = StepKind.normal;
    uint audioOutBus = uint.max;
    uint audioInWireStart = 0;
    uint audioInWireCount = 0;
    uint sidechainInWireStart = 0;
    uint sidechainInWireCount = 0;
    uint cvInWireStart = 0;
    uint cvInWireCount = 0;
    uint cvOutBusStart = uint.max;
    uint cvOutBusCount = 0;
    uint eventOutWireStart = 0;
    uint eventOutWireCount = 0;
    bool muted = false;
    bool bypassed = false;
    bool isOutput = false;
    bool hasAudioIn = false;
    bool hasAudioOut = false;
    bool hasSidechainIn = false;
    uint numCvIn = 0;
    uint numCvOut = 0;
}

/**
 * Pre-bound audio or sidechain wire sourcing samples from srcBus into a consumer node.
 */
struct AudioWireBinding {
    uint srcBus = 0;
    float gain = 1.0f;
    bool srcIsMono = false;
}

/**
 * Pre-bound CV control wire routing srcCvBus into dstCvSlot on a consumer node.
 */
struct CvWireBinding {
    uint srcCvBus = 0;
    uint dstCvSlot = 0;
    float gain = 1.0f;
}

/**
 * Pre-bound event wire targeting dstNodeIndex on dstPort.
 */
struct EventWireBinding {
    uint dstNodeIndex = 0;
    ushort dstPort = 0;
}

/**
 * Runtime binding mapping a node index inside GraphPlan to its ModuleVTable and state.
 */
struct NodeBinding {
    ModuleId id = ModuleId.invalid;
    const(ModuleVTable)* vtable = null;
    void* state = null;
}

static assert(!hasIndirections!CompiledStep);
static assert(!hasIndirections!AudioWireBinding);
static assert(!hasIndirections!CvWireBinding);
static assert(!hasIndirections!EventWireBinding);

/**
 * Immutable @nogc compiled execution plan executed on the real-time audio thread.
 *
 * Allocated off-RT via posix_memalign and retired back through RetireSink/RetireRing so
 * zero GC pointers ever enter RT audio structs.
 */
struct GraphPlan {
    OwnedBuffer!CompiledStep steps;
    OwnedBuffer!AudioWireBinding audioInWires;
    OwnedBuffer!AudioWireBinding sidechainInWires;
    OwnedBuffer!CvWireBinding cvInWires;
    OwnedBuffer!EventWireBinding eventOutWires;

    OwnedBuffer!float audioBusStorage;
    OwnedBuffer!ubyte audioBusSilent;
    OwnedBuffer!float cvBusStorage;
    OwnedBuffer!ubyte cvBusSilent;
    OwnedBuffer!float scratchStorage;

    uint numAudioBuses = 0;
    uint numCvBuses = 0;
    uint outputNodeIndex = uint.max;
    uint outputAudioBus = uint.max;

    private NodeBinding* nodeBindings_ = null;
    private size_t nodeCount_ = 0;

    @disable this(this);

    @nogc nothrow:

    /**
     * Releases all owned buffers and node binding arrays.
     */
    ~this() {
        if (nodeBindings_ !is null) {
            free(nodeBindings_);
            nodeBindings_ = null;
            nodeCount_ = 0;
        }
        steps.reset();
        audioInWires.reset();
        sidechainInWires.reset();
        cvInWires.reset();
        eventOutWires.reset();
        audioBusStorage.reset();
        audioBusSilent.reset();
        cvBusStorage.reset();
        cvBusSilent.reset();
        scratchStorage.reset();
    }

    /**
     * Destroys and frees a GraphPlan* allocated by GraphCompiler.compile().
     *
     * Params:
     *   plan = Heap pointer to destroy (no-op if null).
     */
    static void destroyOffRT(GraphPlan* plan) {
        if (plan is null) {
            return;
        }
        destroy!false(*plan);
        free(plan);
    }

    /**
     * Type-erased destructor callback suitable for RetiredResource reclamation off-RT.
     *
     * Params:
     *   raw = Opaque GraphPlan* pointer.
     */
    static void destroyErased(void* raw) {
        destroyOffRT(cast(GraphPlan*) raw);
    }

    /**
     * Returns the number of module nodes bound in this plan.
     *
     * Returns:
     *   Node count.
     */
    size_t nodeCount() const pure @safe {
        return nodeCount_;
    }

    /**
     * Returns a pointer to the NodeBinding at nodeIdx.
     *
     * Params:
     *   nodeIdx = Zero-based node index (< nodeCount()).
     *
     * Returns:
     *   Pointer to NodeBinding.
     */
    NodeBinding* nodeAt(size_t nodeIdx) pure {
        assert(nodeIdx < nodeCount_, "GraphPlan.nodeAt index out of bounds");
        return &nodeBindings_[nodeIdx];
    }

    /**
     * Looks up a NodeBinding by ModuleId via linear scan.
     *
     * Params:
     *   id = ModuleId to find.
     *
     * Returns:
     *   Pointer to matching NodeBinding, or null if absent.
     */
    NodeBinding* findNode(ModuleId id) pure {
        if (!id.isValid()) {
            return null;
        }
        foreach (i; 0 .. nodeCount_) {
            if (nodeBindings_[i].id == id) {
                return &nodeBindings_[i];
            }
        }
        return null;
    }

    /**
     * Returns the 64-frame audio bus channel slice for busIdx and stereo channel ch.
     *
     * Params:
     *   busIdx = Zero-based audio bus index (< numAudioBuses).
     *   ch = Stereo channel index (0 or 1).
     *
     * Returns:
     *   Slice of length FIXED_BLOCK_FRAMES.
     */
    float[] audioBusChannel(uint busIdx, uint ch) pure {
        assert(busIdx < numAudioBuses && ch < 2, "GraphPlan.audioBusChannel out of bounds");
        immutable size_t base = (cast(size_t) busIdx * 2 + cast(size_t) ch) * FIXED_BLOCK_FRAMES;
        return audioBusStorage[base .. base + FIXED_BLOCK_FRAMES];
    }

    /**
     * Returns the 64-frame CV bus slice for cvBusIdx.
     *
     * Params:
     *   cvBusIdx = Zero-based CV bus index (< numCvBuses).
     *
     * Returns:
     *   Slice of length FIXED_BLOCK_FRAMES.
     */
    float[] cvBusSlice(uint cvBusIdx) pure {
        assert(cvBusIdx < numCvBuses, "GraphPlan.cvBusSlice out of bounds");
        immutable size_t base = cast(size_t) cvBusIdx * FIXED_BLOCK_FRAMES;
        return cvBusStorage[base .. base + FIXED_BLOCK_FRAMES];
    }

    /**
     * Returns one of the 8 internal per-slice scratch buffers of length FIXED_BLOCK_FRAMES.
     *
     * Slots 0..1 hold main audio input mix, 2..3 hold sidechain input mix, and 4..7 hold CV input mixes.
     *
     * Params:
     *   slot = Scratch buffer slot index in [0 .. 4 + MAX_CV_PORTS).
     *
     * Returns:
     *   Slice of length FIXED_BLOCK_FRAMES.
     */
    float[] scratchChannel(size_t slot) pure {
        assert(slot < 4 + MAX_CV_PORTS, "GraphPlan.scratchChannel out of bounds");
        immutable size_t base = slot * FIXED_BLOCK_FRAMES;
        return scratchStorage[base .. base + FIXED_BLOCK_FRAMES];
    }
}

static assert(!hasGcReference!GraphPlan);

private struct VertexMeta {
    uint nodeIndex = 0;
    StepKind kind = StepKind.normal;
    uint audioOutBus = uint.max;
    uint cvOutBusStart = uint.max;
    uint cvOutBusCount = 0;
    bool hasAudioIn = false;
    bool hasAudioOut = false;
    bool hasSidechainIn = false;
    uint numCvIn = 0;
    uint numCvOut = 0;
    bool muted = false;
    bool bypassed = false;
    bool isOutput = false;
    AudioWireBinding[] audioIn;
    AudioWireBinding[] sidechainIn;
    CvWireBinding[] cvIn;
    EventWireBinding[] eventOut;
    uint[] outEdges;
    uint inDegree = 0;
}

/**
 * Off-RT compiler transforming modular NodeSpec/WireSpec graphs into @nogc GraphPlans.
 */
struct GraphCompiler {
    /**
     * Validates ports, splits Feedback cycles, topologically sorts nodes, and packs a GraphPlan.
     *
     * Params:
     *   nodes = Array of instantiated NodeSpecs in the graph.
     *   wires = Array of directed WireSpecs connecting output ports to input ports.
     *   plan = Output @nogc GraphPlan pointer allocated on success (destroyed via GraphPlan.destroyOffRT).
     *   err = Diagnostic error code describing why compilation failed.
     *
     * Returns:
     *   True if compilation succeeded; false on validation error, cycle, or OOM.
     */
    static bool compile(
        const(NodeSpec)[] nodes,
        const(WireSpec)[] wires,
        out GraphPlan* plan,
        out GraphCompileError err
    ) {
        plan = null;
        err = GraphCompileError.none;

        foreach (i, ref n; nodes) {
            if (!n.id.isValid() || n.desc is null || n.desc.vtable is null || n.state is null) {
                err = GraphCompileError.invalidNode;
                return false;
            }
            foreach (j; i + 1 .. nodes.length) {
                if (nodes[j].id == n.id) {
                    err = GraphCompileError.duplicateNodeId;
                    return false;
                }
            }
        }

        auto normalOrRecvVertex = new uint[nodes.length];
        auto feedbackSendVertex = new uint[nodes.length];
        feedbackSendVertex[] = uint.max;
        auto nodeAudioOutBus = new uint[nodes.length];
        nodeAudioOutBus[] = uint.max;
        auto nodeAudioOutMono = new bool[nodes.length];
        auto nodeCvOutStart = new uint[nodes.length];
        nodeCvOutStart[] = uint.max;

        VertexMeta[] vertices;
        uint audioBusCount = 0;
        uint cvBusCount = 0;
        uint outputNodeIdx = uint.max;
        uint outputAudioBus = uint.max;

        foreach (ni, ref n; nodes) {
            auto ports = n.desc.ports;
            bool hasAudioIn = false;
            bool hasAudioOut = false;
            bool outIsMono = false;
            bool hasSidechainIn = false;
            uint numCvIn = 0;
            uint numCvOut = 0;

            foreach (ref p; ports) {
                if (p.dir == PortDirection.input) {
                    if (p.kind == PortKind.audioStereo || p.kind == PortKind.audioMono) {
                        hasAudioIn = true;
                    } else if (p.kind == PortKind.sidechainStereo) {
                        hasSidechainIn = true;
                    } else if (p.kind == PortKind.cvControl && numCvIn < MAX_CV_PORTS) {
                        numCvIn++;
                    }
                } else {
                    if (p.kind == PortKind.audioStereo || p.kind == PortKind.audioMono) {
                        if (!hasAudioOut) {
                            hasAudioOut = true;
                            outIsMono = (p.kind == PortKind.audioMono);
                        }
                    } else if (p.kind == PortKind.cvControl && numCvOut < MAX_CV_PORTS) {
                        numCvOut++;
                    }
                }
            }

            uint aBus = uint.max;
            if (hasAudioOut) {
                aBus = audioBusCount++;
                nodeAudioOutBus[ni] = aBus;
                nodeAudioOutMono[ni] = outIsMono;
            }

            uint cStart = uint.max;
            if (numCvOut > 0) {
                cStart = cvBusCount;
                cvBusCount += numCvOut;
                nodeCvOutStart[ni] = cStart;
            }

            if (n.desc.isOutput && outputNodeIdx == uint.max) {
                outputNodeIdx = cast(uint) ni;
                outputAudioBus = aBus;
            }

            if (n.desc.isFeedback) {
                immutable uint recvV = cast(uint) vertices.length;
                normalOrRecvVertex[ni] = recvV;
                VertexMeta recvMeta;
                recvMeta.nodeIndex = cast(uint) ni;
                recvMeta.kind = StepKind.feedbackReceive;
                recvMeta.audioOutBus = aBus;
                recvMeta.hasAudioOut = hasAudioOut;
                recvMeta.muted = n.muted;
                recvMeta.bypassed = n.bypassed;
                vertices ~= recvMeta;

                immutable uint sendV = cast(uint) vertices.length;
                feedbackSendVertex[ni] = sendV;
                VertexMeta sendMeta;
                sendMeta.nodeIndex = cast(uint) ni;
                sendMeta.kind = StepKind.feedbackSend;
                sendMeta.hasAudioIn = hasAudioIn;
                sendMeta.muted = n.muted;
                sendMeta.bypassed = n.bypassed;
                vertices ~= sendMeta;
            } else {
                immutable uint v = cast(uint) vertices.length;
                normalOrRecvVertex[ni] = v;
                VertexMeta meta;
                meta.nodeIndex = cast(uint) ni;
                meta.kind = StepKind.normal;
                meta.audioOutBus = aBus;
                meta.cvOutBusStart = cStart;
                meta.cvOutBusCount = numCvOut;
                meta.hasAudioIn = hasAudioIn;
                meta.hasAudioOut = hasAudioOut;
                meta.hasSidechainIn = hasSidechainIn;
                meta.numCvIn = numCvIn;
                meta.numCvOut = numCvOut;
                meta.muted = n.muted;
                meta.bypassed = n.bypassed;
                meta.isOutput = n.desc.isOutput;
                vertices ~= meta;
            }
        }

        foreach (ref w; wires) {
            size_t srcNodeIdx = size_t.max;
            size_t dstNodeIdx = size_t.max;
            foreach (ni, ref n; nodes) {
                if (n.id == w.srcMod) srcNodeIdx = ni;
                if (n.id == w.dstMod) dstNodeIdx = ni;
            }
            if (srcNodeIdx == size_t.max || dstNodeIdx == size_t.max) {
                err = GraphCompileError.invalidNode;
                return false;
            }

            auto srcPorts = nodes[srcNodeIdx].desc.ports;
            auto dstPorts = nodes[dstNodeIdx].desc.ports;
            if (w.srcPort >= srcPorts.length || w.dstPort >= dstPorts.length) {
                err = GraphCompileError.invalidPort;
                return false;
            }

            immutable auto srcPortDesc = srcPorts[w.srcPort];
            immutable auto dstPortDesc = dstPorts[w.dstPort];
            if (srcPortDesc.dir != PortDirection.output || dstPortDesc.dir != PortDirection.input) {
                err = GraphCompileError.invalidDirection;
                return false;
            }
            if (!arePortsCompatible(srcPortDesc.kind, dstPortDesc.kind)) {
                err = GraphCompileError.incompatiblePorts;
                return false;
            }

            immutable uint uVertex = normalOrRecvVertex[srcNodeIdx];
            immutable uint vVertex = nodes[dstNodeIdx].desc.isFeedback
                ? feedbackSendVertex[dstNodeIdx]
                : normalOrRecvVertex[dstNodeIdx];

            if (uVertex == vVertex) {
                err = GraphCompileError.cycleDetected;
                return false;
            }

            vertices[uVertex].outEdges ~= vVertex;
            vertices[vVertex].inDegree++;

            if (dstPortDesc.kind == PortKind.audioStereo || dstPortDesc.kind == PortKind.audioMono) {
                immutable uint bus = nodeAudioOutBus[srcNodeIdx];
                if (bus == uint.max) {
                    err = GraphCompileError.invalidPort;
                    return false;
                }
                vertices[vVertex].audioIn ~= AudioWireBinding(bus, w.gain, nodeAudioOutMono[srcNodeIdx]);
            } else if (dstPortDesc.kind == PortKind.sidechainStereo) {
                immutable uint bus = nodeAudioOutBus[srcNodeIdx];
                if (bus == uint.max) {
                    err = GraphCompileError.invalidPort;
                    return false;
                }
                vertices[vVertex].sidechainIn ~= AudioWireBinding(bus, w.gain, nodeAudioOutMono[srcNodeIdx]);
            } else if (dstPortDesc.kind == PortKind.cvControl) {
                immutable uint srcSlot = countPriorPortsOfKind(srcPorts, w.srcPort, PortDirection.output, PortKind.cvControl);
                immutable uint dstSlot = countPriorPortsOfKind(dstPorts, w.dstPort, PortDirection.input, PortKind.cvControl);
                if (srcSlot >= MAX_CV_PORTS || dstSlot >= MAX_CV_PORTS || nodeCvOutStart[srcNodeIdx] == uint.max) {
                    err = GraphCompileError.invalidPort;
                    return false;
                }
                vertices[vVertex].cvIn ~= CvWireBinding(nodeCvOutStart[srcNodeIdx] + srcSlot, dstSlot, w.gain);
            } else if (dstPortDesc.kind == PortKind.event) {
                vertices[uVertex].eventOut ~= EventWireBinding(cast(uint) dstNodeIdx, w.dstPort);
            }
        }

        uint[] topoOrder;
        topoOrder.reserve(vertices.length);
        auto queue = new uint[vertices.length];
        size_t qHead = 0;
        size_t qTail = 0;
        foreach (vi, ref vm; vertices) {
            if (vm.inDegree == 0) {
                queue[qTail++] = cast(uint) vi;
            }
        }
        while (qHead < qTail) {
            immutable uint u = queue[qHead++];
            topoOrder ~= u;
            foreach (v; vertices[u].outEdges) {
                vertices[v].inDegree--;
                if (vertices[v].inDegree == 0) {
                    queue[qTail++] = v;
                }
            }
        }
        if (topoOrder.length != vertices.length) {
            err = GraphCompileError.cycleDetected;
            return false;
        }

        size_t totalAudioInWires = 0;
        size_t totalSidechainInWires = 0;
        size_t totalCvInWires = 0;
        size_t totalEventOutWires = 0;
        foreach (vi; topoOrder) {
            totalAudioInWires += vertices[vi].audioIn.length;
            totalSidechainInWires += vertices[vi].sidechainIn.length;
            totalCvInWires += vertices[vi].cvIn.length;
            totalEventOutWires += vertices[vi].eventOut.length;
        }

        void* rawPlanMem = null;
        enum size_t planAlign = GraphPlan.alignof > DEFAULT_SIMD_ALIGNMENT
            ? GraphPlan.alignof : DEFAULT_SIMD_ALIGNMENT;
        version (Posix) {
            if (posix_memalign(&rawPlanMem, planAlign, GraphPlan.sizeof) != 0 || rawPlanMem is null) {
                err = GraphCompileError.outOfMemory;
                return false;
            }
        } else {
            rawPlanMem = malloc(GraphPlan.sizeof);
            if (rawPlanMem is null) {
                err = GraphCompileError.outOfMemory;
                return false;
            }
        }

        GraphPlan* compiled = cast(GraphPlan*) rawPlanMem;
        emplace(compiled);

        bool cleanupOnFailure = true;
        scope (exit) {
            if (cleanupOnFailure) {
                GraphPlan.destroyOffRT(compiled);
            }
        }

        if (nodes.length > 0) {
            void* bindingsMem = null;
            enum size_t bindAlign = NodeBinding.alignof > DEFAULT_SIMD_ALIGNMENT
                ? NodeBinding.alignof : DEFAULT_SIMD_ALIGNMENT;
            immutable size_t bindBytes = nodes.length * NodeBinding.sizeof;
            version (Posix) {
                if (posix_memalign(&bindingsMem, bindAlign, bindBytes) != 0 || bindingsMem is null) {
                    err = GraphCompileError.outOfMemory;
                    return false;
                }
            } else {
                bindingsMem = malloc(bindBytes);
                if (bindingsMem is null) {
                    err = GraphCompileError.outOfMemory;
                    return false;
                }
            }
            compiled.nodeBindings_ = cast(NodeBinding*) bindingsMem;
            compiled.nodeCount_ = nodes.length;
            foreach (ni, ref n; nodes) {
                compiled.nodeBindings_[ni] = NodeBinding(n.id, n.desc.vtable, cast(void*) n.state);
            }
        }

        if (!OwnedBuffer!CompiledStep.tryAllocate(topoOrder.length, compiled.steps)
                || !OwnedBuffer!AudioWireBinding.tryAllocate(totalAudioInWires, compiled.audioInWires)
                || !OwnedBuffer!AudioWireBinding.tryAllocate(totalSidechainInWires, compiled.sidechainInWires)
                || !OwnedBuffer!CvWireBinding.tryAllocate(totalCvInWires, compiled.cvInWires)
                || !OwnedBuffer!EventWireBinding.tryAllocate(totalEventOutWires, compiled.eventOutWires)
                || !OwnedBuffer!float.tryAllocate(cast(size_t) audioBusCount * 2 * FIXED_BLOCK_FRAMES, compiled.audioBusStorage)
                || !OwnedBuffer!ubyte.tryAllocate(audioBusCount, compiled.audioBusSilent)
                || !OwnedBuffer!float.tryAllocate(cast(size_t) cvBusCount * FIXED_BLOCK_FRAMES, compiled.cvBusStorage)
                || !OwnedBuffer!ubyte.tryAllocate(cvBusCount, compiled.cvBusSilent)
                || !OwnedBuffer!float.tryAllocate((4 + MAX_CV_PORTS) * FIXED_BLOCK_FRAMES, compiled.scratchStorage)) {
            err = GraphCompileError.outOfMemory;
            return false;
        }

        if (audioBusCount > 0) {
            auto aSil = compiled.audioBusSilent[];
            aSil[] = 1;
        }
        if (cvBusCount > 0) {
            auto cSil = compiled.cvBusSilent[];
            cSil[] = 1;
        }
        compiled.numAudioBuses = audioBusCount;
        compiled.numCvBuses = cvBusCount;
        compiled.outputNodeIndex = outputNodeIdx;
        compiled.outputAudioBus = outputAudioBus;

        uint aWireCursor = 0;
        uint scWireCursor = 0;
        uint cvWireCursor = 0;
        uint evWireCursor = 0;

        foreach (stepIdx, vi; topoOrder) {
            auto vm = &vertices[vi];
            CompiledStep step;
            step.nodeIndex = vm.nodeIndex;
            step.kind = vm.kind;
            step.audioOutBus = vm.audioOutBus;
            step.cvOutBusStart = vm.cvOutBusStart;
            step.cvOutBusCount = vm.cvOutBusCount;
            step.muted = vm.muted;
            step.bypassed = vm.bypassed;
            step.isOutput = vm.isOutput;
            step.hasAudioIn = vm.hasAudioIn;
            step.hasAudioOut = vm.hasAudioOut;
            step.hasSidechainIn = vm.hasSidechainIn;
            step.numCvIn = vm.numCvIn;
            step.numCvOut = vm.numCvOut;

            step.audioInWireStart = aWireCursor;
            step.audioInWireCount = cast(uint) vm.audioIn.length;
            foreach (ref aw; vm.audioIn) {
                compiled.audioInWires[aWireCursor++] = aw;
            }

            step.sidechainInWireStart = scWireCursor;
            step.sidechainInWireCount = cast(uint) vm.sidechainIn.length;
            foreach (ref scw; vm.sidechainIn) {
                compiled.sidechainInWires[scWireCursor++] = scw;
            }

            step.cvInWireStart = cvWireCursor;
            step.cvInWireCount = cast(uint) vm.cvIn.length;
            foreach (ref cvw; vm.cvIn) {
                compiled.cvInWires[cvWireCursor++] = cvw;
            }

            step.eventOutWireStart = evWireCursor;
            step.eventOutWireCount = cast(uint) vm.eventOut.length;
            foreach (ref evw; vm.eventOut) {
                compiled.eventOutWires[evWireCursor++] = evw;
            }

            compiled.steps[stepIdx] = step;
        }

        cleanupOnFailure = false;
        plan = compiled;
        return true;
    }

    private static uint countPriorPortsOfKind(
        immutable(PortDescriptor)[] ports,
        ushort targetPort,
        PortDirection dir,
        PortKind kind
    ) pure @safe {
        uint count = 0;
        foreach (i; 0 .. targetPort) {
            if (ports[i].dir == dir && ports[i].kind == kind) {
                count++;
            }
        }
        return count;
    }
}
