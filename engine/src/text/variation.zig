//! OpenType font variations: axes and named instances (fvar), axis value
//! mapping (avar), item variation stores (shared by HVAR, MVAR and GDEF),
//! glyph outline deltas (gvar) and GSUB/GPOS FeatureVariations.
//!
//! Written from the OpenType 1.9 specification ("OpenType Font Variations
//! Overview" and the fvar, avar, gvar, HVAR, MVAR, GDEF and "OpenType
//! Layout Common Table Formats" chapters). As in font.zig, every read is
//! bounds-checked: malformed data yields no delta, never a panic.

const std = @import("std");
const geom = @import("../raster/geom.zig");
const font_mod = @import("font.zig");
const r16 = font_mod.r16;
const ri16 = font_mod.ri16;
const r32 = font_mod.r32;

/// Most axes a font instance carries coordinates for; axes past this stay at
/// their default.
pub const max_axes = 16;

/// A variation axis from fvar, in user units.
pub const Axis = struct {
    tag: [4]u8,
    min: f32,
    default: f32,
    max: f32,
    /// The axis name from the name table ("Weight"), or "".
    name: []const u8,
    /// True when fvar flags the axis as hidden from users.
    hidden: bool,
};

/// A requested axis setting, in user units (`wght` 500).
pub const AxisValue = struct {
    tag: [4]u8,
    value: f32,
};

/// A named instance from fvar ("Medium": wght 500).
pub const NamedInstance = struct {
    /// Subfamily name from the name table ("Medium").
    subfamily: []const u8,
    /// PostScript name, when fvar gives one.
    postscript_name: ?[]const u8,
    /// The instance's coordinates, one per axis in fvar order, in user units.
    values: []const AxisValue,
};

/// The variation tables of a font (empty slices when absent).
pub const Tables = struct {
    fvar: []const u8 = &.{},
    avar: []const u8 = &.{},
    gvar: []const u8 = &.{},
    hvar: []const u8 = &.{},
    mvar: []const u8 = &.{},
    /// Offset of the GDEF ItemVariationStore in the GDEF table (0 when none).
    gdef_store: usize = 0,
};

/// Rounds a normalized coordinate to F2Dot14 precision.
pub fn quantize(v: f32) f32 {
    return @round(std.math.clamp(v, -1, 1) * 16384) / 16384;
}

/// Reads an F2Dot14 value as f32.
pub fn f2dot14(d: []const u8, off: usize) f32 {
    return @as(f32, @floatFromInt(ri16(d, off))) / 16384.0;
}

fn fixed(d: []const u8, off: usize) f32 {
    const v: i32 = @bitCast(r32(d, off));
    return @as(f32, @floatFromInt(v)) / 65536.0;
}

// ---------------------------------------------------------------------------
// fvar and avar.

/// The fvar header fields the rest of the code needs.
pub const Fvar = struct {
    axes_at: usize,
    axis_count: usize,
    axis_size: usize,
    instance_count: usize,
    instance_size: usize,

    /// Reads the fvar header; null when the table is missing or malformed.
    pub fn init(d: []const u8) ?Fvar {
        if (d.len < 16 or r16(d, 0) != 1) return null;
        const f: Fvar = .{
            .axes_at = r16(d, 4),
            .axis_count = r16(d, 8),
            .axis_size = r16(d, 10),
            .instance_count = r16(d, 12),
            .instance_size = r16(d, 14),
        };
        if (f.axis_count == 0 or f.axis_size < 20) return null;
        if (f.axes_at + f.axis_count * f.axis_size > d.len) return null;
        return f;
    }

    /// Offset of instance record `k` (null when outside the table).
    fn instance(f: Fvar, d: []const u8, k: usize) ?usize {
        const at = f.axes_at + f.axis_count * f.axis_size + k * f.instance_size;
        if (f.instance_size < 4 + f.axis_count * 4 or at + f.instance_size > d.len) return null;
        return at;
    }
};

/// Reads the fvar axes into `arena`, naming them through `nameFn(ctx, id)`.
pub fn readAxes(arena: std.mem.Allocator, d: []const u8, ctx: anytype, comptime nameFn: fn (@TypeOf(ctx), u16) std.mem.Allocator.Error!?[]const u8) ![]const Axis {
    const f = Fvar.init(d) orelse return &.{};
    const axes = try arena.alloc(Axis, f.axis_count);
    for (axes, 0..) |*a, k| {
        const rec = f.axes_at + k * f.axis_size;
        const lo = fixed(d, rec + 4);
        const def = fixed(d, rec + 8);
        const hi = fixed(d, rec + 12);
        a.* = .{
            .tag = d[rec..][0..4].*,
            // A malformed range collapses onto the default.
            .min = @min(lo, def),
            .default = def,
            .max = @max(hi, def),
            .name = try nameFn(ctx, r16(d, rec + 18)) orelse "",
            .hidden = r16(d, rec + 16) & 1 != 0,
        };
    }
    return axes;
}

/// Reads the fvar named instances into `arena`.
pub fn readInstances(arena: std.mem.Allocator, d: []const u8, axes: []const Axis, ctx: anytype, comptime nameFn: fn (@TypeOf(ctx), u16) std.mem.Allocator.Error!?[]const u8) ![]NamedInstance {
    const f = Fvar.init(d) orelse return &.{};
    if (axes.len != f.axis_count) return &.{};
    var out: std.ArrayList(NamedInstance) = .empty;
    for (0..f.instance_count) |k| {
        const rec = f.instance(d, k) orelse break;
        const values = try arena.alloc(AxisValue, f.axis_count);
        for (values, axes, 0..) |*v, a, i| v.* = .{
            .tag = a.tag,
            .value = fixed(d, rec + 4 + i * 4),
        };
        var ps: ?[]const u8 = null;
        if (f.instance_size >= 6 + f.axis_count * 4) {
            const id = r16(d, rec + 4 + f.axis_count * 4);
            if (id != 0xFFFF) ps = try nameFn(ctx, id);
        }
        try out.append(arena, .{
            .subfamily = try nameFn(ctx, r16(d, rec)) orelse "",
            .postscript_name = ps,
            .values = values,
        });
    }
    return out.items;
}

/// Normalizes a user value of `axis` to [-1, 1] (default 0), at 16.16
/// precision; `applyAvar` maps it and rounds it to F2Dot14.
pub fn normalize(axis: Axis, user: f32) f32 {
    const v = std.math.clamp(user, axis.min, axis.max);
    var n: f32 = 0;
    if (v < axis.default and axis.default > axis.min) {
        n = (v - axis.default) / (axis.default - axis.min);
    } else if (v > axis.default and axis.max > axis.default) {
        n = (v - axis.default) / (axis.max - axis.default);
    }
    return @round(std.math.clamp(n, -1, 1) * 65536) / 65536;
}

/// Maps normalized coordinates through avar (version 1 segment maps) and
/// rounds them to F2Dot14, the precision the variation tables work at.
pub fn applyAvar(d: []const u8, coords: []f32) void {
    defer for (coords) |*c| {
        c.* = quantize(c.*);
    };
    if (d.len < 8 or r16(d, 0) != 1) return;
    const axis_count: usize = r16(d, 6);
    var p: usize = 8;
    for (0..axis_count) |i| {
        const n: usize = r16(d, p);
        const maps = p + 2;
        p = maps + n * 4;
        if (p > d.len) return;
        if (i >= coords.len or n == 0) continue;
        coords[i] = mapSegment(d, maps, n, coords[i]);
    }
}

fn mapSegment(d: []const u8, maps: usize, n: usize, v: f32) f32 {
    const from0 = f2dot14(d, maps);
    if (v <= from0) return quantize(f2dot14(d, maps + 2) + (v - from0));
    for (1..n) |k| {
        const from = f2dot14(d, maps + k * 4);
        const to = f2dot14(d, maps + k * 4 + 2);
        if (v > from) continue;
        if (v == from) return to;
        const pf = f2dot14(d, maps + (k - 1) * 4);
        const pt = f2dot14(d, maps + (k - 1) * 4 + 2);
        if (from <= pf) return to;
        return quantize(pt + (v - pf) * (to - pt) / (from - pf));
    }
    const last = maps + (n - 1) * 4;
    return quantize(f2dot14(d, last + 2) + (v - f2dot14(d, last)));
}

// ---------------------------------------------------------------------------
// Item variation stores and delta-set index maps.

/// The scalar of one axis of a region or tuple: 1 outside the axis' say,
/// 0 outside its range, else the position on the tent.
fn axisScalar(start: f32, peak: f32, end: f32, v: f32) f32 {
    if (peak == 0 or v == peak) return 1;
    // Malformed ranges, and ranges across zero, put no constraint on the axis.
    if (start > peak or peak > end) return 1;
    if (start < 0 and end > 0) return 1;
    if (v <= start or v >= end) return 0;
    if (v < peak) return (v - start) / (peak - start);
    return (end - v) / (end - peak);
}

/// Scalar of region `index` of the VariationRegionList at `list`.
fn regionScalar(d: []const u8, list: usize, index: usize, coords: []const f32) f32 {
    const axis_count: usize = r16(d, list);
    const count: usize = r16(d, list + 2);
    if (index >= count) return 0;
    const rec = list + 4 + index * axis_count * 6;
    if (rec + axis_count * 6 > d.len) return 0;
    var s: f32 = 1;
    for (0..axis_count) |a| {
        const v: f32 = if (a < coords.len) coords[a] else 0;
        s *= axisScalar(f2dot14(d, rec + a * 6), f2dot14(d, rec + a * 6 + 2), f2dot14(d, rec + a * 6 + 4), v);
        if (s == 0) return 0;
    }
    return s;
}

/// The delta for (outer, inner) of the ItemVariationStore at `store` in `d`,
/// at `coords`. Zero for missing entries.
pub fn storeDelta(d: []const u8, store: usize, outer: u16, inner: u16, coords: []const f32) f32 {
    if (store == 0 or r16(d, store) != 1) return 0;
    const list_off = r32(d, store + 2);
    if (list_off == 0) return 0;
    const list = store + list_off;
    if (outer >= r16(d, store + 6)) return 0;
    const data_off = r32(d, store + 8 + @as(usize, outer) * 4);
    if (data_off == 0) return 0;
    const ivd = store + data_off;
    const items = r16(d, ivd);
    const word_field = r16(d, ivd + 2);
    const long = word_field & 0x8000 != 0;
    const words: usize = word_field & 0x7FFF;
    const regions: usize = r16(d, ivd + 4);
    if (inner >= items or words > regions) return 0;
    const wsize: usize = if (long) 4 else 2;
    const ssize: usize = if (long) 2 else 1;
    const row_size = words * wsize + (regions - words) * ssize;
    const rows = ivd + 6 + regions * 2;
    const row = rows + @as(usize, inner) * row_size;
    if (row + row_size > d.len) return 0;
    var sum: f32 = 0;
    var p = row;
    for (0..regions) |k| {
        const delta: i32 = if (k < words)
            (if (long) @as(i32, @bitCast(r32(d, p))) else ri16(d, p))
        else if (long)
            ri16(d, p)
        else
            @as(i8, @bitCast(d[p]));
        p += if (k < words) wsize else ssize;
        if (delta == 0) continue;
        const s = regionScalar(d, list, r16(d, ivd + 6 + k * 2), coords);
        sum += s * @as(f32, @floatFromInt(delta));
    }
    return sum;
}

/// An (outer, inner) delta-set index.
pub const DeltaIndex = struct {
    outer: u16,
    inner: u16,
};

/// Entry `i` of the DeltaSetIndexMap at `map` (the last entry for larger
/// indices; null when the map is malformed or empty).
pub fn mapIndex(d: []const u8, map: usize, i: u32) ?DeltaIndex {
    const format = if (map < d.len) d[map] else return null;
    if (map + 2 > d.len) return null;
    const entry_format = d[map + 1];
    var count: u32 = 0;
    var entries: usize = 0;
    if (format == 0) {
        count = r16(d, map + 2);
        entries = map + 4;
    } else if (format == 1) {
        count = r32(d, map + 2);
        entries = map + 6;
    } else return null;
    if (count == 0) return null;
    const size: usize = ((entry_format & 0x30) >> 4) + 1;
    const inner_bits: u5 = @intCast((entry_format & 0x0F) + 1);
    const at = entries + @as(usize, @min(i, count - 1)) * size;
    if (at + size > d.len) return null;
    var v: u32 = 0;
    for (d[at .. at + size]) |b| v = v << 8 | b;
    return .{
        .outer = @truncate(v >> inner_bits),
        .inner = @truncate(v & ((@as(u32, 1) << inner_bits) - 1)),
    };
}

/// HVAR advance-width delta of `glyph`, in font units (unrounded).
pub fn hvarAdvanceDelta(d: []const u8, glyph: u16, coords: []const f32) f32 {
    return hvarDelta(d, 8, glyph, coords) orelse 0;
}

/// HVAR left-side-bearing delta of `glyph`, or null when HVAR has no
/// left-side-bearing mapping.
pub fn hvarLsbDelta(d: []const u8, glyph: u16, coords: []const f32) ?f32 {
    if (r32(d, 12) == 0) return null;
    return hvarDelta(d, 12, glyph, coords);
}

fn hvarDelta(d: []const u8, map_field: usize, glyph: u16, coords: []const f32) ?f32 {
    if (d.len < 20 or r16(d, 0) != 1) return null;
    const store = r32(d, 4);
    const map = r32(d, map_field);
    var idx: DeltaIndex = .{
        .outer = 0,
        .inner = glyph,
    };
    if (map != 0) idx = mapIndex(d, map, glyph) orelse return null;
    return storeDelta(d, store, idx.outer, idx.inner, coords);
}

/// MVAR delta of the value tagged `tag` (null when MVAR does not vary it).
pub fn mvarDelta(d: []const u8, tag: *const [4]u8, coords: []const f32) ?f32 {
    if (d.len < 12 or r16(d, 0) != 1) return null;
    const rec_size: usize = r16(d, 6);
    const count: usize = r16(d, 8);
    const store: usize = r16(d, 10);
    if (rec_size < 8) return null;
    // Records are sorted by tag.
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const rec = 12 + mid * rec_size;
        if (rec + 8 > d.len) return null;
        const order = std.mem.order(u8, d[rec..][0..4], tag);
        switch (order) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return storeDelta(d, store, r16(d, rec + 4), r16(d, rec + 6), coords),
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// FeatureVariations.

/// Offset of the FeatureTableSubstitution of the first FeatureVariation
/// record whose conditions hold at `coords`, or 0. `fv` is the
/// FeatureVariations offset in the GSUB/GPOS table `d`.
pub fn selectFeatureVariation(d: []const u8, fv: usize, coords: []const f32) usize {
    if (fv == 0 or r16(d, fv) != 1) return 0;
    const count = @min(r32(d, fv + 4), d.len / 8);
    for (0..count) |k| {
        const rec = fv + 8 + k * 8;
        if (rec + 8 > d.len) return 0;
        const cs_off = r32(d, rec);
        const subst_off = r32(d, rec + 4);
        if (cs_off != 0 and !conditionsHold(d, fv + cs_off, coords)) continue;
        if (subst_off == 0) return 0;
        return fv + subst_off;
    }
    return 0;
}

fn conditionsHold(d: []const u8, set: usize, coords: []const f32) bool {
    if (set + 2 > d.len) return false;
    const n: usize = r16(d, set);
    for (0..n) |k| {
        const off = r32(d, set + 2 + k * 4);
        if (off == 0) return false;
        const c = set + off;
        // Format 1: an axis range. Other formats are not understood: no match.
        if (r16(d, c) != 1) return false;
        const axis: usize = r16(d, c + 2);
        const v: i32 = if (axis < coords.len) @intFromFloat(@round(coords[axis] * 16384)) else 0;
        if (v < ri16(d, c + 4) or v > ri16(d, c + 6)) return false;
    }
    return true;
}

/// The alternate feature table offset for feature index `fi` in the
/// FeatureTableSubstitution at `subst`, or null when it is not substituted.
pub fn substituteFeature(d: []const u8, subst: usize, fi: u16) ?usize {
    if (subst == 0 or r16(d, subst) != 1) return null;
    const n: usize = r16(d, subst + 4);
    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const rec = subst + 6 + mid * 6;
        if (rec + 6 > d.len) return null;
        const v = r16(d, rec);
        if (v < fi) lo = mid + 1 else if (v > fi) hi = mid else {
            const off = r32(d, rec + 2);
            if (off == 0 or subst + off >= d.len) return null;
            return subst + off;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// gvar: packed point numbers and deltas.

/// Reads packed point numbers (gvar "Packed point numbers").
const PointReader = struct {
    d: []const u8,
    p: usize,
    /// Points listed; 0 means every point of the glyph.
    count: usize,
    left: usize,
    run_left: usize = 0,
    words: bool = false,
    value: u32 = 0,

    fn init(d: []const u8, p: usize) ?PointReader {
        if (p >= d.len) return null;
        var count: usize = d[p];
        var q = p + 1;
        if (count & 0x80 != 0) {
            if (q >= d.len) return null;
            count = (count & 0x7F) << 8 | d[q];
            q += 1;
        }
        return .{
            .d = d,
            .p = q,
            .count = count,
            .left = count,
        };
    }

    /// The next point number; null when done or malformed (`ok` tells them apart).
    fn next(r: *PointReader) ?u16 {
        if (r.left == 0) return null;
        if (r.run_left == 0) {
            if (r.p >= r.d.len) return r.fail();
            const c = r.d[r.p];
            r.p += 1;
            r.words = c & 0x80 != 0;
            r.run_left = (c & 0x7F) + 1;
        }
        var v: u32 = undefined;
        if (r.words) {
            if (r.p + 2 > r.d.len) return r.fail();
            v = r16(r.d, r.p);
            r.p += 2;
        } else {
            if (r.p >= r.d.len) return r.fail();
            v = r.d[r.p];
            r.p += 1;
        }
        r.run_left -= 1;
        r.left -= 1;
        r.value +%= v;
        if (r.value > 0xFFFF) return r.fail();
        return @intCast(r.value);
    }

    fn fail(r: *PointReader) ?u16 {
        r.left = std.math.maxInt(usize);
        r.count = std.math.maxInt(usize);
        return null;
    }

    fn ok(r: *const PointReader) bool {
        return r.count != std.math.maxInt(usize);
    }

    /// Reads to the end of the list; the position after it, or null when malformed.
    fn skip(r: *PointReader) ?usize {
        while (r.next()) |_| {}
        return if (r.ok()) r.p else null;
    }
};

/// Reads packed deltas (gvar "Packed deltas").
const DeltaReader = struct {
    d: []const u8,
    p: usize,
    run_left: usize = 0,
    /// 0: zeros, 1: bytes, 2: words, 4: longs.
    size: u8 = 0,
    bad: bool = false,

    fn next(r: *DeltaReader) ?i32 {
        if (r.run_left == 0) {
            if (r.p >= r.d.len) {
                r.bad = true;
                return null;
            }
            const c = r.d[r.p];
            r.p += 1;
            r.size = switch (c & 0xC0) {
                0x80 => 0,
                0x40 => 2,
                0xC0 => 4,
                else => 1,
            };
            r.run_left = (c & 0x3F) + 1;
        }
        r.run_left -= 1;
        if (r.p + r.size > r.d.len) {
            r.bad = true;
            return null;
        }
        const v: i32 = switch (r.size) {
            0 => 0,
            1 => @as(i8, @bitCast(r.d[r.p])),
            2 => ri16(r.d, r.p),
            else => @bitCast(r32(r.d, r.p)),
        };
        r.p += r.size;
        return v;
    }
};

/// The gvar entry of one glyph: its tuple variations.
const GlyphVariations = struct {
    /// The GlyphVariationData.
    g: []const u8,
    /// gvar table and its shared tuples.
    gvar: []const u8,
    shared_tuples: usize,
    shared_count: usize,
    axis_count: usize,
    count: usize,
    /// Next tuple header and its serialized data.
    header: usize,
    data: usize,
    /// Start of the shared point numbers (when `shared_points`).
    shared_points: ?usize,

    fn init(gvar: []const u8, num_glyphs: u16, glyph: u16) ?GlyphVariations {
        if (gvar.len < 20 or r16(gvar, 0) != 1) return null;
        const glyph_count = r16(gvar, 12);
        if (glyph >= glyph_count or glyph_count != num_glyphs) return null;
        const long = r16(gvar, 14) & 1 != 0;
        const array = r32(gvar, 16);
        const start: usize, const end: usize = if (long)
            .{ r32(gvar, 20 + @as(usize, glyph) * 4), r32(gvar, 24 + @as(usize, glyph) * 4) }
        else
            .{ @as(usize, r16(gvar, 20 + @as(usize, glyph) * 2)) * 2, @as(usize, r16(gvar, 22 + @as(usize, glyph) * 2)) * 2 };
        if (end <= start or array + end > gvar.len) return null;
        const g = gvar[array + start .. array + end];
        if (g.len < 4) return null;
        const tc = r16(g, 0);
        const data: usize = r16(g, 2);
        if (data > g.len) return null;
        return .{
            .g = g,
            .gvar = gvar,
            .shared_tuples = r32(gvar, 8),
            .shared_count = r16(gvar, 6),
            .axis_count = r16(gvar, 4),
            .count = tc & 0x0FFF,
            .header = 4,
            .data = data,
            .shared_points = if (tc & 0x8000 != 0) data else null,
        };
    }

    const Tuple = struct {
        scalar: f32,
        /// The tuple's serialized data: [point numbers] x deltas, y deltas.
        data: []const u8,
        private_points: bool,
    };

    /// The next tuple (scalar 0 when it does not apply); null at the end or
    /// when malformed.
    fn next(v: *GlyphVariations, coords: []const f32) ?Tuple {
        if (v.count == 0) return null;
        v.count -= 1;
        const g = v.g;
        const h = v.header;
        if (h + 4 > g.len) return null;
        const size: usize = r16(g, h);
        const index = r16(g, h + 2);
        const n = v.axis_count;
        var p = h + 4;
        var peak: usize = undefined;
        var peak_data: []const u8 = g;
        if (index & 0x8000 != 0) {
            peak = p;
            p += n * 2;
        } else {
            const i: usize = index & 0x0FFF;
            if (i >= v.shared_count) return null;
            peak = v.shared_tuples + i * n * 2;
            peak_data = v.gvar;
            if (peak + n * 2 > v.gvar.len) return null;
        }
        var start: ?usize = null;
        if (index & 0x4000 != 0) {
            start = p;
            p += n * 4;
        }
        if (p > g.len) return null;
        v.header = p;
        const data_start = v.data;
        if (data_start + size > g.len) return null;
        v.data += size;

        var s: f32 = 1;
        for (0..n) |a| {
            const pk = f2dot14(peak_data, peak + a * 2);
            const c: f32 = if (a < coords.len) coords[a] else 0;
            const lo, const hi = if (start) |st|
                .{ f2dot14(g, st + a * 2), f2dot14(g, st + n * 2 + a * 2) }
            else
                .{ @min(pk, 0), @max(pk, 0) };
            s *= axisScalar(lo, pk, hi, c);
            if (s == 0) break;
        }
        return .{
            .scalar = s,
            .data = g[data_start .. data_start + size],
            .private_points = index & 0x2000 != 0,
        };
    }
};

/// Reusable buffers for applying gvar deltas to an outline.
pub const Scratch = struct {
    /// The points before any delta (IUP interpolates against them).
    orig: std.ArrayList(geom.Vec2) = .empty,
    /// One tuple's deltas.
    delta: std.ArrayList(geom.Vec2) = .empty,
    touched: std.ArrayList(bool) = .empty,
    /// Point numbers of the shared and the current tuple.
    shared: std.ArrayList(u16) = .empty,
    points: std.ArrayList(u16) = .empty,

    /// Frees the buffers.
    pub fn deinit(s: *Scratch, gpa: std.mem.Allocator) void {
        s.orig.deinit(gpa);
        s.delta.deinit(gpa);
        s.touched.deinit(gpa);
        s.shared.deinit(gpa);
        s.points.deinit(gpa);
    }
};

/// Reads a packed point-number list into `out`; returns false when it lists
/// every point, null when malformed. `p` moves past the list.
fn readPointList(gpa: std.mem.Allocator, d: []const u8, p: *usize, out: *std.ArrayList(u16)) !?bool {
    var r = PointReader.init(d, p.*) orelse return null;
    out.clearRetainingCapacity();
    try out.ensureTotalCapacity(gpa, r.count);
    while (r.next()) |v| out.appendAssumeCapacity(v);
    if (!r.ok()) return null;
    p.* = r.p;
    return r.count != 0;
}

/// Applies the gvar deltas of `glyph` at `coords` to `pts`: the glyph's
/// points followed by its four phantom points. `ends` holds the exclusive
/// contour ends, offset by `ends_base` (empty for composite glyphs, whose
/// "points" are component offsets and are never interpolated). Malformed
/// variation data stops the remaining tuples; nothing panics.
pub fn applyGvar(gpa: std.mem.Allocator, gvar: []const u8, num_glyphs: u16, glyph: u16, coords: []const f32, pts: []geom.Vec2, ends: []const u32, ends_base: usize, s: *Scratch) !void {
    var it = GlyphVariations.init(gvar, num_glyphs, glyph) orelse return;
    const n = pts.len;
    try s.orig.resize(gpa, n);
    @memcpy(s.orig.items, pts);
    try s.delta.resize(gpa, n);
    try s.touched.resize(gpa, n);
    var shared_explicit = false;
    if (it.shared_points) |sp| {
        var p = sp;
        shared_explicit = try readPointList(gpa, it.g, &p, &s.shared) orelse return;
        it.data = p;
    }
    while (it.next(coords)) |t| {
        if (t.scalar == 0) continue;
        var p: usize = 0;
        var explicit = shared_explicit;
        var list = s.shared.items;
        if (t.private_points) {
            explicit = try readPointList(gpa, t.data, &p, &s.points) orelse return;
            list = s.points.items;
        }
        const count = if (explicit) list.len else n;
        var xs: DeltaReader = .{
            .d = t.data,
            .p = p,
        };
        // The y deltas follow all the x deltas: find where they start.
        for (0..count) |_| _ = xs.next() orelse return;
        var ys: DeltaReader = .{
            .d = t.data,
            .p = xs.p,
        };
        xs = .{
            .d = t.data,
            .p = p,
        };
        const delta = s.delta.items;
        const touched = s.touched.items;
        if (!explicit) {
            for (delta, touched) |*dv, *tv| {
                dv.* = .{
                    .x = @floatFromInt(xs.next() orelse return),
                    .y = @floatFromInt(ys.next() orelse return),
                };
                tv.* = true;
            }
        } else {
            @memset(touched, false);
            @memset(delta, .{});
            for (list) |k| {
                const dx = xs.next() orelse return;
                const dy = ys.next() orelse return;
                if (k >= n) continue;
                delta[k] = .{
                    .x = @floatFromInt(dx),
                    .y = @floatFromInt(dy),
                };
                touched[k] = true;
            }
            var start: usize = 0;
            for (ends) |e_u| {
                if (e_u < ends_base) break;
                const e: usize = e_u - ends_base;
                if (e <= start or e > n) break;
                interpolate(s.orig.items[start..e], delta[start..e], touched[start..e]);
                start = e;
            }
        }
        for (pts, delta, touched) |*q, dv, tv| if (tv) {
            q.x += dv.x * t.scalar;
            q.y += dv.y * t.scalar;
        };
    }
}

/// Infers deltas for the untouched points of one contour from the touched
/// points around them (gvar "Inferred deltas for un-referenced point
/// numbers"), each coordinate separately. Marks the contour touched.
fn interpolate(orig: []const geom.Vec2, delta: []geom.Vec2, touched: []bool) void {
    const n = orig.len;
    var first: ?usize = null;
    for (touched, 0..) |t, k| if (t) {
        first = k;
        break;
    };
    const f = first orelse return;
    var a = f;
    while (true) {
        // The next touched point after `a`, cyclically.
        var b = (a + 1) % n;
        while (!touched[b]) b = (b + 1) % n;
        var k = (a + 1) % n;
        while (k != b) : (k = (k + 1) % n) {
            delta[k] = .{
                .x = infer(orig[k].x, orig[a].x, orig[b].x, delta[a].x, delta[b].x),
                .y = infer(orig[k].y, orig[a].y, orig[b].y, delta[a].y, delta[b].y),
            };
        }
        a = b;
        if (a == f) break;
    }
    @memset(touched, true);
}

fn infer(c: f32, ca: f32, cb: f32, da: f32, db: f32) f32 {
    if (ca == cb) return if (da == db) da else 0;
    const lo, const dlo, const hi, const dhi = if (ca < cb) .{ ca, da, cb, db } else .{ cb, db, ca, da };
    if (c <= lo) return dlo;
    if (c >= hi) return dhi;
    return dlo + (c - lo) * (dhi - dlo) / (hi - lo);
}

/// The summed deltas of the four phantom points of `glyph`, whose own point
/// count (outline points, or components) is `points`. Reads the variation
/// data in place, without buffers.
pub fn phantomDeltas(gvar: []const u8, num_glyphs: u16, glyph: u16, coords: []const f32, points: usize) [4]geom.Vec2 {
    var out: [4]geom.Vec2 = @splat(.{});
    var it = GlyphVariations.init(gvar, num_glyphs, glyph) orelse return out;
    var shared: ?PointReader = null;
    if (it.shared_points) |sp| {
        var r = PointReader.init(it.g, sp) orelse return out;
        const start = r;
        it.data = r.skip() orelse return out;
        shared = start;
    }
    while (it.next(coords)) |t| {
        if (t.scalar == 0) continue;
        var p: usize = 0;
        var list: ?PointReader = shared;
        if (t.private_points) {
            var r = PointReader.init(t.data, 0) orelse return out;
            list = r;
            p = r.skip() orelse return out;
        }
        // Positions of the phantom points in the tuple's point list.
        var at: [4]?usize = @splat(null);
        var count: usize = points + 4;
        if (list != null and list.?.count != 0) {
            var r = list.?;
            var k: usize = 0;
            while (r.next()) |v| : (k += 1) {
                if (v >= points and v - points < 4) at[v - points] = k;
            }
            if (!r.ok()) return out;
            count = list.?.count;
        } else {
            for (&at, 0..) |*a, k| a.* = points + k;
        }
        var xs: DeltaReader = .{
            .d = t.data,
            .p = p,
        };
        var xv: [4]f32 = @splat(0);
        var yv: [4]f32 = @splat(0);
        for (0..count) |k| {
            const v = xs.next() orelse return out;
            for (at, 0..) |a, j| if (a == k) {
                xv[j] = @floatFromInt(v);
            };
        }
        for (0..count) |k| {
            const v = xs.next() orelse return out;
            for (at, 0..) |a, j| if (a == k) {
                yv[j] = @floatFromInt(v);
            };
        }
        for (&out, xv, yv) |*o, x, y| {
            o.x += x * t.scalar;
            o.y += y * t.scalar;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests (font-independent pieces; the font tests are in font.zig).

const testing = std.testing;

test "tent scalars" {
    try testing.expectEqual(@as(f32, 1), axisScalar(0, 1, 1, 1));
    try testing.expectEqual(@as(f32, 0.5), axisScalar(0, 1, 1, 0.5));
    try testing.expectEqual(@as(f32, 0), axisScalar(0, 1, 1, -0.5));
    try testing.expectApproxEqAbs(@as(f32, 0.5), axisScalar(0.2, 0.4, 0.6, 0.5), 1e-6);
    // Peak 0 and malformed regions leave the axis out.
    try testing.expectEqual(@as(f32, 1), axisScalar(0, 0, 1, 0.3));
    try testing.expectEqual(@as(f32, 1), axisScalar(0.5, 0.2, 1, 0.3));
}

test "packed point numbers and deltas" {
    // 3 points: one byte run of 3 (1, +2, +3) -> 1, 3, 6.
    const pts = [_]u8{ 3, 0x02, 1, 2, 3 };
    var r = PointReader.init(&pts, 0).?;
    try testing.expectEqual(@as(?u16, 1), r.next());
    try testing.expectEqual(@as(?u16, 3), r.next());
    try testing.expectEqual(@as(?u16, 6), r.next());
    try testing.expectEqual(@as(?u16, null), r.next());
    try testing.expect(r.ok());
    // Truncated: malformed, not a crash.
    var bad = PointReader.init(pts[0..3], 0).?;
    try testing.expectEqual(@as(?usize, null), bad.skip());
    // Deltas: two zeros, then a word run of one (-2), then a byte (5).
    const ds = [_]u8{ 0x81, 0x40, 0xFF, 0xFE, 0x00, 5 };
    var dr: DeltaReader = .{
        .d = &ds,
        .p = 0,
    };
    for ([_]i32{ 0, 0, -2, 5 }) |want| try testing.expectEqual(@as(?i32, want), dr.next());
    try testing.expectEqual(@as(?i32, null), dr.next());
}

test "interpolation of untouched points" {
    // A square; corners 0 and 2 touched, 1 and 3 inferred.
    const orig = [_]geom.Vec2{
        .{
            .x = 0,
            .y = 0,
        },
        .{
            .x = 100,
            .y = 0,
        },
        .{
            .x = 100,
            .y = 100,
        },
        .{
            .x = 0,
            .y = 100,
        },
    };
    var delta = [_]geom.Vec2{
        .{
            .x = 10,
            .y = 0,
        },
        .{},
        .{
            .x = 20,
            .y = 4,
        },
        .{},
    };
    var touched = [_]bool{ true, false, true, false };
    interpolate(&orig, &delta, &touched);
    // Point 1: x=100 equals the max reference (point 2) -> 20; y=0 -> 0.
    try testing.expectEqual(@as(f32, 20), delta[1].x);
    try testing.expectEqual(@as(f32, 0), delta[1].y);
    try testing.expectEqual(@as(f32, 10), delta[3].x);
    try testing.expectEqual(@as(f32, 4), delta[3].y);
}
