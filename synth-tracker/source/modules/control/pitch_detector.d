/**
 * File:         source/modules/control/pitch_detector.d
 * Module:       modules.control.pitch_detector
 * Phase:        Phase 4.8 (Tier 2) — Real-Time Audio Pitch Tracker
 *
 * Purpose:
 *   Estimates monophonic fundamental frequency via normalized autocorrelation (with parabolic lag peak interpolation) or zero-crossing counting and emits NoteOn, SetPitch, and NoteOff ModEvents with hysteresis.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow on process(); 1024-sample analysis ring allocated via OwnedBuffer!float in prepare().
 *
 * Dependencies:
 *   Internal: foundation.math_rt, foundation.memory, foundation.types, graph.context, graph.event, graph.module_api, graph.port
 *   External: std.math (fabs, isFinite)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct PitchDetector (typeId = "ctl.pitch_detector", ports: audioStereo in, event out)
 *   - @Param algorithm, threshold, minFreqHz, maxFreqHz, hysteresis
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module modules.control.pitch_detector;

import std.math : fabs, isFinite;

import foundation.math_rt : hzToMidiNote;
import foundation.memory : OwnedBuffer;
import foundation.types : NoteId;
import graph.context : ProcessContext;
import graph.event : ModEvent;
import graph.module_api : ModuleCategory, Param, ParamScale;
import graph.port : PortDescriptor, PortDirection, PortKind;

/**
 * Monophonic audio-to-MIDI/ModEvent pitch tracker supporting normalized autocorrelation and zero-crossing modes.
 */
struct PitchDetector {
    enum string typeId = "ctl.pitch_detector";
    enum string displayName = "Pitch Detector";
    enum ModuleCategory category = ModuleCategory.control;
    enum size_t WINDOW_SIZE = 1024;
    enum size_t HOP_SIZE = 256;

    static immutable PortDescriptor[2] ports = [
        PortDescriptor("in", "Audio In", PortKind.audioStereo, PortDirection.input),
        PortDescriptor("out", "Events Out", PortKind.event, PortDirection.output)
    ];

    @Param("Algorithm", 0.0f, 1.0f, 0.0f, "", ParamScale.discrete)
    float algorithm = 0.0f;

    @Param("Threshold", 0.001f, 0.5f, 0.02f, "", ParamScale.logarithmic)
    float threshold = 0.02f;

    @Param("Min Freq", 30.0f, 1000.0f, 60.0f, "Hz", ParamScale.logarithmic)
    float minFreqHz = 60.0f;

    @Param("Max Freq", 200.0f, 4000.0f, 1600.0f, "Hz", ParamScale.logarithmic)
    float maxFreqHz = 1600.0f;

    @Param("Hysteresis", 0.05f, 2.0f, 0.3f, "st", ParamScale.linear)
    float hysteresis = 0.3f;

    private OwnedBuffer!float ring_;
    private OwnedBuffer!float frame_;
    private size_t writePos_ = 0;
    private size_t hopCounter_ = 0;
    private float sampleRate_ = 44_100.0f;
    private NoteId activeNoteId_ = NoteId.none;
    private uint nextNoteSeq_ = 1;
    private float lastMidiNote_ = 0.0f;
    private float lastDetectedHz_ = 0.0f;

    @nogc nothrow:

    /**
     * Pre-allocates the 1024-sample analysis ring and contiguous frame copy buffer off-RT.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz.
     *   maxSliceFrames = Maximum internal slice size.
     */
    void prepare(float sampleRate, uint maxSliceFrames) {
        cast(void) maxSliceFrames;
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44_100.0f : sampleRate;
        if (ring_.empty()) {
            OwnedBuffer!float.tryAllocate(WINDOW_SIZE, ring_);
            OwnedBuffer!float.tryAllocate(WINDOW_SIZE, frame_);
        }
        reset();
    }

    /**
     * Zeroes analysis buffers and clears tracked active pitch note cleanly.
     */
    void reset() {
        if (!ring_.empty()) ring_.opSlice()[] = 0.0f;
        if (!frame_.empty()) frame_.opSlice()[] = 0.0f;
        writePos_ = 0;
        hopCounter_ = 0;
        activeNoteId_ = NoteId.none;
        lastMidiNote_ = 0.0f;
        lastDetectedHz_ = 0.0f;
    }

    /**
     * Returns the most recently estimated fundamental frequency in Hertz, or 0.0f when silent.
     *
     * Returns:
     *   Latest detected frequency in Hertz.
     */
    float lastDetectedHz() const pure @safe {
        return lastDetectedHz_;
    }

    /**
     * Analyzes incoming audio into the 1024-sample window and emits pitch-tracked ModEvents.
     *
     * Params:
     *   audioIn = Input stereo slices summed to mono for fundamental tracking.
     *   audioOut = Unused audio output slices (zero-filled if wired).
     *   ctx = Per-slice execution context holding EventSink.
     *
     * Returns:
     *   True if tracking an active pitch or emitting note events.
     */
    bool process(const(float[])[2] audioIn, float[][2] audioOut, ref ProcessContext ctx) {
        cast(void) audioOut;
        if (ring_.empty() || frame_.empty()) {
            return false;
        }

        if (ctx.inputSilent && lastDetectedHz_ == 0.0f && !activeNoteId_.isValid()) {
            return false;
        }

        immutable float sr = ctx.sampleRate > 0.0f ? ctx.sampleRate : sampleRate_;
        const inL = audioIn[0];
        const inR = audioIn[1];
        bool emitted = false;

        foreach (i; 0 .. ctx.frames) {
            immutable float mono = ctx.inputSilent ? 0.0f : 0.5f * (
                (isFinite(inL[i]) ? inL[i] : 0.0f) + (isFinite(inR[i]) ? inR[i] : 0.0f)
            );
            ring_[writePos_] = mono;
            writePos_ = (writePos_ + 1) & (WINDOW_SIZE - 1);
            hopCounter_++;

            if (hopCounter_ >= HOP_SIZE) {
                hopCounter_ = 0;
                if (analyzeAndEmit(sr, i, ctx)) {
                    emitted = true;
                }
            }
        }

        return emitted || activeNoteId_.isValid();
    }

    private bool analyzeAndEmit(float sr, uint frameOffset, ref ProcessContext ctx) {
        float peakAmp = 0.0f;
        foreach (k; 0 .. WINDOW_SIZE) {
            immutable float s = ring_[(writePos_ + k) & (WINDOW_SIZE - 1)];
            frame_[k] = s;
            immutable float a = fabs(s);
            if (a > peakAmp) peakAmp = a;
        }

        immutable float thresh = isFinite(threshold) ? (threshold < 0.0005f ? 0.0005f : threshold) : 0.02f;
        if (peakAmp < thresh) {
            lastDetectedHz_ = 0.0f;
            if (activeNoteId_.isValid()) {
                ctx.eventOut.emit(ModEvent.makeNoteOff(activeNoteId_, frameOffset));
                activeNoteId_ = NoteId.none;
                return true;
            }
            return false;
        }

        immutable int algIdx = isFinite(algorithm) ? cast(int)(algorithm + 0.5f) : 0;
        immutable float estHz = algIdx >= 1 ? estimateZeroCrossing(sr) : estimateAutocorr(sr);
        if (estHz <= 0.0f) {
            return false;
        }

        lastDetectedHz_ = estHz;
        immutable float midiNote = hzToMidiNote(estHz);
        immutable float hyst = isFinite(hysteresis) ? (hysteresis < 0.01f ? 0.01f : hysteresis) : 0.3f;

        if (!activeNoteId_.isValid()) {
            uint idVal = nextNoteSeq_++;
            if (idVal == 0) idVal = nextNoteSeq_++;
            activeNoteId_ = NoteId(idVal);
            lastMidiNote_ = midiNote;
            ctx.eventOut.emit(ModEvent.makeNoteOn(activeNoteId_, midiNote, 0.85f, frameOffset));
            return true;
        } else if (fabs(midiNote - lastMidiNote_) >= hyst) {
            lastMidiNote_ = midiNote;
            ctx.eventOut.emit(ModEvent.makeSetPitch(activeNoteId_, midiNote, frameOffset));
            return true;
        }
        return false;
    }

    private float estimateAutocorr(float sr) const {
        immutable double loFreq = (isFinite(minFreqHz) && minFreqHz >= 20.0f) ? cast(double) minFreqHz : 60.0;
        immutable double hiFreq = (isFinite(maxFreqHz) && maxFreqHz > loFreq) ? cast(double) maxFreqHz : 1600.0;
        size_t minLag = cast(size_t)(cast(double) sr / hiFreq);
        size_t maxLag = cast(size_t)(cast(double) sr / loFreq);
        if (minLag < 4) minLag = 4;
        if (maxLag >= WINDOW_SIZE / 2) maxLag = WINDOW_SIZE / 2 - 2;
        if (maxLag <= minLag) {
            return 0.0f;
        }

        immutable size_t corrN = WINDOW_SIZE / 2;
        double evalLag(size_t lag) {
            double num = 0.0;
            double den = 0.0;
            foreach (k; 0 .. corrN) {
                immutable double a = cast(double) frame_[k];
                immutable double b = cast(double) frame_[k + lag];
                num += 2.0 * a * b;
                den += a * a + b * b;
            }
            return den > 1e-12 ? (num / den) : 0.0;
        }

        double[WINDOW_SIZE / 2] nsdf = 0.0;
        double globalMax = -1.0;
        foreach (lag; (minLag - 1) .. (maxLag + 2)) {
            immutable double v = evalLag(lag);
            nsdf[lag] = v;
            if (lag >= minLag && lag <= maxLag && v > globalMax) {
                globalMax = v;
            }
        }
        if (globalMax <= 0.6) {
            return 0.0f;
        }

        immutable double keyThresh = globalMax * 0.85;
        size_t bestLag = 0;
        double bestVal = -1.0;
        foreach (lag; minLag .. (maxLag + 1)) {
            if (nsdf[lag] >= keyThresh && nsdf[lag] > nsdf[lag - 1] && nsdf[lag] >= nsdf[lag + 1]) {
                bestLag = lag;
                bestVal = nsdf[lag];
                break;
            }
        }
        if (bestLag == 0) {
            return 0.0f;
        }

        immutable double ym1 = nsdf[bestLag - 1];
        immutable double y0 = bestVal;
        immutable double yp1 = nsdf[bestLag + 1];
        immutable double denom = ym1 - 2.0 * y0 + yp1;
        double offset = 0.0;
        if (fabs(denom) > 1e-12) {
            offset = 0.5 * (ym1 - yp1) / denom;
            if (offset < -0.5) offset = -0.5;
            if (offset > 0.5) offset = 0.5;
        }
        immutable double refinedLag = cast(double) bestLag + offset;
        return refinedLag > 1.0 ? cast(float)(cast(double) sr / refinedLag) : 0.0f;
    }

    private float estimateZeroCrossing(float sr) const {
        size_t crossings = 0;
        ptrdiff_t firstIdx = -1;
        ptrdiff_t lastIdx = -1;
        foreach (k; 1 .. WINDOW_SIZE) {
            if (frame_[k - 1] < 0.0f && frame_[k] >= 0.0f) {
                if (firstIdx < 0) firstIdx = cast(ptrdiff_t) k;
                lastIdx = cast(ptrdiff_t) k;
                crossings++;
            }
        }
        if (crossings < 2 || lastIdx <= firstIdx) {
            return 0.0f;
        }
        immutable double cycles = cast(double)(crossings - 1);
        immutable double spanSamples = cast(double)(lastIdx - firstIdx);
        immutable float hz = cast(float)(cycles * cast(double) sr / spanSamples);
        if (hz < minFreqHz || hz > maxFreqHz) {
            return 0.0f;
        }
        return hz;
    }
}
