/**
 * File:         source/app/telemetry.d
 * Module:       app.telemetry
 * Phase:        Phase 7.5.3 — UI-Side Scope History, Spectrum Analysis & Combined Studio Telemetry
 *
 * Purpose:
 *   Consumes the RT-published ScopeBlock ring of an Engine into per-source history rings (master = source 0
 *   plus up to four tapped modules), serves oscilloscope snapshots aligned to the newest frame, computes
 *   Hann-windowed magnitude spectra (dBFS) with dsp.fft, and bundles EngineTelemetry + AudioLoadTelemetry into a
 *   single StudioTelemetry snapshot for transport bars and meters.
 *
 * Real-Time & Safety Contract:
 *   UI thread only (single consumer of Engine.tryPopScopeBlock()); never blocks the RT producer.
 *
 * Dependencies:
 *   Internal: app.audio_host (AudioLoadTelemetry), dsp.fft, foundation.types, sequencer.engine
 *   External: std.math (cos, log10, PI, sqrt)
 *
 * Planned API (Types, Functions & Hooks):
 *   - class ScopeHistory : consume(), snapshot(), spectrum(), newestFrame(), sources()
 *   - struct StudioTelemetry / StudioTelemetry makeStudioTelemetry(Engine*, const(AudioLoadTelemetry)*)
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 7.5.3)
 */
module app.telemetry;

import std.math : cos, log10, PI, sqrt;

import app.audio_host : AudioLoadTelemetry;
import dsp.fft : FftFloat;
import foundation.types : FIXED_BLOCK_FRAMES;
import sequencer.engine : Engine, EngineTelemetry, ScopeBlock;

/**
 * Combined transport, graph, and audio-device telemetry for one UI frame.
 */
struct StudioTelemetry {
    EngineTelemetry engine;
    AudioLoadTelemetry audio;
    bool audioRunning = false;
}

private final class SourceRing {
    float[] left;
    float[] right;
    size_t write = 0;
    size_t filled = 0;
    ulong newestFrame = 0;
    ulong gaps = 0;

    this(size_t capacity) {
        left = new float[capacity];
        right = new float[capacity];
    }

    void append(const ref ScopeBlock b) {
        immutable ulong expected = newestFrame + FIXED_BLOCK_FRAMES;
        if (filled > 0 && b.frame != expected) {
            gaps++;
        }
        foreach (i; 0 .. FIXED_BLOCK_FRAMES) {
            left[write] = b.left[i];
            right[write] = b.right[i];
            write = (write + 1) % left.length;
        }
        filled = filled + FIXED_BLOCK_FRAMES > left.length ? left.length : filled + FIXED_BLOCK_FRAMES;
        newestFrame = b.frame;
    }
}

/**
 * Per-source rolling history of published scope blocks.
 */
final class ScopeHistory {
    private size_t capacity_;
    private SourceRing[uint] rings_;

    /**
     * Creates histories holding capacity frames per source.
     *
     * Params:
     *   capacity = Frames retained per source (rounded up to a multiple of 64, >= 64).
     */
    this(size_t capacity = 8192) {
        immutable size_t c = capacity < FIXED_BLOCK_FRAMES ? FIXED_BLOCK_FRAMES : capacity;
        capacity_ = (c + FIXED_BLOCK_FRAMES - 1) / FIXED_BLOCK_FRAMES * FIXED_BLOCK_FRAMES;
    }

    /**
     * Drains every pending block from engine into the histories.
     *
     * Params:
     *   engine = Engine publishing scope blocks.
     *   maxBlocks = Upper bound per call.
     *
     * Returns:
     *   Number of blocks consumed.
     */
    size_t consume(Engine* engine, size_t maxBlocks = 4096) {
        if (engine is null) {
            return 0;
        }
        size_t n = 0;
        ScopeBlock b;
        while (n < maxBlocks && engine.tryPopScopeBlock(b)) {
            push(b);
            n++;
        }
        return n;
    }

    /**
     * Appends one block (exposed for tests and offline analysis).
     *
     * Params:
     *   b = Block.
     */
    void push(const ref ScopeBlock b) {
        auto p = b.sourceId in rings_;
        SourceRing r = p is null ? null : *p;
        if (r is null) {
            r = new SourceRing(capacity_);
            rings_[b.sourceId] = r;
        }
        r.append(b);
    }

    /**
     * Returns the source ids seen so far.
     *
     * Returns:
     *   Source ids (0 = master).
     */
    uint[] sources() const {
        return rings_.keys.dup;
    }

    /**
     * Returns the absolute frame index of the newest block of a source.
     *
     * Params:
     *   sourceId = Source.
     *
     * Returns:
     *   Frame index, or 0 if unseen.
     */
    ulong newestFrame(uint sourceId) const {
        auto p = sourceId in rings_;
        return p is null ? 0 : (*p).newestFrame;
    }

    /**
     * Returns how many discontinuities (dropped blocks) a source history has seen.
     *
     * Params:
     *   sourceId = Source.
     *
     * Returns:
     *   Gap count.
     */
    ulong gaps(uint sourceId) const {
        auto p = sourceId in rings_;
        return p is null ? 0 : (*p).gaps;
    }

    /**
     * Copies the newest frames of a source, oldest first.
     *
     * Params:
     *   sourceId = Source.
     *   frames = Frames requested.
     *   l = Receives left samples.
     *   r = Receives right samples.
     *
     * Returns:
     *   Frames copied (less than requested while the history is filling).
     */
    size_t snapshot(uint sourceId, size_t frames, out float[] l, out float[] r) const {
        auto p = sourceId in rings_;
        if (p is null) {
            return 0;
        }
        const SourceRing ring = *p;
        immutable size_t n = frames < ring.filled ? frames : ring.filled;
        l = new float[n];
        r = new float[n];
        immutable size_t cap = ring.left.length;
        immutable size_t start = (ring.write + cap - n) % cap;
        foreach (i; 0 .. n) {
            l[i] = ring.left[(start + i) % cap];
            r[i] = ring.right[(start + i) % cap];
        }
        return n;
    }

    /**
     * Computes a Hann-windowed mono (L+R)/2 magnitude spectrum of the newest fftSize frames in dBFS
     * (a full-scale sine reads about 0 dBFS).
     *
     * Params:
     *   sourceId = Source.
     *   fftSize = Power-of-two FFT length (64 .. 16384).
     *   magnitudesDb = Receives fftSize/2 bins (bin k = k * sampleRate / fftSize Hz).
     *
     * Returns:
     *   True if enough history exists.
     */
    bool spectrum(uint sourceId, size_t fftSize, out float[] magnitudesDb) const {
        if (!FftFloat.isValidSize(fftSize) || fftSize < 64 || fftSize > 16384) {
            return false;
        }
        float[] l;
        float[] r;
        if (snapshot(sourceId, fftSize, l, r) < fftSize) {
            return false;
        }
        float[] mono = new float[fftSize];
        float windowSum = 0.0f;
        foreach (i; 0 .. fftSize) {
            immutable float w = 0.5f - 0.5f * cast(float) cos(2.0 * PI * i / (fftSize - 1));
            windowSum += w;
            mono[i] = 0.5f * (l[i] + r[i]) * w;
        }
        float[] re = new float[fftSize];
        float[] im = new float[fftSize];
        FftFloat.forwardReal(mono, re, im);
        magnitudesDb = new float[fftSize / 2];
        immutable float norm = 2.0f / windowSum;
        foreach (k; 0 .. fftSize / 2) {
            immutable float mag = sqrt(re[k] * re[k] + im[k] * im[k]) * norm;
            magnitudesDb[k] = mag > 1e-10f ? 20.0f * cast(float) log10(mag) : -200.0f;
        }
        return true;
    }
}

/**
 * Bundles the latest Engine telemetry with optional audio-device load telemetry.
 *
 * Params:
 *   engine = Session Engine.
 *   audio = Latest AudioLoadTelemetry (null when no AudioHost is running).
 *
 * Returns:
 *   Combined snapshot.
 */
StudioTelemetry makeStudioTelemetry(Engine* engine, const(AudioLoadTelemetry)* audio) {
    StudioTelemetry t;
    if (engine !is null) {
        engine.readTelemetry(t.engine);
    }
    if (audio !is null) {
        t.audio = *audio;
        t.audioRunning = true;
    }
    return t;
}
