//! `pe view`: serves PublrDesign's UI build (the file browser and the viewer; `zig build`
//! in ../editor writes it to ../editor/zig-out/site), the engine's WASM build, the fonts
//! and, when given, one document, so the page can open documents and render them in WASM.
//! The files the page imports or creates live in the browser (OPFS), never here; the
//! document given here shows among them as a file served from disk, read-only.
//!
//!   pe view [doc.pubd-dir | file.fig] [--port 8402] [--site DIR] [--wasm FILE]
//!
//! Binds 127.0.0.1. Files are read on every request, so a rebuilt WASM or UI shows after
//! a reload. Fonts come from the document's folder (or `corpus/` without one).
//!
//!   GET /, /fonts, /file/<id>,      the page
//!       /content/<doc>              (the site's index.html; its other files)
//!   GET /publr_engine.wasm          the engine
//!   GET /api/fonts                  font URLs by role
//!   GET /api/doc                    the served document: kind, name, URLs, assets, fonts
//!                                   by role; `null` without one
//!   GET /doc/document.json          a .pubd document
//!   GET /doc/pages/<file>.json      its pages (a document kept page by page)
//!   GET /doc/assets/<hash>          its assets
//!   GET /doc/file.fig               a .fig document
//!   GET /fonts/<n>/<name>           font file n of /api/doc's lists
//!   GET /api/render?node=ID&scale=S the node exported natively (as `pe render` draws it),
//!                                   raw RGBA8 with x-width and x-height headers

const std = @import("std");
const engine = @import("publr_engine");
const corpus = @import("corpus.zig");
const serve = @import("serve.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

const State = struct {
    io: Io,
    gpa: std.mem.Allocator,
    /// The `.pubd` folder or the `.fig` file; null when none is served.
    doc_path: ?[]const u8,
    is_fig: bool,
    /// The UI build's folder.
    site_dir: []const u8,
    wasm_path: []const u8,
    /// Every font file, faces then fallbacks then variable fonts (`/fonts/<n>`).
    font_paths: []const []const u8,
    /// `/api/doc`, built once.
    doc_json: []const u8,
    /// `/api/fonts`, built once.
    fonts_json: []const u8,
    /// The document loaded natively for `/api/render`, on first use.
    native: ?Native = null,
    mutex: Io.Mutex = .init,
    /// `--dev-file`: a file of this machine the page may fetch (`/dev/file`), for testing
    /// the import with files too large to hand to a test browser otherwise.
    dev_file: ?[]const u8 = null,
};

/// The document as the native tools load it.
const Native = union(enum) {
    /// A `.pubd`: exactly what `pe render` loads.
    pubd: corpus.Loaded,
    /// A `.fig`: the session imports it as the browser does.
    fig: *engine.session.Session,
};

/// Runs the server until killed.
pub fn run(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, doc_path: ?[]const u8, rest: []const []const u8) !void {
    var port: u16 = 8402;
    var site_dir: []const u8 = "../editor/zig-out/site";
    var wasm_path: []const u8 = "zig-out/web/publr_engine.wasm";
    var dev_file: ?[]const u8 = null;
    var i: usize = 0;
    while (i + 1 < rest.len) : (i += 2) {
        if (std.mem.eql(u8, rest[i], "--port")) port = try std.fmt.parseInt(u16, rest[i + 1], 10);
        if (std.mem.eql(u8, rest[i], "--site")) site_dir = rest[i + 1];
        if (std.mem.eql(u8, rest[i], "--wasm")) wasm_path = rest[i + 1];
        if (std.mem.eql(u8, rest[i], "--dev-file")) dev_file = rest[i + 1];
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const is_fig = if (doc_path) |p| std.mem.endsWith(u8, p, ".fig") else false;
    // Fonts are found from the document's folder (a .fig: the folder holding it).
    const font_from = if (doc_path) |p| (if (is_fig) std.fs.path.dirname(p) orelse "." else p) else "corpus";
    const files = try corpus.fontFiles(io, arena, font_from);
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(arena, files.faces);
    try all.appendSlice(arena, files.fallbacks);
    try all.appendSlice(arena, files.variable);

    var s: State = .{
        .io = io,
        .gpa = gpa,
        .doc_path = doc_path,
        .is_fig = is_fig,
        .site_dir = site_dir,
        .wasm_path = wasm_path,
        .dev_file = dev_file,
        .font_paths = all.items,
        .doc_json = if (doc_path) |p| try docJson(io, arena, p, is_fig, files) else "null",
        .fonts_json = try std.json.Stringify.valueAlloc(arena, try fontUrls(arena, files), .{}),
    };
    defer if (s.native) |*n| switch (n.*) {
        .pubd => |*l| l.deinit(gpa),
        .fig => |ses| ses.destroy(),
    };

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try addr.listen(io, .{
        .reuse_address = true,
    });
    defer listener.deinit(io);
    try w.print("pe view: {s} ({d} fonts), http://127.0.0.1:{d}/\n", .{ doc_path orelse "no document", all.items.len, port });
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

/// Font URLs by role (`/fonts/<n>/<name>`, numbered faces then fallbacks then variable).
const FontUrls = struct {
    faces: [][]const u8,
    fallbacks: [][]const u8,
    variable: [][]const u8,
};

fn fontUrls(arena: std.mem.Allocator, files: corpus.FontFiles) !FontUrls {
    var n: usize = 0;
    const lists = [_][]const []const u8{ files.faces, files.fallbacks, files.variable };
    var urls: [3][][]const u8 = undefined;
    for (lists, &urls) |list, *out| {
        out.* = try arena.alloc([]const u8, list.len);
        for (list, out.*) |fp, *u| {
            u.* = try std.fmt.allocPrint(arena, "/fonts/{d}/{s}", .{ n, std.fs.path.basename(fp) });
            n += 1;
        }
    }
    return .{
        .faces = urls[0],
        .fallbacks = urls[1],
        .variable = urls[2],
    };
}

/// `/api/doc`: the document's kind, name (its file name without the extension) and URL,
/// its asset hashes, and the font URLs by role.
fn docJson(io: Io, arena: std.mem.Allocator, doc_path: []const u8, is_fig: bool, files: corpus.FontFiles) ![]const u8 {
    var assets: std.ArrayList([]const u8) = .empty;
    if (!is_fig) {
        const p = try std.fs.path.join(arena, &.{ doc_path, "assets" });
        if (Dir.cwd().openDir(io, p, .{
            .iterate = true,
        })) |d_const| {
            var d = d_const;
            defer d.close(io);
            var it = d.iterate();
            while (try it.next(io)) |e| if (e.kind == .file and isHash(e.name)) try assets.append(arena, try arena.dupe(u8, e.name));
        } else |_| {}
    }
    const base = std.fs.path.basename(std.mem.trimEnd(u8, doc_path, "/"));
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| (if (dot > 0) base[0..dot] else base) else base;
    return std.json.Stringify.valueAlloc(arena, .{
        .kind = if (is_fig) "fig" else "pubd",
        .name = stem,
        .url = if (is_fig) "/doc/file.fig" else "/doc/document.json",
        .assets = assets.items,
        .fonts = try fontUrls(arena, files),
    }, .{});
}

/// A lowercase hex SHA-256: the only names served from `assets/`.
fn isHash(name: []const u8) bool {
    if (name.len != 64) return false;
    for (name) |c| if (!std.ascii.isHex(c)) return false;
    return true;
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

fn contentType(name: []const u8) []const u8 {
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

/// Sends a file read now; 404 when it cannot be read.
fn sendFile(s: *State, req: *std.http.Server.Request, path: []const u8, content_type: []const u8) !void {
    const bytes = Dir.cwd().readFileAlloc(s.io, path, s.gpa, .limited(corpus.max_file)) catch return serve.notFound(req);
    defer s.gpa.free(bytes);
    return serve.send(req, bytes, content_type);
}

fn handle(s: *State, req: *std.http.Server.Request) !void {
    if (req.head.method != .GET and req.head.method != .HEAD) return serve.notFound(req);
    const target = req.head.target;
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. q orelse target.len];
    const query = if (q) |k| target[k + 1 ..] else "";
    var buf: [1024]u8 = undefined;

    if (std.mem.eql(u8, path, "/api/doc")) return serve.send(req, s.doc_json, "application/json");
    if (std.mem.eql(u8, path, "/api/fonts")) return serve.send(req, s.fonts_json, "application/json");
    if (std.mem.eql(u8, path, "/dev/file")) {
        // Streamed: the file may be larger than memory.
        const path_ = s.dev_file orelse return serve.notFound(req);
        const file = Dir.cwd().openFile(s.io, path_, .{}) catch return serve.notFound(req);
        defer file.close(s.io);
        const size = try file.length(s.io);
        var out_buf: [64 * 1024]u8 = undefined;
        var body = try req.respondStreaming(&out_buf, .{
            .content_length = size,
            .respond_options = .{
                .extra_headers = &.{.{
                    .name = "content-type",
                    .value = "application/octet-stream",
                }},
            },
        });
        const chunk = try s.gpa.alloc(u8, 4 << 20);
        defer s.gpa.free(chunk);
        var at: u64 = 0;
        while (at < size) {
            const n = try file.readPositionalAll(s.io, chunk[0..@intCast(@min(chunk.len, size - at))], at);
            if (n == 0) break;
            try body.writer.writeAll(chunk[0..n]);
            at += n;
        }
        try body.end();
        return;
    }
    if (std.mem.eql(u8, path, "/publr_engine.wasm")) return sendFile(s, req, s.wasm_path, "application/wasm");
    if (std.mem.eql(u8, path, "/doc/document.json") and !s.is_fig) {
        const doc_path = s.doc_path orelse return serve.notFound(req);
        const p = try std.fmt.bufPrint(&buf, "{s}/document.json", .{doc_path});
        return sendFile(s, req, p, "application/json");
    }
    if (serve.strip(path, "/doc/pages/", "")) |file| {
        // A document kept page by page: its page files.
        const doc_path = s.doc_path orelse return serve.notFound(req);
        if (s.is_fig or file.len == 0 or std.mem.indexOf(u8, file, "..") != null or std.mem.indexOfAny(u8, file, "/\\") != null) return serve.notFound(req);
        const p = try std.fmt.bufPrint(&buf, "{s}/pages/{s}", .{ doc_path, file });
        return sendFile(s, req, p, "application/json");
    }
    if (std.mem.eql(u8, path, "/doc/file.fig") and s.is_fig) return sendFile(s, req, s.doc_path.?, "application/octet-stream");
    if (serve.strip(path, "/doc/assets/", "")) |hash| {
        const doc_path = s.doc_path orelse return serve.notFound(req);
        if (s.is_fig or !isHash(hash)) return serve.notFound(req);
        const p = try std.fmt.bufPrint(&buf, "{s}/assets/{s}", .{ doc_path, hash });
        return sendFile(s, req, p, "application/octet-stream");
    }
    if (serve.strip(path, "/fonts/", "")) |rest| {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const n = std.fmt.parseInt(usize, rest[0..slash], 10) catch return serve.notFound(req);
        if (n >= s.font_paths.len) return serve.notFound(req);
        return sendFile(s, req, s.font_paths[n], "font/ttf");
    }
    if (std.mem.eql(u8, path, "/api/render")) {
        if (s.doc_path == null) return serve.notFound(req);
        return renderNative(s, req, query);
    }

    // The UI build's files (no way up out of its folder). The page routes `/file/<id>`
    // and `/content/<doc>` itself (history API), so those paths serve it too and a reload lands back there.
    const name = if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/fonts") or std.mem.startsWith(u8, path, "/file/") or std.mem.startsWith(u8, path, "/content/")) "index.html" else path[1..];
    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOfScalar(u8, name, '\\') != null) return serve.notFound(req);
    const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ s.site_dir, name });
    return sendFile(s, req, p, contentType(name));
}

/// The value of `name` in a query string, percent-decoded into `buf`.
fn queryStr(query: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        const v = pair[eq + 1 ..];
        if (v.len > buf.len) return null;
        @memcpy(buf[0..v.len], v);
        return std.Uri.percentDecodeInPlace(buf[0..v.len]);
    }
    return null;
}

/// `/api/render`: the node exported by the native engine, for checking the WASM build.
fn renderNative(s: *State, req: *std.http.Server.Request, query: []const u8) !void {
    var id_buf: [256]u8 = undefined;
    var scale_buf: [32]u8 = undefined;
    const id = queryStr(query, "node", &id_buf) orelse return serve.notFound(req);
    const scale = std.fmt.parseFloat(f32, queryStr(query, "scale", &scale_buf) orelse "1") catch 1;
    const gpa = s.gpa;

    try s.mutex.lock(s.io);
    defer s.mutex.unlock(s.io);
    if (s.native == null) s.native = try loadNative(s);
    var px = switch (s.native.?) {
        .pubd => |*l| blk: {
            const node = corpus.findNode(l.doc.pages, id) orelse return serve.notFound(req);
            var r = corpus.renderer(gpa, l);
            defer r.deinit();
            break :blk try r.renderExport(node, scale);
        },
        .fig => |ses| ses.renderNode(id, scale) catch return serve.notFound(req),
    };
    defer px.deinit(gpa);
    const rgba = try px.toRgba8(gpa, px.rect);
    defer gpa.free(rgba);
    var wb: [16]u8 = undefined;
    var hb: [16]u8 = undefined;
    try req.respond(rgba, .{
        .extra_headers = &.{
            .{
                .name = "content-type",
                .value = "application/octet-stream",
            },
            .{
                .name = "x-width",
                .value = try std.fmt.bufPrint(&wb, "{d}", .{px.rect.width()}),
            },
            .{
                .name = "x-height",
                .value = try std.fmt.bufPrint(&hb, "{d}", .{px.rect.height()}),
            },
            .{
                .name = "cache-control",
                .value = "no-store",
            },
        },
    });
}

fn loadNative(s: *State) !Native {
    const doc_path = s.doc_path orelse return error.NoDocument;
    if (!s.is_fig) return .{
        .pubd = try corpus.load(s.io, s.gpa, doc_path, .{}),
    };
    const ses = try engine.session.Session.create(s.gpa);
    errdefer ses.destroy();
    const bytes = try Dir.cwd().readFileAlloc(s.io, doc_path, s.gpa, .limited(1 << 30));
    defer s.gpa.free(bytes);
    try ses.loadFig(bytes);
    var scratch: std.heap.ArenaAllocator = .init(s.gpa);
    defer scratch.deinit();
    const font_from = std.fs.path.dirname(doc_path) orelse ".";
    const files = try corpus.fontFiles(s.io, scratch.allocator(), font_from);
    const lists = [_][]const []const u8{ files.faces, files.fallbacks, files.variable };
    const roles = [_]engine.fonts.Role{ .face, .fallback, .variable };
    for (lists, roles) |list, role| for (list) |fp| {
        const fb = Dir.cwd().readFileAlloc(s.io, fp, scratch.allocator(), .limited(64 * 1024 * 1024)) catch continue;
        _ = try ses.addFont(fb, role);
    };
    return .{
        .fig = ses,
    };
}
