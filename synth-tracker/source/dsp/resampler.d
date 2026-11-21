/**
 * File:         source/dsp/resampler.d
 * Module:       dsp.resampler
 * Phase:        Phase 1.1 — Fractional Streaming Resampler
 *
 * Purpose:
 *   Provides stateful fractional sample-rate conversion used by Sampler, MetaModule rate matching, and dual-device drift-compensated CoreAudio input.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; all FP state explicitly zero-initialized (= 0.0f / 0.0) with zero heap allocations.
 *
 * Dependencies:
 *   Internal: foundation.types, dsp.interp
 *   External: std.math (isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum ResampleQuality : ubyte { nearest, linear, catmullRom }
 *   - struct ResampleCounts { size_t consumed = 0; size_t produced = 0; }
 *   - struct FractionalResampler : setQuality(), reset(), pushSample(), evaluateCurrent(), processBlock()
 *   - struct StereoResampler : dual-channel synchronized FractionalResampler wrapper
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.resampler;

import std.math : isFinite;

import dsp.interp : interpCatmullRom, interpLinear, interpNearest;

/**
 * Interpolation quality mode for streaming sample-rate conversion.
 */
enum ResampleQuality : ubyte {
    nearest = 0,
    linear = 1,
    catmullRom = 2
}

/**
 * Frame counters returned by streaming resampler block invocations.
 */
struct ResampleCounts {
    size_t consumed = 0;
    size_t produced = 0;
}

/**
 * Stateful streaming fractional resampler supporting arbitrary continuous rate ratios.
 *
 * Maintains a 4-sample causal history window giving 2-sample lookahead latency and exact
 * phase continuity across arbitrary host/slice block boundaries.
 */
struct FractionalResampler {
    private float[4] history_ = 0.0f;
    private double fracPos_ = 3.0;
    private ResampleQuality quality_ = ResampleQuality.catmullRom;

    @nogc nothrow pure @safe:

    /**
     * Configures the sample interpolation kernel.
     *
     * Params:
     *   q = Desired interpolation quality level.
     */
    void setQuality(ResampleQuality q) {
        quality_ = q;
    }

    /**
     * Returns the active interpolation quality setting.
     *
     * Returns:
     *   Current ResampleQuality mode.
     */
    ResampleQuality quality() const {
        return quality_;
    }

    /**
     * Returns the fixed causal lookahead latency in input samples for 4-point interpolation.
     *
     * Returns:
     *   Latency in input samples (2).
     */
    uint latencySamples() const {
        return 2;
    }

    /**
     * Clears sample history and resets the fractional phase cursor to its primed state.
     */
    void reset() {
        history_[] = 0.0f;
        fracPos_ = 3.0;
    }

    /**
     * Shifts one new input sample into the 4-sample interpolation window.
     *
     * Params:
     *   sample = Next mono PCM input sample.
     */
    void pushSample(float sample) {
        history_[0] = history_[1];
        history_[1] = history_[2];
        history_[2] = history_[3];
        history_[3] = isFinite(sample) ? sample : 0.0f;
    }

    /**
     * Evaluates the output sample at the current fractional offset within [0.0, 1.0).
     *
     * Returns:
     *   Interpolated sample value.
     */
    float evaluateCurrent() const {
        float frac = cast(float) fracPos_;
        if (frac < 0.0f) {
            frac = 0.0f;
        } else if (frac > 1.0f) {
            frac = 1.0f;
        }

        final switch (quality_) {
            case ResampleQuality.nearest:
                return interpNearest(history_[1], history_[2], frac);
            case ResampleQuality.linear:
                return interpLinear(history_[1], history_[2], frac);
            case ResampleQuality.catmullRom:
                return interpCatmullRom(history_[0], history_[1], history_[2], history_[3], frac);
        }
    }

    /**
     * Resamples input frames into output at the specified input-to-output step ratio.
     *
     * A ratio of sourceSampleRate / targetSampleRate advances ratio input frames per emitted
     * output frame (for example, 0.5 upsamples 2x and 2.0 downsamples 2x).
     *
     * Params:
     *   input = Available input sample slice.
     *   output = Destination slice receiving resampled output frames.
     *   ratio = Input frames advanced per output sample (> 0.0).
     *
     * Returns:
     *   Counts of input samples consumed and output samples produced.
     */
    ResampleCounts processBlock(const(float)[] input, float[] output, double ratio) {
        ResampleCounts counts;
        if (!isFinite(ratio) || ratio <= 0.0 || output.length == 0) {
            return counts;
        }

        while (counts.produced < output.length) {
            while (fracPos_ >= 1.0) {
                if (counts.consumed >= input.length) {
                    return counts;
                }
                pushSample(input[counts.consumed]);
                counts.consumed++;
                fracPos_ -= 1.0;
            }

            output[counts.produced] = evaluateCurrent();
            counts.produced++;
            fracPos_ += ratio;
        }
        return counts;
    }
}

/**
 * Synchronized stereo pair of FractionalResampler instances for dual-channel streams.
 */
struct StereoResampler {
    private FractionalResampler[2] channels_;

    @nogc nothrow pure @safe:

    /**
     * Sets the interpolation quality on both left and right channels.
     *
     * Params:
     *   q = Desired interpolation quality level.
     */
    void setQuality(ResampleQuality q) {
        channels_[0].setQuality(q);
        channels_[1].setQuality(q);
    }

    /**
     * Resets both left and right resampler states.
     */
    void reset() {
        channels_[0].reset();
        channels_[1].reset();
    }

    /**
     * Processes stereo planar input slices into stereo planar output slices in lockstep.
     *
     * Params:
     *   inL = Left input slice.
     *   inR = Right input slice (must match inL length).
     *   outL = Left output slice.
     *   outR = Right output slice (must match outL length).
     *   ratio = Input frames advanced per output frame (> 0.0).
     *
     * Returns:
     *   Input frames consumed and output frames produced per channel.
     */
    ResampleCounts processBlock(
        const(float)[] inL,
        const(float)[] inR,
        float[] outL,
        float[] outR,
        double ratio
    ) {
        assert(inL.length == inR.length && outL.length == outR.length,
            "StereoResampler requires matched left and right slice lengths");
        immutable ResampleCounts cL = channels_[0].processBlock(inL, outL, ratio);
        immutable ResampleCounts cR = channels_[1].processBlock(inR, outR, ratio);
        assert(cL.consumed == cR.consumed && cL.produced == cR.produced,
            "StereoResampler channels diverged");
        return cL;
    }
}
