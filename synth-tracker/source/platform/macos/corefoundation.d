/**
 * File:         source/platform/macos/corefoundation.d
 * Module:       platform.macos.corefoundation
 * Phase:        Phase 3.1 — Minimal CoreFoundation extern(C) Bindings
 *
 * Purpose:
 *   Provides thin @nogc-safe extern(C) bindings for CFString, CFArray, CFRunLoop, CFRelease, and Mach timebase timing needed by CoreAudio, CoreMIDI, and CoreText.
 *
 * Real-Time & Safety Contract:
 *   extern(C) @nogc nothrow bindings; caller balances CFCreate/CFCopy with CFRelease or ScopedCF.
 *
 * Dependencies:
 *   Internal: None
 *   External: macOS CoreFoundation.framework, System mach_time
 *
 * Planned API (Types, Functions & Hooks):
 *   - aliases CFTypeRef, CFAllocatorRef, CFStringRef, CFArrayRef, CFRunLoopRef, CFRunLoopMode, CFIndex
 *   - extern(C) @nogc nothrow: CFRelease, CFRetain, CFStringCreateWithBytes, CFStringGetCString, CFRunLoopRunInMode, mach_timebase_info, mach_absolute_time
 *   - struct ScopedCF(T) / struct MachTimebase
 *   - CFStringRef createCFString(...) @nogc nothrow / size_t cfStringToBuffer(...) @nogc nothrow / string cfStringToDString(...)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module platform.macos.corefoundation;

version (OSX):

alias CFTypeRef = const(void)*;
alias CFAllocatorRef = const(void)*;
alias CFStringRef = const(void)*;
alias CFArrayRef = const(void)*;
alias CFRunLoopRef = void*;
alias CFRunLoopMode = CFStringRef;
alias CFIndex = ptrdiff_t;
alias CFStringEncoding = uint;
alias CFTimeInterval = double;
alias CFBoolean = ubyte;

/**
 * CoreFoundation integer range matching C CFRange layout on 64-bit macOS.
 */
struct CFRange {
    CFIndex location = 0;
    CFIndex length = 0;
}

static assert(CFIndex.sizeof == 8, "Expected 64-bit CFIndex");
static assert(CFRange.sizeof == 16, "Expected 16-byte CFRange");

enum CFAllocatorRef kCFAllocatorDefault = null;
enum CFStringEncoding kCFStringEncodingUTF8 = 0x0800_0100u;

enum int kCFRunLoopRunFinished = 1;
enum int kCFRunLoopRunStopped = 2;
enum int kCFRunLoopRunTimedOut = 3;
enum int kCFRunLoopRunHandledSource = 4;

/**
 * Mach host-time conversion numerator/denominator ratio matching mach_timebase_info_data_t.
 */
struct MachTimebaseInfo {
    uint numer = 1;
    uint denom = 1;
}

static assert(MachTimebaseInfo.sizeof == 8, "Expected 8-byte MachTimebaseInfo");

extern(C) @nogc nothrow {
    void CFRelease(CFTypeRef cf);
    CFTypeRef CFRetain(CFTypeRef cf);
    CFIndex CFGetRetainCount(CFTypeRef cf);

    CFStringRef CFStringCreateWithBytes(
        CFAllocatorRef alloc,
        const(ubyte)* bytes,
        CFIndex numBytes,
        CFStringEncoding encoding,
        CFBoolean isExternalRepresentation
    );

    CFIndex CFStringGetLength(CFStringRef theString);
    CFIndex CFStringGetMaximumSizeForEncoding(CFIndex length, CFStringEncoding encoding);
    CFBoolean CFStringGetCString(
        CFStringRef theString,
        char* buffer,
        CFIndex bufferSize,
        CFStringEncoding encoding
    );
    const(char)* CFStringGetCStringPtr(CFStringRef theString, CFStringEncoding encoding);

    CFIndex CFArrayGetCount(CFArrayRef theArray);
    const(void)* CFArrayGetValueAtIndex(CFArrayRef theArray, CFIndex idx);

    CFRunLoopRef CFRunLoopGetCurrent();
    CFRunLoopRef CFRunLoopGetMain();
    int CFRunLoopRunInMode(
        CFRunLoopMode mode,
        CFTimeInterval seconds,
        CFBoolean returnAfterSourceHandled
    );
    void CFRunLoopWakeUp(CFRunLoopRef rl);
    void CFRunLoopStop(CFRunLoopRef rl);

    extern __gshared const CFRunLoopMode kCFRunLoopDefaultMode;

    int mach_timebase_info(MachTimebaseInfo* info);
    ulong mach_absolute_time();
}

/**
 * Move-only RAII holder calling CFRelease automatically on owned CoreFoundation handles.
 */
struct ScopedCF(T = CFTypeRef) {
    private T handle_ = null;

    @disable this(this);

    @nogc nothrow:

    /**
     * Takes ownership of an already-retained CoreFoundation handle.
     *
     * Params:
     *   handle = Retained CF handle or null.
     */
    this(T handle) {
        handle_ = handle;
    }

    /**
     * Transfers ownership of a CoreFoundation handle from an rvalue ScopedCF.
     *
     * Params:
     *   rhs = Source owner cleared after move.
     *
     * Returns:
     *   Reference to this wrapper.
     */
    ref ScopedCF!T opAssign(ScopedCF!T rhs) return {
        if (handle_ !is rhs.handle_) {
            reset();
            handle_ = rhs.handle_;
            rhs.handle_ = null;
        }
        return this;
    }

    /**
     * Releases the owned handle on scope exit if non-null.
     */
    ~this() {
        reset();
    }

    /**
     * Returns the underlying CoreFoundation handle without releasing ownership.
     *
     * Returns:
     *   Owned CF handle or null.
     */
    T get() const pure @safe {
        return handle_;
    }

    /**
     * Checks whether a non-null CoreFoundation handle is held.
     *
     * Returns:
     *   True if handle is non-null.
     */
    bool isNull() const pure @safe {
        return handle_ is null;
    }

    /**
     * Detaches ownership and returns the handle without invoking CFRelease.
     *
     * Returns:
     *   Previously held CF handle.
     */
    T release() pure @safe {
        T outHandle = handle_;
        handle_ = null;
        return outHandle;
    }

    /**
     * Releases the held handle via CFRelease and resets to null.
     */
    void reset() {
        if (handle_ !is null) {
            CFRelease(cast(CFTypeRef) handle_);
            handle_ = null;
        }
    }
}

/**
 * Creates a UTF-8 CFStringRef from a D character slice (caller must release with CFRelease).
 *
 * Params:
 *   text = UTF-8 text slice.
 *
 * Returns:
 *   Newly created CFStringRef, or null on failure.
 */
CFStringRef createCFString(const(char)[] text) @nogc nothrow {
    static immutable ubyte[1] emptyByte = [0];
    const(ubyte)* bytes = text.length > 0 ? cast(const(ubyte)*) text.ptr : emptyByte.ptr;
    return CFStringCreateWithBytes(
        kCFAllocatorDefault,
        bytes,
        cast(CFIndex) text.length,
        kCFStringEncodingUTF8,
        0
    );
}

/**
 * Copies UTF-8 bytes from a CFStringRef into a caller-supplied destination buffer without GC allocation.
 *
 * Guarantees NUL-termination whenever dst.length > 0.
 *
 * Params:
 *   cfStr = Source CFStringRef (may be null).
 *   dst = Destination character slice receiving UTF-8 bytes and trailing NUL.
 *
 * Returns:
 *   UTF-8 byte length written excluding the terminating NUL byte.
 */
size_t cfStringToBuffer(CFStringRef cfStr, char[] dst) @nogc nothrow {
    if (dst.length == 0) {
        return 0;
    }
    dst[0] = '\0';
    if (cfStr is null) {
        return 0;
    }

    if (CFStringGetCString(cfStr, dst.ptr, cast(CFIndex) dst.length, kCFStringEncodingUTF8) == 0) {
        const(char)* cPtr = CFStringGetCStringPtr(cfStr, kCFStringEncodingUTF8);
        if (cPtr is null) {
            dst[0] = '\0';
            return 0;
        }
        size_t copyLen = 0;
        while (copyLen + 1 < dst.length && cPtr[copyLen] != '\0') {
            dst[copyLen] = cPtr[copyLen];
            copyLen++;
        }
        dst[copyLen] = '\0';
        return copyLen;
    }

    size_t len = 0;
    while (len < dst.length && dst[len] != '\0') {
        len++;
    }
    return len;
}

/**
 * Converts a CFStringRef into an immutable D UTF-8 string (off-RT helper).
 *
 * Params:
 *   cfStr = Source CFStringRef (not released by this call).
 *
 * Returns:
 *   Decoded UTF-8 D string, or empty string if cfStr is null or conversion fails.
 */
string cfStringToDString(CFStringRef cfStr) nothrow {
    if (cfStr is null) {
        return "";
    }

    char[512] stackBuf = '\0';
    if (CFStringGetCString(cfStr, stackBuf.ptr, cast(CFIndex) stackBuf.length, kCFStringEncodingUTF8) != 0) {
        size_t len = 0;
        while (len < stackBuf.length && stackBuf[len] != '\0') {
            len++;
        }
        return stackBuf[0 .. len].idup;
    }

    immutable CFIndex utf16Len = CFStringGetLength(cfStr);
    immutable CFIndex maxBytes = CFStringGetMaximumSizeForEncoding(utf16Len, kCFStringEncodingUTF8) + 1;
    if (maxBytes <= 1) {
        return "";
    }

    auto heapBuf = new char[cast(size_t) maxBytes];
    if (CFStringGetCString(cfStr, heapBuf.ptr, maxBytes, kCFStringEncodingUTF8) == 0) {
        return "";
    }

    size_t len = 0;
    while (len < heapBuf.length && heapBuf[len] != '\0') {
        len++;
    }
    return heapBuf[0 .. len].idup;
}

/**
 * Overflow-safe Mach absolute-time tick to nanosecond converter cached per system clock.
 */
struct MachTimebase {
    uint numer = 1;
    uint denom = 1;

    @nogc nothrow:

    /**
     * Queries the kernel Mach timebase multiplier once for nanosecond conversions.
     *
     * Returns:
     *   Initialized MachTimebase (defaults to 1:1 if kernel query returns zero denominator).
     */
    static MachTimebase query() {
        MachTimebaseInfo raw;
        MachTimebase result;
        if (mach_timebase_info(&raw) == 0 && raw.numer != 0 && raw.denom != 0) {
            result.numer = raw.numer;
            result.denom = raw.denom;
        }
        return result;
    }

    /**
     * Returns the current monotonic host tick counter from mach_absolute_time().
     *
     * Returns:
     *   Current Mach absolute tick count.
     */
    static ulong nowTicks() {
        return mach_absolute_time();
    }

    /**
     * Converts a Mach absolute-time tick interval into nanoseconds without 64-bit overflow.
     *
     * Params:
     *   ticks = Elapsed Mach ticks.
     *
     * Returns:
     *   Equivalent duration in nanoseconds.
     */
    ulong ticksToNanos(ulong ticks) const pure @safe {
        if (denom == 0) {
            return ticks;
        }
        if (numer == denom) {
            return ticks;
        }
        immutable ulong q = ticks / denom;
        immutable ulong r = ticks % denom;
        return q * numer + (r * numer) / denom;
    }

    /**
     * Converts a duration in nanoseconds into Mach absolute-time ticks without 64-bit overflow.
     *
     * Params:
     *   nanos = Duration in nanoseconds.
     *
     * Returns:
     *   Equivalent duration in Mach ticks.
     */
    ulong nanosToTicks(ulong nanos) const pure @safe {
        if (numer == 0) {
            return nanos;
        }
        if (numer == denom) {
            return nanos;
        }
        immutable ulong q = nanos / numer;
        immutable ulong r = nanos % numer;
        return q * denom + (r * denom) / numer;
    }
}
