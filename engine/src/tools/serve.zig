//! `pe serve`: a local page for watching render accuracy while the engine is built.
//!
//!   pe serve <doc.pubd-dir> <renders-dir> [--port 8400] [--site DIR]
//!
//! Loads the document once, then renders fresh on every request it has not answered
//! before, so restarting a rebuilt binary shows the current engine. Binds 127.0.0.1.
//! The page is PublrDesign's UI build (`zig build` in ../editor writes it to
//! ../editor/zig-out/site; its sources are ../editor/dashboard), read on every request.
//!
//!   GET /                          the page (the site's dashboard.html; its other files)
//!   GET /api/state                 start time, document name and the items
//!   GET /api/score/<file>          diff numbers for one item
//!   GET /api/step/<file>?upto=N    the Nth node drawn and its device bounds
//!   GET /ref/<file>.png            Figma's export
//!   GET /ours/<file>.png[?upto=N]  our render, stopped after N nodes when given
//!   GET /diff/<file>.png           the heat map

const std = @import("std");
const engine = @import("publr_engine");
const corpus = @import("corpus.zig");

const m = engine.model;
const Io = std.Io;
const Dir = std.Io.Dir;
const IRect = engine.mask.IRect;
const Renderer = engine.render.Renderer;

/// Encoded PNGs kept past this many bytes are all dropped.
const cache_budget = 512 * 1024 * 1024;

/// One reference export that maps to a node.
const Item = struct {
    /// The reference's file name without `.png`, e.g. `27-51@1`.
    file: []const u8,
    /// The node id with ':', e.g. `27:51`.
    id: []const u8,
    node: *const m.Node,
    /// The scale in the file name.
    named_scale: f32,
    /// The scale rendered at: the reference width over the node width when the export
    /// came back smaller than asked.
    scale: f32,
    width: u32,
    height: u32,
    /// Nodes the full render draws.
    nodes: u32,
    /// The top-level frame the node sits in (itself when top-level), its depth below
    /// it, and the node's place in document order.
    top: *const m.Node = undefined,
    depth: u32 = 0,
    order: u32 = 0,
    score: ?Score = null,
};

const Place = struct {
    top: *const m.Node,
    depth: u32,
    order: u32,
};

/// Every node's top-level frame, depth and document order, by id.
fn places(gpa: std.mem.Allocator, pages: []const m.Node) !std.StringHashMapUnmanaged(Place) {
    var map: std.StringHashMapUnmanaged(Place) = .empty;
    var order: u32 = 0;
    for (pages) |*pg| for (pg.children) |*top| try placeWalk(gpa, &map, top, top, 0, &order);
    return map;
}

fn placeWalk(gpa: std.mem.Allocator, map: *std.StringHashMapUnmanaged(Place), n: *const m.Node, top: *const m.Node, depth: u32, order: *u32) !void {
    try map.put(gpa, n.id, .{
        .top = top,
        .depth = depth,
        .order = order.*,
    });
    order.* += 1;
    for (n.children) |*c| try placeWalk(gpa, map, c, top, depth + 1, order);
}

/// Diff numbers for one item, as `/api/score` returns them.
const Score = struct {
    file: []const u8,
    pixels: u64,
    mean: f64,
    within2: f64,
    within16: f64,
    non_text_within2: f64,
    visual: f64,
    ms: u64,
};

/// What the server holds for its whole run.
const State = struct {
    io: Io,
    gpa: std.mem.Allocator,
    loaded: corpus.Loaded,
    renders: []const u8,
    /// The UI build's folder.
    site_dir: []const u8,
    items: []Item,
    /// `/api/state`, built once at start.
    state_json: []u8,
    /// Guards everything below and the renders.
    mutex: Io.Mutex = .init,
    /// Encoded PNGs by key (`ours/<file>/<upto>`, `diff/<file>`).
    pngs: std.StringHashMapUnmanaged([]u8) = .empty,
    png_bytes: usize = 0,
    /// `/api/step` answers by `<file>/<upto>`.
    steps: std.StringHashMapUnmanaged([]u8) = .empty,

    fn find(s: *State, file: []const u8) ?*Item {
        for (s.items) |*it| if (std.mem.eql(u8, it.file, file)) return it;
        return null;
    }

    /// Keeps `bytes` (owned) under `key`, dropping every PNG first when over budget.
    fn keepPng(s: *State, key: []const u8, bytes: []u8) !void {
        if (s.png_bytes + bytes.len > cache_budget) {
            var it = s.pngs.iterator();
            while (it.next()) |e| {
                s.gpa.free(e.key_ptr.*);
                s.gpa.free(e.value_ptr.*);
            }
            s.pngs.clearRetainingCapacity();
            s.png_bytes = 0;
        }
        const k = try s.gpa.dupe(u8, key);
        errdefer s.gpa.free(k);
        try s.pngs.put(s.gpa, k, bytes);
        s.png_bytes += bytes.len;
    }
};

/// Runs the server until killed.
pub fn run(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, doc_dir: []const u8, renders: []const u8, rest: []const []const u8) !void {
    var port: u16 = 8400;
    var site_dir: []const u8 = "../editor/zig-out/site";
    var i: usize = 0;
    while (i + 1 < rest.len) : (i += 2) {
        if (std.mem.eql(u8, rest[i], "--port")) port = try std.fmt.parseInt(u16, rest[i + 1], 10);
        if (std.mem.eql(u8, rest[i], "--site")) site_dir = rest[i + 1];
    }

    const started = Io.Timestamp.now(io, .real).toMilliseconds();
    var s: State = .{
        .io = io,
        .gpa = gpa,
        .loaded = try corpus.load(io, gpa, doc_dir, .{}),
        .renders = renders,
        .site_dir = site_dir,
        .items = &.{},
        .state_json = &.{},
    };
    s.items = try listItems(&s);
    s.state_json = try stateJson(&s, started);

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try addr.listen(io, .{
        .reuse_address = true,
    });
    defer listener.deinit(io);
    try w.print("pe serve: {d} items from {s}, http://127.0.0.1:{d}/\n", .{ s.items.len, renders, port });
    try w.flush();

    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.log.err("accept: {t}", .{err});
            continue;
        };
        group.concurrent(io, serveConnection, .{ &s, stream }) catch serveConnection(&s, stream);
    }
}

/// Finds every `<id>@<scale>.png` under the renders folder whose node is in the document.
fn listItems(s: *State) ![]Item {
    const io = s.io;
    const gpa = s.gpa;
    const cwd = Dir.cwd();
    var items: std.ArrayList(Item) = .empty;
    var rd = try cwd.openDir(io, s.renders, .{
        .iterate = true,
    });
    defer rd.close(io);
    var it = rd.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".png")) continue;
        const base = e.name[0 .. e.name.len - 4];
        const at = std.mem.indexOfScalar(u8, base, '@') orelse continue;
        const named = std.fmt.parseFloat(f32, base[at + 1 ..]) catch continue;
        const id = try gpa.dupe(u8, base[0..at]);
        std.mem.replaceScalar(u8, id, '-', ':');
        const node = corpus.findNode(s.loaded.doc.pages, id) orelse {
            gpa.free(id);
            continue;
        };
        // The PNG header holds the size; no need to decode.
        var head: [24]u8 = undefined;
        const n = try rd.readFile(io, e.name, &head);
        const sn = corpus.sniff(n);
        if (sn.width == 0 or node.size.x <= 0) continue;
        const rw: f32 = @floatFromInt(sn.width);
        const scale = if (@abs(rw - node.size.x * named) > 1) rw / node.size.x else named;
        try items.append(gpa, .{
            .file = try gpa.dupe(u8, base),
            .id = id,
            .node = node,
            .named_scale = named,
            .scale = scale,
            .width = sn.width,
            .height = sn.height,
            .nodes = 0,
        });
    }
    var where = try places(gpa, s.loaded.doc.pages);
    defer where.deinit(gpa);
    for (items.items) |*item| if (where.get(item.id)) |pl| {
        item.top = pl.top;
        item.depth = pl.depth;
        item.order = pl.order;
    } else {
        item.top = item.node;
    };
    std.mem.sort(Item, items.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            if (a.order != b.order) return a.order < b.order;
            return a.named_scale < b.named_scale;
        }
    }.lt);
    // Count the nodes a full render draws: once per node, at 1x (cheap; the count barely
    // depends on scale, and /api/step reports the true number).
    for (items.items, 0..) |*item, k| {
        if (k > 0 and items.items[k - 1].node == item.node) {
            item.nodes = items.items[k - 1].nodes;
            continue;
        }
        var r = corpus.renderer(gpa, &s.loaded);
        defer r.deinit();
        var px = try r.renderExport(item.node, 1);
        px.deinit(gpa);
        item.nodes = r.drawn;
    }
    return items.toOwnedSlice(gpa);
}

fn stateJson(s: *State, started: i64) ![]u8 {
    const ItemJson = struct {
        file: []const u8,
        node: []const u8,
        name: []const u8,
        scale: f32,
        named_scale: f32,
        width: u32,
        height: u32,
        nodes: u32,
        top: []const u8,
        top_name: []const u8,
        depth: u32,
    };
    const out = try s.gpa.alloc(ItemJson, s.items.len);
    defer s.gpa.free(out);
    for (s.items, out) |it, *o| o.* = .{
        .file = it.file,
        .node = it.id,
        .name = it.node.name,
        .scale = it.scale,
        .named_scale = it.named_scale,
        .width = it.width,
        .height = it.height,
        .nodes = it.nodes,
        .top = it.top.id,
        .top_name = it.top.name,
        .depth = it.depth,
    };
    return std.json.Stringify.valueAlloc(s.gpa, .{
        .started = started,
        .doc = s.loaded.doc.name,
        .items = out,
    }, .{});
}

fn serveConnection(s: *State, stream: Io.net.Stream) void {
    const io = s.io;
    defer stream.close(io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);
    var server = std.http.Server.init(&sr.interface, &sw.interface);
    while (true) {
        var req = server.receiveHead() catch return;
        handle(s, &req) catch |err| {
            std.log.err("{s}: {t}", .{ req.head.target, err });
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "error: {t}\n", .{err}) catch "error\n";
            req.respond(msg, .{
                .status = .internal_server_error,
                .keep_alive = false,
            }) catch {};
            return;
        };
        if (!req.head.keep_alive) return;
    }
}

const no_store: std.http.Header = .{
    .name = "cache-control",
    .value = "no-store",
};

pub fn send(req: *std.http.Server.Request, body: []const u8, content_type: []const u8) !void {
    try req.respond(body, .{
        .extra_headers = &.{
            .{
                .name = "content-type",
                .value = content_type,
            },
            no_store,
        },
    });
}

pub fn notFound(req: *std.http.Server.Request) !void {
    try req.respond("not found\n", .{
        .status = .not_found,
    });
}

fn handle(s: *State, req: *std.http.Server.Request) !void {
    const target = req.head.target;
    const q = std.mem.indexOfScalar(u8, target, '?');
    // Browsers escape '@' in file names; decode into a copy (the head buffer stays intact).
    var path_buf: [512]u8 = undefined;
    const raw = target[0 .. q orelse target.len];
    if (raw.len > path_buf.len) return notFound(req);
    @memcpy(path_buf[0..raw.len], raw);
    const path = std.Uri.percentDecodeInPlace(path_buf[0..raw.len]);
    const query = if (q) |k| target[k + 1 ..] else "";
    const upto = queryInt(query, "upto");

    if (req.head.method != .GET and req.head.method != .HEAD) return notFound(req);
    if (std.mem.eql(u8, path, "/api/state")) return send(req, s.state_json, "application/json");

    if (strip(path, "/api/score/", "")) |file| {
        const item = s.find(file) orelse return notFound(req);
        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);
        const sc = try scoreItem(s, item);
        const json = try std.json.Stringify.valueAlloc(s.gpa, sc, .{});
        defer s.gpa.free(json);
        return send(req, json, "application/json");
    }
    if (strip(path, "/api/step/", "")) |file| {
        const item = s.find(file) orelse return notFound(req);
        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);
        const json = try step(s, item, upto orelse item.nodes);
        return send(req, json, "application/json");
    }
    if (strip(path, "/ref/", ".png")) |file| {
        const item = s.find(file) orelse return notFound(req);
        const p = try std.fmt.allocPrint(s.gpa, "{s}/{s}.png", .{ s.renders, item.file });
        defer s.gpa.free(p);
        const bytes = try Dir.cwd().readFileAlloc(s.io, p, s.gpa, .limited(corpus.max_file));
        defer s.gpa.free(bytes);
        return send(req, bytes, "image/png");
    }
    if (strip(path, "/ours/", ".png")) |file| {
        const item = s.find(file) orelse return notFound(req);
        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);
        return send(req, try ours(s, item, upto), "image/png");
    }
    if (strip(path, "/diff/", ".png")) |file| {
        const item = s.find(file) orelse return notFound(req);
        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);
        var key_buf: [128]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "diff/{s}", .{item.file});
        if (s.pngs.get(key) == null) _ = try computeScore(s, item);
        return send(req, s.pngs.get(key).?, "image/png");
    }
    return sendSite(s.io, s.gpa, req, s.site_dir, if (std.mem.eql(u8, path, "/")) "dashboard.html" else path[1..]);
}

/// A file of the UI build, read now (a rebuilt UI shows after a reload); 404 when it
/// cannot be read or the name leaves the folder.
pub fn sendSite(io: Io, gpa: std.mem.Allocator, req: *std.http.Server.Request, site_dir: []const u8, name: []const u8) !void {
    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOfScalar(u8, name, '\\') != null) return notFound(req);
    const p = try std.fs.path.join(gpa, &.{ site_dir, name });
    defer gpa.free(p);
    const bytes = Dir.cwd().readFileAlloc(io, p, gpa, .limited(corpus.max_file)) catch return notFound(req);
    defer gpa.free(bytes);
    return send(req, bytes, contentType(name));
}

/// The content type of a UI build file, by its extension.
pub fn contentType(name: []const u8) []const u8 {
    const types = [_][2][]const u8{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".wasm", "application/wasm" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
    };
    for (types) |t| if (std.mem.endsWith(u8, name, t[0])) return t[1];
    return "application/octet-stream";
}

/// `path` without `prefix` and `suffix`, when it has both.
pub fn strip(path: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    if (path.len < prefix.len + suffix.len) return null;
    return path[prefix.len .. path.len - suffix.len];
}

pub fn queryInt(query: []const u8, name: []const u8) ?u32 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return std.fmt.parseInt(u32, pair[eq + 1 ..], 10) catch null;
    }
    return null;
}

/// Renders `item` with `r` (limit already set) and returns RGBA8 at the reference's size.
fn renderRgba(item: *const Item, r: *Renderer, gpa: std.mem.Allocator) ![]u8 {
    var px = try r.renderExport(item.node, item.scale);
    defer px.deinit(gpa);
    const rect: IRect = .{
        .x1 = @intCast(item.width),
        .y1 = @intCast(item.height),
    };
    return px.toRgba8(gpa, rect);
}

fn scoreItem(s: *State, item: *Item) !Score {
    if (item.score) |sc| return sc;
    return computeScore(s, item);
}

/// Renders in full, compares with the reference, keeps the numbers and the heat map.
fn computeScore(s: *State, item: *Item) !Score {
    const gpa = s.gpa;
    const io = s.io;
    const p = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ s.renders, item.file });
    defer gpa.free(p);
    const ref_bytes = try Dir.cwd().readFileAlloc(io, p, gpa, .limited(corpus.max_file));
    defer gpa.free(ref_bytes);
    var ref = try engine.png.decode(gpa, ref_bytes);
    defer ref.deinit(gpa);

    var r = corpus.renderer(gpa, &s.loaded);
    defer r.deinit();
    const t0 = Io.Timestamp.now(io, .awake);
    const rgba = try renderRgba(item, &r, gpa);
    defer gpa.free(rgba);
    const ms: u64 = @intCast(@divTrunc(t0.untilNow(io, .awake).nanoseconds, std.time.ns_per_ms));

    const d = try engine.diff.compare(gpa, rgba, ref.pixels, ref.width, ref.height, r.text_bounds.items, r.image_bounds.items);
    defer gpa.free(d.heat);
    const sc: Score = .{
        .file = item.file,
        .pixels = d.pixels,
        .mean = d.mean,
        .within2 = pct(d.within2, d.pixels),
        .within16 = pct(d.within16, d.pixels),
        .non_text_within2 = pct(d.non_text_within2, d.non_text_pixels),
        .visual = pct(d.visual, d.pixels),
        .ms = ms,
    };
    item.score = sc;

    var key_buf: [128]u8 = undefined;
    const heat_png = try engine.png.encode(gpa, ref.width, ref.height, d.heat);
    try s.keepPng(try std.fmt.bufPrint(&key_buf, "diff/{s}", .{item.file}), heat_png);
    return sc;
}

/// Our render as PNG, from the cache or freshly drawn; also records the step answer.
fn ours(s: *State, item: *Item, upto: ?u32) ![]const u8 {
    var key_buf: [128]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "ours/{s}/{d}", .{ item.file, upto orelse std.math.maxInt(u32) });
    if (s.pngs.get(key)) |b| return b;
    var r = corpus.renderer(s.gpa, &s.loaded);
    defer r.deinit();
    r.limit = upto;
    const rgba = try renderRgba(item, &r, s.gpa);
    defer s.gpa.free(rgba);
    if (upto) |n| try keepStep(s, item, n, &r);
    const bytes = try engine.png.encode(s.gpa, item.width, item.height, rgba);
    try s.keepPng(key, bytes);
    return bytes;
}

/// The step answer for `upto`; draws (and caches the PNG) when not known yet.
fn step(s: *State, item: *Item, upto: u32) ![]const u8 {
    var key_buf: [128]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "{s}/{d}", .{ item.file, upto });
    if (s.steps.get(key)) |j| return j;
    _ = try ours(s, item, upto);
    return s.steps.get(key).?;
}

fn keepStep(s: *State, item: *const Item, upto: u32, r: *const Renderer) !void {
    const NodeJson = struct {
        id: []const u8,
        name: []const u8,
        type: []const u8,
    };
    const b = r.last_bounds;
    const node: ?NodeJson = if (r.last_node) |n| .{
        .id = n.id,
        .name = n.name,
        .type = @tagName(n.kind),
    } else null;
    const json = try std.json.Stringify.valueAlloc(s.gpa, .{
        .drawn = r.drawn,
        .node = node,
        .bounds = [4]i32{ b.x0, b.y0, b.x1, b.y1 },
    }, .{});
    errdefer s.gpa.free(json);
    const key = try std.fmt.allocPrint(s.gpa, "{s}/{d}", .{ item.file, upto });
    errdefer s.gpa.free(key);
    const gop = try s.steps.getOrPut(s.gpa, key);
    if (gop.found_existing) {
        s.gpa.free(key);
        s.gpa.free(gop.value_ptr.*);
    }
    gop.value_ptr.* = json;
}

fn pct(a: u64, b: u64) f64 {
    return 100 * @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(@max(b, 1)));
}
