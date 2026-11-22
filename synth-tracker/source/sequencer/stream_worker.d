/**
 * File:         source/sequencer/stream_worker.d
 * Module:       sequencer.stream_worker
 * Phase:        Phase 4.9 — Background Disk & Codec Streaming Worker
 *
 * Purpose:
 *   Runs a dedicated non-RT background thread decoding streaming Ogg Vorbis/WAV/FLAC/MP3 audio tracks (VorbisPlayer) and async Sampler loads via audio-formats, feeding decoded PCM over lock-free SpscRing buffers.
 *
 * Real-Time & Safety Contract:
 *   Background worker thread handles all file syscalls and decoding; StreamAudioRing consumer interface is strictly @nogc nothrow wait-free.
 *
 * Dependencies:
 *   Internal: foundation.concurrency, foundation.memory, foundation.types, io.audio_io
 *   External: audioformats, core.lifetime, core.stdc.stdlib, core.sync.mutex, core.thread, core.time
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct StreamAudioRing : @nogc SpscRing!StereoFrame PCM block bridge for VorbisPlayer
 *   - struct AsyncSampleResult : completed off-RT DecodedAudio job payload
 *   - class StreamWorker : openStreamFile(), openStreamMemory(), stopStream(), enqueueSampleDecodeFile(), enqueueSampleDecodeMemory(), pollSampleDecodeResult(), shutdown()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module sequencer.stream_worker;

import audioformats : AudioStream;
import core.lifetime : emplace, move;
import core.stdc.stdlib : calloc, free;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : dur;

import foundation.concurrency : Atomic, SpscRing, hasGcReference;
import foundation.memory : OwnedBuffer;
import foundation.types : StereoFrame;
import io.audio_io : DecodedAudio, decodeAudioFile, decodeAudioMemory;

/**
 * Unmanaged @nogc wait-free stereo PCM ring decoupling StreamWorker from VorbisPlayer RT process().
 *
 * Zero GC-managed references allow unregistered audio threads to consume frames safely while
 * issuing non-blocking play, stop, loop, and seek commands via atomics.
 */
struct StreamAudioRing {
    private SpscRing!StereoFrame pcmRing_;
    private Atomic!int playing_;
    private Atomic!int loopEnabled_;
    private Atomic!int seekPending_;
    private Atomic!ulong seekTargetFrame_;
    private Atomic!int endOfStream_;
    private Atomic!uint sourceSampleRate_;
    private Atomic!ulong framesDecoded_;
    private Atomic!ulong underruns_;
    private Atomic!int clearRequested_;

    @disable this(this);

    @nogc nothrow:

    /**
     * Releases the backing SPSC stereo ring storage.
     */
    ~this() {
        pcmRing_.reset();
    }

    /**
     * Allocates a lock-free SpscRing!StereoFrame of power-of-two capacity.
     *
     * Params:
     *   capacityPow2 = Ring capacity in stereo frames (must be power of two >= 64).
     *
     * Returns:
     *   True on success; false on invalid capacity or OOM.
     */
    bool tryInit(size_t capacityPow2 = 16_384) {
        if (capacityPow2 < 64) {
            return false;
        }
        SpscRing!StereoFrame allocated;
        if (!SpscRing!StereoFrame.tryCreate(capacityPow2, allocated)) {
            return false;
        }
        pcmRing_ = move(allocated);
        playing_.store(0);
        loopEnabled_.store(0);
        seekPending_.store(0);
        seekTargetFrame_.store(0);
        endOfStream_.store(0);
        sourceSampleRate_.store(44_100);
        framesDecoded_.store(0);
        underruns_.store(0);
        clearRequested_.store(0);
        return true;
    }

    /**
     * Requests playback start from the RT thread without locking.
     */
    void requestPlay() {
        endOfStream_.store(0);
        playing_.store(1);
    }

    /**
     * Requests playback pause/stop from the RT thread without locking.
     */
    void requestStop() {
        playing_.store(0);
    }

    /**
     * Schedules an asynchronous worker seek to frame and flushes stale queued audio on the RT thread.
     *
     * Params:
     *   frame = Zero-based target stream frame index.
     */
    void requestSeek(ulong frame) {
        StereoFrame discard;
        while (pcmRing_.tryPop(discard)) {
        }
        seekTargetFrame_.store(frame);
        seekPending_.store(1);
        endOfStream_.store(0);
    }

    /**
     * Sets loop-wrap behavior read atomically by the background decoding worker.
     *
     * Params:
     *   enabled = When true, loops back to frame 0 upon reaching EOF.
     */
    void setLoopEnabled(bool enabled) {
        loopEnabled_.store(enabled ? 1 : 0);
    }

    /**
     * Drains up to outL.length decoded stereo frames on the single RT consumer thread.
     *
     * Params:
     *   outL = Destination left sample buffer.
     *   outR = Destination right sample buffer (must match outL.length).
     *
     * Returns:
     *   Actual stereo frame count popped into outL/outR.
     */
    size_t popStereo(float[] outL, float[] outR) {
        if (pcmRing_.capacity() == 0 || outL.length == 0 || outL.length != outR.length) {
            return 0;
        }
        if (clearRequested_.load() != 0) {
            StereoFrame discard;
            while (pcmRing_.tryPop(discard)) {
            }
            clearRequested_.store(0);
        }
        size_t got = 0;
        StereoFrame sf;
        while (got < outL.length && pcmRing_.tryPop(sf)) {
            outL[got] = sf.left;
            outR[got] = sf.right;
            got++;
        }
        if (got < outL.length && playing_.load() != 0 && endOfStream_.load() == 0) {
            underruns_.fetchAdd(1);
        }
        return got;
    }

    /**
     * Pushes a decoded stereo frame into the queue from the background worker thread only.
     *
     * Params:
     *   left = Left channel sample.
     *   right = Right channel sample.
     *
     * Returns:
     *   True if pushed; false if ring is currently full.
     */
    bool workerTryPushFrame(float left, float right) {
        return pcmRing_.tryPush(StereoFrame(left, right));
    }

    /**
     * Returns remaining writable frame capacity available in the ring.
     *
     * Returns:
     *   Free stereo slot count.
     */
    size_t workerFreeSpace() const {
        immutable size_t cap = pcmRing_.capacity();
        immutable size_t used = pcmRing_.approximateCount();
        return cap > used ? (cap - used) : 0;
    }

    /**
     * Reports whether playback has been requested by VorbisPlayer.
     *
     * Returns:
     *   True when playing.
     */
    bool isPlaying() const {
        return playing_.load() != 0;
    }

    /**
     * Reports whether end-of-stream has been reached while loop is disabled.
     *
     * Returns:
     *   True at EOF.
     */
    bool isEndOfStream() const {
        return endOfStream_.load() != 0;
    }

    /**
     * Returns the stream's native sample rate in Hertz as discovered by the worker.
     *
     * Returns:
     *   Stream sample rate in Hertz.
     */
    uint sourceSampleRate() const {
        immutable uint sr = sourceSampleRate_.load();
        return sr > 0 ? sr : 44_100;
    }

    /**
     * Returns total decoded frame count pushed into the ring by the worker thread.
     *
     * Returns:
     *   Decoded frame count.
     */
    ulong framesDecoded() const {
        return framesDecoded_.load();
    }

    /**
     * Returns consumer ring underrun count while actively playing before EOF.
     *
     * Returns:
     *   Underrun count.
     */
    ulong underrunCount() const {
        return underruns_.load();
    }

    /**
     * Returns current buffered frame count available for immediate RT consumption.
     *
     * Returns:
     *   Queued stereo frame count.
     */
    size_t bufferedFrames() const {
        return pcmRing_.approximateCount();
    }

    /**
     * Allocates an unmanaged StreamAudioRing* off-RT cleanly.
     *
     * Params:
     *   capacityPow2 = Power-of-two capacity in stereo frames.
     *
     * Returns:
     *   Allocated StreamAudioRing*, or null on OOM.
     */
    static StreamAudioRing* createOffRT(size_t capacityPow2 = 16_384) {
        auto ptr = cast(StreamAudioRing*) calloc(1, StreamAudioRing.sizeof);
        if (ptr is null) {
            return null;
        }
        emplace(ptr);
        if (!ptr.tryInit(capacityPow2)) {
            destroy!false(*ptr);
            free(ptr);
            return null;
        }
        return ptr;
    }

    /**
     * Frees an unmanaged StreamAudioRing* allocated by createOffRT().
     *
     * Params:
     *   ptr = Pointer to free (null-safe).
     */
    static void destroyOffRT(StreamAudioRing* ptr) {
        if (ptr !is null) {
            destroy!false(*ptr);
            free(ptr);
        }
    }
}

static assert(!hasGcReference!StreamAudioRing,
    "StreamAudioRing must remain free of D GC indirections");

/**
 * Result produced asynchronously by StreamWorker for off-RT sample loading.
 */
struct AsyncSampleResult {
    uint jobId = 0;
    bool success = false;
    string error;
    DecodedAudio audio;
}

/**
 * Background disk/codec worker thread decoding streaming audio and off-RT sample files.
 */
class StreamWorker {
    private struct SampleDecodeJob {
        uint jobId = 0;
        string path;
        immutable(ubyte)[] memBytes;
    }

    private Mutex lock_;
    private Thread workerThread_;
    private Atomic!int stopRequested_;
    private bool started_ = false;

    private StreamAudioRing* activeRing_ = null;
    private AudioStream activeStream_;
    private bool streamOpen_ = false;
    private bool streamFromMemory_ = false;
    private string streamPath_;
    private immutable(ubyte)[] streamBytes_;
    private int streamChannels_ = 2;

    private SampleDecodeJob[] pendingJobs_;
    private AsyncSampleResult*[] completedJobs_;
    private uint nextJobId_ = 1;

    /**
     * Constructs a StreamWorker ready to spawn its background thread lazily or via start().
     */
    this() {
        lock_ = new Mutex();
    }

    /**
     * Stops active decoding and joins the worker thread cleanly on garbage collection.
     */
    ~this() {
        shutdown();
    }

    /**
     * Ensures the dedicated background decoding thread is running.
     */
    void start() {
        synchronized (lock_) {
            if (started_) {
                return;
            }
            stopRequested_.store(0);
            workerThread_ = new Thread(&workerLoop);
            workerThread_.name = "SynthTracker-StreamWorker";
            started_ = true;
            workerThread_.start();
        }
    }

    /**
     * Stops streaming, shuts down the worker thread, and releases internal stream resources.
     */
    void shutdown() {
        Thread threadToJoin = null;
        synchronized (lock_) {
            stopRequested_.store(1);
            activeRing_ = null;
            streamOpen_ = false;
            if (started_) {
                threadToJoin = workerThread_;
                workerThread_ = null;
                started_ = false;
            }
        }
        if (threadToJoin !is null) {
            threadToJoin.join();
        }
    }

    /**
     * Opens an audio file on disk (such as Ogg Vorbis or WAV) for background streaming into ring.
     *
     * Params:
     *   path = UTF-8 path to audio file.
     *   ring = Pre-allocated StreamAudioRing* shared wait-free with VorbisPlayer.
     *   err = Error message populated if opening the stream fails.
     *
     * Returns:
     *   True if the stream opened validly and worker decoding is primed.
     */
    bool openStreamFile(string path, StreamAudioRing* ring, out string err) {
        err = null;
        if (path.length == 0 || ring is null) {
            err = "Stream file path and destination ring must be valid";
            return false;
        }
        start();

        AudioStream probe;
        probe.openFromFile(path);
        if (probe.isError() || probe.getNumChannels() <= 0 || probe.getSamplerate() <= 0.0f) {
            auto msg = probe.errorMessage();
            err = msg.length > 0 ? msg.idup : "Failed opening streaming audio file";
            return false;
        }

        synchronized (lock_) {
            activeStream_ = move(probe);
            streamFromMemory_ = false;
            streamPath_ = path;
            streamBytes_ = null;
            streamChannels_ = activeStream_.getNumChannels();
            ring.sourceSampleRate_.store(cast(uint)(activeStream_.getSamplerate() + 0.5f));
            ring.framesDecoded_.store(0);
            ring.endOfStream_.store(0);
            ring.seekPending_.store(0);
            ring.clearRequested_.store(0);
            activeRing_ = ring;
            streamOpen_ = true;
        }
        return true;
    }

    /**
     * Opens an in-memory encoded audio stream (such as Ogg Vorbis or WAV) for background streaming.
     *
     * Params:
     *   encodedBytes = Complete encoded audio payload copied for background decode.
     *   ring = Pre-allocated StreamAudioRing* shared wait-free with VorbisPlayer.
     *   err = Error message populated on decode open failure.
     *
     * Returns:
     *   True if the stream opened cleanly and worker priming started.
     */
    bool openStreamMemory(const(ubyte)[] encodedBytes, StreamAudioRing* ring, out string err) {
        err = null;
        if (encodedBytes.length == 0 || ring is null) {
            err = "Encoded stream buffer and destination ring must be valid";
            return false;
        }
        start();

        immutable(ubyte)[] ownedCopy = encodedBytes.idup;
        AudioStream probe;
        probe.openFromMemory(ownedCopy);
        if (probe.isError() || probe.getNumChannels() <= 0 || probe.getSamplerate() <= 0.0f) {
            auto msg = probe.errorMessage();
            err = msg.length > 0 ? msg.idup : "Failed opening streaming audio memory buffer";
            return false;
        }

        synchronized (lock_) {
            activeStream_ = move(probe);
            streamFromMemory_ = true;
            streamPath_ = null;
            streamBytes_ = ownedCopy;
            streamChannels_ = activeStream_.getNumChannels();
            ring.sourceSampleRate_.store(cast(uint)(activeStream_.getSamplerate() + 0.5f));
            ring.framesDecoded_.store(0);
            ring.endOfStream_.store(0);
            ring.seekPending_.store(0);
            ring.clearRequested_.store(0);
            activeRing_ = ring;
            streamOpen_ = true;
        }
        return true;
    }

    /**
     * Closes the active stream on the worker thread without destroying the external ring pointer.
     */
    void stopStream() {
        synchronized (lock_) {
            streamOpen_ = false;
            if (activeRing_ !is null) {
                activeRing_.playing_.store(0);
                activeRing_ = null;
            }
            streamBytes_ = null;
            streamPath_ = null;
        }
    }

    /**
     * Queues an asynchronous disk sample file decode job executed on the background thread.
     *
     * Params:
     *   path = UTF-8 audio file path.
     *
     * Returns:
     *   Non-zero job identifier matched in pollSampleDecodeResult().
     */
    uint enqueueSampleDecodeFile(string path) {
        start();
        synchronized (lock_) {
            immutable uint id = nextJobId_++;
            pendingJobs_ ~= SampleDecodeJob(id, path, null);
            return id;
        }
    }

    /**
     * Queues an asynchronous in-memory audio decode job executed on the background thread.
     *
     * Params:
     *   bytes = Encoded audio file bytes.
     *
     * Returns:
     *   Non-zero job identifier matched in pollSampleDecodeResult().
     */
    uint enqueueSampleDecodeMemory(const(ubyte)[] bytes) {
        start();
        immutable(ubyte)[] copy = bytes.idup;
        synchronized (lock_) {
            immutable uint id = nextJobId_++;
            pendingJobs_ ~= SampleDecodeJob(id, null, copy);
            return id;
        }
    }

    /**
     * Dequeues one completed off-RT sample decode result cleanly on the UI/control thread.
     *
     * Params:
     *   result = Populated AsyncSampleResult on success.
     *
     * Returns:
     *   True if a completed job was dequeued; false otherwise.
     */
    bool pollSampleDecodeResult(out AsyncSampleResult result) {
        synchronized (lock_) {
            if (completedJobs_.length == 0) {
                return false;
            }
            AsyncSampleResult* ptr = completedJobs_[0];
            foreach (i; 1 .. completedJobs_.length) {
                completedJobs_[i - 1] = completedJobs_[i];
            }
            completedJobs_.length = completedJobs_.length - 1;
            result = move(*ptr);
            return true;
        }
    }

    private void workerLoop() {
        enum size_t CHUNK_FRAMES = 512;
        float[] interleavedChunk = new float[CHUNK_FRAMES * 8];

        while (stopRequested_.load() == 0) {
            bool didWork = false;

            SampleDecodeJob job;
            bool hasJob = false;
            synchronized (lock_) {
                if (pendingJobs_.length > 0) {
                    job = pendingJobs_[0];
                    foreach (i; 1 .. pendingJobs_.length) {
                        pendingJobs_[i - 1] = pendingJobs_[i];
                    }
                    pendingJobs_.length = pendingJobs_.length - 1;
                    hasJob = true;
                }
            }
            if (hasJob) {
                auto res = new AsyncSampleResult();
                res.jobId = job.jobId;
                if (job.memBytes.length > 0) {
                    res.success = decodeAudioMemory(job.memBytes, res.audio, res.error);
                } else {
                    res.success = decodeAudioFile(job.path, res.audio, res.error);
                }
                synchronized (lock_) {
                    completedJobs_ ~= res;
                }
                didWork = true;
            }

            synchronized (lock_) {
                if (streamOpen_ && activeRing_ !is null) {
                    if (activeRing_.seekPending_.load() != 0) {
                        immutable ulong target = activeRing_.seekTargetFrame_.load();
                        activeRing_.seekPending_.store(0);
                        if (!activeStream_.seekPosition(cast(int) target)) {
                            reopenStreamLocked();
                        }
                        activeRing_.endOfStream_.store(0);
                        didWork = true;
                    }

                    immutable size_t freeSlots = activeRing_.workerFreeSpace();
                    if (freeSlots >= CHUNK_FRAMES) {
                        immutable size_t chCount = streamChannels_ > 0 ? cast(size_t) streamChannels_ : 2;
                        if (interleavedChunk.length < CHUNK_FRAMES * chCount) {
                            interleavedChunk.length = CHUNK_FRAMES * chCount;
                        }
                        immutable int got = activeStream_.readSamplesFloat(
                            interleavedChunk.ptr,
                            cast(int) CHUNK_FRAMES
                        );
                        if (got > 0) {
                            foreach (f; 0 .. cast(size_t) got) {
                                immutable size_t base = f * chCount;
                                immutable float l = interleavedChunk[base];
                                immutable float r = chCount >= 2 ? interleavedChunk[base + 1] : l;
                                activeRing_.workerTryPushFrame(l, r);
                            }
                            activeRing_.framesDecoded_.fetchAdd(cast(ulong) got);
                            didWork = true;
                        } else {
                            if (activeRing_.loopEnabled_.load() != 0) {
                                if (!activeStream_.seekPosition(0)) {
                                    reopenStreamLocked();
                                }
                                didWork = true;
                            } else {
                                activeRing_.endOfStream_.store(1);
                            }
                        }
                    }
                }
            }

            if (!didWork) {
                Thread.sleep(dur!"msecs"(2));
            }
        }
    }

    private void reopenStreamLocked() {
        AudioStream reopened;
        if (streamFromMemory_ && streamBytes_.length > 0) {
            reopened.openFromMemory(streamBytes_);
        } else if (streamPath_.length > 0) {
            reopened.openFromFile(streamPath_);
        }
        if (!reopened.isError()) {
            activeStream_ = move(reopened);
            streamChannels_ = activeStream_.getNumChannels();
        }
    }
}
