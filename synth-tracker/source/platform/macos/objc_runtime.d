/**
 * File:         source/platform/macos/objc_runtime.d
 * Module:       platform.macos.objc_runtime
 * Phase:        Phase 7.1 — Objective-C Runtime & Autorelease Pool Discipline
 *
 * Purpose:
 *   Thin, typed access to the Objective-C runtime from D without ARC: statically typed objc_msgSend /
 *   objc_msgSendSuper trampolines (including the x86_64 struct-return variant), selector/class lookup,
 *   runtime subclass registration (RuntimeClassBuilder) used to subclass NSView/NSObject from D, ivar
 *   context-pointer storage, NSString conversion, manual retain/release, ScopedAutoreleasePool, and the
 *   extern(C) entry points of objc_blocks_shim.m.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Every AppKit event tick and every Metal frame must run inside a ScopedAutoreleasePool.
 *   Callers own +1 references returned by alloc/new/copy and must release them; everything else is
 *   autoreleased into the innermost pool. IMP callbacks registered through RuntimeClassBuilder must be
 *   extern(C) and nothrow so no D exception crosses an Objective-C frame.
 *
 * Dependencies:
 *   Internal: None
 *   External: libobjc (objc_msgSend family, class/ivar/protocol API, autorelease pools), objc_blocks_shim.m
 *
 * Planned API (Types, Functions & Hooks):
 *   - alias id / SEL / Class / IMP; struct CGPoint / CGSize / CGRect; struct ObjcSuper
 *   - SEL sel(const(char)*); Class cls(const(char)*); R send!R(id, SEL, args...); R sendSuper!R(id, Class, SEL, args...)
 *   - id retain(id) / void release(id) / id autorelease(id)
 *   - id nsString(const(char)[]) / string fromNSString(id)
 *   - struct ScopedAutoreleasePool (enter() / RAII pop) / size_t autoreleasePoolDepthProbe()
 *   - struct RuntimeClassBuilder : begin(), addMethod(), addIvar(), addProtocol(), register()
 *   - void setIvarPointer(id, const(char)*, void*) / void* getIvarPointer(id, const(char)*)
 *   - extern(C) st_mtl_cmdbuf_add_completed_handler, st_ns_panel_begin_open_sheet, st_ns_panel_begin_save_sheet
 *
 * See_Also:
 *   architecture.md (Objective-C Runtime Discipline), dev_plan.md (Phase 7.1)
 */
module platform.macos.objc_runtime;

version (OSX):

import std.string : fromStringz;

alias id = void*;
alias SEL = void*;
alias Class = void*;
alias IMP = void*;
alias Ivar = void*;
alias Protocol = void*;
alias CGFloat = double;

/**
 * CoreGraphics point (CGFloat = double on 64-bit macOS).
 */
struct CGPoint {
    CGFloat x = 0.0;
    CGFloat y = 0.0;
}

/**
 * CoreGraphics size.
 */
struct CGSize {
    CGFloat width = 0.0;
    CGFloat height = 0.0;
}

/**
 * CoreGraphics rectangle (bottom-left origin in AppKit window coordinates).
 */
struct CGRect {
    CGPoint origin;
    CGSize size;
}

/**
 * objc_super receiver/superclass pair for objc_msgSendSuper.
 */
struct ObjcSuper {
    id receiver = null;
    Class superClass = null;
}

/**
 * Foundation NSRange.
 */
struct NSRange {
    ulong location = 0;
    ulong length = 0;
}

enum ulong NSNotFound = long.max;
enum ulong NSUTF8StringEncoding = 4;

extern (C) @nogc nothrow {
    Class objc_getClass(const(char)* name);
    Protocol objc_getProtocol(const(char)* name);
    SEL sel_registerName(const(char)* name);
    void objc_msgSend();
    void objc_msgSendSuper();
    Class objc_allocateClassPair(Class superclass, const(char)* name, size_t extraBytes);
    void objc_registerClassPair(Class cls);
    bool class_addMethod(Class cls, SEL name, IMP imp, const(char)* types);
    bool class_addIvar(Class cls, const(char)* name, size_t size, ubyte alignment, const(char)* types);
    bool class_addProtocol(Class cls, Protocol protocol);
    Ivar class_getInstanceVariable(Class cls, const(char)* name);
    ptrdiff_t ivar_getOffset(Ivar v);
    Class object_getClass(id obj);
    Class class_getSuperclass(Class cls);
    void* objc_autoreleasePoolPush();
    void objc_autoreleasePoolPop(void* pool);
    id objc_retain(id obj);
    void objc_release(id obj);
    id objc_autorelease(id obj);

    void st_mtl_cmdbuf_add_completed_handler(void* cmdBuf, void function(void* ctx) nothrow callback, void* ctx);
    void st_ns_panel_begin_open_sheet(
        void* panel,
        void* window,
        void function(void* ctx, int accepted, const(char)* utf8Path) nothrow callback,
        void* ctx
    );
    void st_ns_panel_begin_save_sheet(
        void* panel,
        void* window,
        void function(void* ctx, int accepted, const(char)* utf8Path) nothrow callback,
        void* ctx
    );
}

version (X86_64) {
    extern (C) @nogc nothrow void objc_msgSend_stret();
    extern (C) @nogc nothrow void objc_msgSendSuper_stret();
}

/**
 * Registers (or looks up) a selector.
 *
 * Params:
 *   name = Zero-terminated selector name, e.g. "initWithFrame:".
 *
 * Returns:
 *   Interned selector.
 */
SEL sel(const(char)* name) @nogc nothrow {
    return sel_registerName(name);
}

/**
 * Looks up an Objective-C class by name.
 *
 * Params:
 *   name = Zero-terminated class name.
 *
 * Returns:
 *   Class object, or null if not loaded.
 */
Class cls(const(char)* name) @nogc nothrow {
    return objc_getClass(name);
}

private template needsStret(R) {
    version (X86_64) {
        enum needsStret = is(R == struct) && R.sizeof > 16;
    } else {
        enum needsStret = false;
    }
}

/**
 * Sends a message with a statically typed signature through objc_msgSend.
 *
 * Params:
 *   receiver = Target object or class (nil receivers return R.init).
 *   selector = Selector to send.
 *   args = Message arguments, passed with C ABI.
 *
 * Returns:
 *   Method result.
 */
R send(R = id, Args...)(id receiver, SEL selector, Args args) nothrow {
    if (receiver is null) {
        static if (!is(R == void)) {
            return R.init;
        } else {
            return;
        }
    }
    static if (needsStret!R) {
        version (X86_64) {
            alias Fn = extern (C) R function(id, SEL, Args) nothrow;
            return (cast(Fn) &objc_msgSend_stret)(receiver, selector, args);
        }
    } else {
        alias Fn = extern (C) R function(id, SEL, Args) nothrow;
        return (cast(Fn) &objc_msgSend)(receiver, selector, args);
    }
}

/**
 * Sends a message to the superclass implementation (used from overridden IMPs).
 *
 * Params:
 *   receiver = The overriding object (self).
 *   superClass = Superclass whose implementation should run.
 *   selector = Selector to send.
 *   args = Message arguments.
 *
 * Returns:
 *   Superclass method result.
 */
R sendSuper(R = id, Args...)(id receiver, Class superClass, SEL selector, Args args) nothrow {
    ObjcSuper sup = ObjcSuper(receiver, superClass);
    static if (needsStret!R) {
        version (X86_64) {
            alias Fn = extern (C) R function(ObjcSuper*, SEL, Args) nothrow;
            return (cast(Fn) &objc_msgSendSuper_stret)(&sup, selector, args);
        }
    } else {
        alias Fn = extern (C) R function(ObjcSuper*, SEL, Args) nothrow;
        return (cast(Fn) &objc_msgSendSuper)(&sup, selector, args);
    }
}

/**
 * Retains obj (+1).
 *
 * Params:
 *   obj = Object to retain (nil-safe).
 *
 * Returns:
 *   obj.
 */
id retain(id obj) @nogc nothrow {
    return obj is null ? null : objc_retain(obj);
}

/**
 * Releases obj (-1).
 *
 * Params:
 *   obj = Object to release (nil-safe).
 */
void release(id obj) @nogc nothrow {
    if (obj !is null) {
        objc_release(obj);
    }
}

/**
 * Hands obj to the innermost autorelease pool.
 *
 * Params:
 *   obj = Object to autorelease (nil-safe).
 *
 * Returns:
 *   obj.
 */
id autorelease(id obj) @nogc nothrow {
    return obj is null ? null : objc_autorelease(obj);
}

/**
 * Creates an autoreleased NSString from UTF-8 bytes (no zero terminator required).
 *
 * Params:
 *   utf8 = UTF-8 text.
 *
 * Returns:
 *   Autoreleased NSString (empty string for empty input).
 */
id nsString(const(char)[] utf8) nothrow {
    id allocated = send(cast(id) cls("NSString"), sel("alloc"));
    id str = send(allocated, sel("initWithBytes:length:encoding:"), cast(const(void)*) utf8.ptr,
        cast(ulong) utf8.length, NSUTF8StringEncoding);
    return autorelease(str);
}

/**
 * Copies an NSString into a GC-managed D string.
 *
 * Params:
 *   str = NSString (nil yields null).
 *
 * Returns:
 *   UTF-8 copy.
 */
string fromNSString(id str) nothrow {
    if (str is null) {
        return null;
    }
    const(char)* raw = send!(const(char)*)(str, sel("UTF8String"));
    return raw is null ? null : fromStringz(raw).idup;
}

/**
 * RAII autorelease pool scope (objc_autoreleasePoolPush / objc_autoreleasePoolPop).
 */
struct ScopedAutoreleasePool {
    private void* token_ = null;

    @disable this(this);

    /**
     * Pushes a new autorelease pool.
     *
     * Returns:
     *   Active pool scope that pops on destruction.
     */
    static ScopedAutoreleasePool enter() @nogc nothrow {
        ScopedAutoreleasePool p;
        p.token_ = objc_autoreleasePoolPush();
        return p;
    }

    /**
     * Reports whether this scope owns a pushed pool.
     *
     * Returns:
     *   True while active.
     */
    bool active() const @nogc nothrow {
        return token_ !is null;
    }

    /**
     * Pops the pool early (idempotent).
     */
    void drain() @nogc nothrow {
        if (token_ !is null) {
            objc_autoreleasePoolPop(token_);
            token_ = null;
        }
    }

    /**
     * Pops the pool, releasing every object autoreleased inside the scope.
     */
    ~this() @nogc nothrow {
        drain();
    }
}

/**
 * Incrementally declares an Objective-C subclass at runtime; idempotent across repeated calls.
 */
struct RuntimeClassBuilder {
    private Class cls_ = null;
    private bool existed_ = false;

    /**
     * Starts declaring className as a subclass of superName, or reuses an already registered class.
     *
     * Params:
     *   className = Unique zero-terminated class name.
     *   superName = Zero-terminated superclass name.
     *
     * Returns:
     *   True if the class exists or allocation succeeded.
     */
    bool begin(const(char)* className, const(char)* superName) @nogc nothrow {
        Class existing = objc_getClass(className);
        if (existing !is null) {
            cls_ = existing;
            existed_ = true;
            return true;
        }
        Class sup = objc_getClass(superName);
        if (sup is null) {
            return false;
        }
        cls_ = objc_allocateClassPair(sup, className, 0);
        existed_ = false;
        return cls_ !is null;
    }

    /**
     * Reports whether begin() found a previously registered class (methods/ivars are then skipped).
     *
     * Returns:
     *   True if reused.
     */
    bool reused() const @nogc nothrow {
        return existed_;
    }

    /**
     * Adds an instance method implementation.
     *
     * Params:
     *   selectorName = Zero-terminated selector.
     *   imp = extern(C) nothrow implementation (self, _cmd, args...).
     *   types = Objective-C type encoding, e.g. "v@:@".
     *
     * Returns:
     *   True on success (or when the class was reused).
     */
    bool addMethod(const(char)* selectorName, IMP imp, const(char)* types) @nogc nothrow {
        if (existed_) {
            return true;
        }
        return cls_ !is null && class_addMethod(cls_, sel_registerName(selectorName), imp, types);
    }

    /**
     * Adds a pointer-sized ivar.
     *
     * Params:
     *   name = Zero-terminated ivar name.
     *
     * Returns:
     *   True on success (or when reused).
     */
    bool addPointerIvar(const(char)* name) @nogc nothrow {
        if (existed_) {
            return true;
        }
        return cls_ !is null && class_addIvar(cls_, name, (void*).sizeof, 3, "^v");
    }

    /**
     * Declares conformance to a protocol if it is loaded.
     *
     * Params:
     *   protocolName = Zero-terminated protocol name.
     *
     * Returns:
     *   True if added, already present, or reused.
     */
    bool addProtocol(const(char)* protocolName) @nogc nothrow {
        if (existed_) {
            return true;
        }
        Protocol p = objc_getProtocol(protocolName);
        return p is null ? false : (cls_ !is null && class_addProtocol(cls_, p));
    }

    /**
     * Registers the class with the runtime.
     *
     * Returns:
     *   The usable Class, or null if begin() failed.
     */
    Class register() @nogc nothrow {
        if (cls_ !is null && !existed_) {
            objc_registerClassPair(cls_);
            existed_ = true;
        }
        return cls_;
    }
}

/**
 * Stores a raw pointer into a pointer ivar declared with RuntimeClassBuilder.addPointerIvar.
 *
 * Params:
 *   obj = Instance.
 *   name = Zero-terminated ivar name.
 *   value = Pointer to store (not retained, not GC-scanned; the owner must keep it alive).
 */
void setIvarPointer(id obj, const(char)* name, void* value) @nogc nothrow {
    if (obj is null) {
        return;
    }
    Ivar v = class_getInstanceVariable(object_getClass(obj), name);
    if (v !is null) {
        *cast(void**)(cast(ubyte*) obj + ivar_getOffset(v)) = value;
    }
}

/**
 * Reads a pointer ivar declared with RuntimeClassBuilder.addPointerIvar.
 *
 * Params:
 *   obj = Instance.
 *   name = Zero-terminated ivar name.
 *
 * Returns:
 *   Stored pointer, or null.
 */
void* getIvarPointer(id obj, const(char)* name) @nogc nothrow {
    if (obj is null) {
        return null;
    }
    Ivar v = class_getInstanceVariable(object_getClass(obj), name);
    return v is null ? null : *cast(void**)(cast(ubyte*) obj + ivar_getOffset(v));
}

/**
 * Returns the retain count reported by the runtime (diagnostics/tests only).
 *
 * Params:
 *   obj = Object.
 *
 * Returns:
 *   retainCount.
 */
ulong retainCountOf(id obj) nothrow {
    return send!ulong(obj, sel("retainCount"));
}

private extern (C) id testDescriptionImp(id self, SEL cmd) nothrow {
    return nsString("st-runtime-ok");
}

private extern (C) id testSuperDescriptionImp(id self, SEL cmd) nothrow {
    return sendSuper(self, cls("NSObject"), sel("description"));
}

unittest {
    auto pool = ScopedAutoreleasePool.enter();
    assert(pool.active());

    id s = nsString("héllo wörld");
    assert(fromNSString(s) == "héllo wörld");
    assert(send!ulong(s, sel("length")) == 11);
    assert(fromNSString(nsString("")) == "");

    RuntimeClassBuilder b;
    assert(b.begin("STRuntimeUnitTestObject", "NSObject"));
    assert(b.addPointerIvar("dctx"));
    assert(b.addMethod("stTestDescription", cast(IMP) &testDescriptionImp, "@@:"));
    assert(b.addMethod("stSuperDescription", cast(IMP) &testSuperDescriptionImp, "@@:"));
    Class c = b.register();
    assert(c !is null);

    RuntimeClassBuilder again;
    assert(again.begin("STRuntimeUnitTestObject", "NSObject"));
    assert(again.reused());
    assert(again.register() is c);

    id obj = send(send(cast(id) c, sel("alloc")), sel("init"));
    assert(obj !is null);
    int marker = 42;
    setIvarPointer(obj, "dctx", &marker);
    assert(getIvarPointer(obj, "dctx") is &marker);
    assert(fromNSString(send(obj, sel("stTestDescription"))) == "st-runtime-ok");
    assert(fromNSString(send(obj, sel("stSuperDescription"))).length > 0);

    immutable ulong rc0 = retainCountOf(obj);
    retain(obj);
    assert(retainCountOf(obj) == rc0 + 1);
    release(obj);
    assert(retainCountOf(obj) == rc0);
    release(obj);

    id view = send(send(cast(id) cls("NSView"), sel("alloc")), sel("initWithFrame:"),
        CGRect(CGPoint(1, 2), CGSize(30, 40)));
    CGRect r = send!CGRect(view, sel("frame"));
    assert(r.origin.x == 1 && r.origin.y == 2 && r.size.width == 30 && r.size.height == 40);
    release(view);

    assert(send(null, sel("description")) is null);
    pool.drain();
    assert(!pool.active());
}
