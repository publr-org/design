//! `pe gpubench`: one page of a document, as the GPU canvas draws it, without the rest.
//!
//!   pe gpubench <doc.pubd-dir> <page-node-id | page-index> [width height [variable-id variable-json]]
//!
//! Reads only that page (and the fonts), never decodes an image, and prints what the page
//! holds (nodes by kind, glyphs, path segments, what needs a surface and why), then times
//! the frame builders at fit in a `width` x `height` view (default 3200 x 2000). With a
//! colour variable (its id and its Pubd JSON), times what a drag in its colour picker
//! costs a step: the edit, and the records brought up to date.

const std = @import("std");
const engine = @import("publr_engine");
const corpus = @import("corpus.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const m = engine.model;
const render = engine.render;
const Scene = engine.gpu_scene.Scene;
const Session = engine.session.Session;

pub fn run(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, dir: []const u8, args: []const []const u8) !void {
    if (args.len < 1) return error.Usage;
    const vw: u32 = if (args.len >= 3) try std.fmt.parseInt(u32, args[1], 10) else 3200;
    const vh: u32 = if (args.len >= 3) try std.fmt.parseInt(u32, args[2], 10) else 2000;
    const s = try openPage(io, gpa, dir, args[0]);
    defer s.sess.destroy();
    const pi = s.page;
    const pg = &s.sess.pages()[pi];

    var c: Census = .{};
    for (pg.children) |*n| census(&c, s.sess, n, 0);
    try c.print(w);

    // Fit, as the stage fits a page.
    var b: engine.geom.Rect = .empty;
    for (pg.children) |*n| b = b.unite(engine.geom.Rect.transformed(.{
        .x1 = n.size.x,
        .y1 = n.size.y,
    }, n.transform));
    const fw: f32 = @floatFromInt(vw);
    const fh: f32 = @floatFromInt(vh);
    const pad: f32 = 96;
    const z = @min((fw - pad * 2) / (b.x1 - b.x0), (fh - pad * 2) / (b.y1 - b.y0));
    const x0 = (b.x0 + b.x1) / 2 - fw / 2 / z;
    const y0 = (b.y0 + b.y1) / 2 - fh / 2 / z;
    try w.print("fit: scale {d:.4}, view {d}x{d}\n", .{ z, vw, vh });
    try w.flush();

    var rec = engine.gpu_records.Records.init(gpa);
    defer rec.deinit();
    for (0..3) |k| {
        const t0 = Io.Timestamp.now(io, .awake);
        try rec.build(s.sess, pi);
        const ms = msSince(io, t0);
        const h = &rec.header;
        try w.print("records {d}: {d} masks, {d:.1} ms, {d} prims, {d} shapes, {d} paints, {d} xforms, {d} curves, {d} paths, {d} bands ({d} items), {d} draws, {d} tops, {d} images, nodes {d}, glyphs {d}, approximated {d}\n", .{ k, h.mask_count, ms, h.prim_count, h.shape_count, h.paint_count, h.xform_count, h.curve_count, h.path_count, h.band_count, h.band_item_count, h.draw_count, h.top_count, h.image_count, h.nodes, h.glyphs, h.approximated });
        try w.flush();
    }
    {
        // Each top-level node written again on its own (what an edit inside it costs).
        var worst: f64 = 0;
        var sum: f64 = 0;
        var worst_i: usize = 0;
        for (0..rec.tops.items.len) |ti| {
            const t0 = Io.Timestamp.now(io, .awake);
            try rec.rebuildTop(s.sess, @intCast(ti));
            const ms = msSince(io, t0);
            sum += ms;
            if (ms > worst) {
                worst = ms;
                worst_i = ti;
            }
        }
        try w.print("one top-level node written again: mean {d:.2} ms, worst {d:.2} ms (node {d}, {d} prims)\n", .{ sum / @as(f64, @floatFromInt(rec.tops.items.len)), worst, worst_i, rec.tops.items[worst_i].prim_count });
        try rec.build(s.sess, pi);
    }
    if (args.len >= 5) try repaint(io, gpa, w, s.sess, pi, &rec, args[3], args[4]);
    {
        const t0 = Io.Timestamp.now(io, .awake);
        for (0..100) |_| try rec.frame(s.sess, x0, y0, z, vw, vh);
        try w.print("records frame (cameras, culling, images): {d:.3} ms, {d} visible\n", .{ msSince(io, t0) / 100, rec.frame_header.visible_count });
        const bytes = rec.prims.items.len * 64 + rec.shapes.items.len * 128 + rec.paints.items.len * 64 + rec.xforms.items.len * 32 + rec.curves.items.len * 32 + rec.band_items.items.len * 4 + rec.bands.items.len * 8;
        // Estimated curve visits per path prim at fit (pixels x curves its rows read).
        var total: f64 = 0;
        var chosen_curves: u64 = 0;
        var worst: [8]struct { cost: f64, prim: u32 } = @splat(.{ .cost = 0, .prim = 0 });
        for (rec.prims.items, 0..) |p, ii| {
            if (p.shape == engine.gpu_records.none) continue;
            const sh = rec.shapes.items[p.shape];
            if (sh.kind != 3 and sh.kind != 4) continue;
            const cam = rec.cameras.items[p.top];
            const ca: engine.geom.Affine = .{ .a = cam.a, .b = cam.b, .c = cam.c, .d = cam.d, .e = cam.e, .f = cam.f };
            const xv = rec.xforms.items[sh.xf];
            var full = ca.mul(.{ .a = xv[0], .b = xv[1], .c = xv[2], .d = xv[3], .e = xv[4], .f = xv[5] });
            if (sh.kind == 4) full = full.mul(.{ .a = sh.v0[1], .b = sh.v0[2], .c = sh.v0[3], .d = sh.v1[0], .e = sh.v1[1], .f = sh.v1[2] });
            const pr = rec.paths.items[@as(u32, @bitCast(sh.v0[0]))];
            const sc = full.maxScale();
            const masked = pr.mask != engine.gpu_records.none and sc <= rec.masks.items[pr.mask].k;
            const bb = engine.geom.Rect.transformed(.{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1 }, ca);
            const wpx = @max(1, @ceil(bb.x1) - @floor(bb.x0));
            const hpx = @max(1, @ceil(bb.y1) - @floor(bb.y0));
            const upright = full.b == 0 and full.c == 0;
            var per_row: f64 = @floatFromInt(pr.curve_count);
            if (upright and pr.band_count > 1) {
                // A row reads the bands its height covers.
                const rows_per_band = (pr.y1 - pr.y0) / @as(f32, @floatFromInt(pr.band_count)) * @abs(full.d);
                const nb = @min(@as(f32, @floatFromInt(pr.band_count)), 1 + 1 / @max(rows_per_band, 1e-6));
                per_row = @as(f64, @floatFromInt(pr.curve_count)) * 2 * nb / @as(f64, @floatFromInt(pr.band_count));
            }
            if (masked) per_row = 1;
            const cost = wpx * hpx * per_row;
            chosen_curves += pr.curve_count;
            total += cost;
            var mi: usize = 0;
            for (worst, 0..) |x, i| if (x.cost < worst[mi].cost) {
                mi = i;
            };
            if (cost > worst[mi].cost) worst[mi] = .{ .cost = cost, .prim = @intCast(ii) };
        }
        try w.print("estimated curve visits at fit: {d:.1} M ({d} curves drawn)\n", .{ total / 1e6, chosen_curves });
        {
            var hist: [6]u32 = @splat(0);
            var hcurves: [6]u64 = @splat(0);
            var seen = std.AutoHashMap(u64, void).init(gpa);
            defer seen.deinit();
            var distinct: u32 = 0;
            for (rec.paths.items) |pr| {
                const cc = pr.curve_count;
                const bi: usize = if (cc < 100) 0 else if (cc < 500) 1 else if (cc < 2000) 2 else if (cc < 10000) 3 else if (cc < 50000) 4 else 5;
                hist[bi] += 1;
                hcurves[bi] += cc;
                if (cc >= 2000) {
                    const h = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(rec.curves.items[pr.curve_first..][0..cc]));
                    if (!(try seen.getOrPut(h)).found_existing) distinct += 1;
                }
            }
            try w.print("paths by curves (<100, <500, <2k, <10k, <50k, more): {any} curves {any}; distinct >=2k: {d}\n", .{ hist, hcurves, distinct });
        }
        for (worst) |x| {
            const p = rec.prims.items[x.prim];
            const sh = rec.shapes.items[p.shape];
            const pr = rec.paths.items[@as(u32, @bitCast(sh.v0[0]))];
            try w.print("  {d:.2} M: prim {d} kind {d} curves {d} bands {d} mask {d} top-bounds {d:.0},{d:.0} {d:.0}x{d:.0}\n", .{ x.cost / 1e6, x.prim, sh.kind, pr.curve_count, pr.band_count, pr.mask, p.x0, p.y0, p.x1 - p.x0, p.y1 - p.y0 });
        }
        try w.print("distinct glyphs: {d}\n", .{rec.glyph_paths.count()});
        try w.print("records GPU bytes: {d:.1} MB\n", .{@as(f64, @floatFromInt(bytes)) / 1048576});
        try w.flush();
    }

    var sc = Scene.init(gpa);
    defer sc.deinit();
    engine.gpu_scene.glyph_budget = std.math.maxInt(u32);
    for (0..3) |k| {
        const t0 = Io.Timestamp.now(io, .awake);
        try sc.buildPage(s.sess, pi, x0, y0, z, vw, vh);
        const ms = msSince(io, t0);
        const h = &sc.header;
        try w.print("immediate scene {d}: {d:.1} ms, {d} prims, {d} shapes, {d} paints, {d} draws, {d} path entries, {d} stencil verts, {d} glyph draws ({d} new), {d} surfaces ({d:.1} Mpx), {d} passes, nodes {d} culled {d}\n", .{ k, ms, h.prim_count, h.shape_count, h.paint_count, h.draw_count, h.entry_count, h.vert_count, h.glyph_draw_count, h.glyph_upload_count, h.surface_count, @as(f64, @floatFromInt(h.surface_pixels)) / 1e6, h.pass_count, h.nodes, h.culled });
        try w.flush();
    }
}

/// A colour picker's drag on variable `id` (`json`: the variable): steps of other
/// colours, each the edit and the records brought up to date.
fn repaint(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, sess: *Session, pi: usize, rec: *engine.gpu_records.Records, id: []const u8, json: []const u8) !void {
    const ed = &sess.edit;
    try ed.ensureIndexed();
    var v = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer v.deinit();
    const values = v.value.object.getPtr("values") orelse return error.BadVariable;
    try ed.begin();
    const steps: usize = if (std.c.getenv("PE_REPAINT_STEPS")) |e| std.fmt.parseInt(usize, std.mem.span(e), 10) catch 8 else 8;
    for (0..steps) |k| {
        var it = values.object.iterator();
        const g: f64 = @as(f64, @floatFromInt(k % 8)) / 8;
        while (it.next()) |e| {
            var arr = std.json.Array.init(gpa);
            for ([_]f64{ 0.5, g, 1 }) |x| try arr.append(.{
                .float = x,
            });
            e.value_ptr.* = .{
                .array = arr,
            };
        }
        const op = try std.fmt.allocPrint(gpa, "{{\"op\":\"variable\",\"id\":{f},\"variable\":{f}}}", .{ std.json.fmt(id, .{}), std.json.fmt(v.value, .{}) });
        defer gpa.free(op);
        var shaped: usize = 0;
        var painted: usize = 0;
        const before = ed.stamp;
        const t0 = Io.Timestamp.now(io, .awake);
        try ed.apply(op);
        const edit_ms = msSince(io, t0);
        for (sess.pages()[pi].children) |*c| count(c, before, &shaped, &painted);
        const t1 = Io.Timestamp.now(io, .awake);
        try rec.update(sess, pi);
        try w.print("repaint {d}: edit {d:.1} ms, records {d:.1} ms (full {d}), nodes changed {d}, shapes made stale {d}\n", .{ k, edit_ms, msSince(io, t1), rec.header.full, painted, shaped });
        try w.flush();
    }
    try ed.commit();
}

fn count(n: *const m.Node, since: u32, shaped: *usize, painted: *usize) void {
    if (n.tree_rev > since) painted.* += 1;
    if (n.shape_rev > since) shaped.* += 1;
    for (n.children) |*c| count(c, since, shaped, painted);
}

pub const Opened = struct {
    sess: *Session,
    page: usize,
};

/// A session holding `dir`'s document, the one page (by top-level id of the page node or
/// index) and the fonts; images are never decoded (`decode_elsewhere`).
pub fn openPage(io: Io, gpa: std.mem.Allocator, dir: []const u8, which: []const u8) !Opened {
    const s = try Session.create(gpa);
    errdefer s.destroy();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = Dir.cwd();
    const json = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ dir, "document.json" }), a, .limited(corpus.max_file));
    try s.loadPubd(json);
    s.decode_elsewhere = true;
    var index: ?usize = std.fmt.parseInt(usize, which, 10) catch null;
    if (index == null) {
        const want = try a.dupe(u8, which);
        std.mem.replaceScalar(u8, want, '-', ':');
        for (s.pages(), 0..) |*p, i| if (std.mem.eql(u8, p.id, want)) {
            index = i;
        };
    }
    const pi = index orelse return error.NoSuchPage;
    if (!s.pageLoaded(pi)) {
        const src = s.pageFile(pi) orelse return error.NoSuchPage;
        const page = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ dir, src }), a, .limited(corpus.max_file));
        try s.loadPage(pi, page);
    }
    const files = try corpus.fontFiles(io, a, dir);
    const lists = [_][]const []const u8{ files.faces, files.fallbacks, files.variable };
    const roles = [_]engine.fonts.Role{ .face, .fallback, .variable };
    for (lists, roles) |list, role| for (list) |fp| {
        const bytes = cwd.readFileAlloc(io, fp, a, .limited(64 * 1024 * 1024)) catch continue;
        _ = try s.addFont(bytes, role);
    };
    return .{
        .sess = s,
        .page = pi,
    };
}

pub fn msSince(io: Io, t0: Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(t0.untilNow(io, .awake).nanoseconds)) / std.time.ns_per_ms;
}

const Census = struct {
    nodes: u64 = 0,
    hidden: u64 = 0,
    kinds: [32]u64 = .{0} ** 32,
    max_depth: u32 = 0,
    texts: u64 = 0,
    glyphs: u64 = 0,
    geometry_nodes: u64 = 0,
    geometry_verbs: u64 = 0,
    network_nodes: u64 = 0,
    stroke_outline: u64 = 0,
    stroke_ring: u64 = 0,
    stroke_computed: u64 = 0,
    image_paints: u64 = 0,
    gradient_paints: u64 = 0,
    pattern_paints: u64 = 0,
    opacity_isolated: u64 = 0,
    opacity_on_paint: u64 = 0,
    blend_nodes: u64 = 0,
    paint_blends: u64 = 0,
    drop_formula: u64 = 0,
    drop_surface: u64 = 0,
    inner_shadows: u64 = 0,
    layer_blurs: u64 = 0,
    background_blurs: u64 = 0,
    noise_texture: u64 = 0,
    masks: u64 = 0,
    clips_path: u64 = 0,
    rotated: u64 = 0,

    fn print(c: *const Census, w: *Io.Writer) !void {
        try w.print("nodes {d} (+{d} hidden), depth {d}\n", .{ c.nodes, c.hidden, c.max_depth });
        try w.print("  kinds:", .{});
        for (c.kinds, 0..) |v, i| if (v > 0) try w.print(" {s} {d}", .{ @tagName(@as(m.Kind, @enumFromInt(i))), v });
        try w.print("\n  texts {d}, glyphs {d}\n", .{ c.texts, c.glyphs });
        try w.print("  stored geometry: {d} nodes, {d} verbs; networks {d}\n", .{ c.geometry_nodes, c.geometry_verbs, c.network_nodes });
        try w.print("  strokes: outline {d}, ring {d}, computed {d}\n", .{ c.stroke_outline, c.stroke_ring, c.stroke_computed });
        try w.print("  paints: image {d}, gradient {d}, pattern {d}\n", .{ c.image_paints, c.gradient_paints, c.pattern_paints });
        try w.print("  isolation: opacity (surface) {d}, opacity on paint {d}, blend {d}, paint blends {d}\n", .{ c.opacity_isolated, c.opacity_on_paint, c.blend_nodes, c.paint_blends });
        try w.print("  effects: drop by formula {d}, drop from surface {d}, inner {d}, layer blur {d}, background blur {d}, noise/texture {d}\n", .{ c.drop_formula, c.drop_surface, c.inner_shadows, c.layer_blurs, c.background_blurs, c.noise_texture });
        try w.print("  masks {d}, path clips {d}, turned or skewed {d}\n", .{ c.masks, c.clips_path, c.rotated });
    }
};

fn census(c: *Census, s: *Session, n: *const m.Node, depth: u32) void {
    if (!n.visible) {
        c.hidden += 1;
        return;
    }
    c.nodes += 1;
    c.max_depth = @max(c.max_depth, depth);
    c.kinds[@intFromEnum(n.kind)] += 1;
    const t = n.transform;
    if (t.b != 0 or t.c != 0) c.rotated += 1;
    if (n.text != null) {
        c.texts += 1;
        if (s.renderer.textLayout(n) catch null) |lay| {
            var l = lay;
            c.glyphs += l.glyphs.items.len;
            l.deinit(s.gpa);
        }
    }
    if (n.geometry.len > 0) {
        c.geometry_nodes += 1;
        for (n.geometry) |g| {
            var p: engine.geom.Path = .{};
            defer p.deinit(s.gpa);
            engine.geom.parseSvgPath(s.gpa, g.d, &p) catch {};
            c.geometry_verbs += p.verbs.items.len;
        }
    } else if (n.network != null) c.network_nodes += 1;
    var has_stroke = false;
    for (n.strokes) |p| {
        if (p.visible) has_stroke = true;
    }
    if (has_stroke and n.stroke.weight > 0) {
        if (n.stroke.outline.len > 0) {
            c.stroke_outline += 1;
        } else if (render.strokeIsRing(n)) {
            c.stroke_ring += 1;
        } else c.stroke_computed += 1;
    }
    for ([2][]const m.Paint{ n.fills, n.strokes }) |ps| for (ps) |p| {
        if (!p.visible) continue;
        switch (p.kind) {
            .image => c.image_paints += 1,
            .linear, .radial, .angular, .diamond => c.gradient_paints += 1,
            .pattern => c.pattern_paints += 1,
            else => {},
        }
        if (p.blend != .normal) c.paint_blends += 1;
    };
    if (n.opacity < 1) {
        if (n.children.len == 0) c.opacity_on_paint += 1 else c.opacity_isolated += 1;
    }
    if (n.blend != .pass_through and n.blend != .normal) c.blend_nodes += 1;
    for (n.effects) |e| {
        if (!e.visible) continue;
        switch (e.kind) {
            .drop_shadow => {
                const formula = switch (n.kind) {
                    .frame, .component, .component_set, .instance, .rectangle, .ellipse => n.geometry.len == 0 and (render.shapeSilhouette(n) or n.children.len == 0),
                    else => false,
                };
                if (formula) c.drop_formula += 1 else c.drop_surface += 1;
            },
            .inner_shadow => c.inner_shadows += 1,
            .layer_blur => c.layer_blurs += 1,
            .background_blur => c.background_blurs += 1,
            .noise, .texture => c.noise_texture += 1,
        }
    }
    if (n.mask != null) c.masks += 1;
    if (n.clip and n.geometry.len > 0 and n.children.len > 0) c.clips_path += 1;
    for (n.children) |*k| census(c, s, k, depth + 1);
}
