//! Brotli decompression (RFC 7932): the compressed format WOFF 2.0 fonts use.
//!
//! The whole stream is decoded into one buffer, so every backward reference reaches
//! straight into the output. Every read is bounds-checked: corrupt or truncated input
//! returns an error, never a crash.

const std = @import("std");

/// Why a stream did not decode.
pub const Error = error{
    /// The stream breaks a rule of the format.
    InvalidData,
    /// The stream ends before its last meta-block does.
    Truncated,
    /// The output would be longer than the caller's limit.
    OutputTooLarge,
    OutOfMemory,
};

/// The static dictionary (RFC 7932 Appendix A): 122,784 bytes, CRC-32 0x5136cb04.
const dictionary = @embedFile("brotli_dictionary.bin");

/// Bits of the word index for each word length (Appendix A, NDBITS).
const ndbits = [25]u5{ 0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5 };

/// Where the words of each length start in the dictionary (section 8, DOFFSET).
const doffset = blk: {
    var off: [25]u32 = undefined;
    var at: u32 = 0;
    for (0..25) |len| {
        off[len] = at;
        if (len >= 4) at += len << ndbits[len];
    }
    break :blk off;
};

comptime {
    if (dictionary.len != 122784 or doffset[24] + (24 << ndbits[24]) != dictionary.len) @compileError("brotli dictionary size");
}

/// Decompresses the Brotli stream `input`, at most `limit` bytes of output. The caller
/// owns the returned slice.
pub fn decompress(gpa: std.mem.Allocator, input: []const u8, limit: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var br: Bits = .{
        .data = input,
    };
    const window = (@as(usize, 1) << try readWindowBits(&br)) - 16;
    // The four last distances, last first (section 4).
    var dists = [4]i64{ 4, 11, 15, 16 };

    while (true) {
        const is_last = try br.read(1) == 1;
        if (is_last and try br.read(1) == 1) break;
        const nibbles_code = try br.read(2);
        if (nibbles_code == 3) {
            // A metadata block: skipped.
            if (try br.read(1) != 0) return error.InvalidData;
            const skip_bytes = try br.read(2);
            var skip_len: usize = 0;
            if (skip_bytes > 0) {
                for (0..skip_bytes) |k| {
                    const b = try br.read(8);
                    if (k == skip_bytes - 1 and skip_bytes > 1 and b == 0) return error.InvalidData;
                    skip_len |= @as(usize, b) << @intCast(8 * k);
                }
                skip_len += 1;
            }
            try br.alignToByte();
            _ = try br.bytes(skip_len);
            if (is_last) break;
            continue;
        }
        const nibbles = nibbles_code + 4;
        var mlen: usize = 0;
        for (0..nibbles) |k| {
            const nib = try br.read(4);
            if (k == nibbles - 1 and nibbles > 4 and nib == 0) return error.InvalidData;
            mlen |= @as(usize, nib) << @intCast(4 * k);
        }
        mlen += 1;
        if (mlen > limit - out.items.len) return error.OutputTooLarge;
        try out.ensureUnusedCapacity(gpa, mlen);

        if (!is_last and try br.read(1) == 1) {
            try br.alignToByte();
            out.appendSliceAssumeCapacity(try br.bytes(mlen));
            continue;
        }

        _ = arena_state.reset(.retain_capacity);
        try decodeMetaBlock(arena_state.allocator(), &br, &out, out.items.len + mlen, window, &dists);
        if (is_last) break;
    }
    // The last byte's unused bits are zeros.
    try br.alignToByte();
    return out.toOwnedSlice(gpa);
}

/// Reads WBITS (section 9.1).
fn readWindowBits(br: *Bits) Error!u5 {
    if (try br.read(1) == 0) return 16;
    const n = try br.read(3);
    if (n != 0) return @intCast(17 + n);
    const m = try br.read(3);
    if (m == 1) return error.InvalidData;
    if (m != 0) return @intCast(8 + m);
    return 17;
}

/// One of the three block categories: literals, insert-and-copy lengths, distances.
const Category = struct {
    types: u32,
    type_code: Code = .{},
    count_code: Code = .{},
    current: u32 = 0,
    previous: u32 = 1,
    /// Symbols left in the current block.
    left: u32 = 1 << 24,

    fn read(arena: std.mem.Allocator, br: *Bits) Error!Category {
        var c: Category = .{
            .types = try readCount256(br),
        };
        if (c.types >= 2) {
            c.type_code = try readCode(arena, br, c.types + 2);
            c.count_code = try readCode(arena, br, 26);
            c.left = try readBlockCount(&c.count_code, br);
        }
        return c;
    }

    /// Takes one symbol from the current block, switching blocks when it is used up.
    fn next(c: *Category, br: *Bits) Error!void {
        if (c.left == 0) {
            if (c.types < 2) {
                c.left = 1 << 24;
            } else {
                const s = try c.type_code.decode(br);
                const t: u32 = switch (s) {
                    0 => c.previous,
                    1 => (c.current + 1) % c.types,
                    else => s - 2,
                };
                if (t >= c.types) return error.InvalidData;
                c.previous = c.current;
                c.current = t;
                c.left = try readBlockCount(&c.count_code, br);
            }
        }
        c.left -= 1;
    }
};

const block_count_base = [26]u32{ 1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625 };
const block_count_extra = [26]u5{ 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24 };
const insert_base = [24]u32{ 0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594 };
const insert_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24 };
const copy_base = [24]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118 };
const copy_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24 };
/// Per 64-symbol cell of the insert-and-copy alphabet: the first insert and copy codes.
const cell_insert = [11]u8{ 0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16 };
const cell_copy = [11]u8{ 0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16 };

fn readBlockCount(code: *const Code, br: *Bits) Error!u32 {
    const s = try code.decode(br);
    if (s >= 26) return error.InvalidData;
    return block_count_base[s] + try br.read(block_count_extra[s]);
}

/// The 1..256 variable-length count of NBLTYPES and NTREES (section 9.2).
fn readCount256(br: *Bits) Error!u32 {
    if (try br.read(1) == 0) return 1;
    const n = try br.read(3);
    if (n == 0) return 2;
    return (@as(u32, 1) << @intCast(n)) + try br.read(@intCast(n)) + 1;
}

fn decodeMetaBlock(
    arena: std.mem.Allocator,
    br: *Bits,
    out: *std.ArrayList(u8),
    end: usize,
    window: usize,
    dists: *[4]i64,
) Error!void {
    var lit = try Category.read(arena, br);
    var cmd = try Category.read(arena, br);
    var dst = try Category.read(arena, br);
    const npostfix: u5 = @intCast(try br.read(2));
    const ndirect: u32 = try br.read(4) << npostfix;
    const modes = try arena.alloc(u2, lit.types);
    for (modes) |*m| m.* = @intCast(try br.read(2));
    const lit_trees = try readCount256(br);
    const lit_map = try readContextMap(arena, br, lit_trees, 64 * lit.types);
    const dist_trees = try readCount256(br);
    const dist_map = try readContextMap(arena, br, dist_trees, 4 * dst.types);
    const lit_codes = try arena.alloc(Code, lit_trees);
    for (lit_codes) |*c| c.* = try readCode(arena, br, 256);
    const cmd_codes = try arena.alloc(Code, cmd.types);
    for (cmd_codes) |*c| c.* = try readCode(arena, br, 704);
    const dist_alphabet = 16 + ndirect + (@as(u32, 48) << npostfix);
    const dist_codes = try arena.alloc(Code, dist_trees);
    for (dist_codes) |*c| c.* = try readCode(arena, br, dist_alphabet);

    while (out.items.len < end) {
        try cmd.next(br);
        const sym = try cmd_codes[cmd.current].decode(br);
        const cell = sym >> 6;
        const insert_code = cell_insert[cell] + ((sym >> 3) & 7);
        const copy_code = cell_copy[cell] + (sym & 7);
        const insert_len = insert_base[insert_code] + try br.read(insert_extra[insert_code]);
        const copy_len = copy_base[copy_code] + try br.read(copy_extra[copy_code]);

        if (insert_len > end - out.items.len) return error.InvalidData;
        for (0..insert_len) |_| {
            try lit.next(br);
            const n = out.items.len;
            const p1: u8 = if (n >= 1) out.items[n - 1] else 0;
            const p2: u8 = if (n >= 2) out.items[n - 2] else 0;
            const ctx: u32 = switch (modes[lit.current]) {
                0 => p1 & 0x3f,
                1 => p1 >> 2,
                2 => lut0[p1] | lut1[p2],
                3 => (@as(u32, lut2[p1]) << 3) | lut2[p2],
            };
            const tree = lit_map[64 * lit.current + ctx];
            out.appendAssumeCapacity(@intCast(try lit_codes[tree].decode(br)));
        }
        if (out.items.len == end) break;

        var distance: i64 = undefined;
        var push = false;
        if (sym < 128) {
            distance = dists[0];
        } else {
            try dst.next(br);
            const cid: u32 = if (copy_len > 4) 3 else copy_len - 2;
            const tree = dist_map[4 * dst.current + cid];
            const code = try dist_codes[tree].decode(br);
            if (code < 16) {
                distance = switch (code) {
                    0, 1, 2, 3 => dists[code],
                    else => blk: {
                        const offsets = [6]i64{ -1, 1, -2, 2, -3, 3 };
                        break :blk if (code < 10) dists[0] + offsets[code - 4] else dists[1] + offsets[code - 10];
                    },
                };
                if (distance <= 0) return error.InvalidData;
                push = code != 0;
            } else if (code < 16 + ndirect) {
                distance = @as(i64, code) - 15;
                push = true;
            } else {
                const c = code - ndirect - 16;
                const nbits: u5 = @intCast(1 + (c >> (npostfix + 1)));
                const hcode = c >> npostfix;
                const lcode = c & ((@as(u32, 1) << npostfix) - 1);
                const offset = ((@as(i64, 2) + (hcode & 1)) << nbits) - 4;
                const extra: i64 = try br.read(nbits);
                distance = ((offset + extra) << npostfix) + lcode + ndirect + 1;
                push = true;
            }
        }

        const max_distance: i64 = @intCast(@min(window, out.items.len));
        if (distance > max_distance) {
            // A static dictionary word.
            if (copy_len < 4 or copy_len > 24) return error.InvalidData;
            const nb = ndbits[copy_len];
            const word_id: usize = @intCast(distance - max_distance - 1);
            const index = word_id & ((@as(usize, 1) << nb) - 1);
            const transform = word_id >> nb;
            if (transform > 120) return error.InvalidData;
            const start = doffset[copy_len] + index * copy_len;
            var buf: [40]u8 = undefined;
            const word = applyTransform(&buf, dictionary[start..][0..copy_len], @intCast(transform));
            if (word.len > end - out.items.len) return error.InvalidData;
            out.appendSliceAssumeCapacity(word);
        } else {
            if (push) {
                dists[3] = dists[2];
                dists[2] = dists[1];
                dists[1] = dists[0];
                dists[0] = distance;
            }
            if (copy_len > end - out.items.len) return error.InvalidData;
            const d: usize = @intCast(distance);
            var from = out.items.len - d;
            for (0..copy_len) |_| {
                out.appendAssumeCapacity(out.items[from]);
                from += 1;
            }
        }
    }
}

/// Reads a context map of `size` entries over `trees` prefix codes (section 7.3).
fn readContextMap(arena: std.mem.Allocator, br: *Bits, trees: u32, size: usize) Error![]u8 {
    const map = try arena.alloc(u8, size);
    @memset(map, 0);
    if (trees < 2) return map;
    const rlemax: u32 = if (try br.read(1) == 1) try br.read(4) + 1 else 0;
    var code = try readCode(arena, br, trees + rlemax);
    var i: usize = 0;
    while (i < size) {
        const s = try code.decode(br);
        if (s == 0) {
            i += 1;
        } else if (s <= rlemax) {
            const run = (@as(usize, 1) << @intCast(s)) + try br.read(@intCast(s));
            if (run > size - i) return error.InvalidData;
            i += run;
        } else {
            map[i] = @intCast(s - rlemax);
            i += 1;
        }
    }
    if (try br.read(1) == 1) {
        // Inverse move-to-front.
        var mtf: [256]u8 = undefined;
        for (&mtf, 0..) |*m, k| m.* = @intCast(k);
        for (map) |*v| {
            const index = v.*;
            const value = mtf[index];
            v.* = value;
            std.mem.copyBackwards(u8, mtf[1 .. @as(usize, index) + 1], mtf[0..index]);
            mtf[0] = value;
        }
    }
    for (map) |v| if (v >= trees) return error.InvalidData;
    return map;
}

/// Applies word transform `id` (Appendix B) to `word` into `buf`.
fn applyTransform(buf: *[40]u8, word: []const u8, id: u8) []const u8 {
    var n: usize = 0;
    const prefix = prefixes[id];
    @memcpy(buf[0..prefix.len], prefix);
    n += prefix.len;
    const kind = kinds[id];
    var body = word;
    if (kind >= 3 and kind <= 11) {
        body = body[@min(body.len, kind - 2)..];
    } else if (kind >= 12) {
        body = body[0 .. body.len - @min(body.len, kind - 11)];
    }
    const at = n;
    @memcpy(buf[at..][0..body.len], body);
    n += body.len;
    if (kind == 1 and body.len > 0) {
        _ = ferment(buf[at..n], 0);
    } else if (kind == 2) {
        var i: usize = 0;
        while (i < body.len) i += ferment(buf[at..n], i);
    }
    const suffix = suffixes[id];
    @memcpy(buf[n..][0..suffix.len], suffix);
    n += suffix.len;
    return buf[0..n];
}

/// Uppercases the character at `pos` (section 8); returns its length in bytes.
fn ferment(word: []u8, pos: usize) usize {
    if (word[pos] < 192) {
        if (word[pos] >= 97 and word[pos] <= 122) word[pos] ^= 32;
        return 1;
    } else if (word[pos] < 224) {
        if (pos + 1 < word.len) word[pos + 1] ^= 32;
        return 2;
    } else {
        if (pos + 2 < word.len) word[pos + 2] ^= 5;
        return 3;
    }
}

/// The input as a stream of bits, least significant first.
const Bits = struct {
    data: []const u8,
    /// Position in bits.
    pos: usize = 0,

    /// The next `n` (at most 24) bits, zeros past the end of the input.
    fn peek(self: *const Bits, n: u5) u32 {
        const byte = self.pos >> 3;
        var v: u64 = 0;
        if (byte + 8 <= self.data.len) {
            v = std.mem.readInt(u64, self.data[byte..][0..8], .little);
        } else {
            var k: usize = 0;
            while (k < 8 and byte + k < self.data.len) : (k += 1) v |= @as(u64, self.data[byte + k]) << @intCast(8 * k);
        }
        return @truncate((v >> @intCast(self.pos & 7)) & ((@as(u64, 1) << n) - 1));
    }

    fn skip(self: *Bits, n: usize) Error!void {
        if (n > self.data.len * 8 - self.pos) return error.Truncated;
        self.pos += n;
    }

    fn read(self: *Bits, n: u5) Error!u32 {
        const v = self.peek(n);
        try self.skip(n);
        return v;
    }

    /// Skips to the next byte boundary; the skipped bits must be zeros.
    fn alignToByte(self: *Bits) Error!void {
        const r = self.pos & 7;
        if (r != 0 and try self.read(@intCast(8 - r)) != 0) return error.InvalidData;
    }

    /// The next `n` whole bytes (the reader must be byte-aligned).
    fn bytes(self: *Bits, n: usize) Error![]const u8 {
        const at = self.pos >> 3;
        if (n > self.data.len - at) return error.Truncated;
        self.pos += n * 8;
        return self.data[at..][0..n];
    }
};

/// Bits of the first lookup in `Code.decode`; longer codes are walked bit by bit.
const root_bits = 8;
const max_code_len = 15;

/// A canonical prefix code (section 3.2).
const Code = struct {
    /// Indexed by the next `root_bits` bits: symbol << 4 | length, or 0 for a longer code.
    table: [1 << root_bits]u16 = @splat(0),
    /// The only symbol of a code that has one (it takes no bits).
    single: ?u16 = null,
    /// Number of codes of each length.
    counts: [max_code_len + 1]u16 = @splat(0),
    /// Symbols in code order (by length, then value).
    symbols: []const u16 = &.{},

    fn decode(self: *const Code, br: *Bits) Error!u16 {
        if (self.single) |s| return s;
        const e = self.table[br.peek(root_bits)];
        const len = e & 15;
        if (len != 0) {
            try br.skip(len);
            return e >> 4;
        }
        if (self.symbols.len == 0) return error.InvalidData;
        // A code longer than the table: walk it one bit at a time.
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (1..max_code_len + 1) |l| {
            code |= @intCast(try br.read(1));
            const count: i32 = self.counts[l];
            if (code - count < first) return self.symbols[@intCast(index + code - first)];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.InvalidData;
    }

    /// Builds the code from each symbol's code length (0 = unused). The lengths must
    /// make a complete code, or name a single symbol.
    fn build(arena: std.mem.Allocator, lengths: []const u8) Error!Code {
        var c: Code = .{};
        var used: usize = 0;
        var last: usize = 0;
        for (lengths, 0..) |len, s| {
            if (len == 0) continue;
            if (len > max_code_len) return error.InvalidData;
            c.counts[len] += 1;
            used += 1;
            last = s;
        }
        if (used == 0) return error.InvalidData;
        if (used == 1) {
            c.single = @intCast(last);
            return c;
        }
        var left: i32 = 1;
        for (1..max_code_len + 1) |len| {
            left = (left << 1) - c.counts[len];
            if (left < 0) return error.InvalidData;
        }
        if (left != 0) return error.InvalidData;

        var offsets: [max_code_len + 2]u16 = undefined;
        offsets[1] = 0;
        for (1..max_code_len + 1) |len| offsets[len + 1] = offsets[len] + c.counts[len];
        const symbols = try arena.alloc(u16, used);
        for (lengths, 0..) |len, s| {
            if (len == 0) continue;
            symbols[offsets[len]] = @intCast(s);
            offsets[len] += 1;
        }
        c.symbols = symbols;

        // Fill the table with the codes of up to `root_bits` bits, bit-reversed since
        // codes are packed most significant bit first.
        var code: u32 = 0;
        var k: usize = 0;
        for (1..root_bits + 1) |len| {
            for (0..c.counts[len]) |_| {
                const rev = @bitReverse(@as(u16, @intCast(code))) >> @intCast(16 - len);
                var at: usize = rev;
                while (at < c.table.len) : (at += @as(usize, 1) << @intCast(len)) {
                    c.table[at] = @intCast(@as(u32, symbols[k]) << 4 | len);
                }
                code += 1;
                k += 1;
            }
            code <<= 1;
        }
        return c;
    }
};

/// Reads a prefix code over an alphabet of `size` symbols (sections 3.4 and 3.5).
fn readCode(arena: std.mem.Allocator, br: *Bits, size: u32) Error!Code {
    var lengths: [704]u8 = @splat(0);
    if (size > lengths.len) return error.InvalidData;
    const hskip = try br.read(2);
    if (hskip == 1) {
        // A simple code: up to four symbols.
        var bits: u5 = 0;
        while ((@as(u32, 1) << bits) < size) bits += 1;
        const nsym = try br.read(2) + 1;
        var syms: [4]u16 = undefined;
        for (0..nsym) |k| {
            const s = try br.read(bits);
            if (s >= size) return error.InvalidData;
            for (syms[0..k]) |p| if (p == s) return error.InvalidData;
            syms[k] = @intCast(s);
        }
        switch (nsym) {
            1 => return .{
                .single = syms[0],
            },
            2 => {
                lengths[syms[0]] = 1;
                lengths[syms[1]] = 1;
            },
            3 => {
                lengths[syms[0]] = 1;
                lengths[syms[1]] = 2;
                lengths[syms[2]] = 2;
            },
            else => {
                const tree = [2][4]u8{ .{ 2, 2, 2, 2 }, .{ 1, 2, 3, 3 } };
                const t = tree[try br.read(1)];
                for (0..4) |k| lengths[syms[k]] = t[k];
            },
        }
        return Code.build(arena, lengths[0..size]);
    }

    // A complex code: first the code over code lengths.
    const order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var cl_lengths: [18]u8 = @splat(0);
    var space: i32 = 32;
    var nonzero: u32 = 0;
    var i: usize = hskip;
    while (i < 18) : (i += 1) {
        const v = br.peek(4);
        var len: u8 = undefined;
        var nbits: u5 = 2;
        switch (v & 3) {
            0 => len = 0,
            1 => len = 4,
            2 => len = 3,
            else => if (v & 4 == 0) {
                len = 2;
                nbits = 3;
            } else if (v & 8 == 0) {
                len = 1;
                nbits = 4;
            } else {
                len = 5;
                nbits = 4;
            },
        }
        try br.skip(nbits);
        cl_lengths[order[i]] = len;
        if (len != 0) {
            space -= @as(i32, 32) >> @intCast(len);
            nonzero += 1;
            if (space <= 0) break;
        }
    }
    if (nonzero != 1 and space != 0) return error.InvalidData;
    var scratch: [32]u16 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(std.mem.sliceAsBytes(&scratch));
    const cl_code = try Code.build(fba.allocator(), &cl_lengths);

    // Then the code lengths themselves.
    var sym: usize = 0;
    var prev_len: u8 = 8;
    var repeat: usize = 0;
    var repeat_len: u8 = 0;
    var left: i64 = 32768;
    while (sym < size and left > 0) {
        const s = try cl_code.decode(br);
        if (s < 16) {
            repeat = 0;
            lengths[sym] = @intCast(s);
            sym += 1;
            if (s != 0) {
                prev_len = @intCast(s);
                left -= @as(i64, 32768) >> @intCast(s);
            }
            continue;
        }
        const extra: u5 = if (s == 16) 2 else 3;
        const new_len: u8 = if (s == 16) prev_len else 0;
        if (new_len != repeat_len) {
            repeat = 0;
            repeat_len = new_len;
        }
        const old = repeat;
        if (repeat > 0) repeat = (repeat - 2) << extra;
        repeat += @as(usize, try br.read(extra)) + 3;
        const delta = repeat - old;
        if (delta > size - sym) return error.InvalidData;
        @memset(lengths[sym..][0..delta], repeat_len);
        sym += delta;
        if (repeat_len != 0) left -= @as(i64, @intCast(delta)) * (@as(i64, 32768) >> @intCast(repeat_len));
    }
    if (left != 0) return error.InvalidData;
    return Code.build(arena, lengths[0..size]);
}

// Context ID lookup tables for literals (section 7.1).
const lut0 = [256]u8{
    0,  0,  0,  0,  0,  0,  0,  0,  0,  4,  4,  0,  0,  4,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    8,  12, 16, 12, 12, 20, 12, 16, 24, 28, 12, 12, 32, 12, 36, 12,
    44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 32, 32, 24, 40, 28, 12,
    12, 48, 52, 52, 52, 48, 52, 52, 52, 48, 52, 52, 52, 52, 52, 48,
    52, 52, 52, 52, 52, 48, 52, 52, 52, 52, 52, 24, 12, 28, 12, 12,
    12, 56, 60, 60, 60, 56, 60, 60, 60, 56, 60, 60, 60, 60, 60, 56,
    60, 60, 60, 60, 60, 56, 60, 60, 60, 60, 60, 24, 12, 28, 12, 0,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
};
const lut1 = [256]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1,
    1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1,
    1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 1, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
};
const lut2 = [256]u8{
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7,
};

// Word transforms (Appendix B): prefix, elementary transform and suffix. Transform kinds:
// 0 Identity, 1 FermentFirst, 2 FermentAll, 3..11 OmitFirst1..9, 12..20 OmitLast1..9.
const prefixes = [121][]const u8{
    "",
    "",
    " ",
    "",
    "",
    "",
    " ",
    "s ",
    "",
    "",
    "",
    "",
    "",
    ", ",
    "",
    " ",
    "",
    "",
    "e ",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    " ",
    "",
    ".",
    " ",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    " the ",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    " ",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    " the ",
    "",
    "",
    " ",
    "",
    ".",
    "",
    "",
    "",
    " ",
    ".com/",
    " the ",
    "",
    "",
    "",
    ".",
    "",
    "",
    "",
    " ",
    "",
    " ",
    "",
    " ",
    "",
    "",
    "",
    " ",
    "",
    " ",
    "",
    "",
    "",
    "",
    " ",
    "",
    " ",
    "",
    "",
    "",
    "\xc2\xa0",
    " ",
    "",
    "",
    "",
    "",
    "",
    " ",
    " ",
    " ",
    "",
    "",
    "",
    " ",
    "",
    " ",
    " ",
    " ",
    " ",
};
const kinds = [121]u8{
    0,
    0,
    0,
    3,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    4,
    12,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    14,
    0,
    0,
    5,
    13,
    0,
    0,
    1,
    0,
    0,
    0,
    6,
    0,
    0,
    0,
    0,
    7,
    8,
    0,
    15,
    0,
    2,
    0,
    0,
    0,
    18,
    12,
    0,
    0,
    0,
    0,
    11,
    9,
    17,
    0,
    1,
    19,
    0,
    0,
    0,
    16,
    20,
    1,
    1,
    0,
    2,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
    1,
    0,
    0,
    0,
    2,
    0,
    2,
    0,
    2,
    1,
    0,
    0,
    1,
    0,
    0,
    2,
    0,
    1,
    2,
    0,
    1,
    0,
    2,
    0,
    0,
    1,
    2,
    0,
    2,
    1,
    1,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    1,
    2,
    1,
};
const suffixes = [121][]const u8{
    "",
    " ",
    " ",
    "",
    " ",
    " the ",
    "",
    " ",
    " of ",
    "",
    " and ",
    "",
    "",
    " ",
    ", ",
    " ",
    " in ",
    " to ",
    " ",
    "\"",
    ".",
    "\">",
    "\n",
    "",
    "]",
    " for ",
    "",
    "",
    " a ",
    " that ",
    "",
    ". ",
    "",
    ", ",
    "",
    " with ",
    "'",
    " from ",
    " by ",
    "",
    "",
    "",
    "",
    ". The ",
    "",
    " on ",
    " as ",
    " is ",
    "",
    "ing ",
    "\n\t",
    ":",
    ". ",
    "ed ",
    "",
    "",
    "",
    "(",
    ", ",
    "",
    " at ",
    "ly ",
    " of ",
    "",
    "",
    ", ",
    "\"",
    "(",
    " ",
    "\">",
    "=\"",
    ".",
    "",
    " of the ",
    "'",
    ". This ",
    ",",
    " ",
    "(",
    ".",
    " not ",
    "=\"",
    "er ",
    " ",
    "al ",
    "",
    "='",
    "\"",
    ". ",
    "(",
    "ful ",
    ". ",
    "ive ",
    "less ",
    "'",
    "est ",
    ".",
    "\">",
    "='",
    ",",
    "ize ",
    ".",
    "",
    ",",
    "=\"",
    "=\"",
    "ous ",
    ", ",
    "='",
    ",",
    "=\"",
    ", ",
    ",",
    "(",
    ". ",
    ".",
    "='",
    ". ",
    "=\"",
    "='",
    "='",
};

const testing = std.testing;

test "the static dictionary matches its RFC checksum" {
    try testing.expectEqual(@as(u32, 0x5136cb04), std.hash.Crc32.hash(dictionary));
}

test "the transforms and context tables match their RFC checksums" {
    var buf: [700]u8 = undefined;
    var n: usize = 0;
    for (0..121) |k| {
        @memcpy(buf[n..][0..prefixes[k].len], prefixes[k]);
        n += prefixes[k].len;
        buf[n] = 0;
        buf[n + 1] = kinds[k];
        n += 2;
        @memcpy(buf[n..][0..suffixes[k].len], suffixes[k]);
        n += suffixes[k].len;
        buf[n] = 0;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 648), n);
    try testing.expectEqual(@as(u32, 0x3d965f81), std.hash.Crc32.hash(buf[0..n]));
    try testing.expectEqual(@as(u32, 0x8e91efb7), std.hash.Crc32.hash(&lut0));
    try testing.expectEqual(@as(u32, 0xd01a32f4), std.hash.Crc32.hash(&lut1));
    try testing.expectEqual(@as(u32, 0x0dd7a0d6), std.hash.Crc32.hash(&lut2));
}

/// Streams made with the `brotli` command line tool (quality and window in the name).
const vectors = struct {
    const hello_q0 =
        \\AxGAaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gd29ybGQD
    ;
    const text_q11 =
        \\oQAMAGCkXG1HqyQqkLl1Svq6IxRbY6IGBkE3haodsDa3/8Fr0+RFcpkFnm7zeYRQmeGe1Orcjk5o0Z718WMdtPSBVb8ZtRSJ
        \\ZNpXbXBJKE2y0rhHKZkk/CistGh4nlunKjtVY6Z5FVVBZKHsUPa+eusCjwSBatE8hRRF33WPfzEhYWXMKD9oJl5XUt/Nw3iV
        \\yMymGxuOeI2sXSTgdFot82pbuiNUAA==
    ;
    const text_q5w10 =
        \\oQAMACD+65Yeo148IX4Tan7C9Do/7Q3/dxPYb2wabeyFa9PPLrEwDDwAyc61Hn/LcCc/lfJvFWz+C15pZWja8CPdDTRVnYHx
        \\M7L3gSRz4ZeF2HydXTaoaNQ/fQqQ93OsSl0hKw1wvKINj8RhceOJ0x1pP5biX9zK/poUyx2TLNIqCmc4vGnWeipDKtm7ekkH
        \\PWgNF9WgJMBjhnJXAQA7b/CvsQgKBa4CQMPab5z87MKtQXPWYapaoVZEscmYT4UkUUlwOp++6DrMxEk+IE6fOiEGVzyQBovx
        \\OgA=
    ;
    const mixed_q11 =
        \\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
        \\qWjp2xu7jp44Q0hpEYVuXo6hAg==
    ;
    const mixed_q5 =
        \\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
    ;
};

fn unbase64(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const clean = try gpa.alloc(u8, text.len);
    defer gpa.free(clean);
    var n: usize = 0;
    for (text) |c| {
        if (c == '\n' or c == ' ') continue;
        clean[n] = c;
        n += 1;
    }
    const dec = std.base64.standard.Decoder;
    const out = try gpa.alloc(u8, try dec.calcSizeForSlice(clean[0..n]));
    try dec.decode(out, clean[0..n]);
    return out;
}

/// The input of the `mixed` vectors: words from a short list picked by a fixed LCG,
/// with runs of little-endian u16 values.
fn mixedInput(gpa: std.mem.Allocator) ![]u8 {
    const words = [_][]const u8{ "the", "of", "and", "to", "in", "is", "was", "for", "on", "that", "with", "as", "by", "at", "from", "this", "which", "be", "are", "or", "an", "it", "not", "have", "one", "all", "new", "more", "page", "time", "web", "font", "glyph", "table" };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var x: u32 = 12345;
    while (out.items.len < 16000) {
        x = (x *% 1103515245 +% 12345) & 0x7fffffff;
        const r = x >> 16;
        if (r % 40 == 0) {
            for (0..24) |i| {
                const v: u16 = @truncate(i * 300 + (r & 3));
                try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
            }
        } else {
            try out.appendSlice(gpa, words[r % words.len]);
            try out.appendSlice(gpa, if (r % 13 == 0) ". " else " ");
        }
    }
    out.shrinkRetainingCapacity(16000);
    return out.toOwnedSlice(gpa);
}

const text_input =
    \\The quick brown fox jumps over the lazy dog. In the beginning of the project, the team wrote a small engine that would render pages for the web; it was meant to be simple and fast, and the people who used it said that it worked well for their sites. This is the time when everything changed: the format grew, the tools grew, and the documentation, which nobody read, grew most of all.
    \\
;

test "decodes streams from the reference tool" {
    const gpa = testing.allocator;
    const mixed = try mixedInput(gpa);
    defer gpa.free(mixed);
    const cases = [_]struct {
        stream: []const u8,
        expect: []const u8,
    }{
        .{
            .stream = vectors.hello_q0,
            .expect = "hello hello hello hello hello world",
        },
        .{
            .stream = vectors.text_q11,
            .expect = text_input,
        },
        .{
            .stream = vectors.text_q5w10,
            .expect = text_input,
        },
        .{
            .stream = vectors.mixed_q11,
            .expect = mixed,
        },
        .{
            .stream = vectors.mixed_q5,
            .expect = mixed,
        },
    };
    for (cases) |c| {
        const stream = try unbase64(gpa, c.stream);
        defer gpa.free(stream);
        const out = try decompress(gpa, stream, 1 << 20);
        defer gpa.free(out);
        try testing.expectEqualSlices(u8, c.expect, out);

        // Every truncation fails cleanly.
        for (0..stream.len) |n| {
            if (decompress(gpa, stream[0..n], 1 << 20)) |o| {
                gpa.free(o);
                return error.TestUnexpectedResult;
            } else |_| {}
        }
        // A limit below the output size is refused.
        try testing.expectError(error.OutputTooLarge, decompress(gpa, stream, c.expect.len - 1));
    }
}

test "corrupt streams never crash" {
    const gpa = testing.allocator;
    const stream = try unbase64(gpa, vectors.mixed_q11);
    defer gpa.free(stream);
    var prng: std.Random.DefaultPrng = .init(7);
    const rand = prng.random();
    const copy = try gpa.dupe(u8, stream);
    defer gpa.free(copy);
    for (0..300) |_| {
        @memcpy(copy, stream);
        for (0..1 + rand.uintLessThan(usize, 4)) |_| {
            copy[rand.uintLessThan(usize, copy.len)] ^= @as(u8, 1) << rand.int(u3);
        }
        if (decompress(gpa, copy, 1 << 20)) |o| gpa.free(o) else |_| {}
    }
}

test "hand-built streams: empty, uncompressed and simple codes" {
    const gpa = testing.allocator;
    // WBITS 16, ISLAST, ISLASTEMPTY.
    const empty = try decompress(gpa, &.{0b0000_0110}, 16);
    defer gpa.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    // WBITS 16; ISLAST=0, MNIBBLES=4, MLEN-1=2, ISUNCOMPRESSED; "abc"; ISLAST, ISLASTEMPTY.
    // Bits: 0 | 0 | 00 | 0100000000000000 | 1 -> then byte-aligned data.
    const stored = [_]u8{ 0b0010_0000, 0b0000_0000, 0b0001_0000, 'a', 'b', 'c', 0b0000_0011 };
    const out = try decompress(gpa, &stored, 16);
    defer gpa.free(out);
    try testing.expectEqualStrings("abc", out);
    // Nonzero fill bits before stored data are invalid.
    var bad = stored;
    bad[2] |= 0x80;
    try testing.expectError(error.InvalidData, decompress(gpa, &bad, 16));
}
