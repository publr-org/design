//! Variables (pubd/SPEC.md "Variables"): what a variable is worth at a node, in the modes
//! the node and its ancestors set, and the fields bound to variables set to it.
//!
//! A file keeps every bound field's resolved value beside its binding, so a reader that
//! ignores variables draws it right; this is what keeps those values true. Readers run it
//! on the nodes they read (`resolveTree`), the editor on what an edit reaches.

const std = @import("std");
const m = @import("model.zig");
const read = @import("read.zig");
const jv = @import("../jv.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Aliases and compositions followed at most this deep (a loop resolves to nothing).
pub const max_depth = 32;

/// A variable's worth at a node.
pub const Resolved = union(enum) {
    /// A colour; `opacity` (0..1) when the variable composes its opacity from a number
    /// (a paint takes it as its opacity, anything else multiplies it into the alpha).
    color: struct {
        c: m.Color,
        opacity: ?f32 = null,
    },
    number: f32,
    /// Points into the resolver's scratch memory.
    string: []const u8,
    boolean: bool,
};

/// The document's variables and collections by id (and by library key).
pub const Index = struct {
    vars: std.StringHashMapUnmanaged(*const m.Variable) = .empty,
    keys: std.StringHashMapUnmanaged(*const m.Variable) = .empty,
    cols: std.StringHashMapUnmanaged(*const m.Collection) = .empty,

    pub fn init(gpa: Allocator, doc: *const m.Document) !Index {
        return fromLists(gpa, doc.collections, doc.variables);
    }

    /// The index of these lists (they must stay where they are while it is used).
    pub fn fromLists(gpa: Allocator, collections: []const m.Collection, variables: []const m.Variable) !Index {
        var ix: Index = .{};
        errdefer ix.deinit(gpa);
        try ix.vars.ensureTotalCapacity(gpa, @intCast(variables.len));
        for (variables) |*v| {
            ix.vars.putAssumeCapacity(v.id, v);
            if (v.key.len > 0) try ix.keys.put(gpa, v.key, v);
        }
        for (collections) |*c| try ix.cols.put(gpa, c.id, c);
        return ix;
    }

    pub fn deinit(ix: *Index, gpa: Allocator) void {
        ix.vars.deinit(gpa);
        ix.keys.deinit(gpa);
        ix.cols.deinit(gpa);
        ix.* = undefined;
    }

    pub fn isEmpty(ix: *const Index) bool {
        return ix.vars.count() == 0;
    }

    /// The variable a reference names: its id, or `key:<library key>`.
    pub fn lookup(ix: *const Index, ref: []const u8) ?*const m.Variable {
        if (ix.vars.get(ref)) |v| return v;
        if (std.mem.startsWith(u8, ref, "key:")) return ix.keys.get(ref["key:".len..]);
        return null;
    }

    /// The mode collection `c` is in under `modes` (innermost last): the innermost choice
    /// for it or for a collection extending it, else its default (its first mode).
    pub fn modeOf(ix: *const Index, c: *const m.Collection, modes: []const m.ModeChoice) Pick {
        var i = modes.len;
        while (i > 0) {
            i -= 1;
            const mc = modes[i];
            if (std.mem.eql(u8, mc.collection, c.id)) {
                if (hasMode(c, mc.mode)) return .{
                    .mode = mc.mode,
                };
                continue;
            }
            // An extended collection's mode stands for the parent mode it extends.
            const ext = ix.cols.get(mc.collection) orelse continue;
            const parent = ext.parent orelse continue;
            if (!std.mem.eql(u8, parent, c.id)) continue;
            for (ext.modes) |md| if (std.mem.eql(u8, md.id, mc.mode)) {
                return .{
                    .mode = md.parent orelse (if (c.modes.len > 0) c.modes[0].id else ""),
                    .ext = ext,
                    .ext_mode = md.id,
                };
            };
        }
        return .{
            .mode = if (c.modes.len > 0) c.modes[0].id else "",
        };
    }

    pub const Pick = struct {
        mode: []const u8,
        /// An extended collection whose mode was chosen, and that mode.
        ext: ?*const m.Collection = null,
        ext_mode: []const u8 = "",
    };

    /// Variable `v`'s own value (JSON) under `modes`, before aliases are followed.
    pub fn valueAt(ix: *const Index, v: *const m.Variable, modes: []const m.ModeChoice) ?[]const u8 {
        const c = ix.cols.get(v.collection) orelse return firstValue(v);
        const pick = ix.modeOf(c, modes);
        if (pick.ext) |ext| for (ext.overrides) |o| if (std.mem.eql(u8, o.variable, v.id)) {
            for (o.values) |x| if (std.mem.eql(u8, x.mode, pick.ext_mode)) return x.value;
        };
        for (v.values) |x| if (std.mem.eql(u8, x.mode, pick.mode)) return x.value;
        // A mode without a value (a mode the variable never had): the default's.
        if (c.modes.len > 0) for (v.values) |x| if (std.mem.eql(u8, x.mode, c.modes[0].id)) return x.value;
        return firstValue(v);
    }

    /// What variable `ref` is worth under `modes`, aliases followed (each in its own
    /// collection's mode there). Null when it is not in the document, or loops.
    pub fn resolve(ix: *const Index, scratch: Allocator, ref: []const u8, modes: []const m.ModeChoice) ?Resolved {
        return ix.resolveDepth(scratch, ref, modes, 0);
    }

    fn resolveDepth(ix: *const Index, scratch: Allocator, ref: []const u8, modes: []const m.ModeChoice, depth: u32) ?Resolved {
        if (depth > max_depth) return null;
        const v = ix.lookup(ref) orelse return null;
        const json = ix.valueAt(v, modes) orelse return null;
        const val = read.parseValue(scratch, json) catch return null;
        return ix.valueOf(scratch, v.type, val, modes, depth);
    }

    /// A value as written in a variable (a colour, number, string, boolean, alias or
    /// composition) as what it is worth.
    pub fn valueOf(ix: *const Index, scratch: Allocator, t: m.VariableType, val: Value, modes: []const m.ModeChoice, depth: u32) ?Resolved {
        switch (val) {
            .object => |o| {
                if (o.get("alias")) |al| {
                    if (al != .string) return null;
                    return ix.resolveDepth(scratch, al.string, modes, depth + 1);
                }
                if (o.get("compose")) |cp| {
                    const base = ix.valueOf(scratch, .color, jv.get(cp, "color") orelse return null, modes, depth + 1) orelse return null;
                    if (base != .color) return null;
                    const op = ix.valueOf(scratch, .number, jv.get(cp, "opacity") orelse return base, modes, depth + 1) orelse return base;
                    if (op != .number) return base;
                    return .{
                        .color = .{
                            .c = base.color.c,
                            .opacity = std.math.clamp(op.number / 100, 0, 1),
                        },
                    };
                }
                return null;
            },
            .integer => |x| return .{
                .number = @floatFromInt(x),
            },
            .float => |x| return .{
                .number = @floatCast(x),
            },
            .number_string => |x| return .{
                .number = std.fmt.parseFloat(f32, x) catch return null,
            },
            .bool => |b| return .{
                .boolean = b,
            },
            .string => |s| return if (t == .color) .{
                .color = .{
                    .c = read.color(val),
                },
            } else .{
                .string = s,
            },
            .array => return .{
                .color = .{
                    .c = read.color(val),
                },
            },
            .null => return null,
        }
    }

    /// The variables whose worth may change when those in `changed` do: themselves and
    /// every variable that aliases or composes one of them, at any depth.
    pub fn dependents(ix: *const Index, gpa: Allocator, changed: []const []const u8) !std.StringHashMapUnmanaged(void) {
        var set: std.StringHashMapUnmanaged(void) = .empty;
        errdefer set.deinit(gpa);
        for (changed) |id| try set.put(gpa, id, {});
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        // Each variable's references, once.
        var refs: std.ArrayList(struct {
            id: []const u8,
            to: []const []const u8,
        }) = .empty;
        var it = ix.vars.valueIterator();
        while (it.next()) |vp| {
            const v = vp.*;
            var to: std.ArrayList([]const u8) = .empty;
            for (v.values) |x| try referencesIn(scratch.allocator(), x.value, &to);
            if (ix.cols.get(v.collection)) |_| {
                var ci = ix.cols.valueIterator();
                while (ci.next()) |cp| for (cp.*.overrides) |o| if (std.mem.eql(u8, o.variable, v.id)) {
                    for (o.values) |x| try referencesIn(scratch.allocator(), x.value, &to);
                };
            }
            if (to.items.len > 0) try refs.append(scratch.allocator(), .{
                .id = v.id,
                .to = to.items,
            });
        }
        var grew = true;
        while (grew) {
            grew = false;
            for (refs.items) |r| {
                if (set.contains(r.id)) continue;
                for (r.to) |t| {
                    const target = if (ix.lookup(t)) |tv| tv.id else t;
                    if (set.contains(target)) {
                        try set.put(gpa, r.id, {});
                        grew = true;
                        break;
                    }
                }
            }
        }
        return set;
    }
};

fn hasMode(c: *const m.Collection, id: []const u8) bool {
    for (c.modes) |md| if (std.mem.eql(u8, md.id, id)) return true;
    return false;
}

fn firstValue(v: *const m.Variable) ?[]const u8 {
    return if (v.values.len > 0) v.values[0].value else null;
}

/// The variable references (`alias`) in a value's JSON, into `out`.
pub fn referencesIn(a: Allocator, json: []const u8, out: *std.ArrayList([]const u8)) !void {
    if (std.mem.indexOf(u8, json, "alias") == null) return;
    const v = read.parseValue(a, json) catch return;
    try collectRefs(a, v, out);
}

fn collectRefs(a: Allocator, v: Value, out: *std.ArrayList([]const u8)) !void {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.key_ptr.*, "alias") and e.value_ptr.* == .string) {
                    try out.append(a, e.value_ptr.string);
                } else try collectRefs(a, e.value_ptr.*, out);
            }
        },
        .array => |xs| for (xs.items) |x| try collectRefs(a, x, out),
        else => {},
    }
}

// ---------------------------------------------------------------------- bound fields

/// The node keys (Pubd) a resolution may change.
pub const node_keys = [_][]const u8{
    "visible", "opacity", "size",      "minWidth", "maxWidth",   "minHeight", "maxHeight", "radius",
    "stroke",  "layout",  "transform", "count",    "fills",      "strokes",   "effects",   "grids",
    "text",    "style",   "runs",      "glyphs",   "glyphRects",
};

/// Which of `node_keys` a resolution changed.
pub const Changed = struct {
    bits: u32 = 0,
    /// A run's style changed (its glyphs may move); without it, `runs` changed only the
    /// runs' paints.
    runs_layout: bool = false,

    fn bit(comptime name: []const u8) u32 {
        inline for (node_keys, 0..) |k, i| if (comptime std.mem.eql(u8, k, name)) return @as(u32, 1) << i;
        @compileError("not a key: " ++ name);
    }

    pub fn set(c: *Changed, comptime name: []const u8) void {
        c.bits |= bit(name);
    }

    pub fn has(c: Changed, comptime name: []const u8) bool {
        return c.bits & bit(name) != 0;
    }

    pub fn any(c: Changed) bool {
        return c.bits != 0;
    }

    /// Only paints changed (fills, strokes, effects, opacity, the runs' paints): a
    /// variable changes a paint's colour, never how many there are, so nothing moves or
    /// changes size and nothing is laid out again.
    pub fn paintOnly(c: Changed) bool {
        const paints = bit("fills") | bit("strokes") | bit("effects") | bit("opacity") | bit("runs");
        return c.bits & ~paints == 0 and !(c.has("runs") and c.runs_layout);
    }

    /// The keys, in `node_keys` order.
    pub fn list(c: Changed, buf: *[node_keys.len][]const u8) []const []const u8 {
        var n: usize = 0;
        for (node_keys, 0..) |k, i| if (c.bits & (@as(u32, 1) << @intCast(i)) != 0) {
            buf[n] = k;
            n += 1;
        };
        return buf[0..n];
    }
};

/// Whether anything of `n` itself (not its children) follows a variable.
pub fn hasBindings(n: *const m.Node) bool {
    if (n.vars.len > 0) return true;
    if (paintsBound(n.fills) or paintsBound(n.strokes)) return true;
    for (n.effects) |e| if (e.vars.len > 0) return true;
    for (n.grids) |g| if (g.vars.len > 0) return true;
    if (n.text) |t| {
        if (t.style.vars.len > 0) return true;
        for (t.runs) |r| {
            if (r.style.vars.len > 0) return true;
            if (r.fills) |fs| if (paintsBound(fs)) return true;
        }
    }
    return false;
}

fn paintsBound(ps: []const m.Paint) bool {
    for (ps) |p| {
        if (p.variable != null or p.vars.len > 0) return true;
        for (p.stops) |s| if (s.variable != null) return true;
    }
    return false;
}

/// Whether `n` itself follows any variable in `set` (ids).
pub fn usesAny(ix: *const Index, n: *const m.Node, set: *const std.StringHashMapUnmanaged(void)) bool {
    const S = struct {
        fn in(x: *const Index, s: *const std.StringHashMapUnmanaged(void), ref: []const u8) bool {
            if (s.contains(ref)) return true;
            if (x.lookup(ref)) |v| return s.contains(v.id);
            return false;
        }
        fn bs(x: *const Index, s: *const std.StringHashMapUnmanaged(void), list: []const m.VarBinding) bool {
            for (list) |b| if (in(x, s, b.variable)) return true;
            return false;
        }
        fn ps(x: *const Index, s: *const std.StringHashMapUnmanaged(void), list: []const m.Paint) bool {
            for (list) |p| {
                if (p.variable) |v| if (in(x, s, v)) return true;
                if (bs(x, s, p.vars)) return true;
                for (p.stops) |st| if (st.variable) |v| if (in(x, s, v)) return true;
            }
            return false;
        }
    };
    if (S.bs(ix, set, n.vars)) return true;
    if (S.ps(ix, set, n.fills) or S.ps(ix, set, n.strokes)) return true;
    for (n.effects) |e| if (S.bs(ix, set, e.vars)) return true;
    for (n.grids) |g| if (S.bs(ix, set, g.vars)) return true;
    if (n.text) |t| {
        if (S.bs(ix, set, t.style.vars)) return true;
        for (t.runs) |r| {
            if (S.bs(ix, set, r.style.vars)) return true;
            if (r.fills) |fs| if (S.ps(ix, set, fs)) return true;
        }
    }
    return false;
}

/// Sets every field of `n` (not its children) that follows a variable to what the
/// variable is worth under `modes` (`n`'s own included). Never writes through memory
/// `n` shares: a changed list is built anew in `a`, so `n` may be a shallow copy.
/// Component property values (`props/<id>`) are left to the caller: setting one
/// changes the instance's layers. Answers what changed.
pub fn applyNode(ix: *const Index, scratch: Allocator, a: Allocator, n: *m.Node, modes: []const m.ModeChoice) !Changed {
    return applyNodeAt(ix, scratch, a, n, modes, 1);
}

/// `applyNode` for a node inside instances scaled as a whole by `scale` (the product of
/// their `scale`, the node's own included): lengths come out scaled, as the instance
/// shows its content.
pub fn applyNodeAt(ix: *const Index, scratch: Allocator, a: Allocator, n: *m.Node, modes: []const m.ModeChoice, scale: f32) !Changed {
    var ch: Changed = .{};
    for (n.vars) |b| {
        const r = ix.resolve(scratch, b.variable, modes) orelse continue;
        try nodeField(a, n, b.key, r, &ch, scale);
    }
    if (try paintsResolved(ix, scratch, a, n.fills, modes)) |ps| {
        n.fills = ps;
        ch.set("fills");
    }
    if (try paintsResolved(ix, scratch, a, n.strokes, modes)) |ps| {
        n.strokes = ps;
        ch.set("strokes");
    }
    if (try effectsResolved(ix, scratch, a, n.effects, modes, scale)) |es| {
        n.effects = es;
        ch.set("effects");
    }
    if (try gridsResolved(ix, scratch, a, n.grids, modes, scale)) |gs| {
        n.grids = gs;
        ch.set("grids");
    }
    if (n.text) |*t| {
        if (try styleResolved(ix, scratch, a, &t.style, modes, scale)) ch.set("style");
        var runs: ?[]m.Run = null;
        for (t.runs, 0..) |r, i| {
            var nr = r;
            var changed = try styleResolved(ix, scratch, a, &nr.style, modes, scale);
            if (changed) ch.runs_layout = true;
            if (r.fills) |fs| if (try paintsResolved(ix, scratch, a, fs, modes)) |ps| {
                nr.fills = ps;
                changed = true;
            };
            if (!changed) continue;
            if (runs == null) runs = try a.dupe(m.Run, t.runs);
            runs.?[i] = nr;
        }
        if (runs) |rs| {
            t.runs = rs;
            ch.set("runs");
        }
        // The text as its source laid it out no longer holds (a new paint leaves it as it
        // is).
        if ((ch.has("text") or ch.has("style") or ch.runs_layout) and (t.glyphs.len > 0 or t.glyph_rects.len > 0)) {
            t.glyphs = &.{};
            t.glyph_rects = &.{};
            ch.set("glyphs");
            ch.set("glyphRects");
        }
    }
    return ch;
}

fn num(r: Resolved) ?f32 {
    return switch (r) {
        .number => |x| if (std.math.isFinite(x)) x else null,
        else => null,
    };
}

fn same(a: f32, b: f32) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}

fn sameColor(a: m.Color, b: m.Color) bool {
    return same(a.r, b.r) and same(a.g, b.g) and same(a.b, b.b) and same(a.a, b.a);
}

fn setF(field: *f32, v: f32) bool {
    if (same(field.*, v)) return false;
    field.* = v;
    return true;
}

fn setOptF(field: *?f32, v: f32) bool {
    if (field.*) |x| if (same(x, v)) return false;
    field.* = v;
    return true;
}

/// Index `i` of a key `base/i` (`radius/2`), or null.
fn indexOf(key: []const u8, base: []const u8) ?usize {
    if (!std.mem.startsWith(u8, key, base) or key.len <= base.len + 1 or key[base.len] != '/') return null;
    return std.fmt.parseInt(usize, key[base.len + 1 ..], 10) catch null;
}

fn nodeField(a: Allocator, n: *m.Node, key: []const u8, r: Resolved, ch: *Changed, scale: f32) !void {
    const eql = std.mem.eql;
    if (eql(u8, key, "visible")) {
        const b = switch (r) {
            .boolean => |b| b,
            else => return,
        };
        if (n.visible != b) {
            n.visible = b;
            ch.set("visible");
        }
        return;
    }
    if (eql(u8, key, "text")) {
        const t = if (n.text) |*t| t else return;
        var buf: [64]u8 = undefined;
        const s: []const u8 = switch (r) {
            .string => |s| s,
            .number => |x| std.fmt.bufPrint(&buf, "{d}", .{x}) catch return,
            .boolean => |b| if (b) "true" else "false",
            .color => return,
        };
        if (!eql(u8, t.text, s)) {
            t.text = try a.dupe(u8, s);
            // Runs past the new end are cut.
            var runs: std.ArrayList(m.Run) = .empty;
            const len = utf16Len(t.text);
            for (t.runs) |run| {
                if (run.from >= len) continue;
                var x = run;
                x.to = @min(x.to, len);
                try runs.append(a, x);
            }
            t.runs = runs.items;
            ch.set("text");
            ch.set("runs");
        }
        return;
    }
    const raw = num(r) orelse return;
    // Everything below but opacity and counts is a length: scaled with the instance.
    const x = if (eql(u8, key, "opacity") or eql(u8, key, "count")) raw else raw * scale;
    if (eql(u8, key, "opacity")) {
        // Opacity variables are percentages.
        if (setF(&n.opacity, std.math.clamp(x / 100, 0, 1))) ch.set("opacity");
    } else if (eql(u8, key, "width")) {
        // A width that auto layout decides (fill, hug) is the layout's, as in Figma.
        if (!fixedAxis(n, .x)) return;
        if (setF(&n.size.x, @max(0, x))) ch.set("size");
    } else if (eql(u8, key, "height")) {
        if (!fixedAxis(n, .y)) return;
        if (setF(&n.size.y, @max(0, x))) ch.set("size");
    } else if (eql(u8, key, "minWidth")) {
        if (setOptF(&n.min_width, x)) ch.set("minWidth");
    } else if (eql(u8, key, "maxWidth")) {
        if (setOptF(&n.max_width, x)) ch.set("maxWidth");
    } else if (eql(u8, key, "minHeight")) {
        if (setOptF(&n.min_height, x)) ch.set("minHeight");
    } else if (eql(u8, key, "maxHeight")) {
        if (setOptF(&n.max_height, x)) ch.set("maxHeight");
    } else if (eql(u8, key, "radius")) {
        var any = false;
        for (&n.radius) |*c| any = setF(c, @max(0, x)) or any;
        if (any) ch.set("radius");
    } else if (indexOf(key, "radius")) |i| {
        if (i < 4 and setF(&n.radius[i], @max(0, x))) ch.set("radius");
    } else if (eql(u8, key, "stroke/weight")) {
        if (setF(&n.stroke.weight, @max(0, x))) ch.set("stroke");
    } else if (indexOf(key, "stroke/sides")) |i| {
        if (i >= 4) return;
        var sides = n.stroke.sides orelse .{ n.stroke.weight, n.stroke.weight, n.stroke.weight, n.stroke.weight };
        // Without sides of its own every side is the weight.
        if (same(sides[i], @max(0, x))) return;
        sides[i] = @max(0, x);
        n.stroke.sides = sides;
        ch.set("stroke");
    } else if (eql(u8, key, "gap")) {
        if (n.layout) |*l| if (setF(&l.gap, x)) ch.set("layout");
    } else if (eql(u8, key, "crossGap")) {
        if (n.layout) |*l| if (setF(&l.cross_gap, x)) ch.set("layout");
    } else if (indexOf(key, "padding")) |i| {
        if (i < 4) if (n.layout) |*l| if (setF(&l.padding[i], x)) ch.set("layout");
    } else if (eql(u8, key, "x")) {
        if (setF(&n.transform.e, x)) ch.set("transform");
    } else if (eql(u8, key, "y")) {
        if (setF(&n.transform.f, x)) ch.set("transform");
    } else if (eql(u8, key, "count")) {
        const c: u32 = @intFromFloat(std.math.clamp(@round(x), 0, 1e6));
        if (n.count != c) {
            n.count = c;
            ch.set("count");
        }
    }
}

/// Whether the node's size along an axis is its own (not filled, hugged or text-fitted).
fn fixedAxis(n: *const m.Node, axis: enum { x, y }) bool {
    if (n.sizing) |sz| if ((if (axis == .x) sz.w else sz.h) != .fixed) return false;
    if (n.layout) |l| if ((if (axis == .x) l.width else l.height) == .hug) return false;
    if (n.text) |t| switch (t.resize) {
        .width_and_height => return false,
        .height => if (axis == .y) return false,
        else => {},
    };
    return true;
}

fn utf16Len(s: []const u8) u32 {
    var n: u32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| n += if (cp >= 0x10000) 2 else 1;
    return n;
}

/// The paints with their bound fields resolved, or null when nothing changes.
fn paintsResolved(ix: *const Index, scratch: Allocator, a: Allocator, ps: []const m.Paint, modes: []const m.ModeChoice) !?[]m.Paint {
    if (!paintsBound(ps)) return null;
    var out: ?[]m.Paint = null;
    for (ps, 0..) |p, i| {
        var np = p;
        var changed = false;
        if (p.variable) |ref| if (ix.resolve(scratch, ref, modes)) |r| if (r == .color) {
            if (!sameColor(np.color, r.color.c)) {
                np.color = r.color.c;
                changed = true;
            }
            if (r.color.opacity) |op| if (!same(np.opacity, op)) {
                np.opacity = op;
                changed = true;
            };
        };
        for (p.vars) |b| {
            const r = ix.resolve(scratch, b.variable, modes) orelse continue;
            if (std.mem.eql(u8, b.key, "opacity")) if (num(r)) |x| {
                if (setF(&np.opacity, std.math.clamp(x / 100, 0, 1))) changed = true;
            };
        }
        var stops: ?[]m.Stop = null;
        for (p.stops, 0..) |s, k| {
            const ref = s.variable orelse continue;
            const r = ix.resolve(scratch, ref, modes) orelse continue;
            if (r != .color) continue;
            var c = r.color.c;
            if (r.color.opacity) |op| c.a *= op;
            if (sameColor(s.color, c)) continue;
            if (stops == null) stops = try a.dupe(m.Stop, p.stops);
            stops.?[k].color = c;
        }
        if (stops) |ss| {
            np.stops = ss;
            changed = true;
        }
        if (!changed) continue;
        if (out == null) out = try a.dupe(m.Paint, ps);
        out.?[i] = np;
    }
    return out;
}

fn effectsResolved(ix: *const Index, scratch: Allocator, a: Allocator, es: []const m.Effect, modes: []const m.ModeChoice, scale: f32) !?[]m.Effect {
    var out: ?[]m.Effect = null;
    for (es, 0..) |e, i| {
        if (e.vars.len == 0) continue;
        var ne = e;
        var changed = false;
        for (e.vars) |b| {
            const r = ix.resolve(scratch, b.variable, modes) orelse continue;
            const key = b.key;
            const eql = std.mem.eql;
            if (eql(u8, key, "color") or eql(u8, key, "secondary")) {
                if (r != .color) continue;
                var c = r.color.c;
                if (r.color.opacity) |op| c.a *= op;
                const field = if (eql(u8, key, "color")) &ne.color else &ne.secondary;
                if (!sameColor(field.*, c)) {
                    field.* = c;
                    changed = true;
                }
                continue;
            }
            const x = (num(r) orelse continue) * scale;
            const field: ?*f32 = if (eql(u8, key, "radius")) &ne.radius else if (eql(u8, key, "spread")) &ne.spread else if (eql(u8, key, "offset/0")) &ne.offset.x else if (eql(u8, key, "offset/1")) &ne.offset.y else if (eql(u8, key, "grain/0")) &ne.grain.x else if (eql(u8, key, "grain/1")) &ne.grain.y else null;
            if (field) |f| if (setF(f, x)) {
                changed = true;
            };
        }
        if (!changed) continue;
        if (out == null) out = try a.dupe(m.Effect, es);
        out.?[i] = ne;
    }
    return out;
}

fn gridsResolved(ix: *const Index, scratch: Allocator, a: Allocator, gs: []const m.Grid, modes: []const m.ModeChoice, scale: f32) !?[]m.Grid {
    var out: ?[]m.Grid = null;
    for (gs, 0..) |g, i| {
        if (g.vars.len == 0) continue;
        var ng = g;
        var changed = false;
        for (g.vars) |b| {
            const r = ix.resolve(scratch, b.variable, modes) orelse continue;
            const raw = num(r) orelse continue;
            const x = raw * scale;
            const eql = std.mem.eql;
            if (eql(u8, b.key, "count")) {
                const c: u32 = @intFromFloat(std.math.clamp(@round(raw), 0, 1e6));
                if (ng.count != c) {
                    ng.count = c;
                    changed = true;
                }
            } else if (eql(u8, b.key, "gutter")) {
                changed = setF(&ng.gutter, x) or changed;
            } else if (eql(u8, b.key, "offset")) {
                changed = setF(&ng.offset, x) or changed;
            } else if (eql(u8, b.key, "size")) {
                // A stretched grid's column size follows from the frame's.
                if (ng.@"align" != .stretch) changed = setF(&ng.size, x) or changed;
            }
        }
        if (!changed) continue;
        if (out == null) out = try a.dupe(m.Grid, gs);
        out.?[i] = ng;
    }
    return out;
}

/// Resolves a text style's bound fields in place (it is a value, not shared); answers
/// whether any changed.
fn styleResolved(ix: *const Index, scratch: Allocator, a: Allocator, st: *m.TextStyle, modes: []const m.ModeChoice, scale: f32) !bool {
    var changed = false;
    const eql = std.mem.eql;
    for (st.vars) |b| {
        const r = ix.resolve(scratch, b.variable, modes) orelse continue;
        const key = b.key;
        if (eql(u8, key, "family") or eql(u8, key, "fontStyle")) {
            const s = switch (r) {
                .string => |s| s,
                else => continue,
            };
            const field = if (eql(u8, key, "family")) &st.family else &st.font_style;
            // Font names match as fonts do: case and spacing aside ("SemiBold" is
            // "Semibold").
            if (field.*) |old| if (sameFontName(old, s)) continue;
            field.* = try a.dupe(u8, s);
            if (eql(u8, key, "fontStyle")) {
                st.weight = m.weightOfStyle(s);
                st.italic = std.ascii.indexOfIgnoreCase(s, "italic") != null or std.ascii.indexOfIgnoreCase(s, "oblique") != null;
            }
            changed = true;
            continue;
        }
        const raw = num(r) orelse continue;
        // A text inside an instance scaled as a whole keeps its own sizes (Figma scales
        // its layout, not its style).
        _ = scale;
        const x = raw;
        if (eql(u8, key, "weight")) {
            const w: u16 = @intFromFloat(std.math.clamp(@round(raw), 1, 1000));
            if (st.weight == null or st.weight.? != w) {
                st.weight = w;
                changed = true;
            }
        } else if (eql(u8, key, "size")) {
            changed = setOptF(&st.size, x) or changed;
        } else if (eql(u8, key, "lineHeight")) {
            // Line height variables are pixels.
            if (st.line_height) |lh| if (lh == .px and same(lh.px, x)) continue;
            st.line_height = .{
                .px = x,
            };
            changed = true;
        } else if (eql(u8, key, "letterSpacing")) {
            // So are letter spacing ones.
            if (st.letter_spacing) |ls| if (ls == .px and same(ls.px, x)) continue;
            st.letter_spacing = .{
                .px = x,
            };
            changed = true;
        } else if (eql(u8, key, "paragraphSpacing")) {
            changed = setOptF(&st.paragraph_spacing, x) or changed;
        } else if (eql(u8, key, "paragraphIndent")) {
            changed = setOptF(&st.paragraph_indent, x) or changed;
        }
    }
    return changed;
}

/// The node key (Pubd) of the field a node binding drives: `width` and `height` are
/// `size`, `radius/2` is `radius`, `padding/1` and `gap` are `layout`, ...
pub fn nodeKeyOf(binding: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, binding, "width") or eql(u8, binding, "height")) return "size";
    if (eql(u8, binding, "x") or eql(u8, binding, "y")) return "transform";
    if (eql(u8, binding, "gap") or eql(u8, binding, "crossGap") or std.mem.startsWith(u8, binding, "padding/")) return "layout";
    if (std.mem.startsWith(u8, binding, "radius")) return "radius";
    if (std.mem.startsWith(u8, binding, "stroke/")) return "stroke";
    if (std.mem.startsWith(u8, binding, "props/")) return "props";
    return binding;
}

/// Which binding lists `pruneStale` changed.
pub const Pruned = struct {
    vars: bool = false,
    fills: bool = false,
    strokes: bool = false,
    effects: bool = false,
    grids: bool = false,
    style: bool = false,
    runs: bool = false,

    pub fn any(p: Pruned) bool {
        return p.vars or p.fills or p.strokes or p.effects or p.grids or p.style or p.runs;
    }
};

/// Drops the bindings of `n` whose field holds a value its variable (under `modes`) does
/// not give it, among the fields of the node keys `keys` names: a value set by hand
/// detaches the variable, as in Figma. A binding to a variable not in the document
/// stays. Lists are built anew in `a`.
pub fn pruneStale(ix: *const Index, scratch: Allocator, a: Allocator, n: *m.Node, modes: []const m.ModeChoice, scale: f32, keys: []const []const u8) !Pruned {
    var out: Pruned = .{};
    const named = struct {
        fn f(list: []const []const u8, k: []const u8) bool {
            for (list) |x| if (std.mem.eql(u8, x, k)) return true;
            return false;
        }
    }.f;
    // The node's own.
    if (n.vars.len > 0) {
        var kept: std.ArrayList(m.VarBinding) = .empty;
        for (n.vars) |b| {
            const nk = nodeKeyOf(b.key);
            if (named(keys, nk) and !std.mem.eql(u8, nk, "props")) if (ix.resolve(scratch, b.variable, modes)) |r| {
                var probe = n.*;
                var ch: Changed = .{};
                try nodeField(scratch, &probe, b.key, r, &ch, scale);
                if (ch.any()) continue;
            };
            try kept.append(a, b);
        }
        if (kept.items.len != n.vars.len) {
            n.vars = kept.items;
            out.vars = true;
        }
    }
    if (named(keys, "fills")) if (try prunePaints(ix, scratch, a, n.fills, modes)) |ps| {
        n.fills = ps;
        out.fills = true;
    };
    if (named(keys, "strokes")) if (try prunePaints(ix, scratch, a, n.strokes, modes)) |ps| {
        n.strokes = ps;
        out.strokes = true;
    };
    if (named(keys, "effects")) {
        var list: ?[]m.Effect = null;
        for (n.effects, 0..) |e, i| {
            var kept: std.ArrayList(m.VarBinding) = .empty;
            for (e.vars) |b| {
                var probe = e;
                probe.vars = @constCast(&[_]m.VarBinding{b});
                if ((try effectsResolved(ix, scratch, scratch, (&probe)[0..1], modes, scale)) != null) continue;
                try kept.append(a, b);
            }
            if (kept.items.len == e.vars.len) continue;
            if (list == null) list = try a.dupe(m.Effect, n.effects);
            list.?[i].vars = kept.items;
        }
        if (list) |l| {
            n.effects = l;
            out.effects = true;
        }
    }
    if (named(keys, "grids")) {
        var list: ?[]m.Grid = null;
        for (n.grids, 0..) |g, i| {
            var kept: std.ArrayList(m.VarBinding) = .empty;
            for (g.vars) |b| {
                var probe = g;
                probe.vars = @constCast(&[_]m.VarBinding{b});
                if ((try gridsResolved(ix, scratch, scratch, (&probe)[0..1], modes, scale)) != null) continue;
                try kept.append(a, b);
            }
            if (kept.items.len == g.vars.len) continue;
            if (list == null) list = try a.dupe(m.Grid, n.grids);
            list.?[i].vars = kept.items;
        }
        if (list) |l| {
            n.grids = l;
            out.grids = true;
        }
    }
    if (n.text) |*t| {
        if (named(keys, "style")) if (try pruneStyle(ix, scratch, a, &t.style, modes, scale)) {
            out.style = true;
        };
        if (named(keys, "runs")) {
            var runs: ?[]m.Run = null;
            for (t.runs, 0..) |r, i| {
                var nr = r;
                var changed = try pruneStyle(ix, scratch, a, &nr.style, modes, scale);
                if (r.fills) |fs| if (try prunePaints(ix, scratch, a, fs, modes)) |ps| {
                    nr.fills = ps;
                    changed = true;
                };
                if (!changed) continue;
                if (runs == null) runs = try a.dupe(m.Run, t.runs);
                runs.?[i] = nr;
            }
            if (runs) |rs| {
                t.runs = rs;
                out.runs = true;
            }
        }
    }
    return out;
}

fn pruneStyle(ix: *const Index, scratch: Allocator, a: Allocator, st: *m.TextStyle, modes: []const m.ModeChoice, scale: f32) !bool {
    if (st.vars.len == 0) return false;
    var kept: std.ArrayList(m.VarBinding) = .empty;
    for (st.vars) |b| {
        var probe = st.*;
        probe.vars = @constCast(&[_]m.VarBinding{b});
        if (try styleResolved(ix, scratch, scratch, &probe, modes, scale)) continue;
        try kept.append(a, b);
    }
    if (kept.items.len == st.vars.len) return false;
    st.vars = kept.items;
    return true;
}

fn prunePaints(ix: *const Index, scratch: Allocator, a: Allocator, ps: []const m.Paint, modes: []const m.ModeChoice) !?[]m.Paint {
    var out: ?[]m.Paint = null;
    for (ps, 0..) |p, i| {
        var np = p;
        var changed = false;
        if (p.variable) |ref| {
            var probe = p;
            probe.vars = &.{};
            probe.stops = &.{};
            if ((try paintsResolved(ix, scratch, scratch, (&probe)[0..1], modes)) != null) {
                np.variable = null;
                changed = true;
            }
            _ = ref;
        }
        if (p.vars.len > 0) {
            var kept: std.ArrayList(m.VarBinding) = .empty;
            for (p.vars) |b| {
                var probe = p;
                probe.variable = null;
                probe.stops = &.{};
                probe.vars = @constCast(&[_]m.VarBinding{b});
                if ((try paintsResolved(ix, scratch, scratch, (&probe)[0..1], modes)) != null) continue;
                try kept.append(a, b);
            }
            if (kept.items.len != p.vars.len) {
                np.vars = kept.items;
                changed = true;
            }
        }
        var stops: ?[]m.Stop = null;
        for (p.stops, 0..) |st, k| {
            if (st.variable == null) continue;
            var probe = p;
            probe.variable = null;
            probe.vars = &.{};
            probe.stops = @constCast(&[_]m.Stop{st});
            if ((try paintsResolved(ix, scratch, scratch, (&probe)[0..1], modes)) == null) continue;
            if (stops == null) stops = try a.dupe(m.Stop, p.stops);
            stops.?[k].variable = null;
        }
        if (stops) |ss| {
            np.stops = ss;
            changed = true;
        }
        if (!changed) continue;
        if (out == null) out = try a.dupe(m.Paint, ps);
        out.?[i] = np;
    }
    return out;
}

fn sameFontName(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and (a[i] == ' ' or a[i] == '-' or a[i] == '_')) i += 1;
        while (j < b.len and (b[j] == ' ' or b[j] == '-' or b[j] == '_')) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

/// Resolves every bound field under `n` (itself included), in the modes `stack` holds
/// (innermost last; each node's own are pushed on the way down and taken off after).
/// Lists are built anew in `a` where they change. Answers how many nodes changed.
pub fn resolveTree(ix: *const Index, gpa: Allocator, a: Allocator, n: *m.Node, stack: *std.ArrayList(m.ModeChoice)) !u32 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    return walk(ix, gpa, &scratch, a, n, stack, 1);
}

/// The scale a node's content shows at: the product of the `scale` of the instances
/// scaled as a whole it is in (itself included).
pub fn scaleOf(n: *const m.Node, outer: f32) f32 {
    return if (n.kind == .instance and n.scale != 1 and n.scale > 0) outer * n.scale else outer;
}

/// `scaleOf` along a path, root first.
pub fn scaleAlong(path: []const *const m.Node) f32 {
    var s: f32 = 1;
    for (path) |p| s = scaleOf(p, s);
    return s;
}

fn walk(ix: *const Index, gpa: Allocator, scratch: *std.heap.ArenaAllocator, a: Allocator, n: *m.Node, stack: *std.ArrayList(m.ModeChoice), outer: f32) !u32 {
    const before = stack.items.len;
    defer stack.shrinkRetainingCapacity(before);
    try stack.appendSlice(gpa, n.modes);
    const scale = scaleOf(n, outer);
    var count: u32 = 0;
    if (hasBindings(n)) {
        _ = scratch.reset(.retain_capacity);
        const ch = try applyNodeAt(ix, scratch.allocator(), a, n, stack.items, scale);
        if (ch.any()) count += 1;
    }
    for (n.children) |*c| count += try walk(ix, gpa, scratch, a, c, stack, scale);
    return count;
}

/// Resolves page `page` of `doc` (lists built anew in `a`, the page's memory): what a
/// reader does with each page it reads. Answers how many nodes changed.
pub fn resolvePage(gpa: Allocator, doc: *const m.Document, a: Allocator, page: *m.Node) !u32 {
    if (doc.variables.len == 0) return 0;
    var ix = try Index.init(gpa, doc);
    defer ix.deinit(gpa);
    var stack: std.ArrayList(m.ModeChoice) = .empty;
    defer stack.deinit(gpa);
    return resolveTree(&ix, gpa, a, page, &stack);
}

/// Resolves every page of `doc` and the nodes pages share, in the document's memory.
pub fn resolveDocument(gpa: Allocator, doc: *m.Document) !u32 {
    if (doc.variables.len == 0) return 0;
    var ix = try Index.init(gpa, doc);
    defer ix.deinit(gpa);
    var stack: std.ArrayList(m.ModeChoice) = .empty;
    defer stack.deinit(gpa);
    const a = doc.arena.allocator();
    var count: u32 = 0;
    for (doc.pages) |*pg| count += try resolveTree(&ix, gpa, a, pg, &stack);
    for (doc.shared) |*n| count += try resolveTree(&ix, gpa, a, n, &stack);
    return count;
}

/// The modes in force at the end of `path` (root first): every node's own, in order.
pub fn modesAlong(a: Allocator, path: []const *const m.Node) ![]m.ModeChoice {
    var list: std.ArrayList(m.ModeChoice) = .empty;
    for (path) |p| try list.appendSlice(a, p.modes);
    return list.items;
}

/// A resolved value as Pubd JSON (a colour, number, string or boolean; a composed
/// colour as `{"color":C,"opacity":o}`), owned by `a`.
pub fn resolvedJson(a: Allocator, r: Resolved) ![]u8 {
    const write = @import("write.zig");
    return switch (r) {
        .color => |c| if (c.opacity) |op| std.fmt.allocPrint(a, "{{\"color\":{s},\"opacity\":{d}}}", .{ try write.colorJson(a, c.c), op }) else write.colorJson(a, c.c),
        .number => |x| std.fmt.allocPrint(a, "{d}", .{x}),
        .string => |s| std.json.Stringify.valueAlloc(a, s, .{}),
        .boolean => |b| a.dupe(u8, if (b) "true" else "false"),
    };
}

test "aliases resolve across collections in each collection's own mode" {
    const gpa = std.testing.allocator;
    var doc = try read.fromJson(
        gpa,
        \\{"pubd":2,"name":"t","pages":[],
        \\ "collections":{
        \\   "C:1":{"name":"Primitives","modes":[{"id":"p","name":"Value"}]},
        \\   "C:2":{"name":"Theme","modes":[{"id":"light","name":"Light"},{"id":"dark","name":"Dark"}]},
        \\   "C:3":{"name":"Brand B","modes":[{"id":"b-light","name":"Light","parent":"light"}],"parent":"C:2",
        \\          "overrides":{"V:3":{"b-light":{"alias":"V:2"}}}}},
        \\ "variables":{
        \\   "V:1":{"name":"white","collection":"C:1","type":"color","values":{"p":"#ffffff"}},
        \\   "V:2":{"name":"black","collection":"C:1","type":"color","values":{"p":"#000000"}},
        \\   "V:3":{"name":"bg","collection":"C:2","type":"color","values":{"light":{"alias":"V:1"},"dark":{"alias":"V:2"}}},
        \\   "V:4":{"name":"half","collection":"C:1","type":"number","values":{"p":50}},
        \\   "V:5":{"name":"veil","collection":"C:2","type":"color","values":{"light":{"compose":{"color":{"alias":"V:3"},"opacity":{"alias":"V:4"}}},"dark":"#ff0000"}},
        \\   "V:6":{"name":"loop","collection":"C:1","type":"number","values":{"p":{"alias":"V:6"}}}}}
    ,
        .{},
    );
    defer doc.deinit();
    var ix = try Index.init(gpa, &doc);
    defer ix.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Default mode: light.
    const light = ix.resolve(a, "V:3", &.{}).?;
    try std.testing.expectEqual(@as(f32, 1), light.color.c.r);
    const dark_modes = [_]m.ModeChoice{.{
        .collection = "C:2",
        .mode = "dark",
    }};
    try std.testing.expectEqual(@as(f32, 0), ix.resolve(a, "V:3", &dark_modes).?.color.c.r);
    // The innermost choice wins.
    const both = [_]m.ModeChoice{ dark_modes[0], .{
        .collection = "C:2",
        .mode = "light",
    } };
    try std.testing.expectEqual(@as(f32, 1), ix.resolve(a, "V:3", &both).?.color.c.r);
    // An extended collection's mode overrides its parent's value.
    const ext = [_]m.ModeChoice{.{
        .collection = "C:3",
        .mode = "b-light",
    }};
    try std.testing.expectEqual(@as(f32, 0), ix.resolve(a, "V:3", &ext).?.color.c.r);
    // A composed colour: its colour and its opacity from a number (percent).
    const veil = ix.resolve(a, "V:5", &.{}).?;
    try std.testing.expectEqual(@as(f32, 1), veil.color.c.g);
    try std.testing.expectEqual(@as(f32, 0.5), veil.color.opacity.?);
    // A loop resolves to nothing.
    try std.testing.expect(ix.resolve(a, "V:6", &.{}) == null);
    // Dependents follow aliases and compositions.
    var deps = try ix.dependents(gpa, &.{"V:1"});
    defer deps.deinit(gpa);
    try std.testing.expect(deps.contains("V:3") and deps.contains("V:5") and !deps.contains("V:2"));
}

test "bound fields take their variables' values in the node's modes" {
    const gpa = std.testing.allocator;
    var doc = try read.fromJson(
        gpa,
        \\{"pubd":2,"name":"t","pages":[{"id":"0:1","type":"page","children":[
        \\  {"id":"1:1","type":"frame","size":[100,100],"modes":{"C:1":"dark"},
        \\   "layout":{"mode":"vertical","gap":4},"vars":{"gap":"V:2","padding/1":"V:2"},
        \\   "children":[
        \\    {"id":"1:2","type":"rectangle","size":[10,10],"opacity":1,"vars":{"opacity":"V:3","radius":"V:2"},
        \\     "fills":[{"type":"solid","color":"#ffffff","var":"V:1"}],
        \\     "effects":[{"type":"drop-shadow","color":"#000000","offset":[0,0],"radius":1,"vars":{"radius":"V:2","color":"V:1"}}]},
        \\    {"id":"1:3","type":"text","size":[10,10],"text":"x","style":{"family":"Inter","size":12,"vars":{"size":"V:2"}},"vars":{"text":"V:4"}}]}]}],
        \\ "collections":{"C:1":{"name":"Theme","modes":[{"id":"light","name":"Light"},{"id":"dark","name":"Dark"}]}},
        \\ "variables":{
        \\   "V:1":{"name":"fg","collection":"C:1","type":"color","values":{"light":"#ffffff","dark":"#102030"}},
        \\   "V:2":{"name":"space","collection":"C:1","type":"number","values":{"light":8,"dark":16}},
        \\   "V:3":{"name":"fade","collection":"C:1","type":"number","values":{"light":100,"dark":40}},
        \\   "V:4":{"name":"label","collection":"C:1","type":"string","values":{"light":"Light","dark":"Dark"}}}}
    ,
        .{},
    );
    defer doc.deinit();
    var ix = try Index.init(gpa, &doc);
    defer ix.deinit(gpa);
    var stack: std.ArrayList(m.ModeChoice) = .empty;
    defer stack.deinit(gpa);
    const changed = try resolveTree(&ix, gpa, doc.arena.allocator(), &doc.pages[0], &stack);
    try std.testing.expectEqual(@as(u32, 3), changed);
    const f = &doc.pages[0].children[0];
    try std.testing.expectEqual(@as(f32, 16), f.layout.?.gap);
    try std.testing.expectEqual(@as(f32, 16), f.layout.?.padding[1]);
    const r = &f.children[0];
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), r.opacity, 1e-6);
    try std.testing.expectEqual(@as(f32, 16), r.radius[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0x10) / 255.0, r.fills[0].color.r, 1e-6);
    try std.testing.expectEqual(@as(f32, 16), r.effects[0].radius);
    const t = &f.children[1];
    try std.testing.expectEqualStrings("Dark", t.text.?.text);
    try std.testing.expectEqual(@as(f32, 16), t.text.?.style.size.?);
    // Resolved already: nothing changes the second time.
    try std.testing.expectEqual(@as(u32, 0), try resolveTree(&ix, gpa, doc.arena.allocator(), &doc.pages[0], &stack));
}
