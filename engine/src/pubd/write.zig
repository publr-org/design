//! A document as Pubd JSON (`document.json`). Defaults are left out.

const std = @import("std");
const m = @import("model.zig");
const geom = @import("../raster/geom.zig");

const Stringify = std.json.Stringify;

/// Pubd JSON for `doc`, owned by the caller. A number that is not finite has no
/// spelling in JSON: such a document is `error.NotFinite`, and `m.findNotFinite` names
/// the node and the field.
pub fn toJson(gpa: std.mem.Allocator, doc: *const m.Document) ![]u8 {
    if (m.findNotFinite(doc) != null) return error.NotFinite;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: Stringify = .{
        .writer = &aw.writer,
    };
    try s.beginObject();
    try s.objectField("pubd");
    try s.write(2);
    try s.objectField("name");
    try s.write(doc.name);
    try s.objectField("pages");
    try s.beginArray();
    const chunked = doc.chunks.len == doc.pages.len and doc.pages.len > 0;
    for (doc.pages, 0..) |*p, i| {
        if (chunked) {
            // The page's own fields; its nodes are in its file.
            var head = p.*;
            head.children = &.{};
            try nodeWith(&s, &head, .{
                .chunk = &doc.chunks[i],
            });
        } else try pageWithCopies(gpa, &s, p, false);
    }
    try s.endArray();
    if (doc.fonts.len > 0) {
        try s.objectField("fonts");
        try s.beginArray();
        for (doc.fonts) |f| {
            try s.beginObject();
            try s.objectField("family");
            try s.write(f.family);
            try s.objectField("style");
            try s.write(f.style);
            try s.objectField("weight");
            try s.write(f.weight);
            if (f.italic) {
                try s.objectField("italic");
                try s.write(true);
            }
            try s.endObject();
        }
        try s.endArray();
    }
    if (doc.glyphs.len > 0) {
        try s.objectField("glyphs");
        try s.beginArray();
        for (doc.glyphs) |g| try s.write(g);
        try s.endArray();
    }
    if (doc.shared.len > 0) {
        try s.objectField("shared");
        try s.beginArray();
        for (doc.shared) |*n| try node(&s, n);
        try s.endArray();
    }
    if (doc.components.len > 0) {
        try s.objectField("components");
        try s.beginObject();
        for (doc.components) |c| {
            try s.objectField(c.id);
            try s.beginObject();
            try s.objectField("type");
            try tag(&s, c.kind);
            try s.objectField("name");
            try s.write(c.name);
            try s.objectField("page");
            try s.write(c.page);
            if (c.set.len > 0) {
                try s.objectField("set");
                try s.write(c.set);
            }
            try propDefs(&s, c.properties);
            try s.endObject();
        }
        try s.endObject();
    }
    if (doc.collections.len > 0) {
        try s.objectField("collections");
        try s.beginObject();
        for (doc.collections) |*c| {
            try s.objectField(c.id);
            try collectionBody(&s, c);
        }
        try s.endObject();
    }
    if (doc.variables.len > 0) {
        try s.objectField("variables");
        try s.beginObject();
        for (doc.variables) |*v| {
            try s.objectField(v.id);
            try variableBody(&s, v);
        }
        try s.endObject();
    }
    if (doc.styles.len > 0) {
        try s.objectField("styles");
        try s.beginObject();
        for (doc.styles) |st| {
            try s.objectField(st.id);
            try s.beginObject();
            try s.objectField("type");
            try s.write(@tagName(st.kind));
            try s.objectField("name");
            try s.write(st.name);
            if (st.description.len > 0) {
                try s.objectField("description");
                try s.write(st.description);
            }
            if (st.value) |v| {
                try s.objectField("value");
                try raw(&s, v);
            }
            if (st.library) {
                try s.objectField("library");
                try s.write(true);
            }
            if (st.key.len > 0) {
                try s.objectField("key");
                try s.write(st.key);
            }
            if (st.deleted) {
                try s.objectField("deleted");
                try s.write(true);
            }
            try s.endObject();
        }
        try s.endObject();
    }
    if (doc.assets.len > 0) {
        try s.objectField("assets");
        try s.beginObject();
        for (doc.assets) |a| {
            try s.objectField(a.hash);
            try s.beginObject();
            try s.objectField("type");
            try s.write(a.type);
            try s.objectField("width");
            try s.write(a.width);
            try s.objectField("height");
            try s.write(a.height);
            try s.endObject();
        }
        try s.endObject();
    }
    try s.endObject();
    try aw.writer.writeByte('\n');
    return aw.toOwnedSlice();
}

/// `"vars": { key: variable }`, when there are any.
fn bindings(s: *Stringify, list: []const m.VarBinding) !void {
    if (list.len == 0) return;
    try s.objectField("vars");
    try s.beginObject();
    for (list) |b| {
        try s.objectField(b.key);
        try s.write(b.variable);
    }
    try s.endObject();
}

fn raw(s: *Stringify, json: []const u8) !void {
    try s.beginWriteRaw();
    try s.writer.writeAll(json);
    s.endWriteRaw();
}

/// Numbers written in full (the shortest digits that read back to the same f32)
/// instead of rounded: set while an editor writes the values a change replaces, so
/// undoing puts back exactly what was there. Files are always rounded.
var exact_numbers = false;

/// A node as Pubd JSON (one object; with `children` its whole subtree), owned by the
/// caller. `exact`: numbers in full rather than rounded to 1/10000.
/// A collection as `document.json` keeps it under its id (the id left out).
fn collectionBody(s: *Stringify, c: *const m.Collection) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(c.name);
    try s.objectField("modes");
    try s.beginArray();
    for (c.modes) |md| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(md.id);
        try s.objectField("name");
        try s.write(md.name);
        if (md.parent) |p| {
            try s.objectField("parent");
            try s.write(p);
        }
        try s.endObject();
    }
    try s.endArray();
    if (c.library) {
        try s.objectField("library");
        try s.write(true);
    }
    if (c.key.len > 0) {
        try s.objectField("key");
        try s.write(c.key);
    }
    if (c.hidden) {
        try s.objectField("hidden");
        try s.write(true);
    }
    if (c.parent) |p| {
        try s.objectField("parent");
        try s.write(p);
    }
    if (c.deleted) {
        try s.objectField("deleted");
        try s.write(true);
    }
    if (c.overrides.len > 0) {
        try s.objectField("overrides");
        try s.beginObject();
        for (c.overrides) |o| {
            try s.objectField(o.variable);
            try valuesBody(s, o.values);
        }
        try s.endObject();
    }
    try s.endObject();
}

fn valuesBody(s: *Stringify, values: []const m.VariableValue) !void {
    try s.beginObject();
    for (values) |x| {
        try s.objectField(x.mode);
        try raw(s, x.value);
    }
    try s.endObject();
}

/// A variable as `document.json` keeps it under its id (the id left out).
fn variableBody(s: *Stringify, v: *const m.Variable) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(v.name);
    try s.objectField("collection");
    try s.write(v.collection);
    try s.objectField("type");
    try tag(s, v.type);
    if (v.description.len > 0) {
        try s.objectField("description");
        try s.write(v.description);
    }
    try s.objectField("values");
    try valuesBody(s, v.values);
    if (v.scopes.len > 0) {
        try s.objectField("scopes");
        try s.write(v.scopes);
    }
    if (v.key.len > 0) {
        try s.objectField("key");
        try s.write(v.key);
    }
    if (v.hidden) {
        try s.objectField("hidden");
        try s.write(true);
    }
    if (v.deleted) {
        try s.objectField("deleted");
        try s.write(true);
    }
    if (!v.code.isEmpty()) {
        try s.objectField("code");
        try s.beginObject();
        if (v.code.web.len > 0) {
            try s.objectField("web");
            try s.write(v.code.web);
        }
        if (v.code.ios.len > 0) {
            try s.objectField("ios");
            try s.write(v.code.ios);
        }
        if (v.code.android.len > 0) {
            try s.objectField("android");
            try s.write(v.code.android);
        }
        try s.endObject();
    }
    try s.endObject();
}

/// A collection's JSON (as `document.json` keeps it, plus its `id`), owned by `gpa`.
pub fn collectionJson(gpa: std.mem.Allocator, c: *const m.Collection) ![]u8 {
    return withId(gpa, c.id, c, collectionBody);
}

/// A variable's JSON (as `document.json` keeps it, plus its `id`), owned by `gpa`.
pub fn variableJson(gpa: std.mem.Allocator, v: *const m.Variable) ![]u8 {
    return withId(gpa, v.id, v, variableBody);
}

fn withId(gpa: std.mem.Allocator, id: []const u8, x: anytype, comptime body: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s: Stringify = .{
        .writer = &out.writer,
    };
    try body(&s, x);
    // `{"id":…,` in front of the body's fields.
    const written = out.written();
    var full: std.Io.Writer.Allocating = .init(gpa);
    errdefer full.deinit();
    try full.writer.writeAll("{\"id\":");
    try std.json.Stringify.value(id, .{}, &full.writer);
    if (written.len > 2) try full.writer.writeByte(',');
    try full.writer.writeAll(written[1..]);
    out.deinit();
    return full.toOwnedSlice();
}

/// How `nodeJson` writes a node.
pub const NodeJsonOptions = struct {
    /// The node's subtree goes in; without it, only the node's own fields.
    children: bool = true,
    /// Numbers as they are, not rounded to 1/10000 as the file keeps them.
    exact: bool = true,
};

pub fn nodeJson(gpa: std.mem.Allocator, n: *const m.Node, options: NodeJsonOptions) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: Stringify = .{
        .writer = &aw.writer,
    };
    const was = exact_numbers;
    exact_numbers = options.exact;
    defer exact_numbers = was;
    if (options.children) {
        try node(&s, n);
    } else {
        var own = n.*;
        own.children = &.{};
        try node(&s, &own);
    }
    return aw.toOwnedSlice();
}

/// Numbers rounded to 1/10000: exact enough for pixels, short in the file.
fn number(s: *Stringify, v: f32) !void {
    if (!std.math.isFinite(v)) return error.NotFinite;
    if (exact_numbers) return exactNumber(s, v);
    const r = @round(@as(f64, v) * 10000) / 10000;
    if (r == @trunc(r) and @abs(r) < 1e15) {
        try s.write(@as(i64, @intFromFloat(r)));
    } else {
        try s.print("{d}", .{r});
    }
}

/// `v` in the shortest digits that read back to the same f32.
fn exactNumber(s: *Stringify, v: f32) !void {
    var buf: [64]u8 = undefined;
    return s.print("{s}", .{exactDigits(&buf, v)});
}

/// The shortest digits that read back (as f64, then f32) to `v`; the exact f64 digits
/// in the rare case the shortest form double-rounds wrong.
fn exactDigits(buf: *[64]u8, v: f32) []const u8 {
    if (v == @trunc(v) and @abs(v) < 1e15) return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(v))}) catch unreachable;
    const short = std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
    const back: f32 = @floatCast(std.fmt.parseFloat(f64, short) catch unreachable);
    if (@as(u32, @bitCast(back)) == @as(u32, @bitCast(v))) return short;
    return std.fmt.bufPrint(buf, "{d}", .{@as(f64, v)}) catch unreachable;
}

fn field(s: *Stringify, name: []const u8, v: f32) !void {
    try s.objectField(name);
    try number(s, v);
}

fn vec(s: *Stringify, v: geom.Vec2) !void {
    try s.beginArray();
    try number(s, v.x);
    try number(s, v.y);
    try s.endArray();
}

/// A colour as authored: `"#rrggbb[aa]"` when every channel is exactly a byte over 255
/// (it reads back identically), else `[r, g, b]` or `[r, g, b, a]` at full precision. The
/// file never quantises; turning a colour into bytes is the renderer's decision.
fn color(s: *Stringify, c: m.Color) !void {
    var buf: [9]u8 = undefined;
    if (colorHex(&buf, c)) |hex| return s.write(hex);
    try s.beginArray();
    try channel(s, c.r);
    try channel(s, c.g);
    try channel(s, c.b);
    if (c.a != 1) try channel(s, c.a);
    try s.endArray();
}

/// The hex spelling of `c`, or null when some channel is not exactly `n / 255` as an f32
/// (the value the reader makes of a hex byte).
pub fn colorHex(buf: *[9]u8, c: m.Color) ?[]const u8 {
    const b = [4]u8{
        byteOf(c.r) orelse return null,
        byteOf(c.g) orelse return null,
        byteOf(c.b) orelse return null,
        byteOf(c.a) orelse return null,
    };
    const hex = "0123456789abcdef";
    buf[0] = '#';
    const n: usize = if (b[3] == 255) 3 else 4;
    for (b[0..n], 0..) |x, i| {
        buf[1 + i * 2] = hex[x >> 4];
        buf[2 + i * 2] = hex[x & 15];
    }
    return buf[0 .. 1 + n * 2];
}

fn byteOf(v: f32) ?u8 {
    if (!(v >= 0 and v <= 1)) return null;
    const n: u8 = @intFromFloat(@round(@as(f64, v) * 255));
    return if (@as(f32, @floatFromInt(n)) / 255 == v) n else null;
}

/// A colour channel in the shortest digits that read back (as f64, then f32) to the same
/// f32. In the rare case that shortest form double-rounds wrong, the exact f64 digits.
fn channel(s: *Stringify, v: f32) !void {
    if (!std.math.isFinite(v)) return error.NotFinite;
    var buf: [64]u8 = undefined;
    const short = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    const back: f32 = @floatCast(std.fmt.parseFloat(f64, short) catch unreachable);
    if (@as(u32, @bitCast(back)) == @as(u32, @bitCast(v))) {
        try s.print("{s}", .{short});
    } else {
        try s.print("{d}", .{@as(f64, v)});
    }
}

fn enumName(e: anytype) []const u8 {
    return @tagName(e);
}

/// Pubd spells enum values with dashes.
fn tag(s: *Stringify, e: anytype) !void {
    var buf: [40]u8 = undefined;
    const name = @tagName(e);
    const out = buf[0..name.len];
    for (name, out) |c, *o| o.* = if (c == '_') '-' else c;
    try s.write(out);
}

fn transform(s: *Stringify, t: geom.Affine) !void {
    try s.beginArray();
    for ([_]f32{ t.a, t.b, t.c, t.d, t.e, t.f }) |v| try number(s, v);
    try s.endArray();
}

fn isIdentity(t: geom.Affine) bool {
    return t.a == 1 and t.b == 0 and t.c == 0 and t.d == 1 and t.e == 0 and t.f == 0;
}

/// A page's own file in a document kept page by page: the page node with its nodes
/// (`pages[i].src` in `document.json`). Owned by the caller.
pub fn pageJson(gpa: std.mem.Allocator, page: *const m.Node) ![]u8 {
    var one = [1]m.Node{page.*};
    const probe: m.Document = .{
        .arena = undefined,
        .pages = &one,
    };
    if (m.findNotFinite(&probe) != null) return error.NotFinite;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: Stringify = .{
        .writer = &aw.writer,
    };
    try pageWithCopies(gpa, &s, page, true);
    try aw.writer.writeByte('\n');
    return aw.toOwnedSlice();
}

fn node(s: *Stringify, n: *const m.Node) !void {
    return nodeWith(s, n, .{});
}

// ------------------------------------------------------------------ instances in files

/// While a page is written into a file: each component's content as one of its
/// instances has it, which the page's other instances are written as changes to
/// (SPEC.md "Instances in files").
var copies: ?*Copies = null;
/// Taken off the front of ids written: content written relative to its instance.
var strip: []const u8 = "";

const Copies = struct {
    gpa: std.mem.Allocator,
    bases: std.StringArrayHashMapUnmanaged(Base) = .empty,

    fn deinit(self: *Copies) void {
        for (self.bases.values()) |b| {
            self.gpa.free(b.pre);
            self.gpa.free(b.json);
        }
        self.bases.deinit(self.gpa);
    }
};

/// The instance a component's copy was taken from, its ids' prefix, and the copy as
/// written (its content, ids relative).
const Base = struct {
    inst: *const m.Node,
    pre: []u8,
    json: []u8,
};

fn pageWithCopies(gpa: std.mem.Allocator, s: *Stringify, page: *const m.Node, edits: bool) !void {
    var c: Copies = .{
        .gpa = gpa,
    };
    defer c.deinit();
    copies = &c;
    defer copies = null;
    try nodeWith(s, page, .{
        .edits = edits,
    });
}

/// What the ids of an instance's content start with: `I<instance id>;` (an instance
/// inside another one's content has an id starting with `I` already).
fn prefixOf(gpa: std.mem.Allocator, id: []const u8) ![]u8 {
    return if (std.mem.startsWith(u8, id, "I")) std.mem.concat(gpa, u8, &.{ id, ";" }) else std.mem.concat(gpa, u8, &.{ "I", id, ";" });
}

fn allUnder(kids: []const m.Node, pre: []const u8) bool {
    for (kids) |*k| if (!std.mem.startsWith(u8, k.id, pre) or !allUnder(k.children, pre)) return false;
    return true;
}

fn sameIds(xs: []const m.Node, px: []const u8, ys: []const m.Node, py: []const u8) bool {
    if (xs.len != ys.len) return false;
    for (xs, ys) |*x, *y| if (!std.mem.eql(u8, x.id[px.len..], y.id[py.len..])) return false;
    return true;
}

/// Instance `n` written as `changes` to its page's copy of its component's content (the
/// first instance of it written gives the copy); false when it is written whole.
fn copied(s: *Stringify, n: *const m.Node) !bool {
    const c = copies orelse return false;
    if (n.kind != .instance) return false;
    const comp = n.component orelse return false;
    const pre = try prefixOf(c.gpa, n.id);
    if (!allUnder(n.children, pre)) {
        c.gpa.free(pre);
        return false;
    }
    if (c.bases.get(comp)) |b| {
        defer c.gpa.free(pre);
        const json = try changesJson(c.gpa, b, n.children, pre);
        defer c.gpa.free(json);
        try s.objectField("changes");
        try raw(s, json);
        return true;
    }
    errdefer c.gpa.free(pre);
    const json = try kidsJson(c.gpa, n.children, pre);
    errdefer c.gpa.free(json);
    try c.bases.put(c.gpa, comp, .{
        .inst = n,
        .pre = pre,
        .json = json,
    });
    try s.objectField("changes");
    try s.beginObject();
    try s.endObject();
    return true;
}

/// Nodes as a JSON array, ids relative to `pre`.
fn kidsJson(gpa: std.mem.Allocator, kids: []const m.Node, pre: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: Stringify = .{
        .writer = &aw.writer,
    };
    try kidsList(&s, kids, pre);
    return aw.toOwnedSlice();
}

fn kidsList(s: *Stringify, kids: []const m.Node, pre: []const u8) !void {
    const was = strip;
    strip = pre;
    defer strip = was;
    try s.beginArray();
    for (kids) |*k| try node(s, k);
    try s.endArray();
}

/// A node's own fields (not its nodes), ids relative to `pre`.
fn ownJson(a: std.mem.Allocator, n: *const m.Node, pre: []const u8) ![]u8 {
    var own = n.*;
    own.children = &.{};
    const was_copies = copies;
    copies = null;
    defer copies = was_copies;
    const was = strip;
    strip = pre;
    defer strip = was;
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: Stringify = .{
        .writer = &aw.writer,
    };
    try node(&s, &own);
    return aw.toOwnedSlice();
}

/// `{ "<path>": { "<key>": value | null, "children"?: [...] }, ... }`: where content
/// `kids` (ids under `pre`) differs from copy `b`, node by node.
fn changesJson(gpa: std.mem.Allocator, b: Base, kids: []const m.Node, pre: []const u8) ![]u8 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: Stringify = .{
        .writer = &aw.writer,
    };
    try s.beginObject();
    if (sameIds(b.inst.children, b.pre, kids, pre)) {
        for (b.inst.children, kids) |*x, *y| try diffNode(&s, scratch.allocator(), x, b.pre, y, pre);
    } else {
        try s.objectField("");
        try s.beginObject();
        try s.objectField("children");
        try kidsList(&s, kids, pre);
        try s.endObject();
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

fn diffNode(s: *Stringify, a: std.mem.Allocator, x: *const m.Node, px: []const u8, y: *const m.Node, py: []const u8) !void {
    const ox = try ownJson(a, x, px);
    const oy = try ownJson(a, y, py);
    const same_own = std.mem.eql(u8, ox, oy);
    const same_kids = sameIds(x.children, px, y.children, py);
    if (!same_own or !same_kids) {
        try s.objectField(y.id[py.len..]);
        try s.beginObject();
        if (!same_own) try keyDiff(s, a, ox, oy);
        if (!same_kids) {
            try s.objectField("children");
            try kidsList(s, y.children, py);
        }
        try s.endObject();
    }
    if (same_kids) for (x.children, y.children) |*cx, *cy| try diffNode(s, a, cx, px, cy, py);
}

/// The keys of object `oy` that `ox` lacks or holds otherwise, and `null` for those
/// only `ox` has (numbers kept as written).
fn keyDiff(s: *Stringify, a: std.mem.Allocator, ox: []const u8, oy: []const u8) !void {
    const options: std.json.ParseOptions = .{
        .parse_numbers = false,
    };
    const vx = try std.json.parseFromSliceLeaky(std.json.Value, a, ox, options);
    const vy = try std.json.parseFromSliceLeaky(std.json.Value, a, oy, options);
    for (vy.object.keys(), vy.object.values()) |k, v| {
        if (std.mem.eql(u8, k, "id")) continue;
        if (vx.object.get(k)) |w| {
            const tv = try std.json.Stringify.valueAlloc(a, v, .{});
            const tw = try std.json.Stringify.valueAlloc(a, w, .{});
            if (std.mem.eql(u8, tv, tw)) continue;
        }
        try s.objectField(k);
        try s.write(v);
    }
    for (vx.object.keys()) |k| {
        if (vy.object.contains(k)) continue;
        try s.objectField(k);
        try s.write(null);
    }
}

const NodeWithOptions = struct {
    /// The page kept in a file of its own: written as a reference to it.
    chunk: ?*const m.PageChunk = null,
    /// A page's count of changes goes in (its own file holds it).
    edits: bool = false,
};

fn nodeWith(s: *Stringify, n: *const m.Node, options: NodeWithOptions) anyerror!void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(if (strip.len > 0 and std.mem.startsWith(u8, n.id, strip)) n.id[strip.len..] else n.id);
    try s.objectField("type");
    try tag(s, n.kind);
    if (n.name.len > 0) {
        try s.objectField("name");
        try s.write(n.name);
    }
    if (!n.visible) {
        try s.objectField("visible");
        try s.write(false);
    }
    if (n.locked) {
        try s.objectField("locked");
        try s.write(true);
    }
    if (n.kind == .page) {
        if (n.background) |b| {
            try s.objectField("background");
            try color(s, b);
        }
        if (options.edits and n.edits > 0) {
            try s.objectField("edits");
            try s.write(n.edits);
        }
    } else {
        if (!isIdentity(n.transform)) {
            try s.objectField("transform");
            try transform(s, n.transform);
        }
        try s.objectField("size");
        try vec(s, n.size);
    }
    if (n.opacity != 1) try field(s, "opacity", n.opacity);
    if (n.blend != .pass_through) {
        try s.objectField("blend");
        try tag(s, n.blend);
    }
    if (n.fills.len > 0) {
        try s.objectField("fills");
        try paints(s, n.fills);
    }
    if (n.strokes.len > 0) {
        try s.objectField("strokes");
        try paints(s, n.strokes);
        try s.objectField("stroke");
        try stroke(s, n.stroke);
    }
    if (n.effects.len > 0) {
        try s.objectField("effects");
        try s.beginArray();
        for (n.effects) |e| try effect(s, e);
        try s.endArray();
    }
    if (n.styles.fill != null or n.styles.stroke != null or n.styles.effect != null or n.styles.text != null or n.styles.grid != null) {
        try s.objectField("styles");
        try s.beginObject();
        inline for (.{ "fill", "stroke", "effect", "text", "grid" }) |k| {
            if (@field(n.styles, k)) |id| {
                try s.objectField(k);
                try s.write(id);
            }
        }
        try s.endObject();
    }
    if (n.data) |d| {
        try s.objectField("data");
        try raw(s, d);
    }
    if (n.hasRadius()) {
        try s.objectField("radius");
        const r = n.radius;
        if (r[0] == r[1] and r[1] == r[2] and r[2] == r[3]) {
            try number(s, r[0]);
        } else {
            try s.beginArray();
            for (r) |v| try number(s, v);
            try s.endArray();
        }
    }
    if (n.smoothing != 0) try field(s, "smoothing", n.smoothing);
    if (n.clip) {
        try s.objectField("clip");
        try s.write(true);
    }
    if (n.layout) |l| try layout(s, l);
    if (n.grids.len > 0) {
        try s.objectField("grids");
        try s.beginArray();
        for (n.grids) |g| try grid(s, g);
        try s.endArray();
    }
    if (n.component) |c| {
        try s.objectField("component");
        try s.write(c);
    }
    if (n.scale != 1) try field(s, "scale", n.scale);
    if (n.constraints.h != .left or n.constraints.v != .top) {
        try s.objectField("constraints");
        try s.beginObject();
        try s.objectField("h");
        try tag(s, n.constraints.h);
        try s.objectField("v");
        try tag(s, n.constraints.v);
        try s.endObject();
    }
    if (n.sizing) |z| if (z.w != .fixed or z.h != .fixed) {
        try s.objectField("sizing");
        try s.beginObject();
        try s.objectField("w");
        try tag(s, z.w);
        try s.objectField("h");
        try tag(s, z.h);
        try s.endObject();
    };
    if (n.absolute) {
        try s.objectField("absolute");
        try s.write(true);
    }
    if (n.min_width) |v| try field(s, "minWidth", v);
    if (n.max_width) |v| try field(s, "maxWidth", v);
    if (n.min_height) |v| try field(s, "minHeight", v);
    if (n.max_height) |v| try field(s, "maxHeight", v);
    if (n.cell) |c| {
        try s.objectField("cell");
        try s.beginObject();
        try s.objectField("column");
        try s.write(c.column);
        try s.objectField("row");
        try s.write(c.row);
        if (c.column_span != 1) {
            try s.objectField("columnSpan");
            try s.write(c.column_span);
        }
        if (c.row_span != 1) {
            try s.objectField("rowSpan");
            try s.write(c.row_span);
        }
        if (c.h != .auto) {
            try s.objectField("h");
            try tag(s, c.h);
        }
        if (c.v != .auto) {
            try s.objectField("v");
            try tag(s, c.v);
        }
        try s.endObject();
    }
    if (n.kind == .ellipse and !n.arc.isFull()) {
        try s.objectField("arc");
        try s.beginObject();
        try field(s, "start", n.arc.start);
        try field(s, "end", n.arc.end);
        try field(s, "inner", n.arc.inner);
        try s.endObject();
    }
    if (n.network) |net| try network(s, net);
    if (n.count != 0) {
        try s.objectField("count");
        try s.write(n.count);
    }
    if (n.kind == .star) try field(s, "innerScale", n.inner_scale);
    if (n.kind == .boolean) {
        try s.objectField("op");
        try tag(s, n.boolean_op);
    }
    if (n.geometry.len > 0) {
        try s.objectField("geometry");
        try s.beginArray();
        for (n.geometry) |g| {
            try s.beginObject();
            if (g.winding != .nonzero) {
                try s.objectField("winding");
                try tag(s, g.winding);
            }
            try s.objectField("d");
            try s.write(g.d);
            if (g.fills) |fs| {
                try s.objectField("fills");
                try paints(s, fs);
            }
            try s.endObject();
        }
        try s.endArray();
    }
    if (n.mask) |mt| {
        try s.objectField("mask");
        try tag(s, mt);
    }
    if (n.repeat) |r| {
        try s.objectField("repeat");
        try s.beginObject();
        try s.objectField("type");
        try tag(s, r.kind);
        try s.objectField("count");
        try s.write(r.count);
        try field(s, "offset", r.offset);
        if (r.vertical) {
            try s.objectField("vertical");
            try s.write(true);
        }
        try s.endObject();
    }
    if (n.reverse_z) {
        try s.objectField("reverseZ");
        try s.write(true);
    }
    if (n.text) |t| try text(s, t);
    try components(s, n);
    if (n.children.len > 0 and !try copied(s, n)) {
        try s.objectField("children");
        try s.beginArray();
        for (n.children) |*c| try node(s, c);
        try s.endArray();
    }
    if (n.kind == .page) if (copies) |c| if (c.bases.count() > 0) {
        try s.objectField("bases");
        try s.beginObject();
        for (c.bases.keys(), c.bases.values()) |k, b| {
            try s.objectField(k);
            try raw(s, b.json);
        }
        try s.endObject();
    };
    if (options.chunk) |ch| {
        try s.objectField("src");
        try s.write(ch.src);
        try s.objectField("frames");
        try s.beginArray();
        for (ch.frames) |f| {
            try s.beginObject();
            try s.objectField("id");
            try s.write(f.id);
            if (f.name.len > 0) {
                try s.objectField("name");
                try s.write(f.name);
            }
            try s.objectField("type");
            try tag(s, f.kind);
            for ([_][]const u8{ "box", "bounds" }, [_][4]f32{ f.box, f.bounds }) |name, b| {
                try s.objectField(name);
                try s.beginArray();
                for (b) |x| try number(s, x);
                try s.endArray();
            }
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
}

/// `"properties": [...]`, when there are any.
fn propDefs(s: *Stringify, defs: []const m.PropDef) !void {
    if (defs.len == 0) return;
    try s.objectField("properties");
    try propDefArray(s, defs);
}

/// Component properties as a JSON array, written to `w`.
pub fn propDefsJson(w: *std.Io.Writer, defs: []const m.PropDef) !void {
    var s: Stringify = .{
        .writer = w,
    };
    try propDefArray(&s, defs);
}

fn propDefArray(s: *Stringify, defs: []const m.PropDef) !void {
    try s.beginArray();
    for (defs) |d| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(d.id);
        if (d.name.len > 0) {
            try s.objectField("name");
            try s.write(d.name);
        }
        try s.objectField("type");
        try tag(s, d.kind);
        try s.objectField("default");
        try raw(s, d.default);
        if (d.options.len > 0) {
            try s.objectField("options");
            try s.write(d.options);
        }
        try s.endObject();
    }
    try s.endArray();
}

/// Component properties, bindings, property values and overrides (draft 1).
fn components(s: *Stringify, n: *const m.Node) !void {
    try propDefs(s, n.properties);
    if (!n.bind.isEmpty()) {
        try s.objectField("bind");
        try s.beginObject();
        inline for (.{ "visible", "text", "component" }) |k| {
            if (@field(n.bind, k)) |id| {
                try s.objectField(k);
                try s.write(id);
            }
        }
        try s.endObject();
    }
    if (n.props.len > 0) {
        try s.objectField("props");
        try s.beginObject();
        for (n.props) |p| {
            try s.objectField(p.id);
            try raw(s, p.value);
        }
        try s.endObject();
    }
    if (n.overrides) |ovs| {
        try s.objectField("overrides");
        try s.beginObject();
        for (ovs) |o| {
            try s.objectField(o.path);
            try s.write(o.keys);
        }
        try s.endObject();
    }
    try bindings(s, n.vars);
    if (n.modes.len > 0) {
        try s.objectField("modes");
        try s.beginObject();
        for (n.modes) |mc| {
            try s.objectField(mc.collection);
            try s.write(mc.mode);
        }
        try s.endObject();
    }
}

/// A style's value, as the importers read it from the style itself.
pub const StyleValue = union(enum) {
    fill: []const m.Paint,
    text: m.TextStyle,
    effect: []const m.Effect,
    grid: []const m.Grid,
};

/// A style's value as Pubd JSON (what `Style.value` keeps), owned by the caller.
pub fn styleValueJson(gpa: std.mem.Allocator, v: StyleValue) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: Stringify = .{
        .writer = &aw.writer,
    };
    switch (v) {
        .fill => |ps| try paints(&s, ps),
        .text => |st| try textStyle(&s, st),
        .effect => |es| {
            try s.beginArray();
            for (es) |e| try effect(&s, e);
            try s.endArray();
        },
        .grid => |gs| {
            try s.beginArray();
            for (gs) |g| try grid(&s, g);
            try s.endArray();
        },
    }
    return aw.toOwnedSlice();
}

/// A colour as Pubd JSON (hex when every channel is exactly a byte, else an array),
/// owned by the caller.
pub fn colorJson(gpa: std.mem.Allocator, c: m.Color) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: Stringify = .{
        .writer = &aw.writer,
    };
    try color(&s, c);
    return aw.toOwnedSlice();
}

fn paints(s: *Stringify, ps: []const m.Paint) !void {
    try s.beginArray();
    for (ps) |p| try paint(s, p);
    try s.endArray();
}

fn paint(s: *Stringify, p: m.Paint) !void {
    try s.beginObject();
    try s.objectField("type");
    try tag(s, p.kind);
    switch (p.kind) {
        .solid => {
            try s.objectField("color");
            try color(s, p.color);
        },
        .linear, .radial, .angular, .diamond => {
            try s.objectField("stops");
            try s.beginArray();
            for (p.stops) |st| {
                try s.beginObject();
                try field(s, "at", st.at);
                try s.objectField("color");
                try color(s, st.color);
                if (st.variable) |v| {
                    try s.objectField("var");
                    try s.write(v);
                }
                try s.endObject();
            }
            try s.endArray();
            try s.objectField("handles");
            try s.beginArray();
            for (p.handles) |h| try vec(s, h);
            try s.endArray();
        },
        .image => {
            try s.objectField("asset");
            try s.write(p.asset);
            try s.objectField("scale");
            try tag(s, p.scale);
            if (!isIdentity(p.image_transform)) {
                try s.objectField("transform");
                try transform(s, p.image_transform);
            }
            if (p.scale == .tile and p.tile != 1) try field(s, "tile", p.tile);
        },
        .pattern => {
            try s.objectField("source");
            try s.write(p.source);
            try s.objectField("tiles");
            try tag(s, p.tile_type);
            if (p.tile != 1) try field(s, "scale", p.tile);
            if (p.spacing.x != 0 or p.spacing.y != 0) {
                try s.objectField("spacing");
                try vec(s, p.spacing);
            }
            try s.objectField("align");
            try s.beginArray();
            try tag(s, p.h_align);
            try tag(s, p.v_align);
            try s.endArray();
        },
    }
    if (!p.visible) {
        try s.objectField("visible");
        try s.write(false);
    }
    if (p.opacity != 1) try field(s, "opacity", p.opacity);
    if (p.blend != .normal) {
        try s.objectField("blend");
        try tag(s, p.blend);
    }
    if (p.variable) |v| {
        try s.objectField("var");
        try s.write(v);
    }
    try bindings(s, p.vars);
    try s.endObject();
}

fn stroke(s: *Stringify, st: m.Stroke) !void {
    try s.beginObject();
    try field(s, "weight", st.weight);
    if (st.outline.len > 0) {
        try s.objectField("outline");
        try s.beginArray();
        for (st.outline) |o| {
            try s.beginObject();
            if (o.winding != .nonzero) {
                try s.objectField("winding");
                try tag(s, o.winding);
            }
            try s.objectField("d");
            try s.write(o.d);
            try s.endObject();
        }
        try s.endArray();
    }
    if (st.@"align") |a| {
        try s.objectField("align");
        try tag(s, a);
    }
    if (st.cap != .none) {
        try s.objectField("cap");
        try tag(s, st.cap);
    }
    if (st.join != .miter) {
        try s.objectField("join");
        try tag(s, st.join);
    }
    if (@abs(st.miter - 4) > 1e-3) try field(s, "miter", st.miter);
    if (st.dashes.len > 0) {
        try s.objectField("dashes");
        try s.beginArray();
        for (st.dashes) |d| try number(s, d);
        try s.endArray();
    }
    if (st.sides) |sd| {
        try s.objectField("sides");
        try s.beginArray();
        for (sd) |v| try number(s, v);
        try s.endArray();
    }
    if (st.widths.len > 0) {
        try s.objectField("widths");
        try s.beginArray();
        for (st.widths) |wp| {
            try s.beginObject();
            if (wp.segment != 0) {
                try s.objectField("segment");
                try s.write(wp.segment);
            }
            try field(s, "at", wp.at);
            try field(s, "ascent", wp.ascent);
            try field(s, "descent", wp.descent);
            try s.endObject();
        }
        try s.endArray();
    }
    if (st.brush) |b| {
        try s.objectField("brush");
        try s.beginObject();
        try s.objectField("type");
        try tag(s, b.kind);
        try s.objectField("name");
        try s.write(b.name);
        try s.objectField("size");
        try vec(s, b.size);
        if (b.geometry.len > 0) {
            try s.objectField("geometry");
            try s.beginArray();
            for (b.geometry) |g| {
                try s.beginObject();
                if (g.winding != .nonzero) {
                    try s.objectField("winding");
                    try tag(s, g.winding);
                }
                try s.objectField("d");
                try s.write(g.d);
                try s.endObject();
            }
            try s.endArray();
        }
        if (b.reverse) {
            try s.objectField("reverse");
            try s.write(true);
        }
        if (b.scatter) |sc| {
            try s.objectField("scatter");
            try scatter(s, sc);
        }
        if (b.adjust) |sc| {
            try s.objectField("adjust");
            try scatter(s, sc);
        }
        if (b.stamps.len > 0) {
            try s.objectField("stamps");
            try s.beginArray();
            // Stamps are small scales of a large shape: kept at full precision.
            for (b.stamps) |t| {
                try s.beginArray();
                for ([_]f32{ t.a, t.b, t.c, t.d, t.e, t.f }) |x| {
                    if (!std.math.isFinite(x)) return error.NotFinite;
                    try s.print("{d}", .{x});
                }
                try s.endArray();
            }
            try s.endArray();
        }
        try s.endObject();
    }
    if (st.dynamic) |d| {
        try s.objectField("dynamic");
        try s.beginObject();
        try field(s, "frequency", d.frequency);
        try field(s, "wiggle", d.wiggle);
        try field(s, "smoothen", d.smoothen);
        try s.endObject();
    }
    try s.endObject();
}

fn scatter(s: *Stringify, sc: m.Scatter) !void {
    try s.beginObject();
    try field(s, "gap", sc.gap);
    try field(s, "wiggle", sc.wiggle);
    try field(s, "angleJitter", sc.angle_jitter);
    try field(s, "rotation", sc.rotation);
    try field(s, "sizeJitter", sc.size_jitter);
    try s.endObject();
}

fn effect(s: *Stringify, e: m.Effect) !void {
    try s.beginObject();
    try s.objectField("type");
    try tag(s, e.kind);
    if (e.kind == .drop_shadow or e.kind == .inner_shadow or e.kind == .noise) {
        try s.objectField("color");
        try color(s, e.color);
    }
    if (e.kind == .drop_shadow or e.kind == .inner_shadow) {
        try s.objectField("offset");
        try vec(s, e.offset);
    }
    try field(s, "radius", e.radius);
    if (e.progressive) |pg| {
        try s.objectField("progressive");
        try s.beginObject();
        try s.objectField("start");
        try vec(s, pg.start);
        try s.objectField("end");
        try vec(s, pg.end);
        try field(s, "startRadius", pg.start_radius);
        try s.endObject();
    }
    if (e.kind == .noise or e.kind == .texture) {
        try s.objectField("grain");
        try vec(s, e.grain);
    }
    if (e.kind == .noise) {
        try s.objectField("noise");
        try tag(s, e.noise);
        try field(s, "density", e.density);
        if (e.noise == .duotone) {
            try s.objectField("secondary");
            try color(s, e.secondary);
        }
        if (e.noise == .multitone) try field(s, "opacity", e.opacity);
    }
    if ((e.kind == .noise or e.kind == .texture) and e.seed != 0) {
        try s.objectField("seed");
        try s.write(e.seed);
    }
    if (e.kind == .texture and !e.clip) {
        try s.objectField("clip");
        try s.write(false);
    }
    if (e.spread != 0) try field(s, "spread", e.spread);
    if (e.behind) {
        try s.objectField("behind");
        try s.write(true);
    }
    if (e.blend != .normal) {
        try s.objectField("blend");
        try tag(s, e.blend);
    }
    if (!e.visible) {
        try s.objectField("visible");
        try s.write(false);
    }
    try bindings(s, e.vars);
    try s.endObject();
}

fn layout(s: *Stringify, l: m.Layout) !void {
    try s.objectField("layout");
    try s.beginObject();
    try s.objectField("mode");
    try tag(s, l.mode);
    if (l.wrap) {
        try s.objectField("wrap");
        try s.write(true);
    }
    if (l.gap != 0) try field(s, "gap", l.gap);
    if (l.cross_gap != 0) try field(s, "crossGap", l.cross_gap);
    if (l.padding[0] != 0 or l.padding[1] != 0 or l.padding[2] != 0 or l.padding[3] != 0) {
        try s.objectField("padding");
        try s.beginArray();
        for (l.padding) |v| try number(s, v);
        try s.endArray();
    }
    if (l.main != .start) {
        try s.objectField("main");
        try tag(s, l.main);
    }
    if (l.cross != .start) {
        try s.objectField("cross");
        try tag(s, l.cross);
    }
    if (l.width != .fixed) {
        try s.objectField("width");
        try tag(s, l.width);
    }
    if (l.height != .fixed) {
        try s.objectField("height");
        try tag(s, l.height);
    }
    if (l.align_content != .auto) {
        try s.objectField("alignContent");
        try tag(s, l.align_content);
    }
    if (l.strokes_included) {
        try s.objectField("strokesIncluded");
        try s.write(true);
    }
    if (l.columns.len > 0) try tracks(s, "columns", l.columns);
    if (l.rows.len > 0) try tracks(s, "rows", l.rows);
    try s.endObject();
}

fn tracks(s: *Stringify, name: []const u8, list: []const m.Track) !void {
    try s.objectField(name);
    try s.beginArray();
    for (list) |t| {
        try s.beginObject();
        try s.objectField("type");
        try tag(s, t.kind);
        try field(s, "value", t.value);
        try s.endObject();
    }
    try s.endArray();
}

fn grid(s: *Stringify, g: m.Grid) !void {
    try s.beginObject();
    try s.objectField("type");
    try tag(s, g.kind);
    try s.objectField("count");
    try s.write(g.count);
    try field(s, "gutter", g.gutter);
    try field(s, "offset", g.offset);
    try field(s, "size", g.size);
    try s.objectField("align");
    try tag(s, g.@"align");
    try s.objectField("color");
    try color(s, g.color);
    if (!g.visible) {
        try s.objectField("visible");
        try s.write(false);
    }
    try bindings(s, g.vars);
    try s.endObject();
}

fn network(s: *Stringify, net: m.Network) !void {
    try s.objectField("network");
    try s.beginObject();
    try s.objectField("vertices");
    try s.beginArray();
    for (net.vertices) |v| try vec(s, v);
    try s.endArray();
    try s.objectField("segments");
    try s.beginArray();
    for (net.segments) |sg| {
        try s.beginObject();
        try s.objectField("from");
        try s.write(sg.from);
        try s.objectField("to");
        try s.write(sg.to);
        if (sg.t0.x != 0 or sg.t0.y != 0) {
            try s.objectField("t0");
            try vec(s, sg.t0);
        }
        if (sg.t1.x != 0 or sg.t1.y != 0) {
            try s.objectField("t1");
            try vec(s, sg.t1);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("regions");
    try s.beginArray();
    for (net.regions) |r| {
        try s.beginObject();
        try s.objectField("winding");
        try tag(s, r.winding);
        try s.objectField("loops");
        try s.write(r.loops);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

fn text(s: *Stringify, t: m.Text) !void {
    if (!t.skip_ink) {
        try s.objectField("skipInk");
        try s.write(false);
    }
    try s.objectField("text");
    try s.write(t.text);
    try s.objectField("style");
    try textStyle(s, t.style);
    if (t.runs.len > 0) {
        try s.objectField("runs");
        try s.beginArray();
        for (t.runs) |r| {
            try s.beginObject();
            try s.objectField("from");
            try s.write(r.from);
            try s.objectField("to");
            try s.write(r.to);
            try s.objectField("style");
            try textStyle(s, r.style);
            if (r.fills) |fs| {
                try s.objectField("fills");
                try paints(s, fs);
            }
            try s.endObject();
        }
        try s.endArray();
    }
    if (t.resize != .fixed) {
        try s.objectField("resize");
        try tag(s, t.resize);
    }
    if (t.@"align" != .left) {
        try s.objectField("align");
        try tag(s, t.@"align");
    }
    if (t.valign != .top) {
        try s.objectField("valign");
        try tag(s, t.valign);
    }
    if (t.truncation != .none) {
        try s.objectField("truncation");
        try tag(s, t.truncation);
    }
    if (t.max_lines) |ml| {
        try s.objectField("maxLines");
        try s.write(ml);
    }
    if (t.wrap != .auto) {
        try s.objectField("wrap");
        try tag(s, t.wrap);
    }
    if (t.leading_trim != .none) {
        try s.objectField("leadingTrim");
        try tag(s, t.leading_trim);
    }
    if (t.hanging_punctuation) {
        try s.objectField("hangingPunctuation");
        try s.write(true);
    }
    if (t.hanging_list) {
        try s.objectField("hangingList");
        try s.write(true);
    }
    if (t.lists.len > 0) {
        try s.objectField("lists");
        try s.beginArray();
        for (t.lists) |l| {
            try s.beginObject();
            try s.objectField("type");
            try tag(s, l.type);
            try s.objectField("indent");
            try s.write(l.indent);
            try s.endObject();
        }
        try s.endArray();
    }
    if (t.path_start.segment != 0 or t.path_start.position != 0) {
        try s.objectField("pathStart");
        try s.beginObject();
        try s.objectField("segment");
        try s.write(t.path_start.segment);
        try field(s, "position", t.path_start.position);
        try s.endObject();
    }
    if (t.glyphs.len > 0) {
        // [outline, x, y, size, char] (and rotation when turned), one line each.
        try s.objectField("glyphs");
        try s.beginArray();
        for (t.glyphs) |g| {
            try s.beginWriteRaw();
            defer s.endWriteRaw();
            try s.writer.print("[{d},", .{g.outline});
            try rawNumber(s, g.x);
            try s.writer.writeByte(',');
            try rawNumber(s, g.y);
            try s.writer.writeByte(',');
            try rawNumber(s, g.size);
            try s.writer.print(",{d}", .{g.char});
            if (g.rotation != 0) {
                try s.writer.writeByte(',');
                try rawNumber(s, g.rotation);
            }
            try s.writer.writeByte(']');
        }
        try s.endArray();
    }
    if (t.glyph_rects.len > 0) {
        try s.objectField("glyphRects");
        try s.beginArray();
        for (t.glyph_rects) |r| {
            try s.beginArray();
            for (r.rect) |x| try number(s, x);
            try s.write(r.char);
            try s.endArray();
        }
        try s.endArray();
    }
}

/// A number as `number` spells it, written straight to the output (inside raw JSON).
fn rawNumber(s: *Stringify, v: f32) !void {
    if (!std.math.isFinite(v)) return error.NotFinite;
    if (exact_numbers) {
        var buf: [64]u8 = undefined;
        return s.writer.writeAll(exactDigits(&buf, v));
    }
    const r = @round(@as(f64, v) * 10000) / 10000;
    if (r == @trunc(r) and @abs(r) < 1e15) {
        try s.writer.print("{d}", .{@as(i64, @intFromFloat(r))});
    } else try s.writer.print("{d}", .{r});
}

fn textStyle(s: *Stringify, st: m.TextStyle) !void {
    try s.beginObject();
    if (st.family) |v| {
        try s.objectField("family");
        try s.write(v);
    }
    if (st.weight) |v| {
        try s.objectField("weight");
        try s.write(v);
    }
    if (st.italic) |v| if (v) {
        try s.objectField("italic");
        try s.write(true);
    };
    if (st.font_style) |v| {
        try s.objectField("fontStyle");
        try s.write(v);
    }
    if (st.size) |v| try field(s, "size", v);
    if (st.line_height) |lh| {
        try s.objectField("lineHeight");
        switch (lh) {
            .auto => try s.write("auto"),
            .px => |v| {
                try s.beginObject();
                try field(s, "px", v);
                try s.endObject();
            },
            .percent => |v| {
                try s.beginObject();
                try field(s, "percent", v);
                try s.endObject();
            },
        }
    }
    if (st.letter_spacing) |ls| switch (ls) {
        .px => |v| if (v != 0) try field(s, "letterSpacing", v),
        .percent => |v| {
            try s.objectField("letterSpacing");
            try s.beginObject();
            try field(s, "percent", v);
            try s.endObject();
        },
    };
    if (st.paragraph_spacing) |v| if (v != 0) try field(s, "paragraphSpacing", v);
    if (st.paragraph_indent) |v| if (v != 0) try field(s, "paragraphIndent", v);
    if (st.case) |v| if (v != .none) {
        try s.objectField("case");
        try tag(s, v);
    };
    if (st.decoration) |v| if (v != .none) {
        try s.objectField("decoration");
        try tag(s, v);
    };
    if (st.decoration_style) |v| if (v != .solid) {
        try s.objectField("decorationStyle");
        try tag(s, v);
    };
    try bindings(s, st.vars);
    try s.endObject();
}

test "colours keep full precision" {
    var buf: [9]u8 = undefined;
    // Figma's 0.7 is 0.69999999 in f32: no byte over 255 reads back as it.
    const lavender: m.Color = .{
        .r = 0.76,
        .g = 0.7,
        .b = 0.94,
    };
    try std.testing.expect(colorHex(&buf, lavender) == null);
    const bytes: m.Color = .{
        .r = 194.0 / 255.0,
        .g = 178.0 / 255.0,
        .b = 240.0 / 255.0,
        .a = 64.0 / 255.0,
    };
    try std.testing.expectEqualStrings("#c2b2f040", colorHex(&buf, bytes).?);
    // The one f32 in 0..1 whose shortest digits double-round wrong through f64.
    const odd: f32 = @bitCast(@as(u32, 0x15ae43fd));
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var s: Stringify = .{
        .writer = &out.writer,
    };
    try color(&s, .{
        .r = odd,
        .g = 0.7,
        .b = 1,
        .a = 0.25,
    });
    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer v.deinit();
    const read = @import("read.zig");
    const c = read.color(v.value);
    try std.testing.expectEqual(odd, c.r);
    try std.testing.expectEqual(@as(f32, 0.7), c.g);
    try std.testing.expectEqual(@as(f32, 1), c.b);
    try std.testing.expectEqual(@as(f32, 0.25), c.a);
}

test "a number that is not finite is an error, never written" {
    var kids = [_]m.Node{.{
        .id = "4:103",
        .kind = .group,
        .size = .{
            .x = std.math.nan(f32),
            .y = std.math.nan(f32),
        },
    }};
    var pages = [_]m.Node{.{
        .id = "0:1",
        .kind = .page,
        .children = &kids,
    }};
    var doc: m.Document = .{
        .arena = .init(std.testing.allocator),
        .pages = &pages,
    };
    defer doc.deinit();
    try std.testing.expectError(error.NotFinite, toJson(std.testing.allocator, &doc));
    var buf: [200]u8 = undefined;
    try std.testing.expectEqualStrings("node 4:103: size.x is not a finite number", m.findNotFinite(&doc).?.describe(&buf));
    kids[0].size = .{};
    const json = try toJson(std.testing.allocator, &doc);
    std.testing.allocator.free(json);
}
