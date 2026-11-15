//! OpenType / TrueType font parsing: metrics, names, the character map,
//! horizontal metrics, TrueType and CFF outlines and the OpenType layout tables
//! (GDEF, GSUB, GPOS, legacy kern) the shaper reads.
//!
//! Written from the OpenType specification and Apple's TrueType reference.
//! Every read is bounds-checked: malformed fonts produce errors (or, inside
//! the layout tables, zero values that end loops), never a panic.

const std = @import("std");
const geom = @import("../raster/geom.zig");
/// Variable fonts: fvar, avar, gvar, HVAR, MVAR, item variation stores.
pub const variation = @import("variation.zig");
pub const Axis = variation.Axis;
pub const AxisValue = variation.AxisValue;
pub const NamedInstance = variation.NamedInstance;
/// CFF outlines (OpenType fonts with PostScript outlines).
pub const cff = @import("cff.zig");
pub const max_axes = variation.max_axes;

/// Errors from parsing a font or reading one of its glyphs.
pub const Error = error{
    InvalidFont,
    UnsupportedFont,
    InvalidGlyph,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Big-endian readers. Out-of-bounds reads return 0.

/// Reads a big-endian u16 at `off`, or 0 when it lies outside `d`.
pub inline fn r16(d: []const u8, off: usize) u16 {
    if (off > d.len or d.len - off < 2) return 0;
    return @as(u16, d[off]) << 8 | d[off + 1];
}

/// Reads a big-endian i16 at `off`, or 0 when it lies outside `d`.
pub inline fn ri16(d: []const u8, off: usize) i16 {
    return @bitCast(r16(d, off));
}

/// Reads a big-endian u32 at `off`, or 0 when it lies outside `d`.
pub inline fn r32(d: []const u8, off: usize) u32 {
    if (off > d.len or d.len - off < 4) return 0;
    return @as(u32, d[off]) << 24 | @as(u32, d[off + 1]) << 16 | @as(u32, d[off + 2]) << 8 | d[off + 3];
}

/// Returns `d[off..off+len]`, or null when that range lies outside `d`.
fn sub(d: []const u8, off: usize, len: usize) ?[]const u8 {
    if (off > d.len or d.len - off < len) return null;
    return d[off .. off + len];
}

// ---------------------------------------------------------------------------
// Coverage and class definition tables.

/// Index of glyph `g` in the Coverage table at `off`, or null when not covered.
pub fn coverageIndex(d: []const u8, off: usize, g: u16) ?u16 {
    const format = r16(d, off);
    const count: usize = r16(d, off + 2);
    if (format == 1) {
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const v = r16(d, off + 4 + mid * 2);
            if (v < g) lo = mid + 1 else if (v > g) hi = mid else return @intCast(mid);
        }
    } else if (format == 2) {
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = off + 4 + mid * 6;
            const start = r16(d, rec);
            const end = r16(d, rec + 2);
            if (end < g) lo = mid + 1 else if (start > g) hi = mid else {
                return @truncate(@as(u32, r16(d, rec + 4)) + (g - start));
            }
        }
    }
    return null;
}

/// Class of glyph `g` in the ClassDef table at `off` (0 when not listed or `off` is 0).
pub fn classOf(d: []const u8, off: usize, g: u16) u16 {
    if (off == 0) return 0;
    const format = r16(d, off);
    if (format == 1) {
        const start = r16(d, off + 2);
        const count = r16(d, off + 4);
        if (g < start or g - start >= count) return 0;
        return r16(d, off + 6 + @as(usize, g - start) * 2);
    } else if (format == 2) {
        var lo: usize = 0;
        var hi: usize = r16(d, off + 2);
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = off + 4 + mid * 6;
            if (r16(d, rec + 2) < g) lo = mid + 1 else if (r16(d, rec) > g) hi = mid else return r16(d, rec + 4);
        }
    }
    return 0;
}

/// A constant-size, approximate set of glyph ids: `mayHave` never returns
/// false for a glyph that was added, and rarely true for one that was not.
/// The shaper uses it to skip lookups that cannot apply to a glyph.
pub const Digest = struct {
    m0: u64 = 0,
    m1: u64 = 0,
    m2: u64 = 0,

    /// A digest that matches every glyph.
    pub const all: Digest = .{
        .m0 = ~@as(u64, 0),
        .m1 = ~@as(u64, 0),
        .m2 = ~@as(u64, 0),
    };

    const shifts = [3]u5{ 0, 4, 9 };

    inline fn bit(g: u32, comptime s: u5) u64 {
        return @as(u64, 1) << @intCast((g >> s) & 63);
    }

    /// True when `g` may be in the set.
    pub inline fn mayHave(self: Digest, g: u16) bool {
        return self.m0 & bit(g, 0) != 0 and self.m1 & bit(g, 4) != 0 and self.m2 & bit(g, 9) != 0;
    }

    /// Adds glyphs `a..=b`.
    pub fn addRange(self: *Digest, a: u16, b: u16) void {
        if (b < a) return;
        inline for (.{ &self.m0, &self.m1, &self.m2 }, shifts) |m, s| {
            const lo: u32 = @as(u32, a) >> s;
            const hi: u32 = @as(u32, b) >> s;
            if (hi - lo >= 63) {
                m.* = ~@as(u64, 0);
            } else {
                var v = lo;
                while (v <= hi) : (v += 1) m.* |= @as(u64, 1) << @intCast(v & 63);
            }
        }
    }

    /// Adds every glyph of the Coverage table at `off`.
    pub fn addCoverage(self: *Digest, d: []const u8, off: usize) void {
        const format = r16(d, off);
        const count: usize = r16(d, off + 2);
        if (format == 1) {
            for (0..count) |k| {
                const g = r16(d, off + 4 + k * 2);
                self.addRange(g, g);
            }
        } else if (format == 2) {
            for (0..count) |k| self.addRange(r16(d, off + 4 + k * 6), r16(d, off + 6 + k * 6));
        } else self.* = all;
    }
};

// ---------------------------------------------------------------------------
// GSUB / GPOS.

/// A lookup subtable: its type (extensions resolved) and offset in the table.
pub const Subtable = struct {
    kind: u16,
    off: usize,
};

/// A GSUB or GPOS table: its script, feature and lookup lists, plus one
/// glyph digest per lookup (built at parse time).
pub const Layout = struct {
    /// The whole table; every offset below is relative to its start.
    data: []const u8 = &.{},
    /// True for GPOS, false for GSUB.
    is_gpos: bool = false,
    script_list: usize = 0,
    feature_list: usize = 0,
    lookup_list: usize = 0,
    /// Glyphs each lookup can start at (first coverage of every subtable).
    digests: []const Digest = &.{},
    /// FeatureVariations table (version 1.1; 0 when absent).
    feature_variations: usize = 0,
    /// The FeatureTableSubstitution chosen for the font's instance (0 when none).
    feature_subst: usize = 0,

    /// True when the table is present.
    pub fn present(self: Layout) bool {
        return self.data.len != 0;
    }

    /// Number of lookups in the lookup list.
    pub fn lookupCount(self: Layout) u16 {
        if (self.lookup_list == 0) return 0;
        return r16(self.data, self.lookup_list);
    }

    /// Offset of lookup `i`.
    pub fn lookupOffset(self: Layout, i: u16) usize {
        return self.lookup_list + r16(self.data, self.lookup_list + 2 + @as(usize, i) * 2);
    }

    /// The lookup type and offset of subtable `k` of the lookup at `lookup`,
    /// with extension subtables (GSUB 7, GPOS 9) resolved.
    pub fn subtable(self: Layout, lookup: usize, k: usize) Subtable {
        var kind = r16(self.data, lookup);
        var off = lookup + r16(self.data, lookup + 6 + k * 2);
        const ext: u16 = if (self.is_gpos) 9 else 7;
        if (kind == ext) {
            kind = r16(self.data, off + 2);
            off +|= r32(self.data, off + 4);
            // An extension may not point at an extension, nor outside the table.
            if (kind == ext or off >= self.data.len) {
                kind = 0;
                off = 0;
            }
        }
        return .{
            .kind = kind,
            .off = off,
        };
    }

    /// Offset of the LangSys used for shaping: script `latn` (else `DFLT`,
    /// else `dflt`), default language system. Null when none exists.
    pub fn langSys(self: Layout) ?usize {
        if (self.script_list == 0) return null;
        const d = self.data;
        const count: usize = r16(d, self.script_list);
        for ([_]*const [4]u8{ "latn", "DFLT", "dflt" }) |want| {
            for (0..count) |k| {
                const rec = self.script_list + 2 + k * 6;
                const tag = sub(d, rec, 4) orelse return null;
                if (!std.mem.eql(u8, tag, want)) continue;
                const script = self.script_list + r16(d, rec + 4);
                const def = r16(d, script);
                if (def == 0) return null;
                return script + def;
            }
        }
        return null;
    }

    /// Calls `visit(ctx, tag, feature_offset)` for every feature of the shaping
    /// LangSys, the required feature included.
    pub fn eachFeature(self: Layout, ctx: anytype, comptime visit: fn (@TypeOf(ctx), [4]u8, usize) void) void {
        const ls = self.langSys() orelse return;
        if (self.feature_list == 0) return;
        const d = self.data;
        const nfeat = r16(d, self.feature_list);
        const req = r16(d, ls + 2);
        const n: usize = r16(d, ls + 4);
        var k: usize = 0;
        while (k <= n) : (k += 1) {
            const fi = if (k == n) req else r16(d, ls + 6 + k * 2);
            if (fi == 0xFFFF or fi >= nfeat) continue;
            const rec = self.feature_list + 2 + @as(usize, fi) * 6;
            const tag = (sub(d, rec, 4) orelse continue)[0..4].*;
            const off = variation.substituteFeature(d, self.feature_subst, fi) orelse self.feature_list + r16(d, rec + 4);
            visit(ctx, tag, off);
        }
    }

    /// True when the shaping LangSys has feature `tag`.
    pub fn hasFeature(self: Layout, tag: [4]u8) bool {
        const S = struct {
            want: [4]u8,
            found: bool = false,
            fn visit(s: *@This(), t: [4]u8, _: usize) void {
                if (std.mem.eql(u8, &t, &s.want)) s.found = true;
            }
        };
        var s: S = .{
            .want = tag,
        };
        self.eachFeature(&s, S.visit);
        return s.found;
    }

    /// Offset of the coverage table that decides where a subtable can start.
    fn startCoverage(self: Layout, kind: u16, off: usize) ?usize {
        const d = self.data;
        const format = r16(d, off);
        const context: u16 = if (self.is_gpos) 7 else 5;
        const chain: u16 = if (self.is_gpos) 8 else 6;
        if (kind == context and format == 3) {
            if (r16(d, off + 2) == 0) return null;
            return off + r16(d, off + 6);
        }
        if (kind == chain and format == 3) {
            const back: usize = r16(d, off + 2);
            if (r16(d, off + 4 + back * 2) == 0) return null;
            return off + r16(d, off + 6 + back * 2);
        }
        if (kind == 0) return null;
        if (!self.is_gpos and kind > 8) return null;
        if (self.is_gpos and kind > 9) return null;
        return off + r16(d, off + 2);
    }

    fn buildDigests(self: *Layout, arena: std.mem.Allocator) !void {
        const n = self.lookupCount();
        const digests = try arena.alloc(Digest, n);
        // A work budget: malformed tables can describe billions of
        // subtable and coverage entries. Past it, lookups get a digest that
        // matches every glyph (correct, only slower to apply).
        var budget: usize = self.data.len * 16 + (1 << 20);
        for (digests, 0..) |*dg, i| {
            dg.* = .{};
            const lookup = self.lookupOffset(@intCast(i));
            const subs: usize = r16(self.data, lookup + 4);
            for (0..subs) |k| {
                const st = self.subtable(lookup, k);
                const cov = self.startCoverage(st.kind, st.off) orelse {
                    dg.* = Digest.all;
                    break;
                };
                const cost = @as(usize, r16(self.data, cov + 2)) + 1;
                if (cost > budget) {
                    dg.* = Digest.all;
                    budget = 0;
                    break;
                }
                budget -= cost;
                dg.addCoverage(self.data, cov);
            }
        }
        self.digests = digests;
    }

    fn init(arena: std.mem.Allocator, data: []const u8, is_gpos: bool) !Layout {
        if (data.len < 10 or r16(data, 0) != 1) return .{};
        var l: Layout = .{
            .data = data,
            .is_gpos = is_gpos,
            .script_list = r16(data, 4),
            .feature_list = r16(data, 6),
            .lookup_list = r16(data, 8),
        };
        if (r16(data, 2) >= 1 and data.len >= 14) {
            const fv = r32(data, 10);
            if (fv != 0 and fv < data.len) l.feature_variations = fv;
        }
        try l.buildDigests(arena);
        return l;
    }
};

// ---------------------------------------------------------------------------
// The font.

const Tables = struct {
    cmap: []const u8 = &.{},
    hmtx: []const u8 = &.{},
    loca: []const u8 = &.{},
    glyf: []const u8 = &.{},
    gdef: []const u8 = &.{},
    kern: []const u8 = &.{},
};

/// A parsed font. Borrows `data`; strings live in the arena given to `parse`.
pub const Font = struct {
    /// The font file, borrowed: the caller keeps it alive.
    data: []const u8,
    units_per_em: u16,
    // hhea
    ascender: i16,
    descender: i16,
    line_gap: i16,
    // OS/2 (0 when missing)
    typo_ascender: i16,
    typo_descender: i16,
    typo_line_gap: i16,
    win_ascent: u16,
    win_descent: u16,
    use_typo_metrics: bool,
    x_height: i16,
    cap_height: i16,
    weight_class: u16,
    italic: bool,
    // post
    underline_position: i16,
    underline_thickness: i16,
    // OS/2
    strikeout_position: i16,
    strikeout_size: i16,
    /// Typographic family (name ID 16, else 1), UTF-8.
    family: []const u8,
    /// Typographic subfamily (name ID 17, else 2), UTF-8.
    subfamily: []const u8,
    /// Glyph count from maxp.
    num_glyphs: u16,
    /// Features this font always shapes with, on top of the defaults: a host's house style
    /// (Publr's UI sets Inter's `cv11` and `ss01`, as its admin's CSS does).
    features: []const [4]u8 = &.{},
    /// Font bounding box from head.
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,

    tables: Tables,
    num_hmetrics: u16,
    long_loca: bool,
    cmap_format: u16,
    /// GDEF sub-table offsets (0 when absent).
    gdef_class_def: usize,
    gdef_mark_attach_def: usize,
    gdef_mark_sets: usize,
    /// GSUB and GPOS (empty when absent).
    gsub: Layout,
    gpos: Layout,

    /// The name table (for named instances).
    name_table: []const u8 = &.{},
    /// Variation tables (empty for static fonts).
    vars: variation.Tables = .{},
    /// fvar axes, in fvar order (empty for static fonts).
    axis_list: []const Axis = &.{},
    /// This instance's normalized coordinates (after avar, F2Dot14
    /// precision), one per fvar axis; all zero for the default instance.
    coords: [max_axes]f32 = @splat(0),
    /// This instance's axis values in user units (clamped), as given to `setVariation`.
    user: [max_axes]f32 = @splat(0),
    /// True when any coordinate is non-zero: outlines, advances, metrics
    /// and GPOS values vary.
    varied: bool = false,
    /// The default instance's metrics, weight and slant (MVAR deltas and
    /// axis values apply on top of them).
    default_metrics: Metrics = .{},
    default_weight: u16 = 400,
    default_italic: bool = false,
    /// The CFF outlines of a font without glyf (null when it has none, or
    /// only CFF2, which is not supported).
    cff_outlines: ?cff.Cff = null,

    /// The vertical metrics of a font instance, in font units.
    pub const Metrics = struct {
        ascender: i16 = 0,
        descender: i16 = 0,
        line_gap: i16 = 0,
        typo_ascender: i16 = 0,
        typo_descender: i16 = 0,
        typo_line_gap: i16 = 0,
        win_ascent: u16 = 0,
        win_descent: u16 = 0,
        x_height: i16 = 0,
        cap_height: i16 = 0,
        underline_position: i16 = 0,
        underline_thickness: i16 = 0,
        strikeout_position: i16 = 0,
        strikeout_size: i16 = 0,
    };

    /// The metrics of this instance (the same values as the fields).
    pub fn metrics(self: *const Font) Metrics {
        var m: Metrics = .{};
        inline for (@typeInfo(Metrics).@"struct".fields) |fld| @field(m, fld.name) = @field(self, fld.name);
        return m;
    }

    /// The variation axes (empty for static fonts).
    pub fn axes(self: *const Font) []const Axis {
        return self.axis_list;
    }

    /// The named instances of a variable font ("Thin" .. "Black"), read into `arena`.
    pub fn namedInstances(self: *const Font, arena: std.mem.Allocator) ![]NamedInstance {
        const N = struct {
            arena: std.mem.Allocator,
            name: []const u8,
            fn get(n: @This(), id: u16) std.mem.Allocator.Error!?[]const u8 {
                return readName(n.arena, n.name, id);
            }
        };
        return variation.readInstances(arena, self.vars.fvar, self.axis_list, N{
            .arena = arena,
            .name = self.name_table,
        }, N.get);
    }

    /// The user value of axis `tag` in this instance (null when the font has
    /// no such axis).
    pub fn axisValue(self: *const Font, tag: [4]u8) ?f32 {
        for (self.axis_list, 0..) |a, i| {
            if (!std.mem.eql(u8, &a.tag, &tag)) continue;
            return if (self.varied and i < max_axes) self.user[i] else a.default;
        }
        return null;
    }

    /// Sets this font's instance from axis values in user units: each is
    /// clamped to its axis range, axes not given take their default, and
    /// unknown tags are ignored (the last value for a tag wins). Recomputes
    /// the normalized coordinates (through avar), the metric fields (MVAR),
    /// `weight_class` (from `wght`), `italic` (from `ital`) and the GSUB/GPOS
    /// feature variations. Does nothing to static fonts.
    pub fn setVariation(self: *Font, values: []const AxisValue) void {
        if (self.axis_list.len == 0) return;
        self.coords = @splat(0);
        self.user = @splat(0);
        const n = @min(self.axis_list.len, max_axes);
        for (self.axis_list[0..n], 0..) |a, i| {
            var v = a.default;
            for (values) |av| {
                if (std.mem.eql(u8, &av.tag, &a.tag) and !std.math.isNan(av.value)) v = av.value;
            }
            v = std.math.clamp(v, a.min, a.max);
            self.user[i] = v;
            self.coords[i] = variation.normalize(a, v);
        }
        variation.applyAvar(self.vars.avar, self.coords[0..n]);
        self.varied = false;
        for (self.coords[0..n]) |c| self.varied = self.varied or c != 0;
        const coords = self.coords[0..n];

        // Metrics: MVAR deltas on the defaults. The ascender, descender and
        // line gap deltas apply to hhea's values as well as OS/2's.
        const m = self.default_metrics;
        inline for (@typeInfo(Metrics).@"struct".fields) |fld| @field(self, fld.name) = @field(m, fld.name);
        if (self.varied and self.vars.mvar.len != 0) {
            const Map = struct {
                tag: *const [4]u8,
                field: []const u8,
            };
            const map = [_]Map{
                .{
                    .tag = "hasc",
                    .field = "typo_ascender",
                },
                .{
                    .tag = "hasc",
                    .field = "ascender",
                },
                .{
                    .tag = "hdsc",
                    .field = "typo_descender",
                },
                .{
                    .tag = "hdsc",
                    .field = "descender",
                },
                .{
                    .tag = "hlgp",
                    .field = "typo_line_gap",
                },
                .{
                    .tag = "hlgp",
                    .field = "line_gap",
                },
                .{
                    .tag = "hcla",
                    .field = "win_ascent",
                },
                .{
                    .tag = "hcld",
                    .field = "win_descent",
                },
                .{
                    .tag = "xhgt",
                    .field = "x_height",
                },
                .{
                    .tag = "cpht",
                    .field = "cap_height",
                },
                .{
                    .tag = "undo",
                    .field = "underline_position",
                },
                .{
                    .tag = "unds",
                    .field = "underline_thickness",
                },
                .{
                    .tag = "stro",
                    .field = "strikeout_position",
                },
                .{
                    .tag = "strs",
                    .field = "strikeout_size",
                },
            };
            inline for (map) |e| {
                if (variation.mvarDelta(self.vars.mvar, e.tag, coords)) |delta| {
                    const T = @FieldType(Metrics, e.field);
                    const v: i32 = @as(i32, @field(m, e.field)) + @as(i32, @intFromFloat(roundDelta(std.math.clamp(delta, -65536, 65536))));
                    @field(self, e.field) = @intCast(std.math.clamp(v, std.math.minInt(T), std.math.maxInt(T)));
                }
            }
        }

        self.weight_class = self.default_weight;
        self.italic = self.default_italic;
        for (self.axis_list[0..n], 0..) |a, i| {
            if (std.mem.eql(u8, &a.tag, "wght")) self.weight_class = @intFromFloat(std.math.clamp(@round(self.user[i]), 1, 1000));
            if (std.mem.eql(u8, &a.tag, "ital") and self.user[i] >= 0.5) self.italic = true;
            if (std.mem.eql(u8, &a.tag, "slnt") and self.user[i] != 0) self.italic = true;
        }

        // Condition ranges may include the default instance, so this runs
        // at every instance (parse runs it for the default one).
        self.gsub.feature_subst = variation.selectFeatureVariation(self.gsub.data, self.gsub.feature_variations, coords);
        self.gpos.feature_subst = variation.selectFeatureVariation(self.gpos.data, self.gpos.feature_variations, coords);
    }

    /// The GDEF ItemVariationStore delta (outer, inner) at this instance,
    /// rounded to font units (GPOS device tables of format 0x8000).
    pub fn variationDelta(self: *const Font, outer: u16, inner: u16) i32 {
        if (!self.varied or self.vars.gdef_store == 0) return 0;
        const v = variation.storeDelta(self.tables.gdef, self.vars.gdef_store, outer, inner, self.normalizedCoords());
        return @intFromFloat(roundDelta(std.math.clamp(v, -1e6, 1e6)));
    }

    /// The coordinates the variation tables read (one per axis).
    pub fn normalizedCoords(self: *const Font) []const f32 {
        return self.coords[0..@min(self.axis_list.len, max_axes)];
    }

    /// Parses `data` (TrueType, OpenType or the first face of a collection).
    /// Strings and lookup digests are allocated in `arena`.
    pub fn parse(arena: std.mem.Allocator, data: []const u8) Error!Font {
        var base: usize = 0;
        if (data.len >= 16 and std.mem.eql(u8, data[0..4], "ttcf")) {
            if (r32(data, 8) == 0) return error.InvalidFont;
            base = r32(data, 12);
        }
        const version = r32(data, base);
        if (version != 0x00010000 and version != 0x4F54544F and version != 0x74727565) return error.InvalidFont;
        const num_tables: usize = r16(data, base + 4);
        if (sub(data, base + 12, num_tables * 16) == null) return error.InvalidFont;

        var head: []const u8 = &.{};
        var hhea: []const u8 = &.{};
        var maxp: []const u8 = &.{};
        var os2: []const u8 = &.{};
        var post: []const u8 = &.{};
        var name: []const u8 = &.{};
        var gsub: []const u8 = &.{};
        var gpos: []const u8 = &.{};
        var t: Tables = .{};
        var vars: variation.Tables = .{};
        var cff_table: []const u8 = &.{};
        for (0..num_tables) |k| {
            const rec = base + 12 + k * 16;
            const tag = data[rec..][0..4];
            const slice = sub(data, r32(data, rec + 8), r32(data, rec + 12)) orelse continue;
            const Tag = enum { head, hhea, maxp, @"OS/2", post, name, GSUB, GPOS, cmap, hmtx, loca, glyf, GDEF, kern, fvar, avar, gvar, HVAR, MVAR, @"CFF " };
            const which = std.meta.stringToEnum(Tag, tag) orelse continue;
            switch (which) {
                .head => head = slice,
                .hhea => hhea = slice,
                .maxp => maxp = slice,
                .@"OS/2" => os2 = slice,
                .post => post = slice,
                .name => name = slice,
                .GSUB => gsub = slice,
                .GPOS => gpos = slice,
                .cmap => t.cmap = slice,
                .hmtx => t.hmtx = slice,
                .loca => t.loca = slice,
                .glyf => t.glyf = slice,
                .GDEF => t.gdef = slice,
                .kern => t.kern = slice,
                .fvar => vars.fvar = slice,
                .avar => vars.avar = slice,
                .gvar => vars.gvar = slice,
                .HVAR => vars.hvar = slice,
                .MVAR => vars.mvar = slice,
                .@"CFF " => cff_table = slice,
            }
        }
        if (head.len < 54 or hhea.len < 36 or maxp.len < 6 or t.hmtx.len < 4) return error.InvalidFont;
        const upem = r16(head, 18);
        if (upem < 16 or upem > 16384) return error.InvalidFont;
        const num_hmetrics = r16(hhea, 34);
        if (num_hmetrics == 0 or t.hmtx.len < @as(usize, num_hmetrics) * 4) return error.InvalidFont;

        // cmap: 3/10 > 3/1 > 0/x, formats 12 and 4 only.
        var cmap_sub: []const u8 = &.{};
        var cmap_format: u16 = 0;
        var best: u8 = 0;
        const n_enc: usize = r16(t.cmap, 2);
        for (0..n_enc) |k| {
            const rec = 4 + k * 8;
            const platform = r16(t.cmap, rec);
            const encoding = r16(t.cmap, rec + 2);
            const off = r32(t.cmap, rec + 4);
            if (off >= t.cmap.len) continue;
            const format = r16(t.cmap, off);
            if (format != 4 and format != 12) continue;
            const score: u8 = if (platform == 3 and encoding == 10 and format == 12)
                6
            else if (platform == 3 and encoding == 1)
                5
            else if (platform == 0 and format == 12)
                4
            else if (platform == 0)
                3
            else if (platform == 3 and encoding == 0)
                1
            else
                0;
            if (score > best) {
                best = score;
                cmap_sub = t.cmap[off..];
                cmap_format = format;
            }
        }
        t.cmap = cmap_sub;

        var f: Font = .{
            .data = data,
            .units_per_em = upem,
            .ascender = ri16(hhea, 4),
            .descender = ri16(hhea, 6),
            .line_gap = ri16(hhea, 8),
            .typo_ascender = 0,
            .typo_descender = 0,
            .typo_line_gap = 0,
            .win_ascent = 0,
            .win_descent = 0,
            .use_typo_metrics = false,
            .x_height = 0,
            .cap_height = 0,
            .weight_class = 400,
            .italic = r16(head, 44) & 2 != 0,
            .underline_position = 0,
            .underline_thickness = 0,
            .strikeout_position = 0,
            .strikeout_size = 0,
            .family = "",
            .subfamily = "",
            .num_glyphs = r16(maxp, 4),
            .x_min = ri16(head, 36),
            .y_min = ri16(head, 38),
            .x_max = ri16(head, 40),
            .y_max = ri16(head, 42),
            .tables = t,
            .num_hmetrics = num_hmetrics,
            .long_loca = r16(head, 50) == 1,
            .cmap_format = cmap_format,
            .gdef_class_def = 0,
            .gdef_mark_attach_def = 0,
            .gdef_mark_sets = 0,
            .gsub = .{},
            .gpos = .{},
        };

        if (os2.len >= 78) {
            const fs_selection = r16(os2, 62);
            f.weight_class = r16(os2, 4);
            f.strikeout_size = ri16(os2, 26);
            f.strikeout_position = ri16(os2, 28);
            f.typo_ascender = ri16(os2, 68);
            f.typo_descender = ri16(os2, 70);
            f.typo_line_gap = ri16(os2, 72);
            f.win_ascent = r16(os2, 74);
            f.win_descent = r16(os2, 76);
            f.use_typo_metrics = fs_selection & 0x80 != 0;
            f.italic = f.italic or fs_selection & 1 != 0;
            if (r16(os2, 0) >= 2 and os2.len >= 90) {
                f.x_height = ri16(os2, 86);
                f.cap_height = ri16(os2, 88);
            }
        }
        if (post.len >= 12) {
            f.underline_position = ri16(post, 8);
            f.underline_thickness = ri16(post, 10);
        }

        f.family = try readName(arena, name, 16) orelse try readName(arena, name, 1) orelse "";
        f.subfamily = try readName(arena, name, 17) orelse try readName(arena, name, 2) orelse "";

        if (t.gdef.len >= 12 and r16(t.gdef, 0) == 1) {
            if (r16(t.gdef, 4) != 0) f.gdef_class_def = r16(t.gdef, 4);
            if (r16(t.gdef, 10) != 0) f.gdef_mark_attach_def = r16(t.gdef, 10);
            if (r16(t.gdef, 2) >= 2 and r16(t.gdef, 12) != 0) f.gdef_mark_sets = r16(t.gdef, 12);
        }
        if (t.glyf.len == 0 and cff_table.len != 0) {
            f.cff_outlines = cff.Cff.init(cff_table) catch |err| switch (err) {
                error.UnsupportedFont => null,
                else => return error.InvalidFont,
            };
        }
        f.gsub = try Layout.init(arena, gsub, false);
        f.gpos = try Layout.init(arena, gpos, true);

        // Variations.
        f.name_table = name;
        f.default_metrics = f.metrics();
        f.default_weight = f.weight_class;
        f.default_italic = f.italic;
        if (variation.Fvar.init(vars.fvar) != null) {
            if (t.gdef.len >= 18 and r16(t.gdef, 0) == 1 and r16(t.gdef, 2) >= 3) {
                const store = r32(t.gdef, 14);
                if (store != 0 and store < t.gdef.len) vars.gdef_store = store;
            }
            f.vars = vars;
            const N = struct {
                arena: std.mem.Allocator,
                name: []const u8,
                fn get(n: @This(), id: u16) std.mem.Allocator.Error!?[]const u8 {
                    return readName(n.arena, n.name, id);
                }
            };
            f.axis_list = try variation.readAxes(arena, vars.fvar, N{
                .arena = arena,
                .name = name,
            }, N.get);
            for (f.axis_list, 0..) |a, i| {
                if (i < max_axes) f.user[i] = a.default;
            }
            const n = @min(f.axis_list.len, max_axes);
            f.gsub.feature_subst = variation.selectFeatureVariation(f.gsub.data, f.gsub.feature_variations, f.coords[0..n]);
            f.gpos.feature_subst = variation.selectFeatureVariation(f.gpos.data, f.gpos.feature_variations, f.coords[0..n]);
        }
        return f;
    }

    /// Glyph for code point `cp`, or 0 (.notdef) when the font has none.
    pub fn glyphIndex(self: *const Font, cp: u21) u16 {
        const d = self.tables.cmap;
        const g: u32 = switch (self.cmap_format) {
            4 => blk: {
                if (cp > 0xFFFF) break :blk 0;
                const c: u16 = @intCast(cp);
                const seg_x2: usize = r16(d, 6) & ~@as(u16, 1);
                const segs = seg_x2 / 2;
                var lo: usize = 0;
                var hi: usize = segs;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (r16(d, 14 + mid * 2) < c) lo = mid + 1 else hi = mid;
                }
                if (lo >= segs) break :blk 0;
                const start = r16(d, 16 + seg_x2 + lo * 2);
                if (c < start) break :blk 0;
                const delta = r16(d, 16 + seg_x2 * 2 + lo * 2);
                const ro_pos = 16 + seg_x2 * 3 + lo * 2;
                const ro = r16(d, ro_pos);
                if (ro == 0) break :blk c +% delta;
                const gi = r16(d, ro_pos + ro + @as(usize, c - start) * 2);
                if (gi == 0) break :blk 0;
                break :blk gi +% delta;
            },
            12 => blk: {
                const groups: usize = @min(r32(d, 12), d.len / 12);
                var lo: usize = 0;
                var hi: usize = groups;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    const rec = 16 + mid * 12;
                    if (r32(d, rec + 4) < cp) lo = mid + 1 else if (r32(d, rec) > cp) hi = mid else {
                        break :blk r32(d, rec + 8) +% (cp - r32(d, rec));
                    }
                }
                break :blk 0;
            },
            else => 0,
        };
        return if (g < self.num_glyphs) @intCast(g) else 0;
    }

    /// Advance width of `glyph`: hmtx, plus the HVAR delta (else the gvar
    /// phantom point deltas) for a varied instance, rounded.
    pub fn advance(self: *const Font, glyph: u16) u16 {
        const base = self.hmtxAdvance(glyph);
        if (!self.varied) return base;
        var delta: f32 = 0;
        if (self.vars.hvar.len != 0) {
            delta = variation.hvarAdvanceDelta(self.vars.hvar, glyph, self.normalizedCoords());
        } else if (self.vars.gvar.len != 0) {
            const ph = self.phantoms(glyph);
            delta = ph[1].x - ph[0].x;
        }
        return clampU16(@as(f32, @floatFromInt(base)) + roundDelta(delta));
    }

    /// Left side bearing of `glyph`: hmtx, varied through HVAR when it maps
    /// side bearings, else measured on the varied outline.
    pub fn leftSideBearing(self: *const Font, glyph: u16) i16 {
        const base = self.hmtxLsb(glyph);
        if (!self.varied) return base;
        if (self.vars.hvar.len != 0) {
            if (variation.hvarLsbDelta(self.vars.hvar, glyph, self.normalizedCoords())) |delta| {
                return clampI16(@as(f32, @floatFromInt(base)) + roundDelta(delta));
            }
        }
        if (self.vars.gvar.len == 0) return base;
        const box = self.glyphBounds(glyph) orelse return base;
        const varied = self.pointBounds(glyph) orelse return base;
        // The varied outline is placed like the default one (left phantom
        // point at x_min - lsb), so the bearing is its left edge minus that.
        const origin: f32 = @floatFromInt(@as(i32, box[0]) - base);
        return clampI16(@round(varied[0] - origin));
    }

    /// The bounding box of all points (on- and off-curve) of `glyph` in this
    /// instance, as [x_min, y_min, x_max, y_max] in font units; the glyf
    /// header box for the default instance. Null for empty glyphs.
    pub fn pointBounds(self: *const Font, glyph: u16) ?[4]f32 {
        const box = self.glyphBounds(glyph) orelse return null;
        if (!self.variesOutlines()) return .{ @floatFromInt(box[0]), @floatFromInt(box[1]), @floatFromInt(box[2]), @floatFromInt(box[3]) };
        var sfa = std.heap.stackFallback(32768, std.heap.smp_allocator);
        const gpa = sfa.get();
        var o: Outline = .{};
        defer o.deinit(gpa);
        self.loadGlyph(gpa, glyph, &o, 0) catch return null;
        if (o.pts.items.len == 0) return null;
        var r: [4]f32 = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        for (o.pts.items) |q| {
            const x = q.x - o.phantom_dx;
            r = .{ @min(r[0], x), @min(r[1], q.y), @max(r[2], x), @max(r[3], q.y) };
        }
        return r;
    }

    fn hmtxAdvance(self: *const Font, glyph: u16) u16 {
        const i: usize = @min(glyph, self.num_hmetrics - 1);
        return r16(self.tables.hmtx, i * 4);
    }

    fn hmtxLsb(self: *const Font, glyph: u16) i16 {
        if (glyph < self.num_hmetrics) return ri16(self.tables.hmtx, @as(usize, glyph) * 4 + 2);
        return ri16(self.tables.hmtx, @as(usize, self.num_hmetrics) * 4 + @as(usize, glyph - self.num_hmetrics) * 2);
    }

    /// The gvar deltas of the four phantom points of `glyph`.
    fn phantoms(self: *const Font, glyph: u16) [4]geom.Vec2 {
        const g = self.glyphData(glyph) catch return @splat(.{});
        var points: usize = 0;
        if (g.len >= 10) {
            const contours = ri16(g, 0);
            if (contours > 0) {
                points = @as(usize, r16(g, 10 + @as(usize, @intCast(contours - 1)) * 2)) + 1;
            } else if (contours < 0) {
                points = componentCount(g) orelse return @splat(.{});
            }
        }
        return variation.phantomDeltas(self.vars.gvar, self.num_glyphs, glyph, self.normalizedCoords(), points);
    }

    /// The glyf data of `glyph` (empty for glyphs without outlines).
    fn glyphData(self: *const Font, glyph: u16) Error![]const u8 {
        if (glyph >= self.num_glyphs) return error.InvalidGlyph;
        const loca = self.tables.loca;
        const i: usize = glyph;
        const start: usize, const end: usize = if (self.long_loca)
            .{ r32(loca, i * 4), r32(loca, i * 4 + 4) }
        else
            .{ @as(usize, r16(loca, i * 2)) * 2, @as(usize, r16(loca, i * 2 + 2)) * 2 };
        if (start == end) return &.{};
        if (end < start or end > self.tables.glyf.len) return error.InvalidGlyph;
        return self.tables.glyf[start..end];
    }

    /// The bounding box of `glyph` from its glyf header (for CFF, the
    /// outline's exact extent rounded outwards), as
    /// [x_min, y_min, x_max, y_max]; null for empty glyphs. This is the
    /// default instance's box; `pointBounds` gives a varied instance's.
    pub fn glyphBounds(self: *const Font, glyph: u16) ?[4]i16 {
        if (self.tables.glyf.len == 0) {
            const c = self.cff_outlines orelse return null;
            if (glyph >= self.num_glyphs) return null;
            var b: cff.Bounds = .{};
            _ = c.outline(glyph, &b) catch return null;
            const r = b.rect;
            if (!(r.x1 >= r.x0 and r.y1 >= r.y0)) return null;
            return .{ clampI16(@floor(r.x0)), clampI16(@floor(r.y0)), clampI16(@ceil(r.x1)), clampI16(@ceil(r.y1)) };
        }
        const g = self.glyphData(glyph) catch return null;
        if (g.len < 10) return null;
        return .{ ri16(g, 2), ri16(g, 4), ri16(g, 6), ri16(g, 8) };
    }

    /// Appends the glyph outline to `path`, every point mapped through `m`
    /// (font units -> caller space; y is up in font units, so the caller's
    /// affine flips it). TrueType quadratics become exact cubics. Composite
    /// glyphs are resolved recursively, depth-limited. A varied instance
    /// applies the gvar deltas (component offsets included, untouched points
    /// interpolated) and keeps the left phantom point where it was. CFF
    /// fonts (no glyf) give their charstring outlines, cubics as they are.
    pub fn outline(self: *const Font, gpa: std.mem.Allocator, glyph: u16, m: geom.Affine, path: *geom.Path) Error!void {
        if (self.tables.glyf.len == 0 or self.tables.loca.len == 0) {
            const c = self.cff_outlines orelse return error.UnsupportedFont;
            if (glyph >= self.num_glyphs) return error.InvalidGlyph;
            var sink: CffPath = .{
                .gpa = gpa,
                .path = path,
                .m = m,
            };
            _ = try c.outline(glyph, &sink);
            return;
        }
        var o: Outline = .{};
        defer o.deinit(gpa);
        try self.loadGlyph(gpa, glyph, &o, 0);
        // The rasterizer places the outline by its left phantom point.
        const shift = o.phantom_dx;
        if (shift != 0) for (o.pts.items) |*q| {
            q.x -= shift;
        };
        try o.emit(gpa, m, path);
    }

    /// True when outlines take gvar deltas.
    fn variesOutlines(self: *const Font) bool {
        return self.varied and self.vars.gvar.len != 0;
    }

    /// The four phantom points of `glyph` (default instance): left and
    /// right ends of the advance, then top and bottom.
    fn phantomOrigins(self: *const Font, glyph: u16, x_min: i16) [4]geom.Vec2 {
        const left: f32 = @floatFromInt(@as(i32, x_min) - self.hmtxLsb(glyph));
        return .{
            .{
                .x = left,
                .y = 0,
            },
            .{
                .x = left + @as(f32, @floatFromInt(self.hmtxAdvance(glyph))),
                .y = 0,
            },
            .{
                .x = 0,
                .y = @floatFromInt(self.ascender),
            },
            .{
                .x = 0,
                .y = @floatFromInt(self.descender),
            },
        };
    }

    const max_depth = 8;
    const max_points = 1 << 20;

    fn loadGlyph(self: *const Font, gpa: std.mem.Allocator, glyph: u16, o: *Outline, depth: u8) Error!void {
        if (depth > max_depth) return error.InvalidGlyph;
        const g = try self.glyphData(glyph);
        if (g.len == 0) return;
        if (g.len < 10) return error.InvalidGlyph;
        const contours = ri16(g, 0);
        const vary = self.variesOutlines();
        if (contours >= 0) {
            const base = o.pts.items.len;
            const ends_base = o.ends.items.len;
            try loadSimple(gpa, g, @intCast(contours), o);
            if (!vary) return;
            // gvar deltas for the glyph's points and its phantom points.
            const n = o.pts.items.len - base;
            const origins = self.phantomOrigins(glyph, ri16(g, 2));
            try o.pts.appendSlice(gpa, &origins);
            try variation.applyGvar(gpa, self.vars.gvar, self.num_glyphs, glyph, self.normalizedCoords(), o.pts.items[base..], o.ends.items[ends_base..], base, &o.scratch);
            if (depth == 0) o.phantom_dx = o.pts.items[base + n].x - origins[0].x;
            o.pts.shrinkRetainingCapacity(base + n);
            return;
        }

        // Composite glyph: its gvar "points" are the component offsets.
        const comp_base = o.comp.items.len;
        defer o.comp.shrinkRetainingCapacity(comp_base);
        if (vary) {
            const ncomp = componentCount(g) orelse return error.InvalidGlyph;
            try o.comp.appendNTimes(gpa, .{}, ncomp);
            const origins = self.phantomOrigins(glyph, ri16(g, 2));
            try o.comp.appendSlice(gpa, &origins);
            try variation.applyGvar(gpa, self.vars.gvar, self.num_glyphs, glyph, self.normalizedCoords(), o.comp.items[comp_base..], &.{}, 0, &o.scratch);
            if (depth == 0) o.phantom_dx = o.comp.items[comp_base + ncomp].x - origins[0].x;
        }
        var component: usize = 0;

        // Point numbers count from the composite's first point.
        const first_point = o.pts.items.len;
        var p: usize = 10;
        while (true) {
            if (p + 4 > g.len) return error.InvalidGlyph;
            const flags = r16(g, p);
            const child = r16(g, p + 2);
            p += 4;
            var arg1: i32 = undefined;
            var arg2: i32 = undefined;
            const xy = flags & 0x0002 != 0;
            if (flags & 0x0001 != 0) {
                if (p + 4 > g.len) return error.InvalidGlyph;
                arg1 = if (xy) ri16(g, p) else r16(g, p);
                arg2 = if (xy) ri16(g, p + 2) else r16(g, p + 2);
                p += 4;
            } else {
                if (p + 2 > g.len) return error.InvalidGlyph;
                arg1 = if (xy) @as(i8, @bitCast(g[p])) else g[p];
                arg2 = if (xy) @as(i8, @bitCast(g[p + 1])) else g[p + 1];
                p += 2;
            }
            var a: f32 = 1;
            var b: f32 = 0;
            var c: f32 = 0;
            var d: f32 = 1;
            if (flags & 0x0008 != 0) {
                if (p + 2 > g.len) return error.InvalidGlyph;
                a = f2dot14(g, p);
                d = a;
                p += 2;
            } else if (flags & 0x0040 != 0) {
                if (p + 4 > g.len) return error.InvalidGlyph;
                a = f2dot14(g, p);
                d = f2dot14(g, p + 2);
                p += 4;
            } else if (flags & 0x0080 != 0) {
                if (p + 8 > g.len) return error.InvalidGlyph;
                a = f2dot14(g, p);
                b = f2dot14(g, p + 2);
                c = f2dot14(g, p + 4);
                d = f2dot14(g, p + 6);
                p += 8;
            }

            const start = o.pts.items.len;
            try self.loadGlyph(gpa, child, o, depth + 1);
            const pts = o.pts.items[start..];
            // x' = a*x + c*y, y' = b*x + d*y (b = scale01, c = scale10).
            for (pts) |*q| q.* = .{
                .x = a * q.x + c * q.y,
                .y = b * q.x + d * q.y,
            };
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (xy) {
                dx = @floatFromInt(arg1);
                dy = @floatFromInt(arg2);
                if (vary) {
                    const delta = o.comp.items[comp_base + component];
                    dx += delta.x;
                    dy += delta.y;
                }
                if (flags & 0x0800 != 0 and flags & 0x1000 == 0) {
                    const sx = a * dx + c * dy;
                    dy = b * dx + d * dy;
                    dx = sx;
                }
            } else {
                // Point matching: parent point arg1 meets child point arg2.
                const p1: usize = first_point + @as(usize, @intCast(arg1));
                const p2: usize = @intCast(arg2);
                if (p1 >= start or p2 >= pts.len) return error.InvalidGlyph;
                dx = o.pts.items[p1].x - pts[p2].x;
                dy = o.pts.items[p1].y - pts[p2].y;
            }
            for (pts) |*q| q.* = .{
                .x = q.x + dx,
                .y = q.y + dy,
            };
            component += 1;
            if (flags & 0x0020 == 0) break;
        }
    }

    /// Number of components of the composite glyph `g`; null when malformed.
    fn componentCount(g: []const u8) ?usize {
        var p: usize = 10;
        var n: usize = 0;
        while (true) {
            if (p + 4 > g.len) return null;
            const flags = r16(g, p);
            p += 4;
            p += if (flags & 0x0001 != 0) 4 else 2;
            if (flags & 0x0008 != 0) p += 2 else if (flags & 0x0040 != 0) p += 4 else if (flags & 0x0080 != 0) p += 8;
            n += 1;
            if (flags & 0x0020 == 0) return n;
        }
    }

    fn f2dot14(g: []const u8, p: usize) f32 {
        return @as(f32, @floatFromInt(ri16(g, p))) / 16384.0;
    }

    fn loadSimple(gpa: std.mem.Allocator, g: []const u8, contours: usize, o: *Outline) Error!void {
        if (contours == 0) return;
        var p: usize = 10;
        if (p + contours * 2 + 2 > g.len) return error.InvalidGlyph;
        const ends_at = p;
        p += contours * 2;
        const n_points: usize = @as(usize, r16(g, ends_at + (contours - 1) * 2)) + 1;
        const ins_len = r16(g, p);
        p += 2 + @as(usize, ins_len);
        if (p > g.len) return error.InvalidGlyph;
        if (o.pts.items.len + n_points > max_points) return error.InvalidGlyph;

        const base = o.pts.items.len;
        var prev_end: usize = 0;
        for (0..contours) |k| {
            const e = @as(usize, r16(g, ends_at + k * 2)) + 1;
            if (e < prev_end or e > n_points) return error.InvalidGlyph;
            prev_end = e;
            try o.ends.append(gpa, @intCast(base + e));
        }

        try o.pts.ensureUnusedCapacity(gpa, n_points);
        try o.on.ensureUnusedCapacity(gpa, n_points);
        o.flags.clearRetainingCapacity();
        try o.flags.ensureUnusedCapacity(gpa, n_points);
        // Flags, with repeats.
        while (o.flags.items.len < n_points) {
            if (p >= g.len) return error.InvalidGlyph;
            const fl = g[p];
            p += 1;
            var rep: usize = 1;
            if (fl & 8 != 0) {
                if (p >= g.len) return error.InvalidGlyph;
                rep += g[p];
                p += 1;
            }
            rep = @min(rep, n_points - o.flags.items.len);
            o.flags.appendNTimesAssumeCapacity(fl, rep);
        }
        const flags = o.flags.items;
        for (flags) |fl| {
            o.on.appendAssumeCapacity(fl & 1 != 0);
            o.pts.appendAssumeCapacity(.{});
        }
        const pts = o.pts.items[base..];
        // X then Y coordinates: short (u8 with sign flag), same, or i16 delta.
        inline for (.{ 0, 1 }) |axis| {
            const short: u8 = if (axis == 0) 0x02 else 0x04;
            const same: u8 = if (axis == 0) 0x10 else 0x20;
            var v: i32 = 0;
            for (pts, flags) |*q, fl| {
                if (fl & short != 0) {
                    if (p >= g.len) return error.InvalidGlyph;
                    const dv: i32 = g[p];
                    p += 1;
                    v +%= if (fl & same != 0) dv else -dv;
                } else if (fl & same == 0) {
                    if (p + 2 > g.len) return error.InvalidGlyph;
                    v +%= ri16(g, p);
                    p += 2;
                }
                if (axis == 0) q.x = @floatFromInt(v) else q.y = @floatFromInt(v);
            }
        }
    }

    /// True when the GSUB or GPOS of the shaping script (`latn`, else
    /// `DFLT`), default language system, has feature `tag`.
    pub fn hasFeature(self: *const Font, tag: [4]u8) bool {
        return self.gsub.hasFeature(tag) or self.gpos.hasFeature(tag);
    }

    /// GDEF glyph class: 1 base, 2 ligature, 3 mark, 4 component, 0 unknown.
    pub fn glyphClass(self: *const Font, glyph: u16) u8 {
        return @truncate(classOf(self.tables.gdef, self.gdef_class_def, glyph));
    }

    /// GDEF mark attachment class of `glyph` (0 when none).
    pub fn markAttachClass(self: *const Font, glyph: u16) u8 {
        return @truncate(classOf(self.tables.gdef, self.gdef_mark_attach_def, glyph));
    }

    /// True when `glyph` is in GDEF mark glyph set `set`.
    pub fn markSetHas(self: *const Font, set: u16, glyph: u16) bool {
        if (self.gdef_mark_sets == 0) return false;
        const d = self.tables.gdef;
        const base = self.gdef_mark_sets;
        if (r16(d, base) != 1 or set >= r16(d, base + 2)) return false;
        const off = r32(d, base + 4 + @as(usize, set) * 4);
        if (off == 0 or off >= d.len) return false;
        return coverageIndex(d, base + off, glyph) != null;
    }

    /// Legacy `kern` table format 0 adjustment for the pair (left, right), in font units.
    pub fn kernPair(self: *const Font, left: u16, right: u16) i16 {
        const d = self.tables.kern;
        if (d.len < 4) return 0;
        const key = @as(u32, left) << 16 | right;
        var total: i32 = 0;
        const apple = r16(d, 0) == 1;
        const n: usize = if (apple) r32(d, 4) else r16(d, 2);
        var p: usize = if (apple) 8 else 4;
        var k: usize = 0;
        while (k < n and k < 64 and p < d.len) : (k += 1) {
            const len: usize = if (apple) r32(d, p) else r16(d, p + 2);
            const coverage = r16(d, p + (if (apple) @as(usize, 4) else 4));
            const header: usize = if (apple) 8 else 6;
            const format = if (apple) coverage & 0xFF else coverage >> 8;
            const horizontal = if (apple) coverage & 0x8000 == 0 else coverage & 1 != 0;
            const cross = if (apple) coverage & 0x4000 != 0 else coverage & 4 != 0;
            const minimum = !apple and coverage & 2 != 0;
            if (format == 0 and horizontal and !cross and !minimum) {
                const t = p + header;
                const pairs: usize = r16(d, t);
                var lo: usize = 0;
                var hi: usize = pairs;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    const rec = t + 8 + mid * 6;
                    const kk = r32(d, rec);
                    if (kk < key) lo = mid + 1 else if (kk > key) hi = mid else {
                        const v = ri16(d, rec + 4);
                        // Bit 3 (MS): the value replaces the running total.
                        if (!apple and coverage & 8 != 0) total = v else total += v;
                        break;
                    }
                }
            }
            if (len == 0 or len >= d.len) break;
            p += len;
        }
        return @intCast(std.math.clamp(total, -32768, 32767));
    }
};

/// Rounds a variation delta to font units, halves upwards (as HarfBuzz does).
fn roundDelta(v: f32) f32 {
    return @floor(v + 0.5);
}

fn clampU16(v: f32) u16 {
    return @intFromFloat(std.math.clamp(v, 0, 65535));
}

fn clampI16(v: f32) i16 {
    return @intFromFloat(std.math.clamp(v, -32768, 32767));
}

/// Receives CFF outlines and appends them to a path through an affine.
const CffPath = struct {
    gpa: std.mem.Allocator,
    path: *geom.Path,
    m: geom.Affine,

    /// Starts a contour at `p`.
    pub fn moveTo(s: *CffPath, p: geom.Vec2) !void {
        try s.path.moveTo(s.gpa, s.m.apply(p));
    }

    /// A line to `p`.
    pub fn lineTo(s: *CffPath, p: geom.Vec2) !void {
        try s.path.lineTo(s.gpa, s.m.apply(p));
    }

    /// A cubic to `p`.
    pub fn cubicTo(s: *CffPath, c1: geom.Vec2, c2: geom.Vec2, p: geom.Vec2) !void {
        try s.path.cubicTo(s.gpa, s.m.apply(c1), s.m.apply(c2), s.m.apply(p));
    }

    /// Ends the contour.
    pub fn close(s: *CffPath) !void {
        try s.path.close(s.gpa);
    }
};

/// Glyph points in font units, with on-curve flags and contour ends.
/// Glyph outlines read once each, for drawing many glyphs (`Font.outline` reads the glyph
/// from the font again every time). The same points come out: what `Font.outline` emits
/// from the same outline. Keyed by the font's data and its variation (a face is a value:
/// copies at other coordinates share the data, and where one lives says nothing); forget
/// it when fonts go.
pub const OutlineCache = struct {
    const Key = struct {
        glyf: usize,
        coords: [max_axes]u32,
        glyph: u16,
    };
    map: std.AutoHashMapUnmanaged(Key, Outline) = .empty,

    pub fn deinit(self: *OutlineCache, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.map.deinit(gpa);
    }

    pub fn clear(self: *OutlineCache, gpa: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |o| o.deinit(gpa);
        self.map.clearRetainingCapacity();
    }

    /// `font.outline(gpa, glyph, m, path)`, the glyph read once.
    pub fn outline(self: *OutlineCache, gpa: std.mem.Allocator, font: *const Font, glyph: u16, m: geom.Affine, path: *geom.Path) Error!void {
        if (font.tables.glyf.len == 0 or font.tables.loca.len == 0) return font.outline(gpa, glyph, m, path);
        var coords: [max_axes]u32 = @splat(0);
        if (font.variesOutlines()) for (&coords, font.coords) |*k, c| {
            k.* = @bitCast(c);
        };
        const got = try self.map.getOrPut(gpa, .{
            .glyf = @intFromPtr(font.tables.glyf.ptr),
            .coords = coords,
            .glyph = glyph,
        });
        if (!got.found_existing) {
            got.value_ptr.* = .{};
            errdefer {
                got.value_ptr.deinit(gpa);
                _ = self.map.remove(got.key_ptr.*);
            }
            const o = got.value_ptr;
            try font.loadGlyph(gpa, glyph, o, 0);
            const shift = o.phantom_dx;
            if (shift != 0) for (o.pts.items) |*q| {
                q.x -= shift;
            };
            // Only what `emit` reads stays.
            o.scratch.deinit(gpa);
            o.scratch = .{};
            o.comp.deinit(gpa);
            o.comp = .empty;
            o.flags.deinit(gpa);
            o.flags = .empty;
        }
        try got.value_ptr.emit(gpa, m, path);
    }
};

const Outline = struct {
    pts: std.ArrayList(geom.Vec2) = .empty,
    on: std.ArrayList(bool) = .empty,
    ends: std.ArrayList(u32) = .empty,
    /// Scratch: the flags of the simple glyph being read.
    flags: std.ArrayList(u8) = .empty,
    /// Scratch: gvar deltas of the component offsets of the composites
    /// being read (a stack, one frame per nesting level).
    comp: std.ArrayList(geom.Vec2) = .empty,
    /// Scratch for applying gvar deltas.
    scratch: variation.Scratch = .{},
    /// How far the gvar deltas moved the top-level glyph's left phantom point.
    phantom_dx: f32 = 0,

    fn deinit(o: *Outline, gpa: std.mem.Allocator) void {
        o.scratch.deinit(gpa);
        o.comp.deinit(gpa);
        o.flags.deinit(gpa);
        o.pts.deinit(gpa);
        o.on.deinit(gpa);
        o.ends.deinit(gpa);
    }

    /// Writes the contours to `path`: lines between on-curve points, and each
    /// quadratic (with implied on-curve midpoints) as its exact cubic.
    fn emit(o: *const Outline, gpa: std.mem.Allocator, m: geom.Affine, path: *geom.Path) !void {
        var start: usize = 0;
        for (o.ends.items) |end_u| {
            const end: usize = end_u;
            defer start = end;
            if (end <= start or end > o.pts.items.len) continue;
            const pts = o.pts.items[start..end];
            const on = o.on.items[start..end];
            const n = pts.len;
            // Pick a starting on-curve point (or the midpoint of two off-curve points).
            var first: geom.Vec2 = undefined;
            var k0: usize = 0;
            if (on[0]) {
                first = pts[0];
                k0 = 1;
            } else if (on[n - 1]) {
                first = pts[n - 1];
                k0 = 0;
            } else {
                first = pts[0].lerp(pts[n - 1], 0.5);
                k0 = 0;
            }
            const steps = if (on[0]) n - 1 else if (on[n - 1]) n - 1 else n;
            try path.moveTo(gpa, m.apply(first));
            var cur = first;
            var ctrl: ?geom.Vec2 = null;
            var s: usize = 0;
            while (s <= steps) : (s += 1) {
                // After the last point, close back to `first`.
                const last = s == steps;
                const p = if (last) first else pts[(k0 + s) % n];
                const p_on = last or on[(k0 + s) % n];
                if (p_on) {
                    if (ctrl) |c| {
                        try quad(gpa, path, m, cur, c, p);
                        ctrl = null;
                    } else if (!last or cur.x != first.x or cur.y != first.y) {
                        try path.lineTo(gpa, m.apply(p));
                    }
                    cur = p;
                } else {
                    if (ctrl) |c| {
                        const mid = c.lerp(p, 0.5);
                        try quad(gpa, path, m, cur, c, mid);
                        cur = mid;
                    }
                    ctrl = p;
                }
            }
            try path.close(gpa);
        }
    }

    fn quad(gpa: std.mem.Allocator, path: *geom.Path, m: geom.Affine, p0: geom.Vec2, c: geom.Vec2, p1: geom.Vec2) !void {
        const c1 = p0.add(c.sub(p0).scale(2.0 / 3.0));
        const c2 = p1.add(c.sub(p1).scale(2.0 / 3.0));
        try path.cubicTo(gpa, m.apply(c1), m.apply(c2), m.apply(p1));
    }
};

/// Decodes name `id` (Windows Unicode, English preferred; then Unicode
/// platform; then Mac Roman ASCII) into UTF-8 in `arena`.
fn readName(arena: std.mem.Allocator, d: []const u8, id: u16) !?[]const u8 {
    const count: usize = r16(d, 2);
    const strings: usize = r16(d, 4);
    var best: ?usize = null;
    var best_score: u8 = 0;
    for (0..count) |k| {
        const rec = 6 + k * 12;
        if (r16(d, rec + 6) != id) continue;
        const platform = r16(d, rec);
        const encoding = r16(d, rec + 2);
        const lang = r16(d, rec + 4);
        const score: u8 = switch (platform) {
            3 => if (encoding != 1 and encoding != 10 and encoding != 0) 0 else if (lang == 0x409) 6 else 4,
            0 => 3,
            1 => if (encoding == 0 and lang == 0) 2 else 0,
            else => 0,
        };
        if (score > best_score) {
            best_score = score;
            best = rec;
        }
    }
    const rec = best orelse return null;
    const bytes = sub(d, strings + r16(d, rec + 10), r16(d, rec + 8)) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    if (r16(d, rec) == 1) {
        for (bytes) |b| try out.append(arena, if (b < 0x80) b else '?');
        return out.items;
    }
    var i: usize = 0;
    var buf: [4]u8 = undefined;
    while (i + 2 <= bytes.len) : (i += 2) {
        var cp: u21 = r16(bytes, i);
        if (cp >= 0xD800 and cp < 0xDC00 and i + 4 <= bytes.len) {
            const lo = r16(bytes, i + 2);
            if (lo >= 0xDC00 and lo < 0xE000) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            }
        }
        const n = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
        try out.appendSlice(arena, buf[0..n]);
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests.

const testing = std.testing;

/// Loads a corpus font into `gpa` memory; skips the test when the corpus is absent.
pub fn testFont(gpa: std.mem.Allocator, file: []const u8) ![]u8 {
    // Fonts live in per-family folders: corpus/fonts/WorkSans/WorkSans-Bold.ttf.
    const family = file[0 .. std.mem.indexOfScalar(u8, file, '-') orelse file.len];
    var buf: [96]u8 = undefined;
    const folder = std.fmt.bufPrint(&buf, "fonts/{s}", .{family}) catch "fonts";
    return testFontIn(gpa, folder, file) catch |err| switch (err) {
        error.SkipZigTest => testFontIn(gpa, "fonts", file),
        else => err,
    };
}

/// Like `testFont`, for a font in corpus/`folder`.
pub fn testFontIn(gpa: std.mem.Allocator, folder: []const u8, file: []const u8) ![]u8 {
    const io = testing.io;
    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "corpus/", "/Users/dawid/Documents/publrv2/publr-design/engine/corpus/" }) |root| {
        var dbuf: [128]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dbuf, "{s}{s}/", .{ root, folder });
        const path = try std.fmt.bufPrint(&buf, "{s}{s}", .{ dir, file });
        return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
    return error.SkipZigTest;
}

test "parse every Work Sans face" {
    const files = [_][]const u8{
        "WorkSans-Regular.ttf",
        "WorkSans-Medium.ttf",
        "WorkSans-SemiBold.ttf",
        "WorkSans-Bold.ttf",
        "WorkSans-Italic.ttf",
        "WorkSans-BoldItalic.ttf",
    };
    const weights = [_]u16{ 400, 500, 600, 700, 400, 700 };
    for (files, weights, 0..) |file, weight, k| {
        const bytes = try testFont(testing.allocator, file);
        defer testing.allocator.free(bytes);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const f = try Font.parse(arena.allocator(), bytes);
        try testing.expectEqual(@as(u16, 1000), f.units_per_em);
        try testing.expectEqualStrings("Work Sans", f.family);
        try testing.expect(f.ascender > 500 and f.ascender < 1500);
        try testing.expect(f.descender < 0 and f.descender > -500);
        try testing.expect(f.x_height > 300 and f.x_height < f.cap_height);
        try testing.expect(f.cap_height < f.ascender);
        try testing.expect(f.underline_thickness > 0);
        try testing.expect(f.strikeout_size > 0 and f.strikeout_position > 0);
        try testing.expectEqual(weight, f.weight_class);
        try testing.expectEqual(k >= 4, f.italic);
        try testing.expect(f.glyphIndex('A') != 0);
        try testing.expect(f.glyphIndex(0x10FFFF) == 0);
        try testing.expect(f.advance(f.glyphIndex('A')) > 0);
        try testing.expect(f.gsub.present() and f.gpos.present());
    }
}

test "outline of O stays inside its glyf bounding box" {
    const gpa = testing.allocator;
    const bytes = try testFont(gpa, "WorkSans-Regular.ttf");
    defer gpa.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const f = try Font.parse(arena.allocator(), bytes);
    for ([_]u21{ 'O', '@', '&', 'g', '8', 0xC5 }) |ch| {
        const g = f.glyphIndex(ch);
        try testing.expect(g != 0);
        var path: geom.Path = .{};
        defer path.deinit(gpa);
        try f.outline(gpa, g, .identity, &path);
        try testing.expect(path.verbs.items.len > 4);
        const box = f.glyphBounds(g).?;
        const r = path.bounds();
        try testing.expect(r.x0 >= @as(f32, @floatFromInt(box[0])) - 0.01);
        try testing.expect(r.y0 >= @as(f32, @floatFromInt(box[1])) - 0.01);
        try testing.expect(r.x1 <= @as(f32, @floatFromInt(box[2])) + 0.01);
        try testing.expect(r.y1 <= @as(f32, @floatFromInt(box[3])) + 0.01);
        // The on-curve extremes of O reach its box.
        if (ch == 'O') {
            try testing.expect(r.x1 - r.x0 > @as(f32, @floatFromInt(box[2] - box[0])) - 2);
            try testing.expect(r.y1 - r.y0 > @as(f32, @floatFromInt(box[3] - box[1])) - 2);
        }
    }
    // A composite: Aring (or any accented glyph) has an outline too.
    var path: geom.Path = .{};
    defer path.deinit(gpa);
    try f.outline(gpa, f.glyphIndex(0xC5), geom.Affine.scaling(0.01, -0.01), &path);
    try testing.expect(path.verbs.items.len > 4);
    // Space has no outline; bad glyph ids are errors.
    var empty: geom.Path = .{};
    defer empty.deinit(gpa);
    try f.outline(gpa, f.glyphIndex(' '), .identity, &empty);
    try testing.expectEqual(@as(usize, 0), empty.verbs.items.len);
    try testing.expectError(error.InvalidGlyph, f.outline(gpa, 0xFFFF, .identity, &empty));
}

test "Work Sans layout features" {
    const gpa = testing.allocator;
    const bytes = try testFont(gpa, "WorkSans-Regular.ttf");
    defer gpa.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const f = try Font.parse(arena.allocator(), bytes);
    for ([_]*const [4]u8{ "liga", "kern", "mark", "mkmk", "ccmp", "calt", "tnum", "frac", "case", "ss01" }) |t| try testing.expect(f.hasFeature(t.*));
    // This build of Work Sans has real small capitals.
    try testing.expect(f.hasFeature("smcp".*));
    try testing.expect(f.hasFeature("c2sc".*));
    try testing.expect(!f.hasFeature("zzzz".*));
}

test "malformed fonts are errors, not panics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidFont, Font.parse(arena.allocator(), ""));
    try testing.expectError(error.InvalidFont, Font.parse(arena.allocator(), "\x00\x01\x00\x00\x00\x40"));
    const bytes = try testFont(testing.allocator, "WorkSans-Regular.ttf");
    defer testing.allocator.free(bytes);
    // Truncations at many lengths must never crash.
    var len: usize = 0;
    while (len < bytes.len) : (len += bytes.len / 97 + 1) {
        const f = Font.parse(arena.allocator(), bytes[0..len]) catch continue;
        _ = f.glyphIndex('A');
        var path: geom.Path = .{};
        defer path.deinit(testing.allocator);
        f.outline(testing.allocator, f.glyphIndex('O'), .identity, &path) catch {};
        _ = f.hasFeature("liga".*);
    }
}

// ---------------------------------------------------------------------------
// Variable font tests (corpus/fonts-variable: Google Fonts' Work Sans[wght]).

const VarTest = struct {
    bytes: []u8,
    arena: std.heap.ArenaAllocator,
    font: Font,

    fn load(file: []const u8) !*VarTest {
        const t = try testing.allocator.create(VarTest);
        errdefer testing.allocator.destroy(t);
        t.bytes = try testFontIn(testing.allocator, "fonts-variable", file);
        t.arena = .init(testing.allocator);
        t.font = try Font.parse(t.arena.allocator(), t.bytes);
        return t;
    }

    fn deinit(t: *VarTest) void {
        t.arena.deinit();
        testing.allocator.free(t.bytes);
        testing.allocator.destroy(t);
    }

    fn at(t: *const VarTest, wght: f32) Font {
        var f = t.font;
        f.setVariation(&.{.{
            .tag = "wght".*,
            .value = wght,
        }});
        return f;
    }
};

test "variable Work Sans: axes, avar and named instances" {
    const t = try VarTest.load("WorkSans[wght].ttf");
    defer t.deinit();
    const f = &t.font;
    try testing.expectEqual(@as(usize, 1), f.axes().len);
    const a = f.axes()[0];
    try testing.expectEqualStrings("wght", &a.tag);
    try testing.expectEqual(@as(f32, 100), a.min);
    try testing.expectEqual(@as(f32, 400), a.default);
    try testing.expectEqual(@as(f32, 900), a.max);
    try testing.expectEqualStrings("Weight", a.name);
    try testing.expect(!f.varied);
    try testing.expectEqual(@as(?f32, 400), f.axisValue("wght".*));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const inst = try f.namedInstances(arena.allocator());
    const names = [_][]const u8{ "Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Black" };
    try testing.expectEqual(names.len, inst.len);
    for (inst, names, 0..) |in, name, k| {
        try testing.expectEqualStrings(name, in.subfamily);
        try testing.expectEqual(@as(usize, 1), in.values.len);
        try testing.expectEqual(@as(f32, @floatFromInt(100 * (k + 1))), in.values[0].value);
        try testing.expect(in.postscript_name != null);
        try testing.expect(std.mem.startsWith(u8, in.postscript_name.?, "WorkSansRoman-"));
        try testing.expect(std.mem.endsWith(u8, in.postscript_name.?, name));
    }

    // Normalization: the ends map to -1 and 1, the default to 0; avar
    // bends the values in between (monotonically).
    var prev: f32 = -2;
    var w: f32 = 100;
    while (w <= 900) : (w += 50) {
        const g = t.at(w);
        const c = g.coords[0];
        try testing.expect(c > prev);
        prev = c;
        try testing.expectEqual(w != 400, g.varied);
        try testing.expectEqual(@as(u16, @intFromFloat(w)), g.weight_class);
    }
    try testing.expectEqual(@as(f32, -1), t.at(100).coords[0]);
    try testing.expectEqual(@as(f32, 1), t.at(900).coords[0]);
    try testing.expectEqual(@as(f32, 1), t.at(5000).coords[0]);
    // avar: wght 500 is 0.2 linearly, mapped to its F2Dot14 neighbourhood.
    const c500 = t.at(500).coords[0];
    try testing.expect(c500 > 0.1 and c500 < 0.3 and c500 != quantizeTest(0.2));
    // Unknown tags are ignored; the instance stays the default one.
    var g = t.font;
    g.setVariation(&.{.{
        .tag = "wdth".*,
        .value = 50,
    }});
    try testing.expect(!g.varied);
}

fn clearPath(p: *geom.Path) void {
    p.verbs.clearRetainingCapacity();
    p.points.clearRetainingCapacity();
}

fn quantizeTest(v: f32) f32 {
    return @round(v * 16384) / 16384;
}

test "variable Work Sans: default instance equals the static path" {
    const gpa = testing.allocator;
    const t = try VarTest.load("WorkSans[wght].ttf");
    defer t.deinit();
    const f = &t.font;
    // The variation code with all-zero coordinates must change nothing.
    var forced = t.at(400);
    forced.varied = true;
    var a: geom.Path = .{};
    defer a.deinit(gpa);
    var b: geom.Path = .{};
    defer b.deinit(gpa);
    var g: u16 = 0;
    while (g < f.num_glyphs) : (g += 1) {
        try testing.expectEqual(f.advance(g), forced.advance(g));
        try testing.expectEqual(f.leftSideBearing(g), forced.leftSideBearing(g));
        clearPath(&a);
        clearPath(&b);
        try f.outline(gpa, g, .identity, &a);
        try forced.outline(gpa, g, .identity, &b);
        try testing.expectEqualSlices(geom.Vec2, a.points.items, b.points.items);
    }
    try testing.expectEqual(f.metrics(), forced.metrics());
}

test "variable Work Sans: outline extents and advances match HarfBuzz" {
    const gpa = testing.allocator;
    const t = try VarTest.load("WorkSans[wght].ttf");
    defer t.deinit();
    // From `hb-shape --variations=wght=N --font-funcs=ot --no-glyph-names
    // --show-extents` (HarfBuzz 14.4.0) on "OgaR@&": advance, then
    // x_bearing, y_bearing, width, height.
    const Ref = struct {
        wght: f32,
        ext: [6][5]i32,
    };
    const refs = [_]Ref{
        .{
            .wght = 500,
            .ext = .{
                .{ 745, 61, 670, 623, -680 },
                .{ 540, 32, 605, 508, -820 },
                .{ 570, 54, 510, 496, -520 },
                .{ 672, 98, 660, 539, -660 },
                .{ 950, 59, 662, 835, -854 },
                .{ 630, 41, 670, 590, -680 },
            },
        },
        .{
            .wght = 650,
            .ext = .{
                .{ 739, 49, 670, 641, -680 },
                .{ 555, 25, 627, 529, -842 },
                .{ 577, 39, 510, 528, -520 },
                .{ 685, 80, 660, 586, -660 },
                .{ 936, 46, 664, 842, -851 },
                .{ 642, 29, 670, 610, -680 },
            },
        },
    };
    for (refs) |ref| {
        const f = t.at(ref.wght);
        for ("OgaR@&", ref.ext) |ch, e| {
            const g = f.glyphIndex(ch);
            try testing.expectEqual(@as(u16, @intCast(e[0])), f.advance(g));
            var path: geom.Path = .{};
            defer path.deinit(gpa);
            try f.outline(gpa, g, .identity, &path);
            const r = path.bounds();
            const want = [4]f32{
                @floatFromInt(e[1]),
                @floatFromInt(e[2] + e[4]),
                @floatFromInt(e[1] + e[3]),
                @floatFromInt(e[2]),
            };
            const got = [4]f32{ r.x0, r.y0, r.x1, r.y1 };
            for (want, got) |w, v| try testing.expect(@abs(w - v) <= 1);
        }
    }
}

test "variable Work Sans at wght 500 against the static Medium" {
    const gpa = testing.allocator;
    const t = try VarTest.load("WorkSans[wght].ttf");
    defer t.deinit();
    const bytes = try testFont(gpa, "WorkSans-Medium.ttf");
    defer gpa.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const stat = try Font.parse(arena.allocator(), bytes);
    const vf = t.at(500);
    var max_point: f32 = 0;
    var max_box: f32 = 0;
    var max_adv: i32 = 0;
    var adv_diffs: usize = 0;
    var mismatched_shapes: usize = 0;
    var chars: usize = 0;
    for ([_][2]u8{ .{ 'A', 'Z' }, .{ 'a', 'z' }, .{ '0', '9' } }) |range| {
        var ch = range[0];
        while (ch <= range[1]) : (ch += 1) {
            chars += 1;
            const gv = vf.glyphIndex(ch);
            const gs = stat.glyphIndex(ch);
            const da = @as(i32, vf.advance(gv)) - stat.advance(gs);
            if (da != 0) adv_diffs += 1;
            max_adv = @max(max_adv, @as(i32, @intCast(@abs(da))));
            var pv: geom.Path = .{};
            defer pv.deinit(gpa);
            var ps: geom.Path = .{};
            defer ps.deinit(gpa);
            try vf.outline(gpa, gv, .identity, &pv);
            try stat.outline(gpa, gs, .identity, &ps);
            if (vf.pointBounds(gv)) |bv| {
                const bs = stat.pointBounds(gs).?;
                for (bv, bs) |x, y| max_box = @max(max_box, @abs(x - y));
            }
            if (pv.points.items.len != ps.points.items.len) {
                mismatched_shapes += 1;
                continue;
            }
            // Contours may start at different points: compare each point
            // with the nearest point of the other outline, both ways.
            for ([2]*const geom.Path{ &pv, &ps }, [2]*const geom.Path{ &ps, &pv }) |x, y| {
                for (x.points.items) |a| {
                    var best = std.math.inf(f32);
                    for (y.points.items) |b| best = @min(best, @max(@abs(a.x - b.x), @abs(a.y - b.y)));
                    max_point = @max(max_point, best);
                }
            }
        }
    }
    // Different builds: reported (in release builds), not asserted.
    if (@import("builtin").mode != .Debug) std.debug.print("wght 500 vs WorkSans-Medium.ttf over {d} characters: max point-to-nearest-point difference {d:.2} units " ++
        "over the glyphs with equal point counts ({d} glyphs differ in point count), max point bounding box difference {d:.2}, " ++
        "{d} advances differ (max {d})\n", .{ chars, max_point, mismatched_shapes, max_box, adv_diffs, max_adv });
}

test "variable fonts: rvrn and italic instances" {
    const gpa = testing.allocator;
    const shape = @import("shape.zig");
    for ([_][]const u8{ "WorkSans[wght].ttf", "WorkSans-Italic[wght].ttf" }, [_]bool{ false, true }) |file, italic| {
        const t = try VarTest.load(file);
        defer t.deinit();
        try testing.expectEqual(italic, t.font.italic);
        try testing.expect(t.font.gsub.feature_variations != 0);
        // FeatureVariations swap in heavier dollar and cent signs past
        // their axis threshold (HarfBuzz: dollar.BRACKET.202 at wght 900).
        const regular = t.at(400);
        const black = t.at(900);
        try testing.expect(regular.gsub.feature_subst != black.gsub.feature_subst);
        try testing.expectEqual(italic, black.italic);
        try testing.expectEqual(@as(u16, 900), black.weight_class);
        var a: std.ArrayList(shape.Glyph) = .empty;
        defer a.deinit(gpa);
        var b: std.ArrayList(shape.Glyph) = .empty;
        defer b.deinit(gpa);
        try shape.shape(gpa, &regular, "$", 0, &.{}, &a);
        try shape.shape(gpa, &black, "$", 0, &.{}, &b);
        try testing.expectEqual(regular.glyphIndex('$'), a.items[0].id);
        try testing.expect(b.items[0].id != a.items[0].id);
        // Turning rvrn off keeps the default glyph.
        b.clearRetainingCapacity();
        try shape.shape(gpa, &black, "$", 0, &.{.{
            .tag = "rvrn".*,
            .on = false,
        }}, &b);
        try testing.expectEqual(a.items[0].id, b.items[0].id);
    }
}

test "malformed variation tables never crash" {
    const gpa = testing.allocator;
    const bytes = try testFontIn(gpa, "fonts-variable", "WorkSans[wght].ttf");
    defer gpa.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const glyphs = "OgaR@&Å$₡ffi";
    const values = [_]f32{ 100, 333, 650, 900 };
    // Truncations.
    var len: usize = 0;
    while (len < bytes.len) : (len += bytes.len / 61 + 1) {
        var f = Font.parse(arena.allocator(), bytes[0..len]) catch continue;
        for (values) |w| {
            f.setVariation(&.{.{
                .tag = "wght".*,
                .value = w,
            }});
            try exercise(gpa, &f, glyphs);
        }
    }
    // Random corruption of each variation table.
    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    var ranges: [8][2]usize = undefined;
    var nr: usize = 0;
    for (0..r16(bytes, 4)) |k| {
        const rec = 12 + k * 16;
        for ([_]*const [4]u8{ "fvar", "avar", "gvar", "HVAR", "GDEF", "GSUB", "GPOS" }) |want| {
            if (std.mem.eql(u8, bytes[rec..][0..4], want)) {
                ranges[nr] = .{ r32(bytes, rec + 8), r32(bytes, rec + 12) };
                nr += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 7), nr);
    var prng: std.Random.DefaultPrng = .init(0x7a51);
    const rand = prng.random();
    for (0..300) |_| {
        @memcpy(copy, bytes);
        const r = ranges[rand.uintLessThan(usize, nr)];
        // Headers are where the offsets are: hit them more often.
        const span = if (rand.boolean()) @min(r[1], 64) else r[1];
        for (0..rand.uintLessThan(usize, 16) + 1) |_| copy[r[0] + rand.uintLessThan(usize, span)] = rand.int(u8);
        var f = Font.parse(arena.allocator(), copy) catch continue;
        _ = f.namedInstances(arena.allocator()) catch {};
        f.setVariation(&.{.{
            .tag = "wght".*,
            .value = values[rand.uintLessThan(usize, values.len)],
        }});
        try exercise(gpa, &f, glyphs);
    }
}

fn exercise(gpa: std.mem.Allocator, f: *const Font, text: []const u8) !void {
    _ = gpa;
    // A production allocator: the testing one makes hundreds of fuzzed
    // fonts take minutes (leaks are covered by the other tests).
    const a = std.heap.smp_allocator;
    const shape = @import("shape.zig");
    var out: std.ArrayList(shape.Glyph) = .empty;
    defer out.deinit(a);
    try shape.shape(a, f, text, 0, &.{}, &out);
    for (out.items) |g| {
        _ = f.advance(g.id);
        _ = f.leftSideBearing(g.id);
        _ = f.pointBounds(g.id);
        var path: geom.Path = .{};
        defer path.deinit(a);
        f.outline(a, g.id, .identity, &path) catch {};
    }
}

test "varied outlines are fast" {
    // A production allocator: the testing one checks every call.
    const gpa = std.heap.smp_allocator;
    const t = try VarTest.load("WorkSans[wght].ttf");
    defer t.deinit();
    const f = t.at(650);
    const text = "The quick brown fox jumps over the lazy dog. AVATAR 0123456789 &@?!";
    var glyphs: [text.len]u16 = undefined;
    for (text, &glyphs) |ch, *g| g.* = f.glyphIndex(ch);
    var path: geom.Path = .{};
    defer path.deinit(gpa);
    const io = testing.io;
    const runs = 200;
    var timings: [2]i96 = undefined;
    for ([_]Font{ t.font, f }, 0..) |font, k| {
        const start = std.Io.Timestamp.now(io, .awake);
        for (0..runs) |_| for (glyphs) |g| {
            clearPath(&path);
            try font.outline(gpa, g, .identity, &path);
        };
        timings[k] = @divTrunc(start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds, runs * glyphs.len);
    }
    if (@import("builtin").mode != .Debug) {
        std.debug.print("outline: {d} ns per glyph static, {d} ns varied\n", .{ timings[0], timings[1] });
        try testing.expect(timings[1] < 10_000);
    }
}

test "variable Inter: MVAR metrics match HarfBuzz" {
    const t = try VarTest.load("Inter[opsz,wght].ttf");
    defer t.deinit();
    // From `hb-info --variations=... --list-metrics` (HarfBuzz 14.4.0):
    // opsz, wght, then x-height, cap height, strikeout size and offset,
    // underline size and offset.
    const refs = [_][8]f32{
        .{ 14, 400, 1118, 1490, 140, 671, 140, -348 },
        .{ 32, 700, 1056, 1490, 205, 634, 205, -143 },
        .{ 20, 150, 1097, 1490, 62, 659, 62, -367 },
    };
    for (refs) |r| {
        var f = t.font;
        f.setVariation(&.{ .{
            .tag = "opsz".*,
            .value = r[0],
        }, .{
            .tag = "wght".*,
            .value = r[1],
        } });
        const m = f.metrics();
        const got = [6]i32{ m.x_height, m.cap_height, m.strikeout_size, m.strikeout_position, m.underline_thickness, m.underline_position };
        for (got, r[2..]) |g, w| try testing.expectEqual(@as(i32, @intFromFloat(w)), g);
        // The fields and metrics() agree.
        try testing.expectEqual(m.x_height, f.x_height);
    }
}

test "CFF fonts on this machine: every glyph outlines, widths match hmtx" {
    // macOS system fonts with PostScript outlines, read in place when present:
    // name-keyed (STIX, Noto, Kohinoor) and CID-keyed (Apple SD Gothic Neo).
    const gpa = testing.allocator;
    const files = [_][]const u8{
        "/System/Library/Fonts/Supplemental/STIXGeneral.otf",
        "/System/Library/Fonts/Supplemental/NotoSansJavanese-Regular.otf",
        "/System/Library/Fonts/Kohinoor.ttc",
        "/System/Library/Fonts/AppleSDGothicNeo.ttc",
    };
    var found = false;
    for (files) |file| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, file, gpa, .limited(64 << 20)) catch continue;
        defer gpa.free(bytes);
        found = true;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const f = try Font.parse(arena.allocator(), bytes);
        const c = f.cff_outlines orelse return error.TestUnexpectedResult;
        var nonempty: usize = 0;
        var path: geom.Path = .{};
        defer path.deinit(gpa);
        for (0..f.num_glyphs) |gi| {
            const g: u16 = @intCast(gi);
            path.verbs.clearRetainingCapacity();
            path.points.clearRetainingCapacity();
            try f.outline(gpa, g, .identity, &path);
            var b: cff.Bounds = .{};
            const w = try c.outline(g, &b);
            try testing.expectEqual(@as(f32, @floatFromInt(f.advance(g))), @round(w));
            if (path.verbs.items.len == 0) {
                try testing.expect(f.glyphBounds(g) == null);
                continue;
            }
            nonempty += 1;
            // The exact extent lies inside the control points and reaches the on-curve ones.
            const box = f.glyphBounds(g).?;
            const r = path.bounds();
            try testing.expect(@as(f32, @floatFromInt(box[0])) >= @floor(r.x0) and @as(f32, @floatFromInt(box[2])) <= @ceil(r.x1));
            try testing.expect(@as(f32, @floatFromInt(box[1])) >= @floor(r.y0) and @as(f32, @floatFromInt(box[3])) <= @ceil(r.y1));
        }
        try testing.expect(nonempty * 10 > @as(usize, f.num_glyphs) * 9);
    }
    // A CFF2 (variable) font parses, but its outlines are unsupported.
    if (std.Io.Dir.cwd().readFileAlloc(testing.io, "/System/Library/Fonts/SFIndia.ttc", gpa, .limited(64 << 20))) |bytes| {
        defer gpa.free(bytes);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const f = try Font.parse(arena.allocator(), bytes);
        var path: geom.Path = .{};
        defer path.deinit(gpa);
        try testing.expectError(error.UnsupportedFont, f.outline(gpa, f.glyphIndex('A'), .identity, &path));
        try testing.expect(f.glyphBounds(f.glyphIndex('A')) == null);
    } else |_| {}
    if (!found) return error.SkipZigTest;
}
