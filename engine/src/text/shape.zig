//! Latin text shaping: maps a UTF-8 run to positioned glyphs with the
//! font's GSUB and GPOS lookups (or its legacy `kern` table), following the
//! default behaviour of OpenType shapers for left-to-right Latin text.
//!
//! Written from the OpenType specification (GSUB, GPOS, GDEF chapters).

const std = @import("std");
const font_mod = @import("font.zig");
const Font = font_mod.Font;
const Layout = font_mod.Layout;
const r16 = font_mod.r16;
const ri16 = font_mod.ri16;
const r32 = font_mod.r32;
const coverageIndex = font_mod.coverageIndex;
const classOf = font_mod.classOf;

/// One shaped glyph. All values are in font units.
pub const Glyph = struct {
    id: u16,
    /// Index of the first input code unit (UTF-16 code unit index into the
    /// original text) the glyph came from.
    cluster: u32,
    x_advance: i32,
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
};

/// A feature to turn on or off on top of the defaults.
pub const Feature = struct {
    tag: [4]u8,
    on: bool = true,
};

/// Features on unless turned off: what shapers apply to horizontal Latin
/// text by default. `rvrn` runs in a stage of its own before the rest.
pub const default_features = [_][4]u8{
    "rvrn".*, "ltra".*, "ltrm".*, "ccmp".*, "locl".*, "rlig".*, "liga".*, "clig".*,
    "calt".*, "rclt".*, "kern".*, "mark".*, "mkmk".*, "abvm".*, "blwm".*, "dist".*,
};

/// Shapes one run (single font, left to right). `text` is UTF-8 (invalid
/// bytes become U+FFFD); clusters count UTF-16 code units from
/// `cluster_base`. Glyphs are appended to `out`.
pub fn shape(gpa: std.mem.Allocator, font: *const Font, text: []const u8, cluster_base: u32, features: []const Feature, out: *std.ArrayList(Glyph)) !void {
    var buf: Buffer = .{};
    defer buf.deinit(gpa);
    // Characters, with their clusters.
    var chars: std.ArrayList(Char) = .empty;
    defer chars.deinit(gpa);
    try chars.ensureTotalCapacity(gpa, text.len + 8);
    var it: Utf8 = .{
        .s = text,
    };
    var unit: u32 = cluster_base;
    while (it.next()) |cp| {
        try chars.append(gpa, .{
            .cp = cp,
            .glyph = font.glyphIndex(cp),
            .cluster = unit,
        });
        unit += if (cp >= 0x10000) 2 else 1;
    }
    try normalize(gpa, font, &chars);

    // Characters to glyphs. Marks and joiners join the cluster before them.
    const space = font.glyphIndex(' ');
    try buf.infos.ensureTotalCapacity(gpa, chars.items.len);
    for (chars.items, 0..) |ch, i| {
        var g = ch.glyph;
        if (g == 0) g = fallbackGlyph(font, ch.cp, space);
        var flags: u8 = 0;
        if (isDefaultIgnorable(ch.cp)) flags |= if (ch.cp == 0x200C) hidden else hidden | skippable;
        var cluster = ch.cluster;
        if (i > 0 and isContinuation(ch.cp)) cluster = buf.infos.items[i - 1].cluster;
        buf.infos.appendAssumeCapacity(.{
            .glyph = g,
            .cluster = cluster,
            .class = font.glyphClass(g),
            .attach_class = font.markAttachClass(g),
            .flags = flags,
        });
    }
    if (buf.infos.items.len == 0) return;

    var plan: Plan = .{};
    defer plan.deinit(gpa);
    try plan.init(gpa, font, features);

    // Substitution, in two stages (rvrn, then everything else).
    var c: Ctx = .{
        .font = font,
        .gpa = gpa,
        .buf = &buf,
        .layout = &font.gsub,
        .max_len = buf.infos.items.len * 16 + 256,
        .ops = buf.infos.items.len * 64 + 16384,
    };
    for ([_]u8{ 1, 2 }) |stage| {
        for (plan.gsub, 0..) |st, li| if (st & stage != 0) try c.applyLookup(@intCast(li));
    }

    // Positioning: advances from hmtx, then GPOS (or the kern table).
    const n = buf.infos.items.len;
    try buf.pos.resize(gpa, n);
    for (buf.infos.items, buf.pos.items) |info, *p| p.* = .{
        .xa = font.advance(info.glyph),
    };
    c.layout = &font.gpos;
    c.ops = n * 64 + 16384;
    for (plan.gpos, 0..) |st, li| if (st != 0) try c.applyLookup(@intCast(li));
    if (plan.legacy_kern) applyKernTable(&c);

    // Marks take no room (from the GDEF class), then attachments resolve.
    for (buf.infos.items, buf.pos.items) |info, *p| if (info.class == 3) {
        p.xa = 0;
        p.ya = 0;
    };
    const pos = buf.pos.items;
    // Default-ignorable characters render as invisible space.
    for (buf.infos.items, pos) |*info, *p| if (info.flags & hidden != 0) {
        info.glyph = space;
        p.* = .{};
    };
    for (pos, 0..) |*p, i| if (p.attach != 0) {
        const j = i - p.attach;
        p.xo += pos[j].xo;
        p.yo += pos[j].yo;
        for (pos[j..i]) |q| p.xo -= q.xa;
    };
    try out.ensureUnusedCapacity(gpa, n);
    for (buf.infos.items, pos) |info, p| out.appendAssumeCapacity(.{
        .id = info.glyph,
        .cluster = info.cluster,
        .x_advance = p.xa,
        .y_advance = p.ya,
        .x_offset = p.xo,
        .y_offset = p.yo,
    });
}

// ---------------------------------------------------------------------------
// Buffer.

const hidden: u8 = 1; // default ignorable: drawn as zero-width space
const skippable: u8 = 2; // skipped when matching sequences

const Info = struct {
    glyph: u16,
    cluster: u32,
    /// GDEF glyph class (1 base, 2 ligature, 3 mark, 4 component).
    class: u8,
    /// GDEF mark attachment class.
    attach_class: u8,
    flags: u8,
    /// Ligature this glyph belongs to (0 when none), per substitution.
    lig_id: u8 = 0,
    /// 0 for the ligature itself; for a mark inside one, the 1-based
    /// component it followed.
    lig_comp: u8 = 0,
};

const Pos = struct {
    xa: i32 = 0,
    ya: i32 = 0,
    xo: i32 = 0,
    yo: i32 = 0,
    /// Distance back to the glyph this mark attaches to (0 when none).
    attach: usize = 0,
};

const Buffer = struct {
    infos: std.ArrayList(Info) = .empty,
    pos: std.ArrayList(Pos) = .empty,

    fn deinit(b: *Buffer, gpa: std.mem.Allocator) void {
        b.infos.deinit(gpa);
        b.pos.deinit(gpa);
    }
};

/// Which lookups run, by table. Each entry is a stage mask (0 = off).
const Plan = struct {
    gsub: []u8 = &.{},
    gpos: []u8 = &.{},
    legacy_kern: bool = false,

    fn deinit(p: *Plan, gpa: std.mem.Allocator) void {
        gpa.free(p.gsub);
        gpa.free(p.gpos);
    }

    fn init(p: *Plan, gpa: std.mem.Allocator, font: *const Font, features: []const Feature) !void {
        p.gsub = try gpa.alloc(u8, font.gsub.lookupCount());
        @memset(p.gsub, 0);
        p.gpos = try gpa.alloc(u8, font.gpos.lookupCount());
        @memset(p.gpos, 0);
        const V = struct {
            features: []const Feature,
            extra: []const [4]u8,
            stages: []u8,
            data: []const u8,
            fn visit(v: *const @This(), tag: [4]u8, off: usize) void {
                if (!enabled(v.features, v.extra, tag)) return;
                const stage: u8 = if (std.mem.eql(u8, &tag, "rvrn")) 1 else 2;
                const n: usize = r16(v.data, off + 2);
                for (0..n) |k| {
                    const li = r16(v.data, off + 4 + k * 2);
                    if (li < v.stages.len) v.stages[li] |= stage;
                }
            }
        };
        font.gsub.eachFeature(&V{
            .features = features,
            .extra = font.features,
            .stages = p.gsub,
            .data = font.gsub.data,
        }, V.visit);
        font.gpos.eachFeature(&V{
            .features = features,
            .extra = font.features,
            .stages = p.gpos,
            .data = font.gpos.data,
        }, V.visit);
        p.legacy_kern = font.tables.kern.len != 0 and enabled(features, font.features, "kern".*) and !font.gpos.hasFeature("kern".*);
    }

    /// The run's own choice wins, then the font's own (`Font.features`), then the defaults.
    fn enabled(features: []const Feature, extra: []const [4]u8, tag: [4]u8) bool {
        var i = features.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, &features[i].tag, &tag)) return features[i].on;
        }
        for (extra) |d| if (std.mem.eql(u8, &d, &tag)) return true;
        for (default_features) |d| if (std.mem.eql(u8, &d, &tag)) return true;
        return false;
    }
};

// ---------------------------------------------------------------------------
// Lookup application.

const max_depth = 8;
const max_match = 64;
const Oom = error{OutOfMemory};

const Ctx = struct {
    font: *const Font,
    gpa: std.mem.Allocator,
    buf: *Buffer,
    layout: *const Layout,
    /// The buffer never grows past this (guards multiple substitutions).
    max_len: usize,
    // The lookup being applied.
    flag: u16 = 0,
    mark_set: u16 = 0,
    depth: u8 = 0,
    /// Nested lookup applications left; bounds the work malformed context
    /// lookups can cause.
    ops: usize = 0,
    /// Last ligature id handed out.
    lig_counter: u8 = 0,

    fn data(c: *const Ctx) []const u8 {
        return c.layout.data;
    }

    fn infos(c: *const Ctx) []Info {
        return c.buf.infos.items;
    }

    /// True when the current lookup's flags skip `info`.
    fn ignored(c: *const Ctx, info: Info) bool {
        return c.skips(info, false);
    }

    /// Like `ignored`; `context` is true for backtrack and lookahead glyphs.
    /// Joiners are always skipped; ZWNJ only blocks substitution input
    /// sequences, never context or positioning.
    fn skips(c: *const Ctx, info: Info, comptime context: bool) bool {
        if (info.flags & skippable != 0 or ((context or c.layout.is_gpos) and info.flags & hidden != 0)) return true;
        switch (info.class) {
            1 => return c.flag & 0x2 != 0,
            2 => return c.flag & 0x4 != 0,
            3 => {
                if (c.flag & 0x8 != 0) return true;
                if (c.flag & 0x10 != 0) return !c.font.markSetHas(c.mark_set, info.glyph);
                const want = c.flag >> 8;
                if (want != 0) return info.attach_class != want;
                return false;
            },
            else => return false,
        }
    }

    fn nextIndex(c: *const Ctx, i: usize) ?usize {
        return c.nextSkipping(i, false);
    }

    fn prevIndex(c: *const Ctx, i: usize) ?usize {
        return c.prevSkipping(i, false);
    }

    fn nextSkipping(c: *const Ctx, i: usize, comptime context: bool) ?usize {
        const s = c.infos();
        var j = i + 1;
        while (j < s.len) : (j += 1) if (!c.skips(s[j], context)) return j;
        return null;
    }

    fn prevSkipping(c: *const Ctx, i: usize, comptime context: bool) ?usize {
        const s = c.infos();
        var j = i;
        while (j > 0) {
            j -= 1;
            if (!c.skips(s[j], context)) return j;
        }
        return null;
    }

    fn setFlags(c: *Ctx, lookup: usize) void {
        const d = c.data();
        c.flag = r16(d, lookup + 2);
        c.mark_set = if (c.flag & 0x10 != 0) r16(d, lookup + 6 + @as(usize, r16(d, lookup + 4)) * 2) else 0;
    }

    /// Applies lookup `li` across the whole buffer.
    fn applyLookup(c: *Ctx, li: u16) Oom!void {
        const lookup = c.layout.lookupOffset(li);
        const digest = if (li < c.layout.digests.len) c.layout.digests[li] else font_mod.Digest.all;
        c.setFlags(lookup);
        const subs: usize = r16(c.data(), lookup + 4);
        if (subs == 0) return;

        // Reverse chaining single substitution runs from the end.
        if (!c.layout.is_gpos and c.layout.subtable(lookup, 0).kind == 8) {
            var i = c.infos().len;
            while (i > 0) {
                i -= 1;
                const info = c.infos()[i];
                if (!digest.mayHave(info.glyph) or c.ignored(info)) continue;
                for (0..subs) |k| {
                    const st = c.layout.subtable(lookup, k);
                    if (st.kind == 8 and c.reverseChain(st.off, i)) break;
                }
            }
            return;
        }

        var i: usize = 0;
        while (i < c.infos().len) {
            const info = c.infos()[i];
            if (digest.mayHave(info.glyph) and !c.ignored(info)) {
                const len = c.infos().len;
                if (try c.applySubtables(lookup, subs, i)) |next| {
                    // Progress is guaranteed: forward, or the buffer shrank.
                    if (next > i or c.infos().len < len) {
                        i = next;
                        continue;
                    }
                }
            }
            i += 1;
        }
    }

    fn applySubtables(c: *Ctx, lookup: usize, subs: usize, i: usize) Oom!?usize {
        for (0..subs) |k| {
            const st = c.layout.subtable(lookup, k);
            const r = if (c.layout.is_gpos) try c.applyPos(st.kind, st.off, i) else try c.applySub(st.kind, st.off, i);
            if (r) |next| return next;
        }
        return null;
    }

    /// Applies lookup `li` once at `i` (a nested lookup of a context rule).
    fn applyNested(c: *Ctx, li: u16, i: usize) Oom!void {
        if (c.depth >= max_depth or c.ops == 0 or li >= c.layout.lookupCount() or i >= c.infos().len) return;
        c.ops -= 1;
        const saved_flag = c.flag;
        const saved_set = c.mark_set;
        defer {
            c.flag = saved_flag;
            c.mark_set = saved_set;
        }
        const lookup = c.layout.lookupOffset(li);
        c.setFlags(lookup);
        if (c.ignored(c.infos()[i])) return;
        c.depth += 1;
        defer c.depth -= 1;
        _ = try c.applySubtables(lookup, r16(c.data(), lookup + 4), i);
    }

    // ---- GSUB ---------------------------------------------------------

    fn setGlyph(c: *Ctx, i: usize, g: u16) void {
        const info = &c.infos()[i];
        info.glyph = g;
        info.class = c.font.glyphClass(g);
        info.attach_class = c.font.markAttachClass(g);
    }

    fn applySub(c: *Ctx, kind: u16, off: usize, i: usize) Oom!?usize {
        const d = c.data();
        const g = c.infos()[i].glyph;
        const format = r16(d, off);
        switch (kind) {
            1 => {
                const idx = coverageIndex(d, off + r16(d, off + 2), g) orelse return null;
                if (format == 1) {
                    c.setGlyph(i, g +% r16(d, off + 4));
                } else if (format == 2) {
                    if (idx >= r16(d, off + 4)) return null;
                    c.setGlyph(i, r16(d, off + 6 + @as(usize, idx) * 2));
                } else return null;
                return i + 1;
            },
            2 => {
                if (format != 1) return null;
                const idx = coverageIndex(d, off + r16(d, off + 2), g) orelse return null;
                if (idx >= r16(d, off + 4)) return null;
                const seq = off + r16(d, off + 6 + @as(usize, idx) * 2);
                const count: usize = r16(d, seq);
                if (count == 0) {
                    _ = c.buf.infos.orderedRemove(i);
                    return i;
                }
                c.setGlyph(i, r16(d, seq + 2));
                if (count > 1) {
                    if (c.infos().len + count - 1 > c.max_len) return i + 1;
                    const proto = c.infos()[i];
                    for (1..count) |k| {
                        try c.buf.infos.insert(c.gpa, i + k, proto);
                        c.setGlyph(i + k, r16(d, seq + 2 + k * 2));
                    }
                }
                return i + count;
            },
            3 => {
                if (format != 1) return null;
                const idx = coverageIndex(d, off + r16(d, off + 2), g) orelse return null;
                if (idx >= r16(d, off + 4)) return null;
                const set = off + r16(d, off + 6 + @as(usize, idx) * 2);
                if (r16(d, set) == 0) return null;
                c.setGlyph(i, r16(d, set + 2));
                return i + 1;
            },
            4 => {
                if (format != 1) return null;
                const idx = coverageIndex(d, off + r16(d, off + 2), g) orelse return null;
                if (idx >= r16(d, off + 4)) return null;
                const set = off + r16(d, off + 6 + @as(usize, idx) * 2);
                const nlig: usize = r16(d, set);
                var positions: [max_match]usize = undefined;
                for (0..nlig) |k| {
                    const lig = set + r16(d, set + 2 + k * 2);
                    const comps: usize = r16(d, lig + 2);
                    if (comps == 0 or comps > max_match) continue;
                    positions[0] = i;
                    var ok = true;
                    for (1..comps) |m| {
                        const j = c.nextIndex(positions[m - 1]) orelse {
                            ok = false;
                            break;
                        };
                        if (c.infos()[j].glyph != r16(d, lig + 4 + (m - 1) * 2)) {
                            ok = false;
                            break;
                        }
                        positions[m] = j;
                    }
                    if (!ok) continue;
                    const last = positions[comps - 1];
                    const s = c.infos();
                    const cluster = s[i].cluster;
                    const last_cluster = s[last].cluster;
                    // Marks skipped between components remember which one they followed.
                    c.lig_counter = if (c.lig_counter == 255) 1 else c.lig_counter + 1;
                    var comp: u8 = 1;
                    for (s[i + 1 .. last + 1], i + 1..) |*inf, at| {
                        inf.cluster = cluster;
                        if (comp < comps and at == positions[comp]) {
                            comp += 1;
                        } else {
                            inf.lig_id = c.lig_counter;
                            inf.lig_comp = comp;
                        }
                    }
                    // Glyphs after the last component that share its cluster join too.
                    var after = last + 1;
                    while (after < s.len and s[after].cluster == last_cluster) : (after += 1) s[after].cluster = cluster;
                    c.setGlyph(i, r16(d, lig));
                    s[i].lig_id = c.lig_counter;
                    s[i].lig_comp = 0;
                    var m = comps;
                    while (m > 1) {
                        m -= 1;
                        _ = c.buf.infos.orderedRemove(positions[m]);
                    }
                    return i + 1;
                }
                return null;
            },
            5, 6 => return c.applyContext(kind == 6, off, i),
            else => return null,
        }
    }

    /// GSUB type 8: one substitution, with backtrack and lookahead coverage.
    fn reverseChain(c: *Ctx, off: usize, i: usize) bool {
        const d = c.data();
        if (r16(d, off) != 1) return false;
        const idx = coverageIndex(d, off + r16(d, off + 2), c.infos()[i].glyph) orelse return false;
        const nb: usize = r16(d, off + 4);
        const la = off + 6 + nb * 2;
        const nl: usize = r16(d, la);
        const subst = la + 2 + nl * 2;
        var j = i;
        for (0..nb) |k| {
            j = c.prevSkipping(j, true) orelse return false;
            if (coverageIndex(d, off + r16(d, off + 6 + k * 2), c.infos()[j].glyph) == null) return false;
        }
        j = i;
        for (0..nl) |k| {
            j = c.nextSkipping(j, true) orelse return false;
            if (coverageIndex(d, off + r16(d, la + 2 + k * 2), c.infos()[j].glyph) == null) return false;
        }
        if (idx >= r16(d, subst)) return false;
        c.setGlyph(i, r16(d, subst + 2 + @as(usize, idx) * 2));
        return true;
    }

    // ---- Contexts (GSUB 5/6, GPOS 7/8) -------------------------------

    const Seq = struct {
        kind: enum { glyph, class, coverage },
        /// ClassDef offset (class) or subtable offset (coverage).
        base: usize = 0,
        /// Offset of the u16 array.
        arr: usize,
        count: usize,
    };

    fn seqMatches(c: *const Ctx, s: Seq, k: usize, g: u16) bool {
        const d = c.data();
        const v = r16(d, s.arr + k * 2);
        return switch (s.kind) {
            .glyph => g == v,
            .class => classOf(d, s.base, g) == v,
            .coverage => coverageIndex(d, s.base + v, g) != null,
        };
    }

    /// Matches the input after `i` (the first glyph already matched);
    /// returns the number of positions filled.
    fn matchInput(c: *const Ctx, i: usize, s: Seq, positions: *[max_match]usize) ?usize {
        if (s.count + 1 > max_match) return null;
        positions[0] = i;
        var j = i;
        for (0..s.count) |k| {
            j = c.nextIndex(j) orelse return null;
            if (!c.seqMatches(s, k, c.infos()[j].glyph)) return null;
            positions[k + 1] = j;
        }
        return s.count + 1;
    }

    fn matchBacktrack(c: *const Ctx, i: usize, s: Seq) bool {
        var j = i;
        for (0..s.count) |k| {
            j = c.prevSkipping(j, true) orelse return false;
            if (!c.seqMatches(s, k, c.infos()[j].glyph)) return false;
        }
        return true;
    }

    fn matchLookahead(c: *const Ctx, last: usize, s: Seq) bool {
        var j = last;
        for (0..s.count) |k| {
            j = c.nextSkipping(j, true) orelse return false;
            if (!c.seqMatches(s, k, c.infos()[j].glyph)) return false;
        }
        return true;
    }

    fn applyContext(c: *Ctx, chain: bool, off: usize, i: usize) Oom!?usize {
        const d = c.data();
        const g = c.infos()[i].glyph;
        const format = r16(d, off);
        var positions: [max_match]usize = undefined;
        switch (format) {
            1, 2 => {
                const idx = coverageIndex(d, off + r16(d, off + 2), g) orelse return null;
                // Format 2 class definitions: backtrack, input, lookahead.
                var cd = [3]usize{ 0, 0, 0 };
                var sets_at: usize = off + 4;
                var set_index: usize = idx;
                if (format == 2) {
                    if (chain) {
                        for (0..3) |k| {
                            const o = r16(d, off + 4 + k * 2);
                            cd[k] = if (o == 0) 0 else off + o;
                        }
                        sets_at = off + 10;
                    } else {
                        const o = r16(d, off + 4);
                        cd[1] = if (o == 0) 0 else off + o;
                        cd[0] = cd[1];
                        cd[2] = cd[1];
                        sets_at = off + 6;
                    }
                    set_index = classOf(d, cd[1], g);
                }
                if (set_index >= r16(d, sets_at)) return null;
                const set_off = r16(d, sets_at + 2 + set_index * 2);
                if (set_off == 0) return null;
                const set = off + set_off;
                const nrules: usize = r16(d, set);
                const kind: @FieldType(Seq, "kind") = if (format == 1) .glyph else .class;
                for (0..nrules) |r| {
                    var p = set + r16(d, set + 2 + r * 2);
                    var back: Seq = .{
                        .kind = kind,
                        .base = cd[0],
                        .arr = 0,
                        .count = 0,
                    };
                    if (chain) {
                        back.count = r16(d, p);
                        back.arr = p + 2;
                        p += 2 + back.count * 2;
                    }
                    const n_in: usize = r16(d, p);
                    if (n_in == 0) continue;
                    var nrec: usize = 0;
                    if (!chain) {
                        nrec = r16(d, p + 2);
                        p += 4;
                    } else p += 2;
                    const input: Seq = .{
                        .kind = kind,
                        .base = cd[1],
                        .arr = p,
                        .count = n_in - 1,
                    };
                    p += (n_in - 1) * 2;
                    var ahead: Seq = .{
                        .kind = kind,
                        .base = cd[2],
                        .arr = 0,
                        .count = 0,
                    };
                    if (chain) {
                        ahead.count = r16(d, p);
                        ahead.arr = p + 2;
                        p += 2 + ahead.count * 2;
                        nrec = r16(d, p);
                        p += 2;
                    }
                    const count = c.matchInput(i, input, &positions) orelse continue;
                    if (!c.matchBacktrack(i, back)) continue;
                    if (!c.matchLookahead(positions[count - 1], ahead)) continue;
                    return try c.applyRecords(&positions, count, p, nrec);
                }
                return null;
            },
            3 => {
                var p = off + 2;
                var back: Seq = .{
                    .kind = .coverage,
                    .base = off,
                    .arr = 0,
                    .count = 0,
                };
                if (chain) {
                    back.count = r16(d, p);
                    back.arr = p + 2;
                    p += 2 + back.count * 2;
                }
                const n_in: usize = r16(d, p);
                if (n_in == 0) return null;
                var nrec: usize = 0;
                if (!chain) {
                    nrec = r16(d, p + 2);
                    p += 4;
                } else p += 2;
                if (coverageIndex(d, off + r16(d, p), g) == null) return null;
                const input: Seq = .{
                    .kind = .coverage,
                    .base = off,
                    .arr = p + 2,
                    .count = n_in - 1,
                };
                p += n_in * 2;
                var ahead: Seq = .{
                    .kind = .coverage,
                    .base = off,
                    .arr = 0,
                    .count = 0,
                };
                if (chain) {
                    ahead.count = r16(d, p);
                    ahead.arr = p + 2;
                    p += 2 + ahead.count * 2;
                    nrec = r16(d, p);
                    p += 2;
                }
                const count = c.matchInput(i, input, &positions) orelse return null;
                if (!c.matchBacktrack(i, back)) return null;
                if (!c.matchLookahead(positions[count - 1], ahead)) return null;
                return try c.applyRecords(&positions, count, p, nrec);
            },
            else => return null,
        }
    }

    /// Runs the SequenceLookupRecords of a matched rule, keeping the matched
    /// positions in step with insertions and removals. Returns the index
    /// after the matched input.
    fn applyRecords(c: *Ctx, positions: *[max_match]usize, count_in: usize, recs: usize, nrec: usize) Oom!usize {
        const d = c.data();
        var count = count_in;
        var end = positions[count - 1] + 1;
        for (0..nrec) |r| {
            const idx: usize = r16(d, recs + r * 4);
            const li = r16(d, recs + r * 4 + 2);
            if (idx >= count) continue;
            const before = c.infos().len;
            try c.applyNested(li, positions[idx]);
            const after = c.infos().len;
            if (after == before) continue;
            if (after > before) {
                const delta = after - before;
                end += delta;
                // New glyphs follow position idx; later positions move right.
                const room = @min(delta, max_match - count);
                var k = count;
                while (k > idx + 1) {
                    k -= 1;
                    if (k + room < max_match) positions[k + room] = positions[k] + delta;
                }
                for (0..room) |t| positions[idx + 1 + t] = positions[idx] + 1 + t;
                count += room;
            } else {
                const delta = before - after;
                end -|= delta;
                // The glyphs after position idx were consumed (a ligature).
                const gone = @min(delta, count - idx - 1);
                var k = idx + 1;
                while (k + gone < count) : (k += 1) positions[k] = @max(positions[k + gone] -| delta, positions[idx] + 1);
                count -= gone;
            }
        }
        return @min(@max(end, positions[0] + 1), c.infos().len);
    }

    // ---- GPOS ---------------------------------------------------------

    fn valueSize(vf: u16) usize {
        return @as(usize, @popCount(vf & 0xFF)) * 2;
    }

    /// Applies the ValueRecord at `at` (format `vf`) to glyph `i`. `base` is
    /// the subtable its device offsets count from.
    fn applyValue(c: *Ctx, at: usize, vf: u16, i: usize, base: usize) void {
        const d = c.data();
        const p = &c.buf.pos.items[i];
        var o = at;
        if (vf & 0x1 != 0) {
            p.xo += ri16(d, o);
            o += 2;
        }
        if (vf & 0x2 != 0) {
            p.yo += ri16(d, o);
            o += 2;
        }
        if (vf & 0x4 != 0) {
            p.xa += ri16(d, o);
            o += 2;
        }
        if (vf & 0x8 != 0) {
            p.ya += ri16(d, o);
            o += 2;
        }
        // Device tables: VariationIndex tables vary the values above; the
        // hinting formats are for sizes in pixels and are ignored.
        if (vf & 0xF0 == 0 or !c.font.varied) return;
        inline for (.{ "xo", "yo", "xa", "ya" }, .{ 0x10, 0x20, 0x40, 0x80 }) |field, bit| {
            if (vf & bit != 0) {
                @field(p, field) += c.deviceDelta(base, r16(d, o));
                o += 2;
            }
        }
    }

    /// The variation delta of the Device/VariationIndex table at `base + off`
    /// (0 for hinting device tables), rounded to font units.
    fn deviceDelta(c: *const Ctx, base: usize, off: u16) i32 {
        if (off == 0 or !c.font.varied) return 0;
        const d = c.data();
        const t = base + off;
        if (r16(d, t + 4) != 0x8000) return 0;
        return c.font.variationDelta(r16(d, t), r16(d, t + 2));
    }

    /// An anchor's coordinates, with format 3 variation deltas.
    fn anchorAt(c: *const Ctx, a: usize) [2]i32 {
        const d = c.data();
        var x: i32 = ri16(d, a + 2);
        var y: i32 = ri16(d, a + 4);
        if (r16(d, a) == 3 and c.font.varied) {
            x += c.deviceDelta(a, r16(d, a + 6));
            y += c.deviceDelta(a, r16(d, a + 8));
        }
        return .{ x, y };
    }

    fn applyPos(c: *Ctx, kind: u16, off: usize, i: usize) Oom!?usize {
        const d = c.data();
        const g = c.infos()[i].glyph;
        const format = r16(d, off);
        switch (kind) {
            1 => {
                const idx = coverageIndex(d, off + r16(d, off + 2), g) orelse return null;
                const vf = r16(d, off + 4);
                if (format == 1) {
                    c.applyValue(off + 6, vf, i, off);
                } else if (format == 2) {
                    if (idx >= r16(d, off + 6)) return null;
                    c.applyValue(off + 8 + idx * valueSize(vf), vf, i, off);
                } else return null;
                return i + 1;
            },
            2 => {
                const idx = coverageIndex(d, off + r16(d, off + 2), g) orelse return null;
                const j = c.nextIndex(i) orelse return null;
                const g2 = c.infos()[j].glyph;
                const vf1 = r16(d, off + 4);
                const vf2 = r16(d, off + 6);
                const s1 = valueSize(vf1);
                const s2 = valueSize(vf2);
                if (format == 1) {
                    if (idx >= r16(d, off + 8)) return null;
                    const set = off + r16(d, off + 10 + @as(usize, idx) * 2);
                    const rec_size = 2 + s1 + s2;
                    var lo: usize = 0;
                    var hi: usize = r16(d, set);
                    while (lo < hi) {
                        const mid = (lo + hi) / 2;
                        const rec = set + 2 + mid * rec_size;
                        const second = r16(d, rec);
                        if (second < g2) lo = mid + 1 else if (second > g2) hi = mid else {
                            c.applyValue(rec + 2, vf1, i, set);
                            c.applyValue(rec + 2 + s1, vf2, j, set);
                            return if (vf2 != 0) j + 1 else j;
                        }
                    }
                    return null;
                } else if (format == 2) {
                    const c1 = classOf(d, off + r16(d, off + 8), g);
                    const c2 = classOf(d, off + r16(d, off + 10), g2);
                    const n1 = r16(d, off + 12);
                    const n2 = r16(d, off + 14);
                    if (c1 >= n1 or c2 >= n2) return null;
                    const rec = off + 16 + (@as(usize, c1) * n2 + c2) * (s1 + s2);
                    c.applyValue(rec, vf1, i, off);
                    c.applyValue(rec + s1, vf2, j, off);
                    return if (vf2 != 0) j + 1 else j;
                }
                return null;
            },
            4, 5, 6 => {
                if (format != 1) return null;
                const mark_idx = coverageIndex(d, off + r16(d, off + 2), g) orelse return null;
                const s = c.infos();
                var j: usize = undefined;
                if (kind == 6) {
                    // The previous mark (per the lookup flags), on the same
                    // ligature component when ligatures are involved.
                    j = c.prevIndex(i) orelse return null;
                    if (s[j].class != 3) return null;
                    const a = s[i];
                    const b = s[j];
                    const same = a.lig_id == b.lig_id and (a.lig_id == 0 or a.lig_comp == b.lig_comp);
                    const one_is_lig = (a.lig_id != 0 and a.lig_comp == 0) or (b.lig_id != 0 and b.lig_comp == 0);
                    if (!same and !one_is_lig) return null;
                } else {
                    // The base: the closest preceding glyph that is not a mark.
                    j = i;
                    while (true) {
                        if (j == 0) return null;
                        j -= 1;
                        if (s[j].class != 3 and s[j].flags & hidden == 0) break;
                    }
                }
                const base_idx = coverageIndex(d, off + r16(d, off + 4), s[j].glyph) orelse return null;
                const classes: usize = r16(d, off + 6);
                const marks = off + r16(d, off + 8);
                const bases = off + r16(d, off + 10);
                if (mark_idx >= r16(d, marks) or base_idx >= r16(d, bases)) return null;
                const mrec = marks + 2 + @as(usize, mark_idx) * 4;
                const class: usize = r16(d, mrec);
                if (class >= classes) return null;
                const mark_anchor = r16(d, mrec + 2);
                var ba: usize = undefined;
                if (kind == 5) {
                    // Pick the ligature component the mark followed (else the last).
                    const attach = bases + r16(d, bases + 2 + @as(usize, base_idx) * 2);
                    const comps: usize = r16(d, attach);
                    if (comps == 0) return null;
                    var comp = comps - 1;
                    if (s[i].lig_id != 0 and s[i].lig_id == s[j].lig_id and s[i].lig_comp > 0) comp = @min(comps, s[i].lig_comp) - 1;
                    const anchor = r16(d, attach + 2 + (comp * classes + class) * 2);
                    if (anchor == 0) return null;
                    ba = attach + anchor;
                } else {
                    const anchor = r16(d, bases + 2 + (@as(usize, base_idx) * classes + class) * 2);
                    if (anchor == 0) return null;
                    ba = bases + anchor;
                }
                if (mark_anchor == 0) return null;
                const ma = marks + mark_anchor;
                const p = &c.buf.pos.items[i];
                const bxy = c.anchorAt(ba);
                const mxy = c.anchorAt(ma);
                p.xo = bxy[0] - mxy[0];
                p.yo = bxy[1] - mxy[1];
                p.attach = i - j;
                return i + 1;
            },
            7, 8 => return c.applyContext(kind == 8, off, i),
            else => return null,
        }
    }
};

/// Legacy `kern` table pairs (used when GPOS has no kern feature).
fn applyKernTable(c: *Ctx) void {
    c.flag = 0x8; // skip marks
    const s = c.infos();
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i].class == 3) continue;
        const j = c.nextIndex(i) orelse break;
        c.buf.pos.items[i].xa += c.font.kernPair(s[i].glyph, s[j].glyph);
        i = j - 1;
    }
}

// ---------------------------------------------------------------------------
// Characters.

const Char = struct {
    cp: u21,
    glyph: u16,
    cluster: u32,
};

/// Unicode normalisation the way shapers do it for display: a character the
/// font lacks is decomposed when the font has its parts; marks are put in
/// canonical order; a base and a following mark compose when the font has
/// the composite. Clusters of merged characters take the smaller value.
fn normalize(gpa: std.mem.Allocator, font: *const Font, chars: *std.ArrayList(Char)) !void {
    var has_mark = false;
    var has_missing = false;
    for (chars.items) |ch| {
        if (ch.glyph == 0 and ch.cp >= 0xC0) has_missing = true;
        if (combiningClass(ch.cp) != 0) has_mark = true;
    }
    // Decompose.
    if (has_missing) {
        var i: usize = 0;
        while (i < chars.items.len) : (i += 1) {
            const ch = chars.items[i];
            if (ch.glyph != 0) continue;
            var parts: [4]Char = undefined;
            const n = decompose(font, ch.cp, ch.cluster, &parts, 0);
            if (n == 0) continue;
            try chars.replaceRange(gpa, i, 1, parts[0..n]);
            has_mark = true;
            i += n - 1;
        }
    }
    if (!has_mark) return;
    // Canonical ordering: stable sort of each run of marks by class.
    const s = chars.items;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (combiningClass(s[i].cp) == 0) continue;
        var j = i;
        while (j < s.len and combiningClass(s[j].cp) != 0) j += 1;
        if (j - i > 1 and j - i <= 32) {
            var k = i + 1;
            while (k < j) : (k += 1) {
                const x = s[k];
                const cx = combiningClass(x.cp);
                var m = k;
                while (m > i and combiningClass(s[m - 1].cp) > cx) : (m -= 1) s[m] = s[m - 1];
                s[m] = x;
            }
        }
        i = j;
    }
    // Compose.
    var out: usize = 0;
    var starter: ?usize = null;
    var last_class: u8 = 0;
    for (chars.items) |ch| {
        const cc = combiningClass(ch.cp);
        if (cc != 0) {
            if (starter) |st| if (out == st + 1 or last_class < cc) {
                const base = &chars.items[st];
                if (compose(base.cp, ch.cp)) |comp| {
                    const g = font.glyphIndex(comp);
                    if (g != 0) {
                        base.cp = comp;
                        base.glyph = g;
                        base.cluster = @min(base.cluster, ch.cluster);
                        continue;
                    }
                }
            };
            last_class = cc;
        } else {
            starter = out;
            last_class = 0;
        }
        chars.items[out] = ch;
        out += 1;
    }
    chars.shrinkRetainingCapacity(out);
}

/// Writes the decomposition of `cp` into `parts` when the font has every
/// part (recursing into the first part); returns the count, or 0.
fn decompose(font: *const Font, cp: u21, cluster: u32, parts: *[4]Char, depth: u8) usize {
    if (depth >= 3) return 0;
    const pair = decomposition(cp) orelse return 0;
    const g2 = font.glyphIndex(pair[1]);
    if (g2 == 0) return 0;
    const g1 = font.glyphIndex(pair[0]);
    var n: usize = 0;
    if (g1 != 0) {
        parts[0] = .{
            .cp = pair[0],
            .glyph = g1,
            .cluster = cluster,
        };
        n = 1;
    } else {
        n = decompose(font, pair[0], cluster, parts, depth + 1);
        if (n == 0 or n >= parts.len) return 0;
    }
    parts[n] = .{
        .cp = pair[1],
        .glyph = g2,
        .cluster = cluster,
    };
    return n + 1;
}

fn decomposition(cp: u21) ?[2]u21 {
    var lo: usize = 0;
    var hi: usize = decompositions.len / 3;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const v = decompositions[mid * 3];
        if (v < cp) lo = mid + 1 else if (v > cp) hi = mid else {
            return .{ @intCast(decompositions[mid * 3 + 1]), @intCast(decompositions[mid * 3 + 2]) };
        }
    }
    return null;
}

fn compose(a: u21, b: u21) ?u21 {
    var k: usize = 0;
    while (k < decompositions.len) : (k += 3) {
        if (decompositions[k + 1] == a and decompositions[k + 2] == b) return @intCast(decompositions[k]);
    }
    return null;
}

fn combiningClass(cp: u21) u8 {
    if (cp < 0x300 or cp > 0xFE2F) return 0;
    var lo: usize = 0;
    var hi: usize = combining_classes.len / 3;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (combining_classes[mid * 3 + 1] < cp) lo = mid + 1 else if (combining_classes[mid * 3] > cp) hi = mid else {
            return @intCast(combining_classes[mid * 3 + 2]);
        }
    }
    return 0;
}

/// Characters that continue the cluster before them: combining marks,
/// the zero width joiner, variation selectors, emoji modifiers and tags.
fn isContinuation(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F, 0x0483...0x0489, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20FF, 0xFE20...0xFE2F => true,
        0x200D, 0xFE00...0xFE0F, 0x1F3FB...0x1F3FF, 0xE0020...0xE007F, 0xE0100...0xE01EF => true,
        else => false,
    };
}

// Generated from the Unicode Character Database 13.0.0: canonical
// two-part decompositions of Latin, Greek and Cyrillic letters, as
// (composite, first, second) triples sorted by composite. Each pair
// also composes back (none is a composition exclusion).
const decompositions = [_]u32{
    0xC0,   0x41,   0x300, 0xC1,   0x41,   0x301, 0xC2,   0x41,   0x302, 0xC3,   0x41,   0x303,
    0xC4,   0x41,   0x308, 0xC5,   0x41,   0x30A, 0xC7,   0x43,   0x327, 0xC8,   0x45,   0x300,
    0xC9,   0x45,   0x301, 0xCA,   0x45,   0x302, 0xCB,   0x45,   0x308, 0xCC,   0x49,   0x300,
    0xCD,   0x49,   0x301, 0xCE,   0x49,   0x302, 0xCF,   0x49,   0x308, 0xD1,   0x4E,   0x303,
    0xD2,   0x4F,   0x300, 0xD3,   0x4F,   0x301, 0xD4,   0x4F,   0x302, 0xD5,   0x4F,   0x303,
    0xD6,   0x4F,   0x308, 0xD9,   0x55,   0x300, 0xDA,   0x55,   0x301, 0xDB,   0x55,   0x302,
    0xDC,   0x55,   0x308, 0xDD,   0x59,   0x301, 0xE0,   0x61,   0x300, 0xE1,   0x61,   0x301,
    0xE2,   0x61,   0x302, 0xE3,   0x61,   0x303, 0xE4,   0x61,   0x308, 0xE5,   0x61,   0x30A,
    0xE7,   0x63,   0x327, 0xE8,   0x65,   0x300, 0xE9,   0x65,   0x301, 0xEA,   0x65,   0x302,
    0xEB,   0x65,   0x308, 0xEC,   0x69,   0x300, 0xED,   0x69,   0x301, 0xEE,   0x69,   0x302,
    0xEF,   0x69,   0x308, 0xF1,   0x6E,   0x303, 0xF2,   0x6F,   0x300, 0xF3,   0x6F,   0x301,
    0xF4,   0x6F,   0x302, 0xF5,   0x6F,   0x303, 0xF6,   0x6F,   0x308, 0xF9,   0x75,   0x300,
    0xFA,   0x75,   0x301, 0xFB,   0x75,   0x302, 0xFC,   0x75,   0x308, 0xFD,   0x79,   0x301,
    0xFF,   0x79,   0x308, 0x100,  0x41,   0x304, 0x101,  0x61,   0x304, 0x102,  0x41,   0x306,
    0x103,  0x61,   0x306, 0x104,  0x41,   0x328, 0x105,  0x61,   0x328, 0x106,  0x43,   0x301,
    0x107,  0x63,   0x301, 0x108,  0x43,   0x302, 0x109,  0x63,   0x302, 0x10A,  0x43,   0x307,
    0x10B,  0x63,   0x307, 0x10C,  0x43,   0x30C, 0x10D,  0x63,   0x30C, 0x10E,  0x44,   0x30C,
    0x10F,  0x64,   0x30C, 0x112,  0x45,   0x304, 0x113,  0x65,   0x304, 0x114,  0x45,   0x306,
    0x115,  0x65,   0x306, 0x116,  0x45,   0x307, 0x117,  0x65,   0x307, 0x118,  0x45,   0x328,
    0x119,  0x65,   0x328, 0x11A,  0x45,   0x30C, 0x11B,  0x65,   0x30C, 0x11C,  0x47,   0x302,
    0x11D,  0x67,   0x302, 0x11E,  0x47,   0x306, 0x11F,  0x67,   0x306, 0x120,  0x47,   0x307,
    0x121,  0x67,   0x307, 0x122,  0x47,   0x327, 0x123,  0x67,   0x327, 0x124,  0x48,   0x302,
    0x125,  0x68,   0x302, 0x128,  0x49,   0x303, 0x129,  0x69,   0x303, 0x12A,  0x49,   0x304,
    0x12B,  0x69,   0x304, 0x12C,  0x49,   0x306, 0x12D,  0x69,   0x306, 0x12E,  0x49,   0x328,
    0x12F,  0x69,   0x328, 0x130,  0x49,   0x307, 0x134,  0x4A,   0x302, 0x135,  0x6A,   0x302,
    0x136,  0x4B,   0x327, 0x137,  0x6B,   0x327, 0x139,  0x4C,   0x301, 0x13A,  0x6C,   0x301,
    0x13B,  0x4C,   0x327, 0x13C,  0x6C,   0x327, 0x13D,  0x4C,   0x30C, 0x13E,  0x6C,   0x30C,
    0x143,  0x4E,   0x301, 0x144,  0x6E,   0x301, 0x145,  0x4E,   0x327, 0x146,  0x6E,   0x327,
    0x147,  0x4E,   0x30C, 0x148,  0x6E,   0x30C, 0x14C,  0x4F,   0x304, 0x14D,  0x6F,   0x304,
    0x14E,  0x4F,   0x306, 0x14F,  0x6F,   0x306, 0x150,  0x4F,   0x30B, 0x151,  0x6F,   0x30B,
    0x154,  0x52,   0x301, 0x155,  0x72,   0x301, 0x156,  0x52,   0x327, 0x157,  0x72,   0x327,
    0x158,  0x52,   0x30C, 0x159,  0x72,   0x30C, 0x15A,  0x53,   0x301, 0x15B,  0x73,   0x301,
    0x15C,  0x53,   0x302, 0x15D,  0x73,   0x302, 0x15E,  0x53,   0x327, 0x15F,  0x73,   0x327,
    0x160,  0x53,   0x30C, 0x161,  0x73,   0x30C, 0x162,  0x54,   0x327, 0x163,  0x74,   0x327,
    0x164,  0x54,   0x30C, 0x165,  0x74,   0x30C, 0x168,  0x55,   0x303, 0x169,  0x75,   0x303,
    0x16A,  0x55,   0x304, 0x16B,  0x75,   0x304, 0x16C,  0x55,   0x306, 0x16D,  0x75,   0x306,
    0x16E,  0x55,   0x30A, 0x16F,  0x75,   0x30A, 0x170,  0x55,   0x30B, 0x171,  0x75,   0x30B,
    0x172,  0x55,   0x328, 0x173,  0x75,   0x328, 0x174,  0x57,   0x302, 0x175,  0x77,   0x302,
    0x176,  0x59,   0x302, 0x177,  0x79,   0x302, 0x178,  0x59,   0x308, 0x179,  0x5A,   0x301,
    0x17A,  0x7A,   0x301, 0x17B,  0x5A,   0x307, 0x17C,  0x7A,   0x307, 0x17D,  0x5A,   0x30C,
    0x17E,  0x7A,   0x30C, 0x1A0,  0x4F,   0x31B, 0x1A1,  0x6F,   0x31B, 0x1AF,  0x55,   0x31B,
    0x1B0,  0x75,   0x31B, 0x1CD,  0x41,   0x30C, 0x1CE,  0x61,   0x30C, 0x1CF,  0x49,   0x30C,
    0x1D0,  0x69,   0x30C, 0x1D1,  0x4F,   0x30C, 0x1D2,  0x6F,   0x30C, 0x1D3,  0x55,   0x30C,
    0x1D4,  0x75,   0x30C, 0x1D5,  0xDC,   0x304, 0x1D6,  0xFC,   0x304, 0x1D7,  0xDC,   0x301,
    0x1D8,  0xFC,   0x301, 0x1D9,  0xDC,   0x30C, 0x1DA,  0xFC,   0x30C, 0x1DB,  0xDC,   0x300,
    0x1DC,  0xFC,   0x300, 0x1DE,  0xC4,   0x304, 0x1DF,  0xE4,   0x304, 0x1E0,  0x226,  0x304,
    0x1E1,  0x227,  0x304, 0x1E2,  0xC6,   0x304, 0x1E3,  0xE6,   0x304, 0x1E6,  0x47,   0x30C,
    0x1E7,  0x67,   0x30C, 0x1E8,  0x4B,   0x30C, 0x1E9,  0x6B,   0x30C, 0x1EA,  0x4F,   0x328,
    0x1EB,  0x6F,   0x328, 0x1EC,  0x1EA,  0x304, 0x1ED,  0x1EB,  0x304, 0x1EE,  0x1B7,  0x30C,
    0x1EF,  0x292,  0x30C, 0x1F0,  0x6A,   0x30C, 0x1F4,  0x47,   0x301, 0x1F5,  0x67,   0x301,
    0x1F8,  0x4E,   0x300, 0x1F9,  0x6E,   0x300, 0x1FA,  0xC5,   0x301, 0x1FB,  0xE5,   0x301,
    0x1FC,  0xC6,   0x301, 0x1FD,  0xE6,   0x301, 0x1FE,  0xD8,   0x301, 0x1FF,  0xF8,   0x301,
    0x200,  0x41,   0x30F, 0x201,  0x61,   0x30F, 0x202,  0x41,   0x311, 0x203,  0x61,   0x311,
    0x204,  0x45,   0x30F, 0x205,  0x65,   0x30F, 0x206,  0x45,   0x311, 0x207,  0x65,   0x311,
    0x208,  0x49,   0x30F, 0x209,  0x69,   0x30F, 0x20A,  0x49,   0x311, 0x20B,  0x69,   0x311,
    0x20C,  0x4F,   0x30F, 0x20D,  0x6F,   0x30F, 0x20E,  0x4F,   0x311, 0x20F,  0x6F,   0x311,
    0x210,  0x52,   0x30F, 0x211,  0x72,   0x30F, 0x212,  0x52,   0x311, 0x213,  0x72,   0x311,
    0x214,  0x55,   0x30F, 0x215,  0x75,   0x30F, 0x216,  0x55,   0x311, 0x217,  0x75,   0x311,
    0x218,  0x53,   0x326, 0x219,  0x73,   0x326, 0x21A,  0x54,   0x326, 0x21B,  0x74,   0x326,
    0x21E,  0x48,   0x30C, 0x21F,  0x68,   0x30C, 0x226,  0x41,   0x307, 0x227,  0x61,   0x307,
    0x228,  0x45,   0x327, 0x229,  0x65,   0x327, 0x22A,  0xD6,   0x304, 0x22B,  0xF6,   0x304,
    0x22C,  0xD5,   0x304, 0x22D,  0xF5,   0x304, 0x22E,  0x4F,   0x307, 0x22F,  0x6F,   0x307,
    0x230,  0x22E,  0x304, 0x231,  0x22F,  0x304, 0x232,  0x59,   0x304, 0x233,  0x79,   0x304,
    0x385,  0xA8,   0x301, 0x386,  0x391,  0x301, 0x388,  0x395,  0x301, 0x389,  0x397,  0x301,
    0x38A,  0x399,  0x301, 0x38C,  0x39F,  0x301, 0x38E,  0x3A5,  0x301, 0x38F,  0x3A9,  0x301,
    0x390,  0x3CA,  0x301, 0x3AA,  0x399,  0x308, 0x3AB,  0x3A5,  0x308, 0x3AC,  0x3B1,  0x301,
    0x3AD,  0x3B5,  0x301, 0x3AE,  0x3B7,  0x301, 0x3AF,  0x3B9,  0x301, 0x3B0,  0x3CB,  0x301,
    0x3CA,  0x3B9,  0x308, 0x3CB,  0x3C5,  0x308, 0x3CC,  0x3BF,  0x301, 0x3CD,  0x3C5,  0x301,
    0x3CE,  0x3C9,  0x301, 0x3D3,  0x3D2,  0x301, 0x3D4,  0x3D2,  0x308, 0x400,  0x415,  0x300,
    0x401,  0x415,  0x308, 0x403,  0x413,  0x301, 0x407,  0x406,  0x308, 0x40C,  0x41A,  0x301,
    0x40D,  0x418,  0x300, 0x40E,  0x423,  0x306, 0x419,  0x418,  0x306, 0x439,  0x438,  0x306,
    0x450,  0x435,  0x300, 0x451,  0x435,  0x308, 0x453,  0x433,  0x301, 0x457,  0x456,  0x308,
    0x45C,  0x43A,  0x301, 0x45D,  0x438,  0x300, 0x45E,  0x443,  0x306, 0x476,  0x474,  0x30F,
    0x477,  0x475,  0x30F, 0x4C1,  0x416,  0x306, 0x4C2,  0x436,  0x306, 0x4D0,  0x410,  0x306,
    0x4D1,  0x430,  0x306, 0x4D2,  0x410,  0x308, 0x4D3,  0x430,  0x308, 0x4D6,  0x415,  0x306,
    0x4D7,  0x435,  0x306, 0x4DA,  0x4D8,  0x308, 0x4DB,  0x4D9,  0x308, 0x4DC,  0x416,  0x308,
    0x4DD,  0x436,  0x308, 0x4DE,  0x417,  0x308, 0x4DF,  0x437,  0x308, 0x4E2,  0x418,  0x304,
    0x4E3,  0x438,  0x304, 0x4E4,  0x418,  0x308, 0x4E5,  0x438,  0x308, 0x4E6,  0x41E,  0x308,
    0x4E7,  0x43E,  0x308, 0x4EA,  0x4E8,  0x308, 0x4EB,  0x4E9,  0x308, 0x4EC,  0x42D,  0x308,
    0x4ED,  0x44D,  0x308, 0x4EE,  0x423,  0x304, 0x4EF,  0x443,  0x304, 0x4F0,  0x423,  0x308,
    0x4F1,  0x443,  0x308, 0x4F2,  0x423,  0x30B, 0x4F3,  0x443,  0x30B, 0x4F4,  0x427,  0x308,
    0x4F5,  0x447,  0x308, 0x4F8,  0x42B,  0x308, 0x4F9,  0x44B,  0x308, 0x1E00, 0x41,   0x325,
    0x1E01, 0x61,   0x325, 0x1E02, 0x42,   0x307, 0x1E03, 0x62,   0x307, 0x1E04, 0x42,   0x323,
    0x1E05, 0x62,   0x323, 0x1E06, 0x42,   0x331, 0x1E07, 0x62,   0x331, 0x1E08, 0xC7,   0x301,
    0x1E09, 0xE7,   0x301, 0x1E0A, 0x44,   0x307, 0x1E0B, 0x64,   0x307, 0x1E0C, 0x44,   0x323,
    0x1E0D, 0x64,   0x323, 0x1E0E, 0x44,   0x331, 0x1E0F, 0x64,   0x331, 0x1E10, 0x44,   0x327,
    0x1E11, 0x64,   0x327, 0x1E12, 0x44,   0x32D, 0x1E13, 0x64,   0x32D, 0x1E14, 0x112,  0x300,
    0x1E15, 0x113,  0x300, 0x1E16, 0x112,  0x301, 0x1E17, 0x113,  0x301, 0x1E18, 0x45,   0x32D,
    0x1E19, 0x65,   0x32D, 0x1E1A, 0x45,   0x330, 0x1E1B, 0x65,   0x330, 0x1E1C, 0x228,  0x306,
    0x1E1D, 0x229,  0x306, 0x1E1E, 0x46,   0x307, 0x1E1F, 0x66,   0x307, 0x1E20, 0x47,   0x304,
    0x1E21, 0x67,   0x304, 0x1E22, 0x48,   0x307, 0x1E23, 0x68,   0x307, 0x1E24, 0x48,   0x323,
    0x1E25, 0x68,   0x323, 0x1E26, 0x48,   0x308, 0x1E27, 0x68,   0x308, 0x1E28, 0x48,   0x327,
    0x1E29, 0x68,   0x327, 0x1E2A, 0x48,   0x32E, 0x1E2B, 0x68,   0x32E, 0x1E2C, 0x49,   0x330,
    0x1E2D, 0x69,   0x330, 0x1E2E, 0xCF,   0x301, 0x1E2F, 0xEF,   0x301, 0x1E30, 0x4B,   0x301,
    0x1E31, 0x6B,   0x301, 0x1E32, 0x4B,   0x323, 0x1E33, 0x6B,   0x323, 0x1E34, 0x4B,   0x331,
    0x1E35, 0x6B,   0x331, 0x1E36, 0x4C,   0x323, 0x1E37, 0x6C,   0x323, 0x1E38, 0x1E36, 0x304,
    0x1E39, 0x1E37, 0x304, 0x1E3A, 0x4C,   0x331, 0x1E3B, 0x6C,   0x331, 0x1E3C, 0x4C,   0x32D,
    0x1E3D, 0x6C,   0x32D, 0x1E3E, 0x4D,   0x301, 0x1E3F, 0x6D,   0x301, 0x1E40, 0x4D,   0x307,
    0x1E41, 0x6D,   0x307, 0x1E42, 0x4D,   0x323, 0x1E43, 0x6D,   0x323, 0x1E44, 0x4E,   0x307,
    0x1E45, 0x6E,   0x307, 0x1E46, 0x4E,   0x323, 0x1E47, 0x6E,   0x323, 0x1E48, 0x4E,   0x331,
    0x1E49, 0x6E,   0x331, 0x1E4A, 0x4E,   0x32D, 0x1E4B, 0x6E,   0x32D, 0x1E4C, 0xD5,   0x301,
    0x1E4D, 0xF5,   0x301, 0x1E4E, 0xD5,   0x308, 0x1E4F, 0xF5,   0x308, 0x1E50, 0x14C,  0x300,
    0x1E51, 0x14D,  0x300, 0x1E52, 0x14C,  0x301, 0x1E53, 0x14D,  0x301, 0x1E54, 0x50,   0x301,
    0x1E55, 0x70,   0x301, 0x1E56, 0x50,   0x307, 0x1E57, 0x70,   0x307, 0x1E58, 0x52,   0x307,
    0x1E59, 0x72,   0x307, 0x1E5A, 0x52,   0x323, 0x1E5B, 0x72,   0x323, 0x1E5C, 0x1E5A, 0x304,
    0x1E5D, 0x1E5B, 0x304, 0x1E5E, 0x52,   0x331, 0x1E5F, 0x72,   0x331, 0x1E60, 0x53,   0x307,
    0x1E61, 0x73,   0x307, 0x1E62, 0x53,   0x323, 0x1E63, 0x73,   0x323, 0x1E64, 0x15A,  0x307,
    0x1E65, 0x15B,  0x307, 0x1E66, 0x160,  0x307, 0x1E67, 0x161,  0x307, 0x1E68, 0x1E62, 0x307,
    0x1E69, 0x1E63, 0x307, 0x1E6A, 0x54,   0x307, 0x1E6B, 0x74,   0x307, 0x1E6C, 0x54,   0x323,
    0x1E6D, 0x74,   0x323, 0x1E6E, 0x54,   0x331, 0x1E6F, 0x74,   0x331, 0x1E70, 0x54,   0x32D,
    0x1E71, 0x74,   0x32D, 0x1E72, 0x55,   0x324, 0x1E73, 0x75,   0x324, 0x1E74, 0x55,   0x330,
    0x1E75, 0x75,   0x330, 0x1E76, 0x55,   0x32D, 0x1E77, 0x75,   0x32D, 0x1E78, 0x168,  0x301,
    0x1E79, 0x169,  0x301, 0x1E7A, 0x16A,  0x308, 0x1E7B, 0x16B,  0x308, 0x1E7C, 0x56,   0x303,
    0x1E7D, 0x76,   0x303, 0x1E7E, 0x56,   0x323, 0x1E7F, 0x76,   0x323, 0x1E80, 0x57,   0x300,
    0x1E81, 0x77,   0x300, 0x1E82, 0x57,   0x301, 0x1E83, 0x77,   0x301, 0x1E84, 0x57,   0x308,
    0x1E85, 0x77,   0x308, 0x1E86, 0x57,   0x307, 0x1E87, 0x77,   0x307, 0x1E88, 0x57,   0x323,
    0x1E89, 0x77,   0x323, 0x1E8A, 0x58,   0x307, 0x1E8B, 0x78,   0x307, 0x1E8C, 0x58,   0x308,
    0x1E8D, 0x78,   0x308, 0x1E8E, 0x59,   0x307, 0x1E8F, 0x79,   0x307, 0x1E90, 0x5A,   0x302,
    0x1E91, 0x7A,   0x302, 0x1E92, 0x5A,   0x323, 0x1E93, 0x7A,   0x323, 0x1E94, 0x5A,   0x331,
    0x1E95, 0x7A,   0x331, 0x1E96, 0x68,   0x331, 0x1E97, 0x74,   0x308, 0x1E98, 0x77,   0x30A,
    0x1E99, 0x79,   0x30A, 0x1E9B, 0x17F,  0x307, 0x1EA0, 0x41,   0x323, 0x1EA1, 0x61,   0x323,
    0x1EA2, 0x41,   0x309, 0x1EA3, 0x61,   0x309, 0x1EA4, 0xC2,   0x301, 0x1EA5, 0xE2,   0x301,
    0x1EA6, 0xC2,   0x300, 0x1EA7, 0xE2,   0x300, 0x1EA8, 0xC2,   0x309, 0x1EA9, 0xE2,   0x309,
    0x1EAA, 0xC2,   0x303, 0x1EAB, 0xE2,   0x303, 0x1EAC, 0x1EA0, 0x302, 0x1EAD, 0x1EA1, 0x302,
    0x1EAE, 0x102,  0x301, 0x1EAF, 0x103,  0x301, 0x1EB0, 0x102,  0x300, 0x1EB1, 0x103,  0x300,
    0x1EB2, 0x102,  0x309, 0x1EB3, 0x103,  0x309, 0x1EB4, 0x102,  0x303, 0x1EB5, 0x103,  0x303,
    0x1EB6, 0x1EA0, 0x306, 0x1EB7, 0x1EA1, 0x306, 0x1EB8, 0x45,   0x323, 0x1EB9, 0x65,   0x323,
    0x1EBA, 0x45,   0x309, 0x1EBB, 0x65,   0x309, 0x1EBC, 0x45,   0x303, 0x1EBD, 0x65,   0x303,
    0x1EBE, 0xCA,   0x301, 0x1EBF, 0xEA,   0x301, 0x1EC0, 0xCA,   0x300, 0x1EC1, 0xEA,   0x300,
    0x1EC2, 0xCA,   0x309, 0x1EC3, 0xEA,   0x309, 0x1EC4, 0xCA,   0x303, 0x1EC5, 0xEA,   0x303,
    0x1EC6, 0x1EB8, 0x302, 0x1EC7, 0x1EB9, 0x302, 0x1EC8, 0x49,   0x309, 0x1EC9, 0x69,   0x309,
    0x1ECA, 0x49,   0x323, 0x1ECB, 0x69,   0x323, 0x1ECC, 0x4F,   0x323, 0x1ECD, 0x6F,   0x323,
    0x1ECE, 0x4F,   0x309, 0x1ECF, 0x6F,   0x309, 0x1ED0, 0xD4,   0x301, 0x1ED1, 0xF4,   0x301,
    0x1ED2, 0xD4,   0x300, 0x1ED3, 0xF4,   0x300, 0x1ED4, 0xD4,   0x309, 0x1ED5, 0xF4,   0x309,
    0x1ED6, 0xD4,   0x303, 0x1ED7, 0xF4,   0x303, 0x1ED8, 0x1ECC, 0x302, 0x1ED9, 0x1ECD, 0x302,
    0x1EDA, 0x1A0,  0x301, 0x1EDB, 0x1A1,  0x301, 0x1EDC, 0x1A0,  0x300, 0x1EDD, 0x1A1,  0x300,
    0x1EDE, 0x1A0,  0x309, 0x1EDF, 0x1A1,  0x309, 0x1EE0, 0x1A0,  0x303, 0x1EE1, 0x1A1,  0x303,
    0x1EE2, 0x1A0,  0x323, 0x1EE3, 0x1A1,  0x323, 0x1EE4, 0x55,   0x323, 0x1EE5, 0x75,   0x323,
    0x1EE6, 0x55,   0x309, 0x1EE7, 0x75,   0x309, 0x1EE8, 0x1AF,  0x301, 0x1EE9, 0x1B0,  0x301,
    0x1EEA, 0x1AF,  0x300, 0x1EEB, 0x1B0,  0x300, 0x1EEC, 0x1AF,  0x309, 0x1EED, 0x1B0,  0x309,
    0x1EEE, 0x1AF,  0x303, 0x1EEF, 0x1B0,  0x303, 0x1EF0, 0x1AF,  0x323, 0x1EF1, 0x1B0,  0x323,
    0x1EF2, 0x59,   0x300, 0x1EF3, 0x79,   0x300, 0x1EF4, 0x59,   0x323, 0x1EF5, 0x79,   0x323,
    0x1EF6, 0x59,   0x309, 0x1EF7, 0x79,   0x309, 0x1EF8, 0x59,   0x303, 0x1EF9, 0x79,   0x303,
    0x1F00, 0x3B1,  0x313, 0x1F01, 0x3B1,  0x314, 0x1F02, 0x1F00, 0x300, 0x1F03, 0x1F01, 0x300,
    0x1F04, 0x1F00, 0x301, 0x1F05, 0x1F01, 0x301, 0x1F06, 0x1F00, 0x342, 0x1F07, 0x1F01, 0x342,
    0x1F08, 0x391,  0x313, 0x1F09, 0x391,  0x314, 0x1F0A, 0x1F08, 0x300, 0x1F0B, 0x1F09, 0x300,
    0x1F0C, 0x1F08, 0x301, 0x1F0D, 0x1F09, 0x301, 0x1F0E, 0x1F08, 0x342, 0x1F0F, 0x1F09, 0x342,
    0x1F10, 0x3B5,  0x313, 0x1F11, 0x3B5,  0x314, 0x1F12, 0x1F10, 0x300, 0x1F13, 0x1F11, 0x300,
    0x1F14, 0x1F10, 0x301, 0x1F15, 0x1F11, 0x301, 0x1F18, 0x395,  0x313, 0x1F19, 0x395,  0x314,
    0x1F1A, 0x1F18, 0x300, 0x1F1B, 0x1F19, 0x300, 0x1F1C, 0x1F18, 0x301, 0x1F1D, 0x1F19, 0x301,
    0x1F20, 0x3B7,  0x313, 0x1F21, 0x3B7,  0x314, 0x1F22, 0x1F20, 0x300, 0x1F23, 0x1F21, 0x300,
    0x1F24, 0x1F20, 0x301, 0x1F25, 0x1F21, 0x301, 0x1F26, 0x1F20, 0x342, 0x1F27, 0x1F21, 0x342,
    0x1F28, 0x397,  0x313, 0x1F29, 0x397,  0x314, 0x1F2A, 0x1F28, 0x300, 0x1F2B, 0x1F29, 0x300,
    0x1F2C, 0x1F28, 0x301, 0x1F2D, 0x1F29, 0x301, 0x1F2E, 0x1F28, 0x342, 0x1F2F, 0x1F29, 0x342,
    0x1F30, 0x3B9,  0x313, 0x1F31, 0x3B9,  0x314, 0x1F32, 0x1F30, 0x300, 0x1F33, 0x1F31, 0x300,
    0x1F34, 0x1F30, 0x301, 0x1F35, 0x1F31, 0x301, 0x1F36, 0x1F30, 0x342, 0x1F37, 0x1F31, 0x342,
    0x1F38, 0x399,  0x313, 0x1F39, 0x399,  0x314, 0x1F3A, 0x1F38, 0x300, 0x1F3B, 0x1F39, 0x300,
    0x1F3C, 0x1F38, 0x301, 0x1F3D, 0x1F39, 0x301, 0x1F3E, 0x1F38, 0x342, 0x1F3F, 0x1F39, 0x342,
    0x1F40, 0x3BF,  0x313, 0x1F41, 0x3BF,  0x314, 0x1F42, 0x1F40, 0x300, 0x1F43, 0x1F41, 0x300,
    0x1F44, 0x1F40, 0x301, 0x1F45, 0x1F41, 0x301, 0x1F48, 0x39F,  0x313, 0x1F49, 0x39F,  0x314,
    0x1F4A, 0x1F48, 0x300, 0x1F4B, 0x1F49, 0x300, 0x1F4C, 0x1F48, 0x301, 0x1F4D, 0x1F49, 0x301,
    0x1F50, 0x3C5,  0x313, 0x1F51, 0x3C5,  0x314, 0x1F52, 0x1F50, 0x300, 0x1F53, 0x1F51, 0x300,
    0x1F54, 0x1F50, 0x301, 0x1F55, 0x1F51, 0x301, 0x1F56, 0x1F50, 0x342, 0x1F57, 0x1F51, 0x342,
    0x1F59, 0x3A5,  0x314, 0x1F5B, 0x1F59, 0x300, 0x1F5D, 0x1F59, 0x301, 0x1F5F, 0x1F59, 0x342,
    0x1F60, 0x3C9,  0x313, 0x1F61, 0x3C9,  0x314, 0x1F62, 0x1F60, 0x300, 0x1F63, 0x1F61, 0x300,
    0x1F64, 0x1F60, 0x301, 0x1F65, 0x1F61, 0x301, 0x1F66, 0x1F60, 0x342, 0x1F67, 0x1F61, 0x342,
    0x1F68, 0x3A9,  0x313, 0x1F69, 0x3A9,  0x314, 0x1F6A, 0x1F68, 0x300, 0x1F6B, 0x1F69, 0x300,
    0x1F6C, 0x1F68, 0x301, 0x1F6D, 0x1F69, 0x301, 0x1F6E, 0x1F68, 0x342, 0x1F6F, 0x1F69, 0x342,
    0x1F70, 0x3B1,  0x300, 0x1F72, 0x3B5,  0x300, 0x1F74, 0x3B7,  0x300, 0x1F76, 0x3B9,  0x300,
    0x1F78, 0x3BF,  0x300, 0x1F7A, 0x3C5,  0x300, 0x1F7C, 0x3C9,  0x300, 0x1F80, 0x1F00, 0x345,
    0x1F81, 0x1F01, 0x345, 0x1F82, 0x1F02, 0x345, 0x1F83, 0x1F03, 0x345, 0x1F84, 0x1F04, 0x345,
    0x1F85, 0x1F05, 0x345, 0x1F86, 0x1F06, 0x345, 0x1F87, 0x1F07, 0x345, 0x1F88, 0x1F08, 0x345,
    0x1F89, 0x1F09, 0x345, 0x1F8A, 0x1F0A, 0x345, 0x1F8B, 0x1F0B, 0x345, 0x1F8C, 0x1F0C, 0x345,
    0x1F8D, 0x1F0D, 0x345, 0x1F8E, 0x1F0E, 0x345, 0x1F8F, 0x1F0F, 0x345, 0x1F90, 0x1F20, 0x345,
    0x1F91, 0x1F21, 0x345, 0x1F92, 0x1F22, 0x345, 0x1F93, 0x1F23, 0x345, 0x1F94, 0x1F24, 0x345,
    0x1F95, 0x1F25, 0x345, 0x1F96, 0x1F26, 0x345, 0x1F97, 0x1F27, 0x345, 0x1F98, 0x1F28, 0x345,
    0x1F99, 0x1F29, 0x345, 0x1F9A, 0x1F2A, 0x345, 0x1F9B, 0x1F2B, 0x345, 0x1F9C, 0x1F2C, 0x345,
    0x1F9D, 0x1F2D, 0x345, 0x1F9E, 0x1F2E, 0x345, 0x1F9F, 0x1F2F, 0x345, 0x1FA0, 0x1F60, 0x345,
    0x1FA1, 0x1F61, 0x345, 0x1FA2, 0x1F62, 0x345, 0x1FA3, 0x1F63, 0x345, 0x1FA4, 0x1F64, 0x345,
    0x1FA5, 0x1F65, 0x345, 0x1FA6, 0x1F66, 0x345, 0x1FA7, 0x1F67, 0x345, 0x1FA8, 0x1F68, 0x345,
    0x1FA9, 0x1F69, 0x345, 0x1FAA, 0x1F6A, 0x345, 0x1FAB, 0x1F6B, 0x345, 0x1FAC, 0x1F6C, 0x345,
    0x1FAD, 0x1F6D, 0x345, 0x1FAE, 0x1F6E, 0x345, 0x1FAF, 0x1F6F, 0x345, 0x1FB0, 0x3B1,  0x306,
    0x1FB1, 0x3B1,  0x304, 0x1FB2, 0x1F70, 0x345, 0x1FB3, 0x3B1,  0x345, 0x1FB4, 0x3AC,  0x345,
    0x1FB6, 0x3B1,  0x342, 0x1FB7, 0x1FB6, 0x345, 0x1FB8, 0x391,  0x306, 0x1FB9, 0x391,  0x304,
    0x1FBA, 0x391,  0x300, 0x1FBC, 0x391,  0x345, 0x1FC1, 0xA8,   0x342, 0x1FC2, 0x1F74, 0x345,
    0x1FC3, 0x3B7,  0x345, 0x1FC4, 0x3AE,  0x345, 0x1FC6, 0x3B7,  0x342, 0x1FC7, 0x1FC6, 0x345,
    0x1FC8, 0x395,  0x300, 0x1FCA, 0x397,  0x300, 0x1FCC, 0x397,  0x345, 0x1FCD, 0x1FBF, 0x300,
    0x1FCE, 0x1FBF, 0x301, 0x1FCF, 0x1FBF, 0x342, 0x1FD0, 0x3B9,  0x306, 0x1FD1, 0x3B9,  0x304,
    0x1FD2, 0x3CA,  0x300, 0x1FD6, 0x3B9,  0x342, 0x1FD7, 0x3CA,  0x342, 0x1FD8, 0x399,  0x306,
    0x1FD9, 0x399,  0x304, 0x1FDA, 0x399,  0x300, 0x1FDD, 0x1FFE, 0x300, 0x1FDE, 0x1FFE, 0x301,
    0x1FDF, 0x1FFE, 0x342, 0x1FE0, 0x3C5,  0x306, 0x1FE1, 0x3C5,  0x304, 0x1FE2, 0x3CB,  0x300,
    0x1FE4, 0x3C1,  0x313, 0x1FE5, 0x3C1,  0x314, 0x1FE6, 0x3C5,  0x342, 0x1FE7, 0x3CB,  0x342,
    0x1FE8, 0x3A5,  0x306, 0x1FE9, 0x3A5,  0x304, 0x1FEA, 0x3A5,  0x300, 0x1FEC, 0x3A1,  0x314,
    0x1FED, 0xA8,   0x300, 0x1FF2, 0x1F7C, 0x345, 0x1FF3, 0x3C9,  0x345, 0x1FF4, 0x3CE,  0x345,
    0x1FF6, 0x3C9,  0x342, 0x1FF7, 0x1FF6, 0x345, 0x1FF8, 0x39F,  0x300, 0x1FFA, 0x3A9,  0x300,
    0x1FFC, 0x3A9,  0x345,
};

// Canonical combining classes of the combining marks above, as
// (first, last, class) runs; every other code point is class 0.
const combining_classes = [_]u32{
    0x300,  0x314,  230, 0x315,  0x315,  232, 0x316,  0x319,  220, 0x31A,  0x31A,  232,
    0x31B,  0x31B,  216, 0x31C,  0x320,  220, 0x321,  0x322,  202, 0x323,  0x326,  220,
    0x327,  0x328,  202, 0x329,  0x333,  220, 0x334,  0x338,  1,   0x339,  0x33C,  220,
    0x33D,  0x344,  230, 0x345,  0x345,  240, 0x346,  0x346,  230, 0x347,  0x349,  220,
    0x34A,  0x34C,  230, 0x34D,  0x34E,  220, 0x350,  0x352,  230, 0x353,  0x356,  220,
    0x357,  0x357,  230, 0x358,  0x358,  232, 0x359,  0x35A,  220, 0x35B,  0x35B,  230,
    0x35C,  0x35C,  233, 0x35D,  0x35E,  234, 0x35F,  0x35F,  233, 0x360,  0x361,  234,
    0x362,  0x362,  233, 0x363,  0x36F,  230, 0x483,  0x487,  230, 0x1AB0, 0x1AB4, 230,
    0x1AB5, 0x1ABA, 220, 0x1ABB, 0x1ABC, 230, 0x1ABD, 0x1ABD, 220, 0x1ABF, 0x1AC0, 220,
    0x1DC0, 0x1DC1, 230, 0x1DC2, 0x1DC2, 220, 0x1DC3, 0x1DC9, 230, 0x1DCA, 0x1DCA, 220,
    0x1DCB, 0x1DCC, 230, 0x1DCD, 0x1DCD, 234, 0x1DCE, 0x1DCE, 214, 0x1DCF, 0x1DCF, 220,
    0x1DD0, 0x1DD0, 202, 0x1DD1, 0x1DF5, 230, 0x1DF6, 0x1DF6, 232, 0x1DF7, 0x1DF8, 228,
    0x1DF9, 0x1DF9, 220, 0x1DFB, 0x1DFB, 230, 0x1DFC, 0x1DFC, 233, 0x1DFD, 0x1DFD, 220,
    0x1DFE, 0x1DFE, 230, 0x1DFF, 0x1DFF, 220, 0x20D0, 0x20D1, 230, 0x20D2, 0x20D3, 1,
    0x20D4, 0x20D7, 230, 0x20D8, 0x20DA, 1,   0x20DB, 0x20DC, 230, 0x20E1, 0x20E1, 230,
    0x20E5, 0x20E6, 1,   0x20E7, 0x20E7, 230, 0x20E8, 0x20E8, 220, 0x20E9, 0x20E9, 230,
    0x20EA, 0x20EB, 1,   0x20EC, 0x20EF, 220, 0x20F0, 0x20F0, 230, 0xFE20, 0xFE26, 230,
    0xFE27, 0xFE2D, 220, 0xFE2E, 0xFE2F, 230,
};

/// A glyph for characters the font lacks: spaces fall back to the space
/// glyph, non-breaking hyphens to the hyphen.
fn fallbackGlyph(font: *const Font, cp: u21, space: u16) u16 {
    return switch (cp) {
        0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => space,
        0x2011 => blk: {
            const h = font.glyphIndex(0x2010);
            break :blk if (h != 0) h else font.glyphIndex('-');
        },
        else => 0,
    };
}

fn isDefaultIgnorable(cp: u21) bool {
    return switch (cp) {
        0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F => true,
        0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0x3164, 0xFE00...0xFE0F, 0xFEFF, 0xFFA0 => true,
        0xFFF0...0xFFF8, 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0000...0xE0FFF => true,
        else => false,
    };
}

/// A lenient UTF-8 decoder: each invalid byte becomes U+FFFD.
const Utf8 = struct {
    s: []const u8,
    i: usize = 0,

    fn next(u: *Utf8) ?u21 {
        const s = u.s;
        if (u.i >= s.len) return null;
        const b0 = s[u.i];
        if (b0 < 0x80) {
            u.i += 1;
            return b0;
        }
        const n: usize = if (b0 & 0xE0 == 0xC0) 2 else if (b0 & 0xF0 == 0xE0) 3 else if (b0 & 0xF8 == 0xF0) 4 else 0;
        if (n == 0 or u.i + n > s.len) {
            u.i += 1;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(s[u.i .. u.i + n]) catch {
            u.i += 1;
            return 0xFFFD;
        };
        u.i += n;
        return cp;
    }
};

// ---------------------------------------------------------------------------
// Tests.

const testing = std.testing;

const TestFont = struct {
    bytes: []u8,
    arena: std.heap.ArenaAllocator,
    font: Font,

    fn load(file: []const u8) !*TestFont {
        const t = try testing.allocator.create(TestFont);
        errdefer testing.allocator.destroy(t);
        t.bytes = try font_mod.testFont(testing.allocator, file);
        t.arena = .init(testing.allocator);
        t.font = try Font.parse(t.arena.allocator(), t.bytes);
        return t;
    }

    fn deinit(t: *TestFont) void {
        t.arena.deinit();
        testing.allocator.free(t.bytes);
        testing.allocator.destroy(t);
    }

    fn run(t: *const TestFont, text: []const u8, features: []const Feature, out: *std.ArrayList(Glyph)) !void {
        out.clearRetainingCapacity();
        try shape(testing.allocator, &t.font, text, 0, features, out);
    }
};

fn sumAdvances(gs: []const Glyph) i32 {
    var s: i32 = 0;
    for (gs) |g| s += g.x_advance;
    return s;
}

test "AV and To kern tighter than their advances" {
    const t = try TestFont.load("WorkSans-Regular.ttf");
    defer t.deinit();
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    const f = &t.font;
    for ([_][]const u8{ "AV", "To" }) |pair| {
        try t.run(pair, &.{}, &out);
        try testing.expectEqual(@as(usize, 2), out.items.len);
        const plain: i32 = @as(i32, f.advance(out.items[0].id)) + f.advance(out.items[1].id);
        try testing.expect(sumAdvances(out.items) < plain);
        try t.run(pair, &.{.{
            .tag = "kern".*,
            .on = false,
        }}, &out);
        try testing.expectEqual(plain, sumAdvances(out.items));
    }
    // Reference values for Work Sans Regular 2.012: A=600 (kerned from 660), V=614, T=494 (from 604).
    try t.run("AV To", &.{}, &out);
    const want = [_]i32{ 600, 614, 314, 494, 600 };
    for (out.items, want) |g, w| try testing.expectEqual(w, g.x_advance);
}

test "a font's own features shape like the run's, and the run can still turn them off" {
    const t = try TestFont.load("Inter-Regular.ttf");
    defer t.deinit();
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    try t.run("a6", &.{}, &out);
    const plain = [_]u16{ out.items[0].id, out.items[1].id };
    // Inter's cv11 is the single-storey a, its ss01 the open 6 and 9.
    t.font.features = &.{ "cv11".*, "ss01".* };
    try t.run("a6", &.{}, &out);
    try testing.expect(out.items[0].id != plain[0]);
    try testing.expect(out.items[1].id != plain[1]);
    try t.run("a6", &.{.{
        .tag = "cv11".*,
        .on = false,
    }}, &out);
    try testing.expectEqual(plain[0], out.items[0].id);
}

test "ligatures follow liga" {
    const t = try TestFont.load("WorkSans-Regular.ttf");
    defer t.deinit();
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    try t.run("office", &.{}, &out);
    // o, f_f_i, c, e: clusters 0, 1, 4, 5.
    try testing.expectEqual(@as(usize, 4), out.items.len);
    const clusters = [_]u32{ 0, 1, 4, 5 };
    for (out.items, clusters) |g, cl| try testing.expectEqual(cl, g.cluster);
    try testing.expectEqual(@as(i32, 1052), out.items[1].x_advance);
    try t.run("office", &.{.{
        .tag = "liga".*,
        .on = false,
    }}, &out);
    try testing.expectEqual(@as(usize, 6), out.items.len);
    try t.run("fi ffl", &.{}, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
}

test "small capitals come from smcp and c2sc" {
    const t = try TestFont.load("WorkSans-Regular.ttf");
    defer t.deinit();
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    // smcp replaces lowercase (so ffi no longer forms a ligature), not capitals.
    try t.run("office A", &.{.{
        .tag = "smcp".*,
    }}, &out);
    try testing.expectEqual(@as(usize, 8), out.items.len);
    for ("office", out.items[0..6]) |ch, g| try testing.expect(g.id != t.font.glyphIndex(ch));
    try testing.expectEqual(t.font.glyphIndex('A'), out.items[7].id);
    // c2sc turns capitals into the same small capitals smcp gives lowercase.
    var lower: std.ArrayList(Glyph) = .empty;
    defer lower.deinit(testing.allocator);
    try shape(testing.allocator, &t.font, "a", 0, &.{.{
        .tag = "smcp".*,
    }}, &lower);
    try t.run("A", &.{.{
        .tag = "c2sc".*,
    }}, &out);
    try testing.expectEqual(lower.items[0].id, out.items[0].id);
    try testing.expect(out.items[0].id != t.font.glyphIndex('A'));
}

test "clusters count UTF-16 units and stay monotonic" {
    const t = try TestFont.load("WorkSans-Italic.ttf");
    defer t.deinit();
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    out.clearRetainingCapacity();
    try shape(testing.allocator, &t.font, "Wörld 😀 office\u{200D}x fi\xffé", 10, &.{}, &out);
    try testing.expectEqual(@as(u32, 10), out.items[0].cluster);
    var prev: u32 = 0;
    for (out.items) |g| {
        try testing.expect(g.cluster >= prev);
        prev = g.cluster;
    }
    // "Wörld " is 6 units, the emoji is two, so the space after it is 18.
    for (out.items) |g| if (g.cluster == 16) try testing.expectEqual(@as(u16, 0), g.id);
    var saw18 = false;
    for (out.items) |g| saw18 = saw18 or g.cluster == 18;
    try testing.expect(saw18);
    // The zero width joiner takes no room.
    for (out.items) |g| if (g.cluster == 25) try testing.expectEqual(@as(i32, 0), g.x_advance);
}

test "marks attach to their base" {
    const t = try TestFont.load("WorkSans-Regular.ttf");
    defer t.deinit();
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    // x + combining acute (no precomposed glyph): the mark has no advance,
    // sits over the x and shares its cluster.
    try t.run("x\u{301}", &.{}, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(i32, 0), out.items[1].x_advance);
    try testing.expect(out.items[1].x_offset < 0);
    try testing.expect(out.items[1].x_offset > -out.items[0].x_advance);
    try testing.expectEqual(@as(u32, 0), out.items[1].cluster);
    // e + combining acute composes to é; a missing precomposed letter
    // (U+0229, e with cedilla) decomposes to e + combining cedilla.
    try t.run("e\u{301}", &.{}, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(t.font.glyphIndex(0xE9), out.items[0].id);
    try t.run("\u{229}", &.{}, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(t.font.glyphIndex('e'), out.items[0].id);
}

test "features report and shape in every face" {
    for ([_][]const u8{ "WorkSans-Medium.ttf", "WorkSans-SemiBold.ttf", "WorkSans-Bold.ttf", "WorkSans-BoldItalic.ttf" }) |file| {
        const t = try TestFont.load(file);
        defer t.deinit();
        try testing.expect(t.font.hasFeature("smcp".*));
        var out: std.ArrayList(Glyph) = .empty;
        defer out.deinit(testing.allocator);
        try t.run("Typography: 1/2 office AVATAR", &.{.{
            .tag = "tnum".*,
        }}, &out);
        try testing.expect(out.items.len > 20);
    }
}

test "shaping 1,000 characters is fast" {
    const t = try TestFont.load("WorkSans-Regular.ttf");
    defer t.deinit();
    const para = "The quick brown fox jumps over the lazy dog. Office affairs, finally: “AVATAR” — Tō, Wörld! ";
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    while (text.items.len < 1000) try text.appendSlice(testing.allocator, para);
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    const io = testing.io;
    const runs = 50;
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..runs) |_| try t.run(text.items, &.{}, &out);
    const ns = start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    const per: i96 = @divTrunc(ns, runs);
    if (@import("builtin").mode != .debug) {
        std.debug.print("shape: {d} bytes in {d} us\n", .{ text.items.len, @divTrunc(per, 1000) });
        try testing.expect(per < 1_000_000);
    }
}

test "legacy kern table applies when GPOS has no kern feature" {
    const t = try TestFont.load("WorkSans-Regular.ttf");
    defer t.deinit();
    const a = t.font.glyphIndex('A');
    const v = t.font.glyphIndex('V');
    // Version 0, one format 0 subtable (horizontal) with the pair A V = -77.
    var kern = [_]u8{
        0, 0, 0, 1, // version, nTables
        0, 0, 0, 20, 0, 1, // subtable version, length, coverage (format 0, horizontal)
        0, 1, 0, 6, 0, 0, 0, 0, // nPairs, searchRange, entrySelector, rangeShift
        0, 0, 0, 0, 0xFF, 0xB3, // left, right, value
    };
    std.mem.writeInt(u16, kern[18..20], a, .big);
    std.mem.writeInt(u16, kern[20..22], v, .big);
    var f = t.font;
    f.tables.kern = &kern;
    f.gpos = .{};
    try testing.expectEqual(@as(i16, -77), f.kernPair(a, v));
    try testing.expectEqual(@as(i16, 0), f.kernPair(v, a));
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    try shape(testing.allocator, &f, "AV", 0, &.{}, &out);
    try testing.expectEqual(@as(i32, f.advance(a)) - 77, out.items[0].x_advance);
    out.clearRetainingCapacity();
    try shape(testing.allocator, &f, "AV", 0, &.{.{
        .tag = "kern".*,
        .on = false,
    }}, &out);
    try testing.expectEqual(@as(i32, f.advance(a)), out.items[0].x_advance);
}

test "corrupt layout and glyph tables never panic" {
    const gpa = testing.allocator;
    const bytes = try font_mod.testFont(gpa, "WorkSans-Bold.ttf");
    defer gpa.free(bytes);
    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    // Byte ranges of the tables to corrupt.
    var ranges: [8][2]usize = undefined;
    var nr: usize = 0;
    const num_tables = r16(bytes, 4);
    for (0..num_tables) |k| {
        const rec = 12 + k * 16;
        const tag = bytes[rec..][0..4];
        for ([_]*const [4]u8{ "GSUB", "GPOS", "GDEF", "cmap", "glyf", "loca", "hmtx" }) |want| {
            if (std.mem.eql(u8, tag, want) and nr < ranges.len) {
                ranges[nr] = .{ r32(bytes, rec + 8), r32(bytes, rec + 12) };
                nr += 1;
            }
        }
    }
    try testing.expect(nr >= 5);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(gpa);
    for (0..150) |_| {
        @memcpy(copy, bytes);
        const r = ranges[rand.uintLessThan(usize, nr)];
        for (0..rand.uintLessThan(usize, 64) + 1) |_| {
            copy[r[0] + rand.uintLessThan(usize, r[1])] = rand.int(u8);
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const f = Font.parse(arena.allocator(), copy) catch continue;
        out.clearRetainingCapacity();
        try shape(gpa, &f, "Office ffi AV To, Wörld! x\u{301}\u{323} ȩ ṏ f\u{301}i 1/2", 0, &.{.{
            .tag = "tnum".*,
        }}, &out);
        var prev: u32 = 0;
        for (out.items) |g| {
            try testing.expect(g.cluster >= prev);
            prev = g.cluster;
            var path: @import("../raster/geom.zig").Path = .{};
            defer path.deinit(gpa);
            f.outline(gpa, g.id, .identity, &path) catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// Variable fonts against HarfBuzz.

/// Strings for the HarfBuzz comparison: mixed case, punctuation, digits,
/// kerning pairs, ligatures, accents and the currency signs whose glyphs
/// change through FeatureVariations (rvrn). All in the BMP, so clusters in
/// UTF-16 units equal HarfBuzz's code point clusters.
const hb_strings = [_][]const u8{
    "AV",                                          "To",             "Wa",                         "ff",
    "fi",                                          "ffi",            "ffl",                        "office",
    "AVATAR",                                      "Typography",     "LT YA PA Fa Ta Va Wo Yo",    "The quick brown fox jumps over the lazy dog.",
    "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG", "0123456789",     "1/2 3/4 10:30 12.5%",
    "$100 ¢50 €20 £5 ¥9 ₡7 ₲3 ₵2",
    "Hello, World!",
    "\"Quoted\" 'single' «guill»",
    "(parens) [brackets] {braces}",
    "a-b–c—d",
    "e.g. i.e. etc.",
    "Wörld Ærø Ångström",
    "Façade naïve café",
    "Zażółć gęślą jaźń",
    "Příliš žluťoučký kůň",
    "Œuvre œil",
    "x\u{301} n\u{303} a\u{308}\u{301}",
    "ȩ ṏ ǻ",
    "Kerning: AT AY Av Aw Ay",                     "LT LV LW LY L'", "P. F. T, V; W: Y!",          "r. r, y. y, v. f.",
    "#hashtag @mention &amp",                      "~^*+=<>|\\/",    "www.example.com/path?q=1",   "fjord fit flow",
    "SMALL caps Mixed",                            "Illegal 1lI0O",  "Quickly jumping zebras vex", "Sphinx of black quartz",
    "AWAY away",                                   "Tw Ty Tu Tr",    "VA WA YA",                   "Fo Fa Po Pa",
    "jj gj yj",                                    "Mr. Smith's",    "it's 5 o'clock",
    "∞ ≈ ≠ ≤ ≥ ± ×",
    "→ ← ↑ ↓",
    "§ ¶ † ‡ • …",
    "™ © ®",
    "ﬁ ﬂ",
    "Ğ ğ İ ı Ş ş",
    "Đ đ Ħ ħ Ŋ ŋ",
    "THORN Þ þ ð",
    "minus − hyphen ‐",
};

const HbGlyph = struct {
    g: u16,
    cl: u32,
    dx: i32,
    dy: i32,
    ax: i32,
    ay: i32,
};

/// Path of a corpus file, relative when run from the engine folder.
fn corpusPath(buf: []u8, rel: []const u8) ?[]const u8 {
    const io = testing.io;
    for ([_][]const u8{ "", "/Users/dawid/Documents/publrv2/publr-design/engine/" }) |root| {
        const p = std.fmt.bufPrint(buf, "{s}corpus/{s}", .{ root, rel }) catch return null;
        std.Io.Dir.cwd().access(io, p, .{}) catch continue;
        return p;
    }
    return null;
}

const CompareOptions = struct {
    /// A second axis value beside `wght`.
    other: ?font_mod.AxisValue = null,
};

/// Shapes `hb_strings` with `font_path` at each `wght`, plus
/// `CompareOptions.other` when given (remaining axes at their default), and compares
/// glyph ids, clusters, advances and offsets with `hb-shape`. Returns the
/// number of strings compared; skips the test when hb-shape is not installed.
fn compareWithHarfBuzz(font_path: []const u8, weights: []const f32, options: CompareOptions) !usize {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (hb_strings) |s| {
        try text.appendSlice(gpa, s);
        try text.append(gpa, '\n');
    }
    try tmp.dir.writeFile(io, .{
        .sub_path = "strings.txt",
        .data = text.items,
    });
    const text_path = try tmp.dir.realPathFileAlloc(io, "strings.txt", gpa);
    defer gpa.free(text_path);
    const text_arg = try std.fmt.allocPrint(gpa, "--text-file={s}", .{text_path});
    defer gpa.free(text_arg);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, font_path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const base = try Font.parse(arena.allocator(), bytes);

    var compared: usize = 0;
    var mismatches: usize = 0;
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(gpa);
    for (weights) |w| {
        var f = base;
        var values: [2]font_mod.AxisValue = .{ .{
            .tag = "wght".*,
            .value = w,
        }, options.other orelse .{
            .tag = "wght".*,
            .value = w,
        } };
        f.setVariation(&values);
        var vbuf: [64]u8 = undefined;
        const var_arg = if (options.other) |o|
            try std.fmt.bufPrint(&vbuf, "--variations=wght={d},{s}={d}", .{ w, o.tag, o.value })
        else
            try std.fmt.bufPrint(&vbuf, "--variations=wght={d}", .{w});
        const r = std.process.run(gpa, io, .{
            .argv = &.{ "hb-shape", var_arg, "--font-funcs=ot", "--output-format=json", "--no-glyph-names", text_arg, font_path },
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) return error.SkipZigTest;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\n"), '\n');
        for (hb_strings) |s| {
            const line = lines.next() orelse return error.TestUnexpectedResult;
            const want = try std.json.parseFromSlice([]HbGlyph, gpa, line, .{});
            defer want.deinit();
            out.clearRetainingCapacity();
            try shape(gpa, &f, s, 0, &.{}, &out);
            compared += 1;
            var same = out.items.len == want.value.len;
            if (same) for (out.items, want.value) |a, b| {
                if (a.id != b.g or a.cluster != b.cl or a.x_advance != b.ax or a.y_advance != b.ay or a.x_offset != b.dx or a.y_offset != b.dy) same = false;
            };
            if (!same) {
                mismatches += 1;
                std.debug.print("wght {d} \"{s}\":\n  hb:   {s}\n  ours:", .{ w, s, line });
                for (out.items) |g| std.debug.print(" {d}={d}+{d}<{d},{d}>", .{ g.id, g.cluster, g.x_advance, g.x_offset, g.y_offset });
                std.debug.print("\n", .{});
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), mismatches);
    return compared;
}

test "variable Work Sans shapes like hb-shape at every weight" {
    const weights = [_]f32{ 100, 300, 400, 500, 600, 700, 900 };
    var compared: usize = 0;
    for ([_][]const u8{ "fonts-variable/WorkSans[wght].ttf", "fonts-variable/WorkSans-Italic[wght].ttf" }) |rel| {
        var buf: [256]u8 = undefined;
        const path = corpusPath(&buf, rel) orelse return error.SkipZigTest;
        compared += try compareWithHarfBuzz(path, &weights, .{});
    }
    try testing.expectEqual(2 * weights.len * hb_strings.len, compared);
}

test "variable Inter (opsz, wght) shapes like hb-shape" {
    const weights = [_]f32{ 100, 300, 400, 500, 600, 700, 900 };
    var compared: usize = 0;
    for ([_][]const u8{ "fonts-variable/Inter[opsz,wght].ttf", "fonts-variable/Inter-Italic[opsz,wght].ttf" }) |rel| {
        var buf: [256]u8 = undefined;
        const path = corpusPath(&buf, rel) orelse return error.SkipZigTest;
        compared += try compareWithHarfBuzz(path, &weights, .{});
    }
    try testing.expectEqual(2 * weights.len * hb_strings.len, compared);
}
test "varied glyph extents and advances match hb-shape --show-extents" {
    const gpa = testing.allocator;
    const io = testing.io;
    const Case = struct {
        file: []const u8,
        wght: f32,
    };
    const cases = [_]Case{
        .{
            .file = "fonts-variable/WorkSans[wght].ttf",
            .wght = 500,
        },
        .{
            .file = "fonts-variable/WorkSans[wght].ttf",
            .wght = 650,
        },
        .{
            .file = "fonts-variable/WorkSans[wght].ttf",
            .wght = 100,
        },
        .{
            .file = "fonts-variable/WorkSans[wght].ttf",
            .wght = 900,
        },
        .{
            .file = "fonts-variable/WorkSans-Italic[wght].ttf",
            .wght = 333,
        },
        .{
            .file = "fonts-variable/Inter[opsz,wght].ttf",
            .wght = 650,
        },
    };
    const text = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@&?!%$ÅÉøçñßæœ{}[]()";
    for (cases) |cs| {
        var pbuf: [256]u8 = undefined;
        const path = corpusPath(&pbuf, cs.file) orelse return error.SkipZigTest;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
        defer gpa.free(bytes);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var f = try Font.parse(arena.allocator(), bytes);
        f.setVariation(&.{.{
            .tag = "wght".*,
            .value = cs.wght,
        }});
        var vb: [64]u8 = undefined;
        const va = try std.fmt.bufPrint(&vb, "--variations=wght={d}", .{cs.wght});
        const r = std.process.run(gpa, io, .{
            .argv = &.{ "hb-shape", va, "--font-funcs=ot", "--output-format=json", "--no-glyph-names", "--show-extents", "--features=-liga,-kern,-calt", path, text },
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        const E = struct {
            g: u16,
            ax: i32,
            xb: i32,
            yb: i32,
            w: i32,
            h: i32,
        };
        const want = try std.json.parseFromSlice([]E, gpa, std.mem.trimEnd(u8, r.stdout, "\n"), .{
            .ignore_unknown_fields = true,
        });
        defer want.deinit();
        var maxd: f32 = 0;
        var maxa: i32 = 0;
        for (want.value) |e| {
            maxa = @max(maxa, @as(i32, @intCast(@abs(@as(i32, f.advance(e.g)) - e.ax))));
            const b = f.pointBounds(e.g) orelse continue;
            const ref = [4]f32{ @floatFromInt(e.xb), @floatFromInt(e.yb + e.h), @floatFromInt(e.xb + e.w), @floatFromInt(e.yb) };
            for (ref, b) |x, y| maxd = @max(maxd, @abs(x - y));
        }
        // HarfBuzz rounds its extents to whole units.
        try testing.expect(want.value.len > 60);
        try testing.expect(maxd <= 0.5 + 1e-3);
        try testing.expectEqual(@as(i32, 0), maxa);
    }
}
