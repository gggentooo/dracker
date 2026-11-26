/**
 * File:         source/modules/effects/fft_fx.d
 * Module:       modules.effects.fft_fx
 * Phase:        Phase 4.7 (Tier 2) — STFT Spectral Processor
 *
 * Purpose:
 *   75%-overlap Short-Time Fourier Transform (256–2048 point) spectral processor supporting spectral freeze, bin frequency shifting, spectral feedback, and zero-allocation overlap-add synthesis.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); all FFT, window, freeze, and ring buffers allocated off-RT in prepare().
 *
 * Dependencies:
 *   Internal: dsp.fft, dsp.smoother, dsp.tables, foundation.memory, graph.context, graph.module_api, graph.port
 *   External: core.lifetime, core.stdc.string, std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct FftFx (typeId = "fx.fft", ports: audioStereo in/out)
 *   - @Param fftSize, feedback, binShift, freeze, mix
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.effects.fft_fx;

import core.lifetime : move;
import core.stdc.string : memcpy, memset;
import std.math : fabs, isFinite;

import dsp.fft : FftFloat;
import dsp.smoother : ParamSmoother;
import dsp.tables : WindowKind, fillWindow;
import foundation.memory : OwnedBuffer;
import graph.context : ProcessContext;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Stereo STFT spectral processor with bin shifting, feedback blur, and spectral freeze.
 */
struct FftFx {
    enum string typeId = "fx.fft";
    enum string displayName = "FFT FX";
    enum ModuleCategory category = ModuleCategory.effect;
    enum size_t MAX_FFT_SIZE = 2048;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Input", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Output", PortKind.audioStereo, PortDirection.output)
    ];

    @Param("FFT Size", 0.0f, 3.0f, 1.0f, "", ParamScale.discrete)
    float fftSize = 1.0f;

    @Param("Feedback", 0.0f, 0.95f, 0.0f, "", ParamScale.linear)
    float feedback = 0.0f;

    @Param("Bin Shift", -64.0f, 64.0f, 0.0f, "bins", ParamScale.discrete)
    float binShift = 0.0f;

    @Param("Freeze", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete,
        ["Off", "On"])
    float freeze = 0.0f;

    @Param("Mix", 0.0f, 1.0f, 1.0f, "", ParamScale.linear)
    float mix = 1.0f;

    private OwnedBuffer!float inRingL_;
    private OwnedBuffer!float inRingR_;
    private OwnedBuffer!float outRingL_;
    private OwnedBuffer!float outRingR_;
    private OwnedBuffer!float window_;
    private OwnedBuffer!float workRe_;
    private OwnedBuffer!float workIm_;
    private OwnedBuffer!float shiftRe_;
    private OwnedBuffer!float shiftIm_;
    private OwnedBuffer!float specPrevReL_;
    private OwnedBuffer!float specPrevImL_;
    private OwnedBuffer!float specPrevReR_;
    private OwnedBuffer!float specPrevImR_;

    private ParamSmoother mixSmoother_;
    private size_t activeN_ = 512;
    private size_t rwCursor_ = 0;
    private size_t hopCounter_ = 0;
    private float sampleRate_ = 44_100.0f;
    private float tailEnergy_ = 0.0f;
    private bool freezeCaptured_ = false;

    @nogc nothrow:

    /**
     * Pre-allocates all 2048-point STFT analysis/synthesis/freeze buffers off-RT.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice frame count.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;

        if (inRingL_.empty()) {
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, inRingL_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, inRingR_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, outRingL_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, outRingR_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, window_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, workRe_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, workIm_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, shiftRe_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, shiftIm_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, specPrevReL_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, specPrevImL_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, specPrevReR_);
            OwnedBuffer!float.tryAllocate(MAX_FFT_SIZE, specPrevImR_);
        }

        mixSmoother_.prepare(sampleRate_, 5.0f, mix);
        reset();
    }

    /**
     * Zeroes all STFT rings and spectral history buffers cleanly.
     */
    void reset() {
        zeroOwned(inRingL_);
        zeroOwned(inRingR_);
        zeroOwned(outRingL_);
        zeroOwned(outRingR_);
        zeroOwned(specPrevReL_);
        zeroOwned(specPrevImL_);
        zeroOwned(specPrevReR_);
        zeroOwned(specPrevImR_);

        activeN_ = selectedFftSize();
        if (!window_.empty() && activeN_ <= window_.length) {
            fillWindow(WindowKind.hann, window_[0 .. activeN_], true);
        }
        rwCursor_ = 0;
        hopCounter_ = 0;
        tailEnergy_ = 0.0f;
        freezeCaptured_ = false;
        mixSmoother_.reset(mix);
    }

    /**
     * Updates wet/dry mix smoother or STFT block window when parameters change.
     *
     * Params:
     *   sampleRate = Active sample rate in Hertz.
     *   instant = True to snap mix smoother immediately.
     */
    void onParamChanged(string field)(float sampleRate, bool instant) {
        cast(void) sampleRate;
        static if (field == "mix") {
            mixSmoother_.setTarget(mix, instant);
        } else static if (field == "fftSize") {
            immutable size_t nextN = selectedFftSize();
            if (nextN != activeN_) {
                activeN_ = nextN;
                if (!window_.empty() && activeN_ <= window_.length) {
                    fillWindow(WindowKind.hann, window_[0 .. activeN_], true);
                }
                rwCursor_ = 0;
                hopCounter_ = 0;
                freezeCaptured_ = false;
            }
        }
    }

    /**
     * Executes 75%-overlap STFT analysis, spectral bin processing, and overlap-add synthesis.
     *
     * Params:
     *   audioIn = Input stereo slices.
     *   audioOut = Output stereo slices.
     *   ctx = Per-slice execution context.
     *
     * Returns:
     *   True while output or spectral/overlap buffer energy remains active.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        if (inRingL_.empty() || outRingL_.empty() || window_.empty()) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            return false;
        }

        immutable bool frozen = freeze >= 0.5f;
        if (ctx.inputSilent && tailEnergy_ <= 1e-7f && !frozen) {
            audioOut[0][0 .. ctx.frames] = 0.0f;
            audioOut[1][0 .. ctx.frames] = 0.0f;
            foreach (_; 0 .. ctx.frames) {
                cast(void) mixSmoother_.next();
            }
            return false;
        }

        immutable size_t n = activeN_;
        immutable size_t mask = n - 1;
        immutable size_t hop = n >> 2;

        const inL = audioIn[0];
        const inR = audioIn[1];
        auto outL = ioSlice(audioOut[0], ctx.frames);
        auto outR = ioSlice(audioOut[1], ctx.frames);

        float slicePeak = 0.0f;
        foreach (i; 0 .. ctx.frames) {
            immutable float m = mixSmoother_.next();
            immutable float xL = ctx.inputSilent ? 0.0f : (isFinite(inL[i]) ? inL[i] : 0.0f);
            immutable float xR = ctx.inputSilent ? 0.0f : (isFinite(inR[i]) ? inR[i] : 0.0f);

            inRingL_[rwCursor_] = xL;
            inRingR_[rwCursor_] = xR;

            immutable float wetL = outRingL_[rwCursor_];
            immutable float wetR = outRingR_[rwCursor_];
            outRingL_[rwCursor_] = 0.0f;
            outRingR_[rwCursor_] = 0.0f;

            immutable float yL = xL + m * (wetL - xL);
            immutable float yR = xR + m * (wetR - xR);
            outL[i] = yL;
            outR[i] = yR;

            immutable float ayL = fabs(yL);
            immutable float ayR = fabs(yR);
            if (ayL > slicePeak) slicePeak = ayL;
            if (ayR > slicePeak) slicePeak = ayR;

            rwCursor_ = (rwCursor_ + 1) & mask;
            hopCounter_++;
            if (hopCounter_ >= hop) {
                hopCounter_ = 0;
                processStftFrame(n, mask);
            }
        }

        if (slicePeak > tailEnergy_) {
            tailEnergy_ = slicePeak;
        } else {
            tailEnergy_ *= 0.985f;
            if (tailEnergy_ < 1e-8f) {
                tailEnergy_ = 0.0f;
            }
        }

        return slicePeak > 1e-7f || tailEnergy_ > 1e-7f || frozen;
    }

    private void processStftFrame(size_t n, size_t mask) {
        immutable bool frozen = freeze >= 0.5f;
        immutable float fb = isFinite(feedback) ? (feedback < 0.0f ? 0.0f : (feedback > 0.95f ? 0.95f : feedback)) : 0.0f;
        immutable int bShift = isFinite(binShift) ? cast(int)(binShift + (binShift >= 0 ? 0.5f : -0.5f)) : 0;

        processChannelFrame(n, mask, inRingL_[], outRingL_[], specPrevReL_[], specPrevImL_[], frozen, fb, bShift);
        processChannelFrame(n, mask, inRingR_[], outRingR_[], specPrevReR_[], specPrevImR_[], frozen, fb, bShift);
        if (frozen) {
            freezeCaptured_ = true;
        } else {
            freezeCaptured_ = false;
        }
    }

    private void processChannelFrame(
        size_t n,
        size_t mask,
        const(float)[] inRing,
        float[] outRing,
        float[] prevRe,
        float[] prevIm,
        bool frozen,
        float fb,
        int bShift
    ) {
        auto wRe = workRe_[0 .. n];
        auto wIm = workIm_[0 .. n];
        auto sRe = shiftRe_[0 .. n];
        auto sIm = shiftIm_[0 .. n];

        if (frozen && freezeCaptured_) {
            memcpy(wRe.ptr, prevRe.ptr, n * float.sizeof);
            memcpy(wIm.ptr, prevIm.ptr, n * float.sizeof);
        } else {
            foreach (k; 0 .. n) {
                immutable size_t rIdx = (rwCursor_ + k) & mask;
                wRe[k] = inRing[rIdx] * window_[k];
                wIm[k] = 0.0f;
            }
            FftFloat.forward(wRe, wIm);

            if (fb > 1e-4f) {
                immutable float invFb = 1.0f - fb * 0.5f;
                foreach (k; 0 .. n) {
                    wRe[k] = wRe[k] * invFb + prevRe[k] * fb;
                    wIm[k] = wIm[k] * invFb + prevIm[k] * fb;
                }
            }
            memcpy(prevRe.ptr, wRe.ptr, n * float.sizeof);
            memcpy(prevIm.ptr, wIm.ptr, n * float.sizeof);
        }

        if (bShift != 0) {
            sRe[] = 0.0f;
            sIm[] = 0.0f;
            immutable ptrdiff_t half = cast(ptrdiff_t)(n / 2);
            foreach (k; 1 .. half) {
                immutable ptrdiff_t dst = cast(ptrdiff_t) k + bShift;
                if (dst > 0 && dst < half) {
                    sRe[dst] = wRe[k];
                    sIm[dst] = wIm[k];
                    sRe[n - dst] = wRe[n - k];
                    sIm[n - dst] = wIm[n - k];
                }
            }
            sRe[0] = wRe[0];
            sIm[0] = 0.0f;
            memcpy(wRe.ptr, sRe.ptr, n * float.sizeof);
            memcpy(wIm.ptr, sIm.ptr, n * float.sizeof);
        }

        FftFloat.inverse(wRe, wIm);

        enum float olaNorm = 1.0f / 1.5f;
        foreach (k; 0 .. n) {
            immutable size_t oIdx = (rwCursor_ + k) & mask;
            outRing[oIdx] += wRe[k] * window_[k] * olaNorm;
        }
    }

    private size_t selectedFftSize() const pure @safe {
        immutable int sel = isFinite(fftSize) ? cast(int)(fftSize + 0.5f) : 1;
        switch (sel) {
            case 0: return 256;
            case 1: return 512;
            case 2: return 1024;
            default: return 2048;
        }
    }

    private static void zeroOwned(ref OwnedBuffer!float buf) @nogc nothrow {
        if (!buf.empty()) {
            memset(buf.ptr, 0, buf.length * float.sizeof);
        }
    }

    private static float[] ioSlice(float[] s, uint n) @nogc nothrow pure @safe {
        return s[0 .. n];
    }
}
