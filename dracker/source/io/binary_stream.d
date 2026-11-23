/**
 * File:         source/io/binary_stream.d
 * Module:       io.binary_stream
 * Phase:        Phase 6.1 — Bounds-Checked @safe Binary Stream Reader & Writer
 *
 * Purpose:
 *   Provides bounds-checked little-endian and big-endian slice readers and growable writers eliminating raw-struct fread/cast serialization hazards.
 *
 * Real-Time & Safety Contract:
 *   @safe with explicit overflow-guarded bounds checks on every read; off-RT only.
 *
 * Dependencies:
 *   Internal: None
 *   External: std.bitmanip (bigEndianToNative, littleEndianToNative, nativeToBigEndian, nativeToLittleEndian)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct BinaryReader : readU8..readF64, readU16BE..readF64BE, readMidiVlq, readBytes, readFourCC, readLengthPrefixedBytes, readString, readChunk
 *   - struct BinaryWriter : writeU8..writeF64, writeU16BE..writeF64BE, writeBytes, writeFourCC, writeLengthPrefixedBytes, writeString, writeChunk
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module io.binary_stream;

import std.bitmanip : bigEndianToNative, littleEndianToNative, nativeToBigEndian,
    nativeToLittleEndian;

/**
 * Overflow-safe, bounds-checked read cursor over an immutable byte slice.
 *
 * Never throws or indexes past data_.length even when fed corrupted/adversarial lengths.
 */
struct BinaryReader {
    private const(ubyte)[] data_;
    private size_t pos_ = 0;

    @safe pure nothrow @nogc {

    /**
     * Constructs a BinaryReader positioned at byte offset 0 of bytes.
     *
     * Params:
     *   bytes = Backing binary payload slice.
     */
    this(const(ubyte)[] bytes) {
        data_ = bytes;
        pos_ = 0;
    }

    /**
     * Returns total byte length of the backing slice.
     *
     * Returns:
     *   Total payload size in bytes.
     */
    size_t length() const {
        return data_.length;
    }

    /**
     * Returns current byte read cursor offset.
     *
     * Returns:
     *   Current zero-based byte offset.
     */
    size_t position() const {
        return pos_;
    }

    /**
     * Returns unread byte count remaining from position() to end of slice.
     *
     * Returns:
     *   Remaining readable bytes.
     */
    size_t remaining() const {
        return pos_ <= data_.length ? (data_.length - pos_) : 0;
    }

    /**
     * Reports whether all bytes in the backing slice have been consumed.
     *
     * Returns:
     *   True when remaining() == 0.
     */
    bool atEnd() const {
        return pos_ >= data_.length;
    }

    /**
     * Overflow-safely checks whether count bytes remain readable from position().
     *
     * Params:
     *   count = Byte count required.
     *
     * Returns:
     *   True if count bytes can be read without exceeding data_.length.
     */
    bool canRead(size_t count) const {
        return count <= data_.length && pos_ <= data_.length - count;
    }

    /**
     * Seeks cursor to absolute byte offset if within [0 .. length()].
     *
     * Params:
     *   offset = Target byte position.
     *
     * Returns:
     *   True on success; false if offset exceeds data_.length.
     */
    bool seek(size_t offset) {
        if (offset > data_.length) {
            return false;
        }
        pos_ = offset;
        return true;
    }

    /**
     * Advances cursor forward by count bytes without wrapping or overflowing.
     *
     * Params:
     *   count = Byte count to skip.
     *
     * Returns:
     *   True if skipped cleanly; false if insufficient bytes remain.
     */
    bool skip(size_t count) {
        if (!canRead(count)) {
            return false;
        }
        pos_ += count;
        return true;
    }

    /**
     * Reads an unsigned 8-bit integer.
     *
     * Params:
     *   val = Output byte value.
     *
     * Returns:
     *   True on success; false at EOF.
     */
    bool readU8(out ubyte val) {
        if (!canRead(1)) {
            return false;
        }
        val = data_[pos_++];
        return true;
    }

    /**
     * Reads a signed 8-bit integer.
     *
     * Params:
     *   val = Output signed byte value.
     *
     * Returns:
     *   True on success; false at EOF.
     */
    bool readI8(out byte val) {
        ubyte tmp = 0;
        if (!readU8(tmp)) {
            return false;
        }
        val = cast(byte) tmp;
        return true;
    }

    /**
     * Reads a little-endian unsigned 16-bit integer.
     *
     * Params:
     *   val = Output ushort value.
     *
     * Returns:
     *   True on success; false if fewer than 2 bytes remain.
     */
    bool readU16(out ushort val) {
        if (!canRead(2)) {
            return false;
        }
        ubyte[2] buf = data_[pos_ .. pos_ + 2];
        pos_ += 2;
        val = littleEndianToNative!ushort(buf);
        return true;
    }

    /**
     * Reads a little-endian signed 16-bit integer.
     *
     * Params:
     *   val = Output short value.
     *
     * Returns:
     *   True on success; false if fewer than 2 bytes remain.
     */
    bool readI16(out short val) {
        if (!canRead(2)) {
            return false;
        }
        ubyte[2] buf = data_[pos_ .. pos_ + 2];
        pos_ += 2;
        val = littleEndianToNative!short(buf);
        return true;
    }

    /**
     * Reads a little-endian unsigned 32-bit integer.
     *
     * Params:
     *   val = Output uint value.
     *
     * Returns:
     *   True on success; false if fewer than 4 bytes remain.
     */
    bool readU32(out uint val) {
        if (!canRead(4)) {
            return false;
        }
        ubyte[4] buf = data_[pos_ .. pos_ + 4];
        pos_ += 4;
        val = littleEndianToNative!uint(buf);
        return true;
    }

    /**
     * Reads a little-endian signed 32-bit integer.
     *
     * Params:
     *   val = Output int value.
     *
     * Returns:
     *   True on success; false if fewer than 4 bytes remain.
     */
    bool readI32(out int val) {
        if (!canRead(4)) {
            return false;
        }
        ubyte[4] buf = data_[pos_ .. pos_ + 4];
        pos_ += 4;
        val = littleEndianToNative!int(buf);
        return true;
    }

    /**
     * Reads a little-endian unsigned 64-bit integer.
     *
     * Params:
     *   val = Output ulong value.
     *
     * Returns:
     *   True on success; false if fewer than 8 bytes remain.
     */
    bool readU64(out ulong val) {
        if (!canRead(8)) {
            return false;
        }
        ubyte[8] buf = data_[pos_ .. pos_ + 8];
        pos_ += 8;
        val = littleEndianToNative!ulong(buf);
        return true;
    }

    /**
     * Reads a little-endian signed 64-bit integer.
     *
     * Params:
     *   val = Output long value.
     *
     * Returns:
     *   True on success; false if fewer than 8 bytes remain.
     */
    bool readI64(out long val) {
        if (!canRead(8)) {
            return false;
        }
        ubyte[8] buf = data_[pos_ .. pos_ + 8];
        pos_ += 8;
        val = littleEndianToNative!long(buf);
        return true;
    }

    /**
     * Reads an IEEE-754 little-endian 32-bit float.
     *
     * Params:
     *   val = Output float value.
     *
     * Returns:
     *   True on success; false if fewer than 4 bytes remain.
     */
    bool readF32(out float val) {
        if (!canRead(4)) {
            return false;
        }
        ubyte[4] buf = data_[pos_ .. pos_ + 4];
        pos_ += 4;
        val = littleEndianToNative!float(buf);
        return true;
    }

    /**
     * Reads an IEEE-754 little-endian 64-bit double.
     *
     * Params:
     *   val = Output double value.
     *
     * Returns:
     *   True on success; false if fewer than 8 bytes remain.
     */
    bool readF64(out double val) {
        if (!canRead(8)) {
            return false;
        }
        ubyte[8] buf = data_[pos_ .. pos_ + 8];
        pos_ += 8;
        val = littleEndianToNative!double(buf);
        return true;
    }

    /**
     * Reads a big-endian unsigned 16-bit integer.
     *
     * Params:
     *   val = Output ushort value.
     *
     * Returns:
     *   True on success; false if fewer than 2 bytes remain.
     */
    bool readU16BE(out ushort val) {
        if (!canRead(2)) {
            return false;
        }
        ubyte[2] buf = data_[pos_ .. pos_ + 2];
        pos_ += 2;
        val = bigEndianToNative!ushort(buf);
        return true;
    }

    /**
     * Reads a big-endian unsigned 32-bit integer.
     *
     * Params:
     *   val = Output uint value.
     *
     * Returns:
     *   True on success; false if fewer than 4 bytes remain.
     */
    bool readU32BE(out uint val) {
        if (!canRead(4)) {
            return false;
        }
        ubyte[4] buf = data_[pos_ .. pos_ + 4];
        pos_ += 4;
        val = bigEndianToNative!uint(buf);
        return true;
    }

    /**
     * Reads a big-endian signed 32-bit integer.
     *
     * Params:
     *   val = Output int value.
     *
     * Returns:
     *   True on success; false if fewer than 4 bytes remain.
     */
    bool readI32BE(out int val) {
        if (!canRead(4)) {
            return false;
        }
        ubyte[4] buf = data_[pos_ .. pos_ + 4];
        pos_ += 4;
        val = bigEndianToNative!int(buf);
        return true;
    }

    /**
     * Reads a big-endian unsigned 64-bit integer.
     *
     * Params:
     *   val = Output ulong value.
     *
     * Returns:
     *   True on success; false if fewer than 8 bytes remain.
     */
    bool readU64BE(out ulong val) {
        if (!canRead(8)) {
            return false;
        }
        ubyte[8] buf = data_[pos_ .. pos_ + 8];
        pos_ += 8;
        val = bigEndianToNative!ulong(buf);
        return true;
    }

    /**
     * Reads an IEEE-754 big-endian 32-bit float.
     *
     * Params:
     *   val = Output float value.
     *
     * Returns:
     *   True on success; false if fewer than 4 bytes remain.
     */
    bool readF32BE(out float val) {
        if (!canRead(4)) {
            return false;
        }
        ubyte[4] buf = data_[pos_ .. pos_ + 4];
        pos_ += 4;
        val = bigEndianToNative!float(buf);
        return true;
    }

    /**
     * Reads an IEEE-754 big-endian 64-bit double.
     *
     * Params:
     *   val = Output double value.
     *
     * Returns:
     *   True on success; false if fewer than 8 bytes remain.
     */
    bool readF64BE(out double val) {
        if (!canRead(8)) {
            return false;
        }
        ubyte[8] buf = data_[pos_ .. pos_ + 8];
        pos_ += 8;
        val = bigEndianToNative!double(buf);
        return true;
    }

    /**
     * Decodes a Standard MIDI variable-length quantity (1..4 bytes, 28-bit maximum).
     *
     * Params:
     *   val = Decoded unsigned 28-bit quantity.
     *
     * Returns:
     *   True on valid VLQ termination within 4 bytes; false on truncation or > 4 bytes.
     */
    bool readMidiVlq(out uint val) {
        val = 0;
        uint acc = 0;
        foreach (_; 0 .. 4) {
            ubyte b = 0;
            if (!readU8(b)) {
                return false;
            }
            acc = (acc << 7) | (b & 0x7Fu);
            if ((b & 0x80u) == 0) {
                val = acc;
                return true;
            }
        }
        return false;
    }

    /**
     * Reads count raw bytes as a zero-copy slice view into the backing buffer.
     *
     * Params:
     *   count = Byte count to slice.
     *   outSlice = Output byte slice view.
     *
     * Returns:
     *   True on success; false if fewer than count bytes remain.
     */
    bool readBytes(size_t count, out const(ubyte)[] outSlice) {
        if (!canRead(count)) {
            return false;
        }
        outSlice = data_[pos_ .. pos_ + count];
        pos_ += count;
        return true;
    }

    /**
     * Reads a 4-byte ASCII FourCC tag cleanly.
     *
     * Params:
     *   id = Output 4-character tag buffer.
     *
     * Returns:
     *   True on success; false if fewer than 4 bytes remain.
     */
    bool readFourCC(out char[4] id) {
        if (!canRead(4)) {
            return false;
        }
        foreach (i; 0 .. 4) {
            id[i] = cast(char) data_[pos_ + i];
        }
        pos_ += 4;
        return true;
    }

    /**
     * Reads a little-endian uint length prefix capped at maxLen, followed by its raw byte slice.
     *
     * Params:
     *   maxLen = Maximum permitted payload byte length.
     *   outSlice = Output zero-copy payload slice.
     *
     * Returns:
     *   True on success; false if length exceeds maxLen or exceeds remaining bytes.
     */
    bool readLengthPrefixedBytes(size_t maxLen, out const(ubyte)[] outSlice) {
        uint len = 0;
        if (!readU32(len)) {
            return false;
        }
        if (cast(size_t) len > maxLen || !canRead(len)) {
            return false;
        }
        outSlice = data_[pos_ .. pos_ + len];
        pos_ += len;
        return true;
    }

    /**
     * Reads a tagged 4CC + uint-length chunk into an isolated bounded sub-BinaryReader.
     *
     * Advances this parent reader past the entire chunk payload cleanly.
     *
     * Params:
     *   id = Output 4-character chunk identifier.
     *   subReader = Sub-reader bounded strictly to the chunk's payload bytes.
     *
     * Returns:
     *   True on success; false if header or declared payload extends past remaining bytes.
     */
    bool readChunk(out char[4] id, out BinaryReader subReader) {
        uint chunkSize = 0;
        if (!readFourCC(id) || !readU32(chunkSize)) {
            return false;
        }
        if (!canRead(chunkSize)) {
            return false;
        }
        subReader = BinaryReader(data_[pos_ .. pos_ + chunkSize]);
        pos_ += chunkSize;
        return true;
    }
    }

    /**
     * Reads a little-endian uint-prefixed UTF-8 string capped at maxLen bytes.
     *
     * Params:
     *   maxLen = Maximum permitted string byte count.
     *   outStr = Newly copied immutable UTF-8 string on success.
     *
     * Returns:
     *   True on success; false on overflow or truncation.
     */
    bool readString(size_t maxLen, out string outStr) @safe pure nothrow {
        const(ubyte)[] slice;
        if (!readLengthPrefixedBytes(maxLen, slice)) {
            return false;
        }
        if (slice.length == 0) {
            outStr = null;
            return true;
        }
        outStr = cast(string)(slice.idup);
        return true;
    }
}

/**
 * Growable @safe little-endian/big-endian binary stream writer with tagged chunk framing.
 */
struct BinaryWriter {
    private ubyte[] buf_;

    @safe nothrow:

    /**
     * Returns read-only view of all serialized bytes emitted so far.
     *
     * Returns:
     *   Serialized byte slice.
     */
    const(ubyte)[] bytes() const pure {
        return buf_;
    }

    /**
     * Returns current output size in bytes.
     *
     * Returns:
     *   Emitted byte length.
     */
    size_t length() const pure {
        return buf_.length;
    }

    /**
     * Resets emitted length to zero while keeping allocated slice capacity for reuse.
     */
    void clear() pure {
        buf_.length = 0;
    }

    /**
     * Appends an unsigned 8-bit integer.
     *
     * Params:
     *   val = Byte to append.
     */
    void writeU8(ubyte val) {
        buf_ ~= val;
    }

    /**
     * Appends a signed 8-bit integer.
     *
     * Params:
     *   val = Signed byte to append.
     */
    void writeI8(byte val) {
        buf_ ~= cast(ubyte) val;
    }

    /**
     * Appends a little-endian unsigned 16-bit integer.
     *
     * Params:
     *   val = Value to encode.
     */
    void writeU16(ushort val) {
        buf_ ~= nativeToLittleEndian(val)[];
    }

    /**
     * Appends a little-endian signed 16-bit integer.
     *
     * Params:
     *   val = Value to encode.
     */
    void writeI16(short val) {
        buf_ ~= nativeToLittleEndian(val)[];
    }

    /**
     * Appends a little-endian unsigned 32-bit integer.
     *
     * Params:
     *   val = Value to encode.
     */
    void writeU32(uint val) {
        buf_ ~= nativeToLittleEndian(val)[];
    }

    /**
     * Appends a little-endian signed 32-bit integer.
     *
     * Params:
     *   val = Value to encode.
     */
    void writeI32(int val) {
        buf_ ~= nativeToLittleEndian(val)[];
    }

    /**
     * Appends a little-endian unsigned 64-bit integer.
     *
     * Params:
     *   val = Value to encode.
     */
    void writeU64(ulong val) {
        buf_ ~= nativeToLittleEndian(val)[];
    }

    /**
     * Appends a little-endian signed 64-bit integer.
     *
     * Params:
     *   val = Value to encode.
     */
    void writeI64(long val) {
        buf_ ~= nativeToLittleEndian(val)[];
    }

    /**
     * Appends a little-endian IEEE-754 32-bit float.
     *
     * Params:
     *   val = Float value to encode.
     */
    void writeF32(float val) {
        buf_ ~= nativeToLittleEndian(val)[];
    }

    /**
     * Appends a little-endian IEEE-754 64-bit double.
     *
     * Params:
     *   val = Double value to encode.
     */
    void writeF64(double val) {
        buf_ ~= nativeToLittleEndian(val)[];
    }

    /**
     * Appends a big-endian unsigned 16-bit integer.
     *
     * Params:
     *   val = Value to encode.
     */
    void writeU16BE(ushort val) {
        buf_ ~= nativeToBigEndian(val)[];
    }

    /**
     * Appends a big-endian unsigned 32-bit integer.
     *
     * Params:
     *   val = Value to encode.
     */
    void writeU32BE(uint val) {
        buf_ ~= nativeToBigEndian(val)[];
    }

    /**
     * Appends a big-endian signed 32-bit integer.
     *
     * Params:
     *   val = Value to encode.
     */
    void writeI32BE(int val) {
        buf_ ~= nativeToBigEndian(val)[];
    }

    /**
     * Appends a big-endian unsigned 64-bit integer.
     *
     * Params:
     *   val = Value to encode.
     */
    void writeU64BE(ulong val) {
        buf_ ~= nativeToBigEndian(val)[];
    }

    /**
     * Appends raw bytes verbatim.
     *
     * Params:
     *   src = Raw byte slice to append.
     */
    void writeBytes(const(ubyte)[] src) {
        if (src.length > 0) {
            buf_ ~= src;
        }
    }

    /**
     * Appends a 4-byte ASCII FourCC tag verbatim.
     *
     * Params:
     *   id = Four-character tag identifier.
     */
    void writeFourCC(char[4] id) {
        foreach (c; id) {
            buf_ ~= cast(ubyte) c;
        }
    }

    /**
     * Appends a little-endian uint length prefix followed by src bytes.
     *
     * Params:
     *   src = Byte slice payload to serialize.
     */
    void writeLengthPrefixedBytes(const(ubyte)[] src) {
        writeU32(cast(uint) src.length);
        writeBytes(src);
    }

    /**
     * Appends a little-endian uint length prefix followed by UTF-8 bytes of str.
     *
     * Params:
     *   str = UTF-8 string to serialize.
     */
    void writeString(string str) {
        writeLengthPrefixedBytes(cast(const(ubyte)[]) str);
    }

    /**
     * Emits a 4CC tag, little-endian uint length prefix, and pre-built payload slice.
     *
     * Params:
     *   id = 4-character chunk tag.
     *   payload = Pre-encoded raw chunk payload bytes.
     */
    void writeChunk(char[4] id, const(ubyte)[] payload) {
        writeFourCC(id);
        writeU32(cast(uint) payload.length);
        writeBytes(payload);
    }

    /**
     * Serializes a sub-chunk into a scratch BinaryWriter, then emits 4CC, uint payload length, and bytes.
     *
     * Params:
     *   id = 4-character chunk tag.
     *   bodyFn = Safe callback populating the chunk payload writer.
     */
    void writeChunk(char[4] id, scope void delegate(ref BinaryWriter) @safe nothrow bodyFn) {
        BinaryWriter sub;
        if (bodyFn !is null) {
            bodyFn(sub);
        }
        writeFourCC(id);
        writeU32(cast(uint) sub.length());
        writeBytes(sub.bytes());
    }
}
