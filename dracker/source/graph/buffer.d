/**
 * File:         source/graph/buffer.d
 * Module:       graph.buffer
 * Phase:        Phase 2.1 — AudioBlock, ChannelSlice & Silence Tracking
 *
 * Purpose:
 *   Manages pre-allocated scratch audio and CV channel views inside compiled GraphPlans, tracking per-buffer silent flags so idle modules are skipped cleanly.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; non-allocating slice views backed by GraphPlan OwnedBuffer storage.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ChannelSlice { float[] samples; bool silent; void zeroFill(uint frames); }
 *   - struct AudioBlock { float[][2] channels; bool silent; void zeroFill(uint frames); }
 *   - struct CvBlock { float[] samples; bool silent; void zeroFill(uint frames); }
 *   - struct CvInView / struct CvOutView
 *   - struct ProcessIO { audioIn; audioOut; sidechainIn; cvIn; cvOut; ProcessIO subSlice(start, end); }
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module graph.buffer;

enum size_t MAX_CV_PORTS = 4;

/**
 * Single-channel audio slice paired with a silence hint flag.
 */
struct ChannelSlice {
    float[] samples;
    bool silent = true;

    /**
     * Zero-fills frames samples and marks the slice silent.
     *
     * Params:
     *   frames = Number of samples to zero.
     */
    void zeroFill(uint frames) @nogc nothrow pure @safe {
        immutable size_t limit = frames < samples.length ? frames : samples.length;
        if (limit > 0) {
            samples[0 .. limit] = 0.0f;
        }
        silent = true;
    }
}

/**
 * Stereo pair of audio channel slices paired with a shared silence flag.
 */
struct AudioBlock {
    float[][2] channels;
    bool silent = true;

    /**
     * Zero-fills frames samples across both channels and sets silent = true.
     *
     * Params:
     *   frames = Number of stereo frames to zero.
     */
    void zeroFill(uint frames) @nogc nothrow pure @safe {
        foreach (ch; 0 .. 2) {
            immutable size_t limit = frames < channels[ch].length ? frames : channels[ch].length;
            if (limit > 0) {
                channels[ch][0 .. limit] = 0.0f;
            }
        }
        silent = true;
    }
}

/**
 * Single audio-rate control-voltage slice paired with a silence hint flag.
 */
struct CvBlock {
    float[] samples;
    bool silent = true;

    /**
     * Zero-fills frames samples and marks the CV buffer silent.
     *
     * Params:
     *   frames = Number of CV samples to zero.
     */
    void zeroFill(uint frames) @nogc nothrow pure @safe {
        immutable size_t limit = frames < samples.length ? frames : samples.length;
        if (limit > 0) {
            samples[0 .. limit] = 0.0f;
        }
        silent = true;
    }
}

/**
 * Read-only audio-rate CV modulation input slot passed to modules via ProcessIO.
 */
struct CvInView {
    const(float)[] samples;
    bool connected = false;
    bool silent = true;
}

/**
 * Writable audio-rate CV modulation output slot passed to modules via ProcessIO.
 */
struct CvOutView {
    float[] samples;
    bool active = false;
}

/**
 * Complete per-node I/O descriptor bundling main stereo audio, sidechain input, and CV ports.
 */
struct ProcessIO {
    const(float)[][2] audioIn;
    float[][2] audioOut;
    const(float)[][2] sidechainIn;
    bool sidechainConnected = false;
    bool sidechainSilent = true;
    CvInView[MAX_CV_PORTS] cvIn;
    uint numCvIn = 0;
    CvOutView[MAX_CV_PORTS] cvOut;
    uint numCvOut = 0;

    /**
     * Returns an O(1) sub-sliced ProcessIO view spanning [start .. end] for event sub-blocking.
     *
     * Params:
     *   start = Inclusive slice start frame offset.
     *   end = Exclusive slice end frame offset.
     *
     * Returns:
     *   Sub-sliced ProcessIO covering [start .. end].
     */
    ProcessIO subSlice(size_t start, size_t end) @nogc nothrow pure @safe {
        ProcessIO sub;
        foreach (ch; 0 .. 2) {
            if (audioIn[ch].length >= end) {
                sub.audioIn[ch] = audioIn[ch][start .. end];
            }
            if (audioOut[ch].length >= end) {
                sub.audioOut[ch] = audioOut[ch][start .. end];
            }
            if (sidechainIn[ch].length >= end) {
                sub.sidechainIn[ch] = sidechainIn[ch][start .. end];
            }
        }
        sub.sidechainConnected = sidechainConnected;
        sub.sidechainSilent = sidechainSilent;
        sub.numCvIn = numCvIn;
        sub.numCvOut = numCvOut;
        foreach (i; 0 .. numCvIn) {
            if (i >= MAX_CV_PORTS) {
                break;
            }
            if (cvIn[i].samples.length >= end) {
                sub.cvIn[i] = CvInView(cvIn[i].samples[start .. end], cvIn[i].connected, cvIn[i].silent);
            } else {
                sub.cvIn[i] = cvIn[i];
            }
        }
        foreach (i; 0 .. numCvOut) {
            if (i >= MAX_CV_PORTS) {
                break;
            }
            if (cvOut[i].samples.length >= end) {
                sub.cvOut[i] = CvOutView(cvOut[i].samples[start .. end], cvOut[i].active);
            } else {
                sub.cvOut[i] = cvOut[i];
            }
        }
        return sub;
    }
}
