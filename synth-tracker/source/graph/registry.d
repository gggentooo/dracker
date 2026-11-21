/**
 * File:         source/graph/registry.d
 * Module:       graph.registry
 * Phase:        Phase 2.2 — Static ModuleRegistry
 *
 * Purpose:
 *   Provides a single-line registration table binding all built-in synth, effect, and control modules via ModuleAdapter!T for runtime lookup and dynamic GUI add-module menus.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow lookup via immutable ModuleDescriptor[] table; zero global mutable state.
 *
 * Dependencies:
 *   Internal: foundation.types, graph.module_api, modules.*
 *   External: std.meta (AliasSeq)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ModuleRegistry : descriptors(), findByTypeId(string typeId), createOffRT(string typeId, ModuleId id, float sampleRate, uint maxSliceFrames, out ModuleInstance instance)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.registry;

import std.meta : AliasSeq;

import foundation.types : FIXED_BLOCK_FRAMES, ModuleId;
import graph.module_api : ModuleAdapter, ModuleDescriptor, ModuleInstance;
import modules.control.feedback : Feedback;
import modules.effects.amplifier : Amplifier;
import modules.effects.dc_blocker : DcBlocker;
import modules.output : MasterOutput;

private alias RegisteredModuleTypes = AliasSeq!(
    MasterOutput,
    Amplifier,
    DcBlocker,
    Feedback
);

private ModuleDescriptor[RegisteredModuleTypes.length] buildRegisteredDescriptors() {
    ModuleDescriptor[RegisteredModuleTypes.length] descs;
    static foreach (i, ModT; RegisteredModuleTypes) {
        descs[i] = ModuleAdapter!ModT.DESCRIPTOR;
    }
    return descs;
}

/**
 * Global read-only static registry of built-in studio module descriptors and constructors.
 */
struct ModuleRegistry {
    static immutable ModuleDescriptor[RegisteredModuleTypes.length] REGISTERED =
        buildRegisteredDescriptors();

    @nogc nothrow:

    /**
     * Returns all registered module descriptors in static registration order.
     *
     * Returns:
     *   Immutable slice of built-in ModuleDescriptors.
     */
    static immutable(ModuleDescriptor)[] descriptors() pure {
        return REGISTERED[];
    }

    /**
     * Looks up a registered ModuleDescriptor by its canonical string typeId.
     *
     * Params:
     *   typeId = Canonical module type identifier (such as "fx.dc_blocker").
     *
     * Returns:
     *   Pointer to matching immutable ModuleDescriptor, or null if unknown.
     */
    static immutable(ModuleDescriptor)* findByTypeId(string typeId) pure {
        foreach (i; 0 .. REGISTERED.length) {
            if (REGISTERED[i].typeId == typeId) {
                return &REGISTERED[i];
            }
        }
        return null;
    }

    /**
     * Instantiates and prepares a registered module off-RT as a ModuleInstance.
     *
     * Params:
     *   typeId = Registered module type identifier.
     *   id = ModuleId assigned to the new instance.
     *   sampleRate = Initial sample rate in Hertz.
     *   maxSliceFrames = Maximum internal processing quantum (defaults to FIXED_BLOCK_FRAMES).
     *   instance = Destination ModuleInstance initialized on success.
     *
     * Returns:
     *   True if typeId was found and allocation succeeded; false otherwise.
     */
    static bool createOffRT(
        string typeId,
        ModuleId id,
        float sampleRate,
        uint maxSliceFrames,
        out ModuleInstance instance
    ) {
        instance = ModuleInstance.init;
        const(ModuleDescriptor)* desc = findByTypeId(typeId);
        if (desc is null || desc.vtable is null || desc.vtable.create is null) {
            return false;
        }
        void* state = desc.vtable.create();
        if (state is null) {
            return false;
        }
        if (desc.vtable.prepare !is null) {
            desc.vtable.prepare(state, sampleRate, maxSliceFrames);
        }
        instance.id = id;
        instance.desc = desc;
        instance.state = state;
        return true;
    }

    /**
     * Convenience overload instantiating a module with FIXED_BLOCK_FRAMES slice size.
     *
     * Params:
     *   typeId = Registered module type identifier.
     *   id = ModuleId assigned to the new instance.
     *   sampleRate = Initial sample rate in Hertz.
     *   instance = Destination ModuleInstance initialized on success.
     *
     * Returns:
     *   True if instantiation and preparation succeeded; false otherwise.
     */
    static bool createOffRT(string typeId, ModuleId id, float sampleRate, out ModuleInstance instance) {
        return createOffRT(typeId, id, sampleRate, FIXED_BLOCK_FRAMES, instance);
    }
}
