/**
 * File:         source/graph/registry.d
 * Module:       graph.registry
 * Phase:        Phase 2.2 / 4 — Complete Static ModuleRegistry
 *
 * Purpose:
 *   Provides a single-line registration table binding all 38 built-in core, Tier 1, and Tier 2 synth, effect, and control modules via ModuleAdapter!T for runtime lookup and dynamic GUI add-module menus.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow lookup via immutable ModuleDescriptor[] table; zero global mutable state.
 *
 * Dependencies:
 *   Internal: foundation.types, graph.module_api, modules.*
 *   External: std.meta (AliasSeq)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ModuleRegistry : descriptors(), findByTypeId(string typeId), createOffRT(...)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.registry;

import std.meta : AliasSeq;

import foundation.types : FIXED_BLOCK_FRAMES, ModuleId;
import graph.module_api : ModuleAdapter, ModuleDescriptor, ModuleInstance;
import modules.control.adsr_mod : AdsrMod;
import modules.control.ctl2note : Ctl2Note;
import modules.control.feedback : Feedback;
import modules.control.glide : Glide;
import modules.control.metamodule : MetaModule;
import modules.control.multictl : MultiCtl;
import modules.control.multisynth : MultiSynth;
import modules.control.pitch2ctl : Pitch2Ctl;
import modules.control.pitch_detector : PitchDetector;
import modules.control.sound2ctl : Sound2Ctl;
import modules.control.velocity2ctl : Velocity2Ctl;
import modules.effects.amplifier : Amplifier;
import modules.effects.compressor : Compressor;
import modules.effects.dc_blocker : DcBlocker;
import modules.effects.delay : Delay;
import modules.effects.distortion : Distortion;
import modules.effects.echo : Echo;
import modules.effects.eq : Eq3Band;
import modules.effects.fft_fx : FftFx;
import modules.effects.filter_pro : FilterPro;
import modules.effects.flanger : Flanger;
import modules.effects.lfo : LfoMod;
import modules.effects.loop_fx : LoopFx;
import modules.effects.modulator : Modulator;
import modules.effects.pitch_shifter : PitchShifter;
import modules.effects.reverb : Reverb;
import modules.effects.smooth_fx : SmoothFx;
import modules.effects.vibrato : Vibrato;
import modules.effects.vocal_filter : VocalFilter;
import modules.effects.waveshaper : WaveShaper;
import modules.output : MasterOutput;
import modules.synths.analog_gen : AnalogGen;
import modules.synths.drumsynth : DrumSynth;
import modules.synths.fm_synth : FmSynth;
import modules.synths.input : AudioInput;
import modules.synths.kicker : Kicker;
import modules.synths.sampler : Sampler;
import modules.synths.spectravoice : SpectraVoice;
import modules.synths.vorbis_player : VorbisPlayer;

private alias RegisteredModuleTypes = AliasSeq!(
    MasterOutput,
    Amplifier,
    DcBlocker,
    FilterPro,
    Distortion,
    Delay,
    Echo,
    Reverb,
    Compressor,
    MultiSynth,
    MultiCtl,
    AdsrMod,
    LfoMod,
    Feedback,
    Kicker,
    DrumSynth,
    AnalogGen,
    FmSynth,
    Sampler,
    Eq3Band,
    WaveShaper,
    Flanger,
    Vibrato,
    Modulator,
    SmoothFx,
    VocalFilter,
    PitchShifter,
    FftFx,
    LoopFx,
    Glide,
    Ctl2Note,
    Pitch2Ctl,
    Velocity2Ctl,
    Sound2Ctl,
    PitchDetector,
    SpectraVoice,
    AudioInput,
    VorbisPlayer,
    MetaModule
);

private ModuleDescriptor[RegisteredModuleTypes.length] buildRegisteredDescriptors() {
    ModuleDescriptor[RegisteredModuleTypes.length] descs;
    static foreach (i, ModT; RegisteredModuleTypes) {
        descs[i] = ModuleAdapter!ModT.DESCRIPTOR;
    }
    return descs;
}

/**
 * Global read-only static registry of all built-in studio module descriptors and constructors.
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
