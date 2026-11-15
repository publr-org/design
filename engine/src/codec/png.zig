//! PNG: decode every PNG to RGBA8, encode RGBA8.
//!
//! Written from the PNG specification (W3C PNG Third Edition, RFC 2083).
//! The decoder accepts every colour type (0, 2, 3, 4, 6) at every allowed bit
//! depth, `tRNS` transparency, Adam7 interlacing, all five filter types and
//! image data split over any number of `IDAT` chunks. Colour management chunks
//! (`gAMA`, `cHRM`, `iCCP`, `sRGB`) are ignored; `hasColorProfile` reports
//! whether a file carries one.

const std = @import("std");
const flate = std.compress.flate;
const Image = @import("image.zig").Image;

/// The largest image `decode` accepts, in pixels.
pub const max_pixels: u64 = 1 << 28;

const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

/// Largest `IDAT` chunk `encode` writes; larger streams are split.
const max_idat_len = 1 << 20;

pub const DecodeError = error{
    /// The input does not start with the PNG signature.
    NotPng,
    /// The input ends before the `IEND` chunk, or inside a chunk.
    Truncated,
    /// A chunk's CRC does not match its contents.
    BadCrc,
    /// A chunk length is out of range.
    InvalidChunk,
    /// `IHDR` is missing, repeated or holds invalid values.
    InvalidHeader,
    /// The image is larger than `max_pixels`.
    ImageTooLarge,
    /// `PLTE` is missing for an indexed image, repeated or malformed.
    InvalidPalette,
    /// A critical chunk this decoder does not know.
    UnsupportedCriticalChunk,
    /// There is no `IDAT` chunk.
    MissingImageData,
    /// The zlib stream is malformed, too short or fails its checksum.
    CorruptImageData,
    /// A scanline uses a filter type other than 0-4.
    InvalidFilter,
    OutOfMemory,
};

pub const EncodeError = error{
    /// Width or height is zero or larger than PNG allows.
    InvalidDimensions,
    /// `rgba.len` is not `width * height * 4`.
    InvalidPixelBuffer,
    OutOfMemory,
};

const ColorType = enum(u8) {
    grey = 0,
    rgb = 2,
    indexed = 3,
    grey_alpha = 4,
    rgba = 6,

    fn channels(c: ColorType) u8 {
        return switch (c) {
            .grey, .indexed => 1,
            .grey_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }

    fn allowsDepth(c: ColorType, depth: u8) bool {
        return switch (c) {
            .grey => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
            .indexed => depth == 1 or depth == 2 or depth == 4 or depth == 8,
            .rgb, .grey_alpha, .rgba => depth == 8 or depth == 16,
        };
    }
};

const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: ColorType,
    interlaced: bool,

    fn bitsPerPixel(h: Header) usize {
        return @as(usize, h.color.channels()) * h.depth;
    }

    /// Bytes in one scanline of `w` pixels, without the filter byte.
    fn rowBytes(h: Header, w: u64) u64 {
        return (w * h.bitsPerPixel() + 7) / 8;
    }

    /// The byte distance filters use to find the corresponding byte of the previous pixel.
    fn filterStride(h: Header) usize {
        return @max(1, h.bitsPerPixel() / 8);
    }
};

const Pass = struct {
    x0: u8,
    y0: u8,
    dx: u8,
    dy: u8,

    fn init(x0: u8, y0: u8, dx: u8, dy: u8) Pass {
        return .{
            .x0 = x0,
            .y0 = y0,
            .dx = dx,
            .dy = dy,
        };
    }

    /// Samples taken from `extent` pixels starting at `start`, every `step`.
    fn count(extent: u32, start: u8, step: u8) u32 {
        if (extent <= start) return 0;
        return (extent - start + step - 1) / step;
    }

    fn width(p: Pass, w: u32) u32 {
        return count(w, p.x0, p.dx);
    }

    fn height(p: Pass, h: u32) u32 {
        return count(h, p.y0, p.dy);
    }
};

const adam7 = [7]Pass{
    .init(0, 0, 8, 8),
    .init(4, 0, 8, 8),
    .init(0, 4, 4, 8),
    .init(2, 0, 4, 4),
    .init(0, 2, 2, 4),
    .init(1, 0, 2, 2),
    .init(0, 1, 1, 2),
};

const whole_image = [1]Pass{.init(0, 0, 1, 1)};

const Chunk = struct {
    kind: [4]u8,
    data: []const u8,

    fn is(c: Chunk, kind: *const [4]u8) bool {
        return std.mem.eql(u8, &c.kind, kind);
    }
};

/// Walks the chunks after the signature. Never reads outside `bytes`.
const ChunkIterator = struct {
    bytes: []const u8,
    pos: usize,

    /// Returns the next chunk, or null when the input ends exactly at a chunk boundary.
    fn next(it: *ChunkIterator, check_crc: bool) DecodeError!?Chunk {
        const rest = it.bytes[it.pos..];
        if (rest.len == 0) return null;
        if (rest.len < 12) return error.Truncated;
        const len = std.mem.readInt(u32, rest[0..4], .big);
        if (len > 0x7fff_ffff) return error.InvalidChunk;
        if (rest.len - 12 < len) return error.Truncated;
        const crc = std.mem.readInt(u32, rest[8 + len ..][0..4], .big);
        if (check_crc and std.hash.Crc32.hash(rest[4 .. 8 + len]) != crc) return error.BadCrc;
        it.pos += 12 + len;
        return .{
            .kind = rest[4..8].*,
            .data = rest[8..][0..len],
        };
    }
};

/// Reports whether the PNG carries colour space information this decoder ignores:
/// an embedded ICC profile (`iCCP`), a gamma (`gAMA`) or chromaticities (`cHRM`).
/// Returns false for input that is not a well-formed chunk sequence.
pub fn hasColorProfile(bytes: []const u8) bool {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return false;
    var it: ChunkIterator = .{
        .bytes = bytes,
        .pos = 8,
    };
    while (it.next(false) catch return false) |c| {
        if (c.is("iCCP") or c.is("gAMA") or c.is("cHRM")) return true;
        if (c.is("IDAT") or c.is("IEND")) return false;
    }
    return false;
}

fn parseHeader(data: []const u8) DecodeError!Header {
    if (data.len != 13) return error.InvalidHeader;
    const w = std.mem.readInt(u32, data[0..4], .big);
    const h = std.mem.readInt(u32, data[4..8], .big);
    if (w == 0 or h == 0 or w > 0x7fff_ffff or h > 0x7fff_ffff) return error.InvalidHeader;
    const color = std.enums.fromInt(ColorType, data[9]) orelse return error.InvalidHeader;
    const depth = data[8];
    if (!color.allowsDepth(depth)) return error.InvalidHeader;
    if (data[10] != 0 or data[11] != 0 or data[12] > 1) return error.InvalidHeader;
    if (@as(u64, w) * h > max_pixels) return error.ImageTooLarge;
    return .{
        .width = w,
        .height = h,
        .depth = depth,
        .color = color,
        .interlaced = data[12] == 1,
    };
}

/// How samples become RGBA8: a lookup table for indexed and low-depth grey
/// images, colour keys for the rest.
const Expander = struct {
    header: Header,
    /// Indexed colours, or grey levels for grey images of depth 8 or less.
    lut: [256][4]u8,
    /// `tRNS` colour key as raw samples (grey uses the first entry).
    key: ?[3]u16,

    fn init(header: Header, palette: ?[]const u8, trns: ?[]const u8) Expander {
        var e: Expander = .{
            .header = header,
            .lut = @splat(.{ 0, 0, 0, 255 }),
            .key = null,
        };
        switch (header.color) {
            .indexed => {
                // Indices past the palette's end decode as opaque black.
                const plte = palette.?;
                const alphas = trns orelse &.{};
                for (0..plte.len / 3) |i| {
                    e.lut[i] = .{
                        plte[i * 3],
                        plte[i * 3 + 1],
                        plte[i * 3 + 2],
                        if (i < alphas.len) alphas[i] else 255,
                    };
                }
            },
            .grey => {
                if (trns) |t| if (t.len == 2) {
                    e.key = .{ std.mem.readInt(u16, t[0..2], .big), 0, 0 };
                };
                if (header.depth <= 8) {
                    const levels: u16 = @as(u16, 1) << @intCast(header.depth);
                    const scale: u16 = 255 / (levels - 1);
                    for (0..levels) |s| {
                        const g: u8 = @intCast(s * scale);
                        const transparent = if (e.key) |k| k[0] == s else false;
                        e.lut[s] = .{ g, g, g, if (transparent) 0 else 255 };
                    }
                }
            },
            .rgb => if (trns) |t| if (t.len == 6) {
                e.key = .{
                    std.mem.readInt(u16, t[0..2], .big),
                    std.mem.readInt(u16, t[2..4], .big),
                    std.mem.readInt(u16, t[4..6], .big),
                };
            },
            .grey_alpha, .rgba => {},
        }
        return e;
    }

    /// Writes `n` pixels of the unfiltered scanline `src` to `dst` (one output
    /// row), starting at column `x0` and stepping by `dx`.
    fn row(e: *const Expander, src: []const u8, dst: []u8, x0: usize, dx: usize, n: usize) void {
        const h = e.header;
        switch (h.color) {
            .indexed => switch (h.depth) {
                inline 1, 2, 4, 8 => |d| e.lookupRow(d, src, dst, x0, dx, n),
                else => unreachable,
            },
            .grey => switch (h.depth) {
                inline 1, 2, 4, 8 => |d| e.lookupRow(d, src, dst, x0, dx, n),
                16 => for (0..n) |i| {
                    const v = sample16(src, i);
                    const g = to8(v);
                    const a: u8 = if (e.key) |k| (if (k[0] == v) 0 else 255) else 255;
                    put(dst, x0 + i * dx, .{ g, g, g, a });
                },
                else => unreachable,
            },
            .rgb => if (h.depth == 8) {
                for (0..n) |i| {
                    const p = src[i * 3 ..][0..3];
                    const a: u8 = if (e.key) |k| (if (k[0] == p[0] and k[1] == p[1] and k[2] == p[2]) 0 else 255) else 255;
                    put(dst, x0 + i * dx, .{ p[0], p[1], p[2], a });
                }
            } else {
                for (0..n) |i| {
                    const r = sample16(src, i * 3);
                    const g = sample16(src, i * 3 + 1);
                    const b = sample16(src, i * 3 + 2);
                    const a: u8 = if (e.key) |k| (if (k[0] == r and k[1] == g and k[2] == b) 0 else 255) else 255;
                    put(dst, x0 + i * dx, .{ to8(r), to8(g), to8(b), a });
                }
            },
            .grey_alpha => if (h.depth == 8) {
                for (0..n) |i| {
                    const g = src[i * 2];
                    put(dst, x0 + i * dx, .{ g, g, g, src[i * 2 + 1] });
                }
            } else {
                for (0..n) |i| {
                    const g = to8(sample16(src, i * 2));
                    put(dst, x0 + i * dx, .{ g, g, g, to8(sample16(src, i * 2 + 1)) });
                }
            },
            .rgba => if (h.depth == 8) {
                if (dx == 1) {
                    @memcpy(dst[x0 * 4 ..][0 .. n * 4], src[0 .. n * 4]);
                } else for (0..n) |i| {
                    put(dst, x0 + i * dx, src[i * 4 ..][0..4].*);
                }
            } else {
                for (0..n) |i| {
                    put(dst, x0 + i * dx, .{
                        to8(sample16(src, i * 4)),
                        to8(sample16(src, i * 4 + 1)),
                        to8(sample16(src, i * 4 + 2)),
                        to8(sample16(src, i * 4 + 3)),
                    });
                }
            },
        }
    }

    fn lookupRow(e: *const Expander, comptime depth: u8, src: []const u8, dst: []u8, x0: usize, dx: usize, n: usize) void {
        const per_byte = 8 / depth;
        const mask: u8 = (1 << depth) - 1;
        for (0..n) |i| {
            const index = if (depth == 8) src[i] else blk: {
                const shift: u3 = @intCast(8 - depth - (i % per_byte) * depth);
                break :blk (src[i / per_byte] >> shift) & mask;
            };
            put(dst, x0 + i * dx, e.lut[index]);
        }
    }

    fn put(dst: []u8, x: usize, px: [4]u8) void {
        dst[x * 4 ..][0..4].* = px;
    }

    fn sample16(src: []const u8, i: usize) u16 {
        return std.mem.readInt(u16, src[i * 2 ..][0..2], .big);
    }

    fn to8(v: u16) u8 {
        return @intCast((@as(u32, v) * 255 + 32767) / 65535);
    }
};

/// Decodes a PNG file to straight-alpha RGBA8. Caller owns the returned image
/// and frees it with `Image.deinit`. Returns an error for anything that is not a
/// complete, valid PNG; never reads outside `bytes`. Colour management chunks
/// are ignored (see `hasColorProfile`).
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Image {
    if (bytes.len < signature.len) {
        return if (std.mem.eql(u8, bytes, signature[0..bytes.len])) error.Truncated else error.NotPng;
    }
    if (!std.mem.eql(u8, bytes[0..8], &signature)) return error.NotPng;

    var it: ChunkIterator = .{
        .bytes = bytes,
        .pos = 8,
    };
    const first = (try it.next(true)) orelse return error.Truncated;
    if (!first.is("IHDR")) return error.InvalidHeader;
    const header = try parseHeader(first.data);

    var palette: ?[]const u8 = null;
    var trns: ?[]const u8 = null;
    // A single IDAT is used in place; more are joined into `joined`.
    var idat: ?[]const u8 = null;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    var ended = false;

    while (try it.next(true)) |c| {
        if (c.is("IDAT")) {
            if (idat) |prev| {
                if (joined.items.len == 0) try joined.appendSlice(gpa, prev);
                try joined.appendSlice(gpa, c.data);
                idat = joined.items;
            } else {
                idat = c.data;
            }
        } else if (c.is("IEND")) {
            ended = true;
            break;
        } else if (c.is("PLTE")) {
            if (palette != null or idat != null) return error.InvalidPalette;
            if (c.data.len == 0 or c.data.len % 3 != 0 or c.data.len > 256 * 3) return error.InvalidPalette;
            palette = c.data;
        } else if (c.is("tRNS")) {
            trns = c.data;
        } else if (c.is("IHDR")) {
            return error.InvalidHeader;
        } else if (c.kind[0] & 0x20 == 0) {
            return error.UnsupportedCriticalChunk;
        }
    }
    if (!ended) return error.Truncated;
    const compressed = idat orelse return error.MissingImageData;
    if (header.color == .indexed and palette == null) return error.InvalidPalette;

    const passes: []const Pass = if (header.interlaced) &adam7 else &whole_image;
    var raw_len: u64 = 0;
    for (passes) |p| {
        const pw = p.width(header.width);
        const ph = p.height(header.height);
        if (pw == 0 or ph == 0) continue;
        raw_len += @as(u64, ph) * (1 + header.rowBytes(pw));
    }
    const raw_size = std.math.cast(usize, raw_len) orelse return error.ImageTooLarge;
    const out_size = std.math.cast(usize, @as(u64, header.width) * header.height * 4) orelse return error.ImageTooLarge;

    const raw = try gpa.alloc(u8, raw_size);
    defer gpa.free(raw);
    try inflate(compressed, raw);

    const zero_row = try gpa.alloc(u8, @intCast(header.rowBytes(header.width)));
    defer gpa.free(zero_row);
    @memset(zero_row, 0);

    const pixels = try gpa.alloc(u8, out_size);
    errdefer gpa.free(pixels);

    const expander: Expander = .init(header, palette, trns);
    const stride = @as(usize, header.width) * 4;
    const filter_stride = header.filterStride();
    var off: usize = 0;
    for (passes) |p| {
        const pw = p.width(header.width);
        const ph = p.height(header.height);
        if (pw == 0 or ph == 0) continue;
        const rb: usize = @intCast(header.rowBytes(pw));
        var prev: []const u8 = zero_row[0..rb];
        for (0..ph) |r| {
            const cur = raw[off + 1 ..][0..rb];
            try unfilter(raw[off], cur, prev, filter_stride);
            const y = p.y0 + r * p.dy;
            expander.row(cur, pixels[y * stride ..][0..stride], p.x0, p.dx, pw);
            prev = cur;
            off += 1 + rb;
        }
    }

    return .{
        .width = header.width,
        .height = header.height,
        .pixels = pixels,
    };
}

/// Inflates the zlib stream into exactly `out.len` bytes and checks its Adler-32.
fn inflate(compressed: []const u8, out: []u8) DecodeError!void {
    var in: std.Io.Reader = .fixed(compressed);
    var zlib: flate.Decompress = .init(&in, .zlib, &.{});
    var w: std.Io.Writer = .fixed(out);
    var stalls: u8 = 0;
    while (w.end < out.len) {
        const n = zlib.reader.stream(&w, .limited(out.len - w.end)) catch return error.CorruptImageData;
        // The decompressor returns 0 while crossing block boundaries, and keeps
        // returning 0 when a match runs past the expected size: too much data.
        stalls = if (n == 0) stalls + 1 else 0;
        if (stalls > 2) return error.CorruptImageData;
    }
    // Run the stream to its end to reach the checksum. A stream that carries
    // extra data, or stops right after the image data, is accepted unchecked,
    // as other decoders do.
    for (0..16) |_| {
        switch (zlib.state) {
            // Calling with a zero limit is only safe where no output is pending.
            .block_header, .protocol_footer, .fixed_block, .dynamic_block => {},
            .end => break,
            else => return,
        }
        _ = zlib.reader.stream(&w, .limited(0)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => {
                const e = zlib.err orelse return error.CorruptImageData;
                if (e == error.EndOfStream) return;
                return error.CorruptImageData;
            },
            error.WriteFailed => return,
        };
    }
    if (zlib.state != .end) return;
    if (std.hash.Adler32.hash(out) != zlib.container_metadata.zlib.adler) return error.CorruptImageData;
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const pa = @abs(@as(i16, b) - c);
    const pb = @abs(@as(i16, a) - c);
    const pc = @abs(@as(i16, a) + b - 2 * @as(i16, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Reverses filter `filter` on `cur` in place; `prev` is the unfiltered previous
/// scanline (zeros for the first one).
fn unfilter(filter: u8, cur: []u8, prev: []const u8, stride: usize) DecodeError!void {
    switch (stride) {
        inline 1, 2, 3, 4, 6, 8 => |s| return unfilterStride(s, filter, cur, prev),
        else => unreachable,
    }
}

fn unfilterStride(comptime s: usize, filter: u8, cur: []u8, prev: []const u8) DecodeError!void {
    const head = @min(s, cur.len);
    switch (filter) {
        0 => {},
        1 => for (s..cur.len) |i| {
            cur[i] +%= cur[i - s];
        },
        2 => for (cur, prev) |*c, p| {
            c.* +%= p;
        },
        3 => {
            for (0..head) |i| cur[i] +%= prev[i] >> 1;
            for (s..cur.len) |i| cur[i] +%= @intCast((@as(u16, cur[i - s]) + prev[i]) >> 1);
        },
        4 => {
            for (0..head) |i| cur[i] +%= prev[i];
            for (s..cur.len) |i| cur[i] +%= paeth(cur[i - s], prev[i], prev[i - s]);
        },
        else => return error.InvalidFilter,
    }
}

/// Writes scanline `cur` filtered with `filter` into `out`.
fn filterRow(filter: u8, out: []u8, cur: []const u8, prev: []const u8, s: usize) void {
    switch (filter) {
        0 => @memcpy(out, cur),
        1 => for (out, cur, 0..) |*o, c, i| {
            o.* = c -% if (i >= s) cur[i - s] else 0;
        },
        2 => for (out, cur, prev) |*o, c, p| {
            o.* = c -% p;
        },
        3 => for (out, cur, prev, 0..) |*o, c, p, i| {
            const a: u16 = if (i >= s) cur[i - s] else 0;
            o.* = c -% @as(u8, @intCast((a + p) >> 1));
        },
        4 => for (out, cur, prev, 0..) |*o, c, p, i| {
            const a = if (i >= s) cur[i - s] else 0;
            const ul = if (i >= s) prev[i - s] else 0;
            o.* = c -% paeth(a, p, ul);
        },
        else => unreachable,
    }
}

/// Sum of the filtered bytes read as signed values: the usual estimate of how
/// well a row will compress.
fn filterCost(row: []const u8) u64 {
    var sum: u64 = 0;
    for (row) |b| sum += @abs(@as(i8, @bitCast(b)));
    return sum;
}

/// A zlib compressor writing into memory. Initialised in place because the
/// compressor keeps a pointer to the output writer.
const Deflater = struct {
    gpa: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    window: []u8,
    comp: *flate.Compress,

    fn init(d: *Deflater, gpa: std.mem.Allocator) error{OutOfMemory}!void {
        d.gpa = gpa;
        d.out = try .initCapacity(gpa, 4096);
        errdefer d.out.deinit();
        d.window = try gpa.alloc(u8, flate.max_window_len);
        errdefer gpa.free(d.window);
        d.comp = try gpa.create(flate.Compress);
        errdefer gpa.destroy(d.comp);
        d.comp.* = flate.Compress.init(&d.out.writer, d.window, .zlib, .default) catch return error.OutOfMemory;
    }

    fn deinit(d: *Deflater) void {
        d.gpa.destroy(d.comp);
        d.gpa.free(d.window);
        d.out.deinit();
    }

    fn write(d: *Deflater, bytes: []const u8) error{OutOfMemory}!void {
        d.comp.writer.writeAll(bytes) catch return error.OutOfMemory;
    }

    /// Ends the stream; the result stays owned by the deflater.
    fn finish(d: *Deflater) error{OutOfMemory}![]const u8 {
        d.comp.finish() catch return error.OutOfMemory;
        return d.out.written();
    }
};

fn appendChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) error{OutOfMemory}!void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try out.appendSlice(gpa, &crc_bytes);
}

/// Lays out a PNG file: signature, IHDR, `extra` chunks, the zlib stream split
/// into IDATs of at most `split` bytes, IEND.
fn assemble(
    gpa: std.mem.Allocator,
    ihdr: [13]u8,
    extra: []const Chunk,
    zdata: []const u8,
    split: usize,
) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, zdata.len + 64 + 12 * (zdata.len / split + 1));
    try out.appendSlice(gpa, &signature);
    try appendChunk(gpa, &out, "IHDR", &ihdr);
    for (extra) |c| try appendChunk(gpa, &out, &c.kind, c.data);
    var rest = zdata;
    while (rest.len > 0) {
        const n = @min(rest.len, split);
        try appendChunk(gpa, &out, "IDAT", rest[0..n]);
        rest = rest[n..];
    }
    try appendChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

const HeaderOptions = struct {
    interlaced: bool = false,
};

fn headerBytes(width: u32, height: u32, depth: u8, color: ColorType, options: HeaderOptions) [13]u8 {
    var b: [13]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], width, .big);
    std.mem.writeInt(u32, b[4..8], height, .big);
    b[8] = depth;
    b[9] = @backingInt(color);
    b[10] = 0;
    b[11] = 0;
    b[12] = @intFromBool(options.interlaced);
    return b;
}

/// Encodes straight-alpha RGBA8 pixels (`width * height * 4` bytes, rows top to
/// bottom) as an 8-bit RGBA, non-interlaced PNG. Each row gets the filter with
/// the smallest sum of absolute differences. Caller owns the returned bytes.
pub fn encode(gpa: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) EncodeError![]u8 {
    if (width == 0 or height == 0 or width > 0x7fff_ffff or height > 0x7fff_ffff) return error.InvalidDimensions;
    const stride = std.math.cast(usize, @as(u64, width) * 4) orelse return error.InvalidDimensions;
    if (@as(u64, stride) * height != rgba.len) return error.InvalidPixelBuffer;

    // One candidate buffer per filter type, each with its filter byte in front.
    const candidates = try gpa.alloc(u8, 5 * (stride + 1));
    defer gpa.free(candidates);
    const zeros = try gpa.alloc(u8, stride);
    defer gpa.free(zeros);
    @memset(zeros, 0);

    var deflater: Deflater = undefined;
    try deflater.init(gpa);
    defer deflater.deinit();

    for (0..height) |y| {
        const cur = rgba[y * stride ..][0..stride];
        const prev = if (y == 0) zeros else rgba[(y - 1) * stride ..][0..stride];
        var best: usize = 0;
        var best_cost: u64 = std.math.maxInt(u64);
        for (0..5) |f| {
            const buf = candidates[f * (stride + 1) ..][0 .. stride + 1];
            buf[0] = @intCast(f);
            filterRow(@intCast(f), buf[1..], cur, prev, 4);
            const cost = filterCost(buf[1..]);
            if (cost < best_cost) {
                best = f;
                best_cost = cost;
            }
        }
        try deflater.write(candidates[best * (stride + 1) ..][0 .. stride + 1]);
    }
    const zdata = try deflater.finish();
    return assemble(gpa, headerBytes(width, height, 8, .rgba, .{}), &.{}, zdata, max_idat_len);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Packs `samples` (one per channel) into a scanline at `depth` bits each.
fn packSamples(out: []u8, samples: []const u16, depth: u8) void {
    @memset(out, 0);
    for (samples, 0..) |s, i| switch (depth) {
        16 => std.mem.writeInt(u16, out[i * 2 ..][0..2], s, .big),
        8 => out[i] = @intCast(s),
        else => {
            const bit = i * depth;
            const shift: u3 = @intCast(8 - depth - bit % 8);
            out[bit / 8] |= @as(u8, @intCast(s)) << shift;
        },
    };
}

const TestImage = struct {
    width: u32,
    height: u32,
    color: ColorType,
    depth: u8,
    interlaced: bool,
    /// `width * height * channels` raw sample values.
    samples: []const u16,
    plte: ?[]const u8 = null,
    trns: ?[]const u8 = null,
};

/// Builds a PNG from raw samples, cycling through all five filter types row by
/// row and splitting the zlib stream into tiny IDAT chunks.
fn buildTestPng(gpa: std.mem.Allocator, t: TestImage) ![]u8 {
    const header: Header = .{
        .width = t.width,
        .height = t.height,
        .depth = t.depth,
        .color = t.color,
        .interlaced = t.interlaced,
    };
    const ch: usize = t.color.channels();
    const max_rb: usize = @intCast(header.rowBytes(t.width));
    const cur = try gpa.alloc(u8, max_rb);
    defer gpa.free(cur);
    const prev = try gpa.alloc(u8, max_rb);
    defer gpa.free(prev);
    const filtered = try gpa.alloc(u8, max_rb);
    defer gpa.free(filtered);
    const row_samples = try gpa.alloc(u16, t.width * ch);
    defer gpa.free(row_samples);

    var deflater: Deflater = undefined;
    try deflater.init(gpa);
    defer deflater.deinit();

    var row_index: usize = 0;
    const passes: []const Pass = if (t.interlaced) &adam7 else &whole_image;
    for (passes) |p| {
        const pw = p.width(t.width);
        const ph = p.height(t.height);
        if (pw == 0 or ph == 0) continue;
        const rb: usize = @intCast(header.rowBytes(pw));
        @memset(prev, 0);
        for (0..ph) |r| {
            const y = p.y0 + r * p.dy;
            for (0..pw) |i| {
                const x = p.x0 + i * p.dx;
                @memcpy(row_samples[i * ch ..][0..ch], t.samples[(y * t.width + x) * ch ..][0..ch]);
            }
            packSamples(cur[0..rb], row_samples[0 .. pw * ch], t.depth);
            const f: u8 = @intCast(row_index % 5);
            row_index += 1;
            filterRow(f, filtered[0..rb], cur[0..rb], prev[0..rb], header.filterStride());
            try deflater.write(&.{f});
            try deflater.write(filtered[0..rb]);
            @memcpy(prev[0..rb], cur[0..rb]);
        }
    }
    const zdata = try deflater.finish();

    var extra: [2]Chunk = undefined;
    var n: usize = 0;
    if (t.plte) |d| {
        extra[n] = .{
            .kind = "PLTE".*,
            .data = d,
        };
        n += 1;
    }
    if (t.trns) |d| {
        extra[n] = .{
            .kind = "tRNS".*,
            .data = d,
        };
        n += 1;
    }
    return assemble(gpa, headerBytes(t.width, t.height, t.depth, t.color, .{
        .interlaced = t.interlaced,
    }), extra[0..n], zdata, 7);
}

/// The RGBA8 value the spec gives for one pixel's raw samples.
fn referencePixel(t: TestImage, s: []const u16) [4]u8 {
    const max: u32 = (@as(u32, 1) << @intCast(t.depth)) - 1;
    const scale = struct {
        fn f(v: u16, m: u32) u8 {
            return @intCast((@as(u32, v) * 255 + m / 2) / m);
        }
    }.f;
    const key = struct {
        fn f(trns: ?[]const u8, i: usize) ?u16 {
            const d = trns orelse return null;
            return std.mem.readInt(u16, d[i * 2 ..][0..2], .big);
        }
    }.f;
    switch (t.color) {
        .grey => {
            const g = scale(s[0], max);
            return .{ g, g, g, if (key(t.trns, 0) == s[0]) 0 else 255 };
        },
        .rgb => {
            const hit = t.trns != null and key(t.trns, 0) == s[0] and key(t.trns, 1) == s[1] and key(t.trns, 2) == s[2];
            return .{ scale(s[0], max), scale(s[1], max), scale(s[2], max), if (hit) 0 else 255 };
        },
        .indexed => {
            const p = t.plte.?;
            if (s[0] * 3 >= p.len) return .{ 0, 0, 0, 255 };
            const a: u8 = if (t.trns) |tr| (if (s[0] < tr.len) tr[s[0]] else 255) else 255;
            return .{ p[s[0] * 3], p[s[0] * 3 + 1], p[s[0] * 3 + 2], a };
        },
        .grey_alpha => {
            const g = scale(s[0], max);
            return .{ g, g, g, scale(s[1], max) };
        },
        .rgba => return .{ scale(s[0], max), scale(s[1], max), scale(s[2], max), scale(s[3], max) },
    }
}

fn expectDecodesLikeReference(t: TestImage) !void {
    const gpa = testing.allocator;
    const png = try buildTestPng(gpa, t);
    defer gpa.free(png);
    var img = try decode(gpa, png);
    defer img.deinit(gpa);
    try testing.expectEqual(t.width, img.width);
    try testing.expectEqual(t.height, img.height);
    const ch: usize = t.color.channels();
    for (0..@as(usize, t.width) * t.height) |i| {
        const want = referencePixel(t, t.samples[i * ch ..][0..ch]);
        try testing.expectEqualSlices(u8, &want, img.pixels[i * 4 ..][0..4]);
    }
}

test "encode then decode round-trips a gradient with alpha" {
    const gpa = testing.allocator;
    const w = 37;
    const h = 23;
    var rgba: [w * h * 4]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const p = rgba[(y * w + x) * 4 ..][0..4];
        p.* = .{ @intCast(x * 7), @intCast(y * 11), @intCast((x + y) * 3), @intCast(255 - x * 5) };
    };
    const png = try encode(gpa, w, h, &rgba);
    defer gpa.free(png);
    try testing.expect(!hasColorProfile(png));
    var img = try decode(gpa, png);
    defer img.deinit(gpa);
    try testing.expectEqual(@as(u32, w), img.width);
    try testing.expectEqual(@as(u32, h), img.height);
    try testing.expectEqualSlices(u8, &rgba, img.pixels);
}

test "encode rejects bad input" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidDimensions, encode(gpa, 0, 1, &.{}));
    try testing.expectError(error.InvalidPixelBuffer, encode(gpa, 2, 2, &@as([15]u8, @splat(0))));
}

test "every colour type and bit depth, plain and interlaced" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x504e47);
    const rand = prng.random();
    const combos = [_]struct {
        ColorType,
        u8,
    }{
        .{ .grey, 1 },    .{ .grey, 2 },       .{ .grey, 4 },        .{ .grey, 8 },    .{ .grey, 16 },
        .{ .rgb, 8 },     .{ .rgb, 16 },       .{ .indexed, 1 },     .{ .indexed, 2 }, .{ .indexed, 4 },
        .{ .indexed, 8 }, .{ .grey_alpha, 8 }, .{ .grey_alpha, 16 }, .{ .rgba, 8 },    .{ .rgba, 16 },
    };
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 3, 2 }, .{ 13, 9 }, .{ 17, 19 } };
    for (combos) |combo| for (sizes) |size| for ([_]bool{ false, true }) |interlaced| {
        const color, const depth = combo;
        const ch = color.channels();
        const n = size[0] * size[1] * ch;
        const samples = try gpa.alloc(u16, n);
        defer gpa.free(samples);
        const max: u32 = (@as(u32, 1) << @intCast(depth)) - 1;
        for (samples) |*s| s.* = @intCast(rand.uintAtMost(u32, max));

        var plte: [256 * 3]u8 = undefined;
        rand.bytes(&plte);
        var trns_buf: [256]u8 = undefined;
        rand.bytes(&trns_buf);
        var t: TestImage = .{
            .width = size[0],
            .height = size[1],
            .color = color,
            .depth = depth,
            .interlaced = interlaced,
            .samples = samples,
        };
        switch (color) {
            .indexed => {
                // A palette shorter than the index range exercises out-of-range indices.
                const entries: usize = @min(256, max + 1) - @intFromBool(depth > 1);
                t.plte = plte[0 .. entries * 3];
                t.trns = trns_buf[0 .. entries / 2];
            },
            .grey, .rgb => {
                // The key is the first pixel's colour, so it matches at least once.
                for (0..ch) |c| std.mem.writeInt(u16, trns_buf[c * 2 ..][0..2], samples[c], .big);
                t.trns = trns_buf[0 .. ch * 2];
            },
            else => {},
        }
        try expectDecodesLikeReference(t);
        if (t.trns != null) {
            t.trns = null;
            try expectDecodesLikeReference(t);
        }
    };
}

test "sample scaling matches the spec" {
    const gpa = testing.allocator;
    // Grey 2-bit 0..3 -> 0, 85, 170, 255; grey 16-bit rounds to nearest.
    {
        const png = try buildTestPng(gpa, .{
            .width = 4,
            .height = 1,
            .color = .grey,
            .depth = 2,
            .interlaced = false,
            .samples = &.{ 0, 1, 2, 3 },
        });
        defer gpa.free(png);
        var img = try decode(gpa, png);
        defer img.deinit(gpa);
        try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 85, 85, 85, 255, 170, 170, 170, 255, 255, 255, 255, 255 }, img.pixels);
    }
    {
        const png = try buildTestPng(gpa, .{
            .width = 3,
            .height = 1,
            .color = .grey_alpha,
            .depth = 16,
            .interlaced = false,
            .samples = &.{ 0x8080, 0xffff, 0x0080, 0x0000, 0x807f, 0x7f80 },
        });
        defer gpa.free(png);
        var img = try decode(gpa, png);
        defer img.deinit(gpa);
        try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255, 0, 0, 0, 0, 128, 128, 128, 127 }, img.pixels);
    }
}

test "interlaced RGBA matches the same image non-interlaced" {
    const gpa = testing.allocator;
    const w = 29;
    const h = 31;
    var samples: [w * h * 4]u16 = undefined;
    for (&samples, 0..) |*s, i| s.* = @intCast((i * 37 + i / 7) % 256);
    var images: [2]Image = undefined;
    for ([_]bool{ false, true }, 0..) |interlaced, k| {
        const png = try buildTestPng(gpa, .{
            .width = w,
            .height = h,
            .color = .rgba,
            .depth = 8,
            .interlaced = interlaced,
            .samples = &samples,
        });
        defer gpa.free(png);
        images[k] = try decode(gpa, png);
    }
    defer for (&images) |*img| img.deinit(gpa);
    try testing.expectEqualSlices(u8, images[0].pixels, images[1].pixels);
    for (samples, images[1].pixels) |s, p| try testing.expectEqual(@as(u8, @intCast(s)), p);
}

fn smallPng(gpa: std.mem.Allocator) ![]u8 {
    var rgba: [6 * 5 * 4]u8 = undefined;
    for (&rgba, 0..) |*b, i| b.* = @intCast(i * 13 % 256);
    return encode(gpa, 6, 5, &rgba);
}

test "corrupt CRC is rejected" {
    const gpa = testing.allocator;
    const png = try smallPng(gpa);
    defer gpa.free(png);
    // Flip one bit in IHDR's data, then in the last IDAT's CRC.
    png[8 + 8 + 3] ^= 1;
    try testing.expectError(error.BadCrc, decode(gpa, png));
    png[8 + 8 + 3] ^= 1;
    png[png.len - 12 - 1] ^= 0x80;
    try testing.expectError(error.BadCrc, decode(gpa, png));
}

test "wrong zlib checksum is rejected" {
    const gpa = testing.allocator;
    const png = try smallPng(gpa);
    defer gpa.free(png);
    // The only IDAT ends 12 bytes before the file's end; its last 4 data bytes are the Adler-32.
    const idat_len = std.mem.readInt(u32, png[33..37], .big);
    const idat_end = 41 + idat_len;
    png[idat_end - 1] ^= 1;
    const crc = std.hash.Crc32.hash(png[37..idat_end]);
    std.mem.writeInt(u32, png[idat_end..][0..4], crc, .big);
    try testing.expectError(error.CorruptImageData, decode(gpa, png));
}

test "every truncation is rejected" {
    const gpa = testing.allocator;
    const png = try smallPng(gpa);
    defer gpa.free(png);
    for (0..png.len) |n| {
        if (decode(gpa, png[0..n])) |img| {
            var copy = img;
            copy.deinit(gpa);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "damaged image data fails cleanly" {
    const gpa = testing.allocator;
    const png = try smallPng(gpa);
    defer gpa.free(png);
    const idat_start = 8 + 25 + 8; // signature, IHDR chunk, IDAT length and type
    const idat_len = std.mem.readInt(u32, png[33..37], .big);
    var prng: std.Random.DefaultPrng = .init(7);
    const rand = prng.random();
    const copy = try gpa.dupe(u8, png);
    defer gpa.free(copy);
    for (0..2000) |_| {
        @memcpy(copy, png);
        const pos = idat_start + rand.uintLessThan(usize, idat_len);
        copy[pos] ^= @as(u8, 1) << rand.int(u3);
        // Fix the CRC so the damage reaches the decompressor.
        const crc = std.hash.Crc32.hash(copy[idat_start - 4 .. idat_start + idat_len]);
        std.mem.writeInt(u32, copy[idat_start + idat_len ..][0..4], crc, .big);
        if (decode(gpa, copy)) |img| {
            var i = img;
            i.deinit(gpa);
        } else |_| {}
    }
}

test "header checks" {
    const gpa = testing.allocator;
    try testing.expectError(error.NotPng, decode(gpa, "GIF89a"));
    try testing.expectError(error.Truncated, decode(gpa, signature[0..5]));
    const too_big = try assemble(gpa, headerBytes(1 << 15, 1 << 14, 8, .rgba, .{}), &.{}, "x", 64);
    defer gpa.free(too_big);
    try testing.expectError(error.ImageTooLarge, decode(gpa, too_big));
    const bad_depth = try assemble(gpa, headerBytes(1, 1, 4, .rgb, .{}), &.{}, "x", 64);
    defer gpa.free(bad_depth);
    try testing.expectError(error.InvalidHeader, decode(gpa, bad_depth));
    const no_palette = try assemble(gpa, headerBytes(1, 1, 8, .indexed, .{}), &.{}, "x", 64);
    defer gpa.free(no_palette);
    try testing.expectError(error.InvalidPalette, decode(gpa, no_palette));
}

test "colour profile detection" {
    const gpa = testing.allocator;
    var deflater: Deflater = undefined;
    try deflater.init(gpa);
    defer deflater.deinit();
    try deflater.write(&.{ 0, 1, 2, 3, 4 });
    const zdata = try deflater.finish();
    const gama: Chunk = .{
        .kind = "gAMA".*,
        .data = &.{ 0, 0, 0xb1, 0x8f },
    };
    const png = try assemble(gpa, headerBytes(1, 1, 8, .rgba, .{}), &.{gama}, zdata, 64);
    defer gpa.free(png);
    try testing.expect(hasColorProfile(png));
    var img = try decode(gpa, png);
    defer img.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, img.pixels);
}

test "decode the corpus PNGs" {
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_][]const u8{ "corpus/landing/images", "corpus/landing/renders" }) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{
            .iterate = true,
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const bytes = try dir.readFileAlloc(io, entry.name, gpa, .unlimited);
            defer gpa.free(bytes);
            if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], &signature)) continue;
            var img = decode(gpa, bytes) catch |err| {
                std.debug.print("{s}/{s}: {t}\n", .{ path, entry.name, err });
                return err;
            };
            defer img.deinit(gpa);
            try testing.expectEqual(std.mem.readInt(u32, bytes[16..20], .big), img.width);
            try testing.expectEqual(std.mem.readInt(u32, bytes[20..24], .big), img.height);
            try testing.expectEqual(@as(usize, img.width) * img.height * 4, img.pixels.len);
        }
    }
}
