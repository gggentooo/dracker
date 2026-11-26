/**
 * File:         source/modules/synths/vorbis_player.d
 * Module:       modules.synths.vorbis_player
 * Phase:        Phase 4.9 (Tier 2) — Background-Streamed Ogg Vorbis Player
 *
 * Purpose:
 *   Streams long-form Ogg Vorbis/WAV/FLAC/MP3 audio tracks seamlessly on the RT thread by popping pre-decoded PCM frames from a non-owning StreamAudioRing and applying transpose/rate conversion via StereoResampler.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; ZERO disk syscalls, ZERO codec decoding, and ZERO heap allocations on the audio thread.
 *
 * Dependencies:
 *   Internal: dsp.resampler, dsp.smoother, foundation.memory, graph.context, graph.event, graph.module_api, graph.port, sequencer.stream_worker
 *   External: std.math (exp2, fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct VorbisPlayer (typeId = "synth.vorbis_player", ports: event in, audioStereo out)
 *   - @Param volume, transposeSemitones, loopEnable
 *   - Hooks: onParamChanged, handleEvent, process, swapAsset
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.synths.vorbis_player;

import std.math : exp2, fabs, isFinite;

import dsp.resampler : ResampleCounts, ResampleQuality, StereoResampler;
import dsp.smoother : ParamSmoother;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;
import sequencer.stream_worker : StreamAudioRing;

/**
 * Lock-free background-streamed Ogg Vorbis / audio file player consuming StreamAudioRing blocks.
 */
struct VorbisPlayer {
    enum string typeId = "synth.vorbis_player";
    enum string displayName = "Vorbis Player";
    enum ModuleCategory category = ModuleCategory.synth;
    enum size_t SCRATCH_FRAMES = 256;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Events In", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Volume", 0.0f, 2.0f, 1.0f, "", ParamScale.linear)
    float volume = 1.0f;

    @Param("Transpose", -24.0f, 24.0f, 0.0f, "st", ParamScale.linear)
    float transposeSemitones = 0.0f;

    @Param("Loop", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete,
        ["Off", "On"])
    float loopEnable = 0.0f;

    private StreamAudioRing* ring_ = null;
    private StereoResampler resampler_;
    private ParamSmoother volSmoother_;
    private float[SCRATCH_FRAMES] scratchL_ = 0.0f;
    private float[SCRATCH_FRAMES] scratchR_ = 0.0f;
    private size_t scratchRead_ = 0;
    private size_t scratchLen_ = 0;
    private float sampleRate_ = 44_100.0f;
    private bool hasPlayedOnce_ = false;

    @nogc nothrow:

    /**
     * Configures resampler quality and initializes volume smoother cleanly.
     *
     * Params:
     *   sampleRate = Active graph sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        resampler_.setQuality(ResampleQuality.catmullRom);
        volSmoother_.prepare(sampleRate_, 5.0f, volume);
        reset();
    }

    /**
     * Flushes local resampler staging buffers and snaps volume smoother cleanly.
     */
    void reset() {
        resampler_.reset();
        scratchL_[] = 0.0f;
        scratchR_[] = 0.0f;
        scratchRead_ = 0;
        scratchLen_ = 0;
        hasPlayedOnce_ = false;
        volSmoother_.reset(volume);
    }

    /**
     * Updates smoothed output volume or propagates loop toggle cleanly to StreamAudioRing.
     *
     * Params:
     *   sampleRate = Active audio sample rate in Hertz.
     *   instant = True to snap smoother immediately.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "volume") {
            volSmoother_.setTarget(volume, instant);
        } else static if (field == "loopEnable") {
            if (ring_ !is null) {
                ring_.setLoopEnabled(loopEnable >= 0.5f);
            }
        }
    }

    /**
     * Dispatches play, seek-reset, and stop commands atomically to StreamAudioRing.
     *
     * Params:
     *   ev = Incoming ModEvent (NoteOn starts playback; NoteOff/AllNotesOff stops).
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        if (ring_ is null) {
            return;
        }
        ring_.setLoopEnabled(loopEnable >= 0.5f);
        if (ev.kind == ModEventKind.noteOn) {
            scratchRead_ = 0;
            scratchLen_ = 0;
            resampler_.reset();
            if (hasPlayedOnce_) {
                ring_.requestSeek(0);
            }
            hasPlayedOnce_ = true;
            ring_.requestPlay();
        } else if (ev.kind == ModEventKind.noteOff || ev.kind == ModEventKind.allNotesOff) {
            ring_.requestStop();
        }
    }

    /**
     * Consumes decoded stereo frames wait-free from StreamAudioRing and resamples cleanly.
     *
     * Params:
     *   audioIn = Unused stereo input slices.
     *   audioOut = Output stereo slices receiving streamed audio.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while playing or streaming non-silent frames; false when stopped or drained at EOF.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        cast(void) audioIn;
        if (ring_ is null || !ring_.isPlaying()) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) volSmoother_.next();
            }
            return false;
        }

        ring_.setLoopEnabled(loopEnable >= 0.5f);

        immutable double graphSr = cast(double)(ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_);
        immutable double srcSr = cast(double) ring_.sourceSampleRate();
        immutable double semis = isFinite(transposeSemitones) ? cast(double) transposeSemitones : 0.0;
        double ratio = (srcSr / (graphSr > 1.0 ? graphSr : 44_100.0)) * exp2(semis / 12.0);
        if (ratio < 0.05) ratio = 0.05;
        if (ratio > 16.0) ratio = 16.0;

        auto outL = audioOut[0];
        auto outR = audioOut[1];
        size_t outPos = 0;

        while (outPos < ctx.frames) {
            if (scratchRead_ >= scratchLen_) {
                scratchRead_ = 0;
                scratchLen_ = ring_.popStereo(scratchL_[], scratchR_[]);
            }
            const(float)[] inL = scratchRead_ < scratchLen_ ? scratchL_[scratchRead_ .. scratchLen_] : null;
            const(float)[] inR = scratchRead_ < scratchLen_ ? scratchR_[scratchRead_ .. scratchLen_] : null;
            immutable ResampleCounts counts = resampler_.processBlock(
                inL,
                inR,
                outL[outPos .. ctx.frames],
                outR[outPos .. ctx.frames],
                ratio
            );
            scratchRead_ += counts.consumed;
            outPos += counts.produced;

            if (counts.produced == 0 && scratchRead_ >= scratchLen_) {
                outL[outPos .. ctx.frames] = 0.0f;
                outR[outPos .. ctx.frames] = 0.0f;
                if (ring_.isEndOfStream() && ring_.bufferedFrames() == 0) {
                    ring_.requestStop();
                }
                break;
            }
        }

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            immutable float gain = volSmoother_.next();
            immutable float yL = outL[i] * gain;
            immutable float yR = outR[i] * gain;
            outL[i] = yL;
            outR[i] = yR;
            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;
        }

        return peak > 1e-7f || ring_.isPlaying();
    }

    /**
     * Attaches a non-owning StreamAudioRing* prepared by StreamWorker on slot 0 cleanly.
     *
     * Params:
     *   slot = Asset slot index (must be 0).
     *   newAsset = New StreamAudioRing* pointer managed externally by StreamWorker/session.
     *   oldAsset = Receives previous StreamAudioRing* pointer.
     *
     * Returns:
     *   True if slot == 0.
     */
    bool swapAsset(uint slot, void* newAsset, out void* oldAsset) {
        oldAsset = null;
        if (slot != 0) {
            return false;
        }
        oldAsset = ring_;
        ring_ = cast(StreamAudioRing*) newAsset;
        scratchRead_ = 0;
        scratchLen_ = 0;
        hasPlayedOnce_ = false;
        resampler_.reset();
        return true;
    }
}
