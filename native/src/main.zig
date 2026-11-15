//! PublrDesign on macOS without a web view: a native window whose every pixel is drawn by
//! PublrEngine on the GPU (`host.zig`, WebGPU through the `native` module). The platform
//! gives the window and the input events; the canvas and the outlines are Zig.
//!
//! `publr-design-native [doc.pubd-dir]` (default: the landing corpus). Scroll pans, pinch
//! or Cmd/Ctrl-scroll zooms, hover outlines a node, click selects it.
//! `publr-design-native --gpucheck <doc.pubd-dir> [scale]`: every top-level node of every
//! page on the GPU against the CPU (`check.zig`).
//! `publr-design-native --bench <doc.pubd-dir> [scale]`: frame times while the view moves.

const std = @import("std");
const native = @import("native");
const engine = @import("publr_engine");
const Host = @import("ui").host.Host;
const Overlay = @import("overlay.zig").Overlay;
const doc = @import("doc.zig");
const check = @import("check.zig");

const c = native.gpu.c;
const Box = engine.geom.Rect;
const Timer = @import("ui").host.Timer;

const accent = [4]f32{ 13.0 / 255.0, 153.0 / 255.0, 1, 1 };
/// The canvas where a page has no background of its own (the browser viewer's).
const default_background = [3]f32{ 0.96, 0.96, 0.96 };

/// What the window shows: the view onto page `page` and what is pointed at.
const View = struct {
    page: usize = 0,
    /// World point at the view's top left, and points per world unit.
    x: f64 = 0,
    y: f64 = 0,
    zoom: f64 = 1,
    hover: ?Box = null,
    selected: ?Box = null,
    selected_name: []const u8 = "",
};

const App = struct {
    gpa: std.mem.Allocator,
    session: *engine.session.Session,
    scene: engine.gpu_scene.Scene,
    gpu: native.gpu.Gpu,
    surface: native.gpu.Surface = undefined,
    host: *Host = undefined,
    overlay: Overlay = undefined,
    window: *native.Window = undefined,
    view: View = .{},
    fitted: bool = false,
    dirty: bool = true,
    /// Until when the zoom counts as changing (stand-ins of nearby scales meanwhile).
    moving_until: u64 = 0,
    last_zoom: f64 = 0,
    frames: u32 = 0,
    frame_ms: f64 = 0,
    self_test: enum {
        off,
        exit,
        stay,
    } = .off,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--gpucheck")) return check.gpucheck(io, gpa, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "--bench")) return check.bench(io, gpa, args[2..]);
    const dir = if (args.len > 1) args[1] else "../engine/corpus/landing/landing.pubd";

    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .session = try engine.session.Session.create(gpa),
        .scene = engine.gpu_scene.Scene.init(gpa),
        .gpu = try native.gpu.Gpu.init(),
    };
    if (init.environ_map.get("SELF_TEST")) |v| app.self_test = if (std.mem.eql(u8, v, "stay")) .stay else .exit;
    try doc.open(io, gpa, app.session, dir);
    std.debug.print("{s}: {d} pages, page 0 has {d} frames\n", .{ dir, app.session.pages().len, app.session.pages()[0].children.len });

    native.init("PublrDesign");
    app.window = try native.Window.create(.{
        .ctx = app,
        .on_event = onEvent,
    }, .{
        .title = "PublrDesign",
        .width = 1200,
        .height = 800,
    });
    app.surface = try app.gpu.surface(app.window);
    app.host = try Host.init(gpa, &app.gpu, app.surface.format);
    app.overlay = Overlay.init(gpa, app.gpu.device, app.gpu.queue, app.surface.format);
    native.run();
}

fn onEvent(ctx: ?*anyopaque, win: *native.Window, event: native.Event) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    switch (event) {
        .frame => frame(app, win),
        .resize => app.dirty = true,
        .scroll => |s| {
            var dx = s.dx;
            var dy = s.dy;
            if (!s.precise) {
                dx *= 10;
                dy *= 10;
            }
            if (s.mods.command or s.mods.control) return zoomAround(app, s.x, s.y, @exp(dy * 0.01));
            app.view.x -= dx / app.view.zoom;
            app.view.y -= dy / app.view.zoom;
            app.dirty = true;
        },
        .magnify => |g| zoomAround(app, g.x, g.y, 1 + g.amount),
        .mouse_move => |m| {
            const hit = hitAt(app, m.x, m.y);
            app.view.hover = if (hit) |h| h.box else null;
            app.dirty = true;
        },
        .mouse_down => |m| {
            const hit = hitAt(app, m.x, m.y);
            app.view.selected = if (hit) |h| h.box else null;
            app.view.selected_name = if (hit) |h| h.node.name else "";
            app.dirty = true;
        },
        else => {},
    }
}

fn hitAt(app: *App, x: f64, y: f64) ?engine.session.Hit {
    return app.session.hitTest(app.view.page, @floatCast(app.view.x + x / app.view.zoom), @floatCast(app.view.y + y / app.view.zoom));
}

fn zoomAround(app: *App, px: f64, py: f64, factor: f64) void {
    const v = &app.view;
    const wx = v.x + px / v.zoom;
    const wy = v.y + py / v.zoom;
    v.zoom = std.math.clamp(v.zoom * factor, 0.02, 256);
    v.x = wx - px / v.zoom;
    v.y = wy - py / v.zoom;
    app.dirty = true;
}

/// Zooms so the page's frames fill the window's width, top aligned.
fn fitWidth(app: *App, width: f64) void {
    const pg = &app.session.pages()[app.view.page];
    var all: Box = .empty;
    for (pg.children) |*ch| {
        const b = Box.transformed(.{
            .x1 = ch.size.x,
            .y1 = ch.size.y,
        }, ch.transform);
        all.include(.{
            .x = b.x0,
            .y = b.y0,
        });
        all.include(.{
            .x = b.x1,
            .y = b.y1,
        });
    }
    const margin = 40.0;
    app.view.zoom = (width - 2 * margin) / @max(1, all.x1 - all.x0);
    app.view.x = all.x0 - margin / app.view.zoom;
    app.view.y = all.y0 - margin / app.view.zoom;
}

/// Every display refresh: a frame when something changed, CPU layers drawn in the time
/// left, and a sharp frame once the zoom settles.
fn frame(app: *App, win: *native.Window) void {
    const size = win.size();
    const dev = win.scale();
    if (!app.fitted) {
        fitWidth(app, size.w);
        app.fitted = true;
    }
    const now = @import("ui").host.nowNs();
    if (app.view.zoom != app.last_zoom) {
        app.moving_until = now + 150 * std.time.ns_per_ms;
        app.last_zoom = app.view.zoom;
    }
    const moving = now < app.moving_until;
    // The frame after the zoom settles is drawn exact.
    if (!moving and app.scene.motion) app.dirty = true;
    if (app.dirty) {
        // Not drawn (no surface texture this refresh): tried again on the next.
        app.dirty = !(draw(app, win, size.w, size.h, dev, moving) catch |e| blk: {
            std.debug.print("frame: {}\n", .{e});
            break :blk true;
        });
    }
    // CPU layers the frame lacked, a few ms per refresh; the next frame shows them.
    if (app.host.pendingLayers() > 0 and app.host.pump(app.session, 6 * std.time.ns_per_ms)) app.dirty = true;
    if (app.host.stats.glyphs_deferred > 0) app.dirty = true;
    app.frames += 1;
    if (app.self_test != .off and app.frames == 60) selfTest(app, size.w, size.h);
}

/// Draws a frame; false when the surface had no texture to give.
fn draw(app: *App, win: *native.Window, w_pt: f64, h_pt: f64, dev: f64, moving: bool) !bool {
    const w: u32 = @intFromFloat(@round(w_pt * dev));
    const h: u32 = @intFromFloat(@round(h_pt * dev));
    if (w == 0 or h == 0) return false;
    app.surface.configure(w, h);
    const out = app.surface.acquire() orelse return false;
    var timer = Timer.start();
    const scale: f32 = @floatCast(app.view.zoom * dev);
    // The camera on whole device pixels: panning keeps every number of the frame.
    const x = @round(app.view.x * scale) / scale;
    const y = @round(app.view.y * scale) / scale;
    app.scene.motion = moving;
    try app.scene.buildPage(app.session, app.view.page, x, y, scale, w, h);
    const scene_ms = timer.lap();
    const pg = &app.session.pages()[app.view.page];
    const bg: [3]f32 = if (pg.background) |b| .{ b.r, b.g, b.b } else default_background;
    const encoder = c.wgpuDeviceCreateCommandEncoder(app.gpu.device, null);
    try app.host.encodeView(&app.scene, encoder, out.view, w, h, bg, !moving);
    app.overlay.begin(w, h);
    const s: f32 = @floatCast(app.view.zoom * dev);
    const ox: f32 = @floatCast(app.view.x);
    const oy: f32 = @floatCast(app.view.y);
    if (app.view.hover) |b| app.overlay.outline((b.x0 - ox) * s, (b.y0 - oy) * s, (b.x1 - ox) * s, (b.y1 - oy) * s, @floatCast(@max(1, dev)), accent);
    if (app.view.selected) |b| app.overlay.outline((b.x0 - ox) * s, (b.y0 - oy) * s, (b.x1 - ox) * s, (b.y1 - oy) * s, @floatCast(2 * dev), accent);
    app.overlay.encode(encoder, out.view);
    app.host.submit(encoder);
    app.surface.present(out);
    app.host.stats.scene_ms = scene_ms;
    app.frame_ms = scene_ms + timer.lap();

    var title: [256]u8 = undefined;
    const st = app.host.stats;
    const t = std.fmt.bufPrintSentinel(&title, "PublrDesign  |  {d:.0}%  |  {d:.1} ms (scene {d:.1})  |  {d} prims, {d} layers pending{s}  |  {s}", .{
        app.view.zoom * 100,
        app.frame_ms,
        scene_ms,
        st.prims,
        st.pending,
        if (moving) " (moving)" else "",
        app.view.selected_name,
    }, 0) catch return true;
    win.setTitle(t);
    return true;
}

/// `SELF_TEST=1`: once the canvas is drawn, select the node a third down the middle,
/// report and quit; `SELF_TEST=stay` keeps the window up for a screenshot.
fn selfTest(app: *App, w: f64, h: f64) void {
    const hit = hitAt(app, w / 2, h / 3);
    app.view.selected = if (hit) |x| x.box else null;
    app.view.selected_name = if (hit) |x| x.node.name else "";
    app.dirty = true;
    std.debug.print("self-test: window {d}, frame {d:.1} ms, {d} prims, {d} layers pending, node at middle: {s}\n", .{
        app.window.number(),
        app.frame_ms,
        app.host.stats.prims,
        app.host.pendingLayers(),
        app.view.selected_name,
    });
    if (app.self_test == .exit) std.c.exit(if (hit != null) 0 else 1);
}
