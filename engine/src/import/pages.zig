//! A document kept page by page (Pubd's `pages/<file>.json`, ../pubd/SPEC.md): the name
//! of a page's file and the list of its top-level nodes that `document.json` keeps, so a
//! viewer can show and fit a page before reading it.

const std = @import("std");
const m = @import("../pubd/model.zig");
const geom = @import("../raster/geom.zig");
const render = @import("../render/render.zig");

/// The page's file: `pages/<id>.json`, the id's `:` and `;` spelled `-` (every file
/// system takes it).
pub fn fileName(a: std.mem.Allocator, page_id: []const u8) ![]const u8 {
    const out = try std.fmt.allocPrint(a, "pages/{s}.json", .{page_id});
    for (out["pages/".len..]) |*c| {
        if (c.* == ':' or c.* == ';' or c.* == '/' or c.* == '\\') c.* = '-';
    }
    return out;
}

/// What `document.json` keeps of a page kept in its own file: the file and its
/// top-level nodes' boxes and painted bounds.
pub fn chunkOf(a: std.mem.Allocator, page: *const m.Node) !m.PageChunk {
    const frames = try a.alloc(m.FrameInfo, page.children.len);
    for (page.children, frames) |*c, *f| {
        const box = geom.Rect.transformed(.{
            .x1 = c.size.x,
            .y1 = c.size.y,
        }, c.transform);
        const b = render.cullBounds(c, c.transform);
        f.* = .{
            .id = try a.dupe(u8, c.id),
            .name = try a.dupe(u8, c.name),
            .kind = c.kind,
            .box = .{ box.x0, box.y0, box.x1, box.y1 },
            .bounds = if (b.isEmpty()) .{ 0, 0, 0, 0 } else .{ b.x0, b.y0, b.x1, b.y1 },
        };
    }
    return .{
        .src = try fileName(a, page.id),
        .frames = frames,
    };
}

/// The page's own fields without its nodes, copied into `a`: what `document.json`
/// lists for it.
pub fn headOf(a: std.mem.Allocator, page: *const m.Node) !m.Node {
    var head = page.*;
    head.children = &.{};
    return m.deepCopy(a, head);
}

/// Adds to `out` (in `a`) the pattern sources `n` paints with that are not under
/// `page`: nodes a page needs from elsewhere.
pub fn foreignSources(a: std.mem.Allocator, page: *const m.Node, n: *const m.Node, out: *std.ArrayList([]const u8)) !void {
    for ([_][]const m.Paint{ n.fills, n.strokes }) |list| for (list) |p| {
        if (p.kind != .pattern or p.source.len == 0) continue;
        if (find(page, p.source) != null) continue;
        for (out.items) |s| {
            if (std.mem.eql(u8, s, p.source)) break;
        } else try out.append(a, try a.dupe(u8, p.source));
    };
    for (n.children) |*c| try foreignSources(a, page, c, out);
}

/// Adds to `out` (in `a`) every component and component set on `page`, as
/// `document.json`'s `components` lists them.
pub fn componentsOf(a: std.mem.Allocator, page: *const m.Node, out: *std.ArrayList(m.ComponentRef)) !void {
    for (page.children) |*c| try componentsUnder(a, page.id, c, "", out);
}

fn componentsUnder(a: std.mem.Allocator, page: []const u8, n: *const m.Node, set: []const u8, out: *std.ArrayList(m.ComponentRef)) !void {
    // Instances hold copies of their mains, never mains.
    if (n.kind == .instance) return;
    if (n.kind == .component or n.kind == .component_set) try out.append(a, try m.deepCopy(a, m.ComponentRef{
        .id = n.id,
        .name = n.name,
        .kind = n.kind,
        .page = page,
        .set = set,
        .properties = n.properties,
    }));
    const inner = if (n.kind == .component_set) n.id else "";
    for (n.children) |*c| try componentsUnder(a, page, c, inner, out);
}

pub fn find(n: *const m.Node, id: []const u8) ?*const m.Node {
    if (std.mem.eql(u8, n.id, id)) return n;
    for (n.children) |*c| if (find(c, id)) |f| return f;
    return null;
}

test "page file names" {
    const a = std.testing.allocator;
    const n = try fileName(a, "I1:2;3:4");
    defer a.free(n);
    try std.testing.expectEqualStrings("pages/I1-2-3-4.json", n);
}
