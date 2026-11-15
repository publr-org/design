//! Headless checks of the GPU canvas (no window): the browser's `gpuReport` and a frame
//! time benchmark, natively.

const std = @import("std");
const native = @import("native");
const engine = @import("publr_engine");
const host_mod = @import("ui").host;
const doc = @import("doc.zig");

const c = native.gpu.c;
const Io = std.Io;
const Host = host_mod.Host;
const Timer = host_mod.Timer;

/// `--gpucheck <doc.pubd-dir> [scale] [filter]`: every top-level node of every page
/// drawn as an export on the GPU and on the CPU (`Session.renderNode`), with how many
/// pixels agree within 2/255 on every channel (straight RGBA8, as the browser compares).
pub fn gpucheck(io: Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 1) return error.Usage;
    const scale: f32 = if (args.len > 1) try std.fmt.parseFloat(f32, args[1]) else 1;
    const filter: []const u8 = if (args.len > 2) args[2] else "";
    const session = try engine.session.Session.create(gpa);
    try doc.open(io, gpa, session, args[0]);
    var gpu = try native.gpu.Gpu.init();
    const host = try Host.init(gpa, &gpu, c.WGPUTextureFormat_RGBA8Unorm);
    var scene = engine.gpu_scene.Scene.init(gpa);

    var off_total: u64 = 0;
    var px_total: u64 = 0;
    std.debug.print("{s:<28} {s:>11} {s:>8} {s:>4} {s:>6} {s:>5} {s:>7} {s:>7}\n", .{ "node", "size", "within2", "max", "prims", "fb", "cpu ms", "gpu ms" });
    for (session.pages()) |*pg| for (pg.children) |*n| {
        if (filter.len > 0 and std.ascii.findIgnoreCase(n.name, filter) == null) continue;
        const w = n.size.x * scale;
        const h = n.size.y * scale;
        if (w * h > 40e6 or w < 1 or h < 1) continue;
        var timer = Timer.start();
        var cpu = session.renderNode(n.id, scale) catch |e| {
            std.debug.print("{s:<28} cpu: {}\n", .{ n.name, e });
            continue;
        };
        defer cpu.deinit(gpa);
        const cpu_ms = timer.lap();
        const width = cpu.rect.width();
        const height = cpu.rect.height();
        const cpu_rgba = try cpu.toRgba8(gpa, cpu.rect);
        defer gpa.free(cpu_rgba);
        const gpu_rgba = try host.renderNode(&scene, session, n.id, scale, width, height);
        defer gpa.free(gpu_rgba);
        const gpu_ms = timer.lap();
        var off: u64 = 0;
        var max: u8 = 0;
        var i: usize = 0;
        while (i < gpu_rgba.len) : (i += 4) {
            var d: u8 = 0;
            for (0..4) |k| d = @max(d, if (gpu_rgba[i + k] > cpu_rgba[i + k]) gpu_rgba[i + k] - cpu_rgba[i + k] else cpu_rgba[i + k] - gpu_rgba[i + k]);
            if (d > 2) off += 1;
            max = @max(max, d);
        }
        const pixels = @as(u64, width) * height;
        off_total += off;
        px_total += pixels;
        var size_buf: [32]u8 = undefined;
        std.debug.print("{s:<28} {s:>11} {d:>7.2}% {d:>4} {d:>6} {d:>5} {d:>7.0} {d:>7.0}\n", .{
            n.name[0..@min(n.name.len, 28)],
            try std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ width, height }),
            100 * (1 - @as(f64, @floatFromInt(off)) / @as(f64, @floatFromInt(@max(1, pixels)))),
            max,
            host.stats.prims,
            host.stats.fallbacks,
            cpu_ms,
            gpu_ms,
        });
    };
    std.debug.print("total at {d}x: {d:.2}% of {d} pixels within 2/255\n", .{ scale, 100 * (1 - @as(f64, @floatFromInt(off_total)) / @as(f64, @floatFromInt(@max(1, px_total)))), px_total });
}

/// `--bench <doc.pubd-dir> [scale] [page]`: page `page` (default 0) in a 1200 x 800 point
/// view at `scale` (default 2) fitted to its width, panned and then zoomed as a person would, offscreen.
/// Per frame: the scene build, the encoding and the GPU (waited for), ms.
pub fn bench(io: Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 1) return error.Usage;
    const dev: f64 = if (args.len > 1) try std.fmt.parseFloat(f64, args[1]) else 2;
    const page: usize = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 0;
    const session = try engine.session.Session.create(gpa);
    try doc.open(io, gpa, session, args[0]);
    var gpu = try native.gpu.Gpu.init();
    const format = c.WGPUTextureFormat_BGRA8Unorm;
    const host = try Host.init(gpa, &gpu, format);
    var scene = engine.gpu_scene.Scene.init(gpa);
    const w: u32 = @intFromFloat(1200 * dev);
    const h: u32 = @intFromFloat(800 * dev);
    const out_tex = host_mod.createTexture(gpu.device, w, h, 1, format, c.WGPUTextureUsage_RenderAttachment, 1, 1);
    const out = c.wgpuTextureCreateView(out_tex, null);

    const pg = &session.pages()[page];
    var x0: f32 = std.math.floatMax(f32);
    var x1: f32 = -std.math.floatMax(f32);
    var y0: f32 = std.math.floatMax(f32);
    for (pg.children) |*n| {
        const b = engine.geom.Rect.transformed(.{
            .x1 = n.size.x,
            .y1 = n.size.y,
        }, n.transform);
        x0 = @min(x0, b.x0);
        x1 = @max(x1, b.x1);
        y0 = @min(y0, b.y0);
    }
    var zoom: f64 = (1200 - 80) / @max(1, x1 - x0);
    var x: f64 = x0 - 40 / zoom;
    var y: f64 = y0 - 40 / zoom;
    const bg: [3]f32 = if (pg.background) |b| .{ b.r, b.g, b.b } else .{ 0.96, 0.96, 0.96 };

    const Frame = struct {
        fn run(hst: *Host, sc: *engine.gpu_scene.Scene, s: *engine.session.Session, page_index: usize, g: *native.gpu.Gpu, o: c.WGPUTextureView, ww: u32, hh: u32, vx: f64, vy: f64, z: f64, d: f64, moving: bool, b: [3]f32) ![3]f64 {
            var t = Timer.start();
            const scale: f32 = @floatCast(z * d);
            sc.motion = moving;
            try sc.buildPage(s, page_index, @round(vx * scale) / scale, @round(vy * scale) / scale, scale, ww, hh);
            const scene_ms = t.lap();
            const enc = c.wgpuDeviceCreateCommandEncoder(g.device, null);
            try hst.encodeView(sc, enc, o, ww, hh, b, !moving);
            hst.submit(enc);
            const encode_ms = t.lap();
            const gpu_ms = hst.finish();
            return .{ scene_ms, encode_ms, gpu_ms };
        }
    };

    // Settled first: every CPU layer of the view drawn, as after a while on screen.
    var settle: u32 = 0;
    while (settle < 400) : (settle += 1) {
        _ = try Frame.run(host, &scene, session, page, &gpu, out, w, h, x, y, zoom, dev, false, bg);
        if (host.pendingLayers() == 0 and host.stats.glyphs_deferred == 0) break;
        _ = host.pump(session, std.math.maxInt(u64));
    }
    const first = try Frame.run(host, &scene, session, page, &gpu, out, w, h, x, y, zoom, dev, false, bg);
    std.debug.print("settled after {d} frames, then a frame {d}x{d}: scene {d:.2} ms, encode {d:.2} ms, gpu {d:.2} ms; {d} prims, {d} draw calls, {d} surfaces ({d} drawn), {d} fallbacks\n", .{ settle, w, h, first[0], first[1], first[2], host.stats.prims, host.stats.draw_calls, host.stats.surfaces, host.stats.surfaces_drawn, host.stats.fallbacks });

    var pan: [120][3]f64 = undefined;
    for (&pan, 0..) |*f, i| {
        // Down the page, as a trackpad scroll: 12 points a frame, a little sideways.
        y += 12 / zoom;
        x += @sin(@as(f64, @floatFromInt(i)) / 10) * 2 / zoom;
        f.* = try Frame.run(host, &scene, session, page, &gpu, out, w, h, x, y, zoom, dev, false, bg);
        _ = host.pump(session, 6 * std.time.ns_per_ms);
    }
    report("pan", &pan);
    var zm: [120][3]f64 = undefined;
    for (&zm, 0..) |*f, i| {
        // Pinch in, then out, around the view's middle.
        const factor: f64 = if (i < 60) 1.02 else 1.0 / 1.02;
        const wx = x + 600 / zoom;
        const wy = y + 400 / zoom;
        zoom *= factor;
        x = wx - 600 / zoom;
        y = wy - 400 / zoom;
        f.* = try Frame.run(host, &scene, session, page, &gpu, out, w, h, x, y, zoom, dev, true, bg);
        _ = host.pump(session, 6 * std.time.ns_per_ms);
    }
    report("zoom", &zm);
}

fn report(name: []const u8, frames: []const [3]f64) void {
    var totals: [4]std.ArrayList(f64) = .{ .empty, .empty, .empty, .empty };
    const a = std.heap.c_allocator;
    for (frames) |f| {
        for (0..3) |k| totals[k].append(a, f[k]) catch {};
        totals[3].append(a, f[0] + f[1] + f[2]) catch {};
    }
    std.debug.print("{s:<5}", .{name});
    for ([_][]const u8{ "scene", "encode", "gpu", "total" }, &totals) |label, *list| {
        std.mem.sort(f64, list.items, {}, std.sort.asc(f64));
        var sum: f64 = 0;
        for (list.items) |v| sum += v;
        const p95 = list.items[@min(list.items.len - 1, list.items.len * 95 / 100)];
        std.debug.print("  {s} avg {d:.2} p95 {d:.2}", .{ label, sum / @as(f64, @floatFromInt(list.items.len)), p95 });
        list.deinit(a);
    }
    std.debug.print("  (ms, {d} frames)\n", .{frames.len});
}
