//! Figma REST JSON (`GET /v1/files/:key?geometry=paths`) to a Pubd document.
//!
//! Built from Figma's public REST API documentation and files we made ourselves.

const std = @import("std");
const m = @import("../pubd/model.zig");
const geom = @import("../raster/geom.zig");

const jv = @import("../jv.zig");
const Value = jv.Value;
const get = jv.get;
const str = jv.str;
const boolean = jv.boolean;
const num = jv.num;
const numberOf = jv.numberOf;
const arr = jv.arr;
const Vec2 = geom.Vec2;

pub const ImageRef = struct {
    /// Figma's `imageRef`.
    ref: []const u8,
    /// The asset hash the document uses for it (filled in by the caller once the bytes
    /// are known).
    hash: []const u8,
};

pub const Result = struct {
    doc: m.Document,
    /// Every `imageRef` the document uses, in first-use order. Image paints carry the
    /// ref as `asset` until `resolveImages` swaps in hashes.
    images: []ImageRef,
};

/// Parses the REST response and builds the document. Everything lives in the document's
/// arena.
pub fn import(gpa: std.mem.Allocator, json: []const u8) !Result {
    var doc: m.Document = .{
        .arena = .init(gpa),
    };
    errdefer doc.deinit();
    const a = doc.arena.allocator();
    const root = try std.json.parseFromSliceLeaky(Value, a, json, .{
        .duplicate_field_behavior = .use_last,
    });
    var ctx: Ctx = .{
        .a = a,
    };
    doc.name = str(root, "name") orelse "";

    const document = get(root, "document") orelse return error.NotAFigmaFile;
    var known_nodes: std.StringHashMapUnmanaged(void) = .empty;
    try collectIds(a, document, &known_nodes);
    ctx.known = &known_nodes;

    var pages: std.ArrayList(m.Node) = .empty;
    for (arr(document, "children")) |page| try pages.append(a, try ctx.node(page));
    doc.pages = pages.items;

    if (get(root, "styles")) |styles| if (styles == .object) {
        var list: std.ArrayList(m.Style) = .empty;
        var it = styles.object.iterator();
        while (it.next()) |e| {
            const kind: m.StyleKind = blk: {
                const t = str(e.value_ptr.*, "styleType") orelse continue;
                if (std.mem.eql(u8, t, "FILL")) break :blk .fill;
                if (std.mem.eql(u8, t, "TEXT")) break :blk .text;
                if (std.mem.eql(u8, t, "EFFECT")) break :blk .effect;
                if (std.mem.eql(u8, t, "GRID")) break :blk .grid;
                continue;
            };
            try list.append(a, .{
                .id = e.key_ptr.*,
                .kind = kind,
                .name = str(e.value_ptr.*, "name") orelse "",
                .description = str(e.value_ptr.*, "description") orelse "",
            });
        }
        doc.styles = list.items;
    };

    return .{
        .doc = doc,
        .images = ctx.images.items,
    };
}

/// Replaces image refs in paints with asset hashes (`images[i].hash`).
pub fn resolveImages(doc: *m.Document, images: []const ImageRef) void {
    for (doc.pages) |*p| resolveNode(p, images);
}

/// `resolveImages` for one node and everything under it (a page built on its own).
pub fn resolveImagesIn(n: *m.Node, images: []const ImageRef) void {
    resolveNode(n, images);
}

fn resolveNode(n: *m.Node, images: []const ImageRef) void {
    for (n.fills) |*p| resolvePaint(p, images);
    for (n.strokes) |*p| resolvePaint(p, images);
    if (n.text) |t| for (t.runs) |r| if (r.fills) |fs| for (fs) |*p| resolvePaint(p, images);
    for (n.children) |*c| resolveNode(c, images);
}

fn resolvePaint(p: *m.Paint, images: []const ImageRef) void {
    if (p.kind != .image) return;
    for (images) |im| if (std.mem.eql(u8, im.ref, p.asset)) {
        p.asset = im.hash;
        return;
    };
}

fn collectIds(a: std.mem.Allocator, n: Value, out: *std.StringHashMapUnmanaged(void)) !void {
    if (str(n, "id")) |id| try out.put(a, id, {});
    for (arr(n, "children")) |c| try collectIds(a, c, out);
}

const Ctx = struct {
    a: std.mem.Allocator,
    known: *const std.StringHashMapUnmanaged(void) = undefined,
    images: std.ArrayList(ImageRef) = .empty,

    fn node(ctx: *Ctx, v: Value) !m.Node {
        const t = str(v, "type") orelse return error.BadNode;
        const kind = kindOf(t);
        var n: m.Node = .{
            .id = str(v, "id") orelse return error.BadNode,
            .kind = kind,
            .name = str(v, "name") orelse "",
            .visible = boolean(v, "visible") orelse true,
            .locked = boolean(v, "locked") orelse false,
            .opacity = num(v, "opacity") orelse 1,
            .blend = blendOf(str(v, "blendMode") orelse "PASS_THROUGH"),
        };
        if (kind == .page) {
            if (get(v, "backgroundColor")) |c| n.background = color(c);
        } else {
            if (get(v, "relativeTransform")) |rt| n.transform = transformOf(rt);
            if (get(v, "size")) |s| n.size = .{
                .x = num(s, "x") orelse 0,
                .y = num(s, "y") orelse 0,
            };
        }

        n.fills = try ctx.paints(arr(v, "fills"));
        n.strokes = try ctx.paints(arr(v, "strokes"));
        n.stroke = strokeOf(ctx.a, v) catch .{};
        n.effects = try ctx.effects(arr(v, "effects"));

        if (get(v, "styles")) |s| n.styles = .{
            .fill = str(s, "fill") orelse str(s, "fills"),
            .stroke = str(s, "stroke") orelse str(s, "strokes"),
            .effect = str(s, "effect") orelse str(s, "effects"),
            .text = str(s, "text"),
            .grid = str(s, "grid"),
        };

        if (get(v, "rectangleCornerRadii")) |r| {
            const items = if (r == .array) r.array.items else &.{};
            if (items.len == 4) {
                for (&n.radius, items) |*d, s| d.* = numberOf(s) orelse 0;
            }
        } else if (num(v, "cornerRadius")) |r| {
            n.radius = .{ r, r, r, r };
        }
        n.smoothing = num(v, "cornerSmoothing") orelse 0;
        if (kind.isContainer()) n.clip = boolean(v, "clipsContent") orelse false;

        if (str(v, "layoutMode")) |mode| if (!std.mem.eql(u8, mode, "NONE")) {
            n.layout = try layoutOf(ctx.a, v, mode);
        };
        n.min_width = num(v, "minWidth");
        n.max_width = num(v, "maxWidth");
        n.min_height = num(v, "minHeight");
        n.max_height = num(v, "maxHeight");
        if (num(v, "gridColumnAnchorIndex") != null or num(v, "gridRowAnchorIndex") != null) n.cell = .{
            .column = whole(v, "gridColumnAnchorIndex", 0),
            .row = whole(v, "gridRowAnchorIndex", 0),
            .column_span = whole(v, "gridColumnSpan", 1),
            .row_span = whole(v, "gridRowSpan", 1),
            .h = cellAlign(str(v, "gridChildHorizontalAlign") orelse "AUTO"),
            .v = cellAlign(str(v, "gridChildVerticalAlign") orelse "AUTO"),
        };
        if (get(v, "constraints")) |c| n.constraints = .{
            .h = hConstraint(str(c, "horizontal") orelse "LEFT"),
            .v = vConstraint(str(c, "vertical") orelse "TOP"),
        };
        if (str(v, "layoutSizingHorizontal") != null or str(v, "layoutSizingVertical") != null) n.sizing = .{
            .w = childSizing(str(v, "layoutSizingHorizontal") orelse "FIXED"),
            .h = childSizing(str(v, "layoutSizingVertical") orelse "FIXED"),
        };
        n.absolute = std.mem.eql(u8, str(v, "layoutPositioning") orelse "", "ABSOLUTE");
        n.grids = try ctx.grids(arr(v, "layoutGrids"));

        if (kind == .instance) {
            if (str(v, "componentId")) |cid| if (ctx.known.contains(cid)) {
                n.component = cid;
            };
            n.scale = num(v, "uniformScaleFactor") orelse 1;
        }
        if (kind == .ellipse) if (get(v, "arcData")) |ad| {
            n.arc = .{
                .start = num(ad, "startingAngle") orelse 0,
                .end = num(ad, "endingAngle") orelse std.math.tau,
                .inner = num(ad, "innerRadius") orelse 0,
            };
        };
        if (kind == .vector or kind == .text) if (get(v, "vectorNetwork")) |net| {
            n.network = try ctx.network(net, n.size);
        };
        if (kind == .text) n.text = try ctx.text(v);
        switch (kind) {
            .vector, .star, .polygon, .boolean, .ellipse => n.geometry = try ctx.geometry(v),
            else => {},
        }
        if (kind == .star or kind == .polygon) n.count = @intFromFloat(@max(0, num(v, "count") orelse 0));
        if (kind == .star) n.inner_scale = num(v, "starInnerScale") orelse 0.382;
        if (kind == .boolean) {
            const op = str(v, "booleanOperation") orelse "UNION";
            n.boolean_op = if (std.mem.eql(u8, op, "INTERSECT")) .intersect else if (std.mem.eql(u8, op, "SUBTRACT")) .subtract else if (std.mem.eql(u8, op, "EXCLUDE")) .exclude else .@"union";
        }
        if (boolean(v, "isMask") orelse false) {
            const mt = str(v, "maskType") orelse "ALPHA";
            n.mask = if (std.mem.eql(u8, mt, "VECTOR")) .vector else if (std.mem.eql(u8, mt, "LUMINANCE")) .luminance else .alpha;
        }
        n.reverse_z = boolean(v, "itemReverseZIndex") orelse false;
        for (arr(v, "transformModifiers")) |mod| {
            if (!std.mem.eql(u8, str(mod, "type") orelse "", "REPEAT")) continue;
            n.repeat = .{
                .kind = if (std.mem.eql(u8, str(mod, "repeatType") orelse "", "RADIAL")) .radial else .linear,
                .count = @intFromFloat(@max(1, num(mod, "count") orelse 1)),
                .offset = num(mod, "offset") orelse 0,
                .vertical = std.mem.eql(u8, str(mod, "axis") orelse "", "VERTICAL"),
            };
        }

        try ctx.componentFields(&n, v, kind);

        var children: std.ArrayList(m.Node) = .empty;
        for (arr(v, "children")) |c| try children.append(ctx.a, try ctx.node(c));
        n.children = children.items;
        return n;
    }

    /// Component property definitions (`componentPropertyDefinitions`, keyed `Name#id`
    /// or, for a variant property, by name), what a node's fields follow
    /// (`componentPropertyReferences`), and an instance's values (`componentProperties`).
    fn componentFields(ctx: *Ctx, n: *m.Node, v: Value, kind: m.Kind) !void {
        const a = ctx.a;
        if (kind == .component or kind == .component_set) if (get(v, "componentPropertyDefinitions")) |defs| if (defs == .object) {
            var list: std.ArrayList(m.PropDef) = .empty;
            var it = defs.object.iterator();
            while (it.next()) |e| {
                const t = str(e.value_ptr.*, "type") orelse continue;
                const pk: m.PropKind = if (std.mem.eql(u8, t, "BOOLEAN")) .boolean else if (std.mem.eql(u8, t, "TEXT")) .text else if (std.mem.eql(u8, t, "INSTANCE_SWAP")) .instance_swap else if (std.mem.eql(u8, t, "VARIANT")) .variant else continue;
                var options: std.ArrayList([]const u8) = .empty;
                for (arr(e.value_ptr.*, "variantOptions")) |o| if (o == .string) try options.append(a, o.string);
                const name = if (std.mem.indexOfScalar(u8, e.key_ptr.*, '#')) |at| e.key_ptr.*[0..at] else e.key_ptr.*;
                try list.append(a, .{
                    .id = e.key_ptr.*,
                    .name = name,
                    .kind = pk,
                    .default = if (get(e.value_ptr.*, "defaultValue")) |d| try std.json.Stringify.valueAlloc(a, d, .{}) else "null",
                    .options = options.items,
                });
            }
            n.properties = list.items;
        };
        if (get(v, "componentPropertyReferences")) |refs| n.bind = .{
            .visible = str(refs, "visible"),
            .text = str(refs, "characters"),
            .component = str(refs, "mainComponent"),
        };
        if (kind == .instance) if (get(v, "componentProperties")) |props| if (props == .object) {
            var list: std.ArrayList(m.PropValue) = .empty;
            var it = props.object.iterator();
            while (it.next()) |e| {
                // A variant property is the instance's component.
                if (std.mem.eql(u8, str(e.value_ptr.*, "type") orelse "", "VARIANT")) continue;
                const val = get(e.value_ptr.*, "value") orelse continue;
                try list.append(a, .{
                    .id = e.key_ptr.*,
                    .value = try std.json.Stringify.valueAlloc(a, val, .{}),
                });
            }
            n.props = list.items;
        };
    }

    fn paints(ctx: *Ctx, list: []const Value) ![]m.Paint {
        var out: std.ArrayList(m.Paint) = .empty;
        for (list) |p| if (try ctx.paint(p)) |pp| try out.append(ctx.a, pp);
        return out.items;
    }

    fn paint(ctx: *Ctx, v: Value) !?m.Paint {
        const t = str(v, "type") orelse return null;
        var p: m.Paint = .{
            .kind = .solid,
            .visible = boolean(v, "visible") orelse true,
            .opacity = num(v, "opacity") orelse 1,
            .blend = blendOf(str(v, "blendMode") orelse "NORMAL"),
        };
        if (std.mem.eql(u8, t, "SOLID")) {
            p.color = if (get(v, "color")) |c| color(c) else .{};
        } else if (std.mem.startsWith(u8, t, "GRADIENT_")) {
            const g = t["GRADIENT_".len..];
            p.kind = if (std.mem.eql(u8, g, "LINEAR")) .linear else if (std.mem.eql(u8, g, "RADIAL")) .radial else if (std.mem.eql(u8, g, "ANGULAR")) .angular else .diamond;
            const hs = arr(v, "gradientHandlePositions");
            for (hs[0..@min(3, hs.len)], 0..) |h, i| p.handles[i] = .{
                .x = num(h, "x") orelse 0,
                .y = num(h, "y") orelse 0,
            };
            var stops: std.ArrayList(m.Stop) = .empty;
            for (arr(v, "gradientStops")) |s| try stops.append(ctx.a, .{
                .at = num(s, "position") orelse 0,
                .color = if (get(s, "color")) |c| color(c) else .{},
            });
            p.stops = stops.items;
        } else if (std.mem.eql(u8, t, "IMAGE")) {
            p.kind = .image;
            const ref = str(v, "imageRef") orelse return null;
            p.asset = ref;
            var seen = false;
            for (ctx.images.items) |im| if (std.mem.eql(u8, im.ref, ref)) {
                seen = true;
            };
            if (!seen) try ctx.images.append(ctx.a, .{
                .ref = ref,
                .hash = ref,
            });
            const sm = str(v, "scaleMode") orelse "FILL";
            p.scale = if (std.mem.eql(u8, sm, "FIT")) .fit else if (std.mem.eql(u8, sm, "TILE")) .tile else if (std.mem.eql(u8, sm, "STRETCH")) .stretch else if (std.mem.eql(u8, sm, "CROP")) .crop else .fill;
            if (get(v, "imageTransform")) |it| p.image_transform = transformOf(it);
            p.tile = num(v, "scalingFactor") orelse 1;
        } else if (std.mem.eql(u8, t, "PATTERN")) {
            p.kind = .pattern;
            p.source = str(v, "sourceNodeId") orelse return null;
            const tt = str(v, "tileType") orelse "RECTANGULAR";
            p.tile_type = if (std.mem.eql(u8, tt, "HORIZONTAL_HEXAGONAL")) .horizontal_hexagonal else if (std.mem.eql(u8, tt, "VERTICAL_HEXAGONAL")) .vertical_hexagonal else .rectangular;
            p.tile = num(v, "scalingFactor") orelse 1;
            if (get(v, "spacing")) |sp| p.spacing = .{
                .x = num(sp, "x") orelse 0,
                .y = num(sp, "y") orelse 0,
            };
            p.h_align = tileAlign(str(v, "horizontalAlignment") orelse "START");
            p.v_align = tileAlign(str(v, "verticalAlignment") orelse "START");
        } else return null;
        return p;
    }

    /// Figma's resolved fill outline, with per-region fills from `fillOverrideTable`.
    fn geometry(ctx: *Ctx, v: Value) ![]m.GeometryPath {
        const geo = arr(v, "fillGeometry");
        var out: std.ArrayList(m.GeometryPath) = .empty;
        const table = get(v, "fillOverrideTable");
        for (geo) |g| {
            const d = str(g, "path") orelse continue;
            const w = str(g, "windingRule") orelse "NONZERO";
            var gp: m.GeometryPath = .{
                .d = d,
                .winding = if (std.ascii.eqlIgnoreCase(w, "EVENODD")) .evenodd else .nonzero,
            };
            if (num(g, "overrideID")) |oid| if (table) |tb| {
                var kb: [24]u8 = undefined;
                const key = std.fmt.bufPrint(&kb, "{d}", .{@as(i64, @intFromFloat(oid))}) catch unreachable;
                if (get(tb, key)) |o| if (get(o, "fills")) |fs| if (fs == .array) {
                    gp.fills = try ctx.paints(fs.array.items);
                };
            };
            try out.append(ctx.a, gp);
        }
        return out.items;
    }

    fn effects(ctx: *Ctx, list: []const Value) ![]m.Effect {
        var out: std.ArrayList(m.Effect) = .empty;
        for (list) |e| {
            const t = str(e, "type") orelse continue;
            const kind: m.EffectKind = if (std.mem.eql(u8, t, "DROP_SHADOW")) .drop_shadow else if (std.mem.eql(u8, t, "INNER_SHADOW")) .inner_shadow else if (std.mem.eql(u8, t, "LAYER_BLUR")) .layer_blur else if (std.mem.eql(u8, t, "BACKGROUND_BLUR")) .background_blur else if (std.mem.eql(u8, t, "NOISE")) .noise else if (std.mem.eql(u8, t, "TEXTURE")) .texture else continue;
            const nt = str(e, "noiseType") orelse "MONOTONE";
            // REST gives one grain size (a non-square grain loses its height).
            const grain = num(e, "noiseSize") orelse 2;
            try out.append(ctx.a, .{
                .kind = kind,
                .visible = boolean(e, "visible") orelse true,
                .color = if (get(e, "color")) |c| color(c) else .{
                    .a = 0.25,
                },
                .offset = if (get(e, "offset")) |o| .{
                    .x = num(o, "x") orelse 0,
                    .y = num(o, "y") orelse 0,
                } else .{},
                .radius = num(e, "radius") orelse 0,
                .spread = num(e, "spread") orelse 0,
                .behind = boolean(e, "showShadowBehindNode") orelse false,
                .blend = blendOf(str(e, "blendMode") orelse "NORMAL"),
                .progressive = if (std.mem.eql(u8, str(e, "blurType") orelse "NORMAL", "PROGRESSIVE")) .{
                    .start = if (get(e, "startOffset")) |o| .{
                        .x = num(o, "x") orelse 0,
                        .y = num(o, "y") orelse 0,
                    } else .{},
                    .end = if (get(e, "endOffset")) |o| .{
                        .x = num(o, "x") orelse 0,
                        .y = num(o, "y") orelse 1,
                    } else .{
                        .y = 1,
                    },
                    .start_radius = num(e, "startRadius") orelse 0,
                } else null,
                .grain = .{
                    .x = grain,
                    .y = grain,
                },
                .noise = if (std.mem.eql(u8, nt, "DUOTONE")) .duotone else if (std.mem.eql(u8, nt, "MULTITONE")) .multitone else .monotone,
                .density = num(e, "density") orelse 0.5,
                .secondary = if (get(e, "secondaryColor")) |c| color(c) else .{},
                .opacity = num(e, "opacity") orelse 1,
                .clip = boolean(e, "clipToShape") orelse true,
            });
        }
        return out.items;
    }

    fn grids(ctx: *Ctx, list: []const Value) ![]m.Grid {
        var out: std.ArrayList(m.Grid) = .empty;
        for (list) |g| {
            const pat = str(g, "pattern") orelse "COLUMNS";
            const al = str(g, "alignment") orelse "STRETCH";
            try out.append(ctx.a, .{
                .kind = if (std.mem.eql(u8, pat, "ROWS")) .rows else if (std.mem.eql(u8, pat, "GRID")) .grid else .columns,
                .count = @intFromFloat(@max(0, num(g, "count") orelse 0)),
                .gutter = num(g, "gutterSize") orelse 0,
                .offset = num(g, "offset") orelse 0,
                .size = num(g, "sectionSize") orelse 0,
                .@"align" = if (std.mem.eql(u8, al, "MIN")) .start else if (std.mem.eql(u8, al, "MAX")) .end else if (std.mem.eql(u8, al, "CENTER")) .center else .stretch,
                .color = if (get(g, "color")) |c| color(c) else .{
                    .r = 1,
                    .a = 0.1,
                },
                .visible = boolean(g, "visible") orelse true,
            });
        }
        return out.items;
    }

    /// Figma stores a vector's network in the space it was drawn in; the node may since
    /// have been scaled. Fit the network's geometric bounds to the node's size.
    fn network(ctx: *Ctx, v: Value, size: Vec2) !m.Network {
        var net: m.Network = .{};
        var verts: std.ArrayList(Vec2) = .empty;
        for (arr(v, "vertices")) |vx| {
            const p = get(vx, "position") orelse continue;
            try verts.append(ctx.a, .{
                .x = num(p, "x") orelse 0,
                .y = num(p, "y") orelse 0,
            });
        }
        var segs: std.ArrayList(m.Segment) = .empty;
        for (arr(v, "segments")) |s| {
            const t0 = get(s, "startTangent");
            const t1 = get(s, "endTangent");
            try segs.append(ctx.a, .{
                .from = @intFromFloat(num(s, "start") orelse 0),
                .to = @intFromFloat(num(s, "end") orelse 0),
                .t0 = if (t0) |t| .{
                    .x = num(t, "x") orelse 0,
                    .y = num(t, "y") orelse 0,
                } else .{},
                .t1 = if (t1) |t| .{
                    .x = num(t, "x") orelse 0,
                    .y = num(t, "y") orelse 0,
                } else .{},
            });
        }
        var regions: std.ArrayList(m.Region) = .empty;
        for (arr(v, "regions")) |r| {
            var loops: std.ArrayList([]u32) = .empty;
            for (arr(r, "loops")) |l| {
                var ids: std.ArrayList(u32) = .empty;
                if (l == .array) for (l.array.items) |i| try ids.append(ctx.a, @intFromFloat(numberOf(i) orelse 0));
                try loops.append(ctx.a, ids.items);
            }
            const w = str(r, "windingRule") orelse "nonzero";
            try regions.append(ctx.a, .{
                .winding = if ((std.ascii.eqlIgnoreCase(w, "evenodd") or std.ascii.eqlIgnoreCase(w, "odd"))) .evenodd else .nonzero,
                .loops = loops.items,
            });
        }
        net = .{
            .vertices = verts.items,
            .segments = segs.items,
            .regions = regions.items,
        };
        fitNetwork(&net, size);
        return net;
    }

    fn text(ctx: *Ctx, v: Value) !m.Text {
        var t: m.Text = .{
            .text = str(v, "characters") orelse "",
        };
        const style = get(v, "style") orelse return t;
        t.style = textStyle(style);
        t.resize = textResize(str(style, "textAutoResize") orelse "NONE");
        const ha = str(style, "textAlignHorizontal") orelse "LEFT";
        t.@"align" = if (std.mem.eql(u8, ha, "CENTER")) .center else if (std.mem.eql(u8, ha, "RIGHT")) .right else if (std.mem.eql(u8, ha, "JUSTIFIED")) .justify else .left;
        const va = str(style, "textAlignVertical") orelse "TOP";
        t.valign = if (std.mem.eql(u8, va, "CENTER")) .center else if (std.mem.eql(u8, va, "BOTTOM")) .bottom else .top;
        if (std.mem.eql(u8, str(style, "textTruncation") orelse "", "ENDING")) t.truncation = .ending;
        if (num(style, "maxLines")) |ml| if (ml >= 1) {
            t.max_lines = @intFromFloat(ml);
        };
        const wrap = str(style, "textWrapStyle") orelse "AUTO";
        t.wrap = if (std.mem.eql(u8, wrap, "BALANCE")) .balance else if (std.mem.eql(u8, wrap, "PRETTY")) .pretty else .auto;
        if (std.mem.eql(u8, str(style, "leadingTrim") orelse "", "CAP_HEIGHT")) t.leading_trim = .cap_height;
        t.hanging_punctuation = boolean(style, "hangingPunctuation") orelse false;
        t.hanging_list = boolean(style, "hangingList") orelse false;
        const types = arr(v, "lineTypes");
        const indents = arr(v, "lineIndentations");
        var any_list = false;
        for (types, 0..) |lt, k| {
            const name = if (lt == .string) lt.string else "NONE";
            const indent = if (k < indents.len) numberOf(indents[k]) orelse 0 else 0;
            if (!std.mem.eql(u8, name, "NONE") or indent != 0) any_list = true;
        }
        if (any_list) {
            const lists = try ctx.a.alloc(m.ParagraphList, types.len);
            for (lists, types, 0..) |*l, lt, k| {
                const name = if (lt == .string) lt.string else "NONE";
                l.* = .{
                    .type = if (std.mem.eql(u8, name, "ORDERED")) .ordered else if (std.mem.eql(u8, name, "UNORDERED")) .unordered else .none,
                    .indent = @intFromFloat(std.math.clamp(if (k < indents.len) numberOf(indents[k]) orelse 0 else 0, 0, 255)),
                };
            }
            t.lists = lists;
        }
        if (get(v, "textPathStartData")) |ps| t.path_start = .{
            .segment = @intFromFloat(@max(0, num(ps, "segment") orelse 0)),
            .position = num(ps, "position") orelse 0,
        };

        const overrides = arr(v, "characterStyleOverrides");
        const table = get(v, "styleOverrideTable");
        var runs: std.ArrayList(m.Run) = .empty;
        var i: usize = 0;
        while (i < overrides.len) {
            const id = numberOf(overrides[i]) orelse 0;
            var j = i + 1;
            while (j < overrides.len and (numberOf(overrides[j]) orelse 0) == id) j += 1;
            if (id != 0) if (table) |tb| {
                var key_buf: [24]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{d}", .{@as(i64, @intFromFloat(id))}) catch unreachable;
                if (get(tb, key)) |o| {
                    var run: m.Run = .{
                        .from = @intCast(i),
                        .to = @intCast(j),
                        .style = textStyle(o),
                    };
                    if (get(o, "fills")) |fs| if (fs == .array) {
                        run.fills = try ctx.paints(fs.array.items);
                    };
                    try runs.append(ctx.a, run);
                }
            };
            i = j;
        }
        t.runs = runs.items;
        return t;
    }
};

/// Maps the network's geometric bounds (curve extremes included) onto `[0, size]`.
pub fn fitNetwork(net: *m.Network, size: Vec2) void {
    var b: geom.Rect = .empty;
    for (net.vertices) |p| b.include(p);
    for (net.segments) |s| {
        if (s.from >= net.vertices.len or s.to >= net.vertices.len) continue;
        const p0 = net.vertices[s.from];
        const p3 = net.vertices[s.to];
        const p1 = p0.add(s.t0);
        const p2 = p3.add(s.t1);
        var k: u32 = 1;
        while (k < 32) : (k += 1) b.include(geom.cubicAt(p0, p1, p2, p3, @as(f32, @floatFromInt(k)) / 32));
    }
    if (b.x0 > b.x1) return;
    const bw = b.x1 - b.x0;
    const bh = b.y1 - b.y0;
    const sx: f32 = if (bw > 1e-4) size.x / bw else 1;
    const sy: f32 = if (bh > 1e-4) size.y / bh else 1;
    if (@abs(sx - 1) < 1e-5 and @abs(sy - 1) < 1e-5 and @abs(b.x0) < 1e-4 and @abs(b.y0) < 1e-4) return;
    for (net.vertices) |*p| p.* = .{
        .x = (p.x - b.x0) * sx,
        .y = (p.y - b.y0) * sy,
    };
    for (net.segments) |*s| {
        s.t0 = .{
            .x = s.t0.x * sx,
            .y = s.t0.y * sy,
        };
        s.t1 = .{
            .x = s.t1.x * sx,
            .y = s.t1.y * sy,
        };
    }
}

fn kindOf(t: []const u8) m.Kind {
    const map = .{
        .{ "CANVAS", m.Kind.page },
        .{ "FRAME", m.Kind.frame },
        .{ "SECTION", m.Kind.frame },
        .{ "COMPONENT", m.Kind.component },
        .{ "COMPONENT_SET", m.Kind.component_set },
        .{ "INSTANCE", m.Kind.instance },
        .{ "GROUP", m.Kind.group },
        .{ "RECTANGLE", m.Kind.rectangle },
        .{ "ELLIPSE", m.Kind.ellipse },
        .{ "LINE", m.Kind.line },
        .{ "STAR", m.Kind.star },
        .{ "REGULAR_POLYGON", m.Kind.polygon },
        .{ "BOOLEAN_OPERATION", m.Kind.boolean },
        .{ "SLICE", m.Kind.slice },
        .{ "SLOT", m.Kind.frame },
        .{ "TRANSFORM_GROUP", m.Kind.group },
        .{ "TEXT", m.Kind.text },
        // Text on a path: a text node whose network is the path.
        .{ "TEXT_PATH", m.Kind.text },
    };
    inline for (map) |e| if (std.mem.eql(u8, t, e[0])) return e[1];
    return .vector;
}

fn blendOf(s: []const u8) m.Blend {
    if (std.mem.eql(u8, s, "PASS_THROUGH")) return .pass_through;
    if (std.mem.eql(u8, s, "NORMAL")) return .normal;
    inline for (@typeInfo(m.Blend).@"enum".fields) |f| {
        var buf: [32]u8 = undefined;
        const up = std.ascii.upperString(&buf, f.name);
        if (std.mem.eql(u8, s, up)) return @field(m.Blend, f.name);
    }
    return .normal;
}

/// Auto layout. A grid's primary axis is horizontal; its gaps are the column and row gaps.
fn layoutOf(a: std.mem.Allocator, v: Value, mode: []const u8) !m.Layout {
    const main = str(v, "primaryAxisAlignItems") orelse "MIN";
    const cross = str(v, "counterAxisAlignItems") orelse "MIN";
    const grid = std.mem.eql(u8, mode, "GRID");
    const horizontal = grid or std.mem.eql(u8, mode, "HORIZONTAL");
    const primary_hug = std.mem.eql(u8, str(v, "primaryAxisSizingMode") orelse "AUTO", "AUTO");
    const counter_hug = std.mem.eql(u8, str(v, "counterAxisSizingMode") orelse "AUTO", "AUTO");
    return .{
        .mode = if (grid) .grid else if (horizontal) .horizontal else .vertical,
        .wrap = std.mem.eql(u8, str(v, "layoutWrap") orelse "NO_WRAP", "WRAP"),
        .gap = num(v, if (grid) "gridColumnGap" else "itemSpacing") orelse 0,
        .cross_gap = num(v, if (grid) "gridRowGap" else "counterAxisSpacing") orelse 0,
        .align_content = if (std.mem.eql(u8, str(v, "counterAxisAlignContent") orelse "AUTO", "SPACE_BETWEEN")) .space_between else .auto,
        .strokes_included = boolean(v, "strokesIncludedInLayout") orelse false,
        .columns = if (grid) try cssTracks(a, str(v, "gridColumnsSizing") orelse "") else &.{},
        .rows = if (grid) try cssTracks(a, str(v, "gridRowsSizing") orelse "") else &.{},
        .padding = .{
            num(v, "paddingTop") orelse 0,
            num(v, "paddingRight") orelse 0,
            num(v, "paddingBottom") orelse 0,
            num(v, "paddingLeft") orelse 0,
        },
        .main = if (std.mem.eql(u8, main, "CENTER")) .center else if (std.mem.eql(u8, main, "MAX")) .end else if (std.mem.eql(u8, main, "SPACE_BETWEEN")) .space_between else if (std.mem.eql(u8, main, "SPACE_AROUND")) .space_around else if (std.mem.eql(u8, main, "SPACE_EVENLY")) .space_evenly else .start,
        .cross = if (std.mem.eql(u8, cross, "CENTER")) .center else if (std.mem.eql(u8, cross, "MAX")) .end else if (std.mem.eql(u8, cross, "BASELINE")) .baseline else .start,
        .width = if ((if (horizontal) primary_hug else counter_hug)) .hug else .fixed,
        .height = if ((if (horizontal) counter_hug else primary_hug)) .hug else .fixed,
    };
}

/// REST spells grid tracks as CSS (`repeat(3,minmax(0,1fr))`, `84px 84px`,
/// `fit-content(100%)`): `Npx` is fixed, `fr` (alone or as a minmax maximum) flexible,
/// `fit-content` and `auto` hug.
pub fn cssTracks(a: std.mem.Allocator, css: []const u8) ![]m.Track {
    var out: std.ArrayList(m.Track) = .empty;
    var i: usize = 0;
    while (i < css.len) {
        while (i < css.len and (css[i] == ' ' or css[i] == ',')) i += 1;
        if (i >= css.len) break;
        // One term: up to a space or comma outside parentheses.
        const start = i;
        var depth: u32 = 0;
        while (i < css.len) : (i += 1) {
            const ch = css[i];
            if (ch == '(') depth += 1;
            if (ch == ')') depth -|= 1;
            if (depth == 0 and (ch == ' ' or ch == ',')) break;
        }
        const term = css[start..i];
        if (std.mem.startsWith(u8, term, "repeat(") and term[term.len - 1] == ')') {
            const inner = term["repeat(".len .. term.len - 1];
            const comma = std.mem.indexOfScalar(u8, inner, ',') orelse continue;
            const n = std.fmt.parseInt(u32, std.mem.trim(u8, inner[0..comma], " "), 10) catch continue;
            const t = cssTrack(std.mem.trim(u8, inner[comma + 1 ..], " "));
            for (0..@min(n, 1000)) |_| try out.append(a, t);
        } else try out.append(a, cssTrack(term));
    }
    return out.items;
}

fn cssTrack(term: []const u8) m.Track {
    if (std.mem.endsWith(u8, term, "fr") or std.mem.endsWith(u8, term, "fr)")) {
        // `Nfr` or `minmax(x,Nfr)`: the share is the number before `fr`.
        const end = std.mem.lastIndexOf(u8, term, "fr").?;
        var s = end;
        while (s > 0 and (std.ascii.isDigit(term[s - 1]) or term[s - 1] == '.')) s -= 1;
        return .{
            .kind = .flex,
            .value = std.fmt.parseFloat(f32, term[s..end]) catch 1,
        };
    }
    if (std.mem.endsWith(u8, term, "px")) return .{
        .kind = .fixed,
        .value = std.fmt.parseFloat(f32, term[0 .. term.len - 2]) catch 0,
    };
    return .{
        .kind = .hug,
        .value = 1,
    };
}

fn whole(v: Value, key: []const u8, default: u32) u32 {
    const x = num(v, key) orelse return default;
    return if (x >= 0 and x < 1e9) @intFromFloat(x) else default;
}

fn cellAlign(s: []const u8) m.CellAlign {
    if (std.mem.eql(u8, s, "MIN")) return .start;
    if (std.mem.eql(u8, s, "CENTER")) return .center;
    if (std.mem.eql(u8, s, "MAX")) return .end;
    return .auto;
}

fn tileAlign(s: []const u8) m.TileAlign {
    if (std.mem.eql(u8, s, "CENTER")) return .center;
    if (std.mem.eql(u8, s, "END")) return .end;
    return .start;
}

fn hConstraint(s: []const u8) m.HConstraint {
    if (std.mem.eql(u8, s, "RIGHT")) return .right;
    if (std.mem.eql(u8, s, "LEFT_RIGHT")) return .left_right;
    if (std.mem.eql(u8, s, "CENTER")) return .center;
    if (std.mem.eql(u8, s, "SCALE")) return .scale;
    return .left;
}

fn vConstraint(s: []const u8) m.VConstraint {
    if (std.mem.eql(u8, s, "BOTTOM")) return .bottom;
    if (std.mem.eql(u8, s, "TOP_BOTTOM")) return .top_bottom;
    if (std.mem.eql(u8, s, "CENTER")) return .center;
    if (std.mem.eql(u8, s, "SCALE")) return .scale;
    return .top;
}

fn childSizing(s: []const u8) m.ChildSizing {
    if (std.mem.eql(u8, s, "HUG")) return .hug;
    if (std.mem.eql(u8, s, "FILL")) return .fill;
    return .fixed;
}

fn textResize(s: []const u8) m.TextResize {
    if (std.mem.eql(u8, s, "HEIGHT")) return .height;
    if (std.mem.eql(u8, s, "WIDTH_AND_HEIGHT")) return .width_and_height;
    if (std.mem.eql(u8, s, "TRUNCATE")) return .truncate;
    return .fixed;
}

fn textStyle(v: Value) m.TextStyle {
    var s: m.TextStyle = .{
        .family = str(v, "fontFamily"),
        .font_style = str(v, "fontStyle"),
        .size = num(v, "fontSize"),
        .italic = boolean(v, "italic"),
        .paragraph_spacing = num(v, "paragraphSpacing"),
        .paragraph_indent = num(v, "paragraphIndent"),
    };
    if (num(v, "fontWeight")) |w| s.weight = @intFromFloat(w);
    if (str(v, "lineHeightUnit")) |u| {
        if (std.mem.eql(u8, u, "PIXELS")) {
            if (num(v, "lineHeightPx")) |px| s.line_height = .{
                .px = px,
            };
        } else if (std.mem.eql(u8, u, "FONT_SIZE_%")) {
            if (num(v, "lineHeightPercentFontSize")) |p| s.line_height = .{
                .percent = p,
            };
        } else {
            s.line_height = .auto;
        }
    }
    if (num(v, "letterSpacing")) |ls| s.letter_spacing = .{
        .px = ls,
    };
    if (str(v, "textCase")) |c| s.case = if (std.mem.eql(u8, c, "UPPER")) .upper else if (std.mem.eql(u8, c, "LOWER")) .lower else if (std.mem.eql(u8, c, "TITLE")) .title else if (std.mem.eql(u8, c, "SMALL_CAPS")) .small_caps else if (std.mem.eql(u8, c, "SMALL_CAPS_FORCED")) .small_caps_forced else .none;
    if (str(v, "textDecoration")) |d| s.decoration = if (std.mem.eql(u8, d, "UNDERLINE")) .underline else if (std.mem.eql(u8, d, "STRIKETHROUGH")) .strikethrough else .none;
    return s;
}

fn strokeOf(a: std.mem.Allocator, v: Value) !m.Stroke {
    var s: m.Stroke = .{
        .weight = num(v, "strokeWeight") orelse 1,
    };
    // Figma's own outline of the stroke (it includes what the API does not describe:
    // variable widths, brushes).
    const geo = arr(v, "strokeGeometry");
    if (geo.len > 0) {
        var list: std.ArrayList(m.OutlinePath) = .empty;
        for (geo) |g| {
            const d = str(g, "path") orelse continue;
            const w = str(g, "windingRule") orelse "NONZERO";
            try list.append(a, .{
                .d = d,
                .winding = if (std.ascii.eqlIgnoreCase(w, "EVENODD")) .evenodd else .nonzero,
            });
        }
        s.outline = list.items;
    }
    if (str(v, "strokeAlign")) |al| s.@"align" = if (std.mem.eql(u8, al, "INSIDE")) .inside else if (std.mem.eql(u8, al, "OUTSIDE")) .outside else .center;
    if (str(v, "strokeCap")) |c| s.cap = if (std.mem.eql(u8, c, "ROUND")) .round else if (std.mem.eql(u8, c, "SQUARE")) .square else .none;
    if (str(v, "strokeJoin")) |j| s.join = if (std.mem.eql(u8, j, "ROUND")) .round else if (std.mem.eql(u8, j, "BEVEL")) .bevel else .miter;
    if (num(v, "strokeMiterAngle")) |deg| {
        const half = deg * std.math.pi / 360;
        if (half > 0) s.miter = 1 / @sin(half);
    }
    const dashes = arr(v, "strokeDashes");
    if (dashes.len > 0) {
        const d = try a.alloc(f32, dashes.len);
        for (d, dashes) |*o, x| o.* = numberOf(x) orelse 0;
        s.dashes = d;
    }
    if (get(v, "individualStrokeWeights")) |w| s.sides = .{
        num(w, "top") orelse 0,
        num(w, "right") orelse 0,
        num(w, "bottom") orelse 0,
        num(w, "left") orelse 0,
    };
    return s;
}

fn transformOf(v: Value) geom.Affine {
    if (v != .array or v.array.items.len < 2) return .identity;
    const r0 = v.array.items[0];
    const r1 = v.array.items[1];
    if (r0 != .array or r1 != .array or r0.array.items.len < 3 or r1.array.items.len < 3) return .identity;
    return .{
        .a = numberOf(r0.array.items[0]) orelse 1,
        .c = numberOf(r0.array.items[1]) orelse 0,
        .e = numberOf(r0.array.items[2]) orelse 0,
        .b = numberOf(r1.array.items[0]) orelse 0,
        .d = numberOf(r1.array.items[1]) orelse 1,
        .f = numberOf(r1.array.items[2]) orelse 0,
    };
}

fn color(v: Value) m.Color {
    return .{
        .r = num(v, "r") orelse 0,
        .g = num(v, "g") orelse 0,
        .b = num(v, "b") orelse 0,
        .a = num(v, "a") orelse 1,
    };
}

test "grid tracks from REST's CSS" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t1 = try cssTracks(arena.allocator(), "repeat(3,minmax(0,1fr))");
    try std.testing.expectEqual(@as(usize, 3), t1.len);
    try std.testing.expectEqual(m.TrackKind.flex, t1[2].kind);
    const t2 = try cssTracks(arena.allocator(), "  56px 84.5px");
    try std.testing.expectEqual(@as(usize, 2), t2.len);
    try std.testing.expectEqual(@as(f32, 84.5), t2[1].value);
    const t3 = try cssTracks(arena.allocator(), "repeat(2,fit-content(100%)) 2fr");
    try std.testing.expectEqual(m.TrackKind.hug, t3[0].kind);
    try std.testing.expectEqual(@as(f32, 2), t3[2].value);
}

test "import a tiny file" {
    const json =
        \\{"name":"T","document":{"id":"0:0","type":"DOCUMENT","children":[{"id":"0:1","type":"CANVAS","name":"Page",
        \\"backgroundColor":{"r":0.9,"g":0.9,"b":0.9,"a":1},"children":[{"id":"1:2","type":"FRAME","name":"F",
        \\"relativeTransform":[[1,0,10],[0,1,20]],"size":{"x":100,"y":50},"clipsContent":true,"cornerRadius":8,
        \\"fills":[{"type":"SOLID","color":{"r":1,"g":0,"b":0,"a":1}}],"children":[]}]}]},"styles":{}}
    ;
    var r = try import(std.testing.allocator, json);
    defer r.doc.deinit();
    const f = r.doc.pages[0].children[0];
    try std.testing.expectEqual(m.Kind.frame, f.kind);
    try std.testing.expectEqual(@as(f32, 10), f.transform.e);
    try std.testing.expectEqual(@as(f32, 8), f.radius[2]);
    try std.testing.expect(f.clip);
    try std.testing.expectEqual(@as(f32, 1), f.fills[0].color.r);
}
