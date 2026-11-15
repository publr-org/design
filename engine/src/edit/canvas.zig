//! What the canvas's tools ask of the open document (`.agents/specs/publr-design-editing.md`
//! "Editing on the canvas"): where nodes are on their page and what they sit in, the
//! frame a drag drops into, and the changes a resize makes inside the resized node
//! (children following their constraints, a vector's path, geometry and stroke outline
//! rescaled, and with the scale tool strokes, effects, corner radii and text too).
//!
//! Reads only: the tools apply what `resizePlan` answers through the editor, so it is one
//! step with everything else the drag did.

const std = @import("std");
const m = @import("../pubd/model.zig");
const geom = @import("../raster/geom.zig");
const lay = @import("../layout/layout.zig");
const props = @import("props.zig");
const write = @import("../pubd/write.zig");
const Session = @import("../session.zig").Session;

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Affine = geom.Affine;
const Vec2 = geom.Vec2;

fn writeAffine(w: *Stringify, t: Affine) !void {
    try w.write([6]f32{ t.a, t.b, t.c, t.d, t.e, t.f });
}

fn kindName(k: m.Kind) []const u8 {
    return switch (k) {
        .component_set => "component-set",
        else => @tagName(k),
    };
}

/// An enum's name as Pubd spells it (`width-and-height`).
fn dashed(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "width_and_height")) return "width-and-height";
    if (std.mem.eql(u8, name, "left_right")) return "left-right";
    if (std.mem.eql(u8, name, "top_bottom")) return "top-bottom";
    return name;
}

fn findPage(s: *Session, id: []const u8) ?*m.Node {
    for (s.pages()) |*pg| if (std.mem.eql(u8, pg.id, id)) return @constCast(pg);
    return null;
}

/// A node or a page by id.
fn nodeOrPage(s: *Session, id: []const u8) ?*m.Node {
    return s.edit.node(id) orelse findPage(s, id);
}

/// The node's space to its page's.
fn pageCtm(s: *Session, id: []const u8) Affine {
    var t: Affine = .identity;
    var cur = id;
    while (s.edit.parents.get(cur)) |p| {
        if (p.len == 0) break;
        const n = s.edit.node(cur) orelse break;
        t = n.transform.mul(t);
        cur = p;
    }
    return t;
}

fn writeLayout(w: *Stringify, l: m.Layout) !void {
    try w.beginObject();
    try w.objectField("mode");
    try w.write(@tagName(l.mode));
    try w.objectField("wrap");
    try w.write(l.wrap);
    try w.objectField("gap");
    try w.write(l.gap);
    try w.objectField("padding");
    try w.write(l.padding);
    try w.objectField("width");
    try w.write(@tagName(l.width));
    try w.objectField("height");
    try w.write(@tagName(l.height));
    try w.endObject();
}

/// Nodes `ids` (a JSON array) as the tools need them, in order (null for an id not
/// found): kind, name, parent and the ancestors from the top-level one down, page, the
/// node's and its parent's transforms to the page (`ctm`, `pctm`), size, whether it is
/// visible and locked (or an ancestor is), inside an instance, its parent's auto layout
/// and its own, how it sizes there, and for text how it resizes and aligns.
pub fn nodesJson(s: *Session, gpa: Allocator, ids_json: []const u8) ![]u8 {
    try s.edit.ensureIndexed();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, ids_json, .{});
    if (v != .array) return error.BadIds;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var w: Stringify = .{
        .writer = &out.writer,
    };
    try w.beginArray();
    for (v.array.items) |iv| {
        const n = if (iv == .string) s.edit.node(iv.string) else null;
        if (n) |node| try writeNode(s, a, &w, node) else try w.write(null);
    }
    try w.endArray();
    return out.toOwnedSlice();
}

fn writeNode(s: *Session, a: Allocator, w: *Stringify, n: *const m.Node) !void {
    const pid = s.edit.parents.get(n.id) orelse "";
    const parent = nodeOrPage(s, pid);
    // The ancestors, the top-level one first (the page left out).
    var path: std.ArrayList([]const u8) = .empty;
    var hidden = !n.visible;
    var locked = n.locked;
    var in_instance = false;
    var cur = pid;
    while (s.edit.parents.get(cur)) |p| {
        if (p.len == 0) break;
        const x = s.edit.node(cur) orelse break;
        try path.append(a, x.id);
        hidden = hidden or !x.visible;
        locked = locked or x.locked;
        in_instance = in_instance or x.kind == .instance;
        cur = p;
    }
    std.mem.reverse([]const u8, path.items);
    const ctm = pageCtm(s, n.id);
    const pctm = if (pid.len > 0) pageCtm(s, pid) else Affine.identity;
    try w.beginObject();
    try w.objectField("id");
    try w.write(n.id);
    try w.objectField("type");
    try w.write(kindName(n.kind));
    try w.objectField("name");
    try w.write(n.name);
    try w.objectField("parent");
    try w.write(pid);
    try w.objectField("ptype");
    try w.write(if (parent) |p| kindName(p.kind) else "");
    try w.objectField("path");
    try w.write(path.items);
    try w.objectField("page");
    try w.write(s.edit.pageOf(n.id));
    try w.objectField("ctm");
    try writeAffine(w, ctm);
    try w.objectField("pctm");
    try writeAffine(w, pctm);
    try w.objectField("transform");
    try writeAffine(w, n.transform);
    try w.objectField("size");
    try w.write([2]f32{ n.size.x, n.size.y });
    try w.objectField("visible");
    try w.write(!hidden);
    try w.objectField("locked");
    try w.write(locked);
    try w.objectField("inInstance");
    try w.write(in_instance);
    try w.objectField("children");
    try w.write(n.children.len);
    try w.objectField("playout");
    if (parent) |p| if (p.layout != null and p.kind.isContainer()) try writeLayout(w, p.layout.?) else try w.write(null) else try w.write(null);
    try w.objectField("layout");
    if (n.layout != null and n.kind.isContainer()) try writeLayout(w, n.layout.?) else try w.write(null);
    try w.objectField("absolute");
    try w.write(n.absolute);
    try w.objectField("sizing");
    const sz = n.sizing orelse m.Sizing{};
    try w.write([2][]const u8{ @tagName(sz.w), @tagName(sz.h) });
    try w.objectField("constraints");
    try w.write([2][]const u8{ dashed(@tagName(n.constraints.h)), dashed(@tagName(n.constraints.v)) });
    if (n.text) |t| {
        try w.objectField("resize");
        try w.write(dashed(@tagName(t.resize)));
        try w.objectField("align");
        try w.write(@tagName(t.@"align"));
        try w.objectField("valign");
        try w.write(@tagName(t.valign));
    }
    try w.endObject();
}

/// Node (or page) `id`'s children as the tools snap to them and reorder them: each one's
/// transform to the page, size and kind, in the parent's order (the first is the
/// bottom-most, and the first in an auto layout's flow); with the parent's own.
pub fn childrenJson(s: *Session, gpa: Allocator, id: []const u8) ![]u8 {
    try s.edit.ensureIndexed();
    const p = nodeOrPage(s, id) orelse return error.NoSuchNode;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var w: Stringify = .{
        .writer = &out.writer,
    };
    const pctm = if (p.kind == .page) Affine.identity else pageCtm(s, p.id);
    try w.beginObject();
    try w.objectField("id");
    try w.write(p.id);
    try w.objectField("type");
    try w.write(kindName(p.kind));
    try w.objectField("ctm");
    try writeAffine(&w, pctm);
    try w.objectField("size");
    try w.write([2]f32{ p.size.x, p.size.y });
    try w.objectField("layout");
    if (p.layout != null and p.kind.isContainer()) try writeLayout(&w, p.layout.?) else try w.write(null);
    try w.objectField("children");
    try w.beginArray();
    for (p.children) |*c| {
        try w.beginObject();
        try w.objectField("id");
        try w.write(c.id);
        try w.objectField("type");
        try w.write(kindName(c.kind));
        try w.objectField("ctm");
        try writeAffine(&w, pctm.mul(c.transform));
        try w.objectField("size");
        try w.write([2]f32{ c.size.x, c.size.y });
        try w.objectField("visible");
        try w.write(c.visible);
        try w.objectField("locked");
        try w.write(c.locked);
        try w.objectField("absolute");
        try w.write(c.absolute);
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
    return out.toOwnedSlice();
}

/// The frame a drag dropping at page point (`x`, `y`) on page `page` puts layers in: the
/// deepest visible, unlocked frame, component or component set under the point (the
/// top-most where they overlap; what a clipping frame hides does not count), never one
/// of `exclude` (a JSON array of ids) or inside one, nor an instance or inside one. The
/// page when there is none. Answers `{"id", "page": bool}`.
pub fn dropJson(s: *Session, gpa: Allocator, page: u32, x: f32, y: f32, exclude_json: []const u8) ![]u8 {
    try s.edit.ensureIndexed();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var skip: std.StringHashMapUnmanaged(void) = .empty;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, exclude_json, .{});
    if (v == .array) for (v.array.items) |e| if (e == .string) try skip.put(a, e.string, {});
    const pages = s.pages();
    if (page >= pages.len) return error.NoSuchPage;
    const pg = &pages[page];
    const at: Vec2 = .{
        .x = x,
        .y = y,
    };
    const found = dropIn(pg.children, .identity, at, &skip);
    return std.json.Stringify.valueAlloc(gpa, .{
        .id = if (found) |f| f.id else pg.id,
        .page = found == null,
    }, .{});
}

fn inside(ctm: Affine, size: Vec2, p: Vec2) bool {
    const inv = ctm.invert() orelse return false;
    const q = inv.apply(p);
    return q.x >= 0 and q.y >= 0 and q.x <= size.x and q.y <= size.y;
}

fn dropIn(children: []const m.Node, pctm: Affine, p: Vec2, skip: *const std.StringHashMapUnmanaged(void)) ?*const m.Node {
    var k = children.len;
    while (k > 0) {
        k -= 1;
        const c = &children[k];
        if (!c.visible or c.locked or skip.contains(c.id)) continue;
        const ctm = pctm.mul(c.transform);
        switch (c.kind) {
            .frame, .component, .component_set => {
                const in = inside(ctm, c.size, p);
                if (c.clip and !in) continue;
                if (dropIn(c.children, ctm, p, skip)) |d| return d;
                if (in) return c;
            },
            .group => if (dropIn(c.children, ctm, p, skip)) |d| return d,
            else => {},
        }
    }
    return null;
}

/// Node `id` with its whole subtree as Pubd JSON (what a duplicate inserts, with new ids).
pub fn subtreeJson(s: *Session, gpa: Allocator, id: []const u8) ![]u8 {
    const n = s.edit.node(id) orelse return error.NoSuchNode;
    return write.nodeJson(gpa, n, .{});
}

// ------------------------------------------------------------------ resizing

/// The changes that resize node `id` to `w` x `h` (its own transform is the caller's): its
/// size; children placed by their constraints (a group's and a boolean's children scale
/// with it), each resized child's own inside again; a vector's network, geometry and
/// stroke outline rescaled. With `scale` (the scale tool) everything inside scales by
/// the same factor instead, and strokes, effects, corner radii, auto layout spacing and
/// text sizes with it. A JSON array of `set` changes.
pub fn resizePlan(s: *Session, gpa: Allocator, id: []const u8, w: f32, h: f32, scale: bool) ![]u8 {
    try s.edit.ensureIndexed();
    const n = s.edit.node(id) orelse return error.NoSuchNode;
    if (!(std.math.isFinite(w) and std.math.isFinite(h))) return error.NotFinite;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var js: Stringify = .{
        .writer = &out.writer,
    };
    var p: Plan = .{
        .a = arena.allocator(),
        .w = &js,
        .scale = scale,
    };
    try js.beginArray();
    try p.node(n, null, .{
        .x = @max(0, w),
        .y = @max(0, h),
    });
    try js.endArray();
    return out.toOwnedSlice();
}

const Plan = struct {
    a: Allocator,
    w: *Stringify,
    scale: bool,

    /// Node `n` resized to `size` (and moved to `transform`): its set, then its children.
    fn node(p: *Plan, n: *const m.Node, transform: ?Affine, size: Vec2) anyerror!void {
        const sx: f32 = if (n.size.x != 0) size.x / n.size.x else 1;
        const sy: f32 = if (n.size.y != 0) size.y / n.size.y else 1;
        // The scale tool scales by one factor (the larger change where an axis is flat).
        const k: f32 = if (n.size.x != 0) sx else sy;
        var copy = n.*;
        var names: std.ArrayList([]const u8) = .empty;
        if (transform) |t| {
            copy.transform = t;
            try names.append(p.a, "transform");
        }
        copy.size = size;
        try names.append(p.a, "size");
        if (n.network) |net| {
            copy.network = try scaleNetwork(p.a, net, sx, sy);
            try names.append(p.a, "network");
        }
        if (n.geometry.len > 0) {
            const g = try p.a.dupe(m.GeometryPath, n.geometry);
            for (g) |*x| x.d = try scalePath(p.a, x.d, sx, sy);
            copy.geometry = g;
            try names.append(p.a, "geometry");
        }
        var stroke_changed = false;
        if (n.stroke.outline.len > 0) {
            const o = try p.a.dupe(m.OutlinePath, n.stroke.outline);
            for (o) |*x| x.d = try scalePath(p.a, x.d, sx, sy);
            copy.stroke.outline = o;
            stroke_changed = true;
        }
        if (p.scale) {
            copy.stroke.weight *= k;
            if (copy.stroke.sides) |sides| copy.stroke.sides = .{ sides[0] * k, sides[1] * k, sides[2] * k, sides[3] * k };
            if (n.stroke.dashes.len > 0) {
                const d = try p.a.dupe(f32, n.stroke.dashes);
                for (d) |*x| x.* *= k;
                copy.stroke.dashes = d;
            }
            stroke_changed = stroke_changed or n.strokes.len > 0;
            if (n.effects.len > 0) {
                const e = try p.a.dupe(m.Effect, n.effects);
                for (e) |*x| {
                    x.offset = .{
                        .x = x.offset.x * k,
                        .y = x.offset.y * k,
                    };
                    x.radius *= k;
                    x.spread *= k;
                    x.grain = .{
                        .x = x.grain.x * k,
                        .y = x.grain.y * k,
                    };
                }
                copy.effects = e;
                try names.append(p.a, "effects");
            }
            if (n.radius[0] != 0 or n.radius[1] != 0 or n.radius[2] != 0 or n.radius[3] != 0) {
                copy.radius = .{ n.radius[0] * k, n.radius[1] * k, n.radius[2] * k, n.radius[3] * k };
                try names.append(p.a, "radius");
            }
            if (n.layout) |l| {
                var nl = l;
                nl.gap *= k;
                nl.cross_gap *= k;
                nl.padding = .{ l.padding[0] * k, l.padding[1] * k, l.padding[2] * k, l.padding[3] * k };
                copy.layout = nl;
                try names.append(p.a, "layout");
            }
            if (n.kind == .instance) {
                copy.scale = n.scale * k;
                try names.append(p.a, "scale");
            }
            if (n.text) |t| {
                copy.text = try scaleText(p.a, t, k);
                try names.appendSlice(p.a, &.{ "style", "runs", "glyphs", "glyphRects" });
            }
        }
        if (stroke_changed) try names.append(p.a, "stroke");
        try p.emit(n.id, &copy, names.items);

        // An instance's content is its main's, fitted by the editor; a text has none.
        if (n.kind == .instance or n.kind == .text) return;
        const old = n.size;
        const scales_kids = p.scale or n.kind == .group or n.kind == .boolean;
        for (n.children) |*c| {
            if (scales_kids) {
                const t = c.transform;
                var ct = t;
                ct.e = t.e * sx;
                ct.f = t.f * sy;
                // An unturned child scales on each axis; a turned one by the factor.
                const turned = t.b != 0 or t.c != 0;
                const cs: Vec2 = if (turned or p.scale) .{
                    .x = c.size.x * k,
                    .y = c.size.y * k,
                } else .{
                    .x = c.size.x * sx,
                    .y = c.size.y * sy,
                };
                try p.node(c, ct, cs);
                continue;
            }
            // In an auto layout's flow the layout places and sizes it.
            if (lay.inFlow(n, c)) continue;
            var cc = c.*;
            var cs = c.size;
            lay.constrain(&cc, &cs, old, size);
            const moved = !std.meta.eql(cc.transform, c.transform);
            const resized = cs.x != c.size.x or cs.y != c.size.y;
            if (resized) {
                try p.node(c, if (moved) cc.transform else null, cs);
            } else if (moved) {
                var only = c.*;
                only.transform = cc.transform;
                try p.emit(c.id, &only, &.{"transform"});
            }
        }
    }

    fn emit(p: *Plan, id: []const u8, n: *const m.Node, names: []const []const u8) !void {
        const json = try props.values(p.a, n, names);
        try p.w.beginObject();
        try p.w.objectField("op");
        try p.w.write("set");
        try p.w.objectField("node");
        try p.w.write(id);
        try p.w.objectField("props");
        try p.w.beginWriteRaw();
        try p.w.writer.writeAll(json);
        p.w.endWriteRaw();
        try p.w.endObject();
    }
};

fn scaleNetwork(a: Allocator, net: m.Network, sx: f32, sy: f32) !m.Network {
    const verts = try a.dupe(Vec2, net.vertices);
    for (verts) |*v| v.* = .{
        .x = v.x * sx,
        .y = v.y * sy,
    };
    const segs = try a.dupe(m.Segment, net.segments);
    for (segs) |*sg| {
        sg.t0 = .{
            .x = sg.t0.x * sx,
            .y = sg.t0.y * sy,
        };
        sg.t1 = .{
            .x = sg.t1.x * sx,
            .y = sg.t1.y * sy,
        };
    }
    return .{
        .vertices = verts,
        .segments = segs,
        .regions = net.regions,
    };
}

/// SVG path data (absolute M, L, C, Q, Z) with x scaled by `sx` and y by `sy`.
pub fn scalePath(a: Allocator, d: []const u8, sx: f32, sy: f32) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var i: usize = 0;
    var axis: u1 = 0;
    var first = true;
    while (i < d.len) {
        const ch = d[i];
        if (std.ascii.isAlphabetic(ch) and ch != 'e' and ch != 'E') {
            try out.writer.writeByte(ch);
            axis = 0;
            first = true;
            i += 1;
            continue;
        }
        if (ch == '-' or ch == '+' or ch == '.' or std.ascii.isDigit(ch)) {
            var j = i + 1;
            var seen_dot = ch == '.';
            while (j < d.len) : (j += 1) {
                const c = d[j];
                if (std.ascii.isDigit(c)) continue;
                if (c == '.' and !seen_dot) {
                    seen_dot = true;
                    continue;
                }
                if ((c == 'e' or c == 'E') and j + 1 < d.len) {
                    j += 1;
                    if (d[j] == '-' or d[j] == '+') {}
                    continue;
                }
                break;
            }
            const v = std.fmt.parseFloat(f32, d[i..j]) catch 0;
            const scaled = v * if (axis == 0) sx else sy;
            if (!first) try out.writer.writeByte(' ');
            try out.writer.print("{d}", .{scaled});
            first = false;
            axis +%= 1;
            i = j;
            continue;
        }
        // Separators.
        i += 1;
    }
    return out.written();
}

fn scaleStyle(st: m.TextStyle, k: f32) m.TextStyle {
    var o = st;
    if (st.size) |v| o.size = v * k;
    if (st.line_height) |lh| o.line_height = switch (lh) {
        .px => |v| .{
            .px = v * k,
        },
        else => lh,
    };
    if (st.letter_spacing) |ls| o.letter_spacing = switch (ls) {
        .px => |v| .{
            .px = v * k,
        },
        else => ls,
    };
    if (st.paragraph_spacing) |v| o.paragraph_spacing = v * k;
    if (st.paragraph_indent) |v| o.paragraph_indent = v * k;
    return o;
}

fn scaleText(a: Allocator, t: m.Text, k: f32) !m.Text {
    var o = t;
    o.style = scaleStyle(t.style, k);
    // A text without a size of its own is 16 px (the layout's default).
    if (t.style.size == null) o.style.size = 16 * k;
    const runs = try a.dupe(m.Run, t.runs);
    for (runs) |*r| r.style = scaleStyle(r.style, k);
    o.runs = runs;
    const glyphs = try a.dupe(m.TextGlyph, t.glyphs);
    for (glyphs) |*g| {
        g.x *= k;
        g.y *= k;
        g.size *= k;
    }
    o.glyphs = glyphs;
    const rects = try a.dupe(m.TextRect, t.glyph_rects);
    for (rects) |*r| r.rect = .{ r.rect[0] * k, r.rect[1] * k, r.rect[2] * k, r.rect[3] * k };
    o.glyph_rects = rects;
    return o;
}

test "a path scales by axis" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try scalePath(arena.allocator(), "M0 0L10 20C1 2 3 4 5 6Z", 2, 0.5);
    try std.testing.expectEqualStrings("M0 0L20 10C2 1 6 2 10 3Z", got);
}
