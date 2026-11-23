/**
 * File:         tests/audio_harness.d
 * Module:       tests.audio_harness
 * Phase:        Phase 0.5 — Offline Golden WAV Renderer & Audio Metric Harness
 *
 * Purpose:
 *   Renders audio slices deterministically offline across arbitrary host block sizes, compares PCM buffers against golden WAV references, and asserts SNR and peak error tolerances.
 *
 * Real-Time & Safety Contract:
 *   Test harness executing off-RT; enters ScopedNoDenormals around each @nogc slice render to match real-time hardware behavior.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, foundation.math_rt, io.audio_io
 *   External: std.format, std.math
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct AudioMetrics { double peakError; double rmsError; double snrDb; double peakActual; double peakExpected; size_t framesCompared; bool hasNaN; bool hasInf; bool bitExact(); }
 *   - AudioMetrics compareAudio(const(float)[] actual, const(float)[] expected)
 *   - AudioMetrics compareStereo(const(float)[] actualL, const(float)[] actualR, const(float)[] expectedL, const(float)[] expectedR)
 *   - bool renderOfflineStereo(scope StereoSliceRenderFn renderSlice, size_t totalFrames, size_t hostBlockFrames, out OwnedBuffer!float outLeft, out OwnedBuffer!float outRight)
 *   - void assertAudioMatches(const(float)[] actual, const(float)[] expected, double maxPeakError = 1e-6, double minSnrDb = 100.0)
 *   - void assertBufferSizeInvariance(scope void delegate() resetState, scope StereoSliceRenderFn renderSlice, size_t totalFrames, const(size_t)[] blockSizes = [64, 128, 256, 333, 512])
 *   - bool renderOfflineToWav(string wavPath, scope StereoSliceRenderFn renderSlice, size_t totalFrames, uint sampleRate, size_t hostBlockFrames, out string err)
 *   - AudioMetrics compareWithGoldenWav(string goldenWavPath, const(float)[] actualLeft, const(float)[] actualRight, out string err)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.audio_harness;

version (unittest) {
    import core.lifetime : move;
    import std.format : format;
    import std.math : fabs, isInfinity, isNaN, log10, sqrt;

    import foundation.math_rt : ScopedNoDenormals;
    import foundation.memory : OwnedBuffer;
    import io.audio_io : DecodedAudio, decodeAudioFile, deinterleaveToPlanar, writeWavFile;

    /**
     * Error and signal-to-noise metrics computed between actual and expected PCM slices.
     */
    struct AudioMetrics {
        double peakError = 0.0;
        double rmsError = 0.0;
        double snrDb = 0.0;
        double peakActual = 0.0;
        double peakExpected = 0.0;
        size_t framesCompared = 0;
        bool hasNaN = false;
        bool hasInf = false;

        /**
         * Reports whether both signals are finite and identical sample-for-sample.
         *
         * Returns:
         *   True when peakError == 0.0 and neither NaN nor Inf appeared.
         */
        bool bitExact() const @nogc nothrow pure @safe {
            return !hasNaN && !hasInf && peakError == 0.0;
        }
    }

    /**
     * Callback invoked per offline host block to render left and right output slices.
     */
    alias StereoSliceRenderFn = void delegate(float[] left, float[] right, size_t startFrame) @nogc nothrow;

    private AudioMetrics finalizeMetrics(
        double peakErr,
        double sumErrSq,
        double sumRefSq,
        double peakAct,
        double peakExp,
        size_t count,
        bool foundNaN,
        bool foundInf
    ) @nogc nothrow pure @safe {
        AudioMetrics metrics;
        metrics.peakError = peakErr;
        metrics.peakActual = peakAct;
        metrics.peakExpected = peakExp;
        metrics.framesCompared = count;
        metrics.hasNaN = foundNaN;
        metrics.hasInf = foundInf;

        if (count == 0) {
            metrics.rmsError = 0.0;
            metrics.snrDb = double.infinity;
            return metrics;
        }

        metrics.rmsError = sqrt(sumErrSq / cast(double) count);
        if (sumErrSq == 0.0) {
            metrics.snrDb = double.infinity;
        } else if (sumRefSq == 0.0) {
            metrics.snrDb = -double.infinity;
        } else {
            metrics.snrDb = 10.0 * log10(sumRefSq / sumErrSq);
        }
        return metrics;
    }

    /**
     * Computes peak error, RMS error, SNR (dB), and non-finite diagnostics for mono slices.
     *
     * Params:
     *   actual = Rendered sample slice to evaluate.
     *   expected = Reference sample slice of identical length.
     *
     * Returns:
     *   Populated AudioMetrics structure.
     */
    AudioMetrics compareAudio(const(float)[] actual, const(float)[] expected) @nogc nothrow pure {
        assert(actual.length == expected.length, "compareAudio requires equal-length slices");
        double peakErr = 0.0;
        double sumErrSq = 0.0;
        double sumRefSq = 0.0;
        double peakAct = 0.0;
        double peakExp = 0.0;
        bool foundNaN = false;
        bool foundInf = false;

        foreach (i; 0 .. actual.length) {
            immutable float a = actual[i];
            immutable float e = expected[i];
            if (isNaN(a) || isNaN(e)) {
                foundNaN = true;
                continue;
            }
            if (isInfinity(a) || isInfinity(e)) {
                foundInf = true;
                continue;
            }
            immutable double da = cast(double) a;
            immutable double de = cast(double) e;
            immutable double absA = fabs(da);
            immutable double absE = fabs(de);
            immutable double err = fabs(da - de);
            if (absA > peakAct) peakAct = absA;
            if (absE > peakExp) peakExp = absE;
            if (err > peakErr) peakErr = err;
            sumErrSq += err * err;
            sumRefSq += de * de;
        }

        return finalizeMetrics(
            peakErr,
            sumErrSq,
            sumRefSq,
            peakAct,
            peakExp,
            actual.length,
            foundNaN,
            foundInf
        );
    }

    /**
     * Computes combined error and SNR diagnostics across stereo left and right channel pairs.
     *
     * Params:
     *   actualL = Rendered left channel.
     *   actualR = Rendered right channel.
     *   expectedL = Reference left channel.
     *   expectedR = Reference right channel.
     *
     * Returns:
     *   Combined stereo AudioMetrics where framesCompared equals the stereo frame count.
     */
    AudioMetrics compareStereo(
        const(float)[] actualL,
        const(float)[] actualR,
        const(float)[] expectedL,
        const(float)[] expectedR
    ) @nogc nothrow pure {
        assert(
            actualL.length == expectedL.length
                && actualR.length == expectedR.length
                && actualL.length == actualR.length,
            "compareStereo requires equal-length stereo slices"
        );

        immutable AudioMetrics leftMetrics = compareAudio(actualL, expectedL);
        immutable AudioMetrics rightMetrics = compareAudio(actualR, expectedR);

        double sumRefSq = 0.0;
        double sumErrSq = 0.0;
        foreach (i; 0 .. actualL.length) {
            immutable float al = actualL[i];
            immutable float el = expectedL[i];
            if (!isNaN(al) && !isNaN(el) && !isInfinity(al) && !isInfinity(el)) {
                immutable double diffL = cast(double) al - cast(double) el;
                sumErrSq += diffL * diffL;
                sumRefSq += cast(double) el * cast(double) el;
            }
            immutable float ar = actualR[i];
            immutable float er = expectedR[i];
            if (!isNaN(ar) && !isNaN(er) && !isInfinity(ar) && !isInfinity(er)) {
                immutable double diffR = cast(double) ar - cast(double) er;
                sumErrSq += diffR * diffR;
                sumRefSq += cast(double) er * cast(double) er;
            }
        }

        immutable double peakErr = leftMetrics.peakError > rightMetrics.peakError
            ? leftMetrics.peakError : rightMetrics.peakError;
        immutable double peakAct = leftMetrics.peakActual > rightMetrics.peakActual
            ? leftMetrics.peakActual : rightMetrics.peakActual;
        immutable double peakExp = leftMetrics.peakExpected > rightMetrics.peakExpected
            ? leftMetrics.peakExpected : rightMetrics.peakExpected;

        AudioMetrics combined = finalizeMetrics(
            peakErr,
            sumErrSq,
            sumRefSq,
            peakAct,
            peakExp,
            actualL.length * 2,
            leftMetrics.hasNaN || rightMetrics.hasNaN,
            leftMetrics.hasInf || rightMetrics.hasInf
        );
        combined.framesCompared = actualL.length;
        return combined;
    }

    /**
     * Renders totalFrames of stereo audio offline in hostBlockFrames increments under ScopedNoDenormals.
     *
     * Params:
     *   renderSlice = Callback filling left and right output slices for each block.
     *   totalFrames = Total stereo frames to render.
     *   hostBlockFrames = Simulated host audio callback block size (> 0).
     *   outLeft = Destination @nogc left channel buffer.
     *   outRight = Destination @nogc right channel buffer.
     *
     * Returns:
     *   True if buffers were allocated and rendered cleanly; false on invalid arguments or OOM.
     */
    bool renderOfflineStereo(
        scope StereoSliceRenderFn renderSlice,
        size_t totalFrames,
        size_t hostBlockFrames,
        out OwnedBuffer!float outLeft,
        out OwnedBuffer!float outRight
    ) {
        outLeft = OwnedBuffer!float.init;
        outRight = OwnedBuffer!float.init;
        if (renderSlice is null || hostBlockFrames == 0) {
            return false;
        }
        if (!OwnedBuffer!float.tryAllocate(totalFrames, outLeft)) {
            return false;
        }
        if (!OwnedBuffer!float.tryAllocate(totalFrames, outRight)) {
            outLeft.reset();
            return false;
        }

        auto leftSlice = outLeft[];
        auto rightSlice = outRight[];
        size_t pos = 0;
        while (pos < totalFrames) {
            immutable size_t remaining = totalFrames - pos;
            immutable size_t chunk = remaining < hostBlockFrames ? remaining : hostBlockFrames;
            auto denormGuard = ScopedNoDenormals.enter();
            renderSlice(leftSlice[pos .. pos + chunk], rightSlice[pos .. pos + chunk], pos);
            pos += chunk;
        }
        return true;
    }

    /**
     * Asserts that actual matches expected with zero NaN/Inf values and tolerances met.
     *
     * Params:
     *   actual = Rendered sample slice.
     *   expected = Reference sample slice.
     *   maxPeakError = Maximum allowable sample-wise absolute error.
     *   minSnrDb = Minimum allowable signal-to-noise ratio in decibels.
     */
    void assertAudioMatches(
        const(float)[] actual,
        const(float)[] expected,
        double maxPeakError = 1e-6,
        double minSnrDb = 100.0
    ) {
        immutable AudioMetrics m = compareAudio(actual, expected);
        assert(!m.hasNaN && !m.hasInf, format(
            "Audio comparison found non-finite samples (hasNaN=%s, hasInf=%s)",
            m.hasNaN,
            m.hasInf
        ));
        assert(m.peakError <= maxPeakError, format(
            "Peak audio error %e exceeds tolerance %e",
            m.peakError,
            maxPeakError
        ));
        if (m.peakExpected > 0.0) {
            assert(m.snrDb >= minSnrDb, format(
                "Audio SNR %.2f dB is below required %.2f dB",
                m.snrDb,
                minSnrDb
            ));
        }
    }

    /**
     * Verifies bit-exact stereo render invariance across multiple simulated host buffer sizes.
     *
     * Params:
     *   resetState = Callback resetting DSP/graph state before each host block size pass.
     *   renderSlice = Callback rendering one host block slice starting at startFrame.
     *   totalFrames = Total stereo frames rendered per pass.
     *   blockSizes = Host callback sizes tested (defaults to [64, 128, 256, 333, 512]).
     */
    void assertBufferSizeInvariance(
        scope void delegate() resetState,
        scope StereoSliceRenderFn renderSlice,
        size_t totalFrames,
        const(size_t)[] blockSizes = [64, 128, 256, 333, 512]
    ) {
        assert(blockSizes.length > 0, "assertBufferSizeInvariance requires at least one block size");

        OwnedBuffer!float refLeft;
        OwnedBuffer!float refRight;
        if (resetState !is null) {
            resetState();
        }
        assert(
            renderOfflineStereo(renderSlice, totalFrames, blockSizes[0], refLeft, refRight),
            "Failed reference render in assertBufferSizeInvariance"
        );

        foreach (bs; blockSizes[1 .. $]) {
            OwnedBuffer!float curLeft;
            OwnedBuffer!float curRight;
            if (resetState !is null) {
                resetState();
            }
            assert(
                renderOfflineStereo(renderSlice, totalFrames, bs, curLeft, curRight),
                format("Failed render at block size %s", bs)
            );
            immutable AudioMetrics m = compareStereo(curLeft[], curRight[], refLeft[], refRight[]);
            assert(m.bitExact(), format(
                "Host block size %s diverged from %s (peakError=%e, hasNaN=%s, hasInf=%s)",
                bs,
                blockSizes[0],
                m.peakError,
                m.hasNaN,
                m.hasInf
            ));
        }
    }

    /**
     * Renders stereo audio offline and writes an IEEE 32-bit float WAV file to disk.
     *
     * Params:
     *   wavPath = Output WAV file path.
     *   renderSlice = Callback rendering stereo host slices.
     *   totalFrames = Total stereo frames to render.
     *   sampleRate = Sample rate in Hertz.
     *   hostBlockFrames = Simulated host callback block size.
     *   err = Error message populated on failure.
     *
     * Returns:
     *   True on success; false otherwise.
     */
    bool renderOfflineToWav(
        string wavPath,
        scope StereoSliceRenderFn renderSlice,
        size_t totalFrames,
        uint sampleRate,
        size_t hostBlockFrames,
        out string err
    ) {
        err = null;
        OwnedBuffer!float left;
        OwnedBuffer!float right;
        if (!renderOfflineStereo(renderSlice, totalFrames, hostBlockFrames, left, right)) {
            err = "Offline stereo rendering failed";
            return false;
        }
        const(float)[][2] channels = [left[], right[]];
        return writeWavFile(wavPath, channels[], sampleRate, err);
    }

    /**
     * Decodes a reference golden WAV file and compares it against rendered stereo slices.
     *
     * Params:
     *   goldenWavPath = Path to the reference WAV file.
     *   actualLeft = Rendered left channel slice.
     *   actualRight = Rendered right channel slice.
     *   err = Error message populated if loading or deinterleaving fails.
     *
     * Returns:
     *   Stereo AudioMetrics comparing rendered channels to the golden WAV.
     */
    AudioMetrics compareWithGoldenWav(
        string goldenWavPath,
        const(float)[] actualLeft,
        const(float)[] actualRight,
        out string err
    ) {
        err = null;
        DecodedAudio decoded;
        if (!decodeAudioFile(goldenWavPath, decoded, err)) {
            return AudioMetrics.init;
        }

        OwnedBuffer!float refLeft;
        OwnedBuffer!float refRight;
        if (!deinterleaveToPlanar(decoded, refLeft, refRight)) {
            err = "Failed to deinterleave golden WAV into planar stereo channels";
            return AudioMetrics.init;
        }

        assert(
            actualLeft.length == refLeft.length && actualRight.length == refRight.length,
            format(
                "Golden WAV frame count (%s) does not match rendered frames (%s)",
                refLeft.length,
                actualLeft.length
            )
        );

        return compareStereo(actualLeft, actualRight, refLeft[], refRight[]);
    }
}
