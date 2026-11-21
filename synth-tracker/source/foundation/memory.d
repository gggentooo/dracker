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
 *   External: core.checkedint (mulu), core.lifetime (emplace), core.stdc.stdlib (malloc/free), core.sys.posix.stdlib (posix_memalign), std.traits
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct OwnedBuffer(T) : tryAllocate(count, out result, alignment = 32), opAssign(move), release(), opIndex, opSlice, reset()
 *   - struct FixedArray(T, size_t Capacity) : inline stack/struct @nogc capacity-bounded vector
 *   - struct Arena : pre-allocated bump allocator reset cleanly between 64-frame graph slices
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module foundation.memory;
