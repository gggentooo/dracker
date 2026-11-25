/**
 * File:         source/sequencer/count_in.d
 * Module:       sequencer.count_in
 * Phase:        Live record mode — count-in metronome
 *
 * Purpose:
 *   Sample-accurate metronome click played by the Engine during a live-record count-in. The Engine arms it with the
 *   first count-in line, the line where recording starts, and the beat length in lines; every beat line in
 *   [firstLine, endLine) triggers one short decaying sine click (the first beat is accented). Clicks are added to
 *   the master output after the graph renders, so they never reach module inputs, stems or exports.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow pure @safe POD with zero indirections; no allocation, no syscalls. Runs on the RT render path.
 *
 * Dependencies:
 *   Internal: dsp.tables (lookupSine)
 *   External: std.math (exp, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct CountInClick : prepare(), arm(), disarm(), armed(), sounding(), clicksTriggered(), onLineStart(),
 *     renderAdd()
 *
 * See_Also:
 *   docs/changelog.md (live record mode)
 */
module sequencer.count_in;

import std.math : exp, isFinite;
import std.traits : hasIndirections;

import dsp.tables : lookupSine;

/**
 * Count-in metronome click generator (one voice; a new click restarts it).
 */
struct CountInClick {
    enum float ACCENT_HZ = 1760.0f;
    enum float BEAT_HZ = 1320.0f;
    enum float ACCENT_GAIN = 0.32f;
    enum float BEAT_GAIN = 0.22f;
    enum float DECAY_SECONDS = 0.018f;
    enum float SILENCE_LEVEL = 1.0e-4f;

    private bool armed_ = false;
    private long firstLine_ = 0;
    private long endLine_ = 0;
    private uint beatLines_ = 4;
    private float sampleRate_ = 44_100.0f;
    private float decay_ = 0.0f;
    private bool pending_ = false;
    private uint pendingOffset_ = 0;
    private float pendingHz_ = 0.0f;
    private float pendingGain_ = 0.0f;
    private float phase_ = 0.0f;
    private float phaseInc_ = 0.0f;
    private float level_ = 0.0f;
    private uint clicks_ = 0;

    @nogc nothrow pure @safe:

    /**
     * Sets the sample rate and silences any ringing click.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     */
    void prepare(float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        decay_ = cast(float) exp(-1.0 / (cast(double) DECAY_SECONDS * cast(double) sampleRate_));
        disarm(true);
    }

    /**
     * Arms the count-in: beat lines in [firstLine, endLine) will click.
     *
     * Params:
     *   firstLine = First count-in line (may be negative); it gets the accented click.
     *   endLine = Line where recording starts; no clicks from here on.
     *   beatLines = Lines per beat (0 is treated as 1).
     */
    void arm(long firstLine, long endLine, uint beatLines) {
        firstLine_ = firstLine;
        endLine_ = endLine;
        beatLines_ = beatLines == 0 ? 1 : beatLines;
        armed_ = endLine > firstLine;
        pending_ = false;
        clicks_ = 0;
    }

    /**
     * Stops further clicks.
     *
     * Params:
     *   silence = Also cut a ringing click immediately (transport stop or seek).
     */
    void disarm(bool silence) {
        armed_ = false;
        pending_ = false;
        if (silence) {
            level_ = 0.0f;
        }
    }

    /**
     * Reports whether more clicks are scheduled.
     *
     * Returns:
     *   True between arm() and endLine.
     */
    bool armed() const {
        return armed_;
    }

    /**
     * Reports whether a click is pending or still audible.
     *
     * Returns:
     *   True while output is non-silent.
     */
    bool sounding() const {
        return pending_ || level_ > SILENCE_LEVEL;
    }

    /**
     * Returns the number of clicks triggered since the last arm().
     *
     * Returns:
     *   Click count.
     */
    uint clicksTriggered() const {
        return clicks_;
    }

    /**
     * Schedules a click when line is a count-in beat; disarms once line reaches the end line.
     *
     * Params:
     *   line = Song line whose first tick starts at frameOffset.
     *   frameOffset = Frame offset of the line start inside the current quantum.
     */
    void onLineStart(long line, uint frameOffset) {
        if (!armed_) {
            return;
        }
        if (line >= endLine_) {
            armed_ = false;
            return;
        }
        if (line < firstLine_ || (line - firstLine_) % beatLines_ != 0) {
            return;
        }
        immutable bool accent = line == firstLine_;
        pending_ = true;
        pendingOffset_ = frameOffset;
        pendingHz_ = accent ? ACCENT_HZ : BEAT_HZ;
        pendingGain_ = accent ? ACCENT_GAIN : BEAT_GAIN;
        clicks_++;
    }

    /**
     * Adds the click signal for this quantum into the stereo output (starting a pending click at its offset).
     *
     * Params:
     *   left = Left output samples (>= frames).
     *   right = Right output samples (>= frames).
     *   frames = Quantum length.
     */
    void renderAdd(float[] left, float[] right, uint frames) {
        if (!sounding()) {
            return;
        }
        immutable uint n = frames <= left.length && frames <= right.length ? frames
            : cast(uint)(left.length < right.length ? left.length : right.length);
        foreach (i; 0 .. n) {
            if (pending_ && i == pendingOffset_) {
                pending_ = false;
                phase_ = 0.0f;
                phaseInc_ = pendingHz_ / sampleRate_;
                level_ = pendingGain_;
            }
            if (level_ <= SILENCE_LEVEL) {
                continue;
            }
            immutable float s = lookupSine(phase_) * level_;
            left[i] += s;
            right[i] += s;
            phase_ += phaseInc_;
            if (phase_ >= 1.0f) {
                phase_ -= 1.0f;
            }
            level_ *= decay_;
        }
        if (pending_ && pendingOffset_ >= n) {
            pending_ = false;
        }
        if (level_ <= SILENCE_LEVEL) {
            level_ = 0.0f;
        }
    }
}

static assert(!hasIndirections!CountInClick, "CountInClick lives inside the RT Engine and must hold no pointers");
