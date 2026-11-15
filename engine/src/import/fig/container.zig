//! The `.fig` container: a zip holding `canvas.fig` (the document), `meta.json`,
//! `thumbnail.png` and `images/<sha1>` (image bytes). `canvas.fig` is an 8-byte magic
//! (`fig-kiwi`), a u32 LE version, then chunks of (u32 LE length, bytes): chunk 0 the Kiwi
//! schema, chunk 1 the document message, each compressed (zstd or raw deflate, told
//! apart by the zstd magic).

const std = @import("std");
const flate = std.compress.flate;
const zstd = std.compress.zstd;

pub const Error = error{
    /// Not a zip, or a zip whose records point outside it.
    BadZip,
    /// A zip entry stored with a method other than stored or deflate.
    UnsupportedZip,
    /// Not a `fig-kiwi` canvas, or its chunks run past the end.
    BadCanvas,
    /// A compressed chunk or entry is corrupt.
    BadCompression,
    /// Something inflates past the size limit.
    TooLarge,
    OutOfMemory,
};

/// The largest thing inflated (a chunk or a zip entry).
pub const max_inflated = 1 << 30;

pub const Entry = struct {
    name: []const u8,
    method: u16,
    /// The entry's bytes as stored (compressed when `method` is 8).
    data: []const u8,
    size: u32,
};

/// Where a zip's central directory sits and how many entries it lists.
pub const Directory = struct {
    offset: u64,
    size: u64,
    count: u64,
};

/// The most of a zip's end a `findDirectory` needs: the end record with the longest
/// comment, and the zip64 end record and locator before it.
pub const max_tail = 22 + 65535 + 20 + 56;

/// Finds the central directory from the file's last bytes: `tail` ends where the file
/// of `file_size` bytes ends (`max_tail` bytes, or the whole file when shorter). Reads
/// zip64 end records, so files past 4 GB work; only the directory and the entries
/// asked for are ever read.
pub fn findDirectory(tail: []const u8, file_size: u64) Error!Directory {
    if (tail.len < 22 or tail.len > file_size) return error.BadZip;
    const base = file_size - tail.len;
    var i: usize = tail.len - 22;
    const e = while (true) : (i -= 1) {
        if (std.mem.eql(u8, tail[i..][0..4], "PK\x05\x06")) break i;
        if (i == 0) return error.BadZip;
    };
    var d: Directory = .{
        .offset = rd32(tail, e + 16),
        .size = rd32(tail, e + 12),
        .count = rd16(tail, e + 10),
    };
    if (d.count == 0xffff or d.offset == 0xffffffff or d.size == 0xffffffff) {
        // Zip64: a locator right before the end record points at the zip64 end record.
        if (e < 20 or !std.mem.eql(u8, tail[e - 20 ..][0..4], "PK\x06\x07")) return error.BadZip;
        const at = std.mem.readInt(u64, tail[e - 12 ..][0..8], .little);
        if (at < base or at - base + 56 > tail.len) return error.BadZip;
        const r: usize = @intCast(at - base);
        if (!std.mem.eql(u8, tail[r..][0..4], "PK\x06\x06")) return error.BadZip;
        d = .{
            .count = std.mem.readInt(u64, tail[r + 32 ..][0..8], .little),
            .size = std.mem.readInt(u64, tail[r + 40 ..][0..8], .little),
            .offset = std.mem.readInt(u64, tail[r + 48 ..][0..8], .little),
        };
    }
    if (d.offset > file_size or d.size > file_size - d.offset) return error.BadZip;
    return d;
}

/// A zip entry as its central directory record describes it.
pub const Item = struct {
    name: []const u8,
    method: u16,
    /// Bytes as stored, and inflated.
    csize: u64,
    size: u64,
    /// Where its local header starts in the file (`dataStart` finds the bytes).
    local: u64,
};

/// The entries the central directory `cd` lists (names point into `cd`).
pub fn listDirectory(a: std.mem.Allocator, cd: []const u8, count: u64) Error![]Item {
    if (count > cd.len / 46) return error.BadZip;
    const out = try a.alloc(Item, @intCast(count));
    var p: usize = 0;
    for (out) |*it| {
        if (p + 46 > cd.len or !std.mem.eql(u8, cd[p..][0..4], "PK\x01\x02")) return error.BadZip;
        const nlen = rd16(cd, p + 28);
        const xlen = rd16(cd, p + 30);
        const clen = rd16(cd, p + 32);
        if (p + 46 + @as(usize, nlen) + xlen + clen > cd.len) return error.BadZip;
        it.* = .{
            .name = cd[p + 46 ..][0..nlen],
            .method = rd16(cd, p + 10),
            .csize = rd32(cd, p + 20),
            .size = rd32(cd, p + 24),
            .local = rd32(cd, p + 42),
        };
        // Zip64 sizes and offset, in that order, for the fields that say 0xffffffff.
        var x = cd[p + 46 + nlen ..][0..xlen];
        while (x.len >= 4) {
            const id = rd16(x, 0);
            const len = rd16(x, 2);
            if (4 + @as(usize, len) > x.len) return error.BadZip;
            if (id == 1) {
                var f = x[4..][0..len];
                inline for (.{ "size", "csize", "local" }) |name| {
                    if (@field(it, name) == 0xffffffff) {
                        if (f.len < 8) return error.BadZip;
                        @field(it, name) = std.mem.readInt(u64, f[0..8], .little);
                        f = f[8..];
                    }
                }
            }
            x = x[4 + len ..];
        }
        p += 46 + @as(usize, nlen) + xlen + clen;
    }
    return out;
}

/// The offset from an entry's local header to its bytes, from the header's first 30
/// bytes.
pub fn dataStart(local_header: []const u8) Error!u64 {
    if (local_header.len < 30 or !std.mem.eql(u8, local_header[0..4], "PK\x03\x04")) return error.BadZip;
    return 30 + @as(u64, rd16(local_header, 26)) + rd16(local_header, 28);
}

/// The entries of a zip in `bytes`, from its central directory.
pub fn zipEntries(a: std.mem.Allocator, bytes: []const u8) Error![]Entry {
    const tail = bytes[bytes.len -| max_tail..];
    const d = try findDirectory(tail, bytes.len);
    const items = try listDirectory(a, bytes[@intCast(d.offset)..][0..@intCast(d.size)], d.count);
    const out = try a.alloc(Entry, items.len);
    for (out, items) |*en, it| {
        if (it.local > bytes.len) return error.BadZip;
        const start = it.local + try dataStart(bytes[@intCast(it.local)..]);
        if (start > bytes.len or it.csize > bytes.len - start or it.size > std.math.maxInt(u32)) return error.BadZip;
        en.* = .{
            .name = it.name,
            .method = it.method,
            .data = bytes[@intCast(start)..][0..@intCast(it.csize)],
            .size = @intCast(it.size),
        };
    }
    return out;
}

/// An entry's bytes, inflated when needed.
pub fn entryBytes(a: std.mem.Allocator, en: Entry) Error![]const u8 {
    return switch (en.method) {
        0 => en.data,
        8 => inflateRaw(a, en.data, @min(max_inflated, @as(usize, en.size))),
        else => error.UnsupportedZip,
    };
}

/// Raw deflate, at most `limit` bytes out.
pub fn inflateRaw(a: std.mem.Allocator, bytes: []const u8, limit: usize) Error![]u8 {
    var in: std.Io.Reader = .fixed(bytes);
    var d: flate.Decompress = .init(&in, .raw, &.{});
    return drain(a, &d.reader, limit);
}

/// A zstd frame, at most `limit` bytes out.
pub fn unzstd(a: std.mem.Allocator, bytes: []const u8, limit: usize) Error![]u8 {
    var in: std.Io.Reader = .fixed(bytes);
    var d: zstd.Decompress = .init(&in, &.{}, .{});
    return drain(a, &d.reader, limit);
}

fn drain(a: std.mem.Allocator, r: *std.Io.Reader, limit: usize) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    while (true) {
        const room = limit + 1 - out.written().len;
        _ = r.stream(&out.writer, .limited(room)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return error.BadCompression,
        };
        if (out.written().len > limit) return error.TooLarge;
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// A chunk's bytes, decompressed by its magic: zstd (`28 b5 2f fd`) or raw deflate.
pub fn unpackChunk(a: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x28\xb5\x2f\xfd")) return unzstd(a, bytes, max_inflated);
    return inflateRaw(a, bytes, max_inflated);
}

pub const Canvas = struct {
    version: u32,
    /// The chunks, still compressed.
    chunks: [][]const u8,
};

/// Splits `canvas.fig` into its chunks.
pub fn canvasChunks(a: std.mem.Allocator, bytes: []const u8) Error!Canvas {
    if (bytes.len < 12 or !std.mem.startsWith(u8, bytes, "fig-")) return error.BadCanvas;
    const version = rd32(bytes, 8);
    var list: std.ArrayList([]const u8) = .empty;
    var p: usize = 12;
    while (p < bytes.len) {
        if (bytes.len - p < 4) return error.BadCanvas;
        const n = rd32(bytes, p);
        p += 4;
        if (n > bytes.len - p) return error.BadCanvas;
        try list.append(a, bytes[p..][0..n]);
        p += n;
    }
    return .{
        .version = version,
        .chunks = list.items,
    };
}

fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

test "canvas chunks are bounded" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = "fig-kiwi\x6a\x00\x00\x00\x02\x00\x00\x00ab\x00\x00\x00\x00";
    const c = try canvasChunks(a, ok);
    try std.testing.expectEqual(@as(u32, 106), c.version);
    try std.testing.expectEqual(@as(usize, 2), c.chunks.len);
    try std.testing.expectEqualStrings("ab", c.chunks[0]);
    try std.testing.expectError(error.BadCanvas, canvasChunks(a, "fig-kiwi\x6a\x00\x00\x00\x09\x00\x00\x00ab"));
    try std.testing.expectError(error.BadCanvas, canvasChunks(a, "PK"));
}

test "a stored zip entry" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // One stored entry "a" holding "hi": local header, data, central record, end record.
    const zip = "PK\x03\x04" ++ "\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x00\x00\x00" ++
        "\x02\x00\x00\x00\x02\x00\x00\x00\x01\x00\x00\x00a" ++ "hi" ++
        "PK\x01\x02" ++ "\x14\x00\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x00\x00\x00" ++
        "\x02\x00\x00\x00\x02\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00a" ++
        "PK\x05\x06\x00\x00\x00\x00\x01\x00\x01\x00\x2f\x00\x00\x00\x21\x00\x00\x00\x00\x00";
    const es = try zipEntries(a, zip);
    try std.testing.expectEqual(@as(usize, 1), es.len);
    try std.testing.expectEqualStrings("a", es[0].name);
    try std.testing.expectEqualStrings("hi", try entryBytes(a, es[0]));
    // Every truncation fails cleanly.
    var n: usize = 0;
    while (n < zip.len) : (n += 1) try std.testing.expect(std.meta.isError(zipEntries(a, zip[0..n])));
}
