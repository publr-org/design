//! Gather (exact): what a source design file declares and what its designs use, written
//! as evidence a model can read.
//!
//! - Declared: styles; variables (collections, modes, types, values per mode, aliases,
//!   scopes, code syntax) with how many visible nodes bind each, by field; the modes
//!   nodes set; components with their properties and variants.
//! - Used, over every visible node of every page (instances resolved), counted with how
//!   many top-level frames and pages each value appears on and where: solid colours and
//!   gradient stops (fills, strokes, text), type combinations, auto-layout gaps and
//!   paddings, corner radii, shadows and blurs, stroke weights, frame widths that look
//!   like screens, icon-like components and vectors.
//! - Pre-clustered: near-identical colours (ΔE00 ≤ 2, same alpha), type combinations by
//!   family, weight and size.
//! - Bound: every used value notes the variables it comes from; `usage.json` keeps, per
//!   kind (colours, type, spacing, radii, strokes, effects), how many uses bind which
//!   variables (with the variables they alias, in any mode), for coverage by binding.
//!
//! Two files: `<out>` (compact, for the model) and `<out minus .json>.usage.json` (every
//! value with its count, for `verify`).
//!
//!   gather <source.fig | doc.pubd-dir> <evidence.json> [--skip-pages a,b]

const std = @import("std");
const engine = @import("publr_engine");
const Source = @import("source.zig").Source;
const color = @import("color.zig");

const m = engine.model;
const Io = std.Io;
const Dir = std.Io.Dir;
const A = std.mem.Allocator;
const Stringify = std.json.Stringify;

const none = std.math.maxInt(u32);

/// Where a value was seen: how often, on how many top-level frames and pages, and the
/// first places.
const Count = struct {
    uses: u32 = 0,
    frames: u32 = 0,
    pages: u32 = 0,
    last_frame: u32 = none,
    last_page: u32 = none,
    ex: [2]?Example = .{ null, null },
};

const Example = struct {
    page: u32,
    id: []const u8,
    path: []const u8,
};

/// A few names with counts (the styles or variables a value comes from).
const Tally = struct {
    names: [5][]const u8 = undefined,
    counts: [5]u32 = undefined,
    len: u8 = 0,

    fn add(t: *Tally, name: []const u8) void {
        for (t.names[0..t.len], 0..) |n, i| if (std.mem.eql(u8, n, name)) {
            t.counts[i] += 1;
            return;
        };
        if (t.len == t.names.len) return;
        t.names[t.len] = name;
        t.counts[t.len] = 1;
        t.len += 1;
    }
};

const ColorKind = enum {
    fill,
    stroke,
    text,
    stop,
};

const ColorUse = struct {
    count: Count = .{},
    by: [4]u32 = .{ 0, 0, 0, 0 },
    styles: Tally = .{},
    vars: Tally = .{},
};

const TypeUse = struct {
    family: []const u8,
    font_style: []const u8,
    weight: u16,
    italic: bool,
    size: f64,
    /// px; negative: auto.
    line: f64,
    /// px.
    tracking: f64,
    case: m.TextCase,
    decoration: m.Decoration,
    count: Count = .{},
    chars: u32 = 0,
    styles: Tally = .{},
    vars: Tally = .{},
};

const NumUse = struct {
    count: Count = .{},
    vars: Tally = .{},
};

const ShadowUse = struct {
    kind: m.EffectKind,
    color: u32,
    x: f64,
    y: f64,
    radius: f64,
    spread: f64,
    count: Count = .{},
    styles: Tally = .{},
    vars: Tally = .{},
};

/// A variable's bindings on visible nodes: how many, on how many nodes, by field.
const VarStat = struct {
    bindings: u32 = 0,
    nodes: u32 = 0,
    last: ?*const m.Node = null,
    fields: std.StringArrayHashMapUnmanaged(u32) = .empty,
};

/// Uses of one kind that bind these variables: the variables' names with every
/// variable they alias (in any mode), so a plan naming either covers them.
const Bound = struct {
    cat: []const u8,
    names: []const []const u8,
    uses: u32 = 0,
};

/// The kinds coverage by binding is counted for.
const cats = [_][]const u8{ "colors", "type", "spacing", "radii", "strokes", "effects" };

const ScreenUse = struct {
    count: Count = .{},
    names: Tally = .{},
};

const IconUse = struct {
    name: []const u8,
    w: f64,
    h: f64,
    kind: m.Kind,
    main: ?[]const u8,
    count: Count = .{},
};

const CompInfo = struct {
    id: []const u8,
    name: []const u8,
    kind: m.Kind,
    page: u32,
    w: f64,
    h: f64,
    set: ?[]const u8 = null,
    variants: u32 = 0,
    props: []const m.PropDef = &.{},
    texts: []const u8 = "",
};

const LibUse = struct {
    count: Count = .{},
    w: f64 = 0,
    h: f64 = 0,
};

const DocText = struct {
    count: u32 = 0,
    frame: []const u8 = "",
    page: u32 = 0,
};

const PageInfo = struct {
    name: []const u8,
    skipped: bool,
    nodes: u32 = 0,
    frames: std.ArrayList(struct {
        name: []const u8,
        id: []const u8,
        w: f64,
        h: f64,
    }) = .empty,
    frame_count: u32 = 0,
};

pub const Gather = struct {
    a: A,
    src: *Source,
    colors: std.AutoArrayHashMapUnmanaged(u32, ColorUse) = .empty,
    types: std.StringArrayHashMapUnmanaged(TypeUse) = .empty,
    gaps: std.AutoArrayHashMapUnmanaged(i32, NumUse) = .empty,
    paddings: std.AutoArrayHashMapUnmanaged(i32, NumUse) = .empty,
    radii: std.AutoArrayHashMapUnmanaged(i32, NumUse) = .empty,
    pills: Count = .{},
    strokes: std.AutoArrayHashMapUnmanaged(i32, NumUse) = .empty,
    shadows: std.StringArrayHashMapUnmanaged(ShadowUse) = .empty,
    blurs: std.StringArrayHashMapUnmanaged(ShadowUse) = .empty,
    screens: std.AutoArrayHashMapUnmanaged(i32, ScreenUse) = .empty,
    icons: std.StringArrayHashMapUnmanaged(IconUse) = .empty,
    comps: std.StringArrayHashMapUnmanaged(CompInfo) = .empty,
    comp_uses: std.StringArrayHashMapUnmanaged(Count) = .empty,
    /// The first instance of each component id: its name, size and property values (for
    /// components whose main is in another file).
    comp_names: std.StringArrayHashMapUnmanaged(struct {
        name: []const u8,
        w: f64,
        h: f64,
        props: []const m.PropValue,
    }) = .empty,
    lib_uses: std.StringArrayHashMapUnmanaged(LibUse) = .empty,
    style_uses: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// For styles whose value the file leaves out: the value of the first node that
    /// follows each (a node stores its styles' resolved values).
    samples: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    var_stats: std.AutoArrayHashMapUnmanaged(*const m.Variable, VarStat) = .empty,
    /// Bindings to library variables the file does not hold, by field.
    unresolved: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// Nodes with at least one binding.
    bound_nodes: u64 = 0,
    bindings: u64 = 0,
    /// Modes nodes set (`collection id\x00mode id`), counted like values.
    mode_sets: std.StringArrayHashMapUnmanaged(Count) = .empty,
    /// Per kind: uses, and uses by the variables they bind.
    cat_uses: [cats.len]u64 = .{0} ** cats.len,
    bound: std.StringArrayHashMapUnmanaged(Bound) = .empty,
    key_buf: std.ArrayList(u8) = .empty,
    field_buf: std.ArrayList(u8) = .empty,
    names: std.AutoHashMapUnmanaged(*const m.Variable, []const u8) = .empty,
    chains: std.AutoHashMapUnmanaged(*const m.Variable, []const []const u8) = .empty,
    doc_texts: std.StringArrayHashMapUnmanaged(DocText) = .empty,
    pages: std.ArrayList(PageInfo) = .empty,
    total_nodes: u64 = 0,
    total_texts: u64 = 0,
    /// Instances scaled as a whole, left out.
    scaled: u32 = 0,

    // Where the walk is.
    page: u32 = 0,
    frame: u32 = 0,
    frame_name: []const u8 = "",
    doc_page: bool = false,
    stack: std.ArrayList(*const m.Node) = .empty,

    fn bump(g: *Gather, c: *Count, n: *const m.Node) !void {
        c.uses += 1;
        if (c.last_frame != g.frame) {
            c.last_frame = g.frame;
            c.frames += 1;
        }
        if (c.last_page != g.page) {
            c.last_page = g.page;
            c.pages += 1;
        }
        for (&c.ex) |*e| {
            if (e.* == null) {
                e.* = .{
                    .page = g.page,
                    .id = try g.a.dupe(u8, n.id),
                    .path = try g.path(n),
                };
                break;
            }
            if (e.*.?.page == g.page and std.mem.eql(u8, e.*.?.path, try g.path(n))) break;
        }
    }

    /// Page › top frame › … › parent › node, names cut to 40 characters.
    fn path(g: *Gather, n: *const m.Node) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(g.a, cut(g.pages.items[g.page].name));
        const s = g.stack.items;
        for (s, 0..) |x, i| {
            if (s.len > 5 and i >= 2 and i < s.len - 2) {
                if (i == 2) try out.appendSlice(g.a, " › …");
                continue;
            }
            try out.appendSlice(g.a, " › ");
            try out.appendSlice(g.a, cut(x.name));
        }
        if (s.len == 0 or s[s.len - 1] != n) {
            try out.appendSlice(g.a, " › ");
            try out.appendSlice(g.a, cut(n.name));
        }
        return out.items;
    }

    fn colorUse(g: *Gather, c: m.Color, paint_opacity: f32, kind: ColorKind, n: *const m.Node, style: ?[]const u8, variable: ?[]const u8) !void {
        const alpha = c.a * paint_opacity;
        if (alpha <= 0.001) return;
        const key = rgba(c, alpha);
        const gop = try g.colors.getOrPut(g.a, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const u = gop.value_ptr;
        try g.bump(&u.count, n);
        u.by[@intFromEnum(kind)] += 1;
        if (style) |s| if (g.src.style(s)) |st| u.styles.add(st.name);
        if (variable) |v| if (g.src.variable(v)) |vr| u.vars.add(try g.fullName(vr));
        try g.useCat(0, if (variable) |v| &.{v} else &.{});
    }

    fn paints(g: *Gather, ps: []const m.Paint, kind: ColorKind, n: *const m.Node, style: ?[]const u8) !void {
        for (ps, 0..) |p, i| {
            if (!p.visible or p.opacity <= 0.001) continue;
            switch (p.kind) {
                .solid => try g.colorUse(p.color, p.opacity, kind, n, if (i == 0) style else null, p.variable),
                .linear, .radial, .angular, .diamond => for (p.stops) |st| try g.colorUse(st.color, p.opacity, .stop, n, null, st.variable),
                else => {},
            }
        }
    }

    fn num(g: *Gather, map: *std.AutoArrayHashMapUnmanaged(i32, NumUse), v: f32, n: *const m.Node, var_key: ?[]const u8, cat: usize) !void {
        if (!(v > 0.01) or v > 100000) return;
        const key: i32 = @intFromFloat(@round(v * 2));
        const gop = try map.getOrPut(g.a, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try g.bump(&gop.value_ptr.count, n);
        const ref = if (var_key) |k| boundRef(n.vars, k) else null;
        if (ref) |r| if (g.src.variable(r)) |vr| gop.value_ptr.vars.add(try g.fullName(vr));
        try g.useCat(cat, if (ref) |r| &.{r} else &.{});
    }

    /// One use of kind `cat`, bound to these variables (none: a plain value).
    fn useCat(g: *Gather, cat: usize, refs: []const []const u8) !void {
        g.cat_uses[cat] += 1;
        if (refs.len == 0) return;
        g.key_buf.clearRetainingCapacity();
        try g.key_buf.appendSlice(g.a, cats[cat]);
        for (refs) |r| {
            try g.key_buf.append(g.a, 0);
            try g.key_buf.appendSlice(g.a, r);
        }
        const gop = try g.bound.getOrPut(g.a, g.key_buf.items);
        if (!gop.found_existing) {
            gop.key_ptr.* = try g.a.dupe(u8, g.key_buf.items);
            var names: std.ArrayList([]const u8) = .empty;
            for (refs) |r| {
                const v = g.src.variable(r) orelse {
                    try addName(g.a, &names, "(a library variable the file does not hold)");
                    continue;
                };
                for (try g.chain(v)) |x| try addName(g.a, &names, x);
            }
            gop.value_ptr.* = .{
                .cat = cats[cat],
                .names = names.items,
            };
        }
        gop.value_ptr.uses += 1;
    }

    /// `Collection/name`, the name a plan uses for a source variable.
    fn fullName(g: *Gather, v: *const m.Variable) ![]const u8 {
        if (g.names.get(v)) |x| return x;
        const c = g.src.collection(v.collection);
        const x = try std.fmt.allocPrint(g.a, "{s}/{s}", .{ if (c) |cc| cc.name else "?", v.name });
        try g.names.put(g.a, v, x);
        return x;
    }

    /// The variable's name and the names of every variable it aliases, in any mode,
    /// to any depth.
    fn chain(g: *Gather, v: *const m.Variable) ![]const []const u8 {
        if (g.chains.get(v)) |c| return c;
        var out: std.ArrayList([]const u8) = .empty;
        try g.chainInto(v, &out, 0);
        try g.chains.put(g.a, v, out.items);
        return out.items;
    }

    fn chainInto(g: *Gather, v: *const m.Variable, out: *std.ArrayList([]const u8), depth: u32) !void {
        const name = try g.fullName(v);
        for (out.items) |x| if (std.mem.eql(u8, x, name)) return;
        try out.append(g.a, name);
        if (depth > 16) return;
        for (v.values) |val| {
            var it = aliasIter(val.value);
            while (it.next()) |id| if (g.src.variable(id)) |t| try g.chainInto(t, out, depth + 1);
        }
    }

    /// Every binding the node holds, counted per variable and field.
    fn bindingsOf(g: *Gather, n: *const m.Node) !void {
        const before = g.bindings;
        for (n.vars) |b| try g.bindField(b.variable, nodeField(b.key), n);
        try g.paintBindings(n.fills, if (n.kind == .text) "text-fill" else "fill", n);
        try g.paintBindings(n.strokes, "stroke", n);
        for (n.effects) |e| for (e.vars) |b| try g.bindField(b.variable, try g.field("effect/", b.key), n);
        for (n.grids) |gr| for (gr.vars) |b| try g.bindField(b.variable, try g.field("grid/", b.key), n);
        if (n.text) |t| {
            for (t.style.vars) |b| try g.bindField(b.variable, try g.field("text/", b.key), n);
            for (t.runs) |r| {
                for (r.style.vars) |b| try g.bindField(b.variable, try g.field("text/", b.key), n);
                if (r.fills) |fs| try g.paintBindings(fs, "text-fill", n);
            }
        }
        if (g.bindings > before) g.bound_nodes += 1;
    }

    fn paintBindings(g: *Gather, ps: []const m.Paint, field_name: []const u8, n: *const m.Node) !void {
        for (ps) |p| {
            if (p.variable) |v| try g.bindField(v, field_name, n);
            for (p.vars) |b| try g.bindField(b.variable, try g.field(field_name, try std.fmt.allocPrint(g.a, "/{s}", .{b.key})), n);
            for (p.stops) |st| if (st.variable) |v| try g.bindField(v, "stop", n);
        }
    }

    /// `prefix` and `key` joined, valid until the next call.
    fn field(g: *Gather, prefix: []const u8, key: []const u8) ![]const u8 {
        g.field_buf.clearRetainingCapacity();
        try g.field_buf.appendSlice(g.a, prefix);
        try g.field_buf.appendSlice(g.a, key);
        return g.field_buf.items;
    }

    fn bindField(g: *Gather, ref: []const u8, field_name: []const u8, n: *const m.Node) !void {
        g.bindings += 1;
        const v = g.src.variable(ref) orelse {
            const gop = try g.unresolved.getOrPut(g.a, field_name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try g.a.dupe(u8, field_name);
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
            return;
        };
        const gop = try g.var_stats.getOrPut(g.a, v);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const st = gop.value_ptr;
        st.bindings += 1;
        if (st.last != n) {
            st.last = n;
            st.nodes += 1;
        }
        const fg = try st.fields.getOrPut(g.a, field_name);
        if (!fg.found_existing) {
            fg.key_ptr.* = try g.a.dupe(u8, field_name);
            fg.value_ptr.* = 0;
        }
        fg.value_ptr.* += 1;
    }

    fn effects(g: *Gather, n: *const m.Node) !void {
        for (n.effects) |e| {
            if (!e.visible) continue;
            const blur = e.kind == .layer_blur or e.kind == .background_blur;
            if (!blur and e.kind != .drop_shadow and e.kind != .inner_shadow) continue;
            const c = rgba(e.color, e.color.a);
            const key = if (blur)
                try std.fmt.allocPrint(g.a, "{s}|{d}", .{ @tagName(e.kind), r1(e.radius) })
            else
                try std.fmt.allocPrint(g.a, "{s}|{x:0>8}|{d}|{d}|{d}|{d}", .{ @tagName(e.kind), c, r1(e.offset.x), r1(e.offset.y), r1(e.radius), r1(e.spread) });
            const map = if (blur) &g.blurs else &g.shadows;
            const gop = try map.getOrPut(g.a, key);
            if (!gop.found_existing) gop.value_ptr.* = .{
                .kind = e.kind,
                .color = c,
                .x = r1(e.offset.x),
                .y = r1(e.offset.y),
                .radius = r1(e.radius),
                .spread = r1(e.spread),
            };
            try g.bump(&gop.value_ptr.count, n);
            if (n.styles.effect) |s| if (g.src.style(s)) |st| gop.value_ptr.styles.add(st.name);
            var refs: [8][]const u8 = undefined;
            var nr: usize = 0;
            for (e.vars) |b| if (nr < refs.len) {
                refs[nr] = b.variable;
                nr += 1;
                if (g.src.variable(b.variable)) |vr| gop.value_ptr.vars.add(try g.fullName(vr));
            };
            if (!blur) try g.useCat(5, refs[0..nr]);
        }
    }

    fn text(g: *Gather, n: *const m.Node) !void {
        const t = n.text orelse return;
        g.total_texts += 1;
        const len16 = utf16Len(t.text);
        if (t.runs.len == 0) {
            try g.typeUse(t.style, .{}, n, len16, n.styles.text);
        } else {
            var covered: u32 = 0;
            for (t.runs) |r| {
                try g.typeUse(t.style, r.style, n, r.to -| r.from, if (r.from == 0) n.styles.text else null);
                covered += r.to -| r.from;
                if (r.fills) |fs| try g.paints(fs, .text, n, null);
            }
            if (covered < len16) try g.typeUse(t.style, .{}, n, len16 - covered, n.styles.text);
        }
        if (g.doc_page) {
            const s = std.mem.trim(u8, t.text, " \n\r\t");
            if (s.len > 0 and s.len <= 80) {
                const gop = try g.doc_texts.getOrPut(g.a, try g.a.dupe(u8, s));
                if (!gop.found_existing) gop.value_ptr.* = .{
                    .frame = g.frame_name,
                    .page = g.page,
                };
                gop.value_ptr.count += 1;
            }
        }
    }

    fn typeUse(g: *Gather, base: m.TextStyle, over: m.TextStyle, n: *const m.Node, chars: u32, style: ?[]const u8) !void {
        if (chars == 0) return;
        const family = over.family orelse base.family orelse "";
        const fs = over.font_style orelse base.font_style orelse "Regular";
        const weight = over.weight orelse base.weight orelse 400;
        const italic = over.italic orelse base.italic orelse false;
        const size = over.size orelse base.size orelse 16;
        const lh = over.line_height orelse base.line_height orelse m.LineHeight.auto;
        const line: f64 = switch (lh) {
            .auto => -1,
            .px => |p| r1(p),
            .percent => |p| r1(size * p / 100),
        };
        const ls = over.letter_spacing orelse base.letter_spacing orelse m.LetterSpacing{
            .px = 0,
        };
        const tracking: f64 = switch (ls) {
            .px => |p| r2(p),
            .percent => |p| r2(size * p / 100),
        };
        const case = over.case orelse base.case orelse .none;
        const deco = over.decoration orelse base.decoration orelse .none;
        const key = try std.fmt.allocPrint(g.a, "{s}|{s}|{d}|{}|{d}|{d}|{d}|{s}|{s}", .{ family, fs, weight, italic, r1(size), line, tracking, @tagName(case), @tagName(deco) });
        const gop = try g.types.getOrPut(g.a, key);
        if (!gop.found_existing) gop.value_ptr.* = .{
            .family = try g.a.dupe(u8, family),
            .font_style = try g.a.dupe(u8, fs),
            .weight = weight,
            .italic = italic,
            .size = r1(size),
            .line = line,
            .tracking = tracking,
            .case = case,
            .decoration = deco,
        };
        try g.bump(&gop.value_ptr.count, n);
        gop.value_ptr.chars += chars;
        if (style) |s| if (g.src.style(s)) |st| gop.value_ptr.styles.add(st.name);
        // The variables its type fields follow (a run's own over the text's).
        var refs: [6][]const u8 = undefined;
        var nr: usize = 0;
        for ([_][]const u8{ "family", "fontStyle", "weight", "size", "lineHeight", "letterSpacing" }) |k| {
            const r = boundRef(over.vars, k) orelse boundRef(base.vars, k) orelse continue;
            refs[nr] = r;
            nr += 1;
            if (g.src.variable(r)) |vr| gop.value_ptr.vars.add(try g.fullName(vr));
        }
        try g.useCat(1, refs[0..nr]);
    }

    fn visit(g: *Gather, n: *const m.Node, depth: u32, in_icon: bool, parent_w: f32) anyerror!void {
        if (!n.visible) return;
        // An instance scaled as a whole is a preview of its component at another size
        // (a cover's thumbnail): its values are not the design's.
        if (n.kind == .instance and n.scale != 1) {
            g.scaled += 1;
            return;
        }
        g.total_nodes += 1;
        g.pages.items[g.page].nodes += 1;
        if (depth == 1) {
            g.frame += 1;
            g.frame_name = try g.a.dupe(u8, n.name);
            const pi = &g.pages.items[g.page];
            pi.frame_count += 1;
            if (pi.frames.items.len < 6) try pi.frames.append(g.a, .{
                .name = try g.a.dupe(u8, n.name),
                .id = try g.a.dupe(u8, n.id),
                .w = r1(n.size.x),
                .h = r1(n.size.y),
            });
        }
        try g.stack.append(g.a, n);
        defer _ = g.stack.pop();

        // Colours.
        try g.paints(n.fills, if (n.kind == .text) .text else .fill, n, if (n.kind == .text) n.styles.text orelse n.styles.fill else n.styles.fill);
        if (n.stroke.weight > 0) try g.paints(n.strokes, .stroke, n, n.styles.stroke);
        try g.effects(n);
        if (n.strokes.len > 0 and n.stroke.weight > 0) {
            var any = false;
            for (n.strokes) |p| any = any or (p.visible and p.opacity > 0);
            if (any) try g.num(&g.strokes, n.stroke.weight, n, "stroke/weight", 4);
        }
        if (n.kind == .text) try g.text(n);

        // Spacing.
        if (n.layout) |l| {
            var shown: u32 = 0;
            for (n.children) |c| if (c.visible and !c.absolute) {
                shown += 1;
            };
            if (shown > 1 and l.main != .space_between and l.main != .space_around and l.main != .space_evenly) try g.num(&g.gaps, l.gap, n, "gap", 2);
            if (shown > 1 and (l.wrap or l.mode == .grid)) try g.num(&g.gaps, l.cross_gap, n, "crossGap", 2);
            const keys = [_][]const u8{ "padding/0", "padding/1", "padding/2", "padding/3" };
            for (l.padding, keys) |p, k| try g.num(&g.paddings, p, n, k, 2);
        }

        // Corner radii.
        if (n.hasRadius() and (n.kind == .rectangle or n.kind.isContainer())) {
            const short = @min(n.size.x, n.size.y);
            const r = n.radius;
            if (r[0] == r[1] and r[1] == r[2] and r[2] == r[3]) {
                if (short > 0 and r[0] >= short / 2 - 0.5) {
                    try g.bump(&g.pills, n);
                    const ref = boundRef(n.vars, "radius") orelse boundRef(n.vars, "radius/0");
                    try g.useCat(3, if (ref) |x| &.{x} else &.{});
                } else try g.num(&g.radii, r[0], n, "radius/0", 3);
            } else {
                const keys = [_][]const u8{ "radius/0", "radius/1", "radius/2", "radius/3" };
                var seen: [4]f32 = .{ -1, -1, -1, -1 };
                for (r, keys, 0..) |v, k, i| {
                    if (v <= 0) continue;
                    var dup = false;
                    for (seen[0..i]) |s| dup = dup or s == v;
                    seen[i] = v;
                    if (!dup) try g.num(&g.radii, v, n, k, 3);
                }
            }
        }

        // Screens: a top-level frame, or one inside a much wider board.
        if ((depth == 1 or (depth == 2 and parent_w > n.size.x * 1.3)) and n.kind.isContainer() and n.kind != .component_set and n.size.x >= 300 and n.size.x <= 3000 and n.size.y >= 300) {
            const key: i32 = @intFromFloat(@round(n.size.x));
            const gop = try g.screens.getOrPut(g.a, key);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try g.bump(&gop.value_ptr.count, n);
            gop.value_ptr.names.add(try g.a.dupe(u8, n.name));
        }

        // Components and instances.
        switch (n.kind) {
            .component_set => {
                try g.comp(n, null);
                for (n.children) |*c| if (c.kind == .component) try g.comp(c, n);
            },
            .component => if (!g.comps.contains(n.id)) try g.comp(n, null),
            .instance => if (n.component) |id| {
                const gop = try g.comp_uses.getOrPut(g.a, try g.a.dupe(u8, id));
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try g.bump(gop.value_ptr, n);
                const ng = try g.comp_names.getOrPut(g.a, gop.key_ptr.*);
                if (!ng.found_existing) ng.value_ptr.* = .{
                    .name = try g.a.dupe(u8, n.name),
                    .w = r1(n.size.x),
                    .h = r1(n.size.y),
                    .props = try m.deepCopy(g.a, n.props),
                };
            } else {
                const gop = try g.lib_uses.getOrPut(g.a, try g.a.dupe(u8, n.name));
                if (!gop.found_existing) gop.value_ptr.* = .{
                    .w = r1(n.size.x),
                    .h = r1(n.size.y),
                };
                try g.bump(&gop.value_ptr.count, n);
            },
            else => {},
        }

        // Icons.
        var icon = in_icon;
        if (!in_icon and iconLike(n)) {
            icon = true;
            const main = if (n.kind == .instance) n.component else if (n.kind == .component) n.id else null;
            const name = if (n.kind == .instance) (if (n.component) |id| if (g.comps.get(id)) |c| c.name else n.name else n.name) else n.name;
            const gop = try g.icons.getOrPut(g.a, try g.a.dupe(u8, name));
            if (!gop.found_existing) gop.value_ptr.* = .{
                .name = gop.key_ptr.*,
                .w = r1(n.size.x),
                .h = r1(n.size.y),
                .kind = n.kind,
                .main = if (main) |x| try g.a.dupe(u8, x) else null,
            };
            try g.bump(&gop.value_ptr.count, n);
        }

        // Styles and variables the node follows.
        inline for (.{ "fill", "stroke", "effect", "text", "grid" }) |f| if (@field(n.styles, f)) |s| {
            const gop = try g.style_uses.getOrPut(g.a, try g.a.dupe(u8, s));
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (g.src.style(s)) |st| if (st.value == null and !g.samples.contains(s)) {
                const W = engine.pubd_write;
                const v: ?W.StyleValue = if (comptime std.mem.eql(u8, f, "fill")) .{
                    .fill = n.fills,
                } else if (comptime std.mem.eql(u8, f, "stroke")) .{
                    .fill = n.strokes,
                } else if (comptime std.mem.eql(u8, f, "effect")) .{
                    .effect = n.effects,
                } else if (comptime std.mem.eql(u8, f, "grid")) .{
                    .grid = n.grids,
                } else if (n.text) |t| .{
                    .text = t.style,
                } else null;
                if (v) |x| try g.samples.put(g.a, gop.key_ptr.*, try W.styleValueJson(g.a, x));
            };
        };
        try g.bindingsOf(n);
        for (n.modes) |mc| {
            g.key_buf.clearRetainingCapacity();
            try g.key_buf.print(g.a, "{s}\x00{s}", .{ mc.collection, mc.mode });
            const gop = try g.mode_sets.getOrPut(g.a, g.key_buf.items);
            if (!gop.found_existing) {
                gop.key_ptr.* = try g.a.dupe(u8, g.key_buf.items);
                gop.value_ptr.* = .{};
            }
            try g.bump(gop.value_ptr, n);
        }

        for (n.children) |*c| try g.visit(c, depth + 1, icon, n.size.x);
    }

    fn comp(g: *Gather, n: *const m.Node, set: ?*const m.Node) !void {
        if (g.comps.contains(n.id)) return;
        // A few of its words, for telling a button from a card.
        var words: std.ArrayList(u8) = .empty;
        collectWords(g.a, n, &words, 3);
        try g.comps.put(g.a, try g.a.dupe(u8, n.id), .{
            .id = try g.a.dupe(u8, n.id),
            .name = try g.a.dupe(u8, n.name),
            .kind = n.kind,
            .page = g.page,
            .w = r1(n.size.x),
            .h = r1(n.size.y),
            .set = if (set) |s| try g.a.dupe(u8, s.id) else null,
            .variants = if (n.kind == .component_set) @intCast(n.children.len) else 0,
            .props = try m.deepCopy(g.a, n.properties),
            .texts = words.items,
        });
    }
};

fn collectWords(a: A, n: *const m.Node, out: *std.ArrayList(u8), max: u32) void {
    if (n.text) |t| {
        const s = std.mem.trim(u8, t.text, " \n\r\t");
        if (s.len > 0) {
            var count: u32 = 0;
            for (out.items) |c| count += @intFromBool(c == '|');
            if (count >= max) return;
            out.appendSlice(a, s[0..@min(s.len, 32)]) catch return;
            out.append(a, '|') catch return;
        }
    }
    for (n.children) |*c| collectWords(a, c, out, max);
}

/// The variable a field follows, if any. A radius bound on every corner is `radius`.
fn boundRef(vars: []const m.VarBinding, key: []const u8) ?[]const u8 {
    for (vars) |b| if (std.mem.eql(u8, b.key, key)) return b.variable;
    if (std.mem.startsWith(u8, key, "radius/")) for (vars) |b| if (std.mem.eql(u8, b.key, "radius")) return b.variable;
    return null;
}

/// A node binding's key as counted: sides and corners together.
fn nodeField(key: []const u8) []const u8 {
    const groups = [_][]const u8{ "padding/", "radius/", "stroke/sides/", "props/" };
    for (groups) |p| if (std.mem.startsWith(u8, key, p)) return p[0 .. p.len - 1];
    return key;
}

fn addName(a: A, names: *std.ArrayList([]const u8), x: []const u8) !void {
    for (names.items) |y| if (std.mem.eql(u8, x, y)) return;
    try names.append(a, x);
}

/// The variable ids a value written in a variable aliases (`{"alias":"V:9"}`, also
/// inside a `compose`).
const AliasIter = struct {
    rest: []const u8,

    fn next(it: *AliasIter) ?[]const u8 {
        const tag = "\"alias\":\"";
        const i = std.mem.indexOf(u8, it.rest, tag) orelse return null;
        const s = it.rest[i + tag.len ..];
        const e = std.mem.indexOfScalar(u8, s, '"') orelse return null;
        it.rest = s[e..];
        return s[0..e];
    }
};

fn aliasIter(v: []const u8) AliasIter {
    return .{
        .rest = v,
    };
}

fn iconLike(n: *const m.Node) bool {
    switch (n.kind) {
        .instance, .component, .frame, .group => {},
        else => return false,
    }
    const w = n.size.x;
    const h = n.size.y;
    if (w < 8 or h < 8 or w > 64 or h > 64) return false;
    if (w / h > 1.67 or h / w > 1.67) return false;
    var shapes: u32 = 0;
    var count: u32 = 0;
    if (!vectorOnly(n, &shapes, &count)) return false;
    return shapes > 0;
}

fn vectorOnly(n: *const m.Node, shapes: *u32, count: *u32) bool {
    count.* += 1;
    if (count.* > 300) return false;
    switch (n.kind) {
        .text => return false,
        .vector, .boolean, .star, .polygon, .line => shapes.* += 1,
        else => {},
    }
    for (n.fills) |p| if (p.kind == .image or p.kind == .pattern) return false;
    for (n.children) |*c| if (c.visible and !vectorOnly(c, shapes, count)) return false;
    return true;
}

fn utf16Len(s: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += if (l == 4) 2 else 1;
        i += l;
    }
    return n;
}

fn cut(s: []const u8) []const u8 {
    if (s.len <= 40) return s;
    var e: usize = 40;
    while (e > 0 and (s[e] & 0xc0) == 0x80) e -= 1;
    return s[0..e];
}

pub fn r1(v: f32) f64 {
    return @round(@as(f64, v) * 10) / 10;
}

pub fn r2(v: f32) f64 {
    return @round(@as(f64, v) * 100) / 100;
}

fn byte(v: f32) u32 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

pub fn rgba(c: m.Color, alpha: f32) u32 {
    return byte(c.r) << 24 | byte(c.g) << 16 | byte(c.b) << 8 | byte(alpha);
}

pub fn hexOf(buf: *[9]u8, v: u32) []const u8 {
    const opaque_ = (v & 255) == 255;
    return if (opaque_)
        std.fmt.bufPrint(buf, "#{x:0>6}", .{v >> 8}) catch unreachable
    else
        std.fmt.bufPrint(buf, "#{x:0>8}", .{v}) catch unreachable;
}

// ------------------------------------------------------------------ output

const Cluster = struct {
    centre: u32,
    lab: color.Lab,
    uses: u32,
    members: std.ArrayList(u32) = .empty,
};

fn byUses(comptime T: type, comptime get: fn (T) u32) fn (void, T, T) bool {
    return struct {
        fn less(_: void, x: T, y: T) bool {
            return get(x) > get(y);
        }
    }.less;
}

pub fn run(io: Io, gpa: A, w: *Io.Writer, src_path: []const u8, out_path: []const u8) !void {
    return runWith(io, gpa, w, src_path, out_path, &.{});
}

pub fn runWith(io: Io, gpa: A, w: *Io.Writer, src_path: []const u8, out_path: []const u8, skip: []const []const u8) !void {
    const t0 = Io.Timestamp.now(io, .awake);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = try Source.open(io, gpa, src_path);
    defer src.deinit();
    const t_open = t0.untilNow(io, .awake);

    var g: Gather = .{
        .a = a,
        .src = src,
    };
    for (src.page_names) |name| {
        var skipped = false;
        for (skip) |s| skipped = skipped or std.ascii.indexOfIgnoreCase(name, s) != null;
        try g.pages.append(a, .{
            .name = name,
            .skipped = skipped,
        });
    }
    for (0..src.pageCount()) |i| {
        if (g.pages.items[i].skipped) continue;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const page = try src.page(scratch.allocator(), i);
        g.page = @intCast(i);
        g.doc_page = docPage(src.page_names[i]);
        for (page.children) |*c| try g.visit(c, 1, false, page.size.x);
    }
    const t_walk = t0.untilNow(io, .awake);

    const evidence = try writeEvidence(gpa, &g, src_path);
    defer gpa.free(evidence);
    try Dir.cwd().writeFile(io, .{
        .sub_path = out_path,
        .data = evidence,
    });
    const usage = try writeUsage(gpa, &g);
    defer gpa.free(usage);
    const usage_path = try std.fmt.allocPrint(a, "{s}.usage.json", .{if (std.mem.endsWith(u8, out_path, ".json")) out_path[0 .. out_path.len - 5] else out_path});
    try Dir.cwd().writeFile(io, .{
        .sub_path = usage_path,
        .data = usage,
    });
    try w.print("{s}: {d} pages, {d} nodes, {d} texts; evidence {d} bytes, usage {d} bytes; open {d} ms, walk {d} ms, total {d} ms\n", .{
        src.name,
        src.pageCount(),
        g.total_nodes,
        g.total_texts,
        evidence.len,
        usage.len,
        @divTrunc(t_open.nanoseconds, std.time.ns_per_ms),
        @divTrunc(t_walk.nanoseconds - t_open.nanoseconds, std.time.ns_per_ms),
        @divTrunc(t0.untilNow(io, .awake).nanoseconds, std.time.ns_per_ms),
    });
}

/// Pages whose names say they document the system: their words are evidence (a
/// breakpoint labelled "390 XS", a colour named on its swatch).
fn docPage(name: []const u8) bool {
    const words = [_][]const u8{ "style", "token", "foundation", "guide", "design system", "brand", "typograph", "colou", "color", "breakpoint", "icon" };
    for (words) |x| if (std.ascii.indexOfIgnoreCase(name, x) != null) return true;
    return false;
}

fn ex(s: *Stringify, c: Count) !void {
    try s.objectField("uses");
    try s.write(c.uses);
    try s.objectField("frames");
    try s.write(c.frames);
    try s.objectField("pages");
    try s.write(c.pages);
    try s.objectField("at");
    try s.beginArray();
    for (c.ex) |e| if (e) |x| {
        try s.beginArray();
        try s.write(x.page);
        try s.write(x.id);
        try s.write(x.path);
        try s.endArray();
    };
    try s.endArray();
}

fn tally(s: *Stringify, name: []const u8, t: Tally) !void {
    if (t.len == 0) return;
    try s.objectField(name);
    try s.beginObject();
    for (t.names[0..t.len], t.counts[0..t.len]) |n, c| {
        try s.objectField(n);
        try s.write(c);
    }
    try s.endObject();
}

/// A variable's value in its collection's default mode, aliases followed, as JSON text,
/// and the name of the variable it aliases (the first hop).
fn resolved(src: *const Source, v: *const m.Variable) struct {
    value: []const u8,
    alias: ?[]const u8,
} {
    var cur = v;
    var alias: ?[]const u8 = null;
    var hops: u32 = 0;
    while (hops < 16) : (hops += 1) {
        const col = src.collection(cur.collection);
        const mode = if (col) |c| (if (c.modes.len > 0) c.modes[0].id else "") else "";
        var val: []const u8 = if (cur.values.len > 0) cur.values[0].value else "null";
        for (cur.values) |x| if (std.mem.eql(u8, x.mode, mode)) {
            val = x.value;
        };
        const prefix = "{\"alias\":\"";
        if (!std.mem.startsWith(u8, val, prefix)) return .{
            .value = val,
            .alias = alias,
        };
        const id = val[prefix.len .. val.len - 2];
        const next = src.variable(id) orelse return .{
            .value = "null",
            .alias = alias,
        };
        if (alias == null) alias = next.name;
        cur = next;
    }
    return .{
        .value = "null",
        .alias = alias,
    };
}

/// A variable's worth in one mode of its collection, written as evidence: a colour as
/// hex, a number, a string, a boolean.
fn writeResolved(s: *Stringify, r: ?engine.pubd_vars.Resolved) !void {
    var buf: [9]u8 = undefined;
    const x = r orelse return s.write(null);
    switch (x) {
        .color => |c| try s.write(hexOf(&buf, rgba(c.c, c.c.a * (c.opacity orelse 1)))),
        .number => |n| try s.write(r2(n)),
        .string => |t| try s.write(t),
        .boolean => |b| try s.write(b),
    }
}

/// Declared variables: collections with their modes and the modes nodes set, every
/// variable with its value per mode (aliases named), scopes, code syntax, and how many
/// visible nodes bind it, by field. Copies of one library collection are one entry.
fn writeVariables(a: A, s: *Stringify, g: *Gather) !void {
    const src = g.src;
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var unresolved: u64 = 0;
    for (g.unresolved.values()) |x| unresolved += x;
    try s.objectField("variables_summary");
    try s.beginObject();
    try s.objectField("collections");
    try s.write(src.collections.len);
    try s.objectField("variables");
    try s.write(src.variables.len);
    try s.objectField("bindings_on_visible_nodes");
    try s.write(g.bindings);
    try s.objectField("nodes_with_a_binding");
    try s.write(g.bound_nodes);
    try s.objectField("of_nodes");
    try s.write(g.total_nodes);
    if (unresolved > 0) {
        try s.objectField("bindings_to_library_variables_not_in_the_file");
        try s.beginObject();
        for (g.unresolved.keys(), g.unresolved.values()) |k, v| {
            try s.objectField(k);
            try s.write(v);
        }
        try s.endObject();
    }
    try s.objectField("note");
    try s.write("Values are the default mode's, aliases followed; 'modes' gives each mode's value ('→ name = value' for an alias). 'bound' counts bindings on visible nodes (instances resolved), 'nodes' the nodes, 'by' the fields (fill, stroke, text-fill, stop, gap, padding, radius, width, text/size, effect/radius, ...). Names in plans are 'Collection/name'.");
    try s.endObject();

    try s.objectField("collections");
    try s.beginArray();
    {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (src.collections) |c| {
            if ((try seen.getOrPut(a, c.name)).found_existing) continue;
            try s.beginObject();
            try s.objectField("id");
            try s.write(c.id);
            try s.objectField("name");
            try s.write(c.name);
            try s.objectField("modes");
            try s.beginArray();
            for (c.modes) |md| try s.write(md.name);
            try s.endArray();
            if (c.library) {
                try s.objectField("library");
                try s.write(true);
            }
            if (c.hidden) {
                try s.objectField("hidden");
                try s.write(true);
            }
            if (c.parent) |pid| {
                try s.objectField("extends");
                try s.write(if (src.collection(pid)) |pc| pc.name else pid);
            }
            var copies: u32 = 0;
            var count: u32 = 0;
            for (src.collections) |o| if (std.mem.eql(u8, o.name, c.name)) {
                copies += 1;
                for (src.variables) |v| count += @intFromBool(std.mem.eql(u8, v.collection, o.id));
            };
            try s.objectField("variables");
            try s.write(count);
            if (copies > 1) {
                try s.objectField("copies");
                try s.write(copies);
            }
            // The modes nodes set for it (any copy).
            var any = false;
            for (g.mode_sets.keys(), g.mode_sets.values()) |k, cnt| {
                const z = std.mem.indexOfScalar(u8, k, 0) orelse continue;
                const col = src.collection(k[0..z]) orelse continue;
                if (!std.mem.eql(u8, col.name, c.name)) continue;
                if (!any) {
                    try s.objectField("set_on");
                    try s.beginObject();
                    any = true;
                }
                var mname: []const u8 = try std.fmt.allocPrint(a, "(mode {s}, not one of the collection's)", .{k[z + 1 ..]});
                for (col.modes) |md| if (std.mem.eql(u8, md.id, k[z + 1 ..])) {
                    mname = md.name;
                };
                try s.objectField(mname);
                try s.write(try std.fmt.allocPrint(a, "{d} nodes on {d} frames, {d} pages", .{ cnt.uses, cnt.frames, cnt.pages }));
            }
            if (any) try s.endObject();
            try s.endObject();
        }
    }
    try s.endArray();

    // How many variables alias each.
    var aliased: std.AutoHashMapUnmanaged(*const m.Variable, u32) = .empty;
    for (src.variables) |*v| for (v.values) |val| {
        var it = aliasIter(val.value);
        while (it.next()) |id| if (src.variable(id)) |t| {
            const gop = try aliased.getOrPut(a, t);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        };
    };

    // Copies of one variable (a library collection copied in more than once): one
    // entry, their bindings summed.
    const Group = struct {
        rep: *const m.Variable,
        bindings: u32 = 0,
        nodes: u32 = 0,
        aliased: u32 = 0,
        fields: std.StringArrayHashMapUnmanaged(u32) = .empty,
    };
    var groups: std.StringArrayHashMapUnmanaged(Group) = .empty;
    for (src.variables) |*v| {
        const col = src.collection(v.collection);
        const r = resolved(src, v);
        const key = try std.fmt.allocPrint(a, "{s}|{s}|{s}", .{ if (col) |c| c.name else "", v.name, r.value });
        const gop = try groups.getOrPut(a, key);
        if (!gop.found_existing) gop.value_ptr.* = .{
            .rep = v,
        };
        const gr = gop.value_ptr;
        gr.aliased += aliased.get(v) orelse 0;
        if (g.var_stats.getPtr(v)) |st| {
            gr.bindings += st.bindings;
            gr.nodes += st.nodes;
            for (st.fields.keys(), st.fields.values()) |k, n| {
                const fg = try gr.fields.getOrPut(a, k);
                if (!fg.found_existing) fg.value_ptr.* = 0;
                fg.value_ptr.* += n;
            }
        }
    }

    try s.objectField("variables");
    try s.beginArray();
    for (groups.values()) |*gr| {
        _ = scratch.reset(.retain_capacity);
        const v = gr.rep;
        const col = src.collection(v.collection);
        const r = resolved(src, v);
        try s.beginObject();
        try s.objectField("id");
        try s.write(v.id);
        try s.objectField("collection");
        try s.write(if (col) |c| c.name else "");
        try s.objectField("name");
        try s.write(v.name);
        try s.objectField("type");
        try s.write(@tagName(v.type));
        try s.objectField("value");
        if (v.type == .color) {
            try writeResolved(s, src.ix.resolve(sa, v.id, &.{}));
        } else {
            try s.beginWriteRaw();
            try s.writer.writeAll(r.value);
            s.endWriteRaw();
        }
        if (r.alias) |al| {
            try s.objectField("alias");
            const t = for (v.values) |val| {
                var it = aliasIter(val.value);
                if (it.next()) |id| if (src.variable(id)) |x| break x;
            } else null;
            try s.write(if (t) |x| try g.fullName(x) else al);
        }
        if (col != null and col.?.modes.len > 1) {
            try s.objectField("modes");
            try s.beginObject();
            for (col.?.modes) |md| {
                try s.objectField(md.name);
                const own = for (v.values) |x| {
                    if (std.mem.eql(u8, x.mode, md.id)) break x.value;
                } else null;
                const modes = [1]m.ModeChoice{.{
                    .collection = col.?.id,
                    .mode = md.id,
                }};
                const res = src.ix.resolve(sa, v.id, &modes);
                var it = aliasIter(own orelse "");
                if (it.next()) |id| {
                    var vbuf: std.Io.Writer.Allocating = .init(sa);
                    var vs: Stringify = .{
                        .writer = &vbuf.writer,
                    };
                    try writeResolved(&vs, res);
                    const tname = if (src.variable(id)) |x| try g.fullName(x) else id;
                    try s.write(try std.fmt.allocPrint(sa, "→ {s} = {s}", .{ tname, vbuf.written() }));
                } else try writeResolved(s, res);
            }
            try s.endObject();
        }
        if (v.scopes.len > 0) {
            try s.objectField("scopes");
            try s.write(v.scopes);
        }
        if (!v.code.isEmpty()) {
            try s.objectField("code");
            try s.beginObject();
            inline for (.{ "web", "ios", "android" }) |k| if (@field(v.code, k).len > 0) {
                try s.objectField(k);
                try s.write(@field(v.code, k));
            };
            try s.endObject();
        }
        if (v.description.len > 0) {
            try s.objectField("description");
            try s.write(v.description[0..@min(v.description.len, 200)]);
        }
        if (v.hidden) {
            try s.objectField("hidden");
            try s.write(true);
        }
        if (v.deleted) {
            try s.objectField("deleted");
            try s.write(true);
        }
        if (gr.aliased > 0) {
            try s.objectField("aliased_by");
            try s.write(gr.aliased);
        }
        try s.objectField("bound");
        try s.write(gr.bindings);
        if (gr.bindings > 0) {
            try s.objectField("nodes");
            try s.write(gr.nodes);
            try s.objectField("by");
            try s.beginObject();
            for (gr.fields.keys(), gr.fields.values()) |k, n| {
                try s.objectField(k);
                try s.write(n);
            }
            try s.endObject();
        }
        try s.endObject();
    }
    try s.endArray();
}

fn writeEvidence(gpa: A, g: *Gather, src_path: []const u8) ![]u8 {
    const a = g.a;
    const src = g.src;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: Stringify = .{
        .writer = &aw.writer,
    };
    try s.beginObject();
    try s.objectField("about");
    try s.write("Evidence for a design system, gathered exactly from a source design file. 'declared' is what the file defines; 'used' counts every visible node of every page read, instances resolved: uses (occurrences), frames (distinct top-level frames), pages, and 'at' examples as [page index, node id, path]. Colours are #rrggbb or #rrggbbaa (alpha last); sizes and spacing are px; a type line height of -1 is auto. Lists are cut to the most used; 'rest' says what was left out.");
    try s.objectField("source");
    try s.beginObject();
    try s.objectField("file");
    try s.write(std.fs.path.basename(src_path));
    try s.objectField("name");
    try s.write(src.name);
    try s.objectField("nodes");
    try s.write(g.total_nodes);
    try s.objectField("texts");
    try s.write(g.total_texts);
    try s.objectField("scaled_instances_left_out");
    try s.write(g.scaled);
    try s.objectField("pages");
    try s.beginArray();
    for (g.pages.items) |p| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(p.name);
        if (p.skipped) {
            try s.objectField("skipped");
            try s.write(true);
        } else {
            try s.objectField("nodes");
            try s.write(p.nodes);
            try s.objectField("frames");
            try s.write(p.frame_count);
            if (p.frames.items.len > 0) {
                try s.objectField("first");
                try s.beginArray();
                for (p.frames.items) |f| {
                    try s.write(try std.fmt.allocPrint(a, "{s} ({d}×{d}) {s}", .{ f.name, f.w, f.h, f.id }));
                }
                try s.endArray();
            }
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();

    // ---------------------------------------------------------- declared
    try s.objectField("declared");
    try s.beginObject();
    try s.objectField("styles");
    try s.beginObject();
    inline for (.{ m.StyleKind.fill, m.StyleKind.text, m.StyleKind.effect, m.StyleKind.grid }) |kind| {
        try s.objectField(@tagName(kind));
        try s.beginArray();
        // The same style copied in from a library more than once: one entry.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (src.styles) |st| {
            if (st.kind != kind) continue;
            const key = try std.fmt.allocPrint(a, "{s}|{s}", .{ st.name, st.value orelse "" });
            if ((try seen.getOrPut(a, key)).found_existing) continue;
            var uses: u32 = 0;
            for (src.styles) |o| if (o.kind == kind and std.mem.eql(u8, o.name, st.name) and std.mem.eql(u8, o.value orelse "", st.value orelse "")) {
                uses += g.style_uses.get(o.id) orelse 0;
            };
            try s.beginObject();
            try s.objectField("id");
            try s.write(st.id);
            try s.objectField("name");
            try s.write(st.name);
            if (st.description.len > 0) {
                try s.objectField("description");
                try s.write(st.description);
            }
            if (st.value orelse g.samples.get(st.id)) |v| {
                try s.objectField("value");
                try s.beginWriteRaw();
                try s.writer.writeAll(v);
                s.endWriteRaw();
                if (st.value == null) {
                    try s.objectField("value_from");
                    try s.write("the first node following it");
                }
            }
            try s.objectField("uses");
            try s.write(uses);
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();

    try writeVariables(a, &s, g);
    // Components: sets and standalone mains, most used first; plus every one whose
    // name or words suggest a primitive (button, input, tag, link).
    try s.objectField("components");
    {
        const Row = struct {
            info: *const CompInfo,
            uses: Count,
        };
        var rows: std.ArrayList(Row) = .empty;
        var it = g.comps.iterator();
        while (it.next()) |e| {
            const c = e.value_ptr;
            if (c.set != null) continue;
            var uses: Count = g.comp_uses.get(c.id) orelse .{};
            if (c.kind == .component_set) {
                var vi = g.comps.iterator();
                while (vi.next()) |v| if (v.value_ptr.set) |sid| if (std.mem.eql(u8, sid, c.id)) {
                    const u = g.comp_uses.get(v.value_ptr.id) orelse Count{};
                    uses.uses += u.uses;
                    uses.frames += u.frames;
                    uses.pages = @max(uses.pages, u.pages);
                    for (&uses.ex) |*x| if (x.* == null) {
                        x.* = u.ex[0];
                    };
                };
            }
            try rows.append(a, .{
                .info = c,
                .uses = uses,
            });
        }
        std.mem.sort(Row, rows.items, {}, struct {
            fn less(_: void, x: Row, y: Row) bool {
                return x.uses.uses > y.uses.uses;
            }
        }.less);
        try s.beginObject();
        try s.objectField("total");
        try s.write(rows.items.len);
        try s.objectField("list");
        try s.beginArray();
        var shown: u32 = 0;
        for (rows.items, 0..) |r, i| {
            const prim = primitiveName(r.info.name) or primitiveName(r.info.texts);
            if (i >= 60 and !(prim and shown < 140)) continue;
            shown += 1;
            const c = r.info;
            try s.beginObject();
            try s.objectField("id");
            try s.write(c.id);
            try s.objectField("name");
            try s.write(c.name);
            try s.objectField("kind");
            try s.write(@tagName(c.kind));
            try s.objectField("page");
            try s.write(c.page);
            try s.objectField("size");
            try s.write([2]f64{ c.w, c.h });
            if (c.variants > 0) {
                try s.objectField("variants");
                try s.write(c.variants);
            }
            if (c.texts.len > 0) {
                try s.objectField("words");
                try s.write(c.texts);
            }
            if (c.props.len > 0) {
                try s.objectField("props");
                try s.beginArray();
                for (c.props) |p| {
                    var line: std.ArrayList(u8) = .empty;
                    try line.print(a, "{s}: {s}", .{ p.name, @tagName(p.kind) });
                    if (p.options.len > 0) {
                        try line.appendSlice(a, " [");
                        for (p.options, 0..) |o, k| {
                            if (k > 0) try line.appendSlice(a, ", ");
                            if (k >= 8) {
                                try line.print(a, "… {d} more", .{p.options.len - k});
                                break;
                            }
                            try line.appendSlice(a, o);
                        }
                        try line.appendSlice(a, "]");
                    }
                    try s.write(line.items);
                }
                try s.endArray();
            }
            try ex(&s, r.uses);
            try s.endObject();
        }
        try s.endArray();
        try s.objectField("rest");
        try s.write(rows.items.len - shown);
        try s.endObject();
    }

    // Components whose main is not in the file (a library's), by the name their
    // instances carry: most used first, plus every primitive-looking one.
    try s.objectField("library_components");
    {
        const Row = struct {
            id: []const u8,
            uses: Count,
        };
        var rows: std.ArrayList(Row) = .empty;
        var byname: std.StringHashMapUnmanaged(usize) = .empty;
        for (g.comp_uses.keys(), g.comp_uses.values()) |id, u| {
            if (g.comps.contains(id)) continue;
            const info = g.comp_names.get(id).?;
            // Variants of one component share a name: one row, uses summed.
            const gop = try byname.getOrPut(a, info.name);
            if (gop.found_existing) {
                const r = &rows.items[gop.value_ptr.*];
                r.uses.uses += u.uses;
                r.uses.frames += u.frames;
                r.uses.pages = @max(r.uses.pages, u.pages);
                continue;
            }
            gop.value_ptr.* = rows.items.len;
            try rows.append(a, .{
                .id = id,
                .uses = u,
            });
        }
        std.mem.sort(Row, rows.items, {}, struct {
            fn less(_: void, x: Row, y: Row) bool {
                return x.uses.uses > y.uses.uses;
            }
        }.less);
        try s.beginObject();
        try s.objectField("total");
        try s.write(rows.items.len);
        try s.objectField("list");
        try s.beginArray();
        var shown: u32 = 0;
        for (rows.items, 0..) |r, i| {
            const info = g.comp_names.get(r.id).?;
            if (i >= 50 and !(primitiveName(info.name) and shown < 110)) continue;
            shown += 1;
            try s.beginObject();
            try s.objectField("id");
            try s.write(r.id);
            try s.objectField("name");
            try s.write(info.name);
            try s.objectField("size");
            try s.write([2]f64{ info.w, info.h });
            if (info.props.len > 0) {
                try s.objectField("props");
                try s.beginObject();
                for (info.props) |p| {
                    try s.objectField(p.id);
                    try s.beginWriteRaw();
                    try s.writer.writeAll(p.value);
                    s.endWriteRaw();
                }
                try s.endObject();
            }
            try ex(&s, r.uses);
            try s.endObject();
        }
        try s.endArray();
        try s.objectField("rest");
        try s.write(rows.items.len - shown);
        try s.endObject();
    }

    // Instances that name no component at all (a REST import of a library's).
    try s.objectField("library_instances");
    {
        const keys = g.lib_uses.keys();
        const vals = g.lib_uses.values();
        const idx = try a.alloc(usize, keys.len);
        for (idx, 0..) |*x, i| x.* = i;
        std.mem.sort(usize, idx, vals, struct {
            fn less(v: []const LibUse, x: usize, y: usize) bool {
                return v[x].count.uses > v[y].count.uses;
            }
        }.less);
        try s.beginArray();
        for (idx[0..@min(idx.len, 50)]) |i| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(keys[i]);
            try s.objectField("size");
            try s.write([2]f64{ vals[i].w, vals[i].h });
            try ex(&s, vals[i].count);
            try s.endObject();
        }
        try s.endArray();
    }

    // Words on pages that document the system.
    try s.objectField("documented");
    {
        try s.beginArray();
        const keys = g.doc_texts.keys();
        const vals = g.doc_texts.values();
        for (keys[0..@min(keys.len, 500)], vals[0..@min(keys.len, 500)]) |k, v| {
            try s.write(try std.fmt.allocPrint(a, "{s} — {s} (p{d}){s}", .{ k, cut(v.frame), v.page, if (v.count > 1) try std.fmt.allocPrint(a, " ×{d}", .{v.count}) else "" }));
        }
        try s.endArray();
    }
    try s.endObject();

    // ---------------------------------------------------------- used
    try s.objectField("used");
    try s.beginObject();
    try writeColors(a, &s, g);
    try writeTypes(a, &s, g);
    try writeNums(a, &s, "gaps", &g.gaps, 40);
    try writeNums(a, &s, "paddings", &g.paddings, 40);
    try writeNums(a, &s, "radii", &g.radii, 30);
    try s.objectField("pill_radii");
    try s.beginObject();
    try ex(&s, g.pills);
    try s.endObject();
    try writeNums(a, &s, "stroke_weights", &g.strokes, 12);
    try writeShadows(a, &s, "shadows", &g.shadows);
    try writeShadows(a, &s, "blurs", &g.blurs);

    try s.objectField("screen_widths");
    {
        const keys = g.screens.keys();
        const vals = g.screens.values();
        const idx = try a.alloc(usize, keys.len);
        for (idx, 0..) |*x, i| x.* = i;
        std.mem.sort(usize, idx, vals, struct {
            fn less(v: []const ScreenUse, x: usize, y: usize) bool {
                return v[x].count.uses > v[y].count.uses;
            }
        }.less);
        try s.beginArray();
        for (idx[0..@min(idx.len, 30)]) |i| {
            try s.beginObject();
            try s.objectField("width");
            try s.write(keys[i]);
            try tally(&s, "names", vals[i].names);
            try ex(&s, vals[i].count);
            try s.endObject();
        }
        try s.endArray();
    }

    try s.objectField("icons");
    {
        const vals = g.icons.values();
        std.mem.sort(IconUse, vals, {}, struct {
            fn less(_: void, x: IconUse, y: IconUse) bool {
                return x.count.uses > y.count.uses;
            }
        }.less);
        try s.beginObject();
        try s.objectField("total");
        try s.write(vals.len);
        try s.objectField("list");
        try s.beginArray();
        for (vals[0..@min(vals.len, 50)]) |v| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(v.name);
            try s.objectField("size");
            try s.write([2]f64{ v.w, v.h });
            try s.objectField("kind");
            try s.write(@tagName(v.kind));
            if (v.main) |x| {
                try s.objectField("main");
                try s.write(x);
            }
            try ex(&s, v.count);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endObject();
    try s.endObject();
    try aw.writer.writeByte('\n');
    return aw.toOwnedSlice();
}

fn primitiveName(name: []const u8) bool {
    const words = [_][]const u8{ "button", "btn", "cta", "link", "input", "field", "tag", "badge", "chip", "pill", "toggle", "checkbox", "radio", "select", "dropdown", "label" };
    for (words) |x| if (std.ascii.indexOfIgnoreCase(name, x) != null) return true;
    return false;
}

fn writeColors(a: A, s: *Stringify, g: *Gather) !void {
    // Clusters: most used first; a colour within ΔE00 2 of a centre with the same alpha
    // (to 0.05) joins it.
    const keys = g.colors.keys();
    const vals = g.colors.values();
    const idx = try a.alloc(usize, keys.len);
    for (idx, 0..) |*x, i| x.* = i;
    std.mem.sort(usize, idx, vals, struct {
        fn less(v: []const ColorUse, x: usize, y: usize) bool {
            return v[x].count.uses > v[y].count.uses;
        }
    }.less);
    var clusters: std.ArrayList(Cluster) = .empty;
    var member_of = try a.alloc(usize, keys.len);
    var total: u64 = 0;
    for (idx) |i| {
        total += vals[i].count.uses;
        const k = keys[i];
        const lab = color.labHex(k >> 8);
        const al = (k & 255) * 20 / 255;
        var found: ?usize = null;
        for (clusters.items, 0..) |*c, ci| {
            if ((c.centre & 255) * 20 / 255 != al) continue;
            if (color.de2000(c.lab, lab) <= 2.0) {
                found = ci;
                break;
            }
        }
        if (found) |ci| {
            clusters.items[ci].uses += vals[i].count.uses;
            try clusters.items[ci].members.append(a, @intCast(i));
            member_of[i] = ci;
        } else {
            try clusters.append(a, .{
                .centre = k,
                .lab = lab,
                .uses = vals[i].count.uses,
            });
            try clusters.items[clusters.items.len - 1].members.append(a, @intCast(i));
            member_of[i] = clusters.items.len - 1;
        }
    }
    std.mem.sort(Cluster, clusters.items, {}, struct {
        fn less(_: void, x: Cluster, y: Cluster) bool {
            return x.uses > y.uses;
        }
    }.less);
    try s.objectField("colors");
    try s.beginObject();
    try s.objectField("distinct");
    try s.write(keys.len);
    try s.objectField("uses");
    try s.write(total);
    try s.objectField("clusters");
    try s.write(clusters.items.len);
    try s.objectField("list");
    try s.beginArray();
    const shown = @min(clusters.items.len, 70);
    var buf: [9]u8 = undefined;
    for (clusters.items[0..shown]) |c| {
        const lead = c.members.items[0];
        const u = vals[lead];
        try s.beginObject();
        try s.objectField("hex");
        try s.write(hexOf(&buf, c.centre));
        try s.objectField("cluster_uses");
        try s.write(c.uses);
        try s.objectField("by");
        try s.beginObject();
        inline for (.{ "fill", "stroke", "text", "stop" }, 0..) |name, k| if (u.by[k] > 0) {
            try s.objectField(name);
            try s.write(u.by[k]);
        };
        try s.endObject();
        try tally(s, "styles", u.styles);
        try tally(s, "variables", u.vars);
        if (c.members.items.len > 1) {
            try s.objectField("near");
            try s.beginArray();
            for (c.members.items[1..@min(c.members.items.len, 7)]) |mi| {
                try s.write(try std.fmt.allocPrint(a, "{s} ×{d}", .{ hexOf(&buf, keys[mi]), vals[mi].count.uses }));
            }
            if (c.members.items.len > 7) try s.write(try std.fmt.allocPrint(a, "… {d} more", .{c.members.items.len - 7}));
            try s.endArray();
        }
        try ex(s, u.count);
        try s.endObject();
    }
    try s.endArray();
    var rest: u64 = 0;
    for (clusters.items[shown..]) |c| rest += c.uses;
    try s.objectField("rest");
    try s.write(try std.fmt.allocPrint(a, "{d} clusters, {d} uses", .{ clusters.items.len - shown, rest }));
    try s.endObject();
}

fn writeTypes(a: A, s: *Stringify, g: *Gather) !void {
    // Clustered by family, weight, style and size (to 1px); line heights, tracking,
    // cases and decorations are counted inside.
    const Group = struct {
        key: []const u8,
        family: []const u8,
        font_style: []const u8,
        weight: u16,
        size: f64,
        uses: u32 = 0,
        chars: u32 = 0,
        frames: u32 = 0,
        members: std.ArrayList(*const TypeUse) = .empty,
    };
    var groups: std.StringArrayHashMapUnmanaged(Group) = .empty;
    var total: u64 = 0;
    var fonts: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(u32)) = .empty;
    for (g.types.values()) |*t| {
        total += t.count.uses;
        const key = try std.fmt.allocPrint(a, "{s}|{s}|{d}|{d}", .{ t.family, t.font_style, t.weight, @round(t.size) });
        const gop = try groups.getOrPut(a, key);
        if (!gop.found_existing) gop.value_ptr.* = .{
            .key = key,
            .family = t.family,
            .font_style = t.font_style,
            .weight = t.weight,
            .size = @round(t.size),
        };
        gop.value_ptr.uses += t.count.uses;
        gop.value_ptr.chars += t.chars;
        gop.value_ptr.frames = @max(gop.value_ptr.frames, t.count.frames);
        try gop.value_ptr.members.append(a, t);
        const fg = try fonts.getOrPut(a, t.family);
        if (!fg.found_existing) fg.value_ptr.* = .empty;
        const sg = try fg.value_ptr.getOrPut(a, try std.fmt.allocPrint(a, "{d} {s}", .{ t.weight, t.font_style }));
        if (!sg.found_existing) sg.value_ptr.* = 0;
        sg.value_ptr.* += t.count.uses;
    }
    try s.objectField("fonts");
    try s.beginObject();
    for (fonts.keys(), fonts.values()) |k, v| {
        try s.objectField(k);
        try s.beginObject();
        for (v.keys(), v.values()) |x, n| {
            try s.objectField(x);
            try s.write(n);
        }
        try s.endObject();
    }
    try s.endObject();
    const list = groups.values();
    std.mem.sort(Group, list, {}, struct {
        fn less(_: void, x: Group, y: Group) bool {
            return x.uses > y.uses;
        }
    }.less);
    try s.objectField("type");
    try s.beginObject();
    try s.objectField("combinations");
    try s.write(g.types.count());
    try s.objectField("uses");
    try s.write(total);
    try s.objectField("groups");
    try s.write(list.len);
    try s.objectField("list");
    try s.beginArray();
    const shown = @min(list.len, 60);
    for (list[0..shown]) |*gr| {
        std.mem.sort(*const TypeUse, gr.members.items, {}, struct {
            fn less(_: void, x: *const TypeUse, y: *const TypeUse) bool {
                return x.count.uses > y.count.uses;
            }
        }.less);
        try s.beginObject();
        try s.objectField("font");
        try s.write(try std.fmt.allocPrint(a, "{s} {s} {d}", .{ gr.family, gr.font_style, gr.weight }));
        try s.objectField("size");
        try s.write(gr.size);
        try s.objectField("uses");
        try s.write(gr.uses);
        try s.objectField("chars");
        try s.write(gr.chars);
        try s.objectField("variants");
        try s.beginArray();
        for (gr.members.items[0..@min(gr.members.items.len, 5)]) |t| {
            var line: std.ArrayList(u8) = .empty;
            try line.print(a, "size {d} lh {s} ls {d}", .{ t.size, if (t.line < 0) "auto" else try std.fmt.allocPrint(a, "{d}", .{t.line}), t.tracking });
            if (t.case != .none) try line.print(a, " {s}", .{@tagName(t.case)});
            if (t.decoration != .none) try line.print(a, " {s}", .{@tagName(t.decoration)});
            if (t.italic) try line.appendSlice(a, " italic");
            try line.print(a, " ×{d} on {d} frames", .{ t.count.uses, t.count.frames });
            if (t.styles.len > 0) {
                try line.appendSlice(a, " style:");
                for (t.styles.names[0..t.styles.len]) |n| try line.print(a, " {s}", .{n});
            }
            if (t.vars.len > 0) {
                try line.appendSlice(a, " variables:");
                for (t.vars.names[0..t.vars.len]) |n| try line.print(a, " {s}", .{n});
            }
            try s.write(line.items);
        }
        if (gr.members.items.len > 5) try s.write(try std.fmt.allocPrint(a, "… {d} more", .{gr.members.items.len - 5}));
        try s.endArray();
        try s.objectField("at");
        try s.beginArray();
        if (gr.members.items[0].count.ex[0]) |x| {
            try s.beginArray();
            try s.write(x.page);
            try s.write(x.id);
            try s.write(x.path);
            try s.endArray();
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    var rest: u64 = 0;
    for (list[shown..]) |gr| rest += gr.uses;
    try s.objectField("rest");
    try s.write(try std.fmt.allocPrint(a, "{d} groups, {d} uses", .{ list.len - shown, rest }));
    try s.endObject();
}

fn writeNums(a: A, s: *Stringify, name: []const u8, map: *std.AutoArrayHashMapUnmanaged(i32, NumUse), max: usize) !void {
    const keys = map.keys();
    const vals = map.values();
    const idx = try a.alloc(usize, keys.len);
    var total: u64 = 0;
    for (idx, 0..) |*x, i| {
        x.* = i;
        total += vals[i].count.uses;
    }
    std.mem.sort(usize, idx, vals, struct {
        fn less(v: []const NumUse, x: usize, y: usize) bool {
            return v[x].count.uses > v[y].count.uses;
        }
    }.less);
    try s.objectField(name);
    try s.beginObject();
    try s.objectField("uses");
    try s.write(total);
    try s.objectField("list");
    try s.beginArray();
    const shown = @min(idx.len, max);
    for (idx[0..shown]) |i| {
        try s.beginObject();
        try s.objectField("value");
        try s.write(@as(f64, @floatFromInt(keys[i])) / 2);
        try tally(s, "variables", vals[i].vars);
        try ex(s, vals[i].count);
        try s.endObject();
    }
    try s.endArray();
    var rest: u64 = 0;
    for (idx[shown..]) |i| rest += vals[i].count.uses;
    try s.objectField("rest");
    try s.write(try std.fmt.allocPrint(a, "{d} values, {d} uses", .{ idx.len - shown, rest }));
    try s.endObject();
}

fn writeShadows(a: A, s: *Stringify, name: []const u8, map: *std.StringArrayHashMapUnmanaged(ShadowUse)) !void {
    const vals = map.values();
    std.mem.sort(ShadowUse, vals, {}, struct {
        fn less(_: void, x: ShadowUse, y: ShadowUse) bool {
            return x.count.uses > y.count.uses;
        }
    }.less);
    _ = a;
    try s.objectField(name);
    try s.beginArray();
    var buf: [9]u8 = undefined;
    for (vals[0..@min(vals.len, 25)]) |v| {
        try s.beginObject();
        try s.objectField("type");
        try s.write(@tagName(v.kind));
        if (v.kind == .drop_shadow or v.kind == .inner_shadow) {
            try s.objectField("color");
            try s.write(hexOf(&buf, v.color));
            try s.objectField("offset");
            try s.write([2]f64{ v.x, v.y });
            try s.objectField("spread");
            try s.write(v.spread);
        }
        try s.objectField("radius");
        try s.write(v.radius);
        try tally(s, "styles", v.styles);
        try tally(s, "variables", v.vars);
        try ex(s, v.count);
        try s.endObject();
    }
    try s.endArray();
}

/// Every value with its count (and per colour, its uses by kind), for `verify`.
fn writeUsage(gpa: A, g: *Gather) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: Stringify = .{
        .writer = &aw.writer,
    };
    var buf: [9]u8 = undefined;
    try s.beginObject();
    try s.objectField("colors");
    try s.beginArray();
    for (g.colors.keys(), g.colors.values()) |k, v| {
        try s.beginArray();
        try s.write(hexOf(&buf, k));
        try s.write(v.count.uses);
        if (v.count.ex[0]) |x| try s.write(x.path);
        try s.endArray();
    }
    try s.endArray();
    try s.objectField("type");
    try s.beginArray();
    for (g.types.values()) |t| {
        try s.beginArray();
        try s.write(t.family);
        try s.write(t.weight);
        try s.write(t.size);
        try s.write(t.line);
        try s.write(t.tracking);
        try s.write(@tagName(t.case));
        try s.write(t.count.uses);
        if (t.count.ex[0]) |x| try s.write(x.path);
        try s.endArray();
    }
    try s.endArray();
    inline for (.{ "gaps", "paddings", "radii" }) |name| {
        try s.objectField(name);
        try s.beginArray();
        const map = &@field(g, name);
        for (map.keys(), map.values()) |k, v| {
            try s.beginArray();
            try s.write(@as(f64, @floatFromInt(k)) / 2);
            try s.write(v.count.uses);
            if (v.count.ex[0]) |x| try s.write(x.path);
            try s.endArray();
        }
        try s.endArray();
    }
    try s.objectField("pills");
    try s.write(g.pills.uses);
    // Coverage by binding: per kind, every use, and the uses that bind variables (the
    // names include the variables they alias in any mode).
    try s.objectField("bound");
    try s.beginObject();
    for (cats, 0..) |c, i| {
        try s.objectField(c);
        try s.beginObject();
        try s.objectField("uses");
        try s.write(g.cat_uses[i]);
        try s.objectField("bound");
        try s.beginArray();
        for (g.bound.values()) |b| if (std.mem.eql(u8, b.cat, c)) {
            try s.beginArray();
            try s.write(b.uses);
            try s.write(b.names);
            try s.endArray();
        };
        try s.endArray();
        try s.endObject();
    }
    try s.endObject();
    try s.endObject();
    try aw.writer.writeByte('\n');
    return aw.toOwnedSlice();
}
