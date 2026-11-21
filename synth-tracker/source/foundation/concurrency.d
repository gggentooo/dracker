/**
 * File:         source/foundation/concurrency.d
 * Module:       foundation.concurrency
 * Phase:        Phase 0.3 — Lock-Free Rings, Atomics & Telemetry Buffers
 *
 * Purpose:
 *   Provides wait-free/lock-free SPSC, MPSC, atomic wrappers, and triple-buffered snapshot channels decoupling UI, CoreMIDI, I/O worker, and unregistered RT audio threads.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; uses core.atomic (MemoryOrder.acq / rel) with cache-line padding (64 bytes) to eliminate false sharing and zero mutex locks.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory
 *   External: core.atomic (atomicLoad, atomicStore, atomicExchange, atomicFetchAdd, atomicFetchSub, cas, MemoryOrder), core.lifetime (move), std.traits
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct Atomic(T) : typed atomic load/store/exchange/CAS wrapper
 *   - struct SpscRing(T) : single-producer/single-consumer ring for UI->RT commands, RT->UI retire queue, and per-endpoint MIDI
 *   - struct MpscRing(T) : bounded multi-producer/single-consumer ring for multi-thread CoreMIDI / worker aggregation
 *   - struct TripleBuffer(T) : wait-free latest-snapshot publisher for meters, playhead, and oscilloscope telemetry
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module foundation.concurrency;

import core.atomic : atomicExchange, atomicFetchAdd, atomicFetchSub, atomicLoad, atomicStore, cas, MemoryOrder;
import core.checkedint : mulu;
import core.lifetime : move;
import std.traits : Fields, hasElaborateAssign, hasElaborateCopyConstructor, hasElaborateDestructor,
    hasIndirections, isAssociativeArray, isDynamicArray, isFloatingPoint, isIntegral, isStaticArray;

import foundation.memory : OwnedBuffer;
import foundation.types : CACHE_LINE_SIZE;

private template anyFieldHasGcReference(TList...) {
    static if (TList.length == 0) {
        enum bool anyFieldHasGcReference = false;
    } else {
        enum bool anyFieldHasGcReference = hasGcReference!(TList[0]) || anyFieldHasGcReference!(TList[1 .. $]);
    }
}

/**
 * Compile-time predicate detecting types that embed D GC-managed references.
 *
 * Rejects classes, interfaces, delegates, dynamic arrays, associative arrays, and
 * composites or pointers targeting them, while permitting POD types and raw @nogc pointers.
 */
template hasGcReference(T) {
    static if (is(T == class) || is(T == interface) || is(T == delegate)
            || isDynamicArray!T || isAssociativeArray!T) {
        enum bool hasGcReference = true;
    } else static if (is(T : U*, U)) {
        enum bool hasGcReference = hasGcReference!U;
    } else static if (isStaticArray!T) {
        enum bool hasGcReference = hasGcReference!(typeof(T.init[0]));
    } else static if (is(T == struct) || is(T == union)) {
        enum bool hasGcReference = anyFieldHasGcReference!(Fields!T);
    } else {
        enum bool hasGcReference = false;
    }
}

private template isZeroBitFloatOrStaticArray(T) {
    static if (isFloatingPoint!T) {
        enum bool isZeroBitFloatOrStaticArray = true;
    } else static if (isStaticArray!T) {
        enum bool isZeroBitFloatOrStaticArray = isZeroBitFloatOrStaticArray!(typeof(T.init[0]));
    } else {
        enum bool isZeroBitFloatOrStaticArray = false;
    }
}

/**
 * Checks whether n is a non-zero power of two.
 *
 * Params:
 *   n = Unsigned size value to test.
 *
 * Returns:
 *   True if n > 0 and (n & (n - 1)) == 0.
 */
bool isPowerOfTwo(size_t n) @nogc nothrow pure @safe {
    return n != 0 && (n & (n - 1)) == 0;
}

/**
 * Lock-free atomic scalar/pointer wrapper supporting explicit memory ordering.
 *
 * Restricted to machine-word-sized or smaller power-of-two types without GC references.
 */
struct Atomic(T) {
    static assert(T.sizeof > 0 && T.sizeof <= size_t.sizeof && isPowerOfTwo(T.sizeof),
        "Atomic!" ~ T.stringof ~ " size must be a power of two <= size_t.sizeof");
    static assert(!hasGcReference!T,
        "Atomic!" ~ T.stringof ~ " cannot hold GC-managed references");

    private shared T value_ = T.init;

    /**
     * Constructs an Atomic!T initialized to initial.
     *
     * Params:
     *   initial = Starting value.
     */
    this(T initial) @nogc nothrow pure @safe {
        value_ = initial;
    }

    @nogc nothrow:

    /**
     * Atomically loads the current value using the specified MemoryOrder.
     *
     * Returns:
     *   Loaded value.
     */
    T load(MemoryOrder order = MemoryOrder.acq)() const {
        return atomicLoad!order(value_);
    }

    /**
     * Atomically stores val using the specified MemoryOrder.
     *
     * Params:
     *   val = Value to store.
     */
    void store(MemoryOrder order = MemoryOrder.rel)(T val) {
        atomicStore!order(value_, val);
    }

    /**
     * Atomically swaps the stored value with val and returns the previous value.
     *
     * Params:
     *   val = Replacement value.
     *
     * Returns:
     *   Value held immediately prior to the exchange.
     */
    T exchange(MemoryOrder order = MemoryOrder.acq_rel)(T val) {
        return atomicExchange!order(&value_, val);
    }

    /**
     * Atomically compares the stored value against expected and swaps in desired on match.
     *
     * Updates expected with the observed stored value on failure.
     *
     * Params:
     *   expected = Expected value on entry; receives observed value on failure.
     *   desired = Value written if comparison succeeds.
     *
     * Returns:
     *   True if the exchange occurred; false otherwise.
     */
    bool compareExchange(MemoryOrder succ = MemoryOrder.acq_rel, MemoryOrder fail = MemoryOrder.acq)(
        ref T expected, T desired
    ) {
        return cas!(succ, fail)(&value_, &expected, desired);
    }

    static if (isIntegral!T) {
        /**
         * Atomically adds delta and returns the value held prior to addition.
         *
         * Params:
         *   delta = Increment operand.
         *
         * Returns:
         *   Previous value before addition.
         */
        T fetchAdd(MemoryOrder order = MemoryOrder.acq_rel)(T delta) {
            return atomicFetchAdd!order(value_, delta);
        }

        /**
         * Atomically subtracts delta and returns the value held prior to subtraction.
         *
         * Params:
         *   delta = Decrement operand.
         *
         * Returns:
         *   Previous value before subtraction.
         */
        T fetchSub(MemoryOrder order = MemoryOrder.acq_rel)(T delta) {
            return atomicFetchSub!order(value_, delta);
        }
    }
}

/**
 * Wait-free single-producer / single-consumer lock-free ring buffer.
 *
 * Producer and consumer indices reside on separate 64-byte cache lines with cached remote
 * bounds to avoid false sharing and minimize cross-core cache invalidations.
 */
struct SpscRing(T) {
    static assert(!hasGcReference!T,
        "SpscRing!" ~ T.stringof ~ " cannot hold GC-managed references");
    static assert(!hasElaborateCopyConstructor!T && !hasElaborateAssign!T && !hasElaborateDestructor!T,
        "SpscRing!" ~ T.stringof ~ " requires trivially movable POD elements");

    private OwnedBuffer!ubyte storage_;
    private T* slots_ = null;
    private size_t cap_ = 0;
    private size_t mask_ = 0;

    private align(CACHE_LINE_SIZE) shared size_t writeIdx_ = 0;
    private size_t cachedReadIdx_ = 0;

    private align(CACHE_LINE_SIZE) shared size_t readIdx_ = 0;
    private size_t cachedWriteIdx_ = 0;

    @disable this(this);

    @nogc nothrow:

    /**
     * Transfers ownership of an SpscRing!T from an rvalue source.
     *
     * Params:
     *   rhs = Source ring buffer moved into this instance.
     *
     * Returns:
     *   Reference to this ring buffer.
     */
    ref SpscRing!T opAssign(SpscRing!T rhs) return {
        if (slots_ !is rhs.slots_) {
            reset();
            storage_ = move(rhs.storage_);
            slots_ = rhs.slots_;
            cap_ = rhs.cap_;
            mask_ = rhs.mask_;
            atomicStore!(MemoryOrder.raw)(writeIdx_, atomicLoad!(MemoryOrder.raw)(rhs.writeIdx_));
            cachedReadIdx_ = rhs.cachedReadIdx_;
            atomicStore!(MemoryOrder.raw)(readIdx_, atomicLoad!(MemoryOrder.raw)(rhs.readIdx_));
            cachedWriteIdx_ = rhs.cachedWriteIdx_;
            rhs.slots_ = null;
            rhs.cap_ = 0;
            rhs.mask_ = 0;
            atomicStore!(MemoryOrder.raw)(rhs.writeIdx_, 0);
            rhs.cachedReadIdx_ = 0;
            atomicStore!(MemoryOrder.raw)(rhs.readIdx_, 0);
            rhs.cachedWriteIdx_ = 0;
        }
        return this;
    }

    /**
     * Releases the backing ring storage.
     */
    ~this() {
        reset();
    }

    /**
     * Allocates a new SpscRing!T with a power-of-two capacity >= 2.
     *
     * Params:
     *   capacityPow2 = Number of element slots; must be a power of two >= 2.
     *   result = Destination ring buffer initialized on success.
     *
     * Returns:
     *   True on success; false on invalid capacity, overflow, or OOM.
     */
    static bool tryCreate(size_t capacityPow2, out SpscRing!T result) {
        result = SpscRing!T.init;
        if (capacityPow2 < 2 || !isPowerOfTwo(capacityPow2)) {
            return false;
        }

        bool overflow = false;
        immutable size_t bytes = mulu(capacityPow2, T.sizeof, overflow);
        if (overflow) {
            return false;
        }

        immutable size_t allocAlign = CACHE_LINE_SIZE > T.alignof ? CACHE_LINE_SIZE : T.alignof;
        OwnedBuffer!ubyte buf;
        if (!OwnedBuffer!ubyte.tryAllocate(bytes, buf, allocAlign)) {
            return false;
        }

        result.slots_ = cast(T*) buf.ptr;
        result.storage_ = move(buf);
        result.cap_ = capacityPow2;
        result.mask_ = capacityPow2 - 1;
        return true;
    }

    /**
     * Frees the backing storage and resets ring state to empty.
     */
    void reset() {
        slots_ = null;
        cap_ = 0;
        mask_ = 0;
        atomicStore!(MemoryOrder.raw)(writeIdx_, 0);
        cachedReadIdx_ = 0;
        atomicStore!(MemoryOrder.raw)(readIdx_, 0);
        cachedWriteIdx_ = 0;
        storage_.reset();
    }

    private bool tryPushImpl(scope const ref T item) {
        if (cap_ == 0) {
            return false;
        }
        immutable size_t w = atomicLoad!(MemoryOrder.raw)(writeIdx_);
        if (w - cachedReadIdx_ >= cap_) {
            cachedReadIdx_ = atomicLoad!(MemoryOrder.acq)(readIdx_);
            if (w - cachedReadIdx_ >= cap_) {
                return false;
            }
        }
        slots_[w & mask_] = item;
        atomicStore!(MemoryOrder.rel)(writeIdx_, w + 1);
        return true;
    }

    /**
     * Attempts to push an item by const reference from the single producer thread.
     *
     * Params:
     *   item = Element to enqueue.
     *
     * Returns:
     *   True if enqueued; false if the ring is full.
     */
    bool tryPush(scope const ref T item) {
        return tryPushImpl(item);
    }

    /**
     * Attempts to push a rvalue or scalar item from the single producer thread.
     *
     * Params:
     *   item = Element value to enqueue.
     *
     * Returns:
     *   True if enqueued; false if the ring is full.
     */
    bool tryPush(T item) {
        return tryPushImpl(item);
    }

    /**
     * Attempts to pop the oldest item from the single consumer thread.
     *
     * Params:
     *   outItem = Receives the dequeued element on success.
     *
     * Returns:
     *   True if an element was dequeued; false if the ring is empty.
     */
    bool tryPop(out T outItem) {
        if (cap_ == 0) {
            return false;
        }
        immutable size_t r = atomicLoad!(MemoryOrder.raw)(readIdx_);
        if (cachedWriteIdx_ == r) {
            cachedWriteIdx_ = atomicLoad!(MemoryOrder.acq)(writeIdx_);
            if (cachedWriteIdx_ == r) {
                return false;
            }
        }
        outItem = slots_[r & mask_];
        atomicStore!(MemoryOrder.rel)(readIdx_, r + 1);
        return true;
    }

    /**
     * Returns the fixed element capacity of the ring buffer.
     *
     * Returns:
     *   Slot count.
     */
    size_t capacity() const pure @safe {
        return cap_;
    }

    /**
     * Returns an approximate count of queued elements using acquire loads.
     *
     * Returns:
     *   Estimated number of pending elements.
     */
    size_t approximateCount() const {
        immutable size_t w = atomicLoad!(MemoryOrder.acq)(writeIdx_);
        immutable size_t r = atomicLoad!(MemoryOrder.acq)(readIdx_);
        return w - r;
    }

    /**
     * Reports whether the ring currently appears empty via acquire loads.
     *
     * Returns:
     *   True when write index equals read index.
     */
    bool empty() const {
        return approximateCount() == 0;
    }
}

/**
 * Bounded multi-producer / single-consumer lock-free ring buffer (Vyukov sequence design).
 *
 * Multiple producer threads (such as CoreMIDI endpoint callbacks) contend via lock-free CAS,
 * while the single real-time consumer executes wait-free in bounded constant time.
 */
struct MpscRing(T) {
    static assert(!hasGcReference!T,
        "MpscRing!" ~ T.stringof ~ " cannot hold GC-managed references");
    static assert(!hasElaborateCopyConstructor!T && !hasElaborateAssign!T && !hasElaborateDestructor!T,
        "MpscRing!" ~ T.stringof ~ " requires trivially movable POD elements");

    private struct Slot {
        shared size_t sequence = 0;
        T data;
    }

    private OwnedBuffer!ubyte storage_;
    private Slot* slots_ = null;
    private size_t cap_ = 0;
    private size_t mask_ = 0;

    private align(CACHE_LINE_SIZE) shared size_t enqueuePos_ = 0;
    private align(CACHE_LINE_SIZE) size_t dequeuePos_ = 0;

    @disable this(this);

    @nogc nothrow:

    /**
     * Transfers ownership of an MpscRing!T from an rvalue source.
     *
     * Params:
     *   rhs = Source ring buffer moved into this instance.
     *
     * Returns:
     *   Reference to this ring buffer.
     */
    ref MpscRing!T opAssign(MpscRing!T rhs) return {
        if (slots_ !is rhs.slots_) {
            reset();
            storage_ = move(rhs.storage_);
            slots_ = rhs.slots_;
            cap_ = rhs.cap_;
            mask_ = rhs.mask_;
            atomicStore!(MemoryOrder.raw)(enqueuePos_, atomicLoad!(MemoryOrder.raw)(rhs.enqueuePos_));
            dequeuePos_ = rhs.dequeuePos_;
            rhs.slots_ = null;
            rhs.cap_ = 0;
            rhs.mask_ = 0;
            atomicStore!(MemoryOrder.raw)(rhs.enqueuePos_, 0);
            rhs.dequeuePos_ = 0;
        }
        return this;
    }

    /**
     * Releases the backing ring storage.
     */
    ~this() {
        reset();
    }

    /**
     * Allocates a new MpscRing!T with a power-of-two capacity >= 2.
     *
     * Params:
     *   capacityPow2 = Number of element slots; must be a power of two >= 2.
     *   result = Destination ring buffer initialized on success.
     *
     * Returns:
     *   True on success; false on invalid capacity, overflow, or OOM.
     */
    static bool tryCreate(size_t capacityPow2, out MpscRing!T result) {
        result = MpscRing!T.init;
        if (capacityPow2 < 2 || !isPowerOfTwo(capacityPow2)) {
            return false;
        }

        bool overflow = false;
        immutable size_t bytes = mulu(capacityPow2, Slot.sizeof, overflow);
        if (overflow) {
            return false;
        }

        immutable size_t allocAlign = CACHE_LINE_SIZE > Slot.alignof ? CACHE_LINE_SIZE : Slot.alignof;
        OwnedBuffer!ubyte buf;
        if (!OwnedBuffer!ubyte.tryAllocate(bytes, buf, allocAlign)) {
            return false;
        }

        auto rawSlots = cast(Slot*) buf.ptr;
        foreach (i; 0 .. capacityPow2) {
            atomicStore!(MemoryOrder.raw)(rawSlots[i].sequence, i);
        }

        result.slots_ = rawSlots;
        result.storage_ = move(buf);
        result.cap_ = capacityPow2;
        result.mask_ = capacityPow2 - 1;
        return true;
    }

    /**
     * Frees the backing storage and resets ring state to empty.
     */
    void reset() {
        slots_ = null;
        cap_ = 0;
        mask_ = 0;
        atomicStore!(MemoryOrder.raw)(enqueuePos_, 0);
        dequeuePos_ = 0;
        storage_.reset();
    }

    private bool tryPushImpl(scope const ref T item) {
        if (cap_ == 0) {
            return false;
        }

        size_t pos = atomicLoad!(MemoryOrder.raw)(enqueuePos_);
        while (true) {
            Slot* slot = &slots_[pos & mask_];
            immutable size_t seq = atomicLoad!(MemoryOrder.acq)(slot.sequence);
            immutable ptrdiff_t diff = cast(ptrdiff_t)(seq - pos);
            if (diff == 0) {
                if (cas!(MemoryOrder.acq_rel, MemoryOrder.raw)(&enqueuePos_, &pos, pos + 1)) {
                    slot.data = item;
                    atomicStore!(MemoryOrder.rel)(slot.sequence, pos + 1);
                    return true;
                }
            } else if (diff < 0) {
                return false;
            } else {
                pos = atomicLoad!(MemoryOrder.raw)(enqueuePos_);
            }
        }
    }

    /**
     * Attempts to enqueue an item concurrently from any producer thread.
     *
     * Params:
     *   item = Element to enqueue.
     *
     * Returns:
     *   True if enqueued; false if the bounded ring is currently full.
     */
    bool tryPush(scope const ref T item) {
        return tryPushImpl(item);
    }

    /**
     * Attempts to enqueue a value item concurrently from any producer thread.
     *
     * Params:
     *   item = Element value to enqueue.
     *
     * Returns:
     *   True if enqueued; false if the bounded ring is currently full.
     */
    bool tryPush(T item) {
        return tryPushImpl(item);
    }

    /**
     * Dequeues the next committed element on the single consumer thread in wait-free O(1) time.
     *
     * Params:
     *   outItem = Receives the dequeued element on success.
     *
     * Returns:
     *   True if an element was ready and dequeued; false if empty or still being committed.
     */
    bool tryPop(out T outItem) {
        if (cap_ == 0) {
            return false;
        }

        immutable size_t pos = dequeuePos_;
        Slot* slot = &slots_[pos & mask_];
        immutable size_t seq = atomicLoad!(MemoryOrder.acq)(slot.sequence);
        immutable ptrdiff_t diff = cast(ptrdiff_t)(seq - (pos + 1));
        if (diff < 0) {
            return false;
        }

        outItem = slot.data;
        atomicStore!(MemoryOrder.rel)(slot.sequence, pos + cap_);
        dequeuePos_ = pos + 1;
        return true;
    }

    /**
     * Returns the fixed element capacity of the ring buffer.
     *
     * Returns:
     *   Slot count.
     */
    size_t capacity() const pure @safe {
        return cap_;
    }

    /**
     * Returns an approximate count of pending elements from the consumer perspective.
     *
     * Returns:
     *   Estimated number of queued elements.
     */
    size_t approximateCount() const {
        immutable size_t enq = atomicLoad!(MemoryOrder.acq)(enqueuePos_);
        immutable size_t deq = dequeuePos_;
        return enq >= deq ? (enq - deq) : 0;
    }

    /**
     * Reports whether no committed element is ready for the consumer.
     *
     * Returns:
     *   True when the consumer head slot is not yet committed.
     */
    bool empty() const {
        if (cap_ == 0) {
            return true;
        }
        immutable size_t pos = dequeuePos_;
        const Slot* slot = &slots_[pos & mask_];
        immutable size_t seq = atomicLoad!(MemoryOrder.acq)(slot.sequence);
        return cast(ptrdiff_t)(seq - (pos + 1)) < 0;
    }
}

/**
 * Wait-free single-writer / single-reader triple buffer for latest telemetry snapshots.
 *
 * Guarantees torn-free transfer of multi-field POD snapshots without locks or allocations,
 * allowing the RT thread to overwrite intermediate frames without stalling the UI thread.
 */
struct TripleBuffer(T) {
    static assert(!hasIndirections!T,
        "TripleBuffer!" ~ T.stringof ~ " requires a POD value type with zero indirections");

    private struct PaddedSlot {
        align(CACHE_LINE_SIZE)
        static if (isZeroBitFloatOrStaticArray!T) {
            T data = 0;
        } else {
            T data;
        }
    }

    private PaddedSlot[3] buffers_;

    private align(CACHE_LINE_SIZE) ubyte writeIdx_ = 0;
    private align(CACHE_LINE_SIZE) shared ubyte sharedState_ = 1;
    private align(CACHE_LINE_SIZE) ubyte readIdx_ = 2;

    @disable this(this);

    @nogc nothrow:

    /**
     * Returns a mutable reference to the writer's private staging buffer.
     *
     * Returns:
     *   Reference to the back buffer owned by the producer until publish().
     */
    ref T backBuffer() pure @safe {
        return buffers_[writeIdx_].data;
    }

    /**
     * Publishes the current back buffer atomically as the latest available snapshot.
     */
    void publish() {
        immutable ubyte nextState = cast(ubyte)(writeIdx_ | 0x04);
        immutable ubyte prevState = atomicExchange!(MemoryOrder.acq_rel)(&sharedState_, nextState);
        writeIdx_ = cast(ubyte)(prevState & 0x03);
    }

    private void writeImpl(scope const ref T snapshot) {
        backBuffer() = snapshot;
        publish();
    }

    /**
     * Copies snapshot by reference into the back buffer and publishes it atomically.
     *
     * Params:
     *   snapshot = Snapshot value to publish.
     */
    void write(scope const ref T snapshot) {
        writeImpl(snapshot);
    }

    /**
     * Copies an rvalue or scalar snapshot into the back buffer and publishes it atomically.
     *
     * Params:
     *   snapshot = Snapshot value to publish.
     */
    void write(T snapshot) {
        writeImpl(snapshot);
    }

    /**
     * Checks for a newly published snapshot and swaps it into the consumer's front buffer.
     *
     * Returns:
     *   True if a newer snapshot was acquired; false if the front buffer is already current.
     */
    bool tryAcquireLatest() {
        if ((atomicLoad!(MemoryOrder.acq)(sharedState_) & 0x04) == 0) {
            return false;
        }
        immutable ubyte prevState = atomicExchange!(MemoryOrder.acq_rel)(&sharedState_, readIdx_);
        readIdx_ = cast(ubyte)(prevState & 0x03);
        return true;
    }

    /**
     * Returns a read-only reference to the consumer's current front buffer.
     *
     * Returns:
     *   Const reference to the front buffer snapshot.
     */
    ref const(T) frontBuffer() const pure @safe {
        return buffers_[readIdx_].data;
    }

    /**
     * Acquires any newly published snapshot and copies the active front buffer to outSnapshot.
     *
     * Params:
     *   outSnapshot = Receives the latest front buffer snapshot.
     *
     * Returns:
     *   True if a new snapshot was published since the previous acquisition; false otherwise.
     */
    bool read(out T outSnapshot) {
        immutable bool updated = tryAcquireLatest();
        outSnapshot = buffers_[readIdx_].data;
        return updated;
    }
}
