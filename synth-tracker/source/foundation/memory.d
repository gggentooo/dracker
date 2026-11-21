/**
 * File:         source/foundation/memory.d
 * Module:       foundation.memory
 * Phase:        Phase 0.2 — @nogc RAII Memory Containers & Scratch Arena
 *
 * Purpose:
 *   Provides move-only @nogc heap buffers, inline fixed arrays, and per-slice linear scratch arenas replacing raw C pointers and smem_get_size() headers.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow; OwnedBuffer!T enforces static assert(!hasIndirections!T) so unscanned heap blocks never hide GC pointers from the D runtime.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: core.checkedint (mulu), core.lifetime (emplace, move, moveEmplace), core.stdc.stdlib (malloc, free), core.stdc.string (memset), core.sys.posix.stdlib (posix_memalign), std.traits
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct OwnedBuffer(T) : tryAllocate(count, out result, alignment = 32), opAssign(move), release(), adopt(), opIndex, opSlice, reset()
 *   - struct FixedArray(T, size_t Capacity) : inline stack/struct @nogc capacity-bounded vector
 *   - struct Arena : pre-allocated bump allocator reset cleanly between 64-frame graph slices
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module foundation.memory;

import core.checkedint : mulu;
import core.lifetime : emplace, move, moveEmplace;
import core.stdc.stdlib : free, malloc;
import core.stdc.string : memset;
version (Posix) import core.sys.posix.stdlib : posix_memalign;
import std.traits : hasElaborateDestructor, hasIndirections, isCopyable, isFloatingPoint, isStaticArray;

import foundation.types : DEFAULT_SIMD_ALIGNMENT;

private template isZeroBitFloatingType(T) {
    static if (isFloatingPoint!T) {
        enum bool isZeroBitFloatingType = true;
    } else static if (isStaticArray!T) {
        enum bool isZeroBitFloatingType = isZeroBitFloatingType!(typeof(T.init[0]));
    } else {
        enum bool isZeroBitFloatingType = false;
    }
}

private void initializeElements(T)(T* raw, size_t count) @nogc nothrow {
    static if (__traits(isZeroInit, T) || isZeroBitFloatingType!T) {
        memset(raw, 0, count * T.sizeof);
    } else {
        foreach (i; 0 .. count) {
            emplace(&raw[i]);
        }
    }
}

/**
 * Move-only @nogc heap buffer unscanned by the D garbage collector.
 *
 * Element type T must contain zero GC-managed indirections and, when possessing an
 * elaborate destructor, must support @nogc nothrow destruction via destroy!false.
 */
struct OwnedBuffer(T) {
    static assert(!hasIndirections!T,
        "OwnedBuffer!" ~ T.stringof ~ " is unscanned by the D GC and cannot hold GC pointers");
    static assert(T.sizeof > 0,
        "OwnedBuffer!" ~ T.stringof ~ " requires a positive element byte size");

    static if (hasElaborateDestructor!T) {
        static assert(
            __traits(compiles, (ref T item) @nogc nothrow { destroy!false(item); }),
            "OwnedBuffer!" ~ T.stringof ~ " requires a @nogc nothrow destructor");
    }

    private T* ptr_ = null;
    private size_t len_ = 0;

    @disable this(this);

    @nogc nothrow:

    /**
     * Transfers buffer ownership from an rvalue OwnedBuffer!T, resetting any prior allocation.
     *
     * Params:
     *   rhs = Source buffer whose ownership is moved into this instance.
     *
     * Returns:
     *   Reference to this buffer.
     */
    ref OwnedBuffer!T opAssign(OwnedBuffer!T rhs) return {
        if (ptr_ !is rhs.ptr_) {
            reset();
            ptr_ = rhs.ptr_;
            len_ = rhs.len_;
            rhs.ptr_ = null;
            rhs.len_ = 0;
        }
        return this;
    }

    /**
     * Allocates and initializes count elements with power-of-two byte alignment.
     *
     * Floating-point scalars and static arrays are zero-initialized rather than NaN-filled.
     *
     * Params:
     *   count = Number of elements to allocate (0 succeeds with an empty buffer).
     *   result = Destination OwnedBuffer receiving ownership on success.
     *   alignment = Requested power-of-two byte alignment (defaults to 32 bytes for SIMD).
     *
     * Returns:
     *   True on success; false on invalid alignment, multiplication overflow, or OOM.
     */
    static bool tryAllocate(size_t count, out OwnedBuffer!T result, size_t alignment = DEFAULT_SIMD_ALIGNMENT) {
        result = OwnedBuffer!T.init;
        if (alignment == 0 || (alignment & (alignment - 1)) != 0) {
            return false;
        }
        if (count == 0) {
            return true;
        }

        bool overflow = false;
        immutable size_t bytes = mulu(count, T.sizeof, overflow);
        if (overflow) {
            return false;
        }

        size_t actualAlign = alignment;
        if (actualAlign < (void*).sizeof) {
            actualAlign = (void*).sizeof;
        }
        if (actualAlign < T.alignof) {
            actualAlign = T.alignof;
        }
        if ((actualAlign & (actualAlign - 1)) != 0) {
            return false;
        }

        void* mem = null;
        version (Posix) {
            if (posix_memalign(&mem, actualAlign, bytes) != 0 || mem is null) {
                return false;
            }
        } else {
            mem = malloc(bytes);
            if (mem is null) {
                return false;
            }
        }

        auto raw = cast(T*) mem;
        initializeElements(raw, count);
        result.ptr_ = raw;
        result.len_ = count;
        return true;
    }

    /**
     * Destroys active elements (if needed) and frees owned heap memory.
     */
    ~this() {
        reset();
    }

    /**
     * Destroys all elements and frees the underlying @nogc allocation, leaving an empty buffer.
     */
    void reset() {
        if (ptr_ !is null) {
            static if (hasElaborateDestructor!T) {
                foreach (i; 0 .. len_) {
                    destroy!false(ptr_[i]);
                }
            }
            free(ptr_);
            ptr_ = null;
            len_ = 0;
        }
    }

    /**
     * Releases buffer ownership to the caller (such as a lock-free retire ring) without freeing.
     *
     * Returns:
     *   Raw slice formerly owned by this buffer.
     */
    T[] release() pure {
        auto slice = ptr_[0 .. len_];
        ptr_ = null;
        len_ = 0;
        return slice;
    }

    /**
     * Re-adopts a slice previously returned by release() for deterministic RAII cleanup.
     *
     * Params:
     *   raw = Slice whose base pointer was allocated by OwnedBuffer!T.tryAllocate.
     *
     * Returns:
     *   OwnedBuffer!T owning the adopted slice.
     */
    static OwnedBuffer!T adopt(T[] raw) {
        OwnedBuffer!T adopted;
        if (raw.length > 0 && raw.ptr !is null) {
            adopted.ptr_ = raw.ptr;
            adopted.len_ = raw.length;
        }
        return adopted;
    }

    /**
     * Indexes an element with bounds checking.
     *
     * Params:
     *   idx = Zero-based element index.
     *
     * Returns:
     *   Reference to the element at idx.
     */
    ref inout(T) opIndex(size_t idx) inout pure {
        assert(idx < len_, "OwnedBuffer index out of bounds");
        return ptr_[idx];
    }

    /**
     * Returns a slice over all owned elements.
     *
     * Returns:
     *   Slice spanning [0 .. length].
     */
    inout(T)[] opSlice() inout pure {
        return ptr_[0 .. len_];
    }

    /**
     * Returns a bounds-checked sub-slice over [start .. end].
     *
     * Params:
     *   start = Inclusive start index.
     *   end = Exclusive end index.
     *
     * Returns:
     *   Sub-slice spanning [start .. end].
     */
    inout(T)[] opSlice(size_t start, size_t end) inout pure {
        assert(start <= end && end <= len_, "OwnedBuffer slice out of bounds");
        return ptr_[start .. end];
    }

    /**
     * Returns the raw base pointer or null when empty.
     *
     * Returns:
     *   Base element pointer.
     */
    inout(T)* ptr() inout pure @safe {
        return ptr_;
    }

    /**
     * Returns the number of elements owned by this buffer.
     *
     * Returns:
     *   Element count.
     */
    size_t length() const pure @safe {
        return len_;
    }

    alias opDollar = length;

    /**
     * Reports whether the buffer contains zero elements.
     *
     * Returns:
     *   True if length == 0.
     */
    bool empty() const pure @safe {
        return len_ == 0;
    }
}

/**
 * Inline capacity-bounded vector storing up to Capacity elements without heap allocation.
 *
 * Floating-point types are zero-initialized; types with elaborate destructors or disabled
 * postblits manage active slot lifetimes explicitly inside union storage.
 */
struct FixedArray(T, size_t Capacity) {
    static assert(Capacity > 0, "FixedArray capacity must be greater than zero");

    static if (hasElaborateDestructor!T) {
        static assert(
            __traits(compiles, (ref T item) @nogc nothrow { destroy!false(item); }),
            "FixedArray!" ~ T.stringof ~ " requires a @nogc nothrow destructor");
    }

    private enum bool usesManualSlots = hasElaborateDestructor!T || !isCopyable!T;

    static if (usesManualSlots) {
        private union RawSlot {
            ubyte[T.sizeof] bytes = 0;
            T item;
        }
        static assert(RawSlot.sizeof == T.sizeof,
            "FixedArray RawSlot size must match element size for contiguous slicing");
        private RawSlot[Capacity] slots_;

        @disable this(this);
    } else static if (isZeroBitFloatingType!T) {
        private T[Capacity] data_ = 0;
    } else {
        private T[Capacity] data_;
    }

    private size_t len_ = 0;

    enum size_t capacity = Capacity;

    static if (usesManualSlots) {
        /**
         * Destroys all active elements when FixedArray leaves scope.
         */
        ~this() @nogc nothrow {
            clear();
        }
    }

    @nogc nothrow:

    /**
     * Appends an element if space remains in the inline storage.
     *
     * Params:
     *   item = Element to append (moved when non-copyable).
     *
     * Returns:
     *   True on success; false if the array is already at Capacity.
     */
    bool tryPush(T item) {
        if (len_ >= Capacity) {
            return false;
        }
        static if (usesManualSlots) {
            moveEmplace(item, slots_[len_].item);
        } else {
            data_[len_] = item;
        }
        len_++;
        return true;
    }

    /**
     * Pops and returns the last element if non-empty.
     *
     * Params:
     *   outItem = Receives the popped element on success.
     *
     * Returns:
     *   True if an element was popped; false if empty.
     */
    bool tryPop(out T outItem) {
        if (len_ == 0) {
            return false;
        }
        len_--;
        static if (usesManualSlots) {
            move(slots_[len_].item, outItem);
            destroy!false(slots_[len_].item);
        } else {
            outItem = data_[len_];
        }
        return true;
    }

    /**
     * Removes the element at idx in O(1) time by swapping in the final element.
     *
     * Params:
     *   idx = Zero-based index of the element to remove.
     *
     * Returns:
     *   True if idx was valid and removed; false if out of range.
     */
    bool removeSwapBack(size_t idx) {
        if (idx >= len_) {
            return false;
        }
        immutable size_t last = len_ - 1;
        static if (usesManualSlots) {
            if (idx != last) {
                move(slots_[last].item, slots_[idx].item);
                destroy!false(slots_[last].item);
            } else {
                destroy!false(slots_[idx].item);
            }
        } else {
            if (idx != last) {
                data_[idx] = data_[last];
            }
        }
        len_ = last;
        return true;
    }

    /**
     * Removes and destroys all active elements, resetting length to zero.
     */
    void clear() {
        static if (usesManualSlots) {
            foreach_reverse (i; 0 .. len_) {
                destroy!false(slots_[i].item);
            }
        }
        len_ = 0;
    }

    /**
     * Indexes an active element with bounds checking.
     *
     * Params:
     *   idx = Zero-based element index.
     *
     * Returns:
     *   Reference to the element at idx.
     */
    ref inout(T) opIndex(size_t idx) inout pure {
        assert(idx < len_, "FixedArray index out of bounds");
        static if (usesManualSlots) {
            return (cast(inout(T)*) slots_.ptr)[idx];
        } else {
            return data_[idx];
        }
    }

    /**
     * Returns a slice over all active elements.
     *
     * Returns:
     *   Slice spanning [0 .. length].
     */
    inout(T)[] opSlice() inout pure {
        static if (usesManualSlots) {
            return (cast(inout(T)*) slots_.ptr)[0 .. len_];
        } else {
            return data_[0 .. len_];
        }
    }

    /**
     * Returns a bounds-checked sub-slice over [start .. end].
     *
     * Params:
     *   start = Inclusive start index.
     *   end = Exclusive end index.
     *
     * Returns:
     *   Sub-slice spanning [start .. end].
     */
    inout(T)[] opSlice(size_t start, size_t end) inout pure {
        assert(start <= end && end <= len_, "FixedArray slice out of bounds");
        static if (usesManualSlots) {
            return (cast(inout(T)*) slots_.ptr)[start .. end];
        } else {
            return data_[start .. end];
        }
    }

    /**
     * Returns a reference to the first active element.
     *
     * Returns:
     *   Reference to element 0.
     */
    ref inout(T) front() inout pure {
        assert(len_ > 0, "FixedArray.front called on empty array");
        return opIndex(0);
    }

    /**
     * Returns a reference to the last active element.
     *
     * Returns:
     *   Reference to element length - 1.
     */
    ref inout(T) back() inout pure {
        assert(len_ > 0, "FixedArray.back called on empty array");
        return opIndex(len_ - 1);
    }

    /**
     * Returns the current number of active elements.
     *
     * Returns:
     *   Active element count.
     */
    size_t length() const pure @safe {
        return len_;
    }

    alias opDollar = length;

    /**
     * Reports whether zero elements are stored.
     *
     * Returns:
     *   True if length == 0.
     */
    bool empty() const pure @safe {
        return len_ == 0;
    }

    /**
     * Reports whether the array has reached Capacity.
     *
     * Returns:
     *   True if length == Capacity.
     */
    bool full() const pure @safe {
        return len_ >= Capacity;
    }

    /**
     * Returns the number of additional elements that fit before Capacity is reached.
     *
     * Returns:
     *   Remaining element slots.
     */
    size_t remaining() const pure @safe {
        return Capacity - len_;
    }
}

/**
 * Pre-allocated @nogc bump allocator designed for per-slice RT scratch memory.
 *
 * Allocations advance an internal offset linearly and are reclaimed in O(1) via reset()
 * or rewind(mark) between 64-frame graph execution slices.
 */
struct Arena {
    private OwnedBuffer!ubyte storage_;
    private size_t offset_ = 0;

    @disable this(this);

    @nogc nothrow:

    /**
     * Transfers arena buffer ownership from an rvalue Arena.
     *
     * Params:
     *   rhs = Source arena moved into this instance.
     *
     * Returns:
     *   Reference to this arena.
     */
    ref Arena opAssign(Arena rhs) return {
        storage_ = move(rhs.storage_);
        offset_ = rhs.offset_;
        rhs.offset_ = 0;
        return this;
    }

    /**
     * Allocates a new backing buffer of capacityBytes bytes for scratch allocations.
     *
     * Params:
     *   capacityBytes = Total capacity in bytes.
     *   result = Destination Arena receiving the backing allocation.
     *   baseAlignment = Base power-of-two alignment of the backing buffer.
     *
     * Returns:
     *   True on success; false on invalid alignment or OOM.
     */
    static bool tryCreate(size_t capacityBytes, out Arena result, size_t baseAlignment = DEFAULT_SIMD_ALIGNMENT) {
        result = Arena.init;
        OwnedBuffer!ubyte buf;
        if (!OwnedBuffer!ubyte.tryAllocate(capacityBytes, buf, baseAlignment)) {
            return false;
        }
        result.storage_ = move(buf);
        result.offset_ = 0;
        return true;
    }

    /**
     * Reclaims all arena allocations in O(1) by resetting the bump offset to zero.
     */
    void reset() pure @safe {
        offset_ = 0;
    }

    /**
     * Captures the current bump offset so temporary sub-allocations can be rewound.
     *
     * Returns:
     *   Opaque byte offset marker.
     */
    size_t mark() const pure @safe {
        return offset_;
    }

    /**
     * Restores the bump offset to a previously captured mark.
     *
     * Params:
     *   savedMark = Offset previously returned by mark(), <= current used bytes.
     */
    void rewind(size_t savedMark) pure @safe {
        assert(savedMark <= offset_, "Arena.rewind target exceeds current offset");
        offset_ = savedMark;
    }

    /**
     * Allocates numBytes bytes aligned to a power-of-two boundary.
     *
     * Params:
     *   numBytes = Number of bytes requested (0 returns null without advancing offset).
     *   alignment = Required power-of-two alignment in bytes.
     *
     * Returns:
     *   Aligned pointer within the arena, or null on invalid alignment, 0 bytes, or exhaustion.
     */
    void* allocBytes(size_t numBytes, size_t alignment = DEFAULT_SIMD_ALIGNMENT) {
        if (numBytes == 0 || alignment == 0 || (alignment & (alignment - 1)) != 0) {
            return null;
        }
        ubyte* base = storage_.ptr;
        if (base is null) {
            return null;
        }

        immutable size_t curAddr = cast(size_t)(base + offset_);
        immutable size_t misalign = curAddr & (alignment - 1);
        immutable size_t pad = misalign == 0 ? 0 : (alignment - misalign);

        immutable size_t cap = storage_.length;
        if (pad > cap - offset_) {
            return null;
        }
        immutable size_t alignedOffset = offset_ + pad;
        if (numBytes > cap - alignedOffset) {
            return null;
        }

        offset_ = alignedOffset + numBytes;
        return base + alignedOffset;
    }

    /**
     * Allocates and initializes an array slice of count POD/non-GC elements.
     *
     * Params:
     *   count = Number of elements requested.
     *   alignment = Required power-of-two byte alignment (defaults to T.alignof).
     *
     * Returns:
     *   Initialized slice of length count, or null on 0 count, overflow, or exhaustion.
     */
    T[] allocSlice(T)(size_t count, size_t alignment = T.alignof) {
        static assert(!hasIndirections!T,
            "Arena.allocSlice!" ~ T.stringof ~ " cannot hold GC indirections");
        static assert(!hasElaborateDestructor!T,
            "Arena.allocSlice!" ~ T.stringof ~ " does not run element destructors on reset");
        static assert(T.sizeof > 0,
            "Arena.allocSlice!" ~ T.stringof ~ " requires positive element byte size");

        if (count == 0) {
            return null;
        }

        size_t actualAlign = alignment;
        if (actualAlign < T.alignof) {
            actualAlign = T.alignof;
        }
        if ((actualAlign & (actualAlign - 1)) != 0) {
            return null;
        }

        bool overflow = false;
        immutable size_t bytes = mulu(count, T.sizeof, overflow);
        if (overflow) {
            return null;
        }

        void* mem = allocBytes(bytes, actualAlign);
        if (mem is null) {
            return null;
        }

        auto raw = cast(T*) mem;
        initializeElements(raw, count);
        return raw[0 .. count];
    }

    /**
     * Allocates and default-initializes a single element of type T.
     *
     * Params:
     *   alignment = Required power-of-two byte alignment (defaults to T.alignof).
     *
     * Returns:
     *   Pointer to the initialized element, or null on arena exhaustion.
     */
    T* allocOne(T)(size_t alignment = T.alignof) {
        auto slice = allocSlice!T(1, alignment);
        return slice.length == 1 ? slice.ptr : null;
    }

    /**
     * Returns the total byte capacity of the arena backing store.
     *
     * Returns:
     *   Total capacity in bytes.
     */
    size_t capacity() const pure @safe {
        return storage_.length;
    }

    /**
     * Returns the number of bytes currently consumed since the last reset.
     *
     * Returns:
     *   Used byte count.
     */
    size_t used() const pure @safe {
        return offset_;
    }

    /**
     * Returns the unallocated byte headroom remaining before exhaustion.
     *
     * Returns:
     *   Remaining byte count.
     */
    size_t remaining() const pure @safe {
        return storage_.length - offset_;
    }
}
