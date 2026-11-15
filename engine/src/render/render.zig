//! Draws a document's nodes into a pixmap on the CPU: the reference renderer.

const std = @import("std");
const m = @import("../pubd/model.zig");
const geom = @import("../raster/geom.zig");
const mask_mod = @import("../raster/mask.zig");
const pix = @import("../raster/pixmap.zig");
const text_layout = @import("../text/layout.zig");
const efx = @import("effects.zig");
pub const colour = @import("colour.zig");

const Affine = geom.Affine;
const Vec2 = geom.Vec2;
const Path = geom.Path;
const Polylines = geom.Polylines;
const IRect = mask_mod.IRect;
const Mask = mask_mod.Mask;
const Pixmap = pix.Pixmap;

/// How coverage is computed: exact area, or by counting sample points.
pub const Aa = enum {
    exact,
    figma16,
    grid16,
    standard16,
    custom,
};

/// Gaussian standard deviation per unit of blur radius, per effect (matched to Figma).
pub var layer_blur_k: f32 = 0.4375;
pub var background_blur_k: f32 = 0.4375;
pub var shadow_k: f32 = 0.4375;
/// Background blur reads only inside the node's bounds (edges repeat).
pub var background_blur_clamp: bool = true;

/// Draw fills of vectors, stars, polygons and booleans from their stored geometry.
pub var use_geometry = true;

/// Draw strokes from their stored outlines when present (off: always compute them, to
/// measure our own stroker).
pub var use_stroke_outlines = true;

/// Debugging: leave out paints with a blend mode (to read what lies under them).
pub var skip_blended_paints = false;

/// Horizontal glyph positions per device pixel (0: unsnapped).
pub var glyph_x_bins: f32 = 0;

/// Sample positions for `.custom` (set by tools while matching).
pub var custom_pattern: []const [2]f32 = &.{};

/// Anti-aliasing for text (set by tools while matching Figma).
pub var text_aa: Aa = .figma16;
/// Anti-aliasing for shapes.
pub var shape_aa: Aa = .figma16;

/// Decoded images by asset hash.
pub const Images = std.StringHashMapUnmanaged(pix.Mipmap);

/// Node space to the pixels of an image `iw` x `ih` that paint `p` fills a node of
/// `size` with (fill, fit, stretch, crop, tile); null when it maps nothing.
pub fn imageSpace(p: *const m.Paint, size: Vec2, iw: f32, ih: f32) ?Affine {
    if (size.x <= 0 or size.y <= 0) return null;
    return switch (p.scale) {
        .fill, .fit => blk: {
            const s = if (p.scale == .fill) @max(size.x / iw, size.y / ih) else @min(size.x / iw, size.y / ih);
            const img_to_node = Affine.translate((size.x - iw * s) / 2, (size.y - ih * s) / 2).mul(Affine.scaling(s, s));
            break :blk img_to_node.invert() orelse null;
        },
        .stretch, .crop => Affine.scaling(iw, ih).mul(p.image_transform).mul(Affine.scaling(1 / size.x, 1 / size.y)),
        .tile => Affine.scaling(1 / @max(p.tile, 1e-3), 1 / @max(p.tile, 1e-3)),
    };
}

/// Largest distance a flattened curve may stray from the true one, in device pixels.
pub const tolerance: f32 = 0.05;

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    images: *const Images,
    /// Fonts for text; without them text nodes are skipped (their bounds land in
    /// `text_bounds` either way, for scoring with and without text).
    fonts: ?*const text_layout.FontSet = null,
    text_bounds: std.ArrayList(IRect) = .empty,
    /// Where image paints were drawn (scored with a looser threshold: resampling
    /// differences there are invisible).
    image_bounds: std.ArrayList(IRect) = .empty,
    /// Stop after drawing this many nodes (for watching a render build up).
    limit: ?u32 = null,
    /// Nodes drawn so far in this export.
    drawn: u32 = 0,
    /// The last node drawn and its device bounds.
    last_node: ?*const m.Node = null,
    last_bounds: IRect = .{},
    /// Every node by id (for pattern sources); built by `indexDocument`.
    nodes: std.StringHashMapUnmanaged(*const m.Node) = .empty,
    /// Short-lived allocations (gradient stops), freed after each export.
    frame: std.heap.ArenaAllocator,
    /// Skip nodes that cannot paint inside the target pixmap (for tiles: a node far
    /// outside costs nothing). Off for exports, which draw everything they hold.
    cull: bool = false,
    /// Nodes skipped by `cull` so far.
    culled: u32 = 0,
    /// Draw only this node's drop shadows (its content and backdrop left out): what the
    /// GPU canvas takes from the CPU for a node whose shadows it cannot draw yet.
    shadows_of: ?*const m.Node = null,
    /// Draw only this node's inner shadows (nothing else of it): the same, for inner
    /// shadows.
    inner_of: ?*const m.Node = null,
    /// The document's glyph outlines (`Document.glyphs`), for texts drawn as their
    /// source laid them out; parsed on first use into `glyph_cache`.
    glyph_outlines: []const []const u8 = &.{},
    glyph_cache: std.AutoHashMapUnmanaged(u32, Path) = .empty,

    pub fn init(gpa: std.mem.Allocator, images: *const Images) Renderer {
        return .{
            .gpa = gpa,
            .images = images,
            .frame = .init(gpa),
        };
    }

    /// Makes the document's nodes findable by id (pattern paints refer to their source).
    pub fn indexDocument(self: *Renderer, doc: *const m.Document) !void {
        // Nodes pages share (a pattern's source on another page), then the pages.
        for (doc.shared) |*n| try self.indexNode(n);
        for (doc.pages) |*pg| try self.indexNode(pg);
        if (doc.glyphs.ptr != self.glyph_outlines.ptr or doc.glyphs.len != self.glyph_outlines.len) {
            self.dropGlyphs();
            self.glyph_outlines = doc.glyphs;
        }
    }

    fn dropGlyphs(self: *Renderer) void {
        var it = self.glyph_cache.valueIterator();
        while (it.next()) |p| p.deinit(self.gpa);
        self.glyph_cache.clearRetainingCapacity();
    }

    /// Whether text node `n` draws as its source laid it out (`Text.glyphs`): it has that
    /// layout and a font it asks for is missing (or there are no fonts).
    pub fn usesFileGlyphs(self: *const Renderer, n: *const m.Node) bool {
        const t = if (n.text) |*t| t else return false;
        if (t.glyphs.len == 0 or self.glyph_outlines.len == 0) return false;
        const fonts = self.fonts orelse return true;
        if (!hasFace(fonts, t.style, .{})) return true;
        for (t.runs) |r| if (!hasFace(fonts, r.style, t.style)) return true;
        return false;
    }

    /// Whether the font set draws `st` (gaps filled from `base`) in its own face: a face
    /// of the family by style name, or by weight and slant, or a variable font of it.
    pub fn hasFace(fonts: *const text_layout.FontSet, st: m.TextStyle, base: m.TextStyle) bool {
        const family = st.family orelse base.family orelse return true;
        const style = st.font_style orelse base.font_style;
        const weight = st.weight orelse base.weight orelse 400;
        const italic = st.italic orelse base.italic orelse false;
        for (fonts.faces.items) |*f| {
            if (!std.ascii.eqlIgnoreCase(f.family, family)) continue;
            if (style) |sn| if (std.ascii.eqlIgnoreCase(f.style, sn)) return true;
            if (f.weight == weight and f.italic == italic) return true;
        }
        for (fonts.variable.items) |*v| if (std.ascii.eqlIgnoreCase(v.family, family) and v.italic == italic) return true;
        return false;
    }

    /// Whether the font set has a face or a variable font of `family` (null: any).
    pub fn hasFamily(fonts: *const text_layout.FontSet, family: ?[]const u8) bool {
        const f = family orelse return true;
        for (fonts.faces.items) |*face| if (std.ascii.eqlIgnoreCase(face.family, f)) return true;
        for (fonts.variable.items) |*v| if (std.ascii.eqlIgnoreCase(v.family, f)) return true;
        return false;
    }

    /// Glyph outline `i` (ems, y up), parsed once.
    fn glyphPath(self: *Renderer, i: u32) !?*const Path {
        if (i >= self.glyph_outlines.len) return null;
        const got = try self.glyph_cache.getOrPut(self.gpa, i);
        if (!got.found_existing) {
            got.value_ptr.* = .{};
            geom.parseSvgPath(self.gpa, self.glyph_outlines[i], got.value_ptr) catch {};
        }
        return got.value_ptr;
    }

    /// The text as its source laid it out: one node-space path per set of paints (the
    /// glyphs and decorations of the runs that share them), as `textPaths` gives.
    pub fn fileTextPaths(self: *Renderer, n: *const m.Node, out: *std.ArrayList(TextPath)) !void {
        const t = &n.text.?;
        const Group = struct {
            fills: []const m.Paint,
            run: ?u32,
            path: Path = .{},
        };
        var groups: std.ArrayList(Group) = .empty;
        defer groups.deinit(self.gpa);
        errdefer for (groups.items) |*g| g.path.deinit(self.gpa);
        // The paints at a character and the run they are of (null: the node's).
        const At = struct {
            paints: []const m.Paint,
            run: ?u32,
        };
        const pick = struct {
            fn paintsAt(node: *const m.Node, char: u32) At {
                for (node.text.?.runs, 0..) |r, ri| if (char >= r.from and char < r.to) {
                    if (r.fills) |f| return .{
                        .paints = f,
                        .run = @intCast(ri),
                    };
                    break;
                };
                return .{
                    .paints = node.fills,
                    .run = null,
                };
            }
            fn group(gs: *std.ArrayList(Group), gpa: std.mem.Allocator, at: At) !*Path {
                const paints = at.paints;
                for (gs.items) |*g| if (g.fills.ptr == paints.ptr and g.fills.len == paints.len) return &g.path;
                try gs.append(gpa, .{
                    .fills = paints,
                    .run = at.run,
                });
                return &gs.items[gs.items.len - 1].path;
            }
        };
        for (t.glyphs) |g| {
            const src = try self.glyphPath(g.outline) orelse continue;
            if (src.verbs.items.len == 0) continue;
            const dst = try pick.group(&groups, self.gpa, pick.paintsAt(n, g.char));
            const c = @cos(g.rotation);
            const sn = @sin(g.rotation);
            // Figma draws a line's baseline on a whole unit (its stored layout keeps the
            // fraction: 18.4 draws at 18), as our own layout places it.
            const tm: Affine = .{
                .a = g.size * c,
                .b = g.size * sn,
                .c = g.size * sn,
                .d = -g.size * c,
                .e = g.x,
                .f = if (g.rotation == 0) @round(g.y) else g.y,
            };
            try dst.verbs.appendSlice(self.gpa, src.verbs.items);
            try dst.points.ensureUnusedCapacity(self.gpa, src.points.items.len);
            for (src.points.items) |p| dst.points.appendAssumeCapacity(tm.apply(p));
        }
        for (t.glyph_rects) |r| {
            const dst = try pick.group(&groups, self.gpa, pick.paintsAt(n, r.char));
            try addDecoration(self.gpa, .{
                .x0 = r.rect[0],
                .y0 = r.rect[1],
                .x1 = r.rect[0] + r.rect[2],
                .y1 = r.rect[1] + r.rect[3],
            }, dst);
        }
        for (groups.items, 0..) |*g, i| {
            try out.append(self.gpa, .{
                .path = g.path,
                .fills = g.fills,
                .run = g.run,
                .style = @intCast(i),
            });
            g.path = .{};
        }
    }

    fn indexNode(self: *Renderer, n: *const m.Node) !void {
        try self.nodes.put(self.gpa, n.id, n);
        for (n.children) |*c| try self.indexNode(c);
    }

    pub fn deinit(self: *Renderer) void {
        self.dropGlyphs();
        self.glyph_cache.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.text_bounds.deinit(self.gpa);
        self.image_bounds.deinit(self.gpa);
        self.frame.deinit();
    }

    /// Renders `node` the way an export does: its own box at `scale`, top left at 0,0.
    pub fn renderExport(self: *Renderer, node: *const m.Node, scale: f32) !Pixmap {
        const w: i32 = @intFromFloat(@round(node.size.x * scale));
        const h: i32 = @intFromFloat(@round(node.size.y * scale));
        var out = try Pixmap.init(self.gpa, .{
            .x1 = w,
            .y1 = h,
        });
        errdefer out.deinit(self.gpa);
        defer _ = self.frame.reset(.retain_capacity);
        self.drawn = 0;
        self.last_node = null;
        try self.drawNode(node, Affine.scaling(scale, scale), &out);
        return out;
    }

    /// `node` as Figma exports it at `scale`: its painted area (`exportBounds`, with
    /// the node at its place on the page), whole pixels wide, and `margin` pixels more
    /// around it (where the rounding may differ). Answers the
    /// pixels and that area's top left in node pixels at `scale` (the export's origin).
    pub fn renderExportBounds(self: *Renderer, node: *const m.Node, scale: f32, margin: i32, snap: bool) !struct {
        pixmap: Pixmap,
        x: i32,
        y: i32,
    } {
        const world = Affine.scaling(scale, scale).mul(node.transform);
        const b = self.paintedBounds(node, world);
        if (b.isEmpty()) return .{
            .pixmap = try self.renderExport(node, scale),
            .x = 0,
            .y = 0,
        };
        // Whole pixels of the page at `scale` (a node at a fractional place gets a
        // pixel more), within a small tolerance for float noise.
        // `margin` more pixels on every side.
        // The area starts where the painting does (Figma's export puts that corner at
        // pixel 0, a fractional place included) and is whole pixels wide.
        // With `snap`, the area starts on the page's whole pixels instead.
        const mf: f32 = @floatFromInt(margin);
        const ox = if (snap) @floor(b.x0 + 1e-3) else b.x0;
        const oy = if (snap) @floor(b.y0 + 1e-3) else b.y0;
        const w: i32 = @as(i32, @intFromFloat(@ceil(b.x1 - ox - 1e-3))) + 2 * margin;
        const h: i32 = @as(i32, @intFromFloat(@ceil(b.y1 - oy - 1e-3))) + 2 * margin;
        var out = try Pixmap.init(self.gpa, .{
            .x1 = @max(1, w),
            .y1 = @max(1, h),
        });
        errdefer out.deinit(self.gpa);
        defer _ = self.frame.reset(.retain_capacity);
        self.drawn = 0;
        self.last_node = null;
        const ctm = Affine.translate(mf - ox, mf - oy).mul(world);
        try self.drawNode(node, ctm, &out);
        const o = world.apply(.{});
        return .{
            .pixmap = out,
            .x = @intFromFloat(@round(ox - mf - o.x)),
            .y = @intFromFloat(@round(oy - mf - o.y)),
        };
    }

    /// `exportBounds` with texts framed by their ink.
    pub fn paintedBounds(self: *Renderer, n: *const m.Node, ctm: Affine) geom.Rect {
        return exportBoundsWith(n, ctm, self);
    }

    /// Draws `n` with `ctm` (node space to device) onto `dst`.
    pub fn drawNode(self: *Renderer, n: *const m.Node, ctm: Affine, dst: *Pixmap) anyerror!void {
        if (!n.visible or n.opacity <= 0 or n.kind == .slice) return;
        if (self.limit) |l| if (self.drawn >= l) return;
        if (self.cull and IRect.around(cullBounds(n, ctm)).intersect(dst.rect).isEmpty()) {
            self.culled += 1;
            return;
        }
        self.drawn += 1;
        self.last_node = n;
        self.last_bounds = IRect.around(geom.Rect.transformed(.{
            .x1 = n.size.x,
            .y1 = n.size.y,
        }, ctm));
        if (n.kind == .text) {
            const r = IRect.around(geom.Rect.transformed(.{
                .x1 = n.size.x,
                .y1 = n.size.y,
            }, ctm));
            try self.text_bounds.append(self.gpa, r);
            if (self.fonts == null or n.text == null) return;
        }
        const extent = effectExtent(n, ctm);
        const isolate = n.opacity < 1 or extent > 0 or (n.blend != .pass_through and n.blend != .normal);
        if (!isolate) return self.drawContent(n, ctm, dst);
        // Blurred as a whole wider than `coarse_sigma`: drawn whole on the coarse grid.
        var whole: f32 = 0;
        for (n.effects) |e| {
            if (e.visible and e.kind == .layer_blur) whole = @max(whole, efx.blurReach(e) * ctm.maxScale() * layer_blur_k);
        }
        if (Coarse.of(ctm, whole)) |c| return self.drawCoarse(n, ctm, dst, c);
        return self.drawIsolated(n, ctm, dst);
    }

    /// Draws `n` whole on a coarse grid and scales it up onto `dst`.
    fn drawCoarse(self: *Renderer, n: *const m.Node, ctm: Affine, dst: *Pixmap, c: Coarse) !void {
        var lo = try Pixmap.init(self.gpa, c.rectFor(dst.rect).outset(2));
        defer lo.deinit(self.gpa);
        try self.drawNode(n, c.ctmFor(ctm), &lo);
        c.drawScaledUp(dst, &lo);
    }

    /// Draws `n` into a layer of its own and composites it (opacity, blend, effects).
    fn drawIsolated(self: *Renderer, n: *const m.Node, ctm: Affine, dst: *Pixmap) !void {
        const only_shadows = self.shadows_of == n;
        if (!only_shadows) for (n.effects) |e| {
            if (e.visible and e.kind == .background_blur) try self.backgroundBlur(n, e, ctm, dst);
        };
        // The layer reaches as far as the shadows cast from it can carry its pixels.
        // Shadows on the coarse grid draw their own silhouette, and a node whose
        // silhouette is its shape casts from the shape: the layer then covers only `dst`.
        const by_shape = shapeSilhouette(n);
        const extent = if (by_shape) layerExtent(n, ctm) else fineExtent(n, ctm);
        var content_rect = IRect.around(visualBounds(n, ctm)).intersect(dst.rect.outset(@intFromFloat(@ceil(extent))));
        var layer_blur: f32 = 0;
        for (n.effects) |e| {
            if (e.visible and e.kind == .layer_blur) layer_blur = @max(layer_blur, efx.blurReach(e) * ctm.maxScale() * layer_blur_k);
        }
        // Room for the blur (or a texture) to spread into.
        const room = @max(layer_blur * 3, efx.textureRoom(n, ctm));
        if (room > 0) content_rect = content_rect.outset(@intFromFloat(@ceil(room))).intersect(dst.rect.outset(@intFromFloat(@ceil(extent))));
        // None of the node may be here while its shadow still is.
        var layer: ?Pixmap = if (content_rect.isEmpty()) null else try Pixmap.init(self.gpa, content_rect);
        defer if (layer) |*l| l.deinit(self.gpa);
        if (layer) |*l| {
            try self.drawContent(n, ctm, l);
            for (n.effects) |e| {
                if (!e.visible) continue;
                if (e.kind == .noise) efx.drawNoise(l, e, ctm);
                if (e.kind == .texture) try efx.drawTexture(self.gpa, l, e, ctm);
            }
            if (layer_blur > 0) for (n.effects) |e| {
                if (!e.visible or e.kind != .layer_blur) continue;
                if (e.progressive != null) {
                    try efx.progressiveBlur(self.gpa, l, n, e, ctm, layer_blur_k);
                } else {
                    try efx.blur(self.gpa, l, e.radius * ctm.maxScale() * layer_blur_k);
                }
                break;
            };
        }

        // Shadows are cast as if see-through paints were opaque.
        var silhouette: ?Pixmap = null;
        defer if (silhouette) |*sl| sl.deinit(self.gpa);
        var shape: ?Mask = null;
        defer if (shape) |*sm| sm.deinit(self.gpa);
        for (n.effects) |e| {
            if (!e.visible or e.kind != .drop_shadow) continue;
            if (Coarse.of(ctm, e.radius * ctm.maxScale() * shadow_k)) |c| {
                try self.coarseShadow(n, e, ctm, dst, c);
                continue;
            }
            if (by_shape) {
                if (shape == null) {
                    var path: Path = .{};
                    defer path.deinit(self.gpa);
                    const winding = try self.fillPath(n, &path);
                    shape = try self.rasterize(&path, ctm, winding, dst.rect.outset(@intFromFloat(@ceil(effectExtent(n, ctm)))));
                }
                try self.dropShadow(n, .{
                    .shape = &shape.?,
                }, e, ctm, dst, n.opacity);
                continue;
            }
            const l = if (layer) |*lp| lp else continue;
            if (silhouette == null and efx.hasTranslucentPaint(n)) {
                var solid = n.*;
                solid.fills = try efx.opaquePaints(self.frame.allocator(), n.fills);
                solid.strokes = try efx.opaquePaints(self.frame.allocator(), n.strokes);
                silhouette = try Pixmap.init(self.gpa, l.rect);
                try self.drawContent(&solid, ctm, &silhouette.?);
            }
            try self.dropShadow(n, .{
                .layer = if (silhouette) |*sl| sl else l,
            }, e, ctm, dst, n.opacity);
        }
        if (only_shadows) return;
        if (layer) |*l| dst.drawPixmap(l, n.opacity, .{
            .mode = blendMode(n.blend),
        });
    }

    /// Casts one drop shadow on the coarse grid, from a silhouette drawn there, and scales
    /// it up onto `dst`.
    fn coarseShadow(self: *Renderer, n: *const m.Node, e: m.Effect, ctm: Affine, dst: *Pixmap, c: Coarse) !void {
        const lo_ctm = c.ctmFor(ctm);
        var lo = try Pixmap.init(self.gpa, c.rectFor(dst.rect).outset(2));
        defer lo.deinit(self.gpa);
        const ext = effectExtent(n, lo_ctm);
        const rect = IRect.around(visualBounds(n, lo_ctm)).intersect(lo.rect.outset(@intFromFloat(@ceil(ext))));
        if (rect.isEmpty()) return;
        var solid = n.*;
        if (efx.hasTranslucentPaint(n)) {
            solid.fills = try efx.opaquePaints(self.frame.allocator(), n.fills);
            solid.strokes = try efx.opaquePaints(self.frame.allocator(), n.strokes);
        }
        var silhouette = try Pixmap.init(self.gpa, rect);
        defer silhouette.deinit(self.gpa);
        try self.drawContent(&solid, lo_ctm, &silhouette);
        try self.dropShadow(n, .{
            .layer = &silhouette,
        }, e, lo_ctm, &lo, n.opacity);
        c.drawScaledUp(dst, &lo);
    }

    fn drawContent(self: *Renderer, n: *const m.Node, ctm: Affine, dst: *Pixmap) !void {
        if (self.inner_of == n) return self.drawInnerShadows(n, ctm, dst);
        var shape: Path = .{};
        defer shape.deinit(self.gpa);
        const winding = try self.fillPath(n, &shape);
        const has_shape = shape.verbs.items.len > 0;

        var fill_mask: ?Mask = null;
        defer if (fill_mask) |*fm| fm.deinit(self.gpa);
        if (has_shape and (hasVisible(n.fills) or (n.clip and n.children.len > 0) or hasVisible(n.strokes))) {
            fill_mask = try self.rasterize(&shape, ctm, winding, dst.rect.outset(2));
        }

        // Regions with fills of their own draw one by one.
        const regions = use_geometry and hasRegionFills(n);
        if (regions) for (n.geometry) |g| {
            var gp: Path = .{};
            defer gp.deinit(self.gpa);
            geom.parseSvgPath(self.gpa, g.d, &gp) catch continue;
            var gm = try self.rasterize(&gp, ctm, if (g.winding == .evenodd) .evenodd else .nonzero, dst.rect.outset(2));
            defer gm.deinit(self.gpa);
            for (g.fills orelse n.fills) |*p| {
                if (!p.visible) continue;
                const shader = try self.shaderFor(p, n.size, ctm) orelse continue;
                dst.fillMaskBlend(&gm, &shader, p.opacity, blendMode(p.blend));
            }
        };

        if (fill_mask) |*fm| if (!regions) for (n.fills) |*p| {
            if (!p.visible) continue;
            if (p.kind == .pattern) {
                try self.drawPattern(n, p, ctm, fm, dst);
                continue;
            }
            const shader = try self.shaderFor(p, n.size, ctm) orelse continue;
            if (p.kind == .image) try self.image_bounds.append(self.gpa, fm.rect.intersect(dst.rect));
            if (skip_blended_paints and p.blend != .normal) continue;
            dst.fillMaskBlend(fm, &shader, p.opacity, blendMode(p.blend));
        };

        if (fill_mask) |*fm| for (n.effects) |e| {
            if (e.visible and e.kind == .inner_shadow) try self.innerShadow(&shape, winding, fm, e, ctm, dst);
        };

        if (n.kind == .text) try self.drawText(n, ctm, dst);

        if (n.children.len > 0) {
            if (n.clip and fill_mask != null) {
                // The clip layer starts as what is already drawn, so effects that read the
                // backdrop (background blur) see the frame's own fills too; it goes back
                // through the clip mask.
                var layer = try Pixmap.init(self.gpa, dst.rect.intersect(fill_mask.?.rect));
                defer layer.deinit(self.gpa);
                if (!layer.rect.isEmpty()) {
                    layer.drawPixmap(dst, 1, .{});
                    try self.drawChildren(n, ctm, &layer);
                    dst.replaceMasked(&layer, &fill_mask.?);
                }
            } else {
                try self.drawChildren(n, ctm, dst);
            }
        }

        if (hasVisible(n.strokes) and n.stroke.weight > 0) {
            var sm = try self.strokeMask(n, &shape, ctm, if (fill_mask) |*fm| fm else null, dst.rect.outset(2));
            defer sm.deinit(self.gpa);
            for (n.strokes) |*p| {
                if (!p.visible) continue;
                if (p.kind == .pattern) {
                    try self.drawPatternIn(n, p, try self.strokeBox(n), ctm, &sm, dst);
                    continue;
                }
                const shader = try self.shaderFor(p, n.size, ctm) orelse continue;
                dst.fillMask(&sm, &shader, p.opacity);
            }
        }
    }

    /// The node's inner shadows alone (`inner_of`, and the GPU canvas's inner shadow
    /// layers).
    pub fn drawInnerShadows(self: *Renderer, n: *const m.Node, ctm: Affine, dst: *Pixmap) !void {
        var shape: Path = .{};
        defer shape.deinit(self.gpa);
        const winding = try self.fillPath(n, &shape);
        if (shape.verbs.items.len == 0) return;
        var fm = try self.rasterize(&shape, ctm, winding, dst.rect.outset(2));
        defer fm.deinit(self.gpa);
        for (n.effects) |e| {
            if (e.visible and e.kind == .inner_shadow) try self.innerShadow(&shape, winding, &fm, e, ctm, dst);
        }
    }

    fn drawText(self: *Renderer, n: *const m.Node, ctm: Affine, dst: *Pixmap) !void {
        if (self.usesFileGlyphs(n)) {
            var list: std.ArrayList(TextPath) = .empty;
            defer {
                for (list.items) |*tp| tp.path.deinit(self.gpa);
                list.deinit(self.gpa);
            }
            try self.fileTextPaths(n, &list);
            for (list.items) |*tp| {
                var mk = try self.rasterizeWith(&tp.path, ctm, .nonzero, dst.rect, text_aa);
                defer mk.deinit(self.gpa);
                for (tp.fills) |*p| {
                    if (!p.visible) continue;
                    const shader = try self.shaderFor(p, n.size, ctm) orelse continue;
                    dst.fillMask(&mk, &shader, p.opacity);
                }
            }
            return;
        }
        const fonts = self.fonts orelse return;
        // A text node with a network is text on a path.
        var lay = if (n.network) |*net| try text_layout.layoutPath(self.gpa, &n.text.?, net, fonts) else try text_layout.layout(self.gpa, &n.text.?, n.size, fonts, .{});
        defer lay.deinit(self.gpa);
        // One mask per style: glyphs that share paints are filled together.
        for (lay.styles.items, 0..) |st, si| {
            var path: Path = .{};
            defer path.deinit(self.gpa);
            for (lay.glyphs.items) |g| {
                if (g.style != si) continue;
                // A tile skips glyphs that cannot reach it (within 2.5 em of the origin).
                if (self.cull) {
                    const r = g.size * 2.5;
                    const gb = IRect.around(geom.Rect.transformed(.{
                        .x0 = g.x - r,
                        .y0 = g.y - r,
                        .x1 = g.x + r,
                        .y1 = g.y + r,
                    }, ctm));
                    if (gb.intersect(dst.rect).isEmpty()) continue;
                }
                var gm = glyphTransform(g);
                // Glyph origins snap to a grid in device space (glyph-cache rendering):
                // whole pixels vertically, `glyph_x_bins` steps per pixel horizontally.
                if (glyph_x_bins > 0 and ctm.b == 0 and ctm.c == 0 and g.sin == 0) {
                    const d = ctm.apply(.{
                        .x = g.x,
                        .y = g.y,
                    });
                    const qx = @round(d.x * glyph_x_bins) / glyph_x_bins;
                    const qy = @round(d.y);
                    gm.e += (qx - d.x) / ctm.a;
                    gm.f += (qy - d.y) / ctm.d;
                }
                try g.font.outline(self.gpa, g.glyph, gm, &path);
            }
            for (lay.decorations.items) |d| {
                if (d.style == si) try addDecoration(self.gpa, d.rect, &path);
            }
            if (path.verbs.items.len == 0) continue;
            var mk = try self.rasterizeWith(&path, ctm, .nonzero, dst.rect, text_aa);
            defer mk.deinit(self.gpa);
            for (st.fills orelse n.fills) |*p| {
                if (!p.visible) continue;
                const shader = try self.shaderFor(p, n.size, ctm) orelse continue;
                dst.fillMask(&mk, &shader, p.opacity);
            }
        }
    }

    /// The text node's glyphs and decorations as one node-space path per style, with the
    /// paints each fills with (what `drawText` rasterises, every glyph included).
    pub fn textPaths(self: *Renderer, n: *const m.Node, out: *std.ArrayList(TextPath)) !void {
        if (self.usesFileGlyphs(n)) return self.fileTextPaths(n, out);
        var lay = try self.textLayout(n) orelse return;
        defer lay.deinit(self.gpa);
        try self.stylePaths(n, &lay, out);
    }

    /// The text node's layout as `drawText` lays it out (null: no fonts or no text).
    pub fn textLayout(self: *Renderer, n: *const m.Node) !?text_layout.Layout {
        const fonts = self.fonts orelse return null;
        const t = if (n.text) |*t| t else return null;
        return if (n.network) |*net| try text_layout.layoutPath(self.gpa, t, net, fonts) else try text_layout.layout(self.gpa, t, n.size, fonts, .{});
    }

    /// `textPaths` from a layout in hand.
    pub fn stylePaths(self: *Renderer, n: *const m.Node, lay: *const text_layout.Layout, out: *std.ArrayList(TextPath)) !void {
        if (self.usesFileGlyphs(n)) return self.fileTextPaths(n, out);
        for (lay.styles.items, 0..) |st, si| {
            var path: Path = .{};
            errdefer path.deinit(self.gpa);
            for (lay.glyphs.items) |g| {
                if (g.style == si) try g.font.outline(self.gpa, g.glyph, glyphTransform(g), &path);
            }
            for (lay.decorations.items) |d| {
                if (d.style == si) try addDecoration(self.gpa, d.rect, &path);
            }
            if (path.verbs.items.len == 0) {
                path.deinit(self.gpa);
                continue;
            }
            try out.append(self.gpa, .{
                .path = path,
                .fills = st.fills orelse n.fills,
                .style = @intCast(si),
            });
        }
    }

    /// Children in stacking order. A boolean draws none (its outline is the result); a mask
    /// child masks the siblings after it up to the next mask.
    fn drawChildren(self: *Renderer, n: *const m.Node, ctm: Affine, dst: *Pixmap) anyerror!void {
        if (n.kind == .boolean) return;
        if (n.repeat) |r| {
            var i: u32 = 0;
            while (i < r.count) : (i += 1) {
                const fi: f32 = @floatFromInt(i);
                const t: Affine = switch (r.kind) {
                    .linear => if (r.vertical) Affine.translate(0, fi * r.offset) else Affine.translate(fi * r.offset, 0),
                    .radial => blk: {
                        const a = fi * std.math.tau / @as(f32, @floatFromInt(r.count));
                        const cx = n.size.x / 2;
                        const cy = n.size.y / 2;
                        const rot: Affine = .{
                            .a = @cos(a),
                            .b = @sin(a),
                            .c = -@sin(a),
                            .d = @cos(a),
                        };
                        break :blk Affine.translate(cx, cy).mul(rot).mul(Affine.translate(-cx, -cy));
                    },
                };
                for (n.children) |*c| try self.drawNode(c, ctm.mul(t).mul(c.transform), dst);
            }
            return;
        }
        const kids = n.children;
        if (n.reverse_z) {
            var k = kids.len;
            while (k > 0) {
                k -= 1;
                try self.drawNode(&kids[k], ctm.mul(kids[k].transform), dst);
            }
            return;
        }
        var i: usize = 0;
        while (i < kids.len) {
            const c = &kids[i];
            if (c.mask) |mt| {
                var j = i + 1;
                while (j < kids.len and kids[j].mask == null) j += 1;
                try self.drawMasked(c, mt, kids[i + 1 .. j], ctm, dst);
                i = j;
            } else {
                try self.drawNode(c, ctm.mul(c.transform), dst);
                i += 1;
            }
        }
    }

    /// The mask among `parent`'s children at `index` and the siblings it masks, as
    /// `drawChildren` draws them (`ctm` is the parent's).
    pub fn drawMaskRun(self: *Renderer, parent: *const m.Node, index: usize, ctm: Affine, dst: *Pixmap) !void {
        const kids = parent.children;
        if (index >= kids.len) return;
        const mt = kids[index].mask orelse return;
        var j = index + 1;
        while (j < kids.len and kids[j].mask == null) j += 1;
        try self.drawMasked(&kids[index], mt, kids[index + 1 .. j], ctm, dst);
    }

    fn drawMasked(self: *Renderer, mask_node: *const m.Node, mt: m.MaskType, masked: []const m.Node, ctm: Affine, dst: *Pixmap) !void {
        if (masked.len == 0 or !mask_node.visible) return;
        const mctm = ctm.mul(mask_node.transform);
        var cov = try Mask.init(self.gpa, dst.rect, 0);
        defer cov.deinit(self.gpa);
        switch (mt) {
            .vector => try self.outlineCoverage(mask_node, mctm, &cov),
            .alpha, .luminance => {
                var ml = try Pixmap.init(self.gpa, dst.rect);
                defer ml.deinit(self.gpa);
                var copy = mask_node.*;
                copy.mask = null;
                try self.drawNode(&copy, mctm, &ml);
                for (cov.data, ml.data) |*v, p| {
                    if (mt == .alpha) {
                        v.* = p[3];
                    } else {
                        // Luminance of the premultiplied colour = luminance times alpha.
                        v.* = 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2];
                    }
                }
            },
        }
        var layer = try Pixmap.init(self.gpa, dst.rect);
        defer layer.deinit(self.gpa);
        for (masked) |*c| try self.drawNode(c, ctm.mul(c.transform), &layer);
        dst.drawPixmap(&layer, 1, .{
            .clip = &cov,
        });
    }

    /// A mask by outline: the node's fill shape, or for a group (it has none) its
    /// visible descendants' shapes together, as coverage in `cov` (each over the last,
    /// as the GPU canvas draws them).
    fn outlineCoverage(self: *Renderer, n: *const m.Node, ctm: Affine, cov: *Mask) !void {
        if (n.kind == .group) {
            for (n.children) |*c| if (c.visible) try self.outlineCoverage(c, ctm.mul(c.transform), cov);
            return;
        }
        var shape: Path = .{};
        defer shape.deinit(self.gpa);
        const w = try self.fillPath(n, &shape);
        var sm = try self.rasterize(&shape, ctm, w, cov.rect);
        defer sm.deinit(self.gpa);
        for (cov.data, 0..) |*v, idx| {
            const x = cov.rect.x0 + @as(i32, @intCast(idx % cov.rect.width()));
            const y = cov.rect.y0 + @as(i32, @intCast(idx / cov.rect.width()));
            const a = sm.at(x, y);
            v.* = v.* + a - v.* * a;
        }
    }

    /// Tiles a pattern's source node over the node's box, clipped to a fill or stroke mask.
    fn drawPattern(self: *Renderer, n: *const m.Node, p: *const m.Paint, ctm: Affine, fm: *const Mask, dst: *Pixmap) !void {
        return self.drawPatternIn(n, p, .{
            .x1 = n.size.x,
            .y1 = n.size.y,
        }, ctm, fm, dst);
    }

    /// The box (node space) the pattern grid aligns to: the node's box for fills, the
    /// stroke's own bounds for strokes (Figma lays stroke patterns over the stroke shape).
    pub fn strokeBox(self: *Renderer, n: *const m.Node) !geom.Rect {
        if (n.stroke.outline.len > 0) {
            var path: Path = .{};
            defer path.deinit(self.gpa);
            for (n.stroke.outline) |o| geom.parseSvgPath(self.gpa, o.d, &path) catch {};
            const b = path.bounds();
            if (!b.isEmpty()) return b;
        }
        const w = n.stroke.weight;
        const out: f32 = switch (n.stroke.alignFor(n.kind)) {
            .center => w / 2,
            .inside, .outside => w,
        };
        return geom.Rect.outset(.{
            .x1 = n.size.x,
            .y1 = n.size.y,
        }, out);
    }

    fn drawPatternIn(self: *Renderer, _: *const m.Node, p: *const m.Paint, box: geom.Rect, ctm: Affine, fm: *const Mask, dst: *Pixmap) !void {
        const src = self.nodes.get(p.source) orelse return;
        const k = if (p.tile > 0) p.tile else 1;
        const cw = src.size.x * k;
        const ch = src.size.y * k;
        // Spacing counts in tiles: 1 leaves a tile-sized gap.
        const tw = cw * (1 + p.spacing.x);
        const th = ch * (1 + p.spacing.y);
        if (tw <= 0.01 or th <= 0.01) return;
        const bw = box.x1 - box.x0;
        const bh = box.y1 - box.y0;
        const ox = box.x0 + alignStart(p.h_align, bw, cw);
        const oy = box.y0 + alignStart(p.v_align, bh, ch);
        var layer = try Pixmap.init(self.gpa, fm.rect.intersect(dst.rect));
        defer layer.deinit(self.gpa);
        if (layer.rect.isEmpty()) return;
        const hex_rows = p.tile_type == .horizontal_hexagonal;
        const hex_cols = p.tile_type == .vertical_hexagonal;
        const row0: i32 = @intFromFloat(@floor((box.y0 - oy) / th) - 1);
        const row1: i32 = @intFromFloat(@ceil((box.y1 - oy) / th) + 1);
        const col0: i32 = @intFromFloat(@floor((box.x0 - ox) / tw) - 1);
        const col1: i32 = @intFromFloat(@ceil((box.x1 - ox) / tw) + 1);
        var j = row0;
        while (j <= row1) : (j += 1) {
            var i = col0;
            while (i <= col1) : (i += 1) {
                var x = ox + @as(f32, @floatFromInt(i)) * tw;
                var y = oy + @as(f32, @floatFromInt(j)) * th;
                if (hex_rows and @mod(j, 2) != 0) x += tw / 2;
                if (hex_cols and @mod(i, 2) != 0) y += th / 2;
                if (x > box.x1 or y > box.y1 or x + cw < box.x0 or y + ch < box.y0) continue;
                const tile_ctm = ctm.mul(Affine.translate(x, y)).mul(Affine.scaling(k, k));
                try self.drawNode(src, tile_ctm, &layer);
            }
        }
        dst.drawPixmap(&layer, p.opacity, .{
            .clip = fm,
        });
    }

    /// The node's fill outline in node space.
    pub fn fillPath(self: *Renderer, n: *const m.Node, out: *Path) !mask_mod.Winding {
        if (use_geometry and n.geometry.len > 0) {
            var winding: mask_mod.Winding = .nonzero;
            for (n.geometry) |g| {
                geom.parseSvgPath(self.gpa, g.d, out) catch {};
                if (g.winding == .evenodd) winding = .evenodd;
            }
            return winding;
        }
        switch (n.kind) {
            .frame, .component, .component_set, .instance, .rectangle => try out.addRoundRect(self.gpa, n.size.x, n.size.y, n.radius),
            .ellipse => try out.addEllipse(self.gpa, n.size.x, n.size.y),
            .vector => if (n.network) |net| {
                var winding: mask_mod.Winding = .nonzero;
                for (net.regions) |r| {
                    if (r.winding == .evenodd) winding = .evenodd;
                    for (r.loops) |loop| try addLoop(self.gpa, net, loop, out);
                }
                return winding;
            },
            else => {},
        }
        return .nonzero;
    }

    fn rasterizeWith(self: *Renderer, path: *const Path, ctm: Affine, winding: mask_mod.Winding, clip: IRect, aa: Aa) !Mask {
        if (aa == .exact) {
            var dev = try clonePath(self.gpa, path);
            defer dev.deinit(self.gpa);
            dev.transform(ctm);
            var polys: Polylines = .{};
            defer polys.deinit(self.gpa);
            try dev.flatten(self.gpa, tolerance, &polys);
            return mask_mod.fill(self.gpa, &polys, winding, clip);
        }
        var dev = try clonePath(self.gpa, path);
        defer dev.deinit(self.gpa);
        dev.transform(ctm);
        var polys: Polylines = .{};
        defer polys.deinit(self.gpa);
        try dev.flatten(self.gpa, tolerance, &polys);
        return mask_mod.fillSampled(self.gpa, &polys, winding, clip, switch (aa) {
            .grid16 => &mask_mod.grid16,
            .standard16 => &mask_mod.standard16,
            .figma16 => &mask_mod.figma16,
            .custom => custom_pattern,
            .exact => unreachable,
        });
    }

    fn rasterize(self: *Renderer, path: *const Path, ctm: Affine, winding: mask_mod.Winding, clip: IRect) !Mask {
        if (shape_aa != .exact) return self.rasterizeWith(path, ctm, winding, clip, shape_aa);
        var dev = try clonePath(self.gpa, path);
        defer dev.deinit(self.gpa);
        dev.transform(ctm);
        var polys: Polylines = .{};
        defer polys.deinit(self.gpa);
        try dev.flatten(self.gpa, tolerance, &polys);
        return mask_mod.fill(self.gpa, &polys, winding, clip);
    }

    fn strokeMask(self: *Renderer, n: *const m.Node, shape: *const Path, ctm: Affine, fill_mask: ?*const Mask, clip: IRect) !Mask {
        var polys: Polylines = .{};
        defer polys.deinit(self.gpa);
        const sg = try self.strokeDevice(n, shape, ctm, &polys);
        var sm = try self.fillPolys(&polys, sg.winding, clip);
        switch (sg.op) {
            .none => {},
            .intersect => if (fill_mask) |fm| sm.intersectWith(fm),
            .subtract => if (fill_mask) |fm| sm.subtract(fm),
        }
        return sm;
    }

    /// The stroke's outline as device-space polylines in `out` (`shape` is the node's fill
    /// path), with how it fills and how the fill's coverage then cuts it.
    pub fn strokeDevice(self: *Renderer, n: *const m.Node, shape: *const Path, ctm: Affine, out: *Polylines) !StrokeGeometry {
        var al = n.stroke.alignFor(n.kind);
        // A stored outline is the stroke's resolved shape: draw it as it is.
        if (use_stroke_outlines and n.stroke.outline.len > 0) {
            var path: Path = .{};
            defer path.deinit(self.gpa);
            var evenodd = false;
            for (n.stroke.outline) |o| {
                geom.parseSvgPath(self.gpa, o.d, &path) catch {};
                if (o.winding == .evenodd) evenodd = true;
            }
            try devicePolys(self.gpa, &path, ctm, out);
            return .{
                .winding = if (evenodd) .evenodd else .nonzero,
                .op = StrokeGeometry.Op.of(al),
            };
        }
        const wt = n.stroke.weight;
        // Rectangles without dashes: the ring between two rounded rectangles, so per-side
        // weights and corners come out exact.
        if (strokeIsRing(n)) {
            var ring: Path = .{};
            defer ring.deinit(self.gpa);
            const d = ringInsets(n);
            try addInset(self.gpa, &ring, n.size, n.radius, d[0]);
            try addInset(self.gpa, &ring, n.size, n.radius, d[1]);
            try devicePolys(self.gpa, &ring, ctm, out);
            return .{
                .winding = .evenodd,
                .op = .none,
            };
        }
        const rect_like = switch (n.kind) {
            .frame, .component, .component_set, .instance, .rectangle => true,
            else => false,
        };

        var centre: Path = .{};
        defer centre.deinit(self.gpa);
        if (n.kind == .line) {
            // Inside draws above the line, outside below.
            const off: f32 = switch (al) {
                .inside => -wt / 2,
                .center => 0,
                .outside => wt / 2,
            };
            try centre.moveTo(self.gpa, .{
                .y = off,
            });
            try centre.lineTo(self.gpa, .{
                .x = n.size.x,
                .y = off,
            });
            al = .center;
        } else if (n.kind == .vector) {
            if (n.network) |net| try addNetworkStrokes(self.gpa, net, &centre);
            // Open paths have no inside: stroke them centred.
            if (net_has_open(n)) al = .center;
        } else {
            for (shape.verbs.items) |v| try centre.verbs.append(self.gpa, v);
            try centre.points.appendSlice(self.gpa, shape.points.items);
        }
        // Stroke in node space so non-uniform scales stretch the stroke as they should.
        const scale = @max(ctm.maxScale(), 1e-6);
        var polys: Polylines = .{};
        defer polys.deinit(self.gpa);
        try centre.flatten(self.gpa, tolerance / scale, &polys);
        if (n.stroke.dashes.len > 0) {
            var dashed: Polylines = .{};
            try dash(self.gpa, &polys, n.stroke.dashes, rect_like and !n.hasRadius(), &dashed);
            polys.deinit(self.gpa);
            polys = dashed;
        }
        const width = if (al == .center) wt else wt * 2;
        const first: u32 = @intCast(out.points.items.len);
        try mask_mod.strokeOutline(self.gpa, &polys, .{
            .width = width,
            .cap = switch (n.stroke.cap) {
                .none => .butt,
                .round => .round,
                .square => .square,
            },
            .join = switch (n.stroke.join) {
                .miter => .miter,
                .round => .round,
                .bevel => .bevel,
            },
            .miter_limit = n.stroke.miter,
        }, out);
        for (out.points.items[first..]) |*p| p.* = ctm.apply(p.*);
        return .{
            .winding = .nonzero,
            .op = StrokeGeometry.Op.of(al),
        };
    }

    /// Coverage of device-space polylines with the shape anti-aliasing.
    fn fillPolys(self: *Renderer, polys: *const Polylines, winding: mask_mod.Winding, clip: IRect) !Mask {
        return switch (shape_aa) {
            .exact => mask_mod.fill(self.gpa, polys, winding, clip),
            .figma16 => mask_mod.fillSampled(self.gpa, polys, winding, clip, &mask_mod.figma16),
            .grid16 => mask_mod.fillSampled(self.gpa, polys, winding, clip, &mask_mod.grid16),
            .standard16 => mask_mod.fillSampled(self.gpa, polys, winding, clip, &mask_mod.standard16),
            .custom => mask_mod.fillSampled(self.gpa, polys, winding, clip, custom_pattern),
        };
    }

    /// What paint `p` draws on a node of `size` under `ctm`, as a shader over device pixels
    /// (null: nothing to draw).
    pub fn shaderFor(self: *Renderer, p: *const m.Paint, size: Vec2, ctm: Affine) !?pix.Shader {
        switch (p.kind) {
            .solid => {
                const c = colour.solid(p.color);
                return .{
                    .solid = pix.premultiply(c.r, c.g, c.b, c.a),
                };
            },
            .linear, .radial, .angular, .diamond => {
                const h0 = p.handles[0];
                const h1 = p.handles[1];
                const h2 = p.handles[2];
                const g: Affine = .{
                    .a = h1.x - h0.x,
                    .b = h1.y - h0.y,
                    .c = h2.x - h0.x,
                    .d = h2.y - h0.y,
                    .e = h0.x,
                    .f = h0.y,
                };
                const full = ctm.mul(Affine.scaling(size.x, size.y)).mul(g);
                const inv = full.invert() orelse return null;
                const stops = try self.frame.allocator().alloc(pix.GradientStop, p.stops.len);
                for (p.stops, stops) |st, *o| {
                    const c = colour.stop(st.color);
                    o.* = .{
                        .at = st.at,
                        .color = .{ c.r, c.g, c.b, c.a },
                    };
                }
                return .{
                    .gradient = .{
                        .kind = switch (p.kind) {
                            .radial => .radial,
                            .angular => .angular,
                            .diamond => .diamond,
                            else => .linear,
                        },
                        .inverse = inv,
                        .stops = stops,
                    },
                };
            },
            .pattern => return null,
            .image => {
                const mip = self.images.getPtr(p.asset) orelse return null;
                // The image is placed by its own size; a chain that starts below it
                // (`Mipmap.dropFinest`) is read in its first level's pixels.
                const base = mip.levels[0];
                const iw: f32 = @floatFromInt(if (mip.width > 0) mip.width else base.w);
                const ih: f32 = @floatFromInt(if (mip.height > 0) mip.height else base.h);
                var node_to_img = imageSpace(p, size, iw, ih) orelse return null;
                if (mip.first > 0) node_to_img = Affine.scaling(@as(f32, @floatFromInt(base.w)) / iw, @as(f32, @floatFromInt(base.h)) / ih).mul(node_to_img);
                const dev_inv = ctm.invert() orelse return null;
                const inv = node_to_img.mul(dev_inv);
                return .{
                    .image = .{
                        .mip = mip,
                        .inverse = inv,
                        .tile = p.scale == .tile,
                        .decal = p.scale == .fit or p.scale == .crop,
                        .footprint = @sqrt(@abs(inv.det())),
                    },
                };
            },
        }
    }

    /// A shadow cast inward from the shape's edge: the outside, shifted, spread and
    /// blurred, kept where the shape is.
    /// Casts an inner shadow inside the node's shape (`path`; `fm` is its fill mask on
    /// `dst`).
    fn innerShadow(self: *Renderer, path: *const Path, winding: mask_mod.Winding, fm: *const Mask, e: m.Effect, ctm: Affine, dst: *Pixmap) !void {
        const scale = ctm.maxScale();
        const sigma = e.radius * scale * shadow_k;
        if (Coarse.of(ctm, sigma)) |c| return self.coarseInnerShadow(path, winding, fm, e, ctm, dst, c);
        const off = ctm.applyVector(e.offset);
        const pad: i32 = @intFromFloat(@ceil(sigma * 3 + @abs(e.spread * scale) + @max(@abs(off.x), @abs(off.y)) + 2));
        // The shape as far as the blur reads: the fill mask stops at the target's edge,
        // and a tile's edge must not cast a shadow.
        var whole = try self.rasterize(path, ctm, winding, dst.rect.outset(pad + 2));
        defer whole.deinit(self.gpa);
        const shape = &whole;
        const rect = shape.rect.outset(pad);
        const w = rect.width();
        const h = rect.height();
        const a = try self.gpa.alloc(f32, w * h);
        defer self.gpa.free(a);
        // Outside of the shape, read at the offset position.
        const ix: i32 = @intFromFloat(@round(off.x));
        const iy: i32 = @intFromFloat(@round(off.y));
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const px = rect.x0 + @as(i32, @intCast(x)) - ix;
                const py = rect.y0 + @as(i32, @intCast(y)) - iy;
                a[y * w + x] = 1 - shape.at(px, py);
            }
        }
        try pix.spreadAlpha(self.gpa, a, w, h, e.spread * scale);
        try pix.blurAlpha(self.gpa, a, w, h, sigma);
        const ec = colour.solid(e.color);
        const col = pix.premultiply(ec.r, ec.g, ec.b, ec.a);
        const r = shape.rect.intersect(dst.rect);
        var dy = r.y0;
        while (dy < r.y1) : (dy += 1) {
            const row = dst.row(dy);
            var dx = r.x0;
            while (dx < r.x1) : (dx += 1) {
                const c = a[@as(usize, @intCast(dy - rect.y0)) * w + @as(usize, @intCast(dx - rect.x0))] * shape.at(dx, dy);
                if (c <= 0) continue;
                const d = &row[@intCast(dx - dst.rect.x0)];
                const sa = col[3] * c;
                const k = 1 - sa;
                d.* = .{ col[0] * c + d[0] * k, col[1] * c + d[1] * k, col[2] * c + d[2] * k, sa + d[3] * k };
            }
        }
    }

    /// `innerShadow` on the coarse grid: the shape and its blur there, sampled back up
    /// inside the fill mask.
    fn coarseInnerShadow(self: *Renderer, path: *const Path, winding: mask_mod.Winding, fm: *const Mask, e: m.Effect, ctm: Affine, dst: *Pixmap, c: Coarse) !void {
        const lo_ctm = c.ctmFor(ctm);
        const scale = lo_ctm.maxScale();
        const sigma = e.radius * scale * shadow_k;
        const off = lo_ctm.applyVector(e.offset);
        const pad: i32 = @intFromFloat(@ceil(sigma * 3 + @abs(e.spread * scale) + @max(@abs(off.x), @abs(off.y)) + 2));
        var shape = try self.rasterize(path, lo_ctm, winding, c.rectFor(dst.rect).outset(pad + 4));
        defer shape.deinit(self.gpa);
        const rect = shape.rect.outset(pad);
        const w = rect.width();
        const h = rect.height();
        const a = try self.gpa.alloc(f32, w * h);
        defer self.gpa.free(a);
        const ix: i32 = @intFromFloat(@round(off.x));
        const iy: i32 = @intFromFloat(@round(off.y));
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const px = rect.x0 + @as(i32, @intCast(x)) - ix;
                const py = rect.y0 + @as(i32, @intCast(y)) - iy;
                a[y * w + x] = 1 - shape.at(px, py);
            }
        }
        try pix.spreadAlpha(self.gpa, a, w, h, e.spread * scale);
        try pix.blurAlpha(self.gpa, a, w, h, sigma);
        const ec = colour.solid(e.color);
        const col = pix.premultiply(ec.r, ec.g, ec.b, ec.a);
        const r = fm.rect.intersect(dst.rect);
        var dy = r.y0;
        while (dy < r.y1) : (dy += 1) {
            const row = dst.row(dy);
            var dx = r.x0;
            while (dx < r.x1) : (dx += 1) {
                const cv = c.sampleAlpha(a, rect, dx, dy) * fm.at(dx, dy);
                if (cv <= 0) continue;
                const d = &row[@intCast(dx - dst.rect.x0)];
                const sa = col[3] * cv;
                const k = 1 - sa;
                d.* = .{ col[0] * cv + d[0] * k, col[1] * cv + d[1] * k, col[2] * cv + d[2] * k, sa + d[3] * k };
            }
        }
    }

    /// Blurs what is already drawn behind the node, inside the node's shape.
    fn backgroundBlur(self: *Renderer, n: *const m.Node, e: m.Effect, ctm: Affine, dst: *Pixmap) !void {
        var shape: Path = .{};
        defer shape.deinit(self.gpa);
        _ = try self.fillPath(n, &shape);
        if (shape.verbs.items.len == 0) return;
        var mk = try self.rasterize(&shape, ctm, .nonzero, dst.rect);
        defer mk.deinit(self.gpa);
        const sigma = efx.blurReach(e) * ctm.maxScale() * background_blur_k;
        const pad: i32 = @intFromFloat(@ceil(sigma * 3));
        const rect = mk.rect.outset(pad).intersect(dst.rect);
        if (rect.isEmpty()) return;
        var copy = try Pixmap.init(self.gpa, rect);
        defer copy.deinit(self.gpa);
        copy.drawPixmap(dst, 1, .{});
        if (background_blur_clamp) {
            // Samples outside the node's bounds mirror the pixels inside them.
            const inner = mk.rect.intersect(dst.rect);
            var yy = rect.y0;
            while (yy < rect.y1) : (yy += 1) {
                const row = copy.row(yy);
                var xx = rect.x0;
                while (xx < rect.x1) : (xx += 1) {
                    const cx = efx.mirror(xx, inner.x0, inner.x1);
                    const cy = efx.mirror(yy, inner.y0, inner.y1);
                    if (cx != xx or cy != yy) row[@intCast(xx - rect.x0)] = dst.at(cx, cy);
                }
            }
        }
        if (e.progressive != null) {
            try efx.progressiveBlur(self.gpa, &copy, n, e, ctm, background_blur_k);
        } else {
            try efx.blur(self.gpa, &copy, sigma);
        }
        const r = mk.rect.intersect(dst.rect);
        var dy = r.y0;
        while (dy < r.y1) : (dy += 1) {
            const row = dst.row(dy);
            var dx = r.x0;
            while (dx < r.x1) : (dx += 1) {
                const c = mk.at(dx, dy);
                if (c <= 0) continue;
                const b = copy.at(dx, dy);
                const d = &row[@intCast(dx - dst.rect.x0)];
                d.* = .{ d[0] + (b[0] - d[0]) * c, d[1] + (b[1] - d[1]) * c, d[2] + (b[2] - d[2]) * c, d[3] + (b[3] - d[3]) * c };
            }
        }
    }

    fn dropShadow(self: *Renderer, n: *const m.Node, src: ShadowSource, e: m.Effect, ctm: Affine, dst: *Pixmap, opacity: f32) !void {
        const scale = ctm.maxScale();
        const sigma = e.radius * scale * shadow_k;
        const off = ctm.applyVector(e.offset);
        // Figma spreads shadows only of rectangles, ellipses and frames that clip their
        // content; other nodes ignore it.
        const spreads = switch (n.kind) {
            .rectangle, .ellipse => true,
            .frame, .component, .component_set, .instance => n.clip,
            else => false,
        };
        const spread = if (spreads) e.spread * scale else 0;
        const pad: i32 = @intFromFloat(@ceil(sigma * 3 + @max(spread, 0) + 2));
        const rect = src.rect().outset(pad);
        const w = rect.width();
        const h = rect.height();
        const a = try self.gpa.alloc(f32, w * h);
        defer self.gpa.free(a);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                a[y * w + x] = src.alpha(rect.x0 + @as(i32, @intCast(x)), rect.y0 + @as(i32, @intCast(y)));
            }
        }
        // A filled shape spreads by its geometry (corners stay round); anything else by
        // growing or shrinking its pixels.
        const shaped = hasVisible(n.fills) and switch (n.kind) {
            .frame, .component, .component_set, .instance, .rectangle, .ellipse => true,
            else => false,
        };
        if (shaped and spread != 0) {
            var grown: Path = .{};
            defer grown.deinit(self.gpa);
            const sp = e.spread;
            const gw = @max(0, n.size.x + 2 * sp);
            const gh = @max(0, n.size.y + 2 * sp);
            if (n.kind == .ellipse) {
                try grown.addEllipse(self.gpa, gw, gh);
            } else {
                var radii = n.radius;
                for (&radii) |*r| r.* = if (r.* > 0) @max(0, r.* + sp) else 0;
                try grown.addRoundRect(self.gpa, gw, gh, radii);
            }
            var gm = try self.rasterize(&grown, ctm.mul(Affine.translate(-sp, -sp)), .nonzero, rect);
            defer gm.deinit(self.gpa);
            // The shape's own pixels give way to the grown (or shrunk) shape; what lies
            // outside it (unclipped children) keeps its alpha.
            var own_path: Path = .{};
            defer own_path.deinit(self.gpa);
            _ = try self.fillPath(n, &own_path);
            var own = try self.rasterize(&own_path, ctm, .nonzero, rect);
            defer own.deinit(self.gpa);
            y = 0;
            while (y < h) : (y += 1) {
                var x: u32 = 0;
                while (x < w) : (x += 1) {
                    const px = rect.x0 + @as(i32, @intCast(x));
                    const py = rect.y0 + @as(i32, @intCast(y));
                    const rest = a[y * w + x] * (1 - own.at(px, py));
                    a[y * w + x] = @max(gm.at(px, py), rest);
                }
            }
        } else {
            try pix.spreadAlpha(self.gpa, a, w, h, spread);
        }
        try pix.blurAlpha(self.gpa, a, w, h, sigma);

        // Shift by the offset (whole pixels then a bilinear part) while compositing.
        const ox = off.x;
        const oy = off.y;
        const ix: i32 = @intFromFloat(@floor(ox));
        const iy: i32 = @intFromFloat(@floor(oy));
        const fx = ox - @floor(ox);
        const fy = oy - @floor(oy);
        const ec = colour.solid(e.color);
        const col = pix.premultiply(ec.r, ec.g, ec.b, ec.a);
        const target = IRect{
            .x0 = rect.x0 + ix,
            .y0 = rect.y0 + iy,
            .x1 = rect.x1 + ix + 1,
            .y1 = rect.y1 + iy + 1,
        };
        const r = target.intersect(dst.rect);
        if (r.isEmpty()) return;
        var dy = r.y0;
        while (dy < r.y1) : (dy += 1) {
            const row = dst.row(dy);
            var dx = r.x0;
            while (dx < r.x1) : (dx += 1) {
                const sx = dx - ix - rect.x0;
                const sy = dy - iy - rect.y0;
                const v = sampleShift(a, w, h, sx, sy, fx, fy);
                if (v <= 0) continue;
                var c = v * opacity;
                if (!e.behind) c *= 1 - src.alpha(dx, dy);
                if (c <= 0) continue;
                const d = &row[@intCast(dx - dst.rect.x0)];
                const sa = col[3] * c;
                const k = 1 - sa;
                d.* = .{ col[0] * c + d[0] * k, col[1] * c + d[1] * k, col[2] * c + d[2] * k, sa + d[3] * k };
            }
        }
    }
};

/// Alpha at (x - fx, y - fy) of the buffer, bilinear.
fn sampleShift(a: []const f32, w: u32, h: u32, x: i32, y: i32, fx: f32, fy: f32) f32 {
    const p00 = tap(a, w, h, x, y);
    const p10 = tap(a, w, h, x - 1, y);
    const p01 = tap(a, w, h, x, y - 1);
    const p11 = tap(a, w, h, x - 1, y - 1);
    const top = p00 + (p10 - p00) * fx;
    const bot = p01 + (p11 - p01) * fx;
    return top + (bot - top) * fy;
}

fn tap(a: []const f32, w: u32, h: u32, x: i32, y: i32) f32 {
    if (x < 0 or y < 0 or x >= w or y >= h) return 0;
    return a[@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))];
}

/// One style of a text node: its glyphs and decorations, and its paints.
pub const TextPath = struct {
    path: Path,
    fills: []const m.Paint,
    /// The run `fills` came from (null: the node's fills).
    run: ?u32 = null,
    /// Its index in the layout's styles.
    style: u32,
};

/// A glyph's outline (font units) to the node's space.
pub fn glyphTransform(g: text_layout.Placed) Affine {
    const s = g.size / @as(f32, @floatFromInt(g.font.units_per_em));
    return .{
        .a = s * g.cos,
        .b = s * g.sin,
        .c = s * g.sin,
        .d = -s * g.cos,
        .e = g.x,
        .f = g.y,
    };
}

/// An underline or strikethrough rectangle as a closed subpath.
pub fn addDecoration(gpa: std.mem.Allocator, r: geom.Rect, path: *Path) !void {
    try path.moveTo(gpa, .{
        .x = r.x0,
        .y = r.y0,
    });
    try path.lineTo(gpa, .{
        .x = r.x1,
        .y = r.y0,
    });
    try path.lineTo(gpa, .{
        .x = r.x1,
        .y = r.y1,
    });
    try path.lineTo(gpa, .{
        .x = r.x0,
        .y = r.y1,
    });
    try path.close(gpa);
}

/// A stroke's outline and how the fill's coverage cuts it: kept inside the fill, cut out
/// of it, or left alone.
pub const StrokeGeometry = struct {
    winding: mask_mod.Winding,
    op: Op,

    pub const Op = enum {
        none,
        intersect,
        subtract,

        pub fn of(al: m.StrokeAlign) Op {
            return switch (al) {
                .center => .none,
                .inside => .intersect,
                .outside => .subtract,
            };
        }
    };
};

/// Whether the node's stroke is the ring between two rounded rectangles (a rectangle-like
/// node without dashes or a stored outline).
pub fn strokeIsRing(n: *const m.Node) bool {
    if (use_stroke_outlines and n.stroke.outline.len > 0) return false;
    const rect_like = switch (n.kind) {
        .frame, .component, .component_set, .instance, .rectangle => true,
        else => false,
    };
    return rect_like and n.stroke.dashes.len == 0;
}

/// The ring's outer and inner edges as insets of the node's box (top, right, bottom,
/// left; negative grows).
pub fn ringInsets(n: *const m.Node) [2][4]f32 {
    const wt = n.stroke.weight;
    const sd = n.stroke.sides orelse [4]f32{ wt, wt, wt, wt };
    const k: f32 = switch (n.stroke.alignFor(n.kind)) {
        .inside => 0,
        .center => 0.5,
        .outside => 1,
    };
    return .{
        .{ -sd[0] * k, -sd[1] * k, -sd[2] * k, -sd[3] * k },
        .{ sd[0] * (1 - k), sd[1] * (1 - k), sd[2] * (1 - k), sd[3] * (1 - k) },
    };
}

/// `path` under `ctm`, flattened as the rasteriser flattens it.
pub fn devicePolys(gpa: std.mem.Allocator, path: *const Path, ctm: Affine, out: *Polylines) !void {
    var dev = try clonePath(gpa, path);
    defer dev.deinit(gpa);
    dev.transform(ctm);
    try dev.flatten(gpa, tolerance, out);
}

/// A rounded rectangle `size` moved in by `d` (top, right, bottom, left; negative grows),
/// corner radii shrinking (or growing) with it.
pub fn addInset(gpa: std.mem.Allocator, out: *Path, size: Vec2, radii: [4]f32, d: [4]f32) !void {
    const w = size.x - d[1] - d[3];
    const h = size.y - d[0] - d[2];
    if (w <= 0 or h <= 0) return;
    var r: [4]f32 = undefined;
    // tl, tr, br, bl: each shrinks by the larger of its two sides.
    const adj = [4][2]usize{ .{ 3, 0 }, .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 } };
    for (&r, radii, adj) |*o, rad, a| o.* = if (rad > 0) @max(0, rad - @max(d[a[0]], d[a[1]])) else 0;
    var p: Path = .{};
    defer p.deinit(gpa);
    try p.addRoundRect(gpa, w, h, r);
    p.transform(Affine.translate(d[3], d[0]));
    try out.verbs.appendSlice(gpa, p.verbs.items);
    try out.points.appendSlice(gpa, p.points.items);
}

/// Splits polylines into dashes. On rectangles each side fits a whole number of pattern
/// repeats, scaled to the side's length, starting and ending on half a dash (as Figma does).
fn dash(gpa: std.mem.Allocator, polys: *const Polylines, pattern: []const f32, per_side: bool, out: *Polylines) !void {
    var period: f32 = 0;
    for (pattern) |v| period += @max(0, v);
    if (period <= 0) {
        try out.points.appendSlice(gpa, polys.points.items);
        try out.contours.appendSlice(gpa, polys.contours.items);
        return;
    }
    for (polys.contours.items) |c| {
        const pts = polys.contour(c);
        const n = pts.len;
        const segs = if (c.closed) n else n - 1;
        if (per_side) {
            var i: usize = 0;
            while (i < segs) : (i += 1) {
                const a = pts[i];
                const b = pts[(i + 1) % n];
                const len = b.sub(a).len();
                if (len <= 0) continue;
                const reps = @max(1, @round(len / period));
                const k = len / (reps * period);
                // Start half a dash early so corners get half a dash on each side.
                try dashRun(gpa, &.{ a, b }, pattern, k, -@max(0, pattern[0]) * k / 2, out);
            }
        } else {
            var run: std.ArrayList(Vec2) = .empty;
            defer run.deinit(gpa);
            try run.appendSlice(gpa, pts);
            if (c.closed) try run.append(gpa, pts[0]);
            try dashRun(gpa, run.items, pattern, 1, 0, out);
        }
    }
}

/// Walks one polyline, emitting the "on" parts of the pattern (scaled by `k`), starting at
/// pattern position `start` (negative: before the line begins).
fn dashRun(gpa: std.mem.Allocator, pts: []const Vec2, pattern: []const f32, k: f32, start: f32, out: *Polylines) !void {
    var idx: usize = 0;
    var on = true;
    var seg_end = start + pattern[0] * k;
    var dist: f32 = 0;
    var open = false;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        const a = pts[i];
        const b = pts[i + 1];
        const len = b.sub(a).len();
        if (len <= 0) continue;
        var t0: f32 = dist;
        const t1 = dist + len;
        while (true) {
            const cut = @min(seg_end, t1);
            if (on and cut > t0) {
                const pa = a.lerp(b, (t0 - dist) / len);
                const pb = a.lerp(b, (cut - dist) / len);
                if (!open) {
                    try out.points.append(gpa, pa);
                    open = true;
                }
                try out.points.append(gpa, pb);
            }
            if (seg_end > t1) break;
            // Pattern step.
            if (on and open) {
                try closeOpen(gpa, out);
                open = false;
            }
            t0 = seg_end;
            idx = (idx + 1) % pattern.len;
            on = !on;
            seg_end += @max(0, pattern[idx]) * k;
        }
        dist = t1;
    }
    if (open) try closeOpen(gpa, out);
}

/// Ends the open run at the end of `out.points` as an open contour.
fn closeOpen(gpa: std.mem.Allocator, out: *Polylines) !void {
    var start: u32 = 0;
    if (out.contours.items.len > 0) start = out.contours.items[out.contours.items.len - 1].end;
    const end: u32 = @intCast(out.points.items.len);
    if (end - start >= 2) {
        try out.contours.append(gpa, .{
            .start = start,
            .end = end,
            .closed = false,
        });
    } else {
        out.points.shrinkRetainingCapacity(start);
    }
}

/// Where the first tile starts for an alignment: `center` puts a tile's centre on the box's.
pub fn alignStart(a: m.TileAlign, box: f32, tile: f32) f32 {
    return switch (a) {
        .start => 0,
        .center => (box - tile) / 2,
        .end => box - tile,
    };
}

pub fn blendMode(b: m.Blend) pix.BlendMode {
    return switch (b) {
        .pass_through, .normal => .normal,
        inline else => |t| @field(pix.BlendMode, @tagName(t)),
    };
}

fn hasRegionFills(n: *const m.Node) bool {
    for (n.geometry) |g| if (g.fills != null) return true;
    return false;
}

fn hasVisible(ps: []const m.Paint) bool {
    for (ps) |p| if (p.visible) return true;
    return false;
}

fn net_has_open(n: *const m.Node) bool {
    const net = n.network orelse return false;
    return net.regions.len == 0 and net.segments.len > 0;
}

fn clonePath(gpa: std.mem.Allocator, p: *const Path) !Path {
    var out: Path = .{};
    try out.verbs.appendSlice(gpa, p.verbs.items);
    try out.points.appendSlice(gpa, p.points.items);
    return out;
}

fn segmentCubic(net: m.Network, s: m.Segment, reversed: bool) [4]Vec2 {
    const p0 = net.vertices[s.from];
    const p3 = net.vertices[s.to];
    const c = [4]Vec2{ p0, p0.add(s.t0), p3.add(s.t1), p3 };
    return if (reversed) .{ c[3], c[2], c[1], c[0] } else c;
}

/// One region loop as a closed subpath: segments chained end to start.
fn addLoop(gpa: std.mem.Allocator, net: m.Network, loop: []const u32, out: *Path) !void {
    if (loop.len == 0) return;
    var cur: ?u32 = null;
    var first = true;
    for (loop, 0..) |si, i| {
        if (si >= net.segments.len) continue;
        const s = net.segments[si];
        if (s.from >= net.vertices.len or s.to >= net.vertices.len) continue;
        var reversed = false;
        if (cur) |v| {
            reversed = s.from != v and s.to == v;
        } else if (loop.len > 1 and loop[1] < net.segments.len) {
            // Orient the first segment toward the second.
            const nx = net.segments[loop[1]];
            reversed = s.from == nx.from or s.from == nx.to;
        }
        _ = i;
        const c = segmentCubic(net, s, reversed);
        if (first) {
            try out.moveTo(gpa, c[0]);
            first = false;
        }
        if (s.t0.x == 0 and s.t0.y == 0 and s.t1.x == 0 and s.t1.y == 0) {
            try out.lineTo(gpa, c[3]);
        } else {
            try out.cubicTo(gpa, c[1], c[2], c[3]);
        }
        cur = if (reversed) s.from else s.to;
    }
    try out.close(gpa);
}

/// Every segment as stroke geometry, the way Figma strokes a vector network: segments chain
/// in list order while each starts where the previous one ended (joined there); a chain
/// that returns to its start is closed. Other meetings get no join.
fn addNetworkStrokes(gpa: std.mem.Allocator, net: m.Network, out: *Path) !void {
    var i: usize = 0;
    while (i < net.segments.len) {
        const first = net.segments[i];
        if (first.from >= net.vertices.len or first.to >= net.vertices.len) {
            i += 1;
            continue;
        }
        try out.moveTo(gpa, net.vertices[first.from]);
        var end = first.from;
        var j = i;
        while (j < net.segments.len) : (j += 1) {
            const sg = net.segments[j];
            if (sg.from >= net.vertices.len or sg.to >= net.vertices.len) break;
            if (j > i and sg.from != end) break;
            const c = segmentCubic(net, sg, false);
            if (sg.t0.x == 0 and sg.t0.y == 0 and sg.t1.x == 0 and sg.t1.y == 0) {
                try out.lineTo(gpa, c[3]);
            } else {
                try out.cubicTo(gpa, c[1], c[2], c[3]);
            }
            end = sg.to;
            if (end == first.from) {
                j += 1;
                try out.close(gpa);
                break;
            }
        }
        i = j;
    }
}

/// Blurs wider than this (Gaussian sigma, device pixels) are computed on a coarse grid
/// and scaled up: zoomed far in, a shadow's sigma reaches thousands of pixels, and its
/// buffers with it. Every export the corpora check stays below (the widest is 155), so
/// they are drawn exactly as before.
pub var coarse_sigma: f32 = 160;
/// The sigma a coarse blur is brought down to (at most).
const coarse_target: f32 = 32;

/// A grid `k` (a power of two) device pixels to a cell, anchored at a node's origin, so
/// the same node lands on the same cells however the render is cut into tiles.
pub const Coarse = struct {
    k: f32,
    ax: f32,
    ay: f32,

    /// The grid for a blur of `sigma` under `ctm` (the node's), or null when it is
    /// narrow enough to draw at full resolution.
    pub fn of(ctm: Affine, sigma: f32) ?Coarse {
        if (!(sigma > coarse_sigma)) return null;
        return .{
            .k = std.math.pow(f32, 2, @ceil(std.math.log2(sigma / coarse_target))),
            .ax = @round(ctm.e),
            .ay = @round(ctm.f),
        };
    }

    pub fn ctmFor(c: Coarse, ctm: Affine) Affine {
        return Affine.scaling(1 / c.k, 1 / c.k).mul(Affine.translate(-c.ax, -c.ay)).mul(ctm);
    }

    /// The cells covering device rect `r`.
    pub fn rectFor(c: Coarse, r: IRect) IRect {
        return IRect.around(.{
            .x0 = (@as(f32, @floatFromInt(r.x0)) - c.ax) / c.k,
            .y0 = (@as(f32, @floatFromInt(r.y0)) - c.ay) / c.k,
            .x1 = (@as(f32, @floatFromInt(r.x1)) - c.ax) / c.k,
            .y1 = (@as(f32, @floatFromInt(r.y1)) - c.ay) / c.k,
        });
    }

    /// Composites `lo`, drawn on this grid, over `dst` (bilinear).
    fn drawScaledUp(c: Coarse, dst: *Pixmap, lo: *const Pixmap) void {
        var y = dst.rect.y0;
        while (y < dst.rect.y1) : (y += 1) {
            const row = dst.row(y);
            const sy = (@as(f32, @floatFromInt(y)) + 0.5 - c.ay) / c.k - 0.5;
            const y0: i32 = @intFromFloat(@floor(sy));
            const fy = sy - @floor(sy);
            if (y0 + 1 < lo.rect.y0 or y0 >= lo.rect.y1) continue;
            var x = dst.rect.x0;
            while (x < dst.rect.x1) : (x += 1) {
                const sx = (@as(f32, @floatFromInt(x)) + 0.5 - c.ax) / c.k - 0.5;
                const x0: i32 = @intFromFloat(@floor(sx));
                const fx = sx - @floor(sx);
                const a = lo.at(x0, y0);
                const b = lo.at(x0 + 1, y0);
                const cc = lo.at(x0, y0 + 1);
                const d = lo.at(x0 + 1, y0 + 1);
                var s: pix.Rgba = undefined;
                inline for (0..4) |i| s[i] = (a[i] * (1 - fx) + b[i] * fx) * (1 - fy) + (cc[i] * (1 - fx) + d[i] * fx) * fy;
                if (s[3] <= 0) continue;
                const p = &row[@intCast(x - dst.rect.x0)];
                const inv = 1 - s[3];
                p.* = .{ s[0] + p[0] * inv, s[1] + p[1] * inv, s[2] + p[2] * inv, s[3] + p[3] * inv };
            }
        }
    }

    /// `a` (alpha over `rect`, on this grid) at device pixel (x, y), bilinear.
    fn sampleAlpha(c: Coarse, a: []const f32, rect: IRect, x: i32, y: i32) f32 {
        const sx = (@as(f32, @floatFromInt(x)) + 0.5 - c.ax) / c.k - 0.5;
        const sy = (@as(f32, @floatFromInt(y)) + 0.5 - c.ay) / c.k - 0.5;
        const x0: i32 = @intFromFloat(@floor(sx));
        const y0: i32 = @intFromFloat(@floor(sy));
        const fx = sx - @floor(sx);
        const fy = sy - @floor(sy);
        const w = rect.width();
        const at = struct {
            fn f(buf: []const f32, r: IRect, ww: u32, px: i32, py: i32) f32 {
                if (px < r.x0 or py < r.y0 or px >= r.x1 or py >= r.y1) return 0;
                return buf[@as(usize, @intCast(py - r.y0)) * ww + @as(usize, @intCast(px - r.x0))];
            }
        }.f;
        const top = at(a, rect, w, x0, y0) * (1 - fx) + at(a, rect, w, x0 + 1, y0) * fx;
        const bot = at(a, rect, w, x0, y0 + 1) * (1 - fx) + at(a, rect, w, x0 + 1, y0 + 1) * fx;
        return top * (1 - fy) + bot * fy;
    }
};

/// Where a drop shadow takes its alpha from: the node's drawn layer, or its shape's
/// coverage when that is the layer's alpha (`shapeSilhouette`).
const ShadowSource = union(enum) {
    layer: *const Pixmap,
    shape: *const Mask,

    fn alpha(s: ShadowSource, x: i32, y: i32) f32 {
        return switch (s) {
            .layer => |l| l.at(x, y)[3],
            .shape => |sm| sm.at(x, y),
        };
    }

    fn rect(s: ShadowSource) IRect {
        return switch (s) {
            .layer => |l| l.rect,
            .shape => |sm| sm.rect,
        };
    }
};

/// Whether the node's silhouette (what its shadows are cast from) is its shape: a
/// container that clips its content, with a solid fill (opaque in a silhouette), and
/// nothing drawn outside the shape or over its alpha (strokes outside it, noise,
/// texture, blur). Such a node casts shadows from its shape alone, without drawing its
/// content over everything the shadow reaches.
pub fn shapeSilhouette(n: *const m.Node) bool {
    if (!(n.clip and n.kind.isContainer())) return false;
    var solid = false;
    for (n.fills) |p| {
        if (p.visible and p.kind == .solid) solid = true;
    }
    if (!solid) return false;
    if (hasVisible(n.strokes) and n.stroke.weight > 0 and n.stroke.alignFor(n.kind) != .inside) return false;
    for (n.effects) |e| {
        if (!e.visible) continue;
        switch (e.kind) {
            .noise, .texture, .layer_blur => return false,
            else => {},
        }
    }
    return true;
}

/// `effectExtent` without drop shadows: how far the layer of a node that casts them
/// from its shape must reach.
pub fn layerExtent(n: *const m.Node, ctm: Affine) f32 {
    var e: f32 = 0;
    const s = ctm.maxScale();
    for (n.effects) |ef| {
        if (!ef.visible or ef.kind == .drop_shadow) continue;
        e = @max(e, 1 + (efx.blurReach(ef) * 1.5 + @abs(ef.spread) + @max(@abs(ef.offset.x), @abs(ef.offset.y))) * s);
    }
    return e;
}

/// `effectExtent` without the drop shadows cast on the coarse grid: how far the node's
/// own layer must reach.
pub fn fineExtent(n: *const m.Node, ctm: Affine) f32 {
    var e: f32 = 0;
    const s = ctm.maxScale();
    for (n.effects) |ef| {
        if (!ef.visible) continue;
        if (ef.kind == .drop_shadow and Coarse.of(ctm, ef.radius * s * shadow_k) != null) continue;
        e = @max(e, 1 + (efx.blurReach(ef) * 1.5 + @abs(ef.spread) + @max(@abs(ef.offset.x), @abs(ef.offset.y))) * s);
    }
    return e;
}

/// How far the node's effects reach past its content, in device pixels.
pub fn effectExtent(n: *const m.Node, ctm: Affine) f32 {
    var e: f32 = 0;
    const s = ctm.maxScale();
    for (n.effects) |ef| {
        if (!ef.visible) continue;
        e = @max(e, 1 + (efx.blurReach(ef) * 1.5 + @abs(ef.spread) + @max(@abs(ef.offset.x), @abs(ef.offset.y))) * s);
    }
    return e;
}

/// Device-space bounds that hold everything the node and its descendants may paint,
/// effects included, with room to spare: strokes may miter past their weight, glyphs
/// overflow their box, and a pixel of anti-aliasing. Used to skip nodes outside a tile.
pub fn cullBounds(n: *const m.Node, ctm: Affine) geom.Rect {
    if (!n.visible) return .empty;
    const s = ctm.maxScale();
    var r: geom.Rect = .empty;
    if (n.kind != .group) {
        var pad: f32 = 0;
        if (hasVisible(n.strokes)) {
            var w = n.stroke.weight;
            if (n.stroke.sides) |sides| for (sides) |sw| {
                w = @max(w, sw);
            };
            for (n.stroke.widths) |wp| w = @max(w, n.stroke.weight * 2 * @max(wp.ascent, wp.descent));
            pad = w * @max(4, n.stroke.miter);
            if (n.stroke.brush != null or n.stroke.dynamic != null) pad += w * 8;
        }
        if (n.text) |t| {
            var fs: f32 = t.style.size orelse 12;
            for (t.runs) |run| fs = @max(fs, run.style.size orelse 0);
            pad = @max(pad, n.size.y + 2 * fs);
        }
        r = geom.Rect.transformed(.{
            .x0 = -pad,
            .y0 = -pad,
            .x1 = n.size.x + pad,
            .y1 = n.size.y + pad,
        }, ctm);
    }
    if (!(n.clip and n.kind.isContainer())) {
        for (n.children) |*c| r = r.unite(cullBounds(c, ctm.mul(c.transform)));
    }
    if (r.isEmpty()) return r;
    return r.outset(effectExtent(n, ctm) + efx.textureRoom(n, ctm) + 2 + s);
}

/// Device-space bounds of everything the node may paint (effects excluded).
pub fn visualBounds(n: *const m.Node, ctm: Affine) geom.Rect {
    var r: geom.Rect = .empty;
    if (n.kind != .group) {
        const pad: f32 = if (hasVisible(n.strokes)) n.stroke.weight * @as(f32, if (n.stroke.alignFor(n.kind) == .inside) 0 else 1) + 1 else 0;
        r = geom.Rect.transformed(.{
            .x0 = -pad,
            .y0 = -pad,
            .x1 = n.size.x + pad,
            .y1 = n.size.y + pad,
        }, ctm);
    }
    if (!(n.clip and n.kind.isContainer())) {
        for (n.children) |*c| {
            if (!c.visible) continue;
            const cm = ctm.mul(c.transform);
            var cb = visualBounds(c, cm);
            const ext = effectExtent(c, cm);
            if (ext > 0) cb = cb.outset(ext);
            r = r.unite(cb);
        }
    }
    return r;
}

/// The area node `n` paints, device space, as an export frames it: its box, strokes past
/// it, what its children paint (inside a clipping frame: within the box), drop shadows
/// (offset, spread and blur radius) and layer blurs (blur radius). Tight, unlike
/// `cullBounds`.
pub fn exportBounds(n: *const m.Node, ctm: Affine) geom.Rect {
    return exportBoundsWith(n, ctm, null);
}

/// `exportBounds` with a text's ink (its glyphs as drawn) where a renderer is at hand,
/// as Figma frames a text: by what it draws, not its box.
fn exportBoundsWith(n: *const m.Node, ctm: Affine, r_in: ?*Renderer) geom.Rect {
    if (!n.visible or n.opacity <= 0) return .empty;
    if (n.kind == .text) if (r_in) |rr| {
        var list: std.ArrayList(TextPath) = .empty;
        defer {
            for (list.items) |*tp| tp.path.deinit(rr.gpa);
            list.deinit(rr.gpa);
        }
        rr.textPaths(n, &list) catch {};
        var ink: geom.Rect = .empty;
        for (list.items) |tp| {
            const pb = tp.path.bounds();
            if (!pb.isEmpty()) ink = ink.unite(geom.Rect.transformed(pb, ctm));
        }
        if (!ink.isEmpty()) return effectsAround(n, ctm, ink);
    };
    var r: geom.Rect = .empty;
    if (n.kind != .group) {
        var pad: f32 = 0;
        if (hasVisible(n.strokes)) {
            var w = n.stroke.weight;
            if (n.stroke.sides) |sides| for (sides) |sw| {
                w = @max(w, sw);
            };
            pad = switch (n.stroke.alignFor(n.kind)) {
                .inside => 0,
                .center => w / 2,
                .outside => w,
            };
        }
        const paints_box = n.kind != .text and (hasVisible(n.fills) or pad > 0 or n.kind.isContainer());
        if (paints_box or n.kind == .text) r = geom.Rect.transformed(.{
            .x0 = -pad,
            .y0 = -pad,
            .x1 = n.size.x + pad,
            .y1 = n.size.y + pad,
        }, ctm);
    }
    var kids: geom.Rect = .empty;
    var masked = false;
    for (n.children) |*c| {
        if (!c.visible) continue;
        const cb = exportBoundsWith(c, ctm.mul(c.transform), r_in);
        if (c.mask != null) {
            // A mask limits what follows it to its own area.
            kids = kids.unite(cb);
            masked = true;
            continue;
        }
        if (!masked) kids = kids.unite(cb);
    }
    if (n.clip and n.kind.isContainer()) {
        const box = geom.Rect.transformed(.{
            .x1 = n.size.x,
            .y1 = n.size.y,
        }, ctm);
        kids = kids.intersect(box);
    }
    if (!kids.isEmpty()) r = r.unite(kids);
    return effectsAround(n, ctm, r);
}

/// `r` (what `n` paints) with what its drop shadows and layer blurs add.
fn effectsAround(n: *const m.Node, ctm: Affine, r: geom.Rect) geom.Rect {
    if (r.isEmpty()) return r;
    const s = ctm.maxScale();
    var out = r;
    for (n.effects) |e| {
        if (!e.visible) continue;
        switch (e.kind) {
            .drop_shadow => {
                const reach = (@max(0, e.spread) + efx.blurReach(e)) * s;
                const d = ctm.applyVector(e.offset);
                out = out.unite((geom.Rect{
                    .x0 = r.x0 + d.x,
                    .y0 = r.y0 + d.y,
                    .x1 = r.x1 + d.x,
                    .y1 = r.y1 + d.y,
                }).outset(reach));
            },
            .layer_blur => out = out.unite(r.outset(efx.blurReach(e) * s)),
            else => {},
        }
    }
    return out;
}

test "render a frame with a child, shadow and gradient" {
    const gpa = std.testing.allocator;
    var images: Images = .empty;
    var r = Renderer.init(gpa, &images);
    defer r.deinit();
    var stops = [_]m.Stop{ .{
        .at = 0,
        .color = .{
            .r = 1,
        },
    }, .{
        .at = 1,
        .color = .{
            .b = 1,
        },
    } };
    var child_fills = [_]m.Paint{.{
        .kind = .linear,
        .stops = &stops,
        .handles = .{ .{
            .y = 0.5,
        }, .{
            .x = 1,
            .y = 0.5,
        }, .{} },
    }};
    var effects = [_]m.Effect{.{
        .kind = .drop_shadow,
        .radius = 4,
        .offset = .{
            .y = 2,
        },
    }};
    var children = [_]m.Node{.{
        .id = "c",
        .kind = .rectangle,
        .transform = .translate(4, 4),
        .size = .{
            .x = 8,
            .y = 8,
        },
        .fills = &child_fills,
        .effects = &effects,
    }};
    var fills = [_]m.Paint{.{
        .kind = .solid,
        .color = .{
            .r = 1,
            .g = 1,
            .b = 1,
        },
    }};
    const frame: m.Node = .{
        .id = "f",
        .kind = .frame,
        .size = .{
            .x = 16,
            .y = 16,
        },
        .fills = &fills,
        .clip = true,
        .children = &children,
    };
    var out = try r.renderExport(&frame, 1);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 16), out.rect.width());
    const left = out.at(4, 8);
    const right = out.at(11, 8);
    try std.testing.expect(left[0] > 0.8 and left[2] < 0.2);
    try std.testing.expect(right[2] > 0.8 and right[0] < 0.2);
    // Shadow below the child darkens the white frame.
    try std.testing.expect(out.at(8, 13)[0] < 0.95);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out.at(0, 0)[0], 1e-4);
}

test {
    _ = colour;
}
