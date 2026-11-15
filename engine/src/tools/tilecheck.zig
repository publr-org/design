//! `pe tilecheck`: does a tiled render equal a whole one?
//!
//!   pe tilecheck <doc.pubd-dir> <node-id> <scale>[@fx,fy]... [--out DIR]
//!
//! For a top-level node at each scale: the node exported whole (as `pe render` draws
//! it), or, when that would pass 16 million pixels, a 2048 px window drawn in one piece
//! (at the node's centre, or at `fx`, `fy` across it, 0..1); then the same area cut into
//! 256 px tiles as the viewer draws them. With `--out`, writes both and their difference
//! as `<node>@<scale>.{whole,tiled,diff}.png`.
//! Prints how many bytes differ and by how much at most, with the time per tile.

const std = @import("std");
const engine = @import("publr_engine");
const corpus = @import("corpus.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const Session = engine.session.Session;
const tile = 256;

pub fn run(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, dir: []const u8, id: []const u8, args: []const []const u8) !void {
    var scales = args;
    var out_dir: ?[]const u8 = null;
    if (args.len >= 2 and std.mem.eql(u8, args[args.len - 2], "--out")) {
        out_dir = args[args.len - 1];
        scales = args[0 .. args.len - 2];
        try Dir.cwd().createDirPath(io, out_dir.?);
    }
    const s = try open(io, gpa, dir);
    defer s.destroy();
    // The node's page and its box there.
    var page: usize = 0;
    var found: ?*const engine.model.Node = null;
    for (s.pages(), 0..) |*pg, i| for (pg.children) |*c| {
        if (std.mem.eql(u8, c.id, id)) {
            page = i;
            found = c;
        }
    };
    const node = found orelse return error.NotATopLevelNode;
    const box = engine.geom.Rect.transformed(.{
        .x1 = node.size.x,
        .y1 = node.size.y,
    }, node.transform);

    for (scales) |arg| {
        const at = std.mem.indexOfScalar(u8, arg, '@');
        const scale = try std.fmt.parseFloat(f32, arg[0 .. at orelse arg.len]);
        var fx: f32 = 0.5;
        var fy: f32 = 0.5;
        if (at) |i| {
            var it = std.mem.splitScalar(u8, arg[i + 1 ..], ',');
            fx = try std.fmt.parseFloat(f32, it.next() orelse "0.5");
            fy = try std.fmt.parseFloat(f32, it.next() orelse "0.5");
        }
        const full_w: u32 = @intFromFloat(@round(node.size.x * scale));
        const full_h: u32 = @intFromFloat(@round(node.size.y * scale));
        const whole = @as(u64, full_w) * full_h <= 16 << 20;
        // The area compared: the node's box, or a window at its centre (in tile steps
        // from the box's corner, so tiles start where they would).
        var ox: u32 = 0;
        var oy: u32 = 0;
        var aw = full_w;
        var ah = full_h;
        if (!whole) {
            aw = @min(full_w, 2048);
            ah = @min(full_h, 2048);
            ox = @as(u32, @intFromFloat(@as(f32, @floatFromInt(full_w - aw)) * std.math.clamp(fx, 0, 1))) / tile * tile;
            oy = @as(u32, @intFromFloat(@as(f32, @floatFromInt(full_h - ah)) * std.math.clamp(fy, 0, 1))) / tile * tile;
        }
        const x0: f64 = box.x0 + @as(f64, @floatFromInt(ox)) / scale;
        const y0: f64 = box.y0 + @as(f64, @floatFromInt(oy)) / scale;
        var ref = if (whole) try s.renderNode(id, scale) else try s.renderTile(page, x0, y0, scale, aw, ah, .{});
        defer ref.deinit(gpa);

        // The tiled image and the difference, for `--out`.
        const tiled = try gpa.alloc(u8, @as(usize, aw) * ah * 4);
        defer gpa.free(tiled);
        const heat = try gpa.alloc(u8, @as(usize, aw) * ah * 4);
        defer gpa.free(heat);
        var differing: u64 = 0;
        var max: u8 = 0;
        var tiles: u32 = 0;
        var diff_box: engine.mask.IRect = .{
            .x0 = std.math.maxInt(i32),
            .y0 = std.math.maxInt(i32),
            .x1 = std.math.minInt(i32),
            .y1 = std.math.minInt(i32),
        };
        const t0 = Io.Timestamp.now(io, .awake);
        var ty: u32 = 0;
        while (ty < ah) : (ty += tile) {
            var tx: u32 = 0;
            while (tx < aw) : (tx += tile) {
                const tw = @min(tile, aw - tx);
                const th = @min(tile, ah - ty);
                var px = try s.renderTile(page, x0 + @as(f64, @floatFromInt(tx)) / scale, y0 + @as(f64, @floatFromInt(ty)) / scale, scale, tw, th, .{});
                defer px.deinit(gpa);
                tiles += 1;
                var y: u32 = 0;
                while (y < th) : (y += 1) {
                    var x: u32 = 0;
                    while (x < tw) : (x += 1) {
                        const a = rgba8(px.at(@intCast(x), @intCast(y)));
                        const b = rgba8(ref.at(@intCast(tx + x), @intCast(ty + y)));
                        const o = (@as(usize, ty + y) * aw + tx + x) * 4;
                        tiled[o..][0..4].* = a;
                        var here: u8 = 0;
                        for (a, b) |p, q| {
                            const d = if (p > q) p - q else q - p;
                            if (d > 0) differing += 1;
                            here = @max(here, d);
                        }
                        max = @max(max, here);
                        const hv: u8 = @intCast(@min(255, @as(u32, here) * 16));
                        heat[o..][0..4].* = .{ hv, if (here > 0) 0 else b[1] / 4, 0, 255 };
                        if (here > 0) {
                            const gx = tx + x;
                            const gy = ty + y;
                            diff_box = .{
                                .x0 = @min(diff_box.x0, @as(i32, @intCast(gx))),
                                .y0 = @min(diff_box.y0, @as(i32, @intCast(gy))),
                                .x1 = @max(diff_box.x1, @as(i32, @intCast(gx + 1))),
                                .y1 = @max(diff_box.y1, @as(i32, @intCast(gy + 1))),
                            };
                        }
                    }
                }
            }
        }
        const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).nanoseconds)) / std.time.ns_per_ms;
        try w.print("{s} @{s}: {s} {d}x{d}, {d} tiles ({d:.1} ms each): {d} bytes differ, max {d}\n", .{
            id,                                  arg,       if (whole) "whole" else "window", aw, ah, tiles,
            ms / @as(f64, @floatFromInt(tiles)), differing, max,
        });
        if (out_dir) |od| {
            const whole_px = try ref.toRgba8(gpa, .{
                .x1 = @intCast(aw),
                .y1 = @intCast(ah),
            });
            defer gpa.free(whole_px);
            const kinds = [_][]const u8{ "whole", "tiled", "diff" };
            const images = [_][]const u8{ whole_px, tiled, heat };
            for (kinds, images) |kind, img| {
                const bytes = try engine.png.encode(gpa, aw, ah, img);
                defer gpa.free(bytes);
                const name = try std.fmt.allocPrint(gpa, "{s}/{s}@{s}.{s}.png", .{ od, id, arg, kind });
                defer gpa.free(name);
                std.mem.replaceScalar(u8, name[od.len..], ':', '-');
                try Dir.cwd().writeFile(io, .{
                    .sub_path = name,
                    .data = bytes,
                });
            }
        }
        if (differing > 0) try w.print("  differences within x {d}..{d}, y {d}..{d} of the area\n", .{ diff_box.x0, diff_box.x1, diff_box.y0, diff_box.y1 });
        try w.flush();
    }
}

/// Straight-alpha RGBA8 of a premultiplied pixel, as `toRgba8` writes it.
fn rgba8(p: engine.pixmap.Rgba) [4]u8 {
    var px: engine.pixmap.Pixmap = .{
        .rect = .{
            .x1 = 1,
            .y1 = 1,
        },
        .data = @constCast(&[1]engine.pixmap.Rgba{p}),
    };
    var out: [4]u8 = undefined;
    px.writeRgba8(px.rect, &out);
    return out;
}

/// A session with the document, its assets and the fonts `pe render` would use.
pub fn open(io: Io, gpa: std.mem.Allocator, dir: []const u8) !*Session {
    const s = try Session.create(gpa);
    errdefer s.destroy();
    const cwd = Dir.cwd();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ dir, "document.json" }), a, .limited(corpus.max_file));
    try s.loadPubd(json);
    // Pages kept in files of their own (Pubd per page): every one, for the tools.
    for (0..s.pages().len) |i| {
        const src = s.pageFile(i) orelse continue;
        if (s.pageLoaded(i)) continue;
        const page = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ dir, src }), a, .limited(corpus.max_file));
        try s.loadPage(i, page);
    }
    for (s.doc.?.assets) |asset| {
        const bytes = cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ dir, "assets", asset.hash }), a, .limited(corpus.max_file)) catch continue;
        try s.addAsset(asset.hash, bytes);
    }
    const files = try corpus.fontFiles(io, a, dir);
    const lists = [_][]const []const u8{ files.faces, files.fallbacks, files.variable };
    const roles = [_]engine.fonts.Role{ .face, .fallback, .variable };
    for (lists, roles) |list, role| for (list) |fp| {
        const bytes = cwd.readFileAlloc(io, fp, a, .limited(64 * 1024 * 1024)) catch continue;
        _ = try s.addFont(bytes, role);
    };
    return s;
}
