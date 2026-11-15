//! JPEG: decode baseline, extended sequential and progressive JPEG to RGBA8.
//!
//! The pixel path follows the defaults of the IJG libjpeg family (and so of
//! libjpeg-turbo and the browsers built on it), so renders compare exactly:
//!
//! - the accurate integer inverse DCT ("islow": 13-bit constants, two passes,
//!   the 10-bit wrapping range limit),
//! - fancy (triangular) chroma upsampling for h2v1, h2v2 and h1v2, plain
//!   replication for every other integer ratio,
//! - YCbCr to RGB with 16-bit fixed-point tables and libjpeg's rounding.
//!
//! Corrupt data never panics: it returns an error. Like libjpeg, entropy data
//! that ends early (a truncated file, a marker in the middle of a scan) leaves
//! the remaining coefficients as they are, so a truncated progressive file
//! decodes as far as its data goes. (libjpeg additionally smooths blocks whose
//! low frequencies are still incomplete; that is not done here, so a
//! truncated progressive file can differ from libjpeg's output.)

const std = @import("std");
const Image = @import("image.zig").Image;

pub const Error = error{
    /// The bytes are not a well-formed JPEG.
    InvalidJpeg,
    /// The file ends before any image data.
    Truncated,
    /// Arithmetic coding, lossless, 12/16-bit, fractional sampling, DNL height.
    Unsupported,
    /// More than `max_pixels` pixels.
    TooLarge,
    OutOfMemory,
};

/// The largest image `decode` accepts, in pixels.
pub const max_pixels: u64 = 1 << 28;

/// What the headers say, without decoding.
pub const Info = struct {
    width: u32,
    height: u32,
    /// 1 (grayscale), 3 (YCbCr or RGB) or 4 (CMYK or YCCK).
    components: u8,
    progressive: bool,
    /// An ICC profile is embedded (APP2 ICC_PROFILE). Decoding ignores it.
    has_icc: bool,
    /// EXIF orientation 1..8; 1 when absent. Decoding does not apply it.
    exif_orientation: u8,
    /// The APP14 Adobe colour transform (0 none, 1 YCbCr, 2 YCCK) when present.
    adobe_transform: ?u8,
};

/// Reads the headers up to the first scan and reports size, layout and metadata.
pub fn info(bytes: []const u8) Error!Info {
    if (bytes.len < 2 or bytes[0] != 0xFF or bytes[1] != 0xD8) return error.InvalidJpeg;
    var result: Info = .{
        .width = 0,
        .height = 0,
        .components = 0,
        .progressive = false,
        .has_icc = false,
        .exif_orientation = 1,
        .adobe_transform = null,
    };
    var have_frame = false;
    var pos: usize = 2;
    while (findMarker(bytes, pos)) |m| {
        const code = bytes[m + 1];
        pos = m + 2;
        if (code == 0xD9 or code == 0xDA) break;
        if (isStandalone(code)) continue;
        const seg = segment(bytes, pos) orelse break;
        pos += 2 + seg.len;
        switch (code) {
            0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => if (!have_frame) {
                if (seg.len < 6) return error.InvalidJpeg;
                result.height = readU16(seg[1..3]);
                result.width = readU16(seg[3..5]);
                result.components = seg[5];
                result.progressive = switch (code) {
                    0xC2, 0xC6, 0xCA, 0xCE => true,
                    else => false,
                };
                have_frame = true;
            },
            0xE1 => if (exifOrientation(seg)) |o| {
                result.exif_orientation = o;
            },
            0xE2 => if (seg.len >= 12 and std.mem.eql(u8, seg[0..12], "ICC_PROFILE\x00")) {
                result.has_icc = true;
            },
            0xEE => if (adobeTransform(seg)) |t| {
                result.adobe_transform = t;
            },
            else => {},
        }
    }
    if (!have_frame) return if (pos >= bytes.len - 1) error.Truncated else error.InvalidJpeg;
    return result;
}

/// Decodes a JPEG to RGBA8 (A = 255). The caller owns `Image.pixels`.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Image {
    var d: Decoder = .{
        .gpa = gpa,
        .data = bytes,
    };
    defer d.deinit();
    try d.run();
    return d.output();
}

// ---------------------------------------------------------------------------
// Markers

/// The position of the next marker's 0xFF at or after `start`, skipping stuffed
/// bytes, fill bytes, restart markers and stray data.
fn findMarker(data: []const u8, start: usize) ?usize {
    var p = start;
    while (p + 1 < data.len) {
        if (data[p] != 0xFF) {
            p += 1;
            continue;
        }
        const n = data[p + 1];
        if (n == 0xFF) {
            p += 1;
        } else if (n == 0x00 or (n >= 0xD0 and n <= 0xD7)) {
            p += 2;
        } else {
            return p;
        }
    }
    return null;
}

/// Markers that carry no length field.
fn isStandalone(code: u8) bool {
    return code == 0x01 or code == 0xD8 or (code >= 0xD0 and code <= 0xD7);
}

/// The payload of the segment whose length field starts at `pos`, or null when
/// the file ends inside it.
fn segment(data: []const u8, pos: usize) ?[]const u8 {
    if (pos + 2 > data.len) return null;
    const len = readU16(data[pos..][0..2]);
    if (len < 2 or len > data.len - pos) return null;
    return data[pos + 2 .. pos + len];
}

fn readU16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .big);
}

fn adobeTransform(seg: []const u8) ?u8 {
    if (seg.len < 12 or !std.mem.eql(u8, seg[0..5], "Adobe")) return null;
    return seg[11];
}

fn exifOrientation(seg: []const u8) ?u8 {
    if (seg.len < 14 or !std.mem.eql(u8, seg[0..6], "Exif\x00\x00")) return null;
    const t = seg[6..];
    const endian: std.builtin.Endian = if (t[0] == 'I' and t[1] == 'I')
        .little
    else if (t[0] == 'M' and t[1] == 'M')
        .big
    else
        return null;
    if (std.mem.readInt(u16, t[2..4], endian) != 42) return null;
    const ifd: u64 = std.mem.readInt(u32, t[4..8], endian);
    if (ifd + 2 > t.len) return null;
    const off: usize = @intCast(ifd);
    const count = std.mem.readInt(u16, t[off..][0..2], endian);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = off + 2 + i * 12;
        if (e + 12 > t.len) return null;
        if (std.mem.readInt(u16, t[e..][0..2], endian) != 0x0112) continue;
        const kind = std.mem.readInt(u16, t[e + 2 ..][0..2], endian);
        const value: u32 = switch (kind) {
            3 => std.mem.readInt(u16, t[e + 8 ..][0..2], endian),
            4 => std.mem.readInt(u32, t[e + 8 ..][0..4], endian),
            else => return null,
        };
        return if (value >= 1 and value <= 8) @intCast(value) else null;
    }
    return null;
}

/// Zigzag position to natural (row-major) position.
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// Natural position for zigzag index `k`; like libjpeg, indexes past the end
/// (corrupt run lengths) land on the last coefficient.
inline fn natural(k: usize) usize {
    return if (k < 64) zigzag[k] else 63;
}

// ---------------------------------------------------------------------------
// Huffman

const fast_bits = 9;

/// A canonical Huffman table: a `fast_bits` lookahead table plus the JPEG
/// spec's maxcode/valoffset arrays for longer codes.
const HuffTable = struct {
    /// `(length << 8) | symbol` for codes up to `fast_bits` long; 0 = longer.
    fast: [1 << fast_bits]u16,
    /// Largest code of each length (index 1..16), -1 when there is none.
    maxcode: [17]i32,
    /// Symbol index = code + valoffset[length].
    valoffset: [17]i32,
    symbols: [256]u8,
    count: u16,

    /// Builds a table from the DHT counts per length (1..16) and symbols.
    /// Rejects over-subscribed tables the way libjpeg does.
    fn build(counts: *const [16]u8, symbols: []const u8) Error!HuffTable {
        var t: HuffTable = .{
            .fast = @splat(0),
            .maxcode = @splat(-1),
            .valoffset = @splat(0),
            .symbols = @splat(0),
            .count = @intCast(symbols.len),
        };
        var total: usize = 0;
        for (counts) |n| total += n;
        if (total != symbols.len or total > 256) return error.InvalidJpeg;
        @memcpy(t.symbols[0..symbols.len], symbols);
        var code: u32 = 0;
        var k: u32 = 0;
        for (1..17) |l| {
            const n: u32 = counts[l - 1];
            t.valoffset[l] = @as(i32, @intCast(k)) - @as(i32, @intCast(code));
            if (n > 0) {
                // No code may be all ones, so the codes must stay below 2^l - 1.
                if (code + n >= (@as(u32, 1) << @intCast(l))) return error.InvalidJpeg;
                if (l <= fast_bits) {
                    const shift: u5 = @intCast(fast_bits - l);
                    for (0..n) |i| {
                        const base = (code + @as(u32, @intCast(i))) << shift;
                        const entry: u16 = @intCast((l << 8) | symbols[k + i]);
                        @memset(t.fast[base .. base + (@as(u32, 1) << shift)], entry);
                    }
                }
                code += n;
                k += n;
                t.maxcode[l] = @intCast(code - 1);
            }
            code <<= 1;
        }
        return t;
    }
};

// ---------------------------------------------------------------------------
// Bit reader

/// Reads entropy-coded bits, unstuffing 0xFF 0x00. At a marker or the end of
/// the data it feeds zero bits and, once a needed bit was fake, sets
/// `insufficient` (libjpeg then skips the rest of the scan's MCUs).
const BitReader = struct {
    data: []const u8,
    pos: usize,
    /// Next bits, most significant first.
    buf: u64 = 0,
    nbits: u32 = 0,
    /// How many of the trailing `nbits` are zero padding past a marker.
    fake: u32 = 0,
    marker_hit: bool = false,
    insufficient: bool = false,

    fn fill(br: *BitReader) void {
        while (br.nbits <= 56) {
            var byte: u8 = 0;
            if (br.marker_hit) {
                br.fake += 8;
            } else if (br.pos >= br.data.len) {
                br.marker_hit = true;
                br.fake += 8;
            } else {
                byte = br.data[br.pos];
                if (byte != 0xFF) {
                    br.pos += 1;
                } else {
                    var q = br.pos + 1;
                    while (q < br.data.len and br.data[q] == 0xFF) q += 1;
                    if (q < br.data.len and br.data[q] == 0) {
                        br.pos = q + 1;
                    } else {
                        br.pos = q - 1;
                        br.marker_hit = true;
                        br.fake += 8;
                        byte = 0;
                    }
                }
            }
            br.buf |= @as(u64, byte) << @intCast(56 - br.nbits);
            br.nbits += 8;
        }
    }

    inline fn ensure(br: *BitReader, n: u32) void {
        if (br.nbits < n) br.fill();
    }

    inline fn consume(br: *BitReader, n: u32) void {
        br.buf = if (n >= 64) 0 else br.buf << @intCast(n);
        br.nbits -= n;
        if (br.nbits < br.fake) {
            br.fake = br.nbits;
            br.insufficient = true;
        }
    }

    /// Reads `n` (0..16) bits as an unsigned value.
    inline fn bits(br: *BitReader, n: u32) u32 {
        if (n == 0) return 0;
        br.ensure(n);
        const v: u32 = @intCast(br.buf >> @intCast(64 - n));
        br.consume(n);
        return v;
    }

    /// Reads `s` bits and sign-extends them as JPEG's EXTEND (F.2.2.1).
    inline fn receiveExtend(br: *BitReader, s: u32) i32 {
        if (s == 0) return 0;
        const v: i32 = @intCast(br.bits(s));
        const half: i32 = @as(i32, 1) << @intCast(s - 1);
        return if (v < half) v - (half << 1) + 1 else v;
    }

    fn decode(br: *BitReader, t: *const HuffTable) u8 {
        br.ensure(16);
        const look: u32 = @intCast(br.buf >> 48);
        const f = t.fast[look >> (16 - fast_bits)];
        if (f != 0) {
            br.consume(f >> 8);
            return @truncate(f);
        }
        var l: u32 = fast_bits + 1;
        while (l <= 16) : (l += 1) {
            const code: i32 = @intCast(look >> @intCast(16 - l));
            if (code <= t.maxcode[l]) {
                br.consume(l);
                const idx = code + t.valoffset[l];
                if (idx < 0 or idx >= t.count) return 0;
                return t.symbols[@intCast(idx)];
            }
        }
        // Not a code: libjpeg consumes 16 bits and fakes a zero symbol.
        br.consume(16);
        return 0;
    }
};

/// Throws away buffered bits and steps over the next marker if it is RSTn.
/// Any other marker stays unread, so the rest of the scan reads as zeros.
fn skipRestart(br: *BitReader) void {
    br.buf = 0;
    br.nbits = 0;
    br.fake = 0;
    var p = br.pos;
    const data = br.data;
    while (p + 1 < data.len) {
        if (data[p] != 0xFF) {
            p += 1;
            continue;
        }
        const n = data[p + 1];
        if (n == 0x00) {
            p += 2;
        } else if (n == 0xFF) {
            p += 1;
        } else break;
    }
    if (p + 1 < data.len and data[p + 1] >= 0xD0 and data[p + 1] <= 0xD7) {
        br.pos = p + 2;
        br.marker_hit = false;
        br.insufficient = false;
    } else {
        br.pos = @min(p, data.len);
        br.marker_hit = true;
    }
}

// ---------------------------------------------------------------------------
// Decoder

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    /// Blocks per row and rows of blocks, padded to whole MCUs.
    bw: usize = 0,
    bh: usize = 0,
    /// Real (downsampled) size in samples.
    cw: usize = 0,
    ch: usize = 0,
    /// `bw * bh` blocks of 64 coefficients in natural order.
    coefs: []i16 = &.{},
    /// Quantisation table latched at the component's first scan.
    quant: [64]u16 = @splat(0),
    latched: bool = false,
    pred: i32 = 0,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
};

const Mode = enum {
    sequential,
    dc_first,
    dc_refine,
    ac_first,
    ac_refine,
};

const ColorSpace = enum {
    gray,
    ycbcr,
    rgb,
    cmyk,
    ycck,
};

const Decoder = struct {
    gpa: std.mem.Allocator,
    data: []const u8,
    width: u32 = 0,
    height: u32 = 0,
    ncomp: u8 = 0,
    comps: [4]Component = undefined,
    hmax: u8 = 1,
    vmax: u8 = 1,
    mcux: usize = 0,
    mcuy: usize = 0,
    have_frame: bool = false,
    progressive: bool = false,
    scans: u32 = 0,
    restart_interval: u32 = 0,
    eobrun: u32 = 0,
    qt: [4][64]u16 = @splat(@splat(0)),
    qt_defined: [4]bool = @splat(false),
    dc_tables: [4]HuffTable = undefined,
    ac_tables: [4]HuffTable = undefined,
    dc_defined: [4]bool = @splat(false),
    ac_defined: [4]bool = @splat(false),
    saw_jfif: bool = false,
    adobe_transform: ?u8 = null,

    fn deinit(d: *Decoder) void {
        if (!d.have_frame) return;
        for (d.comps[0..d.ncomp]) |*c| d.gpa.free(c.coefs);
    }

    fn run(d: *Decoder) Error!void {
        const data = d.data;
        if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) return error.InvalidJpeg;
        var pos: usize = 2;
        var saw_eoi = false;
        while (findMarker(data, pos)) |m| {
            const code = data[m + 1];
            pos = m + 2;
            if (code == 0xD9) {
                saw_eoi = true;
                break;
            }
            if (isStandalone(code)) continue;
            const seg = segment(data, pos) orelse break;
            const next = pos + 2 + seg.len;
            pos = next;
            switch (code) {
                0xC0, 0xC1, 0xC2 => try d.frame(seg, code == 0xC2),
                0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.Unsupported,
                0xC4 => try d.huffmanTables(seg),
                0xDB => try d.quantTables(seg),
                0xDD => {
                    if (seg.len < 2) return error.InvalidJpeg;
                    d.restart_interval = readU16(seg[0..2]);
                },
                0xDA => pos = try d.scan(seg, next),
                0xE0 => if (seg.len >= 14 and std.mem.eql(u8, seg[0..5], "JFIF\x00")) {
                    d.saw_jfif = true;
                },
                0xEE => if (adobeTransform(seg)) |t| {
                    d.adobe_transform = t;
                },
                else => {},
            }
        }
        if (d.scans == 0) return if (saw_eoi) error.InvalidJpeg else error.Truncated;
    }

    fn frame(d: *Decoder, seg: []const u8, progressive: bool) Error!void {
        if (d.have_frame) return error.InvalidJpeg;
        if (seg.len < 6) return error.InvalidJpeg;
        if (seg[0] != 8) return error.Unsupported;
        const height = readU16(seg[1..3]);
        const width = readU16(seg[3..5]);
        const n = seg[5];
        if (height == 0) return error.Unsupported; // height from a DNL marker
        if (width == 0) return error.InvalidJpeg;
        if (n != 1 and n != 3 and n != 4) return error.Unsupported;
        if (seg.len < 6 + 3 * @as(usize, n)) return error.InvalidJpeg;
        if (@as(u64, width) * height > max_pixels) return error.TooLarge;
        d.width = width;
        d.height = height;
        d.progressive = progressive;
        d.ncomp = n;
        for (0..n) |i| {
            const b = seg[6 + 3 * i ..][0..3];
            const h = b[1] >> 4;
            const v = b[1] & 15;
            if (h < 1 or h > 4 or v < 1 or v > 4 or b[2] > 3) return error.InvalidJpeg;
            for (d.comps[0..i]) |c| if (c.id == b[0]) return error.InvalidJpeg;
            d.comps[i] = .{
                .id = b[0],
                .h = h,
                .v = v,
                .tq = b[2],
            };
            d.hmax = @max(d.hmax, h);
            d.vmax = @max(d.vmax, v);
        }
        d.mcux = ceilDiv(width, 8 * @as(usize, d.hmax));
        d.mcuy = ceilDiv(height, 8 * @as(usize, d.vmax));
        for (d.comps[0..n], 0..) |*c, i| {
            c.bw = d.mcux * c.h;
            c.bh = d.mcuy * c.v;
            c.cw = ceilDiv(@as(usize, width) * c.h, d.hmax);
            c.ch = ceilDiv(@as(usize, height) * c.v, d.vmax);
            c.coefs = d.gpa.alloc(i16, c.bw * c.bh * 64) catch |err| {
                for (d.comps[0..i]) |*prev| d.gpa.free(prev.coefs);
                return err;
            };
            @memset(c.coefs, 0);
        }
        d.have_frame = true;
    }

    fn huffmanTables(d: *Decoder, seg: []const u8) Error!void {
        var p: usize = 0;
        while (p < seg.len) {
            if (seg.len - p < 17) return error.InvalidJpeg;
            const class = seg[p] >> 4;
            const id = seg[p] & 15;
            if (class > 1 or id > 3) return error.InvalidJpeg;
            const counts = seg[p + 1 ..][0..16];
            var total: usize = 0;
            for (counts) |c| total += c;
            if (total > 256 or seg.len - p - 17 < total) return error.InvalidJpeg;
            const symbols = seg[p + 17 ..][0..total];
            const table = try HuffTable.build(counts, symbols);
            if (class == 0) {
                // DC magnitudes above 15 are invalid (libjpeg rejects them).
                for (symbols) |s| if (s > 15) return error.InvalidJpeg;
                d.dc_tables[id] = table;
                d.dc_defined[id] = true;
            } else {
                d.ac_tables[id] = table;
                d.ac_defined[id] = true;
            }
            p += 17 + total;
        }
    }

    fn quantTables(d: *Decoder, seg: []const u8) Error!void {
        var p: usize = 0;
        while (p < seg.len) {
            const precision = seg[p] >> 4;
            const id = seg[p] & 15;
            if (precision > 1 or id > 3) return error.InvalidJpeg;
            const size: usize = if (precision == 0) 64 else 128;
            if (seg.len - p - 1 < size) return error.InvalidJpeg;
            const body = seg[p + 1 ..][0..size];
            for (0..64) |k| {
                d.qt[id][zigzag[k]] = if (precision == 0) body[k] else readU16(body[2 * k ..][0..2]);
            }
            d.qt_defined[id] = true;
            p += 1 + size;
        }
    }

    /// Decodes one scan; returns where marker parsing resumes.
    fn scan(d: *Decoder, seg: []const u8, start: usize) Error!usize {
        if (!d.have_frame) return error.InvalidJpeg;
        if (seg.len < 1) return error.InvalidJpeg;
        const ns = seg[0];
        if (ns < 1 or ns > 4 or seg.len < 4 + 2 * @as(usize, ns)) return error.InvalidJpeg;
        var list: [4]*Component = undefined;
        var blocks_in_mcu: usize = 0;
        for (0..ns) |i| {
            const cid = seg[1 + 2 * i];
            const tables = seg[2 + 2 * i];
            const c = for (d.comps[0..d.ncomp]) |*c| {
                if (c.id == cid) break c;
            } else return error.InvalidJpeg;
            for (list[0..i]) |prev| if (prev == c) return error.InvalidJpeg;
            c.dc_table = tables >> 4;
            c.ac_table = tables & 15;
            if (c.dc_table > 3 or c.ac_table > 3) return error.InvalidJpeg;
            list[i] = c;
            blocks_in_mcu += @as(usize, c.h) * c.v;
        }
        if (ns > 1 and blocks_in_mcu > 10) return error.InvalidJpeg;
        const comps = list[0..ns];
        const ss = seg[1 + 2 * ns];
        const se = seg[2 + 2 * ns];
        const ah = seg[3 + 2 * ns] >> 4;
        const al = seg[3 + 2 * ns] & 15;

        var mode: Mode = .sequential;
        if (d.progressive) {
            if (ss == 0) {
                if (se != 0) return error.InvalidJpeg;
            } else {
                if (se < ss or se > 63 or ns != 1) return error.InvalidJpeg;
            }
            if (ah != 0 and al != ah - 1) return error.InvalidJpeg;
            if (al > 13) return error.InvalidJpeg;
            mode = if (ss == 0)
                (if (ah == 0) .dc_first else .dc_refine)
            else
                (if (ah == 0) .ac_first else .ac_refine);
        }

        for (comps) |c| {
            const needs_dc = mode == .sequential or mode == .dc_first;
            const needs_ac = mode == .sequential or mode == .ac_first or mode == .ac_refine;
            if (needs_dc and !d.dc_defined[c.dc_table]) return error.InvalidJpeg;
            if (needs_ac and !d.ac_defined[c.ac_table]) return error.InvalidJpeg;
            if (!c.latched) {
                if (!d.qt_defined[c.tq]) return error.InvalidJpeg;
                c.quant = d.qt[c.tq];
                c.latched = true;
            }
            c.pred = 0;
        }
        d.eobrun = 0;

        var br: BitReader = .{
            .data = d.data,
            .pos = start,
        };
        const ri = d.restart_interval;
        const s: ScanParams = .{
            .ss = ss,
            .se = se,
            .al = @truncate(al),
        };
        var mcu: usize = 0;

        if (ns == 1) {
            const c = comps[0];
            const nbx = ceilDiv(c.cw, 8);
            const nby = ceilDiv(c.ch, 8);
            for (0..nby) |by| {
                for (0..nbx) |bx| {
                    if (ri != 0 and mcu != 0 and mcu % ri == 0) d.restart(&br, comps);
                    mcu += 1;
                    if (br.insufficient) continue;
                    const blk = c.coefs[(by * c.bw + bx) * 64 ..][0..64];
                    d.decodeBlock(&br, mode, s, c, blk);
                }
            }
        } else {
            for (0..d.mcuy) |my| {
                for (0..d.mcux) |mx| {
                    if (ri != 0 and mcu != 0 and mcu % ri == 0) d.restart(&br, comps);
                    mcu += 1;
                    if (br.insufficient) continue;
                    for (comps) |c| {
                        for (0..c.v) |v| {
                            for (0..c.h) |h| {
                                const row = my * c.v + v;
                                const col = mx * c.h + h;
                                const blk = c.coefs[(row * c.bw + col) * 64 ..][0..64];
                                d.decodeBlock(&br, mode, s, c, blk);
                            }
                        }
                    }
                }
            }
        }
        d.scans += 1;
        return br.pos;
    }

    fn restart(d: *Decoder, br: *BitReader, comps: []const *Component) void {
        skipRestart(br);
        for (comps) |c| c.pred = 0;
        d.eobrun = 0;
    }

    const ScanParams = struct {
        ss: u8,
        se: u8,
        al: u4,
    };

    inline fn decodeBlock(d: *Decoder, br: *BitReader, mode: Mode, s: ScanParams, c: *Component, blk: *[64]i16) void {
        switch (mode) {
            .sequential => d.decodeSequential(br, c, blk),
            .dc_first => {
                const t = br.decode(&d.dc_tables[c.dc_table]);
                c.pred +%= br.receiveExtend(t);
                blk[0] = shl(c.pred, s.al);
            },
            .dc_refine => {
                if (br.bits(1) != 0) blk[0] |= shl(1, s.al);
            },
            .ac_first => d.decodeAcFirst(br, s, c, blk),
            .ac_refine => d.decodeAcRefine(br, s, c, blk),
        }
    }

    fn decodeSequential(d: *Decoder, br: *BitReader, c: *Component, blk: *[64]i16) void {
        const t = br.decode(&d.dc_tables[c.dc_table]);
        c.pred +%= br.receiveExtend(t);
        blk[0] = @truncate(c.pred);
        const ac = &d.ac_tables[c.ac_table];
        var k: usize = 1;
        while (k < 64) {
            const rs = br.decode(ac);
            const r = rs >> 4;
            const size = rs & 15;
            if (size != 0) {
                k += r;
                blk[natural(k)] = @truncate(br.receiveExtend(size));
                k += 1;
            } else {
                if (r != 15) break;
                k += 16;
            }
        }
    }

    fn decodeAcFirst(d: *Decoder, br: *BitReader, s: ScanParams, c: *Component, blk: *[64]i16) void {
        if (d.eobrun > 0) {
            d.eobrun -= 1;
            return;
        }
        const ac = &d.ac_tables[c.ac_table];
        var k: usize = s.ss;
        while (k <= s.se) : (k += 1) {
            const rs = br.decode(ac);
            const r = rs >> 4;
            const size = rs & 15;
            if (size != 0) {
                k += r;
                blk[natural(k)] = shl(br.receiveExtend(size), s.al);
            } else {
                if (r == 15) {
                    k += 15;
                    continue;
                }
                d.eobrun = (@as(u32, 1) << @intCast(r)) - 1;
                if (r != 0) d.eobrun += br.bits(r);
                break;
            }
        }
    }

    fn decodeAcRefine(d: *Decoder, br: *BitReader, s: ScanParams, c: *Component, blk: *[64]i16) void {
        const p1: i32 = @as(i32, 1) << s.al;
        const m1: i32 = -p1;
        const se: usize = s.se;
        var k: usize = s.ss;
        if (d.eobrun == 0) {
            const ac = &d.ac_tables[c.ac_table];
            while (k <= se) : (k += 1) {
                const rs = br.decode(ac);
                var r: i32 = rs >> 4;
                var value: i32 = 0;
                if ((rs & 15) != 0) {
                    value = if (br.bits(1) != 0) p1 else m1;
                } else if (r != 15) {
                    d.eobrun = @as(u32, 1) << @intCast(r);
                    if (r != 0) d.eobrun += br.bits(@intCast(r));
                    break;
                }
                while (k <= se) : (k += 1) {
                    const coef = &blk[zigzag[k]];
                    if (coef.* != 0) {
                        refineBit(br, coef, p1, m1);
                    } else {
                        r -= 1;
                        if (r < 0) break;
                    }
                }
                if (value != 0) blk[natural(k)] = @truncate(value);
            }
        }
        if (d.eobrun > 0) {
            while (k <= se) : (k += 1) {
                const coef = &blk[zigzag[k]];
                if (coef.* != 0) refineBit(br, coef, p1, m1);
            }
            d.eobrun -= 1;
        }
    }

    // -----------------------------------------------------------------------
    // Pixels

    fn colorSpace(d: *const Decoder) ColorSpace {
        switch (d.ncomp) {
            1 => return .gray,
            3 => {
                if (d.saw_jfif) return .ycbcr;
                if (d.adobe_transform) |t| return if (t == 0) .rgb else .ycbcr;
                const c = d.comps;
                if (c[0].id == 'R' and c[1].id == 'G' and c[2].id == 'B') return .rgb;
                return .ycbcr;
            },
            else => {
                if (d.adobe_transform) |t| return if (t == 0) .cmyk else .ycck;
                return .cmyk;
            },
        }
    }

    fn output(d: *Decoder) Error!Image {
        const gpa = d.gpa;
        const w: usize = d.width;
        const h: usize = d.height;
        const n = d.ncomp;

        var kinds: [4]Upsample = undefined;
        for (d.comps[0..n], 0..) |c, i| {
            if (d.hmax % c.h != 0 or d.vmax % c.v != 0) return error.Unsupported;
            kinds[i] = Upsample.choose(d.hmax / c.h, d.vmax / c.v, c.cw);
        }

        var planes: [4][]u8 = @splat(&.{});
        defer for (planes[0..n]) |p| gpa.free(p);
        for (d.comps[0..n], 0..) |*c, i| {
            const stride = c.bw * 8;
            const nbx = ceilDiv(c.cw, 8);
            const nby = ceilDiv(c.ch, 8);
            planes[i] = try gpa.alloc(u8, stride * nby * 8);
            for (0..nby) |by| {
                for (0..nbx) |bx| {
                    const blk = c.coefs[(by * c.bw + bx) * 64 ..][0..64];
                    idctBlock(blk, &c.quant, planes[i][by * 8 * stride + bx * 8 ..], stride);
                }
            }
            // The coefficients are no longer needed; give the memory back early.
            gpa.free(c.coefs);
            c.coefs = &.{};
        }

        var rows: [4][]u8 = @splat(&.{});
        defer for (rows[0..n]) |r| gpa.free(r);
        for (d.comps[0..n], 0..) |c, i| {
            rows[i] = try gpa.alloc(u8, @max(w, 2 * c.cw) + 8);
        }

        const pixels = try gpa.alloc(u8, w * h * 4);
        errdefer gpa.free(pixels);
        const cs = d.colorSpace();
        const inverted = d.adobe_transform != null;
        var src: [4][]const u8 = undefined;
        for (0..h) |y| {
            for (d.comps[0..n], 0..) |*c, i| {
                src[i] = upsampleRow(c, planes[i], kinds[i], d.hmax / c.h, d.vmax / c.v, y, w, rows[i]);
            }
            convertRow(cs, inverted, src[0..n], pixels[y * w * 4 ..][0 .. w * 4]);
        }
        return .{
            .width = d.width,
            .height = d.height,
            .pixels = pixels,
        };
    }
};

fn ceilDiv(a: usize, b: usize) usize {
    return (a + b - 1) / b;
}

/// `v << al` stored in a 16-bit coefficient, wrapping like libjpeg's JCOEF.
inline fn shl(v: i32, al: u4) i16 {
    const u: u32 = @bitCast(v);
    return @truncate(@as(i32, @bitCast(u << al)));
}

inline fn refineBit(br: *BitReader, coef: *i16, p1: i32, m1: i32) void {
    if (br.bits(1) == 0) return;
    const cur: i32 = coef.*;
    if ((cur & p1) != 0) return;
    coef.* = @truncate(cur + (if (cur >= 0) p1 else m1));
}

// ---------------------------------------------------------------------------
// Inverse DCT: the accurate integer algorithm ("islow")

const const_bits = 13;
const pass1_bits = 2;

const fix_0_298631336: i32 = 2446;
const fix_0_390180644: i32 = 3196;
const fix_0_541196100: i32 = 4433;
const fix_0_765366865: i32 = 6270;
const fix_0_899976223: i32 = 7373;
const fix_1_175875602: i32 = 9633;
const fix_1_501321110: i32 = 12299;
const fix_1_847759065: i32 = 15137;
const fix_1_961570560: i32 = 16069;
const fix_2_053119869: i32 = 16819;
const fix_2_562915447: i32 = 20995;
const fix_3_072711026: i32 = 25172;

const V = @Vector(8, i32);

inline fn splat(x: i32) V {
    return @splat(x);
}

/// One 8-point pass of the islow IDCT, before descaling, run on eight lanes
/// at once (eight columns in the first pass, eight rows in the second).
/// Outputs are scaled by 2^const_bits relative to the inputs. Arithmetic
/// wraps like C on corrupt data instead of trapping.
inline fn idct8(s: [8]V) [8]V {
    // Even part.
    var z2 = s[2];
    var z3 = s[6];
    var z1 = (z2 +% z3) *% splat(fix_0_541196100);
    var tmp2 = z1 +% z3 *% splat(-fix_1_847759065);
    var tmp3 = z1 +% z2 *% splat(fix_0_765366865);
    z2 = s[0];
    z3 = s[4];
    var tmp0 = (z2 +% z3) *% splat(1 << const_bits);
    var tmp1 = (z2 -% z3) *% splat(1 << const_bits);
    const tmp10 = tmp0 +% tmp3;
    const tmp13 = tmp0 -% tmp3;
    const tmp11 = tmp1 +% tmp2;
    const tmp12 = tmp1 -% tmp2;

    // Odd part.
    tmp0 = s[7];
    tmp1 = s[5];
    tmp2 = s[3];
    tmp3 = s[1];
    z1 = tmp0 +% tmp3;
    z2 = tmp1 +% tmp2;
    z3 = tmp0 +% tmp2;
    var z4 = tmp1 +% tmp3;
    const z5 = (z3 +% z4) *% splat(fix_1_175875602);
    tmp0 = tmp0 *% splat(fix_0_298631336);
    tmp1 = tmp1 *% splat(fix_2_053119869);
    tmp2 = tmp2 *% splat(fix_3_072711026);
    tmp3 = tmp3 *% splat(fix_1_501321110);
    z1 = z1 *% splat(-fix_0_899976223);
    z2 = z2 *% splat(-fix_2_562915447);
    z3 = z3 *% splat(-fix_1_961570560);
    z4 = z4 *% splat(-fix_0_390180644);
    z3 +%= z5;
    z4 +%= z5;
    tmp0 +%= z1 +% z3;
    tmp1 +%= z2 +% z4;
    tmp2 +%= z2 +% z3;
    tmp3 +%= z1 +% z4;

    return .{
        tmp10 +% tmp3,
        tmp11 +% tmp2,
        tmp12 +% tmp1,
        tmp13 +% tmp0,
        tmp13 -% tmp0,
        tmp12 -% tmp1,
        tmp11 -% tmp2,
        tmp10 -% tmp3,
    };
}

/// libjpeg's post-IDCT range limit: the value is centred on 128 and masked to
/// 10 bits, so mild overshoot clamps and wild values wrap the same way
/// (0..127 -> 128..255, 128..511 -> 255, 512..895 -> 0, 896..1023 -> 0..127).
inline fn limitV(x: V) @Vector(8, u8) {
    const wrapped = ((x +% splat(512)) & splat(1023)) - splat(384);
    return @intCast(@max(@min(wrapped, splat(255)), splat(0)));
}

fn limit(x: i32) u8 {
    return limitV(splat(x))[0];
}

/// Dequantises and inverse-transforms one block into `out` (8 rows of `stride`).
/// The column pass's all-zero-AC shortcut in libjpeg gives the same values as
/// the full pass, so only the whole-block DC case is special-cased here.
fn idctBlock(blk: *const [64]i16, q: *const [64]u16, out: []u8, stride: usize) void {
    if (std.mem.allEqual(i16, blk[1..], 0)) {
        const dc = @as(i32, blk[0]) *% @as(i32, q[0]);
        const v = limit((dc *% (1 << pass1_bits) +% 16) >> (pass1_bits + 3));
        for (0..8) |r| @memset(out[r * stride ..][0..8], v);
        return;
    }
    // Pass 1: columns. Lane c of s[r] is coefficient (r, c).
    var s: [8]V = undefined;
    for (0..8) |r| {
        const c: @Vector(8, i16) = blk[r * 8 ..][0..8].*;
        const m: @Vector(8, u16) = q[r * 8 ..][0..8].*;
        s[r] = @as(V, c) *% @as(V, m);
    }
    const o1 = idct8(s);
    // Transpose: lane r of t[c] is work value (r, c).
    var ws: [8][8]i32 = undefined;
    for (0..8) |r| {
        const row: [8]i32 = (o1[r] +% splat(1 << (const_bits - pass1_bits - 1))) >> @splat(const_bits - pass1_bits);
        ws[r] = row;
    }
    var t: [8]V = undefined;
    for (0..8) |c| {
        var col: [8]i32 = undefined;
        for (0..8) |r| col[r] = ws[r][c];
        t[c] = col;
    }
    // Pass 2: rows. Lane r of o2[c] is output pixel (r, c).
    const o2 = idct8(t);
    var px: [8][8]u8 = undefined;
    for (0..8) |c| {
        const v: [8]u8 = limitV((o2[c] +% splat(1 << (const_bits + pass1_bits + 3 - 1))) >> @splat(const_bits + pass1_bits + 3));
        for (0..8) |r| px[r][c] = v[r];
    }
    for (0..8) |r| out[r * stride ..][0..8].* = px[r];
}

// ---------------------------------------------------------------------------
// Upsampling

const Upsample = enum {
    none,
    h2v1,
    h2v2,
    h1v2,
    replicate,

    /// libjpeg's choice: fancy (triangular) for h2v1 and h2v2 when the
    /// component is wider than 2 samples, and for h1v2; replication otherwise.
    fn choose(hr: usize, vr: usize, cw: usize) Upsample {
        if (hr == 1 and vr == 1) return .none;
        if (hr == 2 and vr == 1 and cw > 2) return .h2v1;
        if (hr == 2 and vr == 2 and cw > 2) return .h2v2;
        if (hr == 1 and vr == 2) return .h1v2;
        return .replicate;
    }
};

/// Output row `y` of a component at full resolution (`w` samples). Rows past
/// the component's real height repeat its last row, as libjpeg's context rows do.
fn upsampleRow(c: *const Component, plane: []const u8, kind: Upsample, hr: usize, vr: usize, y: usize, w: usize, buf: []u8) []const u8 {
    const stride = c.bw * 8;
    const cw = c.cw;
    const last_row = c.ch - 1;
    switch (kind) {
        .none => return plane[y * stride ..][0..w],
        .h2v1 => {
            h2v1Fancy(plane[y * stride ..][0..cw], buf[0 .. 2 * cw]);
            return buf[0..w];
        },
        .h2v2 => {
            const r = y / 2;
            const near = if (y % 2 == 0) (if (r == 0) 0 else r - 1) else @min(r + 1, last_row);
            h2v2Fancy(plane[r * stride ..][0..cw], plane[near * stride ..][0..cw], buf[0 .. 2 * cw]);
            return buf[0..w];
        },
        .h1v2 => {
            const r = y / 2;
            const upper = y % 2 == 0;
            const near = if (upper) (if (r == 0) 0 else r - 1) else @min(r + 1, last_row);
            h1v2Fancy(plane[r * stride ..][0..cw], plane[near * stride ..][0..cw], upper, buf[0..cw]);
            return buf[0..w];
        },
        .replicate => {
            const r = @min(y / vr, last_row);
            const src = plane[r * stride ..][0..cw];
            var x: usize = 0;
            for (src) |v| {
                const end = @min(x + hr, w);
                @memset(buf[x..end], v);
                x = end;
                if (x == w) break;
            }
            return buf[0..w];
        },
    }
}

/// Doubles a row horizontally with the 3:1 triangle filter (libjpeg h2v1).
/// Needs `in.len >= 2` and `out.len == 2 * in.len`.
fn h2v1Fancy(in: []const u8, out: []u8) void {
    const n = in.len;
    out[0] = in[0];
    out[1] = @intCast((@as(u32, in[0]) * 3 + in[1] + 2) >> 2);
    var i: usize = 1;
    while (i + 1 < n) : (i += 1) {
        const v = @as(u32, in[i]) * 3;
        out[2 * i] = @intCast((v + in[i - 1] + 1) >> 2);
        out[2 * i + 1] = @intCast((v + in[i + 1] + 2) >> 2);
    }
    out[2 * n - 2] = @intCast((@as(u32, in[n - 1]) * 3 + in[n - 2] + 1) >> 2);
    out[2 * n - 1] = in[n - 1];
}

/// One output row of libjpeg's h2v2 triangle filter: `in0` is the nearest
/// input row, `in1` the next nearest (above for even rows, below for odd).
fn h2v2Fancy(in0: []const u8, in1: []const u8, out: []u8) void {
    const n = in0.len;
    var this: u32 = @as(u32, in0[0]) * 3 + in1[0];
    var next: u32 = @as(u32, in0[1]) * 3 + in1[1];
    out[0] = @intCast((this * 4 + 8) >> 4);
    out[1] = @intCast((this * 3 + next + 7) >> 4);
    var last = this;
    this = next;
    var i: usize = 1;
    while (i + 1 < n) : (i += 1) {
        next = @as(u32, in0[i + 1]) * 3 + in1[i + 1];
        out[2 * i] = @intCast((this * 3 + last + 8) >> 4);
        out[2 * i + 1] = @intCast((this * 3 + next + 7) >> 4);
        last = this;
        this = next;
    }
    out[2 * n - 2] = @intCast((this * 3 + last + 8) >> 4);
    out[2 * n - 1] = @intCast((this * 4 + 7) >> 4);
}

/// One output row of libjpeg-turbo's h1v2 triangle filter.
fn h1v2Fancy(in0: []const u8, in1: []const u8, upper: bool, out: []u8) void {
    const bias: u32 = if (upper) 1 else 2;
    for (in0, in1, out) |a, b, *o| o.* = @intCast((@as(u32, a) * 3 + b + bias) >> 2);
}

// ---------------------------------------------------------------------------
// Colour conversion

/// libjpeg's YCbCr to RGB tables: 16-bit fixed point, ONE_HALF rounding.
const ycc_tables = blk: {
    const one_half: i32 = 1 << 15;
    var t: struct {
        cr_r: [256]i32,
        cb_b: [256]i32,
        cr_g: [256]i32,
        cb_g: [256]i32,
    } = undefined;
    for (0..256) |i| {
        const x: i32 = @as(i32, i) - 128;
        t.cr_r[i] = (91881 * x + one_half) >> 16; // FIX(1.40200)
        t.cb_b[i] = (116130 * x + one_half) >> 16; // FIX(1.77200)
        t.cr_g[i] = -46802 * x; // -FIX(0.71414)
        t.cb_g[i] = -22554 * x + one_half; // -FIX(0.34414)
    }
    break :blk t;
};

inline fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// YCbCr to RGB exactly as libjpeg's ycc_rgb_convert.
inline fn yccToRgb(y: u8, cb: u8, cr: u8) [3]u8 {
    const yy: i32 = y;
    return .{
        clamp8(yy + ycc_tables.cr_r[cr]),
        clamp8(yy + ((ycc_tables.cb_g[cb] + ycc_tables.cr_g[cr]) >> 16)),
        clamp8(yy + ycc_tables.cb_b[cb]),
    };
}

/// round(a * b / 255).
inline fn mulDiv255(a: u8, b: u8) u8 {
    const x: u32 = @as(u32, a) * b + 128;
    return @intCast((x + (x >> 8)) >> 8);
}

/// CMYK as stored to RGB. Adobe files store inverted CMYK (255 = no ink), the
/// convention browsers assume; files without APP14 store plain ink values.
inline fn cmykToRgb(c: u8, m: u8, y: u8, k: u8, inverted: bool) [3]u8 {
    if (inverted) return .{ mulDiv255(c, k), mulDiv255(m, k), mulDiv255(y, k) };
    return .{ mulDiv255(255 - c, 255 - k), mulDiv255(255 - m, 255 - k), mulDiv255(255 - y, 255 - k) };
}

fn convertRow(cs: ColorSpace, inverted: bool, src: []const []const u8, out: []u8) void {
    const w = out.len / 4;
    switch (cs) {
        .gray => for (src[0][0..w], 0..) |v, x| {
            out[x * 4 ..][0..4].* = .{ v, v, v, 255 };
        },
        .ycbcr => for (src[0][0..w], src[1][0..w], src[2][0..w], 0..) |y, cb, cr, x| {
            const rgb = yccToRgb(y, cb, cr);
            out[x * 4 ..][0..4].* = .{ rgb[0], rgb[1], rgb[2], 255 };
        },
        .rgb => for (src[0][0..w], src[1][0..w], src[2][0..w], 0..) |r, g, b, x| {
            out[x * 4 ..][0..4].* = .{ r, g, b, 255 };
        },
        .cmyk, .ycck => {
            for (0..w) |x| {
                var c = src[0][x];
                var m = src[1][x];
                var y = src[2][x];
                const k = src[3][x];
                if (cs == .ycck) {
                    // libjpeg's ycck_cmyk_convert: YCC to RGB, then C = 255 - R ...
                    const rgb = yccToRgb(c, m, y);
                    c = 255 - rgb[0];
                    m = 255 - rgb[1];
                    y = 255 - rgb[2];
                }
                const rgb = cmykToRgb(c, m, y, k, inverted);
                out[x * 4 ..][0..4].* = .{ rgb[0], rgb[1], rgb[2], 255 };
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// The textbook float IDCT, rounded and clamped, for comparison.
fn referenceIdct(coefs: *const [64]i16, out: *[64]u8) void {
    for (0..8) |y| {
        for (0..8) |x| {
            var sum: f64 = 0;
            for (0..8) |v| {
                for (0..8) |u| {
                    const cu: f64 = if (u == 0) std.math.sqrt1_2 else 1;
                    const cv: f64 = if (v == 0) std.math.sqrt1_2 else 1;
                    const fx: f64 = @floatFromInt(2 * x + 1);
                    const fy: f64 = @floatFromInt(2 * y + 1);
                    const fu: f64 = @floatFromInt(u);
                    const fv: f64 = @floatFromInt(v);
                    sum += cu * cv * @as(f64, @floatFromInt(coefs[v * 8 + u])) *
                        @cos(fx * fu * std.math.pi / 16) * @cos(fy * fv * std.math.pi / 16);
                }
            }
            const value = @round(sum / 4 + 128);
            out[y * 8 + x] = @intFromFloat(std.math.clamp(value, 0, 255));
        }
    }
}

test "islow IDCT matches the float IDCT within 1" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    const ones: [64]u16 = @splat(1);
    var worst: u32 = 0;
    for (0..500) |round| {
        var blk: [64]i16 = @splat(0);
        // Mostly low frequencies, like real images; every tenth block is dense.
        const dense = round % 10 == 0;
        for (&blk, 0..) |*c, i| {
            const keep = dense or i < 10 or random.uintLessThan(u8, 8) == 0;
            if (keep) c.* = random.intRangeAtMost(i16, -120, 120);
        }
        blk[0] = random.intRangeAtMost(i16, -900, 900);
        var got: [64]u8 = undefined;
        var want: [64]u8 = undefined;
        idctBlock(&blk, &ones, &got, 8);
        referenceIdct(&blk, &want);
        for (got, want) |g, w| worst = @max(worst, @abs(@as(i32, g) - w));
    }
    try testing.expect(worst <= 1);
}

test "IDCT of a DC-only block and dequantisation" {
    var blk: [64]i16 = @splat(0);
    blk[0] = 4;
    var q: [64]u16 = @splat(1);
    q[0] = 16;
    var out: [64]u8 = undefined;
    idctBlock(&blk, &q, &out, 8);
    // 4 * 16 / 8 = 8 above mid grey.
    for (out) |v| try testing.expectEqual(@as(u8, 136), v);
    blk[0] = -100;
    idctBlock(&blk, &q, &out, 8);
    for (out) |v| try testing.expectEqual(@as(u8, 0), v);
}

test "range limit clamps overshoot and wraps like libjpeg" {
    try testing.expectEqual(@as(u8, 128), limit(0));
    try testing.expectEqual(@as(u8, 255), limit(127));
    try testing.expectEqual(@as(u8, 255), limit(300));
    try testing.expectEqual(@as(u8, 0), limit(-129));
    try testing.expectEqual(@as(u8, 0), limit(-500));
    try testing.expectEqual(@as(u8, 127), limit(-1));
}

test "h2v1 fancy upsampling" {
    const in = [_]u8{ 10, 20, 30 };
    var out: [6]u8 = undefined;
    h2v1Fancy(&in, &out);
    try testing.expectEqualSlices(u8, &.{ 10, 13, 17, 23, 27, 30 }, &out);
}

test "h2v2 fancy upsampling" {
    const near = [_]u8{ 100, 100, 100, 100 };
    const far = [_]u8{ 0, 0, 0, 0 };
    var out: [8]u8 = undefined;
    // colsum = 300 everywhere: (1200 + 8) >> 4 = 75, (1200 + 7) >> 4 = 75.
    h2v2Fancy(&near, &far, &out);
    for (out) |v| try testing.expectEqual(@as(u8, 75), v);
    const ramp = [_]u8{ 0, 16, 32, 48 };
    h2v2Fancy(&ramp, &ramp, &out);
    try testing.expectEqualSlices(u8, &.{ 0, 4, 12, 20, 28, 36, 44, 48 }, &out);
}

test "h1v2 fancy upsampling" {
    const a = [_]u8{ 100, 0 };
    const b = [_]u8{ 0, 100 };
    var out: [2]u8 = undefined;
    h1v2Fancy(&a, &b, true, &out);
    try testing.expectEqualSlices(u8, &.{ 75, 25 }, &out);
    h1v2Fancy(&a, &b, false, &out);
    try testing.expectEqualSlices(u8, &.{ 75, 25 }, &out);
}

test "upsampler choice follows libjpeg" {
    try testing.expectEqual(Upsample.none, Upsample.choose(1, 1, 10));
    try testing.expectEqual(Upsample.h2v1, Upsample.choose(2, 1, 10));
    try testing.expectEqual(Upsample.h2v2, Upsample.choose(2, 2, 10));
    try testing.expectEqual(Upsample.replicate, Upsample.choose(2, 2, 2));
    try testing.expectEqual(Upsample.h1v2, Upsample.choose(1, 2, 1));
    try testing.expectEqual(Upsample.replicate, Upsample.choose(4, 1, 10));
}

test "YCbCr to RGB uses libjpeg's fixed-point rounding" {
    try testing.expectEqual([3]u8{ 128, 128, 128 }, yccToRgb(128, 128, 128));
    try testing.expectEqual([3]u8{ 255, 255, 255 }, yccToRgb(255, 128, 128));
    try testing.expectEqual([3]u8{ 201, 49, 100 }, yccToRgb(100, 128, 200));
    // Pure red as encoded by libjpeg's forward transform (76, 85, 255).
    try testing.expectEqual([3]u8{ 254, 0, 0 }, yccToRgb(76, 85, 255));
}

test "CMYK to RGB" {
    try testing.expectEqual([3]u8{ 255, 255, 255 }, cmykToRgb(255, 255, 255, 255, true));
    try testing.expectEqual([3]u8{ 0, 0, 0 }, cmykToRgb(255, 255, 255, 0, true));
    try testing.expectEqual([3]u8{ 255, 255, 255 }, cmykToRgb(0, 0, 0, 0, false));
    try testing.expectEqual([3]u8{ 64, 128, 255 }, cmykToRgb(64, 128, 255, 255, true));
}

test "Huffman table: canonical codes decode, over-subscribed tables are rejected" {
    // The standard luminance DC table (JPEG spec Annex K.3).
    const counts = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
    const symbols = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const t = try HuffTable.build(&counts, &symbols);
    // "00" "011" "1110" "111111110" -> 0, 2, 6, 11, then padding 1s.
    // 0001 1111 0111 1111 10 + 111111
    const data = [_]u8{ 0b0001_1111, 0b0111_1111, 0b1011_1111 };
    var br: BitReader = .{
        .data = &data,
        .pos = 0,
    };
    try testing.expectEqual(@as(u8, 0), br.decode(&t));
    try testing.expectEqual(@as(u8, 2), br.decode(&t));
    try testing.expectEqual(@as(u8, 6), br.decode(&t));
    try testing.expectEqual(@as(u8, 11), br.decode(&t));
    try testing.expect(!br.insufficient);

    const bad = [16]u8{ 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.InvalidJpeg, HuffTable.build(&bad, &.{ 1, 2, 3 }));
    // Two one-bit codes would use the all-ones code, which JPEG forbids.
    const full = [16]u8{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.InvalidJpeg, HuffTable.build(&full, &.{ 1, 2 }));
}

test "bit reader unstuffs 0xFF00 and pads with zeros at a marker" {
    const data = [_]u8{ 0xFF, 0x00, 0xA5, 0xFF, 0xD9 };
    var br: BitReader = .{
        .data = &data,
        .pos = 0,
    };
    try testing.expectEqual(@as(u32, 0xFF), br.bits(8));
    try testing.expectEqual(@as(u32, 0xA5), br.bits(8));
    try testing.expect(!br.insufficient);
    try testing.expectEqual(@as(u32, 0), br.bits(8));
    try testing.expect(br.insufficient);
    try testing.expectEqual(@as(usize, 3), br.pos);
}

test "EXTEND sign-extends magnitudes" {
    const data = [_]u8{ 0b0111_1000, 0b1000_0000 };
    var br: BitReader = .{
        .data = &data,
        .pos = 0,
    };
    try testing.expectEqual(@as(i32, -8), br.receiveExtend(4)); // 0111
    try testing.expectEqual(@as(i32, 8), br.receiveExtend(4)); // 1000
    try testing.expectEqual(@as(i32, 1), br.receiveExtend(1));
}

/// A 16x8 grayscale baseline JPEG with a restart marker between its two
/// blocks; each block's DC difference is +8, so both decode to 129.
const tiny_gray = blk: {
    const head = [_]u8{
        0xFF, 0xD8,
        // DQT, table 0, all ones.
        0xFF, 0xDB,
        0x00, 0x43,
        0x00,
    } ++ [_]u8{1} ** 64 ++ [_]u8{
        // SOF0: 8-bit, 8 high, 16 wide, one component 1x1 using table 0.
        0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x08, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00,
        // DHT DC 0: one 1-bit code "0" for magnitude 4.
        0xFF, 0xC4, 0x00, 0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04,
        // DHT AC 0: one 1-bit code "0" for end of block.
        0xFF, 0xC4, 0x00, 0x14,
        0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
        // DRI: restart every MCU.
        0xFF, 0xDD, 0x00, 0x04, 0x00, 0x01,
        // SOS: one component, tables 0/0, Ss 0, Se 63, Ah/Al 0.
        0xFF, 0xDA,
        0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
        // "0" "1000" "0" + padding, RST0, the same again, EOI.
        0x43, 0xFF, 0xD0, 0x43, 0xFF,
        0xD9,
    };
    break :blk head;
};

test "decode a hand-built baseline JPEG with a restart interval" {
    const meta = try info(&tiny_gray);
    try testing.expectEqual(@as(u32, 16), meta.width);
    try testing.expectEqual(@as(u32, 8), meta.height);
    try testing.expectEqual(@as(u8, 1), meta.components);
    try testing.expect(!meta.progressive);
    try testing.expectEqual(@as(u8, 1), meta.exif_orientation);

    var img = try decode(testing.allocator, &tiny_gray);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 16 * 8 * 4), img.pixels.len);
    for (0..16 * 8) |i| {
        try testing.expectEqualSlices(u8, &.{ 129, 129, 129, 255 }, img.pixels[i * 4 ..][0..4]);
    }
}

test "corrupt and truncated input returns errors or partial images, never panics" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidJpeg, decode(gpa, ""));
    try testing.expectError(error.InvalidJpeg, decode(gpa, "GIF89a"));
    try testing.expectError(error.Truncated, decode(gpa, &.{ 0xFF, 0xD8 }));
    try testing.expectError(error.Truncated, info(&.{ 0xFF, 0xD8, 0xFF }));
    for (0..tiny_gray.len) |n| {
        if (decode(gpa, tiny_gray[0..n])) |img| {
            var copy = img;
            copy.deinit(gpa);
        } else |_| {}
    }
    var buf = tiny_gray;
    for (0..buf.len) |i| {
        for ([_]u8{ 0x00, 0xFF, 0x11, 0x80 }) |v| {
            const saved = buf[i];
            buf[i] = v;
            if (decode(gpa, &buf)) |img| {
                var copy = img;
                copy.deinit(gpa);
            } else |_| {}
            _ = info(&buf) catch {};
            buf[i] = saved;
        }
    }
}

const corpus_dir = "/Users/dawid/Documents/publrv2/publr-design/engine/corpus/landing/images";

test "corpus: every landing JPEG decodes at the size info() reports" {
    const io = testing.io;
    const gpa = testing.allocator;
    var dir = std.Io.Dir.openDirAbsolute(io, corpus_dir, .{
        .iterate = true,
    }) catch return error.SkipZigTest;
    defer dir.close(io);
    var it = dir.iterate();
    var count: usize = 0;
    var smallest: ?[]u8 = null;
    defer if (smallest) |s| gpa.free(s);
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, gpa, .limited(64 << 20));
        var keep = false;
        defer if (!keep) gpa.free(bytes);
        if (bytes.len < 3 or bytes[0] != 0xFF or bytes[1] != 0xD8) continue;
        const meta = try info(bytes);
        try testing.expect(meta.progressive);
        try testing.expect(meta.has_icc);
        var img = try decode(gpa, bytes);
        defer img.deinit(gpa);
        try testing.expectEqual(meta.width, img.width);
        try testing.expectEqual(meta.height, img.height);
        try testing.expectEqual(@as(usize, meta.width) * meta.height * 4, img.pixels.len);
        count += 1;
        if (smallest == null or bytes.len < smallest.?.len) {
            if (smallest) |s| gpa.free(s);
            smallest = bytes;
            keep = true;
        }
    }
    try testing.expect(count > 0);

    // A truncated progressive file still decodes, as far as its data goes.
    const full = smallest.?;
    const meta = try info(full);
    for ([_]usize{ 2, 3, 5 }) |part| {
        var img = try decode(gpa, full[0 .. full.len * part / 6]);
        defer img.deinit(gpa);
        try testing.expectEqual(meta.width, img.width);
    }
}
