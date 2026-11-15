//! What an editor's panels read of the live document: a page's layer tree as flat arrays
//! (the layers panel, the canvas marks), and the layer under a point by its real shape
//! (selection on the canvas).
//!
//! The tree is depth first and top-most first, as the layers panel lists it: node `i`'s
//! subtree is `i + 1 .. end[i]`. Its binary form (little endian, every section 4-byte
//! aligned):
//!
//!   u32 n, u32 json_len, u32 json_hash,
//!   f32 xf[6n]     absolute transforms (page space)
//!   f32 size[2n]
//!   f32 sub[4n]    what the node and its subtree may cover: x0, y0, x1, y1
//!   i32 parent[n]  (-1: on the page)
//!   i32 end[n]
//!   u16 depth[n], u16 flags[n], u8 types[n]  (each padded to 4 bytes)
//!   JSON {"ids":[...],"names":[...],"grids":[[i,[Grid...]],...],"modes":[[i,"Dark mode"],...]}
//!
//! The JSON (ids, names, guides) is most of the bytes and of the time on a big page, and
//! an edit of geometry leaves it as it was: `json_hash` says which it is, and when it is
//! the one the caller says it holds, `json_len` is 0 and no JSON follows.

const std = @import("std");
const m = @import("../pubd/model.zig");
const geom = @import("../raster/geom.zig");
const props = @import("props.zig");
const render = @import("../render/render.zig");
const Session = @import("../session.zig").Session;

const Allocator = std.mem.Allocator;
const Affine = geom.Affine;
const Vec2 = geom.Vec2;

/// Bits of `flags` (editor/design/doc-types.ts `F`).
pub const F = struct {
    pub const visible: u16 = 1;
    pub const locked: u16 = 2;
    pub const in_instance: u16 = 4;
    pub const mask: u16 = 8;
    pub const clip: u16 = 16;
    pub const hidden_above: u16 = 32;
    pub const reverse_z: u16 = 64;
    pub const locked_above: u16 = 128;
    pub const in_component: u16 = 256;
    pub const image: u16 = 512;
    /// Auto layout, by direction (the layers panel's icon); its children are listed in
    /// flow order, first at the top, as Figma lists them.
    pub const auto_v: u16 = 1024;
    pub const auto_h: u16 = 2048;
    pub const auto_grid: u16 = 4096;
};

/// Node kinds by code (editor/design/doc-types.ts `TYPES`).
const types = [_][]const u8{ "frame", "group", "section", "component", "component-set", "instance", "rectangle", "ellipse", "line", "vector", "text", "star", "polygon", "boolean", "slice", "page", "other" };

fn typeCode(k: m.Kind) u8 {
    return type_codes[@backingInt(k)];
}

/// `types` index by kind, worked out once.
const type_codes = blk: {
    const info = @typeInfo(m.Kind).@"enum";
    var out: [info.field_names.len]u8 = undefined;
    for (info.field_names, info.field_values) |field_name, value| {
        var buf: [field_name.len]u8 = undefined;
        for (field_name, 0..) |ch, i| buf[i] = if (ch == '_') '-' else ch;
        var code: u8 = types.len - 1;
        for (types, 0..) |t, i| if (std.mem.eql(u8, t, &buf)) {
            code = i;
        };
        out[value] = code;
    }
    break :blk out;
};

const Builder = struct {
    a: Allocator,
    ids: std.ArrayList([]const u8) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    xf: std.ArrayList(f32) = .empty,
    size: std.ArrayList(f32) = .empty,
    sub: std.ArrayList(f32) = .empty,
    parent: std.ArrayList(i32) = .empty,
    end: std.ArrayList(i32) = .empty,
    depth: std.ArrayList(u16) = .empty,
    flags: std.ArrayList(u16) = .empty,
    kinds: std.ArrayList(u8) = .empty,
    grids: std.ArrayList(u32) = .empty,
    grid_nodes: std.ArrayList(*const m.Node) = .empty,
    /// The layers that set variable modes themselves (their badges), by index.
    modes: std.ArrayList(u32) = .empty,
    mode_nodes: std.ArrayList(*const m.Node) = .empty,

    fn reserve(b: *Builder, n: usize) !void {
        try b.ids.ensureTotalCapacity(b.a, n);
        try b.names.ensureTotalCapacity(b.a, n);
        try b.kinds.ensureTotalCapacity(b.a, n);
        try b.parent.ensureTotalCapacity(b.a, n);
        try b.depth.ensureTotalCapacity(b.a, n);
        try b.end.ensureTotalCapacity(b.a, n);
        try b.xf.ensureTotalCapacity(b.a, n * 6);
        try b.size.ensureTotalCapacity(b.a, n * 2);
        try b.flags.ensureTotalCapacity(b.a, n);
        try b.sub.ensureTotalCapacity(b.a, n * 4);
    }

    fn visit(b: *Builder, n: *const m.Node, up: i32, d: u16, parent_m: Affine, inherited: u16) !geom.Rect {
        const i: u32 = @intCast(b.ids.items.len);
        b.ids.appendAssumeCapacity(n.id);
        b.names.appendAssumeCapacity(n.name);
        b.kinds.appendAssumeCapacity(typeCode(n.kind));
        b.parent.appendAssumeCapacity(up);
        b.depth.appendAssumeCapacity(d);
        b.end.appendAssumeCapacity(0);
        if (n.grids.len > 0) {
            try b.grids.append(b.a, i);
            try b.grid_nodes.append(b.a, n);
        }
        if (n.modes.len > 0) {
            try b.modes.append(b.a, i);
            try b.mode_nodes.append(b.a, n);
        }
        const abs = parent_m.mul(n.transform);
        b.xf.appendSliceAssumeCapacity(&.{ abs.a, abs.b, abs.c, abs.d, abs.e, abs.f });
        b.size.appendSliceAssumeCapacity(&.{ n.size.x, n.size.y });
        var f = inherited;
        if (n.visible) f |= F.visible;
        if (n.locked) f |= F.locked;
        if (n.mask != null) f |= F.mask;
        if (n.clip) f |= F.clip;
        if (n.reverse_z) f |= F.reverse_z;
        if (n.layout) |l| f |= switch (l.mode) {
            .vertical => F.auto_v,
            .horizontal => F.auto_h,
            .grid => F.auto_grid,
        };
        if (n.kind == .rectangle) for (n.fills) |p| {
            if (p.kind == .image) f |= F.image;
        };
        b.flags.appendAssumeCapacity(f);
        b.sub.appendSliceAssumeCapacity(&.{ 0, 0, 0, 0 });
        var box = geom.Rect.transformed(.{
            .x1 = n.size.x,
            .y1 = n.size.y,
        }, abs);
        if (n.children.len > 0) {
            var below = inherited;
            if (!n.visible or inherited & F.hidden_above != 0) below |= F.hidden_above;
            if (n.locked or inherited & F.locked_above != 0) below |= F.locked_above;
            if (n.kind == .instance) below |= F.in_instance;
            if (n.kind == .component or n.kind == .component_set) below |= F.in_component;
            below &= ~(F.visible | F.locked | F.mask | F.clip | F.reverse_z | F.image | F.auto_v | F.auto_h | F.auto_grid);
            const clips = n.clip and n.kind != .group;
            var k: usize = 0;
            while (k < n.children.len) : (k += 1) {
                // Top-most first (the last child), as the panel lists them; an auto layout's
                // children (or a reversed stack's) in flow order, the first at the top.
                const c = if (n.reverse_z or n.layout != null) &n.children[k] else &n.children[n.children.len - 1 - k];
                const cb = try b.visit(c, @intCast(i), d + 1, abs, below);
                if (!clips) box = box.unite(cb);
            }
        }
        b.sub.items[i * 4 + 0] = box.x0;
        b.sub.items[i * 4 + 1] = box.y0;
        b.sub.items[i * 4 + 2] = box.x1;
        b.sub.items[i * 4 + 3] = box.y1;
        b.end.items[i] = @intCast(b.ids.items.len);
        return box;
    }
};

fn countNodes(n: *const m.Node) usize {
    var k: usize = 1;
    for (n.children) |*c| k += countNodes(c);
    return k;
}

fn pad(out: *std.ArrayList(u8), gpa: Allocator) !void {
    while (out.items.len % 4 != 0) try out.append(gpa, 0);
}

fn section(out: *std.ArrayList(u8), gpa: Allocator, comptime T: type, items: []const T) !void {
    try out.appendSlice(gpa, std.mem.sliceAsBytes(items));
    try pad(out, gpa);
}

/// The name of the mode `mc` picks, or null when the document has no such mode.
fn modeName(s: *Session, mc: m.ModeChoice) ?[]const u8 {
    const d = if (s.doc) |*d| d else return null;
    for (d.collections) |c| {
        if (!std.mem.eql(u8, c.id, mc.collection)) continue;
        for (c.modes) |md| if (std.mem.eql(u8, md.id, mc.mode)) return md.name;
    }
    return null;
}

/// Page `page`'s tree in the binary form above, in `out`; without the JSON when its hash
/// is `known` (0: always with it). `same`: the caller knows the ids, names and guides are
/// as they were when it got `known` (the edits since changed geometry or paint only), so
/// they are not even hashed.
pub fn pageTree(gpa: Allocator, s: *Session, page: usize, known: u32, same: bool, out: *std.ArrayList(u8)) !void {
    if (page >= s.pages().len) return error.NoSuchPage;
    if (!s.pageLoaded(page)) return error.PageNotLoaded;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Builder = .{
        .a = a,
    };
    const pg = &s.pages()[page];
    // Every list sized once (a big page has tens of thousands of layers).
    var count: usize = 0;
    for (pg.children) |*c| count += countNodes(c);
    try b.reserve(count);
    var k: usize = 0;
    while (k < pg.children.len) : (k += 1) {
        const c = if (pg.reverse_z) &pg.children[k] else &pg.children[pg.children.len - 1 - k];
        _ = try b.visit(c, -1, 0, .identity, 0);
    }
    const n: u32 = @intCast(b.ids.items.len);
    // What the JSON says, hashed (never 0): each string on its own, combined in order.
    var h: u64 = 0x9e3779b97f4a7c15;
    if (same and known != 0) {
        b.ids.clearRetainingCapacity();
        b.names.clearRetainingCapacity();
        b.grids.clearRetainingCapacity();
        b.grid_nodes.clearRetainingCapacity();
        b.modes.clearRetainingCapacity();
        b.mode_nodes.clearRetainingCapacity();
    }
    for (b.ids.items, b.names.items) |id, name| {
        h = (h ^ std.hash.Wyhash.hash(1, id)) *% 0x100000001b3;
        h = (h ^ std.hash.Wyhash.hash(2, name)) *% 0x100000001b3;
    }
    const grid_json = try a.alloc([]const u8, b.grid_nodes.items.len);
    for (b.grids.items, b.grid_nodes.items, grid_json) |i, node, *g| {
        g.* = try props.values(a, node, &.{"grids"});
        h = (h ^ i ^ std.hash.Wyhash.hash(3, g.*)) *% 0x100000001b3;
    }
    // Each mode badge: the names of the modes the layer sets ("Dark mode").
    const mode_labels = try a.alloc([]const u8, b.mode_nodes.items.len);
    for (b.modes.items, b.mode_nodes.items, mode_labels) |i, node, *label| {
        var text: std.ArrayList(u8) = .empty;
        for (node.modes) |mc| {
            const name = modeName(s, mc) orelse continue;
            if (text.items.len > 0) try text.appendSlice(a, ", ");
            try text.appendSlice(a, name);
        }
        label.* = text.items;
        h = (h ^ i ^ std.hash.Wyhash.hash(4, label.*)) *% 0x100000001b3;
    }
    const hash: u32 = if (same and known != 0) known else @as(u32, @truncate(h ^ (h >> 32))) | 1;
    const send = hash != known;
    var json: std.Io.Writer.Allocating = .init(a);
    var w: std.json.Stringify = .{
        .writer = &json.writer,
    };
    if (send) {
        try w.beginObject();
        try w.objectField("ids");
        try w.write(b.ids.items);
        try w.objectField("names");
        try w.write(b.names.items);
        try w.objectField("grids");
        try w.beginArray();
        for (b.grids.items, grid_json) |i, g| {
            // `{"grids":[...]}`: the array.
            const at = std.mem.indexOfScalar(u8, g, '[') orelse continue;
            try w.beginArray();
            try w.write(i);
            try w.beginWriteRaw();
            try w.writer.writeAll(g[at .. g.len - 1]);
            w.endWriteRaw();
            try w.endArray();
        }
        try w.endArray();
        try w.objectField("modes");
        try w.beginArray();
        for (b.modes.items, mode_labels) |i, label| {
            if (label.len == 0) continue;
            try w.beginArray();
            try w.write(i);
            try w.write(label);
            try w.endArray();
        }
        try w.endArray();
        try w.endObject();
    }
    const text = json.written();
    out.clearRetainingCapacity();
    try out.appendSlice(gpa, std.mem.asBytes(&n));
    const jl: u32 = @intCast(text.len);
    try out.appendSlice(gpa, std.mem.asBytes(&jl));
    try out.appendSlice(gpa, std.mem.asBytes(&hash));
    try section(out, gpa, f32, b.xf.items);
    try section(out, gpa, f32, b.size.items);
    try section(out, gpa, f32, b.sub.items);
    try section(out, gpa, i32, b.parent.items);
    try section(out, gpa, i32, b.end.items);
    try section(out, gpa, u16, b.depth.items);
    try section(out, gpa, u16, b.flags.items);
    try section(out, gpa, u8, b.kinds.items);
    try out.appendSlice(gpa, text);
}

// ------------------------------------------------------------------ hit testing

/// The deepest layer at page point `p` on page `page` by its real shape, as a click on
/// the canvas finds it: hidden and locked layers (and what is in them) are skipped, masks
/// and slices never answer, clipping containers hide what lies outside them, a group
/// answers only through its children. `tol` is how near (page units) a thin shape counts.
pub fn hit(gpa: Allocator, s: *Session, page: usize, p: Vec2, tol: f32) ?*const m.Node {
    if (page >= s.pages().len or !s.pageLoaded(page)) return null;
    const pg = &s.pages()[page];
    var k: usize = 0;
    while (k < pg.children.len) : (k += 1) {
        const c = if (pg.reverse_z) &pg.children[k] else &pg.children[pg.children.len - 1 - k];
        if (hitIn(gpa, s, c, .identity, p, tol)) |h| return h;
    }
    return null;
}

fn hitIn(gpa: Allocator, s: *Session, n: *const m.Node, parent: Affine, p: Vec2, tol: f32) ?*const m.Node {
    if (!n.visible or n.locked or n.kind == .slice or n.mask != null) return null;
    const ctm = parent.mul(n.transform);
    const inv = ctm.invert() orelse return null;
    const lp = inv.apply(p);
    const inside = lp.x >= 0 and lp.y >= 0 and lp.x <= n.size.x and lp.y <= n.size.y;
    if (n.clip and n.kind.isContainer() and !inside) return null;
    if (n.kind != .boolean) {
        var k: usize = 0;
        while (k < n.children.len) : (k += 1) {
            const c = if (n.reverse_z) &n.children[k] else &n.children[n.children.len - 1 - k];
            if (hitIn(gpa, s, c, ctm, p, tol)) |h| return h;
        }
    }
    if (n.kind == .group) return null;
    // Near enough in node units: the tolerance through the node's scale.
    const scale = @max(ctm.maxScale(), 1e-6);
    const t = tol / scale;
    return if (shapeHit(gpa, s, n, lp, t, inside)) n else null;
}

/// Whether node-space point `lp` is on the node's shape (its fill area, or within its
/// stroke or `t` of its outline).
fn shapeHit(gpa: Allocator, s: *Session, n: *const m.Node, lp: Vec2, t: f32, inside: bool) bool {
    switch (n.kind) {
        .frame, .component, .component_set, .instance, .rectangle, .text, .boolean => {
            if (n.kind == .boolean and n.geometry.len == 0) return inside;
            if (n.kind != .boolean) return lp.x >= -t and lp.y >= -t and lp.x <= n.size.x + t and lp.y <= n.size.y + t;
        },
        .line => {
            const half = @max(strokeHalf(n), t);
            return lp.x >= -half and lp.x <= n.size.x + half and @abs(lp.y) <= half;
        },
        else => {},
    }
    // Shapes with an outline: inside it (when filled, or always for closed shapes), or
    // near it.
    _ = gpa;
    const ga = s.renderer.gpa;
    var path: geom.Path = .{};
    defer path.deinit(ga);
    const winding = s.renderer.fillPath(n, &path) catch return inside;
    if (path.verbs.items.len == 0) return inside;
    var polys: geom.Polylines = .{};
    defer polys.deinit(ga);
    path.flatten(ga, @max(t / 4, 0.05), &polys) catch return inside;
    const near = @max(strokeHalf(n), t);
    var wind: i32 = 0;
    var crossings: u32 = 0;
    for (polys.contours.items) |c| {
        const pts = polys.contour(c);
        const count = if (c.closed) pts.len else pts.len - 1;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const a = pts[i];
            const b = pts[(i + 1) % pts.len];
            if (segDist(lp, a, b) <= near) return true;
            if (!c.closed) continue;
            if ((a.y <= lp.y) != (b.y <= lp.y)) {
                const x = a.x + (lp.y - a.y) / (b.y - a.y) * (b.x - a.x);
                if (x > lp.x) {
                    crossings += 1;
                    wind += if (b.y > a.y) 1 else -1;
                }
            }
        }
    }
    return if (winding == .evenodd) crossings % 2 == 1 else wind != 0;
}

fn strokeHalf(n: *const m.Node) f32 {
    for (n.strokes) |p| if (p.visible) return n.stroke.weight / 2;
    return 0;
}

fn segDist(p: Vec2, a: Vec2, b: Vec2) f32 {
    const d = b.sub(a);
    const l2 = d.x * d.x + d.y * d.y;
    if (l2 == 0) return p.sub(a).len();
    const k = std.math.clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l2, 0, 1);
    return p.sub(a.add(d.scale(k))).len();
}

test "a page's tree lists top-most first with absolute boxes" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(
        \\{"pubd":0,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","children":[
        \\{"id":"1:1","type":"frame","name":"F","transform":[1,0,0,1,10,20],"size":[100,100],"clip":true,"children":[
        \\{"id":"1:2","type":"ellipse","name":"E","transform":[1,0,0,1,0,0],"size":[40,40],"fills":[{"type":"solid","color":"#000000"}]},
        \\{"id":"1:4","type":"rectangle","name":"L","locked":true,"transform":[1,0,0,1,60,60],"size":[20,20]}]},
        \\{"id":"1:3","type":"rectangle","name":"R","transform":[1,0,0,1,200,20],"size":[8,8]}]}]}
    );
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try pageTree(gpa, s, 0, 0, false, &out);
    const n = std.mem.readInt(u32, out.items[0..4], .little);
    try std.testing.expectEqual(@as(u32, 4), n);
    const jl = std.mem.readInt(u32, out.items[4..8], .little);
    const json = out.items[out.items.len - jl ..];
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"ids\":[\"1:3\",\"1:1\",\"1:4\",\"1:2\"]"));
    // Asked again by one holding that JSON: the arrays alone, the same hash.
    const hash = std.mem.readInt(u32, out.items[8..12], .little);
    const full = out.items.len;
    try pageTree(gpa, s, 0, hash, false, &out);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out.items[4..8], .little));
    try std.testing.expectEqual(hash, std.mem.readInt(u32, out.items[8..12], .little));
    try std.testing.expectEqual(full - jl, out.items.len);
    // The ellipse's corner is outside its shape; its centre is in it.
    try std.testing.expect(hit(gpa, s, 0, .{
        .x = 11,
        .y = 21,
    }, 0.5) != null);
    try std.testing.expectEqualStrings("1:1", hit(gpa, s, 0, .{
        .x = 11,
        .y = 21,
    }, 0.5).?.id);
    try std.testing.expectEqualStrings("1:2", hit(gpa, s, 0, .{
        .x = 30,
        .y = 40,
    }, 0.5).?.id);
    // A locked layer is not hit: its frame is.
    try std.testing.expectEqualStrings("1:1", hit(gpa, s, 0, .{
        .x = 75,
        .y = 85,
    }, 0.5).?.id);
}
