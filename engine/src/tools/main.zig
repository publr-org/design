//! `pe`: PublrEngine on the command line.
//!
//!   pe import-figma <file.json> <images-dir> <out.pubd-dir>
//!   pe import-fig <file.fig> <out.pubd-dir>
//!   pe fig-dump <file.fig> <type | field>
//!   pe render <doc.pubd-dir> <node-id> <scale> <out.png>
//!   pe score <doc.pubd-dir> <renders-dir> [out-dir]
//!   pe decode <image> <out.png>
//!   pe serve [doc.pubd-dir renders-dir] [--port 8400] [--site DIR]
//!   pe view [doc.pubd-dir | file.fig] [--port 8402]
//!   pe tilecheck <doc.pubd-dir> <node-id> <scale>...
//!   pe gpuscene <doc.pubd-dir> [scale]
//!   pe gpubench <doc.pubd-dir> <page-id | index> [width height]
//!   pe layout-check <doc.pubd-dir> [--show N] [--instances] [--incremental N] [--text]
//!
//! A `.pubd` folder holds `document.json` and `assets/<sha256>`.

const std = @import("std");
const engine = @import("publr_engine");

const m = engine.model;
const Io = std.Io;
const Dir = std.Io.Dir;

const corpus = @import("corpus.zig");
const serve = @import("serve.zig");
const view = @import("view.zig");
const tilecheck = @import("tilecheck.zig");
const gpuscene = @import("gpuscene.zig");
const gpubench = @import("gpubench.zig");
const layout_check = @import("layout_check.zig");
const max_file = corpus.max_file;
const sniff = corpus.sniff;
const load = corpus.load;
const findNode = corpus.findNode;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // `PE_TEXT_AA=exact|grid16|standard16` picks text anti-aliasing (for matching).
    if (init.environ_map.get("PE_TEXT_AA")) |v| {
        engine.render.text_aa = std.meta.stringToEnum(engine.render.Aa, v) orelse engine.render.text_aa;
    }
    if (init.environ_map.get("PE_SHAPE_AA")) |v| {
        engine.render.shape_aa = std.meta.stringToEnum(engine.render.Aa, v) orelse engine.render.shape_aa;
    }
    // `PE_PATTERN=x,y,x,y,...` sets the custom sample pattern (pixel fractions).
    if (init.environ_map.get("PE_PATTERN")) |v| {
        var list: std.ArrayList([2]f32) = .empty;
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |xs| {
            const ys = it.next() orelse break;
            try list.append(arena, .{ try std.fmt.parseFloat(f32, xs), try std.fmt.parseFloat(f32, ys) });
        }
        engine.render.custom_pattern = list.items;
    }
    // `PE_XBINS=<n>` snaps glyph x to 1/n pixel (0 = off).
    if (init.environ_map.get("PE_XBINS")) |v| engine.render.glyph_x_bins = std.fmt.parseFloat(f32, v) catch 0;
    if (init.environ_map.get("PE_SHK")) |v| engine.render.shadow_k = std.fmt.parseFloat(f32, v) catch 0.4375;
    if (init.environ_map.get("PE_NATIVE_STROKES")) |v| engine.render.use_stroke_outlines = !(v.len > 0 and v[0] == '1');
    if (init.environ_map.get("PE_SKIPBLEND") != null) engine.render.skip_blended_paints = true;
    if (init.environ_map.get("PE_BBCLAMP")) |v| engine.render.background_blur_clamp = v[0] == '1';
    if (init.environ_map.get("PE_LBK")) |v| engine.render.layer_blur_k = std.fmt.parseFloat(f32, v) catch 0.5;
    if (init.environ_map.get("PE_BBK")) |v| engine.render.background_blur_k = std.fmt.parseFloat(f32, v) catch 0.5;
    // `PE_COARSE_SIGMA=<px>`: blurs wider than this go to the coarse grid (huge: never).
    if (init.environ_map.get("PE_COARSE_SIGMA")) |v| engine.render.coarse_sigma = std.fmt.parseFloat(f32, v) catch engine.render.coarse_sigma;
    if (init.environ_map.get("PE_ADV")) |v| {
        engine.layout.advance_floor = v[0] == 'f';
        engine.layout.advance_steps = std.fmt.parseFloat(f32, if (v[0] == 'f' or v[0] == 'r') v[1..] else v) catch 0;
    }
    if (init.environ_map.get("PE_UPEM")) |v| {
        engine.layout.advance_upem_floor = v[0] == 'f';
        engine.layout.advance_upem = std.fmt.parseFloat(f32, if (v[0] == 'f' or v[0] == 'r') v[1..] else v) catch 0;
    }
    // `PE_SC=<scale>,<tracking>` overrides synthesised small caps (for tuning).
    if (init.environ_map.get("PE_SC")) |v| {
        var it = std.mem.splitScalar(u8, v, ',');
        engine.layout.small_caps_scale = std.fmt.parseFloat(f32, it.next() orelse "") catch engine.layout.small_caps_scale;
        engine.layout.small_caps_tracking = std.fmt.parseFloat(f32, it.next() orelse "") catch engine.layout.small_caps_tracking;
    }
    // `PE_SKIPINK=<band>,<pad>` overrides underline skip-ink (for tuning; `0` turns it off).
    if (init.environ_map.get("PE_SKIPINK")) |v| {
        var it = std.mem.splitScalar(u8, v, ',');
        const band = it.next() orelse "";
        if (std.mem.eql(u8, band, "0")) engine.layout.skip_ink = false;
        engine.layout.skip_ink_band = std.fmt.parseFloat(f32, band) catch engine.layout.skip_ink_band;
        engine.layout.skip_ink_pad = std.fmt.parseFloat(f32, it.next() orelse "") catch engine.layout.skip_ink_pad;
    }

    var out_buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    if (args.len >= 5 and std.mem.eql(u8, args[1], "import-figma")) {
        return importFigma(io, gpa, w, args[2], args[3], args[4]);
    }
    if (args.len >= 4 and std.mem.eql(u8, args[1], "fig-dump")) {
        return figDump(io, gpa, w, args[2], args[3]);
    }
    if (args.len >= 4 and std.mem.eql(u8, args[1], "import-fig")) {
        return importFig(io, gpa, w, args[2], args[3]);
    }
    if (args.len >= 6 and std.mem.eql(u8, args[1], "render")) {
        const scale = try std.fmt.parseFloat(f32, args[4]);
        return render(io, gpa, w, args[2], args[3], scale, args[5]);
    }
    if (args.len >= 4 and std.mem.eql(u8, args[1], "shape")) {
        return shapeCmd(io, gpa, w, args[2], args[3]);
    }
    if (args.len >= 4 and std.mem.eql(u8, args[1], "decode")) {
        return decodeCmd(io, gpa, w, args[2], args[3]);
    }
    if (args.len >= 4 and std.mem.eql(u8, args[1], "score")) {
        return score(io, gpa, w, args[2], args[3], if (args.len >= 5) args[4] else null);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "serve")) {
        // Without both paths the page serves the landing corpus.
        const has_paths = args.len >= 4 and !std.mem.startsWith(u8, args[2], "--");
        if (!has_paths) return serve.run(io, gpa, w, "corpus/landing/landing.pubd", "corpus/landing/renders", args[2..]);
        return serve.run(io, gpa, w, args[2], args[3], args[4..]);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "view")) {
        // The document is optional: without one the page is the file browser alone.
        const has_doc = args.len >= 3 and !std.mem.startsWith(u8, args[2], "--");
        return view.run(io, gpa, w, if (has_doc) args[2] else null, args[if (has_doc) 3 else 2..]);
    }
    if (args.len >= 4 and std.mem.eql(u8, args[1], "gpubench")) {
        return gpubench.run(io, gpa, w, args[2], args[3..]);
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "gpuscene")) {
        return gpuscene.run(io, gpa, w, args[2], args[3..]);
    }
    if (args.len >= 5 and std.mem.eql(u8, args[1], "tilecheck")) {
        return tilecheck.run(io, gpa, w, args[2], args[3], args[4..]);
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "layout-check")) {
        return layout_check.run(io, gpa, w, args[2], args[3..]);
    }
    try w.writeAll(
        \\usage:
        \\  pe import-figma <file.json> <images-dir> <out.pubd-dir>
        \\  pe import-fig <file.fig> <out.pubd-dir>
        \\  pe fig-dump <file.fig> <type | field>
        \\  pe render <doc.pubd-dir> <node-id> <scale> <out.png>
        \\  pe score <doc.pubd-dir> <renders-dir> [out-dir]
        \\  pe serve [doc.pubd-dir renders-dir] [--port 8400] [--site DIR]
        \\  pe view [doc.pubd-dir | file.fig] [--port 8402]
        \\  pe tilecheck <doc.pubd-dir> <node-id> <scale>...
        \\  pe layout-check <doc.pubd-dir> [--show N] [--instances] [--incremental N] [--text]
        \\
    );
    try w.flush();
    std.process.exit(2);
}

fn importFigma(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, json_path: []const u8, images_dir: []const u8, out_dir: []const u8) !void {
    const cwd = Dir.cwd();
    const json = try cwd.readFileAlloc(io, json_path, gpa, .limited(max_file));
    defer gpa.free(json);
    var result = try engine.figma.import(gpa, json);
    defer result.doc.deinit();
    const a = result.doc.arena.allocator();

    try cwd.createDirPath(io, out_dir);
    const assets_path = try std.fs.path.join(gpa, &.{ out_dir, "assets" });
    defer gpa.free(assets_path);
    try cwd.createDirPath(io, assets_path);

    var assets: std.ArrayList(m.Asset) = .empty;
    var missing: usize = 0;
    for (result.images) |*im| {
        const src = try std.fs.path.join(gpa, &.{ images_dir, im.ref });
        defer gpa.free(src);
        const bytes = cwd.readFileAlloc(io, src, gpa, .limited(max_file)) catch {
            missing += 1;
            continue;
        };
        defer gpa.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        im.hash = try a.dupe(u8, &hex);
        const kind = sniff(bytes);
        try assets.append(a, .{
            .hash = im.hash,
            .type = kind.type,
            .width = kind.width,
            .height = kind.height,
        });
        const dst = try std.fs.path.join(gpa, &.{ assets_path, &hex });
        defer gpa.free(dst);
        try cwd.writeFile(io, .{
            .sub_path = dst,
            .data = bytes,
        });
    }
    engine.figma.resolveImages(&result.doc, result.images);
    result.doc.assets = assets.items;

    const out = engine.pubd_write.toJson(gpa, &result.doc) catch |e| return explain(w, &result.doc, e);
    defer gpa.free(out);
    const doc_path = try std.fs.path.join(gpa, &.{ out_dir, "document.json" });
    defer gpa.free(doc_path);
    try cwd.writeFile(io, .{
        .sub_path = doc_path,
        .data = out,
    });
    try w.print("{s}: {d} pages, {d} assets ({d} missing), {d} bytes\n", .{ doc_path, result.doc.pages.len, assets.items.len, missing, out.len });
}

/// `pe import-fig`: a `.fig` file (the zip Figma saves) to a `.pubd` folder kept page by
/// page (`document.json`, `pages/<id>.json`, `assets/<sha256>`). Streams: the zip's
/// directory, the canvas and one image or one page at a time are in memory, never the
/// whole file, so any size imports (zip64 included).
/// `pe fig-dump <file.fig> <filter>`: the node records of a `.fig` whose type is
/// `filter` (`VARIABLE_SET`) or that have a field named `filter` (`styleType`), a JSON
/// line each (debugging the importer).
fn figDump(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, fig_path: []const u8, filter: []const u8) !void {
    const C = engine.fig_container;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file = try Dir.cwd().openFile(io, fig_path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const tail = try arena.alloc(u8, @intCast(@min(size, C.max_tail)));
    _ = try file.readPositionalAll(io, tail, size - tail.len);
    const dir = try C.findDirectory(tail, size);
    const cd = try arena.alloc(u8, @intCast(dir.size));
    _ = try file.readPositionalAll(io, cd, dir.offset);
    const items = try C.listDirectory(arena, cd, dir.count);
    var canvas: ?[]const u8 = null;
    for (items) |it| {
        if (std.mem.eql(u8, it.name, "canvas.fig")) canvas = try readEntry(io, arena, file, it);
    }
    const job = try engine.fig_stream.Job.create(gpa, canvas orelse return error.NotAFigFile, null);
    defer job.destroy();
    try job.im.dump(w, filter);
}

fn importFig(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, fig_path: []const u8, out_dir: []const u8) !void {
    const cwd = Dir.cwd();
    const C = engine.fig_container;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t0 = Io.Timestamp.now(io, .awake);

    const file = try cwd.openFile(io, fig_path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const tail = try arena.alloc(u8, @intCast(@min(size, C.max_tail)));
    _ = try file.readPositionalAll(io, tail, size - tail.len);
    const dir = try C.findDirectory(tail, size);
    const cd = try arena.alloc(u8, @intCast(dir.size));
    _ = try file.readPositionalAll(io, cd, dir.offset);
    const items = try C.listDirectory(arena, cd, dir.count);

    var canvas: ?[]const u8 = null;
    var meta: ?[]const u8 = null;
    for (items) |it| {
        if (std.mem.eql(u8, it.name, "canvas.fig")) canvas = try readEntry(io, arena, file, it);
        if (std.mem.eql(u8, it.name, "meta.json")) meta = try readEntry(io, arena, file, it);
    }
    const job = try engine.fig_stream.Job.create(gpa, canvas orelse return error.NotAFigFile, meta);
    defer job.destroy();

    const assets_path = try std.fs.path.join(arena, &.{ out_dir, "assets" });
    try cwd.createDirPath(io, assets_path);
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ out_dir, "pages" }));
    var images: usize = 0;
    for (items) |it| {
        if (!std.mem.startsWith(u8, it.name, "images/")) continue;
        if (!try job.im.namesImage(it.name["images/".len..])) continue;
        const bytes = try readEntry(io, gpa, file, it);
        defer gpa.free(bytes);
        const hash = try job.addImage(it.name["images/".len..], bytes);
        try cwd.writeFile(io, .{
            .sub_path = try std.fs.path.join(arena, &.{ assets_path, hash }),
            .data = bytes,
        });
        images += 1;
    }
    var total: usize = 0;
    for (0..job.pageCount()) |i| {
        const pg = job.pageJson(gpa, i) catch |e| return explainPage(w, e);
        defer gpa.free(pg.json);
        try cwd.writeFile(io, .{
            .sub_path = try std.fs.path.join(arena, &.{ out_dir, pg.path }),
            .data = pg.json,
        });
        total += pg.json.len;
    }
    const doc_json = try job.documentJson(gpa);
    defer gpa.free(doc_json);
    const doc_path = try std.fs.path.join(arena, &.{ out_dir, "document.json" });
    try cwd.writeFile(io, .{
        .sub_path = doc_path,
        .data = doc_json,
    });
    const ms = @divTrunc(t0.untilNow(io, .awake).nanoseconds, std.time.ns_per_ms);
    try w.print("{s}: canvas v{d}, {d} pages ({d} bytes), {d} images, {d} bytes, {d} ms\n", .{ doc_path, job.im.version, job.pageCount(), total, images, doc_json.len, ms });
    if (job.im.variables.len > 0) {
        var modes: usize = 0;
        var library: usize = 0;
        for (job.im.collections) |c| modes += c.modes.len;
        for (job.im.collections) |c| library += @intFromBool(c.library);
        try w.print("  variables: {d} in {d} collections ({d} from libraries, {d} modes), {d} bindings, {d} nodes re-resolved\n", .{ job.im.variables.len, job.im.collections.len, library, modes, job.im.bindingCount(), job.im.resolved });
    }
    for (try job.skipped()) |sk| try w.print("  skipped {d} {s}\n", .{ sk.count, sk.type });
}

/// A zip entry's bytes, read from the file (and inflated when deflated).
fn readEntry(io: Io, a: std.mem.Allocator, file: Io.File, it: engine.fig_container.Item) ![]u8 {
    const C = engine.fig_container;
    var head: [30]u8 = undefined;
    _ = try file.readPositionalAll(io, &head, it.local);
    const start = it.local + try C.dataStart(&head);
    const raw = try a.alloc(u8, @intCast(it.csize));
    _ = try file.readPositionalAll(io, raw, start);
    if (it.method == 0) return raw;
    defer a.free(raw);
    if (it.method != 8) return error.UnsupportedZip;
    return C.inflateRaw(a, raw, @intCast(@min(it.size, C.max_inflated)));
}

fn explainPage(w: *Io.Writer, e: anyerror) anyerror {
    if (e == error.NotFinite) try w.print("not written: a page holds a number that is not finite\n", .{});
    return e;
}

/// Says which node and field hold a number that is not finite before failing with `e`.
fn explain(w: *Io.Writer, doc: *const m.Document, e: anyerror) anyerror {
    if (e == error.NotFinite) if (m.findNotFinite(doc)) |nf| {
        var buf: [256]u8 = undefined;
        try w.print("not written: {s}\n", .{nf.describe(&buf)});
        try w.flush();
    };
    return e;
}

fn render(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, dir: []const u8, id: []const u8, scale: f32, out_path: []const u8) !void {
    var loaded = try load(io, gpa, dir, .{});
    defer loaded.deinit(gpa);
    const node = findNode(loaded.doc.pages, id) orelse return error.NodeNotFound;
    var r = corpus.renderer(gpa, &loaded);
    defer r.deinit();
    const t0 = Io.Timestamp.now(io, .awake);
    var px = try r.renderExport(node, scale);
    defer px.deinit(gpa);
    const ms: u64 = @intCast(@divTrunc(t0.untilNow(io, .awake).nanoseconds, std.time.ns_per_ms));
    const rgba = try px.toRgba8(gpa, px.rect);
    defer gpa.free(rgba);
    const bytes = try engine.png.encode(gpa, px.rect.width(), px.rect.height(), rgba);
    defer gpa.free(bytes);
    try Dir.cwd().writeFile(io, .{
        .sub_path = out_path,
        .data = bytes,
    });
    try w.print("{s}: {d}x{d} in {d} ms\n", .{ out_path, px.rect.width(), px.rect.height(), ms });
}

fn score(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, dir: []const u8, renders: []const u8, out_dir: ?[]const u8) !void {
    var loaded = try load(io, gpa, dir, .{});
    defer loaded.deinit(gpa);
    const cwd = Dir.cwd();
    if (out_dir) |o| try cwd.createDirPath(io, o);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var rd = try cwd.openDir(io, renders, .{
        .iterate = true,
    });
    defer rd.close(io);
    var it = rd.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".png")) continue;
        try names.append(gpa, try gpa.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    try w.print("{s:<14} {s:<22} {s:>11} {s:>8} {s:>8} {s:>8} {s:>9} {s:>8} {s:>7}\n", .{ "node", "name", "size", "mean", "<=2", "<=16", "non-text", "visual", "ms" });
    var total_px: f64 = 0;
    var total_ok: f64 = 0;
    var total_ok_nt: f64 = 0;
    var total_visual: f64 = 0;
    var total_nt: f64 = 0;
    for (names.items) |name| {
        const at = std.mem.indexOfScalar(u8, name, '@') orelse continue;
        const scale = std.fmt.parseFloat(f32, name[at + 1 .. name.len - 4]) catch continue;
        var id_buf: [64]u8 = undefined;
        const id = id_buf[0..at];
        @memcpy(id, name[0..at]);
        if (std.mem.indexOfScalar(u8, id, '-')) |dash| id[dash] = ':';
        const node = findNode(loaded.doc.pages, id) orelse continue;

        const ref_path = try std.fs.path.join(gpa, &.{ renders, name });
        defer gpa.free(ref_path);
        const ref_bytes = try cwd.readFileAlloc(io, ref_path, gpa, .limited(max_file));
        defer gpa.free(ref_bytes);
        var ref = try engine.png.decode(gpa, ref_bytes);
        defer ref.deinit(gpa);

        var r = corpus.renderer(gpa, &loaded);
        defer r.deinit();
        const t0 = Io.Timestamp.now(io, .awake);
        // Large exports come back smaller than asked (a pixel budget); match their scale.
        // (Against the painted area's width when the box's is not the reference's.)
        const ref_w: f32 = @floatFromInt(ref.width);
        const painted = r.paintedBounds(node, node.transform);
        const pw = if (painted.isEmpty()) node.size.x else painted.x1 - painted.x0;
        const eff = if (@abs(ref_w - node.size.x * scale) <= 1 or @abs(ref_w - pw * scale) <= 2) scale else ref_w / pw;
        // Figma's export frames what the node paints (shadows, strokes, children past
        // its box). When the reference is the box's size, the box is drawn as it always
        // was; else the painted area with a margin, and the reference's window of it that
        // matches best (the edges round a pixel either way).
        const box_fits = @abs(ref_w - @round(node.size.x * eff)) <= 1 and @abs(@as(f32, @floatFromInt(ref.height)) - @round(node.size.y * eff)) <= 1;
        const margin = 3;
        var px = try r.renderExport(node, eff);
        defer px.deinit(gpa);
        var rect: engine.mask.IRect = .{
            .x1 = @intCast(ref.width),
            .y1 = @intCast(ref.height),
        };
        if (!box_fits) {
            // The painted area from its own corner and from the page's pixel grid, each
            // with the window that fits best; the closer of the two is kept.
            var best_err: u64 = std.math.maxInt(u64);
            for ([_]bool{ false, true }) |snap| {
                var r2 = corpus.renderer(gpa, &loaded);
                defer r2.deinit();
                var wide = (try r2.renderExportBounds(node, eff, margin, snap)).pixmap;
                const slack_x = @as(i32, @intCast(wide.rect.width())) - @as(i32, @intCast(ref.width));
                const slack_y = @as(i32, @intCast(wide.rect.height())) - @as(i32, @intCast(ref.height));
                if (slack_x < 0 or slack_y < 0 or slack_x > 4 * margin or slack_y > 4 * margin) {
                    wide.deinit(gpa);
                    continue;
                }
                const all = try wide.toRgba8(gpa, wide.rect);
                defer gpa.free(all);
                const fit = bestWindow(all, @intCast(wide.rect.width()), ref.pixels, ref.width, ref.height, @intCast(slack_x), @intCast(slack_y));
                if (fit.err >= best_err) {
                    wide.deinit(gpa);
                    continue;
                }
                best_err = fit.err;
                px.deinit(gpa);
                px = wide;
                rect = .{
                    .x0 = @intCast(fit.at[0]),
                    .y0 = @intCast(fit.at[1]),
                    .x1 = @as(i32, @intCast(fit.at[0])) + @as(i32, @intCast(ref.width)),
                    .y1 = @as(i32, @intCast(fit.at[1])) + @as(i32, @intCast(ref.height)),
                };
                // Text and image areas as this render placed them, in the window's pixels.
                r.text_bounds.clearRetainingCapacity();
                r.image_bounds.clearRetainingCapacity();
                for (r2.text_bounds.items) |b| try r.text_bounds.append(gpa, .{
                    .x0 = b.x0 - rect.x0,
                    .y0 = b.y0 - rect.y0,
                    .x1 = b.x1 - rect.x0,
                    .y1 = b.y1 - rect.y0,
                });
                for (r2.image_bounds.items) |b| try r.image_bounds.append(gpa, .{
                    .x0 = b.x0 - rect.x0,
                    .y0 = b.y0 - rect.y0,
                    .x1 = b.x1 - rect.x0,
                    .y1 = b.y1 - rect.y0,
                });
            }
        }
        const ms: u64 = @intCast(@divTrunc(t0.untilNow(io, .awake).nanoseconds, std.time.ns_per_ms));
        const ours = try px.toRgba8(gpa, rect);
        defer gpa.free(ours);

        const d = try engine.diff.compare(gpa, ours, ref.pixels, ref.width, ref.height, r.text_bounds.items, r.image_bounds.items);
        defer gpa.free(d.heat);
        total_px += @floatFromInt(d.pixels);
        total_ok += @floatFromInt(d.within2);
        total_nt += @floatFromInt(d.non_text_pixels);
        total_ok_nt += @floatFromInt(d.non_text_within2);
        total_visual += @floatFromInt(d.visual);

        var size_buf: [32]u8 = undefined;
        const size = try std.fmt.bufPrint(&size_buf, "{d}x{d}{s}", .{ ref.width, ref.height, if (ref.width != rect.width() or ref.height != rect.height() or (rect.x1 > px.rect.x1 or rect.y1 > px.rect.y1)) "!" else "" });
        const nm = node.name[0..@min(node.name.len, 22)];
        try w.print("{s:<14} {s:<22} {s:>11} {d:>8.2} {d:>7.2}% {d:>7.2}% {d:>8.2}% {d:>7.2}% {d:>7}\n", .{
            name[0 .. name.len - 4],                    nm,                       size,
            d.mean,                                     pct(d.within2, d.pixels), pct(d.within16, d.pixels),
            pct(d.non_text_within2, d.non_text_pixels), pct(d.visual, d.pixels),  ms,
        });

        if (out_dir) |o| {
            const ours_png = try engine.png.encode(gpa, ref.width, ref.height, ours);
            defer gpa.free(ours_png);
            const heat_png = try engine.png.encode(gpa, ref.width, ref.height, d.heat);
            defer gpa.free(heat_png);
            const base = name[0 .. name.len - 4];
            const p1 = try std.fmt.allocPrint(gpa, "{s}/{s}.ours.png", .{ o, base });
            defer gpa.free(p1);
            const p2 = try std.fmt.allocPrint(gpa, "{s}/{s}.diff.png", .{ o, base });
            defer gpa.free(p2);
            try cwd.writeFile(io, .{
                .sub_path = p1,
                .data = ours_png,
            });
            try cwd.writeFile(io, .{
                .sub_path = p2,
                .data = heat_png,
            });
        }
        try w.flush();
    }
    try w.print("\nall: {d:.2}% of pixels within 2/255; outside text {d:.2}%; visual (photos within 16/255) {d:.2}%\n", .{
        100 * total_ok / @max(total_px, 1),
        100 * total_ok_nt / @max(total_nt, 1),
        100 * total_visual / @max(total_px, 1),
    });
}

/// The offset (up to `sx`, `sy`) of the `w` x `h` window of `ours` (`ow` pixels a row)
/// nearest the reference, by the colour difference over every third pixel.
fn bestWindow(ours: []const u8, ow: usize, ref: []const u8, w: usize, h: usize, sx: usize, sy: usize) struct {
    at: [2]usize,
    err: u64,
} {
    var best: [2]usize = .{ 0, 0 };
    var best_err: u64 = std.math.maxInt(u64);
    for (0..sy + 1) |oy| for (0..sx + 1) |ox| {
        var err: u64 = 0;
        var y: usize = 0;
        while (y < h) : (y += 3) {
            var x: usize = 0;
            while (x < w) : (x += 3) {
                const a = ((y + oy) * ow + x + ox) * 4;
                const b = (y * w + x) * 4;
                for (0..4) |k| err += @abs(@as(i32, ours[a + k]) - @as(i32, ref[b + k]));
            }
        }
        if (err < best_err) {
            best_err = err;
            best = .{ ox, oy };
        }
    };
    return .{
        .at = best,
        .err = best_err,
    };
}

/// `pe decode <image> <out.png>`: an image as the engine decodes it (checking codecs).
fn decodeCmd(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, in_path: []const u8, out_path: []const u8) !void {
    const bytes = try Dir.cwd().readFileAlloc(io, in_path, gpa, .limited(max_file));
    defer gpa.free(bytes);
    var img = try corpus.decodeImage(gpa, bytes);
    defer img.deinit(gpa);
    const png = try engine.png.encode(gpa, img.width, img.height, img.pixels);
    defer gpa.free(png);
    try Dir.cwd().writeFile(io, .{
        .sub_path = out_path,
        .data = png,
    });
    try w.print("{s}: {d}x{d}\n", .{ out_path, img.width, img.height });
}

fn pct(a: u64, b: u64) f64 {
    return 100 * @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(@max(b, 1)));
}

/// `pe shape <font> <text>`: glyph, advance (kerned) and ink centre per glyph, font units.
fn shapeCmd(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, font_path: []const u8, text: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try Dir.cwd().readFileAlloc(io, font_path, a, .limited(64 * 1024 * 1024));
    const font = try engine.font.Font.parse(a, bytes);
    var glyphs: std.ArrayList(engine.shape.Glyph) = .empty;
    try engine.shape.shape(a, &font, text, 0, &.{}, &glyphs);
    for (glyphs.items) |g| {
        var path: engine.geom.Path = .{};
        try font.outline(a, g.id, .identity, &path);
        const b = path.bounds();
        const mid = if (b.isEmpty()) 0 else (b.x0 + b.x1) / 2;
        try w.print("{d} {d} {d} {d:.1} {d:.1} {d:.1}\n", .{ g.id, g.cluster, g.x_advance, g.x_offset, mid, if (b.isEmpty()) 0 else b.y1 });
    }
}
