//! Web font containers: WOFF 1.0 and WOFF 2.0 files turned back into plain sfnt
//! (TrueType or CFF-flavored OpenType) bytes that `font.Font.parse` reads.
//!
//! WOFF 1.0 keeps each table, zlib-compressed or stored. WOFF 2.0 compresses all tables
//! in one Brotli stream and may transform `glyf`/`loca` (section 5.1-5.3) and `hmtx`
//! (section 5.4); those are rebuilt here. Of a collection (flavor 'ttcf') the first font
//! is returned, as a single font. CFF tables are copied as they are.

const std = @import("std");
const brotli = @import("../codec/brotli.zig");

/// Why a file did not convert.
pub const Error = error{
    /// Not a WOFF file, or one that breaks the format.
    InvalidFont,
    OutOfMemory,
};

/// True when `bytes` start like a WOFF 1.0 or WOFF 2.0 file.
pub fn isWoff(bytes: []const u8) bool {
    return bytes.len >= 4 and (std.mem.eql(u8, bytes[0..4], "wOFF") or std.mem.eql(u8, bytes[0..4], "wOF2"));
}

/// Converts a WOFF 1.0 or WOFF 2.0 file into sfnt bytes owned by the caller.
pub fn toSfnt(gpa: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    if (bytes.len < 4) return error.InvalidFont;
    if (std.mem.eql(u8, bytes[0..4], "wOFF")) return woff1(gpa, bytes);
    if (std.mem.eql(u8, bytes[0..4], "wOF2")) return woff2(gpa, bytes);
    return error.InvalidFont;
}

/// One table of the sfnt being written.
const Table = struct {
    tag: [4]u8,
    data: []const u8,
};

// WOFF 1.0 ----------------------------------------------------------------------------

fn woff1(gpa: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    if (bytes.len < 44) return error.InvalidFont;
    const flavor = be32(bytes, 4);
    const num_tables: usize = be16(bytes, 12);
    if (num_tables == 0 or 44 + num_tables * 20 > bytes.len) return error.InvalidFont;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tables = try arena.alloc(Table, num_tables);
    for (tables, 0..) |*t, k| {
        const rec = 44 + k * 20;
        const offset: usize = be32(bytes, rec + 4);
        const comp_len: usize = be32(bytes, rec + 8);
        const orig_len: usize = be32(bytes, rec + 12);
        if (offset > bytes.len or comp_len > bytes.len - offset or comp_len > orig_len) return error.InvalidFont;
        const src = bytes[offset..][0..comp_len];
        t.tag = bytes[rec..][0..4].*;
        if (comp_len == orig_len) {
            t.data = src;
        } else {
            const out = try arena.alloc(u8, orig_len);
            try inflate(src, out);
            t.data = out;
        }
    }
    return writeSfnt(gpa, flavor, tables);
}

/// Inflates the zlib stream `src` into exactly `out.len` bytes.
fn inflate(src: []const u8, out: []u8) Error!void {
    var in: std.Io.Reader = .fixed(src);
    var zlib: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    var w: std.Io.Writer = .fixed(out);
    var stalls: u8 = 0;
    while (w.end < out.len) {
        const n = zlib.reader.stream(&w, .limited(out.len - w.end)) catch return error.InvalidFont;
        // The decompressor returns 0 while crossing block boundaries; a stream that keeps
        // returning 0 has ended early.
        stalls = if (n == 0) stalls + 1 else 0;
        if (stalls > 2) return error.InvalidFont;
    }
}

// WOFF 2.0 ----------------------------------------------------------------------------

/// The "known table tags" of the WOFF 2.0 table directory (section 4.1).
const known_tags = [63]*const [4]u8{
    "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post",
    "cvt ", "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT",
    "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea",
    "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH",
    "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt", "avar",
    "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar",
    "gvar", "hsty", "just", "lcar", "mort", "morx", "opbd", "prop",
    "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill",
};

/// A WOFF 2.0 table directory entry.
const Entry = struct {
    tag: [4]u8,
    /// Whether a non-null transform was applied.
    transformed: bool,
    orig_len: u32,
    /// Its length in the decompressed stream.
    len: u32,
    /// The table's bytes in the decompressed stream.
    data: []const u8 = &.{},
};

fn woff2(gpa: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    if (bytes.len < 48) return error.InvalidFont;
    var flavor = be32(bytes, 4);
    const num_tables: usize = be16(bytes, 12);
    const compressed_len: usize = be32(bytes, 20);
    if (num_tables == 0) return error.InvalidFont;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var r: Reader = .{
        .data = bytes,
        .pos = 48,
    };
    const entries = try arena.alloc(Entry, num_tables);
    var stream_len: usize = 0;
    for (entries) |*e| {
        const flags = try r.byte();
        const known = flags & 0x3f;
        const tag: [4]u8 = if (known == 63) (try r.take(4))[0..4].* else known_tags[known].*;
        const version = flags >> 6;
        const orig_len = try r.base128();
        const is_glyf_loca = std.mem.eql(u8, &tag, "glyf") or std.mem.eql(u8, &tag, "loca");
        const transformed = if (is_glyf_loca) version != 3 else version != 0;
        // Only glyf/loca version 0 and hmtx version 1 are defined transforms.
        if (transformed and !(is_glyf_loca and version == 0) and !(std.mem.eql(u8, &tag, "hmtx") and version == 1)) return error.InvalidFont;
        const len = if (transformed) try r.base128() else orig_len;
        if (std.mem.eql(u8, &tag, "loca") and transformed and len != 0) return error.InvalidFont;
        e.* = .{
            .tag = tag,
            .transformed = transformed,
            .orig_len = orig_len,
            .len = len,
        };
        stream_len += len;
    }

    // Of a collection, the first font's tables.
    var chosen = try arena.alloc(usize, num_tables);
    for (chosen, 0..) |*c, k| c.* = k;
    if (flavor == tag32("ttcf")) {
        _ = try r.take(4); // TTC version
        const num_fonts = try r.ushort255();
        if (num_fonts == 0) return error.InvalidFont;
        for (0..num_fonts) |f| {
            const n = try r.ushort255();
            const font_flavor = try r.u32be();
            const list = try arena.alloc(usize, n);
            for (list) |*idx| {
                idx.* = try r.ushort255();
                if (idx.* >= num_tables) return error.InvalidFont;
            }
            if (f == 0) {
                flavor = font_flavor;
                chosen = list;
            }
        }
    }

    const compressed = try r.take(compressed_len);
    const stream = brotli.decompress(gpa, compressed, stream_len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFont,
    };
    defer gpa.free(stream);
    if (stream.len != stream_len) return error.InvalidFont;
    var at: usize = 0;
    for (entries) |*e| {
        e.data = stream[at..][0..e.len];
        at += e.len;
    }

    var tables: std.ArrayList(Table) = .empty;
    var glyf: ?usize = null;
    var loca: ?usize = null;
    var hmtx: ?usize = null;
    var head: ?usize = null;
    for (chosen) |idx| {
        const e = entries[idx];
        if (std.mem.eql(u8, &e.tag, "DSIG")) continue;
        try tables.append(arena, .{
            .tag = e.tag,
            .data = e.data,
        });
        const slot = tables.items.len - 1;
        if (std.mem.eql(u8, &e.tag, "glyf")) glyf = slot;
        if (std.mem.eql(u8, &e.tag, "loca")) loca = slot;
        if (std.mem.eql(u8, &e.tag, "hmtx")) hmtx = slot;
        if (std.mem.eql(u8, &e.tag, "head")) head = slot;
    }
    const entryOf = struct {
        fn f(es: []const Entry, ch: []const usize, tag: []const u8) ?Entry {
            for (ch) |idx| if (std.mem.eql(u8, &es[idx].tag, tag)) return es[idx];
            return null;
        }
    }.f;

    if (glyf) |g| {
        const ge = entryOf(entries, chosen, "glyf").?;
        const l = loca orelse return error.InvalidFont;
        const le = entryOf(entries, chosen, "loca").?;
        if (ge.transformed != le.transformed) return error.InvalidFont;
        if (ge.transformed) {
            const rebuilt = try rebuildGlyf(arena, ge.data);
            const per: u32 = if (rebuilt.index_format == 0) 2 else 4;
            if (le.orig_len != (@as(u32, rebuilt.num_glyphs) + 1) * per) return error.InvalidFont;
            tables.items[g].data = rebuilt.glyf;
            tables.items[l].data = rebuilt.loca;
            if (rebuilt.long_loca_forced) {
                // The rebuilt glyphs outgrew short offsets: say so in head.
                const h = head orelse return error.InvalidFont;
                if (tables.items[h].data.len < 54) return error.InvalidFont;
                const copy = try arena.dupe(u8, tables.items[h].data);
                copy[50] = 0;
                copy[51] = 1;
                tables.items[h].data = copy;
            }
        }
    } else if (loca != null) return error.InvalidFont;

    if (hmtx) |h| {
        const he = entryOf(entries, chosen, "hmtx").?;
        if (he.transformed) tables.items[h].data = try rebuildHmtx(arena, tables.items, he.data);
    }
    return writeSfnt(gpa, flavor, tables.items);
}

/// A rebuilt `glyf` table and its `loca`.
const Glyf = struct {
    glyf: []const u8,
    loca: []const u8,
    num_glyphs: u16,
    /// indexFormat from the transformed table.
    index_format: u16,
    /// True when short offsets could not hold the rebuilt table and `loca` is long.
    long_loca_forced: bool,
};

/// Rebuilds `glyf` and `loca` from the transformed `glyf` (WOFF 2.0 section 5.1).
fn rebuildGlyf(arena: std.mem.Allocator, data: []const u8) Error!Glyf {
    if (data.len < 36) return error.InvalidFont;
    const option_flags = be16(data, 2);
    const num_glyphs = be16(data, 4);
    const index_format = be16(data, 6);
    var at: usize = 36;
    var streams: [7]Reader = undefined;
    for (&streams, 0..) |*s, k| {
        const len: usize = be32(data, 8 + 4 * k);
        if (len > data.len - at) return error.InvalidFont;
        s.* = .{
            .data = data[at..][0..len],
        };
        at += len;
    }
    var n_contours = streams[0];
    var n_points = streams[1];
    var flag_stream = streams[2];
    var glyph_stream = streams[3];
    var composite_stream = streams[4];
    var bbox_stream = streams[5];
    var instructions = streams[6];
    const bitmap_len = 4 * ((@as(usize, num_glyphs) + 31) / 32);
    const bbox_bitmap = try bbox_stream.take(bitmap_len);
    var overlap_bitmap: []const u8 = &.{};
    if (option_flags & 1 != 0) {
        const len = (@as(usize, num_glyphs) + 7) / 8;
        if (len > data.len - at) return error.InvalidFont;
        overlap_bitmap = data[at..][0..len];
    }

    var out: std.ArrayList(u8) = .empty;
    const offsets = try arena.alloc(u32, @as(usize, num_glyphs) + 1);
    var points: std.ArrayList(Point) = .empty;
    var flags: std.ArrayList(u8) = .empty;
    var coords: std.ArrayList(u8) = .empty;

    for (0..num_glyphs) |i| {
        offsets[i] = @intCast(out.items.len);
        const has_bbox = bitSet(bbox_bitmap, i);
        const nc = try n_contours.i16be();
        if (nc == 0) {
            if (has_bbox) return error.InvalidFont;
            continue;
        }
        const start = out.items.len;
        if (nc > 0) {
            // A simple glyph.
            const ncu: usize = @intCast(nc);
            try out.appendNTimes(arena, 0, 10 + 2 * ncu);
            put16(out.items, start, @bitCast(nc));
            var total: u32 = 0;
            for (0..ncu) |k| {
                const n = try n_points.ushort255();
                if (n == 0) return error.InvalidFont;
                total += n;
                if (total > 65536) return error.InvalidFont;
                put16(out.items, start + 10 + 2 * k, @intCast(total - 1));
            }
            points.clearRetainingCapacity();
            var x: i32 = 0;
            var y: i32 = 0;
            for (0..total) |_| {
                const f = try flag_stream.byte();
                const d = try triplet(f, &glyph_stream);
                x += d.dx;
                y += d.dy;
                if (x < -32768 or x > 32767 or y < -32768 or y > 32767) return error.InvalidFont;
                try points.append(arena, .{
                    .x = x,
                    .y = y,
                    .on = f & 0x80 == 0,
                });
            }
            const ins_len = try glyph_stream.ushort255();
            const ins = try instructions.take(ins_len);
            try out.appendSlice(arena, &.{ @intCast(ins_len >> 8), @truncate(ins_len) });
            try out.appendSlice(arena, ins);

            // The bounding box: explicit, else from all points.
            var box: [4]i16 = undefined;
            if (has_bbox) {
                for (&box) |*b| b.* = try bbox_stream.i16be();
            } else {
                var x0: i32 = points.items[0].x;
                var y0: i32 = points.items[0].y;
                var x1 = x0;
                var y1 = y0;
                for (points.items) |p| {
                    x0 = @min(x0, p.x);
                    y0 = @min(y0, p.y);
                    x1 = @max(x1, p.x);
                    y1 = @max(y1, p.y);
                }
                box = .{ @intCast(x0), @intCast(y0), @intCast(x1), @intCast(y1) };
            }
            for (box, 0..) |b, k| put16(out.items, start + 2 + 2 * k, @bitCast(b));

            try encodePoints(arena, points.items, bitSet(overlap_bitmap, i), &flags, &coords);
            try out.appendSlice(arena, flags.items);
            try out.appendSlice(arena, coords.items);
        } else if (nc == -1) {
            // A composite glyph: its bounding box is always explicit.
            if (!has_bbox) return error.InvalidFont;
            try out.appendNTimes(arena, 0, 10);
            put16(out.items, start, 0xffff);
            for (0..4) |k| put16(out.items, start + 2 + 2 * k, @bitCast(try bbox_stream.i16be()));
            var have_instructions = false;
            while (true) {
                const head = try composite_stream.take(2);
                const cf = be16(head, 0);
                var n: usize = 2 + @as(usize, if (cf & 0x0001 != 0) 4 else 2);
                if (cf & 0x0008 != 0) {
                    n += 2;
                } else if (cf & 0x0040 != 0) {
                    n += 4;
                } else if (cf & 0x0080 != 0) {
                    n += 8;
                }
                try out.appendSlice(arena, head);
                try out.appendSlice(arena, try composite_stream.take(n));
                if (cf & 0x0100 != 0) have_instructions = true;
                if (cf & 0x0020 == 0) break;
            }
            if (have_instructions) {
                const ins_len = try glyph_stream.ushort255();
                try out.appendSlice(arena, &.{ @intCast(ins_len >> 8), @truncate(ins_len) });
                try out.appendSlice(arena, try instructions.take(ins_len));
            }
        } else return error.InvalidFont;
        // Glyphs start on 4-byte boundaries.
        while (out.items.len % 4 != 0) try out.append(arena, 0);
    }
    offsets[num_glyphs] = @intCast(out.items.len);

    const long = index_format != 0 or out.items.len / 2 > 0xffff;
    const loca = try arena.alloc(u8, (@as(usize, num_glyphs) + 1) * @as(usize, if (long) 4 else 2));
    for (offsets, 0..) |o, k| {
        if (long) {
            std.mem.writeInt(u32, loca[4 * k ..][0..4], o, .big);
        } else {
            put16(loca, 2 * k, @intCast(o / 2));
        }
    }
    return .{
        .glyf = out.items,
        .loca = loca,
        .num_glyphs = num_glyphs,
        .index_format = index_format,
        .long_loca_forced = long and index_format == 0,
    };
}

const Point = struct {
    x: i32,
    y: i32,
    on: bool,
};

/// Writes TrueType simple-glyph flags and coordinates (deltas, short where they fit,
/// runs of equal flags repeated).
fn encodePoints(arena: std.mem.Allocator, pts: []const Point, overlap: bool, flags: *std.ArrayList(u8), coords: *std.ArrayList(u8)) Error!void {
    flags.clearRetainingCapacity();
    coords.clearRetainingCapacity();
    const raw = try arena.alloc(u8, pts.len);
    defer arena.free(raw);
    var xs: std.ArrayList(u8) = .empty;
    var ys: std.ArrayList(u8) = .empty;
    var px: i32 = 0;
    var py: i32 = 0;
    for (pts, 0..) |p, k| {
        var f: u8 = if (p.on) 0x01 else 0;
        if (k == 0 and overlap) f |= 0x40;
        const dx = p.x - px;
        const dy = p.y - py;
        px = p.x;
        py = p.y;
        if (dx == 0) {
            f |= 0x10;
        } else if (@abs(dx) <= 255) {
            f |= 0x02;
            if (dx > 0) f |= 0x10;
            try xs.append(arena, @intCast(@abs(dx)));
        } else {
            const v: i16 = @intCast(dx);
            try xs.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(i16, v)));
        }
        if (dy == 0) {
            f |= 0x20;
        } else if (@abs(dy) <= 255) {
            f |= 0x04;
            if (dy > 0) f |= 0x20;
            try ys.append(arena, @intCast(@abs(dy)));
        } else {
            const v: i16 = @intCast(dy);
            try ys.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(i16, v)));
        }
        raw[k] = f;
    }
    var k: usize = 0;
    while (k < raw.len) {
        var run: usize = 1;
        while (k + run < raw.len and raw[k + run] == raw[k] and run < 256) run += 1;
        if (run > 1) {
            try flags.appendSlice(arena, &.{ raw[k] | 0x08, @intCast(run - 1) });
        } else {
            try flags.append(arena, raw[k]);
        }
        k += run;
    }
    try coords.appendSlice(arena, xs.items);
    try coords.appendSlice(arena, ys.items);
}

const Delta = struct {
    dx: i32,
    dy: i32,
};

/// Decodes one point's coordinate deltas for WOFF 2.0 flag `flag` (section 5.2),
/// reading its bytes from `r`.
fn triplet(flag: u8, r: *Reader) Error!Delta {
    const f = flag & 0x7f;
    var dx: i32 = 0;
    var dy: i32 = 0;
    var g: u8 = undefined;
    if (f < 10) {
        dy = (@as(i32, f & 14) << 7) + try r.byte();
        if (f & 1 == 0) dy = -dy;
        return .{
            .dx = 0,
            .dy = dy,
        };
    } else if (f < 20) {
        const h = f - 10;
        dx = (@as(i32, h & 14) << 7) + try r.byte();
        if (h & 1 == 0) dx = -dx;
        return .{
            .dx = dx,
            .dy = 0,
        };
    } else if (f < 84) {
        g = f - 20;
        const b = try r.byte();
        dx = 1 + @as(i32, g & 0x30) + (b >> 4);
        dy = 1 + (@as(i32, g & 0x0c) << 2) + (b & 15);
    } else if (f < 120) {
        g = f - 84;
        const b = try r.take(2);
        dx = 1 + 256 * @as(i32, g / 12) + b[0];
        dy = 1 + 256 * @as(i32, (g % 12) >> 2) + b[1];
    } else if (f < 124) {
        g = f - 120;
        const b = try r.take(3);
        dx = (@as(i32, b[0]) << 4) | (b[1] >> 4);
        dy = (@as(i32, b[1] & 15) << 8) | b[2];
    } else {
        g = f - 124;
        const b = try r.take(4);
        dx = (@as(i32, b[0]) << 8) | b[1];
        dy = (@as(i32, b[2]) << 8) | b[3];
    }
    return .{
        .dx = if (g & 1 != 0) dx else -dx,
        .dy = if (g & 2 != 0) dy else -dy,
    };
}

/// Rebuilds `hmtx` from its transformed form (WOFF 2.0 section 5.4): left side
/// bearings left out are the glyphs' xMin.
fn rebuildHmtx(arena: std.mem.Allocator, tables: []const Table, data: []const u8) Error![]const u8 {
    const find = struct {
        fn f(ts: []const Table, tag: []const u8) []const u8 {
            for (ts) |t| if (std.mem.eql(u8, &t.tag, tag)) return t.data;
            return &.{};
        }
    }.f;
    const hhea = find(tables, "hhea");
    const maxp = find(tables, "maxp");
    const head = find(tables, "head");
    const glyf = find(tables, "glyf");
    const loca = find(tables, "loca");
    if (hhea.len < 36 or maxp.len < 6 or head.len < 54) return error.InvalidFont;
    const num_h: usize = be16(hhea, 34);
    const num_glyphs: usize = be16(maxp, 4);
    if (num_h == 0 or num_h > num_glyphs) return error.InvalidFont;
    const long_loca = be16(head, 50) != 0;

    var r: Reader = .{
        .data = data,
    };
    const flags = try r.byte();
    if (flags & 3 == 0 or flags & 0xfc != 0) return error.InvalidFont;
    const advances = try r.take(2 * num_h);
    const lsbs: ?[]const u8 = if (flags & 1 == 0) try r.take(2 * num_h) else null;
    const rest: ?[]const u8 = if (flags & 2 == 0) try r.take(2 * (num_glyphs - num_h)) else null;

    const out = try arena.alloc(u8, 4 * num_h + 2 * (num_glyphs - num_h));
    for (0..num_glyphs) |g| {
        var lsb: u16 = undefined;
        if (g < num_h) {
            lsb = if (lsbs) |l| be16(l, 2 * g) else try xMin(glyf, loca, long_loca, g);
            out[4 * g] = advances[2 * g];
            out[4 * g + 1] = advances[2 * g + 1];
            put16(out, 4 * g + 2, lsb);
        } else {
            const k = g - num_h;
            lsb = if (rest) |l| be16(l, 2 * k) else try xMin(glyf, loca, long_loca, g);
            put16(out, 4 * num_h + 2 * k, lsb);
        }
    }
    return out;
}

/// Glyph `g`'s xMin from `glyf`/`loca`, 0 for an empty glyph.
fn xMin(glyf: []const u8, loca: []const u8, long: bool, g: usize) Error!u16 {
    const a: usize, const b: usize = if (long)
        .{ be32(loca, 4 * g), be32(loca, 4 * g + 4) }
    else
        .{ @as(usize, be16(loca, 2 * g)) * 2, @as(usize, be16(loca, 2 * g + 2)) * 2 };
    if ((if (long) 4 * g + 8 else 2 * g + 4) > loca.len) return error.InvalidFont;
    if (b <= a) return 0;
    if (a + 4 > glyf.len) return error.InvalidFont;
    return be16(glyf, a + 2);
}

// Writing the sfnt --------------------------------------------------------------------

/// Writes an sfnt with `tables` (in tag order, 4-byte aligned, with checksums and the
/// head checksum adjustment).
fn writeSfnt(gpa: std.mem.Allocator, flavor: u32, tables: []Table) Error![]u8 {
    if (tables.len == 0 or tables.len > 0xffff) return error.InvalidFont;
    std.mem.sort(Table, tables, {}, struct {
        fn lt(_: void, a: Table, b: Table) bool {
            return std.mem.order(u8, &a.tag, &b.tag) == .lt;
        }
    }.lt);
    var size: usize = 12 + 16 * tables.len;
    for (tables) |t| size += pad4(t.data.len);
    const out = try gpa.alloc(u8, size);
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], flavor, .big);
    const n: u16 = @intCast(tables.len);
    const selector = std.math.log2_int(u16, n);
    const range = @as(u32, 16) << selector;
    put16(out, 4, n);
    put16(out, 6, @truncate(range));
    put16(out, 8, selector);
    put16(out, 10, @truncate(@as(u32, n) * 16 - range));
    var at: usize = 12 + 16 * tables.len;
    var head_at: ?usize = null;
    for (tables, 0..) |t, k| {
        const rec = 12 + 16 * k;
        @memcpy(out[at..][0..t.data.len], t.data);
        const is_head = std.mem.eql(u8, &t.tag, "head") and t.data.len >= 12;
        if (is_head) {
            head_at = at;
            @memset(out[at + 8 ..][0..4], 0);
        }
        @memcpy(out[rec..][0..4], &t.tag);
        std.mem.writeInt(u32, out[rec + 4 ..][0..4], checksum(out[at..][0..pad4(t.data.len)]), .big);
        std.mem.writeInt(u32, out[rec + 8 ..][0..4], @intCast(at), .big);
        std.mem.writeInt(u32, out[rec + 12 ..][0..4], @intCast(t.data.len), .big);
        at += pad4(t.data.len);
    }
    if (head_at) |h| std.mem.writeInt(u32, out[h + 8 ..][0..4], 0xB1B0AFBA -% checksum(out), .big);
    return out;
}

fn checksum(data: []const u8) u32 {
    var sum: u32 = 0;
    var k: usize = 0;
    while (k + 4 <= data.len) : (k += 4) sum +%= std.mem.readInt(u32, data[k..][0..4], .big);
    return sum;
}

fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

// Reading -----------------------------------------------------------------------------

/// A bounds-checked cursor over big-endian data.
const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.data.len - self.pos) return error.InvalidFont;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }

    fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    fn i16be(self: *Reader) Error!i16 {
        return @bitCast(be16(try self.take(2), 0));
    }

    fn u32be(self: *Reader) Error!u32 {
        return be32(try self.take(4), 0);
    }

    /// A 255UInt16 (WOFF 2.0 section 3.1).
    fn ushort255(self: *Reader) Error!u16 {
        const code = try self.byte();
        return switch (code) {
            253 => be16(try self.take(2), 0),
            254 => @as(u16, try self.byte()) + 506,
            255 => @as(u16, try self.byte()) + 253,
            else => code,
        };
    }

    /// A UIntBase128 (WOFF 2.0 section 3.1): no leading zeros, at most five bytes.
    fn base128(self: *Reader) Error!u32 {
        var v: u32 = 0;
        for (0..5) |k| {
            const b = try self.byte();
            if (k == 0 and b == 0x80) return error.InvalidFont;
            if (v & 0xfe000000 != 0) return error.InvalidFont;
            v = (v << 7) | (b & 0x7f);
            if (b & 0x80 == 0) return v;
        }
        return error.InvalidFont;
    }
};

fn bitSet(bitmap: []const u8, i: usize) bool {
    if (i / 8 >= bitmap.len) return false;
    return bitmap[i / 8] & (@as(u8, 0x80) >> @intCast(i % 8)) != 0;
}

fn be16(d: []const u8, off: usize) u16 {
    if (off > d.len or d.len - off < 2) return 0;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

fn be32(d: []const u8, off: usize) u32 {
    if (off > d.len or d.len - off < 4) return 0;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

fn put16(d: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, d[off..][0..2], v, .big);
}

fn tag32(comptime t: *const [4]u8) u32 {
    return std.mem.readInt(u32, t, .big);
}

// Tests -------------------------------------------------------------------------------

const testing = std.testing;
const font_mod = @import("font.zig");

/// Bits packed least significant first (Brotli and Deflate order).
const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    used: u3 = 0,

    fn bit(w: *BitWriter, gpa: std.mem.Allocator, b: u1) !void {
        if (w.used == 0) try w.bytes.append(gpa, 0);
        w.bytes.items[w.bytes.items.len - 1] |= @as(u8, b) << w.used;
        w.used +%= 1;
    }

    /// An integer, least significant bit first.
    fn int(w: *BitWriter, gpa: std.mem.Allocator, v: u32, n: u5) !void {
        for (0..n) |k| try w.bit(gpa, @truncate(v >> @intCast(k)));
    }

    /// A prefix code, most significant bit first.
    fn code(w: *BitWriter, gpa: std.mem.Allocator, v: u32, n: u5) !void {
        for (0..n) |k| try w.bit(gpa, @truncate(v >> @intCast(n - 1 - k)));
    }

    fn alignByte(w: *BitWriter) void {
        w.used = 0;
    }
};

/// A Brotli stream of uncompressed meta-blocks holding `data`.
fn brotliStored(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var w: BitWriter = .{};
    errdefer w.bytes.deinit(gpa);
    try w.int(gpa, 0, 1); // WBITS 16
    var at: usize = 0;
    while (at < data.len) {
        const n = @min(data.len - at, 65536);
        try w.int(gpa, 0, 1); // ISLAST
        try w.int(gpa, 0, 2); // MNIBBLES 4
        try w.int(gpa, @intCast(n - 1), 16);
        try w.int(gpa, 1, 1); // ISUNCOMPRESSED
        w.alignByte();
        try w.bytes.appendSlice(gpa, data[at..][0..n]);
        at += n;
    }
    try w.int(gpa, 3, 2); // ISLAST, ISLASTEMPTY
    return w.bytes.toOwnedSlice(gpa);
}

/// A zlib stream of `n` zero bytes (n = 1 + 258 k) in one fixed-Huffman block.
fn zlibZeros(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var w: BitWriter = .{};
    errdefer w.bytes.deinit(gpa);
    try w.bytes.appendSlice(gpa, &.{ 0x78, 0x01 });
    try w.int(gpa, 1, 1); // BFINAL
    try w.int(gpa, 1, 2); // fixed codes
    try w.code(gpa, 0x30, 8); // literal 0
    for (0..(n - 1) / 258) |_| {
        try w.code(gpa, 0xc5, 8); // length 258
        try w.code(gpa, 0, 5); // distance 1
    }
    try w.code(gpa, 0, 7); // end of block
    w.alignByte();
    const zeros = try gpa.alloc(u8, n);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(zeros), .big);
    try w.bytes.appendSlice(gpa, &adler);
    return w.bytes.toOwnedSlice(gpa);
}

fn be(comptime T: type, v: T) [@sizeOf(T)]u8 {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .big);
    return b;
}

/// The test font's tables: glyph 0 empty, glyph 1 two contours (one with an off-curve
/// point, overlap flag set), glyph 2 a scaled composite of glyph 1 with instructions.
const test_font = struct {
    const head = blk: {
        var h: [54]u8 = @splat(0);
        h[0] = 0;
        h[1] = 1;
        h[12] = 0x5f;
        h[13] = 0x0f;
        h[14] = 0x3c;
        h[15] = 0xf5;
        h[18] = 0x03; // unitsPerEm 1000
        h[19] = 0xe8;
        break :blk h; // indexToLocFormat 0
    };
    const hhea = blk: {
        var h: [36]u8 = @splat(0);
        h[1] = 1;
        h[35] = 2; // numberOfHMetrics
        break :blk h;
    };
    const maxp = [_]u8{ 0, 0, 0x50, 0, 0, 3 };
    const cmap = [_]u8{ 0, 0, 0, 0 };
    // Advance 600 / lsb 0, advance 650 / lsb 0, lsb 50.
    const hmtx = [_]u8{ 0x02, 0x58, 0, 0, 0x02, 0x8a, 0, 0, 0, 50 };
    const xs = [_]i16{ 0, 500, 0, -500, 100, 150, 150 };
    const ys = [_]i16{ 0, 0, 700, 0, -600, 300, -300 };
    const glyph1 = blk: {
        var g: []const u8 = &(be(i16, 2) ++ be(i16, 0) ++ be(i16, 0) ++ be(i16, 500) ++ be(i16, 700) ++ be(u16, 3) ++ be(u16, 6) ++ be(u16, 2) ++ [_]u8{ 0xb0, 0x01 } ++ [_]u8{ 0x41, 1, 1, 1, 1, 0, 1 });
        for (xs) |x| g = g ++ be(i16, x);
        for (ys) |y| g = g ++ be(i16, y);
        break :blk g ++ [_]u8{ 0, 0, 0 };
    };
    const glyph2 = be(i16, -1) ++ be(i16, 50) ++ be(i16, -10) ++ be(i16, 550) ++ be(i16, 690) ++ be(u16, 0x010a) ++ be(u16, 1) ++ [_]u8{ 50, 0xf6 } ++ be(u16, 0x4000) ++ be(u16, 1) ++ [_]u8{0x2a} ++ [_]u8{ 0, 0, 0 };
    const glyf = glyph1 ++ glyph2;
    const loca = be(u16, 0) ++ be(u16, 0) ++ be(u16, glyph1.len / 2) ++ be(u16, glyf.len / 2);

    /// The transformed glyf (WOFF 2.0 section 5.1) of the same glyphs.
    const glyf_transformed = blk: {
        const n_contour = be(i16, 0) ++ be(i16, 2) ++ be(i16, -1);
        const n_points = [_]u8{ 4, 3 };
        const flags = [_]u8{ 1, 13, 5, 12, 121, 91 | 0x80, 125 };
        const glyph = [_]u8{ 0, 244, 188, 244, 0x06, 0x42, 0x58, 149, 43, 0x00, 0x96, 0x01, 0x2c } ++ [_]u8{ 2, 1 };
        const composite = be(u16, 0x010a) ++ be(u16, 1) ++ [_]u8{ 50, 0xf6 } ++ be(u16, 0x4000);
        const bbox = [_]u8{ 0x20, 0, 0, 0 } ++ be(i16, 50) ++ be(i16, -10) ++ be(i16, 550) ++ be(i16, 690);
        const instructions = [_]u8{ 0xb0, 0x01, 0x2a };
        const overlap = [_]u8{0x40};
        break :blk be(u16, 0) ++ be(u16, 1) ++ be(u16, 3) ++ be(u16, 0) ++
            be(u32, n_contour.len) ++ be(u32, n_points.len) ++ be(u32, flags.len) ++ be(u32, glyph.len) ++
            be(u32, composite.len) ++ be(u32, bbox.len) ++ be(u32, instructions.len) ++
            n_contour ++ n_points ++ flags ++ glyph ++ composite ++ bbox ++ instructions ++ overlap;
    };
    /// hmtx with both bearing arrays left to the glyphs' xMin.
    const hmtx_transformed = [_]u8{ 3, 0x02, 0x58, 0x02, 0x8a };

    fn tables() [7]Table {
        return .{
            .{
                .tag = "head".*,
                .data = &head,
            },
            .{
                .tag = "hhea".*,
                .data = &hhea,
            },
            .{
                .tag = "maxp".*,
                .data = &maxp,
            },
            .{
                .tag = "cmap".*,
                .data = &cmap,
            },
            .{
                .tag = "hmtx".*,
                .data = &hmtx,
            },
            .{
                .tag = "glyf".*,
                .data = glyf,
            },
            .{
                .tag = "loca".*,
                .data = &loca,
            },
        };
    }
};

/// Writes a WOFF 2.0 file of the test font; `transform` picks transformed glyf, loca
/// and hmtx over null transforms.
fn testWoff2(gpa: std.mem.Allocator, transform: bool) ![]u8 {
    var dir: std.ArrayList(u8) = .empty;
    defer dir.deinit(gpa);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    const T = test_font;
    const Item = struct {
        flags: u8,
        orig: []const u8,
        stored: ?[]const u8,
    };
    const items = [_]Item{
        .{
            .flags = 1,
            .orig = &T.head,
            .stored = null,
        },
        .{
            .flags = 2,
            .orig = &T.hhea,
            .stored = null,
        },
        .{
            .flags = 4,
            .orig = &T.maxp,
            .stored = null,
        },
        .{
            .flags = 63,
            .orig = &T.cmap,
            .stored = null,
        },
        .{
            .flags = if (transform) 3 | 0x40 else 3,
            .orig = &T.hmtx,
            .stored = if (transform) &T.hmtx_transformed else null,
        },
        .{
            .flags = if (transform) 10 else 10 | 0xc0,
            .orig = T.glyf,
            .stored = if (transform) &T.glyf_transformed else null,
        },
        .{
            .flags = if (transform) 11 else 11 | 0xc0,
            .orig = &T.loca,
            .stored = if (transform) "" else null,
        },
    };
    for (items) |it| {
        try dir.append(gpa, it.flags);
        if (it.flags & 0x3f == 63) try dir.appendSlice(gpa, "cmap");
        try dir.append(gpa, @intCast(it.orig.len)); // all under 128: one base-128 byte
        if (it.stored) |s| try dir.append(gpa, @intCast(s.len));
        try data.appendSlice(gpa, it.stored orelse it.orig);
    }
    const compressed = try brotliStored(gpa, data.items);
    defer gpa.free(compressed);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "wOF2");
    try out.appendSlice(gpa, &be(u32, 0x00010000));
    try out.appendSlice(gpa, &be(u32, @intCast(48 + dir.items.len + compressed.len)));
    try out.appendSlice(gpa, &be(u16, items.len));
    try out.appendSlice(gpa, &be(u16, 0));
    try out.appendSlice(gpa, &be(u32, 0));
    try out.appendSlice(gpa, &be(u32, @intCast(compressed.len)));
    try out.appendNTimes(gpa, 0, 24);
    try out.appendSlice(gpa, dir.items);
    try out.appendSlice(gpa, compressed);
    return out.toOwnedSlice(gpa);
}

fn expectSameOutlines(gpa: std.mem.Allocator, a_bytes: []const u8, b_bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try font_mod.Font.parse(arena, a_bytes);
    const b = try font_mod.Font.parse(arena, b_bytes);
    try testing.expectEqual(a.num_glyphs, b.num_glyphs);
    for (0..a.num_glyphs) |g| {
        var pa: @import("../raster/geom.zig").Path = .{};
        var pb: @import("../raster/geom.zig").Path = .{};
        try a.outline(arena, @intCast(g), .identity, &pa);
        try b.outline(arena, @intCast(g), .identity, &pb);
        try testing.expectEqualSlices(@TypeOf(pa.verbs.items[0]), pa.verbs.items, pb.verbs.items);
        try testing.expectEqual(pa.points.items.len, pb.points.items.len);
        for (pa.points.items, pb.points.items) |p, q| try testing.expect(std.meta.eql(p, q));
        try testing.expectEqual(a.advance(@intCast(g)), b.advance(@intCast(g)));
    }
}

fn tableOf(sfnt: []const u8, tag: []const u8) []const u8 {
    const n = be16(sfnt, 4);
    for (0..n) |k| {
        const rec = 12 + 16 * k;
        if (std.mem.eql(u8, sfnt[rec..][0..4], tag)) return sfnt[be32(sfnt, rec + 8)..][0..be32(sfnt, rec + 12)];
    }
    return &.{};
}

test "WOFF 2.0 with transformed glyf, loca and hmtx rebuilds the font" {
    const gpa = testing.allocator;
    var tables = test_font.tables();
    const plain = try writeSfnt(gpa, 0x00010000, &tables);
    defer gpa.free(plain);
    for ([_]bool{ true, false }) |transform| {
        const file = try testWoff2(gpa, transform);
        defer gpa.free(file);
        try testing.expect(isWoff(file));
        const sfnt = try toSfnt(gpa, file);
        defer gpa.free(sfnt);
        try expectSameOutlines(gpa, plain, sfnt);
        try testing.expectEqualSlices(u8, &test_font.hmtx, tableOf(sfnt, "hmtx"));
        const glyf = tableOf(sfnt, "glyf");
        // Header, end points and instructions as written; the overlap flag kept.
        try testing.expectEqualSlices(u8, test_font.glyph1[0..18], glyf[0..18]);
        try testing.expect(glyf[18] & 0x40 != 0);
        // The composite glyph is copied whole.
        const loca = tableOf(sfnt, "loca");
        const g2 = glyf[@as(usize, be16(loca, 4)) * 2 .. @as(usize, be16(loca, 6)) * 2];
        try testing.expectEqualSlices(u8, &test_font.glyph2, g2);
        // Every truncation is refused cleanly.
        for (0..file.len) |n| try testing.expectError(error.InvalidFont, toSfnt(gpa, file[0..n]));
    }
}

test "WOFF 1.0 with stored and zlib tables" {
    const gpa = testing.allocator;
    var tables = test_font.tables();
    const plain = try writeSfnt(gpa, 0x00010000, &tables);
    defer gpa.free(plain);
    // The test font plus a 517-byte table of zeros, compressed.
    const zeros_len = 517;
    const z = try zlibZeros(gpa, zeros_len);
    defer gpa.free(z);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const n = tables.len + 1;
    try out.appendSlice(gpa, "wOFF");
    try out.appendSlice(gpa, &be(u32, 0x00010000));
    try out.appendNTimes(gpa, 0, 4);
    try out.appendSlice(gpa, &be(u16, n));
    try out.appendNTimes(gpa, 0, 44 - 14);
    var at: u32 = @intCast(44 + 20 * n);
    for (tables) |t| {
        try out.appendSlice(gpa, &t.tag);
        try out.appendSlice(gpa, &(be(u32, at) ++ be(u32, @intCast(t.data.len)) ++ be(u32, @intCast(t.data.len)) ++ be(u32, 0)));
        at += @intCast(pad4(t.data.len));
    }
    try out.appendSlice(gpa, "zero");
    try out.appendSlice(gpa, &(be(u32, at) ++ be(u32, @intCast(z.len)) ++ be(u32, zeros_len) ++ be(u32, 0)));
    for (tables) |t| {
        try out.appendSlice(gpa, t.data);
        try out.appendNTimes(gpa, 0, pad4(t.data.len) - t.data.len);
    }
    try out.appendSlice(gpa, z);
    try testing.expect(isWoff(out.items));
    const sfnt = try toSfnt(gpa, out.items);
    defer gpa.free(sfnt);
    try expectSameOutlines(gpa, plain, sfnt);
    const zero = tableOf(sfnt, "zero");
    try testing.expectEqual(@as(usize, zeros_len), zero.len);
    for (zero) |b| try testing.expectEqual(@as(u8, 0), b);
    for (0..out.items.len) |k| try testing.expectError(error.InvalidFont, toSfnt(gpa, out.items[0..k]));
}

test "triplet decoding follows the WOFF 2.0 table" {
    const cases = [_]struct {
        flag: u8,
        bytes: []const u8,
        dx: i32,
        dy: i32,
    }{
        .{
            .flag = 0,
            .bytes = &.{5},
            .dx = 0,
            .dy = -5,
        },
        .{
            .flag = 9,
            .bytes = &.{5},
            .dx = 0,
            .dy = 1029,
        },
        .{
            .flag = 12,
            .bytes = &.{7},
            .dx = -263,
            .dy = 0,
        },
        .{
            .flag = 20,
            .bytes = &.{0x23},
            .dx = -3,
            .dy = -4,
        },
        .{
            .flag = 83,
            .bytes = &.{0x23},
            .dx = 51,
            .dy = 52,
        },
        .{
            .flag = 85,
            .bytes = &.{ 1, 2 },
            .dx = 2,
            .dy = -3,
        },
        .{
            .flag = 119,
            .bytes = &.{ 1, 2 },
            .dx = 514,
            .dy = 515,
        },
        .{
            .flag = 120,
            .bytes = &.{ 0x12, 0x34, 0x56 },
            .dx = -0x123,
            .dy = -0x456,
        },
        .{
            .flag = 127 | 0x80,
            .bytes = &.{ 0x12, 0x34, 0x56, 0x78 },
            .dx = 0x1234,
            .dy = 0x5678,
        },
    };
    for (cases) |c| {
        var r: Reader = .{
            .data = c.bytes,
        };
        const d = try triplet(c.flag, &r);
        try testing.expectEqual(c.dx, d.dx);
        try testing.expectEqual(c.dy, d.dy);
        try testing.expectEqual(c.bytes.len, r.pos);
    }
}

test "variable-length integers" {
    var r: Reader = .{
        .data = &.{ 0x3f, 0x81, 0x00, 0x80, 0x01, 0xff, 0xff, 0xff, 0xff, 0x7f },
    };
    try testing.expectEqual(@as(u32, 63), try r.base128());
    try testing.expectEqual(@as(u32, 128), try r.base128());
    try testing.expectError(error.InvalidFont, r.base128()); // leading zero
    var big: Reader = .{
        .data = &.{ 0x8f, 0xff, 0xff, 0xff, 0x7f },
    };
    try testing.expectEqual(@as(u32, 0xffffffff), try big.base128());
    var too_big: Reader = .{
        .data = &.{ 0x90, 0x80, 0x80, 0x80, 0x00 },
    };
    try testing.expectError(error.InvalidFont, too_big.base128());
    var s: Reader = .{
        .data = &.{ 252, 255, 0, 254, 0, 253, 0x12, 0x34 },
    };
    try testing.expectEqual(@as(u16, 252), try s.ushort255());
    try testing.expectEqual(@as(u16, 253), try s.ushort255());
    try testing.expectEqual(@as(u16, 506), try s.ushort255());
    try testing.expectEqual(@as(u16, 0x1234), try s.ushort255());
}
