/**
 * File:         source/app/pattern_ops.d
 * Module:       app.pattern_ops
 * Phase:        Phase 7.5.5 — Pattern Block Operations & Dracker-Block-v1 Clipboard Codec
 *
 * Purpose:
 *   Pure, headless-testable rectangular pattern block helpers (extract, clipped write, clear, transpose,
 *   per-column linear interpolation) and the strict, versioned Dracker-Block-v1 clipboard text codec
 *   used by the pattern editor's cut/copy/paste and by grouped undoable block commands in app.session.
 *
 * Real-Time & Safety Contract:
 *   UI-thread only, @safe nothrow pure; never touches the Engine or RT state. The text decoder never
 *   throws, validates every dimension (tracks <= 64, lines <= 4096, cells <= 262144) and the minimum
 *   input length before allocating, and rejects any malformed, oversized, or trailing-garbage input.
 *
 * Dependencies:
 *   Internal: sequencer.note (NoteCell)
 *   External: None
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum uint MAX_BLOCK_TRACKS = 64, MAX_BLOCK_LINES = 4096, MAX_BLOCK_CELLS = 262_144
 *   - enum string BLOCK_TEXT_MAGIC = "Dracker-Block-v1"
 *   - struct PatternBlock { uint tracks; uint lines; NoteCell[] cells; isValid(), at(), set(), create() }
 *   - bool blockDimsAllowed(ulong tracks, ulong lines)
 *   - PatternBlock extractBlock(cells, patTracks, patLines, track, line, w, h)
 *   - size_t writeBlockInto(cells, patTracks, patLines, track, line, block, skipEmpty = false)
 *   - size_t clearRegion(cells, patTracks, patLines, track, line, w, h)
 *   - size_t clearBlock(ref PatternBlock)
 *   - size_t transposeBlock(ref PatternBlock, int semitones [, out size_t outOfRange])
 *   - enum InterpolateField { velocity, effectValue, paramId }
 *   - bool interpolateColumn(ref PatternBlock, uint track, InterpolateField)
 *   - string encodeBlockText(const ref PatternBlock)
 *   - bool decodeBlockText(const(char)[] text, out PatternBlock, out string err)
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module app.pattern_ops;

import sequencer.note : NoteCell;

enum uint MAX_BLOCK_TRACKS = 64;

enum uint MAX_BLOCK_LINES = 4096;

enum uint MAX_BLOCK_CELLS = 262_144;

enum string BLOCK_TEXT_MAGIC = "Dracker-Block-v1";

private enum size_t CELL_TEXT_CHARS = 16;

/**
 * Rectangular, row-major copy of pattern cells where index = line * tracks + track.
 */
struct PatternBlock {
    uint tracks = 0;
    uint lines = 0;
    NoteCell[] cells;

    @safe nothrow pure:

    /**
     * Allocates a zero-filled block of the given dimensions.
     *
     * Params:
     *   tracks = Block width in tracks (1..MAX_BLOCK_TRACKS).
     *   lines = Block height in lines (1..MAX_BLOCK_LINES).
     *
     * Returns:
     *   A valid empty-celled block, or an invalid zero-sized block when the dimensions exceed the limits.
     */
    static PatternBlock create(uint tracks, uint lines) {
        PatternBlock b;
        if (!blockDimsAllowed(tracks, lines)) {
            return b;
        }
        b.tracks = tracks;
        b.lines = lines;
        b.cells = new NoteCell[](cast(size_t) tracks * lines);
        return b;
    }

    /**
     * Reports whether the dimensions are non-zero, within limits, and match the cell array length.
     *
     * Returns:
     *   True when the block may be safely indexed and encoded.
     */
    bool isValid() const @nogc {
        return blockDimsAllowed(tracks, lines) && cells.length == cast(size_t) tracks * lines;
    }

    /**
     * Reads the cell at (track, line).
     *
     * Params:
     *   track = Zero-based column inside the block.
     *   line = Zero-based row inside the block.
     *
     * Returns:
     *   The cell, or an empty NoteCell when the coordinates are outside the block or the block is invalid.
     */
    NoteCell at(uint track, uint line) const @nogc {
        if (!isValid() || track >= tracks || line >= lines) {
            return NoteCell.init;
        }
        return cells[cast(size_t) line * tracks + track];
    }

    /**
     * Writes the cell at (track, line).
     *
     * Params:
     *   track = Zero-based column inside the block.
     *   line = Zero-based row inside the block.
     *   cell = New cell value.
     *
     * Returns:
     *   True if written; false when out of bounds or the block is invalid.
     */
    bool set(uint track, uint line, NoteCell cell) @nogc {
        if (!isValid() || track >= tracks || line >= lines) {
            return false;
        }
        cells[cast(size_t) line * tracks + track] = cell;
        return true;
    }
}

/**
 * Checks block dimension limits without allocating.
 *
 * Params:
 *   tracks = Candidate width.
 *   lines = Candidate height.
 *
 * Returns:
 *   True when 1 <= tracks <= 64, 1 <= lines <= 4096 and tracks * lines <= 262144.
 */
bool blockDimsAllowed(ulong tracks, ulong lines) @safe @nogc nothrow pure {
    return tracks >= 1 && tracks <= MAX_BLOCK_TRACKS && lines >= 1 && lines <= MAX_BLOCK_LINES
        && tracks * lines <= MAX_BLOCK_CELLS;
}

private bool patternShapeOk(size_t cellCount, uint patTracks, uint patLines) @safe @nogc nothrow pure {
    return patTracks >= 1 && patLines >= 1 && cellCount >= cast(ulong) patTracks * patLines;
}

private uint clampSpan(uint origin, uint span, uint limit, uint cap) @safe @nogc nothrow pure {
    immutable uint avail = limit - origin;
    uint s = span < avail ? span : avail;
    return s < cap ? s : cap;
}

/**
 * Copies a rectangular region of a row-major pattern into a new block, clamped to the pattern bounds.
 *
 * The region is clipped to the pattern edges and additionally capped at MAX_BLOCK_TRACKS x MAX_BLOCK_LINES.
 *
 * Params:
 *   cells = Row-major pattern cells (index = line * patTracks + track).
 *   patTracks = Pattern width in tracks.
 *   patLines = Pattern height in lines.
 *   track = Region origin column.
 *   line = Region origin row.
 *   w = Requested region width.
 *   h = Requested region height.
 *
 * Returns:
 *   The clipped block, or an invalid zero-sized block when the region is empty or the pattern shape is inconsistent.
 */
PatternBlock extractBlock(const(NoteCell)[] cells, uint patTracks, uint patLines, uint track, uint line,
    uint w, uint h) @safe nothrow pure {
    if (!patternShapeOk(cells.length, patTracks, patLines) || track >= patTracks || line >= patLines
        || w == 0 || h == 0) {
        return PatternBlock.init;
    }
    immutable uint bw = clampSpan(track, w, patTracks, MAX_BLOCK_TRACKS);
    immutable uint bh = clampSpan(line, h, patLines, MAX_BLOCK_LINES);
    PatternBlock b = PatternBlock.create(bw, bh);
    if (!b.isValid()) {
        return PatternBlock.init;
    }
    foreach (r; 0 .. bh) {
        immutable size_t src = cast(size_t)(line + r) * patTracks + track;
        immutable size_t dst = cast(size_t) r * bw;
        b.cells[dst .. dst + bw] = cells[src .. src + bw];
    }
    return b;
}

/**
 * Writes a block into a row-major pattern at (track, line), clipping anything past the pattern edges.
 *
 * Params:
 *   cells = Row-major destination pattern cells.
 *   patTracks = Pattern width in tracks.
 *   patLines = Pattern height in lines.
 *   track = Destination origin column.
 *   line = Destination origin row.
 *   b = Source block (ignored when invalid).
 *   skipEmpty = When true, completely empty block cells leave the destination untouched (mix-paste).
 *
 * Returns:
 *   Number of destination cells written.
 */
size_t writeBlockInto(NoteCell[] cells, uint patTracks, uint patLines, uint track, uint line,
    const ref PatternBlock b, bool skipEmpty = false) @safe @nogc nothrow pure {
    if (!b.isValid() || !patternShapeOk(cells.length, patTracks, patLines) || track >= patTracks
        || line >= patLines) {
        return 0;
    }
    immutable uint w = clampSpan(track, b.tracks, patTracks, MAX_BLOCK_TRACKS);
    immutable uint h = clampSpan(line, b.lines, patLines, MAX_BLOCK_LINES);
    size_t written = 0;
    foreach (r; 0 .. h) {
        foreach (c; 0 .. w) {
            immutable NoteCell src = b.cells[cast(size_t) r * b.tracks + c];
            if (skipEmpty && src.isEmpty()) {
                continue;
            }
            cells[cast(size_t)(line + r) * patTracks + track + c] = src;
            written++;
        }
    }
    return written;
}

/**
 * Resets a rectangular pattern region to empty cells, clipped to the pattern bounds.
 *
 * Params:
 *   cells = Row-major pattern cells.
 *   patTracks = Pattern width in tracks.
 *   patLines = Pattern height in lines.
 *   track = Region origin column.
 *   line = Region origin row.
 *   w = Region width.
 *   h = Region height.
 *
 * Returns:
 *   Number of cells inside the clipped region (all of which are now empty).
 */
size_t clearRegion(NoteCell[] cells, uint patTracks, uint patLines, uint track, uint line, uint w, uint h)
    @safe @nogc nothrow pure {
    if (!patternShapeOk(cells.length, patTracks, patLines) || track >= patTracks || line >= patLines) {
        return 0;
    }
    immutable uint cw = clampSpan(track, w, patTracks, uint.max);
    immutable uint ch = clampSpan(line, h, patLines, uint.max);
    foreach (r; 0 .. ch) {
        immutable size_t start = cast(size_t)(line + r) * patTracks + track;
        cells[start .. start + cw] = NoteCell.init;
    }
    return cast(size_t) cw * ch;
}

/**
 * Resets every cell of a block to empty while keeping its dimensions.
 *
 * Params:
 *   b = Block to clear.
 *
 * Returns:
 *   Number of cells cleared (0 for an invalid block).
 */
size_t clearBlock(ref PatternBlock b) @safe @nogc nothrow pure {
    if (!b.isValid()) {
        return 0;
    }
    b.cells[] = NoteCell.init;
    return b.cells.length;
}

/**
 * Transposes every real note (stored 1..128) in the block by a number of semitones.
 *
 * Empty cells and NoteCmd cells (note-off and other commands >= 240) are never modified. A note whose
 * result would leave MIDI 0..127 is left unchanged and counted in outOfRange.
 *
 * Params:
 *   b = Block to modify in place.
 *   semitones = Signed semitone offset.
 *   outOfRange = Receives the number of notes skipped because they would leave the MIDI range.
 *
 * Returns:
 *   Number of notes transposed.
 */
size_t transposeBlock(ref PatternBlock b, int semitones, out size_t outOfRange) @safe @nogc nothrow pure {
    outOfRange = 0;
    if (!b.isValid()) {
        return 0;
    }
    size_t moved = 0;
    foreach (ref cell; b.cells) {
        if (!cell.isMidiNote()) {
            continue;
        }
        immutable long target = cast(long) cell.note + semitones;
        if (target < 1 || target > 128) {
            outOfRange++;
            continue;
        }
        cell.note = cast(ubyte) target;
        moved++;
    }
    return moved;
}

/**
 * Transposes every real note in the block, discarding the out-of-range count.
 *
 * Params:
 *   b = Block to modify in place.
 *   semitones = Signed semitone offset.
 *
 * Returns:
 *   Number of notes transposed.
 */
size_t transposeBlock(ref PatternBlock b, int semitones) @safe @nogc nothrow pure {
    size_t skipped;
    return transposeBlock(b, semitones, skipped);
}

/**
 * NoteCell column targeted by interpolateColumn.
 */
enum InterpolateField : ubyte {
    velocity,
    effectValue,
    paramId
}

private long readField(const ref NoteCell c, InterpolateField f) @safe @nogc nothrow pure {
    final switch (f) {
        case InterpolateField.velocity:
            return c.velocity;
        case InterpolateField.effectValue:
            return c.effectVal;
        case InterpolateField.paramId:
            return c.paramId;
    }
}

private void writeField(ref NoteCell c, InterpolateField f, long v) @safe @nogc nothrow pure {
    final switch (f) {
        case InterpolateField.velocity:
            c.velocity = cast(ubyte) v;
            break;
        case InterpolateField.effectValue:
            c.effectVal = cast(ubyte) v;
            break;
        case InterpolateField.paramId:
            c.paramId = cast(ushort) v;
            break;
    }
}

private long lerpRounded(long v0, long v1, long pos, long span) @safe @nogc nothrow pure {
    immutable long num = (v1 - v0) * pos;
    immutable long half = span / 2;
    immutable long step = num >= 0 ? (num + half) / span : -((-num + half) / span);
    return v0 + step;
}

/**
 * Linearly interpolates one field down a block column between its first and last non-empty cells.
 *
 * Values are rounded to the nearest integer, with exact halves rounded away from the start value. If any non-empty cell lies strictly between the two endpoints, only those
 * in-between non-empty cells are rewritten, so sparse note columns keep their gaps. If every in-between
 * cell is empty, the field is written on all in-between rows (other fields, including the note, stay
 * empty) so a ramp can be drawn between two automation points. The endpoints are never modified.
 *
 * Params:
 *   b = Block to modify in place.
 *   track = Zero-based column inside the block.
 *   f = Field to interpolate (velocity, effectVal, or paramId).
 *
 * Returns:
 *   False (leaving the block untouched) if the block is invalid, track is out of range, or the column
 *   holds fewer than two non-empty cells; true otherwise.
 */
bool interpolateColumn(ref PatternBlock b, uint track, InterpolateField f) @safe @nogc nothrow pure {
    if (!b.isValid() || track >= b.tracks) {
        return false;
    }
    long first = -1;
    long last = -1;
    size_t nonEmpty = 0;
    foreach (r; 0 .. b.lines) {
        if (!b.cells[cast(size_t) r * b.tracks + track].isEmpty()) {
            if (first < 0) {
                first = r;
            }
            last = r;
            nonEmpty++;
        }
    }
    if (nonEmpty < 2) {
        return false;
    }
    immutable long v0 = readField(b.cells[cast(size_t) first * b.tracks + track], f);
    immutable long v1 = readField(b.cells[cast(size_t) last * b.tracks + track], f);
    immutable long span = last - first;
    immutable bool fillAll = nonEmpty == 2;
    foreach (r; first + 1 .. last) {
        NoteCell* cell = &b.cells[cast(size_t) r * b.tracks + track];
        if (!fillAll && cell.isEmpty()) {
            continue;
        }
        writeField(*cell, f, lerpRounded(v0, v1, r - first, span));
    }
    return true;
}

private immutable char[16] HEX_DIGITS = "0123456789ABCDEF";

private size_t decimalDigits(uint v) @safe @nogc nothrow pure {
    size_t n = 1;
    while (v >= 10) {
        v /= 10;
        n++;
    }
    return n;
}

private size_t putDecimal(char[] buf, size_t pos, uint v) @safe @nogc nothrow pure {
    immutable size_t n = decimalDigits(v);
    foreach_reverse (i; 0 .. n) {
        buf[pos + i] = cast(char)('0' + v % 10);
        v /= 10;
    }
    return pos + n;
}

/**
 * Serializes a block to Dracker-Block-v1 clipboard text.
 *
 * Layout: "Dracker-Block-v1 <tracks> <lines>\n", then one "\n"-terminated row per line whose cells are
 * separated by '|'; each cell is its packU64() value as 16 uppercase hex digits, or "................" when empty.
 *
 * Params:
 *   b = Block to encode.
 *
 * Returns:
 *   Encoded text, or an empty string when the block is invalid.
 */
string encodeBlockText(const ref PatternBlock b) @safe nothrow pure {
    if (!b.isValid()) {
        return "";
    }
    immutable size_t headerLen = BLOCK_TEXT_MAGIC.length + 1 + decimalDigits(b.tracks) + 1
        + decimalDigits(b.lines) + 1;
    immutable size_t rowLen = b.tracks * CELL_TEXT_CHARS + (b.tracks - 1) + 1;
    char[] buf = new char[](headerLen + rowLen * b.lines);
    size_t pos = 0;
    buf[pos .. pos + BLOCK_TEXT_MAGIC.length] = BLOCK_TEXT_MAGIC;
    pos += BLOCK_TEXT_MAGIC.length;
    buf[pos++] = ' ';
    pos = putDecimal(buf, pos, b.tracks);
    buf[pos++] = ' ';
    pos = putDecimal(buf, pos, b.lines);
    buf[pos++] = '\n';
    foreach (r; 0 .. b.lines) {
        foreach (c; 0 .. b.tracks) {
            if (c > 0) {
                buf[pos++] = '|';
            }
            immutable ulong bits = b.cells[cast(size_t) r * b.tracks + c].packU64();
            if (bits == 0) {
                buf[pos .. pos + CELL_TEXT_CHARS] = '.';
            } else {
                foreach (i; 0 .. CELL_TEXT_CHARS) {
                    buf[pos + i] = HEX_DIGITS[cast(size_t)((bits >> ((CELL_TEXT_CHARS - 1 - i) * 4)) & 0xF)];
                }
            }
            pos += CELL_TEXT_CHARS;
        }
        buf[pos++] = '\n';
    }
    return (() @trusted => cast(string) buf)();
}

private bool parseDim(const(char)[] text, ref size_t pos, out uint value) @safe @nogc nothrow pure {
    value = 0;
    immutable size_t start = pos;
    while (pos < text.length && text[pos] >= '0' && text[pos] <= '9') {
        if (pos - start >= 5) {
            return false;
        }
        value = value * 10 + cast(uint)(text[pos] - '0');
        pos++;
    }
    if (pos == start || text[start] == '0') {
        return false;
    }
    return true;
}

private bool consumeLineEnd(const(char)[] text, ref size_t pos) @safe @nogc nothrow pure {
    if (pos < text.length && text[pos] == '\n') {
        pos++;
        return true;
    }
    if (pos + 1 < text.length && text[pos] == '\r' && text[pos + 1] == '\n') {
        pos += 2;
        return true;
    }
    return false;
}

private int hexValue(char ch) @safe @nogc nothrow pure {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    return -1;
}

private bool parseCell(const(char)[] text, size_t pos, out ulong bits) @safe @nogc nothrow pure {
    bits = 0;
    if (text[pos] == '.') {
        foreach (i; 0 .. CELL_TEXT_CHARS) {
            if (text[pos + i] != '.') {
                return false;
            }
        }
        return true;
    }
    foreach (i; 0 .. CELL_TEXT_CHARS) {
        immutable int d = hexValue(text[pos + i]);
        if (d < 0) {
            return false;
        }
        bits = (bits << 4) | cast(ulong) d;
    }
    return true;
}

/**
 * Strictly parses Dracker-Block-v1 clipboard text into a block.
 *
 * Accepts "\n" or "\r\n" line endings and an optional single line ending after the last row; hex digits may
 * be upper- or lower-case, and an all-zero hex cell is accepted as empty. Rejects a wrong magic/version,
 * malformed or leading-zero dimensions, dimensions outside the block limits, wrong row or cell counts,
 * bad hex or partial "." cells, and any trailing bytes. Dimensions and the minimum input length are
 * validated before the cell array is allocated.
 *
 * Params:
 *   text = Candidate clipboard text.
 *   b = Receives the decoded block on success (an invalid empty block on failure).
 *   err = Receives a static diagnostic on failure (null on success).
 *
 * Returns:
 *   True when the entire text is a well-formed block.
 */
bool decodeBlockText(const(char)[] text, out PatternBlock b, out string err) @safe nothrow pure {
    immutable size_t magicLen = BLOCK_TEXT_MAGIC.length;
    if (text.length < magicLen + 1 || text[0 .. magicLen] != BLOCK_TEXT_MAGIC || text[magicLen] != ' ') {
        err = "missing Dracker-Block-v1 header";
        return false;
    }
    size_t pos = magicLen + 1;
    uint tracks = 0;
    uint lines = 0;
    if (!parseDim(text, pos, tracks) || pos >= text.length || text[pos] != ' ') {
        err = "malformed track count";
        return false;
    }
    pos++;
    if (!parseDim(text, pos, lines) || !consumeLineEnd(text, pos)) {
        err = "malformed line count";
        return false;
    }
    if (!blockDimsAllowed(tracks, lines)) {
        err = "block dimensions out of range";
        return false;
    }
    immutable size_t rowChars = tracks * CELL_TEXT_CHARS + (tracks - 1);
    if (text.length - pos < rowChars * lines + (lines - 1)) {
        err = "text too short for declared dimensions";
        return false;
    }
    NoteCell[] cells = new NoteCell[](cast(size_t) tracks * lines);
    foreach (r; 0 .. lines) {
        if (r > 0 && !consumeLineEnd(text, pos)) {
            err = "bad row terminator";
            return false;
        }
        if (text.length - pos < rowChars) {
            err = "row too short";
            return false;
        }
        foreach (c; 0 .. tracks) {
            if (c > 0) {
                if (text[pos] != '|') {
                    err = "bad cell separator";
                    return false;
                }
                pos++;
            }
            ulong bits = 0;
            if (!parseCell(text, pos, bits)) {
                err = "bad cell value";
                return false;
            }
            cells[cast(size_t) r * tracks + c] = NoteCell.unpackU64(bits);
            pos += CELL_TEXT_CHARS;
        }
    }
    if (pos < text.length && !consumeLineEnd(text, pos)) {
        err = "trailing garbage after last row";
        return false;
    }
    if (pos != text.length) {
        err = "trailing garbage after last row";
        return false;
    }
    b.tracks = tracks;
    b.lines = lines;
    b.cells = cells;
    err = null;
    return true;
}
