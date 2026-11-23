/**
 * File:         source/platform/macos/coreaudio.d
 * Module:       platform.macos.coreaudio
 * Phase:        Phase 3.2 — CoreAudio / AudioToolbox AUHAL Driver
 *
 * Purpose:
 *   Binds macOS AudioUnit (HALOutput / AUHAL) for low-latency stereo playback, same-device duplex input, and dual-device drift-compensated resampling ring input, plus hot-plug property listeners.
 *
 * Real-Time & Safety Contract:
 *   Render and input callbacks are extern(C) @nogc nothrow, execute on unregistered macOS RT threads with zero D TLS accesses, and activate ScopedNoDenormals on entry.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory, foundation.concurrency, foundation.math_rt, dsp.resampler, platform.interfaces, platform.macos.corefoundation
 *   External: core.lifetime, core.stdc.stdlib, core.stdc.string, core.sys.posix.pthread, macOS CoreAudio.framework, AudioToolbox.framework
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct DriftCompensatedInputRing : @nogc PI-controlled fractional resampling ring for dual-device duplex
 *   - struct CoreAudioRtContext : @nogc zero-GC-ref RT callback state block
 *   - extern(C) OSStatus auRenderCallback(...) @nogc nothrow / auInputCallback(...) @nogc nothrow / auPropertyListener(...) @nogc nothrow
 *   - class CoreAudioDriver : IAudioDriver
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.macos.coreaudio;

import core.atomic : MemoryOrder;
import core.lifetime : emplace, move;
import core.stdc.string : memcpy, memset;
import std.math : fabs, isFinite;
import std.traits : hasIndirections;

import dsp.resampler : ResampleCounts, ResampleQuality, StereoResampler;
import foundation.concurrency : Atomic, MpscRing, SpscRing, hasGcReference;
import foundation.math_rt : ScopedNoDenormals;
import foundation.memory : OwnedBuffer;
import foundation.types : StereoFrame;
import platform.interfaces;

/**
 * Lock-free stereo input ring buffer with PI-controlled fractional clock-drift compensation.
 *
 * Bridges an independent CoreAudio input AudioUnit thread (producer) and the CoreAudio
 * output render thread (consumer) when input and output run on separate hardware clocks.
 */
struct DriftCompensatedInputRing {
    private enum size_t SCRATCH_CHUNK_FRAMES = 256;

    private SpscRing!StereoFrame ring_;
    private StereoResampler resampler_;
    private OwnedBuffer!float scratchInL_;
    private OwnedBuffer!float scratchInR_;
    private size_t scratchRead_ = 0;
    private size_t scratchLen_ = 0;

    private double baseRatio_ = 1.0;
    private double currentRatio_ = 1.0;
    private double targetFill_ = 512.0;
    private double smoothedFill_ = 512.0;
    private double integralErr_ = 0.0;
    private bool primed_ = false;

    private Atomic!ulong overruns_;
    private Atomic!ulong underruns_;
    private Atomic!ulong lastRatioBits_;

    @disable this(this);

    @nogc nothrow:

    /**
     * Transfers ownership of a DriftCompensatedInputRing from an rvalue source.
     *
     * Params:
     *   rhs = Source instance moved into this struct.
     *
     * Returns:
     *   Reference to this DriftCompensatedInputRing.
     */
    ref DriftCompensatedInputRing opAssign(DriftCompensatedInputRing rhs) return {
        ring_ = move(rhs.ring_);
        resampler_ = rhs.resampler_;
        scratchInL_ = move(rhs.scratchInL_);
        scratchInR_ = move(rhs.scratchInR_);
        scratchRead_ = rhs.scratchRead_;
        scratchLen_ = rhs.scratchLen_;
        baseRatio_ = rhs.baseRatio_;
        currentRatio_ = rhs.currentRatio_;
        targetFill_ = rhs.targetFill_;
        smoothedFill_ = rhs.smoothedFill_;
        integralErr_ = rhs.integralErr_;
        primed_ = rhs.primed_;
        overruns_.store(rhs.overruns_.load());
        underruns_.store(rhs.underruns_.load());
        lastRatioBits_.store(rhs.lastRatioBits_.load());
        rhs.scratchRead_ = 0;
        rhs.scratchLen_ = 0;
        rhs.primed_ = false;
        return this;
    }

    /**
     * Allocates the lock-free ring buffer and scratch buffers for inputRate -> outputRate conversion.
     *
     * Params:
     *   inputRate = Nominal hardware input sample rate in Hertz.
     *   outputRate = Nominal hardware output sample rate in Hertz.
     *   targetFillFrames = Steady-state target queue fill in input frames.
     *   ringCapacityPow2 = Power-of-two capacity in stereo frames.
     *
     * Returns:
     *   True on success; false on invalid arguments or OOM.
     */
    bool tryInit(
        double inputRate,
        double outputRate,
        uint targetFillFrames = 512,
        size_t ringCapacityPow2 = 8192
    ) {
        if (!isFinite(inputRate) || !isFinite(outputRate) || inputRate < 1000.0 || outputRate < 1000.0) {
            return false;
        }
        if (ringCapacityPow2 < 64) {
            return false;
        }

        SpscRing!StereoFrame allocatedRing;
        if (!SpscRing!StereoFrame.tryCreate(ringCapacityPow2, allocatedRing)) {
            return false;
        }
        OwnedBuffer!float sL;
        OwnedBuffer!float sR;
        if (!OwnedBuffer!float.tryAllocate(SCRATCH_CHUNK_FRAMES, sL)
                || !OwnedBuffer!float.tryAllocate(SCRATCH_CHUNK_FRAMES, sR)) {
            return false;
        }

        ring_ = move(allocatedRing);
        scratchInL_ = move(sL);
        scratchInR_ = move(sR);
        scratchRead_ = 0;
        scratchLen_ = 0;

        baseRatio_ = inputRate / outputRate;
        if (baseRatio_ < 0.05) {
            baseRatio_ = 0.05;
        } else if (baseRatio_ > 20.0) {
            baseRatio_ = 20.0;
        }
        currentRatio_ = baseRatio_;
        storeRatioBits(currentRatio_);

        immutable double maxTarget = cast(double)(ringCapacityPow2 / 2);
        targetFill_ = targetFillFrames < 32 ? 32.0 : cast(double) targetFillFrames;
        if (targetFill_ > maxTarget) {
            targetFill_ = maxTarget;
        }
        smoothedFill_ = targetFill_;
        integralErr_ = 0.0;
        primed_ = false;
        overruns_.store(0);
        underruns_.store(0);
        resampler_.setQuality(ResampleQuality.catmullRom);
        resampler_.reset();
        return true;
    }

    /**
     * Releases owned ring and scratch storage.
     */
    void destroy() {
        ring_.reset();
        scratchInL_.reset();
        scratchInR_.reset();
        scratchRead_ = 0;
        scratchLen_ = 0;
        primed_ = false;
    }

    /**
     * Drains queued frames and resets controller and resampler history without reallocating.
     */
    void reset() {
        StereoFrame discard;
        while (ring_.tryPop(discard)) {
        }
        resampler_.reset();
        scratchRead_ = 0;
        scratchLen_ = 0;
        currentRatio_ = baseRatio_;
        storeRatioBits(currentRatio_);
        smoothedFill_ = targetFill_;
        integralErr_ = 0.0;
        primed_ = false;
        overruns_.store(0);
        underruns_.store(0);
    }

    /**
     * Enqueues incoming stereo input frames on the producer thread, counting any ring overflow.
     *
     * Params:
     *   inL = Left input channel pointer (null yields zeros).
     *   inR = Right input channel pointer (null yields zeros).
     *   frames = Number of input frames to push.
     *
     * Returns:
     *   Count of frames successfully written to the ring.
     */
    size_t pushStereo(const(float)* inL, const(float)* inR, uint frames) {
        if (ring_.capacity() == 0 || frames == 0) {
            return 0;
        }
        size_t pushed = 0;
        size_t dropped = 0;
        foreach (i; 0 .. frames) {
            immutable float l = (inL !is null && isFinite(inL[i])) ? inL[i] : 0.0f;
            immutable float r = (inR !is null && isFinite(inR[i])) ? inR[i] : 0.0f;
            if (ring_.tryPush(StereoFrame(l, r))) {
                pushed++;
            } else {
                dropped++;
            }
        }
        if (dropped > 0) {
            overruns_.fetchAdd(dropped);
        }
        return pushed;
    }

    /**
     * Resamples buffered input audio into output buffers using a slow PI clock-drift loop.
     *
     * Before reaching half of targetFillFrames, outputs silence cleanly without flagging underruns.
     *
     * Params:
     *   outL = Destination left buffer of length >= frames.
     *   outR = Destination right buffer of length >= frames.
     *   frames = Number of output frames requested by the output audio thread.
     */
    void pullResampled(float* outL, float* outR, uint frames) {
        if (outL is null || outR is null || frames == 0) {
            return;
        }
        if (ring_.capacity() == 0 || scratchInL_.empty() || scratchInR_.empty()) {
            memset(outL, 0, frames * float.sizeof);
            memset(outR, 0, frames * float.sizeof);
            return;
        }

        immutable size_t fill = ring_.approximateCount() + (scratchLen_ - scratchRead_);
        immutable size_t primeThreshold = cast(size_t)(targetFill_ * 0.5);
        if (!primed_) {
            if (fill < primeThreshold) {
                memset(outL, 0, frames * float.sizeof);
                memset(outR, 0, frames * float.sizeof);
                return;
            }
            primed_ = true;
            smoothedFill_ = cast(double) fill;
            integralErr_ = 0.0;
        }

        smoothedFill_ += 0.02 * (cast(double) fill - smoothedFill_);
        immutable double err = smoothedFill_ - targetFill_;
        integralErr_ += err;
        if (integralErr_ > 50_000.0) {
            integralErr_ = 50_000.0;
        } else if (integralErr_ < -50_000.0) {
            integralErr_ = -50_000.0;
        }
        double adj = err * 1.5e-5 + integralErr_ * 1.5e-8;
        if (adj > 0.02) {
            adj = 0.02;
        } else if (adj < -0.02) {
            adj = -0.02;
        }
        currentRatio_ = baseRatio_ * (1.0 + adj);
        storeRatioBits(currentRatio_);

        size_t outPos = 0;
        while (outPos < frames) {
            if (scratchRead_ >= scratchLen_) {
                scratchRead_ = 0;
                scratchLen_ = 0;
                StereoFrame sf;
                while (scratchLen_ < scratchInL_.length && ring_.tryPop(sf)) {
                    scratchInL_[scratchLen_] = sf.left;
                    scratchInR_[scratchLen_] = sf.right;
                    scratchLen_++;
                }
            }

            const(float)[] inSliceL = scratchRead_ < scratchLen_
                ? scratchInL_[scratchRead_ .. scratchLen_] : null;
            const(float)[] inSliceR = scratchRead_ < scratchLen_
                ? scratchInR_[scratchRead_ .. scratchLen_] : null;
            float[] dstL = outL[outPos .. frames];
            float[] dstR = outR[outPos .. frames];

            immutable ResampleCounts counts = resampler_.processBlock(
                inSliceL,
                inSliceR,
                dstL,
                dstR,
                currentRatio_
            );
            scratchRead_ += counts.consumed;
            outPos += counts.produced;

            if (counts.produced == 0 && scratchRead_ >= scratchLen_) {
                memset(outL + outPos, 0, (frames - outPos) * float.sizeof);
                memset(outR + outPos, 0, (frames - outPos) * float.sizeof);
                underruns_.fetchAdd(1);
                break;
            }
        }
    }

    /**
     * Returns total input ring overflow sample count.
     *
     * Returns:
     *   Dropped stereo frame count.
     */
    ulong overrunCount() const {
        return overruns_.load();
    }

    /**
     * Returns total consumer underrun event count after initial priming.
     *
     * Returns:
     *   Underrun event count.
     */
    ulong underrunCount() const {
        return underruns_.load();
    }

    /**
     * Returns the latest adaptive input-to-output resampling step ratio cleanly via atomic load.
     *
     * Returns:
     *   Resampling step ratio (inputFrames / outputFrame).
     */
    double currentRatio() const {
        ulong bits = lastRatioBits_.load();
        double val = 1.0;
        memcpy(&val, &bits, double.sizeof);
        return val;
    }

    /**
     * Returns the approximate number of buffered stereo frames waiting in the ring.
     *
     * Returns:
     *   Queued stereo frame count.
     */
    size_t fillLevel() const {
        return ring_.approximateCount();
    }

    /**
     * Reports whether initial pre-roll priming threshold has been met.
     *
     * Returns:
     *   True once primed.
     */
    bool isPrimed() const pure @safe {
        return primed_;
    }

    private void storeRatioBits(double ratio) {
        ulong bits = 0;
        memcpy(&bits, &ratio, double.sizeof);
        lastRatioBits_.store(bits);
    }
}

static assert(!hasGcReference!DriftCompensatedInputRing,
    "DriftCompensatedInputRing must never contain GC-managed references");

version (OSX):

import core.stdc.stdlib : calloc, free;
import core.sys.posix.pthread : pthread_self, pthread_t;
import platform.macos.corefoundation : CFStringRef, MachTimebase, ScopedCF, cfStringToDString;

static assert(pthread_t.sizeof <= size_t.sizeof,
    "Expected pthread_t to fit cleanly inside size_t");

alias OSStatus = int;
alias AudioObjectID = uint;
alias AudioDeviceID = uint;
alias AudioObjectPropertySelector = uint;
alias AudioObjectPropertyScope = uint;
alias AudioObjectPropertyElement = uint;
alias AudioUnitRenderActionFlags = uint;
alias AudioUnitPropertyID = uint;
alias AudioUnitScope = uint;
alias AudioUnitElement = uint;
alias AudioComponent = void*;
alias AudioComponentInstance = void*;
alias AudioUnit = void*;

enum OSStatus noErr = 0;

enum AudioObjectID kAudioObjectSystemObject = 1;
enum AudioObjectID kAudioObjectUnknown = 0;

enum AudioObjectPropertyScope kAudioObjectPropertyScopeGlobal = 0x676c_6f62u;
enum AudioObjectPropertyScope kAudioObjectPropertyScopeInput = 0x696e_7074u;
enum AudioObjectPropertyScope kAudioObjectPropertyScopeOutput = 0x6f75_7470u;
enum AudioObjectPropertyElement kAudioObjectPropertyElementMain = 0u;

enum AudioObjectPropertySelector kAudioHardwarePropertyDevices = 0x6465_7623u;
enum AudioObjectPropertySelector kAudioHardwarePropertyDefaultOutputDevice = 0x644f_7574u;
enum AudioObjectPropertySelector kAudioHardwarePropertyDefaultInputDevice = 0x6449_6e20u;
enum AudioObjectPropertySelector kAudioObjectPropertyName = 0x6c6e_616du;
enum AudioObjectPropertySelector kAudioDevicePropertyDeviceUID = 0x7569_6420u;
enum AudioObjectPropertySelector kAudioDevicePropertyNominalSampleRate = 0x6e73_7274u;
enum AudioObjectPropertySelector kAudioDevicePropertyAvailableNominalSampleRates = 0x6e73_7223u;
enum AudioObjectPropertySelector kAudioDevicePropertyStreamConfiguration = 0x736c_6179u;
enum AudioObjectPropertySelector kAudioDevicePropertyBufferFrameSize = 0x6673_697au;
enum AudioObjectPropertySelector kAudioDevicePropertyBufferFrameSizeRange = 0x6673_7a23u;
enum AudioObjectPropertySelector kAudioDevicePropertyDeviceIsAlive = 0x6c69_766eu;
enum AudioObjectPropertySelector kAudioDevicePropertySafetyOffset = 0x7361_6674u;
enum AudioObjectPropertySelector kAudioDevicePropertyLatency = 0x6c74_6e63u;

enum uint kAudioFormatLinearPCM = 0x6c70_636du;
enum uint kAudioFormatFlagIsFloat = 1u << 0;
enum uint kAudioFormatFlagIsPacked = 1u << 3;
enum uint kAudioFormatFlagIsNonInterleaved = 1u << 5;
enum uint kAudioFormatFlagsNativeFloatPacked = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;

enum uint kAudioUnitType_Output = 0x6175_6f75u;
enum uint kAudioUnitSubType_HALOutput = 0x6168_616cu;
enum uint kAudioUnitSubType_DefaultOutput = 0x6465_6620u;
enum uint kAudioUnitManufacturer_Apple = 0x6170_706cu;

enum AudioUnitScope kAudioUnitScope_Global = 0;
enum AudioUnitScope kAudioUnitScope_Input = 1;
enum AudioUnitScope kAudioUnitScope_Output = 2;

enum AudioUnitPropertyID kAudioOutputUnitProperty_CurrentDevice = 2000;
enum AudioUnitPropertyID kAudioOutputUnitProperty_EnableIO = 2003;
enum AudioUnitPropertyID kAudioOutputUnitProperty_SetInputCallback = 2005;

enum AudioUnitPropertyID kAudioUnitProperty_SampleRate = 2;
enum AudioUnitPropertyID kAudioUnitProperty_StreamFormat = 8;
enum AudioUnitPropertyID kAudioUnitProperty_MaximumFramesPerSlice = 14;
enum AudioUnitPropertyID kAudioUnitProperty_SetRenderCallback = 23;

enum AudioUnitRenderActionFlags kAudioUnitRenderAction_OutputIsSilence = 1u << 4;
enum uint kAudioTimeStampSampleTimeValid = 1u << 0;
enum uint kAudioTimeStampHostTimeValid = 1u << 1;

/**
 * CoreAudio HAL object property selector/scope/element tuple matching AudioObjectPropertyAddress.
 */
struct AudioObjectPropertyAddress {
    AudioObjectPropertySelector mSelector = 0;
    AudioObjectPropertyScope mScope = 0;
    AudioObjectPropertyElement mElement = 0;
}

/**
 * Closed numeric range descriptor matching CoreAudio AudioValueRange.
 */
struct AudioValueRange {
    double mMinimum = 0.0;
    double mMaximum = 0.0;
}

/**
 * CoreAudio PCM format descriptor matching AudioStreamBasicDescription.
 */
struct AudioStreamBasicDescription {
    double mSampleRate = 0.0;
    uint mFormatID = 0;
    uint mFormatFlags = 0;
    uint mBytesPerPacket = 0;
    uint mFramesPerPacket = 0;
    uint mBytesPerFrame = 0;
    uint mChannelsPerFrame = 0;
    uint mBitsPerChannel = 0;
    uint mReserved = 0;
}

/**
 * CoreAudio single buffer slice header matching AudioBuffer.
 */
struct AudioBuffer {
    uint mNumberChannels = 0;
    uint mDataByteSize = 0;
    void* mData = null;
}

/**
 * Single-element CoreAudio buffer list header matching C AudioBufferList.
 */
struct AudioBufferList {
    uint mNumberBuffers = 0;
    AudioBuffer[1] mBuffers;
}

/**
 * Fixed two-buffer variant matching C AudioBufferList with two non-interleaved AudioBuffers.
 */
struct AudioBufferList2 {
    uint mNumberBuffers = 0;
    AudioBuffer[2] mBuffers;
}

/**
 * SMPTE timecode structure embedded inside AudioTimeStamp.
 */
struct SMPTETime {
    short mSubframes = 0;
    short mSubframeDivisor = 0;
    uint mCounter = 0;
    uint mType = 0;
    uint mFlags = 0;
    short mHours = 0;
    short mMinutes = 0;
    short mSeconds = 0;
    short mFrames = 0;
}

/**
 * High-resolution CoreAudio timestamp descriptor matching C AudioTimeStamp.
 */
struct AudioTimeStamp {
    double mSampleTime = 0.0;
    ulong mHostTime = 0;
    double mRateScalar = 0.0;
    ulong mWordClockTime = 0;
    SMPTETime mSMPTETime;
    uint mFlags = 0;
    uint mReserved = 0;
}

/**
 * AudioComponent lookup descriptor matching C AudioComponentDescription.
 */
struct AudioComponentDescription {
    uint componentType = 0;
    uint componentSubType = 0;
    uint componentManufacturer = 0;
    uint componentFlags = 0;
    uint componentFlagsMask = 0;
}

alias AURenderCallback = extern(C) OSStatus function(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const(AudioTimeStamp)* inTimeStamp,
    uint inBusNumber,
    uint inNumberFrames,
    AudioBufferList* ioData
) @nogc nothrow;

/**
 * CoreAudio AudioUnit callback registration structure matching AURenderCallbackStruct.
 */
struct AURenderCallbackStruct {
    AURenderCallback inputProc = null;
    void* inputProcRefCon = null;
}

alias AudioObjectPropertyListenerProc = extern(C) OSStatus function(
    AudioObjectID inObjectID,
    uint inNumberAddresses,
    const(AudioObjectPropertyAddress)* inAddresses,
    void* inClientData
) @nogc nothrow;

static assert(AudioObjectPropertyAddress.sizeof == 12);
static assert(AudioValueRange.sizeof == 16);
static assert(AudioStreamBasicDescription.sizeof == 40);
static assert(AudioBuffer.sizeof == 16 && AudioBuffer.mData.offsetof == 8);
static assert(AudioBufferList.sizeof == 24 && AudioBufferList.mBuffers.offsetof == 8);
static assert(AudioBufferList2.sizeof == 40 && AudioBufferList2.mBuffers.offsetof == 8);
static assert(SMPTETime.sizeof == 24);
static assert(AudioTimeStamp.sizeof == 64 && AudioTimeStamp.mSMPTETime.offsetof == 32 && AudioTimeStamp.mFlags.offsetof == 56);
static assert(AudioComponentDescription.sizeof == 20);
static assert(AURenderCallbackStruct.sizeof == 16);

extern(C) @nogc nothrow {
    ubyte AudioObjectHasProperty(AudioObjectID inObjectID, const(AudioObjectPropertyAddress)* inAddress);
    OSStatus AudioObjectIsPropertySettable(
        AudioObjectID inObjectID,
        const(AudioObjectPropertyAddress)* inAddress,
        ubyte* outIsSettable
    );
    OSStatus AudioObjectGetPropertyDataSize(
        AudioObjectID inObjectID,
        const(AudioObjectPropertyAddress)* inAddress,
        uint inQualifierDataSize,
        const(void)* inQualifierData,
        uint* outDataSize
    );
    OSStatus AudioObjectGetPropertyData(
        AudioObjectID inObjectID,
        const(AudioObjectPropertyAddress)* inAddress,
        uint inQualifierDataSize,
        const(void)* inQualifierData,
        uint* ioDataSize,
        void* outData
    );
    OSStatus AudioObjectSetPropertyData(
        AudioObjectID inObjectID,
        const(AudioObjectPropertyAddress)* inAddress,
        uint inQualifierDataSize,
        const(void)* inQualifierData,
        uint inDataSize,
        const(void)* inData
    );
    OSStatus AudioObjectAddPropertyListener(
        AudioObjectID inObjectID,
        const(AudioObjectPropertyAddress)* inAddress,
        AudioObjectPropertyListenerProc inListener,
        void* inClientData
    );
    OSStatus AudioObjectRemovePropertyListener(
        AudioObjectID inObjectID,
        const(AudioObjectPropertyAddress)* inAddress,
        AudioObjectPropertyListenerProc inListener,
        void* inClientData
    );

    AudioComponent AudioComponentFindNext(
        AudioComponent inComponent,
        const(AudioComponentDescription)* inDesc
    );
    OSStatus AudioComponentInstanceNew(
        AudioComponent inComponent,
        AudioComponentInstance* outInstance
    );
    OSStatus AudioComponentInstanceDispose(AudioComponentInstance inInstance);

    OSStatus AudioUnitInitialize(AudioUnit inUnit);
    OSStatus AudioUnitUninitialize(AudioUnit inUnit);
    OSStatus AudioUnitSetProperty(
        AudioUnit inUnit,
        AudioUnitPropertyID inID,
        AudioUnitScope inScope,
        AudioUnitElement inElement,
        const(void)* inData,
        uint inDataSize
    );
    OSStatus AudioUnitGetProperty(
        AudioUnit inUnit,
        AudioUnitPropertyID inID,
        AudioUnitScope inScope,
        AudioUnitElement inElement,
        void* outData,
        uint* ioDataSize
    );
    OSStatus AudioUnitRender(
        AudioUnit inUnit,
        AudioUnitRenderActionFlags* ioActionFlags,
        const(AudioTimeStamp)* inTimeStamp,
        uint inOutputBusNumber,
        uint inNumberFrames,
        AudioBufferList* ioData
    );
    OSStatus AudioOutputUnitStart(AudioUnit ci);
    OSStatus AudioOutputUnitStop(AudioUnit ci);
}

/**
 * Unmanaged @nogc state structure passed cleanly as C refCon to CoreAudio callbacks and listeners.
 *
 * Strictly forbids GC-managed references so unregistered CoreAudio Mach RT threads never trigger
 * GC scans, _tlv_get_addr allocations, or write barriers.
 */
struct CoreAudioRtContext {
    AudioRenderCallback userCallback = null;
    void* userData = null;

    AudioUnit outputUnit = null;
    AudioUnit inputUnit = null;
    AudioDeviceID outputDeviceId = kAudioObjectUnknown;
    AudioDeviceID inputDeviceId = kAudioObjectUnknown;
    uint inputHardwareChannels = 0;

    uint maxFramesPerSlice = 4096;
    uint activeBufferFrames = 128;
    double activeSampleRate = 44_100.0;
    double inputSampleRate = 44_100.0;

    Atomic!int active;
    Atomic!int duplexMode;
    Atomic!ulong callbackCount;
    Atomic!ulong framesRendered;
    Atomic!ulong xrunCount;
    Atomic!size_t lastRtThreadId;
    Atomic!int lastDenormalsEnabled;

    MachTimebase timebase;
    ulong lastCallbackHostTime = 0;
    double expectedCallbackNanos = 0.0;

    OwnedBuffer!float outScratchL;
    OwnedBuffer!float outScratchR;
    OwnedBuffer!float inScratchL;
    OwnedBuffer!float inScratchR;
    OwnedBuffer!float dualInScratchL;
    OwnedBuffer!float dualInScratchR;

    DriftCompensatedInputRing inputRing;
    MpscRing!AudioNotification notifRing;

    @disable this(this);

    @nogc nothrow:

    /**
     * Releases all @nogc OwnedBuffer and ring allocations held by this RT context.
     */
    void releaseBuffers() {
        active.store(0);
        inputRing.destroy();
        notifRing.reset();
        outScratchL.reset();
        outScratchR.reset();
        inScratchL.reset();
        inScratchR.reset();
        dualInScratchL.reset();
        dualInScratchR.reset();
    }
}

static assert(!hasGcReference!CoreAudioRtContext,
    "CoreAudioRtContext passed to unregistered RT threads must have zero GC references");

private void zeroAudioBufferList(AudioBufferList* ioData) @nogc nothrow {
    if (ioData is null) {
        return;
    }
    AudioBuffer* bufs = ioData.mBuffers.ptr;
    foreach (i; 0 .. ioData.mNumberBuffers) {
        if (bufs[i].mData !is null && bufs[i].mDataByteSize > 0) {
            memset(bufs[i].mData, 0, bufs[i].mDataByteSize);
        }
    }
}

private void writeAudioBufferList(
    AudioBufferList* ioData,
    const(float)* srcL,
    const(float)* srcR,
    uint frames
) @nogc nothrow {
    if (ioData is null || ioData.mNumberBuffers == 0 || frames == 0) {
        return;
    }
    AudioBuffer* bufs = ioData.mBuffers.ptr;
    immutable uint nBufs = ioData.mNumberBuffers;

    if (nBufs >= 2) {
        if (bufs[0].mData !is null && bufs[0].mDataByteSize >= frames * float.sizeof) {
            auto dstL = cast(float*) bufs[0].mData;
            foreach (i; 0 .. frames) {
                immutable float s = srcL[i];
                dstL[i] = isFinite(s) ? s : 0.0f;
            }
        }
        if (bufs[1].mData !is null && bufs[1].mDataByteSize >= frames * float.sizeof) {
            auto dstR = cast(float*) bufs[1].mData;
            foreach (i; 0 .. frames) {
                immutable float s = srcR[i];
                dstR[i] = isFinite(s) ? s : 0.0f;
            }
        }
        foreach (b; 2 .. nBufs) {
            if (bufs[b].mData !is null && bufs[b].mDataByteSize > 0) {
                memset(bufs[b].mData, 0, bufs[b].mDataByteSize);
            }
        }
        return;
    }

    auto dst = cast(float*) bufs[0].mData;
    if (dst is null) {
        return;
    }
    immutable uint chans = bufs[0].mNumberChannels == 0 ? 1 : bufs[0].mNumberChannels;
    if (bufs[0].mDataByteSize < frames * chans * float.sizeof) {
        return;
    }
    if (chans == 1) {
        foreach (i; 0 .. frames) {
            immutable float l = isFinite(srcL[i]) ? srcL[i] : 0.0f;
            immutable float r = isFinite(srcR[i]) ? srcR[i] : 0.0f;
            dst[i] = 0.5f * (l + r);
        }
    } else {
        foreach (i; 0 .. frames) {
            immutable float l = isFinite(srcL[i]) ? srcL[i] : 0.0f;
            immutable float r = isFinite(srcR[i]) ? srcR[i] : 0.0f;
            immutable size_t base = i * chans;
            dst[base] = l;
            dst[base + 1] = r;
            foreach (c; 2 .. chans) {
                dst[base + c] = 0.0f;
            }
        }
    }
}

private void renderHardwareInputChunk(
    AudioUnit unit,
    uint channels,
    AudioUnitRenderActionFlags* ioActionFlags,
    const(AudioTimeStamp)* inTimeStamp,
    uint frames,
    float* dstL,
    float* dstR
) @nogc nothrow {
    if (dstL is null || dstR is null || frames == 0) {
        return;
    }
    if (unit is null || channels == 0) {
        memset(dstL, 0, frames * float.sizeof);
        memset(dstR, 0, frames * float.sizeof);
        return;
    }

    AudioBufferList2 abl;
    abl.mNumberBuffers = channels >= 2 ? 2 : 1;
    abl.mBuffers[0].mNumberChannels = 1;
    abl.mBuffers[0].mDataByteSize = frames * cast(uint) float.sizeof;
    abl.mBuffers[0].mData = dstL;
    abl.mBuffers[1].mNumberChannels = 1;
    abl.mBuffers[1].mDataByteSize = frames * cast(uint) float.sizeof;
    abl.mBuffers[1].mData = dstR;

    immutable OSStatus status = AudioUnitRender(
        unit,
        ioActionFlags,
        inTimeStamp,
        1,
        frames,
        cast(AudioBufferList*) &abl
    );
    if (status != noErr) {
        memset(dstL, 0, frames * float.sizeof);
        memset(dstR, 0, frames * float.sizeof);
        return;
    }
    if (channels == 1) {
        memcpy(dstR, dstL, frames * float.sizeof);
    }
}

/**
 * Unregistered-thread CoreAudio AUHAL output render callback entering ScopedNoDenormals.
 */
extern(C) OSStatus auRenderCallback(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const(AudioTimeStamp)* inTimeStamp,
    uint inBusNumber,
    uint inNumberFrames,
    AudioBufferList* ioData
) @nogc nothrow {
    cast(void) inBusNumber;
    auto denormGuard = ScopedNoDenormals.enter();
    cast(void) denormGuard;

    auto ctx = cast(CoreAudioRtContext*) inRefCon;
    if (ctx is null || ioData is null || inNumberFrames == 0) {
        return noErr;
    }

    ctx.lastRtThreadId.store(cast(size_t) pthread_self());
    ctx.lastDenormalsEnabled.store(ScopedNoDenormals.isHardwareNoDenormalsEnabled() ? 1 : 0);

    if (ctx.active.load() == 0 || ctx.userCallback is null
            || ctx.outScratchL.empty() || ctx.outScratchR.empty()) {
        zeroAudioBufferList(ioData);
        if (ioActionFlags !is null) {
            *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        return noErr;
    }

    if (inTimeStamp !is null && (inTimeStamp.mFlags & kAudioTimeStampHostTimeValid) != 0) {
        if (ctx.lastCallbackHostTime != 0 && ctx.expectedCallbackNanos > 0.0
                && inTimeStamp.mHostTime > ctx.lastCallbackHostTime) {
            immutable ulong dtTicks = inTimeStamp.mHostTime - ctx.lastCallbackHostTime;
            immutable double dtNanos = cast(double) ctx.timebase.ticksToNanos(dtTicks);
            immutable double threshold = ctx.expectedCallbackNanos * 2.5 + 4_000_000.0;
            if (dtNanos > threshold) {
                ctx.xrunCount.fetchAdd(1);
            }
        }
        ctx.lastCallbackHostTime = inTimeStamp.mHostTime;
    }

    immutable uint maxSlice = ctx.maxFramesPerSlice > 0 ? ctx.maxFramesPerSlice : 4096;
    immutable int dMode = ctx.duplexMode.load();
    uint offset = 0;

    while (offset < inNumberFrames) {
        immutable uint rem = inNumberFrames - offset;
        immutable uint chunk = rem > maxSlice ? maxSlice : rem;

        const(float)* inL = null;
        const(float)* inR = null;
        if (dMode == 1 && !ctx.inScratchL.empty() && !ctx.inScratchR.empty()) {
            renderHardwareInputChunk(
                ctx.outputUnit,
                ctx.inputHardwareChannels,
                ioActionFlags,
                inTimeStamp,
                chunk,
                ctx.inScratchL.ptr,
                ctx.inScratchR.ptr
            );
            inL = ctx.inScratchL.ptr;
            inR = ctx.inScratchR.ptr;
        } else if (dMode == 2 && !ctx.inScratchL.empty() && !ctx.inScratchR.empty()) {
            ctx.inputRing.pullResampled(ctx.inScratchL.ptr, ctx.inScratchR.ptr, chunk);
            inL = ctx.inScratchL.ptr;
            inR = ctx.inScratchR.ptr;
        }

        ctx.userCallback(
            ctx.userData,
            inL,
            inR,
            ctx.outScratchL.ptr + offset,
            ctx.outScratchR.ptr + offset,
            chunk
        );
        offset += chunk;
    }

    if (inNumberFrames <= ctx.outScratchL.length) {
        writeAudioBufferList(ioData, ctx.outScratchL.ptr, ctx.outScratchR.ptr, inNumberFrames);
    } else {
        zeroAudioBufferList(ioData);
    }

    ctx.callbackCount.fetchAdd(1);
    ctx.framesRendered.fetchAdd(inNumberFrames);
    return noErr;
}

/**
 * Secondary CoreAudio input AUHAL callback pushing frames into DriftCompensatedInputRing.
 */
extern(C) OSStatus auInputCallback(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const(AudioTimeStamp)* inTimeStamp,
    uint inBusNumber,
    uint inNumberFrames,
    AudioBufferList* ioData
) @nogc nothrow {
    cast(void) inBusNumber;
    cast(void) ioData;
    auto denormGuard = ScopedNoDenormals.enter();
    cast(void) denormGuard;

    auto ctx = cast(CoreAudioRtContext*) inRefCon;
    if (ctx is null || ctx.active.load() == 0 || ctx.inputUnit is null
            || ctx.dualInScratchL.empty() || ctx.dualInScratchR.empty()) {
        return noErr;
    }

    immutable uint maxSlice = ctx.maxFramesPerSlice > 0 ? ctx.maxFramesPerSlice : 4096;
    immutable uint chunk = inNumberFrames > maxSlice ? maxSlice : inNumberFrames;

    renderHardwareInputChunk(
        ctx.inputUnit,
        ctx.inputHardwareChannels,
        ioActionFlags,
        inTimeStamp,
        chunk,
        ctx.dualInScratchL.ptr,
        ctx.dualInScratchR.ptr
    );
    ctx.inputRing.pushStereo(ctx.dualInScratchL.ptr, ctx.dualInScratchR.ptr, chunk);
    return noErr;
}

/**
 * CoreAudio HAL hardware property listener forwarding hot-plug/rate changes via lock-free MPSC queue.
 */
extern(C) OSStatus auPropertyListener(
    AudioObjectID inObjectID,
    uint inNumberAddresses,
    const(AudioObjectPropertyAddress)* inAddresses,
    void* inClientData
) @nogc nothrow {
    auto ctx = cast(CoreAudioRtContext*) inClientData;
    if (ctx is null || inAddresses is null || inNumberAddresses == 0) {
        return noErr;
    }

    foreach (i; 0 .. inNumberAddresses) {
        immutable AudioObjectPropertySelector sel = inAddresses[i].mSelector;
        AudioNotification notif;
        notif.deviceId = inObjectID;

        if (sel == kAudioHardwarePropertyDevices) {
            notif.kind = AudioNotificationKind.deviceListChanged;
        } else if (sel == kAudioHardwarePropertyDefaultOutputDevice) {
            notif.kind = AudioNotificationKind.defaultOutputChanged;
        } else if (sel == kAudioHardwarePropertyDefaultInputDevice) {
            notif.kind = AudioNotificationKind.defaultInputChanged;
        } else if (sel == kAudioDevicePropertyNominalSampleRate) {
            notif.kind = AudioNotificationKind.sampleRateChanged;
            double sr = 0.0;
            uint sz = double.sizeof;
            AudioObjectPropertyAddress queryAddr = AudioObjectPropertyAddress(
                kAudioDevicePropertyNominalSampleRate,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            );
            if (AudioObjectGetPropertyData(inObjectID, &queryAddr, 0, null, &sz, &sr) == noErr) {
                notif.newSampleRate = sr;
            }
        } else if (sel == kAudioDevicePropertyBufferFrameSize) {
            notif.kind = AudioNotificationKind.bufferSizeChanged;
            uint bFrames = 0;
            uint sz = uint.sizeof;
            AudioObjectPropertyAddress queryAddr = AudioObjectPropertyAddress(
                kAudioDevicePropertyBufferFrameSize,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            );
            if (AudioObjectGetPropertyData(inObjectID, &queryAddr, 0, null, &sz, &bFrames) == noErr) {
                notif.newBufferFrames = bFrames;
            }
        } else if (sel == kAudioDevicePropertyDeviceIsAlive) {
            uint alive = 1;
            uint sz = uint.sizeof;
            AudioObjectPropertyAddress queryAddr = AudioObjectPropertyAddress(
                kAudioDevicePropertyDeviceIsAlive,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            );
            if (AudioObjectGetPropertyData(inObjectID, &queryAddr, 0, null, &sz, &alive) == noErr
                    && alive == 0) {
                ctx.active.store(0);
                notif.kind = AudioNotificationKind.deviceDisconnected;
            } else {
                continue;
            }
        } else {
            continue;
        }

        ctx.notifRing.tryPush(notif);
    }
    return noErr;
}

/**
 * macOS CoreAudio HALOutput (AUHAL) implementation of IAudioDriver.
 *
 * Supports low-latency stereo output, single-device direct duplex I/O, and dual-device
 * drift-compensated resampled input with lock-free hot-plug/rate change handling.
 */
class CoreAudioDriver : IAudioDriver {
    private struct ListenerReg {
        AudioObjectID objectId = kAudioObjectUnknown;
        AudioObjectPropertyAddress addr;
    }

    private CoreAudioRtContext* rtCtx_ = null;
    private AudioStreamConfig lastConfig_;
    private AudioRenderCallback lastCallback_ = null;
    private void* lastUserData_ = null;
    private ListenerReg[] listeners_;
    private bool opened_ = false;
    private bool running_ = false;

    /**
     * Releases all CoreAudio units, property listeners, and unmanaged RT context on teardown.
     */
    ~this() {
        close();
    }

    /**
     * Enumerates active CoreAudio hardware devices and their channel, sample rate, and buffer capabilities.
     *
     * Returns:
     *   Array of AudioDeviceInfo structs describing available macOS audio endpoints.
     */
    override AudioDeviceInfo[] enumerateDevices() {
        AudioDeviceID defOut = queryDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice);
        AudioDeviceID defIn = queryDefaultDevice(kAudioHardwarePropertyDefaultInputDevice);

        AudioObjectPropertyAddress devsAddr = AudioObjectPropertyAddress(
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        );
        uint byteSize = 0;
        if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devsAddr, 0, null, &byteSize) != noErr
                || byteSize < AudioDeviceID.sizeof) {
            return null;
        }

        immutable size_t count = byteSize / AudioDeviceID.sizeof;
        auto ids = new AudioDeviceID[count];
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &devsAddr, 0, null, &byteSize, ids.ptr) != noErr) {
            return null;
        }

        immutable size_t actualCount = byteSize / AudioDeviceID.sizeof;
        AudioDeviceInfo[] result;
        result.reserve(actualCount);

        foreach (devId; ids[0 .. actualCount]) {
            AudioDeviceInfo info;
            info.id = devId;
            info.name = queryDeviceStringProperty(devId, kAudioObjectPropertyName);
            info.uid = queryDeviceStringProperty(devId, kAudioDevicePropertyDeviceUID);
            info.inputChannels = queryChannelCount(devId, kAudioObjectPropertyScopeInput);
            info.outputChannels = queryChannelCount(devId, kAudioObjectPropertyScopeOutput);
            info.nominalSampleRate = queryNominalSampleRate(devId);
            info.supportedSampleRates = querySupportedSampleRates(devId, info.nominalSampleRate);
            queryBufferSizeRange(devId, info.minBufferFrames, info.maxBufferFrames);
            info.isDefaultOutput = (devId == defOut);
            info.isDefaultInput = (devId == defIn);
            result ~= info;
        }
        return result;
    }

    /**
     * Initializes AUHAL hardware output and optional direct or drift-resampled duplex input.
     *
     * Params:
     *   config = Requested device IDs, sample rate, buffer frame size, and duplex options.
     *   callback = @nogc nothrow render callback executed on unregistered RT thread.
     *   userData = Opaque @nogc context pointer forwarded to callback.
     *
     * Returns:
     *   True if AUHAL hardware initialization succeeded.
     */
    override bool open(const ref AudioStreamConfig config, AudioRenderCallback callback, void* userData) {
        close();
        if (callback is null) {
            return false;
        }

        AudioDeviceID outDev = config.outputDeviceId != 0
            ? config.outputDeviceId
            : queryDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice);
        if (outDev == kAudioObjectUnknown) {
            return false;
        }

        AudioDeviceID inDev = kAudioObjectUnknown;
        bool wantInput = config.enableInput;
        if (wantInput) {
            inDev = config.inputDeviceId != 0
                ? config.inputDeviceId
                : queryDefaultDevice(kAudioHardwarePropertyDefaultInputDevice);
            if (inDev == kAudioObjectUnknown || queryChannelCount(inDev, kAudioObjectPropertyScopeInput) == 0) {
                wantInput = false;
                inDev = kAudioObjectUnknown;
            }
        }

        auto ctx = cast(CoreAudioRtContext*) calloc(1, CoreAudioRtContext.sizeof);
        if (ctx is null) {
            return false;
        }
        emplace(ctx);

        immutable uint maxSlice = config.bufferFrames > 4096 ? config.bufferFrames : 4096;
        if (!OwnedBuffer!float.tryAllocate(maxSlice, ctx.outScratchL)
                || !OwnedBuffer!float.tryAllocate(maxSlice, ctx.outScratchR)
                || !OwnedBuffer!float.tryAllocate(maxSlice, ctx.inScratchL)
                || !OwnedBuffer!float.tryAllocate(maxSlice, ctx.inScratchR)
                || !OwnedBuffer!float.tryAllocate(maxSlice, ctx.dualInScratchL)
                || !OwnedBuffer!float.tryAllocate(maxSlice, ctx.dualInScratchR)
                || !MpscRing!AudioNotification.tryCreate(64, ctx.notifRing)) {
            ctx.releaseBuffers();
            destroy!false(*ctx);
            free(ctx);
            return false;
        }

        ctx.userCallback = callback;
        ctx.userData = userData;
        ctx.outputDeviceId = outDev;
        ctx.inputDeviceId = inDev;
        ctx.maxFramesPerSlice = maxSlice;
        ctx.timebase = MachTimebase.query();
        rtCtx_ = ctx;

        immutable double desiredRate = (isFinite(config.sampleRate) && config.sampleRate >= 8000.0)
            ? config.sampleRate : 44_100.0;
        immutable uint desiredBuf = config.bufferFrames >= 32 ? config.bufferFrames : 128;

        negotiateSampleRate(outDev, desiredRate);
        negotiateBufferFrames(outDev, desiredBuf);

        immutable double actualOutRate = queryNominalSampleRate(outDev);
        immutable uint actualOutBuf = queryBufferFrames(outDev, desiredBuf);
        ctx.activeSampleRate = actualOutRate > 0.0 ? actualOutRate : desiredRate;
        ctx.activeBufferFrames = actualOutBuf > 0 ? actualOutBuf : desiredBuf;
        ctx.expectedCallbackNanos = (cast(double) ctx.activeBufferFrames / ctx.activeSampleRate) * 1.0e9;

        bool configured = false;
        if (wantInput && inDev == outDev) {
            if (setupSameDeviceDirectDuplex(ctx, outDev, ctx.activeSampleRate, maxSlice)) {
                ctx.duplexMode.store(1);
                configured = true;
            }
        }

        if (!configured) {
            if (!setupOutputOnlyUnit(ctx, outDev, ctx.activeSampleRate, maxSlice)) {
                close();
                return false;
            }
            ctx.duplexMode.store(0);

            if (wantInput && inDev != kAudioObjectUnknown) {
                negotiateSampleRate(inDev, desiredRate);
                immutable double inRate = queryNominalSampleRate(inDev);
                ctx.inputSampleRate = inRate > 0.0 ? inRate : ctx.activeSampleRate;
                immutable uint targetFill = ctx.activeBufferFrames * 4 >= 256
                    ? ctx.activeBufferFrames * 4 : 256;
                if (ctx.inputRing.tryInit(ctx.inputSampleRate, ctx.activeSampleRate, targetFill, 8192)
                        && setupDedicatedInputUnit(ctx, inDev, ctx.inputSampleRate, maxSlice)) {
                    ctx.duplexMode.store(2);
                } else {
                    ctx.inputRing.destroy();
                }
            }
        }

        registerPropertyListeners(outDev, inDev);
        lastConfig_ = config;
        lastCallback_ = callback;
        lastUserData_ = userData;
        opened_ = true;
        running_ = false;
        return true;
    }

    /**
     * Starts CoreAudio hardware I/O callbacks on the configured output (and input) units.
     *
     * Returns:
     *   True if AudioOutputUnitStart succeeded.
     */
    override bool start() {
        if (!opened_ || rtCtx_ is null || rtCtx_.outputUnit is null) {
            return false;
        }
        if (running_) {
            return true;
        }

        rtCtx_.lastCallbackHostTime = 0;
        rtCtx_.active.store(1);

        if (rtCtx_.inputUnit !is null) {
            immutable OSStatus inSt = AudioOutputUnitStart(rtCtx_.inputUnit);
            if (inSt != noErr) {
                rtCtx_.duplexMode.store(0);
            }
        }

        immutable OSStatus outSt = AudioOutputUnitStart(rtCtx_.outputUnit);
        if (outSt != noErr) {
            if (rtCtx_.inputUnit !is null) {
                AudioOutputUnitStop(rtCtx_.inputUnit);
            }
            rtCtx_.active.store(0);
            return false;
        }

        running_ = true;
        return true;
    }

    /**
     * Stops active CoreAudio hardware callbacks cleanly without releasing AUHAL configuration.
     */
    override void stop() {
        if (rtCtx_ !is null) {
            rtCtx_.active.store(0);
            if (rtCtx_.outputUnit !is null) {
                AudioOutputUnitStop(rtCtx_.outputUnit);
            }
            if (rtCtx_.inputUnit !is null) {
                AudioOutputUnitStop(rtCtx_.inputUnit);
            }
        }
        running_ = false;
    }

    /**
     * Stops hardware callbacks, removes listeners, disposes AudioUnits, and frees @nogc RT context.
     */
    override void close() {
        stop();
        unregisterPropertyListeners();

        if (rtCtx_ !is null) {
            if (rtCtx_.outputUnit !is null) {
                AudioUnitUninitialize(rtCtx_.outputUnit);
                AudioComponentInstanceDispose(rtCtx_.outputUnit);
                rtCtx_.outputUnit = null;
            }
            if (rtCtx_.inputUnit !is null) {
                AudioUnitUninitialize(rtCtx_.inputUnit);
                AudioComponentInstanceDispose(rtCtx_.inputUnit);
                rtCtx_.inputUnit = null;
            }
            rtCtx_.releaseBuffers();
            destroy!false(*rtCtx_);
            free(rtCtx_);
            rtCtx_ = null;
        }
        opened_ = false;
        running_ = false;
    }

    /**
     * Reports whether the hardware driver is currently running.
     *
     * Returns:
     *   True if start() has succeeded and stop()/close() has not been invoked.
     */
    override bool isRunning() const {
        return running_;
    }

    /**
     * Returns the hardware-negotiated active output sample rate in Hertz.
     *
     * Returns:
     *   Sample rate in Hertz.
     */
    override double activeSampleRate() const {
        return rtCtx_ !is null ? rtCtx_.activeSampleRate : 44_100.0;
    }

    /**
     * Returns the hardware-negotiated buffer frame count.
     *
     * Returns:
     *   Buffer size in frames.
     */
    override uint activeBufferFrames() const {
        return rtCtx_ !is null ? rtCtx_.activeBufferFrames : 0;
    }

    /**
     * Reads lock-free telemetry counters and duplex/resampler status from the active RT context.
     *
     * Returns:
     *   AudioDriverStats snapshot.
     */
    override AudioDriverStats stats() const {
        AudioDriverStats st;
        if (rtCtx_ is null) {
            return st;
        }
        immutable int dMode = rtCtx_.duplexMode.load();
        st.callbackCount = rtCtx_.callbackCount.load();
        st.framesRendered = rtCtx_.framesRendered.load();
        st.xrunCount = rtCtx_.xrunCount.load();
        st.inputOverrunCount = rtCtx_.inputRing.overrunCount();
        st.inputUnderrunCount = rtCtx_.inputRing.underrunCount();
        st.activeSampleRate = rtCtx_.activeSampleRate;
        st.activeBufferFrames = rtCtx_.activeBufferFrames;
        st.resampleRatio = dMode == 2 ? rtCtx_.inputRing.currentRatio() : 1.0;
        st.lastRtThreadId = rtCtx_.lastRtThreadId.load();
        st.running = running_;
        st.duplexDirect = (dMode == 1);
        st.duplexResampled = (dMode == 2);
        st.denormalsSuppressedInCallback = rtCtx_.lastDenormalsEnabled.load() != 0;
        return st;
    }

    /**
     * Polls one hardware notification emitted by CoreAudio property listeners.
     *
     * Params:
     *   outNotif = Destination AudioNotification populated on return.
     *
     * Returns:
     *   True if a notification was available; false otherwise.
     */
    override bool pollNotification(out AudioNotification outNotif) @nogc nothrow {
        if (rtCtx_ is null) {
            return false;
        }
        return rtCtx_.notifRing.tryPop(outNotif);
    }

    /**
     * Reconciles stream configuration cleanly after device hot-unplug, default change, or rate change.
     *
     * Returns:
     *   True if the driver recovered or remains valid.
     */
    override bool handleDeviceChange() {
        if (!opened_ || rtCtx_ is null || lastCallback_ is null) {
            return false;
        }

        bool needReopen = false;
        AudioNotification notif;
        while (pollNotification(notif)) {
            if (notif.kind == AudioNotificationKind.deviceDisconnected
                    || notif.kind == AudioNotificationKind.defaultOutputChanged
                    || notif.kind == AudioNotificationKind.sampleRateChanged
                    || notif.kind == AudioNotificationKind.bufferSizeChanged
                    || notif.kind == AudioNotificationKind.defaultInputChanged) {
                needReopen = true;
            }
        }

        if (!needReopen && isDeviceAlive(rtCtx_.outputDeviceId)) {
            return true;
        }

        immutable bool wasRunning = running_;
        AudioStreamConfig nextCfg = lastConfig_;
        if (nextCfg.outputDeviceId != 0 && !isDeviceAlive(nextCfg.outputDeviceId)) {
            nextCfg.outputDeviceId = 0;
        }
        if (nextCfg.enableInput && nextCfg.inputDeviceId != 0 && !isDeviceAlive(nextCfg.inputDeviceId)) {
            nextCfg.inputDeviceId = 0;
        }

        if (!open(nextCfg, lastCallback_, lastUserData_)) {
            return false;
        }
        if (wasRunning) {
            return start();
        }
        return true;
    }

    /**
     * Invokes auRenderCallback directly on an unmanaged CoreAudioRtContext for unit/RT-trap testing.
     *
     * Params:
     *   ctx = Pre-initialized unmanaged CoreAudioRtContext*.
     *   frames = Frame count for this simulated callback slice.
     *   ioData = Output AudioBufferList populated by the callback.
     *   ioActionFlags = Optional action flags receiving silence flag when inactive.
     *   ts = Optional host AudioTimeStamp pointer.
     *
     * Returns:
     *   OSStatus returned by auRenderCallback.
     */
    static OSStatus invokeRenderCallbackForTest(
        CoreAudioRtContext* ctx,
        uint frames,
        AudioBufferList* ioData,
        AudioUnitRenderActionFlags* ioActionFlags = null,
        const(AudioTimeStamp)* ts = null
    ) @nogc nothrow {
        return auRenderCallback(ctx, ioActionFlags, ts, 0, frames, ioData);
    }

    private AudioUnit createHalAudioUnit() @nogc nothrow {
        AudioComponentDescription desc;
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_HALOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        AudioComponent comp = AudioComponentFindNext(null, &desc);
        if (comp is null) {
            return null;
        }
        AudioUnit unit = null;
        if (AudioComponentInstanceNew(comp, &unit) != noErr || unit is null) {
            return null;
        }
        return unit;
    }

    private AudioStreamBasicDescription makeNonInterleavedStereoAsbd(double sampleRate, uint channels) const @nogc nothrow {
        AudioStreamBasicDescription asbd;
        asbd.mSampleRate = sampleRate;
        asbd.mFormatID = kAudioFormatLinearPCM;
        asbd.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
        asbd.mBytesPerPacket = float.sizeof;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerFrame = float.sizeof;
        asbd.mChannelsPerFrame = channels;
        asbd.mBitsPerChannel = 32;
        return asbd;
    }

    private bool setupOutputOnlyUnit(
        CoreAudioRtContext* ctx,
        AudioDeviceID outDev,
        double sampleRate,
        uint maxSlice
    ) @nogc nothrow {
        AudioUnit unit = createHalAudioUnit();
        if (unit is null) {
            return false;
        }

        uint enableOut = 1;
        uint disableIn = 0;
        if (AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOut, enableOut.sizeof) != noErr
                || AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableIn, disableIn.sizeof) != noErr
                || AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outDev, outDev.sizeof) != noErr) {
            AudioComponentInstanceDispose(unit);
            return false;
        }

        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxSlice, maxSlice.sizeof);

        AudioStreamBasicDescription asbd = makeNonInterleavedStereoAsbd(sampleRate, 2);
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, asbd.sizeof) != noErr) {
            AudioComponentInstanceDispose(unit);
            return false;
        }

        AURenderCallbackStruct cb = AURenderCallbackStruct(&auRenderCallback, ctx);
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, cb.sizeof) != noErr
                || AudioUnitInitialize(unit) != noErr) {
            AudioComponentInstanceDispose(unit);
            return false;
        }

        ctx.outputUnit = unit;
        return true;
    }

    private bool setupSameDeviceDirectDuplex(
        CoreAudioRtContext* ctx,
        AudioDeviceID devId,
        double sampleRate,
        uint maxSlice
    ) @nogc nothrow {
        AudioUnit unit = createHalAudioUnit();
        if (unit is null) {
            return false;
        }

        uint enable = 1;
        if (AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, enable.sizeof) != noErr
                || AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, enable.sizeof) != noErr
                || AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devId, devId.sizeof) != noErr) {
            AudioComponentInstanceDispose(unit);
            return false;
        }

        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxSlice, maxSlice.sizeof);

        AudioStreamBasicDescription outAsbd = makeNonInterleavedStereoAsbd(sampleRate, 2);
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outAsbd, outAsbd.sizeof) != noErr) {
            AudioComponentInstanceDispose(unit);
            return false;
        }

        uint inChans = 2;
        AudioStreamBasicDescription inAsbd = makeNonInterleavedStereoAsbd(sampleRate, 2);
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inAsbd, inAsbd.sizeof) != noErr) {
            inChans = 1;
            inAsbd = makeNonInterleavedStereoAsbd(sampleRate, 1);
            if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inAsbd, inAsbd.sizeof) != noErr) {
                AudioComponentInstanceDispose(unit);
                return false;
            }
        }

        AURenderCallbackStruct cb = AURenderCallbackStruct(&auRenderCallback, ctx);
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, cb.sizeof) != noErr
                || AudioUnitInitialize(unit) != noErr) {
            AudioComponentInstanceDispose(unit);
            return false;
        }

        ctx.inputHardwareChannels = inChans;
        ctx.outputUnit = unit;
        return true;
    }

    private bool setupDedicatedInputUnit(
        CoreAudioRtContext* ctx,
        AudioDeviceID inDev,
        double sampleRate,
        uint maxSlice
    ) @nogc nothrow {
        AudioUnit unit = createHalAudioUnit();
        if (unit is null) {
            return false;
        }

        uint disableOut = 0;
        uint enableIn = 1;
        if (AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOut, disableOut.sizeof) != noErr
                || AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIn, enableIn.sizeof) != noErr
                || AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inDev, inDev.sizeof) != noErr) {
            AudioComponentInstanceDispose(unit);
            return false;
        }

        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxSlice, maxSlice.sizeof);

        uint inChans = 2;
        AudioStreamBasicDescription inAsbd = makeNonInterleavedStereoAsbd(sampleRate, 2);
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inAsbd, inAsbd.sizeof) != noErr) {
            inChans = 1;
            inAsbd = makeNonInterleavedStereoAsbd(sampleRate, 1);
            if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inAsbd, inAsbd.sizeof) != noErr) {
                AudioComponentInstanceDispose(unit);
                return false;
            }
        }

        AURenderCallbackStruct cb = AURenderCallbackStruct(&auInputCallback, ctx);
        if (AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, cb.sizeof) != noErr
                || AudioUnitInitialize(unit) != noErr) {
            AudioComponentInstanceDispose(unit);
            return false;
        }

        ctx.inputHardwareChannels = inChans;
        ctx.inputUnit = unit;
        return true;
    }

    private void addListener(AudioObjectID objId, AudioObjectPropertySelector sel) {
        if (rtCtx_ is null) {
            return;
        }
        AudioObjectPropertyAddress addr = AudioObjectPropertyAddress(
            sel,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        );
        if (AudioObjectHasProperty(objId, &addr) != 0) {
            if (AudioObjectAddPropertyListener(objId, &addr, &auPropertyListener, rtCtx_) == noErr) {
                listeners_ ~= ListenerReg(objId, addr);
            }
        }
    }

    private void registerPropertyListeners(AudioDeviceID outDev, AudioDeviceID inDev) {
        addListener(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
        addListener(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice);
        addListener(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice);

        if (outDev != kAudioObjectUnknown) {
            addListener(outDev, kAudioDevicePropertyNominalSampleRate);
            addListener(outDev, kAudioDevicePropertyBufferFrameSize);
            addListener(outDev, kAudioDevicePropertyDeviceIsAlive);
        }
        if (inDev != kAudioObjectUnknown && inDev != outDev) {
            addListener(inDev, kAudioDevicePropertyNominalSampleRate);
            addListener(inDev, kAudioDevicePropertyBufferFrameSize);
            addListener(inDev, kAudioDevicePropertyDeviceIsAlive);
        }
    }

    private void unregisterPropertyListeners() {
        if (rtCtx_ !is null) {
            foreach (ref reg; listeners_) {
                AudioObjectRemovePropertyListener(reg.objectId, &reg.addr, &auPropertyListener, rtCtx_);
            }
        }
        listeners_.length = 0;
    }

    private static AudioDeviceID queryDefaultDevice(AudioObjectPropertySelector selector) @nogc nothrow {
        AudioDeviceID dev = kAudioObjectUnknown;
        uint sz = dev.sizeof;
        AudioObjectPropertyAddress addr = AudioObjectPropertyAddress(
            selector,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        );
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, null, &sz, &dev) != noErr) {
            return kAudioObjectUnknown;
        }
        return dev;
    }

    private static bool isDeviceAlive(AudioDeviceID devId) @nogc nothrow {
        if (devId == kAudioObjectUnknown) {
            return false;
        }
        AudioObjectPropertyAddress addr = AudioObjectPropertyAddress(
            kAudioDevicePropertyDeviceIsAlive,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        );
        if (AudioObjectHasProperty(devId, &addr) == 0) {
            return false;
        }
        uint alive = 0;
        uint sz = alive.sizeof;
        return AudioObjectGetPropertyData(devId, &addr, 0, null, &sz, &alive) == noErr && alive != 0;
    }

    private static string queryDeviceStringProperty(AudioDeviceID devId, AudioObjectPropertySelector sel) {
        AudioObjectPropertyAddress addr = AudioObjectPropertyAddress(
            sel,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        );
        if (AudioObjectHasProperty(devId, &addr) == 0) {
            return "";
        }
        CFStringRef raw = null;
        uint sz = raw.sizeof;
        if (AudioObjectGetPropertyData(devId, &addr, 0, null, &sz, &raw) != noErr || raw is null) {
            return "";
        }
        ScopedCF!CFStringRef scoped = ScopedCF!CFStringRef(raw);
        return cfStringToDString(scoped.get());
    }

    private static uint queryChannelCount(AudioDeviceID devId, AudioObjectPropertyScope scopeVal) {
        AudioObjectPropertyAddress addr = AudioObjectPropertyAddress(
            kAudioDevicePropertyStreamConfiguration,
            scopeVal,
            kAudioObjectPropertyElementMain
        );
        uint byteSize = 0;
        if (AudioObjectGetPropertyDataSize(devId, &addr, 0, null, &byteSize) != noErr
                || byteSize < AudioBufferList.mNumberBuffers.sizeof) {
            return 0;
        }
        auto buf = new ubyte[byteSize];
        if (AudioObjectGetPropertyData(devId, &addr, 0, null, &byteSize, buf.ptr) != noErr) {
            return 0;
        }
        auto abl = cast(const(AudioBufferList)*) buf.ptr;
        uint total = 0;
        const(AudioBuffer)* arr = abl.mBuffers.ptr;
        foreach (i; 0 .. abl.mNumberBuffers) {
            total += arr[i].mNumberChannels;
        }
        return total;
    }

    private static double queryNominalSampleRate(AudioDeviceID devId) @nogc nothrow {
        AudioObjectPropertyAddress addr = AudioObjectPropertyAddress(
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        );
        double sr = 0.0;
        uint sz = sr.sizeof;
        if (AudioObjectGetPropertyData(devId, &addr, 0, null, &sz, &sr) != noErr || !isFinite(sr)) {
            return 0.0;
        }
        return sr;
    }

    private static double[] querySupportedSampleRates(AudioDeviceID devId, double nominal) {
        static immutable double[4] standardRates = [44_100.0, 48_000.0, 88_200.0, 96_000.0];
        AudioObjectPropertyAddress addr = AudioObjectPropertyAddress(
            kAudioDevicePropertyAvailableNominalSampleRates,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        );
        uint byteSize = 0;
        if (AudioObjectGetPropertyDataSize(devId, &addr, 0, null, &byteSize) != noErr
                || byteSize < AudioValueRange.sizeof) {
            return nominal > 0.0 ? [nominal] : [44_100.0];
        }
        auto ranges = new AudioValueRange[byteSize / AudioValueRange.sizeof];
        if (AudioObjectGetPropertyData(devId, &addr, 0, null, &byteSize, ranges.ptr) != noErr) {
            return nominal > 0.0 ? [nominal] : [44_100.0];
        }

        double[] rates;
        foreach (ref r; ranges) {
            if (fabs(r.mMaximum - r.mMinimum) < 1.0) {
                if (r.mMinimum > 0.0) {
                    rates ~= r.mMinimum;
                }
            } else {
                foreach (sr; standardRates) {
                    if (sr >= r.mMinimum && sr <= r.mMaximum) {
                        rates ~= sr;
                    }
                }
            }
        }
        if (rates.length == 0) {
            return nominal > 0.0 ? [nominal] : [44_100.0];
        }
        return rates;
    }

    private static void queryBufferSizeRange(
        AudioDeviceID devId,
        out uint minFrames,
        out uint maxFrames
    ) @nogc nothrow {
        minFrames = 32;
        maxFrames = 4096;
        AudioObjectPropertyAddress addr = AudioObjectPropertyAddress(
            kAudioDevicePropertyBufferFrameSizeRange,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        );
        if (AudioObjectHasProperty(devId, &addr) == 0) {
            return;
        }
        AudioValueRange range;
        uint sz = range.sizeof;
        if (AudioObjectGetPropertyData(devId, &addr, 0, null, &sz, &range) == noErr
                && isFinite(range.mMinimum) && isFinite(range.mMaximum)
                && range.mMinimum >= 1.0 && range.mMaximum >= range.mMinimum) {
            minFrames = cast(uint) range.mMinimum;
            maxFrames = cast(uint) range.mMaximum;
        }
    }

    private static uint queryBufferFrames(AudioDeviceID devId, uint fallback) @nogc nothrow {
        AudioObjectPropertyAddress addr = AudioObjectPropertyAddress(
            kAudioDevicePropertyBufferFrameSize,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        );
        uint frames = fallback;
        uint sz = frames.sizeof;
        if (AudioObjectGetPropertyData(devId, &addr, 0, null, &sz, &frames) != noErr || frames == 0) {
            return fallback;
        }
        return frames;
    }

    private static void negotiateSampleRate(AudioDeviceID devId, double desiredRate) @nogc nothrow {
        AudioObjectPropertyAddress addr = AudioObjectPropertyAddress(
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        );
        ubyte settable = 0;
        if (AudioObjectIsPropertySettable(devId, &addr, &settable) == noErr && settable != 0) {
            double req = desiredRate;
            AudioObjectSetPropertyData(devId, &addr, 0, null, req.sizeof, &req);
        }
    }

    private static void negotiateBufferFrames(AudioDeviceID devId, uint desiredFrames) @nogc nothrow {
        uint minF = 32;
        uint maxF = 4096;
        queryBufferSizeRange(devId, minF, maxF);
        uint clamped = desiredFrames;
        if (clamped < minF) {
            clamped = minF;
        } else if (clamped > maxF) {
            clamped = maxF;
        }
        AudioObjectPropertyAddress addr = AudioObjectPropertyAddress(
            kAudioDevicePropertyBufferFrameSize,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        );
        ubyte settable = 0;
        if (AudioObjectIsPropertySettable(devId, &addr, &settable) == noErr && settable != 0) {
            AudioObjectSetPropertyData(devId, &addr, 0, null, clamped.sizeof, &clamped);
        }
    }
}
