/**
 * File:         source/modules/control/feedback.d
 * Module:       modules.control.feedback
 * Phase:        Phase 2.5 / 4.2 (Tier 1) — Fixed-Delay Graph Feedback Pair
 *
 * Purpose:
 *   Breaks directed audio graph cycles cleanly via explicit FeedbackSend/FeedbackReceive edge splitting with a buffer-size-independent fixed sample delay.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; fixed-length DelayLine buffers pre-allocated in prepare() independent of host audio buffer size.
 *
 * Dependencies:
 *   Internal: foundation.types, dsp.delay_line, dsp.smoother, graph.module_api, graph.port, graph.context
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Feedback (typeId = "ctl.feedback", ports: audioStereo in/out)
 *   - @Param volume, channels, fixedDelayFrames (default 64, range 64..4096)
 *   - process() (Receive step) & processFeedbackSend() (Send step)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.feedback;

import std.math : fabs, isFinite;

import dsp.delay_line : DelayLine;
import dsp.smoother : ParamSmoother;
import foundation.types : FIXED_BLOCK_FRAMES;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Buffer-size-independent graph feedback bridge splitting cycles into Receive -> Send steps.
 *
 * Enforces fixedDelayFrames >= FIXED_BLOCK_FRAMES (64) so FeedbackReceive taps depend
 * strictly on prior-slice audio regardless of host audio callback buffer size or event sub-blocking.
 */
struct Feedback {
    enum string typeId = "ctl.feedback";
    enum string displayName = "Feedback";
    enum ModuleCategory category = ModuleCategory.control;
    enum size_t MAX_FEEDBACK_DELAY_FRAMES = 4096;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("Volume", 0.0f, 2.0f, 0.5f, "", ParamScale.linear)
    float volume = 0.5f;

    @Param("Channels", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete)
    float channels = 0.0f;

    @Param("Fixed Delay", 64.0f, 4096.0f, 64.0f, "frames", ParamScale.discrete)
    float fixedDelayFrames = 64.0f;

    private DelayLine[2] delayLines_;
    private ParamSmoother volSmoother_;
    private uint tailCountdown_ = 0;

    @nogc nothrow:

    /**
     * Pre-allocates stereo DelayLine ring buffers up to MAX_FEEDBACK_DELAY_FRAMES and prepares smoother.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        foreach (ch; 0 .. 2) {
            if (delayLines_[ch].empty()) {
                delayLines_[ch].tryInit(MAX_FEEDBACK_DELAY_FRAMES);
            }
        }
        volSmoother_.prepare(sampleRate, 5.0f, volume);
        reset();
    }

    /**
     * Clears delayed feedback history and resets output smoother and tail countdown.
     */
    void reset() {
        foreach (ch; 0 .. 2) {
            delayLines_[ch].clear();
        }
        volSmoother_.reset(volume);
        tailCountdown_ = 0;
    }

    /**
     * Updates feedback volume smoother when volume is edited or snapped.
     *
     * Params:
     *   sampleRate = Active audio sample rate in Hertz.
     *   instant = When true, snaps immediately without ramping.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "volume") {
            volSmoother_.setTarget(volume, instant);
        }
    }

    /**
     * Receive half executed before downstream feedback-loop modules: emits delayed samples.
     *
     * Params:
     *   audioIn = Unused during Receive (reads from internal delay lines fed by processFeedbackSend).
     *   audioOut = Output stereo channel slices.
     *   ctx = Per-slice processing context.
     *
     * Returns:
     *   True while delayed signal or tail energy remains active; false when fully silent.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        cast(void) audioIn;
        if (delayLines_[0].empty() || delayLines_[1].empty()) {
            foreach (ch; 0 .. 2) {
                audioOut[ch][0 .. ctx.frames] = 0.0f;
            }
            return false;
        }

        if (tailCountdown_ == 0 && volSmoother_.isSettled()) {
            foreach (ch; 0 .. 2) {
                audioOut[ch][0 .. ctx.frames] = 0.0f;
            }
            return false;
        }

        immutable size_t delayLen = effectiveDelayFrames();
        immutable bool monoMix = channels >= 0.5f;
        auto outL = audioOut[0];
        auto outR = audioOut[1];

        float peak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            immutable float gain = volSmoother_.next();
            immutable size_t tapOffset = delayLen - 1 - i;
            immutable float dL = delayLines_[0].readTap(tapOffset);
            immutable float dR = delayLines_[1].readTap(tapOffset);

            float yL = dL * gain;
            float yR = dR * gain;
            if (monoMix) {
                immutable float m = 0.5f * (yL + yR);
                yL = m;
                yR = m;
            }
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > peak) peak = ayL;
            if (ayR > peak) peak = ayR;
        }

        return peak > 1e-7f || tailCountdown_ > 0;
    }

    /**
     * Send half executed after upstream loop modules: records input frames into delay rings.
     *
     * Params:
     *   audioIn = Upstream stereo audio feeding back into the delay lines.
     *   ctx = Per-slice processing context.
     */
    void processFeedbackSend(const(float[])[2] audioIn, ref ProcessContext ctx) {
        if (delayLines_[0].empty() || delayLines_[1].empty()) {
            return;
        }

        if (ctx.inputSilent && tailCountdown_ == 0) {
            return;
        }

        immutable size_t delayLen = effectiveDelayFrames();
        const inL = audioIn[0];
        const inR = audioIn[1];
        bool sawEnergy = false;

        foreach (i; 0 .. ctx.frames) {
            immutable float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);
            delayLines_[0].write(xL);
            delayLines_[1].write(xR);
            if (fabs(xL) > 1e-7f || fabs(xR) > 1e-7f) {
                sawEnergy = true;
            }
        }

        if (sawEnergy) {
            tailCountdown_ = cast(uint)(delayLen + FIXED_BLOCK_FRAMES);
        } else if (tailCountdown_ > ctx.frames) {
            tailCountdown_ -= ctx.frames;
        } else {
            tailCountdown_ = 0;
        }
    }

    private size_t effectiveDelayFrames() const pure @safe {
        if (!isFinite(fixedDelayFrames)) {
            return FIXED_BLOCK_FRAMES;
        }
        immutable long rounded = cast(long)(fixedDelayFrames + 0.5f);
        if (rounded < FIXED_BLOCK_FRAMES) {
            return FIXED_BLOCK_FRAMES;
        }
        if (rounded > MAX_FEEDBACK_DELAY_FRAMES) {
            return MAX_FEEDBACK_DELAY_FRAMES;
        }
        return cast(size_t) rounded;
    }
}
