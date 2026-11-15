//! `pe gpuscene`: what the GPU canvas's frames hold, and how long the engine takes to
//! build them.
//!
//!   pe gpuscene <doc.pubd-dir> [scale]
//!
//! For every top-level node, its frame as an export draws it at `scale` (default 1):
//! primitives per feature and fallbacks per reason, and the build time. Then each page
//! fitted into a 3456 x 1784 view, built twice (cold, then with the kept paths). The
//! pixels are checked in the browser (`window.viewer.gpuReport()`); WebGPU is not here.

const std = @import("std");
const engine = @import("publr_engine");
const tilecheck = @import("tilecheck.zig");

const Io = std.Io;
const scene_mod = engine.gpu_scene;
const Scene = scene_mod.Scene;

const features = [_][]const u8{ "", "fill formula", "fill path", "stroke ring", "stroke path", "text", "fallback", "layer", "shadow formula", "shadow pass" };
const reasons = [_][]const u8{ "", "text", "effect", "blend", "opacity", "pattern", "paint blend", "clip path", "drop shadow", "inner shadow", "mask" };

pub fn run(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, dir: []const u8, args: []const []const u8) !void {
    const scale: f32 = if (args.len > 0) try std.fmt.parseFloat(f32, args[0]) else 1;
    const s = try tilecheck.open(io, gpa, dir);
    defer s.destroy();
    var sc = Scene.init(gpa);
    defer sc.deinit();
    var total: scene_mod.Header = .{};
    for (s.pages()) |*pg| for (pg.children) |*c| {
        const wd: u32 = @intFromFloat(@max(1, @round(c.size.x * scale)));
        const ht: u32 = @intFromFloat(@max(1, @round(c.size.y * scale)));
        const t0 = Io.Timestamp.now(io, .awake);
        try sc.buildNode(s, c.id, scale, wd, ht);
        const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).nanoseconds)) / std.time.ns_per_ms;
        try w.print("{s:<14} {s:<28} {d:>6} prims {d:>5} paths {d:>4} fallbacks {d:>8.1} ms ", .{ c.id, trunc(c.name), sc.header.prim_count, sc.header.entry_count, sc.header.fallback_count, ms });
        try counts(w, &sc.header);
        try w.print("\n", .{});
        for (&total.features, sc.header.features) |*t, v| t.* += v;
        for (&total.reasons, sc.header.reasons) |*t, v| t.* += v;
        total.surface_count += sc.header.surface_count;
        total.surface_pixels += sc.header.surface_pixels;
        total.pass_count += sc.header.pass_count;
    };
    try w.print("\nall: ", .{});
    try counts(w, &total);
    try w.print("\n", .{});
    for (s.pages(), 0..) |*pg, pi| {
        var b: engine.geom.Rect = .empty;
        for (pg.children) |*c| b = b.unite(engine.geom.Rect.transformed(.{
            .x1 = c.size.x,
            .y1 = c.size.y,
        }, c.transform));
        if (b.isEmpty()) continue;
        const vw: f32 = 3456;
        const vh: f32 = 1784;
        const z = @min(vw / (b.x1 - b.x0), vh / (b.y1 - b.y0));
        sc.forget();
        for (0..2) |k| {
            const t0 = Io.Timestamp.now(io, .awake);
            try sc.buildPage(s, pi, b.x0, b.y0, z, @intFromFloat(vw), @intFromFloat(vh));
            const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).nanoseconds)) / std.time.ns_per_ms;
            try w.print("page {s} fitted (scale {d:.3}) {s}: {d} prims, {d} paths, {d} stencil vertices, {d} fallbacks, {d:.1} ms\n", .{ pg.name, z, if (k == 0) "cold" else "warm", sc.header.prim_count, sc.header.entry_count, sc.header.vert_count, sc.header.fallback_count, ms });
        }
        // Panning by whole pixels: every number kept.
        {
            var sum: f64 = 0;
            for (0..120) |fi| {
                const dx: f32 = @as(f32, @floatFromInt(fi % 60)) * 8 / z;
                const t0 = Io.Timestamp.now(io, .awake);
                try sc.buildPage(s, pi, b.x0 + dx, b.y0, z, @intFromFloat(vw), @intFromFloat(vh));
                sum += @as(f64, @floatFromInt(t0.untilNow(io, .awake).nanoseconds)) / std.time.ns_per_ms;
            }
            try w.print("page {s} panning: {d:.1} ms a frame\n", .{ pg.name, sum / 120 });
        }
        // Zooming in 2% a frame about the middle and back, still and moving (stand-ins).
        // The second moving run has the stand-ins of the first (as a canvas zooming back and forth).
        for ([3]bool{ false, true, true }) |moving| {
            sc.motion = moving;
            var sum: f64 = 0;
            var verts: u64 = 0;
            var zz = z;
            const cxw = (b.x0 + b.x1) / 2;
            const cyw = (b.y0 + b.y1) / 2;
            for (0..120) |fi| {
                zz = if (fi % 120 < 60) zz * 1.02 else zz / 1.02;
                const t0 = Io.Timestamp.now(io, .awake);
                try sc.buildPage(s, pi, cxw - vw / 2 / zz, cyw - vh / 2 / zz, zz, @intFromFloat(vw), @intFromFloat(vh));
                sum += @as(f64, @floatFromInt(t0.untilNow(io, .awake).nanoseconds)) / std.time.ns_per_ms;
                verts += sc.header.vert_count;
            }
            sc.motion = false;
            try w.print("page {s} zooming{s}: {d:.1} ms a frame, {d} stencil vertices a frame\n", .{ pg.name, if (moving) " (stand-ins)" else "", sum / 120, verts / 120 });
        }
    }
}

fn counts(w: *Io.Writer, h: *const scene_mod.Header) !void {
    for (h.features, 0..) |v, i| if (v > 0 and i < features.len) try w.print("{s} {d}; ", .{ features[i], v });
    for (h.reasons, 0..) |v, i| if (v > 0 and i < reasons.len) try w.print("fallback {s} {d}; ", .{ reasons[i], v });
    if (h.surface_count > 0) try w.print("surfaces {d} ({d:.1} Mpx); passes {d}; ", .{ h.surface_count, @as(f64, @floatFromInt(h.surface_pixels)) / 1e6, h.pass_count });
}

fn trunc(s: []const u8) []const u8 {
    return s[0..@min(s.len, 28)];
}
