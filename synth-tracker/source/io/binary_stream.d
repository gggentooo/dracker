/**
 * File:         source/io/binary_stream.d
 * Module:       io.binary_stream
 * Phase:        Phase 6.1 — Bounds-Checked @safe Binary Stream Reader & Writer
 *
 * Purpose:
 *   Provides bounds-checked little-endian and big-endian slice readers and growable writers eliminating raw-struct fread/cast serialization hazards.
 *
 * Real-Time & Safety Contract:
 *   @safe; explicit bounds and integer overflow validation on every read; off-RT only.
 *
 * Dependencies:
 *   Internal: None
 *   External: std.bitmanip
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct BinaryReader : readU8/U16/U32/U64/F32/F64, readBytes(size_t), skip(size_t), remaining()
 *   - struct BinaryWriter : writeU8..writeF64, writeChunk(char[4] id, scope void delegate(ref BinaryWriter))
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.binary_stream;
