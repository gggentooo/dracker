/**
 * File:         source/modules/effects/loop_fx.d
 * Module:       modules.effects.loop_fx
 * Phase:        Phase 4.7 (Tier 2) — Tempo-Synced Stutter & Beat Repeater
 *
 * Purpose:
 *   Captures tempo-synchronized audio subdivisions and repeats them forward or ping-pong up to repeats cycles with click-free crossfaded boundaries.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process()/handleEvent(); OwnedBuffer!float capture ring pre-allocated in prepare().
 *
 * Dependencies:
 *   Internal: dsp.smoother, foundation.memory, graph.context, graph.event, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct LoopFx (typeId = "fx.loop", ports: audioStereo in/out, event in)
 *   - @Param repeats, lengthTicks, mode, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.loop_fx;

import std.math : fabs, isFinite;

import dsp.smoother : ParamSmoother;
import foundation.memory : OwnedBuffer;
import graph.context : ProcessContext;
import graph.event : ModEvent, ModEventKind;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Tempo-synced audio beat repeater supporting forward and ping-pong loop playback.
 */
struct LoopFx {
    enum string typeId = "fx.loop";
    enum string displayName = "Loop";
    enum ModuleCategory category = ModuleCategory.effect;
    enum size_t MAX_LOOP_FRAMES = 192_000;

    static immutable PortDescriptor[3] ports = [
        PortDescriptor("in", "Audio In", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("events", "Trigger In", PortKind.event, PortDirection.input),
        PortDescriptor("out", "Audio Out", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Repeats", 0.0f, 16.0f, 4.0f, "x", ParamScale.discrete)
    float repeats = 4.0f;

    @Param("Length", 1.0f, 32.0f, 4.0f, "ticks", ParamScale.discrete)
    float lengthTicks = 4.0f;

    @Param("Mode", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete,
        ["Forward", "Ping-Pong"])
    float mode = 0.0f;

    @Param("Mix", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float mix = 1.0f;

    private OwnedBuffer!float capL_;
    private OwnedBuffer!float capR_;
    private ParamSmoother mixSmoother_;
    private size_t writePos_ = 0;
    private size_t playPos_ = 0;
    private size_t loopLen_ = 1024;
    private uint remainingRepeats_ = 0;
    private bool capturing_ = false;
    private bool playingLoop_ = false;
    private bool forward_ = true;
    private float sampleRate_ = 44_100.0f;

    @nogc nothrow:

    /**
     * Pre-allocates up to 4 seconds of stereo capture buffers and primes mix smoother.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        if (capL_.empty()) {
            OwnedBuffer!float.tryAllocate(MAX_LOOP_FRAMES, capL_);
            OwnedBuffer!float.tryAllocate(MAX_LOOP_FRAMES, capR_);
        }
        mixSmoother_.prepare(sampleRate_, 5.0f, mix);
        reset();
    }

    /**
     * Clears captured loop audio and resets capture/playback cursors immediately.
     */
    void reset() {
        if (!capL_.empty()) capL_.opSlice()[] = 0.0f;
        if (!capR_.empty()) capR_.opSlice()[] = 0.0f;
        writePos_ = 0;
        playPos_ = 0;
        remainingRepeats_ = 0;
        capturing_ = false;
        playingLoop_ = false;
        forward_ = true;
        mixSmoother_.reset(mix);
    }

    /**
     * Updates wet/dry mix smoother cleanly.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap immediately.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "mix") {
            mixSmoother_.setTarget(mix, instant);
        }
    }

    /**
     * Triggers fresh loop slice capture on NoteOn or stops playback on NoteOff/AllNotesOff.
     *
     * Params:
     *   ev = Incoming ModEvent.
     *   sampleRate = Active sample rate in Hertz.
     */
    void handleEvent(const ref ModEvent ev, float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? sampleRate_ : sampleRate;
        if (ev.kind == ModEventKind.noteOn) {
            writePos_ = 0;
            playPos_ = 0;
            remainingRepeats_ = effectiveRepeats();
            capturing_ = remainingRepeats_ > 0;
            playingLoop_ = false;
            forward_ = true;
        } else if (ev.kind == ModEventKind.noteOff || ev.kind == ModEventKind.allNotesOff) {
            capturing_ = false;
            playingLoop_ = false;
            remainingRepeats_ = 0;
        }
    }

    /**
     * Captures and repeats incoming audio slices synced to transport BPM/TPL.
     *
     * Params:
     *   audioIn = Input stereo slices.
     *   audioOut = Output stereo slices.
     *   ctx = Per-slice execution context carrying transport tempo.
     *
     * Returns:
     *   True while input or active loop playback remains audible.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        if (capL_.empty() || capR_.empty() || (ctx.inputSilent && !playingLoop_ && !capturing_)) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) mixSmoother_.next();
            }
            return false;
        }

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        immutable double bpm = ctx.transport.bpm > 1.0 ? ctx.transport.bpm : 125.0;
        immutable uint tpl = ctx.transport.ticksPerLine > 0 ? ctx.transport.ticksPerLine : 6;
        immutable double ticksPerSec = (bpm * 4.0 / 60.0) * cast(double) tpl;
        immutable double ticksVal = isFinite(lengthTicks) ? (lengthTicks < 1.0f ? 1.0 : cast(double) lengthTicks) : 4.0;
        size_t targetLen = cast(size_t)((ticksVal / ticksPerSec) * cast(double) sr + 0.5);
        if (targetLen < 64) targetLen = 64;
        if (targetLen > capL_.length) targetLen = capL_.length;

        immutable bool pingPong = mode >= 0.5f;
        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            immutable float m = mixSmoother_.next();
            immutable float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            if (capturing_ && writePos_ == 0) {
                loopLen_ = targetLen;
            }
            if (!capturing_ && !playingLoop_ && effectiveRepeats() > 0
                    && (fabs(xL) > 1e-4f || fabs(xR) > 1e-4f)) {
                writePos_ = 0;
                playPos_ = 0;
                loopLen_ = targetLen;
                remainingRepeats_ = effectiveRepeats();
                capturing_ = true;
                forward_ = true;
            }

            float wetL = xL;
            float wetR = xR;
            if (capturing_) {
                if (writePos_ < loopLen_) {
                    capL_[writePos_] = xL;
                    capR_[writePos_] = xR;
                    writePos_++;
                }
                if (writePos_ >= loopLen_) {
                    capturing_ = false;
                    playingLoop_ = true;
                    playPos_ = pingPong && loopLen_ > 1 ? loopLen_ - 1 : 0;
                    forward_ = !pingPong;
                }
            } else if (playingLoop_ && remainingRepeats_ > 0 && loopLen_ > 0) {
                immutable size_t edgeFade = loopLen_ >= 64 ? 32 : (loopLen_ / 4);
                float env = 1.0f;
                if (edgeFade > 0) {
                    if (playPos_ < edgeFade) {
                        env = cast(float)(playPos_ + 1) / cast(float) edgeFade;
                    } else if (playPos_ + edgeFade > loopLen_) {
                        env = cast(float)(loopLen_ - playPos_) / cast(float) edgeFade;
                    }
                }
                wetL = capL_[playPos_] * env;
                wetR = capR_[playPos_] * env;

                if (forward_) {
                    playPos_++;
                    if (playPos_ >= loopLen_) {
                        remainingRepeats_--;
                        if (remainingRepeats_ == 0) {
                            playingLoop_ = false;
                        } else if (pingPong && loopLen_ > 1) {
                            playPos_ = loopLen_ - 2;
                            forward_ = false;
                        } else {
                            playPos_ = 0;
                        }
                    }
                } else {
                    if (playPos_ == 0) {
                        remainingRepeats_--;
                        if (remainingRepeats_ == 0) {
                            playingLoop_ = false;
                        } else {
                            playPos_ = loopLen_ > 1 ? 1 : 0;
                            forward_ = true;
                        }
                    } else {
                        playPos_--;
                    }
                }
            }

            immutable float yL = xL + m * (wetL - xL);
            immutable float yR = xR + m * (wetR - xR);
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;
        }

        return peak > 1e-7f || playingLoop_ || capturing_;
    }

    private uint effectiveRepeats() const pure @safe {
        if (!isFinite(repeats)) return 0;
        immutable int r = cast(int)(repeats + 0.5f);
        if (r <= 0) return 0;
        if (r > 16) return 16;
        return cast(uint) r;
    }
}
