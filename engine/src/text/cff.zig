//! CFF (Compact Font Format, version 1) outlines: the `CFF ` table of an
//! OpenType font with PostScript outlines ('OTTO').
//!
//! Written from Adobe Technical Note #5176 (The Compact Font Format
//! Specification), #5177 (The Type 2 Charstring Format) and the OpenType
//! specification's CFF chapter. Reads the header, the Name / Top DICT /
//! String / Global Subr INDEXes, the CharStrings INDEX, the Private DICT
//! (local Subrs, defaultWidthX, nominalWidthX) and, for CID-keyed fonts,
//! the FDArray and FDSelect (formats 0 and 3) that pick each glyph's
//! Private DICT. Type 2 charstrings are interpreted into moves, lines and
//! cubics handed to a caller's sink.
//!
//! Every read is bounds-checked and the interpreter is limited in stack
//! size, subroutine depth and total work: corrupt data is an error, never
//! a panic or a hang. Accented-character `endchar` (the deprecated seac
//! form) is read but its accent composition is not drawn. CFF2 (variable
//! fonts) is a different table and is not handled here.

const std = @import("std");
const geom = @import("../raster/geom.zig");
const Vec2 = geom.Vec2;

/// Errors from reading a CFF table or one of its charstrings.
pub const Error = error{
    InvalidFont,
    UnsupportedFont,
    InvalidGlyph,
    OutOfMemory,
};

fn r16(d: []const u8, off: usize) ?u16 {
    if (off > d.len or d.len - off < 2) return null;
    return @as(u16, d[off]) << 8 | d[off + 1];
}

/// Reads a big-endian offset of `size` (1..4) bytes.
fn readOffset(d: []const u8, off: usize, size: u8) ?u32 {
    if (off > d.len or d.len - off < size) return null;
    var v: u32 = 0;
    for (d[off .. off + size]) |b| v = v << 8 | b;
    return v;
}

// ---------------------------------------------------------------------------
// INDEX.

/// An INDEX: a counted array of variable-length byte strings.
pub const Index = struct {
    /// The whole CFF table.
    data: []const u8 = &.{},
    /// Number of items.
    count: u32 = 0,
    off_size: u8 = 1,
    /// Position of the offset array.
    offsets: usize = 0,
    /// Position of the byte before the item data (offsets are 1-based).
    base: usize = 0,

    /// Item `k`, or null when out of range or malformed.
    pub fn get(self: Index, k: u32) ?[]const u8 {
        if (k >= self.count) return null;
        const a = readOffset(self.data, self.offsets + @as(usize, k) * self.off_size, self.off_size) orelse return null;
        const b = readOffset(self.data, self.offsets + (@as(usize, k) + 1) * self.off_size, self.off_size) orelse return null;
        if (a == 0 or b < a) return null;
        const start = self.base + a;
        const end = self.base + b;
        if (end > self.data.len) return null;
        return self.data[start..end];
    }

    /// The subroutine number bias for an INDEX of this size (Type 2 charstrings).
    pub fn bias(self: Index) i32 {
        return if (self.count < 1240) 107 else if (self.count < 33900) 1131 else 32768;
    }
};

const IndexAt = struct {
    index: Index,
    /// Position just past the INDEX.
    end: usize,
};

/// Reads the INDEX starting at `pos` in `d`.
fn readIndex(d: []const u8, pos: usize) Error!IndexAt {
    const count = r16(d, pos) orelse return error.InvalidFont;
    if (count == 0) return .{
        .index = .{
            .data = d,
        },
        .end = pos + 2,
    };
    if (pos + 3 > d.len) return error.InvalidFont;
    const os = d[pos + 2];
    if (os < 1 or os > 4) return error.InvalidFont;
    const offsets = pos + 3;
    const arr = (@as(usize, count) + 1) * os;
    if (offsets + arr > d.len) return error.InvalidFont;
    const base = offsets + arr - 1;
    const last = readOffset(d, offsets + @as(usize, count) * os, os) orelse return error.InvalidFont;
    if (last == 0 or base + last > d.len) return error.InvalidFont;
    return .{
        .index = .{
            .data = d,
            .count = count,
            .off_size = os,
            .offsets = offsets,
            .base = base,
        },
        .end = base + last,
    };
}

// ---------------------------------------------------------------------------
// DICT.

const max_dict_operands = 48;

/// Appends `c` to a real number's text (an over-long one reads as 0).
fn realChar(buf: *[64]u8, n: *usize, c: u8) void {
    if (n.* < buf.len) {
        buf[n.*] = c;
        n.* += 1;
    } else n.* = buf.len + 1;
}

/// Reads one DICT operand at `i.*`, advancing past it.
fn dictNumber(d: []const u8, i: *usize) Error!f64 {
    const b0 = d[i.*];
    i.* += 1;
    switch (b0) {
        32...246 => return @as(f64, @floatFromInt(@as(i32, b0) - 139)),
        247...250 => {
            if (i.* >= d.len) return error.InvalidFont;
            const b1 = d[i.*];
            i.* += 1;
            return @floatFromInt((@as(i32, b0) - 247) * 256 + b1 + 108);
        },
        251...254 => {
            if (i.* >= d.len) return error.InvalidFont;
            const b1 = d[i.*];
            i.* += 1;
            return @floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108);
        },
        28 => {
            const v = r16(d, i.*) orelse return error.InvalidFont;
            i.* += 2;
            return @floatFromInt(@as(i16, @bitCast(v)));
        },
        29 => {
            const v = readOffset(d, i.*, 4) orelse return error.InvalidFont;
            i.* += 4;
            return @floatFromInt(@as(i32, @bitCast(v)));
        },
        30 => {
            // A real number: nibbles of digits, '.', 'E', 'E-', '-', ended by 0xf.
            var buf: [64]u8 = undefined;
            var n: usize = 0;
            while (true) {
                if (i.* >= d.len) return error.InvalidFont;
                const b = d[i.*];
                i.* += 1;
                for ([2]u8{ b >> 4, b & 15 }) |nib| {
                    switch (nib) {
                        0...9 => realChar(&buf, &n, '0' + nib),
                        0xa => realChar(&buf, &n, '.'),
                        0xb => realChar(&buf, &n, 'E'),
                        0xc => {
                            realChar(&buf, &n, 'E');
                            realChar(&buf, &n, '-');
                        },
                        0xd => return error.InvalidFont,
                        0xe => realChar(&buf, &n, '-'),
                        else => return if (n > buf.len) 0 else std.fmt.parseFloat(f64, buf[0..n]) catch 0,
                    }
                }
            }
        },
        else => return error.InvalidFont,
    }
}

/// The operands of operator `op` (escaped operators are 1200 + the second
/// byte) in DICT `dict`, or null when it is absent.
fn dictFind(dict: []const u8, op: u16, buf: *[max_dict_operands]f64) Error!?[]const f64 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < dict.len) {
        const b0 = dict[i];
        if (b0 <= 21) {
            var o: u16 = b0;
            i += 1;
            if (b0 == 12) {
                if (i >= dict.len) return error.InvalidFont;
                o = 1200 + @as(u16, dict[i]);
                i += 1;
            }
            if (o == op) return buf[0..n];
            n = 0;
            continue;
        }
        if (n == buf.len) return error.InvalidFont;
        buf[n] = try dictNumber(dict, &i);
        n += 1;
    }
    return null;
}

/// Operand `k` of `op` in `dict` as a non-negative integer offset or size,
/// null when the operator is absent.
fn dictOffset(dict: []const u8, op: u16, k: usize) Error!?usize {
    var buf: [max_dict_operands]f64 = undefined;
    const args = try dictFind(dict, op, &buf) orelse return null;
    if (args.len <= k) return error.InvalidFont;
    const v = args[k];
    if (!(v >= 0 and v < 1 << 31)) return error.InvalidFont;
    return @intFromFloat(v);
}

/// Operand 0 of `op` in `dict` as a float, or `default` when absent.
fn dictValue(dict: []const u8, op: u16, default: f32) Error!f32 {
    var buf: [max_dict_operands]f64 = undefined;
    const args = try dictFind(dict, op, &buf) orelse return default;
    if (args.len == 0) return error.InvalidFont;
    return @floatCast(args[0]);
}

const op_charset_type = 1206;
const op_char_strings = 17;
const op_private = 18;
const op_subrs = 19;
const op_default_width = 20;
const op_nominal_width = 21;
const op_ros = 1230;
const op_fd_array = 1236;
const op_fd_select = 1237;

// ---------------------------------------------------------------------------
// The font.

/// The values a glyph's charstring needs from its Private DICT.
pub const Private = struct {
    /// Local subroutines.
    subrs: Index = .{},
    /// Advance width of glyphs whose charstring gives none.
    default_width: f32 = 0,
    /// Added to the width a charstring gives.
    nominal_width: f32 = 0,
};

/// A parsed CFF table. Borrows the table bytes.
pub const Cff = struct {
    /// The CFF table.
    data: []const u8,
    /// One Type 2 charstring per glyph.
    char_strings: Index,
    /// Global subroutines.
    gsubrs: Index,
    /// The Private DICT of a name-keyed font (unused when CID-keyed).
    private: Private = .{},
    /// CID-keyed fonts: the Font DICTs, each with its own Private DICT.
    fd_array: Index = .{},
    /// CID-keyed fonts: the FDSelect position in `data` (0 when not CID-keyed).
    fd_select: usize = 0,

    /// Reads the CFF table `data` (the first font of its FontSet).
    pub fn init(data: []const u8) Error!Cff {
        if (data.len < 4) return error.InvalidFont;
        if (data[0] != 1) return error.UnsupportedFont;
        const hdr_size = data[2];
        if (hdr_size < 4) return error.InvalidFont;
        const names = try readIndex(data, hdr_size);
        const tops = try readIndex(data, names.end);
        const strings = try readIndex(data, tops.end);
        const globals = try readIndex(data, strings.end);
        const top = tops.index.get(0) orelse return error.InvalidFont;

        if (try dictValue(top, op_charset_type, 2) != 2) return error.UnsupportedFont;
        const cs_off = try dictOffset(top, op_char_strings, 0) orelse return error.InvalidFont;
        const cs = try readIndex(data, cs_off);
        if (cs.index.count == 0) return error.InvalidFont;

        var c: Cff = .{
            .data = data,
            .char_strings = cs.index,
            .gsubrs = globals.index,
        };
        var ros: [max_dict_operands]f64 = undefined;
        if (try dictFind(top, op_ros, &ros) != null) {
            const fda = try dictOffset(top, op_fd_array, 0) orelse return error.InvalidFont;
            c.fd_array = (try readIndex(data, fda)).index;
            if (c.fd_array.count == 0) return error.InvalidFont;
            c.fd_select = try dictOffset(top, op_fd_select, 0) orelse return error.InvalidFont;
            if (c.fd_select == 0 or c.fd_select >= data.len) return error.InvalidFont;
            const format = data[c.fd_select];
            if (format != 0 and format != 3) return error.UnsupportedFont;
            // Every Font DICT must lead to a readable Private DICT.
            for (0..c.fd_array.count) |k| {
                const fd = c.fd_array.get(@intCast(k)) orelse return error.InvalidFont;
                _ = try readPrivate(data, fd);
            }
        } else {
            c.private = try readPrivate(data, top);
        }
        return c;
    }

    /// Number of glyphs (charstrings).
    pub fn glyphCount(self: *const Cff) u32 {
        return self.char_strings.count;
    }

    /// The Font DICT index of `glyph` in a CID-keyed font.
    fn fdOf(self: *const Cff, glyph: u16) Error!u32 {
        const d = self.data;
        const at = self.fd_select;
        const fd: u32 = switch (d[at]) {
            0 => blk: {
                if (at + 1 + @as(usize, glyph) >= d.len) return error.InvalidGlyph;
                break :blk d[at + 1 + glyph];
            },
            3 => blk: {
                const n: usize = r16(d, at + 1) orelse return error.InvalidGlyph;
                if (n == 0 or at + 3 + n * 3 + 2 > d.len) return error.InvalidGlyph;
                // Ranges sorted by first glyph; the sentinel ends the last one.
                var lo: usize = 0;
                var hi: usize = n;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (r16(d, at + 3 + mid * 3).? <= glyph) lo = mid + 1 else hi = mid;
                }
                if (lo == 0) return error.InvalidGlyph;
                const rec = at + 3 + (lo - 1) * 3;
                const next = r16(d, rec + 3).?;
                if (glyph >= next) return error.InvalidGlyph;
                break :blk d[rec + 2];
            },
            else => return error.InvalidGlyph,
        };
        if (fd >= self.fd_array.count) return error.InvalidGlyph;
        return fd;
    }

    /// The Private DICT values that apply to `glyph`.
    pub fn privateFor(self: *const Cff, glyph: u16) Error!Private {
        if (self.fd_select == 0) return self.private;
        const fd = self.fd_array.get(try self.fdOf(glyph)) orelse return error.InvalidGlyph;
        return readPrivate(self.data, fd) catch return error.InvalidGlyph;
    }

    /// Interprets the charstring of `glyph`, handing its contours to `sink`
    /// (font units, y up): `moveTo(p)`, `lineTo(p)`, `cubicTo(c1, c2, p)`
    /// and `close()`, each returning an error union. Every contour is
    /// closed, with an explicit line back to its start when it ends
    /// elsewhere. Returns the glyph's advance width from the charstring.
    pub fn outline(self: *const Cff, glyph: u16, sink: anytype) Error!f32 {
        const code = self.char_strings.get(glyph) orelse return error.InvalidGlyph;
        const priv = try self.privateFor(glyph);
        var m: Machine = .{
            .gsubrs = self.gsubrs,
            .lsubrs = priv.subrs,
            .nominal_width = priv.nominal_width,
            .width = priv.default_width,
        };
        try m.run(code, sink);
        return m.width;
    }
};

/// Reads the Private DICT named by the `Private` operator of `dict`.
fn readPrivate(data: []const u8, dict: []const u8) Error!Private {
    var buf: [max_dict_operands]f64 = undefined;
    const args = try dictFind(dict, op_private, &buf) orelse return .{};
    if (args.len < 2) return error.InvalidFont;
    if (!(args[0] >= 0 and args[0] < 1 << 31 and args[1] >= 0 and args[1] < 1 << 31)) return error.InvalidFont;
    const size: usize = @intFromFloat(args[0]);
    const off: usize = @intFromFloat(args[1]);
    if (off > data.len or data.len - off < size) return error.InvalidFont;
    const priv = data[off .. off + size];
    var p: Private = .{
        .default_width = try dictValue(priv, op_default_width, 0),
        .nominal_width = try dictValue(priv, op_nominal_width, 0),
    };
    if (try dictOffset(priv, op_subrs, 0)) |rel| {
        p.subrs = (try readIndex(data, off + rel)).index;
    }
    return p;
}

// ---------------------------------------------------------------------------
// Type 2 charstrings.

const max_stack = 48;
const max_depth = 10;
const max_steps = 1 << 20;
const max_coord = 1e7;

const Frame = struct {
    code: []const u8,
    pos: usize,
};

fn vec(x: f32, y: f32) Vec2 {
    return .{
        .x = x,
        .y = y,
    };
}

/// The charstring interpreter's state.
const Machine = struct {
    gsubrs: Index,
    lsubrs: Index,
    nominal_width: f32,
    /// The glyph's advance: defaultWidthX unless the charstring gives one.
    width: f32,
    stack: [max_stack]f32 = undefined,
    sp: usize = 0,
    transient: [32]f32 = @splat(0),
    x: f32 = 0,
    y: f32 = 0,
    start: Vec2 = .{},
    open: bool = false,
    stems: usize = 0,
    have_width: bool = false,

    fn push(m: *Machine, v: f32) Error!void {
        if (m.sp == max_stack) return error.InvalidGlyph;
        m.stack[m.sp] = v;
        m.sp += 1;
    }

    fn pop(m: *Machine) Error!f32 {
        if (m.sp == 0) return error.InvalidGlyph;
        m.sp -= 1;
        return m.stack[m.sp];
    }

    /// On the first stack-clearing operator, takes the leading width operand
    /// when `extra` says one is there. Returns the operands that remain.
    fn args(m: *Machine, extra: bool) []const f32 {
        var base: usize = 0;
        if (!m.have_width) {
            m.have_width = true;
            if (extra and m.sp > 0) {
                m.width = m.nominal_width + m.stack[0];
                base = 1;
            }
        }
        return m.stack[base..m.sp];
    }

    fn point(m: *const Machine) Error!Vec2 {
        if (!(@abs(m.x) < max_coord and @abs(m.y) < max_coord)) return error.InvalidGlyph;
        return vec(m.x, m.y);
    }

    fn closePath(m: *Machine, sink: anytype) Error!void {
        if (!m.open) return;
        m.open = false;
        if (m.x != m.start.x or m.y != m.start.y) try sink.lineTo(m.start);
        try sink.close();
    }

    fn ensureOpen(m: *Machine, sink: anytype) Error!void {
        if (m.open) return;
        m.start = try m.point();
        m.open = true;
        try sink.moveTo(m.start);
    }

    fn moveTo(m: *Machine, sink: anytype, dx: f32, dy: f32) Error!void {
        try m.closePath(sink);
        m.x += dx;
        m.y += dy;
        try m.ensureOpen(sink);
    }

    fn lineTo(m: *Machine, sink: anytype, dx: f32, dy: f32) Error!void {
        try m.ensureOpen(sink);
        m.x += dx;
        m.y += dy;
        try sink.lineTo(try m.point());
    }

    fn curveTo(m: *Machine, sink: anytype, dx1: f32, dy1: f32, dx2: f32, dy2: f32, dx3: f32, dy3: f32) Error!void {
        try m.ensureOpen(sink);
        m.x += dx1;
        m.y += dy1;
        const c1 = try m.point();
        m.x += dx2;
        m.y += dy2;
        const c2 = try m.point();
        m.x += dx3;
        m.y += dy3;
        try sink.cubicTo(c1, c2, try m.point());
    }

    /// hlineto / vlineto: lines alternating between horizontal and vertical.
    fn alternatingLines(m: *Machine, sink: anytype, a: []const f32, horizontal: bool) Error!void {
        if (a.len == 0) return error.InvalidGlyph;
        var h = horizontal;
        for (a) |d| {
            if (h) try m.lineTo(sink, d, 0) else try m.lineTo(sink, 0, d);
            h = !h;
        }
    }

    /// hvcurveto / vhcurveto: curves whose tangents alternate between
    /// horizontal and vertical; a fifth operand on the last one bends its end.
    fn alternatingCurves(m: *Machine, sink: anytype, a: []const f32, horizontal: bool) Error!void {
        if (a.len < 4) return error.InvalidGlyph;
        var i: usize = 0;
        var h = horizontal;
        while (a.len - i >= 4) {
            const last = a.len - i == 5;
            const e: f32 = if (last) a[i + 4] else 0;
            if (h)
                try m.curveTo(sink, a[i], 0, a[i + 1], a[i + 2], e, a[i + 3])
            else
                try m.curveTo(sink, 0, a[i], a[i + 1], a[i + 2], a[i + 3], e);
            i += if (last) 5 else 4;
            h = !h;
        }
    }

    fn need(a: []const f32, n: usize) Error!void {
        if (a.len < n) return error.InvalidGlyph;
    }

    fn int(v: f32) Error!i32 {
        if (!(@abs(v) < 1 << 24)) return error.InvalidGlyph;
        return @intFromFloat(@trunc(v));
    }

    /// Runs `code` to its endchar.
    fn run(m: *Machine, code: []const u8, sink: anytype) Error!void {
        var frames: [max_depth + 1]Frame = undefined;
        var depth: usize = 0;
        frames[0] = .{
            .code = code,
            .pos = 0,
        };
        var steps: u32 = 0;
        while (true) {
            steps += 1;
            if (steps > max_steps) return error.InvalidGlyph;
            const f = &frames[depth];
            const c = f.code;
            if (f.pos >= c.len) {
                // A charstring must end in endchar and a subroutine in
                // return (or endchar); accept a glyph that just stops.
                if (depth != 0) return error.InvalidGlyph;
                try m.closePath(sink);
                return;
            }
            const b0 = c[f.pos];
            f.pos += 1;
            switch (b0) {
                32...246 => {
                    try m.push(@floatFromInt(@as(i32, b0) - 139));
                    continue;
                },
                247...250 => {
                    if (f.pos >= c.len) return error.InvalidGlyph;
                    try m.push(@floatFromInt((@as(i32, b0) - 247) * 256 + c[f.pos] + 108));
                    f.pos += 1;
                    continue;
                },
                251...254 => {
                    if (f.pos >= c.len) return error.InvalidGlyph;
                    try m.push(@floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, c[f.pos]) - 108));
                    f.pos += 1;
                    continue;
                },
                28 => {
                    const v = r16(c, f.pos) orelse return error.InvalidGlyph;
                    f.pos += 2;
                    try m.push(@floatFromInt(@as(i16, @bitCast(v))));
                    continue;
                },
                255 => {
                    const v = readOffset(c, f.pos, 4) orelse return error.InvalidGlyph;
                    f.pos += 4;
                    try m.push(@as(f32, @floatFromInt(@as(i32, @bitCast(v)))) / 65536.0);
                    continue;
                },
                else => {},
            }
            // An operator.
            switch (b0) {
                // hstem, vstem, hstemhm, vstemhm
                1, 3, 18, 23 => {
                    const a = m.args(m.sp % 2 == 1);
                    m.stems += a.len / 2;
                },
                // hintmask, cntrmask: operands left on the stack are vstems.
                19, 20 => {
                    const a = m.args(m.sp % 2 == 1);
                    m.stems += a.len / 2;
                    const bytes = (m.stems + 7) / 8;
                    if (c.len - f.pos < bytes) return error.InvalidGlyph;
                    f.pos += bytes;
                },
                // rmoveto
                21 => {
                    const a = m.args(m.sp > 2);
                    try need(a, 2);
                    try m.moveTo(sink, a[0], a[1]);
                },
                // hmoveto
                22 => {
                    const a = m.args(m.sp > 1);
                    try need(a, 1);
                    try m.moveTo(sink, a[0], 0);
                },
                // vmoveto
                4 => {
                    const a = m.args(m.sp > 1);
                    try need(a, 1);
                    try m.moveTo(sink, 0, a[0]);
                },
                // rlineto
                5 => {
                    const a = m.stack[0..m.sp];
                    try need(a, 2);
                    var i: usize = 0;
                    while (i + 2 <= a.len) : (i += 2) try m.lineTo(sink, a[i], a[i + 1]);
                },
                6 => try m.alternatingLines(sink, m.stack[0..m.sp], true),
                7 => try m.alternatingLines(sink, m.stack[0..m.sp], false),
                // rrcurveto
                8 => {
                    const a = m.stack[0..m.sp];
                    try need(a, 6);
                    var i: usize = 0;
                    while (i + 6 <= a.len) : (i += 6) try m.curveTo(sink, a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
                },
                // hhcurveto: {dxa dxb dyb dxc}+ after an optional dy1.
                27 => {
                    const a = m.stack[0..m.sp];
                    try need(a, 4);
                    var i: usize = a.len % 4;
                    var dy1: f32 = if (i > 0) a[0] else 0;
                    while (i + 4 <= a.len) : (i += 4) {
                        try m.curveTo(sink, a[i], dy1, a[i + 1], a[i + 2], a[i + 3], 0);
                        dy1 = 0;
                    }
                },
                // vvcurveto: {dya dxb dyb dyc}+ after an optional dx1.
                26 => {
                    const a = m.stack[0..m.sp];
                    try need(a, 4);
                    var i: usize = a.len % 4;
                    var dx1: f32 = if (i > 0) a[0] else 0;
                    while (i + 4 <= a.len) : (i += 4) {
                        try m.curveTo(sink, dx1, a[i], a[i + 1], a[i + 2], 0, a[i + 3]);
                        dx1 = 0;
                    }
                },
                31 => try m.alternatingCurves(sink, m.stack[0..m.sp], true),
                30 => try m.alternatingCurves(sink, m.stack[0..m.sp], false),
                // rcurveline: curves, then one line.
                24 => {
                    const a = m.stack[0..m.sp];
                    try need(a, 8);
                    var i: usize = 0;
                    while (a.len - i >= 8) : (i += 6) try m.curveTo(sink, a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
                    try m.lineTo(sink, a[i], a[i + 1]);
                },
                // rlinecurve: lines, then one curve.
                25 => {
                    const a = m.stack[0..m.sp];
                    try need(a, 8);
                    var i: usize = 0;
                    while (a.len - i >= 8) : (i += 2) try m.lineTo(sink, a[i], a[i + 1]);
                    try m.curveTo(sink, a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
                },
                // callsubr, callgsubr
                10, 29 => {
                    const subrs = if (b0 == 10) m.lsubrs else m.gsubrs;
                    const n = try int(try m.pop()) + subrs.bias();
                    if (n < 0) return error.InvalidGlyph;
                    if (depth == max_depth) return error.InvalidGlyph;
                    const sub = subrs.get(@intCast(n)) orelse return error.InvalidGlyph;
                    depth += 1;
                    frames[depth] = .{
                        .code = sub,
                        .pos = 0,
                    };
                    continue;
                },
                // return
                11 => {
                    if (depth == 0) return error.InvalidGlyph;
                    depth -= 1;
                    continue;
                },
                // endchar (four more operands are the seac accent, not drawn).
                14 => {
                    _ = m.args(m.sp == 1 or m.sp == 5);
                    try m.closePath(sink);
                    return;
                },
                12 => {
                    if (f.pos >= c.len) return error.InvalidGlyph;
                    const b1 = c[f.pos];
                    f.pos += 1;
                    if (try m.escaped(sink, b1)) continue;
                },
                else => return error.InvalidGlyph,
            }
            m.sp = 0;
        }
    }

    /// Runs escaped operator `op`. Returns true when the stack is kept
    /// (arithmetic), false when the operator clears it.
    fn escaped(m: *Machine, sink: anytype, op: u8) Error!bool {
        const a = m.stack[0..m.sp];
        switch (op) {
            // flex: two curves (the depth operand is ignored).
            35 => {
                try need(a, 13);
                try m.curveTo(sink, a[0], a[1], a[2], a[3], a[4], a[5]);
                try m.curveTo(sink, a[6], a[7], a[8], a[9], a[10], a[11]);
            },
            // hflex: dx1 dx2 dy2 dx3 dx4 dx5 dx6
            34 => {
                try need(a, 7);
                try m.curveTo(sink, a[0], 0, a[1], a[2], a[3], 0);
                try m.curveTo(sink, a[4], 0, a[5], -a[2], a[6], 0);
            },
            // hflex1: dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
            36 => {
                try need(a, 9);
                try m.curveTo(sink, a[0], a[1], a[2], a[3], a[4], 0);
                try m.curveTo(sink, a[5], 0, a[6], a[7], a[8], -(a[1] + a[3] + a[7]));
            },
            // flex1: five points, the last coordinate pair from d6 and the
            // direction that moved most.
            37 => {
                try need(a, 11);
                const dx = a[0] + a[2] + a[4] + a[6] + a[8];
                const dy = a[1] + a[3] + a[5] + a[7] + a[9];
                const horizontal = @abs(dx) > @abs(dy);
                try m.curveTo(sink, a[0], a[1], a[2], a[3], a[4], a[5]);
                if (horizontal)
                    try m.curveTo(sink, a[6], a[7], a[8], a[9], a[10], -dy)
                else
                    try m.curveTo(sink, a[6], a[7], a[8], a[9], -dx, a[10]);
            },
            else => {
                try m.arithmetic(op);
                return true;
            },
        }
        return false;
    }

    /// The arithmetic, storage and stack operators.
    fn arithmetic(m: *Machine, op: u8) Error!void {
        switch (op) {
            // and, or, eq, add, sub, div, mul
            3, 4, 15, 10, 11, 12, 24 => {
                const b = try m.pop();
                const a = try m.pop();
                try m.push(switch (op) {
                    3 => @floatFromInt(@intFromBool(a != 0 and b != 0)),
                    4 => @floatFromInt(@intFromBool(a != 0 or b != 0)),
                    15 => @floatFromInt(@intFromBool(a == b)),
                    10 => a + b,
                    11 => a - b,
                    12 => if (b == 0) return error.InvalidGlyph else a / b,
                    else => a * b,
                });
            },
            // not, abs, neg, sqrt
            5, 9, 14, 26 => {
                const a = try m.pop();
                try m.push(switch (op) {
                    5 => @floatFromInt(@intFromBool(a == 0)),
                    9 => @abs(a),
                    14 => -a,
                    else => if (a < 0) return error.InvalidGlyph else @sqrt(a),
                });
            },
            // drop
            18 => _ = try m.pop(),
            // put: val i
            20 => {
                const i = try int(try m.pop());
                const v = try m.pop();
                if (i < 0 or i >= m.transient.len) return error.InvalidGlyph;
                m.transient[@intCast(i)] = v;
            },
            // get: i
            21 => {
                const i = try int(try m.pop());
                if (i < 0 or i >= m.transient.len) return error.InvalidGlyph;
                try m.push(m.transient[@intCast(i)]);
            },
            // ifelse: s1 s2 v1 v2
            22 => {
                const v2 = try m.pop();
                const v1 = try m.pop();
                const s2 = try m.pop();
                const s1 = try m.pop();
                try m.push(if (v1 <= v2) s1 else s2);
            },
            // random: a fixed value in (0, 1], so outlines stay reproducible.
            23 => try m.push(0.5),
            // dup
            27 => {
                const a = try m.pop();
                try m.push(a);
                try m.push(a);
            },
            // exch
            28 => {
                const b = try m.pop();
                const a = try m.pop();
                try m.push(b);
                try m.push(a);
            },
            // index: copies the element `i` below the top (the top for i < 0).
            29 => {
                const i = try int(try m.pop());
                if (m.sp == 0) return error.InvalidGlyph;
                const k: usize = if (i < 0) 0 else @intCast(i);
                if (k >= m.sp) return error.InvalidGlyph;
                try m.push(m.stack[m.sp - 1 - k]);
            },
            // roll: N J rotates the top N elements by J.
            30 => {
                const j = try int(try m.pop());
                const n = try int(try m.pop());
                if (n < 0 or n > m.sp) return error.InvalidGlyph;
                if (n == 0) return;
                const top = m.stack[m.sp - @as(usize, @intCast(n)) .. m.sp];
                const shift: usize = @intCast(@mod(j, n));
                if (shift != 0) std.mem.rotate(f32, top, top.len - shift);
            },
            else => return error.InvalidGlyph,
        }
    }
};

/// A sink that measures the exact bounds of an outline (curve extrema
/// included), in font units.
pub const Bounds = struct {
    /// The bounds so far; empty until a point is added.
    rect: geom.Rect = .empty,
    cur: Vec2 = .{},

    /// Starts a contour at `p`.
    pub fn moveTo(b: *Bounds, p: Vec2) error{}!void {
        b.rect.include(p);
        b.cur = p;
    }

    /// A line to `p`.
    pub fn lineTo(b: *Bounds, p: Vec2) error{}!void {
        b.rect.include(p);
        b.cur = p;
    }

    /// A cubic to `p`; its extrema between the end points count too.
    pub fn cubicTo(b: *Bounds, c1: Vec2, c2: Vec2, p: Vec2) error{}!void {
        const p0 = b.cur;
        b.rect.include(p);
        b.cur = p;
        var ts: [4]f32 = undefined;
        var n: usize = 0;
        inline for (.{ "x", "y" }) |axis| {
            const a = @field(c1, axis) - @field(p0, axis);
            const bb = @field(c2, axis) - @field(c1, axis);
            const cc = @field(p, axis) - @field(c2, axis);
            // Derivative / 3: A t^2 + B t + C.
            const qa = a - 2 * bb + cc;
            const qb = 2 * (bb - a);
            const qc = a;
            if (@abs(qa) < 1e-9) {
                if (@abs(qb) > 1e-9) {
                    ts[n] = -qc / qb;
                    n += 1;
                }
            } else {
                const disc = qb * qb - 4 * qa * qc;
                if (disc >= 0) {
                    const s = @sqrt(disc);
                    ts[n] = (-qb + s) / (2 * qa);
                    ts[n + 1] = (-qb - s) / (2 * qa);
                    n += 2;
                }
            }
        }
        for (ts[0..n]) |t| {
            if (t > 0 and t < 1) b.rect.include(geom.cubicAt(p0, c1, c2, p, t));
        }
    }

    /// Ends a contour.
    pub fn close(b: *Bounds) error{}!void {
        _ = b;
    }
};

// ---------------------------------------------------------------------------
// Tests.

const testing = std.testing;

/// Appends charstring / DICT integer `v` in its shortest Type 2 encoding.
fn testNum(out: *std.ArrayList(u8), v: i32) !void {
    const gpa = testing.allocator;
    if (v >= -107 and v <= 107) {
        try out.append(gpa, @intCast(v + 139));
    } else if (v >= 108 and v <= 1131) {
        const w = v - 108;
        try out.appendSlice(gpa, &.{ @intCast(247 + (w >> 8)), @intCast(w & 255) });
    } else if (v >= -1131 and v <= -108) {
        const w = -v - 108;
        try out.appendSlice(gpa, &.{ @intCast(251 + (w >> 8)), @intCast(w & 255) });
    } else {
        const u: u16 = @bitCast(@as(i16, @intCast(v)));
        try out.appendSlice(gpa, &.{ 28, @intCast(u >> 8), @intCast(u & 255) });
    }
}

/// A charstring from a list of numbers, operators, raw bytes and nested
/// lists: `.{ .{ 10, 20, .rmoveto }, .endchar }`.
fn testCharstring(comptime items: anytype) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    inline for (items) |it| {
        switch (@typeInfo(@TypeOf(it))) {
            .comptime_int, .int => try testNum(&out, it),
            .enum_literal => {
                const code: u16 = @field(TestOp, @tagName(it));
                if (code >= 1200) try out.appendSlice(testing.allocator, &.{ 12, @intCast(code - 1200) }) else try out.append(testing.allocator, @intCast(code));
            },
            .pointer => try out.appendSlice(testing.allocator, it),
            .@"struct" => {
                const part = try testCharstring(it);
                defer testing.allocator.free(part);
                try out.appendSlice(testing.allocator, part);
            },
            else => @compileError("bad charstring item"),
        }
    }
    return out.toOwnedSlice(testing.allocator);
}

const TestOp = struct {
    const hstem = 1;
    const vmoveto = 4;
    const rlineto = 5;
    const hlineto = 6;
    const vlineto = 7;
    const rrcurveto = 8;
    const callsubr = 10;
    const @"return" = 11;
    const endchar = 14;
    const hintmask = 19;
    const rmoveto = 21;
    const hmoveto = 22;
    const rcurveline = 24;
    const vvcurveto = 26;
    const hhcurveto = 27;
    const callgsubr = 29;
    const vhcurveto = 30;
    const hvcurveto = 31;
    const hflex = 1234;
    const flex = 1235;
    const add = 1210;
};

/// Appends an INDEX of `items`, with 4-byte offsets.
fn testIndex(out: *std.ArrayList(u8), items: []const []const u8) !void {
    const gpa = testing.allocator;
    try out.appendSlice(gpa, &.{ @intCast(items.len >> 8), @intCast(items.len & 255) });
    if (items.len == 0) return;
    try out.append(gpa, 4);
    var off: u32 = 1;
    for (0..items.len + 1) |k| {
        try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, off)));
        if (k < items.len) off += @intCast(items[k].len);
    }
    for (items) |it| try out.appendSlice(gpa, it);
}

/// A DICT entry with 5-byte integer operands, so its size never depends on values.
fn testDictOp(out: *std.ArrayList(u8), operands: []const i32, op: u16) !void {
    const gpa = testing.allocator;
    for (operands) |v| {
        try out.append(gpa, 29);
        try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(i32, v)));
    }
    if (op >= 1200) try out.appendSlice(gpa, &.{ 12, @intCast(op - 1200) }) else try out.append(gpa, @intCast(op));
}

/// Builds a CFF table with the given charstrings, global and local subrs.
/// CID-keyed when `cid`: two Font DICTs, glyph 0 in the first and every
/// other glyph in the second (FDSelect format 3); only the second has the
/// local subrs.
fn testCff(glyphs: []const []const u8, gsubrs: []const []const u8, lsubrs: []const []const u8, cid: bool) ![]u8 {
    const gpa = testing.allocator;
    // Fixed-size parts first, so the offsets can be computed.
    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(gpa);
    try testIndex(&name, &.{"T"});
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(gpa);
    try testIndex(&strings, &.{});
    var globals: std.ArrayList(u8) = .empty;
    defer globals.deinit(gpa);
    try testIndex(&globals, gsubrs);
    var chars: std.ArrayList(u8) = .empty;
    defer chars.deinit(gpa);
    try testIndex(&chars, glyphs);
    var locals: std.ArrayList(u8) = .empty;
    defer locals.deinit(gpa);
    try testIndex(&locals, lsubrs);

    // Private DICT: Subrs (relative to the DICT), widths. Fixed size 3 x 5 + 3 + 5 + 1.
    const priv_len = 5 + 1 + 5 + 1 + 5 + 1;
    var priv: std.ArrayList(u8) = .empty;
    defer priv.deinit(gpa);
    try testDictOp(&priv, &.{priv_len}, op_subrs);
    try testDictOp(&priv, &.{600}, op_default_width);
    try testDictOp(&priv, &.{500}, op_nominal_width);
    try testing.expectEqual(@as(usize, priv_len), priv.items.len);

    const top_len: usize = if (cid) 3 * 5 + 2 + 5 + 1 + 5 + 2 + 5 + 2 else 5 + 1 + 2 * 5 + 1;
    const header = [_]u8{ 1, 0, 4, 4 };
    const top_index_len = 2 + 1 + 8 + top_len;
    const after_top = header.len + name.items.len + top_index_len;
    const cs_at = after_top + strings.items.len + globals.items.len;
    const priv_at = cs_at + chars.items.len;
    const locals_at = priv_at + priv.items.len;
    const fds_at = locals_at + locals.items.len;

    // CID: FDArray of two Font DICTs (Private size offset), then FDSelect.
    var fd0: std.ArrayList(u8) = .empty;
    defer fd0.deinit(gpa);
    try testDictOp(&fd0, &.{ 0, @intCast(priv_at) }, op_private);
    var fd1: std.ArrayList(u8) = .empty;
    defer fd1.deinit(gpa);
    try testDictOp(&fd1, &.{ priv_len, @intCast(priv_at) }, op_private);
    var fdarray: std.ArrayList(u8) = .empty;
    defer fdarray.deinit(gpa);
    try testIndex(&fdarray, &.{ fd0.items, fd1.items });
    const fdselect_at = fds_at + fdarray.items.len;
    var fdselect: std.ArrayList(u8) = .empty;
    defer fdselect.deinit(gpa);
    const n: u16 = @intCast(glyphs.len);
    try fdselect.appendSlice(gpa, &.{ 3, 0, 2, 0, 0, 0, 0, 1, 1, @intCast(n >> 8), @intCast(n & 255) });

    var top: std.ArrayList(u8) = .empty;
    defer top.deinit(gpa);
    if (cid) {
        try testDictOp(&top, &.{ 0, 0, 0 }, op_ros);
        try testDictOp(&top, &.{@intCast(cs_at)}, op_char_strings);
        try testDictOp(&top, &.{@intCast(fds_at)}, op_fd_array);
        try testDictOp(&top, &.{@intCast(fdselect_at)}, op_fd_select);
    } else {
        try testDictOp(&top, &.{@intCast(cs_at)}, op_char_strings);
        try testDictOp(&top, &.{ priv_len, @intCast(priv_at) }, op_private);
    }
    try testing.expectEqual(top_len, top.items.len);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &header);
    try out.appendSlice(gpa, name.items);
    try testIndex(&out, &.{top.items});
    try testing.expectEqual(after_top, out.items.len);
    try out.appendSlice(gpa, strings.items);
    try out.appendSlice(gpa, globals.items);
    try out.appendSlice(gpa, chars.items);
    try out.appendSlice(gpa, priv.items);
    try out.appendSlice(gpa, locals.items);
    if (cid) {
        try out.appendSlice(gpa, fdarray.items);
        try out.appendSlice(gpa, fdselect.items);
    }
    return out.toOwnedSlice(gpa);
}

/// Records the sink calls as text, one per line.
const TestSink = struct {
    out: std.ArrayList(u8) = .empty,

    fn put(s: *TestSink, comptime fmt: []const u8, args: anytype) !void {
        try s.out.print(testing.allocator, fmt, args);
    }

    pub fn moveTo(s: *TestSink, p: Vec2) !void {
        try s.put("M{d},{d} ", .{ p.x, p.y });
    }

    pub fn lineTo(s: *TestSink, p: Vec2) !void {
        try s.put("L{d},{d} ", .{ p.x, p.y });
    }

    pub fn cubicTo(s: *TestSink, c1: Vec2, c2: Vec2, p: Vec2) !void {
        try s.put("C{d},{d},{d},{d},{d},{d} ", .{ c1.x, c1.y, c2.x, c2.y, p.x, p.y });
    }

    pub fn close(s: *TestSink) !void {
        try s.put("Z ", .{});
    }
};

fn expectOutline(c: *const Cff, glyph: u16, want: []const u8, want_width: f32) !void {
    var s: TestSink = .{};
    defer s.out.deinit(testing.allocator);
    const w = try c.outline(glyph, &s);
    try testing.expectEqualStrings(want, std.mem.trimEnd(u8, s.out.items, " "));
    try testing.expectEqual(want_width, w);
}

test "hand-built CFF: moves, lines, curves, subroutines, widths" {
    const gpa = testing.allocator;
    const notdef = try testCharstring(.{.endchar});
    defer gpa.free(notdef);
    // A square: width operand on rmoveto, lines, the last side in a local subr;
    // then a second contour of curves from a global subr.
    const square = try testCharstring(.{
        .{ 10, 100, 100, .rmoveto },
        .{ 200, 0, .rlineto },
        .{ 200, .vlineto },
        .{ -107, .callsubr },
        .{ 0, -150, .rmoveto },
        .{ -107, .callgsubr },
        .endchar,
    });
    defer gpa.free(square);
    const lsub = try testCharstring(.{ -200, .hlineto, .@"return" });
    defer gpa.free(lsub);
    const gsub = try testCharstring(.{ 10, 20, 30, 40, .hhcurveto, 5, 10, 20, 30, 40, .vvcurveto, .@"return" });
    defer gpa.free(gsub);
    // Stem hints and a hintmask before the first move, no width (default).
    const hinted = try testCharstring(.{ 0, 10, 20, 10, .hstem, 0, 10, .hintmask, &[_]u8{0xC0}, 50, .hmoveto, 30, 40, 50, 60, .hvcurveto, 1, 2, 3, 4, 5, .vhcurveto, .endchar });
    defer gpa.free(hinted);
    // flex, hflex, rcurveline and arithmetic.
    const flexy = try testCharstring(.{
        .{ 7, .vmoveto },
        .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 50, .flex },
        .{ 1, 2, 3, 4, 5, 6, 7, .hflex },
        .{ 1, 2, 3, 4, 5, 6, 7, 8, .rcurveline },
        .{ 2, 3, .add, 4, .rlineto },
        .endchar,
    });
    defer gpa.free(flexy);
    const bytes = try testCff(&.{ notdef, square, hinted, flexy }, &.{gsub}, &.{lsub}, false);
    defer gpa.free(bytes);

    for ([_]bool{ false, true }) |cid| {
        const data = if (cid) try testCff(&.{ notdef, square, hinted, flexy }, &.{gsub}, &.{lsub}, true) else bytes;
        defer if (cid) gpa.free(data);
        const c = try Cff.init(data);
        try testing.expectEqual(@as(u32, 4), c.glyphCount());
        try testing.expectEqual(cid, c.fd_select != 0);
        // .notdef: no outline, the default width (none in the CID font's first Font DICT).
        try expectOutline(&c, 0, "", if (cid) 0 else 600);
        try expectOutline(&c, 1, "M100,100 L300,100 L300,300 L100,300 L100,100 Z " ++
            "M100,150 C110,150,130,180,170,180 C175,190,195,220,195,260 L100,150 Z", 510);
        try expectOutline(&c, 2, "M50,0 C80,0,120,50,120,110 C120,111,122,114,126,119 L50,0 Z", 600);
        try expectOutline(&c, 3, "M0,7 C1,9,4,13,9,19 C16,27,25,37,36,49 " ++
            "C37,49,39,52,43,52 C48,52,54,49,61,49 " ++
            "C62,51,65,55,70,61 L77,69 L82,73 L0,7 Z", 600);
    }
}

test "corrupt CFF data is an error, never a crash" {
    const gpa = testing.allocator;
    const notdef = try testCharstring(.{.endchar});
    defer gpa.free(notdef);
    // A subroutine that calls itself: depth limit.
    const loop = try testCharstring(.{ -107, .callsubr });
    defer gpa.free(loop);
    const calls_loop = try testCharstring(.{ 0, 0, .rmoveto, -107, .callsubr, .endchar });
    defer gpa.free(calls_loop);
    // Missing subr, stack underflow, stack overflow, truncated number, bad operator.
    const missing = try testCharstring(.{ 5, .callgsubr, .endchar });
    defer gpa.free(missing);
    const underflow = try testCharstring(.{ 1, .rlineto, .endchar });
    defer gpa.free(underflow);
    var overflow: std.ArrayList(u8) = .empty;
    defer overflow.deinit(gpa);
    for (0..60) |_| try overflow.append(gpa, 139);
    const truncated = [_]u8{28};
    const reserved = [_]u8{ 139, 139, 2 };
    const glyphs = [_][]const u8{ notdef, calls_loop, missing, underflow, overflow.items, &truncated, &reserved };
    const bytes = try testCff(&glyphs, &.{}, &.{loop}, false);
    defer gpa.free(bytes);
    const c = try Cff.init(bytes);
    for (1..glyphs.len) |g| {
        var s: TestSink = .{};
        defer s.out.deinit(gpa);
        try testing.expectError(error.InvalidGlyph, c.outline(@intCast(g), &s));
    }
    var s: TestSink = .{};
    defer s.out.deinit(gpa);
    try testing.expectError(error.InvalidGlyph, c.outline(99, &s));

    // Every truncation and every single-byte change of the table is
    // rejected or read, never a crash.
    for (0..bytes.len) |cut| _ = Cff.init(bytes[0..cut]) catch {};
    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    for (0..copy.len) |k| {
        for ([_]u8{ 0, 1, 12, 28, 30, 255 }) |v| {
            @memcpy(copy, bytes);
            copy[k] = v;
            const cc = Cff.init(copy) catch continue;
            for (0..glyphs.len) |g| {
                var b: Bounds = .{};
                _ = cc.outline(@intCast(g), &b) catch {};
            }
        }
    }
}

test "Bounds includes curve extrema" {
    var b: Bounds = .{};
    try b.moveTo(vec(0, 0));
    try b.cubicTo(vec(0, 100), vec(100, 100), vec(100, 0));
    try testing.expectApproxEqAbs(@as(f32, 75), b.rect.y1, 1e-3);
    try testing.expectEqual(@as(f32, 0), b.rect.x0);
    try testing.expectEqual(@as(f32, 100), b.rect.x1);
}
