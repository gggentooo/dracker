/**
 * File:         tests/rt_malloc_trap.d
 * Module:       tests.rt_malloc_trap
 * Phase:        Phase 0.5 — Thread-Local RT Allocation Trap
 *
 * Purpose:
 *   Installs a thread-local allocation guard around Engine.renderOffline(), AudioGraph.render(), and module process() tests to catch any accidental malloc/calloc/realloc/free or GC entry at runtime.
 *
 * Real-Time & Safety Contract:
 *   Diagnostic verification utility for CI headless tests; uses non-TLS gshared slots keyed by pthread_t to prevent Darwin _tlv_get_addr recursion inside malloc_logger.
 *
 * Dependencies:
 *   Internal: foundation.types
 *   External: core.atomic, core.memory (GC.stats), core.sys.posix.dlfcn (dlsym), core.sys.posix.pthread, std.format
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct RtAllocationAudit : heapCallCount, allocCallCount, freeCallCount, gcBytesAllocated, clean()
 *   - struct ScopedRtMallocTrap : RAII guard failing assertions if any heap or GC allocation occurs on the guarded thread
 *   - RtAllocationAudit auditRtAllocations(scope void delegate() rtStep)
 *   - void verifyZeroRtAllocations(scope void delegate() rtStep)
 *   - void verifyZeroRtAllocationsNothrow(scope void delegate() @nogc nothrow rtStep)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module tests.rt_malloc_trap;

version (unittest) {
    import core.atomic : atomicFetchAdd, atomicFetchSub, atomicLoad, atomicStore, cas, MemoryOrder;
    import core.memory : GC;
    import core.sys.posix.pthread : pthread_equal, pthread_self, pthread_t;
    import std.format : format;

    version (OSX) {
        import core.sys.posix.dlfcn : dlsym;

        private enum void* DARWIN_RTLD_DEFAULT = cast(void*)-2;
        private enum uint MALLOC_LOG_TYPE_ALLOCATE = 2;
        private enum uint MALLOC_LOG_TYPE_DEALLOCATE = 4;

        private alias DarwinMallocLoggerFn = extern(C) void function(
            uint type,
            ulong arg1,
            ulong arg2,
            ulong arg3,
            ulong result,
            uint numHotFramesToSkip
        ) nothrow @nogc;

        private __gshared DarwinMallocLoggerFn* gMallocLoggerSlot = null;
        private __gshared DarwinMallocLoggerFn gPrevMallocLogger = null;
    }

    private enum size_t MAX_TRAP_THREADS = 16;
    private enum int SLOT_FREE = 0;
    private enum int SLOT_CLAIMING = 1;
    private enum int SLOT_ARMED = 2;

    private struct TrapSlot {
        shared int state = SLOT_FREE;
        pthread_t threadId;
        size_t depth = 0;
        size_t gcBytesBaseline = 0;
        shared size_t heapOps = 0;
        shared size_t allocOps = 0;
        shared size_t freeOps = 0;
    }

    private __gshared TrapSlot[MAX_TRAP_THREADS] gTrapSlots;
    private __gshared int gActiveTrapCount = 0;

    version (OSX) {
        private extern(C) void rtMallocLoggerCallback(
            uint type,
            ulong arg1,
            ulong arg2,
            ulong arg3,
            ulong result,
            uint numHotFramesToSkip
        ) nothrow @nogc {
            if (atomicLoad!(MemoryOrder.acq)(gActiveTrapCount) > 0) {
                pthread_t callerThread = pthread_self();
                foreach (i; 0 .. MAX_TRAP_THREADS) {
                    if (atomicLoad!(MemoryOrder.acq)(gTrapSlots[i].state) == SLOT_ARMED
                            && pthread_equal(callerThread, gTrapSlots[i].threadId) != 0) {
                        atomicFetchAdd!(MemoryOrder.raw)(gTrapSlots[i].heapOps, cast(size_t) 1);
                        if ((type & MALLOC_LOG_TYPE_ALLOCATE) != 0) {
                            atomicFetchAdd!(MemoryOrder.raw)(gTrapSlots[i].allocOps, cast(size_t) 1);
                        }
                        if ((type & MALLOC_LOG_TYPE_DEALLOCATE) != 0) {
                            atomicFetchAdd!(MemoryOrder.raw)(gTrapSlots[i].freeOps, cast(size_t) 1);
                        }
                        break;
                    }
                }
            }

            if (gPrevMallocLogger !is null) {
                gPrevMallocLogger(type, arg1, arg2, arg3, result, numHotFramesToSkip);
            }
        }

        shared static this() {
            gMallocLoggerSlot = cast(DarwinMallocLoggerFn*) dlsym(DARWIN_RTLD_DEFAULT, "malloc_logger");
            if (gMallocLoggerSlot !is null) {
                gPrevMallocLogger = *gMallocLoggerSlot;
                *gMallocLoggerSlot = &rtMallocLoggerCallback;
            }
        }

        shared static ~this() {
            if (gMallocLoggerSlot !is null && *gMallocLoggerSlot is &rtMallocLoggerCallback) {
                *gMallocLoggerSlot = gPrevMallocLogger;
            }
        }
    }

    /**
     * Summary of heap and garbage-collector activity recorded inside an RT trap scope.
     */
    struct RtAllocationAudit {
        size_t heapCallCount = 0;
        size_t allocCallCount = 0;
        size_t freeCallCount = 0;
        size_t gcBytesAllocated = 0;

        /**
         * Reports whether zero C-heap operations and zero D-GC allocations occurred.
         *
         * Returns:
         *   True if both heapCallCount and gcBytesAllocated are zero.
         */
        bool clean() const @nogc nothrow pure @safe {
            return heapCallCount == 0 && gcBytesAllocated == 0;
        }
    }

    /**
     * Thread-scoped RAII allocation trap detecting C malloc/calloc/realloc/free and GC allocations.
     *
     * Supports re-entrant nesting on the same thread; only records operations originating on the
     * thread that invoked enter() so unrelated background threads do not cause false positives.
     */
    struct ScopedRtMallocTrap {
        private size_t slotIdx_ = size_t.max;
        private bool active_ = false;
        private bool assertOnExit_ = true;

        @disable this(this);

        /**
         * Arms the thread-local RT allocation trap on the calling thread.
         *
         * Params:
         *   assertOnExit = When true, finish() or destruction asserts if any violation occurred.
         *
         * Returns:
         *   Active ScopedRtMallocTrap guard.
         */
        static ScopedRtMallocTrap enter(bool assertOnExit = true) {
            version (OSX) {
                assert(gMallocLoggerSlot !is null, "Darwin malloc_logger symbol unavailable for RT malloc trap");
            }

            ScopedRtMallocTrap guard;
            pthread_t self = pthread_self();
            size_t matchedIdx = size_t.max;
            foreach (i; 0 .. MAX_TRAP_THREADS) {
                if (atomicLoad!(MemoryOrder.acq)(gTrapSlots[i].state) == SLOT_ARMED
                        && pthread_equal(self, gTrapSlots[i].threadId) != 0) {
                    matchedIdx = i;
                    break;
                }
            }

            if (matchedIdx != size_t.max) {
                gTrapSlots[matchedIdx].depth++;
                guard.slotIdx_ = matchedIdx;
                guard.active_ = true;
                guard.assertOnExit_ = assertOnExit;
                return guard;
            }

            size_t claimedIdx = size_t.max;
            foreach (i; 0 .. MAX_TRAP_THREADS) {
                int expected = SLOT_FREE;
                if (cas!(MemoryOrder.acq_rel, MemoryOrder.raw)(&gTrapSlots[i].state, &expected, SLOT_CLAIMING)) {
                    claimedIdx = i;
                    break;
                }
            }
            assert(claimedIdx != size_t.max, "Exceeded concurrent ScopedRtMallocTrap slot limit");

            gTrapSlots[claimedIdx].threadId = self;
            gTrapSlots[claimedIdx].depth = 1;
            atomicStore!(MemoryOrder.raw)(gTrapSlots[claimedIdx].heapOps, cast(size_t) 0);
            atomicStore!(MemoryOrder.raw)(gTrapSlots[claimedIdx].allocOps, cast(size_t) 0);
            atomicStore!(MemoryOrder.raw)(gTrapSlots[claimedIdx].freeOps, cast(size_t) 0);
            gTrapSlots[claimedIdx].gcBytesBaseline = GC.stats().allocatedInCurrentThread;

            atomicFetchAdd!(MemoryOrder.acq_rel)(gActiveTrapCount, 1);
            atomicStore!(MemoryOrder.rel)(gTrapSlots[claimedIdx].state, SLOT_ARMED);

            guard.slotIdx_ = claimedIdx;
            guard.active_ = true;
            guard.assertOnExit_ = assertOnExit;
            return guard;
        }

        /**
         * Disarms the trap guard on the calling thread and returns recorded allocation counts.
         *
         * Returns:
         *   Audit summary covering heap calls and GC bytes allocated while guarded.
         */
        RtAllocationAudit finish() {
            RtAllocationAudit audit;
            if (!active_ || slotIdx_ >= MAX_TRAP_THREADS) {
                return audit;
            }
            active_ = false;

            auto slot = &gTrapSlots[slotIdx_];
            assert(slot.depth > 0, "ScopedRtMallocTrap slot depth underflow");
            slot.depth--;

            if (slot.depth > 0) {
                audit.heapCallCount = atomicLoad!(MemoryOrder.acq)(slot.heapOps);
                audit.allocCallCount = atomicLoad!(MemoryOrder.acq)(slot.allocOps);
                audit.freeCallCount = atomicLoad!(MemoryOrder.acq)(slot.freeOps);
                immutable size_t gcNow = GC.stats().allocatedInCurrentThread;
                audit.gcBytesAllocated = gcNow >= slot.gcBytesBaseline ? (gcNow - slot.gcBytesBaseline) : 0;
            } else {
                atomicStore!(MemoryOrder.rel)(slot.state, SLOT_FREE);
                atomicFetchSub!(MemoryOrder.acq_rel)(gActiveTrapCount, 1);

                immutable size_t gcNow = GC.stats().allocatedInCurrentThread;
                audit.heapCallCount = atomicLoad!(MemoryOrder.acq)(slot.heapOps);
                audit.allocCallCount = atomicLoad!(MemoryOrder.acq)(slot.allocOps);
                audit.freeCallCount = atomicLoad!(MemoryOrder.acq)(slot.freeOps);
                audit.gcBytesAllocated = gcNow >= slot.gcBytesBaseline ? (gcNow - slot.gcBytesBaseline) : 0;
            }

            if (assertOnExit_ && !audit.clean()) {
                assert(false, format(
                    "RT allocation trap violated: heapCalls=%s (alloc=%s, free=%s), gcBytes=%s",
                    audit.heapCallCount,
                    audit.allocCallCount,
                    audit.freeCallCount,
                    audit.gcBytesAllocated
                ));
            }
            return audit;
        }

        /**
         * Ensures the trap slot is released when leaving scope even if finish() was not called.
         */
        ~this() {
            if (active_) {
                finish();
            }
        }
    }

    /**
     * Executes rtStep under the allocation trap and returns the audit counts without asserting.
     *
     * Params:
     *   rtStep = Delegate representing a real-time audio rendering step.
     *
     * Returns:
     *   Recorded heap and GC allocation summary.
     */
    RtAllocationAudit auditRtAllocations(scope void delegate() rtStep) {
        auto trap = ScopedRtMallocTrap.enter(false);
        rtStep();
        return trap.finish();
    }

    /**
     * Executes rtStep under the allocation trap and asserts zero heap or GC allocations occurred.
     *
     * Params:
     *   rtStep = Delegate representing a real-time audio rendering step.
     */
    void verifyZeroRtAllocations(scope void delegate() rtStep) {
        auto trap = ScopedRtMallocTrap.enter(true);
        rtStep();
        trap.finish();
    }

    /**
     * Executes an @nogc nothrow rtStep under the allocation trap and asserts zero allocations.
     *
     * Params:
     *   rtStep = Statically @nogc nothrow delegate representing a real-time rendering step.
     */
    void verifyZeroRtAllocationsNothrow(scope void delegate() @nogc nothrow rtStep) {
        auto trap = ScopedRtMallocTrap.enter(true);
        rtStep();
        trap.finish();
    }
}
